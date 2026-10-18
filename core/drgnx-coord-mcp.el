;;; drgnx-coord-mcp.el --- The coordination tools every agent gets (an MCP server) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; One server process per agent, started by the agent from the `mcpServers' entry drgnx gives it in ACP's
;; session/new (`drgnx-coord-mcp-server-spec').  Its identity comes from its environment: DRGNX_AGENT (required to
;; write), DRGNX_JOB, DRGNX_TASK.  The tools read and write the coordination store (drgnx-coord.el); every write
;; carries the decision-log version the agent last read, and a write made from an old version is held — nothing
;; written, the changes returned.  After a write the server tells the hub, so messages go out at once.
;; Agents outside drgnx (Claude Code in a terminal, Codex, Zed, …) start it from their own config
;; (`drgnx-coord-mcp-outside-spec'): DRGNX_AGENT_KIND names their kind, their identity is ext:KIND:PID-HASH — PID
;; their process, this server's parent, HASH its start time — and they report (hello, report_edit, report_test,
;; ask_user) and send messages, within one limit, but never touch a job's tasks or escalate.  No tool takes an identity as an argument.  See docs/develop/coordination.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-mcp)
(require 'drgnx-coord)
(require 'drgnx-paths)

(declare-function drgnx-hub-socket "drgnx-hub")
(declare-function drgnx-work--status-rows "drgnx-work")
(declare-function drgnx-work--json-row "drgnx-work")
(declare-function drgnx-hub--untrusted "drgnx-hub")

;;;; Who this server speaks for

(defvar drgnx-coord-mcp--parent nil
  "The agent process this server speaks for, read once (at startup, `drgnx-coord-mcp-main'): (:pid PID :tag TAG
:note NOTE).  TAG is PID-HASH — HASH of the process's start time, so a pid used again by another process is another
agent — or PID alone when the start time cannot be read; when no parent can be read, PID is this server's own.  NOTE
says which fallback was taken.")

