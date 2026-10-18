;;; agent-config-claude-test.el --- batch tests: Claude Code's settings (MCP in three scopes, hooks, skills, routes) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-agent-config-claude)
(load (expand-file-name "test/fixtures/agent-config-fixture" drgnx-dir) nil t)

(defvar drgnx-agent-config-claude-test--rewrites nil
  "How many times the rewrite stub ran.")
(defvar drgnx-agent-config-claude-test--rewrite-once nil
  "Non-nil: the rewrite stub rewrites the file only the first time it runs.")

(defmacro drgnx-agent-config-claude-test-env (&rest body)
  "BODY in the agent settings fixture, with the managed settings in a temp dir (bound to `managed') and drgnx's
own configuration directory (agents.eld, ai.eld) in a temp dir too."
  (declare (indent 0))
  `(drgnx-agent-config-test-env
     (let* ((managed (expand-file-name "managed/" drgnx-agent-config-test--dir))
            (drgnx-agent-config-claude-managed-dir managed)
            (process-environment
             (cons (concat "DRGNX_CONFIG_DIR=" (expand-file-name "drgnx-config" drgnx-agent-config-test--dir))
                   process-environment)))
       (ignore managed)
       ,@body)))

(defun drgnx-agent-config-claude-test--put (file text)
  "Write TEXT to FILE (making its directory); return FILE."
  (make-directory (file-name-directory file) t)
  (write-region text nil file nil 'silent)
  file)

(defun drgnx-agent-config-claude-test--text (file)
  "The text of FILE."
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defun drgnx-agent-config-claude-test--value (file)
  "The parsed JSON of FILE."
  (plist-get (drgnx-agent-config-json-read file) :value))

(defun drgnx-agent-config-claude-test--get (value &rest keys)
  "VALUE (parsed JSON) at KEYS (strings)."
  (dolist (k keys value)
    (setq value (cdr (assoc k (mapcar (lambda (c) (cons (symbol-name (car c)) (cdr c))) value))))))

(defun drgnx-agent-config-claude-test--item (items section name)
  "The item of SECTION called NAME."
  (cl-find-if (lambda (i) (and (eq (plist-get i :section) section) (equal (plist-get i :name) name))) items))

(defun drgnx-agent-config-claude-test--names (items section)
  "The names of the SECTION items."
  (sort (mapcar (lambda (i) (plist-get i :name))
                (cl-remove-if-not (lambda (i) (eq (plist-get i :section) section)) items))
        #'string<))

(defun drgnx-agent-config-claude-test--write (op item scope root)
  "Run the write and wait (for a CLI) for its callback; return what the callback got."
  (let ((result nil) (deadline (+ (float-time) 15)))
    (drgnx-agent-config-write 'claude op item scope root (lambda (r) (setq result r)))
    (while (and (not result) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (or result (error "The write never called back"))))

(defun drgnx-agent-config-claude-test--mcp (name spec)
  "An MCP server item."
  (list :kind 'claude :section 'mcp :name name :spec spec :enabled t))

(defun drgnx-agent-config-claude-test--hook (event matcher command &optional timeout replaces)
  "A hook item."
  (list :kind 'claude :section 'hook :name event :enabled t :replaces replaces
        :spec (list :event event :matcher matcher :command command :timeout timeout)))

(defun drgnx-agent-config-claude-test--rewrite-stub (&rest _)
  "Stands in for Claude Code rewriting its file between our read and our write: every time, a new count."
  (let ((file (drgnx-agent-config-claude-json-file)) (n (1+ (or (bound-and-true-p drgnx-agent-config-claude-test--rewrites) 0))))
    (setq drgnx-agent-config-claude-test--rewrites n)
    (when (or (not (bound-and-true-p drgnx-agent-config-claude-test--rewrite-once)) (= n 1))
      (drgnx-agent-config-claude-test--put
       file (format "{\n  \"numStartups\": %d,\n  \"mcpServers\": {\"theirs\": {\"command\": \"other\"}}\n}\n" (+ 1 n))))))

;;;; Reading

(ert-deftest drgnx-agent-config-claude/reads-every-scope-with-its-from ()
  (drgnx-agent-config-claude-test-env
    (let* ((json (drgnx-agent-config-claude-json-file))
           (claude-home (drgnx-agent-config-home 'claude))
           (key (directory-file-name root)))
      (should (equal json (expand-file-name ".claude.json" (concat drgnx-agent-config-test--dir "claude"))))
      (drgnx-agent-config-claude-test--put
       json (format (concat "{\n  \"numStartups\": 3,\n"
                            "  \"mcpServers\": {\"u-srv\": {\"type\": \"stdio\", \"command\": \"npx\", \"args\": [\"-y\", \"pkg\"],"
                            " \"env\": {\"A\": \"b\"}}},\n"
                            "  \"projects\": {\"%s\": {\"mcpServers\": {\"l-srv\": {\"type\": \"http\","
                            " \"url\": \"https://example.com/mcp\", \"headers\": {\"X-Id\": \"7\"}}}},\n"
                            "    \"/elsewhere\": {\"mcpServers\": {\"other\": {\"command\": \"x\"}}}}\n}\n")
                    key))
      (drgnx-agent-config-claude-test--put (expand-file-name ".mcp.json" root)
                                           "{\"mcpServers\": {\"p-srv\": {\"command\": \"proj\"}}}")
      (drgnx-agent-config-claude-test--put (expand-file-name "managed-mcp.json" managed)
                                           "{\"mcpServers\": {\"m-srv\": {\"command\": \"managed\"}}}")
      (drgnx-agent-config-claude-test--put
       (expand-file-name "settings.json" claude-home)
       "{\"hooks\": {\"Stop\": [{\"hooks\": [{\"type\": \"command\", \"command\": \"echo user\", \"timeout\": 5}]}]}}")
      (drgnx-agent-config-claude-test--put
       (expand-file-name ".claude/settings.json" root)
       "{\"hooks\": {\"PreToolUse\": [{\"matcher\": \"Bash\", \"hooks\": [{\"type\": \"command\", \"command\": \"echo proj\"}]}]}}")
      (drgnx-agent-config-claude-test--put
       (expand-file-name ".claude/settings.local.json" root)
       "{\"hooks\": {\"Notification\": [{\"hooks\": [{\"type\": \"command\", \"command\": \"echo local\"}]}]}}")
      (drgnx-agent-config-claude-test--put
       (expand-file-name "managed-settings.json" managed)
       "{\"hooks\": {\"SessionStart\": [{\"hooks\": [{\"type\": \"command\", \"command\": \"echo managed\"}]}]}}")
      (drgnx-agent-config-claude-test--put (expand-file-name "skills/alpha/SKILL.md" claude-home)
                                           "---\nname: alpha\ndescription: Alpha skill\n---\nBody\n")
      (drgnx-agent-config-claude-test--put (expand-file-name ".claude/skills/beta/SKILL.md" root)
                                           "---\nname: beta\ndescription: Beta skill\n---\nBody\n")
      (drgnx-agent-config-claude-test--put (expand-file-name "CLAUDE.md" claude-home) "user rules\n")
      (drgnx-agent-config-claude-test--put (expand-file-name "CLAUDE.md" root) "project rules\n")
      (drgnx-agent-config-claude-test--put (expand-file-name ".claude/CLAUDE.md" root) "more project rules\n")
      (let* ((read (drgnx-agent-config-read 'claude root))
             (items (plist-get read :items)))
        (should-not (plist-get read :problems))
        (should (equal (drgnx-agent-config-claude-test--names items 'mcp) '("l-srv" "m-srv" "p-srv" "u-srv")))
        (let ((u (drgnx-agent-config-claude-test--item items 'mcp "u-srv")))
          (should (eq (plist-get u :from) 'user))
          (should (equal (plist-get u :file) json))
          (should-not (plist-get u :readonly))
          (should (= (plist-get u :line) 3))
          (should (equal (plist-get u :spec)
                         '(:type stdio :command "npx" :args ("-y" "pkg") :env (("A" . "b")) :url nil :headers nil))))
        (let ((l (drgnx-agent-config-claude-test--item items 'mcp "l-srv")))
          (should (eq (plist-get l :from) 'local))
          (should (= (plist-get l :line) 4))
          (should (equal (plist-get l :file) json))
          (should (eq (plist-get (plist-get l :spec) :type) 'http))
          (should (equal (plist-get (plist-get l :spec) :headers) '(("X-Id" . "7")))))
        (let ((p (drgnx-agent-config-claude-test--item items 'mcp "p-srv")))
          (should (eq (plist-get p :from) 'project))
          (should (equal (plist-get p :file) (expand-file-name ".mcp.json" root))))
        (let ((m (drgnx-agent-config-claude-test--item items 'mcp "m-srv")))
          (should (eq (plist-get m :from) 'system))
          (should (plist-get m :readonly))
          (should (equal (plist-get m :file) (expand-file-name "managed-mcp.json" managed))))
        (should (equal (mapcar (lambda (i) (cons (plist-get i :from) (plist-get (plist-get i :spec) :command)))
                               (cl-remove-if-not (lambda (i) (eq (plist-get i :section) 'hook)) items))
                       '((user . "echo user") (project . "echo proj") (local . "echo local") (system . "echo managed"))))
        (let ((h (cl-find 'user items :key (lambda (i) (and (eq (plist-get i :section) 'hook) (plist-get i :from))))))
          (should (equal (plist-get h :file) (expand-file-name "settings.json" claude-home)))
          (should (equal (plist-get (plist-get h :spec) :event) "Stop"))
          (should (= (plist-get (plist-get h :spec) :timeout) 5)))
        (should (plist-get (cl-find 'system items :key (lambda (i) (and (eq (plist-get i :section) 'hook) (plist-get i :from))))
                           :readonly))
        (should (equal (mapcar (lambda (i) (cons (plist-get i :name) (plist-get i :from)))
                               (cl-remove-if-not (lambda (i) (eq (plist-get i :section) 'skill)) items))
                       '(("alpha" . user) ("beta" . project))))
        (should (plist-get (drgnx-agent-config-claude-test--item items 'skill "alpha") :enabled))
        (should (equal (plist-get read :rules)
                       (list (expand-file-name "CLAUDE.md" claude-home) (expand-file-name "CLAUDE.md" root)
                             (expand-file-name ".claude/CLAUDE.md" root))))
        ;; without a project: only the user's
        (let ((items (plist-get (drgnx-agent-config-read 'claude nil) :items)))
          (should (equal (drgnx-agent-config-claude-test--names items 'mcp) '("m-srv" "u-srv"))))))))

(ert-deftest drgnx-agent-config-claude/scopes-name-the-files ()
  (drgnx-agent-config-claude-test-env
    (let ((json (drgnx-agent-config-claude-json-file)) (claude-home (drgnx-agent-config-home 'claude)))
      (should (equal (mapcar (lambda (s) (list (nth 0 s) (nth 2 s))) (drgnx-agent-config-scopes 'claude 'mcp root))
                     (list (list 'user json) (list 'local json) (list 'project (expand-file-name ".mcp.json" root)))))
      (should (equal (mapcar (lambda (s) (list (nth 0 s) (nth 2 s))) (drgnx-agent-config-scopes 'claude 'hook root))
                     (list (list 'user (expand-file-name "settings.json" claude-home))
                           (list 'project (expand-file-name ".claude/settings.json" root))
                           (list 'local (expand-file-name ".claude/settings.local.json" root)))))
      (should (equal (mapcar (lambda (s) (list (nth 0 s) (nth 2 s))) (drgnx-agent-config-scopes 'claude 'skill root))
                     (list (list 'user (expand-file-name "skills" claude-home))
                           (list 'project (expand-file-name ".claude/skills" root)))))
      (should (equal (mapcar #'car (drgnx-agent-config-scopes 'claude 'mcp nil)) '(user))))))

(ert-deftest drgnx-agent-config-claude/plugin-items-are-read-only ()
  (drgnx-agent-config-claude-test-env
    (let* ((claude-home (drgnx-agent-config-home 'claude))
           (plug (expand-file-name "plug/demo/1.0/" drgnx-agent-config-test--dir))
           (off (expand-file-name "plug/off/1.0/" drgnx-agent-config-test--dir))
           (installed (expand-file-name "plugins/installed_plugins.json" claude-home)))
      (drgnx-agent-config-claude-test--put (expand-file-name ".mcp.json" plug)
                                           "{\"mcpServers\": {\"plug-srv\": {\"command\": \"demo-server\"}}}")
      (drgnx-agent-config-claude-test--put (expand-file-name "skills/plug-skill/SKILL.md" plug)
                                           "---\nname: plug-skill\ndescription: From a plugin\n---\n")
      (drgnx-agent-config-claude-test--put (expand-file-name ".mcp.json" off)
                                           "{\"mcpServers\": {\"off-srv\": {\"command\": \"off-server\"}}}")
      (drgnx-agent-config-claude-test--put
       installed (format (concat "{\"version\": 2, \"plugins\": {\"demo@mk\": [{\"scope\": \"user\", \"installPath\": \"%s\"}],"
                                 " \"off@mk\": [{\"scope\": \"user\", \"installPath\": \"%s\"}]}}")
                         (directory-file-name plug) (directory-file-name off)))
      (drgnx-agent-config-claude-test--put (expand-file-name "settings.json" claude-home)
                                           "{\"enabledPlugins\": {\"demo@mk\": true, \"off@mk\": false}}")
      (let* ((items (plist-get (drgnx-agent-config-read 'claude root) :items))
             (server (drgnx-agent-config-claude-test--item items 'mcp "plugin:demo:plug-srv"))
             (skill (cl-find-if (lambda (i) (and (eq (plist-get i :section) 'skill) (eq (plist-get i :from) 'plugin))) items)))
        (should server)
        (should (eq (plist-get server :from) 'plugin))
        (should (plist-get server :readonly))
        (should (equal (plist-get (plist-get server :spec) :command) "demo-server"))
        (should-not (cl-find-if (lambda (i) (string-match-p "off-srv" (plist-get i :name))) items))
        (should skill)
        (should (plist-get skill :readonly))
        ;; writes to a plugin's server are refused and touch nothing
        (let* ((before (drgnx-agent-config-claude-test--text (expand-file-name ".mcp.json" plug)))
               (result (drgnx-agent-config-claude-test--write 'remove server 'user root)))
          (should (plist-get result :error))
          (should (equal (drgnx-agent-config-claude-test--text (expand-file-name ".mcp.json" plug)) before))
          (should-not (drgnx-agent-config-test-argv)))))))

;;;; Writing MCP servers

(ert-deftest drgnx-agent-config-claude/user-scope-goes-through-the-cli ()
  (drgnx-agent-config-claude-test-env
    (let ((json (drgnx-agent-config-claude-json-file))
          (item (drgnx-agent-config-claude-test--mcp
                 "github" '(:type stdio :command "npx" :args ("-y" "@x/github")))))
      (drgnx-agent-config-claude-test--put json "{\n  \"numStartups\": 1,\n  \"mcpServers\": {}\n}\n")
      (should (plist-get (drgnx-agent-config-claude-test--write 'add item 'user root) :ok))
      (should (equal (drgnx-agent-config-test-argv)
                     '("claude mcp add-json github {\"type\":\"stdio\",\"command\":\"npx\",\"args\":[\"-y\",\"@x/github\"]} --scope user")))
      ;; one backup next to the file before the CLI changes it
      (should (equal (drgnx-agent-config-claude-test--text (concat json ".drgnx-bak"))
                     (drgnx-agent-config-claude-test--text json)))
      (should (plist-get (drgnx-agent-config-claude-test--write 'remove item 'user root) :ok))
      (should (equal (car (last (drgnx-agent-config-test-argv))) "claude mcp remove github --scope user"))
      ;; edit = remove, then add
      (drgnx-agent-config-claude-test--put json "{\n  \"numStartups\": 1,\n  \"mcpServers\": {\"github\": {\"command\": \"old\"}}\n}\n")
      (let ((before (length (drgnx-agent-config-test-argv)))
            (edited (drgnx-agent-config-claude-test--mcp "github" '(:type stdio :command "npx" :args ("-y" "@x/github2")))))
        (should (plist-get (drgnx-agent-config-claude-test--write 'edit edited 'user root) :ok))
        (should (equal (nthcdr before (drgnx-agent-config-test-argv))
                       '("claude mcp remove github --scope user"
                         "claude mcp add-json github {\"type\":\"stdio\",\"command\":\"npx\",\"args\":[\"-y\",\"@x/github2\"]} --scope user")))))))

(ert-deftest drgnx-agent-config-claude/local-scope-runs-in-the-project ()
  (drgnx-agent-config-claude-test-env
    (let* ((bin (expand-file-name "bin2" drgnx-agent-config-test--dir))
           (log (expand-file-name "pwd.log" drgnx-agent-config-test--dir))
           (exec-path (cons bin exec-path))
           (process-environment (cons (concat "PATH=" bin path-separator (getenv "PATH")) process-environment)))
      (make-directory bin t)
      (drgnx-agent-config-claude-test--put (expand-file-name "claude" bin)
                                           (format "#!/bin/sh\nprintf '%%s|%%s\\n' \"$PWD\" \"$*\" >> '%s'\n" log))
      (set-file-modes (expand-file-name "claude" bin) #o755)
      (should (plist-get (drgnx-agent-config-claude-test--write
                          'add (drgnx-agent-config-claude-test--mcp "docs" '(:type http :url "https://example.com/mcp"))
                          'local root)
                         :ok))
      (let ((line (car (split-string (drgnx-agent-config-claude-test--text log) "\n" t))))
        (should (string-prefix-p (concat (directory-file-name (file-truename root)) "|") line))
        (should (string-suffix-p "mcp add-json docs {\"type\":\"http\",\"url\":\"https://example.com/mcp\"} --scope local" line))))))

(ert-deftest drgnx-agent-config-claude/cli-failures-are-reported ()
  (drgnx-agent-config-claude-test-env
    (let ((item (drgnx-agent-config-claude-test--mcp "x" '(:command "npx"))))
      ;; no claude on the path
      (let ((exec-path '("/nonexistent")))
        (let ((result (drgnx-agent-config-claude-test--write 'add item 'user root)))
          (should (string-match-p "claude" (plist-get result :error)))))
      ;; a failing claude
      (let* ((bin (expand-file-name "bin2" drgnx-agent-config-test--dir)) (exec-path (cons bin exec-path)))
        (drgnx-agent-config-claude-test--put (expand-file-name "claude" bin) "#!/bin/sh\necho 'secret-looking-output'\nexit 3\n")
        (set-file-modes (expand-file-name "claude" bin) #o755)
        (let ((result (drgnx-agent-config-claude-test--write 'add item 'user root)))
          (should (string-match-p "status 3" (plist-get result :error)))
          (should-not (string-match-p "secret-looking-output" (plist-get result :error))))
        ;; one that never ends is killed at the limit
        (drgnx-agent-config-claude-test--put (expand-file-name "claude" bin) "#!/bin/sh\nexec sleep 30\n")
        (let* ((drgnx-agent-config-claude-cli-timeout 0.5)
               (start (float-time))
               (result (drgnx-agent-config-claude-test--write 'add item 'user root)))
          (should (string-match-p "did not finish" (plist-get result :error)))
          (should (< (- (float-time) start) 10)))))))

(ert-deftest drgnx-agent-config-claude/no-secret-on-a-command-line ()
  (drgnx-agent-config-claude-test-env
    (let ((json (drgnx-agent-config-claude-json-file)))
      (drgnx-agent-config-claude-test--put json "{\n  \"numStartups\": 7,\n  \"mcpServers\": {\"keep\": {\"command\": \"k\"}}\n}\n")
      (let ((result (drgnx-agent-config-claude-test--write
                     'add (drgnx-agent-config-claude-test--mcp
                           "svc" '(:type stdio :command "svc-server" :env (("API_KEY" . "s3cret-value"))))
                     'user root)))
        (should (plist-get result :ok))
        (should (string-match-p "Restart running Claude sessions to pick this up" (plist-get result :note)))
        (should-not (string-match-p "s3cret-value" (format "%S" result))))
      ;; nothing ran, so the value is on no command line
      (should-not (drgnx-agent-config-test-argv))
      (should-not (string-match-p "s3cret-value" (format "%S" (drgnx-agent-config-test-argv))))
      ;; the file has it, and everything else is still there
      (let ((value (drgnx-agent-config-claude-test--value json)))
        (should (equal (drgnx-agent-config-claude-test--get value "mcpServers" "svc" "env" "API_KEY") "s3cret-value"))
        (should (equal (drgnx-agent-config-claude-test--get value "mcpServers" "svc" "command") "svc-server"))
        (should (equal (drgnx-agent-config-claude-test--get value "mcpServers" "keep" "command") "k"))
        (should (= (drgnx-agent-config-claude-test--get value "numStartups") 7)))
      (should (file-exists-p (concat json ".drgnx-bak")))
      ;; a secret in an http header
      (should (plist-get (drgnx-agent-config-claude-test--write
                          'add (drgnx-agent-config-claude-test--mcp
                                "web" '(:type http :url "https://example.com/mcp" :headers (("Authorization" . "Bearer tok-4321"))))
                          'user root)
                         :ok))
      (should-not (drgnx-agent-config-test-argv))
      ;; edit in place keeps the position; remove goes through the CLI (the name only)
      (should (plist-get (drgnx-agent-config-claude-test--write
                          'edit (drgnx-agent-config-claude-test--mcp
                                 "svc" '(:type stdio :command "svc-server2" :env (("API_KEY" . "s3cret-value-2"))))
                          'user root)
                         :ok))
      (should (equal (mapcar #'symbol-name (mapcar #'car (drgnx-agent-config-claude-test--get
                                                          (drgnx-agent-config-claude-test--value json) "mcpServers")))
                     '("keep" "svc" "web")))
      (should (plist-get (drgnx-agent-config-claude-test--write 'remove (drgnx-agent-config-claude-test--mcp "svc" nil) 'user root) :ok))
      (should (equal (drgnx-agent-config-test-argv) '("claude mcp remove svc --scope user"))))))

(ert-deftest drgnx-agent-config-claude/local-secret-creates-the-project-entry ()
  (drgnx-agent-config-claude-test-env
    (let ((json (drgnx-agent-config-claude-json-file)) (key (directory-file-name root)))
      (drgnx-agent-config-claude-test--put json "{\"numStartups\": 1, \"projects\": {\"/other\": {\"allowedTools\": []}}}\n")
      (should (plist-get (drgnx-agent-config-claude-test--write
                          'add (drgnx-agent-config-claude-test--mcp "loc" '(:command "x" :env (("TOKEN" . "abcd1234"))))
                          'local root)
                         :ok))
      (let ((value (drgnx-agent-config-claude-test--value json)))
        (should (equal (drgnx-agent-config-claude-test--get value "projects" key "mcpServers" "loc" "env" "TOKEN") "abcd1234"))
        (should (drgnx-agent-config-claude-test--get value "projects" key "allowedTools"))
        (should (equal (drgnx-agent-config-claude-test--get value "projects" key "hasTrustDialogAccepted") :false))
        (should (assoc "allowedTools" (mapcar (lambda (c) (cons (symbol-name (car c)) (cdr c)))
                                              (drgnx-agent-config-claude-test--get value "projects" "/other"))))))))

(ert-deftest drgnx-agent-config-claude/concurrent-rewrite-is-kept ()
  (drgnx-agent-config-claude-test-env
    (let ((json (drgnx-agent-config-claude-json-file))
          (drgnx-agent-config-claude-test--rewrites 0)
          (drgnx-agent-config-claude-test--rewrite-once t)
          (item (drgnx-agent-config-claude-test--mcp "ours" '(:command "mine" :env (("API_KEY" . "s3cret-value"))))))
      (drgnx-agent-config-claude-test--put json "{\n  \"numStartups\": 1,\n  \"mcpServers\": {}\n}\n")
      (advice-add 'drgnx-agent-config-json-write :before #'drgnx-agent-config-claude-test--rewrite-stub)
      (unwind-protect
          (should (plist-get (drgnx-agent-config-claude-test--write 'add item 'user root) :ok))
        (advice-remove 'drgnx-agent-config-json-write #'drgnx-agent-config-claude-test--rewrite-stub))
      (let ((value (drgnx-agent-config-claude-test--value json)))
        ;; their change (the count and their server) and ours
        (should (= (drgnx-agent-config-claude-test--get value "numStartups") 2))
        (should (equal (drgnx-agent-config-claude-test--get value "mcpServers" "theirs" "command") "other"))
        (should (equal (drgnx-agent-config-claude-test--get value "mcpServers" "ours" "command") "mine"))))))

(ert-deftest drgnx-agent-config-claude/endless-rewrites-are-reported-not-lost ()
  (drgnx-agent-config-claude-test-env
    (let ((json (drgnx-agent-config-claude-json-file))
          (drgnx-agent-config-claude-test--rewrites 0)
          (drgnx-agent-config-claude-test--rewrite-once nil)
          (item (drgnx-agent-config-claude-test--mcp "ours" '(:command "mine" :env (("API_KEY" . "s3cret-value"))))))
      (drgnx-agent-config-claude-test--put json "{\"numStartups\": 1}\n")
      (advice-add 'drgnx-agent-config-json-write :before #'drgnx-agent-config-claude-test--rewrite-stub)
      (let ((result (unwind-protect (drgnx-agent-config-claude-test--write 'add item 'user root)
                      (advice-remove 'drgnx-agent-config-json-write #'drgnx-agent-config-claude-test--rewrite-stub))))
        (should (string-match-p "changed" (plist-get result :error)))
        (should-not (string-match-p "s3cret-value" (format "%S" result))))
      (should-not (assoc "ours" (mapcar (lambda (c) (cons (symbol-name (car c)) (cdr c)))
                                        (drgnx-agent-config-claude-test--get (drgnx-agent-config-claude-test--value json) "mcpServers")))))))

(ert-deftest drgnx-agent-config-claude/project-file-and-unreadable-files ()
  (drgnx-agent-config-claude-test-env
    (let ((mcp (expand-file-name ".mcp.json" root)))
      ;; add creates .mcp.json; edit and remove keep the other servers and their order
      (should (plist-get (drgnx-agent-config-claude-test--write
                          'add (drgnx-agent-config-claude-test--mcp "a" '(:command "ca" :args ("1"))) 'project root)
                         :ok))
      (should (plist-get (drgnx-agent-config-claude-test--write
                          'add (drgnx-agent-config-claude-test--mcp "b" '(:type sse :url "https://example.com/sse")) 'project root)
                         :ok))
      (should (plist-get (drgnx-agent-config-claude-test--write
                          'edit (drgnx-agent-config-claude-test--mcp "a" '(:command "ca2")) 'project root)
                         :ok))
      (should (equal (mapcar #'symbol-name (mapcar #'car (drgnx-agent-config-claude-test--get
                                                          (drgnx-agent-config-claude-test--value mcp) "mcpServers")))
                     '("a" "b")))
      (should (equal (drgnx-agent-config-claude-test--get (drgnx-agent-config-claude-test--value mcp) "mcpServers" "a" "command")
                     "ca2"))
      (should (plist-get (drgnx-agent-config-claude-test--write 'remove (drgnx-agent-config-claude-test--mcp "a" nil) 'project root) :ok))
      (should-not (drgnx-agent-config-test-argv))
      ;; a file that does not parse: a problem with its line when read, never written
      (drgnx-agent-config-claude-test--put mcp "{\n  \"mcpServers\": {\n    \"x\": {\"command\": \"c\"},\n  }\n}\n")
      (let ((problem (car (plist-get (drgnx-agent-config-read 'claude root) :problems))))
        (should (equal (nth 0 problem) mcp))
        (should (= (nth 1 problem) 3)))
      (let* ((before (drgnx-agent-config-claude-test--text mcp))
             (result (drgnx-agent-config-claude-test--write
                      'add (drgnx-agent-config-claude-test--mcp "c" '(:command "cc")) 'project root)))
        (should (plist-get result :error))
        (should (string-match-p "line 3" (plist-get result :error)))
        (should (equal (drgnx-agent-config-claude-test--text mcp) before))))))

(ert-deftest drgnx-agent-config-claude/refuses-names-the-cli-would-read-as-flags ()
  (drgnx-agent-config-claude-test-env
    (dolist (name '("--scope" "-x" "a b" ""))
      (should (plist-get (drgnx-agent-config-claude-test--write
                          'add (drgnx-agent-config-claude-test--mcp name '(:command "x")) 'user root)
                         :error)))
    (should-not (drgnx-agent-config-test-argv))))

;;;; Hooks

(ert-deftest drgnx-agent-config-claude/hooks-add-edit-remove ()
  (drgnx-agent-config-claude-test-env
    (let* ((claude-home (drgnx-agent-config-home 'claude))
           (settings (expand-file-name "settings.json" claude-home))
           (hook-items (lambda (scope-root)
                         (cl-remove-if-not (lambda (i) (eq (plist-get i :section) 'hook))
                                           (plist-get (drgnx-agent-config-read 'claude scope-root) :items)))))
      (drgnx-agent-config-claude-test--put settings "{\n    \"theme\": \"dark\",\n    \"model\": \"opus\"\n}\n")
      (should (plist-get (drgnx-agent-config-claude-test--write
                          'add (drgnx-agent-config-claude-test--hook "PreToolUse" "Bash" "echo one" 5) 'user root)
                         :ok))
      (should (plist-get (drgnx-agent-config-claude-test--write
                          'add (drgnx-agent-config-claude-test--hook "PreToolUse" "Bash" "echo two") 'user root)
                         :ok))
      (should (plist-get (drgnx-agent-config-claude-test--write
                          'add (drgnx-agent-config-claude-test--hook "Stop" nil "echo stop") 'user root)
                         :ok))
      ;; the same matcher shares a group; the file keeps its other keys, order and indent
      (let ((value (drgnx-agent-config-claude-test--value settings)))
        (should (= (length (drgnx-agent-config-claude-test--get value "hooks" "PreToolUse")) 1))
        (should (= (length (drgnx-agent-config-claude-test--get (list (cons 'x (aref (drgnx-agent-config-claude-test--get
                                                                                      value "hooks" "PreToolUse") 0)))
                                                                "x" "hooks"))
                   2))
        (should (equal (mapcar #'car value) '(theme model hooks))))
      (should (string-match-p "^    \"theme\": \"dark\"" (drgnx-agent-config-claude-test--text settings)))
      (let ((items (funcall hook-items root)))
        (should (equal (mapcar (lambda (i) (plist-get (plist-get i :spec) :command)) items)
                       '("echo one" "echo two" "echo stop")))
        (should (equal (plist-get (nth 0 items) :name) "PreToolUse Bash"))
        (should (= (plist-get (plist-get (nth 0 items) :spec) :timeout) 5))
        ;; edit the first one in place (a new command and timeout)
        (should (plist-get (drgnx-agent-config-claude-test--write
                            'edit (drgnx-agent-config-claude-test--hook "PreToolUse" "Bash" "echo uno" 9 (nth 0 items)) 'user root)
                           :ok)))
      (let ((items (funcall hook-items root)))
        (should (equal (mapcar (lambda (i) (plist-get (plist-get i :spec) :command)) items)
                       '("echo uno" "echo two" "echo stop")))
        (should (= (plist-get (plist-get (nth 0 items) :spec) :timeout) 9))
        ;; moving it to another event
        (should (plist-get (drgnx-agent-config-claude-test--write
                            'edit (drgnx-agent-config-claude-test--hook "PostToolUse" "Edit" "echo uno" nil (nth 0 items)) 'user root)
                           :ok)))
      (should (equal (sort (mapcar (lambda (i) (plist-get (plist-get i :spec) :event)) (funcall hook-items root)) #'string<)
                     '("PostToolUse" "PreToolUse" "Stop")))
      ;; remove: empty groups and events go
      (dolist (i (funcall hook-items root))
        (should (plist-get (drgnx-agent-config-claude-test--write 'remove i 'user root) :ok)))
      (should-not (funcall hook-items root))
      (let ((value (drgnx-agent-config-claude-test--value settings)))
        (should (equal (mapcar #'car value) '(theme model))))
      ;; project and project-local files are made when needed
      (should (plist-get (drgnx-agent-config-claude-test--write
                          'add (drgnx-agent-config-claude-test--hook "Stop" nil "echo proj") 'project root)
                         :ok))
      (should (plist-get (drgnx-agent-config-claude-test--write
                          'add (drgnx-agent-config-claude-test--hook "Stop" nil "echo local") 'local root)
                         :ok))
      (should (file-exists-p (expand-file-name ".claude/settings.json" root)))
      (should (file-exists-p (expand-file-name ".claude/settings.local.json" root)))
      (should (equal (mapcar (lambda (i) (plist-get i :from)) (funcall hook-items root)) '(project local)))
      ;; a hook that is not there cannot be edited
      (should (plist-get (drgnx-agent-config-claude-test--write
                          'remove (drgnx-agent-config-claude-test--hook "Stop" nil "echo nothing") 'user root)
                         :error)))))

;;;; Skills

(ert-deftest drgnx-agent-config-claude/skill-toggle-writes-skill-overrides ()
  (drgnx-agent-config-claude-test-env
    (let* ((claude-home (drgnx-agent-config-home 'claude))
           (settings (expand-file-name "settings.json" claude-home))
           (local (expand-file-name ".claude/settings.local.json" root))
           (skill (lambda (name) (drgnx-agent-config-claude-test--item
                                  (plist-get (drgnx-agent-config-read 'claude root) :items) 'skill name))))
      (drgnx-agent-config-claude-test--put (expand-file-name "skills/alpha/SKILL.md" claude-home)
                                           "---\nname: alpha\ndescription: A\n---\n")
      (drgnx-agent-config-claude-test--put (expand-file-name ".claude/skills/beta/SKILL.md" root)
                                           "---\nname: beta\ndescription: B\n---\n")
      (drgnx-agent-config-claude-test--put settings "{\n  \"theme\": \"dark\"\n}\n")
      (should (plist-get (funcall skill "alpha") :enabled))
      ;; a user skill: the user's settings
      (should (plist-get (drgnx-agent-config-claude-test--write 'toggle (funcall skill "alpha") nil root) :ok))
      (should (equal (drgnx-agent-config-claude-test--get (drgnx-agent-config-claude-test--value settings) "skillOverrides" "alpha") "off"))
      (should-not (plist-get (funcall skill "alpha") :enabled))
      (should (plist-get (funcall skill "beta") :enabled))
      ;; on again: the key (and the empty object) goes, the rest stays
      (should (plist-get (drgnx-agent-config-claude-test--write 'toggle (funcall skill "alpha") nil root) :ok))
      (should (equal (mapcar #'car (drgnx-agent-config-claude-test--value settings)) '(theme)))
      (should (plist-get (funcall skill "alpha") :enabled))
      ;; a project skill: the project-local settings (private), not the committed file
      (should (plist-get (drgnx-agent-config-claude-test--write 'toggle (funcall skill "beta") nil root) :ok))
      (should (equal (drgnx-agent-config-claude-test--get (drgnx-agent-config-claude-test--value local) "skillOverrides" "beta") "off"))
      (should-not (file-exists-p (expand-file-name ".claude/settings.json" root)))
      (should-not (plist-get (funcall skill "beta") :enabled))
      ;; switching on removes an "off" wherever it is set
      (drgnx-agent-config-claude-test--put settings "{\"skillOverrides\": {\"beta\": \"off\", \"keep\": \"name-only\"}}\n")
      (should (plist-get (drgnx-agent-config-claude-test--write 'toggle (funcall skill "beta") nil root) :ok))
      (should (plist-get (funcall skill "beta") :enabled))
      (should (equal (drgnx-agent-config-claude-test--get (drgnx-agent-config-claude-test--value settings) "skillOverrides" "keep")
                     "name-only"))
      (should-not (drgnx-agent-config-claude-test--get (drgnx-agent-config-claude-test--value settings) "skillOverrides" "beta"))
      ;; "name-only" still counts as enabled
      (drgnx-agent-config-claude-test--put settings "{\"skillOverrides\": {\"alpha\": \"name-only\"}}\n")
      (should (plist-get (funcall skill "alpha") :enabled)))))

(ert-deftest drgnx-agent-config-claude/new-skill-in-project-scope ()
  (drgnx-agent-config-claude-test-env
    (let ((item (list :kind 'claude :section 'skill :name "gamma" :spec '(:description "Does gamma things"))))
      (let ((result (drgnx-agent-config-claude-test--write 'add item 'project root)))
        (should (plist-get result :ok)))
      (let ((file (expand-file-name ".claude/skills/gamma/SKILL.md" root)))
        (should (file-exists-p file))
        (should (string-match-p "^name: gamma$" (drgnx-agent-config-claude-test--text file)))
        (should (string-match-p "^description: Does gamma things$" (drgnx-agent-config-claude-test--text file))))
      (let ((skill (drgnx-agent-config-claude-test--item (plist-get (drgnx-agent-config-read 'claude root) :items) 'skill "gamma")))
        (should (eq (plist-get skill :from) 'project))
        (should (equal (plist-get (plist-get skill :spec) :description) "Does gamma things")))
      ;; an existing name is refused
      (should (plist-get (drgnx-agent-config-claude-test--write 'add item 'project root) :error))
      ;; and in the user's scope
      (should (plist-get (drgnx-agent-config-claude-test--write 'add item 'user root) :ok))
      (should (file-exists-p (expand-file-name "skills/gamma/SKILL.md" (drgnx-agent-config-home 'claude)))))))

;;;; Routes

(ert-deftest drgnx-agent-config-claude/routes-and-billing ()
  (drgnx-agent-config-claude-test-env
    (let* ((routes (drgnx-agent-config-claude-routes root))
           (route (lambda (name) (cl-find name routes :key (lambda (r) (plist-get r :profile)) :test #'equal))))
      (let ((r (funcall route "claude")))
        (should r)
        (should (eq (plist-get r :billing) 'subscription))
        (should-not (plist-get r :base-url)))
      (let ((r (funcall route "claude (OpenRouter)")))
        (should (eq (plist-get r :billing) 'openrouter))
        (should (equal (plist-get r :vendor) "OpenRouter"))
        (should (eq (plist-get r :kind) 'claude-openrouter))
        (should (equal (plist-get r :base-url) "https://openrouter.ai/api"))
        (should (equal (plist-get r :key-where) "OPENROUTER_API_KEY, else the keyring entry for openrouter.ai")))
      (let ((r (funcall route "claude (Ollama)")))
        (should (eq (plist-get r :billing) 'local))
        (should (string-match-p "127\\.0\\.0\\.1" (plist-get r :base-url)))
        (should-not (plist-get r :key-where)))
      ;; an agents.eld profile with the direct Anthropic route
      (drgnx-agent-config-claude-test--put
       (expand-file-name "agents.eld" (drgnx-user-dir))
       "(:profiles ((\"claude (API)\" :command (\"claude-agent-acp\") :ai claude-anthropic)
                    (\"other agent\" :command (\"some-acp\"))))")
      (let* ((routes (drgnx-agent-config-claude-routes root))
             (r (cl-find "claude (API)" routes :key (lambda (r) (plist-get r :profile)) :test #'equal)))
        (should r)
        (should (eq (plist-get r :billing) 'per-token))
        (should (equal (plist-get r :vendor) "Anthropic API"))
        (should (equal (plist-get r :base-url) "https://api.anthropic.com"))
        (should (equal (plist-get r :key-where) "ANTHROPIC_API_KEY, else the keyring entry for api.anthropic.com"))
        ;; only Claude Code profiles
        (should-not (cl-find "other agent" routes :key (lambda (r) (plist-get r :profile)) :test #'equal)))
      ;; the read carries the routes too
      (should (plist-get (drgnx-agent-config-read 'claude root) :routes)))))

(ert-deftest drgnx-agent-config-claude/routes-never-look-up-a-key ()
  (drgnx-agent-config-claude-test-env
    (require 'drgnx-agents)
    (require 'drgnx-ai)
    (require 'auth-source)
    (let ((looked nil))
      (cl-letf (((symbol-function 'drgnx-ai-key) (lambda (&rest _) (setq looked t) "x"))
                ((symbol-function 'auth-source-search) (lambda (&rest _) (setq looked t) nil)))
        (drgnx-agent-config-claude-routes root)
        (drgnx-agent-config-read 'claude root))
      (should-not looked))))

;;;; Conflicts, credentials

(ert-deftest drgnx-agent-config-claude/settings-env-conflict-noted ()
  (drgnx-agent-config-claude-test-env
    (let* ((claude-home (drgnx-agent-config-home 'claude))
           (user (expand-file-name "settings.json" claude-home))
           (local (expand-file-name ".claude/settings.local.json" root)))
      (drgnx-agent-config-claude-test--put
       user "{\"env\": {\"ANTHROPIC_BASE_URL\": \"https://proxy.example.com\", \"ANTHROPIC_API_KEY\": \"s3cret-env-value\", \"FOO\": \"bar\"}}")
      (drgnx-agent-config-claude-test--put local "{\"env\": {\"ANTHROPIC_DEFAULT_SONNET_MODEL\": \"some-model\"}}")
      (drgnx-agent-config-claude-test--put (expand-file-name ".claude/settings.json" root) "{\"env\": {\"FOO\": \"bar\"}}")
      (let ((notes (plist-get (drgnx-agent-config-read 'claude root) :notes)))
        (should (= (length notes) 2))
        (should (cl-some (lambda (n) (and (string-match-p (regexp-quote user) n)
                                          (string-match-p "ANTHROPIC_BASE_URL" n)
                                          (string-match-p "ANTHROPIC_API_KEY" n)
                                          (string-match-p "overrides every profile's route" n)))
                         notes))
        (should (cl-some (lambda (n) (and (string-match-p (regexp-quote local) n)
                                          (string-match-p "ANTHROPIC_DEFAULT_SONNET_MODEL" n)))
                         notes))
        ;; names only
        (dolist (n notes)
          (should-not (string-match-p "s3cret-env-value\\|proxy\\.example\\.com\\|some-model\\|FOO" n)))))))

(ert-deftest drgnx-agent-config-claude/never-opens-credentials ()
  (drgnx-agent-config-claude-test-env
    (let* ((claude-home (drgnx-agent-config-home 'claude))
           (opened nil)
           (record (lambda (orig file &rest args) (push (expand-file-name file) opened) (apply orig file args))))
      (drgnx-agent-config-claude-test--put (expand-file-name ".credentials.json" claude-home) "{\"claudeAiOauth\": {\"accessToken\": \"CANARY\"}}")
      (drgnx-agent-config-claude-test--put (drgnx-agent-config-claude-json-file) "{\"numStartups\": 1}\n")
      (drgnx-agent-config-claude-test--put (expand-file-name "settings.json" claude-home) "{\"theme\": \"dark\"}\n")
      (drgnx-agent-config-claude-test--put (expand-file-name "skills/alpha/SKILL.md" claude-home) "---\nname: alpha\n---\n")
      (advice-add 'insert-file-contents :around record)
      (advice-add 'insert-file-contents-literally :around record)
      (unwind-protect
          (progn
            (drgnx-agent-config-read 'claude root)
            (drgnx-agent-config-claude-routes root)
            (drgnx-agent-config-claude-test--write
             'add (drgnx-agent-config-claude-test--hook "Stop" nil "echo x") 'user root)
            (drgnx-agent-config-claude-test--write
             'add (drgnx-agent-config-claude-test--mcp "s" '(:command "x" :env (("API_KEY" . "abcd1234")))) 'user root)
            (drgnx-agent-config-claude-test--write
             'toggle (drgnx-agent-config-claude-test--item (plist-get (drgnx-agent-config-read 'claude root) :items) 'skill "alpha")
             nil root))
        (advice-remove 'insert-file-contents record)
        (advice-remove 'insert-file-contents-literally record))
      (should opened)
      (should-not (cl-some (lambda (f) (string-match-p "credentials" f)) opened))
      (should (cl-some (lambda (f) (string-suffix-p "settings.json" f)) opened)))))


;;;; Fix round 1: no lost configuration

(defun drgnx-agent-config-claude-test--fake-claude (script)
  "Put a fake `claude' with the shell SCRIPT first on the path (use inside the env macro); return its directory."
  (let ((bin (expand-file-name "bin2" drgnx-agent-config-test--dir)))
    (drgnx-agent-config-claude-test--put (expand-file-name "claude" bin) (concat "#!/bin/sh\n" script))
    (set-file-modes (expand-file-name "claude" bin) #o755)
    (setq exec-path (cons bin exec-path))
    bin))

(ert-deftest drgnx-agent-config-claude/failed-cli-edit-puts-the-entry-back ()
  (drgnx-agent-config-claude-test-env
    (let* ((exec-path exec-path)
           (json (drgnx-agent-config-claude-json-file))
           (before (concat "{\n  \"numStartups\": 1,\n  \"mcpServers\": {\"github\": {\"type\": \"stdio\","
                           " \"command\": \"npx\", \"args\": [\"-y\", \"old\"]}}\n}\n"))
           (after (drgnx-agent-config-claude-test--put (expand-file-name "after.json" drgnx-agent-config-test--dir)
                                                       "{\n  \"numStartups\": 1,\n  \"mcpServers\": {}\n}\n"))
           (edited (drgnx-agent-config-claude-test--mcp "github" '(:type stdio :command "npx" :args ("-y" "new")))))
      (drgnx-agent-config-claude-test--put json before)
      ;; remove works (and really removes), add-json fails
      (drgnx-agent-config-claude-test--fake-claude
       (format "case \"$2\" in remove) cp '%s' '%s'; exit 0;; *) exit 1;; esac\n" after json))
      (let ((result (drgnx-agent-config-claude-test--write 'edit edited 'user root)))
        (should (string-match-p "the change failed; the previous entry was put back" (plist-get result :error))))
      (let ((value (drgnx-agent-config-claude-test--value json)))
        (should (equal (drgnx-agent-config-claude-test--get value "mcpServers" "github" "args") ["-y" "old"]))
        (should (= (drgnx-agent-config-claude-test--get value "numStartups") 1))))))

(ert-deftest drgnx-agent-config-claude/backup-is-kept-while-a-restore-is-unconfirmed ()
  (drgnx-agent-config-claude-test-env
    (let* ((exec-path exec-path)
           (drgnx-agent-config-claude--unrestored nil)
           (json (drgnx-agent-config-claude-json-file))
           (before "{\n  \"mcpServers\": {\"github\": {\"command\": \"npx\"}}\n}\n")
           (bad (drgnx-agent-config-claude-test--put (expand-file-name "bad.json" drgnx-agent-config-test--dir)
                                                     "{\"mcpServers\": {},}\n")))
      (drgnx-agent-config-claude-test--put json before)
      ;; remove leaves a file nothing can be merged into; add-json fails
      (drgnx-agent-config-claude-test--fake-claude
       (format "case \"$2\" in remove) cp '%s' '%s'; exit 0;; *) exit 1;; esac\n" bad json))
      (let ((result (drgnx-agent-config-claude-test--write
                     'edit (drgnx-agent-config-claude-test--mcp "github" '(:command "other")) 'user root)))
        (should (string-match-p "\\.drgnx-bak" (plist-get result :error)))
        (should-not (string-match-p "put back" (plist-get result :error))))
      (should (equal (drgnx-agent-config-claude-test--text (concat json ".drgnx-bak")) before))
      ;; the next command line write does not overwrite that backup
      (drgnx-agent-config-claude-test--write 'add (drgnx-agent-config-claude-test--mcp "more" '(:command "m")) 'user root)
      (should (equal (drgnx-agent-config-claude-test--text (concat json ".drgnx-bak")) before)))))

(ert-deftest drgnx-agent-config-claude/no-backup-when-the-cli-cannot-run ()
  (drgnx-agent-config-claude-test-env
    (let ((exec-path '("/nonexistent")) (json (drgnx-agent-config-claude-json-file)))
      (drgnx-agent-config-claude-test--put json "{\"numStartups\": 1}\n")
      (drgnx-agent-config-claude-test--write 'add (drgnx-agent-config-claude-test--mcp "x" '(:command "c")) 'user root)
      (should-not (file-exists-p (concat json ".drgnx-bak"))))))

(ert-deftest drgnx-agent-config-claude/edits-keep-members-drgnx-does-not-model ()
  (drgnx-agent-config-claude-test-env
    (let ((json (drgnx-agent-config-claude-json-file))
          (mcp (expand-file-name ".mcp.json" root))
          (entry (concat "{\"type\": \"http\", \"url\": \"https://old.example.com/mcp\","
                         " \"oauth\": {\"clientId\": \"cid\"}, \"headersHelper\": \"./helper.sh\"}")))
      (drgnx-agent-config-claude-test--put json (format "{\"numStartups\": 1, \"mcpServers\": {\"web\": %s}}\n" entry))
      (drgnx-agent-config-claude-test--put mcp (format "{\"mcpServers\": {\"web\": %s}}\n" entry))
      (dolist (scope '(user project))
        (let ((result (drgnx-agent-config-claude-test--write
                       'edit (drgnx-agent-config-claude-test--mcp
                              "web" '(:type http :url "https://new.example.com/mcp" :headers (("X-Id" . "7"))))
                       scope root))
              (server (drgnx-agent-config-claude-test--get
                       (drgnx-agent-config-claude-test--value (if (eq scope 'user) json mcp)) "mcpServers" "web")))
          (should (plist-get result :ok))
          (should (equal (drgnx-agent-config-claude-test--get server "url") "https://new.example.com/mcp"))
          (should (equal (drgnx-agent-config-claude-test--get server "oauth" "clientId") "cid"))
          (should (equal (drgnx-agent-config-claude-test--get server "headersHelper") "./helper.sh"))
          (should (equal (drgnx-agent-config-claude-test--get server "headers" "X-Id") "7"))
          (should (equal (mapcar #'car server) '(type url oauth headersHelper headers)))))
      ;; no command line was involved: the extras could not have gone with it safely
      (should-not (drgnx-agent-config-test-argv))
      ;; a member the edit no longer has is removed (http -> stdio)
      (drgnx-agent-config-claude-test--write 'edit (drgnx-agent-config-claude-test--mcp "web" '(:type stdio :command "c")) 'project root)
      (let ((server (drgnx-agent-config-claude-test--get (drgnx-agent-config-claude-test--value mcp) "mcpServers" "web")))
        (should-not (assoc "url" (mapcar (lambda (c) (cons (symbol-name (car c)) (cdr c))) server)))
        (should (equal (drgnx-agent-config-claude-test--get server "command") "c"))
        (should (equal (drgnx-agent-config-claude-test--get server "oauth" "clientId") "cid"))))))

(ert-deftest drgnx-agent-config-claude/hook-edits-keep-members-drgnx-does-not-model ()
  (drgnx-agent-config-claude-test-env
    (let ((settings (expand-file-name "settings.json" (drgnx-agent-config-home 'claude))))
      (drgnx-agent-config-claude-test--put
       settings (concat "{\"hooks\": {\"PreToolUse\": [{\"matcher\": \"Bash\", \"hooks\": [{\"type\": \"command\","
                        " \"command\": \"echo a\", \"timeout\": 3, \"statusMessage\": \"Checking\", \"async\": true}]}]}}\n"))
      (let ((original (car (cl-remove-if-not (lambda (i) (eq (plist-get i :section) 'hook))
                                             (plist-get (drgnx-agent-config-read 'claude root) :items)))))
        ;; in place: the command changes, the timeout goes, the rest stays
        (should (plist-get (drgnx-agent-config-claude-test--write
                            'edit (drgnx-agent-config-claude-test--hook "PreToolUse" "Bash" "echo b" nil original) 'user root)
                           :ok))
        (let ((hook (aref (drgnx-agent-config-claude-test--get
                           (aref (drgnx-agent-config-claude-test--get (drgnx-agent-config-claude-test--value settings)
                                                                      "hooks" "PreToolUse") 0)
                           "hooks")
                          0)))
          (should (equal (drgnx-agent-config-claude-test--get hook "command") "echo b"))
          (should (equal (drgnx-agent-config-claude-test--get hook "statusMessage") "Checking"))
          (should (eq (drgnx-agent-config-claude-test--get hook "async") t))
          (should-not (assoc "timeout" (mapcar (lambda (c) (cons (symbol-name (car c)) (cdr c))) hook))))
        ;; moved to another event: the hook's own members go with it
        (let ((moved (car (cl-remove-if-not (lambda (i) (eq (plist-get i :section) 'hook))
                                            (plist-get (drgnx-agent-config-read 'claude root) :items)))))
          (should (plist-get (drgnx-agent-config-claude-test--write
                              'edit (drgnx-agent-config-claude-test--hook "Stop" nil "echo b" nil moved) 'user root)
                             :ok)))
        (let ((hook (aref (drgnx-agent-config-claude-test--get
                           (aref (drgnx-agent-config-claude-test--get (drgnx-agent-config-claude-test--value settings)
                                                                      "hooks" "Stop") 0)
                           "hooks")
                          0)))
          (should (equal (drgnx-agent-config-claude-test--get hook "statusMessage") "Checking"))
          (should (eq (drgnx-agent-config-claude-test--get hook "async") t)))))))

(ert-deftest drgnx-agent-config-claude/skill-on-removes-only-the-offs-that-matter ()
  (drgnx-agent-config-claude-test-env
    (let* ((claude-home (drgnx-agent-config-home 'claude))
           (user (expand-file-name "settings.json" claude-home))
           (project (expand-file-name ".claude/settings.json" root))
           (local (expand-file-name ".claude/settings.local.json" root))
           (skill (lambda () (drgnx-agent-config-claude-test--item
                              (plist-get (drgnx-agent-config-read 'claude root) :items) 'skill "alpha")))
           (overrides (lambda (file) (drgnx-agent-config-claude-test--get (drgnx-agent-config-claude-test--value file)
                                                                          "skillOverrides" "alpha"))))
      (drgnx-agent-config-claude-test--put (expand-file-name "skills/alpha/SKILL.md" claude-home)
                                           "---\nname: alpha\ndescription: A\n---\n")
      ;; local off, project name-only, user off: only local's off makes it off
      (drgnx-agent-config-claude-test--put user "{\"skillOverrides\": {\"alpha\": \"off\", \"zeta\": \"off\"}}\n")
      (drgnx-agent-config-claude-test--put project "{\"skillOverrides\": {\"alpha\": \"name-only\"}}\n")
      (drgnx-agent-config-claude-test--put local "{\"skillOverrides\": {\"alpha\": \"off\"}}\n")
      (should-not (plist-get (funcall skill) :enabled))
      (let ((result (drgnx-agent-config-claude-test--write 'toggle (funcall skill) nil root)))
        (should (plist-get result :ok))
        (should (string-match-p (regexp-quote local) (plist-get result :note)))
        (should-not (string-match-p (regexp-quote user) (plist-get result :note))))
      (should (equal (funcall overrides project) "name-only"))
      (should (equal (funcall overrides user) "off"))
      (should (plist-get (funcall skill) :enabled))
      ;; local off, user off: both go (the user's would make it off again), zeta stays
      (drgnx-agent-config-claude-test--put project "{}\n")
      (drgnx-agent-config-claude-test--put local "{\"skillOverrides\": {\"alpha\": \"off\"}}\n")
      (let ((result (drgnx-agent-config-claude-test--write 'toggle (funcall skill) nil root)))
        (should (string-match-p (regexp-quote local) (plist-get result :note)))
        (should (string-match-p (regexp-quote user) (plist-get result :note))))
      (should-not (funcall overrides user))
      (should (equal (drgnx-agent-config-claude-test--get (drgnx-agent-config-claude-test--value user) "skillOverrides" "zeta") "off"))
      ;; off while a higher file says name-only: written, with a warning
      (drgnx-agent-config-claude-test--put local "{\"skillOverrides\": {\"alpha\": \"name-only\"}}\n")
      (let ((result (drgnx-agent-config-claude-test--write 'toggle (funcall skill) 'user root)))
        (should (plist-get result :ok))
        (should (string-match-p "name-only" (plist-get result :note)))
        (should (string-match-p (regexp-quote local) (plist-get result :note))))
      (should (equal (funcall overrides local) "name-only"))
      ;; a file that does not parse stops the switch before anything is written
      (drgnx-agent-config-claude-test--put user "{\"skillOverrides\": {\"alpha\": \"off\"}}\n")
      (drgnx-agent-config-claude-test--put local "{\"skillOverrides\": {\"alpha\": \"off\",}}\n")
      (let* ((item (plist-put (copy-sequence (funcall skill)) :enabled nil))
             (before (drgnx-agent-config-claude-test--text user))
             (result (drgnx-agent-config-claude-test--write 'toggle item nil root)))
        (should (plist-get result :error))
        (should (equal (drgnx-agent-config-claude-test--text user) before))))))

(ert-deftest drgnx-agent-config-claude/names-the-cli-cannot-take-say-why ()
  (drgnx-agent-config-claude-test-env
    (let ((result (drgnx-agent-config-claude-test--write
                   'add (drgnx-agent-config-claude-test--mcp "my server" '(:command "x")) 'user root)))
      (should (string-match-p "digits, .\\.., " (plist-get result :error)))
      (should (string-match-p "Claude Code" (plist-get result :error))))))

(ert-deftest drgnx-agent-config-claude/model-helpers-are-public ()
  (should (fboundp 'drgnx-agent-config-save-backup))
  (drgnx-agent-config-claude-test-env
    (let ((file (drgnx-agent-config-claude-test--put (expand-file-name "x.json" home) "{\n    \"a\": 1\n}\n")))
      (should (equal (drgnx-agent-config-json-read-text file (drgnx-agent-config-claude-test--text file))
                     (drgnx-agent-config-json-read file)))
      (drgnx-agent-config-save-backup file)
      (should (file-exists-p (concat file ".drgnx-bak"))))))
(provide 'agent-config-claude-test)
;;; agent-config-claude-test.el ends here
