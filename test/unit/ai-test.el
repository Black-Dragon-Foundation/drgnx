;;; ai-test.el --- batch tests: the AI provider registry, keys, agent environments, the mock LLM server -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-ai)
(require 'drgnx-jobs)
(require 'auth-source)
(load (expand-file-name "test/fixtures/mock-llm" drgnx-dir) nil t)

(defmacro drgnx-ai-test--with (root &rest body)
  "BODY with ROOT a temp dir: the config dir ROOT/config, a project ROOT/proj, no provider keys in the environment."
  (declare (indent 1))
  `(let* ((,root (file-name-as-directory (make-temp-file "drgnx-ai" t)))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" ,root "config") (concat "XDG_STATE_HOME=" ,root "state")
                                             "OPENROUTER_API_KEY" "DRGNX_JOBS_LAUNCHER=detached")
                                       process-environment))
          (auth-sources nil) (drgnx-ai--keys (make-hash-table :test #'eq)))
     (unwind-protect (progn (make-directory (concat ,root "config") t) (make-directory (concat ,root "proj/.drgnx") t) ,@body)
       (delete-directory ,root t))))

(defun drgnx-ai-test--write (file form) (with-temp-file file (prin1 form (current-buffer))))

(ert-deftest drgnx-ai/the-presets-cover-openrouter-and-every-local-runner ()
  (drgnx-ai-test--with root
    (let ((ps (drgnx-ai-providers)))
      (dolist (id '(openrouter ollama lmstudio llamacpp vllm jan localai koboldcpp tabbyapi gpt4all lemonade llamafile tei))
        (should (assq id ps)))
      (should (equal (plist-get (alist-get 'llamacpp ps) :url) "http://localhost:8012"))     ; not 8080: TEI's
      (should (equal (plist-get (alist-get 'llamafile ps) :url) "http://localhost:8081/v1"))
      (should (equal (plist-get (alist-get 'lemonade ps) :url) "http://localhost:13305/api/v1"))
      (should (equal (plist-get (alist-get 'openrouter ps) :key-env) "OPENROUTER_API_KEY")))))

(ert-deftest drgnx-ai/ai-eld-adds-providers-and-a-project-overrides-a-role ()
  (drgnx-ai-test--with root
    (drgnx-ai-test--write (concat root "config/ai.eld")
                          '(:version 1 :providers ((mine :name "Mine" :kind openai :url "http://box:9000/v1" :key-env "MINE_KEY"))
                                     :roles ((chat (mine . "big") (ollama . "small")))))
    (drgnx-ai-test--write (concat root "proj/.drgnx/ai.eld") '(:version 1 :roles ((chat (ollama . "project-model")))))
    (should (equal (plist-get (alist-get 'mine (drgnx-ai-providers)) :url) "http://box:9000/v1"))
    (should (equal (drgnx-ai-role 'chat) '((mine . "big") (ollama . "small"))))
    (let ((default-directory (concat root "proj/")))
      (should (equal (drgnx-ai-role 'chat) '((ollama . "project-model")))))
    (should (equal (car (drgnx-ai-role 'complete)) '(ollama . "qwen2.5-coder:1.5b")))))       ; a default

(ert-deftest drgnx-ai/a-key-comes-from-the-environment-then-auth-source-never-a-gpg-file-unasked ()
  (drgnx-ai-test--with root
    (let ((plain (concat root "authinfo")) (gpg (concat root "authinfo.gpg")) (searched nil))
      (with-temp-file plain (insert "machine openrouter.ai password from-authinfo\n"))
      (let ((file-name-handler-alist nil)) (with-temp-file gpg (insert "not really encrypted\n")))   ; no EasyPG
      (let ((auth-sources (list gpg plain)))
        (should (equal (drgnx-ai-key 'openrouter) "from-authinfo"))
        ;; the environment wins, even over a key found (and kept) before
        (let ((process-environment (cons "OPENROUTER_API_KEY=from-env" process-environment)))
          (should (equal (drgnx-ai-key 'openrouter) "from-env")))
        (clrhash drgnx-ai--keys)
        ;; outside a command the user ran, a .gpg source (it may ask for a passphrase) is never searched
        (let ((auth-sources (list gpg)))
          (cl-letf (((symbol-function 'auth-source-search)       ; records what it would read; never decrypts
                     (lambda (&rest _) (push auth-sources searched) nil)))
            (should-not (drgnx-ai-key 'openrouter))
            (should-not (seq-find (lambda (s) (member gpg s)) searched))))
        (should-not (drgnx-ai-key 'ollama))))))                                            ; local: no key

(ert-deftest drgnx-ai/agent-profiles-get-their-environment-when-they-start ()
  (drgnx-ai-test--with root
    (let ((process-environment (cons "OPENROUTER_API_KEY=sk-or-test" process-environment)))
      (should (equal (drgnx-ai-agent-env '(:kind claude-openrouter))
                     '("ANTHROPIC_BASE_URL=https://openrouter.ai/api" "ANTHROPIC_AUTH_TOKEN=sk-or-test" "ANTHROPIC_API_KEY=")))
      (should (equal (drgnx-ai-agent-env '(:kind claude-ollama))
                     '("ANTHROPIC_BASE_URL=http://localhost:11434" "ANTHROPIC_AUTH_TOKEN=ollama" "ANTHROPIC_API_KEY=")))
      (should-not (drgnx-ai-agent-env '(:kind subscription))))                             ; its own login, never read
    (should-error (drgnx-ai-agent-env '(:kind claude-openrouter)) :type 'user-error)))     ; no key: said, not sent empty

(ert-deftest drgnx-ai/an-agent-profile-names-its-kind-and-gets-the-environment-at-start ()
  (require 'drgnx-agents)
  (drgnx-ai-test--with root
    (let ((drgnx-agents-profiles '(("local claude" :command ("claude-agent-acp") :ai claude-ollama))))
      (should (member "ANTHROPIC_AUTH_TOKEN=ollama" (drgnx-agents--env (drgnx-agents--make :profile "local claude"))))
      (should (assoc "claude (OpenRouter)" drgnx-agents-builtin-profiles))                 ; offered without setup
      (should (assoc "claude (Ollama)" drgnx-agents-builtin-profiles)))))

(ert-deftest drgnx-ai/a-job-receives-keys-that-no-command-line-or-state-file-shows ()
  (skip-unless (executable-find "setsid"))
  (drgnx-ai-test--with root
    (let* ((id (drgnx-jobs-start "k" (list "sh" "-c" "printf %s \"$SECRET_FOR_JOB\" > got") :cwd root :env '("SECRET_FOR_JOB=s3cret")))
           (d (+ (float-time) 10)))
      (while (and (not (eq (plist-get (drgnx-jobs-get id) :status) 'exited)) (< (float-time) d)) (sleep-for 0.05))
      (should (equal (with-temp-buffer (insert-file-contents (concat root "got")) (buffer-string)) "s3cret"))
      (dolist (f (directory-files (drgnx-jobs--dir id) t "\\`[^.]"))
        (should-not (string-search "s3cret" (with-temp-buffer (insert-file-contents f) (buffer-string))))))
    ;; under systemd the value travels in systemd-run's environment: --setenv=NAME, never NAME=value
    (let ((args (drgnx-jobs--systemd-args "1" root "true" '("SECRET_FOR_JOB=s3cret"))))
      (should (member "--setenv=SECRET_FOR_JOB" args))
      (should-not (seq-find (lambda (a) (string-search "s3cret" a)) args)))))

(ert-deftest drgnx-ai/the-mock-llm-server-answers-from-its-script-and-logs-requests ()
  (drgnx-ai-test--with root
    (let* ((port (+ 20000 (random 20000))) (log (concat root "llm.log")) (script (concat root "llm.eld")))
      (drgnx-ai-test--write script '((:path "/v1/chat/completions" :status 200
                                            :body "{\"choices\":[{\"message\":{\"content\":\"hello\"}}]}")))
      (let ((p (drgnx-ai-test-mock-llm port script log)))
        (unwind-protect
            (let ((out (with-temp-buffer
                         (call-process "curl" nil t nil "-s" "-H" "Authorization: Bearer k1" "-d" "{}" (format "http://127.0.0.1:%d/v1/chat/completions" port))
                         (buffer-string))))
              (should (string-search "\"hello\"" out))
              (should (string-search "Authorization: Bearer k1" (with-temp-buffer (insert-file-contents log) (buffer-string)))))
          (delete-process p))))))

;;; ai-test.el ends here
