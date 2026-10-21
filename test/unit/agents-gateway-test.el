;;; agents-gateway-test.el --- batch tests: agents on OpenRouter/Ollama/Anthropic profiles go through the gateway -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-agents)
(require 'drgnx-hub)

(defmacro drgnx-agents-gw-test--with (&rest body)
  "BODY with drgnx's dirs under ROOT, the hub served in this Emacs, OPENROUTER_API_KEY=sk-or-x."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-agents-gw" t)))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" root "config") (concat "DRGNX_DATA_DIR=" root "data")
                                             (concat "XDG_STATE_HOME=" root "state") "OPENROUTER_API_KEY=sk-or-x" "ANTHROPIC_API_KEY")
                                       process-environment))
          (drgnx-ai--keys (make-hash-table :test #'eq)) (auth-sources nil) (drgnx-work-db--handles nil)
          (drgnx-gateway--keys (make-hash-table :test #'eq)) (drgnx-gateway--registrations (make-hash-table :test #'equal))
          (drgnx-hub--exit-function #'drgnx-hub-stop) (drgnx-agents-profiles nil))
     (unwind-protect
         (progn (make-directory (concat root "config") t) ,@body)
       (drgnx-hub-disconnect)
       (drgnx-hub-stop)
       (drgnx-work-db-close-all)
       (delete-directory root t))))

(defun drgnx-agents-gw-test--session (profile)
  (drgnx-agents--make :name "t" :profile profile :cwd temporary-file-directory))

(ert-deftest drgnx-agents/an-openrouter-agent-gets-the-gateway-not-the-key ()
  (drgnx-agents-gw-test--with
    (drgnx-hub-serve (drgnx-hub-socket))
    (let* ((s (drgnx-agents-gw-test--session "claude (OpenRouter)"))
           (env (drgnx-agents--env s)))
      (should (member (format "ANTHROPIC_BASE_URL=http://127.0.0.1:%d" (drgnx-gateway-port)) env))
      (should (seq-find (lambda (e) (string-match-p "\\`ANTHROPIC_AUTH_TOKEN=[0-9a-f]\\{64\\}\\'" e)) env))
      (should (member "ANTHROPIC_API_KEY=" env))
      (should-not (seq-find (lambda (e) (string-search "sk-or-x" e)) env))
      (should (eq (drgnx-agent-session-via s) 'gateway))
      (should (= (plist-get (drgnx-hub-call-sync "status" nil) :registrations) 1))
      ;; registered with role `agent''s chain (OpenRouter) and the session's name
      (let ((reg (cdar (drgnx-gateway-registrations))))
        (should (equal (plist-get reg :chain) '((openrouter))))
        (should (equal (plist-get reg :agent) "t"))
        ;; …and its owner: this Emacs (its agents are its children; a crashed one's tokens are pruned)
        (should (eql (plist-get reg :owner) (emacs-pid)))))))

(ert-deftest drgnx-agents/in-the-hub-keys-come-only-from-editors ()
  ;; the hub is a daemon: an agent it starts never looks a key up where that may ask (a .gpg file's passphrase); it
  ;; uses what editors handed over (`gateway/keys'), and without one it does not start, saying how one comes
  (drgnx-agents-gw-test--with
    (let ((process-environment (cons "OPENROUTER_API_KEY" process-environment))
          (auth-sources (list (concat root "authinfo.gpg"))) (asked nil))
      (cl-letf (((symbol-function 'auth-source-search) (lambda (&rest _) (push auth-sources asked) nil)))
        (drgnx-hub-serve (drgnx-hub-socket))
        (let ((err (should-error (drgnx-agents--env (drgnx-agents-gw-test--session "claude (OpenRouter)")))))
          (should (string-match-p "editor" (error-message-string err))))
        (should-not (seq-some (lambda (srcs) (seq-some (lambda (s) (and (stringp s) (string-suffix-p ".gpg" s))) srcs)) asked))
        (should (= (plist-get (drgnx-hub-call-sync "status" nil) :registrations) 0))
        ;; an editor connects: its key is the agents' too (the gateway's, and a direct start's)
        (drgnx-hub-call-sync "gateway/keys" '(:keys (:openrouter "sk-fake-sent")))
        (let ((env (drgnx-agents--env (drgnx-agents-gw-test--session "claude (OpenRouter)"))))
          (should (seq-find (lambda (e) (string-prefix-p "ANTHROPIC_AUTH_TOKEN=" e)) env))
          (should-not (seq-find (lambda (e) (string-search "sk-fake-sent" e)) env)))
        (should (equal (drgnx-ai-key 'openrouter) "sk-fake-sent"))
        (should-not (seq-some (lambda (srcs) (seq-some (lambda (s) (and (stringp s) (string-suffix-p ".gpg" s))) srcs)) asked))))))

(ert-deftest drgnx-agents/an-ollama-or-anthropic-agent-has-its-own-chain ()
  (drgnx-agents-gw-test--with
    (drgnx-hub-serve (drgnx-hub-socket))
    (let ((drgnx-agents-profiles '(("mine" :command ("x") :ai claude-anthropic))))
      (drgnx-hub-call-sync "gateway/keys" '(:keys (:anthropic "sk-fake-ant")))   ; (in the hub: from an editor)
      (drgnx-agents--env (drgnx-agents-gw-test--session "claude (Ollama)"))
      (drgnx-agents--env (drgnx-agents-gw-test--session "mine"))
      (should (equal (sort (mapcar (lambda (r) (plist-get (cdr r) :chain)) (drgnx-gateway-registrations))
                           (lambda (a b) (string< (symbol-name (caar a)) (symbol-name (caar b)))))
                     '(((anthropic)) ((ollama))))))))

(ert-deftest drgnx-agents/an-agent-s-token-goes-when-the-agent-does ()
  ;; a token left in an exited agent's environment must not keep spending
  (drgnx-agents-gw-test--with
    (drgnx-hub-serve (drgnx-hub-socket))
    (let ((s (drgnx-agents-gw-test--session "claude (OpenRouter)")))
      (drgnx-agents--env s)
      (should (= (length (drgnx-gateway-registrations)) 1))
      (drgnx-agents--release-gateway s)                   ; what the session's exit runs (asynchronously)
      (should (let ((deadline (+ (float-time) 3)))
                (while (and (drgnx-gateway-registrations) (< (float-time) deadline)) (accept-process-output nil 0.02))
                (null (drgnx-gateway-registrations))))
      (should-not (drgnx-agent-session-gateway s)))))

(ert-deftest drgnx-agents/a-subscription-agent-never-gets-the-gateway ()
  (drgnx-agents-gw-test--with
    (drgnx-hub-serve (drgnx-hub-socket))
    (let* ((s (drgnx-agents-gw-test--session "claude")) (env (drgnx-agents--env s)))
      ;; no route variable is set (the bare names only unset what Emacs's own environment has: no inherited key)
      (should-not (seq-find (lambda (e) (and (string-prefix-p "ANTHROPIC_" e) (string-search "=" e))) env))
      (should-not (drgnx-agent-session-via s))
      (should (= (plist-get (drgnx-hub-call-sync "status" nil) :registrations) 0)))))

(ert-deftest drgnx-agents/without-a-hub-it-goes-direct-and-says-so ()
  (drgnx-agents-gw-test--with
    (let ((said nil))
      (cl-letf (((symbol-function 'drgnx-hub-ensure) (lambda () (error "no hub here")))
                ((symbol-function 'message) (lambda (fmt &rest args) (when fmt (push (apply #'format fmt args) said)))))
        (let* ((s (drgnx-agents-gw-test--session "claude (OpenRouter)")) (env (drgnx-agents--env s)))
          (should (member "ANTHROPIC_BASE_URL=https://openrouter.ai/api" env))
          (should (eq (drgnx-agent-session-via s) 'direct))
          (should (seq-find (lambda (m) (string-match-p "hub" m)) said)))))))

(ert-deftest drgnx-agents/env-functions-add-strings-only ()
  ;; a function that fails, or returns anything but a list of strings, is reported; the agent still starts with the rest
  (let ((drgnx-agents-env-functions (list (lambda (_s) (error "Boom")) (lambda (_s) "BARE=string")
                                          (lambda (_s) (list "A=1" 42)) (lambda (_s) nil) (lambda (_s) '("B=2"))))
        (said nil))
    (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) said)))
              ((symbol-function 'drgnx-notify) (lambda (_s _v text &rest _) (push text said) nil)))   ; a notice, Task 20
      (let ((env (drgnx-agents--env (drgnx-agents--make :name "a" :profile "claude"))))
        ;; …and the rest is the bare names of `drgnx-agents-scrubbed-env' (variables the agent does not inherit)
        (should (equal (seq-filter (lambda (e) (string-search "=" e)) env) '("A=1" "B=2")))
        (should (equal (seq-remove (lambda (e) (string-search "=" e)) env)
                       (seq-difference drgnx-agents-scrubbed-env (cdr (assq 'claude drgnx-agents-own-env)))))
        (should (seq-find (lambda (m) (string-match-p "Boom" m)) said))
        (should (seq-find (lambda (m) (string-match-p "BARE=string" m)) said))
        (should (seq-find (lambda (m) (string-match-p "42" m)) said))))))

;;; agents-gateway-test.el ends here
