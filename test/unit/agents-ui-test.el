;;; agents-ui-test.el --- batch tests: transcripts, the Agents list, edit review -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)
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
            (should (equal (aref (car rows) 3) "gateway"))                 ; how its traffic goes
            (should (equal (aref (car rows) 4) "2 queued (paused)"))
            (should (equal (aref (cadr rows) 0) "job: index"))
            (should (equal (aref (cadr rows) 1) "exited"))))
      (delete-directory root t))))

(ert-deftest drgnx-agents-ui/an-agent-edit-is-reviewed-hunk-by-hunk ()
  ;; The agent proposes two changes (first line, a new last line); the user takes the first only.
  (skip-unless (file-readable-p "/proc/self/fd/0"))
  (let* ((dir (make-temp-file "drgnx-review" t))
         (file (expand-file-name "f.txt" dir))
         (drgnx-agents-profiles
          (list (list "mock" :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q" "-l" drgnx-agents-ui-test--mock))))
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
    (dolist (id '(agents-view agents-new agents-send agents-stop agents-deliver agents-take-over agents-answer jobs-log jobs-stop agents-open agents-reply agents-review-done agents-review-reject))
      (should (drgnx-commands-get id)))))

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

;;; agents-ui-test.el ends here
