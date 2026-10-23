;;; drgnx-hub.el --- The hub: a durable process for agents and their gateway -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The hub is a batch Emacs started as a durable job (drgnx-jobs.el): it outlives the Emacs that started it, and
;; holds what must keep running while editors come and go — today the agent traffic gateway (drgnx-gateway.el).
;; Editors, the CLI and tests talk to it over a Unix socket in a directory only the user can enter: one JSON object
;; per line, requests {id, method, params} answered {id, result} or {id, error}, and events {event, data} for the
;; connections that subscribed.  One hub per drgnx data directory.  This file is the server; the client (the socket,
;; requests, the subscription) is drgnx-hub-client.el, which editors load instead.  See docs/develop/hub.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-file)
(require 'drgnx-hub-client)
(require 'drgnx-gateway)
(require 'drgnx-jobs)
(require 'drgnx-gc)
(require 'drgnx-agents)
(require 'drgnx-coord)
(require 'drgnx-records)
(require 'drgnx-job)
(require 'drgnx-job-clash)
(require 'drgnx-timer)
(require 'drgnx-sandbox-vc)
(require 'drgnx-shell-env)
(require 'drgnx-guard)

(defvar drgnx-hub--server nil "This Emacs's hub socket, when it is the hub.")
(defvar drgnx-hub--subscribers nil "Connections that asked for events.")
(defvar drgnx-hub--started nil)
(defvar drgnx-hub--exit-function (lambda () (kill-emacs 0)) "What `shutdown' does (tests: stop serving).")
(defvar drgnx-hub--secret nil
  "Ratatoskr's secret (DRGNX_HUB_SERVE_SECRET) when this hub is its Lisp backend, else nil.  Then every connection's
first line must be {\"auth\": SECRET}: any other closes it before a method runs (`drgnx-hub--receive').")

;;;; Where

(defun drgnx-hub--lock (socket) (concat socket ".lock"))

(defun drgnx-hub--lock-pid (socket)
  (ignore-errors (string-to-number (with-temp-buffer (insert-file-contents (expand-file-name "pid" (drgnx-hub--lock socket)))
                                                     (buffer-string)))))

(defun drgnx-hub--alive-p (pid)
  "Is PID a running process (a zombie is not)?"
  (let ((attrs (and pid (> pid 0) (process-attributes pid))))
    (and attrs (not (member (alist-get 'state attrs) '("Z" "X"))))))

(defun drgnx-hub--take-lock (socket)
  "Hold SOCKET's lock (a directory made atomically, with our pid): one hub at a time, even when one is too busy to
answer a ping.  A lock whose process is gone is taken over.  Signals when another hub holds it."
  (let ((lock (drgnx-hub--lock socket)))
    (condition-case nil (make-directory lock)
      (file-already-exists
       (let ((pid (drgnx-hub--lock-pid socket)))
         (when (and (drgnx-hub--alive-p pid) (/= pid (emacs-pid)))
           (error "a hub already serves on %s (pid %d)" socket pid))
         (delete-directory lock t)
         (make-directory lock))))
    (write-region (number-to-string (emacs-pid)) nil (expand-file-name "pid" lock) nil 'silent)))

(defun drgnx-hub--port-file () (expand-file-name "hub/port" (drgnx-state-dir)))

(defun drgnx-hub--registrations-file () (expand-file-name "hub/registrations.eld" (drgnx-state-dir)))

(defun drgnx-hub--sessions-file () (expand-file-name "hub/sessions.eld" (drgnx-state-dir)))

;;;; Writing to clients (the line protocol and the write queue are in drgnx-hub-client.el)

(defun drgnx-hub--answer (conn object)
  "Send OBJECT to CONN, a client of this hub.  A write to a client that does not read fast enough waits, and runs
timers and filters meanwhile: what comes for it then is queued (written in order once the write is done), never
written one level deeper.  A client that stopped reading (`drgnx-hub--client-stuck-p') is dropped instead.  Hub side
only: a client's nested `drgnx-hub-call' is legitimate."
  (drgnx-hub--enqueue conn (concat (json-serialize (drgnx-hub--jsonable object)) "\n"))
  (drgnx-hub--drain conn))

(defun drgnx-hub--drop-stuck ()
  "Drop the client that stopped reading even when nothing more comes for it (the hub's tick): the innermost write
in progress is the only one judged (`drgnx-hub--client-stuck-p')."
  (when-let* ((c (car drgnx-hub--writing)))
    (when (and (process-live-p c) (drgnx-hub--client-stuck-p c)) (drgnx-hub--drop c))))

(defconst drgnx-hub--max-line (* 1024 1024)
  "The longest request line the hub reads (characters): a longer one closes its connection.")

(defun drgnx-hub--malformed (conn line)
  "LINE from CONN is not JSON: when its id can be read, it is answered with an error (its sender would wait)."
  (when (string-match "\"id\"[ \t]*:[ \t]*\\(-?[0-9]+\\)[ \t]*[,}]" line)
    (drgnx-hub--answer conn (list :id (string-to-number (match-string 1 line)) :error (list :message "not a JSON object")))))

;;;; The hub side

(defun drgnx-hub--write-private (file value)
  "Keep VALUE in FILE (mode 0600) through the file layer: written to a temporary file beside the old one, synced,
then renamed over it, so a hub that dies mid-write (or a machine) leaves the old file whole.  Over
`drgnx-file-max-bytes' or not plain data is `drgnx-file-refused', and FILE is untouched."
  (drgnx-file-write file value :private t :fsync t))

(defun drgnx-hub--save-registrations ()
  "Keep the registrations (`drgnx-hub--write-private')."
  (drgnx-hub--write-private (drgnx-hub--registrations-file) (drgnx-gateway-registrations)))

(defun drgnx-hub--kept-unusable (file why consequence)
  "FILE, a kept file the hub cannot use (WHY), is copied aside (`drgnx-file-backup': the next save replaces it) and
logged in one line with CONSEQUENCE.  Never signals: a backup that fails is said in the same line."
  (let ((backup (condition-case err (drgnx-file-backup file) (error (format "not backed up: %s" (error-message-string err))))))
    (message "drgnx hub: %s cannot be used (%s; kept as %s): %s" file why backup consequence)))

(defun drgnx-hub--read-kept (file consequence)
  "The data of the kept FILE, or nil when it is missing or cannot be read (`drgnx-hub--kept-unusable')."
  (let ((r (drgnx-file-read file)))
    (when (eq (plist-get r :status) 'unreadable)
      (drgnx-hub--kept-unusable file (plist-get (plist-get r :problem) :text) consequence))
    (and (eq (plist-get r :status) 'ok) (plist-get r :data))))

(defun drgnx-hub--load-registrations ()
  "Take back the registrations a previous hub kept; a file that cannot be read is backed up and logged (its agents
register again)."
  (let* ((file (drgnx-hub--registrations-file))
         (consequence "agents registered before must register again")
         (data (drgnx-hub--read-kept file consequence)))
    (condition-case err (drgnx-gateway-load-registrations data)
      (error (drgnx-hub--kept-unusable file (error-message-string err) consequence)))))

(defun drgnx-hub--prune-registrations ()
  "Drop the registrations whose owner (the pid of the Emacs that registered them: its agents are its children) is
gone — a crashed editor never unregisters its agents' tokens; then keep the rest.  One without an owner stays until it
is unregistered (those kept before owners were: they are tolerated, not guessed at), as does one whose owner is not
a pid.  How many went."
  (let ((alive (make-hash-table)) (dead nil))
    (maphash (lambda (hash reg)
               (when-let* ((owner (plist-get reg :owner)) ((natnump owner)))
                 (unless (eq (or (gethash owner alive) (puthash owner (if (drgnx-hub--alive-p owner) 'yes 'no) alive)) 'yes)
                   (push hash dead))))
             drgnx-gateway--registrations)
    (dolist (hash dead) (remhash hash drgnx-gateway--registrations))
    (when dead (drgnx-hub--save-registrations))
    (length dead)))

(defun drgnx-hub--chain (chain)
  "A chain from JSON ([[provider, model-or-null]…]) as ((PROVIDER . MODEL)…)."
  (mapcar (lambda (step) (cons (intern (car step)) (cadr step))) chain))

(defvar drgnx-hub--seq)                 ; defined with the events below

(defun drgnx-hub--method (method params)
  "The result of METHOD with PARAMS, or (:error MESSAGE)."
  (pcase method
    ("ping" (list :pid (emacs-pid)))
    ("status" (list :pid (emacs-pid) :socket (drgnx-hub-socket) :gateway_port (drgnx-gateway-port)
                    :registrations (length (drgnx-gateway-registrations)) :started drgnx-hub--started))
    ("gateway/register" (drgnx-hub-register params))
    ("gateway/unregister" (drgnx-gateway-unregister (plist-get params :token)) (drgnx-hub--save-registrations) t)
    ("gateway/keys" (drgnx-hub--set-keys (plist-get params :keys)) t)
    ("events/since" (drgnx-hub--events-since params))
    ("env/set" (drgnx-hub--set-env (plist-get params :env)))
    ("coord/notify" (run-at-time 0 nil #'drgnx-hub--deliver)   ; a coordination server wrote: deliver now, look for clashes
     (drgnx-hub--events-soon)                                    ; and send its events
     (run-at-time 0 nil (lambda () (dolist (j (drgnx-coord-jobs "running")) (with-demoted-errors "drgnx job: %S" (drgnx-job-clash-scan j)))))
     t)   ; a coordination server wrote: deliver now
    ("spend" (drgnx-work-db-spend :job (plist-get params :job) :task (plist-get params :task) :agent (plist-get params :agent)))
    ("agents/start"
     (let ((s (drgnx-agents-start (plist-get params :profile) (plist-get params :cwd) (plist-get params :task) (plist-get params :job))))
       (list :id (drgnx-agent-session-id s) :name (drgnx-agent-session-name s))))
    ("agents/list" (list :sessions (vconcat (mapcar #'drgnx-hub--snapshot-json (drgnx-agents-sessions)))))
    ("agents/get" (let ((s (drgnx-hub--session params)))
                    (drgnx-agents-join-text s)          ; the wire carries whole texts
                    (list :session (drgnx-hub--snapshot-json s)
                          :entries (vconcat (mapcar #'drgnx-hub--entry-json (drgnx-agent-session-entries s)))
                          :seq (gethash (drgnx-agent-session-id s) drgnx-hub--seq 0))))
    ("agents/send" (drgnx-agents-send (drgnx-hub--session params) (plist-get params :text)) t)
    ("agents/stop" (drgnx-agents-stop (drgnx-hub--session params)) t)
    ("agents/kill" (drgnx-agents-kill (drgnx-hub--session params)) t)
    ("agents/permission"
     ;; the user's answer, from their own Emacs: the only way a permission request is answered
     (let* ((s (drgnx-hub--session params))
            (item (or (seq-find (lambda (p) (equal (format "%s" (plist-get p :id)) (format "%s" (plist-get params :request))))
                                (drgnx-agent-session-permissions s))
                      (error "No such permission request"))))
       (drgnx-hub-note-permission-answer s (plist-get item :id) (drgnx-hub--value (plist-get params :option)) "user")
       (drgnx-agents-answer-permission s item (plist-get params :option))
       (drgnx-job--answered s)
       t))
    ;; the user's other actions on a session, from the editor that mirrors it
    ("agents/do"
     (let ((s (drgnx-hub--session params)) (n (plist-get params :n)))
       (pcase (plist-get params :op)
         ("deliver-queue" (drgnx-agents-deliver-queue s))
         ("unqueue" (drgnx-agents-unqueue s n))
         ("requeue" (drgnx-agents-requeue s n (plist-get params :text)))
         ("review" (let ((item (or (seq-find (lambda (r) (equal (format "%s" (plist-get r :id)) (format "%s" (plist-get params :item))))
                                             (drgnx-agent-session-reviews s))
                                   (error "No such review")))
                         (reject (drgnx-hub--value (plist-get params :reject))))
                     (drgnx-agents-finish-review s item reject)
                     (unless reject (drgnx-hub--review-edit s item))))
         (op (error "No action %s" op)))
       t))
    ;; jobs (drgnx-job.el): every answer is the job as `drgnx-job-summary' has it
    ("job/propose"
     (let ((id (drgnx-job-propose (plist-get params :plan) :repo (drgnx-hub--value (plist-get params :repo))
                                  :budget (drgnx-hub--value (plist-get params :budget))
                                  :gate (drgnx-hub--value (plist-get params :gate)))))
       (when (and (eq (plist-get params :auto) t) (equal (plist-get (drgnx-coord-job id) :status) "proposed"))
         (drgnx-job-approve id))
       (drgnx-job-summary id)))
    ;; Start as Job (the Work graph): task N of a plan and the tasks it needs, proposed — the plan is only read
    ("job/start-task"
     (let ((id (progn (unless (natnump (plist-get params :n)) (error "job/start-task wants n, a task's number"))   ; never the whole plan
                      (drgnx-job-propose (plist-get params :plan) :only (plist-get params :n) :gate (drgnx-hub--value (plist-get params :gate))))))
       (when (and (eq (plist-get params :auto) t) (equal (plist-get (drgnx-coord-job id) :status) "proposed"))
         (drgnx-job-approve id))
       (drgnx-job-summary id)))
    ;; writing back from the Work graph: the user's, each answered with the job's summary
    ("job/reassign" (drgnx-job-reassign (plist-get params :task) (plist-get params :profile)))
    ("job/block" (drgnx-job-block (plist-get params :task) (drgnx-hub--value (plist-get params :reason))))
    ("job/unblock" (drgnx-job-unblock (plist-get params :task)))
    ("job/order" (drgnx-job-order (plist-get params :task) (plist-get params :delta)))
    ("job/approve" (drgnx-job-approve (plist-get params :id) :budget (drgnx-hub--value (plist-get params :budget)))
     (drgnx-job-summary (plist-get params :id)))
    ("job/stop" (drgnx-job-stop (plist-get params :id)) (drgnx-job-summary (plist-get params :id)))
    ("job/resume" (drgnx-job-resume (plist-get params :id) :budget (drgnx-hub--value (plist-get params :budget)))
     (drgnx-hub--save-registrations)
     (drgnx-job-summary (plist-get params :id)))
    ("job/card" (drgnx-job-card-act (plist-get params :card) (plist-get params :action) (drgnx-hub--value (plist-get params :arg))))
    ("job/reply" (drgnx-job-reply (plist-get params :message) (plist-get params :text)))
    ("job/dismiss" (drgnx-job-dismiss (plist-get params :message)))   ; a message that needs no answer: acted on
    ("job/status"
     (if-let* ((id (drgnx-hub--value (plist-get params :id))))
         (or (drgnx-job-summary id (eq (plist-get params :decisions) t)) (error "No job %s" id))
       (list :jobs (mapcar #'drgnx-job-summary (drgnx-coord-jobs)))))
    (_ (list :error (format "no method %s" method)))))

(defun drgnx-hub--value (v) "V from JSON, null as nil." (unless (eq v :null) v))

(defun drgnx-hub-serving-p () "Is this Emacs the hub?" (and drgnx-hub--server (process-live-p drgnx-hub--server) t))

(defun drgnx-hub--set-keys (keys)
  "KEYS (:PROVIDER KEY…), from a client: kept in memory only (never written anywhere) — the gateway's, and the keys
this Emacs found (`drgnx-ai--keys'), which the agents the hub starts read without looking anywhere that may ask."
  (cl-loop for (k v) on keys by #'cddr
           when (and (keywordp k) (stringp v) (not (string-empty-p v)))
           do (let ((id (intern (substring (symbol-name k) 1))))
                (drgnx-gateway-set-key id v)
                (puthash id v drgnx-ai--keys))))

(defun drgnx-hub--set-env (env)
  "ENV, the variables an Emacs read from the user's login shell — a list of (:name NAME :value VALUE), at most 16, a
value at most 32768 characters (the contract's `env/set'; the {NAME: VALUE} object form is refused) — applied to the
hub's own environment (`drgnx-shell-env-apply'), only the names `drgnx-shell-env-names' allows and never a key: the
agents and jobs the hub starts from now on get the new PATH (running ones keep theirs).  Answers (:applied [NAME…])."
  (unless (and (proper-list-p env) (<= (length env) 16)
               (cl-every (lambda (c) (and (proper-list-p c) (keywordp (car-safe c)) (stringp (plist-get c :name))
                                          (stringp (plist-get c :value)) (<= (length (plist-get c :value)) 32768)))
                         env))
    (error "invalid params: env is a list of {name, value}, at most 16, values at most 32768 characters"))
  (let* ((allowed (drgnx-shell-env--names))
         (pairs (cl-loop for c in env
                         when (member (plist-get c :name) allowed)
                         collect (cons (plist-get c :name) (plist-get c :value)))))
    (drgnx-shell-env-apply pairs)
    (list :applied (vconcat (mapcar #'car pairs)))))

(defun drgnx-hub-register (params)
  "Register an agent with the gateway: PARAMS (:job :task :agent :chain ((PROVIDER MODEL)…) :budget :openrouter (the
restrictions of `drgnx-gateway-restrictions', lists or vectors) :keys (:PROVIDER KEY…) :owner PID), keys held in
memory; OWNER, the pid of the Emacs whose agent it is, ends it when it is gone
\(`drgnx-hub--prune-registrations').  (:token :url :openrouter KEPT): KEPT, the restrictions registered, lets the
editor check that they all were.  Restrictions that do not read refuse the registration (an error naming them)."
  (let ((restrictions (drgnx-gateway-restrictions (plist-get params :openrouter) t)))
    (drgnx-hub--set-keys (plist-get params :keys))
    (let ((token (drgnx-gateway-register (list :job (plist-get params :job) :task (plist-get params :task)
                                               :agent (plist-get params :agent)
                                               :owner (let ((o (plist-get params :owner))) (and (natnump o) o))
                                               :chain (drgnx-hub--chain (append (plist-get params :chain) nil))
                                               :openrouter restrictions
                                               :budget (or (plist-get params :budget) (drgnx-job-budget (plist-get params :job)))))))
      (drgnx-hub--save-registrations)
      (append (list :token token :url (format "http://127.0.0.1:%d" (drgnx-gateway-port)))
              (and restrictions (list :openrouter restrictions))))))

;;;; Agent sessions (held here; editors mirror them)

(defun drgnx-hub--entry-json (e)
  "Transcript entry E as the wire's JSON value (`drgnx-records-entry')."
  (drgnx-records-to-json 'drgnx-records-entry e))

(defun drgnx-hub--session (params)
  (or (drgnx-agents-get (plist-get params :id)) (error "No agent session %s" (plist-get params :id))))

(defun drgnx-hub--snapshot (s)
  "What an editor mirrors of session S (everything but the transcript), as a plist."
  (list :id (drgnx-agent-session-id s) :name (drgnx-agent-session-name s) :profile (drgnx-agent-session-profile s)
        :cwd (drgnx-agent-session-cwd s) :task (drgnx-agent-session-task s) :job (drgnx-agent-session-job s)
        :status (drgnx-agent-session-status s) :via (drgnx-agent-session-via s) :mode (drgnx-agent-session-mode s)
        :queue (drgnx-agent-session-queue s) :paused (drgnx-agent-session-paused s)
        :permissions (mapcar (lambda (p) (list :id (plist-get p :id) :title (plist-get p :title) :tool (plist-get p :tool)
                                               :options (plist-get p :options)))
                             (drgnx-agent-session-permissions s))
        :reviews (mapcar (lambda (r) (list :id (plist-get r :id) :path (plist-get r :path) :content (plist-get r :content)))
                         (drgnx-agent-session-reviews s))
        :usage (drgnx-agent-session-usage s) :commands (drgnx-agent-session-commands s)
        :capabilities (drgnx-agent-session-capabilities s) :exit (drgnx-agent-session-exit s)
        :stderr (let ((e (drgnx-agent-session-stderr s))) (and e (substring e (max 0 (- (length e) 2000)))))
        :entries-count (length (drgnx-agent-session-entries s))
        ;; no agent offers a gate yet (a hook before each tool): messages wait for the turn's end, its own edits are
        ;; not held while it is behind the decision log — only its coordination writes are
        :enforced (drgnx-job-enforced-p s)))

(defun drgnx-hub--snapshot-json (s)
  "Session S's snapshot as the wire's JSON value (`drgnx-records-session')."
  (drgnx-records-to-json 'drgnx-records-session (drgnx-hub--snapshot s)))

(defvar drgnx-hub--sent (make-hash-table :test #'equal) "Session id → the entries last sent to subscribers (copies).")
(defvar drgnx-hub--seq (make-hash-table :test #'equal)
  "Session id → how many times its changes went out: events carry it, `agents/get' answers it, so an editor that
fetched a transcript keeps only the events after it.")

(defvar drgnx-hub--saved-sessions nil "What `drgnx-hub--save-sessions' last wrote (or the hub read at start).")

(defun drgnx-hub--resumable ()
  "The sessions a next hub resumes, oldest first: (:id :name :profile :cwd :acp-id :task) of each live one the agent
made.  A job's agents are not among them: a job frees the task of an agent the hub took with it, and starts it again."
  (delq nil (mapcar (lambda (s) (and (drgnx-agent-session-acp-id s) (not (drgnx-agent-session-job s))
                                     (list :id (drgnx-agent-session-id s) :name (drgnx-agent-session-name s)
                                           :profile (drgnx-agent-session-profile s)
                                           :cwd (drgnx-agent-session-cwd s) :acp-id (drgnx-agent-session-acp-id s)
                                           :task (drgnx-agent-session-task s))))
                    (reverse (drgnx-hub--live-sessions)))))

(defun drgnx-hub--save-sessions ()
  "Keep `drgnx-hub--resumable' in hub/sessions.eld when it changed (a session started, ended, or its agent made it)."
  (let ((now (drgnx-hub--resumable)))
    (unless (equal now drgnx-hub--saved-sessions)
      (drgnx-hub--write-private (drgnx-hub--sessions-file) now)
      (setq drgnx-hub--saved-sessions now))))

(defun drgnx-hub--resume-sessions ()
  "Resume the sessions the previous hub kept (`drgnx-agents-take-over': ACP session/load), each under its own id and
name; one whose agent cannot load it ends (and so leaves the file).  A file that does not read as a list of sessions
is backed up and logged (`drgnx-hub--kept-unusable'): it never stops the hub from starting."
  (let* ((file (drgnx-hub--sessions-file))
         (saved (drgnx-hub--read-kept file "no session resumed")))
    (unless (proper-list-p saved)
      (drgnx-hub--kept-unusable file "not a list of sessions" "no session resumed")
      (setq saved nil))
    (setq drgnx-hub--saved-sessions saved)
    (dolist (e saved)
      (with-demoted-errors "drgnx hub: a session not resumed: %S"
        (drgnx-agents-take-over (plist-get e :profile) (plist-get e :cwd) (plist-get e :acp-id) (plist-get e :task)
                                (plist-get e :id) (plist-get e :name))))))

(defun drgnx-hub--agent-changed (s)
  "Session S changed: tell subscribers soon (one message per burst of changes)."
  (with-demoted-errors "drgnx hub: sessions not kept: %S" (drgnx-hub--save-sessions))
  (with-demoted-errors "drgnx hub: no events: %S" (drgnx-hub--session-events s))
  (when (drgnx-agents-free-p s)                                  ; free again: what waited goes now (a burst: once)
    (drgnx-timer-soon 'hub-deliver 0.1 #'drgnx-hub--deliver :owner :core))
  (drgnx-timer-soon (cons 'hub-flush (drgnx-agent-session-id s)) 0.05 #'drgnx-hub--flush :args (list s) :owner :core))

;;;; Events: what the agents here do, in the store's event log, and to subscribers in batches

(defvar drgnx-hub-events-interval 0.25 "Seconds between two `events' broadcasts, at the most often.")
(defconst drgnx-hub--events-batch 200 "The most events one `events' broadcast carries; more go in the next one.")
(defvar drgnx-hub--events-sent 0 "The id of the last event subscribers were sent.")
(defvar drgnx-hub--event-state (make-hash-table :test #'equal)
  "Session id → what its last events were derived from (`drgnx-hub--session-events'): (:busy BOOL :turn EVENT-ID
:from N :tools (TOOL-CALL-ID…) :permissions ((REQUEST-ID . QUESTION-EVENT-ID)…) :answers ((REQUEST-ID BY . OPTION)…)).
A session's entry goes when it exits, and all of them when the hub stops.")

(defun drgnx-hub--event-add (s kind summary &optional data agent)
  "Add an event of KIND by session S (or AGENT), of S's job and task — best effort: a busy store drops it — and
broadcast soon.  Its id, or nil."
  (prog1 (drgnx-coord-event-add-best-effort :agent (or agent (drgnx-agent-session-id s)) :job (drgnx-agent-session-job s)
                                            :task (drgnx-agent-session-task s) :kind kind :summary summary :data data)
    (drgnx-hub--events-soon)))

(defun drgnx-hub--edit-paths (paths)
  "PATHS as an `edit' event's data: at most 100 of them, then :more N for the rest."
  (append (list :paths (seq-take paths 100)) (and (nthcdr 100 paths) (list :more (- (length paths) 100)))))

(defun drgnx-hub--tool-open-p (e)
  "Whether tool entry E, or one of its children, may still change (not completed or failed)."
  (or (not (member (plist-get e :status) '("completed" "failed")))
      (seq-some #'drgnx-hub--tool-open-p (plist-get e :children))))

(defun drgnx-hub--tool-edits (s from seen turn)
  "Session S's edit tool calls (kind edit, delete or move; children too) completed in its entries from index FROM,
whose ids are not in SEEN: each becomes an `edit' event with the paths of its diffs — less the paths this turn (since
event TURN) recorded already, from a write request (an agent that writes through drgnx reports the tool call too), and
none when they all were.  (SEEN . FROM): the ids now seen, and the index of the first entry that may still change, from
which the next call looks."
  (let ((recorded :unread) (i from) (next nil))
    (cl-labels ((covered ()
                  (when (eq recorded :unread)
                    (setq recorded (cl-loop for e in (drgnx-coord-events :since turn :agent (drgnx-agent-session-id s) :kinds '("edit"))
                                            append (plist-get (plist-get e :data) :paths))))
                  recorded)
                (walk (e)
                  (when (eq (plist-get e :type) 'tool)
                    (let ((id (plist-get e :id)))
                      (when (and (member (plist-get e :kind) '("edit" "delete" "move")) (equal (plist-get e :status) "completed")
                                 id (not (member id seen)))
                        (push id seen)
                        (let* ((all (delete-dups (delq nil (mapcar (lambda (c) (and (equal (plist-get c :type) "diff")
                                                                                    (stringp (plist-get c :path)) (plist-get c :path)))
                                                                   (append (plist-get e :content) nil)))))
                               (paths (and all (seq-remove (lambda (p) (member p (covered))) all))))
                          (when (or paths (null all))
                            (drgnx-hub--event-add s "edit" (format "%s" (or (plist-get e :title) "an edit"))
                                                  (and paths (append (list :root (drgnx-agent-session-cwd s))
                                                                     (drgnx-hub--edit-paths paths)))))))
                      (mapc #'walk (plist-get e :children))))))
      (dolist (e (nthcdr from (drgnx-agent-session-entries s)))
        (walk e)
        (when (and (null next) (eq (plist-get e :type) 'tool) (drgnx-hub--tool-open-p e)) (setq next i))
        (setq i (1+ i))))
    (cons seen (or next i))))

(defun drgnx-hub-note-permission-answer (s request option by)
  "Session S's permission REQUEST is about to be answered with OPTION (nil: cancelled) by BY (\"user\"): its
`answer' event says so.  For whoever answers it in the hub (the `agents/permission' request, a job's card)."
  (let ((st (gethash (drgnx-agent-session-id s) drgnx-hub--event-state)))
    (when st
      (puthash (drgnx-agent-session-id s) (plist-put st :answers (cons (cons request (cons by option)) (plist-get st :answers)))
               drgnx-hub--event-state))))

(defun drgnx-hub--session-events (s)
  "What changed in session S as events, from what it was the last time (`drgnx-hub--event-state'):
- its life: seen first, `start' (data :head, the commit its folder is at); exited, `stop';
- a turn's start and end: `start' and `stop' with data (:turn t …), never read as its life;
- an edit tool call it completed: `edit', with the paths of its diffs a write request did not record already;
- a permission it asks: `question' (:permission ID); gone, an `answer' (:question EVENT-ID :permission ID :by BY
  :option OPTION) — by the user (`drgnx-hub-note-permission-answer'), else by drgnx: cancelled (Stop), or dropped
  when the agent ended."
  (let* ((id (drgnx-agent-session-id s)) (old (gethash id drgnx-hub--event-state))
         (exited (eq (drgnx-agent-session-status s) 'exited))
         (busy (and (not exited) (eq (drgnx-agent-session-status s) 'busy)))
         (was (plist-get old :busy)) (turn (plist-get old :turn))
         (from (if (and busy (not was)) (length (drgnx-agent-session-entries s)) (or (plist-get old :from) 0)))
         (asked (plist-get old :permissions)) (answers (plist-get old :answers)) (now nil) (tools (plist-get old :tools)))
    (unless (or old exited)
      (drgnx-hub--event-add s "start" "session started"
                            (when-let* ((head (drgnx-job-git-head (drgnx-agent-session-cwd s)))) (list :head head))))
    (when (or old (not exited))
      (when (and busy (not was))
        (setq tools nil turn (drgnx-hub--event-add s "start" "turn started" (list :turn t))))
      (when (or busy was)
        (pcase-let ((`(,seen . ,next) (drgnx-hub--tool-edits s from tools turn))) (setq tools seen from next)))
      (unless exited
        (dolist (p (drgnx-agent-session-permissions s))
          (let ((pid (plist-get p :id)))
            (push (or (assoc pid asked)
                      (cons pid (drgnx-hub--event-add s "question" (format "permission: %s" (or (plist-get p :title) "a tool call"))
                                                      (list :permission pid))))
                  now))))
      (dolist (a asked)
        (when (and (cdr a) (not (assoc (car a) now)))
          (let* ((how (cdr (assoc (car a) answers))) (by (or (car how) "drgnx")) (option (cdr how)))
            (drgnx-hub--event-add s "answer" (cond (how (format "permission answered: %s" (or option "cancelled")))
                                                   (exited "permission dropped: the agent ended")
                                                   (t "permission cancelled"))
                                  (append (list :question (cdr a) :permission (car a) :by by) (and option (list :option option)))
                                  (and how by)))))
      (when (and was (not busy))
        (drgnx-hub--event-add s "stop" (let ((last (car (last (drgnx-agent-session-entries s)))))
                                         (if (eq (plist-get last :type) 'stop) (format "turn ended (%s)" (plist-get last :stop)) "turn ended"))
                              (list :turn t)))
      (when exited (drgnx-hub--event-add s "stop" "session ended")))
    (if exited (remhash id drgnx-hub--event-state)
      (puthash id (list :busy busy :turn turn :from from :tools tools :permissions (nreverse now)
                        :answers (seq-filter (lambda (a) (assoc (car a) now)) answers))
               drgnx-hub--event-state))))

(defun drgnx-hub--review-edit (s item)
  "The user accepted session S's write request ITEM (a review): an `edit' event of its path."
  (drgnx-hub--event-add s "edit" (format "wrote %s" (file-name-nondirectory (plist-get item :path)))
                        (append (list :root (drgnx-agent-session-cwd s)) (drgnx-hub--edit-paths (list (plist-get item :path))))))

(defun drgnx-hub--events-soon ()
  "Send subscribers the new events soon: one `events' event per `drgnx-hub-events-interval' at the most often.  Behind
the front (`drgnx-hub--behind-front') nothing: the front broadcasts the event log."
  (unless drgnx-hub--behind-front
    (drgnx-timer-soon 'hub-events drgnx-hub-events-interval #'drgnx-hub--events-send :owner :core)))

(defun drgnx-hub--events-check ()
  "Events another process added (a coordination server, the CLI) or this one without a broadcast (a job's review,
merge and writes) go out too: the hub's tick, every 2 s."
  (when (> (or (caar (sqlite-select (drgnx-work-db) "select max(id) from event")) 0) drgnx-hub--events-sent)
    (drgnx-hub--events-soon)))

(defun drgnx-hub--event-rows (since limit)
  "The events after id SINCE, oldest first, at most LIMIT, for JSON: (:id :at :agent :job :task :kind :summary :data),
DATA the JSON object the store's checked column holds (schema 6), parsed; absent when there is none."
  (mapcar (pcase-lambda (`(,id ,at ,agent ,job ,task ,kind ,summary ,data))
            (let ((d (and (stringp data)
                          (ignore-errors (json-parse-string data :object-type 'plist :array-type 'array
                                                            :null-object :null :false-object :false)))))
              (append (list :id id :at at :agent agent :job job :task task :kind kind :summary summary)
                      (and d (list :data d)))))
          (sqlite-select (drgnx-work-db) (format "select %s from event where id > ? order by id limit ?" drgnx-coord--event-cols)
                         (list since limit))))

(defun drgnx-hub--events-send ()
  "Broadcast `events' (:since ID :last ID :events […]): the events added since the last broadcast."
  (with-demoted-errors "drgnx hub: events not sent: %S"
    (let ((since drgnx-hub--events-sent) (new (drgnx-hub--event-rows drgnx-hub--events-sent drgnx-hub--events-batch)))
      (when new
        (setq drgnx-hub--events-sent (plist-get (car (last new)) :id))
        (drgnx-hub--broadcast 'events (list :since since :last drgnx-hub--events-sent :events (vconcat new)))
        (when (= (length new) drgnx-hub--events-batch) (drgnx-hub--events-soon))))))

(defun drgnx-hub--events-since (params)
  "`events/since' for a client catching up: the events after :since (0), oldest first, at most :limit (200, at most
1000) — (:since ID :last ID :events […]), as `events' sends them."
  (let* ((since (let ((v (drgnx-hub--value (plist-get params :since)))) (if (natnump v) v 0)))
         (limit (let ((v (drgnx-hub--value (plist-get params :limit)))) (if (and (natnump v) (> v 0)) (min v 1000) 200)))
         (rows (drgnx-hub--event-rows since limit)))
    (list :since since :last (if rows (plist-get (car (last rows)) :id) since) :events (vconcat rows))))

;;;; Delivery: messages and decisions reach agents without interrupting them

(defvar drgnx-hub--told (make-hash-table :test #'equal) "Session name → the decision-log version it was last told of.")
(defvar drgnx-hub--ticks 0)

(defun drgnx-hub--live-sessions ()
  (seq-remove (lambda (s) (or (eq (drgnx-agent-session-status s) 'exited) (drgnx-agent-session-remote s)))
              (drgnx-agents-sessions)))

(defun drgnx-hub--for-p (s recipient)
  "Is RECIPIENT session S (its id, or its name)?"
  (or (equal recipient (drgnx-agent-session-id s)) (equal recipient (drgnx-agent-session-name s))))

(defun drgnx-hub--deliver ()
  "Give each queued message to the hub session it is for once that agent is free (idle, not paused by the user's
Stop, nothing queued): a new turn, never an interruption — until then it stays queued in the store, where
read_inbox finds it too.  Agents of a job behind its decision log are told what changed, the same way.  A message
for an agent that is not here (or exited) stays queued."
  (let ((sessions (drgnx-hub--live-sessions)))
    (dolist (m (drgnx-coord-queued))
      (when-let* ((s (seq-find (lambda (s) (drgnx-hub--for-p s (plist-get m :recipient))) sessions)))
        (when (and (drgnx-agents-free-p s) (drgnx-coord-mark (plist-get m :id) "delivered"))
          (drgnx-agents-deliver s (drgnx-coord-message-prompt m)))))
    (let ((v (drgnx-coord-version)))
      (when (> v 0)
        (dolist (s sessions)
          (when-let* ((job (drgnx-agent-session-job s)))
            (let* ((id (drgnx-agent-session-id s)) (seen (drgnx-coord-seen id))
                   (changes (and (< seen v) (< (gethash id drgnx-hub--told 0) v) (drgnx-coord-decisions-since seen job))))
              (when (and changes (drgnx-agents-free-p s))
                (puthash id v drgnx-hub--told)
                (drgnx-agents-deliver s (drgnx-coord-notice v job changes seen))))))))))

(defun drgnx-hub--prompted (_s text)
  "A prompt went to an agent: a message in it is now read."
  (when (string-match "\\`\\[message from [^#\n]* #\\([0-9]+\\) " text)
    (drgnx-coord-mark (string-to-number (match-string 1 text)) "read")))

(defun drgnx-hub--housekeeping ()
  "Renew the claims of the agents working here; release those whose lease ran out, and say so."
  (dolist (s (drgnx-hub--live-sessions)) (drgnx-coord-renew (drgnx-agent-session-id s)))
  (dolist (r (drgnx-coord-release-stale)) (drgnx-hub--broadcast 'lease-released r))
  (drgnx-coord-events-prune-daily))     ; at most once a day; never signals

(defun drgnx-hub--tick ()
  (with-demoted-errors "drgnx hub: %S"
    (drgnx-hub--deliver)
    (drgnx-job-tick)
    (drgnx-hub--prune-registrations)
    (drgnx-hub--drop-stuck)
    (unless drgnx-hub--behind-front (drgnx-hub--events-check))   ; behind the front, the front broadcasts the log
    (when (zerop (% (cl-incf drgnx-hub--ticks) 30)) (drgnx-hub--housekeeping))))

(defun drgnx-hub--flush (s)
  "Send S's snapshot, and the entries that are new or changed since the last time, as `agent' / `agent-entries'."
  (let* ((id (drgnx-agent-session-id s)) (sent (gethash id drgnx-hub--sent)) (changed nil) (i 0))
    (drgnx-agents-join-text s)                  ; the wire carries whole texts (RP7-e: send deltas instead)
    (dolist (e (drgnx-agent-session-entries s))
      (unless (equal e (and sent (< i (length sent)) (aref sent i)))
        (push (vector i (drgnx-hub--entry-json e)) changed))
      (setq i (1+ i)))
    (puthash id (vconcat (mapcar #'copy-tree (drgnx-agent-session-entries s))) drgnx-hub--sent)
    (let ((seq (puthash id (1+ (gethash id drgnx-hub--seq 0)) drgnx-hub--seq)))
      (drgnx-hub--broadcast 'agent (list :id id :seq seq :session (drgnx-hub--snapshot-json s)))
      (when changed (drgnx-hub--broadcast 'agent-entries (list :id id :seq seq :entries (vconcat (nreverse changed))))))))

(defun drgnx-hub--exit-now (exit)
  "Call EXIT, the exit function of the hub that was asked to `shutdown'."
  (funcall exit))

(defun drgnx-hub--serve-request (conn json)
  (let ((id (plist-get json :id)) (method (plist-get json :method)))
    (pcase method
      ("subscribe" (cl-pushnew conn drgnx-hub--subscribers) (drgnx-hub--answer conn (list :id id :result t)))
      ("shutdown" (drgnx-hub--answer conn (list :id id :result t))
       ;; the exit of this hub, as it is now: a hub stopped meanwhile cancels it (it never reaches the next one)
       (let ((exit drgnx-hub--exit-function))
         (drgnx-timer-start 'hub-exit 0.1 #'drgnx-hub--exit-now :args (list exit) :owner :core)))
      (_ (let ((r (condition-case err (drgnx-hub--method method (plist-get json :params))
                    (error (list :error (error-message-string err))))))
           ;; a notification (no id) is answered by nothing
           (when id (drgnx-hub--answer conn (if (and (consp r) (eq (car r) :error) (stringp (cadr r)) (null (cddr r)))
                                                (list :id id :error (list :message (cadr r)))
                                              (list :id id :result r)))))))))

(defun drgnx-hub--admitted-p (conn json)
  "Is CONN past the backend's door?  Its first line JSON (nil: not JSON) must carry the secret; any other first line
closes CONN, logged without what it said.  Always so for a hub with no `drgnx-hub--secret'."
  (cond ((or (null drgnx-hub--secret) (process-get conn 'drgnx-hub-admitted)) t)
        ((let ((auth (plist-get json :auth)))
           ;; the digests, not the strings: no early exit on the secret's own bytes
           (and (stringp auth) (string= (secure-hash 'sha256 auth) (secure-hash 'sha256 drgnx-hub--secret))))
         (process-put conn 'drgnx-hub-admitted t)
         nil)
        (t (message "drgnx hub: refused a connection without the backend secret")
           (delete-process conn)
           nil)))

(defun drgnx-hub--receive (conn json)
  "A request JSON from CONN, served once CONN is admitted (`drgnx-hub--admitted-p'); its first line is the door's."
  (when (drgnx-hub--admitted-p conn json) (drgnx-hub--serve-request conn json)))

(defun drgnx-hub--receive-malformed (conn line)
  "LINE from CONN is not JSON: an error answer once CONN is admitted; as its first line, the door closes CONN."
  (when (drgnx-hub--admitted-p conn nil) (drgnx-hub--malformed conn line)))

(defun drgnx-hub--broadcast (event data)
  "Send EVENT with DATA to every subscriber: queued for each first, then written — so while one waits (a slow
reader), a newer event never reaches another before this one."
  (setq drgnx-hub--subscribers (seq-filter #'process-live-p drgnx-hub--subscribers))
  (let ((line (concat (json-serialize (drgnx-hub--jsonable (list :event (symbol-name event) :data data))) "\n"))
        (subscribers drgnx-hub--subscribers))
    (dolist (c subscribers) (drgnx-hub--enqueue c line))
    (dolist (c subscribers) (drgnx-hub--drain c))))

(defun drgnx-hub-serve (socket)
  "Be the hub on SOCKET: the gateway started, the registrations a previous hub kept taken back.  Returns the server.
Signals an error when a hub already serves there."
  (when (drgnx-hub--ping-socket socket) (error "a hub already serves on %s" socket))
  (drgnx-hub--private-dir (file-name-directory socket))
  (drgnx-hub--take-lock socket)
  (ignore-errors (delete-file socket))
  ;; the port agents were given, again (running agents keep the address they started with)
  (let* ((file (drgnx-hub--port-file))
         (old (ignore-errors (string-to-number (with-temp-buffer (insert-file-contents file) (buffer-string))))))
    (unless (and old (> old 0) (ignore-errors (drgnx-gateway-start old)))
      (when (and old (> old 0)) (message "drgnx hub: port %d is taken; agents started before must start again" old))
      (drgnx-gateway-start))
    (drgnx-file-write-text file (number-to-string (drgnx-gateway-port))))
  (drgnx-hub--load-registrations)
  (drgnx-hub--prune-registrations)
  (add-hook 'drgnx-gateway-event-functions #'drgnx-hub--broadcast)
  (add-hook 'drgnx-agents-changed-functions #'drgnx-hub--agent-changed)
  (add-hook 'drgnx-agents-prompt-functions #'drgnx-hub--prompted)
  (add-hook 'drgnx-agents-changed-functions #'drgnx-job--session-changed)
  (add-hook 'drgnx-agents-request-functions #'drgnx-job--request)
  (add-hook 'drgnx-agents-error-functions #'drgnx-job--agent-error)
  (add-hook 'drgnx-gateway-event-functions #'drgnx-job--gateway-event)
  (drgnx-timer-start 'hub-tick 2 #'drgnx-hub--tick :repeat 2 :owner :core)
  ;; subscribers get the events from now on (`events/since' has the ones before)
  (setq drgnx-hub--events-sent (or (caar (sqlite-select (drgnx-work-db) "select max(id) from event")) 0))
  (setq drgnx-hub--started (format-time-string "%FT%T%z")
        drgnx-hub--server
        (make-network-process :name "drgnx-hub" :family 'local :server t :service socket :noquery t
                              :coding 'utf-8-unix
                              :filter (drgnx-guard-wrap
                                       (lambda (conn chunk)
                                         (drgnx-hub--lines conn chunk (lambda (j) (drgnx-hub--receive conn j))
                                                           (lambda (line) (drgnx-hub--receive-malformed conn line))
                                                           drgnx-hub--max-line))
                                       "hub requests")))
  ;; serving now: a resumed agent registers with this hub's gateway directly
  (drgnx-hub--resume-sessions)
  drgnx-hub--server)

(defun drgnx-hub-stop ()
  "Stop being the hub (the socket closed and removed, the gateway stopped, its registrations dropped from memory)."
  (when drgnx-hub--server
    (let ((socket (process-contact drgnx-hub--server :service)))
      (delete-process drgnx-hub--server)
      ;; only what is still ours: a hub that took over meanwhile keeps its socket
      (when (eql (drgnx-hub--lock-pid socket) (emacs-pid))
        (ignore-errors (delete-file socket))
        (ignore-errors (delete-directory (drgnx-hub--lock socket) t)))))
  (dolist (c drgnx-hub--subscribers) (when (process-live-p c) (delete-process c)))
  (setq drgnx-hub--server nil drgnx-hub--subscribers nil)
  (remove-hook 'drgnx-gateway-event-functions #'drgnx-hub--broadcast)
  (remove-hook 'drgnx-agents-changed-functions #'drgnx-hub--agent-changed)
  (remove-hook 'drgnx-agents-prompt-functions #'drgnx-hub--prompted)
  (remove-hook 'drgnx-agents-changed-functions #'drgnx-job--session-changed)
  (remove-hook 'drgnx-agents-request-functions #'drgnx-job--request)
  (remove-hook 'drgnx-agents-error-functions #'drgnx-job--agent-error)
  (remove-hook 'drgnx-gateway-event-functions #'drgnx-job--gateway-event)
  (dolist (key '(hub-tick hub-exit hub-events hub-deliver)) (drgnx-timer-cancel key))
  (dolist (entry (drgnx-timer-pending))
    (when (eq (car-safe (car entry)) 'hub-flush) (drgnx-timer-cancel (car entry))))
  (clrhash drgnx-hub--event-state)
  (clrhash drgnx-hub--told)
  (clrhash drgnx-hub--sent)
  (setq drgnx-hub--saved-sessions nil)
  (drgnx-gateway-stop)
  (clrhash drgnx-gateway--registrations))

(defun drgnx-hub--take-serve-env ()
  "(SOCKET PARENT-PID SECRET) from DRGNX_HUB_SERVE_SOCKET (an absolute name; nil when unset or empty; (:invalid
VALUE) when set to anything else), DRGNX_HUB_PARENT_PID (0 when unset) and DRGNX_HUB_SERVE_SECRET (nil when unset or
empty), all then unset in this Emacs: nothing it starts afterwards (agents, their coordination servers, an agent's
`drgnx job', a test run inside a job) sees them.  Ratatoskr starts the Lisp hub as its backend on a socket of its
own, with the secret its connections must show; those children find the hub through `drgnx-hub-socket', the front,
never the backend."
  (let ((socket (getenv "DRGNX_HUB_SERVE_SOCKET"))
        (parent (string-to-number (or (getenv "DRGNX_HUB_PARENT_PID") "0")))
        (secret (getenv "DRGNX_HUB_SERVE_SECRET")))
    (dolist (name '("DRGNX_HUB_SERVE_SOCKET" "DRGNX_HUB_PARENT_PID" "DRGNX_HUB_SERVE_SECRET"))
      (setenv name nil))
    (list (cond ((or (null socket) (string-empty-p socket)) nil)
                ((string-prefix-p "/" socket) socket)
                (t (list :invalid socket)))
          parent
          (and secret (not (string-empty-p secret)) secret))))

(defun drgnx-hub-main ()
  "The hub process's entry point (batch): serve until `shutdown' or SIGTERM.  Exit 3 when a hub already serves, 1
when it cannot start for any other reason.  It serves on DRGNX_HUB_SERVE_SOCKET when that is set (Ratatoskr's Lisp
backend), else on `drgnx-hub-socket'; both that and DRGNX_HUB_PARENT_PID are read and unset before anything starts a
process (`drgnx-hub--take-serve-env').  A DRGNX_HUB_SERVE_SOCKET that is set but not an absolute name is exit 1: it
never falls back to the front's socket.  So is one without DRGNX_HUB_SERVE_SECRET: the backend serves only Ratatoskr
(`drgnx-hub--secret').
With a serve socket it is the backend behind Ratatoskr's front: `drgnx-hub--behind-front' is set, the coordination
writers call the front (`drgnx-coord-writer' `front', `drgnx-hub-call-front'), and the front broadcasts the event
log (no `events' from here).  Without one it is the standalone Lisp hub and writes work.db itself (`local')."
  (pcase-let* ((`(,serve ,parent ,secret) (drgnx-hub--take-serve-env))
               (socket (cond ((consp serve)
                              (message "drgnx hub: DRGNX_HUB_SERVE_SOCKET is not an absolute name: %s" (cadr serve))
                              (kill-emacs 1))
                             ((and serve (not secret))
                              (message "drgnx hub: DRGNX_HUB_SERVE_SOCKET is set without DRGNX_HUB_SERVE_SECRET")
                              (kill-emacs 1))
                             (t (or serve (drgnx-hub-socket))))))
    (setq drgnx-hub--secret (and serve secret)
          drgnx-hub--behind-front (and serve t)
          drgnx-coord-writer (if serve 'front 'local))
    (drgnx-gc-batch-setup)
    (setq drgnx-timer-report-file "hub-timers-report.eld")   ; the hub's stopped timers go to a file of their own
    (drgnx-sandbox-vc-mode 1)                       ; the hub's own git never runs in a job's folder either
    (condition-case err
        (drgnx-hub-serve socket)
      (error (let ((already (string-prefix-p "a hub already serves" (error-message-string err))))
               (message "drgnx hub: %s" (if already "a hub already serves" (error-message-string err)))
               (kill-emacs (if already 3 1)))))
    (add-hook 'kill-emacs-hook #'drgnx-hub-stop)
    (message "drgnx hub: serving on %s, gateway on 127.0.0.1:%d" socket (drgnx-gateway-port))
    ;; a test's hub (DRGNX_HUB_PARENT_PID: its test Emacs) and Ratatoskr's backend end with their parent, never
    ;; outliving it
    (while t
      (accept-process-output nil 1)
      (dotimes (_ 2) (read-event nil nil 0.002))     ; queued events would hold back process sentinels
      (when (and (> parent 0) (not (drgnx-hub--alive-p parent)))
        (message "drgnx hub: its parent (pid %d) is gone" parent)
        (kill-emacs 0)))))

(provide 'drgnx-hub)
;;; drgnx-hub.el ends here
