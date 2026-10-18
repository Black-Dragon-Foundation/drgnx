;;; drgnx-agent-config-codex.el --- Codex's settings: MCP servers, hooks, skills, trusted projects, routes -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; What Codex has configured, read from its own files, and the edits drgnx makes to them.
;;
;; Where things live (checked against codex 0.163.0):
;; - User settings: CODEX_HOME/config.toml (CODEX_HOME, else ~/.codex).  Project settings: ROOT/.codex/config.toml and
;;   ROOT/.codex/hooks.json, which Codex reads only when the project is trusted (`[projects."ROOT"]' with
;;   `trust_level = "trusted"' in the user's config.toml); an untrusted project's files are still read and shown (items carry :inactive and a note says why), because trust
;;   gates the effect, not the display.
;; - MCP servers: `[mcp_servers.NAME]' with `command', `args', `env' (stdio) or `url', `bearer_token_env_var',
;;   `http_headers', `env_http_headers' (streamable HTTP; `sse' does not exist), and `enabled', `startup_timeout_sec',
;;   `enabled_tools' and more, which drgnx keeps when it edits a server.  `http_headers' (literal values) and
;;   `env_http_headers' (header -> the NAME of an environment variable) are kept apart: :headers holds the literal
;;   values (secrets), :env-headers the header names and :env-header-vars the variable names in the same order (names,
;;   not secrets, so they show as they are; a value that cannot be a variable name is also put in :headers, masked).
;; - Hooks: CODEX_HOME/hooks.json and ROOT/.codex/hooks.json, shaped like Claude Code's (`hooks' -> event -> groups with
;;   `matcher' and `hooks'); also inline `[[hooks.EVENT]]' tables in config.toml, shown read-only.
;; - Skills: SKILL.md files under ~/.agents/skills and ROOT/.agents/skills; off by an `[[skills.config]]' entry of the
;;   user's config.toml with the skill's `path' and `enabled = false' (absent = on).
;; - Rules: AGENTS.md in CODEX_HOME and in ROOT.
;; - Routes: Codex's own CLI with the ChatGPT login (`subscription'), and each `[profiles.NAME]' whose `model_provider' is
;;   OpenRouter, run as `codex --profile NAME'.  Codex 0.163 supports `wire_api = "responses"' only (`chat' is refused).
;;
;; Writing: TOML goes through `drgnx-toml-set-table' / `drgnx-toml-set-array-entry' and
;; `drgnx-agent-config-write-text' (parse check before and after, one backup, atomic, refused when the file changed since
;; it was read).  A table is rebuilt from the existing one with only the modelled keys replaced, so keys drgnx does not
;; know survive; comments inside a replaced table do not (the backup has them).  A rename or move is one write.  hooks.json
;; is edited the same way, keeping hook fields drgnx does not know.  Credential files (auth.json) are never opened.
;; See docs/develop/core.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-agent-config)
(require 'drgnx-toml)

(defconst drgnx-agent-config-codex-hook-events
  '("SessionStart" "UserPromptSubmit" "PreToolUse" "PermissionRequest" "PostToolUse" "Stop" "PreCompact" "PostCompact"
    "SessionEnd" "SubagentStart" "SubagentStop")
  "Codex's hook events (offered on the settings page; another name may be typed).")

(defconst drgnx-agent-config-codex--ignored "Codex ignores it until the project is trusted"
  "Why the items of an untrusted project do nothing.")

(defvar drgnx-agent-config-codex--texts nil
  "While reading: file name -> its text (or nil), for the line numbers of the items.")

(defvar drgnx-agent-config-codex--problems nil
  "While reading: the problems found, newest first.")

;;;; Where the files are

(defun drgnx-agent-config-codex--root (root)
  "ROOT as a directory name with a trailing slash, or nil."
  (and root (file-name-as-directory (expand-file-name root))))

(defun drgnx-agent-config-codex--config-file (scope root)
  "The config.toml of SCOPE (user or project); nil without a project for the latter."
  (pcase scope
    ('user (expand-file-name "config.toml" (drgnx-agent-config-home 'codex)))
    ('project (and root (expand-file-name ".codex/config.toml" root)))))

(defun drgnx-agent-config-codex--hooks-file (scope root)
  "The hooks.json of SCOPE (user or project); nil without a project for the latter."
  (pcase scope
    ('user (expand-file-name "hooks.json" (drgnx-agent-config-home 'codex)))
    ('project (and root (expand-file-name ".codex/hooks.json" root)))))

(defun drgnx-agent-config-codex--skills-dir (scope root)
  "The directory the skills of SCOPE (user or project) live in."
  (pcase scope
    ('user (expand-file-name ".agents/skills" "~"))
    ('project (and root (expand-file-name ".agents/skills" root)))))

;;;; Small helpers

(defun drgnx-agent-config-codex--text (file)
  "FILE's text (cached while reading), or nil."
  (let ((cached (and drgnx-agent-config-codex--texts (gethash file drgnx-agent-config-codex--texts :none))))
    (if (and cached (not (eq cached :none)))
        cached
      (let ((text (ignore-errors (drgnx-agent-config-read-text file))))
        (when drgnx-agent-config-codex--texts (puthash file (or text "") drgnx-agent-config-codex--texts))
        text))))

(defun drgnx-agent-config-codex--line-of (file regexp)
  "The line of FILE where REGEXP (matched with `^' at line starts) first matches, or nil."
  (when-let* ((text (drgnx-agent-config-codex--text file)))
    (when (string-match regexp text)
      (1+ (cl-count ?\n text :end (match-beginning 0))))))

