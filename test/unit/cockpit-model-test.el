;;; cockpit-model-test.el --- batch tests: the Work cockpit's model of specs, plans, tasks, agents, jobs, reviews -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)                                ; `drgnx-dir': each test file runs in an Emacs of its own
(load (expand-file-name "test/fixtures/cockpit-fixture" drgnx-dir) nil t)   ; a project, a job, worktrees, events
(require 'drgnx-cockpit-model)

(defun drgnx-cockpit-model-test--node (model id)
  (seq-find (lambda (n) (equal (plist-get n :id) id)) (plist-get model :nodes)))

(defun drgnx-cockpit-model-test--edge-p (model from to kind)
  (seq-some (lambda (e) (and (equal (plist-get e :from) from) (equal (plist-get e :to) to) (eq (plist-get e :kind) kind)))
            (plist-get model :edges)))

(defun drgnx-cockpit-model-test--agent (model id)
  (seq-find (lambda (a) (equal (plist-get a :id) id)) (plist-get model :agents)))

(ert-deftest drgnx-cockpit-model/spec-plan-task-agent-chain ()
  (drgnx-cockpit-fixture-with
    (let* ((m (drgnx-cockpit-model :sessions sessions))
           (s (concat "spec:" spec)) (p (concat "plan:" plan)) (t2 (format "task:%s#2" plan)) (t5 (format "task:%s#5" plan)))
      (should (eq (plist-get (drgnx-cockpit-model-test--node m s) :kind) 'spec))
      (let ((pn (drgnx-cockpit-model-test--node m p)))
        (should (eq (plist-get pn :kind) 'plan))
        (should (equal (plist-get pn :title) "M99 — the plan"))
        (should (equal (plist-get pn :path) plan)))
      (should (drgnx-cockpit-model-test--edge-p m p s 'derives))
      (dolist (n '(1 2 3 4 5 6))
        (let ((tn (drgnx-cockpit-model-test--node m (format "task:%s#%d" plan n))))
          (should (eq (plist-get tn :kind) 'task))
          (should (equal (plist-get tn :line) (plan-line n)))
          (should (drgnx-cockpit-model-test--edge-p m (plist-get tn :id) p 'implements))))
      ;; the job task is the plan task: one node, the job's state
      (let ((tn (drgnx-cockpit-model-test--node m t2)))
        (should (equal (plist-get tn :job) "jx"))
        (should (equal (plist-get tn :state) "running"))
        (should (equal (plist-get tn :agent) "s-1")))
      (should-not (drgnx-cockpit-model-test--node m "jx#2"))
      (should (eq (plist-get (drgnx-cockpit-model-test--node m "job:jx") :kind) 'job))
      (should (drgnx-cockpit-model-test--edge-p m "job:jx" p 'implements))
      ;; who is on what: a job's agent, a native chat on a plan task, an outside agent with its own label
      (should (drgnx-cockpit-model-test--edge-p m t2 "agent:s-1" 'assigned))
      (should (eq (plist-get (drgnx-cockpit-model-test--node m "agent:s-1") :reporting) 'job))
      (should (drgnx-cockpit-model-test--edge-p m t5 "agent:s-2" 'assigned))
      (should (eq (plist-get (drgnx-cockpit-model-test--node m "agent:s-2") :reporting) 'native))
      (let ((o (drgnx-cockpit-model-test--node m "agent:ext:claude-code:42")))
        (should (eq (plist-get o :reporting) 'outside))
        (should (equal (plist-get o :label) "jx#4")))
      ;; an outside agent's task is a label of its own: never joined to a job or plan task
      (should-not (seq-some (lambda (e) (equal (plist-get e :to) "agent:ext:claude-code:42")) (plist-get m :edges)))
      (should (equal (plist-get (drgnx-cockpit-model-test--agent m "ext:claude-code:42") :task) nil))
      ;; every edge joins two nodes of the model
      (dolist (e (plist-get m :edges))
        (should (drgnx-cockpit-model-test--node m (plist-get e :from)))
        (should (drgnx-cockpit-model-test--node m (plist-get e :to)))))))

(ert-deftest drgnx-cockpit-model/needs-and-blocks-from-job-deps ()
  (drgnx-cockpit-fixture-with
    (let ((t2 (format "task:%s#2" plan)) (t3 (format "task:%s#3" plan)) (t4 (format "task:%s#4" plan)))
      (let ((m (drgnx-cockpit-model :sessions sessions)))
        (should (drgnx-cockpit-model-test--edge-p m t3 t2 'needs))
        (should (drgnx-cockpit-model-test--edge-p m t4 t2 'needs))
        (should (drgnx-cockpit-model-test--edge-p m t2 t3 'blocks))
        (should (drgnx-cockpit-model-test--edge-p m t2 t4 'blocks))
        (should-not (drgnx-cockpit-model-test--edge-p m t3 t4 'needs)))
      ;; done: still needed, no longer blocking
      (drgnx-work-fixture-as-hub (drgnx-coord-force-status "jx#2" "done" "s-1"))
      (let ((m (drgnx-cockpit-model :sessions sessions)))
        (should (drgnx-cockpit-model-test--edge-p m t3 t2 'needs))
        (should-not (drgnx-cockpit-model-test--edge-p m t2 t3 'blocks))
        (should (equal (plist-get (drgnx-cockpit-model-test--node m t3) :state) "ready"))))))

(ert-deftest drgnx-cockpit-model/plan-only-tasks-are-read-only ()
  (drgnx-cockpit-fixture-with
    (let ((m (drgnx-cockpit-model :sessions sessions)))
      (dolist (n '(1 5 6))
        (let ((tn (drgnx-cockpit-model-test--node m (format "task:%s#%d" plan n))))
          (should (plist-get tn :readonly))
          (should-not (plist-get tn :job))))
      (dolist (n '(2 3 4))
        (let ((tn (drgnx-cockpit-model-test--node m (format "task:%s#%d" plan n))))
          (should-not (plist-get tn :readonly))
          (should (equal (plist-get tn :job) "jx"))))
      ;; the ledger (in worktree wt-b) says task 1 is complete
      (should (equal (plist-get (drgnx-cockpit-model-test--node m (format "task:%s#1" plan)) :state) "done")))
    ;; a job whose plan the tracker never scanned: its tasks come from the plan file's headings, read only
    (let* ((other (concat repo "elsewhere/q.md")))
      (drgnx-cockpit-fixture-write other "# Q plan\n\n### Task 1: first\n\n### Task 2: second\n")
      (let ((attrs (file-attributes other)))
        (drgnx-work-fixture-as-hub
          (drgnx-coord-job-create :id "jq" :title "Q" :plan other :repo repo :tasks '((:n 2 :title "second" :role "implement"))))
        (let ((m (drgnx-cockpit-model)))
          (should (plist-get (drgnx-cockpit-model-test--node m (format "task:%s#1" other)) :readonly))
          (should (equal (plist-get (drgnx-cockpit-model-test--node m (format "task:%s#1" other)) :line) 3))
          (should (equal (plist-get (drgnx-cockpit-model-test--node m (format "task:%s#2" other)) :job) "jq"))
          (should (equal (plist-get (drgnx-cockpit-model-test--node m (concat "plan:" other)) :title) "Q plan")))
        ;; never written
        (should (equal (file-attribute-modification-time (file-attributes other)) (file-attribute-modification-time attrs)))))))

(ert-deftest drgnx-cockpit-model/the-board-is-one-more-source ()
  (drgnx-cockpit-fixture-with
    (let ((read nil))
      (cl-letf* ((orig (symbol-function 'insert-file-contents))
                 ((symbol-function 'insert-file-contents)
                  (lambda (file &rest args) (push (expand-file-name file) read) (apply orig file args))))
        (let* ((m (drgnx-cockpit-model :sessions sessions))
               (todo (seq-find (lambda (n) (eq (plist-get n :kind) 'todo)) (plist-get m :nodes))))
          (should todo)
          (should (equal (plist-get todo :title) "Write the docs"))
          (should (equal (plist-get todo :path) board))
          (should (plist-get todo :readonly))
          (should (drgnx-cockpit-model-test--edge-p m (plist-get todo :id) (concat "plan:" plan) 'implements))))
      ;; the model reads nothing outside the fixture: never ~/org/board.org
      (should (seq-every-p (lambda (f) (string-prefix-p root f)) read))
      (should (equal drgnx-projects-board-file board)))))

(ert-deftest drgnx-cockpit-model/waiting-from-questions-and-cards ()
  (drgnx-cockpit-fixture-with
    (let* ((m (drgnx-cockpit-model :sessions sessions))
           (t3 (format "task:%s#3" plan)) (t4 (format "task:%s#4" plan)))
      ;; s-1 escalated: its node waits
      (should (plist-get (drgnx-cockpit-model-test--node m "agent:s-1") :waiting))
      (should (plist-get (drgnx-cockpit-model-test--agent m "s-1") :waiting))
      ;; the ask card on jx#3 was answered, then reopened: it waits again (no question event is open for it)
      (should (plist-get (drgnx-cockpit-model-test--node m t3) :waiting))
      (should-not (plist-get (drgnx-cockpit-model-test--node m t4) :waiting))
      (should-not (plist-get (drgnx-cockpit-model-test--node m "agent:s-2") :waiting))
      (should (= (length (plist-get m :questions)) 2))
      (should (member t3 (mapcar (lambda (q) (plist-get q :node)) (plist-get m :questions))))
      ;; a permission the session waits on is waiting too
      (let ((m2 (drgnx-cockpit-model :sessions (list (append (list :permissions '((:id 1 :title "write a.el"))) (cadr sessions))))))
        (should (plist-get (drgnx-cockpit-model-test--node m2 "agent:s-2") :waiting)))
      ;; answered: no longer waiting
      (let ((q (seq-find (lambda (q) (equal (plist-get q :agent) "s-1")) (plist-get m :questions))))
        (drgnx-work-fixture-as-hub
          (drgnx-coord-event-add :agent "user" :job "jx" :kind "answer" :summary "this way" :data (list :question (plist-get q :id)))))
      (let ((card (plist-get (car (drgnx-coord-cards "jx" "open")) :id)))
        (drgnx-work-fixture-as-hub (drgnx-coord-card-settle card "bar")))
      (let ((m (drgnx-cockpit-model :sessions sessions)))
        (should-not (plist-get (drgnx-cockpit-model-test--node m "agent:s-1") :waiting))
        (should-not (plist-get (drgnx-cockpit-model-test--node m t3) :waiting))
        (should-not (plist-get m :questions))))))

(ert-deftest drgnx-cockpit-model/filter-keeps-ancestors ()
  (drgnx-cockpit-fixture-with
    (let* ((m (drgnx-cockpit-model :sessions sessions))
           (s (concat "spec:" spec)) (p (concat "plan:" plan)) (t2 (format "task:%s#2" plan)) (t3 (format "task:%s#3" plan))
           (ids (lambda (model) (mapcar (lambda (n) (plist-get n :id)) (plist-get model :nodes)))))
      ;; one agent: its node, its task, the plan, the spec — nothing else
      (let ((f (drgnx-cockpit-filter m '(:agent "s-1"))))
        (should (equal (sort (funcall ids f) #'string<) (sort (list "agent:s-1" t2 p s) #'string<)))
        (should (drgnx-cockpit-model-test--edge-p f t2 "agent:s-1" 'assigned))
        (should-not (drgnx-cockpit-model-test--edge-p f t2 t3 'blocks))
        (should (equal (mapcar (lambda (a) (plist-get a :id)) (plist-get f :agents)) '("s-1"))))
      ;; states: the ready ones and their ancestors
      (let ((f (drgnx-cockpit-filter m '(:states ("pending")))))
        (should (member t3 (funcall ids f)))
        (should (member p (funcall ids f)))
        (should-not (member t2 (funcall ids f))))
      ;; a milestone: what lies under a plan or spec that names it
      (should (member t3 (funcall ids (drgnx-cockpit-filter m '(:milestone "m99")))))
      (should-not (funcall ids (drgnx-cockpit-filter m '(:milestone "M42"))))
      ;; the filter hook drops nodes
      (let ((drgnx-cockpit-filter-functions (list (lambda (n _f) (not (eq (plist-get n :kind) 'todo))))))
        (should-not (seq-find (lambda (n) (eq (plist-get n :kind) 'todo)) (plist-get (drgnx-cockpit-filter m nil) :nodes))))
      ;; a node kind added by the hook
      (let* ((drgnx-cockpit-node-functions
              (list (lambda (model) (list :nodes (list (list :id "pr:1" :kind 'pr :title "PR 1"))
                                          :edges (list (list :from "pr:1" :to (concat "plan:" plan) :kind 'implements))))))
             (m (drgnx-cockpit-model :sessions sessions)))
        (should (drgnx-cockpit-model-test--node m "pr:1"))
        (should (drgnx-cockpit-model-test--edge-p m "pr:1" p 'implements))))))

(ert-deftest drgnx-cockpit-model/happened-is-one-line-per-event ()
  ;; the batch terminal is not UTF-8 in a C locale (CI): the glyphs below are the Unicode ones
  (cl-letf (((symbol-function 'drgnx-ui-ascii-frame-p) (lambda (&optional _f) nil)))
    (drgnx-cockpit-fixture-with
      (drgnx-work-fixture-as-hub
        (drgnx-coord-event-add :agent "s-1" :job "jx" :task "jx#2" :kind "test" :summary "fail"
                               :data '(:command "make test" :passed 10 :failed 2)))
      (let* ((lines (drgnx-cockpit-happened "s-1")) (texts (mapcar (lambda (l) (plist-get l :text)) lines)))
        (should (equal (mapcar (lambda (l) (plist-get l :kind)) lines)
                       '("claim" "status" "decision" "edit" "test" "question" "test")))
        (dolist (l lines)
          (should (stringp (plist-get l :text)))
          (should-not (string-match-p "\n" (plist-get l :text)))
          (should (<= (length (plist-get l :text)) 200))
          (should (numberp (plist-get l :at))))
        (should (string-match-p "the parser" (nth 2 texts)))
        (should (string-match-p "2 files" (nth 3 texts)))
        (should (string-match-p "a\\.el" (nth 3 texts)))
        (should (string-match-p "12/12 ✓" (nth 4 texts)))
        (should (string-match-p "which way" (nth 5 texts)))
        (should-not (string-match-p "\\[escalation\\]" (nth 5 texts)))
        (should (string-match-p "10/12" (nth 6 texts)))
        ;; a job task's events lead to its node
        (should (equal (plist-get (plist-get (nth 1 lines) :target) :node) (format "task:%s#2" plan)))
        ;; newest last, at most LIMIT
        (should (equal (mapcar (lambda (l) (plist-get l :kind)) (drgnx-cockpit-happened "s-1" 2)) '("question" "test"))))
      ;; the timeline: every agent's events as chips, oldest first, after SINCE
      (let* ((chips (drgnx-cockpit-timeline)) (last-id (plist-get (car (last chips)) :id)))
        (should (> (length chips) 10))
        (should (equal (sort (mapcar (lambda (c) (plist-get c :at)) chips) #'<) (mapcar (lambda (c) (plist-get c :at)) chips)))
        (dolist (c chips) (should (stringp (plist-get c :label))) (should (<= (length (plist-get c :label)) 40)))
        (should (seq-find (lambda (c) (equal (plist-get c :label) "T2 running")) chips))
        (should (seq-find (lambda (c) (and (equal (plist-get c :kind) "question") (string-match-p "asks you" (plist-get c :label)))) chips))
        (should-not (drgnx-cockpit-timeline :since last-id))
        (drgnx-work-fixture-as-hub (drgnx-coord-force-status "jx#2" "done" "s-1"))
        (should (equal (mapcar (lambda (c) (plist-get c :label)) (drgnx-cockpit-timeline :since last-id)) '("T2 ✓")))))))

(ert-deftest drgnx-cockpit-model/edit-sources-per-kind-of-agent ()
  (drgnx-cockpit-fixture-with
    ;; a job's agent: its task worktree, the job branch where it forked
    (let ((src (drgnx-cockpit-edit-source "s-1" sessions)))
      (should (equal (plist-get src :dir) tree))
      (should (equal (plist-get src :base) "job/jx"))
      (should (eq (plist-get src :kind) 'job))
      (should (equal (plist-get src :task) "jx#2"))
      (should (plist-get src :job-worktree))                     ; the worktree drgnx makes for jx#2
      (should (plist-get src :merge-base))
      (should (plist-get src :own-worktree))
      (should-not (plist-get src :stopped)))
    ;; gone from the hub: stopped
    (should (plist-get (drgnx-cockpit-edit-source "s-1" (cdr sessions)) :stopped))
    ;; a native session: its cwd, the HEAD at its first event
    (let ((src (drgnx-cockpit-edit-source "s-2" sessions)))
      (should (equal (plist-get src :dir) repo))
      (should (equal (plist-get src :base) sha))
      (should (eq (plist-get src :kind) 'native))
      (should-not (plist-get src :merge-base))
      (should-not (plist-get src :own-worktree)))
    ;; an outside agent: its registered folder and base, the paths it reported
    (let ((src (drgnx-cockpit-edit-source "ext:claude-code:42")))
      (should (equal (plist-get src :dir) wt-a))
      (should (equal (plist-get src :base) sha))
      (should (equal (plist-get src :paths) '("README" "new.txt")))
      (should (eq (plist-get src :kind) 'outside))
      (should (plist-get src :own-worktree))
      (should-not (plist-get src :stopped)))
    (drgnx-work-fixture-as-hub (drgnx-coord-event-add :agent "ext:claude-code:42" :kind "stop" :summary "ended"))
    (should (plist-get (drgnx-cockpit-edit-source "ext:claude-code:42") :stopped))
    ;; a silent worktree: the worktree and its merge-base with main
    (let ((src (drgnx-cockpit-edit-source (concat "silent:" (directory-file-name wt-b)))))
      (should (equal (plist-get src :dir) wt-b))
      (should (equal (plist-get src :base) "main"))
      (should (eq (plist-get src :kind) 'silent))
      (should (plist-get src :merge-base))
      (should (plist-get src :own-worktree)))
    (should-not (drgnx-cockpit-edit-source "nobody"))))

(ert-deftest drgnx-cockpit-model/silent-worktrees-are-found ()
  (drgnx-cockpit-fixture-with
    (let (got)
      (drgnx-cockpit-silent-worktrees (list repo) (lambda (agents) (setq got (list agents))) sessions)
      (should-not got)                                  ; nothing waited for in the caller
      (should (drgnx-cockpit-fixture-wait (lambda () got)))
      (let ((agents (car got)))
        ;; wt-a has an outside agent registered in it; the main checkout is the user's; wt-b is silent
        (should (= (length agents) 1))
        (let ((a (car agents)))
          (should (equal (plist-get a :id) (concat "silent:" (directory-file-name wt-b))))
          (should (eq (plist-get a :reporting) 'silent))
          (should (equal (plist-get a :branch) "wt-b"))
          (should (equal (plist-get a :base) "main"))
          (should (equal (plist-get a :plan) (concat "plan:" plan)))
          (should (string-suffix-p "progress.md" (plist-get a :ledger)))
          (should (> (plist-get a :changed) 0))
          ;; it joins the model when given
          (let ((m (drgnx-cockpit-model :sessions sessions :silent agents)))
            (should (eq (plist-get (drgnx-cockpit-model-test--node m (concat "agent:" (plist-get a :id))) :reporting) 'silent))
            (should (drgnx-cockpit-model-test--edge-p m (concat "plan:" plan) (concat "agent:" (plist-get a :id)) 'assigned))))))
    ;; a remote root: an error entry, and no file handler ever runs on its name
    (let (got)
      (let ((file-name-handler-alist (list (cons "\\`/[^/|:]+:" #'drgnx-cockpit-model-test--trap))))
        (drgnx-cockpit-silent-worktrees '("/ssh:somehost:/x/") (lambda (agents) (setq got (list agents))))
        (should (drgnx-cockpit-fixture-wait (lambda () got) 2)))
      (should (plist-get (caar got) :error)))))

(defun drgnx-cockpit-model-test--trap (op &rest args)
  "A file handler that must never run: a remote name reached one (OP on ARGS)."
  (error "A file handler ran: %S %S" op args))

(ert-deftest drgnx-cockpit-model/remote-names-are-never-expanded ()
  (drgnx-cockpit-fixture-with
    (let ((remote "/ssh:somehost:/srv/proj") files diff)
      (drgnx-work-fixture-as-hub
        (drgnx-coord-agent-register :id "ext:zed:7" :kind "zed" :name "Zed" :cwd remote :worktree remote :base sha
                                    :plan "docs/plans/p.md")
        (drgnx-coord-event-add :agent "ext:zed:7" :kind "edit" :summary "1 file" :data (list :root remote :paths '("a.el"))))
      (let ((file-name-handler-alist (list (cons "\\`/[^/|:]+:" #'drgnx-cockpit-model-test--trap)))
            (sessions (append sessions (list (list :id "s-9" :name "far" :cwd (concat remote "/") :task "jx#9" :status 'idle)))))
        (let ((m (drgnx-cockpit-model :sessions sessions)))
          (should (eq (plist-get (drgnx-cockpit-model-test--node m "agent:ext:zed:7") :reporting) 'outside))
          (should (drgnx-cockpit-model-test--node m "agent:s-9")))
        (let ((src (drgnx-cockpit-edit-source "ext:zed:7")))
          (should (equal (plist-get src :dir) remote))
          (should-not (plist-get src :paths))
          (should-not (plist-get src :own-worktree))
          (drgnx-cockpit-changed-files src (lambda (r) (setq files (list r))))
          (drgnx-cockpit-file-diff src "a.el" (lambda (r) (setq diff (list r)))))
        (should (equal (plist-get (drgnx-cockpit-edit-source "s-9" sessions) :dir) (concat remote "/")))
        (should (drgnx-cockpit-fixture-wait (lambda () (and files diff)) 2)))
      (should (plist-get (car files) :error))
      (should (plist-get (car diff) :error))
      ;; no folder at all: an error answer, not a signal
      (let (r)
        (drgnx-cockpit-changed-files (list :dir nil) (lambda (x) (setq r (list x))))
        (should (drgnx-cockpit-fixture-wait (lambda () r) 2))
        (should (plist-get (car r) :error))))))

(ert-deftest drgnx-cockpit-model/a-deleted-big-file-stops-at-the-cap ()
  (drgnx-cockpit-fixture-with
    (let ((big (concat wt-a "big.txt")))
      (with-temp-file big (dotimes (i 40000) (insert (format "line %06d of a big file\n" i))))   ; about 1 MB
      (drgnx-cockpit-fixture-git wt-a "add" "big.txt")
      (drgnx-cockpit-fixture-git wt-a "commit" "-q" "-m" "big")
      (delete-file big)
      (let ((drgnx-cockpit-diff-max-bytes 100000) diff)
        (drgnx-cockpit-file-diff (list :dir wt-a :base "HEAD") "big.txt" (lambda (r) (setq diff (list r))))
        (should (drgnx-cockpit-fixture-wait (lambda () diff)))
        (let ((n (plist-get (car diff) :too-large)))
          (should n)
          (should (> n 100000))
          ;; git was ended as soon as its output passed the cap: one chunk more at most
          (should (<= n (+ 100000 (max read-process-output-max 65536)))))))))

(ert-deftest drgnx-cockpit-model/many-untracked-files-never-block ()
  (drgnx-cockpit-fixture-with
    (let ((text (make-string 2047 ?x)) (took nil) files)
      (make-directory (concat wt-a "many") t)
      (dotimes (i 1000) (write-region (concat text "\n") nil (format "%smany/f%04d.txt" wt-a i) nil 'silent))
      (advice-add 'drgnx-cockpit--changed :around
                  (lambda (f &rest args) (let ((t0 (float-time))) (prog1 (apply f args) (setq took (- (float-time) t0)))))
                  '((name . drgnx-cockpit-model-test--time)))
      (unwind-protect
          (let ((drgnx-cockpit-count-bytes-max 10240))
            (drgnx-cockpit-changed-files (list :dir wt-a :base sha) (lambda (r) (setq files (list r))))
            (should (drgnx-cockpit-fixture-wait (lambda () files) 20)))
        (advice-remove 'drgnx-cockpit--changed 'drgnx-cockpit-model-test--time))
      (let* ((r (car files)) (listed (seq-filter (lambda (f) (plist-get f :file)) r)))
        (should (= (length listed) drgnx-cockpit-changed-files-max))
        (should (equal (car (last r)) (list :more (- 1002 drgnx-cockpit-changed-files-max))))
        ;; lines counted while the byte budget lasts (5 files of 2 KB), none after
        (should (= (seq-count (lambda (f) (plist-get f :added)) (seq-filter (lambda (f) (string-prefix-p "many/" (plist-get f :file))) listed))
                   5))
        (should (< took 0.1))))))

(ert-deftest drgnx-cockpit-model/closed-jobs-only-when-asked ()
  (drgnx-cockpit-fixture-with
    (drgnx-work-fixture-as-hub
      (drgnx-coord-job-create :id "jold" :title "old" :plan plan :repo repo :tasks '((:n 6 :title "task 6" :role "implement")))
      (drgnx-coord-job-set "jold" :status "done"))
    (should-not (drgnx-cockpit-model-test--node (drgnx-cockpit-model :sessions sessions) "job:jold"))
    (should-not (plist-get (drgnx-cockpit-model-test--node (drgnx-cockpit-model :sessions sessions) (format "task:%s#6" plan)) :job))
    (let* ((drgnx-cockpit-include-closed-jobs t) (m (drgnx-cockpit-model :sessions sessions)))
      (should (drgnx-cockpit-model-test--node m "job:jold"))
      (should (equal (plist-get (drgnx-cockpit-model-test--node m (format "task:%s#6" plan)) :job) "jold"))
      ;; the open job still has its tasks
      (should (equal (plist-get (drgnx-cockpit-model-test--node m (format "task:%s#2" plan)) :job) "jx")))))

(ert-deftest drgnx-cockpit-model/changed-files-and-diff-are-async ()
  (drgnx-cockpit-fixture-with
    (let ((made 0) files diff remote)
      (cl-letf* ((orig (symbol-function 'make-process))
                 ((symbol-function 'make-process) (lambda (&rest args) (cl-incf made) (apply orig args)))
                 ((symbol-function 'call-process) (lambda (&rest _) (error "call-process in the caller")))
                 ((symbol-function 'process-file) (lambda (&rest _) (error "process-file in the caller"))))
        (let ((src (drgnx-cockpit-edit-source "ext:claude-code:42")))
          (drgnx-cockpit-changed-files src (lambda (r) (setq files (list r))))
          (drgnx-cockpit-file-diff src "README" (lambda (r) (setq diff (list r))))
          (drgnx-cockpit-changed-files (list :dir "/ssh:somehost:/x/" :base "HEAD") (lambda (r) (setq remote (list r)))))
        (should (> made 0))
        (should-not files) (should-not diff)            ; the answers come later, from the sentinel
        (should (drgnx-cockpit-fixture-wait (lambda () (and files diff remote)))))
      (let ((r (car files)))
        (should (equal (seq-find (lambda (f) (equal (plist-get f :file) "README")) r)
                       '(:file "README" :added 1 :removed 0 :status modified)))
        (should (equal (seq-find (lambda (f) (equal (plist-get f :file) "new.txt")) r)
                       '(:file "new.txt" :added 1 :removed 0 :status new)))
        (should (= (length r) 2)))
      (should (string-match-p "^\\+more$" (car diff)))
      (should (plist-get (car remote) :error)))
    ;; the silent worktree, against its merge-base with main: a committed new file and an untracked ledger
    (let (files)
      (drgnx-cockpit-changed-files (drgnx-cockpit-edit-source (concat "silent:" (directory-file-name wt-b)))
                                   (lambda (r) (setq files (list r))))
      (should (drgnx-cockpit-fixture-wait (lambda () files)))
      (should (equal (seq-find (lambda (f) (equal (plist-get f :file) "b.txt")) (car files))
                     '(:file "b.txt" :added 1 :removed 0 :status new)))
      (should (seq-find (lambda (f) (string-suffix-p "progress.md" (plist-get f :file))) (car files))))
    ;; an untracked file's diff
    (let (diff)
      (drgnx-cockpit-file-diff (drgnx-cockpit-edit-source "ext:claude-code:42") "new.txt" (lambda (r) (setq diff (list r))))
      (should (drgnx-cockpit-fixture-wait (lambda () diff)))
      (should (string-match-p "^\\+new$" (car diff))))))

(ert-deftest drgnx-cockpit-model/only-regular-files-inside-and-a-size-cap ()
  (drgnx-cockpit-fixture-with
    ;; a link to a device, a link out of the worktree, a FIFO: never listed, never read
    (drgnx-cockpit-fixture-write (concat root "secret.txt") "secret\n")
    (make-symbolic-link "/dev/zero" (concat wt-a "zero"))
    (make-symbolic-link (concat root "secret.txt") (concat wt-a "key"))
    (call-process "mkfifo" nil nil nil (concat wt-a "pipe"))
    (drgnx-cockpit-fixture-write (concat wt-a "big.txt") (make-string 300 ?x))
    (let ((src (list :dir wt-a :base sha)) files diffs)
      (drgnx-cockpit-changed-files src (lambda (r) (setq files (list r))))
      (should (drgnx-cockpit-fixture-wait (lambda () files)))
      (should (equal (sort (delq nil (mapcar (lambda (f) (plist-get f :file)) (car files))) #'string<) '("README" "big.txt" "new.txt")))
      ;; …but counted: the merge gate must not take them for no change
      (should (<= 2 (or (seq-some (lambda (f) (plist-get f :refused)) (car files)) 0) 3))   ; zero, key (git may skip the FIFO)
      (let ((drgnx-cockpit-diff-max-bytes 200))
        (dolist (f '("zero" "key" "pipe" "../../../../secret.txt" "big.txt" "README"))
          (drgnx-cockpit-file-diff src f (lambda (r) (push (cons f r) diffs))))
        (should (drgnx-cockpit-fixture-wait (lambda () (= (length diffs) 6)))))
      (dolist (f '("zero" "key" "pipe" "../../../../secret.txt"))
        (should (plist-get (cdr (assoc f diffs)) :error)))
      (should (equal (cdr (assoc "big.txt" diffs)) '(:too-large 300)))
      (should (string-match-p "^\\+more$" (cdr (assoc "README" diffs))))
      ;; a diff over the cap is too large too, though the file is small
      (let ((drgnx-cockpit-diff-max-bytes 20) diff)
        (drgnx-cockpit-file-diff src "README" (lambda (r) (setq diff (list r))))
        (should (drgnx-cockpit-fixture-wait (lambda () diff)))
        (should (plist-get (car diff) :too-large))))))

(ert-deftest drgnx-cockpit-model/changed-files-checks-at-most-the-cap ()
  (drgnx-cockpit-fixture-with
    ;; 20 links out of the worktree (never shown) come before a regular file: only the cap's worth is checked
    (drgnx-cockpit-fixture-write (concat root "secret.txt") "secret\n")
    (dotimes (i 20) (make-symbolic-link (concat root "secret.txt") (format "%sa-link-%02d" wt-a i)))
    (let ((checked 0) files)
      (advice-add 'drgnx-cockpit--file-ok :before (lambda (&rest _) (cl-incf checked)) '((name . drgnx-cockpit-model-test--count)))
      (unwind-protect
          (let ((drgnx-cockpit-changed-files-max 5))
            (drgnx-cockpit-changed-files (list :dir wt-a :base sha) (lambda (r) (setq files (list r))))
            (should (drgnx-cockpit-fixture-wait (lambda () files))))
        (advice-remove 'drgnx-cockpit--file-ok 'drgnx-cockpit-model-test--count))
      (should (<= checked 5))
      (should (plist-get (car (last (car files))) :more)))))

(ert-deftest drgnx-cockpit-model/git-answers-once-however-often-its-sentinel-runs ()
  ;; macOS reports a process ended in its filter twice (the kill, then the exit); the second must say nothing
  (drgnx-cockpit-fixture-with
    (let* ((calls 0)
           (p (drgnx-cockpit--git wt-a '("--version") (lambda (_) (cl-incf calls)))))
      (should (drgnx-cockpit-fixture-wait (lambda () (> calls 0))))
      (funcall (process-sentinel p) p "finished\n")
      (funcall (process-sentinel p) p "exited abnormally with code 1\n")
      (should (= calls 1)))))

(ert-deftest drgnx-cockpit-model/changed-files-listing-is-capped-and-answers-once ()
  (drgnx-cockpit-fixture-with
    (dotimes (i 200) (write-region "x\n" nil (format "%suntracked-file-with-a-long-name-%04d.txt" wt-a i) nil 'silent))
    (let ((calls 0) r)
      (let ((drgnx-cockpit-diff-max-bytes 1000))
        (drgnx-cockpit-changed-files (list :dir wt-a :base sha) (lambda (x) (cl-incf calls) (setq r x)))
        (should (drgnx-cockpit-fixture-wait (lambda () r)))
        (drgnx-test-pause 0.5))          ; a second answer would come now
      (should (plist-get r :too-large))
      (should (= calls 1)))
    ;; a diff over the cap: one answer too
    (let ((big (concat wt-a "big.txt")) (calls 0) r)
      (with-temp-file big (dotimes (i 20000) (insert (format "line %06d of a big file\n" i))))
      (drgnx-cockpit-fixture-git wt-a "add" "big.txt")
      (drgnx-cockpit-fixture-git wt-a "commit" "-q" "-m" "big")
      (delete-file big)
      (let ((drgnx-cockpit-diff-max-bytes 1000))
        (drgnx-cockpit-file-diff (list :dir wt-a :base "HEAD") "big.txt" (lambda (x) (cl-incf calls) (setq r x)))
        (should (drgnx-cockpit-fixture-wait (lambda () r)))
        (drgnx-test-pause 0.5))
      (should (plist-get r :too-large))
      (should (= calls 1)))))

(ert-deftest drgnx-cockpit-model/summary-names-are-unquoted ()
  ;; git C-quotes the names on its --summary lines, even under -z
  (let ((files (drgnx-cockpit--numstat
                (concat "1\t0\ta\"b\0" "1\t0\tt\tab\0" "1\t0\t\001x\0" "0\t1\tü.txt\0"
                        " create mode 100644 \"a\\\"b\"\n" " create mode 100644 \"t\\tab\"\n"
                        " create mode 100644 \"\\001x\"\n" " delete mode 100644 \"\\303\\274.txt\"\n"))))
    (should (equal (mapcar (lambda (f) (cons (plist-get f :file) (plist-get f :status))) files)
                   '(("a\"b" . new) ("t\tab" . new) ("\001x" . new) ("ü.txt" . deleted))))))

(ert-deftest drgnx-cockpit-model/a-git-that-cannot-start-leaves-no-buffers ()
  (drgnx-cockpit-fixture-with
    (let ((before (length (drgnx-test-buffer-list))) r)
      (cl-letf (((symbol-function 'make-process) (lambda (&rest _) (error "No git here"))))
        (drgnx-cockpit--git repo '("status") (lambda (x) (setq r x))))
      (should (drgnx-cockpit-fixture-wait (lambda () r)))
      (should (equal (plist-get r :error) "No git here"))
      (should (= (length (drgnx-test-buffer-list)) before)))))

(ert-deftest drgnx-cockpit-model/closed-jobs-deps-are-not-read ()
  (drgnx-cockpit-fixture-with
    (drgnx-work-fixture-as-hub
      (drgnx-coord-job-create :id "jold" :title "old" :plan plan :repo repo
                              :tasks '((:n 5 :title "task 5" :role "implement") (:n 6 :title "task 6" :role "implement" :deps (5))))
      (drgnx-coord-job-set "jold" :status "done"))
    (let ((deps (nth 2 (drgnx-cockpit--jobs))))
      (should (gethash "jx#3" deps))
      (should-not (gethash "jold#6" deps)))
    (let ((drgnx-cockpit-include-closed-jobs t))
      (should (gethash "jold#6" (nth 2 (drgnx-cockpit--jobs)))))))

(ert-deftest drgnx-cockpit-model/paused-and-stopped-jobs-are-shown ()
  (drgnx-cockpit-fixture-with
    (drgnx-work-fixture-as-hub
      (drgnx-coord-job-create :id "jp" :title "paused one" :plan plan :repo repo :tasks '((:n 5 :title "task 5" :role "implement")))
      (drgnx-coord-job-set "jp" :status "paused")
      (drgnx-coord-job-create :id "js" :title "stopped one" :plan plan :repo repo :tasks '((:n 6 :title "task 6" :role "implement")))
      (drgnx-coord-job-set "js" :status "stopped"))
    (let ((m (drgnx-cockpit-model :sessions sessions)))
      (should (equal (plist-get (drgnx-cockpit-model-test--node m "job:jp") :state) "paused"))
      (should (equal (plist-get (drgnx-cockpit-model-test--node m "job:js") :state) "stopped"))
      (should (equal (plist-get (drgnx-cockpit-model-test--node m (format "task:%s#6" plan)) :job) "js")))))

(ert-deftest drgnx-cockpit-model/silent-worktrees-three-git-at-a-time ()
  (drgnx-cockpit-fixture-with
    ;; six more silent worktrees, each with a change
    (dotimes (i 6)
      (let ((wt (format "%s.claude/worktrees/s%d/" repo i)))
        (drgnx-cockpit-fixture-git repo "worktree" "add" "-q" "-b" (format "s%d" i) wt "main")
        (drgnx-cockpit-fixture-write (concat wt "x.txt") "x\n")))
    (let ((most 0) got)
      (cl-letf* ((orig (symbol-function 'make-process))
                 ((symbol-function 'make-process)
                  (lambda (&rest args)
                    (setq most (max most (1+ (seq-count (lambda (p) (and (process-live-p p) (eq (process-type p) 'real)   ; not their stderr pipes
                                                                         (string-prefix-p "drgnx-cockpit-git" (process-name p))))
                                                        (process-list)))))
                    (apply orig args))))
        (drgnx-cockpit-silent-worktrees (list repo) (lambda (agents) (setq got (list agents))) sessions)
        (should (drgnx-cockpit-fixture-wait (lambda () got) 30)))
      (should (<= most 3))
      (should (> most 1))
      ;; the queue drained: wt-b and the six
      (should (= (length (car got)) 7)))))

(ert-deftest drgnx-cockpit-model/plan-cache-is-capped-and-follows-mtime ()
  (let ((dir (make-temp-file "drgnx-cockpit-plans" t)) (drgnx-cockpit--plan-cache (make-hash-table :test #'equal)))
    (unwind-protect
        (let ((files (mapcar (lambda (i) (let ((f (format "%s/p%02d.md" dir i))) (write-region (format "# Plan %d\n" i) nil f nil 'silent) f))
                             (number-sequence 0 64))))
          (dolist (f (seq-take files 64)) (drgnx-cockpit--plan-file f))
          (should (= (hash-table-count drgnx-cockpit--plan-cache) 64))
          ;; a file read again after it changed: its entry is replaced, the others are kept
          (write-region "# Plan zero, renamed\n" nil (car files) nil 'silent)
          (set-file-times (car files) (time-add (current-time) 10))
          (should (equal (car (drgnx-cockpit--plan-file (car files))) "Plan zero, renamed"))
          (should (= (hash-table-count drgnx-cockpit--plan-cache) 64))
          ;; a 65th file: the cache is emptied first
          (should (equal (car (drgnx-cockpit--plan-file (nth 64 files))) "Plan 64"))
          (should (= (hash-table-count drgnx-cockpit--plan-cache) 1)))
      (delete-directory dir t))))

(ert-deftest drgnx-cockpit-model/job-agents-registered-by-the-hub-are-job-agents ()
  (drgnx-cockpit-fixture-with
    ;; the hub registers each task agent (kind job): an open job's shows as its job's agent, a done job's not at all
    (drgnx-work-fixture-as-hub
      (drgnx-coord-agent-register :id "s-1" :kind "job" :name "claude · jx#2" :cwd tree :worktree tree :branch "job/jx-2" :base sha
                                  :task "jx#2")
      (drgnx-coord-job-create :id "jold" :title "old" :plan plan :repo repo :tasks '((:n 6 :title "task 6" :role "implement")))
      (drgnx-coord-agent-register :id "s-old" :kind "job" :name "claude · jold#6" :cwd repo :task "jold#6")
      (drgnx-coord-event-add :agent "s-old" :kind "stop" :summary "session ended")
      (drgnx-coord-job-set "jold" :status "done"))
    (let ((m (drgnx-cockpit-model :sessions nil)))
      (should-not (drgnx-cockpit-model-test--agent m "s-old"))
      (should-not (drgnx-cockpit-model-test--node m "agent:s-old"))
      (let ((a (drgnx-cockpit-model-test--agent m "s-1")))
        (should (eq (plist-get a :reporting) 'job))
        (should (equal (plist-get a :job) "jx"))))
    (let ((src (drgnx-cockpit-edit-source "s-1")))
      (should (equal (plist-get src :base) sha))
      (should-not (plist-get src :merge-base)))
    ;; with closed jobs asked for, its agent comes back as a job agent
    (let* ((drgnx-cockpit-include-closed-jobs t) (m (drgnx-cockpit-model :sessions nil)))
      (should (eq (plist-get (drgnx-cockpit-model-test--agent m "s-old") :reporting) 'job)))))

(ert-deftest drgnx-cockpit-model/turns-are-not-an-agent-s-life ()
  (drgnx-cockpit-fixture-with
    ;; s-2's session started (the fixture); a turn of it ended: it is not stopped, and the timeline shows no turns
    (drgnx-work-fixture-as-hub
      (drgnx-coord-agent-register :id "s-2" :name "chat" :cwd repo)   ; a native agent the registry knows
      (drgnx-coord-event-add :agent "s-2" :kind "start" :summary "turn started" :data '(:turn t))
      (drgnx-coord-event-add :agent "s-2" :kind "stop" :summary "turn ended (end_turn)" :data '(:turn t)))
    (let ((m (drgnx-cockpit-model :sessions nil)))
      (should (equal (plist-get (drgnx-cockpit-model-test--agent m "s-2") :state) "not running")))
    (should-not (plist-get (drgnx-cockpit-edit-source "s-2") :stopped))
    (should (equal (mapcar (lambda (c) (plist-get c :label)) (seq-filter (lambda (c) (equal (plist-get c :agent) "s-2")) (drgnx-cockpit-timeline)))
                   '("started")))
    ;; the session's own stop is its life
    (drgnx-work-fixture-as-hub (drgnx-coord-event-add :agent "s-2" :kind "stop" :summary "session ended"))
    (should (equal (plist-get (drgnx-cockpit-model-test--agent (drgnx-cockpit-model :sessions nil) "s-2") :state) "stopped"))
    (should (plist-get (drgnx-cockpit-edit-source "s-2") :stopped))
    (should (equal (mapcar (lambda (c) (plist-get c :label)) (seq-filter (lambda (c) (equal (plist-get c :agent) "s-2")) (drgnx-cockpit-timeline)))
                   '("started" "stopped")))))

(ert-deftest drgnx-cockpit-model/turns-come-from-the-turn-column ()
  (drgnx-cockpit-fixture-with
    (drgnx-work-fixture-as-hub (drgnx-coord-agent-register :id "s-2" :name "chat" :cwd repo))
    (let ((a (drgnx-work-fixture-as-hub
               (drgnx-coord-event-add :agent "s-2" :kind "start" :summary "turn started" :data '(:turn t))))
          (b (drgnx-work-fixture-as-hub
               (drgnx-coord-event-add :agent "s-2" :kind "stop" :summary "turn ended (end_turn)" :data '(:turn t)))))
      (should (equal (sqlite-select (drgnx-work-fixture--db) "select id, turn from event where id in (?, ?) order by id" (list a b))
                     (list (list a 1) (list b 1))))
      ;; whatever the data text says, the column decides: no turn column set, a life event; set, a turn
      (sqlite-execute (drgnx-work-fixture--db) "update event set data = null where id in (?, ?)" (list a b))
      (should (equal (mapcar (lambda (c) (plist-get c :label)) (seq-filter (lambda (c) (equal (plist-get c :agent) "s-2")) (drgnx-cockpit-timeline)))
                     '("started")))
      (should (equal (plist-get (drgnx-cockpit-model-test--agent (drgnx-cockpit-model :sessions nil) "s-2") :state) "not running"))
      (sqlite-execute (drgnx-work-fixture--db) "update event set turn = null where id = ?" (list b))
      (should (equal (plist-get (drgnx-cockpit-model-test--agent (drgnx-cockpit-model :sessions nil) "s-2") :state) "stopped")))))

(load (expand-file-name "test/fixtures/handler-trap" drgnx-dir) nil t)

(ert-deftest drgnx-cockpit-model/an-agents-links-are-checked-with-no-file-name-handler ()
  ;; the names git lists are the agent's, and so are the links among them: one climbing `../' to `ssh:host:' made the
  ;; cockpit (the user's Emacs) load Tramp
  (let* ((root (file-name-as-directory (make-temp-file "drgnx-cockpit-links" t))) (wt (concat root "wt/")))
    (unwind-protect
        (progn
          (make-directory wt)
          (drgnx-test-hostile-paths wt)
          (drgnx-test-with-handler-trap
            (dolist (name '("abs-ssh" "abs-sudo" "up-ssh" "up-sudo" "gz" "gpg"))
              (should-not (drgnx-cockpit--file-ok wt name)))     ; a link out of the folder
            (dolist (name '("abs-ssh" "abs-sudo" "up-ssh" "up-sudo"))
              (should-not (drgnx-cockpit--true-dir (concat wt name "/"))))
            (should (eq (drgnx-cockpit--file-ok wt "n.gz") 'missing))
            (should (eq (drgnx-cockpit--file-ok wt "a.zip/y") 'missing))
            (should-not drgnx-test-handler-calls)))
      (delete-directory root t))))

(load (expand-file-name "test/fixtures/git-fixture" drgnx-dir) nil t)

(ert-deftest drgnx-cockpit-model/a-files-diff-reads-its-true-name-with-no-file-name-handler ()
  ;; FILE is the agent's name: its size was read through it with handlers on (`a.zip/' reached tramp-archive), and
  ;; git started in an agent's folder with them on too
  (drgnx-git-test-with-repo
    (drgnx-git-test repo "commit" "-q" "--allow-empty" "-m" "start")
    (let ((paths (drgnx-test-hostile-paths repo)) (diffs nil))
      (let ((file-name-handler-alist nil)) (drgnx-cockpit-fixture-write (concat repo "a.zip/y") "y\n"))
      (drgnx-test-with-handler-trap
        (dolist (f '("back" "a.zip/y"))
          (drgnx-cockpit-file-diff (list :dir repo) f (lambda (r) (push (cons f r) diffs))))
        (should (drgnx-cockpit-fixture-wait (lambda () (= 2 (length diffs)))))
        (should-not drgnx-test-handler-calls))
      (should (plist-get paths :back))
      (dolist (d diffs) (should (stringp (cdr d))))
      (should (string-search "+y" (cdr (assoc "a.zip/y" diffs)))))))

(ert-deftest drgnx-cockpit-model/a-link-loop-is-no-file-to-show ()
  ;; an agent's link loop made `file-truename' signal "Apparent cycle" in the cockpit's listing
  (let ((wt (file-name-as-directory (make-temp-file "drgnx-cockpit-loop" t))))
    (unwind-protect
        (progn
          (let ((file-name-handler-alist nil)) (make-symbolic-link "loop" (concat wt "loop")))
          (should-not (drgnx-cockpit--file-ok wt "loop"))
          (should-not (drgnx-cockpit--true-dir (concat wt "loop/"))))
      (delete-directory wt t))))

;;; cockpit-model-test.el ends here
