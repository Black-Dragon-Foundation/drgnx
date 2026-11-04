;;; drgnx-hub-core.el --- The hub client's connection and subscription lifecycle, as a pure core -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Every ordering decision of the hub client (core/drgnx-hub-client.el) is made here: which connection a call waits
;; on and when it goes, the challenge, the hello and its proof, the probe that finds a legacy hub, deadlines, the one
;; subscription, its end and its redial, and which answers still count.  `drgnx-hub-core-step' takes a state and one
;; event and returns the next state and the effects to run.  It calls no process, timer, file or hook: the shell
;; (drgnx-hub-client.el) snapshots its globals into a state, calls this, writes the globals back and runs the effects,
;; and the tests (test/unit/hub-core-test.el) run it in every order with `drgnx-test-every-order'.
;; See docs/develop/hub.md, "The client's core".

;;; Code:
(require 'cl-lib)
(require 'subr-x)

(defconst drgnx-hub-proto 1 "The hub protocol this drgnx speaks: its `hello' says it.")
(defconst drgnx-hub-proto-min 1 "The oldest hub protocol this drgnx still speaks.")
(defconst drgnx-hub-records 2
  "The record layout this drgnx reads (records 2: JSON objects): the agents mirror pauses while a hub's differs.")
(defconst drgnx-hub-schema-readable-max 7
  "The newest work.db schema this editor reads (`drgnx-work-db-read': schema 7's compatibility views, `compat-read' 6):
a hub whose hello says a schema from `drgnx-work-db-schema-version' to this one is not skewed.")

(defconst drgnx-hub-core-event-kinds
  '(open connect call challenge answer event closed timer disconnect version-known)
  "The kinds of event `drgnx-hub-core-step' takes.  Each is a list headed by its kind:
- (open CONN EVENTS): the shell opened CONN; EVENTS non-nil for a subscription, else CONN is the call connection.
- (connect NOW): `drgnx-hub-connect' was called (NOW: `float-time'); (connect NOW :opened CONN): its dial opened
  CONN; (connect NOW :redial-failed t): a redial failed at once, or the shell asks for the next one (NOW:
  `drgnx-timer-now').
- (call CONN METHOD PARAMS CALLBACK &key DEADLINE FULL FIRST HELLO ROLE UNDER): a call on CONN (CALLBACK nil: the
  core's own, such as `subscribe').  HELLO: this Emacs's hello; ROLE `token' or `keys-held': the
  hand-over's questions, asked under the subscription UNDER.  HELLO is what `drgnx-hub-core--hello-answered'
  judges the answer by: (:problem :proves :expect :version :socket :cap-file), never the cap.
- (challenge CONN NONCE SOCKET): the hub's challenge line.
- (answer CONN ID RESULT ERROR): an answer line (CONN nil: settled by this side, `drgnx-hub--settle').
- (event CONN NAME DATA): an event line.
- (closed CONN NOW): CONN's sentinel ran (NOW: `drgnx-timer-now').
- (timer KEY &key READ SOCKET): the layer timer KEY fired: (hub-call . ID), (hub-challenge . CONN) (READ: its read
  of what had arrived is done) or `hub-resubscribe'.
- (disconnect): `drgnx-hub-disconnect'.
- (version-known CONN NONCE): the binary's version is read (or cannot be): CONN's hello may go.")

(defconst drgnx-hub-core-effect-kinds '(send delete timer-start timer-cancel callback hook notify)
  "The kinds of effect `drgnx-hub-core-step' returns, run by the shell in order:
- (send CONN MSG); (delete CONN) (its sentinel runs at once: a `closed' event);
- (timer-start KEY SECS); (timer-cancel KEY);
- (callback FN LABEL ARGS): FN applied to ARGS inside the guard;
- (hook NAME . ARGS): a shell action (`drgnx-hub--run-hook');
- (notify SEVERITY TEXT ID . PROPS), or (notify :clear ID): a notice of source `hub'.")

(cl-defstruct (drgnx-hub-core (:constructor drgnx-hub-core-make) (:copier drgnx-hub-core--copy))
  "The client's state.  CONNS: (CONN . PLIST) with :live :state :queue :proven :asked :events :since; PENDING:
\(ID . ENTRY), ENTRY (:cb :conn :full :method [:role :under :hello]); CONFIG: (:call-deadline :challenge-wait
:subscribe-deadline :give-up :schema :noninteractive)."
  client events subscribing pending (next-id 0) editor (keys-held :unknown) asked-disconnect resubscribe-since
  (resubscribe-delay 1) last-hello conns config)

;;;; Helpers: the state is copied once per step, and changed only through these

(defvar drgnx-hub-core--effects nil "The effects of the step running, newest first.")

(defun drgnx-hub-core--do (&rest effect)
  (push effect drgnx-hub-core--effects))

(defun drgnx-hub-core--conn (s conn prop)
  (plist-get (cdr (assq conn (drgnx-hub-core-conns s))) prop))

(defun drgnx-hub-core--conn-put (s conn prop value)
  (let ((cell (assq conn (drgnx-hub-core-conns s))))
    (if cell
        (setcdr cell (plist-put (copy-sequence (cdr cell)) prop value))
      (push (list conn prop value) (drgnx-hub-core-conns s)))))

(defun drgnx-hub-core--live-p (s conn)
  (and conn (drgnx-hub-core--conn s conn :live)))

(defun drgnx-hub-core--config (s key)
  (plist-get (drgnx-hub-core-config s) key))

(defun drgnx-hub-core--same-p (a b)
  "Whether the strings A and B are equal, compared as SHA-256 digests (the time taken never tells where they differ)."
  (and (stringp a) (stringp b) (string= (secure-hash 'sha256 a) (secure-hash 'sha256 b))))

;;;; Skew

(defun drgnx-hub-core-skew (reply version schema)
  "What to do about the hub that answered a hello with REPLY, VERSION the commit of the binary on disk (nil: not
known) and SCHEMA this editor's work.db schema: `incompatible', `restart-when-idle' or `ok' (`drgnx-hub-skew')."
  (cond ((eq reply :legacy) 'restart-when-idle)
        ((let ((proto (plist-get reply :proto)) (min (plist-get reply :proto_min)))
           (or (not (natnump proto)) (< proto drgnx-hub-proto-min) (and (natnump min) (< drgnx-hub-proto min))))
         'incompatible)
        ((or (not (eql (plist-get reply :records) drgnx-hub-records))
             (and version (not (equal (plist-get reply :drgnx_version) version)))
             (let ((s (plist-get reply :schema)))
               (and (natnump s) (/= s 0) (not (<= schema s drgnx-hub-schema-readable-max)))))
         'restart-when-idle)
        (t 'ok)))

(defun drgnx-hub-core--incompatible-text (reply)
  "What the user is told about an incompatible hub (REPLY its hello's answer)."
  (if (and (natnump (plist-get reply :proto_min)) (< drgnx-hub-proto (plist-get reply :proto_min)))
      (format "the hub is drgnx %s (protocol %s, at least %s); this drgnx speaks protocol %d — update drgnx"
              (plist-get reply :drgnx_version) (plist-get reply :proto) (plist-get reply :proto_min) drgnx-hub-proto)
    (format "the hub is drgnx %s (protocol %s); this drgnx needs protocol %d or later — drgnx hub stop, then try again"
            (plist-get reply :drgnx_version) (plist-get reply :proto) drgnx-hub-proto-min)))

;;;; Calls

(defun drgnx-hub-core--settle (s id result error)
  "Call ID is answered with RESULT and ERROR (the hub's error object, or this side's message) — once: it is forgotten
first and its deadline cancelled; then its role's step runs, and its callback."
  (when-let* ((entry (cdr (assq id (drgnx-hub-core-pending s)))))
    (setf (drgnx-hub-core-pending s) (assq-delete-all id (copy-sequence (drgnx-hub-core-pending s))))
    (drgnx-hub-core--do 'timer-cancel (cons 'hub-call id))
    (let* ((err (cond ((null error) nil) ((stringp error) (list :message error)) (t error)))
           (r (and (not err) result))
           (e (and err (if (plist-get entry :full) err (plist-get err :message))))
           (conn (plist-get entry :conn)))
      (pcase (plist-get entry :role)
        ('probe (unless err (drgnx-hub-core--legacy-now s conn)))
        ('hello (drgnx-hub-core--hello-answered s conn (plist-get entry :hello) r e))
        ('subscribe (drgnx-hub-core--subscribed s conn r))
        ('token (when (drgnx-hub-core--answered-under s (plist-get entry :under)) (drgnx-hub-core--editor-answered s r)))
        ('keys-held (when (drgnx-hub-core--answered-under s (plist-get entry :under))
                      (drgnx-hub-core--keys-held-answered s r))))
      (when (plist-get entry :cb)
        (drgnx-hub-core--do 'callback (plist-get entry :cb) (format "hub answer %s" (plist-get entry :method))
                            (list r e))))))

(defun drgnx-hub-core--answered-under (s sub)
  "Whether an answer to a question asked under the subscription SUB (nil: none) still counts: SUB has not ended.  The
hub ends its connections in any order, so the call connection's answers can come after the subscription's end, and
they would undo its forget."
  (or (null sub) (eq sub (drgnx-hub-core-events s))))

(defun drgnx-hub-core--fail-conn (s conn message)
  "Every call waiting on CONN gets MESSAGE as its error (once each), oldest first."
  (let ((ids (sort (cl-loop for (id . e) in (drgnx-hub-core-pending s) when (eq (plist-get e :conn) conn) collect id)
                   #'<)))
    (drgnx-hub-core--conn-put s conn :queue nil)
    (dolist (id ids) (drgnx-hub-core--settle s id nil message))))

(defun drgnx-hub-core--transmit (s conn msg)
  "Send the call MSG (:id :method :params) on CONN.  Keys go only to a hub that proved itself: on any other connection
`gateway/keys' fails at once and `gateway/register' goes without its `:keys'."
  (let ((proven (drgnx-hub-core--conn s conn :proven)) (method (plist-get msg :method)))
    (if (and (equal method "gateway/keys") (not proven))
        (drgnx-hub-core--settle s (plist-get msg :id) nil "keys go only to a hub that proved itself")
      (when (and (equal method "gateway/register") (not proven) (consp (plist-get msg :params)))
        (setq msg (list :id (plist-get msg :id) :method method
                        :params (cl-loop for (k v) on (plist-get msg :params) by #'cddr unless (eq k :keys) append (list k v)))))
      (drgnx-hub-core--do 'send conn msg))))

(defun drgnx-hub-core--send-queued (s conn)
  "Send the calls waiting in CONN's queue, in order — only those still waiting: one whose deadline passed was told it
failed, so it never goes."
  (let ((queue (drgnx-hub-core--conn s conn :queue)))
    (drgnx-hub-core--conn-put s conn :queue nil)
    (dolist (msg queue)
      (when (assq (plist-get msg :id) (drgnx-hub-core-pending s)) (drgnx-hub-core--transmit s conn msg)))))

(cl-defun drgnx-hub-core--call (s conn method params cb &key deadline full first hello role under)
  "Call METHOD with PARAMS on CONN: FIRST sends it now (the probe, the hello), else once CONN is proven or `legacy'."
  (let ((id (cl-incf (drgnx-hub-core-next-id s))))
    (when (equal method "shutdown")     ; the hub ends at this editor's request: the subscription is not redialled
      (setf (drgnx-hub-core-asked-disconnect s) t)
      (drgnx-hub-core--resubscribe-stop s))
    (when hello (drgnx-hub-core--conn-put s conn :state 'hello))
    (push (cons id (append (list :cb cb :conn conn :full full :method method)
                           (let ((role (or role (cond (hello 'hello) ((equal method "subscribe") 'subscribe)))))
                             (and role (list :role role)))
                           (and under (list :under under))
                           (and hello (list :hello hello))))
          (drgnx-hub-core-pending s))
    (drgnx-hub-core--do 'timer-start (cons 'hub-call id) (or deadline (drgnx-hub-core--config s :call-deadline)))
    (let ((msg (list :id id :method method :params (or params (make-hash-table)))))
      (cond (first (drgnx-hub-core--do 'send conn msg))
            ((memq (drgnx-hub-core--conn s conn :state) '(wait version hello))
             (drgnx-hub-core--conn-put s conn :queue (append (drgnx-hub-core--conn s conn :queue) (list msg))))
            (t (drgnx-hub-core--transmit s conn msg))))
    id))

;;;; A connection proves itself

(defun drgnx-hub-core--reject (s conn message &optional tell)
  "CONN's hub is not used: its calls fail with MESSAGE and it closes.  TELL, a notice id: the user is told too."
  (drgnx-hub-core--conn-put s conn :state 'rejected)
  (drgnx-hub-core--fail-conn s conn message)
  (when tell (drgnx-hub-core--do 'notify 'fail message tell))
  (when (drgnx-hub-core--live-p s conn)
    (drgnx-hub-core--conn-put s conn :live nil)
    (drgnx-hub-core--do 'delete conn)))

(defun drgnx-hub-core--legacy-now (s conn)
  "CONN's hub answered the probe before it sent a challenge: it is `legacy'."
  (when (and (drgnx-hub-core--live-p s conn) (eq (drgnx-hub-core--conn s conn :state) 'wait))
    (drgnx-hub-core--do 'timer-cancel (cons 'hub-challenge conn))
    (drgnx-hub-core--conn-put s conn :state 'legacy)
    (drgnx-hub-core--hello-done s conn :legacy nil)))

(defun drgnx-hub-core--hello-answered (s conn facts reply err)
  "The hub's answer to CONN's hello, FACTS what the hello said (:problem: why the cap could not be read; :proves: it
carried a proof; :expect: the proof the hub must give back; :version :socket :cap-file).  `no method hello' is
`legacy'; a hub that should have proved itself and did not is closed, its calls failed and the user told; otherwise
the calls waiting go out."
  (let ((socket (plist-get facts :socket)))
    (cond
     ((and err (null (plist-get err :code)) (equal (plist-get err :message) "no method hello"))
      (drgnx-hub-core--conn-put s conn :state 'legacy)
      (drgnx-hub-core--hello-done s conn :legacy nil))
     (err (drgnx-hub-core--reject s conn (format "the hub at %s refused this Emacs's hello: %s" socket (plist-get err :message))))
     ((plist-get facts :problem)
      (drgnx-hub-core--reject s conn (format "this Emacs cannot read the hub's cap %s (%s)" (plist-get facts :cap-file)
                                             (plist-get facts :problem))))
     ((and (plist-get facts :proves) (not (drgnx-hub-core--same-p (plist-get reply :proof) (plist-get facts :expect))))
      (drgnx-hub-core--reject s conn (format "the hub at %s did not prove it read %s" socket (plist-get facts :cap-file))
                              'unproven))
     (t (drgnx-hub-core--conn-put s conn :state 'ready)
        (drgnx-hub-core--conn-put s conn :proven (and (plist-get facts :proves) t))
        (drgnx-hub-core--hello-done s conn reply (plist-get facts :version))))))

(defun drgnx-hub-core--hello-done (s conn reply version)
  "CONN's hello was answered with REPLY (`:legacy' for a hub of before protocol 1): the skew hooks run, and the calls
waiting go out — unless the hub is `incompatible', when they fail."
  (setf (drgnx-hub-core-last-hello s) reply)
  (let ((skew (drgnx-hub-core-skew reply version (drgnx-hub-core--config s :schema))))
    (drgnx-hub-core--do 'hook 'skew skew reply)
    (if (eq skew 'incompatible)
        (drgnx-hub-core--reject s conn (drgnx-hub-core--incompatible-text reply)
                                (and (not (drgnx-hub-core--config s :noninteractive)) 'incompatible))
      (drgnx-hub-core--send-queued s conn))))

(defun drgnx-hub-core--open (s conn events)
  "The shell opened CONN: it waits for the hub's challenge (a timer), and a `ping' goes at once — a hub of before
protocol 1 answers it, where Ratatoskr's challenge always comes first."
  (drgnx-hub-core--conn-put s conn :live t)
  (drgnx-hub-core--conn-put s conn :events events)
  (drgnx-hub-core--conn-put s conn :state 'wait)
  (unless events (setf (drgnx-hub-core-client s) conn))
  (let ((wait (drgnx-hub-core--config s :challenge-wait)))
    (drgnx-hub-core--do 'timer-start (cons 'hub-challenge conn) wait)
    (drgnx-hub-core--call s conn "ping" nil nil :deadline wait :first t :role 'probe)))

(defun drgnx-hub-core--challenge (s conn nonce socket)
  (cond ((eq (drgnx-hub-core--conn s conn :state) 'legacy)
         ;; a v1 hub taken for `legacy': its calls would all be refused as service class; the next call connects again
         (drgnx-hub-core--reject s conn (format "the hub at %s sent its challenge late: connecting again" socket)))
        ((eq (drgnx-hub-core--conn s conn :state) 'wait)
         (drgnx-hub-core--do 'timer-cancel (cons 'hub-challenge conn))
         (if (stringp nonce)
             ;; the hello waits for the binary's version (the shell reads it); the connection no longer waits for a
             ;; challenge, so the probe's answer cannot make it `legacy'
             (progn (drgnx-hub-core--conn-put s conn :state 'version)
                    (drgnx-hub-core--do 'hook 'version conn nonce))
           (drgnx-hub-core--reject s conn (format "the hub at %s sent a challenge without a nonce" socket))))))

(defun drgnx-hub-core--challenge-late (s conn read socket)
  "The challenge wait passed with CONN still waiting for its hub's first line.  What already arrived is read first
\(the shell does, then READ is t): an Emacs busy past the wait runs the timer before it reads a challenge waiting in
the socket.  Still nothing: CONN is closed and its calls fail — never taken for `legacy'."
  (when (and (drgnx-hub-core--live-p s conn) (eq (drgnx-hub-core--conn s conn :state) 'wait))
    (if (not read)
        (drgnx-hub-core--do 'hook 'read conn)
      (drgnx-hub-core--reject s conn (format "the drgnx hub at %s sent nothing within %s s" socket
                                             (drgnx-hub-core--config s :challenge-wait))))))

;;;; The subscription

(defun drgnx-hub-core--resubscribe-stop (s)
  "Forget a redial under way: its timer and its clock."
  (drgnx-hub-core--do 'timer-cancel 'hub-resubscribe)
  (setf (drgnx-hub-core-resubscribe-since s) nil (drgnx-hub-core-resubscribe-delay s) 1))

(defun drgnx-hub-core--resubscribe-schedule (s now)
  "Arm the next redial of the subscription: after 1 s, then twice as long each time, up to 30 s.  After the give-up
\(600 s) from the first loss it stops and posts one notice naming Hub: Restart Now."
  (unless (drgnx-hub-core-resubscribe-since s)
    (setf (drgnx-hub-core-resubscribe-since s) now (drgnx-hub-core-resubscribe-delay s) 1))
  (if (>= (- now (drgnx-hub-core-resubscribe-since s)) (drgnx-hub-core--config s :give-up))
      (progn (setf (drgnx-hub-core-resubscribe-since s) nil (drgnx-hub-core-resubscribe-delay s) 1)
             (drgnx-hub-core--do 'notify 'warn "the drgnx hub is gone and did not come back; start it with Hub: Restart Now"
                                 'resubscribe-gave-up :command 'hub-restart-now))
    (drgnx-hub-core--do 'timer-start 'hub-resubscribe (drgnx-hub-core-resubscribe-delay s))
    (setf (drgnx-hub-core-resubscribe-delay s) (min 30 (* 2 (drgnx-hub-core-resubscribe-delay s))))))

(defun drgnx-hub-core--connect (s now opened redial-failed)
  (cond
   (redial-failed (drgnx-hub-core--resubscribe-schedule s now))
   (opened
    (setf (drgnx-hub-core-subscribing s) opened)
    (drgnx-hub-core--conn-put s opened :since now))
   (t
    ;; a subscribe left unanswered past the deadline (a hub stopped, or one that lost the line) is given up quietly
    (let ((c (drgnx-hub-core-subscribing s)))
      (when (and (drgnx-hub-core--live-p s c)
                 (> (- now (or (drgnx-hub-core--conn s c :since) now)) (drgnx-hub-core--config s :subscribe-deadline)))
        (setf (drgnx-hub-core-subscribing s) nil)
        (drgnx-hub-core--do 'hook 'quiet c)
        (drgnx-hub-core--do 'timer-cancel (cons 'hub-challenge c))
        (drgnx-hub-core--fail-conn s c "the drgnx hub did not answer subscribe")
        (drgnx-hub-core--conn-put s c :live nil)
        (drgnx-hub-core--do 'delete c)))
    ;; one subscription at once: a dial opens its own connection, which proves itself first
    (unless (or (drgnx-hub-core--live-p s (drgnx-hub-core-events s)) (drgnx-hub-core--live-p s (drgnx-hub-core-subscribing s)))
      (setf (drgnx-hub-core-asked-disconnect s) nil)
      (drgnx-hub-core--do 'hook 'dial)))))

(defun drgnx-hub-core--subscribed (s conn result)
  "The hub answered CONN's `subscribe' with RESULT: CONN is the subscribed connection, and the hub gets the hand-over
\(settings, keys, the token and held-keys questions, asked under CONN)."
  (when (and result (drgnx-hub-core--live-p s conn))
    (setf (drgnx-hub-core-events s) conn)
    (when (eq (drgnx-hub-core-subscribing s) conn) (setf (drgnx-hub-core-subscribing s) nil))
    (drgnx-hub-core--resubscribe-stop s)
    (drgnx-hub-core--do 'hook 'presence-start)
    (drgnx-hub-core--do 'hook 'exec-sync)
    (drgnx-hub-core--do 'notify :clear 'resubscribe-gave-up)
    (drgnx-hub-core--do 'hook 'hand-over conn)
    (when (drgnx-hub-core--conn s conn :proven)
      (drgnx-hub-core--do 'hook 'connected))))

(defun drgnx-hub-core--editor-answered (s result)
  "The answer to `gateway/editor-token': RESULT (:token :url)."
  (when (and (consp result) (stringp (plist-get result :token)) (stringp (plist-get result :url)))
    (setf (drgnx-hub-core-editor s) (cons (plist-get result :token) (plist-get result :url)))
    (drgnx-hub-core--do 'hook 'editor-token)))

(defun drgnx-hub-core--keys-held-answered (s result)
  "The answer to `gateway/keys-held': RESULT (:providers [ID…])."
  (when (consp result)
    (setf (drgnx-hub-core-keys-held s) (cl-remove-if-not #'stringp (append (plist-get result :providers) nil)))
    (drgnx-hub-core--do 'hook 'keys-held)))

(defun drgnx-hub-core--closed (s conn now)
  "CONN's sentinel ran: its calls fail; the subscribed one's end is said.  When the subscription went away without
being asked to (a hub restart or crash), the editor token and the held keys are forgotten and the subscription is
redialled with a backoff."
  (drgnx-hub-core--conn-put s conn :live nil)
  (drgnx-hub-core--do 'timer-cancel (cons 'hub-challenge conn))
  (drgnx-hub-core--fail-conn s conn "the drgnx hub's connection closed")
  (when (eq (drgnx-hub-core-client s) conn) (setf (drgnx-hub-core-client s) nil))
  (when (drgnx-hub-core--conn s conn :events)
    (let ((lost (or (eq (drgnx-hub-core-events s) conn) (drgnx-hub-core-resubscribe-since s)))
          (asked (or (drgnx-hub-core-asked-disconnect s) (drgnx-hub-core--conn s conn :asked))))
      (when (eq (drgnx-hub-core-events s) conn)
        (setf (drgnx-hub-core-events s) nil)
        (drgnx-hub-core--do 'hook 'presence-stop))
      (when (eq (drgnx-hub-core-subscribing s) conn) (setf (drgnx-hub-core-subscribing s) nil))
      (when (and lost (not asked))
        (setf (drgnx-hub-core-editor s) nil (drgnx-hub-core-keys-held s) :unknown)
        (drgnx-hub-core--resubscribe-schedule s now))
      ;; the hub went away (shutdown, a crash, a restart): whoever mirrors it is told
      (drgnx-hub-core--do 'hook 'disconnected))))

(defun drgnx-hub-core--disconnect (s)
  "Close this Emacs's connections to the hub; the calls waiting on them fail (once).  Not redialled."
  (setf (drgnx-hub-core-asked-disconnect s) t)
  (drgnx-hub-core--resubscribe-stop s)
  (dolist (c (list (drgnx-hub-core-client s) (drgnx-hub-core-events s) (drgnx-hub-core-subscribing s)))
    (when c
      (drgnx-hub-core--conn-put s c :asked t)
      (drgnx-hub-core--do 'timer-cancel (cons 'hub-challenge c))
      (drgnx-hub-core--fail-conn s c "disconnected from the drgnx hub")
      (when (drgnx-hub-core--live-p s c)
        (drgnx-hub-core--conn-put s c :live nil)
        (drgnx-hub-core--do 'delete c))))
  (setf (drgnx-hub-core-client s) nil (drgnx-hub-core-events s) nil (drgnx-hub-core-subscribing s) nil)
  (drgnx-hub-core--do 'hook 'presence-stop)
  (drgnx-hub-core--do 'hook 'unsync)
  (setf (drgnx-hub-core-editor s) nil (drgnx-hub-core-keys-held s) :unknown)
  (dolist (id (sort (mapcar #'car (drgnx-hub-core-pending s)) #'<))
    (drgnx-hub-core--settle s id nil "disconnected from the drgnx hub")))

;;;; The step

(defun drgnx-hub-core-settled-p (s)
  "Whether S is subscribed and no call waits for an answer: no hand-over answer can still change it."
  (and (drgnx-hub-core-events s) (null (drgnx-hub-core-pending s)) t))

(defun drgnx-hub-core-step (state event)
  "The client in STATE takes EVENT (one of `drgnx-hub-core-event-kinds'): (NEW-STATE . EFFECTS).  STATE is not
changed.  Signals on an event of no known kind."
  (let ((s (drgnx-hub-core--copy state)) (drgnx-hub-core--effects nil))
    ;; fresh cells: `drgnx-hub-core--conn-put' replaces their plists, never STATE's
    (setf (drgnx-hub-core-conns s) (mapcar (lambda (c) (cons (car c) (cdr c))) (drgnx-hub-core-conns s)))
    (pcase event
      (`(open ,conn ,events) (drgnx-hub-core--open s conn events))
      (`(connect ,now . ,keys)
       (drgnx-hub-core--connect s now (plist-get keys :opened) (plist-get keys :redial-failed)))
      (`(call ,conn ,method ,params ,cb . ,keys) (apply #'drgnx-hub-core--call s conn method params cb keys))
      (`(challenge ,conn ,nonce ,socket) (drgnx-hub-core--challenge s conn nonce socket))
      (`(answer ,_conn ,id ,result ,error) (drgnx-hub-core--settle s id result error))
      (`(event ,conn ,name ,data)
       (when (drgnx-hub-core--conn s conn :events) (drgnx-hub-core--do 'hook 'events conn name data)))
      (`(closed ,conn ,now) (drgnx-hub-core--closed s conn now))
      (`(timer ,key . ,keys)
       (pcase key
         (`(hub-call . ,id)
          (when-let* ((entry (cdr (assq id (drgnx-hub-core-pending s)))))
            (drgnx-hub-core--settle s id nil (format "the drgnx hub did not answer %s in time" (plist-get entry :method)))))
         (`(hub-challenge . ,conn) (drgnx-hub-core--challenge-late s conn (plist-get keys :read) (plist-get keys :socket)))
         ('hub-resubscribe
          ;; never starts a hub, never asks anything: a dial that fails at once arms the next one (`:redial-failed')
          (unless (or (drgnx-hub-core-asked-disconnect s) (drgnx-hub-core--live-p s (drgnx-hub-core-events s)))
            (drgnx-hub-core--do 'hook 'redial)))
         (_ (error "drgnx-hub-core: no timer %S" key))))
      ('(disconnect) (drgnx-hub-core--disconnect s))
      (`(version-known ,conn ,nonce)
       (when (drgnx-hub-core--live-p s conn) (drgnx-hub-core--do 'hook 'hello conn nonce)))
      (_ (error "drgnx-hub-core: no event %S" event)))
    (cons s (nreverse drgnx-hub-core--effects))))

(provide 'drgnx-hub-core)
;;; drgnx-hub-core.el ends here
