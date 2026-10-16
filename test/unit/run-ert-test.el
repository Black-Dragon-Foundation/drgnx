;;; run-ert-test.el --- batch tier sanity -*- lexical-binding: t -*-
(require 'ert)
(ert-deftest drgnx-run-ert/loaded ()
  (should (fboundp 'drgnx-run-ert)))
