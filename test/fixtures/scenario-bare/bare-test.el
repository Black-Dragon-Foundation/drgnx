;;; bare-test.el --- fixture: a known red failing a bare `should' (not a scenario check) -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-scenario)
(ert-deftest drgnx-fixture/known-red-bare-should ()
  :expected-result (drgnx-scenario-expected 'drgnx-fixture/known-red-bare-should)
  (should (= 1 2)))
