;;; drgnx-statusbar.el --- The status bar: a quiet line of segments in place of the raw mode line -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Part A of M12f.  The bar is built from segments, which are data: `drgnx-statusbar-define-segment' registers an
;; ID with a function that returns a string (or nil), `drgnx-statusbar-left' and `-right' say which segments show
;; and in which order.  Each segment is clickable.  The bar replaces the editor windows' mode line
;; (`drgnx-chrome-editor-mode-line'): the full bar in the most recently used editor window, the few segments of
;; `drgnx-statusbar-compact' in the others.  It never wraps: when the window is narrower than the bar, segments are
;; dropped in `drgnx-statusbar-drop-order' and the branch is cut with an ellipsis.
;;
;; A segment function runs on every redisplay of its window, so it reads only state that is already cached (a
;; variable, a buffer-local value); it never calls git, a process, the file system or a language server.  See
;; docs/guide/face.md ("The status bar").

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-chrome)
(declare-function drgnx-face-glyph "drgnx-face")
(declare-function drgnx-wb-editor-window "drgnx-wb")
(declare-function drgnx-signal-post "drgnx-signal")
(declare-function drgnx-signal-subscribe "drgnx-signal")
(declare-function drgnx-signal-unsubscribe "drgnx-signal")
(declare-function drgnx-signal-editor-window-p "drgnx-signal")
(declare-function drgnx-modal-indicator-on "ext:drgnx-modal")
(declare-function drgnx-modal-indicator-off "ext:drgnx-modal")
(declare-function drgnx-modal-mode-line "ext:drgnx-modal")
(declare-function drgnx-agent-session-status "drgnx-agents")
(declare-function drgnx-agent-session-permissions "drgnx-agents")
(declare-function drgnx-agent-session-reviews "drgnx-agents")
(declare-function drgnx-job-ui-status "drgnx-job-ui")
(declare-function drgnx-agents-ui-view "drgnx-agents-ui")
(declare-function flymake--mode-line-counter "flymake")
(declare-function flymake-running-backends "flymake")
(declare-function flymake-reporting-backends "flymake")
(declare-function drgnx-job-ui--badge-segment "drgnx-job-ui")
(declare-function jsonrpc-running-p "jsonrpc")
(declare-function eglot--current-server-connection-running-p "ext:eglot")
(defvar vc-mode)
(defvar flymake-mode)
(defvar eglot--managed-mode)
(defvar eglot--cached-server)
(defvar drgnx-agents--sessions)
(defvar drgnx-job-ui--badge)

(defgroup drgnx-statusbar nil
  "The status bar: segments, their order, what is dropped when the window is narrow."
  :group 'drgnx-face :prefix "drgnx-statusbar-")

(defun drgnx-statusbar--set (symbol value)
  "Set SYMBOL to VALUE and redraw the bars."
  (set-default symbol value)
  (force-mode-line-update t))

(defcustom drgnx-statusbar-left '(branch problems tests jobs agents modal misc)
  "The segments on the left of the status bar, in order (see `drgnx-statusbar-define-segment')."
  :type '(repeat symbol) :set #'drgnx-statusbar--set :group 'drgnx-statusbar)

(defcustom drgnx-statusbar-right '(lsp position indent encoding eol language)
  "The segments on the right of the status bar, in order."
  :type '(repeat symbol) :set #'drgnx-statusbar--set :group 'drgnx-statusbar)

(defcustom drgnx-statusbar-drop-order '(eol indent encoding lsp language misc tests jobs)
  "Segments dropped, first to last, when the bar is wider than its window.
The branch is cut with an ellipsis instead, and only after these are gone."
  :type '(repeat symbol) :set #'drgnx-statusbar--set :group 'drgnx-statusbar)

(defcustom drgnx-statusbar-compact '(position language)
  "The segments the other editor groups show (the most recently used one shows the whole bar)."
  :type '(repeat symbol) :set #'drgnx-statusbar--set :group 'drgnx-statusbar)

(defcustom drgnx-statusbar-place 'editors
  "Where the bar is: `editors' (in each editor window) or `frame' (one bar across the frame's bottom).
`frame' arrives with the grid (drgnx-grid-mode); until that is on, the bar stays in the editor windows."
  :type '(choice (const :tag "In the editor windows" editors) (const :tag "Across the frame" frame))
  :set #'drgnx-statusbar--set :group 'drgnx-statusbar)

(defcustom drgnx-statusbar-indent-vars
  '(c-basic-offset js-indent-level typescript-ts-mode-indent-offset python-indent-offset
                   yaml-indent-offset sh-basic-offset lisp-body-indent standard-indent)
  "Variables that hold a mode's indentation width; the first one that is bound and a number is shown."
  :type '(repeat symbol) :group 'drgnx-statusbar)

;;;; Segments

(defvar drgnx-statusbar--segments (make-hash-table :test #'eq)
  "Segment ID → plist (:fn :click :help).")

(defvar drgnx-statusbar--errors nil
  "Alist ID → (MESSAGE . TIME) of the error a segment function (or the bar itself, ID `host') signalled.
Recorded, never shown as a message; a segment that failed is skipped for `drgnx-statusbar-retry-seconds', then tried
again: success clears the entry, failure records it anew.")

(defvar drgnx-statusbar-retry-seconds 10
  "Seconds a segment that signalled an error is skipped before it is tried again.")

(defun drgnx-statusbar--now () (float-time))

(defvar drgnx-statusbar--window nil
  "The window a bar is being drawn for (bound while it renders); nil: the most recently used editor window.")

(cl-defun drgnx-statusbar-define-segment (id &key fn click help)
  "Define (or replace) the segment ID.
FN takes no arguments and returns a string or nil; it runs with the buffer of `drgnx-statusbar-source-window'
current and may read only cached state.  CLICK is a command symbol or a function, run when the text is clicked.
HELP is the text shown when the pointer rests on the segment."
  (puthash id (list :fn fn :click click :help help) drgnx-statusbar--segments)
  (setq drgnx-statusbar--errors (assq-delete-all id drgnx-statusbar--errors))   ; a new definition gets a new chance
  (force-mode-line-update t)
  id)

(defun drgnx-statusbar-source-window ()
  "The window whose buffer the segment functions read: the window the bar is drawn for, else the most recently
used editor window."
  (or (and (window-live-p drgnx-statusbar--window) drgnx-statusbar--window)
      (and (fboundp 'drgnx-wb-editor-window) (drgnx-wb-editor-window))
      (selected-window)))

(defvar drgnx-statusbar--map
  (let ((m (make-sparse-keymap)))
    (define-key m [mode-line mouse-1] #'drgnx-statusbar-click)
    (define-key m [mouse-1] #'drgnx-statusbar-click)
    m)
  "The keymap of a segment's text.")

(defun drgnx-statusbar-click (event)
  "Run the click command of the segment under the mouse EVENT."
  (interactive "e")
  (let* ((posn (event-start event))
         (str (posn-string posn))
         (id (and str (get-text-property (cdr str) 'drgnx-statusbar-segment (car str))))
         (click (and id (plist-get (gethash id drgnx-statusbar--segments) :click)))
         (w (posn-window posn)))
    (when click
      (with-selected-window (if (and (window-live-p w) (drgnx-signal-editor-window-p w)) w (selected-window))
        (cond ((commandp click) (call-interactively click))
              ((functionp click) (funcall click))
              (t (message "%s is not available" click)))))))

(defun drgnx-statusbar--note-error (id err)
  "Record ERR as the error of segment ID with the time, replacing its entry (the record never grows).
Within `drgnx-statusbar-retry-seconds' of the last record nothing is formatted: a redisplay costs no more for it."
  (unless (drgnx-statusbar--failed-p id)
    (setq drgnx-statusbar--errors
          (cons (cons id (cons (error-message-string err) (drgnx-statusbar--now)))
                (assq-delete-all id drgnx-statusbar--errors)))))

(defun drgnx-statusbar--failed-p (id)
  "Non-nil when segment ID signalled an error less than `drgnx-statusbar-retry-seconds' ago."
  (when-let* ((e (assq id drgnx-statusbar--errors)))
    (< (- (drgnx-statusbar--now) (cddr e)) drgnx-statusbar-retry-seconds)))

(defun drgnx-statusbar--text (id)
  "The text of segment ID with its properties, or nil when it has nothing to say (or failed)."
  (when-let* ((seg (gethash id drgnx-statusbar--segments))
              (fn (plist-get seg :fn))
              ((not (drgnx-statusbar--failed-p id)))
              (s (condition-case err
                     (prog1 (funcall fn)
                       (when (assq id drgnx-statusbar--errors)      ; it works again
                         (setq drgnx-statusbar--errors (assq-delete-all id drgnx-statusbar--errors))))
                   (error (drgnx-statusbar--note-error id err) nil)))
              ((stringp s)) ((not (string-empty-p s))))
    (let ((s (copy-sequence s)))
      ;; the bar counts columns of characters: a `display' property could show something of another width
      (remove-text-properties 0 (length s) '(display nil) s)
      (add-text-properties 0 (length s)
                           (list 'drgnx-statusbar-segment id 'local-map drgnx-statusbar--map
                                 'mouse-face 'mode-line-highlight
                                 'help-echo (or (plist-get seg :help) (symbol-name id)))
                           s)
      s)))

;;;; Layout

(defvar drgnx-statusbar--left-sep " · "
  "The separator between left segments (bound while rendering to the glyph `sep': ASCII on a non-UTF-8 terminal).")
(defconst drgnx-statusbar--right-sep "  ")
(defconst drgnx-statusbar--branch-min 14 "Columns the branch is cut to before other segments are dropped for it.")

(defun drgnx-statusbar--run-width (segs sep)
  "Columns of the texts in SEGS (an alist ID → text) joined by SEP."
  (if segs (+ (apply #'+ (mapcar (lambda (s) (string-width (cdr s))) segs)) (* (string-width sep) (1- (length segs)))) 0))

(defun drgnx-statusbar--total (left right)
  "Columns of the bar with these LEFT and RIGHT segments: a pad on each side and at least two between."
  (+ 2 (drgnx-statusbar--run-width left drgnx-statusbar--left-sep)
     (drgnx-statusbar--run-width right drgnx-statusbar--right-sep)
     (if right (if left 2 1) 0)))

(defun drgnx-statusbar--cut-branch (left right width min)
  "LEFT with the branch cut so that the bar fits WIDTH, but not below MIN columns; the new LEFT, or nil if it cannot."
  (when-let* ((b (assq 'branch left))
              (excess (- (drgnx-statusbar--total left right) width))
              ((> excess 0))
              (target (max min 1 (- (string-width (cdr b)) excess)))
              ((< target (string-width (cdr b)))))
    (mapcar (lambda (s) (if (eq (car s) 'branch) (cons 'branch (truncate-string-to-width (cdr b) target nil nil t)) s))
            left)))

(defun drgnx-statusbar--fit (left right width)
  "LEFT and RIGHT (alists ID → text) reduced until the bar fits WIDTH: (LEFT . RIGHT).
First the segments of `drgnx-statusbar-drop-order' go, then the branch is cut to a short form, then the others go
(right to left, then left to right, the branch last), and last the branch is cut as far as it takes."
  (let ((order drgnx-statusbar-drop-order))
    (while (and (> (drgnx-statusbar--total left right) width) order)
      (let ((id (pop order)))
        (setq left (assq-delete-all id (copy-sequence left)) right (assq-delete-all id (copy-sequence right))))))
  (when (> (drgnx-statusbar--total left right) width)
    (setq left (or (drgnx-statusbar--cut-branch left right width drgnx-statusbar--branch-min) left)))
  (while (and (> (drgnx-statusbar--total left right) width) (or right (seq-find (lambda (s) (not (eq (car s) 'branch))) left)))
    (if right
        (setq right (butlast right))
      (let ((last (car (last (seq-remove (lambda (s) (eq (car s) 'branch)) left)))))
        (setq left (delq last (copy-sequence left))))))
  (when (> (drgnx-statusbar--total left right) width)
    (setq left (or (drgnx-statusbar--cut-branch left right width 1) left)))
  (cons left right))

(defun drgnx-statusbar--join (segs sep)
  (let ((sep (propertize sep 'face 'shadow)))
    (mapconcat #'cdr segs sep)))

(defun drgnx-statusbar-render (width &optional compact)
  "The status bar as a propertized string of at most WIDTH columns for the window being drawn.
COMPACT: only the segments of `drgnx-statusbar-compact' (on the right).  The segment functions run with the
source window's buffer current."
  (let* ((w (drgnx-statusbar-source-window))
         (buf (and (window-live-p w) (window-buffer w))))
    (with-current-buffer (or buf (current-buffer))
      (let* ((drgnx-statusbar--window w)
             (drgnx-statusbar--left-sep (drgnx-statusbar--separator))
             (texts (lambda (ids) (delq nil (mapcar (lambda (id) (when-let* ((s (drgnx-statusbar--text id))) (cons id s))) ids))))
             (left (unless compact (funcall texts drgnx-statusbar-left)))
             (right (funcall texts (if compact drgnx-statusbar-compact drgnx-statusbar-right)))
             (fitted (drgnx-statusbar--fit left right (max width 0))))
        (setq left (car fitted) right (cdr fitted))
        (let* ((l (drgnx-statusbar--join left drgnx-statusbar--left-sep))
               (r (drgnx-statusbar--join right drgnx-statusbar--right-sep))
               (rw (string-width r))
               (bar (concat " " l
                            (when right (propertize " " 'display `(space :align-to (- right ,(1+ rw)))))
                            r " ")))
          ;; a last guard: whatever the segments were, the bar is never wider than the window
          (cond ((<= (string-width bar) width) bar)
                ((<= width 0) "")
                (t (truncate-string-to-width bar width nil nil t))))))))

;;;; The mode line

(defun drgnx-statusbar--mru-editor-p (w)
  "Non-nil when W is its frame's most recently used editor window."
  (let ((mru (if (eq (window-frame w) (selected-frame))
                 (drgnx-wb-editor-window)
               (seq-find #'drgnx-signal-editor-window-p (window-list (window-frame w) 'nomini)))))
    (or (null mru) (eq w mru))))

(defcustom drgnx-statusbar-modes '(prog-mode text-mode conf-mode)
  "Major modes (and the modes derived from them) whose buffers get the status bar; so does any buffer that visits a file.
Every other buffer (Magit, Dired, help, Info, shells, compilation, drgnx's own panes) keeps its own mode line."
  :type '(repeat symbol) :set #'drgnx-statusbar--set :group 'drgnx-statusbar)

(defun drgnx-statusbar--own-mode-line-p ()
  "Non-nil when this buffer sets its own, non-nil `mode-line-format'."
  (and (local-variable-p 'mode-line-format) mode-line-format t))

(defun drgnx-statusbar--wanted-p ()
  "Non-nil when the current buffer gets the status bar: it visits a file or is code, text or configuration."
  (and (not (drgnx-statusbar--own-mode-line-p))
       (or buffer-file-name (and drgnx-statusbar-modes (apply #'derived-mode-p drgnx-statusbar-modes)))))

(defun drgnx-statusbar--escape (s)
  "S with every `%' doubled (keeping the properties): in a mode line, `%' starts a construct such as `%b'."
  (if (not (string-search "%" s))
      s
    (let ((parts nil) (start 0) pos)
      (while (setq pos (string-search "%" s start))
        (push (substring s start (1+ pos)) parts)
        (push (substring s pos (1+ pos)) parts)
        (setq start (1+ pos)))
      (push (substring s start) parts)
      (apply #'concat (nreverse parts)))))

(defun drgnx-statusbar-mode-line ()
  "The `:eval' of an editor window's mode line.
In a buffer that visits a file or is code, text or configuration (`drgnx-statusbar-modes'): the full bar in the most
recently used editor window, the compact one in the others.  In a buffer whose own `mode-line-format' is nil: nothing.
In any other buffer: the stock mode line.  An error shows nothing and is recorded once, never on every redisplay."
  (condition-case err
      (cond ((and (local-variable-p 'mode-line-format) (null mode-line-format)) nil)
            ((drgnx-statusbar--wanted-p)
             (let* ((w (selected-window))       ; the window being drawn (a mode line is drawn with it selected)
                    (drgnx-statusbar--window w))
               (drgnx-statusbar--escape
                (drgnx-statusbar-render (window-total-width w) (not (drgnx-statusbar--mru-editor-p w))))))
            (t (or mode-line-format (default-value 'mode-line-format))))
    (error (drgnx-statusbar--note-error 'host err) nil)))

(defvar drgnx-statusbar--last (make-vector 4 nil) "[BUFFER WINDOW POINT TICK] as of the last command.")

(defun drgnx-statusbar--post-command ()
  "A mode line made by `:eval' does not know it shows the point: ask for a redraw when what it shows changed."
  (let ((l drgnx-statusbar--last) (b (current-buffer)) (w (selected-window)))
    (let ((pt (window-point w)) (tick (buffer-chars-modified-tick)))
      (unless (and (eq (aref l 0) b) (eq (aref l 1) w) (eql (aref l 2) pt) (eql (aref l 3) tick))
        ;; the most recently used editor window is only known after the bus's idle flush: redraw both bars then
        ;; (`editor-changed' covers another buffer; this covers the same buffer in two windows)
        (unless (eq (aref l 1) w) (drgnx-signal-post 'statusbar-window-changed))
        (aset l 0 b) (aset l 1 w) (aset l 2 pt) (aset l 3 tick)
        (force-mode-line-update)))))             ; this buffer's mode line only

(defun drgnx-statusbar--editor-changed (&rest _)
  "On the bus's `editor-changed' and `statusbar-window-changed': the most recently used editor window is another
one now, so the full bar and the compact one trade places in every window."
  (force-mode-line-update t))

(defvar drgnx-statusbar--agents-seen nil "(BUSY . WAITING) as of the last agent change.")
(defvar drgnx-agents-changed-functions)

(defun drgnx-statusbar--agents-changed (&rest _)
  "On `drgnx-agents-changed-functions': redraw the bars when the counts the agents segment shows changed."
  (let ((now (drgnx-statusbar--agent-counts)))
    (unless (equal now drgnx-statusbar--agents-seen)
      (setq drgnx-statusbar--agents-seen now)
      (force-mode-line-update t))))

(defconst drgnx-statusbar--host '(:eval (drgnx-statusbar-mode-line)))

(define-minor-mode drgnx-statusbar-mode
  "The status bar in the editor windows in place of the raw mode line."
  :global t :group 'drgnx-statusbar
  (setq drgnx-chrome-editor-mode-line (if drgnx-statusbar-mode drgnx-statusbar--host drgnx-chrome--mode-line))
  (if drgnx-statusbar-mode
      (progn
        (add-hook 'post-command-hook #'drgnx-statusbar--post-command)
        (add-hook 'drgnx-agents-changed-functions #'drgnx-statusbar--agents-changed)
        (dolist (e '(editor-changed statusbar-window-changed))
          (drgnx-signal-subscribe e #'drgnx-statusbar--editor-changed))
        (when (fboundp 'drgnx-modal-indicator-off) (drgnx-modal-indicator-off)))   ; the bar shows the modal state
    (remove-hook 'post-command-hook #'drgnx-statusbar--post-command)
    (remove-hook 'drgnx-agents-changed-functions #'drgnx-statusbar--agents-changed)
    (dolist (e '(editor-changed statusbar-window-changed))
      (drgnx-signal-unsubscribe e #'drgnx-statusbar--editor-changed))
    (when (fboundp 'drgnx-modal-indicator-on) (drgnx-modal-indicator-on)))
  (dolist (f (frame-list)) (drgnx-chrome-apply f))
  (force-mode-line-update t))

;;;; The default segments (cached state only)

(defun drgnx-statusbar--glyph (name)
  "The glyph NAME for the frame being drawn (ASCII on a terminal that is not UTF-8)."
  (if (fboundp 'drgnx-face-glyph)
      (or (drgnx-face-glyph name (window-frame (drgnx-statusbar-source-window))) "")
    ""))

(defun drgnx-statusbar--separator ()
  "What goes between the left segments: the glyph `sep' (` · ', or ` | ' in ASCII)."
  (let ((s (drgnx-statusbar--glyph 'sep))) (if (string-empty-p s) " · " s)))

(defun drgnx-statusbar--seg-branch ()
  "The branch git put in `vc-mode' (\" Git-main\")."
  (when (and (stringp vc-mode) (string-match "\\`[ ]*[[:alpha:]]+[-:@!?]\\(.+\\)" (substring-no-properties vc-mode)))
    (concat (drgnx-statusbar--glyph 'branch) " " (match-string 1 (substring-no-properties vc-mode)))))

(defun drgnx-statusbar--flymake-count (type)
  "How many problems of TYPE flymake counts in this buffer (flymake caches the count until diagnostics change)."
  (let ((c (flymake--mode-line-counter type)))
    (or (and (consp c) (consp (nth 1 c)) (stringp (nth 1 (nth 1 c))) (string-to-number (nth 1 (nth 1 c)))) 0)))

(defun drgnx-statusbar--seg-problems ()
  (when (and (bound-and-true-p flymake-mode) (fboundp 'flymake--mode-line-counter))
    (let ((e (drgnx-statusbar--flymake-count :error)) (w (drgnx-statusbar--flymake-count :warning)))
      (cond
       ((or (> e 0) (> w 0))
        (let ((glyph (drgnx-statusbar--glyph 'warning)))
          (string-join (delq nil (list (and (> e 0) (propertize (format "%s %d" glyph e) 'face 'error))
                                       (and (> w 0) (propertize (format "%s %d" glyph w) 'face 'warning))))
                       " ")))
       ;; a backend that has not reported yet: not "no problems" (as in stock flymake's Wait)
       ((cl-set-difference (flymake-running-backends) (flymake-reporting-backends))
        (propertize (drgnx-statusbar--glyph 'waiting) 'face 'shadow))
       ((flymake-reporting-backends) (propertize (drgnx-statusbar--glyph 'ok) 'face 'success))))))

(defun drgnx-statusbar--seg-jobs ()
  "The job badge (cards waiting for you); the count of running jobs is not cached anywhere yet."
  (when (and (boundp 'drgnx-job-ui--badge) (stringp drgnx-job-ui--badge) (not (string-empty-p drgnx-job-ui--badge)))
    (string-trim (substring-no-properties drgnx-job-ui--badge))))

(defun drgnx-statusbar--agent-counts ()
  "(BUSY . WAITING): agents working, and agents with something waiting on you, from the sessions drgnx already holds."
  (when (and (boundp 'drgnx-agents--sessions) drgnx-agents--sessions (fboundp 'drgnx-agent-session-status))
    (let ((busy 0) (waiting 0))
      (dolist (s drgnx-agents--sessions)
        (when (eq (drgnx-agent-session-status s) 'busy) (cl-incf busy))
        (when (or (drgnx-agent-session-permissions s) (drgnx-agent-session-reviews s)) (cl-incf waiting)))
      (cons busy waiting))))

(defun drgnx-statusbar--seg-agents ()
  (when-let* ((c (drgnx-statusbar--agent-counts)))
    (let ((busy (car c)) (waiting (cdr c)))
      (string-join (delq nil (list (and (> busy 0) (format "%s %d busy" (drgnx-statusbar--glyph 'busy) busy))
                                   (and (> waiting 0)
                                        (propertize (format "%s %d waiting on you" (drgnx-statusbar--glyph 'waiting) waiting)
                                                    'face 'error))))
                   " "))))

(defcustom drgnx-statusbar-misc-exclude '((:eval (drgnx-job-ui--badge-segment)))
  "Entries of `global-mode-string' the `misc' segment leaves out because the bar already shows them (the job badge)."
  :type 'sexp :group 'drgnx-statusbar)

(defun drgnx-statusbar--construct-text (c)
  "The text of the mode-line construct C: a string as it is, a list of strings joined, anything else formatted.
Only what the mode line already holds (no lookups)."
  (cond ((null c) nil)
        ((stringp c) c)
        ((and (consp c) (seq-every-p #'stringp c)) (apply #'concat c))
        (t (format-mode-line c))))

(defun drgnx-statusbar--seg-misc ()
  "What stock Emacs would show beside the file: the process of the buffer, `global-mode-string' (without the job badge),
a keyboard macro being recorded, narrowing, and a remote directory."
  (let* ((global (and (listp global-mode-string)
                      (seq-remove (lambda (e) (member e drgnx-statusbar-misc-exclude)) global-mode-string)))
         (parts (delq nil
                      (list (and defining-kbd-macro
                                 (propertize (format "%s Rec" (drgnx-statusbar--glyph 'dot)) 'face 'error))
                            (and (buffer-narrowed-p) "Narrowed")
                            (when-let* (((stringp default-directory))
                                        (host (file-remote-p default-directory 'host))   ; parses the name, no connection
                                        ((not (string-empty-p host))))
                              (format "Remote: %s" host))
                            (drgnx-statusbar--construct-text mode-line-process)
                            (drgnx-statusbar--construct-text global)))))
    (let ((text (string-join (seq-remove #'string-empty-p (mapcar #'string-trim parts)) " ")))
      (unless (string-empty-p text) text))))

(defun drgnx-statusbar--seg-modal ()
  (when (fboundp 'drgnx-modal-mode-line)
    (let ((m (drgnx-modal-mode-line)))
      (cond ((stringp m) m) (m (format-mode-line m))))))

(defun drgnx-statusbar--seg-lsp ()
  "Eglot's own cache: its server for this buffer (nothing is looked up)."
  (when (bound-and-true-p eglot--managed-mode)
    (let ((server (bound-and-true-p eglot--cached-server)))
      (format "LSP %s" (cond ((null server) (drgnx-statusbar--glyph 'circle))
                             ((and (fboundp 'jsonrpc-running-p) (not (jsonrpc-running-p server))) (drgnx-statusbar--glyph 'close))
                             (t (drgnx-statusbar--glyph 'dot)))))))

(defvar-local drgnx-statusbar--line-cache nil
  "[TICK POINT-MIN LINE-START LINE]: the line number the position segment last worked out in this buffer.")

(defun drgnx-statusbar--line-at (bol)
  "The line number of the line starting at BOL.  Moving point costs the lines between the last answer and here; only
a change of the text (or of the narrowing) counts again from the top."
  (let* ((c drgnx-statusbar--line-cache) (tick (buffer-chars-modified-tick)) (pmin (point-min))
         (line (if (and c (eql (aref c 0) tick) (eql (aref c 1) pmin))
                   (let ((cb (aref c 2)) (cl (aref c 3)))
                     (cond ((= bol cb) cl)
                           ((> bol cb) (+ cl (count-lines cb bol)))
                           (t (- cl (count-lines bol cb)))))
                 (line-number-at-pos bol))))
    (setq drgnx-statusbar--line-cache (vector tick pmin bol line))
    line))

(defun drgnx-statusbar--seg-position ()
  (let* ((w (drgnx-statusbar-source-window))
         (pt (if (eq (window-buffer w) (current-buffer)) (window-point w) (point))))
    (save-excursion
      (goto-char pt)
      (let* ((bol (pos-bol))
             (col (if (> (- pt bol) 2000) (- pt bol) (current-column))))   ; a minified line: characters, not columns
        (format "Ln %d, Col %d" (drgnx-statusbar--line-at bol) (1+ col))))))

(defun drgnx-statusbar--seg-indent ()
  (if indent-tabs-mode
      (format "Tab Size: %d" tab-width)
    (format "Spaces: %d" (or (seq-some (lambda (v) (and (boundp v) (natnump (symbol-value v)) (symbol-value v)))
                                       drgnx-statusbar-indent-vars)
                             tab-width))))

(defun drgnx-statusbar--seg-encoding ()
  (when-let* ((cs buffer-file-coding-system)
              (charset (or (coding-system-get cs :mime-charset) (coding-system-base cs))))
    (if (memq charset '(undecided prefer-utf-8)) "UTF-8" (upcase (symbol-name charset)))))   ; plain ASCII is undecided

(defun drgnx-statusbar--seg-eol ()
  (pcase (and buffer-file-coding-system (coding-system-eol-type buffer-file-coding-system))
    (1 "CRLF") (2 "CR") (_ "LF")))

(defun drgnx-statusbar--seg-language ()
  (let ((name (replace-regexp-in-string "\\(-ts\\)?-mode\\'" "" (symbol-name major-mode))))
    (if (<= (length name) 4) (upcase name) (capitalize (replace-regexp-in-string "-" " " name)))))

(defun drgnx-statusbar--click-branch ()
  (interactive)
  (if (fboundp 'magit-status) (call-interactively 'magit-status) (call-interactively 'vc-dir)))

(defun drgnx-statusbar--define-defaults ()
  "Define the segments the bar ships with.  Tests has nothing cached to read yet: it renders nothing until a later
task gives it a source."
  (drgnx-statusbar-define-segment 'branch :fn #'drgnx-statusbar--seg-branch :click #'drgnx-statusbar--click-branch
                                  :help "Branch; click for the repository status")
  (drgnx-statusbar-define-segment 'problems :fn #'drgnx-statusbar--seg-problems :click 'flymake-show-buffer-diagnostics
                                  :help "Problems in this file; click to list them")
  (drgnx-statusbar-define-segment 'tests :fn #'ignore :help "Test results")
  (drgnx-statusbar-define-segment 'jobs :fn #'drgnx-statusbar--seg-jobs :click 'drgnx-job-ui-status
                                  :help "Jobs; click for their status")
  (drgnx-statusbar-define-segment 'agents :fn #'drgnx-statusbar--seg-agents :click 'drgnx-agents-ui-view
                                  :help "Agents busy or waiting on you; click for the Agents tab")
  (drgnx-statusbar-define-segment 'modal :fn #'drgnx-statusbar--seg-modal :help "Modal editing state")
  (drgnx-statusbar-define-segment 'misc :fn #'drgnx-statusbar--seg-misc
                                  :help "Process, recording, narrowing, remote and other indicators")
  (drgnx-statusbar-define-segment 'lsp :fn #'drgnx-statusbar--seg-lsp :click 'eglot-events-buffer
                                  :help "Language server; click for its events")
  (drgnx-statusbar-define-segment 'position :fn #'drgnx-statusbar--seg-position :click 'goto-line
                                  :help "Line and column; click to go to a line")
  (drgnx-statusbar-define-segment 'indent :fn #'drgnx-statusbar--seg-indent :click 'indent-tabs-mode
                                  :help "Indentation; click to switch between tabs and spaces")
  (drgnx-statusbar-define-segment 'encoding :fn #'drgnx-statusbar--seg-encoding :click 'set-buffer-file-coding-system
                                  :help "File encoding; click to change it")
  (drgnx-statusbar-define-segment 'eol :fn #'drgnx-statusbar--seg-eol :click 'set-buffer-file-coding-system
                                  :help "Line endings; click to change them")
  (drgnx-statusbar-define-segment 'language :fn #'drgnx-statusbar--seg-language :click 'describe-mode
                                  :help "Language (major mode); click for its help"))

;;;; Setup (called by the module ui/face)

(defun drgnx-statusbar-setup ()
  "Define the command and the default segments and turn the status bar on."
  (drgnx-command-define 'statusbar-toggle :category "View" :title "Toggle Status Bar" :menu '("View")
                        :command #'drgnx-statusbar-mode
                        :doc "Show the status bar (branch, problems, position, language …) or the plain mode line")
  (drgnx-statusbar--define-defaults)
  (drgnx-statusbar-mode 1))

(provide 'drgnx-statusbar)
;;; drgnx-statusbar.el ends here
