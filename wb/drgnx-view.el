;;; drgnx-view.el --- Views: keyed rows with integer starts, patched in place, never erased -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A view draws a buffer as rows, one per KEY, from START (its only marker) to the end of the buffer.  A view type
;; (`drgnx-view-define') says how a row is rendered (RENDER), how it grows at its end (GROW) and how the view pulls
;; changes from its model (SYNC).  Code that changes the model only MARKS the view: a mark is a hash put or a queue
;; push plus a timer arm, cheap enough for a process filter.  The draw runs from that timer, only while a window on
;; a visible frame shows the buffer (as the workbench state store records it),
;; in slices (at most `drgnx-view-slice' each, stopped by input; views ripe in
;; one timer pass share a deadline while it is unspent), visible rows first.  A draw first folds the structural marks into the row vectors (no buffer change), then works
;; row by row: a dirty row is deleted and inserted again at its integer start, a growing row gets only its new
;; characters, a new row is inserted, a removed row deleted.  Nothing is applied by erasing a region, undo is off,
;; and no row has a marker: row starts are integers, relative to START.  Window start and point stay on their row.
;;
;; `drgnx-view-draw-now' draws at once (for `g' and tests).  See docs/develop/core.md, "Views".

;;; Code:
(require 'cl-lib)
(require 'drgnx-modules-record)
(require 'drgnx-timer)
(require 'drgnx-wb)
(require 'drgnx-state)                  ; whether a view shows: the workbench state store

(defvar drgnx-signal-errors)            ; drgnx-signal, when loaded
(declare-function drgnx-gc-gap "drgnx-gc" ())

(defcustom drgnx-view-slice 0.004
  "The longest slice, in seconds, a view type may ask for.  Views ripe in one timer pass share an unspent deadline;
one that finds it spent starts its own slice."
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

(defvar drgnx-view--live (make-hash-table :test 'eq :weakness 'key)
  "The attached views (keys; weak, so a view whose buffer died goes): those the store's events update.")

(defconst drgnx-view--all (make-symbol "all")
  "The key `drgnx-view-dirty' stores in the dirty table for KEYS t: every row.")

(defconst drgnx-view--read-only '(read-only t front-sticky (read-only))
  "Text properties of a drawn row when the buffer is not read-only: an insertion at the row's start, inside it or
right after it would inherit `read-only' and is refused (see `drgnx-view--protect').")

(defconst drgnx-view--stat-names
  [:rows-drawn :rows-grown :appended :removed :slices :max-slice-rows :full-draws :stale-skips]
  "The names of the counters in a view's `stats' vector, in order.")

;;;; The frame budget: one deadline for every view in a timer pass

(defvar drgnx-view--deadline nil
  "When the slice now running ends (`drgnx-timer-now' time).  A view whose draw starts before it shares it.")

(defvar drgnx-view--slicing nil "Non-nil while a sliced draw runs: `drgnx-view--go-p' checks the deadline.")
(defvar drgnx-view--rows 0 "Rows the draw now running has drawn, grown or removed.")
(defvar drgnx-view--stopped nil "Non-nil once the draw now running stopped at its deadline or on input.")
(defvar drgnx-view--changed nil "Keys the draw now running drew or grew, newest first (for PATCHED).")
(defvar drgnx-view--syncing nil "The view whose SYNC runs now: its marks need no timer, the draw takes them.")

(defun drgnx-view--go-p ()
  "Non-nil if the draw now running may work on one more row (and count it).  Every `drgnx-view--check-every' rows a
sliced draw reads the clock and `input-pending-p': past the deadline or with input waiting it stops.  A slice always
draws its first row."
  (cond (drgnx-view--stopped nil)
        ((and drgnx-view--slicing (> drgnx-view--rows 0) (zerop (% drgnx-view--rows drgnx-view--check-every))
              (or (>= (drgnx-timer-now) drgnx-view--deadline) (input-pending-p)))
         (setq drgnx-view--stopped t)
         nil)
        (t (setq drgnx-view--rows (1+ drgnx-view--rows)) t)))

;;;; Types

(cl-defstruct (drgnx-view-type (:constructor drgnx-view--make-type) (:copier nil) (:predicate drgnx-view--type-struct-p))
  "A view type: how its rows are rendered, grown and synced (`drgnx-view-define')."
  name render grow sync slice delay follow-tail key-test patched)

(defun drgnx-view-type-p (name)
  "Non-nil if the view type NAME is defined now (`drgnx-view-define'; its module may have been turned off)."
  (and (assq name drgnx-view--types) t))

(cl-defun drgnx-view-define (name &key render grow sync slice delay follow-tail key-test patched)
  "Define the view type NAME and return NAME.
RENDER (KEY): the row's text, a string ending in a newline, or (BODY . SUFFIX) so that growth goes before SUFFIX.
GROW (KEY BODY-LENGTH): the characters to add at the end of the row's BODY, or nil to render the row again.
SYNC (VIEW): called at draw time after `drgnx-view-touch', to mark what changed (`drgnx-view-sync-rows').
SLICE: nil (draw all at once) or at most `drgnx-view-slice' seconds.  DELAY: the throttle (nil:
`drgnx-view-delay'; 0: draw at the next timer pass).  FOLLOW-TAIL: a window at the end stays at the end.
KEY-TEST: `eq' or `equal' (the default).  PATCHED (VIEW KEYS): called after a draw with the keys whose rows it drew
or grew.  The undo `\"view type NAME\"' removes the definition while it is still this one; views of a removed type
stop drawing."
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
  "Remove the view type NAME, when TYPE is nil or still its definition.  Its views stop drawing."
  (when (or (null type) (eq (alist-get name drgnx-view--types) type))
    (setq drgnx-view--types (assq-delete-all name drgnx-view--types))))

;;;; The record

(cl-defstruct (drgnx-view (:constructor drgnx-view--make) (:copier nil) (:conc-name drgnx-view--))
  "A view attached to a buffer.  Entry I of N is `keys'[I], from START + `starts'[I] to START + `starts'[I+1].
An entry is a row, or, between the slices of a draw, a row still to insert (empty, `work' `new'), a row still to
delete (`work' `gone', not in the index) or a deleted one (empty, not in the index)."
  buffer type
  start                                 ; the only marker: where the rows begin (insertion type nil)
  keys starts work                      ; vectors grown by doubling: N keys, N+1 starts, N work marks
  index                                 ; KEY → entry number (the type's KEY-TEST), for rows and rows to insert
  dirty                                 ; KEY → `patch' or `grow'; `drgnx-view--all' → `patch' for every row
  pending                               ; structural changes (OP KEYS AFTER), newest first
  bodies                                ; KEY → its BODY's length, for rows rendered as (BODY . SUFFIX)
  stale                                 ; non-nil: a draw found the view hidden; showing it draws it
  shown                                 ; whether it shows: the store's answer, or the last live one
  stats                                 ; the counters of `drgnx-view--stat-names'
  (n 0) touched
  error                                 ; the error message already recorded for this view
  sigs                                  ; KEY → its signature at the last `drgnx-view-sync-rows'
  (empty 0)                             ; how many entries are empty (to insert, or deleted)
  cut)                                  ; non-nil: the last draw stopped with work left in `work'

(cl-defun drgnx-view-attach (name &key buffer start)
  "Attach a view of type NAME to BUFFER (default: the current buffer), with rows from START (default `point-min').
START to the end of the buffer belongs to the view: text there that is not a row is deleted at the first draw.
Attach after the major mode (it kills local variables).  Undo is turned off.  The rows are read-only: the whole
buffer when START is `point-min', else each row, so text above START stays editable.  Attaching again removes the
old view's rows first.  Returns the view."
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
                                        :work (make-vector 16 nil)
                                        :index (make-hash-table :test test) :dirty (make-hash-table :test test)
                                        :bodies (make-hash-table :test test) :sigs (make-hash-table :test test)
                                        :stats (make-vector (length drgnx-view--stat-names) 0)))
          (setq buffer-undo-list t)
          (when (= start (point-min)) (setq buffer-read-only t))
          (puthash drgnx-view t drgnx-view--live)
          (when drgnx-state-mode
            (setf (drgnx-view--shown drgnx-view) (and (memq (current-buffer) (drgnx-view--store-shown)) t)))
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

;;;; Visibility: the workbench state store's records while `drgnx-state-mode' is on, else live windows

(defun drgnx-view--store-shown ()
  "The buffers a window the workbench state store recorded shows on a visible frame (any terminal's)."
  (let ((out nil))
    (dolist (f (drgnx-state-frames))
      (when (eq (frame-visible-p f) t)
        (dolist (w (drgnx-state-windows f)) (push (window-buffer w) out))))
    out))

(defun drgnx-view--windows-changed (&optional _data)
  "A subscriber of the store's `windows-changed', `frame-visibility' and `frame-removed' (lane `now', core/workbench's
setup): set each attached view's `shown' from the store's records (`drgnx-view--store-shown'), and arm the draw of a
stale view that shows now.  It only marks and arms; it never draws (it may run during redisplay)."
  (let ((shown (drgnx-view--store-shown)))
    (maphash (lambda (view _)
               (let ((buffer (drgnx-view--buffer view)))
                 (if (not (and (buffer-live-p buffer) (eq view (buffer-local-value 'drgnx-view buffer))))
                     (remhash view drgnx-view--live)
                   (setf (drgnx-view--shown view) (and (memq buffer shown) t))
                   (when (and (drgnx-view--shown view) (drgnx-view--stale view))
                     (drgnx-view--arm view)))))
             drgnx-view--live)))

(defun drgnx-view--tree-shows-p (window buffer)
  "Non-nil if WINDOW, its siblings after it or their children show BUFFER.  Allocates nothing."
  (let ((found nil))
    (while (and window (not found))
      (setq found (if (window-live-p window)
                      (eq (window-buffer window) buffer)
                    (drgnx-view--tree-shows-p (window-child window) buffer))
            window (window-next-sibling window)))
    found))

(defun drgnx-view--frame-shows-p (frame buffer)
  (and (eq (frame-visible-p frame) t) (drgnx-view--tree-shows-p (frame-root-window frame) buffer)))

(defun drgnx-view-shown-p (view)
  "Non-nil if a window on a visible frame shows VIEW's buffer.  One source at a time: while `drgnx-state-mode' is on,
the view's `shown', which the store's events keep (`drgnx-view--windows-changed'; every terminal's frames); else the
live windows, as `get-buffer-window' with `visible' answers, without its window list: the frames `next-frame' reaches
from the selected one (that terminal's) and their window trees.  Allocates nothing."
  (if drgnx-state-mode
      (drgnx-view--shown view)
    (let* ((buffer (drgnx-view--buffer view)) (start (selected-frame))
           (found (drgnx-view--frame-shows-p start buffer)))
      (unless found
        (let* ((first (next-frame start t)) (frame first))
          (while (and (not found) (not (eq frame start))
                      (progn (setq found (drgnx-view--frame-shows-p frame buffer))
                             (setq frame (next-frame frame t))
                             (not (eq frame first)))))))
      (setf (drgnx-view--shown view) found))))

;;;; Marks: a hash put or a queue push, then `drgnx-view--arm'

(defun drgnx-view--arm (view)
  "Arm VIEW's draw: the timer `(drgnx-view . BUFFER)', DELAY after the first mark of a burst, at most once per DELAY
\(a DELAY of 0: at the next timer pass).  Nothing while VIEW's SYNC runs (that draw takes the marks), while a
slice chain's continuation `(drgnx-view-more . BUFFER)' is pending (its next slice takes them), for a view no longer
attached, or for a stale view that is still hidden: showing it arms the draw."
  (let ((buffer (drgnx-view--buffer view)))
    (when (and (not (eq view drgnx-view--syncing))
               (buffer-live-p buffer) (eq view (buffer-local-value 'drgnx-view buffer))
               (not (drgnx-timer-active-p (cons 'drgnx-view-more buffer)))
               (or (not (drgnx-view--stale view)) (drgnx-view-shown-p view)))
      (setf (drgnx-view--stale view) nil)
      (let ((delay (or (drgnx-view-type-delay (drgnx-view--type view)) drgnx-view-delay)))
        (if (> delay 0)
            (drgnx-timer-soon (cons 'drgnx-view buffer) delay #'drgnx-view--draw-buffer
                              :args (list buffer) :min-interval delay :owner buffer)
          (drgnx-timer-soon (cons 'drgnx-view buffer) 0 #'drgnx-view--draw-buffer
                            :args (list buffer) :owner buffer))))))

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

(defun drgnx-view--ghost-p (view i)
  "Non-nil if VIEW's entry I is not a row of the model: a row still to delete, or a deleted one."
  (let ((w (aref (drgnx-view--work view) i)) (starts (drgnx-view--starts view)))
    (or (eq w 'gone) (and (= (aref starts i) (aref starts (1+ i))) (not (eq w 'new))))))

(defun drgnx-view--walk (view plan fn)
  "Call FN (KEY I STATE) for each entry of VIEW after PLAN, in buffer order: STATE nil for entry I that stays,
`gone' for entry I that PLAN removes, `ghost' for entry I that is no row of the model (`drgnx-view--ghost-p'), `new'
\(I nil) for a new row.  PLAN nil: every entry stays."
  (let ((keys (drgnx-view--keys view)) (n (drgnx-view--n view)) (i 0)
        (all (and plan (drgnx-view--plan-all-gone plan)))
        (gone (and plan (drgnx-view--plan-gone plan)))
        (after-old (and plan (drgnx-view--plan-after-old plan))))
    (when plan (drgnx-view--walk-group plan (drgnx-view--plan-first plan) fn))
    (while (< i n)
      (let ((key (aref keys i)))
        (if (drgnx-view--ghost-p view i)
            (funcall fn key i 'ghost)
          (funcall fn key i (and plan (or all (gethash key gone)) 'gone))
          (when plan
            (let ((group (gethash key after-old))) (when group (drgnx-view--walk-group plan group fn))))))
      (setq i (1+ i)))
    (when plan (drgnx-view--walk-group plan (drgnx-view--plan-end plan) fn))))

;;;; Rows: render, insert, grow

(defun drgnx-view--record (view message)
  "Record MESSAGE as VIEW's error, unless VIEW already recorded one: in `drgnx-signal-errors' when it is bound."
  (unless (drgnx-view--error view)
    (setf (drgnx-view--error view) message)
    (when (boundp 'drgnx-signal-errors)
      (push (format "view %s: %s" (drgnx-view-type-name (drgnx-view--type view)) message) drgnx-signal-errors)
      (setq drgnx-signal-errors (take 20 drgnx-signal-errors)))))

(defun drgnx-view--error-text (key message)
  "The row drawn for KEY when its RENDER or GROW signalled MESSAGE (KEY printed to 60 characters at most)."
  (propertize (format "⚠ %.60s: %s\n" key message) 'face 'error))

(defun drgnx-view--newline-end-p (string)
  (let ((n (length string))) (and (> n 0) (eq (aref string (1- n)) ?\n))))

(defun drgnx-view--row-p (r)
  "Non-nil if R is a row's text: a string ending in a newline, or (BODY . SUFFIX) whose SUFFIX ends in one (so text
GROW puts after BODY never lands after the newline)."
  (if (stringp r)
      (drgnx-view--newline-end-p r)
    (and (consp r) (stringp (car r)) (stringp (cdr r)) (drgnx-view--newline-end-p (cdr r)))))

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

(defun drgnx-view--protect (beg end)
  "Make BEG..END of a row read-only and front-sticky, unless the whole buffer is read-only: an insertion at the
row's start, inside it or right after it is refused.  Text above START stays editable."
  (unless buffer-read-only
    (add-text-properties beg end drgnx-view--read-only)))

(defun drgnx-view--put-row (view key pos text)
  "Insert TEXT, KEY's row (a string or (BODY . SUFFIX)), at POS; note its body; return its length."
  (goto-char pos)
  (if (consp text)
      (progn (insert (car text) (cdr text))
             (puthash key (length (car text)) (drgnx-view--bodies view)))
    (insert text)
    (remhash key (drgnx-view--bodies view)))
  (drgnx-view--protect pos (point))
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
                     (drgnx-view--protect (+ pos body) (point))
                     (puthash key (+ body (length text)) (drgnx-view--bodies view))
                     (cl-incf (aref (drgnx-view--stats view) 1))
                     (+ len (length text)))))
        (error
         (let ((message (error-message-string err)))
           (drgnx-view--record view message)
           (delete-region pos (+ pos len))
           (drgnx-view--put-row view key pos (drgnx-view--error-text key message))))))))

;;;; The fold: structural marks into the vectors, without touching the buffer

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

(defun drgnx-view--only-at-end-p (plan)
  "Non-nil if PLAN puts no new row before a row that stays: only appends and removals."
  (and (null (car (drgnx-view--plan-first plan)))
       (catch 'no
         (maphash (lambda (_ box) (when (car box) (throw 'no nil))) (drgnx-view--plan-after-old plan))
         t)))

(defun drgnx-view--fold (view)
  "Apply VIEW's pending structural changes to its vectors; the buffer does not change.  A row that goes stays as an
entry marked `gone' (a slice deletes it), a new row is an empty entry marked `new' (a slice inserts it), and empty
entries of rows deleted earlier are dropped.  The vectors are rewritten in place when new rows only go at the end
\(appends, removals), grown by doubling only when full; otherwise fresh ones are made.  A plan that only appends
\(no row goes) visits only its new rows (`drgnx-view--fold-tail')."
  (let ((plan (drgnx-view--plan-pending view)))
    (cond
     ((null plan))
     ((and (not (drgnx-view--plan-all-gone plan)) (zerop (hash-table-count (drgnx-view--plan-gone plan)))
           (drgnx-view--only-at-end-p plan))
      (setf (drgnx-view--pending view) nil)
      (drgnx-view--fold-tail view plan))
     (t
      (drgnx-view--forget-gone view plan)
      (setf (drgnx-view--pending view) nil)
      (let* ((okeys (drgnx-view--keys view)) (ostarts (drgnx-view--starts view)) (owork (drgnx-view--work view))
             (index (drgnx-view--index view)) (n (drgnx-view--n view))
             (cap (length okeys)) (need (+ n (hash-table-count (drgnx-view--plan-new plan)) 1))
             nkeys nstarts nwork (here 0) (o 0) (empty 0))
        (while (< cap need) (setq cap (* 2 cap)))
        (if (and (= cap (length okeys)) (drgnx-view--only-at-end-p plan))
            (setq nkeys okeys nstarts ostarts nwork owork)     ; o <= i throughout: no unread entry is overwritten
          (setq nkeys (make-vector cap nil) nstarts (make-vector (1+ cap) 0) nwork (make-vector cap nil)))
        (drgnx-view--walk
         view plan
         (lambda (key i state)
           (let ((len (if i (- (aref ostarts (1+ i)) (aref ostarts i)) 0)) (mark nil) (keep t))
             (cond ((eq state 'new) (setq mark 'new) (puthash key o index))
                   ((memq state '(gone ghost)) (if (> len 0) (setq mark 'gone) (setq keep nil)))
                   (t (setq mark (aref owork i))
                      (unless (eql i o) (puthash key o index))))
             (when keep
               (aset nkeys o key)
               (aset nstarts o here)
               (aset nwork o mark)
               (when (= len 0) (setq empty (1+ empty)))
               (setq here (+ here len) o (1+ o))))))
        (aset nstarts o here)
        (when (eq nkeys okeys) (drgnx-view--clear-entries nkeys nwork o n))
        (setf (drgnx-view--n view) o (drgnx-view--keys view) nkeys (drgnx-view--starts view) nstarts
              (drgnx-view--work view) nwork (drgnx-view--empty view) empty))))))

(defun drgnx-view--fold-tail (view plan)
  "Fold PLAN, which only adds rows at the end (no row goes, none comes before a drawn one): its new rows become empty
entries marked `new' after VIEW's entries, which stay as they are (rows still to delete, and empty ones of rows
deleted, are left to the sweep and `drgnx-view--compact').  Only the new tail is visited; the vectors grow by
doubling, copied, only when full."
  (let* ((n (drgnx-view--n view)) (keys (drgnx-view--keys view)) (starts (drgnx-view--starts view))
         (work (drgnx-view--work view)) (index (drgnx-view--index view))
         (need (+ n (hash-table-count (drgnx-view--plan-new plan)) 1)) (cap (length keys)))
    (when (< cap need)
      (while (< cap need) (setq cap (* 2 cap)))
      (let ((nkeys (make-vector cap nil)) (nstarts (make-vector (1+ cap) 0)) (nwork (make-vector cap nil)))
        (dotimes (i n) (aset nkeys i (aref keys i)) (aset nstarts i (aref starts i)) (aset nwork i (aref work i)))
        (aset nstarts n (aref starts n))
        (setq keys nkeys starts nstarts work nwork)
        (setf (drgnx-view--keys view) keys (drgnx-view--starts view) starts (drgnx-view--work view) work)))
    (let ((o n) (end (aref starts n)))
      (drgnx-view--walk-group plan (drgnx-view--plan-end plan)
                              (lambda (key _ _)
                                (aset keys o key) (aset starts o end) (aset work o 'new) (puthash key o index)
                                (setq o (1+ o))))
      (aset starts o end)
      (setf (drgnx-view--n view) o (drgnx-view--empty view) (+ (drgnx-view--empty view) (- o n))))))

(defun drgnx-view--clear-entries (keys work from to)
  "Clear KEYS and WORK from FROM to TO (exclusive), so dropped entries hold no key."
  (while (< from to) (aset keys from nil) (aset work from nil) (setq from (1+ from))))

(defun drgnx-view--take-dirty (view)
  "Move VIEW's dirty marks onto its entries' work marks (`patch' wins over `grow'; a row to insert or delete keeps
its mark) and empty the dirty table.  Marks of keys with no row are dropped."
  (let ((dirty (drgnx-view--dirty view)))
    (when (> (hash-table-count dirty) 0)
      (let ((work (drgnx-view--work view)) (index (drgnx-view--index view)) (starts (drgnx-view--starts view)))
        (when (gethash drgnx-view--all dirty)
          (dotimes (i (drgnx-view--n view))
            (when (and (memq (aref work i) '(nil grow)) (< (aref starts i) (aref starts (1+ i))))
              (aset work i 'patch))))
        (maphash (lambda (key mark)
                   (let ((i (gethash key index)))
                     (when i
                       (let ((w (aref work i)))
                         (cond ((null w) (aset work i mark))
                               ((and (eq w 'grow) (eq mark 'patch)) (aset work i 'patch)))))))
                 dirty)
        (clrhash dirty)))))

;;;; The sweep: row work in buffer order, one running shift

(defun drgnx-view--do-row (view key mark pos len)
  "Do the work MARK on KEY's entry at POS, LEN long; return its new length."
  (let ((stats (drgnx-view--stats view)) (new nil))
    (pcase mark
      ('gone (delete-region pos (+ pos len))
             (cl-incf (aref stats 3))
             (cl-incf (drgnx-view--empty view))
             (setq new 0))
      ('new (setq new (drgnx-view--put-row view key pos (drgnx-view--render view key)))
            (cl-incf (aref stats 2))
            (cl-decf (drgnx-view--empty view)))
      ('patch (delete-region pos (+ pos len))
              (setq new (drgnx-view--put-row view key pos (drgnx-view--render view key))))
      (_ (setq new (or (drgnx-view--grow-row view key pos len)
                       (progn (delete-region pos (+ pos len))
                              (drgnx-view--put-row view key pos (drgnx-view--render view key)))))))
    (when (and (not (eq mark 'gone)) (drgnx-view-type-patched (drgnx-view--type view)))
      (push key drgnx-view--changed))
    new))

(defun drgnx-view--sweep (view ranges)
  "Do the work marks of VIEW's entries in RANGES, sorted disjoint (FROM . TO) entry ranges, or t for every entry, in
buffer order while `drgnx-view--go-p' allows; shift the starts after each changed row.  In VIEW's buffer."
  (let* ((keys (drgnx-view--keys view)) (starts (drgnx-view--starts view)) (work (drgnx-view--work view))
         (n (drgnx-view--n view)) (s (marker-position (drgnx-view--start view)))
         (all (eq ranges t)) (i (if all 0 (car (car ranges)))) (delta 0))
    (while (< i n)
      (unless all
        (while (and ranges (>= i (cdr (car ranges)))) (setq ranges (cdr ranges)))
        (when (and ranges (= delta 0) (< i (car (car ranges)))) (setq i (car (car ranges)))))
      (if (and (= delta 0) (or drgnx-view--stopped (and (not all) (null ranges))))
          (setq i n)                    ; nothing left to do or to shift
        (let ((beg (+ (aref starts i) delta)) (mark (aref work i)))
          (aset starts i beg)
          (when (and mark (or all (and ranges (>= i (car (car ranges))))) (drgnx-view--go-p))
            (let* ((len (- (+ (aref starts (1+ i)) delta) beg))
                   (new (drgnx-view--do-row view (aref keys i) mark (+ s beg) len)))
              (aset work i nil)
              (setq delta (+ delta (- new len)))))
          (setq i (1+ i)))))
    (aset starts n (+ (aref starts n) delta))))

(defun drgnx-view--compact (view)
  "Drop VIEW's empty entries (rows deleted), in place, and point the index at the entries that moved."
  (let ((keys (drgnx-view--keys view)) (starts (drgnx-view--starts view)) (work (drgnx-view--work view))
        (index (drgnx-view--index view)) (n (drgnx-view--n view)) (i 0) (o 0))
    (while (< i n)
      (when (< (aref starts i) (aref starts (1+ i)))
        (unless (= i o)
          (let ((key (aref keys i)))
            (aset keys o key) (aset starts o (aref starts i)) (aset work o (aref work i))
            (puthash key o index)))
        (setq o (1+ o)))
      (setq i (1+ i)))
    (aset starts o (aref starts n))
    (drgnx-view--clear-entries keys work o n)
    (setf (drgnx-view--n view) o (drgnx-view--empty view) 0)))

(defun drgnx-view--visible-ranges (view)
  "The entries VIEW's windows on visible frames show, as sorted disjoint (FROM . TO) ranges: from the entry at the
window's start, `window-body-height' entries."
  (let ((s (marker-position (drgnx-view--start view))) (n (drgnx-view--n view)) ranges out)
    (when (> n 0)
      (dolist (w (get-buffer-window-list (drgnx-view--buffer view) nil 'visible))
        (let* ((rel (- (window-start w) s)) (i (if (< rel 0) 0 (drgnx-view--entry-at view rel))))
          (when i (push (cons i (+ i (window-body-height w))) ranges))))
      (dolist (r (sort ranges (lambda (a b) (< (car a) (car b)))))
        (if (and out (<= (car r) (cdr (car out))))
            (setcdr (car out) (max (cdr (car out)) (cdr r)))
          (push (cons (car r) (cdr r)) out))))
    (nreverse out)))

;;;; Places: window start and point stay on their row

(defun drgnx-view--live-p (view i)
  (let ((starts (drgnx-view--starts view))) (< (aref starts i) (aref starts (1+ i)))))

(defun drgnx-view--live-after (view i)
  "The first non-empty entry of VIEW from I on, or nil."
  (let ((n (drgnx-view--n view)))
    (while (and (< i n) (not (drgnx-view--live-p view i))) (setq i (1+ i)))
    (and (< i n) i)))

(defun drgnx-view--live-before (view i)
  "The last non-empty entry of VIEW before I, or nil."
  (setq i (1- i))
  (while (and (>= i 0) (not (drgnx-view--live-p view i))) (setq i (1- i)))
  (and (>= i 0) i))

(defun drgnx-view--row-place (view pos follow)
  "POS as a place in VIEW: [ENTRY OFFSET TAG POS].  TAG nil: OFFSET into ENTRY; `abs': POS itself (above START, or
an empty view); `tail': the end of the buffer (FOLLOW and POS at the end); `row-end': the end of ENTRY (POS at
the end, not FOLLOW)."
  (let* ((rel (- pos (marker-position (drgnx-view--start view)))) (starts (drgnx-view--starts view))
         (n (drgnx-view--n view)))
    (cond ((< rel 0) (vector nil 0 'abs pos))
          ((< rel (aref starts n))
           (let ((i (drgnx-view--entry-at view rel))) (vector i (- rel (aref starts i)) nil pos)))
          (follow (vector nil 0 'tail pos))
          (t (let ((i (drgnx-view--live-before view n)))
               (if i (vector i 0 'row-end pos) (vector nil 0 'abs pos)))))))

(defun drgnx-view--row-place-pos (view place)
  "Where PLACE (`drgnx-view--row-place') is now.  An entry that was deleted falls to the next non-empty one, or to
the previous one at the end."
  (let ((tag (aref place 2)) (s (marker-position (drgnx-view--start view))) (starts (drgnx-view--starts view)))
    (cond ((eq tag 'abs) (max (point-min) (min (aref place 3) (point-max))))
          ((eq tag 'tail) (point-max))
          (t (let* ((i (aref place 0))
                    (j (if (drgnx-view--live-p view i) i
                         (or (drgnx-view--live-after view (1+ i)) (drgnx-view--live-before view i)))))
               (cond ((null j) s)
                     ((not (eql j i)) (+ s (aref starts j)))
                     ((eq tag 'row-end) (+ s (aref starts (1+ i))))
                     (t (+ s (aref starts i)
                           (min (aref place 1) (- (aref starts (1+ i)) (aref starts i) 1))))))))))

(defun drgnx-view--save-row-places (view)
  "The buffer's point and, for each window showing the buffer (all frames), its start and point, as places:
\(POINT-PLACE (WINDOW START-PLACE POINT-PLACE)...).  In VIEW's buffer."
  (let ((follow (drgnx-view-type-follow-tail (drgnx-view--type view))) windows)
    (dolist (w (get-buffer-window-list (current-buffer) nil t))
      (push (list w (drgnx-view--row-place view (window-start w) nil)
                  (drgnx-view--row-place view (window-point w) follow))
            windows))
    (cons (drgnx-view--row-place view (point) follow) windows)))

(defun drgnx-view--restore-row-places (view places)
  "Put the buffer's point and each live window of PLACES back on its row (`drgnx-view--save-row-places').  The
windows move as the caller's own (`drgnx-wb-with-owned-windows')."
  (goto-char (drgnx-view--row-place-pos view (car places)))
  (when (cdr places)
    (drgnx-wb-with-owned-windows (mapcar #'car (cdr places))
      (dolist (e (cdr places))
        (let ((w (car e)))
          (when (and (window-live-p w) (eq (window-buffer w) (current-buffer)))
            (set-window-start w (drgnx-view--row-place-pos view (nth 1 e)) t)
            (set-window-point w (drgnx-view--row-place-pos view (nth 2 e)))))))))

;;;; The draw

(defun drgnx-view--self-check (view)
  "When VIEW's region (START to the end of the buffer) is not as long as its entries, reset it: delete the region and
draw every row again, before the pending changes.  In VIEW's buffer, widened."
  (let ((s (marker-position (drgnx-view--start view))) (n (drgnx-view--n view)))
    (unless (= (- (point-max) s) (aref (drgnx-view--starts view) n))
      (let (old)
        (drgnx-view--walk view nil (lambda (key _ state) (unless (eq state 'ghost) (push key old))))
        (delete-region s (point-max))
        (setf (drgnx-view--n view) 0 (drgnx-view--empty view) 0 (drgnx-view--cut view) nil)
        (aset (drgnx-view--starts view) 0 0)
        (drgnx-view--clear-entries (drgnx-view--keys view) (drgnx-view--work view) 0 n)
        (clrhash (drgnx-view--index view))
        (clrhash (drgnx-view--bodies view))
        (setf (drgnx-view--pending view) (nconc (drgnx-view--pending view) (list (list 'append (nreverse old) nil))))
        (cl-incf (aref (drgnx-view--stats view) 6))))))

(defun drgnx-view--current-type (view)
  "VIEW's type as defined now, looked up by name (stored in VIEW when it was redefined), or nil once removed."
  (let ((type (alist-get (drgnx-view-type-name (drgnx-view--type view)) drgnx-view--types)))
    (when type (setf (drgnx-view--type view) type))))

(defun drgnx-view--draw (view slice)
  "Draw VIEW: SYNC when touched, the self-check, the fold, then the row work, the visible rows first when SLICE (a
number of seconds: stop at the shared deadline or on input).  Window start and point stay on their row.  Returns the
rows drawn, grown or removed; the view's `cut' says whether work is left."
  (with-current-buffer (drgnx-view--buffer view)
    (save-restriction
      (widen)
      (let ((inhibit-read-only t) (inhibit-interaction t)
            (drgnx-view--slicing (and slice t)) (drgnx-view--rows 0) (drgnx-view--stopped nil)
            (drgnx-view--changed nil) (type (drgnx-view--type view)))
        (when slice
          (let ((now (drgnx-timer-now)))
            (unless (and drgnx-view--deadline (> drgnx-view--deadline now))
              (setq drgnx-view--deadline (+ now slice)))))
        (when (drgnx-view--touched view)
          (setf (drgnx-view--touched view) nil)
          (let ((sync (drgnx-view-type-sync type)))
            (when sync
              (let ((drgnx-view--syncing view))
                (condition-case err (funcall sync view)
                  (error (drgnx-view--record view (format "SYNC: %s" (error-message-string err)))))))))
        (drgnx-view--self-check view)
        (drgnx-view--fold view)
        (drgnx-view--take-dirty view)
        (let ((places (drgnx-view--save-row-places view)))
          (when slice
            (let ((ranges (drgnx-view--visible-ranges view))) (when ranges (drgnx-view--sweep view ranges))))
          (drgnx-view--sweep view t)
          (when (> drgnx-view--rows 0) (drgnx-view--restore-row-places view places)))
        (setf (drgnx-view--cut view) drgnx-view--stopped)
        (when (and (not drgnx-view--stopped) (> (drgnx-view--empty view) 0)) (drgnx-view--compact view))
        (when (> drgnx-view--rows 0) (set-buffer-modified-p nil))
        (let ((patched (drgnx-view-type-patched type)))
          (when (and patched drgnx-view--changed)
            (condition-case err (funcall patched view (nreverse drgnx-view--changed))
              (error (drgnx-view--record view (format "PATCHED: %s" (error-message-string err)))))))
        drgnx-view--rows))))

(defun drgnx-view-draw-now (view)
  "Draw VIEW now, whole, even when hidden: run SYNC when touched, then apply every mark.  Window start and point stay
on their row.  Returns the number of rows drawn, grown or removed; 0 for a view no longer attached or whose type
was removed.  A RENDER, GROW, SYNC or PATCHED that signals is recorded (`drgnx-view--record'), never raised."
  (let ((buffer (drgnx-view--buffer view)))
    (if (and (buffer-live-p buffer) (eq view (buffer-local-value 'drgnx-view buffer))
             (drgnx-view--current-type view))
        (prog1 (drgnx-view--draw view nil) (setf (drgnx-view--stale view) nil))
      0)))

(defun drgnx-view--draw-buffer (buffer)
  "The timer function of BUFFER's view (keys `(drgnx-view . BUFFER)' and `(drgnx-view-more . BUFFER)').
Hidden: mark it stale, count a `:stale-skips', draw and allocate nothing.  Shown: draw one slice (a type with SLICE)
or everything; work left re-arms `(drgnx-view-more . BUFFER)' at 0; when no view has work left, `drgnx-gc-gap'."
  (let ((view (and (buffer-live-p buffer) (buffer-local-value 'drgnx-view buffer))))
    (when (drgnx-view-p view)
      (cond ((not (drgnx-view-shown-p view))
             (setf (drgnx-view--stale view) t)
             (cl-incf (aref (drgnx-view--stats view) 7)))
            ((drgnx-view--current-type view)
             (setf (drgnx-view--stale view) nil)
             (let* ((slice (drgnx-view-type-slice (drgnx-view--type view)))
                    (rows (drgnx-view--draw view slice)) (stats (drgnx-view--stats view)))
               (when (and slice (> rows 0))
                 (cl-incf (aref stats 4))
                 (when (> rows (aref stats 5)) (aset stats 5 rows)))
               (if (drgnx-view--cut view)
                   (progn
                     (drgnx-timer-cancel (cons 'drgnx-view buffer))   ; a mark made during this draw: the chain takes it
                     (drgnx-timer-start (cons 'drgnx-view-more buffer) 0 #'drgnx-view--draw-buffer
                                        :args (list buffer) :owner buffer))
                 (drgnx-view--pass-over))))))))

(defun drgnx-view--pass-over ()
  "When no view that is not stale has work left, call `drgnx-gc-gap' (when loaded): the gap is quiet."
  (let ((buffers (buffer-list)) (busy nil))
    (while (and buffers (not busy))
      (let ((v (buffer-local-value 'drgnx-view (car buffers))))
        (setq busy (and (drgnx-view-p v) (not (drgnx-view--stale v)) (drgnx-view-pending-p v))
              buffers (cdr buffers))))
    (when (and (not busy) (fboundp 'drgnx-gc-gap)) (drgnx-gc-gap))))

;;;; Keeping places in any buffer

(defun drgnx-view--key-place (pos key-at)
  "POS as (KEY OFFSET LINE): KEY = (KEY-AT POS), OFFSET from the start of KEY's row (the first of the lines above
POS whose key is KEY), LINE POS's line number."
  (save-excursion
    (goto-char pos)
    (let ((key (funcall key-at pos)) (line (line-number-at-pos pos t)))
      (forward-line 0)
      (when key
        (while (and (not (bobp)) (equal (funcall key-at (line-beginning-position 0)) key)) (forward-line -1)))
      (list key (- pos (point)) line))))

(defun drgnx-view--key-place-pos (place pos-of)
  "Where PLACE (`drgnx-view--key-place') is now: (POS-OF KEY) + OFFSET, or the start of its LINE (clamped)."
  (let ((start (and (car place) (funcall pos-of (car place)))))
    (if start
        (max (point-min) (min (+ start (nth 1 place)) (point-max)))
      (save-excursion (goto-char (point-min)) (forward-line (1- (nth 2 place))) (point)))))

(defun drgnx-view-save-places (key-at)
  "The current buffer's point and, for each window showing it (all frames), its start and point, each as
\(KEY OFFSET LINE) with KEY = (KEY-AT POS) and OFFSET the distance from KEY's row start.  The value is
\(POINT-PLACE (WINDOW START-PLACE POINT-PLACE)...), for `drgnx-view-restore-places'."
  (cons (drgnx-view--key-place (point) key-at)
        (mapcar (lambda (w) (list w (drgnx-view--key-place (window-start w) key-at)
                                  (drgnx-view--key-place (window-point w) key-at)))
                (get-buffer-window-list (current-buffer) nil t))))

(defun drgnx-view-restore-places (places pos-of)
  "Put the point and windows of PLACES (`drgnx-view-save-places') back: each at (+ (POS-OF KEY) OFFSET), POS-OF
giving a row's start, or at its LINE (clamped) when POS-OF returns nil.  Dead windows, and windows that show
another buffer now, are skipped.  The windows move as the caller's own (`drgnx-wb-with-owned-windows')."
  (goto-char (drgnx-view--key-place-pos (car places) pos-of))
  (drgnx-wb-with-owned-windows (mapcar #'car (cdr places))
    (dolist (e (cdr places))
      (let ((w (car e)))
        (when (and (window-live-p w) (eq (window-buffer w) (current-buffer)))
          (set-window-start w (drgnx-view--key-place-pos (nth 1 e) pos-of) t)
          (set-window-point w (drgnx-view--key-place-pos (nth 2 e) pos-of)))))))

(cl-defmacro drgnx-view-with-kept-windows ((&key key-at pos-of) &rest body)
  "Run BODY keeping the current buffer's point and its windows' start and point on their rows: save them by key
with KEY-AT, run BODY, restore them with POS-OF (`drgnx-view-save-places', `drgnx-view-restore-places').
Returns BODY's value."
  (declare (indent 1))
  (let ((places (make-symbol "places")))
    `(let ((,places (drgnx-view-save-places ,key-at)))
       (prog1 (progn ,@body) (drgnx-view-restore-places ,places ,pos-of)))))

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
rows moved, or KEYS share no key with the rows (a new row set), the view is reset instead, so window start and point
go to its first row.  The drawn rows and the pending changes are both taken into account."
  (let* ((plan (drgnx-view--plan-pending view))
         (n (drgnx-view--n view)) (vkeys (drgnx-view--keys view))
         (same (and (null plan) (not (drgnx-view--cut view))
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
         (current (let (l) (drgnx-view--walk view plan (lambda (key _ state)
                                                         (unless (memq state '(gone ghost)) (push key l))))
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
      (if (or (null common) (> (* 2 moved) (length current)))   ; a new row set: places go to its first row
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

(defun drgnx-view--entry-at (view rel)
  "The entry of VIEW that holds the position REL (relative to START), or nil.  A binary search on the starts (an
empty entry never holds a position); allocates nothing."
  (let ((starts (drgnx-view--starts view)) (n (drgnx-view--n view)))
    (when (and (>= rel 0) (< rel (aref starts n)))
      (let ((lo 0) (hi n))                  ; starts[lo] <= rel < starts[hi]
        (while (> (- hi lo) 1)
          (let ((mid (ash (+ lo hi) -1)))
            (if (<= (aref starts mid) rel) (setq lo mid) (setq hi mid))))
        lo))))

(defun drgnx-view-key-at (&optional pos)
  "The key of the row at POS (default: point) of the current buffer's view, or nil.  A binary search on the row
starts; allocates nothing."
  (let ((view drgnx-view))
    (when (drgnx-view-p view)
      (let ((i (drgnx-view--entry-at view (- (or pos (point)) (marker-position (drgnx-view--start view))))))
        (and i (aref (drgnx-view--keys view) i))))))

(defun drgnx-view-row-start (view key)
  "The buffer position where KEY's drawn row starts in VIEW, or nil."
  (let ((i (gethash key (drgnx-view--index view))))
    (and i (+ (marker-position (drgnx-view--start view)) (aref (drgnx-view--starts view) i)))))

(defun drgnx-view-row-count (view)
  "The number of rows in VIEW's buffer (between the slices of a draw, rows still to delete count too)."
  (- (drgnx-view--n view) (drgnx-view--empty view)))

(defun drgnx-view-pending-p (view)
  "Non-nil if VIEW has marks not drawn yet."
  (or (drgnx-view--pending view) (drgnx-view--touched view) (drgnx-view--cut view)
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
        (dotimes (j (length sum))
          (aset sum j (if (eq (aref drgnx-view--stat-names j) :max-slice-rows)
                          (max (aref sum j) (aref stats j))
                        (+ (aref sum j) (aref stats j)))))))
    (while (> i 0)
      (setq i (1- i) plist (cons (aref drgnx-view--stat-names i) (cons (aref sum i) plist))))
    plist))

(defun drgnx-view--check (view)
  "nil when VIEW's starts are its entries' actual extents (each non-empty entry ends with a newline just before the
next start, the last at the end of the buffer; an empty entry is a row to insert or a deleted one) and the index
points at each row and row to insert; otherwise a string naming the first fault."
  (with-current-buffer (drgnx-view--buffer view)
    (save-restriction
      (widen)
      (let ((s (marker-position (drgnx-view--start view))) (starts (drgnx-view--starts view))
            (keys (drgnx-view--keys view)) (work (drgnx-view--work view)) (index (drgnx-view--index view))
            (n (drgnx-view--n view)) (rows 0) (empty 0))
        (catch 'fault
          (unless (= 0 (aref starts 0)) (throw 'fault (format "row 0 starts at %d, not 0" (aref starts 0))))
          (dotimes (i n)
            (let* ((beg (aref starts i)) (end (aref starts (1+ i))) (key (aref keys i)) (w (aref work i))
                   (row (not (drgnx-view--ghost-p view i))))
              (when (= end beg) (setq empty (1+ empty)))
              (cond ((< end beg) (throw 'fault (format "row %d (%S) runs backwards: %d to %d" i key beg end)))
                    ((> (+ s end) (point-max)) (throw 'fault (format "row %d (%S) runs past the buffer" i key)))
                    ((and (> end beg) (not (eq (char-after (+ s end -1)) ?\n)))
                     (throw 'fault (format "row %d (%S) does not end with a newline at %d" i key end)))
                    ((and (= end beg) w (not (eq w 'new)))
                     (throw 'fault (format "row %d (%S) is empty with work %S" i key w)))
                    ((and row (not (eql (gethash key index) i)))
                     (throw 'fault (format "row %d (%S) is indexed at %S" i key (gethash key index))))
                    ((and (not row) (eql (gethash key index) i))
                     (throw 'fault (format "row %d (%S) is gone but indexed" i key))))
              (when row (setq rows (1+ rows)))))
          (unless (= (hash-table-count index) rows)
            (throw 'fault (format "%d rows indexed, %d drawn" (hash-table-count index) rows)))
          (unless (= empty (drgnx-view--empty view))
            (throw 'fault (format "%d empty entries, %d counted" empty (drgnx-view--empty view))))
          (unless (= (- (point-max) s) (aref starts n))
            (throw 'fault (format "the region is %d long, the rows %d" (- (point-max) s) (aref starts n))))
          nil)))))

(provide 'drgnx-view)
;;; drgnx-view.el ends here
