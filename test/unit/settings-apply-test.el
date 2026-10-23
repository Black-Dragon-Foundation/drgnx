;;; settings-apply-test.el --- batch tests: theme drgnx, the winner rule, store in place, teardown -*- lexical-binding: t -*-
;; Each test declares its own variables (`drgnx-sat--…') and forgets them afterwards: unbound, their custom
;; properties gone, out of every theme's settings.  settings.el lives under `drgnx-test-with-config' (a temp
;; config and state dir).  `applying-adds-only-the-named-custom-loads' runs in two child Emacsen (test/settings-child.el).
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/config-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/settings-child" drgnx-dir) nil t)
(require 'drgnx-registry)
(require 'drgnx-settings-apply)

(defvar use-package-use-theme)                     ; use-package's, loaded by the tests that use it

(defconst drgnx-settings-apply-test--props
  '(standard-value theme-value saved-value customized-value custom-type custom-set custom-get force-value
                   custom-requests saved-variable-comment variable-comment customized-variable-comment
                   custom-check-value drgnx-setting custom-autoload custom-dependencies)
  "The symbol properties a test's variable may get; all cleared afterwards.")

(defun drgnx-settings-apply-test--forget (var)
  "Make VAR as if it had never been declared or set."
  (makunbound var)
  (dolist (p drgnx-settings-apply-test--props) (put var p nil))
  (dolist (theme custom-known-themes)
    (put theme 'theme-settings (cl-remove-if (lambda (s) (eq (cadr s) var)) (get theme 'theme-settings))))
  (setq drgnx-setting--names (delq var drgnx-setting--names))
  (remhash var drgnx-setting--cache))

(defmacro drgnx-settings-apply-test--with (vars &rest body)
  "BODY with VARS forgotten before and after, the applier's session state bound fresh, settings.el in a temp dir."
  (declare (indent 1))
  `(let ((drgnx-settings-apply--entries nil) (drgnx-settings-apply-problems nil)
         (drgnx-settings-apply-durations nil) (drgnx-settings-package-settings-off nil))
     (mapc #'drgnx-settings-apply-test--forget ',vars)
     (unwind-protect (drgnx-test-with-config ,@body)
       (mapc #'drgnx-settings-apply-test--forget ',vars))))

(defun drgnx-settings-apply-test--def (var &optional default &rest args)
  "Declare VAR as an integer `defcustom' with DEFAULT (70) and ARGS."
  (eval `(defcustom ,var ,(or default 70) "A test option." :type 'integer :group 'drgnx-settings-apply-test ,@args) t))

(defun drgnx-settings-apply-test--settings (&rest entries)
  "Make settings.el hold ENTRIES, each a string (an entry's text)."
  (drgnx-test-config-put 'settings (concat "(drgnx-settings\n :version 1\n " (string-join entries "\n ") ")\n")))

(defun drgnx-settings-apply-test--state (var)
  "VAR's `custom-variable-state'."
  (require 'cus-edit)
  (custom-variable-state var (symbol-value var)))

;;;; The winner rule

(ert-deftest drgnx-settings-apply/a-plain-setq-is-not-the-winner ()
  ;; V3: a setq over drgnx's value, no watcher: rule 2 says drgnx lost, and a new value is stored, not applied.
  (drgnx-settings-apply-test--with (drgnx-sat--a)
    (drgnx-settings-apply-test--def 'drgnx-sat--a)
    (should (drgnx-settings-winner-p 'drgnx-sat--a))
    (should (eq (drgnx-settings-push 'drgnx-sat--a 100) 'applied))
    (should (= drgnx-sat--a 100))
    (setq drgnx-sat--a 80)
    (should-not (drgnx-settings-winner-p 'drgnx-sat--a))
    (should (eq (drgnx-settings-push 'drgnx-sat--a 90) 'stored))
    (should (= drgnx-sat--a 80))))

(ert-deftest drgnx-settings-apply/a-session-set-is-not-the-winner ()
  ;; Customize's "Set for current session" (customize-set-variable) and M-x set-variable.
  (drgnx-settings-apply-test--with (drgnx-sat--a drgnx-sat--b)
    (dolist (v '(drgnx-sat--a drgnx-sat--b))
      (drgnx-settings-apply-test--def v)
      (should (eq (drgnx-settings-push v 100) 'applied)))
    (customize-set-variable 'drgnx-sat--a 80)
    (set-variable 'drgnx-sat--b 85)
    (should-not (drgnx-settings-winner-p 'drgnx-sat--a))
    (should-not (drgnx-settings-winner-p 'drgnx-sat--b))
    (should (eq (drgnx-settings-push 'drgnx-sat--a 120) 'stored))
    (should (eq (drgnx-settings-push 'drgnx-sat--b 120) 'stored))
    (should (equal (list drgnx-sat--a drgnx-sat--b) '(80 85)))))

(ert-deftest drgnx-settings-apply/a-setopt-is-not-the-winner ()
  (drgnx-settings-apply-test--with (drgnx-sat--a)
    (let ((sets 0))
      (drgnx-settings-apply-test--def 'drgnx-sat--a 70 :set (lambda (s v) (cl-incf sets) (set-default s v)))
      (should (eq (drgnx-settings-push 'drgnx-sat--a 100) 'applied))
      (eval '(setopt drgnx-sat--a 80) t)
      (should-not (drgnx-settings-winner-p 'drgnx-sat--a))
      (let ((before sets))
        (should (eq (drgnx-settings-push 'drgnx-sat--a 120) 'stored))
        (should (= sets before)))                     ; a stored value runs no :set
      (should (= drgnx-sat--a 80)))))

(ert-deftest drgnx-settings-apply/use-package-custom-wins ()
  ;; use-package :custom (theme use-package) after drgnx's push: use-package's value, drgnx's stored behind it.
  (require 'use-package)
  (drgnx-settings-apply-test--with (drgnx-sat--a)
    (drgnx-settings-apply-test--def 'drgnx-sat--a)
    (should (eq (drgnx-settings-push 'drgnx-sat--a 100) 'applied))
    (let ((use-package-use-theme t)) (eval '(use-package emacs :custom (drgnx-sat--a 7)) t))
    (should (= drgnx-sat--a 7))
    (should-not (drgnx-settings-winner-p 'drgnx-sat--a))
    (should (eq (drgnx-settings-push 'drgnx-sat--a 120) 'stored))
    (should (= drgnx-sat--a 7))
    (should (eq (caar (get 'drgnx-sat--a 'theme-value)) 'use-package))))

(ert-deftest drgnx-settings-apply/custom-el-wins-saved-not-pushed ()
  (drgnx-settings-apply-test--with (drgnx-sat--a)
    (drgnx-settings-apply-test--def 'drgnx-sat--a)
    (should (eq (drgnx-settings-push 'drgnx-sat--a 100) 'applied))
    (custom-set-variables '(drgnx-sat--a 5))
    (should (= drgnx-sat--a 5))
    (should (eq (drgnx-settings-apply-test--state 'drgnx-sat--a) 'saved))
    (should (eq (drgnx-settings-push 'drgnx-sat--a 120) 'stored))
    (should (= drgnx-sat--a 5))
    (should (eq (drgnx-settings-apply-test--state 'drgnx-sat--a) 'saved))
    (should (equal (get 'drgnx-sat--a 'theme-value) '((user 5) (drgnx 120))))))

;;;; Store in place

(ert-deftest drgnx-settings-apply/a-losing-store-keeps-the-effective-value ()
  ;; V3: storing 100 under a setq of 80 gives ((changed 80) (drgnx 100)), state changed, value 80.
  (drgnx-settings-apply-test--with (drgnx-sat--a)
    (drgnx-settings-apply-test--def 'drgnx-sat--a)
    (should (eq (drgnx-settings-push 'drgnx-sat--a 90) 'applied))
    (setq drgnx-sat--a 80)
    (should (eq (drgnx-settings-push 'drgnx-sat--a 100) 'stored))
    (should (equal (get 'drgnx-sat--a 'theme-value) '((changed 80) (drgnx 100))))
    (should (eq (drgnx-settings-apply-test--state 'drgnx-sat--a) 'changed))
    (should (= drgnx-sat--a 80))
    (should (equal (cl-remove-if-not (lambda (s) (eq (cadr s) 'drgnx-sat--a)) (get 'drgnx 'theme-settings))
                   '((theme-value drgnx-sat--a drgnx 100))))))

(ert-deftest drgnx-settings-apply/disable-use-package-gives-drgnxs-current-value ()
  ;; V4: drgnx's value stored under use-package's; when use-package's theme goes, Emacs recalculates to drgnx's
  ;; current value, not the one it pushed first.
  (require 'use-package)
  (drgnx-settings-apply-test--with (drgnx-sat--a)
    (drgnx-settings-apply-test--def 'drgnx-sat--a)
    (should (eq (drgnx-settings-push 'drgnx-sat--a 100) 'applied))
    (let ((use-package-use-theme t)) (eval '(use-package emacs :custom (drgnx-sat--a 7)) t))
    (should (eq (drgnx-settings-push 'drgnx-sat--a 150) 'stored))
    (unwind-protect
        (progn (enable-theme 'use-package)          ; as a user who lists it in custom-enabled-themes
               (should (= drgnx-sat--a 7))
               (disable-theme 'use-package)
               (should (= drgnx-sat--a 150)))
      (setq custom-enabled-themes (remq 'use-package custom-enabled-themes)))))

;;;; Teardown

(ert-deftest drgnx-settings-apply/teardown-keeps-a-later-setq ()
  ;; V2: a setq of 80 made after drgnx's push survives the teardown.
  (drgnx-settings-apply-test--with (drgnx-sat--a)
    (drgnx-settings-apply-test--def 'drgnx-sat--a)
    (drgnx-settings-push 'drgnx-sat--a 100)
    (setq drgnx-sat--a 80)
    (should (drgnx-settings-teardown 'drgnx-sat--a))
    (should (= drgnx-sat--a 80))
    (should-not (assq 'drgnx (get 'drgnx-sat--a 'theme-value)))))

(ert-deftest drgnx-settings-apply/teardown-restores-an-untouched-variable ()
  (drgnx-settings-apply-test--with (drgnx-sat--a)
    (drgnx-settings-apply-test--def 'drgnx-sat--a)
    (drgnx-settings-push 'drgnx-sat--a 100)
    (should (drgnx-settings-teardown 'drgnx-sat--a))
    (should (= drgnx-sat--a 70))
    (should-not (get 'drgnx-sat--a 'theme-value))
    (should-not (get 'drgnx-sat--a 'saved-value))
    (should-not (drgnx-settings-teardown 'drgnx-sat--a))))   ; nothing of drgnx's left: nothing to do

(ert-deftest drgnx-settings-apply/never-disable-theme-drgnx ()
  (drgnx-settings-apply-test--with (drgnx-sat--a drgnx-sat--b)
    (let* ((disabled 0)
           (count (lambda (theme) (when (eq theme 'drgnx) (cl-incf disabled)))))
      (advice-add 'disable-theme :before count)
      (unwind-protect
          (progn
            (drgnx-settings-apply-test--def 'drgnx-sat--a)
            (drgnx-settings-apply-test--def 'drgnx-sat--b)
            (drgnx-settings-apply-test--settings "(drgnx-sat--a 100)" "(drgnx-sat--b 100)")
            (drgnx-settings-apply-global)
            (drgnx-settings-teardown 'drgnx-sat--a)
            (drgnx-settings-turn-off-package-settings)
            (drgnx-settings-turn-on-package-settings)
            (should (= drgnx-sat--b 100))
            (should-not (memq 'drgnx custom-enabled-themes))
            (should (custom-theme-p 'drgnx))
            (should (= disabled 0)))
        (advice-remove 'disable-theme count)))))

;;;; Applying settings.el

(ert-deftest drgnx-settings-apply/a-broken-file-falls-back-per-setting ()
  ;; settings.el stops reading: a strict setting gets its default, another its last good copy's value.
  (drgnx-settings-apply-test--with (drgnx-sat--strict drgnx-sat--a)
    (eval '(drgnx-defsetting drgnx-sat--strict 1 "A strict one." :type 'integer :group 'drgnx-settings-apply-test
             :on-error 'strict)
          t)
    (drgnx-settings-apply-test--def 'drgnx-sat--a)
    (drgnx-settings-apply-test--settings "(drgnx-sat--a 100)" "(drgnx-sat--strict 5)")
    (should (equal (drgnx-settings-apply-global) '((drgnx-sat--a . applied) (drgnx-sat--strict . applied))))
    (should (equal (list drgnx-sat--a drgnx-sat--strict) '(100 5)))
    (drgnx-settings-teardown 'drgnx-sat--a)           ; so that 100 can only come back from the last good copy
    (drgnx-test-config-put 'settings "(drgnx-settings\n :version 1\n (drgnx-sat--a 200)\n (drgnx-sat--strict 6\n")
    (should (equal (drgnx-settings-apply-global) '((drgnx-sat--a . applied) (drgnx-sat--strict . default))))
    (should (equal (list drgnx-sat--a drgnx-sat--strict) '(100 1)))))

(ert-deftest drgnx-settings-apply/a-bad-entry-falls-back-alone ()
  (drgnx-settings-apply-test--with (drgnx-sat--a drgnx-sat--b drgnx-sat--strict)
    (eval '(drgnx-defsetting drgnx-sat--strict 1 "A strict one." :type 'integer :group 'drgnx-settings-apply-test
             :on-error 'strict)
          t)
    (drgnx-settings-apply-test--def 'drgnx-sat--a)
    (drgnx-settings-apply-test--def 'drgnx-sat--b)
    (drgnx-settings-apply-test--settings "(drgnx-sat--a 50)" "(drgnx-sat--b 1)" "(drgnx-sat--strict 5)")
    (drgnx-settings-apply-global)
    (drgnx-settings-apply-test--settings "(drgnx-sat--a \"wide\")" "(drgnx-sat--b 2)" "(drgnx-sat--strict \"x\")")
    (let ((r (drgnx-settings-apply-global)))
      (should (eq (alist-get 'drgnx-sat--a r) 'applied))    ; its last good value
      (should (eq (alist-get 'drgnx-sat--b r) 'applied))
      (should (eq (alist-get 'drgnx-sat--strict r) 'default)))
    (should (equal (list drgnx-sat--a drgnx-sat--b drgnx-sat--strict) '(50 2 1)))
    (should (equal (mapcar (lambda (p) (list (plist-get p :var) (plist-get p :line))) drgnx-settings-apply-problems)
                   '((drgnx-sat--a 3) (drgnx-sat--strict 5))))))

(ert-deftest drgnx-settings-apply/a-dormant-entry-applies-when-its-package-loads ()
  ;; P7: set in the theme before its package loads, the value applies at the defcustom and :set runs; nothing loaded.
  (drgnx-settings-apply-test--with (drgnx-sat--later)
    (drgnx-settings-apply-test--settings)
    (drgnx-settings-apply-global)                    ; the applier's own libraries, loaded before the count
    (let ((sets 0) (features-before features))
      (drgnx-settings-apply-test--settings "(drgnx-sat--later 5)")
      (should (equal (drgnx-settings-apply-global) '((drgnx-sat--later . applied))))
      (should-not (boundp 'drgnx-sat--later))
      (should (equal (mapcar #'drgnx-settings-entry-var (drgnx-settings-dormant)) '(drgnx-sat--later)))
      (should (equal features features-before))
      (drgnx-settings-apply-test--def 'drgnx-sat--later 1 :set (lambda (s v) (cl-incf sets) (set-default s v)))
      (should (= drgnx-sat--later 5))
      (should (= sets 1))
      (should-not (drgnx-settings-dormant)))))

(ert-deftest drgnx-settings-apply/applying-adds-only-the-named-custom-loads ()
  ;; 200 entries: 100 options already defined, 99 for packages not loaded, and one autoloaded minor-mode variable
  ;; (display-time-mode).  Applying them loads what that variable's custom loads load, and nothing else: the same
  ;; features as `custom-load-symbol' of that one variable in another child.  Both children first apply a one-entry
  ;; settings.el, so the applier's own libraries are loaded before the count.
  (let* ((warm '((progn (eval '(defcustom sat-warm 0 "" :type 'integer :group 'sat) t)
                        (with-temp-file (drgnx-config-file 'settings)
                          (insert "(drgnx-settings :version 1 (sat-warm 1))\n"))
                        (drgnx-settings-apply-global)
                        t)
                 (setq drgnx-sat--before (copy-sequence features))))
         (text (concat "(drgnx-settings\n :version 1\n (display-time-mode nil)\n"
                       (mapconcat (lambda (i) (format " (sat-v%d %d)\n" i i)) (number-sequence 0 99) "")
                       (mapconcat (lambda (i) (format " (sat-missing-%d %d)\n" i i)) (number-sequence 1 99) "")
                       ")\n"))
         (diff '(sort (mapcar #'symbol-name (cl-set-difference features drgnx-sat--before)) #'string<))
         (defs '(dotimes (i 100)
                  (eval (list 'defcustom (intern (format "sat-v%d" i)) 0 "" :type ''integer :group ''sat) t)))
         (a (drgnx-settings-test-child
             `((defvar drgnx-sat--before nil)
               ,defs
               ,@warm
               (progn (with-temp-file (drgnx-config-file 'settings) (insert ,text)) t)
               (length (drgnx-settings-apply-global))
               (featurep 'time)
               ,diff)))
         (b (drgnx-settings-test-child
             `((defvar drgnx-sat--before nil)
               ,@warm
               (progn (custom-load-symbol 'display-time-mode) t)
               ,diff))))
    (should-not (plist-get a :error))
    (should-not (plist-get b :error))
    (let ((va (plist-get a :values)) (vb (plist-get b :values)))
      (should (equal (nth 5 va) 200))
      (should (eq (nth 6 va) t))
      (should (member "time" (nth 7 va)))
      (should (equal (nth 7 va) (nth 4 vb))))))

(ert-deftest drgnx-settings-apply/owned-only-skips-package-entries ()
  (drgnx-settings-apply-test--with (drgnx-sat--own drgnx-sat--a)
    ;; :scope given: `drgnx-setting-own-p' is nil for a declaration with no drgnx key (Task 7's, reported)
    (eval '(drgnx-defsetting drgnx-sat--own 1 "Ours." :type 'integer :group 'drgnx-settings-apply-test
             :scope 'global)
          t)
    (drgnx-settings-apply-test--def 'drgnx-sat--a)
    (drgnx-settings-apply-test--settings "(drgnx-sat--a 100)" "(drgnx-sat--own 2)")
    (should (equal (drgnx-settings-apply-global :owned-only t) '((drgnx-sat--own . applied))))
    (should (equal (list drgnx-sat--a drgnx-sat--own) '(70 2)))
    (should-not (get 'drgnx-sat--a 'theme-value))
    ;; DRGNX_PACKAGE_SETTINGS=off (drgnx bisect's step) is the same
    (let ((process-environment (cons "DRGNX_PACKAGE_SETTINGS=off" process-environment)))
      (should (equal (drgnx-settings-apply-global) '((drgnx-sat--own . applied)))))
    (should (= drgnx-sat--a 70))))

(ert-deftest drgnx-settings-apply/turn-off-and-on-is-live ()
  ;; V2 through the commands: an untouched variable goes back to its default, a later setq stays, drgnx's own stays;
  ;; turning on applies again where drgnx is the winner, and stores behind the setq.
  (drgnx-settings-apply-test--with (drgnx-sat--a drgnx-sat--b drgnx-sat--own)
    ;; :scope given: `drgnx-setting-own-p' is nil for a declaration with no drgnx key (Task 7's, reported)
    (eval '(drgnx-defsetting drgnx-sat--own 1 "Ours." :type 'integer :group 'drgnx-settings-apply-test
             :scope 'global)
          t)
    (drgnx-settings-apply-test--def 'drgnx-sat--a)
    (drgnx-settings-apply-test--def 'drgnx-sat--b)
    (drgnx-settings-apply-test--settings "(drgnx-sat--a 100)" "(drgnx-sat--b 100)" "(drgnx-sat--own 2)")
    (drgnx-settings-apply-global)
    (setq drgnx-sat--b 80)
    (should (= (drgnx-settings-turn-off-package-settings) 2))
    (should (equal (list drgnx-sat--a drgnx-sat--b drgnx-sat--own) '(70 80 2)))
    (should (equal (drgnx-settings-apply-global) '((drgnx-sat--own . applied))))   ; off holds until turned on
    (should (equal (list drgnx-sat--a drgnx-sat--b) '(70 80)))
    (let ((r (drgnx-settings-turn-on-package-settings)))
      (should (eq (alist-get 'drgnx-sat--a r) 'applied))
      (should (eq (alist-get 'drgnx-sat--b r) 'stored)))
    (should (equal (list drgnx-sat--a drgnx-sat--b drgnx-sat--own) '(100 80 2))))
  ;; both are registry commands
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
    (drgnx-config-register-commands)
    (dolist (c '((settings-package-off "Turn Off Package Settings" drgnx-settings-turn-off-package-settings)
                 (settings-package-on "Turn On Package Settings" drgnx-settings-turn-on-package-settings)))
      (let ((cmd (drgnx-commands-get (car c))))
        (should (equal (list (drgnx-cmd-category cmd) (drgnx-cmd-title cmd) (drgnx-cmd-command cmd))
                       (list "Settings" (nth 1 c) (nth 2 c))))
        (should (commandp (nth 2 c)))))))

;;; settings-apply-test.el ends here
