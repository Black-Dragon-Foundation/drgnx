;;; mixed-test.el --- fixture: one passing, one failing test -*- lexical-binding: t -*-
(require 'ert)
(ert-deftest drgnx-fixture/passes () (should (= 1 1)))
(ert-deftest drgnx-fixture/fails () (should (= 1 2)))
