;;; drgnx-windows.el --- Module extra/windows: pick a window by letter (ace-window) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:
(require 'drgnx-modules)
(require 'drgnx-registry)

(drgnx-module-define 'extra/windows
  :doc "Pick Window: a letter on every window, type it to go there (ace-window)."
  :stage 'idle :packages '(ace-window)
  :setup (lambda ()
           (require 'ace-window)
           (drgnx-command-define 'go-window-pick :category "View" :title "Pick Window" :command 'ace-window
             :scope 'window :doc "Go to a window by its letter")))

(provide 'drgnx-windows)
;;; drgnx-windows.el ends here
