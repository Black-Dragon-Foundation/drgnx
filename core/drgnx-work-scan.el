;;; drgnx-work-scan.el --- The work tracker's scan: specs, plans, ledgers, the board, git -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Reads what agents and people already leave behind and fills the store (drgnx-work-db.el):
;; - plans: markdown under a plans/ directory with `### Task N:' headings; their spec from the
;;   `**Spec:**' line; each task's `- [ ]' / `- [x]' steps;
;; - specs: markdown under a specs/ directory, and every file a plan names;
;; - ledgers (`.superpowers/sdd/<plan>/progress.md', copied `*.ledger.md'): `Task N: complete
;;   (commits A..B …)' marks a task done and links the commits of that range (inferred; a range git
;;   no longer has marks the task stale, never wrong), `Ruling:' lines; a ledger inside a linked git
;;   worktree gives the plan its worktree and branch (kept after the worktree is gone);
;; - board TODOs with :PLAN_FILE: (onboarding's import).
;; Files are read again only when their modification time changed; git facts (worktrees, merged
;; branches) are looked at on every scan.  See docs/guide/work.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-work-db)

(defconst drgnx-work-scan-skip '(".git" "node_modules" "eln-cache" "elpa" "target" "dist" "build")
  "Directory names the scan never enters (dot directories are entered: ledgers live in .superpowers).")

(defun drgnx-work--git (dir &rest args)
  "git ARGS in DIR: its output (trimmed) or nil."
  (when (file-directory-p dir)
    (with-temp-buffer
      (let ((default-directory (file-name-as-directory dir)))
        (when (eql 0 (apply #'call-process "git" nil t nil args)) (string-trim (buffer-string)))))))

;;;; Finding files

(defun drgnx-work--walk (root depth fn &optional ledgers-only)
  "Call FN on every regular file under ROOT, at most DEPTH levels down, with LEDGERS-ONLY: inside a
linked git worktree (its .git a file) only its ledgers count — its plans and specs are copies."
  (dolist (f (ignore-errors (directory-files root t "\\`[^.]\\|\\`\\.[^.]")))
    (let ((name (file-name-nondirectory f)))
      (cond ((file-symlink-p f) nil)
            ((file-directory-p f)
             (when (and (> depth 0) (not (member name drgnx-work-scan-skip))
                        (not (and (equal name "tmp") (string-suffix-p "/.claude" (directory-file-name root)))))
               (drgnx-work--walk f (1- depth) fn (or ledgers-only (file-regular-p (expand-file-name ".git" f))))))
            (t (funcall fn f ledgers-only))))))

(defun drgnx-work--classify (file)
  "`plan', `spec', `ledger' or nil for FILE."
  (let ((parts (split-string file "/" t)))
    (cond ((string-suffix-p ".ledger.md" file) 'ledger)
          ((and (equal (file-name-nondirectory file) "progress.md") (member "sdd" parts) (member ".superpowers" parts)) 'ledger)
          ((not (string-suffix-p ".md" file)) nil)
          ((member "plans" parts) 'plan)
          ((member "specs" parts) 'spec))))

(defun drgnx-work--text (file) (with-temp-buffer (insert-file-contents file) (buffer-string)))

;;;; Specs and plans

(defun drgnx-work--title (text fallback)
  (if (string-match "^# \\(.+\\)$" text) (string-trim (match-string 1 text)) fallback))

(defun drgnx-work--spec-source (file) (concat "spec " file))

(defun drgnx-work--parse-spec (file)
  "The node of spec FILE (its own source: a spec under plans/ is also scanned as a plan candidate)."
  (drgnx-work-put-node (concat "spec:" file) :kind 'spec :title (drgnx-work--title (drgnx-work--text file) (file-name-base file))
                       :path file :line 1 :source (drgnx-work--spec-source file)))

(defun drgnx-work--resolve (name file roots)
  "The file NAME (a `**Spec:**' reference) means, seen from FILE under ROOTS (or a repository in
