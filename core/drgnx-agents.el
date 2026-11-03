;;; drgnx-agents.el --- Agent sessions: settings, profiles, the transcript model, what the editor asks the hub -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A session is one ACP agent process (a profile: command and environment) working in a directory.  The hub
;; (Ratatoskr) runs it; this Emacs holds a mirror of it (drgnx-agents-mirror.el).  Its transcript is a list of
;; entries — user, agent, thought, tool (with children: subagents), plan — built from the agent's updates.
;; Sending never cancels: to a busy session the hub queues a message (delivered once, in order, when the turn
;; ends), or steers the running turn when the profile says `steer' and the agent supports it; only Stop cancels.
;; An agent's questions — may I run this? may I write that file? — become pending items for the viewer: nothing
;; here ever asks.  This file holds the agent settings, the Claude Code adapter checks, the "needs you" set, the
;; transcript model and the calls that ask the hub to act on a session.  See docs/guide/agents.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-config)
(require 'drgnx-setting)
(require 'drgnx-settings-defaults)     ; the shipped built-in profiles, and `drgnx-agents-set-setting's writer
(require 'drgnx-agent-config)          ; `drgnx-agent-config-vendor-env'
(require 'drgnx-notice)                 ; what waits on you is the `agents' set of the "needs you" count

(defun drgnx-agents--openrouter-check (raw)
  "Signal a `user-error' naming the first part of RAW (an `:openrouter' value) that is not a restriction: RAW not a
plist, a key other than :only :ignore :data-collection :zdr, a list of slugs that is not one, a :data-collection
other than deny or allow, a :zdr other than t or false.  Empty values (nil, [], JSON false or null) are no
restriction."
  (unless (and (proper-list-p raw) (cl-evenp (length raw)))
    (user-error "OpenRouter restrictions: :openrouter is %S, not a list of keys and values" raw))
  (cl-loop for (key value) on raw by #'cddr
           do (pcase key
                ((or :only :ignore)
                 (unless (and (or (listp value) (vectorp value))
                              (cl-every (lambda (s) (and (stringp s) (string-match-p "\\`[A-Za-z0-9][A-Za-z0-9._/-]*\\'" s)))
                                        (append value nil)))
                   (user-error "OpenRouter restrictions: %s is %S, not a list of provider slugs (like (\"anthropic\"))"
                               key value)))
                (:data-collection
                 (unless (member value '(nil :null deny allow "deny" "allow"))
                   (user-error "OpenRouter restrictions: :data-collection is %S, not deny or allow" value)))
                (:zdr
                 (unless (memq value '(nil t :false :null))
                   (user-error "OpenRouter restrictions: :zdr is %S, not t or nil" value)))
                (_ (user-error "OpenRouter restrictions: %S is not one of :only :ignore :data-collection :zdr" key)))))

(defun drgnx-agents--openrouter-slugs (value)
  "The provider slugs in VALUE (a list or a vector): the strings that are plain slugs (letters, digits, . _ / -)."
  (and (or (listp value) (vectorp value))
       (cl-loop for s in (append value nil)
                when (and (stringp s) (string-match-p "\\`[A-Za-z0-9][A-Za-z0-9._/-]*\\'" s)) collect s)))

(defun drgnx-agents--openrouter-ok-p (value)
  "Whether VALUE is an `:openrouter' restriction: t when `drgnx-agents--openrouter-check' accepts it, else its
`user-error' (the schema reports its message, which names the offending key)."
  (drgnx-agents--openrouter-check value)
  t)

(defconst drgnx-agents-config-schema
  '(plist (:profiles (alist string (plist (:command (list-of string) "The program and its arguments" :required t)
                                          (:env (list-of string) "NAME=value pairs added to its environment")
                                          (:mode (enum queue steer interrupt) "What a message to a busy agent does")
                                          (:ai symbol "The provider environment it gets")
                                          (:model string "The model it asks for")
                                          (:tracker-tools (enum on off) "The five tracker tools; on by default")
                                          (:doc string "One line")))
                     "Your agent profiles; the built-in ones need none")
          (:default string "The profile New Agent Session… offers")
          (:mcp (list-of (enum coordination search)) "The MCP servers agents get")
          (:openrouter (pred drgnx-agents--openrouter-ok-p "not an OpenRouter restriction (:only :ignore :data-collection :zdr)")
                       "Which providers OpenRouter may use")
          (:routes (alist symbol (or string (list-of string))) "Which profiles do each job role: a list of names, or one name"))
  "The schema of agents.eld, which the migration still reads (`drgnx-settings-migrate').
The settings below use its parts.")

(drgnx-config-define 'agents
                     :file "agents.eld" :shape 'plist :version 1 :schema drgnx-agents-config-schema
                     :default '(:profiles nil :mcp (coordination)) :reload 'mtime :last-good nil :max-bytes 262144
                     :header ";; drgnx agents (docs/guide/agents.md)\n"
                     :doc "The old agents.eld, read only to move it into settings.el (docs/guide/settings.md).")

;;;; The settings (agents.eld folded into settings.el; docs/guide/agents.md)
;; All `:on-error strict' (a settings.el that does not read gives the shipped default, never a half-read value),
;; `:agents never' (an agent cannot change them), `:workspace never' (a cloned repository cannot set them: a profile
;; is a program, a route chooses where your code goes) and `:runtime' (the hub reads them).  Callers read the
;; default value, so a buffer-local value never reaches them.

(defun drgnx-agents--key-schema (key)
  "The schema of KEY in `drgnx-agents-config-schema'."
  (nth 1 (assq key (cdr drgnx-agents-config-schema))))

(drgnx-defsetting drgnx-agents-profiles nil
  "Your agent profiles: an alist NAME → plist (:command LIST :env (\"NAME=value\"…) :mode queue|steer|interrupt
:ai PROVIDER-ENVIRONMENT :model MODEL :tracker-tools on|off :doc LINE).  The built-in ones need none; never holds
secrets (keys come from the environment)."
  :type 'sexp :group 'drgnx :scope 'global :workspace 'never :on-error 'strict :agents 'never
  :runtime "Vec<AgentProfile>" :schema (drgnx-agents--key-schema :profiles))

(drgnx-defsetting drgnx-agents-default nil
  "The profile New Agent Session offers on Return: a profile's name, or nil for claude."
  :type '(choice (const :tag "claude" nil) string) :group 'drgnx :scope 'global :workspace 'never
  :on-error 'strict :agents 'never :runtime "Option<String>" :schema '(or null string))

(drgnx-defsetting drgnx-agents-mcp '(coordination)
  "The MCP servers agents get: `coordination' and `search'."
  :type '(repeat symbol) :group 'drgnx :scope 'global :workspace 'never :on-error 'strict :agents 'never
  :runtime "Vec<String>" :schema (drgnx-agents--key-schema :mcp))

(drgnx-defsetting drgnx-agents-routes nil
  "Which profiles do each job role: an alist ROLE → a profile's name, or a list of names."
  :type 'sexp :group 'drgnx :scope 'global :workspace 'never :on-error 'strict :agents 'never
  :runtime "Vec<AgentRoute>" :schema (drgnx-agents--key-schema :routes))

(drgnx-defsetting drgnx-agents-openrouter nil
  "Which providers OpenRouter may use for the agents' requests: a plist (:only SLUGS :ignore SLUGS
:data-collection deny|allow :zdr t), each key only when set.  A value that is not a restriction is refused, and
OpenRouter agents do not start until it is fixed."
  :type 'sexp :group 'drgnx :scope 'global :workspace 'never :on-error 'strict :agents 'never
  :runtime "OpenRouterRestrictions" :schema (drgnx-agents--key-schema :openrouter))

(drgnx-defsetting drgnx-agents-allow-unsandboxed nil
  "Non-nil: agents may run without the sandbox.  Off unless you turn it on; no workspace and no agent can."
  :type 'boolean :group 'drgnx :scope 'global :workspace 'never :on-error 'strict :agents 'never
  :runtime "bool" :schema 'boolean)

(drgnx-defsetting drgnx-agents-start-env-names '("PLAYWRIGHT_MCP_CDP_ENDPOINT")
  "The environment variables an editor module may add to an agent the hub starts (`drgnx-agents-env-functions'), by
name.  The hub drops any other name, and any name that looks like a credential (it contains KEY, TOKEN, SECRET,
PASSWORD, PASSPHRASE or CREDENTIAL), whatever this lists.  Only you can set it, never a repository or an agent."
  :type '(repeat string) :group 'drgnx :scope 'global :workspace 'never :on-error 'strict :agents 'never
  :runtime "Vec<String>" :schema '(list-of string))

(cl-defstruct (drgnx-agent-session (:constructor drgnx-agents--make) (:copier nil))
  name profile cwd conn acp-id (status 'starting) entries queue (mode 'queue) capabilities usage commands
  permissions reviews stderr exit stopping paused turn draining task via gateway id job remote
  mcp-dir mcp-sid mcp-socket)           ; unused since the hub runs every session; kept so the shape stays

(defvar drgnx-agents--sessions nil "Live and finished sessions, newest first.")

(defvar drgnx-agents-changed-functions nil
  "Called with a session whenever it changes (status, transcript, queue, pending items).")

(defvar drgnx-agents-task-functions nil
  "Called with a session working on a task (a mirror's `task', `drgnx-agents-mirror') and `start', `turn-start' or
`turn-end': the work tracker records the commits each turn made (docs/guide/work.md).")

(defconst drgnx-agents-builtin-profiles
  (drgnx-settings-defaults-value 'drgnx-agents-builtin-profiles)
  "Profiles drgnx offers without setup; :ai names the provider environment the agent gets when it starts
\(`drgnx-ai-agent-env'); :job-safe, that a job may run it (`drgnx-job-safe-p': Claude Code, whose job sessions
ignore a repository's own settings).  Shipped in settings/runtime-defaults.el, which the hub reads too.")

;;;; The Claude Code adapter

(defconst drgnx-agents-claude-program "claude-agent-acp"
  "The Claude Code adapter's program, which the built-in claude profiles run (both packages below install it).")

(defconst drgnx-agents-claude-package "@agentclientprotocol/claude-agent-acp"
  "The npm package of the maintained Claude Code adapter: the one onboarding installs and the profiles prefer.")

(defconst drgnx-agents-claude-old-package "@zed-industries/claude-agent-acp"
  "The adapter's deprecated npm package (frozen at 0.23.1): it never says which MCP server a tool comes from.")

(defconst drgnx-agents-claude-min-version "0.93.0"
  "The oldest `drgnx-agents-claude-package' the doctor accepts: the version verified to send the tool's `mcpServer'.")

(defconst drgnx-agents--package-json-max 65536
  "The largest package.json drgnx reads, in bytes: the adapter's is about 2 KB; a bigger one is no package it knows.")

(defun drgnx-agents--package-json (dir)
  "(NAME . VERSION) of the package.json in DIR, or nil when there is none, it has no name, or it is not a regular
readable file of at most `drgnx-agents--package-json-max' bytes (a FIFO would block the read).  VERSION may be nil."
  (let ((file (expand-file-name "package.json" dir)))
    (when (and (file-regular-p file) (file-readable-p file)
               (<= (or (file-attribute-size (file-attributes file)) (1+ drgnx-agents--package-json-max))
                   drgnx-agents--package-json-max))
      (let ((json (ignore-errors
                    (with-temp-buffer
                      (insert-file-contents file nil 0 drgnx-agents--package-json-max)
                      (json-parse-buffer :object-type 'plist :null-object nil :false-object nil)))))
        (and (stringp (plist-get json :name))
             (cons (plist-get json :name) (and (stringp (plist-get json :version)) (plist-get json :version))))))))

(defun drgnx-agents--adapter-package (program)
  "The npm package the adapter PROGRAM (a path) belongs to: (:name :version :prefix), or nil.  A global npm install
links PROGRAM into the package (PREFIX/bin/claude-agent-acp → ../lib/node_modules/PKG/dist/index.js): the package is
where the link leads, under its last node_modules.  A program that is no link (a copy, a shim) is looked up at
../lib/node_modules/PKG beside it: when exactly one of the two packages is there, it is that one; with both there it
cannot tell (nil).  :prefix is PREFIX for such a global layout, else nil (pnpm, volta, a project's node_modules).
Reads files only: nothing is run."
  (let* ((true (file-truename program))
         (dir (if (string-match "\\`\\(.*/node_modules/\\(?:@[^/]+/\\)?[^/]+\\)/" true)
                  (match-string 1 true)
                (let ((found (seq-filter #'drgnx-agents--package-json
                                         (mapcar (lambda (pkg) (expand-file-name (concat "../lib/node_modules/" pkg) (file-name-directory true)))
                                                 (list drgnx-agents-claude-package drgnx-agents-claude-old-package)))))
                  (and (null (cdr found)) (car found)))))
         (json (and dir (drgnx-agents--package-json dir))))
    (when json
      (list :name (car json) :version (cdr json)
            :prefix (and (string-match "\\`\\(.+\\)/lib/node_modules/\\(?:@[^/]+/\\)?[^/]+\\'" dir) (match-string 1 dir))))))

(defun drgnx-agents-claude-adapter ()
  "The Claude Code adapter the claude profiles run: the first `claude-agent-acp' on `exec-path' that is the maintained
package, else the first one there — (:program PATH :name :version :prefix), without :name when drgnx cannot tell its
package (`drgnx-agents--adapter-package') — or nil when there is none.  Reads files only."
  (let ((all (delq nil (mapcar (lambda (d)
                                 (let ((f (expand-file-name drgnx-agents-claude-program d)))
                                   (and (file-executable-p f) (not (file-directory-p f))
                                        (cons :program (cons f (drgnx-agents--adapter-package f))))))
                               (delete-dups (seq-filter #'stringp exec-path))))))
    (or (seq-find (lambda (a) (equal (plist-get a :name) drgnx-agents-claude-package)) all) (car all))))

(defun drgnx-agents--npm-g (a verb package)
  "The command `npm VERB -g --prefix PREFIX PACKAGE' in adapter A's npm prefix, as text.  A prefix in HOME is
written with `~' unquoted, for the shell to expand; the rest of it is quoted."
  (let ((prefix (abbreviate-file-name (directory-file-name (plist-get a :prefix)))))
    (format "npm %s -g --prefix %s %s" verb
            (cond ((equal prefix "~") "~")
                  ((string-prefix-p "~/" prefix) (concat "~/" (shell-quote-argument (substring prefix 2))))
                  (t (shell-quote-argument prefix)))
            package)))

(defun drgnx-agents-adapter-advice (a)
  "What to do about adapter A when drgnx can name no global npm prefix for it (an unknown package, pnpm, volta, a
project's node_modules): a sentence, not a command."
  (format "replace %s with %s %s or newer, using the tool that installed it (drgnx can name no global npm prefix for it)"
          (abbreviate-file-name (plist-get a :program)) drgnx-agents-claude-package drgnx-agents-claude-min-version))

(defun drgnx-agents--version-ok-p (version)
  "Is VERSION (a string or nil) `drgnx-agents-claude-min-version' or newer?  A pre-release or build suffix
\(-rc.1, +build) is dropped first: 0.93.1-rc.1 counts as 0.93.1.  What cannot be read is not new enough."
  (and (stringp version)
       (ignore-errors (not (version< (replace-regexp-in-string "[-+].*\\'" "" version) drgnx-agents-claude-min-version)))))

(defun drgnx-agents-adapter-problem (a)
  "What is wrong with the adapter A (`drgnx-agents-claude-adapter'), as (WHY . FIX); nil when A is the maintained
package at `drgnx-agents-claude-min-version' or newer, or when drgnx cannot tell A's package.  FIX is one shell
command line in A's global npm prefix — the deprecated package uninstalled first there, as npm will not install
over another package's program — or, with no such prefix, `drgnx-agents-adapter-advice'."
  (let ((name (plist-get a :name)) (version (plist-get a :version)) (prefix (plist-get a :prefix)))
    (cond
     ((equal name drgnx-agents-claude-old-package)
      (cons (format "%s is the deprecated %s %s, which never tells drgnx which MCP server a tool comes from (the jobs permission check then goes by names only)"
                    (abbreviate-file-name (plist-get a :program)) name (or version "(no version)"))
            (if (not prefix) (drgnx-agents-adapter-advice a)
              (concat (drgnx-agents--npm-g a "uninstall" drgnx-agents-claude-old-package) " && "
                      (drgnx-agents--npm-g a "install" drgnx-agents-claude-package)))))
     ((and (equal name drgnx-agents-claude-package) (not (drgnx-agents--version-ok-p version)))
      (cons (format "%s is %s %s, older than %s (or no version drgnx can read)"
                    (abbreviate-file-name (plist-get a :program)) name (or version "(no version)") drgnx-agents-claude-min-version)
            (if (not prefix) (drgnx-agents-adapter-advice a)
              (drgnx-agents--npm-g a "install" (concat drgnx-agents-claude-package "@latest"))))))))

(defvar drgnx-agents--old-adapter-said nil
  "Whether this Emacs has said that the claude profiles run the deprecated adapter (it says so once).")

(defun drgnx-agents-command (command)
  "The agent COMMAND (a list) as it is started.  A bare `claude-agent-acp' becomes the adapter
`drgnx-agents-claude-adapter' chooses (the maintained package first); when that is the deprecated package it still
runs, and the first time in this Emacs a message says how to move.  Any other command, a path, or an adapter that is
not installed (starting it says so) is left as it is."
  (let ((a (and (equal (car command) drgnx-agents-claude-program) (drgnx-agents-claude-adapter))))
    (if (not a) command
      (when (and (equal (plist-get a :name) drgnx-agents-claude-old-package) (not drgnx-agents--old-adapter-said))
        (setq drgnx-agents--old-adapter-said t)
        (let ((problem (drgnx-agents-adapter-problem a)))
          (message "drgnx: %s — to move to the maintained adapter: %s" (car problem) (cdr problem))))
      (cons (plist-get a :program) (cdr command)))))

(defun drgnx-agents-profile (name)
  (or (assoc name (default-value 'drgnx-agents-profiles))
      (assoc name drgnx-agents-builtin-profiles)
      (user-error "No agent profile %s" name)))

(defun drgnx-agents-profile-names ()
  (delete-dups (mapcar #'car (append (default-value 'drgnx-agents-profiles) drgnx-agents-builtin-profiles))))

(defun drgnx-agents-default-profile ()
  "The profile New Agent Session offers on Return: `drgnx-agents-default' when it names a profile, else claude."
  (let ((d (default-value 'drgnx-agents-default)))
    (if (and (stringp d) (member d (drgnx-agents-profile-names))) d "claude")))

(defun drgnx-agents-route (role)
  "ROLE's profiles from `drgnx-agents-routes', in order (the first is used; the rest are its fallbacks); claude when
the setting names none for ROLE."
  (let ((r (alist-get role (default-value 'drgnx-agents-routes))))
    (cond ((null r) (list "claude")) ((listp r) r) (t (list r)))))

(defun drgnx-agents-mcp-names ()
  "The MCP servers agents get, from `drgnx-agents-mcp' (`coordination', `search'): the coordination tools alone
until it says otherwise."
  (default-value 'drgnx-agents-mcp))

(defun drgnx-agents-set-setting (key value)
  "Save VALUE as KEY (`:profiles', `:default', `:mcp', `:routes', `:openrouter') in settings.el, and apply it at
once: only that entry changes, comments and the rest stay.  A settings.el with a mistake is a
`drgnx-settings-refused' (a `user-error') and is not changed."
  (unless (memq key '(:profiles :default :mcp :routes :openrouter))
    (user-error "No agent setting %s" key))
  (drgnx-settings-defaults-save (intern (concat "drgnx-agents-" (substring (symbol-name key) 1))) value))

(defvar drgnx-settings-apply-problems)

(defun drgnx-agents-openrouter-restrictions ()
  "Which providers OpenRouter may use for the agents' requests, from `drgnx-agents-openrouter': (:only SLUGS
:ignore SLUGS :data-collection deny|allow :zdr t), each only when set, or nil.  A settings.el that does not read, or
an entry of it that did not apply (a value that is not a restriction), is a `user-error' naming it: OpenRouter agents
do not start until it is fixed, and a typo never turns a restriction off.  One setting for every OpenRouter route; it
applies through the gateway only."
  (when-let* ((p (or (drgnx-config-problem 'settings)
                     (and (boundp 'drgnx-settings-apply-problems)
                          (seq-find (lambda (p) (eq (plist-get p :var) 'drgnx-agents-openrouter))
                                    drgnx-settings-apply-problems)))))
    (user-error "%s has a mistake (line %s: %s): OpenRouter agents do not start until it is fixed"
                (abbreviate-file-name (or (plist-get p :file) "settings.el")) (plist-get p :line) (plist-get p :text)))
  (let ((raw (default-value 'drgnx-agents-openrouter)))
    (drgnx-agents--openrouter-check raw)
    (when (proper-list-p raw)
      (let ((only (drgnx-agents--openrouter-slugs (plist-get raw :only)))
            (ignore (drgnx-agents--openrouter-slugs (plist-get raw :ignore)))
            (dc (let ((v (plist-get raw :data-collection))) (if (stringp v) (intern v) v)))
            (out nil))
        (when (eq (plist-get raw :zdr) t) (setq out (list :zdr t)))
        (when (memq dc '(deny allow)) (setq out (nconc (list :data-collection dc) out)))
        (when ignore (setq out (nconc (list :ignore ignore) out)))
        (when only (setq out (nconc (list :only only) out)))
        out))))

(defun drgnx-agents--openrouter-json (restrictions)
  "RESTRICTIONS as a hub call carries them (vectors for lists, a string for the symbol)."
  (append (and (plist-get restrictions :only) (list :only (vconcat (plist-get restrictions :only))))
          (and (plist-get restrictions :ignore) (list :ignore (vconcat (plist-get restrictions :ignore))))
          (and (plist-get restrictions :data-collection)
               (list :data-collection (symbol-name (plist-get restrictions :data-collection))))
          (and (plist-get restrictions :zdr) (list :zdr t))))

(defun drgnx-agents--changed (s)
  (drgnx-agents--note-attention)
  (run-hook-with-args 'drgnx-agents-changed-functions s))

;;;; What waits on you: the `agents' set of the one "needs you" count

(defvar drgnx-agents--attention-seen nil
  "What `drgnx-agents--note-attention' last noted: one (SESSION PERMS . REVIEWS) per session, in the order of
`drgnx-agents--sessions'; PERMS and REVIEWS are copies of its lists (nil for an exited session).")

(defun drgnx-agents--same-items-p (a b)
  "Non-nil if lists A and B hold the same objects (`eq'), in order; allocates nothing."
  (while (and a b (eq (car a) (car b))) (setq a (cdr a) b (cdr b)))
  (and (null a) (null b)))

(defun drgnx-agents--attention-same-p ()
  "Non-nil if no session came or went, and none's permissions or edits to review changed, since the last note."
  (let ((ss drgnx-agents--sessions) (seen drgnx-agents--attention-seen) (same t))
    (while (and same ss seen)
      (let* ((s (car ss)) (e (car seen)) (live (not (eq (drgnx-agent-session-status s) 'exited))))
        (setq same (and (eq s (car e))
                        (drgnx-agents--same-items-p (and live (drgnx-agent-session-permissions s)) (cadr e))
                        (drgnx-agents--same-items-p (and live (drgnx-agent-session-reviews s)) (cddr e)))
              ss (cdr ss) seen (cdr seen))))
    (and same (null ss) (null seen))))

(defun drgnx-agents--note-attention ()
  "Give the notice model the `agents' set: each live session's pending permissions and edits to review.
Called on every change of a session (`drgnx-agents--changed', a mirror's too), so a streamed chunk costs a walk that
allocates nothing; the set is built only when a list changed.  A review's path is the agent's: it is abbreviated
with no file name handler."
  (unless (drgnx-agents--attention-same-p)
    (let ((seen nil) (items nil))
      (dolist (s drgnx-agents--sessions)
        (let* ((live (not (eq (drgnx-agent-session-status s) 'exited)))
               (perms (and live (drgnx-agent-session-permissions s)))
               (reviews (and live (drgnx-agent-session-reviews s)))
               (sid (drgnx-agent-session-id s)) (name (drgnx-agent-session-name s)) (job (drgnx-agent-session-job s)))
          (push (cons s (cons (copy-sequence perms) (copy-sequence reviews))) seen)
          (dolist (p perms)
            (push (list :id (cons 'permission (cons sid (plist-get p :id)))
                        :text (format "%s asks: %s" name (or (plist-get p :title) "permission"))
                        :command 'agents-answer :scope job)
                  items))
          (dolist (r reviews)
            (push (list :id (cons 'review (cons sid (plist-get r :id)))
                        :text (format "%s wants to write %s" name
                                      (let ((path (plist-get r :path)) (file-name-handler-alist nil))
                                        (if (stringp path) (abbreviate-file-name path) "a file")))
                        :command 'agents-view :scope job)
                  items))))
      (setq drgnx-agents--attention-seen (nreverse seen))
      (drgnx-notice-set 'agents (nreverse items)))))

;;;; Transcript

(defun drgnx-agents--add (s entry)
  (setf (drgnx-agent-session-entries s) (append (drgnx-agent-session-entries s) (list entry))))

(defun drgnx-agents--append-text (s type text)
  "Add TEXT to the last entry when it is of TYPE (a streamed chunk), else start an entry.
A chunk is kept, not joined: the running entry's :chunks (newest first) and :length grow, so a chunk costs a cons
whatever the answer's size.  `drgnx-agents-entry-text' joins them when the text is read."
  (let ((last (car (last (drgnx-agent-session-entries s)))))
    (if (and last (eq (plist-get last :type) type) (not (plist-get last :done)))
        (progn (plist-put last :length (+ (drgnx-agents-entry-length last) (length text)))
               (plist-put last :chunks (cons text (plist-get last :chunks))))
      (drgnx-agents--add s (list :type type :text text :chunks nil :length (length text))))))

(defun drgnx-agents-entry-length (e)
  "The length of entry E's text (an `agent' or `thought' entry: its chunks included) without joining it."
  (or (plist-get e :length) (length (or (plist-get e :text) ""))))

(defun drgnx-agents-entry-text (e)
  "Entry E's whole text.  A running answer's chunks are joined into its :text once, kept until the next chunk."
  (let ((chunks (plist-get e :chunks)))
    (when chunks
      (plist-put e :text (apply #'concat (or (plist-get e :text) "") (reverse chunks)))
      (plist-put e :chunks nil))
    (plist-get e :text)))

(defun drgnx-agents-entry-tail (e from)
  "Entry E's text from character FROM to its end, read from the newest chunks only (the joined :text only when they
do not reach back to FROM), or nil when the text is shorter than FROM."
  (let ((need (- (drgnx-agents-entry-length e) from)) (chunks (plist-get e :chunks)) (have 0) parts)
    (cond ((< need 0) nil)
          ((= need 0) "")
          (t (while (and chunks (< have need))
               (push (car chunks) parts)
               (setq have (+ have (length (car chunks))) chunks (cdr chunks)))
             (if (< have need)
                 (let ((text (or (plist-get e :text) "")))
                   (apply #'concat (substring text (- (length text) (- need have))) parts))
               (apply #'concat (substring (car parts) (- have need)) (cdr parts)))))))

(defun drgnx-agents-join-text (s)
  "Join the chunks of every entry of session S (`drgnx-agents-entry-text'): each :text is whole after."
  (dolist (e (drgnx-agent-session-entries s)) (when (plist-get e :chunks) (drgnx-agents-entry-text e))))

(defun drgnx-agents--find-tool (s id)
  (let (found)
    (cl-labels ((walk (es) (dolist (e es)
                             (when (and (eq (plist-get e :type) 'tool) (equal (plist-get e :id) id)) (setq found e))
                             (walk (plist-get e :children)))))
      (walk (drgnx-agent-session-entries s)))
    found))

(defun drgnx-agents--raw-url (u)
  "The url in update U's raw tool input (a string), or nil.  Only the url is kept: a Write's input is the whole file."
  (let ((url (plist-get (plist-get u :rawInput) :url))) (and (stringp url) url)))

(defun drgnx-agents--update (s u)
  (pcase (plist-get u :sessionUpdate)
    ;; chunks of a turn that Stop's deadline already ended are dropped
    ((and (or "agent_message_chunk" "agent_thought_chunk") (guard (drgnx-agent-session-draining s))) nil)
    ("agent_message_chunk" (drgnx-agents--append-text s 'agent (or (plist-get (plist-get u :content) :text) "")))
    ("agent_thought_chunk" (drgnx-agents--append-text s 'thought (or (plist-get (plist-get u :content) :text) "")))
    ("usage_update" (setf (drgnx-agent-session-usage s) (list :used (plist-get u :used) :size (plist-get u :size)
                                                              :cost (plist-get u :cost))))
    ("user_message_chunk"
     ;; during a turn: our own prompt echoed (already in the transcript); otherwise a replayed session
     (unless (eq (drgnx-agent-session-status s) 'busy)
       (drgnx-agents--add s (list :type 'user :text (or (plist-get (plist-get u :content) :text) "")))))
    ("tool_call"
     (let ((e (list :type 'tool :id (plist-get u :toolCallId) :title (plist-get u :title) :kind (plist-get u :kind)
                    :status (plist-get u :status) :content (plist-get u :content) :url (drgnx-agents--raw-url u)))
           (parent (plist-get (plist-get u :_meta) :parentToolCallId)))
       (if-let* ((p (and parent (drgnx-agents--find-tool s parent))))
           (plist-put p :children (append (plist-get p :children) (list e)))
         (drgnx-agents--add s e))))
    ("tool_call_update"
     (when-let* ((e (drgnx-agents--find-tool s (plist-get u :toolCallId))))
       (dolist (k '(:status :title :content)) (when (plist-member u k) (plist-put e k (plist-get u k))))
       (when-let* ((url (drgnx-agents--raw-url u))) (plist-put e :url url))))
    ("plan"
     (let ((last (seq-find (lambda (e) (eq (plist-get e :type) 'plan)) (reverse (drgnx-agent-session-entries s)))))
       (if (and last (not (plist-get last :done))) (plist-put last :entries (plist-get u :entries))
         (drgnx-agents--add s (list :type 'plan :entries (plist-get u :entries))))))
    ("available_commands_update" (setf (drgnx-agent-session-commands s) (plist-get u :availableCommands))))
  (drgnx-agents--changed s))

(defun drgnx-agents-context-percent (s)
  "How full the agent's context is, in percent (from the last turn's usage), or nil."
  (let* ((u (drgnx-agent-session-usage s))
         (used (or (plist-get u :used) (plist-get u :inputTokens) (plist-get u :totalTokens)))
         (window (or (plist-get u :size) (plist-get u :contextWindow))))
    (and (numberp used) (numberp window) (> window 0) (min 100 (round (* 100.0 used) window)))))

;;;; The hub's sessions: what the editor asks of them

(defvar drgnx-agents-use-gateway t
  "Non-nil: an Ollama agent (a keyless profile) talks to the hub's gateway too; nil: it goes to Ollama directly.  For
keyed profiles (OpenRouter, Anthropic, Kimi, DeepSeek: `drgnx-ai-agent-keyed-p') it means nothing: only the hub holds
keys, so they always go through its gateway (a token, never a key).")

(defvar drgnx-agents-env-functions nil
  "Called with a session as its agent starts; each returns extra \"NAME=value\" strings for the agent's environment
(the Live browser's endpoint, docs/guide/live.md).  One that fails is reported and skipped, and so is anything
returned that is not a string.  Only names on `drgnx-agents-start-env-names' reach the agent.")

(drgnx-defsetting drgnx-agents-scrubbed-env (copy-sequence drgnx-agent-config-vendor-env)
  "Keys never inherited by agents: variables of Emacs's environment that an agent does not get.
MCP Test and Hook Test on the Agent Settings page unset the same list (drgnx-agent-check.el).
An agent gets the variables of its own route (the provider key or the gateway token, the model names) and
nothing else from this list, so a Kimi agent never sees your DeepSeek or OpenRouter key.  A profile without a
route (`:ai') is the user's own login and also keeps its own vendor's names (`drgnx-agents-own-env').  To pass
another one on, remove it from this list (or set it in the profile's `:env')."
  :type '(repeat string) :group 'drgnx :scope 'global :workspace 'never :agents 'never)

(drgnx-defsetting drgnx-agents-own-env
  '((claude "ANTHROPIC_API_KEY" "ANTHROPIC_AUTH_TOKEN" "ANTHROPIC_BASE_URL" "ANTHROPIC_MODEL"
            "ANTHROPIC_SMALL_FAST_MODEL" "ANTHROPIC_DEFAULT_HAIKU_MODEL" "ANTHROPIC_DEFAULT_SONNET_MODEL"
            "ANTHROPIC_DEFAULT_OPUS_MODEL" "ANTHROPIC_DEFAULT_FABLE_MODEL" "CLAUDE_CODE_SUBAGENT_MODEL"
            "CLAUDE_CODE_OAUTH_TOKEN" "CLAUDE_CODE_USE_BEDROCK" "CLAUDE_CODE_USE_VERTEX")
    (codex "OPENAI_API_KEY" "OPENAI_BASE_URL")
    (gemini "GEMINI_API_KEY" "GOOGLE_API_KEY"))
  "Each agent's own credentials and switches: (AGENT NAME…).  A profile without an `:ai' route runs on the user's
own login, so the names of its agent (by its command: claude, codex, gemini) are exempt from
`drgnx-agents-scrubbed-env' for it, and only for it.  `AWS_*' and `GOOGLE_APPLICATION_CREDENTIALS' are not scrubbed
at all."
  :type '(alist :key-type symbol :value-type (repeat string)) :group 'drgnx
  :scope 'global :workspace 'never :agents 'never)

(defun drgnx-agents-get (id) (seq-find (lambda (s) (equal (drgnx-agent-session-id s) id)) drgnx-agents--sessions))

(declare-function drgnx-hub-call "drgnx-hub-client")

(defun drgnx-agents--remote (s method params)
  "Ask the hub to do METHOD (with PARAMS) on mirror S's session; asynchronous, never waits.  An error is the reply to
the command that asked (stop, answer, send): said in the echo area each time."
  (require 'drgnx-hub-client)
  (drgnx-hub-call method (append (list :id (drgnx-agent-session-remote s)) params)
                  (lambda (_r err)
                    (when err
                      (let ((text (format "agent %s: %s" (drgnx-agent-session-name s) err)))
                        (drgnx-notice-clear 'agents text)
                        (drgnx-notify 'agents 'warn text :id text :echo t))))))

(defun drgnx-agents-answer-permission (s item option-id)
  "Answer the pending permission ITEM of session S with OPTION-ID (nil: cancelled): it leaves S's list at once, and
the hub hears the answer when S is its session's mirror."
  (setf (drgnx-agent-session-permissions s) (delq item (drgnx-agent-session-permissions s)))
  (drgnx-agents--changed s)
  (when (drgnx-agent-session-remote s)
    (drgnx-agents--remote s "agents/permission" (list :request (plist-get item :id) :option option-id))))

(defun drgnx-agents-finish-review (s item &optional reject)
  "Answer the agent's write request ITEM of session S: done (the user applied what they accepted) or REJECT.  It
leaves S's list at once, and the hub hears the answer when S is its session's mirror."
  (setf (drgnx-agent-session-reviews s) (delq item (drgnx-agent-session-reviews s)))
  (drgnx-agents--changed s)
  (when (drgnx-agent-session-remote s)
    (drgnx-agents--remote s "agents/do" (list :op "review" :item (plist-get item :id) :reject (and reject t)))))

(defun drgnx-agents-free-p (s)
  "Can mirror S take a new turn now (idle, not paused by a Stop, nothing queued)?"
  (and (drgnx-agent-session-remote s) (eq (drgnx-agent-session-status s) 'idle) (not (drgnx-agent-session-paused s))
       (null (drgnx-agent-session-queue s)) t))

(defun drgnx-agents-deliver (s text)
  "Give TEXT to mirror S as a new turn (`agents/send') if it is free (`drgnx-agents-free-p'); t when it did.  Never
queues, never steers, never interrupts, whatever S's mode — for drgnx's own deliveries."
  (when (drgnx-agents-free-p s) (drgnx-agents--remote s "agents/send" (list :text text)) t))

(defun drgnx-agents-steer (s text)
  "Put TEXT into mirror S's running turn: `agents/send', and the hub steers when the profile's mode is `steer' and
the agent can, else it queues TEXT for the turn's end.  t when S is busy under mode `steer' (the hub is asked to
steer), else nil."
  (when (drgnx-agent-session-remote s)
    (drgnx-agents--remote s "agents/send" (list :text text))
    (and (eq (drgnx-agent-session-status s) 'busy) (eq (drgnx-agent-session-mode s) 'steer))))

(defun drgnx-agents-send (s text)
  "Send TEXT to mirror S: the hub sends it now when the session is ready; when busy, it queues it (default), steers
the turn (mode `steer', when the agent can) or — only in mode `interrupt' — sends it after cancelling the turn."
  (when (drgnx-agent-session-remote s)
    (drgnx-agents--remote s "agents/send" (list :text text))))

(defun drgnx-agents-deliver-queue (s)
  "Send the queued messages a Stop held back."
  (when (drgnx-agent-session-remote s)
    (drgnx-agents--remote s "agents/do" (list :op "deliver-queue"))))

(defun drgnx-agents-unqueue (s n)
  "Remove the Nth queued message of S (before it is sent)."
  (when (drgnx-agent-session-remote s)
    (drgnx-agents--remote s "agents/do" (list :op "unqueue" :n n))))

(defun drgnx-agents-requeue (s n text)
  "Replace the Nth queued message of S with TEXT (empty: remove it)."
  (when (drgnx-agent-session-remote s)
    (drgnx-agents--remote s "agents/do" (list :op "requeue" :n n :text text))))

(defun drgnx-agents-stop (s &optional _why)
  "Cancel S's running turn: the hub ends it within a second; pending permission requests are answered cancelled and
pending edits rejected; queued messages wait (`drgnx-agents-deliver-queue')."
  (when (drgnx-agent-session-remote s)
    (drgnx-agents--remote s "agents/stop" nil)))

(defun drgnx-agents-kill (s)
  "End session S's agent process (in the hub)."
  (when (drgnx-agent-session-remote s)
    (drgnx-agents--remote s "agents/kill" nil)))

(defun drgnx-agents-sessions () drgnx-agents--sessions)

(provide 'drgnx-agents)
;;; drgnx-agents.el ends here
