;;; look-pixels-test.el --- logical pixels to device pixels: one rounding rule, one line rule -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D (pure): `drgnx-px' and `drgnx-px-line' take the scale as an argument, so no display is needed.
(require 'ert)
(require 'drgnx)
(require 'drgnx-pixels)

(defconst drgnx-pixels-test--scales (list 1.0 1.25 (/ 160 120.0) 2.0)
  "The scales every sizing row checks: 1, 1.25, 4/3 (the wire's 160/120) and 2.")

(ert-deftest drgnx-pixels/px-rounds-half-up ()
  "The look's sizes at each scale: halves go up (Emacs `round' sends 32.5 to 32 and 42.5 to 42)."
  (pcase-dolist (`(,logical . ,want) '((21 21 26 28 42) (26 26 33 35 52) (34 34 43 45 68) (38 38 48 51 76)
                                       (6 6 8 8 12) (12 12 15 16 24) (16 16 20 21 32) (24 24 30 32 48)))
    (should (equal (mapcar (lambda (s) (drgnx-px logical nil s)) drgnx-pixels-test--scales) want))))

(ert-deftest drgnx-pixels/px-line-thin-line-is-floor-of-the-scale ()
  "A thin line is max(1, floor(scale)) device pixels: 1 at 1.25 and 4/3, 2 at 2; wider lines keep their width."
  (should (equal (mapcar (lambda (s) (drgnx-px-line 1 nil s)) drgnx-pixels-test--scales) '(1 1 1 2)))
  (should (equal (mapcar (lambda (s) (drgnx-px-line 0.5 nil s)) drgnx-pixels-test--scales) '(1 1 1 2)))
  (should (equal (mapcar (lambda (s) (drgnx-px-line 1.5 nil s)) drgnx-pixels-test--scales) '(1 1 2 3)))
  (should (equal (mapcar (lambda (s) (drgnx-px-line 2 nil s)) drgnx-pixels-test--scales) '(2 3 3 4))))

(ert-deftest drgnx-pixels/device-pixels-on-both-native-shells ()
  "Frames count device pixels under the Wayland shell and under Naglfar.
Nidhogg answers `(featurep \\='nidhogg-wayland)' with t even with `features' bound without it, so the case without
a native shell can't be made here; the Naglfar case can."
  (let ((features (cons 'naglfar features)))
    (should (drgnx-pixels-device-p)))
  (should (eq (and (drgnx-pixels-device-p) t) (and (or (featurep 'nidhogg-wayland) (featurep 'naglfar)) t)))
  ;; the scale is the display scale (1 in batch) times the UI scale
  (should (= (drgnx-pixels-scale) (drgnx-pixels-ui-scale))))

(ert-deftest drgnx-pixels/sums-from-rounded-parts ()
  "A row and its gap add up from their rounded parts at 1.25 (33 + 8), never from the unrounded sum (round 40)."
  (should (= (+ (drgnx-px 26 nil 1.25) (drgnx-px 6 nil 1.25)) 41)))

(ert-deftest drgnx-pixels/the-scale-conses-nothing ()
  "A budget: `drgnx-pixels-scale' runs on every bar build and row, so reading the scale conses nothing, with a UI
scale or without one (`frame-parameter' of a parameter of drgnx's own copies the frame's whole parameter list)."
  (let ((f (selected-frame))
        ;; compiled, so the loop itself conses nothing; the difference to an empty loop is the calls' own
        (conses (byte-compile (lambda (n) (let ((c (car (memory-use-counts))))
                                            (dotimes (_ n) (drgnx-pixels-scale))
                                            (- (car (memory-use-counts)) c))))))
    (unwind-protect
        (dolist (s '(nil 1.1))
          (drgnx-pixels-set-ui-scale f s)
          (should (= (drgnx-pixels-ui-scale f) (or s 1.0)))
          (should (= (funcall conses 1000) (funcall conses 0))))
      (drgnx-pixels-set-ui-scale f nil))))

(provide 'look-pixels-test)
;;; look-pixels-test.el ends here
