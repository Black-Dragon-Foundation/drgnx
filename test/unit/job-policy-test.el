;;; job-policy-test.el --- batch tests: a job agent's permission requests and writes -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-hub)
(require 'drgnx-job)

(defmacro drgnx-job-policy-test--with (&rest body)
  "BODY with the hub served here, a proposed job J (task J#1, role implement), WT a worktree-like dir, EVENTS heard."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-job-policy" t)))
          (wt (concat root "wt/")) (plan (concat root "repo/docs/plans/p.md"))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" root "config") (concat "DRGNX_DATA_DIR=" root "data")
                                             (concat "XDG_STATE_HOME=" root "state") "DRGNX_NO_HUB_START")
                                       process-environment))
          (drgnx-work-db--handles nil) (drgnx-agents--sessions nil) (drgnx-hub--exit-function #'drgnx-hub-stop)
          (drgnx-gateway--registrations (make-hash-table :test #'equal))
          (drgnx-agents-profiles
           (list (list "mock" :command (list "sh" (expand-file-name "test/fixtures/mock-acp-stdin.sh" drgnx-dir) (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                             "-l" (expand-file-name "test/fixtures/mock-acp.el" drgnx-dir)))))
          (drgnx-job-routes '((implement . "mock"))) (events nil) (job nil)
          (drgnx-hub-event-functions (list (lambda (e d) (push (cons e d) events)))))
     (unwind-protect
         (progn
           (make-directory wt t) (make-directory (concat root "repo/docs/plans") t) (make-directory (concat root "config") t)
           (write-region "# J\n\n### Task 1: one\n" nil plan nil 'silent)
           (setq job (drgnx-job-propose plan :repo (concat root "repo")))
           (drgnx-hub-serve (drgnx-hub-socket))
           (drgnx-hub-connect)
           ,@body)
       (dolist (s drgnx-agents--sessions) (ignore-errors (drgnx-agents-kill s)))
       (drgnx-hub-disconnect)
       (drgnx-hub-stop)
       (drgnx-work-db-close-all)
       (delete-directory root t))))

(defun drgnx-job-policy-test--wait (pred &optional secs)
  (let ((deadline (+ (float-time) (or secs 10)))) (while (and (not (funcall pred)) (< (float-time) deadline)) (accept-process-output nil 0.05)))
  (funcall pred))

(defun drgnx-job-policy-test--agent (wt job &optional no-job)
  "A mock session working on J#1 in WT (or, NO-JOB, a plain session there), idle."
  (let ((s (if no-job (drgnx-agents-start "mock" wt) (drgnx-agents-start "mock" wt (concat job "#1") job))))
    (unless no-job (drgnx-coord-force-status (concat job "#1") "running" (drgnx-agent-session-id s)))
    (drgnx-job-policy-test--wait (lambda () (eq (drgnx-agent-session-status s) 'idle)))
    s))

(defun drgnx-job-policy-test--said (s text)
  (drgnx-job-policy-test--wait (lambda () (string-search text (format "%S" (drgnx-agent-session-entries s))))))

(ert-deftest drgnx-job/edits-and-commands-in-the-worktree-need-no-one ()
  (drgnx-job-policy-test--with
    (let ((s (drgnx-job-policy-test--agent wt job)))
      (drgnx-agents-send s (format "permission edit :: Edit a.txt :: %sa.txt" wt))
      (should (drgnx-job-policy-test--said s "permission: allow"))
      (drgnx-agents-send s "permission execute :: make test")
      (should (drgnx-job-policy-test--wait (lambda () (= 2 (cl-count-if (lambda (e) (string-search "permission: allow" (format "%s" (plist-get e :text))))
                                                                        (drgnx-agent-session-entries s))))))
      (should-not (drgnx-agent-session-permissions s)))))

(ert-deftest drgnx-job/network-and-installs-go-to-the-user ()
  (drgnx-job-policy-test--with
    (let ((s (drgnx-job-policy-test--agent wt job)))
      (drgnx-agents-send s "permission execute :: npm install left-pad")
      (should (drgnx-job-policy-test--wait (lambda () (drgnx-agent-session-permissions s))))
      (should (equal (plist-get (drgnx-coord-task (concat job "#1")) :status) "needs-input"))
      (should (drgnx-job-policy-test--wait (lambda () (seq-find (lambda (e) (and (equal (car e) "card") (equal (plist-get (cdr e) :kind) "permission"))) events))))
      (should (seq-find (lambda (m) (string-prefix-p "[permission]" (plist-get m :text))) (drgnx-coord-inbox "user")))
      ;; the user's answer: the task works again
      (drgnx-hub-call-sync "agents/permission" (list :id (drgnx-agent-session-id s) :request (plist-get (car (drgnx-agent-session-permissions s)) :id) :option "allow"))
      (should (drgnx-job-policy-test--said s "permission: allow"))
      (should (equal (plist-get (drgnx-coord-task (concat job "#1")) :status) "running"))
      (drgnx-agents-send s "permission fetch :: https://example.com")
      (should (drgnx-job-policy-test--wait (lambda () (drgnx-agent-session-permissions s)))))))

(ert-deftest drgnx-job/a-path-out-of-the-worktree-is-outside ()
  (drgnx-job-policy-test--with
    (make-symbolic-link root (concat wt "out"))
    (let ((s (drgnx-job-policy-test--agent wt job)))
      (drgnx-agents-send s (format "permission edit :: Edit :: %s../elsewhere/x" wt))
      (should (drgnx-job-policy-test--wait (lambda () (drgnx-agent-session-permissions s))))
      (drgnx-agents-answer-permission s (car (drgnx-agent-session-permissions s)) "reject")
      (drgnx-job-policy-test--wait (lambda () (eq (drgnx-agent-session-status s) 'idle)))
      (drgnx-agents-send s (format "permission edit :: Edit :: %sout/x" wt))
      (should (drgnx-job-policy-test--wait (lambda () (drgnx-agent-session-permissions s)))))))

(ert-deftest drgnx-job/the-agent-writes-in-its-worktree-directly ()
  (drgnx-job-policy-test--with
    (write-region "first\n" nil (concat wt "f.txt") nil 'silent)
    (let ((s (drgnx-job-policy-test--agent wt job)))
      (drgnx-agents-send s (format "write %sf.txt" wt))
      (should (drgnx-job-policy-test--said s "write done"))
      (should (string-prefix-p "CHANGED first" (with-temp-buffer (insert-file-contents (concat wt "f.txt")) (buffer-string))))
      (should-not (drgnx-agent-session-reviews s))
      (let ((out (concat root "elsewhere.txt")))
        (write-region "x\n" nil out nil 'silent)
        (drgnx-agents-send s (format "write %s" out))
        (should (drgnx-job-policy-test--wait (lambda () (drgnx-agent-session-reviews s))))
        (should (equal (with-temp-buffer (insert-file-contents out) (buffer-string)) "x\n"))))))

(ert-deftest drgnx-job/interactive-sessions-are-unchanged ()
  (drgnx-job-policy-test--with
    (write-region "first\n" nil (concat wt "f.txt") nil 'silent)
    (let ((s (drgnx-job-policy-test--agent wt job t)))
      (drgnx-agents-send s (format "permission edit :: Edit a.txt :: %sa.txt" wt))
      (should (drgnx-job-policy-test--wait (lambda () (drgnx-agent-session-permissions s))))
      (drgnx-agents-answer-permission s (car (drgnx-agent-session-permissions s)) "allow")
      (drgnx-job-policy-test--wait (lambda () (eq (drgnx-agent-session-status s) 'idle)))
      (drgnx-agents-send s (format "write %sf.txt" wt))
      (should (drgnx-job-policy-test--wait (lambda () (drgnx-agent-session-reviews s)))))))

(ert-deftest drgnx-job/a-relative-write-path-is-refused ()
  ;; checked against the worktree, written against the hub's directory: neither — it goes to the user
  (drgnx-job-policy-test--with
    (let ((s (drgnx-agents--make :id "s-w" :name "w" :profile "mock" :cwd wt :task (concat job "#1") :job job))
          (default-directory root))
      (should-not (drgnx-job--request s "fs/write_text_file" (list :path "rel.txt" :content "x") 1))
      (should-not (file-exists-p (concat root "rel.txt")))
      (should-not (file-exists-p (concat wt "rel.txt"))))))

(ert-deftest drgnx-job/the-reviewer-may-read-the-diff ()
  (let ((tree temporary-file-directory))
    (dolist (cmd '("git diff job/j...HEAD" "git log --oneline -5" "git show HEAD" "git status"))
      (should (eq (drgnx-job-policy "review" (list :kind "execute" :title cmd) tree) 'allow)))
    (dolist (cmd '("git diff; curl x" "git diff | sh" "git push" "make test" "git diff $(curl x)"))
      (should (eq (drgnx-job-policy "review" (list :kind "execute" :title cmd) tree) 'ask)))))

(ert-deftest drgnx-job/outward-commands-are-found-anywhere-in-the-line ()
  (let ((tree temporary-file-directory))
    (with-temp-buffer
      (emacs-lisp-mode)                                       ; whatever buffer the hub is in
      (dolist (cmd '("/usr/bin/curl -s x" "echo `/usr/bin/curl -s x`" "git -C . push" "git  push origin" "git clone https://x/y"
                     "npx cowsay" "npm ci" "go install x@latest" "bun add x" "pipx install x" "nc host 80" "gh pr create"
                     "sh -c \"curl x\"" "env A=1 wget x" "npm  install"))
        (should (eq (drgnx-job-policy "implement" (list :kind "execute" :title cmd) tree) 'ask)))
      (dolist (cmd '("make test" "git commit -m x" "git status" "ls -la" "cargo test"))
        (should (eq (drgnx-job-policy "implement" (list :kind "execute" :title cmd) tree) 'allow)))
      ;; the command itself, when the title says less
      (should (eq (drgnx-job-policy "implement" '(:kind "execute" :title "Run a script" :rawInput (:command "curl x")) tree) 'ask)))))

(ert-deftest drgnx-job/allow-without-allow-once-option-is-a-card ()
  ;; the policy allows it, but the agent offered no allow_once option to answer with: it goes to the user
  (drgnx-job-policy-test--with
    (let ((s (drgnx-agents--make :id "s-w" :name "w" :profile "mock" :cwd wt :task (concat job "#1") :job job)))
      (should-not (drgnx-job--request s "session/request_permission"
                                      (list :toolCall (list :kind "read" :title "Read a.txt")
                                            :options (vector (list :optionId "no" :kind "reject_once")))
                                      7))
      (should (seq-find (lambda (c) (equal (plist-get c :kind) "permission")) (drgnx-coord-cards job "open"))))))

(ert-deftest drgnx-job/a-write-into-a-new-directory-makes-it ()
  (drgnx-job-policy-test--with
    (let ((s (drgnx-agents--make :id "s-w" :name "w" :profile "mock" :cwd wt :task (concat job "#1") :job job))
          (path (concat wt "new/sub/f.txt")))
      (should (equal (drgnx-job--request s "fs/write_text_file" (list :path path :content "x\n") 1) '(:result nil)))
      (should (equal (with-temp-buffer (insert-file-contents path) (buffer-string)) "x\n")))))

;;; job-policy-test.el ends here
