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

(defun drgnx-job-policy-test--swap (dir outside)
  "Put a symlink to OUTSIDE where the directory DIR was (moved beside it), with the real `rename-file'."
  (funcall (get 'drgnx-job-policy-test--swap 'rename) (directory-file-name dir) (concat (directory-file-name dir) "-was"))
  (make-symbolic-link outside (directory-file-name dir)))
(put 'drgnx-job-policy-test--swap 'rename (symbol-function 'rename-file))

(ert-deftest drgnx-job/a-link-swapped-in-after-the-check-is-never-written-through ()
  ;; Check, then write: the policy found the path inside the worktree (the last check is the agent-config one, which
  ;; fails closed on a path that is no longer inside); a directory on its way swapped for a symlink before the write
  ;; led it out.  The write resolves the path itself: refused (an error the agent gets).
  (drgnx-job-policy-test--with
    (let* ((s (drgnx-agents--make :id "s-w" :name "w" :profile "mock" :cwd wt :task (concat job "#1") :job job))
           (outside (concat root "outside/")) (real (symbol-function 'drgnx-job--agent-config-p)) (swapped nil))
      (make-directory (concat wt "sub")) (make-directory outside)
      (cl-letf (((symbol-function 'drgnx-job--agent-config-p)
                 (lambda (p tree) (prog1 (funcall real p tree)
                                    (unless swapped (setq swapped t) (drgnx-job-policy-test--swap (concat wt "sub") outside))))))
        (should-error (drgnx-job--request s "fs/write_text_file" (list :path (concat wt "sub/f.txt") :content "x\n") 1)))
      (should swapped)
      (should-not (file-exists-p (concat outside "f.txt"))))))

(ert-deftest drgnx-job/a-directory-swapped-during-the-rename-is-an-error ()
  ;; The window Emacs cannot close (it has no openat): a directory swapped right at the rename is found by the check
  ;; after it, and said.
  (drgnx-job-policy-test--with
    (let* ((s (drgnx-agents--make :id "s-w" :name "w" :profile "mock" :cwd wt :task (concat job "#1") :job job))
           (outside (concat root "outside/")) (real (symbol-function 'rename-file)) (swapped nil))
      (make-directory (concat wt "sub")) (make-directory outside)
      (cl-letf (((symbol-function 'rename-file)
                 (lambda (from to &optional ok)
                   (prog1 (funcall real from to ok)
                     (unless swapped (setq swapped t) (drgnx-job-policy-test--swap (concat wt "sub") outside))))))
        (should-error (drgnx-job--request s "fs/write_text_file" (list :path (concat wt "sub/f.txt") :content "x\n") 1)))
      (should (equal (with-temp-buffer (insert-file-contents (concat wt "sub-was/f.txt")) (buffer-string)) "x\n"))
      (should-not (file-exists-p (concat outside "f.txt"))))))

(ert-deftest drgnx-job/a-write-is-a-temp-file-renamed-over-the-target ()
  ;; written whole: the file keeps its modes, a link inside the worktree is written through and stays a link, and
  ;; no temp file is left beside it
  (drgnx-job-policy-test--with
    (let ((s (drgnx-agents--make :id "s-w" :name "w" :profile "mock" :cwd wt :task (concat job "#1") :job job)))
      (write-region "old\n" nil (concat wt "run.sh") nil 'silent)
      (set-file-modes (concat wt "run.sh") #o755)
      (make-symbolic-link "run.sh" (concat wt "link.sh"))
      (should (equal (drgnx-job--request s "fs/write_text_file" (list :path (concat wt "link.sh") :content "new\n") 1) '(:result nil)))
      (should (file-symlink-p (concat wt "link.sh")))
      (should (equal (with-temp-buffer (insert-file-contents (concat wt "run.sh")) (buffer-string)) "new\n"))
      (should (= (file-modes (concat wt "run.sh")) #o755))
      (should (equal (directory-files wt nil "\\`[^.]\\|\\.drgnx") '("link.sh" "run.sh"))))))

(ert-deftest drgnx-job/a-new-file-gets-the-usual-modes ()
  ;; the temp file is made 0600: a new file gets what `write-region' would give (0666 less the umask)
  (drgnx-job-policy-test--with
    (let ((s (drgnx-agents--make :id "s-w" :name "w" :profile "mock" :cwd wt :task (concat job "#1") :job job)))
      (should (equal (drgnx-job--request s "fs/write_text_file" (list :path (concat wt "new.txt") :content "x\n") 1) '(:result nil)))
      (should (= (file-modes (concat wt "new.txt")) (logand #o666 (default-file-modes)))))))

(ert-deftest drgnx-job/a-read-only-file-is-refused ()
  ;; a file the agent could not write before (0444) is not replaced by the rename
  (skip-unless (/= 0 (user-uid)))       ; root can write a 0444 file (CI's containers run as root): nothing to refuse
  (drgnx-job-policy-test--with
    (let ((s (drgnx-agents--make :id "s-w" :name "w" :profile "mock" :cwd wt :task (concat job "#1") :job job)))
      (write-region "keep\n" nil (concat wt "ro.txt") nil 'silent)
      (set-file-modes (concat wt "ro.txt") #o444)
      (should-error (drgnx-job--request s "fs/write_text_file" (list :path (concat wt "ro.txt") :content "x\n") 2))
      (should (equal (with-temp-buffer (insert-file-contents (concat wt "ro.txt")) (buffer-string)) "keep\n"))
      (should (equal (directory-files wt nil "\\.drgnx") nil)))))

(ert-deftest drgnx-job/a-remote-write-path-never-reaches-tramp ()
  ;; the policy's check resolved the path with file name handlers on: /ssh:… made the hub connect
  (drgnx-job-policy-test--with
    (let ((s (drgnx-agents--make :id "s-w" :name "w" :profile "mock" :cwd wt :task (concat job "#1") :job job))
          (real (symbol-function 'tramp-file-name-handler)))
      (cl-letf (((symbol-function 'tramp-file-name-handler)
                 (lambda (op &rest args) (if (eq op 'file-remote-p) (apply real op args) (error "Touched a remote file: %s" op)))))
        (should-not (drgnx-job--request s "fs/write_text_file" (list :path "/ssh:nobody@example.invalid:/x" :content "x\n") 1))
        (should (eq (drgnx-job-policy "implement" (list :kind "edit" :locations (vector '(:path "/ssh:nobody@example.invalid:/x"))) wt)
                    'ask))))))

(load (expand-file-name "test/fixtures/handler-trap" drgnx-dir) nil t)

(ert-deftest drgnx-job/a-path-through-a-planted-link-is-decided-with-no-file-name-handler ()
  ;; the policy and the write resolved the agent's path with handlers on: a link in the worktree climbing `../' to
  ;; `ssh:host:' made the hub load Tramp and connect (`sudo::': start sudo)
  (drgnx-job-policy-test--with
    (let ((s (drgnx-agents--make :id "s-l" :name "w" :profile "mock" :cwd wt :task (concat job "#1") :job job))
          (paths (drgnx-test-hostile-paths wt)) (n 0))
      (drgnx-test-with-handler-trap
        (dolist (p (plist-get paths :outside))
          (dolist (kind '("read" "edit"))
            (should (eq (drgnx-job-policy "implement" (list :kind kind :locations (vector (list :path p))) wt) 'ask)))
          (should-not (drgnx-job--request s "fs/write_text_file" (list :path p :content "x\n") (cl-incf n))))   ; a card
        (dolist (p (plist-get paths :inside))
          (should (eq (drgnx-job-policy "implement" (list :kind "edit" :locations (vector (list :path p))) wt) 'allow)))
        (should (equal (drgnx-job--request s "fs/write_text_file" (list :path (concat wt "a.zip/y") :content "z\n") 99) '(:result nil)))
        (should-not drgnx-test-handler-calls))
      (should (equal (with-temp-buffer (insert-file-contents-literally (concat wt "a.zip/y")) (buffer-string)) "z\n")))))

(ert-deftest drgnx-job/planted-links-never-load-tramp-jka-compr-or-epa ()
  ;; end to end, in an Emacs of its own (-Q: nothing loaded them before); Tramp's handler fails if it is ever reached
  (let* ((root (file-name-as-directory (make-temp-file "drgnx-job-links" t))) (wt (concat root "wt/")))
    (unwind-protect
        (let* ((paths (progn (make-directory wt) (drgnx-test-hostile-paths wt)))
               (all (append (plist-get paths :outside) (plist-get paths :inside)))
               (form `(progn
                        (with-eval-after-load 'tramp
                          (advice-add 'tramp-file-name-handler :override (lambda (&rest _) (error "Tramp was reached"))))
                        (require 'drgnx-job)
                        (let* ((loaded (lambda () (list (featurep 'tramp) (featurep 'jka-compr) (featurep 'epa-file))))
                               (before (funcall loaded))
                               (decisions (mapcar (lambda (p)
                                                    (condition-case err
                                                        (list (drgnx-job-policy "implement" (list :kind "read" :locations (vector (list :path p))) ,wt)
                                                              (and (drgnx-job--agent-config-p p ,wt) t))
                                                      (error (error-message-string err))))
                                                  ',all)))
                          (prin1 (list before decisions (funcall loaded))))))
               (out (with-temp-buffer
                      (call-process (expand-file-name invocation-name invocation-directory) nil '(t nil) nil
                                    "-Q" "--batch" "-L" (expand-file-name "core" drgnx-dir) "--eval" (prin1-to-string form))
                      (buffer-string)))
               (result (car (read-from-string out))))
          (should (equal (nth 0 result) '(nil nil nil)))
          (should (equal (nth 1 result) (append (mapcar (lambda (_) '(ask t)) (plist-get paths :outside))
                                                (mapcar (lambda (_) '(allow nil)) (plist-get paths :inside)))))
          (should (equal (nth 2 result) '(nil nil nil))))
      (delete-directory root t))))

;;; job-policy-test.el ends here
