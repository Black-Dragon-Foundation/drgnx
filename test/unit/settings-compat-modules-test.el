;;; settings-compat-modules-test.el --- design §15's module row C26, in a child Emacs -*- lexical-binding: t -*-
;; Row C26 (unified-settings Task 9): a module's `drgnx-module-alist-put' key and a settings.el value for the same
;; alist, with `:merge replace' and `alist'.  Each case runs in a child Emacs under a temp HOME
;; (test/settings-child.el) with a small package (`sat-alist', under ~/sat): settings.el is applied, then a module
;; (`test/c26') is set up and torn down.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/settings-child" drgnx-dir) nil t)

(defconst drgnx-settings-compat-modules--pkg
  ";;; sat-alist.el --- the row's package  -*- lexical-binding: t -*-
(defgroup sat nil \"The row's package.\" :group 'convenience)
(defcustom sat-alist '((std . 0)) \"An alist.\" :type '(alist :key-type symbol :value-type integer) :group 'sat)
(provide 'sat-alist)
"
  "~/sat/sat-alist.el: an alist option.")

(defun drgnx-settings-compat-modules--run (forms &optional entry env)
  "FORMS' values in a child, after the package loads, settings.el (holding ENTRY, an entry's text, if any) is
applied and module test/c26 is set up (it puts the key m into `sat-alist').  ENV as `drgnx-settings-test-child'."
  (let* ((stock (member "DRGNX_SETTINGS_TEST_STOCK=1" env))
         (start (append '((progn (add-to-list 'load-path (expand-file-name "~/sat")) (require 'sat-alist) t))
                        (unless stock
                          '((progn (drgnx-settings-apply-global) t)
                            (progn (drgnx-module-define 'test/c26 :doc "C26"
                                                        :setup (lambda () (drgnx-module-alist-put 'sat-alist 'm 2)))
                                   (drgnx-modules--run-one 'test/c26 (alist-get 'test/c26 drgnx-modules--table)
                                                           'startup)
                                   t)))))
         (r (drgnx-settings-test-child
             (append start forms)
             :files (list (cons "~/sat/sat-alist.el" drgnx-settings-compat-modules--pkg)
                          (cons "settings.el" (concat "(drgnx-settings\n :version 1\n " (or entry "") ")\n")))
             :env env)))
    (should (equal (plist-get r :error) nil))
    (nthcdr (length start) (plist-get r :values))))

(ert-deftest drgnx-settings-compat/c26-a-module-key-and-a-settings-value ()
  ;; replace: settings.el's value, the module's key listed as replaced; alist: both; the module's undo removes only
  ;; its key.
  (should (equal (drgnx-settings-compat-modules--run
                  '((drgnx-settings-test-check-row 'sat-alist :value '((a . 1)) :state 'themed
                                                   :source "Settings (settings.el:3)")
                    (cdr (drgnx-settings-resolve 'sat-alist))
                    (progn (drgnx-module-teardown 'test/c26) sat-alist))
                  "(sat-alist ((a . 1)))")
                 '(t ((test/c26 (m . 2))) ((a . 1)))))
  (should (equal (drgnx-settings-compat-modules--run
                  '((drgnx-settings-test-check-row 'sat-alist :value '((a . 1) (m . 2)) :state 'themed
                                                   :source "Settings (settings.el:3)")
                    (cdr (drgnx-settings-resolve 'sat-alist))
                    (progn (drgnx-module-teardown 'test/c26) sat-alist))
                  "(sat-alist ((a . 1)) :merge alist)")
                 '(t nil ((a . 1)))))
  ;; with drgnx's layers empty (no entry; the module's key is the only change), the answer is stock Emacs's plus that key
  (let ((stock (car (drgnx-settings-compat-modules--run '((drgnx-settings-test-answer 'sat-alist)) nil
                                                        '("DRGNX_SETTINGS_TEST_STOCK=1")))))
    (should (equal stock '(((std . 0)) standard)))
    (should (equal (drgnx-settings-compat-modules--run
                    '((drgnx-settings-test-check-row 'sat-alist :value '((m . 2) (std . 0)) :source "module test/c26")
                      (progn (drgnx-module-teardown 'test/c26)
                             (drgnx-settings-test-check-row 'sat-alist :stock-equal '(((std . 0)) standard)))))
                   '(t t)))))

;;; settings-compat-modules-test.el ends here
