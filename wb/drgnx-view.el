;;; drgnx-view.el --- Views: keyed rows with integer starts, patched in place, never erased -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A view draws a buffer as rows, one per KEY, from START (its only marker) to the end of the buffer.  A view type
;; (`drgnx-view-define') says how a row is rendered (RENDER), how it grows at its end (GROW) and how the view pulls
;; changes from its model (SYNC).  Code that changes the model only MARKS the view: a mark is a hash put or a queue
;; push, cheap enough for a process filter.  The draw applies the marks in buffer order, with one running position:
;; a dirty row is deleted and inserted again at its integer start, a growing row gets only its new characters,
;; removed rows are deleted one by one.  Nothing is applied by erasing a region, undo is off, and no row has a
;; marker: row starts are integers, relative to START, shifted in one pass.
;;
;; `drgnx-view-draw-now' draws at once (for `g' and tests).  See docs/develop/core.md, "Views".

;;; Code:
(require 'cl-lib)
(require 'drgnx-modules-record)

(defvar drgnx-signal-errors)            ; drgnx-signal, when loaded

(defcustom drgnx-view-slice 0.004
  "The longest slice, in seconds, a view type may ask for: all views together draw at most this long per gap."
  :type 'number :group 'drgnx)

(defcustom drgnx-view-delay 0.1
  "Seconds between a view's first mark and its draw, for a type that names no DELAY (the throttle)."
  :type 'number :group 'drgnx)

(defconst drgnx-view--check-every 8
  "A slice reads the clock and `input-pending-p' once per this many rows (a clock read boxes a float).")

(defvar drgnx-view--types nil
  "Alist NAME → `drgnx-view-type', the view types `drgnx-view-define' made.  The fingerprint reads the names.")

(defvar-local drgnx-view nil
  "The view drawn in this buffer (`drgnx-view-attach'), or nil.")

(defconst drgnx-view--all (make-symbol "all")
  "The key `drgnx-view-dirty' stores in the dirty table for KEYS t: every row.")

(defconst drgnx-view--read-only '(read-only t)
  "Text properties of a drawn row's text when the buffer is not read-only (see `drgnx-view--protect').")

(defconst drgnx-view--last-char '(rear-nonsticky (read-only))
  "Text properties of a drawn row's last character: text typed after the row does not inherit `read-only'.")

(defconst drgnx-view--stat-names
  [:rows-drawn :rows-grown :appended :removed :slices :max-slice-rows :full-draws :stale-skips]
  "The names of the counters in a view's `stats' vector, in order.")

;;;; Types

(cl-defstruct (drgnx-view-type (:constructor drgnx-view--make-type) (:copier nil))
  "A view type: how its rows are rendered, grown and synced (`drgnx-view-define')."
  name render grow sync slice delay follow-tail key-test patched)

(cl-defun drgnx-view-define (name &key render grow sync slice delay follow-tail key-test patched)
  "Define the view type NAME and return NAME.
RENDER (KEY): the row's text, a string ending in a newline, or (BODY . SUFFIX) so that growth goes before SUFFIX.
GROW (KEY BODY-LENGTH): the characters to add at the end of the row's BODY, or nil to render the row again.
SYNC (VIEW): called at draw time after `drgnx-view-touch', to mark what changed (`drgnx-view-sync-rows').
SLICE: nil (draw all at once) or at most `drgnx-view-slice' seconds.  DELAY: the throttle (nil:
`drgnx-view-delay').  FOLLOW-TAIL: a window at the end stays at the end.  KEY-TEST: `eq' or `equal' (the
default).  PATCHED (VIEW KEYS): called after a draw with the keys whose rows it drew or grew.
The undo `\"view type NAME\"' removes the definition while it is still this one."
  (unless (and name (symbolp name)) (signal 'wrong-type-argument (list 'symbolp name)))
  (unless (functionp render) (error "View type %s: RENDER is not a function: %S" name render))
  (unless (or (null slice) (and (numberp slice) (> slice 0) (<= slice drgnx-view-slice)))
    (error "View type %s: SLICE is nil or at most %s, not %S" name drgnx-view-slice slice))
  (unless (memq (or key-test 'equal) '(eq equal))
    (error "View type %s: KEY-TEST is `eq' or `equal', not %S" name key-test))
  (let ((type (drgnx-view--make-type :name name :render render :grow grow :sync sync :slice slice :delay delay
                                     :follow-tail follow-tail :key-test (or key-test 'equal) :patched patched)))
    (setf (alist-get name drgnx-view--types) type)
    (drgnx-modules-push-undo (format "view type %s" name) (lambda () (drgnx-view--undefine name type)))
    name))

(defun drgnx-view--undefine (name &optional type)
  "Remove the view type NAME, when TYPE is nil or still its definition.  Attached views keep drawing."
  (when (or (null type) (eq (alist-get name drgnx-view--types) type))
    (setq drgnx-view--types (assq-delete-all name drgnx-view--types))))

;;;; The record

(cl-defstruct (drgnx-view (:constructor drgnx-view--make) (:copier nil) (:conc-name drgnx-view--))
  "A view attached to a buffer.  Row I of N is `keys'[I], from START + `starts'[I] to START + `starts'[I+1]."
  buffer type
  start                                 ; the only marker: where the rows begin (insertion type nil)
  keys starts                           ; vectors grown by doubling: N keys and N+1 starts
  index                                 ; KEY → row number (the type's KEY-TEST)
  dirty                                 ; KEY → `patch' or `grow'; `drgnx-view--all' → `patch' for every row
  pending                               ; structural changes (OP KEYS AFTER), newest first
  bodies                                ; KEY → its BODY's length, for rows rendered as (BODY . SUFFIX)
  stale shown
  stats                                 ; the counters of `drgnx-view--stat-names'
  (n 0) touched
  error                                 ; the error message already recorded for this view
  places                                ; window places kept across a draw
  sigs)                                 ; KEY → its signature at the last `drgnx-view-sync-rows'

(cl-defun drgnx-view-attach (name &key buffer start)
  "Attach a view of type NAME to BUFFER (default: the current buffer), with rows from START (default `point-min').
Undo is turned off.  The rows are read-only: the whole buffer when START is `point-min', else each row (text above
START and after the last row stays editable).  Attaching again removes the old view's rows first.  Returns the view."
  (let ((type (or (alist-get name drgnx-view--types) (error "No view type %s" name))))
    (with-current-buffer (or buffer (current-buffer))
      (save-restriction
        (widen)
        (when (drgnx-view-p drgnx-view) (drgnx-view--remove-rows drgnx-view))
        (let ((test (drgnx-view-type-key-test type))
              (start (copy-marker (or start (point-min)) nil)))
          (setq-local drgnx-view
                      (drgnx-view--make :buffer (current-buffer) :type type :start start
                                        :keys (make-vector 16 nil) :starts (make-vector 17 0)
                                        :index (make-hash-table :test test) :dirty (make-hash-table :test test)
                                        :bodies (make-hash-table :test test) :sigs (make-hash-table :test test)
                                        :stats (make-vector (length drgnx-view--stat-names) 0)))
          (setq buffer-undo-list t)
          (when (= start (point-min)) (setq buffer-read-only t))
          drgnx-view)))))

(defun drgnx-view--remove-rows (view)
  "Remove VIEW's rows, the last first, and release its START.  In VIEW's buffer, widened."
  (let ((s (marker-position (drgnx-view--start view))) (starts (drgnx-view--starts view))
        (i (drgnx-view--n view)) (inhibit-read-only t))
    (if (= (- (point-max) s) (aref starts i))
        (while (> i 0)
          (setq i (1- i))
          (delete-region (+ s (aref starts i)) (+ s (aref starts (1+ i)))))
      (delete-region s (point-max)))       ; the starts are wrong (a foreign edit): no row can be found
    (set-marker (drgnx-view--start view) nil)))

;;;; Marks: a hash put or a queue push, then `drgnx-view--arm'

(defun drgnx-view--arm (_view)
  "Arm VIEW's draw.  Nothing yet: views draw with `drgnx-view-draw-now'."
  nil)

(defun drgnx-view--queue (view op keys after)
  (push (list op keys after) (drgnx-view--pending view))
  (drgnx-view--arm view))

(defun drgnx-view-reset (view keys)
  "Mark that VIEW's rows are KEYS from now on: every row there is now goes, KEYS are appended."
  (setf (drgnx-view--pending view) nil)          ; a reset supersedes every earlier change
  (drgnx-view--queue view 'reset keys nil))

(defun drgnx-view-append (view keys)
  "Mark KEYS as new rows at the end of VIEW.  A key already shown or pending is left where it is."
  (drgnx-view--queue view 'append keys nil))

(cl-defun drgnx-view-insert (view keys &key after)
  "Mark KEYS as new rows right after the row AFTER (a drawn or pending key; nil: the first rows).
An AFTER that is neither appends KEYS.  A key already shown or pending is left where it is."
  (drgnx-view--queue view 'insert keys after))

(defun drgnx-view-remove (view keys)
  "Mark the rows of KEYS (drawn or pending) as gone from VIEW."
  (drgnx-view--queue view 'remove keys nil))

(defun drgnx-view-dirty (view keys)
  "Mark the rows of KEYS to be rendered again; KEYS t: every row.  They are patched in place, never erased."
  (let ((dirty (drgnx-view--dirty view)))
    (if (eq keys t)
        (puthash drgnx-view--all 'patch dirty)
      (dolist (key keys) (puthash key 'patch dirty))))
  (drgnx-view--arm view))

(defun drgnx-view-grow (view key)
  "Mark that KEY's row only grew at the end of its BODY: the draw inserts GROW's text."
  (let ((dirty (drgnx-view--dirty view)))
    (unless (eq (gethash key dirty) 'patch) (puthash key 'grow dirty)))
  (drgnx-view--arm view))

(defun drgnx-view-touch (view)
  "Mark that VIEW's model changed: its type's SYNC runs at the next draw."
  (setf (drgnx-view--touched view) t)
  (drgnx-view--arm view))

;;;; The plan: the pending changes, worked out at draw time

(cl-defstruct (drgnx-view--plan (:constructor drgnx-view--make-plan) (:copier nil))
  "VIEW's pending changes.  A group is a box (a cons whose car is a list of new keys, in order)."
  all-gone                              ; non-nil: every drawn row goes (a reset)
  gone                                  ; drawn KEY → t: the drawn rows that go
  first                                 ; the group before the first drawn row
  after-old                             ; drawn KEY → the group right after its row
  after-new                             ; new KEY → the group right after its row
  end                                   ; the group after everything else
  new)                                  ; new KEY → the group that holds it

(defun drgnx-view--drawn-p (view plan key)
  "Non-nil if KEY's row is drawn in VIEW and PLAN keeps it."
  (and (gethash key (drgnx-view--index view))
       (not (drgnx-view--plan-all-gone plan))
       (not (gethash key (drgnx-view--plan-gone plan)))))

(defun drgnx-view--plan-add (view plan keys box at-end)
  "Put the KEYS that are neither drawn nor new in BOX: at its end when AT-END, else at its front."
  (let ((new (drgnx-view--plan-new plan)) fresh)
    (dolist (key keys)
      (unless (or (gethash key new) (drgnx-view--drawn-p view plan key))
        (puthash key box new)
        (push key fresh)))
    (setq fresh (nreverse fresh))
    (setcar box (if at-end (nconc (car box) fresh) (nconc fresh (car box))))))

(defun drgnx-view--plan-box (table key)
  "The group of KEY in TABLE, made empty when it has none."
  (or (gethash key table) (puthash key (list nil) table)))

(defun drgnx-view--plan-remove (view plan key)
  "KEY's row goes: a new key leaves its group (the keys after it take its place), a drawn row is gone."
  (let* ((new (drgnx-view--plan-new plan)) (box (gethash key new)))
    (cond (box
           (let* ((after-new (drgnx-view--plan-after-new plan))
                  (followers (car (gethash key after-new))) out found)
             (remhash key new)
             (remhash key after-new)
             (dolist (f followers) (puthash f box new))
             (dolist (k (car box))
               (if (and (not found) (drgnx-view--same-key-p view k key))
                   (setq out (append (reverse followers) out) found t)
                 (push k out)))
             (setcar box (nreverse out))))
          ((drgnx-view--drawn-p view plan key) (puthash key t (drgnx-view--plan-gone plan))))))

(defun drgnx-view--same-key-p (view a b)
  (if (eq (drgnx-view-type-key-test (drgnx-view--type view)) 'eq) (eq a b) (equal a b)))

(defun drgnx-view--plan-pending (view)
  "VIEW's pending structural changes as a `drgnx-view--plan', or nil when there are none."
  (when (drgnx-view--pending view)
    (let* ((test (drgnx-view-type-key-test (drgnx-view--type view)))
           (plan (drgnx-view--make-plan :gone (make-hash-table :test test) :first (list nil)
                                        :after-old (make-hash-table :test test)
                                        :after-new (make-hash-table :test test)
                                        :end (list nil) :new (make-hash-table :test test))))
      (dolist (op (reverse (drgnx-view--pending view)))
        (let ((keys (nth 1 op)) (after (nth 2 op)))
          (pcase (car op)
            ('append (drgnx-view--plan-add view plan keys (drgnx-view--plan-end plan) t))
            ('insert
             (cond ((null after) (drgnx-view--plan-add view plan keys (drgnx-view--plan-first plan) nil))
                   ((gethash after (drgnx-view--plan-new plan))
                    (drgnx-view--plan-add view plan keys
                                          (drgnx-view--plan-box (drgnx-view--plan-after-new plan) after) nil))
                   ((drgnx-view--drawn-p view plan after)
                    (drgnx-view--plan-add view plan keys
                                          (drgnx-view--plan-box (drgnx-view--plan-after-old plan) after) nil))
                   (t (drgnx-view--plan-add view plan keys (drgnx-view--plan-end plan) t))))
            ('remove (dolist (key keys) (drgnx-view--plan-remove view plan key)))
            ('reset
             (setf (drgnx-view--plan-all-gone plan) t)
             (dolist (table (list (drgnx-view--plan-gone plan) (drgnx-view--plan-after-old plan)
                                  (drgnx-view--plan-after-new plan) (drgnx-view--plan-new plan)))
               (clrhash table))
             (setcar (drgnx-view--plan-first plan) nil)
             (setcar (drgnx-view--plan-end plan) nil)
             (drgnx-view--plan-add view plan keys (drgnx-view--plan-end plan) t)))))
      plan)))

(defun drgnx-view--walk-group (plan box fn)
  "Call FN (KEY nil `new') for each key of the group BOX, each followed by its own group."
  (let ((stack (car box)) (after-new (drgnx-view--plan-after-new plan)))
    (while stack
      (let* ((key (pop stack)) (group (gethash key after-new)))
        (funcall fn key nil 'new)
        (when group (setq stack (append (car group) stack)))))))

(defun drgnx-view--walk (view plan fn)
  "Call FN (KEY I STATE) for each row of VIEW after PLAN, in buffer order: STATE nil for drawn row I that stays,
`gone' for drawn row I that goes, `new' (I nil) for a new row.  PLAN nil: every drawn row stays."
  (let ((keys (drgnx-view--keys view)) (n (drgnx-view--n view)) (i 0))
    (if (null plan)
        (while (< i n) (funcall fn (aref keys i) i nil) (setq i (1+ i)))
      (let ((all (drgnx-view--plan-all-gone plan)) (gone (drgnx-view--plan-gone plan))
            (after-old (drgnx-view--plan-after-old plan)))
        (drgnx-view--walk-group plan (drgnx-view--plan-first plan) fn)
        (while (< i n)
          (let* ((key (aref keys i)) (group (gethash key after-old)))
            (funcall fn key i (and (or all (gethash key gone)) 'gone))
            (when group (drgnx-view--walk-group plan group fn)))
          (setq i (1+ i)))
        (drgnx-view--walk-group plan (drgnx-view--plan-end plan) fn)))))

;;;; Rows: render, insert, grow

(defun drgnx-view--record (view message)
  "Record MESSAGE as VIEW's error, unless VIEW already recorded one: in `drgnx-signal-errors' when it is bound."
  (unless (drgnx-view--error view)
    (setf (drgnx-view--error view) message)
    (when (boundp 'drgnx-signal-errors)
      (push (format "view %s: %s" (drgnx-view-type-name (drgnx-view--type view)) message) drgnx-signal-errors)
      (setq drgnx-signal-errors (take 20 drgnx-signal-errors)))))

(defun drgnx-view--error-text (key message)
  "The row drawn for KEY when its RENDER or GROW signalled MESSAGE."
  (propertize (format "⚠ %s: %s\n" key message) 'face 'error))

(defun drgnx-view--newline-end-p (string)
  (let ((n (length string))) (and (> n 0) (eq (aref string (1- n)) ?\n))))

(defun drgnx-view--row-p (r)
  "Non-nil if R is a row's text: a string ending in a newline, or (BODY . SUFFIX) whose concatenation does."
  (if (stringp r)
      (drgnx-view--newline-end-p r)
    (and (consp r) (stringp (car r)) (stringp (cdr r))
         (drgnx-view--newline-end-p (if (equal (cdr r) "") (car r) (cdr r))))))

(defun drgnx-view--render (view key)
  "KEY's row text in VIEW, or its error row (recorded) when RENDER signals or returns no row."
  (let ((r (condition-case err (funcall (drgnx-view-type-render (drgnx-view--type view)) key)
             (error (drgnx-view--record view (error-message-string err))
                    (drgnx-view--error-text key (error-message-string err))))))
    (if (drgnx-view--row-p r)
        r
      (let ((message (format "RENDER returned %S, not text ending in a newline" r)))
        (drgnx-view--record view message)
        (drgnx-view--error-text key message)))))

(defun drgnx-view--protect (beg end row-end)
  "Make BEG..END of a row ending at ROW-END read-only, unless the whole buffer is.  Only the row's last character is
rear-nonsticky: an insertion inside the row would inherit `read-only' and is refused, one after the row is not."
  (unless buffer-read-only
    (add-text-properties beg end drgnx-view--read-only)
    (add-text-properties (1- row-end) row-end drgnx-view--last-char)))

(defun drgnx-view--put-row (view key pos text)
  "Insert TEXT, KEY's row (a string or (BODY . SUFFIX)), at POS; note its body; return its length."
  (goto-char pos)
  (if (consp text)
      (progn (insert (car text) (cdr text))
             (puthash key (length (car text)) (drgnx-view--bodies view)))
    (insert text)
    (remhash key (drgnx-view--bodies view)))
  (drgnx-view--protect pos (point) (point))
  (cl-incf (aref (drgnx-view--stats view) 0))
  (- (point) pos))

(defun drgnx-view--grow-row (view key pos len)
  "Grow KEY's row (at POS, LEN long) by its GROW's text; return its new length, or nil to render it again.
A GROW that signals or returns a non-string draws the error row."
  (let ((body (gethash key (drgnx-view--bodies view)))
        (grow (drgnx-view-type-grow (drgnx-view--type view))))
    (when (and body grow)
      (condition-case err
          (let ((text (funcall grow key body)))
            (cond ((null text) nil)
                  ((not (stringp text)) (error "GROW returned %S, not a string" text))
                  ((equal text "") len)
                  (t (goto-char (+ pos body))
                     (insert text)
                     (drgnx-view--protect (+ pos body) (point) (+ pos len (length text)))
                     (puthash key (+ body (length text)) (drgnx-view--bodies view))
                     (cl-incf (aref (drgnx-view--stats view) 1))
                     (+ len (length text)))))
        (error
         (let ((message (error-message-string err)))
           (drgnx-view--record view message)
           (delete-region pos (+ pos len))
           (drgnx-view--put-row view key pos (drgnx-view--error-text key message))))))))

;;;; The pass

(defun drgnx-view--forget-gone (view plan)
  "Drop the rows PLAN removes from VIEW's index and bodies, and their signatures unless they come back."
  (let ((index (drgnx-view--index view)) (bodies (drgnx-view--bodies view)) (sigs (drgnx-view--sigs view))
        (new (drgnx-view--plan-new plan)))
    (if (drgnx-view--plan-all-gone plan)
        (progn (clrhash index) (clrhash bodies)
               (maphash (lambda (key _) (unless (gethash key new) (remhash key sigs))) sigs))
      (maphash (lambda (key _)
                 (remhash key index) (remhash key bodies)
                 (unless (gethash key new) (remhash key sigs)))
               (drgnx-view--plan-gone plan)))))

(defun drgnx-view--self-check (view)
  "When VIEW's region (START to the end of the buffer) is not as long as its rows, reset it: delete the region and
draw every row again, before the pending changes.  In VIEW's buffer, widened."
  (let ((s (marker-position (drgnx-view--start view))) (n (drgnx-view--n view)))
    (unless (= (- (point-max) s) (aref (drgnx-view--starts view) n))
      (let ((keys (drgnx-view--keys view)) (i n) old)
        (while (> i 0) (setq i (1- i)) (push (aref keys i) old))
        (delete-region s (point-max))
        (setf (drgnx-view--n view) 0)
        (aset (drgnx-view--starts view) 0 0)
        (clrhash (drgnx-view--index view))
        (clrhash (drgnx-view--bodies view))
        (setf (drgnx-view--pending view) (nconc (drgnx-view--pending view) (list (list 'append old nil))))
        (cl-incf (aref (drgnx-view--stats view) 6))))))

(defun drgnx-view--pass (view)
  "Apply VIEW's pending changes and dirty rows in buffer order, with one running position; return the rows
drawn, grown or removed.  In VIEW's buffer, widened, with `inhibit-read-only'."
  (let ((plan (drgnx-view--plan-pending view)) (dirty (drgnx-view--dirty view)))
    (if (and (null plan) (zerop (hash-table-count dirty)))
        0
      (let* ((stats (drgnx-view--stats view))
             (before (+ (aref stats 0) (aref stats 1) (aref stats 3)))
             (all (gethash drgnx-view--all dirty))
             (index (drgnx-view--index view))
             (ostarts (drgnx-view--starts view))
             (nkeys (drgnx-view--keys view)) (nstarts ostarts)   ; in place when no row comes or goes
             (s (marker-position (drgnx-view--start view)))
             (patched (drgnx-view-type-patched (drgnx-view--type view)))
             (here 0) (o 0) changed)
        (when plan
          (drgnx-view--forget-gone view plan)
          (let ((cap (length nkeys))
                (need (+ (drgnx-view--n view) (hash-table-count (drgnx-view--plan-new plan)) 1)))
            (while (< cap need) (setq cap (* 2 cap)))
            (setq nkeys (make-vector cap nil) nstarts (make-vector (1+ cap) 0))))
        (drgnx-view--walk
         view plan
         (lambda (key i state)
           ;; old row I's length is read before its start is overwritten (in place, nstarts is ostarts)
           (let ((len (and i (- (aref ostarts (1+ i)) (aref ostarts i)))) (pos (+ s here)))
             (if (eq state 'gone)
                 (progn (delete-region pos (+ pos len))
                        (cl-incf (aref stats 3)))
               (let ((mark (cond ((null i) 'new) (all 'patch) (t (gethash key dirty)))))
                 (pcase mark
                   ('new (setq len (drgnx-view--put-row view key pos (drgnx-view--render view key)))
                         (cl-incf (aref stats 2)))
                   ('patch (delete-region pos (+ pos len))
                           (setq len (drgnx-view--put-row view key pos (drgnx-view--render view key))))
                   ('grow (setq len (or (drgnx-view--grow-row view key pos len)
                                        (progn (delete-region pos (+ pos len))
                                               (drgnx-view--put-row view key pos
                                                                    (drgnx-view--render view key)))))))
                 (when (and mark patched) (push key changed)))
               (aset nkeys o key)
               (aset nstarts o here)
               (unless (eql i o) (puthash key o index))
               (setq here (+ here len) o (1+ o))))))
        (aset nstarts o here)
        (setf (drgnx-view--n view) o (drgnx-view--keys view) nkeys (drgnx-view--starts view) nstarts
              (drgnx-view--pending view) nil)
        (clrhash dirty)
        (set-buffer-modified-p nil)
        (when changed
          (condition-case err (funcall patched view (nreverse changed))
            (error (drgnx-view--record view (format "PATCHED: %s" (error-message-string err))))))
        (- (+ (aref stats 0) (aref stats 1) (aref stats 3)) before)))))

(defun drgnx-view-draw-now (view)
  "Draw VIEW now: run SYNC when touched, then apply every mark.  Returns the number of rows drawn, grown or removed.
A RENDER, GROW, SYNC or PATCHED that signals is recorded (`drgnx-view--record'), never raised."
  (let ((buffer (drgnx-view--buffer view)))
    (if (not (buffer-live-p buffer))
        0
      (with-current-buffer buffer
        (save-excursion
          (save-restriction
            (widen)
            (let ((inhibit-read-only t) (inhibit-interaction t))
              (when (drgnx-view--touched view)
                (setf (drgnx-view--touched view) nil)
                (let ((sync (drgnx-view-type-sync (drgnx-view--type view))))
                  (when sync
                    (condition-case err (funcall sync view)
                      (error (drgnx-view--record view (format "SYNC: %s" (error-message-string err))))))))
              (drgnx-view--self-check view)
              (drgnx-view--pass view))))))))

;;;; Sync: diff a model's keys against the rows

(defun drgnx-view--same-sig-p (a b)
  "Non-nil if signatures A and B are `eq', or vectors of the same length with `eq' elements."
  (or (eq a b)
      (and (vectorp a) (vectorp b) (= (length a) (length b))
           (let ((i 0) (n (length a)))
             (while (and (< i n) (eq (aref a i) (aref b i))) (setq i (1+ i)))
             (= i n)))))

(defun drgnx-view--sync-sig (view key sig)
  "Store KEY's signature (SIG's value) in VIEW; non-nil if it changed since the last one stored."
  (let ((new (funcall sig key)) (sigs (drgnx-view--sigs view)))
    (unless (drgnx-view--same-sig-p (gethash key sigs drgnx-view--all) new)
      (puthash key new sigs)
      t)))

(defun drgnx-view--lis (p)
  "A longest strictly increasing subsequence of the vector of integers P, as a bool-vector over P's indices."
  (let* ((m (length p)) (tails (make-vector m 0)) (prev (make-vector m -1)) (len 0) (keep (make-bool-vector m nil)))
    (dotimes (i m)
      (let ((lo 0) (hi len))
        (while (< lo hi)
          (let ((mid (ash (+ lo hi) -1)))
            (if (< (aref p (aref tails mid)) (aref p i)) (setq lo (1+ mid)) (setq hi mid))))
        (when (> lo 0) (aset prev i (aref tails (1- lo))))
        (aset tails lo i)
        (when (= lo len) (setq len (1+ len)))))
    (let ((i (if (> len 0) (aref tails (1- len)) -1)))
      (while (>= i 0) (aset keep i t) (setq i (aref prev i))))
    keep))

(defun drgnx-view-sync-rows (view keys sig)
  "Mark VIEW so that its rows become KEYS (a list, in order).  A row whose signature (SIG KEY) is not `eq' to the
one stored at the last sync is dirty (a vector signature is compared element by element, with `eq').  Keys not
shown are inserted, rows not in KEYS removed.  A row that moved is removed and inserted; when more than half the
rows moved, the view is reset instead.  The drawn rows and the pending changes are both taken into account."
  (let* ((plan (drgnx-view--plan-pending view))
         (n (drgnx-view--n view)) (vkeys (drgnx-view--keys view))
         (same (and (null plan)
                    (let ((i 0) (rest keys))
                      (while (and rest (< i n) (drgnx-view--same-key-p view (car rest) (aref vkeys i)))
                        (setq i (1+ i) rest (cdr rest)))
                      (and (null rest) (= i n))))))
    (if same
        (dolist (key keys)
          (when (drgnx-view--sync-sig view key sig) (puthash key 'patch (drgnx-view--dirty view))))
      (drgnx-view--sync-diff view keys sig plan))
    (drgnx-view--arm view)))

(defun drgnx-view--sync-diff (view keys sig plan)
  "`drgnx-view-sync-rows' when KEYS differ from VIEW's rows after PLAN."
  (let* ((test (drgnx-view-type-key-test (drgnx-view--type view)))
         (current (let (l) (drgnx-view--walk view plan (lambda (key _ state) (unless (eq state 'gone) (push key l))))
                       (nreverse l)))
         (pos (make-hash-table :test test :size (length current)))
         (kept (make-hash-table :test test))
         (i 0) common p)
    (dolist (key current) (puthash key i pos) (setq i (1+ i)))
    (dolist (key keys)
      (let ((j (gethash key pos))) (when j (remhash key pos) (push key common) (push j p))))
    (setq common (nreverse common))
    (let* ((keep (drgnx-view--lis (vconcat (nreverse p))))
           (moved (- (length common) (bool-vector-count-population keep))))
      (setq i 0)
      (dolist (key common) (when (aref keep i) (puthash key t kept)) (setq i (1+ i)))
      (if (> (* 2 moved) (length current))
          (progn (drgnx-view-reset view keys)
                 (dolist (key keys) (drgnx-view--sync-sig view key sig)))
        (let (gone prev run)
          (dolist (key current) (unless (gethash key kept) (push key gone)))
          (when gone (drgnx-view-remove view (nreverse gone)))
          (dolist (key keys)
            (if (not (gethash key kept))
                (progn (push key run) (drgnx-view--sync-sig view key sig))
              (when run (drgnx-view-insert view (nreverse run) :after prev) (setq run nil))
              (setq prev key)
              (when (drgnx-view--sync-sig view key sig) (puthash key 'patch (drgnx-view--dirty view)))))
          (when run (drgnx-view-insert view (nreverse run) :after prev)))))))

;;;; Reads

(defun drgnx-view-key-at (&optional pos)
  "The key of the row at POS (default: point) of the current buffer's view, or nil.  A binary search on the row
starts; allocates nothing."
  (let ((view drgnx-view))
    (when (drgnx-view-p view)
      (let* ((starts (drgnx-view--starts view)) (n (drgnx-view--n view))
             (rel (- (or pos (point)) (marker-position (drgnx-view--start view)))))
        (when (and (>= rel 0) (< rel (aref starts n)))
          (let ((lo 0) (hi n))                  ; starts[lo] <= rel < starts[hi]
            (while (> (- hi lo) 1)
              (let ((mid (ash (+ lo hi) -1)))
                (if (<= (aref starts mid) rel) (setq lo mid) (setq hi mid))))
            (aref (drgnx-view--keys view) lo)))))))

(defun drgnx-view-row-start (view key)
  "The buffer position where KEY's drawn row starts in VIEW, or nil."
  (let ((i (gethash key (drgnx-view--index view))))
    (and i (+ (marker-position (drgnx-view--start view)) (aref (drgnx-view--starts view) i)))))

(defun drgnx-view-row-count (view)
  "The number of rows drawn in VIEW."
  (drgnx-view--n view))

(defun drgnx-view-pending-p (view)
  "Non-nil if VIEW has marks not drawn yet."
  (or (drgnx-view--pending view) (drgnx-view--touched view)
      (> (hash-table-count (drgnx-view--dirty view)) 0)))

(defun drgnx-view-body-length (view key)
  "The length of KEY's drawn BODY in VIEW (a row rendered as (BODY . SUFFIX)), or nil."
  (gethash key (drgnx-view--bodies view)))

(defun drgnx-view-stats (&optional view)
  "VIEW's counters as a plist (:rows-drawn :rows-grown :appended :removed :slices :max-slice-rows :full-draws
:stale-skips).  Without VIEW, the sums over every live view (for :max-slice-rows, the largest)."
  (let* ((sum (make-vector (length drgnx-view--stat-names) 0)) (i (length sum)) plist)
    (dolist (v (if view (list view)
                 (delq nil (mapcar (lambda (b) (let ((v (buffer-local-value 'drgnx-view b))) (and (drgnx-view-p v) v)))
                                   (buffer-list)))))
      (let ((stats (drgnx-view--stats v)))
        (dotimes (i (length sum))
          (aset sum i (if (eq (aref drgnx-view--stat-names i) :max-slice-rows)
                          (max (aref sum i) (aref stats i))
                        (+ (aref sum i) (aref stats i)))))))
    (while (> i 0)
      (setq i (1- i) plist (cons (aref drgnx-view--stat-names i) (cons (aref sum i) plist))))
    plist))

(defun drgnx-view--check (view)
  "nil when VIEW's starts are its rows' actual extents (each row ends with a newline just before the next start,
the last at the end of the buffer, and the index points at each row); otherwise a string naming the first fault."
  (with-current-buffer (drgnx-view--buffer view)
    (save-restriction
      (widen)
      (let ((s (marker-position (drgnx-view--start view))) (starts (drgnx-view--starts view))
            (keys (drgnx-view--keys view)) (index (drgnx-view--index view)) (n (drgnx-view--n view)))
        (catch 'fault
          (unless (= 0 (aref starts 0)) (throw 'fault (format "row 0 starts at %d, not 0" (aref starts 0))))
          (dotimes (i n)
            (let ((beg (aref starts i)) (end (aref starts (1+ i))) (key (aref keys i)))
              (cond ((<= end beg) (throw 'fault (format "row %d (%S) is empty: %d to %d" i key beg end)))
                    ((> (+ s end) (point-max)) (throw 'fault (format "row %d (%S) runs past the buffer" i key)))
                    ((not (eq (char-after (+ s end -1)) ?\n))
                     (throw 'fault (format "row %d (%S) does not end with a newline at %d" i key end)))
                    ((not (eql (gethash key index) i))
                     (throw 'fault (format "row %d (%S) is indexed at %S" i key (gethash key index)))))))
          (unless (= (hash-table-count index) n)
            (throw 'fault (format "%d rows indexed, %d drawn" (hash-table-count index) n)))
          (unless (= (- (point-max) s) (aref starts n))
            (throw 'fault (format "the region is %d long, the rows %d" (- (point-max) s) (aref starts n))))
          nil)))))

(provide 'drgnx-view)
;;; drgnx-view.el ends here
