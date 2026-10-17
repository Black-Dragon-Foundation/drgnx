;;; perf-test.el --- batch tests: the perf probes (statistics, recording, the hook audit, budgets, history) -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-perf)

(ert-deftest drgnx-perf/statistics ()
  (let ((s (drgnx-perf-stats '(5 1 4 2 3 10 6 7 9 8))))
    (should (eql (plist-get s :n) 10))
    (should (eql (plist-get s :p50) 5))
    (should (eql (plist-get s :p95) 10))
    (should (eql (plist-get s :max) 10))
    (should (= (plist-get s :mean) 5.5)))
  (should (equal (drgnx-perf-stats nil) '(:n 0))))

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
      (should (numberp (plist-get (plist-get r :gc_pause) :p95)))))
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
      (should (numberp (plist-get row :p95)))))
  (should (equal (drgnx-perf-audit-verdict '((:fn "slow" :hooks "post-command-hook" :p95 3.1) (:fn "fast" :p95 0.1)) 2)
                 '("hook function slow (post-command-hook) p95 3.1 > 2 ms"))))

(ert-deftest drgnx-perf/a-regression-is-fifteen-percent-and-five-ms ()
  (let* ((dir (make-temp-file "drgnx-perf-hist" t)) (file (expand-file-name "history.jsonl" dir)))
    (unwind-protect
        (progn
          (dotimes (i 3) (drgnx-perf-history-append file (format "c%d" i) '((typing :input (:p95 30)))))
          (should-not (drgnx-perf-regressions file '((typing :input (:p95 34)))))     ; 13%
          (should (drgnx-perf-regressions file '((typing :input (:p95 36))))))        ; 20% and 6 ms
      (delete-directory dir t))))

(ert-deftest drgnx-perf/a-busy-machine-is-told-apart-from-a-quiet-one ()
  ;; Timings taken while other processes took the CPU looked like a regression (scrolling 11.6 → 17.6 ms
  ;; on the same commit); the highest load sample decides, a missing sample never does.
  (should (eql (drgnx-perf-busy '(1.0 nil 5.5 2.0) 4) 5.5))
  (should-not (drgnx-perf-busy '(1.0 3.9) 4))
  (should-not (drgnx-perf-busy '(nil) 4))
  (let ((process-environment (cons "DRGNX_PERF_MAX_LOAD=7.5" process-environment)))
    (should (eql (drgnx-perf-max-load) 7.5)))
  (let ((process-environment (cons "DRGNX_PERF_MAX_LOAD=lots" process-environment)))
    (should (>= (drgnx-perf-max-load) 3))))

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
