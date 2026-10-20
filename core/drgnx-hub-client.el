;;; drgnx-hub-client.el --- The hub's socket client: what editors, the CLI and the sandbox load -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The client half of the hub (drgnx-hub.el serves): where the hub's socket is and whether it can be trusted, the
;; line protocol (one JSON object per line), requests and their answers, the event subscription, starting the hub
;; as a durable job, and `drgnx hub start|stop|status'.  It loads none of the hub's runtime (gateway, jobs, agents,
;; coordination): an editor that only talks to the hub requires this file.  The write queue (`drgnx-hub--enqueue',
;; `drgnx-hub--drain') is here too, because the sandbox's MCP server (drgnx-sandbox-mcp.el) writes the same way.
;; See docs/develop/hub.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-jobs)
(require 'drgnx-guard)

(declare-function drgnx-ai-providers "drgnx-ai")
(defvar drgnx-ai--keys)

(defvar drgnx-hub-event-functions nil
  "Functions called with (EVENT DATA) for each event the hub sends this Emacs (after `drgnx-hub-connect'); EVENT a
string (\"request\", \"fallback\", \"budget\"), DATA a plist.  Each runs inside the guard (`drgnx-guard-run-hook'):
one that fails or asks is recorded as a notice, and the next still runs.")

(defvar drgnx-hub-disconnect-functions nil
  "Called when this Emacs's event connection to the hub closes (the hub ended, or `drgnx-hub-disconnect'); each
inside the guard, as `drgnx-hub-event-functions'.")

(defvar drgnx-hub--client nil "This Emacs's connection to the hub, for requests.")
(defvar drgnx-hub--events nil "This Emacs's subscribed connection to the hub.")
(defvar drgnx-hub--subscribing nil "This Emacs's connection whose `subscribe' the hub has not answered yet.")
(defvar drgnx-hub-subscribe-deadline 5
  "Seconds a `subscribe' may go unanswered: after that `drgnx-hub-connect' gives it up and subscribes again.")
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
the state dir; past 103 bytes, drgnx-hub-UID/ in the first of $TMPDIR, $TMP, $TEMP, else /tmp.  A function of the
environment alone, as the Rust side computes it (test/fixtures/hub-socket-cases.json): never `temporary-file-directory',
which macOS's Emacs takes from `getconf DARWIN_USER_TEMP_DIR' when none of the three is set, and a user can change."
  (let* ((name (format "hub-%s.sock" (substring (secure-hash 'sha1 (drgnx-data-dir)) 0 8)))
         (run (getenv "XDG_RUNTIME_DIR"))
         (path (if (and run (file-directory-p run))
                   (expand-file-name name (expand-file-name "drgnx" run))
                 (expand-file-name name (expand-file-name "hub" (drgnx-state-dir))))))
    ;; a Unix socket's path ends with a NUL inside 104 bytes on macOS (108 on Linux): at most 103; a deep state
    ;; dir gets a short private one instead.  Counted as the system sees it: encoded (macOS decomposes "é" to 3 bytes)
    (if (<= (length (encode-coding-string path (or file-name-coding-system default-file-name-coding-system))) 103) path
      (let ((tmp (file-name-as-directory (or (getenv "TMPDIR") (getenv "TMP") (getenv "TEMP") "/tmp"))))
        (expand-file-name name (expand-file-name (format "drgnx-hub-%d" (user-uid)) tmp))))))

(defun drgnx-hub--private-dir (dir)
  "Make DIR (mode 0700 from the start) and make sure it is this user's own directory (a shared /tmp: never another's,
nor a link — one would be followed to wherever it points, and that chmodded)."
  (let ((dir (directory-file-name dir)))
    (unless (file-attributes dir) (with-file-modes #o700 (make-directory dir t)))
    (let ((a (file-attributes dir)))
      (unless (eq (file-attribute-type a) t) (error "%s is not a directory" dir))
      (unless (eql (file-attribute-user-id a) (user-uid)) (error "%s belongs to another user" dir)))
    (set-file-modes dir #o700 'nofollow)))

(defun drgnx-hub--untrusted (socket)
  "Why this Emacs must not use SOCKET (it would hand its keys to whatever answers there), or nil: its directory must
be a directory (not a link) of this user's with no access for others (0700), and the socket, when there, this
user's.  Nothing else can then have made it.  A directory that is not there is a reason too: what is checked is
then connected to by path, and a missing one could be another user's by then (one swapped in and out of /tmp)."
  (let* ((dir (directory-file-name (file-name-directory socket)))
         (d (file-attributes dir)) (s (file-attributes socket))
         ;; its mode from what was read once ("drwx------"): a directory gone since is no error
         (mode (and d (cl-loop with m = (file-attribute-modes d) for i from 1 to 9
                               unless (memq (aref m i) '(?- ?S ?T)) sum (ash 1 (- 9 i))))))
    (cond ((null d) (format "%s does not exist (no hub)" dir))
          ((not (eq (file-attribute-type d) t)) (format "%s is not a directory" dir))
          ((not (eql (file-attribute-user-id d) (user-uid))) (format "%s belongs to another user" dir))
          ((/= 0 (logand mode #o077)) (format "%s is open to other users (mode %o; it must be 700)" dir mode))
          ((and s (not (eql (file-attribute-user-id s) (user-uid)))) (format "%s belongs to another user" socket)))))

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
  (drgnx-hub--send-line conn (concat (json-serialize (drgnx-hub--jsonable object)) "\n")))

(defun drgnx-hub--send-line (conn line)
  "Write LINE to CONN, as `drgnx-hub--send' does."
  (when (process-live-p conn)
    (condition-case nil (process-send-string conn line)
      (error (ignore-errors (delete-process conn))))))

;;;; The write queue

(defcustom drgnx-hub-client-max-queued (* 16 1024 1024)
  "Bytes the hub holds for a client while a write to it waits; past that the client counts as stopped and its
connection is closed (its Emacs connects again).  One snapshot can carry whole files (edits to review)."
  :type 'integer :group 'drgnx)

(defcustom drgnx-hub-client-stuck-after 10
  "Seconds a write to a hub client may make no progress before the client counts as stopped (a suspended Emacs)
and its connection is closed.  A line goes out `drgnx-hub--piece' bytes at a time, each one progress."
  :type 'number :group 'drgnx)

(defconst drgnx-hub--piece 8192
  "Bytes of a line (unibyte, as `json-serialize' makes it) the hub writes to a client at a time: a piece may end
inside a UTF-8 sequence, which the client's decoder carries over.  A long line to a client that reads, slowly, is
progress, never a stopped client.  A write that fills the client's socket waits 20 ms before it tries again, and
macOS's local sockets hold 8 KB: a snapshot of a few MB takes seconds there.")

(defvar drgnx-hub--writing nil
  "The hub's writes in progress, innermost first: a write that waits runs timers and filters, which may write to
another client on top of it — the ones beneath cannot go on meanwhile.")

(defun drgnx-hub--client-stuck-p (conn &optional more)
  "Has CONN stopped reading, while a write to it is in progress: its queue (with MORE bytes) past
`drgnx-hub-client-max-queued', wherever its write is (beneath a live client's that goes on for long, it would grow
without end), or its write the innermost one in progress and without progress for `drgnx-hub-client-stuck-after'
\(one beneath cannot go on, so its time is not judged)?"
  (let ((since (process-get conn :sending)))
    (and since
         (or (> (+ (or (process-get conn :queued-bytes) 0) (or more 0)) drgnx-hub-client-max-queued)
             (and (eq conn (car drgnx-hub--writing))
                  (> (- (float-time) since) drgnx-hub-client-stuck-after))))))

(defun drgnx-hub--drop (conn)
  (message "drgnx hub: a client stopped reading; its connection is closed")
  (delete-process conn))

(defun drgnx-hub--enqueue (conn line)
  "Put LINE in CONN's queue — unless CONN stopped reading (`drgnx-hub--client-stuck-p'): it is dropped instead (its
Emacs connects again)."
  (if (drgnx-hub--client-stuck-p conn (string-bytes line)) (drgnx-hub--drop conn)
    (process-put conn :queue (cons line (process-get conn :queue)))
    (process-put conn :queued-bytes (+ (or (process-get conn :queued-bytes) 0) (string-bytes line)))))

(defun drgnx-hub--drain (conn)
  "Write CONN's queue, in order — unless a write to it is already in progress below (it writes what comes)."
  (unless (process-get conn :sending)
    (unwind-protect
        (let (lines)
          (while (and (process-live-p conn) (setq lines (nreverse (process-get conn :queue))))
            (process-put conn :queue nil)
            (process-put conn :queued-bytes 0)
            (dolist (l lines)
              (let ((t0 (float-time)))
                (let ((drgnx-hub--writing (cons conn drgnx-hub--writing)) (i 0) (n (length l)))
                  ;; a piece at a time, each one progress: a write that makes progress is not stuck
                  (while (and (< i n) (process-live-p conn))
                    (process-put conn :sending (float-time))
                    (drgnx-hub--send-line conn (if (and (= i 0) (<= n drgnx-hub--piece)) l
                                                 (substring l i (min n (+ i drgnx-hub--piece)))))
                    (setq i (+ i drgnx-hub--piece))))
                ;; a write beneath this one could not go on meanwhile: it gets back the time this one took (only that:
                ;; a stopped client beneath writes to others still ends)
                (when-let* ((below (car drgnx-hub--writing)) (since (process-get below :sending)))
                  (process-put below :sending (+ since (- (float-time) t0))))))))
      (process-put conn :sending nil))))

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

;;;; The client side

(defun drgnx-hub--ping-socket (socket)
  "Does a hub answer on SOCKET?  (At most a second; never an error.)  One where it is not private to this user is
never asked."
  (condition-case nil
      (when (and (file-exists-p socket) (not (drgnx-hub--untrusted socket)))
        (let* ((got nil)
               (c (make-network-process :name "drgnx-hub-probe" :family 'local :service socket :noquery t
                                        :coding 'utf-8-unix :filter (lambda (_p s) (setq got (concat got s))))))
          (unwind-protect
              (progn (process-send-string c "{\"id\":0,\"method\":\"ping\"}\n")
                     (let ((deadline (+ (float-time) 1)))
                       (while (and (not (and got (string-search "\n" got))) (< (float-time) deadline))
                         (accept-process-output nil 0.02)))
                     (and got (string-search "\"pid\"" got) t))
            (delete-process c))))
    (error nil)))

(defun drgnx-hub--connect-socket (filter)
  "A connection to the hub's socket — never one that is not private to this user (`drgnx-hub--untrusted')."
  (let ((socket (drgnx-hub-socket)))
    (when-let* ((why (drgnx-hub--untrusted socket)))
      (error "Not connecting to the drgnx hub: %s" why))
    (make-network-process :name "drgnx-hub-client" :family 'local :service socket :noquery t
                          :coding 'utf-8-unix :filter filter)))

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
  (remove-hook 'drgnx-hub-event-functions #'drgnx-hub--note-tests)
  (clrhash drgnx-hub--pending))

(defun drgnx-hub-running-p ()
  "Does a hub serve this data dir?"
  (drgnx-hub--ping-socket (drgnx-hub-socket)))

(defun drgnx-hub--held-keys ()
  "The provider keys this Emacs already holds, asking no one: a provider's environment variable, else a key loaded
this session (`drgnx-ai--keys': from a command the user ran).  (:PROVIDER KEY…)."
  (require 'drgnx-ai)                   ; the provider list: not needed to load the client, only to hand keys over
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
  (require 'drgnx-ai)
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
  ;; a subscribe left unanswered past the deadline (a hub stopped, or one that lost the line) is given up quietly
  (when (and (process-live-p drgnx-hub--subscribing)
             (> (- (float-time) (process-get drgnx-hub--subscribing :since)) drgnx-hub-subscribe-deadline))
    (set-process-sentinel drgnx-hub--subscribing #'ignore)
    (delete-process drgnx-hub--subscribing)
    (setq drgnx-hub--subscribing nil))
  (unless (or (process-live-p drgnx-hub--events) (process-live-p drgnx-hub--subscribing))
    (let ((c (drgnx-hub--connect-socket
              (lambda (conn chunk)
                (drgnx-hub--lines conn chunk
                                  (lambda (json)
                                    (cond ((plist-get json :event)
                                           (drgnx-guard-run-hook 'drgnx-hub-event-functions (plist-get json :event) (plist-get json :data)))
                                          ((plist-get json :id)
                                           (setq drgnx-hub--events conn)
                                           (when (eq drgnx-hub--subscribing conn) (setq drgnx-hub--subscribing nil))))))))))
      (setq drgnx-hub--subscribing c)
      (process-put c :since (float-time))
      ;; the hub went away (shutdown, a crash, a restart): whoever mirrors it is told
      (set-process-sentinel c (lambda (p _e)
                                (unless (process-live-p p)
                                  (when (eq drgnx-hub--events p) (setq drgnx-hub--events nil))
                                  (when (eq drgnx-hub--subscribing p) (setq drgnx-hub--subscribing nil))
                                  (drgnx-guard-run-hook 'drgnx-hub-disconnect-functions))))
      (drgnx-hub--send c (list :id 0 :method "subscribe" :params (make-hash-table)))
      (add-hook 'drgnx-hub-event-functions #'drgnx-hub--note-tests)   ; removed by `drgnx-hub-disconnect'
      ;; a hub keeps keys in memory only: one that restarted has none, so each new subscription gives them again
      (with-demoted-errors "drgnx hub: keys not handed over: %S" (drgnx-hub--send-keys)))))

(declare-function drgnx-statusbar-note-tests "drgnx-statusbar")

(defun drgnx-hub--note-tests (event data)
  "In an editor: the test runs among the `events' the hub sent reach the status bar (`drgnx-statusbar-note-tests',
when it is loaded)."
  (when (and (equal event "events") (fboundp 'drgnx-statusbar-note-tests))
    (dolist (e (append (plist-get data :events) nil))
      (when (equal (plist-get e :kind) "test")
        (let ((d (plist-get e :data)))
          (when (and (proper-list-p d) (or (natnump (plist-get d :passed)) (natnump (plist-get d :failed))))
            (drgnx-statusbar-note-tests (or (plist-get d :passed) 0) (or (plist-get d :failed) 0) (plist-get e :agent))))))))

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

(provide 'drgnx-hub-client)
;;; drgnx-hub-client.el ends here
