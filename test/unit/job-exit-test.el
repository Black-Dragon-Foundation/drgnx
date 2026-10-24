;;; job-exit-test.el --- batch tests: M9b's exit criteria end to end with mock agents -*- lexical-binding: t -*-
;; The criteria each part's own tests cover in depth are named where they are: a clash settled and heard
;; (job-clash-review-test.el), message states and peer messages (coord-*-test.el), the gateway (gateway-test.el),
;; permission cards (job-policy-test.el), budget and fallback (job-budget-test.el), the job in the Work cockpit
;; (mod-cockpit-cards-test.el and test/ui/job-window-test.el).  Here: a whole job, the credential files, closing the
;; job's parts.
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/support/work-db-gate" drgnx-dir) nil t)   ; the tests below are of the `local' writer
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/job-fixture" drgnx-dir) nil t)   ; a repo, the hub, mock agents
(require 'drgnx)
(load (expand-file-name "modules/tools/drgnx-job-ui" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-cockpit" drgnx-dir) nil t)

(defconst drgnx-job-exit-test--four
  ;; each task in its own file: parallel tasks merge without conflict
  (concat "# Four\n\n### Task 1: one\n\nIn its own file.\n\n### Task 2: two\n\nIn its own file.\n\n"
          "### Task 3: three\n**Depends:** Task 1\n\nIn its own file.\n\n### Task 4: four\n**Depends:** Task 2, Task 3\n\nIn its own file.\n"))

(defun drgnx-job-exit-test--run (plan repo &optional midway)
  "Run the four-task PLAN of REPO with automatic start to the end: the job's id, after the checks along the way.
MIDWAY (a function of the id) is called once the job is running, its tasks not done."
  (let* ((drgnx-job-auto-start t) (drgnx-job-max-agents 3) (main (drgnx-job-run-test--git repo "rev-parse" "main"))
         (id (drgnx-job-propose plan)) (both nil))
    (should (equal (plist-get (drgnx-coord-job id) :status) "running"))                   ; started by itself
    (should (equal (drgnx-job-run-test--status id 3) "pending"))                         ; waits for task 1
    (should (equal (drgnx-job-run-test--status id 4) "pending"))
    (when midway (funcall midway id))
    ;; tasks 1 and 2 at once, each in a worktree of its own
    (should (drgnx-job-run-test--wait
             (lambda () (or both (setq both (and (file-directory-p (drgnx-job--task-tree id 1)) (file-directory-p (drgnx-job--task-tree id 2))
                                                 (not (file-directory-p (drgnx-job--task-tree id 3)))))))
             15))
    (let ((done (condition-case nil (drgnx-job-run-test--wait (lambda () (equal (plist-get (drgnx-coord-job id) :status) "done")) 90)
                  (ert-test-failed nil))))
      ;; a job that does not finish says where it stands (the failure carries it): the tasks, the open cards, what each session last said
      (unless done (ert-fail (list :tasks (mapcar (lambda (task) (list (plist-get task :n) (plist-get task :status) (plist-get task :agent)))
                                                  (drgnx-coord-tasks id))
                                   :cards (mapcar (lambda (c) (list (plist-get c :kind) (plist-get c :task) (plist-get c :title)))
                                                  (drgnx-coord-cards id "open"))
                                   :sessions (mapcar (lambda (s)
                                                       (list (drgnx-agent-session-id s) (drgnx-agent-session-task s) (drgnx-agent-session-status s)
                                                             (let ((said (drgnx-job-clash--said s))) (substring said (max 0 (- (length said) 300))))))
                                                     drgnx-agents--sessions)))))
    ;; task 3 started from the job branch with task 1 merged
    (should (string-search (format "work for %s#1" id) (drgnx-job-run-test--git repo "log" "--format=%s" (format "job/%s-3" id))))
    (should (= 4 (length (split-string (drgnx-job-run-test--git repo "log" "--merges" "--format=%s" (concat "job/" id)) "\n" t))))
    (should (equal (drgnx-job-run-test--git repo "rev-parse" "main") main))               ; nothing reached main
    id))

(drgnx-work-db-writer-deftest drgnx-job-exit/four-tasks-three-agents ()
  :tags '(:frozen)
  (drgnx-job-run-test--with drgnx-job-exit-test--four
    (drgnx-job-exit-test--run plan repo)))

(defconst drgnx-job-exit-test--credential-files '(".claude/.credentials.json" ".codex/auth.json" ".config/gh/hosts.yml")
  "The subscription CLIs' logins, relative to HOME.")

(defun drgnx-job-exit-test--canaries (home)
  "FIFOs for the credential files under HOME, each with the word `canary' in it (held open by a shell so it stays):
whoever reads one — a process of any kind — takes the word away.  The holders, to `drgnx-job-exit-test--unread-p'."
  (mapcar (lambda (f)
            (let ((path (concat home f)) (ready nil))
              (make-directory (file-name-directory path) t)
              (call-process "mkfifo" nil nil nil path)
              (let ((p (make-process :name "canary" :noquery t :connection-type 'pipe
                                     :command (list "sh" "-c" "exec 3<>\"$1\"; printf canary >&3; echo ready; read x" "sh" path)
                                     :filter (lambda (_p out) (when (string-search "ready" out) (setq ready t))))))
                (should (drgnx-job-run-test--wait (lambda () ready) 5))
                (cons path p))))
          drgnx-job-exit-test--credential-files))

(defun drgnx-job-exit-test--unread-p (canary)
  "Is the word still in CANARY's FIFO (a (PATH . HOLDER))?  Looking takes it out and puts it back.
An `x' goes in first, so the read never waits on an empty FIFO (POSIX dd: macOS's has no iflag=nonblock)."
  (equal (with-temp-buffer
           (call-process "sh" nil t nil "-c"
                         "exec 3<>\"$1\"; printf x >&3; w=$(dd bs=7 count=1 <&3 2>/dev/null); w=${w%x}; printf '%s' \"$w\" >&3; printf '%s' \"$w\""
                         "sh" (car canary))
           (buffer-string))
         "canary"))

(defun drgnx-job-exit-test--release (canaries)
  (dolist (c canaries) (when (process-live-p (cdr c)) (delete-process (cdr c)))))

(drgnx-work-db-writer-deftest drgnx-job-exit/a-process-reading-a-credential-file-is-seen ()
  ;; the guard of the next test works for any process, not only this Emacs
  (drgnx-job-run-test--with "# One\n\n### Task 1: one\n"
    (let ((canaries (drgnx-job-exit-test--canaries (concat root "home/"))))
      (unwind-protect
          (progn
            (should (seq-every-p #'drgnx-job-exit-test--unread-p canaries))
            (call-process "dd" nil nil nil (concat "if=" (car (car canaries))) "bs=3" "count=1")   ; no `timeout' on macOS; the word is there
            (should-not (drgnx-job-exit-test--unread-p (car canaries)))
            (should (drgnx-job-exit-test--unread-p (cadr canaries))))
        (drgnx-job-exit-test--release canaries)))))

(drgnx-work-db-writer-deftest drgnx-job-exit/no-credential-file-is-opened ()
  :tags '(:frozen)
  ;; the subscription CLIs' logins under a fake HOME: drgnx — this Emacs, the hub here and every process it starts —
  ;; never touches them.  This Emacs: a file name handler on the file names (wherever they are); the others: FIFOs.
  (drgnx-job-run-test--with drgnx-job-exit-test--four
    (let* ((home (concat root "home/")) (opened nil)
           (canaries (drgnx-job-exit-test--canaries home))
           (process-environment (cons (concat "HOME=" home) process-environment))
           (handler (lambda (op &rest args)
                      (push (cons op args) opened)
                      (let ((inhibit-file-name-handlers (cons 'drgnx-job-exit-test--watch inhibit-file-name-handlers))
                            (inhibit-file-name-operation op))
                        (if (and (stringp (car args)) (string-prefix-p home (expand-file-name (car args))))
                            (apply op args)
                          (signal 'file-missing (list "credential file" (car args))))))))   ; never the real one
      (unwind-protect
          (progn
            (defalias 'drgnx-job-exit-test--watch handler)
            (let ((file-name-handler-alist
                   (cons (cons "/\\.\\(?:claude/\\.credentials\\.json\\|codex/auth\\.json\\|config/gh/hosts\\.yml\\)\\'" 'drgnx-job-exit-test--watch)
                         file-name-handler-alist)))
              (drgnx-job-exit-test--run plan repo))
            (should-not opened)
            (should (seq-every-p #'drgnx-job-exit-test--unread-p canaries)))
        (drgnx-job-exit-test--release canaries)))))

(drgnx-work-db-writer-deftest drgnx-job-exit/closing-the-window-leaves-agents-running ()
  (drgnx-job-run-test--with "# One\n\n### Task 1: one\n"
    (let* ((drgnx-job-max-agents 0) (drgnx-job-review nil) (id (drgnx-job-propose plan)) (s nil))
      (drgnx-job-approve id)
      (setq s (drgnx-agents-start "mock" repo (concat id "#1") id))
      (drgnx-coord-force-status (concat id "#1") "running" (drgnx-agent-session-id s))
      (drgnx-job-run-test--wait (lambda () (eq (drgnx-agent-session-status s) 'idle)))
      (drgnx-agents-send s "slow")
      (should-not (drgnx-job-ui-show id))                                    ; the cockpit filtered to it: no frame
      (should (drgnx-job-run-test--wait (lambda () (string-search "Task 1: one" (with-current-buffer (drgnx-cockpit-cards-buffer) (buffer-string))))))
      (dolist (b (list (drgnx-cockpit-cards-buffer) (drgnx-cockpit-decisions-buffer))) (kill-buffer b))   ; its parts close
      (setq drgnx-cockpit-graph-current-filter nil)
      (should (eq (drgnx-agent-session-status s) 'busy))
      (should (memq s (drgnx-agents-sessions)))
      (should (equal (plist-get (drgnx-coord-job id) :status) "running"))
      (delete-other-windows))))

(drgnx-work-db-writer-deftest drgnx-job-exit/a-clash-in-the-middle-of-a-job ()
  :tags '(:frozen)
  ;; two agents decide opposite things while the job runs: one card, a reviewer on it; the job goes on to its end and
  ;; the reviewer ends with it
  (drgnx-job-run-test--with drgnx-job-exit-test--four
    (let* ((card nil)
           (id (drgnx-job-exit-test--run
                plan repo
                (lambda (id)
                  (drgnx-coord-decide :kind "build" :subject "the CSV export" :author "s-a" :task (concat id "#1") :job id
                                      :reason "users asked" :seen (drgnx-coord-version))
                  (drgnx-coord-decide :kind "wont-build" :subject "the csv export" :author "s-b" :task (concat id "#2") :job id
                                      :reason "out of scope" :seen (drgnx-coord-version))
                  (drgnx-job-clash-scan id)
                  (setq card (car (seq-filter (lambda (c) (equal (plist-get c :kind) "clash")) (drgnx-coord-cards id "open"))))
                  (should card)
                  (should (stringp (plist-get (plist-get card :data) :reviewer)))
                  (should (equal (plist-get (plist-get card :data) :reviewer)
                                 (drgnx-agent-session-id (drgnx-job-clash--reviewer (plist-get card :id)))))))))
      (should (= 1 (length (seq-filter (lambda (c) (equal (plist-get c :kind) "clash")) (drgnx-coord-cards id)))))
      (should-not (drgnx-job-clash--reviewer (plist-get card :id)))
      (should-not (seq-find (lambda (s) (and (equal (drgnx-agent-session-job s) id) (not (eq (drgnx-agent-session-status s) 'exited))))
                            drgnx-agents--sessions)))))

;;; job-exit-test.el ends here
