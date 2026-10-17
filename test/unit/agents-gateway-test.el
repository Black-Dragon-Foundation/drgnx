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
        (should (equal (plist-get reg :agent) "t"))))))

(ert-deftest drgnx-agents/an-ollama-or-anthropic-agent-has-its-own-chain ()
  (drgnx-agents-gw-test--with
    (drgnx-hub-serve (drgnx-hub-socket))
    (let ((drgnx-agents-profiles '(("mine" :command ("x") :ai claude-anthropic))))
      (drgnx-agents--env (drgnx-agents-gw-test--session "claude (Ollama)"))
      (drgnx-agents--env (drgnx-agents-gw-test--session "mine"))
      (should (equal (sort (mapcar (lambda (r) (plist-get (cdr r) :chain)) (drgnx-gateway-registrations))
                           (lambda (a b) (string< (symbol-name (caar a)) (symbol-name (caar b)))))
                     '(((anthropic)) ((ollama))))))))

(ert-deftest drgnx-agents/a-subscription-agent-never-gets-the-gateway ()
  (drgnx-agents-gw-test--with
    (drgnx-hub-serve (drgnx-hub-socket))
    (let* ((s (drgnx-agents-gw-test--session "claude")) (env (drgnx-agents--env s)))
      (should-not (seq-find (lambda (e) (string-prefix-p "ANTHROPIC_" e)) env))
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

;;; agents-gateway-test.el ends here
