;;; job-ui-test.el --- batch tests: the badge, notifications and the Plan Job commands (a job's parts in the cockpit: mod-cockpit-cards-test.el) -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)
(require 'drgnx-timer)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/memo-alloc-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-job-ui" drgnx-dir) nil t)
(require 'drgnx-hub)                                   ; before any stub of its functions
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)

(defconst drgnx-job-ui-test--summary
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

(ert-deftest drgnx-job-ui/the-badge-counts-what-needs-you ()
  (let ((drgnx-job-ui--badge "") (answer nil))
    (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (_m _p &optional cb) (funcall cb answer nil))))
      ;; two cards and a message of a running job; a done job's card does not count
      (setq answer (list :jobs (list drgnx-job-ui-test--summary
                                     (list :id "j2" :status "done" :cards '((:id 9 :kind "review")) :messages :null))))
      (drgnx-job-ui--recount)
      (should (equal (substring-no-properties drgnx-job-ui--badge) " ⚑3"))
      (should (equal drgnx-job-ui--badge-job "j1"))
      (setq answer (list :jobs :null))
      (drgnx-job-ui--recount)
      (should (equal drgnx-job-ui--badge "")))))

(ert-deftest drgnx-job-ui/an-unchanged-badge-allocates-nothing ()
  (let ((drgnx-job-ui--badge (format " ⚑%d" 2)))
    (let ((s (drgnx-job-ui--badge-segment)))
      (should (equal (substring-no-properties s) " ⚑2"))
      (should (eq 'warning (get-text-property 1 'face s)))
      (should (eq s (drgnx-job-ui--badge-segment)))
      (should (= 0 (drgnx-memo-fixture-alloc (lambda () (drgnx-job-ui--badge-segment)) 'drgnx-job-ui--badge-segment))))
    ;; a new count builds the string again; none is the empty string
    (setq drgnx-job-ui--badge (format " ⚑%d" 3))
    (should (equal (substring-no-properties (drgnx-job-ui--badge-segment)) " ⚑3"))
    (setq drgnx-job-ui--badge "")
    (should (equal (drgnx-job-ui--badge-segment) ""))))

(ert-deftest drgnx-job-ui/a-new-card-notifies-once ()
  ;; when and what is sent, whatever the platform: the send itself (osascript on macOS, D-Bus elsewhere) is stubbed
  (let ((sent nil) (drgnx-job-ui-notify t) (drgnx-job-ui--notified (make-hash-table :test #'equal)))
    (cl-letf (((symbol-function 'drgnx-job-ui--send) (lambda (title body) (push (list :title title :body body) sent)))
              ((symbol-function 'drgnx-hub-call) #'ignore))
      (drgnx-job-ui--event "card" '(:id 11 :job "j1" :kind "budget" :title "spent 1.2 of 1.0 USD: paused"))
      (should-not sent)                                     ; never inside the hub's event handler (D-Bus may hang)
      (drgnx-job-ui--event "card" '(:id 11 :job "j1" :kind "budget" :title "spent 1.2 of 1.0 USD: paused"))
      (drgnx-job-ui--event "card" '(:id 13 :job "j1" :kind "overlap" :title "advisory"))   ; nothing to do: no notification
      (let ((deadline (+ (float-time) 0.5))) (while (< (float-time) deadline) (accept-process-output nil 0.05)))
      (should (= 1 (length sent)))
      (should (equal (plist-get (car sent) :title) "drgnx: a job needs you"))
      (should (string-search "paused" (plist-get (car sent) :body)))
      (let ((drgnx-job-ui-notify nil))
        (drgnx-job-ui--event "card" '(:id 12 :job "j1" :kind "stalled" :title "x"))
        (let ((deadline (+ (float-time) 0.3))) (while (< (float-time) deadline) (accept-process-output nil 0.05)))
        (should (= 1 (length sent)))))))

(ert-deftest drgnx-job-ui/the-commands-are-registered ()
  (drgnx-test-with-modules '(tools/jobs) :strict t
                           (dolist (id '(job-show job-start job-approve job-status job-stop))
                             (should (drgnx-commands-get id))
                             (dolist (profile '("vscode" "emacs" "vim"))
                               (should (with-temp-buffer (insert-file-contents (expand-file-name (format "keys/%s.eld" profile) drgnx-dir))
                                                         (search-forward (format "(%s " id) nil t)))))
                           ;; M12f: a job shows in the Work cockpit; the window of its own is gone (closing a frame forgets nothing here)
                           (should (equal (drgnx-cmd-title (drgnx-commands-get 'job-show)) "Show Job in Work…"))
                           (should-not (memq 'drgnx-job-ui--frame-deleted delete-frame-functions))
                           (should-not (fboundp 'drgnx-job-ui--frame))
                           (should-not (fboundp 'drgnx-job-ui--layout))))

(ert-deftest drgnx-job-ui/turned-off-it-hears-the-hub-no-more ()
  ;; the badge hears the hub through its mode and counts again through layer keys; turned off, both end, and the
  ;; last count goes (the status bar's jobs segment reads it)
  (cl-letf (((symbol-function 'drgnx-hub-call) #'ignore))
    (drgnx-test-with-modules '(tools/jobs) :strict t
                             (should (memq #'drgnx-job-ui--event drgnx-hub-event-functions))
                             (drgnx-job-ui--schedule-recount)
                             (should (drgnx-timer-active-p 'job-ui-recount))
                             (drgnx-job-ui-note-jobs (list drgnx-job-ui-test--summary))
                             (should (eql (drgnx-job-ui-needs-you) 3))
                             (drgnx-module-teardown 'tools/jobs)
                             (should-not (memq #'drgnx-job-ui--event drgnx-hub-event-functions))
                             (should-not (drgnx-timer-active-p 'job-ui-recount))
                             (should-not (drgnx-timer-active-p 'job-ui-recount-idle))
                             (should-not (drgnx-job-ui-needs-you)))))

;; From the old UI list ("stale status values after gry failures"): a status that cannot be read says nothing
;; instead of keeping the last count.
(ert-deftest drgnx-job-ui/the-badge-clears-when-the-hub-cannot-answer ()
  (let ((drgnx-job-ui--badge " ⚑3") (drgnx-job-ui--badge-job "j1"))
    (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (_m _p &optional cb) (funcall cb nil "hub: connection lost"))))
      (drgnx-job-ui--recount))
    (should (equal drgnx-job-ui--badge ""))
    (should-not drgnx-job-ui--badge-job))
  (let ((drgnx-job-ui--badge " ⚑3") (drgnx-job-ui--badge-job "j1"))
    (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (&rest _) (error "No drgnx hub runs"))))
      (drgnx-job-ui--recount))
    (should (equal drgnx-job-ui--badge ""))))

(ert-deftest drgnx-job-ui/the-badge-clears-when-the-hub-goes-away ()
  (let ((drgnx-job-ui--badge " ⚑2") (drgnx-job-ui--badge-job "j1")
        (drgnx-hub-disconnect-functions nil) (drgnx-hub-event-functions nil) (global-mode-string nil) (drgnx-job-ui-badge-mode nil))
    (cl-letf (((symbol-function 'drgnx-job-ui--schedule-recount) #'ignore))
      (drgnx-job-ui-badge-mode 1)
      (unwind-protect (run-hooks 'drgnx-hub-disconnect-functions)
        (drgnx-job-ui-badge-mode -1)))
    (should (equal drgnx-job-ui--badge ""))
    (should-not drgnx-job-ui--badge-job)))

;; M9b4-1: once the hub has marked a dismissed message acted, the recount gives 0 (Dismiss itself:
;; mod-cockpit-cards-test.el).
(ert-deftest drgnx-job-ui/an-acted-message-is-not-counted ()
  (should (= 0 (car (drgnx-job-ui-needs-you-count '((:id "j1" :status "running" :cards :null :messages ((:id 3 :state "acted")))))))))

;; one count of what needs you: the badge, the cockpit's What needs you and (after part A) the status bar read it
(ert-deftest drgnx-job-ui/one-count-of-what-needs-you ()
  (let ((drgnx-job-ui--badge "") (drgnx-job-ui--badge-job nil) (drgnx-job-ui--needs-you nil)
        (done (list :id "j2" :status "done" :cards '((:id 9 :kind "review")) :messages :null))
        (acted (list :id "j3" :status "running" :cards :null :messages '((:id 4 :state "acted")))))
    (should (equal (drgnx-job-ui-needs-you-count (list drgnx-job-ui-test--summary done acted)) '(3 . "j1")))
    (should (drgnx-job-ui-waiting-p drgnx-job-ui-test--summary))
    (should-not (drgnx-job-ui-waiting-p done))
    (should-not (drgnx-job-ui-waiting-p acted))
    (should-not (drgnx-job-ui-needs-you))                  ; not known yet
    (drgnx-job-ui-note-jobs (list drgnx-job-ui-test--summary done acted))
    (should (= 3 (drgnx-job-ui-needs-you)))
    (should (equal (substring-no-properties drgnx-job-ui--badge) " ⚑3"))
    (should (equal drgnx-job-ui--badge-job "j1"))
    (drgnx-job-ui-note-jobs nil)
    (should (= 0 (drgnx-job-ui-needs-you)))
    (should (equal drgnx-job-ui--badge ""))
    (drgnx-job-ui--badge-clear)                           ; the hub cannot be asked: not known
    (should-not (drgnx-job-ui-needs-you))))

;; M9b4-14: where the notification goes (osascript, D-Bus, a message) is core's: core-notice-desktop-test.el.

;; M12a-70
(ert-deftest drgnx-job-ui/badge-mode-adds-and-removes-its-disconnect-hook ()
  (let ((drgnx-hub-disconnect-functions nil) (drgnx-hub-event-functions nil) (global-mode-string nil) (drgnx-job-ui-badge-mode nil))
    (cl-letf (((symbol-function 'drgnx-job-ui--schedule-recount) #'ignore))
      (drgnx-job-ui-badge-mode 1)
      (should (memq #'drgnx-job-ui--badge-clear drgnx-hub-disconnect-functions))
      (should (memq #'drgnx-job-ui--event drgnx-hub-event-functions))
      (drgnx-job-ui-badge-mode -1)
      (should-not (memq #'drgnx-job-ui--badge-clear drgnx-hub-disconnect-functions))
      (should-not (memq #'drgnx-job-ui--event drgnx-hub-event-functions)))))

(defun drgnx-job-ui-test--fires ()
  "How many idle timers on the list are the timer layer's."
  (let ((n 0)) (dolist (tm timer-idle-list n) (when (eq (timer--function tm) #'drgnx-timer--fire) (setq n (1+ n))))))

(ert-deftest drgnx-job-ui/the-recount-timer-has-an-owner ()
  ;; B1: the 60 s repeat belongs to the module's setup, so a second setup (or a reload) cannot stack another.
  (let* ((state (make-temp-file "drgnx-job-ui-state" t))
         (process-environment (cons (concat "XDG_STATE_HOME=" state) process-environment))
         (drgnx-modules--table (list (assq 'tools/jobs drgnx-modules--table)))
         (drgnx-modules--report nil) (drgnx-modules--stacks nil) (drgnx-modules--runs nil) (drgnx-modules--features nil)
         (setup (plist-get (cdar drgnx-modules--table) :setup)))
    (unwind-protect
        (drgnx-test-with-clock (:allow-pending t)
          (dotimes (_ 3)
            (should-not (drgnx-modules--run-setup 'tools/jobs setup))
            (drgnx-modules--record 'tools/jobs 'startup 0 'ok)
            (should (drgnx-timer-active-p 'job-ui-recount-idle))
            (should (= 1 (drgnx-job-ui-test--fires)))
            (should-not (drgnx-module-teardown 'tools/jobs))
            (should-not (drgnx-timer-active-p 'job-ui-recount-idle))
            (should (= 0 (drgnx-job-ui-test--fires)))
            (should (= 0 (drgnx-timer-cancel-owner 'tools/jobs))))
          ;; the 60 s idle repeat is unchanged: once per pause
          (should-not (drgnx-modules--run-setup 'tools/jobs setup))
          (let ((idle (seq-find (lambda (tm) (eq (timer--function tm) #'drgnx-timer--fire)) timer-idle-list)))
            (should idle)
            (should (= 60 (float-time (timer--time idle))))
            (should (timer--repeat-delay idle)))
          (drgnx-modules--record 'tools/jobs 'startup 0 'ok)   ; else the teardown finds it not running: the badge would stay
          (drgnx-module-teardown 'tools/jobs)
          (mapc #'cancel-timer (append timer-list timer-idle-list)))
      (delete-directory state t))))

(ert-deftest drgnx-job-ui/events-recount-once-and-the-module-owns-the-recount ()
  ;; a burst of job events is one recount a second later; once the module is off, a pending recount never runs
  (let ((drgnx-modules--runs (list (list 'tools/jobs 'tools/jobs))) (n 0))
    (drgnx-test-with-clock ()
      (cl-letf (((symbol-function 'drgnx-job-ui--recount) (lambda () (cl-incf n))))
        (dotimes (_ 5) (drgnx-job-ui--schedule-recount))
        (should (equal (mapcar #'car (drgnx-timer-pending)) '(job-ui-recount)))
        (should (eq (cadar (drgnx-timer-pending)) 'tools/jobs))
        (drgnx-test-advance 1.1)
        (should (= n 1))
        (drgnx-job-ui--schedule-recount)
        (should (= 1 (drgnx-timer-cancel-owner 'tools/jobs)))   ; the module is turned off
        (drgnx-test-advance 2)
        (should (= n 1))))))

;;; job-ui-test.el ends here
