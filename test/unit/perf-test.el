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
          (should (equal (plist-get top :hook) "drgnx-perf-test-hook"))
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

;;; perf-test.el ends here
