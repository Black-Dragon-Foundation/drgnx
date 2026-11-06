;;; drgnx-agents-mirror.el --- The editing Emacs's mirrors of the hub's agent sessions -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Agent sessions held by the hub (Ratatoskr) keep working when this Emacs closes; here they are mirrors: the
;; same `drgnx-agent-session' struct, its `remote' slot the hub's id, filled from the hub's `agent' and
;; `agent-entries' events, so the Agents tab shows and drives them like local ones (actions on a mirror go to the
;; hub: `drgnx-agents--remote').  A new Emacs reattaches with `drgnx-agents-mirror-sync': the transcript is
;; fetched once, and events numbered after it are applied on top (events that arrive while it is fetched wait).
;; Never blocks: every call to the hub here is asynchronous.  See docs/develop/hub.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-agents)
(require 'drgnx-records)
(require 'drgnx-hub-client)

(declare-function drgnx-shell-env-refused-p "drgnx-shell-env" (name))

(defvar drgnx-agents-mirror--fetching (make-hash-table :test #'equal)
  "Hub id → events that came while its transcript was being fetched (newest first).")
(defvar drgnx-agents-mirror--seq (make-hash-table :test #'equal) "Hub id → the last change number applied.")

(defvar drgnx-agents-mirror--lock (make-hash-table :test #'equal)
  "Hub id → why the hub could not hold the provider to its lock (its snapshot's `enforced_why'), or nil.")

(defun drgnx-agents-mirror--find (id) (seq-find (lambda (s) (equal (drgnx-agent-session-remote s) id)) drgnx-agents--sessions))

(defconst drgnx-agents-mirror--slots
  '(name profile cwd task job status via mode queue paused permissions reviews usage commands capabilities exit stderr
         hooked panel)
  "The session slots a hub snapshot fills (its keys are the slot names).  `plugins-changed' is filled by hand (the key
is `plugins_changed').")

(defun drgnx-agents-mirror--fetching-p (id) (not (eq (gethash id drgnx-agents-mirror--fetching :none) :none)))

(defvar drgnx-agents-mirror--paused nil
  "Non-nil while the hub sends its sessions in another record layout (`drgnx-hub-records'): nothing is mirrored then,
so a mirror never reads a record it would misread.  A hub of this drgnx's layout (after a restart) is mirrored again.")

(defun drgnx-agents-mirror--skew (_skew reply)
  "The hub said hello with REPLY (`drgnx-hub-skew-functions'): mirroring pauses while its `records' differ."
  (let ((paused (and (consp reply) (not (eql (plist-get reply :records) drgnx-hub-records)))))
    (cond ((and paused (not drgnx-agents-mirror--paused))
           (drgnx-notify 'hub 'warn
                         (format "the agent hub is another drgnx (records %s, not %d): its sessions are not mirrored until it restarts"
                                 (plist-get reply :records) drgnx-hub-records)
                         :id 'records-skew :life 'condition))
          ((and drgnx-agents-mirror--paused (not paused)) (drgnx-notice-clear 'hub 'records-skew)))
    (setq drgnx-agents-mirror--paused paused)))

(defun drgnx-agents-mirror--decode (schema json)
  "The record SCHEMA describes, from JSON the hub sent (parsed), as a one-element list; nil if it does not decode.
One damaged record from the hub is skipped (and said so), never allowed to stop the records after it."
  (condition-case err
      (list (drgnx-records-from-json schema json))
    (error (drgnx-notify 'hub 'warn (format "skipped a record from the hub that does not decode (%s)"
                                            (error-message-string err)))
           nil)))

(defvar drgnx-agents-mirror--starting nil
  "The session `drgnx-agents-mirror-start' gave to `drgnx-agents-env-functions', until the hub's snapshot of the session
it started arrives (the hub's event comes before its reply): that snapshot's mirror is this very object, so what a
hook function kept of it (the Live browser's list of agents it gave its endpoint) stays the mirror.")

(defun drgnx-agents-mirror--adopt (snap)
  "The session `drgnx-agents-mirror--starting' when SNAP (a hub snapshot) is the session it started, else nil."
  (when-let* ((s drgnx-agents-mirror--starting)
              ((null (drgnx-agent-session-remote s)))
              ((equal (plist-get snap :profile) (drgnx-agent-session-profile s)))
              ((equal (plist-get snap :task) (drgnx-agent-session-task s)))
              ((equal (plist-get snap :job) (drgnx-agent-session-job s)))
              ((or (null (plist-get snap :cwd))
                   (equal (directory-file-name (plist-get snap :cwd))
                          (directory-file-name (drgnx-agent-session-cwd s))))))
    (setq drgnx-agents-mirror--starting nil)
    s))

(defun drgnx-agents-mirror--task-hook (m event)
  "Run `drgnx-agents-task-functions' for mirror M and EVENT (`start', `turn-start', `turn-end'); a failing function is
reported and skipped.  Never waits: the functions defer their own work to timers."
  (with-demoted-errors "drgnx work: %S" (run-hook-with-args 'drgnx-agents-task-functions m event)))

(defvar drgnx-agents-mirror--turns (make-hash-table :test #'equal)
  "Hub id → [STARTED ENDED STOPS]: how many turns the task hooks have seen start and end, and how many `stop' entries
the transcript has.  A turn runs its hooks once, whichever of the status change and the `stop' entry tells of it first.")

(defun drgnx-agents-mirror--counts (id) (or (gethash id drgnx-agents-mirror--turns) (puthash id (vector 0 0 0) drgnx-agents-mirror--turns)))

(defun drgnx-agents-mirror--turn-begin (m)
  "A turn of mirror M begins, unless one is open: `turn-start' for a session with a task."
  (let ((c (drgnx-agents-mirror--counts (drgnx-agent-session-remote m))))
    (when (= (aref c 0) (aref c 1))
      (cl-incf (aref c 0))
      (when (drgnx-agent-session-task m) (drgnx-agents-mirror--task-hook m 'turn-start)))))

(defun drgnx-agents-mirror--turn-end (m)
  "The open turn of mirror M ends: `turn-end' for a session with a task.  Nothing when no turn is open."
  (let ((c (drgnx-agents-mirror--counts (drgnx-agent-session-remote m))))
    (when (> (aref c 0) (aref c 1))
      (cl-incf (aref c 1))
      (when (drgnx-agent-session-task m) (drgnx-agents-mirror--task-hook m 'turn-end)))))

(defun drgnx-agents-mirror--stops (m n)
  "N new turn-ending entries (`stop', or the `error' of a failed turn) came into mirror M's transcript: each ends a turn
that the status did not already end.  The hub sends a session's state at most every 50 ms, so a short turn can go by
with no busy status in between."
  (let ((c (drgnx-agents-mirror--counts (drgnx-agent-session-remote m))))
    (dotimes (_ n)
      (cl-incf (aref c 2))
      (when (> (aref c 2) (aref c 1))
        (drgnx-agents-mirror--turn-begin m)
        (drgnx-agents-mirror--turn-end m)))))

(defvar drgnx-agents-mirror--shown)
(defvar drgnx-agents-mirror--hub-turns (make-hash-table :test #'equal)
  "Hub id → the turn count (the snapshot's `turns') of the last snapshot applied.")
(defvar drgnx-agents-mirror--hub-entries (make-hash-table :test #'equal)
  "Hub id → how many entries the transcript had at the last snapshot applied (its `entries_count'): where a fetched
transcript's new turns begin.")

(defun drgnx-agents-mirror--transitions (m new prev &optional turned)
  "Run the task hooks for what a snapshot changed in mirror M, which was in status PREV before it (M was just made,
NEW).  A session with a task runs `start' when first seen, `turn-start' when it becomes busy and `turn-end' when it
stops being busy: each once per turn (`drgnx-agents-mirror--turns'), so a snapshot sent again runs nothing.
TURNED, the number of turns the hub started since the last snapshot (when positive), tells of turns that were over
between two snapshots (shorter than the hub's update throttle, so no `busy' was seen): the open turn ends, each whole
turn begins and ends, and the one open now begins."
  (when (and new (drgnx-agent-session-task m)) (drgnx-agents-mirror--task-hook m 'start))
  (let ((was (eq prev 'busy)) (is (eq (drgnx-agent-session-status m) 'busy)))
    (cond ((and turned (> turned 0))
           (when was (drgnx-agents-mirror--turn-end m))
           (dotimes (_ (- turned (if is 1 0)))
             (drgnx-agents-mirror--turn-begin m)
             (drgnx-agents-mirror--turn-end m))
           (when is (drgnx-agents-mirror--turn-begin m)))
          ((and is (not was)) (drgnx-agents-mirror--turn-begin m))
          ((and was (not is)) (drgnx-agents-mirror--turn-end m)))))

(defun drgnx-agents-mirror--apply-snapshot (snap)
  "Make (or update) the mirror of SNAP (a hub snapshot); returns (MIRROR . NEW-P)."
  (let* ((id (plist-get snap :id)) (m (drgnx-agents-mirror--find id)) (new (not m))
         (prev (and m (drgnx-agent-session-status m))))
    (unless m
      (setq m (or (drgnx-agents-mirror--adopt snap) (drgnx-agents--make)))
      (setf (drgnx-agent-session-remote m) id (drgnx-agent-session-id m) id)
      (push m drgnx-agents--sessions))
    (dolist (slot drgnx-agents-mirror--slots)
      (setf (cl-struct-slot-value 'drgnx-agent-session slot m) (plist-get snap (intern (concat ":" (symbol-name slot))))))
    (setf (drgnx-agent-session-plugins-changed m) (and (plist-get snap :plugins_changed) t))
    ;; a false flag is not in a decoded record (nil-valued keys are left out): the hub's reason says the lock is not held
    (progn
      (puthash id (plist-get snap :enforced_why) drgnx-agents-mirror--lock)
      (when (and new (plist-get snap :enforced_why))
        (drgnx-notify 'agents 'warn (format "%s: %s" (plist-get snap :name) (format "not enforced: %s" (plist-get snap :enforced_why)))
                      :id (intern (concat "lock-" id)) :life 'event)))
    ;; a session whose transcript is shown has its turns told by its entries too; one nobody shows, by the count alone
    (when-let* ((count (plist-get snap :entries_count))) (puthash id count drgnx-agents-mirror--hub-entries))
    (let* ((turns (plist-get snap :turns)) (last (gethash id drgnx-agents-mirror--hub-turns)))
      (when turns (puthash id turns drgnx-agents-mirror--hub-turns))
      (drgnx-agents-mirror--transitions
       m new prev (and turns last (> turns last) (not (gethash id drgnx-agents-mirror--shown)) (- turns last))))
    (cons m new)))

(defun drgnx-agents-mirror-lock-label (m)
  "\"not enforced\" (with the hub's reason) when the hub could not hold mirror M's provider to its lock, else nil."
  (when-let* ((why (gethash (drgnx-agent-session-remote m) drgnx-agents-mirror--lock)))
    (format "not enforced: %s" why)))

(defun drgnx-agents-mirror--module-env (s)
  "What the functions on `drgnx-agents-env-functions' add to the environment of the agent of session S, as the hub's
`agents/start' takes it: a vector of (:name NAME :value VALUE), or nil.  Only the names on
`drgnx-agents-start-env-names' go, and never one that looks like a credential: the others are dropped with one notice
naming them.  A function that fails, or returns what is not a list of \"NAME=value\" strings, is reported and skipped."
  (require 'drgnx-shell-env)
  (let (vars dropped)
    (run-hook-wrapped
     'drgnx-agents-env-functions
     (lambda (f)
       (let ((r (with-demoted-errors "drgnx agents: %S" (funcall f s))))
         (if (not (proper-list-p r))
             (drgnx-notify 'agents 'warn
                           (format "an environment function returned %S, not a list of NAME=value strings; ignored" r))
           (dolist (e r)
             (if (not (and (stringp e) (string-match "\\`\\([A-Za-z_][A-Za-z0-9_]*\\)=\\(.*\\)\\'" e)))
                 (drgnx-notify 'agents 'warn (format "an environment function returned %S, not a NAME=value string; ignored" e))
               (let ((name (match-string 1 e)) (value (match-string 2 e)))
                 (if (or (not (member name (default-value 'drgnx-agents-start-env-names)))
                         (drgnx-shell-env-refused-p name))
                     (cl-pushnew name dropped :test #'equal)
                   (setq vars (cons (list :name name :value value) (seq-remove (lambda (v) (equal (plist-get v :name) name)) vars)))))))))
       nil))
    (when dropped
      (drgnx-notify 'agents 'warn
                    (format "not passed on to the agent: %s (only names on drgnx-agents-start-env-names, and none that look like a credential)"
                            (mapconcat #'identity (nreverse dropped) ", "))))
    (and vars (vconcat (seq-take (nreverse vars) 8)))))

(defun drgnx-agents-mirror-start (profile cwd &optional task job)
  "Start a session of PROFILE in CWD in the hub and return its mirror here (for a command the user ran: it waits for
the hub).  The agent runs in the hub, so it keeps working when this Emacs closes.  The functions on
`drgnx-agents-env-functions' add to its environment (`drgnx-agents-mirror--module-env')."
  (unless (memq #'drgnx-agents-mirror--event drgnx-hub-event-functions) (drgnx-hub-ensure) (drgnx-agents-mirror-sync))
  (let* ((s (drgnx-agents--make :profile profile :cwd (expand-file-name cwd) :task task :job job))
         (env (drgnx-agents-mirror--module-env s))
         (drgnx-agents-mirror--starting s))
    (unwind-protect
        (let* ((r (drgnx-hub-call-sync "agents/start" (append (list :profile profile :cwd (expand-file-name cwd))
                                                              (and task (list :task task)) (and job (list :job job))
                                                              (and env (list :env env)))
                                       30))
               (id (plist-get r :id)))
          (or (drgnx-agents-mirror--find id)
              (when-let* ((snap (drgnx-agents-mirror--decode 'drgnx-records-session
                                                             (plist-get (drgnx-hub-call-sync "agents/get" (list :id id) 10) :session))))
                (let ((m (car (drgnx-agents-mirror--apply-snapshot (car snap)))))
                  (drgnx-agents-mirror--fetch m)
                  m))))
      ;; a start that failed leaves nothing for a hook function's list to hold on to
      (unless (drgnx-agent-session-remote s) (setf (drgnx-agent-session-status s) 'exited)))))

(defun drgnx-agents-mirror--ends-turn-p (entry)
  "Does transcript ENTRY end a turn: a `stop' entry, or the `error' entry of a turn that failed (the hub marks it with
`stop'; an error in the middle of a turn, a refused wait, is not marked)?"
  (let ((type (plist-get entry :type)))
    (or (eq type 'stop) (and (eq type 'error) (plist-get entry :stop) t))))

(defun drgnx-agents-mirror--apply-entries (m entries)
  "Put ENTRIES ((INDEX ENTRY)…, as the hub's JSON arrays arrive) into mirror M's transcript.  The number of entries
that end a turn (`drgnx-agents-mirror--ends-turn-p': `stop', or a failed turn's `error') that were not in the
transcript before."
  (let ((v (vconcat (drgnx-agent-session-entries m))) (stops 0))
    (mapc (lambda (pair)
            (when-let* ((read (drgnx-agents-mirror--decode 'drgnx-records-entry (elt pair 1))) (i (elt pair 0)))
              (when (>= i (length v)) (setq v (vconcat v (make-vector (- (1+ i) (length v)) nil))))
              (when (and (drgnx-agents-mirror--ends-turn-p (car read)) (not (drgnx-agents-mirror--ends-turn-p (aref v i))))
                (cl-incf stops))
              (aset v i (car read))))
          entries)
    (setf (drgnx-agent-session-entries m) (append v nil))
    stops))

(defun drgnx-agents-mirror--fetch (m)
  "Fetch mirror M's whole transcript; then apply the events that came meanwhile and are newer.
The turns that had ended when this editor last heard of the session (the entries the last snapshot applied counted)
ran their hooks, or belong to the past: none runs again.  A turn that ended after that, even before the fetch's
answer, runs its hooks once."
  (let ((id (drgnx-agent-session-remote m)))
    (puthash id nil drgnx-agents-mirror--fetching)
    (drgnx-hub-call "agents/get" (list :id id)
                    (lambda (r _err)
                      (let ((waiting (gethash id drgnx-agents-mirror--fetching)) (seq (or (plist-get r :seq) 0)))
                        (remhash id drgnx-agents-mirror--fetching)
                        (when r
                          (let* ((known (gethash id drgnx-agents-mirror--hub-entries))   ; before the answer's snapshot
                                 (c (drgnx-agents-mirror--counts id))
                                 (open (> (aref c 0) (aref c 1)))
                                 (stops (progn (setf (drgnx-agent-session-entries m) nil)
                                               (drgnx-agents-mirror--apply-entries
                                                m (let ((i -1)) (mapcar (lambda (e) (list (cl-incf i) e)) (plist-get r :entries))))))
                                 (old (if known
                                          (cl-count-if #'drgnx-agents-mirror--ends-turn-p
                                                       (seq-take (drgnx-agent-session-entries m) known))
                                        stops)))
                            (aset c 2 old)
                            (aset c 1 old)
                            (aset c 0 (if open (1+ old) old))
                            (when-let* ((snap (drgnx-agents-mirror--decode 'drgnx-records-session (plist-get r :session))))
                              (drgnx-agents-mirror--apply-snapshot (car snap)))
                            ;; the turns that ended since: once each (the answer's status may have ended one already)
                            (drgnx-agents-mirror--stops m (- stops old)))
                          (puthash id seq drgnx-agents-mirror--seq))
                        (dolist (ev (reverse waiting)) (drgnx-agents-mirror--event (car ev) (cdr ev)))
                        (drgnx-agents--changed m))))))

(defvar drgnx-agents-mirror--shown (make-hash-table :test #'equal)
  "Hub id → t while a transcript of the session is shown: the ids whose entries the hub sends this editor.")

(defvar drgnx-hub--events)
(declare-function drgnx-hub--call-on "drgnx-hub-client")

(defun drgnx-agents-mirror--entries-call (method id &optional callback)
  "Ask the hub METHOD (`agents/entries/subscribe' or `…/unsubscribe') for session ID on this Emacs's subscribed
connection: the entries are sent to that connection, which is where events arrive.  Nothing while it is down: the
subscriptions are made again when it is up (`drgnx-agents-mirror--resubscribe')."
  (when (process-live-p drgnx-hub--events)
    (drgnx-hub--call-on drgnx-hub--events method (list :session id) (or callback #'ignore))))

(defun drgnx-agents-mirror-show (id)
  "A transcript of hub session ID is shown: ask the hub for its entries, and fetch what the mirror missed.
The hub sends a session's entries only to the editors that asked, so a mirror nobody shows has its snapshots (status,
queue, permissions) and no transcript beyond the one fetched when it first appeared.  Asynchronous."
  (unless (or (gethash id drgnx-agents-mirror--shown) drgnx-agents-mirror--paused)
    (puthash id t drgnx-agents-mirror--shown)
    (drgnx-agents-mirror--subscribe id)))

(defun drgnx-agents-mirror--subscribe (id)
  "Subscribe to session ID's entries; once the hub took the subscription, fetch the transcript (the two travel on
different connections, so the fetch waits): the entries between the two wait (`--fetching') and are applied on top."
  (drgnx-agents-mirror--entries-call
   "agents/entries/subscribe" id
   (lambda (_result err)
     (when-let* (((not err)) ((gethash id drgnx-agents-mirror--shown)) (m (drgnx-agents-mirror--find id)))
       (drgnx-agents-mirror--fetch m)))))

(defun drgnx-agents-mirror-hide (id)
  "No transcript of hub session ID is shown now: the hub stops sending its entries."
  (when (gethash id drgnx-agents-mirror--shown)
    (remhash id drgnx-agents-mirror--shown)
    (drgnx-agents-mirror--entries-call "agents/entries/unsubscribe" id)))

(defun drgnx-agents-mirror--shown-ids ()
  "The hub ids of the sessions whose transcripts a window shows now."
  (let (ids)
    (walk-windows
     (lambda (w)
       (let ((s (and (boundp 'drgnx-agents-ui--session) (buffer-local-value 'drgnx-agents-ui--session (window-buffer w)))))
         (when (and (drgnx-agent-session-p s) (drgnx-agent-session-remote s))
           (cl-pushnew (drgnx-agent-session-remote s) ids :test #'equal))))
     'never t)
    ids))

(defun drgnx-agents-mirror--windows-changed (&optional _frame)
  "`window-buffer-change-functions': show the sessions whose transcripts a window now shows, hide those none does."
  (let ((now (drgnx-agents-mirror--shown-ids)) gone)
    (maphash (lambda (id _) (unless (member id now) (push id gone))) drgnx-agents-mirror--shown)
    (mapc #'drgnx-agents-mirror-hide gone)
    (mapc #'drgnx-agents-mirror-show now)))

(defun drgnx-agents-mirror--resubscribe ()
  "A new connection to the hub (after a restart): ask again for the entries of the sessions shown."
  (maphash (lambda (id _) (drgnx-agents-mirror--subscribe id)) drgnx-agents-mirror--shown))

(defconst drgnx-agents-mirror--hook-steps-max 100 "How many steps' hook rows a mirror keeps (the newest).")

(defun drgnx-agents-mirror--last-tool-id (m)
  "The `:id' of the newest top-level tool entry of mirror M's transcript, or nil."
  (let (id)
    (dolist (e (drgnx-agent-session-entries m))
      (when (eq (plist-get e :type) 'tool) (setq id (plist-get e :id))))
    id))

(defun drgnx-agents-mirror--step (data)
  "An `agent-step' event (DATA `{session, step}') whose step carries hook rows (`hooks': each hook point run on it):
mirror M of that session keeps them as (STEP TOOL-ID ROWS), TOOL-ID being the tool entry that was the newest when the
rows first arrived (the hook ran on that step's call; a step has no id in the transcript).  A step seen again
replaces its rows and keeps its tool entry.  Only the newest `drgnx-agents-mirror--hook-steps-max' steps are kept."
  (let* ((step (plist-get data :step)) (rows (append (plist-get step :hooks) nil)))
    (when-let* ((rows rows) (seq (plist-get step :seq))
                (m (drgnx-agents-mirror--find (plist-get step :session))))
      (let* ((old (assq seq (drgnx-agent-session-hooks m)))
             (entry (list seq (if old (nth 1 old) (drgnx-agents-mirror--last-tool-id m)) rows)))
        (setf (drgnx-agent-session-hooks m)
              (seq-take (cons entry (seq-remove (lambda (e) (eql (car e) seq)) (drgnx-agent-session-hooks m)))
                        drgnx-agents-mirror--hook-steps-max))
        (drgnx-agents--changed m)))))

(defun drgnx-agents-mirror--event (event data)
  "An event from the hub (`drgnx-hub-event-functions')."
  (when (and (equal event "agent-step") (not drgnx-agents-mirror--paused))
    (drgnx-agents-mirror--step data))
  (when (and (member event '("agent" "agent-entries")) (not drgnx-agents-mirror--paused))
    (let ((id (plist-get data :id)) (seq (or (plist-get data :seq) 0)))
      (cond
       ;; a transcript on its way: the event waits for it
       ((drgnx-agents-mirror--fetching-p id)
        (puthash id (cons (cons event data) (gethash id drgnx-agents-mirror--fetching)) drgnx-agents-mirror--fetching))
       ;; older than what the mirror has (a snapshot or entries that waited for the transcript, numbered before it)
       ((and (gethash id drgnx-agents-mirror--seq) (<= seq (gethash id drgnx-agents-mirror--seq))))
       ((equal event "agent")
        (when-let* ((snap (drgnx-agents-mirror--decode 'drgnx-records-session (plist-get data :session))))
          (pcase-let ((`(,m . ,new) (drgnx-agents-mirror--apply-snapshot (car snap))))
            (if new (drgnx-agents-mirror--fetch m)
              (drgnx-agents--changed m)))))
       ((equal event "agent-entries")
        (when-let* ((m (drgnx-agents-mirror--find id)))
          (let ((stops (drgnx-agents-mirror--apply-entries m (plist-get data :entries))))
            (puthash id seq drgnx-agents-mirror--seq)
            (drgnx-agents-mirror--stops m stops))
          (drgnx-agents--changed m)))))))

(defun drgnx-agents-mirror--hub-gone ()
  "The hub's connection closed: its sessions ended with it (they are its children), so the mirrors say so."
  (dolist (m drgnx-agents--sessions)
    (when (and (drgnx-agent-session-remote m) (not (eq (drgnx-agent-session-status m) 'exited)))
      (setf (drgnx-agent-session-status m) 'exited (drgnx-agent-session-permissions m) nil (drgnx-agent-session-reviews m) nil
            (drgnx-agent-session-stderr m) "the agent hub ended; its sessions end with it")
      (drgnx-agents--changed m))))

(defun drgnx-agents-mirror-sync ()
  "Mirror the hub's agent sessions here, and keep them current.  Asynchronous; never starts a hub."
  (add-hook 'drgnx-hub-event-functions #'drgnx-agents-mirror--event)
  (add-hook 'drgnx-hub-disconnect-functions #'drgnx-agents-mirror--hub-gone)
  (add-hook 'drgnx-hub-skew-functions #'drgnx-agents-mirror--skew)
  (add-hook 'drgnx-hub-connected-functions #'drgnx-agents-mirror--resubscribe)
  (add-hook 'window-buffer-change-functions #'drgnx-agents-mirror--windows-changed)
  (drgnx-hub-connect)
  (drgnx-hub-call "agents/list" nil
                  (lambda (r _err)
                    (mapc (lambda (json)
                            (when-let* ((snap (drgnx-agents-mirror--decode 'drgnx-records-session json)))
                              (pcase-let ((`(,m . ,_) (drgnx-agents-mirror--apply-snapshot (car snap))))
                                (drgnx-agents-mirror--fetch m))))
                          (and (not drgnx-agents-mirror--paused) (consp r) (plist-get r :sessions))))))

(defun drgnx-agents-mirror-stop ()
  "Stop mirroring (the mirrors stay as they are)."
  (remove-hook 'drgnx-hub-event-functions #'drgnx-agents-mirror--event)
  (remove-hook 'drgnx-hub-disconnect-functions #'drgnx-agents-mirror--hub-gone)
  (remove-hook 'drgnx-hub-skew-functions #'drgnx-agents-mirror--skew)
  (remove-hook 'drgnx-hub-connected-functions #'drgnx-agents-mirror--resubscribe)
  (remove-hook 'window-buffer-change-functions #'drgnx-agents-mirror--windows-changed)
  (setq drgnx-agents-mirror--paused nil)
  (clrhash drgnx-agents-mirror--shown)
  (clrhash drgnx-agents-mirror--hub-turns)
  (clrhash drgnx-agents-mirror--hub-entries)
  (clrhash drgnx-agents-mirror--fetching)
  (clrhash drgnx-agents-mirror--lock)
  (clrhash drgnx-agents-mirror--turns)
  (clrhash drgnx-agents-mirror--seq))

(provide 'drgnx-agents-mirror)
;;; drgnx-agents-mirror.el ends here
