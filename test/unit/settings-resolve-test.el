;;; settings-resolve-test.el --- batch tests: module claims resolved with settings.el -*- lexical-binding: t -*-
;; Unified-settings Task 9.  Each test declares its own options (`drgnx-srt--…') and forgets them afterwards; the
;; claims, the module stacks and the applier's session state are bound fresh, settings.el lives under
;; `drgnx-test-with-config'.  A module's setup is `drgnx-settings-resolve-test--as' (or the recorder, for the
;; `add-to-list' door); its teardown runs its undos (`drgnx-settings-resolve-test--down').
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/config-fixture" drgnx-dir) nil t)
(require 'drgnx-registry)
(require 'drgnx-modules)
(require 'drgnx-settings-resolve)


(defconst drgnx-settings-resolve-test--props
  '(standard-value theme-value saved-value customized-value custom-type custom-set custom-get force-value
                   custom-requests saved-variable-comment variable-comment customized-variable-comment
                   custom-check-value drgnx-setting custom-autoload custom-dependencies)
  "The symbol properties a test's variable may get; all cleared afterwards.")

(defun drgnx-settings-resolve-test--forget (var)
  "Make VAR as if it had never been declared or set."
  (makunbound var)
  (dolist (p drgnx-settings-resolve-test--props) (put var p nil))
  (dolist (theme custom-known-themes)
    (put theme 'theme-settings (cl-remove-if (lambda (s) (eq (cadr s) var)) (get theme 'theme-settings)))))

(defmacro drgnx-settings-resolve-test--with (vars &rest body)
  "BODY with VARS forgotten before and after, fresh claims, module stacks and applier state, settings.el in a temp
dir."
  (declare (indent 1))
  `(let ((drgnx-settings-apply--entries nil) (drgnx-settings-apply-problems nil)
         (drgnx-settings-apply-durations nil) (drgnx-settings-package-settings-off nil)
         (drgnx-settings--claims (make-hash-table :test 'eq))
         (drgnx-settings-resolve--before (make-hash-table :test 'eq))
         (drgnx-settings-resolve--last (make-hash-table :test 'eq))
         (drgnx-modules--setup-load load-file-name)
         (drgnx-modules--stacks nil)
         (drgnx-module--claims (make-hash-table :test 'equal))
         (drgnx-module--releasers (make-hash-table :test 'equal)))
     (mapc #'drgnx-settings-resolve-test--forget ',vars)
     (unwind-protect (drgnx-test-with-config ,@body)
       (mapc #'drgnx-settings-resolve-test--forget ',vars))))

(defmacro drgnx-settings-resolve-test--as (module &rest body)
  "BODY as the code of MODULE's running setup."
  (declare (indent 1))
  `(let ((drgnx-modules--current ,module)) ,@body))

(defun drgnx-settings-resolve-test--down (module)
  "Tear MODULE down: run its undos now; the problems must be nil."
  (should-not (drgnx-modules--unwind module)))

