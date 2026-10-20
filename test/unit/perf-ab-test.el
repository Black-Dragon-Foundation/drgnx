;;; perf-ab-test.el --- batch tests: the paired A/B perf run (bootstrap, verdict, rounds, the REF archive) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-perf-run)

(cl-defun drgnx-perf-ab-test--samples (base n &optional (spread 0.4))
  "N samples around BASE ms, a fixed pattern (no randomness in a test)."
  (cl-loop for i below n collect (+ base (* spread (- (mod (* i 7) 5) 2)))))

(ert-deftest drgnx-perf-ab/bootstrap-is-seeded-and-repeatable ()
  (let ((a (drgnx-perf-ab-test--samples 10 30)) (b (drgnx-perf-ab-test--samples 11 30)))
    (should (equal (drgnx-perf-bootstrap-diff a b) (drgnx-perf-bootstrap-diff a b)))
    (should-not (equal (drgnx-perf-bootstrap-diff a b :seed 1) (drgnx-perf-bootstrap-diff a b :seed 2)))
    ;; never the global generator
    (random "fixed")
    (let ((next (random 1000000)))
      (random "fixed")
      (drgnx-perf-bootstrap-diff a b :iterations 50)
      (should (= next (random 1000000))))))

(ert-deftest drgnx-perf-ab/a-shift-of-5-ms-is-regressed ()
  (let ((v (drgnx-perf-ab-verdict (drgnx-perf-ab-test--samples 10 40) (drgnx-perf-ab-test--samples 15 40))))
    (should (eq (plist-get v :verdict) 'regressed))
    (should (> (plist-get v :lo) 4))
    (should (= (plist-get v :threshold) 1.0))))

(ert-deftest drgnx-perf-ab/the-same-samples-are-no-regression ()
  (let* ((s (drgnx-perf-ab-test--samples 10 40)) (v (drgnx-perf-ab-verdict s s)))
    (should (eq (plist-get v :verdict) 'no-regression))
    (should (and (<= (plist-get v :lo) 0) (>= (plist-get v :hi) 0)))))

(ert-deftest drgnx-perf-ab/a-wide-interval-is-inconclusive ()
  (let ((v (drgnx-perf-ab-verdict '(1 30 2 29 3 28 4 27 5 26) '(2 31 3 30 4 29 5 28 6 27))))
    (should (eq (plist-get v :verdict) 'inconclusive))))

(ert-deftest drgnx-perf-ab/rounds-run-until-n-and-the-minimum-of-rounds ()
  (let (order)
    (let ((r (drgnx-perf-ab-rounds 10 (lambda (side) (push side order) (list 1.0 2.0 3.0 4.0)))))
      (should (= (length (plist-get r :rounds)) drgnx-perf-ab-min-rounds))
      (should (= (length order) (* 2 drgnx-perf-ab-min-rounds)))
      (should (= (length (plist-get r :a)) (* 4 drgnx-perf-ab-min-rounds))))
    ;; more samples than the minimum of rounds gives: it goes on until each side has N
    (let ((r (drgnx-perf-ab-rounds 100 (lambda (_side) (list 1.0 2.0 3.0 4.0)))))
      (should (= (length (plist-get r :rounds)) 26))))) ; 25 would be odd: ABBA needs pairs

(ert-deftest drgnx-perf-ab/the-ref-tree-is-an-archive-not-a-worktree ()
  (let (cmds (dest (make-temp-file "drgnx-ab" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-perf-ab--shell) (lambda (cmd) (push cmd cmds) 0)))
          (drgnx-perf-ab--export "v1.2" dest)
          (should (= (length cmds) 1))
          (should (string-match-p "git .*archive v1.2 | tar -x" (car cmds)))
          (should-not (string-match-p "git worktree\\| worktree add" (car cmds))))
      (delete-directory dest t))))

(defvar drgnx-perf-ab-test--loaded nil)

(defmacro drgnx-perf-ab-test--with-fake (shift &rest body)
  "Run BODY with the sessions, git and builds stubbed; side b is SHIFT ms slower than a."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "drgnx-perf-ab" t)) (process-environment (cons (concat "DRGNX_RUN_TMP=" dir) process-environment)))
     (unwind-protect
         (cl-letf (((symbol-function 'drgnx-perf-ab--shell) (lambda (_) 0))
                   ((symbol-function 'drgnx-perf-ab--start) (lambda (tree) (list :name (if tree 'sess-a 'sess-b))))
                   ((symbol-function 'drgnx-ui-stop) #'ignore)
                   ((symbol-function 'drgnx-ui-own-session) #'identity)
                   ((symbol-function 'drgnx-perf-run--make-fixture) (lambda () (make-temp-file "drgnx-perf-fixture")))
                   ((symbol-function 'drgnx-perf-run--workloads)
                    (lambda () '((typing :setup "s" :actions ((:type "a"))) (frames :measure "m"))))
                   ((symbol-function 'drgnx-perf-run--budgets) (lambda () '((typing (:input :p95) 16))))
                   ((symbol-function 'drgnx-perf-run--call)
                    (lambda (_s form &rest _)
                      (if (string-match-p "calibrate" form) (list :wall_ms 10.0 :cpu_ms 5.0 :loaded drgnx-perf-ab-test--loaded) t)))
                   ((symbol-function 'drgnx-perf-ab--one)
                    (lambda (sess _spec)
                      (list :samples (drgnx-perf-ab-test--samples (if (eq sess 'sess-a) 5 (+ 5 ,shift)) 25)
                            :run (list :alloc (list :p50 100) :cpu_ms (list :p90 1.0) :rows 1)))))
           ,@body)
       (delete-directory dir t))))

(ert-deftest drgnx-perf-ab/the-same-tree-is-judged-clean-and-frames-are-not-comparable ()
  (drgnx-perf-ab-test--with-fake 0
    (let (code out)
      (setq out (with-output-to-string (setq code (drgnx-perf-ab "HEAD" :n 50))))
      (should (eql code 0))
      (should (string-match-p "typing .*no-regression" out))
      (should (string-match-p "frames .*not comparable" out)))))

(ert-deftest drgnx-perf-ab/a-slower-work-tree-exits-1 ()
  (drgnx-perf-ab-test--with-fake 5
    (let (code out)
      (setq out (with-output-to-string (setq code (drgnx-perf-ab "HEAD" :n 50))))
      (should (eql code 1))
      (should (string-match-p "typing .*regressed" out)))))

(ert-deftest drgnx-perf-ab/a-loaded-calibration-is-not-judged ()
  (drgnx-perf-ab-test--with-fake 5
    (let ((drgnx-perf-ab-test--loaded t) code out)
      (setq out (with-output-to-string (setq code (drgnx-perf-ab "HEAD" :n 50))))
      (should (eql code 3))
      (should (string-match-p "not judged: .*calibration" out)))))

(defun drgnx-perf-ab-test--run-effect-rounds ()
  "Four rounds, no real difference between the sides, but each run has its own offset: A's slow run is round 4,
B's is round 1 (+/-4 ms)."
  (cl-loop for off-a in '(0 0 0 4) for off-b in '(4 0 0 0)
           collect (list :a (drgnx-perf-ab-test--samples (+ 10 off-a) 25) :b (drgnx-perf-ab-test--samples (+ 10 off-b) 25))))

(ert-deftest drgnx-perf-ab/the-unit-is-the-run-not-the-sample ()
  (let* ((rounds (drgnx-perf-ab-test--run-effect-rounds))
         (a (apply #'append (mapcar (lambda (r) (plist-get r :a)) rounds)))
         (b (apply #'append (mapcar (lambda (r) (plist-get r :b)) rounds)))
         (pooled (drgnx-perf-ab-verdict a b))
         (per-round (drgnx-perf-ab-verdict a b rounds)))
    ;; 100 samples a side look like a precise answer ...
    (should (eq (plist-get pooled :verdict) 'no-regression))
    ;; ... but there are four runs a side: the interval over the rounds is wider and says so
    (should (> (- (plist-get per-round :hi) (plist-get per-round :lo))
               (* 2 (- (plist-get pooled :hi) (plist-get pooled :lo)))))
    (should (eq (plist-get per-round :verdict) 'inconclusive))))

(ert-deftest drgnx-perf-ab/rounds-alternate-the-order-abba ()
  (let (order)
    (let ((r (drgnx-perf-ab-rounds 10 (lambda (side) (push side order) (list 1.0 2.0 3.0 4.0)))))
      (should (equal (nreverse order) '(a b b a a b b a a b b a a b b a)))
      (should (equal (plist-get r :order) '(a b b a a b b a a b b a a b b a)))
      (should (cl-evenp (length (plist-get r :rounds)))))))

(ert-deftest drgnx-perf-ab/a-fixed-order-bias-is-no-regression-after-abba ()
  ;; the side that runs second in a round is 1.5 ms slower (the other's allocation, a later warm-up): same tree
  (let* ((n 0)
         (r (drgnx-perf-ab-rounds
             10 (lambda (_side)
                  (setq n (1+ n))
                  (drgnx-perf-ab-test--samples (+ 10 (if (cl-evenp n) 1.5 0)) 25))))
         (v (drgnx-perf-ab-verdict (plist-get r :a) (plist-get r :b) (plist-get r :rounds))))
    (should (eq (plist-get v :verdict) 'no-regression))))
