;;; wb-signal-edge-test.el --- batch tests: the change bus, edge cases -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-signal)

(ert-deftest drgnx-signal-edge/a-failing-window-function-is-recorded-and-the-flush-still-armed ()
  "M3d-3: an error in one `drgnx-signal-window-functions' function neither skips the others nor the
flush schedule, and it is recorded."
  (let* ((drgnx-signal-errors nil) (drgnx-signal--timer nil) (called nil)
         (drgnx-signal-window-functions
          (list (lambda (_f) (error "Boom")) (lambda (f) (push f called)))))
    (unwind-protect
        (progn
          (drgnx-signal--windows (selected-frame))
          (should (equal called (list (selected-frame))))
          (should (timerp drgnx-signal--timer))
          (should (string-match-p "Boom" (car drgnx-signal-errors))))
      (when (timerp drgnx-signal--timer) (cancel-timer drgnx-signal--timer)))))

;;; wb-signal-edge-test.el ends here
