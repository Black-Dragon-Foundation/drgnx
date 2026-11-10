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
(require 'ansi-color)                   ; the terminal colours' parents
(require 'drgnx-modules-record)
(require 'drgnx-timer)
(require 'drgnx-wb)
(require 'drgnx-state)                  ; whether a view shows: the workbench state store

(defvar drgnx-signal-errors)            ; drgnx-signal, when loaded
(declare-function drgnx-gc-gap "drgnx-gc" ())

(defcustom drgnx-view-slice 0.004
  "The longest slice, in seconds, a view type may ask for.  Views ripe in one timer pass share one deadline: one that
finds it spent in the same pass draws its first rows only; the next pass starts a fresh slice."
  :type 'number :group 'drgnx)

(defcustom drgnx-view-delay 0.1
  "Seconds between two draws of a view, for a type that names no DELAY (the throttle).  The first mark after a quiet
spell draws sooner (`drgnx-view-first-delay')."
  :type 'number :group 'drgnx)

(defcustom drgnx-view-first-delay 0.016
  "Seconds between the first mark after a quiet spell (no draw for the type's DELAY) and its draw: one frame.
The change shows at once, and a burst arriving apart is drawn whole: a new search's reset and the first file's
rows, which the hub writes one after the other (drawn at the end of the reset's batch, the list would flash empty)."
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
  [:rows-drawn :rows-grown :appended :removed :slices :max-slice-rows :full-draws :stale-skips :draw-ms]
  "The names of the counters in a view's `stats' vector, in order.")

;;;; The frame budget: one deadline for every view in a timer pass

(defvar drgnx-view--deadline nil
  "When the slice now running ends (`drgnx-timer-now' time).  A view whose draw starts before it shares it.")

(defvar drgnx-view--line-height nil
  "While a draw pass runs: the default line height, read at the first row that needs it (it cannot change inside one pass).")
(defvar drgnx-view--slicing nil "Non-nil while a sliced draw runs: `drgnx-view--go-p' checks the deadline.")
(defvar drgnx-view--rows 0 "Rows the draw now running has drawn, grown or removed.")
(defvar drgnx-view--stopped nil "Non-nil once the draw now running stopped at its deadline or on input.")
(defvar drgnx-view--changed nil "Keys the draw now running drew or grew, newest first (for PATCHED).")
(defvar drgnx-view--syncing nil "The view whose SYNC runs now: its marks need no timer, the draw takes them.")

(defun drgnx-view--pass-end ()
  "The key `drgnx-view-pass' fired: a new timer pass began, its first sliced view starts a fresh deadline."
  (setq drgnx-view--deadline nil))

(defun drgnx-view--spend ()
  "The deadline is spent in this timer pass: until the pass ends, a view drawn after this one keeps it (and stops
after its first rows) instead of starting a fresh one.  The pass's end is the key `drgnx-view-pass': Emacs runs the
timers ripe when a pass began and never one armed during it, so it fires in the next pass.  It is due a second ago,
so it sorts before every timer of that pass (a view's continuation armed after it may carry the same time).
Returns t."
  (unless (drgnx-timer-active-p 'drgnx-view-pass)
    (drgnx-timer-start 'drgnx-view-pass -1 #'drgnx-view--pass-end :owner :core))
  t)

(defun drgnx-view--go-p ()
  "Non-nil if the draw now running may work on one more row (and count it).  Every `drgnx-view--check-every' rows a
sliced draw reads the clock and `input-pending-p': past the deadline (spent for the pass: `drgnx-view--spend') or
with input waiting it stops.  A slice always draws its first row."
  (cond (drgnx-view--stopped nil)
        ((and drgnx-view--slicing (> drgnx-view--rows 0) (zerop (% drgnx-view--rows drgnx-view--check-every))
              (or (and (>= (drgnx-timer-now) drgnx-view--deadline) (drgnx-view--spend)) (input-pending-p)))
         (setq drgnx-view--stopped t)
         nil)
        (t (setq drgnx-view--rows (1+ drgnx-view--rows)) t)))

;;;; Types

(cl-defstruct (drgnx-view-type (:constructor drgnx-view--make-type) (:copier nil) (:predicate drgnx-view--type-struct-p))
  "A view type: how its rows are rendered, grown and synced (`drgnx-view-define')."
  name render grow sync slice delay follow-tail key-test patched ack (epoch-reset t))

(defun drgnx-view-type-p (name)
  "Non-nil if the view type NAME is defined now (`drgnx-view-define'; its module may have been turned off)."
  (and (assq name drgnx-view--types) t))

(cl-defun drgnx-view-define (name &key render grow sync slice delay follow-tail key-test patched ack
                                  (epoch-reset t))
  "Define the view type NAME and return NAME.
RENDER (KEY): the row's text, a string ending in a newline, or (BODY . SUFFIX) so that growth goes before SUFFIX.
GROW (KEY BODY-LENGTH): the characters to add at the end of the row's BODY, or nil to render the row again.
SYNC (VIEW): called at draw time after `drgnx-view-touch', to mark what changed (`drgnx-view-sync-rows').
SLICE: nil (draw all at once) or at most `drgnx-view-slice' seconds.  DELAY: the throttle (nil:
`drgnx-view-delay'; 0: draw at the next timer pass).  FOLLOW-TAIL: a window at the end stays at the end.
KEY-TEST: `eq' or `equal' (the default).  PATCHED (VIEW KEYS): called after a draw with the keys whose rows it drew
or grew.  For a hub-fed view (`drgnx-view-patch-attach'): ACK non-nil sends `view/ack' after each applied patch (the
hub then keeps one patch in flight), and EPOCH-RESET nil applies patches of an older env epoch instead of holding
them (a view whose faces repaint in place, a terminal's).  The undo `\"view type NAME\"' removes the definition
while it is still this one; views of a removed type stop drawing."
  (unless (and name (symbolp name)) (signal 'wrong-type-argument (list 'symbolp name)))
  (unless (functionp render) (error "View type %s: RENDER is not a function: %S" name render))
  (unless (or (null slice) (and (numberp slice) (> slice 0) (<= slice drgnx-view-slice)))
    (error "View type %s: SLICE is nil or at most %s, not %S" name drgnx-view-slice slice))
  (unless (memq (or key-test 'equal) '(eq equal))
    (error "View type %s: KEY-TEST is `eq' or `equal', not %S" name key-test))
  (let ((type (drgnx-view--make-type :name name :render render :grow grow :sync sync :slice slice :delay delay
                                     :follow-tail follow-tail :key-test (or key-test 'equal) :patched patched
                                     :ack ack :epoch-reset epoch-reset)))
    (setf (alist-get name drgnx-view--types) type)
    (drgnx-modules-push-undo (format "view type %s" name) (lambda () (drgnx-view--undefine name type)))
    name))

(defun drgnx-view--undefine (name &optional type)
  "Remove the view type NAME, when TYPE is nil or still its definition.  Its views stop drawing."
  (when (or (null type) (eq (alist-get name drgnx-view--types) type))
    (setq drgnx-view--types (assq-delete-all name drgnx-view--types))))

;;;; The record

(cl-defstruct (drgnx-view (:constructor drgnx-view--make) (:copier nil) (:conc-name drgnx-view--))
  "A view attached to a buffer.  Entry I of N is `keys'[I], from START + (`drgnx-view--at' I) to START +
\(`drgnx-view--at' I+1): `starts'[I], plus `shift' when I is `shift-at' or after (what a slice that stopped left
to the next one).  An entry is a row, or, between the slices of a draw, a row still to insert (empty, `work' `new'),
a row still to delete (`work' `gone', not in the index) or a deleted one (empty, not in the index)."
  buffer type
  start                                 ; the only marker: where the rows begin (insertion type nil)
  keys starts work                      ; vectors grown by doubling: N keys, N+1 starts, N work marks
  shift-at (shift 0)                    ; starts from SHIFT-AT on are SHIFT short (nil: none)
  (lo 0)                                ; no entry before LO has a work mark
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

(defsubst drgnx-view--at (view i)
  "Where VIEW's entry I starts, relative to START (I may be N: the end of the last): `starts'[I], plus the shift a
stopped slice left when I is at or after `shift-at'."
  (let ((k (drgnx-view--shift-at view)))
    (if (and k (>= i k))
        (+ (aref (drgnx-view--starts view) i) (drgnx-view--shift view))
      (aref (drgnx-view--starts view) i))))

(defun drgnx-view--settle (view)
  "Add the shift a stopped slice left to the starts it is for: afterwards `starts' holds every entry's own start.
For the code that rewrites the vectors (the fold, the compaction); it costs the entries from `shift-at' on."
  (let ((k (drgnx-view--shift-at view)))
    (when k
      (let ((starts (drgnx-view--starts view)) (d (drgnx-view--shift view)) (n (drgnx-view--n view)))
        (while (<= k n) (aset starts k (+ (aref starts k) d)) (setq k (1+ k))))
      (setf (drgnx-view--shift-at view) nil (drgnx-view--shift view) 0))))

(defun drgnx-view--remove-rows (view)
  "Remove VIEW's rows, the last first, and release its START.  In VIEW's buffer, widened."
  (drgnx-view--settle view)
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

(defun drgnx-view--arm (view &optional now)
  "Arm VIEW's draw: the timer `(drgnx-view . BUFFER)', `drgnx-view-first-delay' (at most DELAY) after the first mark
of a burst, then at most once per DELAY (a DELAY of 0: at the next timer pass).  NOW: at the next timer pass
whatever the DELAY, replacing a draw armed for later (`drgnx-view-hurry').  Nothing while VIEW's SYNC runs (that
draw takes the marks), while a slice chain's continuation `(drgnx-view-more . BUFFER)' is pending (its next slice
takes them), for a view no longer attached, or for a stale view that is still hidden: showing it arms the draw."
  (let ((buffer (drgnx-view--buffer view)))
    (when (and (not (eq view drgnx-view--syncing))
               (buffer-live-p buffer) (eq view (buffer-local-value 'drgnx-view buffer))
               (not (drgnx-timer-active-p (cons 'drgnx-view-more buffer)))
               (or (not (drgnx-view--stale view)) (drgnx-view-shown-p view)))
      (setf (drgnx-view--stale view) nil)
      (when now (drgnx-timer-cancel (cons 'drgnx-view buffer)))
      (let ((delay (if now 0 (or (drgnx-view-type-delay (drgnx-view--type view)) drgnx-view-delay))))
        (if (> delay 0)
            (drgnx-timer-soon (cons 'drgnx-view buffer) (min delay drgnx-view-first-delay) #'drgnx-view--draw-buffer
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

(defun drgnx-view-hurry (view)
  "Draw VIEW's marks at the next timer pass instead of its type's DELAY after the first of them: for a change the
user asked for and waits to see.  The draw is the view's own, sliced as ever.  Nothing while a slice chain's
continuation is pending (its next slice, at the next pass, takes the marks), or for a view no longer attached."
  (drgnx-view--arm view t))

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
  (let ((w (aref (drgnx-view--work view) i)))
    (or (eq w 'gone) (and (= (drgnx-view--at view i) (drgnx-view--at view (1+ i))) (not (eq w 'new))))))

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
      (setf (drgnx-view--pending view) nil (drgnx-view--lo view) 0)
      (drgnx-view--settle view)
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
doubling, copied, only when full.  The new entries take `starts'[N] as it is: they come after `shift-at', so the
shift a slice left is theirs too."
  (setf (drgnx-view--lo view) (min (drgnx-view--lo view) (drgnx-view--n view)))
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
      (let ((work (drgnx-view--work view)) (index (drgnx-view--index view)) (lo (drgnx-view--lo view)))
        (when (gethash drgnx-view--all dirty)
          (drgnx-view--settle view)
          (let ((starts (drgnx-view--starts view)))
            (dotimes (i (drgnx-view--n view))
              (when (and (memq (aref work i) '(nil grow)) (< (aref starts i) (aref starts (1+ i))))
                (aset work i 'patch))))
          (setq lo 0))
        (maphash (lambda (key mark)
                   (let ((i (gethash key index)))
                     (when i
                       (let ((w (aref work i)))
                         (cond ((null w) (aset work i mark) (when (< i lo) (setq lo i)))
                               ((and (eq w 'grow) (eq mark 'patch)) (aset work i 'patch)))))))
                 dirty)
        (setf (drgnx-view--lo view) lo)
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
  "Do the work marks of VIEW's entries in RANGES, sorted disjoint (FROM . TO) entry ranges, or t for every entry from
`lo' on (none before it has work), in buffer order while `drgnx-view--go-p' allows.  A changed row moves the starts
after it: those the sweep passes are written as they are now, and the rest, from where it stops, are left to
`shift' (from `shift-at'), so a slice costs the rows it passes, not every row after them.  With RANGES t, `lo' moves to
the first entry whose work is left.  In VIEW's buffer."
  (let* ((keys (drgnx-view--keys view)) (starts (drgnx-view--starts view)) (work (drgnx-view--work view))
         (n (drgnx-view--n view)) (s (marker-position (drgnx-view--start view)))
         (all (eq ranges t)) (i (if all (min (drgnx-view--lo view) n) (car (car ranges))))
         (k (drgnx-view--shift-at view)) (d (drgnx-view--shift view)) (delta 0) (left nil))
    ;; a shift left before I: the entries up to I take it, so that from I on every start is written as it is now
    (when (and k (< k i))
      (while (< k i) (aset starts k (+ (aref starts k) d)) (setq k (1+ k))))
    (catch 'done
      (while (< i n)
        (let ((off (if (and k (>= i k)) (+ delta d) delta)))   ; what starts[I] lacks
          (unless all
            (while (and ranges (>= i (cdr (car ranges)))) (setq ranges (cdr ranges)))
            (when (and ranges (= off 0) (< i (car (car ranges))))   ; nothing to write up to the next range,
              (setq i (if (and k (< i k)) (min k (car (car ranges))) (car (car ranges)))   ; nor past the left shift
                    off (if (and k (>= i k)) (+ delta d) delta))))
          (when (or drgnx-view--stopped (and (not all) (null ranges))) (throw 'done nil))
          (let ((beg (+ (aref starts i) off)) (mark (aref work i)))
            (aset starts i beg)
            (when mark
              (if (and (or all (>= i (car (car ranges)))) (drgnx-view--go-p))
                  (let* ((end (+ (aref starts (1+ i)) (if (and k (>= (1+ i) k)) (+ delta d) delta)))
                         (len (- end beg))
                         (new (drgnx-view--do-row view (aref keys i) mark (+ s beg) len)))
                    (aset work i nil)
                    (setq delta (+ delta (- new len))))
                (when (and all (not left)) (setq left i))))
            (setq i (1+ i))))))
    (when all (setf (drgnx-view--lo view) (or left i)))
    (drgnx-view--leave-shift view i k d delta)))

(defun drgnx-view--leave-shift (view m k d delta)
  "After a sweep that stopped at entry M with DELTA made: the starts from M on lack DELTA, and those from K (the shift
before it, D, when K is past M) also D.  Leave one shift for the next sweep: when there would be two, the shorter run of
starts is written."
  (let ((starts (drgnx-view--starts view)) (n (drgnx-view--n view)) at by)
    (cond ((or (null k) (<= k m)) (setq at m by (+ delta (if k d 0))))
          ((= delta 0) (setq at k by d))
          ((<= (- k m) (- (1+ n) k))       ; M to K take DELTA now: from K on D + DELTA is left
           (while (< m k) (aset starts m (+ (aref starts m) delta)) (setq m (1+ m)))
           (setq at k by (+ d delta)))
          (t (while (<= k n) (aset starts k (+ (aref starts k) d)) (setq k (1+ k)))   ; from K on D now
             (setq at m by delta)))
    (when (and (= at n) (/= by 0))       ; only the end is left: write it
      (aset starts n (+ (aref starts n) by))
      (setq by 0))
    (if (= by 0)
        (setf (drgnx-view--shift-at view) nil (drgnx-view--shift view) 0)
      (setf (drgnx-view--shift-at view) at (drgnx-view--shift view) by))))

(defun drgnx-view--compact (view)
  "Drop VIEW's empty entries (rows deleted), in place, and point the index at the entries that moved."
  (drgnx-view--settle view)
  (let ((keys (drgnx-view--keys view)) (starts (drgnx-view--starts view)) (work (drgnx-view--work view))
        (index (drgnx-view--index view)) (n (drgnx-view--n view)) (i 0) (o 0) (lo nil))
    (while (< i n)
      (when (< (aref starts i) (aref starts (1+ i)))
        (unless (= i o)
          (let ((key (aref keys i)))
            (aset keys o key) (aset starts o (aref starts i)) (aset work o (aref work i))
            (puthash key o index)))
        (when (and (not lo) (aref work o)) (setq lo o))
        (setq o (1+ o)))
      (setq i (1+ i)))
    (aset starts o (aref starts n))
    (drgnx-view--clear-entries keys work o n)
    (setf (drgnx-view--n view) o (drgnx-view--empty view) 0 (drgnx-view--lo view) (or lo o))))

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
  (< (drgnx-view--at view i) (drgnx-view--at view (1+ i))))

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
  (let* ((rel (- pos (marker-position (drgnx-view--start view)))) (n (drgnx-view--n view)))
    (cond ((< rel 0) (vector nil 0 'abs pos))
          ((< rel (drgnx-view--at view n))
           (let ((i (drgnx-view--entry-at view rel))) (vector i (- rel (drgnx-view--at view i)) nil pos)))
          (follow (vector nil 0 'tail pos))
          (t (let ((i (drgnx-view--live-before view n)))
               (if i (vector i 0 'row-end pos) (vector nil 0 'abs pos)))))))

(defun drgnx-view--row-place-pos (view place)
  "Where PLACE (`drgnx-view--row-place') is now.  An entry that was deleted falls to the next non-empty one, or to
the previous one at the end."
  (let ((tag (aref place 2)) (s (marker-position (drgnx-view--start view))))
    (cond ((eq tag 'abs) (max (point-min) (min (aref place 3) (point-max))))
          ((eq tag 'tail) (point-max))
          (t (let* ((i (aref place 0))
                    (j (if (drgnx-view--live-p view i) i
                         (or (drgnx-view--live-after view (1+ i)) (drgnx-view--live-before view i)))))
               (cond ((null j) s)
                     ((not (eql j i)) (+ s (drgnx-view--at view j)))
                     ((eq tag 'row-end) (+ s (drgnx-view--at view (1+ i))))
                     (t (let ((beg (drgnx-view--at view i)))
                          (+ s beg (min (aref place 1) (- (drgnx-view--at view (1+ i)) beg 1)))))))))))

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
    (unless (= (- (point-max) s) (drgnx-view--at view n))
      (let (old)
        (drgnx-view--walk view nil (lambda (key _ state) (unless (eq state 'ghost) (push key old))))
        (delete-region s (point-max))
        (setf (drgnx-view--n view) 0 (drgnx-view--empty view) 0 (drgnx-view--cut view) nil
              (drgnx-view--shift-at view) nil (drgnx-view--shift view) 0 (drgnx-view--lo view) 0)
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

(defun drgnx-view--work-left-p (view)
  "Non-nil if some entry of VIEW still has a work mark."
  (let ((work (drgnx-view--work view)) (i (drgnx-view--n view)) (found nil))
    (while (and (> i 0) (not found))
      (setq i (1- i) found (aref work i)))
    (and found t)))

(defun drgnx-view--entry-ranges (view keys)
  "The sorted disjoint (FROM . TO) entry ranges of VIEW's rows KEYS (keys with no row are skipped)."
  (let ((index (drgnx-view--index view)) entries ranges)
    (dolist (key keys)
      (when-let* ((i (gethash key index))) (push i entries)))
    (dolist (i (sort entries #'<))
      (if (and ranges (= i (cdr (car ranges))))
          (setcdr (car ranges) (1+ i))
        (unless (and ranges (< i (cdr (car ranges)))) (push (cons i (1+ i)) ranges))))
    (nreverse ranges)))

(defun drgnx-view--draw (view slice &optional keys)
  "Draw VIEW: SYNC when touched, the self-check, the fold, then the row work, the visible rows first when SLICE (a
number of seconds: stop at the shared deadline or on input).  KEYS (a list; with no SLICE): only those rows' work;
the marks of the others stay.  Window start and point stay on their row.  Returns the rows drawn, grown or removed;
the view's `cut' says whether work is left."
  (with-current-buffer (drgnx-view--buffer view)
    (save-restriction
      (widen)
      (let ((inhibit-read-only t) (inhibit-interaction t)
            (t0 (float-time))   ; the :draw-ms stat's own clock: the slice's deadline is the only reader of `drgnx-timer-now'
            (drgnx-view--slicing (and slice t)) (drgnx-view--rows 0) (drgnx-view--stopped nil)
            (drgnx-view--changed nil) (drgnx-view--line-height nil) (type (drgnx-view--type view)))
        (when slice
          (let ((now (drgnx-timer-now)))   ; this pass's deadline while unspent, or spent by a view before this one
            (unless (and drgnx-view--deadline
                         (or (> drgnx-view--deadline now) (drgnx-timer-active-p 'drgnx-view-pass)))
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
          (if keys
              (let ((ranges (drgnx-view--entry-ranges view keys))) (when ranges (drgnx-view--sweep view ranges)))
            (when slice
              (let ((ranges (drgnx-view--visible-ranges view))) (when ranges (drgnx-view--sweep view ranges))))
            (drgnx-view--sweep view t))
          (when (> drgnx-view--rows 0) (drgnx-view--restore-row-places view places)))
        (when (> drgnx-view--rows 0)
          (cl-incf (aref (drgnx-view--stats view) 8) (* 1000.0 (- (float-time) t0))))
        (setf (drgnx-view--cut view) (or drgnx-view--stopped (and keys (drgnx-view--work-left-p view))))
        (when (and (not drgnx-view--stopped) (> (drgnx-view--empty view) 0)) (drgnx-view--compact view))
        (when (> drgnx-view--rows 0) (set-buffer-modified-p nil))
        (let ((patched (drgnx-view-type-patched type)))
          (when (and patched drgnx-view--changed)
            (condition-case err (funcall patched view (nreverse drgnx-view--changed))
              (error (drgnx-view--record view (format "PATCHED: %s" (error-message-string err)))))))
        drgnx-view--rows))))

(defun drgnx-view-draw-now (view &optional keys)
  "Draw VIEW now, whole, even when hidden: run SYNC when touched, then apply every mark.  KEYS (a list of row keys):
only the work on those rows, in the caller's own redisplay; the marks of the other rows stay for the view's own
draw.  Window start and point stay on their row.  Returns the number of rows drawn, grown or removed; 0 for a view
no longer attached or whose type was removed.  A RENDER, GROW, SYNC or PATCHED that signals is recorded
\(`drgnx-view--record'), never raised."
  (let ((buffer (drgnx-view--buffer view)))
    (if (and (buffer-live-p buffer) (eq view (buffer-local-value 'drgnx-view buffer))
             (drgnx-view--current-type view))
        (prog1 (drgnx-view--draw view nil keys) (unless keys (setf (drgnx-view--stale view) nil)))
      0)))

(defun drgnx-view--draw-buffer (buffer)
  "The timer function of BUFFER's view (keys `(drgnx-view . BUFFER)' and `(drgnx-view-more . BUFFER)').
Hidden: mark it stale, count a `:stale-skips', draw and allocate nothing.  Shown: draw one slice (a type with SLICE)
or everything; work left re-arms `(drgnx-view-more . BUFFER)' at `drgnx-timer-chain-delay' (0.0, or later while
input is pending or the chain has run long); when no view has work left, `drgnx-gc-gap' in a timer pass of its own
\(`drgnx-view--pass-over'), so a key typed during the draw is read before the collection."
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
                     (drgnx-timer-start (cons 'drgnx-view-more buffer) (drgnx-timer-chain-delay)
                                        #'drgnx-view--draw-buffer
                                        :args (list buffer) :owner buffer))
                 (drgnx-timer-start 'drgnx-view-gap 0.0 #'drgnx-view--pass-over :owner :core))))))))

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
  "POS as (KEY OFFSET LINE ROW-LINE): KEY = (KEY-AT POS), OFFSET from the start of KEY's row (the first of the lines
above POS whose key is KEY), LINE POS's line number, ROW-LINE POS's line within the row (0 = its first)."
  (save-excursion
    (goto-char pos)
    (let ((key (funcall key-at pos)) (line (line-number-at-pos pos t)) (row-line 0))
      (forward-line 0)
      (when key
        (while (and (not (bobp)) (equal (funcall key-at (line-beginning-position 0)) key))
          (forward-line -1)
          (setq row-line (1+ row-line))))
      (list key (- pos (point)) line row-line))))

(defun drgnx-view--key-place-pos (place pos-of)
  "Where PLACE (`drgnx-view--key-place') is now: (POS-OF KEY) + OFFSET, but no further than the end of the row's
ROW-LINE (a row drawn shorter keeps the place on it); or, when KEY's row is gone, the start of its LINE, clamped to
the last line when the rows now end above it."
  (let ((start (and (car place) (funcall pos-of (car place)))))
    (save-excursion
      (if start
          (progn (goto-char start)
                 (forward-line (or (nth 3 place) 0))
                 (max (point-min) (min (+ start (nth 1 place)) (line-end-position))))
        (goto-char (point-min))
        (forward-line (1- (nth 2 place)))
        (when (and (car place) (eobp) (bolp) (not (bobp))) (forward-line -1)) ; past the rows: the last one
        (point)))))

(defun drgnx-view-save-places (key-at)
  "The current buffer's point and, for each window showing it (all frames), its start and point, each as
\(KEY OFFSET LINE ROW-LINE) with KEY = (KEY-AT POS), OFFSET the distance from KEY's row start, LINE the line
number and ROW-LINE the line within the row.  The value is
\(POINT-PLACE (WINDOW START-PLACE POINT-PLACE)...), for `drgnx-view-restore-places'."
  (cons (drgnx-view--key-place (point) key-at)
        (mapcar (lambda (w) (list w (drgnx-view--key-place (window-start w) key-at)
                                  (drgnx-view--key-place (window-point w) key-at)))
                (get-buffer-window-list (current-buffer) nil t))))

(defun drgnx-view-restore-places (places pos-of)
  "Put the point and windows of PLACES (`drgnx-view-save-places') back: each at (+ (POS-OF KEY) OFFSET), POS-OF
giving a row's start, but no further than the end of the row's ROW-LINE; or at its LINE (clamped to the last
line) when POS-OF returns nil.  Dead windows, and windows that show
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
  (let ((n (drgnx-view--n view)))
    (when (and (>= rel 0) (< rel (drgnx-view--at view n)))
      (let ((lo 0) (hi n))                  ; at(lo) <= rel < at(hi)
        (while (> (- hi lo) 1)
          (let ((mid (ash (+ lo hi) -1)))
            (if (<= (drgnx-view--at view mid) rel) (setq lo mid) (setq hi mid))))
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
    (and i (+ (marker-position (drgnx-view--start view)) (drgnx-view--at view i)))))

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
  "nil when VIEW's starts (`drgnx-view--at') are its entries' actual extents (each non-empty entry ends with a newline
just before the next start, the last at the end of the buffer; an empty entry is a row to insert or a deleted one),
no entry before `lo' has work and the index points at each row and row to insert; otherwise a string naming the first
fault."
  (with-current-buffer (drgnx-view--buffer view)
    (save-restriction
      (widen)
      (let ((s (marker-position (drgnx-view--start view)))
            (keys (drgnx-view--keys view)) (work (drgnx-view--work view)) (index (drgnx-view--index view))
            (n (drgnx-view--n view)) (rows 0) (empty 0))
        (catch 'fault
          (unless (= 0 (drgnx-view--at view 0))
            (throw 'fault (format "row 0 starts at %d, not 0" (drgnx-view--at view 0))))
          (dotimes (i n)
            (let* ((beg (drgnx-view--at view i)) (end (drgnx-view--at view (1+ i))) (key (aref keys i)) (w (aref work i))
                   (row (not (drgnx-view--ghost-p view i))))
              (when (= end beg) (setq empty (1+ empty)))
              (cond ((and w (< i (drgnx-view--lo view)))
                     (throw 'fault (format "row %d (%S) has work %S before lo %d" i key w (drgnx-view--lo view))))
                    ((< end beg) (throw 'fault (format "row %d (%S) runs backwards: %d to %d" i key beg end)))
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
          (unless (= (- (point-max) s) (drgnx-view--at view n))
            (throw 'fault (format "the region is %d long, the rows %d" (- (point-max) s) (drgnx-view--at view n))))
          nil)))))

;;;; Fitting a label to a width

(defun drgnx-view-text-width (s)
  "The width of S in pixels in the current buffer (in a terminal, 8 per column)."
  (if (display-graphic-p) (string-pixel-width s) (* 8 (string-width s))))

(defvar drgnx-view--text-width-function #'drgnx-view-text-width
  "Called with a string for its width in pixels, by `drgnx-view-fit'; tests set a fixed one.")

(defvar drgnx-view--fit-memo (make-hash-table :test #'equal)
  "(TEXT . PIXELS) → TEXT cut to PIXELS, so a label is measured once.  Emptied when it holds 4000 entries (a theme,
font or scale change makes the rows draw again anyway).")

(defun drgnx-view-fit (text px)
  "TEXT cut at the end, with an ellipsis, to be at most PX pixels wide.  Memoised by text and width."
  (let ((key (cons text px)))
    (or (gethash key drgnx-view--fit-memo)
        (progn
          (when (> (hash-table-count drgnx-view--fit-memo) 4000) (clrhash drgnx-view--fit-memo))
          (puthash key
                   (if (<= (funcall drgnx-view--text-width-function text) px)
                       text
                     (let ((lo 0) (hi (length text)))
                       (while (< lo hi)
                         (let ((mid (/ (+ lo hi 1) 2)))
                           (if (<= (funcall drgnx-view--text-width-function (concat (substring text 0 mid) "…")) px)
                               (setq lo mid)
                             (setq hi (1- mid)))))
                       (concat (substring text 0 lo) "…")))
                   drgnx-view--fit-memo)))))

;;;; Hub-fed views: the hub's row patches, inserted

;; A hub-fed view's rows come finished from the hub (docs/develop/hub.md, "Rows"): `drgnx-view-patch-attach' makes the
;; buffer of one (view, display class) a view of type `drgnx-view-rows', and each `view-patch' event goes to
;; `drgnx-view-apply-patch', which keeps the rows by key and only marks the view (reset, insert, dirty, remove): the
;; draw (throttle, slices, row starts) is the view's.  RENDER turns a stored row into text: faces and property names
;; through an allow-list (`intern-soft', never `intern'), stops as one shared `(space :align-to (PX))' per PX, images
;; from an id-keyed cache, heights as `line-height'.  The rules, in order (`drgnx-view-patch--decide', pure):
;; - a patch whose `hub' is not the last reset's, or that comes before the first reset, is dropped (and a reset of
;;   that hub whose version is not newer);
;; - an epoch behind this editor's is held and the view dims (no layout change); a reset at the current epoch drops
;;   every held patch;
;; - a base older than the current version is dropped silently;
;; - a newer base, or a row naming an image the cache lacks (not in a reset), sends `view/resync', at most one
;;   outstanding;
;; - on `drgnx-hub-disconnect-functions' every hub-fed view goes stale (dimmed, keys work) and forgets its version and
;;   hub;
;; - a run naming a style (`s:ID') the buffer lacks (not in a reset) sends `view/resync', like a missing image;
;; - a view type with `:epoch-reset nil' (a terminal's: its faces repaint in place) applies an older epoch's patch;
;; - a view type with `:ack t' sends `view/ack' with the version after each applied patch.
;; Styles (a terminal's cells) arrive as `[id, style]', kept per buffer until the next reset.  An ansi foreground is
;; the face `drgnx-term-color-N' itself, so a remap or theme shows at once; program (rgb) colours and attributes
;; become one anonymous face per distinct style from an LRU (`drgnx-view-patch-style-face-max'); faint text adds
;; `drgnx-term-faint'.  A theme change repaints in place (`drgnx-view-patch-repaint': the LRU emptied, every row drawn
;; again).  A terminal's patch also carries `term' (cursor, alt screen, mouse tracking, title): kept in the state, and
;; the cursor's row is drawn again so the view type's PATCHED places the cursor after the draw.
;; The stale shade is the view's own state, put back as the last step of every draw; the classes (selected, match,
;; lit, dim) come from the view's model in Sjá and go on each node's span, not the line (`drgnx-view-nav.el').

(defvar drgnx-hub--events)
(declare-function drgnx-hub--call-on "drgnx-hub-client")

(defvar drgnx-view-old-path nil
  "Test-only: non-nil makes the views moved onto hub-built rows take their old Lisp path (kept, frozen, until the
render offload's combined pass compares the two).  Never a user option.")

(defface drgnx-view-stale '((t :inherit shadow))
  "A hub-fed view whose rows may be out of date: the hub went away, or its rows are for an older look."
  :group 'drgnx)

(defface drgnx-view-selected '((t :inherit highlight :extend t))
  "The selected node of a hub-fed view, over its span."
  :group 'drgnx)

;; The terminal's 16 colours.  Each inherits its `ansi-color-' face for the foreground and resets the background to
;; the default's, so a face naming one colours text, not cells.
(defface drgnx-term-color-0 '((t :inherit ansi-color-black :background reset))
  "The terminal's colour 0 (a hub-fed row's `{ansi: 0}' foreground)."
  :group 'drgnx)

(defface drgnx-term-color-1 '((t :inherit ansi-color-red :background reset))
  "The terminal's colour 1 (a hub-fed row's `{ansi: 1}' foreground)."
  :group 'drgnx)

(defface drgnx-term-color-2 '((t :inherit ansi-color-green :background reset))
  "The terminal's colour 2 (a hub-fed row's `{ansi: 2}' foreground)."
  :group 'drgnx)

(defface drgnx-term-color-3 '((t :inherit ansi-color-yellow :background reset))
  "The terminal's colour 3 (a hub-fed row's `{ansi: 3}' foreground)."
  :group 'drgnx)

(defface drgnx-term-color-4 '((t :inherit ansi-color-blue :background reset))
  "The terminal's colour 4 (a hub-fed row's `{ansi: 4}' foreground)."
  :group 'drgnx)

(defface drgnx-term-color-5 '((t :inherit ansi-color-magenta :background reset))
  "The terminal's colour 5 (a hub-fed row's `{ansi: 5}' foreground)."
  :group 'drgnx)

(defface drgnx-term-color-6 '((t :inherit ansi-color-cyan :background reset))
  "The terminal's colour 6 (a hub-fed row's `{ansi: 6}' foreground)."
  :group 'drgnx)

(defface drgnx-term-color-7 '((t :inherit ansi-color-white :background reset))
  "The terminal's colour 7 (a hub-fed row's `{ansi: 7}' foreground)."
  :group 'drgnx)

(defface drgnx-term-color-8 '((t :inherit ansi-color-bright-black :background reset))
  "The terminal's colour 8 (a hub-fed row's `{ansi: 8}' foreground)."
  :group 'drgnx)

(defface drgnx-term-color-9 '((t :inherit ansi-color-bright-red :background reset))
  "The terminal's colour 9 (a hub-fed row's `{ansi: 9}' foreground)."
  :group 'drgnx)

(defface drgnx-term-color-10 '((t :inherit ansi-color-bright-green :background reset))
  "The terminal's colour 10 (a hub-fed row's `{ansi: 10}' foreground)."
  :group 'drgnx)

(defface drgnx-term-color-11 '((t :inherit ansi-color-bright-yellow :background reset))
  "The terminal's colour 11 (a hub-fed row's `{ansi: 11}' foreground)."
  :group 'drgnx)

(defface drgnx-term-color-12 '((t :inherit ansi-color-bright-blue :background reset))
  "The terminal's colour 12 (a hub-fed row's `{ansi: 12}' foreground)."
  :group 'drgnx)

(defface drgnx-term-color-13 '((t :inherit ansi-color-bright-magenta :background reset))
  "The terminal's colour 13 (a hub-fed row's `{ansi: 13}' foreground)."
  :group 'drgnx)

(defface drgnx-term-color-14 '((t :inherit ansi-color-bright-cyan :background reset))
  "The terminal's colour 14 (a hub-fed row's `{ansi: 14}' foreground)."
  :group 'drgnx)

(defface drgnx-term-color-15 '((t :inherit ansi-color-bright-white :background reset))
  "The terminal's colour 15 (a hub-fed row's `{ansi: 15}' foreground)."
  :group 'drgnx)

(defface drgnx-term-faint '((t :inherit shadow))
  "Faint (SGR 2) text of the terminal: under the text's own colour, so it shows on text in the default colour."
  :group 'drgnx)

(defface drgnx-term-bold '((t))
  "Bold (SGR 1) text of the terminal, under the text's own colour: give it a foreground for a colour of bold text's
own (Ghostty's `bold-color')."
  :group 'drgnx)

(defconst drgnx-view-patch-ansi-faces
  (vconcat (mapcar (lambda (n) (intern (format "drgnx-term-color-%d" n))) (number-sequence 0 15)))
  "The face of each `{ansi: N}' colour, by N.")

(defconst drgnx-view-patch-faces '(default bold italic shadow error warning success link highlight)
  "Faces a hub row may name besides the `drgnx-' ones.  A name not interned, not a face, or neither of these is
dropped.")

(defconst drgnx-view-patch-props '(help-echo mouse-face)
  "Text properties a hub row may set besides the `drgnx-' ones; any other name is dropped (never interned).")

(defconst drgnx-view-patch-image-max 256
  "The most images a hub-fed view holds; past that the ids no live row names are evicted.")

(defvar drgnx-view-patch-style-face-max 4096
  "The most style faces a hub-fed view keeps (an LRU keyed by the style: its colours and attributes); past it the
least recently used quarter goes.")

(defconst drgnx-view-patch-held-max 64
  "The most patches of an older epoch a hub-fed view holds (the oldest go first); a reset drops them all.")

(defvar drgnx-view-patch-send-function #'drgnx-view-patch--send
  "Called with (METHOD PARAMS) to tell the hub (`view/resync', `view/measured'); tests capture it.")

(defvar drgnx-view-patch-measure-function #'drgnx-view-text-width
  "Called with a string to measure it, in px, in the view's buffer (the fit guard); tests count it.")

(defvar-local drgnx-view-patch-guard-function #'drgnx-view-patch--fit-guard
  "Called by RENDER with (STATE TEXT STOPS) for a row that has stops: the new text, or nil to keep TEXT.  The default
is the fit guard; a terminal's buffer sets its own (each wide cell drawn within its two cells, never an ellipsis).")

(defvar-local drgnx-view-patch-apply-function #'drgnx-view-patch--apply-ops
  "Called with (STATE VIEW PATCH) to put an applied patch's rows in the buffer's view.  A buffer that keeps a view of
its own (`drgnx-view-patch-attach' with KEEP) places the hub's rows among its own rows with a function of its own.")

(defvar drgnx-view-patch--buffers (make-hash-table :test #'equal)
  "(VIEW . CLASS) → the buffer that shows that pair's rows.  Pruned with the buffer.")

(defvar drgnx-view-patch--hooked nil "Non-nil while the hub hooks are on (the first hub-fed buffer added them).")

(cl-defstruct (drgnx-view-patch (:constructor drgnx-view-patch--make) (:copier nil))
  "One hub-fed (view, class): what its editor holds.  HUB and VERSION: the last reset's hub and the version applied
\(nil: none since attaching or the last disconnect).  EPOCH: the env epoch this editor sent last.  HELD: patches of an
older epoch, held.  RESYNC: non-nil while a `view/resync' is outstanding.  STALE: dimmed."
  view class hub version (epoch 0) held resync stale
  ack (epoch-reset t)                           ; the view type's options
  term                                          ; a terminal's last metadata (cursor, alt screen, mouse, title)
  paused                                        ; while paused: (COUNT . PATCHES), the patches kept, newest first
  (styles (make-hash-table))                    ; style id → its style (a plist as the event has it)
  (faces (make-hash-table :test #'equal))       ; style → (TICK . FACE), the LRU of `drgnx-view-patch-style-face-max'
  (face-tick 0)
  (rows (make-hash-table :test #'equal))        ; KEY → its row (a plist as the event has it)
  (images (make-hash-table :test #'equal))      ; image id → the image spec (`:alt' on a terminal: the alt shows)
  (stops (make-hash-table))                     ; PX → the shared (space :align-to (PX))
  stale-overlay
  handle                                        ; this buffer's instance of the view in Sjá (nil without Sjá)
  model                                         ; the highest model version its row patches named, not applied yet
  (ids (make-hash-table :test #'equal))         ; node id → the keys of the rendered rows that hold its span
  (spans (make-hash-table :test #'equal))       ; node id → the overlays of its class (drgnx-view-nav.el)
  class-faces                                   ; the faces by class index, made by the class step; nil: again
  (resyncs 0) (refits 0) (measures 0)           ; counters, for tests and the perf lab
  (classed 0))                                  ; the class step's overlays made and deleted (the perf lab's)

(defvar-local drgnx-view-patch nil "This buffer's hub-fed (view, class), or nil.")

(defvar-local drgnx-view-patch-id-prop 'drgnx-work-id
  "The text property whose value is a node's id over that node's span in this view's rows (the class step's).")

;;;; The rules: a pure decision per patch, and the bookkeeping

(defun drgnx-view-patch--reset-p (patch)
  "Non-nil when PATCH is one reset."
  (let ((ops (plist-get patch :ops))) (and ops (null (cdr ops)) (plist-member (car ops) :reset))))

(defun drgnx-view-patch--image-ids (patch)
  "The image ids PATCH's rows name."
  (let (ids)
    (dolist (op (plist-get patch :ops))
      (dolist (row (or (plist-get op :reset) (plist-get op :replace) (plist-get (plist-get op :insert) :rows)))
        (dolist (im (plist-get row :images)) (push (nth 1 im) ids))))
    ids))

(defun drgnx-view-patch--style-id (name)
  "The style id a run's face NAME names (`s:ID'), or nil."
  (and (> (length name) 2) (eq (aref name 0) ?s) (eq (aref name 1) ?:)
       (let ((id (string-to-number (substring name 2)))) (and (natnump id) id))))

(defun drgnx-view-patch--style-ids (patch)
  "The style ids PATCH's rows' runs name."
  (let (ids)
    (dolist (op (plist-get patch :ops))
      (dolist (row (or (plist-get op :reset) (plist-get op :replace) (plist-get (plist-get op :insert) :rows)))
        (dolist (run (plist-get row :runs))
          (when-let* ((id (drgnx-view-patch--style-id (nth 2 run)))) (push id ids)))))
    ids))

(defun drgnx-view-patch--decide (state patch)
  "What to do with PATCH given STATE (a `drgnx-view-patch'), by the rules: `drop', `hold', `resync' or `apply'."
  (let ((reset (drgnx-view-patch--reset-p patch)) (hub (drgnx-view-patch-hub state))
        (version (drgnx-view-patch-version state)))
    (cond ((and (not reset) (or (null hub) (not (eql hub (plist-get patch :hub))))) 'drop)
          ((and reset version (eql hub (plist-get patch :hub)) (<= (plist-get patch :version) version)) 'drop)
          ((and (drgnx-view-patch-epoch-reset state) (< (plist-get patch :env_epoch) (drgnx-view-patch-epoch state)))
           'hold)
          ((and (not reset) (< (plist-get patch :base) version)) 'drop)
          ((and (not reset) (> (plist-get patch :base) version)) 'resync)
          ;; (a reset carries every image the hub has: one it lacks shows its alt, as a resync could not bring it)
          ((let ((have (drgnx-view-patch-images state)) (new (plist-get patch :images)))
             (and (not reset)
                  (cl-some (lambda (id) (not (or (gethash id have) (assoc id new)))) (drgnx-view-patch--image-ids patch))))
           'resync)
          ((let ((have (drgnx-view-patch-styles state)) (new (plist-get patch :styles)))
             (and (not reset)
                  (cl-some (lambda (id) (not (or (gethash id have) (assq id new)))) (drgnx-view-patch--style-ids patch))))
           'resync)
          (t 'apply))))

(defun drgnx-view-patch--accept (state patch)
  "Decide PATCH (`drgnx-view-patch--decide') and keep STATE's books: a held patch is held, a resync is counted
\(one outstanding at most), an applied reset takes its hub, drops the held patches and answers the resync, and an
applied patch sets the version.  Returns the decision.  No buffer is touched."
  (let ((what (drgnx-view-patch--decide state patch)))
    (pcase what
      ('hold
       (push patch (drgnx-view-patch-held state))
       (when (> (length (drgnx-view-patch-held state)) drgnx-view-patch-held-max)
         (setf (drgnx-view-patch-held state) (take drgnx-view-patch-held-max (drgnx-view-patch-held state)))))
      ('resync
       (unless (drgnx-view-patch-resync state)
         (setf (drgnx-view-patch-resync state) t)
         (cl-incf (drgnx-view-patch-resyncs state))))
      ('apply
       (when (drgnx-view-patch--reset-p patch)
         (setf (drgnx-view-patch-held state) nil (drgnx-view-patch-resync state) nil
               (drgnx-view-patch-hub state) (plist-get patch :hub)))
       (setf (drgnx-view-patch-version state) (plist-get patch :version))))
    what))

(defun drgnx-view-patch--forget (state)
  "The hub went away: STATE forgets its hub, version, held patches and outstanding resync."
  (setf (drgnx-view-patch-hub state) nil (drgnx-view-patch-version state) nil
        (drgnx-view-patch-resync state) nil (drgnx-view-patch-held state) nil))

;;;; Applying

(defun drgnx-view-patch--send (method params)
  "METHOD with PARAMS on this Emacs's subscribed connection, the one the patches come on; nil while it is down."
  (when (and (boundp 'drgnx-hub--events) (process-live-p drgnx-hub--events))
    (drgnx-hub--call-on drgnx-hub--events method params #'ignore)
    t))

(defun drgnx-view-patch--stale (state on)
  "Dim STATE's view (ON) or show it plainly, in the current (the view's) buffer; the layout does not change."
  (setf (drgnx-view-patch-stale state) on)
  (let ((o (drgnx-view-patch-stale-overlay state)))
    (cond ((and on (not o))
           (let ((ov (make-overlay (point-min) (point-max) nil nil t)))
             (overlay-put ov 'face 'drgnx-view-stale)
             (overlay-put ov 'priority 100)
             (setf (drgnx-view-patch-stale-overlay state) ov)))
          ((and (not on) o)
           (delete-overlay o)
           (setf (drgnx-view-patch-stale-overlay state) nil)))))

(defun drgnx-view-patch--keys (rows)
  (mapcar (lambda (r) (plist-get r :key)) rows))

(defun drgnx-view-patch--image (svg)
  "SVG as an image spec on a graphic display, else `:alt' (the row's alt shows)."
  (or (and (display-graphic-p) (image-type-available-p 'svg) (create-image svg 'svg t :ascent 'center)) :alt))

(defun drgnx-view-patch--evict-images (state)
  "Past `drgnx-view-patch-image-max', drop the images no live row names."
  (let ((images (drgnx-view-patch-images state)))
    (when (> (hash-table-count images) drgnx-view-patch-image-max)
      (let ((live (make-hash-table :test #'equal)))
        (maphash (lambda (_ r) (dolist (im (plist-get r :images)) (puthash (nth 1 im) t live)))
                 (drgnx-view-patch-rows state))
        (maphash (lambda (id _) (unless (gethash id live) (remhash id images))) images)))))

(defun drgnx-view-patch--apply-ops (state view patch)
  "Store PATCH's images and rows in STATE and mark VIEW; the draw does the rest."
  (let ((table (drgnx-view-patch-rows state)))
    (when (drgnx-view-patch--reset-p patch)
      (clrhash (drgnx-view-patch-images state))
      (clrhash (drgnx-view-patch-styles state)))
    (dolist (st (plist-get patch :styles))
      (puthash (car st) (cadr st) (drgnx-view-patch-styles state)))
    (dolist (im (plist-get patch :images))
      (puthash (car im) (drgnx-view-patch--image (cadr im)) (drgnx-view-patch-images state)))
    (dolist (op (plist-get patch :ops))
      (cond
       ((plist-member op :reset)
        (let ((rows (plist-get op :reset)))
          (clrhash table)
          (clrhash (drgnx-view-patch-ids state))
          (dolist (r rows) (puthash (plist-get r :key) r table))
          (drgnx-view-reset view (drgnx-view-patch--keys rows))))
       ((plist-member op :insert)
        (let* ((ins (plist-get op :insert)) (rows (plist-get ins :rows)))
          (dolist (r rows) (puthash (plist-get r :key) r table))
          (drgnx-view-insert view (drgnx-view-patch--keys rows) :after (plist-get ins :after))))
       ((plist-member op :replace)
        (let ((rows (plist-get op :replace)))
          (dolist (r rows) (puthash (plist-get r :key) r table))
          (drgnx-view-dirty view (drgnx-view-patch--keys rows))))
       ((plist-member op :remove)
        (let ((keys (plist-get op :remove)))
          (dolist (k keys) (remhash k table))
          (drgnx-view-remove view keys)))))
    (drgnx-view-patch--evict-images state)))

(defconst drgnx-view-patch-paused-max 256
  "The most patches a paused view keeps; past that it keeps none and asks for a reset when it resumes.")

(defun drgnx-view-patch-pause (buffer on)
  "Pause BUFFER's hub-fed view (ON non-nil), or resume it.  While it is paused the patches that come are kept, not
drawn and not acknowledged (a view that acknowledges is sent no more meanwhile); resuming applies them in order, or
asks for a reset when more than `drgnx-view-patch-paused-max' came."
  (with-current-buffer buffer
    (when-let* ((state drgnx-view-patch))
      (if on
          (unless (drgnx-view-patch-paused state) (setf (drgnx-view-patch-paused state) (list 0)))
        (let ((kept (drgnx-view-patch-paused state)))
          (setf (drgnx-view-patch-paused state) nil)
          (if (and kept (> (car kept) drgnx-view-patch-paused-max))
              (funcall drgnx-view-patch-send-function "view/resync"
                       (list :view (drgnx-view-patch-view state) :class (drgnx-view-patch-class state)
                             :version (or (drgnx-view-patch-version state) 0)))
            (dolist (p (reverse (cdr kept))) (drgnx-view-apply-patch p))))))))

(defun drgnx-view-apply-patch (patch)
  "Apply PATCH (a `view-patch' event's data) to its (view, class)'s buffer, by the rules (`drgnx-view-patch--decide').
Returns what was done: `drop', `hold', `resync', `apply', `paused' (kept until the view resumes:
`drgnx-view-patch-pause'), or nil when no buffer shows the pair."
  (let ((buffer (gethash (cons (plist-get patch :view) (plist-get patch :class)) drgnx-view-patch--buffers)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (if-let* ((kept (drgnx-view-patch-paused drgnx-view-patch)))
            (progn (setcar kept (1+ (car kept)))
                   (setcdr kept (and (<= (car kept) drgnx-view-patch-paused-max) (cons patch (cdr kept))))
                   'paused)
          (let* ((state drgnx-view-patch) (sent (drgnx-view-patch-resyncs state))
                 (what (drgnx-view-patch--accept state patch)))
            (pcase what
              ('hold (drgnx-view-patch--stale state t))
              ('resync
               (unless (= sent (drgnx-view-patch-resyncs state))
                 (funcall drgnx-view-patch-send-function "view/resync"
                          (list :view (drgnx-view-patch-view state) :class (drgnx-view-patch-class state)
                                :version (or (drgnx-view-patch-version state) 0)))))
              ('apply
               (when (drgnx-view-patch--reset-p patch) (drgnx-view-patch--stale state nil))
               (funcall drgnx-view-patch-apply-function state drgnx-view patch)
               (when-let* ((n (plist-get patch :model)))
                 (drgnx-view-model--named state n (drgnx-view-patch--reset-p patch))
                 (drgnx-view-touch drgnx-view))
               ;; a terminal's cursor: its row is drawn again, so the view type's PATCHED places it after the draw
               (when-let* ((term (plist-get patch :term)))
                 (setf (drgnx-view-patch-term state) term)
                 (when-let* ((key (car (plist-get term :cursor)))) (drgnx-view-dirty drgnx-view (list key))))
               (when (drgnx-view-patch-ack state)
                 (funcall drgnx-view-patch-send-function "view/ack"
                          (list :view (drgnx-view-patch-view state) :class (drgnx-view-patch-class state)
                                :version (drgnx-view-patch-version state))))))
            what))))))

(defun drgnx-view-patch-event (event data)
  "A `drgnx-hub-event-functions' handler: a `view-patch' goes to its buffer.  (A `view-model' line never comes here:
the hub client hands it whole to `drgnx-view-model-line'.)"
  (when (equal event "view-patch") (drgnx-view-apply-patch data)))

(defun drgnx-view-patch-env-sent (view class epoch)
  "This editor sent (VIEW, CLASS) the env EPOCH (`drgnx-view-env'): patches of an older one are held from now on."
  (let ((buffer (gethash (cons view class) drgnx-view-patch--buffers)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setf (drgnx-view-patch-epoch drgnx-view-patch) epoch)))))

(defun drgnx-view-patch-reclass (buffer class)
  "BUFFER's hub-fed view is shown in the display CLASS now (a `text-scale', a font or a scale change): it is paired
with that class and starts afresh, its rows kept on screen until the class's first reset.  Nothing when it is
already."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((s drgnx-view-patch))
        (when (and s (not (equal class (drgnx-view-patch-class s))))
          (remhash (cons (drgnx-view-patch-view s) (drgnx-view-patch-class s)) drgnx-view-patch--buffers)
          (drgnx-view-patch--forget s)
          (setf (drgnx-view-patch-class s) class (drgnx-view-patch-epoch s) 0)
          (puthash (cons (drgnx-view-patch-view s) class) buffer drgnx-view-patch--buffers))))))

(defun drgnx-view-patch-repaint (buffer)
  "BUFFER's hub-fed rows again from the faces as they are now (a theme changed): the style faces are made afresh and
every row is drawn again, with no message to the hub."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and drgnx-view-patch (drgnx-view-p drgnx-view))
        (clrhash (drgnx-view-patch-faces drgnx-view-patch))
        (drgnx-view-dirty drgnx-view t)))))

(defun drgnx-view-patch--disconnected ()
  "The hub went away: every hub-fed view is stale (dimmed, keys work) and forgets its version and hub."
  (maphash (lambda (_ buffer)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (drgnx-view-patch--forget drgnx-view-patch)
                 (drgnx-view-patch--stale drgnx-view-patch t))))
           drgnx-view-patch--buffers)
  (drgnx-view-model--hub-lost))

;;;; The native view model (Sjá): each view's model, queued in Sjá, applied at the draw
;;
;; A view whose keys move a selection also gets its model (`view-model', docs/develop/hub.md "The native view model").
;; drgnx never parses it: the hub client hands the whole line to Sjá (`drgnx-view-model-line' → `nidhogg-view-push'),
;; which reads the envelope, decides (the rows' rules: a new stream, a queued diff, an old one dropped, a gap) and
;; queues the model per view.  The models go into Sjá's model at the draw that inserts the rows built from them: a
;; draw's first slice (the type's SYNC) drains every queued model up to the highest `model' its buffer's row patches
;; named (`nidhogg-view-drain'), so a key answers from the model that is drawn.  A model no row patch names (a change
;; the rows don't show) applies on the view's own timer one throttle later (`nidhogg-view-due').  Lisp keeps only what
;; talks to the hub: an outstanding `view/resync'.  Without Sjá's queue (an Emacs that is not Nidhogg, or a Nidhogg
;; older than it) the lines are dropped and the first one fails a `render' notice that says why and how to fix it.

(require 'nidhogg-views nil t)          ; Nidhogg's, not preloaded; `nidhogg-view--call' is the C door
(declare-function nidhogg-view-push "nidhogg-views" (line))
(declare-function nidhogg-view-drain "nidhogg-views" (view &optional upto))
(declare-function nidhogg-view-named "nidhogg-views" (view n))
(declare-function nidhogg-view-due "nidhogg-views" (view))
(declare-function nidhogg-view-open "nidhogg-views" (view &optional group))
(declare-function nidhogg-view-close "nidhogg-views" (h))
(declare-function drgnx-notice-clear "drgnx-notice" (source &optional id))
(declare-function drgnx-notify "drgnx-notice" (source severity text &rest keys))
(declare-function nidhogg-view-hub-lost "nidhogg-views" ())

(cl-defstruct (drgnx-view-model (:constructor drgnx-view-model--make) (:copier nil))
  "One hub-fed VIEW's model stream, as the editor's side of it: RESYNC, non-nil while a `view/resync' with `model' is
outstanding (RESYNCS counts them).  LAST: Sjá's status of the last model drained; APPLIED counts those applied.  The
stream itself (its hub, generation, version, queue and the version the rows named) is Sjá's."
  view resync last (applied 0) (resyncs 0))

(defvar drgnx-view-model-functions nil
  "Called with (VIEW VERSION) after a `view-model' of VIEW (a view's name) was queued: a command that asked the hub
for a model and got the answer first takes it here (Find in Terminal).")

(defvar drgnx-view-model--views (make-hash-table :test #'equal)
  "VIEW → its `drgnx-view-model', while a buffer of VIEW lives (pruned with the last: `drgnx-view-patch--killed').")

(defsubst drgnx-view-model--sja-p ()
  "Non-nil when this Emacs has Sjá with its queue (`nidhogg-view-push' and the drains): a Nidhogg older than the queue
has `nidhogg-view--call' without it."
  (fboundp 'nidhogg-view-push))

(defvar drgnx-view-model--said-missing nil
  "Non-nil once a model line found no Sjá queue and said so (`drgnx-view-model--missing'): once a session.")

(defun drgnx-view-model--missing ()
  "A model line came and this Emacs has no Sjá queue: the hub-fed views draw their rows but their keys have no model.
Fails one `render' condition a session (the doctor's `views' row shows it), never an error per line."
  (unless drgnx-view-model--said-missing
    (setq drgnx-view-model--said-missing t)
    (require 'drgnx-notice)
    (drgnx-notify 'render 'fail
                  (if (fboundp 'nidhogg-view--call)
                      "this Nidhogg is older than drgnx: it has no nidhogg-view-push, so the views' keys have no model"
                    "this Emacs has no Sjá (nidhogg-view-push): the views' keys have no model")
                  :id 'view-model-missing :life 'condition
                  :fix "update Nidhogg to the version drgnx pins: drgnx update")))

(declare-function drgnx-view-nav-drained "drgnx-view-nav" (view))
(declare-function drgnx-view-nav-waiting-p "drgnx-view-nav" (view))

(defun drgnx-view-model-line (line)
  "A hub's whole `view-model' LINE, unparsed, to Sjá (`nidhogg-view-push'), which decides by its envelope and queues
its model for the draw.  A gap or a full queue asks the hub for a reset; a queued model arms the view's timer and runs
`drgnx-view-model-functions'; one a key waits for (another window) applies at once.  Returns Sjá's decision
\(`queue', `reset', `drop', `resync', `none'), or nil without Sjá's queue (`drgnx-view-model--missing' says so once)."
  (when-let* (((or (drgnx-view-model--sja-p) (ignore (drgnx-view-model--missing)))) (r (nidhogg-view-push line)))
    (let ((view (nth 0 r)) (what (nth 2 r)))
      (when-let* ((state (gethash view drgnx-view-model--views)))
        (pcase what
          ('resync (drgnx-view-model--resync state))
          ((or 'queue 'reset)
           (when (eq what 'reset) (setf (drgnx-view-model-resync state) nil))
           (drgnx-view-model--arm state)
           (run-hook-with-args 'drgnx-view-model-functions view (nth 1 r))
           ;; a key waits for this model's window: no throttle (`drgnx-view-nav-drained' runs it)
           (when (and (fboundp 'drgnx-view-nav-waiting-p) (drgnx-view-nav-waiting-p view))
             (drgnx-view-model--apply state nil)))))
      what)))

(defun drgnx-view-model-event (data)
  "DATA, a `view-model' event's as a plist whose `:model' is the model's JSON text, as the hub writes the line, to
`drgnx-view-model-line' (tests and the harness: the hub's lines never come here).  Returns its decision."
  (let ((text (lambda (s) (if (multibyte-string-p s) s (decode-coding-string s 'utf-8 t))))) ; json-serialize's bytes
    (drgnx-view-model-line
     (format "{\"event\":\"view-model\",\"data\":{\"view\":%s,\"hub\":%d,\"base\":%d,\"version\":%d,%s\"model\":%s}}"
             (funcall text (json-serialize (plist-get data :view))) (plist-get data :hub) (plist-get data :base)
             (plist-get data :version) (if (plist-get data :reset) "\"reset\":true," "")
             (funcall text (plist-get data :model))))))

(defun drgnx-view-model--resync (state)
  "Ask the hub for a reset of STATE's view, unless one is outstanding."
  (unless (drgnx-view-model-resync state)
    (setf (drgnx-view-model-resync state) t)
    (cl-incf (drgnx-view-model-resyncs state))
    (funcall drgnx-view-patch-send-function "view/resync" (list :view (drgnx-view-model-view state) :model t))))

(defun drgnx-view-model--arm (state)
  "One frame from now after a quiet spell, else one throttle after the last time, STATE's queued models no row patch
named apply (`drgnx-view-model--due'; `drgnx-view-first-delay', `drgnx-view-delay')."
  (let ((view (drgnx-view-model-view state)))
    (drgnx-timer-soon (cons 'drgnx-view-model view) drgnx-view-first-delay #'drgnx-view-model--due
                      :args (list view) :owner :core :min-interval drgnx-view-delay)))

(defun drgnx-view-model--drained (state r)
  "R, Sjá's answer to a drain of STATE's view, (APPLIED LAST VERSION): the faces by class go after a model applied and
a key that waited for another window runs again (`drgnx-view-nav-drained'), and Sjá's `resync' (a model that did not
apply: the queue and the stream are gone) asks the hub for a reset."
  (when r
    (setf (drgnx-view-model-last state) (nth 1 r))
    (when (> (nth 0 r) 0)
      (cl-incf (drgnx-view-model-applied state) (nth 0 r))
      (drgnx-view-model--forget-faces (drgnx-view-model-view state))
      (when (fboundp 'drgnx-view-nav-drained)
        (drgnx-view-nav-drained (drgnx-view-model-view state))))
    (when (eq (nth 1 r) 'resync) (drgnx-view-model--resync state)))
  r)

(defun drgnx-view-model--apply (state upto)
  "STATE's queued models of a version up to UPTO (nil: all) go into Sjá's model, oldest first (`nidhogg-view-drain')."
  (drgnx-view-model--drained state (nidhogg-view-drain (drgnx-view-model-view state) upto)))

(defun drgnx-view-model-apply-queued (view)
  "The queued models of VIEW (a view's name) go to Sjá now: for a view whose row patches name no model (a
terminal's), the command that asked the hub for one uses it at once instead of one throttle later.  Returns the
version of the last model VIEW's stream queued (now applied), or nil."
  (when-let* ((state (gethash view drgnx-view-model--views)))
    (nth 2 (drgnx-view-model--apply state nil))))

(defun drgnx-view-model--forget-faces (view)
  "VIEW's buffers make their faces by class again: a reset may name other classes."
  (maphash (lambda (pair buffer)
             (when (and (equal (car pair) view) (buffer-live-p buffer))
               (with-current-buffer buffer
                 (when drgnx-view-patch (setf (drgnx-view-patch-class-faces drgnx-view-patch) nil)))))
           drgnx-view-patch--buffers))

(defun drgnx-view-model--due (view)
  "The timer of VIEW's queue: models no row patch named apply now.  One a patch named waits for that patch's draw,
which arms this again for what is left."
  (when-let* ((state (gethash view drgnx-view-model--views))
              ((drgnx-view-model--drained state (nidhogg-view-due view))))
    (drgnx-view-model--reclass view)))

(defun drgnx-view-model--reclass (view)
  "VIEW's buffers take the classes a model no row patch named changed (a list another view's selection lit): no
draw follows it to run the class step."
  (when (fboundp 'drgnx-view-nav-class-step)
    (maphash (lambda (pair buffer)
               (when (and (equal (car pair) view) (buffer-live-p buffer))
                 (with-current-buffer buffer (drgnx-view-nav-class-step drgnx-view))))
             drgnx-view-patch--buffers)))

(defun drgnx-view-model--named (patch-state n reset)
  "A row patch applied in PATCH-STATE's buffer named model N (RESET: a reset of the rows): its draw applies up to N."
  (setf (drgnx-view-patch-model patch-state) (if reset n (max n (or (drgnx-view-patch-model patch-state) 0))))
  (when (gethash (drgnx-view-patch-view patch-state) drgnx-view-model--views)
    (nidhogg-view-named (drgnx-view-patch-view patch-state) n)))

(defun drgnx-view-patch--sync (_view)
  "SYNC of `drgnx-view-rows', at a draw's first slice in the view's buffer: the view's queued models up to the
highest one this buffer's row patches named go to Sjá, before the rows built from them are inserted."
  (let ((state drgnx-view-patch))
    (when-let* ((n (drgnx-view-patch-model state))
                (m (gethash (drgnx-view-patch-view state) drgnx-view-model--views)))
      (setf (drgnx-view-patch-model state) nil)
      (drgnx-view-model--apply m n)
      (drgnx-view-model--arm m))))

(defun drgnx-view-model--hub-lost ()
  "The hub went: Sjá drops every view's queue and stream and marks every view stale; keys keep working on what is
drawn."
  (maphash (lambda (_ m) (setf (drgnx-view-model-resync m) nil)) drgnx-view-model--views)
  (when (drgnx-view-model--sja-p) (nidhogg-view-hub-lost)))

(defun drgnx-view-model--open (state)
  "Open PATCH-STATE's instance in Sjá, and its view's stream state when it is the view's first buffer."
  (when (drgnx-view-model--sja-p)
    (let ((view (drgnx-view-patch-view state)))
      (unless (gethash view drgnx-view-model--views)
        (puthash view (drgnx-view-model--make :view view) drgnx-view-model--views))
      (setf (drgnx-view-patch-handle state) (nidhogg-view-open view)))))

(defun drgnx-view-model--close (state &optional all)
  "Close PATCH-STATE's instance; its view's queue goes with the view's last buffer (ALL: now)."
  (when-let* ((h (drgnx-view-patch-handle state)))
    (setf (drgnx-view-patch-handle state) nil)
    (nidhogg-view-close h))
  (let ((view (drgnx-view-patch-view state)) (other nil))
    (unless all
      (maphash (lambda (key b)
                 (when (and (equal (car key) view) (buffer-live-p b) (not (eq b (current-buffer)))) (setq other t)))
               drgnx-view-patch--buffers))
    (unless other
      (remhash view drgnx-view-model--views)
      (drgnx-timer-cancel (cons 'drgnx-view-model view))
      ;; the view is closed in Sjá with its last instance: a broken one starts whole when opened again
      (when (fboundp 'drgnx-notice-clear) (drgnx-notice-clear 'render (cons 'view-broken view))))))

;;;; Rendering a stored row

(defun drgnx-view-patch--face (name)
  "The face NAME names, when it is one a row may use; never interns NAME."
  (let ((f (intern-soft name)))
    (and f (facep f) (or (memq f drgnx-view-patch-faces) (string-prefix-p "drgnx-" name)) f)))

(defun drgnx-view-patch--prop (name)
  "The text property NAME names, when a row may set it; never interns NAME."
  (let ((p (intern-soft name)))
    (and p (or (memq p drgnx-view-patch-props) (string-prefix-p "drgnx-" name)) p)))

(defun drgnx-view-patch--on (v)
  "Non-nil when the JSON boolean V is true (false parses as `:false')."
  (eq v t))

(defun drgnx-view-patch--colour (c)
  "The colour C (`(:ansi N)' or `(:rgb HEX)', the hub's program data) as a colour string, or nil for the default."
  (cond ((null c) nil)
        ((plist-get c :rgb))
        ((natnump (plist-get c :ansi))
         (let ((n (plist-get c :ansi)))
           (and (< n 16) (face-foreground (aref drgnx-view-patch-ansi-faces n) nil t))))))

(defun drgnx-view-patch--style-attrs (style)
  "STYLE's face attributes besides an ansi foreground (which is a face of its own): a plist, nil for none."
  (let* ((fg (plist-get style :fg)) (bg (drgnx-view-patch--colour (plist-get style :bg)))
         (ul (drgnx-view-patch--colour (plist-get style :ul_color)))
         (attrs nil))
    (when (drgnx-view-patch--on (plist-get style :inverse)) (setq attrs (list :inverse-video t)))
    (when (drgnx-view-patch--on (plist-get style :strike)) (setq attrs (append (list :strike-through t) attrs)))
    (when (drgnx-view-patch--on (plist-get style :underline))
      (setq attrs (append (list :underline (if ul (list :color ul) t)) attrs)))
    (when (drgnx-view-patch--on (plist-get style :italic)) (setq attrs (append (list :slant 'italic) attrs)))
    (cond ((drgnx-view-patch--on (plist-get style :bold)) (setq attrs (append (list :weight 'bold) attrs)))
          ((drgnx-view-patch--on (plist-get style :faint)) (setq attrs (append (list :weight 'light) attrs))))
    (when bg (setq attrs (append (list :background bg) attrs)))
    (when (plist-get fg :rgb) (setq attrs (append (list :foreground (plist-get fg :rgb)) attrs)))
    attrs))

(defun drgnx-view-patch--style-face (state id)
  "The face of STATE's style ID (nil: the default, or a style STATE lacks): `drgnx-term-color-N' for an ansi
foreground, before it the style's other attributes as one anonymous face, shared through the LRU."
  (when-let* ((style (gethash id (drgnx-view-patch-styles state))))
    (let* ((faces (drgnx-view-patch-faces state)) (tick (cl-incf (drgnx-view-patch-face-tick state)))
           (hit (gethash style faces)))
      (if hit
          (progn (setcar hit tick) (cdr hit))
        (let* ((n (plist-get (plist-get style :fg) :ansi))
               (ansi (and (natnump n) (< n 16) (aref drgnx-view-patch-ansi-faces n)))
               (attrs (drgnx-view-patch--style-attrs style))
               (face (delq nil (list attrs ansi (and (drgnx-view-patch--on (plist-get style :faint)) 'drgnx-term-faint)
                                     (and (drgnx-view-patch--on (plist-get style :bold)) 'drgnx-term-bold))))
               (face (if (cdr face) face (car face))))
          (when (>= (hash-table-count faces) drgnx-view-patch-style-face-max)
            (drgnx-view-patch--evict-faces faces))
          (puthash style (cons tick face) faces)
          face)))))

(defun drgnx-view-patch--evict-faces (faces)
  "Drop the least recently used quarter (at least one) of FACES, the style LRU."
  (let (ticks)
    (maphash (lambda (_ v) (push (car v) ticks)) faces)
    (let* ((sorted (sort ticks #'<))
           (cut (nth (max 0 (1- (max 1 (/ (length sorted) 4)))) sorted)))
      (maphash (lambda (k v) (when (<= (car v) cut) (remhash k faces))) faces))))

(defun drgnx-view-patch--stop (state px)
  "The one `(space :align-to (PX))' of STATE for PX (at most 512 kept)."
  (let ((table (drgnx-view-patch-stops state)))
    (or (gethash px table)
        (progn (when (>= (hash-table-count table) 512) (clrhash table))
               (puthash px `(space :align-to (,px)) table)))))

(defun drgnx-view-patch--fit-guard (state text stops)
  "The fit guard: one measure of TEXT's segment before its first stop of STOPS (none: nothing measured).  When it
runs past that stop's PX, the segment is fitted again (`drgnx-view-fit'), padded so later positions keep their
place, and the measure reported (`view/measured').  Returns the new text, or nil when TEXT fits."
  (when-let* ((stop (car stops)))
    (let* ((end (car stop)) (limit (cadr stop)) (seg (substring text 0 end))
           (w (funcall drgnx-view-patch-measure-function seg)))
      (cl-incf (drgnx-view-patch-measures state))
      (when (> w limit)
        (cl-incf (drgnx-view-patch-refits state))
        (funcall drgnx-view-patch-send-function "view/measured"
                 (list :view (drgnx-view-patch-view state) :class (drgnx-view-patch-class state)
                       :measured (list (list "ui" seg w))))
        (let ((fit (drgnx-view-fit seg limit)))
          (concat fit (make-string (max 0 (- end (length fit))) ?\s) (substring text end)))))))

(defun drgnx-view-patch-render (key)
  "RENDER of `drgnx-view-rows': KEY's stored row as text, in the current (the view's) buffer."
  (let* ((state drgnx-view-patch) (row (gethash key (drgnx-view-patch-rows state)))
         (text (plist-get row :text)) (stops (plist-get row :stops)))
    (setq text (or (and stops (funcall drgnx-view-patch-guard-function state text stops)) (copy-sequence text)))
    (dolist (run (plist-get row :runs))
      (when-let* ((name (nth 2 run))
                  (face (let ((id (drgnx-view-patch--style-id name)))
                          (if id (drgnx-view-patch--style-face state id) (drgnx-view-patch--face name)))))
        (put-text-property (nth 0 run) (nth 1 run) 'face face text)))
    (dolist (p (plist-get row :props))
      (when-let* ((name (drgnx-view-patch--prop (nth 2 p))))
        (put-text-property (nth 0 p) (nth 1 p) name (nth 3 p) text)
        (when (eq name drgnx-view-patch-id-prop)        ; the rows that hold a node, for the class step
          (let ((ids (drgnx-view-patch-ids state)))
            (unless (member key (gethash (nth 3 p) ids)) (push key (gethash (nth 3 p) ids)))))))
    (dolist (stop stops)
      (put-text-property (car stop) (1+ (car stop)) 'display (drgnx-view-patch--stop state (cadr stop)) text))
    (dolist (sp (plist-get row :spaces))              ; a space of a size in device px (a card's progress bar)
      (put-text-property (car sp) (1+ (car sp)) 'display `(space :width (,(nth 1 sp)) :height (,(nth 2 sp))) text))
    (dolist (im (plist-get row :images))
      (let ((spec (gethash (nth 1 im) (drgnx-view-patch-images state))))
        (put-text-property (nth 0 im) (1+ (nth 0 im)) 'display (if (or (null spec) (eq spec :alt)) (nth 2 im) spec)
                           text)))
    (let ((h (plist-get row :height)) (nl (copy-sequence "\n")))
      (when h
        (put-text-property 0 1 'line-height
                           (* (plist-get h :lines) (or drgnx-view--line-height (setq drgnx-view--line-height (default-line-height))))
                           nl))
      (concat text nl))))

;;;; Classes and the stale shade: the last step

(declare-function drgnx-view-nav-class-step "drgnx-view-nav" (view &optional keys))

(defvar drgnx-view-patch-patched-functions nil
  "Called with (VIEW KEYS) in a hub-fed view's buffer after the rows KEYS were drawn and got their classes: a view's
own marks over the hub's rows go back on here (the Search view's tick boxes, user state in Sjá).  Added buffer-locally
by the view that owns the buffer.")

(defun drgnx-view-patch--patched (view keys)
  "PATCHED of `drgnx-view-rows': the stale shade, then the model's classes on the patched rows KEYS, then
`drgnx-view-patch-patched-functions'.  The classes (selected, match, lit, dim) come from Sjá by node id
(`drgnx-view-nav-class-step'), never from a row patch."
  (with-current-buffer (drgnx-view--buffer view)
    (let ((state drgnx-view-patch))
      (when (drgnx-view-patch-stale-overlay state)
        (move-overlay (drgnx-view-patch-stale-overlay state) (point-min) (point-max)))
      (when (fboundp 'drgnx-view-nav-class-step)
        (drgnx-view-nav-class-step view keys))
      (run-hook-with-args 'drgnx-view-patch-patched-functions view keys))))

(drgnx-view-define 'drgnx-view-rows :render #'drgnx-view-patch-render :patched #'drgnx-view-patch--patched
                   :sync #'drgnx-view-patch--sync :slice drgnx-view-slice)

;;;; Attaching

(defun drgnx-view-patch--hooks ()
  "The hub hooks on while a hub-fed buffer lives, off with the last."
  (let ((live nil))
    (maphash (lambda (_ b) (when (buffer-live-p b) (setq live t))) drgnx-view-patch--buffers)
    (unless (eq live drgnx-view-patch--hooked)
      (let ((f (if live #'add-hook #'remove-hook)))
        (funcall f 'drgnx-hub-event-functions #'drgnx-view-patch-event)
        (funcall f 'drgnx-hub-disconnect-functions #'drgnx-view-patch--disconnected))
      (setq drgnx-view-patch--hooked live))))

(defun drgnx-view-patch--killed ()
  "`kill-buffer-hook' of a hub-fed buffer: its pair is forgotten, and the hub hooks go with the last."
  (when drgnx-view-patch
    (remhash (cons (drgnx-view-patch-view drgnx-view-patch) (drgnx-view-patch-class drgnx-view-patch))
             drgnx-view-patch--buffers)
    (drgnx-view-model--close drgnx-view-patch)
    (setq drgnx-view-patch nil))
  (drgnx-view-patch--hooks))

(cl-defun drgnx-view-patch-attach (view class &key buffer start epoch type keep)
  "Make BUFFER (default: the current one) show the hub-built rows of (VIEW, CLASS), from START: a view of TYPE
\(default `drgnx-view-rows'; another type renders with `drgnx-view-patch-render' too, and sets ACK and EPOCH-RESET,
`drgnx-view-define').  EPOCH: the env epoch sent for the pair.  KEEP: the buffer keeps the view it has, whose type
renders the hub's rows with `drgnx-view-patch-render' among its own and sets `drgnx-view-patch-apply-function'.
Returns the view."
  (with-current-buffer (or buffer (current-buffer))
    (let* ((v (if keep drgnx-view (drgnx-view-attach (or type 'drgnx-view-rows) :start start))) (ty (drgnx-view--type v)))
      (when drgnx-view-patch (drgnx-view-model--close drgnx-view-patch))   ; attached again: the old instance goes
      (setq-local drgnx-view-patch (drgnx-view-patch--make :view view :class class :epoch (or epoch 0)
                                                           :ack (drgnx-view-type-ack ty)
                                                           :epoch-reset (drgnx-view-type-epoch-reset ty)))
      (drgnx-view-model--open drgnx-view-patch)
      (puthash (cons view class) (current-buffer) drgnx-view-patch--buffers)
      (add-hook 'kill-buffer-hook #'drgnx-view-patch--killed nil t)
      (drgnx-view-patch--hooks)
      v)))

(defun drgnx-view-patch-detach ()
  "Make the current buffer no longer hub-fed: its (view, class) pair is forgotten and its instance in Sjá closed.  The
buffer's view and its rows stay; attach another view type to replace them."
  (remove-hook 'kill-buffer-hook #'drgnx-view-patch--killed t)
  (drgnx-view-patch--killed))

(defun drgnx-view-patch-teardown ()
  "Forget every hub-fed buffer's pairing and remove the hub hooks (the owning module's teardown)."
  (maphash (lambda (_ b)
             (when (buffer-live-p b)
               (with-current-buffer b
                 (remove-hook 'kill-buffer-hook #'drgnx-view-patch--killed t)
                 (when drgnx-view-patch (drgnx-view-model--close drgnx-view-patch t)))))
           drgnx-view-patch--buffers)
  (clrhash drgnx-view-patch--buffers)
  (drgnx-view-patch--hooks))

(provide 'drgnx-view)
;;; drgnx-view.el ends here
