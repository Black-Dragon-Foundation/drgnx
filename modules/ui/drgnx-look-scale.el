;;; drgnx-look-scale.el --- ui/look: the UI scale, every size and every font from 100 to 200 % -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx-look-scale' (percent, 100 to 200 in steps of 5) multiplies the display's own scale.  On every graphical
;; root frame it sets the frame parameter `drgnx-ui-scale', which `drgnx-pixels-ui-scale' reads, so every
;; `drgnx-px' of the look follows, and Nidhogg's text zoom (`nidhogg-set-frame-text-zoom'), so the fonts are opened at
;; 96 dpi × the display scale × the UI scale; child frames share their root's.  Then what is sized from the scale is
;; given again: the density's code line, the cards' gap, the bars and the hub views' env.  Frames made later take it
;; before their first draw.  Zoom In and Zoom Out step 10 %, Reset Zoom gives 100 %; each is saved in settings.el and
;; applies at once, and +, - or 0 repeat it.

;;; Code:
(require 'seq)
(require 'drgnx-setting)
(require 'drgnx-state)
(require 'drgnx-pixels)

(defvar drgnx-look-density-changed-hook)
(declare-function nidhogg-set-frame-text-zoom "nhwl-scale" (frame zoom))
(declare-function drgnx-settings-defaults-save "drgnx-settings-defaults" (var value))
(declare-function drgnx-module-running-p "drgnx-modules" (module))
(declare-function drgnx-look-density-apply "drgnx-look-density")
(declare-function drgnx-view-env-look-changed "drgnx-view-env")

(defun drgnx-look-scale-percent-p (value)
  "Non-nil when VALUE is a UI scale: an integer percent from 100 to 200 in steps of 5."
  (and (integerp value) (<= 100 value 200) (zerop (% value 5))))

(drgnx-defsetting drgnx-look-scale 100
  "The UI scale in percent: every size of the look and every font, on top of the display's own scale.  100 to 200 in
steps of 5; Zoom In and Zoom Out step 10.  A change applies at once."
  :type 'integer :group 'drgnx-look
  :scope 'global :agents 'never :apply #'drgnx-look-scale--settings-apply
  :schema '(pred drgnx-look-scale-percent-p "a percent from 100 to 200 in steps of 5"))

(drgnx-defsetting drgnx-look-scale-monitors nil
  "The UI scale of particular monitors, in percent: an alist from a monitor's name (as `frame-monitor-attributes'
gives it, \"eDP-1\") to a percent, 100 to 200 in steps of 5.  A frame on a monitor named here takes its percent
instead of `drgnx-look-scale', and changes when it moves to another monitor.  A change applies at once."
  :type '(alist :key-type string :value-type integer) :group 'drgnx-look
  :scope 'global :agents 'never :apply #'drgnx-look-scale--settings-apply
  :schema '(alist string (pred drgnx-look-scale-percent-p "a percent from 100 to 200 in steps of 5")))

(defconst drgnx-look-scale-step 10 "The percent Zoom In and Zoom Out add or take.")

(defun drgnx-look-scale-for (monitor)
  "The UI scale in percent on the monitor named MONITOR (nil: none, a terminal's): its override, else the global."
  (or (and monitor (cdr (assoc monitor drgnx-look-scale-monitors))) drgnx-look-scale))

(defun drgnx-look-scale--monitor (frame)
  "The name of the monitor FRAME is on, or nil."
  (alist-get 'name (frame-monitor-attributes frame)))

(defun drgnx-look-scale--frame-percent (frame)
  "FRAME's UI scale in percent: its monitor's."
  (drgnx-look-scale-for (drgnx-look-scale--monitor frame)))

(defun drgnx-look-scale--roots ()
  "The graphical root frames."
  (seq-filter (lambda (f) (and (display-graphic-p f) (not (frame-parent f)))) (frame-list)))

(defun drgnx-look-scale-apply-frame (frame &optional percent)
  "Give the root FRAME the UI scale PERCENT (default its own): its pixels and, on Nidhogg, its fonts."
  (when (frame-live-p frame)
    (let ((s (/ (or percent (drgnx-look-scale--frame-percent frame)) 100.0)))
      (set-frame-parameter frame 'drgnx-ui-scale (unless (= s 1.0) s))
      (when (fboundp 'nidhogg-set-frame-text-zoom)
        (nidhogg-set-frame-text-zoom frame s)))))

(defun drgnx-look-scale--follow ()
  "What is sized from the scale, given again: the code line, the cards' gap, the bars and the hub views."
  (when (fboundp 'drgnx-look-density-apply) (drgnx-look-density-apply))
  (run-hooks 'drgnx-look-density-changed-hook)
  (setq drgnx-pixels-generation (1+ drgnx-pixels-generation))
  (when (fboundp 'drgnx-view-env-look-changed) (drgnx-view-env-look-changed))
  (force-mode-line-update t))

(defun drgnx-look-scale-apply ()
  "Every graphical root frame at its UI scale, at once."
  (mapc #'drgnx-look-scale-apply-frame (drgnx-look-scale--roots))
  (drgnx-look-scale--follow))

(defun drgnx-look-scale--settings-apply ()
  "The `:apply' of `drgnx-look-scale': at once, while ui/look runs."
  (when (drgnx-module-running-p 'ui/look)
    (drgnx-look-scale-apply)))

(defun drgnx-look-scale--frame-added (data)
  "The store's `frame-added' (now lane, before the first draw): a new root frame takes the UI scale."
  (let ((frame (plist-get data :frame)))
    (when (and (frame-live-p frame) (display-graphic-p frame) (not (frame-parent frame)))
      (drgnx-look-scale-apply-frame frame))))

(defun drgnx-look-scale--refresh-frame (frame)
  "FRAME's root at its monitor's UI scale, when that changed (it moved, or its monitor went)."
  (when (frame-live-p frame)
    (while (frame-parent frame) (setq frame (frame-parent frame)))
    (when (and (display-graphic-p frame)
               (/= (drgnx-pixels-ui-scale frame) (/ (drgnx-look-scale--frame-percent frame) 100.0)))
      (drgnx-look-scale-apply-frame frame)
      (drgnx-look-scale--follow))))

(defun drgnx-look-scale--monitors-changed (&optional _terminal)
  "A monitor came or went: every frame at its monitor's UI scale."
  (mapc #'drgnx-look-scale--refresh-frame (drgnx-look-scale--roots)))

;;;; The commands

(defun drgnx-look-scale-set (percent)
  "Set the UI scale to PERCENT, kept within 100 to 200: saved in settings.el and applied at once.  Return it."
  (let ((p (max 100 (min 200 percent))))
    (require 'drgnx-settings-defaults)
    (drgnx-settings-defaults-save 'drgnx-look-scale p)
    (mapc #'drgnx-look-scale-apply-frame (drgnx-look-scale--roots))
    (drgnx-look-scale--follow)
    p))

(defvar-keymap drgnx-look-scale-repeat-map
  :doc "After a zoom command: + or = bigger, - smaller, 0 back to 100 %."
  "+" #'drgnx-look-scale-zoom-in "=" #'drgnx-look-scale-zoom-in
  "-" #'drgnx-look-scale-zoom-out "0" #'drgnx-look-scale-zoom-reset)

(defun drgnx-look-scale--step (delta)
  "Add DELTA percent to the UI scale (nil: back to 100); then +, - or 0 repeat."
  (let ((p (drgnx-look-scale-set (if delta (+ drgnx-look-scale delta) 100))))
    (set-transient-map drgnx-look-scale-repeat-map)
    (message "UI scale %d %% (+, - or 0 to go on)" p)))

(defun drgnx-look-scale-zoom-in () "Everything 10 % bigger; then +, - or 0." (interactive) (drgnx-look-scale--step drgnx-look-scale-step))
(defun drgnx-look-scale-zoom-out () "Everything 10 % smaller; then +, - or 0." (interactive) (drgnx-look-scale--step (- drgnx-look-scale-step)))
(defun drgnx-look-scale-zoom-reset () "The UI scale back to 100 %." (interactive) (drgnx-look-scale--step nil))

(defun drgnx-look-scale-choose (percent)
  "Set the UI scale to PERCENT (100 to 200, in steps of 5)."
  (interactive
   (list (let ((n (read-number "UI scale (100–200 %, steps of 5): " drgnx-look-scale)))
           (unless (drgnx-look-scale-percent-p n) (user-error "The UI scale is 100 to 200 in steps of 5, not %s" n))
           n)))
  (message "UI scale %d %%" (drgnx-look-scale-set percent)))

(defun drgnx-look-scale-monitor-set (percent)
  "Set the UI scale of the selected frame's monitor to PERCENT (nil: clear it, the global applies): saved in
settings.el and applied at once."
  (let* ((name (or (drgnx-look-scale--monitor (selected-frame)) (user-error "This frame is on no monitor")))
         (rest (seq-remove (lambda (e) (equal (car e) name)) drgnx-look-scale-monitors))
         (new (if percent (cons (cons name (max 100 (min 200 percent))) rest) rest)))
    (require 'drgnx-settings-defaults)
    (drgnx-settings-defaults-save 'drgnx-look-scale-monitors new)
    (drgnx-look-scale-apply)
    name))

(defun drgnx-look-scale-monitor-choose (percent)
  "Set the UI scale of this frame's monitor to PERCENT, or back to the global one (\"default\")."
  (interactive
   (list (let ((s (read-string "UI scale for this monitor (100–200 %, or default): ")))
           (cond ((string= (string-trim s) "default") nil)
                 ((drgnx-look-scale-percent-p (string-to-number s)) (string-to-number s))
                 (t (user-error "The UI scale is 100 to 200 in steps of 5, or default, not %s" s))))))
  (let ((name (drgnx-look-scale-monitor-set percent)))
    (message "UI scale on %s: %s" name (if percent (format "%d %%" percent) "the default"))))

;;;; On and off

(defun drgnx-look-scale-on ()
  "Every frame at its UI scale, frames made later too, and again when a frame changes monitor or a monitor goes."
  (drgnx-state-subscribe 'frame-added #'drgnx-look-scale--frame-added :lane 'now)
  (add-hook 'move-frame-functions #'drgnx-look-scale--refresh-frame)
  (add-hook 'nidhogg-frame-scale-change-functions #'drgnx-look-scale--refresh-frame)
  (add-hook 'display-monitors-changed-functions #'drgnx-look-scale--monitors-changed)
  (unless (and (= drgnx-look-scale 100) (null drgnx-look-scale-monitors)) (drgnx-look-scale-apply)))

(defun drgnx-look-scale-off ()
  "Undo `drgnx-look-scale-on': every frame at its own sizes and text zoom 1.  The settings stay."
  (drgnx-state-unsubscribe 'frame-added #'drgnx-look-scale--frame-added)
  (remove-hook 'move-frame-functions #'drgnx-look-scale--refresh-frame)
  (remove-hook 'nidhogg-frame-scale-change-functions #'drgnx-look-scale--refresh-frame)
  (remove-hook 'display-monitors-changed-functions #'drgnx-look-scale--monitors-changed)
  (dolist (f (drgnx-look-scale--roots))
    (drgnx-look-scale-apply-frame f 100))
  (drgnx-look-scale--follow))

(provide 'drgnx-look-scale)
;;; drgnx-look-scale.el ends here
