;;; lint-guard-allowed.eld --- today's process callbacks outside the guard, for test/unit/lint-guard-test.el  -*- lexical-binding: t -*-
;; One row per site: (:file F :form CALL :near DEFUN :why STRING :until TASK).  CALL is the watched call
;; (make-process, make-network-process, make-pipe-process, make-serial-process, set-process-filter,
;; set-process-sentinel); DEFUN the name of the definition holding it ("top-level" outside any); two sites of one
;; call in one definition are two equal rows.  TASK: "runner" (the hub-protocol sweep moves the site to
;; `drgnx-proc-start', which wraps its own callbacks).  Core, `wb' and the modules are guarded (notices Task 18 and
;; its fix pass).  Rows can only go: the task that wraps a site deletes its row.
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
)
