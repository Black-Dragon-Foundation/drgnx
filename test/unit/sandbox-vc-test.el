;;; sandbox-vc-test.el --- batch tests: the VC guard — no git in a job's snapshot folder outside its sandbox -*- lexical-binding: t -*-
;; Fixture folders live in the test's temporary directory; the folder list goes to a temporary XDG_STATE_HOME.
(require 'ert)
(require 'cl-lib)
(require 'vc)
(require 'project)
(require 'drgnx-sandbox-vc)

(defun drgnx-sandbox-vc-test--git (dir &rest args)
  "Git ARGS in DIR (the test's own fixture, run with the guard off or DIR unregistered), its output."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (unless (eql 0 (apply #'call-process "git" nil t nil "-c" "user.name=t" "-c" "user.email=t@t.invalid" args))
        (error "git %S: %s" args (buffer-string)))
      (string-trim (buffer-string)))))

(defmacro drgnx-sandbox-vc-test--with (&rest body)
  "BODY with ROOT (a temporary directory, its true name), the folder list in it, and the guard mode on and off
again.  Runs without a hub: no process of the user's, no `~'."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (file-truename (make-temp-file "drgnx-svc" t))))
          (process-environment (append (list (concat "XDG_STATE_HOME=" root "state") "GIT_CONFIG_NOSYSTEM=1"
                                             "GIT_TERMINAL_PROMPT=0")
                                       process-environment))
          (drgnx-sandbox-vc--cache nil) (drgnx-sandbox-vc--added nil)
          (vc-ignore-dir-regexp vc-ignore-dir-regexp)
          (drgnx-sandbox-vc-mode nil))
     (unwind-protect
         (progn (drgnx-sandbox-vc-mode 1) ,@body)
       (drgnx-sandbox-vc-mode -1)
       (delete-directory root t))))

(defun drgnx-sandbox-vc-test--fsmonitor-repo (folder canary)
  "FOLDER: a repository with a tracked file `a' and a `core.fsmonitor' hook that creates CANARY."
  (make-directory folder t)
  (let ((hook (expand-file-name "hook.sh" (file-name-directory (directory-file-name folder)))))
    (write-region (format "#!/bin/sh\ntouch %s\nprintf '\\0'\n" (shell-quote-argument canary)) nil hook nil 'silent)
    (set-file-modes hook #o755)
    (drgnx-sandbox-vc-test--git folder "init" "-q" "-b" "main")
    (write-region "x\n" nil (expand-file-name "a" folder) nil 'silent)
    (drgnx-sandbox-vc-test--git folder "add" "-A")
    (drgnx-sandbox-vc-test--git folder "commit" "-q" "-m" "one")
    (drgnx-sandbox-vc-test--git folder "config" "core.fsmonitor" hook)
    hook))

(ert-deftest drgnx-sandbox-vc/visiting-runs-no-fsmonitor ()
  (drgnx-sandbox-vc-test--with
    (let* ((folder (concat root "tasks/7-1/")) (canary (concat root "canary")))
      (drgnx-sandbox-vc-test--fsmonitor-repo folder canary)
      ;; the fixture works: an unguarded git runs the hook
      (drgnx-sandbox-vc-test--git folder "status")
      (should (file-exists-p canary))
      (delete-file canary)
      (drgnx-sandbox-vc-register folder)
      (let ((file (concat folder "a")) (vc-handled-backends '(Git)) (buf nil))
        (unwind-protect
            (progn
              (ignore-errors (setq buf (find-file-noselect file)))
              (ignore-errors (let ((default-directory folder)) (project-current)))
              (ignore-errors (let ((default-directory folder)) (vc-dir folder 'Git)))
              (ignore-errors (let ((default-directory folder)) (vc-refresh-state)))
              (when (locate-library "magit")
                (ignore-errors (require 'magit) (let ((default-directory folder)) (magit-status-setup-buffer folder))))
              (sleep-for 0.3)
              (should-not (file-exists-p canary)))
          (when (buffer-live-p buf) (kill-buffer buf))
          (when-let* ((b (get-buffer "*vc-dir*"))) (kill-buffer b)))))))

(ert-deftest drgnx-sandbox-vc/vc-ignores-a-registered-folder ()
  (drgnx-sandbox-vc-test--with
    (let ((folder (concat root "tasks/7-1/")))
      (make-directory folder t)
      (should-not (string-match-p vc-ignore-dir-regexp folder))
      (drgnx-sandbox-vc-register folder)
      (drgnx-sandbox-vc-folders)
      (should (string-match-p vc-ignore-dir-regexp (concat folder "sub/")))
      (should-not (string-match-p vc-ignore-dir-regexp (concat root "tasks/7-10/")))
      (drgnx-sandbox-vc-unregister folder)
      (drgnx-sandbox-vc-folders)
      (should-not (string-match-p vc-ignore-dir-regexp folder)))))

(ert-deftest drgnx-sandbox-vc/refuses-git-in-a-folder ()
  (drgnx-sandbox-vc-test--with
    (let ((folder (concat root "tasks/7-1/")) (git (executable-find "git")))
      (make-directory (concat folder "sub") t)
      (drgnx-sandbox-vc-register folder)
      (dolist (dir (list folder (concat folder "sub/")))
        (let ((default-directory dir))
          (should-error (call-process "git" nil nil nil "--version") :type 'drgnx-sandbox-guarded)
          (should-error (call-process git nil nil nil "--version") :type 'drgnx-sandbox-guarded)
          (should-error (process-file "git" nil nil nil "--version") :type 'drgnx-sandbox-guarded)
          (should-error (make-process :name "svc" :command (list "git" "--version")) :type 'drgnx-sandbox-guarded)
          (should-error (process-lines "git" "--version") :type 'drgnx-sandbox-guarded)
          (should-error (with-temp-buffer (call-process-region "x" nil "git" nil nil nil "--version"))
                        :type (quote drgnx-sandbox-guarded))
          (should-error (with-temp-buffer (insert "x") (call-process-region (point-min) (point-max) git nil nil nil "--version"))
                        :type (quote drgnx-sandbox-guarded))))
      (let ((err (condition-case e (let ((default-directory folder)) (call-process "git")) (error e))))
        (should (string-match-p "use the job window" (error-message-string err)))))))

(ert-deftest drgnx-sandbox-vc/allows-git-elsewhere ()
  (drgnx-sandbox-vc-test--with
    (let ((folder (concat root "tasks/7-1/")) (other (concat root "tasks/other/")))
      (make-directory folder t) (make-directory other t)
      (drgnx-sandbox-vc-register folder)
      (let ((default-directory other))
        (should (eql 0 (call-process "git" nil nil nil "--version")))
        (should (eql 0 (process-file "git" nil nil nil "--version")))
        (should (eql 0 (call-process-region "x" nil "git" nil nil nil "--version"))))
      (let ((default-directory folder))        ; not git: not ours to refuse
        (should (eql 0 (call-process "true"))))
      (with-temp-buffer                        ; no folder registered: nothing is refused
        (drgnx-sandbox-vc-unregister folder)
        (let ((default-directory folder)) (should (eql 0 (call-process "git" nil t nil "--version"))))))))

(ert-deftest drgnx-sandbox-vc/boundaries-are-exact ()
  (drgnx-sandbox-vc-test--with
    (dolist (n '("7-1" "7-10" "7-1x"))
      (make-directory (concat root "tasks/" n "/sub") t))
    (drgnx-sandbox-vc-register (concat root "tasks/7-1"))
    (should (drgnx-sandbox-vc-guarded-p (concat root "tasks/7-1")))
    (should (drgnx-sandbox-vc-guarded-p (concat root "tasks/7-1/sub/")))
    (should-not (drgnx-sandbox-vc-guarded-p (concat root "tasks/7-10/")))
    (should-not (drgnx-sandbox-vc-guarded-p (concat root "tasks/7-10/sub")))
    (should-not (drgnx-sandbox-vc-guarded-p (concat root "tasks/7-1x")))
    (should-not (drgnx-sandbox-vc-guarded-p (concat root "tasks")))
    ;; a link into the folder is the folder
    (make-symbolic-link (concat root "tasks/7-1/sub") (concat root "alias"))
    (should (drgnx-sandbox-vc-guarded-p (concat root "alias")))))

(ert-deftest drgnx-sandbox-vc/dash-c-counts ()
  (drgnx-sandbox-vc-test--with
    (let ((folder (concat root "tasks/7-1/")) (other (concat root "other/")))
      (make-directory (concat folder "sub") t) (make-directory other t)
      (drgnx-sandbox-vc-register folder)
      (let ((default-directory other))
        (should-error (call-process "git" nil nil nil "-C" folder "status") :type 'drgnx-sandbox-guarded)
        (should-error (call-process "git" nil nil nil "-c" "a.b=c" "-C" (concat folder "sub") "status")
                      :type 'drgnx-sandbox-guarded)
        (should-error (process-file "git" nil nil nil "--no-pager" "-C" folder "log") :type 'drgnx-sandbox-guarded)
        (should-error (call-process-region "x" nil "git" nil nil nil "-C" folder "status") :type (quote drgnx-sandbox-guarded))
        (should-error (make-process :name "svc" :command (list "git" "-C" folder "status")) :type 'drgnx-sandbox-guarded)
        (should-error (call-process "git" nil nil nil (concat "--git-dir=" folder ".git") "status")
                      :type 'drgnx-sandbox-guarded)
        (should-error (call-process "git" nil nil nil "--work-tree" folder "status") :type 'drgnx-sandbox-guarded)
        ;; a relative -C resolves against default-directory, after the earlier -C
        (should-error (call-process "git" nil nil nil "-C" (concat root "tasks") "-C" "7-1" "status")
                      :type 'drgnx-sandbox-guarded)
        ;; elsewhere is still allowed; after the subcommand, -C is the subcommand's option, not git's
        (should (eql 0 (call-process "git" nil nil nil "-C" other "--version")))
        (should-not (condition-case nil (progn (call-process "git" nil nil nil "version" "-C" folder) nil)
                      (drgnx-sandbox-guarded t)))))))

(ert-deftest drgnx-sandbox-vc/nested-git-found ()
  (drgnx-sandbox-vc-test--with
    (let ((folder (concat root "tasks/7-1/")))
      (make-directory (concat folder ".git/objects") t)
      (make-directory (concat folder "a/b/.git") t)
      (make-directory (concat folder "c") t)
      (write-region "gitdir: /elsewhere\n" nil (concat folder "c/.git") nil 'silent)
      (make-directory (concat folder "d") t)
      (should (equal (sort (mapcar (lambda (p) (file-relative-name p folder)) (drgnx-sandbox-vc-nested-git folder)) #'string<)
                     '("a/b/.git" "c/.git")))
      (delete-directory (concat folder "a") t) (delete-file (concat folder "c/.git"))
      (should-not (drgnx-sandbox-vc-nested-git folder)))))

(ert-deftest drgnx-sandbox-vc/links-not-followed ()
  (drgnx-sandbox-vc-test--with
    (let ((folder (concat root "tasks/7-1/")) (outside (concat root "outside/")))
      (make-directory (concat outside "deep/.git") t)
      (make-directory folder t)
      (make-symbolic-link (directory-file-name outside) (concat folder "lnk"))
      (should-not (drgnx-sandbox-vc-nested-git folder))             ; the link's target is not walked
      (make-symbolic-link (concat outside "deep/.git") (concat folder ".git"))
      (should-not (drgnx-sandbox-vc-nested-git folder))             ; FOLDER/.git itself, link or not, is the top one
      (make-directory (concat folder "s") t)
      (make-symbolic-link (concat outside "deep/.git") (concat folder "s/.git"))
      (should (equal (mapcar (lambda (p) (file-relative-name p folder)) (drgnx-sandbox-vc-nested-git folder))
                     '("s/.git"))))))                                ; a link named .git is one entry, not followed

(ert-deftest drgnx-sandbox-vc/list-survives-a-restart ()
  (drgnx-sandbox-vc-test--with
    (let ((a (concat root "tasks/7-1/")) (b (concat root "tasks/7-2/")) (file (drgnx-sandbox-vc--file)))
      (make-directory a t) (make-directory b t)
      (drgnx-sandbox-vc-register a) (drgnx-sandbox-vc-register b) (drgnx-sandbox-vc-register a)
      (should (equal (drgnx-sandbox-vc-folders) (list a b)))                ; once each
      (should (= #o600 (file-modes file)))
      (setq drgnx-sandbox-vc--cache nil)                                    ; a new process
      (should (equal (drgnx-sandbox-vc-folders) (list a b)))
      (drgnx-sandbox-vc-unregister a)
      (setq drgnx-sandbox-vc--cache nil)
      (should (equal (drgnx-sandbox-vc-folders) (list b)))
      ;; another process (the hub) rewrites the file: this one sees it without a restart
      (should (equal (drgnx-sandbox-vc-folders) (list b)))
      (write-region (prin1-to-string (list a "relative" 5)) nil file nil 'silent)
      (should (equal (drgnx-sandbox-vc-folders) (list a)))                  ; only absolute strings count
      (write-region "(((" nil file nil 'silent)
      (should-not (drgnx-sandbox-vc-folders))                               ; a damaged file guards nothing and breaks nothing
      (delete-file file)
      (should-not (drgnx-sandbox-vc-folders)))))

(ert-deftest drgnx-sandbox-vc/guard-cost ()
  :tags '(:timing)                                      ; a quiet machine: bin/drgnx check runs it alone
  ;; The advice on a non-git program, measured twice: the advice function alone against a no-op (stable), and the
  ;; whole `call-process' of `true' with and without the mode (10,000 each, blocks interleaved; fork noise dominates).
  (drgnx-sandbox-vc-test--with
    (let ((folder (concat root "tasks/7-1/")))
      (make-directory folder t)
      (drgnx-sandbox-vc-register folder)
      (let* ((n 500000)
             (bare (byte-compile `(lambda () (dotimes (_ ,n) (ignore "true" nil nil nil)))))
             (advised (byte-compile `(lambda () (dotimes (_ ,n) (drgnx-sandbox-vc--refuse-git #'ignore "true" nil nil nil)))))
             (t0 (float-time)) (_ (funcall bare)) (t1 (float-time)) (_ (funcall advised)) (t2 (float-time))
             (micro (/ (- (- t2 t1) (- t1 t0)) n)))
        (message "guard-cost: advice function %.3f us per non-git call" (* 1e6 micro))
        (should (< (* 1e6 (max micro 0)) 2.0)))
      (let ((default-directory root) (blocks 10) (per 1000) (with 0.0) (without 0.0)
            (run (byte-compile '(lambda (k) (dotimes (_ k) (call-process "true"))))))
        (dotimes (_ blocks)
          (drgnx-sandbox-vc-mode 1)
          (let ((s (float-time))) (funcall run per) (cl-incf with (- (float-time) s)))
          (drgnx-sandbox-vc-mode -1)
          (let ((s (float-time))) (funcall run per) (cl-incf without (- (float-time) s))))
        (drgnx-sandbox-vc-mode 1)
        (message "guard-cost: call-process of true, %d calls each: %.1f us with, %.1f us without, difference %.2f us"
                 (* blocks per) (/ (* 1e6 with) (* blocks per)) (/ (* 1e6 without) (* blocks per))
                 (/ (* 1e6 (- with without)) (* blocks per)))
        (should (< (/ (* 1e6 (- with without)) (* blocks per)) 100.0))))))   ; fork noise is tens of us: a gross check

(ert-deftest drgnx-sandbox-vc/trusted-binding-allows-the-hubs-own-step ()
  (drgnx-sandbox-vc-test--with
    (let ((folder (concat root "tasks/7-1/")))
      (make-directory folder t)
      (drgnx-sandbox-vc-register folder)
      (let ((default-directory folder))
        (should-error (call-process "git" nil nil nil "--version") :type 'drgnx-sandbox-guarded)
        (let ((drgnx-sandbox-vc-trusted t))
          (should (eql 0 (call-process "git" nil nil nil "--version")))
          (should (eql 0 (with-temp-buffer (call-process-region "x" nil "git" nil nil nil "--version"))))
          (should (eql 0 (process-file "git" nil nil nil "--version"))))
        (should-error (call-process "git" nil nil nil "--version") :type 'drgnx-sandbox-guarded)))))
