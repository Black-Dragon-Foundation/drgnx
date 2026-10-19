;;; drgnx-cockpit-model.el --- The Work cockpit's model: specs, plans, tasks, agents, jobs and reviews, from the live store -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; One model of the work for the Work cockpit (the graph, live edits, "what happened", questions, the timeline), read
;; from the live store — the work tracker's nodes (specs, plans, tasks, board TODOs: drgnx-work-db.el), the
;; coordination store's jobs, tasks, cards, events, agent registry (drgnx-coord.el) — and the hub's session snapshots,
;; passed in.  Plan tasks are the skeleton; a job's task is joined to its plan task (`task:PLAN#N'); a plan task no job
;; runs is read-only.  Batch-safe: nothing here prompts, and nothing runs a process except git, always asynchronously
;; (`drgnx-cockpit-silent-worktrees', `drgnx-cockpit-changed-files', `drgnx-cockpit-file-diff'), never on a remote
;; (TRAMP) folder.  Plan files are read, never written.  See docs/develop/cockpit.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-timer)
(require 'drgnx-file)                   ; `drgnx-file-truename': an agent's names, with no file name handler
(require 'drgnx-work-db)
(require 'drgnx-coord)

(defgroup drgnx-cockpit nil
  "The Work cockpit: the Work graph, each agent's edits, what happened, questions and the timeline."
  :group 'drgnx)

(defcustom drgnx-cockpit-node-functions nil
  "Functions that add to the cockpit's model: each is called with the model and returns (:nodes NODES :edges EDGES)
to add.  A new node kind needs only this (and a face for it).  A node is a plist with at least :id, :kind and :title
\(see `drgnx-cockpit-model'); an edge is (:from ID :to ID :kind KIND)."
  :type 'hook :group 'drgnx-cockpit)

(defcustom drgnx-cockpit-filter-functions nil
  "Functions that filter the cockpit's nodes: each is called with a node and the filter (`drgnx-cockpit-filter'); nil
drops the node."
  :type 'hook :group 'drgnx-cockpit)

(defcustom drgnx-cockpit-happened-limit 50
  "How many events \"what happened\" shows for an agent (the newest)."
  :type 'natnum :group 'drgnx-cockpit)

(defcustom drgnx-cockpit-timeline-limit 300
  "How many events the timeline holds (the newest)."
  :type 'natnum :group 'drgnx-cockpit)

(defcustom drgnx-cockpit-main-branches '("main" "master")
  "The names a repository's main branch may have, the first that exists wins: a worktree's changes are against its
merge-base with it."
  :type '(repeat string) :group 'drgnx-cockpit)

(defcustom drgnx-cockpit-include-closed-jobs nil
  "Non-nil: the model shows done jobs too (their tasks on the plan tasks they ran); nil: only the open ones."
  :type 'boolean :group 'drgnx-cockpit)

(defcustom drgnx-cockpit-git-timeout 30
  "Seconds a git process of the cockpit may run; then it is ended and its caller gets an error."
  :type 'number :group 'drgnx-cockpit)

(defcustom drgnx-cockpit-diff-max-bytes 1048576
  "The biggest file, and the biggest diff of one file, the cockpit shows; above it the diff is \"too large\".  Also
the most bytes git's list of changed or untracked files may take (`drgnx-cockpit-changed-files')."
  :type 'natnum :group 'drgnx-cockpit)

(defcustom drgnx-cockpit-count-bytes-max 1048576
  "The most bytes of untracked files one `drgnx-cockpit-changed-files' reads to count their lines (shown as added);
the files past it show no count."
  :type 'natnum :group 'drgnx-cockpit)

(defcustom drgnx-cockpit-changed-files-max 500
  "The most files `drgnx-cockpit-changed-files' checks, and so lists; the rest are counted, as (:more N)."
  :type 'natnum :group 'drgnx-cockpit)

(declare-function drgnx-face-glyph "drgnx-face")
(defvar read-eval)                      ; so a let binds it dynamically in compiled code

(defun drgnx-cockpit--glyph (name unicode)
  "The glyph NAME (`drgnx-face-glyph', when the face is loaded), else UNICODE."
  (if (fboundp 'drgnx-face-glyph) (drgnx-face-glyph name) unicode))

(defun drgnx-cockpit--line (text &optional max)
  "TEXT as one line of at most MAX (200) characters."
  (let ((line (string-trim (replace-regexp-in-string "[[:cntrl:]]+" " " (format "%s" (or text ""))))))
    (truncate-string-to-width line (or max 200) nil nil "…")))

(defun drgnx-cockpit--remote-p (dir)
  "Whether DIR is a remote (TRAMP) name — by its syntax alone: no file handler runs, nothing connects."
  (and (stringp dir) (string-match-p "\\`/[^/|:]+[:|]" dir)))

;;;; Plan files the tracker has not scanned (read, never written)

(defvar drgnx-cockpit--plan-cache (make-hash-table :test #'equal)
  "Plan file → (MTIME TITLE ((N TITLE LINE)…)): a file's entry is replaced when its time changes; a 65th file
empties the cache first (it holds only the plans of jobs the tracker never scanned).")

(defun drgnx-cockpit--plan-file (file)
  "(TITLE ((N TITLE LINE)…)) of plan FILE from its `# ' title and `### Task N' headings, or nil (remote, unreadable).
Cached by modification time."
  (when (and (stringp file) (not (drgnx-cockpit--remote-p file)) (file-readable-p file))
    (let ((mtime (file-attribute-modification-time (file-attributes file))) (hit (gethash file drgnx-cockpit--plan-cache)))
      (if (and hit (equal (car hit) mtime)) (cdr hit)
        (let ((v (with-temp-buffer
                   (insert-file-contents file)
                   (goto-char (point-min))
                   (let ((title (file-name-base file)) (titled nil) (tasks nil) (line 1))
                     (while (not (eobp))
                       (cond ((and (not titled) (looking-at "^# \\(.+\\)$"))
                              (setq title (string-trim (match-string 1)) titled t))
                             ((looking-at "^### Task \\([0-9]+\\)[:.]? *\\(.*\\)$")
                              (push (list (string-to-number (match-string 1)) (string-trim (match-string 2)) line) tasks)))
                       (forward-line 1) (setq line (1+ line)))
                     (list title (nreverse tasks))))))
          (when (and (not hit) (>= (hash-table-count drgnx-cockpit--plan-cache) 64)) (clrhash drgnx-cockpit--plan-cache))   ; bounded
          (puthash file (cons mtime v) drgnx-cockpit--plan-cache)
          v)))))

;;;; The model

(defconst drgnx-cockpit--up '((derives . to) (implements . to) (assigned . from) (reviewed-by . from))
  "Edge kinds that make a tree: whether an edge's :to or its :from is the parent.  needs and blocks do not.")

(defun drgnx-cockpit--node (id kind title &rest props)
  "A model node: ID, KIND, TITLE and PROPS (:state :waiting :readonly :path :line :job :agent :reporting …)."
  (append (list :id id :kind kind :title title :state (plist-get props :state) :waiting (plist-get props :waiting)
                :readonly (plist-get props :readonly) :path (plist-get props :path) :line (plist-get props :line)
                :job (plist-get props :job) :agent (plist-get props :agent) :reporting (plist-get props :reporting))
          (cl-loop for (k v) on props by #'cddr
                   unless (memq k '(:state :waiting :readonly :path :line :job :agent :reporting)) append (list k v))))

(defun drgnx-cockpit--jobs ()
  "The jobs the model shows, newest first, with their tasks, dependencies and open ask cards — four queries, grouped
here: (JOBS . (TASKS DEPS CARDS)), JOBS ((ID TITLE PLAN STATUS DATA)…) — DATA the job's data as text when it marks a
task blocked (:blocked, task → reason), else nil — TASKS hash job → ((ID N TITLE STATUS AGENT)…) in order, DEPS
hash task → (DEP…), CARDS ((ID JOB TASK TITLE AT)…).  A done job only with `drgnx-cockpit-include-closed-jobs'."
  (let* ((db (drgnx-work-db))
         (open (if drgnx-cockpit-include-closed-jobs "" " where j.status is not 'done'"))
         (jobs (sqlite-select db (concat "select j.id, j.title, j.plan, j.status, case when instr(j.data, ':blocked (') > 0 then j.data end"
                                         " from job j" open " order by j.created desc, j.id")))
         (tasks (make-hash-table :test #'equal)) (deps (make-hash-table :test #'equal)))
    (pcase-dolist (`(,id ,job ,n ,title ,status ,agent)
                   (sqlite-select db (concat "select t.id, t.job, t.n, t.title, t.status, t.agent from jtask t join job j on j.id = t.job"
                                             open " order by t.job, t.n desc")))
      (push (list id n title status agent) (gethash job tasks)))
    (pcase-dolist (`(,task ,dep) (sqlite-select db (concat "select d.task, d.dep from jdep d join jtask t on t.id = d.task join job j on j.id = t.job"
                                                           open " order by d.task, d.dep desc")))
      (push dep (gethash task deps)))
    (list jobs tasks deps
          (sqlite-select db (concat "select c.id, c.job, c.task, c.title, c.at from card c join job j on j.id = c.job"
                                    " where c.state = 'open' and c.kind = 'ask'"
                                    (if drgnx-cockpit-include-closed-jobs "" " and j.status is not 'done'")
                                    " order by c.id")))))

(defconst drgnx-cockpit--life-sql "kind in ('start', 'stop') and coalesce(data, '') not like '(:turn t%'"
  "The events of an agent's life: its start and stop — not a turn's (the hub's turn events lead with :turn t).")

(defun drgnx-cockpit--life ()
  "Hash agent → \"start\" or \"stop\", whichever of its life's events (`drgnx-cockpit--life-sql') came last."
  (let ((h (make-hash-table :test #'equal)))
    (pcase-dolist (`(,agent ,kind)
                   (sqlite-select (drgnx-work-db) (concat "select agent, kind from event where id in
                                     (select max(id) from event where " drgnx-cockpit--life-sql " and agent is not null group by agent)")))
      (puthash agent kind h))
    h))

(defun drgnx-cockpit--status (s) (and s (format "%s" s)))

(cl-defun drgnx-cockpit-model (&key sessions silent)
  "The Work cockpit's model: (:nodes NODES :edges EDGES :agents AGENTS :questions QUESTIONS).
SESSIONS: the hub's session snapshots (`agents/list'), passed in.  SILENT: the agents
`drgnx-cockpit-silent-worktrees' found, when the caller has them.
A node: (:id :kind spec|plan|task|todo|agent|job|review :title :state :waiting BOOL :readonly BOOL :path :line :job
:agent :reporting native|job|outside|silent …).  An edge: (:from :to :kind implements|derives|needs|blocks|assigned|
reviewed-by).  A job's task is its plan's task `task:PLAN#N' (the job's state, agent and job on it); a plan task no
job runs, a spec, a plan and a board TODO are :readonly.  A node is :waiting while an open question is about it
\(`drgnx-coord-open-questions', an open ask card, a permission its session waits on).  AGENTS: (:id :name :reporting
:state :waiting :cwd :worktree :branch :base :job :task NODE :label …); an outside agent's task is its own :label,
never joined to a job's or a plan's.  QUESTIONS: the open questions, each with the :node it is about.  Then
`drgnx-cockpit-node-functions' add theirs."
  (let ((nodes (make-hash-table :test #'equal)) (order nil)
        (edges nil) (edge-seen (make-hash-table :test #'equal))
        (jt-node (make-hash-table :test #'equal))          ; job task id → its node
        (agents (make-hash-table :test #'equal)) (agent-order nil)
        (questions nil)
        (life (drgnx-cockpit--life))
        (jobs-data (drgnx-cockpit--jobs)))
    (cl-labels ((add (node) (unless (gethash (plist-get node :id) nodes) (push (plist-get node :id) order))
                  (puthash (plist-get node :id) node nodes))
                (put (id k v) (when-let* ((n (gethash id nodes))) (puthash id (plist-put n k v) nodes)))
                (edge (from to kind)
                  (let ((key (format "%s\0%s\0%s" from to kind)))
                    (unless (gethash key edge-seen)
                      (puthash key t edge-seen) (push (list :from from :to to :kind kind) edges))))
                (agent (id &rest props)
                  (let ((a (gethash id agents)))
                    (unless a (push id agent-order) (setq a (list :id id)))
                    (cl-loop for (k v) on props by #'cddr when (and v (not (plist-get a k))) do (setq a (plist-put a k v)))
                    (puthash id a agents)))
                (task-node (task)                       ; a job task id or a tracker node id → its node, if any
                  (and task (or (gethash task jt-node) (and (gethash task nodes) task)))))
      ;; the skeleton: specs, plans, tasks, TODOs
      (dolist (w (drgnx-work-nodes-of-kinds '(spec plan task todo)))
        (let ((id (plist-get w :id)) (kind (plist-get w :kind)))
          (add (drgnx-cockpit--node id kind (plist-get w :title)
                                    :state (if (plist-get w :merged) "merged" (plist-get w :status)) :readonly t
                                    :path (plist-get w :path) :line (plist-get w :line) :stale (plist-get w :stale)
                                    :parent (plist-get w :parent)))))
      (dolist (id order)
        (let ((n (gethash id nodes)))
          (when (and (memq (plist-get n :kind) '(task todo)) (plist-get n :parent) (gethash (plist-get n :parent) nodes))
            (edge id (plist-get n :parent) 'implements))))
      (pcase-dolist (`(,src ,dst) (sqlite-select (drgnx-work-db) "select src, dst from edge where kind = 'derives'"))
        (when (and (gethash src nodes) (gethash dst nodes)) (edge src dst 'derives)))
      ;; jobs (newest first: the newest job of a plan task is the one shown on it)
      (let ((deps nil) (status (make-hash-table :test #'equal)))
        (pcase-dolist (`(,jid ,jtitle ,planf ,jstatus ,jdata) (car jobs-data))
          (let* ((pid (and planf (concat "plan:" planf))) (jnode (concat "job:" jid))
                 ;; its tasks marked blocked (the Work graph's Mark Blocked): their own state while no agent works on them
                 (blocked (and jdata (plist-get (let ((read-eval nil)) (ignore-errors (car (read-from-string jdata)))) :blocked))))
            ;; a plan the tracker never scanned: its headings, read only
            (when (and planf (not (gethash pid nodes)))
              (pcase (drgnx-cockpit--plan-file planf)
                (`(,title ,tasks)
                 (add (drgnx-cockpit--node pid 'plan title :state "open" :readonly t :path planf :line 1))
                 (pcase-dolist (`(,n ,ttitle ,line) tasks)
                   (let ((tid (format "task:%s#%d" planf n)))
                     (add (drgnx-cockpit--node tid 'task ttitle :state "open" :readonly t :path planf :line line))
                     (edge tid pid 'implements))))))
            (add (drgnx-cockpit--node jnode 'job (or jtitle jid) :state jstatus :job jid :path planf))
            (when (gethash pid nodes) (edge jnode pid 'implements))
            (pcase-dolist (`(,tid ,n ,ttitle ,st ,holder) (gethash jid (nth 1 jobs-data)))
              (let ((pt (format "task:%s#%d" planf n)))
                (puthash tid st status)
                ;; a plan task a newer job runs already (it has a :job) is shown once, with that job
                (cond
                 ((and planf (gethash pt nodes) (not (plist-get (gethash pt nodes) :job)))
                  (puthash tid pt jt-node)
                  (put pt :job jid) (put pt :jtask tid) (put pt :state st) (put pt :agent holder) (put pt :readonly nil))
                 ((not (gethash pt nodes))
                  (puthash tid tid jt-node)
                  (add (drgnx-cockpit--node tid 'task ttitle :state st :job jid :agent holder :jtask tid))
                  (edge tid jnode 'implements)))
                (when-let* ((why (alist-get tid blocked nil nil #'equal)) (tn (gethash tid jt-node)))
                  (put tn :blocked why)
                  (when (member st '("ready" "pending")) (put tn :state "blocked")))
                (when (gethash tid jt-node)
                  (dolist (d (gethash tid (nth 2 jobs-data))) (push (list tid d) deps))
                  (when holder
                    (agent holder :reporting 'job :job jid :task (gethash tid jt-node))
                    (edge (gethash tid jt-node) (concat "agent:" holder) 'assigned))
                  (when (equal st "in-review")
                    (add (drgnx-cockpit--node (concat "review:" tid) 'review (format "review of %s" tid) :state "in-review" :job jid))
                    (edge (gethash tid jt-node) (concat "review:" tid) 'reviewed-by)))))))
        (pcase-dolist (`(,tid ,d) deps)
          (when-let* ((a (gethash tid jt-node)) (b (gethash d jt-node)))
            (edge a b 'needs)
            (unless (equal (gethash d status) "done") (edge b a 'blocks)))))
      ;; reviews: the last verdict of each job task
      (pcase-dolist (`(,task ,summary ,data)
                     (sqlite-select (drgnx-work-db) "select task, summary, data from event where id in
                                      (select max(id) from event where kind = 'review' and task is not null group by task)"))
        (when-let* ((tn (gethash task jt-node)))
          (let* ((rid (concat "review:" task))
                 (verdict (plist-get (and data (let ((read-eval nil)) (ignore-errors (car (read-from-string data))))) :verdict)))
            (unless (gethash rid nodes)
              (add (drgnx-cockpit--node rid 'review (format "review of %s" task) :state (drgnx-cockpit--status (or verdict "reviewed"))
                                        :summary summary :job (plist-get (gethash tn nodes) :job))))
            (edge tn rid 'reviewed-by))))
      ;; agents: the hub's sessions, the registry, silent worktrees
      (let ((rows (drgnx-coord-agents)))
        (dolist (s sessions)
          (let* ((id (plist-get s :id)) (tn (task-node (plist-get s :task))))
            (agent id :name (plist-get s :name) :reporting (if (plist-get s :job) 'job 'native) :session t
                   :state (drgnx-cockpit--status (plist-get s :status)) :cwd (plist-get s :cwd) :job (plist-get s :job) :task tn
                   :permissions (and (plist-get s :permissions) t))))
        (dolist (r rows)
          (let* ((id (plist-get r :id))
                 ;; a job's task agent, which the hub registers: its job's, shown only while its job is
                 (job-agent (equal (plist-get r :kind) "job"))
                 (jid (let ((tk (plist-get r :task))) (and job-agent (stringp tk) (string-match "\\`\\(.+\\)#[0-9]+\\'" tk) (match-string 1 tk))))
                 (outside (and (not job-agent) (not (gethash id agents)) (or (string-prefix-p "ext:" id) (plist-get r :kind)))))
            (unless (and job-agent (not (gethash id agents)) (not (and jid (gethash (concat "job:" jid) nodes))))
              (cond
               (job-agent (agent id :name (plist-get r :name) :reporting 'job :job jid :task (task-node (plist-get r :task))))
               (outside
                (let ((stopped (equal (gethash id life) "stop")))
                  (agent id :name (plist-get r :name) :reporting 'outside :kind (plist-get r :kind)
                         :state (if stopped "stopped" "reporting") :label (plist-get r :task)
                         :plan (when-let* ((p (plist-get r :plan)) (cwd (or (plist-get r :cwd) "/"))
                                           ((not (or (drgnx-cockpit--remote-p p) (drgnx-cockpit--remote-p cwd))))
                                           (pid (concat "plan:" (expand-file-name p cwd))))
                                 (and (gethash pid nodes) pid)))))
               (t (agent id :name (plist-get r :name) :reporting 'native :task (task-node (plist-get r :task)))))
              (agent id :cwd (plist-get r :cwd) :worktree (plist-get r :worktree) :branch (plist-get r :branch) :base (plist-get r :base)))))
        (dolist (a silent)
          (unless (plist-get a :error) (apply #'agent (plist-get a :id) (append (list :reporting 'silent) a)))))
      (dolist (id (reverse agent-order))
        (let* ((a (gethash id agents)) (nid (concat "agent:" id)))
          (unless (plist-get a :state) (setq a (plist-put a :state (if (equal (gethash id life) "stop") "stopped" "not running"))))
          (setq a (plist-put a :node nid))
          (puthash id a agents)
          (add (drgnx-cockpit--node nid 'agent (or (plist-get a :name) id) :state (plist-get a :state) :agent id
                                    :job (plist-get a :job) :reporting (plist-get a :reporting) :path (plist-get a :cwd)
                                    :label (plist-get a :label) :waiting (plist-get a :permissions)))
          (when (and (plist-get a :task) (not (eq (plist-get a :reporting) 'outside))) (edge (plist-get a :task) nid 'assigned))
          (when (plist-get a :plan) (edge (plist-get a :plan) nid 'assigned))))
      ;; questions: open escalations and ask cards, and ask cards opened again
      (let ((cards-asked nil))
        (dolist (q (drgnx-coord-open-questions))
          (let* ((tn (task-node (plist-get q :task)))
                 (an (let ((a (plist-get q :agent))) (and a (gethash a agents) (concat "agent:" a))))
                 (jn (and (plist-get q :job) (gethash (concat "job:" (plist-get q :job)) nodes) (concat "job:" (plist-get q :job))))
                 (node (or tn an jn)))
            (when (plist-get (plist-get q :data) :card) (push (plist-get (plist-get q :data) :card) cards-asked))
            (dolist (n (delq nil (list tn an (and (not (or tn an)) jn)))) (put n :waiting t))
            (push (plist-put (copy-sequence q) :node node) questions)))
        (pcase-dolist (`(,cid ,jid ,task ,title ,at) (nth 3 jobs-data))
          (unless (memql cid cards-asked)
            (let ((node (or (task-node task) (concat "job:" jid))))
              (put node :waiting t)
              (push (list :id nil :card cid :at at :job jid :task task :kind "question" :summary title :node node)
                    questions)))))
      (dolist (id agent-order)
        (let ((a (gethash id agents)))
          (puthash id (plist-put a :waiting (and (plist-get (gethash (concat "agent:" id) nodes) :waiting) t)) agents)))
      (let ((model (list :nodes (mapcar (lambda (id) (gethash id nodes)) (reverse order))
                         :edges (nreverse edges)
                         :agents (mapcar (lambda (id) (gethash id agents)) (reverse agent-order))
                         :questions (sort questions (lambda (a b) (< (or (plist-get a :at) 0) (or (plist-get b :at) 0)))))))
        ;; extensions add their nodes and edges
        (dolist (fn drgnx-cockpit-node-functions)
          (when (functionp fn)
            (condition-case err
                (let ((more (funcall fn model)))
                  (setq model (plist-put model :nodes (append (plist-get model :nodes) (plist-get more :nodes))))
                  (setq model (plist-put model :edges (append (plist-get model :edges) (plist-get more :edges)))))
              (error (message "drgnx cockpit: %S: %s" fn (error-message-string err))))))
        ;; only edges between nodes of the model
        (let ((ids (make-hash-table :test #'equal)))
          (dolist (n (plist-get model :nodes)) (puthash (plist-get n :id) t ids))
          (plist-put model :edges (seq-filter (lambda (e) (and (gethash (plist-get e :from) ids) (gethash (plist-get e :to) ids)))
                                              (plist-get model :edges))))))))

;;;; Filters

(defun drgnx-cockpit--parents (model)
  "Hash node id → its parents' ids (`drgnx-cockpit--up')."
  (let ((h (make-hash-table :test #'equal)))
    (dolist (e (plist-get model :edges))
      (pcase (alist-get (plist-get e :kind) drgnx-cockpit--up)
        ('to (push (plist-get e :to) (gethash (plist-get e :from) h)))
        ('from (push (plist-get e :from) (gethash (plist-get e :to) h)))))
    h))

(defun drgnx-cockpit-filter (model filter)
  "MODEL with only the nodes FILTER matches and their ancestors (and the edges, agents and questions among them).
FILTER: (:milestone STRING :agent ID :states (STATE…)), each optional, all must hold — a milestone matches a node
whose title or path, or one of its ancestors', contains it (any case); an agent matches its node and the tasks it
holds; states match a node's :state.  `drgnx-cockpit-filter-functions' may drop a node too."
  (let* ((parents (drgnx-cockpit--parents model))
         (byid (let ((h (make-hash-table :test #'equal))) (dolist (n (plist-get model :nodes)) (puthash (plist-get n :id) n h)) h))
         (milestone (plist-get filter :milestone)) (agent (plist-get filter :agent)) (states (plist-get filter :states))
         (named (make-hash-table :test #'equal))
         (keep (make-hash-table :test #'equal)))
    (cl-labels ((names-p (id seen)
                  (pcase (gethash id named 'unknown)
                    ('unknown
                     (let* ((n (gethash id byid))
                            (v (or (and n (seq-some (lambda (s) (and (stringp s) (string-match-p (regexp-quote milestone) s)))
                                                    (list (plist-get n :title) (plist-get n :path))))
                                   (seq-some (lambda (p) (and (not (member p seen)) (names-p p (cons id seen)))) (gethash id parents)))))
                       (puthash id (and v t) named)
                       v))
                    (v v)))
                (up (id) (unless (gethash id keep) (puthash id t keep) (mapc #'up (gethash id parents)))))
      (let ((case-fold-search t))
        (dolist (n (plist-get model :nodes))
          (when (and (or (null milestone) (names-p (plist-get n :id) nil))
                     (or (null agent) (equal (plist-get n :agent) agent))
                     (or (null states) (member (plist-get n :state) states))
                     (run-hook-with-args-until-failure 'drgnx-cockpit-filter-functions n filter))
            (up (plist-get n :id))))))
    (list :nodes (seq-filter (lambda (n) (gethash (plist-get n :id) keep)) (plist-get model :nodes))
          :edges (seq-filter (lambda (e) (and (gethash (plist-get e :from) keep) (gethash (plist-get e :to) keep))) (plist-get model :edges))
          :agents (seq-filter (lambda (a) (gethash (plist-get a :node) keep)) (plist-get model :agents))
          :questions (seq-filter (lambda (q) (gethash (plist-get q :node) keep)) (plist-get model :questions)))))

;;;; What happened, the timeline

(defun drgnx-cockpit--events (sql args)
  (mapcar #'drgnx-coord--event-plist (sqlite-select (drgnx-work-db) (format sql drgnx-coord--event-cols) args)))

(defun drgnx-cockpit--targeter ()
  "A function from an event to its target (:node ID :event ID): its task's node, else its agent's, else its job's."
  (let ((plans (make-hash-table :test #'equal)) (known (make-hash-table :test #'equal)))
    (pcase-dolist (`(,id ,plan) (sqlite-select (drgnx-work-db) "select id, plan from job")) (puthash id plan plans))
    (lambda (e)
      (let* ((task (plist-get e :task)) (job (plist-get e :job)) (agent (plist-get e :agent))
             (plan (and job (gethash job plans)))
             (n (and task (string-match "#\\([0-9]+\\)\\'" task) (string-to-number (match-string 1 task))))
             (pt (and plan n (format "task:%s#%d" plan n))))
        (list :node (cond ((and pt (eq t (with-memoization (gethash pt known)
                                           (if (or (drgnx-work-node pt) (assq n (cadr (drgnx-cockpit--plan-file plan)))) t 'no))))
                           pt)
                          (task task)
                          ((and agent (not (equal agent "user"))) (concat "agent:" agent))
                          (job (concat "job:" job)))
              :event (plist-get e :id))))))

(defun drgnx-cockpit--tests (data)
  "A test event's DATA as `12/12 ✓' (or `10/12 ⚠'), or nil when it carries no counts."
  (let ((passed (plist-get data :passed)) (failed (plist-get data :failed)))
    (cond ((and (natnump passed) (natnump failed))
           (format "%d/%d %s" passed (+ passed failed)
                   (if (zerop failed) (drgnx-cockpit--glyph 'ok "✓") (drgnx-cockpit--glyph 'warning "⚠"))))
          ((natnump passed) (format "%d passed" passed))
          ((natnump failed) (format "%d failed" failed)))))

(defun drgnx-cockpit--paths-count (data) (+ (length (plist-get data :paths)) (or (plist-get data :more) 0)))

(defun drgnx-cockpit--question-text (summary) (string-remove-prefix "[escalation] " (or summary "")))

(defun drgnx-cockpit--text (e)
  "Event E as one line of \"what happened\"."
  (let ((d (plist-get e :data)) (s (or (plist-get e :summary) "")))
    (drgnx-cockpit--line
     (pcase (plist-get e :kind)
       ("decision" (concat "decided " s))
       ("edit" (let* ((paths (plist-get d :paths)) (n (drgnx-cockpit--paths-count d)))
                 (concat (format "edited %d file%s" n (if (= n 1) "" "s"))
                         (if paths (concat ": " (string-join (mapcar #'file-name-nondirectory (seq-take paths 3)) ", ")
                                           (if (> n 3) ", …" ""))
                           "")
                         (if (or (string-empty-p s) (string-match-p "\\`[0-9]+ files?\\'" s)) "" (concat " — " s)))))
       ("test" (if-let* ((counts (drgnx-cockpit--tests d)))
                   (concat "tests " counts (if (plist-get d :command) (format " (%s)" (plist-get d :command)) ""))
                 (concat "tests: " s)))
       ("question" (concat "asks: " (drgnx-cockpit--question-text s)))
       ("answer" (concat "answered: " s))
       ("review" (concat "review: " s))
       (_ s)))))

(defun drgnx-cockpit-happened (agent &optional limit)
  "What AGENT did, one line per event — its own (decisions, edits with file counts, tests `12/12 ✓', questions,
claims, statuses) and the cards, questions and answers about the job tasks it holds — newest last, at most LIMIT
\(`drgnx-cockpit-happened-limit').  ((:at :kind :text :target (:node ID :event ID))…)."
  (let* ((limit (or limit drgnx-cockpit-happened-limit))
         (own (drgnx-cockpit--events "select %s from event where agent = ? order by id desc limit ?" (list agent limit)))
         (about (cl-loop for (task job) in (sqlite-select (drgnx-work-db) "select id, job from jtask where agent = ?" (list agent))
                         append (drgnx-cockpit--events
                                 "select %s from event where job = ? and task = ? and (agent is null or agent = 'user') order by id desc limit ?"
                                 (list job task limit))))
         (events (seq-take (sort (append own about) (lambda (a b) (> (plist-get a :id) (plist-get b :id)))) limit))
         (target (drgnx-cockpit--targeter)))
    (mapcar (lambda (e) (list :at (plist-get e :at) :kind (plist-get e :kind) :text (drgnx-cockpit--text e)
                              :target (funcall target e)))
            (nreverse events))))

(defun drgnx-cockpit--short-task (task)
  "TASK (`JOB#N') as `TN'."
  (if (and task (string-match "#\\([0-9]+\\)\\'" task)) (concat "T" (match-string 1 task)) (or task "")))

(defun drgnx-cockpit--label (e)
  "Event E as a timeline chip's label (at most 40 characters)."
  (let* ((d (plist-get e :data)) (s (or (plist-get e :summary) "")) (tk (drgnx-cockpit--short-task (plist-get e :task)))
         (who (or (and (not (equal (plist-get e :agent) "user")) (plist-get e :agent)) (plist-get e :job) "someone")))
    (drgnx-cockpit--line
     (string-trim
      (pcase (plist-get e :kind)
        ("status" (let ((st (plist-get d :status)))
                    (format "%s %s" tk (if (equal st "done") (drgnx-cockpit--glyph 'ok "✓") (or st "")))))
        ("claim" (format "%s claimed" tk))
        ("release" (format "%s released" tk))
        ("question" (format "%s asks you" who))
        ("answer" "answered")
        ("decision" (format "decision #%s" (or (plist-get d :n) "")))
        ("edit" (let ((n (drgnx-cockpit--paths-count d))) (format "%d file%s" n (if (= n 1) "" "s"))))
        ("test" (or (drgnx-cockpit--tests d) "tests"))
        ("review" (format "%s review: %s" tk (or (plist-get d :verdict) s)))
        ("card" (format "%s %s" tk (car (split-string s ":"))))
        ("job" (format "job %s" (or (plist-get d :status) "")))
        ("start" "started")
        ("stop" "stopped")
        (k (format "%s %s" tk k))))
     40)))

(cl-defun drgnx-cockpit-timeline (&key since)
  "Every agent's events after id SINCE (all when nil) as chips, oldest first — the newest `drgnx-cockpit-timeline-limit'.
A turn's start and stop (the hub's, data :turn t) are left out: an agent's life is its session's.
\((:id :at :agent :kind :label :target (:node ID :event ID))…)."
  (let ((target (drgnx-cockpit--targeter)))
    (mapcar (lambda (e) (list :id (plist-get e :id) :at (plist-get e :at) :agent (plist-get e :agent) :kind (plist-get e :kind)
                              :label (drgnx-cockpit--label e) :target (funcall target e)))
            (nreverse (drgnx-cockpit--events (concat "select %s from event where id > ? and not (kind in ('start', 'stop') and coalesce(data, '') like '(:turn t%%')"
                                                     " order by id desc limit ?")
                                             (list (or since 0) drgnx-cockpit-timeline-limit))))))

;;;; Where an agent's edits are

(defun drgnx-cockpit--dir (d)
  "D as a local folder name ending in a slash; a remote name comes back untouched (no file handler runs on it)."
  (cond ((not (stringp d)) nil) ((drgnx-cockpit--remote-p d) d) (t (file-name-as-directory (expand-file-name d)))))

(defun drgnx-cockpit--linked-worktree-p (dir)
  "Whether DIR is (inside) a linked git worktree: its top has a `.git' file, not a directory."
  (when-let* ((dir) ((not (drgnx-cockpit--remote-p dir))) (top (locate-dominating-file dir ".git")))
    (file-regular-p (expand-file-name ".git" top))))

(defun drgnx-cockpit--reported-paths (agent dir)
  "The paths AGENT's `edit' events name, relative to DIR (those outside it left out), first reported first.  None for
a remote DIR, and a remote root or path is left out: no remote name is expanded."
  (let ((paths nil))
    (dolist (e (and (not (drgnx-cockpit--remote-p dir)) (drgnx-coord-events :agent agent :kinds '("edit"))))
      (let ((root (or (plist-get (plist-get e :data) :root) dir)))
        (dolist (p (and (stringp root) (not (drgnx-cockpit--remote-p root)) (plist-get (plist-get e :data) :paths)))
          (when (and (stringp p) (not (drgnx-cockpit--remote-p p)))
            (let ((abs (expand-file-name p (file-name-as-directory root))))
              (when (string-prefix-p dir abs) (push (file-relative-name abs dir) paths)))))))
    (delete-dups (nreverse paths))))

(defun drgnx-cockpit-edit-source (agent &optional sessions)
  "Where AGENT's edits are: (:kind :dir :base :merge-base :paths :own-worktree :stopped …), or nil for an agent unknown.
AGENT: an id, or an agent of the model (`drgnx-cockpit-model').  SESSIONS: the hub's snapshots — an agent of a job or
a native session not among them is :stopped.
- a job's agent: its task worktree; the base its registry row names, else the job branch (`job/ID') where it forked
  (:merge-base t);
- a native session: its cwd; the base its registry row names, else the HEAD its first event carries (:head);
- an outside agent: its registered worktree (or cwd) and base, and the paths it reported (:paths, relative to :dir);
- a silent worktree (`silent:DIR'): the worktree and its merge-base with the main branch.
:own-worktree: the folder is the agent's alone (a job's task worktree, or a linked worktree no other agent works in).
:kind is `job', `native', `outside' or `silent'.  A job's agent also has :job and :task (its job task's id) and
:job-worktree t when :dir is the worktree drgnx makes for that task (`.claude/worktrees/JOB-N/' of the job's repository,
from its jtask row)."
  (let* ((plist (and (consp agent) agent)) (id (if plist (plist-get plist :id) agent))
         (session (seq-find (lambda (s) (equal (plist-get s :id) id)) sessions))
         (exited (and session (equal (drgnx-cockpit--status (plist-get session :status)) "exited")))
         (row (and (stringp id) (drgnx-coord-agent id)))
         ;; its job task: the session's own, else the one it holds and works on (else the last one it held)
         (jt (and (stringp id)
                  (car (or (and (plist-get session :task)
                                (sqlite-select (drgnx-work-db) "select id, job, n from jtask where id = ?" (list (plist-get session :task))))
                           (sqlite-select (drgnx-work-db) "select id, job, n from jtask where agent = ?
                                                           order by status in ('claimed', 'running', 'needs-input', 'in-review') desc, n desc
                                                           limit 1"
                                          (list id))))))
         (life (and (stringp id) (caar (sqlite-select (drgnx-work-db) (concat "select kind from event where agent = ? and " drgnx-cockpit--life-sql " order by id desc limit 1") (list id)))))
         (others (lambda (dir) (seq-some (lambda (r) (and (not (equal (plist-get r :id) id))
                                                          (member dir (mapcar #'drgnx-cockpit--dir (delq nil (list (plist-get r :cwd) (plist-get r :worktree)))))))
                                         (drgnx-coord-agents)))))
    (cond
     ((not (stringp id)) nil)
     ((or (eq (plist-get plist :reporting) 'silent) (string-prefix-p "silent:" id))
      (list :kind 'silent :dir (drgnx-cockpit--dir (or (plist-get plist :worktree) (substring id (length "silent:"))))
            :base (or (plist-get plist :base) (car drgnx-cockpit-main-branches)) :merge-base t :paths nil
            :own-worktree t :stopped nil))
     ((or jt (and session (plist-get session :job)))
      (let* ((job (or (nth 1 jt) (plist-get session :job)))
             (n (or (nth 2 jt) (let ((tk (plist-get session :task))) (and tk (string-match "#\\([0-9]+\\)\\'" tk) (string-to-number (match-string 1 tk))))))
             (repo (plist-get (drgnx-coord-job job) :repo))
             (made (and (stringp repo) n (not (drgnx-cockpit--remote-p repo))
                        (drgnx-cockpit--dir (expand-file-name (format ".claude/worktrees/%s-%d/" job n) repo))))
             (dir (or made (drgnx-cockpit--dir (plist-get session :cwd)))))
        (list :kind 'job :job job :task (car jt) :job-worktree (and made jt t) :dir dir :base (or (plist-get row :base) (concat "job/" job)) :merge-base (not (plist-get row :base)) :paths nil
              :own-worktree t :stopped (if sessions (or (null session) exited) (equal life "stop")))))
     ((and row (not session) (or (string-prefix-p "ext:" id) (and (plist-get row :kind) (not (equal (plist-get row :kind) "job")))))
      (let ((dir (drgnx-cockpit--dir (or (plist-get row :worktree) (plist-get row :cwd)))))
        (list :kind 'outside :dir dir :base (plist-get row :base) :merge-base nil
              :paths (and dir (drgnx-cockpit--reported-paths id dir))
              :own-worktree (and dir (drgnx-cockpit--linked-worktree-p dir) (not (funcall others dir)) t)
              :stopped (equal life "stop"))))
     ((or session row)
      (let ((dir (drgnx-cockpit--dir (or (plist-get session :cwd) (plist-get row :cwd))))
            (first (plist-get (car (drgnx-coord-events :agent id :limit 1)) :data)))
        (list :kind 'native :dir dir :base (or (plist-get row :base) (plist-get first :head) (plist-get first :base)) :merge-base nil :paths nil
              :own-worktree (and dir (drgnx-cockpit--linked-worktree-p dir) (not (funcall others dir))
                                 (not (seq-some (lambda (s) (and (not (equal (plist-get s :id) id))
                                                                 (equal (drgnx-cockpit--dir (plist-get s :cwd)) dir)))
                                                sessions))
                                 t)
              :stopped (cond (session exited) (sessions t) (t (equal life "stop")))))))))

;;;; git, asynchronously

(defun drgnx-cockpit--call (fn &rest args)
  "FN with ARGS; an error is a message, never a prompt or a signal out of a sentinel or timer."
  (condition-case err (apply fn args)
    (error (message "drgnx cockpit: %s" (error-message-string err)) nil)))

(defun drgnx-cockpit--later (fn &rest args)
  (run-at-time 0 nil (lambda () (apply #'drgnx-cockpit--call fn args))))

(defun drgnx-cockpit--git-timed-out (p)
  "The deadline of the git process P (`drgnx-cockpit--git'): mark it timed out and end it."
  (when (process-live-p p) (process-put p :timed-out t) (delete-process p)))

(defun drgnx-cockpit--git (dir args done &optional limit)
  "Run git ARGS in DIR as a process of its own and return at once.  DONE gets, from the sentinel, (:exit N :out TEXT
:err TEXT); (:too-large N) when its output passed LIMIT bytes (it is ended then, having read N: at most one chunk
more); or (:error MESSAGE) when DIR is remote (no TRAMP call is made) or not a folder, git cannot start, or it ran
past `drgnx-cockpit-git-timeout'.  git takes pathspecs literally, no optional locks, and never asks."
  (cond
   ((not (stringp dir)) (drgnx-cockpit--later done (list :error (format "no folder to run git in: %S" dir))))
   ((drgnx-cockpit--remote-p dir)
    (drgnx-cockpit--later done (list :error (format "%s is remote: the cockpit never runs git there" dir))))
   ((not (file-directory-p dir)) (drgnx-cockpit--later done (list :error (format "%s is not a folder" dir))))
   (t
    (let ((out (generate-new-buffer " *drgnx-cockpit-git*" t))
          (errbuf (generate-new-buffer " *drgnx-cockpit-git-err*" t)))
      (condition-case err
          (let* ((default-directory (file-name-as-directory dir))
                 (process-environment (append '("GIT_OPTIONAL_LOCKS=0" "GIT_TERMINAL_PROMPT=0") process-environment))
                 (p (make-process
                     :name "drgnx-cockpit-git" :buffer out :stderr errbuf :noquery t :connection-type 'pipe
                     :coding 'utf-8-unix :command (append '("git" "-c" "core.quotePath=false" "--literal-pathspecs") args)
                     :filter
                     (lambda (p s)
                       (let ((n (+ (or (process-get p :bytes) 0) (string-bytes s))))
                         (process-put p :bytes n)
                         (cond ((and limit (> n limit)) (process-put p :too-large n) (delete-process p))
                               ((buffer-live-p (process-buffer p))
                                (with-current-buffer (process-buffer p) (goto-char (point-max)) (insert s))))))
                     :sentinel
                     (lambda (p _)
                       (unless (process-live-p p)
                         (drgnx-timer-cancel (cons 'cockpit-git-timeout p))
                         (let ((r (cond
                                   ((process-get p :too-large) (list :too-large (process-get p :too-large)))
                                   ((process-get p :timed-out)
                                    (list :error (format "git %s did not finish in %s s" (car args) drgnx-cockpit-git-timeout)))
                                   (t (list :exit (process-exit-status p)
                                            :out (if (buffer-live-p out) (with-current-buffer out (buffer-string)) "")
                                            :err (if (buffer-live-p errbuf) (with-current-buffer errbuf (string-trim (buffer-string))) ""))))))
                           (when (buffer-live-p out) (kill-buffer out))
                           (when (buffer-live-p errbuf) (let ((kill-buffer-query-functions nil)) (kill-buffer errbuf)))
                           (drgnx-cockpit--call done r)))))))
            (when-let* ((ep (get-buffer-process errbuf))) (set-process-sentinel ep #'ignore))
            (drgnx-timer-start (cons 'cockpit-git-timeout p) drgnx-cockpit-git-timeout #'drgnx-cockpit--git-timed-out
                               :args (list p) :owner p)
            (ignore-errors (process-send-eof p))
            p)
        (error
         ;; git could not start: its buffers go too (and a stderr pipe made before the failure with them)
         (let ((kill-buffer-query-functions nil))
           (dolist (b (list out errbuf)) (when (buffer-live-p b) (kill-buffer b))))
         (drgnx-cockpit--later done (list :error (error-message-string err)))))))))

(defun drgnx-cockpit--failed (r)
  "nil when git's answer R went well, else (:error MESSAGE) — or R itself when it is (:too-large N)."
  (cond ((plist-get r :error) r)
        ((plist-get r :too-large) r)
        ((not (eql 0 (plist-get r :exit)))
         (list :error (let ((e (plist-get r :err))) (if (string-empty-p e) (format "git exited %s" (plist-get r :exit)) e))))))

(defun drgnx-cockpit--base-args (source)
  (let ((base (plist-get source :base)))
    (cond ((null base) (list "HEAD")) ((plist-get source :merge-base) (list "--merge-base" base)) (t (list base)))))

(defun drgnx-cockpit--unquote (name)
  "NAME as git wrote it, C-quoted (`\"t\\tab\"') when it holds a quote, a backslash or a control character (octal
escapes are bytes, read as UTF-8), else as it is."
  (if (not (and (> (length name) 1) (string-prefix-p "\"" name) (string-suffix-p "\"" name))) name
    (let ((s (encode-coding-string (substring name 1 -1) 'utf-8)) (i 0) (bytes nil))
      (while (< i (length s))
        (let ((c (aref s i)))
          (if (or (/= c ?\\) (>= (1+ i) (length s))) (progn (push c bytes) (setq i (1+ i)))
            (let ((e (aref s (1+ i))))
              (if (and (<= ?0 e ?7) (<= (+ i 4) (length s)))
                  (progn (push (string-to-number (substring s (1+ i) (+ i 4)) 8) bytes) (setq i (+ i 4)))
                (push (pcase e (?a ?\a) (?b ?\b) (?t ?\t) (?n ?\n) (?v ?\v) (?f ?\f) (?r ?\r) (_ e)) bytes)
                (setq i (+ i 2)))))))
      (decode-coding-string (apply #'unibyte-string (nreverse bytes)) 'utf-8))))

(defun drgnx-cockpit--numstat (text)
  "`git diff -z --numstat --summary' TEXT as ((:file :added :removed :status)…): NUL-ended records, then the summary's
lines (`create mode', `delete mode'), whose names git C-quotes even under -z (`drgnx-cockpit--unquote')."
  (let* ((end (cl-position ?\0 text :from-end t))
         (files (cl-loop for rec in (and end (split-string (substring text 0 end) "\0" t))
                         when (string-match "\\`\\([0-9]+\\|-\\)\t\\([0-9]+\\|-\\)\t\\(\\(?:.\\|\n\\)*\\)\\'" rec)
                         collect (list :file (match-string 3 rec)
                                       :added (and (not (equal (match-string 1 rec) "-")) (string-to-number (match-string 1 rec)))
                                       :removed (and (not (equal (match-string 2 rec) "-")) (string-to-number (match-string 2 rec)))
                                       :status 'modified)))
         (byname (make-hash-table :test #'equal)))
    (dolist (f files) (puthash (plist-get f :file) f byname))
    (dolist (l (and end (split-string (substring text (1+ end)) "\n" t)))
      (when (string-match "\\` \\(create\\|delete\\) mode [0-7]+ \\(.*\\)\\'" l)
        (when-let* ((f (gethash (drgnx-cockpit--unquote (match-string 2 l)) byname)))
          (plist-put f :status (if (equal (match-string 1 l) "create") 'new 'deleted)))))
    files))

(defun drgnx-cockpit--file-ok (dir file &optional truedir memo)
  "Whether FILE (relative to DIR) may be shown: t for a regular file whose true name lies inside DIR, `missing' when
nothing is there (a deleted file), nil for anything else — a remote name, outside DIR, a device, FIFO, socket or
folder, a link out of DIR, a dangling one or a loop.  Decided from names and attributes only (lstat, readlink), with
no file name handler: nothing is opened, and no remote name is expanded, also one a link leads to.  TRUEDIR: DIR's
true name, when the caller has it; MEMO: a hash table of the true names of the folders seen, when the caller checks
many files.  Open FILE by its true name (`drgnx-file-truename'), never as named: `find-file' follows its links again,
with handlers on."
  (when (and (stringp dir) (stringp file) (not (drgnx-cockpit--remote-p dir)) (not (drgnx-cockpit--remote-p file)))
    (let* ((file-name-handler-alist nil)            ; the names and links are the agent's (`drgnx-file-truename')
           (dir (file-name-as-directory (expand-file-name dir))) (abs (expand-file-name file dir)))
      (when (string-prefix-p dir abs)
        (let ((attrs (file-attributes abs)) (truedir (or truedir (drgnx-cockpit--true-dir dir))))   ; nil: a loop
          (cond ((null truedir) nil)
                ((null attrs) 'missing)
                ((stringp (file-attribute-type attrs))              ; a link: where it leads
                 (let ((true (drgnx-file-truename abs))) (and true (string-prefix-p truedir true) (file-regular-p true) t)))
                ((not (eq (aref (file-attribute-modes attrs) 0) ?-)) nil)    ; a folder, device, FIFO or socket
                ;; a regular file (lstat: its own name is no link) inside DIR when its folder truly is
                (t (let* ((parent (file-name-directory abs))
                          (true (if memo (with-memoization (gethash parent memo) (drgnx-cockpit--true-dir parent))
                                  (drgnx-cockpit--true-dir parent))))
                     (and true (string-prefix-p truedir true) t)))))))))

(defun drgnx-cockpit--lines (file)
  "FILE's line count, read into the current buffer (emptied first; the caller checked its size), or nil when it cannot
be read."
  (ignore-errors
    (erase-buffer)
    (insert-file-contents-literally file)
    (count-lines (point-min) (point-max))))

(defun drgnx-cockpit-changed-files (source callback)
  "Ask git, asynchronously, what SOURCE (`drgnx-cockpit-edit-source') changed: `git diff --numstat' against its base
\(its merge-base when :merge-base), only its :paths when it has them, plus its untracked files.  Returns at once; CALLBACK
gets, from the sentinel, ((:file :added :removed :status new|modified|deleted)…), (:too-large BYTES) when git's
list of changed or untracked files passes `drgnx-cockpit-diff-max-bytes' (git is ended then), or (:error MESSAGE).
Only regular files inside the folder are listed (`drgnx-cockpit--file-ok'): never a device, FIFO, socket or a link out
of it; those refused are counted, as (:refused N), so that a change is never taken for none.  At most
`drgnx-cockpit-changed-files-max' are checked, those of them that may be shown listed, then (:more N) for the rest;
untracked files' lines are counted until `drgnx-cockpit-count-bytes-max' bytes are read (after that
:added is nil)."
  (let ((dir (plist-get source :dir)) (paths (plist-get source :paths)))
    (if (not (stringp dir))
        (drgnx-cockpit--later callback (list :error (format "no folder to compare: %S" dir)))
      (drgnx-cockpit--git
       dir (append '("diff" "-z" "--numstat" "--summary" "--no-renames") (drgnx-cockpit--base-args source) '("--") paths)
       (lambda (r)
         (if-let* ((bad (drgnx-cockpit--failed r))) (funcall callback bad)
           (let ((files (drgnx-cockpit--numstat (plist-get r :out))))
             (drgnx-cockpit--git
              dir (append '("ls-files" "-z" "--others" "--exclude-standard" "--") paths)
              (lambda (r2)
                (if-let* ((bad (drgnx-cockpit--failed r2))) (funcall callback bad)
                  (funcall callback (drgnx-cockpit--changed dir files (split-string (plist-get r2 :out) "\0" t)))))
              drgnx-cockpit-diff-max-bytes))))
       drgnx-cockpit-diff-max-bytes))))

(defun drgnx-cockpit--changed (dir files untracked)
  "FILES (`drgnx-cockpit--numstat') and the UNTRACKED names of DIR as `drgnx-cockpit-changed-files' answers them.
DIR is local (git ran there) and the names are git's own, relative to it: no file handler is needed."
  (let* ((file-name-handler-alist nil)
         (truedir (file-name-as-directory (file-truename dir)))
         (known (make-hash-table :test #'equal)) (new (make-hash-table :test #'equal)) (memo (make-hash-table :test #'equal))
         (budget drgnx-cockpit-count-bytes-max) (checked 0) (refused 0) (out nil))
    (dolist (f files) (puthash (plist-get f :file) t known))
    (let ((extra nil))
      (dolist (f untracked)
        (unless (gethash f known) (puthash f t new) (push (list :file f :added nil :removed 0 :status 'new) extra)))
      (setq files (append files (nreverse extra))))
    (with-temp-buffer
      (while (and files (< checked drgnx-cockpit-changed-files-max))   ; checked, shown or not: a bounded sentinel
        (let* ((f (pop files)) (ok (drgnx-cockpit--file-ok dir (plist-get f :file) truedir memo)))
          (setq checked (1+ checked))
          (when ok
            (when (and (eq ok t) (> budget 0) (gethash (plist-get f :file) new))
              (let* ((abs (expand-file-name (plist-get f :file) dir)) (size (file-attribute-size (file-attributes abs))))
                (when (and size (<= size budget))
                  (setq budget (- budget size))
                  (plist-put f :added (drgnx-cockpit--lines abs)))))
            (push f out))
          (unless ok (setq refused (1+ refused))))))
    ;; the rest only counted (not checked one by one)
    (nconc (nreverse out) (and (> refused 0) (list (list :refused refused))) (and files (list (list :more (length files)))))))

(defun drgnx-cockpit-file-diff (source file callback)
  "Ask git, asynchronously, for FILE's diff in SOURCE (`drgnx-cockpit-edit-source') against its base — an untracked
file against nothing.  Returns at once; CALLBACK gets, from the sentinel or a timer, the diff text (empty when FILE did
not change), (:too-large BYTES) when the file or its diff is over `drgnx-cockpit-diff-max-bytes' (git is ended as soon
as its output passes it), or (:error MESSAGE) — for a remote folder, or a FILE that is not a regular file inside the
folder (`drgnx-cockpit--file-ok': a device, FIFO, socket, a link out of it), without running git or reading it."
  (let* ((dir (plist-get source :dir))
         (ok (drgnx-cockpit--file-ok dir file))
         (size (and (eq ok t) (file-attribute-size (file-attributes (expand-file-name file dir)))))
         (limit drgnx-cockpit-diff-max-bytes))
    (cond
     ((or (not (stringp dir)) (drgnx-cockpit--remote-p dir))
      (drgnx-cockpit--later callback (list :error (format "%S is not a local folder: the cockpit never runs git there" dir))))
     ((null ok) (drgnx-cockpit--later callback (list :error (format "%s is not a regular file inside %s" file dir))))
     ((and size (> size limit)) (drgnx-cockpit--later callback (list :too-large size)))
     (t
      (drgnx-cockpit--git
       dir (append '("diff" "--no-renames") (drgnx-cockpit--base-args source) (list "--" file))
       (lambda (r)
         (cond
          ((drgnx-cockpit--failed r) (funcall callback (drgnx-cockpit--failed r)))
          ((not (string-empty-p (plist-get r :out))) (funcall callback (plist-get r :out)))
          ((eq ok 'missing) (funcall callback ""))
          (t (drgnx-cockpit--git
              dir (list "ls-files" "--" file)
              (lambda (r2)
                (cond ((drgnx-cockpit--failed r2) (funcall callback (drgnx-cockpit--failed r2)))
                      ((not (string-empty-p (string-trim (plist-get r2 :out)))) (funcall callback ""))   ; tracked, unchanged
                      (t (drgnx-cockpit--git
                          dir (list "diff" "--no-index" "--" "/dev/null" file)
                          (lambda (r3)
                            (if (or (plist-get r3 :error) (plist-get r3 :too-large) (not (memql (plist-get r3 :exit) '(0 1))))
                                (funcall callback (or (drgnx-cockpit--failed r3) (list :error "git diff failed")))
                              (funcall callback (plist-get r3 :out))))
                          limit))))))))
       limit)))))

;;;; Worktrees nobody reports from

(defun drgnx-cockpit--porcelain (text)
  "`git worktree list --porcelain' TEXT as ((:path DIR :head SHA :branch NAME :bare BOOL :prunable BOOL)…)."
  (let ((out nil) (cur nil))
    (dolist (l (append (split-string text "\n") '("")))
      (cond ((string-empty-p l) (when cur (push cur out)) (setq cur nil))
            ((string-prefix-p "worktree " l) (setq cur (list :path (file-name-as-directory (substring l 9)))))
            ((string-prefix-p "HEAD " l) (setq cur (plist-put cur :head (substring l 5))))
            ((string-prefix-p "branch " l) (setq cur (plist-put cur :branch (string-remove-prefix "refs/heads/" (substring l 7)))))
            ((equal l "bare") (setq cur (plist-put cur :bare t)))
            ((string-prefix-p "prunable" l) (setq cur (plist-put cur :prunable t)))))
    (nreverse out)))

(defconst drgnx-cockpit--git-jobs 3 "The most git processes `drgnx-cockpit-silent-worktrees' runs at a time.")

(defun drgnx-cockpit--true-dir (d)
  "D's true name as a directory name, with no file name handler (an agent names its folders); nil for a remote one."
  (when-let* ((true (and d (not (drgnx-cockpit--remote-p d)) (drgnx-file-truename d))))
    (let ((file-name-handler-alist nil)) (file-name-as-directory true))))

(defun drgnx-cockpit--taken (sessions)
  "The folders an agent works in: registered agents' cwd and worktree, SESSIONS' cwd, every job's worktrees."
  (delq nil (mapcar #'drgnx-cockpit--true-dir
                    (append (cl-loop for r in (drgnx-coord-agents) append (list (plist-get r :cwd) (plist-get r :worktree)))
                            (mapcar (lambda (s) (plist-get s :cwd)) sessions)
                            ;; one query: each job with each of its task numbers (a job without tasks once, with nil)
                            (cl-loop for (job repo n) in (sqlite-select (drgnx-work-db) "select j.id, j.repo, t.n from job j left join jtask t on t.job = j.id
                                                                                         where j.repo is not null")
                                     unless (drgnx-cockpit--remote-p repo)
                                     collect (expand-file-name (format ".claude/worktrees/%s/" job) repo)
                                     and when n collect (expand-file-name (format ".claude/worktrees/%s-%d/" job n) repo))))))

(defun drgnx-cockpit--ledger (main wt)
  "(PLAN-ID . LEDGER) the work tracker has for worktree WT (a `branch' node of it, from a ledger), of the repository
whose main checkout is MAIN; nil when it has none."
  (let* ((dir (directory-file-name (plist-get wt :path)))
         (bid (and (plist-get wt :branch) (format "branch:%s/.git:%s" (directory-file-name main) (plist-get wt :branch))))
         (branch (seq-find (lambda (b) (or (equal (plist-get b :id) bid)
                                           (equal (and (plist-get b :path) (directory-file-name (plist-get b :path))) dir)))
                           (drgnx-work-nodes 'branch)))
         (plan (and branch (car (car (drgnx-work-edges-to (plist-get branch :id) 'on-branch))))))
    (when plan
      (let ((ledgers (mapcar #'car (drgnx-work-edges-to plan 'ledger-of))))
        (cons plan (or (seq-find (lambda (l) (string-prefix-p (file-name-as-directory dir) l)) ledgers) (car ledgers)))))))

(defun drgnx-cockpit-silent-worktrees (roots callback &optional sessions)
  "Find, asynchronously, the git worktrees under ROOTS (repositories) that have changes and no agent working in them
\(no registered agent, none of SESSIONS, no job's worktree): `git worktree list --porcelain' per root, then each
candidate's changes against its merge-base with the main branch (`drgnx-cockpit-main-branches').  Returns at once;
CALLBACK gets, from a sentinel, a list of agents (:id \"silent:DIR\" :name :reporting silent :state \"not reporting\"
:cwd :worktree :branch :base :changed N :plan PLAN-ID :ledger FILE) — :changed nil when git's list of its files was
too large; the plan and ledger when the work tracker has one for its branch — and (:error MESSAGE :root ROOT) for a
root git could not read (a remote one is never touched).
At most `drgnx-cockpit--git-jobs' git processes run at a time."
  (let ((taken (drgnx-cockpit--taken sessions)) (found nil) (pending (length roots)) (queue nil) (running 0))
    (cl-labels ((root-done () (when (zerop (cl-decf pending))
                                (funcall callback (sort found (lambda (a b) (string< (or (plist-get a :id) "") (or (plist-get b :id) "")))))))
                ;; a JOB runs its git processes one after another and calls its RELEASE when its last one ended
                (run (job) (if (< running drgnx-cockpit--git-jobs) (progn (cl-incf running) (funcall job #'release))
                             (setq queue (nconc queue (list job)))))
                (release () (cl-decf running) (when queue (run (pop queue))))
                (candidate (main base w on-done)
                  (lambda (rel)
                    (let ((d (plist-get w :path)))
                      (drgnx-cockpit-changed-files
                       (list :dir d :base base :merge-base (and base t))
                       (lambda (files)
                         (unwind-protect
                             (when (and files (or (plist-get files :too-large) (not (keywordp (car files)))))
                               (let ((ledger (drgnx-cockpit--ledger main w)))
                                 (push (list :id (concat "silent:" (directory-file-name d))
                                             :name (or (plist-get w :branch) (file-name-nondirectory (directory-file-name d)))
                                             :reporting 'silent :state "not reporting" :cwd d :worktree d
                                             :branch (plist-get w :branch) :base base
                                             :changed (and (not (plist-get files :too-large))
                                                           (cl-loop for f in files sum (if (plist-get f :file) 1 (or (plist-get f :more) 0))))
                                             :plan (car ledger) :ledger (cdr ledger))
                                       found)))
                           (funcall rel) (funcall on-done)))))))
                (root-job (root)
                  (lambda (rel)
                    (drgnx-cockpit--git
                     root '("worktree" "list" "--porcelain")
                     (lambda (r)
                       (if-let* ((bad (drgnx-cockpit--failed r)))
                           (progn (push (list :error (plist-get bad :error) :root root) found) (funcall rel) (root-done))
                         (let* ((wts (drgnx-cockpit--porcelain (plist-get r :out))) (main (plist-get (car wts) :path))
                                (cands (seq-filter (lambda (w)
                                                     (let ((d (plist-get w :path)))
                                                       (and (not (plist-get w :bare)) (not (plist-get w :prunable)) (file-directory-p d)
                                                            (let ((td (drgnx-cockpit--true-dir d)))
                                                              (not (seq-some (lambda (tk) (string-prefix-p td tk)) taken))))))
                                                   (cdr wts))))
                           (if (null cands) (progn (funcall rel) (root-done))
                             (drgnx-cockpit--git
                              root (append '("for-each-ref" "--format=%(refname:short)")
                                           (mapcar (lambda (b) (concat "refs/heads/" b)) drgnx-cockpit-main-branches))
                              (lambda (r2)
                                (funcall rel)
                                (let* ((have (and (not (drgnx-cockpit--failed r2)) (split-string (plist-get r2 :out) "\n" t)))
                                       (base (seq-find (lambda (b) (member b have)) drgnx-cockpit-main-branches))
                                       (left (length cands)))
                                  (dolist (w cands)
                                    (run (candidate main base w (lambda () (when (zerop (cl-decf left)) (root-done)))))))))))))))))
      (if (null roots) (drgnx-cockpit--later callback nil)
        (dolist (root roots) (run (root-job root)))))))

(provide 'drgnx-cockpit-model)
;;; drgnx-cockpit-model.el ends here
