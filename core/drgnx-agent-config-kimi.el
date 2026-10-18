;;; drgnx-agent-config-kimi.el --- Kimi Code's settings: MCP servers, hooks, skills -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; What Kimi Code has configured, read from its own files, and the edits drgnx makes to them.
;;
;; Where things live (checked in the bundle of kimi-code 2.2.0, `kimi'):
;; - The home: $KIMI_CODE_HOME, else ~/.kimi-code (see `drgnx-agent-config-home').
;; - MCP servers: `mcpServers' of HOME/mcp.json (user), ROOT/.kimi-code/mcp.json (project, Kimi only) and ROOT/.mcp.json
;;   (the Claude-compatible, repo-shared file: read here, edited on Claude Code's page); later files override earlier
;;   ones.  An entry is `command' (stdio) or `url' (http; `transport' "sse" must be written for sse); `enabled' false
;;   turns it off; `bearerTokenEnvVar' names a variable, never holds a token.
;; - Hooks: `[[hooks]]' tables (`event', `matcher', `command', `timeout' 1..600) in HOME/config.toml.  The project
;;   has no hook file (ROOT/.kimi-code/local.toml holds extra directories only).
;; - Skills: SKILL.md files under HOME/skills, ~/.agents/skills, ROOT/.kimi-code/skills and ROOT/.agents/skills.  The
;;   format has no off switch, so a skill is always on.
;; - Plugins: HOME/plugins/installed.json lists them; each root has kimi.plugin.json (or .kimi-plugin/plugin.json) with
;;   `mcpServers', `hooks' and `skills'.  Read only.
;; - Rules: AGENTS.md files.  Credentials: HOME/credentials/ is never opened.
;; - The old kimi-cli kept its files in ~/.kimi: listed read only as `legacy'.
;;
;; Writing is direct and synchronous: JSON keeps key order and indent; an edit merges what drgnx models into the
;; entry that is there and keeps every other member of it; TOML changes the one `[[hooks]]' table (every other byte
;; stays).  One backup next to the file; a file that changed since it was read is read again once.  See
;; docs/develop/core.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-agent-config)
(require 'drgnx-toml)

(defconst drgnx-agent-config-kimi-legacy-note
  "the old kimi-cli's config: kimi-code migrates from it; drgnx does not edit it"
  "The note shown with the items of the old kimi-cli directory.")

(defconst drgnx-agent-config-kimi--hook-events
  '("PreToolUse" "PostToolUse" "PostToolUseFailure" "PermissionRequest" "PermissionResult" "UserPromptSubmit" "Stop"
    "StopFailure" "Interrupt" "SessionStart" "SessionEnd" "SubagentStart" "SubagentStop" "PreCompact" "PostCompact"
    "Notification")
  "The events config.toml may name; Kimi Code rejects the whole file for any other.")

(defvar drgnx-agent-config-kimi--texts nil
  "While reading: file name → a buffer with its text, for the line numbers of the items.")

;;;; Where the files are

(defun drgnx-agent-config-kimi--root (root)
  "ROOT as a directory name with a trailing slash, or nil."
  (and root (file-name-as-directory (expand-file-name root))))

