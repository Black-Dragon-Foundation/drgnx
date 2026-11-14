;;; wall-clock-allowed.eld --- test files that still wait on a real time window  -*- mode: lisp-data -*-
;; (FILE :slice SLICE :why STRING) ...: a test file with a `drgnx-test-pause' (a real "did not happen" window) must be listed;
;; `drgnx-lint/real-pauses-are-registered' fails a file with a pause that is not here, and a row whose file has none (the list
;; only shrinks).  :slice names the slice of docs/plans/drgnx/2026-11-14-virtual-clocks.md that converts the file to the virtual
;; clock; "user" is a case the user is asked to rule on (no observable effect ends the window, or the pause is the subject); no agent decides an exception.
(
 ("test/unit/delivery-gate-test.el" :slice "user" :why "a pause of real time is the subject: the test shows that virtual time stands still while real time passes")
 ("test/unit/wait-fixture-test.el" :slice "user" :why "the tests of `drgnx-test-pause' itself call it")
 ("test/tty/frames-test.el" :slice "user" :why "two windows: 'nothing may error in a loop a while later' (no event marks the end of a future loop) and a terminal killed DELAY s into drgnx's and Emacs's own query timeouts (0.5 s, 2.1 s): the delay is the subject")
 ("test/tty/state-test.el" :slice "user" :why "'redisplays and a command-free interval may not note a change': an idle interval of the daemon, no event ends it")
 ("test/ui/childframe-chrome-test.el" :slice "user" :why "two windows: the compositor's late draws after a resize (the count is the result) and a focus event after a call: neither has an end marker")
 ("test/live/drgnx-modal-daemon-test.el" :slice "user" :why "'nothing may close the other window a moment later' after :q: a later close has no marker")
 ("test/live/drgnx-persist-first-client-test.el" :slice "user" :why "'nothing may restore again a moment later' after the first client's restore: a later restore has no marker")
 ("test/live/drgnx-wm-test.el" :slice "user" :why "'the monitor message may not come twice' after the placement ran: a later message has no marker")
)
