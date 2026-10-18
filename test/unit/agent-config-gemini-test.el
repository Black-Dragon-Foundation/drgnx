;;; agent-config-gemini-test.el --- batch tests: Gemini CLI's settings (MCP servers, hooks, skills, extensions) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-agent-config-gemini)
(load (expand-file-name "test/fixtures/agent-config-fixture" drgnx-dir) nil t)

(defmacro drgnx-agent-config-gemini-test-env (&rest body)
  "BODY in the agent settings fixture, with the system settings files in a temp dir (bound to `system')."
  (declare (indent 0))
  `(drgnx-agent-config-test-env
     (let* ((system (expand-file-name "system/" drgnx-agent-config-test--dir))
            (process-environment
             (append (list (concat "GEMINI_CLI_SYSTEM_SETTINGS_PATH=" (expand-file-name "settings.json" system))
                           (concat "GEMINI_CLI_SYSTEM_DEFAULTS_PATH=" (expand-file-name "system-defaults.json" system)))
                     process-environment)))
       (ignore system)
       ,@body)))

(defun drgnx-agent-config-gemini-test--put (file text)
  "Write TEXT to FILE (making its directory); return FILE."
  (make-directory (file-name-directory file) t)
  (write-region text nil file nil 'silent)
  file)

(defun drgnx-agent-config-gemini-test--text (file)
  "The text of FILE."
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defun drgnx-agent-config-gemini-test--value (file)
  "The parsed JSON of FILE."
  (plist-get (drgnx-agent-config-json-read file) :value))

(defun drgnx-agent-config-gemini-test--item (items section name)
  "The item of SECTION called NAME."
  (cl-find-if (lambda (i) (and (eq (plist-get i :section) section) (equal (plist-get i :name) name))) items))

(defun drgnx-agent-config-gemini-test--names (items section)
  "The names of the SECTION items."
  (sort (mapcar (lambda (i) (plist-get i :name))
                (cl-remove-if-not (lambda (i) (eq (plist-get i :section) section)) items))
        #'string<))

(defun drgnx-agent-config-gemini-test--read (root)
  "The items Gemini has for ROOT."
  (plist-get (drgnx-agent-config-read 'gemini root) :items))

(defun drgnx-agent-config-gemini-test--write (op item scope root)
  "Run the write; return what the callback got."
  (let ((result nil))
    (drgnx-agent-config-write 'gemini op item scope root (lambda (r) (setq result r)))
    (or result (error "The write never called back"))))

(defun drgnx-agent-config-gemini-test--user-file ()
  "The user's settings file."
  (expand-file-name "settings.json" (drgnx-agent-config-home 'gemini)))

;;;; Reading

(ert-deftest drgnx-agent-config-gemini/reads-settings-and-extensions ()
  (drgnx-agent-config-gemini-test-env
    (let* ((gemini-home (drgnx-agent-config-home 'gemini))
           (user (drgnx-agent-config-gemini-test--user-file))
           (project (expand-file-name ".gemini/settings.json" root))
           (ext (expand-file-name "extensions/demo/" gemini-home)))
      (should (equal gemini-home (concat drgnx-agent-config-test--dir "gemini/.gemini/")))
      (drgnx-agent-config-gemini-test--put
       user (concat "{\n  \"mcpServers\": {\n"
                    "    \"u-stdio\": {\"command\": \"npx\", \"args\": [\"-y\", \"pkg\"], \"env\": {\"A\": \"b\"}, \"cwd\": \"/x\"},\n"
                    "    \"u-sse\": {\"url\": \"https://example.com/sse\", \"type\": \"sse\", \"headers\": {\"X-Id\": \"7\"}},\n"
                    "    \"u-legacy\": {\"httpUrl\": \"https://example.com/mcp\"},\n"
                    "    \"u-bare\": {\"url\": \"https://example.com/bare\"}\n  },\n"
                    "  \"hooks\": {\"BeforeTool\": [{\"matcher\": \"read_.*\", \"hooks\": [{\"type\": \"command\","
                    " \"command\": \"echo user\", \"name\": \"audit\", \"timeout\": 5000}]}]},\n"
                    "  \"hooksConfig\": {\"disabled\": [\"audit\"]},\n"
                    "  \"skills\": {\"disabled\": [\"beta\"]},\n"
                    "  \"context\": {\"fileName\": [\"AGENTS.md\", \"GEMINI.md\"]}\n}\n"))
      (drgnx-agent-config-gemini-test--put
       project "{\"mcpServers\": {\"p-srv\": {\"command\": \"proj\"}},\n \"hooks\": {\"SessionStart\": [{\"hooks\": [{\"type\": \"command\", \"command\": \"echo proj\"}]}]}}")
      (drgnx-agent-config-gemini-test--put
       (expand-file-name "settings.json" system) "{\"mcpServers\": {\"s-srv\": {\"command\": \"sysd\"}}}")
      (drgnx-agent-config-gemini-test--put
       (expand-file-name "gemini-extension.json" ext)
       "{\"name\": \"demo\", \"version\": \"1\", \"mcpServers\": {\"e-srv\": {\"command\": \"ext-server\"}}}")
      (drgnx-agent-config-gemini-test--put
       (expand-file-name "hooks/hooks.json" ext)
       "{\"hooks\": {\"AfterTool\": [{\"hooks\": [{\"type\": \"command\", \"command\": \"echo ext\"}]}]}}")
      (drgnx-agent-config-gemini-test--put (expand-file-name "skills/gamma/SKILL.md" ext)
                                           "---\nname: gamma\ndescription: From an extension\n---\n")
      (dolist (dir (list (expand-file-name "skills" gemini-home)
                         (expand-file-name ".agents/skills" (concat drgnx-agent-config-test--dir "gemini"))
                         (expand-file-name ".gemini/skills" root)
                         (expand-file-name ".agents/skills" root)))
        (let ((name (if (string-match-p "/\\.agents/skills\\'" dir)
                        (if (string-prefix-p root dir) "delta" "beta")
                      (if (string-prefix-p root dir) "epsilon" "alpha"))))
          (drgnx-agent-config-gemini-test--put (expand-file-name (concat name "/SKILL.md") dir)
                                               (format "---\nname: %s\ndescription: The %s skill\n---\n" name name))))
      (drgnx-agent-config-gemini-test--put (expand-file-name "GEMINI.md" gemini-home) "user rules\n")
      (drgnx-agent-config-gemini-test--put (expand-file-name "AGENTS.md" root) "project rules\n")
      (let* ((read (drgnx-agent-config-read 'gemini root))
             (items (plist-get read :items)))
        (should-not (plist-get read :problems))
        (should-not (plist-get read :notes))
        (should (equal (drgnx-agent-config-gemini-test--names items 'mcp)
                       '("extension:demo:e-srv" "p-srv" "s-srv" "u-bare" "u-legacy" "u-sse" "u-stdio")))
        (let ((u (drgnx-agent-config-gemini-test--item items 'mcp "u-stdio")))
          (should (eq (plist-get u :from) 'user))
          (should (equal (plist-get u :file) user))
          (should-not (plist-get u :readonly))
          (should (= (plist-get u :line) 3))
          (should (equal (plist-get u :spec)
                         '(:type stdio :command "npx" :args ("-y" "pkg") :env (("A" . "b")) :url nil :headers nil))))
        (let ((s (drgnx-agent-config-gemini-test--item items 'mcp "u-sse")))
          (should (eq (plist-get (plist-get s :spec) :type) 'sse))
          (should (equal (plist-get (plist-get s :spec) :url) "https://example.com/sse"))
          (should (equal (plist-get (plist-get s :spec) :headers) '(("X-Id" . "7")))))
        (should (eq (plist-get (plist-get (drgnx-agent-config-gemini-test--item items 'mcp "u-legacy") :spec) :type) 'http))
        (should (equal (plist-get (plist-get (drgnx-agent-config-gemini-test--item items 'mcp "u-legacy") :spec) :url)
                       "https://example.com/mcp"))
        (should (eq (plist-get (plist-get (drgnx-agent-config-gemini-test--item items 'mcp "u-bare") :spec) :type) 'http))
        (let ((p (drgnx-agent-config-gemini-test--item items 'mcp "p-srv")))
          (should (eq (plist-get p :from) 'project))
          (should (equal (plist-get p :file) project)))
        (let ((s (drgnx-agent-config-gemini-test--item items 'mcp "s-srv")))
          (should (eq (plist-get s :from) 'system))
          (should (plist-get s :readonly)))
        (let ((e (drgnx-agent-config-gemini-test--item items 'mcp "extension:demo:e-srv")))
          (should (eq (plist-get e :from) 'extension))
          (should (equal (plist-get e :file) (expand-file-name "gemini-extension.json" ext)))
          (should (plist-get e :enabled)))
        ;; hooks: user (off by name in hooksConfig.disabled), project, extension
        (let ((hooks (cl-remove-if-not (lambda (i) (eq (plist-get i :section) 'hook)) items)))
          (should (equal (mapcar (lambda (i) (cons (plist-get i :from) (plist-get (plist-get i :spec) :command))) hooks)
                         '((user . "echo user") (project . "echo proj") (extension . "echo ext"))))
          (let ((h (car hooks)))
            (should (equal (plist-get h :name) "BeforeTool read_.*"))
            (should (= (plist-get (plist-get h :spec) :timeout) 5000))
            (should (eq (plist-get (plist-get h :spec) :timeout-unit) 'ms))
            (should-not (plist-get h :enabled))
            (should-not (plist-get h :readonly)))
          (should (plist-get (nth 1 hooks) :enabled))
          (should (plist-get (nth 2 hooks) :readonly)))
        ;; skills: the four directories and the extension's; beta is off by skills.disabled
        (should (equal (mapcar (lambda (i) (list (plist-get i :name) (plist-get i :from) (plist-get i :enabled)))
                               (cl-remove-if-not (lambda (i) (eq (plist-get i :section) 'skill)) items))
                       '(("alpha" user t) ("beta" user nil) ("epsilon" project t) ("delta" project t) ("gamma" extension t))))
        (should (plist-get (drgnx-agent-config-gemini-test--item items 'skill "gamma") :readonly))
        ;; rules follow context.fileName; routes: the Google login
        (should (equal (plist-get read :rules)
                       (list (expand-file-name "GEMINI.md" gemini-home) (expand-file-name "AGENTS.md" root))))
        (should (eq (plist-get (car (plist-get read :routes)) :billing) 'subscription))
        ;; without a project only the user's and the system's
        (should (equal (drgnx-agent-config-gemini-test--names (drgnx-agent-config-gemini-test--read nil) 'mcp)
                       '("extension:demo:e-srv" "s-srv" "u-bare" "u-legacy" "u-sse" "u-stdio")))))))

(ert-deftest drgnx-agent-config-gemini/scopes-name-the-files ()
  (drgnx-agent-config-gemini-test-env
    (let ((gemini-home (drgnx-agent-config-home 'gemini)))
      (dolist (section '(mcp hook))
        (should (equal (mapcar (lambda (s) (list (nth 0 s) (nth 2 s))) (drgnx-agent-config-scopes 'gemini section root))
                       (list (list 'user (expand-file-name "settings.json" gemini-home))
                             (list 'project (expand-file-name ".gemini/settings.json" root))))))
      (should (equal (mapcar (lambda (s) (list (nth 0 s) (nth 2 s))) (drgnx-agent-config-scopes 'gemini 'skill root))
                     (list (list 'user (expand-file-name "skills" gemini-home))
                           (list 'project (expand-file-name ".gemini/skills" root)))))
      (should (equal (mapcar #'car (drgnx-agent-config-scopes 'gemini 'mcp nil)) '(user))))))

(ert-deftest drgnx-agent-config-gemini/commented-settings-are-read-and-shown-read-only ()
  (drgnx-agent-config-gemini-test-env
    (let* ((user (drgnx-agent-config-gemini-test--user-file))
           (text (concat "{\n  // my servers: \"fake\": {}\n  \"mcpServers\": {\n"
                         "    /* the main one */ \"main\": {\"command\": \"srv\", \"args\": [\"//not-a-comment\"]}\n  }\n}\n")))
      (drgnx-agent-config-gemini-test--put user text)
      (let* ((read (drgnx-agent-config-read 'gemini root))
             (item (drgnx-agent-config-gemini-test--item (plist-get read :items) 'mcp "main")))
        (should-not (plist-get read :problems))
        (should (= (plist-get item :line) 4))
        (should (plist-get item :readonly))
        (should (equal (plist-get (plist-get item :spec) :args) '("//not-a-comment")))
        (should-not (drgnx-agent-config-gemini-test--item (plist-get read :items) 'mcp "fake"))
        (should (cl-some (lambda (n) (string-match-p "has comments" n)) (plist-get read :notes)))
        ;; the item refuses a write, and so does the file when asked directly
        (should (plist-get (drgnx-agent-config-gemini-test--write 'remove item 'user root) :error))
        (let ((result (drgnx-agent-config-gemini-test--write
                       'add (list :kind 'gemini :section 'mcp :name "new" :spec '(:command "x")) 'user root)))
          (should (string-match-p "has comments" (plist-get result :error))))
        (should (equal (drgnx-agent-config-gemini-test--text user) text))
        (should-not (file-exists-p (concat user ".drgnx-bak")))))))

(ert-deftest drgnx-agent-config-gemini/a-file-that-does-not-parse-is-a-problem ()
  (drgnx-agent-config-gemini-test-env
    (let ((user (drgnx-agent-config-gemini-test--user-file)))
      (drgnx-agent-config-gemini-test--put user "{\n  \"mcpServers\": {},\n}\n")
      (let ((read (drgnx-agent-config-read 'gemini root)))
        (should (equal (car (plist-get read :problems)) (list user 2 "trailing comma")))
        (should-not (plist-get read :items))))))

;;;; Read-only items

(ert-deftest drgnx-agent-config-gemini/extension-items-are-read-only ()
  (drgnx-agent-config-gemini-test-env
    (let* ((gemini-home (drgnx-agent-config-home 'gemini))
           (ext (expand-file-name "extensions/demo/" gemini-home))
           (off (expand-file-name "extensions/off/" gemini-home))
           (sys (expand-file-name "settings.json" system))
           (manifest (expand-file-name "gemini-extension.json" ext)))
      (drgnx-agent-config-gemini-test--put manifest "{\"name\": \"demo\", \"mcpServers\": {\"e-srv\": {\"command\": \"x\"}}}")
      (drgnx-agent-config-gemini-test--put
       (expand-file-name "gemini-extension.json" off) "{\"name\": \"off\", \"mcpServers\": {\"o-srv\": {\"command\": \"y\"}}}")
      (drgnx-agent-config-gemini-test--put
       (expand-file-name "extensions/extension-enablement.json" gemini-home)
       (format "{\"off\": {\"overrides\": [\"!%s*\"]}, \"demo\": {\"overrides\": [\"!/\", \"%s*\"]}}"
               (file-name-as-directory (directory-file-name root)) root))
      (drgnx-agent-config-gemini-test--put sys "{\"mcpServers\": {\"s-srv\": {\"command\": \"sysd\"}}}")
      (let* ((items (drgnx-agent-config-gemini-test--read root))
             (e (drgnx-agent-config-gemini-test--item items 'mcp "extension:demo:e-srv"))
             (o (drgnx-agent-config-gemini-test--item items 'mcp "extension:off:o-srv"))
             (s (drgnx-agent-config-gemini-test--item items 'mcp "s-srv")))
        ;; the last matching rule wins: demo is on in this project; off is switched off for it
        (should (plist-get e :enabled))
        (should-not (plist-get o :enabled))
        (dolist (item (list e o s))
          (dolist (op '(edit remove))
            (let ((result (drgnx-agent-config-gemini-test--write op item 'user root)))
              (should (string-match-p "read-only" (plist-get result :error))))))
        (should-not (file-exists-p (drgnx-agent-config-gemini-test--user-file)))
        (should (equal (drgnx-agent-config-gemini-test--text sys)
                       "{\"mcpServers\": {\"s-srv\": {\"command\": \"sysd\"}}}"))
        (should (string-match-p "demo" (drgnx-agent-config-gemini-test--text manifest)))
        (should-not (file-exists-p (concat manifest ".drgnx-bak")))
        ;; elsewhere both are on
        (let ((other (drgnx-agent-config-gemini-test--item (drgnx-agent-config-gemini-test--read "/elsewhere/")
                                                           'mcp "extension:off:o-srv")))
          (should (plist-get other :enabled)))))))

;;;; Skills

(ert-deftest drgnx-agent-config-gemini/skill-off-writes-skills-disabled ()
  (drgnx-agent-config-gemini-test-env
    (let* ((user (drgnx-agent-config-gemini-test--user-file))
           (project (expand-file-name ".gemini/settings.json" root))
           (text (concat "{\n    \"theme\": \"dark\",\n    \"unknownThing\": {\"keep\": [1, 2]},\n"
                         "    \"skills\": {\"enabled\": true, \"disabled\": [\"other\"]}\n}\n")))
      (drgnx-agent-config-gemini-test--put user text)
      (drgnx-agent-config-gemini-test--put (expand-file-name ".gemini/skills/proj/SKILL.md" root)
                                           "---\nname: proj\ndescription: P\n---\n")
      (drgnx-agent-config-gemini-test--put (expand-file-name "skills/mine/SKILL.md" (drgnx-agent-config-home 'gemini))
                                           "---\nname: mine\ndescription: M\n---\n")
      (let ((mine (drgnx-agent-config-gemini-test--item (drgnx-agent-config-gemini-test--read root) 'skill "mine")))
        (should (plist-get mine :enabled))
        (should (plist-get (drgnx-agent-config-gemini-test--write 'toggle mine nil root) :ok))
        ;; only skills.disabled changed: order, indent and every other member stay
        (should (equal (drgnx-agent-config-gemini-test--text user)
                       (concat "{\n    \"theme\": \"dark\",\n    \"unknownThing\": {\n        \"keep\": [\n            1,\n            2\n        ]\n    },\n"
                               "    \"skills\": {\n        \"enabled\": true,\n        \"disabled\": [\n            \"other\",\n            \"mine\"\n        ]\n    }\n}\n")))
        (should (file-exists-p (concat user ".drgnx-bak")))
        (let ((now (drgnx-agent-config-gemini-test--item (drgnx-agent-config-gemini-test--read root) 'skill "mine")))
          (should-not (plist-get now :enabled))
          ;; a second off does not repeat the name
          (drgnx-agent-config-gemini-test--write 'toggle (plist-put (copy-sequence now) :enabled t) nil root)
          (should (equal (append (cdr (assq 'disabled (cdr (assq 'skills (drgnx-agent-config-gemini-test--value user))))) nil)
                         '("other" "mine")))
          ;; on removes it from every file that lists it, and only it
          (drgnx-agent-config-gemini-test--put project "{\"skills\": {\"disabled\": [\"mine\"]}}")
          (should (plist-get (drgnx-agent-config-gemini-test--write 'toggle now nil root) :ok))
          (should (equal (append (cdr (assq 'disabled (cdr (assq 'skills (drgnx-agent-config-gemini-test--value user))))) nil)
                         '("other")))
          (should (equal (drgnx-agent-config-gemini-test--value project) nil))
          (should (plist-get (drgnx-agent-config-gemini-test--item (drgnx-agent-config-gemini-test--read root) 'skill "mine")
                             :enabled)))
        ;; a skill switched off by the system settings stays off, with a reason
        (drgnx-agent-config-gemini-test--put (expand-file-name "settings.json" system)
                                             "{\"skills\": {\"disabled\": [\"proj\"]}}")
        (let* ((proj (drgnx-agent-config-gemini-test--item (drgnx-agent-config-gemini-test--read root) 'skill "proj"))
               (result (drgnx-agent-config-gemini-test--write 'toggle proj nil root)))
          (should-not (plist-get proj :enabled))
          (should (string-match-p "system settings" (plist-get result :error))))
        ;; a new skill goes to the chosen directory
        (should (plist-get (drgnx-agent-config-gemini-test--write
                            'add (list :kind 'gemini :section 'skill :name "fresh" :spec '(:description "New one")) 'project root)
                           :ok))
        (should (file-exists-p (expand-file-name ".gemini/skills/fresh/SKILL.md" root)))))))

;;;; MCP servers and hooks

(ert-deftest drgnx-agent-config-gemini/mcp-and-hooks-written-in-the-chosen-file ()
  (drgnx-agent-config-gemini-test-env
    (let* ((user (drgnx-agent-config-gemini-test--user-file))
           (project (expand-file-name ".gemini/settings.json" root))
           (user-text "{\n  \"theme\": \"dark\",\n  \"mcpServers\": {\"keep\": {\"command\": \"k\"}}\n}\n"))
      (drgnx-agent-config-gemini-test--put user user-text)
      ;; add a server, a stdio one with a secret, and an http one, to the project file (made on the way)
      (should (plist-get (drgnx-agent-config-gemini-test--write
                          'add (list :kind 'gemini :section 'mcp :name "alpha"
                                     :spec '(:type stdio :command "node" :args ("a.js") :env (("API_TOKEN" . "tok-secret-1"))))
                          'project root)
                         :ok))
      (should (plist-get (drgnx-agent-config-gemini-test--write
                          'add (list :kind 'gemini :section 'mcp :name "web" :spec '(:type http :url "https://example.com/mcp"
                                                                                           :headers (("X-A" . "1"))))
                          'project root)
                         :ok))
      (should (equal (drgnx-agent-config-gemini-test--text user) user-text))
      (should (equal (drgnx-agent-config-gemini-test--text project)
                     (concat "{\n  \"mcpServers\": {\n    \"alpha\": {\n      \"command\": \"node\",\n      \"args\": [\n        \"a.js\"\n      ],\n"
                             "      \"env\": {\n        \"API_TOKEN\": \"tok-secret-1\"\n      }\n    },\n"
                             "    \"web\": {\n      \"url\": \"https://example.com/mcp\",\n      \"type\": \"http\",\n"
                             "      \"headers\": {\n        \"X-A\": \"1\"\n      }\n    }\n  }\n}\n")))
      (should (string-match-p "already in this file"
                              (plist-get (drgnx-agent-config-gemini-test--write
                                          'add (list :kind 'gemini :section 'mcp :name "alpha" :spec '(:command "x")) 'project root)
                                         :error)))
      ;; an underscore is refused, and an error never shows the data
      (let ((result (drgnx-agent-config-gemini-test--write
                     'add (list :kind 'gemini :section 'mcp :name "bad_name"
                                :spec '(:command "x" :env (("API_TOKEN" . "tok-secret-2"))))
                     'user root)))
        (should (string-match-p "underscore" (plist-get result :error)))
        (should-not (string-match-p "tok-secret" (plist-get result :error))))
      (should (equal (drgnx-agent-config-gemini-test--text user) user-text))
      ;; an edit keeps the members drgnx does not model, wherever they are; a rename keeps the place
      (drgnx-agent-config-gemini-test--put
       user (concat "{\n  \"mcpServers\": {\n    \"first\": {\"command\": \"f\"},\n"
                    "    \"srv\": {\"cwd\": \"/w\", \"command\": \"old\", \"trust\": true, \"timeout\": 9, \"description\": \"d\","
                    " \"includeTools\": [\"a\"], \"oauth\": {\"enabled\": true}, \"futureKey\": {\"x\": 1}},\n"
                    "    \"last\": {\"command\": \"l\"}\n  }\n}\n"))
      (let ((old (drgnx-agent-config-gemini-test--item (drgnx-agent-config-gemini-test--read root) 'mcp "srv")))
        (should (plist-get (drgnx-agent-config-gemini-test--write
                            'edit (list :kind 'gemini :section 'mcp :name "renamed" :replaces old
                                        :spec '(:type sse :url "https://example.com/sse"))
                            'user root)
                           :ok)))
      (let* ((servers (cdr (assq 'mcpServers (drgnx-agent-config-gemini-test--value user))))
             (entry (cdr (assq 'renamed servers))))
        (should (equal (mapcar #'car servers) '(first renamed last)))
        (should (equal (mapcar #'car entry) '(cwd trust timeout description includeTools oauth futureKey url type)))
        (should (equal (cdr (assq 'url entry)) "https://example.com/sse"))
        (should (equal (cdr (assq 'type entry)) "sse"))
        (should (eq (cdr (assq 'trust entry)) t))
        (should (equal (cdr (assq 'futureKey entry)) '((x . 1)))))
      ;; remove
      (let ((item (drgnx-agent-config-gemini-test--item (drgnx-agent-config-gemini-test--read root) 'mcp "renamed")))
        (should (plist-get (drgnx-agent-config-gemini-test--write 'remove item 'user root) :ok))
        (should (equal (mapcar #'car (cdr (assq 'mcpServers (drgnx-agent-config-gemini-test--value user)))) '(first last)))
        (should (file-exists-p (concat user ".drgnx-bak"))))
      ;; hooks: add to the user file, edit in place (name and description stay), move, remove
      (drgnx-agent-config-gemini-test--put
       user (concat "{\n  \"hooks\": {\"BeforeTool\": [{\"matcher\": \"a\", \"sequential\": true, \"hooks\": ["
                    "{\"type\": \"command\", \"command\": \"one\", \"name\": \"first\", \"description\": \"keep me\", \"timeout\": 100},"
                    "{\"type\": \"command\", \"command\": \"two\"}]}]},\n  \"other\": 1\n}\n"))
      (let ((hook (lambda (event matcher command &optional replaces)
                    (list :kind 'gemini :section 'hook :name event :replaces replaces
                          :spec (list :event event :matcher matcher :command command)))))
        (should (plist-get (drgnx-agent-config-gemini-test--write
                            'add (funcall hook "AfterTool" "write_file" "echo after") 'user root)
                           :ok))
        (let ((old (drgnx-agent-config-gemini-test--item (drgnx-agent-config-gemini-test--read root) 'hook "BeforeTool a")))
          (should (equal (plist-get (plist-get old :spec) :command) "one"))
          (should (plist-get (drgnx-agent-config-gemini-test--write
                              'edit (funcall hook "BeforeTool" "a" "one-changed" old) 'user root)
                             :ok))
          (let* ((value (drgnx-agent-config-gemini-test--value user))
                 (group (aref (cdr (assq 'BeforeTool (cdr (assq 'hooks value)))) 0))
                 (first (aref (cdr (assq 'hooks group)) 0)))
            (should (eq (cdr (assq 'sequential group)) t))
            (should (equal first '((type . "command") (command . "one-changed") (name . "first")
                                   (description . "keep me"))))
            (should (equal (cdr (assq 'other value)) 1))
            (should (equal (cdr (assq 'command (aref (cdr (assq 'hooks group)) 1))) "two"))
            (should (equal (mapcar #'car (cdr (assq 'hooks value))) '(BeforeTool AfterTool)))))
        ;; moving to another event takes the hook with its name and description
        (let ((old (drgnx-agent-config-gemini-test--item (drgnx-agent-config-gemini-test--read root) 'hook "BeforeTool a")))
          (should (plist-get (drgnx-agent-config-gemini-test--write
                              'edit (funcall hook "SessionStart" nil "one-changed" old) 'user root)
                             :ok))
          (let* ((hooks (cdr (assq 'hooks (drgnx-agent-config-gemini-test--value user))))
                 (moved (aref (cdr (assq 'hooks (aref (cdr (assq 'SessionStart hooks)) 0))) 0)))
            (should (equal (cdr (assq 'name moved)) "first"))
            (should (equal (cdr (assq 'description moved)) "keep me"))))
        ;; an event Gemini does not know is refused; removing the last hooks leaves no empty `hooks'
        (should (string-match-p "events" (plist-get (drgnx-agent-config-gemini-test--write
                                                     'add (funcall hook "Stop" nil "x") 'user root)
                                                    :error)))
        (dolist (item (cl-remove-if-not (lambda (i) (eq (plist-get i :section) 'hook))
                                        (drgnx-agent-config-gemini-test--read root)))
          (should (plist-get (drgnx-agent-config-gemini-test--write 'remove item 'user root) :ok)))
        (should (equal (drgnx-agent-config-gemini-test--value user) '((other . 1))))
        ;; the project file was only written by the first part
        (should (string-match-p "alpha" (drgnx-agent-config-gemini-test--text project)))))))

(ert-deftest drgnx-agent-config-gemini/a-changed-file-is-not-overwritten ()
  (drgnx-agent-config-gemini-test-env
    (let ((user (drgnx-agent-config-gemini-test--user-file)))
      (drgnx-agent-config-gemini-test--put user "{\"mcpServers\": {\"a\": {\"command\": \"a\"}}}")
      (cl-letf* ((real (symbol-function 'drgnx-agent-config-json-write))
                 ((symbol-function 'drgnx-agent-config-json-write)
                  (lambda (file value indent &optional expect)
                    ;; someone else writes between our read and our write
                    (drgnx-agent-config-gemini-test--put file "{\"mcpServers\": {\"theirs\": {\"command\": \"t\"}}}")
                    (funcall real file value indent expect))))
        (let ((result (drgnx-agent-config-gemini-test--write
                       'add (list :kind 'gemini :section 'mcp :name "mine" :spec '(:command "m")) 'user root)))
          (should (string-match-p "changed by another program" (plist-get result :error)))
          (should (string-match-p "theirs" (drgnx-agent-config-gemini-test--text user)))
          (should-not (string-match-p "mine" (drgnx-agent-config-gemini-test--text user))))))))

(provide 'agent-config-gemini-test)
;;; agent-config-gemini-test.el ends here
