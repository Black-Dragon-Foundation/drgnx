;;; settings-compat-global-test.el --- design §15's global rows, each in a child Emacs -*- lexical-binding: t -*-
;; Rows C1, C2, C3, C5, C7, C7b, C13, C14, C16, C17, C18, C22 (unified-settings Task 8).  Each row runs in a child
;; Emacs under a temp HOME (test/settings-child.el) with a small package (`sat-pkg', under ~/sat), and goes through
;; drgnx's start order for the settings layers: settings.el (`drgnx-settings-apply-global'), custom.el, config.el.
;; `drgnx-settings-test-check-row' asserts the value, `custom-variable-state', `describe-variable''s text, the source
;; `drgnx-settings-explain' gives and, where a row says so, that the answer equals stock Emacs's with drgnx's layers
;; empty.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/settings-child" drgnx-dir) nil t)

(defconst drgnx-settings-compat--pkg
  ";;; sat-pkg.el --- the rows' package  -*- lexical-binding: t -*-
(defvar sat-sets 0 \"How many times sat-width's :set ran.\")
(defvar sat-mode-runs 0 \"How many times sat-global-mode's body ran.\")
(defgroup sat nil \"The rows' package.\" :group 'convenience)
(defcustom sat-width 70 \"A width.\" :type 'integer :group 'sat
  :set (lambda (s v) (setq sat-sets (1+ sat-sets)) (set-default s v)))
(defcustom sat-height 70 \"A height.\" :type 'integer :group 'sat)
(define-minor-mode sat-global-mode \"A global mode.\" :global t :group 'sat
  (setq sat-mode-runs (1+ sat-mode-runs)))
(provide 'sat-pkg)
"
  "~/sat/sat-pkg.el: options with and without a `:set', and a global minor mode.")

(defconst drgnx-settings-compat--later
  ";;; sat-later.el --- a package loaded after start  -*- lexical-binding: t -*-
(defvar sat-later-sets 0 \"How many times sat-later's :set ran.\")
(defcustom sat-later 1 \"Later.\" :type 'integer :group 'sat
  :set (lambda (s v) (setq sat-later-sets (1+ sat-later-sets)) (set-default s v)))
(provide 'sat-later)
"
  "~/sat/sat-later.el: a package nothing loads at start.")

(defconst drgnx-settings-compat--start
  '((progn (add-to-list 'load-path (expand-file-name "~/sat")) (require 'sat-pkg) t)
    (progn (drgnx-settings-apply-global) t)
    (progn (drgnx--load-user-config (expand-file-name "custom.el" (drgnx-user-dir))) t)
    (progn (drgnx--load-user-config) t))
  "drgnx-init's settings steps in order (the package already loaded): settings.el, custom.el, config.el.")

(defconst drgnx-settings-compat--stock-start
  '((progn (add-to-list 'load-path (expand-file-name "~/sat")) (require 'sat-pkg) t)
    (progn (load (expand-file-name "custom.el" (getenv "DRGNX_CONFIG_DIR")) t t t) t)
    (progn (load (expand-file-name "config.el" (getenv "DRGNX_CONFIG_DIR")) t t t) t))
  "The same start in stock Emacs: custom.el, then config.el.")

(defun drgnx-settings-compat--settings (entries)
  "settings.el's text holding ENTRIES (each an entry's text)."
  (concat "(drgnx-settings\n :version 1\n " (string-join entries "\n ") ")\n"))

(cl-defun drgnx-settings-compat--run (forms &key settings custom config files env (start drgnx-settings-compat--start))
  "FORMS' values in a child after START, with settings.el holding SETTINGS (entry texts), custom.el CUSTOM and
config.el CONFIG (texts), and FILES.  The row fails when the child stops with an error."
  (let ((r (drgnx-settings-test-child
            (append start forms)
            :files (append (list (cons "~/sat/sat-pkg.el" drgnx-settings-compat--pkg)
                                 (cons "~/sat/sat-later.el" drgnx-settings-compat--later)
                                 (cons "settings.el" (drgnx-settings-compat--settings settings)))
                           (and custom (list (cons "custom.el" custom)))
                           (and config (list (cons "config.el" config)))
                           files)
            :env env)))
    (should (equal (plist-get r :error) nil))
    (nthcdr (length start) (plist-get r :values))))

(cl-defun drgnx-settings-compat--stock-equal (var &key custom config files forms)
  "Assert that VAR's answer (`drgnx-settings-test-answer') in stock Emacs equals drgnx's with its layers empty, both
after custom.el CUSTOM, config.el CONFIG and FORMS."
  (let ((stock (car (last (drgnx-settings-compat--run (append forms `((drgnx-settings-test-answer ',var)))
                                                      :custom custom :config config :files files
                                                      :env '("DRGNX_SETTINGS_TEST_STOCK=1")
                                                      :start drgnx-settings-compat--stock-start)))))
    (should stock)
    (should (equal (car (last (drgnx-settings-compat--run
                               (append forms `((drgnx-settings-test-check-row ',var :stock-equal ',stock)))
                               :custom custom :config config :files files)))
                   t))))

(ert-deftest drgnx-settings-compat/c1-setq-default-in-config-el-wins ()
  ;; Your setq-default wins over settings.el; a later UI change is saved, not applied.
  (should (equal (drgnx-settings-compat--run
                  '((drgnx-settings-test-check-row 'sat-width :value 80 :state 'changed :describe "Original value was"
                                                   :source "your Lisp (config.el:1)")
                    (drgnx-settings-push 'sat-width 120)
                    sat-width)
                  :settings '("(sat-width 100)") :config "(setq-default sat-width 80)\n")
                 '(t stored 80)))
  (drgnx-settings-compat--stock-equal 'sat-width :config "(setq-default sat-width 80)\n"))

(ert-deftest drgnx-settings-compat/c2-setopt-in-config-el ()
  ;; setopt: your value, its :set ran, state changed (P1).
  (should (equal (drgnx-settings-compat--run
                  '((drgnx-settings-test-check-row 'sat-width :value 80 :state 'changed :source "your Lisp (config.el:2)")
                    (- sat-sets sat-before-setopt))
                  :settings '("(sat-width 100)")
                  :config "(defvar sat-before-setopt sat-sets)\n(setopt sat-width 80)\n")
                 '(t 1))))

(ert-deftest drgnx-settings-compat/c3-custom-el-wins ()
  ;; custom-set-variables in custom.el (theme user) over settings.el: Customize's value, state saved.
  (let ((custom "(custom-set-variables '(sat-width 90))\n"))
    (should (equal (drgnx-settings-compat--run
                    '((drgnx-settings-test-check-row 'sat-width :value 90 :state 'saved :source "Customize (custom.el:1)")
                      (drgnx-settings-push 'sat-width 120)
                      (mapcar #'car (get 'sat-width 'theme-value)))
                    :settings '("(sat-width 100)") :custom custom)
                   '(t stored (user drgnx))))
    (drgnx-settings-compat--stock-equal 'sat-width :custom custom)))

(ert-deftest drgnx-settings-compat/c5-use-package-custom ()
  ;; use-package :custom: your value, theme use-package above drgnx (P7); with use-package-use-theme nil, a session
  ;; set that drgnx does not push over.
  (let ((with-theme "(require 'use-package)\n(setq use-package-use-theme t)\n(use-package sat-pkg :custom (sat-width 7))\n")
        (without "(require 'use-package)\n(setq use-package-use-theme nil)\n(use-package sat-pkg :custom (sat-width 7))\n"))
    (should (equal (drgnx-settings-compat--run
                    '((drgnx-settings-test-check-row 'sat-width :value 7 :state 'themed :source "your Lisp (config.el:3)")
                      (mapcar #'car (get 'sat-width 'theme-value))
                      (drgnx-settings-push 'sat-width 120)
                      sat-width)
                    :settings '("(sat-width 100)") :config with-theme)
                   '(t (use-package drgnx) stored 7)))
    (should (equal (drgnx-settings-compat--run
                    '((drgnx-settings-test-check-row 'sat-width :value 7)
                      (drgnx-settings-push 'sat-width 120)
                      sat-width)
                    :settings '("(sat-width 100)") :config without)
                   '(t stored 7)))
    (drgnx-settings-compat--stock-equal 'sat-width :config with-theme)))

(ert-deftest drgnx-settings-compat/c7-a-package-not-yet-loaded ()
  ;; Applied at its defcustom, :set run once; drgnx loads nothing.
  (should (equal (drgnx-settings-compat--run
                  '((featurep 'sat-later)
                    (progn (require 'sat-later) t)
                    (drgnx-settings-test-check-row 'sat-later :value 5 :state 'themed :describe "Original value was"
                                                   :source "Settings (settings.el:3)")
                    sat-later-sets)
                  :settings '("(sat-later 5)"))
                 '(nil t t 1))))

(ert-deftest drgnx-settings-compat/c7b-an-autoloaded-minor-mode-variable ()
  ;; savehist-mode in settings.el loads savehist at apply, as the same entry in custom.el does (R3).
  (should (equal (drgnx-settings-compat--run
                  '((featurep 'savehist)
                    (drgnx-settings-test-check-row 'savehist-mode :value t :state 'themed :source "Settings (settings.el:3)"))
                  :settings '("(savehist-mode t)"))
                 '(t t))))

(ert-deftest drgnx-settings-compat/c13-a-colour-theme-and-disabling-every-theme ()
  ;; A colour theme loaded later wins (Emacs's order); `(mapc #'disable-theme custom-enabled-themes)' leaves drgnx
  ;; alone, since it is not in the list.
  (let ((files '(("~/themes/sat-colours-theme.el"
                  . "(deftheme sat-colours \"Colours.\")\n(custom-theme-set-variables 'sat-colours '(sat-width 60))\n(provide-theme 'sat-colours)\n")))
        (load '((progn (add-to-list 'custom-theme-load-path (expand-file-name "~/themes")) (load-theme 'sat-colours t)
                       sat-width)
                (memq 'drgnx custom-enabled-themes)
                (progn (mapc #'disable-theme custom-enabled-themes) sat-width))))
    (should (equal (drgnx-settings-compat--run
                    (append load '((drgnx-settings-test-check-row 'sat-width :value 100 :state 'themed
                                                                  :source "Settings (settings.el:3)")))
                    :settings '("(sat-width 100)") :files files)
                   '(60 nil 100 t)))
    (drgnx-settings-compat--stock-equal 'sat-width :files files :forms load)))

(ert-deftest drgnx-settings-compat/c14-a-session-set-at-runtime ()
  ;; customize-set-variable (Customize's Set for current session) and set-variable apply; a later UI change is stored.
  (should (equal (drgnx-settings-compat--run
                  '((progn (customize-set-variable 'sat-width 80) (set-variable 'sat-height 85) t)
                    (drgnx-settings-test-check-row 'sat-width :value 80 :state 'set :source "Customize, this session only")
                    (drgnx-settings-test-check-row 'sat-height :value 85 :source "changed this session")
                    (plist-get (drgnx-settings-explain 'sat-width) :changed-this-session)
                    (list (drgnx-settings-push 'sat-width 120) (drgnx-settings-push 'sat-height 120))
                    (list sat-width sat-height))
                  :settings '("(sat-height 100)" "(sat-width 100)"))
                 '(t t t t (stored stored) (80 85)))))

(ert-deftest drgnx-settings-compat/c16-safe-mode-and-emacs-q ()
  ;; drgnx safe: only drgnx's own entries apply.  emacs -Q loading settings.el stops at its head, nothing changed.
  (should (equal (drgnx-settings-compat--run
                  '((list sat-width sat-own)
                    (drgnx-settings-test-check-row 'sat-width :value 70 :state 'standard
                                                   :source "default (package sat-pkg)"))
                  :settings '("(sat-own 2)" "(sat-width 100)")
                  :start '((progn (add-to-list 'load-path (expand-file-name "~/sat")) (require 'sat-pkg) t)
                           (progn (drgnx-defsetting sat-own 1 "Ours." :type 'integer :group 'sat) t)
                           (drgnx-settings-apply-global :owned-only t)))
                 '((70 2) t)))
  (should (equal (drgnx-settings-compat--run
                  '((condition-case e (progn (load (expand-file-name "settings.el" (getenv "DRGNX_CONFIG_DIR")) nil t t)
                                             'loaded)
                      (error e))
                    sat-width
                    (boundp 'sat-own))
                  :settings '("(sat-own 2)" "(sat-width 100)") :env '("DRGNX_SETTINGS_TEST_STOCK=1")
                  :start '((progn (add-to-list 'load-path (expand-file-name "~/sat")) (require 'sat-pkg) t)))
                 '((void-function drgnx-settings) 70 nil))))

(ert-deftest drgnx-settings-compat/c17-turn-off-and-on-keeps-a-later-setq ()
  ;; Every untouched variable back to its lower layer, config.el's setq kept (V2); then on, then off again; live.
  (should (equal (drgnx-settings-compat--run
                  '((drgnx-settings-turn-off-package-settings)
                    (list sat-width sat-height)
                    (progn (drgnx-settings-turn-on-package-settings) (list sat-width sat-height))
                    (progn (drgnx-settings-turn-off-package-settings) (list sat-width sat-height))
                    (drgnx-settings-test-check-row 'sat-height :value 80 :state 'changed :source "your Lisp (config.el:1)"))
                  :settings '("(sat-height 100)" "(sat-width 100)") :config "(setq sat-height 80)\n")
                 '(2 (70 80) (100 80) (70 80) t))))

(ert-deftest drgnx-settings-compat/c18-set-runs-once-per-change ()
  ;; Variables whose :set does work: :set runs once per change, never on a no-op.
  (should (equal (drgnx-settings-compat--run
                  '((progn (defvar sat-c0 sat-sets) (defvar sat-m0 sat-mode-runs) t)
                    (list sat-width sat-global-mode (default-value 'indent-tabs-mode))
                    (progn (drgnx-settings-apply-global) (list (- sat-sets sat-c0) (- sat-mode-runs sat-m0)))
                    (progn (with-temp-file (drgnx-config-file 'settings)
                             (insert "(drgnx-settings :version 1 (display-line-numbers-type relative) (indent-tabs-mode nil) (sat-global-mode t) (sat-width 60))\n"))
                           (drgnx-settings-apply-global)
                           (list (- sat-sets sat-c0) (- sat-mode-runs sat-m0) sat-width))
                    (progn (require 'display-line-numbers) display-line-numbers-type)
                    (drgnx-settings-test-check-row 'sat-global-mode :value t :state 'themed
                                                   :source "Settings (settings.el:1)"))
                  :settings '("(display-line-numbers-type relative)" "(indent-tabs-mode nil)" "(sat-global-mode t)"
                              "(sat-width 5)"))
                 '(t (5 t nil) (0 0) (1 0 60) relative t))))

(ert-deftest drgnx-settings-compat/c22-newcomers-presets ()
  ;; The newcomers-presets theme, enabled in config.el: stock order (it wins over drgnx's stored value).
  (let ((config "(load-theme 'newcomers-presets t)\n"))
    (should (equal (drgnx-settings-compat--run
                    '((drgnx-settings-test-check-row 'mouse-yank-at-point :value t :state 'themed
                                                     :source "theme newcomers-presets")
                      (mapcar #'car (get 'mouse-yank-at-point 'theme-value)))
                    :settings '("(mouse-yank-at-point nil)") :config config)
                   '(t (newcomers-presets drgnx))))
    (drgnx-settings-compat--stock-equal 'mouse-yank-at-point :config config)))

;;; settings-compat-global-test.el ends here
