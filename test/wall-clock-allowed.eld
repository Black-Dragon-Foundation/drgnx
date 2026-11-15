;;; wall-clock-allowed.eld --- test files that still wait on a real time window  -*- mode: lisp-data -*-
;; (FILE :slice SLICE :why STRING) ...: a test file with a `drgnx-test-pause' (a real "did not happen" window) must be listed;
;; `drgnx-lint/real-pauses-are-registered' fails a file with a pause that is not here, and a row whose file has none (the list
;; only shrinks).  :slice names the slice of docs/plans/drgnx/2026-11-14-virtual-clocks.md that converts the file to the virtual
;; clock; "user, DATE" is an exception the user decided (no observable effect ends the window, or the pause is the subject): no agent decides one.
(
 ("test/unit/delivery-gate-test.el" :slice "user, 2026-11-15" :why "decided by the user 2026-11-15: a pause of real time is the subject: the test shows that virtual time stands still while real time passes")
 ("test/unit/wait-fixture-test.el" :slice "user, 2026-11-15" :why "decided by the user 2026-11-15: the tests of `drgnx-test-pause' itself call it")
 ("test/tty/frames-test.el" :slice "user, 2026-11-15" :why "decided by the user 2026-11-15: a terminal killed 0.5 s and 2.1 s into drgnx's and Emacs's own query timeouts (XTVERSION, DA2): the delay is the subject")
 ("test/tty/state-test.el" :slice "user, 2026-11-15" :why "decided by the user 2026-11-15: 'redisplays and a command-free interval may not note a change': a daemon idle interval, no event ends it")
 ("test/live/drgnx-modal-daemon-test.el" :slice "user, 2026-11-15" :why "decided by the user 2026-11-15: 'nothing may close the other window a moment later' after :q: a later close has no marker")
 ("test/live/drgnx-persist-first-client-test.el" :slice "user, 2026-11-15" :why "decided by the user 2026-11-15: 'nothing may restore again a moment later' after the first client's restore: a later restore has no marker")
 ("test/live/drgnx-wm-test.el" :slice "user, 2026-11-15" :why "decided by the user 2026-11-15: 'the monitor message may not come twice' after the placement ran: a later message has no marker")
)
