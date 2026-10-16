;;; drgnx.el --- drgnx: a workbench-first Emacs framework -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The core: paths, staged hooks, the no-prompt guard, the command registry, key profiles,
;; everything generated from them (menus, context menus, palette, key sheet), and a minimal
;; module system.  `drgnx-init' boots it; the checkout's init/ calls it.  See docs/core.md.

;;; Code:
(require 'drgnx-paths)
(require 'drgnx-hooks)
(require 'drgnx-guard)
(require 'drgnx-registry)
(require 'drgnx-surfaces)
(require 'drgnx-palette)
(require 'drgnx-keys)
(require 'drgnx-modules)

(defgroup drgnx nil "drgnx, a workbench-first Emacs framework." :group 'convenience)

(defun drgnx--core-commands ()
  "The commands the core itself provides."
  (drgnx-command-define 'palette :category "View" :title "Command Palette"
    :command #'drgnx-palette :menu '("View") :doc "Every command by name, with its key")
  (drgnx-command-define 'keys-sheet :category "Help" :title "Keyboard Shortcuts"
    :command #'drgnx-surfaces-cheatsheet :menu '("Help") :doc "Every command, its key and where to click")
  (drgnx-command-define 'modules-report :category "Help" :title "Module Report"
    :command #'drgnx-modules-show-report :menu '("Help") :doc "Which modules loaded, how long they took, what failed")
  (drgnx-command-define 'preferences-modules :category "Preferences" :title "Modules"
    :command #'drgnx-modules-list :menu '("Options") :doc "Every module, its status; turn modules on and off")
  (drgnx-command-define 'modules-toggle :category "Modules" :title "Turn On / Off" :command #'drgnx-modules-list-toggle
    :map 'drgnx-modules-list-mode-map :when (lambda () (derived-mode-p 'drgnx-modules-list-mode))
    :doc "Turn the module on this row off at the next start, or back on")
  (drgnx-command-define 'keyboard-profile :category "Preferences" :title "Keyboard Profile…"
    :command #'drgnx-keys-choose-profile :menu '("Options")
    :doc "VS Code, Emacs or Vim keys, or Emacs/Vim editing with VS Code app keys"))

(defun drgnx-init ()
  "Boot drgnx: guard, staged hooks, core commands, modules, keys, then the generated surfaces."
  (drgnx-guard-mode 1)
  (drgnx-hooks-install)
  (drgnx--core-commands)
  ;; Modules that run later (idle, first frame, …) register commands after the keys were applied.
  (add-hook 'drgnx-modules-after-stage-functions
            (lambda (stage) (unless (eq stage 'startup) (drgnx-keys-apply) (drgnx-surfaces-refresh))))
  (drgnx-modules-start (expand-file-name "modules" drgnx-dir))
  (drgnx-keys-apply)
  (drgnx-surfaces-refresh))

(provide 'drgnx)
;;; drgnx.el ends here
