;;; clean.el --- fixture: a test file that sets state and puts it back -*- lexical-binding: t -*-
;; Copied into a temp suite as a *-test.el by test/unit/run-ert-test.el.
(ert-deftest file-leak-fixture/puts-everything-back ()
  (let ((old (default-value 'mode-line-format)))
    (unwind-protect
        (progn (setq-default mode-line-format (append old (list " TEMPORARY")))
               (global-set-key (kbd "C-c C-x C-c") #'ignore)
               (should (member " TEMPORARY" (default-value 'mode-line-format))))
      (setq-default mode-line-format old)
      (define-key global-map (kbd "C-c C-x C-c") nil t))))
