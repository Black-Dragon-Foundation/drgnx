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
;; git, a process, the file system or a language server.  Each window's bar is the memo `statusbar-bar', keyed on six
;; epochs (`buffer-look', `flymake', `eglot', `git', `misc-info', `statusbar': bumped by hooks and variable watchers)
;; and plain values (buffer, point, text, width…), so a redisplay that changes nothing costs a few comparisons and
;; allocates nothing.  Other packages' entries of the mode line stay real time: they are formatted once per buffer per
;; redisplay, in that buffer (`drgnx-statusbar--misc'), and one too slow for that once a second.  drgnx's own segments (tests,
;; jobs, agents) are worked out when their hooks say something changed (`drgnx-statusbar-refresh', debounced), never on
;; redisplay.  See docs/guide/face.md ("The status bar").

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
(require 'drgnx-large-file)
(require 'drgnx-memo)
(require 'drgnx-notices)                ; the two counts the bar shows, and `drgnx-notice-tick'
(declare-function drgnx-face-glyph "drgnx-face")
(declare-function drgnx-file-write "drgnx-file")
(declare-function drgnx-state-dir "drgnx-paths")
(declare-function drgnx-wb-editor-window "drgnx-wb")
(declare-function drgnx-signal-subscribe "drgnx-signal")
(declare-function drgnx-signal-unsubscribe "drgnx-signal")
(declare-function drgnx-signal-editor-window-p "drgnx-signal")
(declare-function drgnx-modal-indicator-on "ext:drgnx-modal")
(declare-function drgnx-modal-indicator-off "ext:drgnx-modal")
(declare-function drgnx-modal-mode-line "ext:drgnx-modal")
(declare-function drgnx-agent-session-status "drgnx-agents")
(declare-function drgnx-agents-sessions "drgnx-agents")
(declare-function drgnx-hub-call "drgnx-hub-client")
(declare-function drgnx-agents-ui-view "drgnx-agents-ui")
(declare-function flymake--mode-line-counter "flymake")
(declare-function flymake-running-backends "flymake")
(declare-function flymake-reporting-backends "flymake")
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

(defface drgnx-statusbar-waiting '((t :inherit drgnx-status-needs-you))
  "The status bar's count of things waiting on you (the face of `drgnx-status-needs-you')."
  :group 'drgnx-statusbar)

;;;; Epochs: what every window's bar is keyed on besides plain values (docs/develop/core.md, "Epochs, memos and
;;;; caches").  Declarations; `drgnx-statusbar-setup' activates their watchers (`drgnx-statusbar--declared').

(drgnx-epoch-define 'buffer-look :per 'buffer :redisplay t
                    :watch '(vc-mode buffer-file-coding-system indent-tabs-mode tab-width drgnx-modal-state
                                     evil-mode-line-tag drgnx-trust--state drgnx-large-file)
                    :doc "How a buffer looks in the status bar: its major mode (`after-change-major-mode-hook'), version
control, encoding, indentation (the variables of `drgnx-statusbar-indent-vars' too), modal state, trust and whether it
holds a large file (`drgnx-large-file': the `large-file' segment; a chunk move changes the text's count).")

(drgnx-epoch-define 'flymake :per 'buffer
                    :doc "A buffer's flymake state: flymake turned on or off there, or a backend reported.")

(drgnx-epoch-define 'eglot :per 'buffer
                    :doc "A buffer's language server: eglot manages it or let it go (its server exited); the base: a server
finished starting.")

(drgnx-epoch-define 'git :per 'object
                    :doc "A repository's branch, or its ahead and behind counts, changed (per root, from
`drgnx-git-changed-functions').")

(drgnx-epoch-define 'misc-info
                    :watch '(global-mode-string mode-line-misc-info drgnx-statusbar-misc-exclude
                                                drgnx-statusbar-misc-info-skip)
                    :doc "The entries other packages put in the mode line changed, or which of them the status bar leaves
out: the entries are read again (`drgnx-statusbar--misc-entries').")

(drgnx-epoch-define 'statusbar
                    :watch '(drgnx-face-glyphs drgnx-explorer--roots drgnx-statusbar-left
                                               drgnx-statusbar-right drgnx-statusbar-compact drgnx-statusbar-drop-order
                                               drgnx-statusbar-quiet drgnx-statusbar-misc-exclude)
                    :doc "What drgnx's own segments show (tests, jobs, agents, the folder), a segment defined, a setting or
the glyphs changed (`drgnx-statusbar--bump').")

(drgnx-epoch-define 'redisplay
                    :doc "Bumped before each redisplay (`pre-redisplay-functions', while the status bar is on): other
packages' entries of the mode line are formatted once per value, for each buffer a bar shows (`drgnx-statusbar--misc').")

(defconst drgnx-statusbar--declared '(buffer-look flymake eglot git misc-info statusbar redisplay statusbar-bar)
  "The epochs and the memo `drgnx-statusbar-setup' activates: watched while `ui/face' is on, emptied when it is off.")

(defun drgnx-statusbar--bump ()
  "Say that the state the bars show changed: the epoch `statusbar'."
  (drgnx-epoch-bump 'statusbar))

(defun drgnx-statusbar--set (symbol value)
  "Set SYMBOL to VALUE and redraw the bars."
  (set-default symbol value)
  (drgnx-statusbar--bump)
  (force-mode-line-update t))

(defcustom drgnx-statusbar-left '(branch trust problems tests jobs agents needs-you drgnx modal misc)
  "The segments on the left of the status bar, in order (see `drgnx-statusbar-define-segment')."
  :type '(repeat symbol) :set #'drgnx-statusbar--set :group 'drgnx-statusbar)

(defcustom drgnx-statusbar-right '(lsp position indent encoding eol language)
  "The segments on the right of the status bar, in order."
  :type '(repeat symbol) :set #'drgnx-statusbar--set :group 'drgnx-statusbar)

(defcustom drgnx-statusbar-drop-order '(eol indent encoding lsp language misc tests jobs drgnx trust)
  "Segments dropped, first to last, when the bar is wider than its window.
The branch is cut with an ellipsis instead, and only after these are gone.  `needs-you' is never dropped."
  :type '(repeat symbol) :set #'drgnx-statusbar--set :group 'drgnx-statusbar)

(defcustom drgnx-statusbar-compact '(position language)
  "The segments the other editor groups show (the most recently used one shows the whole bar)."
  :type '(repeat symbol) :set #'drgnx-statusbar--set :group 'drgnx-statusbar)

(defcustom drgnx-statusbar-quiet '(folder branch agents jobs needs-you drgnx tests misc)
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
  "Variables that hold a mode's indentation width; the first one that is bound and a number is shown.
Setting one of them bumps the epoch `buffer-look': the list as it is when the status bar is set up."
  :type '(repeat symbol) :group 'drgnx-statusbar)

(drgnx-epoch-watch 'buffer-look drgnx-statusbar-indent-vars)

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
HELP is the text shown when the pointer rests on the segment.
Called from a module's setup, the definition claims ID and records its undo \"statusbar segment ID\": the segment
it replaced put back, or `drgnx-statusbar-undefine-segment' — only while ID is still the one defined here.  Two
modules defining the same ID may be torn down in either order (`drgnx-module--claim').  Either way the epoch
`statusbar' moves, so every bar is drawn again."
  (let* ((rec (drgnx-modules--recording-p))
         (old (gethash id drgnx-statusbar--segments))
         (spec (list :fn fn :click click :help help)))
    (drgnx-statusbar--put-segment id spec)
    (when rec
      (let* ((target (list 'statusbar-segment id)) (box (drgnx-module--claim target old)))
        (drgnx-modules-push-undo
         (format "statusbar segment %s" id)
         (lambda ()
           (drgnx-module--release target box
                                  (lambda () (eq (gethash id drgnx-statusbar--segments) spec))
                                  (lambda (prev) (if prev (drgnx-statusbar--put-segment id prev)
                                                   (drgnx-statusbar-undefine-segment id))))))))
    id))

(defun drgnx-statusbar--put-segment (id spec)
  "Make SPEC the definition of segment ID: a new chance after an error, and the bars drawn again."
  (puthash id spec drgnx-statusbar--segments)
  (setq drgnx-statusbar--errors (assq-delete-all id drgnx-statusbar--errors))   ; a new definition gets a new chance
  (drgnx-statusbar--bump)
  (force-mode-line-update t))

(defun drgnx-statusbar-undefine-segment (id)
  "Remove the segment ID, and draw the bars again (the epoch `statusbar' moves): an ID in `drgnx-statusbar-left' or
`-right' then shows nothing.  Non-nil if ID was defined."
  (when (gethash id drgnx-statusbar--segments)
    (remhash id drgnx-statusbar--segments)
    (setq drgnx-statusbar--errors (assq-delete-all id drgnx-statusbar--errors))
    (drgnx-statusbar--bump)
    (force-mode-line-update t)
    t))

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

;;;; Other packages' entries: real time, formatted once per buffer per redisplay

(defvar drgnx-statusbar-misc-exclude)
(defvar drgnx-statusbar-misc-info-skip)

(defcustom drgnx-statusbar-misc-slow-ms 1.0
  "Milliseconds another package's entry of the mode line may take, on average, to be formatted on every redisplay.
One that takes longer is formatted once a second instead, until it is fast again, and `drgnx doctor' names it."
  :type 'number :group 'drgnx-statusbar)

(defconst drgnx-statusbar-slow-report "statusbar-slow.eld"
  "The file in `drgnx-state-dir' the bar writes its slow entries to; the doctor's `statusbar-misc' check reads it.")

(cl-defstruct (drgnx-statusbar--entry (:constructor drgnx-statusbar--entry-make) (:copier nil))
  "An entry of `mode-line-misc-info' or `global-mode-string' the `misc' segment shows: FORM, from `global-mode-string'
when GLOBAL; LIVE unless it holds only strings; TEXT as last formatted; AVG, the moving average of the milliseconds a
format took, over N samples (at most 8 counted); SLOW (formatted once a second) since SINCE; FAST, its ticks in a row
under half the limit."
  form global live text (avg 0.0) (n 0) slow since (fast 0))

(defvar drgnx-statusbar--misc-all nil "The entries `misc' shows, in order (`drgnx-statusbar--misc-entries').")
(defvar drgnx-statusbar--misc-split nil "(STATIC . LIVE): the entries of `drgnx-statusbar--misc-all', split.")
(defvar drgnx-statusbar--misc-made nil "The value of the epoch `misc-info' the entries were read at; nil: never.")
(defvar drgnx-statusbar--misc-read nil
  "(MODE-LINE-MISC-INFO . GLOBAL-MODE-STRING): the values the entries were read from.  A value not `eq' to them (a
`let' of one, which moves no epoch, or a buffer-local one) reads the entries again.")
(defvar drgnx-statusbar--misc-texts (make-hash-table :test #'eq :weakness 'key)
  "Buffer → [AT ALL TEXTS TEXT]: the text of other packages' entries in that buffer's bars (`drgnx-statusbar--misc'),
made at the value AT of the epoch `redisplay' for the entries ALL (`drgnx-statusbar--misc-all'), TEXTS the live
entries' texts it was joined from.  Weak on the buffer; emptied when the mode turns off.")
(defvar drgnx-statusbar--misc-report-due nil "Non-nil: the set of slow entries changed since the report was written.")

(defun drgnx-statusbar--static-p (c)
  "Non-nil when the mode-line construct C holds only strings with no `%' and `:propertize' of such: its text changes
only when the construct does."
  (cond ((stringp c) (not (string-search "%" c)))
        ((eq (car-safe c) :propertize) (drgnx-statusbar--static-p (cadr c)))
        ((and (consp c) (or (stringp (car c)) (consp (car c))))
         (while (and (consp c) (drgnx-statusbar--static-p (car c))) (setq c (cdr c)))
         (null c))))

(defun drgnx-statusbar--static-text (c)
  "The text of the static construct C (`drgnx-statusbar--static-p'): its strings joined, `:propertize' applied.
Nothing is formatted: a string is shown as it is, with its properties."
  (cond ((stringp c) c)
        ((eq (car-safe c) :propertize)
         (let ((s (copy-sequence (drgnx-statusbar--static-text (cadr c)))))
           (add-text-properties 0 (length s) (cddr c) s)
           s))
        (t (mapconcat #'drgnx-statusbar--static-text c ""))))

(defun drgnx-statusbar--constructs (c)
  "The entries of C (`mode-line-misc-info' or `global-mode-string'): its elements when it is a list of them, else C."
  (cond ((null c) nil)
        ((and (consp c) (not (keywordp (car c))) (proper-list-p c)) c)
        (t (list c))))

(defun drgnx-statusbar--misc-forget ()
  "Forget the entries, their averages and their text: they are read again when next asked (the mode turned off)."
  (setq drgnx-statusbar--misc-all nil drgnx-statusbar--misc-split nil drgnx-statusbar--misc-made nil
        drgnx-statusbar--misc-read nil)
  (clrhash drgnx-statusbar--misc-texts))

(defun drgnx-statusbar--misc-format (x)
  "Format entry X, keep its text (the old string when `equal') and add how long that took to its moving average
\(avg += (ms - avg) / 8, the first sample as it is); return the milliseconds, read with `drgnx-timer-now'.  An error
formats as nothing."
  (let* ((t0 (drgnx-timer-now))
         (s (condition-case nil (format-mode-line (drgnx-statusbar--entry-form x)) (error "")))
         (ms (* 1000.0 (- (drgnx-timer-now) t0)))
         (n (drgnx-statusbar--entry-n x)) (avg (drgnx-statusbar--entry-avg x)))
    (unless (equal s (drgnx-statusbar--entry-text x)) (setf (drgnx-statusbar--entry-text x) s))
    (setf (drgnx-statusbar--entry-avg x) (if (= n 0) ms (+ avg (/ (- ms avg) 8.0)))
          (drgnx-statusbar--entry-n x) (min (1+ n) 8))
    ms))

(defun drgnx-statusbar--misc-entries ()
  "The entries of other packages the `misc' segment shows, as (STATIC . LIVE), each a list of `drgnx-statusbar--entry'
in order: those of `mode-line-misc-info' (not those of `drgnx-statusbar-misc-info-skip'), then those of
`global-mode-string' (not those of `drgnx-statusbar-misc-exclude').  An entry is static when it holds only strings
and `:propertize' of strings (`drgnx-statusbar--static-p'), else live.  Read again, and the static ones given their
text (`drgnx-statusbar--static-text'), only when the epoch `misc-info' moved or one of the two variables is not the
value they were read from (`drgnx-statusbar--misc-read': two `eq' tests, for a `let' or a buffer-local value); that
forgets every average, so a slow entry is live again."
  (let ((epoch (drgnx-epoch 'misc-info)) (read drgnx-statusbar--misc-read))
    (unless (and (eq epoch drgnx-statusbar--misc-made)
                 (eq (car read) mode-line-misc-info) (eq (cdr read) global-mode-string))
      (let ((all nil) (static nil) (live nil))
        (dolist (x drgnx-statusbar--misc-all)
          (when (drgnx-statusbar--entry-slow x) (setq drgnx-statusbar--misc-report-due t)))
        (dolist (c (drgnx-statusbar--constructs mode-line-misc-info))
          (unless (or (equal c "") (and (consp c) (memq (car c) drgnx-statusbar-misc-info-skip)))
            (push (drgnx-statusbar--entry-make :form c :live (not (drgnx-statusbar--static-p c))) all)))
        (dolist (c (drgnx-statusbar--constructs global-mode-string))
          (unless (or (equal c "") (member c drgnx-statusbar-misc-exclude))
            (push (drgnx-statusbar--entry-make :form c :global t :live (not (drgnx-statusbar--static-p c))) all)))
        (setq all (nreverse all))
        (dolist (x all)
          (if (drgnx-statusbar--entry-live x)
              (push x live)
            (setf (drgnx-statusbar--entry-text x) (drgnx-statusbar--static-text (drgnx-statusbar--entry-form x)))
            (push x static)))
        (setq drgnx-statusbar--misc-all all
              drgnx-statusbar--misc-split (cons (nreverse static) (nreverse live))
              drgnx-statusbar--misc-made epoch
              drgnx-statusbar--misc-read (cons mode-line-misc-info global-mode-string))))
    drgnx-statusbar--misc-split))

(defun drgnx-statusbar--misc-join ()
  "The entries' texts as the stock mode line shows them: those of `mode-line-misc-info', then those of
`global-mode-string' after a space, each part trimmed; nil when both are empty."
  (let ((others nil) (global nil))
    (dolist (x drgnx-statusbar--misc-all)
      (when-let* ((s (drgnx-statusbar--entry-text x)))
        (if (drgnx-statusbar--entry-global x) (push s global) (push s others))))
    (let ((o (drgnx-statusbar--trim (apply #'concat (nreverse others))))
          (g (drgnx-statusbar--trim (apply #'concat (nreverse global)))))
      (cond ((string-empty-p o) (unless (string-empty-p g) g))
            ((string-empty-p g) o)
            (t (concat o " " g))))))

(defun drgnx-statusbar--misc ()
  "The text of other packages' entries in this buffer's mode line for this redisplay, or nil: a key of the bar.
Made again for the buffer only when the epoch `redisplay' moved or the entries were read again: each live entry that
is not slow is formatted, in this buffer, and timed; the static ones keep the text they got when read, the slow ones
the text of their last tick.  When no live entry's text differs from the last time in this buffer, the last string
is given back, so the bars' memo still hits.  So an entry is formatted once per buffer per redisplay however many
windows show it (an entry that reads buffer-local state shows each buffer's own value), and one averaging over
`drgnx-statusbar-misc-slow-ms' after 8 samples is formatted once a second instead (`drgnx-statusbar--misc-make-slow')."
  (let* ((live (cdr (drgnx-statusbar--misc-entries)))
         (all drgnx-statusbar--misc-all)
         (at (drgnx-epoch 'redisplay))
         (rec (gethash (current-buffer) drgnx-statusbar--misc-texts)))
    (if (and rec (eq (aref rec 0) at) (eq (aref rec 1) all))
        (aref rec 3)
      (let ((changed (not (and rec (eq (aref rec 1) all)))) (old (and rec (aref rec 2))))
        (dolist (x live)
          (unless (drgnx-statusbar--entry-slow x)
            (drgnx-statusbar--misc-format x)
            (when (and (>= (drgnx-statusbar--entry-n x) 8)
                       (> (drgnx-statusbar--entry-avg x) drgnx-statusbar-misc-slow-ms))
              (drgnx-statusbar--misc-make-slow x)))
          (unless (equal (drgnx-statusbar--entry-text x) (car old)) (setq changed t))
          (setq old (cdr old)))
        (if (not changed)
            (aset rec 0 at)
          (let ((text (drgnx-statusbar--misc-join)))
            (when (and rec (equal text (aref rec 3))) (setq text (aref rec 3)))
            (setq rec (vector at all (mapcar #'drgnx-statusbar--entry-text live) text))
            (puthash (current-buffer) rec drgnx-statusbar--misc-texts)))
        (aref rec 3)))))

(defun drgnx-statusbar--misc-make-slow (x)
  "Entry X averages over `drgnx-statusbar-misc-slow-ms': from now on the timer `statusbar-misc-slow' formats it, once a
second, and the report names it.  Nothing changes when the timer cannot start (`ui/face' is off): X stays live."
  (when (or (drgnx-timer-active-p 'statusbar-misc-slow)
            (drgnx-timer-start 'statusbar-misc-slow 1 #'drgnx-statusbar--misc-slow-tick :repeat 1 :owner 'ui/face))
    (setf (drgnx-statusbar--entry-slow x) t (drgnx-statusbar--entry-since x) (drgnx-timer-now)
          (drgnx-statusbar--entry-fast x) 0)
    (setq drgnx-statusbar--misc-report-due t)))

(defun drgnx-statusbar--misc-slow-tick ()
  "Once a second while an entry is slow (the timer `statusbar-misc-slow'): format each slow entry, in the buffer that
is current (the selected window's), and redraw the bars when one's text changed.  One that took under half of
`drgnx-statusbar-misc-slow-ms' on 8 ticks in a row is live again.  The report is written when the set of slow entries
changed (here, never on redisplay), and with no slow entry left the timer is cancelled."
  (let ((inhibit-interaction t) (left nil) (stale nil))
    (dolist (x drgnx-statusbar--misc-all)
      (when (drgnx-statusbar--entry-slow x)
        (let* ((old (drgnx-statusbar--entry-text x)) (ms (drgnx-statusbar--misc-format x)))
          (unless (eq old (drgnx-statusbar--entry-text x)) (setq stale t))
          (setf (drgnx-statusbar--entry-fast x)
                (if (< ms (/ drgnx-statusbar-misc-slow-ms 2.0)) (1+ (drgnx-statusbar--entry-fast x)) 0))
          (if (< (drgnx-statusbar--entry-fast x) 8)
              (setq left t)
            (setf (drgnx-statusbar--entry-slow x) nil (drgnx-statusbar--entry-since x) nil
                  (drgnx-statusbar--entry-fast x) 0 (drgnx-statusbar--entry-n x) 0 (drgnx-statusbar--entry-avg x) 0.0)
            (setq drgnx-statusbar--misc-report-due t)))))
    (when stale (force-mode-line-update t))
    (when drgnx-statusbar--misc-report-due (drgnx-statusbar--misc-write-report))
    (unless left (drgnx-timer-cancel 'statusbar-misc-slow))))

(defun drgnx-statusbar--misc-report-soon ()
  "When the bar turns on and an earlier session left a report: rewrite it once, a second later, from the timer
`statusbar-misc-report' (never from redisplay), with the slow entries of now (maybe none).  So an entry you removed,
or that got fast, is not named by the doctor forever; one that is still slow is named again when it is found slow."
  (when (and (fboundp 'drgnx-state-dir)
             (file-exists-p (expand-file-name drgnx-statusbar-slow-report (drgnx-state-dir))))
    (drgnx-timer-soon 'statusbar-misc-report 1 #'drgnx-statusbar--misc-write-report :owner 'ui/face)))

(defun drgnx-statusbar--misc-write-report ()
  "Write the slow entries, ((:entry PRINTED :avg-ms N :since TIME)…), to `drgnx-statusbar-slow-report' in the state
dir (the doctor's `statusbar-misc' check reads it).  Never prompts and never raises: a write that fails is skipped."
  (setq drgnx-statusbar--misc-report-due nil)
  (condition-case nil
      (when (and (fboundp 'drgnx-state-dir) (require 'drgnx-file nil t))
        (let ((inhibit-interaction t) (rows nil))
          (dolist (x drgnx-statusbar--misc-all)
            (when (drgnx-statusbar--entry-slow x)
              (let ((printed (let ((print-length 8) (print-level 4))
                               (prin1-to-string (drgnx-statusbar--entry-form x)))))
                (push (list :entry (if (> (length printed) 120) (concat (substring printed 0 119) "…") printed)
                            :avg-ms (/ (round (* 100 (drgnx-statusbar--entry-avg x))) 100.0)
                            :since (drgnx-statusbar--entry-since x))
                      rows))))
          (drgnx-file-write (expand-file-name drgnx-statusbar-slow-report (drgnx-state-dir)) (nreverse rows)
                            :fsync nil)))
    (error nil)))

;;;; The memo: a redisplay that changes nothing reuses the bar

(drgnx-memo-define statusbar-bar :on window
                   :keys ((drgnx-epoch 'buffer-look (current-buffer)) (drgnx-epoch 'flymake (current-buffer))
                          (drgnx-epoch 'eglot (current-buffer)) (drgnx-epoch 'git) (drgnx-epoch 'misc-info)
                          (drgnx-epoch 'statusbar) (drgnx-notice-tick)
                          (window-point object) (buffer-chars-modified-tick) (point-min) (point-max) width compact
                          (drgnx-statusbar--selected-p object) (and mark-active (mark t))
                          (current-buffer) default-directory mode-line-process defining-kbd-macro
                          ;; keycast's keys: a new vector after every command (its text changes even when nothing else did)
                          (and (bound-and-true-p keycast-mode-line-mode) (bound-and-true-p keycast--this-command-keys))
                          (drgnx-statusbar--which-func object) (drgnx-statusbar--misc))
                   :doc "A window's escaped bar (`drgnx-statusbar--bar'), evaluated in its buffer with WIDTH its width and
COMPACT whether it shows the compact bar.  Six epochs, the notice model's tick (`drgnx-notice-tick': the two counts
the `needs-you' and `drgnx' segments show), then plain values compared with `eq': the window's point, the
text's change count, the narrowing, width and kind, whether you are in it, the mark of a selection; the buffer,
`default-directory', `mode-line-process', a keyboard macro being recorded, keycast's keys, which-function's name and
the text of other packages' entries this redisplay (`drgnx-statusbar--misc').  A segment of your own that shows
something else is drawn again when point moves, the text changes or `(drgnx-statusbar-refresh t)' runs.")

(defun drgnx-statusbar--bar (w width compact)
  "The escaped bar of window W (WIDTH columns, COMPACT or full), in W's buffer: the memo `statusbar-bar', built again
only when one of its keys changed."
  (drgnx-memo statusbar-bar w (drgnx-statusbar--escape (drgnx-statusbar-render width compact))))

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
            (t (drgnx-memo-forget 'statusbar-bar (selected-window))   ; no bar here now: keep no buffer alive for it
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

(defvar drgnx-statusbar--agents-state nil "How many agents are busy, as of the last refresh.")

(defvar drgnx-statusbar-refresh-delay 0.2
  "Seconds `drgnx-statusbar-refresh' waits, so that a burst of changes is one refresh and one redraw.")

(defvar drgnx-statusbar--redraw-wanted nil "Non-nil: the next refresh redraws the bars even when no count changed.")
(defvar drgnx-statusbar--jobs-wanted nil "Non-nil: the next refresh asks the hub how many jobs run.")
(defvar drgnx-statusbar--jobs-pending nil "Non-nil while a `job/status' question is on its way to the hub.")

(defun drgnx-statusbar-refresh (&optional changed)
  "Bring drgnx's segments (agents, jobs) up to date and redraw the bars when they changed.
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
      (setq drgnx-statusbar--agents-state agents redraw t)
      (drgnx-statusbar--bump))                           ; else every window would reuse its memoized bar
    ;; who asked for a redraw bumped its own epoch then: `statusbar' (`drgnx-statusbar-refresh' t), `git', `flymake'
    (when redraw (force-mode-line-update t))))

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

(defun drgnx-statusbar--hub-tests (event data)
  "On `drgnx-hub-event-functions': the test runs among the `events' the hub sent reach the `tests' segment
\(`drgnx-statusbar-note-tests')."
  (when (equal event "events")
    (dolist (e (append (plist-get data :events) nil))
      (when (equal (plist-get e :kind) "test")
        (let ((d (plist-get e :data)))
          (when (and (proper-list-p d) (or (natnump (plist-get d :passed)) (natnump (plist-get d :failed))))
            (drgnx-statusbar-note-tests (or (plist-get d :passed) 0) (or (plist-get d :failed) 0) (plist-get e :agent))))))))

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
ahead and behind counts are not what the bars last drew (the epoch `git' moves for ROOT); a status run that changed
only files redraws nothing."
  (let ((branch (and root (fboundp 'drgnx-git-branch) (drgnx-git-branch root))))
    (unless (equal branch (gethash root drgnx-statusbar--git-branches))
      (puthash root branch drgnx-statusbar--git-branches)
      (drgnx-epoch-bump 'git root)
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
  "After a flymake backend reported (advice on `flymake--handle-report': flymake has no hook for it), in the buffer
it checked: the epoch `flymake' moves for that buffer and the bars are redrawn, debounced, so the problems count
follows reports that arrive while you do nothing.  Idempotent; removed with the mode."
  (drgnx-epoch-bump 'flymake (current-buffer))
  (setq drgnx-statusbar--redraw-wanted t)
  (drgnx-statusbar-refresh))

(defun drgnx-statusbar--flymake-started (&rest _)
  "After a flymake check started (advice on `flymake-start'), in its buffer: as after a report, the epoch `flymake'
moves for the buffer and the bars are redrawn, debounced, so the problems segment shows the check running instead of
the old counts.  Removed with the mode."
  (drgnx-statusbar--flymake-reported))

(defun drgnx-statusbar--flymake-changed ()
  "On `flymake-mode-hook': flymake turned on or off in this buffer."
  (drgnx-epoch-bump 'flymake (current-buffer)))

(defun drgnx-statusbar--mode-changed ()
  "On `after-change-major-mode-hook': this buffer has another major mode (its language, maybe its indentation)."
  (drgnx-epoch-bump 'buffer-look (current-buffer)))

(defun drgnx-statusbar--eglot-changed ()
  "On `eglot-managed-mode-hook': eglot manages this buffer now, or let it go (it does when its server exits)."
  (drgnx-epoch-bump 'eglot (current-buffer)))

(defun drgnx-statusbar--eglot-initialized (&rest _)
  "On `eglot-server-initialized-hook': a server finished starting (and told its name): every buffer's `lsp' segment."
  (drgnx-epoch-bump 'eglot))

(defun drgnx-statusbar--pre-redisplay (&rest _)
  "On `pre-redisplay-functions' (run for each window about to be redisplayed, before any is): the epoch `redisplay'
moves, so other packages' entries are formatted again, once per buffer the bars this redisplay draws show."
  (drgnx-epoch-bump 'redisplay))

(defconst drgnx-statusbar--host '(:eval (drgnx-statusbar-mode-line)))

(defconst drgnx-statusbar--hooks
  '((post-command-hook . drgnx-statusbar--post-command)
    (drgnx-agents-changed-functions . drgnx-statusbar--agents-changed)
    (drgnx-hub-event-functions . drgnx-statusbar--hub-event)
    (drgnx-hub-event-functions . drgnx-statusbar--hub-tests)
    (drgnx-hub-disconnect-functions . drgnx-statusbar--hub-gone)
    (drgnx-git-changed-functions . drgnx-statusbar--git-changed)
    (compilation-finish-functions . drgnx-statusbar--compilation-finished)
    (after-change-major-mode-hook . drgnx-statusbar--mode-changed)
    (flymake-mode-hook . drgnx-statusbar--flymake-changed)
    (eglot-managed-mode-hook . drgnx-statusbar--eglot-changed)
    (eglot-server-initialized-hook . drgnx-statusbar--eglot-initialized)
    (pre-redisplay-functions . drgnx-statusbar--pre-redisplay))
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
        (advice-add 'flymake-start :after #'drgnx-statusbar--flymake-started)               ; nor for this
        (drgnx-statusbar--misc-report-soon)
        (when (fboundp 'drgnx-modal-indicator-off) (drgnx-modal-indicator-off))   ; the bar shows the modal state
        (setq drgnx-statusbar--agents-state (drgnx-statusbar--agent-counts))
        (when (drgnx-statusbar--hub-connected-p)           ; connected: count the jobs
          (setq drgnx-statusbar--jobs-wanted t)
          (drgnx-statusbar-refresh)))
    (dolist (h drgnx-statusbar--hooks) (remove-hook (car h) (cdr h)))
    (drgnx-state-unsubscribe 'editor-changed #'drgnx-statusbar--editor-changed)
    (drgnx-signal-unsubscribe 'editor-changed #'drgnx-statusbar--ask-git)
    (advice-remove 'flymake--handle-report #'drgnx-statusbar--flymake-reported)
    (advice-remove 'flymake-start #'drgnx-statusbar--flymake-started)
    (drgnx-timer-cancel 'statusbar-refresh)
    (drgnx-timer-cancel 'statusbar-misc-slow)
    (drgnx-timer-cancel 'statusbar-misc-report)
    (drgnx-memo-forget 'statusbar-bar)
    (drgnx-statusbar--misc-forget)
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
  "Segment ID → [EPOCH SEP EXTRA TEXT]: the text of one of drgnx's own segments as of the epoch `statusbar', the
separator glyph in use (it stands for the frame's glyph set) and EXTRA.  One entry per segment ID.")

(defun drgnx-statusbar--state-text (id fn &optional extra)
  "The text FN makes for segment ID, made again only when the epoch `statusbar', the glyph set or EXTRA (compared
with `eq') changed: drgnx's own segments are worked out once per change of their state, not per bar."
  (let ((c (gethash id drgnx-statusbar--state-texts))
        (epoch (drgnx-epoch 'statusbar))
        (glyphs (drgnx-statusbar--glyph 'sep)))           ; the same string object while the glyph set is the same
    (if (and c (eql (aref c 0) epoch) (eq (aref c 1) glyphs) (eq (aref c 2) extra))
        (aref c 3)
      (let ((s (funcall fn)))
        (puthash id (vector epoch glyphs extra s) drgnx-statusbar--state-texts)
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

(defun drgnx-statusbar--seg-jobs ()
  "`◎ 2 jobs' (running, as the hub last said).  What waits on you is the `needs-you' segment's."
  (drgnx-statusbar--state-text
   'jobs
   (lambda ()
     (let ((running drgnx-statusbar--jobs-state))
       (and running (> running 0)
            (format "%s %d job%s" (drgnx-statusbar--glyph 'busy) running (if (= running 1) "" "s")))))))

(defun drgnx-statusbar--agent-counts ()
  "How many agents work (from the sessions drgnx holds)."
  (let ((busy 0))
    (when (and (fboundp 'drgnx-agents-sessions) (fboundp 'drgnx-agent-session-status))
      (dolist (s (drgnx-agents-sessions))
        (when (eq (drgnx-agent-session-status s) 'busy) (setq busy (1+ busy)))))
    busy))

(defun drgnx-statusbar--seg-agents ()
  "`◎ 1 busy', as of the last refresh."
  (drgnx-statusbar--state-text
   'agents
   (lambda ()
     (let ((busy drgnx-statusbar--agents-state))
       (and busy (> busy 0) (format "%s %d busy" (drgnx-statusbar--glyph 'busy) busy))))))

(defcustom drgnx-statusbar-misc-exclude '((:eval (drgnx-trust--mark)) (:eval (drgnx-notice-mode-line)))
  "Entries of `global-mode-string' the `misc' segment leaves out because the bar already shows them (the
Restricted Mode mark: the `trust' segment; the notice counts: the `needs-you' and `drgnx' segments)."
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
`mode-line-misc-info' and `global-mode-string' (without the job badge: `drgnx-statusbar--misc', once per buffer per
redisplay)."
  (let* ((global (drgnx-statusbar--misc))
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
  "`Ln N, Col M'; in a large file `Col M' alone (its line number would count the lines from the top)."
  (let* ((w (drgnx-statusbar-source-window))
         (pt (if (eq (window-buffer w) (current-buffer)) (window-point w) (point))))
    (save-excursion
      (goto-char pt)
      (let* ((bol (pos-bol))
             (col (if (> (- pt bol) 2000) (- pt bol) (current-column))))   ; a minified line: characters, not columns
        (format "%sCol %d%s" (if (drgnx-large-file-p) "" (format "Ln %d, " (drgnx-statusbar--line-at bol))) (1+ col)
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
space-indented lines, else the first of `drgnx-statusbar-indent-vars' that is bound to a natural number (setting one
bumps the epoch `buffer-look'; an edit changes the text's count): no allocation beyond the scan's cache.  A large file
is not scanned: `tab-width'."
  (if (or (drgnx-large-file-p) (drgnx-statusbar--indent-tabs-p))
      tab-width
    (or (nth 3 (drgnx-statusbar--indent-scan))
        (let ((vars drgnx-statusbar-indent-vars) (found nil))
          (while (and vars (not found))
            (let ((v (car vars)))
              (when (and (boundp v) (natnump (symbol-value v))) (setq found (symbol-value v))))
            (setq vars (cdr vars)))
          (or found tab-width)))))

(defun drgnx-statusbar--seg-indent ()
  "`Spaces: N' or `Tab Size: N'; nothing in a large file (its first lines are not scanned)."
  (unless (drgnx-large-file-p)
    (format (if (drgnx-statusbar--indent-tabs-p) "Tab Size: %d" "Spaces: %d") (drgnx-statusbar--indent-width))))

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
                                  :help "Agents busy; click for the Agents tab")
  (drgnx-statusbar-define-segment 'needs-you :fn #'drgnx-notice-needs-you-text :click #'drgnx-notice-needs-you-click
                                  :help "Waiting on you: click for the newest, or the Notices list")
  (drgnx-statusbar-define-segment 'drgnx :fn #'drgnx-notice-problems-text :click #'drgnx-notices-show
                                  :help "drgnx's problems: click for the Notices list")
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
  "Define the command and the default segments, activate the bar's epochs and memo (`drgnx-statusbar--declared':
their watchers go, and the memo empties, when `ui/face' is turned off) and turn the status bar on."
  (drgnx-epoch-watch 'buffer-look drgnx-statusbar-indent-vars)   ; the list as it is now (your config's)
  (apply #'drgnx-memo-activate drgnx-statusbar--declared)
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
