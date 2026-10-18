;;; drgnx-topline.el --- The top line: where you are, and the three keys that open everything -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Part A of M12f.  A quiet line at the top of the frame, built on `tab-bar-mode' with no tabs (drgnx has no
;; workspaces): `◆ PROJECT · BRANCH' on the left (the project and branch of the most recently used editor), a hint
;; in the middle (`⌕ KEY files · KEY commands · KEY all keys', the keys of the active profile, each one clickable),
;; and, only when drgnx draws the title itself (`drgnx-face-drawn-title-p'), `– ▢ ✕' on the right with the empty
;; area dragging the frame.  It exists to tell someone who has just opened drgnx where to start.
;;
;; The tab bar calls the format on its redisplay, so `drgnx-topline--line' reads cached state only: the editor's
;; `vc-mode' text for the branch (never git), the project root in the buffer-local cache the breadcrumb keeps
;; (`drgnx-chrome--root'; no file or process access, a miss shows `drgnx'), the keys the registry already resolved.
;; The cache is filled off redisplay, from the change bus's `editor-changed' edge (never for a remote directory).
;; What the line makes is memoized on what it shows (the editor buffer, its `vc-mode' text, directory and cached
;; project, the frame and its width, the keys, the glyph forms), so a redisplay that changes nothing costs a few
;; comparisons.  An error while making it never escapes: the line shows its mark alone for a few seconds (an
;; empty tab bar is taken away by Emacs, which resizes every window), and nothing here then touches the frames.
;; Only terminal frames get their number of lines decided here (a graphical frame has one, from `tab-bar-mode'),
;; and a decision is made once, never repeated against what redisplay has done since.  A tab-bar format of your
;; own, or a tab bar that was on before this module, is never replaced.  See docs/guide/face.md ("The top line").

;;; Code:
(require 'subr-x)
(require 'tab-bar)
(require 'drgnx-modules)
(require 'drgnx-registry)
(declare-function drgnx-face-glyph "drgnx-face")
(declare-function drgnx-face-drawn-title-p "drgnx-face")
(declare-function drgnx-surfaces-key "drgnx-surfaces")
(declare-function drgnx-tty-sendable-key "drgnx-tty-fallback")
(declare-function drgnx-signal-editor-window "drgnx-signal")
(declare-function drgnx-chrome--project-root "drgnx-chrome")
(declare-function drgnx-signal-subscribe "drgnx-signal")
(declare-function drgnx-signal-unsubscribe "drgnx-signal")
(defvar vc-mode)
(defvar drgnx-chrome--root)
(defvar drgnx-face-glyphs)

(defgroup drgnx-topline nil
  "The top line: project and branch, the keys that open everything, window controls."
  :group 'drgnx-face :prefix "drgnx-topline-")

(defface drgnx-topline '((t :inherit (shadow header-line)))
  "The top line's quiet text (labels, separators, the empty area)."
  :group 'drgnx-topline)

(defface drgnx-topline-strong '((t :inherit (bold header-line)))
  "The project and the keys on the top line."
  :group 'drgnx-topline)

(defvar drgnx-topline--active nil
  "Non-nil once the module has run: from then on a setting applies to the open frames when it changes.")

(defun drgnx-topline--set (symbol value)
  "Set SYMBOL to VALUE; when the module is running, apply it to every open frame."
  (set-default symbol value)
  (when drgnx-topline--active (drgnx-topline--apply)))

(defcustom drgnx-topline t
  "Show the top line (project and branch, the keys that open everything).
A tab-bar format you set yourself is never replaced: then the line stays off."
  :type 'boolean :set #'drgnx-topline--set :group 'drgnx-topline)

(defcustom drgnx-topline-min-lines 20
  "A terminal frame with fewer lines than this shows no top line (windows always show it)."
  :type 'natnum :set #'drgnx-topline--set :group 'drgnx-topline)

;;;; What the line shows

(defconst drgnx-topline--hint-commands
  '((go-quick-open "files" "Open a file of the project by name")
    (palette "commands" "Run any command by name")
    (keys-sheet "all keys" "Every key of the active profile"))
  "The hint: registry command ID, the label shown after its key, and the help text.")

(defun drgnx-topline--glyph (name ascii)
  "The glyph NAME for the selected frame (see `drgnx-face-glyph'); ASCII when it is not known."
  (or (and (fboundp 'drgnx-face-glyph) (drgnx-face-glyph name)) ascii))

(defun drgnx-topline--branch (buffer)
  "The branch git put in BUFFER's `vc-mode' text (\" Git-main\"), or nil.  Reads the cached text; never runs git."
  (let ((vc (buffer-local-value 'vc-mode buffer)))
    (when (and (stringp vc) (string-match "\\`[ ]*[[:alpha:]]+[-:@!?]\\(.+\\)" (substring-no-properties vc)))
      (match-string 1 (substring-no-properties vc)))))

(defun drgnx-topline--project (buffer)
  "The name of BUFFER's project (the folder of its root), or nil.  Reads the breadcrumb's buffer-local cache
\(`drgnx-chrome--root') and nothing else: no project lookup, so no file access, from redisplay."
  (when (boundp 'drgnx-chrome--root)
    (let ((cache (buffer-local-value 'drgnx-chrome--root buffer)))
      (when (and (consp cache) (stringp (cdr cache))
                 (equal (car cache) (buffer-local-value 'default-directory buffer)))
        (file-name-nondirectory (directory-file-name (cdr cache)))))))

(defun drgnx-topline--note-editor (&optional buffer)
  "Fill BUFFER's (default: the editor's) project cache, so the line can show its project.
On the change bus's `editor-changed' edge (idle, never redisplay); never for a remote directory.  Redraws the line
when the cache changed."
  (let ((buffer (or buffer (and (fboundp 'drgnx-signal-editor-window)
                                (let ((w (drgnx-signal-editor-window))) (and (window-live-p w) (window-buffer w)))))))
    (when (and (buffer-live-p buffer) (fboundp 'drgnx-chrome--project-root))
      (with-current-buffer buffer
        (unless (file-remote-p default-directory)
          (let ((before (and (boundp 'drgnx-chrome--root) drgnx-chrome--root)))
            (drgnx-chrome--project-root (or (buffer-file-name) default-directory))
            (unless (equal before drgnx-chrome--root) (force-mode-line-update t))))))))

(defun drgnx-topline--key (cmd)
  "The key that runs registry command CMD as the active profile has it, else the key Emacs gives its command, else nil.
On a terminal, a chord it cannot send is shown the way it can (`drgnx-tty-sendable-key', when M12b is there)."
  (let* ((s (drgnx-surfaces-key cmd))
         (suffix (string-search " (in " s))
         (key (if (string-empty-p s)
                  (let ((c (drgnx-cmd-command cmd)))
                    (when-let* ((k (and (symbolp c) (where-is-internal c nil t)))) (key-description k)))
                (substring s 0 suffix))))
    (when key
      (concat (if (and (not (display-graphic-p)) (fboundp 'drgnx-tty-sendable-key))
                  (or (ignore-errors (drgnx-tty-sendable-key (selected-frame) key)) key)
                key)
              (and suffix (substring s suffix))))))

(defun drgnx-topline--drawn-title-p (frame)
  "Non-nil when drgnx draws FRAME's title itself (A2's `drgnx-face-drawn-title-p'; until it exists, never)."
  (and (fboundp 'drgnx-face-drawn-title-p) (drgnx-face-drawn-title-p frame)))

(defun drgnx-topline--text (text face)
  "TEXT in FACE."
  (propertize text 'face face))

(defun drgnx-topline--item (key text &optional command help)
  "A tab-bar item named KEY showing TEXT; a click runs COMMAND (a symbol) and rests on HELP."
  `(,key menu-item ,text ,(if (and command (symbolp command)) command 'ignore) :help ,(or help "")))

(defun drgnx-topline--gap (key columns drag)
  "An item of COLUMNS spaces; with DRAG, pressing it drags the frame (a drawn title).
Real spaces, not an `:align-to' display property on one: the tab bar redraws only when its items are not `equal',
and `equal' ignores text properties, so a new width would have left the old gap on the screen."
  (drgnx-topline--item key (propertize (make-string (max 0 columns) ?\s) 'face 'drgnx-topline)
                       (and drag (fboundp 'mouse-drag-frame-move) 'mouse-drag-frame-move)
                       (and drag "Drag to move the window")))

(defun drgnx-topline--mark (buffer width)
  "The mark and the place: `◆ PROJECT · BRANCH' for BUFFER, cut to fit WIDTH columns."
  (let* ((project (or (drgnx-topline--project buffer) "drgnx"))
         (branch (drgnx-topline--branch buffer))
         (text (concat " " (drgnx-topline--text (drgnx-topline--glyph 'diamond "<>") 'drgnx-topline) " "
                       (drgnx-topline--text project 'drgnx-topline-strong)
                       (and branch (concat (drgnx-topline--text (drgnx-topline--glyph 'sep " | ") 'drgnx-topline)
                                           (drgnx-topline--text branch 'drgnx-topline))))))
    (drgnx-topline--item 'drgnx-topline-mark (truncate-string-to-width text (max 8 (- width 4)) nil nil t))))

(defun drgnx-topline--hint ()
  "The hint's items: the search glyph, then each of the three keys with its label (a command without a key is
left out), each one running its command.  nil when none has a key."
  (let ((i 0) (items nil))
    (pcase-dolist (`(,id ,label ,help) drgnx-topline--hint-commands)
      (when-let* ((cmd (drgnx-commands-get id))
                  (key (drgnx-topline--key cmd)))
        (when items
          (push (drgnx-topline--item (intern (format "drgnx-topline-sep-%d" (setq i (1+ i))))
                                     (drgnx-topline--text (drgnx-topline--glyph 'sep " | ") 'drgnx-topline))
                items))
        (push (drgnx-topline--item (intern (format "drgnx-topline-%s" id))
                                   (concat (drgnx-topline--text key 'drgnx-topline-strong)
                                           (drgnx-topline--text (concat " " label) 'drgnx-topline))
                                   (drgnx-cmd-command cmd) help)
              items)))
    (when items
      (cons (drgnx-topline--item 'drgnx-topline-search
                                 (drgnx-topline--text (concat (drgnx-topline--glyph 'search "/") " ") 'drgnx-topline))
            (nreverse items)))))

(defun drgnx-topline--controls ()
  "The window controls' items: minimise, maximise, close."
  (list (drgnx-topline--item 'drgnx-topline-minimize
                             (drgnx-topline--text (concat " " (drgnx-topline--glyph 'minimize "-") " ") 'drgnx-topline-strong)
                             'iconify-frame "Minimise")
        (drgnx-topline--item 'drgnx-topline-maximize
                             (drgnx-topline--text (concat (drgnx-topline--glyph 'maximize "[]") " ") 'drgnx-topline-strong)
                             'toggle-frame-maximized "Maximise or restore")
        (drgnx-topline--item 'drgnx-topline-close
                             (drgnx-topline--text (concat (drgnx-topline--glyph 'close "x") " ") 'drgnx-topline-strong)
                             'delete-frame "Close the window")))

(defun drgnx-topline--width (items)
  "The columns the tab-bar ITEMS take (their strings)."
  (let ((n 0)) (dolist (i items) (setq n (+ n (string-width (nth 2 i))))) n))

(defun drgnx-topline--build (buffer width drawn)
  "The items for BUFFER on a frame WIDTH columns wide; DRAWN: drgnx draws the title, so the controls show."
  (let* ((controls (and drawn (drgnx-topline--controls)))
         (controls-w (drgnx-topline--width controls))
         (mark (drgnx-topline--mark buffer (- width controls-w)))   ; never under the controls
         (hint (with-current-buffer buffer (drgnx-topline--hint)))
         (hint-w (drgnx-topline--width hint))
         (mark-w (string-width (nth 2 mark)))
         (hint (and hint (<= (+ mark-w hint-w controls-w 4) width) hint)))
    (let ((column mark-w) (items (list mark)))
      (when hint                                         ; centred
        (let ((gap (max 2 (- (/ (- width hint-w) 2) column))))   ; never touching the mark
          (setq items (append items (cons (drgnx-topline--gap 'drgnx-topline-gap-1 gap drawn) hint))
                column (+ column gap hint-w))))
      (when drawn                                        ; at the right end
        (setq items (append items (cons (drgnx-topline--gap 'drgnx-topline-gap-2 (- width controls-w column) t) controls))))
      items)))

;;;; The memo: a redisplay that changes nothing reuses the line

(defvar drgnx-topline--memo (make-hash-table :test #'eq :weakness 'key)
  "Frame → the vector of the items last made for it and what they were made from, compared in place so a redisplay
that changes nothing allocates nothing: [FRAME BUFFER VC-MODE DIRECTORY PROJECT-CACHE WIDTH DRAWN, then for each of the
three hint commands its command and its keys, GLYPHS ITEMS].  One vector per frame (the tab bar of each frame is drawn
with that frame selected, so two frames would otherwise make the line again at every redisplay), weak on the frame, so
a deleted frame's goes with it.  The vector holds the editor's buffer strongly: a killed buffer is kept until that
frame's next redisplay replaces it (a few objects that are otherwise gone; it never accumulates).")

(defun drgnx-topline--forget ()
  "Empty the memo."
  (clrhash drgnx-topline--memo))

(defun drgnx-topline--same-p (m frame buffer width drawn)
  "Non-nil when the memo vector M was made from exactly these: FRAME, BUFFER (its `vc-mode' text, directory and
project cache), WIDTH columns, DRAWN, the hint commands and their keys, and the glyph table.  Allocates nothing."
  (let ((i 7) (same t))
    (and (eq (aref m 0) frame) (eq (aref m 1) buffer)
         (eq (aref m 2) (buffer-local-value 'vc-mode buffer))
         (eq (aref m 3) (buffer-local-value 'default-directory buffer))
         (eq (aref m 4) (and (boundp 'drgnx-chrome--root) (buffer-local-value 'drgnx-chrome--root buffer)))
         (eql (aref m 5) width) (eq (aref m 6) drawn)
         (eq (aref m 13) drgnx-face-glyphs)
         (dolist (spec drgnx-topline--hint-commands same)
           (let ((cmd (drgnx-commands-get (car spec))))
             (unless (and (eq (aref m i) (and cmd (drgnx-cmd-command cmd)))
                          (eq (aref m (1+ i)) (and cmd (drgnx-cmd-bound cmd))))
               (setq same nil))
             (setq i (+ i 2)))))))

(defun drgnx-topline--stamp (m frame buffer width drawn items)
  "Remember ITEMS in the memo vector M with what they were made from (see `drgnx-topline--same-p')."
  (let ((i 7))
    (aset m 0 frame) (aset m 1 buffer)
    (aset m 2 (buffer-local-value 'vc-mode buffer))
    (aset m 3 (buffer-local-value 'default-directory buffer))
    (aset m 4 (and (boundp 'drgnx-chrome--root) (buffer-local-value 'drgnx-chrome--root buffer)))
    (aset m 5 width) (aset m 6 drawn)
    (aset m 13 drgnx-face-glyphs) (aset m 14 items)
    (dolist (spec drgnx-topline--hint-commands)
      (let ((cmd (drgnx-commands-get (car spec))))
        (aset m i (and cmd (drgnx-cmd-command cmd)))
        (aset m (1+ i) (and cmd (drgnx-cmd-bound cmd)))
        (setq i (+ i 2))))
    items))

(defvar drgnx-topline--error nil
  "The message of the error the line last failed with, or nil while it works.  Never shown as a message.
While it is set the line shows its mark alone (for `drgnx-topline-retry-seconds') and `drgnx-topline--fit' leaves
the frames alone.")

(defvar drgnx-topline--error-at nil "When `drgnx-topline--error' was recorded (`drgnx-topline--now'), or nil.")

(defvar drgnx-topline-retry-seconds 10
  "Seconds the line shows its mark alone after an error, before it is made again.")

(defun drgnx-topline--now () (float-time))

(defconst drgnx-topline--fallback '((drgnx-topline-mark menu-item " drgnx" ignore :help ""))
  "What the line shows while it is failing: not empty, because Emacs takes away a tab bar with no items.")

(defun drgnx-topline--failing-p ()
  "Non-nil while the line shows its fallback: it failed less than `drgnx-topline-retry-seconds' ago (a clock that
went back counts as long ago)."
  (and drgnx-topline--error-at
       (let ((d (- (drgnx-topline--now) drgnx-topline--error-at)))
         (<= 0 d drgnx-topline-retry-seconds))))

(defun drgnx-topline--line ()
  "The top line's tab-bar items, from cached state only (see the Commentary); memoized on what they show.
Everything runs under an error guard: a failure is recorded in `drgnx-topline--error' and the line shows its mark
alone for `drgnx-topline-retry-seconds'.  A memo hit allocates nothing."
  (if (drgnx-topline--failing-p)
      drgnx-topline--fallback
    (condition-case err
        (let* ((frame (selected-frame))
               (window (and (fboundp 'drgnx-signal-editor-window) (drgnx-signal-editor-window)))
               (buffer (if (window-live-p window) (window-buffer window) (current-buffer)))
               (width (frame-text-cols frame))   ; `frame-width' conses ~140 cells and 14 strings per call
               (drawn (and (drgnx-topline--drawn-title-p frame) t)))
          (let ((m (or (gethash frame drgnx-topline--memo) (puthash frame (make-vector 15 nil) drgnx-topline--memo))))
            (unless (drgnx-topline--same-p m frame buffer width drawn)
              (drgnx-topline--stamp m frame buffer width drawn (drgnx-topline--build buffer width drawn)))
            (setq drgnx-topline--error nil drgnx-topline--error-at nil)
            (aref m 14)))
      ;; An error would leave the tab bar without items, which Emacs answers by taking the line away; and then
      ;; every redisplay would give it back and take it away again.
      (error (setq drgnx-topline--error (error-message-string err) drgnx-topline--error-at (drgnx-topline--now))
             drgnx-topline--fallback))))

(defun drgnx-topline--resized (frame)
  "On `window-size-change-functions': redraw the tab bar when FRAME is not the width the line was made for.
It never touches `tab-bar-lines'.  Does nothing while the line is failing."
  (when (and (not drgnx-topline--error) (frame-live-p frame) (not (frame-parent frame)))
    (let ((m (gethash frame drgnx-topline--memo)))
      (unless (and m (eql (aref m 5) (frame-text-cols frame)))
        (force-mode-line-update t)))))

(defun drgnx-topline-format ()
  "The `tab-bar-format' list that draws the top line (one function, `drgnx-topline--line')."
  (list #'drgnx-topline--line))

;;;; Turning it on and off

(defvar drgnx-topline--saved nil
  "What this module changed to turn the line on, to put back when it goes off: (:mode WAS-ON :format F :show S).
nil while it is off.")

(defvar drgnx-topline--format nil "The `tab-bar-format' value this module set, to tell it from a user's own.")

(defun drgnx-topline--users-format-p ()
  "Non-nil when `tab-bar-format' is the user's own: neither Emacs's default nor what this module set."
  (let ((now (default-value 'tab-bar-format)))
    (not (or (equal now (eval (car (get 'tab-bar-format 'standard-value)) t))
             (and drgnx-topline--format (equal now drgnx-topline--format))))))

(defun drgnx-topline--lines (frame)
  "1 when FRAME shows the top line, else 0: a terminal with fewer than `drgnx-topline-min-lines' lines shows none."
  (if (or (display-graphic-p frame) (>= (frame-height frame) drgnx-topline-min-lines)) 1 0))

(defun drgnx-topline--fit (&optional frame)
  "Give FRAME (default: the selected one) its top line, or none when it is a short terminal.
On `after-make-frame-functions' and `window-size-change-functions'; the frame keeps the state this sets
\(`tab-bar-lines-keep-state'), so the tab bar's own updates leave it alone.  A child frame is left alone.
While the line is failing (`drgnx-topline--error') this does nothing at all, so a terminal frame made in that time
gets its decision only after the line works again (the next size change or `drgnx-topline--fit-all')."
  (let ((frame (or frame (selected-frame))))
    (when (and (frame-live-p frame) (not (frame-parent frame))
               (not drgnx-topline--error))                  ; while the line is failing, nothing here touches a frame
      (cond
       ((not (equal (default-value 'tab-bar-format) drgnx-topline--format))   ; the user took the tab bar over
        (set-frame-parameter frame 'tab-bar-lines-keep-state nil))
       ((display-graphic-p frame)
        ;; A graphical frame has its one line from `tab-bar-mode'; it is never set here.  Only what a text frame's
        ;; parameters left on it (the frame made after init takes over the initial one's) is undone, once.
        (when (frame-parameter frame 'tab-bar-lines-keep-state)
          (set-frame-parameter frame 'tab-bar-lines-keep-state nil)
          (set-frame-parameter frame 'drgnx-topline-lines nil)
          (tab-bar--update-tab-bar-lines (list frame))))
       (t
        ;; A terminal frame: decide once per change of the answer.  What redisplay did to `tab-bar-lines' since is
        ;; not undone, or the two would resize every window against each other on every redisplay.
        (let ((want (drgnx-topline--lines frame)))
          (unless (eq (frame-parameter frame 'tab-bar-lines-keep-state) t)
            (set-frame-parameter frame 'tab-bar-lines-keep-state t))
          (unless (eql (frame-parameter frame 'drgnx-topline-lines) want)
            (set-frame-parameter frame 'drgnx-topline-lines want)
            (set-frame-parameter frame 'tab-bar-lines want))))))))

(defun drgnx-topline--fit-all ()
  "Fit every frame.  On `emacs-startup-hook' and `window-setup-hook': while init runs the frame is still the initial
text frame, whose size and parameters (the top line's among them) the window's frame then takes over."
  (mapc #'drgnx-topline--fit (frame-list)))

(defvar drgnx-topline--timer nil "The idle timer that fills the first editor's project cache, or nil.")

(defun drgnx-topline--first-note ()
  "Fill the open editor's project cache once (the editor-changed edge only tells of changes)."
  (setq drgnx-topline--timer nil)
  (drgnx-topline--note-editor))

(defun drgnx-topline--on ()
  "Turn the line on (idempotent): `tab-bar-mode' with the format of `drgnx-topline-format' and no tabs."
  (unless drgnx-topline--saved
    (setq drgnx-topline--saved (list :mode tab-bar-mode :format (default-value 'tab-bar-format)
                                     :show (default-value 'tab-bar-show)
                                     :face (get 'tab-bar 'face-defface-spec))))
  (setq drgnx-topline--format (drgnx-topline-format))
  ;; No tabs to size: auto-width walks the items and makes strings on every redisplay.  A value of the user's stays.
  (when (and (not (plist-member drgnx-topline--saved :auto-width))
             (eq (default-value 'tab-bar-auto-width) (eval (car (get 'tab-bar-auto-width 'standard-value)) t)))
    (setq drgnx-topline--saved (plist-put drgnx-topline--saved :auto-width (default-value 'tab-bar-auto-width)))
    (setq-default tab-bar-auto-width nil))
  (setq-default tab-bar-format drgnx-topline--format
                tab-bar-show t)                          ; 1 would hide the bar: it has one tab
  (face-spec-set 'tab-bar '((t :inherit header-line :box nil)) 'face-defface-spec)   ; the quiet line, in the theme's chrome
  (add-hook 'after-make-frame-functions #'drgnx-topline--fit)
  (add-hook 'window-size-change-functions #'drgnx-topline--fit)
  (add-hook 'window-size-change-functions #'drgnx-topline--resized)
  (add-hook 'emacs-startup-hook #'drgnx-topline--fit-all)
  (add-hook 'window-setup-hook #'drgnx-topline--fit-all)
  (when (fboundp 'drgnx-signal-subscribe) (drgnx-signal-subscribe 'editor-changed #'drgnx-topline--note-editor))
  (unless (timerp drgnx-topline--timer)                  ; the project of the editor that is open now, once, when idle
    (setq drgnx-topline--timer (run-with-idle-timer 0.5 nil #'drgnx-topline--first-note)))
  (tab-bar-mode 1)
  (drgnx-topline--fit-all))

(defun drgnx-topline--off ()
  "Turn the line off (idempotent), putting back what it changed."
  (remove-hook 'after-make-frame-functions #'drgnx-topline--fit)
  (remove-hook 'window-size-change-functions #'drgnx-topline--fit)
  (remove-hook 'window-size-change-functions #'drgnx-topline--resized)
  (when (timerp drgnx-topline--timer) (cancel-timer drgnx-topline--timer))
  (setq drgnx-topline--timer nil)
  (remove-hook 'emacs-startup-hook #'drgnx-topline--fit-all)
  (remove-hook 'window-setup-hook #'drgnx-topline--fit-all)
  (when (fboundp 'drgnx-signal-unsubscribe) (drgnx-signal-unsubscribe 'editor-changed #'drgnx-topline--note-editor))
  (when drgnx-topline--saved
    (let ((saved drgnx-topline--saved) (format drgnx-topline--format))
      (setq drgnx-topline--saved nil drgnx-topline--format nil
            drgnx-topline--error nil drgnx-topline--error-at nil)
      (drgnx-topline--forget)
      (when-let* ((spec (plist-get saved :face))) (face-spec-set 'tab-bar spec 'face-defface-spec))
      (dolist (f (frame-list))
        (set-frame-parameter f 'tab-bar-lines-keep-state nil)
        (set-frame-parameter f 'drgnx-topline-lines nil))
      (when (equal (default-value 'tab-bar-format) format)   ; a format the user set since stays
        (setq-default tab-bar-format (plist-get saved :format) tab-bar-show (plist-get saved :show)))
      (when (and (plist-member saved :auto-width) (null (default-value 'tab-bar-auto-width)))   ; still ours
        (setq-default tab-bar-auto-width (plist-get saved :auto-width)))
      (unless (plist-get saved :mode) (tab-bar-mode -1))
      (tab-bar--update-tab-bar-lines t))))

(defun drgnx-topline--apply ()
  "Make the line match `drgnx-topline': on unless it is off, the user has a tab-bar format of their own, or the
tab bar was already on before this module (then it is theirs)."
  (if (and drgnx-topline (not (drgnx-topline--users-format-p))
           (or drgnx-topline--saved (not tab-bar-mode)))
      (drgnx-topline--on)
    (drgnx-topline--off)))

(defun drgnx-topline-setup ()
  "Turn the top line on (called by the module ui/face)."
  (setq drgnx-topline--active t)
  (drgnx-topline--apply))

(provide 'drgnx-topline)
;;; drgnx-topline.el ends here
