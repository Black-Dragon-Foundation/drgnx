;;; drgnx.el --- Scenario driver for drgnx -*- lexical-binding: t -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; How the scenarios do things in drgnx's workbench.  Setup goes through drgnx's own functions;
;; the behaviour under test always goes through input events, with the keys the active key
;; profile binds (so the scenarios follow a profile change).

(require 'drgnx-uitest)
(require 'drgnx-explorer)
(require 'drgnx-buffers)

(defun drgnx-driver--key (id)
  "The first key the active profile gives command ID."
  (or (car (car (drgnx-cmd-bound (drgnx-commands-get id))))
      (error "driver: command %s has no key in the active profile" id)))

(defconst drgnx-driver-focus-explorer-keys (drgnx-driver--key 'focus-explorer) "Keys that focus the Explorer.")
(defconst drgnx-driver-explorer-down-key (drgnx-driver--key 'explorer-next) "Moves the Explorer selection down.")
(defconst drgnx-driver-explorer-target "drgnx-explorer-mode"
  "How `drgnx-uitest-target-xy' finds the Explorer window (buffer name or major mode).")

(defun drgnx-driver-reset ()
  "A clean layout: sidebar hidden, one editor window."
  (drgnx-wb-hide-sidebar)
  (select-window (drgnx-wb-editor-window))
  (delete-other-windows))

(defun drgnx-driver-open-file (file)
  (select-window (drgnx-wb-editor-window))
  (find-file file))

(defun drgnx-driver-show-sidebar ()
  "Show the sidebar with the Explorer rooted at the editor's project (as opening that folder would)."
  (let ((default-directory (with-current-buffer (window-buffer (drgnx-wb-editor-window)) default-directory)))
    (drgnx-explorer-set-roots (list (if-let* ((p (project-current))) (project-root p) default-directory))))
  (drgnx-wb-show-sidebar))

(defun drgnx-driver-explorer-window () (drgnx-wb-section-window 'explorer))
(defun drgnx-driver-buffers-window () (drgnx-wb-section-window 'buffers))
(defun drgnx-driver-editor-window () (drgnx-wb-editor-window))

(defun drgnx-driver-explorer-roots () (drgnx-explorer-roots))

(defun drgnx-driver-explorer-collapse (text)
  "Collapse the Explorer folder at path TEXT (relative to the root, e.g. \"src/app\") — setup."
  (with-current-buffer drgnx-explorer-buffer-name
    (let ((pos (drgnx-explorer--row-pos (directory-file-name (expand-file-name text (car (drgnx-explorer-roots)))))))
      (unless pos (error "driver: no Explorer row for %s" text))
      (when (drgnx-explorer--expanded-p (get-text-property pos 'drgnx-node))
        (drgnx-explorer-toggle-at pos)))))

(defun drgnx-driver-buffers-top-row ()
  "The buffer listed on the first visible row of the Buffers panel, or nil."
  (let ((w (drgnx-driver-buffers-window)))
    (with-current-buffer (window-buffer w) (get-text-property (window-start w) 'drgnx-buffer))))

(defun drgnx-driver-buffers-row-xy (buffer &optional column-text)
  "Pixel of BUFFER's row in the Buffers panel — on COLUMN-TEXT (e.g. \"×\") if given."
  (let ((win (drgnx-driver-buffers-window)))
    (with-current-buffer (window-buffer win)
      (save-excursion
        (goto-char (or (drgnx-buffers--row-pos buffer) (error "driver: no Buffers row for %s" buffer)))
        (when column-text (search-forward column-text (pos-eol)) (goto-char (match-beginning 0)))
        (or (drgnx-uitest-pos-xy win (point)) (error "driver: Buffers row of %s is not visible" buffer))))))
