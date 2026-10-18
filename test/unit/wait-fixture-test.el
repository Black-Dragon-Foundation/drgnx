;;; wait-fixture-test.el --- drgnx-test-wait -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)

(defun drgnx-wait-test--fail (thunk)
  "The data of the `ert-test-failed' THUNK signals, as a plist."
  (cdr (should-error (funcall thunk) :type 'ert-test-failed)))

(defun drgnx-wait-test--tick ())

(ert-deftest drgnx-test-wait/returns-the-first-non-nil-value ()
  (let ((n 0))
    (should (equal (drgnx-test-wait (lambda () (and (>= (cl-incf n) 3) (list 'got n)))) '(got 3)))))

(ert-deftest drgnx-test-wait/a-timeout-names-what-it-waited-for-and-what-is-live ()
  (let ((proc (make-process :name "wait-test-sleeper" :command '("sleep" "60") :noquery t))
        (timer (run-at-time 600 nil #'drgnx-wait-test--tick)))
    (unwind-protect
        (let ((d (drgnx-wait-test--fail (lambda () (drgnx-test-wait (lambda () nil) :secs 0.05 :what "the sleeper")))))
          (should (equal (plist-get d :waited-for) "the sleeper"))
          (should (= (plist-get d :secs) (* 0.05 (drgnx-uitest-settle-scale))))
          (should (plist-member d :last-value))
          (should (member '("wait-test-sleeper" run) (plist-get d :processes)))
          (should (memq 'drgnx-wait-test--tick (plist-get d :timers))))
      (cancel-timer timer)
      (delete-process proc))))

(ert-deftest drgnx-test-wait/the-deadline-scales-with-the-settle-factor ()
  (let ((process-environment (cons "DRGNX_UITEST_SETTLE_SCALE=2" process-environment))
        (t0 (float-time)))
    (let ((d (drgnx-wait-test--fail (lambda () (drgnx-test-wait (lambda () nil) :secs 0.05)))))
      (should (= (plist-get d :secs) 0.1))
      ;; A lower bound only: a loaded machine may take longer, never less.
      (should (>= (- (float-time) t0) 0.1)))))

(ert-deftest drgnx-test-wait/a-pass-costs-no-deadline ()
  (let ((waits 0))
    (cl-letf (((symbol-function 'accept-process-output) (lambda (&rest _) (cl-incf waits) nil)))
      (should (eq (drgnx-test-wait (lambda () 'now) :secs 0.001) 'now)))
    (should (= waits 0))))

(ert-deftest drgnx-test-wait/waits-for-a-process-sentinel-by-its-done-flag ()
  (let ((proc (make-process :name "wait-test-echo" :command '("true") :noquery t
                            :sentinel (lambda (p _) (process-put p :done t)))))
    (should (drgnx-test-wait (lambda () (process-get proc :done)) :what "the sentinel"))))

(ert-deftest drgnx-test-wait/works-inside-the-clock-fixture ()
  (let ((clock (expand-file-name "test/fixtures/clock-fixture" drgnx-dir)))
    (skip-unless (load clock t t))
    ;; Each timed `accept-process-output' advances virtual time by the real wait, so a virtual-time PRED comes true.
    (eval '(drgnx-test-with-clock
            (let ((start (float-time)))
              (should (drgnx-test-wait (lambda () (> (float-time) (+ start 0.05))) :secs 5))))
          t)))
