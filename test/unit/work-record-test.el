;;; work-record-test.el --- batch tests: commits recorded for the tasks drgnx starts -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-work)
(require 'drgnx-agents)
(require 'drgnx-jobs)
(require 'drgnx-projects)

(defun drgnx-work-rec--git (dir &rest args)
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (apply #'call-process "git" nil t nil "-c" "user.name=t" "-c" "user.email=t@t.invalid" args)
      (string-trim (buffer-string)))))

(defun drgnx-work-rec--commit (repo msg)
  (write-region msg nil (expand-file-name (format "f-%s" (sxhash msg)) repo) nil 'silent)
  (drgnx-work-rec--git repo "add" "-A")
  (drgnx-work-rec--git repo "commit" "-q" "-m" msg)
  (drgnx-work-rec--git repo "rev-parse" "HEAD"))

(defmacro drgnx-work-rec--with (repo &rest body)
  (declare (indent 1))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-work-rec" t)))
          (,repo (concat root "repo/"))
          (process-environment (append (list (concat "DRGNX_DATA_DIR=" root "data") (concat "XDG_STATE_HOME=" root "state")
                                             "DRGNX_JOBS_LAUNCHER=detached" "GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@t.invalid"
                                             "GIT_COMMITTER_NAME=t" "GIT_COMMITTER_EMAIL=t@t.invalid")
                                       process-environment))
          (drgnx-work-db--handles nil) (drgnx-work--tasks nil))
     (unwind-protect
         (progn (make-directory ,repo t)
                (drgnx-work-rec--git ,repo "init" "-q" "-b" "main")
                (drgnx-work-rec--commit ,repo "base")
                ,@body)
       (drgnx-work-db-close-all)
       (delete-directory root t))))

(defun drgnx-work-rec--titles (task)
  (mapcar (lambda (n) (plist-get n :title)) (seq-filter (lambda (n) (eq (plist-get n :kind) 'commit)) (drgnx-work-children task))))

(ert-deftest drgnx-work/the-commits-made-during-a-task-are-recorded-once ()
  (drgnx-work-rec--with repo
    (let ((st (drgnx-work-task-begin "task:/p.md#1" repo))
          ;; one second for all: git's order, not the date, puts them newest first
          (process-environment (append '("GIT_COMMITTER_DATE=2026-01-01T00:00:00Z" "GIT_AUTHOR_DATE=2026-01-01T00:00:00Z") process-environment)))
      (dolist (m '("one" "two" "three" "four")) (drgnx-work-rec--commit repo m))
      (should (= 4 (length (drgnx-work-task-collect st))))
      (should-not (drgnx-work-task-collect st))                       ; nothing new: nothing twice
      (should (equal (drgnx-work-rec--titles "task:/p.md#1") '("four" "three" "two" "one"))))))

(ert-deftest drgnx-work/an-agent-task-gets-its-commits-at-the-end-of-each-turn ()
  (skip-unless (file-readable-p "/proc/self/fd/0"))
  (drgnx-work-rec--with repo
    (let* ((drgnx-agents-profiles
            (list (list "mock" :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q" "-l"
                                              (expand-file-name "test/fixtures/mock-acp.el" drgnx-dir)))))
           (drgnx-agents--sessions nil)
           (s (drgnx-agents-start "mock" repo "task:/p.md#2"))
           (wait (lambda (pred) (let ((d (+ (float-time) 10))) (while (and (not (funcall pred)) (< (float-time) d)) (accept-process-output nil 0.02))))))
      (unwind-protect
          (progn
            (funcall wait (lambda () (eq (drgnx-agent-session-status s) 'idle)))
            (drgnx-agents-send s "commit")
            (funcall wait (lambda () (and (eq (drgnx-agent-session-status s) 'idle) (drgnx-work-rec--titles "task:/p.md#2"))))
            (should (equal (drgnx-work-rec--titles "task:/p.md#2") '("agent work for task:/p.md#2"))))
        (drgnx-agents-kill s)))))

(ert-deftest drgnx-work/a-job-task-gets-its-commits-when-it-ends ()
  (skip-unless (executable-find "setsid"))
  (drgnx-work-rec--with repo
    (let ((id (drgnx-jobs-start "j" (list "sh" "-c" "echo x > j.txt && git add j.txt && git -c user.name=t -c user.email=t@t.invalid commit -q -m 'job work'")
                                :cwd repo :task "task:/p.md#3")))
      (let ((d (+ (float-time) 10))) (while (and (not (eq (plist-get (drgnx-jobs-get id) :status) 'exited)) (< (float-time) d)) (sleep-for 0.05)))
      (drgnx-work-collect-jobs)
      (should (equal (drgnx-work-rec--titles "task:/p.md#3") '("job work")))
      (drgnx-work-rec--commit repo "later, not the job's")                ; the job ended before this
      (drgnx-work-collect-jobs)
      (should (equal (drgnx-work-rec--titles "task:/p.md#3") '("job work"))))))

(ert-deftest drgnx-work/the-cli-records-a-commit-for-a-task ()
  (drgnx-work-rec--with repo
    (let ((sha (drgnx-work-rec--commit repo "by hand"))
          (default-directory repo)
          (process-environment (cons "DRGNX_TASK=task:/p.md#4" process-environment)))
      (should (eql (drgnx-work-cli-run '("record")) 0))
      (should (equal (drgnx-work-rec--titles "task:/p.md#4") '("by hand")))
      (should (eql (drgnx-work-cli-run (list "record" "--task" "task:/p.md#5" (substring sha 0 8))) 0))
      (should (equal (drgnx-work-rec--titles "task:/p.md#5") '("by hand")))
      (let ((process-environment (cons "DRGNX_TASK" process-environment)))
        (should (eql (drgnx-work-cli-run '("record")) 2))))))           ; no task: a usage error

(ert-deftest drgnx-work/git-notes-mirror-a-recorded-link-when-asked ()
  (drgnx-work-rec--with repo
    (let ((sha (drgnx-work-rec--commit repo "noted")) (drgnx-work-git-notes t))
      (drgnx-work-record-commit "task:/p.md#6" repo sha)
      (should (string-match-p "drgnx task: task:/p.md#6" (drgnx-work-rec--git repo "notes" "--ref=drgnx" "show" sha))))))

(ert-deftest drgnx-work/the-cli-scans-and-shows-each-plan-with-its-counts ()
  (drgnx-work-rec--with repo
    (make-directory (concat repo "docs/plans") t)
    (write-region "# Plan P\n\n### Task 1: one\n\n- [x] a\n- [ ] b\n" nil (concat repo "docs/plans/p.md") nil (quote silent))
    (let ((drgnx-projects-board-file (concat repo "none.org")))
      (should (string-match-p "1 plans" (with-output-to-string (should (eql (drgnx-work-cli-run (list "scan" repo)) 0)))))
      (let ((out (with-output-to-string (should (eql (drgnx-work-cli-run (list "status")) 0)))))
        (should (string-match-p "tasks 0/1 +steps 1/2 .*Plan P" out)))
      (let ((rows (json-parse-string (with-output-to-string (drgnx-work-cli-run (list "status" "--json"))) :object-type (quote plist))))
        (should (equal (plist-get (aref rows 0) :steps) [1 2]))))))

;;; work-record-test.el ends here
