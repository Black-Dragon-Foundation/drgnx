;;; drgnx-hub-client.el --- The hub's socket client: what editors, the CLI and the sandbox load -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The client half of the hub (drgnx-hub.el serves): where the hub's socket is and whether it can be trusted, the
;; line protocol (one JSON object per line), protocol v1 (the hub's challenge, `hello' with the proofs both ways, the
;; skew rules), requests with deadlines and their answers, the event subscription, starting the hub as a durable job,
;; and `drgnx hub start|stop|status'.  It loads none of the hub's runtime (gateway, jobs, agents, coordination): an
;; editor that only talks to the hub requires this file.  The write queue (`drgnx-hub--enqueue', `drgnx-hub--drain')
;; is here too, because the sandbox's MCP server (drgnx-sandbox-mcp.el) writes the same way.
;; See docs/develop/hub.md, "The client".

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'drgnx-paths)
(require 'drgnx-jobs)
(require 'drgnx-guard)
(require 'drgnx-timer)
(require 'drgnx-file)
(require 'drgnx-notice)
(require 'drgnx-work-db)                ; `drgnx-work-db-schema-version', which the hello says

(declare-function drgnx-ai-providers "drgnx-ai")
(defvar drgnx-ai--keys)
(defvar drgnx-hub--server)              ; drgnx-hub.el: this Emacs's hub socket, when it is the hub
(defvar drgnx-hub--editor)              ; the editor token and the held keys: defined below, used by `drgnx-hub-disconnect'
(defvar drgnx-hub--keys-held)

(defvar drgnx-hub-event-functions nil
  "Functions called with (EVENT DATA) for each event the hub sends this Emacs (after `drgnx-hub-connect'); EVENT a
string (\"request\", \"fallback\", \"budget\"), DATA a plist.  Each runs inside the guard (`drgnx-guard-run-hook'):
one that fails or asks is recorded as a notice, and the next still runs.")

(defvar drgnx-hub-disconnect-functions nil
  "Called when this Emacs's event connection to the hub closes (the hub ended, or `drgnx-hub-disconnect'); each
inside the guard, as `drgnx-hub-event-functions'.")

(defvar drgnx-hub--event-conn nil
  "The connection whose event `drgnx-hub-event-functions' run for, while they run (else nil): a handler that acts
only for a hub that proved itself checks its `:drgnx-proven'.")

(defvar drgnx-hub--client nil "This Emacs's connection to the hub, for requests.")
(defvar drgnx-hub--events nil "This Emacs's subscribed connection to the hub.")
(defvar drgnx-hub--subscribing nil "This Emacs's connection whose `subscribe' the hub has not answered yet.")
(defvar drgnx-hub-subscribe-deadline 5
  "Seconds a `subscribe' may go unanswered: after that `drgnx-hub-connect' gives it up and subscribes again.")
(defvar drgnx-hub--pending (make-hash-table)
  "Request id → (:cb CALLBACK :conn CONNECTION :full FULL :method METHOD), until its callback has run.")
(defvar drgnx-hub--next-id 0)

(defconst drgnx-hub-proto 1 "The hub protocol this drgnx speaks: its `hello' says it.")
(defconst drgnx-hub-proto-min 1 "The oldest hub protocol this drgnx still speaks.")
(defconst drgnx-hub-records 2
  "The record layout this drgnx reads (records 2: JSON objects): the agents mirror pauses while a hub's differs.")

(defcustom drgnx-hub-call-deadline 30
  "Seconds a call to the hub may go unanswered: then its callback gets an error (`drgnx-hub-call')."
  :type 'number :group 'drgnx)

(defconst drgnx-hub--challenge-wait 2
  "Seconds a new connection waits for the hub's challenge: a hub that sends none by then is of before protocol 1.")

(defvar drgnx-hub-client-proves t
  "Non-nil: this Emacs's hello proves it read the hub's cap file, which makes its connections user class.  nil: the
hello carries no proof and the cap is never read, so the connections stay service class.  `drgnx-coord-mcp-main'
binds it to nil: a coordination server an agent started must never become user class by reading the cap.")

(defvar drgnx-hub-skew-functions nil
  "Abnormal hook: (SKEW REPLY) after each hub's answer to this Emacs's hello — REPLY its plist, or `:legacy' for a hub
of before protocol 1; SKEW as `drgnx-hub-skew' has it.  Each runs inside the guard.  The mirror pauses when the
record layout differs.")

(defvar drgnx-hub--last-hello nil "The last hub's answer to this Emacs's hello: a plist, `:legacy', or nil.")
(defvar drgnx-hub--nonces 0 "Nonces made: one of their inputs.")
(defvar drgnx-hub--binary-version nil
  "(FILE MTIME COMMIT) of Ratatoskr's binary as `drgnx-hub-client-binary-version' last read it.")
(defvar drgnx-hub--binary-reading nil "The `ratatoskr version --json' process reading now, or nil.")

(defvar drgnx-hub--ensuring nil
  "The `ratatoskr ensure' process running now, or nil.  Its property `:callbacks' holds the functions to call (with
nil or the reason it failed) when it ends.")

(defconst drgnx-hub-ensure-deadline 10 "Seconds `ratatoskr ensure' may run before it is ended and counted as failed.")

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

(defun drgnx-hub--line-too-long (conn limit)
  (message "drgnx hub: a line over %d characters; its connection is closed" limit)
  (process-put conn :pending nil)
  (delete-process conn))

(defun drgnx-hub--lines (conn chunk fn &optional bad limit)
  "Split CONN's input into lines; FN gets each parsed JSON object, BAD (when given) each line that is not JSON.
With LIMIT, a line longer than LIMIT closes CONN: nothing after it is read, nor after FN or BAD closed CONN.
Only CHUNK is searched for a newline: the start of a line still open waits in CONN's list of pieces (`:pending'),
joined once when its newline comes, so a long line in many chunks costs its length (HUB-LINES-1)."
  (let ((start 0) (n (length chunk)) (live (process-live-p conn)) nl)
    (while (and (setq nl (string-search "\n" chunk start)) (or (not live) (process-live-p conn)))
      (let* ((pending (process-get conn :pending))
             (line (if pending (apply #'concat (nreverse (cons (substring chunk start nl) pending)))
                     (substring chunk start nl))))
        (process-put conn :pending nil)
        (process-put conn :pending-length 0)
        (setq start (1+ nl))
        (if (and limit (> (length line) limit))
            (progn (setq start n) (drgnx-hub--line-too-long conn limit))
          (let ((json (condition-case nil
                          (json-parse-string line :object-type 'plist :array-type 'list :null-object nil :false-object nil)
                        (error :bad))))
            (cond ((eq json :bad) (when bad (funcall bad line)))
                  (json (funcall fn json)))))))
    (when (and (< start n) (or (not live) (process-live-p conn)))
      (let ((length (+ (or (process-get conn :pending-length) 0) (- n start))))
        (if (and limit (> length limit))
            (drgnx-hub--line-too-long conn limit)
          (process-put conn :pending (cons (substring chunk start) (process-get conn :pending)))
          (process-put conn :pending-length length))))))

;;;; The client side

(defun drgnx-hub--ping-socket (socket)
  "Does a hub answer on SOCKET?  (At most a second; never an error.)  One where it is not private to this user is
never asked.  Event lines (Ratatoskr's challenge comes first) are skipped: the first other line is the answer."
  (condition-case nil
      (when (and (file-exists-p socket) (not (drgnx-hub--untrusted socket)))
        (let* ((answer nil)
               (c (make-network-process :name "drgnx-hub-probe" :family 'local :service socket :noquery t
                                        :coding 'utf-8-unix
                                        :filter (drgnx-guard-wrap
                                                 (lambda (p s)
                                                   (drgnx-hub--lines p s (lambda (j) (unless (or answer (plist-get j :event))
                                                                                       (setq answer j)))))
                                                 "hub probe"))))
          (unwind-protect
              (progn (process-send-string c "{\"id\":0,\"method\":\"ping\"}\n")
                     (let ((deadline (+ (float-time) 1)))
                       (while (and (not answer) (< (float-time) deadline))
                         (accept-process-output nil 0.02)))
                     (and (natnump (plist-get (plist-get answer :result) :pid)) t))
            (delete-process c))))
    (error nil)))

(defun drgnx-hub--connect-socket (filter)
  "A connection to the hub's socket — never one that is not private to this user (`drgnx-hub--untrusted')."
  (let ((socket (drgnx-hub-socket)))
    (when-let* ((why (drgnx-hub--untrusted socket)))
      (error "Not connecting to the drgnx hub: %s" why))
    (make-network-process :name "drgnx-hub-client" :family 'local :service socket :noquery t
                          :coding 'utf-8-unix :filter (drgnx-guard-wrap filter "hub connection"))))

;;;; Proofs and the binary on disk

(defun drgnx-hub-cap-file ()
  "The hub's cap file, `hub-HASH.cap' beside `drgnx-hub-socket' (mode 0600 in its 0700 directory): what an editor or
the CLI proves it read in its hello."
  (concat (file-name-sans-extension (drgnx-hub-socket)) ".cap"))

(defun drgnx-hub-hmac (key text)
  "HMAC-SHA256 of TEXT with KEY (strings; their UTF-8 bytes), as 64 hex characters (RFC 2104 over `secure-hash')."
  (let* ((key (encode-coding-string key 'utf-8 t))
         (key (if (> (length key) 64) (secure-hash 'sha256 key nil nil t) key))
         (key (concat key (make-string (- 64 (length key)) 0)))
         (pad (lambda (x) (apply #'unibyte-string (mapcar (lambda (c) (logxor c x)) key)))))
    (secure-hash 'sha256 (concat (funcall pad #x5c)
                                 (secure-hash 'sha256 (concat (funcall pad #x36) (encode-coding-string text 'utf-8 t)) nil nil t)))))

(defun drgnx-hub--same-p (a b)
  "Whether the strings A and B are equal, compared as SHA-256 digests (the time taken never tells where they differ)."
  (and (stringp a) (stringp b) (string= (secure-hash 'sha256 a) (secure-hash 'sha256 b))))

(defun drgnx-hub--nonce ()
  "A fresh nonce, 32 hex digits: unique, not secret (SHA-256 of the pid, the time, a counter and `random')."
  (substring (secure-hash 'sha256 (format "%d %s %d %d" (emacs-pid) (format-time-string "%s.%N")
                                          (cl-incf drgnx-hub--nonces) (random)))
             0 32))

(defun drgnx-hub--read-cap ()
  "The hub's cap (`drgnx-hub-cap-file', read bounded at 256 bytes), or (:problem REASON) when it cannot be read."
  (condition-case err
      (let ((text (drgnx-file-read-bounded (drgnx-hub-cap-file) :max-bytes 256)))
        (if text (string-trim text) (list :problem "it does not exist")))
    (drgnx-file-refused (list :problem (nth 2 err)))
    (error (list :problem (error-message-string err)))))

(defun drgnx-hub-client-binary ()
  "Ratatoskr's binary: DRGNX_RATATOSKR_BIN when it is the absolute name of an executable file, else
<data>/bin/ratatoskr when it is one, else nil."
  (let ((ok (lambda (f) (and f (string-prefix-p "/" f) (file-regular-p f) (file-executable-p f) f))))
    (or (funcall ok (getenv "DRGNX_RATATOSKR_BIN"))
        (funcall ok (expand-file-name "bin/ratatoskr" (drgnx-data-dir))))))

(defun drgnx-hub--binary-version-read (p _event)
  "The `version --json' process P ended: its `commit' is cached for the file and time it read."
  (unless (process-live-p p)
    (let ((commit (and (eq (process-status p) 'exit) (eql (process-exit-status p) 0) (buffer-live-p (process-buffer p))
                       (with-current-buffer (process-buffer p)
                         (ignore-errors (plist-get (json-parse-string (buffer-string) :object-type 'plist) :commit))))))
      (when (stringp commit) (setq drgnx-hub--binary-version (append (process-get p :stamp) (list commit))))
      (process-put p :done t)
      (when (buffer-live-p (process-buffer p)) (kill-buffer (process-buffer p)))
      (when (eq drgnx-hub--binary-reading p) (setq drgnx-hub--binary-reading nil))
      (drgnx-hub--version-read-ended p))))

(defun drgnx-hub--version-read-ended (p)
  "The read P ended (or ran too long): the functions waiting for its answer (`drgnx-hub--with-binary-version') run once."
  (drgnx-timer-cancel (cons 'hub-binary-version p))
  (let ((fns (nreverse (process-get p :then))))
    (process-put p :then nil)
    (dolist (f fns) (funcall f))))

(defun drgnx-hub--version-read-expired (p)
  "The read P ran past its deadline: it is ended, and what waits for it goes on without a version."
  (when (process-live-p p) (delete-process p))
  (when (eq drgnx-hub--binary-reading p) (setq drgnx-hub--binary-reading nil))
  (drgnx-hub--version-read-ended p))

(defun drgnx-hub--with-binary-version (fn)
  "Call FN once Ratatoskr's binary version is known or cannot be: at once when it is cached or there is no binary, else
when the read that runs ends (at most 2 s).  Never waits.
The read has ended when its sentinel or its expiry ran, not when its child exited: a fast child is reaped (no
longer live) before the sentinel stores its commit."
  (if (drgnx-hub-client-binary-version t)
      (funcall fn)
    (let ((p drgnx-hub--binary-reading))
      (if (and (processp p) (not (process-get p :done)))
          (process-put p :then (cons fn (process-get p :then)))
        (funcall fn)))))

(defun drgnx-hub--read-binary-version (stamp)
  "Start reading the version of the binary STAMP names ((FILE MTIME)), unless that read runs already: the process,
or nil when it cannot start.  One left running past 2 s is ended by the next read."
  (let ((p drgnx-hub--binary-reading))
    (when (and (process-live-p p)
               (or (not (equal (process-get p :stamp) stamp)) (> (- (float-time) (process-get p :started)) 2)))
      (delete-process p)
      (setq p nil drgnx-hub--binary-reading nil))
    (or (and (process-live-p p) p)
        (condition-case nil
            (let ((p (make-process :name "ratatoskr-version" :buffer (generate-new-buffer " *ratatoskr version*" t)
                                   :noquery t :connection-type 'pipe :command (list (car stamp) "version" "--json")
                                   :sentinel (drgnx-guard-wrap #'drgnx-hub--binary-version-read "ratatoskr version"))))
              (process-put p :stamp stamp)
              (process-put p :started (float-time))
              (drgnx-timer-start (cons 'hub-binary-version p) 2 #'drgnx-hub--version-read-expired :args (list p) :owner :core)
              (setq drgnx-hub--binary-reading p))
          (error nil)))))

(defun drgnx-hub-client-binary-version (&optional cached-only)
  "The drgnx commit Ratatoskr's binary on disk was built from (its `version --json' `commit'), or nil: no binary, or
none read yet.  Cached by the file's name and modification time; a read is bounded at 2 s.  CACHED-ONLY (a daemon
path: a filter, a timer) never waits: the cached value, or nil while the read it starts runs."
  (when-let* ((bin (drgnx-hub-client-binary)))
    (let ((stamp (list bin (file-attribute-modification-time (file-attributes bin)))))
      (unless (equal (butlast drgnx-hub--binary-version) stamp)
        (let ((p (drgnx-hub--read-binary-version stamp)))
          (unless cached-only
            (let ((limit (+ (float-time) 2)))
              (while (and p (not (process-get p :done)) (< (float-time) limit)) (accept-process-output p 0.02))
              (when (process-live-p p) (delete-process p))))))
      (and (equal (butlast drgnx-hub--binary-version) stamp) (car (last drgnx-hub--binary-version))))))

;;;; Connections: the challenge, hello, the queue, deadlines

(defun drgnx-hub--serving-here-p (socket)
  "Whether this Emacs itself serves SOCKET (`drgnx-hub--server' live on that path: the Lisp hub's own tests, where
keys never leave the process).  Such a hub sends no challenge and is proven without a hello."
  (let ((server (bound-and-true-p drgnx-hub--server)))
    (and (processp server) (process-live-p server)
         (equal (expand-file-name (process-contact server :service)) (expand-file-name socket)))))

(defun drgnx-hub--client-filter (conn chunk)
  "A client connection's filter: the challenge starts the hello, an answer settles its call, an event (on the
subscribed connection) goes to `drgnx-hub-event-functions'."
  (drgnx-hub--lines conn chunk (lambda (json) (drgnx-hub--client-line conn json))))

(defun drgnx-hub--client-line (conn json)
  (let ((event (plist-get json :event)))
    (cond ((and (equal event "challenge") (eq (process-get conn :drgnx-state) 'legacy))
           ;; a v1 hub taken for `legacy': its calls would all be refused as service class; the next call connects again
           (drgnx-hub--reject-hub conn (format "the hub at %s sent its challenge late: connecting again" (drgnx-hub-socket))))
          ((equal event "challenge")
           (when (eq (process-get conn :drgnx-state) 'wait)
             (drgnx-timer-cancel (cons 'hub-challenge conn))
             (let ((nonce (plist-get (plist-get json :data) :nonce)))
               (if (stringp nonce)
                   ;; the binary's version goes in the first hello too: it waits for the read that runs (R-T17-2); the
                   ;; connection is no longer `wait'ing for a challenge (the probe's answer must not make it `legacy')
                   (progn (process-put conn :drgnx-state 'version)
                          (drgnx-hub--with-binary-version (lambda () (when (process-live-p conn) (drgnx-hub--hello conn nonce)))))
                 (drgnx-hub--reject-hub conn (format "the hub at %s sent a challenge without a nonce" (drgnx-hub-socket)))))))
          (event (when (process-get conn :drgnx-events)
                   (let ((drgnx-hub--event-conn conn))
                     (drgnx-guard-run-hook 'drgnx-hub-event-functions event (plist-get json :data)))))
          ((plist-get json :id)
           (drgnx-hub--settle (plist-get json :id) (plist-get json :result) (plist-get json :error))))))

(defun drgnx-hub--settle (id result error)
  "Call the callback of call ID with RESULT and ERROR (the hub's error object, or this side's message) — once: the
call is forgotten first and its deadline cancelled.  The callback runs in the guard (`drgnx-guard--call'): what it
raises is recorded, and the lines after its answer are still read."
  (when-let* ((entry (gethash id drgnx-hub--pending)))
    (remhash id drgnx-hub--pending)
    (drgnx-timer-cancel (cons 'hub-call id))
    (let ((err (cond ((null error) nil) ((stringp error) (list :message error)) (t error))))
      (drgnx-guard--call (plist-get entry :cb) (format "hub answer %s" (plist-get entry :method))
                         (list (and (not err) result) (and err (if (plist-get entry :full) err (plist-get err :message))))))))

(defun drgnx-hub--call-expired (id)
  "Call ID's deadline passed: its callback gets an error."
  (when-let* ((entry (gethash id drgnx-hub--pending)))
    (drgnx-hub--settle id nil (format "the drgnx hub did not answer %s in time" (plist-get entry :method)))))

(defun drgnx-hub--fail-conn (conn message)
  "Every call waiting on CONN gets MESSAGE as its error (once each)."
  (let (ids)
    (maphash (lambda (id e) (when (eq (plist-get e :conn) conn) (push id ids))) drgnx-hub--pending)
    (process-put conn :drgnx-queue nil)
    (dolist (id (sort ids #'<)) (drgnx-hub--settle id nil message))))

(defun drgnx-hub--client-sentinel (conn _event)
  "A client connection closed: its calls fail; the subscribed one's end is said (`drgnx-hub-disconnect-functions')."
  (unless (process-live-p conn)
    (drgnx-timer-cancel (cons 'hub-challenge conn))
    (drgnx-hub--fail-conn conn "the drgnx hub's connection closed")
    (when (eq drgnx-hub--client conn) (setq drgnx-hub--client nil))
    (when (process-get conn :drgnx-events)
      (when (eq drgnx-hub--events conn) (setq drgnx-hub--events nil))
      (when (eq drgnx-hub--subscribing conn) (setq drgnx-hub--subscribing nil))
      ;; the hub went away (shutdown, a crash, a restart): whoever mirrors it is told
      (drgnx-guard-run-hook 'drgnx-hub-disconnect-functions))))

(defun drgnx-hub--open (events)
  "A new connection to the hub (`drgnx-hub--connect-socket'); EVENTS non-nil: the subscribed connection.  Calls on it
wait in its queue until it is proven or `legacy' (`drgnx-hub--hello'); on a socket this Emacs serves it is proven at
once.  Otherwise a `ping' goes at once: a hub of before protocol 1 answers it, where Ratatoskr's challenge always
comes first, so such a hub is not waited for.  None of the two within `drgnx-hub--challenge-wait' closes the
connection (`drgnx-hub--challenge-late'): only the probe's answer makes a hub `legacy'."
  (let* ((socket (drgnx-hub-socket)) (c (drgnx-hub--connect-socket #'drgnx-hub--client-filter)))
    (process-put c :drgnx-events events)
    (set-process-sentinel c (drgnx-guard-wrap #'drgnx-hub--client-sentinel "hub connection"))
    (if (drgnx-hub--serving-here-p socket)
        (progn (process-put c :drgnx-state 'ready)
               (process-put c :drgnx-proven t))
      (process-put c :drgnx-state 'wait)
      (drgnx-hub-client-binary-version t)       ; read now, never waiting: for this hello and the skew
      (drgnx-timer-start (cons 'hub-challenge c) drgnx-hub--challenge-wait #'drgnx-hub--challenge-late :args (list c) :owner :core)
      (drgnx-hub--call-on c "ping" nil (lambda (_r err) (unless err (drgnx-hub--legacy-now c)))
                          :deadline drgnx-hub--challenge-wait :first t))
    c))

(defun drgnx-hub--challenge-late (conn)
  "`drgnx-hub--challenge-wait' passed with CONN still waiting for its hub's first line.  What already arrived is read
first: an Emacs busy past the wait runs this timer before it reads the challenge waiting in the socket (review S2).
Still nothing: CONN is closed and its calls fail — never taken for `legacy' (a v1 hub would then refuse every user
call on it); the next call connects again."
  (when (and (process-live-p conn) (eq (process-get conn :drgnx-state) 'wait))
    (accept-process-output conn 0 nil t)
    (when (and (process-live-p conn) (eq (process-get conn :drgnx-state) 'wait))
      (drgnx-hub--reject-hub conn (format "the drgnx hub at %s sent nothing within %s s" (drgnx-hub-socket)
                                          drgnx-hub--challenge-wait)))))

(defun drgnx-hub--legacy-now (conn)
  "CONN's hub answered the probe before it sent a challenge: it is `legacy'."
  (when (and (process-live-p conn) (eq (process-get conn :drgnx-state) 'wait))
    (drgnx-timer-cancel (cons 'hub-challenge conn))
    (process-put conn :drgnx-state 'legacy)
    (drgnx-hub--hello-done conn :legacy)))

(defun drgnx-hub--hello (conn hub-nonce)
  "Answer CONN's challenge HUB-NONCE with this Emacs's hello: its protocol, the binary's version (when known), its
schema and records, a fresh nonce and — when `drgnx-hub-client-proves' — the proof that it read the cap file.  The
answer goes to `drgnx-hub--hello-answered'."
  (let* ((nonce (drgnx-hub--nonce))
         (cap (and drgnx-hub-client-proves (drgnx-hub--read-cap)))
         (proof (and (stringp cap) (drgnx-hub-hmac cap (format "drgnx-hub client %s %s" hub-nonce nonce))))
         (version (drgnx-hub-client-binary-version t)))
    (process-put conn :drgnx-state 'hello)
    (drgnx-hub--call-on conn "hello"
                        (append (list :proto drgnx-hub-proto :nonce nonce)
                                (and version (list :drgnx_version version))
                                (list :schema drgnx-work-db-schema-version :records drgnx-hub-records
                                      :client (if noninteractive "cli" "editor"))
                                (and proof (list :proof proof)))
                        (lambda (r err) (drgnx-hub--hello-answered conn hub-nonce nonce cap r err))
                        :full t :first t)))

(defun drgnx-hub--hello-answered (conn hub-nonce nonce cap reply err)
  "The hub's answer to CONN's hello (HUB-NONCE its challenge, NONCE this side's; CAP the cap read, or (:problem
REASON), or nil when `drgnx-hub-client-proves' is nil).  `no method hello' is `legacy'; a hub that should have proved
itself and did not is closed, its calls failed and the user told; otherwise the calls waiting go out."
  (let ((socket (drgnx-hub-socket)))
    (cond
     ((and err (null (plist-get err :code)) (equal (plist-get err :message) "no method hello"))
      (process-put conn :drgnx-state 'legacy)
      (drgnx-hub--hello-done conn :legacy))
     (err (drgnx-hub--reject-hub conn (format "the hub at %s refused this Emacs's hello: %s" socket (plist-get err :message))))
     ((consp cap)
      (drgnx-hub--reject-hub conn (format "this Emacs cannot read the hub's cap %s (%s)" (drgnx-hub-cap-file) (plist-get cap :problem))))
     ((and (stringp cap)
           (not (drgnx-hub--same-p (plist-get reply :proof) (drgnx-hub-hmac cap (format "drgnx-hub hub %s %s" nonce hub-nonce)))))
      (drgnx-hub--reject-hub conn (format "the hub at %s did not prove it read %s" socket (drgnx-hub-cap-file)) 'unproven))
     (t (process-put conn :drgnx-state 'ready)
        (process-put conn :drgnx-proven (stringp cap))
        (drgnx-hub--hello-done conn reply)))))

(defun drgnx-hub--reject-hub (conn message &optional tell)
  "CONN's hub is not used: its calls fail with MESSAGE and it closes.  TELL, a notice id: the user is told too (a
`fail' notice of source `hub')."
  (process-put conn :drgnx-state 'rejected)
  (drgnx-hub--fail-conn conn message)
  (when tell (drgnx-notify 'hub 'fail message :id tell))
  (when (process-live-p conn) (delete-process conn)))

(defun drgnx-hub--hello-done (conn reply)
  "CONN's hello was answered with REPLY (`:legacy' for a hub of before protocol 1): skew is applied
\(`drgnx-hub-skew', `drgnx-hub-skew-functions'), and the calls waiting go out — unless the hub is `incompatible',
when they fail."
  (setq drgnx-hub--last-hello reply)
  (let ((skew (drgnx-hub-skew reply)))
    (drgnx-guard-run-hook 'drgnx-hub-skew-functions skew reply)
    (drgnx-hub--skew-notice skew reply)
    (if (eq skew 'incompatible)
        (drgnx-hub--reject-hub conn (drgnx-hub--incompatible-text reply) (and (not noninteractive) 'incompatible))
      (drgnx-hub--send-queued conn))))

(defun drgnx-hub--skew-notice (skew reply)
  "The notice for a hub of SKEW (`drgnx-hub-skew') that answered with REPLY.  A legacy hub (the Lisp hub of an install
updated while it ran) is offered Hub: Restart Now, in an editor; nothing restarts it unasked.  A hub that is current
takes away the notice that offered a restart (the Ratatoskr one is the hub's own `notice' event,
`drgnx-hub--note-notice')."
  (cond ((and (eq skew 'restart-when-idle) (eq reply :legacy))
         (unless noninteractive
           (drgnx-notify 'hub 'warn "a hub from before this drgnx update runs; restart it to use Ratatoskr (running agent sessions end)"
                         :id 'restart-when-idle :life 'condition :command 'hub-restart-now)))
        ((eq skew 'ok) (drgnx-notice-clear 'hub 'restart-when-idle))))

(defun drgnx-hub--send-queued (conn)
  "Send the calls waiting in CONN's queue, in order — only those still waiting: one whose deadline passed was told it
failed, so it never goes."
  (let ((queue (process-get conn :drgnx-queue)))
    (process-put conn :drgnx-queue nil)
    (dolist (msg queue)
      (when (gethash (plist-get msg :id) drgnx-hub--pending) (drgnx-hub--transmit conn msg)))))

(defun drgnx-hub--transmit (conn msg)
  "Send the call MSG (:id :method :params) on CONN.  Keys go only to a hub that proved itself: on any other
connection `gateway/keys' fails at once and `gateway/register' goes without its `:keys'."
  (let ((proven (process-get conn :drgnx-proven)) (method (plist-get msg :method)))
    (if (and (equal method "gateway/keys") (not proven))
        (drgnx-hub--settle (plist-get msg :id) nil "keys go only to a hub that proved itself")
      (when (and (equal method "gateway/register") (not proven) (consp (plist-get msg :params)))
        (setq msg (list :id (plist-get msg :id) :method method
                        :params (cl-loop for (k v) on (plist-get msg :params) by #'cddr unless (eq k :keys) append (list k v)))))
      (drgnx-hub--send conn msg))))

(cl-defun drgnx-hub--call-on (conn method params callback &key deadline full first)
  "Call METHOD with PARAMS on CONN (`drgnx-hub-call'); FIRST: send it now (the probe, the hello), else once CONN is
proven or `legacy'."
  (let ((id (cl-incf drgnx-hub--next-id)))
    (puthash id (list :cb callback :conn conn :full full :method method) drgnx-hub--pending)
    (drgnx-timer-start (cons 'hub-call id) (or deadline drgnx-hub-call-deadline) #'drgnx-hub--call-expired
                       :args (list id) :owner :core)
    (let ((msg (list :id id :method method :params (or params (make-hash-table)))))
      (cond (first (drgnx-hub--send conn msg))
            ((memq (process-get conn :drgnx-state) '(wait version hello))
             (process-put conn :drgnx-queue (nconc (process-get conn :drgnx-queue) (list msg))))
            (t (drgnx-hub--transmit conn msg))))
    id))

(cl-defun drgnx-hub-call (method params callback &key deadline full)
  "Ask the hub METHOD with PARAMS (a plist); CALLBACK gets (RESULT ERROR) exactly once — ERROR the hub's message (with
FULL its error, (:code :message :path)), or this side's when DEADLINE (`drgnx-hub-call-deadline') seconds pass or
the connection goes first.  A new connection proves itself first (`drgnx-hub--open'); calls wait for that.  Signals
when no hub serves.  The call's id."
  (unless (process-live-p drgnx-hub--client)
    (setq drgnx-hub--client (drgnx-hub--open nil)))
  (drgnx-hub--call-on drgnx-hub--client method params callback :deadline deadline :full full))

(defun drgnx-hub-call-sync (method params &optional timeout)
  "METHOD's result from the hub, waiting up to TIMEOUT (5) s — for commands and the CLI only.  Signals the hub's
error, or when it does not answer."
  (let* ((done nil) result error
         (limit (+ (float-time (time-convert nil t)) (or timeout 5) 1))
         (id (drgnx-hub-call method params (lambda (r e) (setq done t result r error e)) :deadline (or timeout 5))))
    ;; the deadline ends the wait; the real clock is only a backstop (a test's virtual clock never fires the deadline)
    (while (and (not done) (< (float-time (time-convert nil t)) limit)) (accept-process-output nil 0.02))
    (unless done (drgnx-hub--settle id nil "gave up"))
    (cond ((not done) (error "The drgnx hub did not answer %s" method))
          (error (error "drgnx hub: %s" error))
          (t result))))

;;;; The backend's calls to the front

(define-error 'drgnx-hub-front-error "drgnx hub: a call to the front failed")

(defvar drgnx-hub--behind-front nil
  "Non-nil in the Lisp backend behind Ratatoskr (`drgnx-hub-main' with a serve socket): only there does
`drgnx-hub-call-front' wait for the front.")

(defvar drgnx-hub--front-conn nil
  "The Lisp backend's one connection to the front, proven as user class (`drgnx-hub-call-front'); never the
editor's `drgnx-hub--client', never subscribed.")

(defvar drgnx-hub--front-waiting nil
  "Non-nil while a call to the front waits: a second one (from a filter, a sentinel or a handler) is refused.")

(defvar drgnx-hub-front-deadline 10 "Seconds a call to the front may take, by default (`drgnx-hub-call-front').")

(defun drgnx-hub--front-now () "The real clock: a test's virtual one never moves a front call's deadline."
       (float-time (time-convert nil t)))

(defun drgnx-hub--front-fail (message &optional code path)
  "Signal `drgnx-hub-front-error' with (:code CODE :message MESSAGE :path PATH); CODE nil is this side's failure."
  (signal 'drgnx-hub-front-error (list :code code :message message :path path)))

(defun drgnx-hub--front-filter (conn chunk)
  "The front connection CONN's filter: its answers and its challenge go to CONN's inbox, in order.  It never subscribes,
so nothing else should come; any other event is dropped."
  (drgnx-hub--lines conn chunk
                    (lambda (json)
                      (when (or (plist-get json :id) (equal (plist-get json :event) "challenge"))
                        (process-put conn :front-inbox (nconc (process-get conn :front-inbox) (list json)))))))

(defun drgnx-hub--front-take (conn pred deadline)
  "The first line in CONN's inbox that PRED accepts, taken out of it, waiting until DEADLINE (`drgnx-hub--front-now')
for it: nil when none came by then or CONN closed.  It waits with JUST-THIS-ONE an integer: no other process's output
is read and no timer runs meanwhile (src/process.c), so nothing re-enters the backend while it waits."
  (let (found)
    (while (and (not (setq found (cl-find-if pred (process-get conn :front-inbox))))
                (process-live-p conn) (< (drgnx-hub--front-now) deadline))
      (accept-process-output conn 0.05 nil 1))
    (when found (process-put conn :front-inbox (delq found (process-get conn :front-inbox))))
    found))

(defun drgnx-hub--front-exchange (conn method params deadline)
  "Send METHOD with PARAMS on CONN and wait for its answer until DEADLINE: its result, decoded (`drgnx-hub--lines':
objects as plists, arrays as lists, false and null as nil).  The front's error is signalled with its code and path."
  (let ((id (cl-incf drgnx-hub--next-id)))
    (drgnx-hub--send conn (list :id id :method method :params (or params (make-hash-table))))
    (let ((answer (drgnx-hub--front-take conn (lambda (j) (eql (plist-get j :id) id)) deadline)))
      (cond ((and (null answer) (process-live-p conn))
             (drgnx-hub--front-fail (format "the drgnx hub did not answer %s in time" method)))
            ((null answer) (drgnx-hub--front-fail "the drgnx hub's connection closed"))
            ((plist-get answer :error)
             (let ((e (plist-get answer :error)))
               (drgnx-hub--front-fail (or (plist-get e :message) "the drgnx hub refused the call")
                                      (plist-get e :code) (plist-get e :path))))
            (t (plist-get answer :result))))))

(defun drgnx-hub--front-open (deadline)
  "A new connection to the front (`drgnx-hub-socket', never one not private to this user), proven by DEADLINE: the
front's challenge, then a hello with the cap's proof (user class), then the front's proof checked.  Signals
`drgnx-hub-front-error' when it cannot connect or the front does not prove itself; nothing is left open then."
  (let* ((socket (drgnx-hub-socket))
         (why (drgnx-hub--untrusted socket))
         (conn (if why (drgnx-hub--front-fail (format "not connecting to the drgnx hub: %s" why))
                 (condition-case err
                     (make-network-process :name "drgnx-hub-front" :family 'local :service socket :noquery t
                                           :coding 'utf-8-unix :sentinel #'ignore
                                           :filter (drgnx-guard-wrap #'drgnx-hub--front-filter "hub front connection"))
                   (error (drgnx-hub--front-fail (format "cannot connect to the drgnx hub at %s: %s" socket
                                                         (error-message-string err))))))))
    (condition-case err
        (let* ((challenge (drgnx-hub--front-take conn (lambda (j) (equal (plist-get j :event) "challenge")) deadline))
               (hub-nonce (plist-get (plist-get challenge :data) :nonce))
               (cap (drgnx-hub--read-cap))
               (nonce (drgnx-hub--nonce)))
          (unless (stringp hub-nonce) (drgnx-hub--front-fail (format "the drgnx hub at %s sent no challenge" socket)))
          (unless (stringp cap)
            (drgnx-hub--front-fail (format "cannot read the hub's cap %s (%s)" (drgnx-hub-cap-file) (plist-get cap :problem))))
          (let ((reply (drgnx-hub--front-exchange
                        conn "hello" (list :proto drgnx-hub-proto :nonce nonce :schema drgnx-work-db-schema-version
                                           :records drgnx-hub-records :client "backend"
                                           :proof (drgnx-hub-hmac cap (format "drgnx-hub client %s %s" hub-nonce nonce)))
                        deadline)))
            (unless (drgnx-hub--same-p (plist-get reply :proof) (drgnx-hub-hmac cap (format "drgnx-hub hub %s %s" nonce hub-nonce)))
              (drgnx-hub--front-fail (format "the drgnx hub at %s did not prove it read %s" socket (drgnx-hub-cap-file)))))
          conn)
      (error (delete-process conn) (signal (car err) (cdr err))))))

(defun drgnx-hub-call-front (method params &optional deadline)
  "Call METHOD with PARAMS (a plist) on the front and wait for it: the decoded result.  Only the Lisp backend behind
Ratatoskr calls it (`drgnx-hub--behind-front'), for what the front serves (its coordination writes); an editor uses
the asynchronous `drgnx-hub-call'.  On failure it signals `drgnx-hub-front-error' with (:code :message :path) — CODE
the front's, or nil for this side's — once: it never retries.
- One connection, `drgnx-hub--front-conn', proven once (`drgnx-hub--front-open'); it never subscribes, so only answers
  arrive on it, and no key ever goes on it: `gateway/keys' is refused, and so is a `gateway/register' with `:keys'
  (the backend registers its agents with the keys the front holds).
- It waits with (accept-process-output CONN 0.05 nil 1) until the answer or DEADLINE (`drgnx-hub-front-deadline')
  seconds: the integer JUST-THIS-ONE reads no other process's output and runs no timer meanwhile.  The front never
  waits on the backend while it serves such a call (the seam rule), so this cannot deadlock.
- A second call while one waits is refused at once, with nothing sent (it would read the same connection's lines).
- A connection that closed, did not prove itself or passed a deadline is dropped: the next call connects again.
Each call's time is logged."
  (cond ((not drgnx-hub--behind-front)
         (drgnx-hub--front-fail "only the Lisp backend calls the front and waits"))
        (drgnx-hub--front-waiting (drgnx-hub--front-fail "a front call is already waiting"))
        ((member method '("gateway/keys" "subscribe"))
         (drgnx-hub--front-fail (format "the backend's front connection never carries %s" method)))
        ((and (equal method "gateway/register") (plist-get params :keys))
         (drgnx-hub--front-fail "the backend's front connection never carries gateway/register with keys")))
  (let* ((drgnx-hub--front-waiting t)
         (t0 (drgnx-hub--front-now))
         (limit (+ t0 (or deadline drgnx-hub-front-deadline)))
         (ok nil))
    (unwind-protect
        (condition-case err
            (progn
              (unless (process-live-p drgnx-hub--front-conn)
                (setq drgnx-hub--front-conn nil)
                (setq drgnx-hub--front-conn (drgnx-hub--front-open limit)))
              (prog1 (drgnx-hub--front-exchange drgnx-hub--front-conn method params limit) (setq ok t)))
          (drgnx-hub-front-error
           ;; the front's own refusal leaves the connection as it is; anything else drops it
           (unless (plist-get (cdr err) :code)
             (when (process-live-p drgnx-hub--front-conn) (delete-process drgnx-hub--front-conn))
             (setq drgnx-hub--front-conn nil))
           (signal (car err) (cdr err))))
      (message "drgnx hub: front call %s: %d ms%s" method (round (* 1000 (- (drgnx-hub--front-now) t0)))
               (if ok "" " (failed)")))))

;;;; MCP sessions: the socket an agent's bridge connects to

(defun drgnx-hub--mcp-answer (result)
  "RESULT of `mcp/session' as (:sid S :socket P), or an error when the hub's answer lacks either."
  (let ((sid (plist-get result :sid)) (socket (plist-get result :socket)))
    (unless (and (stringp sid) (stringp socket)) (error "The drgnx hub's mcp/session answer is malformed"))
    (list :sid sid :socket socket)))

(cl-defun drgnx-hub-mcp-session (agent &key sid job task cwd callback)
  "Ask the hub for the MCP socket of AGENT's session (`mcp/session'): (:sid S :socket P).  The socket is the agent's
identity; the owner is this Emacs, so the hub closes the session when this Emacs dies.  SID: the session's id when its
agent socket made the directory already; JOB, TASK, CWD as the session has them.
- In the Lisp backend behind Ratatoskr it calls the front (`drgnx-hub-call-front') and waits.
- In an editor, from a command, it waits at most 2 s (`drgnx-hub-call-sync').
- In a daemon path (`inhibit-interaction') it never waits: it asks with `drgnx-hub-call' and returns nil, and
  CALLBACK is called later with (ANSWER ERROR) — ANSWER the plist above, or nil with ERROR a message.
Signals \"Ratatoskr is not built: run `drgnx runtime build'\" when there is no binary."
  (unless (drgnx-hub-client-binary) (error "Ratatoskr is not built: run `drgnx runtime build'"))
  (let ((params (append (list :agent agent)
                        (and sid (list :sid sid)) (and job (list :job job)) (and task (list :task task))
                        (and cwd (list :cwd (expand-file-name cwd)))
                        (list :owner (emacs-pid)))))
    (cond (drgnx-hub--behind-front
           (drgnx-hub--mcp-answer (drgnx-hub-call-front "mcp/session" params)))
          (inhibit-interaction
           (unless callback (error "A daemon path asks for an MCP session with a callback"))
           (drgnx-hub-call "mcp/session" params
                           (lambda (result err)
                             (funcall callback
                                      (and (not err) (condition-case nil (drgnx-hub--mcp-answer result) (error nil)))
                                      (or err (and (null result) "no answer")))))
           nil)
          (t (drgnx-hub--mcp-answer (drgnx-hub-call-sync "mcp/session" params 2))))))

(defun drgnx-hub-mcp-session-close (sid)
  "Tell the hub session SID's agent is gone (`mcp/session-close'); never waits and never signals: the hub also
closes it when this Emacs dies."
  (ignore-errors
    (if drgnx-hub--behind-front
        (drgnx-hub-call-front "mcp/session-close" (list :sid sid))
      (drgnx-hub-call "mcp/session-close" (list :sid sid) #'ignore))))

(defun drgnx-hub-disconnect ()
  "Close this Emacs's connections to the hub; the calls waiting on them fail (once)."
  (dolist (c (list drgnx-hub--client drgnx-hub--events drgnx-hub--subscribing))
    (when (processp c)
      (drgnx-timer-cancel (cons 'hub-challenge c))
      (drgnx-hub--fail-conn c "disconnected from the drgnx hub"))
    (when (process-live-p c) (delete-process c)))
  (setq drgnx-hub--client nil drgnx-hub--events nil drgnx-hub--subscribing nil)
  (remove-hook 'drgnx-hub-event-functions #'drgnx-hub--note-notice)
  (remove-hook 'drgnx-hub-event-functions #'drgnx-hub--need-keys)
  (remove-hook 'drgnx-hub-event-functions #'drgnx-hub--keys-changed)
  (setq drgnx-hub--editor nil drgnx-hub--keys-held :unknown)
  (let (ids)
    (maphash (lambda (id _) (push id ids)) drgnx-hub--pending)
    (dolist (id ids) (drgnx-hub--settle id nil "disconnected from the drgnx hub"))))

;;;; Skew: another drgnx's hub

(defun drgnx-hub-skew (reply)
  "What to do about the hub that answered this Emacs's hello with REPLY: `incompatible' (its protocol is older than
`drgnx-hub-proto-min', or this drgnx's older than its `proto_min'); `restart-when-idle' (a legacy hub, `:legacy';
another `records'; a `drgnx_version' other than the binary on disk's, when that is known; a `schema' other than
`drgnx-work-db-schema-version', 0 — no work.db yet — counting as the same); else `ok'."
  (cond ((eq reply :legacy) 'restart-when-idle)
        ((let ((proto (plist-get reply :proto)) (min (plist-get reply :proto_min)))
           (or (not (natnump proto)) (< proto drgnx-hub-proto-min) (and (natnump min) (< drgnx-hub-proto min))))
         'incompatible)
        ((or (not (eql (plist-get reply :records) drgnx-hub-records))
             (let ((v (drgnx-hub-client-binary-version t))) (and v (not (equal (plist-get reply :drgnx_version) v))))
             (let ((s (plist-get reply :schema))) (and (natnump s) (/= s 0) (/= s drgnx-work-db-schema-version))))
         'restart-when-idle)
        (t 'ok)))

(defun drgnx-hub--incompatible-text (reply)
  "What the user is told about an incompatible hub (REPLY its hello's answer)."
  (if (and (natnump (plist-get reply :proto_min)) (< drgnx-hub-proto (plist-get reply :proto_min)))
      (format "the hub is drgnx %s (protocol %s, at least %s); this drgnx speaks protocol %d — update drgnx"
              (plist-get reply :drgnx_version) (plist-get reply :proto) (plist-get reply :proto_min) drgnx-hub-proto)
    (format "the hub is drgnx %s (protocol %s); this drgnx needs protocol %d or later — drgnx hub stop, then try again"
            (plist-get reply :drgnx_version) (plist-get reply :proto) drgnx-hub-proto-min)))

(defun drgnx-hub-has-method-p (name)
  "Whether the last hub that answered this Emacs's hello has method NAME (nil for a legacy hub)."
  (and (consp drgnx-hub--last-hello) (member name (plist-get drgnx-hub--last-hello :methods)) t))

(defun drgnx-hub-running-p ()
  "Does a hub serve this data dir?"
  (drgnx-hub--ping-socket (drgnx-hub-socket)))

(defun drgnx-hub--held-keys ()
  "The provider keys this Emacs holds now, asking no one: a provider's environment variable, else a key a command the
user ran found and the hub has not taken yet (`drgnx-ai--keys').  (:PROVIDER KEY…).  An empty key is no key: it
would replace a good one in the hub."
  (require 'drgnx-ai)                   ; the provider list: not needed to load the client, only to hand keys over
  (cl-loop for (id . p) in (drgnx-ai-providers)
           for env = (plist-get p :key-env)
           for key = (and env (let ((v (getenv env))) (if (and v (not (string-empty-p v))) v (gethash id drgnx-ai--keys))))
           when (and (stringp key) (not (string-empty-p key))) append (list (intern (concat ":" (symbol-name id))) key)))

(defun drgnx-hub--send-keys ()
  "Hand the hub the keys this Emacs holds (`drgnx-hub--held-keys'), over the socket: never in an environment, an
argument or a file, and only to a hub that proved itself (`drgnx-hub--transmit').  Once the hub took them this Emacs
drops them (`drgnx-hub--keys-taken'): the hub alone holds them, in memory, and those in the environment go again on
each start and each (re)connect.  The call's id."
  (when-let* ((keys (drgnx-hub--held-keys)))
    (drgnx-hub-call "gateway/keys" (list :keys keys) (lambda (_result err) (drgnx-hub--keys-taken keys err)))))

(defun drgnx-hub--keys-taken (keys err)
  "The hub answered a `gateway/keys' that carried KEYS: without ERR it took them, and this Emacs drops them
\(`drgnx-hub--drop-keys').  A refusal, a deadline or a closed connection keeps them for the next hand-over."
  (unless err (drgnx-hub--drop-keys keys)))

(declare-function drgnx-ai-forget-keys "drgnx-ai")

(defun drgnx-hub--drop-keys (keys)
  "The hub took KEYS (:PROVIDER KEY…) over a connection that proved itself (`gateway/keys', or `gateway/register'
with them, answered): this Emacs keeps none of them (`drgnx-ai-forget-keys').  Not in an Emacs that serves the hub
itself (the standalone Lisp hub): there the key table is the hub's own."
  (unless (process-live-p (bound-and-true-p drgnx-hub--server))
    (require 'drgnx-ai)
    (drgnx-ai-forget-keys keys)))

(defun drgnx-hub-hand-over-keys ()
  "Hand the hub the keys this Emacs holds now, without waiting (AI: Load Keys): to the hub this Emacs is subscribed to
when it proved itself (`drgnx-hub--send-keys'); else the hub is found or started and connected to, and the hand-over
that follows takes them.  Signals when no hub can be had (Ratatoskr not built, starting it off here)."
  (if (and (process-live-p drgnx-hub--events) (process-get drgnx-hub--events :drgnx-proven))
      (drgnx-hub--send-keys)
    (unless (process-live-p drgnx-hub--subscribing)
      (drgnx-hub--ensure-running #'drgnx-hub--ensured)
      (drgnx-hub-connect))))

;;;; The provider table, and keys the hub asks for again

(defconst drgnx-hub--provider-kinds '(openai ollama llamacpp tei anthropic) "The provider kinds `config/providers' takes.")

(defun drgnx-hub--provider-json (id p)
  "Provider ID (its entry P) as `config/providers' takes it — (:id :kind :base :auth :messages :caps [:price]), never
a key — or nil when it cannot be one (no URL, a kind the hub does not know).  AUTH is \"none\" without a `:key-env',
\"x-api-key\" for `:auth x-api-key', else \"bearer\"; CAPS are the known ones of `:caps'; PRICE from `:price' (IN . OUT)."
  (let ((kind (plist-get p :kind)) (url (plist-get p :url)) (price (plist-get p :price)))
    (when (and (memq kind drgnx-hub--provider-kinds) (stringp url))
      (append (list :id (symbol-name id) :kind (symbol-name kind) :base url
                    :auth (cond ((not (plist-get p :key-env)) "none") ((eq (plist-get p :auth) 'x-api-key) "x-api-key") (t "bearer"))
                    :messages (if (plist-get p :messages) t :false)
                    :caps (vconcat (mapcar #'symbol-name (cl-remove-if-not (lambda (c) (memq c '(chat fim embed)))
                                                                           (delete-dups (copy-sequence (plist-get p :caps)))))))
              (and (consp price) (numberp (car price)) (numberp (cdr price))
                   (list :price (list :input (car price) :output (cdr price))))))))

(defun drgnx-hub--providers-table ()
  "The provider table the hub gets: the effective one, the presets and the user's ai.eld as `drgnx-ai-providers'
resolves them, each as `drgnx-hub--provider-json' has it."
  (require 'drgnx-ai)
  (vconcat (delq nil (mapcar (lambda (e) (drgnx-hub--provider-json (car e) (cdr e))) (drgnx-ai-providers)))))

(defvar drgnx-hub--clear-text-told nil
  "The providers (ids, strings) whose clear-text warning this Emacs has shown: each once per Emacs session.")

(defun drgnx-hub--providers-applied (result _err)
  "The hub's answer to `config/providers': each of its `warnings' (a provider whose key would travel in clear text, at
an http:// address off this machine) becomes a notice, once per provider per Emacs session."
  (when (consp result)
    (dolist (w (plist-get result :warnings))
      (let ((provider (plist-get w :provider)) (text (plist-get w :text)))
        (when (and (stringp provider) (stringp text) (not (member provider drgnx-hub--clear-text-told)))
          (push provider drgnx-hub--clear-text-told)
          (drgnx-notify 'hub 'warn text :id (intern (concat "clear-text-" provider))))))))

(defun drgnx-hub--send-providers ()
  "Hand the hub the provider table (`drgnx-hub--providers-table'): which providers the gateway may route to, their kinds
and what they take.  It carries no key.  Sent on every proven connection, beside the keys, and when ai.eld changes
\(`drgnx-hub-resend-providers').  The call's id."
  (drgnx-hub-call "config/providers" (list :providers (drgnx-hub--providers-table)) #'drgnx-hub--providers-applied))

(defun drgnx-hub-resend-providers ()
  "ai.eld changed (`drgnx-config-changed-functions', from drgnx-ai.el): an editor subscribed to a hub that proved
itself sends the provider table again.  Anywhere else nothing: the next connection sends it."
  (when (and (not drgnx-hub--behind-front) (process-live-p drgnx-hub--events) (process-get drgnx-hub--events :drgnx-proven))
    (drgnx-hub--send-providers)))

(defun drgnx-hub--need-keys (event data)
  "`gateway/need-keys' (DATA (:providers [ID…])): agents need the keys of these providers and the hub holds none (it
restarted; keys live in its memory only).  Only for a hub that proved itself (`:drgnx-proven' of the connection the
event came on).  Each key is looked for again, in the provider's environment variable — never in a copy kept here
\(`drgnx-ai--keys' is not consulted) — and the ones found go with `gateway/keys' and are kept nowhere.  This runs in a
process filter, a daemon path: auth-source is never read and nothing asks (design §5.6); a key not found is a notice
saying how to load it."
  (when (and (equal event "gateway/need-keys") (processp drgnx-hub--event-conn)
             (process-get drgnx-hub--event-conn :drgnx-proven))
    (require 'drgnx-ai)
    (let ((providers (drgnx-ai-providers)) keys missing)
      (dolist (name (plist-get data :providers))
        (when (stringp name)
          (let* ((p (cdr (cl-find-if (lambda (e) (equal (symbol-name (car e)) name)) providers)))
                 (env (plist-get p :key-env))
                 (key (and env (getenv env))))
            (if (and key (not (string-empty-p key)))
                (setq keys (append keys (list (intern (concat ":" name)) key)))
              (push name missing)))))
      (when keys (drgnx-hub-call "gateway/keys" (list :keys keys) #'ignore))
      (dolist (name (nreverse missing))
        (drgnx-notify 'hub 'warn (format "agents need your %s key in the drgnx hub: run AI: Load Keys" name)
                      :id (intern (concat "need-key-" name)) :command 'drgnx-ai-load-keys)))))

;;;; The editor's token, and which keys the hub holds (the editor's AI goes through the gateway)

(defvar drgnx-hub--editor nil
  "The gateway's answer to this Emacs's `gateway/editor-token': (TOKEN . URL), or nil before it came.  The token is a
secret of this process: kept in memory only, fetched again on every proven (re)connect.")

(defvar drgnx-hub--keys-held :unknown
  "The ids (strings) of the providers whose key the hub holds, as `gateway/keys-held' and `gateway/keys-changed'
said, or `:unknown' before the hub answered.  Never a key.")

(defvar drgnx-hub-editor-token-hook nil
  "Functions of no arguments run (inside the guard) when the hub gave this Emacs its editor token: what needed the
gateway's address (gptel's backend) can be set up.")

(defun drgnx-hub--editor-answered (result _err)
  "The answer to `gateway/editor-token': RESULT (:token :url)."
  (when (and (consp result) (stringp (plist-get result :token)) (stringp (plist-get result :url)))
    (setq drgnx-hub--editor (cons (plist-get result :token) (plist-get result :url)))
    (drgnx-guard-run-hook 'drgnx-hub-editor-token-hook)))

(defun drgnx-hub--keys-held-answered (result _err)
  "The answer to `gateway/keys-held': RESULT (:providers [ID…])."
  (when (consp result)
    (setq drgnx-hub--keys-held (seq-filter #'stringp (append (plist-get result :providers) nil)))))

(defun drgnx-hub--fetch-editor ()
  "Ask the hub for this Emacs's editor token and for the keys it holds: the ids of the two calls."
  (list (drgnx-hub-call "gateway/editor-token" nil #'drgnx-hub--editor-answered)
        (drgnx-hub-call "gateway/keys-held" nil #'drgnx-hub--keys-held-answered)))

(defun drgnx-hub--keys-changed (event data)
  "`gateway/keys-changed' (DATA (:providers [ID…])) from a hub that proved itself: the keys it holds now."
  (when (and (equal event "gateway/keys-changed") (processp drgnx-hub--event-conn)
             (process-get drgnx-hub--event-conn :drgnx-proven))
    (setq drgnx-hub--keys-held (seq-filter #'stringp (append (plist-get data :providers) nil)))))

(defun drgnx-hub-keys-held ()
  "The ids (strings) of the providers whose key the hub holds, or `:unknown' when the hub has not said yet."
  drgnx-hub--keys-held)

(defun drgnx-hub-editor-token (&optional wait)
  "(TOKEN . URL) for this Emacs's requests to the gateway, or nil when the hub has not given one yet.  Then the hub's
start is asked for, without waiting, and the token arrives with the hand-over.  WAIT (a command, or a batch process;
never in a daemon path, `inhibit-interaction'): make sure the hub runs and wait for it (`drgnx-hub-ensure'), signalling
why it cannot."
  (or drgnx-hub--editor
      (progn
        (if (and wait (not inhibit-interaction))
            (drgnx-hub-ensure)
          ;; asked once: a subscription under way hands the token over when the hub answers
          (unless (or (process-live-p drgnx-hub--events) (process-live-p drgnx-hub--subscribing))
            (ignore-errors
              (drgnx-hub--ensure-running #'drgnx-hub--ensured)
              (drgnx-hub-connect))))
        drgnx-hub--editor)))

(defun drgnx-hub-give-key (id key)
  "Hand the hub provider ID's KEY over the socket and wait for it (a command the user ran: a key found in a store that
asks); the hub's list of held keys then includes ID.  The key is kept nowhere here: once the hub took it this Emacs
drops it (`drgnx-hub--drop-keys')."
  (let ((keys (list (intern (concat ":" (symbol-name id))) key)))
    (drgnx-hub-call-sync "gateway/keys" (list :keys keys))
    (drgnx-hub--drop-keys keys))
  (unless (eq drgnx-hub--keys-held :unknown)
    (cl-pushnew (symbol-name id) drgnx-hub--keys-held :test #'equal)))

(defun drgnx-hub--hand-over ()
  "Hand the hub the provider table (`drgnx-hub--send-providers') and the keys this Emacs holds
\(`drgnx-hub--send-keys'), and ask it for the editor token and the keys it holds (`drgnx-hub--fetch-editor'): the ids
of the calls made."
  (delq nil (append (list (drgnx-hub--send-providers) (drgnx-hub--send-keys)) (drgnx-hub--fetch-editor))))

(defun drgnx-hub--wait-for-keys ()
  "Hand the hub the provider table and the keys this Emacs holds (`drgnx-hub--hand-over') and wait (up to 5 s) for it
to take them: a CLI that exits at once would take them with it."
  (let ((ids (drgnx-hub--hand-over)) (limit (+ (float-time (time-convert nil t)) 5)))
    (while (and (cl-some (lambda (id) (gethash id drgnx-hub--pending)) ids) (< (float-time (time-convert nil t)) limit))
      (accept-process-output nil 0.02))))

(defun drgnx-hub--ensured (err)
  "A hub started in a daemon path is up (ERR nil): it gets the provider table and the keys this Emacs holds.  Otherwise
\(ERR the reason) the user is told."
  (if err
      (drgnx-notify 'hub 'fail err :id 'start)
    (with-demoted-errors "drgnx hub: keys not handed over: %S" (drgnx-hub--hand-over))))

(defun drgnx-hub-ensure ()
  "Make sure the hub runs, starting Ratatoskr (one `ratatoskr ensure') if not, and hand it the provider table and the
keys this Emacs holds (`drgnx-hub--hand-over').
t, or an error saying why not.  For commands and the CLI, which wait for it (`drgnx-hub-ensure-deadline' at most).  In a
daemon path (`inhibit-interaction') it never waits: it returns t only when a hub answered already, and the keys go,
or the user is told, when the start ends."
  (if inhibit-interaction
      (null (drgnx-hub--ensure-running #'drgnx-hub--ensured))
    (let ((state 'waiting) (limit (+ (float-time) drgnx-hub-ensure-deadline 2)))
      (drgnx-hub--ensure-running (lambda (err) (setq state (or err t))))
      (while (and (eq state 'waiting) (< (float-time) limit)) (accept-process-output nil 0.05))
      (unless (eq state t) (error "%s" (if (stringp state) state "ratatoskr ensure did not finish")))
      (drgnx-hub--wait-for-keys)
      t)))

(defun drgnx-hub--ensure-done (p)
  "The `ratatoskr ensure' process P ended, or ran past its deadline: whoever waits for it hears how it went."
  (when (eq drgnx-hub--ensuring p)
    (setq drgnx-hub--ensuring nil)
    (drgnx-timer-cancel 'hub-ensure)
    (let* ((out (if (buffer-live-p (process-buffer p)) (with-current-buffer (process-buffer p) (string-trim (buffer-string))) ""))
           (err (cond ((process-get p :expired)
                       (format "ratatoskr ensure did not finish in %d s (see `drgnx hub status')" drgnx-hub-ensure-deadline))
                      ((and (eq (process-status p) 'exit) (eql (process-exit-status p) 0)) nil)
                      (t (format "Ratatoskr did not start: %s" (if (string-empty-p out) "ratatoskr ensure failed" out)))))
           (callbacks (reverse (process-get p :callbacks))))
      (when (buffer-live-p (process-buffer p)) (kill-buffer (process-buffer p)))
      (dolist (f callbacks) (drgnx-guard--call f "hub start" (list err))))))

(defun drgnx-hub--ensure-sentinel (p _event)
  (unless (process-live-p p) (drgnx-hub--ensure-done p)))

(defun drgnx-hub--ensure-expired ()
  "`ratatoskr ensure' ran past `drgnx-hub-ensure-deadline': it is ended and counted as failed."
  (when-let* ((p drgnx-hub--ensuring))
    (process-put p :expired t)
    (when (process-live-p p) (delete-process p))
    (drgnx-hub--ensure-done p)))

(defun drgnx-hub--ensure-running (callback)
  "Make sure a hub runs, without waiting: CALLBACK is called with nil once one answers (at once when one does already)
or with the reason it does not, when the one asynchronous `ratatoskr ensure --timeout 5' ends or passes
`drgnx-hub-ensure-deadline'.  Returns that process (nil when a hub ran already).  Signals when it cannot start one:
Ratatoskr is not built, or starting is off (DRGNX_NO_HUB_START)."
  (require 'drgnx-ai)
  (cond ((drgnx-hub-running-p) (funcall callback nil) nil)
        ((getenv "DRGNX_NO_HUB_START")
         (error "No drgnx hub runs, and starting one is off here (DRGNX_NO_HUB_START)"))
        ((process-live-p drgnx-hub--ensuring)
         (process-put drgnx-hub--ensuring :callbacks (cons callback (process-get drgnx-hub--ensuring :callbacks)))
         drgnx-hub--ensuring)
        (t
         (let* ((bin (or (drgnx-hub-client-binary) (error "Ratatoskr is not built: run `drgnx runtime build'")))
                ;; its Emacs and checkout are this one's; no key through inheritance either (names without a value unset)
                (process-environment (append (list (concat "DRGNX_EMACS=" (drgnx-emacs-program))
                                                   (concat "DRGNX_DIR=" (directory-file-name drgnx-dir)))
                                             (delq nil (mapcar (lambda (p) (plist-get (cdr p) :key-env)) (drgnx-ai-providers)))
                                             process-environment))
                (p (make-process :name "ratatoskr-ensure" :buffer (generate-new-buffer " *ratatoskr ensure*" t) :noquery t
                                 :connection-type 'pipe :command (list bin "ensure" "--timeout" "5")
                                 :sentinel (drgnx-guard-wrap #'drgnx-hub--ensure-sentinel "ratatoskr ensure"))))
           (process-put p :callbacks (list callback))
           (setq drgnx-hub--ensuring p)
           (drgnx-timer-start 'hub-ensure drgnx-hub-ensure-deadline #'drgnx-hub--ensure-expired :owner :core)
           p))))

(defun drgnx-hub--restart-legacy ()
  "End the Lisp hub of before this update (protocol 0 has `shutdown', not `restart'), wait up to 5 s for its lock directory
to go, then start Ratatoskr."
  (let ((lock (concat (drgnx-hub-socket) ".lock")) (limit (+ (float-time) 5)))
    (ignore-errors (drgnx-hub-call-sync "shutdown" nil 5))
    (while (and (file-exists-p lock) (< (float-time) limit)) (accept-process-output nil 0.05))
    (drgnx-hub--ensure-running #'drgnx-hub--ensured)))

(defun drgnx-hub-restart-now ()
  "Restart the hub now (Hub: Restart Now): the agent sessions it runs end.  Asks no one: the user chose it, from the
update notice or the palette.  Ratatoskr is asked to `restart' (its supervisor starts it again); a hub from before
Ratatoskr is shut down and Ratatoskr started in its place; no hub at all is started."
  (interactive)
  (if (not (drgnx-hub-running-p))
      (drgnx-hub--ensure-running #'drgnx-hub--ensured)
    (drgnx-hub-call-sync "ping" nil 5)            ; the connection's hello says which hub it is
    (if (eq (process-get drgnx-hub--client :drgnx-state) 'legacy)
        (drgnx-hub--restart-legacy)
      (drgnx-hub-call-sync "restart" nil 5))))

(defun drgnx-hub-connect ()
  "Subscribe to the hub's events (`drgnx-hub-event-functions') and, once the hub answered, hand it the provider table and
the keys this Emacs holds (`drgnx-hub--hand-over'); answer its `gateway/need-keys' (`drgnx-hub--need-keys').
Asynchronous; safe to call again, also before the hub has answered (one subscription)."
  ;; a subscribe left unanswered past the deadline (a hub stopped, or one that lost the line) is given up quietly
  (when (and (process-live-p drgnx-hub--subscribing)
             (> (- (float-time) (process-get drgnx-hub--subscribing :since)) drgnx-hub-subscribe-deadline))
    (let ((c drgnx-hub--subscribing))
      (setq drgnx-hub--subscribing nil)
      (set-process-sentinel c #'ignore)
      (drgnx-timer-cancel (cons 'hub-challenge c))
      (drgnx-hub--fail-conn c "the drgnx hub did not answer subscribe")
      (when (process-live-p c) (delete-process c))))
  (unless (or (process-live-p drgnx-hub--events) (process-live-p drgnx-hub--subscribing))
    ;; a connection of its own, which proves itself first (`drgnx-hub--open'); its end is said by its sentinel
    (let ((c (drgnx-hub--open t)))
      (setq drgnx-hub--subscribing c)
      (process-put c :since (float-time))
      (drgnx-hub--call-on c "subscribe" nil (lambda (r _err) (drgnx-hub--subscribed c r)))
      ;; both removed by `drgnx-hub-disconnect'
      (add-hook 'drgnx-hub-event-functions #'drgnx-hub--note-notice)
      (add-hook 'drgnx-hub-event-functions #'drgnx-hub--need-keys)
      (add-hook 'drgnx-hub-event-functions #'drgnx-hub--keys-changed))))

(defun drgnx-hub--subscribed (conn result)
  "The hub answered CONN's `subscribe' with RESULT: CONN is the subscribed connection, and the hub gets the provider
table and the keys.  A hub keeps keys in memory only: one that restarted has none, so each new subscription gives them
again.  They go after the answer, so a `gateway/need-keys' the hub sends a new subscriber is about the keys it held
before them."
  (when (and result (process-live-p conn))
    (setq drgnx-hub--events conn)
    (when (eq drgnx-hub--subscribing conn) (setq drgnx-hub--subscribing nil))
    (with-demoted-errors "drgnx hub: keys not handed over: %S" (drgnx-hub--hand-over))))

(defun drgnx-hub--note-notice (event data)
  "In an editor: a `notice' the hub sent (it is not the version on disk any more) becomes a notice of source `hub', with
the command it names (Hub: Restart Now).  A condition: the hub, or the next hello from a current one, takes it away."
  (when (equal event "notice")
    (let ((id (plist-get data :id)) (text (plist-get data :text)) (severity (plist-get data :severity))
          (command (plist-get data :command)))
      (when (and (stringp id) (stringp text) (member severity '("info" "warn" "fail")))
        (drgnx-notify 'hub (intern severity) text :id (intern id)
                      :life (if (equal (plist-get data :life) "condition") 'condition 'event)
                      :command (and (stringp command) (intern command)))))))

(provide 'drgnx-hub-client)
;;; drgnx-hub-client.el ends here
