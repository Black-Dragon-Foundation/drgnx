;;; drgnx-guides.el --- Module extra/guides: indent guides (indent-bars) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Thin vertical guides at each indentation level of code (and YAML), on graphical frames — drawn by indent-bars
;; with stipples, not characters, so they cost little and never get in the way of the cursor.  Their colour comes
;; from the theme (the `highlight' face, blended).  See docs/guide/editing.md.

;;; Code:
(require 'drgnx-modules)
(require 'drgnx-registry)
(declare-function indent-bars-mode "indent-bars")
(defvar indent-bars-mode)
(defvar indent-bars-treesit-support)

(defvar drgnx-guides-modes '(prog-mode-hook yaml-mode-hook yaml-ts-mode-hook) "Where the guides go.")

(defun drgnx-guides--maybe ()
  "Guides in this buffer, on a graphical frame."
  (when (display-graphic-p) (indent-bars-mode 1)))

(defun drgnx-guides-toggle ()
  "Indent guides off or on in this buffer."
  (interactive)
  (indent-bars-mode (if (bound-and-true-p indent-bars-mode) -1 1)))

(defun drgnx-guides--teardown ()
  "The guides go off in the buffers that have them."
  (dolist (b (buffer-list))
    (with-current-buffer b (when (bound-and-true-p indent-bars-mode) (indent-bars-mode -1)))))

(drgnx-module-define 'extra/guides
                     :doc "Indent guides in code and YAML on graphical frames (indent-bars; the theme's colours)."
                     :stage 'first-frame :packages '(indent-bars)
                     :teardown #'drgnx-guides--teardown
                     :setup (lambda ()
                              (require 'indent-bars)
                              (drgnx-module-set 'indent-bars-treesit-support (and (fboundp 'treesit-available-p) (treesit-available-p)))
                              (dolist (h drgnx-guides-modes) (add-hook h #'drgnx-guides--maybe))
                              (drgnx-command-define 'toggle-indent-guides :category "View" :title "Toggle Indent Guides"
                                                    :command #'drgnx-guides-toggle :doc "Indent guides off or on in this buffer")))

(provide 'drgnx-guides)
;;; drgnx-guides.el ends here
