;;; job-worktree-test.el --- batch tests: worktree mode — a task's linked worktree and its minimum binds -*- lexical-binding: t -*-
;; Fixture repositories live in the test's temporary directory.  These tests assert data: what the binds are, and in
;; which order.  That each pinned path really gives EROFS or EBUSY under bubblewrap is proved by the escape tests
;; (`drgnx-sandbox-escape/k4-worktree').  The git these tests run in the task folder plays the agent's part.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-job-worktree)

(defun drgnx-job-worktree-test--git (dir &rest args)
  "Git ARGS in DIR (the test's own fixture: a plain synchronous git), its output; an error when it fails."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (unless (eql 0 (apply #'call-process "git" nil t nil args))
        (error "git %S: %s" args (buffer-string)))
      (string-trim (buffer-string)))))

(defun drgnx-job-worktree-test--repo (repo &optional ref-format)
  "Make REPO: two commits on main, the branch job/7 at the second.  REF-FORMAT: files (default) or reftable."
  (make-directory repo t)
  (drgnx-job-worktree-test--git repo "init" "-q" "-b" "main" (format "--ref-format=%s" (or ref-format "files")))
  (write-region "one\n" nil (concat repo "README") nil 'silent)
  (drgnx-job-worktree-test--git repo "add" "-A")
  (drgnx-job-worktree-test--git repo "commit" "-q" "-m" "one")
  (write-region "two\n" nil (concat repo "README") nil 'silent)
  (drgnx-job-worktree-test--git repo "commit" "-q" "-am" "two")
  (drgnx-job-worktree-test--git repo "branch" "job/7"))

(defmacro drgnx-job-worktree-test--with (&rest body)
  "BODY with ROOT (a temporary directory, its true name), REPO in it (`drgnx-job-worktree-test--repo'), GIT (REPO's
.git, no trailing slash) and FOLDER, the task folder REPO/.claude/worktrees/7-1 (not made; no trailing slash)."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (file-truename (make-temp-file "drgnx-worktree" t))))
          (repo (concat root "repo/")) (git (concat repo ".git")) (folder (concat repo ".claude/worktrees/7-1"))
          (process-environment (append (list "GIT_CONFIG_NOSYSTEM=1" "GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@t.invalid"
                                             "GIT_COMMITTER_NAME=t" "GIT_COMMITTER_EMAIL=t@t.invalid")
                                       process-environment)))
     (unwind-protect
         (progn
           (drgnx-job-worktree-test--repo repo)
           ,@body)
       (dolist (p (process-list))
         (when (string-prefix-p "drgnx-worktree" (process-name p)) (set-process-sentinel p #'ignore) (delete-process p)))
       (delete-directory root t))))

(defun drgnx-job-worktree-test--add (repo folder id n base &optional secs)
  "Add FOLDER, task N of job ID at BASE, and wait for it: what DONE got (`:timeout' when it never came)."
  (let ((got :timeout) (deadline (+ (float-time) (or secs 30))))
    (drgnx-job-worktree-add repo folder id n base (lambda (r) (setq got r)))
    (while (and (eq got :timeout) (< (float-time) deadline)) (accept-process-output nil 0.05))
    got))

(defun drgnx-job-worktree-test--mode-of (path binds)
  "How PATH is mounted under BINDS (applied in order, a later one over an earlier): the mode of the last bind whose
source is PATH or one of its parents, or nil when none is."
  (let (mode)
    (pcase-dolist (`(,m ,outside ,_inside) binds)
      (when (or (string= path outside) (string-prefix-p (file-name-as-directory outside) path))
        (setq mode m)))
    mode))

(defun drgnx-job-worktree-test--expected (git folder name)
  "The binds of spec §4b for task 7-1, in order, every one writable but the pins."
  (let ((wt (concat git "/worktrees/" name)))
    (mapcar (lambda (b) (list (car b) (cadr b) (cadr b)))
            `((ro ,git) (rw ,(concat git "/objects"))
              (rw ,(concat git "/refs/heads/job/7-1")) (rw ,(concat git "/logs/refs/heads/job/7-1"))
              (rw ,wt) (ro ,(concat wt "/commondir")) (ro ,(concat wt "/gitdir")) (ro ,(concat wt "/config.worktree"))
              (rw ,folder) (ro ,(concat folder "/.git"))))))

;;;; The branch, the worktree

(ert-deftest drgnx-job-worktree/config-worktree-made-empty ()
  (drgnx-job-worktree-test--with
    (should (equal (drgnx-job-worktree-branch "7" 1) "job/7-1/work"))
    (should (equal (drgnx-job-worktree-test--add repo folder "7" 1 "job/7") '(:name "7-1")))
    (should (equal (drgnx-job-worktree-name repo folder) "7-1"))
    ;; the branch is in the main repository, at the base, checked out in the folder
    (should (equal (drgnx-job-worktree-test--git repo "rev-parse" "job/7-1/work")
                   (drgnx-job-worktree-test--git repo "rev-parse" "job/7")))
    (should (equal (drgnx-job-worktree-test--git folder "symbolic-ref" "HEAD") "refs/heads/job/7-1/work"))
    ;; the pins' sources exist: config.worktree empty, the branch's reflog directory there
    (let ((cw (concat git "/worktrees/7-1/config.worktree")))
      (should (file-regular-p cw))
      (should (eql 0 (file-attribute-size (file-attributes cw)))))
    (should (file-directory-p (concat git "/logs/refs/heads/job/7-1")))
    (should (file-directory-p (concat git "/refs/heads/job/7-1")))
    ;; `git pack-refs' (in `git gc') removes the ref directory: prepare, before each start, makes it again
    (drgnx-job-worktree-test--git repo "pack-refs" "--all")
    (should-not (file-exists-p (concat git "/refs/heads/job")))
    (drgnx-job-worktree-prepare repo "7" 1)
    (should (file-directory-p (concat git "/refs/heads/job/7-1")))
    (should (equal (drgnx-job-worktree-test--git folder "rev-parse" "HEAD") (drgnx-job-worktree-test--git repo "rev-parse" "job/7")))
    ;; a folder that is there already is refused, and nothing is changed
    (should (equal (car (drgnx-job-worktree-test--add repo folder "7" 1 "job/7")) :error))
    ;; a bad base or id never reaches git
    (should (equal (car (drgnx-job-worktree-test--add repo (concat folder "-x") "7" 2 "--orphan")) :error))
    (should (equal (car (drgnx-job-worktree-test--add repo (concat folder "-y") "../7" 2 "job/7")) :error))
    (should-not (file-exists-p (concat folder "-x")))
    (should-not (file-exists-p (concat folder "-y")))))

;;;; The binds

(ert-deftest drgnx-job-worktree/binds-in-order ()
  (drgnx-job-worktree-test--with
    (should (equal (drgnx-job-worktree-test--add repo folder "7" 1 "job/7") '(:name "7-1")))
    (let ((binds (drgnx-job-worktree-binds repo folder "7-1" "7" 1)))
      (should (equal binds (drgnx-job-worktree-test--expected git folder "7-1")))
      ;; every pin comes after the writable directory it sits in, so it is mounted over it
      (cl-loop for (mode path) in binds for i from 0
               when (eq mode 'ro)
               do (cl-loop for (m p) in binds for j from 0
                           when (and (eq m 'rw) (string-prefix-p (file-name-as-directory p) path))
                           do (should (< j i))))
      ;; each source is there (bubblewrap cannot bind what is missing), and is its own true name
      (dolist (b binds)
        (should (file-exists-p (nth 1 b)))
        (should (equal (nth 1 b) (directory-file-name (file-truename (nth 1 b)))))))
    ;; a link in the repository's path resolves before binding
    (let ((link (concat root "link")))
      (make-symbolic-link (directory-file-name repo) link)
      (should (equal (drgnx-job-worktree-binds (concat link "/") (concat link "/.claude/worktrees/7-1") "7-1" "7" 1)
                     (drgnx-job-worktree-test--expected git folder "7-1"))))))

(ert-deftest drgnx-job-worktree/only-its-own-ref-dir-writable ()
  (drgnx-job-worktree-test--with
    (should (equal (drgnx-job-worktree-test--add repo folder "7" 1 "job/7") '(:name "7-1")))
    (should (equal (drgnx-job-worktree-test--add repo (concat repo ".claude/worktrees/7-10") "7" 10 "job/7") '(:name "7-10")))
    (let ((binds (drgnx-job-worktree-binds repo folder "7-1" "7" 1)))
      (dolist (p '("config" "packed-refs" "HEAD" "index" "hooks/pre-commit" "info/exclude" "refs" "refs/heads"
                   "refs/heads/main" "refs/heads/job" "refs/heads/job/7" "refs/heads/job/7-10/work" "refs/tags/v1"
                   "logs/HEAD" "logs/refs/heads/main" "worktrees/7-10/HEAD" "worktrees/7-1/commondir"
                   "worktrees/7-1/gitdir" "worktrees/7-1/config.worktree"))
        (should (equal (cons p (drgnx-job-worktree-test--mode-of (concat git "/" p) binds)) (cons p 'ro))))
      (dolist (p '("objects/ab/cdef" "objects/pack/x.pack" "refs/heads/job/7-1/work" "logs/refs/heads/job/7-1/work"
                   "worktrees/7-1/HEAD" "worktrees/7-1/index" "worktrees/7-1/logs/HEAD"))
        (should (equal (cons p (drgnx-job-worktree-test--mode-of (concat git "/" p) binds)) (cons p 'rw))))
      (should (eq (drgnx-job-worktree-test--mode-of (concat folder "/src/a.el") binds) 'rw))
      (should (eq (drgnx-job-worktree-test--mode-of (concat folder "/.git") binds) 'ro))
      ;; nothing else of the repository: the main checkout's files (untracked ones too) are not mounted at all
      (should-not (drgnx-job-worktree-test--mode-of (concat repo "README") binds))
      (should-not (drgnx-job-worktree-test--mode-of (concat repo ".env") binds))
      (should-not (drgnx-job-worktree-test--mode-of (concat repo ".claude/worktrees/7-10/README") binds)))
    ;; an id, a number or a worktree name that would widen the ref directory or the worktree's is refused
    (dolist (args '(("../7" 1 "7-1") ("" 1 "7-1") ("7/x" 1 "7-1") ("-7" 1 "7-1") ("7" 0 "7-1") ("7" "1" "7-1")
                    ("7" 1 "..") ("7" 1 "a/b") ("7" 1 "")))
      (should-error (drgnx-job-worktree-binds repo folder (nth 2 args) (nth 0 args) (nth 1 args)))
      (when (equal (nth 2 args) "7-1")                              ; a bad id or number, not a bad name
        (should-error (drgnx-job-worktree-branch (nth 0 args) (nth 1 args)))))))

(ert-deftest drgnx-job-worktree/reviewer-binds-are-read-only ()
  (drgnx-job-worktree-test--with
    (should (equal (drgnx-job-worktree-test--add repo folder "7" 1 "job/7") '(:name "7-1")))
    (let ((writer (drgnx-job-worktree-binds repo folder "7-1" "7" 1))
          (reviewer (drgnx-job-worktree-binds repo folder "7-1" "7" 1 t)))
      (should (equal (mapcar #'cdr reviewer) (mapcar #'cdr writer)))
      (should (cl-every (lambda (b) (eq (car b) 'ro)) reviewer))
      (dolist (p '("objects/ab/cdef" "refs/heads/job/7-1/work" "worktrees/7-1/index"))
        (should (eq (drgnx-job-worktree-test--mode-of (concat git "/" p) reviewer) 'ro)))
      (should (eq (drgnx-job-worktree-test--mode-of (concat folder "/README") reviewer) 'ro)))))

;;;; Refused: reftable

(ert-deftest drgnx-job-worktree/reftable-refused ()
  (let ((version (with-temp-buffer (call-process "git" nil t nil "--version") (buffer-string))))
    (unless (and (string-match "\\([0-9]+\\)\\.\\([0-9]+\\)" version)
                 (version<= "2.45" (concat (match-string 1 version) "." (match-string 2 version))))
      (ert-skip (format "git %s has no reftable (2.45 or later)" (string-trim version)))))
  (drgnx-job-worktree-test--with
    (should-not (drgnx-job-worktree-refusal repo))
    (let ((table (concat root "table/")))
      (drgnx-job-worktree-test--repo table "reftable")
      (should (equal (drgnx-job-worktree-refusal table)
                     "this repository keeps its refs in reftable: worktree mode cannot limit the agent to its own branch; use snapshot mode"))
      ;; from the config alone too (a git that cannot say the ref format)
      (cl-letf (((symbol-function 'drgnx-job-worktree--show-ref-format) #'ignore))
        (should (drgnx-job-worktree-refusal table))
        (should-not (drgnx-job-worktree-refusal repo)))
      ;; and the worktree is never made
      (let ((got (drgnx-job-worktree-test--add table (concat table ".claude/worktrees/7-1") "7" 1 "job/7")))
        (should (equal got (list :error (drgnx-job-worktree-refusal table)))))
      (should-not (file-exists-p (concat table ".claude/worktrees/7-1")))
      (should-not (string-match-p "job/7-1/work" (drgnx-job-worktree-test--git table "branch" "--list"))))))

;;;; The check after each turn

(ert-deftest drgnx-job-worktree/check-catches-a-rewound-branch ()
  (drgnx-job-worktree-test--with
    (should (equal (drgnx-job-worktree-test--add repo folder "7" 1 "job/7") '(:name "7-1")))
    (should (drgnx-job-worktree-check repo "7" 1 "job/7"))               ; at the base
    (write-region "three\n" nil (concat folder "/README") nil 'silent)
    (drgnx-job-worktree-test--git folder "commit" "-q" "-am" "three")
    (should (drgnx-job-worktree-check repo "7" 1 "job/7"))               ; a commit on it
    (let ((ref (concat git "/refs/heads/job/7-1/work"))
          (tip (drgnx-job-worktree-test--git repo "rev-parse" "job/7-1/work")))
      (should (equal (drgnx-job-worktree-tip repo "7" 1) tip))
      ;; rewound below the base
      (drgnx-job-worktree-test--git folder "reset" "-q" "--hard" "main~1")
      (should-not (drgnx-job-worktree-check repo "7" 1 "job/7"))
      ;; a branch of its own history
      (drgnx-job-worktree-test--git folder "checkout" "-q" "--orphan" "x")
      (drgnx-job-worktree-test--git folder "commit" "-q" "-m" "alone")
      (drgnx-job-worktree-test--git folder "update-ref" "refs/heads/job/7-1/work" "HEAD")
      (should-not (drgnx-job-worktree-check repo "7" 1 "job/7"))
      ;; the ref file is the agent's: a symbolic ref, a link or junk is no commit
      (write-region "ref: refs/heads/main\n" nil ref nil 'silent)
      (should-not (drgnx-job-worktree-tip repo "7" 1))
      (should-not (drgnx-job-worktree-check repo "7" 1 "job/7"))
      (delete-file ref)
      (make-symbolic-link (concat git "/refs/heads/main") ref)
      (should-not (drgnx-job-worktree-check repo "7" 1 "job/7"))
      (delete-file ref)
      (write-region (concat (make-string 40 ?z) "\n") nil ref nil 'silent)
      (should-not (drgnx-job-worktree-check repo "7" 1 "job/7"))
      ;; back at the commit: descends again; packed (the user's gc) it is still found
      (write-region (concat tip "\n") nil ref nil 'silent)
      (should (drgnx-job-worktree-check repo "7" 1 "job/7"))
      (drgnx-job-worktree-test--git repo "pack-refs" "--all")
      (should-not (file-exists-p ref))
      (should (equal (drgnx-job-worktree-tip repo "7" 1) tip))
      (should (drgnx-job-worktree-check repo "7" 1 "job/7")))
    ;; no branch at all
    (should-not (drgnx-job-worktree-check repo "7" 2 "job/7"))))

;;; job-worktree-test.el ends here
