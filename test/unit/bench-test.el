;;; bench-test.el --- batch tests: the workbench benchmark's verdict -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-bench)

(ert-deftest drgnx-bench/verdict ()
  (let ((budgets '(:explorer-first 30 :explorer-expand 80)))
    ;; Within budget and faster than the competitor: no failures.
    (should (null (drgnx-bench-verdict '(:drgnx (:explorer-first 10 :explorer-expand 50)
                                                :treemacs (:explorer-first 40 :explorer-expand 900))
                                       budgets '((:explorer-first . :treemacs) (:explorer-expand . :treemacs)))))
    (let ((fails (drgnx-bench-verdict '(:drgnx (:explorer-first 35 :explorer-expand 50)
                                               :treemacs (:explorer-first 40 :explorer-expand 20))
                                      budgets '((:explorer-first . :treemacs) (:explorer-expand . :treemacs)))))
      (should (seq-find (lambda (f) (string-match-p "explorer-first.*35.*budget 30" f)) fails))
      (should (seq-find (lambda (f) (string-match-p "explorer-expand.*50.*treemacs.*20" f)) fails)))
    ;; A competitor that is not installed is not compared.
    (should (null (drgnx-bench-verdict '(:drgnx (:explorer-first 10)) '(:explorer-first 30)
                                       '((:explorer-first . :treemacs)))))))

(ert-deftest drgnx-bench/table ()
  (let ((table (drgnx-bench-table '(:drgnx (:explorer-first 10.4) :treemacs (:explorer-first 41.25))
                                  '((:explorer-first . :treemacs)))))
    (should (string-match-p "explorer-first +10\\.4 +41\\.2 +treemacs" table))))

(ert-deftest drgnx-bench/differences-below-the-noise-floor-do-not-count ()
  ;; 0.2 ms at the p95 of 50 presses is measurement noise, not a slower editor (a frame is 16 ms).
  (should (null (drgnx-bench-verdict '(:drgnx (:explorer-key-p95 0.5) :treemacs (:explorer-key-p95 0.3))
                                     '(:explorer-key-p95 8) '((:explorer-key-p95 . :treemacs)))))
  (should (drgnx-bench-verdict '(:drgnx (:explorer-key-p95 1.5) :treemacs (:explorer-key-p95 0.3))
                               '(:explorer-key-p95 8) '((:explorer-key-p95 . :treemacs)))))

;;;; The in-session measuring helpers (test/bench/workbench-bench.el)

(load (expand-file-name "../test/bench/workbench-bench.el" drgnx-ui-harness-dir) nil t)

(ert-deftest drgnx-bench/explorer-gc-reported ()
  ;; DEFERRED M3a-12: every measurement notes the garbage collections that ran inside it, and the session
  ;; reports them next to the times, so a GC that lands in a measured window is visible.
  (let ((drgnx-bench--gc nil) (gc-cons-threshold 100000) (gc-cons-percentage 0.001) (garbage nil))
    (let ((r (drgnx-bench--put nil :explorer-first
                               (drgnx-bench--ms nil (lambda () (setq garbage (make-list 400000 (make-string 8 ?x))))))))
      (should (numberp (plist-get r :explorer-first)))
      (let ((gc (plist-get drgnx-bench--gc :explorer-first)))
        (should (> (plist-get gc :gcs) 0))
        (should (>= (plist-get gc :ms) 0)))
      (should (string-match-p "explorer-first ran [1-9]" (string-join (drgnx-bench-gc-notes (list :gc drgnx-bench--gc)) "\n"))))
    ;; a measurement without garbage reports none
    (let ((gc-cons-threshold (* 512 1024 1024)))
      (drgnx-bench--put nil :explorer-expand (drgnx-bench--ms nil (lambda () (+ 1 1))))
      (should (= 0 (plist-get (plist-get drgnx-bench--gc :explorer-expand) :gcs))))
    (should (equal '("gc: none inside any measurement") (drgnx-bench-gc-notes '(:gc (:a (:gcs 0 :ms 0.0))))))))

(ert-deftest drgnx-bench/key-p95-is-the-median-of-five-rounds ()
  ;; DEFERRED M3c-11: one slow round (a GC, another process) must not decide the verdict.
  (should (= 3 (drgnx-bench--median '(5 1 3 100 2))))
  (should (= 2.5 (drgnx-bench--median '(1 2 3 4))))
  (with-temp-buffer
    (insert (make-string 2000 ?\n))
    (goto-char (point-min))
    (let ((n 0))
      (cl-letf (((symbol-function 'redisplay) #'ignore))
        (let ((v (drgnx-bench--p95 (lambda () (forward-line 1) (setq n (1+ n))) 20)))
          (should (numberp v))))
      ;; five rounds of 20 presses, the point back at the start between them
      (should (= 100 n))
      (should (= 1 (point))))))
