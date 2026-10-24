;;; drgnx.el --- drgnx: a workbench-first Emacs framework -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The core: paths, staged hooks, the no-prompt guard, the command registry, key profiles,
;; everything generated from them (menus, context menus, palette, key sheet), and a minimal
;; module system.  `drgnx-init' boots it; the checkout's init/ calls it.  See docs/develop/core.md.

;;; Code:
(require 'drgnx-paths)
(require 'drgnx-file)
(require 'drgnx-hooks)
(require 'drgnx-guard)
(require 'drgnx-ui-kit)
(require 'drgnx-sandbox-vc)
(require 'drgnx-registry)
(require 'drgnx-surfaces)
(require 'drgnx-palette)
(require 'drgnx-keys)
(require 'drgnx-modal)
(require 'drgnx-modules)
(require 'drgnx-pkg-activate)
(require 'drgnx-onboard)
(require 'drgnx-modal-choose)
(autoload 'drgnx-ai--on-first-window "drgnx-ai-probe")
(autoload 'drgnx-hub-restart-now "drgnx-hub-client" nil t)
(autoload 'drgnx-secrets-export-keys "drgnx-secrets" nil t)
(autoload 'drgnx-secrets-import-keys "drgnx-secrets" nil t)
(autoload 'drgnx-heap-audit-command "drgnx-heap" nil t)
(autoload 'drgnx-store-allow-personal-file "drgnx-store-privacy" nil t)
(autoload 'drgnx-store-revoke-personal-file "drgnx-store-privacy" nil t)
(autoload 'drgnx-store-deny-personal-path "drgnx-store-privacy" nil t)
(autoload 'drgnx-store-undeny-personal-path "drgnx-store-privacy" nil t)
(require 'drgnx-gc)
(require 'drgnx-gc-census)
(require 'drgnx-session)
(require 'drgnx-config)
(require 'drgnx-shell-env)
(require 'drgnx-notice-echo)
(require 'drgnx-notice-save)
(require 'drgnx-notices)
(require 'drgnx-settings-migrate)
(require 'drgnx-settings-apply)
(require 'drgnx-settings-prov)
(require 'drgnx-settings-mode)            ; language overrides (L1): on change-major-mode-after-body-hook once loaded
(require 'drgnx-user-lisp)
(require 'drgnx-settings-workspace)       ; workspace layers W1, W2: `drgnx-settings-workspace-enable' runs at load,
                                        ; so the first file visited (before `drgnx-init' too) gets them
(require 'drgnx-settings-live)
(require 'drgnx-settings-runtime)         ; the editor's override sender to the hub (config/settings)
(require 'drgnx-lisp-index)
(require 'drgnx-settings-lisp-page)       ; told of every load of your Lisp; its keymap is there for the keys apply
                                        ; (a map of a library not loaded yet waits in an after-load entry per apply)

(defgroup drgnx nil "drgnx, a workbench-first Emacs framework." :group 'convenience)

(defun drgnx-user-config-file ()
  "Your own Emacs Lisp, loaded at the end of every start: config.el in `drgnx-user-dir'."
  (expand-file-name "config.el" (drgnx-user-dir)))