(defun drgnx-agent-config-codex--put-key (alist key value)
  "ALIST with KEY set to VALUE: an existing member keeps its place, a new one goes last."
  (if (assoc key alist)
      (mapcar (lambda (c) (if (equal (car c) key) (cons key value) c)) alist)
    (append alist (list (cons key value)))))

(defun drgnx-agent-config-codex--drop-keys (alist keys)
  "ALIST without the members called one of KEYS."
  (cl-remove-if (lambda (c) (member (car c) keys)) alist))

(defun drgnx-agent-config-codex--table (value &rest keys)
  "The table at KEYS (strings) in the parsed TOML VALUE, or nil when it is not there or not a table."
  (dolist (k keys)
    (setq value (and (consp value) (consp (car value)) (cdr (assoc k value)))))
  value)

;;;; Reading TOML and JSON

(defun drgnx-agent-config-codex--problem (file line message)
  "Note a problem in FILE at LINE."
  (push (list file line message) drgnx-agent-config-codex--problems))

(defun drgnx-agent-config-codex--load-toml (file)
  "The parsed TOML of FILE; a file that is not there or does not parse gives nil (and a problem for the latter)."
  (when (and file (file-regular-p file))
    (condition-case err
        (drgnx-toml-parse (drgnx-agent-config-read-text file))
      ;; the parser's message quotes the file (a key, a value's characters): only the line is kept
      (drgnx-toml-error (drgnx-agent-config-codex--problem file (nth 1 err) "not valid TOML") nil)
      (error (drgnx-agent-config-codex--problem file nil "cannot be read") nil))))

(defun drgnx-agent-config-codex--load-json (file)
  "The parsed JSON of FILE, as `drgnx-agent-config-json-get' reads it; nil with a problem when it does not parse."
  (when (and file (file-regular-p file))
    (condition-case err
        (plist-get (drgnx-agent-config-json-read file) :value)
      (drgnx-agent-config-unreadable (push (cdr err) drgnx-agent-config-codex--problems) nil)
      (error (drgnx-agent-config-codex--problem file nil "cannot be read") nil))))

;;;; Trust

(defun drgnx-agent-config-codex--dir-key (dir)
  "DIR as a name to compare: absolute, no trailing slash."
  (directory-file-name (expand-file-name dir)))

(defun drgnx-agent-config-codex--git-root (dir)
  "The nearest directory at or above DIR that has a .git, or nil."
  (let ((dir (file-name-as-directory (expand-file-name dir))) found)
    (while (and dir (not found))
      (if (file-exists-p (expand-file-name ".git" dir))
          (setq found dir)
        (let ((parent (file-name-directory (directory-file-name dir))))
          (setq dir (and parent (not (equal parent dir)) parent)))))
    found))

