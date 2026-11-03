;;; http-test.el --- batch tests: the streaming mock provider -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/mock-llm" drgnx-dir) nil t)

(ert-deftest drgnx-http/the-mock-streams-chunks ()
  :tags '(:cond)                        ; a real mock server and connection
  (let* ((dir (make-temp-file "drgnx-http" t)) (script (expand-file-name "s.eld" dir)) (port nil)
         (mock nil) (got nil) (seen nil))
    (unwind-protect
        (progn
          (with-temp-file script (prin1 '((:path "/s" :chunks ((0 . "aa") (0.3 . "bb")))) (current-buffer)))
          (setq mock (drgnx-ai-test-mock-llm nil script) port (process-get mock :port))
          (let ((c (open-network-stream "c" nil "127.0.0.1" port :coding 'binary)))
            (set-process-filter c (lambda (_p s) (setq got (concat got s)) (push got seen)))
            (process-send-string c "GET /s HTTP/1.1\r\n\r\n")
            (drgnx-test-wait-ended c :secs 5 :what "the connection to close")
            (should (string-match-p "\\`HTTP/1.1 200" got))
            (should-not (string-match-p "Content-Length" got))
            (should (string-suffix-p "\r\n\r\naabb" got))
            (should (seq-find (lambda (s) (string-suffix-p "\r\n\r\naa" s)) seen))))   ; "aa" came before "bb"
      (when mock (delete-process mock))
      (delete-directory dir t))))

;;; http-test.el ends here
