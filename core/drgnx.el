;;; drgnx.el --- drgnx: a workbench-first Emacs framework -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The core: paths, staged hooks, the no-prompt guard, the command registry, key profiles,
;; everything generated from them (menus, context menus, palette, key sheet), and a minimal
;; module system.  `drgnx-init' boots it; the checkout's init/ calls it.  See docs/develop/core.md.

;;; Code:
(require 'drgnx-paths)
(require 'drgnx-hooks)
(require 'drgnx-guard)
(require 'drgnx-registry)
(require 'drgnx-surfaces)
(require 'drgnx-palette)
(require 'drgnx-keys)
(require 'drgnx-modules)
(require 'drgnx-pkg-activate)
(require 'drgnx-onboard)
(autoload 'drgnx-ai--on-first-window "drgnx-ai-probe")
(autoload 'drgnx-secrets-export-keys "drgnx-secrets" nil t)
(autoload 'drgnx-secrets-import-keys "drgnx-secrets" nil t)
(require 'drgnx-gc)
(require 'drgnx-session)

(defgroup drgnx nil "drgnx, a workbench-first Emacs framework." :group 'convenience)

(defun drgnx-user-config-file ()
  "Your own Emacs Lisp, loaded at the end of every start: config.el in `drgnx-user-dir'."
  (expand-file-name "config.el" (drgnx-user-dir)))

(defun drgnx--load-user-config ()
  "Load `drgnx-user-config-file' when it exists; an error in it is said in *Messages*, never stops the start."
  (let ((file (drgnx-user-config-file)))
    (when (file-exists-p file)
      (condition-case err (load file nil 'nomessage 'nosuffix)
        (error (message "drgnx: %s: %s (the rest of it did not run)" (abbreviate-file-name file) (error-message-string err)))))))

(defun drgnx-open-user-config ()
  "Open your config.el — made from a short template the first time."
  (interactive)
  (let ((file (drgnx-user-config-file)))
    (unless (file-exists-p file)
      (make-directory (file-name-directory file) t)
      (write-region ";;; config.el --- my drgnx configuration -*- lexical-binding: t -*-
;; Loaded at the end of every start, after drgnx's startup modules: settings here win.
;; An error is said in *Messages* and drgnx starts anyway; `drgnx safe' skips this file.

" nil file nil 'silent))
    (find-file file)))

(defun drgnx--core-commands ()
  "The commands the core itself provides."
  (drgnx-onboard-register-commands)
  (drgnx-session-register-commands)
  (drgnx-command-define 'palette :category "View" :title "Command Palette"
                        :command #'drgnx-palette :menu '("View") :doc "Every command by name, with its key")
  (drgnx-command-define 'keys-sheet :category "Help" :title "Keyboard Shortcuts"
                        :command #'drgnx-surfaces-cheatsheet :menu '("Help") :doc "Every command, its key and where to click")
  (drgnx-command-define 'modules-report :category "Help" :title "Module Report"
                        :command #'drgnx-modules-show-report :menu '("Help") :doc "Which modules loaded, how long they took, what failed")
  (drgnx-command-define 'preferences-modules :category "Preferences" :title "Modules"
                        :command #'drgnx-modules-list :menu '("Options") :doc "Every module, its status; turn modules on and off")
  (drgnx-command-define 'preferences-user-config :category "Preferences" :title "Open User Config"
                        :command #'drgnx-open-user-config :menu '("Options")
                        :doc "Your own Emacs Lisp (config.el), loaded at the end of every start")
  (drgnx-command-define 'preferences :category "Preferences" :title "All Preferences…"
                        :command #'drgnx-palette-preferences :doc "The palette, on every Preferences command")
  (drgnx-command-define 'modules-toggle :category "Modules" :title "Turn On / Off" :command #'drgnx-modules-list-toggle
                        :map 'drgnx-modules-list-mode-map :when (lambda () (derived-mode-p 'drgnx-modules-list-mode))
                        :doc "Turn the module on this row off at the next start, or back on")
  (drgnx-command-define 'keyboard-profile :category "Preferences" :title "Keyboard Profile…"
                        :command #'drgnx-keys-choose-profile :menu '("Options")
                        :doc "VS Code, Emacs or Vim keys, or Emacs/Vim editing with VS Code app keys")
  (drgnx-command-define 'portability-export-keys :category "Portability" :title "Export Keys"
                        :command #'drgnx-secrets-export-keys
                        :doc "Your provider keys into secrets.age (age, a passphrase), for a second machine")
  (drgnx-command-define 'portability-import-keys :category "Portability" :title "Import Keys"
                        :command #'drgnx-secrets-import-keys
                        :doc "The provider keys of secrets.age into this machine's keyring"))

(defun drgnx-init ()
  "Boot drgnx: guard, staged hooks, core commands, modules, keys, then the generated surfaces.
The steady GC threshold is set at the end, also when a step fails (early-init deferred collection)."
  (unwind-protect
      (progn
        (drgnx-guard-mode 1)
        (drgnx-hooks-install)
        (drgnx-session-setup)                          ; keep running or quit; the close button
        (add-hook 'drgnx-first-gui-frame-hook #'drgnx-onboard--on-first-window)   ; a first start: the Welcome
        (add-hook 'drgnx-first-gui-frame-hook #'drgnx-ai--on-first-window)        ; the local AI runner, started again
        (let ((safe (getenv "DRGNX_SAFE")))            ; drgnx safe: the core only
          (unless safe
            (condition-case err (drgnx-pkg-activate)
              (error (message "drgnx: packages not activated: %s" (error-message-string err))))
            (drgnx-pkg-guard-mode 1))
          (drgnx--core-commands)
          ;; Modules that run later (idle, first frame, …) register commands after the keys were applied.
          (add-hook 'drgnx-modules-after-stage-functions
                    (lambda (stage) (unless (eq stage 'startup) (drgnx-keys-apply) (drgnx-surfaces-refresh))))
          (if safe
              (message "drgnx safe mode: the core only — no modules, no packages (drgnx bisect finds a module that breaks)")
            (condition-case err (drgnx-modules-start (expand-file-name "modules" drgnx-dir))   ; never stops the rest
              (error (message "drgnx: modules did not start: %s" (error-message-string err))))
            (drgnx--load-user-config)))
        (drgnx-keys-apply)
        (drgnx-surfaces-refresh))
    (drgnx-gc-setup)))

(provide 'drgnx)
;;; drgnx.el ends here
