;;; agents-mirror-test.el --- batch tests: the editing Emacs mirrors the hub's agent sessions -*- lexical-binding: t -*-
;; The hub runs as its own process (as it does for the user); this Emacs plays the editor.  Each test runs inside the
;; delivery gate (a test-hooks Ratatoskr, `drgnx-test-gated'): the hub's lines reach the editor when the test says so.
;; The agent behind a session is a real child (mock-acp) whose turns run in real time; what it did is a condition the
;; test sees in the mirror after each release of the hub's lines (`drgnx-agents-mirror-test--settle'), never a deadline.
;; test-class: cond
;; test-pattern: gated
(require 'ert)
(require 'drgnx-agents)
(require 'drgnx-agents-mirror)
(require 'drgnx-records)
(require 'drgnx-hub-client)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/ratatoskr-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/delivery-gate-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/runtime-settings-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/unit/hub-client-test" drgnx-dir) nil t)   ; its Ratatoskr helpers

(defmacro drgnx-agents-mirror-test--with (schedule &rest body)
  "BODY inside `drgnx-test-gated' SCHEDULE (quoted, as there) with a gated Ratatoskr serving drgnx's dirs under ROOT
\(profile \"mock\" in its settings.el), this Emacs not connected, no mirrors yet; skipped without the binary
\(`drgnx-hub-client-test--with-hub')."
  (declare (indent 1))
  `(drgnx-hub-client-test--with-hub
     (drgnx-hub-client-test--mock-profile root)
     (let ((drgnx-agents--sessions nil) (drgnx-agents-profiles nil) (drgnx-test-gate-unnamed-ok t))
       (drgnx-test-gated ,schedule
         (unwind-protect (progn ,@body)
           (drgnx-agents-mirror-stop))))))

(defun drgnx-agents-mirror-test--settle (pred what)
  "Wait until PRED holds, the hub's clock moved past its update throttle and what it has written released
\(`drgnx-test-hub-advance') before each look.  The hub's agents are real children: their progress is what PRED sees in
the mirrors.  PRED's value."
  (drgnx-test-wait (lambda () (drgnx-test-hub-advance 100) (funcall pred)) :what what))

(defun drgnx-agents-mirror-test--ask (method params)
  "The hub's answer (the result) to METHOD with PARAMS, asked without a wait of its own: the answer is released with
the rest, so no schedule step has to be met before the next look."
  (let (done result)
    (drgnx-hub-call method params (lambda (r _err) (setq result r done t)))
    (drgnx-agents-mirror-test--settle (lambda () done) (format "the hub's answer to %s" method))
    result))

(defun drgnx-agents-mirror-test--mirror (id) (seq-find (lambda (s) (equal (drgnx-agent-session-remote s) id)) drgnx-agents--sessions))

(defun drgnx-agents-mirror-test--text (s)
  (mapconcat (lambda (e) (format "%s" (or (plist-get e :text) ""))) (drgnx-agent-session-entries s) " "))

(defun drgnx-agents-mirror-test--idle-mirror (id)
  "Mirror ID's mirror once it exists and is idle (a settle's condition), else nil."
  (let ((m (drgnx-agents-mirror-test--mirror id))) (and m (eq (drgnx-agent-session-status m) 'idle) m)))

(defun drgnx-agents-mirror-test--start (&rest params)
  "Start a session of PARAMS (a plist: :profile …) in the hub; its mirror once it is idle.  The caller's schedule has
the answer to `agents/start', and this Emacs mirrors the hub (`drgnx-agents-mirror-sync')."
  (let ((id (plist-get (drgnx-agents-mirror-test--ask "agents/start" (append params (list :cwd (getenv "HOME")))) :id)))   ; ROOT/home
    (drgnx-agents-mirror-test--settle (lambda () (drgnx-agents-mirror-test--idle-mirror id)) "the new session's mirror, idle")))

(ert-deftest drgnx-agents-mirror/hub-sessions-appear-and-stay-current ()
  (drgnx-agents-mirror-test--with '()
    (drgnx-agents-mirror-sync)
    (let* ((m (drgnx-agents-mirror-test--start :profile "mock")) (was (drgnx-agent-session-status m)))
      (drgnx-agents-mirror-show (drgnx-agent-session-remote m))   ; the entries go to the editor that shows the transcript
      (drgnx-agents-send m "hello mirror")
      (drgnx-agents-mirror-test--settle (lambda () (string-search "You said: hello mirror" (drgnx-agents-mirror-test--text m)))
                                        "the answer in the mirror")
      (drgnx-test-deliver-all)
      (should (eq was 'idle))
      (should-not (drgnx-agent-session-conn m)))))                   ; a mirror: the agent runs in the hub

(defun drgnx-agents-mirror-test--asking (root)
  "ROOT's settings.el: the profile \"mock\" (as `drgnx-hub-client-test--mock-profile'), the profile \"asks\"
(`ratatoskr-mock acp', beside the hub's binary) and a matrix whose cell for a worker's edits asks the user, so the
hub hands that permission request to the editor."
  (drgnx-test-write-settings
   (concat root "config/settings.el")
   'drgnx-agents-profiles
   (list (list "mock" :command (list "sh" (expand-file-name "test/fixtures/mock-acp-stdin.sh" drgnx-dir)
                                     (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                     "-l" (expand-file-name "test/fixtures/mock-acp.el" drgnx-dir)))
         (list "asks" :provider 'claude
               :command (list (expand-file-name "ratatoskr-mock" (file-name-directory (drgnx-hub-client-test--bin)))
                              "acp" "--as" "claude")))
   'drgnx-agents-matrix '(:cells ((:action code.edit :column (:role worker) :verdict ask)))))

(ert-deftest drgnx-agents-mirror/actions-on-a-mirror-go-to-the-hub ()
  (drgnx-agents-mirror-test--with '()
    (drgnx-agents-mirror-test--asking root)
    (drgnx-agents-mirror-sync)
    (let ((m (drgnx-agents-mirror-test--start :profile "asks" :role "worker")) request option)
      (drgnx-agents-mirror-show (drgnx-agent-session-remote m))
      (drgnx-agents-send m "ask:permission edit")
      (drgnx-agents-mirror-test--settle (lambda () (drgnx-agent-session-permissions m)) "the permission request in the mirror")
      (setq request (car (drgnx-agent-session-permissions m))
            option (plist-get (car (plist-get request :options)) :optionId))
      (when (stringp option) (drgnx-agents-answer-permission m request option))
      (drgnx-agents-mirror-test--settle
       (lambda () (string-search (concat "permission: " option) (drgnx-agents-mirror-test--text m))) "the agent's word on the answer")
      (drgnx-agents-kill m)
      (drgnx-agents-mirror-test--settle (lambda () (eq (drgnx-agent-session-status m) 'exited)) "the killed session, exited")
      (drgnx-test-deliver-all)
      (should (stringp option)))))

;; A hub's sessions are its children: they end with it, and the editor must not show them working.  What the mirror says
;; of why depends on which reached the editor first, the session's own end or the hub's: the test chooses.
(ert-deftest drgnx-agents-mirror/when-the-hub-ends-its-mirrors-say-so ()
  ;; the hub's end comes first (the session's own end is a snapshot the hub never sends once it is gone)
  (drgnx-agents-mirror-test--with '()
    (drgnx-agents-mirror-sync)
    (let ((m (drgnx-agents-mirror-test--start :profile "mock")))
      (drgnx-hub-call "shutdown" nil #'ignore)
      (drgnx-test-wait (lambda () (memq :eof (drgnx-test-gate-held 'sub-1))) :what "the subscription's end, held")
      (drgnx-test-deliver-all)
      (should (eq (drgnx-agent-session-status m) 'exited))
      (should (string-search "hub" (or (drgnx-agent-session-stderr m) ""))))))

(ert-deftest drgnx-agents-mirror/a-session-that-ended-before-the-hub-keeps-its-own-reason ()
  ;; the session's end comes first: the hub's end leaves what the session said alone
  (drgnx-agents-mirror-test--with '()
    (drgnx-agents-mirror-sync)
    (let ((m (drgnx-agents-mirror-test--start :profile "mock")) own)
      (drgnx-agents-kill m)
      (drgnx-agents-mirror-test--settle (lambda () (eq (drgnx-agent-session-status m) 'exited)) "the killed session, exited")
      (setq own (drgnx-agent-session-stderr m))
      (drgnx-hub-call "shutdown" nil #'ignore)
      (drgnx-test-wait (lambda () (memq :eof (drgnx-test-gate-held 'sub-1))) :what "the subscription's end, held")
      (drgnx-test-deliver-all)
      (should (eq (drgnx-agent-session-status m) 'exited))
      (should (equal (drgnx-agent-session-stderr m) own)))))

(ert-deftest drgnx-agents-mirror/a-new-emacs-reattaches ()
  (drgnx-agents-mirror-test--with '()
    (drgnx-agents-mirror-sync)
    (let* ((m (drgnx-agents-mirror-test--start :profile "mock")) (id (drgnx-agent-session-remote m)) hub again)
      (drgnx-agents-mirror-show id)
      (drgnx-agents-mirror-test--ask "agents/send" (list :id id :text "slow work"))       ; it streams while this Emacs goes away
      (drgnx-agents-mirror-test--settle (lambda () (string-search "part 1" (drgnx-agents-mirror-test--text m))) "the stream under way")
      (drgnx-agents-mirror-stop) (drgnx-hub-disconnect) (setq drgnx-agents--sessions nil)
      (drgnx-agents-mirror-sync)                                             ; a new editor
      (drgnx-agents-mirror-show id)                                          ; whose window shows the transcript
      (setq m (drgnx-agents-mirror-test--settle
               (lambda () (let ((m (drgnx-agents-mirror-test--mirror id)))
                            (and m (eq (drgnx-agent-session-status m) 'idle) (string-search "part 10" (drgnx-agents-mirror-test--text m)) m)))
               "the stream's end in the new editor's mirror"))
      ;; nothing lost: the mirror's transcript is the hub's
      (setq hub (mapcar (lambda (e) (drgnx-records-from-json 'drgnx-records-entry e))
                        (plist-get (drgnx-agents-mirror-test--ask "agents/get" (list :id id)) :entries)))
      (drgnx-agents-mirror-test--settle (lambda () (equal (drgnx-agent-session-entries m) hub)) "the mirror's transcript is the hub's")
      ;; and once the session is quiet (no event will come): a new editor still gets the whole transcript
      (drgnx-agents-mirror-stop) (drgnx-hub-disconnect) (setq drgnx-agents--sessions nil)
      (drgnx-agents-mirror-sync)
      (drgnx-agents-mirror-show id)
      (drgnx-agents-mirror-test--settle
       (lambda () (let ((m (drgnx-agents-mirror-test--mirror id))) (and m (setq again m) (equal (drgnx-agent-session-entries m) hub))))
       "the whole transcript in a third editor's mirror")
      (drgnx-test-deliver-all)
      (should again))))

;; From the old UI list ("a malformed RUN_STARTED aborting the board refresh"): one unreadable record from the
;; hub must not stop the others from being mirrored.
(ert-deftest drgnx-agents-mirror/a-malformed-session-record-does-not-abort-the-sync ()
  (let ((drgnx-agents--sessions nil) (drgnx-hub-event-functions nil) (drgnx-hub-disconnect-functions nil))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-hub-connect) #'ignore)
                  ((symbol-function 'drgnx-hub-call)
                   (lambda (method _params &optional cb)
                     (when (equal method "agents/list")
                       (funcall cb (list :sessions '((:id "bad" :name "cut off" :status "nonsense")
                                                     (:id "s-good" :name "Good" :status "idle")
                                                     42))
                                nil))))
                  ((symbol-function 'drgnx-agents-mirror--fetch) #'ignore))
          (let ((inhibit-message t)) (drgnx-agents-mirror-sync))
          (should (drgnx-agents-mirror-test--mirror "s-good"))
          (should-not (drgnx-agents-mirror-test--mirror "bad")))
      (drgnx-agents-mirror-stop))))

(defmacro drgnx-agents-mirror-test--calls (&rest body)
  "BODY with `drgnx-hub-call' recording each (METHOD . PARAMS); the list, oldest first, is the value."
  (declare (indent 0))
  `(let ((calls nil))
     (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (method params &rest _) (push (cons method params) calls))))
       ,@body)
     (nreverse calls)))

(ert-deftest drgnx-agents-mirror/deliver-sends-agents-send ()
  ;; a free mirror takes the text as a new turn: one `agents/send' that the hub sends only if the session is free (the
  ;; mirror may be stale), and t
  (let ((m (drgnx-agents--make :remote "s-d" :id "s-d" :status 'idle)) (took nil))
    (should (equal (drgnx-agents-mirror-test--calls (setq took (drgnx-agents-deliver m "go on")))
                   '(("agents/send" :id "s-d" :text "go on" :if_free t))))
    (should took))
  ;; one that is not free (busy, paused by a Stop, something queued) or is no mirror gets nothing
  (dolist (s (list (drgnx-agents--make :remote "s-d" :id "s-d" :status 'busy)
                   (drgnx-agents--make :remote "s-d" :id "s-d" :status 'idle :paused t)
                   (drgnx-agents--make :remote "s-d" :id "s-d" :status 'idle :queue '("waiting"))
                   (drgnx-agents--make :id "s-local" :status 'idle)))
    (let ((took 'unset))
      (should-not (drgnx-agents-mirror-test--calls (setq took (drgnx-agents-deliver s "go on"))))
      (should-not took))))

(ert-deftest drgnx-agents-mirror/deliver-says-when-the-hub-found-the-session-busy ()
  ;; the mirror said idle, the hub's session was busy (a snapshot throttled away): the hub sent nothing and answered
  ;; false, so the caller's DECLINED runs (it tries again when the session is free); an answer of true, or an error
  ;; (said in the echo area), does not
  (let ((m (drgnx-agents--make :remote "s-d" :id "s-d" :status 'idle :name "d")) (declined 0) (cb nil))
    (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (_method _params f) (setq cb f)))
              ((symbol-function 'drgnx-notify) #'ignore))
      (drgnx-agents-deliver m "go on" (lambda () (cl-incf declined)))
      (funcall cb t nil)
      (should (= declined 0))
      (funcall cb :false nil)
      (should (= declined 1))
      (funcall cb nil "boom")
      (should (= declined 1)))))

(ert-deftest drgnx-agents-mirror/steer-sends-steer ()
  ;; a steer is an `agents/send': the hub steers a busy session under mode `steer', else queues; t says the hub steers
  (let ((m (drgnx-agents--make :remote "s-t" :id "s-t" :status 'busy :mode 'steer)) (steered nil))
    (should (equal (drgnx-agents-mirror-test--calls (setq steered (drgnx-agents-steer m "left, not right")))
                   '(("agents/send" :id "s-t" :text "left, not right"))))
    (should steered))
  (let ((m (drgnx-agents--make :remote "s-t" :id "s-t" :status 'busy :mode 'queue)) (steered 'unset))
    (should (drgnx-agents-mirror-test--calls (setq steered (drgnx-agents-steer m "later"))))
    (should-not steered))
  (let ((s (drgnx-agents--make :id "s-local" :status 'busy :mode 'steer)))
    (should-not (drgnx-agents-mirror-test--calls (drgnx-agents-steer s "nobody to ask")))))

(ert-deftest drgnx-agents-mirror/a-malformed-transcript-entry-does-not-lose-the-others ()
  (let ((m (drgnx-agents--make :remote "s-x" :id "s-x")))
    (let ((inhibit-message t))
      (drgnx-agents-mirror--apply-entries m '((0 (:text "one")) (1 (:type "bogus")) (2 (:text "three")))))
    (should (equal (plist-get (nth 0 (drgnx-agent-session-entries m)) :text) "one"))
    (should (equal (plist-get (nth 2 (drgnx-agent-session-entries m)) :text) "three"))))

(ert-deftest drgnx-agents-mirror/an-old-snapshot-never-overwrites ()
  ;; a snapshot that came while the transcript was fetched, numbered before the fetch's answer, is older than it
  (let ((drgnx-agents--sessions nil) (answer nil))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-hub-call)
                   (lambda (method _params &optional cb) (when (equal method "agents/get") (setq answer cb)))))
          (let ((m (drgnx-agents--make :remote "s-o" :id "s-o")))
            (push m drgnx-agents--sessions)
            (drgnx-agents-mirror--fetch m)
            (drgnx-agents-mirror--event "agent" (list :id "s-o" :seq 3 :session '(:id "s-o" :name "old" :status "busy")))
            (funcall answer (list :seq 5 :session '(:id "s-o" :name "new" :status "idle") :entries '((:text "hi"))) nil)
            (should (equal (drgnx-agent-session-name m) "new"))
            (should (eq (drgnx-agent-session-status m) 'idle))
            ;; and later, live: an older number is skipped, a newer one applied
            (drgnx-agents-mirror--event "agent" (list :id "s-o" :seq 5 :session '(:id "s-o" :name "old" :status "busy")))
            (should (equal (drgnx-agent-session-name m) "new"))
            (drgnx-agents-mirror--event "agent" (list :id "s-o" :seq 6 :session '(:id "s-o" :name "newer" :status "idle")))
            (should (equal (drgnx-agent-session-name m) "newer"))))
      (drgnx-agents-mirror-stop))))

(ert-deftest drgnx-agents-mirror/a-record-that-does-not-decode-is-skipped ()
  ;; not an object, or an unknown entry type: never a snapshot or an entry
  (let ((drgnx-agents--sessions nil) (inhibit-message t) (m (drgnx-agents--make :remote "s-n" :id "s-n")))
    (drgnx-agents-mirror--event "agent" (list :id "s-n" :seq 1 :session 42))
    (should-not drgnx-agents--sessions)
    (drgnx-agents-mirror--apply-entries m '((0 (:type "no-such-type" :text "x")) (1 (:type "agent" :text "y"))))
    (should (equal (mapcar (lambda (e) (plist-get e :text)) (drgnx-agent-session-entries m)) '(nil "y")))))

(ert-deftest drgnx-agents-mirror/sessions-and-entries-arrive-as-json ()
  ;; a session from a mock-acp agent in a hub: status and entry types reach the mirror as symbols
  (drgnx-agents-mirror-test--with '()
    (drgnx-agents-mirror-sync)
    (let* ((m (drgnx-agents-mirror-test--start :profile "mock")) (id (drgnx-agent-session-remote m)))
      (drgnx-agents-mirror-show id)
      (drgnx-agents-mirror-test--ask "agents/send" (list :id id :text "hello json"))
      (drgnx-agents-mirror-test--settle (lambda () (string-search "You said: hello json" (drgnx-agents-mirror-test--text m)))
                                        "the answer in the mirror")
      (drgnx-test-deliver-all)
      (should (memq (drgnx-agent-session-status m) '(busy idle)))
      (should (cl-every (lambda (e) (symbolp (plist-get e :type))) (drgnx-agent-session-entries m)))
      (should (memq 'agent (mapcar (lambda (e) (plist-get e :type)) (drgnx-agent-session-entries m)))))))

(ert-deftest drgnx-agents-mirror/no-read-of-hub-data ()
  (let ((drgnx-agents--sessions nil) (inhibit-message t))
    (cl-letf (((symbol-function 'drgnx-hub-call) #'ignore))
      (advice-add 'read-from-string :before #'drgnx-agents-mirror-test--no-read)
      (advice-add 'read :before #'drgnx-agents-mirror-test--no-read)
      (unwind-protect
          (progn
            (drgnx-agents-mirror--event "agent" (list :id "s-r" :seq 1 :session '(:id "s-r" :name "r" :status "idle")))
            (let ((m (drgnx-agents-mirror--find "s-r")))
              (should m)
              (clrhash drgnx-agents-mirror--fetching)       ; the transcript fetch (a no-op call here) is not waited on
              (drgnx-agents-mirror--event "agent-entries" (list :id "s-r" :seq 2 :entries '((0 (:type "agent" :text "hi")))))
              (should (equal (plist-get (car (drgnx-agent-session-entries m)) :text) "hi"))))
        (advice-remove 'read-from-string #'drgnx-agents-mirror-test--no-read)
        (advice-remove 'read #'drgnx-agents-mirror-test--no-read)))))

(defun drgnx-agents-mirror-test--no-read (&rest _) (error "The mirror read hub data as Lisp"))

(ert-deftest drgnx-agents-mirror/not-enforced-label ()
  (let ((drgnx-agents--sessions nil) (drgnx-agents-mirror--lock (make-hash-table :test #'equal)))
    (cl-letf (((symbol-function 'drgnx-notify) #'ignore))
      (let* ((snap (drgnx-records-from-json 'drgnx-records-session
                                            '(:id "h1" :name "a" :status "idle" :enforced_why "no sandbox here")))
             (m (car (drgnx-agents-mirror--apply-snapshot snap)))
             (ok (car (drgnx-agents-mirror--apply-snapshot
                       (drgnx-records-from-json 'drgnx-records-session '(:id "h2" :name "b" :status "idle" :enforced t))))))
        (should (equal (drgnx-agents-mirror-lock-label m) "not enforced: no sandbox here"))
        (should-not (drgnx-agents-mirror-lock-label ok))))))

;;;; The editor's agent hooks run for sessions the hub holds

(defun drgnx-agents-mirror-test--snap (status &optional task)
  "A hub snapshot of the session \"h-t\" in STATUS (a string), working on TASK."
  (drgnx-records-from-json 'drgnx-records-session
                           (append (list :id "h-t" :name "t" :profile "mock" :cwd "/w" :status status)
                                   (and task (list :task task)))))

(defmacro drgnx-agents-mirror-test--hooks (events &rest body)
  "BODY with `drgnx-agents-task-functions' pushing (EVENT . MIRROR-ID) onto EVENTS (a variable, newest first)."
  (declare (indent 1))
  `(let ((drgnx-agents--sessions nil) (inhibit-message t) (drgnx-agents-mirror--turns (make-hash-table :test #'equal))
         (drgnx-agents-mirror--seq (make-hash-table :test #'equal))
         (drgnx-agents-task-functions
          (list (lambda (s event) (push (cons event (drgnx-agent-session-remote s)) ,events)))))
     (cl-letf (((symbol-function 'drgnx-notify) #'ignore))
       ,@body)))

(ert-deftest drgnx-agents-mirror/task-turn-end-fires-once ()
  (let (events)
    (drgnx-agents-mirror-test--hooks events
      (drgnx-agents-mirror--apply-snapshot (drgnx-agents-mirror-test--snap "idle" "T#1"))
      (should (equal (reverse events) '((start . "h-t"))))                  ; first seen: start, nothing else
      (drgnx-agents-mirror--apply-snapshot (drgnx-agents-mirror-test--snap "busy" "T#1"))
      (drgnx-agents-mirror--apply-snapshot (drgnx-agents-mirror-test--snap "idle" "T#1"))
      (should (equal (reverse events) '((start . "h-t") (turn-start . "h-t") (turn-end . "h-t"))))
      ;; a second turn: once more each
      (drgnx-agents-mirror--apply-snapshot (drgnx-agents-mirror-test--snap "busy" "T#1"))
      (drgnx-agents-mirror--apply-snapshot (drgnx-agents-mirror-test--snap "idle" "T#1"))
      (should (= 2 (cl-count 'turn-end events :key #'car)))
      (should (= 2 (cl-count 'turn-start events :key #'car)))
      (should (= 1 (cl-count 'start events :key #'car))))))

(ert-deftest drgnx-agents-mirror/resent-snapshot-fires-nothing ()
  (let (events)
    (drgnx-agents-mirror-test--hooks events
      (dolist (status '("idle" "busy" "busy" "idle" "idle"))
        (drgnx-agents-mirror--apply-snapshot (drgnx-agents-mirror-test--snap status "T#1")))
      (should (equal (mapcar #'car (reverse events)) '(start turn-start turn-end))))
    ;; a session with no task runs no task hook at all
    (let (none)
      (drgnx-agents-mirror-test--hooks none
        (dolist (status '("idle" "busy" "idle"))
          (drgnx-agents-mirror--apply-snapshot (drgnx-agents-mirror-test--snap status)))
        (should-not none)))))

(ert-deftest drgnx-agents-mirror/a-turn-with-no-busy-snapshot-ends-at-its-stop-entry ()
  ;; the hub sends a session's state at most every 50 ms: a short turn can be idle both before and after it
  (let (events)
    (drgnx-agents-mirror-test--hooks events
      (drgnx-agents-mirror--apply-snapshot (drgnx-agents-mirror-test--snap "idle" "T#1"))
      (let ((turn (lambda (seq i)
                    (drgnx-agents-mirror--event
                     "agent-entries" (list :id "h-t" :seq seq
                                           :entries (list (list i '(:type "user" :text "go")) (list (1+ i) '(:type "stop" :stop "EndTurn"))))))))
        (funcall turn 1 0)
        (should (equal (mapcar #'car (reverse events)) '(start turn-start turn-end)))
        ;; the same entries again (a resent event, a later number): nothing
        (funcall turn 2 0)
        (should (= 3 (length events)))
        ;; the next turn's entries: one more turn
        (funcall turn 3 2)
        (should (= 2 (cl-count 'turn-end events :key #'car)))
        (should (= 2 (cl-count 'turn-start events :key #'car)))))))

(ert-deftest drgnx-agents-mirror/a-failed-turn-ends-at-its-error-entry ()
  ;; a turn that fails writes an `error' entry (marked `stop': it ends the turn), not a `stop' one; with its busy
  ;; status throttled away it must still run `turn-end', once; an error in the middle of a turn (a refused wait) is
  ;; not marked and ends nothing
  (let (events)
    (drgnx-agents-mirror-test--hooks events
      (drgnx-agents-mirror--apply-snapshot (drgnx-agents-mirror-test--snap "idle" "T#1"))
      (let ((turn (lambda (seq i)
                    (drgnx-agents-mirror--event
                     "agent-entries" (list :id "h-t" :seq seq
                                           :entries (list (list i '(:type "user" :text "go"))
                                                          (list (1+ i) '(:type "error" :text "boom" :stop "Error"))))))))
        (funcall turn 1 0)
        (should (equal (mapcar #'car (reverse events)) '(start turn-start turn-end)))
        (funcall turn 2 0)                  ; the same entries again: nothing
        (should (= 3 (length events)))
        (funcall turn 3 2)                  ; the next failed turn: one more
        (should (= 2 (cl-count 'turn-end events :key #'car)))
        (should (= 2 (cl-count 'turn-start events :key #'car))))
      ;; a refused wait inside a turn: no end
      (drgnx-agents-mirror--event "agent-entries" (list :id "h-t" :seq 4
                                                        :entries (list (list 4 '(:type "error" :text "your job runs")))))
      (should (= 2 (cl-count 'turn-end events :key #'car))))))

(ert-deftest drgnx-agents-mirror/a-turn-the-status-ended-is-not-ended-again-by-its-error-entry ()
  (let (events)
    (drgnx-agents-mirror-test--hooks events
      (dolist (status '("idle" "busy" "idle"))
        (drgnx-agents-mirror--apply-snapshot (drgnx-agents-mirror-test--snap status "T#1")))
      (drgnx-agents-mirror--event "agent-entries"
                                  (list :id "h-t" :seq 1 :entries (list (list 0 '(:type "error" :text "boom" :stop "Error")))))
      (should (equal (mapcar #'car (reverse events)) '(start turn-start turn-end))))))

(ert-deftest drgnx-agents-mirror/a-turn-the-status-ended-is-not-ended-again-by-its-stop-entry ()
  (let (events)
    (drgnx-agents-mirror-test--hooks events
      (dolist (status '("idle" "busy" "idle"))
        (drgnx-agents-mirror--apply-snapshot (drgnx-agents-mirror-test--snap status "T#1")))
      (drgnx-agents-mirror--event "agent-entries" (list :id "h-t" :seq 1 :entries (list (list 0 '(:type "stop" :stop "EndTurn")))))
      (should (equal (mapcar #'car (reverse events)) '(start turn-start turn-end))))))

(ert-deftest drgnx-agents-mirror/a-session-first-seen-busy-starts-its-turn ()
  (let (events)
    (drgnx-agents-mirror-test--hooks events
      (drgnx-agents-mirror--apply-snapshot (drgnx-agents-mirror-test--snap "busy" "T#1"))
      (should (equal (mapcar #'car (reverse events)) '(start turn-start))))))

(ert-deftest drgnx-agents-mirror/env-functions-reach-start ()
  ;; the functions' NAME=value strings go to agents/start as `env' when the name is on `drgnx-agents-start-env-names' and
  ;; is no credential; the others are dropped, with one notice naming them; the session they saw is the mirror
  (let* ((drgnx-agents--sessions nil) (inhibit-message t) (calls nil) (notices nil) (seen nil)
         (drgnx-agents-env-functions
          (list (lambda (s) (push s seen)
                  (list "PLAYWRIGHT_MCP_CDP_ENDPOINT=http://127.0.0.1:9222" "OPENAI_API_KEY=sk-x" "OTHER=1"))
                (lambda (_s) (error "Boom"))))
         (drgnx-hub-event-functions (list #'drgnx-agents-mirror--event)))
    (cl-letf (((symbol-function 'drgnx-notify) (lambda (_src _sev text &rest _) (push text notices)))
              ((symbol-function 'drgnx-hub-call) #'ignore)
              ((symbol-function 'drgnx-hub-call-sync)
               (lambda (method params &optional _timeout)
                 (push (cons method params) calls)
                 ;; the hub's event comes before its reply
                 (drgnx-agents-mirror--event "agent" (list :id "h-e" :seq 1
                                                           :session (list :id "h-e" :name "e" :profile "mock" :cwd "/w" :status "idle")))
                 (list :id "h-e" :name "e"))))
      (let* ((m (unwind-protect (drgnx-agents-mirror-start "mock" "/w/") (drgnx-agents-mirror-stop)))
             (start (cdr (assoc "agents/start" calls))))
        (should (equal (plist-get start :env) [(:name "PLAYWRIGHT_MCP_CDP_ENDPOINT" :value "http://127.0.0.1:9222")]))
        (should (equal (plist-get start :profile) "mock"))
        (should (equal (drgnx-agent-session-remote m) "h-e"))
        (should (eq m (car seen)))                         ; what the functions kept of the session is the mirror
        (should (eq m (car drgnx-agents--sessions)))
        (should (= 1 (length (seq-filter (lambda (n) (string-search "OPENAI_API_KEY" n)) notices))))
        (should (cl-some (lambda (n) (and (string-search "OTHER" n) (string-search "OPENAI_API_KEY" n))) notices))))))

(ert-deftest drgnx-agents-mirror/no-env-functions-no-env ()
  (let ((drgnx-agents--sessions nil) (inhibit-message t) (calls nil) (drgnx-agents-env-functions nil)
        (drgnx-hub-event-functions (list #'drgnx-agents-mirror--event)))
    (cl-letf (((symbol-function 'drgnx-hub-call) #'ignore)
              ((symbol-function 'drgnx-hub-call-sync)
               (lambda (method params &optional _timeout)
                 (push (cons method params) calls)
                 (if (equal method "agents/get")
                     (list :session (list :id "h-n" :name "n" :status "idle"))
                   (list :id "h-n" :name "n")))))
      (unwind-protect (drgnx-agents-mirror-start "mock" "/w/") (drgnx-agents-mirror-stop))
      (should-not (plist-member (cdr (assoc "agents/start" calls)) :env)))))

(ert-deftest drgnx-agents-mirror/start-goes-through-the-hub ()
  ;; a real Ratatoskr (mock profile): the editor's start is the hub's agents/start, and the mirror follows the session
  ;; The mirror is already syncing (the hook is on), so the start does not ask for the hub: the hub runs.  The start's
  ;; answer reaches the editor before the session's snapshot (the gate holds that line), so the start fetches the
  ;; session itself.
  (drgnx-agents-mirror-test--with '((call-1 :answer "agents/start") (call-1 :answer "agents/get"))
    (drgnx-agents-mirror-sync)
    (let* ((m (drgnx-agents-mirror-start "mock" root)) (id (drgnx-agent-session-remote m))
           (listed (seq-find (lambda (s) (equal (plist-get s :id) id))
                             (plist-get (drgnx-agents-mirror-test--ask "agents/list" nil) :sessions))))
      (drgnx-agents-mirror-test--settle (lambda () (eq (drgnx-agent-session-status m) 'idle)) "the mirror is idle")
      (drgnx-agents-mirror-show id)
      (drgnx-agents-send m "hello hub")
      (drgnx-agents-mirror-test--settle (lambda () (string-search "hello hub" (drgnx-agents-mirror-test--text m)))
                                        "the mirror follows the session")
      (drgnx-test-deliver-all)
      (should (stringp id))
      (should listed)
      (should-not (drgnx-agent-session-conn m)))))                  ; the agent runs in the hub

;;; agents-mirror-test.el ends here
