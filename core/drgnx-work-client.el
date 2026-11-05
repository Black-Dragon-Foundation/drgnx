;;; drgnx-work-client.el --- The Work map's client: a cached frame kept current from the hub's versioned deltas -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The hub keeps one map per (connection, view) and sends its frame and then `work-map' deltas
;; (docs/develop/hub.md, "The Work map").  This library holds the Emacs side in two layers.
;;
;; The core is pure.  `drgnx-work-client-init' makes a state from a frame; `drgnx-work-client-step' takes a state and
;; one `work-map' event and returns (NEW-STATE . MARKS).  An event older than the frame is dropped; one whose base is
;; the frame's version is applied (and any held event it unblocks); one whose base is ahead of the frame is held and
;; marks a resync; a full event replaces the frame.  MARKS is a plist: `:rows' (row keys to draw again, or t for all),
;; `:items' (the changed ids), `:removed', `:edges', `:layout', `:keys' (the list of rows changed), `:strip' and
;; `:resync', each only when it applies.
;; Row keys are `(:row LAYER BLOCK-LINE SUB)': one view row per sub-row of the layout.
;;
;; The shell keeps the views (an id string each), calls the hub (`work/map/subscribe', `set', `close'), feeds the
;; core from `drgnx-hub-event-functions', re-subscribes from `drgnx-hub-connected-functions' and runs
;; `drgnx-work-client-change-functions' with (VIEW-ID MARKS).  A view with no answer keeps its frame and says
;; "reconnecting".  Nothing here draws.  See docs/develop/work-space.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(declare-function drgnx-hub-call "drgnx-hub-client")

;;;; The state

(cl-defstruct (drgnx-work-client-state (:constructor drgnx-work-client--make) (:copier drgnx-work-client--copy)
                                       (:conc-name drgnx-work-client-))
  "A map view's cached frame.  ITEMS: id → item plist.  EDGES: plists (:from :to :kind).  LAYOUT: a plist (:rows
:at :form :lanes :ports :bands :fits :crossings :width_units :height_units), :at and :form hash tables id → rect
plist / form string.  HELD: events whose base is ahead of VERSION.  LIVE: nil before a frame and after the hub was lost."
  version live items edges layout needs-you chips held)

(defun drgnx-work-client--key (k)
  "The id a decoded JSON object key stands for (`:agent:a1' is \"agent:a1\")."
  (substring (symbol-name k) 1))

