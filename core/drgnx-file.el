;;; drgnx-file.el --- Files drgnx keeps: one bounded reader, one atomic writer, a locked update -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The byte layer under drgnx-config (docs/develop/core.md, "Files drgnx keeps: drgnx-file").
;; - `drgnx-file-read-bounded' gives a local regular file's text, or refuses: a remote name, a symbolic link to
;;   nothing, anything that is not a regular file (checked before opening, so a FIFO never blocks) and a file over the
;;   limit (never truncated).
;; - `drgnx-file-read' reads exactly one plain data form from it, or names the problem with its line and column.
;; - `drgnx-file-write' and `drgnx-file-write-text' replace a file atomically through a temp file beside it: a symlink
;;   stays a symlink, the mode is kept, data must read back `equal', and no buffer ever visits the file.
;; - `drgnx-file-update' is the locked read-modify-write: a `make-directory' lock, a fresh read, the change applied,
;;   the lock released.
;; - `drgnx-file-truename' and `drgnx-file-inside-p' resolve a name an agent gave, with no file name handler
;;   (docs/develop/core.md, "Names an agent gave").
;; Every name is used with no file name handlers and `default-directory' "/", so nothing here reaches Tramp, and
;; nothing prompts.  It requires only cl-lib and subr-x, so an `emacs --batch -Q' hub can load it.

