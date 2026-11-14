;;; audit-cond-allowed.eld --- cond tests that really sleep  -*- mode: lisp-data -*-
;; (TEST-NAME :slice SLICE :why STRING) ...: the runtime audit (DRGNX_TEST_AUDIT_FAIL=1) fails a `cond' test that calls a
;; real `sleep-for' or `sit-for' (a wait on time); a test listed here is let through until the slice that moves it to the
;; virtual clock (docs/plans/drgnx/2026-11-14-virtual-clocks.md). The list only shrinks: `drgnx-lint/audit-cond-register'
;; fails a row whose test is gone or that has no reason.
(
)
