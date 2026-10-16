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
