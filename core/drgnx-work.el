;;; drgnx-work.el --- The work tracker: recording the commits drgnx-started work makes; the CLI -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Agent sessions and jobs started on a task (a node id of the tracker: "task:FILE#N", a TODO, a
;; plan) get it as DRGNX_TASK; drgnx notes the git HEAD they start at and records the commits made
;; since — after each agent turn, and once a job ended.  Commit messages stay untouched; the links
;; live in the tracker's database (and, when `drgnx-work-git-notes' is on, in git notes too).
;; `drgnx work record|scan|status' is the command line.  See docs/work.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-work-scan)

(defvar drgnx-work-git-notes nil
  "Non-nil: every recorded link is also written as a git note (refs/notes/drgnx) on its commit,
so it travels with the repository.  Off by default: notes are shared state of the repository.")

(defvar drgnx-work-roots nil
  "Directories the tracker scans besides the projects' roots (projects.eld).")

(defvar drgnx-work--tasks nil "Alist agent session → its recording state (`drgnx-work-task-begin').")

;;;; Recording

(defun drgnx-work--head (dir) (drgnx-work--git dir "rev-parse" "HEAD"))

(defun drgnx-work--new-commits (dir from to)
  "The commits FROM..TO in DIR's repository, newest first (all of TO's when FROM is nil)."
  (when to
    (split-string (or (drgnx-work--git dir "rev-list" (if from (concat from ".." to) to)) "") "\n" t)))

(defun drgnx-work-record-commit (task repo sha)
  "`drgnx-work-record' TASK REPO SHA, mirrored to a git note when `drgnx-work-git-notes'."
  (prog1 (drgnx-work-record task repo sha)
    (when drgnx-work-git-notes
      (drgnx-work--git repo "notes" "--ref=drgnx" "append" "-m" (concat "drgnx task: " task) sha))))

(defun drgnx-work-task-begin (task dir)
  "Start recording for TASK the commits made in DIR's repository from now on: the state."
  (list :task task :dir dir :head (drgnx-work--head dir)))

(defun drgnx-work-task-collect (state)
  "Record the commits made since STATE last looked; the SHAs recorded (none twice)."
  (let* ((dir (plist-get state :dir)) (head (drgnx-work--head dir))
         (repo (drgnx-work--git dir "rev-parse" "--show-toplevel"))
         (new (and head (not (equal head (plist-get state :head)))
                   (drgnx-work--new-commits dir (plist-get state :head) head))))
    (dolist (sha new) (drgnx-work-record-commit (plist-get state :task) (file-name-as-directory repo) sha))
    (plist-put state :head head)
    new))

