;;; perf-test.el --- batch tests: the perf probes (statistics, recording, the hook audit, budgets, history) -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-perf)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)

(ert-deftest drgnx-perf/statistics ()
  (let ((s (drgnx-perf-stats '(5 1 4 2 3 10 6 7 9 8))))
    (should (eql (plist-get s :n) 10))
    (should (eql (plist-get s :p50) 5))
    (should (eql (plist-get s :p90) 9))
    (should-not (plist-get s :p95))                     ; fewer than 100 samples: no tail
    (should (eql (plist-get s :max) 10))
    (should (= (plist-get s :mean) 5.5)))
  (should (equal (drgnx-perf-stats nil) '(:n 0))))

(ert-deftest drgnx-perf/stats-carry-p90-and-p99 ()
  (let ((s (drgnx-perf-stats (number-sequence 1 100))))
    (should (equal (list (plist-get s :p50) (plist-get s :p90) (plist-get s :p95) (plist-get s :p99) (plist-get s :max))
                   '(50 90 95 99 100))))
  (let ((s (drgnx-perf-stats (number-sequence 1 99))))
    (should (eql (plist-get s :p90) 90))
    (should-not (plist-get s :p95))
    (should-not (plist-get s :p99))))

(ert-deftest drgnx-perf/p95-below-100-is-not-judged ()
  ;; a p95 of fewer samples is the maximum or next to it: it neither passes nor fails a budget
  (let ((r (list 'tabs :input (drgnx-perf-stats '(1 2 3 400)))))
    (should-not (drgnx-perf-verdict (list r) '((tabs (:input :p95) 16))))
    (should (drgnx-perf-verdict (list r) '((tabs (:input :p90) 16))))))   ; the p90 is judged

(defvar drgnx-perf-test--rows-a 0)
(defvar drgnx-perf-test--rows-b 0)

(defun drgnx-perf-test--command (work)
  "One simulated command: the command hooks around WORK, then the 0 s timer after its redisplay has run."
  (let ((n (length drgnx-perf--latencies)))
    (run-hooks 'pre-command-hook)
    (funcall work)
    (run-hooks 'post-command-hook)
    (drgnx-test-wait (lambda () (> (length drgnx-perf--latencies) n)) :what "the command's redisplay")))

(defun drgnx-perf-test--session (works)
  "Record the commands WORKS and return `drgnx-perf-end' (a first, unrecorded run warms the code)."
  (drgnx-perf-begin)
  (mapc #'drgnx-perf-test--command works)
  (drgnx-perf-end)
  (drgnx-perf-begin)
  (mapc #'drgnx-perf-test--command works)
  (drgnx-perf-end))

(ert-deftest drgnx-perf/per-command-alloc-cpu-and-wall ()
  ;; three commands that cons nothing, 1000 and 5000 conses; the CPU clock is stubbed to advance 1 ms per reading
  (let ((ticks 0))
    (cl-letf (((symbol-function 'current-cpu-time) (lambda () (cons (setq ticks (+ ticks 1000000)) 1000000000))))
      (let* ((r (drgnx-perf-test--session (list (lambda () nil) (lambda () (make-list 1000 nil)) (lambda () (make-list 5000 nil)))))
             (a (plist-get r :alloc)))
        (should (eql (plist-get a :n) 3))
        (should (eql (- (plist-get a :max) (plist-get a :p50)) 4000))      ; 5000 vs 1000 conses, nothing else differs
        (should (>= (- (plist-get a :p50) 1000) 0))
        (should (< (plist-get a :p50) 3000))                                ; the probe's own cost is small
        (should (equal (plist-get r :cpu_ms) (list :n 3 :p50 1.0 :p90 1.0 :p95 nil :p99 nil :max 1.0 :mean 1.0)))
        (should (eql (plist-get (plist-get r :input) :n) 3))
        (should (numberp (plist-get (plist-get r :input) :max)))))))

(ert-deftest drgnx-perf/alloc-is-the-same-in-two-runs ()
  ;; what a command allocates does not depend on the machine or on the run
  (let* ((works (list (lambda () nil) (lambda () (make-list 300 nil)) (lambda () (make-string 100 ?x))))
         (one (drgnx-perf-test--session works))
         (two (drgnx-perf-test--session works)))
    (should (eql (plist-get (plist-get one :alloc) :n) 3))
    (should (equal (plist-get one :alloc) (plist-get two :alloc)))))

(ert-deftest drgnx-perf/rows-sum-the-bound-counters ()
  (let ((drgnx-perf-row-counters '(drgnx-perf-test--rows-a drgnx-perf-test--rows-b drgnx-perf-test--not-bound))
        (drgnx-perf-test--rows-a 10) (drgnx-perf-test--rows-b 0))
    (drgnx-perf-begin)
    (setq drgnx-perf-test--rows-a 13 drgnx-perf-test--rows-b 2)
    (should (eql (plist-get (drgnx-perf-end) :rows) 5))))                 ; 3 + 2; the unbound one counts 0

(ert-deftest drgnx-perf/calibration-marks-a-loaded-run ()
  ;; stubbed clocks: the loop takes W ms of wall time and C ms of this process's CPU
  (drgnx-perf-calibrate)                                                   ; compiles the loop before the clocks are stubbed
  (cl-flet ((calibrate (wall cpu)
              (let ((w (list 0.0 (/ wall 1000.0))) (c (list 0 (* cpu 1000000))))
                (cl-letf (((symbol-function 'float-time) (lambda (&rest _) (pop w)))
                          ((symbol-function 'current-cpu-time) (lambda () (cons (pop c) 1000000000))))
                  (drgnx-perf-calibrate)))))
    (let ((alone (calibrate 40 40)) (busy (calibrate 100 50)))
      (should-not (plist-get alone :loaded))
      (should (plist-get busy :loaded))                                    ; 2.0 > 1.3
      (should (eql (plist-get busy :wall_ms) 100.0))
      (should (eql (plist-get busy :cpu_ms) 50.0)))))

(defvar drgnx-perf-test-hook5 nil)
(defun drgnx-perf-test--hook5 () nil)

(ert-deftest drgnx-perf/the-audit-gives-hooks-per-command ()
  ;; each audited function call takes 5 ms of a stubbed clock; commands 1 and 2 run it twice and once
  (let ((now 0.0) (drgnx-perf-test-hook5 nil))
    (cl-letf (((symbol-function 'float-time) (lambda (&rest _) (setq now (+ now 0.005)))))
      (add-hook 'drgnx-perf-test-hook5 #'drgnx-perf-test--hook5)
      (drgnx-perf-begin)
      (drgnx-perf-audit-begin '(drgnx-perf-test-hook5))
      (run-hooks 'pre-command-hook) (run-hooks 'drgnx-perf-test-hook5) (run-hooks 'drgnx-perf-test-hook5)
      (run-hooks 'pre-command-hook) (run-hooks 'drgnx-perf-test-hook5)
      (drgnx-perf-audit-end)
      (drgnx-perf-end))
    (let ((h (drgnx-perf-audit-hooks)))
      (should (eql (plist-get h :n) 2))
      (should (eql (plist-get h :p50) 5.0))
      (should (eql (plist-get h :max) 10.0)))
    (should-not (advice-member-p #'drgnx-perf--timers-ad 'timer-event-handler))))

(ert-deftest drgnx-perf/a-command-is-timed-to-the-next-idle-point ()
  ;; pre-command → post-command → a 0 s timer (after the redisplay that follows)
  (drgnx-perf-begin)
  (unwind-protect
      (progn
        (run-hooks 'pre-command-hook)
        (sleep-for 0.03)
        (run-hooks 'post-command-hook)
        (sit-for 0.05))                                 ; the timer runs
    (let ((r (drgnx-perf-end)))
      (should (eql (plist-get (plist-get r :input) :n) 1))
      (should (>= (plist-get (plist-get r :input) :max) 30))
      (should (numberp (plist-get r :gc_ms)))
      (should (> (plist-get r :rss_kb) 0))))
  (should-not (memq #'drgnx-perf--pre pre-command-hook)))      ; nothing left installed

(ert-deftest drgnx-perf/rss-without-proc-comes-from-the-process-attributes ()
  ;; macOS has no /proc/self/status
  (let ((insert (symbol-function 'insert-file-contents)))
    (cl-letf (((symbol-function 'insert-file-contents)
               (lambda (file &rest args)
                 (if (string-prefix-p "/proc/" file) (signal 'file-missing (list "Opening input file" file))
                   (apply insert file args)))))
      (should (> (drgnx-perf-rss-kb) 0)))))

(ert-deftest drgnx-perf/the-hook-audit-names-what-costs-and-restores-the-hooks ()
  (let ((drgnx-perf-test-hook nil) (slow (lambda () (sleep-for 0.02))))
    (defvar drgnx-perf-test-hook)
    (add-hook 'drgnx-perf-test-hook #'ignore)
    (add-hook 'drgnx-perf-test-hook slow)
    (let ((before (copy-sequence drgnx-perf-test-hook)))
      (drgnx-perf-audit-begin '(drgnx-perf-test-hook))
      (run-hooks 'drgnx-perf-test-hook)
      (run-hooks 'drgnx-perf-test-hook)
      (let ((audit (drgnx-perf-audit-end)))
        (should (equal drgnx-perf-test-hook before))
        (let ((top (car audit)))
          (should (equal (plist-get top :hooks) "drgnx-perf-test-hook"))
          (should (eql (plist-get top :calls) 2))
          (should (>= (plist-get top :ms) 40)))))))

(ert-deftest drgnx-perf/budgets-judge-medians-and-say-what-failed ()
  (let ((budgets '((typing (:input :p95) 50) (frames (:frame :p95) 500))))
    (should-not (drgnx-perf-verdict '((typing :input (:p95 30)) (frames :frame (:p95 400))) budgets))
    (should (equal (drgnx-perf-verdict '((typing :input (:p95 80)) (frames :frame (:p95 400))) budgets)
                   '("typing input p95 80 > 50")))
    (should (equal (drgnx-perf-verdict '((frames :frame (:p95 400))) budgets)
                   '("typing: not measured")))))

(ert-deftest drgnx-perf/history-says-what-got-worse ()
  (let* ((dir (make-temp-file "drgnx-perf-hist" t)) (file (expand-file-name "history.jsonl" dir)))
    (unwind-protect
        (progn
          (dotimes (i 5) (drgnx-perf-history-append file (format "c%d" i) '((typing :input (:p95 20)))))
          (should-not (drgnx-perf-regressions file '((typing :input (:p95 22)))))
          (should-not (drgnx-perf-regressions file '((typing :input (:p95 24)))))   ; 20% … and noise below 5 ms
          (should (equal (drgnx-perf-regressions file '((typing :input (:p95 40))))
                         '("typing input p95 40 vs 20 (median of the last 5)"))))
      (delete-directory dir t))))

(ert-deftest drgnx-perf/small-differences-are-noise ()
  (let* ((dir (make-temp-file "drgnx-perf-hist" t)) (file (expand-file-name "history.jsonl" dir)))
    (unwind-protect
        (progn
          (drgnx-perf-history-append file "c0" '((typing :input (:p95 2.2))))
          (should-not (drgnx-perf-regressions file '((typing :input (:p95 3.5))))))   ; +60%, but 1.3 ms
      (delete-directory dir t))))

(defvar drgnx-perf-test-hook2 nil)
(defvar drgnx-perf-test--calls 0)
(defun drgnx-perf-test--once ()
  (setq drgnx-perf-test--calls (1+ drgnx-perf-test--calls))
  (remove-hook 'drgnx-perf-test-hook2 #'drgnx-perf-test--once))

(ert-deftest drgnx-perf/the-audit-lets-a-function-remove-itself ()
  ;; A probe must not change what it measures: a hook function that removes itself is gone.
  (let ((drgnx-perf-test-hook2 nil) (drgnx-perf-test--calls 0))
    (add-hook 'drgnx-perf-test-hook2 #'drgnx-perf-test--once)
    (drgnx-perf-audit-begin '(drgnx-perf-test-hook2))
    (run-hooks 'drgnx-perf-test-hook2)
    (run-hooks 'drgnx-perf-test-hook2)
    (let ((audit (drgnx-perf-audit-end)))
      (should (= drgnx-perf-test--calls 1))
      (should (eql (plist-get (car audit) :calls) 1))
      (should-not (advice--p (symbol-function 'drgnx-perf-test--once))))))

;;;; Review fixes (M8 final review)

(ert-deftest drgnx-perf/latency-includes-the-redisplay ()
  ;; C1: timers can run before read_char's redisplay; the probe redisplays before reading the clock.
  (cl-letf (((symbol-function 'redisplay) (lambda (&optional _) (sleep-for 0.03))))
    (drgnx-perf-begin)
    (unwind-protect
        (progn (run-hooks 'pre-command-hook) (run-hooks 'post-command-hook) (sit-for 0.1))
      (let ((r (drgnx-perf-end)))
        (should (>= (plist-get (plist-get r :input) :max) 30))))))

(ert-deftest drgnx-perf/every-gc-pause-is-recorded ()
  (drgnx-perf-begin)
  (unwind-protect (progn (garbage-collect) (garbage-collect))
    (let ((r (drgnx-perf-end)))
      (should (>= (plist-get (plist-get r :gc_pause) :n) 2))
      (should (numberp (plist-get (plist-get r :gc_pause) :p90)))))
  (should-not (memq #'drgnx-perf--gc post-gc-hook)))

(defvar drgnx-perf-test-hook3 nil)
(defvar drgnx-perf-test-hook4 nil)
(defun drgnx-perf-test--once3 () (remove-hook 'drgnx-perf-test-hook3 #'drgnx-perf-test--once3))
(defun drgnx-perf-test--both () nil)

(ert-deftest drgnx-perf/the-audit-restores-only-what-it-changed ()
  ;; I5: with a lambda on the hook, a function that removed itself stays removed, one added stays.
  (let ((drgnx-perf-test-hook3 nil) (lam (lambda () nil)))
    (add-hook 'drgnx-perf-test-hook3 lam)
    (add-hook 'drgnx-perf-test-hook3 #'drgnx-perf-test--once3)
    (drgnx-perf-audit-begin '(drgnx-perf-test-hook3))
    (should-error (drgnx-perf-audit-begin '(drgnx-perf-test-hook3)))       ; never twice
    (run-hooks 'drgnx-perf-test-hook3)
    (add-hook 'drgnx-perf-test-hook3 #'ignore)
    (drgnx-perf-audit-end)
    (should (memq lam drgnx-perf-test-hook3))
    (should (memq #'ignore drgnx-perf-test-hook3))
    (should-not (memq #'drgnx-perf-test--once3 drgnx-perf-test-hook3))))

(ert-deftest drgnx-perf/the-audit-counts-a-call-once-and-gates-p95 ()
  (let ((drgnx-perf-test-hook3 nil) (drgnx-perf-test-hook4 nil))
    (add-hook 'drgnx-perf-test-hook3 #'drgnx-perf-test--both)
    (add-hook 'drgnx-perf-test-hook4 #'drgnx-perf-test--both)
    (drgnx-perf-audit-begin '(drgnx-perf-test-hook3 drgnx-perf-test-hook4))
    (run-hooks 'drgnx-perf-test-hook3)
    (let ((row (car (drgnx-perf-audit-end))))
      (should (eql (plist-get row :calls) 1))
      (should (numberp (plist-get row :p90)))))
  (should (equal (drgnx-perf-audit-verdict '((:fn "slow" :hooks "post-command-hook" :p90 3.1) (:fn "fast" :p90 0.1)) 2)
                 '("hook function slow (post-command-hook) p90 3.1 > 2 ms"))))

(ert-deftest drgnx-perf/a-regression-is-fifteen-percent-and-five-ms ()
  (let* ((dir (make-temp-file "drgnx-perf-hist" t)) (file (expand-file-name "history.jsonl" dir)))
    (unwind-protect
        (progn
          (dotimes (i 3) (drgnx-perf-history-append file (format "c%d" i) '((typing :input (:p95 30)))))
          (should-not (drgnx-perf-regressions file '((typing :input (:p95 34)))))     ; 13%
          (should (drgnx-perf-regressions file '((typing :input (:p95 36))))))        ; 20% and 6 ms
      (delete-directory dir t))))

(ert-deftest drgnx-perf/the-history-keeps-the-load-of-a-run ()
  (let* ((dir (make-temp-file "drgnx-perf-hist" t)) (file (expand-file-name "history.jsonl" dir)))
    (unwind-protect
        (progn
          (drgnx-perf-history-append file "c0" '((typing :input (:p95 3))) 1.234)
          (should (eql (plist-get (json-parse-string (with-temp-buffer (insert-file-contents file) (buffer-string)) :object-type 'plist) :load)
                       1.2))
          (should (drgnx-perf--history file)))
      (delete-directory dir t))))

;;; perf-test.el ends here
