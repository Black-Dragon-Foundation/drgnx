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

(defun drgnx-agent-settings-test--item-line (name)
  "The text of the first line of the item called NAME on the page in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((found nil))
      (while (and (not found) (not (eobp)))
        (let ((item (get-text-property (point) 'drgnx-agent-settings-item)))
          (if (and item (equal (plist-get item :name) name))
              (setq found (buffer-substring-no-properties (line-beginning-position) (line-end-position)))
            (forward-line 1))))
      found)))

(defun drgnx-agent-settings-test--goto-item (name)
  (goto-char (point-min))
  (while (not (let ((item (get-text-property (point) 'drgnx-agent-settings-item)))
                (and item (equal (plist-get item :name) name))))
    (when (eobp) (error "No item %s on the page" name))
    (forward-line 1)))

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
      (should-not (string-search "k-1234567" (buffer-string))))))

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
          (call-interactively #'drgnx-agent-settings-test)
          (should (equal (plist-get (car (car callbacks)) :name) "docs"))
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
          (should (string-search "exit 0" (drgnx-agent-settings-test--item-line "PreToolUse Bash"))))))))

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
                   agent-settings-new-skill agent-settings-open-file agent-settings-other))

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

;;; mod-agent-settings-test.el ends here
