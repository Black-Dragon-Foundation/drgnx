;;; drgnx-tty-layout.el --- Module ui/terminal-layout: the workbench in a small terminal -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A terminal has the size it has: the workbench's docks follow it.  For each terminal frame
;; (`drgnx-tty-layout-apply'):
;;
;; - The sizes are fractions of the terminal, through the frame parameters the docks already read:
;;   `drgnx-wb-dock-px' (the sidebar: 25% of the columns, at least 20), `drgnx-wb-right-px' (the right dock: 30%,
;;   at least 24), `drgnx-wb-panel-px' (the panel: 30% of the lines, at least 6).  In a terminal a pixel is a
;;   column or a line.
;; - A new frame shows the sidebar when it has `drgnx-tty-layout-columns' columns and the panel when it has
;;   `drgnx-tty-layout-lines' lines; the right dock stays hidden, as in a graphical window.  A dock the size
;;   kept from showing is shown when the terminal grows enough — unless you toggled it since.
;; - A resize re-applies the sizes (`window-size-change-functions').  It never closes a dock, whatever you or
;;   the layout opened.  A dock you resized
;;   yourself, with the mouse or a resize command (`drgnx-tty-layout-resize-commands'), keeps that width (or
;;   height); a popup, a minibuffer or Emacs clamping a dock to a small frame is no choice of yours.
;; - Below 40 columns or 12 lines nothing is shown or resized, and whatever a too small window makes
;;   `split-window' signal never reaches you: the dock is tried again at the next size.
;; - Below 30 lines the frame parameter `drgnx-chrome-breadcrumb' is `off'.
;;
;; An EDITOR frame (`emacsclient -t FILE') shows the editor only and is left alone.  Nothing here prompts or
;; signals: it runs in hooks.  See docs/guide/terminal.md and docs/guide/workbench.md.

;;; Code:
(require 'seq)
(require 'cl-lib)
(require 'drgnx-hooks)
(require 'drgnx-modules)
(require 'drgnx-wb)
(require 'drgnx-frame-kind)
(declare-function drgnx-wb-area-show "drgnx-area")
(declare-function drgnx-wb-area-window "drgnx-area")
(declare-function drgnx-chrome-apply "drgnx-chrome")

(defcustom drgnx-tty-layout-columns 120
  "Columns a new terminal window needs to show the sidebar (a narrower one starts with the editor alone; the
sidebar comes when the terminal grows this wide)."
  :type 'integer :group 'drgnx)

(defcustom drgnx-tty-layout-lines 30
  "Lines a new terminal window needs to show the panel (a shorter one starts without it; the panel comes when
the terminal grows this tall)."
  :type 'integer :group 'drgnx)

(defconst drgnx-tty-layout--min-columns 40 "Below this many columns nothing is shown or resized.")
(defconst drgnx-tty-layout--min-lines 12 "Below this many lines nothing is shown or resized.")
(defconst drgnx-tty-layout--breadcrumb-lines 30 "Below this many lines the breadcrumb is off.")

(defvar drgnx-tty-layout--active nil
  "Non-nil once the module's setup has run: a module that is switched off still has its file loaded, and then
lays nothing out.")

(defvar drgnx-tty-layout--applying nil
  "Non-nil while the layout shows a dock itself: that is no toggle by the user (`drgnx-tty-layout--toggled').")

(defun drgnx-tty-layout-sizes (columns lines)
  "The dock sizes for a terminal of COLUMNS by LINES: (:dock COLUMNS :right COLUMNS :panel LINES)."
  (list :dock (max 20 (round (* 0.25 columns)))
        :right (max 24 (round (* 0.30 columns)))
        :panel (max 6 (round (* 0.30 lines)))))

(defun drgnx-tty-layout--fits-p (dock columns lines)
  "A terminal of COLUMNS by LINES has room to show DOCK (`dock', the sidebar, or `panel')."
  (pcase dock
    ('dock (>= columns drgnx-tty-layout-columns))
    ('panel (>= lines drgnx-tty-layout-lines))))

(defun drgnx-tty-layout--showing-p (dock)
  (pcase dock
    ('dock (drgnx-wb-sidebar-showing-p))
    ('panel (and (fboundp 'drgnx-wb-area-window) (drgnx-wb-area-window 'panel) t))))

(defun drgnx-tty-layout--show (dock)
  (pcase dock
    ('dock (drgnx-wb-show-sidebar))
    ('panel (when (fboundp 'drgnx-wb-area-show) (drgnx-wb-area-show 'panel)))))

;; Which docks the layout looks after: DOCK is the sidebar, PANEL the bottom panel, RIGHT the right dock.
(defconst drgnx-tty-layout--docks '(dock panel right))

(defun drgnx-tty-layout--param (key)
  (pcase key ('dock 'drgnx-wb-dock-px) ('panel 'drgnx-wb-panel-px) ('right 'drgnx-wb-right-px)))

(defun drgnx-tty-layout--window (key)
  "The selected frame's window of dock KEY, or nil."
  (if (eq key 'dock)
      (car (drgnx-wb--dock-windows))
    (and (fboundp 'drgnx-wb-area-window) (drgnx-wb-area-window key))))

(defun drgnx-tty-layout--size-of (key)
  "The size, in columns (lines for the panel), of the shown dock KEY, or nil."
  (when-let* ((w (drgnx-tty-layout--window key)))
    (if (eq key 'panel) (window-pixel-height w) (window-pixel-width w))))

(defun drgnx-tty-layout--resize-dock (key size)
  "Make the shown dock KEY SIZE columns (lines for the panel); a window that cannot be that size stays as it is."
  (when-let* ((w (drgnx-tty-layout--window key)))
    (let ((window-resize-pixelwise t) (horizontal (not (eq key 'panel))))
      (ignore-errors
        (window-resize w (- size (if horizontal (window-pixel-width w) (window-pixel-height w))) horizontal nil t)))))

(defun drgnx-tty-layout--withheld-drop (dock)
  (set-frame-parameter nil 'drgnx-tty-layout-withheld
                       (remq dock (frame-parameter nil 'drgnx-tty-layout-withheld))))

(defun drgnx-tty-layout--try-show (dock)
  "Show DOCK; if the split fails part-way, take the half-built dock down, so the next size tries it whole."
  (let ((drgnx-tty-layout--applying t))
    (condition-case nil
        (drgnx-tty-layout--show dock)
      (error (when (drgnx-tty-layout--showing-p dock)
               (ignore-errors (pcase dock
                                ('dock (drgnx-wb-hide-sidebar))
                                ('panel (drgnx-wb-area-hide 'panel)))))))))

(defcustom drgnx-tty-layout-resize-commands
  '(mouse-drag-vertical-line mouse-drag-mode-line mouse-drag-header-line enlarge-window shrink-window
                             enlarge-window-horizontally shrink-window-horizontally)
  "The commands with which you resize a window.  A dock whose size a command of these changed is the size you
chose, and the layout keeps it.  Any other change of a dock's size (a popup borrowing the panel, a growing
minibuffer, Emacs squeezing a dock into a small frame) is not a choice.  Add the command of a package that
resizes windows for you."
  :type '(repeat symbol) :group 'drgnx)

(defvar drgnx-tty-layout--dragging nil
  "Non-nil between the start of a mouse drag on a divider and the next command that is not part of it.  The
drag's moves and its end run as an anonymous function Emacs binds for the drag, not as the command that began it.")

(defvar drgnx-tty-layout--before nil
  "(FRAME (KEY . SIZE) …): the sizes of FRAME's shown docks before the resize command that is running.")

(defun drgnx-tty-layout--problem (err)
  (push (format "ui/terminal-layout: %s" (error-message-string err)) drgnx-hooks-problems)
  nil)

(defun drgnx-tty-layout--resize-step-p ()
  "`this-command' resizes a window: a resize command, or a step of a mouse drag one of them began."
  (or (memq this-command drgnx-tty-layout-resize-commands)
      (and drgnx-tty-layout--dragging (not (symbolp this-command)))))

(defun drgnx-tty-layout--managed-p (frame)
  "FRAME is a terminal frame the layout looks after."
  (and (not (display-graphic-p frame)) (frame-parameter frame 'drgnx-tty-layout-size)
       (not (frame-parameter frame 'drgnx-tty-editor-only))))

(defun drgnx-tty-layout--before-command ()
  "`pre-command-hook': before a resize command of yours (or a step of a drag), in a terminal frame the layout
looks after, note the sizes of the shown docks.  Cheap and silent: every other command returns at the first or
second test."
  (condition-case err
      (progn
        (setq drgnx-tty-layout--before nil)
        (when (and drgnx-tty-layout--active (drgnx-tty-layout--resize-step-p))
          (let ((frame (selected-frame)))
            (when (drgnx-tty-layout--managed-p frame)
              (setq drgnx-tty-layout--before
                    (cons frame (delq nil (mapcar (lambda (key) (when-let* ((size (drgnx-tty-layout--size-of key)))
                                                                  (cons key size)))
                                                  drgnx-tty-layout--docks))))))))
    (error (drgnx-tty-layout--problem err))))

(defun drgnx-tty-layout--notice-drags (before)
  "A shown dock whose size is not what it was BEFORE the resize command that just ran (an alist KEY . SIZE):
you resized it.  It is yours from now on and its size is the one on record, which a resize of the terminal
restores."
  (let ((set (frame-parameter nil 'drgnx-tty-layout-set)) (owned (frame-parameter nil 'drgnx-tty-layout-owned)))
    (dolist (key drgnx-tty-layout--docks)
      (let ((size (drgnx-tty-layout--size-of key)) (was (alist-get key before)))
        (when (and size was (/= size was))
          (setf (alist-get key set) size)
          (cl-pushnew key owned))))
    (set-frame-parameter nil 'drgnx-tty-layout-set set)
    (set-frame-parameter nil 'drgnx-tty-layout-owned owned)))

(defun drgnx-tty-layout--after-command ()
  "`post-command-hook': after a resize command of yours (or a step of a drag) that the `pre-command-hook'
function saw, notice the dock it resized.  A dock that changed size some other way before or between commands is
not noticed.  Returns t when it looked."
  (condition-case err
      (when drgnx-tty-layout--active
        (let ((step (drgnx-tty-layout--resize-step-p)) (before drgnx-tty-layout--before))
          (setq drgnx-tty-layout--before nil)
          (setq drgnx-tty-layout--dragging
                (if step
                    (or drgnx-tty-layout--dragging
                        (and (symbolp this-command) (string-prefix-p "mouse-drag" (symbol-name this-command))))
                  nil))
          (when (and step before (eq (car before) (selected-frame)))
            (drgnx-tty-layout--notice-drags (cdr before))
            t)))
    (error (drgnx-tty-layout--problem err))))

(defun drgnx-tty-layout--fit (columns lines)
  "In the selected frame, COLUMNS by LINES with room: give the docks their sizes — except one you sized
yourself, which keeps your size —, show the docks the size had kept hidden and now has room for, and resize
the docks that show."
  (let* ((sizes (drgnx-tty-layout-sizes columns lines))
         (wanted (list (cons 'dock (plist-get sizes :dock)) (cons 'panel (plist-get sizes :panel))
                       (cons 'right (plist-get sizes :right))))
         (owned (frame-parameter nil 'drgnx-tty-layout-owned))
         (mine (seq-remove (lambda (key) (memq key owned)) drgnx-tty-layout--docks)))
    (dolist (key mine) (set-frame-parameter nil (drgnx-tty-layout--param key) (alist-get key wanted)))
    (dolist (dock (frame-parameter nil 'drgnx-tty-layout-withheld))
      (cond ((drgnx-tty-layout--showing-p dock) (drgnx-tty-layout--withheld-drop dock))
            ((drgnx-tty-layout--fits-p dock columns lines)
             (drgnx-tty-layout--try-show dock)
             ;; hiding a half-built dock remembered its size: the size it was meant to have stays
             (when (memq dock mine) (set-frame-parameter nil (drgnx-tty-layout--param dock) (alist-get dock wanted)))
             (when (drgnx-tty-layout--showing-p dock) (drgnx-tty-layout--withheld-drop dock)))))
    (dolist (key mine) (drgnx-tty-layout--resize-dock key (alist-get key wanted)))
    ;; a dock you sized stays that size, whatever Emacs made of it when the terminal changed
    (dolist (c (seq-filter (lambda (c) (memq (car c) owned)) (frame-parameter nil 'drgnx-tty-layout-set)))
      (unless (member (drgnx-tty-layout--size-of (car c)) (list nil (cdr c)))
        (drgnx-tty-layout--resize-dock (car c) (cdr c))))
    ;; the size on record for each dock: what the layout gave it (as it came out), to tell a size you chose later
    (set-frame-parameter nil 'drgnx-tty-layout-set
                         (append (mapcar (lambda (key) (cons key (or (drgnx-tty-layout--size-of key) (alist-get key wanted))))
                                         mine)
                                 (seq-filter (lambda (c) (memq (car c) owned))
                                             (frame-parameter nil 'drgnx-tty-layout-set))))))

(defun drgnx-tty-layout-apply (frame &optional opening)
  "Lay out terminal FRAME by its size (see the file's commentary); nothing while the module is off.  OPENING:
FRAME is new, so the sidebar and the panel are wanted, shown as far as the size allows; it counts once per
frame.  A call that finds the frame's size as it was changes nothing; a new size gives every dock its
fraction, except one you resized (`drgnx-tty-layout--notice-drags'), which keeps your size."
  (when (and drgnx-tty-layout--active (frame-live-p frame) (not (display-graphic-p frame))
             (not (frame-parameter frame 'drgnx-tty-editor-only)))
    (let* ((columns (frame-width frame)) (lines (frame-height frame))
           (opening (and opening (not (frame-parameter frame 'drgnx-tty-layout-size))))
           (breadcrumb (and (< lines drgnx-tty-layout--breadcrumb-lines) 'off))
           (same (equal (frame-parameter frame 'drgnx-tty-layout-size) (cons columns lines))))
      (unless (eq (frame-parameter frame 'drgnx-chrome-breadcrumb) breadcrumb)
        (set-frame-parameter frame 'drgnx-chrome-breadcrumb breadcrumb)
        ;; the parameter alone redraws nothing: the chrome reads it now
        (when (bound-and-true-p drgnx-chrome-mode) (drgnx-chrome-apply frame)))
      (when opening (set-frame-parameter frame 'drgnx-tty-layout-withheld (list 'dock 'panel)))
      (unless same (set-frame-parameter frame 'drgnx-tty-layout-size (cons columns lines)))
      (when (and (not same) (>= columns drgnx-tty-layout--min-columns) (>= lines drgnx-tty-layout--min-lines))
        (with-selected-frame frame (drgnx-tty-layout--fit columns lines)))
      t)))

;;;; Hooks

(defun drgnx-tty-layout--own-frame-p (frame)
  "FRAME is a terminal frame of this Emacs's own terminal (`emacs -nw'), not a daemon's client or its initial frame."
  (and (eq (drgnx-state-frame-kind frame) 'tty) (not (frame-parameter frame 'client))))

(defun drgnx-tty-layout--startup ()
  "`window-setup-hook': the first window of `emacs -nw' is new (a daemon's clients are laid out as
`drgnx-tty-frames' sets them up)."
  (let ((frame (selected-frame)))
    (when (drgnx-tty-layout--own-frame-p frame)
      (condition-case err (drgnx-tty-layout-apply frame t)
        (error (push (format "ui/terminal-layout: %s" (error-message-string err)) drgnx-hooks-problems))))))

(defun drgnx-tty-layout--resized (frame)
  "`window-size-change-functions': a terminal frame the layout looks after changed size."
  (when (and (frame-live-p frame) (frame-parameter frame 'drgnx-tty-layout-size))
    (condition-case err (drgnx-tty-layout-apply frame)
      (error (push (format "ui/terminal-layout: %s" (error-message-string err)) drgnx-hooks-problems)))))

(defun drgnx-tty-layout--toggled (dock)
  "The user showed or hid DOCK: the size no longer decides it."
  (unless drgnx-tty-layout--applying
    (when (frame-parameter nil 'drgnx-tty-layout-withheld) (drgnx-tty-layout--withheld-drop dock))))

(defun drgnx-tty-layout--sidebar-toggled (&rest _) (drgnx-tty-layout--toggled 'dock))

(defun drgnx-tty-layout--area-toggled (area &rest _) (when (eq area 'panel) (drgnx-tty-layout--toggled 'panel)))

(defun drgnx-tty-layout--install ()
  (setq drgnx-tty-layout--active t)
  (add-hook 'window-size-change-functions #'drgnx-tty-layout--resized)
  (add-hook 'window-setup-hook #'drgnx-tty-layout--startup)
  (add-hook 'pre-command-hook #'drgnx-tty-layout--before-command)
  (add-hook 'post-command-hook #'drgnx-tty-layout--after-command)
  (dolist (f '(drgnx-wb-show-sidebar drgnx-wb-hide-sidebar))
    (advice-add f :after #'drgnx-tty-layout--sidebar-toggled))
  (dolist (f '(drgnx-wb-area-show drgnx-wb-area-hide))
    (advice-add f :after #'drgnx-tty-layout--area-toggled)))

(defun drgnx-tty-layout--uninstall ()
  (setq drgnx-tty-layout--active nil drgnx-tty-layout--dragging nil drgnx-tty-layout--before nil)
  (remove-hook 'window-size-change-functions #'drgnx-tty-layout--resized)
  (remove-hook 'window-setup-hook #'drgnx-tty-layout--startup)
  (remove-hook 'pre-command-hook #'drgnx-tty-layout--before-command)
  (remove-hook 'post-command-hook #'drgnx-tty-layout--after-command)
  (dolist (f '(drgnx-wb-show-sidebar drgnx-wb-hide-sidebar))
    (advice-remove f #'drgnx-tty-layout--sidebar-toggled))
  (dolist (f '(drgnx-wb-area-show drgnx-wb-area-hide))
    (advice-remove f #'drgnx-tty-layout--area-toggled)))

(defconst drgnx-tty-layout--frame-parameters
  '(drgnx-tty-layout-size drgnx-tty-layout-set drgnx-tty-layout-owned drgnx-tty-layout-withheld)
  "What the layout keeps on each terminal frame (the docks' sizes are the docks' own, `drgnx-wb-dock-px' …).")

(defun drgnx-tty-layout--off ()
  "The module's teardown: it lays nothing out from now on (`drgnx-tty-layout--uninstall'), and each terminal frame
forgets what the layout kept, so the module turned on again lays it out as new.  The docks keep the sizes they
have; the breadcrumb the layout turned off in a short terminal comes back."
  (drgnx-tty-layout--uninstall)
  (dolist (frame (frame-list))
    (when (frame-parameter frame 'drgnx-tty-layout-size)
      (dolist (p drgnx-tty-layout--frame-parameters) (set-frame-parameter frame p nil))
      (when (eq (frame-parameter frame 'drgnx-chrome-breadcrumb) 'off)
        (set-frame-parameter frame 'drgnx-chrome-breadcrumb nil)
        (when (bound-and-true-p drgnx-chrome-mode) (ignore-errors (drgnx-chrome-apply frame)))))))

(drgnx-module-define 'ui/terminal-layout
                     :doc "The workbench in a small terminal: docks by the terminal's size, as fractions of it, never closing one you opened."
                     :stage 'startup
                     :setup #'drgnx-tty-layout--install
                     :teardown #'drgnx-tty-layout--off)

(provide 'drgnx-tty-layout)
;;; drgnx-tty-layout.el ends here
