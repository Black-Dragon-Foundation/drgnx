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
  (let* ((a (drgnx-test--sig)) (b (drgnx-test--sig :point 9)) (c (drgnx-test--sig :point 9 :header 22))
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

(ert-deftest drgnx-uitest/report-oscillation-is-per-field ()
  ;; Point snaps back to where it was while the window's edges changed meanwhile: still a snap-back.
  (let* ((a (drgnx-test--sig))
         (b (drgnx-test--sig :point 73 :edges '(0 0 10 12)))
         (c (drgnx-test--sig :point 1 :edges '(0 0 10 12)))
         (r (drgnx-uitest-jank-report (list (list 1.1 'change "w1" a b) (list 1.3 'change "w1" b c))
                                      1.0 (list (cons "w1" a)) '("w1") 1.0)))
    (should (= (plist-get r :oscillations) 1))))

(ert-deftest drgnx-uitest/report-causes-and-trace ()
  (let* ((a (drgnx-test--sig)) (b (drgnx-test--sig :point 9)) (c (drgnx-test--sig :point 1))
         (log (list (list 1.1 'change "w1" a b "command:mouse-set-point")
                    (list 1.3 'change "w1" b c "timer:follow")))
         (r (drgnx-uitest-jank-report log 1.0 (list (cons "w1" a)) '("w1") 1.0)))
    (should (= (plist-get r :timer_moves) 1))
    (should (equal (plist-get r :causes)
                   [(:cause "command:mouse-set-point" :count 1) (:cause "timer:follow" :count 1)]))
    (let ((step (aref (plist-get r :trace) 1)))
      (should (equal (plist-get step :cause) "timer:follow"))
      (should (equal (plist-get step :t_ms) 300))
      (should (equal (plist-get step :window) "w1"))
      (should (equal (plist-get step :fields) ["point"]))
      (should (equal (plist-get step :from) '(:point 9)))
      (should (equal (plist-get step :to) '(:point 1))))))

(ert-deftest drgnx-uitest/report-uncaused-changes-are-other ()
  (let* ((a (drgnx-test--sig)) (b (drgnx-test--sig :start 5))
         (r (drgnx-uitest-jank-report (list (list 1.1 'change "w1" a b)) 1.0 (list (cons "w1" a)) '("w1") 1.0)))
    (should (equal (plist-get (aref (plist-get r :trace) 0) :cause) "other"))
    (should (= (plist-get r :timer_moves) 0))))

(ert-deftest drgnx-uitest/scroll-without-a-new-start-is-not-a-change ()
  ;; window-scroll-functions also run when redisplay re-uses the same start; that must not
  ;; count as a change (it kept busy configurations from ever settling).
  (let ((drgnx-uitest-record--log nil) (drgnx-uitest-record--scroll-starts nil)
        (drgnx-uitest-record--last-change 0.0) (w (selected-window)))
    (drgnx-uitest-record--on-scroll w 1)
    (drgnx-uitest-record--on-scroll w 1)
    (drgnx-uitest-record--on-scroll w 9)
    (should (= (length drgnx-uitest-record--log) 2))))

(ert-deftest drgnx-uitest/a-redraw-with-an-unchanged-start-is-not-a-scroll ()
  ;; The first `window-scroll-functions' call of a measurement for a window whose start did not
  ;; change (any redisplay, e.g. a timer's) must not count as a change: it inflated settle times.
  (require 'drgnx-uitest)
  (drgnx-uitest-measure-begin)
  (unwind-protect
      (progn
        (drgnx-uitest-record--on-scroll (selected-window) (window-start))
        (should-not (seq-find (lambda (e) (eq (nth 1 e) 'scroll)) drgnx-uitest-record--log)))
    (drgnx-uitest-measure-end)))
