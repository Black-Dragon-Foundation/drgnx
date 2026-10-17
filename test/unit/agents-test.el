;;; agents-test.el --- batch tests: agent sessions against the mock ACP agent -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-agents)
(require 'drgnx-paths)

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
           (list (list "mock" :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q" "-l" drgnx-agents-test--mock)
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
  (mapcar (lambda (e) (plist-get e :text)) (seq-filter (lambda (e) (eq (plist-get e :type) type)) (drgnx-agent-session-entries s))))

(defun drgnx-agents-test--idle (s) (drgnx-agents-test--wait (lambda () (eq (drgnx-agent-session-status s) 'idle))))

(ert-deftest drgnx-agents/a-turn-fills-the-transcript ()
  (skip-unless (file-readable-p "/proc/self/fd/0"))
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
  (skip-unless (file-readable-p "/proc/self/fd/0"))
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
  (skip-unless (file-readable-p "/proc/self/fd/0"))
  (drgnx-agents-test--with s '(:mode steer)
    (drgnx-agents-send s "slow one")
    (drgnx-agents-send s "go left")
    (should-not (drgnx-agent-session-queue s))
    (should (drgnx-agents-test--idle s))
    (should (string-match-p "steered: go left" (car (drgnx-agents-test--texts s 'agent))))
    (should (equal (drgnx-agents-test--texts s 'user) '("slow one" "go left")))   ; one prompt, one steer
    (should (plist-get (car (last (seq-filter (lambda (e) (eq (plist-get e :type) 'user)) (drgnx-agent-session-entries s)))) :steer))))

(ert-deftest drgnx-agents/steer-without-the-capability-queues ()
  (skip-unless (file-readable-p "/proc/self/fd/0"))
  (drgnx-agents-test--with s '(:mode steer :env ("MOCK_ACP_NO_STEER=1"))
    (drgnx-agents-send s "slow one")
    (drgnx-agents-send s "go left")
    (should (equal (drgnx-agent-session-queue s) '("go left")))))

(ert-deftest drgnx-agents/stop-ends-the-turn-within-a-second-and-keeps-the-queue ()
  (skip-unless (file-readable-p "/proc/self/fd/0"))
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
  (skip-unless (file-readable-p "/proc/self/fd/0"))
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
  (skip-unless (file-readable-p "/proc/self/fd/0"))
  (drgnx-agents-test--with s nil
    (drgnx-agents-send s "permission please")
    (should (drgnx-agents-test--wait (lambda () (drgnx-agent-session-permissions s))))
    (drgnx-agents-stop s)
    (should-not (drgnx-agent-session-permissions s))
    (should (drgnx-agents-test--idle s))))

(ert-deftest drgnx-agents/tool-calls-plans-and-subagents ()
  (skip-unless (file-readable-p "/proc/self/fd/0"))
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
  (skip-unless (file-readable-p "/proc/self/fd/0"))
  (drgnx-agents-test--with s nil
    (drgnx-agents-send s "crash")
    (drgnx-agents-send s "after")
    (should (drgnx-agents-test--wait (lambda () (eq (drgnx-agent-session-status s) 'exited))))
    (should (string-match-p "mock crashed" (drgnx-agent-session-stderr s)))
    (should (equal (drgnx-agent-session-queue s) '("after")))))

(ert-deftest drgnx-agents/take-over-resumes-a-session ()
  (skip-unless (file-readable-p "/proc/self/fd/0"))
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
  (skip-unless (file-readable-p "/proc/self/fd/0"))
  (drgnx-agents-test--with s nil
    (drgnx-agents-send s (make-string 300 ?w))
    (should (drgnx-agents-test--idle s))
    (let ((before (drgnx-agents-context-percent s)))
      (drgnx-agents-send s "/compact")
      (should (drgnx-agents-test--idle s))
      (should (< (drgnx-agents-context-percent s) before)))))

;;; agents-test.el ends here
