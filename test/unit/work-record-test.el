;;; work-record-test.el --- batch tests: commits recorded for the tasks drgnx starts -*- lexical-binding: t -*-
;; test-class: cond
(require 'ert)
(require 'drgnx-work)
(require 'drgnx-agents)
(require 'drgnx-exec)
(require 'drgnx-projects)
(require 'drgnx-sandbox-vc)
(load (expand-file-name "test/fixtures/work-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)

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
                                             "GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@t.invalid"
                                             "GIT_COMMITTER_NAME=t" "GIT_COMMITTER_EMAIL=t@t.invalid")
                                       process-environment))
          (drgnx-work-db--handles nil) (drgnx-work--tasks nil))
     (unwind-protect
         (progn (make-directory ,repo t)
                (drgnx-work-rec--git ,repo "init" "-q" "-b" "main")
                (drgnx-work-rec--commit ,repo "base")
                (drgnx-work-fixture-with-hub ,@body))
       (drgnx-work-db-close-all)
       (delete-directory root t))))

(defun drgnx-work-rec--titles (task)
  (mapcar (lambda (n) (plist-get n :title)) (seq-filter (lambda (n) (eq (plist-get n :kind) 'commit)) (drgnx-work-children task))))

(ert-deftest drgnx-work/the-commits-made-during-a-task-are-recorded-once ()
  (drgnx-work-rec--with repo
    (let* ((st (drgnx-work-task-begin "task:/p.md#1" repo))
           ;; one second for all: git's order, not the date, puts them newest first
           (date (format-time-string "%FT%TZ" (time-add nil 60) t))      ; after the task began
           (process-environment (append (list (concat "GIT_COMMITTER_DATE=" date) (concat "GIT_AUTHOR_DATE=" date)) process-environment)))
      (dolist (m '("one" "two" "three" "four")) (drgnx-work-rec--commit repo m))
      (should (= 4 (length (drgnx-work-task-collect st))))
      (should-not (drgnx-work-task-collect st))                       ; nothing new: nothing twice
      (should (equal (drgnx-work-rec--titles "task:/p.md#1") '("four" "three" "two" "one"))))))

(load (expand-file-name "test/fixtures/hub-client-fixture" drgnx-dir) nil t)   ; its Ratatoskr helpers
(require 'drgnx-agents-mirror)

(ert-deftest drgnx-work-record/hub-session-turn-records-commits ()
  ;; binary: a session the hub holds works on a task (mock ACP agent, a turn that commits); the mirror's turn end records
  ;; the commit for the task, as the in-process turn end did
  (drgnx-hub-client-test--with-ratatoskr
    (let* ((mock (expand-file-name "ratatoskr-mock" (file-name-directory (drgnx-hub-client-test--bin))))
           (repo (concat root "repo/")) (task (concat "task:" repo "docs/plans/p.md#1"))
           (drgnx-projects-board-file (concat root "none.org"))
           (drgnx-agents--sessions nil) (drgnx-work--tasks nil) (drgnx-hub-event-functions nil) (drgnx-work-db--handles nil))
      (skip-unless (file-executable-p mock))
      (write-region "[user]\n\tname = t\n\temail = t@t.invalid\n" nil (concat root "home/.gitconfig") nil 'silent)
      (make-directory (concat repo "docs/plans") t)
      (write-region "# Plan P\n\n### Task 1: one\n\n- [ ] a\n" nil (concat repo "docs/plans/p.md") nil 'silent)
      (drgnx-work-rec--git repo "init" "-q" "-b" "main")
      (drgnx-work-rec--commit repo "base")
      ;; the hub knows the task once the plan is scanned (it refuses commits for a task it does not have)
      (with-output-to-string (should (eql (drgnx-work-cli-run (list "scan" repo)) 0)))
      (drgnx-test-write-settings (concat root "config/settings.el") 'drgnx-agents-profiles
                                 (list (list "rmock" :provider 'claude :command (list mock "acp" "--as" "claude"))))
      (unwind-protect
          (progn
            (drgnx-agents-mirror-sync)
            (let ((m (drgnx-agents-mirror-start "rmock" repo task)))
              (drgnx-hub-client-test--wait (lambda () (eq (drgnx-agent-session-status m) 'idle)) "the session is idle")
              ;; the mock's commit takes what is in the checkout: something to commit
              (write-region "work\n" nil (concat repo "hub-work.txt") nil 'silent)
              (drgnx-agents-send m "commit hub work")
              (drgnx-hub-client-test--wait (lambda () (ignore-errors (member "hub work" (drgnx-work-rec--titles task))))
                                           "the turn's commit is recorded for the task")
              (should (equal (drgnx-work-rec--titles task) '("hub work")))))
        (drgnx-agents-mirror-stop)
        (drgnx-work-db-close-all)))))

(ert-deftest drgnx-work/a-job-task-gets-its-commits-when-it-ends ()
  (drgnx-work-rec--with repo
    (let ((job (list :id "j3" :name "j" :task "task:/p.md#3" :status 'running :cwd repo
                     :started (format-time-string "%FT%T%z" (time-subtract (current-time) 5))))
          (drgnx-work--job-starts (make-hash-table :test #'equal)))
      (cl-letf (((symbol-function 'drgnx-exec-list) (lambda () (list job))))
        (drgnx-work-collect-jobs)                                         ; sees it running: its start commit is noted
        (drgnx-work-rec--commit repo "job work")
        (setq job (plist-put (copy-sequence job) :status 'done))
        (drgnx-work-collect-jobs)
        (should (equal (drgnx-work-rec--titles "task:/p.md#3") '("job work")))
        (drgnx-work-rec--commit repo "later, not the job's")              ; the job ended before this
        (drgnx-work-collect-jobs)
        (should (equal (drgnx-work-rec--titles "task:/p.md#3") '("job work")))))))

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

;;;; Final review fixes

(defun drgnx-work-rec--old-commit (repo msg)
  "A commit of REPO dated 2020 (work done before any task began)."
  (let ((process-environment (append '("GIT_COMMITTER_DATE=2020-01-01T00:00:00Z" "GIT_AUTHOR_DATE=2020-01-01T00:00:00Z") process-environment)))
    (drgnx-work-rec--commit repo msg)))

(ert-deftest drgnx-work/a-pull-or-merge-brings-in-no-one-else-s-commits ()
  (drgnx-work-rec--with repo
    (drgnx-work-rec--git repo "checkout" "-q" "-b" "upstream")
    (drgnx-work-rec--old-commit repo "upstream work")
    (drgnx-work-rec--git repo "checkout" "-q" "-b" "side" "main")
    (drgnx-work-rec--old-commit repo "side work")
    (drgnx-work-rec--git repo "checkout" "-q" "main")
    (let ((st (drgnx-work-task-begin "task:/p.md#7" repo)))
      (drgnx-work-rec--git repo "merge" "-q" "--ff-only" "upstream")    ; a pull: older commits arrive
      (drgnx-work-rec--commit repo "mine")
      (drgnx-work-rec--git repo "merge" "-q" "--no-ff" "-m" "merge side" "side")
      (drgnx-work-task-collect st)
      (should (equal (drgnx-work-rec--titles "task:/p.md#7") '("merge side" "mine"))))))

(ert-deftest drgnx-work/a-checkout-or-rebase-records-nothing ()
  (drgnx-work-rec--with repo
    (drgnx-work-rec--git repo "checkout" "-q" "-b" "other")
    (drgnx-work-rec--commit repo "other branch work")
    (drgnx-work-rec--git repo "checkout" "-q" "main")
    (drgnx-work-rec--commit repo "main moves on")
    (let ((st (drgnx-work-task-begin "task:/p.md#8" repo)))
      (drgnx-work-rec--git repo "checkout" "-q" "other")                  ; HEAD jumps to an unrelated line
      (should-not (drgnx-work-task-collect st))
      (drgnx-work-rec--commit repo "after the checkout")
      (should (equal (length (drgnx-work-task-collect st)) 1)))))         ; from the new HEAD on

(ert-deftest drgnx-work/no-start-head-records-nothing ()
  (let* ((dir (file-name-as-directory (make-temp-file "drgnx-work-nohead" t))))
    (drgnx-work-rec--with repo
      (ignore repo)
      (let ((st (drgnx-work-task-begin "task:/p.md#9" dir)))             ; not a repository yet
        (drgnx-work-rec--git dir "init" "-q" "-b" "main")
        (drgnx-work-rec--commit dir "a whole history")
        (should-not (drgnx-work-task-collect st))))
    (delete-directory dir t)))

(ert-deftest drgnx-work/too-many-new-commits-for-one-turn-record-nothing ()
  (drgnx-work-rec--with repo
    (let ((st (drgnx-work-task-begin "task:/p.md#10" repo)) (drgnx-work-collect-max 2))
      (dotimes (i 3) (drgnx-work-rec--commit repo (format "c%d" i)))
      (should-not (drgnx-work-task-collect st))
      (should-not (drgnx-work-rec--titles "task:/p.md#10")))))

(defun drgnx-work-rec--session (task repo)
  (drgnx-agents--make :name task :profile "mock" :cwd repo :task task))

(defun drgnx-work-rec--pump ()
  "Let the zero timer that records a turn's commits run: wait until no timer is due."
  (drgnx-test-wait (lambda () (not (drgnx-test-wait--due-p))) :secs 5 :what "the due timers"))

(ert-deftest drgnx-work/a-turn-s-commits-are-recorded-after-the-turn-not-inside-it ()
  (drgnx-work-rec--with repo
    (let ((a (drgnx-work-rec--session "task:/p.md#11" repo)))
      (drgnx-work--agent-task a 'start)
      (drgnx-work--agent-task a 'turn-start)
      (drgnx-work-rec--commit repo "a's work")
      (drgnx-work--agent-task a 'turn-end)
      (should-not (drgnx-work-rec--titles "task:/p.md#11"))             ; not in the process filter
      (drgnx-work-rec--pump)
      (should (equal (drgnx-work-rec--titles "task:/p.md#11") '("a's work"))))))

(ert-deftest drgnx-work/job-agents-in-their-own-worktrees-are-recorded ()
  ;; a job's agents work in worktrees of one repository at once: each worktree has its own HEAD, so each turn's
  ;; commits are its task's (only two sessions in one worktree cannot be told apart)
  (drgnx-work-rec--with repo
    (let* ((w1 (concat repo ".claude/worktrees/w1/")) (w2 (concat repo ".claude/worktrees/w2/")))
      (drgnx-work-rec--git repo "worktree" "add" "-q" "-b" "b1" w1)
      (drgnx-work-rec--git repo "worktree" "add" "-q" "-b" "b2" w2)
      (let ((a (drgnx-work-rec--session "task:/p.md#21" w1)) (b (drgnx-work-rec--session "task:/p.md#22" w2)))
        (dolist (s (list a b)) (drgnx-work--agent-task s 'start))
        (drgnx-work--agent-task a 'turn-start)
        (drgnx-work--agent-task b 'turn-start)
        (drgnx-work-rec--commit w1 "a in w1")
        (drgnx-work-rec--commit w2 "b in w2")
        (drgnx-work--agent-task a 'turn-end)
        (drgnx-work--agent-task b 'turn-end)
        (drgnx-work-rec--pump)
        (should (equal (drgnx-work-rec--titles "task:/p.md#21") '("a in w1")))
        (should (equal (drgnx-work-rec--titles "task:/p.md#22") '("b in w2")))))))

(ert-deftest drgnx-work/two-task-sessions-busy-in-one-repository-record-nothing-by-themselves ()
  (drgnx-work-rec--with repo
    (let ((a (drgnx-work-rec--session "task:/p.md#12" repo)) (b (drgnx-work-rec--session "task:/p.md#13" repo)))
      (dolist (s (list a b)) (drgnx-work--agent-task s 'start))
      (drgnx-work--agent-task a 'turn-start)
      (drgnx-work--agent-task b 'turn-start)
      (drgnx-work-rec--commit repo "whose?")
      (drgnx-work--agent-task a 'turn-end)
      (drgnx-work--agent-task b 'turn-end)
      (drgnx-work-rec--pump)
      (should-not (drgnx-work-rec--titles "task:/p.md#12"))
      (should-not (drgnx-work-rec--titles "task:/p.md#13"))
      (drgnx-work--agent-task a 'turn-start)                               ; alone again: recorded
      (drgnx-work-rec--commit repo "a alone")
      (drgnx-work--agent-task a 'turn-end)
      (drgnx-work-rec--pump)
      (should (equal (drgnx-work-rec--titles "task:/p.md#12") '("a alone"))))))

(ert-deftest drgnx-work/a-job-whose-worktree-is-gone-still-gets-its-commits ()
  (drgnx-work-rec--with repo
    (let ((wt (concat repo ".wt/")))
      (drgnx-work-rec--git repo "worktree" "add" "-q" wt "-b" "w")
      (let ((job (list :id "j14" :name "j" :task "task:/p.md#14" :status 'running :cwd wt
                       :started (format-time-string "%FT%T%z" (time-subtract (current-time) 5))))
            (drgnx-work--job-starts (make-hash-table :test #'equal)))
        (cl-letf (((symbol-function 'drgnx-exec-list) (lambda () (list job))))
          (drgnx-work-collect-jobs)                                       ; sees it running in the worktree
          (drgnx-work-rec--commit wt "job in a worktree")
          (setq job (plist-put (copy-sequence job) :status 'done))
          (drgnx-work-rec--git repo "merge" "-q" "--ff-only" "w")
          (drgnx-work-rec--git repo "worktree" "remove" "--force" wt)
          (drgnx-work-collect-jobs)
          (should (equal (drgnx-work-rec--titles "task:/p.md#14") '("job in a worktree"))))))))

(defmacro drgnx-work-rec--dated (secs &rest body)
  "BODY with every commit dated SECS seconds from now."
  (declare (indent 1))
  `(let* ((date (format-time-string "%FT%TZ" (time-add nil ,secs) t))
          (process-environment (append (list (concat "GIT_COMMITTER_DATE=" date) (concat "GIT_AUTHOR_DATE=" date))
                                       process-environment)))
     ,@body))

(ert-deftest drgnx-work/a-job-first-seen-after-it-ended-still-gets-its-commits ()
  ;; the editor was closed while the job ran: the first time it sees the job it is done.  Its commits are those on its
  ;; own branch since it started (the hub keeps no start commit); what was there before it started is not its own
  (drgnx-work-rec--with repo
    (let* ((wt (concat repo ".wt/"))
           (started (format-time-string "%FT%T%z" (time-add nil 30)))
           (job (list :id "j16" :name "j" :task "task:/p.md#16" :status 'done :cwd wt :started started))
           (drgnx-work--job-starts (make-hash-table :test #'equal)))
      (drgnx-work-rec--git repo "worktree" "add" "-q" wt "-b" "w")
      (drgnx-work-rec--dated 60 (drgnx-work-rec--commit wt "job work"))
      (cl-letf (((symbol-function 'drgnx-exec-list) (lambda () (list job))))
        (drgnx-work-collect-jobs)
        (should (equal (drgnx-work-rec--titles "task:/p.md#16") '("job work")))))))

(ert-deftest drgnx-work/a-job-s-commits-on-its-own-branch-count-before-they-are-merged ()
  ;; seen running, then done with its commits only on its worktree's branch (the main checkout has not got them)
  (drgnx-work-rec--with repo
    (let* ((wt (concat repo ".wt/"))
           (job (list :id "j18" :name "j" :task "task:/p.md#18" :status 'running :cwd wt
                      :started (format-time-string "%FT%T%z" (time-subtract (current-time) 5))))
           (drgnx-work--job-starts (make-hash-table :test #'equal)))
      (drgnx-work-rec--git repo "worktree" "add" "-q" wt "-b" "w")
      (cl-letf (((symbol-function 'drgnx-exec-list) (lambda () (list job))))
        (drgnx-work-collect-jobs)
        (drgnx-work-rec--dated 60 (drgnx-work-rec--commit wt "unmerged job work"))
        (setq job (plist-put (copy-sequence job) :status 'done))
        (drgnx-work-collect-jobs)
        (should (equal (drgnx-work-rec--titles "task:/p.md#18") '("unmerged job work")))))))

(ert-deftest drgnx-work/git-notes-follow-the-environment ()
  (drgnx-work-rec--with repo
    (let ((sha (drgnx-work-rec--commit repo "noted by the cli")) (default-directory repo) (drgnx-work-git-notes nil)
          (process-environment (append '("DRGNX_WORK_GIT_NOTES=1" "DRGNX_TASK=task:/p.md#15") process-environment)))
      (drgnx-work-cli-run '("record"))
      (drgnx-work-cli-run '("record"))                                    ; twice: one line
      (should (equal (drgnx-work-rec--git repo "notes" "--ref=drgnx" "show" sha) "drgnx task: task:/p.md#15")))))


(ert-deftest drgnx-work/an-exited-session-s-last-commits-are-collected-once-at-the-exit ()
  ;; M7b-6: commits after the last turn-end are the dead session's; commits after the exit never are
  (drgnx-work-rec--with repo
    (let ((a (drgnx-work-rec--session "task:/p.md#31" repo)))
      (drgnx-work--agent-task a 'start)
      (drgnx-work--agent-task a 'turn-start)
      (drgnx-work-rec--commit repo "in the turn")
      (drgnx-work--agent-task a 'turn-end)
      (drgnx-work-rec--pump)
      (drgnx-work-rec--commit repo "after the last turn")
      (setf (drgnx-agent-session-status a) 'exited)
      (drgnx-work--agent-changed a)
      (should (equal (drgnx-work-rec--titles "task:/p.md#31") '("in the turn")))   ; on a timer, not in the hook
      (drgnx-work-rec--pump)
      (should (equal (sort (drgnx-work-rec--titles "task:/p.md#31") #'string<) '("after the last turn" "in the turn")))
      (drgnx-work-rec--commit repo "the user's own, after the exit")
      (drgnx-work--agent-changed a)                                      ; changed again, later starts: nothing more
      (drgnx-work--agent-task (drgnx-work-rec--session "task:/p.md#32" repo) 'start)
      (drgnx-work-rec--pump)
      (should (equal (sort (drgnx-work-rec--titles "task:/p.md#31") #'string<) '("after the last turn" "in the turn"))))))

(ert-deftest drgnx-work/an-exit-beside-a-busy-task-session-in-one-checkout-records-nothing ()
  (drgnx-work-rec--with repo
    (let ((dead (drgnx-work-rec--session "task:/p.md#33" repo)) (busy (drgnx-work-rec--session "task:/p.md#34" repo)))
      (dolist (s (list dead busy)) (drgnx-work--agent-task s 'start))
      (drgnx-work--agent-task busy 'turn-start)
      (drgnx-work-rec--commit repo "whose?")
      (setf (drgnx-agent-session-status dead) 'exited)
      (drgnx-work--agent-changed dead)
      (drgnx-work-rec--pump)
      (should-not (drgnx-work-rec--titles "task:/p.md#33")))))

;;; work-record-test.el ends here

;;;; A session with a work source (a sandboxed job's task): the main repository is read, when the job says so

(ert-deftest drgnx-work/source-function-defers-collection ()
  (drgnx-work-rec--with repo
    (let* ((folder (concat root "task/")) (a (drgnx-work-rec--session "task:/p.md#20" folder))
           (drgnx-work-source-functions (list (lambda (_s) (list :repo repo :ref "main")))))
      (make-directory folder t)                                       ; the session's folder is no repository
      (drgnx-work--agent-task a 'start)
      (drgnx-work--agent-task a 'turn-start)
      (drgnx-work-rec--commit repo "the task's work")
      (drgnx-work--agent-task a 'turn-end)
      (drgnx-work-rec--pump)
      (should-not (drgnx-work-rec--titles "task:/p.md#20"))           ; turn-end collects nothing
      (should (= 1 (length (drgnx-work-collect-now a))))              ; the job collects
      (should (equal (drgnx-work-rec--titles "task:/p.md#20") '("the task's work")))
      (should-not (drgnx-work-collect-now a)))))                      ; none twice

(ert-deftest drgnx-work/collect-now-reads-the-main-repo ()
  (drgnx-work-rec--with repo
    (let* ((folder (concat root "task/")) (a (drgnx-work-rec--session "task:/p.md#21" folder))
           (drgnx-work-source-functions (list (lambda (_s) (list :repo repo :ref "main"))))
           (drgnx-sandbox-vc--cache nil) (drgnx-sandbox-vc--added nil) (vc-ignore-dir-regexp vc-ignore-dir-regexp))
      (drgnx-work-rec--git repo "clone" "-q" repo folder)
      (drgnx-sandbox-vc-register folder)
      (drgnx-sandbox-vc-mode 1)
      (unwind-protect
          (progn
            (drgnx-work--agent-task a 'start)                         ; no git runs in the guarded folder
            (drgnx-work--agent-task a 'turn-start)
            (let ((default-directory folder))                         ; what the agent commits in its copy is not read
              (should-error (call-process "git" nil nil nil "log") :type 'drgnx-sandbox-guarded))
            (drgnx-work-rec--commit repo "arrived in the main repository")
            (drgnx-work--agent-task a 'turn-end)
            (should (= 1 (length (drgnx-work-collect-now a))))
            (should (equal (drgnx-work-rec--titles "task:/p.md#21") '("arrived in the main repository")))
            ;; a tracker call on the folder itself says nothing instead of failing
            (should-not (drgnx-work--git folder "rev-parse" "HEAD")))
        (drgnx-sandbox-vc-unregister folder)
        (drgnx-sandbox-vc-mode -1)))))
