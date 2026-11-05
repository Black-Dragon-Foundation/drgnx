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

(require 'drgnx-setting)

(drgnx-defsetting drgnx-popup-style 'auto
  "How the popup lane shows: `window' (the panel's window, or one under the editors), `float' (one child frame
over the editor, bottom-centre) or `auto': `float' under Glitnir, `window' without it."
  :type '(choice (const auto) (const window) (const float)) :group 'drgnx
  :scope 'global :workspace 'never :agents 'never
  :schema '(or (const auto) (const window) (const float)))

(declare-function glitnir-active-p "glitnir")

(defun drgnx-popup--float-p ()
  "Non-nil when the lane floats in a child frame now."
  (pcase drgnx-popup-style
    ('float t)
    ('auto (and (featurep 'glitnir) (fboundp 'glitnir-active-p) (glitnir-active-p) t))))

(defun drgnx-popup--root (&optional frame)
  "FRAME's (default: the selected one's) root frame."
  (let ((f (or frame (selected-frame))))
    (while (frame-parent f) (setq f (frame-parent f)))
    f))

(defun drgnx-popup--float-frame (root)
  "ROOT's popup child frame while it is live, else nil."
  (let ((f (frame-parameter root 'drgnx-popup-frame)))
    (and (frame-live-p f) f)))

(defun drgnx-popup--window (&optional frame)
  "The window the popup lane uses now on FRAME, or nil."
  (or (seq-find (lambda (w) (window-parameter w 'drgnx-popup)) (window-list frame 'nomini))
      (when-let* ((child (drgnx-popup--float-frame (drgnx-popup--root frame)))
                  (w (frame-root-window child))
                  ((window-parameter w 'drgnx-popup)))
        w)))

(defun drgnx-popup-active-p (&optional frame)
  "Non-nil while a popup shows on FRAME."
  (and (drgnx-popup--window frame) t))

(defun drgnx-popup--height (fraction)
  "A `window-height' function: fit the buffer, at most FRACTION of the frame."
  (lambda (w) (fit-window-to-buffer w (max 1 (floor (* (or fraction 0.33) (frame-height (window-frame w))))) 1)))

(defun drgnx-popup--close-click (event)
  "A click on the lane's ✕: end the popup."
  (interactive "e")
  (when-let* ((w (posn-window (event-start event))) ((window-live-p w)) ((window-parameter w 'drgnx-popup)))
    (drgnx-popup--end w)))

(defun drgnx-popup--header (buffer)
  "The lane's one line for BUFFER: its name without the stars and spaces round it, and the ✕ that ends the popup.
Built when the popup shows, set as a window parameter."
  (drgnx-wb-header-with-close (concat " " (string-trim (buffer-name buffer) "[ *]+" "[ *]+"))
                              #'drgnx-popup--close-click "Close (Esc, q)"))

(defun drgnx-popup--float-fit (window)
  "Fit the floating lane's frame to its buffer (at most 0.9 of the root's width and 0.33 of its height) and put it
bottom-centre, above the echo area."
  ;; The size is computed from the text and set, then the position from that size: a frame's size is answered by the
  ;; compositor later, so `frame-outer-width' right after a resize still says the old one.
  (let* ((child (window-frame window)) (root (frame-parent child))
         (max-w (floor (* 0.9 (frame-pixel-width root)))) (max-h (floor (* 0.33 (frame-pixel-height root))))
         (frame-resize-pixelwise t)
         ;; measured in a window as large as the lane may be, or a long line would wrap at a small one's width
         (_ (set-frame-size child max-w max-h t))
         (extra-w (- (window-pixel-width window) (window-body-width window t)))
         (extra-h (- (window-pixel-height window) (window-body-height window t)))
         (text (window-text-pixel-size window nil nil (- max-w extra-w) (- max-h extra-h)))
         (w (min max-w (+ (car text) extra-w))) (h (min max-h (+ (cdr text) extra-h)))
         (border-w (- (frame-outer-width child) (frame-text-width child)))
         (border-h (- (frame-outer-height child) (frame-text-height child))))
    (set-frame-size child w h t)
    (set-frame-position child
                        (max 0 (/ (- (frame-pixel-width root) w border-w) 2))
                        (max 0 (- (frame-pixel-height root) (window-pixel-height (minibuffer-window root))
                                  h border-h)))))

(defun drgnx-popup--float-window (buffer)
  "The root window of the selected root frame's popup child frame, showing BUFFER; the frame is made once and
reused (`display-buffer-in-child-frame' makes it the first time)."
  (let* ((root (drgnx-popup--root)) (child (drgnx-popup--float-frame root)))
    (if child
        (let ((w (frame-root-window child)))
          (set-window-dedicated-p w nil)
          (set-window-buffer w buffer))
      (let ((drgnx-rules--placing t))
        (setq child (window-frame
                     (display-buffer-in-child-frame
                      buffer `((child-frame-parameters . ((undecorated . t) (no-accept-focus . t) (no-other-frame . t)
                                                          (minibuffer . nil) (drgnx-popup . t) (skip-taskbar . t)
                                                          (no-focus-on-map . t) (internal-border-width . 0)))
                               (inhibit-switch-frame . t)))))
        (set-frame-parameter root 'drgnx-popup-frame child)))
    (frame-root-window child)))

(defun drgnx-popup--show-float (buffer)
  "The lane in the popup child frame: shown with BUFFER, fitted and placed; return its window."
  (let ((lane (drgnx-popup--float-window buffer)))
    (set-window-parameter lane 'header-line-format (drgnx-popup--header buffer))
    (set-window-parameter lane 'drgnx-popup (list :float t :popup buffer))
    ;; `delete-window' ends the lane through its `delete-window' parameter (set by `drgnx-popup--show').  `quit-window'
    ;; and `bury-buffer' would delete a dedicated window — here its frame's only one, so the frame — so the lane is not
    ;; dedicated, and they take the idle buffer from `quit-restore' / the previous buffers instead; the buffer change
    ;; then ends the popup (`drgnx-popup--frame-changed' on `window-buffer-change-functions', before anything is drawn).
    (let ((idle (get-buffer-create " *drgnx-popup-idle*")))
      (set-window-dedicated-p lane nil)
      (set-window-prev-buffers lane (list (list idle (copy-marker 1) (copy-marker 1))))
      (set-window-parameter lane 'quit-restore (list 'window (list idle 1 1 nil) (selected-window) buffer)))
    (drgnx-popup--float-fit lane)
    (make-frame-visible (window-frame lane))
    (drgnx-popup--float-fit lane)       ; a frame that has just been mapped can take its first size from the toolkit
    lane))

(defun drgnx-popup--show (buffer alist props)
  "The `popup' place: borrow the panel's window — unless you are typing in it — else a temporary
one; mark it as the lane.  Under `drgnx-popup-style' `float', one child frame instead."
  (let ((lane (drgnx-popup--window)) (panel (drgnx-wb-area-window 'panel)))
    (cond
     ((and (drgnx-popup--float-p) (or (not lane) (plist-get (window-parameter lane 'drgnx-popup) :float)))
      (setq lane (drgnx-popup--show-float buffer)))
     (lane (drgnx-wb-set-area-buffer lane buffer)                   ; a popup replaces a popup
           (set-window-parameter lane 'header-line-format (drgnx-popup--header buffer))
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
      (set-window-parameter lane 'header-line-format (drgnx-popup--header buffer))  ; a lane always has one header line (I3)
      (drgnx-wb-set-area-buffer lane buffer))
     (t
      (setq lane (let ((drgnx-rules--placing t))
                   (display-buffer-in-side-window
                    buffer `((side . bottom) (slot . 1) (dedicated . drgnx)
                             (window-height . ,(drgnx-popup--height (plist-get props :height)))
                             (window-parameters . ((drgnx-role . popup) (no-delete-other-windows . t)
                                                   (no-other-window . t)
                                                   (header-line-format . ,(drgnx-popup--header buffer))))))))
      (set-window-parameter lane 'drgnx-popup (list :borrowed nil :popup buffer))))
    ;; However the package ends it, it comes here: `delete-window' calls our function, and
    ;; `quit-window' / `bury-buffer' delete the window (no earlier buffers to go back to).
    (set-window-parameter lane 'delete-window #'drgnx-popup--end)
    (unless (plist-get (window-parameter lane 'drgnx-popup) :float)   ; the float lane's are set by `drgnx-popup--show-float'
      (set-window-prev-buffers lane nil)
      (set-window-parameter lane 'quit-restore (list 'window 'window (selected-window) buffer)))
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
    (cond
     ((plist-get saved :float)             ; hidden, never deleted while the root lives: the next popup reuses it
      (set-window-dedicated-p lane nil)
      (make-frame-invisible (window-frame lane) t))
     ((not (plist-get saved :borrowed))
      (delete-window lane))
     (t
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
          (let ((window-resize-pixelwise t)) (ignore-errors (window-resize lane delta nil nil t)))))))
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

(defun drgnx-popup--frame-changed (frame)
  "Default `window-buffer-change-functions': a window of FRAME changed its buffer; end a floating lane that no
longer shows its popup (`quit-window' and `bury-buffer' put the idle buffer there)."
  (when-let* ((child (if (frame-parameter frame 'drgnx-popup) frame (frame-parameter frame 'drgnx-popup-frame)))
              ((frame-live-p child)))
    (drgnx-popup--check-window (frame-root-window child))))

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
  "Follow `drgnx-rules-mode': the fit guard and the floating lane's buffer-change check are on while the rules are."
  (if drgnx-rules-mode
      (progn (advice-add 'fit-window-to-buffer :around #'drgnx-popup--fit)
             (add-hook 'window-buffer-change-functions #'drgnx-popup--frame-changed))
    (advice-remove 'fit-window-to-buffer #'drgnx-popup--fit)
    (remove-hook 'window-buffer-change-functions #'drgnx-popup--frame-changed)))

(add-hook 'drgnx-rules-mode-hook #'drgnx-popup--mode)
(when drgnx-rules-mode (drgnx-popup--mode))

(drgnx-wb-define-place 'popup #'drgnx-popup--show)
(dolist (re '("\\` \\*transient\\*\\'" "\\` \\*which-key\\*\\'" "\\`\\*Completions\\*\\'" "\\`\\*Calendar\\*\\'"))
  (drgnx-wb-place re 'popup))

(provide 'drgnx-popup)
;;; drgnx-popup.el ends here
