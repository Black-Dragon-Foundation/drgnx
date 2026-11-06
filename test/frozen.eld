;;; frozen.eld --- the tests of code a plan replaces, switched off  -*- mode: lisp-data -*-
;; ((FILE :by "PLAN-OR-DESIGN:LINE" :since DATE :tests (NAME…) :keep (NAME…)) …), one row per test file.
;; :tests are the tests tagged `:frozen' in FILE (left out of every run unless DRGNX_TEST_FROZEN=1, harness/run-ert.el);
;; :keep are the tests of the file that stay on (data loss or security), and are never tagged.
;; drgnx-lint/frozen-tests-are-registered fails a `:frozen' test with no row, a row that names a file or test that is
;; gone, and a `:keep' test tagged `:frozen'.  A row ends when the replacing plan lands: its tests take over, and the
;; frozen file (or the frozen tests) are deleted with the row (docs/develop/testing.md, "Frozen tests").
(
 ("test/unit/agents-ui-test.el"
  :by "2026-10-24-agent-system-design:8; 2026-11-01-agent-system-p4:44" :since "2026-11-04"
  :tests (drgnx-agents-ui/a-transcript-shows-turns-tools-plans-and-what-waits
          drgnx-agents-ui/the-list-has-sessions-and-jobs
          drgnx-agents-ui/last-active-column
          drgnx-agents-ui/an-agent-edit-is-reviewed-hunk-by-hunk
          drgnx-agents-ui/every-command-is-registered
          drgnx-agents-ui/defines-the-agents-segment
          drgnx-agents-ui/turned-off-it-stops-mirroring-and-closes-the-hub-events
          drgnx-agents-ui/turned-off-it-empties-the-agents-set-and-a-click-says-why
          drgnx-agents-ui/hub-sessions-are-mirrored-only-when-a-hub-runs
          drgnx-agents-ui/reject-leaves-the-file-as-it-was
          drgnx-agents-ui/an-agent-can-create-a-file-through-review
          drgnx-agents-ui/closing-a-review-rejects-it
          drgnx-agents-ui/a-transcript-has-stop-deliver-commands-and-queue-controls
          drgnx-agents-ui/the-list-reads-jobs-at-most-every-few-seconds
          drgnx-agents-ui/the-mirror-timer-has-an-owner
          drgnx-agents-ui/thousand-chunks-insert-only-their-text
          drgnx-agents-ui/grow-allocation-is-independent-of-size
          drgnx-agents-ui/a-hidden-transcript-costs-nothing
          drgnx-agents-ui/a-tool-status-change-redraws-one-row
          drgnx-agents-ui/a-permission-adds-and-removes-a-footer-row
          drgnx-agents-ui/answering-the-second-permission-removes-its-row
          drgnx-agents-ui/an-edited-queued-message-is-redrawn
          drgnx-agents-ui/a-steer-removed-from-the-entries-removes-its-row
          drgnx-agents-ui/the-tail-is-followed
          drgnx-agents-ui/a-reader-scrolled-up-stays-put
          drgnx-agents-ui/g-redraws-now
          drgnx-agents-ui/the-list-updates-in-place
          drgnx-agents-ui/the-list-keeps-each-window-on-its-session
          drgnx-agents-ui/the-list-follows-removals-and-reorders
          drgnx-agents-ui/a-hidden-list-prints-nothing
          drgnx-agents-ui/last-ages-on-a-30-second-tick
          drgnx-agents-ui/the-tick-runs-only-while-the-list-shows
          drgnx-agents-ui/hiding-stops-the-tick
          drgnx-agents-ui/the-list-in-an-editor-window-ticks-too
          drgnx-agents-ui/the-column-titles-are-the-first-line
          drgnx-agents-ui/an-empty-list-says-how-to-start
          drgnx-agents-ui/the-empty-hint-names-the-key-and-what-claude-needs
          drgnx-agents-ui/a-write-through-a-planted-link-runs-no-file-name-handler)
  :keep (drgnx-agents-ui/unsaved-edits-of-the-file-are-never-mixed-in
         drgnx-agents-ui/a-quoted-name-is-refused-and-an-edit-is-copied-and-written-with-no-handler
         drgnx-agents-ui/an-edit-to-an-encrypted-or-compressed-file-is-refused))
 ("test/unit/job-ui-test.el"
  :by "2026-10-24-agent-system-design:9; 2026-11-01-agent-system-p4:44; 2026-11-01-agent-system-p5:25" :since "2026-11-04"
  :tests (drgnx-job-ui/note-jobs-sets-cards-and-messages
          drgnx-job-ui/a-failed-recount-is-unknown-with-a-reason
          drgnx-job-ui/a-disconnect-is-unknown
          drgnx-job-ui/the-badge-is-gone
          drgnx-job-ui/badge-mode-is-an-obsolete-alias
          drgnx-job-ui/notify-is-an-obsolete-alias
          drgnx-job-ui/a-new-card-reaches-the-desktop-once
          drgnx-job-ui/overlap-cards-count-but-never-interrupt
          drgnx-job-ui/setup-defines-the-source-and-teardown-clears-it
          drgnx-job-ui/defines-the-jobs-segment
          drgnx-job-ui/note-jobs-is-quiet-while-the-module-is-off
          drgnx-job-ui/the-commands-are-registered
          drgnx-job-ui/turned-off-it-hears-the-hub-no-more
          drgnx-job-ui/what-waits-on-you-is-open-cards-and-unacted-messages
          drgnx-job-ui/attention-mode-adds-and-removes-its-hooks
          drgnx-job-ui/the-recount-timer-has-an-owner
          drgnx-job-ui/events-recount-once-and-the-module-owns-the-recount)
  :keep ())
 ("test/unit/mod-review-test.el"
  :by "2026-11-01-agent-system-p4:44" :since "2026-11-04"
  :tests (drgnx-review/parse-findings-and-verdict
          drgnx-review/the-prompt-goes-once-then-the-answer-is-read
          drgnx-review/edge-cases
          drgnx-review/a-refresh-during-a-head-check-is-not-lost
          drgnx-review/an-older-head-check-answering-late-is-stale
          drgnx-review/ret-opens-the-finding
          drgnx-review/findings-in-model-formatting
          drgnx-review/a-reviewer-that-stops-says-so
          drgnx-review/the-reviewer-goes-once-it-has-answered
          drgnx-review/revert-buffer-redraws
          drgnx-review/show-diff-uses-reviewed-sha
          drgnx-review/refresh-is-a-registered-command
          drgnx-review/turning-it-off-closes-the-tab-and-takes-the-hooks
          drgnx-review/redrawing-keeps-the-place
          drgnx-review/head-check-survives-a-vanished-root
          drgnx-review/turning-it-off-kills-the-reviewers-and-forgets-the-runs)
  :keep (drgnx-review/summary-never-runs-git-itself
         drgnx-review/visit-refuses-outside-root
         drgnx-review/visit-refuses-a-symlink-out-of-the-repository
         drgnx-review/a-path-through-a-planted-link-runs-no-file-name-handler
         drgnx-review/a-finding-is-opened-by-the-name-it-was-checked-by))
 ("test/unit/work-ui-test.el"
  :by "2026-11-01-agent-system-p4:44; 2026-11-01-agent-system-p5:25" :since "2026-11-04"
  :tests (drgnx-work-ui/the-tree-shows-each-spec-with-its-plans-and-their-counts
          drgnx-work-ui/tab-unfolds-a-plan-into-tasks-and-a-task-into-steps-and-commits
          drgnx-work-ui/ret-opens-a-task-at-its-line-and-a-commit-as-a-diff
          drgnx-work-ui/the-filter-and-hide-merged-narrow-the-plans
          drgnx-work-ui/the-graph-lays-out-specs-plans-and-branches-in-columns
          drgnx-work-ui/plans-on-one-branch-each-link-their-own-branch-box
          drgnx-work-ui/a-big-graph-is-drawn-in-bands-emacs-can-show
          drgnx-work-ui/the-graph-on-a-text-frame-says-it-cannot-be-shown
          drgnx-work-ui/g-draws-the-graph-again-and-wide-graphs-scroll-sideways
          drgnx-work-ui/the-graph-takes-its-colours-from-the-theme
          drgnx-work-ui/a-tall-graph-scrolls-line-by-line
          drgnx-work-ui/the-graph-shows-no-cursor-and-a-press-moves-nothing
          drgnx-work-ui/a-click-on-a-box-opens-what-it-shows
          drgnx-work-ui/a-click-opens-from-its-own-window-and-a-double-click-once
          drgnx-work-ui/refresh-scans-in-another-process-and-redraws
          drgnx-work-ui/a-failed-scan-says-only-its-own-output-and-never-errors
          drgnx-work-ui/an-agent-started-on-a-task-works-on-it
          drgnx-work-ui/every-command-is-registered
          drgnx-work-ui/doctor-says-whether-the-tracker-can-work
          drgnx-work-ui/commits-recorded-for-a-todo-or-the-plan-show-and-count
          drgnx-work-ui/a-scan-that-changes-one-task-redraws-one-row
          drgnx-work-ui/folding-inserts-and-removes-children
          drgnx-work-ui/point-stays-on-its-node
          drgnx-work-ui/a-fold-a-filter-and-hide-merged-draw-before-they-return
          drgnx-work-ui/the-node-at-point-is-fresh-after-a-scan-that-leaves-its-row-alone)
  :keep (drgnx-work-ui/a-file-is-opened-by-its-true-name-with-no-file-name-handler))
 ("test/live/drgnx-work-test.el"
  :by "2026-11-01-agent-system-p4:44; 2026-11-01-agent-system-p5:25" :since "2026-11-04"
  :tests (drgnx-live/the-work-tab-fills-in-and-opens-what-it-shows)
  :keep ())
 ("test/unit/ai-gateway-test.el"
  :by "2026-10-24-agent-system-design:8; 2026-11-01-agent-system-p4:45" :since "2026-11-04"
  :tests (drgnx-ai-gateway/gptel-backend-points-at-the-gateway
          drgnx-ai-gateway/gptel-streams-through-the-gateway)
  :keep ())
 ("test/unit/ai-ask-test.el"
  :by "2026-10-24-agent-system-design:8; 2026-11-01-agent-system-p4:45" :since "2026-11-04"
  :tests (drgnx-ai-gptel/its-backend-comes-from-the-chat-role
          drgnx-ai-gptel/configured-unless-the-user-chose-a-backend-of-their-own)
  :keep ())
 ("test/unit/ai-test.el"
  :by "2026-10-24-agent-system-design:8; 2026-11-01-agent-system-p4:45" :since "2026-11-04"
  :tests (drgnx-ai/own-gptel-api-key-keeps-default-backend)
  :keep ())
 ("test/unit/isolated/modal-ai-isolated.el"
  :by "2026-10-24-agent-system-design:8; 2026-11-01-agent-system-p4:44" :since "2026-11-05"
  :tests (drgnx-modal-ai/no-suggestion-outside-insert
          drgnx-modal-ai/one-escape-dismisses-and-leaves-insert
          drgnx-modal-ai/tab-accepts-in-insert
          drgnx-modal-ai/visual-line-edits-whole-lines
          drgnx-modal-ai/visual-block-edits-the-lines-it-touches
          drgnx-modal-ai/visual-edits-the-characters-under-both-ends)
  :keep ())
 ("test/unit/ai-onboard-test.el"
  :by "2026-10-24-agent-system-design:8; 2026-11-01-agent-system-p4:45; onboarding rebuilt on the Rust runtime (2026-11-05): 2026-11-04-race-proof-tests.ledger:137"
  :since "2026-11-04"
  :tests (drgnx-onboard/the-ai-step-finds-providers-sets-roles-and-tests-them
          drgnx-onboard/the-ai-step-keeps-roles-that-work
          drgnx-onboard/the-ai-step-with-nothing-running-says-what-to-do
          drgnx-onboard/the-ai-step-checks-chats-module-when-providers-work
          drgnx-ai-onboard/role-written-only-after-answer
          drgnx-ai-onboard/a-projects-route-never-reaches-the-global-roles
          drgnx-ai-onboard/the-role-tests-run-side-by-side
          drgnx-ai-onboard/a-slow-provider-is-not-tested-and-never-sets-ai-up
          drgnx-ai-onboard/a-provider-that-refuses-at-once-did-not-answer
          drgnx-onboard/ollama-is-installed-started-pulled-and-tested
          drgnx-onboard/lm-studio-is-set-up-the-same-way
          drgnx-onboard/lm-studio-without-lms-says-what-to-do
          drgnx-ai-onboard/cli-exit-stops-the-job
          drgnx-ai-onboard/a-real-ctrl-c-stops-the-job
          drgnx-ai-onboard/pull-has-no-hour-limit
          drgnx-ai-onboard/the-package-sync-has-no-hour-limit
          drgnx-ai-onboard/estimate-skips-models-present
          drgnx-ai-onboard/last-line-has-no-escapes
          drgnx-onboard/openrouter-from-the-cli-asks-for-no-key
          drgnx-onboard/a-failed-download-says-how-to-retry
          drgnx-onboard/non-interactive-installs-nothing
          drgnx-onboard/chat-needs-its-module
          drgnx-onboard/chat-turned-on-installs-its-package
          drgnx-ai/ensure-local-starts-the-runner-when-it-is-down
          drgnx-ai/a-refused-request-starts-the-runner-at-most-once-a-minute
          drgnx-ai/ensure-local-never-waits-for-the-job)
  :keep (drgnx-onboard/openrouter-key-goes-to-the-keychain
         drgnx-ai-onboard/typed-key-cleared-and-env-noted))
 ("test/unit/mod-extras-teardown-test.el"
  :by "2026-10-24-agent-system-design:8; 2026-11-01-agent-system-p4:45" :since "2026-11-04"
  :tests (drgnx-extras-teardown/llm-hook-is-a-name-and-the-backend-returns)
  :keep ())
 ("test/unit/onboard-test.el"
  :by "2026-10-24-agent-system-design:8; 2026-11-01-agent-system-p4:45; onboarding rebuilt on the Rust runtime (2026-11-05): 2026-11-04-race-proof-tests.ledger:137"
  :since "2026-11-04"
  :tests (drgnx-onboard/steps-run-in-order-and-record-progress
          drgnx-onboard/a-check-follows-every-step
          drgnx-onboard/non-interactive-never-asks
          drgnx-onboard/presets-choose-the-extra-modules
          drgnx-onboard/the-environment-says-what-is-missing-and-how-to-fix-it
          drgnx-onboard/macos-fixes-say-brew
          drgnx-onboard/linux-has-no-command-line-tools-row-and-keeps-its-fixes
          drgnx-onboard/no-fc-list-is-not-a-missing-font
          drgnx-onboard/the-font-is-asked-of-emacs-in-a-graphical-session
          drgnx-onboard/look-and-keys-writes-the-choices
          drgnx-onboard/the-daemon-step-writes-files-and-installs-nothing
          drgnx-onboard/step-7-on-macos-asks-once-and-installs-the-app
          drgnx-onboard/step-7-on-macos-without-interaction-installs-nothing
          drgnx-onboard/step-7-on-linux-is-unchanged-plus-the-question
          drgnx-onboard/the-first-window-opens-the-welcome-once
          drgnx-onboard/the-whole-flow-twice
          drgnx-onboard/the-cli
          drgnx-onboard/the-doctor-reports-onboarding
          drgnx-onboard/every-step-is-a-command
          drgnx-onboard/a-scan-that-runs-out-of-time-says-so
          drgnx-onboard/todos-are-imported-only-when-asked
          drgnx-onboard/the-linux-desktop-files-are-written-in-the-data-folder-only
          drgnx-onboard/the-desktop-entry-never-starts-another-config
          drgnx-onboard/the-desktop-entry-claims-nidhoggs-windows
          drgnx-onboard/the-project-picker-can-pick-none-and-paths-with-commas
          drgnx-onboard/claude-missing-is-installed-with-permission
          drgnx-onboard/the-onboarding-package-is-the-maintained-adapter
          drgnx-onboard/a-deprecated-adapter-keeps-working-and-the-step-says-how-to-move
          drgnx-onboard/claude-missing-says-no-and-nothing-is-installed
          drgnx-onboard/claude-on-linux-uses-its-installer-and-your-terminal-for-sudo
          drgnx-onboard/a-vs-code-extensions-claude-does-not-count
          drgnx-onboard/claude-not-logged-in-opens-its-login
          drgnx-onboard/a-claude-that-cannot-say-is-offered-the-login-and-never-fails-the-step
          drgnx-onboard/the-claude-profile-is-checked
          drgnx-onboard/claude-profile-asks-the-hub
          drgnx-onboard/an-npm-failure-says-how-to-retry
          drgnx-onboard/the-preset-step-offers-the-packages
          drgnx-onboard/a-fresh-install-is-full-ai
          drgnx-onboard/every-question-shows-its-choices-and-default
          drgnx-onboard/set-up-ai-with-defaults-to-the-machine
          drgnx-onboard/the-welcome-says-where-to-start-and-moves-on
          drgnx-onboard/on-a-mac-look-and-keys-asks-about-option-once
          drgnx-onboard/option-question-shows-the-current-choice
          drgnx-onboard/chat-check-in-batch-offers-no-restart
          drgnx-onboard/chat-step-turns-chat-on-whatever-the-file-says-now
          drgnx-onboard/restart-detaches-after-the-questions
          drgnx-onboard/restart-waiter-outlives-a-systemd-service
          drgnx-onboard/new-modules-need-a-restart-and-finish-offers-it
          drgnx-onboard/finish-names-spotlight-only-with-the-app
          drgnx-onboard/the-agents-step-and-its-docs
          drgnx-ai-onboard/brew-dir-is-appended-to-path
          drgnx-ai-onboard/path-added-with-a-hub-says-hub-stop
          drgnx-ai-onboard/the-install-question-explains-the-vs-code-claude
          drgnx-ai-onboard/quit-during-auth-status-kills-it
          drgnx-ai-onboard/non-homebrew-npm-on-macos-uses-local-prefix
          drgnx-ai-onboard/failed-claude-installer-names-the-command
          drgnx-ai-onboard/agents-offer-mcp-servers-and-a-default-profile
          drgnx-ai-onboard/agent-defaults-are-never-asked-without-interaction
          drgnx-onboard/the-definition
          drgnx-onboard/an-older-file-keeps-working-and-keeps-its-steps
          drgnx-onboard/record-replaces-its-step-and-keeps-other-entries-and-keys
          drgnx-onboard/a-new-file-has-the-header-and-reads-back
          drgnx-onboard/two-processes-record-different-steps-both-kept
          drgnx-onboard/write-state-writes-the-state-whole-and-nil-leaves-an-empty-file
          drgnx-onboard/the-doctor-and-the-reference-know-onboarding)
  :keep (drgnx-onboard/projects-non-interactive-never-writes-the-board
         drgnx-onboard/projects-interactive-asks-before-writing-the-board
         drgnx-onboard/running-look-and-keys-again-keeps-the-users-choices
         drgnx-onboard/look-step-stops-at-a-keys-mistake-before-any-change
         drgnx-ai-onboard/agent-defaults-keep-the-rest-of-settings-el
         drgnx-onboard/an-unreadable-state-is-backed-up
         drgnx-onboard/an-unreadable-file-is-never-written-by-a-read))
 ("test/unit/core-ui-test.el"
  :by "onboarding rebuilt on the Rust runtime (2026-11-05): 2026-11-04-race-proof-tests.ledger:137" :since "2026-11-05"
  :tests (drgnx-onboard/steps-use-the-kit)
  :keep ())
 ("test/unit/portable-test.el"
  :by "onboarding rebuilt on the Rust runtime (2026-11-05): 2026-11-04-race-proof-tests.ledger:137" :since "2026-11-05"
  :tests (drgnx-onboard/desktop-files-are-machine-local)
  :keep ())
 ("test/unit/tty-onboard-test.el"
  :by "onboarding rebuilt on the Rust runtime (2026-11-05): 2026-11-04-race-proof-tests.ledger:137" :since "2026-11-05"
  :tests (drgnx-onboard/the-daemon-step-names-good-terminals
          drgnx-onboard/run-in-a-terminal-shows-its-row
          drgnx-onboard/a-limited-terminal-gets-the-recommendation)
  :keep ())
 ("test/unit/hub-client-test.el"
  :by "2026-10-24-agent-system-p1:258" :since "2026-10-24"
  :tests (drgnx-hub-client/editor-traffic-over-ratatoskr)
  :keep ())
)
