;;; wb-guard-test.el --- batch tests: the jank guard knows owned windows (I9) -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-wb)
(require 'drgnx-jank-guard)

(defun drgnx-guard-test--from-timer (fn)
  "Run FN from a real timer and wait for it."
  (let ((done nil))
    (run-with-timer 0 nil (lambda () (unwind-protect (funcall fn) (setq done t))))
    (while (not done) (accept-process-output nil 0.01))))

(defmacro drgnx-guard-test--guarded (&rest body)
  `(let ((drgnx-jank-guard-log nil))
     (drgnx-jank-guard-enable)
     (unwind-protect (progn ,@body) (drgnx-jank-guard-disable))))

(ert-deftest drgnx-guard/owned-moves-are-not-violations ()
  (delete-other-windows)
  (let* ((a (selected-window)) (b (split-window a)))
    (unwind-protect
        (drgnx-guard-test--guarded
         (let ((moved nil))
           (drgnx-guard-test--from-timer
            (lambda () (drgnx-wb-with-owned-windows (list b) (set-window-start b 1) (set-window-point b 1))
              (setq moved t)))
           (should moved))                                   ; the moves ran (a timer error is silent)
         (should-not drgnx-jank-guard-log)
         (drgnx-guard-test--from-timer (lambda () (set-window-start b 1)))
         (should (= 1 (length drgnx-jank-guard-log))))
      (delete-other-windows))))
