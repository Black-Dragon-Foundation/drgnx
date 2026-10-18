;;; gateway-openrouter-test.el --- batch tests: OpenRouter's provider restrictions through the gateway -*- lexical-binding: t -*-
;; The gateway runs in the test's Emacs and a mock OpenRouter (test/fixtures/mock-llm.el) logs what it receives.
;; Every directory is a temp one; the settings page reads the agent fixture's homes.
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx)
(require 'drgnx-registry)
(require 'drgnx-keys)
(require 'drgnx-agents)
(require 'drgnx-gateway)
(require 'drgnx-hub)
(load (expand-file-name "test/fixtures/mock-llm" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/agent-config-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-agents-ui" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-agent-settings" drgnx-dir) nil t)

(defconst drgnx-gateway-openrouter-test--restrictions
  '(:only ("anthropic" "google-vertex") :ignore ("azure") :data-collection deny :zdr t)
  "The restrictions most tests use.")

(defmacro drgnx-gateway-openrouter-test--with (&rest body)
  "BODY with the gateway on PORT, a mock OpenRouter (log OR-LOG) and a mock Ollama (log OL-LOG) as the `openrouter' and
`ollama' providers, OPENROUTER_API_KEY=sk-or-test, every directory under ROOT."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-gw-or" t)))
          (or-port (+ 20000 (random 10000))) (ol-port (+ 30000 (random 10000)))
          (or-log (concat root "or.log")) (ol-log (concat root "ol.log"))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" root "config") (concat "DRGNX_DATA_DIR=" root "data")
                                             (concat "XDG_STATE_HOME=" root "state") "OPENROUTER_API_KEY=sk-or-test")
                                       process-environment))
          (drgnx-ai--keys (make-hash-table :test #'eq)) (auth-sources nil)
          (drgnx-gateway--keys (make-hash-table :test #'eq)) (drgnx-gateway--registrations (make-hash-table :test #'equal))
          (drgnx-work-db--handles nil) (mocks nil) (port nil))
     (unwind-protect
         (progn
           (make-directory (concat root "config") t)
           (with-temp-file (concat root "or.eld")
             (prin1 '((:path "/api/v1/messages" :body "{\"content\":\"ok\",\"usage\":{\"input_tokens\":1,\"output_tokens\":2}}")) (current-buffer)))
           (with-temp-file (concat root "ol.eld")
             (prin1 '((:path "/v1/messages" :body "{\"content\":\"ok\",\"usage\":{\"input_tokens\":1,\"output_tokens\":2}}")) (current-buffer)))
           (with-temp-file (concat root "config/ai.eld")
             (prin1 `(:version 1 :providers ((openrouter :name "OpenRouter" :kind openai :url ,(format "http://127.0.0.1:%d/api/v1" or-port)
                                                         :key-env "OPENROUTER_API_KEY" :caps (chat) :messages t)
                                             (ollama :name "Ollama" :kind ollama :url ,(format "http://127.0.0.1:%d" ol-port) :caps (chat) :messages t)))
                    (current-buffer)))
           (push (drgnx-ai-test-mock-llm or-port (concat root "or.eld") or-log) mocks)
           (push (drgnx-ai-test-mock-llm ol-port (concat root "ol.eld") ol-log) mocks)
           (setq port (drgnx-gateway-start))
           ,@body)
       (drgnx-gateway-stop)
       (mapc #'delete-process mocks)
       (drgnx-work-db-close-all)
       (delete-directory root t))))

(defvar drgnx-gateway-openrouter-test--answer nil "What the gateway answered the last request with.")

(defun drgnx-gateway-openrouter-test--request (port token &optional body path)
  "POST BODY (a Messages request) to PATH of the gateway at PORT with TOKEN; the status once it closed (what it
answered is in `drgnx-gateway-openrouter-test--answer')."
  (let* ((got "") (closed nil) (body (or body "{\"model\":\"claude-x\"}")) (path (or path "/v1/messages"))
         (c (open-network-stream "gw-or-test" nil "127.0.0.1" port :coding 'binary)))
    (set-process-sentinel c (lambda (_p _e) (setq closed t)))
    (set-process-filter c (lambda (_p s) (setq got (concat got s))))
    (process-send-string c (format "POST %s HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nAuthorization: Bearer %s\r\nContent-Length: %d\r\n\r\n%s"
                                   path token (length body) body))
    (let ((deadline (+ (float-time) 8))) (while (and (not closed) (< (float-time) deadline)) (accept-process-output nil 0.01)))
    (setq drgnx-gateway-openrouter-test--answer got)
    (and (string-match "\\`HTTP/1\\.[01] \\([0-9]+\\)" got) (string-to-number (match-string 1 got)))))

(defun drgnx-gateway-openrouter-test--provider (body &optional restrictions)
  "The \"provider\" object (a plist) in the body the gateway builds from the JSON text BODY with RESTRICTIONS."
  (plist-get (json-parse-string (drgnx-gateway--body (list :body body) nil (drgnx-gateway-restrictions restrictions))
                                :object-type 'plist)
             :provider))

(defun drgnx-gateway-openrouter-test--log (file)
  (if (file-exists-p file) (with-temp-buffer (insert-file-contents file) (buffer-string)) ""))

(ert-deftest drgnx-gateway-openrouter/restrictions-reach-the-body ()
  (drgnx-gateway-openrouter-test--with
    (let ((token (drgnx-gateway-register
                  (list :chain '((openrouter . "m1"))
                        :openrouter (drgnx-gateway-restrictions drgnx-gateway-openrouter-test--restrictions)))))
      (should (= (drgnx-gateway-openrouter-test--request port token) 200))
      (let ((sent (drgnx-gateway-openrouter-test--log or-log)))
        (should (string-search "\"model\":\"m1\"" sent))
        (should (string-search "\"only\":[\"anthropic\",\"google-vertex\"]" sent))
        (should (string-search "\"ignore\":[\"azure\"]" sent))
        (should (string-search "\"data_collection\":\"deny\"" sent))
        (should (string-search "\"zdr\":true" sent))))
    ;; the body function alone: the provider object is top level, the model still replaced, nothing else touched
    (let* ((req (list :body "{\"model\":\"x\",\"max_tokens\":5}"))
           (json (json-parse-string (drgnx-gateway--body req "m1" (drgnx-gateway-restrictions drgnx-gateway-openrouter-test--restrictions))
                                    :object-type 'plist)))
      (should (equal (plist-get json :model) "m1"))
      (should (equal (plist-get json :max_tokens) 5))
      (should (equal (plist-get (plist-get json :provider) :data_collection) "deny")))
    ;; the model of the request stays when the chain names none
    (should (equal (plist-get (json-parse-string
                               (drgnx-gateway--body (list :body "{\"model\":\"x\"}") nil '(:zdr t)) :object-type 'plist)
                              :model)
                   "x"))))

(ert-deftest drgnx-gateway-openrouter/a-client-provider-object-is-merged-the-stricter-wins ()
  (let* ((mine '(:only ("anthropic" "google-vertex") :ignore ("azure") :data-collection deny :zdr t))
         (body (lambda (provider) (format "{\"model\":\"x\",\"provider\":%s}" provider))))
    ;; only: the intersection (drgnx's order); one side alone is kept
    (should (equal (plist-get (drgnx-gateway-openrouter-test--provider
                               (funcall body "{\"only\":[\"google-vertex\",\"openai\"]}") mine)
                              :only)
                   ["google-vertex"]))
    (should (equal (plist-get (drgnx-gateway-openrouter-test--provider (funcall body "{\"order\":[\"openai\"]}") mine) :only)
                   ["anthropic" "google-vertex"]))
    (should (equal (plist-get (drgnx-gateway-openrouter-test--provider (funcall body "{\"only\":[\"openai\"]}") '(:zdr t)) :only)
                   ["openai"]))
    ;; ignore: the union
    (should (equal (plist-get (drgnx-gateway-openrouter-test--provider (funcall body "{\"ignore\":[\"openai\",\"azure\"]}") mine)
                              :ignore)
                   ["openai" "azure"]))
    ;; data_collection: deny wins, from either side
    (should (equal (plist-get (drgnx-gateway-openrouter-test--provider (funcall body "{\"data_collection\":\"allow\"}") mine)
                              :data_collection)
                   "deny"))
    (should (equal (plist-get (drgnx-gateway-openrouter-test--provider (funcall body "{\"data_collection\":\"deny\"}") '(:zdr t))
                              :data_collection)
                   "deny"))
    ;; zdr: either asks for it
    (should (eq (plist-get (drgnx-gateway-openrouter-test--provider (funcall body "{\"zdr\":false}") mine) :zdr) t))
    (should (eq (plist-get (drgnx-gateway-openrouter-test--provider (funcall body "{\"zdr\":true}") '(:only ("a"))) :zdr) t))
    (should (eq (plist-get (drgnx-gateway-openrouter-test--provider (funcall body "{\"zdr\":false}") '(:only ("a"))) :zdr) :false))
    ;; every other key passes through
    (let ((p (drgnx-gateway-openrouter-test--provider
              (funcall body "{\"order\":[\"openai\"],\"sort\":\"price\",\"require_parameters\":true,\"allow_fallbacks\":false}") mine)))
      (should (equal (plist-get p :order) ["openai"]))
      (should (equal (plist-get p :sort) "price"))
      (should (eq (plist-get p :require_parameters) t))
      (should (eq (plist-get p :allow_fallbacks) :false)))
    ;; without restrictions the client's object is not touched
    (should (equal (drgnx-gateway--body (list :body (funcall body "{\"only\":[\"x\"]}")) nil nil)
                   (funcall body "{\"only\":[\"x\"]}")))))

(ert-deftest drgnx-gateway-openrouter/no-provider-in-common-is-a-400-and-nothing-is-sent ()
  (drgnx-gateway-openrouter-test--with
    (let ((token (drgnx-gateway-register
                  (list :chain '((openrouter . "m1")) :openrouter (drgnx-gateway-restrictions '(:only ("anthropic")))))))
      (should (= (drgnx-gateway-openrouter-test--request
                  port token "{\"model\":\"x\",\"provider\":{\"only\":[\"openai\"]}}")
                 400))
      (should (string-search "invalid_request_error" drgnx-gateway-openrouter-test--answer))
      (should (string-search "no provider in common" drgnx-gateway-openrouter-test--answer))
      (should (equal (drgnx-gateway-openrouter-test--log or-log) "")))))

(ert-deftest drgnx-gateway-openrouter/a-body-that-cannot-be-read-is-refused-with-restrictions ()
  (drgnx-gateway-openrouter-test--with
    (let ((token (drgnx-gateway-register
                  (list :chain '((openrouter . "m1")) :openrouter (drgnx-gateway-restrictions drgnx-gateway-openrouter-test--restrictions))))
          (plain (drgnx-gateway-register (list :chain '((openrouter . "m1"))))))
      (dolist (bad '("this is not json" "[1,2]" "{\"model\":\"x\",\"provider\":\"anthropic\"}"))
        (should (= (drgnx-gateway-openrouter-test--request port token bad) 400))
        (should (string-search "invalid_request_error" drgnx-gateway-openrouter-test--answer)))
      (should (equal (drgnx-gateway-openrouter-test--log or-log) ""))
      ;; an empty object is a body: the restrictions are added to it
      (should (= (drgnx-gateway-openrouter-test--request port token "{}") 200))
      (should (string-search "\"zdr\":true" (drgnx-gateway-openrouter-test--log or-log)))
      ;; no restrictions, nothing to fail closed on: the bytes go as they were
      (should (= (drgnx-gateway-openrouter-test--request port plain "this is not json") 200))
      (should (string-search "this is not json" (drgnx-gateway-openrouter-test--log or-log))))))

(ert-deftest drgnx-gateway-openrouter/only-the-messages-endpoint-gets-the-provider-object ()
  (drgnx-gateway-openrouter-test--with
    (let ((token (drgnx-gateway-register
                  (list :chain '((openrouter . "m1"))
                        :openrouter (drgnx-gateway-restrictions drgnx-gateway-openrouter-test--restrictions)))))
      (drgnx-gateway-openrouter-test--request port token "{\"model\":\"x\",\"messages\":[]}" "/v1/messages/count_tokens")
      (let ((sent (drgnx-gateway-openrouter-test--log or-log)))
        (should (string-search "POST /api/v1/messages/count_tokens" sent))
        (should-not (string-search "provider" sent))
        (should-not (string-search "zdr" sent)))
      ;; the Messages path with a query (Claude Code sends ?beta=true) does
      (drgnx-gateway-openrouter-test--request port token nil "/v1/messages?beta=true")
      (should (string-search "\"zdr\":true" (drgnx-gateway-openrouter-test--log or-log))))))

(ert-deftest drgnx-gateway-openrouter/restrictions-travel-from-agents-eld-to-the-registration ()
  ;; drgnx-agents--gateway: agents.eld's :openrouter reaches the registration of an OpenRouter agent, through the hub's
  ;; register call, which keeps it as lists (the JSON call turns them into vectors)
  (drgnx-gateway-openrouter-test--with
    (let ((drgnx-agents-profiles nil) (drgnx-hub--exit-function #'drgnx-hub-stop))
      (unwind-protect
          (progn
            (drgnx-hub-serve (drgnx-hub-socket))
            (drgnx-agents-set-setting :openrouter drgnx-gateway-openrouter-test--restrictions)
            (let ((s (drgnx-agents--make :name "t" :profile "claude (OpenRouter)" :cwd temporary-file-directory)))
              (drgnx-agents--env s)
              (let ((reg (cdar (drgnx-gateway-registrations))))
                (should (equal (plist-get reg :openrouter) drgnx-gateway-openrouter-test--restrictions))))
            (let ((json (drgnx-hub-register (list :chain '(("openrouter" nil))
                                                  :openrouter '(:only ["a/b"] :ignore [] :data-collection "allow" :zdr :false)))))
              (should (equal (plist-get (gethash (drgnx-gateway--hash (plist-get json :token)) drgnx-gateway--registrations)
                                        :openrouter)
                             '(:only ("a/b") :data-collection allow)))
              ;; the answer says what was kept, so an editor can tell a hub that dropped them
              (should (equal (plist-get json :openrouter) '(:only ("a/b") :data-collection allow)))))
        (drgnx-hub-disconnect)
        (drgnx-hub-stop)))))

;;;; Fail closed (final review C1, I1, I2)

(defun drgnx-gateway-openrouter-test--session (&optional profile)
  (drgnx-agents--make :name "t" :profile (or profile "claude (OpenRouter)") :cwd temporary-file-directory))

(ert-deftest drgnx-gateway-openrouter/no-hub-with-restrictions-refuses ()
  ;; the restrictions apply through the hub's gateway only: without a hub, an OpenRouter agent with restrictions does
  ;; not start (directly it would reach OpenRouter with none of them); its session says why
  (drgnx-gateway-openrouter-test--with
    (let ((drgnx-agents-profiles nil) (drgnx-agents--sessions nil) (started nil))
      (drgnx-agents-set-setting :openrouter drgnx-gateway-openrouter-test--restrictions)
      (cl-letf (((symbol-function 'drgnx-hub-ensure) (lambda () (error "No hub here")))
                ((symbol-function 'drgnx-acp-start) (lambda (&rest args) (push args started) nil)))
        (let* ((s (drgnx-gateway-openrouter-test--session))
               (err (should-error (drgnx-agents--env s) :type 'user-error)))
          (should (string-search "OpenRouter restrictions" (error-message-string err)))
          (should (string-search "No hub here" (error-message-string err)))
          (should-not (eq (drgnx-agent-session-via s) 'direct)))
        (let ((s (drgnx-agents-start "claude (OpenRouter)" temporary-file-directory)))
          (should-not started)                                    ; no agent ran, with any environment
          (should (eq (drgnx-agent-session-status s) 'exited))
          (should (seq-find (lambda (e) (string-search "OpenRouter restrictions" (or (plist-get e :text) "")))
                            (drgnx-agent-session-entries s))))
        ;; without restrictions it goes direct, as before
        (drgnx-agents-set-setting :openrouter nil)
        (let ((s (drgnx-gateway-openrouter-test--session)))
          (should (seq-find (lambda (e) (string-prefix-p "ANTHROPIC_BASE_URL=" e)) (drgnx-agents--env s)))
          (should (eq (drgnx-agent-session-via s) 'direct)))))))

(ert-deftest drgnx-gateway-openrouter/gateway-off-with-restrictions-refuses ()
  ;; restrictions are never dropped silently: with the gateway turned off, an OpenRouter agent with restrictions does
  ;; not start either, and says how to fix it; without restrictions, or without an OpenRouter step, it goes direct
  (drgnx-gateway-openrouter-test--with
    (let ((drgnx-agents-profiles nil) (drgnx-agents--sessions nil) (drgnx-agents-use-gateway nil) (started nil)
          (hub-asked nil))
      (drgnx-agents-set-setting :openrouter drgnx-gateway-openrouter-test--restrictions)
      (cl-letf (((symbol-function 'drgnx-hub-ensure) (lambda () (setq hub-asked t)))
                ((symbol-function 'drgnx-acp-start) (lambda (&rest args) (push args started) nil)))
        (let* ((s (drgnx-gateway-openrouter-test--session))
               (err (should-error (drgnx-agents--env s) :type 'user-error)))
          (should (string-search "OpenRouter restrictions" (error-message-string err)))
          (should (string-search "turned off" (error-message-string err)))
          (should (string-search "drgnx-agents-use-gateway" (error-message-string err)))
          (should (string-search "remove :openrouter" (error-message-string err))))
        (let ((s (drgnx-agents-start "claude (OpenRouter)" temporary-file-directory)))
          (should-not started)
          (should (eq (drgnx-agent-session-status s) 'exited))
          (should (seq-find (lambda (e) (string-search "turned off" (or (plist-get e :text) "")))
                            (drgnx-agent-session-entries s))))
        ;; a value that does not read refuses too
        (drgnx-agents-set-setting :openrouter '(:zdr yes))
        (should-error (drgnx-agents--env (drgnx-gateway-openrouter-test--session)) :type 'user-error)
        ;; no OpenRouter step: not held up
        (should (drgnx-agents--env (drgnx-gateway-openrouter-test--session "claude (Ollama)")))
        ;; no restrictions: direct, as before
        (drgnx-agents-set-setting :openrouter nil)
        (should (seq-find (lambda (e) (string-prefix-p "ANTHROPIC_BASE_URL=" e))
                          (drgnx-agents--env (drgnx-gateway-openrouter-test--session))))
        (should-not hub-asked)))))

(ert-deftest drgnx-gateway-openrouter/restrictions-that-cannot-be-read-refuse-the-start ()
  ;; a typo never turns a restriction off: an agents.eld that does not read, or an :openrouter value that is not one,
  ;; refuses the OpenRouter agent's start, naming the problem; the hub refuses such a registration itself
  (drgnx-gateway-openrouter-test--with
    (let ((drgnx-agents-profiles nil) (drgnx-hub--exit-function #'drgnx-hub-stop)
          (file (concat root "config/agents.eld")))
      (unwind-protect
          (progn
            (drgnx-hub-serve (drgnx-hub-socket))
            (pcase-dolist (`(,text . ,named)
                           '(("(:openrouter (:zdr t)" . "agents.eld")             ; a parenthesis short
                             ("(:openrouter (:only \"anthropic\"))" . ":only")    ; a string, not a list
                             ("(:openrouter (:only (\"bad slug!\")))" . ":only")
                             ("(:openrouter (:ignore (anthropic)))" . ":ignore")   ; a symbol, not a slug
                             ("(:openrouter (:zdr 1))" . ":zdr")
                             ("(:openrouter (:zdr yes))" . ":zdr")
                             ("(:openrouter (:data-collection no))" . ":data-collection")
                             ("(:openrouter (:zdrr t))" . ":zdrr")                ; a key that is not one
                             ("(:openrouter \"anthropic\")" . ":openrouter")))
              (with-temp-file file (insert ";; mine\n" text "\n"))
              (let ((err (should-error (drgnx-agents--env (drgnx-gateway-openrouter-test--session)) :type 'user-error)))
                (should (string-search named (error-message-string err))))
              (should-not (drgnx-gateway-registrations)))
            ;; a file of comments only has no restrictions
            (with-temp-file file (insert ";; nothing yet\n"))
            (should-not (drgnx-agents-openrouter-restrictions))
            ;; empty values are no restriction, as the JSON call carries them
            (with-temp-file file (insert "(:openrouter (:only () :zdr nil))\n"))
            (should-not (drgnx-agents-openrouter-restrictions))
            ;; an agent with no OpenRouter step is not held up by a broken value
            (with-temp-file file (insert "(:openrouter (:zdr yes))\n"))
            (drgnx-agents--env (drgnx-gateway-openrouter-test--session "claude (Ollama)"))
            (should (= (length (drgnx-gateway-registrations)) 1))
            ;; the hub: in this Emacs and over its socket
            (should-error (drgnx-hub-register (list :chain '(("openrouter" nil)) :openrouter '(:zdr "yes"))))
            (should-error (drgnx-hub-call-sync "gateway/register"
                                               (list :chain [["openrouter" nil]] :openrouter '(:only "anthropic"))))
            (should (= (length (drgnx-gateway-registrations)) 1)))
        (drgnx-hub-disconnect)
        (drgnx-hub-stop)))))

(ert-deftest drgnx-gateway-openrouter/a-hub-that-drops-them-is-refused ()
  ;; a hub started before restrictions existed keeps a registration without them: its answer says what it kept, and
  ;; an agent whose restrictions it did not keep does not start (its token is given back)
  (drgnx-gateway-openrouter-test--with
    (let ((drgnx-agents-profiles nil) (answer nil) (calls nil))
      (drgnx-agents-set-setting :openrouter drgnx-gateway-openrouter-test--restrictions)
      (cl-letf (((symbol-function 'drgnx-hub-ensure) #'ignore)
                ((symbol-function 'drgnx-hub-serving-p) #'ignore)
                ((symbol-function 'drgnx-hub-call-sync) (lambda (method &rest _) (push method calls) answer))
                ((symbol-function 'drgnx-hub-call) (lambda (method params &rest _) (push (list method params) calls))))
        (dolist (a '((:token "tok-old" :url "http://127.0.0.1:1")                               ; says nothing
                     (:token "tok-less" :url "http://127.0.0.1:1" :openrouter (:only ("anthropic")))))  ; kept fewer
          (setq answer a calls nil)
          (let* ((s (drgnx-gateway-openrouter-test--session))
                 (err (should-error (drgnx-agents--env s) :type 'user-error)))
            (should (string-search "drgnx hub stop" (error-message-string err)))
            (should (member (list "gateway/unregister" (list :token (plist-get a :token))) calls))
            (should-not (drgnx-agent-session-gateway s))))
        ;; what it kept, as JSON brings it back: the agent starts through it
        (setq answer '(:token "tok-ok" :url "http://127.0.0.1:1"
                              :openrouter (:only ("anthropic" "google-vertex") :ignore ("azure") :data-collection "deny" :zdr t))
              calls nil)
        (let ((s (drgnx-gateway-openrouter-test--session)))
          (should (member "ANTHROPIC_BASE_URL=http://127.0.0.1:1" (drgnx-agents--env s)))
          (should (eq (drgnx-agent-session-via s) 'gateway))
          (should-not (assoc "gateway/unregister" calls)))))))

(ert-deftest drgnx-gateway-openrouter/other-providers-untouched ()
  (drgnx-gateway-openrouter-test--with
    ;; an Ollama step in a registration that has restrictions: its body is the request's, only the model replaced
    (let ((token (drgnx-gateway-register
                  (list :chain '((ollama . "q"))
                        :openrouter (drgnx-gateway-restrictions drgnx-gateway-openrouter-test--restrictions)))))
      (should (= (drgnx-gateway-openrouter-test--request port token) 200))
      (let ((sent (drgnx-gateway-openrouter-test--log ol-log)))
        (should (string-search "\"model\":\"q\"" sent))
        (should-not (string-search "provider" sent))
        (should-not (string-search "zdr" sent))))
    ;; no restrictions: OpenRouter's body has no provider object either
    (let ((token (drgnx-gateway-register (list :chain '((openrouter . "m1"))))))
      (should (= (drgnx-gateway-openrouter-test--request port token) 200))
      (should-not (string-search "\"provider\"" (drgnx-gateway-openrouter-test--log or-log))))
    ;; the body function without a provider object is what it was
    (should (equal (drgnx-gateway--body (list :body "{\"model\":\"x\",\"a\":1}") "m1") "{\"model\":\"m1\",\"a\":1}"))
    (should (equal (drgnx-gateway--body (list :body "{\"model\":\"x\",\"a\":1}") nil) "{\"model\":\"x\",\"a\":1}"))
    ;; an agent whose chain has no OpenRouter step is registered without them
    (let ((drgnx-agents-profiles nil) (drgnx-hub--exit-function #'drgnx-hub-stop))
      (unwind-protect
          (progn
            (drgnx-hub-serve (drgnx-hub-socket))
            (drgnx-agents-set-setting :openrouter drgnx-gateway-openrouter-test--restrictions)
            (drgnx-agents--env (drgnx-agents--make :name "o" :profile "claude (Ollama)" :cwd temporary-file-directory))
            (let ((reg (cdar (drgnx-gateway-registrations))))
              (should reg)
              (should-not (plist-get reg :openrouter))))
        (drgnx-hub-disconnect)
        (drgnx-hub-stop)))))

(ert-deftest drgnx-gateway-openrouter/saved-in-agents-eld-comments-kept ()
  (let* ((root (file-name-as-directory (make-temp-file "drgnx-gw-or" t)))
         (process-environment (cons (concat "DRGNX_CONFIG_DIR=" root) process-environment))
         (file (concat root "agents.eld")))
    (unwind-protect
        (progn
          (should-not (drgnx-agents-openrouter-restrictions))
          (with-temp-file file (insert ";; my agents\n(:default \"claude\"   ; the usual one\n :mcp (coordination))\n"))
          (drgnx-agents-set-setting :openrouter drgnx-gateway-openrouter-test--restrictions)
          (let ((text (with-temp-buffer (insert-file-contents file) (buffer-string))))
            (should (string-search ";; my agents" text))
            (should (string-search "; the usual one" text))
            (should (string-search ":mcp (coordination)" text)))
          (should (equal (drgnx-agents-default-profile) "claude"))
          (should (equal (drgnx-agents-openrouter-restrictions) drgnx-gateway-openrouter-test--restrictions))
          ;; saving again replaces the value only
          (drgnx-agents-set-setting :openrouter '(:only ("anthropic") :data-collection allow))
          (should (equal (drgnx-agents-openrouter-restrictions) '(:only ("anthropic") :data-collection allow)))
          (should (string-search "; the usual one" (with-temp-buffer (insert-file-contents file) (buffer-string))))
          ;; what is not a restriction is refused when read, never read as none: slugs that could break the JSON or
          ;; the line, odd values
          (drgnx-agents-set-setting :openrouter '(:only ("ok" "bad\"slug" 5) :ignore "x" :data-collection maybe :zdr maybe))
          (should-error (drgnx-agents-openrouter-restrictions) :type 'user-error)
          (drgnx-agents-set-setting :openrouter nil)
          (should-not (drgnx-agents-openrouter-restrictions)))
      (delete-directory root t))))

(defun drgnx-gateway-openrouter-test--page-text (use-gateway root)
  "The text of Claude Code's settings page for ROOT, USE-GATEWAY as `drgnx-agents-use-gateway'."
  (let ((drgnx-agents-use-gateway use-gateway))
    (with-current-buffer (drgnx-agent-settings-open 'claude root)
      (prog1 (buffer-string) (kill-buffer (current-buffer))))))

(ert-deftest drgnx-gateway-openrouter/direct-route-says-gateway-only ()
  (drgnx-agent-config-test-env
    (let ((process-environment (cons (concat "DRGNX_CONFIG_DIR=" home "cfg") process-environment))
          (drgnx-agents-profiles nil))
      (drgnx-agents-set-setting :openrouter drgnx-gateway-openrouter-test--restrictions)
      ;; gateway off with restrictions: the page says the agents do not start, and how to fix it
      (let ((text (drgnx-gateway-openrouter-test--page-text nil root)))
        (should (string-search "OpenRouter restrictions: only anthropic, google-vertex" text))
        (should (string-search "the gateway is turned off, so OpenRouter agents do not start" text))
        (should (string-search "turn it on (drgnx-agents-use-gateway) or remove the restrictions" text))
        (should (string-search "[Change…]" text)))
      ;; gateway off without restrictions: the setting does not apply, and where the account's settings are
      (drgnx-agents-set-setting :openrouter nil)
      (let ((text (drgnx-gateway-openrouter-test--page-text nil root)))
        (should (string-search "applies through drgnx's gateway only; without it, your OpenRouter account settings apply" text))
        (should (string-search "https://openrouter.ai/settings/privacy" text)))
      (drgnx-agents-set-setting :openrouter drgnx-gateway-openrouter-test--restrictions)
      ;; through the gateway: the restrictions are shown, with a Change button
      (let ((text (drgnx-gateway-openrouter-test--page-text t root)))
        (should (string-search "OpenRouter restrictions" text))
        (should (string-search "only anthropic, google-vertex" text))
        (should (string-search "never azure" text))
        (should (string-search "[Change…]" text))
        (should-not (string-search "applies through drgnx's gateway only" text))))))

(ert-deftest drgnx-gateway-openrouter/the-page-says-when-they-cannot-be-read ()
  (drgnx-agent-config-test-env
    (let ((process-environment (cons (concat "DRGNX_CONFIG_DIR=" home "cfg") process-environment))
          (drgnx-agents-profiles nil))
      (make-directory (concat home "cfg") t)
      (with-temp-file (concat home "cfg/agents.eld") (insert "(:openrouter (:zdr yes))\n"))
      (let ((text (drgnx-gateway-openrouter-test--page-text t root)))
        (should (string-search "OpenRouter restrictions: unreadable" text))
        (should (string-search ":zdr" text))
        (should (string-search "OpenRouter agents do not start" text))))))

(ert-deftest drgnx-gateway-openrouter/the-command-asks-and-saves ()
  (drgnx-agent-config-test-env
    (let ((process-environment (cons (concat "DRGNX_CONFIG_DIR=" home "cfg") process-environment))
          (drgnx-agents-profiles nil) (answers (list "anthropic, google-vertex" "azure" "deny" t)))
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) (pop answers)))
                ((symbol-function 'completing-read) (lambda (&rest _) (pop answers)))
                ((symbol-function 'y-or-n-p) (lambda (&rest _) (pop answers))))
        (with-current-buffer (drgnx-agent-settings-open 'claude root)
          (unwind-protect
              (progn (drgnx-agent-settings-openrouter)
                     (should-not answers)
                     (should (equal (drgnx-agents-openrouter-restrictions) drgnx-gateway-openrouter-test--restrictions)))
            (kill-buffer (current-buffer))))
        ;; a slug that is not one is refused and nothing is saved
        (setq answers (list "bad slug!" "" "allow" nil))
        (with-current-buffer (drgnx-agent-settings-open 'claude root)
          (unwind-protect
              (progn (should-error (drgnx-agent-settings-openrouter) :type 'user-error)
                     (should (equal (drgnx-agents-openrouter-restrictions) drgnx-gateway-openrouter-test--restrictions)))
            (kill-buffer (current-buffer))))))))

(ert-deftest drgnx-gateway-openrouter/the-zdr-question-says-what-n-does ()
  (drgnx-agent-config-test-env
    (let ((process-environment (cons (concat "DRGNX_CONFIG_DIR=" home "cfg") process-environment))
          (drgnx-agents-profiles nil) (answers nil) (asked nil))
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) (pop answers)))
                ((symbol-function 'completing-read) (lambda (&rest _) (pop answers)))
                ((symbol-function 'y-or-n-p) (lambda (prompt) (push prompt asked) (pop answers))))
        (with-current-buffer (drgnx-agent-settings-open 'claude root)
          (unwind-protect
              (progn
                ;; on: the question says that n turns it off, and n does
                (drgnx-agents-set-setting :openrouter '(:zdr t))
                (setq answers (list "" "" "allow" nil))
                (drgnx-agent-settings-openrouter)
                (should (string-search "now on; n turns it off" (car asked)))
                (should-not (drgnx-agents-openrouter-restrictions))
                ;; off: the question says it is off
                (setq answers (list "" "" "allow" nil))
                (drgnx-agent-settings-openrouter)
                (should (string-search "now off" (car asked))))
            (kill-buffer (current-buffer))))))))

(ert-deftest drgnx-gateway-openrouter/the-command-is-registered-with-keys ()
  (drgnx-agent-settings--setup)
  (should (drgnx-commands-get 'agent-settings-openrouter))
  (dolist (profile '("vscode" "emacs" "vim"))
    (let ((text (with-temp-buffer (insert-file-contents (expand-file-name (format "keys/%s.eld" profile) drgnx-dir)) (buffer-string))))
      (should (string-match-p "(agent-settings-openrouter \"r\" :map (drgnx-agent-settings \\. drgnx-agent-settings-mode-map))" text)))))

;;; gateway-openrouter-test.el ends here
