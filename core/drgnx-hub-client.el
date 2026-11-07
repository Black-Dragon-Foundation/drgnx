;;; drgnx-hub-client.el --- The hub's socket client: what the editor and the CLI load -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The client of the hub (Ratatoskr serves): where the hub's socket is and whether it can be trusted, the
;; line protocol (one JSON object per line), protocol v1 (the hub's challenge, `hello' with the proofs both ways, the
;; skew rules), requests with deadlines and their answers, the event subscription, starting the hub (`ratatoskr ensure'),
;; and `drgnx hub start|stop|status'.  The hub is the Rust binary: nothing of its runtime is in Emacs, and an editor
;; that talks to the hub requires this file.  The write queue (`drgnx-hub--enqueue', `drgnx-hub--drain') is here too.
;; See docs/develop/hub.md, "The client".

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'drgnx-paths)
(require 'drgnx-guard)
(require 'drgnx-timer)
(require 'drgnx-file)
(require 'drgnx-notice)
(require 'drgnx-agents-matrix)          ; `drgnx-agents-away-after'
(require 'drgnx-work-db)                ; `drgnx-work-db-schema-version', which the hello says
(require 'drgnx-hub-core)               ; every ordering decision of the connections and the subscription

(declare-function drgnx-exec-sync "drgnx-exec")
(declare-function drgnx-exec-unsync "drgnx-exec")
(declare-function drgnx-settings-agents--event "drgnx-settings-agents")
(declare-function drgnx-records-review--event "drgnx-records-review")
(declare-function drgnx-history-revert--event "drgnx-history-revert")
(declare-function drgnx-say-event "drgnx-say")
(declare-function drgnx-ai-providers "drgnx-ai")
(declare-function drgnx-settings-runtime-send "drgnx-settings-runtime")
(declare-function drgnx-ai-provider "drgnx-ai")
(declare-function drgnx-ai-key "drgnx-ai")
(declare-function drgnx-commands-get "drgnx-registry" (id))
(defvar drgnx-hub--editor)              ; the editor token and the held keys: defined below, used by `drgnx-hub-disconnect'
(defvar drgnx-hub--keys-held)

(defvar drgnx-hub-event-functions nil
  "Functions called with (EVENT DATA) for each event the hub sends this Emacs (after `drgnx-hub-connect'); EVENT a
string (\"request\", \"fallback\", \"budget\"), DATA a plist.  Each runs inside the guard (`drgnx-guard-run-hook'):
one that fails or asks is recorded as a notice, and the next still runs.")

(defvar drgnx-hub-disconnect-functions nil
  "Called when this Emacs's event connection to the hub closes (the hub ended, or `drgnx-hub-disconnect'); each
inside the guard, as `drgnx-hub-event-functions'.")

(defvar drgnx-hub-connected-functions nil
  "Called, with no arguments, each time this Emacs's subscription to a hub that proved itself is up (the first time,
and again after a hub restart); each inside the guard, as `drgnx-hub-event-functions'.  For what the hub keeps in memory
only and must be told again, such as the login shell's variables.")

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

;; `drgnx-hub-proto', `drgnx-hub-proto-min', `drgnx-hub-records' and `drgnx-hub-schema-readable-max' are in
;; drgnx-hub-core.el: the skew is decided there.

(defcustom drgnx-hub-call-deadline 30
  "Seconds a call to the hub may go unanswered: then its callback gets an error (`drgnx-hub-call')."
  :type 'number :group 'drgnx)

(defconst drgnx-hub--challenge-wait 2
  "Seconds a new connection waits for the hub's challenge: a hub that sends none by then is of before protocol 1.")

(defvar drgnx-hub-client-proves t
  "Non-nil: this Emacs's hello proves it read the hub's cap file, which makes its connections user class.  nil: the
hello carries no proof and the cap is never read, so the connections stay service class.  A client an agent
started binds it to nil: it must never become user class by reading the cap.")

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
                          ;; binary in, UTF-8 out: Nidhogg's `lines' framing needs a decoding without state; the
                          ;; filter's `drgnx-hub--lines' parses UTF-8 bytes as well as characters
                          :coding '(binary . utf-8-unix) :filter (drgnx-guard-wrap filter "hub connection"))))

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
  "The read P ended (or ran too long): the functions waiting for its answer
\(`drgnx-hub--with-binary-version') run once."
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

(defun drgnx-hub--client-filter (conn chunk)
  "A client connection's filter: the challenge starts the hello, an answer settles its call, an event (on the
subscribed connection) goes to `drgnx-hub-event-functions'."
  (drgnx-hub--lines conn chunk (lambda (json) (drgnx-hub--client-line conn json))))

(defvar nidhogg-workers-framing)
(declare-function nidhogg-set-process-framing "nidhogg-io.c")

(defun drgnx-hub--frame (conn)
  "Have Nidhogg's reader thread split CONN's input into lines and parse them, when `nidhogg-workers-framing' is on:
the main thread then gets batches (`drgnx-hub--client-batch') where it gets chunks (`drgnx-hub--client-filter').
Without the feature or the switch, or on an error from the framing, the filter reads, as it always did.  No
`:max-message': the client has no line limit.  A connection whose filter is replaced (the delivery gate's, in tests)
is unframed again by the reader itself."
  (when (and (fboundp 'nidhogg-set-process-framing) (bound-and-true-p nidhogg-workers-framing))
    (condition-case nil
        (nidhogg-set-process-framing conn 'lines :parse 'string :object-type 'plist :array-type 'list
                                     :null-object nil :false-object nil
                                     :batch-function (drgnx-guard-wrap #'drgnx-hub--client-batch "hub connection"))
      (error nil))))

(defun drgnx-hub--client-batch (conn batch)
  "The framed counterpart of `drgnx-hub--lines' with `drgnx-hub--client-line': BATCH is a list of (MESSAGE RAW ERROR)
from CONN's reader, in the order the hub wrote them.  One whose line is not JSON (ERROR), or is JSON `null' or
`false' (no MESSAGE), is skipped as `drgnx-hub--lines' skips it.  Nothing is read once CONN, live when the batch
began, is not any more (nothing after `closed').  Each message runs in a guard of its own: one that fails never drops
the rest of the batch.  A last line with no newline before the end of the stream is a message here, where the filter
drops it."
  (let ((live (process-live-p conn)) (one (drgnx-guard-wrap #'drgnx-hub--client-line "hub connection")))
    (dolist (entry batch)
      (when (or (not live) (process-live-p conn))
        (let ((message (nth 0 entry)))
          (when (and message (null (nth 2 entry)))
            (funcall one conn message)))))))

(defconst drgnx-hub--conn-props
  '((:state . :drgnx-state) (:queue . :drgnx-queue) (:proven . :drgnx-proven) (:asked . :drgnx-asked)
    (:events . :drgnx-events) (:since . :since))
  "The core's connection fields and the process properties that keep them between steps.")

(defun drgnx-hub--client-line (conn json)
  "One line JSON read on CONN, as the core's event: the challenge, an event, or an answer."
  (let ((event (plist-get json :event)))
    (cond ((equal event "challenge")
           (drgnx-hub--step (list 'challenge conn (plist-get (plist-get json :data) :nonce) (drgnx-hub-socket))))
          (event (drgnx-hub--step-event conn event (plist-get json :data)))
          ((plist-get json :id)
           (drgnx-hub--step (list 'answer conn (plist-get json :id) (plist-get json :result) (plist-get json :error)))))))

(defun drgnx-hub--step-event (conn name data)
  "The hub's event NAME with DATA, read on CONN, through the core with only CONN's subscription mark as its state:
an event changes nothing in the client, so no snapshot of the globals or the connections is taken."
  (let ((state (drgnx-hub-core-make
                :conns (list (list conn :events (process-get conn (alist-get :events drgnx-hub--conn-props)))))))
    (dolist (e (cdr (drgnx-hub-core-step state (list 'event conn name data)))) (drgnx-hub--effect e))))

(defun drgnx-hub--settle (id result error)
  "Call the callback of call ID with RESULT and ERROR (the hub's error object, or this side's message) — once: the
call is forgotten first and its deadline cancelled.  The callback runs in the guard (`drgnx-guard--call'): what it
raises is recorded, and the lines after its answer are still read."
  (drgnx-hub--step (list 'answer nil id result error)))

(defun drgnx-hub--call-expired (id)
  "Call ID's deadline passed: its callback gets an error."
  (drgnx-hub--step (list 'timer (cons 'hub-call id))))

;;;; The shell: the core decides (drgnx-hub-core.el), this runs what it decided

(defvar drgnx-hub--asked-disconnect nil
  "Non-nil when this editor ended its own subscription (`drgnx-hub-disconnect', or a `shutdown' it sent): a hub that
goes away then is not redialled (`drgnx-hub--resubscribe-schedule').  Cleared by `drgnx-hub-connect'.")

(defvar drgnx-hub--resubscribe-since nil
  "When the redial of a lost subscription began (`drgnx-timer-now'), or nil when none is under way.")

(defvar drgnx-hub--resubscribe-delay 1 "Seconds until the next redial: 1, doubling to 30.")

(defconst drgnx-hub-resubscribe-give-up 600 "Seconds of redialling after which the editor stops and says so once.")

(defun drgnx-hub--snapshot (conns)
  "The client's globals, and the properties of its connections, of those its calls wait on, and of CONNS, as a core
state."
  (let (pending)
    (maphash (lambda (id e) (push (cons id e) pending) (push (plist-get e :conn) conns)) drgnx-hub--pending)
    (drgnx-hub-core-make
     :client drgnx-hub--client :events drgnx-hub--events :subscribing drgnx-hub--subscribing :pending pending
     :next-id drgnx-hub--next-id :editor drgnx-hub--editor :keys-held drgnx-hub--keys-held
     :asked-disconnect drgnx-hub--asked-disconnect :resubscribe-since drgnx-hub--resubscribe-since
     :resubscribe-delay drgnx-hub--resubscribe-delay :last-hello drgnx-hub--last-hello
     :conns (mapcar (lambda (c)
                      (cons c (cl-loop for (k . prop) in drgnx-hub--conn-props
                                       append (list k (process-get c prop)) into l
                                       finally return (append (list :live (process-live-p c)) l))))
                    (delete-dups (cl-remove-if-not #'processp (append (list drgnx-hub--client drgnx-hub--events
                                                                            drgnx-hub--subscribing)
                                                                      conns))))
     :config (list :call-deadline drgnx-hub-call-deadline :challenge-wait drgnx-hub--challenge-wait
                   :subscribe-deadline drgnx-hub-subscribe-deadline :give-up drgnx-hub-resubscribe-give-up
                   :schema drgnx-work-db-schema-version :noninteractive noninteractive))))

(defun drgnx-hub--write-back (old new)
  "Write the core's state NEW (stepped from OLD) back to the globals and the connections' properties."
  (setq drgnx-hub--client (drgnx-hub-core-client new) drgnx-hub--events (drgnx-hub-core-events new)
        drgnx-hub--subscribing (drgnx-hub-core-subscribing new) drgnx-hub--next-id (drgnx-hub-core-next-id new)
        drgnx-hub--editor (drgnx-hub-core-editor new) drgnx-hub--keys-held (drgnx-hub-core-keys-held new)
        drgnx-hub--asked-disconnect (drgnx-hub-core-asked-disconnect new)
        drgnx-hub--resubscribe-since (drgnx-hub-core-resubscribe-since new)
        drgnx-hub--resubscribe-delay (drgnx-hub-core-resubscribe-delay new)
        drgnx-hub--last-hello (drgnx-hub-core-last-hello new))
  ;; the same table (a test let-binds its own and reads it), filled again only when a call came or went
  (unless (eq (drgnx-hub-core-pending old) (drgnx-hub-core-pending new))
    (clrhash drgnx-hub--pending)
    (dolist (p (drgnx-hub-core-pending new)) (puthash (car p) (cdr p) drgnx-hub--pending)))
  (dolist (c (drgnx-hub-core-conns new))
    (when (processp (car c))
      (cl-loop for (k . prop) in drgnx-hub--conn-props do (process-put (car c) prop (plist-get (cdr c) k))))))

(defun drgnx-hub--step (event &rest conns)
  "Run EVENT (`drgnx-hub-core-event-kinds') through the core: the globals and the properties of the client's
connections, the processes in EVENT and CONNS go in; the new state is written back before the effects run, so an
effect that comes back (a sentinel, a callback that calls the hub) steps from it.  The core's new state."
  (let* ((old (drgnx-hub--snapshot (append conns (cl-remove-if-not #'processp (cdr event)))))
         (r (drgnx-hub-core-step old event)))
    (drgnx-hub--write-back old (car r))
    (dolist (e (cdr r)) (drgnx-hub--effect e))
    (car r)))

(defun drgnx-hub--effect (effect)
  "Run one of the core's EFFECT (`drgnx-hub-core-effect-kinds')."
  (pcase effect
    (`(send ,conn ,msg) (drgnx-hub--send conn msg))
    (`(delete ,conn) (when (process-live-p conn) (delete-process conn)))
    (`(timer-start (hub-call . ,id) ,secs)
     (drgnx-timer-start (cons 'hub-call id) secs #'drgnx-hub--call-expired :args (list id) :owner :core))
    (`(timer-start (hub-challenge . ,c) ,secs)
     (drgnx-timer-start (cons 'hub-challenge c) secs #'drgnx-hub--challenge-late :args (list c) :owner :core))
    (`(timer-start hub-resubscribe ,secs) (drgnx-timer-start 'hub-resubscribe secs #'drgnx-hub--resubscribe :owner :core))
    (`(timer-cancel ,key) (drgnx-timer-cancel key))
    (`(callback ,fn ,label ,args) (drgnx-guard--call fn label args))
    (`(hook ,name . ,args) (apply #'drgnx-hub--run-hook name args))
    (`(notify :clear ,id) (drgnx-notice-clear 'hub id))
    (`(notify ,severity ,text ,id . ,props) (apply #'drgnx-notify 'hub severity text :id id props))
    (_ (error "drgnx hub: no effect %S" effect))))

(defun drgnx-hub--run-hook (name &rest args)
  "The core's effect (hook NAME . ARGS): what only the shell can do — read, wait, start, run the hooks."
  (pcase name
    ('version (let ((conn (nth 0 args)) (nonce (nth 1 args)))
                ;; the binary's version goes in the first hello too: it waits for the read that runs (R-T17-2)
                (drgnx-hub--with-binary-version (lambda () (drgnx-hub--step (list 'version-known conn nonce))))))
    ('hello (apply #'drgnx-hub--hello args))
    ('read (let ((conn (car args)))
             ;; review S2: an Emacs busy past the wait runs the timer before it reads a challenge waiting in the socket
             (when (process-live-p conn) (accept-process-output conn 0 nil t))
             (drgnx-hub--step (list 'timer (cons 'hub-challenge conn) :read t :socket (drgnx-hub-socket)) conn)))
    ('skew (drgnx-guard-run-hook 'drgnx-hub-skew-functions (nth 0 args) (nth 1 args))
           (drgnx-hub--skew-notice (nth 0 args) (nth 1 args)))
    ('events (let ((drgnx-hub--event-conn (nth 0 args)))
               (drgnx-guard-run-hook 'drgnx-hub-event-functions (nth 1 args) (nth 2 args))))
    ('disconnected (drgnx-guard-run-hook 'drgnx-hub-disconnect-functions))
    ('presence-start (drgnx-hub--presence-start))
    ('presence-stop (drgnx-hub--presence-stop))
    ;; the editor's own jobs (grammars, mermaid, the browser, …): their cache, read again on every subscription
    ('exec-sync (with-demoted-errors "drgnx hub: jobs not synced: %S" (require 'drgnx-exec) (drgnx-exec-sync)))
    ('hand-over (with-demoted-errors "drgnx hub: keys not handed over: %S" (drgnx-hub--hand-over)))
    ('connected (drgnx-guard-run-hook 'drgnx-hub-connected-functions))
    ('editor-token (drgnx-guard-run-hook 'drgnx-hub-editor-token-hook))
    ('keys-held (require 'drgnx-ai) (drgnx-hub--keys-lost) (drgnx-hub--keys-note))
    ('dial (drgnx-hub--dial))
    ('redial (condition-case nil (drgnx-hub-connect) (error (drgnx-hub--resubscribe-schedule))))
    ('quiet (set-process-sentinel (car args) #'ignore))
    ('unsync (drgnx-hub--unsync))
    (_ (error "drgnx hub: no hook %S" name))))

(defun drgnx-hub--resubscribe-schedule ()
  "Arm the next redial of the subscription (timer key `hub-resubscribe'): after 1 s, then twice as long each time, up to
30 s.  After `drgnx-hub-resubscribe-give-up' seconds from the first loss it stops and posts one notice naming
Hub: Restart Now.  It never runs `ensure': a hub the user stopped stays stopped.  (The core's `:redial-failed'.)"
  (drgnx-hub--step (list 'connect (drgnx-timer-now) :redial-failed t)))

(defun drgnx-hub--resubscribe ()
  "The redial timer: subscribe again (`drgnx-hub-connect'); a dial that fails at once arms the next one, one that
fails later is found by the sentinel.  Never starts a hub, never asks anything."
  (drgnx-hub--step (list 'timer 'hub-resubscribe)))

(defun drgnx-hub--client-sentinel (conn _event)
  "A client connection closed: its calls fail; the subscribed one's end is said (`drgnx-hub-disconnect-functions').
When the subscription went away without being asked to (a hub restart or crash), the editor token and the held keys are
forgotten and the subscription is redialled with a backoff (`drgnx-hub--resubscribe-schedule').  The core gets one
`closed' per connection, its last event: the filter has run for everything read before the end."
  (unless (or (process-live-p conn) (process-get conn :drgnx-closed))
    (process-put conn :drgnx-closed t)
    (drgnx-hub--step (list 'closed conn (drgnx-timer-now)))))

(defun drgnx-hub--open (events)
  "A new connection to the hub (`drgnx-hub--connect-socket'); EVENTS non-nil: the subscribed connection.  Calls on it
wait in its queue until it is proven or `legacy' (`drgnx-hub--hello').  A `ping' goes at once: a hub of before
protocol 1 answers it, where Ratatoskr's challenge always comes first, so such a hub is not waited for.  None of the
two within `drgnx-hub--challenge-wait' closes the connection (`drgnx-hub--challenge-late'): only the probe's answer
makes a hub `legacy'.  The process."
  (let ((c (drgnx-hub--connect-socket #'drgnx-hub--client-filter)))
    (set-process-sentinel c (drgnx-guard-wrap #'drgnx-hub--client-sentinel "hub connection"))
    (drgnx-hub--frame c)
    (drgnx-hub-client-binary-version t)        ; read now, never waiting: for this hello and the skew
    (drgnx-hub--step (list 'open c events))
    c))

(defun drgnx-hub--challenge-late (conn)
  "`drgnx-hub--challenge-wait' passed with CONN still waiting for its hub's first line.  What already arrived is read
first: an Emacs busy past the wait runs this timer before it reads the challenge waiting in the socket (review S2).
Still nothing: CONN is closed and its calls fail — never taken for `legacy' (a v1 hub would then refuse every user
call on it); the next call connects again."
  (drgnx-hub--step (list 'timer (cons 'hub-challenge conn)) conn))

(defun drgnx-hub--hello (conn hub-nonce)
  "Answer CONN's challenge HUB-NONCE with this Emacs's hello: its protocol, the binary's version (when known), its
schema and records, a fresh nonce and — when `drgnx-hub-client-proves' — the proof that it read the cap file.  The
core judges the answer from what the hello said: the proof the hub must give back, never the cap itself."
  (let* ((nonce (drgnx-hub--nonce))
         (cap (and drgnx-hub-client-proves (drgnx-hub--read-cap)))
         (proof (and (stringp cap) (drgnx-hub-hmac cap (format "drgnx-hub client %s %s" hub-nonce nonce))))
         (version (drgnx-hub-client-binary-version t)))
    (drgnx-hub--call-on conn "hello"
                        (append (list :proto drgnx-hub-proto :nonce nonce)
                                (and version (list :drgnx_version version))
                                (list :schema drgnx-work-db-schema-version :records drgnx-hub-records
                                      :client (if noninteractive "cli" "editor"))
                                (and proof (list :proof proof)))
                        nil :full t :first t
                        :hello (list :problem (and (consp cap) (or (plist-get cap :problem) "it cannot be read"))
                                     :proves (stringp cap)
                                     :expect (and (stringp cap) (drgnx-hub-hmac cap (format "drgnx-hub hub %s %s" nonce hub-nonce)))
                                     :version version :socket (drgnx-hub-socket) :cap-file (drgnx-hub-cap-file)))))

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

(cl-defun drgnx-hub--call-on (conn method params callback &rest keys &key deadline full first hello role under)
  "Call METHOD with PARAMS on CONN (`drgnx-hub-call'); FIRST: send it now (the probe, the hello), else once CONN is
proven or `legacy'.  HELLO, ROLE and UNDER: as the core's `call' event has them.  The call's id."
  (ignore deadline full first hello role under)
  (drgnx-hub-core-next-id (drgnx-hub--step (append (list 'call conn method params callback) keys))))

(defun drgnx-hub--call (method params callback &rest keys)
  "`drgnx-hub-call' with the core's KEYS: on the call connection, opened when there is none."
  (unless (process-live-p drgnx-hub--client)
    (setq drgnx-hub--client (drgnx-hub--open nil)))
  (apply #'drgnx-hub--call-on drgnx-hub--client method params callback keys))

(cl-defun drgnx-hub-call (method params callback &key deadline full)
  "Ask the hub METHOD with PARAMS (a plist); CALLBACK gets (RESULT ERROR) exactly once — ERROR the hub's message (with
FULL its error, (:code :message :path)), or this side's when DEADLINE (`drgnx-hub-call-deadline') seconds pass or
the connection goes first.  A new connection proves itself first (`drgnx-hub--open'); calls wait for that.  Signals
when no hub serves.  The call's id."
  (drgnx-hub--call method params callback :deadline deadline :full full))

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

;;;; MCP sessions: the socket an agent's bridge connects to

(defun drgnx-hub--mcp-answer (result)
  "RESULT of `mcp/session' as (:sid S :socket P), or an error when the hub's answer lacks either."
  (let ((sid (plist-get result :sid)) (socket (plist-get result :socket)))
    (unless (and (stringp sid) (stringp socket)) (error "The drgnx hub's mcp/session answer is malformed"))
    (list :sid sid :socket socket)))

(defun drgnx-hub-profile-id (name)
  "The agent profile NAME as the hub's id for it (letters, digits and ._:+-, a letter or digit at both ends, at most 127
characters): each run of other characters becomes one `-'.  \"claude (OpenRouter)\" is \"claude-OpenRouter\"."
  (let ((id (string-trim (replace-regexp-in-string "[^A-Za-z0-9._:+-]+" "-" name) "[^A-Za-z0-9]+" "[^A-Za-z0-9]+")))
    (if (string-empty-p id) "profile" (substring id 0 (min 127 (length id))))))

(cl-defun drgnx-hub-mcp-session (agent &key sid job task cwd profile tools callback)
  "Ask the hub for the MCP socket of AGENT's session (`mcp/session'): (:sid S :socket P).  The socket is the agent's
identity; the owner is this Emacs, so the hub closes the session when this Emacs dies.  SID: the session's id when its
agent socket made the directory already; JOB, TASK, CWD as the session has them.  PROFILE: the drgnx profile's name
\(grants by `profile:NAME' name it; see `drgnx-hub-profile-id'); TOOLS: the profile's tool sets, `(:tracker t)' or
`(:tracker :false)' (agents.eld's `:tracker-tools'), absent when the profile says nothing — the hub resolves the task's
own setting against it.
- From a command, it waits at most 2 s (`drgnx-hub-call-sync').
- In a daemon path (`inhibit-interaction') it never waits: it asks with `drgnx-hub-call' and returns nil, and
  CALLBACK is called later with (ANSWER ERROR) — ANSWER the plist above, or nil with ERROR a message.
Signals \"Ratatoskr is not built: run `drgnx runtime build'\" when there is no binary."
  (unless (drgnx-hub-client-binary) (error "Ratatoskr is not built: run `drgnx runtime build'"))
  (let ((params (append (list :agent agent)
                        (and sid (list :sid sid)) (and job (list :job job)) (and task (list :task task))
                        (and cwd (list :cwd (expand-file-name cwd)))
                        (list :owner (emacs-pid))
                        (and profile (list :profile (drgnx-hub-profile-id profile)))
                        (and tools (list :tools tools)))))
    (cond (inhibit-interaction
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
    (drgnx-hub-call "mcp/session-close" (list :sid sid) #'ignore)))

(defun drgnx-hub-disconnect ()
  "Close this Emacs's connections to the hub; the calls waiting on them fail (once)."
  (drgnx-hub--step '(disconnect)))

(defun drgnx-hub--unsync ()
  "What `drgnx-hub-disconnect' undoes beside the connections: the jobs' cache and the event handlers
`drgnx-hub-connect' added."
  (when (featurep 'drgnx-exec) (drgnx-exec-unsync))
  (remove-hook 'drgnx-hub-event-functions #'drgnx-hub--note-notice)
  (remove-hook 'drgnx-hub-event-functions #'drgnx-hub--need-keys)
  (remove-hook 'drgnx-hub-event-functions #'drgnx-hub--keys-changed)
  (remove-hook 'drgnx-hub-event-functions #'drgnx-hub--note-card)
  (remove-hook 'drgnx-hub-event-functions #'drgnx-hub--note-plugin)
  (remove-hook 'drgnx-hub-event-functions #'drgnx-settings-agents--event)
  (remove-hook 'drgnx-hub-event-functions #'drgnx-records-review--event)
  (remove-hook 'drgnx-hub-event-functions #'drgnx-history-revert--event)
  (remove-hook 'drgnx-hub-event-functions #'drgnx-say-event))

;;;; Skew: another drgnx's hub

(defun drgnx-hub-skew (reply)
  "What to do about the hub that answered this Emacs's hello with REPLY: `incompatible' (its protocol is older than
`drgnx-hub-proto-min', or this drgnx's older than its `proto_min'); `restart-when-idle' (a legacy hub, `:legacy';
another `records'; a `drgnx_version' other than the binary on disk's, when that is known; a `schema' this editor cannot
read — below `drgnx-work-db-schema-version' or above `drgnx-hub-schema-readable-max', 0 (no work.db yet) counting as
readable; schema 7 of the hub is read through its compatibility views); else `ok'.  (`drgnx-hub-core-skew'.)"
  (drgnx-hub-core-skew reply (drgnx-hub-client-binary-version t) drgnx-work-db-schema-version))

(defun drgnx-hub-has-method-p (name)
  "Whether the last hub that answered this Emacs's hello has method NAME (nil for a legacy hub)."
  (and (consp drgnx-hub--last-hello) (member name (plist-get drgnx-hub--last-hello :methods)) t))

(defun drgnx-hub-running-p ()
  "Does a hub serve this data dir?"
  (drgnx-hub--ping-socket (drgnx-hub-socket)))

(defun drgnx-hub--held-keys ()
  "The provider keys this Emacs can hand over now, asking no one, for each keyed provider of the effective table
\(`drgnx-ai-key' without INTERACTIVE): its environment variable, else a key AI: Load Keys found and the hub has not
taken yet (`drgnx-ai--keys'), else auth-source's sources that never ask (`drgnx-ai--quiet-sources': a plain
~/.authinfo, never a .gpg file, the Keychain or the keyring), read without keeping anything.  So a hub that restarted
gets back the keys that live in a quiet file (design §5.6).  (:PROVIDER KEY…).  An empty key is no key: it would
replace a good one in the hub."
  (require 'drgnx-ai)                   ; the provider list: not needed to load the client, only to hand keys over
  (cl-loop for (id . p) in (drgnx-ai-providers)
           for key = (and (plist-get p :key-env) (drgnx-ai-key id nil))
           when (and (stringp key) (not (string-empty-p key))) append (list (intern (concat ":" (symbol-name id))) key)))

(defun drgnx-hub--send-keys ()
  "Hand the hub the keys this Emacs holds (`drgnx-hub--held-keys'), over the socket: never in an environment, an
argument or a file, and only to a hub that proved itself (`drgnx-hub-core--transmit').  Once the hub took them this
Emacs drops them (`drgnx-hub--keys-taken'): the hub alone holds them, in memory, and those in the environment go
again on each start and each (re)connect.  The call's id."
  (when-let* ((keys (drgnx-hub--held-keys)))
    (drgnx-hub-call "gateway/keys" (list :keys keys) (lambda (_result err) (drgnx-hub--keys-taken keys err)))))

(defun drgnx-hub--keys-taken (keys err)
  "The hub answered a `gateway/keys' that carried KEYS: without ERR it took them, and this Emacs drops them
\(`drgnx-hub--drop-keys').  A refusal, a deadline or a closed connection keeps them for the next hand-over."
  (unless err (drgnx-hub--drop-keys keys)))

(declare-function drgnx-ai-forget-keys "drgnx-ai")

(defun drgnx-hub--drop-keys (keys)
  "The hub took KEYS (:PROVIDER KEY…) over a connection that proved itself (`gateway/keys', or `gateway/register'
with them, answered): this Emacs keeps none of them (`drgnx-ai-forget-keys')."
  (require 'drgnx-ai)
  (drgnx-ai-forget-keys keys))

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

(defun drgnx-hub--need-keys (event data)
  "`gateway/need-keys' (DATA (:providers [ID…])): agents need the keys of these providers and the hub holds none (it
restarted; keys live in its memory only).  Only for a hub that proved itself (`:drgnx-proven' of the connection the
event came on).  Each key is looked for again as the hand-over does (`drgnx-ai-key' without INTERACTIVE: the
environment, else auth-source's sources that never ask, read without keeping anything), and the ones found go with
`gateway/keys'; once the hub took them this Emacs keeps none (`drgnx-hub--keys-taken').  This runs in a process
filter, a daemon path: nothing asks — no .gpg file, Keychain or keyring (design §5.6); a key not found is a notice
saying how to load it."
  (when (and (equal event "gateway/need-keys") (processp drgnx-hub--event-conn)
             (process-get drgnx-hub--event-conn :drgnx-proven))
    (require 'drgnx-ai)
    (let ((providers (drgnx-ai-providers)) keys missing)
      (dolist (name (plist-get data :providers))
        (when (stringp name)
          (let* ((e (cl-find-if (lambda (e) (equal (symbol-name (car e)) name)) providers))
                 (key (and (plist-get (cdr e) :key-env) (drgnx-ai-key (car e) nil))))
            (if (and (stringp key) (not (string-empty-p key)))
                (setq keys (append keys (list (intern (concat ":" name)) key)))
              (push name missing)))))
      (when keys (drgnx-hub-call "gateway/keys" (list :keys keys) (lambda (_result err) (drgnx-hub--keys-taken keys err))))
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

(defvar drgnx-hub--keys-had nil
  "The ids (strings) of the providers whose key a hub held during this Emacs session, as `gateway/keys-held' and
`gateway/keys-changed' said.  Never a key.  After a hub restart, one it no longer holds is a notice
\(`drgnx-hub--keys-lost').")

(defvar drgnx-hub-editor-token-hook nil
  "Functions of no arguments run (inside the guard) when the hub gave this Emacs its editor token: what needed the
gateway's address (gptel's backend) can be set up.")

(defun drgnx-hub--keys-note ()
  "The hub said which keys it holds (`drgnx-hub--keys-held'): each is one it had (`drgnx-hub--keys-had'), and its
`key-lost' notice goes."
  (dolist (name drgnx-hub--keys-held)
    (cl-pushnew name drgnx-hub--keys-had :test #'equal)
    (drgnx-notice-clear 'hub (intern (concat "key-lost-" name)))))

(defun drgnx-hub--keys-lost ()
  "After the hub answered `gateway/keys-held' on a (re)connect: a keyed provider whose key a hub held earlier in this
session (`drgnx-hub--keys-had'), which this hub does not hold and which this Emacs cannot hand over again without
asking (`drgnx-hub--held-keys': the environment, a quiet file), is a notice saying how to load it.  That is a hub
that restarted while the key lived only in a store that asks (a .gpg file, the Keychain, the keyring): without the
notice ghost text and chat would fail with no word why.  Keys this connection's hand-over carried are found again
here, so an answer that came before the hub took them raises nothing.  Runs in a process filter: nothing asks."
  (when (listp drgnx-hub--keys-held)
    (when-let* ((gone (seq-filter (lambda (name)
                                    (and (not (member name drgnx-hub--keys-held))
                                         (plist-get (drgnx-ai-provider (intern name)) :key-env)))
                                  drgnx-hub--keys-had)))
      (let ((here (drgnx-hub--held-keys)))
        (dolist (name gone)
          (unless (plist-get here (intern (concat ":" name)))
            (drgnx-notify 'hub 'warn (format "the drgnx hub restarted without your %s key: run AI: Load Keys" name)
                          :id (intern (concat "key-lost-" name)) :life 'condition :command 'drgnx-ai-load-keys)))))))

(defun drgnx-hub--fetch-editor ()
  "Ask the hub for this Emacs's editor token and for the keys it holds: the ids of the two calls.  The core keeps the
answers (`drgnx-hub--editor', `drgnx-hub--keys-held'; then `drgnx-hub-editor-token-hook', and a key the hub held
before and lost is a notice, `drgnx-hub--keys-lost').  Asked under a subscription, an answer read after that
subscription ended is dropped: it is the gone hub's, and the end forgot both.  The hub ends its connections in any
order, so the call connection's answers can come after the subscription's end; the next subscription asks again."
  (let ((sub drgnx-hub--events))
    (list (drgnx-hub--call "gateway/editor-token" nil nil :role 'token :under sub)
          (drgnx-hub--call "gateway/keys-held" nil nil :role 'keys-held :under sub))))

(defun drgnx-hub--keys-changed (event data)
  "`gateway/keys-changed' (DATA (:providers [ID…])) from a hub that proved itself: the keys it holds now."
  (when (and (equal event "gateway/keys-changed") (processp drgnx-hub--event-conn)
             (process-get drgnx-hub--event-conn :drgnx-proven))
    (setq drgnx-hub--keys-held (seq-filter #'stringp (append (plist-get data :providers) nil)))
    (drgnx-hub--keys-note)))

(defun drgnx-hub-settled-p ()
  "Whether this Emacs is subscribed and no call to the hub waits for its answer (`drgnx-hub-core-settled-p'): no
hand-over answer can still change the editor token or the held keys.  What a test waits for before it changes them."
  (drgnx-hub-core-settled-p (drgnx-hub--snapshot nil)))

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

;;;; Asking for the hub when a daemon has started (the nightly graph backup runs inside the hub)

(defun drgnx-hub--daemon-start-answered (err)
  "The hub asked for at daemon start answered: nothing is handed over (no keys, no settings: the hub holds none until
AI is used), and only a failed start is said, as a notice."
  (when err (drgnx-notify 'hub 'warn err :id 'start)))

(defun drgnx-hub--ask-for-hub ()
  "Ask for the hub without waiting (`drgnx-hub--ensure-running'); no error: the off-switch (DRGNX_NO_HUB_START) and a
Ratatoskr that is not built are quiet.  It does not connect, so no key or provider is touched."
  (ignore-errors (drgnx-hub--ensure-running #'drgnx-hub--daemon-start-answered))
  nil)

(defun drgnx-hub-ask-at-daemon-start ()
  "`emacs-startup-hook' (added by core/drgnx.el, never turned off): in a drgnx daemon, ask for the hub a moment
after startup, so the nightly backup (it runs in the hub) has a hub to run in.  Not in a batch run, a plain Emacs or
where starting a hub is off (DRGNX_NO_HUB_START).  A timer, so startup does not wait and nothing prompts."
  (when (and (daemonp) (not noninteractive) (not (getenv "DRGNX_NO_HUB_START")))
    (drgnx-timer-start 'hub-daemon-start 2 #'drgnx-hub--ask-for-hub :owner :core)
    nil))

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
  "Hand the hub the runtime settings your Lisp holds (`drgnx-settings-runtime-send') and the keys this Emacs holds
\(`drgnx-hub--send-keys'), and ask it for the editor token and the keys it holds (`drgnx-hub--fetch-editor'): the ids
of the calls made."
  (require 'drgnx-settings-runtime)     ; the sender needs the settings layers; a client that never hands over does not load them
  (delq nil (append (list (drgnx-settings-runtime-send) (drgnx-hub--send-keys)) (drgnx-hub--fetch-editor))))

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
  "End the Lisp hub of before this update (protocol 0 has `shutdown', not `restart'), wait up to 5 s for its lock
directory to go, then start Ratatoskr."
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

;;;; The store's settings the editor owns

(defvar drgnx-store-only-i-close-my-tasks)

(defun drgnx-hub--settings-failed (text)
  (drgnx-notify 'hub 'warn (format "drgnx hub: %s" text) :id 'store-settings))

(defun drgnx-hub-send-settings ()
  "Tell the hub the store settings this editor holds (`graph/settings': \"only I close my tasks\").  Asynchronous; an
error shows once, as \"drgnx hub: TEXT\"."
  (condition-case err
      (drgnx-hub-call "graph/settings"
                      (list :set (list :only_user_closes (if drgnx-store-only-i-close-my-tasks t :false)))
                      (lambda (_result e) (when e (drgnx-hub--settings-failed e))))
    (error (drgnx-hub--settings-failed (error-message-string err)))))

(defun drgnx-hub--only-closes-set (symbol value)
  "The :set of `drgnx-store-only-i-close-my-tasks': the hub hears of a change at once (when connected; else at the
next connection)."
  (set-default symbol value)
  (when (or (process-live-p drgnx-hub--client) (process-live-p drgnx-hub--events))
    (drgnx-hub-send-settings)))

(defcustom drgnx-store-only-i-close-my-tasks nil
  "Non-nil: an agent's `done' on a task of yours is a proposal until you accept it (the agent cannot close tasks).
Sent to the hub when this editor connects and when you change it."
  :type 'boolean :group 'drgnx :set #'drgnx-hub--only-closes-set)

(defun drgnx-hub-connect ()
  "Subscribe to the hub's events (`drgnx-hub-event-functions') and, once the hub answered, hand it the provider table
and the keys this Emacs holds (`drgnx-hub--hand-over'); answer its `gateway/need-keys' (`drgnx-hub--need-keys').
Asynchronous; safe to call again, also before the hub has answered (one subscription: the core decides whether to
dial, and gives up a `subscribe' left unanswered past `drgnx-hub-subscribe-deadline').  When the hub answers the
subscription, the core runs the hand-over (`drgnx-hub-core--subscribed')."
  (drgnx-hub--step (list 'connect (float-time))))

(defun drgnx-hub--dial ()
  "The core's dial: a connection of its own for the subscription, which proves itself first (`drgnx-hub--open'); its
end is said by its sentinel."
  (let ((c (drgnx-hub--open t)))
    (drgnx-hub--step (list 'connect (float-time) :opened c))
    (drgnx-hub--call-on c "subscribe" nil nil)
    ;; all removed by `drgnx-hub-disconnect'
    (add-hook 'drgnx-hub-event-functions #'drgnx-hub--note-notice)
    (add-hook 'drgnx-hub-event-functions #'drgnx-hub--need-keys)
    (add-hook 'drgnx-hub-event-functions #'drgnx-hub--keys-changed)
    (add-hook 'drgnx-hub-event-functions #'drgnx-hub--note-card)
    (add-hook 'drgnx-hub-event-functions #'drgnx-hub--note-plugin)
    (when (require 'drgnx-settings-agents nil t) (add-hook 'drgnx-hub-event-functions #'drgnx-settings-agents--event))
    (when (require 'drgnx-records-review nil t) (add-hook 'drgnx-hub-event-functions #'drgnx-records-review--event))
    (when (require 'drgnx-history-revert nil t) (add-hook 'drgnx-hub-event-functions #'drgnx-history-revert--event))
    (when (require 'drgnx-say nil t) (add-hook 'drgnx-hub-event-functions #'drgnx-say-event))
    (drgnx-hub-send-settings)
    (when (fboundp 'drgnx-settings-history-connected) (drgnx-settings-history-connected))))

;; The subscription's answer is the core's (`drgnx-hub-core--subscribed'): the hub answered a `subscribe', so that
;; connection is the subscribed one, and the hub gets the provider table and the keys (`drgnx-hub--hand-over', the hook
;; `hand-over').  A hub keeps keys in memory only: one that restarted has none, so each new subscription gives them
;; again.  They go after the answer, so a `gateway/need-keys' the hub sends a new subscriber is about the keys it held
;; before them.

;;;; The away signal (agent system part 1, Task 13)
;; The editor tells the hub when you are away (`presence/set'), so the matrix's time presets follow.  Never from an
;; agent.  An idle timer (key `hub-presence') fires once in every pause longer than `drgnx-agents-away-after'; while
;; away, `drgnx-hub--presence-back' on `pre-command-hook' says "back" at your next command (no poll).  It reads one
;; variable, removes itself when it fires, and `drgnx-hub--presence-stop' removes it too.  Only a change is sent.

(defvar drgnx-hub--presence-sent :unknown
  "What the hub was last told: t (away), nil (back) or `:unknown' (nothing yet on this subscription).")

(defun drgnx-hub--presence-away-p ()
  "Non-nil when Emacs has been idle for `drgnx-agents-away-after' seconds or more."
  (let ((idle (drgnx-timer--idle-time)))
    (and idle (>= (float-time idle) drgnx-agents-away-after))))

(defun drgnx-hub--presence-back ()
  "`pre-command-hook' while away: your next command tells the hub you are back.  Cached state only; removes itself."
  (remove-hook 'pre-command-hook #'drgnx-hub--presence-back)
  (when (eq drgnx-hub--presence-sent t)
    (setq drgnx-hub--presence-sent nil)
    (when (process-live-p drgnx-hub--events)
      (drgnx-hub-call "presence/set" (list :away :false) #'ignore))))

(defun drgnx-hub--presence-tick ()
  "Send `presence/set' when away or back changed since the last time; never prompts, never blocks."
  (when (process-live-p drgnx-hub--events)
    (let ((away (and (drgnx-hub--presence-away-p) t)))
      (if away
          (add-hook 'pre-command-hook #'drgnx-hub--presence-back)
        (remove-hook 'pre-command-hook #'drgnx-hub--presence-back))
      (unless (eq away drgnx-hub--presence-sent)
        (setq drgnx-hub--presence-sent away)
        (drgnx-hub-call "presence/set" (list :away (if away t :false)) #'ignore)))))

(defun drgnx-hub--presence-start ()
  "A new subscription: the hub's idea of you is unknown, so the next change is sent whatever it is; arm the idle
timer.  A hub starts with you back, so nothing goes now unless you are away already."
  (setq drgnx-hub--presence-sent :unknown)
  (drgnx-timer-start 'hub-presence drgnx-agents-away-after #'drgnx-hub--presence-tick
                     :idle t :repeat t :owner :core)
  (when (drgnx-hub--presence-away-p) (drgnx-hub--presence-tick)))

(defun drgnx-hub--presence-stop ()
  "Forget the presence timers."
  (drgnx-timer-cancel 'hub-presence)
  (remove-hook 'pre-command-hook #'drgnx-hub--presence-back)
  (setq drgnx-hub--presence-sent :unknown))

(defun drgnx-hub--note-notice (event data)
  "In an editor: a `notice' the hub sent (it is not the version on disk any more) becomes a notice of source `hub', with
the command it names (Hub: Restart Now).  A condition: the hub, or the next hello from a current one, takes it away."
  (when (equal event "notice")
    (let ((id (plist-get data :id)) (text (plist-get data :text)) (severity (plist-get data :severity))
          (command (plist-get data :command)))
      (when (and (stringp id) (stringp text) (member severity '("info" "warn" "fail")))
        (drgnx-notify 'hub (intern severity) text :id (intern id)
                      :life (if (equal (plist-get data :life) "condition") 'condition 'event)
                      ;; only a registry id: the click runs it through `drgnx-ui--run'
                      :command (let ((sym (and (stringp command) (intern-soft command))))
                                 (and sym (fboundp 'drgnx-commands-get) (drgnx-commands-get sym) sym)))))))

(defvar drgnx-hub--card-choices nil
  "The matrix cards that list their answers, newest first: (ID :title TITLE :body BODY :choices ((CHOICE . LABEL)…)),
as their `card' events said.  At most `drgnx-hub--card-choices-cap' entries; an entry goes once its card's notice is
gone (`drgnx-hub--card-choices-live').")

(defconst drgnx-hub--card-choices-cap 64 "How many cards' choices `drgnx-hub--card-choices' keeps.")

(defun drgnx-hub--card-notice-id (id)
  "The notice id of matrix card ID."
  (intern (format "matrix-card-%d" id)))

(defun drgnx-hub--card-choices-live ()
  "`drgnx-hub--card-choices' without the cards whose notice is gone (answered, or cleared with the hub)."
  (when drgnx-hub--card-choices
    (let ((live (mapcar (lambda (n) (plist-get n :id)) (drgnx-notices :source 'hub :life 'condition))))
      (setq drgnx-hub--card-choices
            (cl-remove-if-not (lambda (e) (memq (drgnx-hub--card-notice-id (car e)) live)) drgnx-hub--card-choices))))
  drgnx-hub--card-choices)

(defun drgnx-hub--card-choices-of (data)
  "The choices a `card' event's DATA lists, as ((CHOICE . LABEL)…); nil when it lists none."
  (let (out)
    (dolist (c (plist-get data :choices))
      (let ((id (plist-get c :id)) (label (plist-get c :label)))
        (when (and (stringp id) (stringp label)) (push (cons id label) out))))
    (nreverse out)))

(defun drgnx-hub--card-choices-put (id data choices)
  "Keep CHOICES of card ID with its DATA's title and body, newest first, within the cap."
  (let ((entry (list id :title (plist-get data :title) :body (plist-get data :body) :choices choices))
        (rest (assq-delete-all id (drgnx-hub--card-choices-live))))
    (setq drgnx-hub--card-choices (seq-take (cons entry rest) drgnx-hub--card-choices-cap))))

(defun drgnx-hub--event-proven-p ()
  "Non-nil when the event now handled came on a connection of a hub that proved itself."
  (and (processp (bound-and-true-p drgnx-hub--event-conn)) (process-get drgnx-hub--event-conn :drgnx-proven)))

(defconst drgnx-hub--quote-max 280 "The most of an agent's words a suggestion's notice quotes, in characters.")

(defun drgnx-hub--quote (text)
  "TEXT, an agent's words, as one inert line: no control, bidi or zero-width character, at most
`drgnx-hub--quote-max' characters."
  (let* ((line (replace-regexp-in-string "[\n\r\t  ]" " " text t t))
         (clean (replace-regexp-in-string
                 "[[:cntrl:]­؜᠎​-‏‪-‮⁠-⁤⁦-⁩﻿]" "" line t t)))
    (substring-no-properties (truncate-string-to-width (string-trim clean) drgnx-hub--quote-max))))

(defun drgnx-hub--note-extension-card (data)
  "An agent's suggestion (an `extension' card): an open one is a notice whose command opens the package's page, with
the hub's title as its text and the agents' words only quoted in its detail; nothing on it installs.  A withdrawn or
settled one takes its notice away."
  (let ((key (intern (format "extension-card-%d" (plist-get data :id))))
        (id (plist-get (plist-get data :data) :id)))
    (if (not (equal (plist-get data :state) "open"))
        (drgnx-notice-clear 'hub key)
      (when (and (stringp id) (string-match-p "\\`\\(?:pkg\\|plugin\\):[^[:space:][:cntrl:]]\\{1,200\\}\\'" id)
                 (stringp (plist-get data :title)))
        (drgnx-notify 'hub 'info (drgnx-hub--quote (plist-get data :title))
                      :id key :life 'condition
                      :detail (mapconcat (lambda (q)
                                           (format "%s says: “%s”"
                                                   (drgnx-hub--quote (format "%s" (plist-get q :session)))
                                                   (drgnx-hub--quote (format "%s" (plist-get q :text)))))
                                         (plist-get (plist-get data :data) :why) "; ")
                      :command (list 'drgnx-extensions-show-suggestion id))))))

(defun drgnx-hub--note-card (event data)
  "In an editor: a `matrix' card (the permission matrix asks), an `extension' card (an agent's suggestion:
`drgnx-hub--note-extension-card') or a `supervisor' pause from a hub that proved itself is a notice.  Nothing asks
and nothing waits: a card that lists its answers (a browser row's) keeps them here and its notice carries Agents:
Answer Permission Card with the card's id; the agent panel's cards answer the others.
`agent-step' is not handled here: it matters only to a subscriber that asked for it."
  (when (drgnx-hub--event-proven-p)
    (cond
     ((and (equal event "card") (equal (plist-get data :kind) "matrix") (numberp (plist-get data :id)))
      (let* ((id (plist-get data :id)) (choices (drgnx-hub--card-choices-of data)))
        (drgnx-notify 'hub 'info
                      (format "The permission matrix asks: %s" (or (plist-get data :title) "a question is waiting"))
                      :id (drgnx-hub--card-notice-id id) :life 'condition
                      :scope (plist-get data :job)
                      :command (and choices (list 'drgnx-agents-answer-card id)))
        (when choices (drgnx-hub--card-choices-put id data choices))))
     ((and (equal event "card") (equal (plist-get data :kind) "extension") (natnump (plist-get data :id)))
      (drgnx-hub--note-extension-card data))
     ((and (equal event "supervisor") (stringp (plist-get data :text)))
      (drgnx-notify 'hub 'warn (format "An agent was paused: %s" (plist-get data :text))
                    :id (intern (format "supervisor-%s" (or (plist-get data :card) (plist-get data :session) "rule")))
                    :life 'condition)))))

(defun drgnx-hub--plugin-notice-id (name)
  "The notice id of plugin NAME."
  (intern (format "plugin-%s" name)))

(defun drgnx-hub--note-plugin (event data)
  "In an editor: a `plugin' event from a hub that proved itself, or a `card' of kind `plugin', becomes a notice of
source `hub' for a plugin that waits for your approval (`unapproved', `changed') or is `broken'; any other state
takes the notice away.  The click opens the plugin's page (`drgnx-plugins-page-open', when the module
`tools/plugins' runs).  Nothing asks and nothing is approved here."
  (when (and (drgnx-hub--event-proven-p)
             (or (equal event "plugin")
                 (and (equal event "card") (equal (plist-get data :kind) "plugin"))))
    (let* ((name (or (plist-get data :name) (plist-get data :subject)))
           (state (or (plist-get data :state) "unapproved"))
           (id (and (stringp name) (drgnx-hub--plugin-notice-id name))))
      (when id
        (if (not (member state '("unapproved" "changed" "broken")))
            (drgnx-notice-clear 'hub id)
          (drgnx-notify 'hub (if (equal state "broken") 'warn 'info)
                        (pcase state
                          ("unapproved" (format "Plugin %s waits for your approval" name))
                          ("changed" (format "Plugin %s changed since you approved it: it does not run until you approve it again" name))
                          (_ (format "Plugin %s does not load" name)))
                        :id id :life 'condition
                        :command (and (fboundp 'drgnx-plugins-page-open) (list 'drgnx-plugins-page-open name))))))))

(provide 'drgnx-hub-client)
;;; drgnx-hub-client.el ends here
