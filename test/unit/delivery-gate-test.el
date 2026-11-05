;;; delivery-gate-test.el --- the delivery gate: the hub's lines released in the schedule a test gives -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: gated
;; The hub is the real Ratatoskr, built with test-hooks (DRGNX_RATATOSKR_BIN; the tests skip without it), started with
;; its clock and sequencer (`drgnx-test-with-ratatoskr' with `:gated t').  test/fixtures/delivery-gate-fixture.el is
;; the gate; docs/develop/harness.md, "The delivery gate".
(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'drgnx-paths)
(require 'drgnx-timer)
(require 'drgnx-hub-client)
(require 'drgnx-exec)
(require 'drgnx-ai)
(require 'drgnx-onboard)                ; its waits are the code under test of the real-children tests
(require 'drgnx-settings-runtime)
(require 'drgnx-settings-agents nil t)
(require 'drgnx-records-review nil t)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/ratatoskr-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/delivery-gate-fixture" drgnx-dir) nil t)

(defvar drgnx-exec--jobs)
(defvar drgnx-exec--stale)
(defvar drgnx-test-gate-waiting-ok)

(defmacro drgnx-delivery-gate-test--with-hub (&rest body)
  "BODY with ROOT a fresh folder, drgnx's dirs under it, and a gated Ratatoskr serving them; this Emacs not connected."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-gate" t)))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" root "config") (concat "DRGNX_DATA_DIR=" root "data")
                                             (concat "XDG_STATE_HOME=" root "state") (concat "HOME=" root "home")
                                             "OPENROUTER_API_KEY")
                                       process-environment))
          (drgnx-hub--asked-disconnect nil) (drgnx-hub--resubscribe-since nil) (drgnx-hub--resubscribe-delay 1)
          (drgnx-hub--presence-sent :unknown) (drgnx-hub-editor-token-hook nil)
          (drgnx-exec--jobs (make-hash-table :test #'equal)) (drgnx-exec--stale nil))
     (dolist (d '("config" "data" "state" "home")) (make-directory (concat root d) t))
     (unwind-protect
         (drgnx-test-with-ratatoskr root :gated t ,@body)
       (delete-directory root t))))

(defun drgnx-delivery-gate-test--json (line)
  (and (stringp line) (ignore-errors (json-parse-string line :object-type 'plist :null-object nil :false-object nil))))

(defun drgnx-delivery-gate-test--answer-held-p (name &optional key)
  "Whether connection NAME holds an answer (with KEY in its result, when given)."
  (cl-some (lambda (line)
             (let ((j (drgnx-delivery-gate-test--json line)))
               (and (plist-get j :id) (not (plist-get j :event))
                    (or (null key) (and (consp (plist-get j :result)) (plist-member (plist-get j :result) key))))))
           (drgnx-test-gate-held name)))

(defun drgnx-delivery-gate-test--paused-and-held ()
  "Wait until the schedule is at its pause (the settings answer released: the client sends that call only after its
hello's answer) and the subscribe answer is held: the two come in either real order."
  (drgnx-test-wait (lambda () (and (drgnx-test-gate--paused-p) (drgnx-delivery-gate-test--answer-held-p 'sub-1)))
                   :what "the pause, and the subscribe answer held"))

(defun drgnx-delivery-gate-test--shape (entry)
  "A delivery (NAME . LINE) as what it is, not what varies by run (ids, nonces, tokens): (NAME . :eof),
\(NAME :event EVENT), (NAME :error) or (NAME :answer RESULT-KEYS)."
  (cons (car entry)
        (if (eq (cdr entry) :eof) :eof
          (let ((j (drgnx-delivery-gate-test--json (cdr entry))))
            (cond ((plist-get j :event) (list :event (plist-get j :event)))
                  ((plist-get j :error) (list :error))
                  (t (let ((r (plist-get j :result)))
                       (list :answer (and (consp r) (keywordp (car r))
                                          (cl-loop for (k _) on r by #'cddr collect k))))))))))

(defun drgnx-delivery-gate-test--position (pred transcript)
  (cl-position-if pred transcript))

;;;; What the gate holds, and when it lets go

(ert-deftest drgnx-delivery-gate/lines-are-held-until-their-step ()
  "The hub has answered `subscribe', but the client sees the answer only at its step."
  (drgnx-delivery-gate-test--with-hub
    (let (before held)
      (drgnx-test-gated '((call-1 :answer "graph/settings") (:pause "held") (sub-1 :answer "subscribe"))
        (drgnx-hub-connect)
        (drgnx-delivery-gate-test--paused-and-held)
        (setq before drgnx-hub--events held (drgnx-test-gate-held 'sub-1))
        (drgnx-test-gate-continue "held")
        (drgnx-test-deliver-all)
        (should-not before)
        (should held)
        (should (eq drgnx-hub--events (drgnx-test-gate-conn 'sub-1)))))))

(ert-deftest drgnx-delivery-gate/a-chunk-of-two-lines-is-two-releases ()
  "What Emacs reads in one chunk (here two lines, the second split over two reads) reaches the client's filter one whole
line per call, each at its own step; so does everything the real hub sends."
  (drgnx-delivery-gate-test--with-hub
    (let* ((chunks nil) (events nil)
           (record (lambda (orig conn chunk) (push (cons conn chunk) chunks) (funcall orig conn chunk))))
      (advice-add 'drgnx-hub--client-filter :around record)
      (unwind-protect
          (drgnx-test-gated '((sub-1 :answer "subscribe") (:pause "inject")
                              (sub-1 :event "drgnx-gate-a") (sub-1 :event "drgnx-gate-b"))
            (add-hook 'drgnx-hub-event-functions (lambda (e _d) (push e events)))
            (drgnx-hub-connect)
            (drgnx-test-wait (lambda () drgnx-hub--events) :what "the subscription")
            (let ((sub (drgnx-test-gate-conn 'sub-1)))
              (funcall (process-filter sub) sub "{\"event\":\"drgnx-gate-a\",\"data\":{}}\n{\"event\":\"drgnx-gate-b\",\"da")
              (funcall (process-filter sub) sub "ta\":{}}\n"))
            (drgnx-test-gate-continue "inject")
            (drgnx-test-deliver-all)
            (should (member "drgnx-gate-a" events))
            (should (member "drgnx-gate-b" events))
            (should (member "{\"event\":\"drgnx-gate-a\",\"data\":{}}\n" (mapcar #'cdr chunks)))
            (should (member "{\"event\":\"drgnx-gate-b\",\"data\":{}}\n" (mapcar #'cdr chunks)))
            (should (cl-every (lambda (c) (let ((s (cdr c)))
                                            (and (string-suffix-p "\n" s) (= 1 (cl-count ?\n s)))))
                              chunks)))
        (advice-remove 'drgnx-hub--client-filter record)))))

(ert-deftest drgnx-delivery-gate/eof-comes-after-the-connections-held-lines ()
  "The hub stops while the subscribe answer is held: the client sees that answer, then the end, and the connection is
open to it until then."
  (drgnx-delivery-gate-test--with-hub
    (let* ((seen nil) held live-while-held
           (line (lambda (conn json) (push (list conn :line (plist-get json :event)) seen)))
           (end (lambda (conn _event) (push (list conn :end) seen))))
      (advice-add 'drgnx-hub--client-line :before line)
      (advice-add 'drgnx-hub--client-sentinel :before end)
      (unwind-protect
          (drgnx-test-gated '((call-1 :answer "graph/settings") (:pause "stop"))
            (drgnx-hub-connect)
            (drgnx-delivery-gate-test--paused-and-held)
            (signal-process drgnx-test-ratatoskr-process 'term)
            (drgnx-test-wait (lambda () (memq :eof (drgnx-test-gate-held 'sub-1))) :what "the end of sub-1, held")
            (setq held (drgnx-test-gate-held 'sub-1)
                  live-while-held (process-live-p (drgnx-test-gate-conn 'sub-1))
                  seen nil)
            (drgnx-test-gate-continue "stop")
            (drgnx-test-deliver-all)
            (let* ((sub (drgnx-test-gate-conn 'sub-1))
                   (mine (reverse (cl-remove-if-not (lambda (s) (eq (car s) sub)) seen)))
                   (lines (cl-count-if #'stringp held)))
              (should (>= lines 1))
              (should (eq (car (last held)) :eof))
              (should live-while-held)
              ;; every held line, then the end, which is the last thing the client sees on it
              (should (equal (mapcar #'cadr mine) (append (make-list lines :line) '(:end))))
              (should-not (process-live-p sub))))
        (advice-remove 'drgnx-hub--client-line line)
        (advice-remove 'drgnx-hub--client-sentinel end)))))

;;;; Waits inside the code under test

(ert-deftest drgnx-delivery-gate/a-nested-wait-releases-the-schedule ()
  "`drgnx-hub-call-sync' waits on `accept-process-output' inside itself: the gate releases the handshake and the step
there, so it returns with no help from the test, and no virtual time passed."
  (drgnx-delivery-gate-test--with-hub
    (let (result now)
      (drgnx-test-gated '((call-1 :answer "ping"))
        (setq result (drgnx-hub-call-sync "ping" nil)
              now (drgnx-test-clock-now))
        (drgnx-test-deliver-all)
        (should (natnump (plist-get result :pid)))
        (should (= now 0))))))

(ert-deftest drgnx-delivery-gate/a-nested-wait-on-a-held-line-fails-naming-the-step ()
  "At a pause, `drgnx-hub-call-sync' waiting for a line the gate holds fails the test at once (no deadline, no pass),
naming the pause, the next step and the caller."
  (drgnx-delivery-gate-test--with-hub
    (let* ((err (should-error (drgnx-test-gated '((:pause "held") (call-1 :answer "ping"))
                                (drgnx-hub-call-sync "ping" nil))
                              :type 'ert-test-failed))
           (data (cdr (cadr err))))
      (should (string-match-p "paused" (car (cadr err))))
      (should (equal (plist-get data :pause) "held"))
      (should (equal (plist-get data :next) '(call-1 :answer "ping")))
      (should (eq (plist-get data :caller) 'drgnx-hub-call-sync))
      ;; at its first wait: not one virtual tick toward the call's deadline went by
      (should (equal (plist-get data :virtual-secs) 0.0)))))

(ert-deftest drgnx-delivery-gate/a-nested-wait-after-the-last-step-fails-naming-the-call ()
  "Past the schedule's last step, `drgnx-hub-call-sync' waiting for an answer the gate holds fails the test at once,
naming the call and the caller: a virtual jump would take the code to its deadline, and it would take its timeout path
for an answer the hub gave."
  (drgnx-delivery-gate-test--with-hub
    (let* ((err (should-error (drgnx-test-gated nil
                                (drgnx-hub-call-sync "ping" nil 10))
                              :type 'ert-test-failed))
           (data (cdr (cadr err))))
      (should (string-match-p "after the last step" (car (cadr err))))
      (should (member "ping" (mapcar (lambda (c) (nth 2 c)) (plist-get data :calls))))
      (should (eq (plist-get data :caller) 'drgnx-hub-call-sync))
      (should (< (plist-get data :virtual-secs) 10)))))

(ert-deftest drgnx-delivery-gate/a-body-that-ends-with-steps-left-fails-naming-them ()
  "A step the body never released (its call never made: a misspelt method) or a pause never continued fails the test
when the body ends: the order the schedule names never happened, whatever the body asserted."
  (drgnx-delivery-gate-test--with-hub
    ;; (SCHEDULE STEPS-LEFT CALL): with (:answers t) the ping is answered and the misspelt step is never due; at the
    ;; pause the body makes no call (a wait there would fail as one while paused)
    (dolist (c '((((:answers t) (call-1 :answer "gateway/keys-helt")) ((call-1 :answer "gateway/keys-helt")) t)
                 (((:pause "never")) ((:pause "never")) nil)))
      (let ((err (should-error (drgnx-test-gated (car c) (when (nth 2 c) (drgnx-hub-call-sync "ping" nil 10)))
                               :type 'ert-test-failed)))
        (should (string-match-p "steps it never released" (car (cadr err))))
        (should (equal (plist-get (cdr (cadr err)) :steps) (cadr c)))))))

;;;; A line the hub holds

(ert-deftest drgnx-delivery-gate/a-step-for-a-held-write-gets-it-from-the-hub ()
  "A job's end (`exec-done') is written by the hub's job task, which the sequencer holds until a barrier: a step that
names it gets it, because the gate asks the hub for barriers while the step waits; the barriers write into the gate's
queues, and no virtual time passes meanwhile."
  (drgnx-delivery-gate-test--with-hub
    (let ((drgnx-test-gate-block-secs 10) (ended nil) started then now)
      (drgnx-test-gated '((sub-1 :answer "subscribe") (call-1 :answer "exec/start") (call-1 :answer "exec/get")
                          (sub-1 :event "exec-done"))
        (add-hook 'drgnx-hub-event-functions (lambda (e _d) (when (equal e "exec-done") (setq ended t))))
        (drgnx-hub-connect)
        (drgnx-test-wait (lambda () drgnx-hub--events) :what "the subscription")
        ;; (the start's look for a running hub is a wait of its own, on the clock: `then' is after it)
        (drgnx-exec-start "gate-job" (list "true") :cwd root :callback (lambda (id _why) (setq started id)))
        (setq then (drgnx-test-clock-now))
        (drgnx-test-wait (lambda () ended) :what "the job's end, through its step")
        (setq now (drgnx-test-clock-now))
        (drgnx-test-deliver-all))
      (should started)
      (should ended)
      (should (= now then)))))

;;;; A hub task inside a real wait

(defun drgnx-delivery-gate-test--start-held-job (go)
  "Start a job that runs until the file GO exists; its id once the hub answered (the schedule names `exec/start' and
`exec/get')."
  (let ((id nil))
    (drgnx-exec-start "gate-held-job"
                      (list "sh" "-c" (concat "until [ -e " (shell-quote-argument go) " ]; do sleep 0.05; done"))
                      :cwd (file-name-directory go) :callback (lambda (i _why) (setq id i)))
    (drgnx-test-wait (lambda () id) :what "the job's start")
    id))

(defun drgnx-delivery-gate-test--end-held-job (go)
  "End the job of `drgnx-delivery-gate-test--start-held-job': make GO, which never blocks (a named pipe's writer waits
for a reader, and macOS has no `timeout' to bound it)."
  (write-region "go\n" nil go nil 'silent))

(ert-deftest drgnx-delivery-gate/a-job-still-running-at-a-barrier-fails-naming-its-watcher ()
  "A job runs on through a barrier: its watcher waits on the child's end, a real wait, so what it writes later is not
ordered by the test.  The barrier waits for it (5 s of real time), then the test fails, naming the watcher's origin."
  (drgnx-delivery-gate-test--with-hub
    (let* ((go (concat root "go"))
           (err (unwind-protect
                    (should-error (drgnx-test-gated '((sub-1 :answer "subscribe") (call-1 :answer "exec/start")
                                                      (call-1 :answer "exec/get"))
                                    (drgnx-hub-connect)
                                    (drgnx-test-wait (lambda () drgnx-hub--events) :what "the subscription")
                                    (drgnx-delivery-gate-test--start-held-job go)
                                    (drgnx-test-deliver-all))
                                  :type 'ert-test-failed)
                  (drgnx-delivery-gate-test--end-held-job go))))
      (should (string-match-p "real wait" (car (cadr err))))
      (should (equal (plist-get (cdr (cadr err)) :waiting) '("exec:watch"))))))

(ert-deftest drgnx-delivery-gate/an-allowed-origin-inside-a-real-wait-passes-the-barrier ()
  "The same job, with its watcher's origin in `drgnx-test-gate-waiting-ok': the hub does not wait for it at the
barrier, and the test goes on."
  (drgnx-delivery-gate-test--with-hub
    (let ((go (concat root "go")) (drgnx-test-gate-waiting-ok '("exec:watch")) id m)
      (unwind-protect
          (drgnx-test-gated '((sub-1 :answer "subscribe") (call-1 :answer "exec/start") (call-1 :answer "exec/get"))
            (drgnx-hub-connect)
            (drgnx-test-wait (lambda () drgnx-hub--events) :what "the subscription")
            (setq id (drgnx-delivery-gate-test--start-held-job go))
            (setq m (drgnx-test-deliver-all)))
        (drgnx-delivery-gate-test--end-held-job go))
      (should id)
      (should (natnump m)))))

(ert-deftest drgnx-delivery-gate/answers-t-releases-every-answer-as-it-is-due ()
  "With (:answers t) every answer is released like a handshake line, so a call the code under test waits on returns
with no step of its own; the events stay held until a step or `drgnx-test-deliver-all'."
  (drgnx-delivery-gate-test--with-hub
    (let (pid now)
      (drgnx-test-gated '((:answers t))
        ;; the first ping's answer is a handshake line anyway; the second's is released by (:answers t)
        (drgnx-hub-call-sync "ping" nil 10)
        (setq pid (plist-get (drgnx-hub-call-sync "ping" nil 10) :pid)
              now (drgnx-test-clock-now))
        (drgnx-test-deliver-all))
      (should (natnump pid))
      (should (= now 0)))))

;;;; Real children of the code under test

(defun drgnx-delivery-gate-test--child (command said)
  "A real child running COMMAND (a shell line); what it prints goes into the cell SAID."
  (make-process :name "drgnx-gate-child" :noquery t :connection-type 'pipe :command (list "sh" "-c" command)
                :filter (lambda (_p s) (setcar said (concat (car said) s)))))

(ert-deftest drgnx-delivery-gate/a-wait-on-a-real-child-moves-no-virtual-time ()
  "The code under test waits, 0.1 s on its clock, for a real child that answers only after real time passed (onboarding's
`drgnx-onboard--wait' on a curl, say): the gate waits on the child for real, and no virtual time goes by meanwhile, so
the answer comes within the code's deadline however slow the machine.  A peer the test drives is not waited on."
  (let ((said (list nil)) (peer-said (list nil)) got now got-peer now-peer child)
    (drgnx-test-gated nil
      (drgnx-delivery-gate-test--child "sleep 0.2; echo answered" said)
      (setq got (drgnx-onboard--wait (lambda () (car said)) 0.1)
            now (drgnx-test-clock-now))
      ;; a peer (a server the test started): the wait is the gate's virtual one, which never waits for it
      (setq child (drgnx-delivery-gate-test--child "read line; echo answered" peer-said))
      (process-put child :drgnx-test-peer t)
      (setq got-peer (drgnx-onboard--wait (lambda () (car peer-said)) 0.1)
            now-peer (drgnx-test-clock-now))
      (delete-process child)
      (drgnx-test-deliver-all))
    (should (equal got "answered\n"))
    (should (= now 0))
    (should-not got-peer)
    (should (>= now-peer 0.1))))

(ert-deftest drgnx-delivery-gate/a-real-child-that-never-answers-fails-naming-it ()
  "A real child the code under test waits on says nothing and does not end: the gate fails the test after its real
bound, naming the child and the code that waits; never a timeout the code would take for an answer."
  (let* ((child nil)
         (err (unwind-protect
                  (should-error (let ((drgnx-test-gate-block-secs 0.3))
                                  (drgnx-test-gated nil
                                    (setq child (drgnx-delivery-gate-test--child "read line" (list nil)))
                                    (drgnx-onboard--wait #'ignore 0.1)))
                                :type 'ert-test-failed)
                (when (process-live-p child) (delete-process child))))
         (data (cdr (cadr err))))
    (should (string-match-p "a real child" (car (cadr err))))
    (should (equal (car (car (plist-get data :children))) "drgnx-gate-child"))
    (should (eq (plist-get data :caller) 'drgnx-onboard--wait))))

(ert-deftest drgnx-delivery-gate/a-childs-output-a-real-look-hands-over-is-in-the-transcript ()
  "A real look that hands the client a child's output records it in the transcript, (:child . NAME), among the hub
lines: that order is real time's, not the schedule's, and the transcript says so."
  (let ((said (list nil)) transcript)
    (drgnx-test-gated nil
      (drgnx-delivery-gate-test--child "sleep 0.2; echo answered" said)
      (drgnx-onboard--wait (lambda () (car said)) 0.1)
      (setq transcript (drgnx-test-gate-transcript))
      (drgnx-test-deliver-all))
    (should (equal (car said) "answered\n"))
    (should (cl-find-if (lambda (e) (and (eq (car e) :child) (string-prefix-p "drgnx-gate-child" (cdr e)))) transcript))))

(ert-deftest drgnx-delivery-gate/a-child-that-ended-before-its-output-was-read-is-still-waited-on ()
  "A child that printed and exited before Emacs read its output: Emacs sees the exit first, the output only at its next
read.  That read is still a real look, no virtual time moves, and the transcript names the child."
  (let ((said (list nil)) child now transcript)
    (drgnx-test-gated nil
      (setq child (drgnx-delivery-gate-test--child "echo answered" said))
      ;; the exit seen, the output not read: `call-process' reads no other process's output
      (while (process-live-p child) (call-process "true"))
      (should-not (car said))
      (drgnx-onboard--wait (lambda () (car said)) 0.1)
      (setq now (drgnx-test-clock-now)
            transcript (drgnx-test-gate-transcript))
      (drgnx-test-deliver-all))
    (should (equal (car said) "answered\n"))
    (should (= now 0))
    (should (cl-find-if (lambda (e) (and (eq (car e) :child) (string-prefix-p "drgnx-gate-child" (cdr e)))) transcript))))

(ert-deftest drgnx-delivery-gate/a-wait-on-a-network-client-moves-no-virtual-time ()
  "A connection the body opens to a peer server (url.el's to the mock LLM, say) is waited on like a child: a timed
wait in the code under test while it is open is a real look, so the server's answer, after real time passed, comes
within the code's deadline."
  (let* ((dir (make-temp-file "drgnx-gate-net" t)) (sock (expand-file-name "s" dir)) (said (list nil))
         ;; the server, started before the body (so never waited on): it answers each connection 0.2 s after it came
         (server (make-process
                  :name "drgnx-gate-server" :noquery t :connection-type 'pipe
                  ;; (the server's program is text: its pause is the peer's, not the test's)
                  :command (list (expand-file-name invocation-name invocation-directory) "-Q" "--batch" "--eval"
                                 (format "(progn (make-network-process :name \"s\" :server t :family 'local :service %S
                                                   :log (lambda (_s c _m) (sleep-for 0.2)
                                                          (process-send-string c \"answered\\n\")))
                                                 (send-string-to-terminal \"ready\\n\")
                                                 (while t (accept-process-output nil 1)))"
                                         sock))
                  :filter (lambda (p s) (process-put p :out (concat (process-get p :out) s)))))
         got now client)
    (unwind-protect
        (progn
          (drgnx-test-wait (lambda () (string-search "ready" (or (process-get server :out) ""))) :what "the server")
          (drgnx-test-gated nil
            (setq client (make-network-process :name "drgnx-gate-client" :family 'local :service sock :noquery t
                                               :filter (lambda (_p s) (setcar said (concat (car said) s)))))
            (setq got (drgnx-onboard--wait (lambda () (car said)) 0.1)
                  now (drgnx-test-clock-now))
            (delete-process client)
            (drgnx-test-deliver-all))
          (should (equal got "answered\n"))
          (should (= now 0)))
      (when (process-live-p server) (delete-process server))
      (delete-directory dir t))))

(ert-deftest drgnx-delivery-gate/a-deleted-connection-gets-nothing-it-held ()
  "The client deletes a connection while the gate holds its lines: its sentinel runs once, at the delete, and nothing
it held is delivered after."
  (drgnx-delivery-gate-test--with-hub
    (let ((runs 0) runs-at-delete held after-delete)
      (drgnx-test-gated '((call-1 :answer "graph/settings") (:pause "held"))
        (drgnx-hub-connect)
        (add-function :after (process-sentinel (drgnx-test-gate-conn 'sub-1)) (lambda (_p _e) (cl-incf runs)))
        (drgnx-delivery-gate-test--paused-and-held)
        (setq held (drgnx-test-gate-held 'sub-1))
        (drgnx-hub-disconnect)
        (setq runs-at-delete runs after-delete (length (drgnx-test-gate-transcript)))
        (drgnx-test-gate-continue "held")
        (drgnx-test-deliver-all)
        (should held)
        (should (= runs-at-delete 1))
        (should (= runs 1))
        (should-not (drgnx-test-gate-held 'sub-1))
        (should-not (cl-find 'sub-1 (nthcdr after-delete (drgnx-test-gate-transcript)) :key #'car))))))

;;;; Determinism

(ert-deftest drgnx-delivery-gate/the-same-schedule-gives-the-same-transcript ()
  "Twenty runs of one schedule, each against a fresh hub: the same deliveries in the same order."
  (let (shapes)
    (dotimes (_ 20)
      (drgnx-delivery-gate-test--with-hub
        (drgnx-test-gated '((sub-1 :answer "subscribe") (call-1 :answer "graph/settings"))
          (drgnx-hub-connect)
          (drgnx-test-deliver-all)
          (push (mapcar #'drgnx-delivery-gate-test--shape (drgnx-test-gate-transcript)) shapes))))
    (should (= (length shapes) 20))
    (should (cl-some (lambda (e) (and (eq (car e) 'sub-1) (eq (car-safe (cdr e)) :answer))) (car shapes)))
    (should (= 1 (length (delete-dups (copy-sequence shapes)))))))

(ert-deftest drgnx-delivery-gate/virtual-time-moves-only-when-the-test-advances ()
  "A connection's challenge held through 2.5 s of real time: its 2 s challenge timer does not fire; a virtual advance
of 2 s fires it."
  (drgnx-delivery-gate-test--with-hub
    (let (state-held now-held state-advanced now-advanced)
      (drgnx-test-gated '((:pause "held"))
        (let ((c (drgnx-hub--open nil)) (t0 (drgnx-test-real-time)))
          (drgnx-test-wait (lambda () (> (- (drgnx-test-real-time) t0) 2.5)) :what "2.5 s of real time")
          (setq state-held (process-get c :drgnx-state) now-held (drgnx-test-clock-now))
          (drgnx-test-advance 2)
          (setq state-advanced (process-get c :drgnx-state) now-advanced (drgnx-test-clock-now))
          (drgnx-test-gate-continue "held")
          (drgnx-test-deliver-all)
          (should (eq state-held 'wait))
          (should (= now-held 0))
          (should (eq state-advanced 'rejected))
          (should (= now-advanced 2)))))))

(ert-deftest drgnx-delivery-gate/deliver-all-sees-every-marker ()
  "`drgnx-test-deliver-all' returns once each connection has its barrier marker; the markers never reach the client."
  (drgnx-delivery-gate-test--with-hub
    (let (m1 m2 markers held (events nil))
      (drgnx-test-gated '((sub-1 :answer "subscribe"))
        (add-hook 'drgnx-hub-event-functions (lambda (e _d) (push e events)))
        (drgnx-hub-connect)
        (setq m1 (drgnx-test-deliver-all)
              markers (mapcar (lambda (n) (drgnx-test-gate--conn-marker (drgnx-test-gate--find n))) '(sub-1 call-1))
              m2 (drgnx-test-deliver-all)
              held (append (drgnx-test-gate-held 'sub-1) (drgnx-test-gate-held 'call-1)))
        (should (natnump m1))
        (should (> m2 m1))
        (should (equal markers (list m1 m1)))
        (should-not held)
        (should-not (member "__test_marker" events))))))

(ert-deftest drgnx-delivery-gate/chaos-leaves-gated-connections-alone ()
  "With hub chaos on (DRGNX_TEST_HUB_CHAOS), a gated body's connections get no delay advice."
  (let ((had (advice-member-p #'drgnx-test-hub-chaos--open 'drgnx-hub--open)) count filters)
    (unwind-protect
        (let ((drgnx-test-hub-chaos--seed "1") (process-environment (cons "DRGNX_TEST_HUB_CHAOS=1" process-environment)))
          (unless had (advice-add 'drgnx-hub--open :filter-return #'drgnx-test-hub-chaos--open))
          (setq count drgnx-test-hub-chaos--count)
          (drgnx-delivery-gate-test--with-hub
            (drgnx-test-gated '((sub-1 :answer "subscribe"))
              (drgnx-hub-connect)
              (drgnx-test-deliver-all)
              (setq filters (mapcar (lambda (n) (process-filter (drgnx-test-gate-conn n))) '(sub-1 call-1)))
              (should (= count drgnx-test-hub-chaos--count))
              (should (equal filters '(drgnx-test-gate--input drgnx-test-gate--input))))))
      (unless had (advice-remove 'drgnx-hub--open #'drgnx-test-hub-chaos--open)))))

;;;; Across connections: one connection's answer held past another's end

(defun drgnx-delivery-gate-test--stop-while-held (after-stop)
  "Subscribe, hold the hand-over's `gateway/editor-token' answer on call-1, stop the hub, then release AFTER-STOP (a
schedule of `(sub-1 :eof)' and `(call-1 :answer \"gateway/editor-token\")' in some order).  (TOKEN-SEEN EDITOR
TRANSCRIPT): whether the token reached `drgnx-hub-editor-token-hook', the token kept at the end, the deliveries."
  (let (seen editor transcript)
    (drgnx-delivery-gate-test--with-hub
      (drgnx-test-gated (append '((sub-1 :answer "subscribe") (:pause "stop")) after-stop)
        (add-hook 'drgnx-hub-editor-token-hook (lambda () (setq seen t)))
        (drgnx-hub-connect)
        (drgnx-test-wait (lambda () (drgnx-delivery-gate-test--answer-held-p 'call-1 :token)) :what "the token answer, held")
        (signal-process drgnx-test-ratatoskr-process 'term)
        (drgnx-test-wait (lambda () (and (memq :eof (drgnx-test-gate-held 'sub-1)) (memq :eof (drgnx-test-gate-held 'call-1))))
                         :what "both ends, held")
        (drgnx-test-gate-continue "stop")
        (drgnx-test-deliver-all)
        (setq editor drgnx-hub--editor transcript (drgnx-test-gate-transcript))))
    (list seen editor transcript)))

(ert-deftest drgnx-delivery-gate/a-held-answer-comes-after-another-connections-eof ()
  "The gate holds call-1's token answer and delivers sub-1's end first: the end forgets the subscription, and the
answer read after it is dropped (the forget race, every run).  The other order is the token, then the forget."
  (pcase-let ((`(,seen-a ,editor-a ,tr-a)
               (drgnx-delivery-gate-test--stop-while-held '((sub-1 :eof) (call-1 :answer "gateway/editor-token"))))
              (`(,seen-b ,editor-b ,tr-b)
               (drgnx-delivery-gate-test--stop-while-held '((call-1 :answer "gateway/editor-token") (sub-1 :eof)))))
    (let ((eof (lambda (e) (equal e '(sub-1 . :eof))))
          (token (lambda (e) (and (eq (car e) 'call-1) (stringp (cdr e))
                                  (let ((r (plist-get (drgnx-delivery-gate-test--json (cdr e)) :result)))
                                    (and (consp r) (plist-member r :token)))))))
      (should (< (drgnx-delivery-gate-test--position eof tr-a) (drgnx-delivery-gate-test--position token tr-a)))
      (should-not seen-a)
      (should-not editor-a)
      (should (> (drgnx-delivery-gate-test--position eof tr-b) (drgnx-delivery-gate-test--position token tr-b)))
      (should seen-b)
      (should-not editor-b))))

;;;; The swap: DRGNX_TEST_GATE_SWAP=K

(defun drgnx-delivery-gate-test--connect-run (swap)
  "Connect the client in the gate with DRGNX_TEST_GATE_SWAP=SWAP (nil: unset); (TRANSCRIPT . PAIRS), PAIRS nil unswapped."
  (let ((process-environment (if swap (cons (format "DRGNX_TEST_GATE_SWAP=%d" swap) process-environment)
                               process-environment))
        transcript pairs)
    (drgnx-delivery-gate-test--with-hub
      (drgnx-test-gated nil
        (drgnx-hub-connect)
        (drgnx-test-deliver-all)
        (setq transcript (drgnx-test-gate-transcript) pairs (drgnx-test-gate-swap-pairs))))
    (cons (mapcar #'drgnx-delivery-gate-test--shape transcript) pairs)))

(ert-deftest drgnx-delivery-gate/swap-k-swaps-one-cross-connection-pair ()
  "With K past the last pair nothing is swapped and the run counts its pairs; with K = 0 the same lines arrive with two
adjacent ones from different connections exchanged."
  (let* ((plain (drgnx-delivery-gate-test--connect-run 99999))
         (pairs (cdr plain)) (base (car plain))
         (swapped (car (drgnx-delivery-gate-test--connect-run 0)))
         (diff (cl-loop for a in base for b in swapped for i from 0 unless (equal a b) collect i)))
    (should (> pairs 0))
    (should (= (length base) (length swapped)))
    (should (equal (sort (copy-sequence (mapcar #'prin1-to-string base)) #'string<)
                   (sort (copy-sequence (mapcar #'prin1-to-string swapped)) #'string<)))
    (should (= (length diff) 2))
    (should (= (cadr diff) (1+ (car diff))))
    (should (equal (nth (car diff) base) (nth (cadr diff) swapped)))
    (should (equal (nth (cadr diff) base) (nth (car diff) swapped)))
    (should-not (eq (car (nth (car diff) base)) (car (nth (cadr diff) base))))))

(ert-deftest drgnx-delivery-gate/swap-never-reorders-one-connection ()
  "Whatever pair is swapped, each connection's lines arrive in the order they do unswapped."
  (let* ((plain (drgnx-delivery-gate-test--connect-run 99999))
         (per-conn (lambda (tr name) (seq-filter (lambda (e) (eq (car e) name)) tr))))
    (should (> (cdr plain) 0))
    (dotimes (k (cdr plain))
      (let ((swapped (car (drgnx-delivery-gate-test--connect-run k))))
        (dolist (name '(call-1 sub-1))
          (should (equal (funcall per-conn (car plain) name) (funcall per-conn swapped name))))))))

(provide 'delivery-gate-test)
;;; delivery-gate-test.el ends here
