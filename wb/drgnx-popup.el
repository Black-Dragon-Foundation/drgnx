;;; drgnx-popup.el --- The popup lane: transient, which-key, completions -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Short-lived buffers (a transient menu, which-key's hints, *Completions*, the calendar) show in
;; one lane at the bottom and leave no trace.  When the panel is showing, the popup *borrows* the
;; panel's window — nothing around it moves — and when the popup ends the panel's buffer, scroll,
;; point, tab row and pixel height are put back exactly.  When the panel is hidden, the popup gets
;; a temporary window under the editors, deleted when it ends, giving every pixel back.  A popup
;; ends however its package ends it: `delete-window', `quit-window', `bury-buffer' or killing its
;; buffer.  See docs/guide/workbench.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-area)

(defun drgnx-popup--window (&optional frame)
  "The window the popup lane uses now on FRAME, or nil."
  (seq-find (lambda (w) (window-parameter w 'drgnx-popup)) (window-list frame 'nomini)))

(defun drgnx-popup-active-p (&optional frame)
  "Non-nil while a popup shows on FRAME."
  (and (drgnx-popup--window frame) t))

(defun drgnx-popup--height (fraction)
  "A `window-height' function: fit the buffer, at most FRACTION of the frame."
  (lambda (w) (fit-window-to-buffer w (max 1 (floor (* (or fraction 0.33) (frame-height (window-frame w))))) 1)))

(defun drgnx-popup--show (buffer alist props)
  "The `popup' place: borrow the panel's window — unless you are typing in it — else a temporary
one; mark it as the lane."
  (let ((lane (drgnx-popup--window)) (panel (drgnx-wb-area-window 'panel)))
    (cond
     (lane (drgnx-wb-set-area-buffer lane buffer)                   ; a popup replaces a popup
           (set-window-parameter lane 'drgnx-popup
                                 (plist-put (window-parameter lane 'drgnx-popup) :popup buffer)))
     ((and panel (not (eq panel (selected-window))))
      (setq lane panel)
      (set-window-parameter lane 'drgnx-popup
                            (list :borrowed t :popup buffer :buffer (window-buffer lane) :start (window-start lane)
                                  :point (window-point lane) :height (window-pixel-height lane)
                                  :header (window-parameter lane 'header-line-format)
                                  :delete (window-parameter lane 'delete-window)
                                  :prev (window-prev-buffers lane)))
      ;; A restored window configuration (leaving the minibuffer) puts the panel's buffer back
      ;; without ending the popup: its buffer tells us.
      (with-current-buffer (window-buffer lane)
        (add-hook 'window-buffer-change-functions #'drgnx-popup--check-window nil t))
      (set-window-parameter lane 'header-line-format 'none)  ; the lane has no chrome (I3)
      (drgnx-wb-set-area-buffer lane buffer))
     (t
      (setq lane (let ((drgnx-rules--placing t))
                   (display-buffer-in-side-window
                    buffer `((side . bottom) (slot . 1) (dedicated . drgnx)
                             (window-height . ,(drgnx-popup--height (plist-get props :height)))
                             (window-parameters . ((drgnx-role . popup) (no-delete-other-windows . t)
                                                   (no-other-window . t)))))))
      (set-window-parameter lane 'drgnx-popup (list :borrowed nil :popup buffer))))
    ;; However the package ends it, it comes here: `delete-window' calls our function, and
    ;; `quit-window' / `bury-buffer' delete the window (no earlier buffers to go back to).
    (set-window-prev-buffers lane nil)
    (set-window-parameter lane 'delete-window #'drgnx-popup--end)
    (set-window-parameter lane 'quit-restore (list 'window 'window (selected-window) buffer))
    (with-current-buffer buffer (add-hook 'kill-buffer-hook #'drgnx-popup--killed nil t))
    (drgnx-wb-run-body-function lane alist)
    lane))

(defun drgnx-popup--end (lane)
  "End the popup in LANE: give the panel back exactly, or delete the temporary window."
  (let ((saved (window-parameter lane 'drgnx-popup)))
    (dolist (p '(drgnx-popup delete-window quit-restore)) (set-window-parameter lane p nil))
    (when (buffer-live-p (plist-get saved :buffer))
      (with-current-buffer (plist-get saved :buffer)
        (remove-hook 'window-buffer-change-functions #'drgnx-popup--check-window t)))
    (if (not (plist-get saved :borrowed))
        (delete-window lane)
      (let ((b (plist-get saved :buffer)))
        (drgnx-wb-set-area-buffer
         lane (if (buffer-live-p b) b
                (with-selected-frame (window-frame lane) (drgnx-area--placeholder 'panel (drgnx-wb-area-tab 'panel)))))
        (when (buffer-live-p b)
          (set-window-start lane (plist-get saved :start) t)
          (set-window-point lane (plist-get saved :point))))
      (set-window-prev-buffers lane (plist-get saved :prev))
      (set-window-parameter lane 'header-line-format (plist-get saved :header))
      (set-window-parameter lane 'delete-window (plist-get saved :delete))
      (let ((delta (- (plist-get saved :height) (window-pixel-height lane))))  ; the popup resized it
        (unless (zerop delta)
          (let ((window-resize-pixelwise t)) (ignore-errors (window-resize lane delta nil nil t))))))
    nil))

(defun drgnx-popup--check-window (window)
  "WINDOW's buffer changed: if it is a lane no longer showing its popup, the popup is over (a
restored window configuration put the panel back) — finish ending it."
  (let ((saved (window-parameter window 'drgnx-popup)))
    (when (and saved (not (eq (window-buffer window) (plist-get saved :popup))))
      (drgnx-popup--end window))))

(defun drgnx-popup-check ()
  "End every popup whose lane no longer shows it."
  (dolist (f (frame-list))
    (dolist (w (window-list f 'nomini)) (drgnx-popup--check-window w))))

(defun drgnx-popup--killed ()
  "The current buffer is being killed: end the popup showing it."
  (dolist (f (frame-list))
    (when-let* ((lane (drgnx-popup--window f)) ((eq (window-buffer lane) (current-buffer))))
      (with-selected-frame f (drgnx-popup--end lane)))))

(defun drgnx-popup--fit (orig &optional window &rest args)
  "Around `fit-window-to-buffer': a borrowed panel keeps its size (transient and which-key fit
their window; the editor above must not move).  A temporary lane is fitted as asked."
  (unless (plist-get (window-parameter (window-normalize-window window) 'drgnx-popup) :borrowed)
    (apply orig window args)))

(defun drgnx-popup--mode ()
  "Follow `drgnx-rules-mode': the fit guard is on while the rules are."
  (if drgnx-rules-mode
      (advice-add 'fit-window-to-buffer :around #'drgnx-popup--fit)
    (advice-remove 'fit-window-to-buffer #'drgnx-popup--fit)))

(add-hook 'drgnx-rules-mode-hook #'drgnx-popup--mode)
(when drgnx-rules-mode (drgnx-popup--mode))

(drgnx-wb-define-place 'popup #'drgnx-popup--show)
(dolist (re '("\\` \\*transient\\*\\'" "\\` \\*which-key\\*\\'" "\\`\\*Completions\\*\\'" "\\`\\*Calendar\\*\\'"))
  (drgnx-wb-place re 'popup))

(provide 'drgnx-popup)
;;; drgnx-popup.el ends here
