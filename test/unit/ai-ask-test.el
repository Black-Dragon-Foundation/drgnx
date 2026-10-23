;;; ai-ask-test.el --- batch tests: Ask the Codebase, Choose Provider/Model, gptel from the registry -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)
(load (expand-file-name "modules/tools/drgnx-ai-ui" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/mock-llm" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/runtime-settings-fixture" drgnx-dir) nil t)

(defvar drgnx-ai-ask-test--delay nil "Seconds the mock waits before it answers a chat.")

(defmacro drgnx-ai-ask-test--with (answer &rest body)
  "BODY with ROOT a project (src/a.el mentions frobnicate on line 3), the `chat' and `complete' roles on
provider `o' served by a mock answering ANSWER, its LOG."
  (declare (indent 1))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-ai-ask" t)))
          (port nil) (script (concat root "llm.eld")) (log (concat root "llm.log"))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" root "config")) process-environment))
          (drgnx-ai-detected '((o :up t :models ("small" "big"))))
          (mock nil))
     (drgnx-test-runtime-settings--reset)
     (unwind-protect
         (progn
           (make-directory (concat root "config") t) (make-directory (concat root "proj/src") t)
           (write-region "(require 'x)\n\n(defun frobnicate (widget)\n  (twist widget))\n" nil (concat root "proj/src/a.el") nil 'silent)
           (write-region "(defun unrelated () nil)\n" nil (concat root "proj/src/b.el") nil 'silent)
           (with-temp-file script
             (prin1 (list (append (list :path "/api/chat" :body (json-serialize (list :message (list :content ,answer))))
                                  (and drgnx-ai-ask-test--delay (list :delay drgnx-ai-ask-test--delay)))
                          (list :path "/api/generate" :body "{\"response\":\"ok\"}"))
                    (current-buffer)))
           (setq mock (drgnx-ai-test-mock-llm nil script log)
                 port (process-get mock :port))
           ;; through settings.el, as the user's own: a `setq' would be your Lisp, which a later choice never overrides
           (drgnx-test-runtime-settings-put
            (format "(drgnx-ai-providers ((o :name \"O\" :kind ollama :url %S :caps (chat fim))))"
                    (format "http://127.0.0.1:%d" port))
            "(drgnx-ai-roles ((chat (o . \"m\"))))")
           ,@body)
       (drgnx-test-runtime-settings--forget)
       (when mock (delete-process mock))
       (when (get-buffer "*AI answer*") (kill-buffer "*AI answer*"))
       (delete-directory root t))))

(defun drgnx-ai-ask-test--answer (&optional secs)
  (let ((deadline (+ (float-time) (or secs 8))))
    (while (and (not (and (get-buffer "*AI answer*")
                          (with-current-buffer "*AI answer*" (string-search "Sources" (buffer-string)))))
                (< (float-time) deadline))
      (accept-process-output nil 0.05)))
  (get-buffer "*AI answer*"))

(ert-deftest drgnx-ai-ask/the-answer-comes-from-the-files-the-question-names-and-cites-them ()
  (drgnx-ai-ask-test--with "frobnicate twists the widget (src/a.el:3)."
    (let ((default-directory (concat root "proj/")))
      (drgnx-ai-ask "where do we frobnicate widgets?" default-directory))
    (let ((b (drgnx-ai-ask-test--answer)))
      (should b)
      (with-current-buffer b
        (should (string-search "where do we frobnicate widgets?" (buffer-string)))
        (should (string-search "twists the widget" (buffer-string)))
        (goto-char (point-min))
        (should (search-forward "Sources:" nil t))                            ; the list, not the answer's text
        (should (search-forward "src/a.el:3" nil t))
        (should (button-at (match-beginning 0)))))                           ; a link
    ;; the model saw the snippet, not the unrelated file
    (let ((sent (with-temp-buffer (insert-file-contents log) (buffer-string))))
      (should (string-search "(twist widget)" sent))
      (should-not (string-search "unrelated" sent)))))

(defun drgnx-ai-ask-test--curls ()
  (seq-filter (lambda (p) (and (equal (process-name p) "drgnx-ai") (process-live-p p))) (process-list)))

