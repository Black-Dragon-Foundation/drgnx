;;; drgnx-work-scan.el --- The work tracker's scan: specs, plans, ledgers, the board, git -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Reads what agents and people already leave behind and sends it to the hub, which fills the store (the editor
;; never writes work.db: one `graph/put-parsed' per scan, `graph/record' for commits; see `drgnx-work-scan'):
;; - plans: markdown under a plans/ directory with `### Task N:' headings; their spec from the
;;   `**Spec:**' line; each task's `- [ ]' / `- [x]' steps;
;; - specs: markdown under a specs/ directory, and every file a plan names (kept while one names it);
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
(require 'drgnx-projects)                 ; the board's projects
(require 'drgnx-deny)                     ; the personal-notes deny-list
(require 'drgnx-hub-client)               ; `drgnx-hub-call-sync'

(defconst drgnx-work-scan-skip '(".git" "node_modules" "eln-cache" "elpa" "target" "dist" "build")
  "Directory names the scan never enters (dot directories are entered: ledgers live in .superpowers).")

;;;; What this scan found
;; The parse fills these (nothing is written while it runs).  Reads of what the parse just made go to them first, then
;; to the read-only database, except rows of a source this scan reads again (the scan sends the whole source).

(defvar drgnx-work-scan--nodes nil "Hash id → the node as the scan sees it now (derived attributes applied).")
(defvar drgnx-work-scan--base nil "Hash id → the node as the parse made it: what is sent as an entity.")
(defvar drgnx-work-scan--order nil "The ids parsed, newest first.")
(defvar drgnx-work-scan--edges nil "The links parsed, newest first: (SRC DST KIND ORIGIN SOURCE).")
(defvar drgnx-work-scan--resent nil "Hash source text → t: the file and spec sources this scan reads again.")
(defvar drgnx-work-scan--gone nil "Hash source text → (:kind K :path P): the sources that are gone.")
(defvar drgnx-work-scan--patched nil "Hash id → a stored node with the derived attributes applied.")
(defvar drgnx-work-scan--updates nil "Hash id → (:status S :patch PLIST): the derived attributes that differ from the store.")

(defun drgnx-work-scan--put (id &rest props)
  "Parse node ID with PROPS (as `drgnx-work-node' answers them: :kind :title :path :line :status :parent :ord :source…)."
  (let ((n (append (list :id id) props)))
    (unless (gethash id drgnx-work-scan--base) (push id drgnx-work-scan--order))
    (puthash id (copy-sequence n) drgnx-work-scan--base)
    (puthash id n drgnx-work-scan--nodes)
    id))

(defun drgnx-work-scan--edge (src dst kind origin source)
  (cl-pushnew (list src dst kind origin source) drgnx-work-scan--edges :test #'equal))

(defun drgnx-work-scan--hidden-p (source)
  "Whether the stored rows of SOURCE are replaced by this scan."
  (and source (gethash source drgnx-work-scan--resent) t))

(defun drgnx-work-scan--node (id)
  "Node ID as the scan sees it: parsed now, else stored (and not replaced)."
  (or (gethash id drgnx-work-scan--nodes)
      (gethash id drgnx-work-scan--patched)
      (let ((n (drgnx-work-node id)))
        (and n (not (drgnx-work-scan--hidden-p (plist-get n :source))) n))))

(defun drgnx-work-scan--nodes-of (kind)
  "The nodes of KIND as the scan sees them."
  (let (out)
    (maphash (lambda (_ n) (when (eq (plist-get n :kind) kind) (push n out))) drgnx-work-scan--nodes)
    (dolist (n (drgnx-work-nodes kind))
      (unless (or (gethash (plist-get n :id) drgnx-work-scan--nodes) (drgnx-work-scan--hidden-p (plist-get n :source)))
        (push (or (gethash (plist-get n :id) drgnx-work-scan--patched) n) out)))
    out))

(defun drgnx-work-scan--links (id kind column)
  "((OTHER . ORIGIN)…) of the KIND links whose COLUMN end (\"src\" or \"dst\") is ID, parsed now or stored (and not
replaced), by OTHER (the other end).  The two selects are literal, so the schema-7 view check reads them."
  (let (out)
    (dolist (e drgnx-work-scan--edges)
      (when (and (equal (nth (if (equal column "src") 0 1) e) id) (eq (nth 2 e) kind))
        (push (cons (nth (if (equal column "src") 1 0) e) (nth 3 e)) out)))
    (dolist (r (sqlite-select (drgnx-work-db-read)
                              (if (equal column "src")
                                  "select dst, origin, source from edge where src = ? and kind = ?"
                                "select src, origin, source from edge where dst = ? and kind = ?")
                              (list id (symbol-name kind))))
      (unless (or (drgnx-work-scan--hidden-p (nth 2 r)) (assoc (car r) out))
        (push (cons (car r) (intern (nth 1 r))) out)))
    (sort out (lambda (a b) (string< (car a) (car b))))))

(defun drgnx-work-scan--edges-from (src kind) (drgnx-work-scan--links src kind "src"))
(defun drgnx-work-scan--edges-to (dst kind) (drgnx-work-scan--links dst kind "dst"))

(defun drgnx-work-scan--flag (v) (and v (not (eq v :false)) v))

(defun drgnx-work-scan--update (id &rest props)
  "Derive PROPS (:status, or a flag or text of the data) for node ID: what differs from what the node holds is
applied to the node as the scan sees it, and remembered to be sent with the request."
  (when-let* ((n (drgnx-work-scan--node id)))
    (let ((own (gethash id drgnx-work-scan--nodes)) (rec (gethash id drgnx-work-scan--updates)))
      (cl-loop for (k v) on props by #'cddr
               unless (equal (drgnx-work-scan--flag (plist-get n k)) (drgnx-work-scan--flag v))
               do (setq n (plist-put n k v))
               (setq rec (if (eq k :status) (plist-put rec :status v) (plist-put rec :patch (plist-put (plist-get rec :patch) k v)))))
      (when rec (puthash id rec drgnx-work-scan--updates))
      (puthash id n (if own drgnx-work-scan--nodes drgnx-work-scan--patched)))))

(defun drgnx-work--git (dir &rest args)
  "git ARGS in DIR: its output (trimmed) or nil.  Nil too in a job's snapshot folder, where the VC guard refuses git
(`drgnx-sandbox-vc'): the tracker reads the main repository (`drgnx-work-source-functions')."
  (when (file-directory-p dir)
    (with-temp-buffer
      (let ((default-directory (file-name-as-directory dir)))
        (condition-case nil
            (when (eql 0 (apply #'call-process "git" nil t nil args)) (string-trim (buffer-string)))
          (drgnx-sandbox-guarded nil))))))

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

(defun drgnx-work--classify (file root)
  "`plan', `spec', `ledger' or nil for FILE under ROOT (only its path under ROOT counts: a root inside
a directory named specs/ or plans/ makes nothing a spec or a plan)."
  (let ((parts (split-string (file-relative-name file root) "/" t)))
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
  (drgnx-work-scan--put (concat "spec:" file) :kind 'spec :title (drgnx-work--title (drgnx-work--text file) (file-name-base file))
                        :path file :line 1 :source (drgnx-work--spec-source file)))

(defun drgnx-work--resolve (name file roots)
  "The file NAME (a `**Spec:**' reference) means, seen from FILE under ROOTS (or a repository in
them), or nil.  A file the personal-notes deny-list denies (after links are resolved: a link into ~/org is caught)
is none: the scan's own door, beside the hub's."
  (seq-find (lambda (f) (and (file-regular-p f) (not (drgnx-deny-path-p (file-truename f)))))
            (mapcar (lambda (d) (expand-file-name name d))
                    (append (list (file-name-directory file)) roots (drgnx-work--repos roots)
                            ;; a plan in docs/plans/x/ naming docs/… relative to its repository root
                            (let ((top (locate-dominating-file file "docs"))) (and top (list top)))))))

(defun drgnx-work--parse-plan (file roots)
  "Nodes of plan FILE: the plan, its tasks, their steps; its spec (and the link to it)."
  (let* ((text (drgnx-work--text file)) (plan (concat "plan:" file)) (steps (make-hash-table :test #'equal)) tasks)
    (when (string-match-p "^### Task [0-9]" text)     ; a markdown without tasks is not a plan
      (drgnx-work-scan--put plan :kind 'plan :title (drgnx-work--title text (file-name-base file)) :path file :line 1
                            :status "open" :source file)
      (when (string-match "^\\*\\*Spec:\\*\\* *`\\([^`]+\\)`" text)
        (when-let* ((spec (drgnx-work--resolve (match-string 1 text) file roots)))
          (unless (drgnx-work-scan--node (concat "spec:" spec)) (drgnx-work--parse-spec spec))
          (drgnx-work-scan--edge plan (concat "spec:" spec) 'derives 'parsed file)))
      (with-temp-buffer
        (insert text)
        (goto-char (point-min))
        (let (task)
          (while (not (eobp))
            (cond
             ((looking-at "^### Task \\([0-9]+\\)[:.]? *\\(.*\\)$")
              (setq task (list (concat "task:" file "#" (match-string 1)) (string-to-number (match-string 1)) 0))
              (push (car task) tasks)
              (drgnx-work-scan--put (car task) :kind 'task :title (string-trim (match-string 2)) :path file
                                    :line (line-number-at-pos) :status "open" :parent plan :ord (cadr task) :source file))
             ((looking-at "^##\\{1,2\\} ") (setq task nil))
             ((and task (looking-at "^[ \t]*[-*] \\[\\([ xX]\\)\\] \\(.+\\)$"))
              (setf (nth 2 task) (1+ (nth 2 task)))
              (push (if (equal (match-string 1) " ") "open" "done") (gethash (car task) steps))
              (drgnx-work-scan--put (format "step:%s#%d.%d" file (cadr task) (nth 2 task)) :kind 'step
                                    :title (string-trim (replace-regexp-in-string "\\*\\*" "" (match-string 2)))
                                    :path file :line (line-number-at-pos)
                                    :status (if (equal (match-string 1) " ") "open" "done")
                                    :parent (car task) :ord (nth 2 task) :source file)))
            (forward-line 1))))
      ;; a task whose steps are all done is done
      (dolist (tk (nreverse tasks))
        (let ((s (gethash tk steps)))
          (when (and s (seq-every-p (lambda (x) (equal x "done")) s))
            (drgnx-work-scan--update tk :status "done"))))
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

(defun drgnx-work--commit-seqs (repo infos)
  "The place of each of the commits INFOS (`drgnx-work--log', newest first) of REPO among its commits: older commits
have fewer ancestors (dates tie within a second) — one count for them all.  A list, as INFOS."
  (let ((depth (and infos (string-to-number (or (drgnx-work--git repo "rev-list" "--count" (caar infos)) "0")))))
    (seq-map-indexed (lambda (_c i) (- i depth)) infos)))

(defun drgnx-work--put-commits (repo infos)
  "Parse the commits INFOS (`drgnx-work--log', newest first) of REPO; their ids.  A commit belongs to no file (several
ledgers may name it; the hub retires the ones no link names)."
  (let ((seqs (drgnx-work--commit-seqs repo infos)))
    (cl-mapcar (lambda (c sq)
                 (drgnx-work-scan--put (concat "commit:" (car c)) :kind 'commit :title (nth 2 c) :path repo :source "commit"
                                       :sha (car c) :date (nth 1 c) :repo repo :seq sq))
               infos seqs)))

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

(defun drgnx-work--ledger-plan (file roots)
  "The plan file the ledger FILE names on its first line: absolute, or relative to ROOTS, the
repositories under them, the ledger's directory or the nearest one holding docs/ (the first that
exists) — never to the scanning process's directory.  Nil when it names none."
  (let ((text (drgnx-work--text file)))
    (when (string-match "\\`# SDD ledger — plan: \\(.+\\)$" text)
      (let ((name (string-trim (match-string 1 text))))
        (if (file-name-absolute-p name) (expand-file-name name)
          (seq-find #'file-regular-p
                    (mapcar (lambda (d) (expand-file-name name d))
                            (append roots (drgnx-work--repos roots) (list (file-name-directory file))
                                    (let ((top (locate-dominating-file file "docs"))) (and top (list top)))))))))))

(defun drgnx-work--parse-ledger (file repos pf)
  "Statuses, commits, rulings and the worktree/branch a ledger FILE gives its plan, the file PF
(`drgnx-work--ledger-plan')."
  (let* ((text (drgnx-work--text file))
         (plan (and pf (concat "plan:" pf))))
    (when (and plan (drgnx-work-scan--node plan))
      ;; which plan it feeds: when the ledger goes (its worktree removed), the plan is read again
      (drgnx-work-scan--put (concat "file:" file) :kind 'file :path file :source file)
      (drgnx-work-scan--edge (concat "file:" file) plan 'ledger-of 'parsed file)
      (let ((n 0))
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
                       when (drgnx-work-scan--node task)
                       do (drgnx-work-scan--update task :status "done" :range-stale (and range (not found) t))
                       (when (and found (= k from))
                         (dolist (c (drgnx-work--put-commits (drgnx-work--main-repo (car found)) (cdr found)))
                           (drgnx-work-scan--edge c task 'implements 'inferred file))))))
           ((string-match "\\`\\(?:Task \\([0-9]+\\)[^:]*: \\)?Ruling: \\(.*\\)" line)
            (let ((task (and (match-string 1 line) (format "task:%s#%s" pf (match-string 1 line)))))
              (drgnx-work-scan--put (format "ruling:%s#%d" file n) :kind 'ruling :title (string-trim (match-string 2 line))
                                    :path file :line n :parent (if (and task (drgnx-work-scan--node task)) task plan) :ord n :source file)))))
        (when-let* ((wt (drgnx-work--worktree-of file)))
          (let ((branch (format "branch:%s:%s" (drgnx-work--git (car wt) "rev-parse" "--path-format=absolute" "--git-common-dir") (cdr wt))))
            (drgnx-work-scan--put branch :kind 'branch :title (cdr wt) :path (car wt) :source "branch"
                                  :repo (car wt) :name (cdr wt))
            (drgnx-work-scan--edge plan branch 'on-branch 'inferred "branch")))))))

(defun drgnx-work--git-facts (plan)
  "Refresh PLAN's worktree, branch and merged state from git."
  (when-let* ((b (car (car (drgnx-work-scan--edges-from plan 'on-branch)))) (bn (drgnx-work-scan--node b)))
    (let* ((common (and (string-match "\\`branch:\\(.*\\):[^:]+\\'" b) (match-string 1 b)))
           (repo (and common (file-name-directory (directory-file-name common))))
           (name (plist-get bn :name))
           (wt (plist-get bn :repo))
           (main (and repo (seq-find (lambda (m) (drgnx-work--git repo "rev-parse" "--verify" "-q" m)) '("main" "master"))))
           (exists (and repo (drgnx-work--git repo "rev-parse" "--verify" "-q" (concat "refs/heads/" name))))
           (tasks (seq-filter (lambda (n) (equal (plist-get n :parent) plan)) (drgnx-work-scan--nodes-of 'task)))
           (done (and tasks (seq-every-p (lambda (n) (equal (plist-get n :status) "done")) tasks)))
           ;; merged: the work is done and its branch is in main (an empty new branch is trivially "in" it)
           (merged (and repo main done
                        (if exists (and (drgnx-work--git repo "merge-base" "--is-ancestor" name main) t)
                          t))))
      (drgnx-work-scan--update plan :branch name :worktree (and wt (file-directory-p wt) wt) :merged merged :repo repo))))

;;;; The board

(defun drgnx-work--parse-board (board)
  "TODOs of the org BOARD that came from a plan (:PLAN_FILE:): nodes under the plan."
  (with-temp-buffer
    (insert-file-contents board)
    (goto-char (point-min))
    (while (re-search-forward "^\\(\\*+\\) \\(?:\\(TODO\\|DONE\\|NEXT\\|WAIT\\|REVIEW\\) \\)?\\(.*\\)$" nil t)
      (let* ((state (match-string 2)) (title (match-string 3)) (hpos (match-beginning 0)) (line (line-number-at-pos))
             (end (save-excursion (forward-line 1) (if (re-search-forward "^\\*+ " nil t) (line-beginning-position) (point-max))))
             (prop (lambda (name) (save-excursion (goto-char hpos)
                                                  (when (re-search-forward (format "^[ \t]*:%s:[ \t]*\\(.+?\\)[ \t]*$" name) end t)
                                                    (match-string 1))))))
        (when-let* ((pf (funcall prop "PLAN_FILE"))
                    ;; relative to the project the TODO is under (refiled or not); without one: none
                    (path (if (file-name-absolute-p pf) (expand-file-name pf)
                            (when-let* ((r (drgnx-projects-heading-root hpos))) (expand-file-name pf r)))))
          (let ((plan (concat "plan:" path)))
            (when (drgnx-work-scan--node plan)
              (drgnx-work-scan--put (format "todo:%s#%s" board (or (funcall prop "ONBOARD_ID") line)) :kind 'todo
                                    :title (string-trim title) :path board :line line
                                    :status (if (equal state "DONE") "done" "open") :parent plan :ord line :source board))))))))

;;;; The scan

(defun drgnx-work-scan--ref (text)
  "The typed source (`graph/put-parsed') of source TEXT: a file's path, `spec PATH', `commit' or `branch'."
  (cond ((member text '("commit" "branch")) (list :kind text))
        ((string-prefix-p "spec " text) (list :kind "spec" :path (substring text 5)))
        (t (list :kind "file" :path text))))

(defun drgnx-work-scan--entity (id)
  "The entity of parsed node ID as `graph/put-parsed' takes it: its own fields, the rest in `data'."
  (let* ((n (gethash id drgnx-work-scan--base)) (title (plist-get n :title)) data)
    (cl-loop for (k v) on n by #'cddr
             unless (or (memq k '(:id :kind :title :status :source)) (null v) (eq v :false))
             do (setq data (append data (list k v))))
    (append (list :id id :kind (symbol-name (plist-get n :kind)))
            (and title (not (string-empty-p title)) (list :title title))
            (and (plist-get n :status) (list :status (plist-get n :status)))
            (and data (list :data data)))))

(defun drgnx-work-scan--link (e)
  (append (list :src (nth 0 e) :kind (symbol-name (nth 2 e)) :dst (nth 1 e))
          (and (not (eq (nth 3 e) 'parsed)) (list :origin (symbol-name (nth 3 e))))))

(defun drgnx-work-scan--update-params (id rec)
  (append (list :id id)
          (and (plist-get rec :status) (list :status (plist-get rec :status)))
          (and (plist-get rec :patch)
               (list :data_patch (cl-loop for (k v) on (plist-get rec :patch) by #'cddr
                                          append (list k (if (drgnx-work-scan--flag v) v :null)))))))

(defun drgnx-work-scan--params (root found seen changed)
  "The `graph/put-parsed' params of what this scan found, or nil when there is nothing to send.  FOUND maps the files
read to their class, SEEN to their times, CHANGED lists the files whose time changed (each is sent, even when it holds
nothing: its time is kept)."
  (let (sources groups)
    ;; entities and links by source, in the order parsed
    (dolist (id (reverse drgnx-work-scan--order))
      (let ((text (plist-get (gethash id drgnx-work-scan--base) :source)))
        (push id (alist-get text groups nil nil #'equal))))
    (let ((texts nil)
          ;; a link may name an entity of another source: specs, commits, then files, ledgers, branches
          (rank (lambda (text)
                  (cond ((string-prefix-p "spec " text) 0) ((equal text "commit") 1) ((equal text "branch") 5)
                        ((seq-some (lambda (id) (string-prefix-p "file:" id)) (alist-get text groups nil nil #'equal)) 4)
                        (t 3)))))
      (dolist (g groups) (cl-pushnew (car g) texts :test #'equal))
      (maphash (lambda (text _) (cl-pushnew text texts :test #'equal)) drgnx-work-scan--resent)
      (dolist (f changed)
        (when (gethash f found) (cl-pushnew (if (eq (gethash f found) 'spec) (drgnx-work--spec-source f) f) texts :test #'equal)))
      (dolist (text (sort texts (lambda (a b) (let ((ra (funcall rank a)) (rb (funcall rank b)))
                                                (if (= ra rb) (string< a b) (< ra rb))))))
        (unless (gethash text drgnx-work-scan--gone)
          (let* ((ref (drgnx-work-scan--ref text)) (path (plist-get ref :path))
                 (ids (reverse (alist-get text groups nil nil #'equal)))
                 (links (seq-filter (lambda (e) (equal (nth 4 e) text)) (reverse drgnx-work-scan--edges)))
                 (mtime (and path (gethash path seen))))
            (when (or ids links mtime (drgnx-work-scan--hidden-p text))
              (push (append (list :source ref)
                            (and mtime (list :mtime mtime))
                            (and ids (list :entities (vconcat (mapcar #'drgnx-work-scan--entity ids))))
                            (and links (list :links (vconcat (mapcar #'drgnx-work-scan--link links)))))
                    sources))))))
    (let ((gone (let (out) (maphash (lambda (_ ref) (push ref out)) drgnx-work-scan--gone) (sort out (lambda (a b) (string< (format "%S" a) (format "%S" b))))))
          (updates (let (out) (maphash (lambda (id rec) (push (drgnx-work-scan--update-params id rec) out)) drgnx-work-scan--updates)
                        (sort out (lambda (a b) (string< (plist-get a :id) (plist-get b :id)))))))
      (when (or sources gone updates)
        (append (and root (list :root (directory-file-name root)))
                (and sources (list :sources (vconcat (nreverse sources))))
                (and gone (list :gone (vconcat gone)))
                (and updates (list :updates (vconcat updates))))))))

(cl-defun drgnx-work-scan-collect (roots &key board)
  "Read ROOTS (directories) and BOARD (an org file) and work out what the hub is to be told: (:params P :files N),
P the `graph/put-parsed' params, or nil when nothing changed.  Reads only; the database is read-only here."
  (let* ((roots (mapcar (lambda (r) (file-name-as-directory (expand-file-name r))) roots))
         (repos (drgnx-work--repos roots))
         (drgnx-work-scan--nodes (make-hash-table :test #'equal)) (drgnx-work-scan--base (make-hash-table :test #'equal))
         (drgnx-work-scan--order nil) (drgnx-work-scan--edges nil)
         (drgnx-work-scan--resent (make-hash-table :test #'equal)) (drgnx-work-scan--gone (make-hash-table :test #'equal))
         (drgnx-work-scan--patched (make-hash-table :test #'equal)) (drgnx-work-scan--updates (make-hash-table :test #'equal))
         (found (make-hash-table :test #'equal)) (seen (make-hash-table :test #'equal))
         (spec-paths (mapcar (lambda (s) (plist-get s :path)) (drgnx-work-nodes 'spec)))
         plans specs ledgers changed reread)
    (dolist (r roots)
      (drgnx-work--walk r 7 (lambda (f ledgers-only)
                              (when-let* ((k (drgnx-work--classify f r)) ((or (not ledgers-only) (eq k 'ledger)))
                                          ((not (drgnx-deny-path-p f))))
                                (puthash f k found)
                                (pcase k ('plan (push f plans)) ('spec (push f specs)) ('ledger (push f ledgers)))))))
    (when (and board (file-readable-p board)) (puthash board 'board found))
    ;; a spec a plan names outside specs/: its time is kept too (read again when it changes, forgotten
    ;; when it goes)
    (dolist (f spec-paths)
      (when (and f (not (gethash f found)) (file-readable-p f)) (puthash f 'spec found)))
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
        (dolist (text (if (member f spec-paths) (list f (drgnx-work--spec-source f)) (list f)))
          (puthash text t drgnx-work-scan--resent)
          (puthash text (drgnx-work-scan--ref text) drgnx-work-scan--gone))
        (push f changed)))
    (when changed
      ;; plans and their ledgers are read together (a ledger changes its plan's tasks)
      (dolist (f specs)
        (when (member f changed)
          (puthash (drgnx-work--spec-source f) t drgnx-work-scan--resent) (drgnx-work--parse-spec f)))
      ;; a spec a plan names, outside specs/, read again when it changed
      (dolist (f spec-paths)
        (when (and (member f changed) (not (member f specs)) (file-readable-p f))
          (puthash (drgnx-work--spec-source f) t drgnx-work-scan--resent) (drgnx-work--parse-spec f)))
      (let ((ledger-plan (mapcar (lambda (l) (cons l (drgnx-work--ledger-plan l roots))) ledgers)))
        (dolist (p plans)
          (when (or (member p changed) (member p reread)
                    (seq-find (lambda (lp) (and (equal (cdr lp) p) (member (car lp) changed))) ledger-plan))
            (puthash p t drgnx-work-scan--resent)
            (dolist (lp ledger-plan) (when (equal (cdr lp) p) (puthash (car lp) t drgnx-work-scan--resent)))
            (drgnx-work--parse-plan p roots)
            (dolist (lp ledger-plan)
              (when (equal (cdr lp) p) (drgnx-work--parse-ledger (car lp) repos p)))))
        (when (and board (file-readable-p board) (or (member board changed) (seq-intersection changed plans)))
          (puthash board t drgnx-work-scan--resent)
          (drgnx-work--parse-board board))))
    ;; …and lives as long as a plan names it (one first read: its time is kept from the next scan on)
    (dolist (s (drgnx-work-scan--nodes-of 'spec))
      (let ((f (plist-get s :path)) (text (plist-get s :source)))
        (unless (or (member f specs) (drgnx-work-scan--edges-to (plist-get s :id) 'derives))
          (puthash text t drgnx-work-scan--resent)
          (puthash text (drgnx-work-scan--ref text) drgnx-work-scan--gone)
          (when (eq (gethash f found) 'spec) (remhash f found)))))
    (dolist (p (drgnx-work-scan--nodes-of 'plan)) (drgnx-work--git-facts (plist-get p :id)))
    (drgnx-work--check-commits)
    (list :params (drgnx-work-scan--params (car roots) found seen changed)
          :files (length (seq-filter (lambda (f) (gethash f found)) changed)))))

(defconst drgnx-work-scan-request-max 800000
  "Bytes of one `graph/put-parsed' line: the hub refuses a line over 1 MiB.")

(defun drgnx-work-scan--chunks (params)
  "PARAMS as the requests that fit the hub's line cap: one, unless the sources do not fit (they are split in order; the
gone sources go first, the derived updates last)."
  (let ((sources (append (plist-get params :sources) nil)) (root (plist-get params :root)))
    (if (and (<= (length sources) 1000)
             (< (length (json-serialize (drgnx-hub--jsonable params))) drgnx-work-scan-request-max))
        (list params)
      (let (chunks cur (size 0))
        (dolist (s sources)
          (let ((n (length (json-serialize (drgnx-hub--jsonable s)))))
            (when (and cur (or (> (+ size n) drgnx-work-scan-request-max) (>= (length cur) 1000)))
              (push (nreverse cur) chunks) (setq cur nil size 0))
            (push s cur) (cl-incf size n)))
        (when cur (push (nreverse cur) chunks))
        (setq chunks (nreverse chunks))
        (let ((n (length chunks)) (i 0))
          (mapcar (lambda (c)
                    (cl-incf i)
                    (append (list :root root :sources (vconcat c))
                            (and (= i 1) (plist-get params :gone) (list :gone (plist-get params :gone)))
                            (and (= i n) (plist-get params :updates) (list :updates (plist-get params :updates)))))
                  chunks))))))

(defun drgnx-work-scan-send (params)
  "Send PARAMS (`graph/put-parsed') to the hub and wait for the answer: (:changed N :retired N :refused LIST), LIST the
refused sources as plists (:source (:kind K :path P) :why TEXT).  Signals the hub's error, or that it did not answer
\(30 s for a request)."
  (let ((changed 0) (retired 0) refused)
    (dolist (p (drgnx-work-scan--chunks params))
      (let ((r (drgnx-hub-call-sync "graph/put-parsed" p 30)))
        (cl-incf changed (or (plist-get r :changed) 0))
        (cl-incf retired (or (plist-get r :retired) 0))
        (setq refused (append refused (append (plist-get r :refused) nil)))))
    (list :changed changed :retired retired :refused refused)))

(cl-defun drgnx-work-scan (roots &key board)
  "Bring the store up to date with ROOTS (directories) and BOARD (an org file): the scan reads, then sends everything
in ONE `graph/put-parsed' to the hub and waits for its answer (a `--batch' Emacs would exit before an asynchronous
one came; no timer runs the scan).  Nothing changed: nothing is sent.  Returns (:files N :changed N :retired N
:refused LIST) — how many files were read again, and what the hub did."
  (let* ((c (drgnx-work-scan-collect roots :board board)) (params (plist-get c :params)))
    (append (list :files (plist-get c :files))
            (if params (drgnx-work-scan-send params) (list :changed 0 :retired 0 :refused nil)))))

(defun drgnx-work--check-commits ()
  "Mark the commits no branch, tag or HEAD reaches any more (rebased, squashed, amended, pruned) as
gone, and their tasks stale — every scan, whatever changed.  Two git calls per repository."
  (let ((by-repo (seq-group-by (lambda (c) (plist-get c :repo)) (drgnx-work-scan--nodes-of 'commit))) gone)
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
              (drgnx-work-scan--update (plist-get c :id) :gone g))))))
    (dolist (tk (drgnx-work-scan--nodes-of 'task))
      (let ((s (and (or (plist-get tk :range-stale)
                        (seq-some (lambda (e) (member (car e) gone)) (drgnx-work-scan--edges-to (plist-get tk :id) 'implements)))
                    t)))
        (drgnx-work-scan--update (plist-get tk :id) :stale s)))))

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

(defvar drgnx-work--sync nil
  "Non-nil in the batch commands (`drgnx work record|scan'): a hub call waits for its answer (`drgnx-hub-call-sync'),
which a `--batch' Emacs needs.  Nil everywhere else, the editor's daemon paths above all: the call is asynchronous.")

(declare-function drgnx-notify "drgnx-notice" (source severity text &rest args))

(defun drgnx-work--hub-failed (text)
  "Tell the user once that a call to the hub failed (the notice replaces its predecessor: one at a time)."
  (require 'drgnx-notice)
  (drgnx-notify 'hub 'warn (format "drgnx hub: %s" text) :id 'work-record))

(defun drgnx-work--hub (method params &optional on-result)
  "Call the hub's METHOD with PARAMS (a plist).  In a batch command (`drgnx-work--sync') it waits and returns the
result (ON-RESULT, if given, turns it into the value); anywhere else it only asks, never waits and returns nil: an
error shows once as \"drgnx hub: TEXT\"."
  (if drgnx-work--sync
      (let ((r (drgnx-hub-call-sync method params 30))) (if on-result (funcall on-result r) r))
    (condition-case err
        (drgnx-hub-call method params
                        (lambda (r e)
                          (cond (e (drgnx-work--hub-failed e))
                                (on-result (funcall on-result r)))))
      (error (drgnx-work--hub-failed (error-message-string err))))
    nil))

(defun drgnx-work-record-commits (task repo infos &optional collected)
  "Record that the commits INFOS (`drgnx-work--log', newest first) of REPO did TASK (a node id) — kept across every
rescan — through the hub (`graph/record'; COLLECTED is the job collector's key, `job ID').  In a batch command their
ids; elsewhere nil (the call is asynchronous)."
  (let* ((repo (or (drgnx-work--main-repo repo) repo))
         (seqs (drgnx-work--commit-seqs repo infos))
         (params (append (list :task task :repo (directory-file-name repo)
                               :commits (vconcat (cl-mapcar (lambda (c sq) (list :sha (nth 0 c) :date (nth 1 c) :subject (nth 2 c) :seq sq))
                                                            infos seqs)))
                         (and collected (list :collected collected)))))
    (drgnx-work--hub "graph/record" params (lambda (r) (append (plist-get r :ids) nil)))))

(defun drgnx-work-record (task repo sha)
  "Record that commit SHA of REPO did TASK (a node id); in a batch command its node id, or nil when REPO has no SHA
\(elsewhere nil: the call is asynchronous)."
  (when-let* ((infos (drgnx-work--log repo "-1" sha)))
    (car (drgnx-work-record-commits task repo infos))))

(provide 'drgnx-work-scan)
;;; drgnx-work-scan.el ends here
