;;; mock-llm-test.el --- batch tests: the mock LLM server never outlives the test that started it -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/mock-llm" drgnx-dir) nil t)

(ert-deftest drgnx-mock-llm/it-ends-when-its-test-emacs-is-killed ()
  ;; a test Emacs killed by a signal (a timeout, SIGPIPE) cannot stop its mock in `unwind-protect': the mock ends by itself
  (let* ((port nil) (script (make-temp-file "drgnx-mock" nil ".eld" "()")) (out "")
         (parent (make-process :name "mock-parent" :noquery t :connection-type 'pipe
                               :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                              "-l" (expand-file-name "test/fixtures/mock-llm" drgnx-dir)
                                              "--eval" (format "(progn (message \"MOCK %%s\" (process-id (drgnx-ai-test-mock-llm %s %S))) (sleep-for 60))"
                                                               port script))
                               :filter (lambda (_p s) (setq out (concat out s)))))
         (mock nil))
    (unwind-protect
        (progn
          (let ((deadline (+ (float-time) 15)))
            (while (and (not (string-match "MOCK \\([0-9]+\\)" out)) (< (float-time) deadline)) (accept-process-output nil 0.05)))
          (should (string-match "MOCK \\([0-9]+\\)" out))   ; (OUT shows why, when not)
          (setq mock (string-to-number (match-string 1 out)))
          (should (process-attributes mock))
          (signal-process parent 'KILL)
          (let ((gone (lambda () (let ((a (process-attributes mock))) (or (null a) (equal (alist-get 'state a) "Z")))))
                (deadline (+ (float-time) 5)))
            (while (and (not (funcall gone)) (< (float-time) deadline)) (sleep-for 0.1))
            (should (funcall gone))))   ; a zombie where PID 1 never reaps (a CI container)
      (when (process-live-p parent) (delete-process parent))
      (when (and mock (process-attributes mock)) (signal-process mock 'KILL))
      (delete-file script))))

;; a mock with no PORT listens on one the system picks and reports it; the readiness check reads that report
(defun drgnx-mock-llm-test--answers-p (port)
  "Non-nil when whatever listens on PORT answers a request with the mock's 404 (an empty script)."
  (let* ((out "") (c (make-network-process :name "probe" :host "127.0.0.1" :service port :noquery t
                                           :filter (lambda (_p s) (setq out (concat out s))))))
    (unwind-protect
        (progn (process-send-string c "GET /x HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n")
               (let ((deadline (+ (float-time) 5)))
                 (while (and (not (string-match-p "404" out)) (< (float-time) deadline)) (accept-process-output c 0.05)))
               (string-match-p "404" out))
      (delete-process c))))

(ert-deftest drgnx-mock-llm/an-ephemeral-port-is-reported ()
  (let* ((script (make-temp-file "drgnx-mock" nil ".eld" "()")) (mock (drgnx-ai-test-mock-llm nil script)))
    (unwind-protect
        (let ((port (process-get mock :port)))
          (should (and (integerp port) (> port 0)))
          (should (drgnx-mock-llm-test--answers-p port)))
      (delete-process mock)
      (delete-file script))))

(ert-deftest drgnx-mock-llm/a-foreign-listener-is-not-taken-for-the-mock ()
  ;; a listener of this Emacs on the port a test used to pick: it accepts, but it never answers like the mock
  (let* ((script (make-temp-file "drgnx-mock" nil ".eld" "()"))
         (foreign (make-network-process :name "foreign" :server t :host "127.0.0.1" :service t :noquery t
                                        :filter #'ignore))
         (taken (process-contact foreign :service)) (mock nil))
    (unwind-protect
        (progn
          ;; the fixed port is taken: the mock does not start (it used to "start" on any listener)
          (should-error (drgnx-ai-test-mock-llm taken script))
          (setq mock (drgnx-ai-test-mock-llm nil script))
          (should-not (eql (process-get mock :port) taken))
          (should (drgnx-mock-llm-test--answers-p (process-get mock :port))))
      (when mock (delete-process mock))
      (delete-process foreign)
      (delete-file script))))

(ert-deftest drgnx-test-port/a-free-port-refuses ()
  (let ((port (drgnx-test-free-port)))
    (should (and (integerp port) (> port 0)))
    (should-error (delete-process (open-network-stream "probe" nil "127.0.0.1" port)))))

;;; mock-llm-test.el ends here
