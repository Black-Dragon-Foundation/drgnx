;;; drgnx-agent-pair.el --- Module tools/agent-pair: a paired chat's writes, applied between your commands -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Pair mode's editor side (docs/guide/pair-mode.md; the hub's side: docs/develop/hub.md, "Pair mode").  A paired
;; chat's writes reach your checkout only through the hub's door, which sends each one to the Emacs that has the file
;; open (`pair-apply').  This module:
;; - **queues** them: the hub's events arrive in a process filter, which can run inside a command (`sit-for',
;;   `completing-read', a nested `jsonrpc-request'), so the filter only puts the write in its buffer's queue;
;; - **applies them in the safe slot**: from `post-command-hook' when a queue holds writes, or from a timer, only when
;;   no command runs, at recursion and minibuffer depth 0, outside keyboard macros and isearch, while the history is
;;   not resyncing and the module's lock (held across the apply and the save) is free;
;; - **drops a write that waited too long**: its deadline is its arrival here plus the hub's `ttl_ms', checked only
;;   before its apply starts; a write whose apply started is never dropped;
;; - **answers** every write once (`pair/answer'), keeps a bounded record of the answers for `pair-reconcile', and
;;   sends again, on the next connection, the answers the hub did not acknowledge;
;; - **tells the hub which files are open** (`pair/open', `pair/closed', `pair/open-set' at setup and on every
;;   connection), and answers `pair-read' with the buffer's text, unsaved edits included.
;; - **shifts a write over your typing**: a read's version is the buffer's drain counter in the edit history
;;   (`drgnx-history-drain-now'); while a paired chat works in the buffer's checkout the module keeps the changes each
;;   drain sent (`drgnx-agent-pair--log'), and a write based on an older version is moved past them, or refused whole
;;   when it meets them (`drgnx-agent-pair--shift'), or when it touches the lines you are at (the guard zone).  A
;;   version the log no longer covers is refused "read it with read_file"; nothing falls back to an unshifted apply.
;; Every call to the hub goes on the subscribed connection, the one the hub sent the write to: that is how it knows
;; which editor answered.

;;; Code:
(require 'cl-lib)
(require 'drgnx-modules)
(require 'drgnx-hub-client)
(require 'drgnx-timer)
(require 'drgnx-large-file)
(require 'drgnx-no-prompt)
(require 'drgnx-registry)
(require 'drgnx-history)

(defvar nidhogg-history-origin)

(defvar drgnx-agent-pair-log-size 4096
  "How many drains of a buffer its change log keeps at least; more while the hub still holds a read older than them.")

(defvar drgnx-agent-pair-reads-size 16
  "How many versions a buffer keeps the line starts of (the versions its reads and applies handed out), newest first.")

(defconst drgnx-agent-pair-record-size 256
  "How many answers the record keeps (`drgnx-agent-pair-answer-of'), newest first: enough for every write still in
the hub's time to live and its reconcile.")

;;;; State

(defvar-local drgnx-agent-pair--queue nil
  "This buffer's writes waiting for the safe slot, oldest first: the hub's `pair-apply' data plus `:deadline' (this
Emacs's clock).  Permanent: a major-mode change keeps it.")
(put 'drgnx-agent-pair--queue 'permanent-local t)

(defvar-local drgnx-agent-pair--file nil
  "The file name the hub was told this buffer has open (`pair/open'), or nil.  Permanent, so a rename knows the old
name.")
(put 'drgnx-agent-pair--file 'permanent-local t)

(defvar-local drgnx-agent-pair--log nil
  "This buffer's drained changes while a paired chat works in its checkout, newest first: (COUNTER . CHANGES), the
changes (the hub's shape: 0-based `:start', `:old_len', `:inserted') that turned version COUNTER-1 into COUNTER.
Bounded: `drgnx-agent-pair-log-size' drains, or back to the hub's floor (`drgnx-agent-pair--floor'), whichever
reaches further.  Permanent.")
(put 'drgnx-agent-pair--log 'permanent-local t)

(defvar-local drgnx-agent-pair--from nil
  "The oldest version the log can shift a write from, or nil: no log.  A gap (a drain that returned `resync') moves it
to the gap's own version.  Permanent.")
(put 'drgnx-agent-pair--from 'permanent-local t)

(defvar-local drgnx-agent-pair--floor nil
  "The oldest version the hub still holds a read of this buffer's file at (sent with each `pair-apply'), or nil.")
(put 'drgnx-agent-pair--floor 'permanent-local t)

(defvar-local drgnx-agent-pair--reads nil
  "The versions handed out (reads, applies), newest first: (VERSION . STARTS), STARTS the 0-based offsets of the
text's line starts at VERSION, its length last; at most `drgnx-agent-pair-reads-size'.  A line edit's place.  Permanent.")
(put 'drgnx-agent-pair--reads 'permanent-local t)

(defvar drgnx-agent-pair--paired (make-hash-table :test 'equal)
  "Session id → its folder (a directory name), for the chats the hub's `agent' snapshots say are paired.  A buffer
keeps a change log only inside one of these folders.")

(defvar drgnx-agent-pair--pending nil
  "The buffers whose queue holds writes: the one variable `post-command-hook' reads before draining.")

(defvar drgnx-agent-pair--commands 0
  "How many commands run now, as the command hooks count them (`drgnx-agent-pair-command-step').")

(defvar drgnx-agent-pair--in-post-command nil
  "Non-nil while the safe slot runs from `post-command-hook' (the command loop copies `this-command' after it).")

(defvar drgnx-agent-pair--lock nil
  "Non-nil while the safe slot applies and saves: a drain entered again from inside (a filter, a save hook) waits.")

(defvar drgnx-agent-pair--answers (make-hash-table)
  "Write id → the `pair/answer' params sent for it; the last `drgnx-agent-pair-record-size' only.")

(defvar drgnx-agent-pair--order nil "The ids in `drgnx-agent-pair--answers', newest first.")

(defvar drgnx-agent-pair--unacked nil "The ids whose answer the hub has not acknowledged yet, newest first.")

;;;; The hub

(defun drgnx-agent-pair--send (method params &optional callback)
  "Ask the hub METHOD with PARAMS on the subscribed connection (CALLBACK gets (RESULT ERROR)).  Non-nil when asked;
nil while there is no connection (the next one gets the open set and the answers again)."
  (when (process-live-p drgnx-hub--events)
    (drgnx-hub--call-on drgnx-hub--events method params (or callback #'ignore))
    t))

(defun drgnx-agent-pair-answer-of (write)
  "The answer this Emacs gave WRITE (`pair/answer' params), or nil."
  (gethash write drgnx-agent-pair--answers))

(defun drgnx-agent-pair--answer (write params)
  "Answer WRITE with PARAMS (`pair/answer' without the id): recorded, then sent; kept until the hub acknowledges it."
  (unless (gethash write drgnx-agent-pair--answers)
    (push write drgnx-agent-pair--order)
    (let ((tail (nthcdr (1- drgnx-agent-pair-record-size) drgnx-agent-pair--order)))
      (when (cdr tail)
        (dolist (old (cdr tail))
          (remhash old drgnx-agent-pair--answers)
          (setq drgnx-agent-pair--unacked (delq old drgnx-agent-pair--unacked)))
        (setcdr tail nil))))
  (puthash write (append (list :write write) params) drgnx-agent-pair--answers)
  (unless (memq write drgnx-agent-pair--unacked) (push write drgnx-agent-pair--unacked))
  (drgnx-agent-pair--send-answer write))

(defun drgnx-agent-pair--send-answer (write)
  "Send WRITE's recorded answer; acknowledged once the hub answers it, whatever it says."
  (when-let* ((answer (gethash write drgnx-agent-pair--answers)))
    (drgnx-agent-pair--send "pair/answer" answer
                            (lambda (_result err)
                              (unless err (setq drgnx-agent-pair--unacked (delq write drgnx-agent-pair--unacked)))))))

;;;; The safe slot

(defun drgnx-agent-pair-command-step (n event depth macro)
  "The count of running commands N after EVENT (`pre' or `post' of a command) at recursion DEPTH, MACRO non-nil
while a keyboard macro runs.  A command inside the minibuffer or a recursive edit runs inside another one, so a
count, not a flag; `post-command-hook' also runs without a `pre' (when the command loop starts, a recursive edit
included), so the count never goes below 0, and the end of a command at depth 0 outside a macro means none runs (a
throw past the inner commands' ends cannot leave the count up)."
  (pcase event
    ('pre (1+ n))
    ('post (if (and (zerop depth) (not macro)) 0 (max 0 (1- n))))
    (_ n)))

(defun drgnx-agent-pair-slot-open-p (gate)
  "Whether the safe slot is open for GATE, a plist: no command runs (`:commands' 0), `:recursion' and `:minibuffer'
depth 0, no `:macro', no `:isearch', the history not `:resyncing' and the lock not `:locked'."
  (and (eql (plist-get gate :commands) 0) (eql (plist-get gate :recursion) 0) (eql (plist-get gate :minibuffer) 0)
       (not (plist-get gate :macro)) (not (plist-get gate :isearch)) (not (plist-get gate :resyncing))
       (not (plist-get gate :locked))))

(defun drgnx-agent-pair--resyncing-p ()
  "Whether the edit history is sending some buffer's whole text (the slot waits: the versions are moving)."
  (drgnx-history-resyncing-p))

(defun drgnx-agent-pair--gate ()
  "The safe slot's gate now (`drgnx-agent-pair-slot-open-p')."
  (list :commands drgnx-agent-pair--commands :recursion (recursion-depth) :minibuffer (minibuffer-depth)
        :macro executing-kbd-macro :isearch (bound-and-true-p isearch-mode)
        :resyncing (drgnx-agent-pair--resyncing-p) :locked drgnx-agent-pair--lock))

(defun drgnx-agent-pair--pre-command ()
  "`pre-command-hook': a command starts (one variable set)."
  (setq drgnx-agent-pair--commands
        (drgnx-agent-pair-command-step drgnx-agent-pair--commands 'pre (recursion-depth) executing-kbd-macro)))

(defun drgnx-agent-pair--post-command ()
  "`post-command-hook': a command ended; when a queue holds writes, the safe slot (`drgnx-agent-pair--drain')."
  (setq drgnx-agent-pair--commands
        (drgnx-agent-pair-command-step drgnx-agent-pair--commands 'post (recursion-depth) executing-kbd-macro))
  (when drgnx-agent-pair--pending
    (let ((drgnx-agent-pair--in-post-command t)) (drgnx-agent-pair--drain))))

(defun drgnx-agent-pair--soon ()
  "The slot's timer: at once, outside any command.  A wall timer, not an idle one: an idle timer started while Emacs is
already idle waits for the next pause, and the write would wait for your next key."
  (drgnx-timer-soon 'agent-pair-drain 0 #'drgnx-agent-pair--drain :owner 'tools/agent-pair))

(defun drgnx-agent-pair--drain ()
  "The safe slot: every queued write taken, oldest first, buffer by buffer, when the slot is open
\(`drgnx-agent-pair--gate'); nothing when it is shut (the next command's end or the timer tries again).
It runs from `post-command-hook' when a queue holds writes: the one bounded exception to post-command code reading
cached state only (measured by the `pair-apply-tick' probe).  Nothing in it asks."
  (when (and drgnx-agent-pair--pending (drgnx-agent-pair-slot-open-p (drgnx-agent-pair--gate)))
    (let ((drgnx-agent-pair--lock t))
      (while drgnx-agent-pair--pending
        (let ((buf (car (last drgnx-agent-pair--pending))))
          (setq drgnx-agent-pair--pending (delq buf drgnx-agent-pair--pending))
          (when (buffer-live-p buf)
            (with-current-buffer buf
              (while drgnx-agent-pair--queue
                (drgnx-agent-pair--take (pop drgnx-agent-pair--queue))))))))))

(defun drgnx-agent-pair--take (write)
  "WRITE, out of its queue: dropped when its deadline passed, else applied and, when it applied, saved in the same
slot (`drgnx-agent-pair--save').  From here on it is never dropped."
  (let ((id (plist-get write :write)))
    (if (> (drgnx-timer-now) (plist-get write :deadline))
        (drgnx-agent-pair--answer id (list :result "dropped" :reason "expired"))
      (let* ((clean (not (buffer-modified-p)))
             (answer (drgnx-agent-pair--apply write)))
        (drgnx-agent-pair--answer id (if (equal (plist-get answer :result) "applied")
                                         (append answer (drgnx-agent-pair--save clean))
                                       answer))))))

(defun drgnx-agent-pair--save (clean)
  "The save after an applied write, in the same slot: the answer's `:saved' and `:not_saved'.  A buffer that was
CLEAN before the apply is saved, so the agent's builds read what it wrote; one with your unsaved edits stays unsaved
\(the agent is told the disk has neither).  The save never asks (`drgnx-with-no-prompts'): a question it would have
asked, or an error, leaves the buffer unsaved and becomes `:not_saved' WHY.  `before-save-hook' runs as usual, here
rather than inside `save-buffer' (which turns its errors into messages and saves anyway): a hook that would ask
stops the save, any other error of it is a message, as Emacs has it."
  (if (not clean)
      (list :saved :false)
    (let* ((failed nil)
           (why (condition-case err
                    (drgnx-with-no-prompts
                      (condition-case e (run-hooks 'before-save-hook)
                        ((inhibited-interaction drgnx-would-prompt drgnx-prompt-in-automatic-path)
                         (signal (car e) (cdr e)))
                        (error (message "Before-save hook error: %S" e)))
                      (let ((before-save-hook nil) (save-silently t)) (save-buffer)))
                  (error (setq failed (error-message-string err))))))
      (cond ((and (or why failed) (buffer-modified-p)) (list :saved :false :not_saved (or why failed)))
            ((buffer-modified-p) (list :saved :false :not_saved "the save did not write the file"))
            (t (list :saved t))))))

(defconst drgnx-pair-apply 'drgnx-pair-apply
  "The command an apply leaves in `last-command': your next command is never the continuation of one before it (an
`undo' run, typing amalgamated into one undo group), so the agent's write stays an undo step of its own.")

(defvar drgnx-agent-pair-max-secs 0.05
  "Most seconds `replace-region-contents' spends finding the least change of one edit (it then replaces it whole).")

(defvar drgnx-agent-pair-apply-ticks nil
  "The `pair-apply-tick' probe: the milliseconds of the last applies that changed a buffer, newest first (the last
64).  The perf workloads read it; nothing else does.")

(defun drgnx-agent-pair--apply (write)
  "Apply WRITE to the current buffer, whole or not at all: its answer (`pair/answer' params without the id).
A read-only buffer and a file another Emacs locked refuse.  A file changed on disk is read again first when the
buffer has none of your edits (quietly, as the outside world's change: `drgnx-agent-pair--revert'), else refused.
The edits are shifted past your changes since the agent's read (`drgnx-agent-pair--shift'), an `edit_file' edit
found once in the text, none may touch the guard zone (`drgnx-agent-pair--guarded'); then they replace their
ranges as one undo group of the agent's own (`drgnx-agent-pair--replace').  Applied, the answer carries the buffer's
version after the write."
  (cond
   (buffer-read-only (list :result "refused" :reason "read-only"))
   ((and buffer-file-name (stringp (file-locked-p buffer-file-name))) (list :result "refused" :reason "locked"))
   ((and (not (verify-visited-file-modtime)) (or (buffer-modified-p) (not (drgnx-agent-pair--revert))))
    (list :result "refused" :reason "changed-on-disk"))
   (t
    (let ((ranges (drgnx-agent-pair--place (plist-get write :edits) (plist-get write :version))))
      (if (eq (car-safe ranges) :refused)
          (cdr ranges)
        (drgnx-agent-pair--replace ranges (plist-get write :session))
        (drgnx-agent-pair--applied))))))

(defun drgnx-agent-pair--revert ()
  "Read the visited file again into this buffer, which has none of your edits: `insert-file-contents' replacing the
text (markers and point kept where the text is), never `revert-buffer' (its hooks and questions), as the outside
world's change (origin `external:disk'), asking nothing.  Non-nil when it was read."
  (and (null (condition-case err
                 (drgnx-with-no-prompts
                   (drgnx-history-with-origin "external:disk"
                     (save-restriction
                       (widen)
                       ;; the disk's time first: reading it is no supersession threat to ask about
                       (set-visited-file-modtime)
                       (insert-file-contents buffer-file-name nil nil nil 'replace))))
               (error (error-message-string err))))
       (progn (set-visited-file-modtime) (set-buffer-modified-p nil) t)))

(defun drgnx-agent-pair--replace (ranges session)
  "RANGES ((START END TEXT) ...) replaced by their texts, as SESSION's change (origin \"agent:SESSION\" in the edit
history): markers first, then each range from the last to the first through `replace-region-contents' (point and
your markers stay where their text is), all one change group amalgamated into one undo step with boundaries before
and after; the history's ring drained right after (the answer's version), so the origin is sent before a resync could
lose it.  Then the command loop is told an apply ran (`drgnx-pair-apply'): from `post-command-hook' through
`this-command', which the loop copies to `last-command' after the hook; from the timer, `last-command' itself."
  (let ((start (float-time))
        (marks (mapcar (lambda (r) (list (copy-marker (nth 0 r)) (copy-marker (nth 1 r) t) (nth 2 r))) ranges))
        (group nil) (done nil))
    (undo-boundary)
    (setq group (prepare-change-group))
    (unwind-protect
        (progn
          (activate-change-group group)
          (drgnx-history-with-origin (concat "agent:" (or session "?"))
            (dolist (m (sort marks (lambda (a b) (> (car a) (car b)))))
              (replace-region-contents (nth 0 m) (nth 1 m) (nth 2 m) drgnx-agent-pair-max-secs)))
          (undo-amalgamate-change-group group)
          (setq done t))
      (if done (accept-change-group group) (cancel-change-group group))
      (dolist (m marks) (set-marker (nth 0 m) nil) (set-marker (nth 1 m) nil)))
    (undo-boundary)
    (if drgnx-agent-pair--in-post-command
        (setq this-command drgnx-pair-apply)
      (setq last-command drgnx-pair-apply))
    (push (* 1000 (- (float-time) start)) drgnx-agent-pair-apply-ticks)
    (let ((tail (nthcdr 63 drgnx-agent-pair-apply-ticks))) (when tail (setcdr tail nil)))))

(defun drgnx-agent-pair--applied ()
  "The answer of an applied write: the buffer's version now, its line starts kept (the hub takes a whole write's text
as the agent's read at that version)."
  (let ((v (drgnx-agent-pair-version)))
    (if v (list :result "applied" :version v) (list :result "applied"))))

(defun drgnx-agent-pair--place (edits version)
  "EDITS (the hub's, based on VERSION) as ranges of the current buffer, (START END TEXT) each, or (:refused . ANSWER):
shifted past the changes since VERSION, a `replace' edit found once in the text, none in the guard zone."
  (let ((shifted (drgnx-agent-pair--shift edits version)))
    (cond
     ((eq shifted 'stale) (cons :refused (list :result "refused" :reason "gap")))
     ((eq (car-safe shifted) 'conflict)
      (cons :refused (list :result "refused" :reason "overlap" :lines (vconcat (cdr shifted)))))
     (t
      (catch 'refused
        (let ((ranges
               (mapcar (lambda (e)
                         (if (eq (car e) :replace)
                             (let ((at (drgnx-agent-pair--find (nth 1 e))))
                               (unless (integerp at)
                                 (throw 'refused (cons :refused (list :result "refused" :reason (symbol-name at)))))
                               (list at (+ at (length (nth 1 e))) (nth 2 e)))
                           e))
                       shifted)))
          (let ((lines (drgnx-agent-pair--guarded ranges)))
            (if lines
                (cons :refused (list :result "refused" :reason "guard" :lines (vconcat lines)))
              ranges))))))))

(defun drgnx-agent-pair--find (old)
  "Where OLD is in the current buffer's text: its start, or `no-match', or `several'."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (if (not (let ((case-fold-search nil)) (search-forward old nil t)))
          'no-match
        (let ((at (match-beginning 0)))
          (goto-char (1+ at))
          (if (let ((case-fold-search nil)) (search-forward old nil t)) 'several at))))))

;;;; The change log and the shift

(defun drgnx-agent-pair--logging-p (buffer)
  "Whether BUFFER's file is inside the folder of a paired chat (`drgnx-agent-pair--paired')."
  (let ((file (buffer-file-name buffer)))
    (and file (catch 'in
                (maphash (lambda (_s dir) (when (string-prefix-p dir file) (throw 'in t))) drgnx-agent-pair--paired)
                nil))))

(defun drgnx-agent-pair--drop-log ()
  (setq drgnx-agent-pair--log nil drgnx-agent-pair--from nil drgnx-agent-pair--floor nil))

(defun drgnx-agent-pair--drained (buffer counter changes)
  "`drgnx-history-drained-functions': BUFFER's drain COUNTER sent CHANGES (or `resync', a gap).  Kept in its log while
a paired chat works in its checkout; a buffer outside any loses its log."
  (with-current-buffer buffer
    (cond ((not (drgnx-agent-pair--logging-p buffer)) (when drgnx-agent-pair--from (drgnx-agent-pair--drop-log)))
          ((or (eq changes 'resync) (null drgnx-agent-pair--from))
           ;; a gap, or the log's start: nothing older than this version can be shifted
           (setq drgnx-agent-pair--log nil drgnx-agent-pair--from counter))
          (t (push (cons counter changes) drgnx-agent-pair--log)
             (drgnx-agent-pair--trim)))))

(defun drgnx-agent-pair--trim ()
  "The log back to its bound: `drgnx-agent-pair-log-size' drains, more while they are newer than the hub's floor."
  (let ((tail (nthcdr (1- drgnx-agent-pair-log-size) drgnx-agent-pair--log)))
    (when (cdr tail)
      (let ((floor drgnx-agent-pair--floor))
        (while (and (cdr tail) floor (> (car (cadr tail)) floor)) (setq tail (cdr tail)))
        (when (cdr tail)
          (setq drgnx-agent-pair--from (car (cadr tail)))
          (setcdr tail nil))))))

(defun drgnx-agent-pair--starts (text)
  "The 0-based offsets of TEXT's line starts, its length last, as a vector."
  (let ((starts (list 0)) (at 0))
    (while (setq at (string-search "\n" text at))
      (setq at (1+ at))
      (push at starts))
    (unless (= (car starts) (length text)) (push (length text) starts))
    (vconcat (nreverse starts))))

(defun drgnx-agent-pair--remember (version)
  "Keep the current buffer's line starts as VERSION's (`drgnx-agent-pair--reads'); with a paired chat in its checkout
and no log yet, the log starts at VERSION."
  (when version
    (when (and (null drgnx-agent-pair--from) (drgnx-agent-pair--logging-p (current-buffer)))
      (setq drgnx-agent-pair--from version drgnx-agent-pair--log nil))
    (unless (assq version drgnx-agent-pair--reads)
      (push (cons version (save-restriction (widen) (drgnx-agent-pair--starts (buffer-substring-no-properties
                                                                               (point-min) (point-max)))))
            drgnx-agent-pair--reads)
      (let ((tail (nthcdr (1- drgnx-agent-pair-reads-size) drgnx-agent-pair--reads)))
        (when tail (setcdr tail nil))))))

(defun drgnx-agent-pair--since (version now)
  "The logged changes from VERSION to NOW, oldest first, or `stale' when the log does not reach back to VERSION."
  (cond ((eql version now) nil)
        ((not (and drgnx-agent-pair--from (integerp version) (integerp now) (>= version drgnx-agent-pair--from) (< version now)))
         'stale)
        (t (let ((out nil))
             (dolist (e drgnx-agent-pair--log)
               (when (> (car e) version) (setq out (append (cdr e) out))))
             out))))

(defun drgnx-agent-pair--map (s e change)
  "The range S..E (0-based) after CHANGE (the hub's shape), as (S . E), or nil when CHANGE meets the range: a change
inside it, or an insertion at its start when it is not empty."
  (let* ((cs (plist-get change :start)) (ol (plist-get change :old_len))
         (ce (+ cs ol)) (d (- (length (plist-get change :inserted)) ol)))
    (cond ((zerop ol)
           (cond ((< cs s) (cons (+ s d) (+ e d)))
                 ((and (= cs s) (> e s)) nil)
                 ((and (> cs s) (< cs e)) nil)
                 (t (cons s e))))
          ((<= ce s) (cons (+ s d) (+ e d)))
          ((>= cs e) (cons s e))
          (t nil))))

(defun drgnx-agent-pair--loose (pos change endp)
  "POS after CHANGE, where it meets it: the change's start, or (ENDP) the end of what it inserted."
  (let* ((cs (plist-get change :start)) (ol (plist-get change :old_len)) (n (length (plist-get change :inserted))))
    (cond ((< pos cs) pos)
          ((>= pos (+ cs ol)) (if (and (= pos cs) (zerop ol) (not endp)) pos (+ pos (- n ol))))
          (endp (+ cs n))
          (t cs))))

(defun drgnx-agent-pair--lines-of (s e)
  "The lines (A B) of the current buffer the 0-based range S..E covers."
  (save-restriction
    (widen)
    (let* ((lo (min (point-max) (1+ s))) (hi (min (point-max) (max lo e))))
      (list (line-number-at-pos lo t) (line-number-at-pos hi t)))))

(defun drgnx-agent-pair--shift (edits version)
  "EDITS (the hub's, based on VERSION) shifted to the current buffer: a list of (START END TEXT) buffer ranges and
\(:replace OLD NEW) for an `edit_file' edit (found at apply time); or (conflict A B) when your changes since VERSION
meet an edit (the lines it would change now), or `stale' when the log does not reach back to VERSION.  The buffer's
ring is drained first, so the log holds every change up to now."
  (let* ((now (drgnx-agent-pair-version))
         (lines-p (cl-some (lambda (e) (equal (plist-get e :kind) "lines")) edits))
         (since (and lines-p version (drgnx-agent-pair--since version now)))
         (starts (and lines-p (if version (cdr (assq version drgnx-agent-pair--reads))
                                (save-restriction (widen) (drgnx-agent-pair--starts (buffer-string)))))))
    (cond
     ((and lines-p (or (eq since 'stale) (null starts))) 'stale)
     (t
      (catch 'conflict
        (mapcar
         (lambda (edit)
           (if (not (equal (plist-get edit :kind) "lines"))
               (list :replace (plist-get edit :old) (plist-get edit :new))
             (let* ((n (length starts)) (line (plist-get edit :line))
                    (s (aref starts (min (1- n) (1- line))))
                    (e (aref starts (min (1- n) (+ (1- line) (plist-get edit :delete)))))
                    (range (cons s e)) (rest since))
               (while (and rest range)
                 (setq range (drgnx-agent-pair--map (car range) (cdr range) (car rest)))
                 (unless range
                   (let ((ls s) (le e))
                     (dolist (c since) (setq ls (drgnx-agent-pair--loose ls c nil) le (drgnx-agent-pair--loose le c t)))
                     (throw 'conflict (cons 'conflict (drgnx-agent-pair--lines-of ls le)))))
                 (setq rest (cdr rest)))
               (list (1+ (car range)) (1+ (cdr range)) (plist-get edit :text)))))
         edits))))))

;;;; The guard zone

(defun drgnx-agent-pair--guard (&optional buffer)
  "BUFFER's (default the current one) guard zone as line intervals ((A . B) ...): the line at point ±1 in every
window showing it, and its active region."
  (let* ((b (or buffer (current-buffer))) (zone nil))
    (with-current-buffer b
      (save-restriction
        (widen)
        (dolist (w (get-buffer-window-list b nil t))
          (let ((l (line-number-at-pos (window-point w) t))) (push (cons (max 1 (1- l)) (1+ l)) zone)))
        (when (and mark-active (mark t))
          (push (cons (line-number-at-pos (min (point) (mark t)) t) (line-number-at-pos (max (point) (mark t)) t))
                zone))))
    zone))

(defun drgnx-agent-pair--guarded (ranges)
  "The lines (A B) of the first of RANGES ((START END TEXT) buffer ranges) that touches the guard zone, or nil."
  (let ((zone (drgnx-agent-pair--guard)))
    (when zone
      (catch 'hit
        (dolist (r ranges)
          (let* ((a (line-number-at-pos (nth 0 r) t))
                 (b (line-number-at-pos (max (nth 0 r) (1- (nth 1 r))) t)))
            (dolist (z zone)
              (when (and (<= a (cdr z)) (>= b (car z))) (throw 'hit (list a b))))))
        nil))))

;;;; The hub's events

(defun drgnx-agent-pair--kind (&optional buffer)
  "How BUFFER (default the current one) has its file open, as the hub spells it: remote, large or normal."
  (with-current-buffer (or buffer (current-buffer))
    (cond ((file-remote-p buffer-file-name) "remote")
          ((drgnx-large-file-p) "large")
          (t "normal"))))

(defun drgnx-agent-pair--arrived (data)
  "`pair-apply' DATA: the write queued in the buffer visiting its file, its deadline its `ttl_ms' from now on this
Emacs's clock; the safe slot applies it.  Never applied here.  No buffer has the file: refused at once."
  (let* ((write (plist-get data :write)) (file (plist-get data :file))
         (buf (and (stringp file) (find-buffer-visiting file))))
    (cond ((not (natnump write)) nil)
          ((not buf) (drgnx-agent-pair--answer write (list :result "refused" :reason "not-open")))
          ((not (equal (drgnx-agent-pair--kind buf) "normal"))
           (drgnx-agent-pair--answer write (list :result "refused"
                                                 :reason "this file is open as a large or remote file; pair edits are off for it")))
          (t (let ((ttl (plist-get data :ttl_ms)))
               (with-current-buffer buf
                 (when (natnump (plist-get data :floor)) (setq drgnx-agent-pair--floor (plist-get data :floor)))
                 (setq drgnx-agent-pair--queue
                       (nconc drgnx-agent-pair--queue
                              (list (append (list :deadline (+ (drgnx-timer-now) (/ (if (numberp ttl) ttl 0) 1000.0)))
                                            data))))))
             (unless (memq buf drgnx-agent-pair--pending) (push buf drgnx-agent-pair--pending))
             (drgnx-agent-pair--soon)))))

(defun drgnx-agent-pair-drop (session reason)
  "Drop every write of SESSION still queued (`pair-drop': pair off, the wheel taken, the matrix made it never), each
answered `dropped' with REASON.  A write whose apply started is out of its queue: it ends as its apply does."
  (dolist (buf (buffer-list))
    (when (buffer-local-value 'drgnx-agent-pair--queue buf)
      (with-current-buffer buf
        (setq drgnx-agent-pair--queue
              (cl-remove-if (lambda (w)
                              (when (equal (plist-get w :session) session)
                                (drgnx-agent-pair--answer (plist-get w :write) (list :result "dropped" :reason reason))
                                t))
                            drgnx-agent-pair--queue))))))

(defun drgnx-agent-pair--queued-p (write file)
  "Whether WRITE waits in the queue of the buffer visiting FILE."
  (let ((buf (and (stringp file) (find-buffer-visiting file))))
    (and buf (cl-find write (buffer-local-value 'drgnx-agent-pair--queue buf)
                      :key (lambda (w) (plist-get w :write))))))

(defun drgnx-agent-pair--reconcile (data)
  "`pair-reconcile' DATA: the hub has no answer for its write.  Answered from the record: its answer again; a write
still queued is answered when the slot takes it; a write this Emacs never had was not applied (`dropped')."
  (let ((write (plist-get data :write)))
    (cond ((not (natnump write)) nil)
          ((gethash write drgnx-agent-pair--answers)
           (unless (memq write drgnx-agent-pair--unacked) (push write drgnx-agent-pair--unacked))
           (drgnx-agent-pair--send-answer write))
          ((drgnx-agent-pair--queued-p write (plist-get data :file)) nil)
          (t (drgnx-agent-pair--answer write (list :result "dropped" :reason "not-applied"))))))

(defun drgnx-agent-pair-version ()
  "The current buffer's version as a pair read gives it: its drain counter in the edit history after a drain
\(`drgnx-history-drain-now'), its line starts kept; nil when the history does not track it (a whole-file write then
cannot be shifted, and is refused)."
  (let ((v (drgnx-history-drain-now)))
    (drgnx-agent-pair--remember v)
    v))

(defun drgnx-agent-pair--read (data)
  "`pair-read' DATA: the text of the buffer that has its file open, unsaved edits included, with its version; a file
no normal buffer has is `not-open' (the hub reads the disk)."
  (let* ((req (plist-get data :req)) (file (plist-get data :file))
         (buf (and (stringp file) (find-buffer-visiting file))))
    (when (natnump req)
      (drgnx-agent-pair--send
       "pair/read-answer"
       (if (and buf (equal (drgnx-agent-pair--kind buf) "normal"))
           (with-current-buffer buf
             (save-restriction
               (widen)
               (let ((v (drgnx-agent-pair-version)))
                 (append (list :req req :text (buffer-substring-no-properties (point-min) (point-max)))
                         (and v (list :version v))))))
         (list :req req :error "not-open"))))))

(defun drgnx-agent-pair--event (event data)
  "`drgnx-hub-event-functions': the pair door's events, from a hub that proved itself.  Each one queues, answers or
drops; none applies or asks."
  (when (and (member event '("pair-apply" "pair-read" "pair-drop" "pair-reconcile" "agent"))
             (processp drgnx-hub--event-conn) (process-get drgnx-hub--event-conn :drgnx-proven))
    (pcase event
      ("pair-apply" (drgnx-agent-pair--arrived data))
      ("pair-read" (drgnx-agent-pair--read data))
      ("pair-drop" (drgnx-agent-pair-drop (plist-get data :session) (or (plist-get data :reason) "pair-off")))
      ("pair-reconcile" (drgnx-agent-pair--reconcile data))
      ("agent" (drgnx-agent-pair--snapshot (plist-get data :id) (plist-get data :session))))))

(defun drgnx-agent-pair--snapshot (id snap)
  "Session ID's `agent' snapshot SNAP: paired (and live, with an ordinal) in a folder, its buffers there keep a change
log; no longer, the logs of buffers in no paired folder go."
  (when (stringp id)
    (let ((dir (plist-get snap :cwd)) (was (gethash id drgnx-agent-pair--paired)))
      (if (and (eq (plist-get snap :paired) t) (plist-get snap :ordinal) (stringp dir))
          (puthash id (file-name-as-directory (expand-file-name dir)) drgnx-agent-pair--paired)
        (remhash id drgnx-agent-pair--paired)
        (when was
          (dolist (b (buffer-list))
            (when (and (buffer-local-value 'drgnx-agent-pair--from b) (not (drgnx-agent-pair--logging-p b)))
              (with-current-buffer b (drgnx-agent-pair--drop-log)))))))))

;;;; The open set

(defun drgnx-agent-pair--open-files ()
  "Every file buffer, as `pair/open-set' lists them: a vector of (:file F :kind K)."
  (let ((files nil))
    (dolist (b (buffer-list))
      (when (buffer-file-name b)
        (with-current-buffer b (setq drgnx-agent-pair--file buffer-file-name))
        (push (list :file (buffer-file-name b) :kind (drgnx-agent-pair--kind b)) files)))
    (vconcat (nreverse files))))

(defun drgnx-agent-pair--send-open-set ()
  "Tell the hub every file this Emacs has open, replacing what it held for this editor."
  (drgnx-agent-pair--send "pair/open-set" (list :files (drgnx-agent-pair--open-files))))

(defun drgnx-agent-pair--opened ()
  "`find-file-hook': the hub learns the file is open here."
  (when buffer-file-name
    (setq drgnx-agent-pair--file buffer-file-name)
    (drgnx-agent-pair--send "pair/open" (list :file buffer-file-name :kind (drgnx-agent-pair--kind)))))

(defun drgnx-agent-pair--closed ()
  "`kill-buffer-hook': the hub learns the file is closed; the writes queued for it are refused (one variable read
for any other buffer)."
  (when drgnx-agent-pair--file
    (drgnx-agent-pair--send "pair/closed" (list :file drgnx-agent-pair--file))
    (setq drgnx-agent-pair--file nil)
    (dolist (w (prog1 drgnx-agent-pair--queue (setq drgnx-agent-pair--queue nil)))
      (drgnx-agent-pair--answer (plist-get w :write) (list :result "refused" :reason "not-open")))
    (setq drgnx-agent-pair--pending (delq (current-buffer) drgnx-agent-pair--pending))))

(defun drgnx-agent-pair--renamed ()
  "`after-set-visited-file-name-hook' (a rename, `write-file'): the old name closed, the new one open."
  (unless (equal drgnx-agent-pair--file buffer-file-name)
    (when drgnx-agent-pair--file (drgnx-agent-pair--send "pair/closed" (list :file drgnx-agent-pair--file)))
    (setq drgnx-agent-pair--file buffer-file-name)
    (when buffer-file-name
      (drgnx-agent-pair--send "pair/open" (list :file buffer-file-name :kind (drgnx-agent-pair--kind))))))

(defun drgnx-agent-pair--connected ()
  "`drgnx-hub-connected-functions': a new subscription gets the whole open set, then the answers not acknowledged."
  (drgnx-agent-pair--send-open-set)
  (dolist (w (reverse drgnx-agent-pair--unacked)) (drgnx-agent-pair--send-answer w)))

;;;; The toggle

(defconst drgnx-agent-pair-proven '("claude" "gemini")
  "The providers whose pair proof row is green: their own edit tools are off and every edit shape reaches the door.")

(defconst drgnx-agent-pair-not-yet
  '(("codex" . "its read-only mode lock is not proven to keep its own edits off yet")
    ("kimi" . "its lock, with plan mode refused, is not proven yet")
    ("deepseek" . "its lock and its ask plugin are not proven yet"))
  "Why Pair is not offered yet for a provider whose pair proof row is not green: (PROVIDER . REASON).")

(defun drgnx-agent-pair-primitives-p ()
  "Whether this Emacs has the edit history's primitives pair mode needs (Nidhogg .6 with Glitnir)."
  (and (fboundp 'nidhogg-history-track) (fboundp 'nidhogg-history-drain)))

(defun drgnx-agent-pair--name (snapshot)
  (or (plist-get snapshot :name) (plist-get snapshot :profile) (plist-get snapshot :id)))

(defun drgnx-agent-pair-toggle-state (snapshot cell primitives)
  "What the Pair toggle of the chat SNAPSHOT (an `agents/list' row) shows: (:on ON :can CAN :why WHY :waiting TEXT).
CELL is the chat's `chat.project-edit' verdict (\"allow\", \"ask\", \"never\"), PRIMITIVES whether this Emacs has the
history primitives.  Turning Pair off can always be done; turning it on cannot, with WHY, where the chat is not in a
project, the cell is never, the primitives are missing or the provider's pair proof is not green.  TEXT: \"NAME is
waiting for lines A–B of FILE\" while the chat waits on your lines."
  (let* ((on (eq (plist-get snapshot :paired) t))
         (provider (plist-get snapshot :provider))
         (why (unless on
                (cond ((not (plist-member snapshot :paired)) "Pair is only for a chat in your project")
                      ((equal cell "never")
                       "Pair is off: the matrix's chat.project-edit is never for this chat (its preset or a column)")
                      ((not primitives) "Pair needs Nidhogg .6 with Glitnir")
                      ((not (member provider drgnx-agent-pair-proven))
                       (concat "Pair is not available for this agent yet: "
                               (or (cdr (assoc provider drgnx-agent-pair-not-yet))
                                   "nothing proves yet that its own edit tools are off"))))))
         (waiting (plist-get snapshot :waiting))
         (lines (plist-get waiting :lines)))
    (list :on on :can (null why) :why why
          :waiting (and waiting
                        (format "%s is waiting for %s of %s" (drgnx-agent-pair--name snapshot)
                                (pcase lines
                                  (`(,a ,b) (if (equal a b) (format "line %s" a) (format "lines %s–%s" a b)))
                                  (_ "you"))
                                (file-name-nondirectory (or (plist-get waiting :file) "")))))))

(defun drgnx-agent-pair-set (session on &optional callback)
  "Ask the hub to turn pair mode ON or off for chat SESSION (`agents/pair'); CALLBACK gets (RESULT ERROR).  Turning it
off cancels nothing: the chat's writes are refused from then on and the ones queued here are dropped."
  (drgnx-hub-call "agents/pair" (list :id session :on (if on t :false)) (or callback #'ignore)))

(defun drgnx-agent-pair-toggle (&optional session)
  "Agents: Pair — turn pair mode on or off for a chat in your project (SESSION, else the one chat, else chosen).
When it cannot be turned on, says why; a chat waiting on your lines says which."
  (interactive)
  (let* ((chats (cl-remove-if-not (lambda (s) (plist-member s :paired))
                                  (plist-get (drgnx-hub-call-sync "agents/list" nil) :sessions)))
         (snap (cond (session (cl-find session chats :key (lambda (s) (plist-get s :id)) :test #'equal))
                     ((null (cdr chats)) (car chats))
                     (t (let ((names (mapcar (lambda (s) (cons (drgnx-agent-pair--name s) s)) chats)))
                          (cdr (assoc (completing-read "Pair for chat: " names nil t) names)))))))
    (unless snap (user-error "No chat in a project to pair"))
    (let* ((provider (plist-get snap :provider)) (profile (plist-get snap :profile))
           (cell (plist-get (drgnx-hub-call-sync
                             "matrix/check"
                             (list :action "chat.project-edit"
                                   :who (append (list :role "chat") (and provider (list :provider provider))
                                                (and profile (list :agent profile)))))
                            :verdict))
           (state (drgnx-agent-pair-toggle-state snap cell (drgnx-agent-pair-primitives-p)))
           (name (drgnx-agent-pair--name snap))
           (on (not (plist-get state :on)))
           (waiting (plist-get state :waiting)))
      (if (not (plist-get state :can))
          (message "%s" (plist-get state :why))
        (drgnx-agent-pair-set
         (plist-get snap :id) on
         (lambda (_result err)
           (message "%s%s"
                    (cond (err (format "Pair: %s" err))
                          (on (format "Pair is on for %s" name))
                          (t (format "Pair is off for %s; nothing it was doing is cancelled" name)))
                    (if waiting (concat " · " waiting) ""))))))))

;;;; The module

(defun drgnx-agent-pair--unpair-all ()
  "Turn pair off for every paired chat (the module goes off): the hub closes their doors; nothing is cancelled."
  (drgnx-agent-pair--send
   "agents/list" nil
   (lambda (result _err)
     (dolist (s (plist-get result :sessions))
       (when (eq (plist-get s :paired) t)
         (drgnx-agent-pair--send "agents/pair" (list :id (plist-get s :id) :on :false)))))))

(defun drgnx-agent-pair--setup ()
  (drgnx-command-define 'agents-pair :category "Agents" :title "Pair: Turn On or Off" :command #'drgnx-agent-pair-toggle
                        :doc "A chat in your project edits the files you have open, live (pair mode); off cancels nothing")
  (add-hook 'drgnx-hub-event-functions #'drgnx-agent-pair--event)
  (add-hook 'drgnx-hub-connected-functions #'drgnx-agent-pair--connected)
  (add-hook 'find-file-hook #'drgnx-agent-pair--opened)
  (add-hook 'kill-buffer-hook #'drgnx-agent-pair--closed)
  (add-hook 'after-set-visited-file-name-hook #'drgnx-agent-pair--renamed)
  (add-hook 'pre-command-hook #'drgnx-agent-pair--pre-command)
  (add-hook 'post-command-hook #'drgnx-agent-pair--post-command)
  (add-hook 'drgnx-history-drained-functions #'drgnx-agent-pair--drained)
  (drgnx-agent-pair--send-open-set))

(defun drgnx-agent-pair--teardown ()
  "The module goes off: the hub routes nothing here any more (an empty open set), every queued write is dropped
\(`dropped', reason `pair-off'), pair goes off for the paired chats (the hub closes their doors), the record goes.
Nothing is cancelled and nothing it applied is undone."
  (drgnx-agent-pair--send "pair/open-set" (list :files []))
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (dolist (w (prog1 drgnx-agent-pair--queue (kill-local-variable 'drgnx-agent-pair--queue)))
        (drgnx-agent-pair--answer (plist-get w :write) (list :result "dropped" :reason "pair-off")))
      (kill-local-variable 'drgnx-agent-pair--file)
      (dolist (v '(drgnx-agent-pair--log drgnx-agent-pair--from drgnx-agent-pair--floor drgnx-agent-pair--reads))
        (kill-local-variable v))))
  (remove-hook 'drgnx-history-drained-functions #'drgnx-agent-pair--drained)
  (clrhash drgnx-agent-pair--paired)
  (drgnx-agent-pair--unpair-all)
  (drgnx-timer-cancel 'agent-pair-drain)
  (setq drgnx-agent-pair--pending nil drgnx-agent-pair--commands 0 drgnx-agent-pair--lock nil
        drgnx-agent-pair--order nil drgnx-agent-pair--unacked nil)
  (clrhash drgnx-agent-pair--answers))

(drgnx-module-define 'tools/agent-pair
                     :doc "Agents: pair mode — a paired chat's writes to the files you have open, applied between your commands"
                     :stage 'idle
                     :setup #'drgnx-agent-pair--setup
                     :teardown #'drgnx-agent-pair--teardown)

(provide 'drgnx-agent-pair)
;;; drgnx-agent-pair.el ends here