;;; Code:
(require 'cl-lib)
(require 'subr-x)

(defvar drgnx-file-max-bytes 1048576
  "The largest file `drgnx-file-read-bounded' reads, in bytes (1 MiB); a bigger one is refused, never truncated.")

(defvar drgnx-file-max-depth 64
  "How deeply lists and vectors may nest in a file `drgnx-file-read' accepts.")

(defvar drgnx-file-backups-kept 3
  "How many backups `drgnx-file-backup' keeps of each file (the newest).")

(defvar drgnx-file-lock-retry 0.01
  "Seconds between two attempts to take a file's lock.")

(defvar drgnx-file-lock-stale 10.0
  "Seconds after which a file's lock is stale, whoever holds it.")

(define-error 'drgnx-file-refused "drgnx refused the file" 'file-error)
(define-error 'drgnx-file-busy "Another drgnx holds the file's lock" 'file-error)

;;;; Seams (tests replace them)

(defun drgnx-file--now ()
  "The lock's clock: `float-time'."
  (float-time))

(defun drgnx-file--sleep (seconds)
  "The lock's wait between two attempts: `sleep-for' SECONDS."
  (sleep-for seconds))

(defmacro drgnx-file--locally (&rest body)
  "BODY with no file name handlers and `default-directory' \"/\": nothing reaches Tramp, a \"~\" is the local home."
  (declare (indent 0) (debug t))
  `(let ((file-name-handler-alist nil) (default-directory "/"))
     ,@body))

(defun drgnx-file--pid-start (pid)
  "When the local process PID started (a float, from `process-attributes'), or nil when it is gone."
  (drgnx-file--locally                                  ; a remote `default-directory' would ask the remote host
    (when-let* ((start (alist-get 'start (process-attributes pid))))
      (float-time start))))

;;;; Reading

(defconst drgnx-file--remote-re "\\`/[^/|:]+:"
  "A remote (Tramp) file name.")

(defun drgnx-file--expand (file)
  "FILE expanded locally; `drgnx-file-refused' when it is a remote name."
  (let ((name (drgnx-file--locally (expand-file-name file))))
    (when (string-match-p drgnx-file--remote-re name)
      (signal 'drgnx-file-refused (list name "a remote file")))
    name))

(defun drgnx-file--regular-p (attrs)
  "Whether ATTRS are a regular file's.  Only the mode string tells: `file-attribute-type' is nil for a FIFO too."
  (string-prefix-p "-" (or (file-attribute-modes attrs) "")))

(cl-defun drgnx-file-read-bounded (file &key (max-bytes drgnx-file-max-bytes))
  "FILE's text decoded as UTF-8, or nil when FILE does not exist.
Signals `drgnx-file-refused' (data (FILE REASON)) for a remote name, a symbolic link to nothing, anything that is not
a regular file (checked before opening, so a FIFO never blocks) and a file over MAX-BYTES — also one that grew past
it while it was read: it is never truncated.  No file name handler runs."
  (drgnx-file--locally
    (let ((name (drgnx-file--expand file)))
      (when (and (file-symlink-p name) (not (file-exists-p name)))
        (signal 'drgnx-file-refused (list name "a symbolic link to nothing")))
      (when-let* ((true (file-truename name))
                  (attrs (file-attributes true)))
        (unless (drgnx-file--regular-p attrs)
          (signal 'drgnx-file-refused (list name "not a regular file")))
        (let ((over (lambda () (signal 'drgnx-file-refused (list name (format "over %d bytes" max-bytes))))))
          (when (> (file-attribute-size attrs) max-bytes) (funcall over))
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert-file-contents-literally true nil 0 (1+ max-bytes))
            (when (> (buffer-size) max-bytes) (funcall over))
            (decode-coding-string (buffer-string) 'utf-8-unix t)))))))

(defun drgnx-file-stamp (file)
  "(INODE MTIME SIZE) of FILE's truename, from one `file-attributes' call; nil when it is missing (or remote).
The inode sees a file renamed over FILE within one mtime tick."
  (drgnx-file--locally
    (let ((name (expand-file-name file)))
      (unless (string-match-p drgnx-file--remote-re name)
        (when-let* ((a (file-attributes (file-truename name))))
          (list (file-attribute-inode-number a) (file-attribute-modification-time a) (file-attribute-size a)))))))

(defun drgnx-file--problem (text pos &optional line column)
  "A problem: TEXT at POS in the current buffer, or at LINE and COLUMN (both 1-based) when given."
  (save-excursion
    (goto-char pos)
    (list :text text :line (or line (line-number-at-pos pos t)) :column (or column (1+ (- pos (line-beginning-position)))))))

(defun drgnx-file--walk (object)
  "Why OBJECT is not plain data, or nil: (depth) when lists and vectors nest deeper than `drgnx-file-max-depth',
\(string) for a string with text properties, (TYPE) for anything but a symbol, a number, a string, a cons or a
vector (a record, a hash table, byte-code, a bool-vector, a char-table, …)."
  (let ((max drgnx-file-max-depth))
    (cl-labels ((walk (x depth)                         ; DEPTH: the containers around X
                  (cond ((or (symbolp x) (numberp x)) nil)
                        ((stringp x) (and (> (length x) 0) (or (text-properties-at 0 x) (next-property-change 0 x))
                                          '(string)))
                        ((or (consp x) (vectorp x))
                         (if (>= depth max) '(depth)
                           (let ((why nil))
                             (if (vectorp x)
                                 (cl-loop for e across x until (setq why (walk e (1+ depth))))
                               (while (and (consp x) (not why))
                                 (setq why (walk (car x) (1+ depth)) x (cdr x)))
                               (unless why (setq why (walk x (1+ depth)))))   ; a dotted list's last cdr
                             why)))
                        (t (list (type-of x))))))
      (walk object 0))))

(defun drgnx-file--locate (why start)
  "Where in the current buffer the form at START shows WHY (from `drgnx-file--walk'): a position, else START."
  (save-excursion
    (goto-char start)
    (or (if (eq (car why) 'depth)
            (let ((target (1+ drgnx-file-max-depth)))
              (and (= (car (parse-partial-sexp start (point-max) target)) target) (1- (point))))
          (let ((from start) (state nil) (found nil))
            (while (and (not found) (re-search-forward "#[s&^[(]" nil t))
              (setq state (parse-partial-sexp from (match-beginning 0) nil nil state)
                    from (match-beginning 0))
              (unless (nth 8 state) (setq found (match-beginning 0))))   ; not in a string or a comment
            found))
        start)))

(defun drgnx-file--why-text (why)
  "The problem text for WHY (from `drgnx-file--walk')."
  (pcase (car why)
    ('depth (format "lists nest deeper than %d" drgnx-file-max-depth))
    ('string "a string with text properties")
    (type (format "a %s, which is not plain data" type))))

(defun drgnx-file--parse (text)
  "TEXT's one data form: (ok . DATA), (absent) for only whitespace and comments, or (problem . PROBLEM)."
  (with-temp-buffer
    (insert text)
    (set-syntax-table lisp-data-mode-syntax-table)
    (goto-char (point-min))
    (forward-comment (buffer-size))
    (if (eobp) (list 'absent)
      (let ((start (point)))
        (condition-case err
            (let* ((data (let ((read-circle nil) (read-symbol-shorthands nil)) (read (current-buffer))))
                   (why (progn (forward-comment (buffer-size)) (and (eobp) (drgnx-file--walk data)))))
              (cond ((not (eobp)) (cons 'problem (drgnx-file--problem "text after the data" (point))))
                    (why (cons 'problem (drgnx-file--problem (drgnx-file--why-text why) (drgnx-file--locate why start))))
                    (t (cons 'ok data))))
          (invalid-read-syntax
           (let ((line (nth 2 err)) (column (nth 3 err)))
             (cons 'problem (drgnx-file--problem (format "invalid syntax: %s" (nth 1 err)) (point)
                                                 (and (natnump line) (natnump column) line)
                                                 (and (natnump line) (natnump column) column)))))
          (end-of-file (cons 'problem (drgnx-file--problem "the file ends inside a form" (point-max))))
          (error (cons 'problem (drgnx-file--problem (error-message-string err) (point)))))))))

(cl-defun drgnx-file-read (file &key max-bytes)
  "FILE read as one data form: (:status S :data D :text T :problem P :stamp ST).
S is `absent' (missing, empty, or only whitespace and comments), `ok' or `unreadable'.  D is the data (ok only), T
the decoded text, P (:text STRING :line N :column N) (lines and columns 1-based) and ST `drgnx-file-stamp'.
Unreadable: a refusal of `drgnx-file-read-bounded' (MAX-BYTES, default `drgnx-file-max-bytes'), an error reading,
`#1=' (no shared or circular structure), text after the form, nesting deeper than `drgnx-file-max-depth', or an
object that is not plain data (records, hash tables, byte-code, strings with text properties, …)."
  (let ((stamp (drgnx-file-stamp file)))
    (condition-case err
        (let ((text (drgnx-file-read-bounded file :max-bytes (or max-bytes drgnx-file-max-bytes))))
          (if (null text) (list :status 'absent :data nil :text nil :problem nil :stamp nil)
            (let ((r (drgnx-file--parse text)))
              (pcase (car r)
                ('ok (list :status 'ok :data (cdr r) :text text :problem nil :stamp stamp))
                ('absent (list :status 'absent :data nil :text text :problem nil :stamp stamp))
                (_ (list :status 'unreadable :data nil :text text :problem (cdr r) :stamp stamp))))))
      (file-error
       (list :status 'unreadable :data nil :text nil :stamp stamp
             :problem (list :text (if (eq (car err) 'drgnx-file-refused) (nth 2 err) (error-message-string err))
                            :line 1 :column 1))))))

;;;; Writing

(defun drgnx-file--print (data pretty)
  "DATA printed for a file (with `pp' when PRETTY), ending in one newline, whatever the user's print settings."
  (let ((print-length nil) (print-level nil) (print-circle nil) (print-integers-as-characters nil)
        (float-output-format nil))
    (concat (string-trim-right (if pretty (pp-to-string data) (prin1-to-string data)) "\n+") "\n")))

(defun drgnx-file--target (file)
  "Where a write of FILE goes: its local truename (a symlink's target), its folder made.
`drgnx-file-refused' for a remote name or something there that is not a regular file."
  (drgnx-file--locally
    (let* ((target (file-truename (drgnx-file--expand file)))
           (attrs (file-attributes target)))
      (when (and attrs (not (drgnx-file--regular-p attrs)))
        (signal 'drgnx-file-refused (list target "not a regular file")))
      (make-directory (file-name-directory target) t)
      target)))

(defun drgnx-file--replace (target bytes mode private fsync check)
  "Replace TARGET (a local truename) by the unibyte BYTES, atomically: a temp file .NAME.tmp-XXXXXX beside it,
renamed over it.  CHECK, unless nil, is called with the temp file before the rename and signals to stop.  The new
file gets the old one's mode, else MODE, else 0644 (0600 with PRIVATE, which also takes group and other bits away).
TARGET."
  (drgnx-file--locally
    (let* ((m (or (file-modes target) mode (if private #o600 #o644)))
           (modes (if private (logand m #o700) m))
           (tmp (with-file-modes #o600
                  (make-temp-file (expand-file-name (concat "." (file-name-nondirectory target) ".tmp-")
                                                    (file-name-directory target)))))
           (renamed nil))
      (unwind-protect
          (let ((coding-system-for-write 'no-conversion) (write-region-inhibit-fsync (not fsync))
                (create-lockfiles nil) (write-region-annotate-functions nil)
                (write-region-post-annotation-function nil))
            (write-region bytes nil tmp nil 'silent)
            (when check (funcall check tmp))
            (set-file-modes tmp modes)
            (rename-file tmp target t)
            (setq renamed t)
            target)
        (unless renamed (ignore-errors (delete-file tmp)))))))

(cl-defun drgnx-file-write (file data &key header mode private (fsync t) pretty text max-bytes)
  "Write DATA to FILE atomically; the path written (FILE's truename: a symlink stays a symlink).
The content is HEADER (comment lines, or nil), then TEXT when given, else DATA printed with `pp' (PRETTY) or
`prin1', whatever the user's print settings.  It is read back by the rules of `drgnx-file-read' and must be `equal' to
DATA, else `drgnx-file-refused' \"not printable as data\" and FILE is untouched.  Missing folders are made.  The mode:
the old file's, else MODE, else 0644 (PRIVATE: 0600 for a new file; an old one loses its group and other bits).
Content over MAX-BYTES (default `drgnx-file-max-bytes', the read limit) is refused \"over N bytes\" before any temp
file is made: drgnx never writes a file its reader would refuse.  FSYNC (default t) syncs the temp file before the
rename.  No buffer visits FILE, nothing prompts and no lock file is made."
  (let* ((content (condition-case nil
                      (concat (and header (if (string-suffix-p "\n" header) header (concat header "\n")))
                              (or text (drgnx-file--print data pretty)))
                    (error (signal 'drgnx-file-refused (list file "not printable as data")))))
         (bytes (encode-coding-string content 'utf-8-unix))
         (cap (or max-bytes drgnx-file-max-bytes))
         (target (if (> (length bytes) cap)
                     (signal 'drgnx-file-refused (list file (format "over %d bytes" cap)))
                   (drgnx-file--target file))))
    (drgnx-file--replace
     target bytes mode private fsync
     (lambda (tmp)
       (let ((r (drgnx-file-read tmp :max-bytes (max 1 (length bytes)))))
         (unless (pcase (plist-get r :status)
                   ('ok (equal (plist-get r :data) data))
                   ('absent (null data)))
           (signal 'drgnx-file-refused (list target "not printable as data"))))))))

(cl-defun drgnx-file-write-text (file text &key mode private (fsync t))
  "Write the string TEXT to FILE (UTF-8) atomically, as `drgnx-file-write' writes, with no read back; the path."
  (drgnx-file--replace (drgnx-file--target file) (encode-coding-string text 'utf-8-unix) mode private fsync nil))

;;;; Backups

(defun drgnx-file--backups (target)
  "TARGET's backups, oldest first."
  (directory-files (file-name-directory target) t
                   (concat "\\`" (regexp-quote (file-name-nondirectory target))
                           "\\.bak-[0-9]\\{8\\}-[0-9]\\{6\\}-[0-9]\\{3\\}\\'")))

(defun drgnx-file-backup (file)
  "Copy FILE aside to NAME.bak-YYYYmmdd-HHMMSS-mmm (UTC) beside its truename, keeping its times and mode, and keep
only the newest `drgnx-file-backups-kept' backups.  The backup's path; nil when FILE is missing.
`drgnx-file-refused' for a remote name or anything that is not a regular file."
  (drgnx-file--locally
    (let* ((target (file-truename (drgnx-file--expand file)))
           (attrs (file-attributes target)))
      (when attrs
        (unless (drgnx-file--regular-p attrs)
          (signal 'drgnx-file-refused (list target "not a regular file")))
        (let ((time (drgnx-file--now)) bak)
          (while (file-exists-p (setq bak (concat target ".bak-" (format-time-string "%Y%m%d-%H%M%S-%3N" time t))))
            (setq time (+ time 0.001)))
          (copy-file target bak nil t)
          (dolist (old (butlast (drgnx-file--backups target) drgnx-file-backups-kept))
            (delete-file old))
          bak)))))

;;;; The lock

(defun drgnx-file--lock-name (target)
  "The lock directory of TARGET (a local truename): .NAME.lock beside it."
  (expand-file-name (concat "." (file-name-nondirectory target) ".lock") (file-name-directory target)))

(defun drgnx-file--owner (lock)
  "The owner plist in the lock directory LOCK, or nil."
  (let* ((r (ignore-errors (drgnx-file-read (expand-file-name "owner" lock) :max-bytes 4096)))
         (data (plist-get r :data)))
    (and (eq (plist-get r :status) 'ok) (consp data) (plistp data) data)))

(defun drgnx-file-lock-holder (file)
  "The owner plist (:pid :host :started :time) of the drgnx holding FILE's lock, or nil."
  (drgnx-file--owner (drgnx-file--lock-name (drgnx-file--locally (file-truename (drgnx-file--expand file))))))

(defun drgnx-file--stale-p (lock owner)
  "Whether LOCK, held by OWNER (nil when its owner file is missing or broken), is stale: older than
`drgnx-file-lock-stale' (OWNER's :time, else the directory's mtime), or on this host with a pid that is gone or
started at another time (a reused pid).  Where this system does not tell start times, only the age counts."
  (let ((time (or (plist-get owner :time)
                  (when-let* ((a (drgnx-file--locally (file-attributes lock))))
                    (float-time (file-attribute-modification-time a)))))
        (pid (plist-get owner :pid)) (started (plist-get owner :started)))
    (or (and (numberp time) (> (- (drgnx-file--now) time) drgnx-file-lock-stale))
        (and (equal (plist-get owner :host) (system-name)) (natnump pid)
             (drgnx-file--pid-start (emacs-pid))
             (let ((now-started (drgnx-file--pid-start pid)))
               (or (null now-started)
                   (and (numberp started) (> (abs (- now-started started)) 1.0))))))))

(defun drgnx-file--try-lock (lock)
  "Make the lock directory LOCK and its owner file: the owner plist written, or nil when LOCK exists."
  (when (drgnx-file--locally (condition-case nil (progn (make-directory lock) t) (file-already-exists nil)))
    (let ((me (list :pid (emacs-pid) :host (system-name) :started (drgnx-file--pid-start (emacs-pid))
                    :time (drgnx-file--now))))
      (condition-case err
          (drgnx-file--locally
            (let ((coding-system-for-write 'utf-8-unix) (create-lockfiles nil) (write-region-inhibit-fsync t)
                  (write-region-annotate-functions nil) (write-region-post-annotation-function nil))
              (write-region (drgnx-file--print me nil) nil (expand-file-name "owner" lock) nil 'silent)
              me))
        (error (ignore-errors (drgnx-file--locally (delete-directory lock t)))
               (signal (car err) (cdr err)))))))

(defun drgnx-file--steal (lock)
  "Move the stale lock LOCK aside (.NAME.lock.stale-PID-RANDOM) and delete it; `make-directory' then decides who
takes it.  Another stealer may have moved it first: that is not an error."
  (drgnx-file--locally
    (let ((aside (format "%s.stale-%d-%06x" lock (emacs-pid) (random #x1000000))))
      (when (ignore-errors (rename-file lock aside) t)
        (ignore-errors (delete-directory aside t))))))

(defun drgnx-file--lock (target timeout)
  "Take TARGET's lock: (LOCK . OWNER).  Retried every `drgnx-file-lock-retry' seconds up to TIMEOUT (0: one
attempt), a stale lock taken; then `drgnx-file-busy' (data (TARGET HOLDER)).  Never prompts."
  (let ((lock (drgnx-file--lock-name target))
        (deadline (+ (drgnx-file--now) timeout)))
    (catch 'taken
      (while t
        (when-let* ((me (drgnx-file--try-lock lock))) (throw 'taken (cons lock me)))
        (let ((owner (drgnx-file--owner lock)))
          (when (drgnx-file--stale-p lock owner)
            (drgnx-file--steal lock)
            (when-let* ((me (drgnx-file--try-lock lock))) (throw 'taken (cons lock me))))
          (when (>= (drgnx-file--now) deadline)
            (signal 'drgnx-file-busy (list target owner)))
          (drgnx-file--sleep drgnx-file-lock-retry))))))

(defun drgnx-file--unlock (held)
  "Release HELD, (LOCK . OWNER) from `drgnx-file--lock', when LOCK still holds OWNER (it was not taken as stale)."
  (when (equal (drgnx-file--owner (car held)) (cdr held))
    (drgnx-file--locally (delete-directory (car held) t))))

(cl-defun drgnx-file-update (file fn &key on-unreadable (timeout 1.0) max-bytes header pretty render private)
  "Change FILE under its lock: the data now in it.
Takes the lock (TIMEOUT seconds, default 1; 0 from timers, filters and sentinels: one attempt, then
`drgnx-file-busy'), reads FILE fresh, and calls FN with a deep copy of its data (nil when it is absent), so FN may
change it in place.  When FN's result is `equal' to the data, nothing is written; else it is written by
`drgnx-file-write' under MAX-BYTES (the read limit too): as the text RENDER returns when given — (funcall RENDER
OLD-TEXT DATA NEW), DATA as read — else printed whole with HEADER and PRETTY.  An unreadable FILE
signals `drgnx-file-refused' and is left untouched; with ON-UNREADABLE `backup' (state files only) it is copied aside
by `drgnx-file-backup' and FN gets nil.  PRIVATE is `drgnx-file-write''s: 0600 for a new file, an old one loses its
group and other bits.  The lock is released whatever happens."
  (let* ((target (drgnx-file--target file))
         (held (drgnx-file--lock target timeout)))
    (unwind-protect
        (let* ((r (drgnx-file-read target :max-bytes max-bytes))
               (data (plist-get r :data)) (old (plist-get r :text)))
          (when (eq (plist-get r :status) 'unreadable)
            (unless (eq on-unreadable 'backup)
              (signal 'drgnx-file-refused (list target (plist-get (plist-get r :problem) :text))))
            (drgnx-file-backup target)
            (setq old nil))
          (let ((new (funcall fn (copy-tree data t))))
            (unless (equal new data)
              (drgnx-file-write target new :header (and (not render) header) :pretty pretty :max-bytes max-bytes :private private
                                :text (and render (funcall render old data new))))
            new))
      (drgnx-file--unlock held))))

;;;; Names an agent gave

(defun drgnx-file-truename (file &optional dir)
  "FILE, expanded against DIR (default: `default-directory'), with `.', `..' and every symbolic link resolved, as a
local name — or nil when it is, or leads through a link to, a remote (Tramp) name or a quoted one (`/:…', which
`file-name-non-special' unquotes once handlers are on), and when its links loop or run past the 100 `file-truename'
follows (that signals \"Apparent cycle\"): fail closed, callers take nil as outside or refused.  For a name an agent
or a model gave (an ACP tool call's locations, an fs/* request, a review finding): no file name handler runs, on FILE
or on any link on its way.  With handlers on, `file-truename' looks one up again at each link: a link in an agent's
worktree climbing `../' to the root and on to `ssh:host:' made Emacs load Tramp and connect (`sudo::': start sudo),
and a `.gz', `.gpg' or archive name reaches jka-compr, EasyPG or tramp-archive.  Use the name this gives, not the
one checked: opening the agent's own name (`find-file') follows its links again, with handlers on."
  (let* ((file-name-handler-alist nil)
         (true (condition-case nil (file-truename (expand-file-name file dir)) (error nil))))
    (and true (not (string-match-p drgnx-file--remote-re true)) (not (string-prefix-p "/:" true)) true)))

(defun drgnx-file-inside-p (file dir)
  "Whether FILE (relative: to DIR) is DIR or inside it once `..' and symbolic links are resolved, with no file name
handler (`drgnx-file-truename'): a name that is or leads to a remote or quoted one, or whose links loop, is not
inside."
  (and (stringp file) (stringp dir)
       (let ((true (drgnx-file-truename file dir)) (top (drgnx-file-truename dir)))
         (and true top (let ((file-name-handler-alist nil)) (file-in-directory-p true top))))))

(provide 'drgnx-file)
;;; drgnx-file.el ends here
