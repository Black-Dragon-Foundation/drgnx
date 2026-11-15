;;; leaky-key.el --- fixture: a test file that leaves a global key, a header line and a frame parameter behind -*- lexical-binding: t -*-
;; Copied into a temp suite as a *-test.el by test/unit/run-ert-test.el.
(ert-deftest file-leak-fixture/leaves-a-global-key ()
  (global-set-key (kbd "C-c C-x C-l") #'ignore)
  (setq-default header-line-format "LEAKED-HEADER")
  (set-frame-parameter nil 'file-leak-fixture-parameter 'left-behind)
  (should t))
