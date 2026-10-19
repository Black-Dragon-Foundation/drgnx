;;; measure-fixture-test.el --- drgnx-test-alloc and drgnx-test-cpu-ms -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/measure-fixture" drgnx-dir) nil t)

(defun drgnx-measure-test--work (n)
  "Allocate some of every common kind: N conses, a string, a vector, a float."
  (list (make-list n 'x) (make-string 30 ?a) (make-vector 10 0) (float n)))

(ert-deftest drgnx-test-measure/alloc-is-deterministic ()
  ;; the same code on the same Emacs allocates the same: one value in 20 measurements, whatever else runs
  (let ((values (cl-loop repeat 20 collect (drgnx-test-alloc (drgnx-measure-test--work 40)))))
    (should (> (car values) 40))
    (should (equal (delete-dups (copy-sequence values)) (list (car values))))))

(ert-deftest drgnx-test-measure/alloc-subtracts-its-own-conses ()
  ;; reading the counters conses 7 (their list): not counted, so nothing measures 0 and N conses measure N
  (should (= 0 (drgnx-test-alloc)))
  (should (= 0 (drgnx-test-alloc nil)))
  (should (= 40 (drgnx-test-alloc (make-list 40 nil))))
  ;; every kind counts, not only conses: 30 characters and the string that holds them
  (should (> (drgnx-test-alloc (make-string 30 ?a)) 30)))

(ert-deftest drgnx-test-measure/alloc-measures-warm-runs ()
  ;; one unmeasured run first (a cache filled on the first call), then the least of three
  (let ((first t) (runs 0))
    (should (= 10 (drgnx-test-alloc (cl-incf runs)
                                    (if first (progn (setq first nil) (make-list 100 nil)) (make-list 10 nil)))))
    (should (= runs 4))))

(ert-deftest drgnx-test-measure/cpu-ms-is-a-median ()
  ;; each run reads the CPU clock before and after BODY; the result is the median of the runs' deltas, in ms
  (cl-flet ((scripted (ticks) (lambda () (cons (pop ticks) 1000))))
    (cl-letf (((symbol-function 'current-cpu-time) (scripted '(0 5 10 110 200 202))))
      (should (= 5.0 (drgnx-test-cpu-ms (:n 3) nil))))              ; 5, 100, 2 ms
    (cl-letf (((symbol-function 'current-cpu-time) (scripted '(0 1 10 12 20 23 30 130))))
      (should (= 2.5 (drgnx-test-cpu-ms (:n 4) nil)))))            ; 1, 2, 3, 100 ms: between the middle two
  (let ((runs 0))
    (should (>= (drgnx-test-cpu-ms () (cl-incf runs)) 0))          ; the real clock; 50 runs by default
    (should (= runs 50))))

;;; measure-fixture-test.el ends here
