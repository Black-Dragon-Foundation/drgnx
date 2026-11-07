;;; ai-onboard-test.el --- batch tests: onboarding step 4, AI providers -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: gated
(require 'ert)
(require 'drgnx-onboard)
(require 'drgnx-ai-probe)
(require 'drgnx-exec)
(require 'drgnx-settings-runtime)
(require 'drgnx-settings-agents nil t)
(require 'drgnx-records-review nil t)
(load (expand-file-name "test/fixtures/mock-llm" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/runtime-settings-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/ratatoskr-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/delivery-gate-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/handshake-fixture" drgnx-dir) nil t)

(defvar drgnx-exec--jobs)
(defvar drgnx-exec--stale)

(defmacro drgnx-ai-onboard-test--with (&rest body)
  "BODY with only provider `o' (Ollama, a mock serving two models and answering chat and fill-in-the-middle)
known: no preset, so nothing running on this machine counts; no OpenRouter key."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-ai-onboard" t)))
          (port nil) (script (concat root "llm.eld"))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" root "config") (concat "XDG_STATE_HOME=" root "state")
                                             "OPENROUTER_API_KEY")
                                       process-environment))
          (drgnx-ai-presets nil) (drgnx-ai-detected nil) (auth-sources nil) (drgnx-ai--keys (make-hash-table :test #'eq))
          (mock nil))
     (drgnx-test-runtime-settings--reset)
     (unwind-protect
         (progn
           (make-directory (concat root "config") t)
           (with-temp-file script
             (prin1 '((:path "/api/tags" :body "{\"models\":[{\"name\":\"llama3:8b\"},{\"name\":\"qwen2.5-coder:1.5b\"}]}")
                      (:path "/api/generate" :body "{\"response\":\"ok\"}")
                      (:path "/api/chat" :body "{\"message\":{\"content\":\"OK\"}}"))
                    (current-buffer)))
           (setq mock (drgnx-ai-test-mock-llm nil script)
                 port (process-get mock :port))
           (setq drgnx-ai-providers `((o :name "O" :kind ollama :url ,(format "http://127.0.0.1:%d" port) :caps (chat fim))))
           (drgnx-test-write-settings (concat root "config/settings.el") 'drgnx-ai-providers drgnx-ai-providers) ; for a child
           ,@body)
       (drgnx-test-runtime-settings--forget)
       (when mock (delete-process mock))
       (delete-directory root t))))

;; The step's own waits (the probe's, the test calls' budget) wait on curls, real children of this Emacs: inside the
;; gate no virtual time passes while one lives, so an answer comes within the budget however slow the machine.  No hub
;; runs here; the gate holds whatever a hub would say.

(ert-deftest drgnx-onboard/the-ai-step-finds-providers-sets-roles-and-tests-them ()
  :tags '(:frozen)
  (drgnx-ai-onboard-test--with
    (let (r)
      (drgnx-test-gated nil
        (setq r (drgnx-onboard--ai-step '(:interactive nil)))
        (drgnx-test-deliver-all))
      (should (eq (car r) 'ok))
      (should (equal (car (drgnx-ai-role 'complete)) '(o . "qwen2.5-coder:1.5b")))   ; a coder model fills the middle
      (should (equal (car (drgnx-ai-role 'chat)) '(o . "llama3:8b")))
      (should (string-match-p "complete: o/qwen2.5-coder:1.5b answered" (cadr r)))
      (should (string-match-p "OPENROUTER_API_KEY" (cadr r)))                        ; how to add the key: said
      (should (string-search "run this step again → Change → openrouter (keeps the key in your Keychain or keyring)" (cadr r)))
      (should-not (string-search "authinfo" (cadr r)))
      (should-not (string-search "sk-" (with-temp-buffer (insert-file-contents (concat root "config/settings.el")) (buffer-string)))))))

(ert-deftest drgnx-onboard/the-ai-step-keeps-roles-that-work ()
  :tags '(:frozen)
  (drgnx-ai-onboard-test--with
    (drgnx-test-gated nil
      (drgnx-ai-set-role 'chat '((o . "qwen2.5-coder:1.5b")))  ; the settings go to a hub, if one runs
      (drgnx-onboard--ai-step '(:interactive nil))
      (drgnx-test-deliver-all))
    (should (equal (drgnx-ai-role 'chat) '((o . "qwen2.5-coder:1.5b"))))))         ; the user's choice stays

(ert-deftest drgnx-onboard/the-ai-step-with-nothing-running-says-what-to-do ()
  :tags '(:frozen)
  (drgnx-ai-onboard-test--with
    (delete-process mock) (setq mock nil)
    (let ((r (drgnx-onboard--ai-step '(:interactive nil))))
      (should (memq (car r) '(info warn)))
      (should (string-match-p "no provider" (cadr r))))))

(ert-deftest drgnx-ai-onboard/role-written-only-after-answer ()
  :tags '(:frozen)
  ;; A provider that never answers leaves the roles (settings.el) as they were, and the three test calls share one
  ;; budget: the step ends within about the budget, not 3 ×.  Roles that ran out of time read "not tested".
  ;; The budget on the clock fixture: virtual time, which a loaded machine does not move.
  (drgnx-ai-onboard-test--with
    (drgnx-test-with-clock ()
      (let ((before (drgnx-ai-onboard-test--slurp (concat root "config/settings.el"))) (t0 (drgnx-test-clock-now)) r
            (drgnx-onboard-ai-test-budget 2))
        (cl-letf (((symbol-function 'drgnx-ai-request) (lambda (&rest _) nil)))
          (setq r (drgnx-onboard--ai-found '(:interactive nil))))
        (should (< (- (drgnx-test-clock-now) t0) 6))
        (should (= (nth 2 r) 0))
        (should (= (nth 3 r) 3))
        (should (string-match-p "not tested" (cadr r)))
        (should-not (string-match-p "did not answer" (cadr r)))
        (should (equal before (drgnx-ai-onboard-test--slurp (concat root "config/settings.el"))))))))

;; A project's ai.eld routes roles for that project only: the roles onboarding writes into the user's settings start
;; from the user's own chain, never from the project's.
(defun drgnx-ai-onboard-test--user-chain (_root role)
  (alist-get role (default-value 'drgnx-ai-roles)))

(ert-deftest drgnx-ai-onboard/a-projects-route-never-reaches-the-global-roles ()
  :tags '(:frozen)
  (drgnx-ai-onboard-test--with
    (make-directory (concat root "proj/.drgnx") t)
    (with-temp-file (concat root "proj/.drgnx/ai.eld")
      (prin1 '(:version 1 :roles ((chat (theirs . "paid/m")) (edit (theirs . "paid/m")) (complete (theirs . "paid/m")))) (current-buffer)))
    (let ((default-directory (concat root "proj/")))
      ;; the project's route is what the roles use here …
      (should (equal (drgnx-ai-role 'chat) '((theirs . "paid/m"))))
      (let (r chains)
        (drgnx-test-gated nil
          (setq r (drgnx-onboard--ai-found '(:interactive nil))
                chains (mapcar (lambda (role) (drgnx-ai-onboard-test--user-chain root role)) '(complete edit chat)))
          (drgnx-onboard--put-first 'chat '(o . "llama3:8b"))
          (drgnx-test-deliver-all))
        (should (memq (car r) '(ok warn)))
        ;; … but what the step wrote into the settings is the found provider on the user's own chain
        (dolist (chain chains)
          (should-not (assq 'theirs chain))
          (should (assq 'o chain))))
      (should-not (assq 'theirs (drgnx-ai-onboard-test--user-chain root 'chat)))
      (should (equal (car (drgnx-ai-onboard-test--user-chain root 'chat)) '(o . "llama3:8b"))))))

;; M9-6 review I1: the three calls run side by side
(defun drgnx-ai-onboard-test--slow-request (delay timers)
  "A `drgnx-ai-request' whose provider answers DELAY seconds later; the timers it starts go on the list in TIMERS (a cell)."
  (lambda (_role _kind _payload callback &rest _)
    (push (run-at-time delay nil (lambda () (funcall callback "OK" nil))) (car timers))
    nil))

(ert-deftest drgnx-ai-onboard/the-role-tests-run-side-by-side ()
  :tags '(:frozen)
  ;; A provider that takes 2.5 s per call answers all three roles within the budget: one wait, not three in a row.
  ;; FLAKY-2: on the clock fixture the provider's 2.5 s are virtual, and the budget is measured on virtual time.  The
  ;; probe's curls are real: inside the gate no virtual time passes while they live.
  (drgnx-ai-onboard-test--with
    (drgnx-test-with-clock ()
      (let ((timers (list nil)) (t0 (drgnx-test-clock-now)) r took (drgnx-onboard-ai-test-budget 8))
        (unwind-protect
            (cl-letf (((symbol-function 'drgnx-ai-request) (drgnx-ai-onboard-test--slow-request 2.5 timers)))
              (drgnx-test-gated nil
                (setq r (drgnx-onboard--ai-found '(:interactive nil))
                      took (- (drgnx-test-clock-now) t0))
                (drgnx-test-deliver-all))
              (should (< took 5.5))  ; three in a row: 7.5 s
              (should (= (nth 2 r) 3))
              (should (= (nth 3 r) 0))
              (should (eq (car r) 'ok)))
          (mapc #'cancel-timer (car timers)))))))

(ert-deftest drgnx-ai-onboard/a-slow-provider-is-not-tested-and-never-sets-ai-up ()
  :tags '(:frozen)
  ;; Calls still waiting when the budget is up read "not tested", are not counted as asked, and the interactive step
  ;; does not offer "Set up AI with" for them.
  ;; On the clock fixture: the 2 s budget and the provider's 30 s are virtual.
  (drgnx-ai-onboard-test--with
    (drgnx-test-with-clock ()
      (let ((timers (list nil)) (drgnx-onboard-ai-test-budget 2) r (before (drgnx-ai-onboard-test--slurp (concat root "config/settings.el"))))
        (unwind-protect
            (cl-letf (((symbol-function 'drgnx-ai-request) (drgnx-ai-onboard-test--slow-request 30 timers))
                      ((symbol-function 'completing-read) (lambda (&rest _) (error "asked")))
                      ((symbol-function 'y-or-n-p) (lambda (&rest _) (error "asked"))))
              (setq r (drgnx-onboard--ai-found '(:interactive t)))
              (should (equal (list (nth 2 r) (nth 3 r)) '(0 3)))
              (should (eq (car r) 'warn))
              (should (string-match-p "complete: o/qwen2.5-coder:1.5b not tested" (cadr r)))
              (let ((step (drgnx-onboard--ai-step '(:interactive t))))
                (should (eq (car step) 'warn))
                (should (string-match-p "not tested" (cadr step))))
              (should (equal before (drgnx-ai-onboard-test--slurp (concat root "config/settings.el")))))
          (mapc #'cancel-timer (car timers)))))))

(ert-deftest drgnx-ai-onboard/a-provider-that-refuses-at-once-did-not-answer ()
  :tags '(:frozen)
  (drgnx-ai-onboard-test--with
    (cl-letf (((symbol-function 'drgnx-ai-request) (lambda (_r _k _p callback &rest _) (funcall callback nil '(:error "refused")) nil)))
      (let ((r (drgnx-onboard--ai-found '(:interactive nil))))
        (should (equal (list (nth 2 r) (nth 3 r)) '(0 0)))
        (should (string-match-p "did not answer" (cadr r)))))))

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

(defun drgnx-ai-onboard-test--openrouter-in-settings ()
  "The OpenRouter preset `drgnx-ai-onboard-test--with-mac' points at the mock, in settings.el too (an entry replaces
the preset with its id): the hub's gateway takes its provider table from settings.el, so a preset bound in Lisp
alone sends the hub to the real OpenRouter (which refuses the test's key).  Before the hub starts."
  (let ((print-length nil) (print-level nil))
    (drgnx-test-runtime-settings-put (format "(drgnx-ai-providers (%S))" (assq 'openrouter drgnx-ai-presets)))))

(defun drgnx-ai-onboard-test--stop-jobs ()
  "Ask the hub to stop every running job and wait until each is over (a stopped job's process is still ending when
the hub answers, and the fixture's clean-up deleting its folder under it fails (macOS))."
  (let ((ids (delq nil (mapcar (lambda (j) (and (eq (plist-get j :status) 'running) (plist-get j :id)))
                               (drgnx-exec-list)))))
    (dolist (id ids) (drgnx-exec-stop id))
    (dolist (id ids)
      (drgnx-test-wait (lambda () (not (eq (plist-get (drgnx-exec-get id) :status) 'running))) :secs 10
                       :what "a stopped job to end"))))

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
          (port (drgnx-test-free-port)) (script (concat root "llm.eld")) (llm-log (concat root "llm.log"))
          (url (format "http://127.0.0.1:%d" port))
          (process-environment (append (list (concat "HOME=" root "home") (concat "DRGNX_CONFIG_DIR=" root "config")
                                             (concat "XDG_STATE_HOME=" root "state") (concat "DRGNX_DATA_DIR=" root "data")
                                             "OPENROUTER_API_KEY"
                                             (concat "PATH=" bin ":" (getenv "PATH")))
                                       process-environment))
          (exec-path (cons bin exec-path))
          (drgnx-ai--security-program (concat bin "security"))
          (drgnx-ai-presets `((openrouter :name "OpenRouter" :kind openai :url ,(concat url "/or/v1") :key-env "OPENROUTER_API_KEY"
                                          :caps (chat fim embed))
                              (ollama :name "Ollama" :kind ollama :url ,url :caps (chat fim embed))
                              (lmstudio :name "LM Studio" :kind openai :url ,(concat url "/v1") :caps (chat fim embed))))
          (drgnx-ai-detected nil) (auth-sources nil) (drgnx-ai--keys (make-hash-table :test #'eq))
          (drgnx-ai--ensure-time nil) (drgnx-onboard--progress nil)
          (mock-cmd (format "env MOCK_LLM_SERVE=1 MOCK_LLM_PORT=%d MOCK_LLM_SCRIPT=%s MOCK_LLM_LOG=%s MOCK_LLM_PARENT=%d %s --batch -Q -l %s"
                            port script llm-log (emacs-pid)
                            (shell-quote-argument (expand-file-name invocation-name invocation-directory))
                            (shell-quote-argument mock-llm--file)))
          (log-line (lambda (name) (format "printf '%%s\\n' \"%s $*\" >> %s\n" name calls)))
          ;; a download of $M: the file HOME/.pull-fail names the model that fails (a flag file, not a variable: a job has
          ;; the hub's environment, not this Emacs's)
          (pull "echo \"pulling $M\"; if [ \"$M\" = \"$(cat \"$HOME/.pull-fail\" 2>/dev/null)\" ]; then echo 'Error: max retries exceeded'; exit 1; fi; echo success"))
     (ignore url)
     (drgnx-test-runtime-settings--reset)          ; the roles a test sets start from the defaults, and go after
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
            (concat (funcall log-line "open") "[ -e \"$HOME/.no-lms\" ] && exit 0\nmkdir -p \"$HOME/.lmstudio/bin\" && cp " tpl "lms \"$HOME/.lmstudio/bin/lms\"\n"))
           (drgnx-ai-onboard-test--script
            (concat bin "sysctl")
            (concat "[ \"$2\" = hw.memsize ] && { echo ${FAKE_MEMSIZE:-17179869184}; exit 0; }\n"
                    "[ \"$2\" = hw.optional.arm64 ] && { echo ${FAKE_ARM64:-1}; exit 0; }\nexit 1\n"))
           (drgnx-ai-onboard-test--script
            (concat bin "security")
            ;; `-i' stdin is kept; `find-internet-password' answers with its `-w "…"' word, unquoted (the read-back)
            (concat (funcall log-line "security")
                    "case \"$1\" in\n"
                    " find-internet-password) [ -f " root "security.stdin ] || exit 44\n"
                    "   sed -n 's/.* -w \"\\(.*\\)\"$/\\1/p' " root "security.stdin | sed 's/\\\\\\(.\\)/\\1/g'; exit 0;;\n"
                    " delete-internet-password) exit 0;;\n"
                    "esac\n"
                    "cat > " root "security.stdin\n"))
           (drgnx-ai-onboard-test--script (concat bin "fake-serve") (concat (funcall log-line "fake-serve") "exec sleep 30\n"))
           (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'macos)))
             ,@body))
       (drgnx-test-runtime-settings--forget)
       (drgnx-ai-onboard-test--stop-jobs)
       (let ((pid (string-to-number (string-trim (drgnx-ai-onboard-test--slurp (concat root "mock.pid"))))))
         (when (and (> pid 0) (process-attributes pid)) (signal-process pid 'SIGTERM)))
       (delete-directory root t))))

(defmacro drgnx-ai-onboard-test--with-hub (&rest body)
  "BODY (inside `drgnx-ai-onboard-test--with-mac') with the real Ratatoskr serving ROOT, gated (its clock and
sequencer), this Emacs not connected: BODY connects inside `drgnx-test-gated' (`drgnx-ai-onboard-test--subscribe'
first), and stops its jobs there before it delivers all (`drgnx-ai-onboard-test--stop-jobs')."
  (declare (indent 0))
  ;; the fixture binds its own `bin' (Ratatoskr's program): the fakes' folder is put back inside
  `(let ((fakes bin) (drgnx-hub--presence-sent :unknown) (drgnx-hub-editor-token-hook nil)
         (drgnx-exec--jobs (make-hash-table :test #'equal)) (drgnx-exec--stale nil))
     (drgnx-test-with-ratatoskr root :gated t
                                (let ((bin fakes))
                                  ,@body))))

(defmacro drgnx-ai-onboard-test--with-mac-jobs (answers &rest body)
  "`drgnx-ai-onboard-test--with-mac', and BODY with the real Ratatoskr serving the jobs (they are the hub's):
`drgnx-ai-onboard-test--with-hub'."
  (declare (indent 1))
  `(drgnx-ai-onboard-test--with-mac ,answers
     (drgnx-ai-onboard-test--with-hub ,@body)))

(defun drgnx-ai-onboard-test--subscribe ()
  "Inside `drgnx-test-gated' (with `(:answers t)'): this Emacs connected as the ungated fixture connects it (the
provider table and keys handed over, the editor token and the held keys taken), and subscribed before anything starts
a job, so every job's end reaches it."
  (drgnx-hub-connect)
  (drgnx-hub-ensure)
  (drgnx-test-wait (lambda () (and drgnx-hub--events drgnx-hub--editor (listp (drgnx-hub-keys-held))))
                   :what "the subscription, the editor token and the held keys"))

(defun drgnx-ai-onboard-test--job-ends (n)
  "The schedule of a test whose code waits on N jobs ending, one after the other: every answer as it is due, then
each job's `exec-done' in turn.  The hub writes a job's end from the job's own task, so the gate asks it for barriers
while a step waits; until each end comes no virtual time passes."
  (cons '(:answers t) (make-list n '(sub-1 :event "exec-done"))))

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
  :tags '(:frozen)
  ;; four jobs end, in turn: the install and three downloads (the server keeps running)
  (drgnx-ai-onboard-test--with-mac-jobs drgnx-ai-onboard-test--ollama-answers
    (cl-letf* ((shown nil)
               ((symbol-function 'completing-read)
                (drgnx-ai-onboard-test--answer '(("Set up AI with" . "ollama"))))
               ((symbol-function 'y-or-n-p) (lambda (&rest _) t))
               ((symbol-function 'drgnx-onboard--refresh-welcome)   ; what the Welcome's row says, each time it changes
                (lambda () (push (cdr drgnx-onboard--progress) shown))))
      (drgnx-test-gated (drgnx-ai-onboard-test--job-ends 4)
        (drgnx-ai-onboard-test--subscribe)
        (let* ((r (drgnx-onboard--ai-step '(:interactive t)))
               (jobs (drgnx-exec-list)))
          (drgnx-ai-onboard-test--stop-jobs)
          (drgnx-test-deliver-all)
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
          (should (seq-find (lambda (j) (and (equal (plist-get j :argv) (list (concat bin "ollama") "serve"))
                                             (eq (plist-get j :status) 'running)))
                            jobs)))))))

(ert-deftest drgnx-onboard/lm-studio-is-set-up-the-same-way ()
  :tags '(:frozen)
  ;; six jobs end, in turn: the install, LM Studio's first start, `lms server start' (it starts the server and ends)
  ;; and three downloads
  (drgnx-ai-onboard-test--with-mac-jobs drgnx-ai-onboard-test--openai-answers
    (cl-letf (((symbol-function 'completing-read)
               (drgnx-ai-onboard-test--answer '(("Set up AI with" . "lmstudio"))))
              ((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
      (drgnx-test-gated (drgnx-ai-onboard-test--job-ends 6)
        (drgnx-ai-onboard-test--subscribe)
        (let ((r (drgnx-onboard--ai-step '(:interactive t))))
          (drgnx-ai-onboard-test--stop-jobs)
          (drgnx-test-deliver-all)
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
          (should (string-match-p "Ask the Codebase answered" (cadr r))))))))

(ert-deftest drgnx-onboard/lm-studio-without-lms-says-what-to-do ()
  :tags '(:frozen)
  ;; two jobs end (the install, LM Studio's first start); then the wait for lms runs out on the virtual clock
  (drgnx-ai-onboard-test--with-mac-jobs drgnx-ai-onboard-test--openai-answers
    (let ((_ (write-region "" nil (concat root "home/.no-lms") nil 'silent)) (drgnx-onboard-lms-wait 1))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
        (drgnx-test-gated (drgnx-ai-onboard-test--job-ends 2)
          (drgnx-ai-onboard-test--subscribe)
          (let ((r (drgnx-onboard--ai-setup 'lmstudio '(:interactive t))))
            (drgnx-ai-onboard-test--stop-jobs)
            (drgnx-test-deliver-all)
            (should (eq (car r) 'fail))
            (should (string-match-p "Open LM Studio once" (cadr r)))
            (should (string-match-p "run this step again" (cadr r)))))))))

(ert-deftest drgnx-onboard/openrouter-key-goes-to-the-keychain ()
  ;; binary: the key goes to the Keychain and to the hub, which alone holds it; the features are tested through it.
  ;; Every answer as it is due; the hub's events (the held keys changed) come at the end
  (drgnx-ai-onboard-test--with-mac drgnx-ai-onboard-test--openai-answers
    (drgnx-ai-onboard-test--openrouter-in-settings)
    (drgnx-ai-onboard-test--with-hub
      (let ((mock (drgnx-ai-test-mock-llm port script llm-log)) (prompted 0))
        (unwind-protect
            (let ((system-type 'darwin))
              (cl-letf (((symbol-function 'completing-read)
                         (drgnx-ai-onboard-test--answer '(("Set up AI with" . "openrouter"))))
                        ((symbol-function 'read-passwd) (lambda (&rest _) (cl-incf prompted) "sk-or-test-123"))
                        ((symbol-function 'auth-source-search)        ; the Keychain gives the key back, once stored
                         (lambda (&rest _) (and (file-exists-p (concat root "security.stdin"))
                                                (list (list :secret "sk-or-test-123"))))))
                (drgnx-test-gated '((:answers t))
                  (drgnx-ai-onboard-test--subscribe)
                  ;; the drgnx app: the Keychain may be used (inside the gate, whose clock is entered in batch)
                  (let ((r (let ((noninteractive nil)) (drgnx-onboard--ai-step '(:interactive t)))))
                    (drgnx-test-deliver-all)
                    (should (= prompted 1))
                    (should (string-search "sk-or-test-123" (drgnx-ai-onboard-test--slurp (concat root "security.stdin"))))
                    (should-not (string-search "sk-or-test-123" (drgnx-ai-onboard-test--slurp calls)))   ; never in argv
                    (should (member "openrouter" (drgnx-hub-keys-held)))       ; the hub holds it…
                    (should-not (gethash 'openrouter drgnx-ai--keys))          ; …and this Emacs does not
                    (dolist (role '(complete edit chat)) (should (eq (car (car (drgnx-ai-role role))) 'openrouter)))
                    (should (equal (drgnx-ai-role 'embed) '((tei))))            ; no embeddings there: step 5's
                    (should (string-match-p "semantic search needs a local model or TEI" (cadr r)))
                    (should (string-match-p "Ask the Codebase answered" (cadr r)))
                    (should (eq (car r) 'ok))
                    (should-not (string-search "sk-or-test-123" (cadr r)))
                    (should-not (string-search "sk-or-test-123" (drgnx-ai-onboard-test--slurp (concat root "config/settings.el"))))))))
          (delete-process mock))))))

(ert-deftest drgnx-ai-onboard/cli-exit-stops-the-job ()
  :tags '(:frozen)
  ;; `drgnx onboard' in batch: while a job is waited on, ending Emacs (Ctrl-C) stops the job; the entry is gone
  ;; once the wait is over.
  ;; Every answer as it is due (the stop's answer is the stopped job's row); the job's end comes at the end.
  (drgnx-ai-onboard-test--with-mac-jobs nil
    (should noninteractive)
    (let ((before kill-emacs-hook) (during nil) (r nil) (after nil))
      (drgnx-test-gated '((:answers t))
        (drgnx-ai-onboard-test--subscribe)
        (run-at-time 1 nil (lambda ()
                             (setq during kill-emacs-hook)
                             (dolist (f (seq-difference kill-emacs-hook before)) (funcall f))))   ; what exiting runs
        (setq r (drgnx-onboard--job "Sleeping" (list "sleep" "30") 15)
              after kill-emacs-hook)
        (drgnx-test-wait (lambda () (not (seq-find (lambda (j) (eq (plist-get j :status) 'running)) (drgnx-exec-list))))
                         :what "the job stopped")
        (drgnx-test-deliver-all)
        (should (> (length during) (length before)))
        (should (equal after before))
        (should (eq (car r) 'fail))))))

(ert-deftest drgnx-ai-onboard/a-real-ctrl-c-stops-the-job ()
  :tags '(:frozen)
  ;; The same with a real SIGINT: a batch Emacs waiting on a job ends on it without unwinding, and its
  ;; `kill-emacs-hook' entry stops the job.  (`env --default-signal=INT': a background job ignores SIGINT.)  The child
  ;; parks (test/fixtures/handshake-fixture.el) right after it sent the job's start and before it read the answer: the
  ;; entry is in before the start, and a start not answered yet is waited for, so the exit stops the job although the
  ;; child never read the answer on its own.  The test serves the start (the hub's barrier), signals the parked child,
  ;; and proves the stop was served on the job-ended event the hub sends this Emacs.
  (skip-unless (eql 0 (call-process "env" nil nil nil "--default-signal=INT" "true")))
  (let* ((root (file-name-as-directory (make-temp-file "drgnx-sigint" t)))
         (process-environment (append (list (concat "HOME=" root "home") (concat "DRGNX_CONFIG_DIR=" root "config")
                                            (concat "XDG_STATE_HOME=" root "state") (concat "DRGNX_DATA_DIR=" root "data"))
                                      process-environment))
         (drgnx-hub--presence-sent :unknown) (drgnx-hub-editor-token-hook nil)
         (drgnx-exec--jobs (make-hash-table :test #'equal)) (drgnx-exec--stale nil)
         (child nil) (ended nil) (gone nil))
    (unwind-protect
        ;; the jobs are the hub's: the real Ratatoskr serves them, the child finds it by the environment
        (drgnx-test-with-ratatoskr root :gated t
                                   (make-directory (concat root "home") t)
                                   (drgnx-test-gated '((sub-1 :answer "subscribe"))
                                     (add-hook 'drgnx-hub-event-functions (lambda (event _data) (when (equal event "exec-done") (setq ended t))))
                                     (drgnx-hub-connect)
                                     (drgnx-test-wait (lambda () drgnx-hub--events) :what "the subscription")
                                     ;; the job sleeps far longer than any wait below: only the stop can end it while the test waits.  The
                                     ;; child connects and settles first, so its start goes out at once; it parks once that is sent
                                     (setq child (drgnx-test-child-start
                                                  :name "drgnx-sigint"
                                                  :command (list "env" "--default-signal=INT" (expand-file-name invocation-name invocation-directory)
                                                                 "--batch" "-Q" "-L" (expand-file-name "core" drgnx-dir)
                                                                 "-l" "drgnx-onboard" "-l" "drgnx-exec"
                                                                 "-l" (expand-file-name "test/fixtures/handshake-fixture.el" drgnx-dir)
                                                                 "--eval" (concat "(progn"
                                                                                  " (advice-add 'drgnx-exec-start :before"
                                                                                  "  (lambda (&rest _) (drgnx-hub-connect)"
                                                                                  "    (while (not (drgnx-hub-settled-p)) (accept-process-output nil 0.05))))"
                                                                                  " (advice-add 'drgnx-exec-start :after"
                                                                                  "  (lambda (&rest _) (drgnx-test-child-announce \"STARTED\")))"
                                                                                  " (drgnx-onboard--job \"Sleeping\" (list \"sleep\" \"3600\")))"))))
                                     (drgnx-test-child-await child "STARTED")
                                     (drgnx-test-deliver-all)        ; the hub has served the start
                                     (set-process-sentinel child (lambda (p _event) (unless (process-live-p p) (process-put p :done t))))
                                     ;; the signal is pending in the parked child (blocked on its input) until it reads GO
                                     (drgnx-test-child-signal child 'SIGINT)
                                     (drgnx-test-child-go child)
                                     (drgnx-test-wait (lambda () (process-get child :done)) :what "the child's exit")
                                     (drgnx-test-deliver-all)        ; the hub has served the stop the exit sent
                                     (drgnx-test-wait (lambda () ended) :what "the job's end")
                                     (setq gone (process-get child :done))))
      (when (and child (process-live-p child)) (delete-process child))
      (delete-directory root t))
    (should ended)
    (should gone)))

(defvar drgnx-ai-onboard-test--job-what nil "The job `drgnx-onboard--job' is waiting on (the test's view).")

(ert-deftest drgnx-ai-onboard/pull-has-no-hour-limit ()
  :tags '(:frozen)
  ;; A model download (and the full-ai package sync) waits without the one-hour cap: C-g stops it, the progress shows.
  (drgnx-ai-onboard-test--with-mac-jobs drgnx-ai-onboard-test--ollama-answers
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
        ;; four jobs end, in turn: the install and three downloads (the server keeps running)
        (drgnx-test-gated (drgnx-ai-onboard-test--job-ends 4)
          (drgnx-ai-onboard-test--subscribe)
          (drgnx-onboard--ai-step '(:interactive t))
          (drgnx-ai-onboard-test--stop-jobs)
          (drgnx-test-deliver-all)
          (let ((pulls (seq-filter (lambda (w) (string-prefix-p "Downloading" (or (car w) ""))) waits)))
            (should (= (length pulls) 3))
            (dolist (w pulls) (should (or (null (cdr w)) (>= (cdr w) (* 6 3600)))))))))))

(ert-deftest drgnx-ai-onboard/the-package-sync-has-no-hour-limit ()
  :tags '(:frozen)
  (let ((seen nil))
    (cl-letf (((symbol-function 'drgnx-onboard--job) (lambda (_what _command &optional secs) (setq seen (list secs)) 'ok)))
      (drgnx-onboard--sync-job))
    (should (equal seen '(:none)))))

(ert-deftest drgnx-ai-onboard/estimate-skips-models-present ()
  :tags '(:frozen)
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
  :tags '(:frozen)
  ;; A progress bar's last state, without ANSI escapes or the carriage-return redraws before it; only the end of the
  ;; log (4 KB) is asked of the hub.
  (let ((log "") (asked nil))
    (cl-letf (((symbol-function 'drgnx-exec-log) (lambda (id max) (push (list id max) asked) log)))
      (setq log "pulling manifest\n\e[?25l\e[2K\rpulling 10%\r\e[2K\rpulling 40%\n")
      (should (equal (drgnx-onboard--last-line "x") "pulling 40%"))
      (setq log "\e[1m\e[32mdone\e[0m\n")
      (should (equal (drgnx-onboard--last-line "x") "done"))
      (should (equal (car asked) '("x" 4096)))
      ;; the hub not answering is no line, not an error
      (cl-letf (((symbol-function 'drgnx-exec-log) (lambda (&rest _) (error "no hub"))))
        (should-not (drgnx-onboard--last-line "x"))))))

(ert-deftest drgnx-ai-onboard/typed-key-cleared-and-env-noted ()
  ;; The string `read-passwd' returned is zeroed once the key is stored (the in-memory key is a copy); with
  ;; OPENROUTER_API_KEY set the environment's key wins over the stored one (it goes to the hub on each connect), it
  ;; stays in the environment, and the result says so.  Binary: the typed key goes to the hub.
  ;; Every answer as it is due; the hub's events come at the end.  This Emacs connects before the key is in its
  ;; environment, as the fixture did before.
  (drgnx-ai-onboard-test--with-mac drgnx-ai-onboard-test--openai-answers
    (drgnx-ai-onboard-test--openrouter-in-settings)
    (drgnx-ai-onboard-test--with-hub
      (let ((mock (drgnx-ai-test-mock-llm port script llm-log)) (typed nil) (env nil))
        (unwind-protect
            (drgnx-test-gated '((:answers t))
              (drgnx-ai-onboard-test--subscribe)
              (let ((r (let ((system-type 'darwin) (noninteractive nil)
                             (process-environment (cons "OPENROUTER_API_KEY=sk-env-456" process-environment)))
                         (cl-letf (((symbol-function 'read-passwd) (lambda (&rest _) (setq typed (copy-sequence "sk-or-test-123"))))
                                   ((symbol-function 'auth-source-search)
                                    (lambda (&rest _) (and (file-exists-p (concat root "security.stdin"))
                                                           (list (list :secret "sk-or-test-123"))))))
                           (prog1 (drgnx-onboard--ai-setup 'openrouter '(:interactive t))
                             (setq env (getenv "OPENROUTER_API_KEY")))))))
                (drgnx-test-deliver-all)
                (should (string-search "sk-or-test-123" (drgnx-ai-onboard-test--slurp (concat root "security.stdin"))))
                (should (equal typed (make-string (length typed) 0)))      ; cleared, not just dropped
                (should (equal env "sk-env-456"))
                (should-not (gethash 'openrouter drgnx-ai--keys))
                (should (string-match-p "OPENROUTER_API_KEY is set in the environment, which wins over the stored key" (cadr r)))
                (should-not (string-search "sk-env-456" (cadr r)))))
          (delete-process mock))))))

(ert-deftest drgnx-onboard/openrouter-from-the-cli-asks-for-no-key ()
  :tags '(:frozen)
  (drgnx-ai-onboard-test--with-mac drgnx-ai-onboard-test--openai-answers
    (cl-letf (((symbol-function 'read-passwd) (lambda (&rest _) (error "Asked for a key in batch"))))
      (let ((r (drgnx-onboard--ai-setup 'openrouter '(:interactive t))))     ; `drgnx onboard' runs in batch
        (should (string-match-p "set OPENROUTER_API_KEY for the CLI, or run this step in the drgnx app" (cadr r)))
        (should-not (file-exists-p (concat root "security.stdin")))))))

(ert-deftest drgnx-onboard/a-failed-download-says-how-to-retry ()
  :tags '(:frozen)
  ;; six jobs end, in turn: the install and two downloads (the second fails, and the step stops there), then on the
  ;; second run three downloads (the server keeps running)
  (drgnx-ai-onboard-test--with-mac-jobs drgnx-ai-onboard-test--ollama-answers
    (cl-letf (((symbol-function 'completing-read)
               (drgnx-ai-onboard-test--answer '(("Keep" . "Change") ("Set up AI with" . "ollama"))))
              ((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
      (drgnx-test-gated (drgnx-ai-onboard-test--job-ends 6)
        (drgnx-ai-onboard-test--subscribe)
        (let* ((first (progn (write-region "qwen2.5-coder:7b" nil (concat root "home/.pull-fail") nil 'silent)
                             (car (drgnx-onboard-run :only '(ai)))))
               (edit-after-first (car (drgnx-ai-role 'edit)))
               ;; again, the download working now: no second install or server; ok
               (again (progn (delete-file (concat root "home/.pull-fail"))
                             (delete-file calls)
                             (car (drgnx-onboard-run :only '(ai)))))
               (calls-again (drgnx-ai-onboard-test--calls calls)))
          (drgnx-ai-onboard-test--stop-jobs)
          (drgnx-test-deliver-all)
          (should (eq (nth 1 first) 'fail))
          (should (string-match-p "qwen2\\.5-coder:7b" (nth 2 first)))
          (should (string-match-p "run the step again" (nth 2 first)))
          (should (string-match-p "max retries exceeded" (nth 2 first)))         ; why, from its log
          (should-not (equal edit-after-first '(ollama . "qwen2.5-coder:7b")))
          (should (eq (nth 1 again) 'ok))
          (should-not (seq-find (lambda (c) (string-prefix-p "brew" c)) calls-again))
          (should-not (member "ollama serve" calls-again))
          (should (member "ollama pull qwen2.5-coder:7b" calls-again))
          (should (equal (car (drgnx-ai-role 'edit)) '(ollama . "qwen2.5-coder:7b"))))))))

(ert-deftest drgnx-onboard/non-interactive-installs-nothing ()
  :tags '(:frozen)
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
      (should-not (drgnx-exec-list))
      ;; Linux: Ollama's installer, with its sudo said
      (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'linux)))
        (should (string-match-p "curl -fsSL https://ollama.com/install.sh | sh.*sudo"
                                (cadr (drgnx-onboard--ai-setup 'ollama '(:interactive nil)))))))))

(defun drgnx-ai-onboard-test--serving (command)
  "Running jobs whose command is COMMAND."
  (seq-filter (lambda (j) (and (eq (plist-get j :status) 'running) (equal (plist-get j :argv) command))) (drgnx-exec-list)))

(defun drgnx-ai-onboard-test--settle (pred &optional secs)
  "Wait until PRED (`drgnx-test-wait': at least 30 s, or SECS): the probe and the start are asynchronous."
  (drgnx-test-wait pred :secs (max 30 (or secs 0)) :what "the runner's job"))

;; The runner's start and stop go through the gate with every answer as it is due (the start's `exec/get' and the
;; stop's answer are the job's row); the jobs' ends come at the end.  A look in the runner's window is the test's own
;; wait, which moves no virtual time, so "at most once a minute" is not reached by waiting.

(ert-deftest drgnx-ai/ensure-local-starts-the-runner-when-it-is-down ()
  :tags '(:frozen)
  (drgnx-ai-onboard-test--with-mac-jobs drgnx-ai-onboard-test--ollama-answers
    (let ((serve (list (concat bin "fake-serve") "serve")) started serving stopped later)
      (cl-letf (((symbol-function 'message) #'ignore))
        (drgnx-test-gated '((:answers t))
          (drgnx-ai-onboard-test--subscribe)
          (let ((noninteractive nil))         ; inside the gate: its clock is entered in batch
            (drgnx-ai-set-managed 'ollama serve "Ollama")
            ;; down, no job: started
            (drgnx-ai-ensure-local)
            (setq started (drgnx-ai-onboard-test--settle (lambda () (drgnx-ai-onboard-test--serving serve)) 5))
            ;; a job runs it already: not a second one
            (setq drgnx-ai--ensure-time nil)
            (drgnx-ai-ensure-local)
            (drgnx-test-pause 1.5 "a second one may not come")
            (setq serving (length (drgnx-ai-onboard-test--serving serve)))
            ;; it answers: nothing started
            (dolist (j (drgnx-exec-list)) (drgnx-exec-stop (plist-get j :id)))
            (setq stopped (drgnx-ai-onboard-test--settle (lambda () (null (drgnx-ai-onboard-test--serving serve)))))
            (let ((mock (drgnx-ai-test-mock-llm port script)))
              (unwind-protect
                  (progn (setq drgnx-ai--ensure-time nil)
                         (drgnx-ai-ensure-local)
                         (drgnx-test-pause 1.5 "nothing may start")
                         (setq later (drgnx-ai-onboard-test--serving serve)))
                (delete-process mock))))
          (drgnx-ai-onboard-test--stop-jobs)
          (drgnx-test-deliver-all)
          (should started)
          (should (= 1 serving))
          (should stopped)
          (should-not later))))))

(ert-deftest drgnx-ai/a-refused-request-starts-the-runner-at-most-once-a-minute ()
  :tags '(:frozen)
  (drgnx-ai-onboard-test--with-mac-jobs drgnx-ai-onboard-test--ollama-answers
    (let ((serve (list (concat bin "fake-serve") "serve"))
          (ask (lambda () (let ((done nil))
                            (drgnx-ai-request 'chat 'chat (list :messages (vector (list :role "user" :content "hi")))
                                              (lambda (_ _) (setq done t)) :chain '((ollama . "m")))
                            (drgnx-ai-onboard-test--settle (lambda () done) 5))))
          started stopped again other)
      (cl-letf (((symbol-function 'message) #'ignore))
        (drgnx-test-gated '((:answers t))
          (drgnx-ai-onboard-test--subscribe)
          (let ((noninteractive nil))         ; inside the gate: its clock is entered in batch
            (drgnx-ai-set-managed 'ollama serve "Ollama")
            (funcall ask)                                       ; nothing listens: connection refused
            (setq started (drgnx-ai-onboard-test--settle (lambda () (drgnx-ai-onboard-test--serving serve)) 5))
            (dolist (j (drgnx-exec-list)) (drgnx-exec-stop (plist-get j :id)))
            (setq stopped (drgnx-ai-onboard-test--settle (lambda () (null (drgnx-ai-onboard-test--serving serve)))))
            (funcall ask)                                       ; again within the minute: left alone
            (drgnx-test-pause 1.5 "nothing may start")
            (setq again (drgnx-ai-onboard-test--serving serve))
            ;; another provider refusing never starts it
            (setq drgnx-ai--ensure-time nil)
            (drgnx-ai--refused 'lmstudio)
            (drgnx-test-pause 1.5 "nothing may start")
            (setq other (drgnx-ai-onboard-test--serving serve)))
          (drgnx-ai-onboard-test--stop-jobs)
          (drgnx-test-deliver-all)
          (should started)
          (should stopped)
          (should-not again)
          (should-not other))))))

(ert-deftest drgnx-ai/ensure-local-never-waits-for-the-job ()
  :tags '(:frozen)
  ;; the probe's callback runs in a curl sentinel: it starts nothing itself, and the start does not wait for the hub
  (drgnx-ai-onboard-test--with-mac-jobs drgnx-ai-onboard-test--ollama-answers
    (let ((serve (list (concat bin "fake-serve") "serve")) (in-callback 'unset) started)
      (cl-letf (((symbol-function 'message) #'ignore)
                ((symbol-function 'drgnx-ai-probe)            ; nothing answers; the callback at once
                 (lambda (callback &optional _ids) (funcall callback) (setq in-callback (drgnx-exec-list)) nil)))
        (drgnx-test-gated '((:answers t))
          (drgnx-ai-onboard-test--subscribe)
          (let ((noninteractive nil))         ; inside the gate: its clock is entered in batch
            (drgnx-ai-set-managed 'ollama serve "Ollama")
            (drgnx-ai-ensure-local)
            (setq started (drgnx-ai-onboard-test--settle (lambda () (drgnx-ai-onboard-test--serving serve)) 5)))
          (drgnx-ai-onboard-test--stop-jobs)
          (drgnx-test-deliver-all)
          (should (null in-callback))                           ; the callback returned before any job was started
          (should started))))))

(ert-deftest drgnx-ai/ensure-local-does-nothing-in-batch ()
  (drgnx-ai-onboard-test--with-mac drgnx-ai-onboard-test--ollama-answers
    (let ((probed nil))
      (drgnx-ai-set-managed 'ollama (list (concat bin "fake-serve") "serve") "Ollama")
      (cl-letf (((symbol-function 'drgnx-ai-probe) (lambda (&rest _) (setq probed t))))
        (should-not (drgnx-ai-ensure-local))
        (drgnx-ai--refused 'ollama))
      (should-not probed)
      (should-not drgnx-ai--ensure-time)
      (should-not (drgnx-exec-list)))))

;;; ai-onboard-test.el ends here
