;;; leaky-theme.el --- fixture: a test file that leaves the enabled-theme list changed -*- lexical-binding: t -*-
;; Copied into a temp suite as a *-test.el by test/unit/run-ert-test.el.
(ert-deftest file-leak-fixture/leaves-a-theme-enabled ()
  (push 'file-leak-fixture-theme custom-enabled-themes)
  (should t))
