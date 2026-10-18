;;; mod-agent-settings-test.el --- batch tests: the agent settings page -*- lexical-binding: t -*-
;; Every agent home is a temp directory (test/fixtures/agent-config-fixture.el); nothing of the user's is read or
;; written.  Minibuffer answers come from a queue (`drgnx-agent-settings-test--answering'); Test is stubbed where a
;; result is fed by hand.
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx)
(require 'drgnx-registry)
(require 'drgnx-keys)
(require 'drgnx-agents)
(load (expand-file-name "test/fixtures/agent-config-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-agents-ui" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-agent-settings" drgnx-dir) nil t)

(defconst drgnx-agent-settings-test--secret "s3cr3t-env-value-0123456789"
  "The fixture's environment value: it must never reach the page or `*Messages*'.")

(defconst drgnx-agent-settings-test--header-secret "hdr-s3cr3t-9876543210"
  "The fixture's header value.")

(defun drgnx-agent-settings-test--write (file text)
  (make-directory (file-name-directory file) t)
  (write-region text nil file nil 'silent))

(defun drgnx-agent-settings-test--read (file)
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defun drgnx-agent-settings-test--claude-files (root)
  "Claude Code's fixture: a user server with a secret env value, a project server over HTTP with a secret header, a
user hook, a user skill and a CLAUDE.md."
  (let ((home (getenv "CLAUDE_CONFIG_DIR")))
    (drgnx-agent-settings-test--write
     (expand-file-name ".claude.json" home)
     (format "{\n  \"mcpServers\": {\n    \"github\": {\n      \"type\": \"stdio\",\n      \"command\": \"drgnx-no-such-command\",\n      \"args\": [\"--stdio\"],\n      \"env\": {\"GITHUB_TOKEN\": \"%s\"}\n    }\n  }\n}\n"
             drgnx-agent-settings-test--secret))
    (drgnx-agent-settings-test--write
     (expand-file-name ".mcp.json" root)
     (format "{\n  \"mcpServers\": {\n    \"docs\": {\n      \"type\": \"http\",\n      \"url\": \"https://example.invalid/mcp\",\n      \"headers\": {\"X-Api\": \"%s\"}\n    }\n  }\n}\n"
             drgnx-agent-settings-test--header-secret))
    (drgnx-agent-settings-test--write
     (expand-file-name "settings.json" home)
     "{\n  \"hooks\": {\n    \"PreToolUse\": [\n      {\"matcher\": \"Bash\", \"hooks\": [{\"type\": \"command\", \"command\": \"echo drgnx-hook\"}]}\n    ]\n  }\n}\n")
    (drgnx-agent-settings-test--write
     (expand-file-name "skills/my-skill/SKILL.md" home)
     "---\nname: my-skill\ndescription: Does one thing well\n---\n\nBody.\n")
    (drgnx-agent-settings-test--write (expand-file-name "CLAUDE.md" home) "# rules\n")))

(defmacro drgnx-agent-settings-test--env (&rest body)
  "BODY in the agent fixture (`home', `root'), with Claude Code's files written and no page left afterwards."
  (declare (indent 0))
  `(drgnx-agent-config-test-env
     (let ((drgnx-agents-profiles nil))
       (unwind-protect
           (progn (drgnx-agent-settings-test--claude-files root) ,@body)
         (dolist (b (buffer-list))
           (when (string-prefix-p "*agent settings: " (buffer-name b)) (kill-buffer b)))
         (clrhash drgnx-agent-settings--running)))))

(defun drgnx-agent-settings-test--name-here ()
  "The name of the item on this line (the text property is ((KIND SECTION NAME FILE) . ORDINAL))."
  (nth 2 (car (get-text-property (point) 'drgnx-agent-settings-item))))

(defun drgnx-agent-settings-test--item-line (name)
  "The text of the first line of the item called NAME on the page in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((found nil))
      (while (and (not found) (not (eobp)))
        (if (equal (drgnx-agent-settings-test--name-here) name)
            (setq found (buffer-substring-no-properties (line-beginning-position) (line-end-position)))
          (forward-line 1)))
      found)))

(defun drgnx-agent-settings-test--goto-item (name)
  (goto-char (point-min))
  (while (not (equal (drgnx-agent-settings-test--name-here) name))
    (when (eobp) (error "No item %s on the page" name))
    (forward-line 1)))

(defun drgnx-agent-settings-test--clear-messages ()
  (with-current-buffer (messages-buffer) (let ((inhibit-read-only t)) (erase-buffer))))

(defun drgnx-agent-settings-test--messages ()
  (with-current-buffer (messages-buffer) (buffer-string)))

(defvar drgnx-agent-settings-test--prompts nil "The prompts asked, newest first.")

(defmacro drgnx-agent-settings-test--answering (answers &rest body)
  "BODY with `completing-read', `read-string', `read-passwd' and `yes-or-no-p' answered from ANSWERS in order.
A `completing-read' answer is the first candidate that starts with it.  The prompts go to
`drgnx-agent-settings-test--prompts'."
  (declare (indent 1))
  `(let ((queue ,answers))
     (setq drgnx-agent-settings-test--prompts nil)
     (cl-flet ((next (prompt)
                 (push prompt drgnx-agent-settings-test--prompts)
                 (if queue (pop queue) (error "No answer left for %S" prompt))))
       (cl-letf (((symbol-function 'completing-read)
                  (lambda (prompt collection &rest _)
                    (let ((answer (next prompt))
                          (candidates (all-completions "" collection)))
                      (or (seq-find (lambda (c) (string-prefix-p answer c)) candidates) answer))))
                 ((symbol-function 'read-string) (lambda (prompt &rest _) (next prompt)))
                 ((symbol-function 'read-passwd) (lambda (prompt &rest _) (next prompt)))
                 ((symbol-function 'yes-or-no-p) (lambda (prompt) (next prompt)))
                 ((symbol-function 'y-or-n-p) (lambda (prompt) (next prompt))))
         ,@body))))

(ert-deftest drgnx-agent-settings/page-shows-sections-from-and-status ()
  (drgnx-agent-settings-test--env
    (with-current-buffer (drgnx-agent-settings-open 'claude root)
      (should (equal (buffer-name) "*agent settings: Claude Code*"))
      (should (derived-mode-p 'drgnx-agent-settings-mode))
      (let ((text (buffer-string)))
        ;; the agents row and the rules file
        (dolist (word '("Claude Code" "Codex" "Gemini" "Kimi Code" "CLAUDE.md"))
          (should (string-search word text)))
        ;; the sections, top to bottom
        (let ((positions (mapcar (lambda (h) (string-search h text)) '("Routes" "MCP Servers" "Hooks" "Skills"))))
          (should (cl-every #'integerp positions))
          (should (equal positions (sort (copy-sequence positions) #'<))))
        ;; the routes and their billing in words
        (should (string-search "flat: your subscription" text)))
      (let ((github (drgnx-agent-settings-test--item-line "github"))
            (docs (drgnx-agent-settings-test--item-line "docs"))
            (hook (drgnx-agent-settings-test--item-line "PreToolUse Bash"))
            (skill (drgnx-agent-settings-test--item-line "my-skill")))
        (should (string-search "user" github))
        (should (string-search "command not found" github))
        (should (string-search "project" docs))
        (should (string-search "ok" docs))
        (should (string-search "user" hook))
        (should (string-search "Test (runs the command)" hook))
        (should (string-search "user" skill)))
      ;; faces only inherit theme faces
      (should (equal (face-attribute 'drgnx-agent-settings-problem :inherit) 'error))
      (should (equal (face-attribute 'drgnx-agent-settings-heading :inherit) 'bold)))))

(ert-deftest drgnx-agent-settings/env-values-never-on-the-page ()
  (drgnx-agent-settings-test--env
    (with-current-buffer (drgnx-agent-settings-open 'claude root)
      (let ((text (buffer-string)))
        (should-not (string-search drgnx-agent-settings-test--secret text))
        (should-not (string-search drgnx-agent-settings-test--header-secret text))
        (should (string-search "GITHUB_TOKEN=••••" text))
        (should (string-search "X-Api: ••••" text))))))

(defun drgnx-agent-settings-test--count-processes (thunk)
  "How many processes THUNK starts (every way a process is made is counted, and still made)."
  (let ((count 0))
    (cl-letf* ((counting (lambda (orig) (lambda (&rest args) (cl-incf count) (apply orig args))))
               ((symbol-function 'make-process) (funcall counting (symbol-function 'make-process)))
               ((symbol-function 'call-process) (funcall counting (symbol-function 'call-process)))
               ((symbol-function 'call-process-region) (funcall counting (symbol-function 'call-process-region)))
               ((symbol-function 'process-file) (funcall counting (symbol-function 'process-file)))
               ((symbol-function 'start-process) (funcall counting (symbol-function 'start-process)))
               ((symbol-function 'start-file-process) (funcall counting (symbol-function 'start-file-process))))
      (funcall thunk))
    count))

(ert-deftest drgnx-agent-settings/opening-spawns-nothing ()
  (drgnx-agent-settings-test--env
    (let ((reads 0))
      (advice-add 'drgnx-agent-config-read :before (lambda (&rest _) (cl-incf reads)) '((name . drgnx-test-count)))
      (unwind-protect
          (progn
            (dolist (kind drgnx-agent-config-kinds)
              (should (= 0 (drgnx-agent-settings-test--count-processes
                            (lambda () (drgnx-agent-settings-open kind root))))))
            (should (= reads 4))
            (with-current-buffer (drgnx-agent-settings-open 'claude root)
              (should (= 0 (drgnx-agent-settings-test--count-processes #'drgnx-agent-settings-refresh))))
            (should (= reads 6)))
        (advice-remove 'drgnx-agent-config-read 'drgnx-test-count)))))

(ert-deftest drgnx-agent-settings/add-asks-scope-then-writes-one-entry ()
  (drgnx-agent-settings-test--env
    (with-current-buffer (drgnx-agent-settings-open 'claude root)
      (goto-char (point-min))
      (search-forward "MCP Servers")
      (drgnx-agent-settings-test--clear-messages)
      (drgnx-agent-settings-test--answering
          (list "Project" "fs" "stdio" "npx -y server-fs /tmp" "API_KEY" "k-1234567")
        (call-interactively #'drgnx-agent-settings-add))
      ;; the scope was the first question
      (should (string-match-p "\\`Where" (car (last drgnx-agent-settings-test--prompts))))
      (let* ((file (expand-file-name ".mcp.json" root))
             (servers (alist-get 'mcpServers (json-parse-string (drgnx-agent-settings-test--read file)
                                                                :object-type 'alist :array-type 'list))))
        (should (equal (mapcar #'car servers) '(docs fs)))   ; one entry added, the other kept
        (should (equal (alist-get 'command (alist-get 'fs servers)) "npx"))
        (should (equal (alist-get 'args (alist-get 'fs servers)) '("-y" "server-fs" "/tmp")))
        (should (equal (alist-get 'API_KEY (alist-get 'env (alist-get 'fs servers))) "k-1234567")))
      ;; the page was read again: the new server is on it, its value is not
      (should (drgnx-agent-settings-test--item-line "fs"))
      (should-not (string-search "k-1234567" (buffer-string)))
      (should (string-search "Wrote" (drgnx-agent-settings-test--messages)))
      (should-not (string-search "k-1234567" (drgnx-agent-settings-test--messages))))))

(ert-deftest drgnx-agent-settings/blank-env-keeps-the-value ()
  (drgnx-agent-settings-test--env
    (drgnx-agent-settings-test--write
     (expand-file-name ".mcp.json" root)
     (format "{\n  \"mcpServers\": {\n    \"fs\": {\n      \"type\": \"stdio\",\n      \"command\": \"old-server\",\n      \"env\": {\"API_KEY\": \"%s\"}\n    }\n  }\n}\n"
             drgnx-agent-settings-test--secret))
    (with-current-buffer (drgnx-agent-settings-open 'claude root)
      (drgnx-agent-settings-test--goto-item "fs")
      (with-current-buffer (messages-buffer) (let ((inhibit-read-only t)) (erase-buffer)))
      ;; name kept, transport kept, command line empty (keep), the same env name, an empty value (keep)
      (drgnx-agent-settings-test--answering (list "fs" "stdio" "" "API_KEY" "")
        (call-interactively #'drgnx-agent-settings-edit))
      (should (seq-find (lambda (p) (string-search "empty: keep the current value" p)) drgnx-agent-settings-test--prompts))
      (let* ((servers (alist-get 'mcpServers (json-parse-string
                                              (drgnx-agent-settings-test--read (expand-file-name ".mcp.json" root))
                                              :object-type 'alist :array-type 'list)))
             (fs (alist-get 'fs servers)))
        (should (equal (alist-get 'command fs) "old-server"))
        (should (equal (alist-get 'API_KEY (alist-get 'env fs)) drgnx-agent-settings-test--secret)))
      (should-not (string-search drgnx-agent-settings-test--secret (buffer-string)))
      (should-not (string-search drgnx-agent-settings-test--secret
                                 (with-current-buffer (messages-buffer) (buffer-string)))))))

(ert-deftest drgnx-agent-settings/test-updates-the-row ()
  (drgnx-agent-settings-test--env
    (let ((callbacks nil))
      (cl-letf (((symbol-function 'drgnx-agent-check-mcp)
                 (lambda (item _root callback) (push (cons item callback) callbacks) nil))
                ((symbol-function 'drgnx-agent-check-hook)
                 (lambda (item _root callback) (push (cons item callback) callbacks) nil)))
        (with-current-buffer (drgnx-agent-settings-open 'claude root)
          (drgnx-agent-settings-test--goto-item "docs")
          (drgnx-agent-settings-test--clear-messages)
          ;; a server from the project's files: asked first, with what it reaches; no: nothing starts
          (drgnx-agent-settings-test--answering (list nil)
            (call-interactively #'drgnx-agent-settings-test))
          (should (equal (car drgnx-agent-settings-test--prompts)
                         "docs is from the project's files. Start https://example.invalid/mcp? "))
          (should-not callbacks)
          (drgnx-agent-settings-test--answering (list t)
            (call-interactively #'drgnx-agent-settings-test))
          (should (equal (plist-get (car (car callbacks)) :name) "docs"))
          ;; the check gets the item as it is in the file (the page itself holds no values)
          (should (equal (cdr (assoc "X-Api" (plist-get (plist-get (car (car callbacks)) :spec) :headers)))
                         drgnx-agent-settings-test--header-secret))
          (should (string-search "testing" (drgnx-agent-settings-test--item-line "docs")))
          ;; the result arrives later (from a process): the row shows it, and it is kept masked
          (funcall (cdr (car callbacks)) (list :status 'ok :tools '("search" "fetch") :time 0.4))
          (let ((row (drgnx-agent-settings-test--item-line "docs")))
            (should-not (string-search "testing" row))
            (should (string-search "2 tools" row)))
          (should (equal (plist-get (drgnx-agent-check-last (car (car callbacks))) :status) 'ok))
          ;; a hook runs its command for real: asked first, with the command
          (drgnx-agent-settings-test--goto-item "PreToolUse Bash")
          (drgnx-agent-settings-test--answering (list nil)
            (call-interactively #'drgnx-agent-settings-test))
          (should (string-match-p "\\`Run echo drgnx-hook for real\\?" (car drgnx-agent-settings-test--prompts)))
          (should (= (length callbacks) 1))
          (drgnx-agent-settings-test--answering (list t)
            (call-interactively #'drgnx-agent-settings-test))
          (should (= (length callbacks) 2))
          (funcall (cdr (car callbacks)) (list :exit 0 :stdout "" :stderr "" :time 0.1))
          (should (string-search "exit 0" (drgnx-agent-settings-test--item-line "PreToolUse Bash")))
          (let ((messages (drgnx-agent-settings-test--messages)))
            (should-not (string-search drgnx-agent-settings-test--secret messages))
            (should-not (string-search drgnx-agent-settings-test--header-secret messages))))))))

(defun drgnx-agent-settings-test--codex-files (root)
  "Codex's fixture: a server that is on, one that is off, and one in an untrusted project (inactive)."
  (drgnx-agent-settings-test--write
   (expand-file-name "config.toml" (getenv "CODEX_HOME"))
   "[mcp_servers.on]\ncommand = \"drgnx-on\"\n\n[mcp_servers.off]\ncommand = \"drgnx-off\"\nenabled = false\n")
  (drgnx-agent-settings-test--write (expand-file-name ".codex/config.toml" root)
                                    "[mcp_servers.proj]\ncommand = \"drgnx-proj\"\n"))

(defmacro drgnx-agent-settings-test--counting-checks (&rest body)
  "BODY with the checks stubbed: `started' collects the names of the MCP servers, `hooks' counts hook runs."
  (declare (indent 0))
  `(let ((started nil) (hooks 0))
     (cl-letf (((symbol-function 'drgnx-agent-check-mcp)
                (lambda (item _root _callback) (push (plist-get item :name) started) nil))
               ((symbol-function 'drgnx-agent-check-hook) (lambda (&rest _) (cl-incf hooks) nil)))
       ,@body)))

(ert-deftest drgnx-agent-settings/test-all-skips-inactive-and-off ()
  (drgnx-agent-settings-test--env
    (drgnx-agent-settings-test--codex-files root)
    (drgnx-agent-settings-test--counting-checks
      (with-current-buffer (drgnx-agent-settings-open 'codex root)
        (drgnx-agent-settings-test--clear-messages)
        ;; nothing is asked: the only project server is inactive (the project is not trusted)
        (drgnx-agent-settings-test--answering nil
          (call-interactively #'drgnx-agent-settings-test-all))
        (should (equal started '("on")))
        (should (string-search "2 skipped" (drgnx-agent-settings-test--messages)))
        ;; one Test of the inactive server asks first, with its command
        (drgnx-agent-settings-test--goto-item "proj")
        (drgnx-agent-settings-test--answering (list nil)
          (call-interactively #'drgnx-agent-settings-test))
        (should (string-search "drgnx-proj" (car drgnx-agent-settings-test--prompts)))
        (should (equal started '("on")))))))

(ert-deftest drgnx-agent-settings/test-all-never-runs-a-hook-and-asks-before-project-servers ()
  (drgnx-agent-settings-test--env
    (drgnx-agent-settings-test--counting-checks
      (with-current-buffer (drgnx-agent-settings-open 'claude root)
        ;; declined: only the user's server starts
        (drgnx-agent-settings-test--answering (list nil)
          (call-interactively #'drgnx-agent-settings-test-all))
        (should (string-search "https://example.invalid/mcp" (car drgnx-agent-settings-test--prompts)))
        (should-not (string-search drgnx-agent-settings-test--header-secret (car drgnx-agent-settings-test--prompts)))
        (should (equal started '("github")))
        (clrhash drgnx-agent-settings--running)
        ;; accepted: both
        (setq started nil)
        (drgnx-agent-settings-test--answering (list t)
          (call-interactively #'drgnx-agent-settings-test-all))
        (should (equal (sort started #'string<) '("docs" "github")))
        (should (= hooks 0))))))

(ert-deftest drgnx-agent-settings/kill-ring-and-text-properties-hold-no-secret ()
  (drgnx-agent-settings-test--env
    (with-current-buffer (drgnx-agent-settings-open 'claude root)
      (let ((kill-ring nil) (helps nil))
        (kill-ring-save (point-min) (point-max))
        (dolist (text (list (prin1-to-string (car kill-ring)) (prin1-to-string (buffer-string))))
          (should-not (string-search drgnx-agent-settings-test--secret text))
          (should-not (string-search drgnx-agent-settings-test--header-secret text)))
        (should-not (text-property-not-all 0 (length (car kill-ring)) 'drgnx-agent-settings-item nil (car kill-ring)))
        (let ((pos (point-min)))
          (while (< pos (point-max))
            (when-let* ((help (get-text-property pos 'help-echo))) (push (format "%s" help) helps))
            (setq pos (next-single-property-change pos 'help-echo nil (point-max)))))
        (should helps)
        (dolist (help helps)
          (should-not (string-search drgnx-agent-settings-test--secret help))
          (should-not (string-search drgnx-agent-settings-test--header-secret help)))))))

(ert-deftest drgnx-agent-settings/toml-message-never-quotes-the-file ()
  (drgnx-agent-settings-test--env
    (drgnx-agent-settings-test--write
     (expand-file-name "config.toml" (getenv "CODEX_HOME"))
     "[mcp_servers.x]\ncommand = \"a\"\nenv = { TOKEN = \"abc\\qTOMLSECRET123\" }\n")
    (with-current-buffer (drgnx-agent-settings-open 'codex root)
      (let ((text (buffer-string)))
        (should (string-search "config.toml, line 3: not valid TOML" text))
        (should-not (string-search "TOMLSECRET123" text))
        (should-not (string-search "escape" text))))))

(ert-deftest drgnx-agent-settings/unreadable-file-shown-with-its-line ()
  (drgnx-agent-settings-test--env
    (let ((file (expand-file-name ".mcp.json" root)))
      (drgnx-agent-settings-test--write file "{\n  \"mcpServers\": {\n    \"a\": {\"command\": \"x\"},\n  }\n}\n")
      (with-current-buffer (drgnx-agent-settings-open 'claude root)
        (goto-char (point-min))
        (should (re-search-forward (concat (regexp-quote (abbreviate-file-name file)) ", line 3") nil t))
        (should (eq (get-text-property (match-beginning 0) 'face) 'drgnx-agent-settings-problem))))))

(defvar drgnx-agents-ui--session)

(ert-deftest drgnx-agent-settings/opens-for-the-agent-at-point ()
  (drgnx-agent-settings-test--env
    (let ((drgnx-agents-profiles '(("cx" :command ("codex-acp")))))
      ;; a transcript of a claude-agent-acp profile → Claude Code's page, for the session's project
      (with-temp-buffer
        (setq-local drgnx-agents-ui--session (drgnx-agents--make :name "a" :profile "claude" :cwd root))
        (call-interactively #'drgnx-agent-settings)
        (should (equal (buffer-name) "*agent settings: Claude Code*"))
        (should (equal drgnx-agent-settings--root (file-name-as-directory root))))
      ;; the Agents list, on a Codex session's row → Codex's page
      (with-temp-buffer
        (drgnx-agents-list-mode)
        (let ((inhibit-read-only t))
          (insert (propertize "b\n" 'tabulated-list-id (drgnx-agents--make :name "b" :profile "cx" :cwd root))))
        (goto-char (point-min))
        (call-interactively #'drgnx-agent-settings-here)
        (should (equal (buffer-name) "*agent settings: Codex*")))
      ;; no session: asked, Claude Code by default
      (with-temp-buffer
        (let ((default nil))
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_prompt _collection &optional _pred _req _init _hist def &rest _) (setq default def) def)))
            (call-interactively #'drgnx-agent-settings))
          (should (equal default "Claude Code"))
          (should (equal (buffer-name) "*agent settings: Claude Code*")))))))

(defconst drgnx-agent-settings-test--ids
  '(agent-settings agent-settings-here agent-settings-refresh agent-settings-test agent-settings-test-all
                   agent-settings-add agent-settings-edit agent-settings-remove agent-settings-toggle
                   agent-settings-new-skill agent-settings-open-file agent-settings-other agent-settings-report))

(ert-deftest drgnx-agent-settings/keys-in-all-three-profiles ()
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
        (drgnx-commands-problems nil) (drgnx-modules--table nil) (drgnx-modules--report nil)
        (ring-bell-function ring-bell-function) (use-dialog-box use-dialog-box)
        (use-short-answers use-short-answers) (inhibit-startup-screen inhibit-startup-screen)
        (profiles (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir)))
        (defaults (copy-keymap global-map))
        (maps (lambda (sym) (and (boundp sym) (keymapp (symbol-value sym)) (symbol-value sym)))))
    (drgnx--core-commands)
    (drgnx-modules-load-directory (expand-file-name "modules" drgnx-dir))
    (drgnx-modules-run 'startup)
    (cl-flet ((resolve (profile)
                (drgnx-keys-resolve :commands (drgnx-commands-all) :profiles profiles
                                    :layers (list (list profile 'app 'editing 'window)) :defaults defaults :maps maps)))
      (let ((before (mapcar (lambda (p) (cons p (plist-get (resolve p) :conflicts))) '(vscode emacs vim))))
        (funcall (plist-get (alist-get 'tools/agent-settings drgnx-modules--table) :setup))
        (dolist (id drgnx-agent-settings-test--ids)
          (should (drgnx-commands-get id)))
        (should (equal (drgnx-cmd-category (drgnx-commands-get 'agent-settings)) "Agents"))
        (should (equal (drgnx-cmd-category (drgnx-commands-get 'agent-settings-edit)) "Agent Settings"))
        (dolist (profile '(vscode emacs vim))
          (let* ((spec (alist-get profile profiles))
                 (r (resolve profile)))
            ;; every new id has an entry (a key or :none) in the profile
            (dolist (id drgnx-agent-settings-test--ids)
              (should (assq id (plist-get spec :bind))))
            ;; the page's keys are the same in all three
            (should (equal (seq-filter (lambda (b) (eq (plist-get b :id) 'agent-settings-edit)) (plist-get r :bindings))
                           (list (list :id 'agent-settings-edit :key "RET"
                                       :map '(drgnx-agent-settings . drgnx-agent-settings-mode-map) :layer profile)
                                 (list :id 'agent-settings-edit :key "e"
                                       :map '(drgnx-agent-settings . drgnx-agent-settings-mode-map) :layer profile))))
            (should (seq-find (lambda (b) (and (eq (plist-get b :id) 'agent-settings-here) (equal (plist-get b :key) ",")))
                              (plist-get r :bindings)))
            ;; no new conflict, no problem
            (should (equal (plist-get r :conflicts) (alist-get profile before)))
            (should-not (plist-get r :problems))))
        (should (seq-find (lambda (b) (and (eq (plist-get b :id) 'agent-settings) (equal (plist-get b :key) "SPC a c")))
                          (plist-get (resolve 'vim) :bindings)))))))

;;;; Fix round 2

(defun drgnx-agent-settings-test--goto-ref (name ordinal)
  "Go to the row of the ORDINAL-th item called NAME."
  (goto-char (point-min))
  (while (not (let ((ref (get-text-property (point) 'drgnx-agent-settings-item)))
                (and ref (equal (nth 2 (car ref)) name) (eql (cdr ref) ordinal))))
    (when (eobp) (error "No item %s #%s on the page" name ordinal))
    (forward-line 1)))

(defun drgnx-agent-settings-test--hooks (&rest commands)
  "Claude Code's user settings with one PreToolUse/Bash group running COMMANDS (each a command or (COMMAND TIMEOUT))."
  (drgnx-agent-settings-test--write
   (expand-file-name "settings.json" (getenv "CLAUDE_CONFIG_DIR"))
   (format "{\n  \"hooks\": {\n    \"PreToolUse\": [\n      {\"matcher\": \"Bash\", \"hooks\": [%s]}\n    ]\n  }\n}\n"
           (mapconcat (lambda (c)
                        (if (consp c)
                            (format "{\"type\": \"command\", \"command\": \"%s\", \"timeout\": %d}" (car c) (cadr c))
                          (format "{\"type\": \"command\", \"command\": \"%s\"}" c)))
                      commands ", "))))

(ert-deftest drgnx-agent-settings/secrets-in-args-url-and-hook-command-never-on-the-page ()
  (drgnx-agent-settings-test--env
    (drgnx-agent-settings-test--write
     (expand-file-name ".claude.json" (getenv "CLAUDE_CONFIG_DIR"))
     "{\"mcpServers\": {\"a\": {\"command\": \"srv\", \"args\": [\"--token\", \"ARGSECRET0123456789\"]},\n \"b\": {\"type\": \"http\", \"url\": \"https://x.invalid/mcp?api_key=URLSECRET0123456789\"}}}\n")
    (drgnx-agent-settings-test--hooks "curl -H 'Authorization: Bearer HOOKSECRET0123456789' https://x.invalid")
    (with-current-buffer (drgnx-agent-settings-open 'claude root)
      (let ((text (prin1-to-string (buffer-string))))
        (dolist (secret '("ARGSECRET0123456789" "URLSECRET0123456789" "HOOKSECRET0123456789"))
          (should-not (string-search secret text)))
        (should (string-search "--token ••••" text))
        (should (string-search "api_key=••••" text))
        (should (string-match-p "runs: curl -H 'Authorization: \\(Bearer \\)?••••' https://x.invalid" text))))))

(ert-deftest drgnx-agent-settings/kill-region-and-copy-region-as-kill-stay-clean ()
  (drgnx-agent-settings-test--env
    (with-current-buffer (drgnx-agent-settings-open 'claude root)
      (let ((kill-ring nil) (kill-read-only-ok t))
        (copy-region-as-kill (point-min) (point-max))
        (kill-region (point-min) (point-max))
        (should (= (length kill-ring) 2))
        (dolist (text kill-ring)
          (should-not (text-property-not-all 0 (length text) 'drgnx-agent-settings-item nil text))
          (should-not (string-search drgnx-agent-settings-test--secret (prin1-to-string text)))
          (should-not (string-search drgnx-agent-settings-test--header-secret (prin1-to-string text))))))))

(ert-deftest drgnx-agent-settings/hook-timeout-none-removes-it ()
  (drgnx-agent-settings-test--env
    (drgnx-agent-settings-test--hooks '("echo drgnx-hook" 30))
    (with-current-buffer (drgnx-agent-settings-open 'claude root)
      (drgnx-agent-settings-test--goto-item "PreToolUse Bash")
      ;; event, matcher, command (empty: keep), timeout: none
      (drgnx-agent-settings-test--answering (list "PreToolUse" "Bash" "" "none")
        (call-interactively #'drgnx-agent-settings-edit))
      (should (string-search "none or 0: no timeout" (car drgnx-agent-settings-test--prompts)))
      (let ((text (drgnx-agent-settings-test--read (expand-file-name "settings.json" (getenv "CLAUDE_CONFIG_DIR")))))
        (should (string-search "echo drgnx-hook" text))
        (should-not (string-search "timeout" text))))))

(ert-deftest drgnx-agent-settings/an-unexpected-read-error-says-could-not-be-read ()
  (drgnx-agent-settings-test--env
    (let ((page (drgnx-agent-settings-open 'claude root)))
      (cl-letf (((symbol-function 'drgnx-agent-config-read)
                 (lambda (&rest _) (error "Parse error near QUOTEDFILETEXT"))))
        (with-current-buffer page
          ;; Test reads the item again: refused with the fixed text
          (drgnx-agent-settings-test--goto-item "github")
          (let ((err (should-error (call-interactively #'drgnx-agent-settings-test) :type 'user-error)))
            (should (string-search "could not be read" (cadr err)))
            (should-not (string-search "QUOTEDFILETEXT" (cadr err))))
          ;; the page read again: one problem with the fixed text
          (drgnx-agent-settings-refresh)
          (should (string-search "could not be read" (buffer-string)))
          (should-not (string-search "QUOTEDFILETEXT" (buffer-string))))))))

(ert-deftest drgnx-agent-settings/two-hooks-with-one-key-are-two-rows ()
  (drgnx-agent-settings-test--env
    (drgnx-agent-settings-test--hooks "echo first" "echo second")
    (drgnx-agent-settings-test--counting-checks
      (with-current-buffer (drgnx-agent-settings-open 'claude root)
        ;; Test on the second asks about the second, and runs the second
        (drgnx-agent-settings-test--goto-ref "PreToolUse Bash" 1)
        (let ((ran nil))
          (cl-letf (((symbol-function 'drgnx-agent-check-hook)
                     (lambda (item &rest _) (push (plist-get (plist-get item :spec) :command) ran) nil)))
            (drgnx-agent-settings-test--answering (list t)
              (call-interactively #'drgnx-agent-settings-test)))
          (should (equal (car drgnx-agent-settings-test--prompts) "Run echo second for real? "))
          (should (equal ran '("echo second"))))
        ;; Remove on the second removes the second
        (drgnx-agent-settings-test--goto-ref "PreToolUse Bash" 1)
        (drgnx-agent-settings-test--answering (list t)
          (call-interactively #'drgnx-agent-settings-remove))
        (let ((text (drgnx-agent-settings-test--read (expand-file-name "settings.json" (getenv "CLAUDE_CONFIG_DIR")))))
          (should (string-search "echo first" text))
          (should-not (string-search "echo second" text)))))))

(ert-deftest drgnx-agent-settings/a-file-changed-on-disk-runs-nothing ()
  (drgnx-agent-settings-test--env
    (drgnx-agent-settings-test--counting-checks
      (with-current-buffer (drgnx-agent-settings-open 'claude root)
        (drgnx-agent-settings-test--hooks "echo CHANGED")
        (drgnx-agent-settings-test--goto-item "PreToolUse Bash")
        (let ((err (drgnx-agent-settings-test--answering (list t)
                     (should-error (call-interactively #'drgnx-agent-settings-test) :type 'user-error))))
          (should (string-search "changed on disk: Refresh (g)" (cadr err))))
        (should (equal (car drgnx-agent-settings-test--prompts) "Run echo drgnx-hook for real? "))
        (should (= hooks 0))
        ;; Test All: a server changed since the page was drawn is skipped, said so
        (drgnx-agent-settings-test--write
         (expand-file-name ".claude.json" (getenv "CLAUDE_CONFIG_DIR"))
         "{\"mcpServers\": {\"github\": {\"command\": \"something-else\"}}}\n")
        (drgnx-agent-settings-test--clear-messages)
        (drgnx-agent-settings-test--answering (list nil)
          (call-interactively #'drgnx-agent-settings-test-all))
        (should-not started)
        (should (string-search "1 skipped (changed on disk" (drgnx-agent-settings-test--messages)))))))

(ert-deftest drgnx-agent-settings/test-results-read-once-per-drawing ()
  (drgnx-agent-settings-test--env
    (let ((calls 0))
      (cl-letf (((symbol-function 'drgnx-agent-check-results) (lambda () (cl-incf calls) nil))
                ((symbol-function 'drgnx-agent-check-last) (lambda (&rest _) (error "Read once, not per item"))))
        (with-current-buffer (drgnx-agent-settings-open 'claude root)
          (should (= calls 1))
          (drgnx-agent-settings-refresh)
          (should (= calls 2)))))))

;;;; Final review minors

(ert-deftest drgnx-agent-settings/no-undo-and-test-all-draws-once ()
  ;; the page is redrawn whole: it keeps no undo; Test All draws once after it started every server, not per server
  (drgnx-agent-settings-test--env
    (drgnx-agent-settings-test--counting-checks
      (with-current-buffer (drgnx-agent-settings-open 'claude root)
        (should (eq buffer-undo-list t))
        (let ((draws 0))
          (cl-letf* ((real (symbol-function 'drgnx-agent-settings--redraw))
                     ((symbol-function 'drgnx-agent-settings--redraw) (lambda (&rest a) (cl-incf draws) (apply real a))))
            (drgnx-agent-settings-test--answering (list t)
              (call-interactively #'drgnx-agent-settings-test-all)))
          (should (equal (sort started #'string<) '("docs" "github")))
          (should (= draws 1)))))))

(ert-deftest drgnx-agent-settings/the-page-works-from-its-project-not-the-callers-directory ()
  ;; opened from a remote buffer, the page must not resolve anything against that host (a TRAMP call, and the wrong
  ;; base): its directory is the project's, or home; a relative command is the project's
  (drgnx-agent-settings-test--env
    (let ((default-directory "/ssh:drgnx-never-reached:/srv/"))
      (with-current-buffer (drgnx-agent-settings-open 'claude root)
        (should (equal default-directory root)))
      (with-current-buffer (drgnx-agent-settings-open 'claude nil)
        (should (equal default-directory (expand-file-name "~/")))))
    (let* ((bin (expand-file-name "tools/srv" root))
           (item (lambda (spec) (list :kind 'claude :section 'mcp :name "s" :spec spec))))
      (make-directory (file-name-directory bin) t)
      (write-region "#!/bin/sh\n" nil bin)
      (set-file-modes bin #o755)
      (let ((default-directory "/nonexistent/"))
        (should (eq (car (drgnx-agent-config-cheap-status (funcall item '(:command "./tools/srv")) root)) 'ok))
        (should (eq (car (drgnx-agent-config-cheap-status (funcall item '(:command "./srv" :cwd "tools")) root)) 'ok))
        (should (eq (car (drgnx-agent-config-cheap-status (funcall item '(:command "./tools/srv")) home))
                    'missing-command))))))

;;;; Report to drgnx (C11)

(defun drgnx-agent-settings-test--await (pred)
  "Wait (for a fake CLI) until PRED is non-nil; the value."
  (let ((deadline (+ (float-time) 15)) v)
    (while (and (not (setq v (funcall pred))) (< (float-time) deadline)) (accept-process-output nil 0.05))
    v))

(defun drgnx-agent-settings-test--argv-with (word)
  (seq-find (lambda (l) (string-search word l)) (drgnx-agent-config-test-argv)))

(defconst drgnx-agent-settings-test--codex-toml
  "# my codex\nmodel = \"gpt-x\"\n\n[mcp_servers.docs]\ncommand = \"npx\"\nargs = [\"-y\", \"docs\"]\n"
  "Codex's user config: a comment, a setting and a server, which a write must leave as they are.")

(ert-deftest drgnx-agent-settings/report-adds-the-drgnx-server ()
  (drgnx-agent-settings-test--env
    ;; Claude Code: the CLI is asked (argv logged by the fake), at user scope, with the outside server's command
    (with-current-buffer (drgnx-agent-settings-open 'claude root)
      (drgnx-agent-settings-test--answering (list t)
        (call-interactively #'drgnx-agent-settings-report))
      (should (string-search "drgnx" (car drgnx-agent-settings-test--prompts)))
      (let ((line (drgnx-agent-settings-test--await (lambda () (drgnx-agent-settings-test--argv-with "mcp add-json drgnx")))))
        (should line)
        (should (string-search "\"coord\",\"mcp\",\"--kind\",\"claude\"" line))
        (should (string-suffix-p "--scope user" line))
        (should-not (string-search "env" line))))      ; no token or key travels with it
    ;; Codex: [mcp_servers.drgnx] is appended, the rest of the file is byte-identical
    (let ((file (expand-file-name "config.toml" (getenv "CODEX_HOME"))))
      (drgnx-agent-settings-test--write file drgnx-agent-settings-test--codex-toml)
      (with-current-buffer (drgnx-agent-settings-open 'codex root)
        (should (string-search "Reports to drgnx: no" (buffer-string)))
        (drgnx-agent-settings-test--answering (list t)
          (call-interactively #'drgnx-agent-settings-report))
        (let ((after (drgnx-agent-settings-test--read file)))
          (should (string-prefix-p drgnx-agent-settings-test--codex-toml after))
          (should (string-search "[mcp_servers.drgnx]" after))
          (should (string-search "\"--kind\", \"codex\"" after))
          (should-not (string-search "env" (substring after (length drgnx-agent-settings-test--codex-toml)))))
        (should (string-search "Reports to drgnx: yes" (buffer-string)))))
    ;; Gemini and Kimi Code: a drgnx server with the same command, in their own user files
    (dolist (kind '(gemini kimi))
      (with-current-buffer (drgnx-agent-settings-open kind root)
        (drgnx-agent-settings-test--answering (list t)
          (call-interactively #'drgnx-agent-settings-report))
        (should (string-search "Reports to drgnx: yes" (buffer-string)))
        (should (member (format "%s" kind) (append (plist-get (plist-get (drgnx-agent-settings--reporting-item) :spec) :args) nil)))))
    ;; declining writes nothing
    (let ((file (expand-file-name "settings.json" (expand-file-name ".gemini" (getenv "GEMINI_CLI_HOME")))))
      (delete-file file)
      (with-current-buffer (drgnx-agent-settings-open 'gemini root)
        (should (string-search "Reports to drgnx: no" (buffer-string)))
        (drgnx-agent-settings-test--answering (list nil)
          (call-interactively #'drgnx-agent-settings-report))
        (should-not (file-exists-p file))))))

(ert-deftest drgnx-agent-settings/report-again-removes-it ()
  (drgnx-agent-settings-test--env
    ;; Codex: add, then again: the file is what it was
    (let ((file (expand-file-name "config.toml" (getenv "CODEX_HOME"))))
      (drgnx-agent-settings-test--write file drgnx-agent-settings-test--codex-toml)
      (with-current-buffer (drgnx-agent-settings-open 'codex root)
        (drgnx-agent-settings-test--answering (list t t)
          (call-interactively #'drgnx-agent-settings-report)
          (should (string-search "Reports to drgnx: yes" (buffer-string)))
          (call-interactively #'drgnx-agent-settings-report))
        (should (equal (drgnx-agent-settings-test--read file) drgnx-agent-settings-test--codex-toml))
        (should (string-search "Reports to drgnx: no" (buffer-string)))))
    ;; Claude Code: a drgnx server in the user's file is removed through the CLI
    (drgnx-agent-settings-test--write
     (expand-file-name ".claude.json" (getenv "CLAUDE_CONFIG_DIR"))
     "{\n  \"mcpServers\": {\n    \"drgnx\": {\"type\": \"stdio\", \"command\": \"/x/bin/drgnx\", \"args\": [\"coord\", \"mcp\", \"--kind\", \"claude\"]}\n  }\n}\n")
    (with-current-buffer (drgnx-agent-settings-open 'claude root)
      (drgnx-agent-settings-test--answering (list t)
        (call-interactively #'drgnx-agent-settings-report))
      (should (drgnx-agent-settings-test--await
               (lambda () (drgnx-agent-settings-test--argv-with "mcp remove drgnx --scope user")))))))

(ert-deftest drgnx-agent-settings/the-page-says-whether-it-reports ()
  (drgnx-agent-settings-test--env
    (with-current-buffer (drgnx-agent-settings-open 'claude root)
      (should (string-search "Reports to drgnx: no" (buffer-string)))
      (should (string-search "[Add drgnx]" (buffer-string)))
      ;; reading the page writes nothing and starts nothing
      (should-not (drgnx-agent-config-test-argv)))
    (drgnx-agent-settings-test--write
     (expand-file-name ".mcp.json" root)
     "{\n  \"mcpServers\": {\"drgnx\": {\"type\": \"stdio\", \"command\": \"/x/bin/drgnx\", \"args\": [\"coord\", \"mcp\", \"--kind\", \"claude\"]}}\n}\n")
    (with-current-buffer (drgnx-agent-settings-open 'claude root)
      (should (string-search "Reports to drgnx: yes" (buffer-string)))
      (should (string-search "[Remove drgnx]" (buffer-string)))
      ;; the button is on the page's map too
      (goto-char (point-min))
      (search-forward "[Remove drgnx]")
      (should (button-at (1- (point)))))))

;;; mod-agent-settings-test.el ends here
