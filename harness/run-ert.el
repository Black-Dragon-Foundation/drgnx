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
  (dolist (file (directory-files-recursively dir "-test\\.el\\'"))
    (load file nil t))
  (let* ((stats (ert-run-tests-batch t))
         (failures
          (cl-loop for test across (ert--stats-tests stats)
                   for result = (ert-test-most-recent-result test)
                   unless (ert-test-result-expected-p test result)
                   collect (list :name (symbol-name (ert-test-name test))
                                 :condition
                                 (if (ert-test-result-with-condition-p result)
                                     (format "%S" (ert-test-result-with-condition-condition result))
                                   "unexpected result")))))
    (when results-file
      (with-temp-file results-file
        (insert (json-serialize
                 (list :total (ert-stats-total stats)
                       :passed (ert-stats-completed-expected stats)
                       :failed (length failures)
                       :failures (vconcat failures))))))
    (null failures)))

(defun drgnx-run-ert-batch ()
  "Batch entry point: run the suite in the first remaining argument, exit 0 or 1."
  (let ((dir (pop command-line-args-left)))
    (kill-emacs (if (drgnx-run-ert dir (getenv "DRGNX_TEST_RESULTS")) 0 1))))

(provide 'drgnx-run-ert)
;;; run-ert.el ends here