(defun drgnx--load-user-config (&optional file)
  "Load FILE (default `drgnx-user-config-file') when it exists; an error in it is a notice, never stops
the start.  Provenance records which of its forms sets what (`drgnx-settings-prov-with-load'); the Lisp files page
hears the time, the error and the parent (`drgnx-settings-lisp-page-note-load')."
  (let ((file (or file (drgnx-user-config-file))))
    (drgnx-settings-prov-with-load file
      (when (and (file-exists-p file) (drgnx-user-lisp-on-p file))   ; the file's switch (Settings: Lisp Files, bisect)
        (let ((start (float-time)) (parent (drgnx-user-lisp-parent)) msg)
          (condition-case err (load file nil 'nomessage 'nosuffix)
            (error (setq msg (error-message-string err))
                   (drgnx-notify 'config 'fail (format "%s: %s (the rest of it did not run)" (abbreviate-file-name file) msg)
                                 :id 'config-el :life 'condition :command 'preferences-user-config)))
          ;; inside the provenance scope, so an error's line is the form being read when it happened
          (ignore-errors
            (drgnx-settings-lisp-page-note-load file :seconds (- (float-time) start) :error msg :parent parent)))))))

(defun drgnx-open-user-config ()
  "Open your config.el — made from a short template the first time."
  (interactive)
  (let ((file (drgnx-user-config-file)))
    (unless (file-exists-p file)
      (drgnx-file-write-text file ";;; config.el --- my drgnx configuration -*- lexical-binding: t -*-
;; Loaded at the end of every start, after drgnx's startup modules: settings here win.
;; An error is said in *Messages* and drgnx starts anyway; `drgnx safe' skips this file.

"))
    (find-file file)))

(defun drgnx--core-commands ()
  "The commands the core itself provides."
  (drgnx-onboard-register-commands)
  (drgnx-session-register-commands)
  (drgnx-modal-register-commands)
  (drgnx-gc-census-register-commands)
  (drgnx-config-register-commands)
  (drgnx-shell-env-register-commands)
  (drgnx-notices-register-commands)
  (drgnx-command-define 'palette :category "View" :title "Command Palette"
                        :command #'drgnx-palette :menu '("View") :doc "Every command by name, with its key")
  (drgnx-command-define 'keys-sheet :category "Help" :title "Keyboard Shortcuts"
                        :command #'drgnx-surfaces-cheatsheet :menu '("Help") :doc "Every command, its key and where to click")
  (drgnx-command-define 'modules-report :category "Help" :title "Module Report"
                        :command #'drgnx-modules-show-report :menu '("Help") :doc "Which modules loaded, how long they took, what failed")
  (drgnx-command-define 'heap-audit :category "Help" :title "Heap Audit" :command #'drgnx-heap-audit-command
                        :menu '("Help") :doc "What keeps the Lisp heap large, by owner (asks first: Emacs stops for seconds)")
  (drgnx-command-define 'preferences-modules :category "Preferences" :title "Modules"
                        :command #'drgnx-modules-list :menu '("Options") :doc "Every module, its status; turn modules on and off")
  (drgnx-command-define 'preferences-user-config :category "Preferences" :title "Open User Config"
                        :command #'drgnx-open-user-config :menu '("Options")
                        :doc "Your own Emacs Lisp (config.el), loaded at the end of every start")
  (drgnx-command-define 'preferences :category "Preferences" :title "All Preferences…"
                        :command #'drgnx-palette-preferences :doc "The palette, on every Preferences command")
  (drgnx-command-define 'modules-toggle :category "Modules" :title "Turn On / Off" :command #'drgnx-modules-list-toggle
                        :map 'drgnx-modules-list-mode-map :when (lambda () (derived-mode-p 'drgnx-modules-list-mode))
                        :doc "Turn the module on this row off now, or back on (asks once when other modules need it); a few stop at the next start")
  (drgnx-command-define 'keyboard-profile :category "Preferences" :title "Keyboard Profile…"
                        :command #'drgnx-keys-choose-profile :menu '("Options")
                        :doc "VS Code, Emacs or Vim keys, or Emacs/Vim editing with VS Code app keys")
  (drgnx-command-define 'hub-restart-now :category "Agents" :title "Hub: Restart Now" :command #'drgnx-hub-restart-now
                        :doc "Restart the agent hub (Ratatoskr) now, e.g. after drgnx was updated; the agent sessions it runs end")
  (drgnx-command-define 'store-allow-personal-file :category "Preferences" :title "Open a Personal File to the Store…"
                        :command #'drgnx-store-allow-personal-file
                        :doc "Let the tracker read one file under ~/org (never your personal notes); agents may then read what it parses")
  (drgnx-command-define 'store-revoke-personal-file :category "Preferences" :title "Close a Personal File to the Store…"
                        :command #'drgnx-store-revoke-personal-file
                        :doc "Close a file you opened to the store; what came in from it is excised")
  (drgnx-command-define 'store-deny-personal-path :category "Preferences" :title "Keep a Path Out of the Store…"
                        :command #'drgnx-store-deny-personal-path
                        :doc "Keep a file, folder or glob out of the store for good, as firmly as your notes; what came in is excised")
  (drgnx-command-define 'store-undeny-personal-path :category "Preferences" :title "Stop Keeping a Path Out…"
                        :command #'drgnx-store-undeny-personal-path
                        :doc "Take one of your own entries off the store's deny list (the built-in list stays)")
  (drgnx-command-define 'portability-export-keys :category "Portability" :title "Export Keys"
                        :command #'drgnx-secrets-export-keys
                        :doc "Your provider keys into secrets.age (age, a passphrase), for a second machine")
  (drgnx-command-define 'portability-import-keys :category "Portability" :title "Import Keys"
                        :command #'drgnx-secrets-import-keys
                        :doc "The provider keys of secrets.age into this machine's keyring"))

(defun drgnx--after-teardown ()
  "Once a batch of module teardowns is done: keys, menus and which-key labels follow the registry.
`drgnx-keys-apply' puts back Emacs's own bindings first, then binds what the registry still holds."
  (drgnx-keys-apply)
  (drgnx-surfaces-refresh))

(add-hook 'drgnx-modules-after-teardown-functions #'drgnx--after-teardown)

(defun drgnx-init ()
  "Boot drgnx: guard, staged hooks, core commands, modules, keys, then the generated surfaces.
The steady GC threshold is set at the end, also when a step fails (early-init deferred collection)."
  (unwind-protect
      (progn
        (drgnx-guard-mode 1)
        (drgnx-sandbox-vc-mode 1)                      ; no git in a job's folder outside its sandbox
        (drgnx-hooks-install)
        (drgnx-notice-desktop-mode 1)                  ; new things waiting on you, on the desktop while you are away
        (drgnx-notice-echo-mode 1)                     ; failures and new things waiting on you, in the echo area
        (drgnx-session-setup)                         ; keep running or quit; the close button
        (drgnx-shell-env-start)                        ; the login shell's PATH, asynchronously
        (drgnx-notice-mode-line-mode 1)                ; the needs-you and problems counts in the mode line
        (drgnx-notice-save-mode 1)                     ; this Emacs's notices in its session file, for the doctor
        (add-hook 'drgnx-first-gui-frame-hook #'drgnx-onboard--on-first-window)   ; a first start: the Welcome
        (add-hook 'drgnx-first-gui-frame-hook #'drgnx-ai--on-first-window)        ; the local AI runner, started again
        (let ((safe (getenv "DRGNX_SAFE")))            ; drgnx safe: the core only
          (drgnx-settings-migrate-maybe)               ; the old settings files into settings.el, once (safe mode too)
          (if safe
              (drgnx-settings-apply-global :owned-only t)   ; safe mode: drgnx's own settings only
            (condition-case err (drgnx-pkg-activate)
              (error (drgnx-notify 'modules 'fail (format "packages were not activated: %s" (error-message-string err))
                                   :id 'packages :life 'condition)))
            (drgnx-pkg-guard-mode 1)
            (drgnx-settings-apply-global)              ; settings.el: after the packages, before custom.el
            (when custom-file (drgnx--load-user-config custom-file)))  ; what Customize saved: packages active, guarded
          (drgnx--core-commands)
          ;; Modules that run later (idle, first frame, …) register commands after the keys were applied.
          (add-hook 'drgnx-modules-after-stage-functions
                    (lambda (stage) (unless (eq stage 'startup) (drgnx-keys-apply) (drgnx-surfaces-refresh))))
          (if safe
              (message "drgnx safe mode: the core only — no modules, no packages (drgnx bisect finds a module that breaks)")
            (condition-case err (drgnx-modules-start (expand-file-name "modules" drgnx-dir))   ; never stops the rest
              (error (drgnx-notify 'modules 'fail (format "modules did not start: %s" (error-message-string err))
                                   :id 'start :life 'condition)))
            (drgnx--load-user-config)                  ; config.el
            (drgnx-user-lisp-load-all)                 ; your Lisp files
            (drgnx-settings-apply-pass)                ; the end-of-init :apply pass
            (drgnx-settings-live-start)                ; changes to the settings files apply at once
            (drgnx-lisp-index-schedule)))              ; the index of your Lisp files, built at idle
        (drgnx-keys-apply)
        (drgnx-modal-apply-pending)                    ; a Vim stack chosen before its engine was installed
        (drgnx-surfaces-refresh))
    (drgnx-gc-setup)))

(provide 'drgnx)
;;; drgnx.el ends here
