;;; mod-cockpit-feed-test.el --- batch tests: what happened, answers, the timeline, questions everywhere -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-agents)
(load (expand-file-name "test/fixtures/cockpit-fixture" drgnx-dir) nil t)   ; a project, a job, worktrees, events
(load (expand-file-name "modules/tools/drgnx-cockpit" drgnx-dir) nil t)
(load (expand-file-name "modules/ui/drgnx-statusbar" drgnx-dir) nil t)   ; what needs you, counted once in the bar
(load (expand-file-name "modules/tools/drgnx-job-ui" drgnx-dir) nil t)
(defvar drgnx-job-ui--badge)
(defvar drgnx-job-ui--badge-job)
(defvar drgnx-job-ui--needs-you)

(defvar drgnx-cockpit-feed-test--hub nil "The hub calls a test saw, newest first: ((METHOD PARAMS)…).")

(defmacro drgnx-cockpit-feed-test--with (&rest body)
  "BODY in the cockpit fixture: the hub's sessions the fixture's, mirrors M1 (of s-1) and M2 (of s-2, busy) in this
Emacs, the hub stubbed (it records each call in `drgnx-cockpit-feed-test--hub' and answers at once), nothing ever
stopped (`drgnx-agents-stop' fails the test).  The feed's buffers are killed after, and they owned their hooks."
  (declare (indent 0))
  `(drgnx-cockpit-fixture-with
     (let* ((drgnx-cockpit-feed--buffers nil)
            (drgnx-cockpit-feed--waiting nil) (drgnx-cockpit-feed-test--hub nil)
            (drgnx-cockpit-feed--told nil) (drgnx-cockpit-feed--in-flight nil)
            (drgnx-cockpit-graph-current-filter nil)
            (drgnx-cockpit--silent nil) (drgnx-cockpit--silent-at (float-time))
            (m1 (drgnx-agents--make :id "m-1" :remote "s-1" :name "claude · jx#2" :status 'idle :job "jx" :task "jx#2"))
            (m2 (drgnx-agents--make :id "m-2" :remote "s-2" :name "chat" :status 'busy :mode 'queue))
            (mirrors (list m1 m2))
            (config (current-window-configuration)))
       (ignore m1 m2)
       (cl-letf (((symbol-function 'drgnx-cockpit-sessions) (lambda () sessions))
                 ;; a UTF-8 terminal whatever the locale (CI's C locale is not): the ASCII tests say so themselves
                 ((symbol-function 'drgnx-cockpit-graph--ascii-p) #'ignore)
                 ((symbol-function 'drgnx-agents-sessions) (lambda () mirrors))
                 ((symbol-function 'drgnx-hub-call)
                  (lambda (method params cb) (push (list method params) drgnx-cockpit-feed-test--hub) (funcall cb t nil) 1))
                 ((symbol-function 'drgnx-agents-stop) (lambda (&rest _) (ert-fail "an answer stopped an agent")))
                 ((symbol-function 'drgnx-agents-kill) (lambda (&rest _) (ert-fail "an answer killed an agent"))))
         (unwind-protect
             (save-window-excursion
               (delete-other-windows)
               ,@body)
           (dolist (b (buffer-list))
             (when (string-match-p "\\`\\*\\(happened: .*\\|Timeline\\|timeline: .*\\|Work Graph\\)\\*\\'" (buffer-name b))
               (kill-buffer b)))
           (should-not drgnx-cockpit-feed--buffers)
           (should-not (drgnx-timer-active-p 'cockpit-feed-update))
           (should-not (drgnx-timer-active-p 'cockpit-feed-check))
           (should-not (memq #'drgnx-cockpit-feed--hub-event (bound-and-true-p drgnx-hub-event-functions)))
           (should-not (memq #'drgnx-cockpit-feed--agent-changed drgnx-agents-changed-functions))
           (set-window-configuration config))))))

(defun drgnx-cockpit-feed-test--tick ()
  "Run the feed's update on its way now, as its timer would."
  (should (drgnx-timer-active-p 'cockpit-feed-update))
  (drgnx-timer-cancel 'cockpit-feed-update)
  (drgnx-cockpit-feed--tick))

(defun drgnx-cockpit-feed-test--question (pred)
  "The open question PRED accepts (`drgnx-cockpit-feed--questions')."
  (or (seq-find pred (drgnx-cockpit-feed--questions)) (ert-fail "no such question")))

(defun drgnx-cockpit-feed-test--open-p (qid)
  (memql qid (mapcar (lambda (q) (plist-get q :id)) (drgnx-coord-open-questions))))

(defun drgnx-cockpit-feed-test--line (text)
  "The line of the current buffer holding TEXT."
  (save-excursion
    (goto-char (point-min))
    (should (search-forward text nil t))
    (buffer-substring (line-beginning-position) (line-end-position))))

(defmacro drgnx-cockpit-feed-test--changes (buffer &rest body)
  "BODY, then the changes it made to BUFFER's text: ((BEG END OLD-LENGTH)…)."
  (declare (indent 1))
  `(let ((changes nil))
     (with-current-buffer ,buffer
       (add-hook 'after-change-functions (lambda (b e l) (push (list b e l) changes)) nil t))
     ,@body
     (with-current-buffer ,buffer (kill-local-variable 'after-change-functions))
     changes))

(ert-deftest drgnx-cockpit-feed/happened-lines-and-transcript-link ()
  (drgnx-cockpit-feed-test--with
    (let ((b (drgnx-cockpit-feed-happened-buffer "s-1")) (opened nil) (transcripts nil)
          (mark (alist-get 'waiting (drgnx-cockpit-graph--glyph-table))))
      (set-window-buffer (selected-window) b)
      (should (equal (buffer-name b) "*happened: s-1*"))
      (with-current-buffer b
        ;; one line per event, newest at the bottom: the decision, the edit, the tests, the question
        (let* ((text (buffer-string))
               (at (mapcar (lambda (s) (or (string-search s text) (ert-fail (list "missing" s text))))
                           '("decided #1 build: the parser" "edited 2 files: a.el, b.el" "tests 12/12 ✓ (make test)"
                             "asks: which way?" "Open the full transcript ▸" "Reply… (queues, never interrupts)"))))
          (should (equal at (sort (copy-sequence at) #'<))))
        ;; the open question is marked, in the waiting face, and on the head line too (however far its line scrolls)
        (let ((head (buffer-substring (point-min) (line-end-position 1))))
          (should (string-search (concat mark " asks you: which way?") head))
          (should (eq (get-text-property (string-search mark head) 'face head) 'drgnx-cockpit-waiting)))
        (let ((line (drgnx-cockpit-feed-test--line "asks: which way?")))
          (should (string-search (concat mark " asks: which way?") line))
          (should (eq (get-text-property (string-search mark line) 'face line) 'drgnx-cockpit-waiting)))
        ;; each line is a button to its target: the edit's is its task's node (plan task 2)
        (let ((drgnx-cockpit-open-functions `((task . ,(lambda (n) (push (plist-get n :id) opened))))))
          (goto-char (point-min)) (search-forward "edited 2 files")
          (push-button (point))
          (should (equal opened (list (format "task:%s#2" plan)))))
        ;; the transcript, one click away
        (cl-letf (((symbol-function 'drgnx-agents-ui-transcript) (lambda (s) (push s transcripts))))
          (goto-char (point-min)) (search-forward "Open the full transcript")
          (push-button (point)))
        (should (equal transcripts (list m1))))
      ;; a new event is appended under the others: nothing above it is drawn again
      (let* ((footer (marker-position (buffer-local-value (quote drgnx-cockpit-feed--end) b)))
             (before (with-current-buffer b (buffer-substring-no-properties (point-min) footer)))
             (changes (drgnx-cockpit-feed-test--changes b
                        (drgnx-coord-event-add :agent "s-1" :job "jx" :task "jx#2" :kind "edit" :summary "1 file"
                                               :data (list :root tree :paths '("c.el")))
                        (drgnx-cockpit-feed-schedule)
                        (drgnx-cockpit-feed-test--tick))))
        (should changes)
        (dolist (c changes) (should (>= (car c) footer)))
        (with-current-buffer b
          (should (string-prefix-p before (buffer-string)))
          (should (< (string-search "asks: which way?" (buffer-string)) (string-search "edited 1 file: c.el" (buffer-string))
                     (string-search "Open the full transcript" (buffer-string))))))
      ;; nothing new: nothing drawn
      (should-not (drgnx-cockpit-feed-test--changes b (drgnx-cockpit-feed-schedule) (drgnx-cockpit-feed-test--tick)))
      ;; more than its window holds: the oldest go, the newest stays in view, the window's point and start stay
      (let ((w (selected-window)))
        (set-window-point w 1)                ; where it starts (the buttons above moved it)
        (should (= 1 (window-point w) (window-start w)))
        (dotimes (i 30)
          (drgnx-coord-event-add :agent "s-1" :job "jx" :task "jx#2" :kind "edit" :data (list :paths (list (format "f%d.el" i)))))
        (drgnx-cockpit-feed-schedule)
        (drgnx-cockpit-feed-test--tick)
        (with-current-buffer b
          (should (= drgnx-cockpit-feed--lines (- (window-body-height w) 4)))
          (should (<= (count-lines (point-min) (point-max)) (window-body-height w)))
          (should (string-search "edited 1 file: f29.el" (buffer-string)))
          (should-not (string-search "decided #1" (buffer-string))))
        (should (= 1 (window-point w) (window-start w)))))
    ;; an outside agent has no transcript here; a reply still goes to it
    (let ((b (drgnx-cockpit-feed-happened-buffer "ext:claude-code:42")))
      (with-current-buffer b
        (should (string-search "edited 2 files: README, new.txt" (buffer-string)))
        (should (string-search "no transcript: an outside agent" (buffer-string)))
        (should-not (string-search "Open the full transcript" (buffer-string)))
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "carry on")))
          (goto-char (point-min)) (search-forward "Reply…")
          (push-button (point))))
      (should (equal (mapcar (lambda (m) (plist-get m :text)) (drgnx-coord-inbox "ext:claude-code:42" '("queued")))
                     '("carry on"))))))

(ert-deftest drgnx-cockpit-feed/a-silent-worktree-says-how-to-make-it-report ()
  (drgnx-cockpit-feed-test--with
    (should (eq (drgnx-cockpit-feed--footer-key "silent:/work/wt-b") 'silent))
    (let ((text (drgnx-cockpit-feed--footer-text "silent:/work/wt-b" 'silent)))
      (should (string-search "not reporting — add drgnx on its settings page" text))
      (should-not (string-search "an outside agent" text)))
    ;; a terminal that does not write UTF-8 gets ASCII
    (cl-letf (((symbol-function 'drgnx-cockpit-graph--ascii-p) #'always))
      (let ((text (drgnx-cockpit-feed--footer-text "silent:/work/wt-b" 'silent)))
        (should (string-search "not reporting - add drgnx on its settings page" text))
        (should-not (string-match-p "[^[:ascii:]]" text))))))

(ert-deftest drgnx-cockpit-feed/answer-routes-by-kind-of-agent ()
  (drgnx-cockpit-feed-test--with
    (drgnx-coord-send :sender "ext:claude-code:42" :recipient "user" :text "[escalation] rename it?" :question t)
    (drgnx-coord-send :sender "s-2" :recipient "user" :text "[escalation] tabs or spaces?" :question t)
    (let* ((job-q (drgnx-cockpit-feed-test--question (lambda (q) (equal (plist-get q :agent) "s-1"))))
           (ext-q (drgnx-cockpit-feed-test--question (lambda (q) (equal (plist-get q :agent) "ext:claude-code:42"))))
           (native-q (drgnx-cockpit-feed-test--question (lambda (q) (equal (plist-get q :agent) "s-2"))))
           (card-q (drgnx-cockpit-feed-test--question (lambda (q) (plist-get q :card))))
           (answers (lambda (qid) (seq-filter (lambda (e) (equal (plist-get (plist-get e :data) :question) qid))
                                              (drgnx-coord-events :kinds '("answer"))))))
      ;; a job's message: the hub's job/reply, and an answer event closes it
      (should (eq (drgnx-cockpit-answer job-q "this way") 'job))
      (should (equal (car drgnx-cockpit-feed-test--hub)
                     (list "job/reply" (list :message (plist-get (plist-get job-q :data) :message) :text "this way"))))
      (should-not (drgnx-cockpit-feed-test--open-p (plist-get job-q :id)))
      (should (equal (mapcar (lambda (e) (plist-get e :summary)) (funcall answers (plist-get job-q :id))) '("this way")))
      ;; an outside agent: a message to it, in the store (it reads its inbox)
      (setq drgnx-cockpit-feed-test--hub nil)
      (should (eq (drgnx-cockpit-answer ext-q "yes, rename") 'message))
      (should (equal (mapcar (lambda (m) (plist-get m :text)) (drgnx-coord-inbox "ext:claude-code:42" '("queued"))) '("yes, rename")))
      (should (equal (plist-get (drgnx-coord-message-answers (plist-get (car (drgnx-coord-inbox "ext:claude-code:42")) :id)) :id)
                     (plist-get (plist-get ext-q :data) :message)))   ; the hub names the question it answers
      (should-not (assoc "agents/send" drgnx-cockpit-feed-test--hub))
      (should-not (drgnx-cockpit-feed-test--open-p (plist-get ext-q :id)))
      ;; a native session (busy): the hub's agents/send, which queues
      (should (eq (drgnx-cockpit-answer native-q "spaces") 'session))
      (should (equal (assoc "agents/send" drgnx-cockpit-feed-test--hub) (list "agents/send" (list :id "s-2" :text "spaces"))))
      (should-not (drgnx-cockpit-feed-test--open-p (plist-get native-q :id)))
      (should (equal (plist-get (drgnx-coord-message (plist-get (plist-get native-q :data) :message)) :state) "acted"))
      ;; an ask card: settled through the store, which writes the answer
      (should (eq (drgnx-cockpit-answer card-q "bar") 'card))
      (should (equal (plist-get (drgnx-coord-card (plist-get card-q :card)) :choice) "bar"))
      (should-not (seq-find (lambda (q) (plist-get q :card)) (drgnx-cockpit-feed--questions)))
      ;; a permission: answered in its transcript, which opens at it; nothing is written or sent
      (setf (drgnx-agent-session-permissions m2) (list (list :id 7 :title "Write a.el")))
      (nconc (nth 1 sessions) (list :permissions (list (list :id 7 :title "Write a.el"))))
      (let ((perm (drgnx-cockpit-feed-test--question (lambda (q) (equal (plist-get q :kind) "permission"))))
            (events (length (drgnx-coord-events))) (shown nil))
        (should (equal (plist-get perm :agent) "s-2"))
        (setq drgnx-cockpit-feed-test--hub nil)
        (cl-letf (((symbol-function 'drgnx-agents-ui-transcript) (lambda (s) (push s shown))))
          (should (eq (drgnx-cockpit-answer perm nil) 'transcript)))
        (should (equal shown (list m2)))
        (should-not drgnx-cockpit-feed-test--hub)
        (should (= events (length (drgnx-coord-events))))))))

(ert-deftest drgnx-cockpit-feed/answers-never-interrupt ()
  (drgnx-cockpit-feed-test--with
    (let ((prompts nil))
      (cl-letf (((symbol-function 'drgnx-agents--prompt) (lambda (s text) (push (list s text) prompts)))
                ((symbol-function 'drgnx-agents-steer) (lambda (&rest _) (ert-fail "a queued answer steered"))))
        ;; a session of this Emacs whose mode interrupts, busy: the answer waits in its queue, nothing is stopped
        (let ((busy (drgnx-agents--make :id "s-4" :name "busy" :status 'busy :mode 'interrupt))
              (idle (drgnx-agents--make :id "s-5" :name "idle" :status 'idle :mode 'interrupt :acp-id "acp-5")))
          (setq mirrors (append (list busy idle) mirrors))
          (drgnx-coord-send :sender "s-4" :recipient "user" :text "[escalation] keep going?" :question t)
          (should (eq (drgnx-cockpit-answer (drgnx-cockpit-feed-test--question (lambda (q) (equal (plist-get q :agent) "s-4"))) "yes")
                      'session))
          (should (equal (drgnx-agent-session-queue busy) '("yes")))
          (should (eq (drgnx-agent-session-mode busy) 'interrupt))          ; its mode is its own again
          (should-not prompts)
          (should-not (drgnx-coord-inbox "s-4" '("queued")))
          ;; …idle: the answer starts its turn
          (drgnx-coord-send :sender "s-5" :recipient "user" :text "[escalation] start?" :question t)
          (should (eq (drgnx-cockpit-answer (drgnx-cockpit-feed-test--question (lambda (q) (equal (plist-get q :agent) "s-5"))) "go")
                      'session))
          (should (equal prompts (list (list idle "go"))))
          (should (eq (drgnx-agent-session-mode idle) 'interrupt))
          (setq prompts nil))
        ;; a hub session's mirror whose mode interrupts: the answer waits in the store, the hub gives it when it is free
        (setf (drgnx-agent-session-mode m2) 'interrupt)
        (drgnx-coord-send :sender "s-2" :recipient "user" :text "[escalation] which file?" :question t)
        (let ((q (drgnx-cockpit-feed-test--question (lambda (q) (equal (plist-get q :agent) "s-2")))))
          (should (eq (drgnx-cockpit-answer q "a.el") 'message))
          (should (equal (mapcar (lambda (m) (plist-get m :text)) (drgnx-coord-inbox "s-2" '("queued"))) '("a.el")))
          (should-not (drgnx-cockpit-feed-test--open-p (plist-get q :id))))
        ;; a session of this Emacs, busy, in the default mode: queued in it
        (let ((local (drgnx-agents--make :id "s-3" :name "local" :status 'busy :mode 'queue)))
          (push local mirrors)
          (drgnx-coord-send :sender "s-3" :recipient "user" :text "[escalation] go on?" :question t)
          (drgnx-cockpit-answer (drgnx-cockpit-feed-test--question (lambda (q) (equal (plist-get q :agent) "s-3"))) "yes")
          (should (equal (drgnx-agent-session-queue local) '("yes")))
          ;; a reply to an agent with no question: queued too
          (drgnx-cockpit-feed-reply "s-3" "and then stop")
          (should (equal (drgnx-agent-session-queue local) '("yes" "and then stop"))))
        (should-not prompts)                                              ; busy sessions: no turn started
        ;; the hub was never asked to stop, kill or cancel anything
        (dolist (c drgnx-cockpit-feed-test--hub)
          (should-not (member (car c) '("agents/stop" "agents/kill")))
          (should-not (equal (plist-get (cadr c) :op) "cancel")))))))

(ert-deftest drgnx-cockpit-feed/a-second-answer-waits-for-the-first ()
  (drgnx-cockpit-feed-test--with
    (let ((pending nil))
      ;; a hub that has not answered yet
      (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (method params cb) (push (list method params cb) pending) 1)))
        (let ((q (drgnx-cockpit-feed-test--question (lambda (q) (equal (plist-get q :agent) "s-1")))) (said nil))
          (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (when fmt (push (apply #'format fmt args) said)))))
            (should (eq (drgnx-cockpit-answer q "this way") 'job)))
          ;; through the hub: sent, not yet queued
          (should (equal said '("Answer sent to the hub for claude · jx#2: it never interrupts")))
          (should (drgnx-cockpit-feed-test--open-p (plist-get q :id)))   ; open until the hub answers
          (should-error (drgnx-cockpit-answer q "that way") :type 'user-error)
          (should (= 1 (length pending)))
          ;; the hub answers: the question closes, and a later answer would go again
          (funcall (nth 2 (car pending)) t nil)
          (should-not (drgnx-cockpit-feed-test--open-p (plist-get q :id)))
          (should-not drgnx-cockpit-feed--in-flight)
          ;; a refused call lands too, and closes nothing
          (drgnx-coord-send :sender "s-2" :recipient "user" :text "[escalation] tabs?" :question t)
          (let ((q2 (drgnx-cockpit-feed-test--question (lambda (q) (equal (plist-get q :agent) "s-2")))))
            (drgnx-cockpit-answer q2 "spaces")
            (funcall (nth 2 (car pending)) nil "no such session")
            (should-not drgnx-cockpit-feed--in-flight)
            (should (drgnx-cockpit-feed-test--open-p (plist-get q2 :id)))
            ;; an answer on its way for longer than the timeout (a hub that went away) no longer blocks: it is dropped
            (setq drgnx-cockpit-feed--in-flight (list (cons (plist-get q2 :id) (- (float-time) 60))))
            (should (eq (drgnx-cockpit-answer q2 "spaces") 'session))
            (should (= 1 (length drgnx-cockpit-feed--in-flight)))
            (should (> (cdar drgnx-cockpit-feed--in-flight) (- (float-time) 5)))
            (should-error (drgnx-cockpit-answer q2 "tabs") :type 'user-error)))))))

(ert-deftest drgnx-cockpit-feed/the-status-bar-hears-of-a-new-count ()
  (drgnx-cockpit-feed-test--with
    (let ((refreshes 0))
      (cl-letf (((symbol-function 'drgnx-statusbar-refresh) (lambda (&rest _) (cl-incf refreshes))))
        (drgnx-cockpit-feed-tell-statusbar)
        (should (= refreshes 1))                    ; first told
        (drgnx-cockpit-feed-tell-statusbar)
        (should (= refreshes 1))                    ; the same count: nothing
        ;; another process asks (no hub event): the feed's check tells the bar
        (drgnx-coord-send :sender "ext:claude-code:42" :recipient "user" :text "[escalation] ok?" :question t)
        (drgnx-cockpit-timeline-buffer)             ; a feed buffer lives: its check runs
        (drgnx-cockpit-feed--check)
        (should (= refreshes 2))
        (drgnx-cockpit-feed--check)
        (should (= refreshes 2))
        ;; and so does the graph's
        (drgnx-coord-send :sender "s-2" :recipient "user" :text "[escalation] tabs?" :question t)
        (drgnx-cockpit--check)
        (should (= refreshes 3))
        ;; a store write that changes no count tells nothing
        (drgnx-coord-event-add :agent "s-1" :kind "edit" :data '(:paths ("x.el")))
        (drgnx-cockpit-feed--check)
        (should (= refreshes 3))
        ;; a refresh that fails leaves the count untold: the next check tries again
        (drgnx-coord-send :sender "s-1" :recipient "user" :text "[escalation] and then?" :question t)
        (cl-letf (((symbol-function 'drgnx-statusbar-refresh) (lambda (&rest _) (error "bar broken"))))
          (drgnx-cockpit-feed--check))
        (should (= refreshes 3))
        (drgnx-cockpit-feed--check)
        (should (= refreshes 4))))))

(ert-deftest drgnx-cockpit-feed/timeline-chips-in-time-order ()
  (drgnx-cockpit-feed-test--with
    (let ((b (drgnx-cockpit-timeline-buffer)) (opened nil)
          (mark (alist-get 'waiting (drgnx-cockpit-graph--glyph-table))))
      (set-window-buffer (selected-window) b)
      (with-current-buffer b
        ;; one row per agent, in the order they first did something; its question first (pinned), then the other
        ;; chips left to right by time
        (let ((s1 (drgnx-cockpit-feed-test--line "claude · jx#2")))
          (let ((at (mapcar (lambda (s) (or (string-search s s1) (ert-fail (list "missing" s s1))))
                            (list (concat mark " s-1 asks you") "decision #1" "2 files" "12/12 ✓"))))
            (should (equal at (sort (copy-sequence at) #'<))))
          (should (eq (get-text-property (string-search "s-1 asks you" s1) 'face s1) 'drgnx-cockpit-waiting)))
        (should (string-search "2 files" (drgnx-cockpit-feed-test--line "Claude Code")))
        (should (string-search "started" (drgnx-cockpit-feed-test--line "chat")))
        ;; a chip is a button to its target
        (let ((drgnx-cockpit-open-functions `((task . ,(lambda (n) (push (plist-get n :id) opened))))))
          (goto-char (point-min)) (search-forward "12/12")
          (push-button (point))
          (should (equal opened (list (format "task:%s#2" plan))))))
      ;; a new event: one chip at the right of its row; the other rows stay as they were
      (let ((others (with-current-buffer b (list (drgnx-cockpit-feed-test--line "Claude Code") (drgnx-cockpit-feed-test--line "chat")))))
        (drgnx-coord-set-status "jx#2" "s-1" "done" (drgnx-coord-version))
        (drgnx-cockpit-feed-schedule)
        (drgnx-cockpit-feed-test--tick)
        (with-current-buffer b
          (should (string-suffix-p "T2 ✓" (drgnx-cockpit-feed-test--line "claude · jx#2")))
          (should (equal others (list (drgnx-cockpit-feed-test--line "Claude Code") (drgnx-cockpit-feed-test--line "chat"))))))
      ;; many events: the row fits its window, the newest is shown, the older ones one click away
      (dotimes (i 40)
        (drgnx-coord-event-add :agent "s-1" :job "jx" :task "jx#2" :kind "edit" :data (list :paths (list (format "f%d.el" i)))))
      (drgnx-coord-event-add :agent "s-1" :job "jx" :task "jx#2" :kind "test" :data '(:passed 3 :failed 1))
      (drgnx-cockpit-feed-schedule)
      (drgnx-cockpit-feed-test--tick)
      (with-current-buffer b
        (let ((row (drgnx-cockpit-feed-test--line "claude · jx#2")) (width (window-body-width (get-buffer-window b))))
          (should (< (string-width row) width))
          (should (string-suffix-p "3/4 ⚠" row))
          (should (eq (get-text-property (string-search "3/4 ⚠" row) 'face row) 'drgnx-cockpit-blocked))
          (should (string-match-p "‹ [0-9]+" row))
          (should-not (string-search "decision #1" row))
          (goto-char (point-min)) (search-forward "claude · jx#2") (search-forward "‹")
          (push-button (point))))
      (let ((earlier (get-buffer "*timeline: claude · jx#2*")))
        (should earlier)
        (with-current-buffer earlier
          (should (string-search "decision #1" (buffer-string)))
          (should (< (string-search "decision #1" (buffer-string)) (string-search "3/4 ⚠" (buffer-string)))))))))

(ert-deftest drgnx-cockpit-feed/a-held-answer-is-not-said-to-be-queued ()
  (drgnx-cockpit-feed-test--with
    (drgnx-coord-send :sender "ext:claude-code:42" :recipient "user" :text "[escalation] rename it?" :question t)
    (let ((q (drgnx-cockpit-feed-test--question (lambda (q) (equal (plist-get q :agent) "ext:claude-code:42"))))
          (said nil) (drgnx-coord-queue-limit 0))   ; its queue is full: the store holds the message
      (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (when fmt (push (apply #'format fmt args) said)))))
        (should-not (drgnx-cockpit-answer q "yes")))
      (should (equal said '("Work cockpit: held, not sent — queue full")))
      (should (drgnx-cockpit-feed-test--open-p (plist-get q :id))))))

(ert-deftest drgnx-cockpit-feed/waiting-chips-stay-in-their-row ()
  (drgnx-cockpit-feed-test--with
    (let ((b (drgnx-cockpit-timeline-buffer))
          (mark (alist-get 'waiting (drgnx-cockpit-graph--glyph-table))))
      (set-window-buffer (selected-window) b)
      ;; 80 newer chips in s-1's row and in the jobs row
      (dotimes (i 80)
        (drgnx-coord-event-add :agent "s-1" :job "jx" :task "jx#2" :kind "edit" :data (list :paths (list (format "f%d.el" i))))
        (drgnx-coord-event-add :job "jx" :kind "job" :data '(:status "running")))
      (drgnx-cockpit-feed-schedule)
      (drgnx-cockpit-feed-test--tick)
      (with-current-buffer b
        (let ((s1 (drgnx-cockpit-feed-test--line "claude · jx#2"))
              (jobs (drgnx-cockpit-feed-test--line "jobs ")))
          ;; s-1's question, right after `‹ N', in the waiting face; newer chips made room for it
          (should (string-match (format "‹ [0-9]+ %s s-1 asks you" mark) s1))
          (should (eq (get-text-property (string-search "s-1 asks you" s1) 'face s1) 'drgnx-cockpit-waiting))
          (should (< (string-width s1) (window-body-width)))
          ;; the reopened ask card (no open question names it) is pinned in the jobs row
          (should (string-search (format "%s T3 asks you: Pick a name" mark) jobs))
          (should (eq (get-text-property (string-search "T3 asks you" jobs) 'face jobs) 'drgnx-cockpit-waiting))))
      ;; A on the card's chip settles the card; the chip goes
      (with-current-buffer b
        (goto-char (point-min)) (search-forward "T3 asks you") (goto-char (match-beginning 0))
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "bar")))
          (should (eq (call-interactively #'drgnx-cockpit-answer) 'card))))
      (drgnx-cockpit-feed-test--tick)
      (with-current-buffer b (should-not (string-search "T3 asks you" (buffer-string))))
      ;; two questions, room for one: `‹ N ◐' says a hidden chip waits
      (with-current-buffer b
        (should-not (string-match-p (format "‹ [0-9]+ %s %s" mark mark) (drgnx-cockpit-feed-test--line "claude · jx#2"))))
      (drgnx-coord-send :sender "s-1" :recipient "user" :text "[escalation] and the tests?" :question t :job "jx")
      (let ((drgnx-cockpit-timeline-name-width 60))
        (with-current-buffer b
          (drgnx-cockpit-feed--timeline-build)
          (let ((s1 (drgnx-cockpit-feed-test--line "claude · jx#2")))
            (should (string-match (format "‹ [0-9]+ %s %s s-1 asks you" mark mark) s1))
            (should (eq (get-text-property (match-beginning 0) 'face s1) 'drgnx-cockpit-waiting))))))))

(ert-deftest drgnx-cockpit-feed/an-old-open-question-stays-in-the-timeline ()
  (drgnx-cockpit-feed-test--with
    (let ((mark (alist-get 'waiting (drgnx-cockpit-graph--glyph-table))))
      ;; 310 newer events of another agent, and a test that only failed: s-1's question is outside the timeline's
      ;; 300 events
      (dotimes (i 310) (drgnx-coord-event-add :agent "s-2" :kind "edit" :data (list :paths (list (format "f%d.el" i)))))
      (drgnx-coord-event-add :agent "s-2" :kind "test" :data '(:failed 2))
      (let ((b (drgnx-cockpit-timeline-buffer)))
        (set-window-buffer (selected-window) b)
        (with-current-buffer b
          (let ((s1 (drgnx-cockpit-feed-test--line "claude · jx#2")) (chat (drgnx-cockpit-feed-test--line "chat")))
            (should (string-search (concat mark " s-1 asks you") s1))
            (should (eq (get-text-property (string-search "s-1 asks you" s1) 'face s1) 'drgnx-cockpit-waiting))
            ;; a test with failures only is a failure too
            (should (string-suffix-p "2 failed" chat))
            (should (eq (get-text-property (string-search "2 failed" chat) 'face chat) 'drgnx-cockpit-blocked))))
        ;; answered: it goes from the row
        (drgnx-cockpit-answer (drgnx-cockpit-feed-test--question (lambda (q) (equal (plist-get q :agent) "s-1"))) "this way")
        (drgnx-cockpit-feed-test--tick)
        (with-current-buffer b
          (should-not (string-search "s-1 asks you" (drgnx-cockpit-feed-test--line "claude · jx#2"))))))))

(ert-deftest drgnx-cockpit-feed/a-question-shows-in-all-three-places ()
  (drgnx-cockpit-feed-test--with
    (let* ((b (drgnx-cockpit-timeline-buffer))
           (mark (alist-get 'waiting (drgnx-cockpit-graph--glyph-table)))
           (task5 "agent:s-2")
           (waiting-p (lambda (id) (plist-get (seq-find (lambda (n) (equal (plist-get n :id) id))
                                                        (plist-get (drgnx-cockpit-model :sessions sessions) :nodes))
                                              :waiting)))
           (n0 (drgnx-cockpit-waiting-count)))
      (set-window-buffer (selected-window) b)
      ;; the count the status bar shows leaves to the jobs count what it holds: the escalation of job jx (a message
      ;; of the job) and the reopened card; the timeline's head still counts the model's open questions
      (should (= n0 0))
      (should (= (drgnx-cockpit-feed--head-count) (length (plist-get (drgnx-cockpit-model :sessions sessions) :questions))))
      (should-not (funcall waiting-p task5))
      ;; s-2 asks: the graph marks its task, the status bar's count goes up, the timeline gets a waiting chip
      (drgnx-coord-send :sender "s-2" :recipient "user" :text "[escalation] tabs or spaces?" :question t)
      (should (funcall waiting-p task5))
      (should (= (drgnx-cockpit-waiting-count) (1+ n0)))
      (drgnx-cockpit-feed-schedule)
      (drgnx-cockpit-feed-test--tick)
      (with-current-buffer b
        (let ((row (drgnx-cockpit-feed-test--line "chat")))
          (should (string-search (concat mark " s-2 asks you") row))
          (should (eq (get-text-property (string-search "s-2 asks you" row) 'face row) 'drgnx-cockpit-waiting)))
        (should (string-match-p (format "%s 3 waiting on you" mark) (drgnx-cockpit-feed-test--line "waiting on you"))))
      ;; A on the timeline's chip answers it (queued to the session)
      (with-current-buffer b
        (goto-char (point-min)) (search-forward "s-2 asks you") (goto-char (match-beginning 0))
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "spaces")))
          (call-interactively #'drgnx-cockpit-answer)))
      (should (equal (assoc "agents/send" drgnx-cockpit-feed-test--hub) (list "agents/send" (list :id "s-2" :text "spaces"))))
      (should-not (funcall waiting-p task5))
      (should (= (drgnx-cockpit-waiting-count) n0))
      ;; the chip is calm again (its row drawn again, though the answer is another row's); the window's point, on the
      ;; chip, stays on it, and no window function ran from the timer
      (cl-letf (((symbol-function 'set-window-point) (lambda (&rest _) (ert-fail "the timer moved a window")))
                ((symbol-function 'set-window-start) (lambda (&rest _) (ert-fail "the timer scrolled a window"))))
        (drgnx-cockpit-feed-test--tick))
      (with-current-buffer b
        (should (string-prefix-p "s-2 asks you" (buffer-substring (window-point (get-buffer-window b)) (point-max)))))
      (with-current-buffer b
        (let ((row (drgnx-cockpit-feed-test--line "chat")))
          (should (string-search "s-2 asks you" row))
          (should-not (string-search (concat mark " s-2 asks you") row))
          (should-not (eq (get-text-property (string-search "s-2 asks you" row) 'face row) 'drgnx-cockpit-waiting))))
      ;; A in the graph answers the question about the node on its line (s-1's escalation)
      (let ((g (drgnx-cockpit-graph-buffer)))
        (set-window-buffer (selected-window) g)
        (drgnx-cockpit-graph-redraw t)
        (with-current-buffer g
          (goto-char (point-min))
          (goto-char (prop-match-beginning (text-property-search-forward 'drgnx-cockpit-node "agent:s-1" t)))
          (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "this way")))
            (call-interactively #'drgnx-cockpit-answer))))
      (should (assoc "job/reply" drgnx-cockpit-feed-test--hub))
      (should (= (drgnx-cockpit-waiting-count) n0)))))           ; that one was the jobs count's

(ert-deftest drgnx-cockpit-feed/an-ask-card-is-left-to-the-jobs-count ()
  ;; notices Phase 0: an ask card is a question event naming the card, and the jobs count (C8) holds it already
  (drgnx-cockpit-feed-test--with
    (let ((n0 (drgnx-cockpit-waiting-count)) (h0 (drgnx-cockpit-feed--head-count)))
      (drgnx-coord-card-create :job "jx" :kind "ask" :title "go?")
      (should (= (drgnx-cockpit-waiting-count) n0))
      (should (= (drgnx-cockpit-feed--head-count) (1+ h0))))))

(ert-deftest drgnx-cockpit-feed/a-job-message-question-is-left-to-the-jobs-count ()
  ;; an escalation sent with a job is also a message of the job to you, which the jobs count holds
  (drgnx-cockpit-feed-test--with
    (let ((n0 (drgnx-cockpit-waiting-count)))
      (drgnx-coord-send :sender "s-1" :recipient "user" :text "[escalation] ok?" :job "jx")
      (should (= (drgnx-cockpit-waiting-count) n0))
      (drgnx-coord-send :sender "s-1" :recipient "user" :text "[escalation] ok?")
      (should (= (drgnx-cockpit-waiting-count) (1+ n0))))))

(ert-deftest drgnx-cockpit-feed/an-ask-card-shows-once-in-the-status-bar ()
  ;; the jobs segment's ⚑ and the agents segment's "waiting on you" never both count one ask card
  (drgnx-cockpit-feed-test--with
    (let ((drgnx-statusbar--tick 0) (drgnx-statusbar--agents-state nil) (drgnx-statusbar--jobs-state nil)
          (drgnx-statusbar--refresh-timer nil) (drgnx-statusbar--redraw-wanted nil)
          (drgnx-statusbar--jobs-wanted nil) (drgnx-statusbar--jobs-pending nil) (drgnx-statusbar--errors nil)
          (drgnx-statusbar--state-texts (make-hash-table :test #'eq))
          (drgnx-statusbar--segments (make-hash-table :test #'eq))
          (drgnx-statusbar-waiting-functions (list #'drgnx-statusbar-agents-waiting))
          (drgnx-job-ui--badge "") (drgnx-job-ui--badge-job nil) (drgnx-job-ui--needs-you nil))
      (add-hook 'drgnx-statusbar-waiting-functions #'drgnx-cockpit-waiting-count)   ; as tools/cockpit's setup does
      (drgnx-statusbar--define-defaults)
      (let ((cid (drgnx-coord-card-create :job "jx" :kind "ask" :title "go?"))
            (seg (lambda (id) (when-let* ((s (funcall (plist-get (gethash id drgnx-statusbar--segments) :fn))))
                                (substring-no-properties s)))))
        (drgnx-job-ui-note-jobs (list (list :id "jx" :status "running" :messages nil
                                            :cards (list (list :id cid :kind "ask" :title "go?")))))
        (drgnx-statusbar--refresh-now)
        (should (equal (funcall seg 'jobs) (concat (drgnx-statusbar--glyph 'flag "#") "1")))   ; ⚑1
        (should-not (string-search "waiting on you" (or (funcall seg 'agents) "")))))))

(ert-deftest drgnx-cockpit-feed/terminals-get-the-same-text-in-ascii ()
  (drgnx-cockpit-feed-test--with
    (cl-letf (((symbol-function 'drgnx-cockpit-graph--ascii-p) #'always))
      (let ((h (drgnx-cockpit-feed-happened-buffer "s-1")) (tl (drgnx-cockpit-timeline-buffer)))
        (with-current-buffer h
          (should (string-search "tests 12/12 + (make test)" (buffer-string)))
          (should (string-search "? asks: which way?" (buffer-string)))
          (should (string-search "Open the full transcript >" (buffer-string)))
          (should (string-search "Reply... (queues, never interrupts)" (buffer-string)))
          (should-not (string-match-p "[^[:ascii:]]" (buffer-string))))
        (with-current-buffer tl
          (should (string-search "? s-1 asks you" (buffer-string)))
          (should (string-search "12/12 +" (buffer-string)))
          (should-not (string-match-p "[^[:ascii:]]" (buffer-string))))))))

(ert-deftest drgnx-cockpit-feed/hidden-panes-wait-and-buffers-own-their-hooks ()
  (drgnx-cockpit-feed-test--with
    (let ((b (drgnx-cockpit-timeline-buffer)))
      (should (memq #'drgnx-cockpit-feed--hub-event drgnx-hub-event-functions))
      (should (drgnx-timer-active-p 'cockpit-feed-check))
      ;; hidden: an event only marks it stale; showing it catches up
      (drgnx-coord-event-add :agent "s-2" :kind "stop" :summary "chat ended")
      (drgnx-cockpit-feed--hub-event "agent" nil)
      (when (drgnx-timer-active-p 'cockpit-feed-update) (drgnx-cockpit-feed-test--tick))
      (with-current-buffer b
        (should drgnx-cockpit-feed--stale)
        (should-not (string-search "stopped" (buffer-string))))
      (set-window-buffer (selected-window) b)
      (drgnx-cockpit-feed--on-show (selected-window))
      (drgnx-cockpit-feed-test--tick)
      (with-current-buffer b (should (string-search "stopped" (buffer-string))))
      ;; a transcript's chunk is not news
      (drgnx-cockpit-feed--hub-event "agent-entries" nil)
      (should-not (drgnx-timer-active-p 'cockpit-feed-update))
      ;; the last feed buffer killed: its hooks and timers go (checked by the macro), its markers are released
      (let ((h (drgnx-cockpit-feed-happened-buffer "s-1")))
        (let ((m (buffer-local-value 'drgnx-cockpit-feed--end h)))
          (kill-buffer h)
          (should-not (marker-buffer m)))))))

(ert-deftest drgnx-cockpit-feed/commands-and-keys-in-every-profile ()
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil) (kinds nil)
        (drgnx-statusbar-waiting-functions (list #'drgnx-statusbar-agents-waiting)))
    (cl-letf (((symbol-function 'drgnx-pane-define-kind) (lambda (kind &rest props) (push (cons kind props) kinds))))
      (funcall (plist-get (alist-get 'tools/cockpit drgnx-modules--table) :setup)))
    ;; the questions only the cockpit counts reach the status bar's "waiting on you"
    (should (memq #'drgnx-cockpit-waiting-count drgnx-statusbar-waiting-functions))
    (should (eq (plist-get (alist-get 'happened kinds) :home) 'right))
    (should (eq (plist-get (alist-get 'timeline kinds) :home) 'bottom))
    (pcase-dolist (`(,id ,fn ,map) '((cockpit-answer drgnx-cockpit-answer drgnx-cockpit-map)
                                     (cockpit-happened drgnx-cockpit-happened-show nil)
                                     (cockpit-timeline drgnx-cockpit-timeline-show nil)))
      (should (eq (drgnx-cmd-command (drgnx-commands-get id)) fn))
      (should (eq (drgnx-cmd-map (drgnx-commands-get id)) map))))
  ;; A works in the graph, what happened and the timeline
  (dolist (m (list drgnx-cockpit-graph-mode-map drgnx-cockpit-happened-mode-map drgnx-cockpit-timeline-mode-map))
    (should (keymap-parent m))
    (should (eq (keymap-parent m) drgnx-cockpit-map)))
  (dolist (profile '("vscode" "emacs" "vim"))
    (let ((text (with-temp-buffer (insert-file-contents (expand-file-name (format "keys/%s.eld" profile) drgnx-dir)) (buffer-string))))
      (dolist (row '("(cockpit-answer \"A\")" "(cockpit-happened :none " "(cockpit-timeline :none "))
        (should (string-search row text))))))

(ert-deftest drgnx-cockpit-feed/loads-alone-in-a-fresh-emacs ()
  ;; the modules directory loads cockpit-feed before drgnx-cockpit.el (alphabetical): it must not need the graph's keymap then
  (let* ((emacs (expand-file-name invocation-name invocation-directory))
         (feed (expand-file-name "modules/tools/drgnx-cockpit-feed.el" drgnx-dir))
         (out (with-temp-buffer
                (cons (call-process emacs nil t nil "--batch" "-Q" "-L" (expand-file-name "core" drgnx-dir)
                                    "--eval" (format "(load %S nil t)" feed)
                                    "--eval" "(message \"loaded %S\" (featurep 'drgnx-cockpit-feed))")
                      (buffer-string)))))
    (should (eql (car out) 0))
    (should (string-search "loaded t" (cdr out)))))

;;; mod-cockpit-feed-test.el ends here