(ert-deftest drgnx-ai-ask/stop-cancels-request ()
  (let ((drgnx-ai-ask-test--delay 1.5))
    (drgnx-ai-ask-test--with "frobnicate twists the widget (src/a.el:3)."
      (let ((default-directory (concat root "proj/")) (said nil))
        (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) said))))
          (drgnx-ai-ask "where do we frobnicate widgets?" default-directory)
          ;; the search runs first, then the model is asked
          (let ((deadline (+ (float-time) 5)))
            (while (and (not (drgnx-ai-ask-test--curls)) (< (float-time) deadline)) (accept-process-output nil 0.02)))
          (should (= 1 (length (drgnx-ai-ask-test--curls))))
          (should (= 1 (length drgnx-ai--active)))
          (drgnx-ai-stop)
          (should-not drgnx-ai--active)
          (should-not (drgnx-ai-ask-test--curls))                         ; the process is gone
          (accept-process-output nil 2.0)                                 ; past the mock's answer
          (should-not (get-buffer "*AI answer*"))                         ; the callback never ran
          (should (seq-find (lambda (m) (string-match-p "stopped" m)) said)))))))

(ert-deftest drgnx-ai-ask/stop-during-the-search-asks-nothing ()
  (drgnx-ai-ask-test--with "never"
    (let ((default-directory (concat root "proj/")) (said nil))
      (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) said))))
        (drgnx-ai-ask "where do we frobnicate widgets?" default-directory)
        (drgnx-ai-stop)                                                   ; the grep has not answered yet
        (accept-process-output nil 1.0)
        (should-not (drgnx-ai-ask-test--curls))
        (should-not (get-buffer "*AI answer*"))
        (should-not drgnx-ai--active)))))