(defun drgnx-settings-resolve-test--def (var default)
  "Declare VAR as a `defcustom' with DEFAULT."
  (eval `(defcustom ,var ',default "A test option." :type 'sexp :group 'drgnx-settings-resolve-test) t))

(defun drgnx-settings-resolve-test--settings (&rest entries)
  "Make settings.el hold ENTRIES, each a string (an entry's text)."
  (drgnx-test-config-put 'settings (concat "(drgnx-settings\n :version 1\n " (string-join entries "\n ") ")\n")))

(defun drgnx-settings-resolve-test--state (var)
  "VAR's `custom-variable-state'."
  (require 'cus-edit)
  (custom-variable-state var (symbol-value var)))

(ert-deftest drgnx-settings-resolve/module-set-no-longer-overrides-customize ()
  (drgnx-settings-resolve-test--with (drgnx-srt--a drgnx-srt--b drgnx-srt--late)
    ;; Customize saved a value: the module's is stored behind it, and its undo leaves Customize's.
    (drgnx-settings-resolve-test--def 'drgnx-srt--a 70)
    (custom-set-variables '(drgnx-srt--a 5))
    (drgnx-settings-resolve-test--as 'test/m (drgnx-module-set 'drgnx-srt--a 9))
    (should (= drgnx-srt--a 5))
    (should (eq (drgnx-settings-resolve-test--state 'drgnx-srt--a) 'saved))
    (should (equal (get 'drgnx-srt--a 'theme-value) '((user 5) (drgnx 9))))
    (should (equal (drgnx-settings-resolve 'drgnx-srt--a) '(9)))
    ;; a package not loaded yet: Customize's value reaches its defcustom, not the module's
    (custom-set-variables '(drgnx-srt--late 6))
    (drgnx-settings-resolve-test--as 'test/m (drgnx-module-set 'drgnx-srt--late 9))
    (should-not (boundp 'drgnx-srt--late))
    (drgnx-settings-resolve-test--def 'drgnx-srt--late 70)
    (should (= drgnx-srt--late 6))
    ;; nobody else set it: the module's value applies, through theme drgnx
    (drgnx-settings-resolve-test--def 'drgnx-srt--b 70)
    (drgnx-settings-resolve-test--as 'test/m (drgnx-module-set 'drgnx-srt--b 9))
    (should (= drgnx-srt--b 9))
    (should (eq (drgnx-settings-resolve-test--state 'drgnx-srt--b) 'themed))
    (drgnx-settings-resolve-test--down 'test/m)
    (should (equal (list drgnx-srt--a drgnx-srt--late drgnx-srt--b) '(5 6 70)))
    (should (equal (get 'drgnx-srt--a 'theme-value) '((user 5))))
    (should-not (get 'drgnx-srt--b 'theme-value))
    (should (zerop (hash-table-count drgnx-settings--claims)))))

(ert-deftest drgnx-settings-resolve/replace-lists-what-it-replaced ()
  (drgnx-settings-resolve-test--with (drgnx-srt--al drgnx-srt--al2)
    (drgnx-settings-resolve-test--def 'drgnx-srt--al '((std . 0)))
    (drgnx-settings-resolve-test--settings "(drgnx-srt--al ((a . 1)))")
    (drgnx-settings-apply-global)
    (drgnx-settings-resolve-test--as 'test/m (drgnx-module-alist-put 'drgnx-srt--al 'm 2))
    (should (equal drgnx-srt--al '((a . 1))))
    (should (equal (drgnx-settings-resolve 'drgnx-srt--al) '(((a . 1)) (test/m (m . 2)))))
    ;; an entry that arrives after the module (a live change) replaces its key too
    (drgnx-settings-resolve-test--def 'drgnx-srt--al2 '((std . 0)))
    (drgnx-settings-resolve-test--as 'test/m (drgnx-module-alist-put 'drgnx-srt--al2 'm 2))
    (should (equal drgnx-srt--al2 '((m . 2) (std . 0))))
    (drgnx-settings-resolve-test--settings "(drgnx-srt--al ((a . 1)))" "(drgnx-srt--al2 ((b . 1)))")
    (should (eq (alist-get 'drgnx-srt--al2 (drgnx-settings-apply-global)) 'applied))
    (should (equal drgnx-srt--al2 '((b . 1))))
    (should (equal (cdr (drgnx-settings-resolve 'drgnx-srt--al2)) '((test/m (m . 2)))))
    (drgnx-settings-resolve-test--down 'test/m)
    (should (equal (list drgnx-srt--al drgnx-srt--al2) '(((a . 1)) ((b . 1)))))
    (should-not (cdr (drgnx-settings-resolve 'drgnx-srt--al)))))

(ert-deftest drgnx-settings-resolve/alist-keeps-other-module-keys ()
  (drgnx-settings-resolve-test--with (drgnx-srt--al)
    (drgnx-settings-resolve-test--def 'drgnx-srt--al '((std . 0)))
    (drgnx-settings-resolve-test--settings "(drgnx-srt--al ((a . 1)) :merge alist)")
    (drgnx-settings-apply-global)
    (drgnx-settings-resolve-test--as 'test/m
      (drgnx-module-alist-put 'drgnx-srt--al 'm 2)
      (drgnx-module-alist-put 'drgnx-srt--al 'a 9))         ; settings.el's key wins
    (drgnx-settings-resolve-test--as 'test/n (drgnx-module-alist-put 'drgnx-srt--al 'n 3))
    (should (equal drgnx-srt--al '((a . 1) (m . 2) (n . 3))))
    (should-not (cdr (drgnx-settings-resolve 'drgnx-srt--al)))
    (drgnx-settings-resolve-test--down 'test/m)
    (should (equal drgnx-srt--al '((a . 1) (n . 3))))
    (drgnx-settings-resolve-test--down 'test/n)
    (should (equal drgnx-srt--al '((a . 1))))))

(ert-deftest drgnx-settings-resolve/append-keeps-module-elements ()
  ;; The `add-to-list' door: the element is the module's claim, merged with settings.el's elements after it.
  (drgnx-settings-resolve-test--with (drgnx-srt--l)
    (drgnx-settings-resolve-test--def 'drgnx-srt--l '(x))
    (drgnx-settings-resolve-test--settings "(drgnx-srt--l (y) :merge append)")
    (drgnx-settings-apply-global)
    (should (equal drgnx-srt--l '(y)))
    ;; evaluated: compiled, `add-to-list''s compiler macro would make it a plain `push' the door never sees
    (drgnx-modules--record-call 'test/m (lambda () (eval '(add-to-list 'drgnx-srt--l 'm) t)))
    (should (equal drgnx-srt--l '(m y)))
    (should (equal (drgnx-settings-claims 'drgnx-srt--l) '((test/m element m))))
    (drgnx-settings-resolve-test--down 'test/m)
    (should (equal drgnx-srt--l '(y)))
    (should-not (drgnx-settings-claims 'drgnx-srt--l))))

(ert-deftest drgnx-settings-resolve/an-undo-removes-only-its-key ()
  (drgnx-settings-resolve-test--with (drgnx-srt--al drgnx-srt--al2)
    ;; no settings.el entry: the keys go in directly, and a key your Lisp changed since stays
    (drgnx-settings-resolve-test--def 'drgnx-srt--al '((std . 0)))
    (drgnx-settings-resolve-test--as 'test/m
      (drgnx-module-alist-put 'drgnx-srt--al 'k 1)
      (drgnx-module-alist-put 'drgnx-srt--al 'j 2))
    (should (equal drgnx-srt--al '((j . 2) (k . 1) (std . 0))))
    (setq drgnx-srt--al (cons '(k . 7) (assq-delete-all 'k (copy-sequence drgnx-srt--al))))
    (drgnx-settings-resolve-test--down 'test/m)
    (should (equal drgnx-srt--al '((k . 7) (std . 0))))
    ;; resolved with an `alist' entry: the undo takes only the module's key away
    (drgnx-settings-resolve-test--def 'drgnx-srt--al2 '((std . 0)))
    (drgnx-settings-resolve-test--settings "(drgnx-srt--al2 ((a . 1)) :merge alist)")
    (drgnx-settings-apply-global)
    (drgnx-settings-resolve-test--as 'test/m (drgnx-module-alist-put 'drgnx-srt--al2 'm 2))
    (should (equal drgnx-srt--al2 '((a . 1) (m . 2))))
    (drgnx-settings-resolve-test--down 'test/m)
    (should (equal drgnx-srt--al2 '((a . 1))))))

(ert-deftest drgnx-settings-resolve/keep-module-entries-writes-merge-alist ()
  (drgnx-settings-resolve-test--with (drgnx-srt--al)
    (drgnx-settings-resolve-test--def 'drgnx-srt--al '((std . 0)))
    (drgnx-settings-resolve-test--settings "(drgnx-srt--al ((a . 1)))")
    (drgnx-settings-apply-global)
    (drgnx-settings-resolve-test--as 'test/m (drgnx-module-alist-put 'drgnx-srt--al 'm 2))
    (should (equal (drgnx-settings-resolve--replacing) '(drgnx-srt--al)))
    (should (eq (drgnx-settings-keep-module-entries 'drgnx-srt--al) 'applied))
    (should (equal drgnx-srt--al '((a . 1) (m . 2))))           ; at once
    (should (string-match-p (regexp-quote "(drgnx-srt--al ((a . 1)) :merge alist)")
                            (with-temp-buffer (insert-file-contents (drgnx-config-file 'settings)) (buffer-string))))
    (should-not (drgnx-settings-resolve--replacing))
    (drgnx-settings-resolve-test--down 'test/m)
    (should (equal drgnx-srt--al '((a . 1)))))
  ;; a registry command
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
    (drgnx-config-register-commands)
    (let ((cmd (drgnx-commands-get 'settings-keep-module-entries)))
      (should (equal (list (drgnx-cmd-category cmd) (drgnx-cmd-title cmd) (drgnx-cmd-command cmd))
                     '("Settings" "Keep Module Entries…" drgnx-settings-keep-module-entries)))
      (should (commandp 'drgnx-settings-keep-module-entries)))))

(ert-deftest drgnx-settings-resolve/lower-only-takes-the-lower ()
  (drgnx-settings-resolve-test--with (drgnx-srt--n)
    (drgnx-settings-resolve-test--def 'drgnx-srt--n 100)
    (drgnx-settings-resolve-test--settings "(drgnx-srt--n 50 :merge lower-only)")
    (drgnx-settings-apply-global)
    (drgnx-settings-resolve-test--as 'test/m (drgnx-module-set 'drgnx-srt--n 80))
    (should (= drgnx-srt--n 50))
    (drgnx-settings-resolve-test--settings "(drgnx-srt--n 90 :merge lower-only)")
    (drgnx-settings-apply-global)
    (should (= drgnx-srt--n 80))
    (drgnx-settings-resolve-test--down 'test/m)
    (should (= drgnx-srt--n 90))))

;;; settings-resolve-test.el ends here
