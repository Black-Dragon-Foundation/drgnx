;;; drgnx-hub.el --- The hub: a durable process for agents and their gateway, and its client -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The hub is a batch Emacs started as a durable job (drgnx-jobs.el): it outlives the Emacs that started it, and
;; holds what must keep running while editors come and go — today the agent traffic gateway (drgnx-gateway.el).
;; Editors, the CLI and tests talk to it over a Unix socket in a directory only the user can enter: one JSON object
;; per line, requests {id, method, params} answered {id, result} or {id, error}, and events {event, data} for the
;; connections that subscribed.  One hub per drgnx data directory.  See docs/develop/hub.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-gateway)
(require 'drgnx-jobs)
(require 'drgnx-agents)
(require 'drgnx-coord)
(require 'drgnx-job)
(require 'drgnx-job-clash)

(defvar drgnx-hub-event-functions nil
  "Functions called with (EVENT DATA) for each event the hub sends this Emacs (after `drgnx-hub-connect'); EVENT a
string (\"request\", \"fallback\", \"budget\"), DATA a plist.")

(defvar drgnx-hub-disconnect-functions nil
  "Called when this Emacs's event connection to the hub closes (the hub ended, or `drgnx-hub-disconnect').")

(defvar drgnx-hub--server nil "This Emacs's hub socket, when it is the hub.")
(defvar drgnx-hub--subscribers nil "Connections that asked for events.")
(defvar drgnx-hub--started nil)
(defvar drgnx-hub--exit-function (lambda () (kill-emacs 0)) "What `shutdown' does (tests: stop serving).")
(defvar drgnx-hub--exit-timer nil "A `shutdown' about to happen (a stopped hub cancels it).")

(defvar drgnx-hub--client nil "This Emacs's connection to the hub, for requests.")
(defvar drgnx-hub--events nil "This Emacs's subscribed connection to the hub.")
(defvar drgnx-hub--subscribing nil "This Emacs's connection whose `subscribe' the hub has not answered yet.")
(defvar drgnx-hub--pending (make-hash-table) "Request id → callback.")
(defvar drgnx-hub--next-id 0)

(defconst drgnx-hub--env-names
  '("DRGNX_DATA_DIR" "DRGNX_CONFIG_DIR" "XDG_STATE_HOME" "XDG_DATA_HOME" "XDG_CONFIG_HOME" "XDG_RUNTIME_DIR"
    "DRGNX_HUB_PARENT_PID")
  "Variables the hub gets from the Emacs that starts it (when set): the same dirs and (tests only) the pid it ends
with.  Never a key: a systemd unit keeps its environment where `systemctl --user show' prints it; keys come over the
socket (`drgnx-hub--send-keys').")

;;;; Where

(defun drgnx-hub-socket ()
  "The hub's socket: $XDG_RUNTIME_DIR/drgnx/hub-HASH.sock (HASH of the data dir: one hub per data dir), else under
the state dir."
  (let* ((name (format "hub-%s.sock" (substring (secure-hash 'sha1 (drgnx-data-dir)) 0 8)))
         (run (getenv "XDG_RUNTIME_DIR"))
         (path (if (and run (file-directory-p run))
                   (expand-file-name name (expand-file-name "drgnx" run))
                 (expand-file-name name (expand-file-name "hub" (drgnx-state-dir))))))
    ;; a Unix socket's path ends with a NUL inside 104 bytes on macOS (108 on Linux): at most 103; a deep state
    ;; dir gets a short private one instead.  Counted as the system sees it: encoded (macOS decomposes "é" to 3 bytes)
    (if (<= (length (encode-coding-string path (or file-name-coding-system default-file-name-coding-system))) 103) path
      (expand-file-name name (expand-file-name (format "drgnx-hub-%d" (user-uid)) temporary-file-directory)))))

(defun drgnx-hub--private-dir (dir)
  "Make DIR (mode 0700) and make sure it is this user's own (a shared /tmp: never another's directory)."
  (make-directory dir t)
  (unless (eql (file-attribute-user-id (file-attributes dir)) (user-uid))
    (error "%s belongs to another user" dir))
  (set-file-modes dir #o700))

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

;;;; JSON

(defun drgnx-hub--jsonable (v)
  "V with symbols as strings and nil as null, for `json-serialize'."
  (cond ((null v) :null)
        ((memq v '(t :null :false)) v)
        ((keywordp v) v)
        ((symbolp v) (symbol-name v))
        ((and (consp v) (keywordp (car v)))
         (cl-loop for (k x) on v by #'cddr append (list k (drgnx-hub--jsonable x))))
        ((consp v) (vconcat (mapcar #'drgnx-hub--jsonable v)))
        ((vectorp v) (vconcat (mapcar #'drgnx-hub--jsonable v)))
        (t v)))

(defun drgnx-hub--send (conn object)
  "Send OBJECT to CONN — unless CONN is gone: a client may leave before its answer (a coordination server's notify,
a probe), and writing to it then must be nothing, never an error in a filter (it would end a batch Emacs that
debugs errors, and without SIGPIPE ignored the write itself would)."
  (when (process-live-p conn)
    (condition-case nil
        (process-send-string conn (concat (json-serialize (drgnx-hub--jsonable object)) "\n"))
      (error (ignore-errors (delete-process conn))))))

(defconst drgnx-hub--max-line (* 1024 1024)
  "The longest request line the hub reads (characters): a longer one closes its connection.")

(defun drgnx-hub--lines (conn chunk fn &optional bad limit)
  "Split CONN's input into lines; FN gets each parsed JSON object, BAD (when given) each line that is not JSON.
With LIMIT, a line longer than LIMIT closes CONN: nothing after it is read."
  (let ((buf (concat (or (process-get conn :buf) "") chunk)))
    (while (and buf (string-match "\n" buf))
      (let ((line (substring buf 0 (match-beginning 0))))
        (setq buf (substring buf (match-end 0)))
        (if (and limit (> (length line) limit)) (setq buf nil)
          (let ((json (condition-case nil
                          (json-parse-string line :object-type 'plist :array-type 'list :null-object nil :false-object nil)
                        (error :bad))))
            (cond ((eq json :bad) (when bad (funcall bad line)))
                  (json (funcall fn json)))))))
    (if (and buf (not (and limit (> (length buf) limit))))
        (process-put conn :buf buf)
      (message "drgnx hub: a line over %d characters; its connection is closed" limit)
      (delete-process conn))))

(defun drgnx-hub--malformed (conn line)
  "LINE from CONN is not JSON: when its id can be read, it is answered with an error (its sender would wait)."
  (when (string-match "\"id\"[ \t]*:[ \t]*\\(-?[0-9]+\\)[ \t]*[,}]" line)
    (drgnx-hub--send conn (list :id (string-to-number (match-string 1 line)) :error (list :message "not a JSON object")))))

;;;; The hub side

(defun drgnx-hub--save-registrations ()
  "Keep the registrations (mode 0600): written to a temporary file beside the old one, then renamed over it, so a hub
that dies mid-write leaves the old file whole."
  (let* ((file (drgnx-hub--registrations-file))
         (tmp (progn (make-directory (file-name-directory file) t)
                     (with-file-modes #o600 (make-temp-file (concat file "-"))))))
    (unwind-protect
        (with-temp-buffer
          (let ((print-length nil) (print-level nil)) (prin1 (drgnx-gateway-registrations) (current-buffer)))
          (let ((coding-system-for-write 'utf-8-unix)) (write-region nil nil tmp nil 'silent))
          (set-file-modes tmp #o600)
          (rename-file tmp file t))
      (when (file-exists-p tmp) (delete-file tmp)))))

(defun drgnx-hub--load-registrations ()
  "Take back the registrations a previous hub kept; a file that cannot be read is logged (its agents register again)."
  (let ((file (drgnx-hub--registrations-file)))
    (when (file-readable-p file)
      (condition-case err
          (drgnx-gateway-load-registrations (with-temp-buffer (insert-file-contents file) (read (current-buffer))))
        (error (message "drgnx hub: %s cannot be read (%s): agents registered before must register again"
                        file (error-message-string err)))))))

(defun drgnx-hub--chain (chain)
  "A chain from JSON ([[provider, model-or-null]…]) as ((PROVIDER . MODEL)…)."
  (mapcar (lambda (step) (cons (intern (car step)) (cadr step))) chain))

(defun drgnx-hub--method (method params)
  "The result of METHOD with PARAMS, or (:error MESSAGE)."
  (pcase method
    ("ping" (list :pid (emacs-pid)))
    ("status" (list :pid (emacs-pid) :socket (drgnx-hub-socket) :gateway_port (drgnx-gateway-port)
                    :registrations (length (drgnx-gateway-registrations)) :started drgnx-hub--started))
    ("gateway/register" (drgnx-hub-register params))
    ("gateway/unregister" (drgnx-gateway-unregister (plist-get params :token)) (drgnx-hub--save-registrations) t)
    ("gateway/keys" (drgnx-hub--set-keys (plist-get params :keys)) t)
    ("coord/notify" (run-at-time 0 nil #'drgnx-hub--deliver)   ; a coordination server wrote: deliver now, look for clashes
     (run-at-time 0 nil (lambda () (dolist (j (drgnx-coord-jobs "running")) (with-demoted-errors "drgnx job: %S" (drgnx-job-clash-scan j)))))
     t)   ; a coordination server wrote: deliver now
    ("spend" (drgnx-work-db-spend :job (plist-get params :job) :task (plist-get params :task) :agent (plist-get params :agent)))
    ("agents/start"
     (let ((s (drgnx-agents-start (plist-get params :profile) (plist-get params :cwd) (plist-get params :task) (plist-get params :job))))
       (list :id (drgnx-agent-session-id s) :name (drgnx-agent-session-name s))))
    ("agents/list" (list :sessions (vconcat (mapcar #'drgnx-hub--snapshot-lisp (drgnx-agents-sessions)))))
    ("agents/get" (let ((s (drgnx-hub--session params)))
                    (list :lisp (drgnx-hub--snapshot-lisp s) :entries (drgnx-hub--lisp (drgnx-agent-session-entries s))
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
         ("review" (drgnx-agents-finish-review
                    s (or (seq-find (lambda (r) (equal (format "%s" (plist-get r :id)) (format "%s" (plist-get params :item))))
                                    (drgnx-agent-session-reviews s))
                          (error "No such review"))
                    (plist-get params :reject)))
         (op (error "No action %s" op)))
       t))
    ;; jobs (drgnx-job.el): every answer is the job as `drgnx-job-summary' has it
    ("job/propose"
     (let ((id (drgnx-job-propose (plist-get params :plan) :repo (drgnx-hub--value (plist-get params :repo))
                                  :budget (drgnx-hub--value (plist-get params :budget)))))
       (when (and (eq (plist-get params :auto) t) (equal (plist-get (drgnx-coord-job id) :status) "proposed"))
         (drgnx-job-approve id))
       (drgnx-job-summary id)))
    ("job/approve" (drgnx-job-approve (plist-get params :id) :budget (drgnx-hub--value (plist-get params :budget)))
     (drgnx-job-summary (plist-get params :id)))
    ("job/stop" (drgnx-job-stop (plist-get params :id)) (drgnx-job-summary (plist-get params :id)))
    ("job/resume" (drgnx-job-resume (plist-get params :id) :budget (drgnx-hub--value (plist-get params :budget)))
     (drgnx-hub--save-registrations)
     (drgnx-job-summary (plist-get params :id)))
    ("job/card" (drgnx-job-card-act (plist-get params :card) (plist-get params :action) (drgnx-hub--value (plist-get params :arg))))
    ("job/reply" (drgnx-job-reply (plist-get params :message) (plist-get params :text)))
    ("job/status"
     (if-let* ((id (drgnx-hub--value (plist-get params :id))))
         (or (drgnx-job-summary id (eq (plist-get params :decisions) t)) (error "No job %s" id))
       (list :jobs (mapcar #'drgnx-job-summary (drgnx-coord-jobs)))))
    (_ (list :error (format "no method %s" method)))))

(defun drgnx-hub--value (v) "V from JSON, null as nil." (unless (eq v :null) v))

(defun drgnx-hub-serving-p () "Is this Emacs the hub?" (and drgnx-hub--server (process-live-p drgnx-hub--server) t))

(defun drgnx-hub--set-keys (keys)
  "KEYS (:PROVIDER KEY…), from a client: kept in the gateway's memory only (never written anywhere)."
  (cl-loop for (k v) on keys by #'cddr
           when (and (keywordp k) (stringp v) (not (string-empty-p v)))
           do (drgnx-gateway-set-key (intern (substring (symbol-name k) 1)) v)))

(defun drgnx-hub-register (params)
  "Register an agent with the gateway: PARAMS (:job :task :agent :chain ((PROVIDER MODEL)…) :budget :keys (:PROVIDER
KEY…)), keys held in memory.  (:token :url)."
  (drgnx-hub--set-keys (plist-get params :keys))
  (let ((token (drgnx-gateway-register (list :job (plist-get params :job) :task (plist-get params :task)
                                             :agent (plist-get params :agent)
                                             :chain (drgnx-hub--chain (append (plist-get params :chain) nil))
                                             :budget (or (plist-get params :budget) (drgnx-job-budget (plist-get params :job)))))))
    (drgnx-hub--save-registrations)
    (list :token token :url (format "http://127.0.0.1:%d" (drgnx-gateway-port)))))

;;;; Agent sessions (held here; editors mirror them)

(defun drgnx-hub--lisp (v) (let ((print-length nil) (print-level nil) (print-circle nil)) (prin1-to-string v)))

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

(defun drgnx-hub--snapshot-lisp (s) (drgnx-hub--lisp (drgnx-hub--snapshot s)))

(defvar drgnx-hub--sent (make-hash-table :test #'equal) "Session id → the entries last sent to subscribers (copies).")
(defvar drgnx-hub--flush-timers (make-hash-table :test #'equal))
(defvar drgnx-hub--seq (make-hash-table :test #'equal)
  "Session id → how many times its changes went out: events carry it, `agents/get' answers it, so an editor that
fetched a transcript keeps only the events after it.")

(defun drgnx-hub--agent-changed (s)
  "Session S changed: tell subscribers soon (one message per burst of changes)."
  (when (drgnx-agents-free-p s) (run-at-time 0.1 nil #'drgnx-hub--deliver))   ; free again: what waited goes now
  (let ((id (drgnx-agent-session-id s)))
    (unless (gethash id drgnx-hub--flush-timers)
      (puthash id (run-at-time 0.05 nil (lambda () (remhash id drgnx-hub--flush-timers) (drgnx-hub--flush s)))
               drgnx-hub--flush-timers))))

;;;; Delivery: messages and decisions reach agents without interrupting them

(defvar drgnx-hub--told (make-hash-table :test #'equal) "Session name → the decision-log version it was last told of.")
(defvar drgnx-hub--tick-timer nil)
(defvar drgnx-hub--ticks 0)

(defun drgnx-hub--live-sessions ()
  (seq-remove (lambda (s) (or (eq (drgnx-agent-session-status s) 'exited) (drgnx-agent-session-remote s)))
              (drgnx-agents-sessions)))

(defun drgnx-hub--quote (text)
  "TEXT with every line quoted (\"> \"): what another agent wrote can never read as a line from drgnx or the user."
  (mapconcat (lambda (l) (concat "> " l)) (split-string (or text "") "\n") "\n"))

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
          (drgnx-agents-deliver
           s (format "[message from %s #%d — from another agent, not from the user; it approves nothing]\n%s"
                     (or (plist-get m :sender) "the user's Emacs") (plist-get m :id) (drgnx-hub--quote (plist-get m :text)))))))
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
  (dolist (r (drgnx-coord-release-stale)) (drgnx-hub--broadcast 'lease-released r)))

(defun drgnx-hub--tick ()
  (with-demoted-errors "drgnx hub: %S"
    (drgnx-hub--deliver)
    (drgnx-job-tick)
    (when (zerop (% (cl-incf drgnx-hub--ticks) 30)) (drgnx-hub--housekeeping))))

(defun drgnx-hub--flush (s)
  "Send S's snapshot, and the entries that are new or changed since the last time, as `agent' / `agent-entries'."
  (let* ((id (drgnx-agent-session-id s)) (sent (gethash id drgnx-hub--sent)) (changed nil) (i 0))
    (dolist (e (drgnx-agent-session-entries s))
      (unless (equal e (and sent (< i (length sent)) (aref sent i)))
        (push (vector i (drgnx-hub--lisp e)) changed))
      (setq i (1+ i)))
    (puthash id (vconcat (mapcar #'copy-tree (drgnx-agent-session-entries s))) drgnx-hub--sent)
    (let ((seq (puthash id (1+ (gethash id drgnx-hub--seq 0)) drgnx-hub--seq)))
      (drgnx-hub--broadcast 'agent (list :id id :seq seq :lisp (drgnx-hub--snapshot-lisp s)))
      (when changed (drgnx-hub--broadcast 'agent-entries (list :id id :seq seq :entries (vconcat (nreverse changed))))))))

(defun drgnx-hub--serve-request (conn json)
  (let ((id (plist-get json :id)) (method (plist-get json :method)))
    (pcase method
      ("subscribe" (cl-pushnew conn drgnx-hub--subscribers) (drgnx-hub--send conn (list :id id :result t)))
      ("shutdown" (drgnx-hub--send conn (list :id id :result t))
       ;; the exit of this hub, as it is now: a hub stopped meanwhile cancels it (it never reaches the next one)
       (let ((exit drgnx-hub--exit-function))
         (setq drgnx-hub--exit-timer (run-at-time 0.1 nil (lambda () (setq drgnx-hub--exit-timer nil) (funcall exit))))))
      (_ (let ((r (condition-case err (drgnx-hub--method method (plist-get json :params))
                    (error (list :error (error-message-string err))))))
           ;; a notification (no id) is answered by nothing
           (when id (drgnx-hub--send conn (if (and (consp r) (eq (car r) :error) (stringp (cadr r)) (null (cddr r)))
                                              (list :id id :error (list :message (cadr r)))
                                            (list :id id :result r)))))))))

(defun drgnx-hub--broadcast (event data)
  (setq drgnx-hub--subscribers (seq-filter #'process-live-p drgnx-hub--subscribers))
  (dolist (c drgnx-hub--subscribers) (drgnx-hub--send c (list :event (symbol-name event) :data data))))

(defun drgnx-hub--ping-socket (socket)
  "Does a hub answer on SOCKET?  (At most a second.)"
  (when (file-exists-p socket)
    (condition-case nil
        (let* ((got nil)
               (c (make-network-process :name "drgnx-hub-probe" :family 'local :service socket :noquery t
                                        :coding 'utf-8-unix :filter (lambda (_p s) (setq got (concat got s))))))
          (unwind-protect
              (progn (process-send-string c "{\"id\":0,\"method\":\"ping\"}\n")
                     (let ((deadline (+ (float-time) 1)))
                       (while (and (not (and got (string-search "\n" got))) (< (float-time) deadline))
                         (accept-process-output nil 0.02)))
                     (and got (string-search "\"pid\"" got) t))
            (delete-process c)))
      (error nil))))

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
    (make-directory (file-name-directory file) t)
    (write-region (number-to-string (drgnx-gateway-port)) nil file nil 'silent))
  (drgnx-hub--load-registrations)
  (add-hook 'drgnx-gateway-event-functions #'drgnx-hub--broadcast)
  (add-hook 'drgnx-agents-changed-functions #'drgnx-hub--agent-changed)
  (add-hook 'drgnx-agents-prompt-functions #'drgnx-hub--prompted)
  (add-hook 'drgnx-agents-changed-functions #'drgnx-job--session-changed)
  (add-hook 'drgnx-agents-request-functions #'drgnx-job--request)
  (add-hook 'drgnx-agents-error-functions #'drgnx-job--agent-error)
  (add-hook 'drgnx-gateway-event-functions #'drgnx-job--gateway-event)
  (setq drgnx-hub--tick-timer (run-at-time 2 2 #'drgnx-hub--tick))
  (setq drgnx-hub--started (format-time-string "%FT%T%z")
        drgnx-hub--server
        (make-network-process :name "drgnx-hub" :family 'local :server t :service socket :noquery t
                              :coding 'utf-8-unix
                              :filter (lambda (conn chunk)
                                        (drgnx-hub--lines conn chunk (lambda (j) (drgnx-hub--serve-request conn j))
                                                          (lambda (line) (drgnx-hub--malformed conn line)) drgnx-hub--max-line)))))

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
  (when (timerp drgnx-hub--exit-timer) (cancel-timer drgnx-hub--exit-timer))
  (setq drgnx-hub--exit-timer nil)
  (when (timerp drgnx-hub--tick-timer) (cancel-timer drgnx-hub--tick-timer))
  (setq drgnx-hub--tick-timer nil)
  (clrhash drgnx-hub--told)
  (clrhash drgnx-hub--sent)
  (drgnx-gateway-stop)
  (clrhash drgnx-gateway--registrations))

(defun drgnx-hub-main ()
  "The hub process's entry point (batch): serve until `shutdown' or SIGTERM.  Exit 3 when a hub already serves, 1
when it cannot start for any other reason."
  (condition-case err
      (drgnx-hub-serve (drgnx-hub-socket))
    (error (let ((already (string-prefix-p "a hub already serves" (error-message-string err))))
             (message "drgnx hub: %s" (if already "a hub already serves" (error-message-string err)))
             (kill-emacs (if already 3 1)))))
  (add-hook 'kill-emacs-hook #'drgnx-hub-stop)
  (message "drgnx hub: serving on %s, gateway on 127.0.0.1:%d" (drgnx-hub-socket) (drgnx-gateway-port))
  ;; a test's hub (DRGNX_HUB_PARENT_PID: its test Emacs) ends with it, never outliving the test's dir
  (let ((parent (string-to-number (or (getenv "DRGNX_HUB_PARENT_PID") "0"))))
    (while t
      (accept-process-output nil 1)
      (dotimes (_ 2) (read-event nil nil 0.002))     ; queued events would hold back process sentinels
      (when (and (> parent 0) (not (drgnx-hub--alive-p parent)))
        (message "drgnx hub: its parent (pid %d) is gone" parent)
        (kill-emacs 0)))))

;;;; The client side

(defun drgnx-hub--connect-socket (filter)
  (make-network-process :name "drgnx-hub-client" :family 'local :service (drgnx-hub-socket) :noquery t
                        :coding 'utf-8-unix :filter filter))

(defun drgnx-hub--client-filter (conn chunk)
  (drgnx-hub--lines conn chunk
                    (lambda (json)
                      (when-let* ((cb (gethash (plist-get json :id) drgnx-hub--pending)))
                        (remhash (plist-get json :id) drgnx-hub--pending)
                        (funcall cb (plist-get json :result) (plist-get (plist-get json :error) :message))))))

(defun drgnx-hub-call (method params callback)
  "Ask the hub METHOD with PARAMS (a plist); CALLBACK gets (RESULT ERROR-MESSAGE).  Signals when no hub serves."
  (unless (process-live-p drgnx-hub--client)
    (setq drgnx-hub--client (drgnx-hub--connect-socket #'drgnx-hub--client-filter)))
  (let ((id (cl-incf drgnx-hub--next-id)))
    (puthash id callback drgnx-hub--pending)
    (drgnx-hub--send drgnx-hub--client (list :id id :method method :params (or params (make-hash-table))))
    id))

(defun drgnx-hub-call-sync (method params &optional timeout)
  "METHOD's result from the hub, waiting up to TIMEOUT (5) s — for commands and the CLI only.  Signals the hub's
error, or when it does not answer."
  (let ((done nil) result error)
    (drgnx-hub-call method params (lambda (r e) (setq done t result r error e)))
    (let ((deadline (+ (float-time) (or timeout 5))))
      (while (and (not done) (< (float-time) deadline)) (accept-process-output nil 0.02)))
    (cond ((not done) (error "The drgnx hub did not answer %s" method))
          (error (error "drgnx hub: %s" error))
          (t result))))

(defun drgnx-hub-disconnect ()
  (dolist (c (list drgnx-hub--client drgnx-hub--events drgnx-hub--subscribing)) (when (process-live-p c) (delete-process c)))
  (setq drgnx-hub--client nil drgnx-hub--events nil drgnx-hub--subscribing nil)
  (clrhash drgnx-hub--pending))

(defun drgnx-hub-running-p ()
  "Does a hub serve this data dir?"
  (drgnx-hub--ping-socket (drgnx-hub-socket)))

(defun drgnx-hub--held-keys ()
  "The provider keys this Emacs already holds, asking no one: a provider's environment variable, else a key loaded
this session (`drgnx-ai--keys': from a command the user ran).  (:PROVIDER KEY…)."
  (cl-loop for (id . p) in (drgnx-ai-providers)
           for env = (plist-get p :key-env)
           for key = (and env (let ((v (getenv env))) (if (and v (not (string-empty-p v))) v (gethash id drgnx-ai--keys))))
           when key append (list (intern (concat ":" (symbol-name id))) key)))

(defun drgnx-hub--send-keys ()
  "Hand the hub the keys this Emacs holds (`drgnx-hub--held-keys'), over the socket: never in an environment, an
argument or a file.  The hub keeps them in memory only, so they go again on each start and each (re)connect."
  (when-let* ((keys (drgnx-hub--held-keys)))
    (drgnx-hub-call "gateway/keys" (list :keys keys) #'ignore)))

(defun drgnx-hub-ensure ()
  "Make sure the hub runs, starting it as a durable job if not (waits up to 5 s: commands and the CLI only), and
hand it the keys this Emacs holds.  t, or an error saying why not."
  (prog1 (drgnx-hub--ensure-running) (drgnx-hub--send-keys)))

(defun drgnx-hub--ensure-running ()
  (or (drgnx-hub-running-p)
      (and (getenv "DRGNX_NO_HUB_START")
           (error "No drgnx hub runs, and starting one is off here (DRGNX_NO_HUB_START)"))
      (let ((env (delq nil (mapcar (lambda (n) (let ((v (getenv n))) (and v (not (string-empty-p v)) (concat n "=" v))))
                                   drgnx-hub--env-names)))
            ;; nor through inheritance (a launcher without systemd passes this Emacs's environment on): keys unset
            (process-environment (append (delq nil (mapcar (lambda (p) (plist-get (cdr p) :key-env)) (drgnx-ai-providers)))
                                         process-environment)))
        ;; SIGPIPE ignored (the editing Emacs does not): an agent that hangs up must never end the hub
        (drgnx-jobs-start "drgnx-hub" (list "sh" "-c" "trap '' PIPE; exec \"$0\" \"$@\""
                                            (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                            "--eval" "(setq load-prefer-newer t)" "-L" (expand-file-name "core" drgnx-dir) "-l" "drgnx-hub" "-f" "drgnx-hub-main")
                          :cwd (expand-file-name "~") :env env)
        (let ((deadline (+ (float-time) 5)))
          (while (and (not (drgnx-hub-running-p)) (< (float-time) deadline)) (sleep-for 0.1)))
        (or (drgnx-hub-running-p) (error "The drgnx hub did not start (see `drgnx hub status' and its job log)")))))

(defun drgnx-hub-connect ()
  "Subscribe to the hub's events (`drgnx-hub-event-functions') and hand it the keys this Emacs holds
\(`drgnx-hub--send-keys').  Asynchronous; safe to call again, also before the hub has answered (one subscription)."
  (unless (or (process-live-p drgnx-hub--events) (process-live-p drgnx-hub--subscribing))
    (let ((c (drgnx-hub--connect-socket
              (lambda (conn chunk)
                (drgnx-hub--lines conn chunk
                                  (lambda (json)
                                    (cond ((plist-get json :event)
                                           (run-hook-with-args 'drgnx-hub-event-functions (plist-get json :event) (plist-get json :data)))
                                          ((plist-get json :id)
                                           (setq drgnx-hub--events conn)
                                           (when (eq drgnx-hub--subscribing conn) (setq drgnx-hub--subscribing nil))))))))))
      (setq drgnx-hub--subscribing c)
      ;; the hub went away (shutdown, a crash, a restart): whoever mirrors it is told
      (set-process-sentinel c (lambda (p _e)
                                (unless (process-live-p p)
                                  (when (eq drgnx-hub--events p) (setq drgnx-hub--events nil))
                                  (when (eq drgnx-hub--subscribing p) (setq drgnx-hub--subscribing nil))
                                  (run-hooks 'drgnx-hub-disconnect-functions))))
      (drgnx-hub--send c (list :id 0 :method "subscribe" :params (make-hash-table)))
      ;; a hub keeps keys in memory only: one that restarted has none, so each new subscription gives them again
      (with-demoted-errors "drgnx hub: keys not handed over: %S" (drgnx-hub--send-keys)))))

;;;; CLI

(defun drgnx-hub-cli ()
  "`drgnx hub start|stop|status [--json]'."
  (let* ((args (prog1 (cdr (member "--" command-line-args-left)) (setq command-line-args-left nil)))
         (json (member "--json" args)))
    (kill-emacs
     (condition-case err
         (pcase (car args)
           ("start" (drgnx-hub-ensure) (princ (format "drgnx hub: running (%s)\n" (drgnx-hub-socket))) 0)
           ("stop" (when (drgnx-hub-running-p) (drgnx-hub-call-sync "shutdown" nil)) 0)
           ("status"
            (if (not (drgnx-hub-running-p))
                (progn (princ (if json "{\"running\":false}\n" "drgnx hub: not running\n")) 1)
              (let ((s (drgnx-hub-call-sync "status" nil)))
                (princ (if json (concat (json-serialize (drgnx-hub--jsonable (append (list :running t) s))) "\n")
                         (format "drgnx hub: running, pid %s, gateway 127.0.0.1:%s, %s registrations, since %s\n"
                                 (plist-get s :pid) (plist-get s :gateway_port) (plist-get s :registrations) (plist-get s :started))))
                0)))
           (_ (princ "usage: drgnx hub start|stop|status [--json]\n" #'external-debugging-output) 2))
       (error (princ (format "drgnx hub: %s\n" (error-message-string err)) #'external-debugging-output) 1)))))

(provide 'drgnx-hub)
;;; drgnx-hub.el ends here
