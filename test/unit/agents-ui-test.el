;;; agents-ui-test.el --- batch tests: transcripts, the Agents list, edit review -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)
(require 'drgnx-timer)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-agents-ui" drgnx-dir) nil t)

(defconst drgnx-agents-ui-test--mock (expand-file-name "test/fixtures/mock-acp.el" drgnx-dir))

(defun drgnx-agents-ui-test--wait (pred &optional secs)
  (let ((deadline (+ (float-time) (or secs 10))) v)
    (while (and (not (setq v (funcall pred))) (< (float-time) deadline)) (accept-process-output nil 0.02))
    v))

(ert-deftest drgnx-agents-ui/a-transcript-shows-turns-tools-plans-and-what-waits ()
  (let ((s (drgnx-agents--make :name "mock · x" :status 'busy :queue '("later")
                               :entries (list '(:type user :text "do it")
                                              '(:type thought :text "hmm")
                                              (list :type 'tool :id "task1" :title "Task: explore" :status "completed"
                                                    :children (list '(:type tool :id "c1" :title "Grep" :status "completed")))
                                              '(:type plan :entries ((:content "Read" :status "completed") (:content "Test" :status "pending")))
                                              '(:type agent :text "Done."))
                               :permissions (list '(:id 7 :title "Run make" :options ((:optionId "a" :name "Allow") (:optionId "r" :name "Reject")))))))
    (with-temp-buffer
      (drgnx-agents-ui-render s)
      (let ((text (buffer-string)))
        (dolist (want '("▸ do it" "… hmm" "⚙ Task: explore [completed]" "  ⚙ Grep [completed]" "☑ Read" "☐ Test" "Done."
                        "? Run make" "[Allow]" "[Reject]" "working…" "1 queued"))
          (should (string-search want text)))))))

(ert-deftest drgnx-agents-ui/the-list-has-sessions-and-jobs ()
  (let* ((root (make-temp-file "drgnx-ui-jobs" t))
         (process-environment (cons (concat "XDG_STATE_HOME=" root) process-environment))
         (drgnx-agents--sessions (list (drgnx-agents--make :name "mock · p" :status 'idle :queue '("a" "b") :paused t :via 'gateway))))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "drgnx/jobs/20261017-000000-1" root) t)
          (with-temp-file (expand-file-name "drgnx/jobs/20261017-000000-1/job.eld" root)
            (prin1 '(:id "20261017-000000-1" :name "index" :launcher detached) (current-buffer)))
          (write-region "0" nil (expand-file-name "drgnx/jobs/20261017-000000-1/exit" root) nil 'silent)
          (let ((rows (mapcar #'cadr (drgnx-agents-ui--entries))))
            (should (equal (aref (car rows) 4) "gateway"))                 ; how its traffic goes
            (should (equal (aref (car rows) 5) "2 queued (paused)"))
            (should (equal (aref (cadr rows) 0) "job: index"))
            (should (equal (aref (cadr rows) 1) "exited"))))
      (delete-directory root t))))

(ert-deftest drgnx-agents-ui/last-active-column ()
  ;; Like Zed's agent list: how long ago each agent acted, from what the UI saw change.
  (let* ((now (drgnx-agents--make :id "n" :name "now" :status 'busy))
         (mins (drgnx-agents--make :id "m" :name "mins" :status 'idle))
         (hours (drgnx-agents--make :id "h" :name "hours" :status 'idle))
         (days (drgnx-agents--make :id "d" :name "days" :status 'idle))
         (never (drgnx-agents--make :id "x" :name "never" :status 'starting))
         (drgnx-agents--sessions (list now mins hours days never))
         (drgnx-agents-ui--last (make-hash-table :test #'eq :weakness 'key))
         (drgnx-agents-ui--jobs-cache (cons 1.0e+INF nil))     ; no job directory is read
         (drgnx-agents-ui--timer (timer-create)))                ; a redraw "pending": none is scheduled
    (drgnx-agents-ui--changed now)                               ; what the UI hears records the time
    (should (numberp (drgnx-agents-ui-last-active now)))
    (puthash mins (- (float-time) 330) drgnx-agents-ui--last)
    (puthash hours (- (float-time) 7300) drgnx-agents-ui--last)
    (puthash days (- (float-time) (* 3 86400) 50) drgnx-agents-ui--last)
    (let ((last (mapcar (lambda (e) (aref (cadr e) 2)) (drgnx-agents-ui--entries))))
      (should (string-match-p "\\`[0-9]s\\'" (nth 0 last)))
      (should (equal (cdr last) '("5m" "2h" "3d" ""))))
    (should (equal (mapcar #'drgnx-agents-ui--ago '(0 59 60 3599 3600 86399 86400)) '("0s" "59s" "1m" "59m" "1h" "23h" "1d")))
    (with-current-buffer (drgnx-agents-ui-list-buffer)
      (unwind-protect (should (equal (car (aref tabulated-list-format 2)) "Last"))
        (kill-buffer)))))

(ert-deftest drgnx-agents-ui/last-ticks-only-while-the-list-shows ()
  ;; A 30 s redraw keeps the ages current while the list is visible; nothing runs while it is not.
  (let* ((drgnx-agents--sessions (mapcar (lambda (n) (drgnx-agents--make :id n :name n :status 'idle)) '("a" "b" "c")))
         (drgnx-agents-ui--last (make-hash-table :test #'eq :weakness 'key))
         (drgnx-agents-ui--jobs-cache (cons 1.0e+INF nil))
         (drgnx-agents-ui--tick-timer nil)
         (w (selected-window)) (was (window-buffer w)))
    (unwind-protect
        (let ((list (drgnx-agents-ui-list-buffer)))
          (drgnx-agents-ui--tick-update)
          (should-not drgnx-agents-ui--tick-timer)                 ; not shown: no timer
          (set-window-buffer w list)
          (drgnx-agents-ui--tick-update)
          (let ((timer drgnx-agents-ui--tick-timer))
            (should (timerp timer))
            (should (memq timer timer-list))
            (should (= 30 (timer--repeat-delay timer)))
            (drgnx-agents-ui--tick-update)
            (should (eq timer drgnx-agents-ui--tick-timer))         ; one timer, however often asked
            ;; a tick redraws the ages and keeps the window's point on its row
            (puthash (nth 1 drgnx-agents--sessions) (- (float-time) 400) drgnx-agents-ui--last)
            (set-window-point w (with-current-buffer list (goto-char (point-min)) (forward-line 1) (point)))
            (drgnx-agents-ui--tick)
            (with-current-buffer list
              (should (string-search "6m" (buffer-string)))
              (should (= 2 (line-number-at-pos (window-point w)))))
            ;; hidden: the next tick stops the timer
            (set-window-buffer w was)
            (drgnx-agents-ui--tick)
            (should-not drgnx-agents-ui--tick-timer)
            (should-not (memq timer timer-list))))
      (when (timerp drgnx-agents-ui--tick-timer) (cancel-timer drgnx-agents-ui--tick-timer))
      (set-window-buffer w was)
      (when (get-buffer "*drgnx Agents*") (kill-buffer "*drgnx Agents*")))))

(ert-deftest drgnx-agents-ui/an-agent-edit-is-reviewed-hunk-by-hunk ()
  ;; The agent proposes two changes (first line, a new last line); the user takes the first only.
  (let* ((dir (make-temp-file "drgnx-review" t))
         (file (expand-file-name "f.txt" dir))
         (drgnx-agents-profiles
          (list (list "mock" :command (list "sh" (expand-file-name "test/fixtures/mock-acp-stdin.sh" drgnx-dir) (expand-file-name invocation-name invocation-directory) "--batch" "-Q" "-l" drgnx-agents-ui-test--mock))))
         (drgnx-agents--sessions nil)
         (drgnx-agents-changed-functions nil))
    (write-region (mapconcat (lambda (i) (format "line %d" i)) (number-sequence 1 12) "\n") nil file nil 'silent)
    (write-region "\n" nil file t 'silent)
    (let ((s (drgnx-agents-start "mock" dir)))
      (unwind-protect
          (progn
            (should (drgnx-agents-ui-test--wait (lambda () (eq (drgnx-agent-session-status s) 'idle))))
            (drgnx-agents-send s (concat "write " file))
            (should (drgnx-agents-ui-test--wait (lambda () (drgnx-agent-session-reviews s))))
            (let ((b (drgnx-agents-ui-review s (car (drgnx-agent-session-reviews s)))))
              (with-current-buffer b
                (goto-char (point-min))
                (diff-hunk-next)
                (let ((inhibit-interaction t)) (diff-apply-hunk))   ; the first hunk only
                (drgnx-agents-ui-review-done)))
            (should (drgnx-agents-ui-test--wait (lambda () (eq (drgnx-agent-session-status s) 'idle))))
            (should (member "write done" (mapcar (lambda (e) (plist-get e :text))
                                                 (seq-filter (lambda (e) (eq (plist-get e :type) 'agent)) (drgnx-agent-session-entries s)))))
            (let ((text (with-temp-buffer (insert-file-contents file) (buffer-string))))
              (should (string-prefix-p "CHANGED line 1\n" text))
              (should-not (string-search "ADDED LINE" text))))
        (drgnx-agents-kill s)
        (when-let* ((b (find-buffer-visiting file))) (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b))
        (delete-directory dir t)))))

(ert-deftest drgnx-agents-ui/every-command-is-registered ()
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
    (funcall (plist-get (alist-get 'tools/agents drgnx-modules--table) :setup))
    (dolist (id '(agents-view agents-new agents-send agents-stop agents-deliver agents-take-over agents-answer jobs-log jobs-stop agents-open agents-reply agents-review-done agents-review-reject
                              agents-new-durable))
      (should (drgnx-commands-get id)))))

(ert-deftest drgnx-agents-ui/hub-sessions-are-mirrored-only-when-a-hub-runs ()
  ;; at idle: never a wait (no ping), never a hub started — only a socket that is there is connected to
  (require 'drgnx-agents-mirror)
  (let* ((root (make-temp-file "drgnx-ui-mirror" t))
         (process-environment (append (list (concat "DRGNX_DATA_DIR=" root "/data") (concat "XDG_STATE_HOME=" root "/state")
                                            "XDG_RUNTIME_DIR")
                                      process-environment))
         (synced 0) (started 0))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-agents-mirror-sync) (lambda () (cl-incf synced)))
                  ((symbol-function 'drgnx-hub-ensure) (lambda () (cl-incf started)))
                  ((symbol-function 'drgnx-hub-running-p) (lambda () (error "no ping at idle"))))
          (drgnx-agents-ui--maybe-mirror)
          (should (= synced 0))
          (make-directory (file-name-directory (drgnx-hub-socket)) t)
          (write-region "" nil (drgnx-hub-socket) nil 'silent)
          (drgnx-agents-ui--maybe-mirror)
          (should (= synced 1))
          (should (= started 0)))
      (delete-directory root t))))

;;;; Review fixes (M7 final review)

(defmacro drgnx-agents-ui-test--reviewing (file content &rest body)
  "BODY with REVIEW the review buffer of an agent's proposed CONTENT for FILE (a fake session;
answers recorded in ANSWERS)."
  (declare (indent 2))
  `(let* ((answers nil)
          (s (drgnx-agents--make :name "fake" :cwd (file-name-directory ,file)))
          (item (list :id 5 :path ,file :content ,content)))
     (setf (drgnx-agent-session-reviews s) (list item))
     (cl-letf (((symbol-function 'drgnx-acp-respond) (lambda (_c id r &optional err) (push (list id r err) answers))))
       (let ((review (drgnx-agents-ui-review s item)))
         ,@body))))

(defun drgnx-agents-ui-test--lines (n) (concat (mapconcat (lambda (i) (format "line %d" i)) (number-sequence 1 n) "\n") "\n"))

(ert-deftest drgnx-agents-ui/reject-leaves-the-file-as-it-was ()
  ;; I2: hunks applied while reviewing are applied to a copy; Reject writes nothing.
  (let* ((dir (make-temp-file "drgnx-rev" t)) (f (expand-file-name "f.txt" dir)) (orig (drgnx-agents-ui-test--lines 12)))
    (write-region orig nil f nil 'silent)
    (drgnx-agents-ui-test--reviewing f (concat "CHANGED " (substring orig 0))
      (with-current-buffer review (goto-char (point-min)) (diff-hunk-next) (diff-apply-hunk) (drgnx-agents-ui-review-reject))
      (should (equal (with-temp-buffer (insert-file-contents f) (buffer-string)) orig))
      (should (nth 2 (car answers))))                                   ; the agent hears it was rejected
    (delete-directory dir t)))

(ert-deftest drgnx-agents-ui/an-agent-can-create-a-file-through-review ()
  ;; I1: a new file is written where the agent asked, not to a temp file.
  (let* ((dir (make-temp-file "drgnx-rev" t)) (f (expand-file-name "new/made.txt" dir)))
    (drgnx-agents-ui-test--reviewing f "hello\n"
      (with-current-buffer review (goto-char (point-min)) (diff-hunk-next) (diff-apply-hunk) (drgnx-agents-ui-review-done))
      (should (equal (with-temp-buffer (insert-file-contents f) (buffer-string)) "hello\n"))
      (should (equal (car answers) '(5 nil nil))))
    (delete-directory dir t)))

(ert-deftest drgnx-agents-ui/unsaved-edits-of-the-file-are-never-mixed-in ()
  (let* ((dir (make-temp-file "drgnx-rev" t)) (f (expand-file-name "f.txt" dir)))
    (write-region "a\n" nil f nil 'silent)
    (let ((b (find-file-noselect f)))
      (unwind-protect
          (progn
            (with-current-buffer b (goto-char (point-max)) (insert "mine\n"))
            (drgnx-agents-ui-test--reviewing f "b\n"
              (with-current-buffer review (should-error (drgnx-agents-ui-review-done) :type 'user-error))
              (should (equal (with-temp-buffer (insert-file-contents f) (buffer-string)) "a\n"))))
        (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))
    (delete-directory dir t)))

(ert-deftest drgnx-agents-ui/closing-a-review-rejects-it ()
  (let* ((dir (make-temp-file "drgnx-rev" t)) (f (expand-file-name "f.txt" dir)))
    (write-region "a\n" nil f nil 'silent)
    (drgnx-agents-ui-test--reviewing f "b\n"
      (kill-buffer review)
      (should (nth 2 (car answers)))
      (should-not (drgnx-agent-session-reviews s)))
    (delete-directory dir t)))

(ert-deftest drgnx-agents-ui/a-transcript-has-stop-deliver-commands-and-queue-controls ()
  (let ((s (drgnx-agents--make :name "x" :status 'busy :queue '("one" "two") :paused nil
                               :commands '((:name "compact" :description "c") (:name "review" :description "r")))))
    (with-temp-buffer
      (drgnx-agents-ui-render s)
      (let ((text (buffer-string)))
        (dolist (want '("[Stop]" "/compact" "/review" "one [×]" "two [×]")) (should (string-search want text)))))
    (setf (drgnx-agent-session-status s) 'idle (drgnx-agent-session-paused s) t)
    (with-temp-buffer (drgnx-agents-ui-render s) (should (string-search "[Deliver]" (buffer-string))))))

(ert-deftest drgnx-agents-ui/the-list-reads-jobs-at-most-every-few-seconds ()
  ;; I9: the list redraws often while an agent streams; jobs are read on a slower cadence.
  (let ((calls 0) (drgnx-agents-ui--jobs-cache nil) (drgnx-agents--sessions nil))
    (cl-letf (((symbol-function 'drgnx-jobs-list) (lambda () (setq calls (1+ calls)) nil)))
      (drgnx-agents-ui--entries) (drgnx-agents-ui--entries) (drgnx-agents-ui--entries)
      (should (= calls 1)))))

(defun drgnx-agents-ui-test--fires ()
  "How many idle timers on the list are the timer layer's."
  (let ((n 0)) (dolist (tm timer-idle-list n) (when (eq (timer--function tm) #'drgnx-timer--fire) (setq n (1+ n))))))

(ert-deftest drgnx-agents-ui/the-mirror-timer-has-an-owner ()
  ;; B1: the 30 s repeat belongs to the module's setup, so a second setup (or a reload) cannot stack another.
  (let* ((state (make-temp-file "drgnx-agents-ui-state" t))
         (process-environment (cons (concat "XDG_STATE_HOME=" state) process-environment))
         (drgnx-modules--table (list (assq 'tools/agents drgnx-modules--table)))
         (drgnx-modules--report nil) (drgnx-modules--stacks nil) (drgnx-modules--runs nil) (drgnx-modules--features nil)
         (setup (plist-get (cdar drgnx-modules--table) :setup)))
    (unwind-protect
        (drgnx-test-with-clock (:allow-pending t)
          (dotimes (_ 3)
            (should-not (drgnx-modules--run-setup 'tools/agents setup))
            (drgnx-modules--record 'tools/agents 'startup 0 'ok)
            (should (drgnx-timer-active-p 'agents-ui-mirror))
            (should (= 1 (drgnx-agents-ui-test--fires)))
            (should-not (drgnx-module-teardown 'tools/agents))
            (should-not (drgnx-timer-active-p 'agents-ui-mirror))
            (should (= 0 (drgnx-agents-ui-test--fires)))
            (should (= 0 (drgnx-timer-cancel-owner 'tools/agents))))
          ;; the 30 s idle repeat is unchanged: once per pause
          (should-not (drgnx-modules--run-setup 'tools/agents setup))
          (let ((idle (seq-find (lambda (tm) (eq (timer--function tm) #'drgnx-timer--fire)) timer-idle-list)))
            (should idle)
            (should (= 30 (float-time (timer--time idle))))
            (should (timer--repeat-delay idle)))
          (drgnx-module-teardown 'tools/agents)
          (mapc #'cancel-timer (append timer-list timer-idle-list)))
      (delete-directory state t))))

;;; agents-ui-test.el ends here
