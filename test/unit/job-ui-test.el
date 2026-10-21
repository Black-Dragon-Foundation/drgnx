;;; job-ui-test.el --- batch tests: jobs as an attention source and the Plan Job commands (a job's parts in the cockpit: mod-cockpit-cards-test.el) -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)
(require 'drgnx-timer)
(require 'drgnx-notice-desktop)
(require 'drgnx-notice-echo)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/notice-fixture" drgnx-dir) nil t)
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

(defmacro drgnx-job-ui-test--with (&rest body)
  "BODY on a fresh notice model with the `jobs' source defined, as the module's setup does."
  (declare (indent 0) (debug t))
  `(drgnx-notice-test-with-model
     (drgnx-notice-define-source 'jobs :title "Jobs" :command 'cockpit-needs-you)
     (cl-letf (((symbol-function 'force-mode-line-update) #'ignore))
       ,@body)))

(defun drgnx-job-ui-test--item (id)
  "The \"needs you\" item with ID, or nil."
  (seq-find (lambda (i) (equal (plist-get i :id) id)) (drgnx-needs-you-items)))

(ert-deftest drgnx-job-ui/note-jobs-sets-cards-and-messages ()
  (drgnx-job-ui-test--with
    ;; two cards and a message of a running job; a done job's card does not count
    (drgnx-job-ui-note-jobs (list drgnx-job-ui-test--summary
                                  (list :id "j2" :status "done" :cards '((:id 9 :kind "review" :title "x")) :messages :null)))
    (should (= 3 (drgnx-needs-you-count)))
    (should (= 3 (drgnx-needs-you-count "j1")))
    (let ((c (drgnx-job-ui-test--item '(card . 7))) (m (drgnx-job-ui-test--item '(message . 3))))
      (should (eq (plist-get c :source) 'jobs))
      (should (equal (plist-get c :text) "j1 — its agent ended 3 times"))
      (should (equal (plist-get c :command) '(drgnx-job-ui-show "j1")))
      (should (equal (plist-get c :scope) "j1"))
      (should (equal (plist-get m :text) "j1 — s-a: [escalation] db: which one?"))
      (should (equal (plist-get m :command) '(drgnx-job-ui-show "j1"))))
    (should-not (drgnx-job-ui-test--item '(card . 9)))
    ;; an acted message and a finished job leave the set; a long, many-line message is one short line
    (drgnx-job-ui-note-jobs (list (list :id "j1" :status "paused" :cards :null
                                        :messages (list (list :id 3 :sender "s-a" :state "acted")
                                                        (list :id 4 :sender "s-b" :state "queued"
                                                              :text (concat "a\nb " (make-string 300 ?x)))))))
    (should (= 1 (drgnx-needs-you-count)))
    (let ((text (plist-get (drgnx-job-ui-test--item '(message . 4)) :text)))
      (should-not (string-search "\n" text))
      (should (<= (length text) 100)))
    (drgnx-job-ui-note-jobs nil)
    (should (= 0 (drgnx-needs-you-count)))))

(ert-deftest drgnx-job-ui/a-failed-recount-is-unknown-with-a-reason ()
  (drgnx-job-ui-test--with
    (drgnx-job-ui-note-jobs (list drgnx-job-ui-test--summary))
    (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (_m _p &optional cb) (funcall cb nil "hub: connection lost"))))
      (drgnx-job-ui--recount))
    (should (= 0 (drgnx-needs-you-count)))
    (should (equal (drgnx-needs-you-unknown) '(jobs)))
    (should (seq-find (lambda (n) (equal (plist-get n :text) "Jobs: not known — the hub did not answer"))
                      (drgnx-notices :source 'jobs)))
    ;; a hub that is not even there says the same
    (drgnx-job-ui-note-jobs (list drgnx-job-ui-test--summary))
    (should-not (drgnx-needs-you-unknown))
    (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (&rest _) (error "No drgnx hub runs"))))
      (drgnx-job-ui--recount))
    (should (equal (drgnx-needs-you-unknown) '(jobs)))
    ;; an answer again: known again
    (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (_m _p &optional cb) (funcall cb (list :jobs (list drgnx-job-ui-test--summary)) nil))))
      (drgnx-job-ui--recount))
    (should-not (drgnx-needs-you-unknown))
    (should (= 3 (drgnx-needs-you-count)))))

(ert-deftest drgnx-job-ui/a-disconnect-is-unknown ()
  (drgnx-job-ui-test--with
    (drgnx-job-ui-note-jobs (list drgnx-job-ui-test--summary))
    (let ((drgnx-hub-disconnect-functions nil) (drgnx-hub-event-functions nil) (drgnx-job-ui-attention-mode nil))
      (cl-letf (((symbol-function 'drgnx-job-ui--schedule-recount) #'ignore))
        (drgnx-job-ui-attention-mode 1)
        (unwind-protect (run-hooks 'drgnx-hub-disconnect-functions)
          (drgnx-job-ui-attention-mode -1))))
    (should (= 0 (drgnx-needs-you-count)))
    (should (equal (drgnx-needs-you-unknown) '(jobs)))
    (should (seq-find (lambda (n) (equal (plist-get n :text) "Jobs: not known — the hub went away"))
                      (drgnx-notices :source 'jobs)))))

(ert-deftest drgnx-job-ui/the-badge-is-gone ()
  (dolist (s '(drgnx-job-ui--badge drgnx-job-ui--badge-job drgnx-job-ui--notified drgnx-job-ui--needs-you drgnx-job-ui-badge-map))
    (should-not (boundp s)))
  (dolist (f '(drgnx-job-ui--badge-segment drgnx-job-ui--badge-click drgnx-job-ui--badge-clear drgnx-job-ui--notify
                                           drgnx-job-ui--send drgnx-job-ui--desktop drgnx-job-ui--desktop-p))
    (should-not (fboundp f)))
  (drgnx-test-with-modules '(tools/jobs) :strict t
                           (should-not (seq-find (lambda (e) (and (consp e) (string-search "badge" (format "%S" e)))) global-mode-string))))

(ert-deftest drgnx-job-ui/badge-mode-is-an-obsolete-alias ()
  (should (eq (indirect-function 'drgnx-job-ui-badge-mode) (indirect-function 'drgnx-job-ui-attention-mode)))
  (should (eq (indirect-variable 'drgnx-job-ui-badge-mode) 'drgnx-job-ui-attention-mode))
  (should (get 'drgnx-job-ui-badge-mode 'byte-obsolete-info))
  (should (get 'drgnx-job-ui-badge-mode 'byte-obsolete-variable)))

(ert-deftest drgnx-job-ui/notify-is-an-obsolete-alias ()
  (should (eq (indirect-variable 'drgnx-job-ui-notify) 'drgnx-notice-desktop))
  (should (get 'drgnx-job-ui-notify 'byte-obsolete-variable))
  (let ((drgnx-job-ui-notify nil)) (should-not drgnx-notice-desktop))
  (should drgnx-notice-desktop))

(defun drgnx-job-ui-test--card-job (id kind)
  (list :id "j1" :status "running" :messages :null
        :cards (list (list :id id :kind kind :title (format "card %d" id)))))

(ert-deftest drgnx-job-ui/a-new-card-reaches-the-desktop-once ()
  ;; the echo route asks the desktop route for each `:added' item (core-notice-echo)
  (drgnx-job-ui-test--with
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
                (drgnx-job-ui-note-jobs (list (drgnx-job-ui-test--card-job 11 "budget")))
                (drgnx-job-ui-note-jobs (list (drgnx-job-ui-test--card-job 11 "budget")))   ; the same card again
                (drgnx-test-advance 0)
                (should (equal sent '(("drgnx: Jobs" . "j1 — card 11"))))
                ;; still there next to a second card: only the second is new
                (drgnx-job-ui-note-jobs (list (list :id "j1" :status "running" :messages :null
                                                    :cards '((:id 11 :kind "budget" :title "card 11")
                                                             (:id 12 :kind "stalled" :title "card 12")))))
                (drgnx-test-advance 0)
                (should (equal (mapcar #'cdr sent) '("j1 — card 12" "j1 — card 11"))))
            (drgnx-notice-echo-mode -1)
            (drgnx-notice-desktop-mode -1)))))))

(ert-deftest drgnx-job-ui/overlap-cards-count-but-never-interrupt ()
  (drgnx-job-ui-test--with
    (drgnx-job-ui-note-jobs (list (drgnx-job-ui-test--card-job 13 "overlap")))
    (should (= 1 (drgnx-needs-you-count)))
    (let ((item (drgnx-job-ui-test--item '(card . 13))))
      (should (plist-member item :echo))
      (should-not (plist-get item :echo))
      (let ((drgnx-notice-desktop t) (drgnx-notice-desktop--backend 'dbus) (drgnx-notice-desktop--seen (make-hash-table :test #'equal)))
        (cl-letf (((symbol-function 'frame-focus-state) #'ignore))
          (drgnx-notice-desktop-mode 1)
          (unwind-protect (should-not (drgnx-notice-desktop-take item))
            (drgnx-notice-desktop-mode -1)))))
    (should (plist-member (drgnx-job-ui-test--item '(card . 13)) :echo))
    (drgnx-job-ui-note-jobs (list (drgnx-job-ui-test--card-job 14 "budget")))
    (should-not (plist-member (drgnx-job-ui-test--item '(card . 14)) :echo))))

(ert-deftest drgnx-job-ui/setup-defines-the-source-and-teardown-clears-it ()
  (cl-letf (((symbol-function 'drgnx-hub-call) #'ignore))
    (drgnx-notice-test-with-model
      (drgnx-test-with-modules '(tools/jobs) :strict t
                               (should (gethash 'jobs drgnx-notice--sources))
                               (should (eq (plist-get (gethash 'jobs drgnx-notice--sources) :command) 'cockpit-needs-you))
                               (should drgnx-job-ui-attention-mode)
                               (should (memq #'drgnx-job-ui--event drgnx-hub-event-functions))
                               (drgnx-job-ui-note-jobs (list drgnx-job-ui-test--summary))
                               (should (= 3 (drgnx-needs-you-count)))
                               (drgnx-module-teardown 'tools/jobs)
                               (should-not (gethash 'jobs drgnx-notice--sources))
                               (should (= 0 (drgnx-needs-you-count)))
                               (should-not drgnx-job-ui-attention-mode)
                               (should-not (memq #'drgnx-job-ui--event drgnx-hub-event-functions))
                               (should-not (memq #'drgnx-job-ui--unknown-gone drgnx-hub-disconnect-functions))
                               (should-not (drgnx-timer-active-p 'job-ui-recount))
                               (should-not (drgnx-timer-active-p 'job-ui-recount-idle))))))

(ert-deftest drgnx-job-ui/note-jobs-is-quiet-while-the-module-is-off ()
  ;; the cockpit's every-job pane calls it whether or not tools/jobs is on
  (drgnx-notice-test-with-model
    (should-not (gethash 'jobs drgnx-notice--sources))
    (drgnx-job-ui-note-jobs (list drgnx-job-ui-test--summary))
    (should (= 0 (drgnx-needs-you-count)))))

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
  ;; the mode hears the hub and counts again through layer keys; turned off, both end
  (cl-letf (((symbol-function 'drgnx-hub-call) #'ignore))
    (drgnx-test-with-modules '(tools/jobs) :strict t
                             (should (memq #'drgnx-job-ui--event drgnx-hub-event-functions))
                             (drgnx-job-ui--schedule-recount)
                             (should (drgnx-timer-active-p 'job-ui-recount))
                             (drgnx-module-teardown 'tools/jobs)
                             (should-not (memq #'drgnx-job-ui--event drgnx-hub-event-functions))
                             (should-not (drgnx-timer-active-p 'job-ui-recount))
                             (should-not (drgnx-timer-active-p 'job-ui-recount-idle)))))

;; M9b4-1: once the hub has marked a dismissed message acted, the job does not wait on you (Dismiss itself:
;; mod-cockpit-cards-test.el); the count is the notice model's (`drgnx-needs-you-count', tested above).
(ert-deftest drgnx-job-ui/what-waits-on-you-is-open-cards-and-unacted-messages ()
  (let ((done (list :id "j2" :status "done" :cards '((:id 9 :kind "review")) :messages :null))
        (acted (list :id "j3" :status "running" :cards :null :messages '((:id 4 :state "acted")))))
    (should (drgnx-job-ui-waiting-p drgnx-job-ui-test--summary))
    (should-not (drgnx-job-ui-waiting-p done))
    (should-not (drgnx-job-ui-waiting-p acted))))

;; M9b4-14: where the notification goes (osascript, D-Bus, a message) is core's: core-notice-desktop-test.el.

;; M12a-70
(ert-deftest drgnx-job-ui/attention-mode-adds-and-removes-its-hooks ()
  (let ((drgnx-hub-disconnect-functions nil) (drgnx-hub-event-functions nil) (drgnx-job-ui-attention-mode nil))
    (cl-letf (((symbol-function 'drgnx-job-ui--schedule-recount) #'ignore))
      (drgnx-job-ui-attention-mode 1)
      (should (memq #'drgnx-job-ui--unknown-gone drgnx-hub-disconnect-functions))
      (should (memq #'drgnx-job-ui--event drgnx-hub-event-functions))
      (drgnx-job-ui-attention-mode -1)
      (should-not (memq #'drgnx-job-ui--unknown-gone drgnx-hub-disconnect-functions))
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
        (drgnx-notice-test-with-model
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
            (drgnx-modules--record 'tools/jobs 'startup 0 'ok)
            (drgnx-module-teardown 'tools/jobs)
            (mapc #'cancel-timer (append timer-list timer-idle-list))))
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
