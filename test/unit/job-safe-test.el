;;; job-safe-test.el --- batch tests: only job-safe profiles run job agents; MCP resources; a profile's MCP servers -*- lexical-binding: t -*-
;; A job's agent works unwatched in a repository drgnx did not write: only a profile whose agent drgnx can stop from
;; reading that repository's own settings (Claude Code, through the lock of agents-claude-options-test.el) may run
;; one.  No real agent runs: the mock agents of job-fixture.el, and profiles that are only read.
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/job-fixture" drgnx-dir) nil t)   ; a repo, the hub, mock agents

(defmacro drgnx-job-safe-test--with (&rest body)
  "BODY with no agents.eld (a temporary config dir), no profiles of the user's Lisp, on Linux."
  (declare (indent 0))
  `(let* ((root (make-temp-file "drgnx-job-safe" t))
          (process-environment (cons (concat "DRGNX_CONFIG_DIR=" root) process-environment))
          (drgnx-agents-profiles nil) (system-type 'gnu/linux))
     (unwind-protect (progn ,@body) (delete-directory root t))))

(defun drgnx-job-safe-test--adapter (root)
  "A fake global npm prefix in ROOT with Claude Code's adapter package (its program never runs): its bin directory."
  (let* ((pkg (expand-file-name "prefix/lib/node_modules/@agentclientprotocol/claude-agent-acp/" root))
         (bin (expand-file-name "prefix/bin/" root)) (js (expand-file-name "dist/index.js" pkg)))
    (make-directory (file-name-directory js) t)
    (make-directory bin t)
    (write-region "{\"name\": \"@agentclientprotocol/claude-agent-acp\", \"version\": \"0.93.0\"}" nil
                  (expand-file-name "package.json" pkg) nil 'silent)
    (write-region "#!/bin/sh\n" nil js nil 'silent)
    (set-file-modes js #o755)
    (make-symbolic-link js (expand-file-name "claude-agent-acp" bin))
    bin))

(ert-deftest drgnx-job-safe/builtins-are-job-safe ()
  (drgnx-job-safe-test--with
    (dolist (p drgnx-agents-builtin-profiles)
      (should (plist-get (cdr p) :job-safe))
      (should (drgnx-job-safe-p (car p))))))

(ert-deftest drgnx-job-safe/a-user-profile-is-not ()
  (drgnx-job-safe-test--with
    (let ((drgnx-agents-profiles '(("mine" :command ("claude-agent-acp"))                    ; Claude, not said
                                   ("claude" :command ("claude-agent-acp" "--x"))            ; a built-in's name, redefined
                                   ("gem" :command ("gemini" "--experimental-acp") :job-safe t)   ; not Claude: no lock
                                   ("wrapped" :command ("my-agent") :job-safe t))))
      (should-not (drgnx-job-safe-p "mine"))
      (should-not (drgnx-job-safe-p "claude"))
      (should-not (drgnx-job-safe-p "gem"))
      (should-not (drgnx-job-safe-p "wrapped"))
      (should-not (drgnx-job-safe-p "no such profile"))
      (should (drgnx-job-safe-p "claude (OpenRouter)")))
    ;; a profile of the user's may say so only when it runs Claude Code's adapter, told by its package: a wrapper
    ;; whose name says claude gets the lock (fail closed) but not a job
    (let* ((wrapper (expand-file-name "my-claude-wrapper" root))
           (exec-path (cons (drgnx-job-safe-test--adapter root) exec-path))
           (drgnx-agents-profiles `(("mine" :command ("claude-agent-acp") :job-safe t)
                                    ("wrapper" :command (,wrapper) :job-safe t))))
      (write-region "#!/bin/sh\nexec gemini \"$@\"\n" nil wrapper nil 'silent)
      (set-file-modes wrapper #o755)
      (should (drgnx-job-safe-p "mine"))
      (should (drgnx-agents--runs-claude-p (list wrapper)))
      (should-not (drgnx-job-safe-p "wrapper")))
    (let ((exec-path (list root)) (drgnx-agents-profiles '(("mine" :command ("claude-agent-acp") :job-safe t))))   ; no adapter
      (should-not (drgnx-job-safe-p "mine")))))

(ert-deftest drgnx-job-safe/subscription-profile-refused-on-macos ()
  (drgnx-job-safe-test--with
    (let ((system-type 'darwin))
      (should-not (drgnx-job-safe-p "claude"))
      (should (drgnx-job-safe-p "claude (OpenRouter)"))
      (should (drgnx-job-safe-p "claude (Ollama)")))
    (should (drgnx-job-safe-p "claude"))))

(defun drgnx-job-safe-test--cards (id kind)
  (seq-filter (lambda (c) (equal (plist-get c :kind) kind)) (drgnx-coord-cards id "open")))

(ert-deftest drgnx-job-safe/refused-with-a-card ()
  (drgnx-job-run-test--with "# One\n\n### Task 1: one\n"
    (let* ((drgnx-job-run-test--safe nil) (system-type 'gnu/linux)
           (drgnx-job-max-agents 0) (drgnx-job-review nil) (id (drgnx-job-propose plan)))
      (drgnx-job-approve id)
      (let ((task (car (drgnx-coord-tasks id))))
        (should-not (drgnx-job-safe-p "mock"))
        (drgnx-job--launch-task id task)
        (should-not (seq-find (lambda (s) (equal (drgnx-agent-session-job s) id)) drgnx-agents--sessions))   ; no agent
        (let ((card (car (drgnx-job-safe-test--cards id "agent"))))
          (should card)
          (should (equal (plist-get card :task) (plist-get task :id)))
          (should (string-search "mock" (plist-get card :title)))
          (should (string-search "repository's own settings" (plist-get card :title)))
          (should (string-search "claude (OpenRouter)" (plist-get card :title))))
        (should (equal (drgnx-job-run-test--status id 1) "needs-input"))
        ;; a reviewer too
        (drgnx-job--start-review-agent id task)
        (should-not (seq-find (lambda (s) (equal (drgnx-agent-session-job s) id)) drgnx-agents--sessions))))))

(ert-deftest drgnx-job-safe/a-job-session-on-an-unsafe-profile-never-starts ()
  ;; the backstop where a session gets its job: a direct start and the hub's agents/start alike
  (drgnx-job-run-test--with "# One\n\n### Task 1: one\n"
    (let* ((drgnx-job-run-test--safe nil) (id (drgnx-job-propose plan))
           (said (lambda (s) (string-search "not job-safe" (format "%S" (drgnx-agent-session-entries s))))))
      (let ((s (drgnx-agents-start "mock" repo nil id)))
        (should (eq (drgnx-agent-session-status s) 'exited))
        (should (funcall said s))
        (should-not (drgnx-agent-session-conn s)))
      (drgnx-hub-connect)
      (let ((s (drgnx-agents-get (plist-get (drgnx-hub-call-sync "agents/start" (list :profile "mock" :cwd repo :job id)) :id))))
        (should (eq (drgnx-agent-session-status s) 'exited))
        (should (funcall said s)))
      (let ((plain (drgnx-agents-start "mock" repo)))                  ; no job: any profile
        (should (drgnx-job-run-test--wait (lambda () (eq (drgnx-agent-session-status plain) 'idle))))))))

(ert-deftest drgnx-job-safe/clash-reviewer-refused-with-a-card ()
  (drgnx-job-run-test--with "# One\n\n### Task 1: one\n"
    (require 'drgnx-job-clash)
    (let* ((drgnx-job-run-test--safe nil) (id (drgnx-job-propose plan))
           (card (drgnx-coord-card-create :job id :kind "clash" :title "a clash" :data '(:rule "r" :size "short"))))
      (should-not (drgnx-job-clash--start-reviewer id card))
      (should-not (seq-find (lambda (s) (equal (drgnx-agent-session-job s) id)) drgnx-agents--sessions))
      (let ((c (car (drgnx-job-safe-test--cards id "profile"))))
        (should c)
        (should (string-search "mock cannot run a job's agent" (plist-get c :title)))
        (should (equal (mapcar #'car (drgnx-job-card-actions c)) '("dismiss")))))))

(defun drgnx-job-safe-test--resource (name server &optional title)
  "An ACP call of Claude Code's tool NAME (ReadMcpResourceTool, ListMcpResourcesTool) with SERVER as its input."
  (list :kind "other" :title (or title name) :rawInput (append (and server (list :server server)) '(:uri "x://y"))
        :_meta (list :claudeCode (list :toolName name))))

(ert-deftest drgnx-job-safe/resource-tools-ask ()
  (let ((tree temporary-file-directory))
    (dolist (tool '("ReadMcpResourceTool" "ListMcpResourcesTool"))
      (should (eq (drgnx-job-policy "implement" (drgnx-job-safe-test--resource tool "other") tree) 'ask))
      (should (eq (drgnx-job-policy "implement" (drgnx-job-safe-test--resource tool nil) tree) 'ask))   ; every server's
      (should (eq (drgnx-job-policy "implement" (drgnx-job-safe-test--resource tool "drgnx_x") tree) 'ask))
      ;; named only in the title, or only in `_meta'
      (should (eq (drgnx-job-policy "implement" (list :kind "other" :title tool :rawInput '(:server "other")) tree) 'ask))
      (should (eq (drgnx-job-policy "implement" (drgnx-job-safe-test--resource tool "other" "Read resource") tree) 'ask))
      (should (eq (drgnx-job-policy "review" (drgnx-job-safe-test--resource tool "other") tree) 'ask)))))

(ert-deftest drgnx-job-safe/resource-tools-of-drgnx-allowed ()
  (let ((tree temporary-file-directory))
    (dolist (tool '("ReadMcpResourceTool" "ListMcpResourcesTool"))
      (should (eq (drgnx-job-policy "implement" (drgnx-job-safe-test--resource tool "drgnx") tree) 'allow))
      (should (eq (drgnx-job-policy "implement" (drgnx-job-safe-test--resource tool "drgnx-search") tree) 'allow)))))

(ert-deftest drgnx-job-safe/profile-mcp-servers-are-appended ()
  (drgnx-job-safe-test--with
    (let* ((docs '(:name "docs" :command "docs-mcp" :args ["--ro"] :env []))
           (drgnx-agents-profiles
            `(("mine" :command ("claude-agent-acp") :job-safe t
               :mcp-servers (,docs (:name "drgnx" :command "evil" :args [] :env [])   ; drgnx's own names are drgnx's
                                   (:name "drgnx-search" :command "evil" :args [] :env [])))
              ("plain" :command ("claude-agent-acp")))))
      (dolist (job '(nil "job-1"))
        (let ((servers (append (drgnx-agents--mcp-servers (drgnx-agents--make :id "s-1" :profile "mine" :cwd root :job job)) nil)))
          (should (equal (mapcar (lambda (e) (plist-get e :name)) servers) '("drgnx" "docs")))   ; after drgnx's
          (should (equal (car (last servers)) docs))))
      (should (equal (mapcar (lambda (e) (plist-get e :name))
                             (drgnx-agents--mcp-servers (drgnx-agents--make :id "s-2" :profile "plain" :cwd root)))
                     '("drgnx"))))))

;;; job-safe-test.el ends here
