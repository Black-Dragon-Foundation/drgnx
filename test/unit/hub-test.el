;;; hub-test.el --- batch tests: the hub process, its socket, its client, drgnx hub -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-hub)
(require 'drgnx-paths)
(require 'drgnx-timer)
(load (expand-file-name "test/fixtures/mock-llm" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)

(defmacro drgnx-hub-test--with (&rest body)
  "BODY with drgnx's dirs under ROOT (so the hub's socket is this test's own), a mock OpenRouter on OR-PORT logging
to OR-LOG, OPENROUTER_API_KEY unset."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-hub" t)))
          (or-port (+ 20000 (random 20000))) (or-log (concat root "or.log"))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" root "config") (concat "DRGNX_DATA_DIR=" root "data")
                                             (concat "XDG_STATE_HOME=" root "state") (concat "HOME=" root "home")
                                             "OPENROUTER_API_KEY" "DRGNX_JOBS_LAUNCHER=detached"
                                             "DRGNX_NO_HUB_START"                 ; these tests start hubs (and stop them)
                                             (format "DRGNX_HUB_PARENT_PID=%d" (emacs-pid)))   ; …ending with this Emacs
                                       process-environment))
          (drgnx-ai--keys (make-hash-table :test #'eq)) (auth-sources nil) (drgnx-work-db--handles nil)
          (drgnx-gateway--keys (make-hash-table :test #'eq)) (drgnx-gateway--registrations (make-hash-table :test #'equal))
          (drgnx-hub--exit-function #'drgnx-hub-stop) (mock nil))
     (unwind-protect
         (progn
           (make-directory (concat root "config") t) (make-directory (concat root "home") t)
           (with-temp-file (concat root "or.eld")
             (prin1 '((:path "/api/v1/messages" :body "{\"usage\":{\"input_tokens\":3,\"output_tokens\":4}}")) (current-buffer)))
           (with-temp-file (concat root "config/ai.eld")
             (prin1 `(:version 1 :providers ((openrouter :name "OR" :kind openai :url ,(format "http://127.0.0.1:%d/api/v1" or-port)
                                                         :key-env "OPENROUTER_API_KEY" :caps (chat) :messages t)))
                    (current-buffer)))
           (setq mock (drgnx-ai-test-mock-llm or-port (concat root "or.eld") or-log))
           ,@body)
       (ignore-errors (drgnx-hub-call-sync "shutdown" nil 2))
       (drgnx-hub-stop)
       (drgnx-hub-disconnect)
       (when mock (delete-process mock))
       (drgnx-work-db-close-all)
       (ignore-errors (delete-file (drgnx-hub-socket)))
       (ignore-errors (delete-directory (concat (drgnx-hub-socket) ".lock") t))
       ;; a hub started as a job: its wrapper writes the exit code just after the hub ends — before the tree goes
       (drgnx-hub-test--wait (lambda () (not (seq-some (lambda (j) (eq (plist-get j :status) 'running)) (drgnx-jobs-list)))) 5)
       (delete-directory root t))))

(defun drgnx-hub-test--post (url token)
  "POST a small request to the gateway at URL with TOKEN; the status.  Asynchronous: the gateway may be this Emacs."
  (let* ((out (generate-new-buffer " *post*" t))
         (p (make-process :name "post" :buffer out :noquery t
                          :command (list "curl" "-s" "--max-time" "10" "-o" "/dev/null" "-w" "%{http_code}"
                                         "-H" (concat "Authorization: Bearer " token) "-H" "Content-Type: application/json"
                                         "--data" "{\"model\":\"x\"}" (concat url "/v1/messages")))))
    (drgnx-hub-test--wait (lambda () (not (process-live-p p))) 12)
    (prog1 (string-to-number (with-current-buffer out (buffer-string))) (kill-buffer out))))

(defun drgnx-hub-test--wait (pred &optional secs)
  (let ((deadline (+ (float-time) (or secs 5)))) (while (and (not (funcall pred)) (< (float-time) deadline)) (accept-process-output nil 0.02)))
  (funcall pred))

(ert-deftest drgnx-hub/ping-status-and-register-over-the-socket ()
  (drgnx-hub-test--with
    (drgnx-hub-serve (drgnx-hub-socket))
    (should (= (plist-get (drgnx-hub-call-sync "ping" nil) :pid) (emacs-pid)))
    (let ((r (drgnx-hub-call-sync "gateway/register" '(:job "j" :task "t" :agent "a" :chain [["openrouter" "m"]]))))
      (should (string-match-p "\\`[0-9a-f]\\{64\\}\\'" (plist-get r :token)))
      (should (string-match-p "\\`http://127\\.0\\.0\\.1:[0-9]+\\'" (plist-get r :url))))
    (let ((s (drgnx-hub-call-sync "status" nil)))
      (should (= (plist-get s :registrations) 1))
      (should (integerp (plist-get s :gateway_port))))
    (should (equal (file-modes (file-name-directory (drgnx-hub-socket))) #o700))))

(ert-deftest drgnx-hub/a-stopped-hub-s-shutdown-never-reaches-the-next-one ()
  ;; shutdown exits 0.1 s later: a hub stopped meanwhile (a test's cleanup) must not take the next hub down with it
  (drgnx-hub-test--with
    (drgnx-hub-serve (drgnx-hub-socket))
    (drgnx-hub-call-sync "shutdown" nil)
    (drgnx-hub-stop)
    (drgnx-hub-disconnect)
    (drgnx-hub-serve (drgnx-hub-socket))
    (drgnx-hub-call-sync "gateway/register" '(:chain [["openrouter" nil]]))
    (drgnx-hub-test--wait #'ignore 0.4)
    (should (drgnx-hub-serving-p))
    (should (= (plist-get (drgnx-hub-call-sync "status" nil) :registrations) 1))))

(ert-deftest drgnx-hub/subscribers-hear-gateway-events ()
  (drgnx-hub-test--with
    (drgnx-hub-serve (drgnx-hub-socket))
    (let* ((heard nil) (drgnx-hub-event-functions (list (lambda (e d) (push (cons e d) heard))))
           (r (drgnx-hub-call-sync "gateway/register" (list :agent "a1" :chain [["openrouter" nil]] :keys '(:openrouter "sk-k")))))
      (drgnx-hub-connect)
      (drgnx-hub-test--wait (lambda () drgnx-hub--events))
      ;; the request from another process (curl), so this Emacs serves the gateway meanwhile
      (let ((p (start-process "post" nil "curl" "-s" "-H" (concat "Authorization: Bearer " (plist-get r :token))
                              "--data" "{}" (concat (plist-get r :url) "/v1/messages"))))
        (drgnx-hub-test--wait (lambda () (assoc "request" heard)) 8)
        (ignore-errors (delete-process p)))
      (should (equal (plist-get (cdr (assoc "request" heard)) :agent) "a1")))))

(ert-deftest drgnx-hub/connect-twice-subscribes-once ()
  ;; a second call before the hub's answer is a no-op: one subscription, not two
  (drgnx-hub-test--with
    (drgnx-hub-serve (drgnx-hub-socket))
    (drgnx-hub-connect)
    (drgnx-hub-connect)
    (should (drgnx-hub-test--wait (lambda () (process-live-p drgnx-hub--events))))
    (drgnx-hub-test--wait #'ignore 0.3)
    (should (= (length drgnx-hub--subscribers) 1))))

(ert-deftest drgnx-hub/kept-files-are-synced-before-the-rename ()
  ;; a rename is atomic against a crash of the hub, not of the machine: the new file's data must be on disk before
  ;; it replaces the old one (Emacs skips fsync by default: `write-region-inhibit-fsync')
  (drgnx-hub-test--with
    (let ((synced nil) (write (symbol-function 'write-region)))
      (cl-letf (((symbol-function 'write-region)
                 (lambda (start end file &rest args)
                   (when (string-match-p "registrations\\.eld-" file) (push (not write-region-inhibit-fsync) synced))
                   (apply write start end file args))))
        (drgnx-hub--save-registrations))
      (should (equal synced '(t))))))

(ert-deftest drgnx-hub/a-subscribe-never-answered-stops-blocking-connect ()
  ;; one subscription while the hub has not answered — but not forever: a subscribe left unanswered (a stopped hub)
  ;; past the deadline is given up, and the next connect tries again (the editor is not told the hub went away).
  ;; It counts accepted connections: it relies on this Emacs holding no keys (the macro's), else each connect's
  ;; `drgnx-hub--send-keys' would open one more
  (drgnx-hub-test--with
    (should-not (drgnx-hub--held-keys))
    (drgnx-hub--private-dir (file-name-directory (drgnx-hub-socket)))
    (let* ((accepted 0) (gone 0)
           (drgnx-hub-disconnect-functions (list (lambda () (cl-incf gone))))
           (server (make-network-process :name "mute-hub" :family 'local :server t :service (drgnx-hub-socket) :noquery t
                                         :filter #'ignore :log (lambda (&rest _) (cl-incf accepted)))))
      (unwind-protect
          (let ((drgnx-hub-subscribe-deadline 0.3))
            (drgnx-hub-connect)
            (should (drgnx-hub-test--wait (lambda () (= accepted 1)) 2))
            (drgnx-hub-connect)                                   ; before the deadline: still the one
            (drgnx-hub-test--wait #'ignore 0.1)
            (should (= accepted 1))
            (drgnx-hub-test--wait #'ignore 0.4)
            (drgnx-hub-connect)                                   ; past it: a new one
            (should (drgnx-hub-test--wait (lambda () (= accepted 2)) 2))
            (should (= gone 0)))
        (delete-process server)))))

(ert-deftest drgnx-hub/a-subscriber-that-stops-reading-is-dropped ()
  ;; a blocked write runs timers and filters meanwhile: each new event would write to the same stuck subscriber one
  ;; level deeper (until excessive-lisp-nesting lands anywhere in the hub); it is dropped instead, and the hub serves
  (drgnx-hub-test--with
    (drgnx-hub-serve (drgnx-hub-socket))
    (let* ((sub (make-process
                 :name "stuck-sub" :noquery t :buffer nil
                 :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q" "--eval"
                                (format "(let ((c (make-network-process :name \"s\" :family 'local :service %S :filter #'ignore)))
                                           (process-send-string c \"{\\\"id\\\":0,\\\"method\\\":\\\"subscribe\\\"}\\n\")
                                           (while t (accept-process-output nil 1)))"
                                        (drgnx-hub-socket)))))
           (blob (make-string (* 64 1024) ?x))
           (drgnx-hub-client-max-queued (* 512 1024))              ; (16 MiB by default: 1.3 MiB go out here)
           (ticker nil) (rescue nil) (nested nil))
      (unwind-protect
          (progn
            (should (drgnx-hub-test--wait (lambda () drgnx-hub--subscribers) 10))
            (signal-process sub 'SIGSTOP)                                   ; it reads nothing more
            ;; without the drop, the innermost write would wait for it forever: let it go after 4 s (the test then fails)
            (setq rescue (run-at-time 4 nil (lambda () (signal-process sub 'SIGCONT))))
            (setq ticker (run-at-time 0 0.05 (lambda () (run-at-time 0 nil (lambda ()
                                                                             (condition-case err (drgnx-hub--broadcast 'test (list :blob blob))
                                                                               (excessive-lisp-nesting (setq nested err))))))))
            (drgnx-hub-test--wait #'ignore 1)
            (cancel-timer ticker)
            (should (drgnx-hub-call-sync "ping" nil))
            (should-not (seq-filter #'process-live-p drgnx-hub--subscribers))
            (should-not nested))
        (when (timerp ticker) (cancel-timer ticker))
        (when (timerp rescue) (cancel-timer rescue))
        (ignore-errors (signal-process sub 'SIGCONT))
        (delete-process sub)))))

(ert-deftest drgnx-hub/a-stopped-subscriber-is-dropped-when-nothing-more-comes ()
  ;; one write that makes no progress for `drgnx-hub-client-stuck-after' ends its client on the hub's tick
  (drgnx-hub-test--with
    (drgnx-hub-serve (drgnx-hub-socket))
    (let* ((sub (make-process
                 :name "stuck-sub" :noquery t :buffer nil
                 :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q" "--eval"
                                (format "(let ((c (make-network-process :name \"s\" :family 'local :service %S :filter #'ignore)))
                                           (process-send-string c \"{\\\"id\\\":0,\\\"method\\\":\\\"subscribe\\\"}\\n\")
                                           (while t (accept-process-output nil 1)))"
                                        (drgnx-hub-socket)))))
           (drgnx-hub-client-stuck-after 0.5) (rescue nil))
      (unwind-protect
          (progn
            (should (drgnx-hub-test--wait (lambda () drgnx-hub--subscribers) 10))
            (signal-process sub 'SIGSTOP)
            (setq rescue (run-at-time 8 nil (lambda () (signal-process sub 'SIGCONT))))
            (run-at-time 0 nil (lambda () (drgnx-hub--broadcast 'test (list :blob (make-string (* 4 1024 1024) ?x)))))
            (should (drgnx-hub-test--wait (lambda () (not (seq-filter #'process-live-p drgnx-hub--subscribers))) 5))
            (should (drgnx-hub-call-sync "ping" nil)))
        (when (timerp rescue) (cancel-timer rescue))
        (ignore-errors (signal-process sub 'SIGCONT))
        (delete-process sub)))))

(defun drgnx-hub-test--reader (out delay)
  "A subscriber in a child Emacs that sleeps DELAY s per chunk it reads, and on a `done' event writes all it got to
OUT and exits."
  (make-process
   :name "reader" :noquery t :buffer nil
   :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q" "--eval"
                  (format "(let* ((got nil) (tail \"\") (done nil)
                                  (c (make-network-process :name \"s\" :family 'local :service %S :coding 'binary
                                       :filter (lambda (_p s) (push s got) (sleep-for %s)
                                                 (when (string-search \"\\\"done\\\"\" (concat tail s)) (setq done t))
                                                 (setq tail (substring (concat tail s) (max 0 (- (+ (length tail) (length s)) 32))))))))
                             (process-send-string c \"{\\\"id\\\":0,\\\"method\\\":\\\"subscribe\\\"}\\n\")
                             (while (not done) (accept-process-output nil 0.1))
                             (let ((coding-system-for-write 'binary)) (write-region (apply #'concat (nreverse got)) nil %S))
                             (kill-emacs 0))"
                          (drgnx-hub-socket) delay out))))

(defun drgnx-hub-test--blob (mib char)
  "MIB mebibytes of CHAR to send a client — an eighth of that on macOS.  A hub write that fills the client's socket
waits 20 ms (Emacs's send_process) before it tries again: Linux's local sockets hold ~200 KB, macOS's 8 KB, so the
hub writes ~25 times slower there (~400 KB/s).  An eighth is still many socket-fulls (the waits these tests are
about) and keeps the tests within their time limits."
  (make-string (round (* mib 1024 1024 (if (eq system-type 'darwin) 0.125 1))) char))

(defun drgnx-hub-test--got (out)
  "The `test' events' numbers in what a reader wrote to OUT, in the order it got them."
  (with-temp-buffer
    (insert-file-contents out)
    (cl-loop for line in (split-string (buffer-string) "\n" t)
             for json = (json-parse-string line :object-type 'plist)
             when (equal (plist-get json :event) "test") collect (plist-get (plist-get json :data) :n))))

(ert-deftest drgnx-hub/every-subscriber-gets-events-in-order-beside-a-slow-one ()
  ;; while a write to a slow subscriber waits, a newer event must not reach another subscriber before an older one
  ;; (a mirror skips what is older than what it has: it would lose it)
  (drgnx-hub-test--with
    (drgnx-hub-serve (drgnx-hub-socket))
    (let* ((fast-out (concat root "fast.txt")) (slow-out (concat root "slow.txt"))
           (fast (drgnx-hub-test--reader fast-out 0)) (slow nil)
           (big (drgnx-hub-test--blob 1 ?b)) (small (make-string 200 ?s)) (n 0) (timers nil)
           ;; nothing after STOP, whoever has control then: on macOS the hub writes hardly faster than these timers
           ;; make events (~400 KB/s), its drain goes on while new ones come, and the test's own 2 s would never end
           ;; (the queue grew for 200 s, to its 16 MiB limit)
           (stop 0)
           (send (lambda (blob) (run-at-time 0 nil (lambda () (when (< (float-time) stop)
                                                                (drgnx-hub--broadcast 'test (list :n (cl-incf n) :blob blob))))))))
      (unwind-protect
          (progn
            (should (drgnx-hub-test--wait (lambda () (= (length drgnx-hub--subscribers) 1)) 10))
            (setq slow (drgnx-hub-test--reader slow-out 0.002))           ; subscribed second: written to first
            (should (drgnx-hub-test--wait (lambda () (= (length drgnx-hub--subscribers) 2)) 10))
            (setq stop (+ (float-time) 2))
            (push (run-at-time 0 0.05 (lambda () (funcall send small))) timers)
            (push (run-at-time 0 0.5 (lambda () (funcall send big))) timers)
            (drgnx-hub-test--wait #'ignore 2)
            (mapc #'cancel-timer timers)
            (drgnx-hub-test--wait #'ignore 0.1)
            (drgnx-hub--broadcast 'done nil)
            (should (drgnx-hub-test--wait (lambda () (not (or (process-live-p fast) (process-live-p slow)))) 30))
            (should (> n 20))
            (should (equal (drgnx-hub-test--got slow-out) (number-sequence 1 n)))
            (should (equal (drgnx-hub-test--got fast-out) (number-sequence 1 n))))
        (mapc #'cancel-timer timers)
        (delete-process fast)
        (when slow (delete-process slow))))))

(ert-deftest drgnx-hub/a-client-beneath-a-stopped-one-is-kept ()
  ;; a write to a stopped client B blocks on top of one to a live client A: A's write cannot go on meanwhile, so only
  ;; the innermost write (B's) is judged; B goes, A stays and gets all of it
  (drgnx-hub-test--with
    (drgnx-hub-serve (drgnx-hub-socket))
    (let* ((out (concat root "a.txt")) (a-proc (drgnx-hub-test--reader out 0.001)) (b-proc nil) (a nil) (b nil)
           (drgnx-hub-client-stuck-after 1) (rescue nil))
      (unwind-protect
          (progn
            (should (drgnx-hub-test--wait (lambda () (= (length drgnx-hub--subscribers) 1)) 10))
            (setq a (car drgnx-hub--subscribers))
            (setq b-proc (make-process
                          :name "stuck-sub" :noquery t :buffer nil
                          :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q" "--eval"
                                         (format "(let ((c (make-network-process :name \"s\" :family 'local :service %S :filter #'ignore)))
                                                    (process-send-string c \"{\\\"id\\\":0,\\\"method\\\":\\\"subscribe\\\"}\\n\")
                                                    (while t (accept-process-output nil 1)))"
                                                 (drgnx-hub-socket)))))
            (should (drgnx-hub-test--wait (lambda () (= (length drgnx-hub--subscribers) 2)) 10))
            (setq b (car drgnx-hub--subscribers))
            (signal-process b-proc 'SIGSTOP)
            (setq rescue (run-at-time 9 nil (lambda () (signal-process b-proc 'SIGCONT))))
            (run-at-time 0 nil (lambda () (drgnx-hub--answer a (list :event "test" :data (list :n 1 :blob (drgnx-hub-test--blob 4 ?a))))))
            (run-at-time 0.2 nil (lambda () (drgnx-hub--answer b (list :event "test" :data (list :n 1 :blob (drgnx-hub-test--blob 4 ?b))))))
            (should (drgnx-hub-test--wait (lambda () (not (process-live-p b))) 6))
            (should (process-live-p a))
            (drgnx-hub--answer a '(:event "done" :data nil))
            (should (drgnx-hub-test--wait (lambda () (not (process-live-p a-proc))) 20))
            (should (equal (drgnx-hub-test--got out) '(1))))
        (when (timerp rescue) (cancel-timer rescue))
        (when b-proc (ignore-errors (signal-process b-proc 'SIGCONT)) (delete-process b-proc))
        (delete-process a-proc)))))

(ert-deftest drgnx-hub/a-stopped-subscriber-is-dropped-while-others-get-traffic ()
  ;; writes to a live subscriber on top of a stopped one's blocked write give the stopped one back only the time they
  ;; took: it is still dropped within about `drgnx-hub-client-stuck-after', the live one never
  (drgnx-hub-test--with
    (drgnx-hub-serve (drgnx-hub-socket))
    (let* ((out (concat root "live.txt")) (live-proc (drgnx-hub-test--reader out 0)) (stopped-proc nil) (live nil) (stopped nil)
           (drgnx-hub-client-stuck-after 1) (rescue nil) (ticker nil) (n 0))
      (unwind-protect
          (progn
            (should (drgnx-hub-test--wait (lambda () (= (length drgnx-hub--subscribers) 1)) 10))
            (setq live (car drgnx-hub--subscribers))
            (setq stopped-proc (make-process
                                :name "stuck-sub" :noquery t :buffer nil
                                :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q" "--eval"
                                               (format "(let ((c (make-network-process :name \"s\" :family 'local :service %S :filter #'ignore)))
                                                          (process-send-string c \"{\\\"id\\\":0,\\\"method\\\":\\\"subscribe\\\"}\\n\")
                                                          (while t (accept-process-output nil 1)))"
                                                       (drgnx-hub-socket)))))
            (should (drgnx-hub-test--wait (lambda () (= (length drgnx-hub--subscribers) 2)) 10))
            (setq stopped (car drgnx-hub--subscribers))
            (signal-process stopped-proc 'SIGSTOP)
            (setq rescue (run-at-time 12 nil (lambda () (signal-process stopped-proc 'SIGCONT))))
            (run-at-time 0 nil (lambda () (drgnx-hub--answer stopped (list :event "big" :data (list :blob (drgnx-hub-test--blob 4 ?b))))))
            (setq ticker (run-at-time 0.1 0.1 (lambda () (run-at-time 0 nil (lambda () (drgnx-hub--broadcast 'test (list :n (cl-incf n))))))))
            (should (drgnx-hub-test--wait (lambda () (not (process-live-p stopped))) 4))
            (cancel-timer ticker)
            ;; a broadcast the ticker queued just before is still to come: after it, `done' (else it follows `done',
            ;; which the reader does not wait past)
            (drgnx-hub-test--wait #'ignore 0.1)
            (should (process-live-p live))
            (drgnx-hub--broadcast 'done nil)
            (should (drgnx-hub-test--wait (lambda () (not (process-live-p live-proc))) 20))
            (should (> n 5))
            (should (equal (drgnx-hub-test--got out) (number-sequence 1 n))))
        (when (timerp ticker) (cancel-timer ticker))
        (when (timerp rescue) (cancel-timer rescue))
        (when stopped-proc (ignore-errors (signal-process stopped-proc 'SIGCONT)) (delete-process stopped-proc))
        (delete-process live-proc)))))

(ert-deftest drgnx-hub/a-queue-past-its-limit-is-dropped-beneath-other-writes ()
  ;; a stopped client X whose write waits beneath a live, slow client Y's (which can go on for long: it makes
  ;; progress) is not judged by time, but its queue is held to `drgnx-hub-client-max-queued' wherever it is; Y's
  ;; old write, innermost, is judged by time
  (let* ((x (make-pipe-process :name "hub-x" :noquery t)) (y (make-pipe-process :name "hub-y" :noquery t))
         (drgnx-hub-client-max-queued 1000) (drgnx-hub-client-stuck-after 10) (inhibit-message t))
    (unwind-protect
        (let ((drgnx-hub--writing (list y x)))
          (process-put x :sending (- (float-time) 60))                          ; beneath: its time is not judged
          (process-put y :sending (float-time))
          (drgnx-hub--enqueue x (make-string 600 ?a))
          (should (process-live-p x))
          (drgnx-hub--enqueue x (make-string 600 ?a))                              ; 1200 bytes: past the limit
          (should-not (process-live-p x))
          (should (process-live-p y))
          (process-put y :sending (- (float-time) 11))                          ; innermost: judged by time
          (drgnx-hub--enqueue y "z")
          (should-not (process-live-p y)))
      (delete-process x)
      (delete-process y))))

(ert-deftest drgnx-hub/a-live-reader-is-kept-through-a-long-line ()
  ;; One line can take long to go out to a client that reads, slowly: on macOS a local socket holds 8 KB and Emacs
  ;; waits 20 ms each time a write fills it, so a snapshot of a few MB takes seconds there.  Only a write that makes
  ;; no progress for `drgnx-hub-client-stuck-after' is stuck: the line goes out a piece at a time, each one progress.
  (drgnx-hub-test--with
    (drgnx-hub-serve (drgnx-hub-socket))
    (let* ((out (concat root "got.txt")) (reader (drgnx-hub-test--reader out 0.05)) (conn nil) (judge nil)
           (drgnx-hub-client-stuck-after 0.3))
      (unwind-protect
          (progn
            (should (drgnx-hub-test--wait (lambda () drgnx-hub--subscribers) 10))
            (setq conn (car drgnx-hub--subscribers))
            (setq judge (run-at-time 0.05 0.05 #'drgnx-hub--drop-stuck))          ; as the hub's tick does, more often
            (drgnx-hub--broadcast 'test (list :n 1 :blob (drgnx-hub-test--blob 4 ?l)))
            (cancel-timer judge)
            (should (process-live-p conn))
            (drgnx-hub--broadcast 'done nil)
            (should (drgnx-hub-test--wait (lambda () (not (process-live-p reader))) 30))
            (should (equal (drgnx-hub-test--got out) '(1))))
        (when (timerp judge) (cancel-timer judge))
        (delete-process reader)))))

(ert-deftest drgnx-hub/a-slow-subscriber-is-kept-and-gets-everything-in-order ()
  ;; a live reader that is merely slow (big snapshots, a busy editor) makes writes wait: what comes meanwhile is
  ;; queued for it, never a reason to drop it
  (drgnx-hub-test--with
    (drgnx-hub-serve (drgnx-hub-socket))
    (let* ((out (concat root "got.txt"))
           (sub (make-process
                 :name "slow-sub" :noquery t :buffer nil
                 :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q" "--eval"
                                (format "(let* ((got nil) (tail \"\") (done nil)
                                                (c (make-network-process :name \"s\" :family 'local :service %S :coding 'binary
                                                     :filter (lambda (_p s) (push s got) (sleep-for 0.002)
                                                               (when (string-search \"\\\"done\\\"\" (concat tail s)) (setq done t))
                                                               (setq tail (substring (concat tail s) (max 0 (- (+ (length tail) (length s)) 32))))))))
                                           (process-send-string c \"{\\\"id\\\":0,\\\"method\\\":\\\"subscribe\\\"}\\n\")
                                           (while (not done) (accept-process-output nil 0.1))
                                           (let ((coding-system-for-write 'binary)) (write-region (apply #'concat (nreverse got)) nil %S))
                                           (kill-emacs 0))"
                                        (drgnx-hub-socket) out))))
           (big (drgnx-hub-test--blob 1 ?b)) (small (make-string 200 ?s)) (n 0) (timers nil)
           ;; nothing after STOP, whoever has control then: on macOS the hub writes hardly faster than these timers
           ;; make events (~400 KB/s), its drain goes on while new ones come, and the test's own 2 s would never end
           ;; (the queue grew for 200 s, to its 16 MiB limit)
           (stop 0)
           (send (lambda (blob) (run-at-time 0 nil (lambda () (when (< (float-time) stop)
                                                                (drgnx-hub--broadcast 'test (list :n (cl-incf n) :blob blob))))))))
      (unwind-protect
          (progn
            (should (drgnx-hub-test--wait (lambda () drgnx-hub--subscribers) 10))
            (let ((conn (car drgnx-hub--subscribers)))
              (setq stop (+ (float-time) 2))
              (push (run-at-time 0 0.05 (lambda () (funcall send small))) timers)
              (push (run-at-time 0 0.5 (lambda () (funcall send big))) timers)
              (drgnx-hub-test--wait #'ignore 2)
              (mapc #'cancel-timer timers)
              (drgnx-hub-test--wait #'ignore 0.1)
              (should (process-live-p conn))
              (should (memq conn drgnx-hub--subscribers))
              (drgnx-hub--broadcast 'done nil)
              (should (drgnx-hub-test--wait (lambda () (not (process-live-p sub))) 30))
              (let ((ns (with-temp-buffer
                          (insert-file-contents out)
                          (cl-loop for line in (split-string (buffer-string) "\n" t)
                                   for json = (json-parse-string line :object-type 'plist)
                                   when (equal (plist-get json :event) "test")
                                   collect (plist-get (plist-get json :data) :n)))))
                (should (> n 20))
                (should (equal ns (number-sequence 1 n))))))
        (mapc #'cancel-timer timers)
        (delete-process sub)))))

(ert-deftest drgnx-hub/a-restarted-hub-takes-the-same-tokens ()
  (drgnx-hub-test--with
    (drgnx-hub-serve (drgnx-hub-socket))
    (let ((token (plist-get (drgnx-hub-call-sync "gateway/register" '(:chain [["openrouter" nil]])) :token))
          (file (expand-file-name "hub/registrations.eld" (drgnx-state-dir))))
      (drgnx-hub-disconnect)
      (drgnx-hub-stop)
      (should (= (hash-table-count drgnx-gateway--registrations) 0))
      (should (file-exists-p file))
      (should (equal (file-modes file) #o600))
      (let ((text (with-temp-buffer (insert-file-contents file) (buffer-string))))
        (should-not (string-search token text))
        (should (string-search (secure-hash 'sha256 token) text)))
      (drgnx-hub-serve (drgnx-hub-socket))
      (should (= (hash-table-count drgnx-gateway--registrations) 1))
      (should (gethash (secure-hash 'sha256 token) drgnx-gateway--registrations)))))

(ert-deftest drgnx-hub/registrations-survive-a-torn-write ()
  ;; a file cut off mid-write (the old in-place write, a full disk) is logged and the hub serves; a save writes a
  ;; temporary file and renames it over the old one (a new inode), leaves no temporary file, and is 0600
  (drgnx-hub-test--with
    (let ((file (expand-file-name "hub/registrations.eld" (drgnx-state-dir))) (logged nil))
      (make-directory (file-name-directory file) t)
      (write-region "((\"abc\" :job \"j\" :chain" nil file nil 'silent)
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (when fmt (push (apply #'format-message fmt args) logged)) nil)))
        (drgnx-hub-serve (drgnx-hub-socket)))
      (should (seq-some (lambda (m) (string-search "registrations.eld" m)) logged))
      (should (drgnx-hub-call-sync "ping" nil))
      (drgnx-hub-call-sync "gateway/register" '(:chain [["openrouter" nil]]))
      (let ((inode (file-attribute-inode-number (file-attributes file))))
        (drgnx-hub-call-sync "gateway/register" '(:chain [["openrouter" nil]]))
        (should-not (equal (file-attribute-inode-number (file-attributes file)) inode)))
      (should (equal (directory-files (file-name-directory file) nil "regist") '("registrations.eld")))
      (should (equal (file-modes file) #o600))
      (should (= (length (with-temp-buffer (insert-file-contents file) (read (current-buffer)))) 2)))))

(ert-deftest drgnx-hub/registrations-of-a-dead-owner-are-pruned ()
  ;; a crashed editor never unregisters its agents' tokens: a registration names its owner's pid, and one whose owner
  ;; is gone is dropped when a hub starts and on its tick; one without an owner stays until it is unregistered
  (drgnx-hub-test--with
    (let* ((gone (let ((p (start-process "gone" nil "true")))
                   (drgnx-hub-test--wait (lambda () (not (process-live-p p))))
                   (process-id p)))
           (reg (lambda (owner) (plist-get (drgnx-hub-call-sync "gateway/register" (list :chain [["openrouter" nil]] :owner owner))
                                           :token)))
           (has (lambda (token) (gethash (secure-hash 'sha256 token) drgnx-gateway--registrations)))
           (file (expand-file-name "hub/registrations.eld" (drgnx-state-dir))))
      (drgnx-hub-serve (drgnx-hub-socket))
      (let ((dead (funcall reg gone)) (live (funcall reg (emacs-pid)))
            (none (plist-get (drgnx-hub-call-sync "gateway/register" '(:chain [["openrouter" nil]])) :token)))
        (should (eql (plist-get (funcall has live) :owner) (emacs-pid)))
        (drgnx-hub-disconnect)
        (drgnx-hub-stop)
        (drgnx-hub-serve (drgnx-hub-socket))                     ; at start
        (should-not (funcall has dead))
        (should (funcall has live))
        (should (funcall has none))
        (let ((dead2 (funcall reg gone)))
          (should (funcall has dead2))
          (should (drgnx-hub-test--wait (lambda () (not (funcall has dead2))) 5))   ; on a tick (every 2 s)
          (should (funcall has live))
          (should-not (string-search (secure-hash 'sha256 dead2) (with-temp-buffer (insert-file-contents file) (buffer-string)))))))))

(ert-deftest drgnx-hub/odd-kept-registrations-never-stop-the-hub ()
  ;; registrations kept before owners were (none), or with an owner that is not a pid, stay — on a tick too — and
  ;; the hub starts; a file that is not an alist is logged and the hub starts
  (drgnx-hub-test--with
    (let ((file (expand-file-name "hub/registrations.eld" (drgnx-state-dir))))
      (make-directory (file-name-directory file) t)
      (with-temp-file file (prin1 '(("h-none" :job "j" :chain ((openrouter))) ("h-junk" :owner "x" :chain ((openrouter)))) (current-buffer)))
      (drgnx-hub-serve (drgnx-hub-socket))
      (should (drgnx-hub-call-sync "ping" nil))
      (drgnx-hub-test--wait #'ignore 2.5)                         ; a tick
      (should (gethash "h-none" drgnx-gateway--registrations))
      (should (gethash "h-junk" drgnx-gateway--registrations))
      (drgnx-hub-disconnect) (drgnx-hub-stop)
      (with-temp-file file (insert "((\"h\" :chain nil) . 3)"))
      (drgnx-hub-serve (drgnx-hub-socket))
      (should (drgnx-hub-call-sync "ping" nil)))))

(ert-deftest drgnx-hub/a-second-hub-exits ()
  (drgnx-hub-test--with
    (drgnx-hub-serve (drgnx-hub-socket))
    (let* ((out (generate-new-buffer " *hub2*" t))
           (p (make-process :name "hub2" :buffer out :noquery t
                            :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                           "-L" (expand-file-name "core" drgnx-dir) "-l" "drgnx-hub" "-f" "drgnx-hub-main"))))
      (drgnx-hub-test--wait (lambda () (not (process-live-p p))) 15)
      (should (eq (process-status p) 'exit))
      (should (= (process-exit-status p) 3))
      (should (string-search "a hub already serves" (with-current-buffer out (buffer-string))))
      (kill-buffer out)))
  ;; a socket file nobody listens on is taken over
  (drgnx-hub-test--with
    (make-directory (file-name-directory (drgnx-hub-socket)) t)
    (write-region "" nil (drgnx-hub-socket) nil 'silent)
    (drgnx-hub-serve (drgnx-hub-socket))
    (should (drgnx-hub-call-sync "ping" nil))))

(ert-deftest drgnx-hub/startup-error-exit-code ()
  ;; 3 says "a hub already serves" (a-second-hub-exits); any other reason a hub cannot start is 1
  (drgnx-hub-test--with
    (let ((state (concat root "state-file")))
      (write-region "" nil state nil 'silent)         ; a state dir that is a plain file: no socket dir under it
      (let* ((process-environment (append (list "XDG_RUNTIME_DIR" (concat "XDG_STATE_HOME=" state)) process-environment))
             (out (generate-new-buffer " *hub-err*" t))
             ;; never waited for without a limit: a hub that starts after all would serve until this Emacs ends
             (p (make-process :name "hub-err" :buffer out :noquery t
                              :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                             "-L" (expand-file-name "core" drgnx-dir) "-l" "drgnx-hub" "-f" "drgnx-hub-main"))))
        (unless (drgnx-hub-test--wait (lambda () (not (process-live-p p))) 20) (delete-process p))
        (should (eq (process-status p) 'exit))
        (should (= (process-exit-status p) 1))
        (should (string-search "drgnx hub: " (with-current-buffer out (buffer-string))))
        (kill-buffer out)))))

(ert-deftest drgnx-hub/a-test-hub-exits-with-its-parent ()
  ;; DRGNX_HUB_PARENT_PID (tests only): a hub whose test Emacs is gone stops instead of outliving the test's dir
  (drgnx-hub-test--with
    (let* ((gone (let ((p (start-process "gone" nil "true")))
                   (drgnx-hub-test--wait (lambda () (not (process-live-p p))))
                   (process-id p)))
           (process-environment (cons (format "DRGNX_HUB_PARENT_PID=%d" gone) process-environment))
           (p (make-process :name "orphan-hub" :noquery t
                            :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                           "-L" (expand-file-name "core" drgnx-dir) "-l" "drgnx-hub" "-f" "drgnx-hub-main"))))
      (unwind-protect
          (progn
            (should (drgnx-hub-test--wait (lambda () (not (process-live-p p))) 10))
            (should (eql (process-exit-status p) 0))
            (should-not (file-exists-p (drgnx-hub-socket))))
        (ignore-errors (delete-process p))))))

(ert-deftest drgnx-hub/the-hub-outlives-the-emacs-that-started-it ()
  (drgnx-hub-test--with
    (let ((rc (call-process (expand-file-name invocation-name invocation-directory) nil nil nil "--batch" "-Q"
                            "-L" (expand-file-name "core" drgnx-dir) "-l" "drgnx-hub"
                            "--eval" "(kill-emacs (if (drgnx-hub-ensure) 0 1))")))
      (should (= rc 0)))
    (should (drgnx-hub-running-p))                    ; the starter is gone; the hub serves
    (let* ((pid (plist-get (drgnx-hub-call-sync "status" nil) :pid))
           (cmdline (or (alist-get 'args (process-attributes pid))           ; no /proc on macOS
                        (shell-command-to-string (format "ps -ww -o command= -p %d" pid)))))
      (should (/= pid (emacs-pid)))
      (should (string-search "drgnx-hub-main" cmdline))
      ;; keys sent over the socket: in the hub's memory only
      (let ((r (drgnx-hub-call-sync "gateway/register" (list :chain [["openrouter" nil]] :keys '(:openrouter "sk-sock-only")))))
        (should (= (drgnx-hub-test--post (plist-get r :url) (plist-get r :token)) 200))
        (should (string-search "Bearer sk-sock-only" (with-temp-buffer (insert-file-contents or-log) (buffer-string)))))
      (should-not (string-search "sk-sock" cmdline))
      (dolist (f (directory-files-recursively root "" nil))
        (unless (or (equal (file-name-nondirectory f) "or.log") (not (file-regular-p f)))   ; the socket, without XDG_RUNTIME_DIR
          (should-not (string-search "sk-sock-only" (with-temp-buffer (set-buffer-multibyte nil) (insert-file-contents-literally f) (buffer-string))))))
      (drgnx-hub-call-sync "shutdown" nil)
      ;; judged by its socket: where PID 1 never reaps (a CI container) the stopped hub lingers as a zombie
      (should (drgnx-hub-test--wait (lambda () (not (drgnx-hub-running-p))) 5))
      ;; and its job ends: the wrapper records the exit (the tree is removed only then — a CI race)
      (should (drgnx-hub-test--wait (lambda () (memq (plist-get (car (drgnx-jobs-list)) :status) '(exited stopped))) 5)))))

(defun drgnx-hub-test--start-elsewhere (&rest env)
  "Start the hub from another Emacs with ENV (\"NAME=value\"…) added, as an editor or the CLI does; its exit status."
  (let ((process-environment (append env process-environment)))
    (call-process (expand-file-name invocation-name invocation-directory) nil nil nil "--batch" "-Q"
                  "-L" (expand-file-name "core" drgnx-dir) "-l" "drgnx-hub" "--eval" "(kill-emacs (if (drgnx-hub-ensure) 0 1))")))

(ert-deftest drgnx-hub/no-key-in-unit-environment ()
  ;; a key in the starting Emacs's environment never becomes the hub's (a systemd unit's --setenv is kept in the
  ;; unit, `systemctl --user show' shows it): it is handed over the socket once the hub runs
  (skip-unless (file-readable-p "/proc/self/environ"))
  (drgnx-hub-test--with
    (let ((started nil))
      (cl-letf (((symbol-function 'drgnx-jobs-start)
                 (lambda (&rest args) (setq started args) (drgnx-hub-serve (drgnx-hub-socket)))))
        (let ((process-environment (cons "OPENROUTER_API_KEY=sk-fake-env" process-environment)))
          (drgnx-hub-ensure)))
      (should started)
      (should-not (string-search "sk-fake-env" (prin1-to-string started)))
      (should-not (string-search "API_KEY" (prin1-to-string started))))
    (drgnx-hub-disconnect)
    (drgnx-hub-stop)
    (clrhash drgnx-gateway--keys)
    ;; a real hub, started by an Emacs that has the key: not in its environment, yet its agents' requests carry it
    (should (= (drgnx-hub-test--start-elsewhere "OPENROUTER_API_KEY=sk-fake-env") 0))
    (let* ((pid (plist-get (drgnx-hub-call-sync "status" nil) :pid))
           (environ (with-temp-buffer (set-buffer-multibyte nil)
                                      (insert-file-contents-literally (format "/proc/%d/environ" pid)) (buffer-string))))
      (let ((leaked (and (string-search "sk-fake-env" environ) t))) (should-not leaked))   ; (never the environment printed)
      (let ((r (drgnx-hub-call-sync "gateway/register" '(:chain [["openrouter" nil]]))))
        (should (= (drgnx-hub-test--post (plist-get r :url) (plist-get r :token)) 200))
        (should (string-search "Bearer sk-fake-env" (with-temp-buffer (insert-file-contents or-log) (buffer-string))))))))

(ert-deftest drgnx-hub/an-editor-gives-its-keys-again-to-a-restarted-hub ()
  ;; a key this Emacs loaded (a .gpg file: in no environment) lives in the hub's memory only: a restarted hub has
  ;; none until the editor connects again, which hands it over again
  (drgnx-hub-test--with
    (puthash 'openrouter "sk-fake-loaded" drgnx-ai--keys)
    (should (= (drgnx-hub-test--start-elsewhere) 0))
    (drgnx-hub-connect)
    (should (drgnx-hub-test--wait (lambda () (process-live-p drgnx-hub--events))))
    (let ((r (drgnx-hub-call-sync "gateway/register" '(:chain [["openrouter" nil]]))))
      (should (= (drgnx-hub-test--post (plist-get r :url) (plist-get r :token)) 200))
      (drgnx-hub-call-sync "shutdown" nil)
      (should (drgnx-hub-test--wait (lambda () (not (process-live-p drgnx-hub--events))) 5))
      (should (drgnx-hub-test--wait (lambda () (not (drgnx-hub-running-p))) 5))
      (should (= (drgnx-hub-test--start-elsewhere) 0))
      (should (= (drgnx-hub-test--post (plist-get r :url) (plist-get r :token)) 502))   ; the same token: no key yet
      (drgnx-hub-connect)                                                               ; (the editor's idle timer)
      (should (drgnx-hub-test--wait (lambda () (process-live-p drgnx-hub--events))))
      (drgnx-hub-call-sync "ping" nil)
      (should (= (drgnx-hub-test--post (plist-get r :url) (plist-get r :token)) 200))
      (should (= (with-temp-buffer (insert-file-contents or-log) (how-many "Bearer sk-fake-loaded" (point-min) (point-max)))
                 2)))))

(defun drgnx-hub-test--sigpipe-ignored-p ()
  "Does this Emacs ignore SIGPIPE, as every hub does (Linux: SigIgn in /proc/self/status)?"
  (with-temp-buffer
    (and (ignore-errors (insert-file-contents "/proc/self/status") t)
         (re-search-forward "^SigIgn:[ \t]+\\([0-9a-f]+\\)" nil t)
         (/= 0 (logand (string-to-number (match-string 1) 16) (ash 1 12))))))   ; SIGPIPE is 13

(ert-deftest drgnx-hub/a-client-that-leaves-before-the-answer-is-no-error ()
  ;; a coordination server's notify, a probe: they write and go; the hub's answer must not raise an error (under
  ;; ERT, or with debug-on-error, a filter error ends a batch Emacs).  The hub here is this Emacs: a hub always
  ;; runs with SIGPIPE ignored (`drgnx-hub-ensure'), so this one must too — the runners (bin/drgnx test, check)
  ;; ignore it; a plain `emacs --batch' would be killed by the write instead of seeing its error
  (skip-unless (drgnx-hub-test--sigpipe-ignored-p))
  (drgnx-hub-test--with
    (drgnx-hub-serve (drgnx-hub-socket))
    (dotimes (_ 5)
      (let ((c (make-network-process :name "leaver" :family 'local :service (drgnx-hub-socket) :noquery t)))
        (process-send-string c "{\"id\":7,\"method\":\"status\"}\n{\"method\":\"coord/notify\"}\n")
        (delete-process c)))
    (let ((deadline (+ (float-time) 1))) (while (< (float-time) deadline) (accept-process-output nil 0.05)))
    (should (drgnx-hub-call-sync "ping" nil))))

(ert-deftest drgnx-hub/long-line-and-malformed-answered ()
  ;; a line that is not JSON but names its id is answered with an error (the client never waits for nothing); a
  ;; line over the cap (1 MiB) closes its connection; the hub serves on
  (drgnx-hub-test--with
    (drgnx-hub-serve (drgnx-hub-socket))
    (let* ((got "")
           (c (make-network-process :name "raw" :family 'local :service (drgnx-hub-socket) :noquery t :coding 'utf-8-unix
                                    :filter (lambda (_p s) (setq got (concat got s))))))
      (process-send-string c "{\"id\":7,\"method\":\n")
      (should (drgnx-hub-test--wait (lambda () (string-search "\n" got)) 1))
      (let ((answer (json-parse-string got :object-type 'plist)))
        (should (eql (plist-get answer :id) 7))
        (should (stringp (plist-get (plist-get answer :error) :message))))
      ;; 2 MiB without an end of line (the write to a closed connection is an error only where SIGPIPE is ignored,
      ;; as the runner does)
      (when (drgnx-hub-test--sigpipe-ignored-p)
        (ignore-errors (process-send-string c (make-string (* 2 1024 1024) ?x)))
        (should (drgnx-hub-test--wait (lambda () (not (process-live-p c))) 5)))
      (delete-process c))
    (should (drgnx-hub-call-sync "ping" nil))))

(ert-deftest drgnx-hub/an-agent-hanging-up-never-kills-the-hub ()
  ;; the editing Emacs starts the hub without ignoring SIGPIPE: a write to a connection the agent closed must not
  ;; end the hub (exit 141)
  (drgnx-hub-test--with
    (with-temp-file (concat root "or.eld")
      (prin1 '((:path "/api/v1/messages" :chunks ((0 . "data: {}\n\n") (0.2 . "data: {}\n\n") (0.2 . "data: {}\n\n") (0.2 . "data: {}\n\n")
                                                  (0.2 . "data: {}\n\n") (0.2 . "data: {}\n\n") (0.2 . "data: {}\n\n"))))
             (current-buffer)))
    (delete-process mock) (setq mock (drgnx-ai-test-mock-llm or-port (concat root "or.eld") or-log))
    (should (= 0 (call-process "sh" nil nil nil "-c" "trap - PIPE; exec \"$0\" \"$@\""
                               (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                               "-L" (expand-file-name "core" drgnx-dir) "-l" "drgnx-hub"
                               "--eval" "(kill-emacs (if (drgnx-hub-ensure) 0 1))")))
    (let* ((r (drgnx-hub-call-sync "gateway/register" (list :chain [["openrouter" nil]] :keys '(:openrouter "sk-k"))))
           (port (string-to-number (car (last (split-string (plist-get r :url) ":"))))))
      (dotimes (_ 3)                                                   ; three agents hang up mid-answer
        (let ((got "") (c (open-network-stream "agent" nil "127.0.0.1" port :coding 'binary)))
          (set-process-filter c (lambda (_p s) (setq got (concat got s))))
          (process-send-string c (format "POST /v1/messages HTTP/1.1\r\nAuthorization: Bearer %s\r\nContent-Length: 2\r\n\r\n{}"
                                         (plist-get r :token)))
          (drgnx-hub-test--wait (lambda () (string-search "data:" got)) 5)
          (delete-process c)))
      (sleep-for 2)
      (should (drgnx-hub-running-p)))))

(ert-deftest drgnx-hub/agents-keep-their-address-across-a-restart ()
  ;; a running agent keeps the URL it started with: a restarted hub's gateway must be there
  (drgnx-hub-test--with
    (drgnx-hub-serve (drgnx-hub-socket))
    (let* ((r (drgnx-hub-call-sync "gateway/register" (list :chain [["openrouter" nil]] :keys '(:openrouter "sk-k"))))
           (url (plist-get r :url)))
      (drgnx-hub-disconnect)
      (drgnx-hub-stop)
      (drgnx-hub-serve (drgnx-hub-socket))
      (should (equal (format "http://127.0.0.1:%d" (drgnx-gateway-port)) url))
      (drgnx-gateway-set-key 'openrouter "sk-k")      ; (a key from the socket lives in memory: sent again)
      (should (= (drgnx-hub-test--post url (plist-get r :token)) 200)))))

(ert-deftest drgnx-hub/a-hub-that-holds-the-lock-is-never-replaced ()
  ;; a live hub too busy to answer a ping within a second keeps its socket
  (drgnx-hub-test--with
    (let ((socket (drgnx-hub-socket)) (other (start-process "busy-hub" nil "sleep" "30")))   ; a live process
      (make-directory (concat socket ".lock") t)
      (write-region (number-to-string (process-id other)) nil (concat socket ".lock/pid") nil 'silent)
      (write-region "" nil socket nil 'silent)                          ; its socket (not answering just now)
      (should-error (drgnx-hub-serve socket))
      (should (file-exists-p socket))
      (delete-process other)
      ;; a lock left by a process that is gone is taken over
      (write-region "999999999" nil (concat socket ".lock/pid") nil 'silent)
      (drgnx-hub-serve socket)
      (should (drgnx-hub-call-sync "ping" nil))
      (should (equal (string-to-number (with-temp-buffer (insert-file-contents (concat socket ".lock/pid")) (buffer-string)))
                     (emacs-pid)))
      ;; stopping removes only what is its own
      (drgnx-hub-disconnect)
      (drgnx-hub-stop)
      (should-not (file-exists-p socket))
      (should-not (file-exists-p (concat socket ".lock"))))))

(ert-deftest drgnx-hub/a-socket-not-private-to-the-user-is-never-used ()
  ;; whatever answers on the socket gets this Emacs's keys: a socket whose directory is open to others (or not the
  ;; user's, or the socket itself not the user's) is never pinged, connected to or given anything
  (drgnx-hub-test--with
    (let* ((run (concat root "run")) (process-environment (cons (concat "XDG_RUNTIME_DIR=" run) process-environment))
           (socket (drgnx-hub-socket)) (dir (file-name-directory socket)) (got "") (uid (user-uid)))
      (make-directory dir t)
      (puthash 'openrouter "sk-fake-loaded" drgnx-ai--keys)
      (let ((listener (make-network-process :name "foreign-hub" :family 'local :server t :service socket :noquery t
                                            :filter (lambda (c s) (setq got (concat got s))
                                                      ;; it answers pings as a hub would
                                                      (when (string-search "ping" s)
                                                        (process-send-string c "{\"id\":0,\"result\":{\"pid\":1}}\n"))))))
        (unwind-protect
            (progn
              (set-file-modes dir #o777)
              (should-not (drgnx-hub-running-p))
              (should (string-match-p "mode 777" (cadr (should-error (drgnx-hub-connect)))))
              (should-error (drgnx-hub-call "status" nil #'ignore))
              ;; the directory private, but not this user's (as another user's would be)
              (set-file-modes dir #o700)
              (cl-letf (((symbol-function 'user-uid) (lambda () (1+ uid))))
                (should-not (drgnx-hub-running-p))
                (should-error (drgnx-hub-connect)))
              (drgnx-hub-test--wait #'ignore 0.3)
              (should-not (string-search "sk-fake" got))
              (should-not (string-search "gateway/keys" got))
              (should-not (string-search "subscribe" got))
              ;; and once it is the user's own and private, it is used
              (should (drgnx-hub-running-p)))
          (delete-process listener))))))

(ert-deftest drgnx-hub/a-socket-whose-directory-is-missing-is-never-connected-to ()
  ;; checked, then connected to by path: a directory missing at the check could be another user's by the connect (a
  ;; swap in /tmp) — so a missing one is a refusal, never a connect by path; the coordination server's notify too
  (require 'drgnx-coord-mcp)
  (drgnx-hub-test--with
    (let* ((run (concat root "run")) (process-environment (cons (concat "XDG_RUNTIME_DIR=" run) process-environment))
           (connects 0))
      (make-directory run t)
      (should-not (file-exists-p (file-name-directory (drgnx-hub-socket))))
      (should (string-match-p "does not exist" (drgnx-hub--untrusted (drgnx-hub-socket))))
      (cl-letf* ((real (symbol-function 'make-network-process))
                 ((symbol-function 'make-network-process)
                  (lambda (&rest args) (unless (plist-get args :server) (cl-incf connects)) (apply real args))))
        (should (string-match-p "does not exist" (cadr (should-error (drgnx-hub-connect)))))
        (should-error (drgnx-hub-call "status" nil #'ignore))
        (should (= connects 0))
        ;; a socket in a directory open to others: the notify does not go there either
        (make-directory (file-name-directory (drgnx-hub-socket)) t)
        (set-file-modes (file-name-directory (drgnx-hub-socket)) #o777)
        (let ((listener (make-network-process :name "foreign" :family 'local :server t :service (drgnx-hub-socket) :noquery t)))
          (unwind-protect
              (progn (drgnx-coord-mcp--notify-hub)
                     (should (= connects 0)))
            (delete-process listener)))))))

(ert-deftest drgnx-hub/the-hub-s-private-dir-is-never-reached-through-a-link ()
  ;; the socket's directory, given with its slash: never followed through a link (another user's, in /tmp, could
  ;; point at a directory of the user's that would be chmodded), and made 0700 from the start (not at the umask)
  (drgnx-hub-test--with
    (let ((target (concat root "target")) (link (concat root "link")) (fresh (concat root "fresh/sub/")))
      (make-directory target)
      (set-file-modes target #o755)
      (make-symbolic-link target link)
      (should-error (drgnx-hub--private-dir (file-name-as-directory link)))
      (should (= (file-modes target) #o755))
      (with-file-modes #o755
        (cl-letf (((symbol-function 'set-file-modes) #'ignore))     ; what it was made with
          (drgnx-hub--private-dir fresh)))
      (should (= (file-modes (directory-file-name fresh)) #o700)))))

(ert-deftest drgnx-hub/a-directory-vanishing-mid-check-is-no-error ()
  ;; the check reads the directory once: one that goes between two reads (its mode then nil) is not an error, and
  ;; whatever the check meets, asking whether a hub runs answers, never signals
  (drgnx-hub-test--with
    (drgnx-hub-serve (drgnx-hub-socket))
    (cl-letf (((symbol-function 'file-modes) (lambda (&rest _) nil)))       ; gone by the second read
      (should-not (drgnx-hub--untrusted (drgnx-hub-socket))))
    (cl-letf (((symbol-function 'drgnx-hub--untrusted) (lambda (_) (error "Vanished"))))
      (should-not (condition-case nil (progn (drgnx-hub-running-p) nil) (error t))))))

(ert-deftest drgnx-hub/without-a-runtime-dir-the-socket-is-short-and-private ()
  (drgnx-hub-test--with
    (let ((process-environment (cons "XDG_RUNTIME_DIR" process-environment)))
      (should (string-prefix-p (drgnx-state-dir) (drgnx-hub-socket)))
      (drgnx-hub-serve (drgnx-hub-socket))
      (should (drgnx-hub-call-sync "ping" nil))
      (should (equal (file-modes (file-name-directory (drgnx-hub-socket))) #o700))
      (drgnx-hub-disconnect) (drgnx-hub-stop))
    ;; a state dir so deep the socket path would pass the system's limit (103 bytes on macOS, 107 on Linux)
    (let* ((deep (concat root (make-string 120 ?d) "/"))
           (process-environment (append (list "XDG_RUNTIME_DIR" (concat "XDG_STATE_HOME=" deep)) process-environment)))
      (should (<= (string-bytes (drgnx-hub-socket)) 103))
      (drgnx-hub-serve (drgnx-hub-socket))
      (should (drgnx-hub-call-sync "ping" nil))
      (should (equal (file-modes (file-name-directory (drgnx-hub-socket))) #o700))
      (drgnx-hub-disconnect) (drgnx-hub-stop))))

(ert-deftest drgnx-hub/a-socket-path-of-104-bytes-is-too-long ()
  ;; macOS's limit is 104 bytes with the closing NUL (Linux's 108): 103 is kept, 104 gets the short private path
  (drgnx-hub-test--with
    (let ((at (lambda (bytes)
                ;; a runtime dir whose socket ($RUN/drgnx/hub-HASH.sock, 24 bytes past it) is BYTES long
                (let ((run (expand-file-name (make-string (- bytes 24 (length (directory-file-name root)) 1) ?r) root)))
                  (make-directory run t)
                  (let ((process-environment (cons (concat "XDG_RUNTIME_DIR=" run) process-environment)))
                    (drgnx-hub-socket))))))
      (let ((kept (funcall at 103)))
        (should (eql (string-bytes kept) 103))
        (should (string-prefix-p root kept)))
      (let ((moved (funcall at 104)))
        (should (string-prefix-p (file-name-as-directory (expand-file-name (format "drgnx-hub-%d" (user-uid)) temporary-file-directory))
                                 moved))))))

(ert-deftest drgnx-hub/socket-length-counts-the-encoded-name ()
  ;; macOS's file names are decomposed (utf-8-hfs): "é" is 2 bytes in Emacs but 3 on disk, so a path of 103 bytes in
  ;; Emacs can pass the limit once encoded
  (require 'ucs-normalize)
  (drgnx-hub-test--with
    ;; a temporary dir too deep to leave room for the name (macOS's /var/folders/…/T/ can be) has nothing to test
    (skip-unless (> (- 103 24 8 (string-bytes root)) 0))
    (let* ((file-name-coding-system 'utf-8-hfs)
           ;; 4 × "é", then r…: the socket ($RUN/drgnx/hub-HASH.sock, 24 bytes past it) is 103 bytes in Emacs, 107 encoded
           (run (concat root (make-string 4 ?é) (make-string (- 103 24 8 (string-bytes root)) ?r)))
           (process-environment (cons (concat "XDG_RUNTIME_DIR=" run) process-environment)))
      (make-directory run t)
      (should (eql (string-bytes (concat run "/drgnx/hub-12345678.sock")) 103))
      (should (string-prefix-p (file-name-as-directory (expand-file-name (format "drgnx-hub-%d" (user-uid)) temporary-file-directory))
                               (drgnx-hub-socket))))))

(ert-deftest drgnx-hub/no-hub-is-started-where-starting-is-off ()
  (drgnx-hub-test--with
    (let ((process-environment (cons "DRGNX_NO_HUB_START=1" process-environment)) (started nil))
      (cl-letf (((symbol-function 'drgnx-jobs-start) (lambda (&rest _) (setq started t))))
        (should-error (drgnx-hub-ensure))
        (should-not started))
      (drgnx-hub-serve (drgnx-hub-socket))            ; one that runs is used
      (should (drgnx-hub-ensure)))))

(ert-deftest drgnx-hub/the-cli ()
  (drgnx-hub-test--with
    (let ((cli (lambda (&rest args)
                 (with-temp-buffer
                   (cons (apply #'call-process (expand-file-name "bin/drgnx" drgnx-dir) nil t nil "hub" args) (buffer-string))))))
      (should (= (car (funcall cli "status" "--json")) 1))
      (should (= (car (funcall cli "start")) 0))
      (let ((s (funcall cli "status" "--json")))
        (should (= (car s) 0))
        (should (integerp (plist-get (json-parse-string (cdr s) :object-type 'plist) :gateway_port))))
      (should (= (car (funcall cli "stop")) 0))
      (should (drgnx-hub-test--wait (lambda () (not (drgnx-hub-running-p))) 5)))))

;;;; The hub's timers, on the timer layer (virtual time; no socket, no gateway)

(defvar drgnx-hub-test--calls nil "What the stubbed hub functions saw, newest first.")

(defmacro drgnx-hub-test--timed (&rest body)
  "BODY on the virtual clock, with the hub's side effects stubbed (they log to `drgnx-hub-test--calls'), no recorded
timer errors and a state dir of its own.  The hub's tables are fresh; nothing is served."
  (declare (indent 0))
  `(let* ((state (make-temp-file "drgnx-hub-state" t))
          (process-environment (cons (concat "XDG_STATE_HOME=" state) process-environment))
          (drgnx-timer-errors nil) (drgnx-timer-report-file drgnx-timer-report-file) (drgnx-hub-test--calls nil)
          (drgnx-hub--event-state (make-hash-table :test #'equal)) (drgnx-hub--told (make-hash-table :test #'equal))
          (drgnx-hub--sent (make-hash-table :test #'equal)) (drgnx-hub--subscribers nil) (drgnx-hub--server nil)
          (drgnx-hub--exit-function (lambda () (push 'exit drgnx-hub-test--calls)))
          (drgnx-gateway--registrations (make-hash-table :test #'equal)))
     (unwind-protect
         (cl-letf (((symbol-function 'drgnx-hub--save-sessions) #'ignore)
                   ((symbol-function 'drgnx-hub--session-events) #'ignore)
                   ((symbol-function 'drgnx-hub--answer) #'ignore)
                   ((symbol-function 'drgnx-gateway-stop) #'ignore)
                   ((symbol-function 'drgnx-agents-free-p) (lambda (_s) t))
                   ((symbol-function 'drgnx-hub--deliver) (lambda () (push 'deliver drgnx-hub-test--calls)))
                   ((symbol-function 'drgnx-hub--flush) (lambda (s) (push (list 'flush (drgnx-agent-session-id s)) drgnx-hub-test--calls)))
                   ((symbol-function 'drgnx-hub--events-send) (lambda () (push 'events drgnx-hub-test--calls))))
           (drgnx-test-with-clock () ,@body))
       (drgnx-timer-reset)
       (delete-directory state t))))

(defun drgnx-hub-test--bad () (error "Boom"))

(defun drgnx-hub-test--seen (what) (cl-count what drgnx-hub-test--calls :test #'equal))

(ert-deftest drgnx-hub/a-burst-of-changes-delivers-once ()
  (drgnx-hub-test--timed
    (let ((s (drgnx-agents--make :id "s-1" :name "one")))
      (dotimes (_ 10) (drgnx-hub--agent-changed s))
      (should (drgnx-timer-active-p 'hub-deliver))
      (drgnx-test-advance 0.09)
      (should (= (drgnx-hub-test--seen 'deliver) 0))
      (drgnx-test-advance 0.02)
      (should (= (drgnx-hub-test--seen 'deliver) 1))
      (drgnx-test-advance 1)
      (should (= (drgnx-hub-test--seen 'deliver) 1))
      (drgnx-hub--agent-changed s)                        ; the next burst delivers again
      (drgnx-test-advance 0.2)
      (should (= (drgnx-hub-test--seen 'deliver) 2)))))

(ert-deftest drgnx-hub/one-flush-per-session-per-burst ()
  (drgnx-hub-test--timed
    (let ((a (drgnx-agents--make :id "s-a" :name "a")) (b (drgnx-agents--make :id "s-b" :name "b")))
      (dotimes (_ 5) (drgnx-hub--agent-changed a) (drgnx-hub--agent-changed b))
      (should (drgnx-timer-active-p (cons 'hub-flush "s-a")))
      (should (drgnx-timer-active-p (cons 'hub-flush "s-b")))
      (drgnx-test-advance 0.06)
      (should (= (drgnx-hub-test--seen '(flush "s-a")) 1))
      (should (= (drgnx-hub-test--seen '(flush "s-b")) 1))
      (drgnx-hub--agent-changed a)
      (drgnx-test-advance 0.06)
      (should (= (drgnx-hub-test--seen '(flush "s-a")) 2))
      (should (= (drgnx-hub-test--seen '(flush "s-b")) 1)))))

(ert-deftest drgnx-hub/events-go-at-most-every-interval ()
  (drgnx-hub-test--timed
    (let ((drgnx-hub-events-interval 0.3))
      (dotimes (_ 5) (drgnx-hub--events-soon))
      (drgnx-test-advance 0.29)
      (should (= (drgnx-hub-test--seen 'events) 0))
      (drgnx-test-advance 0.02)
      (should (= (drgnx-hub-test--seen 'events) 1))
      (drgnx-hub--events-soon)                            ; at once after the first went out: the next interval
      (drgnx-hub--events-soon)
      (drgnx-test-advance 0.29)
      (should (= (drgnx-hub-test--seen 'events) 1))
      (drgnx-test-advance 0.02)
      (should (= (drgnx-hub-test--seen 'events) 2)))))

(ert-deftest drgnx-hub/shutdown-exits-after-a-tenth-unless-stopped ()
  (drgnx-hub-test--timed
    (drgnx-hub--serve-request nil '(:id 1 :method "shutdown"))
    (should (drgnx-timer-active-p 'hub-exit))
    (drgnx-test-advance 0.09)
    (should (= (drgnx-hub-test--seen 'exit) 0))
    (drgnx-test-advance 0.02)
    (should (= (drgnx-hub-test--seen 'exit) 1))
    (should-not (drgnx-timer-active-p 'hub-exit))
    ;; a hub stopped meanwhile never exits
    (drgnx-hub--serve-request nil '(:id 2 :method "shutdown"))
    (drgnx-hub-stop)
    (drgnx-test-advance 1)
    (should (= (drgnx-hub-test--seen 'exit) 1))))

(ert-deftest drgnx-hub/stop-leaves-no-hub-timer ()
  (drgnx-hub-test--timed
    (drgnx-hub--agent-changed (drgnx-agents--make :id "s-1" :name "one"))
    (drgnx-hub--agent-changed (drgnx-agents--make :id "s-2" :name "two"))
    (drgnx-hub--events-soon)
    (drgnx-hub--serve-request nil '(:id 1 :method "shutdown"))
    (drgnx-timer-start 'hub-tick 2 #'drgnx-hub--tick :repeat 2 :owner :core)
    (should (= (length (drgnx-timer-pending)) 6))        ; deliver, 2 flushes, events, exit, tick
    (drgnx-timer-start 'unrelated 5 #'ignore :owner :core)
    (drgnx-hub-stop)
    (should (equal (mapcar #'car (drgnx-timer-pending)) '(unrelated)))
    (drgnx-timer-cancel 'unrelated)))

(ert-deftest drgnx-hub/a-failing-tick-step-never-stops-the-tick ()
  ;; the tick's steps fail on a busy work.db: demoted by the tick itself, so the failure limit never counts them
  (drgnx-hub-test--timed
    (cl-letf (((symbol-function 'drgnx-hub--deliver) (lambda () (error "database is locked"))))
      (drgnx-timer-start 'hub-tick 2 #'drgnx-hub--tick :repeat 2 :owner :core)
      (drgnx-test-advance 10))
    (should-not drgnx-timer-errors)
    (should (drgnx-timer-active-p 'hub-tick))
    (drgnx-timer-cancel 'hub-tick)))

(ert-deftest drgnx-hub/the-hub-writes-its-own-timer-report ()
  (drgnx-hub-test--timed
    (let ((report nil))
      (cl-letf (((symbol-function 'drgnx-hub-serve) (lambda (_s) (error "stop here")))
                ((symbol-function 'kill-emacs) (lambda (&rest _) (throw 'drgnx-hub-test--out nil))))
        (catch 'drgnx-hub-test--out (drgnx-hub-main)))
      (should (equal drgnx-timer-report-file "hub-timers-report.eld"))
      (drgnx-timer-start 'hub-bad 1 #'drgnx-hub-test--bad :repeat 1 :owner :core)
      (drgnx-test-advance 3.5)
      (setq report (expand-file-name "hub-timers-report.eld" (drgnx-state-dir)))
      (should (file-exists-p report))
      (should (string-match-p "hub-bad" (with-temp-buffer (insert-file-contents report) (buffer-string))))
      (should-not (file-exists-p (expand-file-name "timers-report.eld" (drgnx-state-dir)))))))

;;; hub-test.el ends here
