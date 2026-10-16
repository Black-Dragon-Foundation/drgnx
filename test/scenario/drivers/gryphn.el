;;; gryphn.el --- Scenario driver for the gryphn layer -*- lexical-binding: t -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; How the scenarios do things in the gryphn layer.  Setup goes through its own functions;
;; the behaviour under test always goes through input events.

(require 'drgnx-uitest)

(defconst drgnx-driver-focus-explorer-keys "C-S-e" "Keys that focus the Explorer.")
(defconst drgnx-driver-explorer-down-key "n" "Moves the Explorer selection down (treemacs).")
(defconst drgnx-driver-explorer-target "treemacs-mode"
  "How `drgnx-uitest-target-xy' finds the Explorer window (buffer name or major mode).")

(defun drgnx-driver-explorer-collapse (text)
  "Collapse the Explorer folder whose row shows TEXT (setup, not under test)."
  (with-selected-window (drgnx-driver-explorer-window)
    (goto-char (point-min)) (search-forward text) (treemacs-TAB-action)))

(defun drgnx-driver-buffers-top-row ()
  "The buffer listed on the first visible row of the Buffers panel, or nil."
  (let ((w (drgnx-driver-buffers-window)))
    (with-current-buffer (window-buffer w)
      (save-excursion
        (goto-char (window-start w))
        (let (b)
          (while (and (not b) (not (eobp)))
            (setq b (car (get-text-property (point) 'ibuffer-properties)))
            (forward-line 1))
          b)))))

(defun drgnx-driver-reset ()
  "A clean layout: sidebar hidden, one editor window."
  (when (gryphn-workspace-sidebar-showing-p) (gryphn-workspace-hide-sidebar))
  (select-window (gryphn-workspace-editor-window))
  (delete-other-windows))

(defun drgnx-driver-open-file (file)
  (select-window (gryphn-workspace-editor-window))
  (find-file file))

(defun drgnx-driver-show-sidebar ()
  (unless (gryphn-workspace-sidebar-showing-p) (gryphn-workspace-show-sidebar)))

(defun drgnx-driver-explorer-window () (gryphn-workspace--explorer-window))
(defun drgnx-driver-buffers-window () (gryphn-workspace--buffers-window))
(defun drgnx-driver-editor-window () (gryphn-workspace-editor-window))

(defun drgnx-driver-explorer-roots ()
  "Directories the Explorer shows as roots."
  (mapcar (lambda (p) (file-name-as-directory (expand-file-name (treemacs-project->path p))))
          (treemacs-workspace->projects (treemacs-current-workspace))))

(defun drgnx-driver-buffers-row-xy (buffer &optional column-text)
  "Pixel of BUFFER's row in the Buffers panel — on COLUMN-TEXT (e.g. \"×\") if given."
  (let ((win (drgnx-driver-buffers-window)))
    (with-current-buffer (window-buffer win)
      (save-excursion
        (goto-char (point-min))
        (while (and (not (eobp)) (not (eq (car (get-text-property (point) 'ibuffer-properties)) buffer)))
          (forward-line 1))
        (when (eobp) (error "driver: no Buffers row for %s" buffer))
        (when column-text (search-forward column-text (pos-eol)) (goto-char (match-beginning 0)))
        (or (drgnx-uitest-pos-xy win (point)) (error "driver: Buffers row of %s is not visible" buffer))))))

(defun drgnx-driver-disable-follow ()
  "The override experiment: switch off the Explorer follow."
  (advice-add 'gryphn-workspace-explorer-follow :override #'ignore))

(defun drgnx-driver-enable-follow ()
  (advice-remove 'gryphn-workspace-explorer-follow #'ignore))
