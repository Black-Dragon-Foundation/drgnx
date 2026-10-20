;;; wait-fixture.el --- one wait for real async work in tests -*- lexical-binding: t -*-
;; `drgnx-test-wait' is the only way a test waits for a process, a sentinel or a filter.  The deadline only
;; bounds a failure, so it is generous (and scaled on a loaded machine); a pass costs what the work costs.
;; `drgnx-test-pause' is the short window of a test that asserts something does not happen.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-uitest)                 ; `drgnx-uitest-settle-scale': definitions only, no window or frame work

(defun drgnx-test-wait-now ()
  "Real seconds, even inside the clock fixture (which fakes `float-time')."
  (if (fboundp 'drgnx-test-real-time) (drgnx-test-real-time) (float-time)))

(defun drgnx-test-wait--due-p ()
  "Non-nil when a wall timer is due now.  One `accept-process-output' runs one link of a chain of zero-delay
timers however long it waits, so with a timer due the wait polls without a timeout: the chain runs back to back."
  (and timer-list (not (time-less-p nil (timer--time (car timer-list))))))

(cl-defun drgnx-test-wait (pred &key (secs 30) what)
  "Call PRED until it returns non-nil, letting processes run between calls; return that value.
The deadline is SECS times `drgnx-uitest-settle-scale' of real time.  While a timer is due the wait polls without a
timeout, so a chain of timers (a view drawing in slices) runs back to back.  On timeout signal `ert-test-failed' with
\(:waited-for WHAT :secs S :last-value V :processes ((NAME STATUS)…) :timers (FUNCTION…)).
Wait on the sentinel's done flag, never on `process-live-p': it turns nil before the sentinel has run."
  (let* ((limit (* secs (drgnx-uitest-settle-scale)))
         (deadline (+ (drgnx-test-wait-now) limit))
         (value (funcall pred)))
    (while (and (not value) (< (drgnx-test-wait-now) deadline))
      (accept-process-output nil (if (drgnx-test-wait--due-p) 0 0.02))
      (setq value (funcall pred)))
    (or value
        (signal 'ert-test-failed
                (list :waited-for what :secs limit :last-value value
                      :processes (mapcar (lambda (p) (list (process-name p) (process-status p))) (process-list))
                      :timers (mapcar #'timer--function (append timer-list timer-idle-list)))))))

(defun drgnx-test-pause (secs)
  "Let processes and timers run for SECS of real time; nil.  Only for a test that asserts something does NOT happen
in a short window (a second answer, a tick that starts nothing): a wait for something uses `drgnx-test-wait'.
Unlike `sleep-for', which runs one link of a chain of timers, it runs the chain back to back."
  (let ((end (+ (drgnx-test-wait-now) secs)))
    (while (< (drgnx-test-wait-now) end)
      (accept-process-output nil (if (drgnx-test-wait--due-p) 0 0.02)))))

(provide 'drgnx-wait-fixture)
