;;; drgnx-undo.el --- Module extra/undo: the undo tree (vundo) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:
(require 'drgnx-modules)
(require 'drgnx-registry)

(drgnx-module-define 'extra/undo
  :doc "Undo Tree: every state of the buffer, browsable (vundo)."
  :stage 'idle :packages '(vundo)
  :setup (lambda ()
           (require 'vundo)
           (drgnx-command-define 'edit-undo-tree :category "Edit" :title "Undo Tree…" :command 'vundo
             :scope 'editing :doc "Browse every state of the buffer")))

(provide 'drgnx-undo)
;;; drgnx-undo.el ends here
