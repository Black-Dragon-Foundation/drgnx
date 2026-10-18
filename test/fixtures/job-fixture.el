;;; job-fixture.el --- for job tests: a git repo with a plan, the hub served here, mock agents -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-hub)
(require 'drgnx-job)

(defun drgnx-job-run-test--git (dir &rest args)
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (unless (eql 0 (apply #'call-process "git" nil t nil "-c" "user.name=t" "-c" "user.email=t@t.invalid" args))
        (error "git %S: %s" args (buffer-string)))
      (string-trim (buffer-string)))))

(defmacro drgnx-job-run-test--with (plan-text &rest body)
  "BODY with drgnx's dirs in ROOT, a git repo REPO (one commit), PLAN-TEXT as PLAN in it, the hub served here and the
profile \"mock\" on every route."
  (declare (indent 1))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-job-run" t)))
          (repo (concat root "repo/")) (plan (concat repo "docs/plans/p.md"))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" root "config") (concat "DRGNX_DATA_DIR=" root "data")
                                             (concat "XDG_STATE_HOME=" root "state") "DRGNX_NO_HUB_START"
                                             "GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@t.invalid" "GIT_COMMITTER_NAME=t"
                                             "GIT_COMMITTER_EMAIL=t@t.invalid")
                                       process-environment))
          (drgnx-work-db--handles nil) (drgnx-agents--sessions nil) (drgnx-hub--exit-function #'drgnx-hub-stop)
          (drgnx-gateway--registrations (make-hash-table :test #'equal))
          (drgnx-agents-profiles
           (list (list "mock" :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                             "-l" (expand-file-name "test/fixtures/mock-acp.el" drgnx-dir)))))
          (drgnx-job-routes '((implement . "mock") (test . "mock") (docs . "mock") (review . "mock")))
          (drgnx-job-auto-start nil) (drgnx-job-max-agents 3))
     (unwind-protect
         (progn
           (make-directory (concat root "config") t) (make-directory (concat repo "docs/plans") t)
           (write-region "x\n" nil (concat repo "README") nil 'silent)
           (write-region ,plan-text nil plan nil 'silent)
           (drgnx-job-run-test--git repo "init" "-q" "-b" "main")
           (drgnx-job-run-test--git repo "add" "-A")
           (drgnx-job-run-test--git repo "commit" "-q" "-m" "start")
           (drgnx-hub-serve (drgnx-hub-socket))
           ;; the hub's memory of jobs is this test's: ids repeat across tests (fresh stores, second-based ids)
           (dolist (h (list drgnx-job--prompts drgnx-job--reviewers drgnx-job--reviewing
                            drgnx-job--turns-seen drgnx-job--step-pending drgnx-job--signatures drgnx-job--busy))
             (clrhash h))
           (when (featurep 'drgnx-job-clash) (clrhash drgnx-job-clash--starts) (clrhash drgnx-job-clash--checked))
           ,@body)
       (dolist (s drgnx-agents--sessions) (ignore-errors (drgnx-agents-kill s)))
       (drgnx-hub-disconnect)
       (drgnx-hub-stop)
       (drgnx-work-db-close-all)
       ;; agents (and their MCP servers) may still be writing in the worktrees as they end: wait, then delete
       (let ((deadline (+ (float-time) 3)))
         (while (and (seq-some (lambda (p) (and (process-live-p p) (not (eq (process-type p) 'network)))) (process-list))
                     (< (float-time) deadline))
           (accept-process-output nil 0.05)))
       (condition-case nil (delete-directory root t)
         (file-error (accept-process-output nil 0.3) (delete-directory root t))))))

(defun drgnx-job-run-test--wait (pred &optional secs)
  (let ((deadline (+ (float-time) (or secs 15))))
    (while (and (not (funcall pred)) (< (float-time) deadline)) (accept-process-output nil 0.05)))
  (funcall pred))

(defun drgnx-job-run-test--status (job n)
  (plist-get (seq-find (lambda (task) (= (plist-get task :n) n)) (drgnx-coord-tasks job)) :status))

(defun drgnx-job-run-test--sessions (job)
  "JOB's live sessions working on its tasks (reviewers apart: `drgnx-job-max-agents' counts the others)."
  (seq-filter (lambda (s) (and (equal (drgnx-agent-session-job s) job) (not (eq (drgnx-agent-session-status s) 'exited))
                               (not (gethash (drgnx-agent-session-id s) drgnx-job--reviewers))))
              drgnx-agents--sessions))

(provide 'job-fixture)
;;; job-fixture.el ends here
