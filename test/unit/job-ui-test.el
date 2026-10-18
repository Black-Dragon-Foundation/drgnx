;;; job-ui-test.el --- batch tests: the job window's three areas, its actions, its refreshes -*- lexical-binding: t -*-
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

(defmacro drgnx-job-ui-test--with (&rest body)
  "BODY with the job window's buffers of j1 cleaned up after."
  (declare (indent 0))
  `(unwind-protect (progn ,@body)
     (clrhash drgnx-job-ui--drawn)
     (dolist (b (buffer-list)) (when (string-prefix-p "*job j1" (buffer-name b)) (kill-buffer b)))))

(defun drgnx-job-ui-test--text (part) (with-current-buffer (drgnx-job-ui--buffer "j1" part) (buffer-string)))

(defun drgnx-job-ui-test--button (part label)
  "The button of PART labelled LABEL."
  (with-current-buffer (drgnx-job-ui--buffer "j1" part)
    (let ((b (next-button (point-min) t)) found)
      (while (and b (not found))
        (if (equal (button-get b 'drgnx-label) label) (setq found b) (setq b (next-button (button-end b)))))
      found)))

(ert-deftest drgnx-job-ui/the-three-areas-show-the-job ()
  (drgnx-job-ui-test--with
    (drgnx-job-ui--draw "j1" drgnx-job-ui-test--summary)
    (let ((tasks (drgnx-job-ui-test--text 'tasks)))
      (should (string-search "Task 1: one" tasks))
      (should (string-search "needs-input" tasks))
      (should (string-search "spent 0.40 of 5.00 USD" tasks))
      (should (string-search "s-a" tasks)))
    (let ((cards (drgnx-job-ui-test--text 'cards)))
      (should (string-search "its agent ended 3 times" cards))
      (should (string-search "A: #1 build: csv" cards))
      (should (string-search "recommends A" cards))
      (should (string-search "which one?" cards)))
    (should (drgnx-job-ui-test--button 'cards "Retry"))
    (should (drgnx-job-ui-test--button 'cards "Drop the task"))
    (should (drgnx-job-ui-test--button 'cards "Reply…"))
    (let ((log (drgnx-job-ui-test--text 'log)))
      (should (< (string-search "#2 wont-build" log) (string-search "#1 build" log))))       ; newest first
    (with-current-buffer (drgnx-job-ui--buffer "j1" 'log)
      (goto-char (point-min))
      (search-forward "#1 build")
      (should (memq 'shadow (ensure-list (get-text-property (match-beginning 0) 'face))))   ; replaced
      (goto-char (point-min))
      (search-forward "#2 wont-build")
      (should (memq 'warning (ensure-list (get-text-property (match-beginning 0) 'face))))))) ; disputed

(ert-deftest drgnx-job-ui/a-button-acts-on-its-card-through-the-hub ()
  (drgnx-job-ui-test--with
    (drgnx-job-ui--draw "j1" drgnx-job-ui-test--summary)
    (let ((calls nil))
      (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (method params &optional _cb) (push (cons method params) calls))))
        (button-activate (drgnx-job-ui-test--button 'cards "Retry")))
      (should (equal (assoc "job/card" calls) '("job/card" :card 7 :action "retry" :arg nil))))))

(ert-deftest drgnx-job-ui/redraws-only-what-changed ()
  (drgnx-job-ui-test--with
    (drgnx-job-ui--draw "j1" drgnx-job-ui-test--summary)
    (let ((ticks (mapcar (lambda (p) (buffer-modified-tick (drgnx-job-ui--buffer "j1" p))) '(tasks cards log))))
      (drgnx-job-ui--draw "j1" (copy-tree drgnx-job-ui-test--summary))
      (should (equal ticks (mapcar (lambda (p) (buffer-modified-tick (drgnx-job-ui--buffer "j1" p))) '(tasks cards log))))
      ;; a task's status changed: only the left area
      (let ((s (copy-tree drgnx-job-ui-test--summary)))
        (plist-put (car (plist-get s :tasks)) :status "in-review")
        (drgnx-job-ui--draw "j1" s))
      (should-not (equal (nth 0 ticks) (buffer-modified-tick (drgnx-job-ui--buffer "j1" 'tasks))))
      (should (equal (nth 1 ticks) (buffer-modified-tick (drgnx-job-ui--buffer "j1" 'cards)))))))

(ert-deftest drgnx-job-ui/events-are-debounced ()
  (drgnx-job-ui-test--with
    (drgnx-job-ui--draw "j1" drgnx-job-ui-test--summary)
    (let ((n 0))
      (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (method _params &optional _cb) (when (equal method "job/status") (cl-incf n)))))
        (dotimes (_ 50) (drgnx-job-ui--event "job" '(:id "j1")))
        (let ((deadline (+ (float-time) 1))) (while (< (float-time) deadline) (accept-process-output nil 0.05))))
      (should (= n 1)))))

(ert-deftest drgnx-job-ui/no-hub-says-so ()
  (drgnx-job-ui-test--with
    (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (&rest _) (error "No drgnx hub runs"))))
      (drgnx-job-ui--refresh "j1"))
    (should (string-search "No drgnx hub" (drgnx-job-ui-test--text 'cards)))))

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
  (let ((sent nil) (drgnx-job-ui-notify t) (drgnx-job-ui--notified (make-hash-table :test #'equal)))
    (cl-letf (((symbol-function 'drgnx-job-ui--desktop-p) (lambda () t))
              ((symbol-function 'notifications-notify) (lambda (&rest args) (push args sent)))
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

(ert-deftest drgnx-job-ui/without-a-hub-it-looks-again-and-a-lost-hub-is-said ()
  (drgnx-job-ui-test--with
    (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (&rest _) (error "No drgnx hub runs"))))
      (drgnx-job-ui--refresh "j1"))
    (should (member "j1" (drgnx-job-ui--jobs)))                     ; still open: the retry will look for it
    ;; a hub that was there goes away: the open window says so
    (drgnx-job-ui--draw "j1" drgnx-job-ui-test--summary)
    (run-hooks 'drgnx-hub-disconnect-functions)
    (should (string-search "No drgnx hub" (drgnx-job-ui-test--text 'cards)))))

(ert-deftest drgnx-job-ui/the-commands-are-registered ()
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
    (funcall (plist-get (alist-get 'tools/jobs drgnx-modules--table) :setup))
    (dolist (id '(job-show job-start job-approve job-status job-stop))
      (should (drgnx-commands-get id))
      (dolist (profile '("vscode" "emacs" "vim"))
        (should (with-temp-buffer (insert-file-contents (expand-file-name (format "keys/%s.eld" profile) drgnx-dir))
                                  (search-forward (format "(%s " id) nil t)))))))

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
  (let ((drgnx-job-ui--badge " ⚑2") (drgnx-job-ui--badge-job "j1"))
    (cl-letf (((symbol-function 'drgnx-job-ui--jobs) (lambda () nil)))
      (drgnx-job-ui--hub-gone))
    (should (equal drgnx-job-ui--badge ""))
    (should-not drgnx-job-ui--badge-job)))

;;; job-ui-test.el ends here
