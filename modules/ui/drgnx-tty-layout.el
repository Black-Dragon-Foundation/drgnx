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
;;   the layout opened.
;; - Below 40 columns or 12 lines nothing is shown or resized, and whatever a too small window makes
;;   `split-window' signal never reaches you: the dock is tried again at the next size.
;; - Below 30 lines the frame parameter `drgnx-chrome-breadcrumb' is `off'.
;;
;; An EDITOR frame (`emacsclient -t FILE') shows the editor only and is left alone.  Nothing here prompts or
;; signals: it runs in hooks.  See docs/guide/terminal.md and docs/guide/workbench.md.

;;; Code:
(require 'seq)
(require 'drgnx-hooks)
(require 'drgnx-modules)
(require 'drgnx-wb)
(declare-function drgnx-wb-area-show "drgnx-area")
(declare-function drgnx-wb-area-window "drgnx-area")

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

(defun drgnx-tty-layout--resize (window size horizontal)
  "Make WINDOW SIZE columns (HORIZONTAL) or lines; a window that cannot be that size stays as it is."
  (let ((window-resize-pixelwise t))
    (ignore-errors
      (window-resize window (- size (if horizontal (window-pixel-width window) (window-pixel-height window)))
                     horizontal nil t))))

(defun drgnx-tty-layout--withheld-drop (dock)
  (set-frame-parameter nil 'drgnx-tty-layout-withheld
                       (remq dock (frame-parameter nil 'drgnx-tty-layout-withheld))))

(defun drgnx-tty-layout--fit (columns lines)
  "In the selected frame, COLUMNS by LINES with room: set the sizes, show the docks the size had kept hidden and
now has room for, resize the docks that show."
  (let ((sizes (drgnx-tty-layout-sizes columns lines)))
    (set-frame-parameter nil 'drgnx-wb-dock-px (plist-get sizes :dock))
    (set-frame-parameter nil 'drgnx-wb-right-px (plist-get sizes :right))
    (set-frame-parameter nil 'drgnx-wb-panel-px (plist-get sizes :panel))
    (dolist (dock (frame-parameter nil 'drgnx-tty-layout-withheld))
      (cond ((drgnx-tty-layout--showing-p dock) (drgnx-tty-layout--withheld-drop dock))
            ((drgnx-tty-layout--fits-p dock columns lines)
             ;; a failing split (the room was not there after all) leaves the dock for the next size
             (let ((drgnx-tty-layout--applying t)) (ignore-errors (drgnx-tty-layout--show dock)))
             (when (drgnx-tty-layout--showing-p dock) (drgnx-tty-layout--withheld-drop dock)))))
    (when-let* ((w (car (drgnx-wb--dock-windows)))) (drgnx-tty-layout--resize w (plist-get sizes :dock) t))
    (when (fboundp 'drgnx-wb-area-window)
      (when-let* ((w (drgnx-wb-area-window 'panel))) (drgnx-tty-layout--resize w (plist-get sizes :panel) nil))
      (when-let* ((w (drgnx-wb-area-window 'right))) (drgnx-tty-layout--resize w (plist-get sizes :right) t)))))

(defun drgnx-tty-layout-apply (frame &optional opening)
  "Lay out terminal FRAME by its size (see the file's commentary).  OPENING: FRAME is new, so the sidebar and
the panel are wanted, shown as far as the size allows; it counts once per frame.  A resize that leaves
the frame's size as it was changes nothing, so a size you dragged a dock to stays until the terminal resizes."
  (when (and (frame-live-p frame) (not (display-graphic-p frame))
             (not (frame-parameter frame 'drgnx-tty-editor-only)))
    (let ((columns (frame-width frame)) (lines (frame-height frame))
          (opening (and opening (not (frame-parameter frame 'drgnx-tty-layout-size)))))
      (set-frame-parameter frame 'drgnx-chrome-breadcrumb (and (< lines drgnx-tty-layout--breadcrumb-lines) 'off))
      (when opening (set-frame-parameter frame 'drgnx-tty-layout-withheld (list 'dock 'panel)))
      (unless (equal (frame-parameter frame 'drgnx-tty-layout-size) (cons columns lines))
        (set-frame-parameter frame 'drgnx-tty-layout-size (cons columns lines))
        (when (and (>= columns drgnx-tty-layout--min-columns) (>= lines drgnx-tty-layout--min-lines))
          (with-selected-frame frame (drgnx-tty-layout--fit columns lines))))
      t)))

;;;; Hooks

(defun drgnx-tty-layout--own-frame-p (frame)
  "FRAME is a terminal frame of this Emacs's own terminal (`emacs -nw'), not a daemon's client or its initial frame."
  (and (frame-live-p frame) (not (display-graphic-p frame)) (not (frame-parameter frame 'client))
       (not (equal (terminal-name (frame-terminal frame)) "initial_terminal"))))

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
  (add-hook 'window-size-change-functions #'drgnx-tty-layout--resized)
  (add-hook 'window-setup-hook #'drgnx-tty-layout--startup)
  (dolist (f '(drgnx-wb-show-sidebar drgnx-wb-hide-sidebar))
    (advice-add f :after #'drgnx-tty-layout--sidebar-toggled))
  (dolist (f '(drgnx-wb-area-show drgnx-wb-area-hide))
    (advice-add f :after #'drgnx-tty-layout--area-toggled)))

(defun drgnx-tty-layout--uninstall ()
  (remove-hook 'window-size-change-functions #'drgnx-tty-layout--resized)
  (remove-hook 'window-setup-hook #'drgnx-tty-layout--startup)
  (dolist (f '(drgnx-wb-show-sidebar drgnx-wb-hide-sidebar))
    (advice-remove f #'drgnx-tty-layout--sidebar-toggled))
  (dolist (f '(drgnx-wb-area-show drgnx-wb-area-hide))
    (advice-remove f #'drgnx-tty-layout--area-toggled)))

(drgnx-module-define 'ui/terminal-layout
                     :doc "The workbench in a small terminal: docks by the terminal's size, as fractions of it, never closing one you opened."
                     :stage 'startup
                     :setup #'drgnx-tty-layout--install)

(provide 'drgnx-tty-layout)
;;; drgnx-tty-layout.el ends here
