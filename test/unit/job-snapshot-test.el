;;; job-snapshot-test.el --- batch tests: a task's snapshot — the job's clean store and the task's copy of it -*- lexical-binding: t -*-
;; Fixture repositories live in the test's temporary directory.  Where its filesystem refuses reflink (tmpfs), the
;; copy-on-write test skips with the reason, and the snapshot path is still covered: `drgnx-job-snapshot--copy-argv'
;; is bound to a plain `cp -a' (the copy is then a full one; what it holds is the same).
;; The git these tests run in a task folder is the agent's or the sandbox's part, played by the test.
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

(defun drgnx-job-snapshot-test--repo (repo &optional ref-format)
  "Make REPO: two commits on main, the branch job/7 at the second.  REF-FORMAT: files (default) or reftable."
  (make-directory repo t)
  (drgnx-job-snapshot-test--git repo "init" "-q" "-b" "main" (format "--ref-format=%s" (or ref-format "files")))
  (write-region "one\n" nil (concat repo "README") nil 'silent)
  (drgnx-job-snapshot-test--git repo "add" "-A")
  (drgnx-job-snapshot-test--git repo "commit" "-q" "-m" "one")
  (write-region "two\n" nil (concat repo "README") nil 'silent)
  (drgnx-job-snapshot-test--git repo "commit" "-q" "-am" "two")
  (drgnx-job-snapshot-test--git repo "branch" "job/7"))

(defmacro drgnx-job-snapshot-test--with (&rest body)
  "BODY with ROOT (a temporary directory), REPO in it (`drgnx-job-snapshot-test--repo') and FOLDER, the task folder
REPO/.claude/worktrees/7-1/ (not made).  The copy-on-write cache is this test's."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (file-truename (make-temp-file "drgnx-snapshot" t))))
          (repo (concat root "repo/")) (folder (concat repo ".claude/worktrees/7-1/"))
          (process-environment (append (list "GIT_CONFIG_NOSYSTEM=1" "GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@t.invalid"
                                             "GIT_COMMITTER_NAME=t" "GIT_COMMITTER_EMAIL=t@t.invalid")
                                       process-environment)))
     (clrhash drgnx-job-snapshot--cow)
     (unwind-protect
         (progn
           (drgnx-job-snapshot-test--repo repo)
           ,@body)
       (dolist (p (process-list))
         (when (string-prefix-p "drgnx-snapshot" (process-name p)) (set-process-sentinel p #'ignore) (delete-process p)))
       (clrhash drgnx-job-snapshot--cow)
       (when (boundp 'drgnx-job-snapshot--busy) (clrhash drgnx-job-snapshot--busy))
       (delete-directory root t))))

(defmacro drgnx-job-snapshot-test--snapshot-anyway (&rest body)
  "BODY where the snapshot path runs whatever the filesystem: reflink where it works, else a plain full copy."
  (declare (indent 0))
  `(let ((real (symbol-function 'drgnx-job-snapshot--copy-argv)))
     (cl-letf (((symbol-function 'drgnx-job-snapshot--copy-argv)
                (if (drgnx-job-snapshot-cow-p repo) real (lambda (from to) (list "cp" "-a" from to)))))
       (clrhash drgnx-job-snapshot--cow)
       ,@body)))

(defmacro drgnx-job-snapshot-test--both-modes (&rest body)
  "BODY twice: as a snapshot (`drgnx-job-snapshot-test--snapshot-anyway'), then as a shared clone; MODE is bound to
the mode expected, and FOLDER is removed after each."
  (declare (indent 0))
  `(dolist (mode '(snapshot clone))
     (let ((drgnx-job-snapshot-copy-on-write (eq mode 'snapshot)))
       (drgnx-job-snapshot-test--snapshot-anyway ,@body)
       (delete-directory folder t))))

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

(defun drgnx-job-snapshot-test--seen (folder)
  "All an agent in FOLDER can read of its repository: every file's bytes, and every object's contents (its own and
its alternates', `cat-file --batch-all-objects --batch')."
  (concat (mapconcat (lambda (f) (with-temp-buffer (insert-file-contents-literally f) (buffer-string)))
                     (directory-files-recursively folder "" nil) "\n")
          (drgnx-job-snapshot-test--git folder "cat-file" "--batch-all-objects" "--batch")))

(defun drgnx-job-snapshot-test--config (folder)
  "FOLDER's repository config, as `git config --list' prints it from the file (lower-case names)."
  (drgnx-job-snapshot-test--git folder "config" "--file" ".git/config" "--list"))

(defun drgnx-job-snapshot-test--store (repo)
  (concat repo ".claude/worktrees/job~7.base.git/"))

;;;; The copy

(ert-deftest drgnx-job-snapshot/cow-copy-has-the-history ()
  (drgnx-job-snapshot-test--with
    (unless (drgnx-job-snapshot-cow-p repo)
      (ert-skip (format "reflink refused on the filesystem of %s (tmpfs, ext4): run with TMPDIR on btrfs or XFS" root)))
    (should (equal (drgnx-job-snapshot-test--make repo folder "job/7")
                   (list :mode 'snapshot :read nil :start (drgnx-job-snapshot-test--git repo "rev-parse" "job/7"))))
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
    (let* ((drgnx-job-snapshot-copy-on-write nil)
           (objects (directory-file-name (concat (drgnx-job-snapshot-test--store repo) "objects"))))
      ;; it borrows from the job's clean store, never from the user's .git
      ;; :start: the commit the task starts from, read before any agent had the folder
      (should (equal (drgnx-job-snapshot-test--make repo folder "job/7")
                     (list :mode 'clone :read (list objects) :start (drgnx-job-snapshot-test--git repo "rev-parse" "job/7"))))
      (should (equal (drgnx-job-snapshot-read-dirs repo "job/7") (list objects)))
      (should (equal (drgnx-job-snapshot--alternates folder) (list objects)))
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
      (drgnx-job-snapshot-test--git repo "config" "core.hooksPath" ".githooks")       ; the common dir's config is read
      (let ((folder (concat wt ".claude/worktrees/7-1/")))
        (drgnx-job-snapshot-test--snapshot-anyway
          (should (eq (plist-get (drgnx-job-snapshot-test--make wt folder "job/7") :mode) 'snapshot)))
        (should (equal (drgnx-job-snapshot-test--git folder "rev-parse" "job/7") (drgnx-job-snapshot-test--git repo "rev-parse" "job/7")))
        (should (string-match-p "^core\\.hookspath=\\.githooks$" (drgnx-job-snapshot-test--config folder)))))))

;;;; What the agent can see: BASE's history, nothing else

(ert-deftest drgnx-job-snapshot/unreachable-objects-and-other-branches-not-copied ()
  ;; K4b through the object store: a .env staged then unstaged, a dropped stash, a commit amended away, another
  ;; branch — none is in what the task folder can read, in either mode, with either ref backend; and no reflog
  (dolist (format '("files" "reftable"))
    (drgnx-job-snapshot-test--with
      (delete-directory repo t)
      (drgnx-job-snapshot-test--repo repo format)
      (write-region "KEY=env-SECRET\n" nil (concat repo ".env") nil 'silent)
      (drgnx-job-snapshot-test--git repo "add" ".env")
      (drgnx-job-snapshot-test--git repo "rm" "-q" "--cached" ".env")
      (write-region "stashed-SECRET\n" nil (concat repo "README") nil 'silent)
      (drgnx-job-snapshot-test--git repo "stash" "-q")
      (drgnx-job-snapshot-test--git repo "stash" "drop" "-q")
      (write-region "amended-SECRET\n" nil (concat repo "notes") nil 'silent)
      (drgnx-job-snapshot-test--git repo "add" "notes")
      (drgnx-job-snapshot-test--git repo "commit" "-q" "-m" "draft")
      (let ((amended (drgnx-job-snapshot-test--git repo "rev-parse" "HEAD")))
        (write-region "clean\n" nil (concat repo "notes") nil 'silent)
        (drgnx-job-snapshot-test--git repo "commit" "-q" "--amend" "-am" "notes")
        (drgnx-job-snapshot-test--git repo "branch" "-f" "job/7" "HEAD")
        (drgnx-job-snapshot-test--git repo "checkout" "-q" "-b" "wip")
        (write-region "wip-SECRET\n" nil (concat repo "wip") nil 'silent)
        (drgnx-job-snapshot-test--git repo "add" "wip")
        (drgnx-job-snapshot-test--git repo "commit" "-q" "-m" "wip")
        (drgnx-job-snapshot-test--git repo "checkout" "-q" "main")
        ;; the user's store does hold them: the fixture is real
        (should (string-search "amended-SECRET" (drgnx-job-snapshot-test--git repo "cat-file" "--batch-all-objects" "--batch")))
        (drgnx-job-snapshot-test--both-modes
          (should (eq (plist-get (drgnx-job-snapshot-test--make repo folder "job/7") :mode) mode))
          (let ((seen (drgnx-job-snapshot-test--seen folder)))
            (dolist (s '("env-SECRET" "stashed-SECRET" "amended-SECRET" "wip-SECRET"))
              (should-not (string-search s seen)))
            (should-not (string-search amended seen)))
          (should (equal (drgnx-job-snapshot-test--git folder "for-each-ref" "--format=%(refname)" "refs/heads" "refs/tags" "refs/stash")
                         "refs/heads/job/7"))
          (should-not (string-search amended (drgnx-job-snapshot-test--git folder "reflog" "--all" "--format=%H %gs")))
          (drgnx-job-snapshot-test--checkout folder "job/7-1" "job/7")
          (should (equal (with-temp-buffer (insert-file-contents (concat folder "notes")) (buffer-string)) "clean\n")))))))

(ert-deftest drgnx-job-snapshot/untracked-and-uncommitted-files-not-copied ()
  (drgnx-job-snapshot-test--with
    ;; the user's main checkout: a staged file, a dirty file, an untracked .env
    (write-region "staged-SECRET\n" nil (concat repo "staged.txt") nil 'silent)
    (drgnx-job-snapshot-test--git repo "add" "staged.txt")
    (write-region "dirty-SECRET\n" nil (concat repo "README") nil 'silent)
    (write-region "KEY=env-SECRET\n" nil (concat repo ".env") nil 'silent)
    (drgnx-job-snapshot-test--both-modes
      (drgnx-job-snapshot-test--make repo folder "job/7")
      (should-not (file-exists-p (concat folder ".git/index")))
      (drgnx-job-snapshot-test--checkout folder "job/7-1" "job/7")
      (should (equal (directory-files folder nil directory-files-no-dot-files-regexp) '(".git" "README")))
      (should (equal (with-temp-buffer (insert-file-contents (concat folder "README")) (buffer-string)) "two\n"))
      (let ((seen (drgnx-job-snapshot-test--seen folder)))
        (dolist (s '("staged-SECRET" "dirty-SECRET" "env-SECRET"))
          (should-not (string-search s seen)))))))

(ert-deftest drgnx-job-snapshot/config-is-a-whitelist ()
  (let ((text (drgnx-job-snapshot--config-text
               '(("core.repositoryformatversion" . "1") ("core.filemode" . "true") ("core.bare" . "true")
                 ("extensions.objectformat" . "sha256") ("remote.origin.url" . "/r"))
               '(("core.hookspath" . ".githooks") ("core.autocrlf" . "input") ("filter.lfs.smudge" . "git-lfs smudge -- %f")
                 ("filter.lfs.required" . "true") ("core.fsmonitor" . "/x") ("core.worktree" . "/r")
                 ("submodule.lib.url" . "https://u:S@h/l") ("lfs.url" . "https://u:S@h/") ("credential.helper" . "store")
                 ("filter.lfs.process" . "https://u:S@h/x") ("filter.other.smudge" . "evil"))
               nil)))
    (should (equal text (concat "[core]\n\trepositoryformatversion = \"1\"\n\tfilemode = \"true\"\n"
                                "\tbare = \"false\"\n\thookspath = \".githooks\"\n\tautocrlf = \"input\"\n"
                                "[extensions]\n\tobjectformat = \"sha256\"\n"
                                "[filter \"lfs\"]\n\tsmudge = \"git-lfs smudge -- %f\"\n\trequired = \"true\"\n"
                                "[gc]\n\tauto = \"0\"\n"))))
  ;; a hooks path outside the checkout is not carried; quotes and backslashes are escaped
  (should-not (string-search "hookspath" (drgnx-job-snapshot--config-text nil '(("core.hookspath" . "/etc/hooks")) t)))
  (should-not (string-search "hookspath" (drgnx-job-snapshot--config-text nil '(("core.hookspath" . "../up")) t)))
  (should (string-search "smudge = \"a \\\"b\\\" \\\\c\""
                         (drgnx-job-snapshot--config-text nil '(("filter.lfs.smudge" . "a \"b\" \\c")) t))))

(ert-deftest drgnx-job-snapshot/prepared-copy-has-no-remotes-or-credentials ()
  (drgnx-job-snapshot-test--with
    (let ((secret "tok-SECRET-41a7"))
      (dolist (kv `(("remote.origin.url" ,(format "https://u:%s@example.invalid/r.git" secret))
                    ("credential.helper" "store")
                    ("credential.https://example.invalid.username" ,secret)
                    (,(format "url.https://%s@x.invalid/.insteadOf" secret) "https://x.invalid/")
                    ("http.https://example.invalid/.extraheader" ,(concat "AUTHORIZATION: basic " secret))
                    ("submodule.lib.url" ,(format "https://u:%s@example.invalid/lib" secret))
                    ("branch.main.pushremote" ,(format "https://u:%s@example.invalid/r" secret))
                    (,(format "http.https://u:%s@h.invalid/.sslverify" secret) "false")
                    ("lfs.url" ,(format "https://u:%s@example.invalid/lfs" secret))
                    ("core.hooksPath" ".githooks")))
        (drgnx-job-snapshot-test--git repo "config" (car kv) (cadr kv)))
      (drgnx-job-snapshot-test--git repo "update-ref" "refs/remotes/origin/main" "main")
      (write-region (format "abc\t\tbranch 'main' of https://u:%s@example.invalid/r\n" secret) nil
                    (concat repo ".git/FETCH_HEAD") nil 'silent)
      (drgnx-job-snapshot-test--both-modes
        (should (eq (plist-get (drgnx-job-snapshot-test--make repo folder "job/7") :mode) mode))
        (should-not (string-search secret (drgnx-job-snapshot-test--seen folder)))
        (should (equal (drgnx-job-snapshot-test--git folder "remote") ""))
        (should-not (string-match-p "^\\(remote\\|credential\\|url\\|submodule\\|lfs\\|http\\)\\."
                                    (drgnx-job-snapshot-test--config folder)))
        ;; the project's own hooks path is kept in both modes: its pre-commit runs inside the sandbox
        (should (string-match-p "^core\\.hookspath=\\.githooks$" (drgnx-job-snapshot-test--config folder)))
        (should-not (file-exists-p (concat folder ".git/refs/remotes/origin/main")))))))

(ert-deftest drgnx-job-snapshot/prepared-copy-has-gc-off ()
  (drgnx-job-snapshot-test--with
    (drgnx-job-snapshot-test--both-modes
      (drgnx-job-snapshot-test--make repo folder "job/7")
      (should (equal (drgnx-job-snapshot-test--git folder "config" "--file" ".git/config" "gc.auto") "0"))
      (should (equal (drgnx-job-snapshot-test--git folder "config" "--file" ".git/config" "core.bare") "false")))))

(ert-deftest drgnx-job-snapshot/prepare-runs-none-of-the-user-s-programs ()
  ;; a reference-transaction hook and core.fsmonitor in the user's repo touch a canary when run: making the store and
  ;; the copy runs neither, and the copy has no fsmonitor, no core.worktree and no hooks of the user's
  (drgnx-job-snapshot-test--with
    (let ((canary (concat root "canary")) (hook (concat repo ".git/hooks/reference-transaction")))
      (write-region (format "#!/bin/sh\ntouch %s\n" canary) nil hook nil 'silent)
      (set-file-modes hook #o755)
      (drgnx-job-snapshot-test--git repo "config" "core.fsmonitor" hook)
      (drgnx-job-snapshot-test--git repo "config" "core.worktree" repo)
      (when (file-exists-p canary) (delete-file canary))
      (drgnx-job-snapshot-test--both-modes
        (should (eq (plist-get (drgnx-job-snapshot-test--make repo folder "job/7") :mode) mode))
        (should-not (file-exists-p canary))
        (should-not (file-exists-p (concat folder ".git/hooks/reference-transaction")))
        (should-not (string-match-p "core\\.\\(fsmonitor\\|worktree\\)" (drgnx-job-snapshot-test--config folder)))))))

(ert-deftest drgnx-job-snapshot/user-worktrees-pruned ()
  (drgnx-job-snapshot-test--with
    (drgnx-job-snapshot-test--git repo "worktree" "add" "-q" "-b" "side" (concat root "wt"))   ; still on disk
    (drgnx-job-snapshot-test--both-modes
      (drgnx-job-snapshot-test--make repo folder "job/7")
      (should-not (file-exists-p (concat folder ".git/worktrees")))
      (should (= 1 (length (seq-filter (lambda (l) (string-prefix-p "worktree " l))
                                       (split-string (drgnx-job-snapshot-test--git folder "worktree" "list" "--porcelain") "\n"))))))))

(ert-deftest drgnx-job-snapshot/stale-lock-files-removed ()
  (drgnx-job-snapshot-test--with
    ;; a git of the user's in the middle of its work: none of its locks reaches the copy, and none is touched
    (let ((locks '("index.lock" "HEAD.lock" "config.lock" "packed-refs.lock" "refs/heads/main.lock")))
      (dolist (l locks) (write-region "" nil (concat repo ".git/" l) nil 'silent))
      (drgnx-job-snapshot-test--both-modes
        (should (eq (plist-get (drgnx-job-snapshot-test--make repo folder "job/7") :mode) mode))
        (should-not (directory-files-recursively (concat folder ".git") "\\.lock\\'"))
        (dolist (l locks) (should (file-exists-p (concat repo ".git/" l))))))))

;;;; The job's store

(ert-deftest drgnx-job-snapshot/store-made-once-per-job-and-refreshed ()
  (drgnx-job-snapshot-test--with
    (let ((store (drgnx-job-snapshot-test--store repo)) (other (concat repo ".claude/worktrees/7-2/")))
      (drgnx-job-snapshot-test--snapshot-anyway
        (drgnx-job-snapshot-test--make repo folder "job/7")
        (should (equal (drgnx-job-snapshot-store-dir repo "job/7") store))
        (should (file-regular-p (concat store "HEAD")))
        (should-not (file-exists-p (concat store "hooks")))
        (let ((inode (file-attribute-inode-number (file-attributes (concat store "config")))))
          ;; job/7 moves on (a task merged): the next task sees it; the store is the same one, fetched into
          (write-region "three\n" nil (concat repo "README") nil 'silent)
          (drgnx-job-snapshot-test--git repo "commit" "-q" "-am" "three")
          (drgnx-job-snapshot-test--git repo "branch" "-f" "job/7" "main")
          (should (eq (plist-get (drgnx-job-snapshot-test--make repo other "job/7") :mode) 'snapshot))
          (should (equal (drgnx-job-snapshot-test--git other "log" "--format=%s" "job/7") "three\ntwo\none"))
          (should (equal (file-attribute-inode-number (file-attributes (concat store "config"))) inode))
          (should-not (file-exists-p (concat store "FETCH_HEAD"))))
        ;; two tasks at once: the store's steps run one after the other, both get their copy
        (delete-directory folder t) (delete-directory other t)
        (let (a b)
          (drgnx-job-snapshot-make repo folder "job/7" (lambda (r) (setq a r)))
          (drgnx-job-snapshot-make repo other "job/7" (lambda (r) (setq b r)))
          (should (drgnx-job-snapshot-test--wait-for (lambda () (and a b)) 30))
          (should (eq (plist-get a :mode) 'snapshot))
          (should (eq (plist-get b :mode) 'snapshot))
          (should (= 0 (hash-table-count drgnx-job-snapshot--busy))))))))

(ert-deftest drgnx-job-snapshot/missing-base-retries-once ()
  (drgnx-job-snapshot-test--with
    (drgnx-job-snapshot-test--snapshot-anyway
      (let* ((tries 0) (appears t) (real (symbol-function 'drgnx-job-snapshot--refresh-store)))
        ;; the base appears only after the first try: a git of the user's was writing it
        (cl-letf (((symbol-function 'drgnx-job-snapshot--refresh-store)
                   (lambda (&rest args)
                     (when (and (= (cl-incf tries) 2) appears) (drgnx-job-snapshot-test--git repo "branch" "job/9"))
                     (apply real args))))
          (should (eq (plist-get (drgnx-job-snapshot-test--make repo folder "job/9") :mode) 'snapshot))
          (should (= tries 2))
          (delete-directory folder t)
          ;; never there: an error after the second try, and nothing left
          (setq tries 0 appears nil)
          (let ((r (drgnx-job-snapshot-test--make repo folder "job/nope")))
            (should (string-match-p "job/nope" (plist-get r :error)))
            (should (= tries 2))
            (should-not (file-exists-p folder))
            (should-not (file-exists-p (drgnx-job-snapshot-store-dir repo "job/nope")))))))))

(ert-deftest drgnx-job-snapshot/refusals ()
  (drgnx-job-snapshot-test--with
    (should (plist-get (drgnx-job-snapshot-test--make repo folder "-oops") :error))
    (should (plist-get (drgnx-job-snapshot-test--make repo folder "job~7") :error))
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

(ert-deftest drgnx-job-snapshot/store-works-with-safe-bare-repository-explicit ()
  ;; git's hardening against embedded bare repositories, in the (test's own) global config: every git on the store
  ;; names it with --git-dir, so the second task's fetch into the store still works
  (drgnx-job-snapshot-test--with
    (let* ((global (concat root "gitconfig"))
           (process-environment (cons (concat "GIT_CONFIG_GLOBAL=" global) process-environment))
           (other (concat repo ".claude/worktrees/7-2/")))
      (write-region "[safe]\n\tbareRepository = explicit\n" nil global nil 'silent)
      (dolist (cow '(t nil))
        (let ((drgnx-job-snapshot-copy-on-write cow))
          (drgnx-job-snapshot-test--snapshot-anyway
            (should (memq (plist-get (drgnx-job-snapshot-test--make repo folder "job/7") :mode) '(snapshot clone)))
            ;; job/7 moves on: the fetch must reach the store (not the repository discovery would find instead)
            (write-region (format "%s\n" cow) nil (concat repo "README") nil 'silent)
            (drgnx-job-snapshot-test--git repo "commit" "-q" "-am" "more")
            (drgnx-job-snapshot-test--git repo "branch" "-f" "job/7" "main")
            (should (memq (plist-get (drgnx-job-snapshot-test--make repo other "job/7") :mode) '(snapshot clone)))
            (should (equal (drgnx-job-snapshot-test--git other "rev-parse" "job/7")
                           (drgnx-job-snapshot-test--git repo "rev-parse" "job/7"))))
          (delete-directory folder t) (delete-directory other t))))))

(ert-deftest drgnx-job-snapshot/a-failing-turn-releases-the-store ()
  ;; .claude/worktrees is a file: the turn fails at once; DONE still comes later, with the error, and the store's
  ;; queue is free again, so the next make (the cause gone) completes
  (drgnx-job-snapshot-test--with
    (make-directory (concat repo ".claude") t)
    (write-region "x" nil (concat repo ".claude/worktrees") nil 'silent)
    (let ((got :none) (early nil))
      (drgnx-job-snapshot-make repo folder "job/7" (lambda (r) (setq got r)))
      (setq early (not (eq got :none)))
      (should-not early)
      (should (drgnx-job-snapshot-test--wait-for (lambda () (not (eq got :none)))))
      (should (plist-get got :error))
      (should (= 0 (hash-table-count drgnx-job-snapshot--busy))))
    (delete-file (concat repo ".claude/worktrees"))
    (should (memq (plist-get (drgnx-job-snapshot-test--make repo folder "job/7") :mode) '(snapshot clone)))))

(ert-deftest drgnx-job-snapshot/a-store-a-stopped-job-left-is-made-again ()
  ;; the job is stopped after the store's clone, before its config is written: that store is never used as is
  (drgnx-job-snapshot-test--with
    (let ((drgnx-job-snapshot-copy-on-write nil) (got :none) (store (drgnx-job-snapshot-test--store repo))
          (run (symbol-function 'drgnx-job-snapshot--run)))
      (drgnx-job-snapshot-test--git repo "remote" "add" "origin" "https://example.invalid/r.git")
      (cl-letf (((symbol-function 'drgnx-job-snapshot--run)
                 (lambda (dir argv job done)
                   (let ((p (funcall run dir argv job done)))
                     (when (member "--list" argv)            ; what `drgnx-job-stop' does to the job's processes
                       (process-put p :stopped t) (delete-process p))
                     p))))
        (drgnx-job-snapshot-make repo folder "job/7" (lambda (r) (setq got r)) "job-x")
        (drgnx-job-snapshot-test--wait-for (lambda () (= 0 (hash-table-count drgnx-job-snapshot--busy)))))
      (should (eq got :none))                                     ; a stopped job hears nothing
      (should (eq (plist-get (drgnx-job-snapshot-test--make repo folder "job/7") :mode) 'clone))
      (should-not (string-match-p "remote\\." (drgnx-job-snapshot-test--git store "config" "--file" "config" "--list")))
      (should (equal (drgnx-job-snapshot-test--git store "config" "--file" "config" "gc.auto") "0")))))

(ert-deftest drgnx-job-snapshot/failure-path-completes-when-rm-cannot-start ()
  ;; the base is missing, so the store fails and its part is removed — but `rm' cannot start: DONE still comes
  (drgnx-job-snapshot-test--with
    (let ((drgnx-job-snapshot-copy-on-write nil) (run (symbol-function 'drgnx-job-snapshot--run)) (got nil) (rms 0))
      ;; the first `rm' (a leftover part, in the turn itself) starts; those of the failure paths, in sentinels, do not
      (cl-letf (((symbol-function 'drgnx-job-snapshot--run)
                 (lambda (dir argv job done)
                   (if (and (equal (car argv) "rm") (> (cl-incf rms) 1))
                       (error "Cannot start rm")
                     (funcall run dir argv job done)))))
        (drgnx-job-snapshot-make repo folder "job/nope" (lambda (r) (setq got r)))
        (should (drgnx-job-snapshot-test--wait-for (lambda () got)))
        (should (plist-get got :error))
        (should (= 0 (hash-table-count drgnx-job-snapshot--busy)))))))

(ert-deftest drgnx-job-snapshot/run-keeps-stderr-and-leaks-nothing ()
  (let ((got nil) (big 200000))
    (drgnx-job-snapshot--run temporary-file-directory
                             (list "sh" "-c" (format "head -c %d /dev/zero | tr '\\0' x >&2; exit 3" big)) nil
                             (lambda (r) (setq got r)))
    (should (drgnx-job-snapshot-test--wait-for (lambda () got)))
    (should (eql (car got) 3))
    (should (= (length (cddr got)) big)))
  ;; a program that cannot start: an error, and no process or buffer left behind
  (let ((procs (length (process-list))) (bufs (length (buffer-list))))
    (should-error (drgnx-job-snapshot--run temporary-file-directory (list "drgnx-no-such-program-x") nil #'ignore))
    (should (= (length (process-list)) procs))
    (should (= (length (buffer-list)) bufs))))

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
      ;; the job's store goes the same way
      (setq removed nil)
      (drgnx-job-snapshot-remove (drgnx-job-snapshot-test--store repo) (lambda (r) (setq removed r)))
      (should (eq (drgnx-job-snapshot-test--wait-for (lambda () removed)) t))
      (should-not (file-exists-p (drgnx-job-snapshot-test--store repo)))
      ;; only its own folders: not the repository, not a session worktree, not a job tree (a .git file)
      (let ((session (concat repo ".claude/worktrees/sb-t6/")) (tree (concat repo ".claude/worktrees/job-1-2/")))
        (make-directory (concat session ".git") t)
        (make-directory tree t)
        (write-region "gitdir: x\n" nil (concat tree ".git") nil 'silent)
        (dolist (dir (list repo session tree))
          (let ((r nil))
            (drgnx-job-snapshot-remove dir (lambda (x) (setq r x)))
            (should (plist-get (drgnx-job-snapshot-test--wait-for (lambda () r)) :error))
            (should (file-directory-p dir)))))
      ;; a link anywhere below the repository: .claude/worktrees links elsewhere, the task folder itself is real
      (let* ((elsewhere (concat root "elsewhere/")) (other (concat root "other/"))
             (task (concat other ".claude/worktrees/7-3/")) (r nil))
        (make-directory (concat elsewhere "7-3/.git") t)
        (make-directory (concat other ".claude") t)
        (make-symbolic-link (directory-file-name elsewhere) (concat other ".claude/worktrees"))
        (drgnx-job-snapshot-remove task (lambda (x) (setq r x)))
        (should (plist-get (drgnx-job-snapshot-test--wait-for (lambda () r)) :error))
        (should (file-directory-p (concat elsewhere "7-3/.git")))))))

;;;; Inside the sandbox: the checkout, the bundle, the base's refresh

(defun drgnx-job-snapshot-test--await (fn &optional secs)
  "Call FN with a DONE and wait for it: what DONE got, or `:timeout'."
  (let ((got :timeout) (deadline (+ (float-time) (or secs 30))))
    (funcall fn (lambda (r) (setq got r)))
    (while (and (eq got :timeout) (< (float-time) deadline)) (accept-process-output nil 0.05))
    got))

(defvar drgnx-job-snapshot-test--sandbox-ok 'unknown)

(defun drgnx-job-snapshot-test--unsandboxed ()
  "Non-nil where the real sandbox cannot run (a container, no bwrap): the steps then run plainly, as for a job the
user let run unsandboxed.  Here the steps run inside bwrap."
  (when (eq drgnx-job-snapshot-test--sandbox-ok 'unknown)
    (setq drgnx-job-snapshot-test--sandbox-ok (and (plist-get (drgnx-sandbox-check) :ok) t)))
  (not drgnx-job-snapshot-test--sandbox-ok))

(defun drgnx-job-snapshot-test--task (repo folder)
  "FOLDER's snapshot of REPO at job/7, checked out at job/7-1 (the agent's part, by the test's git)."
  (should (memq (car (drgnx-job-snapshot-test--make repo folder "job/7")) '(:mode)))
  (drgnx-job-snapshot-test--checkout folder "job/7-1" "job/7"))

(defun drgnx-job-snapshot-test--commit (folder n)
  "N commits in FOLDER on its branch, as the agent makes them."
  (dotimes (i n)
    (write-region (format "work %d\n" i) nil (concat folder "WORK") nil 'silent)
    (drgnx-job-snapshot-test--git folder "add" "WORK")
    (drgnx-job-snapshot-test--git folder "commit" "-q" "-m" (format "work %d" i))))

(defun drgnx-job-snapshot-test--fetch (repo bundle)
  (drgnx-job-snapshot-test--await (lambda (d) (drgnx-job-snapshot-fetch repo bundle "job/7-1" "job/7" d))))

(defun drgnx-job-snapshot-test--ref (dir ref)
  "REF's commit in DIR, or nil."
  (ignore-errors (drgnx-job-snapshot-test--git dir "rev-parse" "--verify" "-q" ref)))

(ert-deftest drgnx-job-snapshot/checkout-happens-inside ()
  "The checkout and the bundle are steps of `drgnx-sandbox-run' (stubbed and recorded): the folder writable only for
the checkout, no home, no network, git's global and system config off, the folder's hooks and fsmonitor off.  No
sandbox means no step, never a plain run."
  (drgnx-job-snapshot-test--with
    (let ((calls nil) (out (concat root "out")))
      (make-directory out)
      (should (eq (car (drgnx-job-snapshot-test--make repo folder "job/7")) :mode))
      (cl-letf (((symbol-function 'drgnx-sandbox-run)
                 (lambda (spec argv done &optional _) (push (list spec argv) calls) (run-at-time 0 nil done '(0 . "")))))
        (should (eq (drgnx-job-snapshot-test--await (lambda (d) (drgnx-job-snapshot-checkout folder "job/7-1" "job/7" d))) t))
        (drgnx-job-snapshot-test--await (lambda (d) (drgnx-job-snapshot-bundle folder "job/7" "job/7-1" out d))))
      (should (= (length calls) 2))
      (let* ((dir (directory-file-name folder))
             (checkout (car (last calls))) (spec (car checkout)) (env (plist-get spec :env)))
        (should (equal (plist-get spec :write) (list dir)))
        (should-not (member dir (plist-get spec :read)))
        (should (equal (plist-get spec :chdir) dir))
        (should (eq (plist-get spec :net) 'isolated))
        (should-not (plist-get spec :home))
        (should (equal (cdr (assoc "HOME" env)) "/nonexistent"))
        (should (equal (cdr (assoc "GIT_CONFIG_NOSYSTEM" env)) "1"))
        (should (equal (cdr (assoc "GIT_CONFIG_GLOBAL" env)) "/dev/null"))
        (should (equal (cadr checkout)
                       '("git" "-c" "core.hooksPath=/dev/null" "-c" "core.fsmonitor=false" "-c" "core.pager=cat"
                         "-c" "core.editor=false" "checkout" "-q" "-f" "-B" "job/7-1" "refs/heads/job/7")))
        ;; the bundle: the folder read-only, only OUT writable
        (let ((spec (car (car calls))))
          (should-not (plist-get spec :write))
          (should (member dir (plist-get spec :read)))
          (should (equal (plist-get spec :binds) (list (list 'rw (directory-file-name (file-truename out)) "/run/drgnx/out"))))
          (should (equal (last (cadr (car calls)) 4)
                         '("create" "-q" "/run/drgnx/out/task.bundle" "refs/heads/job/7..refs/heads/job/7-1")))))
      ;; fail closed: without a sandbox the step is refused, and nothing is checked out
      (cl-letf (((symbol-function 'drgnx-sandbox-wrap)
                 (lambda (&rest _) (signal 'drgnx-sandbox-refused (list "no sandbox on this system")))))
        (let ((r (drgnx-job-snapshot-test--await (lambda (d) (drgnx-job-snapshot-checkout folder "job/7-1" "job/7" d)))))
          (should (eq (car-safe r) :error))
          (should (string-match-p "no sandbox" (cadr r)))))
      (should-not (file-exists-p (concat folder "README"))))))

(ert-deftest drgnx-job-snapshot/checkout-happens-inside-the-real-sandbox ()
  "The checkout runs in bwrap: README appears in the folder.  Skipped where the sandbox cannot run."
  (drgnx-job-snapshot-test--with
    (when (drgnx-job-snapshot-test--unsandboxed) (ert-skip "the sandbox cannot run here (drgnx-sandbox-check)"))
    (should (eq (car (drgnx-job-snapshot-test--make repo folder "job/7")) :mode))
    (should (eq (drgnx-job-snapshot-test--await (lambda (d) (drgnx-job-snapshot-checkout folder "job/7-1" "job/7" d))) t))
    (should (equal (with-temp-buffer (insert-file-contents (concat folder "README")) (buffer-string)) "two\n"))
    (should (equal (drgnx-job-snapshot-test--git folder "symbolic-ref" "HEAD") "refs/heads/job/7-1"))))

(ert-deftest drgnx-job-snapshot/bundle-round-trip ()
  "Two commits made in the task come back as job/7-1 in the main repository, both modes."
  (drgnx-job-snapshot-test--with
    (let ((out (concat root "out")) (plain (drgnx-job-snapshot-test--unsandboxed)))
      (make-directory out)
      (drgnx-job-snapshot-test--both-modes
        (should (eq (car (drgnx-job-snapshot-test--make repo folder "job/7")) :mode))
        (should (eq (drgnx-job-snapshot-test--await
                     (lambda (d) (drgnx-job-snapshot-checkout folder "job/7-1" "job/7" d plain)))
                    t))
        (drgnx-job-snapshot-test--commit folder 2)
        (let ((r (drgnx-job-snapshot-test--await (lambda (d) (drgnx-job-snapshot-bundle folder "job/7" "job/7-1" out d plain))))
              (tip (drgnx-job-snapshot-test--ref folder "job/7-1")))
          (should (equal r (list :bundle (expand-file-name "task.bundle" (file-truename out)))))
          (should (equal (drgnx-job-snapshot-test--fetch repo (cadr r)) (list :fetched tip)))
          (should (equal (drgnx-job-snapshot-test--ref repo "refs/heads/job/7-1") tip))
          (should (equal (drgnx-job-snapshot-test--git repo "log" "--format=%s" "job/7..job/7-1") "work 1\nwork 0")))
        (drgnx-job-snapshot-test--git repo "branch" "-D" "job/7-1")))))

(ert-deftest drgnx-job-snapshot/empty-bundle-means-no-commits ()
  (drgnx-job-snapshot-test--with
    (let ((out (concat root "out")) (plain (drgnx-job-snapshot-test--unsandboxed)))
      (make-directory out)
      (drgnx-job-snapshot-test--task repo folder)
      ;; a stale bundle of an earlier turn never stands for this one
      (write-region "stale" nil (concat out "/task.bundle") nil 'silent)
      (should (equal (drgnx-job-snapshot-test--await (lambda (d) (drgnx-job-snapshot-bundle folder "job/7" "job/7-1" out d plain)))
                     '(:empty)))
      (should-not (file-exists-p (concat out "/task.bundle")))
      ;; what cannot be removed there ends in DONE, never as a signal out of the call
      (make-directory (concat out "/task.bundle"))
      (let ((r (drgnx-job-snapshot-test--await (lambda (d) (drgnx-job-snapshot-bundle folder "job/7" "job/7-1" out d plain)))))
        (should (eq (car-safe r) :error))))))

(ert-deftest drgnx-job-snapshot/bundle-refusals ()
  "Refused, and the main repository's job/7-1 is as it was: a link for task.bundle, a second ref, a branch that does
not descend from the base, a malformed object (fsckObjects).  The bundles are made by the test, as an agent would."
  (drgnx-job-snapshot-test--with
    (let* ((out (concat root "out/")) (bundle (concat out "task.bundle")) (base (drgnx-job-snapshot-test--ref repo "job/7"))
           (refused (lambda (why)
                      (let ((r (drgnx-job-snapshot-test--fetch repo bundle)))
                        (ert-info ((format "%S" r))
                          (should (eq (car-safe r) :error))
                          (should (string-match-p why (cadr r))))))))
      (make-directory out)
      (drgnx-job-snapshot-test--task repo folder)
      (drgnx-job-snapshot-test--commit folder 1)
      ;; a link to a good bundle
      (drgnx-job-snapshot-test--git folder "bundle" "create" "-q" (concat root "real.bundle") "refs/heads/job/7..refs/heads/job/7-1")
      (make-symbolic-link (concat root "real.bundle") bundle)
      (funcall refused "link or not a regular file")
      (should-not (drgnx-job-snapshot-test--ref repo "refs/heads/job/7-1"))
      (delete-file bundle)
      ;; larger than the bound: never read
      (copy-file (concat root "real.bundle") bundle)
      (let ((drgnx-job-snapshot-bundle-max 10)) (funcall refused "larger than"))
      (should-not (drgnx-job-snapshot-test--ref repo "refs/heads/job/7-1"))
      (delete-file bundle)
      ;; a second ref: main would be written too
      (drgnx-job-snapshot-test--git folder "branch" "main" "job/7-1")
      (drgnx-job-snapshot-test--git folder "bundle" "create" "-q" bundle "^refs/heads/job/7" "refs/heads/job/7-1" "refs/heads/main")
      (let ((main (drgnx-job-snapshot-test--ref repo "main")))
        (funcall refused "more than refs/heads/job/7-1")
        (should (equal (drgnx-job-snapshot-test--ref repo "main") main)))
      (should-not (drgnx-job-snapshot-test--ref repo "refs/heads/job/7-1"))
      (delete-file bundle)
      ;; not descending from the base: the earlier job/7-1 is put back, or none stays when there was none
      (let ((orphan (drgnx-job-snapshot-test--git folder "commit-tree" "job/7^{tree}" "-m" "orphan")))
        (drgnx-job-snapshot-test--git folder "update-ref" "refs/heads/job/7-1" orphan)
        (drgnx-job-snapshot-test--git folder "bundle" "create" "-q" bundle "refs/heads/job/7..refs/heads/job/7-1")
        (drgnx-job-snapshot-test--git repo "branch" "job/7-1" "job/7")
        (funcall refused "does not descend from job/7")
        (should (equal (drgnx-job-snapshot-test--ref repo "refs/heads/job/7-1") base))
        (drgnx-job-snapshot-test--git repo "branch" "-D" "job/7-1")
        (funcall refused "does not descend from job/7")
        (should-not (drgnx-job-snapshot-test--ref repo "refs/heads/job/7-1")))
      (delete-file bundle)
      ;; a malformed commit (a bad date): fsckObjects refuses it, even where the user's config turns fetch's fsck off
      (let* ((tree (drgnx-job-snapshot-test--git folder "rev-parse" "job/7^{tree}"))
             (bad (with-temp-buffer
                    (insert (format "tree %s\nparent %s\nauthor bad <x> notanumber +0000\ncommitter t <t@t> 1 +0000\n\nbad\n" tree base))
                    (let ((default-directory folder))
                      (call-process-region (point-min) (point-max) "git" t t nil "hash-object" "-t" "commit" "--literally" "-w" "--stdin"))
                    (string-trim (buffer-string)))))
        (drgnx-job-snapshot-test--git folder "update-ref" "refs/heads/job/7-1" bad)
        (drgnx-job-snapshot-test--git folder "bundle" "create" "-q" bundle "refs/heads/job/7..refs/heads/job/7-1")
        (drgnx-job-snapshot-test--git repo "config" "fetch.fsckObjects" "false")
        (funcall refused "fsck\\|bad date")
        (should-not (drgnx-job-snapshot-test--ref repo "refs/heads/job/7-1"))))))

(ert-deftest drgnx-job-snapshot/fetch-runs-no-agent-hooks-or-config ()
  "The folder's core.fsmonitor and its hooks (post-checkout, post-merge, reference-transaction) would touch a
canary: neither drgnx's checkout and bundle steps nor the fetch outside ever runs them.  The steps run UNSANDBOXED
here, so the overrides are the only defence (inside bwrap the canary's directory is not even there).  Last, the
test's own git in the folder shows the plant works."
  (drgnx-job-snapshot-test--with
    (let* ((out (concat root "out")) (canary (concat root "canary"))
           (touch (format "#!/bin/sh\ntouch %s\n" (shell-quote-argument canary))))
      (make-directory out)
      (should (eq (car (drgnx-job-snapshot-test--make repo folder "job/7")) :mode))
      (make-directory (concat folder ".git/hooks") t)
      (dolist (hook '("post-checkout" "post-merge" "reference-transaction" "pre-auto-gc"))
        (let ((file (concat folder ".git/hooks/" hook)))
          (write-region touch nil file nil 'silent)
          (set-file-modes file #o755)))
      (write-region touch nil (concat root "fsmonitor") nil 'silent)
      (set-file-modes (concat root "fsmonitor") #o755)
      (drgnx-job-snapshot-test--git folder "config" "--file" ".git/config" "core.fsmonitor" (concat root "fsmonitor"))
      (should (eq (drgnx-job-snapshot-test--await (lambda (d) (drgnx-job-snapshot-checkout folder "job/7-1" "job/7" d t))) t))
      (should (file-exists-p (concat folder "README")))
      ;; the agent's commit, made here without the plants
      (write-region "work\n" nil (concat folder "WORK") nil 'silent)
      (drgnx-job-snapshot-test--git folder "-c" "core.hooksPath=/dev/null" "-c" "core.fsmonitor=false" "add" "WORK")
      (drgnx-job-snapshot-test--git folder "-c" "core.hooksPath=/dev/null" "-c" "core.fsmonitor=false" "commit" "-q" "-m" "work")
      (let ((r (drgnx-job-snapshot-test--await (lambda (d) (drgnx-job-snapshot-bundle folder "job/7" "job/7-1" out d t)))))
        (should (eq (car r) :bundle))
        (should (eq (car (drgnx-job-snapshot-test--fetch repo (cadr r))) :fetched)))
      (should-not (file-exists-p canary))
      ;; the plant is real: git run plainly in the folder runs it
      (drgnx-job-snapshot-test--git folder "status" "--short")
      (should (file-exists-p canary)))))

(ert-deftest drgnx-job-snapshot/reviewer-snapshot-has-no-agent-config ()
  "The reviewer's folder comes from a store of job/7-1 made from the main repository after the fetch: the
implementer's config, hooks and secrets never reach it; job/7-1 is checked out."
  (drgnx-job-snapshot-test--with
    (let ((out (concat root "out")) (review (concat repo ".claude/worktrees/7-1-review/"))
          (plain (drgnx-job-snapshot-test--unsandboxed)))
      (make-directory out)
      (drgnx-job-snapshot-test--task repo folder)
      (drgnx-job-snapshot-test--commit folder 1)
      (make-directory (concat folder ".git/hooks") t)
      (write-region "#!/bin/sh\necho HOOK-CANARY\n" nil (concat folder ".git/hooks/post-checkout") nil 'silent)
      (drgnx-job-snapshot-test--git folder "config" "--file" ".git/config" "core.fsmonitor" "/bin/false")
      (drgnx-job-snapshot-test--git folder "config" "--file" ".git/config" "agent.token" "SECRET-CANARY")
      (let ((r (drgnx-job-snapshot-test--await (lambda (d) (drgnx-job-snapshot-bundle folder "job/7" "job/7-1" out d plain)))))
        (should (eq (car (drgnx-job-snapshot-test--fetch repo (cadr r))) :fetched)))
      (let ((r (drgnx-job-snapshot-test--await (lambda (d) (drgnx-job-snapshot-review-folder repo "job/7-1" review d plain)))))
        (should (eq (car r) :mode)))
      (should (file-directory-p (concat repo ".claude/worktrees/job~7-1.base.git")))
      (should (equal (drgnx-job-snapshot-test--git review "symbolic-ref" "HEAD") "refs/heads/job/7-1"))
      (should (equal (with-temp-buffer (insert-file-contents (concat review "WORK")) (buffer-string)) "work 0\n"))
      (let ((config (drgnx-job-snapshot-test--config review)) (seen (drgnx-job-snapshot-test--seen review)))
        (should-not (string-match-p "fsmonitor\\|agent\\.token" config))
        (should-not (string-match-p "SECRET-CANARY\\|HOOK-CANARY" seen))))))

(ert-deftest drgnx-job-snapshot/parallel-task-lands-after-another-merges ()
  "Tasks 7-1 and 7-2 fork from job/7 at S.  7-1's work is fetched and merged (job/7 moves on).  7-2's bundle,
from its own start S, still lands: the descend check is against the task's start, not the branch's tip.  Against
job/7's moved tip it would be refused."
  (drgnx-job-snapshot-test--with
    (let* ((out (concat root "out")) (plain (drgnx-job-snapshot-test--unsandboxed))
           (folder2 (concat repo ".claude/worktrees/7-2/"))
           (start (plist-get (drgnx-job-snapshot-test--make repo folder "job/7") :start))
           (start2 (plist-get (drgnx-job-snapshot-test--make repo folder2 "job/7") :start)))
      (make-directory out)
      (should (equal start (drgnx-job-snapshot-test--ref repo "job/7")))
      (should (equal start2 start))
      (dolist (f (list (cons folder "job/7-1") (cons folder2 "job/7-2")))
        (should (eq (drgnx-job-snapshot-test--await (lambda (d) (drgnx-job-snapshot-checkout (car f) (cdr f) "job/7" d plain))) t))
        ;; work of its own: two equal commits in one second would be one commit
        (write-region (cdr f) nil (concat (car f) "WHO") nil 'silent)
        (drgnx-job-snapshot-test--git (car f) "add" "WHO")
        (drgnx-job-snapshot-test--commit (car f) 1))
      ;; 7-1 lands and is merged: job/7 moves on
      (let ((r (drgnx-job-snapshot-test--await (lambda (d) (drgnx-job-snapshot-bundle folder "job/7" "job/7-1" out d plain start)))))
        (should (equal (car (drgnx-job-snapshot-test--await (lambda (d) (drgnx-job-snapshot-fetch repo (cadr r) "job/7-1" start d))))
                       :fetched)))
      (drgnx-job-snapshot-test--git repo "branch" "-f" "job/7" "job/7-1")
      ;; 7-2: from its own start it lands; against job/7's tip it would not
      (let* ((r (drgnx-job-snapshot-test--await (lambda (d) (drgnx-job-snapshot-bundle folder2 "job/7" "job/7-2" out d plain start))))
             (tip (drgnx-job-snapshot-test--ref folder2 "job/7-2")))
        (should (eq (car r) :bundle))
        (should (eq (car-safe (drgnx-job-snapshot-test--await (lambda (d) (drgnx-job-snapshot-fetch repo (cadr r) "job/7-2" "job/7" d))))
                    :error))
        (should-not (drgnx-job-snapshot-test--ref repo "refs/heads/job/7-2"))
        (should (equal (drgnx-job-snapshot-test--await (lambda (d) (drgnx-job-snapshot-fetch repo (cadr r) "job/7-2" start d)))
                       (list :fetched tip)))
        (should (equal (drgnx-job-snapshot-test--ref repo "refs/heads/job/7-2") tip))))))

(defvar drgnx-sandbox-vc-trusted)

(ert-deftest drgnx-job-snapshot/unsandboxed-steps-are-the-hub-s-trusted-steps ()
  "An unsandboxed job's steps run git in the task folder outside any sandbox: they start with
`drgnx-sandbox-vc-trusted' bound, so the VC guard (Task 9) lets them through; sandboxed steps never bind it."
  (drgnx-job-snapshot-test--with
    (let ((seen nil) (real (symbol-function 'drgnx-job-snapshot--run)))
      (should (eq (car (drgnx-job-snapshot-test--make repo folder "job/7")) :mode))
      (cl-letf (((symbol-function 'drgnx-job-snapshot--run)
                 (lambda (dir argv job done)
                   (when (equal dir folder) (push (bound-and-true-p drgnx-sandbox-vc-trusted) seen))
                   (funcall real dir argv job done))))
        (should (eq (drgnx-job-snapshot-test--await (lambda (d) (drgnx-job-snapshot-checkout folder "job/7-1" "job/7" d t))) t)))
      (should (equal seen '(t)))
      (should-not (bound-and-true-p drgnx-sandbox-vc-trusted)))))

(ert-deftest drgnx-job-snapshot/refresh-base-fetches-inside ()
  "A merge-conflict retry: the new job/7 is bundled from the main repository and fetched by a step inside the
sandbox (stubbed: it records the spec, then runs the git plainly), the bundle's directory read-only, then removed."
  (drgnx-job-snapshot-test--with
    (let ((calls nil))
      (drgnx-job-snapshot-test--task repo folder)
      (write-region "three\n" nil (concat repo "README") nil 'silent)
      (drgnx-job-snapshot-test--git repo "commit" "-q" "-am" "three")
      (drgnx-job-snapshot-test--git repo "branch" "-f" "job/7" "main")
      (cl-letf (((symbol-function 'drgnx-sandbox-run)
                 (lambda (spec argv done &optional _)
                   (push (list spec argv (file-exists-p (car (last argv 2)))) calls)
                   (let ((r (with-temp-buffer
                              (let ((default-directory (file-name-as-directory (plist-get spec :chdir))))
                                (cons (apply #'call-process (car argv) nil t nil (cdr argv)) (buffer-string))))))
                     (run-at-time 0 nil done r)))))
        ;; DONE names the commit brought: the task's new start, for its later bundles and fetches
        (should (equal (drgnx-job-snapshot-test--await (lambda (d) (drgnx-job-snapshot-refresh-base repo folder "job/7" d)))
                       (list :refreshed (drgnx-job-snapshot-test--ref repo "job/7")))))
      (should (= (length calls) 1))
      (pcase-let ((`(,spec ,argv ,there) (car calls)))
        (should there)
        (should (equal (plist-get spec :write) (list (directory-file-name folder))))
        (should (member (directory-file-name (file-name-directory (car (last argv 2)))) (plist-get spec :read)))
        (should (eq (plist-get spec :net) 'isolated))
        (should (equal (last argv 6) (list "fetch" "-q" "--no-tags" "--no-write-fetch-head" (car (last argv 2))
                                           "+refs/heads/job/7:refs/heads/job/7"))))
      (should (equal (drgnx-job-snapshot-test--ref folder "job/7") (drgnx-job-snapshot-test--ref repo "job/7")))
      ;; the bundle's directory goes
      (should (drgnx-job-snapshot-test--wait-for
               (lambda () (null (directory-files (concat repo ".claude/worktrees/") nil "\\`\\.drgnx-base-"))))))))

;;; job-snapshot-test.el ends here
