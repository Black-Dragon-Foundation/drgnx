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
                 merge.integration push.ci push.main code.ci-config machines job.container job.keys network browser
                 browser.web browser.private unsandboxed settings.change user.private user.emacs chat.project-read
                 plugin.abilities chat.project-edit)
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

(drgnx-defsetting drgnx-agents-net-hosts
  '((packages "crates.io:443" "index.crates.io:443" "static.crates.io:443"
              "registry.npmjs.org:443" "pypi.org:443" "files.pythonhosted.org:443"))
  "The hosts a job that was granted network may reach, per tier: an alist TIER → list of \"host:port\" strings.
`packages' (the tier of a granted network) is the package registries of crates.io, npm and PyPI; `provider-only'
reaches nothing unless you list hosts.  A tier you leave out reaches nothing.  A sandboxed agent session's proxy
allows its tier's hosts (`provider-only') beside its provider's and its CLI's own.  `plugin' is the tier of the
plugins' HTTP requests (never the agent's): a host the plugin's approved manifest names, where the session's network
is not open, must also be listed there.  Only you can set it, never a
repository."
  :type 'sexp :group 'drgnx :scope 'global :workspace 'never :on-error 'strict :agents 'never
  :runtime "NetHosts" :schema '(alist symbol (list-of (string :match ":[0-9]+\\'"))))

(drgnx-defsetting drgnx-agents-browser-program nil
  "The browser an agent session gets: the absolute path of a Chromium, Chrome or headless shell, or nil to find one
(a distro package first, then the one `drgnx browser install' downloaded).  Only you can set it, never a repository."
  :type '(choice (const :tag "find one" nil) file) :group 'drgnx :scope 'global :workspace 'never
  :on-error 'strict :agents 'never :runtime "Option<String>" :schema '(or null (string :match "\\`/")))

