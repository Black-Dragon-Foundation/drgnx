;;; agents-test.el --- batch tests: agent sessions against the mock ACP agent -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-agents)
(require 'drgnx-paths)
(require 'drgnx-timer)
(require 'bytecomp)                                  ; `byte-compile-warnings' is let-bound below
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)

(defconst drgnx-agents-test--mock (expand-file-name "test/fixtures/mock-acp.el" drgnx-dir))

(defun drgnx-agents-test--wait (pred &optional secs)
  (let ((deadline (+ (float-time) (or secs 10))) v)
    (while (and (not (setq v (funcall pred))) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    v))

(defmacro drgnx-agents-test--with (s opts &rest body)
  "BODY with S a started session of the mock agent (OPTS: :mode :env)."
  (declare (indent 2))
  `(let* ((state (make-temp-file "drgnx-mock-state" t))
          (drgnx-agents-profiles
           (list (list "mock" :command (list "sh" (expand-file-name "test/fixtures/mock-acp-stdin.sh" drgnx-dir) (expand-file-name invocation-name invocation-directory) "--batch" "-Q" "-l" drgnx-agents-test--mock)
                       :env (append (list (concat "MOCK_ACP_STATE=" state)) (plist-get ,opts :env))
                       :mode (or (plist-get ,opts :mode) 'queue))))
          (drgnx-agents--sessions nil)
          (,s (drgnx-agents-start "mock" temporary-file-directory)))
     (unwind-protect
         (progn (should (drgnx-agents-test--wait (lambda () (eq (drgnx-agent-session-status ,s) 'idle))))
                ,@body)
       (dolist (x drgnx-agents--sessions) (drgnx-agents-kill x))
       (delete-directory state t))))

(defun drgnx-agents-test--texts (s type)
  (mapcar #'drgnx-agents-entry-text (seq-filter (lambda (e) (eq (plist-get e :type) type)) (drgnx-agent-session-entries s))))

(defun drgnx-agents-test--idle (s) (drgnx-agents-test--wait (lambda () (eq (drgnx-agent-session-status s) 'idle))))

(ert-deftest drgnx-agents/a-turn-fills-the-transcript ()
  (drgnx-agents-test--with s nil
    (should (drgnx-agents-test--wait (lambda () (drgnx-agent-session-commands s))))
    (should (equal (mapcar (lambda (c) (plist-get c :name)) (drgnx-agent-session-commands s)) '("compact" "review")))
    (drgnx-agents-send s "hello there")
    (should (eq (drgnx-agent-session-status s) 'busy))
    (should (drgnx-agents-test--idle s))
    (should (equal (drgnx-agents-test--texts s 'user) '("hello there")))
    (should (equal (drgnx-agents-test--texts s 'agent) '("You said: hello there")))   ; chunks joined
    (should (equal (drgnx-agents-test--texts s 'thought) '("thinking…")))
    (should (numberp (drgnx-agents-context-percent s)))))

(ert-deftest drgnx-agents/sending-during-a-turn-queues-and-never-cancels ()
  ;; The spec's first rule: queued, delivered once, in order, after the turn; the turn not cancelled.
  (drgnx-agents-test--with s nil
    (drgnx-agents-send s "slow one")
    (drgnx-agents-send s "second")
    (drgnx-agents-send s "third")
    (should (equal (drgnx-agent-session-queue s) '("second" "third")))
    (should (drgnx-agents-test--wait (lambda () (and (null (drgnx-agent-session-queue s))
                                                     (eq (drgnx-agent-session-status s) 'idle)
                                                     (= 3 (length (drgnx-agents-test--texts s 'user)))))
                                     15))
    (should (equal (drgnx-agents-test--texts s 'user) '("slow one" "second" "third")))
    (should-not (seq-find (lambda (e) (equal (plist-get e :stop) "cancelled")) (drgnx-agent-session-entries s)))
    (should (string-match-p "part 10" (car (drgnx-agents-test--texts s 'agent))))))

(ert-deftest drgnx-agents/steer-mode-reaches-the-running-turn ()
  (drgnx-agents-test--with s '(:mode steer)
    (drgnx-agents-send s "slow one")
    (drgnx-agents-send s "go left")
    (should-not (drgnx-agent-session-queue s))
    (should (drgnx-agents-test--idle s))
    (should (string-match-p "steered: go left" (car (drgnx-agents-test--texts s 'agent))))
    (should (equal (drgnx-agents-test--texts s 'user) '("slow one" "go left")))   ; one prompt, one steer
    (should (plist-get (car (last (seq-filter (lambda (e) (eq (plist-get e :type) 'user)) (drgnx-agent-session-entries s)))) :steer))))

(ert-deftest drgnx-agents/steer-without-the-capability-queues ()
  (drgnx-agents-test--with s '(:mode steer :env ("MOCK_ACP_NO_STEER=1"))
    (drgnx-agents-send s "slow one")
    (drgnx-agents-send s "go left")
    (should (equal (drgnx-agent-session-queue s) '("go left")))))

(ert-deftest drgnx-agents/stop-ends-the-turn-within-a-second-and-keeps-the-queue ()
  :tags '(:timing)                                      ; a quiet machine: bin/drgnx check runs it alone
  (drgnx-agents-test--with s nil
    (drgnx-agents-send s "slow one")
    (drgnx-agents-send s "later")
    (sleep-for 0.4)
    (let ((t0 (float-time)))
      (drgnx-agents-stop s)
      (should (drgnx-agents-test--idle s))
      (should (< (- (float-time) t0) 1.0)))
    (should (seq-find (lambda (e) (equal (plist-get e :stop) "cancelled")) (drgnx-agent-session-entries s)))
    (should (equal (drgnx-agent-session-queue s) '("later")))             ; kept, not sent (paused)
    (sleep-for 0.5)
    (should (= 1 (length (drgnx-agents-test--texts s 'user))))))

(ert-deftest drgnx-agents/permission-requests-wait-for-an-answer ()
  ;; Never a minibuffer question: a pending item the viewer answers.
  (drgnx-agents-test--with s nil
    (let ((inhibit-interaction t))
      (drgnx-agents-send s "permission please")
      (should (drgnx-agents-test--wait (lambda () (drgnx-agent-session-permissions s))))
      (let ((p (car (drgnx-agent-session-permissions s))))
        (should (equal (plist-get p :title) "Run rm -rf build"))
        (drgnx-agents-answer-permission s p "allow"))
      (should (drgnx-agents-test--idle s))
      (should-not (drgnx-agent-session-permissions s))
      (should (member "permission: allow" (drgnx-agents-test--texts s 'agent))))))

(ert-deftest drgnx-agents/stop-answers-pending-permissions-cancelled ()
  (drgnx-agents-test--with s nil
    (drgnx-agents-send s "permission please")
    (should (drgnx-agents-test--wait (lambda () (drgnx-agent-session-permissions s))))
    (drgnx-agents-stop s)
    (should-not (drgnx-agent-session-permissions s))
    (should (drgnx-agents-test--idle s))))

(ert-deftest drgnx-agents/tool-calls-plans-and-subagents ()
  (drgnx-agents-test--with s nil
    (drgnx-agents-send s "tool plan subagent")
    (should (drgnx-agents-test--idle s))
    (let* ((tools (seq-filter (lambda (e) (eq (plist-get e :type) 'tool)) (drgnx-agent-session-entries s)))
           (t1 (seq-find (lambda (e) (equal (plist-get e :id) "t1")) tools))
           (task (seq-find (lambda (e) (equal (plist-get e :id) "task1")) tools)))
      (should (equal (plist-get t1 :status) "completed"))
      (should (equal (plist-get task :status) "completed"))
      (should (equal (mapcar (lambda (c) (plist-get c :title)) (plist-get task :children)) '("Grep" "Read")))
      (should-not (seq-find (lambda (e) (equal (plist-get e :id) "c1")) tools)))           ; under its parent only
    (let ((plan (seq-find (lambda (e) (eq (plist-get e :type) 'plan)) (drgnx-agent-session-entries s))))
      (should (equal (mapcar (lambda (x) (plist-get x :status)) (plist-get plan :entries)) '("completed" "in_progress" "pending"))))))

(ert-deftest drgnx-agents/an-agent-that-dies-says-so-and-keeps-the-queue ()
  (drgnx-agents-test--with s nil
    (drgnx-agents-send s "crash")
    (drgnx-agents-send s "after")
    (should (drgnx-agents-test--wait (lambda () (eq (drgnx-agent-session-status s) 'exited))))
    (should (string-match-p "mock crashed" (drgnx-agent-session-stderr s)))
    (should (equal (drgnx-agent-session-queue s) '("after")))))

(ert-deftest drgnx-agents/take-over-resumes-a-session ()
  (drgnx-agents-test--with s nil
    (drgnx-agents-send s "remember me")
    (should (drgnx-agents-test--idle s))
    (let ((sid (drgnx-agent-session-acp-id s)))
      (drgnx-agents-kill s)
      (let ((s2 (drgnx-agents-take-over "mock" temporary-file-directory sid)))
        (should (drgnx-agents-test--idle s2))
        (should (equal (drgnx-agent-session-acp-id s2) sid))
        (should (equal (drgnx-agents-test--texts s2 'agent) '("You said: remember me")))))))

(ert-deftest drgnx-agents/compact-lowers-the-context ()
  ;; The parity rule (kb: agent-viewer-openrouter-parity): context %, /compact, slash commands.
  (drgnx-agents-test--with s nil
    (drgnx-agents-send s (make-string 300 ?w))
    (should (drgnx-agents-test--idle s))
    (let ((before (drgnx-agents-context-percent s)))
      (drgnx-agents-send s "/compact")
      (should (drgnx-agents-test--idle s))
      (should (< (drgnx-agents-context-percent s) before)))))

;;;; Review fixes (M7 final review)

(defun drgnx-agents-test--shape (s)
  "The user/stop rhythm of S's transcript: (user stop user stop …)."
  (delq nil (mapcar (lambda (e) (memq (plist-get e :type) '(user stop))) (drgnx-agent-session-entries s))))

(ert-deftest drgnx-agents/a-late-answer-to-a-stopped-turn-never-ends-the-next ()
  ;; C1: the agent answers the cancel after the 1 s deadline; the next turns stay in order, one at a time.
  (drgnx-agents-test--with s '(:env ("MOCK_ACP_LATE_CANCEL=2"))
    (drgnx-agents-send s "slow one")
    (sleep-for 0.3)
    (drgnx-agents-stop s)
    (should (drgnx-agents-test--idle s))                         ; the deadline ended it locally
    (drgnx-agents-send s "second")
    (drgnx-agents-send s "third")
    (should (drgnx-agents-test--wait (lambda () (and (eq (drgnx-agent-session-status s) 'idle) (null (drgnx-agent-session-queue s))
                                                     (= 3 (length (drgnx-agents-test--texts s 'user)))
                                                     (= 3 (seq-count (lambda (e) (eq (plist-get e :type) 'stop)) (drgnx-agent-session-entries s)))))
                                     15))
    (should (equal (mapcar #'car (mapcar #'list (drgnx-agents-test--texts s 'user))) '("slow one" "second" "third")))
    (should-not (seq-find (lambda (x) (string-search "OVERLAPPING" x)) (drgnx-agents-test--texts s 'agent)))
    (should (equal (mapcar (lambda (e) (plist-get e :type))
                           (seq-filter (lambda (e) (memq (plist-get e :type) '(user stop))) (drgnx-agent-session-entries s)))
                   '(user stop user stop user stop)))))

(ert-deftest drgnx-agents/interrupt-mode-sends-the-message-after-the-cancel ()
  ;; I3
  (drgnx-agents-test--with s '(:mode interrupt)
    (drgnx-agents-send s "slow one")
    (drgnx-agents-send s "now this")
    (should (drgnx-agents-test--wait (lambda () (member "now this" (drgnx-agents-test--texts s 'user))) 5))
    (should (drgnx-agents-test--idle s))
    (should-not (drgnx-agent-session-queue s))))

(ert-deftest drgnx-agents/a-message-sent-while-starting-is-delivered ()
  ;; I4
  (let* ((drgnx-agents-profiles
          (list (list "mock" :command (list "sh" (expand-file-name "test/fixtures/mock-acp-stdin.sh" drgnx-dir) (expand-file-name invocation-name invocation-directory) "--batch" "-Q" "-l" drgnx-agents-test--mock))))
         (drgnx-agents--sessions nil)
         (s (drgnx-agents-start "mock" temporary-file-directory)))
    (unwind-protect
        (progn
          (drgnx-agents-send s "early")
          (should (drgnx-agents-test--wait (lambda () (and (eq (drgnx-agent-session-status s) 'idle)
                                                           (member "You said: early" (drgnx-agents-test--texts s 'agent))))))
          (should-not (drgnx-agent-session-queue s)))
      (drgnx-agents-kill s))))

(ert-deftest drgnx-agents/two-sessions-of-a-profile-have-their-own-names ()
  ;; I13
  (drgnx-agents-test--with s nil
    (let ((s2 (drgnx-agents-start "mock" temporary-file-directory)))
      (should-not (equal (drgnx-agent-session-name s) (drgnx-agent-session-name s2))))))

(ert-deftest drgnx-agents/a-missing-agent-program-is-an-exited-session ()
  ;; I14: the first run without claude-agent-acp installed
  (let ((drgnx-agents-profiles '(("nope" :command ("drgnx-no-such-agent-program-x"))))
        (drgnx-agents--sessions nil)
        (before (length (process-list))))
    (let ((s (drgnx-agents-start "nope" temporary-file-directory)))
      (should (eq (drgnx-agent-session-status s) 'exited))
      (should (seq-find (lambda (e) (eq (plist-get e :type) 'error)) (drgnx-agent-session-entries s)))
      (should (= (length (process-list)) before)))))

(ert-deftest drgnx-agents/steering-that-fails-queues-the-message ()
  ;; I12: a request (not a notification): an error puts the text in the queue
  (drgnx-agents-test--with s '(:mode steer :env ("MOCK_ACP_STEER_FAILS=1"))
    (drgnx-agents-send s "slow one")
    (drgnx-agents-send s "go left")
    (should (drgnx-agents-test--wait (lambda () (equal (drgnx-agent-session-queue s) '("go left"))) 3))))

(ert-deftest drgnx-agents/reads-honour-line-and-limit-and-need-absolute-paths ()
  ;; I10 and the path checks
  (let* ((f (make-temp-file "drgnx-read")) (s (drgnx-agents--make :cwd temporary-file-directory)))
    (unwind-protect
        (progn
          (write-region (mapconcat (lambda (i) (format "l%d" i)) (number-sequence 1 10) "\n") nil f nil 'silent)
          (should (equal (plist-get (plist-get (drgnx-agents--on-request s "fs/read_text_file" (list :path f :line 3 :limit 2) 1) :result) :content)
                         "l3\nl4\n"))
          (should (plist-get (drgnx-agents--on-request s "fs/read_text_file" (list :path "~/x") 2) :error))
          (should (plist-get (drgnx-agents--on-request s "fs/read_text_file" (list :path "rel/x") 3) :error))
          (should (plist-get (drgnx-agents--on-request s "fs/write_text_file" (list :path "rel/x" :content "a") 4) :error))
          (should (plist-get (drgnx-agents--on-request s "fs/write_text_file" (list :path f) 5) :error)))
      (delete-file f))))

(ert-deftest drgnx-agents/reads-refuse-fifos-devices-remote-paths-and-big-files ()
  ;; fs/read_text_file is served by the hub, outside any sandbox: a FIFO would block it inside a process filter, a
  ;; device may never end, a remote path reaches TRAMP (a connection, a password prompt), a huge file fills it
  (skip-unless (executable-find "mkfifo"))
  (let* ((dir (make-temp-file "drgnx-read" t)) (fifo (expand-file-name "fifo" dir)) (big (expand-file-name "big" dir))
         (s (drgnx-agents--make :cwd dir)) (writer nil)
         (err (lambda (path) (plist-get (drgnx-agents--on-request s "fs/read_text_file" (list :path path) 1) :error)))
         (real (symbol-function 'tramp-file-name-handler)))
    (unwind-protect
        (progn
          (should (eql 0 (call-process "mkfifo" nil nil nil fifo)))
          ;; were the FIFO opened, this writer lets it go after 2 s: the test fails instead of hanging
          (setq writer (start-process "drgnx-fifo-writer" nil "sh" "-c" (format "sleep 2; echo x > %s" (shell-quote-argument fifo))))
          (let ((t0 (float-time)))
            (should (funcall err fifo))
            (should (< (- (float-time) t0) 1)))
          (should (funcall err "/dev/null"))
          (write-region (make-string (1+ drgnx-agents-read-max) ?x) nil big nil 'silent)
          (should (funcall err big))
          (cl-letf (((symbol-function 'tramp-file-name-handler)       ; any remote operation but naming the host
                     (lambda (op &rest args) (if (eq op 'file-remote-p) (apply real op args) (error "Touched a remote file: %s" op)))))
            (should (funcall err "/ssh:nobody@example.invalid:/x"))
            (should (funcall err "/sudo::/etc/shadow")))
          ;; a regular file up to the cap is still read
          (write-region "ok\n" nil big nil 'silent)
          (should (equal (plist-get (plist-get (drgnx-agents--on-request s "fs/read_text_file" (list :path big) 2) :result) :content) "ok\n")))
      (when (process-live-p writer) (delete-process writer))
      (delete-directory dir t))))

(ert-deftest drgnx-agents/stop-answers-pending-writes-too ()
  (let* ((answers nil)
         (s (drgnx-agents--make :status 'busy :acp-id "x" :id "s-writes" :reviews (list '(:id 9 :path "/tmp/x" :content "y")))))
    (cl-letf (((symbol-function 'drgnx-acp-respond) (lambda (_c id _r &optional err) (push (list id err) answers)))
              ((symbol-function 'drgnx-acp-notify) #'ignore))
      (unwind-protect
          (progn
            (drgnx-agents-stop s)
            (should-not (drgnx-agent-session-reviews s))
            (should (equal (car answers) '(9 (:code -32003 :message "the turn was stopped")))))
        (drgnx-timer-cancel '(agents-stop . "s-writes"))))))

(ert-deftest drgnx-agents/a-stop-that-is-never-answered-ends-the-turn-then-frees-the-queue ()
  ;; A-29: these deadlines were raw timers that outlived the test and fired in the next one, on a session with no
  ;; connection (`wrong-type-argument drgnx-acp-conn nil').  They are keyed layer timers now, and a session whose
  ;; agent is gone is `exited', not an error.
  (let ((drgnx-timer-errors nil)
        (s (drgnx-agents--make :status 'busy :acp-id "x" :id "s-stop" :turn 4 :queue '("later"))))
    (cl-letf (((symbol-function 'drgnx-acp-notify) #'ignore))
      (drgnx-test-with-clock ()
        (drgnx-agents-stop s)
        (drgnx-agents-stop s)                                ; a second stop replaces the first, never stacks
        (should (= (length (cl-remove-if-not (lambda (e) (eq (car-safe (car e)) 'agents-stop)) (drgnx-timer-pending))) 1))
        (drgnx-test-advance 0.8)
        (should (eq (drgnx-agent-session-status s) 'busy))
        (drgnx-test-advance 0.2)
        (should (eq (drgnx-agent-session-status s) 'exited))
        (should (eql (drgnx-agent-session-draining s) 4))
        (should (drgnx-timer-active-p '(agents-drain . "s-stop")))
        (drgnx-test-advance 10)
        (should-not (drgnx-agent-session-draining s))
        (should-not (drgnx-timer-active-p '(agents-drain . "s-stop")))
        (should-not drgnx-timer-errors)))))

(ert-deftest drgnx-agents/a-turn-that-answers-before-the-deadline-keeps-its-session ()
  (let ((drgnx-timer-errors nil)
        (s (drgnx-agents--make :status 'busy :acp-id "x" :id "s-late" :turn 4)))
    (cl-letf (((symbol-function 'drgnx-acp-notify) #'ignore))
      (drgnx-test-with-clock ()
        (drgnx-agents-stop s)
        (setf (drgnx-agent-session-turn s) 5)                ; the stopped turn ended and another began
        (drgnx-test-advance 1)
        (should (eq (drgnx-agent-session-status s) 'busy))
        (should-not (drgnx-agent-session-draining s))
        (should-not (drgnx-timer-active-p '(agents-drain . "s-late")))
        (should-not drgnx-timer-errors)))))

(ert-deftest drgnx-agents/a-session-that-was-never-made-is-never-prompted ()
  (let* ((sent nil) (s (drgnx-agents--make :status 'idle :acp-id nil)))
    (cl-letf (((symbol-function 'drgnx-acp-request) (lambda (&rest a) (push a sent))))
      (drgnx-agents-send s "hello")
      (should-not sent)
      (should (equal (drgnx-agent-session-queue s) '("hello"))))))

;;;; Streamed text: chunks are kept, joined once when read

(ert-deftest drgnx-agents/chunks-are-joined-once-when-read ()
  (let* ((s (drgnx-agents--make :name "chunks" :status 'busy)))
    (dolist (c '("Hel" "lo, " "wor" "ld")) (drgnx-agents--append-text s 'agent c))
    (let ((e (car (drgnx-agent-session-entries s))))
      (should (= 1 (length (drgnx-agent-session-entries s))))
      (should (= 12 (drgnx-agents-entry-length e)))
      (should (equal "world" (drgnx-agents-entry-tail e 7)))         ; only the newest chunks
      (should (equal "lo, world" (drgnx-agents-entry-tail e 3)))
      (should (equal "" (drgnx-agents-entry-tail e 12)))
      (should (equal "Hello, world" (drgnx-agents-entry-text e)))
      (should (eq (drgnx-agents-entry-text e) (drgnx-agents-entry-text e)))   ; joined once, kept until the next chunk
      (drgnx-agents--append-text s 'agent "!")
      (should (equal "d!" (drgnx-agents-entry-tail e 11)))
      (should (equal "Hello, world!" (drgnx-agents-entry-text e)))
      ;; the turn's end: the text is whole in :text, for everything that reads the plist
      (drgnx-agents--append-text s 'agent " Bye.")
      (drgnx-agents-join-text s)
      (should (equal "Hello, world! Bye." (plist-get e :text)))
      (should-not (plist-get e :chunks)))))

(defun drgnx-agents-test--append-alloc (size)
  "What appending a 100-character chunk to a running SIZE-character answer allocates (byte-compiled; least of 3)."
  (dolist (f '(drgnx-agents--append-text drgnx-agents-entry-length))
    (unless (compiled-function-p (symbol-function f)) (let ((byte-compile-warnings nil)) (byte-compile f))))
  (let* ((s (drgnx-agents--make :name "alloc" :status 'busy)) (chunk (make-string 100 ?b)) best
         (run (byte-compile (lambda () (drgnx-agents--append-text s 'agent chunk)))))
    (drgnx-agents--append-text s 'agent (make-string size ?a))
    (dotimes (i 5)
      (let* ((a (memory-use-counts)) (_ (funcall run)) (z (memory-use-counts)) (d (apply #'+ (cl-mapcar #'- z a))))
        (when (>= i 2) (setq best (if best (min best d) d)))))
    (should (= (+ size 500) (drgnx-agents-entry-length (car (drgnx-agent-session-entries s)))))
    best))

(ert-deftest drgnx-agents/a-chunk-costs-the-chunk-not-the-answer ()
  ;; AGENTS.md: stream parsing never concatenates the whole pending input per chunk
  (let ((small (drgnx-agents-test--append-alloc 4096)) (big (drgnx-agents-test--append-alloc 409600)))
    (message "chunk append allocation: 4 kB answer %d, 400 kB answer %d" small big)
    (should (= small big))
    (should (< big 100))))

;;; agents-test.el ends here
