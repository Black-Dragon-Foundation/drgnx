;;; core-hooks-test.el --- batch tests: staged hooks -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-hooks)

(ert-deftest drgnx-hooks/run-once-isolates-errors ()
  (let ((drgnx-test-hook nil) (n 0) (drgnx-hooks-problems nil) (drgnx-hooks--done nil))
    (add-hook 'drgnx-test-hook (lambda () (error "boom")))
    (add-hook 'drgnx-test-hook (lambda () (setq n (1+ n))))
    (drgnx-hooks-run-once 'drgnx-test-hook)
    (drgnx-hooks-run-once 'drgnx-test-hook)
    (should (= n 1))
    (should (= (length drgnx-hooks-problems) 1))
    (should (string-search "boom" (car drgnx-hooks-problems)))))

(ert-deftest drgnx-hooks/first-file-runs-on-first-visit-only ()
  (let ((drgnx-first-file-hook nil) (drgnx-hooks--done nil) (n 0)
        (f1 (make-temp-file "drgnx-hooks")) (f2 (make-temp-file "drgnx-hooks")))
    (add-hook 'drgnx-first-file-hook (lambda () (setq n (1+ n))))
    (drgnx-hooks-install)
    (unwind-protect
        (progn
          (kill-buffer (find-file-noselect f1))
          (kill-buffer (find-file-noselect f2))
          (should (= n 1)))
      (drgnx-hooks-uninstall)
      (delete-file f1) (delete-file f2))))
