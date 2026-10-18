;;; job-ui-test.el --- batch tests: the badge, notifications and the Plan Job commands (a job's parts in the cockpit: mod-cockpit-cards-test.el) -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)
(load (expand-file-name "modules/tools/drgnx-job-ui" drgnx-dir) nil t)
(require 'drgnx-hub)                                   ; before any stub of its functions

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
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
    (funcall (plist-get (alist-get 'tools/jobs drgnx-modules--table) :setup))
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

;; M9b4-14: the notification goes where the platform has one.
(ert-deftest drgnx-job-ui/notify-backend-choice ()
  (let ((made nil) (said nil))
    (cl-letf (((symbol-function 'make-process) (lambda (&rest args) (push args made) 'proc))
              ((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) said)))
              ((symbol-function 'executable-find) (lambda (c &rest _) (and (equal c "osascript") "/usr/bin/osascript")))
              ((symbol-function 'drgnx-job-ui--desktop-p) (lambda () nil))
              ((symbol-function 'notifications-notify) (lambda (&rest _) (push 'dbus made))))
      ;; macOS: a fixed script (`on run argv'), the text only as argv items after "--": nothing of it is ever script
      (let ((system-type 'darwin))
        (drgnx-job-ui--send "say \"hi\" \\ \" & (do shell script \"touch x\") & \"" "j1 — body\nnext -e"))
      (should (= 1 (length made)))
      (should (equal (plist-get (car made) :command)
                     '("osascript" "-e" "on run argv"
                       "-e" "display notification (item 1 of argv) with title (item 2 of argv)"
                       "-e" "end run" "--"
                       "j1 — body next -e" "say \"hi\" \\ \" & (do shell script \"touch x\") & \"")))
      (should-not said)
      ;; macOS without osascript, Linux without D-Bus, Windows: the message
      (setq made nil)
      (cl-letf (((symbol-function 'executable-find) #'ignore))
        (let ((system-type 'darwin)) (drgnx-job-ui--send "t" "b")))
      (dolist (type '(gnu/linux windows-nt)) (let ((system-type type)) (drgnx-job-ui--send "t" "b")))
      (should-not made)
      (should (= 3 (length said)))
      ;; Linux with D-Bus: notifications
      (cl-letf (((symbol-function 'drgnx-job-ui--desktop-p) (lambda () t)))
        (let ((system-type 'gnu/linux)) (drgnx-job-ui--send "t" "b")))
      (should (equal made '(dbus))))))

;; a failed osascript says so once and is not tried again
(ert-deftest drgnx-job-ui/a-failed-osascript-says-so-once ()
  (let ((made nil) (said nil) (sentinel nil))
    (cl-letf (((symbol-function 'make-process) (lambda (&rest args) (push args made) (setq sentinel (plist-get args :sentinel)) 'proc))
              ((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) said)))
              ((symbol-function 'executable-find) (lambda (&rest _) "/usr/bin/osascript"))
              ((symbol-function 'process-status) (lambda (_p) 'exit))
              ((symbol-function 'process-exit-status) (lambda (_p) 1)))
      (let ((system-type 'darwin)) (drgnx-job-ui--send "t" "b"))
      (should (functionp sentinel))
      (funcall sentinel 'proc "exited abnormally with code 1\n")
      (should (= 1 (length said)))
      (should (string-search "b" (car said)))
      (should (= 1 (length made))))                         ; no second try
    (setq said nil)
    (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) said)))
              ((symbol-function 'process-status) (lambda (_p) 'exit))
              ((symbol-function 'process-exit-status) (lambda (_p) 0)))
      (funcall sentinel 'proc "finished\n")
      (should-not said))))

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

;;; job-ui-test.el ends here
