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

;;;; The rings

(defun drgnx-agents-editor-draw--use (n)
  "The Nth ring row overlay of the pool (made when missing)."
  (or (nth n drgnx-agents-editor-draw--pool)
      (let ((ov (make-overlay 1 1)))
        (overlay-put ov 'drgnx-agents-editor-ring t)
        (setq drgnx-agents-editor-draw--pool (nconc drgnx-agents-editor-draw--pool (list ov)))
        ov)))

(defun drgnx-agents-editor-draw--rebuild-buffer (buffer)
  "Put a ring row overlay on each visible row of BUFFER's rings; free the overlays no row needs."
  (with-current-buffer buffer
    (let ((n 0))
      (when drgnx-agents-editor-draw--rings
        (dolist (win (get-buffer-window-list buffer nil t))
          (let* ((start (window-start win)) (rows (1+ (window-body-height win)))
                 (line (save-restriction (widen) (line-number-at-pos start))))
            (save-excursion
              (goto-char start)
              (while (> rows 0)
                (dolist (r drgnx-agents-editor-draw--rings)
                  (when (and (>= line (nth 2 r)) (<= line (nth 3 r)))
                    (let ((ov (drgnx-agents-editor-draw--use n)))
                      (move-overlay ov (line-beginning-position) (line-end-position) buffer)
                      (overlay-put ov 'face (drgnx-agents-editor-draw--ring-face (car r) (nth 1 r)))
                      (cl-incf n))))
                (cl-decf rows)
                (if (or (eobp) (not (zerop (forward-line 1)))) (setq rows 0) (cl-incf line)))))))
      (let ((i n))
        (while (< i drgnx-agents-editor-draw--in-use)
          (when-let* ((ov (nth i drgnx-agents-editor-draw--pool))) (delete-overlay ov))
          (cl-incf i)))
      (setq drgnx-agents-editor-draw--in-use n))))

(defun drgnx-agents-editor-draw--scrolled (window _start)
  "A window scrolled: its buffer's ring rows follow."
  (let ((b (window-buffer window)))
    (when (buffer-local-value 'drgnx-agents-editor-draw--rings b)
      (drgnx-agents-editor-draw--rebuild-buffer b))))

(defun drgnx-agents-editor-draw--resized (frame)
  (dolist (w (window-list frame 'never))
    (drgnx-agents-editor-draw--scrolled w nil)))

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
        (drgnx-agents-editor-draw--rebuild-buffer buffer)))))

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
      (setq drgnx-agents-editor-draw--rings nil)
      (drgnx-agents-editor-draw--rebuild-buffer buffer)
      (mapc #'delete-overlay drgnx-agents-editor-draw--pool)
      (setq drgnx-agents-editor-draw--pool nil drgnx-agents-editor-draw--in-use 0))))

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
  (drgnx-agents-editor-draw--tags-apply))

(defun drgnx-agents-editor-draw-teardown ()
  "Take everything drawn out of every live buffer."
  (dolist (b (buffer-list)) (drgnx-agents-editor-draw-clear b))
  (clrhash drgnx-agents-editor-draw--tints))

(provide 'drgnx-agents-editor-draw)
;;; drgnx-agents-editor-draw.el ends here
