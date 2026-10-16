;;; uitest-report-test.el --- batch tests: jank report reduction -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-uitest)

(defun drgnx-test--sig (&rest kv)
  (append kv (list :buffer "b" :start 1 :point 1 :edges '(0 0 10 10) :header 0 :modeline 20)))

(ert-deftest drgnx-uitest/report-quiet ()
  (let ((r (drgnx-uitest-jank-report nil 100.0 nil '("w1") 100.0)))
    (should (equal (plist-get r :settle_ms) 0))
    (should (equal (plist-get r :collateral_moves) 0))
    (should (equal (plist-get r :layout_changes) 0))))

(ert-deftest drgnx-uitest/report-collateral-oscillation-chrome-echo ()
  (let* ((a (drgnx-test--sig)) (b (drgnx-test--sig :point 9)) (c (drgnx-test--sig :header 22))
         (initial (list (cons "w1" a) (cons "w2" a) (cons "mini" '(:height 20))))
         (log (list (list 100.10 'change "w1" a b)        ; target: not collateral
                    (list 100.20 'change "w2" a b)        ; collateral
                    (list 100.30 'change "w2" b a)        ; back to an earlier value: oscillation
                    (list 100.35 'change "w1" b c)        ; chrome change
                    (list 100.40 'change "mini" '(:height 20) '(:height 40))
                    (list 100.45 'scroll "w2" 5)))
         (r (drgnx-uitest-jank-report log 100.0 initial '("w1") 100.05)))
    (should (equal (plist-get r :collateral_moves) 1))
    (should (equal (plist-get r :collateral) ["w2"]))
    (should (equal (plist-get r :oscillations) 1))
    (should (equal (plist-get r :chrome_changes) 1))
    (should (equal (plist-get r :echo_changes) 1))
    (should (equal (plist-get r :scrolls) 1))
    (should (equal (plist-get r :settle_ms) 400))))   ; 100.45 - 100.05

(ert-deftest drgnx-uitest/report-layout ()
  (let* ((a (drgnx-test--sig)) (moved (drgnx-test--sig :edges '(0 0 10 5)))
         (log (list (list 1.1 'change "w1" a moved) (list 1.2 'change "w3" nil a)))
         (r (drgnx-uitest-jank-report log 1.0 (list (cons "w1" a)) '("w1" "w3") 1.0)))
    (should (equal (plist-get r :layout_changes) 2))
    (should (equal (plist-get r :collateral_moves) 0))))
