;;; agent-config-kimi-test.el --- batch tests: Kimi Code's settings (MCP servers, hooks, skills) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-agent-config-kimi)
(load (expand-file-name "test/fixtures/agent-config-fixture" drgnx-dir) nil t)

(defvar drgnx-agent-config-kimi-test--rewrites 0
  "How many times a stub rewrote a file.")

(defun drgnx-agent-config-kimi-test--put (file text)
  "Write TEXT to FILE (making its directory); return FILE."
  (make-directory (file-name-directory file) t)
  (write-region text nil file nil 'silent)
  file)

(defun drgnx-agent-config-kimi-test--text (file)
  "The text of FILE."
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defun drgnx-agent-config-kimi-test--value (file)
  "The parsed JSON of FILE."
  (plist-get (drgnx-agent-config-json-read file) :value))

(defun drgnx-agent-config-kimi-test--keys (file &rest path)
  "The member names, in order, of the object at PATH (strings) in the JSON FILE."
  (let ((value (drgnx-agent-config-kimi-test--value file)))
    (dolist (k path)
      (setq value (cdr (cl-find-if (lambda (c) (equal (symbol-name (car c)) k)) value))))
    (mapcar (lambda (c) (symbol-name (car c))) value)))

(defun drgnx-agent-config-kimi-test--item (items section name)
  "The item of SECTION called NAME."
  (cl-find-if (lambda (i) (and (eq (plist-get i :section) section) (equal (plist-get i :name) name))) items))

(defun drgnx-agent-config-kimi-test--names (items section &optional from)
  "The sorted names of the SECTION items (only those FROM, when given)."
  (sort (mapcar (lambda (i) (plist-get i :name))
                (cl-remove-if-not (lambda (i) (and (eq (plist-get i :section) section)
                                                   (or (null from) (eq (plist-get i :from) from))))
                                  items))
        #'string<))

(defun drgnx-agent-config-kimi-test--write (op item scope root)
  "Run the write; return what the callback got (the callback runs at once for files)."
  (let ((result nil))
    (drgnx-agent-config-write 'kimi op item scope root (lambda (r) (setq result r)))
    (or result (error "The write never called back"))))

(defun drgnx-agent-config-kimi-test--mcp (name spec &optional replaces)
  "An MCP server item."
  (list :kind 'kimi :section 'mcp :name name :spec spec :enabled t :replaces replaces))

(defun drgnx-agent-config-kimi-test--hook (event matcher command &optional timeout replaces)
  "A hook item."
  (list :kind 'kimi :section 'hook :name event :enabled t :replaces replaces
        :spec (list :event event :matcher matcher :command command :timeout timeout)))

(defun drgnx-agent-config-kimi-test--rewrite-once (file text)
  "Rewrite FILE to TEXT the first time this runs (a program changing its file under us)."
  (when (zerop drgnx-agent-config-kimi-test--rewrites)
    (setq drgnx-agent-config-kimi-test--rewrites 1)
    (drgnx-agent-config-kimi-test--put file text)))

;;;; Where Kimi Code keeps its files

(ert-deftest drgnx-agent-config-kimi/honours-kimi-code-home ()
  (drgnx-agent-config-test-env
    (let ((kimi-home (concat drgnx-agent-config-test--dir "kimi/")))
      (should (equal (drgnx-agent-config-home 'kimi) kimi-home))
      (drgnx-agent-config-kimi-test--put (concat kimi-home "mcp.json") "{\"mcpServers\": {\"in-env\": {\"command\": \"x\"}}}")
      (drgnx-agent-config-kimi-test--put (concat home ".kimi-code/mcp.json") "{\"mcpServers\": {\"in-home\": {\"command\": \"y\"}}}")
      (drgnx-agent-config-kimi-test--put (concat kimi-home "AGENTS.md") "rules\n")
      (let ((read (drgnx-agent-config-read 'kimi root)))
        (should (equal (drgnx-agent-config-kimi-test--names (plist-get read :items) 'mcp) '("in-env")))
        (should (equal (plist-get (car (plist-get read :items)) :file) (concat kimi-home "mcp.json")))
        (should (equal (plist-get read :rules) (list (concat kimi-home "AGENTS.md")))))
      (should (equal (caddr (assq 'user (drgnx-agent-config-scopes 'kimi 'mcp root))) (concat kimi-home "mcp.json")))
      (should (equal (caddr (assq 'user (drgnx-agent-config-scopes 'kimi 'hook root))) (concat kimi-home "config.toml")))
      (should (equal (caddr (assq 'user (drgnx-agent-config-scopes 'kimi 'skill root))) (concat kimi-home "skills")))
      ;; a write lands in KIMI_CODE_HOME, not in ~/.kimi-code
      (should (plist-get (drgnx-agent-config-kimi-test--write
                          'add (drgnx-agent-config-kimi-test--mcp "new" '(:command "z")) 'user root)
                         :ok))
      (should (member "new" (drgnx-agent-config-kimi-test--keys (concat kimi-home "mcp.json") "mcpServers")))
      (should-not (member "new" (drgnx-agent-config-kimi-test--keys (concat home ".kimi-code/mcp.json") "mcpServers")))
      ;; unset, or empty: ~/.kimi-code
      (dolist (setting '(nil ""))
        (let ((process-environment (cons (if setting (concat "KIMI_CODE_HOME=" setting) "KIMI_CODE_HOME")
                                         (cl-remove-if (lambda (e) (string-prefix-p "KIMI_CODE_HOME" e)) process-environment))))
          (should (equal (drgnx-agent-config-home 'kimi) (concat home ".kimi-code/")))
          (should (equal (drgnx-agent-config-kimi-test--names
                          (plist-get (drgnx-agent-config-read 'kimi root) :items) 'mcp)
                         '("in-home"))))))))

(ert-deftest drgnx-agent-config-kimi/user-and-project-mcp ()
  (drgnx-agent-config-test-env
    (let* ((kimi-home (drgnx-agent-config-home 'kimi))
           (user (concat kimi-home "mcp.json"))
           (project (concat root ".kimi-code/mcp.json"))
           (shared (concat root ".mcp.json")))
      (drgnx-agent-config-kimi-test--put
       user (concat "{\n  \"mcpServers\": {\n"
                    "    \"u-srv\": {\"command\": \"npx\", \"args\": [\"-y\", \"pkg\"], \"env\": {\"A\": \"b\"}, \"cwd\": \"/w\"},\n"
                    "    \"u-http\": {\"url\": \"https://example.com/mcp\", \"bearerTokenEnvVar\": \"EX_TOKEN\","
                    " \"headers\": {\"X-Id\": \"7\"}},\n"
                    "    \"u-off\": {\"command\": \"off\", \"enabled\": false},\n"
                    "    \"u-sse\": {\"transport\": \"sse\", \"url\": \"https://example.com/sse\"}\n"
                    "  }\n}\n"))
      (drgnx-agent-config-kimi-test--put project "{\"mcpServers\": {\"p-srv\": {\"command\": \"proj\"}}}")
      (drgnx-agent-config-kimi-test--put shared "{\"mcpServers\": {\"s-srv\": {\"command\": \"shared\"}}}")
      (let* ((read (drgnx-agent-config-read 'kimi root))
             (items (plist-get read :items)))
        (should-not (plist-get read :problems))
        (should (equal (drgnx-agent-config-kimi-test--names items 'mcp)
                       '("p-srv" "s-srv" "u-http" "u-off" "u-srv" "u-sse")))
        (let* ((u (drgnx-agent-config-kimi-test--item items 'mcp "u-srv")) (spec (plist-get u :spec)))
          (should (eq (plist-get u :from) 'user))
          (should (equal (plist-get u :file) user))
          (should (= (plist-get u :line) 3))
          (should-not (plist-get u :readonly))
          (should (plist-get u :enabled))
          (should (eq (plist-get spec :type) 'stdio))
          (should (equal (plist-get spec :command) "npx"))
          (should (equal (plist-get spec :args) '("-y" "pkg")))
          (should (equal (plist-get spec :env) '(("A" . "b"))))
          (should (equal (plist-get spec :cwd) "/w")))
        (let* ((h (drgnx-agent-config-kimi-test--item items 'mcp "u-http")) (spec (plist-get h :spec)))
          (should (eq (plist-get spec :type) 'http))
          (should (equal (plist-get spec :url) "https://example.com/mcp"))
          (should (equal (plist-get spec :headers) '(("X-Id" . "7"))))
          (should (equal (plist-get spec :bearer-env) "EX_TOKEN"))
          (should (eq (car (drgnx-agent-config-cheap-status h)) 'ok)))
        (should (eq (plist-get (plist-get (drgnx-agent-config-kimi-test--item items 'mcp "u-sse") :spec) :type) 'sse))
        (should-not (plist-get (drgnx-agent-config-kimi-test--item items 'mcp "u-off") :enabled))
        (let ((p (drgnx-agent-config-kimi-test--item items 'mcp "p-srv")))
          (should (eq (plist-get p :from) 'project))
          (should (equal (plist-get p :file) project))
          (should-not (plist-get p :readonly)))
        ;; ROOT/.mcp.json is read by Kimi Code too; Claude Code's page owns its edits
        (let ((s (drgnx-agent-config-kimi-test--item items 'mcp "s-srv")))
          (should (eq (plist-get s :from) 'project))
          (should (equal (plist-get s :file) shared))
          (should (plist-get s :readonly)))
        (should (cl-some (lambda (n) (string-match-p "\\.mcp\\.json" n)) (plist-get read :notes))))
      ;; the scopes an add may go to
      (should (equal (mapcar #'car (drgnx-agent-config-scopes 'kimi 'mcp root)) '(user project)))
      (should (equal (caddr (assq 'project (drgnx-agent-config-scopes 'kimi 'mcp root))) project))
      (should (equal (mapcar #'car (drgnx-agent-config-scopes 'kimi 'mcp nil)) '(user)))
      ;; without a project only the user file is read
      (should (equal (drgnx-agent-config-kimi-test--names (plist-get (drgnx-agent-config-read 'kimi nil) :items) 'mcp)
                     '("u-http" "u-off" "u-srv" "u-sse"))))))

(ert-deftest drgnx-agent-config-kimi/mcp-writes-change-only-their-entry ()
  (drgnx-agent-config-test-env
    (let* ((user (concat (drgnx-agent-config-home 'kimi) "mcp.json"))
           (project (concat root ".kimi-code/mcp.json")))
      (drgnx-agent-config-kimi-test--put
       user (concat "{\n    \"mcpServers\": {\n"
                    "        \"b\": {\"command\": \"old\", \"args\": [\"1\"], \"startupTimeoutMs\": 9000, \"env\": {\"K\": \"v\"}},\n"
                    "        \"a\": {\"url\": \"https://example.com/a\", \"bearerTokenEnvVar\": \"A_TOKEN\", \"auth\": \"oauth\"}\n"
                    "    },\n    \"other\": 1\n}\n"))
      ;; edit: the command changes, startupTimeoutMs and the position stay, a dropped key goes
      (let ((r (drgnx-agent-config-kimi-test--write
                'edit (drgnx-agent-config-kimi-test--mcp "b" '(:type stdio :command "new" :args ("2" "3")))
                'user root)))
        (should (plist-get r :ok))
        (should (string-match-p "restart\\|new session" (plist-get r :note))))
      (let ((value (drgnx-agent-config-kimi-test--value user)))
        (should (equal (drgnx-agent-config-kimi-test--keys user "mcpServers") '("b" "a")))
        (should (equal (drgnx-agent-config-kimi-test--keys user "mcpServers" "b") '("command" "args" "startupTimeoutMs")))
        (should (equal (cdr (assq 'command (cdr (assq 'b (cdr (assq 'mcpServers value)))))) "new"))
        (should (eq (cdr (assq 'other value)) 1)))
      (should (string-prefix-p "{\n    \"mcpServers\"" (drgnx-agent-config-kimi-test--text user)))
      ;; the previous content is kept once
      (should (string-match-p "\"old\"" (drgnx-agent-config-kimi-test--text (concat user ".drgnx-bak"))))
      ;; a rename: the old entry is replaced where it stood
      (should (plist-get (drgnx-agent-config-kimi-test--write
                          'edit (drgnx-agent-config-kimi-test--mcp
                                 "b2" '(:type stdio :command "new")
                                 (drgnx-agent-config-kimi-test--mcp "b" '(:command "new")))
                          'user root)
                         :ok))
      (should (equal (sort (drgnx-agent-config-kimi-test--keys user "mcpServers") #'string<) '("a" "b2")))
      ;; ... and keeps the members it has that drgnx does not model
      (should (equal (drgnx-agent-config-kimi-test--keys user "mcpServers" "b2") '("command" "startupTimeoutMs")))
      ;; add an sse server (the type must be written: it is inferred as http otherwise) and an http one with bearer env
      (should (plist-get (drgnx-agent-config-kimi-test--write
                          'add (drgnx-agent-config-kimi-test--mcp "live" '(:type sse :url "https://example.com/sse"
                                                                                 :headers (("X-A" . "b"))))
                          'user root)
                         :ok))
      (should (equal (drgnx-agent-config-kimi-test--keys user "mcpServers" "live") '("transport" "url" "headers")))
      (should (plist-get (drgnx-agent-config-kimi-test--write
                          'add (drgnx-agent-config-kimi-test--mcp "web" '(:type http :url "https://example.com/w"
                                                                                :bearer-env "W_TOKEN"))
                          'user root)
                         :ok))
      (should (equal (drgnx-agent-config-kimi-test--keys user "mcpServers" "web") '("url" "bearerTokenEnvVar")))
      (let ((read (drgnx-agent-config-read 'kimi root)))
        (should (equal (plist-get (plist-get (drgnx-agent-config-kimi-test--item (plist-get read :items) 'mcp "web") :spec)
                                  :bearer-env)
                       "W_TOKEN")))
      ;; an existing http entry changes its URL and keeps `auth' and the bearer variable it has
      (should (plist-get (drgnx-agent-config-kimi-test--write
                          'edit (drgnx-agent-config-kimi-test--mcp "a" '(:type http :url "https://example.com/a2"
                                                                               :bearer-env "A_TOKEN"))
                          'user root)
                         :ok))
      (should (equal (drgnx-agent-config-kimi-test--keys user "mcpServers" "a") '("url" "bearerTokenEnvVar" "auth")))
      ;; the project scope creates its file; a name taken is refused
      (should-not (file-exists-p project))
      (should (plist-get (drgnx-agent-config-kimi-test--write
                          'add (drgnx-agent-config-kimi-test--mcp "p" '(:command "proj")) 'project root)
                         :ok))
      (should (equal (drgnx-agent-config-kimi-test--keys project "mcpServers") '("p")))
      (should (plist-get (drgnx-agent-config-kimi-test--write
                          'add (drgnx-agent-config-kimi-test--mcp "p" '(:command "again")) 'project root)
                         :error))
      (should (equal (drgnx-agent-config-kimi-test--keys project "mcpServers") '("p")))
      ;; toggle: `enabled' false, then removed again
      (let ((item (drgnx-agent-config-kimi-test--item (plist-get (drgnx-agent-config-read 'kimi root) :items) 'mcp "p")))
        (should (plist-get (drgnx-agent-config-kimi-test--write 'toggle item 'project root) :ok))
        (let ((off (drgnx-agent-config-kimi-test--item (plist-get (drgnx-agent-config-read 'kimi root) :items) 'mcp "p")))
          (should-not (plist-get off :enabled))
          (should (equal (drgnx-agent-config-kimi-test--keys project "mcpServers" "p") '("command" "enabled")))
          (should (plist-get (drgnx-agent-config-kimi-test--write 'toggle off 'project root) :ok))
          (should (equal (drgnx-agent-config-kimi-test--keys project "mcpServers" "p") '("command")))))
      ;; remove
      (should (plist-get (drgnx-agent-config-kimi-test--write
                          'remove (drgnx-agent-config-kimi-test--mcp "p" '(:command "proj")) 'project root)
                         :ok))
      (should-not (drgnx-agent-config-kimi-test--keys project "mcpServers"))
      ;; names that are not names, and a project scope without a project
      (dolist (bad '("-x" "a b" "" "x/y"))
        (let ((r (drgnx-agent-config-kimi-test--write
                  'add (drgnx-agent-config-kimi-test--mcp bad '(:command "x")) 'user root)))
          (should (plist-get r :error))
          (should (string-match-p "characters \\. - _" (plist-get r :error)))))
      (should (plist-get (drgnx-agent-config-kimi-test--write
                          'add (drgnx-agent-config-kimi-test--mcp "n" '(:command "x")) 'project nil)
                         :error)))))

(ert-deftest drgnx-agent-config-kimi/mcp-bad-files-and-secrets ()
  (drgnx-agent-config-test-env
    (let* ((user (concat (drgnx-agent-config-home 'kimi) "mcp.json"))
           (project (concat root ".kimi-code/mcp.json")))
      (drgnx-agent-config-kimi-test--put user "{\n  \"mcpServers\": {\n    \"a\": {\"command\": \"x\"},\n  }\n}\n")
      (drgnx-agent-config-kimi-test--put project "{\"mcpServers\": {\"p\": {\"command\": \"x\"}}}")
      ;; an unreadable file is a problem with its line, and its good neighbours still show
      (let ((read (drgnx-agent-config-read 'kimi root)))
        (should (= (length (plist-get read :problems)) 1))
        (should (equal (car (car (plist-get read :problems))) user))
        (should (= (cadr (car (plist-get read :problems))) 3))
        (should (equal (drgnx-agent-config-kimi-test--names (plist-get read :items) 'mcp) '("p"))))
      ;; and is never written
      (let* ((before (drgnx-agent-config-kimi-test--text user))
             (r (drgnx-agent-config-kimi-test--write
                 'add (drgnx-agent-config-kimi-test--mcp "n" '(:command "x" :env (("API_KEY" . "s3cr3t-value")))) 'user root)))
        (should (plist-get r :error))
        (should (string-match-p "line 3" (plist-get r :error)))
        (should-not (string-match-p "s3cr3t-value" (plist-get r :error)))
        (should (equal (drgnx-agent-config-kimi-test--text user) before))
        (should-not (file-exists-p (concat user ".drgnx-bak"))))
      ;; an error never shows a value
      (let ((r (drgnx-agent-config-kimi-test--write
                'add (drgnx-agent-config-kimi-test--mcp "m" '(:command "x" :env (("API_KEY" . 12345678)))) 'project root)))
        (should (plist-get r :error))
        (should-not (string-match-p "12345678" (plist-get r :error))))
      ;; a stdio server needs a command, an http one a URL
      (should (plist-get (drgnx-agent-config-kimi-test--write
                          'add (drgnx-agent-config-kimi-test--mcp "m" '(:type stdio)) 'project root)
                         :error))
      (should (plist-get (drgnx-agent-config-kimi-test--write
                          'add (drgnx-agent-config-kimi-test--mcp "m" '(:type http)) 'project root)
                         :error))
      ;; a secret in env is written (a file, not a command line) and still found by the model
      (should (plist-get (drgnx-agent-config-kimi-test--write
                          'add (drgnx-agent-config-kimi-test--mcp "k" '(:command "x" :env (("API_KEY" . "s3cr3t-value"))))
                          'project root)
                         :ok))
      (let ((item (drgnx-agent-config-kimi-test--item (plist-get (drgnx-agent-config-read 'kimi root) :items) 'mcp "k")))
        (should (equal (drgnx-agent-config-secrets (plist-get item :spec)) '("s3cr3t-value")))))))

(ert-deftest drgnx-agent-config-kimi/concurrent-rewrite-is-kept ()
  (drgnx-agent-config-test-env
    (let ((user (concat (drgnx-agent-config-home 'kimi) "mcp.json")) (config (concat (drgnx-agent-config-home 'kimi) "config.toml")))
      (drgnx-agent-config-kimi-test--put user "{\"mcpServers\": {\"a\": {\"command\": \"x\"}}}\n")
      (setq drgnx-agent-config-kimi-test--rewrites 0)
      (let ((stub (lambda (orig file &rest args)
                    (prog1 (apply orig file args)
                      (drgnx-agent-config-kimi-test--rewrite-once
                       user "{\"mcpServers\": {\"a\": {\"command\": \"x\"}, \"theirs\": {\"command\": \"y\"}}}\n")))))
        (advice-add 'drgnx-agent-config-json-read :around stub)
        (unwind-protect
            (should (plist-get (drgnx-agent-config-kimi-test--write
                                'add (drgnx-agent-config-kimi-test--mcp "mine" '(:command "z")) 'user root)
                               :ok))
          (advice-remove 'drgnx-agent-config-json-read stub)))
      (should (equal (drgnx-agent-config-kimi-test--keys user "mcpServers") '("a" "theirs" "mine")))
      ;; the same for config.toml
      (drgnx-agent-config-kimi-test--put config "default_model = \"m\"\n")
      (setq drgnx-agent-config-kimi-test--rewrites 0)
      (let ((stub (lambda (orig string &rest args)
                    (drgnx-agent-config-kimi-test--rewrite-once config "default_model = \"m\"\nyolo = true\n")
                    (apply orig string args))))
        (advice-add 'drgnx-toml-set-array-entry :around stub)
        (unwind-protect
            (should (plist-get (drgnx-agent-config-kimi-test--write
                                'add (drgnx-agent-config-kimi-test--hook "Stop" nil "echo done") 'user root)
                               :ok))
          (advice-remove 'drgnx-toml-set-array-entry stub)))
      (should (string-match-p "yolo = true" (drgnx-agent-config-kimi-test--text config)))
      (should (string-match-p "echo done" (drgnx-agent-config-kimi-test--text config))))))

;;;; Hooks (config.toml, [[hooks]])

(ert-deftest drgnx-agent-config-kimi/hooks-read-and-write ()
  (drgnx-agent-config-test-env
    (let* ((config (concat (drgnx-agent-config-home 'kimi) "config.toml"))
           (head "# my settings\ndefault_model = \"kimi\"   # keep\n\n[providers.moon]\ntype = \"kimi\"\n\n")
           (tail "\n# tail comment\n[mcp]\nstartup_timeout_ms = 5000\n")
           before-bad)
      (drgnx-agent-config-kimi-test--put
       config (concat head
                      "[[hooks]]\nevent = \"Stop\"\ncommand = \"echo stop\"\n\n"
                      "[[hooks]]\nevent = \"PreToolUse\"\nmatcher = \"Bash\"\ncommand = \"echo pre\"\ntimeout = 30\n"
                      tail))
      (let* ((read (drgnx-agent-config-read 'kimi root))
             (items (plist-get read :items))
             (stop (drgnx-agent-config-kimi-test--item items 'hook "Stop"))
             (pre (drgnx-agent-config-kimi-test--item items 'hook "PreToolUse Bash")))
        (should-not (plist-get read :problems))
        (should (eq (plist-get stop :from) 'user))
        (should (equal (plist-get stop :file) config))
        (should (= (plist-get stop :line) 7))
        (should (= (plist-get pre :line) 11))
        (should-not (plist-get stop :readonly))
        (should (equal (plist-get stop :spec) '(:event "Stop" :matcher nil :command "echo stop" :timeout nil)))
        (should (equal (plist-get pre :spec) '(:event "PreToolUse" :matcher "Bash" :command "echo pre" :timeout 30)))
        ;; edit one hook, in place; every other byte stays
        (let ((before (drgnx-agent-config-kimi-test--text config)))
          (should (plist-get (drgnx-agent-config-kimi-test--write
                              'edit (drgnx-agent-config-kimi-test--hook "Stop" nil "echo stopped" 5 stop) 'user root)
                             :ok))
          (let ((after (drgnx-agent-config-kimi-test--text config)))
            (should (string-prefix-p head after))
            (should (string-suffix-p tail after))
            (should (string-match-p "command = \"echo stopped\"\ntimeout = 5" after))
            (should (string-match-p "command = \"echo pre\"" after))
            (should-not (equal before after))))
        ;; add, then remove
        (should (plist-get (drgnx-agent-config-kimi-test--write
                            'add (drgnx-agent-config-kimi-test--hook "SessionStart" nil "echo hi") 'user root)
                           :ok))
        (let ((items (plist-get (drgnx-agent-config-read 'kimi root) :items)))
          (should (equal (drgnx-agent-config-kimi-test--names items 'hook) '("PreToolUse Bash" "SessionStart" "Stop"))))
        (should (plist-get (drgnx-agent-config-kimi-test--write
                            'remove (drgnx-agent-config-kimi-test--hook "PreToolUse" "Bash" "echo pre") 'user root)
                           :ok))
        (should-not (string-match-p "echo pre" (drgnx-agent-config-kimi-test--text config)))
        (should (string-prefix-p head (drgnx-agent-config-kimi-test--text config)))
        (should (string-search tail (drgnx-agent-config-kimi-test--text config)))
        ;; an edit that makes a hook identical to another is refused like an add
        (let ((before (drgnx-agent-config-kimi-test--text config))
              (stop (drgnx-agent-config-kimi-test--item (plist-get (drgnx-agent-config-read 'kimi root) :items) 'hook "Stop")))
          (should (plist-get (drgnx-agent-config-kimi-test--write
                              'edit (drgnx-agent-config-kimi-test--hook "SessionStart" nil "echo hi" nil stop) 'user root)
                             :error))
          (should (equal (drgnx-agent-config-kimi-test--text config) before)))
        ;; a hook that is not there, one already there, and ones Kimi Code would reject
        (should (plist-get (drgnx-agent-config-kimi-test--write
                            'remove (drgnx-agent-config-kimi-test--hook "Stop" nil "echo gone") 'user root)
                           :error))
        (should (plist-get (drgnx-agent-config-kimi-test--write
                            'add (drgnx-agent-config-kimi-test--hook "SessionStart" nil "echo hi") 'user root)
                           :error))
        (setq before-bad (drgnx-agent-config-kimi-test--text config))
        (dolist (bad (list (drgnx-agent-config-kimi-test--hook "NoSuchEvent" nil "x")
                           (drgnx-agent-config-kimi-test--hook "Stop" nil "")
                           (drgnx-agent-config-kimi-test--hook "Stop" nil "x" 0)
                           (drgnx-agent-config-kimi-test--hook "Stop" nil "x" 601)))
          (should (plist-get (drgnx-agent-config-kimi-test--write 'add bad 'user root) :error)))
        (should (equal (drgnx-agent-config-kimi-test--text config) before-bad))
        ;; only the user scope has hooks
        (should (equal (mapcar #'car (drgnx-agent-config-scopes 'kimi 'hook root)) '(user)))
        (should (plist-get (drgnx-agent-config-kimi-test--write
                            'add (drgnx-agent-config-kimi-test--hook "Stop" nil "x") 'project root)
                           :error))))))

(ert-deftest drgnx-agent-config-kimi/hooks-in-a-form-drgnx-does-not-edit-are-read-only ()
  (drgnx-agent-config-test-env
    (let* ((config (concat (drgnx-agent-config-home 'kimi) "config.toml"))
           (text "hooks = [{event = \"Stop\", command = \"echo inline\"}]\n"))
      (drgnx-agent-config-kimi-test--put config text)
      (let* ((read (drgnx-agent-config-read 'kimi root))
             (hook (drgnx-agent-config-kimi-test--item (plist-get read :items) 'hook "Stop")))
        (should hook)
        (should (plist-get hook :readonly))
        (should (stringp (plist-get hook :reason)))
        (should (string-match-p "line 1" (plist-get hook :reason)))
        (let ((r (drgnx-agent-config-kimi-test--write 'add (drgnx-agent-config-kimi-test--hook "Notification" nil "x") 'user root)))
          (should (plist-get r :error)))
        (should (plist-get (drgnx-agent-config-kimi-test--write 'remove hook 'user root) :error))
        (should (equal (drgnx-agent-config-kimi-test--text config) text))
        (should-not (file-exists-p (concat config ".drgnx-bak"))))
      ;; a config.toml that does not parse is a problem with its line, and is never written
      (drgnx-agent-config-kimi-test--put config "default_model = \"m\"\nthis is not toml\n")
      (let ((read (drgnx-agent-config-read 'kimi root)))
        (should (equal (car (car (plist-get read :problems))) config))
        (should (= (cadr (car (plist-get read :problems))) 2))
        (should-not (drgnx-agent-config-kimi-test--names (plist-get read :items) 'hook)))
      (let ((r (drgnx-agent-config-kimi-test--write 'add (drgnx-agent-config-kimi-test--hook "Stop" nil "x") 'user root)))
        (should (plist-get r :error))
        (should (string-match-p "line 2" (plist-get r :error)))
        (should-not (string-match-p "default_model" (plist-get r :error))))
      (should (equal (drgnx-agent-config-kimi-test--text config) "default_model = \"m\"\nthis is not toml\n"))
      ;; no config.toml yet: an add makes it
      (delete-file config)
      (should (plist-get (drgnx-agent-config-kimi-test--write 'add (drgnx-agent-config-kimi-test--hook "Stop" nil "x") 'user root) :ok))
      (should (equal (drgnx-agent-config-kimi-test--text config) "[[hooks]]\nevent = \"Stop\"\ncommand = \"x\"\n")))))

(ert-deftest drgnx-agent-config-kimi/hook-edit-keeps-members-drgnx-does-not-model ()
  (drgnx-agent-config-test-env
    (let ((config (concat (drgnx-agent-config-home 'kimi) "config.toml")))
      (drgnx-agent-config-kimi-test--put
       config "[[hooks]]\nevent = \"Stop\"\ncommand = \"echo a\"\nfuture = \"keep me\"\ntimeout = 9\n")
      (let ((hook (drgnx-agent-config-kimi-test--item (plist-get (drgnx-agent-config-read 'kimi root) :items) 'hook "Stop")))
        (should (plist-get (drgnx-agent-config-kimi-test--write
                            'edit (drgnx-agent-config-kimi-test--hook "Stop" "Bash" "echo b" nil hook) 'user root)
                           :ok)))
      (let ((text (drgnx-agent-config-kimi-test--text config)))
        (should (string-match-p "future = \"keep me\"" text))
        (should (string-match-p "command = \"echo b\"" text))
        (should (string-match-p "matcher = \"Bash\"" text))
        (should-not (string-match-p "timeout" text))))))

(ert-deftest drgnx-agent-config-kimi/toml-errors-never-show-a-secret ()
  (drgnx-agent-config-test-env
    (let ((files (list (concat (drgnx-agent-config-home 'kimi) "config.toml") (concat home ".kimi/config.toml"))))
      (dolist (file files)
        (drgnx-agent-config-kimi-test--put file "default_model = \"m\"\napiKey = sk-SECRETTOKEN123\n"))
      (let ((read (drgnx-agent-config-read 'kimi root)))
        (should (= (length (plist-get read :problems)) 2))
        (dolist (problem (plist-get read :problems))
          (should (member (car problem) files))
          (should (= (cadr problem) 2))
          (should-not (string-match-p "SECRETTOKEN" (format "%S" problem)))))
      (let ((r (drgnx-agent-config-kimi-test--write 'add (drgnx-agent-config-kimi-test--hook "Stop" nil "x") 'user root)))
        (should (plist-get r :error))
        (should (string-match-p "line 2" (plist-get r :error)))
        (should-not (string-match-p "SECRETTOKEN" (plist-get r :error)))))))

;;;; Skills, plugins, rules, routes

(ert-deftest drgnx-agent-config-kimi/skills-from-both-places-and-no-off-switch ()
  (drgnx-agent-config-test-env
    (let ((kimi-home (drgnx-agent-config-home 'kimi)))
      (drgnx-agent-config-kimi-test--put (concat kimi-home "skills/alpha/SKILL.md") "---\nname: alpha\ndescription: Alpha skill\n---\nBody\n")
      (drgnx-agent-config-kimi-test--put (concat home ".agents/skills/shared/SKILL.md") "---\nname: shared\ndescription: Shared\n---\n")
      (drgnx-agent-config-kimi-test--put (concat root ".kimi-code/skills/beta/SKILL.md") "---\nname: beta\ndescription: Beta skill\n---\n")
      (drgnx-agent-config-kimi-test--put (concat root ".agents/skills/gamma/SKILL.md") "---\nname: gamma\ndescription: Gamma\n---\n")
      (let* ((items (plist-get (drgnx-agent-config-read 'kimi root) :items))
             (alpha (drgnx-agent-config-kimi-test--item items 'skill "alpha")))
        (should (equal (drgnx-agent-config-kimi-test--names items 'skill) '("alpha" "beta" "gamma" "shared")))
        (should (eq (plist-get alpha :from) 'user))
        (should (equal (plist-get (plist-get alpha :spec) :description) "Alpha skill"))
        (should (eq (plist-get (drgnx-agent-config-kimi-test--item items 'skill "beta") :from) 'project))
        (should (eq (plist-get (drgnx-agent-config-kimi-test--item items 'skill "gamma") :from) 'project))
        (should (plist-get alpha :enabled))
        ;; Kimi Code's format has no way to turn a skill off
        (let ((r (drgnx-agent-config-kimi-test--write 'toggle alpha nil root)))
          (should (plist-get r :error))
          (should (string-match-p "no setting\\|cannot" (plist-get r :error)))))
      (should (equal (mapcar #'car (drgnx-agent-config-scopes 'kimi 'skill root)) '(user project)))
      (should (equal (caddr (assq 'project (drgnx-agent-config-scopes 'kimi 'skill root))) (concat root ".kimi-code/skills")))
      (should (plist-get (drgnx-agent-config-kimi-test--write
                          'add (list :section 'skill :name "fresh" :spec '(:description "Fresh one")) 'project root)
                         :ok))
      (should (file-exists-p (concat root ".kimi-code/skills/fresh/SKILL.md")))
      (should (plist-get (drgnx-agent-config-kimi-test--write
                          'add (list :section 'skill :name "mine" :spec '(:description "Mine")) 'user root)
                         :ok))
      (should (file-exists-p (concat kimi-home "skills/mine/SKILL.md"))))))

(ert-deftest drgnx-agent-config-kimi/plugin-items-are-read-only ()
  (drgnx-agent-config-test-env
    (let* ((kimi-home (drgnx-agent-config-home 'kimi))
           (plug (concat kimi-home "plugins/store/tools/"))
           (off (concat kimi-home "plugins/store/off/")))
      (drgnx-agent-config-kimi-test--put
       (concat kimi-home "plugins/installed.json")
       (format "{\"version\": 1, \"plugins\": [{\"id\": \"tools\", \"root\": \"%s\", \"enabled\": true},
 {\"id\": \"off\", \"root\": \"%s\", \"enabled\": false}]}" (directory-file-name plug) (directory-file-name off)))
      (drgnx-agent-config-kimi-test--put
       (concat plug "kimi.plugin.json")
       "{\"name\": \"tools\", \"mcpServers\": {\"srv\": {\"command\": \"plugsrv\"}},
 \"hooks\": [{\"event\": \"Stop\", \"command\": \"echo plug\"}], \"skills\": \"skills\"}")
      (drgnx-agent-config-kimi-test--put (concat plug "skills/ps/SKILL.md") "---\nname: ps\ndescription: Plugin skill\n---\n")
      (drgnx-agent-config-kimi-test--put (concat off "kimi.plugin.json")
                                         "{\"name\": \"off\", \"mcpServers\": {\"ghost\": {\"command\": \"g\"}}}")
      (let* ((items (plist-get (drgnx-agent-config-read 'kimi root) :items))
             (srv (drgnx-agent-config-kimi-test--item items 'mcp "plugin-tools:srv")))
        (should (equal (drgnx-agent-config-kimi-test--names items 'mcp 'plugin) '("plugin-tools:srv")))
        (should (plist-get srv :readonly))
        (should (eq (plist-get srv :from) 'plugin))
        (should (equal (drgnx-agent-config-kimi-test--names items 'hook 'plugin) '("Stop")))
        (should (plist-get (drgnx-agent-config-kimi-test--item items 'hook "Stop") :readonly))
        (should (equal (drgnx-agent-config-kimi-test--names items 'skill 'plugin) '("tools:ps")))
        (should (plist-get (drgnx-agent-config-kimi-test--item items 'skill "tools:ps") :readonly))
        (let ((before (drgnx-agent-config-kimi-test--text (concat plug "kimi.plugin.json"))))
          (dolist (op '(edit remove toggle))
            (should (plist-get (drgnx-agent-config-kimi-test--write op srv 'user root) :error)))
          (should (plist-get (drgnx-agent-config-kimi-test--write
                              'remove (drgnx-agent-config-kimi-test--item items 'hook "Stop") 'user root)
                             :error))
          (should (equal (drgnx-agent-config-kimi-test--text (concat plug "kimi.plugin.json")) before)))))))

(ert-deftest drgnx-agent-config-kimi/rules-and-route ()
  (drgnx-agent-config-test-env
    (let ((kimi-home (drgnx-agent-config-home 'kimi)))
      (should-not (plist-get (drgnx-agent-config-read 'kimi root) :rules))
      (drgnx-agent-config-kimi-test--put (concat kimi-home "AGENTS.md") "user\n")
      (drgnx-agent-config-kimi-test--put (concat root "AGENTS.md") "project\n")
      (drgnx-agent-config-kimi-test--put (concat root ".kimi-code/AGENTS.md") "kimi project\n")
      (let ((read (drgnx-agent-config-read 'kimi root)))
        (should (equal (plist-get read :rules)
                       (list (concat kimi-home "AGENTS.md") (concat root ".kimi-code/AGENTS.md") (concat root "AGENTS.md"))))
        (let ((route (car (plist-get read :routes))))
          (should (= (length (plist-get read :routes)) 1))
          (should (eq (plist-get route :billing) 'subscription))
          (should (string-match-p "kimi login" (plist-get route :key-where))))))))

;;;; The old kimi-cli directory

(ert-deftest drgnx-agent-config-kimi/legacy-dir-is-read-only ()
  (drgnx-agent-config-test-env
    (let* ((old (concat home ".kimi/"))
           (mcp (concat old "mcp.json"))
           (config (concat old "config.toml")))
      (drgnx-agent-config-kimi-test--put mcp "{\"mcpServers\": {\"old-srv\": {\"command\": \"oldcmd\"}}}\n")
      (drgnx-agent-config-kimi-test--put config "[[hooks]]\nevent = \"Stop\"\ncommand = \"echo old\"\n")
      (drgnx-agent-config-kimi-test--put (concat old "skills/oldskill/SKILL.md") "---\nname: oldskill\ndescription: Old\n---\n")
      (drgnx-agent-config-kimi-test--put (concat old "credentials/token.json") "CANARY")
      (let* ((read (drgnx-agent-config-read 'kimi root))
             (items (plist-get read :items))
             (legacy (cl-remove-if-not (lambda (i) (eq (plist-get i :from) 'legacy)) items)))
        (should (equal (drgnx-agent-config-kimi-test--names legacy 'mcp) '("old-srv")))
        (should (equal (drgnx-agent-config-kimi-test--names legacy 'hook) '("Stop")))
        (should (equal (drgnx-agent-config-kimi-test--names legacy 'skill) '("oldskill")))
        (should (= (length legacy) 3))
        (should (cl-every (lambda (i) (plist-get i :readonly)) legacy))
        (should (equal (plist-get (car legacy) :file) mcp))
        (should (member "the old kimi-cli's config: kimi-code migrates from it; drgnx does not edit it"
                        (plist-get read :notes)))
        ;; no write goes there, whatever the scope or operation
        (let ((snapshot (mapcar #'drgnx-agent-config-kimi-test--text (list mcp config))))
          (dolist (item legacy)
            (dolist (op '(edit remove toggle))
              (dolist (scope '(user project nil))
                (should (plist-get (drgnx-agent-config-kimi-test--write op item scope root) :error)))))
          (should (equal (mapcar #'drgnx-agent-config-kimi-test--text (list mcp config)) snapshot))
          (should-not (file-exists-p (concat mcp ".drgnx-bak")))
          (should-not (file-exists-p (concat config ".drgnx-bak")))))
      ;; no legacy directory: no note, no legacy items
      (delete-directory old t)
      (let ((read (drgnx-agent-config-read 'kimi root)))
        (should-not (plist-get read :notes))
        (should-not (cl-some (lambda (i) (eq (plist-get i :from) 'legacy)) (plist-get read :items))))
      ;; KIMI_CODE_HOME set to the old directory itself: it is the live one, not legacy
      (drgnx-agent-config-kimi-test--put mcp "{\"mcpServers\": {\"live\": {\"command\": \"c\"}}}\n")
      (let* ((process-environment (cons (concat "KIMI_CODE_HOME=" (directory-file-name old)) process-environment))
             (read (drgnx-agent-config-read 'kimi root)))
        (should (equal (mapcar (lambda (i) (plist-get i :from)) (plist-get read :items)) '(user)))
        (should-not (plist-get read :notes))))))

(ert-deftest drgnx-agent-config-kimi/never-opens-credentials ()
  (drgnx-agent-config-test-env
    (let* ((kimi-home (drgnx-agent-config-home 'kimi))
           (old (concat home ".kimi/"))
           (touched nil)
           (record (lambda (orig file &rest args) (push (expand-file-name file) touched) (apply orig file args))))
      (dolist (dir (list kimi-home old))
        (drgnx-agent-config-kimi-test--put (concat dir "credentials/token.json") "{\"access_token\": \"CANARY\"}")
        (drgnx-agent-config-kimi-test--put (concat dir "credentials/nested/key") "CANARY"))
      (drgnx-agent-config-kimi-test--put (concat kimi-home "mcp.json") "{\"mcpServers\": {\"a\": {\"command\": \"x\"}}}\n")
      (drgnx-agent-config-kimi-test--put (concat kimi-home "config.toml") "default_model = \"m\"\n")
      (drgnx-agent-config-kimi-test--put (concat kimi-home "skills/alpha/SKILL.md") "---\nname: alpha\n---\n")
      (drgnx-agent-config-kimi-test--put (concat old "mcp.json") "{}\n")
      (dolist (fn '(insert-file-contents insert-file-contents-literally file-attributes file-modes file-regular-p
                                         file-directory-p directory-files directory-files-recursively file-truename copy-file rename-file
                                         delete-file delete-directory))
        (advice-add fn :around record))
      (unwind-protect
          (progn
            (drgnx-agent-config-read 'kimi root)
            (drgnx-agent-config-kimi-test--write 'add (drgnx-agent-config-kimi-test--hook "Stop" nil "echo x") 'user root)
            (drgnx-agent-config-kimi-test--write
             'add (drgnx-agent-config-kimi-test--mcp "s" '(:command "x" :env (("API_KEY" . "abcd1234")))) 'user root)
            (drgnx-agent-config-kimi-test--write
             'add (list :section 'skill :name "n" :spec '(:description "d")) 'user root)
            (drgnx-agent-config-read 'kimi nil))
        (dolist (fn '(insert-file-contents insert-file-contents-literally file-attributes file-modes file-regular-p
                                           file-directory-p directory-files directory-files-recursively file-truename copy-file rename-file
                                           delete-file delete-directory))
          (advice-remove fn record)))
      (should touched)
      (should-not (cl-some (lambda (f) (string-match-p "credentials" f)) touched))
      (should (cl-some (lambda (f) (string-suffix-p "mcp.json" f)) touched))
      (should (cl-some (lambda (f) (string-suffix-p "config.toml" f)) touched))
      (should (equal (drgnx-agent-config-kimi-test--text (concat kimi-home "credentials/token.json"))
                     "{\"access_token\": \"CANARY\"}")))))

(provide 'agent-config-kimi-test)
;;; agent-config-kimi-test.el ends here
