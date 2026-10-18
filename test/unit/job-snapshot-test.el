;;; job-snapshot-test.el --- batch tests: a task's snapshot — the copy of .git and its preparation -*- lexical-binding: t -*-
;; Fixture repositories live in the test's temporary directory.  Where its filesystem refuses reflink (tmpfs), the
;; copy-on-write test skips with the reason, and the snapshot path is still covered: `drgnx-job-snapshot--copy-argv'
;; is bound to a plain `cp -a' (the copy is then a full one, the preparation the same).
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-job-snapshot)

(defun drgnx-job-snapshot-test--git (dir &rest args)
  "Git ARGS in DIR (the test's own fixture: a plain synchronous git), its output; an error when it fails."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (unless (eql 0 (apply #'call-process "git" nil t nil "-c" "user.name=t" "-c" "user.email=t@t.invalid" args))
        (error "git %S: %s" args (buffer-string)))
      (string-trim (buffer-string)))))

(defmacro drgnx-job-snapshot-test--with (&rest body)
  "BODY with ROOT (a temporary directory), REPO in it (two commits on main, the branch job/7 at the second) and
FOLDER, the task folder REPO/.claude/worktrees/7-1/ (not made).  The copy-on-write cache is this test's."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (file-truename (make-temp-file "drgnx-snapshot" t))))
          (repo (concat root "repo/")) (folder (concat repo ".claude/worktrees/7-1/"))
          (process-environment (append (list "GIT_CONFIG_NOSYSTEM=1" "GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@t.invalid"
                                             "GIT_COMMITTER_NAME=t" "GIT_COMMITTER_EMAIL=t@t.invalid")
                                       process-environment)))
     (clrhash drgnx-job-snapshot--cow)
     (unwind-protect
         (progn
           (make-directory repo t)
           (drgnx-job-snapshot-test--git repo "init" "-q" "-b" "main")
           (write-region "one\n" nil (concat repo "README") nil 'silent)
           (drgnx-job-snapshot-test--git repo "add" "-A")
           (drgnx-job-snapshot-test--git repo "commit" "-q" "-m" "one")
           (write-region "two\n" nil (concat repo "README") nil 'silent)
           (drgnx-job-snapshot-test--git repo "commit" "-q" "-am" "two")
           (drgnx-job-snapshot-test--git repo "branch" "job/7")
           ,@body)
       (dolist (p (process-list))
         (when (string-prefix-p "drgnx-snapshot" (process-name p)) (set-process-sentinel p #'ignore) (delete-process p)))
       (clrhash drgnx-job-snapshot--cow)
       (delete-directory root t))))

(defmacro drgnx-job-snapshot-test--snapshot-anyway (&rest body)
  "BODY where the snapshot path runs whatever the filesystem: reflink where it works, else a plain full copy."
  (declare (indent 0))
  `(let ((real (symbol-function 'drgnx-job-snapshot--copy-argv)))
     (cl-letf (((symbol-function 'drgnx-job-snapshot--copy-argv)
                (if (drgnx-job-snapshot-cow-p repo) real (lambda (from to) (list "cp" "-a" from to)))))
       (clrhash drgnx-job-snapshot--cow)
       ,@body)))

(defun drgnx-job-snapshot-test--make (repo folder base &optional secs)
  "Make FOLDER's snapshot of REPO at BASE and wait for it: what DONE got (`:timeout' when it never came)."
  (let ((got :timeout) (deadline (+ (float-time) (or secs 30))))
    (drgnx-job-snapshot-make repo folder base (lambda (r) (setq got r)))
    (while (and (eq got :timeout) (< (float-time) deadline)) (accept-process-output nil 0.05))
    got))

(defun drgnx-job-snapshot-test--wait-for (pred &optional secs)
  "PRED's value once it is non-nil, or after SECS (15)."
  (let ((deadline (+ (float-time) (or secs 15))))
    (while (and (not (funcall pred)) (< (float-time) deadline)) (accept-process-output nil 0.05)))
  (funcall pred))

(defun drgnx-job-snapshot-test--checkout (folder branch base)
  "What the sandbox does first: check BRANCH out at BASE in FOLDER."
  (drgnx-job-snapshot-test--git folder "checkout" "-q" "-f" "-B" branch base))

(defun drgnx-job-snapshot-test--texts (dir)
  "Every file under DIR except loose and packed objects, with its contents: ((FILE . TEXT) …)."
  (mapcar (lambda (f) (cons f (with-temp-buffer (insert-file-contents-literally f) (buffer-string))))
          (seq-remove (lambda (f) (string-match-p "/objects/" f)) (directory-files-recursively dir "" nil))))

(defun drgnx-job-snapshot-test--leaks (dir needle)
  "The files under DIR (objects apart) that hold NEEDLE."
  (mapcar #'car (seq-filter (lambda (ft) (string-search needle (cdr ft))) (drgnx-job-snapshot-test--texts dir))))

(defun drgnx-job-snapshot-test--config (folder)
  "FOLDER's repository config, as `git config --list' prints it from the file (lower-case names)."
  (drgnx-job-snapshot-test--git folder "config" "--file" ".git/config" "--list"))

;;;; The copy

(ert-deftest drgnx-job-snapshot/cow-copy-has-the-history ()
  (drgnx-job-snapshot-test--with
    (unless (drgnx-job-snapshot-cow-p repo)
      (ert-skip (format "reflink refused on the filesystem of %s (tmpfs, ext4): run with TMPDIR on btrfs or XFS" root)))
    (should (equal (drgnx-job-snapshot-test--make repo folder "job/7") '(:mode snapshot :read nil)))
    (should (file-directory-p (concat folder ".git")))
    (should (equal (drgnx-job-snapshot-test--git folder "rev-parse" "job/7") (drgnx-job-snapshot-test--git repo "rev-parse" "job/7")))
    (should (equal (drgnx-job-snapshot-test--git folder "log" "--format=%s" "job/7") "two\none"))
    (drgnx-job-snapshot-test--checkout folder "job/7-1" "job/7")
    (should (equal (with-temp-buffer (insert-file-contents (concat folder "README")) (buffer-string)) "two\n"))))

(ert-deftest drgnx-job-snapshot/cow-probe-never-writes-in-dot-git ()
  (drgnx-job-snapshot-test--with
    (let ((before (directory-files-recursively (concat repo ".git") "" t))
          (calls 0))
      (drgnx-job-snapshot-cow-p repo)
      (should (equal (directory-files-recursively (concat repo ".git") "" t) before))
      ;; the probe's files were under .claude/worktrees/, and are gone
      (should (equal (directory-files (concat repo ".claude/worktrees/") nil directory-files-no-dot-files-regexp) nil))
      ;; once per filesystem: the second answer is the cache's
      (cl-letf* ((real (symbol-function 'call-process))
                 ((symbol-function 'call-process) (lambda (&rest args) (cl-incf calls) (apply real args))))
        (drgnx-job-snapshot-cow-p repo))
      (should (= calls 0)))))

(ert-deftest drgnx-job-snapshot/fallback-is-a-shared-clone ()
  (drgnx-job-snapshot-test--with
    (let ((drgnx-job-snapshot-copy-on-write nil)
          (objects (directory-file-name (file-truename (concat repo ".git/objects")))))
      (should (equal (drgnx-job-snapshot-test--make repo folder "job/7") (list :mode 'clone :read (list objects))))
      (should (equal (drgnx-job-snapshot-alternates folder) (list objects)))
      (should (equal (drgnx-job-snapshot-test--git folder "rev-parse" "job/7") (drgnx-job-snapshot-test--git repo "rev-parse" "job/7")))
      ;; no checkout: the sandbox makes it
      (should-not (file-exists-p (concat folder "README")))
      (drgnx-job-snapshot-test--checkout folder "job/7-1" "job/7")
      (should (file-exists-p (concat folder "README"))))))

(ert-deftest drgnx-job-snapshot/linked-worktree-repo-copies-its-common-dir ()
  (drgnx-job-snapshot-test--with
    (let ((wt (concat root "wt/")))
      (drgnx-job-snapshot-test--git repo "worktree" "add" "-q" "-b" "side" wt)
      (should (equal (drgnx-job-snapshot-common-dir wt)
                     (directory-file-name (drgnx-job-snapshot-test--git wt "rev-parse" "--path-format=absolute" "--git-common-dir"))))
      (should (equal (drgnx-job-snapshot-common-dir repo) (directory-file-name (concat repo ".git"))))
      (should-not (drgnx-job-snapshot-common-dir root))
      (let ((folder (concat wt ".claude/worktrees/7-1/")))
        (drgnx-job-snapshot-test--snapshot-anyway
          (should (eq (plist-get (drgnx-job-snapshot-test--make wt folder "job/7") :mode) 'snapshot)))
        (should (file-directory-p (concat folder ".git/objects")))
        (should (equal (drgnx-job-snapshot-test--git folder "rev-parse" "job/7") (drgnx-job-snapshot-test--git repo "rev-parse" "job/7")))))))

;;;; The preparation

(ert-deftest drgnx-job-snapshot/prepare-argvs ()
  (let ((argvs (drgnx-job-snapshot--prepare-argvs
                "/r/.claude/worktrees/7-1/" "job/7"
                '("core.bare" "core.fsmonitor" "core.worktree" "remote.origin.url" "remote.origin.fetch" "remote.a.b.url"
                  "remote.pushdefault" "credential.helper" "credential.https://h.invalid.username" "url.https://t@h/.insteadof"
                  "http.https://h/.extraheader" "github.token" "sendemail.smtppass" "include.path" "gc.auto" "user.name"))))
    (should (equal (car argvs) '("cat-file" "-e" "job/7^{commit}")))
    (should (member '("remote" "remove" "--" "origin") argvs))
    (should (member '("remote" "remove" "--" "a.b") argvs))
    (should (equal (seq-filter (lambda (a) (equal (car a) "remote")) argvs)
                   '(("remote" "remove" "--" "origin") ("remote" "remove" "--" "a.b"))))
    (should (equal (sort (mapcar (lambda (a) (nth 4 a)) (seq-filter (lambda (a) (member "--unset-all" a)) argvs)) #'string<)
                   (sort (list "core.fsmonitor" "core.worktree" "remote.pushdefault" "credential.helper"
                               "credential.https://h.invalid.username" "url.https://t@h/.insteadof" "http.https://h/.extraheader"
                               "github.token" "sendemail.smtppass" "include.path")
                         #'string<)))
    (should (member '("config" "--file" "/r/.claude/worktrees/7-1/.git/config" "gc.auto" "0") argvs))
    (should (equal (car (last argvs)) '("worktree" "prune")))
    ;; every git on the copy runs with the user's hooks and fsmonitor off
    (should (equal (drgnx-job-snapshot--git '("worktree" "prune"))
                   '("git" "-c" "core.hooksPath=/dev/null" "-c" "core.fsmonitor=false" "worktree" "prune")))))

(ert-deftest drgnx-job-snapshot/prepared-copy-has-no-remotes-or-credentials ()
  (drgnx-job-snapshot-test--with
    (let ((secret "tok-SECRET-41a7"))
      (drgnx-job-snapshot-test--git repo "remote" "add" "origin" (format "https://u:%s@example.invalid/r.git" secret))
      (drgnx-job-snapshot-test--git repo "update-ref" "refs/remotes/origin/main" "main")
      (drgnx-job-snapshot-test--git repo "config" "credential.helper" "store")
      (drgnx-job-snapshot-test--git repo "config" "credential.https://example.invalid.username" secret)
      (drgnx-job-snapshot-test--git repo "config" (format "url.https://%s@x.invalid/.insteadOf" secret) "https://x.invalid/")
      (drgnx-job-snapshot-test--git repo "config" "http.https://example.invalid/.extraheader" (concat "AUTHORIZATION: basic " secret))
      (write-region (format "abc\t\tbranch 'main' of https://u:%s@example.invalid/r\n" secret) nil
                    (concat repo ".git/FETCH_HEAD") nil 'silent)
      (dolist (cow '(t nil))
        (let ((drgnx-job-snapshot-copy-on-write cow))
          (drgnx-job-snapshot-test--snapshot-anyway
            (should (eq (plist-get (drgnx-job-snapshot-test--make repo folder "job/7") :mode) (if cow 'snapshot 'clone))))
          (should-not (drgnx-job-snapshot-test--leaks (concat folder ".git") secret))
          (should (equal (drgnx-job-snapshot-test--git folder "remote") ""))
          (should-not (string-match-p "^\\(remote\\|credential\\|url\\)\\.\\|extraheader"
                                      (drgnx-job-snapshot-test--config folder)))
          (should-not (file-exists-p (concat folder ".git/refs/remotes/origin/main")))
          (delete-directory folder t))))))

(ert-deftest drgnx-job-snapshot/prepared-copy-has-gc-off ()
  (drgnx-job-snapshot-test--with
    (dolist (cow '(t nil))
      (let ((drgnx-job-snapshot-copy-on-write cow))
        (drgnx-job-snapshot-test--snapshot-anyway (drgnx-job-snapshot-test--make repo folder "job/7"))
        (should (equal (drgnx-job-snapshot-test--git folder "config" "--file" ".git/config" "gc.auto") "0"))
        (delete-directory folder t)))))

(ert-deftest drgnx-job-snapshot/prepare-runs-none-of-the-user-s-programs ()
  ;; a reference-transaction hook (run by `remote remove') and core.fsmonitor in the user's repo touch a canary when
  ;; run: the preparation runs neither, and the copy keeps no fsmonitor and no core.worktree
  (drgnx-job-snapshot-test--with
    (let ((canary (concat root "canary")) (hook (concat repo ".git/hooks/reference-transaction")))
      (write-region (format "#!/bin/sh\ntouch %s\n" canary) nil hook nil 'silent)
      (set-file-modes hook #o755)
      (drgnx-job-snapshot-test--git repo "config" "core.fsmonitor" hook)
      (drgnx-job-snapshot-test--git repo "config" "core.worktree" repo)
      (drgnx-job-snapshot-test--git repo "remote" "add" "origin" "https://example.invalid/r.git")
      (drgnx-job-snapshot-test--git repo "update-ref" "refs/remotes/origin/main" "main")
      (when (file-exists-p canary) (delete-file canary))
      (drgnx-job-snapshot-test--snapshot-anyway
        (should (eq (plist-get (drgnx-job-snapshot-test--make repo folder "job/7") :mode) 'snapshot)))
      (should-not (file-exists-p canary))
      (should-not (string-match-p "core\\.\\(fsmonitor\\|worktree\\)" (drgnx-job-snapshot-test--config folder))))))

(ert-deftest drgnx-job-snapshot/user-worktrees-pruned ()
  (drgnx-job-snapshot-test--with
    (drgnx-job-snapshot-test--git repo "worktree" "add" "-q" "-b" "side" (concat root "wt"))   ; still on disk
    (dolist (cow '(t nil))
      (let ((drgnx-job-snapshot-copy-on-write cow))
        (drgnx-job-snapshot-test--snapshot-anyway (drgnx-job-snapshot-test--make repo folder "job/7"))
        (should-not (file-exists-p (concat folder ".git/worktrees")))
        (should (= 1 (length (seq-filter (lambda (l) (string-prefix-p "worktree " l))
                                         (split-string (drgnx-job-snapshot-test--git folder "worktree" "list" "--porcelain") "\n")))))
        (delete-directory folder t)))))

(ert-deftest drgnx-job-snapshot/untracked-and-uncommitted-files-not-copied ()
  (drgnx-job-snapshot-test--with
    ;; the user's main checkout: a stash, a staged file, a dirty file, an untracked .env
    (write-region "stashed-SECRET\n" nil (concat repo "README") nil 'silent)
    (drgnx-job-snapshot-test--git repo "stash" "-q")
    (write-region "staged-SECRET\n" nil (concat repo "staged.txt") nil 'silent)
    (drgnx-job-snapshot-test--git repo "add" "staged.txt")
    (write-region "dirty-SECRET\n" nil (concat repo "README") nil 'silent)
    (write-region "KEY=env-SECRET\n" nil (concat repo ".env") nil 'silent)
    (dolist (cow '(t nil))
      (let ((drgnx-job-snapshot-copy-on-write cow))
        (drgnx-job-snapshot-test--snapshot-anyway (drgnx-job-snapshot-test--make repo folder "job/7"))
        (should-not (file-exists-p (concat folder ".git/index")))            ; the user's staging area
        (should-not (file-exists-p (concat folder ".git/refs/stash")))
        (drgnx-job-snapshot-test--checkout folder "job/7-1" "job/7")
        (should (equal (directory-files folder nil directory-files-no-dot-files-regexp) '(".git" "README")))
        (should (equal (with-temp-buffer (insert-file-contents (concat folder "README")) (buffer-string)) "two\n"))
        (should (equal (drgnx-job-snapshot-test--git folder "stash" "list") ""))
        (dolist (s '("stashed-SECRET" "staged-SECRET" "dirty-SECRET" "env-SECRET"))
          (should-not (drgnx-job-snapshot-test--leaks folder s)))
        (delete-directory folder t)))))

(ert-deftest drgnx-job-snapshot/stale-lock-files-removed ()
  (drgnx-job-snapshot-test--with
    ;; a git of the user's in the middle of its work: its locks are copied with the rest
    (let ((locks '("index.lock" "HEAD.lock" "config.lock" "packed-refs.lock" "refs/heads/main.lock")))
      (dolist (l locks) (write-region "" nil (concat repo ".git/" l) nil 'silent))
      (drgnx-job-snapshot-test--snapshot-anyway
        (should (eq (plist-get (drgnx-job-snapshot-test--make repo folder "job/7") :mode) 'snapshot)))
      (should-not (directory-files-recursively (concat folder ".git") "\\.lock\\'"))
      (dolist (l locks) (should (file-exists-p (concat repo ".git/" l)))))))       ; the user's are not touched

(ert-deftest drgnx-job-snapshot/missing-base-retries-once ()
  (drgnx-job-snapshot-test--with
    (drgnx-job-snapshot-test--snapshot-anyway
      (let* ((copies 0) (appears t) (argv (symbol-function 'drgnx-job-snapshot--copy-argv)))
        ;; the base appears only after the first copy: a git of the user's was writing it
        (cl-letf (((symbol-function 'drgnx-job-snapshot--copy-argv)
                   (lambda (from to)
                     (when (and (= (cl-incf copies) 2) appears) (drgnx-job-snapshot-test--git repo "branch" "job/9"))
                     (funcall argv from to))))
          (should (eq (plist-get (drgnx-job-snapshot-test--make repo folder "job/9") :mode) 'snapshot))
          (should (= copies 2))
          (delete-directory folder t)
          ;; never there: an error after the second try, and the folder gone
          (setq copies 0 appears nil)
          (let ((r (drgnx-job-snapshot-test--make repo folder "job/nope")))
            (should (string-match-p "job/nope" (plist-get r :error)))
            (should (= copies 2))
            (should-not (file-exists-p folder))))))))

(ert-deftest drgnx-job-snapshot/refusals ()
  (drgnx-job-snapshot-test--with
    (should (plist-get (drgnx-job-snapshot-test--make repo folder "-oops") :error))
    (should (plist-get (drgnx-job-snapshot-test--make root folder "job/7") :error))            ; not a repository
    (make-directory folder t)
    (write-region "x" nil (concat folder "keep") nil 'silent)
    (should (string-match-p "not empty" (plist-get (drgnx-job-snapshot-test--make repo folder "job/7") :error)))
    (should (file-exists-p (concat folder "keep")))))

(ert-deftest drgnx-job-snapshot/never-blocks ()
  (drgnx-job-snapshot-test--with
    (let ((got nil))
      (cl-letf (((symbol-function 'call-process) (lambda (&rest _) (error "call-process in the hub path")))
                ((symbol-function 'process-file) (lambda (&rest _) (error "process-file in the hub path")))
                ((symbol-function 'y-or-n-p) (lambda (&rest _) (error "a prompt")))
                ((symbol-function 'read-from-minibuffer) (lambda (&rest _) (error "a prompt"))))
        ;; the probe too (the cache is empty): a process of its own
        (drgnx-job-snapshot-make repo folder "job/7" (lambda (r) (setq got r)))
        (should-not got)
        (let ((deadline (+ (float-time) 30)))
          (while (and (not got) (< (float-time) deadline)) (accept-process-output nil 0.05))))
      (should (memq (plist-get got :mode) '(snapshot clone))))))

;;;; Bounded: disk use and removal

(ert-deftest drgnx-job-snapshot/disk-use-reported-and-remove-deletes-the-copy ()
  (drgnx-job-snapshot-test--with
    (let ((outside (concat root "outside/")) (usage nil) (removed nil))
      (make-directory outside)
      (write-region "keep" nil (concat outside "canary") nil 'silent)
      (drgnx-job-snapshot-test--snapshot-anyway (drgnx-job-snapshot-test--make repo folder "job/7"))
      (make-symbolic-link outside (concat folder "link"))         ; what an agent could leave
      (drgnx-job-snapshot-disk-usage folder (lambda (r) (setq usage r)))
      (should (drgnx-job-snapshot-test--wait-for (lambda () usage)))
      (should (natnump (plist-get usage :bytes)))
      (should (> (plist-get usage :bytes) 0))
      (drgnx-job-snapshot-remove folder (lambda (r) (setq removed r)))
      (should (eq (drgnx-job-snapshot-test--wait-for (lambda () removed)) t))
      (should-not (file-exists-p folder))
      (should (file-exists-p (concat outside "canary")))
      (should (file-directory-p (concat repo ".git/objects")))
      ;; only task folders
      (let ((r nil))
        (drgnx-job-snapshot-remove repo (lambda (x) (setq r x)))
        (should (drgnx-job-snapshot-test--wait-for (lambda () r)))
        (should (plist-get r :error))
        (should (file-directory-p repo))))))

;;; job-snapshot-test.el ends here
