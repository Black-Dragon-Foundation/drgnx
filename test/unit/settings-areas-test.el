;;; settings-areas-test.el --- batch tests: keys, modules, large files and the session are settings (Task 16) -*- lexical-binding: t -*-
;; Every test runs under `drgnx-test-with-areas' (temp config and state folders, settings.el not applied in this
;; process) or `drgnx-test-with-modules'; nothing reaches ~.  The per-area tests are in keys-eld-test.el,
;; keys-edit-test.el, modules-eld-test.el, session-eld-test.el and large-files-test.el.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/areas-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(require 'drgnx-settings-live)
(require 'drgnx-keys-edit)

(ert-deftest drgnx-settings-areas/a-config-el-setq-of-modules-disabled-turns-it-off-by-end-of-init ()
  (drgnx-test-with-areas
    (let ((stopped 0) (drgnx-modules--table nil) (drgnx-modules--report nil)
          (drgnx-modules-after-teardown-functions nil)
          (drgnx-settings-live--applied (make-hash-table :test 'eq)))
      (drgnx-module-define 'test/a :doc "a" :setup #'ignore :teardown (lambda () (cl-incf stopped)))
      (drgnx-modules-run 'startup)
      (should (drgnx-module-running-p 'test/a))
      ;; config.el ran `(setq drgnx-modules-disabled '(test/a))' after the modules started
      (let ((drgnx-modules-disabled '(test/a)) (drgnx-settings-apply--entries '((x . y))))
        (drgnx-settings-apply-pass)                    ; the end-of-init pass
        (should-not (drgnx-module-running-p 'test/a))
        (should (= stopped 1))
        (drgnx-settings-apply-pass)                    ; once
        (should (= stopped 1))))))

(ert-deftest drgnx-settings-areas/keys-edit-writes-settings ()
  (drgnx-test-with-areas
    (let ((drgnx-keys-last (list :bindings nil)))
      (cl-letf (((symbol-function 'drgnx-keys-apply) #'ignore) ((symbol-function 'drgnx-surfaces-refresh) #'ignore))
        (should (drgnx-keys-edit-bind 'palette "C-c p"))
        (should (string-search "(drgnx-keys-bind ((palette \"C-c p\")))" (drgnx-test-areas-text)))
        (should (equal drgnx-keys-bind '((palette "C-c p"))))           ; applied at once
        (should (drgnx-keys-edit-unbind 'palette "C-c p"))
        (should (string-search "(drgnx-keys-unbind (palette))" (drgnx-test-areas-text)))
        (should-not drgnx-keys-bind)
        (should-not (file-exists-p (expand-file-name "keys.eld" (drgnx-user-dir))))))))

(ert-deftest drgnx-settings-areas/modules-page-writes-settings ()
  (drgnx-test-with-areas
    (let ((drgnx-modules--table nil) (drgnx-modules--report nil) (drgnx-modules-after-teardown-functions nil))
      (drgnx-module-define 'test/a :doc "a" :setup #'ignore)
      (drgnx-modules-run 'startup)
      (drgnx-modules-turn-off 'test/a)
      (should (string-search "(drgnx-modules-disabled (test/a))" (drgnx-test-areas-text)))
      (should-not (file-exists-p (expand-file-name "modules.eld" (drgnx-user-dir))))
      (should (drgnx-module-disabled-p 'test/a))
      (drgnx-modules-turn-on 'test/a)
      (should (string-search "(drgnx-modules-disabled nil)" (drgnx-test-areas-text)))
      (should (drgnx-module-running-p 'test/a)))))

(ert-deftest drgnx-settings-areas/look-theme-switches-live ()
  (let ((before custom-enabled-themes))
    (unwind-protect
        (drgnx-test-with-modules '(ui/look) :strict t
                                 (should (drgnx-module-running-p 'ui/look))
                                 (let ((drgnx-look-theme 'modus-vivendi))
                                   (drgnx-look--settings-apply)                ; the idle `:apply' after settings.el changed it
                                   (should (equal custom-enabled-themes '(modus-vivendi))))
                                 (let ((drgnx-look-theme 'modus-operandi))
                                   (drgnx-look--settings-apply)
                                   (should (equal custom-enabled-themes '(modus-operandi)))))
      (mapc #'disable-theme custom-enabled-themes)
      (dolist (theme (reverse before)) (load-theme theme t)))))

(ert-deftest drgnx-settings-areas/safe-mode-applies-keys ()
  ;; drgnx safe: settings.el's own entries apply, keys included, and the keys read them
  (drgnx-test-with-areas
    (let ((process-environment (cons "DRGNX_SAFE=1" process-environment)))
      (drgnx-test-areas-put
       "(drgnx-settings\n :version 1\n (some-package-setting 1)\n (drgnx-keys-layers ((emacs app editing window)))\n (drgnx-keys-unbind (keys-sheet)))\n")
      (drgnx-settings-apply-global :owned-only t)
      (should (equal drgnx-keys-layers '((emacs app editing window))))
      (let ((user (drgnx-keys-read-user)))
        (should (equal (plist-get user :layers) '((emacs app editing window))))
        (should (equal (plist-get user :unbind) '(keys-sheet)))))))

(ert-deftest drgnx-settings-areas/the-security-settings-are-never-for-a-workspace-or-an-agent ()
  ;; US-WORKSPACE-NEVER-1: the workspace refusal reads this metadata
  (dolist (var '(drgnx-keys-layers drgnx-keys-pending-layers drgnx-keys-bind drgnx-keys-unbind drgnx-keys-mac-option
                                   drgnx-keys-tty-fallback drgnx-modules-disabled drgnx-modules-enabled drgnx-modules-flags
                                   drgnx-modules-external drgnx-look-theme))
    (let ((meta (drgnx-setting-meta var)))
      (should (equal (list var (plist-get meta :workspace) (plist-get meta :agents)) (list var 'never 'never))))))

;;; settings-areas-test.el ends here
