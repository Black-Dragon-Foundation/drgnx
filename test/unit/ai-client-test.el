;;; ai-client-test.el --- batch tests: requests to providers, fallback, cancel, probes, the doctor's ai check -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-ai-client)
(require 'drgnx-ai-probe)
(require 'drgnx-doctor)
(load (expand-file-name "test/fixtures/mock-llm" drgnx-dir) nil t)

(defmacro drgnx-ai-client-test--with (spec &rest body)
  "BODY with a mock LLM server answering SPEC (a list of answers, see mock-llm.el) on PORT, its LOG, and providers
`a' (openai), `o' (ollama), `l' (llama.cpp) and `dead' (nothing listens) pointing at it in `drgnx-ai-providers' — all
keyless, so asked directly — and `k' (openai, key in K_KEY), which only the hub's gateway may ask (ai-gateway-test.el)."
  (declare (indent 1))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-ai-client" t)))
          (port nil) (dead nil)
          (log (concat root "llm.log")) (script (concat root "llm.eld"))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" root "config") (concat "XDG_STATE_HOME=" root "state")
                                             (concat "XDG_RUNTIME_DIR=" root "run") "DRGNX_NO_HUB_START=1" "K_KEY=sk-test-123")
                                       process-environment))
          (auth-sources nil) (drgnx-ai--keys (make-hash-table :test #'eq)) (drgnx-ai-detected nil)
          (drgnx-ai-providers nil) (drgnx-ai-roles nil)
          (mock nil))
     (unwind-protect
         (progn
           (make-directory (concat root "config") t)
           (with-temp-file script (prin1 ,spec (current-buffer)))
           (setq mock (drgnx-ai-test-mock-llm nil script log)
                 port (process-get mock :port)
                 dead (drgnx-test-free-port))
           (setq drgnx-ai-providers `((a :name "A" :kind openai :url ,(format "http://127.0.0.1:%d/v1" port) :caps (chat fim))
                                      (k :name "K" :kind openai :url ,(format "http://127.0.0.1:%d/v1" port) :key-env "K_KEY" :caps (chat fim))
                                      (o :name "O" :kind ollama :url ,(format "http://127.0.0.1:%d" port) :caps (chat fim))
                                      (l :name "L" :kind llamacpp :url ,(format "http://127.0.0.1:%d" port) :caps (chat fim))
                                      (dead :name "Dead" :kind openai :url ,(format "http://127.0.0.1:%d/v1" dead) :caps (chat fim))))
           ,@body)
       (when mock (delete-process mock))
       (delete-directory root t))))

