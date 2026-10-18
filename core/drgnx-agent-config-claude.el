;;; drgnx-agent-config-claude.el --- Claude Code's settings: MCP servers, hooks, skills, routes -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; What Claude Code has configured, read from its own files, and the edits drgnx makes to them.
;;
;; Where things live (checked against claude 2.1.302):
;; - MCP servers: user `mcpServers' and local `projects[ROOT].mcpServers' in the user file `.claude.json' (inside
;;   $CLAUDE_CONFIG_DIR when set, else directly in the home directory: not in ~/.claude), project ROOT/.mcp.json,
;;   plugins' servers (read-only), the managed `managed-mcp.json' (read-only).
;; - Hooks: `hooks' of settings.json in the Claude home (user), ROOT/.claude/settings.json (project),
;;   ROOT/.claude/settings.local.json (local) and the managed settings (read-only).
;; - Skills: SKILL.md files under HOME/skills, ROOT/.claude/skills and the enabled plugins; on or off by
;;   `skillOverrides' in a settings file (absent = on, "off" = off).
;; - Rules: CLAUDE.md files.
;;
;; Writing: user and local MCP servers go through `claude mcp add-json' / `claude mcp remove' (asynchronous, in the
;; project, 20 seconds at most; an edit is a remove, then an add).  A server with a secret in it never goes on a
;; command line: its entry is merged into the file directly (`drgnx-agent-config-claude--merge-entry').  Everything
;; else is a direct JSON edit that keeps key order and indent, keeps one backup, and refuses a file that changed since
;; it was read (Claude Code rewrites .claude.json every few seconds: the edit re-reads and tries once more).
;; Credential files are never opened.  See docs/develop/core.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'url-parse)
(require 'drgnx-agent-config)

(declare-function drgnx-agents-profile-names "drgnx-agents")
(declare-function drgnx-agents-profile "drgnx-agents")
(declare-function drgnx-ai-provider "drgnx-ai")
(declare-function drgnx-ai-agent-gateway-chain "drgnx-ai")

(defvar drgnx-agent-config-claude-managed-dir nil
  "The directory of Claude Code's managed settings and MCP servers; nil: the platform's own
\(/etc/claude-code, or /Library/Application Support/ClaudeCode on macOS).")

(defconst drgnx-agent-config-claude-hook-events
  '("PreToolUse" "PostToolUse" "PostToolUseFailure" "PostToolBatch" "PermissionRequest" "PermissionDenied"
    "UserPromptSubmit" "UserPromptExpansion" "Notification" "MessageDisplay" "Stop" "StopFailure" "SubagentStart"
    "SubagentStop" "PreCompact" "PostCompact" "SessionStart" "SessionEnd" "Setup" "PreModelSwitch" "PostModelSwitch"
    "TeammateIdle" "TaskCreated" "TaskCompleted" "Elicitation" "ElicitationResult" "ConfigChange" "InstructionsLoaded"
    "CwdChanged" "FileChanged" "WorktreeCreate" "WorktreeRemove" "DirectoryAdded")
  "Claude Code's hook events (offered on the settings page; another name may be typed).")

(defvar drgnx-agent-config-claude-cli-timeout 20
  "Seconds a `claude mcp' command may run before it is stopped.")

(defvar drgnx-agent-config-claude--texts nil
  "While reading: file name → a buffer with its text, for the line numbers of the items.")

;;;; Where the files are

(defun drgnx-agent-config-claude-json-file ()
  "Claude Code's user file: $CLAUDE_CONFIG_DIR/.claude.json when the variable is set, else ~/.claude.json."
  (expand-file-name ".claude.json" (or (drgnx-agent-config--env-dir "CLAUDE_CONFIG_DIR") "~")))

(defun drgnx-agent-config-claude--managed-dir ()
  "The managed settings directory (with a trailing slash)."
  (file-name-as-directory
   (or drgnx-agent-config-claude-managed-dir
       (if (eq system-type 'darwin) "/Library/Application Support/ClaudeCode" "/etc/claude-code"))))

(defun drgnx-agent-config-claude--root (root)
  "ROOT as a directory name with a trailing slash, or nil."
  (and root (file-name-as-directory (expand-file-name root))))

(defun drgnx-agent-config-claude--settings-file (scope root)
  "The settings file of SCOPE (user, project or local); nil without a project for the last two."
  (pcase scope
    ('user (expand-file-name "settings.json" (drgnx-agent-config-home 'claude)))
    ('project (and root (expand-file-name ".claude/settings.json" root)))
    ('local (and root (expand-file-name ".claude/settings.local.json" root)))))

(defun drgnx-agent-config-claude--skills-dir (scope root)
  "The directory the skills of SCOPE (user or project) live in."
  (pcase scope
    ('user (expand-file-name "skills" (drgnx-agent-config-home 'claude)))
    ('project (and root (expand-file-name ".claude/skills" root)))))

(defun drgnx-agent-config-claude--mcp-file (scope root)
  "The file the MCP servers of SCOPE (user, local or project) are in."
  (pcase scope
    ((or 'user 'local) (drgnx-agent-config-claude-json-file))
    ('project (and root (expand-file-name ".mcp.json" root)))))

(defun drgnx-agent-config-claude--project-key (root)
  "The key Claude Code files ROOT under in `projects': its name without the trailing slash."
  (directory-file-name (expand-file-name root)))

(defun drgnx-agent-config-claude--project-keys (root)
  "The keys ROOT may be filed under: as given, and with symbolic links resolved."
  (delete-dups (list (drgnx-agent-config-claude--project-key root)
                     (directory-file-name (file-truename root)))))

;;;; Where a member is in the file's text

(defun drgnx-agent-config-claude--line-of (file keys)
  "The line of FILE where the member path KEYS (strings) is, found by text; nil when not found."
  (when-let* ((buffer (or (gethash file drgnx-agent-config-claude--texts)
                          (puthash file (let ((buffer (generate-new-buffer " *drgnx-claude-text*" t)))
                                          (with-current-buffer buffer
                                            (ignore-errors (insert (drgnx-agent-config-read-text file))))
                                          buffer)
                                   drgnx-agent-config-claude--texts))))
    (with-current-buffer buffer
      (save-excursion
        (goto-char (point-min))
        (catch 'none
          (dolist (key keys)
            (unless (re-search-forward (concat "\"" (regexp-quote key) "\"[ \t\r\n]*:") nil t)
              (throw 'none nil)))
          (line-number-at-pos (match-beginning 0)))))))

;;;; MCP server entries

(defun drgnx-agent-config-claude--mcp-spec (json)
  "The :spec of the server entry JSON (nil when it is not an object)."
  (when (drgnx-agent-config-json-alist-p json)
    (let ((command (drgnx-agent-config-json-str (drgnx-agent-config-json-get json "command")))
          (url (drgnx-agent-config-json-str (drgnx-agent-config-json-get json "url")))
          (type (drgnx-agent-config-json-str (drgnx-agent-config-json-get json "type"))))
      (list :type (cond (type (intern type)) (command 'stdio) (url 'http))
            :command command
            :args (drgnx-agent-config-json-strings (drgnx-agent-config-json-get json "args"))
            :env (drgnx-agent-config-json-string-alist (drgnx-agent-config-json-get json "env"))
            :url url
            :headers (drgnx-agent-config-json-string-alist (drgnx-agent-config-json-get json "headers"))))))

(defun drgnx-agent-config-claude--spec-json (spec)
  "The entry Claude Code files for the server SPEC (a JSON object); signals when SPEC is not a server."
  (let* ((command (plist-get spec :command))
         (url (plist-get spec :url))
         (type (or (plist-get spec :type) (cond (command 'stdio) (url 'http)))))
    (pcase type
      ('stdio
       (unless (and (stringp command) (not (string-empty-p command))) (error "A stdio server needs a command"))
       (append (list (cons 'type "stdio") (cons 'command command))
               (and (plist-get spec :args) (list (cons 'args (vconcat (plist-get spec :args)))))
               (and (plist-get spec :env) (list (cons 'env (drgnx-agent-config-json-pairs (plist-get spec :env)))))))
      ((or 'http 'sse)
       (unless (and (stringp url) (not (string-empty-p url))) (error "An http or sse server needs a URL"))
       (append (list (cons 'type (symbol-name type)) (cons 'url url))
               (and (plist-get spec :headers)
                    (list (cons 'headers (drgnx-agent-config-json-pairs (plist-get spec :headers)))))))
      (_ (error "Unknown server type")))))

(defun drgnx-agent-config-claude--check-name (name)
  "Signal unless NAME can be an MCP server name (and cannot be read as a flag)."
  (unless (and (stringp name) (string-match-p "\\`[A-Za-z0-9_][A-Za-z0-9_.-]*\\'" name))
    (error "drgnx handles server names of letters, digits, '.', '-' and '_' (not starting with '-' or '.'); a name with other characters, such as spaces, is a drgnx limit: edit that server in Claude Code")))

(defconst drgnx-agent-config-claude--mcp-members '("type" "command" "args" "env" "url" "headers")
  "The members of an MCP server entry drgnx edits; any other (oauth, headersHelper, …) is kept as it is.")

(defconst drgnx-agent-config-claude--hook-members '("type" "command" "timeout")
  "The members of a hook drgnx edits; any other (statusMessage, async, shell, …) is kept as it is.")

(defun drgnx-agent-config-claude--merge-members (existing new keys)
  "The object EXISTING with the members KEYS (strings) taken from the object NEW: one NEW lacks is removed,
every other member of EXISTING stays where it is."
  (let ((object existing))
    (dolist (key keys object)
      (let ((cell (drgnx-agent-config-json-cell new key)))
        (setq object (if cell
                         (drgnx-agent-config-json-set object (list key) (cdr cell))
                       (drgnx-agent-config-json-del object (list key))))))))

(defun drgnx-agent-config-claude--extra-members-p (object keys)
  "Non-nil when the object OBJECT has a member that is not in KEYS."
  (and (drgnx-agent-config-json-alist-p object)
       (cl-some (lambda (c) (not (member (drgnx-agent-config-json-keystr (car c)) keys))) object)))

;;;; Reading

(defun drgnx-agent-config-claude--server-items (servers from file keys readonly &optional prefix)
  "MCP items for the object SERVERS from FROM, found in FILE under KEYS (for the line numbers)."
  (when (drgnx-agent-config-json-alist-p servers)
    (mapcar (lambda (cell)
              (let* ((name (drgnx-agent-config-json-keystr (car cell)))
                     (spec (drgnx-agent-config-claude--mcp-spec (cdr cell))))
                (append (list :kind 'claude :section 'mcp :name (concat prefix name) :from from :file file
                              :line (drgnx-agent-config-claude--line-of file (append keys (list name)))
                              :spec spec :enabled t :readonly readonly)
                        (unless spec (list :problem "not a server definition")))))
            servers)))

(defun drgnx-agent-config-claude--hook-items (value from file readonly)
  "Hook items for the `hooks' of the settings VALUE, read from FILE."
  (let ((hooks (drgnx-agent-config-json-get value "hooks")) out)
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
                  (push (list :kind 'claude :section 'hook
                              :name (if (and matcher (not (string-empty-p matcher))) (format "%s %s" event matcher) event)
                              :from from :file file
                              :line (drgnx-agent-config-claude--line-of file (list "hooks" event))
                              :spec (list :event event :matcher matcher :command command
                                          :timeout (and (numberp timeout) timeout) :hook-type type)
                              :enabled t
                              :readonly (or readonly (not (and (equal type "command") command))))
                        out))))))))
    (nreverse out)))

(defun drgnx-agent-config-claude--override (name settings)
  "The `skillOverrides' value for the skill NAME in SETTINGS ((SCOPE . VALUE)…): local, project, then user win."
  (cl-some (lambda (scope)
             (drgnx-agent-config-json-str
              (drgnx-agent-config-json-get (alist-get scope settings) "skillOverrides" name)))
           '(local project user)))

(defun drgnx-agent-config-claude--plugin-enabled-p (id settings)
  "Non-nil when the plugin ID is enabled by `enabledPlugins' in SETTINGS."
  (eq t (cl-some (lambda (scope)
                   (let ((cell (drgnx-agent-config-json-cell
                                (drgnx-agent-config-json-get (alist-get scope settings) "enabledPlugins") id)))
                     (and cell (cdr cell))))
                 '(local project user))))

(defun drgnx-agent-config-claude--plugin-path (records root)
  "The install path in the installed-plugins RECORDS (a vector, or one object) that applies to ROOT."
  (let ((key (and root (drgnx-agent-config-claude--project-key root))))
    (cl-some (lambda (rec)
               (let ((scope (drgnx-agent-config-json-str (drgnx-agent-config-json-get rec "scope")))
                     (project (drgnx-agent-config-json-str (drgnx-agent-config-json-get rec "projectPath"))))
                 (and (or (member scope '(nil "user" "managed"))
                          (and key project (equal (directory-file-name project) key)))
                      (drgnx-agent-config-json-str (drgnx-agent-config-json-get rec "installPath")))))
             (if (vectorp records) (append records nil) (list records)))))

(defun drgnx-agent-config-claude--env-overrides (env)
  "The names in the settings `env' object ENV that override a profile's route."
  (when (drgnx-agent-config-json-alist-p env)
    (cl-loop for cell in env
             for name = (drgnx-agent-config-json-keystr (car cell))
             when (string-match-p "\\`ANTHROPIC_\\(?:BASE_URL\\|MODEL\\|AUTH_TOKEN\\|API_KEY\\|SMALL_FAST_MODEL\\|DEFAULT_[A-Z_]*_MODEL\\)\\'"
                                  name)
             collect name)))

(cl-defmethod drgnx-agent-config-read ((_kind (eql 'claude)) root)
  (let ((drgnx-agent-config-claude--texts (make-hash-table :test #'equal)))
    (unwind-protect (drgnx-agent-config-claude--read-all root)
      (maphash (lambda (_file buffer) (kill-buffer buffer)) drgnx-agent-config-claude--texts))))

(defun drgnx-agent-config-claude--read-all (root)
  "Everything Claude Code has configured for the project ROOT (see `drgnx-agent-config-read')."
  (let* ((root (drgnx-agent-config-claude--root root))
         (home (drgnx-agent-config-home 'claude))
         (managed (drgnx-agent-config-claude--managed-dir))
         problems items notes rules)
    (cl-flet ((read-json (file)
                (when (and file (file-regular-p file))
                  (condition-case err
                      (plist-get (drgnx-agent-config-json-read file) :value)
                    (drgnx-agent-config-unreadable (push (cdr err) problems) nil)
                    (error (push (list file nil "cannot be read") problems) nil))))
              (add (new) (setq items (append items new))))
      (let* ((json-file (drgnx-agent-config-claude-json-file))
             (global (read-json json-file))
             (settings-files (mapcar (lambda (s) (cons s (drgnx-agent-config-claude--settings-file s root)))
                                     '(user project local)))
             (settings (mapcar (lambda (s) (cons (car s) (read-json (cdr s)))) settings-files))
             (managed-files (cons (expand-file-name "managed-settings.json" managed)
                                  (and (file-directory-p (expand-file-name "managed-settings.d" managed))
                                       (directory-files (expand-file-name "managed-settings.d" managed) t "\\.json\\'"))))
             (managed-values (mapcar (lambda (f) (cons f (read-json f))) managed-files))
             (plugins nil))
        ;; MCP servers
        (add (drgnx-agent-config-claude--server-items
              (drgnx-agent-config-json-get global "mcpServers") 'user json-file '("mcpServers") nil))
        (when root
          (let* ((projects (drgnx-agent-config-json-get global "projects"))
                 (key (cl-find-if (lambda (k) (drgnx-agent-config-json-cell projects k))
                                  (drgnx-agent-config-claude--project-keys root))))
            (when key
              (add (drgnx-agent-config-claude--server-items
                    (drgnx-agent-config-json-get projects key "mcpServers") 'local json-file
                    (list "projects" key "mcpServers") nil))))
          (let ((file (expand-file-name ".mcp.json" root)))
            (add (drgnx-agent-config-claude--server-items
                  (drgnx-agent-config-json-get (read-json file) "mcpServers") 'project file '("mcpServers") nil))))
        (let ((file (expand-file-name "managed-mcp.json" managed)))
          (add (drgnx-agent-config-claude--server-items
                (drgnx-agent-config-json-get (read-json file) "mcpServers") 'system file '("mcpServers") t)))
        ;; the enabled plugins
        (let* ((file (expand-file-name "plugins/installed_plugins.json" home))
               (installed (drgnx-agent-config-json-get (read-json file) "plugins")))
          (when (drgnx-agent-config-json-alist-p installed)
            (dolist (cell installed)
              (let ((id (drgnx-agent-config-json-keystr (car cell))))
                (when (drgnx-agent-config-claude--plugin-enabled-p id settings)
                  (when-let* ((path (drgnx-agent-config-claude--plugin-path (cdr cell) root)))
                    (push (cons (car (split-string id "@")) (file-name-as-directory (expand-file-name path))) plugins)))))
            (setq plugins (nreverse plugins))))
        (dolist (plugin plugins)
          (let* ((name (car plugin)) (dir (cdr plugin))
                 (mcp-file (expand-file-name ".mcp.json" dir))
                 (mcp (read-json mcp-file))
                 (manifest (expand-file-name ".claude-plugin/plugin.json" dir))
                 (servers (or (drgnx-agent-config-json-get mcp "mcpServers")
                              (and (not (drgnx-agent-config-json-cell mcp "mcpServers")) mcp))))
            (add (drgnx-agent-config-claude--server-items
                  servers 'plugin mcp-file (and (drgnx-agent-config-json-cell mcp "mcpServers") '("mcpServers")) t
                  (format "plugin:%s:" name)))
            (let ((declared (drgnx-agent-config-json-get (read-json manifest) "mcpServers")))
              (when (drgnx-agent-config-json-alist-p declared)
                (add (drgnx-agent-config-claude--server-items declared 'plugin manifest '("mcpServers") t
                                                              (format "plugin:%s:" name)))))))
        ;; hooks
        (dolist (s settings)
          (add (drgnx-agent-config-claude--hook-items (cdr s) (car s) (cdr (assq (car s) settings-files)) nil)))
        (dolist (m managed-values)
          (add (drgnx-agent-config-claude--hook-items (cdr m) 'system (car m) t)))
        ;; skills
        (dolist (spec (list (cons 'user (drgnx-agent-config-claude--skills-dir 'user root))
                            (cons 'project (drgnx-agent-config-claude--skills-dir 'project root))))
          (dolist (skill (and (cdr spec) (drgnx-agent-config-skills-in (cdr spec) (car spec) 'claude)))
            (let ((override (drgnx-agent-config-claude--override (plist-get skill :name) settings)))
              (plist-put skill :enabled (not (equal override "off")))
              (plist-put skill :spec (plist-put (plist-get skill :spec) :override override))
              (add (list skill)))))
        (dolist (plugin plugins)
          (dolist (skill (drgnx-agent-config-skills-in (expand-file-name "skills" (cdr plugin)) 'plugin 'claude))
            (let* ((qualified (format "%s:%s" (car plugin) (plist-get skill :name)))
                   (override (or (drgnx-agent-config-claude--override qualified settings)
                                 (drgnx-agent-config-claude--override (plist-get skill :name) settings))))
              (plist-put skill :name qualified)
              (plist-put skill :readonly t)
              (plist-put skill :enabled (not (equal override "off")))
              (plist-put skill :spec (plist-put (plist-get skill :spec) :override override))
              (add (list skill)))))
        ;; rules
        (setq rules (cl-remove-if-not
                     #'file-regular-p
                     (delq nil (list (expand-file-name "CLAUDE.md" home)
                                     (and root (expand-file-name "CLAUDE.md" root))
                                     (and root (expand-file-name ".claude/CLAUDE.md" root))))))
        ;; settings that override every profile's route (names only)
        (dolist (entry (append (mapcar (lambda (s) (cons (cdr (assq (car s) settings-files)) (cdr s))) settings)
                               managed-values))
          (when-let* ((names (drgnx-agent-config-claude--env-overrides
                              (drgnx-agent-config-json-get (cdr entry) "env"))))
            (push (format "%s sets %s in env: overrides every profile's route" (car entry) (mapconcat #'identity names ", "))
                  notes)))))
    (list :rules rules :items items :problems (nreverse problems)
          :routes (ignore-errors (drgnx-agent-config-claude-routes root))
          :notes (nreverse notes))))

(cl-defmethod drgnx-agent-config-scopes ((_kind (eql 'claude)) section root)
  (let ((root (drgnx-agent-config-claude--root root)))
    (pcase section
      ('mcp (append (list (list 'user "User (all projects)" (drgnx-agent-config-claude-json-file)))
                    (and root (list (list 'local "Local (this project, private)" (drgnx-agent-config-claude-json-file))
                                    (list 'project "Project (.mcp.json, shared)" (drgnx-agent-config-claude--mcp-file 'project root))))))
      ('hook (append (list (list 'user "User (all projects)" (drgnx-agent-config-claude--settings-file 'user root)))
                     (and root (list (list 'project "Project (shared)" (drgnx-agent-config-claude--settings-file 'project root))
                                     (list 'local "Local (this project, private)"
                                           (drgnx-agent-config-claude--settings-file 'local root))))))
      ('skill (append (list (list 'user "User (all projects)" (drgnx-agent-config-claude--skills-dir 'user root)))
                      (and root (list (list 'project "Project" (drgnx-agent-config-claude--skills-dir 'project root))))))
      (_ (error "No such section: %S" section)))))

;;;; Routes

(defun drgnx-agent-config-claude--loopback-p (url)
  "Non-nil when URL points at this machine."
  (let ((host (url-host (url-generic-parse-url url))))
    (and host (string-match-p "\\`\\(?:localhost\\|127\\.[0-9.]+\\|0\\.0\\.0\\.0\\|\\[?::1\\]?\\)\\'" host))))

(defun drgnx-agent-config-claude--route (name plist)
  "The route of the Claude Code profile NAME with the options PLIST."
  (let* ((kind (plist-get plist :ai))
         (first (and kind (car (drgnx-ai-agent-gateway-chain kind))))
         (id (car first))
         (provider (and id (drgnx-ai-provider id)))
         (model (or (plist-get plist :model) (cdr first)))
         (url (plist-get provider :url))
         (key-env (plist-get provider :key-env))
         (host (and url (url-host (url-generic-parse-url url)))))
    (list :profile name :kind kind
          :base-url (and url (string-remove-suffix "/v1" url))
          :model model
          :key-where (cond ((null kind) "Claude Code's own login (drgnx never reads it)")
                           (key-env (format "%s, else the keyring entry for %s" key-env host)))
          :billing (cond ((null kind) 'subscription)
                         ((eq id 'openrouter) 'openrouter)
                         ((and url (drgnx-agent-config-claude--loopback-p url)) 'local)
                         (t 'per-token))
          :vendor (cond ((null kind) "Anthropic")
                        (provider (plist-get provider :name))
                        (t (symbol-name kind))))))

(defun drgnx-agent-config-claude-routes (root)
  "One route per Claude Code profile (command claude-agent-acp), for the project ROOT:
\((:profile NAME :kind KIND :base-url URL :model MODEL :key-where STRING :billing BILLING :vendor NAME)…).
BILLING is `subscription' (no provider: Claude Code's own login), `openrouter', `local' (a loopback URL) or
`per-token' (a provider with a key).  :key-where says where the key is kept; no key is looked up."
  (require 'drgnx-agents)
  (require 'drgnx-ai)
  (let ((default-directory (if root (file-name-as-directory (expand-file-name root)) default-directory))
        out)
    (dolist (name (drgnx-agents-profile-names))
      (let* ((plist (cdr (ignore-errors (drgnx-agents-profile name))))
             (command (plist-get plist :command)))
        (when (and (stringp (car command)) (equal (file-name-nondirectory (car command)) "claude-agent-acp"))
          (push (drgnx-agent-config-claude--route name plist) out))))
    (nreverse out)))

;;;; Writing files

(defconst drgnx-agent-config-claude--project-defaults
  '((allowedTools . []) (mcpContextUris . []) (mcpServers) (enabledMcpjsonServers . []) (disabledMcpjsonServers . [])
    (hasTrustDialogAccepted . :false) (hasClaudeMdExternalIncludesApproved . :false)
    (hasClaudeMdExternalIncludesWarningShown . :false))
  "What Claude Code files for a project it has not met yet.")

(defun drgnx-agent-config-claude--merge-entry (file scope root name entry &optional old-name replace)
  "Put the server NAME (the JSON object ENTRY; nil removes it) into the MCP servers of SCOPE (user, local or
project) in FILE, re-reading FILE just before and changing nothing else in it.  OLD-NAME is the entry that ENTRY
replaces when the server is renamed.  The members of the existing entry that drgnx does not edit (oauth,
headersHelper, …) are kept, unless REPLACE.  Returns FILE."
  (drgnx-agent-config-json-modify
   file
   (lambda (value)
     (let* ((key (and (eq scope 'local)
                      (let ((projects (drgnx-agent-config-json-get value "projects")))
                        (or (cl-find-if (lambda (k) (drgnx-agent-config-json-cell projects k))
                                        (drgnx-agent-config-claude--project-keys root))
                            (drgnx-agent-config-claude--project-key root)))))
            (keys (if key (list "projects" key "mcpServers") (list "mcpServers")))
            (servers (apply #'drgnx-agent-config-json-get value keys))
            (renamed (and old-name (not (equal old-name name))))
            (base (or (cdr (drgnx-agent-config-json-cell servers name))
                      (and renamed (cdr (drgnx-agent-config-json-cell servers old-name)))))
            (entry (if (and entry (not replace) (drgnx-agent-config-json-alist-p base))
                       (drgnx-agent-config-claude--merge-members base entry drgnx-agent-config-claude--mcp-members)
                     entry)))
       (when (and entry key (not (drgnx-agent-config-json-cell (drgnx-agent-config-json-get value "projects") key)))
         (setq value (drgnx-agent-config-json-set value (list "projects" key) drgnx-agent-config-claude--project-defaults)))
       (when renamed
         (setq value (drgnx-agent-config-json-del value (append keys (list old-name)))))
       (if entry
           (drgnx-agent-config-json-set value (append keys (list name)) entry)
         (drgnx-agent-config-json-del value (append keys (list name))))))))

(defun drgnx-agent-config-claude--server-cell (file scope root name)
  "The member (NAME . ENTRY) of the MCP servers of SCOPE in FILE, or nil."
  (let* ((value (plist-get (drgnx-agent-config-json-read file) :value))
         (servers (if (eq scope 'local)
                      (let ((projects (drgnx-agent-config-json-get value "projects")))
                        (cl-some (lambda (k) (drgnx-agent-config-json-get projects k "mcpServers"))
                                 (drgnx-agent-config-claude--project-keys root)))
                    (drgnx-agent-config-json-get value "mcpServers"))))
    (drgnx-agent-config-json-cell servers name)))

(defvar drgnx-agent-config-claude--unrestored nil
  "Entries a failed claude edit removed and drgnx could not put back: ((FILE . NAME)…).  While a file is in it, its
backup (the only copy of the entry) is not replaced by the next command line write.")

(defun drgnx-agent-config-claude--forget-unrestored (file name)
  "NAME was written to FILE again: its backup need not be kept any longer."
  (setq drgnx-agent-config-claude--unrestored
        (cl-remove-if (lambda (p) (and (equal (car p) file) (equal (cdr p) name)))
                      drgnx-agent-config-claude--unrestored)))

;;;; Writing through the claude command

(defun drgnx-agent-config-claude--cli (argvs dir finish &optional completed)
  "Run each of ARGVS (argument lists for `claude') in DIR, one after the other, asynchronously.
FINISH gets (FAILURE COMPLETED): FAILURE is nil when all succeeded, else (missing), (start), (exit N) or (timeout);
COMPLETED is how many of ARGVS had succeeded."
  (let ((completed (or completed 0)))
    (if (null argvs)
        (funcall finish nil completed)
      (let ((program (executable-find "claude")))
        (if (not program)
            (funcall finish '(missing) completed)
          (let* ((default-directory dir)
                 (buffer (generate-new-buffer " *drgnx-claude*" t))
                 (done nil) timer process
                 (end (lambda (failure)
                        (unless done
                          (setq done t)
                          (when timer (cancel-timer timer))
                          (when (buffer-live-p buffer) (kill-buffer buffer))
                          (if failure
                              (funcall finish failure completed)
                            (drgnx-agent-config-claude--cli (cdr argvs) dir finish (1+ completed)))))))
            (condition-case nil
                (progn
                  (setq process
                        (make-process :name "drgnx-claude" :buffer buffer :command (cons program (car argvs))
                                      :connection-type 'pipe :noquery t
                                      :sentinel (lambda (p _event)
                                                  (when (memq (process-status p) '(exit signal))
                                                    (funcall end (unless (and (eq (process-status p) 'exit)
                                                                              (zerop (process-exit-status p)))
                                                                   (list 'exit (process-exit-status p))))))))
                  (ignore-errors (process-send-eof process))
                  (setq timer (run-at-time drgnx-agent-config-claude-cli-timeout nil
                                           (lambda ()
                                             (funcall end '(timeout))
                                             (when (process-live-p process) (delete-process process))))))
              (error (funcall end '(start))))))))))

(defun drgnx-agent-config-claude--cli-error (failure)
  "The message for FAILURE of a claude command."
  (pcase (car failure)
    ('missing "The claude command was not found: install Claude Code or put it on PATH")
    ('start "The claude command could not be started")
    ('timeout (format "The claude command did not finish within %s seconds" drgnx-agent-config-claude-cli-timeout))
    (_ (format "The claude command failed (exit status %s)" (cadr failure)))))

(defun drgnx-agent-config-claude--cli-result (failure completed op file scope root name old old-cell)
  "The result of the claude commands ARGVS for OP on NAME (OLD: the entry an edit replaces, OLD-CELL: what it held
before): when an edit's remove worked and its add did not, the old entry is put back by a direct write."
  (cond
   ((null failure)
    (drgnx-agent-config-claude--forget-unrestored file name)
    (list :ok t :note (format "%s %s (%s scope)" name (pcase op ('add "added") ('edit "changed") (_ "removed")) scope)))
   ((and (eq op 'edit) old-cell (>= completed 1))
    (let ((reason (drgnx-agent-config-claude--cli-error failure)))
      (if (condition-case nil
              (progn (drgnx-agent-config-claude--merge-entry file scope root old (cdr old-cell) nil t) t)
            (error nil))
          (list :error (format "%s: the change failed; the previous entry was put back" reason))
        (push (cons file old) drgnx-agent-config-claude--unrestored)
        (list :error (format "%s, and putting the previous entry back failed: the server is gone from %s, its backup (%s.drgnx-bak) has the entry"
                             reason file file)))))
   (t (list :error (drgnx-agent-config-claude--cli-error failure)))))

(defun drgnx-agent-config-claude--write-mcp (op item scope root callback)
  "Add, edit or remove the MCP server ITEM in SCOPE.  Returns the result for a direct write, nil when the claude
command is running (CALLBACK is called with its result)."
  (let* ((name (plist-get item :name))
         (old (or (plist-get (plist-get item :replaces) :name) name))
         (file (drgnx-agent-config-claude--mcp-file scope root))
         (scope-name (symbol-name scope)))
    (unless (memq scope '(user local project)) (error "No such scope for an MCP server"))
    (unless file (error "This scope needs a project"))
    (when (eq op 'toggle) (error "An MCP server cannot be switched off here"))
    (when (and (eq scope 'local) (null root)) (error "This scope needs a project"))
    (drgnx-agent-config-claude--check-name name)
    (when (and (eq op 'edit) (not (equal old name))) (drgnx-agent-config-claude--check-name old))
    (let* ((entry (and (memq op '(add edit)) (drgnx-agent-config-claude--spec-json (plist-get item :spec))))
           ;; `drgnx-agent-config-secrets' leaves out values of 3 characters or fewer (the model's rule): such a
           ;; value is not kept off the command line.
           (secret (and entry (drgnx-agent-config-secrets (plist-get item :spec))))
           (old-cell (and (memq op '(edit remove)) (not (eq scope 'project))
                          (drgnx-agent-config-claude--server-cell file scope root old)))
           ;; the entry has members drgnx does not edit: a command line would drop them
           (extras (and (eq op 'edit) old-cell
                        (drgnx-agent-config-claude--extra-members-p (cdr old-cell) drgnx-agent-config-claude--mcp-members))))
      (when (and (eq op 'add) (drgnx-agent-config-claude--server-cell file scope root name))
        (error "%s is already in this scope" name))
      (cond
       ;; a file edit: .mcp.json, or .claude.json when a command line would show a secret or drop members
       ((or (eq scope 'project) secret extras)
        (drgnx-agent-config-claude--merge-entry file scope root name entry (and (eq op 'edit) old))
        (when entry (drgnx-agent-config-claude--forget-unrestored file name))
        (list :ok t :note (if (eq scope 'project)
                              (format "Wrote %s" file)
                            (format "Wrote %s directly (%s). Restart running Claude sessions to pick this up" file
                                    (if secret "the server has a secret, which would show on a command line"
                                      "the entry has settings drgnx does not edit, which are kept")))))
       (t
        (let ((argvs (append (and (or (eq op 'remove) old-cell)
                                  (list (list "mcp" "remove" old "--scope" scope-name)))
                             (and entry
                                  (list (list "mcp" "add-json" name
                                              (decode-coding-string (json-serialize entry) 'utf-8)
                                              "--scope" scope-name))))))
          ;; one backup, only when the command will run, and not over an entry that is not back yet
          (when (and argvs (executable-find "claude") (file-exists-p file)
                     (not (assoc file drgnx-agent-config-claude--unrestored)))
            (drgnx-agent-config-save-backup file))
          (drgnx-agent-config-claude--cli
           argvs (file-name-as-directory (expand-file-name (or root "~")))
           (lambda (failure completed)
             (funcall callback
                      (drgnx-agent-config-claude--cli-result failure completed op file scope root name old old-cell))))
          nil))))))

;;;; Writing hooks

(defun drgnx-agent-config-claude--hook-json (spec &optional existing)
  "The hook object for the hook SPEC: the members drgnx edits taken from SPEC, the others from the object EXISTING."
  (let ((hook (append (list (cons 'type "command") (cons 'command (plist-get spec :command)))
                      (and (numberp (plist-get spec :timeout)) (list (cons 'timeout (plist-get spec :timeout)))))))
    (if (drgnx-agent-config-json-alist-p existing)
        (drgnx-agent-config-claude--merge-members existing hook drgnx-agent-config-claude--hook-members)
      hook)))

(defun drgnx-agent-config-claude--hooks-update (value old new)
  "The settings VALUE with the hook OLD (a spec: :event :matcher :command; nil for none) replaced by NEW (a spec;
nil for none).  A hook whose event and matcher stay the same keeps its place; the members of a hook drgnx does not
edit (statusMessage, async, …) stay with it."
  (let ((in-place nil) (removed nil))
    (when old
      (let* ((event (plist-get old :event))
             (found nil)
             (same-place (and new (equal (plist-get new :event) event)
                              (equal (or (plist-get new :matcher) "") (or (plist-get old :matcher) ""))))
             (groups
              (delq nil
                    (mapcar
                     (lambda (group)
                       (let* ((hooks (and (not found) (drgnx-agent-config-hook-matcher= group (plist-get old :matcher))
                                          (append (drgnx-agent-config-json-get group "hooks") nil)))
                              (pos (and hooks
                                        (cl-position-if
                                         (lambda (h)
                                           (and (equal (or (drgnx-agent-config-json-get h "type") "command") "command")
                                                (equal (drgnx-agent-config-json-get h "command") (plist-get old :command))))
                                         hooks))))
                         (cond ((null pos) group)
                               (same-place
                                (setq found t in-place t)
                                (setf (nth pos hooks) (drgnx-agent-config-claude--hook-json new (nth pos hooks)))
                                (drgnx-agent-config-json-set group '("hooks") (vconcat hooks)))
                               (t
                                (setq found t removed (nth pos hooks))
                                (setq hooks (append (take pos hooks) (nthcdr (1+ pos) hooks)))
                                (and hooks (drgnx-agent-config-json-set group '("hooks") (vconcat hooks)))))))
                     (append (drgnx-agent-config-json-get value "hooks" event) nil)))))
        (unless found (error "The hook was not found in this file"))
        (setq value (if groups
                        (drgnx-agent-config-json-set value (list "hooks" event) (vconcat groups))
                      (let ((without (drgnx-agent-config-json-del value (list "hooks" event))))
                        (if (drgnx-agent-config-json-get without "hooks") without
                          (drgnx-agent-config-json-del without '("hooks"))))))))
    (when (and new (not in-place))
      (let* ((event (plist-get new :event))
             (matcher (plist-get new :matcher))
             (groups (append (drgnx-agent-config-json-get value "hooks" event) nil))
             (pos (cl-position-if (lambda (g) (drgnx-agent-config-hook-matcher= g matcher)) groups))
             (hook (drgnx-agent-config-claude--hook-json new removed)))
        (if pos
            (setf (nth pos groups)
                  (drgnx-agent-config-json-set (nth pos groups) '("hooks")
                                               (vconcat (drgnx-agent-config-json-get (nth pos groups) "hooks") (list hook))))
          (setq groups (append groups
                               (list (append (and matcher (not (string-empty-p matcher)) (list (cons 'matcher matcher)))
                                             (list (cons 'hooks (vector hook))))))))
        (setq value (drgnx-agent-config-json-set value (list "hooks" event) (vconcat groups)))))
    value))

(defun drgnx-agent-config-claude--write-hook (op item scope root)
  "Add, edit or remove the hook ITEM in the settings file of SCOPE; returns the result."
  (let* ((file (drgnx-agent-config-claude--settings-file scope root))
         (spec (plist-get item :spec))
         (previous (if (eq op 'add) nil (or (plist-get (plist-get item :replaces) :spec) spec))))
    (unless file (error "This scope needs a project"))
    (when (eq op 'toggle) (error "A hook cannot be switched off here"))
    (when (memq op '(add edit))
      (unless (and (stringp (plist-get spec :event)) (string-match-p "\\`[A-Za-z]+\\'" (plist-get spec :event)))
        (error "A hook needs an event"))
      (unless (and (stringp (plist-get spec :command)) (not (string-empty-p (plist-get spec :command))))
        (error "A hook needs a command")))
    (drgnx-agent-config-json-modify
     file (lambda (value) (drgnx-agent-config-claude--hooks-update value previous (and (memq op '(add edit)) spec))))
    (list :ok t :note (format "Wrote %s" file))))

;;;; Writing skills

(defun drgnx-agent-config-claude--write-skill (op item scope root)
  "Add the skill ITEM to SCOPE, or switch it on or off (SCOPE then names the settings file written, nil: the
user's for a user or plugin skill, the project-local one for a project skill); returns the result."
  (let ((name (plist-get item :name)))
    (pcase op
      ('add (let ((dir (drgnx-agent-config-claude--skills-dir scope root)))
              (unless dir (error "This scope needs a project"))
              (list :ok t :note (format "Created %s"
                                        (drgnx-agent-config-new-skill
                                         dir name (or (plist-get (plist-get item :spec) :description) ""))))))
      ('toggle (drgnx-agent-config-claude--toggle-skill item scope root))
      (_ (error "Only adding a skill and switching one on or off are supported")))))

(defun drgnx-agent-config-claude--toggle-skill (item scope root)
  "Switch the skill ITEM off (an \"off\" in the settings file SCOPE) or on (the \"off\" that makes it off removed).
Every settings file is parsed before one is written.  Settings of the three scopes are read local, project, user: the
first that names the skill wins.  Switching on removes the \"off\" of the files that make the skill off and stops at
the first other value; a name-only or user-invocable-only value is never changed."
  (let* ((name (plist-get item :name))
         (order '(local project user))
         (files (mapcar (lambda (s) (cons s (drgnx-agent-config-claude--settings-file s root))) order))
         (values (mapcar (lambda (p)
                           (cons (car p)
                                 (drgnx-agent-config-json-str
                                  (and (cdr p) (file-regular-p (cdr p))
                                       (drgnx-agent-config-json-get
                                        (plist-get (drgnx-agent-config-json-read (cdr p)) :value) "skillOverrides" name)))))
                         files))
         (written nil))
    (cl-flet ((write-file (file function)
                (condition-case err
                    (progn (drgnx-agent-config-json-modify file function) (push file written))
                  (error (if written
                             (error "%s; already changed: %s"
                                    (drgnx-agent-config-error-text err item) (mapconcat #'identity (reverse written) ", "))
                           (signal (car err) (cdr err)))))))
      (if (plist-get item :enabled)
          (let* ((target (or scope (if (eq (plist-get item :from) 'project) 'local 'user)))
                 (file (cdr (assq target files)))
                 (higher (cl-remove-if-not (lambda (s) (let ((v (cdr (assq s values)))) (and v (not (equal v "off")))))
                                           (take (cl-position target order) order))))
            (unless file (error "This scope needs a project"))
            (write-file file (lambda (value) (drgnx-agent-config-json-set value (list "skillOverrides" name) "off")))
            (list :ok t
                  :note (concat (format "%s is now off (%s)" name file)
                                (mapconcat (lambda (s)
                                             (format ". Warning: %s sets it to %s, which wins: it stays listed"
                                                     (cdr (assq s files)) (cdr (assq s values))))
                                           higher ""))))
        (let (chain)
          (catch 'stop
            (dolist (s order)
              (let ((v (cdr (assq s values))))
                (cond ((null v))
                      ((equal v "off") (push (cdr (assq s files)) chain))
                      (t (throw 'stop nil))))))
          (dolist (file (reverse chain))
            (write-file file (lambda (value)
                               (let ((without (drgnx-agent-config-json-del value (list "skillOverrides" name))))
                                 (if (drgnx-agent-config-json-get without "skillOverrides") without
                                   (drgnx-agent-config-json-del without '("skillOverrides")))))))
          (list :ok t :note (if chain
                                (format "%s is now on: removed \"off\" from %s" name (mapconcat #'identity (reverse chain) ", "))
                              (format "%s is not switched off in any settings file" name))))))))

;;;; The generic write

(cl-defmethod drgnx-agent-config-write ((_kind (eql 'claude)) op item scope root callback)
  "Do OP (add, edit, remove or toggle) with ITEM in SCOPE for Claude Code.
For an edit, ITEM carries the new definition and :replaces the item it replaces (the old name, or the old hook), when
it differs.  MCP servers: SCOPE user, local or project.  Hooks: user, project or local settings.  Skills: add to user
or project; toggle writes `skillOverrides' (SCOPE: the settings file; default: the project-local file for a project
skill, the user's otherwise).  Items from plugins or managed settings are read-only."
  (let* ((root (drgnx-agent-config-claude--root root))
         (result
          (condition-case err
              (progn
                (when (and (plist-get item :readonly) (not (and (eq op 'toggle) (eq (plist-get item :section) 'skill))))
                  (error "This item is read-only: it comes from a plugin or from managed settings"))
                (pcase (plist-get item :section)
                  ('mcp (drgnx-agent-config-claude--write-mcp op item scope root callback))
                  ('hook (drgnx-agent-config-claude--write-hook op item scope root))
                  ('skill (drgnx-agent-config-claude--write-skill op item scope root))
                  (_ (error "No such section"))))
            (error (list :error (drgnx-agent-config-error-text err item))))))
    (when result (funcall callback result))
    nil))

(provide 'drgnx-agent-config-claude)
;;; drgnx-agent-config-claude.el ends here
