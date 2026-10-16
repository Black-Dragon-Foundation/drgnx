;;; drgnx.el --- drgnx: a workbench-first Emacs framework -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The core: paths, staged hooks, the no-prompt guard, the command registry and everything
;; generated from it (keys, menus, context menus, palette, F1 sheet), and a minimal module
;; system.  `drgnx-init' boots it; the checkout's init/ calls it.  See docs/core.md.

;;; Code:
(require 'drgnx-paths)
(require 'drgnx-hooks)
(require 'drgnx-guard)
(require 'drgnx-registry)
(require 'drgnx-surfaces)
(require 'drgnx-palette)
(require 'drgnx-modules)

(defgroup drgnx nil "drgnx, a workbench-first Emacs framework." :group 'convenience)

(defun drgnx--core-commands ()
  "The commands the core itself provides."
  (drgnx-command-define 'palette :category "View" :title "Command Palette" :key "C-S-p"
    :command #'drgnx-palette :menu '("View") :doc "Every command by name, with its key")
  (drgnx-command-define 'keys-sheet :category "Help" :title "Keyboard Shortcuts" :key "<f1>"
    :command #'drgnx-surfaces-cheatsheet :menu '("Help") :doc "Every command, its key and where to click")
  (drgnx-command-define 'modules-report :category "Help" :title "Module Report"
    :command #'drgnx-modules-show-report :menu '("Help") :doc "Which modules loaded, how long they took, what failed"))

(defun drgnx-init ()
  "Boot drgnx: guard, staged hooks, core commands, modules, then the generated surfaces."
  (drgnx-guard-mode 1)
  (drgnx-hooks-install)
  (drgnx--core-commands)
  (drgnx-modules-start (expand-file-name "modules" drgnx-dir))
  (drgnx-surfaces-refresh))

(provide 'drgnx)
;;; drgnx.el ends here
