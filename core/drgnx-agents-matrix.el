;;; drgnx-agents-matrix.el --- The permissions matrix and the agent limits as settings -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; What agents may do without asking (the matrix), and the limits the hub keeps for them (docs/guide/agents.md,
;; "The permissions matrix"; docs/guide/security.md).  Settings only: the hub decides.  Every one is `:runtime' (the
;; hub reads it from settings.el), `:on-error strict' (a settings.el that does not read gives the shipped default,
;; never a half-read matrix), `:agents never' (an agent cannot change what it may do: the `settings_change' tool
;; refuses them) and `:workspace never' (a repository's .drgnx/settings.el or .dir-locals.el cannot set them).
;;
;; `drgnx-agents-matrix' is a plist in the wire's own words (`runstav::methods::matrix'; the hub decodes the same
;; shape as JSON):
;;   (:preset balanced
;;    :time ((:when away :preset cautious) (:when (between 1320 420) :preset autonomous))
;;    :cells ((:action push.main :column (:role worker) :verdict never)
;;            (:action spend :column (:role chat) :verdict ask :limit (:amount 2 :unit usd))))
;; Action ids are the hub's `Action::id' (`drgnx-agents-matrix-actions'; a test holds them to the protocol's schema).

;;; Code:
(require 'cl-lib)
(require 'drgnx-setting)

(defconst drgnx-agents-matrix-actions
  '(agents.start agents.model agents.control graph.change task.done spend spend.over code.read code.edit commit
                 merge.integration push.ci push.main code.ci-config machines job.container network unsandboxed
                 settings.change user.private user.emacs chat.project-read)
  "The matrix's rows, as the hub spells them (`Action::id' in runstav::methods::matrix).")

(defconst drgnx-agents-matrix-schema
  `(plist (:preset (enum cautious balanced autonomous) "The base preset; absent: balanced")
          (:time (list-of (plist (:when (or (enum away) (pred drgnx-agents-matrix--between-p "(between FROM TO), minutes of the day"))
                                        "While you are away, or between two minutes of the day (local time)" :required t)
                                 (:preset (enum cautious balanced autonomous) "The preset that applies then" :required t)))
                 "Presets that replace the base one at some times")
          (:cells (list-of (plist (:action (enum ,@drgnx-agents-matrix-actions) "What the agent does" :required t)
                                  (:column (pred drgnx-agents-matrix--column-p "(:role manager|worker|chat), (:agent NAME) or (:provider NAME)")
                                           "Whose cell" :required t)
                                  (:verdict (enum allow ask never) "What happens" :required t)
                                  (:limit (plist (:amount number "How much" :required t)
                                                 (:unit (enum count usd usd-est tokens limit-share) "Of what" :required t))
                                          "An amount over which the cell is decided by spend.over")))
                  "Cell overrides"))
  "The schema of `drgnx-agents-matrix'.")

(defun drgnx-agents-matrix--between-p (v)
  "Non-nil when V is (between FROM TO) with minutes of the day."
  (and (eq (car-safe v) 'between) (= (length v) 3)
       (cl-every (lambda (m) (and (natnump m) (< m 1440))) (cdr v))))

(defun drgnx-agents-matrix--column-p (v)
  "Non-nil when V is a matrix column: (:role manager|worker|chat), (:agent NAME) or (:provider NAME)."
  (and (proper-list-p v) (= (length v) 2)
       (pcase (car v)
         (:role (memq (cadr v) '(manager worker chat)))
         ((or :agent :provider) (and (stringp (cadr v)) (<= 1 (length (cadr v)) 128))))
       t))

;;;; The settings

(drgnx-defsetting drgnx-agents-matrix '(:preset balanced)
  "What agents may do without asking: a plist (:preset cautious|balanced|autonomous :time TIME-PRESETS :cells CELLS).
Balanced is the shipped preset.  A time preset replaces the base one while you are away (`drgnx-agents-away-after')
or between two minutes of the day.  A cell sets one action for a role, an agent or a provider; the most restrictive
column that matches wins.  Set it in Settings → User; no workspace and no agent can."
  :type 'sexp :group 'drgnx :scope 'global :workspace 'never :on-error 'strict :agents 'never
  :runtime "AgentsMatrix" :schema drgnx-agents-matrix-schema)

(drgnx-defsetting drgnx-agents-away-after 600
  "Seconds without input after which the editor tells the hub you are away (the time presets of the matrix follow)."
  :type 'natnum :group 'drgnx :scope 'global :workspace 'never :on-error 'strict :agents 'never
  :runtime "u64" :schema 'natnum)

(drgnx-defsetting drgnx-agents-wait-refusals 3
  "How many times an agent may try to wait on a job (sleep, tail -f, polling) before its turn is cancelled."
  :type 'natnum :group 'drgnx :scope 'global :workspace 'never :on-error 'strict :agents 'never
  :runtime "u32" :schema 'natnum)

(drgnx-defsetting drgnx-agents-close-idle-after 1800
  "Seconds a session may sit idle on a running job before it is closed and resumed at the job's wake."
  :type 'natnum :group 'drgnx :scope 'global :workspace 'never :on-error 'strict :agents 'never
  :runtime "u64" :schema 'natnum)

(drgnx-defsetting drgnx-agents-checkpoint-cap 2147483648
  "Bytes of checkpoints kept per project (the shadow repos of all its sessions together); the oldest of finished
tasks go first."
  :type 'natnum :group 'drgnx :scope 'global :workspace 'never :on-error 'strict :agents 'never
  :runtime "u64" :schema 'natnum)

(drgnx-defsetting drgnx-agents-job-memory "4G"
  "The memory cap of one job (systemd's MemoryMax, podman's --memory), like \"4G\" or \"512M\"."
  :type 'string :group 'drgnx :scope 'global :workspace 'never :on-error 'strict :agents 'never
  :runtime "String" :schema '(string :match "\\`[1-9][0-9]*[KMGT]?\\'"))

(drgnx-defsetting drgnx-agents-job-cpus 2
  "How many CPUs one job may use."
  :type 'natnum :group 'drgnx :scope 'global :workspace 'never :on-error 'strict :agents 'never
  :runtime "u32" :schema 'natnum)

(drgnx-defsetting drgnx-agents-container-images nil
  "The images container jobs may run: an alist NAME → image reference pinned by digest (\"registry/name@sha256:…\").
The hub pulls them; a job names one of them and nothing else.  Only you can set it, never a repository."
  :type 'sexp :group 'drgnx :scope 'global :workspace 'never :on-error 'strict :agents 'never
  :runtime "Vec<ContainerImage>"
  :schema '(alist string (string :match "@sha256:[0-9a-f]\\{64\\}\\'")))

(drgnx-defsetting drgnx-agents-silent-after '((task . 600) (brainstorm . 1800))
  "Seconds without an update after which the supervisor pauses a session, per kind of work."
  :type 'sexp :group 'drgnx :scope 'global :workspace 'never :on-error 'strict :agents 'never
  :runtime "SilentAfter" :schema '(alist symbol natnum))

(drgnx-defsetting drgnx-agents-repeat-limit 3
  "How many times the same command may run in one turn before the supervisor pauses the session."
  :type 'natnum :group 'drgnx :scope 'global :workspace 'never :on-error 'strict :agents 'never
  :runtime "u32" :schema 'natnum)

(drgnx-defsetting drgnx-agents-no-progress-tokens 20000
  "Tokens per changed line of task work over which the supervisor pauses the session."
  :type 'natnum :group 'drgnx :scope 'global :workspace 'never :on-error 'strict :agents 'never
  :runtime "u64" :schema 'natnum)

(drgnx-defsetting drgnx-agents-manager-context 0.7
  "The share of its context window (0 to 1) at which a manager is rotated."
  :type 'number :group 'drgnx :scope 'global :workspace 'never :on-error 'strict :agents 'never
  :runtime "f64" :schema 'number)

(provide 'drgnx-agents-matrix)
;;; drgnx-agents-matrix.el ends here
