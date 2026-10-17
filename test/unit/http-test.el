;;; http-test.el --- batch tests: HTTP request parsing, SSE usage, the streaming mock -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-http)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/mock-llm" drgnx-dir) nil t)

(ert-deftest drgnx-http/a-request-comes-in-pieces ()
  (should-not (drgnx-http-parse-request "POST /v1/messages HTTP/1.1\r\nHost: x\r\nContent-"))
  (let ((r (drgnx-http-parse-request "POST /v1/messages HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nX-Api-Key: t\r\n\r\nhello")))
    (should (equal (plist-get r :method) "POST"))
    (should (equal (plist-get r :path) "/v1/messages"))
    (should (equal (drgnx-http-header r "x-api-key") "t"))
    (should (equal (drgnx-http-header r "host") "x"))
    (should (equal (plist-get r :body) "hello"))
    (should (equal (plist-get r :rest) "")))
  ;; the body not all there yet
  (should-not (drgnx-http-parse-request "POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nhel"))
  ;; no body
  (should (equal (plist-get (drgnx-http-parse-request "GET /v1/models HTTP/1.1\r\n\r\n") :body) "")))

(ert-deftest drgnx-http/bad-requests-get-their-status ()
  (should (equal (drgnx-http-parse-request "garbage\r\n\r\n") '(:error 400)))
  (should (equal (drgnx-http-parse-request "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n") '(:error 411)))
  (should (equal (drgnx-http-parse-request (format "POST / HTTP/1.1\r\nContent-Length: %d\r\n\r\n" (1+ drgnx-http-max-body)))
                 '(:error 413)))
  (should (equal (drgnx-http-parse-request (concat "POST / HTTP/1.1\r\nX: " (make-string (* 70 1024) ?a))) '(:error 431))))

(defconst drgnx-http-test--stream
  (concat "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"usage\":{\"input_tokens\":12,\"output_tokens\":1}}}\n\n"
          "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}\n\n"
          "event: message_delta\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":3}}\n\n"
          "event: message_delta\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":7}}\n\n"
          "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n")
  "An Anthropic Messages stream: 12 tokens in, 7 out.")

(ert-deftest drgnx-http/usage-from-an-anthropic-stream-split-anywhere ()
  (let ((scan (drgnx-http-usage-scanner)) (s drgnx-http-test--stream) last)
    (while (> (length s) 0)
      (setq last (funcall scan (substring s 0 (min 5 (length s)))) s (substring s (min 5 (length s)))))
    (should (equal last '(:input 12 :output 7 :cost nil)))))

(ert-deftest drgnx-http/usage-from-a-plain-json-answer ()
  (let ((scan (drgnx-http-usage-scanner)))
    (funcall scan "{\"choices\":[],\"usage\":{\"prompt_tokens\":4,")
    (should (equal (funcall scan "\"completion_tokens\":9,\"cost\":0.002}}") '(:input 4 :output 9 :cost 0.002))))
  (let ((scan (drgnx-http-usage-scanner)))
    (should (equal (funcall scan "{\"usage\":{\"input_tokens\":2,\"output_tokens\":3}}") '(:input 2 :output 3 :cost nil)))))

(ert-deftest drgnx-http/a-non-ascii-body-is-byte-exact ()
  (let* ((body (encode-coding-string "é—𝄞 \"x\"" 'utf-8))
         (r (drgnx-http-parse-request (concat (format "POST / HTTP/1.1\r\nContent-Length: %d\r\n\r\n" (length body)) body))))
    (should (equal (plist-get r :body) body))
    (should-not (multibyte-string-p (plist-get r :body)))))

(ert-deftest drgnx-http/the-mock-streams-chunks ()
  :tags '(:timing)
  (let* ((dir (make-temp-file "drgnx-http" t)) (script (expand-file-name "s.eld" dir)) (port (+ 20000 (random 20000)))
         (mock nil) (got nil) (times nil))
    (unwind-protect
        (progn
          (with-temp-file script (prin1 '((:path "/s" :chunks ((0 . "aa") (0.3 . "bb")))) (current-buffer)))
          (setq mock (drgnx-ai-test-mock-llm port script))
          (let ((c (open-network-stream "c" nil "127.0.0.1" port :coding 'binary)) (t0 (float-time)))
            (set-process-filter c (lambda (_p s) (setq got (concat got s)) (push (- (float-time) t0) times)))
            (process-send-string c "GET /s HTTP/1.1\r\n\r\n")
            (let ((deadline (+ (float-time) 5)))
              (while (and (process-live-p c) (< (float-time) deadline)) (accept-process-output nil 0.02)))
            (should (string-match-p "\\`HTTP/1.1 200" got))
            (should-not (string-match-p "Content-Length" got))
            (should (string-suffix-p "\r\n\r\naabb" got))
            (should (>= (- (car times) (car (last times))) 0.25))))     ; "bb" came later
      (when mock (delete-process mock))
      (delete-directory dir t))))

;;; http-test.el ends here
