;;; run-ert.el --- Run drgnx ERT suites and write a JSON summary -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Used by `drgnx test' (batch) and by harness sessions in test mode (GUI).  The JSON
;; summary carries the details, because a GUI session's exit status is only pass/fail.

;;; Code:
(require 'cl-lib)
(require 'ert)

(defun drgnx-run-ert-drain-events ()
  "Handle the events queued for a command loop batch Emacs does not have (file-notify events from a test's
watches): while one waits in the input queue, Emacs runs no process sentinel — later tests would never hear
their processes end.  The runner calls this after every test."
  (dotimes (_ 2) (read-event nil nil 0.002)))     ; 0 reads nothing: the event must be fetched first

(defun drgnx-run-ert--files (where)
  "The test files WHERE names: every *-test.el under a directory, or a list of files (a shard)."
  (if (and (stringp where) (file-directory-p where))
      (directory-files-recursively (expand-file-name where) "-test\\.el\\'")
    (mapcar #'expand-file-name (if (listp where) where (list where)))))

(defun drgnx-run-ert (dir &optional results-file)
  "Load every *-test.el under DIR (or the files of the list DIR: a shard), run all tests, write a JSON
summary to RESULTS-FILE.  Return t if every test passed."
  (advice-add 'ert-run-test :after (lambda (&rest _) (drgnx-run-ert-drain-events)) '((name . drgnx-run-ert-drain)))
  (let* ((load-failures
          (cl-loop for file in (drgnx-run-ert--files dir)
                   for err = (condition-case err (progn (load file nil t) nil) (error err))
                   when err collect (list :name (concat "load " (file-name-nondirectory file))
                                          :condition (format "%S" err))))
         ;; which tests: all, or DRGNX_TEST_SELECTOR (an ERT selector; bin/drgnx check runs :timing ones alone)
         (stats (ert-run-tests-batch (let ((s (getenv "DRGNX_TEST_SELECTOR")))
                                       (if (and s (not (string-empty-p s))) (car (read-from-string s)) t))))
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
                 :expected (if expected t :false)
                 ;; where and how long: bin/drgnx check balances its shards with them
                 :file (or (ert-test-file-name test) :null)
                 :seconds (or (ignore-errors (ert-test-result-duration result)) 0))
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

(defvar project-list-file)

(defun drgnx-run-ert-batch ()
  "Batch entry point: run the suite in the remaining arguments — a directory, or test files (a shard) —
exit 0 or 1."
  ;; Absolute paths before HOME changes: "~/…" would then mean the temp home.
  (setq default-directory (expand-file-name default-directory)
        load-path (mapcar (lambda (d) (if (stringp d) (expand-file-name d) d)) load-path))
  (let* ((args (prog1 (mapcar #'expand-file-name command-line-args-left) (setq command-line-args-left nil)))
         (dir (if (and (= (length args) 1) (file-directory-p (car args))) (car args) args))
         ;; The suite never sees the user's drgnx config, packages, state or cache.
         (tmp (make-temp-file "drgnx-unit" t))
         ;; …nor anything else under ~ (HOME is a temp dir; the user's ELPA stays readable for the
         ;; tests that load packages from it, read-only, through DRGNX_USER_ELPA)
         (elpa (expand-file-name "~/.config/emacs/elpa"))
         (process-environment
          (append (mapcar (lambda (v) (format "%s=%s" (car v) (expand-file-name (cdr v) tmp)))
                          '(("DRGNX_CONFIG_DIR" . "config") ("DRGNX_DATA_DIR" . "data")
                            ("XDG_STATE_HOME" . "state") ("XDG_CACHE_HOME" . "cache") ("HOME" . "home")))
                  (list "DRGNX_TEST_ISOLATED=1")
                  (and (getenv "DRGNX_USER_ELPA") (list (concat "DRGNX_USER_ELPA=" (getenv "DRGNX_USER_ELPA"))))
                  (and (not (getenv "DRGNX_USER_ELPA")) (file-directory-p elpa) (list (concat "DRGNX_USER_ELPA=" elpa)))
                  process-environment))
         (_ (make-directory (expand-file-name "home" tmp) t))
         (abbreviated-home-dir nil)                     ; recomputed for the temp home
         ;; project.el remembers projects it sees: never in the user's own Emacs's list
         (project-list-file (expand-file-name "projects" tmp))
         (ok (drgnx-run-ert dir (getenv "DRGNX_TEST_RESULTS"))))
    (delete-directory tmp t)
    (kill-emacs (if ok 0 1))))

(provide 'drgnx-run-ert)
;;; run-ert.el ends here
