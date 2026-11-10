;;; view-model-test.el --- batch tests: views' models queued and applied at the draw (wb/drgnx-view.el, Sjá) -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: orders
;; Every order the editor can see: the hub writes a model before the rows built from it, so a model always comes before
;; its row patch; the draw, the queue's own timer and the user's key may come anywhere.  Each test runs every such
;; order on a fresh view and checks that a key answers from the model that is drawn.  Needs Sjá (a Nidhogg with
;; `nidhogg-view--call'); skipped elsewhere.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-view)

(defvar drgnx-view-model-test--sent nil "What the view sent the hub, newest first: (METHOD . PARAMS).")
(defvar drgnx-view-model-test--n 0 "Counts the views the tests made: each run gets a view name of its own in Sjá.")

(defmacro drgnx-view-model-test--with (&rest body)
  "BODY in a fresh buffer attached as the hub-fed pair (`view' . \"c\") at epoch 1, `view' a new name; sending
captured.  `h' is the buffer's instance in Sjá."
  (declare (indent 0))
  `(progn
     (drgnx-test-require-nidhogg (fboundp 'nidhogg-view-push) "nidhogg-view-push")
     (let ((drgnx-view-patch--buffers (make-hash-table :test #'equal))
           (drgnx-view-model--views (make-hash-table :test #'equal))
           (drgnx-view-patch--hooked nil)
           (drgnx-view-model-test--sent nil)
           (drgnx-view-patch-send-function (lambda (m p) (push (cons m p) drgnx-view-model-test--sent)))
           (view (format "vm-test-%d" (cl-incf drgnx-view-model-test--n))))
       (with-temp-buffer
         (let ((buf (current-buffer)))
           (drgnx-view-patch-attach view "c" :epoch 1)
           (let ((h (drgnx-view-patch-handle drgnx-view-patch)))
             (ignore h)
             (unwind-protect (progn ,@body)
               (drgnx-view-patch-teardown)
               (drgnx-timer-cancel (cons 'drgnx-view buf))
               (drgnx-timer-cancel (cons 'drgnx-view-model view)))))))))

(defun drgnx-view-model-test--node (id right)
  "A node ID whose `right' link is RIGHT (nil: none), with one row of its own."
  (list :id id :kind "card" :nav (if right (list :right right) (list :left id)) :fields (vector (vector "label" id))
        :rows (vector id)))

(defun drgnx-view-model-test--json (ops)
  (json-serialize (list :ops (vconcat ops))))

(defun drgnx-view-model-test--reset (nodes)
  "A reset op of NODES, a links model with the list `team' of their ids."
  (list :reset (list :descriptor (list :scheme "links" :chain_kinds [] :match_fields ["label"] :lists ["team"]
                                       :classes ["selected" "dim"] :start "team")
                     :nodes (vconcat nodes) :edges []
                     :lists (vector (list :name "team" :ids (vconcat (mapcar (lambda (n) (plist-get n :id)) nodes)))))))

(cl-defun drgnx-view-model-test--model (view ops &key (hub 7) (base 0) (version 1) reset)
  (list :view view :hub hub :base base :version version :reset reset :model (drgnx-view-model-test--json ops)))

(cl-defun drgnx-view-model-test--rows (view model keys &key (hub 7) (base 0) (version 1) reset)
  "A row patch of VIEW naming MODEL: a reset to KEYS (RESET), else their rows replaced."
  (list :view view :class "c" :hub hub :base base :version version :env_epoch 1 :model model
        :ops (list (if reset
                       (list :reset (mapcar (lambda (k) (list :key k :text (format "row %s" k))) keys))
                     (list :replace (mapcar (lambda (k) (list :key k :text (format "row %s again" k))) keys))))))

(defun drgnx-view-model-test--start (view)
  "VIEW's first model (a, b, c; a's right is b) and its rows, applied and drawn."
  (should (eq 'reset (drgnx-view-model-event
                      (drgnx-view-model-test--model
                       view (list (drgnx-view-model-test--reset
                                   (list (drgnx-view-model-test--node "a" "b") (drgnx-view-model-test--node "b" nil)
                                         (drgnx-view-model-test--node "c" nil))))
                       :reset t))))
  (should (eq 'apply (drgnx-view-apply-patch (drgnx-view-model-test--rows view 1 '("a" "b" "c") :reset t))))
  (drgnx-view-draw-now drgnx-view))

(defun drgnx-view-model-test--right-of-a (h)
  "Where `right' goes from a, in instance H (a stays selected)."
  (nidhogg-view-set h 'select "a")
  (prog1 (nidhogg-view-follow h "right") (nidhogg-view-set h 'select "a")))

(defun drgnx-view-model-test--orders (steps free)
  "Every order of STEPS (kept in their order) with each of FREE put anywhere among them: a list of lists."
  (if (null free)
      (list steps)
    (let (out)
      (dolist (rest (drgnx-view-model-test--orders steps (cdr free)))
        (dotimes (i (1+ (length rest)))
          (push (append (take i rest) (list (car free)) (nthcdr i rest)) out)))
      (nreverse out))))

(defun drgnx-view-model-test--queued-none (view)
  "Non-nil when VIEW has no model queued in Sjá (a drain applies none)."
  (eql 0 (car (nidhogg-view-drain view))))

;;;; The rules on the envelope (D): Sjá decides

(ert-deftest drgnx-view-model/envelope-rules ()
  "Pattern D: Sjá decides by the stream and the envelope; Lisp sends a resync for a gap and nothing else."
  (drgnx-view-model-test--with
    (let ((m (lambda (hub base version &optional reset)
               (drgnx-view-model-event (drgnx-view-model-test--model view (list (list :remove ["x"])) :hub hub
                                                                     :base base :version version :reset reset)))))
      (should (eq 'drop (funcall m 7 0 1)))           ; no reset yet
      (should (eq 'reset (funcall m 7 0 1 t)))
      (should (eq 'queue (funcall m 7 1 2)))
      (should (eq 'drop (funcall m 7 0 1)))           ; old
      (should (eq 'drop (funcall m 8 2 3)))           ; another hub's diff
      (should-not drgnx-view-model-test--sent)
      (should (eq 'resync (funcall m 7 5 6)))         ; a gap
      (should (equal (list (cons "view/resync" (list :view view :model t))) drgnx-view-model-test--sent))
      (should (eq 'reset (funcall m 7 3 4 t)))        ; the resync's answer
      (should (eq 'drop (funcall m 7 2 3 t)))         ; an older reset
      (should (eq 'reset (funcall m 8 9 10 t)))       ; another hub's reset: a new stream
      (should (eq 'reset (funcall m 8 0 1 t)))        ; subscribed again
      (should (equal (list (nidhogg-view-push "{\"event\":\"view-model\",\"data\":{}}")) '(nil))))))

(ert-deftest drgnx-view-model/a-full-queue-asks-one-resync ()
  "Pattern D: past 64 models unapplied Sjá drops the queue and the stream: one `view/resync' with `model', and diffs
are dropped until the reset comes."
  (drgnx-view-model-test--with
    (drgnx-view-model-test--start view)
    (dotimes (i 64)
      (should (eq 'queue (drgnx-view-model-event
                          (drgnx-view-model-test--model view (list (list :remove ["x"])) :base (+ 1 i) :version (+ 2 i))))))
    (should (eq 'resync (drgnx-view-model-event
                         (drgnx-view-model-test--model view (list (list :remove ["x"])) :base 65 :version 66))))
    (should (eq 'drop (drgnx-view-model-event
                       (drgnx-view-model-test--model view (list (list :remove ["x"])) :base 66 :version 67))))
    (should (equal (list (cons "view/resync" (list :view view :model t))) drgnx-view-model-test--sent))
    (should (drgnx-view-model-test--queued-none view))
    (should (equal "b" (drgnx-view-model-test--right-of-a h)))))

;;;; Keys answer from the drawn model (A)

(ert-deftest drgnx-view-nav/keys-answer-from-the-drawn-model ()
  "Pattern A: a relayout (a's right moves from b to c) comes as model 2 and the rows naming it.  In every order of the
model, its rows, the queue's timer and the draw, `right' from a answers b until the draw that inserts those rows, and
c from then on; the timer never applies a model a row patch named.  (The timer, a throttle after the model, never
falls between the model and its rows, which the hub writes back to back: a model unnamed for a throttle applies.)"
  (dolist (order (cl-remove-if (lambda (o) (< (cl-position 'model o) (cl-position 'timer o) (cl-position 'rows o)))
                               (drgnx-view-model-test--orders '(model rows draw) '(timer))))
    (drgnx-view-model-test--with
      (drgnx-view-model-test--start view)
      (should (equal "b" (drgnx-view-model-test--right-of-a h)))
      (let ((drawn nil))
        (dolist (step order)
          (pcase step
            ('model (should (eq 'queue (drgnx-view-model-event
                                        (drgnx-view-model-test--model
                                         view (list (list :nodes (vector (drgnx-view-model-test--node "a" "c"))))
                                         :base 1 :version 2)))))
            ('rows (should (eq 'apply (drgnx-view-apply-patch
                                       (drgnx-view-model-test--rows view 2 '("a") :base 1 :version 2)))))
            ('timer (drgnx-view-model--due view))
            ('draw (drgnx-view-draw-now drgnx-view)
                   (setq drawn (memq 'rows (cdr (memq step (reverse order)))))))
          (should (equal (if drawn "c" "b") (drgnx-view-model-test--right-of-a h))))
        (when (memq 'draw (memq 'rows order))
          (should (equal "row a again\nrow b\nrow c\n" (buffer-substring-no-properties (point-min) (point-max)))))
        (should-not drgnx-view-model-test--sent)))))

(ert-deftest drgnx-view-nav/unnamed-model-applies-on-its-timer ()
  "Pattern A: a model no row patch names (a field the rows don't show) applies on the queue's timer, in either order of
the timer and a draw with nothing to insert."
  (dolist (order '((model draw timer) (model timer draw)))
    (drgnx-view-model-test--with
      (drgnx-view-model-test--start view)
      (dolist (step order)
        (pcase step
          ('model (drgnx-view-model-event
                   (drgnx-view-model-test--model
                    view (list (list :nodes (vector (plist-put (drgnx-view-model-test--node "a" "b")
                                                               :fields [["label" "A2"]]))))
                    :base 1 :version 2)))
          ('timer (drgnx-view-model--due view))
          ('draw (drgnx-view-draw-now drgnx-view))))
      (should (equal "A2" (nidhogg-view-get h 'field "label" "a"))))))

(ert-deftest drgnx-view-nav/selection-survives-every-order-of-patch-and-key ()
  "Pattern A: the user's key (right from a: b) and a resync's reset of the same model with its rows come in every
order with the draw: once all have run, b is selected, in Sjá and on screen."
  (dolist (order (drgnx-view-model-test--orders '(model rows) '(key draw)))
    (drgnx-view-model-test--with
      (drgnx-view-model-test--start view)
      (nidhogg-view-set h 'select "a")
      (dolist (step order)
        (pcase step
          ('key (should (equal "b" (nidhogg-view-follow h "right"))))
          ('model (should (eq 'reset (drgnx-view-model-event
                                      (drgnx-view-model-test--model
                                       view (list (drgnx-view-model-test--reset
                                                   (list (drgnx-view-model-test--node "a" "b")
                                                         (drgnx-view-model-test--node "b" nil)
                                                         (drgnx-view-model-test--node "c" nil))))
                                       :base 1 :version 2 :reset t)))))
          ('rows (drgnx-view-apply-patch (drgnx-view-model-test--rows view 2 '("a" "b" "c") :base 1 :version 2
                                                                      :reset t)))
          ('draw (drgnx-view-draw-now drgnx-view))))
      (drgnx-view-draw-now drgnx-view)
      (should (equal "b" (nidhogg-view-get h 'selection)))
      (should (drgnx-view-model-test--queued-none view)))))

(ert-deftest drgnx-view-model/hub-lost-drops-the-queue-keys-still-move ()
  "Pattern A: the hub goes with a model queued: the queue goes, keys answer from what is drawn, and the next
subscription's reset (version 1 again, the same hub) applies."
  (drgnx-view-model-test--with
    (drgnx-view-model-test--start view)
    (drgnx-view-model-event (drgnx-view-model-test--model
                             view (list (list :nodes (vector (drgnx-view-model-test--node "a" "c"))))
                             :base 1 :version 2))
    (drgnx-view-patch--disconnected)
    (should (drgnx-view-model-test--queued-none view))
    (should (eql 3 (nidhogg-view-get h 'health)))                          ; stale
    (should (equal "b" (drgnx-view-model-test--right-of-a h)))
    (should (eq 'reset (drgnx-view-model-event
                        (drgnx-view-model-test--model
                         view (list (drgnx-view-model-test--reset (list (drgnx-view-model-test--node "a" "c")
                                                                        (drgnx-view-model-test--node "c" nil))))
                         :reset t))))
    (drgnx-view-apply-patch (drgnx-view-model-test--rows view 1 '("a" "c") :reset t))
    (drgnx-view-draw-now drgnx-view)
    (should (eq 'applied (drgnx-view-model-last (gethash view drgnx-view-model--views))))
    (should (equal "c" (drgnx-view-model-test--right-of-a h)))))

(declare-function drgnx-hub-call "drgnx-hub-client")
(declare-function drgnx-hub-call-sync "drgnx-hub-client")
(declare-function drgnx-hub--call-on "drgnx-hub-client")

(ert-deftest drgnx-view-nav/keys-move-while-hub-is-stopped ()
  "Pattern B, the hub's door shut as the gate: every way to call the hub signals, as a stopped hub would never answer.
In every order of a model queued and keys, a drawn view's keys move from what is drawn and nothing calls the hub."
  (dolist (queued '(nil t))
    (drgnx-view-model-test--with
      (drgnx-view-model-test--start view)
      (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (&rest _) (error "A key called the hub")))
                ((symbol-function 'drgnx-hub-call-sync) (lambda (&rest _) (error "A key called the hub")))
                ((symbol-function 'drgnx-hub--call-on) (lambda (&rest _) (error "A key called the hub"))))
        (when queued
          (drgnx-view-model-event (drgnx-view-model-test--model
                                   view (list (list :nodes (vector (drgnx-view-model-test--node "a" "c"))))
                                   :base 1 :version 2)))
        (nidhogg-view-set h 'select nil)
        (should (equal "a" (nidhogg-view-follow h "right")))      ; no selection: the team's first
        (should (equal "b" (nidhogg-view-follow h "right")))
        (should (equal "b" (nidhogg-view-follow h "right")))      ; b has no right: it stays
        (should (equal "c" (nidhogg-view-walk h "team" 1)))
        (should-not drgnx-view-model-test--sent)))))

(ert-deftest drgnx-view-model/gap-asks-one-resync ()
  "Pattern D: two models past a gap send one `view/resync' with `model'."
  (drgnx-view-model-test--with
    (drgnx-view-model-test--start view)
    (dolist (v '(3 4))
      (should (eq 'resync (drgnx-view-model-event
                           (drgnx-view-model-test--model view (list (list :remove ["c"])) :base v :version (1+ v))))))
    (should (equal (list (cons "view/resync" (list :view view :model t))) drgnx-view-model-test--sent))))

(ert-deftest drgnx-view-model/an-emacs-without-the-queue-says-so-once ()
  "Pattern D: on an Emacs without Sjá's queue (an older Nidhogg, or none) a model line fails one `render' notice
naming `nidhogg-view-push' and the fix, not an error per line and not a silent empty view.  Runs on any Emacs: it
takes the door away."
  (let ((said nil) (drgnx-view-model--said-missing nil)
        (line "{\"event\":\"view-model\",\"data\":{\"view\":\"v\",\"hub\":1,\"base\":0,\"version\":1,\"reset\":true,\"model\":{\"ops\":[]}}}"))
    (cl-letf (((symbol-function 'nidhogg-view-push) nil)
              ((symbol-function 'drgnx-notify) (lambda (&rest args) (push args said))))
      (should-not (drgnx-view-model-line line))
      (should-not (drgnx-view-model-line line))
      (should (= 1 (length said)))
      (pcase-let ((`(,source ,severity ,text . ,keys) (car said)))
        (should (eq source 'render))
        (should (eq severity 'fail))
        (should (string-search "nidhogg-view-push" text))
        (should (eq (plist-get keys :life) 'condition))
        (should (plist-get keys :fix))))))

;;; view-model-test.el ends here
