;;; leaky-mode-line.el --- fixture: a test file that leaves a mode-line entry behind -*- lexical-binding: t -*-
;; Copied into a temp suite as a *-test.el by test/unit/run-ert-test.el (the per-file leak check, DRGNX_TEST_FILE_LEAKS).
;; Its test passes; the file does not: the entry stays in the default `mode-line-format'.
(ert-deftest file-leak-fixture/leaves-a-mode-line-entry ()
  (setq-default mode-line-format (append (default-value 'mode-line-format) (list " LEAKED-ENTRY")))
  (should t))
