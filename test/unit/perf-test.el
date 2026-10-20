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
  ;; a p95 of fewer samples is the maximum or next to it: it has no value, and wall clock is only reported anyway
  (let ((r (list 'tabs :input (drgnx-perf-stats '(1 2 3 400)))))
    (should-not (drgnx-perf-verdict (list r) '((tabs (:input :p95) 16))))
    (should (equal (drgnx-perf-report (list r) '((tabs (:input :p95) 16) (tabs (:input :p90) 16)))
                   '("tabs input p95 - (budget 16): reported (wall clock; judge with --perf --ab)"
                     "tabs input p90 400 (budget 16): reported (wall clock; judge with --perf --ab)")))))

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
  (let ((budgets '((typing (:alloc :p50) 50) (memory (:rss_kb) 500))))
    (should-not (drgnx-perf-verdict '((typing :alloc (:p50 30)) (memory :rss_kb 400)) budgets))
    (should (equal (drgnx-perf-verdict '((typing :alloc (:p50 80)) (memory :rss_kb 400)) budgets)
                   '("typing alloc p50 80 > 50")))
    (should (equal (drgnx-perf-verdict '((memory :rss_kb 400)) budgets) '("typing: not measured")))
    (should (equal (drgnx-perf-verdict '((typing :input (:p50 1)) (memory :rss_kb 400)) budgets) '("typing alloc p50: no value")))))

(ert-deftest drgnx-perf/an-alloc-budget-fails-at-plus-one ()
  (let ((budgets '((typing (:alloc :p50) 1000))))
    (should-not (drgnx-perf-verdict '((typing :alloc (:p50 1000))) budgets))
    (should (equal (drgnx-perf-verdict '((typing :alloc (:p50 1001))) budgets) '("typing alloc p50 1001 > 1000")))))

(ert-deftest drgnx-perf/a-rows-budget-is-exact ()
  (let ((budgets '((explorer (:rows) 12))))
    (should-not (drgnx-perf-verdict '((explorer :rows 12)) budgets))
    (should (drgnx-perf-verdict '((explorer :rows 13)) budgets))
    (should (equal (drgnx-perf-verdict '((explorer :rows 11)) budgets) nil))))   ; fewer rows drawn is not a failure

(ert-deftest drgnx-perf/cpu-budgets-scale-with-the-factor ()
  (let ((budgets '((typing (:cpu_ms :p90) 2.0))) (r '((typing :cpu_ms (:p90 3.5)))))
    (should (drgnx-perf-verdict r budgets))                                          ; default factor 1
    (should (drgnx-perf-verdict r budgets :cpu-factor 1.5))
    (should-not (drgnx-perf-verdict r budgets :cpu-factor 2))                        ; hosted runners
    (let ((process-environment (cons "DRGNX_PERF_CPU_FACTOR=2" process-environment)))
      (should-not (drgnx-perf-verdict r budgets)))
    ;; the factor is for CPU only: allocation and rows stay exact
    (should (drgnx-perf-verdict '((typing :alloc (:p50 11))) '((typing (:alloc :p50) 10)) :cpu-factor 2))))

(ert-deftest drgnx-perf/a-budget-for-another-emacs-is-skipped ()
  (let ((budgets '((typing (:alloc :p50) 100 :emacs 30) (typing (:alloc :p50) 500 :emacs 31)))
        (r '((typing :alloc (:p50 300)))))
    (should-not (drgnx-perf-verdict r budgets :emacs-major 31))                      ; 300 > 100, but that row is for Emacs 30
    (should (equal (drgnx-perf-verdict r budgets :emacs-major 30) '("typing alloc p50 300 > 100")))
    (should (equal (drgnx-perf-verdict '((typing :alloc (:p50 600))) budgets :emacs-major 31) '("typing alloc p50 600 > 500")))
    (should-not (drgnx-perf-verdict '((typing :alloc (:p50 9999))) budgets :emacs-major 32))))   ; no row for 32 at all

(ert-deftest drgnx-perf/wall-paths-are-reported-not-judged ()
  (let ((budgets '((typing (:input :p90) 16) (typing (:alloc :p50) 100) (frames (:frame :p95) 500) (scrolling (:input :max) 50)))
        (r '((typing :input (:p90 400) :alloc (:p50 90)) (frames :frame (:p95 9000)))))
    (should-not (drgnx-perf-verdict r budgets))                                     ; 400 ms against 16 ms does not fail
    (should (equal (drgnx-perf-report r budgets)
                   '("typing input p90 400 (budget 16): reported (wall clock; judge with --perf --ab)"
                     "frames frame p95 9000 (budget 500): reported (wall clock; judge with --perf --ab)")))))   ; scrolling did not run

(ert-deftest drgnx-perf/regressions-use-the-spread-floor ()
  (let* ((dir (make-temp-file "drgnx-perf-hist" t)) (file (expand-file-name "history.jsonl" dir)))
    (unwind-protect
        (progn
          ;; alloc 100 x4 and 140: median 100, spread 40, so the floor is 80
          (dolist (a '(100 100 100 100 140)) (drgnx-perf-history-append file "c" `((typing :alloc (:p50 ,a)))))
          (should-not (drgnx-perf-regressions file '((typing :alloc (:p50 150)))))   ; +50%, but 50 < 80
          (should (equal (drgnx-perf-regressions file '((typing :alloc (:p50 181))))
                         '("typing alloc p50 181 vs 100 (median of the last 5)"))))
      (delete-directory dir t)))
  (let* ((dir (make-temp-file "drgnx-perf-hist" t)) (file (expand-file-name "history.jsonl" dir)))
    (unwind-protect
        (progn
          ;; a steady history: the floors alone (8 conses, 0.5 ms), and 15%
          (dotimes (i 5) (drgnx-perf-history-append file (format "c%d" i) '((typing :alloc (:p50 100) :cpu_ms (:p50 2.0)))))
          (should-not (drgnx-perf-regressions file '((typing :alloc (:p50 114) :cpu_ms (:p50 2.4)))))   ; under 15%
          (should-not (drgnx-perf-regressions file '((typing :alloc (:p50 6) :cpu_ms (:p50 2.5)))))      ; better, or exactly 25% and 0.5 ms
          (should (equal (drgnx-perf-regressions file '((typing :alloc (:p50 120) :cpu_ms (:p50 2.6))))
                         '("typing alloc p50 120 vs 100 (median of the last 5)" "typing cpu_ms p50 2.6 vs 2.0 (median of the last 5)")))
          (should-not (drgnx-perf-regressions file '((typing :alloc (:p50 105))))))   ; 5%: not worse by 15%
      (delete-directory dir t))))

(ert-deftest drgnx-perf/history-says-what-got-worse ()
  (let* ((dir (make-temp-file "drgnx-perf-hist" t)) (file (expand-file-name "history.jsonl" dir)))
    (unwind-protect
        (progn
          (dotimes (i 5) (drgnx-perf-history-append file (format "c%d" i) '((typing :alloc (:p50 200)))))
          (should-not (drgnx-perf-regressions file '((typing :alloc (:p50 220)))))
          (should-not (drgnx-perf-regressions file '((typing :alloc (:p50 229)))))   ; under 15%
          (should (equal (drgnx-perf-regressions file '((typing :alloc (:p50 400))))
                         '("typing alloc p50 400 vs 200 (median of the last 5)"))))
      (delete-directory dir t))))

(ert-deftest drgnx-perf/small-differences-are-noise ()
  (let* ((dir (make-temp-file "drgnx-perf-hist" t)) (file (expand-file-name "history.jsonl" dir)))
    (unwind-protect
        (progn
          (drgnx-perf-history-append file "c0" '((typing :alloc (:p50 20))))
          (should-not (drgnx-perf-regressions file '((typing :alloc (:p50 27))))))   ; +35%, but 7 conses
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
