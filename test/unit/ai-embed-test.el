;;; ai-embed-test.el --- batch tests: embeddings along the embed role (TEI, Ollama, llama.cpp, OpenAI-compatible) -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-ai-client)
(load (expand-file-name "test/fixtures/mock-llm" drgnx-dir) nil t)

(defmacro drgnx-ai-embed-test--with (spec chain &rest body)
  "BODY with a mock LLM server answering SPEC on PORT (its request LOG), providers `tei', `a' (openai), `o' (ollama),
`l' (llama.cpp) and `dead' (nothing listens) pointing at it, and the embed role set to CHAIN in ai.eld."
  (declare (indent 2))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-ai-embed" t)))
          (port (+ 20000 (random 20000))) (dead (+ 40000 (random 9000)))
          (log (concat root "llm.log")) (script (concat root "llm.eld"))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" root "config") (concat "XDG_STATE_HOME=" root "state")
                                             "A_KEY=sk-test-123")
                                       process-environment))
          (auth-sources nil) (drgnx-ai--keys (make-hash-table :test #'eq)) (drgnx-ai-detected nil)
          (mock nil))
     (unwind-protect
         (progn
           (make-directory (concat root "config") t)
           (with-temp-file script (prin1 ,spec (current-buffer)))
           (with-temp-file (concat root "config/ai.eld")
             (prin1 `(:version 1
                               :providers ((tei :name "TEI" :kind tei :url ,(format "http://127.0.0.1:%d" port) :caps (embed))
                                           (a :name "A" :kind openai :url ,(format "http://127.0.0.1:%d/v1" port) :key-env "A_KEY" :caps (embed))
                                           (o :name "O" :kind ollama :url ,(format "http://127.0.0.1:%d" port) :caps (embed))
                                           (l :name "L" :kind llamacpp :url ,(format "http://127.0.0.1:%d" port) :caps (embed))
                                           (dead :name "Dead" :kind openai :url ,(format "http://127.0.0.1:%d/v1" dead) :caps (embed)))
                               :roles ((embed ,@,chain)))
                    (current-buffer)))
           (setq mock (drgnx-ai-test-mock-llm port script log))
           ,@body)
       (when mock (delete-process mock))
       (delete-directory root t))))

(defun drgnx-ai-embed-test--norm (v) (sqrt (cl-loop for x across v sum (* x x))))

(defun drgnx-ai-embed-test--request (inputs)
  "Ask the embed role for INPUTS and wait: (VECTORS . INFO)."
  (let (result)
    (drgnx-ai-request 'embed 'embed (list :inputs inputs) (lambda (v info) (setq result (cons v info))) :timeout 5)
    (let ((deadline (+ (float-time) 15)))
      (while (and (not result) (< (float-time) deadline)) (accept-process-output nil 0.02)))
    result))

(defun drgnx-ai-embed-test--check (r)
  "R, a request result for two inputs answered with [3 4 0] and [0 0 2]: normalised."
  (should (vectorp (car r)))
  (should (= 2 (length (car r))))
  (should (equal (aref (car r) 0) [0.6 0.8 0.0]))
  (should (equal (aref (car r) 1) [0.0 0.0 1.0]))
  (dolist (v (append (car r) nil)) (should (< (abs (- 1.0 (drgnx-ai-embed-test--norm v))) 1e-6))))

(ert-deftest drgnx-ai-embed/tei-shape ()
  (drgnx-ai-embed-test--with '((:path "/embed" :body "[[3,4,0],[0,0,2]]")) '((tei))
    (drgnx-ai-embed-test--check (drgnx-ai-embed-test--request ["one" "two"]))
    ;; TEI takes no model; long inputs are cut to its limit
    (let ((req (with-temp-buffer (insert-file-contents log) (buffer-string))))
      (should (string-search "POST /embed " req))
      (should (string-search "\"inputs\":[\"one\",\"two\"]" req))
      (should (string-search "\"truncate\":true" req))
      (should-not (string-search "model" req)))))

(ert-deftest drgnx-ai-embed/ollama-shape ()
  (drgnx-ai-embed-test--with '((:path "/api/embed" :body "{\"embeddings\":[[3,4,0],[0,0,2]]}")) '((o . "nomic"))
    (drgnx-ai-embed-test--check (drgnx-ai-embed-test--request ["one" "two"]))
    (let ((req (with-temp-buffer (insert-file-contents log) (buffer-string))))
      (should (string-search "\"model\":\"nomic\"" req))
      (should (string-search "\"input\":[\"one\",\"two\"]" req)))))

(ert-deftest drgnx-ai-embed/openai-shape ()
  (drgnx-ai-embed-test--with '((:path "/v1/embeddings" :body "{\"data\":[{\"embedding\":[3,4,0]},{\"embedding\":[0,0,2]}]}")) '((a . "emb"))
    (drgnx-ai-embed-test--check (drgnx-ai-embed-test--request ["one" "two"]))
    (let ((req (with-temp-buffer (insert-file-contents log) (buffer-string))))
      (should (string-search "POST /v1/embeddings " req))
      (should (string-search "\"model\":\"emb\"" req))
      (should (string-search "\"input\":[\"one\",\"two\"]" req)))))

(ert-deftest drgnx-ai-embed/llamacpp-shape ()
  (drgnx-ai-embed-test--with '((:path "/v1/embeddings" :body "{\"data\":[{\"embedding\":[3,4,0]},{\"embedding\":[0,0,2]}]}")) '((l . "m"))
    (drgnx-ai-embed-test--check (drgnx-ai-embed-test--request ["one" "two"]))))

(ert-deftest drgnx-ai-embed/a-zero-vector-stays-zero ()
  (drgnx-ai-embed-test--with '((:path "/embed" :body "[[0,0,0],[0,0,2]]")) '((tei))
    (let ((r (drgnx-ai-embed-test--request ["one" "two"])))
      (should (equal (aref (car r) 0) [0.0 0.0 0.0]))
      (should (equal (aref (car r) 1) [0.0 0.0 1.0])))))

(ert-deftest drgnx-ai-embed/falls-back-along-the-role ()
  (drgnx-ai-embed-test--with '((:path "/embed" :status 500 :body "boom")
                               (:path "/api/embed" :body "{\"embeddings\":[[3,4,0],[0,0,2]]}"))
      '((tei) (o . "nomic"))
    (let ((r (drgnx-ai-embed-test--request ["one" "two"])))
      (drgnx-ai-embed-test--check r)
      (should (eq 'o (plist-get (cdr r) :provider)))
      (should (equal '((tei . "HTTP 500")) (plist-get (cdr r) :fallbacks))))))

(ert-deftest drgnx-ai-embed/an-answer-that-is-not-vectors-falls-back ()
  ;; too few vectors, an overflowing number and text instead of numbers: each moves on to the next provider
  (dolist (bad '("[[3,4,0]]" "[[1e999,4,0],[0,0,2]]" "[[\"x\"],[\"y\"]]" "{\"error\":\"no\"}"))
    (drgnx-ai-embed-test--with `((:path "/embed" :body ,bad)
                                 (:path "/api/embed" :body "{\"embeddings\":[[3,4,0],[0,0,2]]}"))
        '((tei) (o . "nomic"))
      (let ((r (drgnx-ai-embed-test--request ["one" "two"])))
        (drgnx-ai-embed-test--check r)
        (should (equal '(tei) (mapcar #'car (plist-get (cdr r) :fallbacks))))))))

(ert-deftest drgnx-ai-embed/sync-returns-the-vectors ()
  (drgnx-ai-embed-test--with '((:path "/embed" :body "[[3,4,0],[0,0,2]]")) '((dead . "m") (tei))
    (drgnx-ai-embed-test--check (cons (drgnx-ai-embed-sync ["one" "two"] :timeout 5) nil))
    ;; who answered, for callers that record it (the search index)
    (should (eq 'tei (plist-get drgnx-ai-embed-last-info :provider)))))

(ert-deftest drgnx-ai-embed/sync-takes-a-chain-instead-of-the-role ()
  (drgnx-ai-embed-test--with '((:path "/embed" :body "[[3,4,0],[0,0,2]]")) '((dead . "m"))
    ;; the role is only a dead provider; the chain given is TEI
    (drgnx-ai-embed-test--check (cons (drgnx-ai-embed-sync ["one" "two"] :timeout 5 :chain '((tei))) nil))
    (should (eq 'tei (plist-get drgnx-ai-embed-last-info :provider)))
    (should-error (drgnx-ai-embed-sync ["one"] :timeout 5) :type 'drgnx-ai-embed-error)))

(ert-deftest drgnx-ai-embed/sync-signals-when-none-answers ()
  (drgnx-ai-embed-test--with '((:path "/embed" :status 500 :body "boom")) '((tei) (dead . "m"))
    (let ((err (should-error (drgnx-ai-embed-sync ["one"] :timeout 5) :type 'drgnx-ai-embed-error)))
      (should (string-search "tei: HTTP 500" (cadr err)))
      (should (string-search "dead: no answer" (cadr err))))))

(ert-deftest drgnx-ai-embed/sync-of-nothing-asks-nobody ()
  (drgnx-ai-embed-test--with nil '((dead . "m"))
    (should (equal [] (drgnx-ai-embed-sync [] :timeout 5)))))
