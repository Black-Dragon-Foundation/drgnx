;;; scenario-runner-test.el --- live tests: the scenario tier -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-ui)

(defconst drgnx-live--fixtures
  (expand-file-name "../fixtures/" (file-name-directory (or load-file-name buffer-file-name))))

(ert-deftest drgnx-live/scenario-tier-accepts-known-reds-with-traces ()
  (let ((out (with-output-to-string
               (should (= (drgnx-ui-run-scenarios "minimal" (expand-file-name "scenario-ok" drgnx-live--fixtures)) 0)))))
    (should (string-search "red (known)  drgnx-fixture/known-red-assertion: the Explorer snapped back" out))
    (should (string-search "+196 ms  timer:follow  w3 point 17 → 36" out))
    (should (string-search "green        drgnx-fixture/green" out))))

(ert-deftest drgnx-live/scenario-tier-rejects-a-known-red-that-errors ()
  (let ((out (with-output-to-string
               (should (= (drgnx-ui-run-scenarios "minimal" (expand-file-name "scenario-error" drgnx-live--fixtures)) 1)))))
    (should (string-search "RED" out))))
