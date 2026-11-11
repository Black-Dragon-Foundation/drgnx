;;; drgnx-agents-editor-draw.el --- Agents drawn in the buffer: named cursors, read rings, tags -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The drawing half of module tools/agents-in-editor.  It draws from the cached frame only (see
;; drgnx-agents-editor.el); nothing here asks the hub or scans for anything in redisplay.
;;
;; - An agent that is editing gets one bar (decor's cursor) at (line_end, col): put once, then moved with
;;   `drgnx-decor-cursor-move-now', so frames bypass decor's 50 ms flush and the overlay is reused.  Its colour is
;;   resolved from the identity face when the cursor is put and again whenever the identity cache clears (a theme).
;; - An agent that reads a range, or is about to edit one, gets one set of ring rows: one overlay per visible row of
;;   the range, a background tint (reading) or a dashed underline (pending, "hollow"); rebuilt on scroll and resize.
;;   Rows outside the windows have no overlay.
;; - An agent in another worktree (projected) gets no bar and no ring: a tag at the mapped line.
;; - Tags: mark, handle and mode.  Without Glitnir the name is in the bar's `help-echo'.
;; The ring's tint is the background tint form (no `:box'): the card box costs about 5 ms per redisplay.
;; See docs/guide/agents-in-the-editor.md and docs/develop/agents-editor.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-setting)
(require 'drgnx-modules)
(require 'drgnx-color)
(require 'drgnx-agent-identity)
(require 'drgnx-margins)
(unless (featurep 'drgnx-decor)
  (load (expand-file-name "../ui/drgnx-decor" (file-name-directory (or load-file-name buffer-file-name))) nil t))

(declare-function drgnx-agents-editor-frame "drgnx-agents-editor")
(declare-function drgnx-agents-editor-watched-buffers "drgnx-agents-editor")
(declare-function drgnx-decor-cursor-put "drgnx-decor")
(declare-function drgnx-decor-cursor-move-now "drgnx-decor")
(declare-function drgnx-decor-cursor-remove "drgnx-decor")
(declare-function drgnx-decor-cursor-overlay "drgnx-decor")
(declare-function drgnx-decor-cursor-keep-label "drgnx-decor")
(declare-function drgnx-decor-cursor-label-mode "drgnx-decor")
(declare-function drgnx-decor--glitnir-p "drgnx-decor")
(defvar drgnx-agents-editor-apply-functions)
(defvar drgnx-agents-tags)
(defvar drgnx-hunks-skip-line-function)
(declare-function drgnx-hunks-redraw "drgnx-hunks")

(defun drgnx-agents-editor-draw--tags-apply ()
  "A new tag setting applies to the frames drawn from now on."
  (drgnx-decor-cursor-label-mode (if (eq drgnx-agents-tags 'never) 'never 'activity)))

(drgnx-defsetting drgnx-agents-tags 'activity
  "When an agent's name tag shows beside its cursor: `activity' (for 2 s after it moves), `always' or `never'.
Two agents of one colour, and the agent you follow, keep their tags on whatever this says (except `never')."
  :type '(choice (const :tag "After a move" activity) (const :tag "Always" always) (const :tag "Never" never))
  :group 'drgnx :scope 'global :agents 'never :apply #'drgnx-agents-editor-draw--tags-apply
  :schema '(enum activity always never))

(defvar drgnx-agents-editor-followed nil
  "The session id of the agent the user follows, or nil: its tag stays on.")

(defvar-local drgnx-agents-editor-draw--bars nil "Ordinals with a bar (a decor cursor) in this buffer.")
(defvar-local drgnx-agents-editor-draw--rings nil
  "This buffer's rings: ((ORDINAL KIND START END)...), KIND `reading' or `pending', START and END line numbers.")
(defvar-local drgnx-agents-editor-draw--pool nil "Ring row overlays, reused: a list, the first N in use.")
(defvar-local drgnx-agents-editor-draw--in-use 0)
(defvar-local drgnx-agents-editor-draw--tag-overlays nil "Tag overlays of projected agents, ordinal → overlay.")

(defconst drgnx-agents-editor-draw--modes
  '(("editing" . "editing") ("pending" . "about to edit") ("reading" . "reading"))
  "The hub's mode → the words of a tag.")

;;;; Colours

(defvar drgnx-agents-editor-draw--tints (make-hash-table :test 'equal)
  "(ORDINAL . THEME) → the ring tint, emptied with the identity cache.")

(defun drgnx-agents-editor-draw--colour (ordinal)
  "Agent ORDINAL's colour string, from its identity face."
  (let ((face (plist-get (drgnx-agent-identity ordinal) :face)))
    (or (face-foreground face nil t) (face-background face nil t) (face-foreground 'default nil t))))

(defun drgnx-agents-editor-draw--tint (ordinal)
  "Agent ORDINAL's colour mixed into the default background: a ring row's background."
  (let ((key (cons ordinal (car custom-enabled-themes))))
    (or (gethash key drgnx-agents-editor-draw--tints)
        (puthash key (let ((c (drgnx-agents-editor-draw--colour ordinal)))
                       (or (and c (drgnx-color-mix c (face-background 'default nil t) 0.7)) c))
                 drgnx-agents-editor-draw--tints))))

(defun drgnx-agents-editor-draw--ring-face (ordinal kind)
  (if (eq kind 'pending)
      (list :underline (list :color (drgnx-agents-editor-draw--colour ordinal) :style 'dashes))
    (list :background (drgnx-agents-editor-draw--tint ordinal))))

;;;; Positions and tags

(defun drgnx-agents-editor-draw--line-pos (line col)
  "The position at column COL of LINE (1-based) in the current buffer, clamped to the line."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (forward-line (1- (max 1 line)))
      (min (+ (line-beginning-position) (max 0 (or col 0))) (line-end-position)))))

(defun drgnx-agents-editor-draw--tag (agent frame)
  "AGENT's tag text: its mark, handle and what it does."
  (let* ((ord (plist-get agent :ordinal))
         (mode (or (cdr (assoc (plist-get agent :mode) drgnx-agents-editor-draw--modes)) (plist-get agent :mode)))
         (where (plist-get (plist-get agent :projected) :worktree_label)))
    (concat (drgnx-agent-identity-text ord) " " (or (plist-get agent :handle) "Agent") " · " (or mode "here")
            (and where (concat " in " where))
            (and (plist-get frame :approximate) " · approximate"))))

(defun drgnx-agents-editor-draw--tags-on-p (agent agents)
  "Non-nil when AGENT's tag stays on: the setting is `always', the colour is shared, or the agent is followed."
  (and (not (eq drgnx-agents-tags 'never))
       (or (eq drgnx-agents-tags 'always)
           (equal (plist-get agent :session) drgnx-agents-editor-followed)
           (let ((face (plist-get (drgnx-agent-identity (plist-get agent :ordinal)) :face)))
             (cl-some (lambda (o) (and (not (eq o agent))
                                       (eq face (plist-get (drgnx-agent-identity (plist-get o :ordinal)) :face))))
                      agents)))))

;;;; The bars

(defun drgnx-agents-editor-draw--bar (buffer agent frame pos force)
  (let* ((ord (plist-get agent :ordinal)) (tag (drgnx-agents-editor-draw--tag agent frame)))
    (if (and (not force) (drgnx-decor-cursor-overlay buffer ord))
        (drgnx-decor-cursor-move-now buffer ord pos)
      (drgnx-decor-cursor-put buffer ord pos (drgnx-agents-editor-draw--colour ord) tag))
    (unless (drgnx-decor--glitnir-p)
      (when-let* ((ov (drgnx-decor-cursor-overlay buffer ord))) (overlay-put ov 'help-echo tag)))
    (add-hook 'kill-buffer-hook #'drgnx-agents-editor-draw--killed nil t)
    (cl-pushnew ord drgnx-agents-editor-draw--bars)))

(defun drgnx-agents-editor-draw--killed ()
  "The buffer is going: its bars go with it (decor's timers do not wait for a sweep)."
  (drgnx-agents-editor-draw--drop-bars nil))

(defun drgnx-agents-editor-draw--drop-bars (keep)
  "Remove the bars of the ordinals not in KEEP."
  (dolist (ord (cl-set-difference drgnx-agents-editor-draw--bars keep))
    (drgnx-decor-cursor-remove (current-buffer) ord))
  (setq drgnx-agents-editor-draw--bars (cl-intersection drgnx-agents-editor-draw--bars keep)))

;;;; Tags of projected agents

(defun drgnx-agents-editor-draw--projected-tag (ord agent frame pos)
  (let ((ov (or (cdr (assq ord drgnx-agents-editor-draw--tag-overlays))
                (let ((new (make-overlay pos pos (current-buffer) t nil)))
                  (push (cons ord new) drgnx-agents-editor-draw--tag-overlays)
                  new))))
    (save-excursion (goto-char pos) (move-overlay ov (line-end-position) (line-end-position)))
    (overlay-put ov 'after-string
                 (propertize (concat " " (drgnx-agents-editor-draw--tag agent frame))
                             'face (plist-get (drgnx-agent-identity ord) :face)))
    (overlay-put ov 'drgnx-agents-editor-tag ord)))

(defun drgnx-agents-editor-draw--drop-tags (keep)
  (dolist (e drgnx-agents-editor-draw--tag-overlays)
    (unless (memq (car e) keep) (delete-overlay (cdr e))))
  (setq drgnx-agents-editor-draw--tag-overlays
        (cl-remove-if-not (lambda (e) (memq (car e) keep)) drgnx-agents-editor-draw--tag-overlays)))

;;;; The visible rows: ring rows and the gutter strip

(defvar-local drgnx-agents-editor-draw--lines nil
  "Line number → [STRING ORDINAL KIND] for the lines the frame's gutter ranges cover, or nil.  STRING is the
`before-string' of the line's strip overlay (the fringe or margin spec, with its hover text).")
(defvar-local drgnx-agents-editor-draw--gpool nil "Gutter strip overlays, reused: a list, the first N in use.")
(defvar-local drgnx-agents-editor-draw--gin-use 0)
(defvar-local drgnx-agents-editor-draw--margin nil "Non-nil while this buffer holds a left margin for the strip.")

(defun drgnx-agents-editor-draw--use (pool-var n prop)
  "The Nth overlay of the pool in POOL-VAR (made, with PROP set, when missing)."
  (or (nth n (symbol-value pool-var))
      (let ((ov (make-overlay 1 1)))
        (overlay-put ov prop t)
        (when (eq prop 'drgnx-agents-editor-gutter) (overlay-put ov 'priority 100))
        (set pool-var (nconc (symbol-value pool-var) (list ov)))
        ov)))

(defun drgnx-agents-editor-draw--trim (pool used n)
  "Delete the overlays of POOL from N up to USED (the ones the last rebuild used)."
  (let ((i n))
    (while (< i used)
      (when-let* ((ov (nth i pool))) (delete-overlay ov))
      (cl-incf i))))

(defun drgnx-agents-editor-draw--rebuild-buffer (buffer)
  "Put a ring row overlay and a strip overlay on each visible row that needs one; free the overlays no row needs."
  (with-current-buffer buffer
    (let ((n 0) (g 0) (lines drgnx-agents-editor-draw--lines) (rings drgnx-agents-editor-draw--rings))
      (when (or lines rings)
        (dolist (win (get-buffer-window-list buffer nil t))
          (let* ((start (window-start win)) (rows (1+ (window-body-height win)))
                 (line (save-restriction (widen) (line-number-at-pos start))))
            (save-excursion
              (goto-char start)
              (while (> rows 0)
                (when-let* ((e (and lines (gethash line lines)))
                            (ov (drgnx-agents-editor-draw--use 'drgnx-agents-editor-draw--gpool g
                                                               'drgnx-agents-editor-gutter)))
                  (move-overlay ov (line-beginning-position) (line-beginning-position) buffer)
                  (unless (eq (overlay-get ov 'before-string) (aref e 0))
                    (overlay-put ov 'before-string (aref e 0)))
                  (cl-incf g))
                (dolist (r rings)
                  (when (and (>= line (nth 2 r)) (<= line (nth 3 r)))
                    (let ((ov (drgnx-agents-editor-draw--use 'drgnx-agents-editor-draw--pool n 'drgnx-agents-editor-ring)))
                      (move-overlay ov (line-beginning-position) (line-end-position) buffer)
                      (overlay-put ov 'face (drgnx-agents-editor-draw--ring-face (car r) (nth 1 r)))
                      (cl-incf n))))
                (cl-decf rows)
                (if (or (eobp) (not (zerop (forward-line 1)))) (setq rows 0) (cl-incf line)))))))
      (drgnx-agents-editor-draw--trim drgnx-agents-editor-draw--pool drgnx-agents-editor-draw--in-use n)
      (drgnx-agents-editor-draw--trim drgnx-agents-editor-draw--gpool drgnx-agents-editor-draw--gin-use g)
      (setq drgnx-agents-editor-draw--in-use n drgnx-agents-editor-draw--gin-use g))))

(defun drgnx-agents-editor-draw--scrolled (window _start)
  "A window scrolled: its buffer's ring rows and strip follow."
  (let ((b (window-buffer window)))
    (when (or (buffer-local-value 'drgnx-agents-editor-draw--rings b) (buffer-local-value 'drgnx-agents-editor-draw--lines b))
      (drgnx-agents-editor-draw--rebuild-buffer b))))

(defun drgnx-agents-editor-draw--resized (frame)
  (dolist (w (window-list frame 'never))
    (drgnx-agents-editor-draw--scrolled w nil)))

;;;; The gutter strip

(when (fboundp 'define-fringe-bitmap)
  (define-fringe-bitmap 'drgnx-agent-fringe-bar [#x3c] 1 8 '(top t))
  (define-fringe-bitmap 'drgnx-agent-fringe-hollow [#x24] 1 8 '(top t))
  (define-fringe-bitmap 'drgnx-agent-fringe-hatch [#x30 #x18 #x0c #x06 #x03 #x81 #xc0 #x60] 8 8 '(top t)))

(defconst drgnx-agents-editor-draw--margin-chars
  '((changed "┃" . "|") (pending "┆" . ":") (conflict "╱" . "/"))
  "Kind → (UNICODE . ASCII): the strip's character in a terminal's margin.")

(defun drgnx-agents-editor-draw--margin-char (kind first ord)
  "The margin character of a strip row: the agent's mark on the first row of a changed range, else KIND's line."
  (if (and first (eq kind 'changed))
      (drgnx-agent-identity-text ord)
    (let ((e (alist-get kind drgnx-agents-editor-draw--margin-chars)))
      (if (char-displayable-p (aref (car e) 0)) (car e) (cdr e)))))

(defun drgnx-agents-editor-draw--strip (ord kind first help)
  "The `before-string' of one strip row: a fringe bitmap in GUI frames, a margin character in terminals."
  (let ((face (plist-get (drgnx-agent-identity ord) :face)))
    (if (display-graphic-p)
        (propertize " " 'display
                    `((left-fringe ,(cond ((eq kind 'pending) 'drgnx-agent-fringe-hollow)
                                          ((eq kind 'conflict) 'drgnx-agent-fringe-hatch)
                                          (first (drgnx-agent-identity-fringe ord))
                                          (t 'drgnx-agent-fringe-bar))
                                   ,face))
                    'help-echo help)
      (propertize " " 'display (list '(margin left-margin)
                                     (concat (drgnx-margins-pad 'agents)
                                             (propertize (drgnx-agents-editor-draw--margin-char kind first ord)
                                                         'face face)))
                  'help-echo help))))

(declare-function drgnx-agent-panel-huddle-of "drgnx-agent-panel-huddle")

(defun drgnx-agents-editor-draw--conflict-help (kind help session)
  "HELP of a gutter range of KIND; a conflict range of an agent in an open huddle says so.
`o' in the follow view opens the huddle."
  (if (and (eq kind 'conflict) (fboundp 'drgnx-agent-panel-huddle-of) (drgnx-agent-panel-huddle-of session))
      (concat help " · huddle open · o opens it")
    help))

(defun drgnx-agents-editor-draw--gutter-lines (frame)
  "FRAME's gutter ranges as the line table of `drgnx-agents-editor-draw--lines', or nil when there are none."
  (when-let* ((ranges (plist-get frame :gutter)))
    (let ((table (make-hash-table)) (agents (plist-get frame :agents)))
      (dolist (g ranges)
        (let* ((ord (or (plist-get g :ordinal)
                        (plist-get (cl-find (plist-get g :session) agents :key (lambda (a) (plist-get a :session)) :test #'equal)
                                   :ordinal)
                        1))
               (kind (intern (or (plist-get g :kind) "changed")))
               (help (drgnx-agents-editor-draw--conflict-help kind (or (plist-get g :help) "") (plist-get g :session)))
               (first (drgnx-agents-editor-draw--strip ord kind t help))
               (rest (drgnx-agents-editor-draw--strip ord kind nil help)))
          (cl-loop for l from (plist-get g :start) to (or (plist-get g :end) (plist-get g :start))
                   for old = (gethash l table)
                   unless (and old (eq (aref old 2) 'conflict))
                   do (puthash l (vector (if (= l (plist-get g :start)) first rest) ord kind) table))))
      table)))

(defun drgnx-agents-editor-draw--owns-line-p (line)
  "Whether an agent's strip draws the gutter on LINE of this buffer: the change marks leave that line out
(`drgnx-hunks-skip-line-function')."
  (and drgnx-agents-editor-draw--lines (gethash line drgnx-agents-editor-draw--lines) t))

(defun drgnx-agents-editor-draw--margin (buffer on)
  "Claim one column of BUFFER's left margin while ON, for the terminal's strip (`drgnx-margins': after the debug
column, before the change marks)."
  (with-current-buffer buffer
    (unless (eq on drgnx-agents-editor-draw--margin)
      (setq drgnx-agents-editor-draw--margin on)
      (drgnx-margins-claim 'agents (and on 1) :order 1))))

(defun drgnx-agents-editor-draw--redraw-marks (&optional buffer)
  "Draw the change marks again in BUFFER (default: every buffer that has them): the strip came or went."
  (when (fboundp 'drgnx-hunks-redraw)
    (dolist (b (if buffer (list buffer) (buffer-list)))
      (when (buffer-live-p b) (ignore-errors (drgnx-hunks-redraw b))))))

;;;; Applying a frame

(defun drgnx-agents-editor-draw--apply (buffer frame &optional force)
  "Draw FRAME's agents in BUFFER: bars, ring rows and projected tags.  FORCE puts every bar again."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((agents (plist-get frame :agents)) bars tags rings)
        (dolist (a agents)
          (let* ((ord (plist-get a :ordinal)) (mode (plist-get a :mode)) (line (plist-get a :line))
                 (end (or (plist-get a :line_end) line)))
            (cond
             ((plist-get a :projected)
              (when line
                (drgnx-agents-editor-draw--projected-tag ord a frame (drgnx-agents-editor-draw--line-pos line 0))
                (push ord tags)))
             ((null line))                      ; file-only: no mark in the text
             ((equal mode "editing")
              (drgnx-agents-editor-draw--bar buffer a frame (drgnx-agents-editor-draw--line-pos end (plist-get a :col)) force)
              (push ord bars))
             ((member mode '("pending" "reading"))
              (push (list ord (intern mode) line end) rings)))))
        (drgnx-agents-editor-draw--drop-bars bars)
        (drgnx-agents-editor-draw--drop-tags tags)
        (dolist (a agents)
          (when-let* ((ord (plist-get a :ordinal)) ((memq ord bars)))
            (drgnx-decor-cursor-keep-label buffer ord (drgnx-agents-editor-draw--tags-on-p a agents))))
        (setq drgnx-agents-editor-draw--rings (nreverse rings))
        (let ((had drgnx-agents-editor-draw--lines))
          (setq drgnx-agents-editor-draw--lines (drgnx-agents-editor-draw--gutter-lines frame))
          (drgnx-agents-editor-draw--margin buffer (and drgnx-agents-editor-draw--lines (not (display-graphic-p))))
          (drgnx-agents-editor-draw--rebuild-buffer buffer)
          ;; the strip came or went: the change marks leave its lines out, or draw them again
          (unless (eq (and had t) (and drgnx-agents-editor-draw--lines t)) (drgnx-agents-editor-draw--redraw-marks buffer)))))))

(defun drgnx-agents-editor-draw--redraw-all ()
  "The identity cache cleared: resolve every colour again and put every bar again."
  (clrhash drgnx-agents-editor-draw--tints)
  (dolist (b (drgnx-agents-editor-watched-buffers))
    (when-let* ((f (drgnx-agents-editor-frame b))) (drgnx-agents-editor-draw--apply b f t))))

(defun drgnx-agents-editor-draw-clear (buffer)
  "Take every bar, ring row and tag out of BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (drgnx-agents-editor-draw--drop-bars nil)
      (remove-hook 'kill-buffer-hook #'drgnx-agents-editor-draw--killed t)
      (drgnx-agents-editor-draw--drop-tags nil)
      (setq drgnx-agents-editor-draw--rings nil drgnx-agents-editor-draw--lines nil)
      (drgnx-agents-editor-draw--margin buffer nil)
      (mapc #'delete-overlay drgnx-agents-editor-draw--pool)
      (mapc #'delete-overlay drgnx-agents-editor-draw--gpool)
      (setq drgnx-agents-editor-draw--pool nil drgnx-agents-editor-draw--in-use 0
            drgnx-agents-editor-draw--gpool nil drgnx-agents-editor-draw--gin-use 0))))

;;;; Setup

(defun drgnx-agents-editor-draw-setup ()
  "Draw frames as they arrive.  Called by the module's setup."
  (drgnx-module-hook 'drgnx-agents-editor-apply-functions draw-apply (buffer frame)
    :module 'tools/agents-in-editor
    (drgnx-agents-editor-draw--apply buffer frame))
  (drgnx-module-hook 'drgnx-agent-identity-cleared-hook draw-theme ()
    :module 'tools/agents-in-editor
    (drgnx-agents-editor-draw--redraw-all))
  (drgnx-module-hook 'window-scroll-functions draw-scroll (window start)
    :module 'tools/agents-in-editor
    (drgnx-agents-editor-draw--scrolled window start))
  (drgnx-module-hook 'window-size-change-functions draw-size (frame)
    :module 'tools/agents-in-editor
    (drgnx-agents-editor-draw--resized frame))
  (drgnx-module-hook 'drgnx-agents-editor-unwatch-functions draw-unwatch (buffer)
    :module 'tools/agents-in-editor
    (drgnx-agents-editor-draw-clear buffer))
  ;; the change marks skip the lines an agent's strip owns
  (drgnx-module-set 'drgnx-hunks-skip-line-function #'drgnx-agents-editor-draw--owns-line-p)
  (drgnx-agents-editor-draw--tags-apply))

(defun drgnx-agents-editor-draw-teardown ()
  "Take everything drawn out of every live buffer and draw the change marks again."
  (dolist (b (buffer-list)) (drgnx-agents-editor-draw-clear b))
  (drgnx-agents-editor-draw--redraw-marks)
  (clrhash drgnx-agents-editor-draw--tints))

(provide 'drgnx-agents-editor-draw)
;;; drgnx-agents-editor-draw.el ends here
