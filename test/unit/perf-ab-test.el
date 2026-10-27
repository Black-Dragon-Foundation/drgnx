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

(ert-deftest drgnx-perf-ab/its-own-temp-dir-is-removed-but-the-runners-is-kept ()
  (let (made)
    (drgnx-perf-ab-test--with-fake 0
      (let ((orig (symbol-function 'make-temp-file)) (process-environment (cons "DRGNX_RUN_TMP" process-environment)))
        (cl-letf (((symbol-function 'make-temp-file)
                   (lambda (prefix &rest args)
                     (let ((f (apply orig prefix args))) (when (equal prefix "drgnx-ab") (push f made)) f))))
          (with-output-to-string (drgnx-perf-ab "HEAD" :n 50))
          (should (= (length made) 1))
          (should-not (file-exists-p (car made)))
          ;; the runner's directory (DRGNX_RUN_TMP set) is its own to delete
          (should (file-directory-p dir)))))))

;;;; Glitnir: the compose probe, the P1 workloads, A/B by environment

(defun drgnx-perf-ab-test--stats (reset-log)
  "A `glitnir-stats' stand-in: its plist, and every RESET argument it got pushed on RESET-LOG."
  (lambda (&optional _frame reset)
    (push reset (car reset-log))
    '(:count 120 :compose-ms (:p50 0.4 :p95 1.1 :max 3.0) :draw-ms (:p50 0.8 :p95 1.9 :max 4.0) :painted-px 5000)))

(ert-deftest drgnx-perf/compose-probe-reads-stats ()
  (let ((log (list nil)))
    (cl-letf (((symbol-function 'glitnir-stats) (drgnx-perf-ab-test--stats log)))
      (unwind-protect
          (progn (drgnx-perf-begin)
                 (let ((r (drgnx-perf-end)))
                   (should (equal (car log) '(nil t)))   ; reset at the begin, read at the end
                   (should (eql (plist-get (plist-get (plist-get r :compose) :draw-ms) :p95) 1.9))
                   (should (eql (plist-get (plist-get r :compose) :count) 120))))
        (remove-hook 'pre-command-hook #'drgnx-perf--pre)
        (remove-hook 'post-command-hook #'drgnx-perf--post)
        (remove-hook 'post-gc-hook #'drgnx-perf--gc)))))

(ert-deftest drgnx-perf/compose-probe-absent-on-stock ()
  (should-not (fboundp 'glitnir-stats))
  (drgnx-perf-begin)
  (should-not (plist-member (drgnx-perf-end) :compose))
  (cl-letf (((symbol-function 'glitnir-stats) (lambda (&rest _) nil)))   ; inactive root: no stats
    (drgnx-perf-begin)
    (should-not (plist-member (drgnx-perf-end) :compose))))

(ert-deftest drgnx-perf/p1-workloads-defined ()
  (let* ((process-environment (cons "DRGNX_CHILDFRAME_ELPA=/nonexistent-elpa" process-environment))
         (ws (drgnx-perf-run--workloads)))
    (dolist (name '(popup-typing popup-churn scroll-under-popup scroll-full-window))
      (should (assq name ws)))
    (let ((keys (lambda (n) (cl-count-if (lambda (a) (plist-member a :keys)) (plist-get (cdr (assq n ws)) :actions)))))
      (should (>= (funcall keys 'scroll-under-popup) 100))
      (should (= (funcall keys 'scroll-full-window) 300))
      (should (= (funcall keys 'popup-churn) 200)))
    (should (>= (apply #'+ (mapcar (lambda (a) (length (plist-get a :type)))
                                   (plist-get (cdr (assq 'popup-typing ws)) :actions)))
                200)))
  ;; without the packages the popup workloads are left out (a line says so); the full-window one needs none
  (let ((process-environment (cons "DRGNX_CHILDFRAME_ELPA" process-environment)))
    (let ((ws (drgnx-perf-run--workloads)))
      (should (assq 'scroll-full-window ws))
      (dolist (name '(popup-typing popup-churn scroll-under-popup)) (should-not (assq name ws))))))

(ert-deftest drgnx-perf/ab-env-sessions-differ ()
  (drgnx-perf-ab-test--with-fake 0
    (let (starts shells)
      (cl-letf (((symbol-function 'drgnx-perf-ab--shell) (lambda (cmd) (push cmd shells) 0))
                ((symbol-function 'drgnx-perf-ab--start)
                 (lambda (tree &optional env)
                   (push (cons tree env) starts)
                   (list :name (if (member "DRGNX_PERF_GLITNIR=off" env) 'sess-a 'sess-b)))))
        (let (code)
          (with-output-to-string (setq code (drgnx-perf-ab-env "DRGNX_PERF_GLITNIR=on,off" :n 50)))
          (should (eql code 0))))
      ;; one tree: no archive; the REF side (first started) runs with the second value, the judged side with the first
      (should-not (seq-some (lambda (c) (string-match-p "archive" c)) shells))
      (should (equal (reverse starts) '((nil "DRGNX_PERF_GLITNIR=off") (nil "DRGNX_PERF_GLITNIR=on")))))))

;;;; p95 and probe verdicts

(defun drgnx-perf-ab-test--tail-rounds (shift)
  "Eight rounds whose medians agree; B's three largest samples (of 20) are SHIFT ms larger."
  (cl-loop for i below 8
           collect (let* ((a (sort (drgnx-perf-ab-test--samples (+ 5 (mod i 3)) 20) #'<)) (b (copy-sequence a)))
                     (dotimes (k 3) (cl-incf (nth (- 19 k) b) shift))
                     (list :a a :b b))))

(defun drgnx-perf-ab-test--probe-rounds (a-val b-val)
  "Eight rounds of probe plists; A's draw p95 is A-VAL (plus a little per-round noise), B's B-VAL, or no path when nil."
  (cl-loop for i below 8
           collect (list :a (list :compose (list :draw-ms (list :p95 (+ a-val (* 0.1 (mod i 3))))))
                         :b (if b-val (list :compose (list :draw-ms (list :p95 (+ b-val (* 0.1 (mod i 4))))))
                              (list :compose (list :compose-ms (list :p95 1.0)))))))

(ert-deftest drgnx-perf/bootstrap-p95-sees-a-tail-shift ()
  (let* ((rounds (drgnx-perf-ab-test--tail-rounds 3.0))
         (a (apply #'append (mapcar (lambda (r) (plist-get r :a)) rounds)))
         (b (apply #'append (mapcar (lambda (r) (plist-get r :b)) rounds))))
    (should (eq (plist-get (drgnx-perf-ab-verdict a b rounds) :verdict) 'no-regression))
    (let ((v (drgnx-perf-ab-verdict a b rounds :stat 'p95 :threshold 1.0)))
      (should (eq (plist-get v :verdict) 'regressed))
      (should (= (plist-get v :threshold) 1.0))
      (should (> (plist-get v :diff) 2.0)))))

(ert-deftest drgnx-perf/bootstrap-p95-seeded ()
  (let ((rounds (drgnx-perf-ab-test--tail-rounds 3.0)))
    (should (equal (drgnx-perf-bootstrap-rounds rounds :stat 'p95) (drgnx-perf-bootstrap-rounds rounds :stat 'p95)))
    (should (equal (drgnx-perf-bootstrap-rounds rounds :stat 'median) (drgnx-perf-bootstrap-rounds rounds)))))

(ert-deftest drgnx-perf/ab-verdict-improved ()
  (let* ((rounds (cl-loop for i below 8
                          collect (list :a (drgnx-perf-ab-test--samples (+ 10 (mod i 2)) 20) :b (drgnx-perf-ab-test--samples (+ 6 (mod i 2)) 20))))
         (a (apply #'append (mapcar (lambda (r) (plist-get r :a)) rounds)))
         (b (apply #'append (mapcar (lambda (r) (plist-get r :b)) rounds))))
    (should (eq (plist-get (drgnx-perf-ab-verdict a b rounds) :verdict) 'improved))
    (should (eq (plist-get (drgnx-perf-ab-verdict a b rounds :stat 'p95) :verdict) 'improved))))

(ert-deftest drgnx-perf/probe-verdict-per-round ()
  (let ((v (drgnx-perf-ab-probe-verdict (drgnx-perf-ab-test--probe-rounds 2.0 5.0) '(:compose :draw-ms :p95))))
    (should (eq (plist-get v :verdict) 'regressed))
    (should (> (plist-get v :diff) 2.5))
    (should (= (plist-get v :threshold) 1.0)))
  (should (eq (plist-get (drgnx-perf-ab-probe-verdict (drgnx-perf-ab-test--probe-rounds 2.0 2.0) '(:compose :draw-ms :p95))
                         :verdict)
              'no-regression))
  (should (eq (plist-get (drgnx-perf-ab-probe-verdict (drgnx-perf-ab-test--probe-rounds 6.0 2.0) '(:compose :draw-ms :p95))
                         :verdict)
              'improved))
  ;; T is 10% of A's median once that is above 1 ms: ~2 ms at 20 ms, so a 1.5-ms shift is within it
  (should (eq (plist-get (drgnx-perf-ab-probe-verdict (drgnx-perf-ab-test--probe-rounds 20.0 21.5) '(:compose :draw-ms :p95))
                         :verdict)
              'no-regression)))

(ert-deftest drgnx-perf/probe-verdict-not-comparable ()
  (let ((v (drgnx-perf-ab-probe-verdict (drgnx-perf-ab-test--probe-rounds 2.0 nil) '(:compose :draw-ms :p95))))
    (should (eq (plist-get v :verdict) 'not-comparable))))

(ert-deftest drgnx-perf/ab-env-judges-compose-budgets ()
  (cl-flet ((go (count p95)
              (drgnx-perf-ab-test--with-fake 0
                (cl-letf (((symbol-function 'drgnx-perf-ab--start)
                           (lambda (_tree &optional env) (list :name (if (member "DRGNX_PERF_GLITNIR=on" env) 'sess-b 'sess-a))))
                          ((symbol-function 'drgnx-perf-run--budgets)
                           (lambda () '((typing (:input :p95) 16) (typing (:compose :compose-ms :p95) 2))))
                          ((symbol-function 'drgnx-perf-ab--one)
                           (lambda (sess _spec)
                             (list :samples (drgnx-perf-ab-test--samples 5 25)
                                   :run (list :alloc (list :p50 100) :cpu_ms (list :p90 1.0) :rows 1
                                              :compose (list :count count :compose-ms (list :p95 (if (eq sess 'sess-b) p95 1.0))
                                                             :draw-ms (list :p95 1.0)))))))
                  (let (code out)
                    (setq out (with-output-to-string (setq code (drgnx-perf-ab-env "DRGNX_PERF_GLITNIR=on,off" :n 50))))
                    (cons code out))))))
    ;; 8+ rounds x 20 frames >= 100: the judged side's 3.5 ms breaks the 2 ms row
    (let ((r (go 20 3.5)))
      (should (eql (car r) 1))
      (should (string-match-p "FAIL typing compose compose-ms p95" (cdr r)))
      (should (string-match-p "p95 no-regression" (cdr r)))
      (should (string-match-p "probe .*draw-ms p95 no-regression" (cdr r))))
    ;; under 100 frames the row is not judged
    (should (eql (car (go 5 3.5)) 0))
    ;; within the row
    (should (eql (car (go 20 1.5)) 0))))

(ert-deftest drgnx-perf/ab-env-needs-two-values ()
  (dolist (bad '("DRGNX_PERF_GLITNIR=on" "DRGNX_PERF_GLITNIR=on," "=on,off" "DRGNX_PERF_GLITNIR" "DRGNX_PERF_GLITNIR=on,off,x"))
    (should-error (drgnx-perf-ab-env-parse bad)))
  (should (equal (drgnx-perf-ab-env-parse "DRGNX_PERF_GLITNIR=on,off") '("DRGNX_PERF_GLITNIR" "on" "off")))
  ;; the command line: usage, exit 2, before anything starts
  (let* ((process-environment (append '("CI=true") process-environment))
         (out (with-temp-buffer
                (cons (call-process (expand-file-name "bin/drgnx" drgnx-ui-repo-dir) nil t nil "test" "--perf" "--ab-env" "DRGNX_PERF_GLITNIR=on")
                      (buffer-string)))))
    (should (eql (car out) 2))
    (should (string-match-p "usage: drgnx test --perf --ab-env VAR=JUDGED,REF" (cdr out)))))

;;;; The A/A first, the phase-sum check, the explain block, timer ms

(defun drgnx-perf-ab-test--run (phases busy-sum &optional timer-p95)
  "A run whose worker phases are PHASES (a plist of ms) and whose main thread was busy BUSY-SUM ms in all."
  (append (list :alloc (list :p50 100) :cpu_ms (list :p90 1.0) :rows 1
                :input (list :p50 5.0 :p95 8.0) :busy-ms (list :p50 5.0 :p95 8.0 :sum busy-sum)
                :workers (list :phase-ms phases))
          (and timer-p95 (list :timer-ms (list :p95 timer-p95)))))

(defmacro drgnx-perf-ab-test--ab-env (run &rest body)
  "Run BODY with `drgnx-perf-ab--one' returning RUN (a form, evaluated per call) and the sessions told apart by
`calls' (the sessions it ran, newest first); side b is the one with DRGNX_PERF_GLITNIR=on."
  (declare (indent 1))
  `(let (calls)
     (drgnx-perf-ab-test--with-fake 0
       (cl-letf (((symbol-function 'drgnx-perf-ab--start)
                  (lambda (_tree &optional env) (list :name (if (member "DRGNX_PERF_GLITNIR=on" env) 'sess-b 'sess-a))))
                 ((symbol-function 'drgnx-perf-ab--one)
                  (lambda (sess _spec)
                    (push sess calls)
                    (list :samples (drgnx-perf-ab-test--samples 5 25) :run ,run))))
         ,@body))))

(ert-deftest drgnx-perf-ab/aa-blocks-on-mismatch ()
  ;; phases of 50 ms in a main thread that was busy 10 ms: the lab is wrong, not the change
  (drgnx-perf-ab-test--ab-env (drgnx-perf-ab-test--run (list 'json 50.0) 10.0)
    (let (code out)
      (setq out (with-output-to-string (setq code (drgnx-perf-ab-env "DRGNX_PERF_GLITNIR=on,off" :n 50))))
      (should (eql code 4))
      (should (string-match-p "A/A failed" out))
      (should (string-match-p "phase-sum" out))
      (should calls)
      (should-not (memq 'sess-b calls)))        ; no A/B round
    ;; --no-aa skips the A/A: the A/B runs, and prints the check
    (setq calls nil)
    (let (code out)
      (setq out (with-output-to-string (setq code (drgnx-perf-ab-env "DRGNX_PERF_GLITNIR=on,off" :n 50 :aa nil))))
      (should (memq 'sess-b calls))
      (should-not (eql code 4))
      (should (string-match-p "phase-sum MISMATCH" out))))
  ;; a regressed verdict and a digest that differs block as well
  (should (string-match-p "regressed" (car (drgnx-perf-ab-test--aa-problems '(("p95" . regressed)) nil))))
  (should (equal (drgnx-perf-ab-test--aa-problems nil nil 'regressed) '("digest differs"))))

(defun drgnx-perf-ab-test--aa-problems (forward reverse &optional digest)
  "`drgnx-perf-ab-aa-problems' with the deciding verdicts FORWARD and REVERSE (alists LABEL -> verdict) and the
digest verdict DIGEST (default no-regression); the entry carries a clean phase-sum."
  (let ((calls 0))
    (cl-letf (((symbol-function 'drgnx-perf-ab--deciding)
               (lambda (&rest _) (prog1 (if (= calls 0) forward reverse) (cl-incf calls))))
              ((symbol-function 'drgnx-perf-ab-digest-verdict)
               (lambda (_) (list :verdict (or digest 'no-regression)))))
      (drgnx-perf-ab-aa-problems (list :wall-rounds nil :run-rounds nil :phase-sum nil)))))

(ert-deftest drgnx-perf-ab/aa-inconclusive-does-not-block ()
  (should-not (drgnx-perf-ab-test--aa-problems '(("median" . no-regression) ("p95" . inconclusive))
                                               '(("median" . no-regression) ("max" . inconclusive))))
  ;; it is printed, as a line of its own
  (cl-letf (((symbol-function 'drgnx-perf-ab--deciding)
             (lambda (&rest _) '(("median" . no-regression) ("p95" . inconclusive))))
            ((symbol-function 'drgnx-perf-ab-digest-verdict) (lambda (_) (list :verdict 'no-regression))))
    (should (equal (drgnx-perf-ab-aa-notes (list :wall-rounds nil :run-rounds nil))
                   '("A/A: p95 inconclusive (forward)" "A/A: p95 inconclusive (reverse)")))))

(ert-deftest drgnx-perf-ab/aa-regressed-blocks ()
  (let ((p (drgnx-perf-ab-test--aa-problems '(("median" . no-regression) ("p95" . regressed))
                                            '(("median" . no-regression)))))
    (should (= (length p) 1))
    (should (string-match-p "p95 regressed (forward)" (car p))))
  (should (string-match-p "median regressed (reverse)"
                          (car (drgnx-perf-ab-test--aa-problems '(("median" . improved))
                                                                '(("median" . regressed)))))))

(ert-deftest drgnx-perf-ab/cross-arm-phase-sum-explains-only ()
  ;; busy fell 121.5 ms, the phases' sum rose 141.4 ms: not comparable run sums, so no mismatch ...
  (let ((a (drgnx-perf-ab-test--run (list 'json 60.0) 200.0)) (b (drgnx-perf-ab-test--run (list 'json 201.4) 78.5)))
    (should-not (drgnx-perf-ab-phase-sum (drgnx-perf-ab-test--run (list 'json 40.0) 200.0)
                                         (drgnx-perf-ab-test--run (list 'json 100.0) 300.0)))
    (should (drgnx-perf-ab-phase-sum a b))      ; per arm: B has 201.4 phases in 78.5 busy
    (let ((ok-b (drgnx-perf-ab-test--run (list 'json 100.0) 300.0))
          (ok-a (drgnx-perf-ab-test--run (list 'json 60.0) 200.0)))
      (should-not (drgnx-perf-ab-phase-sum ok-a ok-b))
      (should (string-match-p "busy changed by 100.0 ms, the phases' sum by 40.0 ms"
                              (drgnx-perf-ab-phase-delta-line ok-a ok-b))))
    (should-not (drgnx-perf-ab-phase-delta-line '(:workers nil) '(:workers nil))))
  ;; ... and an A/A with such a pair passes (the phase-sum entry is nil)
  (drgnx-perf-ab-test--ab-env (drgnx-perf-ab-test--run (list 'json 40.0) 100.0)
    (let (out)
      (setq out (with-output-to-string (drgnx-perf-ab-env "DRGNX_PERF_GLITNIR=on,off" :n 50)))
      (should (string-match-p "busy changed by" out)))))

(ert-deftest drgnx-perf-ab/aa-passes-then-ab ()
  (drgnx-perf-ab-test--ab-env (drgnx-perf-ab-test--run (list 'json 40.0 'worker-wait 3.0 'worker-wait-drain 3.0) 100.0)
    (let (code out)
      (setq out (with-output-to-string (setq code (drgnx-perf-ab-env "DRGNX_PERF_GLITNIR=on,off" :n 50))))
      (should (eql code 0))
      (should (string-match-p "A/A (typing): passed" out))
      (should (string-match-p "phase-sum ok" out))
      ;; the A/A ran first, on the REF side's session alone, then the A/B on both
      (let ((order (reverse calls)))
        (should (eq (car order) 'sess-a))
        ;; a warm-up and the minimum of rounds on sess-a alone, before the first call on sess-b
        (should (>= (cl-position 'sess-b order) (+ 1 (* 2 drgnx-perf-ab-min-rounds))))))))

(defmacro drgnx-perf-ab-test--three-workloads (&rest body)
  "BODY with three workloads selected and `drgnx-perf-ab--workload' counting its calls in `wcalls' ((NAME SA SB)…,
newest first), returning a judged entry that carries the A/A fields."
  (declare (indent 0))
  `(let (wcalls)
     (drgnx-perf-ab-test--with-fake 0
       (cl-letf (((symbol-function 'drgnx-perf-run--workloads)
                  (lambda () '((w1 :measure "m") (w2 :measure "m") (w3 :measure "m"))))
                 ((symbol-function 'drgnx-perf-ab--start)
                  (lambda (_tree &optional env) (list :name (if (member "DRGNX_PERF_GLITNIR=on" env) 'sess-b 'sess-a))))
                 ((symbol-function 'drgnx-perf-ab--workload)
                  (lambda (name _spec sa sb _n)
                    (push (list name sa sb) wcalls)
                    (list :name name :status 'judged :wall-rounds nil :run-rounds nil
                          :verdict (list :verdict 'no-regression :diff 0.0 :lo 0.0 :hi 0.0 :threshold 1.0)
                          :a (list :n 1) :b (list :n 1))))
                 ((symbol-function 'drgnx-perf-ab--deciding) (lambda (&rest _) nil))
                 ((symbol-function 'drgnx-perf-ab-digest-verdict) (lambda (_) (list :verdict 'no-regression))))
         ,@body))))

(ert-deftest drgnx-perf-ab/aa-runs-once-per-invocation ()
  (drgnx-perf-ab-test--three-workloads
    (let (code out)
      (setq out (with-output-to-string (setq code (drgnx-perf-ab-env "DRGNX_PERF_GLITNIR=on,off" :n 50))))
      (should (eql code 0))
      ;; one call with session S on both sides (the A/A), then one A/B per workload
      (let ((aa (seq-filter (lambda (c) (eq (nth 1 c) (nth 2 c))) wcalls)))
        (should (= (length aa) 1))
        (should (eq (car (car aa)) 'w1)))
      (should (= (length wcalls) 4))
      (should (string-match-p "A/A (w1): passed" out))
      (should (= 1 (with-temp-buffer (insert out) (how-many "A/A (" (point-min) (point-max)))))))
  ;; --no-aa: no such call
  (drgnx-perf-ab-test--three-workloads
    (with-output-to-string (drgnx-perf-ab-env "DRGNX_PERF_GLITNIR=on,off" :n 50 :aa nil))
    (should (= (length wcalls) 3))
    (should-not (seq-some (lambda (c) (eq (nth 1 c) (nth 2 c))) wcalls))))

(ert-deftest drgnx-perf-ab/aa-failure-refuses-every-workload ()
  (drgnx-perf-ab-test--three-workloads
    (cl-letf (((symbol-function 'drgnx-perf-ab-aa-problems) (lambda (&rest _) '("p95 regressed (forward)"))))
      (let (code out)
        (setq out (with-output-to-string (setq code (drgnx-perf-ab-env "DRGNX_PERF_GLITNIR=on,off" :n 50))))
        (should (eql code 4))
        (should (= (length wcalls) 1))            ; the A/A only: no A/B for any workload
        (should (string-match-p "^w1 +A/A failed: p95 regressed (forward)" out))))))

(ert-deftest drgnx-perf-ab/phase-sum-checks-arms-and-the-difference ()
  (let ((run (lambda (ph busy) (drgnx-perf-ab-test--run ph busy))))
    (should-not (drgnx-perf-ab-phase-sum (funcall run (list 'json 40.0) 100.0) (funcall run (list 'json 40.0) 100.0)))
    ;; within 1 ms of the busy time is fine, more is not
    (should-not (drgnx-perf-ab-phase-sum (funcall run (list 'json 100.9) 100.0) nil))
    (should (drgnx-perf-ab-phase-sum (funcall run (list 'json 101.5) 100.0) nil))
    ;; the by-reason entries repeat worker-wait: not summed twice
    (should-not (drgnx-perf-ab-phase-sum (funcall run (list 'worker-wait 30.0 'worker-wait-display 30.0) 40.0) nil))
    ;; across arms nothing is judged here (see `cross-arm-phase-sum-explains-only')
    (should-not (drgnx-perf-ab-phase-sum (funcall run (list 'json 60.0) 200.0) (funcall run (list 'json 50.0) 150.0)))
    (let ((m (drgnx-perf-ab-phase-sum (funcall run (list 'json 60.0) 200.0) (funcall run (list 'json 160.0) 150.0))))
      (should (eq (car m) :phase-sum-mismatch))
      (should (string-match-p "arm B: phases 160.0" (plist-get (cdr m) :why))))
    ;; no phases (stock Emacs) or no busy time: nothing to check
    (should-not (drgnx-perf-ab-phase-sum '(:workers nil) '(:workers nil)))))

(ert-deftest drgnx-perf-ab/phases-explain-not-decide ()
  ;; a phase rises 10 -> 30 ms while busy and input stay equal: not worse, and the phase shows in the explain block
  (let* ((rounds (cl-loop for i below 10
                          collect (list :a (drgnx-perf-ab-test--run (list 'treesit-wait (+ 10.0 (* 0.1 (% i 3)))) 100.0)
                                        :b (drgnx-perf-ab-test--run (list 'treesit-wait (+ 30.0 (* 0.1 (% i 3)))) 100.0))))
         (vs (drgnx-perf-ab-metric-verdicts rounds)))
    (should vs)
    (dolist (v vs)
      (should (memq (plist-get (cdr v) :verdict) '(no-regression improved)))
      (should-not (eq (nth 1 (car v)) :phase-ms)))
    (let ((text (drgnx-perf-ab--extra-lines (list :metric-verdicts vs :a-run (plist-get (car rounds) :a)
                                                  :b-run (plist-get (car rounds) :b)))))
      (should (string-match-p "explain" text))
      (should (string-match-p "treesit-wait 10.0 / 30.0" text))
      (should (string-match-p "busy-ms p50 no-regression" text)))))

(ert-deftest drgnx-perf-ab/timer-ms-decides ()
  (let* ((rounds (cl-loop for i below 10
                          collect (list :a (drgnx-perf-ab-test--run nil 100.0 (+ 2.0 (* 0.1 (% i 3))))
                                        :b (drgnx-perf-ab-test--run nil 100.0 (+ 9.0 (* 0.1 (% i 3)))))))
         (vs (drgnx-perf-ab-metric-verdicts rounds)))
    (should (eq (plist-get (cdr (assoc '(:timer-ms :p95) vs)) :verdict) 'regressed))
    (should (eq (plist-get (cdr (assoc '(:busy-ms :p95) vs)) :verdict) 'no-regression))
    (should (eq (plist-get (cdr (assoc '(:input :p50) vs)) :verdict) 'no-regression))))

(ert-deftest drgnx-perf/timer-ms-and-busy-per-command ()
  (let ((drgnx-perf--timers-on t) (drgnx-perf--timer-cur nil) (drgnx-perf--timer-after 0.0) (drgnx-perf--cmd-lat nil)
        (drgnx-perf--timer-ms nil) (drgnx-perf--busy-ms nil))
    ;; a command: 2 ms of timers before the screen shows it (inside its latency), 3 ms after (added to its busy time)
    (setq drgnx-perf--timer-cur 0.0)
    (drgnx-perf--timer-note 2.0)
    (setq drgnx-perf--cmd-lat 10.0)
    (drgnx-perf--timer-note 3.0)
    (drgnx-perf--busy-flush)
    (should (equal drgnx-perf--timer-ms '(5.0)))
    (should (equal drgnx-perf--busy-ms '(13.0)))
    ;; before any command, and with the recording off, nothing is kept
    (setq drgnx-perf--timer-cur nil)
    (drgnx-perf--timer-note 9.0)
    (should-not drgnx-perf--timer-cur)))

(ert-deftest drgnx-perf-ab/results-keep-a-digest-and-blank-count-per-round ()
  ;; the medians keep one run's digest; a differing round must stay visible in the results file
  (let* ((rounds (list (list :a (list :digest "d1" :live (list :blank 0)) :b (list :digest "d1" :live (list :blank 0)))
                       (list :a (list :digest "d1" :live (list :blank 0)) :b (list :digest "d2" :live (list :blank 3)))
                       (list :a (list :digest "d1") :b (list :digest "d1" :live (list :blank 0)))))
         (e (list :name 'live-view :status 'judged :run-rounds rounds))
         (file (make-temp-file "drgnx-perf-ab" nil ".json")))
    (unwind-protect
        (progn
          (drgnx-perf-run--write-results file (list (drgnx-perf-ab--result-entry e)))
          (let* ((j (json-parse-string (with-temp-buffer (insert-file-contents file) (buffer-string))
                                       :object-type 'plist :null-object nil))
                 (r (plist-get (plist-get j :results) :live-view)))
            (should (equal (plist-get (plist-get r :digests) :a) ["d1" "d1" "d1"]))
            (should (equal (plist-get (plist-get r :digests) :b) ["d1" "d2" "d1"]))
            (should (equal (plist-get (plist-get r :blanks) :a) [0 0 nil]))
            (should (equal (plist-get (plist-get r :blanks) :b) [0 3 0]))))
      (delete-file file))))

(ert-deftest drgnx-perf-ab/a-workload-without-a-digest-still-has-one-entry-per-round ()
  (let* ((rounds (list (list :a (list :rows 1) :b (list :rows 1)) (list :a (list :rows 1) :b (list :rows 1))))
         (file (make-temp-file "drgnx-perf-ab" nil ".json")))
    (unwind-protect
        (progn
          (drgnx-perf-run--write-results file (list (drgnx-perf-ab--result-entry (list :name 'w :status 'judged :run-rounds rounds))))
          (let ((r (plist-get (plist-get (json-parse-string (with-temp-buffer (insert-file-contents file) (buffer-string))
                                                            :object-type 'plist :null-object nil)
                                         :results)
                              :w)))
            (should (equal (plist-get (plist-get r :digests) :a) [nil nil]))))
      (delete-file file))))
