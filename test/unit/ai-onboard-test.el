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
          (mock nil))
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
          (drgnx-ai-presets `((openrouter :name "OpenRouter" :kind openai :url ,(concat url "/or/v1") :key-env "OPENROUTER_API_KEY"
                                          :caps (chat fim embed))
                              (ollama :name "Ollama" :kind ollama :url ,url :caps (chat fim embed))
                              (lmstudio :name "LM Studio" :kind openai :url ,(concat url "/v1") :caps (chat fim embed))))
          (drgnx-ai-detected nil) (auth-sources nil) (drgnx-ai--keys (make-hash-table :test #'eq))
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
            "[ \"$2\" = hw.memsize ] && { echo ${FAKE_MEMSIZE:-17179869184}; exit 0; }\nexit 1\n")
           (drgnx-ai-onboard-test--script
            (concat bin "security")
            (concat (funcall log-line "security") "cat > " root "security.stdin\n"))
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
                                         "[ \"$2\" = hw.memsize ] && { echo $FAKE_MEMSIZE; exit 0; }\nexit 1\n")
          (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'macos)))
            (let ((process-environment (cons "FAKE_MEMSIZE=17179869184" process-environment)))
              (should (equal (drgnx-ai-vram) '(:total 10922 :used 0 :unified t))))
            (let ((process-environment (cons "FAKE_MEMSIZE=8589934592" process-environment)))
              (should (equal (drgnx-ai-vram) '(:total 5461 :used 0 :unified t))))))
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
    (cl-letf (((symbol-function 'completing-read)
               (drgnx-ai-onboard-test--answer '(("Set up AI with" . "Ollama (local)"))))
              ((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
      (let ((r (drgnx-onboard--ai-step '(:interactive t))))
        (should (equal (drgnx-ai-onboard-test--calls calls)
                       '("brew install ollama" "ollama serve"
                         "ollama pull qwen2.5-coder:1.5b" "ollama pull qwen2.5-coder:7b" "ollama pull nomic-embed-text")))
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
               (drgnx-ai-onboard-test--answer '(("Set up AI with" . "LM Studio (local)"))))
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
                       (drgnx-ai-onboard-test--answer '(("Set up AI with" . "OpenRouter (cloud key)"))))
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

(ert-deftest drgnx-onboard/openrouter-from-the-cli-asks-for-no-key ()
  (drgnx-ai-onboard-test--with-mac drgnx-ai-onboard-test--openai-answers
    (cl-letf (((symbol-function 'read-passwd) (lambda (&rest _) (error "Asked for a key in batch"))))
      (let ((r (drgnx-onboard--ai-setup 'openrouter '(:interactive t))))     ; `drgnx onboard' runs in batch
        (should (string-match-p "set OPENROUTER_API_KEY for the CLI, or run this step in the drgnx app" (cadr r)))
        (should-not (file-exists-p (concat root "security.stdin")))))))

(ert-deftest drgnx-onboard/a-failed-download-says-how-to-retry ()
  (drgnx-ai-onboard-test--with-mac drgnx-ai-onboard-test--ollama-answers
    (cl-letf (((symbol-function 'completing-read)
               (drgnx-ai-onboard-test--answer '(("Keep" . "Change") ("Set up AI with" . "Ollama (local)"))))
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

;;; ai-onboard-test.el ends here
