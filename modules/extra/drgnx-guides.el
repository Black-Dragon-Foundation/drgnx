;;; drgnx-guides.el --- Module extra/guides: indent guides (indent-bars) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Thin vertical guides at each indentation level of code (and YAML), on graphical frames — drawn by indent-bars
;; with stipples, not characters, so they cost little and never get in the way of the cursor.  Their colour comes
;; from the theme (the `shadow' face's colour, blended into the background).  See docs/guide/editing.md.

;;; Code:
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-large-file)
(declare-function indent-bars-mode "indent-bars")
(defvar indent-bars-mode)
(defvar indent-bars-color)
(defvar indent-bars-treesit-support)
(defvar indent-bars--highlight-timer)

(defvar drgnx-guides-modes '(prog-mode-hook yaml-mode-hook yaml-ts-mode-hook) "Where the guides go.")

(defun drgnx-guides--cleanup-timer-p (timer buffer)
  "Whether TIMER is indent-bars' one-shot remap cleanup for BUFFER (any buffer when BUFFER is t).
indent-bars schedules it with `apply-partially' and keeps no handle on it, so its own teardown cannot cancel it:
the closure's constants name the function and hold the buffer."
  (let ((f (timer--function timer)))
    (and (byte-code-function-p f) (vectorp (aref f 2))
         (let ((c (append (aref f 2) nil)))
           (and (memq 'indent-bars--cleanup-stipple-remaps c)
                (or (eq buffer t) (member (list buffer) c)))))))

(defun drgnx-guides--cancel-timers (&optional buffer)
  "Cancel indent-bars' pending timers for BUFFER (default: the current one; t: every buffer's).
A buffer killed with the guides on would otherwise leave them holding it."
  (let ((buffer (or buffer (current-buffer))))
    (dolist (tm (append timer-idle-list timer-list))
      (when (drgnx-guides--cleanup-timer-p tm buffer) (cancel-timer tm)))
    (dolist (b (if (eq buffer t) (buffer-list) (and (buffer-live-p buffer) (list buffer))))
      (with-current-buffer b
        (when (timerp (bound-and-true-p indent-bars--highlight-timer))
          (cancel-timer indent-bars--highlight-timer)
          (setq indent-bars--highlight-timer nil))))))

(defun drgnx-guides--on ()
  "Guides on in this buffer; its `kill-buffer-hook' cancels what indent-bars leaves pending."
  (indent-bars-mode 1)
  (add-hook 'kill-buffer-hook #'drgnx-guides--cancel-timers nil t))

(defun drgnx-guides--maybe ()
  "Guides in this buffer, on a graphical frame, unless it holds a large file."
  (when (and (display-graphic-p) (not (drgnx-large-file-p))) (drgnx-guides--on)))

(defun drgnx-guides-toggle ()
  "Indent guides off or on in this buffer."
  (interactive)
  (if (bound-and-true-p indent-bars-mode) (indent-bars-mode -1) (drgnx-guides--on)))

(defun drgnx-guides--teardown ()
  "The guides go off in the buffers that have them, and indent-bars' pending timers with them."
  (dolist (b (buffer-list))
    (with-current-buffer b
      (when (bound-and-true-p indent-bars-mode) (indent-bars-mode -1))
      (remove-hook 'kill-buffer-hook #'drgnx-guides--cancel-timers t)))
  (drgnx-guides--cancel-timers t))

(drgnx-module-define 'extra/guides
                     :doc "Indent guides in code and YAML on graphical frames (indent-bars; the theme's colours)."
                     ;; off until chosen: the approved look's code has no guides (docs/guide/look.md)
                     :default 'off
                     :stage 'first-frame :packages '(indent-bars)
                     :teardown #'drgnx-guides--teardown
                     :setup (lambda ()
                              (require 'indent-bars)
                              (drgnx-module-set 'indent-bars-color '(shadow :blend 0.35))   ; shadow's colour, not highlight's background
                              (drgnx-module-set 'indent-bars-treesit-support (and (fboundp 'treesit-available-p) (treesit-available-p)))
                              (dolist (h drgnx-guides-modes) (add-hook h #'drgnx-guides--maybe))
                              (drgnx-command-define 'toggle-indent-guides :category "View" :title "Toggle Indent Guides"
                                                    :command #'drgnx-guides-toggle :doc "Indent guides off or on in this buffer")))

(provide 'drgnx-guides)
;;; drgnx-guides.el ends here
