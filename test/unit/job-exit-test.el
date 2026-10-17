;;; job-exit-test.el --- batch tests: M9b's exit criteria end to end with mock agents -*- lexical-binding: t -*-
;; The criteria each part's own tests cover in depth are named where they are: a clash settled and heard
;; (job-clash-review-test.el), message states and peer messages (coord-*-test.el), the gateway (gateway-test.el),
;; permission cards (job-policy-test.el), budget and fallback (job-budget-test.el), the window (job-ui-test.el and
;; test/ui/job-window-test.el).  Here: a whole job, the credential files, closing the window.
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/job-fixture" drgnx-dir) nil t)   ; a repo, the hub, mock agents
(require 'drgnx)
(load (expand-file-name "modules/tools/drgnx-job-ui" drgnx-dir) nil t)

(defconst drgnx-job-exit-test--four
  ;; each task in its own file: parallel tasks merge without conflict
  (concat "# Four\n\n### Task 1: one\n\nIn its own file.\n\n### Task 2: two\n\nIn its own file.\n\n"
          "### Task 3: three\n**Depends:** Task 1\n\nIn its own file.\n\n### Task 4: four\n**Depends:** Task 2, Task 3\n\nIn its own file.\n"))

(defun drgnx-job-exit-test--run (plan repo)
  "Run the four-task PLAN of REPO with automatic start to the end: the job's id, after the checks along the way."
  (let* ((drgnx-job-auto-start t) (drgnx-job-max-agents 3) (main (drgnx-job-run-test--git repo "rev-parse" "main"))
         (id (drgnx-job-propose plan)) (both nil))
    (should (equal (plist-get (drgnx-coord-job id) :status) "running"))                   ; started by itself
    (should (equal (drgnx-job-run-test--status id 3) "pending"))                         ; waits for task 1
    (should (equal (drgnx-job-run-test--status id 4) "pending"))
    ;; tasks 1 and 2 at once, each in a worktree of its own
    (should (drgnx-job-run-test--wait
             (lambda () (or both (setq both (and (file-directory-p (drgnx-job--task-tree id 1)) (file-directory-p (drgnx-job--task-tree id 2))
                                                 (not (file-directory-p (drgnx-job--task-tree id 3)))))))
             15))
    (should (drgnx-job-run-test--wait (lambda () (equal (plist-get (drgnx-coord-job id) :status) "done")) 90))
    ;; task 3 started from the job branch with task 1 merged
    (should (string-search (format "work for %s#1" id) (drgnx-job-run-test--git repo "log" "--format=%s" (format "job/%s-3" id))))
    (should (= 4 (length (split-string (drgnx-job-run-test--git repo "log" "--merges" "--format=%s" (concat "job/" id)) "\n" t))))
    (should (equal (drgnx-job-run-test--git repo "rev-parse" "main") main))               ; nothing reached main
    id))

(ert-deftest drgnx-job-exit/four-tasks-three-agents ()
  (drgnx-job-run-test--with drgnx-job-exit-test--four
    (drgnx-job-exit-test--run plan repo)))

(ert-deftest drgnx-job-exit/no-credential-file-is-opened ()
  ;; the subscription CLIs' logins under a fake HOME: drgnx (this Emacs, the hub here) never touches them
  (drgnx-job-run-test--with drgnx-job-exit-test--four
    (let* ((home (concat root "home/")) (opened nil)
           (creds (mapcar (lambda (f) (concat home f)) '(".claude/.credentials.json" ".codex/auth.json" ".config/gh/hosts.yml")))
           (process-environment (cons (concat "HOME=" home) process-environment))
           (handler (lambda (op &rest args)
                      (push (cons op args) opened)
                      (let ((inhibit-file-name-handlers (cons 'drgnx-job-exit-test--watch inhibit-file-name-handlers))
                            (inhibit-file-name-operation op))
                        (apply op args)))))
      (dolist (f creds) (make-directory (file-name-directory f) t) (write-region "secret" nil f nil 'silent))
      (defalias 'drgnx-job-exit-test--watch handler)
      (let ((file-name-handler-alist (cons (cons (concat "\\`" (regexp-quote home) "\\.\\(claude\\|codex\\|config/gh\\)/") 'drgnx-job-exit-test--watch)
                                           file-name-handler-alist)))
        (drgnx-job-exit-test--run plan repo))
      (should-not opened))))

(ert-deftest drgnx-job-exit/closing-the-window-leaves-agents-running ()
  (drgnx-job-run-test--with "# One\n\n### Task 1: one\n"
    (let* ((drgnx-job-max-agents 0) (drgnx-job-review nil) (id (drgnx-job-propose plan)) (s nil))
      (drgnx-job-approve id)
      (setq s (drgnx-agents-start "mock" repo (concat id "#1") id))
      (drgnx-coord-force-status (concat id "#1") "running" (drgnx-agent-session-id s))
      (drgnx-job-run-test--wait (lambda () (eq (drgnx-agent-session-status s) 'idle)))
      (drgnx-agents-send s "slow")
      (drgnx-job-ui-show id)                                                 ; batch: laid out in this frame
      (should (drgnx-job-run-test--wait (lambda () (string-search "Task 1: one" (with-current-buffer (drgnx-job-ui--buffer id 'tasks) (buffer-string))))))
      (dolist (p '(tasks cards log)) (kill-buffer (drgnx-job-ui--buffer id p)))   ; the window closes
      (should (eq (drgnx-agent-session-status s) 'busy))
      (should (memq s (drgnx-agents-sessions)))
      (should (equal (plist-get (drgnx-coord-job id) :status) "running"))
      (delete-other-windows))))

;;; job-exit-test.el ends here
