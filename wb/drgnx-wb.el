;;; drgnx-wb.el --- The workbench: window roles and the left dock -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Each window has a role (window parameter `drgnx-role'): editor windows hold files, the left
;; dock holds sections (the Buffers panel above the Explorer).  The dock is made of side windows
;; with a fixed pixel width that survives hiding and showing; its titles live in the
;; `header-line-format' window parameter, so no mode can erase them.  Showing the dock never
;; focuses it, and files chosen in the dock go to the most recently used editor window without
;; splitting.  See docs/guide/workbench.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-signal)

(defcustom drgnx-wb-dock-columns 32
  "Width of the left dock, in columns, the first time it shows (later: the width it had)."
  :type 'integer :group 'drgnx)

(defvar drgnx-wb-dock-map (make-sparse-keymap)
  "Parent keymap of every dock section's mode (keys come from the key profiles).")

(defvar drgnx-wb--owned nil
  "Windows the running code owns (it shows its own buffer there): moving them from a timer or a
follower is not a jank-guard violation (invariant I9).")

(defmacro drgnx-wb-with-owned-windows (windows &rest body)
  "Run BODY with WINDOWS declared as the caller's own (see `drgnx-wb--owned')."
  (declare (indent 1))
  `(let ((drgnx-wb--owned (append ,windows drgnx-wb--owned))) ,@body))

(defvar drgnx-wb--sections nil "Alist NAME → plist (:slot :title :buffer), the left dock's sections.")

(defun drgnx-wb-display-name (name)
  "NAME as it can be shown on one row: control characters (a newline in a file name) as ^X."
  (if (string-match-p "[\0-\37\177]" name)
      (replace-regexp-in-string "[\0-\37\177]"
                                (lambda (c) (if (equal c "\177") "^?" (string ?^ (+ 64 (aref c 0)))))
                                name t t)
    name))

(defun drgnx-wb-define-section (name &rest spec)
  "Define dock section NAME: SPEC is (:slot N :title STRING-OR-FUNCTION-RETURNING-ONE
:buffer FUNCTION-RETURNING-A-BUFFER :height FRACTION-OF-THE-DOCK :on-show FUNCTION-OF-THE-WINDOW).
A function title is asked each time the dock shows (a panel's filter stays in its title)."
  (setf (alist-get name drgnx-wb--sections) spec)
  name)

(defun drgnx-wb-section-window (name &optional frame)
  "The window showing dock section NAME on FRAME, or nil."
  (seq-find (lambda (w) (eq (window-parameter w 'drgnx-section) name)) (window-list frame 'nomini)))

(defun drgnx-wb--dock-windows (&optional frame)
  (seq-filter (lambda (w) (eq (window-parameter w 'drgnx-role) 'dock)) (window-list frame 'nomini)))

(defun drgnx-wb-sidebar-showing-p (&optional frame)
  (and (drgnx-wb--dock-windows frame) t))

(defun drgnx-wb-show-sidebar ()
  "Show the left dock (all sections) without selecting it; keep the width it had."
  (unless (drgnx-wb-sidebar-showing-p)
    (let ((selected (selected-window)))
      (pcase-dolist (`(,name . ,spec) (sort (copy-sequence drgnx-wb--sections)
                                            (lambda (a b) (< (plist-get (cdr a) :slot) (plist-get (cdr b) :slot)))))
        (display-buffer-in-side-window
         (funcall (plist-get spec :buffer))
         `((side . left) (slot . ,(plist-get spec :slot)) (window-width . ,drgnx-wb-dock-columns)
           ,@(when (plist-get spec :height) `((window-height . ,(plist-get spec :height))))
           (dedicated . t)
           (window-parameters . ((drgnx-role . dock) (drgnx-section . ,name) (no-delete-other-windows . t)
                                 (no-other-window . t)
                                 (header-line-format . ,(let ((title (plist-get spec :title)))
                                                          (if (functionp title) (funcall title) title))))))))
      (when-let* ((px (frame-parameter nil 'drgnx-wb-dock-px)) (w (car (drgnx-wb--dock-windows))))
        (let ((window-resize-pixelwise t))              ; or the width is rounded to whole columns
          (ignore-errors (window-resize w (- px (window-pixel-width w)) t nil t))))
      (dolist (w (drgnx-wb--dock-windows))
        (window-preserve-size w t t)
        (set-window-scroll-bars w nil nil nil nil t))       ; a clean sidebar, like VS Code's
      (unless (eq (selected-window) selected) (select-window selected 'norecord))
      (pcase-dolist (`(,name . ,spec) drgnx-wb--sections)
        (when-let* ((fn (plist-get spec :on-show)) (w (drgnx-wb-section-window name)))
          (funcall fn w))))))

(defun drgnx-wb-hide-sidebar ()
  "Hide the left dock, remembering its pixel width for the next show."
  (when-let* ((windows (drgnx-wb--dock-windows)))
    (set-frame-parameter nil 'drgnx-wb-dock-px (window-pixel-width (car windows)))
    (when (memq (selected-window) windows) (drgnx-wb-focus-editor))
    (dolist (w windows) (when (window-live-p w) (delete-window w)))))

(defun drgnx-wb-toggle-sidebar ()
  "Show or hide the left dock (Buffers and Explorer)."
  (interactive)
  (if (drgnx-wb-sidebar-showing-p) (drgnx-wb-hide-sidebar) (drgnx-wb-show-sidebar)))

(defun drgnx-wb-editor-window () (drgnx-signal-editor-window))

(defun drgnx-wb-show-in-editor (buffer &optional select)
  "Show BUFFER in the most recently used editor window, never splitting; SELECT it if asked."
  (let ((w (drgnx-wb-editor-window)))
    (set-window-buffer w buffer)
    (setq drgnx-signal--editor-window w)
    (when select (select-window w))
    w))

(defun drgnx-wb-focus-editor ()
  "Move focus to the most recently used editor window."
  (interactive)
  (select-window (drgnx-wb-editor-window)))

(defun drgnx-wb-focus-section (name)
  "Show the dock if needed and focus its section NAME."
  (drgnx-wb-show-sidebar)
  (select-window (drgnx-wb-section-window name)))

(provide 'drgnx-wb)
;;; drgnx-wb.el ends here
