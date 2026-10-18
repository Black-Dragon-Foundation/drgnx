;;; work-test.el --- batch tests: the work tracker — store, scan, links -*- lexical-binding: t -*-
;; Fixture roots (a spec, plans, ledgers, a git repo with commits and a worktree, a board) in temp dirs.
(require 'ert)
(require 'drgnx-work-db)
(require 'drgnx-work-scan)

(defun drgnx-work-test--git (dir &rest args)
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (unless (eql 0 (apply #'call-process "git" nil t nil "-c" "user.name=t" "-c" "user.email=t@t.invalid" args))
        (error "git %S: %s" args (buffer-string)))
      (string-trim (buffer-string)))))

(defun drgnx-work-test--commit (repo file text msg)
  (write-region text nil (expand-file-name file repo) nil 'silent)
  (drgnx-work-test--git repo "add" "-A")
  (drgnx-work-test--git repo "commit" "-q" "-m" msg)
  (drgnx-work-test--git repo "rev-parse" "--short" "HEAD"))

(defun drgnx-work-test--write (root file text)
  (let ((f (expand-file-name file root)))
    (make-directory (file-name-directory f) t)
    (write-region text nil f nil 'silent)
    f))

(defmacro drgnx-work-test--with (root &rest body)
  "BODY with ROOT a fixture: docs/specs/s.md, docs/plans/p.md (two tasks with steps), a code repo
code/ with three commits, p's ledger naming the first two, a board TODO from p."
  (declare (indent 1))
  `(let* ((,root (file-name-as-directory (file-truename (make-temp-file "drgnx-work" t))))   ; git's paths: macOS /private/var
          (process-environment (append (list (concat "DRGNX_DATA_DIR=" ,root "data") (concat "DRGNX_CONFIG_DIR=" ,root "config"))
                                       process-environment))
          (drgnx-work-db--handles nil)
          (code (concat ,root "code/")))
     (unwind-protect
         (progn
           (make-directory code t)
           (drgnx-work-test--git code "init" "-q" "-b" "main")
           (write-region ".superpowers/\n.claude/\n" nil (expand-file-name ".gitignore" code) nil 'silent)   ; as in real repos
           (let* ((c0 (drgnx-work-test--commit code "a" "0" "base"))
                  (c1 (drgnx-work-test--commit code "a" "1" "task one"))
                  (c2 (drgnx-work-test--commit code "b" "2" "task one, more")))
             (ignore c0 c1 c2)
             (drgnx-work-test--write ,root "docs/specs/s.md" "# The spec\n")
             (drgnx-work-test--write ,root "docs/plans/p.md"
                                     "# Plan P\n\n**Spec:** `docs/specs/s.md`\n\n### Task 1: First\n- [x] **Step 1: test**\n- [ ] **Step 2: code**\n\n### Task 2: Second\n- [ ] one\n")
             (drgnx-work-test--write ,root "code/.superpowers/sdd/p/progress.md"
                                     (format "# SDD ledger — plan: %sdocs/plans/p.md\nTask 1: complete (commits %s..%s, tests: ok)\nTask 1: Ruling: keep it small — why — cost\n" ,root c0 c2))
             (drgnx-work-test--write ,root "org/board.org"
                                     (format "* code\n:PROPERTIES:\n:PROJECT_ROOT: %s\n:END:\n** DONE one\n:PROPERTIES:\n:ONBOARD_ID: x1\n:PLAN_FILE: docs/plans/p.md\n:PLAN_TEXT: one\n:END:\n" ,root))
             ,@body))
       (drgnx-work-db-close-all)
       (delete-directory ,root t))))

(defun drgnx-work-test--scan (root) (drgnx-work-scan (list root) :board (concat root "org/board.org")))
(defun drgnx-work-test--kids (id &optional kind)
  (seq-filter (lambda (n) (or (null kind) (eq (plist-get n :kind) kind))) (drgnx-work-children id)))

;;;; Task 1: the store

(ert-deftest drgnx-work/the-store-keeps-nodes-edges-and-its-version ()
  (let* ((dir (make-temp-file "drgnx-work-db" t))
         (process-environment (cons (concat "DRGNX_DATA_DIR=" dir) process-environment))
         (drgnx-work-db--handles nil))
    (unwind-protect
        (progn
          (drgnx-work-put-node "plan:a" :kind 'plan :title "A" :path "/a.md" :line 1 :status "open" :source "/a.md")
          (drgnx-work-put-node "task:a#1" :kind 'task :title "T1" :parent "plan:a" :ord 1 :source "/a.md")
          (drgnx-work-put-node "task:a#2" :kind 'task :title "T2" :parent "plan:a" :ord 2 :source "/a.md")
          (drgnx-work-put-edge "commit:abc" "task:a#1" 'implements 'recorded)
          (should (equal (plist-get (drgnx-work-node "plan:a") :title) "A"))
          (should (equal (mapcar (lambda (n) (plist-get n :id)) (drgnx-work-children "plan:a")) '("task:a#1" "task:a#2")))
          (should (equal (drgnx-work-edges-to "task:a#1" 'implements) '(("commit:abc" . recorded))))
          (drgnx-work-forget-source "/a.md")                               ; a rescan of the file
          (should-not (drgnx-work-node "task:a#1"))
          (should (drgnx-work-edges-to "task:a#1" 'implements))           ; recorded links are kept
          (should (equal (drgnx-work-db-version) drgnx-work-db-schema-version))
          (should (= (caar (sqlite-select (drgnx-work-db) "pragma busy_timeout")) 5000)))
      (drgnx-work-db-close-all)
      (delete-directory dir t))))

(ert-deftest drgnx-work/a-store-another-process-began-migrating-opens ()
  ;; tables and an index there, no schema row yet: what a second Emacs opening a fresh work.db meets
  (let* ((dir (make-temp-file "drgnx-work-db" t))
         (process-environment (cons (concat "DRGNX_DATA_DIR=" dir) process-environment))
         (drgnx-work-db--handles nil))
    (unwind-protect
        (let ((db (sqlite-open (drgnx-work-db-file))))
          (sqlite-execute db "create table meta (key text primary key, value text)")
          (sqlite-execute db "create table node (id text primary key, kind text, title text, path text, line integer,
                            status text, parent text, ord integer, source text, data text, updated real)")
          (sqlite-execute db "create index node_parent on node(parent)")
          (sqlite-close db)
          (should (equal (drgnx-work-db-version) drgnx-work-db-schema-version))
          (drgnx-work-put-edge "commit:abc" "task:a#1" 'implements 'recorded)
          (should (drgnx-work-edges-to "task:a#1" 'implements)))
      (drgnx-work-db-close-all)
      (delete-directory dir t))))

;;;; Task 2: the scan

(ert-deftest drgnx-work/a-plan-with-its-spec-tasks-and-steps ()
  (drgnx-work-test--with root
    (drgnx-work-test--scan root)
    (let* ((spec (concat "spec:" root "docs/specs/s.md")) (plan (concat "plan:" root "docs/plans/p.md")))
      (should (equal (plist-get (drgnx-work-node spec) :title) "The spec"))
      (should (equal (mapcar (lambda (n) (plist-get n :id)) (drgnx-work-test--kids spec 'plan)) (list plan)))
      (let ((tasks (drgnx-work-test--kids plan 'task)))
        (should (equal (mapcar (lambda (n) (plist-get n :title)) tasks) '("First" "Second")))
        (should (equal (mapcar (lambda (n) (plist-get n :status)) tasks) '("done" "open")))   ; the ledger says Task 1
        (should (equal (mapcar (lambda (n) (plist-get n :status)) (drgnx-work-test--kids (plist-get (car tasks) :id) 'step))
                       '("done" "open"))))
      (should (equal (drgnx-work-counts plan) '(:tasks (1 . 2) :steps (2 . 3) :todos (1 . 1) :commits 2))))))

(ert-deftest drgnx-work/commits-from-the-ledger-and-rulings ()
  (drgnx-work-test--with root
    (drgnx-work-test--scan root)
    (let* ((t1 (concat "task:" root "docs/plans/p.md#1"))
           (commits (drgnx-work-test--kids t1 'commit)))
      (should (equal (mapcar (lambda (n) (plist-get n :title)) commits) '("task one, more" "task one")))
      (should (seq-every-p (lambda (c) (eq (cdar (drgnx-work-edges-from (plist-get c :id) 'implements)) 'inferred)) commits))
      (should (equal (mapcar (lambda (n) (plist-get n :title)) (drgnx-work-test--kids t1 'ruling)) '("keep it small — why — cost"))))))

(ert-deftest drgnx-work/a-range-git-no-longer-has-is-stale-never-wrong ()
  (drgnx-work-test--with root
    (drgnx-work-test--write root "code/.superpowers/sdd/p/progress.md"
                            (format "# SDD ledger — plan: %sdocs/plans/p.md\nTask 1: complete (commits deadbee..cafef00, tests: ok)\nTask 2: complete (commit HEAD, tests: ok)\n" root))
    (drgnx-work-test--scan root)
    (let ((t1 (drgnx-work-node (concat "task:" root "docs/plans/p.md#1")))
          (t2 (drgnx-work-node (concat "task:" root "docs/plans/p.md#2"))))
      (should (equal (plist-get t1 :status) "done"))
      (should (plist-get t1 :stale))
      (should-not (drgnx-work-test--kids (plist-get t1 :id) 'commit))
      (should (equal (plist-get t2 :status) "done")))))

(ert-deftest drgnx-work/a-plan-shows-its-worktree-and-branch-then-merged ()
  (drgnx-work-test--with root
    (let ((wt (concat root "code/.claude/worktrees/p/")))
      (drgnx-work-test--git (concat root "code") "worktree" "add" "-q" wt "-b" "p")
      (drgnx-work-test--write root "code/.claude/worktrees/p/.superpowers/sdd/p/progress.md"
                              (format "# SDD ledger — plan: %sdocs/plans/p.md\n" root))
      (drgnx-work-test--commit wt "c" "3" "on the branch")
      (drgnx-work-test--scan root)
      (let ((plan (drgnx-work-node (concat "plan:" root "docs/plans/p.md"))))
        (should (equal (plist-get plan :branch) "p"))
        (should (equal (file-name-as-directory (plist-get plan :worktree)) wt))
        (should (equal (plist-get plan :merged) nil)))
      ;; the work done, merged into main, worktree removed
      (write-region "Task 2: complete (commit HEAD, tests: ok)\n" nil (concat root "code/.superpowers/sdd/p/progress.md") t 'silent)
      (drgnx-work-test--git (concat root "code") "merge" "-q" "--ff-only" "p")
      (drgnx-work-test--git (concat root "code") "worktree" "remove" "--force" wt)
      (drgnx-work-test--scan root)
      (should (plist-get (drgnx-work-node (concat "plan:" root "docs/plans/p.md")) :merged)))))

(ert-deftest drgnx-work/a-markdown-without-tasks-is-not-a-plan ()
  (drgnx-work-test--with root
    (drgnx-work-test--write root "docs/plans/notes.md" "# Just notes\n\nNo tasks here.\n")
    (drgnx-work-test--scan root)
    (should-not (drgnx-work-node (concat "plan:" root "docs/plans/notes.md")))))

(ert-deftest drgnx-work/plans-without-a-spec-and-specs-of-two-plans ()
  (drgnx-work-test--with root
    (drgnx-work-test--write root "docs/plans/q.md" "# Plan Q\n\n**Spec:** `docs/specs/s.md`\n\n### Task 1: Only\n")
    (drgnx-work-test--write root "docs/plans/r.md" "# Plan R (no spec)\n\n### Task 1: Alone\n")
    (drgnx-work-test--scan root)
    (should (= 2 (length (drgnx-work-test--kids (concat "spec:" root "docs/specs/s.md") 'plan))))
    (should (member (concat "plan:" root "docs/plans/r.md")
                    (mapcar (lambda (n) (plist-get n :id)) (drgnx-work-roots))))))

(ert-deftest drgnx-work/a-rescan-reads-only-what-changed-and-forgets-what-left ()
  (drgnx-work-test--with root
    (drgnx-work-test--scan root)
    (should (eql (plist-get (drgnx-work-test--scan root) :files) 0))     ; nothing changed
    (rename-file (concat root "docs/plans/p.md") (concat root "docs/plans/p2.md"))
    (let ((r (drgnx-work-test--scan root)))
      (should (> (plist-get r :files) 0)))
    (should-not (drgnx-work-node (concat "plan:" root "docs/plans/p.md")))
    (should (drgnx-work-node (concat "plan:" root "docs/plans/p2.md")))))

(ert-deftest drgnx-work/a-recorded-commit-survives-rescans ()
  (drgnx-work-test--with root
    (drgnx-work-test--scan root)
    (let ((t2 (concat "task:" root "docs/plans/p.md#2"))
          (sha (drgnx-work-test--commit (concat root "code") "z" "z" "recorded work")))
      (drgnx-work-record t2 (concat root "code") sha)
      (drgnx-work-test--write root "docs/plans/p.md"
                              "# Plan P\n\n**Spec:** `docs/specs/s.md`\n\n### Task 1: First\n### Task 2: Second, renamed\n")
      (drgnx-work-test--scan root)
      (let ((c (drgnx-work-test--kids t2 'commit)))
        (should (equal (mapcar (lambda (n) (plist-get n :title)) c) '("recorded work")))
        (should (eq (cdar (drgnx-work-edges-from (plist-get (car c) :id) 'implements)) 'recorded))))))

;;;; Found on this repository's own plans

(ert-deftest drgnx-work/a-single-commit-and-a-spec-in-a-sub-repository ()
  (drgnx-work-test--with root
    (drgnx-work-test--write root "code/docs/roadmap.md" "# Roadmap\n")
    (drgnx-work-test--write root "docs/plans/x/q.md" "# Plan Q\n\n**Spec:** `docs/roadmap.md` (row Q)\n\n### Task 1: One\n")
    (let ((sha (drgnx-work-test--commit (concat root "code") "q" "q" "the q work")))
      (drgnx-work-test--write root "docs/plans/x/q.ledger.md"
                              (format "# SDD ledger — plan: %sdocs/plans/x/q.md\nTask 1: complete (commit %s, tests: ok)\n" root sha))
      (drgnx-work-test--scan root)
      (should (equal (mapcar (lambda (n) (plist-get n :id)) (drgnx-work-test--kids (concat "spec:" root "code/docs/roadmap.md") 'plan))
                     (list (concat "plan:" root "docs/plans/x/q.md"))))
      (should (equal (mapcar (lambda (n) (plist-get n :title)) (drgnx-work-test--kids (concat "task:" root "docs/plans/x/q.md#1") 'commit))
                     '("the q work"))))))

(ert-deftest drgnx-work/an-empty-branch-of-work-in-progress-is-not-merged ()
  (drgnx-work-test--with root
    (let ((wt (concat root "code/.claude/worktrees/p/")))
      (drgnx-work-test--git (concat root "code") "worktree" "add" "-q" wt "-b" "p")
      (drgnx-work-test--write root "code/.claude/worktrees/p/.superpowers/sdd/p/progress.md"
                              (format "# SDD ledger — plan: %sdocs/plans/p.md\n" root))
      (drgnx-work-test--scan root)                                    ; task 2 open, no commits on p yet
      (should-not (plist-get (drgnx-work-node (concat "plan:" root "docs/plans/p.md")) :merged)))))

(ert-deftest drgnx-work/steps-of-a-completed-task-count-as-done ()
  (drgnx-work-test--with root
    (drgnx-work-test--scan root)
    ;; task 1 is complete (ledger): its unticked step 2 counts as done
    (should (equal (plist-get (drgnx-work-counts (concat "plan:" root "docs/plans/p.md")) :steps) '(2 . 3)))))

;;; work-test.el ends here

;;;; Final review fixes

(defun drgnx-work-test--titles (id) (mapcar (lambda (n) (plist-get n :title)) (drgnx-work-test--kids id 'commit)))

(ert-deftest drgnx-work/a-ledger-never-downgrades-a-recorded-link ()
  (drgnx-work-test--with root
    (drgnx-work-test--scan root)
    (let* ((t1 (concat "task:" root "docs/plans/p.md#1")) (ledger (concat root "code/.superpowers/sdd/p/progress.md"))
           (c2 (drgnx-work-test--git code "rev-parse" "HEAD")))
      (drgnx-work-record t1 code c2)                                   ; recorded, and in the ledger's range
      (drgnx-work-test--write root "code/.superpowers/sdd/p/progress.md" (concat (drgnx-work--text ledger) "\n"))
      (drgnx-work-test--scan root)
      (should (eq (alist-get (concat "commit:" c2) (drgnx-work-edges-to t1 'implements) nil nil #'equal) 'recorded))
      (delete-file ledger)
      (drgnx-work-test--scan root)
      (should (equal (drgnx-work-test--titles t1) '("task one, more"))))))

(ert-deftest drgnx-work/a-commit-two-ledgers-name-stays-when-either-goes ()
  (dolist (gone '("code/.superpowers/sdd/p/progress.md" "docs/plans/p.ledger.md"))
    (drgnx-work-test--with root
      (drgnx-work-test--write root "docs/plans/p.ledger.md" (drgnx-work--text (concat root "code/.superpowers/sdd/p/progress.md")))
      (drgnx-work-test--scan root)
      (delete-file (concat root gone))
      (drgnx-work-test--scan root)
      (should (equal (drgnx-work-test--titles (concat "task:" root "docs/plans/p.md#1")) '("task one, more" "task one"))))))

(ert-deftest drgnx-work/rewritten-commits-turn-stale-on-the-next-scan ()
  (drgnx-work-test--with root
    (drgnx-work-test--scan root)
    (let ((t1 (concat "task:" root "docs/plans/p.md#1")))
      (should-not (plist-get (drgnx-work-node t1) :stale))
      (drgnx-work-test--git code "reset" "-q" "--hard" "HEAD~2")      ; the task's commits on no branch now
      (drgnx-work-test--scan root)                                      ; no file changed
      (should (plist-get (drgnx-work-node t1) :stale))
      (should (seq-every-p (lambda (c) (plist-get c :gone)) (drgnx-work-test--kids t1 'commit)))
      (drgnx-work-test--git code "reset" "-q" "--hard" "HEAD@{1}")     ; back on the branch: not stale
      (drgnx-work-test--scan root)
      (should-not (plist-get (drgnx-work-node t1) :stale)))))

(ert-deftest drgnx-work/a-removed-worktree-re-reads-its-plan-and-keeps-recorded-commits ()
  (drgnx-work-test--with root
    (let ((wt (concat root "code/.claude/worktrees/p/")) (t2 (concat "task:" root "docs/plans/p.md#2")))
      (drgnx-work-test--git code "worktree" "add" "-q" wt "-b" "p")
      (let ((sha (drgnx-work-test--commit wt "c" "3" "on the branch")))
        (drgnx-work-test--write root "code/.claude/worktrees/p/.superpowers/sdd/p/progress.md"
                                (format "# SDD ledger — plan: %sdocs/plans/p.md\nTask 2: complete (commit %s, tests: ok)\n" root sha))
        (drgnx-work-test--scan root)
        (should (equal (plist-get (drgnx-work-node t2) :status) "done"))
        (drgnx-work-record t2 wt sha)
        (drgnx-work-test--git code "merge" "-q" "--ff-only" "p")
        (drgnx-work-test--git code "worktree" "remove" "--force" wt)
        (drgnx-work-test--scan root)
        (should (equal (plist-get (drgnx-work-node t2) :status) "open"))   ; the ledger went with its worktree
        (let ((c (car (drgnx-work-test--kids t2 'commit))))
          (should (equal (plist-get c :title) "on the branch"))               ; the recorded link stays
          (should (equal (file-name-as-directory (plist-get c :repo)) code)))))))   ; in the repository, not the worktree

(ert-deftest drgnx-work/a-plan-whose-spec-is-deleted-becomes-a-root ()
  (drgnx-work-test--with root
    (drgnx-work-test--scan root)
    (delete-file (concat root "docs/specs/s.md"))
    (drgnx-work-test--scan root)
    (should (member (concat "plan:" root "docs/plans/p.md") (mapcar (lambda (n) (plist-get n :id)) (drgnx-work-roots))))))

(ert-deftest drgnx-work/a-file-changed-while-it-is-read-is-read-again ()
  (drgnx-work-test--with root
    (let* ((plan (concat root "docs/plans/p.md")) (orig (symbol-function 'drgnx-work--parse-plan)) (once t))
      (cl-letf (((symbol-function 'drgnx-work--parse-plan)
                 (lambda (file roots)
                   (prog1 (funcall orig file roots)
                     (when (and once (equal file plan))           ; an agent writes the plan during the scan
                       (setq once nil)
                       (write-region "# Plan P2\n\n### Task 1: First\n" nil plan nil 'silent)
                       (set-file-times plan (time-add (current-time) 5)))))))
        (drgnx-work-test--scan root))
      (drgnx-work-test--scan root)
      (should (equal (plist-get (drgnx-work-node (concat "plan:" plan)) :title) "Plan P2")))))

(ert-deftest drgnx-work/a-linked-worktree-inside-a-root-gives-only-its-ledgers ()
  (drgnx-work-test--with root
    (make-directory (concat code "docs/plans") t)
    (drgnx-work-test--commit code "docs/plans/q.md" "# Plan Q\n\n### Task 1: one\n" "a committed plan")
    (drgnx-work-test--git code "worktree" "add" "-q" (concat code ".claude/worktrees/w") "-b" "w")
    (drgnx-work-test--scan root)
    (let ((paths (mapcar (lambda (n) (plist-get n :path)) (drgnx-work-nodes 'plan))))
      (should (member (concat code "docs/plans/q.md") paths))
      (should-not (seq-find (lambda (p) (string-search "/.claude/worktrees/" p)) paths)))))

(ert-deftest drgnx-work/commits-recorded-for-a-plan-or-a-todo-are-counted ()
  (drgnx-work-test--with root
    (drgnx-work-test--scan root)
    (let* ((plan (concat "plan:" root "docs/plans/p.md"))
           (todo (plist-get (car (drgnx-work-test--kids plan 'todo)) :id))
           (before (plist-get (drgnx-work-counts plan) :commits)))
      (drgnx-work-record plan code (drgnx-work-test--commit code "x" "x" "for the plan"))
      (drgnx-work-record todo code (drgnx-work-test--commit code "y" "y" "for the todo"))
      (should (= (plist-get (drgnx-work-counts plan) :commits) (+ before 2))))))

;;;; Deferred fixes

(ert-deftest drgnx-work/a-root-inside-a-specs-or-plans-directory-classifies-by-its-own-paths ()
  ;; only the path under the root counts: …/specs/ above it makes nothing a spec, …/plans/ nothing a plan
  (dolist (above '("specs/" "plans/"))
    (let* ((top (file-name-as-directory (make-temp-file "drgnx-work" t)))
           (root (concat top above "proj/"))
           (process-environment (cons (concat "DRGNX_DATA_DIR=" top "data") process-environment))
           (drgnx-work-db--handles nil))
      (unwind-protect
          (progn
            (drgnx-work-test--write root "README.md" "# Read me\n\n### Task 1: not a plan of the root\n")
            (drgnx-work-test--write root "docs/specs/s.md" "# The spec\n\n### Task 1: a spec, not a plan\n")
            (drgnx-work-scan (list root))
            (should-not (drgnx-work-node (concat "spec:" root "README.md")))
            (should-not (drgnx-work-node (concat "plan:" root "README.md")))
            (should (drgnx-work-node (concat "spec:" root "docs/specs/s.md")))
            (should-not (drgnx-work-node (concat "plan:" root "docs/specs/s.md"))))
        (drgnx-work-db-close-all)
        (delete-directory top t)))))

(ert-deftest drgnx-work/a-ledger-naming-its-plan-relative-to-the-root-feeds-it ()
  (drgnx-work-test--with root
    (drgnx-work-test--write root "docs/plans/p.ledger.md" "# SDD ledger — plan: docs/plans/p.md\nTask 2: complete (tests: ok)\n")
    (let ((default-directory temporary-file-directory)) (drgnx-work-test--scan root))   ; not the root
    (should (equal (plist-get (drgnx-work-node (concat "task:" root "docs/plans/p.md#2")) :status) "done"))))

(ert-deftest drgnx-work/a-board-todo-takes-the-root-of-the-project-it-is-under ()
  (drgnx-work-test--with root
    (let ((todo (lambda (id) (format "** TODO %s\n:PROPERTIES:\n:ONBOARD_ID: %s\n:PLAN_FILE: docs/plans/p.md\n:PLAN_TEXT: one\n:END:\n" id id))))
      (drgnx-work-test--write root "org/board.org"
                              (concat (format "* code\n:PROPERTIES:\n:PROJECT_ROOT: %s\n:END:\n" root)
                                      (format "** a sub-project\n:PROPERTIES:\n:PROJECT_ROOT: %selsewhere/\n:END:\n" root)
                                      (funcall todo "refiled")              ; under code, after the sub-project
                                      "* no root\n" (funcall todo "rootless")))
      (let ((default-directory root)) (drgnx-work-test--scan root))         ; the cwd is no root either
      (should (equal (mapcar (lambda (n) (plist-get n :title)) (drgnx-work-test--kids (concat "plan:" root "docs/plans/p.md") 'todo))
                     '("refiled"))))))

(ert-deftest drgnx-work/a-spec-outside-specs-is-read-again-and-goes-with-its-last-plan ()
  (drgnx-work-test--with root
    (let ((spec (concat "spec:" root "docs/roadmap.md")) (q (concat root "docs/plans/q.md")))
      (drgnx-work-test--write root "docs/roadmap.md" "# Roadmap\n")
      (drgnx-work-test--write root "docs/plans/q.md" "# Plan Q\n\n**Spec:** `docs/roadmap.md`\n\n### Task 1: One\n")
      (drgnx-work-test--scan root)
      (should (equal (plist-get (drgnx-work-node spec) :title) "Roadmap"))
      (drgnx-work-test--write root "docs/roadmap.md" "# Roadmap, renamed\n")
      (set-file-times (concat root "docs/roadmap.md") (time-add (current-time) 5))
      (drgnx-work-test--scan root)
      (should (equal (plist-get (drgnx-work-node spec) :title) "Roadmap, renamed"))
      ;; the plan names it no more: it goes
      (drgnx-work-test--write root "docs/plans/q.md" "# Plan Q\n\n### Task 1: One\n")
      (set-file-times q (time-add (current-time) 10))
      (drgnx-work-test--scan root)
      (should-not (drgnx-work-node spec))
      (should (drgnx-work-node (concat "spec:" root "docs/specs/s.md"))))))       ; one under specs/ stays

(ert-deftest drgnx-work/status-json-non-ascii-title ()
  "`drgnx work status --json' is valid UTF-8 JSON whatever the locale: the title comes out as it went in."
  (let* ((dir (make-temp-file "drgnx-work-db" t))
         (core (file-name-directory (locate-library "drgnx-work")))
         (title "Café → 計画")
         (process-environment (cons (concat "DRGNX_DATA_DIR=" dir) process-environment))
         (drgnx-work-db--handles nil))
    (unwind-protect
        (progn
          (drgnx-work-put-node "plan:a" :kind 'plan :title title :path "/a.md" :line 1 :status "open" :source "/a.md")
          (drgnx-work-db-close-all)
          (dolist (locale '("C" "C.UTF-8"))
            (let ((process-environment (append (list (concat "LC_ALL=" locale) (concat "LANG=" locale) "LANGUAGE=")
                                               process-environment))
                  (out (generate-new-buffer " *work-status*")))
              (unwind-protect
                  (progn
                    (let ((coding-system-for-read 'no-conversion))
                      (should (eql 0 (call-process (expand-file-name invocation-name invocation-directory) nil out nil
                                                   "--batch" "-Q" "-L" core "-l" "drgnx-work" "-f" "drgnx-work-cli" "--" "status" "--json"))))
                    (let* ((bytes (with-current-buffer out (string-to-unibyte (buffer-string))))
                           (text (decode-coding-string bytes 'utf-8))
                           (rows (json-parse-string text :object-type 'plist)))
                      (should (equal (encode-coding-string text 'utf-8) bytes)) ; valid UTF-8, not re-encoded
                      (should (equal (plist-get (aref rows 0) :title) title))))
                (kill-buffer out)))))
      (drgnx-work-db-close-all)
      (delete-directory dir t))))
