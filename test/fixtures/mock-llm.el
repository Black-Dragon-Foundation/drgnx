;;; mock-llm.el --- a scripted HTTP server standing in for every LLM provider in tests -*- lexical-binding: t -*-
;; Run as its own batch Emacs (a server in the test's Emacs could not answer while the test waits on curl):
;;   MOCK_LLM_SERVE=1 MOCK_LLM_PORT=N MOCK_LLM_SCRIPT=FILE [MOCK_LLM_LOG=FILE] emacs --batch -Q -l mock-llm.el
;; N = 0 (or empty): the system picks the port.  Once listening, the server reports it on one line,
;; "MOCK-LLM-PORT N", which `drgnx-ai-test-mock-llm' reads (a listener that is not the mock cannot pass for it).
;; FILE holds a list of answers (:path PREFIX [:match REGEXP] [:status 200] [:delay SECS] [:body STRING]
;; [:headers ((NAME . VALUE)…) more response headers] [:once t]):
;; the first whose PREFIX starts the request path and whose REGEXP (if any) matches the body answers; :once answers
;; once and goes; :status 0 never answers (a hanging provider); no match answers 404.  :chunks ((DELAY . TEXT)…)
;; streams instead (the head at once, no length; each TEXT after its DELAY; then the close — or with :no-end, the
;; connection dropped mid-answer).  Every request (start line,
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
      (if (plist-get entry :chunks)
          ;; a stream: the head at once (no length, the end is the close), each chunk after its delay
          (let ((t0 0))
            (process-send-string proc (format "HTTP/1.1 %d X\r\nContent-Type: %s\r\nConnection: close\r\n\r\n"
                                              status (or (plist-get entry :content-type) "text/event-stream")))
            (pcase-dolist (`(,delay . ,text) (plist-get entry :chunks))
              (setq t0 (+ t0 delay))
              (run-at-time t0 nil (lambda () (when (process-live-p proc)
                                               (process-send-string proc (encode-coding-string text 'utf-8))))))
            (unless (plist-get entry :no-end)          ; :no-end: the stream stops without closing… then drops
              (run-at-time (+ t0 0.01) nil (lambda () (when (process-live-p proc) (process-send-eof proc)))))
            (when (plist-get entry :no-end)
              (run-at-time (+ t0 0.05) nil (lambda () (when (process-live-p proc) (delete-process proc))))))
        (unless (eql status 0)
          (run-at-time (or (plist-get entry :delay) 0) nil
                       (lambda ()
                         (when (process-live-p proc)
                           (process-send-string proc (format "HTTP/1.1 %d X\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n%s\r\n"
                                                             status (length out)
                                                             (mapconcat (lambda (h) (format "%s: %s\r\n" (car h) (cdr h)))
                                                                        (plist-get entry :headers) "")))
                           (process-send-string proc out)
                           (process-send-eof proc)))))))))

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
  (let* ((n (string-to-number (or (getenv "MOCK_LLM_PORT") "")))
         (srv (make-network-process :name "mock-llm" :server t :host "127.0.0.1" :family 'ipv4 :coding 'binary
                                    :service (if (> n 0) n t) :filter #'mock-llm--filter)))
    (message "MOCK-LLM-PORT %d" (process-contact srv :service)))
  ;; it ends with the test Emacs that started it — even one killed by a signal, which cannot stop it
  (let ((parent (and (getenv "MOCK_LLM_PARENT") (string-to-number (getenv "MOCK_LLM_PARENT")))))
    (while t
      (accept-process-output nil 1)
      (when parent
        (let ((a (process-attributes parent)))
          (when (or (null a) (equal (alist-get 'state a) "Z")) (kill-emacs 0)))))))

(defun drgnx-test-free-port ()
  "A port a listener of this Emacs just bound and released: nothing listens on it, a connection is refused."
  (let ((srv (make-network-process :name "free-port" :server t :host "127.0.0.1" :family 'ipv4 :service t :noquery t)))
    (prog1 (process-contact srv :service) (delete-process srv))))

(defun drgnx-ai-test-mock-llm (port script &optional log)
  "Start the mock answering from SCRIPT (a file), logging to LOG; the process, once it listens.
PORT nil: the mock listens on a port the system picks.  A number asks for that port (a caller that needs a fixed one);
it errors when the port is taken.  Either way the port the mock reports is the process's `:port' property."
  (let* ((process-environment (append (list "MOCK_LLM_SERVE=1" (format "MOCK_LLM_PORT=%d" (or port 0)) (concat "MOCK_LLM_SCRIPT=" script)
                                            (format "MOCK_LLM_PARENT=%d" (emacs-pid)))
                                      (and log (list (concat "MOCK_LLM_LOG=" log)))
                                      process-environment))
         (out "")
         ;; SIGPIPE ignored, as a server does: a client that went away (a cancelled request) must not kill it —
         ;; started from a GUI session it would (signal 13)
         (p (make-process :name "mock-llm" :noquery t :buffer nil :connection-type 'pipe
                          :filter (lambda (_p s) (setq out (concat out s)))
                          :command (list "sh" "-c" "trap '' PIPE; exec \"$0\" \"$@\""
                                         (expand-file-name invocation-name invocation-directory) "--batch" "-Q" "-l"
                                         mock-llm--file)))
         (deadline (+ (float-time) 10)))
    ;; ready = the server said which port it bound (not "something accepts on PORT")
    (while (and (< (float-time) deadline) (process-live-p p) (not (string-match "MOCK-LLM-PORT \\([0-9]+\\)" out)))
      (accept-process-output p 0.05))
    (unless (string-match "MOCK-LLM-PORT \\([0-9]+\\)" out)
      (when (process-live-p p) (delete-process p))
      (error "Mock LLM did not start (port %s): %s" (or port "any") (string-trim out)))
    (process-put p :port (string-to-number (match-string 1 out)))
    p))

(when (getenv "MOCK_LLM_SERVE") (mock-llm-serve))

;;; mock-llm.el ends here
