;;; drgnx-actions.el --- Row actions across panels; panel tabs; the mode's menu -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; What you do with a row: in the Buffers panel save it, copy its path, reveal it in the Explorer;
;; in the Explorer reveal the file in the Buffers panel, open the folder in dired, open the file in
;; the other editor group.  Next Panel Tab cycles the panel's tabs; Menu for This Mode pops up the
;; major mode's menu at point (no mouse needed).  See docs/guide/workbench.md.

;;; Code:
(require 'drgnx-explorer)
(require 'drgnx-buffers)
(require 'drgnx-groups)

;;;; Buffers rows

(defun drgnx-actions--row-buffer ()
  (or (and (derived-mode-p 'drgnx-buffers-mode) (drgnx-buffers-buffer-at (point)))
      (user-error "No buffer on this row")))

(defun drgnx-buffers-save-row () "Save the buffer on this row." (interactive)
       (with-current-buffer (drgnx-actions--row-buffer) (save-buffer)))

(defun drgnx-buffers-copy-path-row () "Copy the path of the buffer on this row." (interactive)
       (let ((f (or (buffer-file-name (drgnx-actions--row-buffer)) (user-error "This buffer has no file"))))
         (kill-new f) (message "Copied %s" f)))

(defun drgnx-buffers-reveal-row () "Show the file of this row in the Explorer." (interactive)
       (let ((f (or (buffer-file-name (drgnx-actions--row-buffer)) (user-error "This buffer has no file"))))
         (drgnx-explorer-focus)
         (drgnx-explorer-reveal f (drgnx-wb-section-window 'explorer))))

(defun drgnx-buffers-full-view () "All buffers in a table (ibuffer), in the editor." (interactive) (ibuffer))

;;;; Explorer rows

(defun drgnx-actions--row-path ()
  (or (and (derived-mode-p 'drgnx-explorer-mode) (drgnx-explorer-node-at (point))) (user-error "No file on this row")))

(defun drgnx-explorer-reveal-in-buffers () "Show the open file of this row in the Buffers panel." (interactive)
       (let ((b (or (get-file-buffer (drgnx-actions--row-path)) (user-error "This file is not open"))))
         (drgnx-buffers-focus)
         (when-let* ((pos (drgnx-buffers--row-pos b))) (goto-char pos))))

(defun drgnx-explorer-open-in-dired () "Open the folder of this row in dired, in the editor." (interactive)
       (let* ((p (drgnx-actions--row-path)) (dir (if (file-directory-p p) p (file-name-directory p))))
         (drgnx-wb-show-in-editor (dired-noselect dir) t)))

(defun drgnx-explorer-other-window () "Open the file of this row in the other editor group." (interactive)
       (let ((p (drgnx-actions--row-path)))
         (when (file-directory-p p) (user-error "A folder: open a file"))
         (drgnx-groups--other-group (find-file-noselect p) nil nil)))

;;;; Panel tabs, the mode's menu

(defun drgnx-wb-panel-next-tab () "Show the panel's next tab (wraps)." (interactive)
       (let* ((tabs (mapcar #'car (plist-get (alist-get 'panel drgnx-wb--areas) :tabs)))
              (i (or (seq-position tabs (drgnx-wb-area-tab 'panel)) -1)))
         (drgnx-wb-area-show 'panel (nth (mod (1+ i) (length tabs)) tabs))))

(defun drgnx-actions--mode-menu ()
  "The major mode's menu (what a right-click on the mode line shows)."
  (mouse-menu-major-mode-map))

(defun drgnx-help-mode-menu () "The major mode's menu, at point." (interactive)
       (popup-menu (drgnx-actions--mode-menu) (posn-at-point)))

(provide 'drgnx-actions)
;;; drgnx-actions.el ends here
