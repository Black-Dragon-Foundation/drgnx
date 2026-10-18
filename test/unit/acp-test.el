;;; acp-test.el --- batch tests: the ACP client against the mock agent -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-acp)
(require 'drgnx-paths)
(require 'drgnx-timer)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)

(defconst drgnx-acp-test--mock (expand-file-name "test/fixtures/mock-acp.el" drgnx-dir))
(defconst drgnx-acp-test--wrapper (expand-file-name "test/fixtures/mock-acp-stdin.sh" drgnx-dir))

(defun drgnx-acp-test--command ()
  (list "sh" drgnx-acp-test--wrapper (expand-file-name invocation-name invocation-directory) "--batch" "-Q" "-l" drgnx-acp-test--mock))

(defun drgnx-acp-test--wait (pred &optional secs)
  "Run the event loop until PRED is non-nil (at most SECS, default 10); PRED's value."
  (let ((deadline (+ (float-time) (or secs 10))) v)
    (while (and (not (setq v (funcall pred))) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    v))

(defmacro drgnx-acp-test--with (conn keys &rest body)
  (declare (indent 2))
  `(let ((,conn (apply #'drgnx-acp-start (drgnx-acp-test--command) ,keys)))
     (unwind-protect (progn ,@body) (drgnx-acp-stop ,conn))))

(defun drgnx-acp-test--call (conn method params)
  "METHOD's (RESULT . ERROR), waiting for it."
  (let (r)
    (drgnx-acp-request conn method params (lambda (res) (setq r res)))
    (drgnx-acp-test--wait (lambda () r))))

(ert-deftest drgnx-acp/the-agent-runs-with-sigpipe-ignored ()
  ;; the agent writes to pipes its own children may close: it must not die of the signal (Emacs resets it for children)
  (skip-unless (file-readable-p "/proc/self/status"))
  (let ((conn (drgnx-acp-start (list "sh" "-c" "grep SigIgn /proc/self/status >&2"))))
    (unwind-protect
        (let ((mask (and (drgnx-acp-test--wait
                          (lambda () (string-match "SigIgn:[ \t]*\\([0-9a-f]+\\)" (or (drgnx-acp-conn-stderr conn) ""))))
                         (string-to-number (match-string 1 (drgnx-acp-conn-stderr conn)) 16))))
          (should mask)
          (should-not (zerop (logand #x1000 mask))))
      (drgnx-acp-stop conn))))

(ert-deftest drgnx-acp/a-request-gets-its-result ()
  (drgnx-acp-test--with c nil
    (let ((r (drgnx-acp-test--call c "initialize" '(:protocolVersion 1 :clientCapabilities (:fs (:readTextFile t :writeTextFile t))))))
      (should (eql (plist-get (car r) :protocolVersion) 1))
      (should-not (cdr r)))
    (let ((r (drgnx-acp-test--call c "no/such/method" nil)))
      (should-not (car r))
      (should (plist-get (cdr r) :message)))))

(ert-deftest drgnx-acp/notifications-reach-the-handler ()
  (let ((seen nil))
    (drgnx-acp-test--with c (list :on-notification (lambda (_c method params) (push (cons method params) seen)))
      (drgnx-acp-test--call c "initialize" '(:protocolVersion 1))
      (drgnx-acp-test--call c "session/new" '(:cwd "/tmp" :mcpServers []))
      (should (drgnx-acp-test--wait
               (lambda () (seq-find (lambda (n) (equal (plist-get (plist-get (cdr n) :update) :sessionUpdate)
                                                       "available_commands_update"))
                                    seen)))))))

(ert-deftest drgnx-acp/agent-requests-are-answered-by-the-handler ()
  (let ((asked nil) (chunks nil))
    (drgnx-acp-test--with c (list :on-request (lambda (_c method _params _id)
                                                (push method asked)
                                                '(:result (:outcome (:outcome "selected" :optionId "allow"))))
                                  :on-notification (lambda (_c _m params)
                                                     (when-let* ((text (plist-get (plist-get (plist-get params :update) :content) :text)))
                                                       (push text chunks))))
      (drgnx-acp-test--call c "initialize" '(:protocolVersion 1))
      (let ((sid (plist-get (car (drgnx-acp-test--call c "session/new" '(:cwd "/tmp" :mcpServers []))) :sessionId)))
        (drgnx-acp-test--call c "session/prompt" (list :sessionId sid :prompt (vector '(:type "text" :text "permission please")))))
      (should (member "session/request_permission" asked))
      (should (member "permission: allow" chunks)))))

(ert-deftest drgnx-acp/the-agent-exiting-is-reported-with-its-stderr ()
  (let (exit)
    (drgnx-acp-test--with c (list :on-exit (lambda (_c status stderr) (setq exit (list status stderr))))
      (drgnx-acp-test--call c "initialize" '(:protocolVersion 1))
      (let* ((sid (plist-get (car (drgnx-acp-test--call c "session/new" '(:cwd "/tmp" :mcpServers []))) :sessionId))
             (r (drgnx-acp-test--call c "session/prompt" (list :sessionId sid :prompt (vector '(:type "text" :text "crash now"))))))
        (should (cdr r)))                                     ; the pending prompt fails, not hangs
      (should (drgnx-acp-test--wait (lambda () exit)))
      (should (eql (car exit) 3))
      (should (string-match-p "mock crashed" (cadr exit)))
      ;; nothing left behind: the stderr pipe and the input buffer go with the agent
      (should-not (process-live-p (drgnx-acp-conn-stderr-process c)))
      (should-not (buffer-live-p (drgnx-acp-conn-input-buffer c))))))

(ert-deftest drgnx-acp/the-mock-reads-the-fifo-in-mock-acp-in ()
  ;; macOS has no /proc/PID/fd/0: given MOCK_ACP_IN, the mock reads its messages from that FIFO (its stdin carries none)
  (let* ((dir (make-temp-file "drgnx-mock-in" t)) (fifo (expand-file-name "in" dir)) (out "")
         (_ (should (eql 0 (call-process "mkfifo" nil nil nil fifo))))
         (process-environment (cons (concat "MOCK_ACP_IN=" fifo) process-environment))
         (p (make-process :name "mock" :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                                      "-l" drgnx-acp-test--mock)
                          :connection-type 'pipe :noquery t :filter (lambda (_p s) (setq out (concat out s)))))
         (w (make-process :name "mock-writer" :command (list "sh" "-c" "exec cat >\"$0\"" fifo) :connection-type 'pipe
                          :noquery t)))
    (unwind-protect
        (progn
          (process-send-string w "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":1}}\n")
          (should (drgnx-acp-test--wait (lambda () (string-search "protocolVersion" out))))
          (process-send-eof w)
          (should (drgnx-acp-test--wait (lambda () (not (process-live-p p))))))     ; the FIFO's EOF ends the mock
      (delete-process w) (delete-process p) (delete-directory dir t))))

(ert-deftest drgnx-acp/the-mock-wrapper-carries-stdin-through-a-fifo-it-removes ()
  (let* ((tmp (make-temp-file "drgnx-mock-tmp" t)) (out "")
         (process-environment (cons (concat "TMPDIR=" tmp) process-environment))
         (p (make-process :name "wrapped" :command (list "sh" drgnx-acp-test--wrapper "sh" "-c" "exec cat \"$MOCK_ACP_IN\"")
                          :connection-type 'pipe :noquery t :filter (lambda (_p s) (setq out (concat out s))))))
    (unwind-protect
        (progn
          (process-send-string p "hello\n")
          (should (drgnx-acp-test--wait (lambda () (equal out "hello\n"))))
          (should-not (directory-files tmp nil "\\`[^.]"))           ; both ends open: the FIFO's name is gone
          (process-send-eof p)
          (should (drgnx-acp-test--wait (lambda () (not (process-live-p p)))))
          (should (eql (process-exit-status p) 0)))
      (delete-process p) (delete-directory tmp t))))

(ert-deftest drgnx-acp/a-mock-gone-before-it-reads-leaves-no-process-and-no-fifo ()
  ;; A mock that exits (or is stopped) before it opens the FIFO: nothing of the wrapper's waits on for ever,
  ;; holding the caller's pipes.  MARKER names the wrapper's own processes (`true' ignores it).
  (let* ((tmp (make-temp-file "drgnx-mock-tmp" t)) (marker (format "drgnx-mock-early-%d" (random 1000000)))
         (process-environment (cons (concat "TMPDIR=" tmp) process-environment))
         (survivors (lambda () (seq-filter (lambda (pid) (string-search marker (or (alist-get 'args (process-attributes pid)) "")))
                                           (list-system-processes))))
         (p (make-process :name "wrapped" :command (list "sh" drgnx-acp-test--wrapper "true" marker)
                          :connection-type 'pipe :noquery t)))
    (unwind-protect
        (progn
          (process-send-string p "hi\n")
          (should (drgnx-acp-test--wait (lambda () (not (process-live-p p)))))
          (should (drgnx-acp-test--wait (lambda () (and (null (funcall survivors)) (null (directory-files tmp nil "\\`[^.]")))) 5))
          (should-not (funcall survivors))
          (should-not (directory-files tmp nil "\\`[^.]")))
      (dolist (pid (funcall survivors)) (signal-process pid 'kill))
      (delete-process p) (delete-directory tmp t))))

(ert-deftest drgnx-acp/lines-are-framed-whatever-the-chunks ()
  ;; No process: the framing alone.  A line split across outputs, a malformed line (logged,
  ;; skipped), a 1 MB line, several lines in one output.
  (let* ((got nil)
         (c (drgnx-acp--make :on-notification (lambda (_c method params) (push (cons method params) got)))))
    (unwind-protect
        (progn
          (drgnx-acp--input c "{\"jsonrpc\":\"2.0\",\"method\":\"a\"")
          (should-not got)
          (drgnx-acp--input c ",\"params\":{\"n\":1}}\nnot json at all\n")
          (should (equal got '(("a" :n 1))))
          (should (string-match-p "not json" (car (drgnx-acp-conn-log c))))
          (let ((big (make-string 1000000 ?x)))
            (drgnx-acp--input c (concat "{\"jsonrpc\":\"2.0\",\"method\":\"big\",\"params\":{\"s\":\"" big "\"}}\n"
                                        "{\"jsonrpc\":\"2.0\",\"method\":\"c\",\"params\":{}}\n"))
            (should (equal (mapcar #'car got) '("c" "big" "a")))
            (should (= (length (plist-get (cdr (nth 1 got)) :s)) 1000000))))
      (drgnx-acp-stop c))))

;;;; The watchdog, on the timer layer (virtual time)

(defmacro drgnx-acp-test--timed (&rest body)
  "BODY on the virtual clock with no recorded timer errors and a state dir of its own."
  (declare (indent 0))
  `(let* ((state (make-temp-file "drgnx-acp-state" t))
          (process-environment (cons (concat "XDG_STATE_HOME=" state) process-environment))
          (drgnx-timer-errors nil))
     (unwind-protect (drgnx-test-with-clock () ,@body) (delete-directory state t))))

(defun drgnx-acp-test--sleeper (&rest keys)
  "A connection to a process that only sleeps, its sentinel replaced by `ignore': only the watchdog can notice it die."
  (let ((conn (apply #'drgnx-acp-start (list "sleep" "30") keys)))
    (set-process-sentinel (drgnx-acp-conn-process conn) #'ignore)
    conn))

(defun drgnx-acp-test--kill (conn)
  "Kill CONN's process and wait (real time, in polls: the clock is virtual) until it is dead."
  (let ((p (drgnx-acp-conn-process conn)) (n 0))
    (kill-process p)
    (while (and (process-live-p p) (< (cl-incf n) 500)) (accept-process-output nil 0.02))
    (should-not (process-live-p p))))

(ert-deftest drgnx-acp/the-watchdog-reports-a-dead-agent ()
  (drgnx-acp-test--timed
    (let* ((status 'none) (conn (drgnx-acp-test--sleeper :on-exit (lambda (_c s _e) (setq status s)))))
      (unwind-protect
          (progn
            (should (drgnx-timer-active-p (cons 'acp-watchdog (drgnx-acp-conn-process conn))))
            (drgnx-test-advance 1.0)
            (should-not (drgnx-acp-conn-exited conn))        ; alive: nothing reported
            (drgnx-acp-test--kill conn)
            (drgnx-test-advance 0.5)                         ; one watchdog period
            (should (drgnx-acp-conn-exited conn))
            (should-not (drgnx-timer-active-p (cons 'acp-watchdog (drgnx-acp-conn-process conn))))
            (drgnx-test-advance 0.1)                         ; the exit is reported a moment later
            (should-not (eq status 'none)))
        (drgnx-acp-stop conn)))))

(ert-deftest drgnx-acp/the-exit-report-is-a-keyed-timer ()
  (drgnx-acp-test--timed
    (let* ((status 'none) (conn (drgnx-acp-test--sleeper :on-exit (lambda (_c s _e) (setq status s))))
           (key (cons 'acp-exit (drgnx-acp-conn-process conn))))
      (unwind-protect
          (progn
            (should-not (drgnx-timer-active-p key))
            (drgnx-acp-test--kill conn)
            (drgnx-test-advance 0.5)                         ; the watchdog notices
            (should (drgnx-timer-active-p key))
            (should (eq status 'none))
            (drgnx-test-advance 0.1)
            (should-not (drgnx-timer-active-p key))
            (should-not (eq status 'none)))
        (drgnx-acp-stop conn)))))

(ert-deftest drgnx-acp/a-failing-exit-handler-is-recorded-and-the-cleanup-still-runs ()
  (drgnx-acp-test--timed
    (let* ((conn (drgnx-acp-test--sleeper :on-exit (lambda (&rest _) (error "Boom"))))
           (stderr (drgnx-acp-conn-stderr-process conn)))
      (unwind-protect
          (progn
            (drgnx-acp-test--kill conn)
            (drgnx-test-advance 0.7)
            (should (= (length drgnx-timer-errors) 1))
            (should (equal (plist-get (car drgnx-timer-errors) :fn) 'drgnx-acp--report-exit))
            (should-not (process-live-p stderr)))
        (drgnx-acp-stop conn)))))

(ert-deftest drgnx-acp/a-failing-watchdog-stops-after-three ()
  (drgnx-acp-test--timed
    (let ((conn (drgnx-acp-test--sleeper)) (key nil))
      (unwind-protect
          (progn
            (setq key (cons 'acp-watchdog (drgnx-acp-conn-process conn)))
            (drgnx-acp-test--kill conn)
            (cl-letf (((symbol-function 'drgnx-acp--exited) (lambda (&rest _) (error "Boom"))))
              (drgnx-test-advance 1.6))                      ; 3 periods
            (should (= (length drgnx-timer-errors) 3))
            (should (equal (plist-get (car drgnx-timer-errors) :key) key))
            (should (plist-get (car drgnx-timer-errors) :stopped))
            (should-not (drgnx-timer-active-p key))
            (cl-letf (((symbol-function 'drgnx-acp--exited) (lambda (&rest _) (error "Boom"))))
              (drgnx-test-advance 3))                        ; and no more, every half second
            (should (= (length drgnx-timer-errors) 3)))
        (drgnx-acp-stop conn)))))

(ert-deftest drgnx-acp/stop-cancels-the-watchdog ()
  (drgnx-acp-test--timed
    (let* ((conn (drgnx-acp-test--sleeper)) (key (cons 'acp-watchdog (drgnx-acp-conn-process conn))))
      (should (drgnx-timer-active-p key))
      (drgnx-acp-stop conn)
      (should-not (drgnx-timer-active-p key)))))

(ert-deftest drgnx-acp/two-connections-two-watchdogs ()
  (drgnx-acp-test--timed
    (let* ((a (drgnx-acp-test--sleeper)) (b (drgnx-acp-test--sleeper))
           (ka (cons 'acp-watchdog (drgnx-acp-conn-process a))) (kb (cons 'acp-watchdog (drgnx-acp-conn-process b))))
      (unwind-protect
          (progn
            (should (drgnx-timer-active-p ka))
            (should (drgnx-timer-active-p kb))
            (drgnx-acp-stop a)
            (should-not (drgnx-timer-active-p ka))
            (should (drgnx-timer-active-p kb)))              ; the other connection keeps its own
        (drgnx-acp-stop a) (drgnx-acp-stop b)))))

;;; acp-test.el ends here
