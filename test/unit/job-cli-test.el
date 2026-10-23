;;; job-cli-test.el --- batch tests: drgnx job … through a hub in a child process; the job commands -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)
(require 'drgnx-hub)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/runtime-settings-fixture" drgnx-dir) nil t)

(ert-deftest drgnx-job-cli/propose-then-approve-then-status ()
  ;; the CLI starts the hub: Ratatoskr (DRGNX_RATATOSKR_BIN), detached from the test but ending with it
  (skip-unless (getenv "DRGNX_RATATOSKR_BIN"))
  (let* ((root (file-name-as-directory (make-temp-file "drgnx-job-cli" t)))
         (repo (concat root "repo/")) (plan (concat repo "docs/plans/p.md"))
         (bin (expand-file-name "bin/drgnx" drgnx-dir))
         (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" root "config") (concat "DRGNX_DATA_DIR=" root "data")
                                            (concat "XDG_STATE_HOME=" root "state") (concat "HOME=" root "home")
                                            "DRGNX_JOBS_LAUNCHER=detached" "DRGNX_NO_HUB_START"   ; the CLI starts the hub
                                            "RATATOSKR_SUPERVISOR=none" (format "DRGNX_HUB_PARENT_PID=%d" (emacs-pid))
                                            "GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@t.invalid" "GIT_COMMITTER_NAME=t"
                                            "GIT_COMMITTER_EMAIL=t@t.invalid")
                                      process-environment))
         (cli (lambda (&rest args) (with-temp-buffer (cons (apply #'call-process bin nil t nil args) (buffer-string))))))
    (unwind-protect
        (progn
          (make-directory (concat root "config") t) (make-directory (concat root "home") t)
          (make-directory (concat repo "docs/plans") t)
          (drgnx-test-write-settings    ; mock agents on every route: nothing real starts
           (concat root "config/settings.el")
           'drgnx-agents-profiles `(("mock" :command ("sh" ,(expand-file-name "test/fixtures/mock-acp-stdin.sh" drgnx-dir) ,(expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                                      "-l" ,(expand-file-name "test/fixtures/mock-acp.el" drgnx-dir))))
           'drgnx-agents-routes '((implement . "mock") (review . "mock")))
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
            (should (= (plist-get (funcall status) :budget) 2))             ; (Ratatoskr answers 2.0)
            (let ((before (mapcar (lambda (task) (plist-get task :status)) (plist-get (funcall status) :tasks))))
              (should (= (car (funcall cli "job" "approve" id)) 0))
              ;; started: running, or already done (a fast machine finishes the mock's tasks before this asks)
              (let ((s (funcall status)))
                (should (member (plist-get s :status) '("running" "done")))
                (should (= (length (plist-get s :tasks)) 2))
                (should-not (equal (mapcar (lambda (task) (plist-get task :status)) (plist-get s :tasks)) before))))
            ;; the mock is no Claude Code, so not job-safe: task 1 gets a card, and no agent starts (job-safe-test.el)
            (let ((deadline (+ (float-time) 15)) s card)
              (while (and (not (setq s (funcall status)
                                     card (seq-find (lambda (c) (equal (plist-get c :kind) "agent")) (plist-get s :cards))))
                          (< (float-time) deadline))
                (sleep-for 0.2))
              (should card)
              (should (string-search "mock cannot run a job's agent" (plist-get card :title)))
              (should (equal (plist-get (seq-find (lambda (task) (= (plist-get task :n) 1)) (plist-get s :tasks)) :status)
                             "needs-input"))
              (should (seq-empty-p (plist-get s :agents))))
            (should (string-search id (cdr (funcall cli "job" "status"))))          ; every job, as text
            (should (= (car (funcall cli "job" "stop" id)) 0))
            (should (equal (plist-get (funcall status) :status) "stopped"))
            (should (= (car (funcall cli "job" "resume" id "--budget" "5")) 0))
            (should (member (plist-get (funcall status) :status) '("running" "done")))
            (should (= (plist-get (funcall status) :budget) 5))
            (should (= (car (funcall cli "job" "approve" "job-nope")) 1))))
      (funcall cli "hub" "stop")
      (let ((deadline (+ (float-time) 5))) (while (and (drgnx-hub-running-p) (< (float-time) deadline)) (sleep-for 0.1)))
      ;; the socket goes while the hub still exits; its job's wrapper then writes the exit code into ROOT: ROOT is
      ;; removed once no job of it runs (the wrapper has ended)
      (ignore-errors (drgnx-test-wait (lambda () (not (seq-find (lambda (j) (eq (plist-get j :status) 'running)) (drgnx-jobs-list))))
                                      :what "the hub's job ended"))
      (delete-directory root t))))

;; the job window needs a hub; here it is stubbed: what `drgnx job' prints and when it refuses
(defun drgnx-job-cli-test--run (reply &rest args)
  "`drgnx-job-cli' with ARGS and the hub answering REPLY: (EXIT STDOUT CALLS)."
  (let ((command-line-args-left (cons "--" args)) (code nil) (calls nil) (out (generate-new-buffer " *job-cli*")))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'kill-emacs) (lambda (c) (setq code c) (throw 'drgnx-job-cli-test--done nil)))
                    ((symbol-function 'drgnx-hub-ensure) #'ignore)
                    ((symbol-function 'drgnx-hub-call-sync) (lambda (method params &rest _) (push (cons method params) calls) reply)))
            (catch 'drgnx-job-cli-test--done (let ((standard-output out)) (drgnx-job-cli))))
          (list code (with-current-buffer out (buffer-string)) calls))
      (kill-buffer out))))

(ert-deftest drgnx-job-cli/cli-json-empty-lists-and-bad-budget ()
  (let* ((summary '(:id "j" :title "T" :status "proposed" :repo "/r" :budget nil :spent nil
                        :estimate (:usd 1.0 :tokens 10 :unpriced nil)
                        :tasks ((:n 1 :title "a" :role "implement" :profile "mock" :status "ready" :deps nil))
                        :agents nil :cards nil :messages nil :decisions nil :permissions nil))
         (parse (lambda (text) (json-parse-string text :object-type 'plist :array-type 'list)))
         (r (drgnx-job-cli-test--run summary "status" "j" "--json"))
         (job (funcall parse (nth 1 r))))
    (should (eql (car r) 0))
    ;; a list with nothing in it is an empty array, not null
    (dolist (k '(:agents :cards :messages :decisions :permissions))
      (should (member k job))
      (should-not (plist-get job k)))
    (should (null (plist-get (car (plist-get job :tasks)) :deps)))
    (should (null (plist-get (plist-get job :estimate) :unpriced)))
    (should (eq (plist-get job :budget) :null))                         ; a number that is missing stays null
    (should (string-search "\"agents\":[]" (nth 1 (drgnx-job-cli-test--run summary "status" "j" "--json"))))
    (should (string-search "\"jobs\":[]" (nth 1 (drgnx-job-cli-test--run '(:jobs nil) "status" "--json"))))
    ;; a budget that is no number is refused before the hub hears of it
    (let ((bad (drgnx-job-cli-test--run summary "propose" "/p.md" "--budget" "ten")))
      (should (eql (car bad) 1))
      (should-not (nth 2 bad)))
    (should (eql (car (drgnx-job-cli-test--run summary "approve" "j" "--budget" "2.5")) 0))
    (dolist (ok '(".5" "5." "5"))
      (let ((r (drgnx-job-cli-test--run summary "approve" "j" "--budget" ok)))
        (should (eql (car r) 0))
        (should (numberp (plist-get (cdr (car (nth 2 r))) :budget)))))
    (should (eql (car (drgnx-job-cli-test--run summary "approve" "j" "--budget")) 1))))      ; no value

;; the commands: job-ui-test.el (module tools/jobs)

;;; job-cli-test.el ends here
