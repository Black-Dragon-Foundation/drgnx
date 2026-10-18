;;; ai-onboard-test.el --- batch tests: onboarding step 4, AI providers -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-onboard)
(require 'drgnx-ai-probe)
(require 'drgnx-jobs)
(load (expand-file-name "test/fixtures/mock-llm" drgnx-dir) nil t)

(defmacro drgnx-ai-onboard-test--with (&rest body)
  "BODY with only provider `o' (Ollama, a mock serving two models and answering chat and fill-in-the-middle)
known: no preset, so nothing running on this machine counts; no OpenRouter key."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-ai-onboard" t)))
          (port (+ 20000 (random 20000))) (script (concat root "llm.eld"))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" root "config") (concat "XDG_STATE_HOME=" root "state")
                                             "OPENROUTER_API_KEY")
                                       process-environment))
          (drgnx-ai-presets nil) (drgnx-ai-detected nil) (auth-sources nil) (drgnx-ai--keys (make-hash-table :test #'eq))
          (drgnx-modules--state nil) (mock nil))
     (unwind-protect
         (progn
           (make-directory (concat root "config") t)
           (with-temp-file script
             (prin1 '((:path "/api/tags" :body "{\"models\":[{\"name\":\"llama3:8b\"},{\"name\":\"qwen2.5-coder:1.5b\"}]}")
                      (:path "/api/generate" :body "{\"response\":\"ok\"}")
                      (:path "/api/chat" :body "{\"message\":{\"content\":\"OK\"}}"))
                    (current-buffer)))
           (with-temp-file (concat root "config/ai.eld")
             (prin1 `(:version 1 :providers ((o :name "O" :kind ollama :url ,(format "http://127.0.0.1:%d" port) :caps (chat fim))))
                    (current-buffer)))
           (setq mock (drgnx-ai-test-mock-llm port script))
           ,@body)
       (when mock (delete-process mock))
       (delete-directory root t))))

(ert-deftest drgnx-onboard/the-ai-step-finds-providers-sets-roles-and-tests-them ()
  (drgnx-ai-onboard-test--with
    (let ((r (drgnx-onboard--ai-step '(:interactive nil))))
      (should (eq (car r) 'ok))
      (should (equal (car (drgnx-ai-role 'complete)) '(o . "qwen2.5-coder:1.5b")))   ; a coder model fills the middle
      (should (equal (car (drgnx-ai-role 'chat)) '(o . "llama3:8b")))
      (should (string-match-p "complete: o/qwen2.5-coder:1.5b answered" (cadr r)))
      (should (string-match-p "OPENROUTER_API_KEY" (cadr r)))                        ; how to add the key: said
      (should (string-search "run this step again → Change → openrouter (keeps the key in your Keychain or keyring)" (cadr r)))
      (should-not (string-search "authinfo" (cadr r)))
      (should-not (string-search "sk-" (with-temp-buffer (insert-file-contents (concat root "config/ai.eld")) (buffer-string)))))))

(ert-deftest drgnx-onboard/the-ai-step-keeps-roles-that-work ()
  (drgnx-ai-onboard-test--with
    (drgnx-ai-set-role 'chat '((o . "qwen2.5-coder:1.5b")))
    (drgnx-onboard--ai-step '(:interactive nil))
    (should (equal (drgnx-ai-role 'chat) '((o . "qwen2.5-coder:1.5b"))))))         ; the user's choice stays

(ert-deftest drgnx-onboard/the-ai-step-with-nothing-running-says-what-to-do ()
  (drgnx-ai-onboard-test--with
    (delete-process mock) (setq mock nil)
    (let ((r (drgnx-onboard--ai-step '(:interactive nil))))
      (should (memq (car r) '(info warn)))
      (should (string-match-p "no provider" (cadr r))))))

(ert-deftest drgnx-onboard/the-ai-step-checks-chats-module-when-providers-work ()
  ;; a provider that answers is not Chat yet: the ide preset leaves extra/llm (gptel) off
  (drgnx-ai-onboard-test--with
    (drgnx-modules-write-state (list :disabled '(extra/llm)))
    (let ((r (drgnx-onboard--ai-step '(:interactive nil))))
      (should (eq (car r) 'warn))
      (should (string-match-p "chat: o/llama3:8b answered" (cadr r)))
      (should (string-match-p "Chat needs module extra/llm" (cadr r))))
    ;; run again, interactively: Keep, then the offer (declined: still a warning)
    (drgnx-onboard--record 'ai 'warn "before")
    (let* ((asked nil)
           (r (cl-letf (((symbol-function 'completing-read)
                         (lambda (prompt &rest _) (push prompt asked) "Keep"))
                        ((symbol-function 'y-or-n-p) (lambda (prompt) (push prompt asked) nil)))
                (drgnx-onboard--ai-step '(:interactive t)))))
      (should (string-match-p "keep it or change it" (cadr asked)))
      (should (equal (car asked) "Turn on Chat (module extra/llm)? "))
      (should (eq (car r) 'warn))
      (should (drgnx-module-disabled-p 'extra/llm)))
    ;; module on: ok as before
    (drgnx-modules-write-state (list :disabled nil))
    (let ((r (drgnx-onboard--ai-step '(:interactive nil))))
      (should (eq (car r) 'ok))
      (should (string-match-p "Chat (module extra/llm) is on" (cadr r))))))

(ert-deftest drgnx-ai-onboard/role-written-only-after-answer ()
  ;; A provider that never answers leaves ai.eld's roles as they were, and the three test calls share one
  ;; budget: the step ends within about 9 s, not 3 × 16.
  (drgnx-ai-onboard-test--with
    (let ((before (drgnx-ai-onboard-test--slurp (concat root "config/ai.eld"))) (t0 (float-time)) r)
      (cl-letf (((symbol-function 'drgnx-ai-request) (lambda (&rest _) nil)))
        (setq r (drgnx-onboard--ai-found '(:interactive nil))))
      (should (< (- (float-time) t0) 10.5))
      (should (= (nth 2 r) 0))
      (should (string-match-p "did not answer" (cadr r)))
      (should (equal before (drgnx-ai-onboard-test--slurp (concat root "config/ai.eld")))))))

;; A project's ai.eld routes roles for that project only: the roles onboarding writes into the user's ai.eld start
;; from the user's own chain, never from the project's.
(defun drgnx-ai-onboard-test--user-chain (root role)
  (alist-get role (plist-get (with-temp-buffer (insert-file-contents (concat root "config/ai.eld")) (read (current-buffer))) :roles)))

(ert-deftest drgnx-ai-onboard/a-projects-route-never-reaches-the-global-ai-eld ()
  (drgnx-ai-onboard-test--with
    (make-directory (concat root "proj/.drgnx") t)
    (with-temp-file (concat root "proj/.drgnx/ai.eld")
      (prin1 '(:version 1 :roles ((chat (theirs . "paid/m")) (edit (theirs . "paid/m")) (complete (theirs . "paid/m")))) (current-buffer)))
    (let ((default-directory (concat root "proj/")))
      ;; the project's route is what the roles use here …
      (should (equal (drgnx-ai-role 'chat) '((theirs . "paid/m"))))
      (let ((r (drgnx-onboard--ai-found '(:interactive nil))))
        (should (memq (car r) '(ok warn)))
        ;; … but what the step wrote into ai.eld is the found provider on the user's own chain
        (dolist (role '(complete edit chat))
          (should-not (assq 'theirs (drgnx-ai-onboard-test--user-chain root role)))
          (should (assq 'o (drgnx-ai-onboard-test--user-chain root role)))))
      (drgnx-onboard--put-first 'chat '(o . "llama3:8b"))
      (should-not (assq 'theirs (drgnx-ai-onboard-test--user-chain root 'chat)))
      (should (equal (car (drgnx-ai-onboard-test--user-chain root 'chat)) '(o . "llama3:8b"))))))

;;;; Setting AI up: the room, the models, Ollama, LM Studio, OpenRouter

(defun drgnx-ai-onboard-test--script (file text)
  (write-region (concat "#!/bin/sh\n" text) nil file nil 'silent)
  (set-file-modes file #o755))

(defun drgnx-ai-onboard-test--slurp (file)
  (if (file-exists-p file) (with-temp-buffer (insert-file-contents file) (buffer-string)) ""))

(defconst drgnx-ai-onboard-test--ollama-answers
  '((:path "/api/tags" :body "{\"models\":[]}")
    (:path "/api/generate" :body "{\"response\":\"ok\"}")
    (:path "/api/chat" :body "{\"message\":{\"content\":\"OK\"}}")
    (:path "/api/embed" :body "{\"embeddings\":[[0.6,0.8]]}"))
  "What the fake Ollama serves: no model listed (nothing works before the step pulls).")

(defconst drgnx-ai-onboard-test--openai-answers
  '((:path "/v1/models" :body "{\"data\":[]}")
    (:path "/v1/chat/completions" :body "{\"choices\":[{\"message\":{\"content\":\"OK\"}}]}")
    (:path "/v1/completions" :body "{\"choices\":[{\"text\":\"ok\"}]}")
    (:path "/v1/embeddings" :body "{\"data\":[{\"index\":0,\"embedding\":[0.6,0.8]}]}")
    (:path "/or/v1/chat/completions" :body "{\"choices\":[{\"message\":{\"content\":\"OK\"}}]}")
    (:path "/or/v1/completions" :body "{\"choices\":[{\"text\":\"ok\"}]}"))
  "What the fake LM Studio serves (OpenRouter too, under /or).")

(defmacro drgnx-ai-onboard-test--with-mac (answers &rest body)
  "BODY on a pretend Mac (16 GiB) where no AI is set up yet.  ROOT is a temp dir holding HOME, the config, state
and data dirs; BIN, first on the path, has fake `brew', `sysctl', `open' and `security' — `brew install ollama'
puts a fake `ollama' there, `open -a \"LM Studio\"' a fake lms in ~/.lmstudio/bin; each logs its arguments to
CALLS.  `ollama serve' and `lms server start' start the mock model on PORT answering ANSWERS (requests in LLM-LOG);
the presets ollama, lmstudio and openrouter all point at PORT.  Jobs run detached; every job and the mock end
with BODY."
  (declare (indent 1))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-ai-setup" t)))
          (bin (concat root "bin/")) (tpl (concat root "tpl/")) (calls (concat root "calls"))
          (port (+ 20000 (random 20000))) (script (concat root "llm.eld")) (llm-log (concat root "llm.log"))
          (url (format "http://127.0.0.1:%d" port))
          (process-environment (append (list (concat "HOME=" root "home") (concat "DRGNX_CONFIG_DIR=" root "config")
                                             (concat "XDG_STATE_HOME=" root "state") (concat "DRGNX_DATA_DIR=" root "data")
                                             "DRGNX_JOBS_LAUNCHER=detached" "OPENROUTER_API_KEY"
                                             (concat "PATH=" bin ":" (getenv "PATH")))
                                       process-environment))
          (exec-path (cons bin exec-path))
          (drgnx-ai--security-program (concat bin "security"))
          (drgnx-ai-presets `((openrouter :name "OpenRouter" :kind openai :url ,(concat url "/or/v1") :key-env "OPENROUTER_API_KEY"
                                          :caps (chat fim embed))
                              (ollama :name "Ollama" :kind ollama :url ,url :caps (chat fim embed))
                              (lmstudio :name "LM Studio" :kind openai :url ,(concat url "/v1") :caps (chat fim embed))))
          (drgnx-ai-detected nil) (auth-sources nil) (drgnx-ai--keys (make-hash-table :test #'eq))
          (drgnx-modules--state nil) (drgnx-ai--ensure-time nil) (drgnx-onboard--progress nil)
          (mock-cmd (format "env MOCK_LLM_SERVE=1 MOCK_LLM_PORT=%d MOCK_LLM_SCRIPT=%s MOCK_LLM_LOG=%s MOCK_LLM_PARENT=%d %s --batch -Q -l %s"
                            port script llm-log (emacs-pid)
                            (shell-quote-argument (expand-file-name invocation-name invocation-directory))
                            (shell-quote-argument mock-llm--file)))
          (log-line (lambda (name) (format "printf '%%s\\n' \"%s $*\" >> %s\n" name calls)))
          ;; a download of $M: FAKE_PULL_FAIL names the model that fails
          (pull "echo \"pulling $M\"; if [ \"$M\" = \"$FAKE_PULL_FAIL\" ]; then echo 'Error: max retries exceeded'; exit 1; fi; echo success"))
     (ignore url)
     (unwind-protect
         (progn
           (make-directory bin t) (make-directory tpl t) (make-directory (concat root "home") t) (make-directory (concat root "config") t)
           (with-temp-file script (prin1 ,answers (current-buffer)))
           (drgnx-ai-onboard-test--script
            (concat tpl "ollama")
            (concat (funcall log-line "ollama")
                    "case \"$1\" in\n serve) trap '' PIPE; echo $$ > " root "mock.pid; exec " mock-cmd " ;;\n pull) M=$2; " pull ";;\nesac\n"))
           (drgnx-ai-onboard-test--script
            (concat tpl "lms")
            (concat (funcall log-line "lms")
                    "case \"$1\" in\n server) (trap '' PIPE; exec " mock-cmd ") & echo $! > " root "mock.pid; echo 'Server started on port 1234';;\n"
                    " get) M=$3; " pull ";;\nesac\n"))
           (drgnx-ai-onboard-test--script
            (concat bin "brew")
            (concat (funcall log-line "brew") "case \"$*\" in\n 'install ollama') echo 'Pouring ollama'; cp " tpl "ollama " bin "ollama;;\nesac\n"))
           (drgnx-ai-onboard-test--script
            (concat bin "open")
            (concat (funcall log-line "open") "[ -n \"$FAKE_NO_LMS\" ] && exit 0\nmkdir -p \"$HOME/.lmstudio/bin\" && cp " tpl "lms \"$HOME/.lmstudio/bin/lms\"\n"))
           (drgnx-ai-onboard-test--script
            (concat bin "sysctl")
            (concat "[ \"$2\" = hw.memsize ] && { echo ${FAKE_MEMSIZE:-17179869184}; exit 0; }\n"
                    "[ \"$2\" = hw.optional.arm64 ] && { echo ${FAKE_ARM64:-1}; exit 0; }\nexit 1\n"))
           (drgnx-ai-onboard-test--script
            (concat bin "security")
            (concat (funcall log-line "security") "cat > " root "security.stdin\n"))
           (drgnx-ai-onboard-test--script (concat bin "fake-serve") (concat (funcall log-line "fake-serve") "exec sleep 30\n"))
           (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'macos)))
             ,@body))
       (require 'drgnx-jobs)
       (dolist (j (drgnx-jobs-list)) (drgnx-jobs-stop (plist-get j :id)))
       (let ((pid (string-to-number (string-trim (drgnx-ai-onboard-test--slurp (concat root "mock.pid"))))))
         (when (and (> pid 0) (process-attributes pid)) (signal-process pid 'SIGTERM)))
       (delete-directory root t))))

(defun drgnx-ai-onboard-test--calls (calls)
  (split-string (drgnx-ai-onboard-test--slurp calls) "\n" t))

(defun drgnx-ai-onboard-test--answer (prompts)
  "A `completing-read' answering from PROMPTS ((REGEXP . ANSWER)…); any other question is an error."
  (lambda (prompt &rest _)
    (or (cdr (seq-find (lambda (p) (string-match-p (car p) prompt)) prompts))
        (error "Unexpected question: %s" prompt))))

(ert-deftest drgnx-ai/room-on-apple-silicon ()
  ;; unified memory: two thirds of the RAM is the room models get
  (let* ((bin (file-name-as-directory (make-temp-file "drgnx-ai-sysctl" t)))
         (exec-path (cons bin exec-path))
         (process-environment (cons (concat "PATH=" bin ":" (getenv "PATH")) process-environment)))
    (unwind-protect
        (progn
          (drgnx-ai-onboard-test--script (concat bin "sysctl")
                                         (concat "[ \"$2\" = hw.memsize ] && { echo $FAKE_MEMSIZE; exit 0; }\n"
                                                 "[ \"$2\" = hw.optional.arm64 ] && [ -n \"$FAKE_ARM64\" ] && { echo $FAKE_ARM64; exit 0; }\nexit 1\n"))
          (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'macos)))
            (let ((process-environment (append '("FAKE_MEMSIZE=17179869184" "FAKE_ARM64=1") process-environment)))
              (should (equal (drgnx-ai-vram) '(:total 10922 :used 0 :unified t))))
            (let ((process-environment (append '("FAKE_MEMSIZE=8589934592" "FAKE_ARM64=1") process-environment)))
              (should (equal (drgnx-ai-vram) '(:total 5461 :used 0 :unified t))))))
      (delete-directory bin t))))

(ert-deftest drgnx-ai/intel-mac-is-not-unified ()
  ;; an Intel Mac's RAM is not GPU memory: a 7B model would run on the CPU.  No room is claimed (the smallest models)
  (let* ((bin (file-name-as-directory (make-temp-file "drgnx-ai-sysctl" t)))
         (exec-path (cons bin exec-path))
         (process-environment (cons (concat "PATH=" bin ":" (getenv "PATH")) process-environment)))
    (unwind-protect
        (progn
          (drgnx-ai-onboard-test--script (concat bin "sysctl")
                                         (concat "[ \"$2\" = hw.memsize ] && { echo $FAKE_MEMSIZE; exit 0; }\n"
                                                 "[ \"$2\" = hw.optional.arm64 ] && [ -n \"$FAKE_ARM64\" ] && { echo $FAKE_ARM64; exit 0; }\nexit 1\n"))
          (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'macos)))
            (dolist (arm64 '("FAKE_ARM64=0" "FAKE_ARM64="))        ; arm64 0, or no such key (older Intel Macs)
              (let ((process-environment (append (list "FAKE_MEMSIZE=34359738368" arm64) process-environment)))
                (should-not (plist-get (drgnx-ai-vram) :unified))
                (should-not (drgnx-ai-vram))))))
      (delete-directory bin t))))

(ert-deftest drgnx-ai/default-models-fit-the-room ()
  (should (equal (drgnx-ai-default-models 10922)
                 '((complete . "qwen2.5-coder:1.5b") (edit . "qwen2.5-coder:7b") (chat . "qwen2.5-coder:7b"))))
  (should (equal (drgnx-ai-default-models 5461)
                 '((complete . "qwen2.5-coder:1.5b") (edit . "qwen2.5-coder:3b") (chat . "qwen2.5-coder:3b"))))
  (should (equal (drgnx-ai-default-models 3000)
                 '((complete . "qwen2.5-coder:1.5b") (edit . "qwen2.5-coder:1.5b") (chat . "qwen2.5-coder:1.5b"))))
  (should (equal (drgnx-ai-default-models nil) (drgnx-ai-default-models 0)))
  ;; LM Studio: the same models under the names it serves them by
  (should (equal (drgnx-ai-default-models 10922 'lmstudio)
                 '((complete . "qwen2.5-coder-1.5b-instruct") (edit . "qwen2.5-coder-7b-instruct") (chat . "qwen2.5-coder-7b-instruct")))))

(ert-deftest drgnx-onboard/ollama-is-installed-started-pulled-and-tested ()
  (drgnx-ai-onboard-test--with-mac drgnx-ai-onboard-test--ollama-answers
    (cl-letf* ((shown nil)
               ((symbol-function 'completing-read)
                (drgnx-ai-onboard-test--answer '(("Set up AI with" . "ollama"))))
               ((symbol-function 'y-or-n-p) (lambda (&rest _) t))
               ((symbol-function 'drgnx-onboard--refresh-welcome)   ; what the Welcome's row says, each time it changes
                (lambda () (push (cdr drgnx-onboard--progress) shown))))
      (let ((r (drgnx-onboard--ai-step '(:interactive t))))
        (should (equal (drgnx-ai-onboard-test--calls calls)
                       '("brew install ollama" "ollama serve"
                         "ollama pull qwen2.5-coder:1.5b" "ollama pull qwen2.5-coder:7b" "ollama pull nomic-embed-text")))
        ;; the row is never empty while it works, and always says how to stop
        (should (member "Starting Ollama… — C-g stops" shown))
        (should (member "Testing every feature… — C-g stops" shown))
        (should (seq-every-p (lambda (s) (string-suffix-p " — C-g stops" s)) (delq nil shown)))
        (should-not drgnx-onboard--progress)                            ; and cleared at the end
        ;; the runner drgnx starts again after a restart
        (should (equal (drgnx-ai-managed) `(ollama :start (,(concat bin "ollama") "serve") :name "Ollama")))
        (should (equal (car (drgnx-ai-role 'complete)) '(ollama . "qwen2.5-coder:1.5b")))
        (should (equal (car (drgnx-ai-role 'edit)) '(ollama . "qwen2.5-coder:7b")))
        (should (equal (car (drgnx-ai-role 'chat)) '(ollama . "qwen2.5-coder:7b")))
        (should (equal (car (drgnx-ai-role 'embed)) '(ollama . "nomic-embed-text")))
        (should (eq (car r) 'ok))
        (dolist (role '("complete" "edit" "chat" "embed"))
          (should (string-match-p (concat role ": ollama/[^ ]+ answered") (cadr r))))
        (should (string-match-p "Ask the Codebase answered" (cadr r)))
        (let ((asked (drgnx-ai-onboard-test--slurp llm-log)))
          (should (string-search "POST /api/generate" asked))           ; complete
          (should (string-search "POST /api/embed" asked))              ; embed
          (should (string-search "Excerpts:" asked)))                   ; Ask: the retriever's snippets went to the model
        ;; the server stays: a drgnx job (not at login)
        (should (seq-find (lambda (j) (and (equal (plist-get j :command) (list (concat bin "ollama") "serve"))
                                           (eq (plist-get j :status) 'running)))
                          (drgnx-jobs-list)))))))

(ert-deftest drgnx-onboard/lm-studio-is-set-up-the-same-way ()
  (drgnx-ai-onboard-test--with-mac drgnx-ai-onboard-test--openai-answers
    (cl-letf (((symbol-function 'completing-read)
               (drgnx-ai-onboard-test--answer '(("Set up AI with" . "lmstudio"))))
              ((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
      (let ((r (drgnx-onboard--ai-step '(:interactive t))))
        ;; lms comes with the app's first start: drgnx opens LM Studio once
        (should (equal (drgnx-ai-onboard-test--calls calls)
                       (list "brew install --cask lm-studio" "open -a LM Studio" "lms server start"
                             (concat "lms get -y " (nth 2 (assoc "qwen2.5-coder:1.5b" drgnx-ai-lmstudio-models)))
                             (concat "lms get -y " (nth 2 (assoc "qwen2.5-coder:7b" drgnx-ai-lmstudio-models)))
                             (concat "lms get -y " (nth 2 (assoc "nomic-embed-text" drgnx-ai-lmstudio-models))))))
        (should (equal (car (drgnx-ai-role 'complete)) '(lmstudio . "qwen2.5-coder-1.5b-instruct")))
        (should (equal (car (drgnx-ai-role 'chat)) '(lmstudio . "qwen2.5-coder-7b-instruct")))
        (should (equal (car (drgnx-ai-role 'embed)) '(lmstudio . "text-embedding-nomic-embed-text-v1.5")))
        (should (eq (car r) 'ok))
        (should (string-match-p "Ask the Codebase answered" (cadr r)))))))

(ert-deftest drgnx-onboard/lm-studio-without-lms-says-what-to-do ()
  (drgnx-ai-onboard-test--with-mac drgnx-ai-onboard-test--openai-answers
    (let ((process-environment (cons "FAKE_NO_LMS=1" process-environment)) (drgnx-onboard-lms-wait 1))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
        (let ((r (drgnx-onboard--ai-setup 'lmstudio '(:interactive t))))
          (should (eq (car r) 'fail))
          (should (string-match-p "Open LM Studio once" (cadr r)))
          (should (string-match-p "run this step again" (cadr r))))))))

(ert-deftest drgnx-onboard/openrouter-key-goes-to-the-keychain ()
  (drgnx-ai-onboard-test--with-mac drgnx-ai-onboard-test--openai-answers
    (let ((mock (drgnx-ai-test-mock-llm port script llm-log)) (prompted 0))
      (unwind-protect
          (let ((system-type 'darwin) (noninteractive nil))          ; the drgnx app: the Keychain may be used
            (cl-letf (((symbol-function 'completing-read)
                       (drgnx-ai-onboard-test--answer '(("Set up AI with" . "openrouter"))))
                      ((symbol-function 'read-passwd) (lambda (&rest _) (cl-incf prompted) "sk-or-test-123"))
                      ((symbol-function 'auth-source-search)        ; the Keychain gives the key back, once stored
                       (lambda (&rest _) (and (file-exists-p (concat root "security.stdin"))
                                              (list (list :secret "sk-or-test-123"))))))
              (let ((r (drgnx-onboard--ai-step '(:interactive t))))
                (should (= prompted 1))
                (should (string-search "sk-or-test-123" (drgnx-ai-onboard-test--slurp (concat root "security.stdin"))))
                (should-not (string-search "sk-or-test-123" (drgnx-ai-onboard-test--slurp calls)))   ; never in argv
                (dolist (role '(complete edit chat)) (should (eq (car (car (drgnx-ai-role role))) 'openrouter)))
                (should (equal (drgnx-ai-role 'embed) '((tei))))            ; no embeddings there: step 5's
                (should (string-match-p "semantic search needs a local model or TEI" (cadr r)))
                (should (string-match-p "Ask the Codebase answered" (cadr r)))
                (should (eq (car r) 'ok))
                (should-not (string-search "sk-or-test-123" (cadr r)))
                (should-not (string-search "sk-or-test-123" (drgnx-ai-onboard-test--slurp (concat root "config/ai.eld")))))))
        (delete-process mock)))))

(ert-deftest drgnx-ai-onboard/cli-exit-stops-the-job ()
  ;; `drgnx onboard' in batch: while a job is waited on, ending Emacs (Ctrl-C) stops the job; the entry is gone
  ;; once the wait is over.
  (drgnx-ai-onboard-test--with-mac nil
    (should noninteractive)
    (let ((before kill-emacs-hook) (during nil) (r nil))
      (run-at-time 1 nil (lambda ()
                           (setq during kill-emacs-hook)
                           (dolist (f (seq-difference kill-emacs-hook before)) (funcall f))))   ; what exiting runs
      (setq r (drgnx-onboard--job "Sleeping" (list "sleep" "30") 15))
      (should (> (length during) (length before)))
      (should (equal kill-emacs-hook before))
      (should (eq (car r) 'fail))
      (should-not (seq-find (lambda (j) (eq (plist-get j :status) 'running)) (drgnx-jobs-list))))))

(defvar drgnx-ai-onboard-test--job-what nil "The job `drgnx-onboard--job' is waiting on (the test's view).")

(ert-deftest drgnx-ai-onboard/pull-has-no-hour-limit ()
  ;; A model download (and the full-ai package sync) waits without the one-hour cap: C-g stops it, the progress shows.
  (drgnx-ai-onboard-test--with-mac drgnx-ai-onboard-test--ollama-answers
    (let ((waits nil) (job (symbol-function 'drgnx-onboard--job)) (until (symbol-function 'drgnx-onboard--until)))
      (cl-letf (((symbol-function 'completing-read) (drgnx-ai-onboard-test--answer '(("Set up AI with" . "ollama"))))
                ((symbol-function 'y-or-n-p) (lambda (&rest _) t))
                ((symbol-function 'drgnx-onboard--job)
                 (lambda (what &rest args)
                   (let ((drgnx-ai-onboard-test--job-what what)) (apply job what args))))
                ((symbol-function 'drgnx-onboard--until)
                 (lambda (pred secs)
                   (push (cons drgnx-ai-onboard-test--job-what secs) waits)
                   (funcall until pred secs))))
        (drgnx-onboard--ai-step '(:interactive t)))
      (let ((pulls (seq-filter (lambda (w) (string-prefix-p "Downloading" (or (car w) ""))) waits)))
        (should (= (length pulls) 3))
        (dolist (w pulls) (should (or (null (cdr w)) (>= (cdr w) (* 6 3600)))))))))

(ert-deftest drgnx-ai-onboard/the-package-sync-has-no-hour-limit ()
  (let ((seen nil))
    (cl-letf (((symbol-function 'drgnx-onboard--job) (lambda (_what _command &optional secs) (setq seen (list secs)) 'ok)))
      (drgnx-onboard--sync-job))
    (should (equal seen '(:none)))))

(ert-deftest drgnx-ai-onboard/estimate-skips-models-present ()
  ;; A re-run's "about N GB to download" counts only the models the provider does not list yet.
  (drgnx-ai-onboard-test--with-mac drgnx-ai-onboard-test--ollama-answers
    (let* ((names (delete-dups (mapcar #'cdr (drgnx-onboard--local-models)))) (prompts nil))
      (should (> (length names) 1))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (p) (push p prompts) nil)))
        (setq drgnx-ai-detected nil)
        (drgnx-onboard--local-setup 'ollama '(:interactive t))
        (setq drgnx-ai-detected `((ollama :up t :models ,(append (remove (nth 1 names) names) '("other:1b")))))   ; one missing
        (drgnx-onboard--local-setup 'ollama '(:interactive t))
        (setq drgnx-ai-detected `((ollama :up t :models ,(mapcar (lambda (n) (concat n ":latest")) names))))
        (drgnx-onboard--local-setup 'ollama '(:interactive t)))
      (let ((gb (mapcar (lambda (p) (and (string-match "about \\([0-9.]+\\) GB" p) (string-to-number (match-string 1 p))))
                        (nreverse prompts))))
        (should (> (nth 0 gb) (nth 1 gb) 0.0))          ; fewer to download than from nothing, still some
        (should (= (nth 2 gb) 0.0))))))                    ; all there (also as name:latest): nothing

(ert-deftest drgnx-ai-onboard/last-line-has-no-escapes ()
  ;; A progress bar's last state, without ANSI escapes or the carriage-return redraws before it; only the end of a
  ;; big log is read.
  (let* ((dir (file-name-as-directory (make-temp-file "drgnx-lastline" t)))
         (log (concat dir "log")))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-jobs--dir) (lambda (_id) dir)))
          (write-region "pulling manifest\n\e[?25l\e[2K\rpulling 10%\r\e[2K\rpulling 40%\n" nil log nil 'silent)
          (should (equal (drgnx-onboard--last-line "x") "pulling 40%"))
          (write-region "\e[1m\e[32mdone\e[0m\n" nil log nil 'silent)
          (should (equal (drgnx-onboard--last-line "x") "done"))
          ;; a log of megabytes: the end is read, not the whole file
          (write-region (concat (make-string 3000000 ?x) "\nlast words\n") nil log nil 'silent)
          (let ((read 0))
            (advice-add 'insert-file-contents :filter-return (lambda (r) (cl-incf read (cadr r)) r) '((name . lastline-count)))
            (unwind-protect (should (equal (drgnx-onboard--last-line "x") "last words"))
              (advice-remove 'insert-file-contents 'lastline-count))
            (should (<= read 8192))))
      (delete-directory dir t))))

(ert-deftest drgnx-ai-onboard/typed-key-cleared-and-env-noted ()
  ;; The string `read-passwd' returned is zeroed once the key is stored (the in-memory key is a copy); with
  ;; OPENROUTER_API_KEY set the environment's key wins over the stored one, and the result says so.
  (drgnx-ai-onboard-test--with-mac drgnx-ai-onboard-test--openai-answers
    (let ((mock (drgnx-ai-test-mock-llm port script llm-log)) (typed nil))
      (unwind-protect
          (let ((system-type 'darwin) (noninteractive nil)
                (process-environment (cons "OPENROUTER_API_KEY=sk-env-456" process-environment)))
            (cl-letf (((symbol-function 'read-passwd) (lambda (&rest _) (setq typed (copy-sequence "sk-or-test-123"))))
                      ((symbol-function 'auth-source-search)
                       (lambda (&rest _) (and (file-exists-p (concat root "security.stdin"))
                                              (list (list :secret "sk-or-test-123"))))))
              (let ((r (drgnx-onboard--ai-setup 'openrouter '(:interactive t))))
                (should (string-search "sk-or-test-123" (drgnx-ai-onboard-test--slurp (concat root "security.stdin"))))
                (should (equal typed (make-string (length typed) 0)))      ; cleared, not just dropped
                (should (equal (drgnx-ai-key 'openrouter) "sk-env-456"))
                (should (string-match-p "OPENROUTER_API_KEY is set in the environment, which wins over the stored key" (cadr r)))
                (should-not (string-search "sk-env-456" (cadr r))))))
        (delete-process mock)))))

(ert-deftest drgnx-onboard/openrouter-from-the-cli-asks-for-no-key ()
  (drgnx-ai-onboard-test--with-mac drgnx-ai-onboard-test--openai-answers
    (cl-letf (((symbol-function 'read-passwd) (lambda (&rest _) (error "Asked for a key in batch"))))
      (let ((r (drgnx-onboard--ai-setup 'openrouter '(:interactive t))))     ; `drgnx onboard' runs in batch
        (should (string-match-p "set OPENROUTER_API_KEY for the CLI, or run this step in the drgnx app" (cadr r)))
        (should-not (file-exists-p (concat root "security.stdin")))))))

(ert-deftest drgnx-onboard/a-failed-download-says-how-to-retry ()
  (drgnx-ai-onboard-test--with-mac drgnx-ai-onboard-test--ollama-answers
    (cl-letf (((symbol-function 'completing-read)
               (drgnx-ai-onboard-test--answer '(("Keep" . "Change") ("Set up AI with" . "ollama"))))
              ((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
      (let ((r (let ((process-environment (cons "FAKE_PULL_FAIL=qwen2.5-coder:7b" process-environment)))
                 (car (drgnx-onboard-run :only '(ai))))))
        (should (eq (nth 1 r) 'fail))
        (should (string-match-p "qwen2\\.5-coder:7b" (nth 2 r)))
        (should (string-match-p "run the step again" (nth 2 r)))
        (should (string-match-p "max retries exceeded" (nth 2 r)))         ; why, from its log
        (should-not (equal (car (drgnx-ai-role 'edit)) '(ollama . "qwen2.5-coder:7b"))))
      ;; again, the download working now: no second install or server; ok
      (delete-file calls)
      (let ((r (car (drgnx-onboard-run :only '(ai)))))
        (should (eq (nth 1 r) 'ok))
        (should-not (seq-find (lambda (c) (string-prefix-p "brew" c)) (drgnx-ai-onboard-test--calls calls)))
        (should-not (member "ollama serve" (drgnx-ai-onboard-test--calls calls)))
        (should (member "ollama pull qwen2.5-coder:7b" (drgnx-ai-onboard-test--calls calls)))
        (should (equal (car (drgnx-ai-role 'edit)) '(ollama . "qwen2.5-coder:7b")))))))

(ert-deftest drgnx-onboard/non-interactive-installs-nothing ()
  (drgnx-ai-onboard-test--with-mac drgnx-ai-onboard-test--ollama-answers
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) (error "Asked")))
              ((symbol-function 'completing-read) (lambda (&rest _) (error "Asked"))))
      (let ((r (let ((inhibit-interaction t)) (drgnx-onboard--ai-step '(:interactive nil)))))
        (should (memq (car r) '(info warn)))
        (should (string-match-p "brew install ollama" (cadr r)))          ; what would set it up
        (should (string-match-p "ollama pull qwen2.5-coder:7b" (cadr r))))
      (dolist (tool '(ollama lmstudio openrouter))
        (should (memq (car (drgnx-onboard--ai-setup tool '(:interactive nil))) '(info warn))))
      (should (equal (drgnx-ai-onboard-test--calls calls) nil))         ; nothing ran, nothing downloaded
      (should-not (drgnx-jobs-list))
      ;; Linux: Ollama's installer, with its sudo said
      (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'linux)))
        (should (string-match-p "curl -fsSL https://ollama.com/install.sh | sh.*sudo"
                                (cadr (drgnx-onboard--ai-setup 'ollama '(:interactive nil)))))))))

(ert-deftest drgnx-onboard/chat-needs-its-module ()
  ;; the ide preset leaves extra/llm (gptel) off: a chat model that answers is not Chat yet
  (drgnx-ai-onboard-test--with-mac drgnx-ai-onboard-test--openai-answers
    (let ((mock (drgnx-ai-test-mock-llm port script llm-log))
          (process-environment (cons "OPENROUTER_API_KEY=sk-or-test-123" process-environment)))
      (unwind-protect
          (progn
            (drgnx-modules-write-state (list :disabled '(extra/llm)))
            (let ((r (drgnx-onboard--ai-setup 'openrouter '(:interactive nil))))
              (should (eq (car r) 'warn))
              (should (string-match-p "Chat needs module extra/llm (Preferences: Modules)" (cadr r)))
              (should (drgnx-module-disabled-p 'extra/llm)))
            (let* ((asked nil)
                   (r (cl-letf (((symbol-function 'y-or-n-p) (lambda (prompt) (push prompt asked) t))
                                ((symbol-function 'drgnx-onboard--job) (lambda (&rest _) 'ok)))
                        (drgnx-onboard--ai-setup 'openrouter '(:interactive t)))))
              (should (equal asked '("Turn on Chat (module extra/llm)? ")))
              (should-not (drgnx-module-disabled-p 'extra/llm))
              (should (eq (car r) 'ok))
              (should (string-match-p "Chat (module extra/llm) turned on" (cadr r)))))
        (delete-process mock)))))

(ert-deftest drgnx-onboard/chat-turned-on-installs-its-package ()
  ;; Turning Chat on installs gptel (the Look step's drgnx sync job) when drgnx's packages lack it; installed but
  ;; not loaded in this Emacs, it is on from the next start.  Whether it is installed: drgnx's elpa, not load-path.
  (let* ((root (file-name-as-directory (make-temp-file "drgnx-chat" t)))
         (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" root "config") (concat "XDG_STATE_HOME=" root "state")
                                            (concat "DRGNX_DATA_DIR=" root "data"))
                                      process-environment))
         (drgnx-modules--state nil) (drgnx-onboard--restart-needed nil) (jobs nil) (done 'ok))
    (unwind-protect
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t))
                  ((symbol-function 'locate-library) (lambda (&rest _) "/somewhere/gptel.el"))   ; never asked
                  ((symbol-function 'drgnx-onboard--job) (lambda (what command &rest _) (push (cons what command) jobs) done)))
          (make-directory (concat root "config") t)
          (drgnx-modules-write-state (list :disabled '(extra/llm)))
          (let ((r (drgnx-onboard--chat-module '(:interactive t))))
            (should (car r))
            (should-not (drgnx-module-disabled-p 'extra/llm))
            (should (equal (caar jobs) "Installing the packages"))
            (should (equal (last (cdar jobs) 2) (list (expand-file-name "bin/drgnx" drgnx-dir) "sync")))
            (should (string-match-p "loads at drgnx's next start" (cdr r))))      ; batch: no Finish offer promised
          (should drgnx-onboard--restart-needed)
          ;; on, not installed, without interaction: says how; nothing runs
          (setq jobs nil)
          (let ((r (drgnx-onboard--chat-module '(:interactive nil))))
            (should (string-match-p "not installed yet: run drgnx sync" (cdr r)))
            (should-not jobs))
          ;; installed, not loaded in this Emacs: on from the next start, nothing installed again
          (make-directory (expand-file-name "gptel-0.9.9" (drgnx-elpa-dir)) t)
          (let ((r (drgnx-onboard--chat-module '(:interactive t))))
            (should (car r))
            (should-not jobs)
            (should (string-match-p "loads at drgnx's next start" (cdr r))))
          (drgnx-modules-write-state (list :disabled '(extra/llm)))
          (drgnx-onboard--chat-module '(:interactive t))
          (should-not jobs)
          ;; the install fails: Chat is not ready, and the result says why
          (delete-directory (drgnx-elpa-dir) t)
          (drgnx-modules-write-state (list :disabled '(extra/llm)))
          (setq done '(fail "Installing the packages failed (exit 1): no network" nil))
          (let ((r (drgnx-onboard--chat-module '(:interactive t))))
            (should-not (car r))
            (should (string-match-p "no network" (cdr r)))
            (should (string-match-p "drgnx sync" (cdr r)))))
      (delete-directory root t))))

(defun drgnx-ai-onboard-test--serving (command)
  "Running jobs whose command is COMMAND."
  (seq-filter (lambda (j) (and (eq (plist-get j :status) 'running) (equal (plist-get j :command) command))) (drgnx-jobs-list)))

(defun drgnx-ai-onboard-test--settle (pred &optional secs)
  "Wait until PRED, at most SECS (2): the probe and the start are asynchronous."
  (let ((deadline (+ (float-time) (or secs 2))))
    (while (and (not (funcall pred)) (< (float-time) deadline)) (accept-process-output nil 0.05))
    (funcall pred)))

(ert-deftest drgnx-ai/ensure-local-starts-the-runner-when-it-is-down ()
  (drgnx-ai-onboard-test--with-mac drgnx-ai-onboard-test--ollama-answers
    (let ((noninteractive nil) (serve (list (concat bin "fake-serve") "serve")))
      (cl-letf (((symbol-function 'message) #'ignore))
        (drgnx-ai-set-managed 'ollama serve "Ollama")
        ;; down, no job: started
        (drgnx-ai-ensure-local)
        (should (drgnx-ai-onboard-test--settle (lambda () (drgnx-ai-onboard-test--serving serve)) 5))
        ;; a job runs it already: not a second one
        (setq drgnx-ai--ensure-time nil)
        (drgnx-ai-ensure-local)
        (drgnx-ai-onboard-test--settle #'ignore 1.5)
        (should (= 1 (length (drgnx-ai-onboard-test--serving serve))))
        ;; it answers: nothing started
        (dolist (j (drgnx-jobs-list)) (drgnx-jobs-stop (plist-get j :id)))
        (should (drgnx-ai-onboard-test--settle (lambda () (null (drgnx-ai-onboard-test--serving serve)))))
        (let ((mock (drgnx-ai-test-mock-llm port script)))
          (unwind-protect
              (progn (setq drgnx-ai--ensure-time nil)
                     (drgnx-ai-ensure-local)
                     (drgnx-ai-onboard-test--settle #'ignore 1.5)
                     (should-not (drgnx-ai-onboard-test--serving serve)))
            (delete-process mock)))))))

(ert-deftest drgnx-ai/a-refused-request-starts-the-runner-at-most-once-a-minute ()
  (drgnx-ai-onboard-test--with-mac drgnx-ai-onboard-test--ollama-answers
    (let ((noninteractive nil) (serve (list (concat bin "fake-serve") "serve"))
          (ask (lambda () (let ((done nil))
                            (drgnx-ai-request 'chat 'chat (list :messages (vector (list :role "user" :content "hi")))
                                              (lambda (_ _) (setq done t)) :chain '((ollama . "m")))
                            (drgnx-ai-onboard-test--settle (lambda () done) 5)))))
      (cl-letf (((symbol-function 'message) #'ignore))
        (drgnx-ai-set-managed 'ollama serve "Ollama")
        (funcall ask)                                       ; nothing listens: connection refused
        (should (drgnx-ai-onboard-test--settle (lambda () (drgnx-ai-onboard-test--serving serve)) 5))
        (dolist (j (drgnx-jobs-list)) (drgnx-jobs-stop (plist-get j :id)))
        (should (drgnx-ai-onboard-test--settle (lambda () (null (drgnx-ai-onboard-test--serving serve)))))
        (funcall ask)                                       ; again within the minute: left alone
        (drgnx-ai-onboard-test--settle #'ignore 1.5)
        (should-not (drgnx-ai-onboard-test--serving serve))
        ;; another provider refusing never starts it
        (setq drgnx-ai--ensure-time nil)
        (drgnx-ai--refused 'lmstudio)
        (drgnx-ai-onboard-test--settle #'ignore 1.5)
        (should-not (drgnx-ai-onboard-test--serving serve))))))

(ert-deftest drgnx-ai/ensure-local-never-waits-for-the-job ()
  ;; the probe's callback runs in a curl sentinel: it starts nothing itself, and the start does not wait for the pid
  (skip-unless (executable-find "setsid"))
  (drgnx-ai-onboard-test--with-mac drgnx-ai-onboard-test--ollama-answers
    (let ((noninteractive nil) (serve (list (concat bin "fake-serve") "serve")) (in-callback 'unset))
      (cl-letf (((symbol-function 'message) #'ignore)
                ((symbol-function 'drgnx-ai-probe)            ; nothing answers; the callback at once
                 (lambda (callback &optional _ids) (funcall callback) (setq in-callback (drgnx-jobs-list)) nil))
                ((symbol-function 'drgnx-jobs--detach)        ; the job's shell, and so its pid file, 0.7 s late
                 (lambda (line) (call-process "sh" nil 0 nil "-c" (concat "sleep 0.7; exec setsid -f sh -c " (shell-quote-argument line))))))
        (drgnx-ai-set-managed 'ollama serve "Ollama")
        (drgnx-ai-ensure-local)
        (should (null in-callback))                           ; the callback returned before any job was started
        (let* ((job (drgnx-ai-onboard-test--settle (lambda () (car (drgnx-jobs-list))) 1))
               (dir (drgnx-jobs--dir (plist-get job :id))))
          (should (equal (plist-get job :command) serve))
          (should-not (file-exists-p (expand-file-name "pid" dir)))                     ; started without waiting
          (should (drgnx-ai-onboard-test--settle
                   (lambda () (plist-get (drgnx-jobs--read (expand-file-name "job.eld" dir)) :start)) 2.5)))))))   ; stamped

(ert-deftest drgnx-ai/ensure-local-does-nothing-in-batch ()
  (drgnx-ai-onboard-test--with-mac drgnx-ai-onboard-test--ollama-answers
    (let ((probed nil))
      (drgnx-ai-set-managed 'ollama (list (concat bin "fake-serve") "serve") "Ollama")
      (cl-letf (((symbol-function 'drgnx-ai-probe) (lambda (&rest _) (setq probed t))))
        (should-not (drgnx-ai-ensure-local))
        (drgnx-ai--refused 'ollama))
      (should-not probed)
      (should-not drgnx-ai--ensure-time)
      (should-not (drgnx-jobs-list)))))

;;; ai-onboard-test.el ends here
