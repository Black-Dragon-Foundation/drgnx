;;; gate-exempt.eld --- tests of a gated file that skip the delivery gate  -*- mode: lisp-data -*-
;; (TEST-SYMBOL :why STRING): a test of a file that names `gated' (`;; test-pattern: gated') that never enters
;; `drgnx-test-gated' and talks to a hub connection all the same.  The audit (harness/run-ert.el, DRGNX_TEST_AUDIT=1)
;; holds every other test of such a file to the gate: it fails one that opens a hub connection outside the gate or sees
;; a line the gate did not release.  A listed test is skipped.  Two kinds of row:
;;   - "fake hub": pure against the client's lying peer (test/fixtures/fake-hub.el), which stays outside the gate by design;
;;   - "not converted": a test over the real hub (or its stand-in) that still waits in its own loops.
;; THIS REGISTER ONLY SHRINKS: a converted or deleted test leaves it, and no row is added.
;; `drgnx-lint/gate-exempt-rows-name-tests-in-gated-files' fails a row naming a test that is gone or not in a gated file,
;; `drgnx-lint/gate-exempt-only-shrinks' holds the rows to a constant in test/unit/lint-test-patterns-test.el.
(
 (drgnx-ai/a-refused-request-starts-the-runner-at-most-once-a-minute :why "not converted: core/drgnx-ai-probe.el:181 (the runner job's start) and a real curl and job child, against the gate's virtual clock")
 (drgnx-ai/ensure-local-never-waits-for-the-job :why "not converted: core/drgnx-ai-probe.el:181, a real job child")
 (drgnx-ai/ensure-local-starts-the-runner-when-it-is-down :why "not converted: core/drgnx-ai-probe.el:181, a real job child")
 (drgnx-ai-onboard/a-projects-route-never-reaches-the-global-roles :why "not converted: core/drgnx-onboard.el:519 (the role tests' budget wait on real curl answers)")
 (drgnx-ai-onboard/cli-exit-stops-the-job :why "not converted: core/drgnx-onboard.el:739 (the job start wait) and :767 (the job's loop), a real `sleep' job")
 (drgnx-ai-onboard/pull-has-no-hour-limit :why "not converted: core/drgnx-onboard.el:694 (`drgnx-onboard--until') over hub jobs that are real children")
 (drgnx-ai-onboard/the-role-tests-run-side-by-side :why "not converted: core/drgnx-onboard.el:519 (the budget wait): on the gate's clock the three answers do not come within it")
 (drgnx-ai-onboard/typed-key-cleared-and-env-noted :why "not converted: core/drgnx-onboard.el:694 (`drgnx-onboard--until') after the key's hand-over")
 (drgnx-hub-client/a-current-hello-clears-the-restart-notice :why "fake hub: pure against a lying peer")
 (drgnx-hub-client/a-failing-callback-does-not-drop-the-rest-of-the-chunk :why "pure: a pipe process stands in for the hub's connection")
 (drgnx-hub-client/a-hub-that-says-nothing-is-closed-not-legacy :why "fake hub: pure against a lying peer")
 (drgnx-hub-client/a-key-found-again-quietly-raises-no-notice :why "fake hub: pure against a lying peer")
 (drgnx-hub-client/a-key-the-hub-lost-is-a-notice :why "fake hub: pure against a lying peer")
 (drgnx-hub-client/a-late-challenge-is-read-not-taken-for-legacy :why "fake hub: pure against a lying peer")
 (drgnx-hub-client/a-legacy-hub-gets-no-keys :why "fake hub: pure against a lying peer")
 (drgnx-hub-client/a-legacy-hub-offers-restart-now :why "fake hub: pure against a lying peer")
 (drgnx-hub-client/an-answer-read-after-the-subscription-ended-is-dropped :why "fake hub: pure against a lying peer")
 (drgnx-hub-client/a-wrong-hub-proof-gets-no-keys :why "fake hub: pure against a lying peer")
 (drgnx-hub-client/calls-wait-for-hello :why "fake hub: pure against a lying peer")
 (drgnx-hub-client/deadline-and-disconnect-fire-once :why "fake hub: pure against a lying peer")
 (drgnx-hub-client/env-resent-on-reconnect :why "fake hub: pure against a lying peer")
 (drgnx-hub-client/need-keys-on-an-unproven-connection-is-ignored :why "fake hub: pure against a lying peer")
 (drgnx-hub-client/need-keys-re-reads-the-environment :why "fake hub: pure against a lying peer")
 (drgnx-hub-client/need-keys-without-a-key-raises-a-notice-never-prompts :why "fake hub: pure against a lying peer")
 (drgnx-hub-client/providers-carry-no-key :why "fake hub: pure against a lying peer")
 (drgnx-hub-client/providers-sent-on-connect-and-on-change :why "fake hub: pure against a lying peer")
 (drgnx-hub-client/records-pause-the-mirror :why "fake hub: pure against a lying peer")
 (drgnx-hub-client/the-editor-token-and-held-keys-are-fetched-on-every-connect :why "fake hub: pure against a lying peer")
 (drgnx-hub-client/the-first-hello-carries-the-binary-version :why "fake hub: pure against a lying peer")
 (drgnx-onboard/a-failed-download-says-how-to-retry :why "not converted: core/drgnx-onboard.el:767 (the job's loop), real shell jobs")
 (drgnx-onboard/lm-studio-is-set-up-the-same-way :why "not converted: core/drgnx-onboard.el:767 (the job's loop), real shell jobs")
 (drgnx-onboard/lm-studio-without-lms-says-what-to-do :why "not converted: core/drgnx-onboard.el:467 (the wait for `lms' on the real clock)")
 (drgnx-onboard/ollama-is-installed-started-pulled-and-tested :why "not converted: core/drgnx-onboard.el:767 (the job's loop), real shell jobs")
 (drgnx-onboard/openrouter-key-goes-to-the-keychain :why "not converted: core/drgnx-onboard.el:519 (the role tests' budget wait on real curl answers)")
 (drgnx-onboard/the-ai-step-finds-providers-sets-roles-and-tests-them :why "not converted: core/drgnx-onboard.el:519 (the budget wait: a real curl against the gate's virtual clock)")
 (drgnx-onboard/the-ai-step-keeps-roles-that-work :why "not converted: core/drgnx-onboard.el:519 (the budget wait: a real curl against the gate's virtual clock)")
)
