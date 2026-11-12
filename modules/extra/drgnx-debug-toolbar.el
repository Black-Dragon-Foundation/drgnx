;;; drgnx-debug-toolbar.el --- The debug toolbar card, its docked form, the status bar's segment, the Paused chip -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The session's controls while one runs (docs/develop/debugging.md, "The toolbar"; spec §6):
;;
;; - `floating' (the default): a card in a child frame at the popup elevation, centred at the top of the frame's editor
;;   window over its breadcrumb row.  One child frame per root frame, made at the first session and hidden (not
;;   deleted) between sessions: child frames are slow to make.  The grip drags it sideways; the offset is kept per
;;   frame.  It never takes the focus: a button runs its command in the parent's editor window.
;; - `docked': the same buttons at the right of the editor's tab row (`drgnx-chrome-tab-row-function').
;; - `hidden': the keys, the palette and the status bar's segment only.  A terminal frame is always this.
;;
;; The buttons follow the session's state and capabilities: Continue while stopped, Pause while running, the steps only
;; while stopped, Restart always (the hub stops and starts again when the adapter has no `restart'), Disconnect in
;; place of Stop for an attach session.  Hover shows the command's title with the active profile's key.  With two or
;; more sessions a chip names the session the controls act on; a click picks another.
;; The status bar's segment `debug' says the session and its state in the warn colour; the title row's Paused chip
;; (`drgnx-topline-paused-function') shows while it is stopped, and a click goes to the stopped line.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-pixels)
(require 'drgnx-ui-kit)
(require 'drgnx-icons)
(require 'drgnx-faces)
(declare-function drgnx-surfaces-key-label "drgnx-surfaces" (cmd-or-id &rest args))
(declare-function drgnx-state-editor-window "drgnx-state" (&optional frame))
(declare-function drgnx-look-chrome-current "drgnx-look" (&optional frame))
(declare-function drgnx-chrome-apply "drgnx-chrome" (&optional frame note))
(declare-function drgnx-debug--session "drgnx-debug" (&optional state))
(defvar drgnx-debug--sessions)
(defvar drgnx-debug--focus)
(defvar drgnx-debug-gutter--stops)
(defvar drgnx-debug-toolbar--grip-map)   ; below, with the drag

(defcustom drgnx-debug-toolbar 'floating
  "Where the debug toolbar shows while a session runs: `floating' (a card over the editor, dragged sideways by its
grip), `docked' (the buttons at the right of the editor's tab row) or `hidden' (the keys, the palette and the status
bar's segment only).  A terminal frame has neither: the segment and the keys.  A change applies at once."
  :type '(choice (const floating) (const docked) (const hidden)) :group 'drgnx
  :set (lambda (symbol value)
         (set-default symbol value)
         (when (fboundp 'drgnx-debug-toolbar-sync) (drgnx-debug-toolbar-sync t))))

(defvar drgnx-debug-toolbar--children (make-hash-table :test #'eq :weakness 'key)
  "Root frame → its card's child frame, made once and hidden between sessions.")

(defvar drgnx-debug-toolbar--offsets (make-hash-table :test #'eq :weakness 'key)
  "Root frame → the card's sideways offset from the centre of the editor window, in the frame's pixels.")

(defvar drgnx-debug-toolbar--drawn (make-hash-table :test #'eq :weakness 'key)
  "Child frame → what its text was drawn from (`drgnx-debug-toolbar--key'): an unchanged state is not drawn again.")

(defvar drgnx-debug-toolbar--docked nil
  "The docked buttons the tab rows show (`drgnx-debug-toolbar--tab-row'), or nil.")

;;;; The buttons

(defun drgnx-debug-toolbar--session ()
  "The session the controls act on (`drgnx-debug--session': the picked one, else the project's), or nil."
  (and drgnx-debug--sessions (or (drgnx-debug--session) (car drgnx-debug--sessions))))

(defun drgnx-debug-toolbar--buttons (session)
  "SESSION's buttons in order: (ID TITLE ICON FACE ENABLED), FACE the role's colour."
  (let* ((state (plist-get session :state)) (stopped (equal state "stopped")))
    (list (if stopped
              (list 'debug-start "Continue" 'play 'drgnx-accent t)
            (list 'debug-pause "Pause" 'pause 'drgnx-accent (equal state "running")))
          (list 'debug-step-over "Step Over" 'redo-dot 'drgnx-text-muted stopped)
          (list 'debug-step-in "Step Into" 'arrow-down-to-dot 'drgnx-text-muted stopped)
          (list 'debug-step-out "Step Out" 'arrow-up-from-dot 'drgnx-text-muted stopped)
          (list 'debug-restart "Restart" 'rotate-ccw 'success t)
          (if (plist-get session :attach)
              (list 'debug-disconnect "Disconnect" 'unplug 'error t)
            (list 'debug-stop "Stop" 'square 'error t)))))

(defun drgnx-debug-toolbar--help (id title)
  "TITLE with ID's key in the active profile: \"Step Over (F10)\", or TITLE alone."
  (let ((key (and (fboundp 'drgnx-surfaces-key-label) (ignore-errors (drgnx-surfaces-key-label id :short t)))))
    (if key (format "%s (%s)" title key) title)))

(defvar drgnx-debug-toolbar--maps (make-hash-table :test #'equal)
  "(ACTION . WHERE) → its keymap, made once.")

(defun drgnx-debug-toolbar--map (action where)
  "The keymap that runs ACTION (a registry id or a command) on a click in WHERE (`card' or `tab-line')."
  (let ((key (cons action where)))
    (or (gethash key drgnx-debug-toolbar--maps)
        (let ((m (make-sparse-keymap))
              (run (lambda (event) (interactive "e") (drgnx-debug-toolbar--press action event))))
          (if (eq where 'tab-line)
              (define-key m [tab-line mouse-1] run)
            (define-key m [down-mouse-1] #'ignore)          ; no region, no selected window in the card
            (define-key m [mouse-1] run))
          (puthash key m drgnx-debug-toolbar--maps)))))

(defun drgnx-debug-toolbar--press (action event)
  "Run ACTION for a click EVENT: in the editor window of the frame the card floats over (the card's own window would
have no project), the registry's way (`drgnx-ui-kit-run': its use counted)."
  (let* ((w (posn-window (event-start event)))
         (frame (and (window-live-p w) (window-frame w)))
         (root (and frame (or (frame-parent frame) frame)))
         (editor (and root (drgnx-state-editor-window root))))
    (if (window-live-p editor)
        (with-selected-window editor (drgnx-ui-kit-run action))
      (drgnx-ui-kit-run action))))

(defun drgnx-debug-toolbar--px (n frame)
  "A stretch N logical pixels wide on FRAME, as tall as a button (26)."
  (propertize " " 'display `(space :width (,(drgnx-px n frame)) :height (,(drgnx-px 26 frame)))))

(defun drgnx-debug-toolbar--button (button frame where)
  "BUTTON (`drgnx-debug-toolbar--buttons') as text on FRAME: the icon, 6 px either side (28 wide in all)."
  (pcase-let* ((`(,id ,title ,icon ,face ,enabled) button)
               (face (if enabled face 'drgnx-text-disabled))
               (s (concat (drgnx-debug-toolbar--px 6 frame) (drgnx-look-icon icon face) (drgnx-debug-toolbar--px 6 frame))))
    (add-text-properties 0 (length s)
                         (append (list 'help-echo (drgnx-debug-toolbar--help id title) 'drgnx-debug-button id)
                                 (and enabled (list 'mouse-face 'drgnx-hover-row
                                                    (if (eq where 'tab-line) 'local-map 'keymap)
                                                    (drgnx-debug-toolbar--map id where))))
                         s)
    s))

(defun drgnx-debug-toolbar--chip (session frame where)
  "The session chip: SESSION's name and a chevron; a click picks another session."
  (let ((s (concat (drgnx-debug-toolbar--px 6 frame)
                   (propertize (plist-get session :name) 'face 'drgnx-text-muted) " "
                   (drgnx-look-icon 'chevron-down 'drgnx-text-muted 14)
                   (drgnx-debug-toolbar--px 6 frame))))
    (add-text-properties 0 (length s)
                         (list 'help-echo "The session the controls act on: click for another" 'mouse-face 'drgnx-hover-row
                               (if (eq where 'tab-line) 'local-map 'keymap)
                               (drgnx-debug-toolbar--map 'debug-pick-session where))
                         s)
    s))

(defun drgnx-debug-toolbar--text (session sessions frame where)
  "The controls of SESSION on FRAME (SESSIONS: all of them, for the chip) for WHERE: `card' starts with the grip."
  (concat
   (when (eq where 'card)
     (let ((g (concat (drgnx-debug-toolbar--px 3 frame) (drgnx-look-icon 'grip-vertical 'drgnx-text-disabled 14)
                      (drgnx-debug-toolbar--px 3 frame))))
       (add-text-properties 0 (length g) (list 'help-echo "Drag to move the toolbar" 'pointer 'hdrag 'drgnx-debug-button 'grip
                                               'keymap drgnx-debug-toolbar--grip-map)
                            g)
       g))
   (mapconcat (lambda (b) (drgnx-debug-toolbar--button b frame where)) (drgnx-debug-toolbar--buttons session) "")
   (when (cdr sessions)
     (concat (drgnx-debug-toolbar--px 3 frame) (propertize "│" 'face 'drgnx-border-subtle)
             (drgnx-debug-toolbar--px 3 frame) (drgnx-debug-toolbar--chip session frame where)))))

(defun drgnx-debug-toolbar-pick-session ()
  "Pick the session the toolbar, the keys and the status bar act on."
  (interactive)
  (let* ((names (mapcar (lambda (s) (cons (format "%s (%s)" (plist-get s :name) (plist-get s :state)) (plist-get s :id)))
                        drgnx-debug--sessions))
         (pick (and names (completing-read "Session: " names nil t))))
    (when pick
      (setq drgnx-debug--focus (cdr (assoc pick names)))
      (drgnx-debug-toolbar-sync))))

;;;; The card (a child frame)

(defun drgnx-debug-toolbar--where (frame)
  "Where FRAME shows the controls: `card', `tab-line' or nil (a terminal frame, or `hidden')."
  (and (display-graphic-p frame)
       (pcase drgnx-debug-toolbar ('floating 'card) ('docked 'tab-line))))

(defun drgnx-debug-toolbar--params (parent)
  "The card's frame parameters under PARENT: never the focus; the popup chrome (the look's card, radius 8)."
  (let* ((chrome (and (featurep 'glitnir) (fboundp 'drgnx-look-chrome-current) (drgnx-look-chrome-current)))
         (ring (or (alist-get 'child-frame-border-width chrome) 0)))
    `((parent-frame . ,parent) (minibuffer . nil) (name . "drgnx-debug-toolbar") (drgnx-debug-toolbar . t)
      (undecorated . t) (no-accept-focus . t) (no-focus-on-map . t) (no-other-frame . t) (skip-taskbar . t)
      (unsplittable . t) (no-special-glyphs . t) (desktop-dont-save . t)
      (internal-border-width . ,(drgnx-px 4 parent)) (border-width . 0)
      (child-frame-border-width . ,(if (> ring 0) (drgnx-px-line ring parent) 0))
      (menu-bar-lines . 0) (tool-bar-lines . 0) (tab-bar-lines . 0) (left-fringe . 0) (right-fringe . 0)
      (vertical-scroll-bars) (horizontal-scroll-bars) (cursor-type . nil) (visibility . nil)
      ,@(seq-remove (lambda (p) (memq (car p) '(child-frame-border-width transition))) chrome))))

(defun drgnx-debug-toolbar--make (parent)
  "A new card under PARENT, hidden, with its own buffer."
  (let ((buf (generate-new-buffer " *drgnx-debug-toolbar*" t))
        (frame (let ((after-make-frame-functions nil) (before-make-frame-hook nil))
                 (make-frame (drgnx-debug-toolbar--params parent)))))
    (with-current-buffer buf
      (setq-local cursor-type nil truncate-lines t mode-line-format nil header-line-format nil tab-line-format nil
                  cursor-in-non-selected-windows nil)
      (face-remap-add-relative 'default 'drgnx-surface-raised))
    (set-window-buffer (frame-root-window frame) buf)
    (set-window-dedicated-p (frame-root-window frame) t)
    frame))

(defun drgnx-debug-toolbar--child (parent)
  "PARENT's card: the one made before while it lives, else a new one."
  (let ((f (gethash parent drgnx-debug-toolbar--children)))
    (unless (and f (frame-live-p f))
      (setq f (drgnx-debug-toolbar--make parent))
      (puthash parent f drgnx-debug-toolbar--children))
    f))

(defun drgnx-debug-toolbar--place (parent child)
  "Put CHILD centred over the top of PARENT's editor window, under its tab row, moved by the frame's offset and kept
inside the window."
  (let* ((w (or (drgnx-state-editor-window parent) (frame-selected-window parent)))
         (edges (window-pixel-edges w)) (left (nth 0 edges)) (right (nth 2 edges))
         (width (frame-pixel-width child))
         (x (+ left (/ (- right left width) 2) (gethash parent drgnx-debug-toolbar--offsets 0))))
    (set-frame-position child (max left (min x (- right width))) (+ (nth 1 edges) (window-tab-line-height w)))))

(defun drgnx-debug-toolbar--key (session sessions frame)
  "What the card on FRAME shows for SESSION and SESSIONS, compared with `equal'."
  (list (plist-get session :id) (plist-get session :state) (plist-get session :attach) (plist-get session :name)
        (length sessions) (drgnx-pixels-scale frame) (bound-and-true-p drgnx-look-icons) custom-enabled-themes
        (bound-and-true-p drgnx-keys--generation)))   ; the keys in the titles

(defun drgnx-debug-toolbar--show (parent session sessions)
  "Show PARENT's card for SESSION (drawn again only when what it shows changed)."
  (let* ((child (drgnx-debug-toolbar--child parent))
         (key (drgnx-debug-toolbar--key session sessions parent)))
    (unless (equal key (gethash child drgnx-debug-toolbar--drawn))
      (let ((win (frame-root-window child)))
        (with-current-buffer (window-buffer win)
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert (drgnx-debug-toolbar--text session sessions parent 'card))
            (goto-char (point-min))))
        (let ((size (window-text-pixel-size win nil nil 10000 10000))
              (border (* 2 (frame-parameter child 'internal-border-width))))
          (set-frame-size child (+ (car size) border) (+ (cdr size) border) t)))
      (puthash child key drgnx-debug-toolbar--drawn))
    (drgnx-debug-toolbar--place parent child)
    (unless (frame-visible-p child) (make-frame-visible child))))

(defun drgnx-debug-toolbar--hide (parent)
  "PARENT's card out of sight (kept for the next session)."
  (let ((f (gethash parent drgnx-debug-toolbar--children)))
    (when (and f (frame-live-p f) (frame-visible-p f)) (make-frame-invisible f))))

(defun drgnx-debug-toolbar--nudge (parent offset)
  "PARENT's card OFFSET pixels from the centre, kept for that frame."
  (puthash parent offset drgnx-debug-toolbar--offsets)
  (let ((f (gethash parent drgnx-debug-toolbar--children)))
    (when (and f (frame-live-p f)) (drgnx-debug-toolbar--place parent f))))

(defun drgnx-debug-toolbar-drag (event)
  "Drag the card sideways by its grip: the mouse is tracked only while the button is down."
  (interactive "e")
  (let* ((child (window-frame (posn-window (event-start event)))) (parent (frame-parent child))
         (x0 (car (mouse-absolute-pixel-position))) (start (gethash parent drgnx-debug-toolbar--offsets 0)))
    (when parent
      (track-mouse
        (while (mouse-movement-p (read-event))
          (drgnx-debug-toolbar--nudge parent (+ start (- (car (mouse-absolute-pixel-position)) x0))))))))

(defvar drgnx-debug-toolbar--grip-map
  (let ((m (make-sparse-keymap))) (define-key m [down-mouse-1] #'drgnx-debug-toolbar-drag) (define-key m [mouse-1] #'ignore) m)
  "The grip's keys: a press starts the drag.")

;;;; Docked: the tab row

(defun drgnx-debug-toolbar--tab-row (w)
  "`drgnx-chrome-tab-row-function': the docked buttons in the tab row of W, its frame's editor window, or nil."
  (and drgnx-debug-toolbar--docked (eq w (drgnx-state-editor-window (window-frame w))) drgnx-debug-toolbar--docked))

;;;; Drawing the state

(defun drgnx-debug-toolbar-sync (&optional all)
  "Show the controls for the sessions now: each graphical root frame's card or tab row, the status bar and the title
row.  ALL: the setting changed, so every form is drawn again."
  (let* ((sessions drgnx-debug--sessions) (session (drgnx-debug-toolbar--session))
         (docked (and session (eq drgnx-debug-toolbar 'docked)
                      (drgnx-debug-toolbar--text session sessions (selected-frame) 'tab-line))))
    (dolist (f (frame-list))
      (unless (frame-parent f)
        (if (and session (eq (drgnx-debug-toolbar--where f) 'card))
            (drgnx-debug-toolbar--show f session sessions)
          (drgnx-debug-toolbar--hide f))))
    (unless (and (not all) (equal-including-properties docked drgnx-debug-toolbar--docked))
      (setq drgnx-debug-toolbar--docked docked)
      (when (fboundp 'drgnx-chrome-apply)
        (dolist (f (frame-list)) (unless (frame-parent f) (drgnx-chrome-apply f)))))
    (force-mode-line-update t)))

(defun drgnx-debug-toolbar--replace (&rest _)
  "The state store's `windows-changed', `frame-resized' or `editor-changed': the visible cards follow their editor
window."
  (maphash (lambda (parent child)
             (when (and (frame-live-p parent) (frame-live-p child) (frame-visible-p child))
               (drgnx-debug-toolbar--place parent child)))
           drgnx-debug-toolbar--children))

(defun drgnx-debug-toolbar-delete-all ()
  "Delete the cards, their buffers and the docked buttons (the module going off)."
  (maphash (lambda (_parent child)
             (when (frame-live-p child)
               (let ((buf (window-buffer (frame-root-window child))))
                 (delete-frame child t)
                 (when (buffer-live-p buf) (kill-buffer buf)))))
           drgnx-debug-toolbar--children)
  (clrhash drgnx-debug-toolbar--children)
  (clrhash drgnx-debug-toolbar--drawn)
  (setq drgnx-debug-toolbar--docked nil))

;;;; The status bar and the title row

(defun drgnx-debug-toolbar--state-text (session)
  "SESSION's state in words: \"paused on breakpoint\", \"running\", \"starting\"."
  (if (equal (plist-get session :state) "stopped")
      (if-let* ((r (plist-get session :reason))) (format "paused on %s" r) "paused")
    (or (plist-get session :state) "starting")))

(defun drgnx-debug-toolbar--segment ()
  "The status bar's `debug': \"<bug> NAME · STATE\" in the warn colour while a session runs; nothing otherwise."
  (when-let* ((s (drgnx-debug-toolbar--session)))
    (concat (drgnx-look-icon 'bug 'drgnx-status-warn 14) " "
            (propertize (format "%s · %s" (plist-get s :name) (drgnx-debug-toolbar--state-text s)) 'face 'drgnx-status-warn))))

(defun drgnx-debug-toolbar-paused-p ()
  "Non-nil while the session the controls act on is stopped (the title row's Paused chip).  Reads a variable."
  (let ((s (drgnx-debug-toolbar--session))) (and s (equal (plist-get s :state) "stopped"))))

(defun drgnx-debug-toolbar-show-stop ()
  "Go to the stopped line of the session the controls act on."
  (interactive)
  (let* ((s (drgnx-debug-toolbar--session))
         (top (and s (seq-find (lambda (o) (and (overlay-buffer o) (eq (overlay-get o 'drgnx-debug-stop) 'top)))
                               (cdr (assoc (plist-get s :id) drgnx-debug-gutter--stops))))))
    (unless top (user-error "No stopped line"))
    (pop-to-buffer (overlay-buffer top))
    (goto-char (overlay-start top))))

(provide 'drgnx-debug-toolbar)
;;; drgnx-debug-toolbar.el ends here
