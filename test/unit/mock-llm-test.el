;;; mock-llm-test.el --- batch tests: the mock LLM server never outlives the test that started it -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)

(ert-deftest drgnx-mock-llm/it-ends-when-its-test-emacs-is-killed ()
  ;; a test Emacs killed by a signal (a timeout, SIGPIPE) cannot stop its mock in `unwind-protect': the mock ends by itself
  (let* ((port (+ 20000 (random 20000))) (script (make-temp-file "drgnx-mock" nil ".eld" "()")) (out "")
         (parent (make-process :name "mock-parent" :noquery t :connection-type 'pipe
                               :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                              "-l" (expand-file-name "test/fixtures/mock-llm" drgnx-dir)
                                              "--eval" (format "(progn (message \"MOCK %%s\" (process-id (drgnx-ai-test-mock-llm %d %S))) (sleep-for 60))"
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

;;; mock-llm-test.el ends here
