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

(ert-deftest drgnx-perf/present-is-the-first-after-paint-after-the-key ()
  ;; stand-ins for Glitnir's clock and last paint: the command's paint reaches the compositor 4 ms after its start
  (let ((now 1000000000) (present 999000000))
    (cl-letf (((symbol-function 'glitnir--now-ns) (lambda () now))
              ((symbol-function 'glitnir--last-paint) (lambda () (list :commit-ns 0 :paint-ns 0 :present-ns present))))
      (drgnx-perf-begin)
      (unwind-protect
          (progn (run-hooks 'pre-command-hook)
                 (run-at-time 0.01 nil (lambda () (setq present (+ now 4000000))))
                 (run-hooks 'post-command-hook)
                 (sit-for 0.2))
        (let ((r (drgnx-perf-end)))
          (should (equal (plist-get (plist-get r :present) :n) 1))
          (should (equal (plist-get (plist-get r :present) :p50) 4.0)))))))

(ert-deftest drgnx-perf/compose-probe-absent-on-stock ()
  (should-not (fboundp 'glitnir-stats))
  (drgnx-perf-begin)
  (should-not (plist-member (drgnx-perf-end) :compose))
  (should-not (plist-member (drgnx-perf-end) :present))
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

(ert-deftest drgnx-perf/ab-env-known-compose-row ()
  "A row tagged `:known' is reported above its limit and fails only above its `:fails-above' ceiling."
  (cl-flet ((go (p95)
              (drgnx-perf-ab-test--with-fake 0
                (cl-letf (((symbol-function 'drgnx-perf-ab--start)
                           (lambda (_tree &optional env) (list :name (if (member "DRGNX_PERF_GLITNIR=on" env) 'sess-b 'sess-a))))
                          ((symbol-function 'drgnx-perf-run--budgets)
                           (lambda () '((typing (:compose :compose-ms :p95) 2 :known GL-POPUP-CHURN-FULL-1 :fails-above 4.42))))
                          ((symbol-function 'drgnx-perf-ab--one)
                           (lambda (sess _spec)
                             (list :samples (drgnx-perf-ab-test--samples 5 25)
                                   :run (list :alloc (list :p50 100) :cpu_ms (list :p90 1.0) :rows 1
                                              :compose (list :count 20 :compose-ms (list :p95 (if (eq sess 'sess-b) p95 1.0))
                                                             :draw-ms (list :p95 1.0)))))))
                  (let (code out)
                    (setq out (with-output-to-string (setq code (drgnx-perf-ab-env "DRGNX_PERF_GLITNIR=on,off" :n 50))))
                    (cons code out))))))
    (let ((r (go 3.5)))
      (should (eql (car r) 0))
      (should (string-match-p "KNOWN typing compose compose-ms p95 3.5 > 2 (GL-POPUP-CHURN-FULL-1; fails above 4.42)" (cdr r)))
      (should-not (let ((case-fold-search nil)) (string-match-p "^FAIL " (cdr r)))))
    (let ((r (go 5.0)))
      (should (eql (car r) 1))
      (should (string-match-p "FAIL typing compose compose-ms p95 5.0 > 2 (GL-POPUP-CHURN-FULL-1) and > 4.42" (cdr r))))))

(ert-deftest drgnx-perf/p1-budget-rows ()
  "The Glitnir P1 rows (§9.2): compose p95 2 / max 8 and input p95 16 for the three popup workloads; the
typing and churn compose p95 rows known (GL-POPUP-CHURN-FULL-1) up to spike (i)'s 4.42 ms; no scroll-full-window gate."
  (let ((budgets (drgnx-perf-run--budgets)))
    (dolist (w '(popup-typing popup-churn scroll-under-popup))
      (dolist (row `(((:compose :compose-ms :p95) 2) ((:compose :compose-ms :max) 8) ((:input :p95) 16)))
        (let ((b (seq-find (lambda (b) (and (eq (car b) w) (equal (cadr b) (car row)))) budgets)))
          (should b)
          (should (eql (nth 2 b) (cadr row)))
          (should (equal (plist-get (nthcdr 3 b) :known)
                         (and (equal (car row) '(:compose :compose-ms :p95))
                              (if (eq w 'scroll-under-popup) 'GL-SCROLL-PAGE-COPY-1 'GL-POPUP-CHURN-FULL-1))))
          (when (plist-get (nthcdr 3 b) :known)
            (if (eq w 'scroll-under-popup)
                (progn (should (equal (plist-get (nthcdr 3 b) :fails-above-row) '(scrolling (:compose :compose-ms :p95))))
                       (should (eql (plist-get (nthcdr 3 b) :by) 1)))
              (should (eql (plist-get (nthcdr 3 b) :fails-above) 4.42)))))))
    (should-not (assq 'scroll-full-window budgets))))

(ert-deftest drgnx-perf/known-row-against-another-row ()
  "A row with `:fails-above-row (ROW PATH) :by B' is known up to ROW's value in the same A/B plus B, fails above it,
and fails when ROW was not measured in the run."
  (let ((budgets '((scroll-under-popup (:compose :compose-ms :p95) 2 :known GL-SCROLL-PAGE-COPY-1
                                       :fails-above-row (scrolling (:compose :compose-ms :p95)) :by 1)))
        (others '((scrolling . (:compose (:compose-ms (:p95 2.57)))))))
    (cl-flet ((go (v others)
                (drgnx-perf-ab--budget-fails 'scroll-under-popup '(:n 960) budgets
                                             (list :compose (list :compose-ms (list :p95 v))) 326 others)))
      (should-not (go 1.9 others))
      (should (equal (go 2.26 others)
                     '((:known "scroll-under-popup compose compose-ms p95 2.3 > 2 (GL-SCROLL-PAGE-COPY-1; fails above scrolling compose compose-ms p95 2.57 + 1)"))))
      (should (equal (go 3.8 others)
                     '("scroll-under-popup compose compose-ms p95 3.8 > 2 (GL-SCROLL-PAGE-COPY-1) and > scrolling compose compose-ms p95 2.57 + 1")))
      (should (equal (go 2.26 nil)
                     '("scroll-under-popup compose compose-ms p95 2.3 > 2 (GL-SCROLL-PAGE-COPY-1) and > scrolling compose compose-ms p95 + 1, not measured in this run"))))))

(ert-deftest drgnx-perf-ab/sessions-outlive-the-default-cap ()
  "The A/B's two sessions serve every workload: they start with DRGNX_UI_MAX_RUNTIME raised (unless it is set)."
  (let (seen)
    (drgnx-perf-ab-test--with-fake 0
      (cl-letf (((symbol-function 'drgnx-perf-ab--start)
                 (lambda (tree &optional _env) (push (getenv "DRGNX_UI_MAX_RUNTIME") seen) (list :name (if tree 'sess-a 'sess-b)))))
        (let ((process-environment (cons "DRGNX_UI_MAX_RUNTIME" process-environment)))   ; unset
          (with-output-to-string (drgnx-perf-ab "HEAD" :n 50)))
        (should (equal seen (list (number-to-string drgnx-perf-ab-session-runtime)
                                  (number-to-string drgnx-perf-ab-session-runtime))))
        (setq seen nil)
        (let ((process-environment (cons "DRGNX_UI_MAX_RUNTIME=99" process-environment)))
          (with-output-to-string (drgnx-perf-ab "HEAD" :n 50)))
        (should (equal seen '("99" "99")))))))

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
