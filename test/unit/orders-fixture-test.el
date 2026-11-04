;;; orders-fixture-test.el --- drgnx-test-every-order -*- lexical-binding: t -*-
;; test-class: det
;; Every answer here is known exactly: closed forms (binomials, multinomials) or a brute force over every
;; interleaving that shares no code with the helper.  The counts are skuld's (runtime/crates/skuld/src/tests.rs), so a
;; Lisp core and a Rust core are held to the same bound.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/orders-fixture" drgnx-dir) nil t)

(defconst drgnx-orders-test--names '(a b c d))

(defun drgnx-orders-test--chains (&rest lens)
  "Sources a, b, c, d with LENS events each: (a 0), (a 1), ..."
  (cl-loop for n in lens
           for name in drgnx-orders-test--names
           collect (cons name (cl-loop for i below n collect (list name i)))))

(defun drgnx-orders-test--run-all (sources edges &rest bound)
  "Every order run over SOURCES and EDGES within BOUND (keywords), in run order, consed onto the result."
  (let ((seen nil))
    (let ((r (apply #'drgnx-test-every-order
                    :kinds (mapcar #'car sources) :sources sources :edges edges
                    :init (lambda () nil)
                    :step (lambda (state e) (list (cons e state)))
                    :check (lambda (state order)
                             (push order seen)
                             (unless (equal (reverse state) order) (format "fed %S" (reverse state))))
                    bound)))
      (cons (nreverse seen) r))))

(defun drgnx-orders-test--seq (order)
  "ORDER's events as their source numbers."
  (mapcar (lambda (e) (cl-position (car e) drgnx-orders-test--names)) order))

(defun drgnx-orders-test--key (seq)
  (mapconcat #'number-to-string seq ""))

(defun drgnx-orders-test--set (seqs)
  "SEQS as a sorted list of distinct strings."
  (sort (delete-dups (mapcar #'drgnx-orders-test--key seqs)) #'string<))

(defun drgnx-orders-test--all (lens)
  "Every sequence of source numbers with (nth S LENS) copies of S: every interleaving, edges ignored."
  (if (cl-every #'zerop lens)
      (list nil)
    (cl-loop for s below (length lens)
             when (> (nth s lens) 0)
             nconc (mapcar (lambda (rest) (cons s rest))
                           (drgnx-orders-test--all
                            (cl-loop for n in lens for u from 0 collect (if (= u s) (1- n) n)))))))

(defun drgnx-orders-test--at (seq s i)
  "Where SEQ holds the I-th event of source S."
  (let ((k 0))
    (cl-loop for x in seq for idx from 0
             when (= x s) do (if (= k i) (cl-return idx) (cl-incf k)))))

(defun drgnx-orders-test--keeps (seq edges)
  "Non-nil if SEQ keeps every edge ((S . I) . (S2 . J)), sources by number."
  (cl-every (lambda (e) (< (drgnx-orders-test--at seq (caar e) (cdar e))
                           (drgnx-orders-test--at seq (cadr e) (cddr e))))
            edges))

(defun drgnx-orders-test--delays (seq lens edges limit)
  "SEQ's delays by the definition, or nil past LIMIT: at each step the natural scheduler takes the lowest-numbered
source whose next event is enabled; taking the r-th enabled source (from 0) costs r."
  (let ((pos (make-vector (length lens) 0)) (cost 0))
    (cl-loop for s in seq
             do (let ((enabled (cl-loop for u below (length lens)
                                        when (and (< (aref pos u) (nth u lens))
                                                  (cl-every (lambda (e) (or (not (equal (cdr e) (cons u (aref pos u))))
                                                                            (> (aref pos (caar e)) (cdar e))))
                                                            edges))
                                        collect u)))
                  (cl-incf cost (cl-position s enabled))
                  (cl-incf (aref pos s)))
             until (> cost limit))
    (and (<= cost limit) cost)))

(defun drgnx-orders-test--binomial (n k)
  (let ((r 1))
    (dotimes (i k) (setq r (/ (* r (- n i)) (1+ i))))
    r))

(defun drgnx-orders-test--failure (thunk)
  "The plist THUNK's `ert-fail' carries."
  (let ((data (cdr (should-error (funcall thunk) :type 'ert-test-failed))))
    (if (keywordp (car data)) data (car data))))

(ert-deftest drgnx-test-every-order/counts-match-the-closed-form ()
  (should (= 12870 (drgnx-test-every-order-count :sources (drgnx-orders-test--chains 8 8))))
  (should (= 1680 (drgnx-test-every-order-count :sources (drgnx-orders-test--chains 3 3 3))))
  (should (= 1 (drgnx-test-every-order-count :sources (drgnx-orders-test--chains 8 8) :edges '(((a . 7) . (b . 0))))))
  ;; 16! / 4!^4
  (should (= 63063000 (drgnx-test-every-order-count :sources (drgnx-orders-test--chains 4 4 4 4))))
  (dotimes (a 7)
    (dotimes (b 7)
      (should (= (drgnx-orders-test--binomial (+ a b) a)
                 (drgnx-test-every-order-count :sources (drgnx-orders-test--chains a b))))))
  ;; the cap: exact below it, the cap itself above it
  (should (= 12870 (drgnx-test-every-order-count :sources (drgnx-orders-test--chains 8 8) :cap 20001)))
  (should (= 48620 (drgnx-test-every-order-count :sources (drgnx-orders-test--chains 9 9))))
  (should (= 20001 (drgnx-test-every-order-count :sources (drgnx-orders-test--chains 9 9) :cap 20001)))
  ;; an edge by source number, against the brute force
  (let ((edges '(((0 . 1) . (1 . 2)))))
    (should (= (cl-count-if (lambda (s) (drgnx-orders-test--keeps s edges)) (drgnx-orders-test--all '(4 4)))
               (drgnx-test-every-order-count :sources (drgnx-orders-test--chains 4 4) :edges edges)))))

(ert-deftest drgnx-test-every-order/exhaustive-visits-each-order-once ()
  (pcase-let ((`(,seen . ,r) (drgnx-orders-test--run-all (drgnx-orders-test--chains 4 4) nil)))
    (should (eq 'exhaustive (plist-get r :mode)))
    (should (= 70 (plist-get r :orders)))
    (should (= 70 (length seen)))
    (should (equal (drgnx-orders-test--set (mapcar #'drgnx-orders-test--seq seen))
                   (drgnx-orders-test--set (drgnx-orders-test--all '(4 4)))))
    (should (equal (drgnx-orders-test--seq (car seen)) '(0 0 0 0 1 1 1 1))))
  ;; with edges (by name in the run, by number in the brute force): exactly the interleavings that keep them
  (let ((want (drgnx-orders-test--set
               (cl-remove-if-not (lambda (s) (drgnx-orders-test--keeps s '(((0 . 1) . (1 . 2)) ((1 . 0) . (0 . 3)))))
                                 (drgnx-orders-test--all '(4 4))))))
    (pcase-let ((`(,seen . ,r) (drgnx-orders-test--run-all (drgnx-orders-test--chains 4 4)
                                                           '(((a . 1) . (b . 2)) ((b . 0) . (a . 3))))))
      (should (= (length want) (plist-get r :orders) (length seen)))
      (should (equal want (drgnx-orders-test--set (mapcar #'drgnx-orders-test--seq seen)))))))

(ert-deftest drgnx-test-every-order/above-the-bound-is-delay-bounded ()
  ;; 2x9: 48,620 orders, so two delays: 1 + 9 + C(10,2) = 55 orders
  (let ((all (drgnx-orders-test--all '(9 9))))
    (should (= 48620 (length all)))
    (let ((want (drgnx-orders-test--set
                 (cl-remove-if-not (lambda (s) (drgnx-orders-test--delays s '(9 9) nil 2)) all))))
      (should (= 55 (length want)))
      (pcase-let ((`(,seen . ,r) (drgnx-orders-test--run-all (drgnx-orders-test--chains 9 9) nil)))
        (should (equal '(delay-bounded 2) (plist-get r :mode)))
        (should (= 55 (plist-get r :orders)))
        (should (= 55 (length seen)))
        (should (equal (drgnx-orders-test--seq (car seen)) (append (make-list 9 0) (make-list 9 1))))
        (should (equal want (drgnx-orders-test--set (mapcar #'drgnx-orders-test--seq seen)))))))
  ;; three sources: one step may spend both delays on the third
  (let ((want (drgnx-orders-test--set
               (cl-remove-if-not (lambda (s) (drgnx-orders-test--delays s '(2 2 2) nil 2))
                                 (drgnx-orders-test--all '(2 2 2))))))
    (pcase-let ((`(,seen . ,r) (drgnx-orders-test--run-all (drgnx-orders-test--chains 2 2 2) nil :exhaustive-max 10)))
      (should (equal '(delay-bounded 2) (plist-get r :mode)))
      (should (= (length want) (plist-get r :orders) (length seen)))
      (should (equal want (drgnx-orders-test--set (mapcar #'drgnx-orders-test--seq seen))))))
  ;; with edges a delay counts against the enabled sources only, and a lower bound is honoured
  (let* ((edges '(((1 . 0) . (0 . 2)) ((0 . 4) . (1 . 3))))
         (want (drgnx-orders-test--set
                (cl-remove-if-not (lambda (s) (and (drgnx-orders-test--keeps s edges)
                                                   (drgnx-orders-test--delays s '(6 6) edges 1)))
                                  (drgnx-orders-test--all '(6 6))))))
    (pcase-let ((`(,seen . ,r) (drgnx-orders-test--run-all (drgnx-orders-test--chains 6 6) edges
                                                           :exhaustive-max 10 :delays 1)))
      (should (equal '(delay-bounded 1) (plist-get r :mode)))
      (should (= (length want) (plist-get r :orders) (length seen)))
      (should (equal want (drgnx-orders-test--set (mapcar #'drgnx-orders-test--seq seen)))))))

(defun drgnx-orders-test--recorder (raises)
  "A step that records each event and raises what RAISES maps its kind to."
  (lambda (state e) (cons (cons e state) (mapcar #'list (alist-get (car e) raises)))))

(ert-deftest drgnx-test-every-order/reentrant-events-run-first ()
  (let ((r (drgnx-test-every-order
            :kinds '(close closed next)
            :sources '((client (close) (next)))
            :init (lambda () nil)
            :step (drgnx-orders-test--recorder '((close closed)))
            :check (lambda (state order)
                     (cond ((not (equal order '((close) (next)))) "the check gets the external order")
                           ((not (equal (reverse state) '((close) (closed) (next)))) (format "%S" state)))))))
    (should (equal r '(:orders 1 :mode exhaustive :kinds-seen (close closed next)))))
  ;; depth first: a raised event's own events run before its next sibling
  (let ((runs nil))
    (drgnx-test-every-order
     :kinds '(root left left-child right next)
     :sources '((a (root)) (b (next)))
     :init (lambda () nil)
     :step (drgnx-orders-test--recorder '((root left right) (left left-child)))
     :check (lambda (state order) (push (cons order (reverse state)) runs) nil))
    (should (equal (nreverse runs)
                   '((((root) (next)) . ((root) (left) (left-child) (right) (next)))
                     (((next) (root)) . ((next) (root) (left) (left-child) (right))))))))

(ert-deftest drgnx-test-every-order/a-cycle-or-no-order-fails ()
  (cl-flet ((message-of (&rest args)
              (plist-get (drgnx-orders-test--failure
                          (lambda ()
                            (apply #'drgnx-test-every-order
                                   (append args (list :init (lambda () nil)
                                                      :step (lambda (s e) (list (cons e s)))
                                                      :check (lambda (_s _o) nil))))))
                         :message)))
    ;; contradictory edges, and an edge against its own source's order
    (should (string-match-p "the edges form a cycle"
                            (message-of :kinds '(a b) :sources (drgnx-orders-test--chains 2 2)
                                        :edges '(((a . 1) . (b . 0)) ((b . 0) . (a . 1))))))
    (should (string-match-p "the edges form a cycle"
                            (plist-get (drgnx-orders-test--failure
                                        (lambda () (drgnx-test-every-order-count
                                                    :sources (drgnx-orders-test--chains 3) :edges '(((a . 2) . (a . 0))))))
                                       :message)))
    ;; no events
    (should (string-match-p "no order to run" (message-of :kinds '(a) :sources nil)))
    (should (string-match-p "no order to run" (message-of :kinds '(a b) :sources (drgnx-orders-test--chains 0 0))))
    ;; a declared kind no order produced, and an event of an undeclared kind
    (let ((m (message-of :kinds '(data eof) :sources '((socket (data) (data))))))
      (should (string-match-p "eof" m))
      (should-not (string-match-p "data" m)))
    (should (string-match-p "is not declared" (message-of :kinds '(data) :sources '((socket (data) (oops))))))
    ;; re-entry that never ends
    (let ((failure (drgnx-orders-test--failure
                    (lambda ()
                      (drgnx-test-every-order :kinds '(a b) :sources (drgnx-orders-test--chains 1 1)
                                              :init (lambda () nil) :step (lambda (s e) (list s e))
                                              :check (lambda (_s _o) nil))))))
      (should (equal "re-entry deeper than 64" (plist-get failure :message)))
      (should (= 1 (plist-get failure :order)))
      ;; the external event and 64 raised ones were fed; the 65th raised one failed
      (should (= 65 (length (plist-get failure :fed)))))
    ;; an edge that names a missing event or source
    (should (string-match-p "source 0 (a) has 2 events"
                            (message-of :kinds '(a b) :sources (drgnx-orders-test--chains 2 2)
                                        :edges '(((a . 2) . (b . 0))))))
    (should (string-match-p "no such source"
                            (message-of :kinds '(a b) :sources (drgnx-orders-test--chains 2 2)
                                        :edges '(((z . 0) . (b . 0))))))))

(ert-deftest drgnx-test-every-order/a-found-order-is-in-the-failure ()
  (should (equal (drgnx-orders-test--failure
                  (lambda ()
                    (drgnx-test-every-order
                     :kinds '(a b) :sources '((a (a)) (b (b)))
                     :init (lambda () nil)
                     :step (lambda (state e) (list (cons e state)))
                     :check (lambda (_state order) (and (equal order '((b) (a))) "b overtook a")))))
                 '(:order 2 :of 2 :mode exhaustive :events ((b) (a)) :fed ((b) (a)) :message "b overtook a"))))

;;; orders-fixture-test.el ends here
