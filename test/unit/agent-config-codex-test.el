;;; agent-config-codex-test.el --- batch tests: Codex's settings (TOML, hooks.json, trusted projects, the OpenRouter route) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-agent-config-codex)
(load (expand-file-name "test/fixtures/agent-config-fixture" drgnx-dir) nil t)

(defun drgnx-agent-config-codex-test--put (file text)
  "Write TEXT to FILE (making its directory); return FILE."
  (make-directory (file-name-directory file) t)
  (write-region text nil file nil 'silent)
  file)

(defun drgnx-agent-config-codex-test--text (file)
  "The text of FILE."
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defun drgnx-agent-config-codex-test--config ()
  "The user's config.toml."
  (expand-file-name "config.toml" (drgnx-agent-config-home 'codex)))

(defun drgnx-agent-config-codex-test--item (items section name)
  "The item of SECTION called NAME."
  (cl-find-if (lambda (i) (and (eq (plist-get i :section) section) (equal (plist-get i :name) name))) items))

(defun drgnx-agent-config-codex-test--names (items section)
  "The sorted names of the SECTION items."
  (sort (mapcar (lambda (i) (plist-get i :name))
                (cl-remove-if-not (lambda (i) (eq (plist-get i :section) section)) items))
        #'string<))

(defun drgnx-agent-config-codex-test--write (op item scope root)
  "Run the write; return what the callback got."
  (let (result)
    (drgnx-agent-config-write 'codex op item scope root (lambda (r) (setq result r)))
    (or result (error "The write never called back"))))

(defun drgnx-agent-config-codex-test--mcp (name spec)
  "An MCP server item."
  (list :kind 'codex :section 'mcp :name name :spec spec :enabled t))

(defun drgnx-agent-config-codex-test--trust (root)
  "Mark ROOT trusted in the user's config.toml."
  (let ((file (drgnx-agent-config-codex-test--config)))
    (drgnx-agent-config-codex-test--put
     file (concat (and (file-exists-p file) (drgnx-agent-config-codex-test--text file))
                  (format "\n[projects.%S]\ntrust_level = \"trusted\"\n" (directory-file-name root))))))

(defconst drgnx-agent-config-codex-test--user-config
  (concat "# my codex\n"
          "model = \"gpt-5\"\n"
          "\n"
          "[mcp_servers.docs]\n"
          "command = \"npx\"\n"
          "args = [\"-y\", \"docs-mcp\"]\n"
          "startup_timeout_sec = 30\n"
          "env = { TOKEN = \"abc12345\" }\n"
          "\n"
          "# the remote one\n"
          "[mcp_servers.remote]\n"
          "url = \"https://example.com/mcp\"\n"
          "bearer_token_env_var = \"REMOTE_TOKEN\"\n"
          "http_headers = { \"X-Api-Key\" = \"hunter2hunter2\" }\n"
          "env_http_headers = { \"X-Org\" = \"ORG_ENV\" }\n"
          "\n"
          "[[skills.config]]\n"
          "path = \"%s\"\n"
          "enabled = false\n"))

;;;; Reading

(ert-deftest drgnx-agent-config-codex/reads-toml-and-hooks-json ()
  (drgnx-agent-config-test-env
    (let* ((codex-home (drgnx-agent-config-home 'codex))
           (config (drgnx-agent-config-codex-test--config))
           (off-skill (expand-file-name ".agents/skills/off-one" home)))
      (should (equal config (expand-file-name "config.toml" (concat drgnx-agent-config-test--dir "codex"))))
      (drgnx-agent-config-codex-test--put
       config (concat (format drgnx-agent-config-codex-test--user-config (expand-file-name "SKILL.md" off-skill))
                      (format "\n[projects.%S]\ntrust_level = \"trusted\"\n" (directory-file-name root))))
      (drgnx-agent-config-codex-test--put
       (expand-file-name "hooks.json" codex-home)
       "{\"hooks\": {\"PreToolUse\": [{\"matcher\": \"Bash\", \"hooks\": [{\"type\": \"command\", \"command\": \"echo pre\", \"timeout\": 7}]}]}}")
      (drgnx-agent-config-codex-test--put
       (expand-file-name ".codex/config.toml" root) "[mcp_servers.proj]\ncommand = \"proj-cmd\"\n")
      (drgnx-agent-config-codex-test--put
       (expand-file-name ".codex/hooks.json" root)
       "{\"hooks\": {\"Stop\": [{\"hooks\": [{\"type\": \"command\", \"command\": \"echo stop\"}]}]}}")
      (drgnx-agent-config-codex-test--put (expand-file-name ".agents/skills/on-one/SKILL.md" home)
                                          "---\nname: on-one\ndescription: Is on\n---\nBody\n")
      (drgnx-agent-config-codex-test--put (expand-file-name "SKILL.md" off-skill)
                                          "---\nname: off-one\ndescription: Is off\n---\nBody\n")
      (drgnx-agent-config-codex-test--put (expand-file-name ".agents/skills/proj-skill/SKILL.md" root)
                                          "---\nname: proj-skill\ndescription: Project\n---\nBody\n")
      (drgnx-agent-config-codex-test--put (expand-file-name "AGENTS.md" codex-home) "user rules\n")
      (drgnx-agent-config-codex-test--put (expand-file-name "AGENTS.md" root) "project rules\n")
      (let* ((read (drgnx-agent-config-read 'codex root))
             (items (plist-get read :items)))
        (should-not (plist-get read :problems))
        (should (equal (drgnx-agent-config-codex-test--names items 'mcp) '("docs" "proj" "remote")))
        (let ((d (drgnx-agent-config-codex-test--item items 'mcp "docs")))
          (should (eq (plist-get d :from) 'user))
          (should (equal (plist-get d :file) config))
          (should (= (plist-get d :line) 4))
          (should-not (plist-get d :readonly))
          (should (plist-get d :enabled))
          (should (equal (plist-get d :spec)
                         '(:type stdio :command "npx" :args ("-y" "docs-mcp") :env (("TOKEN" . "abc12345"))
                                 :url nil :headers nil :env-headers nil :env-header-vars nil :bearer-env nil))))
        (let ((r (drgnx-agent-config-codex-test--item items 'mcp "remote")))
          (should (= (plist-get r :line) 11))
          (should (eq (plist-get (plist-get r :spec) :type) 'http))
          ;; literal headers are secrets; the headers read from the environment are only names
          (should (equal (plist-get (plist-get r :spec) :headers) '(("X-Api-Key" . "hunter2hunter2"))))
          (should (equal (plist-get (plist-get r :spec) :env-headers) '("X-Org")))
          (should (equal (plist-get (plist-get r :spec) :env-header-vars) '("ORG_ENV")))
          (should (equal (plist-get (plist-get r :spec) :bearer-env) "REMOTE_TOKEN"))
          (should (member "hunter2hunter2" (drgnx-agent-config-secrets (plist-get r :spec))))
          (should-not (member "ORG_ENV" (drgnx-agent-config-secrets (plist-get r :spec)))))
        (let ((p (drgnx-agent-config-codex-test--item items 'mcp "proj")))
          (should (eq (plist-get p :from) 'project))
          (should (equal (plist-get p :file) (expand-file-name ".codex/config.toml" root))))
        (should (equal (mapcar (lambda (i) (list (plist-get i :from) (plist-get (plist-get i :spec) :event)
                                                 (plist-get (plist-get i :spec) :matcher)
                                                 (plist-get (plist-get i :spec) :command) (plist-get i :readonly)))
                               (cl-remove-if-not (lambda (i) (eq (plist-get i :section) 'hook)) items))
                       '((user "PreToolUse" "Bash" "echo pre" nil) (project "Stop" nil "echo stop" nil))))
        (should (= (plist-get (plist-get (drgnx-agent-config-codex-test--item items 'hook "PreToolUse Bash") :spec) :timeout) 7))
        (should (equal (mapcar (lambda (i) (list (plist-get i :name) (plist-get i :from) (plist-get i :enabled)))
                               (cl-remove-if-not (lambda (i) (eq (plist-get i :section) 'skill)) items))
                       '(("off-one" user nil) ("on-one" user t) ("proj-skill" project t))))
        (should (equal (plist-get read :rules)
                       (list (expand-file-name "AGENTS.md" codex-home) (expand-file-name "AGENTS.md" root))))
        ;; without a project: the user's files only
        (let ((items (plist-get (drgnx-agent-config-read 'codex nil) :items)))
          (should (equal (drgnx-agent-config-codex-test--names items 'mcp) '("docs" "remote"))))))))

(ert-deftest drgnx-agent-config-codex/untrusted-project-is-shown-inactive ()
  (drgnx-agent-config-test-env
    (drgnx-agent-config-codex-test--put (drgnx-agent-config-codex-test--config) "model = \"gpt-5\"\n")
    (let ((pconfig (expand-file-name ".codex/config.toml" root))
          (phooks (expand-file-name ".codex/hooks.json" root)))
      (drgnx-agent-config-codex-test--put pconfig "[mcp_servers.proj]\ncommand = \"proj-cmd\"\n")
      (drgnx-agent-config-codex-test--put
       phooks "{\"hooks\": {\"Stop\": [{\"hooks\": [{\"type\": \"command\", \"command\": \"echo stop\"}]}]}}")
      (should-not (drgnx-agent-config-codex-trusted-p root))
      (let ((read (drgnx-agent-config-read 'codex root)))
        (should (equal (mapcar (lambda (i) (plist-get i :name)) (plist-get read :items)) '("proj" "Stop")))
        (dolist (i (plist-get read :items))
          (should (equal (plist-get i :inactive) "Codex ignores it until the project is trusted"))
          (should-not (plist-get i :readonly)))
        (should-not (plist-get read :problems))
        (should (cl-some (lambda (n) (and (string-search pconfig n)
                                          (string-search "Codex ignores it until the project is trusted" n)))
                         (plist-get read :notes))))
      ;; an unparsable file of an untrusted project is a problem like any other
      (drgnx-agent-config-codex-test--put pconfig "[broken\n")
      (should (equal (mapcar #'car (plist-get (drgnx-agent-config-read 'codex root) :problems)) (list pconfig)))
      ;; trusted: read
      (drgnx-agent-config-codex-test--put pconfig "[mcp_servers.proj]\ncommand = \"proj-cmd\"\n")
      (drgnx-agent-config-codex-test--trust root)
      (should (drgnx-agent-config-codex-trusted-p root))
      (let ((read (drgnx-agent-config-read 'codex root)))
        (should (equal (mapcar (lambda (i) (plist-get i :name)) (plist-get read :items)) '("proj" "Stop")))
        (should-not (cl-some (lambda (i) (plist-get i :inactive)) (plist-get read :items)))
        (should-not (plist-get read :notes))))))

(ert-deftest drgnx-agent-config-codex/a-project-server-written-untrusted-does-not-vanish ()
  (drgnx-agent-config-test-env
    (should (plist-get (drgnx-agent-config-codex-test--write
                        'add (drgnx-agent-config-codex-test--mcp "p" '(:type stdio :command "x")) 'project root)
                       :ok))
    (let ((item (drgnx-agent-config-codex-test--item (plist-get (drgnx-agent-config-read 'codex root) :items) 'mcp "p")))
      (should item)
      (should (plist-get item :inactive))
      (should (plist-get (drgnx-agent-config-codex-test--write 'remove item 'project root) :ok)))))

(ert-deftest drgnx-agent-config-codex/trust-is-the-trusted-level-of-this-project ()
  (drgnx-agent-config-test-env
    (let ((config (drgnx-agent-config-codex-test--config)))
      (should-not (drgnx-agent-config-codex-trusted-p root))
      (should-not (drgnx-agent-config-codex-trusted-p nil))
      (drgnx-agent-config-codex-test--put config (format "[projects.%S]\ntrust_level = \"untrusted\"\n" (directory-file-name root)))
      (should-not (drgnx-agent-config-codex-trusted-p root))
      (drgnx-agent-config-codex-test--put config (format "[projects.%S]\ntrust_level = \"trusted\"\n" (expand-file-name "other" root)))
      (should-not (drgnx-agent-config-codex-trusted-p root))
      ;; the repository root counts for a folder inside it
      (make-directory (expand-file-name ".git" root) t)
      (make-directory (expand-file-name "sub/dir" root) t)
      (drgnx-agent-config-codex-test--put config (format "[projects.%S]\ntrust_level = \"trusted\"\n" (directory-file-name root)))
      (should (drgnx-agent-config-codex-trusted-p root))
      (should (drgnx-agent-config-codex-trusted-p (expand-file-name "sub/dir/" root)))
      ;; a file that does not parse trusts nothing
      (drgnx-agent-config-codex-test--put config "[projects\n")
      (should-not (drgnx-agent-config-codex-trusted-p root)))))

(ert-deftest drgnx-agent-config-codex/a-file-that-does-not-parse-is-a-problem-not-an-error ()
  (drgnx-agent-config-test-env
    (let ((config (drgnx-agent-config-codex-test--config)))
      (drgnx-agent-config-codex-test--put config "model = \"x\"\n[mcp_servers.a\ncommand = \"c\"\n")
      (drgnx-agent-config-codex-test--put (expand-file-name "hooks.json" (drgnx-agent-config-home 'codex)) "{\"hooks\": ")
      (let ((read (drgnx-agent-config-read 'codex root)))
        (should (equal (mapcar #'car (plist-get read :problems))
                       (list config (expand-file-name "hooks.json" (drgnx-agent-config-home 'codex)))))
        (should (integerp (nth 1 (car (plist-get read :problems)))))))))

(ert-deftest drgnx-agent-config-codex/scopes-name-the-files ()
  (drgnx-agent-config-test-env
    (let ((codex-home (drgnx-agent-config-home 'codex)))
      (should (equal (drgnx-agent-config-scopes 'codex 'mcp root)
                     (list (list 'user "User (all projects)" (expand-file-name "config.toml" codex-home))
                           (list 'project "Project (.codex/config.toml, when trusted)" (expand-file-name ".codex/config.toml" root)))))
      (should (equal (mapcar #'car (drgnx-agent-config-scopes 'codex 'hook nil)) '(user)))
      (should (equal (cl-third (car (drgnx-agent-config-scopes 'codex 'hook nil))) (expand-file-name "hooks.json" codex-home)))
      (should (equal (cl-third (cadr (drgnx-agent-config-scopes 'codex 'hook root))) (expand-file-name ".codex/hooks.json" root)))
      (should (equal (cl-third (car (drgnx-agent-config-scopes 'codex 'skill nil))) (expand-file-name ".agents/skills" home)))
      (should (equal (cl-third (cadr (drgnx-agent-config-scopes 'codex 'skill root))) (expand-file-name ".agents/skills" root)))
      (should-error (drgnx-agent-config-scopes 'codex 'nothing root)))))

;;;; Writing MCP servers

(ert-deftest drgnx-agent-config-codex/mcp-add-edit-remove-keeps-the-rest ()
  (drgnx-agent-config-test-env
    (let* ((config (drgnx-agent-config-codex-test--config))
           (before (concat "# my codex\nmodel = \"gpt-5\"\n\n[mcp_servers.keep]\ncommand = \"keep-cmd\"  # mine\n\n"
                           "# trailing words\n[tui]\nstyle = \"x\"\n"))
           (backup (concat config ".drgnx-bak")))
      (drgnx-agent-config-codex-test--put config before)
      ;; add: appended, everything before it byte for byte
      (should (plist-get (drgnx-agent-config-codex-test--write
                          'add (drgnx-agent-config-codex-test--mcp
                                "new" '(:type stdio :command "npx" :args ("-y" "pkg") :env (("A" . "b"))))
                          'user root)
                         :ok))
      (let ((after (drgnx-agent-config-codex-test--text config)))
        (should (string-prefix-p before after))
        (should (equal (cdr (assoc "new" (cdr (assoc "mcp_servers" (drgnx-toml-parse after)))))
                       '(("command" . "npx") ("args" . ["-y" "pkg"]) ("env" . (("A" . "b")))))))
      (should (equal (drgnx-agent-config-codex-test--text backup) before))
      ;; an http server with headers: literal and from the environment
      (let ((mid (drgnx-agent-config-codex-test--text config)))
        (should (plist-get (drgnx-agent-config-codex-test--write
                            'add (drgnx-agent-config-codex-test--mcp
                                  "web" '(:type http :url "https://example.com/mcp"
                                                :headers (("X-Key" . "k1k1k1k1"))
                                                :env-headers ("X-Org") :env-header-vars ("ORG_ENV")
                                                :bearer-env "WEB_TOKEN"))
                            'user root)
                           :ok))
        (let ((web (cdr (assoc "web" (cdr (assoc "mcp_servers" (drgnx-toml-parse (drgnx-agent-config-codex-test--text config))))))))
          (should (equal (cdr (assoc "url" web)) "https://example.com/mcp"))
          (should (equal (cdr (assoc "bearer_token_env_var" web)) "WEB_TOKEN"))
          (should (equal (cdr (assoc "http_headers" web)) '(("X-Key" . "k1k1k1k1"))))
          (should (equal (cdr (assoc "env_http_headers" web)) '(("X-Org" . "ORG_ENV")))))
        (should (string-prefix-p mid (drgnx-agent-config-codex-test--text config))))
      ;; edit: the table is replaced, what drgnx does not manage in it stays, the rest is untouched
      (drgnx-agent-config-codex-test--put
       config (replace-regexp-in-string "  # mine\n\n# trailing" "  # mine\n[mcp_servers.keep.extra]\nz = 1\n\n# trailing" before t t))
      (let ((mid (drgnx-agent-config-codex-test--text config)))
        (should (plist-get (drgnx-agent-config-codex-test--write
                            'edit (list :kind 'codex :section 'mcp :name "keep" :enabled t
                                        :spec '(:type stdio :command "other-cmd" :args ("a")))
                            'user root)
                           :ok))
        (let* ((after (drgnx-agent-config-codex-test--text config))
               (keep (cdr (assoc "keep" (cdr (assoc "mcp_servers" (drgnx-toml-parse after)))))))
          (should (string-prefix-p "# my codex\nmodel = \"gpt-5\"\n\n[mcp_servers.keep]\n" after))
          (should (equal (cdr (assoc "command" keep)) "other-cmd"))
          (should (equal (cdr (assoc "extra" keep)) '(("z" . 1))))
          (should (string-suffix-p "# trailing words\n[tui]\nstyle = \"x\"\n" after))
          (should-not (equal mid after))))
      ;; edit keeps keys of the table that drgnx does not manage
      (drgnx-agent-config-codex-test--put
       config "[mcp_servers.t]\ncommand = \"c\"\nstartup_timeout_sec = 30\nenabled_tools = [\"a\"]\n")
      (drgnx-agent-config-codex-test--write
       'edit (drgnx-agent-config-codex-test--mcp "t" '(:type stdio :command "c2")) 'user root)
      (let ((tbl (cdr (assoc "t" (cdr (assoc "mcp_servers" (drgnx-toml-parse (drgnx-agent-config-codex-test--text config))))))))
        (should (equal (cdr (assoc "command" tbl)) "c2"))
        (should (equal (cdr (assoc "startup_timeout_sec" tbl)) 30))
        (should (equal (cdr (assoc "enabled_tools" tbl)) ["a"])))
      ;; rename: the old table goes, the new one comes
      (drgnx-agent-config-codex-test--write
       'edit (list :kind 'codex :section 'mcp :name "t2" :spec '(:type stdio :command "c3")
                   :replaces (drgnx-agent-config-codex-test--mcp "t" nil))
       'user root)
      (let ((servers (cdr (assoc "mcp_servers" (drgnx-toml-parse (drgnx-agent-config-codex-test--text config))))))
        (should (equal (mapcar #'car servers) '("t2")))
        (should (equal (cdr (assoc "startup_timeout_sec" (cdr (assoc "t2" servers)))) 30)))
      ;; remove: the rest of the file stays
      (drgnx-agent-config-codex-test--put config before)
      (drgnx-agent-config-codex-test--write
       'add (drgnx-agent-config-codex-test--mcp "gone" '(:type stdio :command "x")) 'user root)
      (should (plist-get (drgnx-agent-config-codex-test--write
                          'remove (drgnx-agent-config-codex-test--mcp "gone" nil) 'user root)
                         :ok))
      (should (equal (drgnx-agent-config-codex-test--text config) before))
      (should (plist-get (drgnx-agent-config-codex-test--write
                          'remove (drgnx-agent-config-codex-test--mcp "keep" nil) 'user root)
                         :ok))
      (should (equal (drgnx-agent-config-codex-test--text config)
                     "# my codex\nmodel = \"gpt-5\"\n\n# trailing words\n[tui]\nstyle = \"x\"\n")))))

(ert-deftest drgnx-agent-config-codex/mcp-refuses-what-it-must-not-write ()
  (drgnx-agent-config-test-env
    (let ((config (drgnx-agent-config-codex-test--config)))
      (drgnx-agent-config-codex-test--put config "[mcp_servers.a]\ncommand = \"c\"\n")
      (cl-flet ((try (op name spec &rest more)
                  (drgnx-agent-config-codex-test--write
                   op (append (list :kind 'codex :section 'mcp :name name :spec spec :enabled t) more) 'user root)))
        (should (plist-get (try 'add "a" '(:type stdio :command "x")) :error))      ; exists
        (should (plist-get (try 'add "b.c" '(:type stdio :command "x")) :error))    ; dotted name
        (should (plist-get (try 'add "-b" '(:type stdio :command "x")) :error))
        (should (plist-get (try 'add "b" '(:type stdio)) :error))                   ; no command
        (should (plist-get (try 'add "b" '(:type http)) :error))                    ; no url
        (should (plist-get (try 'add "b" '(:type sse :url "https://x.test/")) :error))
        (should (plist-get (try 'add "b" '(:type stdio :command "x" :env (("A" . 3)))) :error))
        (should (plist-get (try 'remove "nope" nil) :error))
        (should (plist-get (try 'add "ro" '(:type stdio :command "x") :readonly t) :error))
        (should (plist-get (drgnx-agent-config-codex-test--write
                            'add (drgnx-agent-config-codex-test--mcp "b" '(:type stdio :command "x")) 'project nil)
                           :error))
        (should (plist-get (drgnx-agent-config-codex-test--write
                            'add (drgnx-agent-config-codex-test--mcp "b" '(:type stdio :command "x")) 'local root)
                           :error)))
      (should (equal (drgnx-agent-config-codex-test--text config) "[mcp_servers.a]\ncommand = \"c\"\n"))
      (should-not (file-exists-p (concat config ".drgnx-bak"))))))

(ert-deftest drgnx-agent-config-codex/mcp-in-an-untrusted-project-is-written-with-a-warning ()
  (drgnx-agent-config-test-env
    (let ((r (drgnx-agent-config-codex-test--write
              'add (drgnx-agent-config-codex-test--mcp "p" '(:type stdio :command "x")) 'project root)))
      (should (plist-get r :ok))
      (should (string-search "Codex ignores it until the project is trusted" (plist-get r :note)))
      (should (file-exists-p (expand-file-name ".codex/config.toml" root))))))

(ert-deftest drgnx-agent-config-codex/mcp-switches-off-with-enabled ()
  (drgnx-agent-config-test-env
    (let ((config (drgnx-agent-config-codex-test--config)))
      (drgnx-agent-config-codex-test--put config "[mcp_servers.a]\ncommand = \"c\"\n")
      (drgnx-agent-config-codex-test--write
       'toggle (list :kind 'codex :section 'mcp :name "a" :enabled t :spec '(:type stdio :command "c")) 'user root)
      (let ((read (drgnx-agent-config-read 'codex root)))
        (should-not (plist-get (drgnx-agent-config-codex-test--item (plist-get read :items) 'mcp "a") :enabled))
        (should (equal (cdr (assoc "enabled" (cdr (assoc "a" (cdr (assoc "mcp_servers" (drgnx-toml-parse (drgnx-agent-config-codex-test--text config)))))))) :false)))
      (drgnx-agent-config-codex-test--write
       'toggle (list :kind 'codex :section 'mcp :name "a" :enabled nil :spec '(:type stdio :command "c")) 'user root)
      (should (plist-get (drgnx-agent-config-codex-test--item
                          (plist-get (drgnx-agent-config-read 'codex root) :items) 'mcp "a")
                         :enabled)))))

(ert-deftest drgnx-agent-config-codex/mcp-toggle-changes-only-the-enabled-key ()
  (drgnx-agent-config-test-env
    (let* ((config (drgnx-agent-config-codex-test--config))
           (text (concat "# top\n[mcp_servers.a]  # the a server\ncommand = 'c'   # single quoted\n"
                         "args = [ \"x\",   \"y\" ]\nenv = { B = \"1\" }   # env\n\n[mcp_servers.a.extra]\nk = 1\n\n[tui]\nz = 2\n"))
           (item (lambda (enabled) (list :kind 'codex :section 'mcp :name "a" :enabled enabled
                                         :spec '(:type stdio :command "c")))))
      (drgnx-agent-config-codex-test--put config text)
      ;; off: one line is added under the header, nothing else moves
      (should (plist-get (drgnx-agent-config-codex-test--write 'toggle (funcall item t) 'user root) :ok))
      (let ((off (drgnx-agent-config-codex-test--text config)))
        (should (equal off (replace-regexp-in-string "the a server\n" "the a server\nenabled = false\n" text t t)))
        ;; on: only the value changes
        (should (plist-get (drgnx-agent-config-codex-test--write 'toggle (funcall item nil) 'user root) :ok))
        (should (equal (drgnx-agent-config-codex-test--text config)
                       (replace-regexp-in-string "enabled = false" "enabled = true" off t t))))
      ;; a key that is there with a comment after it: just the word changes
      (drgnx-agent-config-codex-test--put config "[mcp_servers.a]\ncommand = \"c\"\nenabled   =   true   # yes\n")
      (drgnx-agent-config-codex-test--write 'toggle (funcall item t) 'user root)
      (should (equal (drgnx-agent-config-codex-test--text config)
                     "[mcp_servers.a]\ncommand = \"c\"\nenabled   =   false   # yes\n"))
      ;; CRLF files stay CRLF
      (drgnx-agent-config-codex-test--put config "[mcp_servers.a]\r\ncommand = \"c\"\r\n")
      (drgnx-agent-config-codex-test--write 'toggle (funcall item t) 'user root)
      (should (equal (drgnx-agent-config-read-text config) "[mcp_servers.a]\r\nenabled = false\r\ncommand = \"c\"\r\n")))))

(ert-deftest drgnx-agent-config-codex/unparsable-toml-never-written ()
  (drgnx-agent-config-test-env
    (let* ((config (drgnx-agent-config-codex-test--config))
           (bad "model = \"x\"\n[mcp_servers.a\ncommand = \"secret-value-1234\"\n"))
      (drgnx-agent-config-codex-test--put config bad)
      (dolist (item (list (drgnx-agent-config-codex-test--mcp "b" '(:type stdio :command "x" :env (("K" . "supersecret99"))))
                          (list :kind 'codex :section 'skill :name "s" :enabled t
                                :spec (list :dir (expand-file-name ".agents/skills/s" home)))))
        (let ((r (drgnx-agent-config-codex-test--write (if (eq (plist-get item :section) 'mcp) 'add 'toggle)
                                                       item 'user root)))
          (should (stringp (plist-get r :error)))
          (should (string-search "does not parse" (plist-get r :error)))
          (should-not (string-search "secret" (plist-get r :error)))))
      (should (equal (drgnx-agent-config-codex-test--text config) bad))
      (should-not (file-exists-p (concat config ".drgnx-bak")))
      ;; the OpenRouter route too
      (let ((r (drgnx-agent-config-codex-add-openrouter "moonshotai/kimi-k2")))
        (should (stringp (plist-get r :error))))
      (should (equal (drgnx-agent-config-codex-test--text config) bad))
      ;; a duplicate table elsewhere in the file is not written over either
      (drgnx-agent-config-codex-test--put config "[mcp_servers.a]\ncommand = \"c\"\n\n[mcp_servers.a]\ncommand = \"d\"\n")
      (should (stringp (plist-get (drgnx-agent-config-codex-test--write
                                   'add (drgnx-agent-config-codex-test--mcp "b" '(:type stdio :command "x")) 'user root)
                                  :error)))
      (should-not (file-exists-p (concat config ".drgnx-bak"))))))

(ert-deftest drgnx-agent-config-codex/a-file-changed-meanwhile-is-read-again-once ()
  (drgnx-agent-config-test-env
    (let* ((config (drgnx-agent-config-codex-test--config))
           (calls 0)
           (limit 1)
           (meddle (lambda (orig file &rest args)
                     (when (and (equal (file-truename file) (file-truename config)) (<= (setq calls (1+ calls)) limit))
                       (drgnx-agent-config-codex-test--put
                        config (format "# other program, change %d\n[mcp_servers.theirs]\ncommand = \"t\"\n" calls)))
                     (apply orig file args))))
      (drgnx-agent-config-codex-test--put config "[mcp_servers.a]\ncommand = \"c\"\n")
      (advice-add 'drgnx-agent-config-write-text :around meddle)
      (unwind-protect
          (progn
            ;; one change: the second try works on the new content
            (let ((r (drgnx-agent-config-codex-test--write
                      'add (drgnx-agent-config-codex-test--mcp "b" '(:type stdio :command "x")) 'user root)))
              (should (plist-get r :ok))
              (should (= calls 2))
              (let ((text (drgnx-agent-config-codex-test--text config)))
                (should (string-search "# other program, change 1" text))
                (should (string-search "[mcp_servers.theirs]" text))
                (should (string-search "[mcp_servers.b]" text))))
            ;; two changes: refused, and what the other program wrote stays
            (setq calls 0 limit 2)
            (let ((r (drgnx-agent-config-codex-test--write
                      'add (drgnx-agent-config-codex-test--mcp "c2" '(:type stdio :command "x")) 'user root)))
              (should (string-search "changed by another program" (or (plist-get r :error) "")))
              (should (= calls 2))
              (should (equal (drgnx-agent-config-codex-test--text config)
                             "# other program, change 2\n[mcp_servers.theirs]\ncommand = \"t\"\n"))))
        (advice-remove 'drgnx-agent-config-write-text meddle)))))

(ert-deftest drgnx-agent-config-codex/errors-never-carry-the-config-data ()
  (drgnx-agent-config-test-env
    (drgnx-agent-config-codex-test--put (drgnx-agent-config-codex-test--config) "model = \"x\"\n")
    ;; a value TOML cannot hold is reported by place, not by content
    (let ((r (drgnx-agent-config-codex-test--write
              'add (drgnx-agent-config-codex-test--mcp "b" '(:type stdio :command "x" :args ("a" 42))) 'user root)))
      (should (plist-get r :error))
      (should-not (string-search "42" (plist-get r :error))))
    (let ((r (drgnx-agent-config-codex-test--write
              'add (drgnx-agent-config-codex-test--mcp "b" '(:type stdio :command "xx-supersecret-9" :env (("K" . ?z)))) 'user root)))
      (should (plist-get r :error))
      (should-not (string-search "supersecret" (plist-get r :error))))
    ;; headers: a value that is not text, and a header read from the environment without its variable
    (let ((r (drgnx-agent-config-codex-test--write
              'add (drgnx-agent-config-codex-test--mcp
                    "h" '(:type http :url "https://example.test/m" :headers (("Authorization" . "Bearer sk-hhhhsecret12345") ("X" . 7))))
              'user root)))
      (should (plist-get r :error))
      (should-not (string-search "hhhhsecret" (plist-get r :error))))
    (let ((r (drgnx-agent-config-codex-test--write
              'add (drgnx-agent-config-codex-test--mcp
                    "h" '(:type http :url "https://example.test/m" :headers (("Authorization" . "Bearer sk-hhhhsecret12345"))
                                :env-headers ("X-Org")))
              'user root)))
      (should (plist-get r :error))
      (should-not (string-search "hhhhsecret" (plist-get r :error))))))

(ert-deftest drgnx-agent-config-codex/env-header-names-are-not-secrets-but-values-are ()
  (drgnx-agent-config-test-env
    (drgnx-agent-config-codex-test--put
     (drgnx-agent-config-codex-test--config)
     (concat "[mcp_servers.r]\nurl = \"https://example.com/mcp\"\n"
             "http_headers = { \"X-Real\" = \"literalvalue99\" }\n"
             "env_http_headers = { \"X-Api-Key\" = \"MY_API_KEY\", \"X-Wrong\" = \"sk-abcdefghijklmnopqrstuvwx\" }\n"))
    (let* ((item (drgnx-agent-config-codex-test--item (plist-get (drgnx-agent-config-read 'codex root) :items) 'mcp "r"))
           (spec (plist-get item :spec))
           (secrets (drgnx-agent-config-secrets spec)))
      (should (equal (plist-get spec :env-headers) '("X-Api-Key" "X-Wrong")))
      (should (equal (plist-get spec :env-header-vars) '("MY_API_KEY" "sk-abcdefghijklmnopqrstuvwx")))
      ;; the variable name shows as it is, even when the header's own name looks secret
      (should-not (member "MY_API_KEY" secrets))
      (should (member "literalvalue99" secrets))
      ;; a value that cannot be a variable name is masked (it was put there by mistake)
      (should (member "sk-abcdefghijklmnopqrstuvwx" secrets))
      ;; and it all round-trips
      (let ((before (drgnx-agent-config-codex-test--text (drgnx-agent-config-codex-test--config))))
        (should (plist-get (drgnx-agent-config-codex-test--write 'edit item 'user root) :ok))
        (should (equal (drgnx-toml-parse (drgnx-agent-config-codex-test--text (drgnx-agent-config-codex-test--config)))
                       (drgnx-toml-parse before)))))))

;;;; Hooks

(ert-deftest drgnx-agent-config-codex/inline-hooks-are-read-only ()
  (drgnx-agent-config-test-env
    (drgnx-agent-config-codex-test--put
     (drgnx-agent-config-codex-test--config)
     (concat "[[hooks.PreToolUse]]\nmatcher = \"Bash\"\n\n[[hooks.PreToolUse.hooks]]\ntype = \"command\"\n"
             "command = \"echo inline\"\ntimeout = 5\n\n"
             "[hooks.state.\"x:y\"]\ntrusted_hash = \"abc\"\n"))
    (let* ((read (drgnx-agent-config-read 'codex root))
           (hooks (cl-remove-if-not (lambda (i) (eq (plist-get i :section) 'hook)) (plist-get read :items))))
      (should-not (plist-get read :problems))
      (should (= (length hooks) 1))
      (let ((h (car hooks)))
        (should (plist-get h :readonly))
        (should (eq (plist-get h :from) 'user))
        (should (equal (plist-get (plist-get h :spec) :command) "echo inline"))
        (should (equal (plist-get (plist-get h :spec) :event) "PreToolUse"))
        (should (= (plist-get h :line) 1))
        (should (string-search "hooks.json" (plist-get h :note)))
        (let ((r (drgnx-agent-config-codex-test--write 'remove h 'user root)))
          (should (plist-get r :error)))))))

(ert-deftest drgnx-agent-config-codex/hooks-json-add-edit-remove ()
  (drgnx-agent-config-test-env
    (let* ((file (expand-file-name "hooks.json" (drgnx-agent-config-home 'codex)))
           (hook (lambda (cmd &optional timeout)
                   (list :kind 'codex :section 'hook :name "x" :enabled t
                         :spec (list :event "PreToolUse" :matcher "Bash" :command cmd :timeout timeout)))))
      (let ((r (drgnx-agent-config-codex-test--write 'add (funcall hook "echo a" 3) 'user root)))
        (should (plist-get r :ok))
        (should (string-search "re-approve" (plist-get r :note))))
      (should (plist-get (drgnx-agent-config-codex-test--write 'add (funcall hook "echo b") 'user root) :ok))
      (let ((items (plist-get (drgnx-agent-config-read 'codex root) :items)))
        (should (equal (mapcar (lambda (i) (plist-get (plist-get i :spec) :command)) items) '("echo a" "echo b"))))
      (should (plist-get (drgnx-agent-config-codex-test--write
                          'edit (append (funcall hook "echo c") (list :replaces (funcall hook "echo a"))) 'user root)
                         :ok))
      (should (equal (mapcar (lambda (i) (plist-get (plist-get i :spec) :command))
                             (plist-get (drgnx-agent-config-read 'codex root) :items))
                     '("echo c" "echo b")))
      (should (plist-get (drgnx-agent-config-codex-test--write 'remove (funcall hook "echo b") 'user root) :ok))
      (should (plist-get (drgnx-agent-config-codex-test--write 'remove (funcall hook "echo c") 'user root) :ok))
      (should (equal (string-trim (drgnx-agent-config-codex-test--text file)) "{}"))
      ;; a project hook file is made when needed
      (should (plist-get (drgnx-agent-config-codex-test--write 'add (funcall hook "echo p") 'project root) :ok))
      (should (file-exists-p (expand-file-name ".codex/hooks.json" root)))
      (should (plist-get (drgnx-agent-config-codex-test--write 'add (funcall hook "") 'user root) :error)))))

;;;; Skills

(ert-deftest drgnx-agent-config-codex/skill-toggle-uses-skills-config ()
  (drgnx-agent-config-test-env
    (let* ((config (drgnx-agent-config-codex-test--config))
           (skill (expand-file-name ".agents/skills/alpha" home))
           (before "# top\nmodel = \"gpt-5\"\n\n[tui]\nstyle = \"x\"\n"))
      (drgnx-agent-config-codex-test--put (expand-file-name "SKILL.md" skill)
                                          "---\nname: alpha\ndescription: Alpha\n---\nBody\n")
      (drgnx-agent-config-codex-test--put config before)
      (let ((item (drgnx-agent-config-codex-test--item (plist-get (drgnx-agent-config-read 'codex root) :items) 'skill "alpha")))
        (should (plist-get item :enabled))
        (should (plist-get (drgnx-agent-config-codex-test--write 'toggle item 'user root) :ok))
        (should (string-prefix-p before (drgnx-agent-config-codex-test--text config)))
        (let ((entries (cdr (assoc "config" (cdr (assoc "skills" (drgnx-toml-parse (drgnx-agent-config-codex-test--text config))))))))
          (should (equal entries (vector `(("path" . ,(expand-file-name "SKILL.md" skill)) ("enabled" . :false)))))))
      (let ((item (drgnx-agent-config-codex-test--item (plist-get (drgnx-agent-config-read 'codex root) :items) 'skill "alpha")))
        (should-not (plist-get item :enabled))
        (should (plist-get (drgnx-agent-config-codex-test--write 'toggle item 'user root) :ok))
        (should (equal (drgnx-agent-config-codex-test--text config) before))
        (should (plist-get (drgnx-agent-config-codex-test--item (plist-get (drgnx-agent-config-read 'codex root) :items) 'skill "alpha")
                           :enabled)))
      ;; an entry written as the skill directory (or with other keys) is found too
      (drgnx-agent-config-codex-test--put
       config (concat before (format "\n[[skills.config]]\npath = \"%s/\"\nenabled = false\n\n[[skills.config]]\npath = \"/else\"\nenabled = false\n" skill)))
      (let ((item (drgnx-agent-config-codex-test--item (plist-get (drgnx-agent-config-read 'codex root) :items) 'skill "alpha")))
        (should-not (plist-get item :enabled))
        (drgnx-agent-config-codex-test--write 'toggle item 'user root)
        (should (equal (cdr (assoc "config" (cdr (assoc "skills" (drgnx-toml-parse (drgnx-agent-config-codex-test--text config))))))
                       [(("path" . "/else") ("enabled" . :false))])))
      ;; an entry with keys drgnx does not know is not dropped when the skill goes on: only its enabled changes
      (drgnx-agent-config-codex-test--put
       config (format "[[skills.config]]\npath = \"%s\"\nenabled = false\nreason = \"mine\"\n" (expand-file-name "SKILL.md" skill)))
      (let ((item (drgnx-agent-config-codex-test--item (plist-get (drgnx-agent-config-read 'codex root) :items) 'skill "alpha")))
        (should-not (plist-get item :enabled))
        (drgnx-agent-config-codex-test--write 'toggle item 'user root)
        (should (equal (cdr (assoc "config" (cdr (assoc "skills" (drgnx-toml-parse (drgnx-agent-config-codex-test--text config))))))
                       (vector `(("path" . ,(expand-file-name "SKILL.md" skill)) ("enabled" . t) ("reason" . "mine"))))))
      ;; and switched off again, the unknown key stays
      (let ((item (drgnx-agent-config-codex-test--item (plist-get (drgnx-agent-config-read 'codex root) :items) 'skill "alpha")))
        (drgnx-agent-config-codex-test--write 'toggle item 'user root)
        (should (equal (cdr (assoc "reason" (aref (cdr (assoc "config" (cdr (assoc "skills" (drgnx-toml-parse (drgnx-agent-config-codex-test--text config)))))) 0)))
                       "mine"))))))

(ert-deftest drgnx-agent-config-codex/hook-edit-keeps-fields-drgnx-does-not-model ()
  (drgnx-agent-config-test-env
    (let ((file (expand-file-name "hooks.json" (drgnx-agent-config-home 'codex))))
      (drgnx-agent-config-codex-test--put
       file (concat "{\n  \"version\": 2,\n  \"hooks\": {\n    \"PreToolUse\": [\n      {\"matcher\": \"Bash\", \"label\": \"g\", \"hooks\": ["
                    "{\"type\": \"command\", \"command\": \"echo a\", \"timeout\": 3, \"statusMessage\": \"hi\", \"async\": true},"
                    "{\"type\": \"command\", \"command\": \"echo b\"}]}\n    ]\n  }\n}\n"))
      (let ((old (list :kind 'codex :section 'hook :name "x" :enabled t
                       :spec '(:event "PreToolUse" :matcher "Bash" :command "echo a"))))
        ;; in place
        (should (plist-get (drgnx-agent-config-codex-test--write
                            'edit (list :kind 'codex :section 'hook :name "x" :enabled t :replaces old
                                        :spec '(:event "PreToolUse" :matcher "Bash" :command "echo z" :timeout 9))
                            'user root)
                           :ok))
        (let* ((value (plist-get (drgnx-agent-config-json-read file) :value))
               (group (aref (cdr (assq 'PreToolUse (cdr (assq 'hooks value)))) 0))
               (hook (aref (cdr (assq 'hooks group)) 0)))
          (should (equal (cdr (assq 'version value)) 2))
          (should (equal (cdr (assq 'label group)) "g"))
          (should (equal (cdr (assq 'command hook)) "echo z"))
          (should (equal (cdr (assq 'timeout hook)) 9))
          (should (equal (cdr (assq 'statusMessage hook)) "hi"))
          (should (eq (cdr (assq 'async hook)) t)))
        ;; moved to another event: the unknown fields go with it, the group's own stay
        (should (plist-get (drgnx-agent-config-codex-test--write
                            'edit (list :kind 'codex :section 'hook :name "x" :enabled t
                                        :replaces '(:kind codex :section hook :name "x"
                                                          :spec (:event "PreToolUse" :matcher "Bash" :command "echo z"))
                                        :spec '(:event "Stop" :matcher nil :command "echo z"))
                            'user root)
                           :ok))
        (let* ((value (plist-get (drgnx-agent-config-json-read file) :value)))
          (should (equal (cdr (assq 'statusMessage (aref (cdr (assq 'hooks (aref (cdr (assq 'Stop (cdr (assq 'hooks value)))) 0))) 0))) "hi"))
          (let ((group (aref (cdr (assq 'PreToolUse (cdr (assq 'hooks value)))) 0)))
            (should (equal (cdr (assq 'label group)) "g"))
            (should (equal (cdr (assq 'command (aref (cdr (assq 'hooks group)) 0))) "echo b"))))))))

(ert-deftest drgnx-agent-config-codex/mcp-edit-that-fails-leaves-the-file-alone ()
  (drgnx-agent-config-test-env
    (let* ((config (drgnx-agent-config-codex-test--config))
           (text "[mcp_servers.a]\ncommand = \"c\"\nfuture_key = [1, 2]\n\n[mcp_servers.b]\ncommand = \"d\"\n"))
      (drgnx-agent-config-codex-test--put config text)
      ;; a rename onto an existing name fails as a whole: neither the old nor the new entry is touched
      (let ((r (drgnx-agent-config-codex-test--write
                'edit (list :kind 'codex :section 'mcp :name "b" :spec '(:type stdio :command "x")
                            :replaces (drgnx-agent-config-codex-test--mcp "a" nil))
                'user root)))
        (should (plist-get r :error)))
      (should (equal (drgnx-agent-config-codex-test--text config) text)))))

(ert-deftest drgnx-agent-config-codex/skill-add-makes-the-file ()
  (drgnx-agent-config-test-env
    (let ((r (drgnx-agent-config-codex-test--write
              'add (list :kind 'codex :section 'skill :name "mine" :spec '(:description "Does things")) 'user root)))
      (should (plist-get r :ok))
      (should (file-exists-p (expand-file-name ".agents/skills/mine/SKILL.md" home))))
    (should (plist-get (drgnx-agent-config-codex-test--write
                        'add (list :kind 'codex :section 'skill :name "pmine" :spec '(:description "x")) 'project root)
                       :ok))
    (should (file-exists-p (expand-file-name ".agents/skills/pmine/SKILL.md" root)))))

;;;; Routes

(ert-deftest drgnx-agent-config-codex/native-route-is-the-chatgpt-login ()
  (drgnx-agent-config-test-env
    (let ((routes (drgnx-agent-config-codex-routes root)))
      (should (= (length routes) 1))
      (let ((r (car routes)))
        (should (eq (plist-get r :billing) 'subscription))
        (should (string-search "ChatGPT" (plist-get r :key-where)))
        (should (equal (plist-get r :profile) "codex"))
        (should-not (plist-get r :base-url))))
    ;; a model set in config.toml shows
    (drgnx-agent-config-codex-test--put (drgnx-agent-config-codex-test--config) "model = \"gpt-5\"\n")
    (should (equal (plist-get (car (drgnx-agent-config-codex-routes root)) :model) "gpt-5"))))

(ert-deftest drgnx-agent-config-codex/openrouter-route-added ()
  (drgnx-agent-config-test-env
    (let* ((config (drgnx-agent-config-codex-test--config))
           (before "# mine\nmodel = \"gpt-5\"\n\n[tui]\nstyle = \"x\"\n")
           (backup (concat config ".drgnx-bak")))
      (drgnx-agent-config-codex-test--put config before)
      (let ((r (drgnx-agent-config-codex-add-openrouter "moonshotai/kimi-k2")))
        (should (plist-get r :ok))
        (should (string-search "codex --profile openrouter" (plist-get r :note))))
      (let* ((after (drgnx-agent-config-codex-test--text config))
             (parsed (drgnx-toml-parse after)))
        (should (string-prefix-p before after))
        (should (equal (cdr (assoc "openrouter" (cdr (assoc "model_providers" parsed))))
                       '(("name" . "OpenRouter") ("base_url" . "https://openrouter.ai/api/v1")
                         ("env_key" . "OPENROUTER_API_KEY") ("wire_api" . "responses"))))
        (should (equal (cdr (assoc "openrouter" (cdr (assoc "profiles" parsed))))
                       '(("model_provider" . "openrouter") ("model" . "moonshotai/kimi-k2"))))
        ;; the default stays the native login
        (should (equal (cdr (assoc "model" parsed)) "gpt-5"))
        (should-not (assoc "model_provider" parsed)))
      (should (equal (drgnx-agent-config-codex-test--text backup) before))
      ;; the page now lists two routes
      (let* ((read (drgnx-agent-config-read 'codex root))
             (routes (plist-get read :routes)))
        (should-not (plist-get read :notes))
        (should (equal (mapcar (lambda (r) (plist-get r :profile)) routes) '("codex" "openrouter")))
        (let ((r (cadr routes)))
          (should (eq (plist-get r :billing) 'openrouter))
          (should (equal (plist-get r :model) "moonshotai/kimi-k2"))
          (should (equal (plist-get r :base-url) "https://openrouter.ai/api/v1"))
          (should (string-search "OPENROUTER_API_KEY" (plist-get r :key-where)))
          (should (equal (plist-get r :launch) "codex --profile openrouter"))))
      ;; again with another model: replaced, once, other keys of the two tables stay
      (let ((mid (drgnx-agent-config-codex-test--text config)))
        (drgnx-agent-config-codex-test--put
         config (replace-regexp-in-string "env_key = " "query_params = { x = \"1\" }\nenv_key = " mid t t)))
      (should (plist-get (drgnx-agent-config-codex-add-openrouter "deepseek/deepseek-chat") :ok))
      (let* ((parsed (drgnx-toml-parse (drgnx-agent-config-codex-test--text config)))
             (provider (cdr (assoc "openrouter" (cdr (assoc "model_providers" parsed))))))
        (should (equal (cdr (assoc "query_params" provider)) '(("x" . "1"))))
        (should (equal (cdr (assoc "model" (cdr (assoc "openrouter" (cdr (assoc "profiles" parsed))))) )
                       "deepseek/deepseek-chat"))
        (should (= (length (cdr (assoc "profiles" parsed))) 1)))
      ;; nothing to change: nothing written, the backup stays
      (let ((text (drgnx-agent-config-codex-test--text config)))
        (drgnx-agent-config-codex-add-openrouter "deepseek/deepseek-chat")
        (should (equal text (drgnx-agent-config-codex-test--text config))))
      ;; a bad model name is refused
      (dolist (bad '("" "a b" "x\ny" "m\"q"))
        (should (plist-get (drgnx-agent-config-codex-add-openrouter bad) :error))))))

(ert-deftest drgnx-agent-config-codex/openrouter-keeps-the-users-url-and-key-name ()
  (drgnx-agent-config-test-env
    (let ((config (drgnx-agent-config-codex-test--config)))
      (drgnx-agent-config-codex-test--put
       config (concat "[model_providers.openrouter]\nname = \"Mine\"\nbase_url = \"https://proxy.example/v1\"\n"
                      "env_key = \"MY_OR_KEY\"\nwire_api = \"chat\"\n"))
      (let ((r (drgnx-agent-config-codex-add-openrouter "openai/gpt-5")))
        (should (plist-get r :ok))
        (should (string-search "base_url" (plist-get r :note)))
        (should (string-search "env_key" (plist-get r :note)))
        (should (string-search "wire_api" (plist-get r :note)))
        (should-not (string-search "proxy.example" (plist-get r :note)))
        (should-not (string-search "MY_OR_KEY" (plist-get r :note))))
      (let ((provider (cdr (assoc "openrouter" (cdr (assoc "model_providers" (drgnx-toml-parse (drgnx-agent-config-codex-test--text config))))))))
        (should (equal provider '(("name" . "Mine") ("base_url" . "https://proxy.example/v1")
                                  ("env_key" . "MY_OR_KEY") ("wire_api" . "responses")))))
      ;; a wire_api that is not chat stays; nothing to say about the others
      (drgnx-agent-config-codex-test--put
       config (concat "[model_providers.openrouter]\nbase_url = \"https://openrouter.ai/api/v1\"\nwire_api = \"other\"\n"))
      (let ((r (drgnx-agent-config-codex-add-openrouter "openai/gpt-5")))
        (should-not (string-search "base_url" (plist-get r :note)))
        (should-not (string-search "wire_api" (plist-get r :note))))
      (should (equal (cdr (assoc "wire_api" (cdr (assoc "openrouter" (cdr (assoc "model_providers" (drgnx-toml-parse (drgnx-agent-config-codex-test--text config))))))))
                     "other")))))

(ert-deftest drgnx-agent-config-codex/openrouter-route-in-a-new-file ()
  (drgnx-agent-config-test-env
    (should (plist-get (drgnx-agent-config-codex-add-openrouter "openai/gpt-5") :ok))
    (let ((config (drgnx-agent-config-codex-test--config)))
      (should (equal (drgnx-agent-config-codex-test--text config)
                     (drgnx-agent-config-codex-openrouter-snippet "openai/gpt-5")))
      (should-not (file-exists-p (concat config ".drgnx-bak")))
      (should (string-search "[model_providers.openrouter]" (drgnx-agent-config-codex-openrouter-snippet "m")))
      (should (string-search "[profiles.openrouter]" (drgnx-agent-config-codex-openrouter-snippet "m"))))))

(ert-deftest drgnx-agent-config-codex/a-default-provider-is-noted ()
  (drgnx-agent-config-test-env
    (drgnx-agent-config-codex-test--put (drgnx-agent-config-codex-test--config) "model_provider = \"openrouter\"\n")
    (let ((read (drgnx-agent-config-read 'codex root)))
      (should (cl-some (lambda (n) (string-search "model_provider" n)) (plist-get read :notes))))))

(ert-deftest drgnx-agent-config-codex/profiles-with-other-providers-are-not-openrouter-routes ()
  (drgnx-agent-config-test-env
    (drgnx-agent-config-codex-test--put
     (drgnx-agent-config-codex-test--config)
     (concat "[model_providers.local]\nname = \"Local\"\nbase_url = \"http://localhost:11434/v1\"\n\n"
             "[model_providers.or2]\nname = \"OR\"\nbase_url = \"https://openrouter.ai/api/v1\"\nenv_key = \"K\"\n\n"
             "[profiles.l]\nmodel_provider = \"local\"\nmodel = \"x\"\n\n"
             "[profiles.viaor]\nmodel_provider = \"or2\"\nmodel = \"y\"\n"))
    (should (equal (mapcar (lambda (r) (plist-get r :profile)) (drgnx-agent-config-codex-routes root))
                   '("codex" "viaor")))))

(provide 'agent-config-codex-test)
;;; agent-config-codex-test.el ends here
