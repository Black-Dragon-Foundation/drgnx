;;; job-cli-test.el --- batch tests: drgnx job … through a hub in a child process; the job commands -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)
(require 'drgnx-hub)
(require 'drgnx)
(load (expand-file-name "modules/tools/drgnx-agents-ui" drgnx-dir) nil t)

(ert-deftest drgnx-job-cli/propose-then-approve-then-status ()
  (let* ((root (file-name-as-directory (make-temp-file "drgnx-job-cli" t)))
         (repo (concat root "repo/")) (plan (concat repo "docs/plans/p.md"))
         (bin (expand-file-name "bin/drgnx" drgnx-dir))
         (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" root "config") (concat "DRGNX_DATA_DIR=" root "data")
                                            (concat "XDG_STATE_HOME=" root "state") (concat "HOME=" root "home")
                                            "DRGNX_JOBS_LAUNCHER=detached" "DRGNX_NO_HUB_START"   ; the CLI starts the hub
                                            "GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@t.invalid" "GIT_COMMITTER_NAME=t"
                                            "GIT_COMMITTER_EMAIL=t@t.invalid")
                                      process-environment))
         (cli (lambda (&rest args) (with-temp-buffer (cons (apply #'call-process bin nil t nil args) (buffer-string))))))
    (unwind-protect
        (progn
          (make-directory (concat root "config") t) (make-directory (concat root "home") t)
          (make-directory (concat repo "docs/plans") t)
          (with-temp-file (concat root "config/agents.eld")   ; mock agents on every route: nothing real starts
            (prin1 `(:profiles (("mock" :command (,(expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                                  "-l" ,(expand-file-name "test/fixtures/mock-acp.el" drgnx-dir))))
                               :routes ((implement . "mock") (review . "mock")))
                   (current-buffer)))
          (write-region "# CLI\n\n### Task 1: one\n\n### Task 2: two\n**Depends:** Task 1\n" nil plan nil 'silent)
          (dolist (args '(("init" "-q" "-b" "main") ("add" "-A") ("commit" "-q" "-m" "start")))
            (let ((default-directory repo)) (should (eql 0 (apply #'call-process "git" nil nil nil args)))))
          (let* ((p (funcall cli "job" "propose" plan "--budget" "2"))
                 (id (and (string-match "\\(job-[0-9]+-[0-9]+\\(?:-[0-9]+\\)?\\)" (cdr p)) (match-string 1 (cdr p))))
                 (status (lambda () (json-parse-string (cdr (funcall cli "job" "status" id "--json")) :object-type 'plist))))
            (should (= (car p) 0))
            (should id)
            (should (string-search "Task 1: one" (cdr p)))
            (should (string-search "Task 2: two" (cdr p)))
            (should (string-search "estimate" (cdr p)))
            (should (equal (plist-get (funcall status) :status) "proposed"))
            (should (equal (plist-get (funcall status) :budget) 2))
            (should (= (car (funcall cli "job" "approve" id)) 0))
            (should (equal (plist-get (funcall status) :status) "running"))
            (should (= (length (plist-get (funcall status) :tasks)) 2))
            (should (string-search id (cdr (funcall cli "job" "status"))))          ; every job, as text
            (should (= (car (funcall cli "job" "stop" id)) 0))
            (should (equal (plist-get (funcall status) :status) "stopped"))
            (should (= (car (funcall cli "job" "resume" id "--budget" "5")) 0))
            (should (equal (plist-get (funcall status) :status) "running"))
            (should (equal (plist-get (funcall status) :budget) 5))
            (should (= (car (funcall cli "job" "approve" "job-nope")) 1))))
      (funcall cli "hub" "stop")
      (let ((deadline (+ (float-time) 5))) (while (and (drgnx-hub-running-p) (< (float-time) deadline)) (sleep-for 0.1)))
      (delete-directory root t))))

(ert-deftest drgnx-job/the-commands-are-registered ()
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
    (funcall (plist-get (alist-get 'tools/agents drgnx-modules--table) :setup))
    (dolist (id '(job-start job-approve job-status job-stop))
      (should (drgnx-commands-get id))
      (dolist (profile '("vscode" "emacs" "vim"))                                   ; a line in every key profile
        (should (with-temp-buffer (insert-file-contents (expand-file-name (format "keys/%s.eld" profile) drgnx-dir))
                                  (search-forward (format "(%s " id) nil t)))))))

;;; job-cli-test.el ends here