(defun drgnx-ai-client-test--call (chain kind payload &optional timeout)
  "Run a request along CHAIN and wait for it: (TEXT . INFO)."
  (let ((drgnx-ai-client-test--roles (list (cons 'test chain))) result)
    (cl-letf (((symbol-function 'drgnx-ai-role) (lambda (_r) chain)))
      (drgnx-ai-request 'test kind payload (lambda (text info) (setq result (cons text info))) :timeout (or timeout 5)))
    (let ((deadline (+ (float-time) 15)))
      (while (and (not result) (< (float-time) deadline)) (accept-process-output nil 0.02)))
    result))

(defvar drgnx-ai-client-test--roles nil)

(ert-deftest drgnx-ai-client/what-cannot-be-sent-falls-back-and-leaves-nothing-behind ()
  ;; a raw byte in the buffer (json-serialize refuses it), no curl: a reason, never an error in a timer
  (drgnx-ai-client-test--with '((:path "/api/generate" :body "{\"response\":\"ok\"}"))
    (let ((buffers (length (buffer-list))))
      (let ((r (drgnx-ai-client-test--call '((o . "m")) 'fim (list :prefix (string (unibyte-char-to-multibyte #xff)) :suffix ""))))
        (should-not (car r))
        (should (string-search "cannot send" (plist-get (cdr r) :error))))
      (let* ((exec-path nil) (r (drgnx-ai-client-test--call '((o . "m")) 'fim '(:prefix "a" :suffix ""))))
        (should-not (car r))
        (should (string-search "cannot send" (plist-get (cdr r) :error))))
      (should (= (length (buffer-list)) buffers)))))

(defun drgnx-ai-client-test--log (log) (if (file-exists-p log) (with-temp-buffer (insert-file-contents log) (buffer-string)) ""))

(ert-deftest drgnx-ai-client/chat-and-fill-in-the-middle-for-each-kind-of-provider ()
  (drgnx-ai-client-test--with
      '((:path "/v1/chat/completions" :body "{\"choices\":[{\"message\":{\"content\":\"openai says hi\"}}]}")
        (:path "/v1/completions" :body "{\"choices\":[{\"text\":\"middle\"}]}")
        (:path "/api/chat" :body "{\"message\":{\"content\":\"ollama says hi\"}}")
        (:path "/api/generate" :body "{\"response\":\"ollama middle\"}")
        (:path "/infill" :body "{\"content\":\"llama middle\"}"))
    (let ((msgs '(:messages [(:role "user" :content "hi")])) (fim '(:prefix "a(" :suffix ")" :max-tokens 16)))
      (should (equal (car (drgnx-ai-client-test--call '((a . "m")) 'chat msgs)) "openai says hi"))
      (should (equal (car (drgnx-ai-client-test--call '((a . "m")) 'fim fim)) "middle"))
      (should (equal (car (drgnx-ai-client-test--call '((o . "m")) 'chat msgs)) "ollama says hi"))
      (should (equal (car (drgnx-ai-client-test--call '((o . "m")) 'fim fim)) "ollama middle"))
      (should (equal (car (drgnx-ai-client-test--call '((l . "m")) 'fim fim)) "llama middle"))
      ;; the suffix reaches every FIM endpoint, each in its own field
      (let ((request (lambda (path) (seq-find (lambda (r) (string-search (concat "POST " path " ") r))
                                              (split-string (drgnx-ai-client-test--log log) "\n---\n")))))
        (should (string-search "\"suffix\":\")\"" (funcall request "/v1/completions")))
        (should (string-search "\"suffix\":\")\"" (funcall request "/api/generate")))
        (should (string-search "\"input_suffix\":\")\"" (funcall request "/infill")))))))

(ert-deftest drgnx-ai-client/the-key-travels-as-a-header-never-in-a-command-line ()
  ;; the bearer token curl sends (toward the gateway, the editor token) goes in its standard input, never its arguments
  (drgnx-ai-client-test--with '((:path "/v1/chat/completions" :delay 0.5 :body "{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}"))
    (let ((proc (drgnx-ai--curl (format "http://127.0.0.1:%d/v1/chat/completions" port) #'ignore
                                :key "sk-test-123" :body '(:messages []) :timeout 5)))
      (should (processp proc))
      (should-not (seq-find (lambda (a) (string-search "sk-test-123" a)) (process-command proc)))
      (let ((deadline (+ (float-time) 10))) (while (and (process-live-p proc) (< (float-time) deadline)) (accept-process-output nil 0.05)))
      (should (string-search "Authorization: Bearer sk-test-123" (drgnx-ai-client-test--log log))))))

(ert-deftest drgnx-ai-client/a-hanging-or-failing-provider-falls-back-to-the-next ()
  (drgnx-ai-client-test--with
      '((:path "/v1/chat/completions" :match "\"model\":\"hang\"" :status 0)
        (:path "/v1/chat/completions" :match "\"model\":\"busy\"" :status 429 :body "{\"error\":\"rate\"}")
        (:path "/v1/chat/completions" :match "\"model\":\"broken\"" :status 500 :body "oops")
        (:path "/v1/chat/completions" :match "\"model\":\"cut\"" :body "{\"choices\":[{\"mess")
        (:path "/api/chat" :body "{\"message\":{\"content\":\"the fallback\"}}"))
    (let* ((msgs '(:messages [(:role "user" :content "x")]))
           (r (drgnx-ai-client-test--call '((dead . "m") (a . "hang") (a . "busy") (a . "broken") (a . "cut") (o . "m")) 'chat msgs 1)))
      (should (equal (car r) "the fallback"))
      (should (equal (plist-get (cdr r) :provider) 'o))
      (should (equal (mapcar #'cdr (plist-get (cdr r) :fallbacks))                ; each failure, and why
                     '("no answer" "no answer" "HTTP 429" "HTTP 500" "an answer that does not parse"))))
    (let ((r (drgnx-ai-client-test--call '((dead . "m")) 'chat '(:messages [(:role "user" :content "x")]) 1)))
      (should-not (car r))
      (should (stringp (plist-get (cdr r) :error))))))                           ; none left: said, not thrown

(ert-deftest drgnx-ai-client/a-keyed-provider-is-never-asked-directly ()
  ;; k's key is in this Emacs's environment, but no hub runs: k is skipped, never called with it, and the chain goes on
  (drgnx-ai-client-test--with '((:path "/v1/chat/completions" :body "{\"choices\":[{\"message\":{\"content\":\"direct\"}}]}")
                                (:path "/api/chat" :body "{\"message\":{\"content\":\"local\"}}"))
    (let ((r (drgnx-ai-client-test--call '((k . "m") (o . "m")) 'chat '(:messages [(:role "user" :content "x")]))))
      (should (equal (car r) "local"))
      (should (eq (plist-get (cdr r) :provider) 'o))
      (should-not (string-search "/v1/chat" (drgnx-ai-client-test--log log)))
      (should-not (string-search "sk-test-123" (drgnx-ai-client-test--log log))))))

(ert-deftest drgnx-ai-client/a-cancelled-request-never-answers ()
  (drgnx-ai-client-test--with '((:path "/v1/chat/completions" :delay 1 :body "{\"choices\":[{\"message\":{\"content\":\"late\"}}]}"))
    (let (called h)
      (cl-letf (((symbol-function 'drgnx-ai-role) (lambda (_r) '((a . "m")))))
        (setq h (drgnx-ai-request 'test 'chat '(:messages [(:role "user" :content "x")]) (lambda (&rest _) (setq called t)))))
      (drgnx-ai-cancel h)
      (let ((deadline (+ (float-time) 2))) (while (< (float-time) deadline) (accept-process-output nil 0.05)))
      (should-not called)
      (should-not (process-live-p (drgnx-ai-request-process h))))))

(ert-deftest drgnx-ai-probe/finds-running-providers-and-tells-tei-from-localai ()
  (drgnx-ai-client-test--with
      '((:path "/api/tags" :body "{\"models\":[{\"name\":\"qwen2.5-coder:1.5b\"}]}")
        (:path "/info" :body "{\"model_id\":\"BAAI/bge\",\"max_input_length\":512}"))
    (setq drgnx-ai-providers `((o :name "O" :kind ollama :url ,(format "http://127.0.0.1:%d" port) :caps (chat fim))
                               (t1 :name "TEI" :kind tei :url ,(format "http://127.0.0.1:%d" port) :caps (embed))
                               (gone :name "Gone" :kind ollama :url ,(format "http://127.0.0.1:%d" dead) :caps (chat))))
    (let ((done nil))
      (drgnx-ai-probe (lambda () (setq done t)) '(o t1 gone))
      (should-not done)                                                         ; returns at once: the answers come later
      (let ((deadline (+ (float-time) 10))) (while (and (not done) (< (float-time) deadline)) (accept-process-output nil 0.02)))
      (should done)
      (should (equal (plist-get (alist-get 'o drgnx-ai-detected) :models) '("qwen2.5-coder:1.5b")))
      (should (plist-get (alist-get 't1 drgnx-ai-detected) :up))
      (should-not (plist-get (alist-get 'gone drgnx-ai-detected) :up))))
  ;; something on TEI's port that is not TEI (LocalAI answers /info differently)
  (drgnx-ai-client-test--with '((:path "/info" :body "{\"version\":\"localai\"}"))
    (setq drgnx-ai-providers `((t1 :name "TEI" :kind tei :url ,(format "http://127.0.0.1:%d" port) :caps (embed))))
    (let (done)
      (drgnx-ai-probe (lambda () (setq done t)) '(t1))
      (let ((deadline (+ (float-time) 10))) (while (and (not done) (< (float-time) deadline)) (accept-process-output nil 0.02)))
      (should-not (plist-get (alist-get 't1 drgnx-ai-detected) :up))
      (should (string-match-p "not TEI" (plist-get (alist-get 't1 drgnx-ai-detected) :note))))))

(ert-deftest drgnx-ai-probe/a-probe-updates-the-providers-it-asked-and-keeps-the-rest ()
  ;; probing some providers (or a probe begun before a provider was added) never forgets the others
  (drgnx-ai-client-test--with '((:path "/api/tags" :body "{\"models\":[]}"))
    (setq drgnx-ai-detected '((other :up t :models ("m")) (o :up nil)))
    (let (done)
      (drgnx-ai-probe (lambda () (setq done t)) '(o))
      (let ((deadline (+ (float-time) 10))) (while (and (not done) (< (float-time) deadline)) (accept-process-output nil 0.02)))
      (should (plist-get (alist-get 'o drgnx-ai-detected) :up))
      (should (equal (alist-get 'other drgnx-ai-detected) '(:up t :models ("m"))))
      (should (= (length drgnx-ai-detected) 2)))))

(ert-deftest drgnx-ai-probe/fill-in-the-middle-capability ()
  (drgnx-ai-client-test--with
      '((:path "/api/show" :match "coder" :body "{\"capabilities\":[\"completion\",\"insert\"]}")
        (:path "/api/show" :body "{\"capabilities\":[\"completion\"]}")
        (:path "/v1/completions" :body "{\"choices\":[{\"text\":\"\"}]}"))
    (let ((ask (lambda (provider model)
                 (let (r) (drgnx-ai-probe-fim provider model (lambda (yes) (setq r (list yes))))
                      (let ((deadline (+ (float-time) 10))) (while (and (not r) (< (float-time) deadline)) (accept-process-output nil 0.02)))
                      (car r)))))
      (should (funcall ask 'o "qwen2.5-coder:1.5b"))
      (should-not (funcall ask 'o "llama3"))
      (should (funcall ask 'a "m")))))

(ert-deftest drgnx-ai/the-doctor-checks-providers-and-vram ()
  (should (equal (drgnx-ai--parse-vram "6144, 1321\n") '(:total 6144 :used 1321)))
  (should (< 1000 (drgnx-ai-model-vram "qwen2.5-coder:1.5b") 2500))               ; MiB, from the size in the name
  (should (eq 'info (car (drgnx-doctor-check 'ai '(:ai-up nil :ai-keys nil)))))
  (should (eq 'ok (car (drgnx-doctor-check 'ai '(:ai-up (ollama) :vram (:total 6144 :used 1321) :ai-complete "qwen2.5-coder:1.5b")))))
  (should (eq 'warn (car (drgnx-doctor-check 'ai '(:ai-up (ollama) :vram (:total 6144 :used 5800) :ai-complete "qwen2.5-coder:1.5b"))))))

;;; ai-client-test.el ends here