(drgnx-defsetting drgnx-agents-browser-local-ports '(3000 3001 4173 4200 5000 5173 8000 8080 8888)
  "The TCP ports on the sandbox's own loopback that a session with the browser lets its agent and browser
connect to, for the servers the agent starts there (a list of port numbers, 1 to 65535).  Servers on this machine are
reached only as host.drgnx.internal:PORT, through a grant.  Only you can set it, never a repository."
  :type '(repeat integer) :group 'drgnx :scope 'global :workspace 'never :on-error 'strict :agents 'never
  :runtime "Vec<u16>" :schema '(list-of (integer :min 1 :max 65535)))

(drgnx-defsetting drgnx-agents-browser-deny-hosts nil
  "Host names (like \"example.com\") a session's browser never reaches, whatever you grant: a list of strings.
Only you can set it, never a repository."
  :type '(repeat string) :group 'drgnx :scope 'global :workspace 'never :on-error 'strict :agents 'never
  :runtime "Vec<String>" :schema '(list-of string))

(drgnx-defsetting drgnx-agents-browser-max-message 67108864
  "The largest message, in bytes, that passes between an agent and its session's browser (64 MiB).
Only you can set it, never a repository."
  :type 'natnum :group 'drgnx :scope 'global :workspace 'never :on-error 'strict :agents 'never
  :runtime "u64" :schema '(integer :min 1))

(drgnx-defsetting drgnx-agents-browser-idle 600
  "Seconds without a command after which a session's browser is stopped; the next command starts it again.
Only you can set it, never a repository."
  :type 'natnum :group 'drgnx :scope 'global :workspace 'never :on-error 'strict :agents 'never
  :runtime "u64" :schema 'natnum)

(drgnx-defsetting drgnx-agents-browser-once-window 600
  "Seconds a one-time browser grant lasts after you give it.  Only you can set it, never a repository."
  :type 'natnum :group 'drgnx :scope 'global :workspace 'never :on-error 'strict :agents 'never
  :runtime "u64" :schema 'natnum)

(drgnx-defsetting drgnx-agents-session-memory "4G"
  "The memory cap of one agent session with its browser, like \"4G\" or \"512M\".
Only you can set it, never a repository."
  :type 'string :group 'drgnx :scope 'global :workspace 'never :on-error 'strict :agents 'never
  :runtime "String" :schema '(string :match "\\`[1-9][0-9]*[KMGT]?\\'"))

(drgnx-defsetting drgnx-agents-browser-memory-high 75
  "The share of the session's memory cap (1 to 99, a percent) at which its browser is stopped.
Only you can set it, never a repository."
  :type 'natnum :group 'drgnx :scope 'global :workspace 'never :on-error 'strict :agents 'never
  :runtime "u32" :schema '(integer :min 1 :max 99))

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

(drgnx-defsetting drgnx-agents-model-prices
  '(("claude-fable-5-1" :in 10 :out 50 :cache-read 0.25 :write-5m 12.5 :write-1h 20 :as-of "2026-11-01")
    ("claude-opus-5-5" :in 4 :out 20 :cache-read 0.2 :write-5m 5 :write-1h 8 :as-of "2026-11-01")
    ("claude-sonnet-5-5" :in 2 :out 10 :cache-read 0.1 :write-5m 2.5 :write-1h 4 :as-of "2026-11-01")
    ("claude-haiku-5-5" :in 0.5 :out 2.5 :cache-read 0.05 :write-5m 0.625 :write-1h 1 :as-of "2026-11-01")
    ("claude" :in 4 :out 20 :cache-read 0.2 :write-5m 5 :write-1h 8 :as-of "2026-11-01"))
  "What a model costs, for the forecasts: an alist KEY → (:in :out :cache-read :write-5m :write-1h :as-of), US dollars per
million tokens.  KEY is a model id prefix (the longest match wins) or a provider name; `claude' is a Claude profile with
no model set.  A cache price left out is the input price.  :as-of is the date the row was read off the provider's page;
the forecast shows the oldest.  The shipped rows are Anthropic's pricing page of 2026-11-01; Haiku's is the tier above
100,000 tokens (a request below it costs a fifth), because agent work runs past it.  A subscription's model is the CLI's
choice, so a subscription's cost is an estimate.  A model with no row (every Codex and Gemini model until you add one)
is unpriced; a gateway provider's `:price' in `drgnx-ai-providers' serves when no row matches.  Add a row for your
own model, or change one when prices move.  Only you can set it, never a repository."
  :type 'sexp :group 'drgnx :scope 'global :workspace 'never :on-error 'strict :agents 'never
  :runtime "Vec<ModelPrice>"
  :schema '(alist string (plist (:in number) (:out number) (:cache-read number) (:write-5m number) (:write-1h number)
                                (:as-of string))))

;; The runners' per-project settings: the hub's queue reads them (docs/guide/jobs.md, "The queue and priority").

(drgnx-defsetting drgnx-runners-send "heavy"
  "Which of the project's jobs may leave this machine for a runner: \"all\", \"heavy\" (only jobs marked heavy) or
\"none\"."
  :type '(choice (const "all") (const "heavy") (const "none")) :group 'drgnx :scope 'project :workspace 'data
  :on-error 'strict :agents 'never :runtime "String" :schema '(string :match "\\`\\(?:all\\|heavy\\|none\\)\\'"))

(drgnx-defsetting drgnx-runners-heavy nil
  "Suite or command patterns whose jobs are heavy in this project (a job is heavy only when marked so)."
  :type '(repeat string) :group 'drgnx :scope 'project :workspace 'data :on-error 'strict :agents 'never
  :runtime "Vec<String>" :schema '(list-of string))

(drgnx-defsetting drgnx-runners-image nil
  "The image a runner runs the project's command jobs in, pinned by digest (\"registry/name@sha256:…\"), or nil."
  :type '(choice (const nil) string) :group 'drgnx :scope 'project :workspace 'data :on-error 'strict
  :agents 'never :runtime "Option<String>" :schema '(or null string))

(drgnx-defsetting drgnx-runners-weight 1.0
  "The project's weight when projects share the machines within a priority (2: twice the share of a project at 1)."
  :type 'number :group 'drgnx :scope 'project :workspace 'data :on-error 'strict :agents 'never
  :runtime "f64" :schema 'number)

(drgnx-defsetting drgnx-runners-project-visibility "private"
  "\"public\" or \"private\": a public project's job whose commit the public origin has may run on a shared runner."
  :type '(choice (const "public") (const "private")) :group 'drgnx :scope 'project :workspace 'data
  :on-error 'strict :agents 'never :runtime "String" :schema '(string :match "\\`\\(?:public\\|private\\)\\'"))

(drgnx-defsetting drgnx-runners-shared-overlay nil
  "Non-nil lets a shared runner have a project's uncommitted files, once each passes the secret scan.
Off, a job with uncommitted changes never runs on a shared runner.  Never set by a repository's own files."
  :type 'boolean :group 'drgnx :safe #'booleanp :scope 'project :workspace 'never
  :on-error 'strict :agents 'never :runtime "bool" :schema 'boolean)

(drgnx-defsetting drgnx-runners-job-keys nil
  "The keys the project's jobs may name, by name (\"CRATES_IO_TOKEN\"): a job naming any other is refused.
Names only, never a value: the values stay in your key store and reach a job's own process only.  Never set by a
repository's own files."
  :type '(repeat string) :group 'drgnx :scope 'project :workspace 'never :on-error 'strict :agents 'never
  :runtime "Vec<String>" :schema '(list-of (string :match "\\`[A-Za-z_][A-Za-z0-9_]*\\'")))

(drgnx-defsetting drgnx-runners-origin-key nil
  "The name of the project's read-only deploy key or token for its private origin, or nil.
Your own runners fetch the project from its origin with it instead of being sent a bundle.  A name only: the value
stays in your key store.  Never set by a repository's own files."
  :type '(choice (const nil) string) :group 'drgnx :scope 'project :workspace 'never :on-error 'strict
  :agents 'never :runtime "Option<String>" :schema '(or null (string :match "\\`[A-Za-z_][A-Za-z0-9_]*\\'")))

;; Plugins and hook rules (docs/guide/plugins.md).  Each is `:scope project' and `:workspace never': a project's value
;; is yours alone.  Neither a repository's files (`.drgnx/settings.el', `.dir-locals.el') nor an agent can write
;; them (a hook only narrows what the matrix allows, so taking one away would widen); only your private workspace
;; file holds a project's value (`drgnx-plugins-project-set' writes it).  Approvals are not settings: the hub keeps
;; them, so a settings file copied to another machine approves nothing.

(defconst drgnx-agents-hook-rules-schema
  '(list-of (plist (:id string "A name to switch the rule off in one project: 1 to 32 lowercase letters, digits and `-'")
                   (:point (enum before-tool after-edit before-commit at-review) "Where the rule looks" :required t)
                   (:tool-kinds (list-of string) "ACP tool kinds (read, edit, delete, move, search, execute, think, fetch, switch_mode, other), or drgnx for the hub's own tools")
                   (:paths (list-of string) "Path globs: * within one segment, ** across segments, ? one character")
                   (:command string "A regular expression the tool's command text must match")
                   (:verdict (enum deny annotate) "What the rule says; a rule never changes anything" :required t)
                   (:reason string "Shown with the refusal or the note" :required t)))
  "The schema of `drgnx-agents-hook-rules'.")

(drgnx-defsetting drgnx-agents-plugins nil
  "The plugins that run, in hook order: a list of plugin names.  A plugin runs only when it is listed here and you
approved it (Extensions, or Settings → Plugins).  In one project the list is the project's own and replaces this one
\(Workspace tab).  Only you can set it, never a repository or an agent."
  :type '(repeat string) :group 'drgnx :scope 'project :merge 'replace :workspace 'never :on-error 'strict
  :agents 'never :runtime "Vec<String>" :schema '(list-of string))

(drgnx-defsetting drgnx-agents-hook-rules nil
  "Rules the hub checks at the hook points, before any plugin: each is a plist with :point, :verdict (deny or annotate)
and :reason, and optionally :id, :tool-kinds, :paths and :command, which all have to match.  A rule only narrows what
the permissions matrix allows; it is a guardrail, not a boundary.  In one project the project's rules are added to
these.  Only you can set it, never a repository or an agent."
  :type '(repeat sexp) :group 'drgnx :scope 'project :merge 'append :workspace 'never :on-error 'strict :agents 'never
  :runtime "Vec<HookRule>" :schema drgnx-agents-hook-rules-schema)

(drgnx-defsetting drgnx-agents-hook-rules-off nil
  "The ids of hook rules that are switched off in this project (a list of strings).  Only a rule with an :id can be
switched off.  Only you can set it, in your private workspace file."
  :type '(repeat string) :group 'drgnx :scope 'project :workspace 'never :on-error 'strict :agents 'never
  :runtime "Vec<String>" :schema '(list-of string))

(provide 'drgnx-agents-matrix)
;;; drgnx-agents-matrix.el ends here
