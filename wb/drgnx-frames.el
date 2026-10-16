;;; drgnx-frames.el --- Several windows: roles, moving editors, each window's buffers -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Every frame (OS window) is its own workbench.  The first graphical frame is the **main** one;
;; frames made later are **auxiliary**: editor-only (no sidebar until you toggle one there).
;; Commands move or open the shown file — or a whole editor group — in a new window.  Each window
;; has its own buffers: the tabs of its groups (the main window also has the open files that are a
;; tab nowhere); the Buffers panel lists the window you work in, or all of them.  drgnx never
;; positions or sizes a window: the window manager places it.  See docs/workbench.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-groups)

(defun drgnx-frames--workbench-p (f)
  "F is a frame the workbench works in (not a child frame, not a daemon's terminal frame)."
  (and (frame-live-p f) (not (frame-parent f)) (or (display-graphic-p f) (not (daemonp)))))

(defun drgnx-frames--main ()
  (seq-find (lambda (f) (and (frame-live-p f) (eq (frame-parameter f 'drgnx-frame-role) 'main))) (frame-list)))

(defun drgnx-frames-mark-main (&optional frame)
  "Make FRAME (default: the first graphical frame) the main window unless one exists."
  (unless (drgnx-frames--main)
    (when-let* ((f (or frame (seq-find #'display-graphic-p (frame-list))
                       (seq-find #'drgnx-frames--workbench-p (frame-list)))))
      (set-frame-parameter f 'drgnx-frame-role 'main))))

(defun drgnx-frame-role (&optional frame)
  "FRAME's role: `main' or `aux'."
  (let ((f (or frame (selected-frame))))
    (drgnx-frames-mark-main)
    (if (eq (frame-parameter f 'drgnx-frame-role) 'main) 'main 'aux)))

(defun drgnx-frames--deleted (frame)
  "The main window closes: the next workbench window becomes main."
  (when (eq (frame-parameter frame 'drgnx-frame-role) 'main)
    (when-let* ((next (seq-find (lambda (f) (and (not (eq f frame)) (drgnx-frames--workbench-p f))) (frame-list))))
      (set-frame-parameter next 'drgnx-frame-role 'main))))

(defun drgnx-frames-count ()
  "How many workbench windows are open."
  (seq-count #'drgnx-frames--workbench-p (frame-list)))

;;;; Each window's buffers

(defun drgnx-frames--tabs (frame)
  (seq-uniq (seq-mapcat #'drgnx-chrome-tabs (drgnx-groups-list frame))))

(defun drgnx-frame-buffers (&optional frame)
  "FRAME's buffers: the tabs of its groups; the main window also has the open files that are a
tab in no window."
  (let* ((f (or frame (selected-frame))) (mine (drgnx-frames--tabs f)))
    (if (not (eq (drgnx-frame-role f) 'main))
        mine
      (let ((elsewhere (seq-mapcat #'drgnx-frames--tabs
                                   (seq-filter (lambda (g) (and (not (eq g f)) (drgnx-frames--workbench-p g))) (frame-list)))))
        (append mine (seq-filter (lambda (b) (and (drgnx-signal-user-buffer-p b) (not (memq b mine))
                                                  (not (memq b elsewhere))))
                                 (buffer-list)))))))

;;;; New windows

(defun drgnx-frames--new (buffer tabs)
  "A new auxiliary window showing BUFFER with TABS; selected."
  (let ((f (make-frame '((drgnx-frame-role . aux)))))
    (let ((w (frame-first-window f)))
      (set-window-buffer w buffer)
      (set-window-prev-buffers w nil)
      (set-window-parameter w 'drgnx-tabs tabs))
    (select-frame-set-input-focus f)
    (drgnx-chrome-apply f t)
    f))

(defun drgnx-frames-move-editor ()
  "Move the shown file to a new window (it leaves this group's tabs)."
  (interactive)
  (let* ((g (drgnx-groups--current)) (b (window-buffer g)))
    (drgnx-chrome--close g b)
    (drgnx-frames--new b (list b))))

(defun drgnx-frames-open-editor ()
  "Open the shown file in a new window too (both show it)."
  (interactive)
  (let ((b (window-buffer (drgnx-groups--current))))
    (drgnx-frames--new b (list b))))

(defun drgnx-frames-move-group ()
  "Move this editor group — its tabs and shown file — to a new window."
  (interactive)
  (let* ((g (drgnx-groups--current)) (b (window-buffer g)) (tabs (drgnx-chrome-tabs g)))
    (if (> (length (drgnx-groups-list)) 1)
        (delete-window g)
      (set-window-parameter g 'drgnx-tabs nil)
      (set-window-buffer g (get-scratch-buffer-create)))
    (drgnx-frames--new b (or tabs (list b)))))

(define-minor-mode drgnx-frames-mode
  "Several windows: the main one, auxiliary ones (editor-only), each with its buffers."
  :global t :group 'drgnx
  (if drgnx-frames-mode
      (progn (add-hook 'delete-frame-functions #'drgnx-frames--deleted)
             (add-hook 'drgnx-first-gui-frame-hook #'drgnx-frames-mark-main))
    (remove-hook 'delete-frame-functions #'drgnx-frames--deleted)
    (remove-hook 'drgnx-first-gui-frame-hook #'drgnx-frames-mark-main)))

(provide 'drgnx-frames)
;;; drgnx-frames.el ends here
