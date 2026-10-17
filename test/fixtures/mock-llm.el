;;; mock-llm.el --- a scripted HTTP server standing in for every LLM provider in tests -*- lexical-binding: t -*-
;; Run as its own batch Emacs (a server in the test's Emacs could not answer while the test waits on curl):
;;   MOCK_LLM_SERVE=1 MOCK_LLM_PORT=N MOCK_LLM_SCRIPT=FILE [MOCK_LLM_LOG=FILE] emacs --batch -Q -l mock-llm.el
;; FILE holds a list of answers (:path PREFIX [:match REGEXP] [:status 200] [:delay SECS] [:body STRING] [:once t]):
;; the first whose PREFIX starts the request path and whose REGEXP (if any) matches the body answers; :once answers
;; once and goes; :status 0 never answers (a hanging provider); no match answers 404.  Every request (start line,
;; headers, body) is appended to the log.  Loaded without MOCK_LLM_SERVE, it defines `drgnx-ai-test-mock-llm'.

(defvar mock-llm--script nil)
(defconst mock-llm--file (or load-file-name buffer-file-name) "This file (the server runs it).")

(defun mock-llm--answer (proc request)
  (let* ((path (and (string-match "\\`[A-Z]+ \\([^ ]+\\)" request) (match-string 1 request)))
         (body (if (string-match "\r\n\r\n" request) (substring request (match-end 0)) ""))
         (entry (seq-find (lambda (e) (and (string-prefix-p (plist-get e :path) path)
                                           (or (null (plist-get e :match)) (string-match-p (plist-get e :match) body))))
                          mock-llm--script)))
    (when (getenv "MOCK_LLM_LOG") (write-region (concat request "\n---\n") nil (getenv "MOCK_LLM_LOG") t 'silent))
    (when (plist-get entry :once) (setq mock-llm--script (delq entry mock-llm--script)))
    (let ((status (if entry (or (plist-get entry :status) 200) 404))
          (out (encode-coding-string (or (plist-get entry :body) "{}") 'utf-8)))
      (unless (eql status 0)
        (run-at-time (or (plist-get entry :delay) 0) nil
                     (lambda ()
                       (when (process-live-p proc)
                         (process-send-string proc (format "HTTP/1.1 %d X\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n"
                                                           status (length out)))
                         (process-send-string proc out)
                         (process-send-eof proc))))))))

(defun mock-llm--filter (proc chunk)
  (let ((req (concat (or (process-get proc :req) "") chunk)))
    (process-put proc :req req)
    (when (string-match "\r\n\r\n" req)
      (let* ((head-end (match-end 0))
             (len (if (string-match "^Content-Length: *\\([0-9]+\\)" req) (string-to-number (match-string 1 req)) 0)))
        (when (>= (- (length req) head-end) len)
          (process-put proc :req nil)
          ;; -unix: keep the CRLFs (the body starts after the first blank line)
          (mock-llm--answer proc (decode-coding-string req 'utf-8-unix)))))))

(defun mock-llm-serve ()
  (setq mock-llm--script (with-temp-buffer (insert-file-contents (getenv "MOCK_LLM_SCRIPT")) (read (current-buffer))))
  (make-network-process :name "mock-llm" :server t :host "127.0.0.1" :family 'ipv4 :coding 'binary
                        :service (string-to-number (getenv "MOCK_LLM_PORT")) :filter #'mock-llm--filter)
  (while t (accept-process-output nil 1)))

(defun drgnx-ai-test-mock-llm (port script &optional log)
  "Start the mock on PORT answering from SCRIPT (a file), logging to LOG; the process, once it listens."
  (let* ((process-environment (append (list "MOCK_LLM_SERVE=1" (format "MOCK_LLM_PORT=%d" port) (concat "MOCK_LLM_SCRIPT=" script))
                                      (and log (list (concat "MOCK_LLM_LOG=" log)))
                                      process-environment))
         ;; SIGPIPE ignored, as a server does: a client that went away (a cancelled request) must not kill it —
         ;; started from a GUI session it would (signal 13)
         (p (make-process :name "mock-llm" :noquery t :buffer nil :connection-type 'pipe
                          :command (list "sh" "-c" "trap '' PIPE; exec \"$0\" \"$@\""
                                         (expand-file-name invocation-name invocation-directory) "--batch" "-Q" "-l"
                                         mock-llm--file)))
         (deadline (+ (float-time) 10)))
    (while (and (< (float-time) deadline)
                (not (ignore-errors (delete-process (open-network-stream "probe" nil "127.0.0.1" port)) t)))
      (sleep-for 0.05))
    p))

(when (getenv "MOCK_LLM_SERVE") (mock-llm-serve))

;;; mock-llm.el ends here
