;;; drgnx-agent-config-gemini.el --- Gemini CLI's settings: MCP servers, hooks, skills, extensions -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; What Gemini CLI has configured, read from its own files, and the edits drgnx makes to them.
;;
;; Where things live (checked against gemini 0.64.0, from its shipped docs and code):
;; - Settings files: HOME/settings.json (user; HOME is `.gemini' under $GEMINI_CLI_HOME, else ~/.gemini),
;;   ROOT/.gemini/settings.json (project), and read-only: $GEMINI_CLI_SYSTEM_SETTINGS_PATH or /etc/gemini-cli/settings.json
;;   (the system's overrides) and $GEMINI_CLI_SYSTEM_DEFAULTS_PATH or /etc/gemini-cli/system-defaults.json.
;; - MCP servers: `mcpServers' in a settings file, and the `mcpServers' of an extension's gemini-extension.json
;;   (read-only).  0.64.0 differs from its docs: `url' with `type' http or sse is current, `url' alone is Streamable HTTP
;;   (the docs say SSE) and `httpUrl' is deprecated (still read, never written).
;; - Hooks: `hooks' (event -> groups of {matcher, hooks: [{type, command, name, timeout in milliseconds}]}) in a settings
;;   file; an extension's hooks/hooks.json (read-only).  A hook is off when its `name' (else its command) is in
;;   `hooksConfig.disabled'.
;; - Skills: SKILL.md files under HOME/skills, $GEMINI_CLI_HOME-or-~/.agents/skills, ROOT/.gemini/skills,
;;   ROOT/.agents/skills and the extensions' skills/; off by name in `skills.disabled', which is the union of all
;;   settings files.
;; - Extensions: HOME/extensions/NAME/gemini-extension.json; on unless extension-enablement.json (in the same directory)
;;   has a rule for NAME that matches the project (the last matching rule wins, `!' disables).
;; - Rules: GEMINI.md (or the names in `context.fileName') in HOME and ROOT.
;;
;; Comments: Gemini reads its settings files with comments (JSONC) and keeps them when it writes.  drgnx cannot keep
;; them, so a settings file with comments is read (comments ignored) and shown read-only, with a note; drgnx never
;; writes such a file.  Every other edit changes only the modelled members of one entry and leaves the rest of the
;; entry (cwd, trust, includeTools, unknown keys) and of the file alone.  Credential files are never opened.
;; See docs/develop/core.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-agent-config)
;; The JSON object helpers and the error text are generic; they live in the Claude file until they are hoisted.
(require 'drgnx-agent-config-claude)

(defalias 'drgnx-agent-config-gemini--keystr #'drgnx-agent-config-claude--keystr)
(defalias 'drgnx-agent-config-gemini--str #'drgnx-agent-config-claude--str)
(defalias 'drgnx-agent-config-gemini--alist-p #'drgnx-agent-config-claude--alist-p)
(defalias 'drgnx-agent-config-gemini--cell #'drgnx-agent-config-claude--cell)
(defalias 'drgnx-agent-config-gemini--get #'drgnx-agent-config-claude--get)
(defalias 'drgnx-agent-config-gemini--set #'drgnx-agent-config-claude--set)
(defalias 'drgnx-agent-config-gemini--del #'drgnx-agent-config-claude--del)
(defalias 'drgnx-agent-config-gemini--strings #'drgnx-agent-config-claude--strings)
(defalias 'drgnx-agent-config-gemini--string-alist #'drgnx-agent-config-claude--string-alist)
(defalias 'drgnx-agent-config-gemini--error-text #'drgnx-agent-config-claude--error-text)

(defconst drgnx-agent-config-gemini--events
  '("BeforeTool" "AfterTool" "BeforeAgent" "AfterAgent" "Notification" "SessionStart" "SessionEnd" "PreCompress"
    "BeforeModel" "AfterModel" "BeforeToolSelection")
  "The hook events of gemini 0.64.0.")

(defvar drgnx-agent-config-gemini--texts nil
  "While reading: file name -> a buffer with its text without comments, for the line numbers of the items.")

;;;; Where the files are

(defun drgnx-agent-config-gemini--system-file (name variable)
  "The system file NAME: the file the environment VARIABLE names, else the platform's own directory."
  (or (drgnx-agent-config--env-dir variable)
      (expand-file-name name (pcase system-type
                               ('darwin "/Library/Application Support/GeminiCli")
                               ('windows-nt "C:/ProgramData/gemini-cli")
                               (_ "/etc/gemini-cli")))))

(defun drgnx-agent-config-gemini--root (root)
  "ROOT as a directory name with a trailing slash, or nil."
  (and root (file-name-as-directory (expand-file-name root))))

(defun drgnx-agent-config-gemini--settings-file (scope root)
  "The settings file of SCOPE (user, project, system or defaults); nil without a project for `project'."
  (pcase scope
    ('user (expand-file-name "settings.json" (drgnx-agent-config-home 'gemini)))
    ('project (and root (expand-file-name ".gemini/settings.json" root)))
    ('system (drgnx-agent-config-gemini--system-file "settings.json" "GEMINI_CLI_SYSTEM_SETTINGS_PATH"))
    ('defaults (drgnx-agent-config-gemini--system-file "system-defaults.json" "GEMINI_CLI_SYSTEM_DEFAULTS_PATH"))))

(defun drgnx-agent-config-gemini--agents-dir ()
  "The user's .agents directory: gemini looks under $GEMINI_CLI_HOME (not its .gemini) when that is set, else ~."
  (expand-file-name ".agents" (or (drgnx-agent-config--env-dir "GEMINI_CLI_HOME") "~")))

(defun drgnx-agent-config-gemini--skills-dir (scope root)
  "The directory the skills of SCOPE (user or project) are added to."
  (pcase scope
    ('user (expand-file-name "skills" (drgnx-agent-config-home 'gemini)))
    ('project (and root (expand-file-name ".gemini/skills" root)))))

;;;; Comments

(defun drgnx-agent-config-gemini--strip-comments (text)
  "(STRIPPED . COMMENTED) for TEXT: // and /* */ comments blanked out (same length, same lines; strings untouched).
COMMENTED is non-nil when there was a comment."
  (let ((commented nil))
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (while (re-search-forward "[\"/]" nil t)
        (let ((start (1- (point))))
          (if (eq (char-before) ?\")
              (progn
                (while (progn (skip-chars-forward "^\"\\\\") (eq (char-after) ?\\))
                  (goto-char (min (point-max) (+ (point) 2))))
                (unless (eobp) (forward-char 1)))
            (let ((end (cond ((eq (char-after) ?/) (end-of-line) (point))
                             ((eq (char-after) ?*)
                              (forward-char 1)
                              (if (search-forward "*/" nil t) (point) (point-max))))))
              (when end
                (setq commented t)
                (goto-char start)
                (while (< (point) end)
                  (if (memq (char-after) '(?\n ?\r))
                      (forward-char 1)
                    (delete-char 1)
                    (insert ?\s))))))))
      (cons (buffer-string) commented))))

(defun drgnx-agent-config-gemini--read-file (file)
  "FILE's JSON, comments allowed, as (:value VALUE :commented BOOL); nil when FILE is not a regular file.
Signals `drgnx-agent-config-unreadable' with (FILE LINE MESSAGE) like `drgnx-agent-config-json-read'."
  (when (file-regular-p file)
    (let ((stripped (drgnx-agent-config-gemini--strip-comments (drgnx-agent-config-read-text file))))
      (list :value (drgnx-agent-config--json-parse file (car stripped)) :commented (cdr stripped)))))

(defun drgnx-agent-config-gemini--line-of (file keys)
  "The line of FILE where the member path KEYS (strings) is, found by text; nil when not found."
  (when-let* ((buffer (or (gethash file drgnx-agent-config-gemini--texts)
                          (puthash file (let ((buffer (generate-new-buffer " *drgnx-gemini-text*" t)))
                                          (with-current-buffer buffer
                                            (ignore-errors
                                              (insert (car (drgnx-agent-config-gemini--strip-comments
                                                            (drgnx-agent-config-read-text file))))))
                                          buffer)
                                   drgnx-agent-config-gemini--texts))))
    (with-current-buffer buffer
      (save-excursion
        (goto-char (point-min))
        (catch 'none
          (dolist (key keys)
            (unless (re-search-forward (concat "\"" (regexp-quote key) "\"[ \t\r\n]*:") nil t)
              (throw 'none nil)))
          (line-number-at-pos (match-beginning 0)))))))

;;;; MCP server entries

(defconst drgnx-agent-config-gemini--managed-keys '("command" "args" "env" "url" "httpUrl" "type" "headers")
  "The members of an MCP server entry that drgnx models; any other member is left as it is.")

(defun drgnx-agent-config-gemini--mcp-spec (json)
  "The :spec of the server entry JSON (nil when it is not an object).
Gemini's precedence: httpUrl (Streamable HTTP), then url (`type' sse for SSE, else Streamable HTTP), then command."
  (when (drgnx-agent-config-gemini--alist-p json)
    (let* ((command (drgnx-agent-config-gemini--str (drgnx-agent-config-gemini--get json "command")))
           (http (drgnx-agent-config-gemini--str (drgnx-agent-config-gemini--get json "httpUrl")))
           (url (drgnx-agent-config-gemini--str (drgnx-agent-config-gemini--get json "url")))
           (type (drgnx-agent-config-gemini--str (drgnx-agent-config-gemini--get json "type"))))
      (list :type (cond (http 'http) (url (if (equal type "sse") 'sse 'http)) (command 'stdio))
            :command command
            :args (drgnx-agent-config-gemini--strings (drgnx-agent-config-gemini--get json "args"))
            :env (drgnx-agent-config-gemini--string-alist (drgnx-agent-config-gemini--get json "env"))
            :url (or http url)
            :headers (drgnx-agent-config-gemini--string-alist (drgnx-agent-config-gemini--get json "headers"))))))

(defun drgnx-agent-config-gemini--spec-members (spec &optional existing)
  "The modelled members Gemini files for the server SPEC, as an alist of (NAME . VALUE).
Signals when SPEC is not a server.  EXISTING is the entry being edited: an http server that had `httpUrl' (and no
`url') keeps it, because older Gemini CLIs on a teammate's machine do not know `url' with `type'."
  (let* ((command (plist-get spec :command))
         (url (plist-get spec :url))
         (type (or (plist-get spec :type) (cond (command 'stdio) (url 'http)))))
    (pcase type
      ('stdio
       (unless (and (stringp command) (not (string-empty-p command))) (error "A stdio server needs a command"))
       (append (list (cons "command" command))
               (and (plist-get spec :args) (list (cons "args" (vconcat (plist-get spec :args)))))
               (and (plist-get spec :env)
                    (list (cons "env" (drgnx-agent-config-claude--pairs-json (plist-get spec :env)))))))
      ((or 'http 'sse)
       (unless (and (stringp url) (not (string-empty-p url))) (error "An http or sse server needs a URL"))
       (append (if (and (eq type 'http)
                        (drgnx-agent-config-gemini--cell existing "httpUrl")
                        (not (drgnx-agent-config-gemini--cell existing "url")))
                   (list (cons "httpUrl" url))
                 (list (cons "url" url) (cons "type" (symbol-name type))))
               (and (plist-get spec :headers)
                    (list (cons "headers" (drgnx-agent-config-claude--pairs-json (plist-get spec :headers)))))))
      (_ (error "Unknown server type")))))

(defun drgnx-agent-config-gemini--merge-members (entry members)
  "The server ENTRY (an object, or nil) with the modelled members replaced by MEMBERS ((NAME . VALUE)…).
Other members stay."
  (dolist (key drgnx-agent-config-gemini--managed-keys entry)
    (let ((cell (assoc key members)))
      (setq entry (if cell
                      (drgnx-agent-config-gemini--set entry (list key) (cdr cell))
                    (drgnx-agent-config-gemini--del entry (list key)))))))

(defun drgnx-agent-config-gemini--check-name (name)
  "Signal unless NAME can be the name of a new MCP server.
Gemini's policy engine splits mcp_SERVER_TOOL at the first underscore, so a name with `_' misleads it."
  (unless (and (stringp name) (string-match-p "\\`[A-Za-z0-9][A-Za-z0-9.-]*\\'" name))
    (error "A server name is letters, digits, - and . (an underscore would confuse Gemini's policy rules)")))

;;;; Reading

(defun drgnx-agent-config-gemini--server-items (servers from file keys readonly &optional prefix)
  "MCP items for the object SERVERS from FROM, found in FILE under KEYS (for the line numbers)."
  (when (drgnx-agent-config-gemini--alist-p servers)
    (mapcar (lambda (cell)
              (let* ((name (drgnx-agent-config-gemini--keystr (car cell)))
                     (spec (drgnx-agent-config-gemini--mcp-spec (cdr cell))))
                (append (list :kind 'gemini :section 'mcp :name (concat prefix name) :from from :file file
                              :line (drgnx-agent-config-gemini--line-of file (append keys (list name)))
                              :spec spec :enabled t :readonly readonly)
                        (unless spec (list :problem "not a server definition")))))
            servers)))

(defun drgnx-agent-config-gemini--hook-items (value from file readonly disabled)
  "Hook items for the `hooks' of the settings VALUE, read from FILE; DISABLED is `hooksConfig.disabled'."
  (let ((hooks (drgnx-agent-config-gemini--get value "hooks")) out)
    (when (drgnx-agent-config-gemini--alist-p hooks)
      (dolist (entry hooks)
        (let ((event (drgnx-agent-config-gemini--keystr (car entry))))
          (dolist (group (and (vectorp (cdr entry)) (append (cdr entry) nil)))
            (let ((matcher (drgnx-agent-config-gemini--str (drgnx-agent-config-gemini--get group "matcher")))
                  (members (drgnx-agent-config-gemini--get group "hooks")))
              (dolist (hook (and (vectorp members) (append members nil)))
                (let* ((type (drgnx-agent-config-gemini--str (drgnx-agent-config-gemini--get hook "type")))
                       (command (drgnx-agent-config-gemini--str (drgnx-agent-config-gemini--get hook "command")))
                       (hook-name (drgnx-agent-config-gemini--str (drgnx-agent-config-gemini--get hook "name")))
                       (timeout (drgnx-agent-config-gemini--get hook "timeout")))
                  (push (list :kind 'gemini :section 'hook
                              :name (if (and matcher (not (string-empty-p matcher))) (format "%s %s" event matcher) event)
                              :from from :file file
                              :line (drgnx-agent-config-gemini--line-of file (list "hooks" event))
                              :spec (list :event event :matcher matcher :command command
                                          :timeout (and (numberp timeout) timeout) :timeout-unit 'ms
                                          :hook-type type :hook-name hook-name)
                              :enabled (not (member (or hook-name command) disabled))
                              :readonly (or readonly (not (and (equal type "command") command))))
                        out))))))))
    (nreverse out)))

(defun drgnx-agent-config-gemini--rule-regexp (rule)
  "The regular expression for an extension-enablement RULE (a directory, with a final `*' for its subdirectories)."
  (let* ((rule (if (string-prefix-p "!" rule) (substring rule 1) rule))
         (all (string-suffix-p "*" rule))
         (base (if all (substring rule 0 -1) rule)))
    (concat "\\`"
            (cond ((not all) (regexp-quote base))
                  ((string-suffix-p "/" base) (concat (regexp-quote (string-remove-suffix "/" base)) "\\(?:/.*\\)?"))
                  (t (concat (regexp-quote base) ".*")))
            "\\'")))

(defun drgnx-agent-config-gemini--extension-enabled-p (name enablement root)
  "Non-nil when the extension NAME is on for the project ROOT by the extension-enablement.json value ENABLEMENT."
  (let ((enabled t)
        (path (file-name-as-directory (expand-file-name (or root "~")))))
    (dolist (rule (append (drgnx-agent-config-gemini--get enablement name "overrides") nil) enabled)
      (when (and (stringp rule) (string-match-p (drgnx-agent-config-gemini--rule-regexp rule) path))
        (setq enabled (not (string-prefix-p "!" rule)))))))

(defun drgnx-agent-config-gemini--context-names (values)
  "The names of the rules files: `context.fileName' (a name or a list) of the settings VALUES, else GEMINI.md."
  (let (names)
    (dolist (value values)
      (let ((setting (drgnx-agent-config-gemini--get value "context" "fileName")))
        (dolist (name (if (stringp setting) (list setting) (and (vectorp setting) (append setting nil))))
          (when (and (stringp name) (not (string-empty-p name)) (not (string-match-p "/" name)))
            (cl-pushnew name names :test #'equal)))))
    (or (nreverse names) (list "GEMINI.md"))))

(cl-defmethod drgnx-agent-config-read ((_kind (eql 'gemini)) root)
  (let ((drgnx-agent-config-gemini--texts (make-hash-table :test #'equal)))
    (unwind-protect (drgnx-agent-config-gemini--read-all root)
      (maphash (lambda (_file buffer) (kill-buffer buffer)) drgnx-agent-config-gemini--texts))))

(defun drgnx-agent-config-gemini--read-all (root)
  "Everything Gemini CLI has configured for the project ROOT (see `drgnx-agent-config-read')."
  (let* ((root (drgnx-agent-config-gemini--root root))
         (home (drgnx-agent-config-home 'gemini))
         problems items notes rules)
    (cl-flet ((read-json (file &optional strict)
                (when (and file (file-regular-p file))
                  (condition-case err
                      (if strict
                          (list :value (plist-get (drgnx-agent-config-json-read file) :value))
                        (drgnx-agent-config-gemini--read-file file))
                    (drgnx-agent-config-unreadable (push (cdr err) problems) nil)
                    (error (push (list file nil "cannot be read") problems) nil))))
              (add (new) (setq items (append items new))))
      (let* ((user-file (drgnx-agent-config-gemini--settings-file 'user root))
             (project-file (let ((file (drgnx-agent-config-gemini--settings-file 'project root)))
                             ;; in the home directory the project's file is the user's
                             (and file (not (equal (file-truename file) (file-truename user-file))) file)))
             (settings
              (delq nil
                    (mapcar (lambda (spec)
                              (let* ((file (cdr spec)) (read (read-json file)))
                                (when read
                                  (list (car spec) file (plist-get read :value) (plist-get read :commented)))))
                            (list (cons 'user user-file)
                                  (cons 'project project-file)
                                  (cons 'defaults (drgnx-agent-config-gemini--settings-file 'defaults root))
                                  (cons 'system (drgnx-agent-config-gemini--settings-file 'system root))))))
             (values (mapcar #'caddr settings))
             (disabled-skills (apply #'append (mapcar (lambda (v) (drgnx-agent-config-gemini--strings
                                                                   (drgnx-agent-config-gemini--get v "skills" "disabled")))
                                                      values)))
             (disabled-hooks (apply #'append (mapcar (lambda (v) (drgnx-agent-config-gemini--strings
                                                                  (drgnx-agent-config-gemini--get v "hooksConfig" "disabled")))
                                                     values)))
             (ext-dir (expand-file-name "extensions" home))
             (enablement (plist-get (read-json (expand-file-name "extension-enablement.json" ext-dir) t) :value)))
        ;; settings files: MCP servers and hooks
        (dolist (entry settings)
          (cl-destructuring-bind (scope file value commented) entry
            (let* ((system (memq scope '(system defaults)))
                   (readonly (or system commented))
                   (from (if system 'system scope)))
              (when commented
                (push (format "%s has comments: shown read-only, because drgnx cannot keep comments when it writes (Gemini does)"
                              file)
                      notes))
              (add (drgnx-agent-config-gemini--server-items
                    (drgnx-agent-config-gemini--get value "mcpServers") from file '("mcpServers") readonly))
              (add (drgnx-agent-config-gemini--hook-items value from file readonly disabled-hooks))
              (when (eq (drgnx-agent-config-gemini--get value "hooksConfig" "enabled") :false)
                (push (format "%s switches every hook off (hooksConfig.enabled)" file) notes))
              (when (eq (drgnx-agent-config-gemini--get value "skills" "enabled") :false)
                (push (format "%s switches every skill off (skills.enabled)" file) notes)))))
        ;; extensions
        (let ((extensions nil))
          (dolist (dir (and (file-directory-p ext-dir) (directory-files ext-dir t "\\`[^.]")))
            (let* ((manifest (expand-file-name "gemini-extension.json" dir))
                   (value (plist-get (read-json manifest t) :value)))
              (when (drgnx-agent-config-gemini--alist-p value)
                (let* ((name (or (drgnx-agent-config-gemini--str (drgnx-agent-config-gemini--get value "name"))
                                 (file-name-nondirectory dir)))
                       (on (drgnx-agent-config-gemini--extension-enabled-p name enablement root))
                       (hooks-file (expand-file-name "hooks/hooks.json" dir)))
                  (push (list name dir on) extensions)
                  (dolist (item (drgnx-agent-config-gemini--server-items
                                 (drgnx-agent-config-gemini--get value "mcpServers") 'extension manifest
                                 '("mcpServers") t (format "extension:%s:" name)))
                    (add (list (plist-put item :enabled on))))
                  (dolist (item (drgnx-agent-config-gemini--hook-items
                                 (plist-get (read-json hooks-file t) :value) 'extension hooks-file t disabled-hooks))
                    (add (list (plist-put item :enabled (and on (plist-get item :enabled))))))))))
          ;; skills
          (dolist (spec (list (cons 'user (drgnx-agent-config-gemini--skills-dir 'user root))
                              (cons 'user (expand-file-name "skills" (drgnx-agent-config-gemini--agents-dir)))
                              (cons 'project (drgnx-agent-config-gemini--skills-dir 'project root))
                              (cons 'project (and root (expand-file-name ".agents/skills" root)))))
            (dolist (skill (and (cdr spec) (drgnx-agent-config-skills-in (cdr spec) (car spec) 'gemini)))
              (add (list (plist-put skill :enabled (not (member (plist-get skill :name) disabled-skills)))))))
          (dolist (extension (nreverse extensions))
            (dolist (skill (drgnx-agent-config-skills-in (expand-file-name "skills" (nth 1 extension)) 'extension 'gemini))
              (add (list (plist-put (plist-put skill :readonly t) :enabled
                                    (and (nth 2 extension) (not (member (plist-get skill :name) disabled-skills)))))))))
        ;; rules
        (let ((names (drgnx-agent-config-gemini--context-names values)))
          (setq rules (cl-remove-duplicates
                       (cl-remove-if-not
                        #'file-regular-p
                        (append (mapcar (lambda (n) (expand-file-name n home)) names)
                                (and root (mapcar (lambda (n) (expand-file-name n root)) names))))
                       :test #'equal :from-end t)))))
    (list :rules rules :items items :problems (nreverse problems)
          :routes (drgnx-agent-config-gemini-routes root)
          :notes (nreverse notes))))

(defun drgnx-agent-config-gemini-routes (_root)
  "Gemini has one route: its own CLI with a Google login (the subscription), whose login drgnx never reads."
  (list (list :profile "Gemini CLI" :kind nil :base-url nil :model nil
              :key-where "its own CLI with a Google login (drgnx never reads it)"
              :billing 'subscription :vendor "Google")))

(cl-defmethod drgnx-agent-config-scopes ((_kind (eql 'gemini)) section root)
  (let ((root (drgnx-agent-config-gemini--root root)))
    (pcase section
      ((or 'mcp 'hook)
       (append (list (list 'user "User (all projects)" (drgnx-agent-config-gemini--settings-file 'user root)))
               (and root (list (list 'project "Project (.gemini/settings.json, shared)"
                                     (drgnx-agent-config-gemini--settings-file 'project root))))))
      ('skill (append (list (list 'user "User (all projects)" (drgnx-agent-config-gemini--skills-dir 'user root)))
                      (and root (list (list 'project "Project" (drgnx-agent-config-gemini--skills-dir 'project root))))))
      (_ (error "No such section: %S" section)))))

;;;; Writing files

(defun drgnx-agent-config-gemini--modify (file function)
  "Replace the JSON object in FILE with (FUNCTION VALUE), VALUE being what FILE holds now.
A FILE with comments is refused (drgnx would drop them).  The write is refused, with `drgnx-agent-config-changed',
when FILE changed since it was read here.  Returns FILE."
  (let ((text (and (file-exists-p file) (drgnx-agent-config-read-text file))))
    (when (and text (cdr (drgnx-agent-config-gemini--strip-comments text)))
      (error "%s has comments, which drgnx would lose when it writes: change it by hand" file))
    (let* ((read (drgnx-agent-config-json-read file))
           (value (plist-get read :value)))
      (unless (or (null value) (drgnx-agent-config-gemini--alist-p value))
        (error "The file does not hold a JSON object"))
      (drgnx-agent-config-json-write file (funcall function value) (plist-get read :indent) text))
    file))

(defun drgnx-agent-config-gemini--write-mcp (op item scope root)
  "Add, edit or remove the MCP server ITEM in the settings file of SCOPE; returns the result."
  (let* ((name (plist-get item :name))
         (old (or (plist-get (plist-get item :replaces) :name) name))
         (file (drgnx-agent-config-gemini--settings-file scope root)))
    (unless (memq scope '(user project)) (error "No such scope for an MCP server"))
    (unless file (error "This scope needs a project"))
    (when (eq op 'toggle) (error "An MCP server cannot be switched off here"))
    (when (or (eq op 'add) (and (eq op 'edit) (not (equal old name)))) (drgnx-agent-config-gemini--check-name name))
    (let ((spec (and (memq op '(add edit)) (plist-get item :spec))))
      (when spec (drgnx-agent-config-gemini--spec-members spec)) ; refuse a bad spec before the file is read
      (drgnx-agent-config-gemini--modify
       file
       (lambda (value)
         (let ((existing (drgnx-agent-config-gemini--get value "mcpServers")))
           (pcase op
             ('add
              (when (drgnx-agent-config-gemini--cell existing name) (error "%s is already in this file" name))
              (drgnx-agent-config-gemini--set
               value (list "mcpServers" name)
               (drgnx-agent-config-gemini--merge-members nil (drgnx-agent-config-gemini--spec-members spec))))
             ('edit
              (let ((cell (drgnx-agent-config-gemini--cell existing old)))
                (unless cell (error "%s is not in this file" old))
                (when (and (not (equal old name)) (drgnx-agent-config-gemini--cell existing name))
                  (error "%s is already in this file" name))
                (let ((entry (drgnx-agent-config-gemini--merge-members
                              (cdr cell) (drgnx-agent-config-gemini--spec-members spec (cdr cell)))))
                  (if (equal old name)
                      (drgnx-agent-config-gemini--set value (list "mcpServers" name) entry)
                    ;; renamed: the entry keeps its place among the servers
                    (drgnx-agent-config-gemini--set
                     value '("mcpServers")
                     (mapcar (lambda (c) (if (eq c cell) (cons (intern name) entry) c)) existing))))))
             ('remove
              (unless (drgnx-agent-config-gemini--cell existing name) (error "%s is not in this file" name))
              (let ((without (drgnx-agent-config-gemini--del value (list "mcpServers" name))))
                (if (drgnx-agent-config-gemini--get without "mcpServers") without
                  (drgnx-agent-config-gemini--del without '("mcpServers"))))))))))
    (list :ok t :note (format "Wrote %s. Restart running Gemini sessions to pick this up" file))))

;;;; Writing hooks

(defun drgnx-agent-config-gemini--matcher= (group matcher)
  "Non-nil when the hook GROUP has the matcher MATCHER (nil and \"\" are the same)."
  (equal (or (drgnx-agent-config-gemini--str (drgnx-agent-config-gemini--get group "matcher")) "") (or matcher "")))

(defun drgnx-agent-config-gemini--hook-json (spec base)
  "The hook object for the hook SPEC: BASE (the hook it replaces, or nil) with the modelled members replaced."
  (let ((hook (drgnx-agent-config-gemini--set base '("type") "command")))
    (setq hook (drgnx-agent-config-gemini--set hook '("command") (plist-get spec :command)))
    (if (numberp (plist-get spec :timeout))
        (drgnx-agent-config-gemini--set hook '("timeout") (plist-get spec :timeout))
      (drgnx-agent-config-gemini--del hook '("timeout")))))

(defun drgnx-agent-config-gemini--command-hook-p (hook command)
  "Non-nil when HOOK is a command hook running COMMAND."
  (and (equal (drgnx-agent-config-gemini--get hook "type") "command")
       (equal (drgnx-agent-config-gemini--get hook "command") command)))

(defun drgnx-agent-config-gemini--hooks-update (value old new)
  "The settings VALUE with the hook OLD (a spec: :event :matcher :command; nil for none) replaced by NEW.
The hook's other members (name, description) stay; a hook whose event and matcher stay the same keeps its place."
  (let ((base nil) (in-place nil))
    (when old
      (let* ((event (plist-get old :event))
             (found nil)
             (same-place (and new (equal (plist-get new :event) event)
                              (equal (or (plist-get new :matcher) "") (or (plist-get old :matcher) ""))))
             (groups
              (delq nil
                    (mapcar
                     (lambda (group)
                       (let* ((hooks (and (not found) (drgnx-agent-config-gemini--matcher= group (plist-get old :matcher))
                                          (append (drgnx-agent-config-gemini--get group "hooks") nil)))
                              (pos (and hooks (cl-position-if (lambda (h) (drgnx-agent-config-gemini--command-hook-p
                                                                           h (plist-get old :command)))
                                                              hooks))))
                         (cond ((null pos) group)
                               (same-place
                                (setq found t in-place t base (nth pos hooks))
                                (setf (nth pos hooks) (drgnx-agent-config-gemini--hook-json new base))
                                (drgnx-agent-config-gemini--set group '("hooks") (vconcat hooks)))
                               (t
                                (setq found t base (nth pos hooks))
                                (setq hooks (append (take pos hooks) (nthcdr (1+ pos) hooks)))
                                (and hooks (drgnx-agent-config-gemini--set group '("hooks") (vconcat hooks)))))))
                     (append (drgnx-agent-config-gemini--get value "hooks" event) nil)))))
        (unless found (error "The hook was not found in this file"))
        (setq value (if groups
                        (drgnx-agent-config-gemini--set value (list "hooks" event) (vconcat groups))
                      (let ((without (drgnx-agent-config-gemini--del value (list "hooks" event))))
                        (if (drgnx-agent-config-gemini--get without "hooks") without
                          (drgnx-agent-config-gemini--del without '("hooks"))))))))
    (when (and new (not in-place))
      (let* ((event (plist-get new :event))
             (matcher (plist-get new :matcher))
             (groups (append (drgnx-agent-config-gemini--get value "hooks" event) nil))
             (pos (cl-position-if (lambda (g) (drgnx-agent-config-gemini--matcher= g matcher)) groups))
             (hook (drgnx-agent-config-gemini--hook-json new base)))
        (if pos
            (setf (nth pos groups)
                  (drgnx-agent-config-gemini--set
                   (nth pos groups) '("hooks")
                   (vconcat (drgnx-agent-config-gemini--get (nth pos groups) "hooks") (list hook))))
          (setq groups (append groups
                               (list (append (and matcher (not (string-empty-p matcher)) (list (cons 'matcher matcher)))
                                             (list (cons 'hooks (vector hook))))))))
        (setq value (drgnx-agent-config-gemini--set value (list "hooks" event) (vconcat groups)))))
    value))

(defun drgnx-agent-config-gemini--write-hook (op item scope root)
  "Add, edit or remove the hook ITEM in the settings file of SCOPE; returns the result."
  (let* ((file (and (memq scope '(user project)) (drgnx-agent-config-gemini--settings-file scope root)))
         (spec (plist-get item :spec))
         (previous (if (eq op 'add) nil (or (plist-get (plist-get item :replaces) :spec) spec))))
    (unless (memq scope '(user project)) (error "No such scope for a hook"))
    (unless file (error "This scope needs a project"))
    (when (eq op 'toggle) (error "A hook cannot be switched off here"))
    (when (memq op '(add edit))
      (unless (member (plist-get spec :event) drgnx-agent-config-gemini--events)
        (error "A hook needs one of Gemini's events: %s" (string-join drgnx-agent-config-gemini--events ", ")))
      (unless (and (stringp (plist-get spec :command)) (not (string-empty-p (plist-get spec :command))))
        (error "A hook needs a command")))
    (drgnx-agent-config-gemini--modify
     file (lambda (value) (drgnx-agent-config-gemini--hooks-update value previous (and (memq op '(add edit)) spec))))
    (list :ok t :note (format "Wrote %s. Restart running Gemini sessions to pick this up" file))))

;;;; Writing skills

(defun drgnx-agent-config-gemini--without-name (value name)
  "The settings VALUE without NAME in skills.disabled (and without the member when that leaves it empty)."
  (let* ((names (cl-remove name (append (drgnx-agent-config-gemini--get value "skills" "disabled") nil) :test #'equal))
         (set (lambda (v) (drgnx-agent-config-gemini--set v '("skills" "disabled") (vconcat names)))))
    (if names
        (funcall set value)
      (let ((without (drgnx-agent-config-gemini--del value '("skills" "disabled"))))
        (if (drgnx-agent-config-gemini--get without "skills") without
          (drgnx-agent-config-gemini--del without '("skills")))))))

(defun drgnx-agent-config-gemini--describe-file (file scope root)
  "FILE of SCOPE for a note: the project's settings are shared with the team."
  (if (eq scope 'project)
      (format "%s (project: shared with the team)" (if root (file-relative-name file root) file))
    file))

(defun drgnx-agent-config-gemini--lists-skill-p (value name)
  "Non-nil when the settings VALUE lists NAME in skills.disabled."
  (member name (drgnx-agent-config-gemini--strings (drgnx-agent-config-gemini--get value "skills" "disabled"))))

(defun drgnx-agent-config-gemini--skill-on (name root)
  "Take NAME out of skills.disabled of every writable settings file that lists it; return ((FILE . SCOPE)…) written.
All the files are checked first (the system settings do not list it; the others parse, have no comments); nothing
is written when one fails.  If a later write fails, the files already written are put back and the error says so."
  (dolist (scope '(system defaults))
    (let ((file (drgnx-agent-config-gemini--settings-file scope root)))
      (when (and (file-regular-p file)
                 (drgnx-agent-config-gemini--lists-skill-p
                  (plist-get (drgnx-agent-config-gemini--read-file file) :value) name))
        (error "%s is switched off by the system settings, which drgnx does not change" name))))
  (let (plan done)
    (dolist (scope '(user project))
      (let ((file (drgnx-agent-config-gemini--settings-file scope root)))
        (when (and file (file-regular-p file))
          (let ((read (drgnx-agent-config-gemini--read-file file)))
            (when (drgnx-agent-config-gemini--lists-skill-p (plist-get read :value) name)
              (when (plist-get read :commented)
                (error "%s has comments, which drgnx would lose when it writes: change it by hand" file))
              (push (cons file scope) plan))))))
    (condition-case err
        (dolist (entry (nreverse plan))
          (let ((before (drgnx-agent-config-read-text (car entry))))
            (drgnx-agent-config-gemini--modify
             (car entry) (lambda (value) (drgnx-agent-config-gemini--without-name value name)))
            (push (list entry before (drgnx-agent-config-read-text (car entry))) done)))
      (error
       (let (undone stuck)
         (dolist (d done)
           (if (condition-case nil
                   (progn (drgnx-agent-config-write-text (caar d) (nth 1 d) #'ignore nil (nth 2 d)) t)
                 (error nil))
               (push (caar d) undone)
             (push (caar d) stuck)))
         (error "%s%s%s" (drgnx-agent-config-gemini--error-text err nil)
                (if undone (format "; the change to %s was undone" (string-join (nreverse undone) ", ")) "")
                (if stuck (format "; the change to %s could NOT be undone (its backup has the previous content)"
                                  (string-join (nreverse stuck) ", "))
                  "")))))
    (nreverse (mapcar #'car done))))

(defun drgnx-agent-config-gemini--write-skill (op item scope root)
  "Add the skill ITEM to SCOPE, or switch it on or off (SCOPE then names the settings file written, nil: the user's);
returns the result."
  (let ((name (plist-get item :name)))
    (pcase op
      ('add (let ((dir (drgnx-agent-config-gemini--skills-dir scope root)))
              (unless dir (error "This scope needs a project"))
              (list :ok t :note (format "Created %s"
                                        (drgnx-agent-config-new-skill
                                         dir name (or (plist-get (plist-get item :spec) :description) ""))))))
      ('toggle
       (if (plist-get item :enabled)
           (let* ((target (or scope 'user))
                  (file (and (memq target '(user project)) (drgnx-agent-config-gemini--settings-file target root))))
             (unless file (error "This scope needs a project"))
             (drgnx-agent-config-gemini--modify
              file (lambda (value)
                     (let ((names (append (drgnx-agent-config-gemini--get value "skills" "disabled") nil)))
                       (if (member name names) value
                         (drgnx-agent-config-gemini--set value '("skills" "disabled") (vconcat names (list name)))))))
             (list :ok t :note (format "%s is now off (written to %s)" name
                                       (drgnx-agent-config-gemini--describe-file file target root))))
         (let ((files (drgnx-agent-config-gemini--skill-on name root)))
           (list :ok t :note (if files
                                 (format "%s is now on (removed from %s)" name
                                         (mapconcat (lambda (f) (drgnx-agent-config-gemini--describe-file (car f) (cdr f) root))
                                                    files " and "))
                               (format "%s is now on (no settings file switched it off)" name))))))
      (_ (error "Only adding a skill and switching one on or off are supported")))))

;;;; The generic write

(cl-defmethod drgnx-agent-config-write ((_kind (eql 'gemini)) op item scope root callback)
  "Do OP (add, edit, remove or toggle) with ITEM in SCOPE for Gemini CLI; the result goes to CALLBACK at once.
For an edit, ITEM carries the new definition and :replaces the item it replaces (the old name, or the old hook).
MCP servers and hooks: SCOPE user or project, the settings file; only the modelled members of the entry change.
Skills: add to user or project; toggle writes `skills.disabled' (SCOPE: the settings file, default the user's).
Items from extensions or the system settings, and from a settings file with comments, are read-only."
  (let* ((root (drgnx-agent-config-gemini--root root))
         (result
          (condition-case err
              (progn
                (when (and (plist-get item :readonly) (not (and (eq op 'toggle) (eq (plist-get item :section) 'skill))))
                  (error "This item is read-only: it comes from an extension, the system settings or a file with comments"))
                (pcase (plist-get item :section)
                  ('mcp (drgnx-agent-config-gemini--write-mcp op item scope root))
                  ('hook (drgnx-agent-config-gemini--write-hook op item scope root))
                  ('skill (drgnx-agent-config-gemini--write-skill op item scope root))
                  (_ (error "No such section"))))
            (error (list :error (drgnx-agent-config-gemini--error-text err item))))))
    (funcall callback result)
    nil))

(provide 'drgnx-agent-config-gemini)
;;; drgnx-agent-config-gemini.el ends here
