;;; wait-fixture-test.el --- drgnx-test-wait -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
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
        (let* ((reads 0)
               (d (cl-letf (((symbol-function 'drgnx-uitest-settle-scale) (lambda (&rest _) (cl-incf reads) 3.0)))
                    ;; the scale is read once, by the wait: a load-based second read here could differ
                    (drgnx-wait-test--fail (lambda () (drgnx-test-wait (lambda () nil) :secs 0.05 :what "the sleeper"))))))
          (should (= reads 1))
          (should (equal (plist-get d :waited-for) "the sleeper"))
          (should (= (plist-get d :secs) (* 0.05 3.0)))
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

(defvar drgnx-wait-test--links 0 "Links of the timer chain run so far.")

(defun drgnx-wait-test--link ()
  "One link of a chain of zero-delay timers (a view drawing in slices): 50 in all."
  (when (< (cl-incf drgnx-wait-test--links) 50) (run-at-time 0 nil #'drgnx-wait-test--link)))

(ert-deftest drgnx-test-wait/runs-a-timer-chain-back-to-back ()
  ;; One `accept-process-output' runs one link of a chain however long it waits: with a timer due, the wait polls
  ;; without a timeout, so the chain never waits a poll per link (CI-GUI-1: 10,100 rows got one 4 ms slice per 50 ms).
  (let ((drgnx-wait-test--links 0) (timeouts nil) (orig (symbol-function 'accept-process-output)))
    (cl-letf (((symbol-function 'accept-process-output)
               (lambda (&optional process secs &rest more) (push secs timeouts) (apply orig process secs more))))
      (run-at-time 0 nil #'drgnx-wait-test--link)
      (should (drgnx-test-wait (lambda () (>= drgnx-wait-test--links 50)) :what "the chain's last link")))
    (should timeouts)
    (should (equal (delete-dups timeouts) '(0)))))

(defun drgnx-wait-test--rearm ()
  "A timer that is due again the moment it has run."
  (run-at-time 0 nil #'drgnx-wait-test--rearm))

(ert-deftest drgnx-test-wait/the-deadline-holds-while-a-timer-stays-due ()
  ;; The wait gives up at its deadline (it signals, it does not return) though a timer is due at every poll.  The
  ;; scale is pinned: a load-based one read again below could differ (macOS CI: 0.337 against 0.369).
  (let ((process-environment (cons "DRGNX_UITEST_SETTLE_SCALE=2" process-environment))
        (t0 (float-time)))
    (run-at-time 0 nil #'drgnx-wait-test--rearm)
    (unwind-protect
        (let ((d (drgnx-wait-test--fail (lambda () (drgnx-test-wait (lambda () nil) :secs 0.2)))))
          (should (= (plist-get d :secs) (* 0.2 (drgnx-uitest-settle-scale))))
          (should (< (- (float-time) t0) 5)))
      (cancel-function-timers #'drgnx-wait-test--rearm))))

(ert-deftest drgnx-test-pause/runs-processes-and-a-timer-chain-for-its-window ()
  ;; A test that asserts something does NOT happen gives it a short window: the whole window, every link of a chain
  ;; (a `sleep-for' runs one).  The clock is a counter here, 1/16 s per read: about 60 polls, 50 of them the links.
  (let ((drgnx-wait-test--links 0) (now 0.0))
    (cl-letf (((symbol-function 'drgnx-test-wait-now) (lambda () (cl-incf now 0.0625)))
              ((symbol-function 'accept-process-output)
               (let ((orig (symbol-function 'accept-process-output)))
                 (lambda (&optional process secs &rest more) (apply orig process (min secs 0.001) more)))))
      (run-at-time 0 nil #'drgnx-wait-test--link)
      (should-not (drgnx-test-pause 4)))
    (should (= drgnx-wait-test--links 50))
    (should (>= now 4))))

(ert-deftest drgnx-test-wait/works-inside-the-clock-fixture ()
  ;; Each timed `accept-process-output' advances virtual time by the real wait, so a virtual-time PRED comes true.
  (drgnx-test-with-clock ()
    (let ((start (float-time)))
      (should (drgnx-test-wait (lambda () (> (float-time) (+ start 0.05))) :secs 5)))))
