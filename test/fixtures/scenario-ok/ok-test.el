;;; ok-test.el --- fixture: a known red that fails an assertion, and a green -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-scenario)
(ert-deftest drgnx-fixture/known-red-assertion ()
  :expected-result (drgnx-scenario-expected 'drgnx-fixture/known-red-assertion)
  (drgnx-scenario-check nil "the Explorer snapped back"
                        '(:trace [(:t_ms 196 :cause "timer:follow" :window "w3" :fields ["point"]
                                         :from (:point 17) :to (:point 36))])))
(ert-deftest drgnx-fixture/green () (should t))
