;;; drgnx-booster.el --- Module extra/booster: language servers through emacs-lsp-booster -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; With the `emacs-lsp-booster' program installed, eglot talks to language servers through it (eglot-booster, a
;; package from Git): JSON is parsed outside Emacs, so big answers no longer stall typing.  Without the program,
;; nothing changes.  See docs/guide/editing.md.

;;; Code:
(require 'drgnx-modules)
(declare-function eglot-booster-mode "eglot-booster")
(defvar eglot-booster-mode)
(defvar eglot-booster-no-remote-boost)

(defun drgnx-booster--setup ()
  "eglot through the booster when `emacs-lsp-booster' is installed; else eglot as it is."
  (when (executable-find "emacs-lsp-booster")
    (require 'eglot-booster)
    (drgnx-module-set 'eglot-booster-no-remote-boost t)  ; a remote host (TRAMP) seldom has the program
    (eglot-booster-mode 1)))

(drgnx-module-define 'extra/booster
                     :doc "Language servers through emacs-lsp-booster when it is installed (faster eglot); else nothing changes."
                     :stage 'idle :packages '(eglot-booster)
                     :setup #'drgnx-booster--setup)

(provide 'drgnx-booster)
;;; drgnx-booster.el ends here
