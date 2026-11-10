;;; drgnx-look-density.el --- ui/look: density and line heights -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx-look-density' (compact, comfortable, roomy) sets the look's sizes in logical pixels: the code line, the
;; tree row, the tab row, the status bar, the title row, the gap between cards, the panel padding and the tree
;; indent.  This file applies the code line (as the frame parameter `line-spacing', in device pixels, on every
;; frame and every frame made later, again when the frame is resized or its scale or font changes) and answers the
;; UI rows' spacing; the
;; chrome reads the other sizes through `drgnx-look-density-value'.  The code line's owners: the code role's
;; `:line-height' when the user set it, then the density.  A `line-spacing' set as the default stays (the obsolete
;; `drgnx-face-line-spacing' sets one), and then the frame parameter is left alone.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-setting)
(require 'drgnx-state)
(require 'drgnx-type-faces)
(require 'drgnx-pixels)

(defvar drgnx-look-font-code)
(defvar drgnx-look-fonts-applied-hook)
(declare-function drgnx-module-running-p "drgnx-modules" (module))

(defconst drgnx-look-density-table
  '((code-line 19 21 23) (tree-row 22 26 30) (tab-row 30 34 38) (status-bar 22 24 28) (title-row 34 38 42)
    (gap 4 6 8) (panel-padding 8 12 16) (tree-indent 12 12 14))
  "The look's sizes in logical pixels: (KEY COMPACT COMFORTABLE ROOMY).")

(drgnx-defsetting drgnx-look-density 'comfortable
  "How much room the look gives: `compact', `comfortable' or `roomy' (the line, row, tab, bar and gap sizes).  A
change applies at once."
  :type '(choice (const compact) (const comfortable) (const roomy)) :group 'drgnx-look
  :scope 'global :agents 'never :apply #'drgnx-look-density--settings-apply
  :schema '(enum compact comfortable roomy))

(defvar drgnx-look-density-changed-hook nil
  "Run after a change of `drgnx-look-density' has been applied while ui/look runs: the cards give the gap again.")

(defun drgnx-look-density-value (key &optional density)
  "KEY's size in logical pixels at DENSITY (default `drgnx-look-density')."
  (let ((row (or (assq key drgnx-look-density-table) (error "drgnx-look-density: no size %S" key)))
        (d (or density drgnx-look-density)))
    (nth (pcase d ('compact 1) ('comfortable 2) ('roomy 3) (_ 2)) row)))

(defun drgnx-look-density-code-line ()
  "The code line's height in logical pixels: the code role's `:line-height' when the user set it, else the density's."
  (let ((value (default-value 'drgnx-look-font-code))
        (default (plist-get (cdr (assq 'code drgnx-type-defaults)) :line-height)))
    (or (and (consp value) (plist-get value :line-height)
             (not (equal (plist-get value :line-height) default))
             (plist-get value :line-height))
        (drgnx-look-density-value 'code-line))))

(defconst drgnx-look-density--saved-parameter 'drgnx-look-density-saved
  "The frame parameter that holds (LINE-SPACING) the frame had before this module wrote its own.")

(defun drgnx-look-density--extra (frame)
  "The `line-spacing' FRAME needs, in device pixels: the code line less the frame's line height.  nil when the
user set a default `line-spacing', which then stays."
  (unless (default-value 'line-spacing)
    (max 0 (- (drgnx-px (drgnx-look-density-code-line) frame)
              (frame-char-height frame)))))

(defun drgnx-look-density-apply-frame (frame)
  "Give FRAME the code line: its `line-spacing' parameter (a terminal frame has none)."
  (when (frame-live-p frame)
    (if-let* ((extra (drgnx-look-density--extra frame)))
        (progn
          (unless (frame-parameter frame drgnx-look-density--saved-parameter)
            (set-frame-parameter frame drgnx-look-density--saved-parameter (list (frame-parameter frame 'line-spacing))))
          (unless (eql (frame-parameter frame 'line-spacing) extra)
            (set-frame-parameter frame 'line-spacing extra)))
      (drgnx-look-density--restore-frame frame))))

(defun drgnx-look-density--restore-frame (frame)
  "Give FRAME the line spacing it had before this module."
  (when-let* ((saved (frame-parameter frame drgnx-look-density--saved-parameter)))
    (set-frame-parameter frame 'line-spacing (car saved))
    (set-frame-parameter frame drgnx-look-density--saved-parameter nil)))

(defun drgnx-look-density--frames ()
  "The graphical root frames."
  (seq-filter (lambda (f) (and (display-graphic-p f) (not (frame-parent f)))) (frame-list)))

(defun drgnx-look-density-apply ()
  "The code line on every graphical frame, at once."
  (mapc #'drgnx-look-density-apply-frame (drgnx-look-density--frames)))

(defun drgnx-look-density--frame-resized (data)
  "The store's `frame-resized': a scale change resizes the frame, so the line is given again in its pixels."
  (let ((frame (plist-get data :frame)))
    (when (and (frame-live-p frame) (frame-parameter frame drgnx-look-density--saved-parameter))
      (drgnx-look-density-apply-frame frame))))

(defun drgnx-look-density--frame-added (data)
  "The store's `frame-added' (now lane, before the frame is drawn): a frame made after setup (`C-x 5 2',
`emacsclient -c', a daemon's first graphical frame) gets the code line too."
  (let ((frame (plist-get data :frame)))
    (when (and (frame-live-p frame) (display-graphic-p frame) (not (frame-parent frame)))
      (drgnx-look-density-apply-frame frame))))

(defun drgnx-look-density--settings-apply ()
  "The `:apply' of `drgnx-look-density': at once, while ui/look runs."
  (when (drgnx-module-running-p 'ui/look)
    (drgnx-look-density-apply)
    (run-hooks 'drgnx-look-density-changed-hook)))

(defun drgnx-look-ui-line-spacing (&optional line-px density scale)
  "The cons (TOP . BOTTOM) that brings a UI buffer's rows from LINE-PX device pixels (default the selected frame's
line height) to the tree row at DENSITY and SCALE: the extra pixels half above and half below, the odd one below."
  (let* ((scale (or scale (drgnx-pixels-scale)))
         (row (drgnx-px (drgnx-look-density-value 'tree-row density) nil scale))
         (extra (max 0 (- row (or line-px (frame-char-height)))))
         (top (/ extra 2)))
    (cons top (- extra top))))

(defun drgnx-look-density-on ()
  "The code line follows the density and the code role, on every graphical frame and as the frames change."
  (drgnx-state-subscribe 'frame-resized #'drgnx-look-density--frame-resized)
  (drgnx-state-subscribe 'frame-added #'drgnx-look-density--frame-added :lane 'now)
  (add-hook 'drgnx-look-fonts-applied-hook #'drgnx-look-density-apply)
  (drgnx-look-density-apply))

(defun drgnx-look-density-off ()
  "Undo `drgnx-look-density-on': every frame's line spacing as it was."
  (drgnx-state-unsubscribe 'frame-resized #'drgnx-look-density--frame-resized)
  (drgnx-state-unsubscribe 'frame-added #'drgnx-look-density--frame-added)
  (remove-hook 'drgnx-look-fonts-applied-hook #'drgnx-look-density-apply)
  (dolist (f (frame-list)) (drgnx-look-density--restore-frame f)))

(provide 'drgnx-look-density)
;;; drgnx-look-density.el ends here
