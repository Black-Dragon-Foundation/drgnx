;;; orders-fixture.el --- every order of a pure Lisp core -*- lexical-binding: t -*-
;; Code whose correctness depends on the order of its inputs is split into a pure core (STEP: no process, timer or
;; clock) and a thin shell.  `drgnx-test-every-order' runs the core in every order its inputs can arrive in, within
;; the same bound as the Rust helper `skuld' (docs/develop/runtime.md): every order while there are at most 20,000,
;; above that every order within 2 delays of the natural one.  Inputs are a partial order: sources, each in its own
;; order, plus happens-before edges.  A run never passes vacuously: a cycle, no events, a declared kind no order
;; produced and re-entry deeper than the limit each fail, naming the cause.
(require 'cl-lib)
(require 'ert)
(require 'seq)
(require 'subr-x)

(defun drgnx-test-orders--fail (fmt &rest args)
  "Fail the test with the message FMT and ARGS."
  (ert-fail (list :message (apply #'format fmt args))))

(defun drgnx-test-orders--graph (sources edges)
  "SOURCES and EDGES checked: a vector [LENS PREDS NAMES EVENTS], or a failure.
PREDS holds, per source and event, the (SRC . I) the edges put before it."
  (let* ((names (vconcat (mapcar #'car sources)))
         (events (vconcat (mapcar (lambda (s) (vconcat (cdr s))) sources)))
         (lens (vconcat (mapcar #'length events)))
         (preds (vconcat (mapcar (lambda (n) (make-vector n nil)) lens)))
         (src (lambda (s)
                (or (if (integerp s) (and (< -1 s (length names)) s) (cl-position s names :test #'equal))
                    (drgnx-test-orders--fail "an edge names source %S, but there is no such source" s)))))
    (dolist (edge edges)
      (let ((ab (list (cons (funcall src (caar edge)) (cdar edge))
                      (cons (funcall src (cadr edge)) (cddr edge)))))
        (pcase-dolist (`(,s . ,i) ab)
          (unless (and (natnump i) (< i (aref lens s)))
            (drgnx-test-orders--fail "an edge names event %S of source %d (%s), but source %d (%s) has %d events"
                                     i s (aref names s) s (aref names s) (aref lens s))))
        (push (car ab) (aref (aref preds (car (nth 1 ab))) (cdr (nth 1 ab))))))
    (let ((g (vector lens preds names events)))
      (drgnx-test-orders--acyclic g)
      g)))

(defun drgnx-test-orders--acyclic (g)
  "Fail unless G's chains and edges are acyclic (Kahn's algorithm)."
  (let* ((lens (aref g 0)) (preds (aref g 1)) (n (length lens))
         (base (make-vector n 0)) (total 0))
    (dotimes (s n) (aset base s total) (cl-incf total (aref lens s)))
    (let ((indegree (make-vector total 0)) (after (make-vector total nil)) ready (ran 0))
      (dotimes (s n)
        (dotimes (i (aref lens s))
          (let ((node (+ (aref base s) i)))
            (when (> i 0) (push node (aref after (1- node))) (cl-incf (aref indegree node)))
            (pcase-dolist (`(,a . ,j) (aref (aref preds s) i))
              (push node (aref after (+ (aref base a) j)))
              (cl-incf (aref indegree node))))))
      (dotimes (node total) (when (zerop (aref indegree node)) (push node ready)))
      (while ready
        (cl-incf ran)
        (dolist (m (aref after (pop ready)))
          (when (zerop (cl-decf (aref indegree m))) (push m ready))))
      (unless (= ran total)
        (let (stuck)
          (dotimes (s n)
            (dotimes (i (aref lens s))
              (when (> (aref indegree (+ (aref base s) i)) 0)
                (push (format "%s[%d]" (aref (aref g 2) s) i) stuck))))
          (setq stuck (nreverse stuck))
          (drgnx-test-orders--fail "the edges form a cycle: %s%s can never run"
                                   (string-join (seq-take stuck 8) ", ")
                                   (if (> (length stuck) 8) (format " and %d more" (- (length stuck) 8)) "")))))))

(defun drgnx-test-orders--enabled (g pos)
  "The sources whose next event may run at POS, lowest first: the natural scheduler takes the first."
  (let ((lens (aref g 0)) (preds (aref g 1)) out)
    (dotimes (s (length lens))
      (let ((p (aref pos s)))
        (when (and (< p (aref lens s))
                   (cl-every (lambda (e) (> (aref pos (car e)) (cdr e))) (aref (aref preds s) p)))
          (push s out))))
    (nreverse out)))

(defun drgnx-test-orders--choices (g pos budget)
  "The enabled sources at POS a run may take with BUDGET delays left (nil: no bound); the r-th costs r."
  (let ((en (drgnx-test-orders--enabled g pos)))
    (if budget (seq-take en (1+ budget)) en)))

(defun drgnx-test-orders--count (g budget cap)
  "G's orders within BUDGET delays (nil: all), exactly up to CAP (nil: no cap), CAP itself above it."
  (let ((memo (make-hash-table :test #'equal))
        (total (apply #'+ (append (aref g 0) nil))))
    (cl-labels ((from (pos depth budget)
                  (if (= depth total)
                      (if cap (min cap 1) 1)
                    (let ((key (cons budget (copy-sequence pos))))
                      (or (gethash key memo)
                          (let ((sum 0))
                            (cl-loop for s in (drgnx-test-orders--choices g pos budget)
                                     for rank from 0
                                     do (cl-incf (aref pos s))
                                     (cl-incf sum (from pos (1+ depth) (and budget (- budget rank))))
                                     (cl-decf (aref pos s))
                                     (when cap (setq sum (min sum cap)))
                                     until (and cap (>= sum cap)))
                            (puthash key sum memo)))))))
      (from (make-vector (length (aref g 0)) 0) 0 budget))))

(defun drgnx-test-orders--walk (g budget visit)
  "Call VISIT with each order of G within BUDGET delays (nil: all), as a list of (SRC . I), depth first."
  (let ((total (apply #'+ (append (aref g 0) nil))))
    (cl-labels ((walk (pos order depth budget)
                  (if (= depth total)
                      (funcall visit (reverse order))
                    (cl-loop for s in (drgnx-test-orders--choices g pos budget)
                             for rank from 0
                             do (let ((i (aref pos s)))
                                  (aset pos s (1+ i))
                                  (walk pos (cons (cons s i) order) (1+ depth) (and budget (- budget rank)))
                                  (aset pos s i))))))
      (walk (make-vector (length (aref g 0)) 0) nil 0 budget))))

(cl-defun drgnx-test-every-order-count (&key sources edges cap)
  "The number of orders of SOURCES and EDGES (as `drgnx-test-every-order' takes them), exactly up to CAP."
  (drgnx-test-orders--count (drgnx-test-orders--graph sources edges) nil cap))

(defun drgnx-test-orders--mode-name (mode)
  (if (eq mode 'exhaustive) "exhaustive" (format "delay-bounded, %d delays" (cadr mode))))

(cl-defun drgnx-test-every-order (&key kinds (kind-of #'car) sources edges init step check
                                       (exhaustive-max 20000) (delays 2) (reentry-depth 64))
  "Run a fresh core in every order of SOURCES consistent with EDGES, within the bound; fail on the first bad order.
KINDS: the declared event kinds (symbols); KIND-OF maps an event to its kind (default `car').  Every kind must be
produced by some order, external or re-entrant, and every event's kind must be declared.
SOURCES: ((NAME . EVENTS) ...), each in its own order.  EDGES: (((SRC . I) . (SRC2 . J)) ...): SRC's I-th event
happens before SRC2's J-th; a SRC is a source's NAME or its index.
INIT: () -> STATE.  STEP: (STATE EVENT) -> (STATE . RAISED): the RAISED events are fed, depth first, before the
next external event, at most REENTRY-DEPTH deep.  CHECK: (STATE ORDER) -> nil, or a failure string; ORDER is the
external order.
Every order runs while there are at most EXHAUSTIVE-MAX; above that, every order within DELAYS delays of the
natural one (the lowest-numbered enabled source first; a delay skips the source it would take, once).
Returns (:orders N :mode exhaustive|(delay-bounded K) :kinds-seen KINDS).  A bad order fails the test with
\(:order I :of N :mode MODE :events ORDER :fed FED :message MESSAGE)."
  (let* ((g (drgnx-test-orders--graph sources edges))
         (_ (when (zerop (apply #'+ (append (aref g 0) nil)))
              (drgnx-test-orders--fail "no order to run: the sources hold no events")))
         (all (drgnx-test-orders--count g nil (1+ exhaustive-max)))
         (budget (and (> all exhaustive-max) delays))
         (mode (if budget (list 'delay-bounded delays) 'exhaustive))
         (of (if budget (drgnx-test-orders--count g budget nil) all))
         (ran 0)
         (seen nil))
    (drgnx-test-orders--walk
     g budget
     (lambda (order)
       (cl-incf ran)
       (let* ((events (mapcar (lambda (at) (aref (aref (aref g 3) (car at)) (cdr at))) order))
              (state (funcall init))
              (fed nil)
              (fail (lambda (message)
                      (ert-fail (list :order ran :of of :mode mode :events events :fed (reverse fed)
                                      :message message)))))
         (dolist (ev events)
           (let ((stack (list (cons ev 0))))
             (while stack
               (pcase-let* ((`(,e . ,depth) (pop stack))
                            (kind (funcall kind-of e)))
                 (when (> depth reentry-depth)
                   (funcall fail (format "re-entry deeper than %d" reentry-depth)))
                 (unless (memq kind kinds)
                   (funcall fail (format "the kind %S of %S is not declared in KINDS %S" kind e kinds)))
                 (cl-pushnew kind seen)
                 (push e fed)
                 (let ((r (funcall step state e)))
                   (setq state (car r))
                   (setq stack (nconc (mapcar (lambda (x) (cons x (1+ depth))) (cdr r)) stack)))))))
         (let ((message (funcall check state events)))
           (when message (funcall fail message))))))
    (unless (= ran of)
      (drgnx-test-orders--fail "the walk ran %d of the %d orders it counted" ran of))
    (let ((unseen (cl-remove-if (lambda (k) (memq k seen)) kinds)))
      (when unseen
        (drgnx-test-orders--fail
         "no order produced the declared event kind(s) %s (%d orders, %s): a source or a step must make each one"
         (mapconcat #'symbol-name unseen ", ") ran (drgnx-test-orders--mode-name mode))))
    (list :orders ran :mode mode :kinds-seen (cl-remove-if-not (lambda (k) (memq k seen)) kinds))))

(provide 'drgnx-orders-fixture)

;;; orders-fixture.el ends here