(defun drgnx-work--agent-task (s event)
  "`drgnx-agents-task-functions': note where S's work starts; record its commits after each turn."
  (pcase event
    ('start (push (cons s (drgnx-work-task-begin (drgnx-agent-session-task s) (drgnx-agent-session-cwd s))) drgnx-work--tasks))
    ('turn-end (when-let* ((st (alist-get s drgnx-work--tasks))) (drgnx-work-task-collect st)))))

(declare-function drgnx-agent-session-task "drgnx-agents")
(declare-function drgnx-agent-session-cwd "drgnx-agents")
(add-hook 'drgnx-agents-task-functions #'drgnx-work--agent-task)

(declare-function drgnx-jobs-list "drgnx-jobs")
(declare-function drgnx-jobs--dir "drgnx-jobs")
(declare-function drgnx-jobs--text "drgnx-jobs")

(defun drgnx-work-collect-jobs ()
  "Record the commits of the jobs that worked on a task and ended (each job once)."
  (require 'drgnx-jobs)
  (dolist (job (drgnx-jobs-list))
    (let* ((id (plist-get job :id)) (key (concat "job " id)))
      (when (and (plist-get job :task) (memq (plist-get job :status) '(exited stopped))
                 (not (sqlite-select (drgnx-work-db) "select 1 from meta where key = ?" (list key))))
        (let* ((dir (plist-get job :cwd))
               (end (drgnx-jobs--text (expand-file-name "head" (drgnx-jobs--dir id))))
               (repo (drgnx-work--git dir "rev-parse" "--show-toplevel")))
          (when repo
            (dolist (sha (and end (not (equal end (plist-get job :head))) (drgnx-work--new-commits dir (plist-get job :head) end)))
              (drgnx-work-record-commit (plist-get job :task) (file-name-as-directory repo) sha)))
          (sqlite-execute (drgnx-work-db) "insert or replace into meta values (?, 'collected')" (list key)))))))

;;;; Scanning what the user works on

(declare-function drgnx-projects-read "drgnx-projects")
(declare-function drgnx-projects-board-file "drgnx-projects")

(defun drgnx-work-default-roots ()
  "The roots of the projects drgnx knows (projects.eld) and `drgnx-work-roots'."
  (require 'drgnx-projects)
  (delete-dups (seq-filter #'file-directory-p
                           (mapcar #'expand-file-name
                                   (append drgnx-work-roots
                                           (delq nil (mapcar (lambda (p) (plist-get p :root)) (plist-get (drgnx-projects-read) :projects))))))))

(defun drgnx-work-refresh (&optional roots)
  "Scan ROOTS (default: `drgnx-work-default-roots') and the board, and collect ended jobs."
  (require 'drgnx-projects)
  (prog1 (drgnx-work-scan (or roots (drgnx-work-default-roots)) :board (drgnx-projects-board-file))
    (drgnx-work-collect-jobs)))

;;;; Command line

(defun drgnx-work--print (fmt &rest args) (princ (apply #'format fmt args)) (terpri))

(defun drgnx-work--status-rows ()
  "One row per plan: (:id :title :path :spec :branch :merged COUNTS…)."
  (mapcar (lambda (p)
            (append (list :id (plist-get p :id) :title (plist-get p :title) :path (plist-get p :path)
                          :spec (car (car (drgnx-work-edges-from (plist-get p :id) 'derives)))
                          :branch (plist-get p :branch) :merged (plist-get p :merged))
                    (drgnx-work-counts (plist-get p :id))))
          (sort (drgnx-work-nodes 'plan) (lambda (a b) (string< (plist-get a :path) (plist-get b :path))))))

(defun drgnx-work--json-row (row)
  (let ((pair (lambda (c) (vector (car c) (cdr c)))))
    (list :id (plist-get row :id) :title (plist-get row :title) :path (plist-get row :path)
          :spec (or (plist-get row :spec) :null) :branch (or (plist-get row :branch) :null)
          :merged (if (plist-get row :merged) t :false)
          :tasks (funcall pair (plist-get row :tasks)) :steps (funcall pair (plist-get row :steps))
          :todos (funcall pair (plist-get row :todos)) :commits (plist-get row :commits))))

(defun drgnx-work-cli-run (args)
  "Run `drgnx work' ARGS (strings); the exit code (2: a usage error)."
  (condition-case err
      (pcase args
        (`("record" . ,rest)
         (let ((task (getenv "DRGNX_TASK")) shas)
           (while rest
             (let ((a (pop rest)))
               (if (equal a "--task") (setq task (pop rest)) (push a shas))))
           (if (or (null task) (string-empty-p task))
               (progn (drgnx-work--print "drgnx work record: which task? (--task ID, or DRGNX_TASK)") 2)
             (let ((repo (drgnx-work--git default-directory "rev-parse" "--show-toplevel")) (bad 0))
               (if (not repo) (progn (drgnx-work--print "drgnx work record: not inside a git repository") 1)
                 (dolist (sha (or (nreverse shas) '("HEAD")))
                   (let ((full (drgnx-work--git repo "rev-parse" "--verify" "--quiet" (concat sha "^{commit}"))))
                     (if (and full (drgnx-work-record-commit task (file-name-as-directory repo) full))
                         (drgnx-work--print "%s → %s" (substring full 0 7) task)
                       (drgnx-work--print "drgnx work record: no commit %s here" sha)
                       (setq bad 1))))
                 bad)))))
        (`("scan" . ,roots)
         (let* ((t0 (float-time)) (r (drgnx-work-refresh (mapcar #'expand-file-name roots))))
           (drgnx-work--print "%d files read in %.2f s; %d plans, %d specs (%s)" (plist-get r :files) (- (float-time) t0)
                              (length (drgnx-work-nodes 'plan)) (length (drgnx-work-nodes 'spec)) (drgnx-work-db-file))
           0))
        (`("status" . ,flags)
         (let ((rows (drgnx-work--status-rows)))
           (if (member "--json" flags)
               (princ (json-serialize (vconcat (mapcar #'drgnx-work--json-row rows))))
             (if (null rows) (drgnx-work--print "no plans yet: drgnx work scan [DIR…]")
               (dolist (r rows)
                 (let ((c (lambda (k) (format "%d/%d" (car (plist-get r k)) (cdr (plist-get r k))))))
                   (drgnx-work--print "%-9s tasks %-6s steps %-7s todos %-5s commits %-3d %s%s"
                                      (cond ((plist-get r :merged) "merged") ((plist-get r :branch) "branch") (t ""))
                                      (funcall c :tasks) (funcall c :steps) (funcall c :todos) (plist-get r :commits)
                                      (plist-get r :title) (if (plist-get r :branch) (format "  [%s]" (plist-get r :branch)) ""))))))
           0))
        (_ (drgnx-work--print "usage: drgnx work record [--task ID] [SHA…] | scan [DIR…] | status [--json]") 2))
    (error (drgnx-work--print "drgnx work: %s" (error-message-string err)) 1)))

(defun drgnx-work-cli ()
  "bin/drgnx's work commands: the arguments after --."
  (let ((args (cdr (member "--" command-line-args-left))))
    (setq command-line-args-left nil)
    (kill-emacs (drgnx-work-cli-run args))))

(provide 'drgnx-work)
;;; drgnx-work.el ends here
