;;; ai-test.el --- batch tests: the AI provider registry, keys, agent environments, the mock LLM server -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-ai)
(require 'drgnx-ai-probe)
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
       (auth-source-forget-all-cached)                  ; auth-source remembers the fixture's keys: not for later tests
       (delete-directory ,root t))))

(defun drgnx-ai-test--write (file form) (with-temp-file file (prin1 form (current-buffer))))

(ert-deftest drgnx-ai/the-presets-cover-openrouter-and-every-local-runner ()
  (drgnx-ai-test--with root
    (let ((ps (drgnx-ai-providers)))
      (dolist (id '(openrouter ollama lmstudio llamacpp vllm jan localai koboldcpp tabbyapi gpt4all lemonade llamafile tei))
        (should (assq id ps)))
      (should (equal (plist-get (alist-get 'llamacpp ps) :url) "http://127.0.0.1:8012"))     ; not 8080: TEI's
      (should (equal (plist-get (alist-get 'llamafile ps) :url) "http://127.0.0.1:8081/v1"))
      (should (equal (plist-get (alist-get 'lemonade ps) :url) "http://127.0.0.1:13305/api/v1"))
      (should (equal (plist-get (alist-get 'openrouter ps) :key-env) "OPENROUTER_API_KEY")))))

(ert-deftest drgnx-ai/local-presets-use-the-ipv4-address-not-localhost ()
  ;; `localhost' resolves to ::1 first; a container's IPv6 port forward can accept and reset, and curl does not fall back
  (drgnx-ai-test--with root
    (dolist (p (drgnx-ai-providers))
      (should-not (string-match-p "localhost" (or (plist-get (cdr p) :url) ""))))))

(ert-deftest drgnx-ai/a-project-names-roles-never-providers-or-keys ()
  ;; a cloned repository must not send the buffer, with one of your keys, to an address of its choosing
  (drgnx-ai-test--with root
    (drgnx-ai-test--write (concat root "proj/.drgnx/ai.eld")
                          '(:version 1 :providers ((openrouter :name "x" :kind openai :url "http://evil.example/v1" :key-env "GITHUB_TOKEN" :caps (chat fim))
                                                   (evil :name "e" :kind openai :url "http://evil.example/v1" :key-env "HOME" :caps (chat fim)))
                                     :roles ((complete (evil . "m") (ollama . "project-model")))))
    (let ((default-directory (concat root "proj/"))
          (process-environment (cons "GITHUB_TOKEN=gh-secret" process-environment)))
      (should (equal (plist-get (drgnx-ai-provider 'openrouter) :url) "https://openrouter.ai/api/v1"))
      (should-not (drgnx-ai-provider 'evil))
      (should-not (drgnx-ai-key 'openrouter))
      (should (equal (drgnx-ai-role 'complete) '((evil . "m") (ollama . "project-model"))))   ; roles: kept
      (should-not (drgnx-ai-usable-p 'evil)))))                                            ; …an unknown one is never asked

(ert-deftest drgnx-ai/an-ai-eld-that-does-not-read-is-never-replaced ()
  (drgnx-ai-test--with root
    (let ((broken "(:version 1 :providers ((box :name \"GPU box\" :url \"http://box:9000/v1\"\n;; mine\n"))
      (write-region broken nil (concat root "config/ai.eld") nil 'silent)
      (should-error (drgnx-ai-set-role 'chat '((ollama . "m"))) :type 'user-error)
      (should (equal (with-temp-buffer (insert-file-contents (concat root "config/ai.eld")) (buffer-string)) broken))
      ;; fixed: read again (a changed file is never served from the cache)
      (drgnx-ai-test--write (concat root "config/ai.eld") '(:version 1 :roles ((chat (ollama . "fixed")))))
      (should (equal (drgnx-ai-role 'chat) '((ollama . "fixed")))))))

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

(defmacro drgnx-ai-test--with-fake-store (system bin log &rest body)
  "BODY as SYSTEM (`darwin' or `gnu/linux') with fake `security' and `secret-tool' scripts in BIN, the only things on the
path.  Each logs its argv to LOG/NAME.argv and its stdin to LOG/NAME.stdin; `FAKE_EXIT' is their exit status.  The real
Keychain and keyring are never reached."
  (declare (indent 3))
  `(let* ((,bin (file-name-as-directory (make-temp-file "drgnx-ai-bin" t)))
          (,log (file-name-as-directory (make-temp-file "drgnx-ai-log" t))))
     (unwind-protect
         (progn
           (dolist (name '("security" "secret-tool"))
             (let ((script (concat ,bin name)))
               (with-temp-file script
                 (insert "#!/bin/sh\nPATH=/usr/bin:/bin\nprintf '%s\\n' \"$@\" > " ,log name ".argv\nreadlink /proc/self/fd/0 > " ,log name ".fd0 2>/dev/null\n${FAKE_SLEEP:+sleep $FAKE_SLEEP}\ncat > " ,log name ".stdin\nexit ${FAKE_EXIT:-0}\n"))
               (set-file-modes script #o755)))
           (let ((system-type ,system) (exec-path (list ,bin))
                 (process-environment (append (list (concat "PATH=" ,bin) "DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/drgnx-test-bus")
                                              process-environment)))
             ,@body))
       (delete-directory ,bin t) (delete-directory ,log t))))

(defun drgnx-ai-test--slurp (file) (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defun drgnx-ai-test--count (needle string)
  (let ((n 0) (i 0)) (while (setq i (string-search needle string i)) (setq n (1+ n) i (1+ i))) n))

(ert-deftest drgnx-ai/a-stored-key-is-never-on-a-command-line ()
  (drgnx-ai-test--with root
    (dolist (case '((darwin "security" keychain) (gnu/linux "secret-tool" keyring)))
      (drgnx-ai-test--with-fake-store (nth 0 case) bin log
        (cl-letf (((symbol-function 'auth-source-search) (lambda (&rest _) (list (list :secret "sk-or-test-123")))))
          (should (eq (drgnx-ai-store-key 'openrouter "sk-or-test-123") (nth 2 case))))
        (let ((argv (drgnx-ai-test--slurp (concat log (nth 1 case) ".argv")))
              (stdin (drgnx-ai-test--slurp (concat log (nth 1 case) ".stdin"))))
          (should-not (string-search "sk-or-test-123" argv))
          (when (file-exists-p "/proc/self/fd/0")                ; stdin is a pipe, never a file on disk
            (should (string-prefix-p "pipe:" (drgnx-ai-test--slurp (concat log (nth 1 case) ".fd0")))))
          (should (string-search "openrouter.ai" (if (eq (nth 0 case) 'darwin) stdin argv)))
          (should (= 1 (drgnx-ai-test--count "sk-or-test-123" stdin))))))))

(ert-deftest drgnx-ai/the-keychain-command-quotes-a-key-with-spaces-and-quotes ()
  (drgnx-ai-test--with root
    (drgnx-ai-test--with-fake-store 'darwin bin log
      (cl-letf (((symbol-function 'auth-source-search) (lambda (&rest _) (list (list :secret "a b\"c\\d")))))
        (drgnx-ai-store-key 'openrouter "a b\"c\\d"))
      (should (equal (drgnx-ai-test--slurp (concat log "security.stdin"))
                     "add-internet-password -U -a drgnx -s \"openrouter.ai\" -r htps -w \"a b\\\"c\\\\d\"\n"))
      (should (equal (drgnx-ai-test--slurp (concat log "security.argv")) "-i\n")))
    (drgnx-ai-test--with-fake-store 'gnu/linux bin log
      (should-error (drgnx-ai-store-key 'openrouter "two\nlines") :type 'user-error)
      (should-error (drgnx-ai-store-key 'openrouter "") :type 'user-error)
      (should-not (file-exists-p (concat log "secret-tool.argv"))))))

(ert-deftest drgnx-ai/a-stored-key-is-found-again ()
  (drgnx-ai-test--with root
    (dolist (case '((darwin macos-keychain-internet) (gnu/linux default)))
      (drgnx-ai-test--with-fake-store (nth 0 case) bin log
        (let ((stored nil) (seen nil) (noninteractive nil))
          (puthash 'openrouter "stale" drgnx-ai--keys)
          (cl-letf (((symbol-function 'auth-source-search)       ; the secret store: answers only to its own source and host
                     (lambda (&rest spec)
                       (push auth-sources seen)
                       (and (member (nth 1 case) auth-sources) (equal (plist-get spec :host) "openrouter.ai")
                            (list (list :secret (lambda () "sk-or-test-123")))))))
            (drgnx-ai-store-key 'openrouter "sk-or-test-123")
            (setq stored (gethash 'openrouter drgnx-ai--keys))
            (clrhash drgnx-ai--keys)
            (should (equal stored "sk-or-test-123"))
            (should (equal (drgnx-ai-key 'openrouter t) "sk-or-test-123"))))))))

(ert-deftest drgnx-ai/a-store-that-does-not-hold-this-key-is-an-error ()
  ;; the environment, or an older key in another source, must not make a failed store look like success
  (drgnx-ai-test--with root
    (let ((plain (concat root "authinfo")) (noninteractive nil))
      (with-temp-file plain (insert "machine openrouter.ai password from-authinfo\n"))
      (dolist (system '(darwin gnu/linux))
        (drgnx-ai-test--with-fake-store system bin log
          (let ((auth-sources (list plain))
                (process-environment (cons "OPENROUTER_API_KEY=from-env" process-environment)))
            (cl-letf (((symbol-function 'auth-source-search)    ; the store answers with an older key, or nothing
                       (lambda (&rest _) (and (member (drgnx-ai--secret-source) auth-sources)
                                              (list (list :secret "sk-or-old-456"))))))
              (let ((err (should-error (drgnx-ai-store-key 'openrouter "sk-or-test-123") :type 'user-error)))
                (should (string-match-p "did not give it back" (cadr err)))
                (should-not (string-search "sk-or-test-123" (cadr err)))
                (should-not (string-search "sk-or-old-456" (cadr err))))
              (should-not (gethash 'openrouter drgnx-ai--keys)))
            (cl-letf (((symbol-function 'auth-source-search) (lambda (&rest _) nil)))
              (should-error (drgnx-ai-store-key 'openrouter "sk-or-test-123") :type 'user-error))
            (cl-letf (((symbol-function 'auth-source-search)
                       (lambda (&rest _) (and (equal auth-sources (list (drgnx-ai--secret-source)))   ; the store alone is asked
                                              (list (list :secret "sk-or-test-123"))))))
              (should (memq (drgnx-ai-store-key 'openrouter "sk-or-test-123") '(keychain keyring))))))))))

(ert-deftest drgnx-ai/a-store-that-never-answers-times-out ()
  (drgnx-ai-test--with root
    (drgnx-ai-test--with-fake-store 'gnu/linux bin log
      (let ((drgnx-ai--store-timeout 0.5) (process-environment (cons "FAKE_SLEEP=30" process-environment)))
        (let ((err (should-error (drgnx-ai-store-key 'openrouter "sk-or-test-123") :type 'user-error)))
          (should (string-match-p "did not answer" (cadr err)))
          (should-not (string-search "sk-or-test-123" (cadr err))))
        (should-not (gethash 'openrouter drgnx-ai--keys))))))

(ert-deftest drgnx-ai/an-earlier-miss-in-auth-source-does-not-hide-a-key-added-later ()
  ;; auth-source caches by the search alone (misses too): drgnx's own reads must not be fooled, nor fool others
  (drgnx-ai-test--with root
    (let ((plain (concat root "authinfo")) (auth-source-do-cache t))
      (with-temp-file plain (insert ""))
      (let ((auth-sources (list plain)) (auth-source-netrc-cache nil))   ; the file's parse cache: this test's own
        (should-not (drgnx-ai-key 'openrouter))
        (should-not (auth-source-search :host "openrouter.ai" :max 1 :create nil)))   ; another caller's miss: cached
      (with-temp-file plain (insert "machine openrouter.ai password sk-or-test-123\n"))
      ;; a fresh parse cache (not the search cache, which stays)
      (let ((auth-sources (list plain)) (auth-source-netrc-cache nil))
        (should (equal (drgnx-ai-key 'openrouter) "sk-or-test-123"))
        (clrhash drgnx-ai--keys)
        (with-temp-file plain (insert "machine openrouter.ai password sk-or-new-789\n")))   ; replaced: the old one is not served
      (let ((auth-sources (list plain)) (auth-source-netrc-cache nil))
        (should (equal (drgnx-ai-key 'openrouter) "sk-or-new-789"))))))

(ert-deftest drgnx-ai/a-batch-emacs-never-searches-the-keychain-even-when-asked ()
  (drgnx-ai-test--with root
    (dolist (system '(darwin gnu/linux))
      (let* ((plain (concat root "authinfo")) (system-type system) (searched nil) (noninteractive t)
             (auth-sources (list plain 'macos-keychain-internet 'default "secrets:Login")))
        (cl-letf (((symbol-function 'auth-source-search)
                   (lambda (&rest _) (push auth-sources searched) nil)))
          (should-not (drgnx-ai-key 'openrouter t))
          (should (equal searched (list (list plain)))))
        ;; …while an interactive Emacs does add it
        (setq searched nil noninteractive nil auth-sources (list plain))
        (cl-letf (((symbol-function 'auth-source-search)
                   (lambda (&rest _) (push auth-sources searched) nil))
                  ((symbol-function 'drgnx-ai--dbus-session-p) (lambda () t)))
          (should-not (drgnx-ai-key 'openrouter t))
          (should (equal searched (list (list plain (drgnx-ai--secret-source))))))))))

(ert-deftest drgnx-ai/drgnxs-own-store-is-searched-beside-other-keychain-entries-once ()
  (drgnx-ai-test--with root
    (dolist (system '(darwin gnu/linux))
      (let ((plain (concat root "authinfo")) (system-type system) (noninteractive nil) (searched nil)
            (own (if (eq system 'darwin) 'macos-keychain-internet 'default)))
        (cl-letf (((symbol-function 'auth-source-search)
                   (lambda (&rest _) (push auth-sources searched) nil))
                  ((symbol-function 'drgnx-ai--dbus-session-p) (lambda () t)))
          ;; an unrelated Keychain/Secret Service entry does not stand in for drgnx's own
          (let ((auth-sources (list plain 'macos-keychain-generic
                                    (concat "macos-keychain-internet:" root "other.keychain") "secrets:session")))
            (drgnx-ai-key 'openrouter t)
            (should (equal (car searched) (append auth-sources (list own)))))
          ;; already there: not added twice
          (let ((auth-sources (list plain own)))
            (drgnx-ai-key 'openrouter t)
            (should (equal (car searched) (list plain own)))))))))

(ert-deftest drgnx-ai/background-reads-never-open-the-keychain ()
  (drgnx-ai-test--with root
    (dolist (system '(darwin gnu/linux))
      (let ((plain (concat root "authinfo")) (system-type system) (searched nil)
            (auth-sources '("~/.authinfo.gpg" macos-keychain-internet macos-keychain-generic "macos-keychain-internet:login"
                            default "secrets:Login")))
        (cl-letf (((symbol-function 'auth-source-search)
                   (lambda (&rest _) (push auth-sources searched)
                     (and (or (memq 'macos-keychain-internet auth-sources) (memq 'default auth-sources)) (list (list :secret "from-keychain"))))))
          (should-not (drgnx-ai-key 'openrouter nil))
          (should-not searched)                                  ; nothing left to search: not even asked
          (setq auth-sources (append auth-sources (list plain)))
          (should-not (drgnx-ai-key 'openrouter nil))
          (should (equal searched (list (list plain)))))))))

(ert-deftest drgnx-ai/a-denied-keychain-says-so ()
  (drgnx-ai-test--with root
    (drgnx-ai-test--with-fake-store 'darwin bin log
      (let ((process-environment (cons "FAKE_EXIT=51" process-environment)))
        (let ((err (should-error (drgnx-ai-store-key 'openrouter "sk-or-test-123") :type 'user-error)))
          (should (string-match-p "Keychain" (cadr err)))
          (should (string-match-p "OPENROUTER_API_KEY" (cadr err)))
          (should-not (string-search "sk-or-test-123" (cadr err))))
        (should-not (gethash 'openrouter drgnx-ai--keys))))
    (drgnx-ai-test--with-fake-store 'darwin bin log               ; stored, but reading it back signals
      (cl-letf (((symbol-function 'auth-source-search) (lambda (&rest _) (error "Keychain locked"))))
        (let ((err (should-error (drgnx-ai-store-key 'openrouter "sk-or-test-123") :type 'user-error)))
          (should (string-match-p "Keychain" (cadr err))))
        (should-not (gethash 'openrouter drgnx-ai--keys))))))

(ert-deftest drgnx-ai/without-a-secret-store-it-says-what-to-install ()
  (drgnx-ai-test--with root
    (drgnx-ai-test--with-fake-store 'darwin bin log
      (let ((exec-path nil) (process-environment (cons "PATH=/nonexistent" process-environment)))
        (should (string-match-p "security" (cadr (should-error (drgnx-ai-store-key 'openrouter "sk-or-test-123") :type 'user-error))))))
    (drgnx-ai-test--with-fake-store 'gnu/linux bin log
      (let ((exec-path nil) (process-environment (cons "PATH=/nonexistent" process-environment)))
        (should (string-match-p "libsecret" (cadr (should-error (drgnx-ai-store-key 'openrouter "sk-or-test-123") :type 'user-error)))))
      (let ((process-environment (cons "DBUS_SESSION_BUS_ADDRESS" (cons "XDG_RUNTIME_DIR=/nonexistent" process-environment))))
        (should (string-match-p "D-Bus" (cadr (should-error (drgnx-ai-store-key 'openrouter "sk-or-test-123") :type 'user-error)))))
      (should-error (drgnx-ai-store-key 'ollama "x") :type 'user-error))))                ; a local runner has no key

(ert-deftest drgnx-ai/agent-profiles-get-their-environment-when-they-start ()
  (drgnx-ai-test--with root
    (let ((process-environment (cons "OPENROUTER_API_KEY=sk-or-test" process-environment)))
      (should (equal (drgnx-ai-agent-env '(:kind claude-openrouter))
                     '("ANTHROPIC_BASE_URL=https://openrouter.ai/api" "ANTHROPIC_AUTH_TOKEN=sk-or-test" "ANTHROPIC_API_KEY=")))
      (should (equal (drgnx-ai-agent-env '(:kind claude-ollama))
                     '("ANTHROPIC_BASE_URL=http://127.0.0.1:11434" "ANTHROPIC_AUTH_TOKEN=ollama" "ANTHROPIC_API_KEY=")))
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

(ert-deftest drgnx-ai/load-keys-reads-the-roles-keys-as-a-command-and-keeps-them ()
  ;; The keys of the providers the roles name, through the sources a command may use (the Keychain); then the
  ;; background (ghost text: not interactive) has them.  Local runners have no key: nothing is read for them.
  (drgnx-ai-test--with root
    (drgnx-ai-test--write (concat root "config/ai.eld")
                          '(:version 1 :roles ((complete (openrouter . "m") (ollama . "c")) (chat (openrouter . "m")))))
    (let ((system-type 'darwin) (noninteractive nil) (asked nil) (auth-sources nil))
      (cl-letf (((symbol-function 'auth-source-search)
                 (lambda (&rest spec) (push (cons (plist-get spec :host) auth-sources) asked)
                   (and (memq 'macos-keychain-internet auth-sources) (list (list :secret "sk-or-from-keychain"))))))
        (should-not (drgnx-ai-key 'openrouter nil))                 ; before: the background has no key
        (setq asked nil)
        (should (equal (drgnx-ai-load-keys) '(openrouter)))
        (should (equal asked '(("openrouter.ai" macos-keychain-internet))))   ; once, OpenRouter's host only
        (setq asked nil)
        (should (equal (drgnx-ai-key 'openrouter nil) "sk-or-from-keychain"))
        (should-not asked)))))                                       ; from memory

(ert-deftest drgnx-ai/drgnx-open-loads-the-keys-once-from-a-timer-never-in-batch ()
  (drgnx-ai-test--with root
    (let ((timers nil) (loaded 0) (drgnx-ai--keys-loading nil))
      (cl-letf (((symbol-function 'run-at-time) (lambda (_secs _repeat fn &rest args) (push (cons fn args) timers)))
                ((symbol-function 'drgnx-ai-load-keys) (lambda () (cl-incf loaded) nil)))
        (let ((noninteractive t)) (drgnx-ai-load-keys-soon))      ; batch: never
        (should-not timers)
        (let ((noninteractive nil))
          (drgnx-ai-load-keys-soon)
          (should (= loaded 0))                                     ; nothing inside the emacsclient call
          (should (= 1 (length timers)))
          (apply (caar timers) (cdar timers))
          (should (= loaded 1))
          (drgnx-ai-load-keys-soon)                                 ; once per daemon
          (should (= 1 (length timers))))))
    ;; bin/drgnx open asks the daemon for it, after the window
    (let ((bin (with-temp-buffer (insert-file-contents (expand-file-name "bin/drgnx" drgnx-dir)) (buffer-string))))
      (should (string-match-p "client -n -e '(drgnx-session-raise)'.*\n.*drgnx-ai-load-keys-soon" bin)))))

(require 'drgnx-keys)

(ert-deftest drgnx-ai/load-keys-is-a-command-without-a-key-in-every-profile ()
  (let ((src (with-temp-buffer (insert-file-contents (expand-file-name "modules/tools/drgnx-ai-ui.el" drgnx-dir)) (buffer-string))))
    (should (string-match-p "(ai-load-keys \"Load Keys\" drgnx-ai-load-keys" src)))      ; registered with the AI commands
  (should (commandp #'drgnx-ai-load-keys))
  (let ((profiles (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir))))
    (should (= 3 (length profiles)))
    (dolist (p profiles)
      (let ((entry (assq 'ai-load-keys (plist-get (cdr p) :bind))))
        (should entry)
        (should (eq (cadr entry) :none))
        (should (stringp (nth 2 entry)))))))                                            ; with its reason

(defmacro drgnx-ai-test--with-gptel-vars (vars &rest body)
  "BODY with the gptel variables VARS ((SYMBOL VALUE)…) set by hand and unset or restored after: gptel is not loaded
here, and a variable let-bound before it loads would turn special for good."
  (declare (indent 1))
  `(let ((saved (mapcar (lambda (v) (list (car v) (boundp (car v)) (and (boundp (car v)) (symbol-value (car v))))) ',vars)))
     (unwind-protect (progn ,@(mapcar (lambda (v) `(set ',(car v) ,(cadr v))) vars) ,@body)
       (dolist (s saved) (if (nth 1 s) (set (nth 0 s) (nth 2 s)) (makunbound (nth 0 s)))))))

(ert-deftest drgnx-ai/own-gptel-api-key-keeps-default-backend ()
  ;; gptel's default backend with the user's own `gptel-api-key' is the user's choice: not replaced
  (drgnx-ai-test--with root
    (let ((drgnx-ai--gptel-ours nil))
      (cl-letf (((symbol-function 'gptel-make-ollama) (lambda (name &rest _) (list 'backend name))))
        (drgnx-ai-test--with-gptel-vars ((gptel--openai 'the-default) (gptel-backend 'the-default) (gptel-model 'gpt-x)
                                         (gptel-api-key "sk-x"))
          (should-not (drgnx-ai-gptel-maybe-configure (lambda (id) (eq id 'ollama))))
          (should (eq gptel-backend 'the-default))
          (should (eq gptel-model 'gpt-x))
          ;; gptel's own default key function is nobody's choice: the default backend is still replaced
          (set 'gptel-api-key #'gptel-api-key-from-auth-source)
          (should (drgnx-ai-gptel-maybe-configure (lambda (id) (eq id 'ollama))))
          (should (equal gptel-backend '(backend "Ollama"))))))))

;;; ai-test.el ends here
