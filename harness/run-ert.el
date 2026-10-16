;;; run-ert.el --- Run drgnx ERT suites and write a JSON summary -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Used by `drgnx test' (batch) and by harness sessions in test mode (GUI).  The JSON
;; summary carries the details, because a GUI session's exit status is only pass/fail.

;;; Code:
(require 'cl-lib)
(require 'ert)

(defun drgnx-run-ert (dir &optional results-file)
  "Load every *-test.el under DIR, run all tests, write a JSON summary to RESULTS-FILE.
Return t if every test passed."
  (let* ((load-failures
          (cl-loop for file in (directory-files-recursively (expand-file-name dir) "-test\\.el\\'")
                   for err = (condition-case err (progn (load file nil t) nil) (error err))
                   when err collect (list :name (concat "load " (file-name-nondirectory file))
                                          :condition (format "%S" err))))
         (stats (ert-run-tests-batch t))
         (tests nil) (known-red nil) (failures nil))
    (cl-loop
     for test across (ert--stats-tests stats)
     for name = (symbol-name (ert-test-name test))
     for result = (ert-test-most-recent-result test)
     for expected = (ert-test-result-expected-p test result)
     for condition = (and (ert-test-result-with-condition-p result)
                          (ert-test-result-with-condition-condition result))
     do
     (push (list :name name
                 :result (cond ((ert-test-passed-p result) "passed")
                               ((ert-test-skipped-p result) "skipped")
                               (t "failed"))
                 :expected (if expected t :false))
           tests)
     (cond
      ((not expected)
       (push (list :name name :condition (if condition (format "%S" condition) "unexpected result")) failures))
      ((ert-test-failed-p result)
       ;; An expected failure (a known red) counts only if it failed an assertion; an error
       ;; (missing fixture, broken driver, timeout) is never acceptable.
       ;; It must also be a `drgnx-scenario-check' failure (carrying its explanation and
       ;; trace), not a bare `should' that could fail for any reason.
       (let* ((data (and (eq (car condition) 'ert-test-failed) (cadr condition)))
              (summary (ignore-errors (plist-get data :scenario))))
         (cond
          (summary (push (list :name name :summary summary
                               :trace (or (ignore-errors (plist-get data :trace)) []))
                         known-red))
          (data (push (list :name name :condition
                            (format "known red, but it failed outside drgnx-scenario-check: %S" condition))
                      failures))
          (t (push (list :name name :condition (format "known red, but it errored: %S" condition))
                   failures)))))))
    (setq failures (append load-failures (nreverse failures)))
    (when results-file
      (let ((coding-system-for-write 'utf-8-unix))
        (write-region
         (decode-coding-string
          (json-serialize
           (list :total (+ (ert-stats-total stats) (length load-failures))
                 :passed (ert-stats-completed-expected stats)
                 :failed (length failures)
                 :failures (vconcat failures)
                 :known_red (vconcat (nreverse known-red))
                 :tests (vconcat (nreverse tests))))
          'utf-8)
         nil results-file nil 'silent)))
    (null failures)))

(defun drgnx-run-ert-batch ()
  "Batch entry point: run the suite in the first remaining argument, exit 0 or 1."
  (let* ((dir (pop command-line-args-left))
         ;; The suite never sees the user's drgnx config, packages, state or cache.
         (tmp (make-temp-file "drgnx-unit" t))
         (process-environment
          (append (mapcar (lambda (v) (format "%s=%s" (car v) (expand-file-name (cdr v) tmp)))
                          '(("DRGNX_CONFIG_DIR" . "config") ("DRGNX_DATA_DIR" . "data")
                            ("XDG_STATE_HOME" . "state") ("XDG_CACHE_HOME" . "cache")))
                  (list "DRGNX_TEST_ISOLATED=1")
                  process-environment))
         (ok (drgnx-run-ert dir (getenv "DRGNX_TEST_RESULTS"))))
    (delete-directory tmp t)
    (kill-emacs (if ok 0 1))))

(provide 'drgnx-run-ert)
;;; run-ert.el ends here