them), or nil."
  (seq-find #'file-regular-p
            (mapcar (lambda (d) (expand-file-name name d))
                    (append (list (file-name-directory file)) roots (drgnx-work--repos roots)
                            ;; a plan in docs/plans/x/ naming docs/… relative to its repository root
                            (let ((top (locate-dominating-file file "docs"))) (and top (list top)))))))

(defun drgnx-work--parse-plan (file roots)
  "Nodes of plan FILE: the plan, its tasks, their steps; its spec (and the edge to it)."
  (let* ((text (drgnx-work--text file)) (plan (concat "plan:" file)))
    (when (string-match-p "^### Task [0-9]" text)     ; a markdown without tasks is not a plan
      (drgnx-work-put-node plan :kind 'plan :title (drgnx-work--title text (file-name-base file)) :path file :line 1
                           :status "open" :source file)
      (when (string-match "^\\*\\*Spec:\\*\\* *`\\([^`]+\\)`" text)
        (when-let* ((spec (drgnx-work--resolve (match-string 1 text) file roots)))
          (unless (drgnx-work-node (concat "spec:" spec)) (drgnx-work--parse-spec spec))
          (drgnx-work-put-edge plan (concat "spec:" spec) 'derives 'parsed file)))
      (with-temp-buffer
        (insert text)
        (goto-char (point-min))
        (let (task)
          (while (not (eobp))
            (cond
             ((looking-at "^### Task \\([0-9]+\\)[:.]? *\\(.*\\)$")
              (setq task (list (concat "task:" file "#" (match-string 1)) (string-to-number (match-string 1)) 0))
              (drgnx-work-put-node (car task) :kind 'task :title (string-trim (match-string 2)) :path file
                                   :line (line-number-at-pos) :status "open" :parent plan :ord (cadr task) :source file))
             ((looking-at "^##\\{1,2\\} ") (setq task nil))
             ((and task (looking-at "^[ \t]*[-*] \\[\\([ xX]\\)\\] \\(.+\\)$"))
              (setf (nth 2 task) (1+ (nth 2 task)))
              (drgnx-work-put-node (format "step:%s#%d.%d" file (cadr task) (nth 2 task)) :kind 'step
                                   :title (string-trim (replace-regexp-in-string "\\*\\*" "" (match-string 2)))
                                   :path file :line (line-number-at-pos)
                                   :status (if (equal (match-string 1) " ") "open" "done")
                                   :parent (car task) :ord (nth 2 task) :source file)))
            (forward-line 1))))
      ;; a task whose steps are all done is done
      (dolist (tk (drgnx-work-children plan))
        (when (eq (plist-get tk :kind) 'task)
          (let ((steps (seq-filter (lambda (n) (eq (plist-get n :kind) 'step)) (drgnx-work-children (plist-get tk :id)))))
            (when (and steps (seq-every-p (lambda (s) (equal (plist-get s :status) "done")) steps))
              (drgnx-work-update-node (plist-get tk :id) :status "done")))))
      plan)))

;;;; Ledgers and commits

(defun drgnx-work--repos (roots)
  "Git repositories under ROOTS (the roots themselves and their direct subdirectories)."
  (delete-dups
   (seq-filter (lambda (d) (file-exists-p (expand-file-name ".git" d)))
               (seq-mapcat (lambda (r) (cons (file-name-as-directory r)
                                             (seq-filter #'file-directory-p (mapcar #'file-name-as-directory (ignore-errors (directory-files r t "\\`[^.]"))))))
                           roots))))

(defun drgnx-work--main-repo (dir)
  "The repository DIR belongs to — its main checkout, never a linked worktree (which may go) — or nil."
  (when-let* ((common (drgnx-work--git dir "rev-parse" "--path-format=absolute" "--git-common-dir")))
    (file-name-as-directory (if (equal (file-name-nondirectory (directory-file-name common)) ".git")
                                (file-name-directory (directory-file-name common))
                              common))))

(defun drgnx-work--log (repo &rest args)
  "The commits `git log ARGS' lists in REPO, newest first: ((SHA DATE SUBJECT)…)."
  (mapcar (lambda (l) (let ((p (split-string l "\t"))) (list (car p) (string-to-number (nth 1 p)) (or (nth 2 p) ""))))
          (split-string (or (apply #'drgnx-work--git repo "log" "--format=%H%x09%ct%x09%s" args) "") "\n" t)))

(defun drgnx-work--put-commits (repo infos)
  "Nodes of the commits INFOS (`drgnx-work--log', newest first) of REPO; their ids.  A commit belongs
to no file (several ledgers may name it; `drgnx-work-forget-orphan-commits' forgets the unlinked);
its place: older commits have fewer ancestors (dates tie within a second) — one count for them all."
  (let ((depth (and infos (string-to-number (or (drgnx-work--git repo "rev-list" "--count" (caar infos)) "0")))))
    (seq-map-indexed (lambda (c i)
                       (let ((id (concat "commit:" (car c))))
                         (drgnx-work-put-node id :kind 'commit :title (nth 2 c) :path repo :source "commit"
                                              :sha (car c) :date (nth 1 c) :repo repo :seq (- i depth))
                         id))
                     infos)))

(defun drgnx-work--range (repos a b)
  "The commits of A..B in the first of REPOS that has both: (REPO . INFOS), or nil."
  (seq-some (lambda (repo)
              (when (and (drgnx-work--git repo "cat-file" "-e" (concat a "^{commit}"))
                         (drgnx-work--git repo "cat-file" "-e" (concat b "^{commit}")))
                (cons repo (drgnx-work--log repo (concat a ".." b)))))
            repos))

(defun drgnx-work--one (repos sha)
  "(REPO . INFOS) for the first of REPOS that has commit SHA, or nil."
  (seq-some (lambda (repo) (when (drgnx-work--git repo "cat-file" "-e" (concat sha "^{commit}"))
                             (cons repo (drgnx-work--log repo "-1" sha))))
            repos))

(defun drgnx-work--worktree-of (file)
  "(TOP . BRANCH) when FILE is inside a linked git worktree, else nil."
  (let* ((dir (file-name-directory file))
         (git-dir (drgnx-work--git dir "rev-parse" "--absolute-git-dir"))
         (common (drgnx-work--git dir "rev-parse" "--path-format=absolute" "--git-common-dir")))
    (when (and git-dir common (not (equal (file-truename git-dir) (file-truename common))))
      (cons (file-name-as-directory (drgnx-work--git dir "rev-parse" "--show-toplevel"))
            (drgnx-work--git dir "rev-parse" "--abbrev-ref" "HEAD")))))

(defun drgnx-work--parse-ledger (file repos)
  "Statuses, commits, rulings and the worktree/branch a ledger FILE gives its plan."
  (let* ((text (drgnx-work--text file))
         (plan-file (and (string-match "\\`# SDD ledger — plan: \\(.+\\)$" text) (string-trim (match-string 1 text))))
         (plan (and plan-file (concat "plan:" (expand-file-name plan-file)))))
    (when (and plan (drgnx-work-node plan))
      ;; which plan it feeds: when the ledger goes (its worktree removed), the plan is read again
      (drgnx-work-put-edge file plan 'ledger-of 'parsed file)
      (let ((pf (expand-file-name plan-file)) (n 0))
        (dolist (line (split-string text "\n"))
          (setq n (1+ n))
          (cond
           ((string-match "\\`Task \\([0-9]+\\)\\(?:-\\([0-9]+\\)\\)?: complete (\\(.*\\)" line)
            (let* ((from (string-to-number (match-string 1 line)))
                   (to (if (match-string 2 line) (string-to-number (match-string 2 line)) from))
                   (rest (match-string 3 line))
                   (range (cond ((string-match "commits? \\([0-9a-f]\\{4,40\\}\\)\\.\\.\\([0-9a-f]\\{4,40\\}\\)" rest)
                                 (cons (match-string 1 rest) (match-string 2 rest)))
                                ((string-match "\\`commits? \\([0-9a-f]\\{7,40\\}\\)\\b" rest)   ; one commit
                                 (cons nil (match-string 1 rest)))))
                   (found (and range (if (car range) (drgnx-work--range repos (car range) (cdr range))
                                       (drgnx-work--one repos (cdr range))))))
              (cl-loop for k from from to to
                       for task = (format "task:%s#%d" pf k)
                       when (drgnx-work-node task)
                       do (drgnx-work-update-node task :status "done" :range-stale (and range (not found) t))
                       (when (and found (= k from))
                         (dolist (c (drgnx-work--put-commits (drgnx-work--main-repo (car found)) (cdr found)))
                           (drgnx-work-put-edge c task 'implements 'inferred file))))))
           ((string-match "\\`\\(?:Task \\([0-9]+\\)[^:]*: \\)?Ruling: \\(.*\\)" line)
            (let ((task (and (match-string 1 line) (format "task:%s#%s" pf (match-string 1 line)))))
              (drgnx-work-put-node (format "ruling:%s#%d" file n) :kind 'ruling :title (string-trim (match-string 2 line))
                                   :path file :line n :parent (if (and task (drgnx-work-node task)) task plan) :ord n :source file)))))
        (when-let* ((wt (drgnx-work--worktree-of file)))
          (let ((branch (format "branch:%s:%s" (drgnx-work--git (car wt) "rev-parse" "--path-format=absolute" "--git-common-dir") (cdr wt))))
            (drgnx-work-put-node branch :kind 'branch :title (cdr wt) :path (car wt) :source "branch"
                                 :repo (car wt) :name (cdr wt))
            (drgnx-work-put-edge plan branch 'on-branch 'inferred "branch")))))))

(defun drgnx-work--git-facts (plan)
  "Refresh PLAN's worktree, branch and merged state from git."
  (when-let* ((b (car (car (drgnx-work-edges-from plan 'on-branch)))) (bn (drgnx-work-node b)))
    (let* ((common (and (string-match "\\`branch:\\(.*\\):[^:]+\\'" b) (match-string 1 b)))
           (repo (and common (file-name-directory (directory-file-name common))))
           (name (plist-get bn :name))
           (wt (plist-get bn :repo))
           (main (and repo (seq-find (lambda (m) (drgnx-work--git repo "rev-parse" "--verify" "-q" m)) '("main" "master"))))
           (exists (and repo (drgnx-work--git repo "rev-parse" "--verify" "-q" (concat "refs/heads/" name))))
           (tasks (seq-filter (lambda (n) (eq (plist-get n :kind) 'task)) (drgnx-work-children plan)))
           (done (and tasks (seq-every-p (lambda (n) (equal (plist-get n :status) "done")) tasks)))
           ;; merged: the work is done and its branch is in main (an empty new branch is trivially "in" it)
           (merged (and repo main done
                        (if exists (and (drgnx-work--git repo "merge-base" "--is-ancestor" name main) t)
                          t))))
      (drgnx-work-update-node plan :branch name :worktree (and wt (file-directory-p wt) wt) :merged merged :repo repo))))

;;;; The board

(defun drgnx-work--parse-board (board)
  "TODOs of the org BOARD that came from a plan (:PLAN_FILE:): nodes under the plan."
  (with-temp-buffer
    (insert-file-contents board)
    (goto-char (point-min))
    (let (root)
      (while (re-search-forward "^\\(\\*+\\) \\(?:\\(TODO\\|DONE\\|NEXT\\|WAIT\\|REVIEW\\) \\)?\\(.*\\)$" nil t)
        (let* ((state (match-string 2)) (title (match-string 3)) (hpos (match-beginning 0)) (line (line-number-at-pos))
               (end (save-excursion (forward-line 1) (if (re-search-forward "^\\*+ " nil t) (line-beginning-position) (point-max))))
               (prop (lambda (name) (save-excursion (goto-char hpos)
                                                    (when (re-search-forward (format "^[ \t]*:%s:[ \t]*\\(.+?\\)[ \t]*$" name) end t)
                                                      (match-string 1))))))
          (when-let* ((r (funcall prop "PROJECT_ROOT"))) (setq root r))
          (when-let* ((pf (funcall prop "PLAN_FILE")))
            (let ((plan (concat "plan:" (expand-file-name pf (or root default-directory)))))
              (when (drgnx-work-node plan)
                (drgnx-work-put-node (format "todo:%s#%s" board (or (funcall prop "ONBOARD_ID") line)) :kind 'todo
                                     :title (string-trim title) :path board :line line
                                     :status (if (equal state "DONE") "done" "open") :parent plan :ord line :source board)))))))))

;;;; The scan

(cl-defun drgnx-work-scan (roots &key board)
  "Bring the store up to date with ROOTS (directories) and BOARD (an org file).  Returns (:files N)
— how many files were read again."
  (let* ((roots (mapcar (lambda (r) (file-name-as-directory (expand-file-name r))) roots))
         (repos (drgnx-work--repos roots))
         (found (make-hash-table :test #'equal)) (seen (make-hash-table :test #'equal))
         plans specs ledgers changed reread)
    (dolist (r roots)
      (drgnx-work--walk r 7 (lambda (f ledgers-only)
                              (when-let* ((k (drgnx-work--classify f)) ((or (not ledgers-only) (eq k 'ledger))))
                                (puthash f k found)
                                (pcase k ('plan (push f plans)) ('spec (push f specs)) ('ledger (push f ledgers)))))))
    (when (and board (file-readable-p board)) (puthash board 'board found))
    ;; what changed, what left; the time seen now is the one kept (a file written while it is read
    ;; is read again next time)
    (maphash (lambda (f _) (let ((m (float-time (file-attribute-modification-time (file-attributes f)))))
                             (puthash f m seen)
                             (unless (equal (drgnx-work-file-mtime f) m) (push f changed))))
             found)
    (dolist (f (drgnx-work-files))
      (unless (gethash f found)
        ;; a ledger gone (its worktree removed): its plan is read again from what is left
        (dolist (e (drgnx-work-edges-from f 'ledger-of))
          (when-let* ((p (drgnx-work-node (car e)))) (push (plist-get p :path) reread)))
        (drgnx-work-forget-source f) (drgnx-work-forget-source (drgnx-work--spec-source f))
        (drgnx-work-drop-file f) (push f changed)))
    (when changed
      ;; plans and their ledgers are read together (a ledger changes its plan's tasks)
      (dolist (f specs) (when (member f changed) (drgnx-work-forget-source (drgnx-work--spec-source f)) (drgnx-work--parse-spec f)))
      ;; a spec a plan names, outside specs/, read again when it changed
      (dolist (s (drgnx-work-nodes 'spec))
        (let ((f (plist-get s :path)))
          (when (and (member f changed) (not (member f specs)) (file-readable-p f))
            (drgnx-work-forget-source (drgnx-work--spec-source f)) (drgnx-work--parse-spec f))))
      (let ((ledger-plan (mapcar (lambda (l) (cons l (and (string-match "\\`# SDD ledger — plan: \\(.+\\)$" (drgnx-work--text l))
                                                          (expand-file-name (string-trim (match-string 1 (drgnx-work--text l)))))))
                                 ledgers)))
        (dolist (p plans)
          (when (or (member p changed) (member p reread)
                    (seq-find (lambda (lp) (and (equal (cdr lp) p) (member (car lp) changed))) ledger-plan))
            (drgnx-work-forget-source p)
            (drgnx-work--parse-plan p roots)
            (dolist (lp ledger-plan)
              (when (equal (cdr lp) p) (drgnx-work-forget-source (car lp)) (drgnx-work--parse-ledger (car lp) repos)))))
        (when (and board (file-readable-p board) (or (member board changed) (seq-intersection changed plans)))
          (drgnx-work-forget-source board)
          (drgnx-work--parse-board board))))
    (dolist (f changed) (when (gethash f found) (drgnx-work-set-file f (gethash f seen))))
    (drgnx-work-forget-orphan-commits)
    (dolist (p (drgnx-work-nodes 'plan)) (drgnx-work--git-facts (plist-get p :id)))
    (drgnx-work--check-commits)
    (list :files (length (seq-filter (lambda (f) (gethash f found)) changed)))))

(defun drgnx-work--check-commits ()
  "Mark the commits no branch, tag or HEAD reaches any more (rebased, squashed, amended, pruned) as
gone, and their tasks stale — every scan, whatever changed.  Two git calls per repository."
  (let ((by-repo (seq-group-by (lambda (c) (plist-get c :repo)) (drgnx-work-nodes 'commit))) gone)
    (pcase-dolist (`(,repo . ,commits) by-repo)
      (when (and repo (file-directory-p repo))
        (let* ((shas (mapcar (lambda (c) (plist-get c :sha)) commits))
               (missing (with-temp-buffer
                          (insert (string-join shas "\n") "\n")
                          (let ((default-directory repo))
                            (call-process-region (point-min) (point-max) "git" t t nil "cat-file" "--batch-check"))
                          (mapcar #'car (seq-filter (lambda (p) (equal (cadr p) "missing"))
                                                    (mapcar #'split-string (split-string (buffer-string) "\n" t))))))
               (present (seq-difference shas missing))
               (unreachable (and present (split-string (or (apply #'drgnx-work--git repo "rev-list" (append present '("--not" "--all"))) "")
                                                       "\n" t))))
          (dolist (c commits)
            (let ((g (and (or (member (plist-get c :sha) missing) (member (plist-get c :sha) unreachable)) t)))
              (when g (push (plist-get c :id) gone))
              (unless (eq g (plist-get c :gone)) (drgnx-work-update-node (plist-get c :id) :gone g)))))))
    (dolist (tk (drgnx-work-nodes 'task))
      (let ((s (and (or (plist-get tk :range-stale)
                        (seq-some (lambda (e) (member (car e) gone)) (drgnx-work-edges-to (plist-get tk :id) 'implements)))
                    t)))
        (unless (eq s (plist-get tk :stale)) (drgnx-work-update-node (plist-get tk :id) :stale s))))))

;;;; Counts and recorded links

(defun drgnx-work-counts (plan)
  "(:tasks (DONE . ALL) :steps (DONE . ALL) :todos (DONE . ALL) :commits N) of PLAN."
  (let* ((kids (drgnx-work-children plan))
         (tasks (seq-filter (lambda (n) (eq (plist-get n :kind) 'task)) kids))
         (todos (seq-filter (lambda (n) (eq (plist-get n :kind) 'todo)) kids))
         (task-kids (seq-mapcat (lambda (tk) (drgnx-work-children (plist-get tk :id))) tasks))
         (done-tasks (mapcar (lambda (tk) (plist-get tk :id)) (seq-filter (lambda (n) (equal (plist-get n :status) "done")) tasks)))
         ;; a step is done when ticked, or when its task is complete (ledgers rarely tick the plan)
         (steps (mapcar (lambda (n) (if (member (plist-get n :parent) done-tasks) (plist-put (copy-sequence n) :status "done") n))
                        (seq-filter (lambda (n) (eq (plist-get n :kind) 'step)) task-kids)))
         ;; the commits of its tasks, its TODOs and the plan itself
         (commits (delete-dups (mapcar (lambda (n) (plist-get n :id))
                                       (seq-filter (lambda (n) (eq (plist-get n :kind) 'commit))
                                                   (append kids task-kids (seq-mapcat (lambda (td) (drgnx-work-children (plist-get td :id))) todos))))))
         (done (lambda (l) (cons (seq-count (lambda (n) (equal (plist-get n :status) "done")) l) (length l)))))
    (list :tasks (funcall done tasks) :steps (funcall done steps) :todos (funcall done todos) :commits (length commits))))

(defun drgnx-work-record-commits (task repo infos)
  "Record that the commits INFOS (`drgnx-work--log', newest first) of REPO did TASK (a node id) — kept
across every rescan; in one transaction.  Their ids."
  (let ((repo (or (drgnx-work--main-repo repo) repo)))
    (with-sqlite-transaction (drgnx-work-db)
      (let ((ids (drgnx-work--put-commits repo infos)))
        (dolist (id ids) (drgnx-work-put-edge id task 'implements 'recorded "recorded"))
        ids))))

(defun drgnx-work-record (task repo sha)
  "Record that commit SHA of REPO did TASK (a node id); its node id, or nil when REPO has no SHA."
  (car (drgnx-work-record-commits task repo (drgnx-work--log repo "-1" sha))))

(provide 'drgnx-work-scan)
;;; drgnx-work-scan.el ends here
