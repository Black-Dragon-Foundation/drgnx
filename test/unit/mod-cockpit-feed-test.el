;;; mod-cockpit-feed-test.el --- batch tests: what happened, answers, the timeline, questions everywhere -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-agents)
(load (expand-file-name "test/fixtures/cockpit-fixture" drgnx-dir) nil t)   ; a project, a job, worktrees, events
(load (expand-file-name "modules/tools/drgnx-cockpit" drgnx-dir) nil t)

(defvar drgnx-cockpit-feed-test--hub nil "The hub calls a test saw, newest first: ((METHOD PARAMS)…).")

(defmacro drgnx-cockpit-feed-test--with (&rest body)
  "BODY in the cockpit fixture: the hub's sessions the fixture's, mirrors M1 (of s-1) and M2 (of s-2, busy) in this
Emacs, the hub stubbed (it records each call in `drgnx-cockpit-feed-test--hub' and answers at once), nothing ever
stopped (`drgnx-agents-stop' fails the test).  The feed's buffers are killed after, and they owned their hooks."
  (declare (indent 0))
  `(drgnx-cockpit-fixture-with
     (let* ((drgnx-cockpit-feed--buffers nil) (drgnx-cockpit-feed--timer nil) (drgnx-cockpit-feed--check-timer nil)
            (drgnx-cockpit-feed--waiting nil) (drgnx-cockpit-feed-test--hub nil)
            (drgnx-cockpit-graph-current-filter nil) (drgnx-cockpit--timer nil) (drgnx-cockpit--check-timer nil)
            (drgnx-cockpit--silent nil) (drgnx-cockpit--silent-at (float-time))
            (m1 (drgnx-agents--make :id "m-1" :remote "s-1" :name "claude · jx#2" :status 'idle :job "jx" :task "jx#2"))
            (m2 (drgnx-agents--make :id "m-2" :remote "s-2" :name "chat" :status 'busy :mode 'queue))
            (mirrors (list m1 m2))
            (config (current-window-configuration)))
       (ignore m1 m2)
       (cl-letf (((symbol-function 'drgnx-cockpit-sessions) (lambda () sessions))
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
           (should-not (timerp drgnx-cockpit-feed--timer))
           (should-not (timerp drgnx-cockpit-feed--check-timer))
           (should-not (memq #'drgnx-cockpit-feed--hub-event drgnx-hub-event-functions))
           (set-window-configuration config))))))

(defun drgnx-cockpit-feed-test--tick ()
  "Run the feed's update on its way now, as its timer would."
  (should (timerp drgnx-cockpit-feed--timer))
  (cancel-timer drgnx-cockpit-feed--timer)
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
    (cl-letf (((symbol-function 'drgnx-agents--prompt) (lambda (&rest _) (ert-fail "an answer started a turn")))
              ((symbol-function 'drgnx-agents-steer) (lambda (&rest _) (ert-fail "a queued answer steered"))))
      ;; a session whose mode interrupts: the answer waits in the store, the hub delivers it when the agent is free
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
      ;; the hub was never asked to stop, kill or cancel anything
      (dolist (c drgnx-cockpit-feed-test--hub)
        (should-not (member (car c) '("agents/stop" "agents/kill")))
        (should-not (equal (plist-get (cadr c) :op) "cancel"))))))

(ert-deftest drgnx-cockpit-feed/timeline-chips-in-time-order ()
  (drgnx-cockpit-feed-test--with
    (let ((b (drgnx-cockpit-timeline-buffer)) (opened nil)
          (mark (alist-get 'waiting (drgnx-cockpit-graph--glyph-table))))
      (set-window-buffer (selected-window) b)
      (with-current-buffer b
        ;; one row per agent, in the order they first did something; chips left to right by time
        (let ((s1 (drgnx-cockpit-feed-test--line "claude · jx#2")))
          (let ((at (mapcar (lambda (s) (or (string-search s s1) (ert-fail (list "missing" s s1))))
                            (list "decision #1" "2 files" "12/12 ✓" (concat mark " s-1 asks you")))))
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
          (should (string-match-p "‹ [0-9]+" row))
          (should-not (string-search "decision #1" row))
          (goto-char (point-min)) (search-forward "‹")
          (push-button (point))))
      (let ((earlier (get-buffer "*timeline: claude · jx#2*")))
        (should earlier)
        (with-current-buffer earlier
          (should (string-search "decision #1" (buffer-string)))
          (should (< (string-search "decision #1" (buffer-string)) (string-search "3/4 ⚠" (buffer-string)))))))))

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
      ;; the count the status bar shows is the model's open questions (the escalation and the reopened card)
      (should (= n0 2))
      (should (= n0 (length (plist-get (drgnx-cockpit-model :sessions sessions) :questions))))
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
      (should (= (drgnx-cockpit-waiting-count) (1- n0))))))

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
      (should (timerp drgnx-cockpit-feed--check-timer))
      ;; hidden: an event only marks it stale; showing it catches up
      (drgnx-coord-event-add :agent "s-2" :kind "stop" :summary "chat ended")
      (drgnx-cockpit-feed--hub-event "agent" nil)
      (when (timerp drgnx-cockpit-feed--timer) (drgnx-cockpit-feed-test--tick))
      (with-current-buffer b
        (should drgnx-cockpit-feed--stale)
        (should-not (string-search "stopped" (buffer-string))))
      (set-window-buffer (selected-window) b)
      (drgnx-cockpit-feed--on-show (selected-window))
      (drgnx-cockpit-feed-test--tick)
      (with-current-buffer b (should (string-search "stopped" (buffer-string))))
      ;; a transcript's chunk is not news
      (drgnx-cockpit-feed--hub-event "agent-entries" nil)
      (should-not (timerp drgnx-cockpit-feed--timer))
      ;; the last feed buffer killed: its hooks and timers go (checked by the macro), its markers are released
      (let ((h (drgnx-cockpit-feed-happened-buffer "s-1")))
        (let ((m (buffer-local-value 'drgnx-cockpit-feed--end h)))
          (kill-buffer h)
          (should-not (marker-buffer m)))))))

(ert-deftest drgnx-cockpit-feed/commands-and-keys-in-every-profile ()
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil) (kinds nil))
    (cl-letf (((symbol-function 'drgnx-pane-define-kind) (lambda (kind &rest props) (push (cons kind props) kinds))))
      (funcall (plist-get (alist-get 'tools/cockpit drgnx-modules--table) :setup)))
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

;;; mod-cockpit-feed-test.el ends here
