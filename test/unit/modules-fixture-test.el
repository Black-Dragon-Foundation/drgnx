;;; modules-fixture-test.el --- batch tests: drgnx-test-with-modules sets modules up and tears them down -*- lexical-binding: t -*-
(require 'ert)
(require 'ert-x)
(require 'drgnx)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)

(defvar drgnx-keys--applied)
(defvar drgnx-layouts-pane-fillers)
(defvar drgnx-layouts-shapes)
(defvar drgnx-persist-state-functions)
(defvar drgnx-persist-after-restore-functions)
(defvar drgnx-fixture-test-late-registry)
(defvar drgnx-fixture-test-table nil "A hash-table registry for the in-place test.")
(defvar drgnx-fixture-test-alist nil "An alist registry for the in-place test.")
(defvar drgnx-fixture-test-map nil "A keymap registry for the in-place test.")
(defvar drgnx-fixture-test-log nil "What the fake modules' teardowns did, newest first.")

(defun drgnx-fixture-test--module-file (dir name contents)
  "Write the file NAME.el under DIR holding CONTENTS; return its path."
  (let ((file (expand-file-name (concat name ".el") dir)))
    (with-temp-file file (insert ";;; " name ".el --- a fake module -*- lexical-binding: t -*-\n" contents))
    file))

(ert-deftest drgnx-test-modules/a-module-set-up-and-gone ()
  ;; tools/browser registers a pane filler and a layout shape; the layouts module wires the persist hooks.
  (drgnx-test-with-modules '(tools/browser) nil)   ; loads the libraries, so the values below are their own
  (let ((state-fns (copy-sequence (bound-and-true-p drgnx-persist-state-functions)))
        (after-fns (copy-sequence (bound-and-true-p drgnx-persist-after-restore-functions)))
        (fillers (copy-tree (bound-and-true-p drgnx-layouts-pane-fillers)))
        (shapes (copy-tree (bound-and-true-p drgnx-layouts-shapes))))
    (drgnx-test-with-modules '(tools/browser) :strict t
                             (should (assq 'browser drgnx-layouts-pane-fillers))
                             (should (assq 'editor+browser drgnx-layouts-shapes))
                             (should (memq 'drgnx-layouts--persist-state drgnx-persist-state-functions))
                             (should (eq 'ok (plist-get (alist-get 'tools/browser (drgnx-modules-report)) :status))))
    (should (equal fillers (bound-and-true-p drgnx-layouts-pane-fillers)))
    (should (equal shapes (bound-and-true-p drgnx-layouts-shapes)))
    (should (equal state-fns drgnx-persist-state-functions))
    (should (equal after-fns drgnx-persist-after-restore-functions))))

(ert-deftest drgnx-test-modules/strict-fails-on-a-leak ()
  ;; A setup that reaches a hook outside every door (the safety net sees `add-hook', not `push').
  (ert-with-temp-directory dir
                           (let ((file (drgnx-fixture-test--module-file
                                        dir "fake-leak"
                                        "(defun drgnx-fixture-test-leaky () nil)
(drgnx-module-define 'fake/leak :doc \"leaks\"
  :setup (lambda () (push #'drgnx-fixture-test-leaky (default-value 'find-file-hook))))")))
                             (unwind-protect
                                 (let ((err (should-error (drgnx-test-with-modules (list file) :strict t (ignore))
                                                          :type 'ert-test-failed)))
                                   (should (string-match-p "hook find-file-hook \\+drgnx-fixture-test-leaky" (format "%S" (cdr err)))))
                               (remove-hook 'find-file-hook #'drgnx-fixture-test-leaky))
                             ;; not strict: the same leak passes
                             (unwind-protect
                                 (drgnx-test-with-modules (list file) (ignore))
                               (remove-hook 'find-file-hook #'drgnx-fixture-test-leaky)))))

(ert-deftest drgnx-test-modules/strict-passes-when-nothing-is-left ()
  (ert-with-temp-directory dir
                           (let ((file (drgnx-fixture-test--module-file
                                        dir "fake-clean"
                                        "(defun drgnx-fixture-test-clean () nil)
(drgnx-module-define 'fake/clean :doc \"clean\"
  :setup (lambda () (add-hook 'find-file-hook #'drgnx-fixture-test-clean)))")))
                             (should (eq 'done (drgnx-test-with-modules (list file) :strict t
                                                                        (should (memq 'drgnx-fixture-test-clean (default-value 'find-file-hook)))
                                                                        'done)))
                             (should-not (memq 'drgnx-fixture-test-clean (default-value 'find-file-hook))))))

(ert-deftest drgnx-test-modules/strict-blames-no-library-top-level ()
  ;; A library the setup loads first registers at its top level (spec row 26: the library's, it stays loaded) and
  ;; an edit starts Emacs's undo timer: strict loads the library before its snapshot and leaves Emacs's own timers
  ;; alone, so the module passes in any order.  What the setup itself does still counts.
  (ert-with-temp-directory dir
                           (let ((load-path (cons dir load-path))
                                 (lib-fns '(drgnx-fixture-test-lib-fn drgnx-fixture-test-lib-fn-2)))
                             (drgnx-fixture-test--module-file dir "drgnx-fixture-test-lib" "(defun drgnx-fixture-test-lib-fn () nil)
(defun drgnx-fixture-test-lib-fn-2 () nil)
(add-hook 'find-file-hook #'drgnx-fixture-test-lib-fn)
(let ((b (get-buffer-create \"drgnx-fixture-test-undo\")))
  (with-current-buffer b (buffer-enable-undo) (insert \"x\"))
  (kill-buffer b))
(provide 'drgnx-fixture-test-lib)")
                             (unwind-protect
                                 (let ((uses (drgnx-fixture-test--module-file dir "fake-uses-lib" "(drgnx-module-define 'fake/uses-lib :doc \"loads a library\"
  :packages '(drgnx-fixture-test-lib)
  :setup (lambda () (require 'drgnx-fixture-test-lib)))"))
                                       (leaks (drgnx-fixture-test--module-file dir "fake-lib-leak" "(drgnx-module-define 'fake/lib-leak :doc \"leaks a library's function\"
  :packages '(drgnx-fixture-test-lib)
  :setup (lambda () (require 'drgnx-fixture-test-lib)
           (push #'drgnx-fixture-test-lib-fn-2 (default-value 'find-file-hook))))")))
                                   (should (eq 'done (drgnx-test-with-modules (list uses) :strict t 'done)))
                                   (should (featurep 'drgnx-fixture-test-lib))
                                   (let ((err (should-error (drgnx-test-with-modules (list leaks) :strict t (ignore)) :type 'ert-test-failed)))
                                     (should (string-match-p "hook find-file-hook \\+drgnx-fixture-test-lib-fn-2" (format "%S" (cdr err))))
                                     (should-not (string-match-p "drgnx-fixture-test-lib-fn[^-]" (format "%S" (cdr err))))))
                               (dolist (f lib-fns) (remove-hook 'find-file-hook f))
                               (setq features (delq 'drgnx-fixture-test-lib features))))))

(ert-deftest drgnx-test-modules/packages-hidden ()
  ;; A third-party feature that is loaded counts as installed, until the helper hides it.
  (ert-with-temp-directory dir
                           (let* ((load-path (cons dir load-path))
                                  (features features)
                                  (file (drgnx-fixture-test--module-file
                                         dir "fake-needs"
                                         "(drgnx-module-define 'fake/needs :doc \"needs a package\" :packages '(drgnx-fixture-test-pkg)
  :setup #'ignore)")))
                             (drgnx-fixture-test--module-file dir "drgnx-fixture-test-pkg" "(provide 'drgnx-fixture-test-pkg)")
                             (require 'drgnx-fixture-test-pkg)
                             (should (featurep 'drgnx-fixture-test-pkg))
                             (should (eq 'ok (drgnx-test-with-modules (list file)
                                               (plist-get (alist-get 'fake/needs (drgnx-modules-report)) :status))))
                             (should (eq 'missing-packages
                                         (drgnx-test-with-modules (list file) :packages hidden
                                                                  (should-not (featurep 'drgnx-fixture-test-pkg))
                                                                  (plist-get (alist-get 'fake/needs (drgnx-modules-report)) :status))))
                             ;; hidden only while the setups run
                             (should (featurep 'drgnx-fixture-test-pkg)))))

(ert-deftest drgnx-test-modules/no-let-binding-trap ()
  ;; A registry variable of a library that is first loaded inside BODY: bound after.  A `let' of it would
  ;; leave it void once the library's defvar has run inside the binding.
  (ert-with-temp-directory dir
                           (let ((drgnx-modules-fingerprint-registries
                                  (cons 'drgnx-fixture-test-late-registry drgnx-modules-fingerprint-registries))
                                 (lib (drgnx-fixture-test--module-file dir "drgnx-fixture-test-late"
                                                                       "(defvar drgnx-fixture-test-late-registry nil \"A registry.\")")))
                             (should-not (boundp 'drgnx-fixture-test-late-registry))
                             (unwind-protect
                                 (progn
                                   (drgnx-test-with-modules nil
                                     (load lib nil t)
                                     (should (boundp 'drgnx-fixture-test-late-registry)))
                                   (should (boundp 'drgnx-fixture-test-late-registry)))
                               (makunbound 'drgnx-fixture-test-late-registry)))))

(ert-deftest drgnx-test-modules/registries-come-back-in-place ()
  ;; Tables and keymaps keep their identity; anything else is set back.
  (let* ((table (make-hash-table :test #'eq))
         (map (make-sparse-keymap))
         (drgnx-fixture-test-table table)
         (drgnx-fixture-test-alist (list (cons 'a (list 1))))
         (drgnx-fixture-test-map map)
         (drgnx-modules-fingerprint-registries '(drgnx-fixture-test-table drgnx-fixture-test-alist
                                                                          drgnx-fixture-test-map)))
    (puthash 'one 1 table)
    (define-key map "a" #'ignore)
    (drgnx-test-with-modules nil
      (puthash 'two 2 drgnx-fixture-test-table)
      (remhash 'one drgnx-fixture-test-table)
      (push (cons 'b 2) drgnx-fixture-test-alist)
      (push 5 (cdr (assq 'a drgnx-fixture-test-alist)))
      (define-key drgnx-fixture-test-map "b" #'ignore)
      (define-key drgnx-fixture-test-map "a" nil))
    (should (eq table drgnx-fixture-test-table))
    (should (equal '(one) (hash-table-keys table)))
    (should (eq map drgnx-fixture-test-map))
    (should (eq #'ignore (lookup-key map "a")))
    (should-not (lookup-key map "b"))
    (should (equal '((a 1)) drgnx-fixture-test-alist))))

(ert-deftest drgnx-test-modules/tears-down-last-first-and-requires-come-along ()
  (ert-with-temp-directory dir
                           (let ((file (drgnx-fixture-test--module-file
                                        dir "fake-order"
                                        "(drgnx-module-define 'fake/first :doc \"a\" :setup #'ignore
  :teardown (lambda () (push 'first drgnx-fixture-test-log)))
(drgnx-module-define 'fake/second :doc \"b\" :requires '(fake/first) :setup #'ignore
  :teardown (lambda () (push 'second drgnx-fixture-test-log)))"))
                                 (drgnx-fixture-test-log nil))
                             (drgnx-test-with-modules (list file)
                               (should (equal '(ok ok) (mapcar (lambda (m) (plist-get (cdr m) :status)) (drgnx-modules-report)))))
                             (should (equal '(first second) drgnx-fixture-test-log)))))

(ert-deftest drgnx-test-modules/teardown-problems-fail-the-test ()
  (ert-with-temp-directory dir
                           (let ((file (drgnx-fixture-test--module-file
                                        dir "fake-bad"
                                        "(drgnx-module-define 'fake/bad :doc \"x\" :setup #'ignore
  :teardown (lambda () (error \"cannot undo\")))")))
                             (let ((err (should-error (drgnx-test-with-modules (list file) (ignore)) :type 'ert-test-failed)))
                               (should (string-match-p "cannot undo" (format "%S" (cdr err))))))))

(ert-deftest drgnx-test-modules/a-failing-body-still-tears-down ()
  (ert-with-temp-directory dir
                           (let ((file (drgnx-fixture-test--module-file
                                        dir "fake-body"
                                        "(drgnx-module-define 'fake/body :doc \"x\" :setup #'ignore
  :teardown (lambda () (push 'body drgnx-fixture-test-log)))"))
                                 (drgnx-fixture-test-log nil))
                             (should-error (drgnx-test-with-modules (list file) (error "boom")))
                             (should (equal '(body) drgnx-fixture-test-log)))))

(ert-deftest drgnx-test-modules/the-keys-and-surfaces-of-the-after-teardown-are-put-back ()
  ;; `drgnx--after-teardown' applies the keys of the registry and installs the context menu; with a populated
  ;; registry the helper puts the process's global state back, so :strict is clean there.
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
    (drgnx--core-commands)
    ;; loads the libraries the setups require, without the keys and menus of the after-teardown function
    (let ((drgnx-modules-after-teardown-functions nil))
      (drgnx-test-with-modules '(tools/browser) (ignore)))
    (let ((map (copy-keymap global-map))
          (context context-menu-mode)
          (menu-hook (default-value 'menu-bar-update-hook))
          (context-fns (default-value 'context-menu-functions))
          (applied drgnx-keys--applied))
      (drgnx-test-with-modules '(tools/browser) :strict t (ignore))
      (should (> (hash-table-count drgnx-commands--table) 4))
      (should (equal map global-map))
      (should (eq context context-menu-mode))
      (should (equal menu-hook (default-value 'menu-bar-update-hook)))
      (should (equal context-fns (default-value 'context-menu-functions)))
      (should (equal applied drgnx-keys--applied)))))

(ert-deftest drgnx-test-modules/a-teardown-problem-is-kept-when-the-body-signals ()
  (ert-with-temp-directory dir
                           (let ((file (drgnx-fixture-test--module-file
                                        dir "fake-both"
                                        "(drgnx-module-define 'fake/both :doc \"x\" :setup #'ignore
  :teardown (lambda () (error \"cannot undo either\")))"))
                                 (said nil))
                             (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) said))))
                               (should-error (drgnx-test-with-modules (list file) (error "boom"))))
                             (should (seq-some (lambda (m) (string-match-p "cannot undo either" m)) said)))))

(ert-deftest drgnx-test-modules/config-and-tables-are-fresh ()
  (let ((real (getenv "DRGNX_CONFIG_DIR")))
    (drgnx-test-with-modules nil
      (should-not (equal real (getenv "DRGNX_CONFIG_DIR")))
      (should (file-directory-p (drgnx-user-dir)))
      (should (string-prefix-p (drgnx-user-dir) (drgnx-state-dir)))
      (should (string-prefix-p (drgnx-user-dir) (file-name-as-directory (getenv "DRGNX_DATA_DIR"))))
      (should-not drgnx-modules--table)
      (should-not drgnx-modules--report))
    (should (equal real (getenv "DRGNX_CONFIG_DIR")))))

;;; modules-fixture-test.el ends here