(ert-deftest drgnx-ai-ask/a-grep-without-gnu-long-options-still-finds-code ()
  ;; macOS' BSD grep: no ripgrep, and a grep whose --exclude/--exclude-dir do not work like GNU's (here: refused)
  (drgnx-ai-ask-test--with "ok"
    (let* ((real (executable-find "grep")) (bin (concat root "bin/")))
      (make-directory bin t)
      (write-region (format "#!/bin/sh\nfor a in \"$@\"; do case \"$a\" in --*) echo \"grep: unrecognized option $a\" >&2; exit 2;; esac; done\nexec %s \"$@\"\n" real)
                    nil (concat bin "grep") nil 'silent)
      (set-file-modes (concat bin "grep") #o755)
      (make-directory (concat root "proj/.git") t)
      (write-region "FROBNICATE_TOKEN=hidden-env-value\n" nil (concat root "proj/.env") nil 'silent)
      (let ((orig (symbol-function 'executable-find))
            (exec-path (cons bin exec-path))
            (process-environment (cons (concat "PATH=" bin ":" (getenv "PATH")) process-environment)))
        (cl-letf (((symbol-function 'executable-find) (lambda (name &rest r) (and (not (equal name "rg")) (apply orig name r)))))
          (drgnx-ai-ask "where do we frobnicate?" (concat root "proj/"))))
      (should (drgnx-ai-ask-test--answer))
      (let ((sent (with-temp-buffer (insert-file-contents log) (buffer-string))))
        (should (string-search "(twist widget)" sent))
        (should-not (string-search "hidden-env-value" sent))))))

(defun drgnx-ai-ask-test--ask-without-rg (root grep-script)
  "Ask about ROOT's project with ripgrep hidden and GREP-SCRIPT (shell text) as the `grep' first on PATH."
  (let ((bin (concat root "bin/")))
    (make-directory bin t)
    (write-region (concat "#!/bin/sh\n" grep-script "\n") nil (concat bin "grep") nil 'silent)
    (set-file-modes (concat bin "grep") #o755)
    (let ((orig (symbol-function 'executable-find))
          (exec-path (cons bin exec-path))
          (process-environment (cons (concat "PATH=" bin ":" (getenv "PATH")) process-environment)))
      (cl-letf (((symbol-function 'executable-find) (lambda (name &rest r) (and (not (equal name "rg")) (apply orig name r)))))
        (drgnx-ai-ask "where do we frobnicate?" (concat root "proj/"))))))

(defun drgnx-ai-ask-test--sent (log)
  (with-temp-buffer (insert-file-contents log) (buffer-string)))

(ert-deftest drgnx-ai-ask/vendored-and-build-trees-are-not-searched ()
  ;; without ripgrep there is no .gitignore: the usual dependency and build trees are skipped by name
  (drgnx-ai-ask-test--with "ok"
    (dolist (d '("node_modules/pkg" "vendor/x" "target/debug" "dist" "build" "__pycache__"))
      (make-directory (concat root "proj/" d) t)
      (write-region (format "frobnicate in-%s\n" (replace-regexp-in-string "/" "-" d)) nil
                    (concat root "proj/" d "/f.txt") nil 'silent))
    (drgnx-ai-ask-test--ask-without-rg root (format "exec %s \"$@\"" (executable-find "grep")))
    (should (drgnx-ai-ask-test--answer))
    (let ((sent (drgnx-ai-ask-test--sent log)))
      (should (string-search "(twist widget)" sent))
      (should-not (string-search "in-node_modules" sent))
      (should-not (string-search "in-vendor" sent))
      (should-not (string-search "in-target" sent))
      (should-not (string-search "in-dist" sent))
      (should-not (string-search "in-build" sent))
      (should-not (string-search "in-__pycache__" sent)))))

(ert-deftest drgnx-ai-ask/a-search-that-never-ends-is-cut-off-and-ask-answers-without-context ()
  (drgnx-ai-ask-test--with "ok"
    (let ((drgnx-ai-search-timeout 0.5) (t0 (float-time)))
      (drgnx-ai-ask-test--ask-without-rg root "exec sleep 8")
      (should (drgnx-ai-ask-test--answer 4))
      (should (< (- (float-time) t0) 4))
      (should-not (drgnx-ai-ask-test--sent-p log "(twist widget)"))
      (should-not (seq-find (lambda (p) (equal (process-name p) "drgnx-ai-grep")) (process-list)))
      (should-not drgnx-ai--active))))

(defun drgnx-ai-ask-test--sent-p (log needle)
  (string-search needle (drgnx-ai-ask-test--sent log)))

(ert-deftest drgnx-ai-ask/a-huge-line-is-cut-before-it-reaches-the-model ()
  (drgnx-ai-ask-test--with "ok"
    (write-region (concat "frobnicate " (make-string 200000 ?q) "\n") nil (concat root "proj/src/big.el") nil 'silent)
    ;; a grep that reports a 2 MB line, as for a minified file
    (drgnx-ai-ask-test--ask-without-rg
     root "printf './src/big.el:1:frobnicate '; head -c 2000000 /dev/zero | tr '\\0' q; printf '\\n'")
    (should (drgnx-ai-ask-test--answer))
    (let ((sent (drgnx-ai-ask-test--sent log)))
      (should (string-search "big.el" sent))                              ; its snippet came
      (should-not (string-match-p "q\\{600\\}" sent)))))

(ert-deftest drgnx-ai-ask/stop-kills-the-search ()
  (drgnx-ai-ask-test--with "ok"
    (drgnx-ai-ask-test--ask-without-rg root "exec sleep 8")
    (should (seq-find (lambda (p) (and (equal (process-name p) "drgnx-ai-grep") (process-live-p p))) (process-list)))
    (drgnx-ai-stop)
    (should-not (seq-find (lambda (p) (and (equal (process-name p) "drgnx-ai-grep") (process-live-p p))) (process-list)))
    (accept-process-output nil 0.3)
    (should-not (get-buffer "*AI answer*"))))

(ert-deftest drgnx-ai-ask/hidden-files-never-reach-the-model ()
  ;; .env, .git and other dot files: never searched, with ripgrep or with grep
  (dolist (rg (if (executable-find "rg") '(t nil) '(nil)))
    (drgnx-ai-ask-test--with "ok"
      (make-directory (concat root "proj/.git") t)
      (write-region "FROBNICATE_TOKEN=hidden-env-value\n" nil (concat root "proj/.env") nil 'silent)
      (write-region "frobnicate hidden-git-value\n" nil (concat root "proj/.git/notes") nil 'silent)
      (let ((orig (symbol-function 'executable-find)))
        (cl-letf (((symbol-function 'executable-find) (lambda (name &rest r) (and (or rg (not (equal name "rg"))) (apply orig name r)))))
          (drgnx-ai-ask "where do we frobnicate?" (concat root "proj/"))))
      (should (drgnx-ai-ask-test--answer))
      (let ((sent (with-temp-buffer (insert-file-contents log) (buffer-string))))
        (should (string-search "(twist widget)" sent))
        (should-not (string-search "hidden-env-value" sent))
        (should-not (string-search "hidden-git-value" sent))))))

(ert-deftest drgnx-ai-ask/another-retriever-adds-its-snippets ()
  ;; M10's semantic index joins through `drgnx-ai-retrievers'
  (drgnx-ai-ask-test--with "ok"
    (let ((drgnx-ai-retrievers (cons (lambda (_q _root done) (funcall done (list (list :file "doc/x.md" :line 7 :text "SEMANTIC HIT"))))
                                     drgnx-ai-retrievers)))
      (drgnx-ai-ask "frobnicate?" (concat root "proj/")))
    (should (drgnx-ai-ask-test--answer))
    (should (string-search "SEMANTIC HIT" (with-temp-buffer (insert-file-contents log) (buffer-string))))))

(ert-deftest drgnx-ai-choose/a-role-is-written-to-settings-el-never-a-key ()
  (drgnx-ai-ask-test--with "OK"
    (let ((process-environment (cons "OPENROUTER_API_KEY=sk-or-secret" process-environment)))
      (drgnx-ai-set-role 'complete '((o . "big") (openrouter . "openrouter/auto")))
      (should (equal (drgnx-ai-role 'complete) '((o . "big") (openrouter . "openrouter/auto"))))
      (should (equal (drgnx-ai-role 'chat) '((o . "m"))))                        ; the rest of the roles kept
      (let ((text (with-temp-buffer (insert-file-contents (concat root "config/settings.el")) (buffer-string))))
        (should-not (string-search "sk-or" text))
        (should (string-search "drgnx-ai-roles" text))
        (should (string-search "openrouter/auto" text))))))                      ; the role written

(ert-deftest drgnx-ai-choose/a-live-call-tests-the-choice-before-it-is-kept ()
  (drgnx-ai-ask-test--with "OK"
    (let ((answers '("complete" "o" "big")) (said nil))
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (pop answers)))
                ((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) said))))
        (drgnx-ai-choose)
        (let ((deadline (+ (float-time) 5)))
          (while (and (not (equal (car (drgnx-ai-role 'complete)) '(o . "big"))) (< (float-time) deadline))
            (accept-process-output nil 0.05))))
      (should (equal (car (drgnx-ai-role 'complete)) '(o . "big")))
      (should (seq-find (lambda (m) (string-match-p "answered" m)) said)))))

(ert-deftest drgnx-ai-choose/a-choice-that-does-not-answer-is-not-kept ()
  (drgnx-ai-ask-test--with "OK"
    (let ((dead (drgnx-test-free-port)))
      (setq drgnx-ai-providers `((gone :name "Gone" :kind ollama :url ,(format "http://127.0.0.1:%d" dead) :caps (chat fim)))
            drgnx-ai-roles '((chat (o . "m"))))
      (let ((drgnx-ai-detected '((gone :up t))) (answers '("chat" "gone" "x")) (said nil))
        (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (pop answers)))
                  ((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) said))))
          (drgnx-ai-choose)
          (let ((deadline (+ (float-time) 5)))
            (while (and (not (seq-find (lambda (m) (string-match-p "did not answer" m)) said)) (< (float-time) deadline))
              (accept-process-output nil 0.05))))
        (should (seq-find (lambda (m) (string-match-p "did not answer" m)) said))
        (should (equal (drgnx-ai-role 'chat) '((o . "m"))))))))                    ; unchanged

(ert-deftest drgnx-ai-gptel/its-backend-comes-from-the-chat-role ()
  (drgnx-ai-ask-test--with "OK"
    (let ((spec (drgnx-ai-gptel-spec 'o "m")))
      (should (eq (car spec) 'gptel-make-ollama))
      (should (equal (plist-get (cddr spec) :host) (format "127.0.0.1:%d" port)))
      (should (equal (plist-get (cddr spec) :protocol) "http")))
    (let* ((process-environment (cons "OPENROUTER_API_KEY=sk-or-from-env" process-environment))
           (spec (drgnx-ai-gptel-spec 'openrouter "openrouter/auto")))
      (should (eq (car spec) 'gptel-make-openai))
      (should (equal (plist-get (cddr spec) :host) "openrouter.ai"))
      (should (equal (plist-get (cddr spec) :endpoint) "/api/v1/chat/completions"))
      (should (functionp (plist-get (cddr spec) :key)))                       ; resolved when gptel asks, never stored
      (should (equal (funcall (plist-get (cddr spec) :key)) "sk-or-from-env")))))

(ert-deftest drgnx-ai-gptel/configured-unless-the-user-chose-a-backend-of-their-own ()
  ;; gptel is not loaded here: its variables are set and unset by hand (never let-bound: they are special once
  ;; gptel loads)
  (drgnx-ai-ask-test--with "OK"
    (let ((was-bound (boundp 'gptel-backend)) (old (and (boundp 'gptel-backend) gptel-backend))
          (old-model (and (boundp 'gptel-model) gptel-model)) (drgnx-ai--gptel-ours nil))
      (unwind-protect
          (cl-letf (((symbol-function 'gptel-make-ollama) (lambda (name &rest _) (list 'backend name))))
            (setq gptel-backend nil)
            (should (equal (drgnx-ai-gptel-maybe-configure (lambda (_id) t)) '(o . "m")))
            (should (equal gptel-backend '(backend "O")))
            (should (eq gptel-model 'm))
            (setq gptel-backend 'the-users-own)                                 ; chosen by the user: kept
            (should-not (drgnx-ai-gptel-maybe-configure (lambda (_id) t)))
            (should (eq gptel-backend 'the-users-own)))
        (if was-bound (setq gptel-backend old gptel-model old-model) (makunbound 'gptel-backend) (makunbound 'gptel-model))))))

(ert-deftest drgnx-ai/ask-and-choose-are-registered ()
  (drgnx-test-with-modules '(tools/ai) :strict t
                           (dolist (id '(ai-ask ai-choose ai-stop)) (should (drgnx-commands-get id)))))

;;; ai-ask-test.el ends here

(ert-deftest drgnx-ai-ask/the-command-confirms-the-roots-project-route-and-fixes-its-chain ()
  ;; asked from the command (not the retriever's callback), for ROOT's project, whatever buffer is current
  (drgnx-ai-ask-test--with "never"
    (let ((asked nil) (chain nil) (drgnx-ai--active nil) (default-directory (expand-file-name "~")))
      (cl-letf (((symbol-function 'drgnx-ai-confirm-project-route) (lambda () (push default-directory asked) t))
                ((symbol-function 'drgnx-ai-ask-request) (lambda (_q _r _cb &rest args) (setq chain (plist-get args :chain)) #'ignore))
                ((symbol-function 'message) #'ignore))
        (drgnx-ai-ask "q?" (concat root "proj/"))
        (should (equal asked (list (concat root "proj/"))))
        (should (equal chain (let ((default-directory (concat root "proj/"))) (drgnx-ai-role 'chat))))))))

(ert-deftest drgnx-ai-choose/never-copies-a-projects-remote-route-into-the-global-roles ()
  ;; the user allowed this project's OpenRouter step; choosing a provider there must not make it global
  (drgnx-ai-ask-test--with "OK"
    (let ((process-environment (cons (concat "XDG_STATE_HOME=" root "state") process-environment))
          (default-directory (concat root "proj/")) (noninteractive nil))
      (make-directory (concat root "proj/.drgnx") t)
      (with-temp-file (concat root "proj/.drgnx/ai.eld")
        (prin1 '(:version 1 :roles ((chat (openrouter . "paid/m") (o . "m")))) (current-buffer)))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
        (should (drgnx-ai-confirm-project-route)))
      (should (assq 'openrouter (drgnx-ai-role 'chat)))                       ; in force in the project
      (let ((answers '("chat" "o" "big")) (said nil))
        (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (pop answers)))
                  ((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) said))))
          (drgnx-ai-choose)
          (let ((deadline (+ (float-time) 5)))
            (while (and (not (seq-find (lambda (m) (string-match-p "answered" m)) said)) (< (float-time) deadline))
              (accept-process-output nil 0.05)))))
      (let ((roles (default-value 'drgnx-ai-roles)))
        (should (equal (alist-get 'chat roles) '((o . "big"))))))))
