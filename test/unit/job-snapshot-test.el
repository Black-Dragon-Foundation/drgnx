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
    (let* ((drgnx-job-snapshot-copy-on-write nil)
           (objects (directory-file-name (concat (drgnx-job-snapshot-test--store repo) "objects"))))
      ;; it borrows from the job's clean store, never from the user's .git
      (should (equal (drgnx-job-snapshot-test--make repo folder "job/7") (list :mode 'clone :read (list objects))))
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

;;; job-snapshot-test.el ends here