(defun drgnx-agent-config-kimi--mcp-file (scope root)
  "The file the MCP servers of SCOPE (user or project) are in."
  (pcase scope
    ('user (expand-file-name "mcp.json" (drgnx-agent-config-home 'kimi)))
    ('project (and root (expand-file-name ".kimi-code/mcp.json" root)))))

(defun drgnx-agent-config-kimi--config-file ()
  "Kimi Code's config.toml (where the hooks are)."
  (expand-file-name "config.toml" (drgnx-agent-config-home 'kimi)))

(defun drgnx-agent-config-kimi--skills-dir (scope root)
  "The directory drgnx adds the skills of SCOPE (user or project) to."
  (pcase scope
    ('user (expand-file-name "skills" (drgnx-agent-config-home 'kimi)))
    ('project (and root (expand-file-name ".kimi-code/skills" root)))))

(defun drgnx-agent-config-kimi--legacy-dir ()
  "The old kimi-cli's directory (with a trailing slash) when it exists and is not Kimi Code's own home."
  (let ((dir (file-name-as-directory (expand-file-name "~/.kimi"))))
    (and (file-directory-p dir)
         (not (equal dir (drgnx-agent-config-home 'kimi)))
         dir)))

;;;; Parsed JSON, taken apart and changed (objects are alists with symbol keys, arrays vectors)

(defun drgnx-agent-config-kimi--keystr (key)
  "KEY (a symbol or string) as a string."
  (if (symbolp key) (symbol-name key) key))

(defun drgnx-agent-config-kimi--str (x)
  "X when it is a string."
  (and (stringp x) x))

(defun drgnx-agent-config-kimi--alist-p (x)
  "Non-nil when X is a parsed JSON object that has members."
  (and (consp x) (cl-every #'consp x)))

(defun drgnx-agent-config-kimi--cell (obj key)
  "The member of the object OBJ called KEY (a string), or nil."
  (and (listp obj)
       (cl-find-if (lambda (c) (and (consp c) (equal (drgnx-agent-config-kimi--keystr (car c)) key))) obj)))

(defun drgnx-agent-config-kimi--get (obj &rest keys)
  "The value in OBJ at KEYS (strings), or nil."
  (dolist (k keys obj)
    (setq obj (cdr (drgnx-agent-config-kimi--cell obj k)))))

(defun drgnx-agent-config-kimi--set (obj keys value)
  "OBJ with VALUE at KEYS (strings): an existing member keeps its place, a new one goes last."
  (unless (or (null obj) (drgnx-agent-config-kimi--alist-p obj))
    (error "The file has no object where drgnx has to write"))
  (let* ((key (car keys))
         (cell (drgnx-agent-config-kimi--cell obj key))
         (new (if (cdr keys) (drgnx-agent-config-kimi--set (cdr cell) (cdr keys) value) value)))
    (if cell
        (mapcar (lambda (c) (if (eq c cell) (cons (car c) new) c)) obj)
      (append obj (list (cons (intern key) new))))))

(defun drgnx-agent-config-kimi--del (obj keys)
  "OBJ without the member at KEYS (strings); OBJ itself when it is not there."
  (let ((cell (drgnx-agent-config-kimi--cell obj (car keys))))
    (cond ((null cell) obj)
          ((cdr keys) (mapcar (lambda (c)
                                (if (eq c cell) (cons (car c) (drgnx-agent-config-kimi--del (cdr c) (cdr keys))) c))
                              obj))
          (t (remq cell obj)))))

(defun drgnx-agent-config-kimi--strings (x)
  "The strings of the vector X, as a list (anything else in it as text)."
  (and (vectorp x) (mapcar (lambda (e) (if (stringp e) e (format "%s" e))) x)))

(defun drgnx-agent-config-kimi--string-alist (obj)
  "The members of the object OBJ as ((\"NAME\" . \"value\")…)."
  (and (drgnx-agent-config-kimi--alist-p obj)
       (mapcar (lambda (c) (cons (drgnx-agent-config-kimi--keystr (car c))
                                 (if (stringp (cdr c)) (cdr c) (format "%s" (cdr c)))))
               obj)))

(defun drgnx-agent-config-kimi--pairs-json (pairs)
  "The alist PAIRS ((\"NAME\" . \"value\")…) as a JSON object."
  (mapcar (lambda (p)
            (unless (stringp (cdr p)) (error "A value of an environment variable or header must be text"))
            (cons (intern (drgnx-agent-config-kimi--keystr (car p))) (cdr p)))
          pairs))

(defun drgnx-agent-config-kimi--text-buffer (file)
  "A buffer with the text of FILE (cached while reading)."
  (or (gethash file drgnx-agent-config-kimi--texts)
      (puthash file (let ((buffer (generate-new-buffer " *drgnx-kimi-text*" t)))
                      (with-current-buffer buffer
                        (ignore-errors (insert (drgnx-agent-config-read-text file))))
                      buffer)
               drgnx-agent-config-kimi--texts)))

(defun drgnx-agent-config-kimi--line-of (file keys)
  "The line of the JSON FILE where the member path KEYS (strings) is, found by text; nil when not found."
  (with-current-buffer (drgnx-agent-config-kimi--text-buffer file)
    (save-excursion
      (goto-char (point-min))
      (catch 'none
        (dolist (key keys)
          (unless (re-search-forward (concat "\"" (regexp-quote key) "\"[ \t\r\n]*:") nil t)
            (throw 'none nil)))
        (line-number-at-pos (match-beginning 0))))))

(defun drgnx-agent-config-kimi--hook-lines (file)
  "The lines of the `[[hooks]]' headers of FILE, in order; else (the line of `hooks =') when written inline."
  (with-current-buffer (drgnx-agent-config-kimi--text-buffer file)
    (save-excursion
      (goto-char (point-min))
      (let (lines)
        (while (re-search-forward "^[ \t]*\\[\\[[ \t]*hooks[ \t]*\\]\\]" nil t)
          (push (line-number-at-pos (match-beginning 0)) lines))
        (or (nreverse lines)
            (progn (goto-char (point-min))
                   (and (re-search-forward "^[ \t]*hooks[ \t]*=" nil t)
                        (list (line-number-at-pos (match-beginning 0))))))))))

;;;; MCP server entries

(defun drgnx-agent-config-kimi--mcp-spec (json)
  "The :spec of the server entry JSON (nil when it is not an object)."
  (when (drgnx-agent-config-kimi--alist-p json)
    (let ((command (drgnx-agent-config-kimi--str (drgnx-agent-config-kimi--get json "command")))
          (url (drgnx-agent-config-kimi--str (drgnx-agent-config-kimi--get json "url")))
          (transport (drgnx-agent-config-kimi--str (drgnx-agent-config-kimi--get json "transport"))))
      (list :type (cond (transport (intern transport)) (command 'stdio) (url 'http))
            :command command
            :args (drgnx-agent-config-kimi--strings (drgnx-agent-config-kimi--get json "args"))
            :env (drgnx-agent-config-kimi--string-alist (drgnx-agent-config-kimi--get json "env"))
            :url url
            :headers (drgnx-agent-config-kimi--string-alist (drgnx-agent-config-kimi--get json "headers"))
            :cwd (drgnx-agent-config-kimi--str (drgnx-agent-config-kimi--get json "cwd"))
            :bearer-env (drgnx-agent-config-kimi--str (drgnx-agent-config-kimi--get json "bearerTokenEnvVar"))))))

(defconst drgnx-agent-config-kimi--managed-keys
  '("transport" "command" "args" "env" "cwd" "url" "headers" "bearerTokenEnvVar")
  "The members of a server entry drgnx models; an edit changes these and keeps every other member.")

(defun drgnx-agent-config-kimi--entry-members (spec old)
  "The managed members ((KEY . VALUE)…) the server SPEC asks for; OLD is the entry that is there now (or nil)."
  (let* ((command (plist-get spec :command))
         (url (plist-get spec :url))
         (type (or (plist-get spec :type) (cond (command 'stdio) (url 'http))))
         (transport (cond ((eq type 'sse) "sse")
                          ((drgnx-agent-config-kimi--cell old "transport") (symbol-name type)))))
    (pcase type
      ('stdio
       (unless (and (stringp command) (not (string-empty-p command))) (error "A stdio server needs a command"))
       (delq nil (list (and transport (cons "transport" transport))
                       (cons "command" command)
                       (and (plist-get spec :args) (cons "args" (vconcat (plist-get spec :args))))
                       (and (plist-get spec :env)
                            (cons "env" (drgnx-agent-config-kimi--pairs-json (plist-get spec :env))))
                       (and (stringp (plist-get spec :cwd)) (not (string-empty-p (plist-get spec :cwd)))
                            (cons "cwd" (plist-get spec :cwd))))))
      ((or 'http 'sse)
       (unless (and (stringp url) (not (string-empty-p url))) (error "An http or sse server needs a URL"))
       (delq nil (list (and transport (cons "transport" transport))
                       (cons "url" url)
                       (and (plist-get spec :headers)
                            (cons "headers" (drgnx-agent-config-kimi--pairs-json (plist-get spec :headers))))
                       (and (stringp (plist-get spec :bearer-env)) (not (string-empty-p (plist-get spec :bearer-env)))
                            (cons "bearerTokenEnvVar" (plist-get spec :bearer-env))))))
      (_ (error "Unknown server type")))))

(defun drgnx-agent-config-kimi--entry (spec old)
  "The server entry for SPEC: the entry OLD (or nil) with the modelled members set from SPEC, nothing else touched."
  (let ((members (drgnx-agent-config-kimi--entry-members spec old))
        (entry old))
    (dolist (key drgnx-agent-config-kimi--managed-keys)
      (let ((member (assoc key members)))
        (setq entry (if member
                        (drgnx-agent-config-kimi--set entry (list key) (cdr member))
                      (drgnx-agent-config-kimi--del entry (list key))))))
    entry))

(defun drgnx-agent-config-kimi--check-name (name)
  "Signal unless NAME can be an MCP server name."
  (unless (and (stringp name) (string-match-p "\\`[A-Za-z0-9_][A-Za-z0-9_.-]*\\'" name))
    (error "A server name is letters, digits and the characters . - _ (it cannot start with -)")))

;;;; Reading

(defun drgnx-agent-config-kimi--server-items (servers from file keys readonly &optional prefix)
  "MCP items for the object SERVERS from FROM, found in FILE under KEYS (for the line numbers)."
  (when (drgnx-agent-config-kimi--alist-p servers)
    (mapcar (lambda (cell)
              (let* ((name (drgnx-agent-config-kimi--keystr (car cell)))
                     (spec (drgnx-agent-config-kimi--mcp-spec (cdr cell))))
                (append (list :kind 'kimi :section 'mcp :name (concat prefix name) :from from :file file
                              :line (drgnx-agent-config-kimi--line-of file (append keys (list name)))
                              :spec spec
                              :enabled (not (eq (drgnx-agent-config-kimi--get (cdr cell) "enabled") :false))
                              :readonly readonly)
                        (unless spec (list :problem "not a server definition")))))
            servers)))

(defun drgnx-agent-config-kimi--hook-item (event matcher command timeout from file line readonly reason)
  "A hook item; READONLY (with REASON, when there is one) says it cannot be edited."
  (let* ((matcher (and (stringp matcher) (not (string-empty-p matcher)) matcher))
         (unusable (not (and (stringp event) (stringp command) (not (string-empty-p command))))))
    (append (list :kind 'kimi :section 'hook
                  :name (if matcher (format "%s %s" event matcher) (format "%s" event))
                  :from from :file file :line line
                  :spec (list :event event :matcher matcher :command command
                              :timeout (and (integerp timeout) timeout))
                  :enabled t :readonly (and (or readonly unusable) t))
            (cond (reason (list :reason reason))
                  (unusable (list :reason "not a complete hook (it needs an event and a command)"))))))

(defun drgnx-agent-config-kimi--toml-hooks (file from readonly reason problems)
  "Hook items for the `[[hooks]]' of the TOML FILE; PROBLEMS is a cons cell whose car collects (FILE LINE MESSAGE)."
  (when (file-regular-p file)
    (condition-case err
        (let* ((hooks (cdr (assoc "hooks" (drgnx-toml-parse (drgnx-agent-config-read-text file)))))
               (lines (drgnx-agent-config-kimi--hook-lines file))
               (reason (or reason
                           (and (not readonly)
                                (condition-case probe
                                    (progn (drgnx-toml-set-array-entry (drgnx-agent-config-read-text file)
                                                                       '("hooks") #'ignore nil)
                                           nil)
                                  (drgnx-toml-error
                                   (format "hooks are written in a form drgnx does not edit (line %s)" (car (cdr probe)))))))))
          (cl-loop for entry across (if (vectorp hooks) hooks [])
                   for i from 0
                   collect (drgnx-agent-config-kimi--hook-item
                            (drgnx-agent-config-kimi--str (cdr (assoc "event" entry)))
                            (cdr (assoc "matcher" entry))
                            (drgnx-agent-config-kimi--str (cdr (assoc "command" entry)))
                            (cdr (assoc "timeout" entry))
                            from file (or (nth i lines) (car lines)) (or readonly (and reason t)) reason)))
      (drgnx-toml-error (push (list file (nth 1 err) "not valid TOML") (car problems)) nil)
      (error (push (list file nil "cannot be read") (car problems)) nil))))

(defun drgnx-agent-config-kimi--json-hooks (hooks from file)
  "Read-only hook items for the JSON array HOOKS of a plugin manifest FILE."
  (cl-loop for hook across (if (vectorp hooks) hooks [])
           for event = (drgnx-agent-config-kimi--str (drgnx-agent-config-kimi--get hook "event"))
           when event
           collect (drgnx-agent-config-kimi--hook-item
                    event (drgnx-agent-config-kimi--get hook "matcher")
                    (drgnx-agent-config-kimi--str (drgnx-agent-config-kimi--get hook "command"))
                    (drgnx-agent-config-kimi--get hook "timeout")
                    from file (drgnx-agent-config-kimi--line-of file '("hooks")) t "comes from a plugin")))

(defun drgnx-agent-config-kimi--skill-items (dirs)
  "Skill items for DIRS, a list of (DIR . FROM), read only skipped."
  (let (seen out)
    (dolist (spec dirs)
      (let ((dir (file-name-as-directory (expand-file-name (car spec)))))
        (unless (member dir seen)
          (push dir seen)
          (setq out (append out (drgnx-agent-config-skills-in dir (cdr spec) 'kimi))))))
    out))

(defun drgnx-agent-config-kimi--plugins (home read-json)
  "The enabled plugins as ((ID . ROOT)…), from HOME/plugins/installed.json read with READ-JSON."
  (let ((records (drgnx-agent-config-kimi--get (funcall read-json (expand-file-name "plugins/installed.json" home))
                                               "plugins")))
    (cl-loop for rec across (if (vectorp records) records [])
             for id = (drgnx-agent-config-kimi--str (drgnx-agent-config-kimi--get rec "id"))
             for dir = (drgnx-agent-config-kimi--str (drgnx-agent-config-kimi--get rec "root"))
             when (and id dir (not (eq (drgnx-agent-config-kimi--get rec "enabled") :false)))
             collect (cons id (file-name-as-directory (expand-file-name dir home))))))

(cl-defmethod drgnx-agent-config-read ((_kind (eql 'kimi)) root)
  (let ((drgnx-agent-config-kimi--texts (make-hash-table :test #'equal)))
    (unwind-protect (drgnx-agent-config-kimi--read-all root)
      (maphash (lambda (_file buffer) (kill-buffer buffer)) drgnx-agent-config-kimi--texts))))

(defun drgnx-agent-config-kimi--read-all (root)
  "Everything Kimi Code has configured for the project ROOT (see `drgnx-agent-config-read')."
  (let* ((root (drgnx-agent-config-kimi--root root))
         (home (drgnx-agent-config-home 'kimi))
         (os-home (file-name-as-directory (expand-file-name "~")))
         (legacy (drgnx-agent-config-kimi--legacy-dir))
         (problems (list nil))
         items notes rules)
    (cl-flet ((read-json (file)
                (when (and file (file-regular-p file))
                  (condition-case err
                      (plist-get (drgnx-agent-config-json-read file) :value)
                    (drgnx-agent-config-unreadable (push (cdr err) (car problems)) nil)
                    (error (push (list file nil "cannot be read") (car problems)) nil))))
              (add (new) (setq items (append items new))))
      ;; MCP servers, in the order Kimi Code merges them
      (let ((user (drgnx-agent-config-kimi--mcp-file 'user root)))
        (add (drgnx-agent-config-kimi--server-items
              (drgnx-agent-config-kimi--get (read-json user) "mcpServers") 'user user '("mcpServers") nil)))
      (when root
        (let ((shared (expand-file-name ".mcp.json" root))
              (project (drgnx-agent-config-kimi--mcp-file 'project root)))
          (add (drgnx-agent-config-kimi--server-items
                (drgnx-agent-config-kimi--get (read-json shared) "mcpServers") 'project shared '("mcpServers") t))
          (when (file-regular-p shared)
            (push ".mcp.json is read by Kimi Code too and shared with Claude Code: edit it on Claude Code's page" notes))
          (add (drgnx-agent-config-kimi--server-items
                (drgnx-agent-config-kimi--get (read-json project) "mcpServers") 'project project '("mcpServers") nil))))
      ;; plugins (read only)
      (let ((plugins (drgnx-agent-config-kimi--plugins home #'read-json)))
        (dolist (plugin plugins)
          (let* ((dir (cdr plugin))
                 (manifest (cl-find-if #'file-regular-p
                                       (list (expand-file-name "kimi.plugin.json" dir)
                                             (expand-file-name ".kimi-plugin/plugin.json" dir))))
                 (value (read-json manifest))
                 (skills (drgnx-agent-config-kimi--get value "skills")))
            (add (drgnx-agent-config-kimi--server-items
                  (drgnx-agent-config-kimi--get value "mcpServers") 'plugin manifest '("mcpServers") t
                  (format "plugin-%s:" (car plugin))))
            (add (drgnx-agent-config-kimi--json-hooks (drgnx-agent-config-kimi--get value "hooks") 'plugin manifest))
            (dolist (rel (cond ((stringp skills) (list skills)) ((vectorp skills) (drgnx-agent-config-kimi--strings skills))))
              (dolist (skill (drgnx-agent-config-skills-in (expand-file-name rel dir) 'plugin 'kimi))
                (plist-put skill :name (format "%s:%s" (car plugin) (plist-get skill :name)))
                (plist-put skill :readonly t)
                (add (list skill)))))))
      ;; hooks
      (add (drgnx-agent-config-kimi--toml-hooks (drgnx-agent-config-kimi--config-file) 'user nil nil problems))
      ;; skills
      (add (drgnx-agent-config-kimi--skill-items
            (append (list (cons (expand-file-name "skills" home) 'user)
                          (cons (expand-file-name ".agents/skills" os-home) 'user))
                    (and root (list (cons (expand-file-name ".kimi-code/skills" root) 'project)
                                    (cons (expand-file-name ".agents/skills" root) 'project))))))
      ;; the old kimi-cli directory (read only)
      (when legacy
        (let ((file (expand-file-name "mcp.json" legacy)))
          (dolist (item (drgnx-agent-config-kimi--server-items
                         (drgnx-agent-config-kimi--get (read-json file) "mcpServers") 'legacy file '("mcpServers") t))
            (add (list item))))
        (add (drgnx-agent-config-kimi--toml-hooks
              (expand-file-name "config.toml" legacy) 'legacy t "the old kimi-cli's file" problems))
        (dolist (skill (drgnx-agent-config-skills-in (expand-file-name "skills" legacy) 'legacy 'kimi))
          (plist-put skill :readonly t)
          (add (list skill)))
        (push drgnx-agent-config-kimi-legacy-note notes))
      ;; rules
      (setq rules (cl-remove-if-not
                   #'file-regular-p
                   (delq nil (list (expand-file-name "AGENTS.md" home)
                                   (and root (expand-file-name ".kimi-code/AGENTS.md" root))
                                   (and root (expand-file-name "AGENTS.md" root)))))))
    (list :rules rules :items items :problems (nreverse (car problems))
          :routes (list (drgnx-agent-config-kimi-route))
          :notes (nreverse notes))))

(defun drgnx-agent-config-kimi-route ()
  "Kimi Code's route: its own login.  No key is looked up."
  (list :profile "Kimi Code" :kind nil :base-url nil :model nil
        :key-where "its own login (`kimi login')"
        :billing 'subscription :vendor "Moonshot AI"))

(cl-defmethod drgnx-agent-config-scopes ((_kind (eql 'kimi)) section root)
  (let ((root (drgnx-agent-config-kimi--root root)))
    (pcase section
      ('mcp (append (list (list 'user "User (all projects)" (drgnx-agent-config-kimi--mcp-file 'user root)))
                    (and root (list (list 'project "Project (.kimi-code/mcp.json, Kimi Code only)"
                                          (drgnx-agent-config-kimi--mcp-file 'project root))))))
      ('hook (list (list 'user "User (config.toml)" (drgnx-agent-config-kimi--config-file))))
      ('skill (append (list (list 'user "User (all projects)" (drgnx-agent-config-kimi--skills-dir 'user root)))
                      (and root (list (list 'project "Project" (drgnx-agent-config-kimi--skills-dir 'project root))))))
      (_ (error "No such section: %S" section)))))

;;;; Writing files

(defun drgnx-agent-config-kimi--modify-json (file function)
  "Replace the JSON object in FILE with (FUNCTION VALUE), VALUE being what FILE holds now.
FILE is read again just before each attempt and the write is refused when it changed since: a refused write is
tried once more with the new content.  A second refusal signals `drgnx-agent-config-changed'.  Returns FILE."
  (let ((attempt 0) done)
    (while (not done)
      (setq attempt (1+ attempt))
      (let* ((text (and (file-exists-p file) (drgnx-agent-config-read-text file)))
             (read (drgnx-agent-config-json-read file))
             (value (plist-get read :value)))
        (unless (or (null value) (drgnx-agent-config-kimi--alist-p value))
          (error "The file does not hold a JSON object"))
        (condition-case nil
            (progn (drgnx-agent-config-json-write file (funcall function value) (plist-get read :indent) text)
                   (setq done t))
          (drgnx-agent-config-changed
           (when (>= attempt 2) (signal 'drgnx-agent-config-changed (list file)))))))
    file))

(defun drgnx-agent-config-kimi--modify-toml (file function)
  "Replace the text of the TOML FILE with (FUNCTION TEXT), TEXT being what FILE holds now (\"\" for none).
Same retry as `drgnx-agent-config-kimi--modify-json'.  A FILE or result that does not parse is never written."
  (let ((attempt 0) done)
    (while (not done)
      (setq attempt (1+ attempt))
      (let* ((exists (file-exists-p file))
             (text (if exists (drgnx-agent-config-read-text file) "")))
        (drgnx-toml-parse text)
        (condition-case nil
            (progn (drgnx-agent-config-write-text file (funcall function text) #'drgnx-toml-parse #'drgnx-toml-parse
                                                  (and exists text))
                   (setq done t))
          (drgnx-agent-config-changed
           (when (>= attempt 2) (signal 'drgnx-agent-config-changed (list file)))))))
    file))

;;;; Writing MCP servers

(defconst drgnx-agent-config-kimi--restart-note
  "MCP servers load when a session starts: start a new session (/new) or restart kimi to pick this up"
  "What the user is told after an MCP edit.")

(defun drgnx-agent-config-kimi--write-mcp (op item scope root)
  "Add, edit, remove or switch the MCP server ITEM in SCOPE (user or project); returns the result."
  (let* ((name (plist-get item :name))
         (old-name (or (plist-get (plist-get item :replaces) :name) name))
         (file (drgnx-agent-config-kimi--mcp-file scope root)))
    (unless (memq scope '(user project)) (error "No such scope for an MCP server"))
    (unless file (error "This scope needs a project"))
    (drgnx-agent-config-kimi--check-name name)
    (when (eq op 'edit) (drgnx-agent-config-kimi--check-name old-name))
    (drgnx-agent-config-kimi--modify-json
     file
     (lambda (value)
       (let* ((servers (drgnx-agent-config-kimi--get value "mcpServers"))
              (previous (drgnx-agent-config-kimi--cell servers (if (eq op 'add) name old-name))))
         (when (and (eq op 'add) previous) (error "%s is already in this file" name))
         (when (and (not (eq op 'add)) (not previous)) (error "%s is not in this file" old-name))
         (pcase op
           ('remove (drgnx-agent-config-kimi--del value (list "mcpServers" name)))
           ('toggle
            (drgnx-agent-config-kimi--set
             value (list "mcpServers" name)
             (if (eq (drgnx-agent-config-kimi--get (cdr previous) "enabled") :false)
                 (drgnx-agent-config-kimi--del (cdr previous) '("enabled"))
               (drgnx-agent-config-kimi--set (cdr previous) '("enabled") :false))))
           ('add (drgnx-agent-config-kimi--set
                  value (list "mcpServers" name)
                  (drgnx-agent-config-kimi--entry (plist-get item :spec) nil)))
           ('edit
            (let ((entry (drgnx-agent-config-kimi--entry (plist-get item :spec) (cdr previous))))
              (if (equal name old-name)
                  (drgnx-agent-config-kimi--set value (list "mcpServers" name) entry)
                (when (drgnx-agent-config-kimi--cell servers name) (error "%s is already in this file" name))
                ;; renamed: the entry takes the old one's place, with everything it had
                (drgnx-agent-config-kimi--set
                 value '("mcpServers")
                 (mapcar (lambda (c) (if (eq c previous) (cons (intern name) entry) c)) servers)))))
           (_ (error "No such operation"))))))
    (list :ok t :note (format "Wrote %s. %s" file drgnx-agent-config-kimi--restart-note))))

;;;; Writing hooks

(defun drgnx-agent-config-kimi--hooks-in (text)
  "The `[[hooks]]' entries of the TOML TEXT, as alists."
  (let ((hooks (cdr (assoc "hooks" (drgnx-toml-parse text)))))
    (and (vectorp hooks) (append hooks nil))))

(defun drgnx-agent-config-kimi--hook-match-p (entry spec)
  "Non-nil when the config.toml ENTRY is the hook SPEC (event, matcher and command)."
  (and (equal (cdr (assoc "event" entry)) (plist-get spec :event))
       (equal (or (cdr (assoc "matcher" entry)) "") (or (plist-get spec :matcher) ""))
       (equal (cdr (assoc "command" entry)) (plist-get spec :command))))

(defun drgnx-agent-config-kimi--hook-members (spec)
  "The members ((KEY . VALUE)…) of the hook SPEC; KEY is nil-valued when the member is absent."
  (let ((matcher (plist-get spec :matcher)) (timeout (plist-get spec :timeout)))
    (list (cons "event" (plist-get spec :event))
          (cons "matcher" (and (stringp matcher) (not (string-empty-p matcher)) matcher))
          (cons "command" (plist-get spec :command))
          (cons "timeout" timeout))))

(defun drgnx-agent-config-kimi--hook-alist (spec old)
  "The table for the hook SPEC: the entry OLD (an alist, or nil) with the modelled members set, any other kept."
  (let ((entry old))
    (dolist (member (drgnx-agent-config-kimi--hook-members spec))
      (let ((cell (assoc (car member) entry)))
        (cond ((and (cdr member) cell)
               (setq entry (mapcar (lambda (c) (if (eq c cell) (cons (car c) (cdr member)) c)) entry)))
              ((cdr member) (setq entry (append entry (list member))))
              (cell (setq entry (remq cell entry))))))
    entry))

(defun drgnx-agent-config-kimi--check-hook (spec)
  "Signal unless SPEC is a hook Kimi Code accepts."
  (unless (member (plist-get spec :event) drgnx-agent-config-kimi--hook-events)
    (error "A hook needs one of Kimi Code's events"))
  (unless (and (stringp (plist-get spec :command)) (not (string-empty-p (plist-get spec :command))))
    (error "A hook needs a command"))
  (when (plist-get spec :timeout)
    (unless (and (integerp (plist-get spec :timeout)) (<= 1 (plist-get spec :timeout) 600))
      (error "A hook's timeout is 1 to 600 seconds"))))

(defun drgnx-agent-config-kimi--write-hook (op item scope)
  "Add, edit or remove the hook ITEM in config.toml; returns the result."
  (let* ((file (drgnx-agent-config-kimi--config-file))
         (spec (plist-get item :spec))
         (old (if (eq op 'add) nil (or (plist-get (plist-get item :replaces) :spec) spec))))
    (unless (eq scope 'user) (error "Hooks live in config.toml: only the user scope has them"))
    (when (eq op 'toggle) (error "A hook cannot be switched off here"))
    (when (memq op '(add edit)) (drgnx-agent-config-kimi--check-hook spec))
    (drgnx-agent-config-kimi--modify-toml
     file
     (lambda (text)
       (let* ((entries (drgnx-agent-config-kimi--hooks-in text))
              (match (and old (cl-find-if (lambda (e) (drgnx-agent-config-kimi--hook-match-p e old)) entries))))
         (when (and (eq op 'add) (cl-some (lambda (e) (drgnx-agent-config-kimi--hook-match-p e spec)) entries))
           (error "This hook is already in config.toml"))
         (when (and old (not match)) (error "The hook was not found in this file"))
         (when (and (eq op 'edit) (not (drgnx-agent-config-kimi--hook-match-p match spec))
                    (cl-some (lambda (e) (drgnx-agent-config-kimi--hook-match-p e spec)) entries))
           (error "This hook is already in config.toml"))
         (drgnx-toml-set-array-entry
          text '("hooks")
          (if match (lambda (e) (drgnx-agent-config-kimi--hook-match-p e old)) #'ignore)
          (and (memq op '(add edit)) (drgnx-agent-config-kimi--hook-alist spec match))))))
    (list :ok t :note (format "Wrote %s. Hooks load when a session starts" file))))

;;;; Writing skills

(defun drgnx-agent-config-kimi--write-skill (op item scope root)
  "Add the skill ITEM to SCOPE; returns the result."
  (pcase op
    ('add (let ((dir (drgnx-agent-config-kimi--skills-dir scope root)))
            (unless dir (error "This scope needs a project"))
            (list :ok t :note (format "Created %s"
                                      (drgnx-agent-config-new-skill
                                       dir (plist-get item :name)
                                       (or (plist-get (plist-get item :spec) :description) ""))))))
    ('toggle (error "Kimi Code has no setting to turn a skill off: remove or move its folder"))
    (_ (error "Only adding a skill is supported"))))

;;;; The generic write

(defun drgnx-agent-config-kimi--error-text (err item)
  "The message for the error ERR of a write of ITEM: where and why, never the item's data."
  (pcase (car err)
    ('drgnx-agent-config-unreadable
     (let ((data (cdr err)))
       (format "%s does not parse (line %s: %s); nothing was written" (nth 0 data) (or (nth 1 data) "?") (nth 2 data))))
    ('drgnx-toml-error
     (format "config.toml is not valid TOML, or in a form drgnx does not edit (line %s); nothing was written"
             (or (nth 1 err) "?")))
    ('drgnx-agent-config-changed
     (format "%s was changed by another program while it was being written; nothing was written, try again" (cadr err)))
    (_ (drgnx-agent-config-mask-text (error-message-string err)
                                     (ignore-errors (drgnx-agent-config-secrets (plist-get item :spec)))))))

(cl-defmethod drgnx-agent-config-write ((_kind (eql 'kimi)) op item scope root callback)
  "Do OP (add, edit, remove or toggle) with ITEM in SCOPE for Kimi Code; CALLBACK is called at once.
For an edit, ITEM carries the new definition and :replaces the item it replaces (the old name, or the old hook), when
it differs.  MCP servers: SCOPE user or project; toggle switches `enabled'.  Hooks: user (config.toml).  Skills: add
to user or project; a skill cannot be turned off.  Items from plugins, the shared .mcp.json, the old kimi-cli
directory or a form of config.toml drgnx does not edit are read-only."
  (let* ((root (drgnx-agent-config-kimi--root root))
         (result
          (condition-case err
              (progn
                (when (plist-get item :readonly)
                  (error "This item is read-only%s"
                         (if (plist-get item :reason) (format " (%s)" (plist-get item :reason))
                           ": it comes from a plugin, the shared .mcp.json or the old kimi-cli directory")))
                (pcase (plist-get item :section)
                  ('mcp (drgnx-agent-config-kimi--write-mcp op item scope root))
                  ('hook (drgnx-agent-config-kimi--write-hook op item scope))
                  ('skill (drgnx-agent-config-kimi--write-skill op item scope root))
                  (_ (error "No such section"))))
            (error (list :error (drgnx-agent-config-kimi--error-text err item))))))
    (funcall callback result)
    nil))

(provide 'drgnx-agent-config-kimi)
;;; drgnx-agent-config-kimi.el ends here
