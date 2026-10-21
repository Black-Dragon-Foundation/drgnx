;;; cockpit-fixture.el --- for Work cockpit tests: a temp project with a spec, a plan, a ledger, a board, a job, worktrees and events -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx-cockpit-fixture-with' makes, in a temp dir (ROOT), with drgnx's data dir and HOME there too:
;; - REPO, a git repository (branch main, one commit SHA) holding SPEC (docs/specs/s.md) and PLAN (docs/plans/p.md,
;;   "M99 — the plan", six tasks; task N's heading on line PLAN-LINE N);
;; - two linked worktrees: WT-A (branch wt-a: README changed, new.txt added — an outside agent registered there) and WT-B
;;   (branch wt-b: b.txt committed, and a ledger saying Task 1 is complete — nobody registered: a silent worktree);
;; - BOARD, its own org file (never ~/org/board.org) with a TODO from the plan;
;; - the work tracker's scan of REPO and BOARD;
;; - job "jx" of 3 tasks (plan tasks 2, 3 and 4; 3 and 4 need 2), running; jx#2 claimed and running by session "s-1";
;; - events: s-1's decision, edit (2 files), test (12/12) and question (an escalation); an ask card on jx#3 settled and
;;   reopened; session "s-2" (a chat on plan task 5) started at SHA; outside agent "ext:claude-code:42" (its own label
;;   "jx#4", which is never a job task of its) started in WT-A and reported README and new.txt;
;; - SESSIONS: the hub's snapshots of s-1 (job jx, task jx#2, in TREE) and s-2 (no job, task plan task 5, in REPO).

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-coord)
(require 'drgnx-work-scan)

(defun drgnx-cockpit-fixture-git (dir &rest args)
  "git ARGS in DIR (the fixture's own identity, nothing of the user's): its output, trimmed; an error when git fails."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (unless (eql 0 (apply #'call-process "git" nil t nil args))
        (error "git %S: %s" args (buffer-string)))
      (string-trim (buffer-string)))))

(defun drgnx-cockpit-fixture-write (file text)
  "Write TEXT to FILE, making its directory."
  (make-directory (file-name-directory file) t)
  (write-region text nil file nil 'silent))

(defun drgnx-cockpit-fixture-plan-text ()
  "The plan: a title, its spec, six tasks with one step each."
  (concat "# M99 — the plan\n\n**Spec:** `docs/specs/s.md`\n\n## Tasks\n\n"
          (mapconcat (lambda (n) (format "### Task %d: task %d\n\n- [ ] Step 1: do %d\n\n" n n n)) (number-sequence 1 6) "")))

(declare-function drgnx-state-sync "drgnx-state")
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)   ; `drgnx-test-with-state'
(load (expand-file-name "test/fixtures/notice-fixture" drgnx-dir) nil t)   ; `drgnx-notice-test-with-model'
(require 'drgnx-wait-fixture (expand-file-name "wait-fixture" (file-name-directory (macroexp-file-name))))

(defmacro drgnx-cockpit-fixture-after-setup (&rest body)
  "Run tools/cockpit's setup outside a module run (its pane kinds as the test stubs them), then BODY, in a fresh
workbench state store and a fresh notice model (the setup defines the `questions' source): its subscriptions go with
the store afterwards, and its `cockpit-waiting' timer is cancelled."
  (declare (indent 0))
  `(drgnx-test-with-state
     (drgnx-notice-test-with-model
       (unwind-protect
           (progn (funcall (plist-get (alist-get 'tools/cockpit drgnx-modules--table) :setup)) ,@body)
         (drgnx-timer-cancel 'cockpit-waiting)))))

(defun drgnx-cockpit-fixture-show-pane (kind buffer home)
  "Show BUFFER as pane KIND in its HOME (`left', `right', `bottom' or `editor') of the selected frame, marked as the
workbench marks it, and let the state store see it (`drgnx-state-sync'; run it inside `drgnx-test-with-state').
Returns the window."
  (let ((w (if (eq home 'editor)
               (let ((w (selected-window)))
                 (set-window-buffer w buffer)
                 (set-window-parameter w 'drgnx-layouts-pane kind)
                 w)
             (let ((area (pcase home ('right 'right) ('bottom 'panel))))
               (when area (set-frame-parameter nil 'drgnx-wb-areas (list (list area :tab kind))))
               (display-buffer-in-side-window
                buffer `((side . ,home) (slot . 0)
                         (window-parameters . ,(if area `((drgnx-role . ,area)) `((drgnx-role . dock) (drgnx-section . ,kind))))))))))
    (drgnx-state-sync)
    w))

(defun drgnx-cockpit-fixture-hide-pane (window)
  "Hide the pane in WINDOW (`drgnx-cockpit-fixture-show-pane'): a side window goes, an editor window shows *scratch*;
the state store sees it."
  (if (window-parameter window 'window-side)
      (let ((ignore-window-parameters t)) (delete-window window))
    (set-window-parameter window 'drgnx-layouts-pane nil)
    (set-window-buffer window (get-buffer-create "*scratch*")))
  (set-frame-parameter nil 'drgnx-wb-areas nil)
  (drgnx-state-sync))

(defun drgnx-cockpit-fixture-wait (pred &optional secs)
  "Wait (processes run) until PRED is non-nil: PRED's value (`drgnx-test-wait', at least 30 s or SECS)."
  (drgnx-test-wait pred :secs (max 30 (or secs 0)) :what "the cockpit fixture's predicate"))

(defmacro drgnx-cockpit-fixture-with (&rest body)
  "BODY in the cockpit fixture (see the commentary): ROOT REPO SPEC PLAN BOARD WT-A WT-B TREE SHA SESSIONS are bound,
and (PLAN-LINE N) is task N's heading line."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-cockpit" t)))
          (repo (concat root "repo/"))
          (spec (concat repo "docs/specs/s.md")) (plan (concat repo "docs/plans/p.md"))
          (board (concat root "board.org"))
          (wt-a (concat repo ".claude/worktrees/wt-a/")) (wt-b (concat repo ".claude/worktrees/wt-b/"))
          (tree (concat repo ".claude/worktrees/jx-2/"))
          (process-environment (append (list (concat "DRGNX_DATA_DIR=" root "data") (concat "DRGNX_CONFIG_DIR=" root "config")
                                             (concat "HOME=" root) "GIT_CONFIG_GLOBAL=/dev/null" "GIT_CONFIG_NOSYSTEM=1"
                                             "GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@t.invalid"
                                             "GIT_COMMITTER_NAME=t" "GIT_COMMITTER_EMAIL=t@t.invalid")
                                       process-environment))
          (drgnx-work-db--handles nil)
          (drgnx-projects-board-file board)
          sha sessions)
     (cl-flet ((plan-line (n) (+ 7 (* 4 (1- n)))))
       (ignore #'plan-line)
       (unwind-protect
           (progn
             (drgnx-cockpit-fixture-write (concat repo "README") "readme\n")
             (drgnx-cockpit-fixture-write spec "# The spec\n\nWhat it is.\n")
             (drgnx-cockpit-fixture-write plan (drgnx-cockpit-fixture-plan-text))
             (drgnx-cockpit-fixture-git repo "init" "-q" "-b" "main")
             (drgnx-cockpit-fixture-git repo "add" "-A")
             (drgnx-cockpit-fixture-git repo "commit" "-q" "-m" "start")
             (setq sha (drgnx-cockpit-fixture-git repo "rev-parse" "HEAD"))
             ;; two worktrees: one an outside agent works in (uncommitted), one nobody reports from (committed + a ledger)
             (drgnx-cockpit-fixture-git repo "worktree" "add" "-q" "-b" "wt-a" wt-a "main")
             (drgnx-cockpit-fixture-write (concat wt-a "README") "readme\nmore\n")
             (drgnx-cockpit-fixture-write (concat wt-a "new.txt") "new\n")
             (drgnx-cockpit-fixture-git repo "worktree" "add" "-q" "-b" "wt-b" wt-b "main")
             (drgnx-cockpit-fixture-write (concat wt-b "b.txt") "b\n")
             (drgnx-cockpit-fixture-git wt-b "add" "b.txt")
             (drgnx-cockpit-fixture-git wt-b "commit" "-q" "-m" "b")
             (drgnx-cockpit-fixture-write (concat wt-b ".superpowers/sdd/p/progress.md")
                                          (format "# SDD ledger — plan: docs/plans/p.md\n\nTask 1: complete (commit %s)\n" sha))
             (drgnx-cockpit-fixture-write board (format "* repo\n:PROPERTIES:\n:PROJECT_ROOT: %s\n:END:\n** TODO Write the docs\n:PROPERTIES:\n:PLAN_FILE: %s\n:END:\n"
                                                        repo plan))
             (drgnx-work-scan (list repo) :board board)
             ;; the job: plan tasks 2, 3, 4
             (drgnx-coord-job-create :id "jx" :title "M99 — the plan" :plan plan :repo repo
                                     :tasks '((:n 2 :title "task 2" :role "implement")
                                              (:n 3 :title "task 3" :role "implement" :deps (2))
                                              (:n 4 :title "task 4" :role "test" :deps (2))))
             (drgnx-coord-job-set "jx" :status "running")
             (drgnx-coord-claim "jx#2" "s-1" 0)
             (drgnx-coord-set-status "jx#2" "s-1" "running" 0)
             (drgnx-coord-decide :kind "build" :subject "the parser" :task "jx#2" :author "s-1" :seen 0 :job "jx")
             (drgnx-coord-event-add :agent "s-1" :job "jx" :task "jx#2" :kind "edit" :summary "2 files"
                                    :data (list :root (directory-file-name tree) :paths '("a.el" "b.el")))
             (drgnx-coord-event-add :agent "s-1" :job "jx" :task "jx#2" :kind "test" :summary "12 passed, 0 failed: make test"
                                    :data '(:command "make test" :passed 12 :failed 0))
             (drgnx-coord-send :job "jx" :sender "s-1" :recipient "user" :text "[escalation] which way?" :seen (drgnx-coord-version))
             (let ((card (drgnx-coord-card-create :job "jx" :task "jx#3" :kind "ask" :title "Pick a name")))
               (drgnx-coord-card-settle card "foo")
               (drgnx-coord-card-set card :state "open"))
             (drgnx-coord-event-add :agent "s-2" :kind "start" :summary "chat started" :data (list :head sha))
             (drgnx-coord-agent-register :id "ext:claude-code:42" :kind "claude-code" :name "Claude Code"
                                         :cwd (directory-file-name wt-a) :worktree (directory-file-name wt-a) :branch "wt-a"
                                         :base sha :task "jx#4")
             (drgnx-coord-event-add :agent "ext:claude-code:42" :kind "start" :summary "Claude Code started")
             (drgnx-coord-event-add :agent "ext:claude-code:42" :kind "edit" :summary "2 files"
                                    :data (list :root (directory-file-name wt-a) :paths '("README" "new.txt")))
             (setq sessions (list (list :id "s-1" :name "claude · jx#2" :cwd tree :task "jx#2" :job "jx" :status 'idle)
                                  (list :id "s-2" :name "chat" :cwd repo :task (format "task:%s#5" plan) :status 'busy)))
             ,@body)
         (dolist (p (process-list))
           (when (string-prefix-p "drgnx-cockpit-git" (process-name p)) (set-process-sentinel p #'ignore) (delete-process p)))
         (drgnx-work-db-close-all)
         (delete-directory root t)))))

(provide 'cockpit-fixture)
;;; cockpit-fixture.el ends here