(defun drgnx-work-client--table (plist)
  "A hash table id → value from the decoded JSON object PLIST (keys are keywords made of the ids)."
  (let ((h (make-hash-table :test #'equal)))
    (cl-loop for (k v) on plist by #'cddr do (puthash (drgnx-work-client--key k) v h))
    h))

(defun drgnx-work-client--layout (layout)
  "LAYOUT, decoded from the wire, with :at and :form as hash tables (a layout already so is returned as it is)."
  (let ((at (plist-get layout :at)) (form (plist-get layout :form)))
    (append (list :at (if (hash-table-p at) at (drgnx-work-client--table at))
                  :form (if (hash-table-p form) form (drgnx-work-client--table form)))
            (cl-loop for (k v) on layout by #'cddr unless (memq k '(:at :form)) append (list k v)))))

(defun drgnx-work-client--items (list)
  (let ((h (make-hash-table :test #'equal)))
    (dolist (it list) (puthash (plist-get it :id) it h))
    h))

(defun drgnx-work-client-init (frame)
  "A live state from FRAME, `work/map/subscribe''s answer (a plist: :version :items :edges :layout :needs_you :chips)."
  (drgnx-work-client--make
   :version (plist-get frame :version) :live t :items (drgnx-work-client--items (plist-get frame :items))
   :edges (plist-get frame :edges) :layout (drgnx-work-client--layout (plist-get frame :layout))
   :needs-you (plist-get frame :needs_you) :chips (plist-get frame :chips)))

(defun drgnx-work-client-live-p (state) (and (drgnx-work-client-live state) t))

(defun drgnx-work-client-lost (state)
  "STATE after the hub went away: not live, nothing held; the frame stays to be shown."
  (let ((s (drgnx-work-client--copy state)))
    (setf (drgnx-work-client-live s) nil (drgnx-work-client-held s) nil)
    s))

(defun drgnx-work-client-item (state id) (gethash id (drgnx-work-client-items state)))
(defun drgnx-work-client-ids (state) (hash-table-keys (drgnx-work-client-items state)))
(defun drgnx-work-client-rect (state id) (gethash id (plist-get (drgnx-work-client-layout state) :at)))
(defun drgnx-work-client-form (state id) (gethash id (plist-get (drgnx-work-client-layout state) :form)))

;;;; Rows

(defun drgnx-work-client-kind-layer (kind)
  "The layer (1 to 6) of an item KIND string."
  (pcase kind
    ("ask" 1) ("spec" 2) ("plan" 3) ((or "agent" "subagent") 4) ("branch" 5) ((or "file" "machine") 6)))

(defun drgnx-work-client-rows-of (state id)
  "The row keys (:row LAYER BLOCK-LINE SUB) the item ID of STATE sits in: the rows of its layer its rectangle starts
in, else its layer's collapsed row."
  (let* ((it (drgnx-work-client-item state id))
         (layer (drgnx-work-client-kind-layer (or (plist-get it :kind) (car (split-string id ":")))))
         (rect (drgnx-work-client-rect state id)) out)
    (dolist (r (plist-get (drgnx-work-client-layout state) :rows))
      (when (and (eq layer (plist-get r :layer))
                 (if rect
                     (and (>= (plist-get rect :y) (plist-get r :y))
                          (< (plist-get rect :y) (+ (plist-get r :y) (plist-get r :height_units))))
                   (plist-get r :collapsed)))
        (push (list :row layer (plist-get r :block_line) (plist-get r :sub)) out)))
    (nreverse out)))

;;;; Applying events

(defun drgnx-work-client--ensure-row (state id)
  "A live arrival can take a row of its own at the bottom, which no delta lists: when ID's rectangle is in no row of
STATE's layout, add a row for it (block line 1000 and up, so its key is its own).  STATE's layout is changed."
  (unless (drgnx-work-client-rows-of state id)
    (let* ((rect (drgnx-work-client-rect state id)) (lay (drgnx-work-client-layout state))
           (layer (drgnx-work-client-kind-layer (car (split-string id ":"))))
           (rows (plist-get lay :rows))
           (k (1+ (apply #'max 999 (mapcar (lambda (r) (plist-get r :block_line)) rows)))))
      (when (and rect layer)
        (setf (drgnx-work-client-layout state)
              (plist-put (copy-sequence lay) :rows
                         (append rows (list (list :layer layer :block_line k :sub 0 :y (plist-get rect :y)
                                                  :height_units (plist-get rect :h))))))))))

(defun drgnx-work-client--merge-marks (a b)
  "Marks A and B as one: the rows joined (t wins), the ids joined, the flags or-ed."
  (let ((out nil))
    (dolist (k '(:rows :items :removed))
      (let ((x (plist-get a k)) (y (plist-get b k)))
        (setq out (plist-put out k (if (or (eq x t) (eq y t)) t (delete-dups (append x y)))))))
    (dolist (k '(:edges :layout :strip :resync :keys))
      (setq out (plist-put out k (or (plist-get a k) (plist-get b k)))))
    (cl-loop for (k v) on out by #'cddr when v append (list k v))))

(defun drgnx-work-client--sort-rows (rows)
  (if (eq rows t) t (sort (delete-dups rows) (lambda (a b) (string< (format "%S" a) (format "%S" b))))))

(defun drgnx-work-client--apply (state ev)
  "STATE with the delta EV (not full) applied, and its marks: (NEW . MARKS)."
  (let* ((s (drgnx-work-client--copy state))
         (items (copy-hash-table (drgnx-work-client-items state)))
         (lay (drgnx-work-client-layout state))
         (at (copy-hash-table (plist-get lay :at))) (form (copy-hash-table (plist-get lay :form)))
         (rows nil) ids gone)
    (setf (drgnx-work-client-items s) items
          (drgnx-work-client-layout s) (plist-put (plist-put (copy-sequence lay) :at at) :form form))
    (dolist (id (plist-get ev :removed))
      (setq rows (append (drgnx-work-client-rows-of state id) rows))
      (push id gone)
      (remhash id items) (remhash id at) (remhash id form))
    (dolist (kv (cl-loop for (k v) on (plist-get ev :places) by #'cddr collect (cons (drgnx-work-client--key k) v)))
      (puthash (car kv) (plist-get (cdr kv) :rect) at)
      (when (plist-get (cdr kv) :form) (puthash (car kv) (plist-get (cdr kv) :form) form))
      (drgnx-work-client--ensure-row s (car kv)))
    (dolist (it (plist-get ev :changed))
      (let ((id (plist-get it :id)))
        (setq rows (append (drgnx-work-client-rows-of state id) rows))
        (puthash id it items)
        (push id ids)))
    (dolist (id (nreverse (copy-sequence ids))) (setq rows (append (drgnx-work-client-rows-of s id) rows)))
    (when (plist-member ev :edges) (setf (drgnx-work-client-edges s) (plist-get ev :edges)))
    (when (plist-get ev :layout)
      (setf (drgnx-work-client-layout s) (drgnx-work-client--layout (plist-get ev :layout)) rows t))
    (when (plist-member ev :needs_you) (setf (drgnx-work-client-needs-you s) (plist-get ev :needs_you)))
    (when (plist-member ev :chips) (setf (drgnx-work-client-chips s) (plist-get ev :chips)))
    (setf (drgnx-work-client-version s) (plist-get ev :version))
    (cons s (cl-loop for (k v) on (list :rows (drgnx-work-client--sort-rows rows) :items (nreverse ids)
                                        :removed (nreverse gone)
                                        :keys (/= (length (plist-get lay :rows))
                                                  (length (plist-get (drgnx-work-client-layout s) :rows)))
                                        :edges (and (plist-get ev :edges) t) :layout (and (plist-get ev :layout) t)
                                        :strip (and (or (plist-member ev :needs_you) (plist-member ev :chips)) t))
                     by #'cddr when v append (list k v)))))

(defun drgnx-work-client--full (ev)
  "The state of the full event EV (its `:changed' are all the items), and its marks: every row, the strip, the edges."
  (cons (drgnx-work-client-init (list :version (plist-get ev :version) :items (plist-get ev :changed)
                                      :edges (plist-get ev :edges) :layout (plist-get ev :layout)
                                      :needs_you (plist-get ev :needs_you) :chips (plist-get ev :chips)))
        (list :rows t :layout t :edges t :strip t)))

(defun drgnx-work-client--drain (state marks)
  "STATE with the held events it unblocks applied, and the marks joined: (NEW . MARKS)."
  (let ((held (sort (copy-sequence (drgnx-work-client-held state))
                    (lambda (a b) (< (plist-get a :base) (plist-get b :base)))))
        (progress t))
    (while (and held progress)
      (setq progress nil)
      (let* ((v (drgnx-work-client-version state))
             (next (seq-find (lambda (e) (eql (plist-get e :base) v)) held)))
        (setq held (seq-remove (lambda (e) (<= (plist-get e :version) v)) held))
        (when next
          (let ((r (drgnx-work-client--apply state next)))
            (setq state (car r) marks (drgnx-work-client--merge-marks marks (cdr r)) progress t
                  held (remq next held))))))
    (let ((s (drgnx-work-client--copy state)))
      (setf (drgnx-work-client-held s) held)
      (cons s marks))))

(defun drgnx-work-client-step (state ev)
  "STATE after the `work-map' event EV (a plist: :version :base :full :changed :removed :entered :places :edges
:layout :needs_you :chips), and the marks: (NEW-STATE . MARKS).  Dropped when STATE is not live or EV is not newer
than its frame; a full event replaces the frame; an event whose base is the frame's version is applied, with the held
events it unblocks; any other is held and marks a resync."
  (let ((cur (drgnx-work-client-version state)) (v (plist-get ev :version)))
    (cond
     ((not (drgnx-work-client-live state)) (cons state nil))
     ((and cur v (<= v cur)) (cons state nil))
     ((plist-get ev :full) (drgnx-work-client--full ev))
     ((eql (plist-get ev :base) cur)
      (let ((r (drgnx-work-client--apply state ev)))
        (drgnx-work-client--drain (car r) (cdr r))))
     (t (let ((s (drgnx-work-client--copy state)))
          (unless (seq-find (lambda (e) (eql (plist-get e :version) v)) (drgnx-work-client-held s))
            (setf (drgnx-work-client-held s) (cons ev (drgnx-work-client-held s))))
          (cons s (list :resync t)))))))

;;;; The shell: views, calls to the hub, events

(cl-defstruct (drgnx-work-client--view (:constructor drgnx-work-client--make-view) (:copier nil))
  "One map view of this Emacs.  PARAMS: the plist `work/map/subscribe' takes (without :view).  STATUS: `subscribing',
`live', `reconnecting' or `hidden'.  COUNTERS: (:events N :deltas N :frames N)."
  id params state (status 'subscribing) (shown t) (counters (list :events 0 :deltas 0 :frames 0)) (gen 0))

(defvar drgnx-work-client--views (make-hash-table :test #'equal)
  "View id → `drgnx-work-client--view'.  A view is closed with its buffer (the module's kill hook) or by the module's
teardown, which empties the table; there is a handful, never more than the maps the user opens.")

(defvar drgnx-work-client-change-functions nil
  "Called with (VIEW-ID MARKS) after a frame or a delta changed a view's state; each inside the guard
\(`drgnx-guard-run-hook' when loaded).  MARKS as `drgnx-work-client-step'; `(:rows t :layout t :edges t :strip t)'
for a frame.")

(defvar drgnx-work-client-status-functions nil
  "Called with (VIEW-ID STATUS) when a view's status changes (`live', `reconnecting', `hidden').")

(defun drgnx-work-client-views () "The ids of the open views." (hash-table-keys drgnx-work-client--views))

(defun drgnx-work-client--get (id) (gethash id drgnx-work-client--views))

(defun drgnx-work-client-view-state (id)
  "View ID's state, or nil."
  (when-let* ((v (drgnx-work-client--get id))) (drgnx-work-client--view-state v)))

(defun drgnx-work-client-status (id)
  "View ID's status as a string: \"subscribing\", \"live\", \"reconnecting\" or \"hidden\"."
  (when-let* ((v (drgnx-work-client--get id))) (symbol-name (drgnx-work-client--view-status v))))

(defun drgnx-work-client-shown-p (id)
  "Whether the hub was told view ID is shown."
  (when-let* ((v (drgnx-work-client--get id))) (and (drgnx-work-client--view-shown v) t)))

(defun drgnx-work-client-counter (id key)
  "View ID's counter KEY (`:events', `:deltas', `:frames')."
  (when-let* ((v (drgnx-work-client--get id))) (plist-get (drgnx-work-client--view-counters v) key)))

(defun drgnx-work-client--bump (view key)
  (let ((c (drgnx-work-client--view-counters view)))
    (setf (drgnx-work-client--view-counters view) (plist-put c key (1+ (plist-get c key))))))

(defun drgnx-work-client--run (hook &rest args)
  (if (fboundp 'drgnx-guard-run-hook)
      (apply #'drgnx-guard-run-hook hook args)
    (apply #'run-hook-with-args hook args)))

(defun drgnx-work-client--status (view status)
  (unless (eq status (drgnx-work-client--view-status view))
    (setf (drgnx-work-client--view-status view) status)
    (drgnx-work-client--run 'drgnx-work-client-status-functions
                            (drgnx-work-client--view-id view) (symbol-name status))))

(defun drgnx-work-client--changed (view marks)
  (when marks (drgnx-work-client--run 'drgnx-work-client-change-functions (drgnx-work-client--view-id view) marks)))

(defun drgnx-work-client--subscribe (view)
  "Ask the hub for VIEW's frame.  The answer counts only for the subscription it was asked in (a later one, or a
close, makes it stale)."
  (let ((gen (cl-incf (drgnx-work-client--view-gen view))) (id (drgnx-work-client--view-id view)))
    (drgnx-hub-call "work/map/subscribe" (append (list :view id) (drgnx-work-client--view-params view))
                    (lambda (result err) (drgnx-work-client--subscribed id gen result err)))))

(defun drgnx-work-client--subscribed (id gen result err)
  (let ((view (drgnx-work-client--get id)))
    (when (and view (= gen (drgnx-work-client--view-gen view)))
      (if (or err (null result))
          (drgnx-work-client--status view 'reconnecting)
        (setf (drgnx-work-client--view-state view) (drgnx-work-client-init result))
        (drgnx-work-client--bump view :frames)
        (drgnx-work-client--status view (if (drgnx-work-client--view-shown view) 'live 'hidden))
        (drgnx-work-client--changed view (list :rows t :layout t :edges t :strip t))))))

(cl-defun drgnx-work-client-open (id workspace &key (width 226) density filters collapsed selected)
  "Open the view ID on WORKSPACE (a plist :id :roots) and ask the hub for its frame; returns ID.  WIDTH is the drawing
width in units of 4 px."
  (let ((view (drgnx-work-client--make-view
               :id id
               :params (append (list :workspace (list :id (plist-get workspace :id) :roots (plist-get workspace :roots))
                                     :width_units width)
                               (and density (list :density density)) (and filters (list :filters filters))
                               (and collapsed (list :collapsed collapsed)) (and selected (list :selected selected))))))
    (puthash id view drgnx-work-client--views)
    (condition-case nil (drgnx-work-client--subscribe view)
      (error (drgnx-work-client--status view 'reconnecting)))
    id))

(defun drgnx-work-client-set (id &rest params)
  "Tell the hub what changed in view ID: PARAMS are `work/map/set''s fields (:filters :collapsed :width_units
:density :shown :selected).  A change of the saved parameters (:filters :collapsed :width_units :density :selected) is
kept for the next subscription.  Never signals: a hub that is not there is the reconnecting view's matter."
  (when-let* ((view (drgnx-work-client--get id)))
    (let ((saved (drgnx-work-client--view-params view)))
      (cl-loop for (k v) on params by #'cddr
               unless (eq k :shown) do (setq saved (plist-put saved k v)))
      (setf (drgnx-work-client--view-params view) saved))
    (when (plist-member params :shown)
      (setf (drgnx-work-client--view-shown view) (not (memq (plist-get params :shown) '(nil :false)))))
    (ignore-errors (drgnx-hub-call "work/map/set" (append (list :view id) params) #'ignore))
    id))

(defun drgnx-work-client-close (id)
  "Close view ID: the hub forgets it, the cached frame goes."
  (when-let* ((view (drgnx-work-client--get id)))
    (cl-incf (drgnx-work-client--view-gen view))          ; a pending answer is stale now
    (remhash id drgnx-work-client--views)
    (ignore-errors (drgnx-hub-call "work/map/close" (list :view id) #'ignore))
    t))

(defun drgnx-work-client-close-all ()
  "Close every view (the module's teardown)."
  (dolist (id (drgnx-work-client-views)) (drgnx-work-client-close id)))

(defun drgnx-work-client-event (event data)
  "A `drgnx-hub-event-functions' handler: a `work-map' event goes to its view's state."
  (when (equal event "work-map")
    (when-let* ((view (drgnx-work-client--get (plist-get data :view))))
      (drgnx-work-client--bump view :events)
      (cond
       ((eq (plist-get data :stale) t) (drgnx-work-client--status view 'hidden))
       ((drgnx-work-client--view-state view)
        (drgnx-work-client--bump view :deltas)
        (pcase-let* ((old (drgnx-work-client--view-state view))
                     (`(,new . ,marks) (drgnx-work-client-step old data)))
          (setf (drgnx-work-client--view-state view) new)
          (when (plist-get marks :removed) (setq marks (plist-put (copy-sequence marks) :old old)))   ; to resolve the selection
          (when (plist-get data :full) (drgnx-work-client--bump view :frames))
          (when (and (plist-get data :full) (drgnx-work-client--view-shown view))
            (drgnx-work-client--status view 'live))
          (drgnx-work-client--changed view marks)
          (when (plist-get marks :resync) (drgnx-work-client--subscribe view))))))))

(defun drgnx-work-client-connected ()
  "A `drgnx-hub-connected-functions' handler: every view subscribes again (the hub kept nothing)."
  (maphash (lambda (_ view) (condition-case nil (drgnx-work-client--subscribe view)
                              (error (drgnx-work-client--status view 'reconnecting))))
           drgnx-work-client--views))

(defun drgnx-work-client-disconnected ()
  "A `drgnx-hub-disconnect-functions' handler: every view keeps its frame and says it is reconnecting."
  (maphash (lambda (_ view)
             (when-let* ((s (drgnx-work-client--view-state view)))
               (setf (drgnx-work-client--view-state view) (drgnx-work-client-lost s)))
             (drgnx-work-client--status view 'reconnecting))
           drgnx-work-client--views))

(provide 'drgnx-work-client)
;;; drgnx-work-client.el ends here
