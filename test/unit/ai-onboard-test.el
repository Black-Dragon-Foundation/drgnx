;;; ai-onboard-test.el --- batch tests: onboarding step 4, AI providers -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-onboard)
(require 'drgnx-ai-probe)
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

;;; ai-onboard-test.el ends here
