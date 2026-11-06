;;; drgnx-work-detail.el --- The Work map's selection chain, keyboard navigation and side panel (library of tools/work-space) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A selection is (KIND . ID): KIND a symbol (`agent', `branch', ...), ID the item's id.  Everything here is a pure
;; function of the cached frame (core/drgnx-work-client.el) and the selection, so moving the selection never waits on
;; the hub: the chain (what the selection came from, up, and what it touches, down), a move along a layer or along the
;; chain, the walk through the agents in team order, the nearest item that is left when the selection goes away, and the
;; text of the side panel.  The panel is also a small view (type `work-detail'): one row per section.
;; Loaded by tools/work-space (drgnx-work-space.el); defines no module.  See docs/develop/work-space.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'text-property-search)
(require 'drgnx-view)
(require 'drgnx-work-client)
(unless (featurep 'drgnx-work-map)
  (load (expand-file-name "drgnx-work-map" (file-name-directory (or load-file-name buffer-file-name))) nil t))

(declare-function drgnx-decor-button "drgnx-decor")
(declare-function drgnx-work-map-open-selection "drgnx-work-map")
(declare-function drgnx-work-map-select "drgnx-work-map")
(declare-function drgnx-work-map--outline-ids "drgnx-work-map")
(declare-function drgnx-work-map--state "drgnx-work-map")
(declare-function drgnx-work-map--state-word "drgnx-work-map")
(declare-function drgnx-work-map--field "drgnx-work-map")
(declare-function drgnx-work-map--parent "drgnx-work-map")
(defvar drgnx-work-map--selection)
(defvar drgnx-work-map--finished)

;;;; The chain

(defconst drgnx-work-nav--chain-kinds '("came-from" "edits" "reads" "runs-on")
  "The edge kinds the chain follows: \"came from\" up, \"touches\" down.")

(defvar drgnx-work-nav--adjacency (make-hash-table :test #'eq :weakness 'key)
  "A frame's edge list → (FORWARD . BACKWARD), hash tables id → the ids a chain edge leads to / from.  Weak on the list:
a new frame has a new list.")

(defun drgnx-work-nav--adj (state)
  (let ((edges (drgnx-work-client-edges state)))
    (or (gethash edges drgnx-work-nav--adjacency)
        (let ((fwd (make-hash-table :test #'equal)) (back (make-hash-table :test #'equal)))
          (dolist (e edges)
            (when (member (plist-get e :kind) drgnx-work-nav--chain-kinds)
              (push (plist-get e :to) (gethash (plist-get e :from) fwd))
              (push (plist-get e :from) (gethash (plist-get e :to) back))))
          (puthash edges (cons fwd back) drgnx-work-nav--adjacency)))))

(defun drgnx-work-nav--reach (adj id)
  "The ids reachable from ID through the adjacency table ADJ, not ID itself."
  (let ((seen nil) (stack (list id)))
    (while stack
      (dolist (z (gethash (pop stack) adj))
        (unless (or (equal z id) (member z seen)) (push z seen) (push z stack))))
    seen))

(defun drgnx-work-nav--layer (state id)
  (drgnx-work-client-kind-layer (or (plist-get (drgnx-work-client-item state id) :kind) (car (split-string id ":")))))

(defun drgnx-work-nav--sorted (state ids)
  (sort (copy-sequence ids) (lambda (a b) (let ((la (drgnx-work-nav--layer state a)) (lb (drgnx-work-nav--layer state b)))
                                            (if (= la lb) (string< a b) (< la lb))))))

(defun drgnx-work-nav-sel (state id)
  "The selection for the item ID of STATE."
  (cons (intern (or (plist-get (drgnx-work-client-item state id) :kind) (car (split-string id ":")))) id))

(defun drgnx-work-nav-chain (state sel)
  "SEL's chain in STATE: (UP DOWN EDGES).  UP: the ids it came from, DOWN: those it touches (both by layer, then id);
EDGES: the chain's edges."
  (let* ((id (cdr sel)) (adj (drgnx-work-nav--adj state))
         (up (drgnx-work-nav--reach (cdr adj) id)) (down (drgnx-work-nav--reach (car adj) id))
         (edges (seq-filter
                 (lambda (e)
                   (and (member (plist-get e :kind) drgnx-work-nav--chain-kinds)
                        (let ((a (plist-get e :from)) (b (plist-get e :to)))
                          (or (and (member a up) (or (equal b id) (member b up)))
                              (and (or (equal a id) (member a down)) (member b down))))))
                 (drgnx-work-client-edges state))))
    (list (drgnx-work-nav--sorted state up) (drgnx-work-nav--sorted state down) edges)))

;;;; Moving

(defun drgnx-work-nav--centre (state id)
  "The x of the middle of ID's card, and its y: (X . Y), or nil when it has no place."
  (when-let* ((r (drgnx-work-client-rect state id)))
    (cons (+ (plist-get r :x) (/ (plist-get r :w) 2.0)) (plist-get r :y))))

(defun drgnx-work-nav--nearest (state from ids &optional above below)
  "Of IDS the one nearest to FROM: the least vertical distance, then the least horizontal.  ABOVE or BELOW keep only
those above / below FROM (all, when none is)."
  (let* ((c0 (drgnx-work-nav--centre state from))
         (with (seq-filter (lambda (i) (drgnx-work-nav--centre state i)) ids))
         (side (seq-filter (lambda (i) (let ((c (drgnx-work-nav--centre state i)))
                                         (cond (above (< (cdr c) (cdr c0))) (below (> (cdr c) (cdr c0))) (t t))))
                           with))
         (pool (or side with)))
    (when (and c0 pool)
      (car (sort (copy-sequence pool)
                 (lambda (a b) (let* ((ca (drgnx-work-nav--centre state a)) (cb (drgnx-work-nav--centre state b))
                                      (da (abs (- (cdr ca) (cdr c0)))) (db (abs (- (cdr cb) (cdr c0))))
                                      (xa (abs (- (car ca) (car c0)))) (xb (abs (- (car cb) (car c0)))))
                                 (cond ((/= da db) (< da db)) ((/= xa xb) (< xa xb)) (t (string< a b))))))))))

(defun drgnx-work-nav-move (state sel dir)
  "The selection after moving SEL in direction DIR: `left' and `right' along the layer (reading order, stopping at its
ends), `up' to what it came from and `down' to what it touches (the nearest of those, by position)."
  (let* ((id (cdr sel)) (target
                         (pcase dir
                           ((or 'left 'right)
                            (let* ((layer (drgnx-work-nav--layer state id))
                                   (row (seq-filter (lambda (i) (and (eql layer (drgnx-work-nav--layer state i))
                                                                     (drgnx-work-client-rect state i)))
                                                    (drgnx-work-client-ids state)))
                                   (row (sort row (lambda (a b) (let ((ra (drgnx-work-client-rect state a)) (rb (drgnx-work-client-rect state b)))
                                                                  (if (= (plist-get ra :y) (plist-get rb :y))
                                                                      (< (plist-get ra :x) (plist-get rb :x))
                                                                    (< (plist-get ra :y) (plist-get rb :y)))))))
                                   (at (cl-position id row :test #'equal)))
                              (and at (nth (max 0 (min (1- (length row)) (+ at (if (eq dir 'left) -1 1)))) row))))
                           ('up (let ((adj (cdr (drgnx-work-nav--adj state))))
                                  (or (drgnx-work-nav--nearest state id (gethash id adj) t)
                                      ;; a missing level: the nearest ancestor, the one on the lowest layer above
                                      (when-let* ((ups (seq-filter (lambda (i) (drgnx-work-client-rect state i))
                                                                   (drgnx-work-nav--reach adj id))))
                                        (drgnx-work-nav--nearest state id
                                                                 (let ((top (apply #'max (mapcar (lambda (i) (drgnx-work-nav--layer state i)) ups))))
                                                                   (seq-filter (lambda (i) (= top (drgnx-work-nav--layer state i))) ups))
                                                                 t)))))
                           ('down (drgnx-work-nav--nearest state id (gethash id (car (drgnx-work-nav--adj state))) nil t)))))
    (if (and target (not (equal target id))) (drgnx-work-nav-sel state target) sel)))

(defun drgnx-work-nav--team (state)
  "The agents and subagents of STATE in team order: plans in their order, agents in start order, each subagent right
after its parent."
  (let (out)
    (dolist (id (drgnx-work-map--outline-ids state))
      (push id out)
      (dolist (sub (sort (seq-filter (lambda (i) (equal (plist-get (drgnx-work-client-item state i) :parent) id))
                                     (drgnx-work-client-ids state))
                         (lambda (a b) (< (or (plist-get (drgnx-work-client-item state a) :order) 0)
                                          (or (plist-get (drgnx-work-client-item state b) :order) 0)))))
        (when (equal (plist-get (drgnx-work-client-item state sub) :kind) "subagent") (push sub out))))
    (nreverse out)))

(defun drgnx-work-nav-agent (state sel forward)
  "The agent after SEL in team order (before it unless FORWARD), wrapping; the first (last) from anything else."
  (let* ((team (drgnx-work-nav--team state)) (at (cl-position (cdr sel) team :test #'equal)) (n (length team)))
    (when team
      (drgnx-work-nav-sel state
                          (nth (cond ((null at) (if forward 0 (1- n))) (forward (mod (1+ at) n)) (t (mod (1- at) n)))
                               team)))))

(defun drgnx-work-nav-resolve (old new sel)
  "SEL, kept or replaced after the frame went from OLD to NEW: (SELECTION . FINISHED).  An item that is still there
stays (FINISHED nil); one that went moves to the nearest item it came from that is left (FINISHED: the id that went), or
to nil when none is.  Nothing signals."
  (let ((id (cdr sel)))
    (if (drgnx-work-client-item new id)
        (cons sel nil)
      (let* ((up (nth 0 (drgnx-work-nav-chain old sel)))
             (left (seq-filter (lambda (i) (drgnx-work-client-item new i)) up)))
        (cons (when left (drgnx-work-nav-sel new (car (last (drgnx-work-nav--sorted new left))))) id)))))

;;;; The side panel's text

(defun drgnx-work-detail--label (state id)
  (or (plist-get (drgnx-work-client-item state id) :label) id))

(defun drgnx-work-detail--why (state id)
  "Lines for the why-chain of ID: the first parent at each level, from the ask down."
  (let ((chain nil) (cur id) (guard 0))
    (while (and (< (cl-incf guard) 8) (setq cur (drgnx-work-map--parent state cur)))
      (let ((it (drgnx-work-client-item state cur)))
        (push (if (equal (plist-get it :kind) "ask") (format "you: \"%s\"" (plist-get it :label)) (plist-get it :label))
              chain)))
    (let ((task (drgnx-work-map--field (drgnx-work-client-item state id) :task)))
      (append chain (and task (list task))))))

(defun drgnx-work-detail--edge-lines (state id)
  "Lines for the edges of ID, in words, both directions."
  (let (out)
    (dolist (e (drgnx-work-client-edges state))
      (let* ((from (plist-get e :from)) (to (plist-get e :to)) (kind (plist-get e :kind))
             (here-from (equal from id)) (here-to (equal to id)))
        (when (or here-from here-to)
          (let ((other (drgnx-work-detail--label state (if here-from to from))))
            (push (pcase kind
                    ("came-from" (if here-from (format "%s — came from this" other) nil))
                    ("edits" (if here-from (format "edits %s" other) (format "edited by %s" other)))
                    ("reads" (if here-from (format "reads %s" other) (format "read by %s" other)))
                    ("runs-on" (if here-from (format "runs on %s" other) (format "%s runs on this" other)))
                    ("overlap" (format "overlaps with %s" other))
                    ("manages" (if here-from (format "manages %s" other) (format "managed by %s" other)))
                    (_ (format "%s: %s" kind other)))
                  out)))))
    (delq nil (nreverse out))))

(defun drgnx-work-detail--job-row (agent job)
  "The queue row of the job JOB of the agent item AGENT: its name, agent, machine, state, time and the keys sent.  The
text carries the job's id for `drgnx-work-job-log'."
  (propertize
   (concat "  "
           (string-join
            (delq nil (list (plist-get job :name) (plist-get agent :label)
                            (or (plist-get job :runner) "waiting for a machine") (plist-get job :state)
                            (and (equal (plist-get job :state) "running") (plist-get job :started)
                                 (drgnx-work-map--job-time job))
                            (and (plist-get job :keys) (format "keys: %s" (string-join (plist-get job :keys) ", ")))))
            " · "))
   'drgnx-work-job (plist-get job :id)))

(defun drgnx-work-detail--machine-queue (state machine)
  "The queue of the machine item MACHINE in STATE: the jobs running on it, each with its agent, and the jobs that wait
for a machine, or nil when there are none."
  (let ((name (plist-get machine :label)) (running nil) (waiting nil)
        (takes-waiting (or (equal (plist-get machine :label) "local") (drgnx-work-map--field machine :runner))))
    (dolist (id (drgnx-work-client-ids state))
      (let* ((it (drgnx-work-client-item state id)) (job (and (equal (plist-get it :kind) "agent")
                                                              (drgnx-work-map--field it :job))))
        (cond ((null job))
              ((equal (plist-get job :runner) name) (push (drgnx-work-detail--job-row it job) running))
              ((and takes-waiting (null (plist-get job :runner))) (push (drgnx-work-detail--job-row it job) waiting)))))
    (when (or running waiting)
      (concat (format "queue · %s\n" name)
              (mapconcat #'identity (nreverse running) "\n")
              (if (and running waiting) "\n" "")
              (if waiting (concat "waiting\n" (mapconcat #'identity (nreverse waiting) "\n")) "")
              "\n  l live log"))))

(defun drgnx-work-detail-sections (state sel &optional finished)
  "The side panel's sections for SEL in STATE: an alist (KEY . TEXT) of :head :why :touches :conclusions :actions.
FINISHED: the id of the item that went and was replaced by SEL, said first."
  (let* ((id (cdr sel)) (item (drgnx-work-client-item state id)) (f (lambda (k) (drgnx-work-map--field item k))))
    (if (null item)
        (list (cons :head "Nothing is selected."))
      (seq-filter
       #'cdr                            ; a section with nothing to say (the queue of a branch not in it) is left out
       (list
        (cons :head
              (concat (if finished (format "%s finished.\n" (drgnx-work-detail--label state finished)) "")
                      (format "%s · %s" (plist-get item :label) (plist-get item :kind))
                      (let ((bits (delq nil (list (and (funcall f :state) (drgnx-work-map--state-word (funcall f :state)))
                                                  (and (funcall f :minutes) (format "%d min" (funcall f :minutes)))
                                                  (funcall f :spend) (funcall f :model)
                                                  (and (funcall f :context) (format "context %d %%" (funcall f :context)))))))
                        (if bits (concat "\n" (string-join bits " · ")) ""))))
        (cons :why
              (let* ((why (drgnx-work-detail--why state id))
                     (parents (delq nil (mapcar (lambda (e) (and (equal (plist-get e :kind) "came-from") (equal (plist-get e :to) id)
                                                                 (drgnx-work-detail--label state (plist-get e :from))))
                                                (drgnx-work-client-edges state)))))
                (concat "why ↑\n"
                        (if why (mapconcat (lambda (l) (concat "  › " l)) why "\n") "  no ask, spec or plan recorded")
                        (if parents (format "\n  came from: %s" (string-join parents ", ")) ""))))
        (cons :touches
              (let ((lines (drgnx-work-detail--edge-lines state id)))
                (concat "touches ↓\n"
                        (if lines (mapconcat (lambda (l) (concat "  " l)) lines "\n") "  nothing yet")
                        (if (funcall f :reads) (format "\n  reads %d files" (funcall f :reads)) "")
                        (if (funcall f :edits)
                            (format "\n  edits %d files (+%d −%d)" (nth 0 (funcall f :edits)) (nth 1 (funcall f :edits))
                                    (nth 2 (funcall f :edits)))
                          ""))))
        (cons :conclusions
              (concat "conclusions\n"
                      (if-let* ((c (funcall f :conclusion))) (concat "  → " c) "  none recorded")))
        ;; a branch in the merge queue: where it stands and what it conflicts with, as the hub sent it
        (cons :queue
              (or (when-let* ((q (funcall f :queue)))
                    (concat "merge queue\n"
                            (format "  %d of %d" (car q) (cadr q))
                            (if-let* ((c (funcall f :conflicts))) (format "\n  conflicts with %s" (string-join c ", ")) "")))
                  (and (equal (plist-get item :kind) "machine") (drgnx-work-detail--machine-queue state item))))
        (cons :actions "actions\n  open (RET)"))))))

(defun drgnx-work-detail-text (state sel &optional finished)
  "All of the side panel's text for SEL in STATE, one section after another."
  (mapconcat #'cdr (drgnx-work-detail-sections state sel finished) "\n"))

;;;; The panel as a view

(defvar-local drgnx-work-detail--map nil "The map buffer a detail buffer shows the selection of.")

(define-derived-mode drgnx-work-detail-mode special-mode "Work detail"
  "The Work space's side panel: why the selected item exists, what it touches, its conclusions and what you can do."
  (setq-local truncate-lines nil cursor-type nil))

(defun drgnx-work-detail--sections ()
  (when-let* ((map drgnx-work-detail--map) ((buffer-live-p map)))
    (with-current-buffer map
      (when-let* ((state (drgnx-work-map--state)) (sel drgnx-work-map--selection))
        (drgnx-work-detail-sections state sel drgnx-work-map--finished)))))

(defun drgnx-work-detail--render (key)
  (concat (or (cdr (assq key (drgnx-work-detail--sections))) (if (eq key :head) "Nothing is selected." "")) "\n"))

(defun drgnx-work-detail--sync (_view)
  (drgnx-view-sync-rows drgnx-view (or (mapcar #'car (drgnx-work-detail--sections)) '(:head))
                        (lambda (key) (cdr (assq key (drgnx-work-detail--sections))))))

(drgnx-view-define 'work-detail :render #'drgnx-work-detail--render :sync #'drgnx-work-detail--sync
                   :key-test 'eq :slice drgnx-view-slice)

(defun drgnx-work-detail-buffer (map-buffer)
  "The side panel's buffer for MAP-BUFFER, made when there is none."
  (let ((buffer (get-buffer-create (format "*drgnx work detail: %s*" (string-trim (buffer-name map-buffer) "\\*drgnx work: " "\\*")))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'drgnx-work-detail-mode)
        (drgnx-work-detail-mode)
        (drgnx-view-attach 'work-detail))
      (setq drgnx-work-detail--map map-buffer)
      (drgnx-view-touch drgnx-view))
    buffer))

(declare-function drgnx-hub-call "drgnx-hub-client")
(declare-function drgnx-work-map--job-time "drgnx-work-map")

(defun drgnx-work-job-log ()
  "Show the end of the log of the job on this row of the queue (the first job of the panel when point is on none).
Press it again for what came since."
  (interactive)
  (let ((id (or (get-text-property (line-beginning-position) 'drgnx-work-job)
                (get-text-property (point) 'drgnx-work-job)
                (save-excursion (goto-char (point-min))
                                (when-let* ((m (text-property-search-forward 'drgnx-work-job)))
                                  (prop-match-value m))))))
    (unless id (user-error "No job in this queue"))
    (drgnx-hub-call "exec/log" (list :id id :tail_bytes 65536)
                    (lambda (result err)
                      (if err (message "Work: the log of %s: %s" id err)
                        (with-current-buffer (let ((name (format "*drgnx job log: %s*" id)))
                                               (when-let* ((old (get-buffer name))) (kill-buffer old))
                                               (generate-new-buffer name))
                          (insert (string-join (plist-get result :lines) "\n") "\n")
                          (special-mode)
                          (goto-char (point-max))
                          (display-buffer (current-buffer)))))
                    :deadline 10)))

(defun drgnx-work-detail-buffers ()
  (seq-filter (lambda (b) (eq (buffer-local-value 'major-mode b) 'drgnx-work-detail-mode)) (buffer-list)))

(defun drgnx-work-detail-update (map-buffer)
  "The selection of MAP-BUFFER changed: its panel (when it has one) is drawn again."
  (dolist (b (drgnx-work-detail-buffers))
    (when (eq (buffer-local-value 'drgnx-work-detail--map b) map-buffer)
      (with-current-buffer b (drgnx-view-touch drgnx-view)))))

(provide 'drgnx-work-detail)
;;; drgnx-work-detail.el ends here
