;;; audit-cond-allowed.eld --- cond tests that really sleep  -*- mode: lisp-data -*-
;; (TEST-NAME :slice SLICE :why STRING) ...: the runtime audit (DRGNX_TEST_AUDIT_FAIL=1) fails a `cond' test that calls a
;; real `sleep-for' or `sit-for' (a wait on time); a test listed here is let through until the slice that moves it to the
;; virtual clock (docs/plans/drgnx/2026-11-14-virtual-clocks.md). The list only shrinks: `drgnx-lint/audit-cond-register'
;; fails a row whose test is gone or that has no reason.
(
 (drgnx-perf/present-is-the-first-after-paint-after-the-key :slice "S5 perf" :why "a frame budget on a real session: sit-for/sleep-for between key and paint")
 (drgnx-perf-run/a-daemon-that-never-serves-is-an-error :slice "S5 bin" :why "the perf run's start wait polls with sleep-for")
 (drgnx-projects-eld/project-el-list-is-changed-under-its-lock-and-replaced-whole :slice "S5 bin" :why "two real writers race for the lock; the loser sleeps")
 (drgnx-ui-compositor/a-lock-another-taker-replaced-is-not-held-and-not-removed :slice "S5 bin" :why "the compositor reservation's lock poll")
 (drgnx-ui-compositor/two-starts-taking-over-one-stale-reservation-get-it-once :slice "S5 bin" :why "the compositor reservation's lock poll")
 (drgnx-ui/stopping-a-group-waits-for-every-member :slice "S5 bin" :why "a session group's stop polls with sleep-for")
 (drgnx-ui/test-sessions-use-the-generator :slice "S5 bin" :why "the session generator's start poll")
)
