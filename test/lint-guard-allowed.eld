;;; lint-guard-allowed.eld --- today's process callbacks outside the guard, for test/unit/lint-guard-test.el  -*- lexical-binding: t -*-
;; One row per site: (:file F :form CALL :near DEFUN :why STRING :until TASK).  CALL is the watched call
;; (make-process, make-network-process, make-pipe-process, make-serial-process, set-process-filter,
;; set-process-sentinel); DEFUN the name of the definition holding it ("top-level" outside any); two sites of one
;; call in one definition are two equal rows.  TASK: td-t15 … td-t23 (the teardown batch whose rider wraps the
;; module), or "runner" (the hub-protocol sweep moves the site to `drgnx-proc-start', which wraps its own
;; callbacks).  Core and `wb' are guarded (notices Task 18).  Rows can only go: the task that wraps a site deletes its row.
(
 ;; core and wb: moved to `drgnx-proc-start' / `drgnx-git' by the hub-protocol sweep (Tasks 5–8)
 (:file "core/drgnx-agent-check.el" :form set-process-sentinel :near "drgnx-agent-check--kill-unit" :why "systemctl kill of a check's scope (sweep Task 8)" :until "runner")
 (:file "core/drgnx-agent-check.el" :form make-pipe-process :near "drgnx-agent-check--start" :why "a checked agent's stderr (sweep Task 8)" :until "runner")
 (:file "core/drgnx-agent-check.el" :form make-process :near "drgnx-agent-check--start" :why "a checked agent (sweep Task 8)" :until "runner")
 (:file "core/drgnx-agent-config-claude.el" :form make-process :near "drgnx-agent-config-claude--cli" :why "the claude CLI run (sweep Task 8)" :until "runner")
 (:file "core/drgnx-ai-client.el" :form make-process :near "drgnx-ai--curl" :why "an AI request's curl (sweep Task 8)" :until "runner")
 (:file "core/drgnx-ai.el" :form make-process :near "drgnx-ai--security-call" :why "the Keychain call (sweep Task 8)" :until "runner")
 (:file "core/drgnx-cockpit-model.el" :form make-process :near "drgnx-cockpit--git" :why "the cockpit's git (sweep Task 6)" :until "runner")
 (:file "core/drgnx-job.el" :form make-process :near "drgnx-job--git-async" :why "a job's git (sweep Task 5)" :until "runner")
 (:file "core/drgnx-platform.el" :form make-process :near "drgnx-platform-call" :why "a platform command (sweep Task 8)" :until "runner")
 (:file "core/drgnx-platform.el" :form set-process-sentinel :near "drgnx-platform-call" :why "a platform command's stderr end (sweep Task 8)" :until "runner")
 (:file "core/drgnx-shell-env.el" :form make-process :near "drgnx-shell-env-start" :why "the login shell's environment (sweep Task 8)" :until "runner")
 (:file "wb/drgnx-git.el" :form make-pipe-process :near "drgnx-git-refresh" :why "the Explorer's git status stderr (sweep Task 7)" :until "runner")
 (:file "wb/drgnx-git.el" :form make-process :near "drgnx-git-refresh" :why "the Explorer's git status (sweep Task 7)" :until "runner")
 ;; modules: the rider of their teardown batch
 (:file "modules/lang/drgnx-markdown.el" :form make-process :near "drgnx-markdown--render" :why "the markdown preview's renderer" :until "td-t17")
 (:file "modules/extra/drgnx-blame.el" :form make-process :near "drgnx-blame--update" :why "git blame of a buffer" :until "td-t18")
 (:file "modules/tools/drgnx-ai-ui.el" :form make-process :near "drgnx-ai--grep-retriever" :why "the AI context's grep" :until "td-t19")
 (:file "modules/tools/drgnx-work-ui.el" :form make-process :near "drgnx-work-ui-refresh" :why "the work scan job" :until "td-t19")
 (:file "modules/tools/drgnx-replace.el" :form make-process :near "drgnx-replace-search" :why "the search behind Replace" :until "td-t20")
 (:file "modules/tools/drgnx-diff.el" :form make-process :near "drgnx-diff--load" :why "the diff's git" :until "td-t21")
 (:file "modules/tools/drgnx-prs.el" :form make-process :near "drgnx-prs-changes" :why "a pull request's fetch" :until "td-t21")
 (:file "modules/tools/drgnx-review.el" :form make-process :near "drgnx-review--check-head" :why "the review's HEAD check" :until "td-t21")
 (:file "modules/editor/drgnx-clipboard.el" :form make-process :near "drgnx-clipboard--gpaste-ask" :why "GPaste's answer (M12b)" :until "td-t22")
)