(defun drgnx-coord-mcp--parent-pid ()
  "This server's parent process — the agent that started it — or nil when the platform does not say."
  (alist-get 'ppid (ignore-errors (process-attributes (emacs-pid)))))

(defun drgnx-coord-mcp--process-start (pid)
  "When process PID started (a Lisp time), or nil when the platform does not say."
  (alist-get 'start (ignore-errors (process-attributes pid))))

(defun drgnx-coord-mcp--start-hash (start)
  "A short hash of START, a process's start time, to the second (the boot time it is computed from jitters)."
  (substring (secure-hash 'sha1 (number-to-string (round (float-time start)))) 0 6))

(defun drgnx-coord-mcp--parent ()
  (or drgnx-coord-mcp--parent
      (setq drgnx-coord-mcp--parent
            (let ((ppid (drgnx-coord-mcp--parent-pid)))
              (if (not (and (natnump ppid) (> ppid 1)))   ; 1: init, not an agent
                  (list :pid (emacs-pid) :tag (number-to-string (emacs-pid))
                        :note "the agent's process could not be read: this identity is from this server's own pid")
                (let ((start (drgnx-coord-mcp--process-start ppid)))
                  (if start (list :pid ppid :tag (format "%d-%s" ppid (drgnx-coord-mcp--start-hash start)) :parent t)
                    (list :pid ppid :tag (number-to-string ppid) :parent t
                          :note "the agent's start time could not be read: this identity is its pid alone, which another process may get later"))))))))

(defun drgnx-coord-mcp--valid-kind (kind)
  "KIND (a string or symbol) as a string when it is a short lower-case name, else an error."
  (let ((k (format "%s" kind)) (case-fold-search nil))
    (if (string-match-p "\\`[a-z0-9][a-z0-9_-]\\{0,31\\}\\'" k) k
      (error "An agent kind is a short lower-case name (claude, codex, zed…), not %S" k))))

(defun drgnx-coord-mcp--outside-kind ()
  "DRGNX_AGENT_KIND when this server speaks for an agent outside drgnx (DRGNX_AGENT empty), else nil."
  (let ((a (getenv "DRGNX_AGENT")) (k (getenv "DRGNX_AGENT_KIND")))
    (and (or (null a) (string-empty-p a)) k (not (string-empty-p k)) (drgnx-coord-mcp--valid-kind k))))

(defun drgnx-coord-mcp--identity ()
  "Who this server speaks for: DRGNX_AGENT (drgnx's own agents), else ext:KIND:PID-HASH for an agent outside drgnx —
PID its process, this server's parent, HASH its start time (see `drgnx-coord-mcp--parent' for the fallbacks) — else
nil (it only reads).  Never from a tool's arguments.  Never \"user\", in any case: that is the user, whose messages
the hub gives agents as the user's answers (`drgnx-hub--message-prompt') — an error."
  (let ((a (getenv "DRGNX_AGENT")))
    (when (and a (equal (downcase (string-trim a)) "user"))
      (error "\"user\" is the user: no agent speaks as the user (DRGNX_AGENT=%s)" a))
    (if (and a (not (string-empty-p a))) a
      (when-let* ((kind (drgnx-coord-mcp--outside-kind)))
        (format "ext:%s:%s" kind (plist-get (drgnx-coord-mcp--parent) :tag))))))

(defun drgnx-coord-mcp--me ()
  (or (drgnx-coord-mcp--identity)
      (error "This server has no agent identity (DRGNX_AGENT, or DRGNX_AGENT_KIND for an agent outside drgnx): it can only read")))

(defun drgnx-coord-mcp--own (var)
  "Environment VAR (DRGNX_JOB, DRGNX_TASK) for drgnx's own agents; nil for an outside one: jobs are drgnx's."
  (unless (drgnx-coord-mcp--outside-kind) (getenv var)))

(defun drgnx-coord-mcp--not-outside (what)
  "An error when this server speaks for an outside agent: WHAT (a job's task, a decision) is drgnx's."
  (when (drgnx-coord-mcp--outside-kind)
    (error "%s" (format "jobs are drgnx's: report your work with report_edit (%s is for drgnx's own job agents)" what))))

(defconst drgnx-coord-mcp--identity-args '(:agent :from :sender :as :identity)
  "Arguments that would name who calls: refused by every tool (an identity is the server's, never an argument).")

(defun drgnx-coord-mcp--guard (call)
  "CALL, a tool's function, refusing arguments that name an identity, and every call of a server whose identity
says it is the user (`drgnx-coord-mcp--identity')."
  (lambda (args)
    (drgnx-coord-mcp--identity)
    (when-let* ((k (and (proper-list-p args) (seq-find (lambda (k) (plist-member args k)) drgnx-coord-mcp--identity-args))))
      (error "No tool takes `%s': you are %s, from the process that started this server"
             (substring (symbol-name k) 1) (or (drgnx-coord-mcp--identity) "nobody (this server only reads)")))
    (funcall call args)))

;;;; Reports from any agent: paths, limits

(defcustom drgnx-coord-report-rate 20
  "Reports (hello, report_edit, report_test, ask_user; an outside agent's send_message too) one agent may make a
minute.  More are held: nothing is
written, the answer says so, and a card tells the user — at most one an hour per agent."
  :type 'natnum :group 'drgnx)

(defvar drgnx-coord-mcp--reports (make-hash-table :test #'equal) "Identity → when its recent reports came, newest first.")
(defvar drgnx-coord-mcp--told (make-hash-table :test #'equal) "Identity → when the user was last told its reports were held.")

(defun drgnx-coord-mcp--now () "The clock the report limit reads." (float-time))

(defun drgnx-coord-mcp--tell-held (me now)
  "Tell the user (a `rate' card) that ME's reports are held — at most once an hour (this server remembers, and so does
the store, for a server started again); best effort: a busy store tells nobody and fails nothing."
  (let ((told (gethash me drgnx-coord-mcp--told)))
    (unless (and told (< (- now told) 3600))
      (puthash me now drgnx-coord-mcp--told)
      (ignore-errors
        (let* ((key (concat "rate-told:" me))
               (stamp (caar (sqlite-select (drgnx-work-db) "select value from meta where key = ?" (list key))))
               (last (and stamp (string-to-number stamp))))
          (if (and last (< (- now last) 3600)) (puthash me last drgnx-coord-mcp--told)
            (sqlite-execute (drgnx-work-db) "insert or replace into meta values (?, ?)" (list key (number-to-string now)))
            (drgnx-coord-card-create :job (drgnx-coord-mcp--own "DRGNX_JOB") :kind "rate"
                                     :title (format "%s reports too fast: more than %d a minute are held, not recorded"
                                                    me drgnx-coord-report-rate)
                                     :data (list :agent me :rate drgnx-coord-report-rate))
            (drgnx-coord-mcp--notify-hub)))))))

(defun drgnx-coord-mcp--held-report (me)
  "nil when ME may report now (the report is counted); else the answer for a held report — nothing written."
  (let* ((now (drgnx-coord-mcp--now))
         (recent (seq-take-while (lambda (at) (> at (- now 60))) (gethash me drgnx-coord-mcp--reports))))
    (if (< (length recent) drgnx-coord-report-rate)
        (progn (puthash me (cons now recent) drgnx-coord-mcp--reports) nil)
      (puthash me recent drgnx-coord-mcp--reports)
      (drgnx-coord-mcp--tell-held me now)
      (format "HELD: more than %d reports a minute (%d a minute is the limit) — this one was not recorded.  Report less often: one report_edit names many paths."
              drgnx-coord-report-rate drgnx-coord-report-rate))))

(defun drgnx-coord-mcp--line (text &optional max)
  "TEXT (a string or nil) as one line of at most MAX (200) characters, `drgnx-coord-control-chars' as spaces; nil when
blank."
  (when (stringp text)
    (let ((line (string-trim (replace-regexp-in-string (concat "[" drgnx-coord-control-chars "]+") " " text))))
      (unless (string-empty-p line) (substring line 0 (min (length line) (or max 200)))))))

(defconst drgnx-coord-mcp--text-max 2000 "The longest question or message text an agent sends, in characters.")

(defun drgnx-coord-mcp--text-cut (text what)
  "TEXT (WHAT, for the error) cleaned for the user to read — trimmed, the characters of `drgnx-coord-control-chars'
other than newline and tab as spaces, at most `drgnx-coord-mcp--text-max' characters — and how many characters were
cut off: (CLEAN . CUT).  An error when it is blank."
  (let ((clean (and (stringp text)
                    (string-trim (replace-regexp-in-string (concat "[" drgnx-coord-control-chars "]")
                                                           (lambda (c) (if (member c '("\n" "\t")) c " "))
                                                           text t t)))))
    (if (or (null clean) (string-empty-p clean)) (error "%s is required" what)
      (cons (substring clean 0 (min (length clean) drgnx-coord-mcp--text-max))
            (max 0 (- (length clean) drgnx-coord-mcp--text-max))))))

(defun drgnx-coord-mcp--text (text what)
  "TEXT cleaned and cut as `drgnx-coord-mcp--text-cut' does (WHAT names it in the error)."
  (car (drgnx-coord-mcp--text-cut text what)))

(defun drgnx-coord-mcp--with-cut (answer cut)
  "ANSWER (a plist), with :cut CUT when the text was shortened."
  (if (and (consp answer) (> cut 0)) (append answer (list :cut cut)) answer))

(defvar drgnx-coord-mcp--git-timeout 3 "Seconds a git command may take before it is given up (nil is its answer).")

(defun drgnx-coord-mcp--git (dir &rest args)
  "git ARGS in DIR: the first line of its output, or nil when git fails or takes over `drgnx-coord-mcp--git-timeout'
seconds (it is killed).  Never asks: no terminal, its stdin closed at once."
  (let* ((default-directory (file-name-as-directory dir))
         (process-environment (append '("GIT_TERMINAL_PROMPT=0" "GIT_OPTIONAL_LOCKS=0") process-environment))
         (out (generate-new-buffer " *drgnx-coord-git*" t))
         (err (generate-new-buffer " *drgnx-coord-git-err*" t))
         (deadline (+ (float-time) drgnx-coord-mcp--git-timeout))
         (proc nil))
    (unwind-protect
        (condition-case nil
            (progn
              (setq proc (make-process :name "drgnx-coord-git" :buffer out :stderr err :command (cons "git" args)
                                       :connection-type 'pipe :noquery t :sentinel #'ignore))
              (process-send-eof proc)
              (while (and (process-live-p proc) (< (float-time) deadline)) (accept-process-output proc 0.05))
              (if (process-live-p proc) nil   ; too slow: given up (killed below)
                (while (accept-process-output proc 0))
                (and (eq (process-exit-status proc) 0)
                     (car (split-string (with-current-buffer out (buffer-string)) "\n" t)))))
          (error nil))
      (when (and proc (process-live-p proc)) (delete-process proc))
      (let ((ep (get-buffer-process err))) (when ep (delete-process ep)))
      (kill-buffer out) (kill-buffer err))))

(defun drgnx-coord-mcp--local (path base)
  "PATH, relative to BASE, as a local truename (no trailing slash).  An error for a blank name, a control character, a
`..', or a remote (TRAMP) name — refused before any file handler runs, so nothing connects."
  (when (or (not (stringp path)) (string-blank-p path) (string-match-p (concat "[" drgnx-coord-control-chars "]") path))
    (error "Not a path: %S" path))
  (when (string-match-p "\\`/[^/]*:" path) (error "%s is not a local path" path))
  (when (member ".." (split-string path "[/\\]+")) (error "%s has a `..': name it from the folder you work in" path))
  (let ((file-name-handler-alist nil))   ; a name stays a local name: no handler, no connection
    (directory-file-name (file-truename (expand-file-name path base)))))

(defun drgnx-coord-mcp--under-p (file dir)
  "Whether FILE is DIR or inside it (both local truenames)."
  (string-prefix-p (file-name-as-directory dir) (file-name-as-directory file)
                   (memq system-type '(darwin windows-nt ms-dos cygwin))))

(defun drgnx-coord-mcp--worktree (dir)
  "The git worktree DIR is in (its truename), or nil — nil too when it is the home folder itself (a repository of
dotfiles holds no project: the folder, not the home, is where an agent under ~ works)."
  (when-let* ((top (drgnx-coord-mcp--git dir "rev-parse" "--show-toplevel")))
    (let* ((file-name-handler-alist nil)
           (top (directory-file-name (file-truename top)))
           (home (let ((h (getenv "HOME"))) (and h (not (string-empty-p h)) (directory-file-name (file-truename h))))))
      (unless (equal top home) top))))

(defvar drgnx-coord-mcp--home nil "(DIR . HOME): `drgnx-coord-mcp--home' for the working directory DIR, found once.")

(defun drgnx-coord-mcp--home ()
  "The folder this server's agent may report about: the git worktree of the folder it started this server in (the
process's own working directory, never an argument), else that folder.  Found once per server."
  (let ((dir (let ((file-name-handler-alist nil)) (directory-file-name (file-truename default-directory)))))
    (if (equal (car drgnx-coord-mcp--home) dir) (cdr drgnx-coord-mcp--home)
      (cdr (setq drgnx-coord-mcp--home (cons dir (or (drgnx-coord-mcp--worktree dir) dir)))))))

(defun drgnx-coord-mcp--too-wide-p (root)
  "Whether ROOT (a truename) is too wide to report about: a file system root, the home folder or one above it."
  (let ((home (let ((h (getenv "HOME")) (file-name-handler-alist nil))
                (and h (not (string-empty-p h)) (directory-file-name (file-truename h))))))
    (or (string-match-p "\\`\\(/\\|[A-Za-z]:/?\\)\\'" root)
        (and home (drgnx-coord-mcp--under-p home root)))))

(defun drgnx-coord-mcp--where (me)
  "(CWD . ROOT) for ME's reports: CWD resolves relative paths, ROOT holds them — the cwd and worktree its hello
registered when they lie in `drgnx-coord-mcp--home', else that folder."
  (let* ((home (drgnx-coord-mcp--home))
         (row (ignore-errors (drgnx-coord-agent me)))
         (cwd (plist-get row :cwd)) (root (or (plist-get row :worktree) cwd)))
    (if (and cwd (drgnx-coord-mcp--under-p cwd home) (drgnx-coord-mcp--under-p root home)) (cons cwd root)
      (cons (let ((file-name-handler-alist nil)) (directory-file-name (file-truename default-directory))) home))))

(defun drgnx-coord-mcp--own-task (task)
  "TASK (a label an agent gives) when it may be the agent's: an outside agent's is its own label, never a job's task."
  (when-let* ((task (drgnx-coord-mcp--line task)))
    (when (drgnx-coord-task task) (drgnx-coord-mcp--not-outside (format "task %s" task)))
    task))

(defun drgnx-coord-mcp--hello (me args)
  "Register ME (`hello'): see `drgnx-coord-mcp-tools'."
  (let* ((home (drgnx-coord-mcp--home))
         ;; not given: the one an earlier hello registered (when still valid), else where the server started
         (cwd (if-let* ((given (plist-get args :cwd))) (drgnx-coord-mcp--local given default-directory)
                (car (drgnx-coord-mcp--where me)))))
    (unless (drgnx-coord-mcp--under-p cwd home)
      (error "%s is outside %s, the folder this server was started in" cwd home))
    (unless (file-directory-p cwd) (error "%s is not a folder" cwd))
    (let* ((kind (or (drgnx-coord-mcp--outside-kind) (getenv "DRGNX_AGENT_KIND")))
           (task (drgnx-coord-mcp--own-task (plist-get args :task)))
           (worktree (drgnx-coord-mcp--worktree cwd))
           (old (drgnx-coord-agent me))
           ;; a new start: never seen, or now in another worktree — the base is HEAD now, else the first hello's
           (start (or (null old) (null (plist-get old :base)) (not (equal (plist-get old :worktree) worktree))))
           (base (if start (and worktree (drgnx-coord-mcp--git cwd "rev-parse" "HEAD")) (plist-get old :base)))
           (branch (or (drgnx-coord-mcp--line (plist-get args :branch)) (and worktree (drgnx-coord-mcp--git cwd "branch" "--show-current"))))
           (name (or (drgnx-coord-mcp--line (plist-get args :name) 80) (plist-get old :name) kind me))
           (parent (drgnx-coord-mcp--parent)))
      (drgnx-coord-agent-register :id me :kind kind :name name :cwd cwd :worktree worktree :branch branch :base base
                                  :plan (drgnx-coord-mcp--line (plist-get args :plan)) :task task
                                  :pid (and (drgnx-coord-mcp--outside-kind) (plist-get parent :parent) (plist-get parent :pid))
                                  :clear (and start (append (and (null worktree) '(:worktree)) (and (null base) '(:base)))))
      (when start
        (drgnx-coord-event-add :agent me :job (drgnx-coord-mcp--own "DRGNX_JOB") :task (drgnx-coord-mcp--own "DRGNX_TASK")
                               :kind "start" :summary (format "%s started in %s%s" name cwd (if branch (format " (%s)" branch) ""))
                               :data (cl-loop for (k v) on (list :kind kind :cwd cwd :branch branch :base base) by #'cddr
                                              when v append (list k v)))
        (drgnx-coord-mcp--notify-hub))
      (append (list :agent me :version (drgnx-coord-version) :cwd cwd :worktree worktree :base base)
              (and (drgnx-coord-mcp--outside-kind) (plist-get parent :note) (list :note (plist-get parent :note)))))))

(defconst drgnx-coord-mcp--paths-max 1000 "The most paths one report_edit may name; more are refused unread.")

(defun drgnx-coord-mcp--edit-data (root paths more)
  "An edit event's data: ROOT, PATHS (relative), and MORE paths left out when it is above 0."
  (append (list :root root :paths paths) (and (> more 0) (list :more more))))

(defun drgnx-coord-mcp--fitting (root paths)
  "The first of PATHS that an edit event's data keeps whole: printed as C1 prints it (`drgnx-coord--data-print': at
most 100 elements of a list), within `drgnx-coord--data-max' characters."
  (let ((kept (seq-take paths 100)))
    (while (and kept (> (length (let ((print-length 100) (print-level 6) (print-escape-newlines t))
                                  (prin1-to-string (drgnx-coord-mcp--edit-data root kept (- (length paths) (length kept))))))
                        drgnx-coord--data-max))
      (setq kept (butlast kept)))
    kept))

(defun drgnx-coord-mcp--report-edit (me args)
  "Record ME's edit (`report_edit'): see `drgnx-coord-mcp-tools'."
  (let* ((where (drgnx-coord-mcp--where me)) (cwd (car where)) (root (cdr where))
         ;; an array, else one per line — or, in a string with no newline, separated by commas
         (given (let ((p (plist-get args :paths)))
                  (cond ((vectorp p) (append p nil))
                        ((not (stringp p)) nil)
                        (t (split-string p (if (string-search "\n" p) "\n" ",") t "[ \t\r]+")))))
         (_ (when (drgnx-coord-mcp--too-wide-p root)
              (error "%s" (format "The folder you work in is %s — your home folder or above it, too wide to report about: start drgnx's MCP server in the project folder (the agent's working directory there)" root))))
         (_ (when (nthcdr drgnx-coord-mcp--paths-max given)
              (error "%d paths: at most %d in one report" (length given) drgnx-coord-mcp--paths-max)))
         (paths (mapcar (lambda (p)
                          (let ((file (drgnx-coord-mcp--local p cwd)))
                            (unless (drgnx-coord-mcp--under-p file root) (error "%s is outside %s, the folder you work in" p root))
                            (let ((file-name-handler-alist nil)) (file-relative-name file root))))
                        given)))
    (unless paths (error "paths is required: the files you changed (an array, or one per line)"))
    (let* ((kept (drgnx-coord-mcp--fitting root paths))
           (id (drgnx-coord-event-add-best-effort
                :agent me :job (drgnx-coord-mcp--own "DRGNX_JOB") :task (drgnx-coord-mcp--own "DRGNX_TASK") :kind "edit"
                :summary (or (plist-get args :summary) (format "%d file%s" (length paths) (if (cdr paths) "s" "")))
                :data (drgnx-coord-mcp--edit-data root kept (- (length paths) (length kept))))))
      (drgnx-coord-agent-seen me)
      (drgnx-coord-mcp--notify-hub)
      (if id (list :ok t :event id :paths (length paths)) (list :ok :false :busy "the store was busy: not recorded, go on")))))

(defun drgnx-coord-mcp--report-test (me args)
  "Record ME's test run (`report_test'): see `drgnx-coord-mcp-tools'."
  (let ((command (or (drgnx-coord-mcp--line (plist-get args :command)) (error "command is required: the test command you ran")))
        (passed (plist-get args :passed)) (failed (plist-get args :failed)))
    (dolist (n (list passed failed))
      (unless (or (null n) (natnump n)) (error "passed and failed are counts (whole numbers, 0 or more), not %S" n)))
    (let ((id (drgnx-coord-event-add-best-effort
               :agent me :job (drgnx-coord-mcp--own "DRGNX_JOB") :task (drgnx-coord-mcp--own "DRGNX_TASK") :kind "test"
               :summary (or (plist-get args :summary) (format "%s passed, %s failed: %s" (or passed "?") (or failed "?") command))
               :data (append (list :command command) (and passed (list :passed passed)) (and failed (list :failed failed))))))
      (drgnx-coord-agent-seen me)
      (drgnx-coord-mcp--notify-hub)
      (if id (list :ok t :event id) (list :ok :false :busy "the store was busy: not recorded, go on")))))

(defun drgnx-coord-mcp--ask-user (me args)
  "Ask the user (`ask_user'): see `drgnx-coord-mcp-tools'."
  (let* ((given (drgnx-coord-mcp--text-cut (plist-get args :question) "question"))
         (question (string-trim
                    ;; the options line is drgnx's to write: an "Options:" line of the question's own goes
                    (replace-regexp-in-string "^[ \t]*[Oo][Pp][Tt][Ii][Oo][Nn][Ss][ \t]*:.*\\(\n\\|\\'\\)" "" (car given))))
         (options (delq nil (mapcar #'drgnx-coord-mcp--line
                                    (let ((o (plist-get args :options))) (if (vectorp o) (append o nil) (and (stringp o) (split-string o "\n" t))))))))
    (when (string-empty-p question) (error "question is required"))
    (when-let* ((bad (seq-find (lambda (o) (string-search "|" o)) options)))
      (error "An option cannot hold a `|' (it separates them): %s" bad))
    (let* ((task (or (drgnx-coord-mcp--own-task (plist-get args :task)) (drgnx-coord-mcp--own "DRGNX_TASK")))
           (r (drgnx-coord-send :job (drgnx-coord-mcp--own "DRGNX_JOB") :sender me :recipient "user" :question t
                                :text (concat "[escalation] " (if task (format "(%s) " task) "") question
                                              (if options (concat "\nOptions: " (string-join (seq-take options 20) " | ")) "")))))
      ;; one of drgnx's agents with a task it holds: the task waits on the user
      (when-let* ((held (and task (not (drgnx-coord-mcp--outside-kind)) (drgnx-coord-task task))))
        (when (and (equal (plist-get held :agent) me) (member (plist-get held :status) '("claimed" "running")))
          (drgnx-coord-set-status task me "needs-input" (drgnx-coord-version))))
      (drgnx-coord-mcp--notify-hub)
      (drgnx-coord-mcp--with-cut (append r (list :answer "the user's answer comes as a message: read_inbox")) (cdr given)))))

(defun drgnx-coord-mcp--jsonable (v)
  (cond ((null v) :null) ((eq v t) t)
        ((and (consp v) (keywordp (car v))) (cl-loop for (k x) on v by #'cddr append (list k (drgnx-coord-mcp--jsonable x))))
        ((consp v) (vconcat (mapcar #'drgnx-coord-mcp--jsonable v)))
        ((and (symbolp v) (not (keywordp v))) (symbol-name v))
        (t v)))

(defun drgnx-coord-mcp--answer (r)
  "The store's answer R as the tool's text: a held write says so first, with the changes."
  (if (plist-get r :held)
      (concat "HELD: the decision log moved on — read these changes, then retry with seen_version "
              (number-to-string (plist-get r :version)) ".\n"
              (drgnx-mcp--json (drgnx-coord-mcp--jsonable (list :version (plist-get r :version) :changes (plist-get r :changes)))))
    (drgnx-mcp--json (drgnx-coord-mcp--jsonable r))))

(defun drgnx-coord-mcp--notify-hub ()
  "Tell the hub something was written (it delivers at once); never waits, never fails."
  (ignore-errors
    (require 'drgnx-hub)
    (let ((socket (drgnx-hub-socket)))
      (when (and (file-exists-p socket) (not (drgnx-hub--untrusted socket)))   ; never a socket not private to the user
        (let ((c (make-network-process :name "drgnx-coord-notify" :family 'local :service socket :noquery t)))
          (process-send-string c "{\"method\":\"coord/notify\"}\n")   ; a notification: no answer to wait for
          (delete-process c))))))

(defmacro drgnx-coord-mcp--write (&rest body)
  "BODY (a store write): its answer as text, the hub told."
  `(let ((r (progn ,@body)))
     (ignore-errors (drgnx-coord-note-held (drgnx-coord-mcp--me) (and (consp r) (plist-get r :held))))   ; stale twice: a card
     (prog1 (drgnx-coord-mcp--answer r) (drgnx-coord-mcp--notify-hub))))

(defvar read-eval)                      ; `let'-bound in `--hub-agents': must be dynamic once compiled
(declare-function drgnx-hub-running-p "drgnx-hub")
(declare-function drgnx-hub-call-sync "drgnx-hub")

(defun drgnx-coord-mcp--hub-agents ()
  "The sessions the hub runs, ((:id :name :job :task …)…) — or `none' when no hub answers."
  (condition-case nil
      (progn
        (require 'drgnx-hub)
        (if (not (drgnx-hub-running-p)) 'none
          (let ((read-eval nil))
            (mapcar (lambda (lisp) (car (read-from-string lisp)))
                    (plist-get (drgnx-hub-call-sync "agents/list" nil 2) :sessions)))))
    (error 'none)))

(defun drgnx-coord-mcp--agents ()
  "The agents of this job (every agent when the caller has no job), ((:agent ID :task TASK :name NAME)…): the hub's
sessions when it runs, else the job's tasks that have an agent."
  (let ((job (drgnx-coord-mcp--own "DRGNX_JOB")) (sessions (drgnx-coord-mcp--hub-agents)))
    (if (listp sessions)
        (delq nil (mapcar (lambda (s) (and (or (null job) (equal (plist-get s :job) job))
                                           (list :agent (plist-get s :id) :task (plist-get s :task) :name (plist-get s :name))))
                          sessions))
      (delq nil (mapcar (lambda (task) (and (plist-get task :agent) (list :agent (plist-get task :agent) :task (plist-get task :id))))
                        (drgnx-coord-tasks job))))))

(defun drgnx-coord-mcp--resolve-recipient (to)
  "The identity a message to TO is stored under: \"user\", an agent of this job's tasks, or the id of the hub session
TO names (by id or name; an agent's identity is its session id, so inbox, ack and replies find the message).  Else an
error, nothing is sent.  The hub is asked only when the cheap checks fail."
  (or (and (equal to "user") to)
      (and (seq-some (lambda (task) (equal to (plist-get task :agent))) (drgnx-coord-tasks (drgnx-coord-mcp--own "DRGNX_JOB"))) to)
      (let ((sessions (drgnx-coord-mcp--hub-agents)))
        (or (and (listp sessions)
                 (plist-get (seq-find (lambda (s) (member to (list (plist-get s :id) (plist-get s :name)))) sessions) :id))
            (error "No agent \"%s\" (list_agents names them; \"user\" is the user)%s" to
                   (if (listp sessions) "" " - no hub answered, so only the job's task agents are known"))))))

(defun drgnx-coord-mcp--seen (args)
  (or (plist-get args :seen_version) (error "seen_version is required: call read_decisions first")))

(defun drgnx-coord-mcp-tools ()
  "The coordination tools: ((NAME :description :schema :call)…).  None takes an identity as an argument."
  (mapcar (lambda (tool) (cons (car tool) (plist-put (copy-sequence (cdr tool)) :call (drgnx-coord-mcp--guard (plist-get (cdr tool) :call)))))
          (append (drgnx-coord-mcp--job-tools) (drgnx-coord-mcp--report-tools))))

(defmacro drgnx-coord-mcp--reporting (fn args)
  "FN called with the caller's identity and ARGS — unless the caller reports too fast (the held answer, nothing written)."
  `(let ((me (drgnx-coord-mcp--me)))
     (or (drgnx-coord-mcp--held-report me) (drgnx-coord-mcp--jsonable (,fn me ,args)))))

(defun drgnx-coord-mcp--report-tools ()
  "The tools every agent reports with — drgnx's own and those outside it."
  (let ((s #'drgnx-mcp-schema))
    `(("hello" :description "Say who you are and where you work, first: answers your identity (from your process: never an argument) and the decision log's version.  The cwd must be inside the folder you started this server in."
       :schema ,(funcall s '(("name" "string" "A name for you the user sees (e.g. \"claude · drgnx\")")
                             ("cwd" "string" "The folder you work in (default: where you started this server)")
                             ("branch" "string" "Your git branch (default: the cwd's)") ("plan" "string" "The plan you work from")
                             ("task" "string" "The task you work on (your own label; a drgnx job's tasks are not yours to name)")))
       :call ,(lambda (a) (drgnx-coord-mcp--reporting drgnx-coord-mcp--hello a)))
      ("report_edit" :description "Say which files you changed (paths only; inside the folder you work in): the user's Work cockpit shows them and their diff."
       :schema ,(let ((schema (funcall s '(("paths" "array" "") ("summary" "string" "What you changed, one line")) '("paths"))))
                  ;; an array of strings (best), or a string: one per line, or — with no newline — separated by commas
                  (puthash "paths" (list :type ["array" "string"] :items (list :type "string")
                                         :description "The files (at most 1000), relative to your cwd or absolute: best an array of strings; a string takes one per line, or, with no newline, separated by commas")
                           (plist-get schema :properties))
                  schema)
       :call ,(lambda (a) (drgnx-coord-mcp--reporting drgnx-coord-mcp--report-edit a)))
      ("report_test" :description "Say you ran tests, and how they went: the user's status bar and cockpit show it."
       :schema ,(funcall s '(("command" "string" "The test command") ("passed" "integer" "Tests passed")
                             ("failed" "integer" "Tests failed") ("summary" "string" "One line"))
                         '("command"))
       :call ,(lambda (a) (drgnx-coord-mcp--reporting drgnx-coord-mcp--report-test a)))
      ("ask_user" :description "Ask the user a question; it waits for them in the cockpit (never a prompt).  Go on with what does not depend on it: the answer comes as a message (read_inbox)."
       :schema ,(let ((schema (funcall s '(("question" "string" "The question") ("options" "array" "")
                                           ("task" "string" "The task it is about"))
                                       '("question"))))
                  (puthash "options" (list :type ["array" "string"] :items (list :type "string")
                                           :description "The choices: best an array of strings; a string takes one per line (none may hold a |)")
                           (plist-get schema :properties))
                  schema)
       :call ,(lambda (a) (drgnx-coord-mcp--reporting drgnx-coord-mcp--ask-user a))))))

(defun drgnx-coord-mcp--job-tools ()
  "The tools of agents that work together: messages, the decision log, a job's tasks."
  (let ((s #'drgnx-mcp-schema) (seen '("seen_version" "integer" "The decision-log version you last read (read_decisions)")))
    `(("list_agents" :description "The agents working on this job, with their tasks"
       :schema ,(funcall s nil)
       :call ,(lambda (_a) (drgnx-coord-mcp--jsonable (drgnx-coord-mcp--agents))))
      ("send_message" :description "Send a message to another agent (or \"user\"); it is queued and never interrupts them"
       :schema ,(funcall s `(("to" "string" "The recipient") ("text" "string" "The message") ,seen) '("to" "text" "seen_version"))
       :call ,(lambda (a)
                ;; an outside agent's messages count as its reports: the same limit
                (or (and (drgnx-coord-mcp--outside-kind) (drgnx-coord-mcp--held-report (drgnx-coord-mcp--me)))
                    (let ((text (drgnx-coord-mcp--text-cut (plist-get a :text) "text"))
                          (to (drgnx-coord-mcp--resolve-recipient (plist-get a :to))))
                      (drgnx-coord-mcp--write
                       (drgnx-coord-mcp--with-cut
                        (drgnx-coord-send :job (drgnx-coord-mcp--own "DRGNX_JOB") :sender (drgnx-coord-mcp--me) :recipient to
                                          :text (car text) :seen (drgnx-coord-mcp--seen a))
                        (cdr text)))))))
      ("read_inbox" :description "Messages to you not read yet (they become read)"
       :schema ,(funcall s nil)
       :call ,(lambda (_a) (let ((msgs (drgnx-coord-inbox (drgnx-coord-mcp--me) '("queued" "delivered"))))
                             (dolist (m msgs) (drgnx-coord-mark (plist-get m :id) "read"))
                             (drgnx-coord-mcp--jsonable msgs))))
      ("ack" :description "Say you acted on a message"
       :schema ,(funcall s '(("id" "integer" "The message's id")) '("id"))
       :call ,(lambda (a)
                (let ((m (drgnx-coord-message (plist-get a :id))))
                  (unless (and m (equal (plist-get m :recipient) (drgnx-coord-mcp--me)))
                    (error "No message %s for you" (plist-get a :id))))
                (when (drgnx-coord-mark (plist-get a :id) "acted") (drgnx-coord-mcp--notify-hub))   ; nothing changed: no news
                "acted"))
      ("read_decisions" :description "The decision log since a version (0: all), and the current version"
       :schema ,(funcall s '(("since" "integer" "The last version you read (0 for all)")))
       :call ,(lambda (a)
                (let ((v (drgnx-coord-version)) (me (ignore-errors (drgnx-coord-mcp--identity))))
                  (when (and me (/= (drgnx-coord-seen me) v)) (drgnx-coord-set-seen me v))   ; the hub stops telling it; a write only when it changed
                  (drgnx-coord-mcp--jsonable (list :version v :decisions (drgnx-coord-decisions-since (or (plist-get a :since) 0)))))))
      ("record_decision"
       :description "Record a decision: build, wait, wont-build or replaces.  Inside your own task it is current; about anything else it is proposed (the reviewer and the user decide)"
       :schema ,(funcall s `(("kind" "string" "build, wait, wont-build or replaces") ("subject" "string" "What it is about")
                             ("task" "string" "The task it concerns") ("paths" "string" "Files or paths it covers")
                             ("reason" "string" "Why") ("replaces" "integer" "The decision it replaces") ,seen)
                         '("kind" "subject" "reason" "seen_version"))
       :call ,(lambda (a) (drgnx-coord-mcp--not-outside "record_decision")
                (drgnx-coord-mcp--write
                 (drgnx-coord-decide :kind (plist-get a :kind) :subject (plist-get a :subject) :task (plist-get a :task)
                                     :paths (plist-get a :paths) :reason (plist-get a :reason)
                                     :author (drgnx-coord-mcp--me) :replaces (plist-get a :replaces)
                                     :job (getenv "DRGNX_JOB") :seen (drgnx-coord-mcp--seen a)))))
      ("claim_task" :description "Claim a ready task (a lease, kept while you work on it)"
       :schema ,(funcall s `(("task" "string" "The task's id") ,seen) '("task" "seen_version"))
       :call ,(lambda (a) (drgnx-coord-mcp--not-outside "claim_task")
                (drgnx-coord-mcp--write
                 (drgnx-coord-claim (plist-get a :task) (drgnx-coord-mcp--me) (drgnx-coord-mcp--seen a)))))
      ("update_task" :description "Set your task's status: running, needs-input, in-review or failed (in a job: running, needs-input or in-review)"
       :schema ,(funcall s `(("task" "string" "The task's id") ("status" "string" "The new status") ,seen)
                         '("task" "status" "seen_version"))
       :call ,(lambda (a)
                (drgnx-coord-mcp--not-outside "update_task")
                ;; in a job, a task is done when its review passed and it is merged: never by its agent's word; outside
                ;; one an agent may also fail it, and complete_task finishes it
                (let ((job (getenv "DRGNX_JOB")))
                  (unless (member (plist-get a :status) (append '("running" "needs-input" "in-review") (and (not job) '("failed"))))
                    (error (if job "In a job, a task's status is running, needs-input or in-review (complete_task); review and merge make it done"
                             "A task's status is running, needs-input, in-review or failed (complete_task finishes it)"))))
                (drgnx-coord-mcp--write
                 (drgnx-coord-set-status (plist-get a :task) (drgnx-coord-mcp--me) (plist-get a :status)
                                         (drgnx-coord-mcp--seen a)))))
      ("complete_task" :description "Your task is done (in a job: it goes to review, then is merged)"
       :schema ,(funcall s `(("task" "string" "The task's id") ,seen) '("task" "seen_version"))
       :call ,(lambda (a) (drgnx-coord-mcp--not-outside "complete_task")
                (drgnx-coord-mcp--write
                 (drgnx-coord-set-status (plist-get a :task) (drgnx-coord-mcp--me)
                                         (if (getenv "DRGNX_JOB") "in-review" "done") (drgnx-coord-mcp--seen a)))))
      ("task_status" :description "The job's tasks: status, agent, dependencies"
       :schema ,(funcall s '(("job" "string" "The job (default: yours)")))
       :call ,(lambda (a) (drgnx-coord-mcp--jsonable (drgnx-coord-tasks (or (plist-get a :job) (getenv "DRGNX_JOB"))))))
      ("work_status" :description "The work tracker's plans: what `drgnx work status --json' gives, one object per plan (tasks, steps, todos as [done, all], commits, branch, merged)"
       :schema ,(funcall s nil)
       ;; drgnx-mcp--json decodes json-serialize's UTF-8 bytes, so a non-ASCII title reaches the agent intact
       :call ,(lambda (_a) (require 'drgnx-work)   ; loaded on first use: every agent starts this server
                (vconcat (mapcar #'drgnx-work--json-row (drgnx-work--status-rows)))))
      ("escalate" :description "Ask the user to decide something (a clash, a question): queued for them (the job window shows it); go on with what does not depend on it"
       :schema ,(funcall s `(("subject" "string" "What it is about") ("text" "string" "What needs deciding") ,seen)
                         '("subject" "text" "seen_version"))
       :call ,(lambda (a)
                (when (drgnx-coord-mcp--outside-kind)
                  (error "%s" "escalate is for drgnx's own job agents: ask the user with ask_user"))
                (drgnx-coord-mcp--write
                 (drgnx-coord-send :job (drgnx-coord-mcp--own "DRGNX_JOB") :sender (drgnx-coord-mcp--me) :recipient "user"
                                   :text (format "[escalation] %s: %s" (drgnx-coord-mcp--text (plist-get a :subject) "subject")
                                                 (drgnx-coord-mcp--text (plist-get a :text) "text"))
                                   :seen (drgnx-coord-mcp--seen a))))))))

(defun drgnx-coord-mcp-main ()
  "Batch entry: serve the coordination tools on stdin/stdout."
  (drgnx-coord-mcp--parent)   ; the agent's process, read now: while it surely is this server's parent
  (drgnx-mcp-serve "drgnx" (drgnx-coord-mcp-tools)))

(defun drgnx-coord-mcp-server-spec (agent &rest props)
  "The ACP `mcpServers' entry that gives AGENT (its session's name) the coordination tools.  PROPS: :job, :task."
  ;; the agent starts this with the default SIGPIPE (libuv resets it): the command ignores it itself
  (let ((command (drgnx-command-ignoring-sigpipe
                  (list (expand-file-name invocation-name invocation-directory)
                        "--batch" "-Q" "--eval" "(setq load-prefer-newer t)" "-L" (expand-file-name "core" drgnx-dir)
                        "-l" "drgnx-coord-mcp" "-f" "drgnx-coord-mcp-main"))))
    (list :name "drgnx"
          :command (car command) :args (vconcat (cdr command))
          :env (vconcat (delq nil (append (list (list :name "DRGNX_AGENT" :value agent)
                                                (and (plist-get props :job) (list :name "DRGNX_JOB" :value (plist-get props :job)))
                                                (and (plist-get props :task) (list :name "DRGNX_TASK" :value (plist-get props :task))))
                                          (mapcar (lambda (n) (let ((v (getenv n))) (and v (list :name n :value v))))
                                                  '("DRGNX_DATA_DIR" "XDG_STATE_HOME" "XDG_DATA_HOME" "XDG_RUNTIME_DIR"))))))))

(defun drgnx-coord-mcp-outside-spec (kind)
  "The MCP server item an agent outside drgnx of KIND (claude, codex, …) is given — what the agent settings pages
write into its config: `bin/drgnx coord mcp --kind KIND', which runs this server with DRGNX_AGENT_KIND=KIND."
  (list :type 'stdio :command (expand-file-name "bin/drgnx" drgnx-dir)
        :args (list "coord" "mcp" "--kind" (drgnx-coord-mcp--valid-kind kind))))

(provide 'drgnx-coord-mcp)
;;; drgnx-coord-mcp.el ends here
