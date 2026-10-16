;;; err-test.el --- fixture: a known red that errors (never acceptable) -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-scenario)
(ert-deftest drgnx-fixture/known-red-assertion ()
  :expected-result (drgnx-scenario-expected 'drgnx-fixture/known-red-assertion)
  (error "fixture repo missing"))
