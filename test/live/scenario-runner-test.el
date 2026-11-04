;;; scenario-runner-test.el --- live tests: the scenario tier -*- lexical-binding: t -*-
;; test-class: cond
(require 'ert)
(require 'drgnx-ui)

(defconst drgnx-live--fixtures
  (expand-file-name "../fixtures/" (file-name-directory (or load-file-name buffer-file-name))))

(defun drgnx-live--run-scenarios (dir)
  "Run the scenario suite DIR of the fixtures as its own run, with the exit code.
The outer run's DRGNX_TEST_SELECTOR names live tests and would match none of the fixture's: a nested run sets its own."
  (let ((process-environment (cons "DRGNX_TEST_SELECTOR=" process-environment)))
    (drgnx-ui-run-scenarios "minimal" (expand-file-name dir drgnx-live--fixtures))))

(ert-deftest drgnx-live/a-nested-scenario-run-ignores-the-outer-selector ()
  (let ((process-environment (cons "DRGNX_TEST_SELECTOR=\"^nothing-matches-this$\"" process-environment)))
    (let ((out (with-output-to-string (should (= (drgnx-live--run-scenarios "scenario-ok") 0)))))
      (should (string-search "green        drgnx-fixture/green" out)))))

(ert-deftest drgnx-live/scenario-tier-accepts-known-reds-with-traces ()
  (let ((out (with-output-to-string
               (should (= (drgnx-live--run-scenarios "scenario-ok") 0)))))
    (should (string-search "red (known)  drgnx-fixture/known-red-assertion: the Explorer snapped back" out))
    (should (string-search "+196 ms  timer:follow  w3 point 17 → 36" out))
    (should (string-search "green        drgnx-fixture/green" out))))

(ert-deftest drgnx-live/scenario-tier-rejects-a-known-red-that-errors ()
  (let ((out (with-output-to-string
               (should (= (drgnx-live--run-scenarios "scenario-error") 1)))))
    (should (string-search "RED" out))))

(ert-deftest drgnx-live/frame-scenario-within-budget ()
  (let ((out (with-output-to-string
               (should (= (drgnx-live--run-scenarios "scenario-frames-ok") 0)))))
    (should (string-match-p "green +drgnx-scenario/frame-from-daemon-fast (median [0-9]+ ms" out))))

(ert-deftest drgnx-live/frame-scenario-over-budget-is-red ()
  (let ((out (with-output-to-string
               (should (= (drgnx-live--run-scenarios "scenario-frames-tight") 1)))))
    (should (string-match-p "RED +drgnx-scenario/frame-from-daemon-fast: median [0-9]+ ms > budget 1 ms" out))))

(ert-deftest drgnx-live/scenario-results-are-kept ()
  (let* ((root (make-temp-file "drgnx-scn-state" t))
         (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment)))
    (unwind-protect
        (progn
          (with-output-to-string
            (drgnx-live--run-scenarios "scenario-ok"))
          (let ((kept (expand-file-name "scenarios/minimal.json" root)))
            (should (file-exists-p kept))
            (should (string-search "the Explorer snapped back"
                                   (with-temp-buffer (insert-file-contents kept) (buffer-string))))))
      (delete-directory root t))))
