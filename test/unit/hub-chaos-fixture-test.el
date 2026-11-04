;;; hub-chaos-fixture-test.el --- the pre-flight's seeded hub answer delays -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'cl-lib)
(load (expand-file-name "test/fixtures/hub-chaos-fixture" drgnx-dir) nil t)

(ert-deftest drgnx-hub-chaos/a-seed-draws-the-same-delays-every-time ()
  ;; a red replays: the delays are a function of the seed and the connection's number only
  (let ((a (cl-loop for n below 30 collect (drgnx-test-hub-chaos-draw "7" n)))
        (b (cl-loop for n below 30 collect (drgnx-test-hub-chaos-draw "7" n))))
    (should (equal a b))
    (should-not (equal a (cl-loop for n below 30 collect (drgnx-test-hub-chaos-draw "8" n))))))

(ert-deftest drgnx-hub-chaos/delays-are-none-or-10-to-200-ms-and-both-occur ()
  ;; some connections go at once and some wait, so two connections of one test can swap their order
  (let ((ds (cl-loop for s from 1 to 10 append (cl-loop for n below 10 collect (drgnx-test-hub-chaos-draw (number-to-string s) n)))))
    (should (cl-every (lambda (d) (or (eql d 0) (and (>= d 0.010) (<= d 0.200)))) ds))
    (should (cl-some (lambda (d) (eql d 0)) ds))
    (should (cl-some (lambda (d) (> d 0.1)) ds))
    (should (cl-some (lambda (d) (and (> d 0) (< d 0.05))) ds))))

;;; hub-chaos-fixture-test.el ends here
