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
  "Alist ID → message of the last error a segment function signalled (once per segment, never a message).")

(defvar drgnx-statusbar--window nil
  "The window a bar is being drawn for (bound while it renders); nil: the most recently used editor window.")

(cl-defun drgnx-statusbar-define-segment (id &key fn click help)
  "Define (or replace) the segment ID.
FN takes no arguments and returns a string or nil; it runs with the buffer of `drgnx-statusbar-source-window'
current and may read only cached state.  CLICK is a command symbol or a function, run when the text is clicked.
HELP is the text shown when the pointer rests on the segment."
  (puthash id (list :fn fn :click click :help help) drgnx-statusbar--segments)
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
  "Record ERR as the error of segment ID (replacing the last one: the record never grows)."
  (setf (alist-get id drgnx-statusbar--errors) (error-message-string err)))

(defun drgnx-statusbar--text (id)
  "The text of segment ID with its properties, or nil when it has nothing to say (or failed)."
  (when-let* ((seg (gethash id drgnx-statusbar--segments))
              (fn (plist-get seg :fn))
              (s (condition-case err (funcall fn) (error (drgnx-statusbar--note-error id err) nil)))
              ((stringp s)) ((not (string-empty-p s))))
    (let ((s (copy-sequence s)))
      (add-text-properties 0 (length s)
                           (list 'drgnx-statusbar-segment id 'local-map drgnx-statusbar--map
                                 'mouse-face 'mode-line-highlight
                                 'help-echo (or (plist-get seg :help) (symbol-name id)))
                           s)
      s)))

;;;; Layout

(defconst drgnx-statusbar--left-sep " · ")
(defconst drgnx-statusbar--right-sep "  ")
(defconst drgnx-statusbar--branch-min 14 "Columns the branch is cut to before other segments are dropped for it.")

(defun drgnx-statusbar--run-width (segs sep)
  "Columns of the texts in SEGS (an alist ID → text) joined by SEP."
  (if segs (+ (apply #'+ (mapcar (lambda (s) (string-width (cdr s))) segs)) (* (string-width sep) (1- (length segs)))) 0))

(defun drgnx-statusbar--total (left right)
  "Columns of the bar with these LEFT and RIGHT segments: a pad on each side and at least two between."
  (+ 2 (drgnx-statusbar--run-width left drgnx-statusbar--left-sep)
     (drgnx-statusbar--run-width right drgnx-statusbar--right-sep)
     (if (and left right) 2 0)))

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
          (if (<= (string-width bar) width) bar (truncate-string-to-width bar (max width 0) nil nil t)))))))

;;;; The mode line

(defun drgnx-statusbar--mru-editor-p (w)
  "Non-nil when W is its frame's most recently used editor window."
  (let ((mru (if (eq (window-frame w) (selected-frame))
                 (drgnx-wb-editor-window)
               (seq-find #'drgnx-signal-editor-window-p (window-list (window-frame w) 'nomini)))))
    (or (null mru) (eq w mru))))

(defun drgnx-statusbar-mode-line ()
  "The `:eval' of an editor window's mode line: the full bar in the most recently used editor window, the compact
one in the others; nothing in a buffer whose own `mode-line-format' is nil."
  (unless (and (local-variable-p 'mode-line-format) (null mode-line-format))
    (let* ((w (selected-window))                ; the window being drawn (a mode line is drawn with it selected)
           (drgnx-statusbar--window w))
      (drgnx-statusbar-render (window-total-width w) (not (drgnx-statusbar--mru-editor-p w))))))

(defconst drgnx-statusbar--host '(:eval (drgnx-statusbar-mode-line)))

(define-minor-mode drgnx-statusbar-mode
  "The status bar in the editor windows in place of the raw mode line."
  :global t :group 'drgnx-statusbar
  (setq drgnx-chrome-editor-mode-line (if drgnx-statusbar-mode drgnx-statusbar--host drgnx-chrome--mode-line))
  (if drgnx-statusbar-mode
      (when (fboundp 'drgnx-modal-indicator-off) (drgnx-modal-indicator-off))   ; the bar shows the modal state
    (when (fboundp 'drgnx-modal-indicator-on) (drgnx-modal-indicator-on)))
  (dolist (f (frame-list)) (drgnx-chrome-apply f))
  (force-mode-line-update t))

;;;; The default segments (cached state only)

(defun drgnx-statusbar--glyph (name)
  (if (fboundp 'drgnx-face-glyph) (or (drgnx-face-glyph name) "") ""))

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
      (if (and (zerop e) (zerop w))
          (propertize (drgnx-statusbar--glyph 'ok) 'face 'success)
        (let ((glyph (drgnx-statusbar--glyph 'warning)))
          (string-join (delq nil (list (and (> e 0) (propertize (format "%s %d" glyph e) 'face 'error))
                                       (and (> w 0) (propertize (format "%s %d" glyph w) 'face 'warning))))
                       " "))))))

(defun drgnx-statusbar--seg-jobs ()
  "The job badge (cards waiting for you); the count of running jobs is not cached anywhere yet."
  (when (and (boundp 'drgnx-job-ui--badge) (stringp drgnx-job-ui--badge) (not (string-empty-p drgnx-job-ui--badge)))
    (string-trim (substring-no-properties drgnx-job-ui--badge))))

(defun drgnx-statusbar--seg-agents ()
  "Agents busy and agents with something waiting on you, counted from the sessions drgnx already holds."
  (when (and (boundp 'drgnx-agents--sessions) drgnx-agents--sessions (fboundp 'drgnx-agent-session-status))
    (let ((busy 0) (waiting 0))
      (dolist (s drgnx-agents--sessions)
        (when (eq (drgnx-agent-session-status s) 'busy) (cl-incf busy))
        (when (or (drgnx-agent-session-permissions s) (drgnx-agent-session-reviews s)) (cl-incf waiting)))
      (string-join (delq nil (list (and (> busy 0) (format "%s %d busy" (drgnx-statusbar--glyph 'busy) busy))
                                   (and (> waiting 0)
                                        (propertize (format "%s %d waiting on you" (drgnx-statusbar--glyph 'waiting) waiting)
                                                    'face 'error))))
                   " "))))

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

(defun drgnx-statusbar--seg-position ()
  (let* ((w (drgnx-statusbar-source-window))
         (pt (if (eq (window-buffer w) (current-buffer)) (window-point w) (point))))
    (format "Ln %d, Col %d" (line-number-at-pos pt) (save-excursion (goto-char pt) (1+ (current-column))))))

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
  "Define the segments the bar ships with.  Tests and misc have nothing cached to read yet: they render nothing
until the later tasks give them a source."
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
  (drgnx-statusbar-define-segment 'misc :fn #'ignore :help "Other indicators")
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