(defun drgnx-agent-config-codex-trusted-p (root)
  "Non-nil when the user's config.toml marks the project ROOT (or its repository root) `trusted'."
  (and root
       (ignore-errors
         (let* ((config (drgnx-agent-config-codex--config-file 'user nil))
                (projects (and (file-regular-p config)
                               (drgnx-agent-config-codex--table
                                (drgnx-toml-parse (drgnx-agent-config-read-text config)) "projects")))
                (truename (file-truename root))
                (keys (mapcar #'drgnx-agent-config-codex--dir-key
                              (delq nil (list root truename (drgnx-agent-config-codex--git-root root)
                                              (drgnx-agent-config-codex--git-root truename))))))
           (cl-some (lambda (cell)
                      (and (equal (cdr (assoc "trust_level" (cdr cell))) "trusted")
                           (member (drgnx-agent-config-codex--dir-key (car cell)) keys)))
                    projects)))))

;;;; MCP servers, hooks, skills

(defun drgnx-agent-config-codex--mcp-spec (tbl)
  "The :spec of the server table TBL (nil when it is not a table)."
  (when (drgnx-agent-config-json-alist-p tbl)
    (let* ((get (lambda (key) (drgnx-agent-config-json-get tbl key)))
           (command (drgnx-agent-config-json-str (funcall get "command")))
           (url (drgnx-agent-config-json-str (funcall get "url")))
           (literal (drgnx-agent-config-json-string-alist (funcall get "http_headers")))
           (from-env (drgnx-agent-config-json-string-alist (funcall get "env_http_headers"))))
      (list :type (cond (command 'stdio) (url 'http))
            :command command
            :args (drgnx-agent-config-json-strings (funcall get "args"))
            :env (drgnx-agent-config-json-string-alist (funcall get "env"))
            :url url
            :headers (append literal
                             (cl-remove-if (lambda (p) (string-match-p "\\`[A-Za-z_][A-Za-z0-9_]*\\'" (cdr p))) from-env))
            :env-headers (mapcar #'car from-env)
            :env-header-vars (mapcar #'cdr from-env)
            :bearer-env (drgnx-agent-config-json-str (funcall get "bearer_token_env_var"))))))

(defun drgnx-agent-config-codex--server-items (parsed from file)
  "MCP items for the `mcp_servers' of the parsed config PARSED, from FROM, found in FILE."
  (let ((servers (drgnx-agent-config-codex--table parsed "mcp_servers")))
    (when (drgnx-agent-config-json-alist-p servers)
      (mapcar (lambda (cell)
                (let* ((name (car cell))
                       (spec (drgnx-agent-config-codex--mcp-spec (cdr cell)))
                       (quoted (regexp-quote name)))
                  (append (list :kind 'codex :section 'mcp :name name :from from :file file
                                :line (drgnx-agent-config-codex--line-of
                                       file (format "^[ \t]*\\[mcp_servers\\.\\(?:%s\\|\"%s\"\\)[] .]" quoted quoted))
                                :spec spec
                                :enabled (not (eq (drgnx-agent-config-json-get (cdr cell) "enabled") :false))
                                :readonly nil)
                          (unless spec (list :problem "not a server definition")))))
              servers))))

(defun drgnx-agent-config-codex--hook-items (hooks from file inline)
  "Hook items for the event map HOOKS (the `hooks' member of hooks.json or of config.toml), read from FILE.
INLINE: the hooks are tables in config.toml, which are shown but not edited here."
  (let (out)
    (when (drgnx-agent-config-json-alist-p hooks)
      (dolist (entry hooks)
        (let ((event (drgnx-agent-config-json-keystr (car entry))))
          (dolist (group (and (vectorp (cdr entry)) (append (cdr entry) nil)))
            (let ((matcher (drgnx-agent-config-json-str (drgnx-agent-config-json-get group "matcher")))
                  (members (drgnx-agent-config-json-get group "hooks")))
              (dolist (hook (and (vectorp members) (append members nil)))
                (let* ((type (or (drgnx-agent-config-json-str (drgnx-agent-config-json-get hook "type")) "command"))
                       (command (drgnx-agent-config-json-str (drgnx-agent-config-json-get hook "command")))
                       (timeout (drgnx-agent-config-json-get hook "timeout")))
                  (push (append
                         (list :kind 'codex :section 'hook
                               :name (if (and matcher (not (string-empty-p matcher))) (format "%s %s" event matcher) event)
                               :from from :file file
                               :line (drgnx-agent-config-codex--line-of
                                      file (if inline
                                               (format "^[ \t]*\\[\\[hooks\\.%s\\]\\]" (regexp-quote event))
                                             (format "\"%s\"[ \t\r\n]*:" (regexp-quote event))))
                               :spec (list :event event :matcher matcher :command command
                                           :timeout (and (numberp timeout) timeout) :hook-type type)
                               :enabled t
                               :readonly (or inline (not (and (equal type "command") command))))
                         (when inline
                           (list :note "Inline in config.toml: shown here, edit hooks.json instead")))
                        out))))))))
    (nreverse out)))

(defun drgnx-agent-config-codex--skill-key (path)
  "PATH (a skill's directory, or its SKILL.md) as a name to compare."
  (drgnx-agent-config-codex--dir-key (string-remove-suffix "SKILL.md" path)))

(defun drgnx-agent-config-codex--skill-entry-p (entry dir name)
  "Non-nil when the `[[skills.config]]' ENTRY (an alist) is about the skill NAME in DIR."
  (and (consp entry) (consp (car entry))
       (let ((path (cdr (assoc "path" entry))) (entry-name (cdr (assoc "name" entry))))
         (if (stringp path)
             (equal (drgnx-agent-config-codex--skill-key path) (drgnx-agent-config-codex--dir-key dir))
           (and (stringp entry-name) (equal entry-name name))))))

(defun drgnx-agent-config-codex--skill-entries (parsed)
  "The `[[skills.config]]' entries of PARSED as a list."
  (let ((entries (drgnx-agent-config-codex--table parsed "skills" "config")))
    (and (vectorp entries) (append entries nil))))

;;;; Routes

(defun drgnx-agent-config-codex--openrouter-provider-p (id provider)
  "Non-nil when the provider ID with the table PROVIDER is OpenRouter."
  (or (equal id "openrouter")
      (let ((url (cdr (assoc "base_url" provider))))
        (and (stringp url) (string-match-p "\\`https?://\\(?:[^/]*\\.\\)?openrouter\\.ai\\(?:[:/]\\|\\'\\)" url)))))

(defun drgnx-agent-config-codex--routes-of (parsed)
  "The routes for the parsed user config PARSED."
  (let ((providers (drgnx-agent-config-codex--table parsed "model_providers"))
        (profiles (drgnx-agent-config-codex--table parsed "profiles")))
    (cons (list :profile "codex" :kind nil :base-url nil
                :model (drgnx-agent-config-json-str (cdr (assoc "model" parsed)))
                :key-where "Codex's own ChatGPT login (drgnx never reads it)"
                :billing 'subscription :vendor "OpenAI" :launch "codex")
          (and (drgnx-agent-config-json-alist-p profiles)
               (cl-loop
                for cell in profiles
                for id = (drgnx-agent-config-json-str (drgnx-agent-config-json-get (cdr cell) "model_provider"))
                for provider = (and id (cdr (assoc id providers)))
                when (and id (drgnx-agent-config-codex--openrouter-provider-p id provider))
                collect (let ((env-key (drgnx-agent-config-json-str (cdr (assoc "env_key" provider)))))
                          (list :profile (car cell) :kind nil
                                :base-url (drgnx-agent-config-json-str (cdr (assoc "base_url" provider)))
                                :model (drgnx-agent-config-json-str (drgnx-agent-config-json-get (cdr cell) "model"))
                                :key-where (if env-key
                                               (format "%s (environment variable)" env-key)
                                             "no key variable set in the provider")
                                :billing 'openrouter :vendor "OpenRouter"
                                :launch (format "codex --profile %s" (car cell)))))))))

(defun drgnx-agent-config-codex-routes (_root)
  "The routes Codex can run: its own CLI with the ChatGPT login, then each profile that uses OpenRouter:
\((:profile NAME :kind nil :base-url URL :model MODEL :key-where STRING :billing BILLING :vendor NAME :launch COMMAND)…).
BILLING is `subscription' or `openrouter'.  :key-where says where the key is kept; no key is looked up."
  (let* ((config (drgnx-agent-config-codex--config-file 'user nil))
         (parsed (ignore-errors (and (file-regular-p config) (drgnx-toml-parse (drgnx-agent-config-read-text config))))))
    (drgnx-agent-config-codex--routes-of parsed)))

;;;; Reading

(cl-defmethod drgnx-agent-config-read ((_kind (eql 'codex)) root)
  (let ((drgnx-agent-config-codex--texts (make-hash-table :test #'equal))
        (drgnx-agent-config-codex--problems nil))
    (drgnx-agent-config-codex--read-all (drgnx-agent-config-codex--root root))))

(defun drgnx-agent-config-codex--read-all (root)
  "Everything Codex has configured for the project ROOT (see `drgnx-agent-config-read')."
  (let* ((home (drgnx-agent-config-home 'codex))
         (trusted (drgnx-agent-config-codex-trusted-p root))
         items notes rules user-config)
    (cl-flet ((add (new) (setq items (append items new))))
      (dolist (scope (if root '(user project) '(user)))
        (let* ((config (drgnx-agent-config-codex--config-file scope root))
               (hooks (drgnx-agent-config-codex--hooks-file scope root))
               (ignored (and (eq scope 'project) (not trusted)))
               (parsed (drgnx-agent-config-codex--load-toml config))
               (new (append (drgnx-agent-config-codex--server-items parsed scope config)
                            (drgnx-agent-config-codex--hook-items
                             (drgnx-agent-config-json-get (drgnx-agent-config-codex--load-json hooks) "hooks")
                             scope hooks nil)
                            (drgnx-agent-config-codex--hook-items
                             (drgnx-agent-config-codex--table parsed "hooks") scope config t))))
          (when (eq scope 'user) (setq user-config parsed))
          (when ignored
            (dolist (item new) (plist-put item :inactive drgnx-agent-config-codex--ignored))
            (dolist (file (list config hooks))
              (when (file-regular-p file)
                (push (format "%s: %s" file drgnx-agent-config-codex--ignored) notes))))
          (add new)))
      ;; skills
      (let ((entries (drgnx-agent-config-codex--skill-entries user-config)))
        (dolist (scope (if root '(user project) '(user)))
          (dolist (skill (drgnx-agent-config-skills-in (drgnx-agent-config-codex--skills-dir scope root) scope 'codex))
            (let ((dir (plist-get (plist-get skill :spec) :dir)) (name (plist-get skill :name)))
              (plist-put skill :enabled
                         (not (cl-some (lambda (e) (and (drgnx-agent-config-codex--skill-entry-p e dir name)
                                                        (eq (cdr (assoc "enabled" e)) :false)))
                                       entries)))
              (add (list skill)))))))
    ;; rules
    (setq rules (cl-remove-if-not #'file-regular-p
                                  (delq nil (list (expand-file-name "AGENTS.md" home)
                                                  (and root (expand-file-name "AGENTS.md" root))))))
    ;; a default provider other than the ChatGPT login
    (when-let* ((provider (drgnx-agent-config-json-str (cdr (assoc "model_provider" user-config)))))
      (push (format "%s sets model_provider = %s: that is Codex's default instead of your ChatGPT login"
                    (drgnx-agent-config-codex--config-file 'user nil) provider)
            notes))
    (list :rules rules :items items :problems (reverse drgnx-agent-config-codex--problems)
          :routes (drgnx-agent-config-codex--routes-of user-config)
          :notes (nreverse notes))))

(cl-defmethod drgnx-agent-config-scopes ((_kind (eql 'codex)) section root)
  (let ((root (drgnx-agent-config-codex--root root)))
    (pcase section
      ('mcp (append (list (list 'user "User (all projects)" (drgnx-agent-config-codex--config-file 'user root)))
                    (and root (list (list 'project "Project (.codex/config.toml, when trusted)"
                                          (drgnx-agent-config-codex--config-file 'project root))))))
      ('hook (append (list (list 'user "User (all projects)" (drgnx-agent-config-codex--hooks-file 'user root)))
                     (and root (list (list 'project "Project (.codex/hooks.json, when trusted)"
                                           (drgnx-agent-config-codex--hooks-file 'project root))))))
      ('skill (append (list (list 'user "User (all projects)" (drgnx-agent-config-codex--skills-dir 'user root)))
                      (and root (list (list 'project "Project" (drgnx-agent-config-codex--skills-dir 'project root))))))
      (_ (error "No such section: %S" section)))))

;;;; Writing TOML

(defun drgnx-agent-config-codex--parse (file text)
  "Parse TEXT, the TOML of FILE; a failure signals `drgnx-agent-config-unreadable' (FILE LINE MESSAGE)."
  (condition-case err
      (drgnx-toml-parse text)
    (drgnx-toml-error (signal 'drgnx-agent-config-unreadable (list file (nth 1 err) (nth 2 err))))))

(defun drgnx-agent-config-codex--modify-toml (file function)
  "Replace the text of the TOML FILE (empty when absent) with (FUNCTION TEXT), TEXT being what FILE holds now.
FILE is parsed first (a file that does not parse is never written), and read again before a second try when it
changed meanwhile; a second change signals `drgnx-agent-config-changed'.  A change the TOML writer cannot make signals
an error that names FILE and a line, never the data.  Returns FILE."
  (let ((attempt 0) done)
    (while (not done)
      (setq attempt (1+ attempt))
      (let* ((exists (file-exists-p file))
             (text (if exists (drgnx-agent-config-read-text file) ""))
             (new (progn
                    (drgnx-agent-config-codex--parse file text)
                    (condition-case err
                        (funcall function text)
                      (drgnx-toml-error
                       (error "The TOML in %s cannot take this change%s" file
                              (if (integerp (nth 1 err)) (format " (line %d)" (nth 1 err)) "")))))))
        (condition-case nil
            (progn
              (drgnx-agent-config-write-text
               file new
               (lambda (current) (drgnx-agent-config-codex--parse file current))
               (lambda (written) (drgnx-agent-config-codex--parse file written))
               (and exists text))
              (setq done t))
          (drgnx-agent-config-changed
           (when (>= attempt 2) (signal 'drgnx-agent-config-changed (list file)))))))
    file))

(defun drgnx-agent-config-codex--check-name (name)
  "Signal unless NAME can be an MCP server name (and cannot be read as a flag)."
  (unless (and (stringp name) (string-match-p "\\`[A-Za-z0-9_][A-Za-z0-9_-]*\\'" name))
    (error "A server name is letters, digits, - and _ (it cannot start with -)")))

(defconst drgnx-agent-config-codex--mcp-managed
  '("command" "args" "env" "url" "bearer_token_env_var" "http_headers" "env_http_headers")
  "The keys of a server table that drgnx sets from a spec; every other key is kept.")

(defun drgnx-agent-config-codex--texts-p (pairs)
  "Non-nil when PAIRS is an alist of (NAME . text)."
  (cl-every (lambda (p) (and (consp p) (stringp (car p)) (stringp (cdr p)))) pairs))

(defun drgnx-agent-config-codex--mcp-table (spec base)
  "The server table for SPEC: the modelled keys from SPEC, then the members of BASE (the table as it is now) that
drgnx does not model.  Signals when SPEC is not a server Codex can run."
  (let* ((command (plist-get spec :command))
         (url (plist-get spec :url))
         (type (or (plist-get spec :type) (cond (command 'stdio) (url 'http))))
         (kept (drgnx-agent-config-codex--drop-keys base drgnx-agent-config-codex--mcp-managed)))
    (pcase type
      ('stdio
       (unless (and (stringp command) (not (string-empty-p command))) (error "A stdio server needs a command"))
       (unless (cl-every #'stringp (plist-get spec :args)) (error "Arguments must be text"))
       (unless (drgnx-agent-config-codex--texts-p (plist-get spec :env))
         (error "A value of an environment variable must be text"))
       (append (list (cons "command" command))
               (and (plist-get spec :args) (list (cons "args" (vconcat (plist-get spec :args)))))
               (and (plist-get spec :env)
                    (list (cons "env" (mapcar (lambda (p) (cons (drgnx-agent-config-json-keystr (car p)) (cdr p)))
                                              (plist-get spec :env)))))
               kept))
      ('http
       (unless (and (stringp url) (not (string-empty-p url))) (error "An http server needs a URL"))
       (unless (drgnx-agent-config-codex--texts-p (plist-get spec :headers)) (error "A header value must be text"))
       (unless (or (null (plist-get spec :bearer-env)) (stringp (plist-get spec :bearer-env)))
         (error "The bearer token variable must be a name"))
       (unless (and (cl-every #'stringp (plist-get spec :env-headers))
                    (cl-every #'stringp (plist-get spec :env-header-vars))
                    (= (length (plist-get spec :env-headers)) (length (plist-get spec :env-header-vars))))
         (error "A header read from the environment needs the name of its variable"))
       (let* ((env-names (plist-get spec :env-headers))
              (literal (cl-remove-if (lambda (p) (member (car p) env-names)) (plist-get spec :headers)))
              (from-env (cl-mapcar #'cons env-names (plist-get spec :env-header-vars))))
         (append (list (cons "url" url))
                 (and (plist-get spec :bearer-env) (list (cons "bearer_token_env_var" (plist-get spec :bearer-env))))
                 (and literal (list (cons "http_headers" literal)))
                 (and from-env (list (cons "env_http_headers" from-env)))
                 kept)))
      ('sse (error "Codex runs stdio and streamable HTTP servers, not sse"))
      (_ (error "Unknown server type")))))

(defun drgnx-agent-config-codex--untrusted-note (scope root)
  "A sentence for the result of a write in SCOPE when ROOT is not trusted (else empty)."
  (if (and (eq scope 'project) (not (drgnx-agent-config-codex-trusted-p root)))
      "; Codex ignores it until the project is trusted"
    ""))

(defun drgnx-agent-config-codex--set-enabled (text name enabled)
  "TEXT with the `enabled' key of `[mcp_servers.NAME]' set to ENABLED, as a change of that one key: a missing key is
added under the header (switching off) or left missing (switching on), a `true' or `false' there changes its word
only.  Comments, quotes and spacing stay.  Returns nil when the table is not shaped so (no plain header, `enabled'
written some other way): the caller then rebuilds the table."
  (when-let* ((region (drgnx-toml-table-region text (list "mcp_servers" name)))
              (beg (car region))
              (own (substring text beg (cdr region)))
              (quoted (regexp-quote name))
              ((string-match (format "\\`[ \t]*\\[[ \t]*mcp_servers[ \t]*\\.[ \t]*\\(?:%s\\|\"%s\"\\)[ \t]*\\][ \t]*\\(?:#[^\n]*\\)?\r?\n"
                                     quoted quoted)
                             own)))
    (let* ((header-end (match-end 0))
           (body (substring own header-end))
           (keys-end (or (string-match "^[ \t]*\\[" body) (length body)))
           (keys (substring body 0 keys-end))
           (word (if enabled "true" "false")))
      (cond
       ((string-match "^\\([ \t]*enabled[ \t]*=[ \t]*\\)\\(?:true\\|false\\)\\(?:[ \t]*\\(?:#[^\n]*\\)?\\)?\r?$" keys)
        (let ((start (+ beg header-end (match-end 1))))
          (concat (substring text 0 start) word
                  (substring text (+ start (if (string-prefix-p "true" (substring keys (match-end 1))) 4 5))))))
       ((string-match-p "^[ \t]*enabled\\>" keys) nil)
       (enabled text)
       (t (concat (substring text 0 (+ beg header-end))
                  "enabled = false" (if (string-suffix-p "\r\n" (substring own 0 header-end)) "\r\n" "\n")
                  (substring text (+ beg header-end))))))))

(defun drgnx-agent-config-codex--write-mcp (op item scope root)
  "Add, edit, remove or switch the MCP server ITEM in SCOPE; returns the result."
  (let* ((name (plist-get item :name))
         (old (or (plist-get (plist-get item :replaces) :name) name))
         (spec (plist-get item :spec))
         (file (drgnx-agent-config-codex--config-file scope root)))
    (unless (memq scope '(user project)) (error "No such scope for an MCP server"))
    (unless file (error "This scope needs a project"))
    (drgnx-agent-config-codex--check-name name)
    (when (and (eq op 'edit) (not (equal old name))) (drgnx-agent-config-codex--check-name old))
    (when (memq op '(add edit)) (drgnx-agent-config-codex--mcp-table spec nil))
    (drgnx-agent-config-codex--modify-toml
     file
     (lambda (text)
       (let* ((servers (drgnx-agent-config-codex--table (drgnx-toml-parse text) "mcp_servers"))
              (here (assoc name servers))
              (previous (assoc old servers)))
         (pcase op
           ('add
            (when here (error "%s is already in this file" name))
            (drgnx-toml-set-table text (list "mcp_servers" name) (drgnx-agent-config-codex--mcp-table spec nil)))
           ('edit
            (unless previous (error "%s is not in this file" old))
            (when (and (not (equal old name)) here) (error "%s is already in this file" name))
            (drgnx-toml-set-table
             (if (equal old name) text (drgnx-toml-set-table text (list "mcp_servers" old) nil))
             (list "mcp_servers" name) (drgnx-agent-config-codex--mcp-table spec (cdr previous))))
           ('remove
            (unless here (error "%s is not in this file" name))
            (drgnx-toml-set-table text (list "mcp_servers" name) nil))
           ('toggle
            (unless here (error "%s is not in this file" name))
            (or (drgnx-agent-config-codex--set-enabled text name (not (plist-get item :enabled)))
                (drgnx-toml-set-table
                 text (list "mcp_servers" name)
                 (if (plist-get item :enabled)
                     (drgnx-agent-config-codex--put-key (cdr here) "enabled" :false)
                   (drgnx-agent-config-codex--drop-keys (cdr here) '("enabled"))))))
           (_ (error "No such operation"))))))
    (list :ok t :note (format "Wrote %s%s" file (drgnx-agent-config-codex--untrusted-note scope root)))))

;;;; Writing hooks.json

(defun drgnx-agent-config-codex--hook-position (value spec)
  "(GROUP-INDEX . HOOK-INDEX) of the command hook SPEC (:event :matcher :command) in the hooks.json VALUE, or nil."
  (let ((groups (append (drgnx-agent-config-json-get value "hooks" (plist-get spec :event)) nil)))
    (cl-loop for group in groups
             for gi from 0
             when (drgnx-agent-config-hook-matcher= group (plist-get spec :matcher))
             do (let ((pos (cl-position-if
                            (lambda (h)
                              (and (equal (or (drgnx-agent-config-json-get h "type") "command") "command")
                                   (equal (drgnx-agent-config-json-get h "command") (plist-get spec :command))))
                            (append (drgnx-agent-config-json-get group "hooks") nil))))
                  (when pos (cl-return (cons gi pos)))))))

(defun drgnx-agent-config-codex--hook-object (object spec)
  "The hook OBJECT (nil for a new one) with the command and timeout of SPEC; its other members stay."
  (let ((object (drgnx-agent-config-json-set (or object (list (cons 'type "command"))) '("command")
                                             (plist-get spec :command))))
    (if (numberp (plist-get spec :timeout))
        (drgnx-agent-config-json-set object '("timeout") (plist-get spec :timeout))
      (drgnx-agent-config-json-del object '("timeout")))))

(defun drgnx-agent-config-codex--hook-remove (value event position)
  "VALUE without the hook at POSITION ((GROUP . HOOK) indices) of EVENT; emptied groups and events go too."
  (let* ((groups (append (drgnx-agent-config-json-get value "hooks" event) nil))
         (group (nth (car position) groups))
         (hooks (append (drgnx-agent-config-json-get group "hooks") nil))
         (hooks (append (take (cdr position) hooks) (nthcdr (1+ (cdr position)) hooks))))
    (if hooks
        (setf (nth (car position) groups) (drgnx-agent-config-json-set group '("hooks") (vconcat hooks)))
      (setq groups (append (take (car position) groups) (nthcdr (1+ (car position)) groups))))
    (if groups
        (drgnx-agent-config-json-set value (list "hooks" event) (vconcat groups))
      (let ((without (drgnx-agent-config-json-del value (list "hooks" event))))
        (if (drgnx-agent-config-json-get without "hooks")
            without
          (drgnx-agent-config-json-del without '("hooks")))))))

(defun drgnx-agent-config-codex--hook-insert (value event matcher object)
  "VALUE with the hook OBJECT added to the group of EVENT with MATCHER (a new group when there is none)."
  (let* ((groups (append (drgnx-agent-config-json-get value "hooks" event) nil))
         (pos (cl-position-if (lambda (g) (drgnx-agent-config-hook-matcher= g matcher)) groups)))
    (if pos
        (setf (nth pos groups)
              (drgnx-agent-config-json-set
               (nth pos groups) '("hooks")
               (vconcat (drgnx-agent-config-json-get (nth pos groups) "hooks") (list object))))
      (setq groups (append groups
                           (list (append (and matcher (not (string-empty-p matcher)) (list (cons 'matcher matcher)))
                                         (list (cons 'hooks (vector object))))))))
    (drgnx-agent-config-json-set value (list "hooks" event) (vconcat groups))))

(defun drgnx-agent-config-codex--hooks-update (value old new)
  "The hooks.json VALUE with the hook OLD (a spec; nil for none) replaced by NEW (a spec; nil for none).
The hook object keeps its members drgnx does not model (`statusMessage', `async', ...); one that stays in its
event and matcher keeps its place."
  (let ((object nil) (in-place nil))
    (when old
      (let ((position (drgnx-agent-config-codex--hook-position value old)))
        (unless position (error "The hook was not found in this file"))
        (let* ((groups (append (drgnx-agent-config-json-get value "hooks" (plist-get old :event)) nil))
               (hooks (append (drgnx-agent-config-json-get (nth (car position) groups) "hooks") nil)))
          (setq object (nth (cdr position) hooks))
          (if (and new (equal (plist-get new :event) (plist-get old :event))
                   (equal (or (plist-get new :matcher) "") (or (plist-get old :matcher) "")))
              (let ((group (nth (car position) groups)))
                (setf (nth (cdr position) hooks) (drgnx-agent-config-codex--hook-object object new))
                (setf (nth (car position) groups) (drgnx-agent-config-json-set group '("hooks") (vconcat hooks)))
                (setq value (drgnx-agent-config-json-set value (list "hooks" (plist-get old :event)) (vconcat groups))
                      in-place t))
            (setq value (drgnx-agent-config-codex--hook-remove value (plist-get old :event) position))))))
    (if (and new (not in-place))
        (drgnx-agent-config-codex--hook-insert
         value (plist-get new :event) (plist-get new :matcher) (drgnx-agent-config-codex--hook-object object new))
      value)))

(defun drgnx-agent-config-codex--write-hook (op item scope root)
  "Add, edit or remove the hook ITEM in the hooks.json of SCOPE; returns the result."
  (let* ((file (drgnx-agent-config-codex--hooks-file scope root))
         (spec (plist-get item :spec))
         (previous (if (eq op 'add) nil (or (plist-get (plist-get item :replaces) :spec) spec))))
    (unless (memq scope '(user project)) (error "No such scope for a hook"))
    (unless file (error "This scope needs a project"))
    (when (eq op 'toggle) (error "A hook cannot be switched off here"))
    (when (memq op '(add edit))
      (unless (and (stringp (plist-get spec :event)) (string-match-p "\\`[A-Za-z]+\\'" (plist-get spec :event)))
        (error "A hook needs an event"))
      (unless (and (stringp (plist-get spec :command)) (not (string-empty-p (plist-get spec :command))))
        (error "A hook needs a command")))
    (drgnx-agent-config-json-modify
     file (lambda (value) (drgnx-agent-config-codex--hooks-update value previous (and (memq op '(add edit)) spec))))
    (list :ok t :note (format "Wrote %s%s; Codex may ask to re-approve changed hooks" file
                              (drgnx-agent-config-codex--untrusted-note scope root)))))

;;;; Writing skills

(defun drgnx-agent-config-codex--write-skill (op item scope root)
  "Add the skill ITEM to SCOPE, or switch it on or off in the user's config.toml; returns the result."
  (let ((name (plist-get item :name)))
    (pcase op
      ('add (let ((dir (drgnx-agent-config-codex--skills-dir scope root)))
              (unless dir (error "This scope needs a project"))
              (list :ok t :note (format "Created %s"
                                        (drgnx-agent-config-new-skill
                                         dir name (or (plist-get (plist-get item :spec) :description) ""))))))
      ('toggle
       (let* ((file (drgnx-agent-config-codex--config-file 'user nil))
              (dir (plist-get (plist-get item :spec) :dir))
              (pred (lambda (entry) (drgnx-agent-config-codex--skill-entry-p entry dir name))))
         (unless dir (error "The skill has no directory"))
         (drgnx-agent-config-codex--modify-toml
          file
          (lambda (text)
            (let ((entry (cl-find-if pred (drgnx-agent-config-codex--skill-entries (drgnx-toml-parse text)))))
              (cond
               ((plist-get item :enabled)
                (drgnx-toml-set-array-entry
                 text '("skills" "config") pred
                 (if entry
                     (drgnx-agent-config-codex--put-key entry "enabled" :false)
                   (list (cons "path" (expand-file-name "SKILL.md" dir)) (cons "enabled" :false)))))
               ((null entry) text)
               ((drgnx-agent-config-codex--drop-keys entry '("path" "name" "enabled"))
                (drgnx-toml-set-array-entry text '("skills" "config") pred
                                            (drgnx-agent-config-codex--put-key entry "enabled" t)))
               (t (drgnx-toml-set-array-entry text '("skills" "config") pred nil))))))
         (list :ok t :note (format "%s is now %s" name (if (plist-get item :enabled) "off" "on")))))
      (_ (error "Only adding a skill and switching one on or off are supported")))))

;;;; The OpenRouter route

(defconst drgnx-agent-config-codex--openrouter-provider
  '(("name" . "OpenRouter") ("base_url" . "https://openrouter.ai/api/v1")
    ("env_key" . "OPENROUTER_API_KEY") ("wire_api" . "responses"))
  "The provider table for OpenRouter (Codex 0.163 speaks the Responses API only).")

(defun drgnx-agent-config-codex--check-model (model)
  "Signal unless MODEL looks like an OpenRouter model slug."
  (unless (and (stringp model) (string-match-p "\\`[A-Za-z0-9][A-Za-z0-9._:/~+@-]*\\'" model))
    (error "A model is a slug such as vendor/model-name")))

(defun drgnx-agent-config-codex-openrouter-snippet (model)
  "The two tables of the OpenRouter route for MODEL as TOML text, to paste into config.toml."
  (drgnx-agent-config-codex--check-model model)
  (drgnx-toml-set-table
   (drgnx-toml-set-table "" '("model_providers" "openrouter") drgnx-agent-config-codex--openrouter-provider)
   '("profiles" "openrouter") (list (cons "model_provider" "openrouter") (cons "model" model))))

(defun drgnx-agent-config-codex-add-openrouter (model)
  "Write `[model_providers.openrouter]' and `[profiles.openrouter]' (for MODEL) into the user's config.toml.
Run as `codex --profile openrouter'; the default stays the ChatGPT login.  A provider table that exists keeps
every key it has (a different `base_url' or `env_key' is the user's, and the note says so); only `wire_api = \"chat\"',
which 0.163 refuses, becomes `responses'.  The profile gets `model_provider' and `model'.  Returns
\(:ok t :note STRING) or (:error STRING)."
  (condition-case err
      (let ((file (drgnx-agent-config-codex--config-file 'user nil)) kept chat)
        (drgnx-agent-config-codex--check-model model)
        (drgnx-agent-config-codex--modify-toml
         file
         (lambda (text)
           (let* ((parsed (drgnx-toml-parse text))
                  (provider (drgnx-agent-config-codex--table parsed "model_providers" "openrouter"))
                  (profile (drgnx-agent-config-codex--table parsed "profiles" "openrouter")))
             (setq kept nil chat nil)
             (dolist (pair drgnx-agent-config-codex--openrouter-provider)
               (let ((existing (assoc (car pair) provider)))
                 (cond ((null existing)
                        (setq provider (drgnx-agent-config-codex--put-key provider (car pair) (cdr pair))))
                       ((and (equal (car pair) "wire_api") (equal (cdr existing) "chat"))
                        (setq chat t provider (drgnx-agent-config-codex--put-key provider "wire_api" (cdr pair))))
                       ((and (member (car pair) '("base_url" "env_key")) (not (equal (cdr existing) (cdr pair))))
                        (push (car pair) kept)))))
             (setq profile (drgnx-agent-config-codex--put-key profile "model_provider" "openrouter")
                   profile (drgnx-agent-config-codex--put-key profile "model" model))
             (drgnx-toml-set-table
              (drgnx-toml-set-table text '("model_providers" "openrouter") provider)
              '("profiles" "openrouter") profile))))
        (list :ok t
              :note (concat (format "Added the OpenRouter route to %s: run it as codex --profile openrouter, with OPENROUTER_API_KEY set in the environment" file)
                            (and kept (format ". Kept your own %s in [model_providers.openrouter] (they differ from OpenRouter's)"
                                              (mapconcat #'identity (nreverse kept) " and ")))
                            (and chat ". Changed wire_api from chat to responses: Codex 0.163 refuses chat"))))
    (error (list :error (drgnx-agent-config-codex--error-text err nil)))))

;;;; The generic write

(defun drgnx-agent-config-codex--error-text (err item)
  "The message for the error ERR of a write of ITEM: where and why, never the item's data."
  (pcase (car err)
    ('drgnx-agent-config-unreadable
     (let ((data (cdr err)))
       (format "%s does not parse (line %s); nothing was written" (nth 0 data) (or (nth 1 data) "?"))))
    ('drgnx-agent-config-changed
     (format "%s was changed by another program while it was being written; nothing was written, try again" (cadr err)))
    ('error (drgnx-agent-config-mask-text (error-message-string err)
                                          (ignore-errors (drgnx-agent-config-secrets (plist-get item :spec)))))
    (_ (format "The settings could not be changed (%s); nothing was written" (car err)))))

(cl-defmethod drgnx-agent-config-write ((_kind (eql 'codex)) op item scope root callback)
  "Do OP (add, edit, remove or toggle) with ITEM in SCOPE for Codex; CALLBACK is called at once.
For an edit, ITEM carries the new definition and :replaces the item it replaces (the old name, or the old hook).
MCP servers: SCOPE user or project (config.toml); toggle sets `enabled'.  Hooks: user or project hooks.json.  Skills:
add to user or project; toggle writes `[[skills.config]]' in the user's config.toml.  Inline hooks are read-only."
  (let* ((root (drgnx-agent-config-codex--root root))
         (result
          (condition-case err
              (progn
                (when (and (plist-get item :readonly) (not (and (eq op 'toggle) (eq (plist-get item :section) 'skill))))
                  (error "This item is read-only here"))
                (pcase (plist-get item :section)
                  ('mcp (drgnx-agent-config-codex--write-mcp op item scope root))
                  ('hook (drgnx-agent-config-codex--write-hook op item scope root))
                  ('skill (drgnx-agent-config-codex--write-skill op item scope root))
                  (_ (error "No such section"))))
            (error (list :error (drgnx-agent-config-codex--error-text err item))))))
    (funcall callback result)
    nil))

(provide 'drgnx-agent-config-codex)
;;; drgnx-agent-config-codex.el ends here
