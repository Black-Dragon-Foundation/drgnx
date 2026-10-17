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

(ert-deftest drgnx-signal-edge/a-flush-with-many-buffers-is-cheap ()
  "M3d-8: a flush with 1500 file buffers takes under 10 ms — the best of five, so one slice of a
busy machine is not judged."
  :tags '(:timing)                                      ; a quiet machine: bin/drgnx check runs it alone
  (let ((drgnx-signal--subscribers nil) (drgnx-signal--state nil) (drgnx-signal-errors nil)
        (dir (make-temp-file "drgnx-signal-edge" t)))
    (unwind-protect
        (progn
          (dotimes (i 1500)
            (let ((f (expand-file-name (format "f%04d.txt" i) dir)))
              (write-region "x\n" nil f nil 'silent)
              (find-file-noselect f)))
          (drgnx-signal--flush)                       ; the starting state
          (should (< (cl-loop repeat 5
                              minimize (let ((t0 (float-time))) (drgnx-signal--flush) (- (float-time) t0)))
                     0.01)))
      (dolist (b (buffer-list))
        (when (and (buffer-file-name b) (string-prefix-p dir (buffer-file-name b))) (kill-buffer b)))
      (when (timerp drgnx-signal--timer) (cancel-timer drgnx-signal--timer))
      (delete-directory dir t))))

;;; wb-signal-edge-test.el ends here
