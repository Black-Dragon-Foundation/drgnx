;;; perf-flow-test.el --- batch tests: the Flow plan's perf workloads and their budgets -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: the specs and the budget file, with no hub and no GUI (the workloads run on the desktop island,
;; docs/develop/perf.md).  Flow Tasks 23 (S3), 24, 24a, 29 and 22c: each names its workloads in the plan; each has a
;; spec in `drgnx-perf-run--workloads' (setup, a measured step and a teardown) and a budget row in test/perf/budgets.eld.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-perf)
(require 'drgnx-perf-run)
(require 'drgnx-paths)

(defconst perf-flow-test--workloads
  '((conversation-open (:first-rows) 100)     ; Task 23: a 10k-block fixture
    (conversation-append (:append :p95) 4)    ; Task 23
    (agents-side-stream (:patch :p95) 4)      ; Task 24 (24a: still under it with 30 agents spending)
    (agents-side-typing (:delta) 1)           ; Task 24
    (look-reset-3-frames (:reset) 250)        ; Task 29
    (budget-page-open (:first-rows) 100))     ; Task 22c: 500 scopes, 3 meters, 8 days of history
  "Each workload with the budget row the plan names: (NAME (KEY...) LIMIT).")

(ert-deftest drgnx-perf-flow/every-workload-has-a-spec-with-setup-measure-and-teardown ()
  (let ((all (drgnx-perf-run--workloads)))
    (dolist (w perf-flow-test--workloads)
      (let ((spec (cdr (assq (car w) all))))
        (should spec)
        (should (plist-get spec :setup))
        (should (or (plist-get spec :actions) (plist-get spec :measure)))
        (should (plist-get spec :teardown))))))

(ert-deftest drgnx-perf-flow/every-workload-has-its-budget-row ()
  (let ((text (with-temp-buffer
                (insert-file-contents (expand-file-name "test/perf/budgets.eld" drgnx-dir))
                (buffer-string))))
    (dolist (w perf-flow-test--workloads)
      (should (string-match-p (regexp-quote (format "(%s %S %s" (nth 0 w) (nth 1 w) (nth 2 w))) text)))))

(provide 'perf-flow-test)
;;; perf-flow-test.el ends here
