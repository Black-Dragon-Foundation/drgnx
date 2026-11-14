;;; jobs-test.el --- batch tests: jobs as an attention source (module tools/jobs) -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'drgnx)
(require 'drgnx-timer)
(require 'drgnx-notice-desktop)
(require 'drgnx-notice-echo)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/notice-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-jobs" drgnx-dir) nil t)
(load (expand-file-name "modules/ui/drgnx-statusbar" drgnx-dir) nil t)   ; the `jobs' segment is defined into its table
(require 'drgnx-hub-client)                            ; before any stub of its functions
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)

(defconst drgnx-jobs-test--summary
  ;; as `job/status' gives it back through JSON: nil as :null, false as :false
  '(:id "j1" :title "Feature" :status "running" :repo "/r/" :budget 5.0 :spent 0.4
        :tasks ((:n 1 :title "one" :role "implement" :profile "mock" :status "running" :agent "s-a" :deps :null)
                (:n 2 :title "two" :role "implement" :profile "mock" :status "needs-input" :agent :null :deps (1)))
        :agents ((:id "s-a" :profile "mock" :task "j1#1" :status "busy" :review :false))
        :cards ((:id 7 :kind "agent" :task "j1#2" :title "its agent ended 3 times" :actions (("retry" "Retry") ("drop" "Drop the task"))
                     :data :null)
                (:id 8 :kind "clash" :task :null :title "build or not: csv" :actions (("accept" "Accept the reviewer") ("pick-a" "Pick A"))
                     :data (:rule "contradiction" :sides ((:label "A" :text "#1 build: csv" :decision 1) (:label "B" :text "#2 wont-build: csv" :decision 2))
                                  :recommendation (:side "A" :why "users asked"))))
        :messages ((:id 3 :sender "s-a" :text "[escalation] db: which one?" :state "queued"))
        :decisions ((:n 3 :kind "build" :subject "the api" :author "s-a" :status "current")
                    (:n 2 :kind "wont-build" :subject "csv" :author "s-b" :status "current")
                    (:n 1 :kind "build" :subject "csv" :author "s-a" :status "replaced"))))

(defmacro drgnx-jobs-test--with (&rest body)
  "BODY on a fresh notice model with the `jobs' source defined, as the module's setup does."
  (declare (indent 0) (debug t))
  `(drgnx-notice-test-with-model
     (drgnx-notice-define-source 'jobs :title "Jobs" :command 'work-needs-you-next)
     (cl-letf (((symbol-function 'force-mode-line-update) #'ignore))
       ,@body)))

(defun drgnx-jobs-test--item (id)
  "The \"needs you\" item with ID, or nil."
  (seq-find (lambda (i) (equal (plist-get i :id) id)) (drgnx-needs-you-items)))

(ert-deftest drgnx-jobs/note-jobs-sets-cards-and-messages ()
  (drgnx-jobs-test--with
    ;; two cards and a message of a running job; a done job's card does not count
    (drgnx-jobs-note-jobs (list drgnx-jobs-test--summary
                                (list :id "j2" :status "done" :cards '((:id 9 :kind "review" :title "x")) :messages :null)))
    (should (= 3 (drgnx-needs-you-count)))
    (should (= 3 (drgnx-needs-you-count "j1")))
    (let ((c (drgnx-jobs-test--item '(card . 7))) (m (drgnx-jobs-test--item '(message . 3))))
      (should (eq (plist-get c :source) 'jobs))
      (should (equal (plist-get c :text) "j1 — its agent ended 3 times"))
      (should (equal (plist-get c :command) 'work-needs-you-next))
      (should (equal (plist-get c :scope) "j1"))
      (should (equal (plist-get m :text) "j1 — s-a: [escalation] db: which one?"))
      (should (equal (plist-get m :command) 'work-needs-you-next)))
    (should-not (drgnx-jobs-test--item '(card . 9)))
    ;; an acted message and a finished job leave the set; a long, many-line message is one short line
    (drgnx-jobs-note-jobs (list (list :id "j1" :status "paused" :cards :null
                                      :messages (list (list :id 3 :sender "s-a" :state "acted")
                                                      (list :id 4 :sender "s-b" :state "queued"
                                                            :text (concat "a\nb " (make-string 300 ?x)))))))
    (should (= 1 (drgnx-needs-you-count)))
    (let ((text (plist-get (drgnx-jobs-test--item '(message . 4)) :text)))
      (should-not (string-search "\n" text))
      (should (<= (length text) 100)))
    (drgnx-jobs-note-jobs nil)
    (should (= 0 (drgnx-needs-you-count)))))

(ert-deftest drgnx-jobs/a-failed-recount-is-unknown-with-a-reason ()
  (drgnx-jobs-test--with
    (drgnx-jobs-note-jobs (list drgnx-jobs-test--summary))
    (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (_m _p &optional cb) (funcall cb nil "hub: connection lost"))))
      (drgnx-jobs--recount))
    (should (= 0 (drgnx-needs-you-count)))
    (should (equal (drgnx-needs-you-unknown) '(jobs)))
    (should (seq-find (lambda (n) (equal (plist-get n :text) "Jobs: not known — the hub did not answer"))
                      (drgnx-notices :source 'jobs)))
    ;; a hub that is not even there says the same
    (drgnx-jobs-note-jobs (list drgnx-jobs-test--summary))
    (should-not (drgnx-needs-you-unknown))
    (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (&rest _) (error "No drgnx hub runs"))))
      (drgnx-jobs--recount))
    (should (equal (drgnx-needs-you-unknown) '(jobs)))
    ;; an answer again: known again
    (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (_m _p &optional cb) (funcall cb (list :jobs (list drgnx-jobs-test--summary)) nil))))
      (drgnx-jobs--recount))
    (should-not (drgnx-needs-you-unknown))
    (should (= 3 (drgnx-needs-you-count)))))

(ert-deftest drgnx-jobs/a-disconnect-is-unknown ()
  (drgnx-jobs-test--with
    (drgnx-jobs-note-jobs (list drgnx-jobs-test--summary))
    (let ((drgnx-hub-disconnect-functions nil) (drgnx-hub-event-functions nil) (drgnx-jobs-attention-mode nil))
      (cl-letf (((symbol-function 'drgnx-jobs--schedule-recount) #'ignore))
        (drgnx-jobs-attention-mode 1)
        (unwind-protect (run-hooks 'drgnx-hub-disconnect-functions)
          (drgnx-jobs-attention-mode -1))))
    (should (= 0 (drgnx-needs-you-count)))
    (should (equal (drgnx-needs-you-unknown) '(jobs)))
    (should (seq-find (lambda (n) (equal (plist-get n :text) "Jobs: not known — the hub went away"))
                      (drgnx-notices :source 'jobs)))))

(defun drgnx-jobs-test--card-job (id kind)
  (list :id "j1" :status "running" :messages :null
        :cards (list (list :id id :kind kind :title (format "card %d" id)))))

(ert-deftest drgnx-jobs/a-new-card-reaches-the-desktop-once ()
  ;; frozen (the job UI is replaced by the agent system): run alone it leaves a `statusbar-refresh' timer pending, which
  ;; the file's earlier tests mask in a whole run; tagged, not fixed
  ;; the echo route asks the desktop route for each `:added' item (core-notice-echo)
  (drgnx-jobs-test--with
    (drgnx-test-with-clock ()
      (let ((sent nil) (after-init-time (current-time))(drgnx-notice-desktop t) (drgnx-notice-desktop--backend 'dbus)
            (drgnx-notice-desktop--seen (make-hash-table :test #'equal)) (drgnx-notice-desktop--queue nil)
            (drgnx-notice-functions nil))
        (cl-letf (((symbol-function 'drgnx-notice-desktop-send) (lambda (title body) (push (cons title body) sent)))
                  ((symbol-function 'drgnx-notice--can-echo-p) (lambda () t))
                  ((symbol-function 'frame-focus-state) #'ignore))
          (unwind-protect
              (progn
                (drgnx-notice-desktop-mode 1)
                (drgnx-notice-echo-mode 1)
                (drgnx-jobs-note-jobs (list (drgnx-jobs-test--card-job 11 "budget")))
                (drgnx-jobs-note-jobs (list (drgnx-jobs-test--card-job 11 "budget")))   ; the same card again
                (drgnx-test-advance 0)
                (should (equal sent '(("drgnx: Jobs" . "j1 — card 11"))))
                ;; still there next to a second card: only the second is new
                (drgnx-jobs-note-jobs (list (list :id "j1" :status "running" :messages :null
                                                  :cards '((:id 11 :kind "budget" :title "card 11")
                                                           (:id 12 :kind "stalled" :title "card 12")))))
                (drgnx-test-advance 0)
                (should (equal (mapcar #'cdr sent) '("j1 — card 12" "j1 — card 11"))))
            (drgnx-notice-echo-mode -1)
            (drgnx-notice-desktop-mode -1)))))))

(ert-deftest drgnx-jobs/overlap-cards-count-but-never-interrupt ()
  (drgnx-jobs-test--with
    (drgnx-jobs-note-jobs (list (drgnx-jobs-test--card-job 13 "overlap")))
    (should (= 1 (drgnx-needs-you-count)))
    (let ((item (drgnx-jobs-test--item '(card . 13))))
      (should (plist-member item :echo))
      (should-not (plist-get item :echo))
      (let ((drgnx-notice-desktop t) (drgnx-notice-desktop--backend 'dbus) (drgnx-notice-desktop--seen (make-hash-table :test #'equal)))
        (cl-letf (((symbol-function 'frame-focus-state) #'ignore))
          (drgnx-notice-desktop-mode 1)
          (unwind-protect (should-not (drgnx-notice-desktop-take item))
            (drgnx-notice-desktop-mode -1)))))
    (should (plist-member (drgnx-jobs-test--item '(card . 13)) :echo))
    (drgnx-jobs-note-jobs (list (drgnx-jobs-test--card-job 14 "budget")))
    (should-not (plist-member (drgnx-jobs-test--item '(card . 14)) :echo))))

(ert-deftest drgnx-jobs/setup-defines-the-source-and-teardown-clears-it ()
  (cl-letf (((symbol-function 'drgnx-hub-call) #'ignore))
    (drgnx-notice-test-with-model
      (drgnx-test-with-modules '(tools/jobs) :strict t
                               (should (gethash 'jobs drgnx-notice--sources))
                               (should (eq (plist-get (gethash 'jobs drgnx-notice--sources) :command) 'work-needs-you-next))
                               (should drgnx-jobs-attention-mode)
                               (should (memq #'drgnx-jobs--event drgnx-hub-event-functions))
                               (drgnx-jobs-note-jobs (list drgnx-jobs-test--summary))
                               (should (= 3 (drgnx-needs-you-count)))
                               (drgnx-module-teardown 'tools/jobs)
                               (should-not (gethash 'jobs drgnx-notice--sources))
                               (should (= 0 (drgnx-needs-you-count)))
                               (should-not drgnx-jobs-attention-mode)
                               (should-not (memq #'drgnx-jobs--event drgnx-hub-event-functions))
                               (should-not (memq #'drgnx-jobs--unknown-gone drgnx-hub-disconnect-functions))
                               (should-not (drgnx-timer-active-p 'jobs-recount))
                               (should-not (drgnx-timer-active-p 'jobs-recount-idle))))))

(defun drgnx-jobs-test--segment ()
  "The plain text of the `jobs' status bar segment (nil when it says nothing)."
  (when-let* ((spec (gethash 'jobs drgnx-statusbar--segments)) (s (funcall (plist-get spec :fn))))
    (substring-no-properties s)))

(ert-deftest drgnx-jobs/defines-the-jobs-segment ()
  ;; frozen, like the test above (DRGNX-JOBUI-CARD-ORDER-1): the same leftover timer; tagged, not fixed
  (cl-letf (((symbol-function 'drgnx-hub-call) #'ignore) (drgnx-jobs--running nil))
    (drgnx-notice-test-with-model
      (drgnx-test-with-modules '(tools/jobs) :strict t
                               (let ((spec (gethash 'jobs drgnx-statusbar--segments)))
                                 (should spec)
                                 (should (eq (plist-get spec :click) 'drgnx-work-space-open)))
                               (should-not (drgnx-jobs-test--segment))
                               ;; the running jobs are counted from the answer the notice model is fed with
                               (drgnx-jobs-note-jobs (list '(:id "a" :status "running") '(:id "b" :status "running")
                                                           '(:id "c" :status "done")))
                               (should (string-suffix-p "2 jobs" (drgnx-jobs-test--segment)))
                               (drgnx-jobs-note-jobs (list '(:id "a" :status "running")))
                               (should (string-suffix-p "1 job" (drgnx-jobs-test--segment)))
                               (drgnx-jobs-note-jobs nil)
                               (should-not (drgnx-jobs-test--segment))
                               ;; a count that cannot be read again is not shown
                               (drgnx-jobs-note-jobs (list '(:id "a" :status "running")))
                               (drgnx-jobs--unknown-gone)
                               (should-not (drgnx-jobs-test--segment))
                               ;; a change redraws the bars (the epoch moves), the same count does not
                               (drgnx-jobs-note-jobs (list '(:id "a" :status "running")))
                               (let ((before (drgnx-epoch 'statusbar)))
                                 (drgnx-jobs-note-jobs (list '(:id "a" :status "running") '(:id "c" :status "done")))
                                 (should (eql before (drgnx-epoch 'statusbar)))
                                 (drgnx-jobs-note-jobs (list '(:id "a" :status "running") '(:id "b" :status "running")))
                                 (should-not (eql before (drgnx-epoch 'statusbar))))
                               (drgnx-timer-cancel 'statusbar-refresh)
                               (drgnx-module-teardown 'tools/jobs)
                               (should-not (gethash 'jobs drgnx-statusbar--segments))))))

(ert-deftest drgnx-jobs/a-pixel-bar-shows-the-layers-icon ()
  "Design §4: in a graphical bar the running jobs are the layers icon and their count; a terminal keeps its glyph."
  (cl-letf (((symbol-function 'drgnx-jobs--source-p) (lambda () t))
            ((symbol-function 'drgnx-look-icon) (lambda (name &rest _) (format "<%s>" name))))
    (let ((drgnx-jobs--running 1) (drgnx-statusbar--measure (lambda (s) (* 10 (string-width s)))))
      (should (equal (drgnx-jobs--segment) "<layers> 1 job")))
    (let ((drgnx-jobs--running 2) (drgnx-statusbar--measure #'string-width))
      (should (string-suffix-p " 2 jobs" (drgnx-jobs--segment)))
      (should-not (string-prefix-p "<layers>" (drgnx-jobs--segment))))))

(ert-deftest drgnx-jobs/note-jobs-is-quiet-while-the-module-is-off ()
  ;; the recount calls it whether or not tools/jobs is on
  (drgnx-notice-test-with-model
    (should-not (gethash 'jobs drgnx-notice--sources))
    (drgnx-jobs-note-jobs (list drgnx-jobs-test--summary))
    (should (= 0 (drgnx-needs-you-count)))))

(ert-deftest drgnx-jobs/turned-off-it-hears-the-hub-no-more ()
  ;; the mode hears the hub and counts again through layer keys; turned off, both end
  (cl-letf (((symbol-function 'drgnx-hub-call) #'ignore))
    (drgnx-test-with-modules '(tools/jobs) :strict t
                             (should (memq #'drgnx-jobs--event drgnx-hub-event-functions))
                             (drgnx-jobs--schedule-recount)
                             (should (drgnx-timer-active-p 'jobs-recount))
                             (drgnx-module-teardown 'tools/jobs)
                             (should-not (memq #'drgnx-jobs--event drgnx-hub-event-functions))
                             (should-not (drgnx-timer-active-p 'jobs-recount))
                             (should-not (drgnx-timer-active-p 'jobs-recount-idle)))))

;; M9b4-1: once the hub has marked a dismissed message acted, the job does not wait on you; the count is the notice
;; model's (`drgnx-needs-you-count', tested above).
;; M9b4-14: where the notification goes (osascript, D-Bus, a message) is core's: core-notice-desktop-test.el.

;; M12a-70
(ert-deftest drgnx-jobs/attention-mode-adds-and-removes-its-hooks ()
  (let ((drgnx-hub-disconnect-functions nil) (drgnx-hub-event-functions nil) (drgnx-jobs-attention-mode nil))
    (cl-letf (((symbol-function 'drgnx-jobs--schedule-recount) #'ignore))
      (drgnx-jobs-attention-mode 1)
      (should (memq #'drgnx-jobs--unknown-gone drgnx-hub-disconnect-functions))
      (should (memq #'drgnx-jobs--event drgnx-hub-event-functions))
      (drgnx-jobs-attention-mode -1)
      (should-not (memq #'drgnx-jobs--unknown-gone drgnx-hub-disconnect-functions))
      (should-not (memq #'drgnx-jobs--event drgnx-hub-event-functions)))))

(defun drgnx-jobs-test--fires ()
  "How many idle timers on the list are the timer layer's."
  (let ((n 0)) (dolist (tm timer-idle-list n) (when (eq (timer--function tm) #'drgnx-timer--fire) (setq n (1+ n))))))

(ert-deftest drgnx-jobs/the-recount-timer-has-an-owner ()
  ;; B1: the 60 s repeat belongs to the module's setup, so a second setup (or a reload) cannot stack another.
  (let* ((state (make-temp-file "drgnx-jobs-state" t))
         (process-environment (cons (concat "XDG_STATE_HOME=" state) process-environment))
         (drgnx-modules--table (list (assq 'tools/jobs drgnx-modules--table)))
         (drgnx-modules--report nil) (drgnx-modules--stacks nil) (drgnx-modules--runs nil) (drgnx-modules--features nil)
         (setup (plist-get (cdar drgnx-modules--table) :setup)))
    (unwind-protect
        (drgnx-notice-test-with-model
          (drgnx-test-with-clock (:allow-pending t)
            (dotimes (_ 3)
              (should-not (drgnx-modules--run-setup 'tools/jobs setup))
              (drgnx-modules--record 'tools/jobs 'startup 0 'ok)
              (should (drgnx-timer-active-p 'jobs-recount-idle))
              (should (= 1 (drgnx-jobs-test--fires)))
              (should-not (drgnx-module-teardown 'tools/jobs))
              (should-not (drgnx-timer-active-p 'jobs-recount-idle))
              (should (= 0 (drgnx-jobs-test--fires)))
              (should (= 0 (drgnx-timer-cancel-owner 'tools/jobs))))
            ;; the 60 s idle repeat is unchanged: once per pause
            (should-not (drgnx-modules--run-setup 'tools/jobs setup))
            (let ((idle (seq-find (lambda (tm) (eq (timer--function tm) #'drgnx-timer--fire)) timer-idle-list)))
              (should idle)
              (should (= 60 (float-time (timer--time idle))))
              (should (timer--repeat-delay idle)))
            (drgnx-modules--record 'tools/jobs 'startup 0 'ok)
            (drgnx-module-teardown 'tools/jobs)
            (mapc #'cancel-timer (append timer-list timer-idle-list))))
      (delete-directory state t))))

(ert-deftest drgnx-jobs/events-recount-once-and-the-module-owns-the-recount ()
  ;; a burst of job events is one recount a second later; once the module is off, a pending recount never runs
  ;; frozen (DRGNX-JOBUI-CARD-ORDER-1): the leftover `statusbar-refresh' timer of the tests before it reaches this one
  (let ((drgnx-modules--runs (list (list 'tools/jobs 'tools/jobs))) (n 0))
    (drgnx-test-with-clock ()
      (cl-letf (((symbol-function 'drgnx-jobs--recount) (lambda () (cl-incf n))))
        (dotimes (_ 5) (drgnx-jobs--schedule-recount))
        (should (equal (mapcar #'car (drgnx-timer-pending)) '(jobs-recount)))
        (should (eq (cadar (drgnx-timer-pending)) 'tools/jobs))
        (drgnx-test-advance 1.1)
        (should (= n 1))
        (drgnx-jobs--schedule-recount)
        (should (= 1 (drgnx-timer-cancel-owner 'tools/jobs)))   ; the module is turned off
        (drgnx-test-advance 2)
        (should (= n 1))))))

;;; jobs-test.el ends here
