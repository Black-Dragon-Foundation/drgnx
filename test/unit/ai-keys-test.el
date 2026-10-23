;;; ai-keys-test.el --- batch tests: after the hand-over the editor holds no provider key -*- lexical-binding: t -*-
;; Binary tests (design §5.6): the real Ratatoskr hub takes the keys AI: Load Keys finds, and this Emacs then keeps none
;; of them — not in `drgnx-ai--keys', not in auth-source's cache, not in a gptel backend, not in anything it sends but
;; the one `gateway/keys'.  Keys in the environment are the user's and stay.  `ratatoskr-mock llm' is the provider.
;; Without the binary (or the mock beside it) these skip; test/no-skip.eld lists them.
(require 'ert)
(require 'cl-lib)
(require 'auth-source)
(require 'password-cache)
(require 'drgnx)                        ; `drgnx-dir'
(require 'ai-gateway-test (expand-file-name "test/unit/ai-gateway-test" drgnx-dir))

(defvar drgnx-ai-keys-test--lines nil "The lines this Emacs wrote to the hub, newest first.")

(defun drgnx-ai-keys-test--record (_conn line)
  (push line drgnx-ai-keys-test--lines))

(defun drgnx-ai-keys-test--netrc (root host key)
  "A netrc under ROOT (mode 600) with KEY for HOST: a store, not the environment."
  (let ((f (concat root "netrc")))
    (with-temp-file f (insert (format "machine %s login drgnx password %s\n" host key)))
    (set-file-modes f #o600)
    f))

(defun drgnx-ai-keys-test--auth-source-cached-p ()
  "Whether auth-source keeps anything cached: its netrc file cache or an entry in the password cache."
  (or auth-source-netrc-cache
      (let (found) (maphash (lambda (k _) (when (eq (car-safe k) 'auth-source) (setq found t))) password-data) found)))

(ert-deftest drgnx-ai/the-editor-holds-no-key-after-the-handover ()
  (drgnx-ai-gateway-test--with nil
    (let* ((canary "sk-or-canary-23c")
           (auth-sources (list (drgnx-ai-keys-test--netrc root "openrouter.ai" canary)))
           (auth-source-netrc-cache nil) (password-data (make-hash-table :test #'equal))
           (drgnx-ai-keys-test--lines nil))
      (advice-add 'drgnx-hub--send-line :before #'drgnx-ai-keys-test--record)
      (unwind-protect
          (progn
            (should (memq 'openrouter (drgnx-ai-load-keys)))      ; the edit and agent roles name OpenRouter
            ;; found and on its way: until the hub answers, it waits here
            (should (equal (gethash 'openrouter drgnx-ai--keys) canary))
            (should (drgnx-ai-keys-test--auth-source-cached-p))
            (drgnx-test-wait (lambda () (zerop (hash-table-count drgnx-ai--keys))) :secs 20 :what "the hub took the key")
            (drgnx-test-wait (lambda () (member "openrouter" (drgnx-hub-keys-held))) :secs 20 :what "keys-changed")
            ;; nowhere in this Emacs: its key table, auth-source's cache (a later hand-over reads a quiet store again,
            ;; keeping nothing: review M3)
            (should-not (drgnx-ai-keys-test--auth-source-cached-p))
            ;; gptel's backend for OpenRouter carries the editor token
            (let ((spec (drgnx-ai-gptel-spec 'openrouter "openrouter/auto")))
              (should (equal (funcall (plist-get (cddr spec) :key)) (car drgnx-hub--editor)))
              (should-not (string-search canary (prin1-to-string spec))))
            ;; of every line sent to the hub, only the one `gateway/keys' carried it
            (let ((with (seq-filter (lambda (l) (string-search canary l)) drgnx-ai-keys-test--lines)))
              (should (= (length with) 1))
              (should (string-search "\"gateway/keys\"" (car with)))))
        (advice-remove 'drgnx-hub--send-line #'drgnx-ai-keys-test--record)))))

(ert-deftest drgnx-ai/a-usable-check-keeps-no-key ()
  ;; review M2: AI: Choose and onboarding ask whether a provider is usable for every keyed provider the hub does not
  ;; hold, reading its key as a command would; that check keeps nothing — not the key, not auth-source's copy of the
  ;; netrc file — whether the hub has said which keys it holds or not
  (drgnx-ai-gateway-test--with nil
    (let* ((canary "sk-b-canary-m2")
           (auth-sources (list (drgnx-ai-keys-test--netrc root "127.0.0.1" canary)))
           (auth-source-netrc-cache nil) (password-data (make-hash-table :test #'equal)))
      (should-not (member "b" (drgnx-hub-keys-held)))
      (dolist (held (list (drgnx-hub-keys-held) :unknown))
        (let ((drgnx-hub--keys-held held))
          (should (drgnx-ai-usable-p 'b 'chat t))                ; found: the check read the store
          (should (zerop (hash-table-count drgnx-ai--keys)))
          (should-not auth-source-netrc-cache)
          (should-not (drgnx-ai-keys-test--auth-source-cached-p)))))))

(ert-deftest drgnx-ai/the-environment-is-left-as-it-was ()
  ;; a key the user put in this Emacs's environment goes to the hub and stays where the user put it
  (drgnx-ai-gateway-test--with nil
    (let* ((process-environment (cons "OPENROUTER_API_KEY=sk-env-canary-23c" process-environment))
           (before (copy-sequence process-environment)))
      (should (memq 'openrouter (drgnx-ai-load-keys)))
      (drgnx-test-wait (lambda () (member "openrouter" (drgnx-hub-keys-held))) :secs 20 :what "the hub took the key")
      (should (equal process-environment before))
      (should (equal (getenv "OPENROUTER_API_KEY") "sk-env-canary-23c"))
      (should (equal (getenv "A_KEY") drgnx-ai-gateway-test--key))      ; handed over when the macro connected
      (should (zerop (hash-table-count drgnx-ai--keys))))))

(ert-deftest drgnx-ai/each-feature-still-works-after-the-drop ()
  ;; a's key only in a store: AI: Load Keys hands it over and this Emacs drops it; chat, FIM, embeddings and the commit
  ;; message then reach the provider with the hub's key, and nothing in this Emacs holds it
  (drgnx-ai-gateway-test--with '((:path "/v1/chat/completions" :body "{\"choices\":[{\"message\":{\"content\":\"hi\"}}]}")
                                 (:path "/v1/completions" :body "{\"choices\":[{\"text\":\"middle\"}]}")
                                 (:path "/v1/embeddings" :body "{\"data\":[{\"index\":0,\"embedding\":[3,4]}]}"))
    (let ((process-environment (append '("A_KEY" "ANTHROPIC_API_KEY" "MOONSHOT_API_KEY" "DEEPSEEK_API_KEY") process-environment))
          (auth-sources (list (drgnx-ai-keys-test--netrc root "127.0.0.1" drgnx-ai-gateway-test--key)))
          (auth-source-netrc-cache nil) (password-data (make-hash-table :test #'equal)))
      (should (memq 'a (drgnx-ai-load-keys)))
      (drgnx-test-wait (lambda () (zerop (hash-table-count drgnx-ai--keys))) :secs 20 :what "the hub took the key")
      (should-not (drgnx-ai-keys-test--auth-source-cached-p))
      (setq drgnx-ai-gateway-test--sent nil)
      (should (equal (car (drgnx-ai-gateway-test--ask 'chat '(:messages [(:role "user" :content "x")]))) "hi"))
      (drgnx-ai-gateway-test--through root "/v1/chat/completions")
      (setq drgnx-ai-gateway-test--sent nil)
      (should (equal (car (drgnx-ai-gateway-test--ask 'fim '(:prefix "a" :suffix "b"))) "middle"))
      (drgnx-ai-gateway-test--through root "/v1/completions")
      (setq drgnx-ai-gateway-test--sent nil)
      (should (= (length (drgnx-ai-embed-sync (vector "hello") :timeout 10 :chain '((a . "e")))) 1))
      (drgnx-ai-gateway-test--through root "/v1/embeddings")
      (setq drgnx-ai-gateway-test--sent nil)
      (drgnx-git-test-with-repo
        (drgnx-git-test-write repo "a.txt" "one\n")
        (drgnx-git-test repo "add" "-A") (drgnx-git-test repo "commit" "-q" "-m" "Start the file")
        (drgnx-git-test-write repo "a.txt" "one\ntwo\n")
        (drgnx-git-test repo "add" "-A")
        (with-temp-buffer
          (setq default-directory repo)
          (insert "\n# Please enter the commit message\n")
          (git-commit-mode 1)
          (cl-letf (((symbol-function 'message) #'ignore))
            (drgnx-commit-message-generate)
            (drgnx-test-wait (lambda () (string-prefix-p "hi" (buffer-string))) :secs 20 :what "the message"))))
      (drgnx-ai-gateway-test--through root "/v1/chat/completions")
      (should (seq-find (lambda (r) (string-search "+two" (or (plist-get r :body) ""))) (drgnx-ai-gateway-test--requests root)))
      (should (zerop (hash-table-count drgnx-ai--keys))))))

(provide 'ai-keys-test)
