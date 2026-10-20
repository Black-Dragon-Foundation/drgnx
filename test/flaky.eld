;;; flaky.eld --- tests the CI tolerates as flaky  -*- mode: lisp-data -*-
;; (NAME :reason STRING :stress STRING): NAME a test that failed once and passed on the rerun
;; (DRGNX_TEST_RERUN=1, harness/run-ert.el) and is listed here; the run prints `flaky (listed: REASON)' and passes.
;; :reason is the cause, :stress the stress run (command and result) that the commit adding the entry quotes:
;; `DRGNX_TEST_SELECTOR=… bin/drgnx test --stress N --load K'.  A flake without a cause is fixed, not listed.
;; drgnx-lint/flaky-entries-have-a-reason-and-a-stress-run checks every entry.
()
