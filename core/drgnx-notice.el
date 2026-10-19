;;; drgnx-notice.el --- One notice model: events, conditions and per-source attention sets -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The one way drgnx tells the user something.  A producer posts a notice (`drgnx-notify'): an `event' (something
;; happened; ages out of a ring) or a `condition' (something is wrong now; the producer clears it).  A source of
;; things waiting on the user replaces its whole set of `attention' items (`drgnx-notice-set'), and the one "needs
;; you" count is the size of the union of those sets.  Readers (the status bar, the cockpit, the Notices list) read
;; cached counts memoised on `drgnx-notice-tick'; routes (echo, desktop, the session file) follow the model through
;; `drgnx-notice-functions', the synchronous `now' lane.  Nothing here prompts or raises from an automatic path: hook
;; errors are recorded.  Core: it requires nothing in wb/ or modules/.  See docs/develop/core.md, "Notices".

;;; Code:
(require 'cl-lib)
(require 'drgnx-guard)
(require 'drgnx-modules-record)
(require 'drgnx-timer)

;;;; Vocabulary

(defconst drgnx-notice-severities '(info warn fail)
  "Severities of a notice: `info' worth knowing, `warn' degraded (drgnx works around it), `fail' something you
expect does not work.  An attention item's severity is `needs-you'.")

(defconst drgnx-notice-lives '(event condition attention)
  "Lifetimes of a notice: `event' (ages out of the ring), `condition' (until its producer clears it), `attention'
\(until its source's next set leaves it out; only `drgnx-notice-set' makes them).")

(defconst drgnx-notice-core-sources
  '(modules keys hooks commands bus guard hub config agents timers terminal wb store render notice)
  "Sources that need no `drgnx-notice-define-source': core and the workbench's own producers.")

(defcustom drgnx-notice-event-limit 200
  "How many events the model keeps; the oldest goes when a new one comes."
  :type 'natnum :group 'drgnx)

(defcustom drgnx-notice-condition-limit 100
  "How many conditions one source may hold.  Past it, a new one only updates the source's \"and N more\"
condition."
  :type 'natnum :group 'drgnx)

;;;; State

(defvar drgnx-notice--table (make-hash-table :test #'equal)
  "KEY (SOURCE . ID) → notice, for events and conditions.  Bounded: events by `drgnx-notice-event-limit', conditions
by `drgnx-notice-condition-limit' per source.")

(defvar drgnx-notice--events nil "Keys of the events, newest first (the ring).")

(defvar drgnx-notice--conditions (make-hash-table :test #'eq)
  "SOURCE → the number of its conditions in the table (the cap's count).")

(defvar drgnx-notice--more (make-hash-table :test #'eq)
  "SOURCE → the ids (a hash table ID → t) its \"and N more\" condition counts, while it has one.  An id past the
cap counts once, however often it is posted again.")

(defvar drgnx-notice--sources (make-hash-table :test #'eq)
  "Defined (non-core) sources: SOURCE → (:title T :command C :stale S :owner MODULE :rank R).  R orders them by
definition, after the core sources.")

(defvar drgnx-notice--rank 0 "The rank the last newly defined source got.")

(defvar drgnx-notice--stale nil "(SOURCE . SECS) of the defined sources with `:stale' (most have none).")

(defvar drgnx-notice--sets (make-hash-table :test #'eq)
  "SOURCE → its attention items (notices), or `:unknown'.")

(defvar drgnx-notice--index (make-hash-table :test #'eq)
  "SOURCE → (ITEMS . TABLE) for each source whose set is a list: ITEMS as it gave them last, TABLE a hash table
ID → (ITEM NOTICE . MARK), ITEM the plist it gave for ID, NOTICE the item as the model holds it, MARK the
`drgnx-notice--gen' of the last replace that reached it.  Updated in place.")

(defvar drgnx-notice--heard (make-hash-table :test #'eq) "SOURCE → the time of its last `drgnx-notice-set'.")

(defvar drgnx-notice--union (make-hash-table :test #'equal)
  "ID → the attention item counted for it: of the sources holding ID, the item with the later :at, on a tie the
source defined first.  Updated, id by id, when a set changes.")

(defvar drgnx-notice--needs-you 0 "The size of `drgnx-notice--union'.")

(defvar drgnx-notice--scoped (make-hash-table :test #'equal)
  "SCOPE → its needs-you count at `drgnx-notice--scoped-tick'.  Emptied whenever the tick moves on.")

(defvar drgnx-notice--scoped-tick -1 "The tick `drgnx-notice--scoped' was counted at.")

(defvar drgnx-notice--problems (cons 0 0)
  "(WARN . FAIL): the conditions of those severities that are not dismissed.  Replaced, never changed in place.")

(defvar drgnx-notice--dismissed (make-hash-table :test #'equal)
  "KEY → the text dismissed.  Kept when the notice is cleared, so it stays hidden when it comes back with the same
text; dropped when it comes back with other text, falls off the ring, or its source is undefined.")

(defvar drgnx-notice--tick 0 "Bumped on every change of the model, never on a repeat.")

(defvar drgnx-notice-functions nil
  "Abnormal hook: the `now' lane.  Each function is called with CHANGE, a plist (:op OP :key KEY :source SOURCE
:notice NOTICE :added IDS :removed IDS) holding only its non-nil keys, OP one of `post' `clear' `set' `unknown'
`dismiss' `undefine'.  NOTICE is the plist the model holds: read it, never change it.  Synchronous, inside `drgnx-automatic' with `inhibit-interaction': cheap reactions only (set
a flag, `force-mode-line-update', start a timer).  An error is recorded in `drgnx-notice--hook-errors'; a change
made meanwhile is queued, never recursive.")

(defvar drgnx-notice--hook-errors nil "(FUNCTION MESSAGE TIME) of failed hook calls, newest first; at most 20.")

(defvar drgnx-notice--queue nil "Changes made while the hook runs, newest first.")

(defvar drgnx-notice--running nil "Non-nil while `drgnx-notice-functions' runs.")

;;;; Checks

(defun drgnx-notice--readable-p (x)
  "Non-nil if X is data that prints readably: symbols, numbers, strings and conses of them."
  (let ((ok t))
    (while (and ok (consp x))
      (setq ok (drgnx-notice--readable-p (car x)) x (cdr x)))
    (and ok (or (symbolp x) (numberp x) (stringp x)))))

(defun drgnx-notice--check-command (command)
  "Signal unless COMMAND is nil, a symbol (a registry id or a command), or (FN . ARGS): FN a symbol, ARGS data."
  (unless (or (symbolp command)
              (and (consp command) (car command) (symbolp (car command))
                   (not (memq (car command) '(lambda closure)))
                   (drgnx-notice--readable-p (cdr command))))
    (signal 'wrong-type-argument (list 'drgnx-notice-command command))))

(defun drgnx-notice--check-source (source)
  (unless (or (memq source drgnx-notice-core-sources) (gethash source drgnx-notice--sources))
    (signal 'wrong-type-argument (list 'drgnx-notice-source source))))

(defun drgnx-notice--line (text)
  "TEXT as one line: newlines become spaces, a leading \"drgnx: \" goes.  TEXT itself when there is nothing to do."
  (unless (stringp text) (signal 'wrong-type-argument (list 'stringp text)))
  (when (string-search "\n" text) (setq text (string-replace "\n" " " text)))
  (if (string-prefix-p "drgnx: " text) (substring text 7) text))

(defun drgnx-notice--rank-of (source)
  "Where SOURCE comes in definition order: the core sources first."
  (let ((core (memq source drgnx-notice-core-sources)))
    (if core (- (length drgnx-notice-core-sources) (length core))
      (+ (length drgnx-notice-core-sources)
         (or (plist-get (gethash source drgnx-notice--sources) :rank) most-positive-fixnum)))))

;;;; The now lane

(defun drgnx-notice--hook-failed (fn err)
  "Record that FN failed with ERR; the first failure of FN gives one message."
  (let ((seen (assq fn drgnx-notice--hook-errors)) (text (error-message-string err)))
    (push (list fn text (drgnx-timer-now)) drgnx-notice--hook-errors)
    (when (nthcdr 20 drgnx-notice--hook-errors) (setq drgnx-notice--hook-errors (ntake 20 drgnx-notice--hook-errors)))
    (unless seen (message "drgnx: notice hook %s failed: %s" fn text))))

(defun drgnx-notice--call (fn change)
  "Call FN with CHANGE as automatic code that cannot ask; record an error.  Nil, so every function runs."
  (condition-case err
      (drgnx-automatic (let ((inhibit-interaction t)) (funcall fn change)))
    (error (drgnx-notice--hook-failed fn err)))
  nil)

(defun drgnx-notice--dispatch (change)
  "Run `drgnx-notice-functions' with CHANGE, then the changes they made (queued), at most 100 of them."
  (if drgnx-notice--running
      (push change drgnx-notice--queue)
    (let ((drgnx-notice--running t) (n 0) (dropped 0))
      (run-hook-wrapped 'drgnx-notice-functions #'drgnx-notice--call change)
      (while drgnx-notice--queue
        (let ((batch (nreverse drgnx-notice--queue)))
          (setq drgnx-notice--queue nil)
          (dolist (c batch)
            (if (>= n 100) (setq dropped (1+ dropped))
              (setq n (1+ n))
              (run-hook-wrapped 'drgnx-notice-functions #'drgnx-notice--call c)))))
      (when (> dropped 0)
        (message "drgnx: %d notice changes not passed on: notice hook functions keep posting" dropped)))))

(defun drgnx-notice--changed (op key source notice added removed)
  "Bump the tick; tell `drgnx-notice-functions' (the change is built only when there is one)."
  (setq drgnx-notice--tick (1+ drgnx-notice--tick))
  (when drgnx-notice-functions
    (let ((c nil))
      (when removed (setq c (cons :removed (cons removed c))))
      (when added (setq c (cons :added (cons added c))))
      (when notice (setq c (cons :notice (cons notice c))))
      (setq c (cons :source (cons source c)))
      (when key (setq c (cons :key (cons key c))))
      (drgnx-notice--dispatch (cons :op (cons op c))))))

;;;; Events and conditions

(defun drgnx-notice--dismissed-p (key notice)
  (let ((d (gethash key drgnx-notice--dismissed))) (and d (equal d (plist-get notice :text)))))

(defun drgnx-notice--count-problem (key notice delta)
  "Add DELTA to the problems count for NOTICE at KEY, if it is a `warn' or `fail' condition not dismissed."
  (when (and (eq (plist-get notice :life) 'condition) (not (drgnx-notice--dismissed-p key notice)))
    (let ((p drgnx-notice--problems))
      (pcase (plist-get notice :severity)
        ('warn (setq drgnx-notice--problems (cons (+ (car p) delta) (cdr p))))
        ('fail (setq drgnx-notice--problems (cons (car p) (+ (cdr p) delta))))))))

(defun drgnx-notice--unstore (key notice)
  "Take NOTICE at KEY out of the ring or the condition count, and out of the problems count."
  (if (eq (plist-get notice :life) 'event)
      (setq drgnx-notice--events (delete key drgnx-notice--events))
    (let ((n (1- (gethash (car key) drgnx-notice--conditions 1))))
      (if (> n 0) (puthash (car key) n drgnx-notice--conditions) (remhash (car key) drgnx-notice--conditions)))
    (drgnx-notice--count-problem key notice -1)))

(defun drgnx-notice--remove (key notice)
  "Remove NOTICE at KEY from the model (no tick)."
  (drgnx-notice--unstore key notice)
  (remhash key drgnx-notice--table)
  (when (eq (cdr key) 'more) (remhash (car key) drgnx-notice--more)))

(defun drgnx-notice--trim-events ()
  "Drop the events past `drgnx-notice-event-limit', oldest first."
  (let ((tail (nthcdr (1- (max 1 drgnx-notice-event-limit)) drgnx-notice--events)))
    (when (cdr tail)
      (dolist (k (cdr tail)) (remhash k drgnx-notice--table) (remhash k drgnx-notice--dismissed))
      (setcdr tail nil))))

(defun drgnx-notice--overflow (source id)
  "SOURCE's condition ID came past its cap: count ID in its \"and N more\" condition, once."
  (let ((ids (or (gethash source drgnx-notice--more)
                 (puthash source (make-hash-table :test #'equal) drgnx-notice--more))))
    (unless (gethash id ids)
      (puthash id t ids)
      (drgnx-notice--post source 'more 'warn 'condition (format "and %d more" (hash-table-count ids)) nil nil
                          (plist-get (gethash source drgnx-notice--sources) :command) nil nil nil))))

(defun drgnx-notice--post (source id severity life text detail fix command scope echo echo-p)
  "Store a checked notice; return its key.  See `drgnx-notify'."
  (let* ((key (cons source id))
         (old (gethash key drgnx-notice--table)))
    (cond
     ;; a repeat: only the count
     ((and old (eq (plist-get old :severity) severity) (eq (plist-get old :life) life)
           (equal (plist-get old :text) text))
      (plist-put old :count (1+ (or (plist-get old :count) 1))))
     ;; a new condition past the source's cap (its own `more' and `unknown' conditions always get in)
     ((and (eq life 'condition) (not (memq id '(more unknown)))
           (not (and old (eq (plist-get old :life) 'condition)))
           (>= (gethash source drgnx-notice--conditions 0) drgnx-notice-condition-limit))
      (drgnx-notice--overflow source id))
     (t
      (when old (drgnx-notice--unstore key old))
      (let ((d (gethash key drgnx-notice--dismissed)))
        (when (and d (or old (not (equal d text)))) (remhash key drgnx-notice--dismissed)))
      (let ((tail nil))
        (when echo-p (setq tail (list :echo echo)))
        (when scope (setq tail (cons :scope (cons scope tail))))
        (when command (setq tail (cons :command (cons command tail))))
        (when fix (setq tail (cons :fix (cons fix tail))))
        (when detail (setq tail (cons :detail (cons detail tail))))
        (let ((n (nconc (list :source source :id id :severity severity :life life :text text
                              :at (drgnx-timer-now))
                        tail)))
          (puthash key n drgnx-notice--table)
          (if (eq life 'event)
              (progn (setq drgnx-notice--events (cons key drgnx-notice--events))
                     (drgnx-notice--trim-events))
            (puthash source (1+ (gethash source drgnx-notice--conditions 0)) drgnx-notice--conditions)
            (drgnx-notice--count-problem key n 1))
          (drgnx-notice--changed 'post key source n nil nil)))))
    key))

(cl-defun drgnx-notify (source severity text &key id life detail fix command scope (echo nil echo-p))
  "Post a notice from SOURCE (a core source or one defined with `drgnx-notice-define-source'); return its KEY.
SEVERITY: `info', `warn' or `fail'.  TEXT: one line (newlines become spaces; a leading \"drgnx: \" goes).
LIFE: `event' (the default) or `condition'.  ID: what it is about; an event without one uses TEXT, so the same
text repeats as a count.  KEY is (SOURCE . ID).  DETAIL: more text.  FIX: what to do about it.  COMMAND: a
registry id, a command symbol, or (FN . ARGS) with ARGS readable data (never a closure).  SCOPE: what it belongs
to (a job id, a project).  ECHO: t or nil overrides the echo rule; given, it is stored even when nil.
The same key, text and severity again only counts (:count, absent means 1): no tick, no hook call; a repeated
event keeps its :at (its first post) and its place in the ring, so it can age out and come back new.  Other text or
another severity at the key is a new notice, and lifts a dismissal.  Signals `wrong-type-argument' on a severity
or life outside the vocabulary, a command that does not read back, or an undefined source."
  (drgnx-notice--check-source source)
  (unless (memq severity drgnx-notice-severities)
    (signal 'wrong-type-argument (list 'drgnx-notice-severity severity)))
  (unless life (setq life 'event))
  (unless (memq life '(event condition)) (signal 'wrong-type-argument (list 'drgnx-notice-life life)))
  (drgnx-notice--check-command command)
  (setq text (drgnx-notice--line text))
  (drgnx-notice--post source (or id text) severity life text detail fix command scope echo echo-p))

(defun drgnx-notice-clear (source &optional id)
  "Clear SOURCE's notice ID, or all of SOURCE's events and conditions.  Returns the key, or the keys, cleared."
  (if id
      (let* ((key (cons source id)) (old (gethash key drgnx-notice--table)))
        (when old
          (drgnx-notice--remove key old)
          (drgnx-notice--changed 'clear key source nil nil nil)
          key))
    (let ((keys nil))
      (maphash (lambda (k _) (when (eq (car k) source) (push k keys))) drgnx-notice--table)
      (when keys
        (dolist (k keys) (drgnx-notice--remove k (gethash k drgnx-notice--table)))
        (drgnx-notice--changed 'clear nil source nil nil keys)
        keys))))

(defun drgnx-notice-dismiss (key)
  "Hide the event or condition at KEY until it is posted again with other text; return KEY.
An attention item cannot be dismissed (its source decides): that signals.  Nil when nothing is at KEY."
  (let ((n (gethash key drgnx-notice--table)))
    (cond
     (n (unless (drgnx-notice--dismissed-p key n)
          (drgnx-notice--count-problem key n -1)
          (puthash key (plist-get n :text) drgnx-notice--dismissed)
          (drgnx-notice--changed 'dismiss key (car key) n nil nil))
        key)
     ((gethash key drgnx-notice--union)
      (error "drgnx: %S is waiting on you; it goes when its source no longer holds it" key)))))

;;;; Attention sets

(defun drgnx-notice--elect (id)
  "Put in the union the item counted for ID — of the known sets holding it, the later :at, on a tie the source
defined first — or take ID out when none holds it."
  (let ((best nil) (best-source nil))
    (maphash (lambda (source given)
               (let ((e (gethash id (cdr given))))
                 (when e
                   (let ((n (cadr e)))
                     (when (or (not best)
                               (> (plist-get n :at) (plist-get best :at))
                               (and (= (plist-get n :at) (plist-get best :at))
                                    (< (drgnx-notice--rank-of source) (drgnx-notice--rank-of best-source))))
                       (setq best n best-source source))))))
             drgnx-notice--index)
    (if best (puthash id best drgnx-notice--union) (remhash id drgnx-notice--union))))

(defun drgnx-notice--drop-index (source)
  "Take SOURCE's set out of the union; return the ids it held."
  (let ((given (gethash source drgnx-notice--index)) (ids nil))
    (when given
      (remhash source drgnx-notice--index)
      (maphash (lambda (id _) (push id ids)) (cdr given))
      (dolist (id ids) (drgnx-notice--elect id))
      (setq drgnx-notice--needs-you (hash-table-count drgnx-notice--union)))
    (nreverse ids)))

(defun drgnx-notice--check-item (item)
  (unless (and (consp item) (plist-get item :id) (stringp (plist-get item :text)))
    (signal 'wrong-type-argument (list 'drgnx-notice-item item)))
  (drgnx-notice--check-command (plist-get item :command)))

(defun drgnx-notice--same-item-p (n item text)
  "Non-nil if the stored N says what ITEM (with TEXT, its one-line text) says."
  (and (equal (plist-get n :text) text)
       (equal (plist-get n :command) (plist-get item :command))
       (equal (plist-get n :scope) (plist-get item :scope))
       (equal (plist-get n :detail) (plist-get item :detail))
       (let ((a (plist-member n :echo)) (b (plist-member item :echo)))
         (if a (and b (eq (cadr a) (cadr b))) (not b)))))

(defun drgnx-notice--item (source item id text at)
  "The attention notice SOURCE holds for ITEM."
  (let ((tail nil) (echo (plist-member item :echo)))
    (when echo (setq tail (list :echo (cadr echo))))
    (dolist (k '(:detail :scope :command))
      (let ((v (plist-get item k))) (when v (setq tail (cons k (cons v tail))))))
    (nconc (list :source source :id id :severity 'needs-you :life 'attention :text text :at at) tail)))

(defvar drgnx-notice--gen 0
  "Bumped by each `drgnx-notice--replace' that compares item by item: it marks the entries its items reach.")

(defun drgnx-notice--replace (source items)
  "Make ITEMS SOURCE's set; non-nil if it changed.
ITEMS `equal' to the set given last time costs one comparison.  Otherwise each item `equal' to the one given last
time for its ID is taken as it is (one lookup, unchecked); the others are checked, all before anything changes,
then applied in order, so a later item with the same ID wins.  An ID no item reached is gone."
  (let* ((prev (gethash source drgnx-notice--sets))
         (given (gethash source drgnx-notice--index)))
    (unless (and given (equal items (car given)))       ; the whole set sent again: nothing to do
      (let* ((table (if given (cdr given) (make-hash-table :test #'equal :size (max 8 (length items)))))
             (old-n (hash-table-count table))
             (gen (setq drgnx-notice--gen (1+ drgnx-notice--gen))) (pending (- gen))
             (found 0) (dups nil) (set nil) (todo nil)
             (now nil) (added nil) (removed nil) (dirty nil))
        ;; 1. reach each item's entry: GEN when the item is the same, PENDING when it waits for step 3
        (dolist (it items)
          (let* ((e (and (consp it) (gethash (plist-get it :id) table))) (mark (cddr e)))
            (cond ((null e) (push it todo))
                  ((or (eq mark gen) (eq mark pending)) (setq dups t) (push it todo))
                  (t (setq found (1+ found))
                     (if (equal (car e) it)
                         (progn (setcdr (cdr e) gen) (push (cadr e) set))
                       (setcdr (cdr e) pending)
                       (push it todo))))))
        ;; 2. check what is new before anything changes
        (setq todo (nreverse todo))
        (dolist (it todo) (drgnx-notice--check-item it))
        ;; 3. apply it
        (dolist (it todo)
          (let* ((id (plist-get it :id)) (e (gethash id table))
                 (text (drgnx-notice--line (plist-get it :text)))
                 (n (cadr e)))
            (cond
             ((and n (drgnx-notice--same-item-p n it text)) (setcar e it))
             (e (setcar e it)
                (setcar (cdr e) (drgnx-notice--item source it id text (plist-get n :at)))
                (push id dirty))
             (t (setq e (cons it (cons (drgnx-notice--item source it id text
                                                           (or now (setq now (drgnx-timer-now))))
                                       pending)))
                (puthash id e table)
                (push id added) (push id dirty)))
            (if (eq (cddr e) gen) (setq dups t) (setcdr (cdr e) gen))
            (push (cadr e) set)))
        ;; 4. an entry no item reached is gone
        (when (< found old-n)
          (maphash (lambda (id e) (unless (eq (cddr e) gen) (push id removed))) table)
          (dolist (id removed) (remhash id table) (push id dirty)))
        (puthash source (cons items table) drgnx-notice--index)
        (when (or dirty (not (consp prev)))
          (when dups (setq set nil) (maphash (lambda (_ e) (push (cadr e) set)) table))
          (puthash source (nreverse set) drgnx-notice--sets))
        (when (or dirty (eq prev :unknown))
          (when (eq prev :unknown) (drgnx-notice-clear source 'unknown))
          (dolist (id dirty) (drgnx-notice--elect id))
          (setq drgnx-notice--needs-you (hash-table-count drgnx-notice--union))
          (drgnx-notice--changed 'set nil source nil (nreverse added) removed)
          t)))))

(defun drgnx-notice--unknown (source reason)
  "SOURCE cannot tell its set: drop its items; post the `warn' condition (SOURCE . unknown) saying REASON."
  (let ((prev (gethash source drgnx-notice--sets)))
    (let ((ids (unless (eq prev :unknown)
                 (puthash source :unknown drgnx-notice--sets)
                 (drgnx-notice--drop-index source))))
      (drgnx-notify source 'warn (or reason "not known") :id 'unknown :life 'condition
                    :command (plist-get (gethash source drgnx-notice--sources) :command))
      (unless (eq prev :unknown)
        (drgnx-notice--changed 'unknown nil source nil nil ids)
        t))))

(defun drgnx-notice--check-stale ()
  "Make `:unknown' each source with `:stale' SECS that holds items and has not set them for SECS."
  (let ((now (and drgnx-notice--stale (drgnx-timer-now))) (stale nil))
    (dolist (s drgnx-notice--stale)
      (when (and (consp (gethash (car s) drgnx-notice--sets))
                 (> (- now (gethash (car s) drgnx-notice--heard now)) (cdr s)))
        (push s stale)))
    (dolist (s stale)
      (drgnx-notice--unknown (car s) (format "not heard from in %d min" (max 1 (round (cdr s) 60)))))))

(cl-defun drgnx-notice-set (source items &key reason)
  "Replace SOURCE's attention items with ITEMS; non-nil if anything changed.
ITEMS: plists with :id (the entity the user acts on: the same ID from two sources counts once) and :text, and
optionally :command :scope :detail :echo.  A later item with the same ID wins; an unchanged ID keeps its :at.
Only a change of ids or what they say ticks.  The model keeps ITEMS to compare the next set with: do not change
them after the call (send fresh plists).  ITEMS `:unknown': SOURCE cannot tell; its items drop out and the
`warn' condition (SOURCE . unknown) says REASON (default \"not known\"), until a later list clears it."
  (drgnx-notice--check-source source)
  (unless (or (eq items :unknown) (listp items)) (signal 'wrong-type-argument (list 'drgnx-notice-items items)))
  (puthash source (drgnx-timer-now) drgnx-notice--heard)
  (prog1 (if (eq items :unknown) (drgnx-notice--unknown source reason) (drgnx-notice--replace source items))
    (drgnx-notice--check-stale)))

;;;; Sources

(cl-defun drgnx-notice-define-source (source &key title command stale)
  "Define notice SOURCE (a symbol): TITLE names it, COMMAND (as in `drgnx-notify') shows it.  STALE: seconds; a
source that holds items and has not called `drgnx-notice-set' for that long becomes `:unknown' (default: never).
Defined in a module's setup, it goes, with its notices and its set, when the module is turned off.  The core
sources (`drgnx-notice-core-sources') need no definition, and defining one signals.  Returns SOURCE."
  (when (memq source drgnx-notice-core-sources)
    (error "drgnx: %s is a core notice source: it needs no definition" source))
  (unless (and source (symbolp source)) (signal 'wrong-type-argument (list 'symbolp source)))
  (drgnx-notice--check-command command)
  (unless (or (null stale) (and (numberp stale) (> stale 0)))
    (signal 'wrong-type-argument (list 'drgnx-notice-stale stale)))
  (let* ((old (gethash source drgnx-notice--sources))
         (entry (list :title title :command command :stale stale :owner drgnx-modules--current
                      :rank (or (plist-get old :rank) (setq drgnx-notice--rank (1+ drgnx-notice--rank))))))
    (puthash source entry drgnx-notice--sources)
    (setq drgnx-notice--stale (assq-delete-all source drgnx-notice--stale))
    (when stale (push (cons source stale) drgnx-notice--stale))
    (drgnx-modules-push-undo (format "notice source %s" source)
                             (lambda () (when (eq (gethash source drgnx-notice--sources) entry)
                                          (drgnx-notice-undefine-source source))))
    source))

(defun drgnx-notice-undefine-source (source)
  "Remove notice SOURCE with its events, conditions, dismissals and set.  Returns SOURCE if it was defined."
  (when (gethash source drgnx-notice--sources)
    (remhash source drgnx-notice--sources)
    (setq drgnx-notice--stale (assq-delete-all source drgnx-notice--stale))
    (let ((keys nil))
      (maphash (lambda (k _) (when (eq (car k) source) (push k keys))) drgnx-notice--table)
      (dolist (k keys) (drgnx-notice--remove k (gethash k drgnx-notice--table)))
      (let ((gone nil))
        (maphash (lambda (k _) (when (eq (car-safe k) source) (push k gone))) drgnx-notice--dismissed)
        (dolist (k gone) (remhash k drgnx-notice--dismissed)))
      (remhash source drgnx-notice--sets)
      (remhash source drgnx-notice--heard)
      (remhash source drgnx-notice--more)
      (drgnx-notice--changed 'undefine nil source nil nil (append keys (drgnx-notice--drop-index source))))
    source))

;;;; Readers

(defun drgnx-notice--newest-first (notices)
  (sort notices (lambda (a b) (> (plist-get a :at) (plist-get b :at)))))

(cl-defun drgnx-notices (&key source severity life scope)
  "The notices, newest first, that are not dismissed: events and conditions, and the attention items when LIFE is
nil or `attention' (SOURCE's own set when SOURCE is given, else the union).  Each key narrows the list."
  (let ((out nil))
    (unless (eq life 'attention)
      (maphash (lambda (key n)
                 (when (and (or (null source) (eq (car key) source))
                            (or (null severity) (eq (plist-get n :severity) severity))
                            (or (null life) (eq (plist-get n :life) life))
                            (or (null scope) (equal (plist-get n :scope) scope))
                            (not (drgnx-notice--dismissed-p key n)))
                   (push n out)))
               drgnx-notice--table))
    (when (and (memq life '(nil attention)) (memq severity '(nil needs-you)))
      (let ((take (lambda (n) (when (or (null scope) (equal (plist-get n :scope) scope)) (push n out)))))
        (if source
            (let ((set (gethash source drgnx-notice--sets))) (when (consp set) (mapc take set)))
          (maphash (lambda (_ n) (funcall take n)) drgnx-notice--union))))
    (drgnx-notice--newest-first out)))

(defun drgnx-needs-you-count (&optional scope)
  "How many distinct things wait on the user, from sources that know; with SCOPE, those belonging to it.
Allocates nothing on a read: the count is cached, and a scope's is memoised until the next change."
  (if (null scope) drgnx-notice--needs-you
    (unless (eq drgnx-notice--scoped-tick drgnx-notice--tick)
      (clrhash drgnx-notice--scoped)
      (setq drgnx-notice--scoped-tick drgnx-notice--tick))
    (let ((c (gethash scope drgnx-notice--scoped)))
      (or c
          (let ((n 0))
            (maphash (lambda (_ it) (when (equal (plist-get it :scope) scope) (setq n (1+ n)))) drgnx-notice--union)
            (puthash scope n drgnx-notice--scoped))))))

(defun drgnx-needs-you-items (&optional scope)
  "The things waiting on the user (attention notices, one per id), newest first; with SCOPE, those belonging to it."
  (drgnx-notices :life 'attention :scope scope))

(defun drgnx-needs-you-unknown ()
  "The sources that cannot tell what waits on the user now (their set is `:unknown')."
  (let ((out nil))
    (maphash (lambda (s set) (when (eq set :unknown) (push s out))) drgnx-notice--sets)
    out))

(defun drgnx-problems-count ()
  "(WARN . FAIL): the `warn' and `fail' conditions not dismissed.  Do not change the cons."
  drgnx-notice--problems)

(defun drgnx-notice-tick ()
  "The model's tick: it changes whenever the model does (not on a repeat).  Readers memoise on it."
  drgnx-notice--tick)

(provide 'drgnx-notice)
;;; drgnx-notice.el ends here
