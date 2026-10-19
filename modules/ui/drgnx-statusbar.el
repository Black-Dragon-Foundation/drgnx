;;; drgnx-statusbar.el --- The status bar: quiet segments in place of the raw mode line -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Part A of M12f.  The bar is built from segments, which are data: `drgnx-statusbar-define-segment' registers an
;; ID with a function that returns a string (or nil), `drgnx-statusbar-left' and `-right' say which segments show
;; and in which order.  Each segment is clickable.  The bar replaces the editor windows' mode line
;; (`drgnx-chrome-editor-mode-line'): the full bar in the most recently used editor window, the few segments of
;; `drgnx-statusbar-compact' in the others.  It never wraps: when the window is narrower than the bar, segments are
;; dropped in `drgnx-statusbar-drop-order' and the branch is cut with an ellipsis.
;;
;; A segment function reads only state that is already cached (a variable, a buffer-local value); it never calls
;; git, a process, the file system or a language server.  Each window's bar is memoized on what it shows (buffer,
;; point, text, width, the drgnx side's state tick and the buffer-locals the segments read), so a redisplay that
;; changes nothing costs a few comparisons.  drgnx's own segments (tests, jobs, agents) are worked out when their
;; hooks say something changed (`drgnx-statusbar-refresh', debounced), never on redisplay.  See docs/guide/face.md
;; ("The status bar").

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'mule-util)                    ; `truncate-string-ellipsis'
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-chrome)
(require 'drgnx-state)
(require 'drgnx-timer)
(declare-function drgnx-face-glyph "drgnx-face")
(declare-function drgnx-wb-editor-window "drgnx-wb")
(declare-function drgnx-signal-subscribe "drgnx-signal")
(declare-function drgnx-signal-unsubscribe "drgnx-signal")
(declare-function drgnx-signal-editor-window-p "drgnx-signal")
(declare-function drgnx-modal-indicator-on "ext:drgnx-modal")
(declare-function drgnx-modal-indicator-off "ext:drgnx-modal")
(declare-function drgnx-modal-mode-line "ext:drgnx-modal")
(declare-function drgnx-agent-session-status "drgnx-agents")
(declare-function drgnx-agent-session-permissions "drgnx-agents")
(declare-function drgnx-agent-session-reviews "drgnx-agents")
(declare-function drgnx-agents-sessions "drgnx-agents")
(declare-function drgnx-hub-call "drgnx-hub")
(declare-function drgnx-job-ui-needs-you "drgnx-job-ui")
(declare-function drgnx-agents-ui-view "drgnx-agents-ui")
(declare-function flymake--mode-line-counter "flymake")
(declare-function flymake-running-backends "flymake")
(declare-function flymake-reporting-backends "flymake")
(declare-function drgnx-job-ui--badge-segment "drgnx-job-ui")
(declare-function jsonrpc-running-p "jsonrpc")
(declare-function drgnx-git-branch "drgnx-git")
(declare-function drgnx-git-cached-root "drgnx-git")
(declare-function drgnx-git-refresh "drgnx-git")
(declare-function eglot--server-info "ext:eglot")
(declare-function eglot--current-server-connection-running-p "ext:eglot")
(defvar vc-mode)
(defvar flymake-mode)
(defvar eglot--managed-mode)
(defvar eglot--cached-server)
(defvar drgnx-job-ui--badge)
(defvar drgnx-face-glyphs)
(defvar drgnx-modal-state)
(defvar flymake--mode-line-counter-cache)
(defvar compilation-arguments)
(defvar drgnx-hub--events)
(defvar drgnx-agents-changed-functions)
(defvar drgnx-hub-event-functions)
(defvar drgnx-hub-disconnect-functions)
(defvar drgnx-git-changed-functions)

(defgroup drgnx-statusbar nil
  "The status bar: segments, their order, what is dropped when the window is narrow."
  :group 'drgnx-face :prefix "drgnx-statusbar-")

(defface drgnx-statusbar-waiting '((t :inherit error))
  "The status bar's count of things waiting on you (agents' questions, edits to review, open questions)."
  :group 'drgnx-statusbar)

(defvar drgnx-statusbar--tick 0
  "Bumped whenever what drgnx's own segments show changes (tests, jobs, agents), a segment is defined or a setting
changes: every window's memoized bar is built again on its next redisplay.")

(defun drgnx-statusbar--bump ()
  "Say that the state the bars show changed."
  (setq drgnx-statusbar--tick (1+ drgnx-statusbar--tick)))

(defun drgnx-statusbar--set (symbol value)
  "Set SYMBOL to VALUE and redraw the bars."
  (set-default symbol value)
  (drgnx-statusbar--bump)
  (force-mode-line-update t))

(defcustom drgnx-statusbar-left '(branch trust problems tests jobs agents modal misc)
  "The segments on the left of the status bar, in order (see `drgnx-statusbar-define-segment')."
  :type '(repeat symbol) :set #'drgnx-statusbar--set :group 'drgnx-statusbar)

(defcustom drgnx-statusbar-right '(lsp position indent encoding eol language)
  "The segments on the right of the status bar, in order."
  :type '(repeat symbol) :set #'drgnx-statusbar--set :group 'drgnx-statusbar)

(defcustom drgnx-statusbar-drop-order '(eol indent encoding lsp language misc tests jobs trust)
  "Segments dropped, first to last, when the bar is wider than its window.
The branch is cut with an ellipsis instead, and only after these are gone."
  :type '(repeat symbol) :set #'drgnx-statusbar--set :group 'drgnx-statusbar)

(defcustom drgnx-statusbar-compact '(position language)
  "The segments the other editor groups show (the most recently used one shows the whole bar)."
  :type '(repeat symbol) :set #'drgnx-statusbar--set :group 'drgnx-statusbar)

(defcustom drgnx-statusbar-quiet '(folder branch agents jobs tests misc)
  "The segments of the quiet bar (`drgnx-statusbar-quiet-modes': the start page), on the left, in order."
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
  (drgnx-statusbar--bump)
  (force-mode-line-update t)
  id)

(defun drgnx-statusbar-source-window ()
  "The window whose buffer the segment functions read: the window the bar is drawn for, else the most recently
used editor window."
  (or (and (window-live-p drgnx-statusbar--window) drgnx-statusbar--window)
      (drgnx-state-editor-window)
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
  (if segs
      (+ (apply #'+ (mapcar (lambda (s) (string-width (cdr s))) segs)) (* (string-width sep) (1- (length segs))))
    0))

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
    (mapcar (lambda (s) (if (eq (car s) 'branch) (cons 'branch (drgnx-statusbar--cut (cdr b) target)) s))
            left)))

(defun drgnx-statusbar--cut (s width)
  "S cut to WIDTH columns, ending in Emacs's ellipsis when that fits in WIDTH.
`truncate-string-to-width' gives back all of S, and the ellipsis, when the ellipsis is wider than WIDTH: \"...\" is,
in 1 or 2 columns, on a terminal that cannot show \"…\"."
  (truncate-string-to-width s width nil nil (>= width (string-width (truncate-string-ellipsis)))))

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
  (while (and (> (drgnx-statusbar--total left right) width)
              (or right (seq-find (lambda (s) (not (eq (car s) 'branch))) left)))
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
COMPACT: only the segments of `drgnx-statusbar-compact' (on the right); `quiet': only those of
`drgnx-statusbar-quiet' (on the left).  The segment functions run with the source window's buffer current."
  (let* ((w (drgnx-statusbar-source-window))
         (buf (and (window-live-p w) (window-buffer w))))
    (with-current-buffer (or buf (current-buffer))
      (let* ((drgnx-statusbar--window w)
             (drgnx-statusbar--left-sep (drgnx-statusbar--separator))
             (texts (lambda (ids)
                      (delq nil (mapcar (lambda (id) (when-let* ((s (drgnx-statusbar--text id))) (cons id s))) ids))))
             (left (cond ((eq compact 'quiet) (funcall texts drgnx-statusbar-quiet))
                         ((not compact) (funcall texts drgnx-statusbar-left))))
             (right (unless (eq compact 'quiet)
                      (funcall texts (if compact drgnx-statusbar-compact drgnx-statusbar-right))))
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
                (t (drgnx-statusbar--cut bar width))))))))

;;;; The mode line

(defun drgnx-statusbar--mru-editor-p (w)
  "Non-nil when W is its frame's most recently used editor window, as the workbench state store has it."
  (eq w (drgnx-state-editor-window (window-frame w))))

(defcustom drgnx-statusbar-modes '(prog-mode text-mode conf-mode)
  "Major modes (and the modes derived from them) whose buffers get the status bar.
So does any buffer that visits a file, and an Untitled editor.  Every other buffer (Magit, Dired, help, Info, shells,
compilation, drgnx's own panes) keeps its own mode line, except the start page (`drgnx-statusbar-quiet-modes')."
  :type '(repeat symbol) :set #'drgnx-statusbar--set :group 'drgnx-statusbar)

(defun drgnx-statusbar--own-mode-line-p ()
  "Non-nil when this buffer sets its own, non-nil `mode-line-format'."
  (and (local-variable-p 'mode-line-format) mode-line-format t))

(defun drgnx-statusbar--wanted-p ()
  "Non-nil when the current buffer gets the status bar: it visits a file, is an Untitled editor (New Untitled, in any
mode) or is code, text or configuration."
  (and (not (drgnx-statusbar--own-mode-line-p))
       (or buffer-file-name (bound-and-true-p drgnx-untitled-p)
           (and drgnx-statusbar-modes (apply #'derived-mode-p drgnx-statusbar-modes)))))

(defcustom drgnx-statusbar-quiet-modes '(drgnx-start-mode)
  "Major modes (and the modes derived from them) whose buffers get the quiet bar: the segments of
`drgnx-statusbar-quiet' on the left and nothing on the right (no line and column).  The start page is one: the first
screen never shows Emacs's raw mode line."
  :type '(repeat symbol) :set #'drgnx-statusbar--set :group 'drgnx-statusbar)

(defun drgnx-statusbar--quiet-p ()
  "Non-nil when the current buffer gets the quiet bar (`drgnx-statusbar-quiet-modes')."
  (and drgnx-statusbar-quiet-modes (not (drgnx-statusbar--own-mode-line-p))
       (apply #'derived-mode-p drgnx-statusbar-quiet-modes)))

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

;;;; The memo: a redisplay that changes nothing reuses the bar

(defvar drgnx-statusbar--memo (make-hash-table :test #'eq :weakness 'key)
  "Window → [KEY… BAR]: the bar last drawn there and the values it was drawn from (`drgnx-statusbar--memo-forms').
Weak on the window, so a deleted window's entry goes with it; emptied when the mode turns off.")

(defvar drgnx-statusbar-misc-exclude)

(defvar drgnx-statusbar--global :unset
  "While a bar renders: the text of `global-mode-string' it was keyed on (see `drgnx-statusbar--global-text').")

(eval-and-compile
  (defconst drgnx-statusbar--memo-forms
    '((current-buffer) (window-point w) (buffer-chars-modified-tick) drgnx-statusbar--tick width compact
      (point-min) (point-max) major-mode vc-mode buffer-file-coding-system indent-tabs-mode tab-width
      defining-kbd-macro mode-line-process default-directory (and mark-active (mark t))
      (drgnx-statusbar--selected-p w)
      (bound-and-true-p flymake-mode) (bound-and-true-p flymake--mode-line-counter-cache)
      (drgnx-statusbar--flymake-backends)
      (bound-and-true-p eglot--managed-mode) (bound-and-true-p eglot--cached-server) (drgnx-statusbar--eglot-live-p)
      (drgnx-statusbar--indent-width)
      (bound-and-true-p drgnx-trust--state) (bound-and-true-p drgnx-explorer--roots)
      (bound-and-true-p drgnx-modal-state) (bound-and-true-p drgnx-job-ui--badge) (bound-and-true-p drgnx-face-glyphs)
      (bound-and-true-p evil-mode-line-tag) (drgnx-statusbar--which-func w)
      ;; keycast's keys: a new vector after every command (its text changes even when nothing else did)
      (and (bound-and-true-p keycast-mode-line-mode) (bound-and-true-p keycast--this-command-keys))
      drgnx-statusbar-left drgnx-statusbar-right drgnx-statusbar-compact drgnx-statusbar-drop-order
      drgnx-statusbar-quiet
      global)
    "What a window's bar depends on, evaluated in its buffer with W the window, WIDTH its width, COMPACT whether it
shows the compact bar and GLOBAL the text of `global-mode-string' and of the other entries of `mode-line-misc-info'
\(`drgnx-statusbar--global-text').  Compared with `eql' (GLOBAL, the last, with
`equal'): a value that is the same object means the same text.  drgnx's own segments are covered by
`drgnx-statusbar--tick'; the rest are the buffer-locals and caches the default segments read.  A segment of your own
that shows something else is drawn again when point moves, the text changes or `(drgnx-statusbar-refresh t)' runs."))

(defmacro drgnx-statusbar--memo-hit-p (memo)
  "Non-nil when every value of `drgnx-statusbar--memo-forms' equals the one stored in the vector MEMO."
  (let ((i -1) (n (length drgnx-statusbar--memo-forms)))
    `(and (= (length ,memo) ,(1+ n))
          ,@(mapcar (lambda (f) (setq i (1+ i)) `(,(if (= i (1- n)) 'equal 'eql) (aref ,memo ,i) ,f))
                    drgnx-statusbar--memo-forms))))

(defmacro drgnx-statusbar--memo-make (bar)
  "A memo vector: the values of `drgnx-statusbar--memo-forms', then BAR."
  `(vector ,@drgnx-statusbar--memo-forms ,bar))

(defvar drgnx-statusbar-misc-info-skip)

(defun drgnx-statusbar--misc-info-others-p ()
  "Non-nil when `mode-line-misc-info' has an entry the bar does not show some other way
\(`drgnx-statusbar-misc-info-skip').  Compares, allocates nothing."
  (let ((l mode-line-misc-info) (found nil))
    (while (and (consp l) (not found))
      (let ((e (car l)))
        (unless (or (equal e "") (and (consp e) (memq (car e) drgnx-statusbar-misc-info-skip))) (setq found t)))
      (setq l (cdr l)))
    found))

(defun drgnx-statusbar--global-text ()
  "The text of `global-mode-string' without the entries of `drgnx-statusbar-misc-exclude', and of the entries of
`mode-line-misc-info' other packages added (not those of `drgnx-statusbar-misc-info-skip'), trimmed; nil when empty.
Other modules' marks change without telling the bar, so this runs on every redisplay of a bar: when no entry is left
to show, it compares and allocates nothing."
  (let* ((g global-mode-string)
         (global (cond ((stringp g) (let ((s (string-trim g))) (unless (string-empty-p s) s)))
                       ((and (consp g)
                             (let ((found nil))
                               (while (and g (not found))
                                 (unless (or (equal (car g) "") (member (car g) drgnx-statusbar-misc-exclude))
                                   (setq found t))
                                 (setq g (cdr g)))
                               found))
                        (let ((s (string-trim (or (drgnx-statusbar--construct-text
                                                   (seq-remove (lambda (e) (member e drgnx-statusbar-misc-exclude))
                                                               global-mode-string))
                                                  ""))))
                          (unless (string-empty-p s) s)))))
         (others (when (drgnx-statusbar--misc-info-others-p)
                   (let ((s (string-trim (format-mode-line
                                          (seq-remove (lambda (e) (and (consp e)
                                                                       (memq (car e) drgnx-statusbar-misc-info-skip)))
                                                      mode-line-misc-info)))))
                     (unless (string-empty-p s) s)))))
    (if (and global others) (concat others " " global) (or others global))))

(defun drgnx-statusbar--bar (w width compact)
  "The escaped bar of window W (WIDTH columns, COMPACT or full): the memoized one when nothing it shows changed."
  (let* ((global (drgnx-statusbar--global-text))
         (memo (gethash w drgnx-statusbar--memo)))
    (if (and memo (drgnx-statusbar--memo-hit-p memo))
        (aref memo (1- (length memo)))
      (let ((bar (let ((drgnx-statusbar--global global))
                   (drgnx-statusbar--escape (drgnx-statusbar-render width compact)))))
        (puthash w (drgnx-statusbar--memo-make bar) drgnx-statusbar--memo)
        bar))))

(defun drgnx-statusbar-mode-line ()
  "The `:eval' of an editor window's mode line.
In a buffer that visits a file, is an Untitled editor or is code, text or configuration (`drgnx-statusbar-modes'): the
full bar in the most recently used editor window, the compact one in the others.  In the start page
\(`drgnx-statusbar-quiet-modes'): the quiet bar.  In a buffer whose own `mode-line-format' is nil: nothing.  In any
other buffer: the stock mode line.  An error shows nothing and is recorded once, never on every redisplay."
  (condition-case err
      (cond ((and (local-variable-p 'mode-line-format) (null mode-line-format)) nil)
            ((drgnx-statusbar--wanted-p)
             (let* ((w (selected-window))       ; the window being drawn (a mode line is drawn with it selected)
                    (drgnx-statusbar--window w))
               (drgnx-statusbar--bar w (window-total-width w) (not (drgnx-statusbar--mru-editor-p w)))))
            ((drgnx-statusbar--quiet-p)
             (let* ((w (selected-window)) (drgnx-statusbar--window w))
               (drgnx-statusbar--bar w (window-total-width w) 'quiet)))
            (t (remhash (selected-window) drgnx-statusbar--memo)   ; no bar here now: keep no buffer alive for it
               (or mode-line-format (default-value 'mode-line-format))))
    (error (drgnx-statusbar--note-error 'host err) nil)))

(defvar drgnx-statusbar--last (make-vector 4 nil) "[BUFFER POINT TICK MARK-ACTIVE] as of the last command.")

(defun drgnx-statusbar--post-command ()
  "A mode line made by `:eval' does not know it shows the point: ask for a redraw when what it shows changed.
While Show Keys As I Type (keycast) is on, every command changes the bar: every bar is redrawn (the editor's too
when you type in a side pane)."
  (when (bound-and-true-p keycast-mode-line-mode) (force-mode-line-update t))
  (let ((l drgnx-statusbar--last) (b (current-buffer)))
    (let ((pt (window-point)) (tick (buffer-chars-modified-tick)))
      (unless (and (eq (aref l 0) b) (eql (aref l 1) pt) (eql (aref l 2) tick) (eq (aref l 3) mark-active))
        (aset l 0 b) (aset l 1 pt) (aset l 2 tick) (aset l 3 mark-active)
        (force-mode-line-update)))))             ; this buffer's mode line only

(defun drgnx-statusbar--editor-changed (&rest _)
  "On the store's `editor-changed' (the `now' lane, before the frame is drawn): the most recently used editor
window is another one now, so the full bar and the compact one trade places in every window."
  (force-mode-line-update t))

;;;; drgnx's side: state worked out when a hook says it changed, never on redisplay

(defvar drgnx-statusbar-tests-state nil
  "The last test run: (:passed N :failed N :at TIME :source SOURCE), or nil.  Set by `drgnx-statusbar-note-tests'.")

(defvar drgnx-statusbar--jobs-state nil
  "How many jobs run, as the hub last said; nil when it is not known (no hub, or it went away).")

(defvar drgnx-statusbar--agents-state nil "(BUSY . WAITING) as of the last refresh.")

(defvar drgnx-statusbar-waiting-functions (list #'drgnx-statusbar-agents-waiting)
  "Functions of no arguments, each returning how many things wait on you; the agents segment shows the sum.
They run when the bar refreshes (`drgnx-statusbar-refresh'), never on redisplay, so a module whose count changes
calls `drgnx-statusbar-refresh'.  One that signals or returns something else than a number counts nothing (and is
recorded in `drgnx-statusbar--errors' as `waiting').")

(defvar drgnx-statusbar-refresh-delay 0.2
  "Seconds `drgnx-statusbar-refresh' waits, so that a burst of changes is one refresh and one redraw.")

(defvar drgnx-statusbar--redraw-wanted nil "Non-nil: the next refresh redraws the bars even when no count changed.")
(defvar drgnx-statusbar--jobs-wanted nil "Non-nil: the next refresh asks the hub how many jobs run.")
(defvar drgnx-statusbar--jobs-pending nil "Non-nil while a `job/status' question is on its way to the hub.")

(defun drgnx-statusbar-refresh (&optional changed)
  "Bring drgnx's segments (agents, jobs, waiting counts) up to date and redraw the bars when they changed.
CHANGED non-nil: something a segment shows changed (a segment of your own): every bar is drawn again.
Debounced: the refresh runs once, `drgnx-statusbar-refresh-delay' seconds after the first call, however many calls
came in between.  Never blocks; safe in a hook, a timer or a process filter."
  (when changed
    (drgnx-statusbar--bump)
    (setq drgnx-statusbar--redraw-wanted t))
  (drgnx-timer-soon 'statusbar-refresh drgnx-statusbar-refresh-delay #'drgnx-statusbar--refresh-now :owner :core))

(defun drgnx-statusbar--refresh-now ()
  "The refresh itself: count again, bump the tick and redraw every bar when a count changed (or a redraw was asked).
Called directly, it takes the place of the pending one."
  (drgnx-timer-cancel 'statusbar-refresh)
  (let ((redraw drgnx-statusbar--redraw-wanted)
        (agents (drgnx-statusbar--agent-counts)))
    (setq drgnx-statusbar--redraw-wanted nil)
    (when (and drgnx-statusbar--jobs-wanted (not drgnx-statusbar--jobs-pending))   ; else: asked when it answers
      (setq drgnx-statusbar--jobs-wanted nil)
      (drgnx-statusbar--ask-jobs))
    (unless (equal agents drgnx-statusbar--agents-state)
      (setq drgnx-statusbar--agents-state agents redraw t))
    (when redraw
      (drgnx-statusbar--bump)                            ; else every window would reuse its memoized bar
      (force-mode-line-update t))))

(defun drgnx-statusbar-note-tests (passed failed &optional source)
  "Record a test run: PASSED and FAILED tests, SOURCE where it came from (the compilation buffer, which a click on
the `tests' segment shows, or what the work tracker knows it by).  The bars are redrawn on the next refresh."
  (setq drgnx-statusbar-tests-state (list :passed passed :failed failed :at (float-time) :source source))
  (drgnx-statusbar-refresh t))

(defcustom drgnx-statusbar-test-command-regexp "\\_<test\\_>"
  "A compilation whose command matches this (case-sensitively) is a test run: the `tests' segment shows its counts."
  :type 'regexp :group 'drgnx-statusbar)

(defcustom drgnx-statusbar-test-count-regexps
  '(("^\\(?:Aborted: \\)?Ran \\([0-9]+\\) tests, \\([0-9]+\\) results as expected, \\([0-9]+\\) unexpected"
     :passed 2 :failed 3)                                ; ERT (and `bin/drgnx test')
    ("^ui ERT: \\([0-9]+\\)/\\([0-9]+\\) passed" :passed 1 :total 2))   ; `bin/drgnx test --ui'
  "Summary lines of a test run: (REGEXP :passed GROUP :failed GROUP) or (REGEXP :passed GROUP :total GROUP).
The last line of the compilation that matches one of them gives the counts."
  :type '(repeat (cons regexp (plist :value-type integer))) :group 'drgnx-statusbar)

(defconst drgnx-statusbar--test-scan-bytes 65536 "How far back from its end a compilation is searched for a summary.")

(defun drgnx-statusbar--test-counts ()
  "(PASSED . FAILED) from the last line of this buffer that matches `drgnx-statusbar-test-count-regexps', or nil.
Only the last `drgnx-statusbar--test-scan-bytes' characters are searched."
  (save-excursion
    (save-restriction
      (widen)
      (let ((best nil) (best-pos (max (point-min) (- (point-max) drgnx-statusbar--test-scan-bytes)))
            (case-fold-search nil))
        (dolist (spec drgnx-statusbar-test-count-regexps)
          (goto-char (point-max))
          (when (re-search-backward (car spec) best-pos t)   ; only a later line than the best so far
            (let* ((group (lambda (k)
                            (when-let* ((g (plist-get (cdr spec) k)) (s (match-string g))) (string-to-number s))))
                   (passed (funcall group :passed)) (failed (funcall group :failed)) (total (funcall group :total)))
              (when passed
                (setq best-pos (point)
                      best (cons passed (or failed (max 0 (- (or total passed) passed)))))))))
        best))))

(defun drgnx-statusbar--compilation-finished (buffer _how)
  "On `compilation-finish-functions': when BUFFER ran tests (`drgnx-statusbar-test-command-regexp'), note the counts
of its last summary line.  The buffer is read once, here.  It runs in the compilation's sentinel: an error (a bad
regexp of yours) is recorded as `tests' in `drgnx-statusbar--errors', never signalled."
  (condition-case err
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (let ((command (car-safe (bound-and-true-p compilation-arguments))))
            (when (and (stringp command) (stringp drgnx-statusbar-test-command-regexp)
                       (with-syntax-table (standard-syntax-table)
                         (let ((case-fold-search nil)) (string-match-p drgnx-statusbar-test-command-regexp command))))
              (when-let* ((counts (drgnx-statusbar--test-counts)))
                (drgnx-statusbar-note-tests (car counts) (cdr counts) buffer))))))
    (error (setq drgnx-statusbar--errors (assq-delete-all 'tests drgnx-statusbar--errors))
           (drgnx-statusbar--note-error 'tests err))))

(defun drgnx-statusbar--hub-connected-p ()
  "Non-nil when this Emacs receives the hub's events."
  (and (boundp 'drgnx-hub--events) (process-live-p drgnx-hub--events)))

(defun drgnx-statusbar--ask-jobs ()
  "Ask the hub (asynchronously) how many jobs run, unless a question is already on its way; the answer redraws the
bars when the count changed."
  (when (and (fboundp 'drgnx-hub-call) (not drgnx-statusbar--jobs-pending))
    (setq drgnx-statusbar--jobs-pending t)
    (condition-case nil
        (drgnx-hub-call "job/status" nil #'drgnx-statusbar--jobs-answer)
      (error (setq drgnx-statusbar--jobs-pending nil)
             (drgnx-statusbar--set-jobs nil)))))

(defun drgnx-statusbar--jobs-answer (result err)
  "The hub's answer to `job/status' (RESULT, or the error message ERR): the running jobs are counted.
It runs in the hub client's process filter: nothing here signals.  A job event that came while the question was on
its way asks again."
  (setq drgnx-statusbar--jobs-pending nil)
  (drgnx-statusbar--set-jobs
   (condition-case nil
       (unless (or err (not (listp result)))
         (let ((n 0))
           (dolist (j (append (plist-get result :jobs) nil))
             (when (equal (plist-get j :status) "running") (setq n (1+ n))))
           n))
     (error nil)))
  (when drgnx-statusbar--jobs-wanted (drgnx-statusbar-refresh)))

(defun drgnx-statusbar--set-jobs (running)
  "RUNNING jobs (nil: not known); the bars are redrawn when that changed."
  (unless (eql running drgnx-statusbar--jobs-state)
    (setq drgnx-statusbar--jobs-state running)
    (drgnx-statusbar--bump)
    (force-mode-line-update t)))

(defun drgnx-statusbar--agents-changed (&rest _)
  "On `drgnx-agents-changed-functions': refresh (debounced)."
  (drgnx-statusbar-refresh))

(defun drgnx-statusbar--hub-event (event &rest _)
  "On `drgnx-hub-event-functions': refresh (debounced).  A job or a card EVENT asks the hub for the running jobs; so
does the first event after the hub connects (the count is not known yet: the hub has no connect hook)."
  (when (or (and (stringp event) (member event '("job" "card")))
            (and (null drgnx-statusbar--jobs-state) (drgnx-statusbar--hub-connected-p)))
    (setq drgnx-statusbar--jobs-wanted t))
  (drgnx-statusbar-refresh))

(defun drgnx-statusbar--hub-gone ()
  "On `drgnx-hub-disconnect-functions': the running jobs are not known any more (the question on its way is lost)."
  (setq drgnx-statusbar--jobs-wanted nil drgnx-statusbar--jobs-pending nil)
  (drgnx-statusbar--set-jobs nil))

(defvar drgnx-statusbar--git-branches (make-hash-table :test #'equal)
  "Repository root → the branch plist the bars were last redrawn for (one entry per repository git has read).
Emptied when `drgnx-statusbar-mode' turns off.")

(defun drgnx-statusbar--git-changed (&optional root &rest _)
  "On `drgnx-git-changed-functions' (ROOT's status was read): redraw the bars (debounced) when ROOT's branch or its
ahead and behind counts are not what the bars last drew; a status run that changed only files redraws nothing."
  (let ((branch (and root (fboundp 'drgnx-git-branch) (drgnx-git-branch root))))
    (unless (equal branch (gethash root drgnx-statusbar--git-branches))
      (puthash root branch drgnx-statusbar--git-branches)
      (setq drgnx-statusbar--redraw-wanted t)
      (drgnx-statusbar-refresh))))

(defvar drgnx-statusbar-git-ask-seconds 5
  "Seconds before the status bar asks drgnx's git cache again about the same repository.
A file whose repository is not known yet counts by its folder.")
(defvar drgnx-statusbar--git-asked nil
  "(REPOSITORY-OR-FOLDER . TIME) of the last time the bar asked the git cache to read.")

(defun drgnx-statusbar--ask-git (&rest _)
  "On `editor-changed' (the signal bus, when Emacs is idle; never redisplay): have drgnx's git cache read the
repository of the editor's file, at most every `drgnx-statusbar-git-ask-seconds' for one repository (one folder
while its repository is unknown).  The answer comes back through `drgnx-git-changed-functions' and redraws the
bars.  A remote file asks nothing."
  (when-let* (((fboundp 'drgnx-git-refresh))
              (w (and (fboundp 'drgnx-wb-editor-window) (drgnx-wb-editor-window)))
              (file (buffer-local-value 'buffer-file-name (window-buffer w)))
              ((not (file-remote-p file))))
    (let ((key (or (drgnx-git-cached-root file) (file-name-directory file)))     ; the repository, else the folder
          (now (drgnx-statusbar--now)) (asked drgnx-statusbar--git-asked))
      (unless (and asked (equal (car asked) key) (< (- now (cdr asked)) drgnx-statusbar-git-ask-seconds))
        (setq drgnx-statusbar--git-asked (cons key now))
        (drgnx-git-refresh file)))))

(defun drgnx-statusbar--flymake-reported (&rest _)
  "After a flymake backend reported (advice on `flymake--handle-report': flymake has no hook for it): redraw the bars,
debounced, so the problems count follows reports that arrive while you do nothing.  Idempotent; removed with the mode."
  (drgnx-statusbar-refresh t))

(defconst drgnx-statusbar--host '(:eval (drgnx-statusbar-mode-line)))

(defconst drgnx-statusbar--hooks
  '((post-command-hook . drgnx-statusbar--post-command)
    (drgnx-agents-changed-functions . drgnx-statusbar--agents-changed)
    (drgnx-hub-event-functions . drgnx-statusbar--hub-event)
    (drgnx-hub-disconnect-functions . drgnx-statusbar--hub-gone)
    (drgnx-git-changed-functions . drgnx-statusbar--git-changed)
    (compilation-finish-functions . drgnx-statusbar--compilation-finished))
  "The global hooks the status bar is on while `drgnx-statusbar-mode' is, and only then.")

(define-minor-mode drgnx-statusbar-mode
  "The status bar in the editor windows in place of the raw mode line."
  :global t :group 'drgnx-statusbar
  (setq drgnx-chrome-editor-mode-line (if drgnx-statusbar-mode drgnx-statusbar--host drgnx-chrome--mode-line))
  (if drgnx-statusbar-mode
      (progn
        (dolist (h drgnx-statusbar--hooks) (add-hook (car h) (cdr h)))
        (drgnx-state-subscribe 'editor-changed #'drgnx-statusbar--editor-changed :lane 'now)
        (drgnx-signal-subscribe 'editor-changed #'drgnx-statusbar--ask-git)
        (advice-add 'flymake--handle-report :after #'drgnx-statusbar--flymake-reported)   ; flymake has no hook for this
        (when (fboundp 'drgnx-modal-indicator-off) (drgnx-modal-indicator-off))   ; the bar shows the modal state
        (setq drgnx-statusbar--agents-state (drgnx-statusbar--agent-counts))
        (when (drgnx-statusbar--hub-connected-p)            ; connected: count the jobs
          (setq drgnx-statusbar--jobs-wanted t)
          (drgnx-statusbar-refresh)))
    (dolist (h drgnx-statusbar--hooks) (remove-hook (car h) (cdr h)))
    (drgnx-state-unsubscribe 'editor-changed #'drgnx-statusbar--editor-changed)
    (drgnx-signal-unsubscribe 'editor-changed #'drgnx-statusbar--ask-git)
    (advice-remove 'flymake--handle-report #'drgnx-statusbar--flymake-reported)
    (drgnx-timer-cancel 'statusbar-refresh)
    (clrhash drgnx-statusbar--memo)
    (clrhash drgnx-statusbar--git-branches)
    (when (fboundp 'drgnx-modal-indicator-on) (drgnx-modal-indicator-on)))
  (drgnx-statusbar--bump)
  (dolist (f (frame-list)) (drgnx-chrome-apply f))
  (force-mode-line-update t))

;;;; The default segments (cached state only)

(defun drgnx-statusbar--glyph (name &optional fallback)
  "The glyph NAME for the frame being drawn (ASCII on a terminal that is not UTF-8); FALLBACK (default \"\") when
the glyph table has no NAME."
  (or (and (fboundp 'drgnx-face-glyph) (drgnx-face-glyph name (window-frame (drgnx-statusbar-source-window))))
      fallback ""))

(defun drgnx-statusbar--separator ()
  "What goes between the left segments: the glyph `sep' (` · ', or ` | ' in ASCII)."
  (let ((s (drgnx-statusbar--glyph 'sep))) (if (string-empty-p s) " · " s)))

(defun drgnx-statusbar--git-branch ()
  "The branch of this buffer's repository from drgnx's git cache, or nil: not a local repository, or not read yet.
Reads the cache only (a remote buffer has no entry)."
  (when-let* ((file (or buffer-file-name default-directory))
              (root (drgnx-git-cached-root file)))
    (drgnx-git-branch root)))

(defun drgnx-statusbar--seg-branch ()
  "`⑂ main ↑2 ↓1' from drgnx's git cache (ahead and behind its upstream, when it has one and they are not 0).
Without a cache entry (a remote file, a repository not read yet) the branch git put in `vc-mode' (\" Git-main\"), or
nothing."
  (if-let* ((b (drgnx-statusbar--git-branch)))
      (let ((ahead (plist-get b :ahead)) (behind (plist-get b :behind)))
        (concat (drgnx-statusbar--glyph 'branch) " " (or (plist-get b :head) "(detached)")
                (and ahead (> ahead 0) (format " %s%d" (drgnx-statusbar--glyph 'ahead) ahead))
                (and behind (> behind 0) (format " %s%d" (drgnx-statusbar--glyph 'behind) behind))))
    (when (and (stringp vc-mode) (string-match "\\`[ ]*[[:alpha:]]+[-:@!?]\\(.+\\)" (substring-no-properties vc-mode)))
      (concat (drgnx-statusbar--glyph 'branch) " " (match-string 1 (substring-no-properties vc-mode))))))

(defun drgnx-statusbar--flymake-count (type)
  "How many problems of TYPE flymake counts in this buffer (flymake caches the count until diagnostics change)."
  (let ((c (flymake--mode-line-counter type)))
    (or (and (consp c) (consp (nth 1 c)) (stringp (nth 1 (nth 1 c))) (string-to-number (nth 1 (nth 1 c)))) 0)))

(defun drgnx-statusbar--seg-problems ()
  (when (and (bound-and-true-p flymake-mode) (fboundp 'flymake--mode-line-counter))
    (let ((e (drgnx-statusbar--flymake-count :error)) (w (drgnx-statusbar--flymake-count :warning)))
      (cond
       ((or (> e 0) (> w 0))
        ;; `⚠ E W': the errors in the error face, the warnings in the warning face, a zero dimmed
        (concat (drgnx-statusbar--glyph 'warning) " "
                (propertize (number-to-string e) 'face (if (> e 0) 'error 'shadow)) " "
                (propertize (number-to-string w) 'face (if (> w 0) 'warning 'shadow))))
       ;; a backend that has not reported yet: not "no problems" (as in stock flymake's Wait)
       ((cl-set-difference (flymake-running-backends) (flymake-reporting-backends))
        (propertize (drgnx-statusbar--glyph 'waiting) 'face 'shadow))
       ;; only notes (shown in the fringe and at the ends of lines): their count, dimmed, never "all clear"
       ((> (drgnx-statusbar--flymake-count :note) 0)
        (propertize (format "%s %d" (drgnx-statusbar--glyph 'dot) (drgnx-statusbar--flymake-count :note))
                    'face 'shadow))
       ((flymake-reporting-backends) (propertize (drgnx-statusbar--glyph 'ok) 'face 'success))))))

(defvar drgnx-statusbar--state-texts (make-hash-table :test #'eq)
  "Segment ID → [TICK SEP EXTRA TEXT]: the text of one of drgnx's own segments as of `drgnx-statusbar--tick', the
separator glyph in use (it stands for the frame's glyph set) and EXTRA.  One entry per segment ID.")

(defun drgnx-statusbar--state-text (id fn &optional extra)
  "The text FN makes for segment ID, made again only when the tick, the glyph set or EXTRA (compared with `eq')
changed: drgnx's own segments are worked out once per change of their state, not per bar."
  (let ((c (gethash id drgnx-statusbar--state-texts))
        (glyphs (drgnx-statusbar--glyph 'sep)))           ; the same string object while the glyph set is the same
    (if (and c (eql (aref c 0) drgnx-statusbar--tick) (eq (aref c 1) glyphs) (eq (aref c 2) extra))
        (aref c 3)
      (let ((s (funcall fn)))
        (puthash id (vector drgnx-statusbar--tick glyphs extra s) drgnx-statusbar--state-texts)
        s))))

(defun drgnx-statusbar--seg-tests ()
  "`✓ tests 41/41' or `✕ tests 2 failed', from the last test run (`drgnx-statusbar-note-tests')."
  (drgnx-statusbar--state-text
   'tests
   (lambda ()
     (when-let* ((st drgnx-statusbar-tests-state))
       (let ((passed (or (plist-get st :passed) 0)) (failed (or (plist-get st :failed) 0)))
         (if (> failed 0)
             (propertize (format "%s tests %d failed" (drgnx-statusbar--glyph 'close) failed) 'face 'error)
           (concat (propertize (drgnx-statusbar--glyph 'ok) 'face 'success)
                   (format " tests %d/%d" passed (+ passed failed)))))))))

(defun drgnx-statusbar--click-tests ()
  "Show where the last test run came from (its compilation buffer)."
  (let ((source (plist-get drgnx-statusbar-tests-state :source)))
    (if (buffer-live-p source) (pop-to-buffer source) (message "drgnx: the last test run has no output to show"))))

(defun drgnx-statusbar--cards-waiting ()
  "How many things of jobs wait on you: C8's one count (`drgnx-job-ui-needs-you'); 0 when it is not known."
  (or (and (fboundp 'drgnx-job-ui-needs-you) (drgnx-job-ui-needs-you)) 0))

(defun drgnx-statusbar--seg-jobs ()
  "`◎ 2 jobs' (running, as the hub last said) and `⚑N' when cards of jobs wait on you (`drgnx-job-ui-needs-you')."
  (drgnx-statusbar--state-text
   'jobs
   (lambda ()
     (let* ((running drgnx-statusbar--jobs-state) (cards (drgnx-statusbar--cards-waiting))
            (text (string-join
                   (delq nil (list (and running (> running 0)
                                        (format "%s %d job%s" (drgnx-statusbar--glyph 'busy) running
                                                (if (= running 1) "" "s")))
                                   (and (> cards 0)
                                        (propertize (format "%s%d" (drgnx-statusbar--glyph 'flag "#") cards)
                                                    'face 'warning))))
                   " ")))
       (unless (string-empty-p text) text)))
   (and (boundp 'drgnx-job-ui--badge) drgnx-job-ui--badge)))

(defun drgnx-statusbar-agents-waiting ()
  "How many permission requests and edits to review the agent sessions hold for you (on
`drgnx-statusbar-waiting-functions')."
  (let ((n 0))
    (when (fboundp 'drgnx-agents-sessions)
      (dolist (s (drgnx-agents-sessions))
        (setq n (+ n (length (drgnx-agent-session-permissions s)) (length (drgnx-agent-session-reviews s))))))
    n))

(defun drgnx-statusbar--waiting ()
  "The sum of `drgnx-statusbar-waiting-functions' (one that fails or says no number counts nothing)."
  (let ((sum 0))
    (run-hook-wrapped 'drgnx-statusbar-waiting-functions
                      (lambda (f)
                        (let ((n (condition-case err (funcall f)
                                   (error (drgnx-statusbar--note-error 'waiting err) 0))))
                          (if (numberp n)
                              (setq sum (+ sum n))
                            (drgnx-statusbar--note-error 'waiting (list 'error (format "%S returned %S" f n)))))
                        nil))
    sum))

(defun drgnx-statusbar--agent-counts ()
  "(BUSY . WAITING): agents working (from the sessions drgnx holds), and the things waiting on you."
  (let ((busy 0))
    (when (and (fboundp 'drgnx-agents-sessions) (fboundp 'drgnx-agent-session-status))
      (dolist (s (drgnx-agents-sessions))
        (when (eq (drgnx-agent-session-status s) 'busy) (setq busy (1+ busy)))))
    (cons busy (drgnx-statusbar--waiting))))

(defun drgnx-statusbar--seg-agents ()
  "`◎ 1 busy' and `◐ 1 waiting on you' (in `drgnx-statusbar-waiting'), as of the last refresh."
  (drgnx-statusbar--state-text
   'agents
   (lambda ()
     (when-let* ((c drgnx-statusbar--agents-state))
       (let* ((busy (car c)) (waiting (cdr c))
              (text (string-join
                     (delq nil (list (and (> busy 0) (format "%s %d busy" (drgnx-statusbar--glyph 'busy) busy))
                                     (and (> waiting 0)
                                          (propertize (format "%s %d waiting on you"
                                                              (drgnx-statusbar--glyph 'waiting) waiting)
                                                      'face 'drgnx-statusbar-waiting))))
                     " ")))
         (unless (string-empty-p text) text))))))

(defcustom drgnx-statusbar-misc-exclude '((:eval (drgnx-job-ui--badge-segment)) (:eval (drgnx-trust--mark)))
  "Entries of `global-mode-string' the `misc' segment leaves out because the bar already shows them (the job badge,
the Restricted Mode mark: the `trust' segment)."
  :type 'sexp :set #'drgnx-statusbar--set :group 'drgnx-statusbar)

(defun drgnx-statusbar--construct-text (c)
  "The text of the mode-line construct C: a string as it is, a list of strings joined, anything else formatted.
Only what the mode line already holds (no lookups)."
  (cond ((null c) nil)
        ((stringp c) c)
        ((and (consp c) (seq-every-p #'stringp c)) (apply #'concat c))
        (t (format-mode-line c))))

(defcustom drgnx-statusbar-misc-info-skip '(global-mode-string which-function-mode which-func-mode eglot--managed-mode)
  "Entries of `mode-line-misc-info' the `misc' segment does not format: those (SYMBOL …) whose SYMBOL is here.
`global-mode-string' and which-function are shown from what they hold (the function's name from which-func's own
cache); eglot's entry is what the `lsp' segment shows.  Every other entry another package adds shows in `misc'."
  :type '(repeat symbol) :set #'drgnx-statusbar--set :group 'drgnx-statusbar)

(defun drgnx-statusbar--which-func (w)
  "The function name `which-function-mode' cached for window W (its idle timer fills the table), or nil: off, not
in this buffer, or shown in the header line instead (`which-func-display').  A table read, nothing is worked out."
  (and (bound-and-true-p which-function-mode) (bound-and-true-p which-func-mode)
       (memq (bound-and-true-p which-func-display) '(mode mode-and-header))
       (boundp 'which-func-table) (hash-table-p which-func-table)
       (let ((name (gethash w which-func-table))) (and (stringp name) name))))

(defun drgnx-statusbar--evil-tag ()
  "evil's state tag (\" <N> \") while evil is on in this buffer and drgnx's modal core shows no state here (evil
set up without editor/evil: `drgnx-modal-mode-line' is \"\")."
  (and (bound-and-true-p evil-local-mode) (bound-and-true-p evil-mode-line-format)
       (not (and (fboundp 'drgnx-modal-mode-line) (not (equal (drgnx-modal-mode-line) ""))))
       (let ((tag (bound-and-true-p evil-mode-line-tag))) (and (stringp tag) tag))))

(defun drgnx-statusbar--keycast ()
  "The key and command of Show Keys As I Type (`keycast-mode-line-mode'), formatted by keycast, or nil."
  (and (bound-and-true-p keycast-mode-line-mode) (fboundp 'keycast-format)
       (let ((s (keycast-format (bound-and-true-p keycast-mode-line-format)))) (and (stringp s) s))))

(defun drgnx-statusbar--trim (s)
  "S without the spaces at its ends (no regexp: this runs whenever the bar is built)."
  (let ((b 0) (e (length s)))
    (while (and (< b e) (memq (aref s b) '(?\s ?\t ?\n))) (setq b (1+ b)))
    (while (and (> e b) (memq (aref s (1- e)) '(?\s ?\t ?\n))) (setq e (1- e)))
    (if (and (= b 0) (= e (length s))) s (substring s b e))))

(defun drgnx-statusbar--seg-misc ()
  "What stock Emacs would show beside the file: evil's state tag, keycast's key, a keyboard macro being recorded,
narrowing, a remote directory, the process of the buffer, which-function's name, the entries other packages added to
`mode-line-misc-info' and `global-mode-string' (without the job badge)."
  (let* ((global (if (eq drgnx-statusbar--global :unset) (drgnx-statusbar--global-text) drgnx-statusbar--global))
         (which (drgnx-statusbar--which-func (drgnx-statusbar-source-window)))
         (parts (delq nil
                      (list (drgnx-statusbar--evil-tag)
                            (drgnx-statusbar--keycast)
                            (and defining-kbd-macro
                                 (propertize (format "%s Rec" (drgnx-statusbar--glyph 'dot)) 'face 'error))
                            (and (buffer-narrowed-p) "Narrowed")
                            (when-let* (((stringp default-directory))
                                        ;; parses the name, no connection
                                        (host (file-remote-p default-directory 'host))
                                        ((not (string-empty-p host))))
                              (format "Remote: %s" host))
                            (drgnx-statusbar--construct-text mode-line-process)
                            (and which (propertize which 'face 'which-func))
                            (drgnx-statusbar--construct-text global)))))
    (let ((text (string-join (seq-remove #'string-empty-p (mapcar #'drgnx-statusbar--trim parts)) " ")))
      (unless (string-empty-p text) text))))

(defun drgnx-statusbar--seg-modal ()
  (when (fboundp 'drgnx-modal-mode-line)
    (let ((m (drgnx-modal-mode-line)))
      (cond ((stringp m) m) (m (format-mode-line m))))))

(defun drgnx-statusbar--lsp-name (server)
  "The name SERVER told eglot when it started (\"pyright\"), or nil: eglot's own cache, nothing is asked."
  (when (and server (fboundp 'eglot--server-info))
    (let ((name (plist-get (ignore-errors (eglot--server-info server)) :name)))
      (and (stringp name) (not (string-empty-p name)) name))))

(defun drgnx-statusbar--seg-lsp ()
  "Eglot's own cache: its server for this buffer (nothing is looked up)."
  (when (bound-and-true-p eglot--managed-mode)
    (let ((server (bound-and-true-p eglot--cached-server)))
      (format "LSP%s %s"
              (if-let* ((name (drgnx-statusbar--lsp-name server))) (concat ": " name) "")
              (cond ((null server) (drgnx-statusbar--glyph 'circle))
                    ((and (fboundp 'jsonrpc-running-p) (not (jsonrpc-running-p server)))
                     (drgnx-statusbar--glyph 'close))
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

(defun drgnx-statusbar--selected-p (w)
  "Non-nil when W is the window you are in (a part of the memo's key: only that window shows a selection).
While a mode line is drawn, its window is the selected one (the frame's too): `mode-line-window-selected-p' knows the
real one."
  (and (window-live-p w) (eq w (selected-window)) (mode-line-window-selected-p)))

(defun drgnx-statusbar--seg-position ()
  (let* ((w (drgnx-statusbar-source-window))
         (pt (if (eq (window-buffer w) (current-buffer)) (window-point w) (point))))
    (save-excursion
      (goto-char pt)
      (let* ((bol (pos-bol))
             (col (if (> (- pt bol) 2000) (- pt bol) (current-column))))   ; a minified line: characters, not columns
        (format "Ln %d, Col %d%s" (drgnx-statusbar--line-at bol) (1+ col)
                (if (and (drgnx-statusbar--selected-p w) (use-region-p))
                    (format " (%d selected)" (abs (- (mark t) pt)))
                  ""))))))

(defvar-local drgnx-statusbar--indent-cache nil
  "(TICK TABS SPACES MIN-SPACES): what the start of this buffer's text indents with, as of the buffer's change TICK.")

(defun drgnx-statusbar--indent-scan ()
  "The indentation the first 300 lines use, as (TICK TABS SPACES MIN-SPACES): lines that start with a tab, lines that
start with two or more spaces, and the least number of those spaces (a lone space is alignment).  Cached on the buffer's
change tick, so redisplay scans again only after an edit; reads the buffer only."
  (let ((tick (buffer-chars-modified-tick)) (c drgnx-statusbar--indent-cache))
    (if (eql (car c) tick)
        c
      (setq drgnx-statusbar--indent-cache
            (save-match-data
              (save-excursion
                (save-restriction
                  (widen)
                  (goto-char (point-min))
                  (let ((n 0) (tabs 0) (spaces 0) (least nil))
                    (while (and (< n 300) (not (eobp)))
                      (let ((ch (char-after)))
                        (cond ((eq ch ?\t) (setq tabs (1+ tabs)))
                              ((and (eq ch ?\s) (looking-at " \\{2,\\}[^ \t\n]"))
                               (let ((w (- (match-end 0) (point) 1)))
                                 (setq spaces (1+ spaces) least (if least (min least w) w))))))
                      (forward-line 1)
                      (setq n (1+ n)))
                    (list tick tabs spaces least)))))))))

(defun drgnx-statusbar--indent-tabs-p ()
  "Non-nil when this buffer is indented with tabs: what its first lines use, else `indent-tabs-mode'."
  (let ((c (drgnx-statusbar--indent-scan)))
    (cond ((> (nth 1 c) (nth 2 c)) t)
          ((> (nth 2 c) 0) nil)
          (t indent-tabs-mode))))

(defun drgnx-statusbar--indent-width ()
  "The indentation width the `indent' segment shows: `tab-width' with tabs, else the least indent of the buffer's own
space-indented lines, else the first of `drgnx-statusbar-indent-vars' that is bound to a natural number.  Part of the
memo's key: no allocation beyond the scan's cache."
  (if (drgnx-statusbar--indent-tabs-p)
      tab-width
    (or (nth 3 (drgnx-statusbar--indent-scan))
        (let ((vars drgnx-statusbar-indent-vars) (found nil))
          (while (and vars (not found))
            (let ((v (car vars)))
              (when (and (boundp v) (natnump (symbol-value v))) (setq found (symbol-value v))))
            (setq vars (cdr vars)))
          (or found tab-width)))))

(defun drgnx-statusbar--seg-indent ()
  (format (if (drgnx-statusbar--indent-tabs-p) "Tab Size: %d" "Spaces: %d") (drgnx-statusbar--indent-width)))

(defun drgnx-statusbar--seg-trust ()
  "`Restricted Mode' while this file's folder is not trusted (drgnx-trust.el keeps the state; nothing is read)."
  (when (eq (bound-and-true-p drgnx-trust--state) 'restricted)
    (propertize "Restricted Mode" 'face 'drgnx-trust-restricted)))

(defun drgnx-statusbar--seg-folder ()
  "The folder the Explorer shows (the first, and how many more), else `No folder open'."
  (let ((roots (bound-and-true-p drgnx-explorer--roots)))
    (if roots
        (concat (file-name-nondirectory (directory-file-name (car roots)))
                (if (cdr roots) (format " +%d" (length (cdr roots))) ""))
      "No folder open")))

(defun drgnx-statusbar--flymake-backends ()
  "Flymake's backends that run and that reported, as one number (a part of the memo's key), 0 without flymake."
  (if (and (bound-and-true-p flymake-mode) (fboundp 'flymake-running-backends))
      (+ (* 1024 (length (flymake-running-backends))) (length (flymake-reporting-backends)))
    0))

(defun drgnx-statusbar--eglot-live-p ()
  "Non-nil when eglot's server for this buffer is running (a part of the memo's key)."
  (and (bound-and-true-p eglot--cached-server) (fboundp 'jsonrpc-running-p)
       (ignore-errors (jsonrpc-running-p eglot--cached-server))))

(defun drgnx-statusbar--seg-encoding ()
  (when-let* ((cs buffer-file-coding-system)
              (charset (or (coding-system-get cs :mime-charset) (coding-system-base cs))))
    (if (memq charset '(undecided prefer-utf-8)) "UTF-8" (upcase (symbol-name charset)))))   ; plain ASCII is undecided

(defun drgnx-statusbar--seg-eol ()
  (pcase (and buffer-file-coding-system (coding-system-eol-type buffer-file-coding-system))
    (1 "CRLF") (2 "CR") (_ "LF")))

(defvar drgnx-statusbar--language-names (make-hash-table :test #'eq)
  "Major mode → the language name the `language' segment shows, worked out the first time the mode is drawn.
One entry per major mode used in the session; emptied when `drgnx-statusbar-language-names' changes.")

(defcustom drgnx-statusbar-language-names
  '((emacs-lisp-mode . "Emacs Lisp") (lisp-interaction-mode . "Emacs Lisp") (lisp-data-mode . "Lisp")
    (sh-mode . "Shell Script") (bash-ts-mode . "Shell Script") (c-mode . "C") (c-ts-mode . "C")
    (c++-mode . "C++") (c++-ts-mode . "C++") (csharp-mode . "C#") (csharp-ts-mode . "C#")
    (js-mode . "JavaScript") (js-ts-mode . "JavaScript") (js-json-mode . "JSON") (tsx-ts-mode . "TypeScript JSX")
    (html-mode . "HTML") (mhtml-mode . "HTML") (html-ts-mode . "HTML") (nxml-mode . "XML")
    (text-mode . "Plain Text") (fundamental-mode . "Plain Text") (makefile-mode . "Makefile")
    (makefile-gmake-mode . "Makefile") (conf-toml-mode . "TOML") (sql-mode . "SQL")
    (markdown-mode . "Markdown") (markdown-ts-mode . "Markdown") (gfm-mode . "Markdown")
    (yaml-mode . "YAML") (yaml-ts-mode . "YAML") (json-mode . "JSON") (json-ts-mode . "JSON") (toml-ts-mode . "TOML")
    (css-mode . "CSS") (css-ts-mode . "CSS"))
  "Major mode → the language name the status bar shows for it (as VS Code names it).
A mode not listed shows its own name (`mode-name') when that is a plain name of the mode (Rust, Go, Python, YAML),
else a name made from the mode's symbol."
  :type '(alist :key-type symbol :value-type string)
  :set (lambda (symbol value)
         (clrhash drgnx-statusbar--language-names)
         (drgnx-statusbar--set symbol value))
  :group 'drgnx-statusbar)

(defun drgnx-statusbar--language-name (mode)
  "The language name of MODE (see `drgnx-statusbar-language-names'), worked out from the current buffer's
`mode-name' when it is in MODE."
  (or (alist-get mode drgnx-statusbar-language-names)
      (let ((own (and (eq major-mode mode) (stringp mode-name) (substring-no-properties mode-name)))
            (base (replace-regexp-in-string "\\(-ts\\)?-mode\\'" "" (symbol-name mode))))
        (if (and own (not (string-match-p "[][/]" own))
                 ;; the mode's own name for itself ("Rust" for rust-ts-mode), not the name of something else
                 (string-prefix-p (replace-regexp-in-string " " "-" (downcase own)) (symbol-name mode)))
            own
          (capitalize (replace-regexp-in-string "-" " " base))))))

(defun drgnx-statusbar--seg-language ()
  "The language of the buffer, as VS Code names it: worked out once per major mode, a table read after that."
  (or (gethash major-mode drgnx-statusbar--language-names)
      (puthash major-mode (drgnx-statusbar--language-name major-mode) drgnx-statusbar--language-names)))

(defun drgnx-statusbar--major-modes ()
  "The major modes to choose from: those files and interpreters are mapped to, those remapped, and what derives
from another (`define-derived-mode')."
  (let ((modes (list 'fundamental-mode 'text-mode 'prog-mode)))
    (dolist (alist (list auto-mode-alist interpreter-mode-alist magic-mode-alist major-mode-remap-alist))
      (dolist (e alist)
        (let ((m (cdr e)))
          (when (consp m) (setq m (car m)))            ; (REGEXP FUNCTION FLAG) in `auto-mode-alist'
          (when (and (symbolp m) m (commandp m)) (push m modes)))))
    (mapatoms (lambda (s) (when (and (get s 'derived-mode-parent) (commandp s)) (push s modes))))
    (sort (delete-dups modes) #'string<)))

(defun drgnx-statusbar-change-mode (mode)
  "Switch this buffer to the major mode MODE (asked with completion), honouring `major-mode-remap-alist'.
Click the language in the status bar for it.  A command: it asks; the bar itself never does."
  (interactive
   (list (intern (completing-read (format-prompt "Major mode" (symbol-name major-mode))
                                  (mapcar #'symbol-name (drgnx-statusbar--major-modes)) nil t nil nil
                                  (symbol-name major-mode)))))
  (funcall (or (and (fboundp 'major-mode-remap) (major-mode-remap mode)) mode))
  (force-mode-line-update))

(defun drgnx-statusbar--click-branch ()
  (interactive)
  (if (fboundp 'magit-status) (call-interactively 'magit-status) (call-interactively 'vc-dir)))

(defun drgnx-statusbar--define-defaults ()
  "Define the segments the bar ships with."
  (drgnx-statusbar-define-segment 'branch :fn #'drgnx-statusbar--seg-branch :click #'drgnx-statusbar--click-branch
                                  :help "Branch; click for the repository status")
  (drgnx-statusbar-define-segment 'trust :fn #'drgnx-statusbar--seg-trust :click 'drgnx-trust-folder
                                  :help (if (boundp 'drgnx-trust--mark-help) drgnx-trust--mark-help
                                          "Restricted Mode: this folder is not trusted; click to trust it"))
  (drgnx-statusbar-define-segment 'folder :fn #'drgnx-statusbar--seg-folder :click 'drgnx-session-open-folder
                                  :help "The folder in the Explorer; click to open another")
  (drgnx-statusbar-define-segment 'problems :fn #'drgnx-statusbar--seg-problems :click 'flymake-show-buffer-diagnostics
                                  :help "Problems in this file; click to list them")
  (drgnx-statusbar-define-segment 'tests :fn #'drgnx-statusbar--seg-tests :click #'drgnx-statusbar--click-tests
                                  :help "The last test run; click for its output")
  (drgnx-statusbar-define-segment 'jobs :fn #'drgnx-statusbar--seg-jobs :click 'drgnx-cockpit-show-jobs
                                  :help "Jobs; click for what they need of you")
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
                                  :help "Indentation of this file (tabs or spaces, as its first lines use them); click to switch what new lines use")
  (drgnx-statusbar-define-segment 'encoding :fn #'drgnx-statusbar--seg-encoding :click 'set-buffer-file-coding-system
                                  :help "File encoding; click to change it")
  (drgnx-statusbar-define-segment 'eol :fn #'drgnx-statusbar--seg-eol :click 'set-buffer-file-coding-system
                                  :help "Line endings; click to change them")
  (drgnx-statusbar-define-segment 'language :fn #'drgnx-statusbar--seg-language :click 'drgnx-statusbar-change-mode
                                  :help "Language (major mode); click to change it"))

;;;; Setup (called by the module ui/face)

(defun drgnx-statusbar-setup ()
  "Define the command and the default segments and turn the status bar on."
  (drgnx-command-define 'statusbar-toggle :category "View" :title "Toggle Status Bar" :menu '("View")
                        :command #'drgnx-statusbar-mode
                        :doc "Show the status bar (branch, problems, position, language …) or the plain mode line")
  (drgnx-command-define 'statusbar-change-mode :category "Edit" :title "Change Language Mode"
                        :command #'drgnx-statusbar-change-mode
                        :doc "Switch this buffer's major mode (the language in the status bar), chosen with completion")
  (drgnx-statusbar--define-defaults)
  (drgnx-statusbar-mode 1))

(provide 'drgnx-statusbar)
;;; drgnx-statusbar.el ends here
