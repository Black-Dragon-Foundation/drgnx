;;; history-perf-test.el --- batch tests: the drain tick does not grow with the buffer -*- lexical-binding: t -*-
;; The drain runs on the typing path (a 10 Hz timer): a large buffer is drained only when Emacs is idle, and the hash of
;; its whole text (the hub's check) is made by a worker over a copy, so it never sits between two keystrokes.  The
;; structure is asserted by counting (no clock): the det test below.  The time it takes is the timing lane's
;; (`test/timing-lane.sh`, the row `drgnx-history`): the second test only runs the 20 MB drain and prints the idle drain's
;; milliseconds, and the lane judges the run against the island's calibration.  Skips on a Nidhogg built without
;; `--with-nidhogg-history' (fails there under DRGNX_NIDHOGG_STRICT=1).
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'drgnx-history)

(ert-deftest drgnx-history/a-large-buffers-drain-hashes-on-a-worker-and-never-on-the-main-thread ()
  (drgnx-test-require-nidhogg (fboundp 'nidhogg-history-track) "nidhogg-history-track")
  (let ((b (generate-new-buffer "history-large")) (sent 0) (sync 0) (async nil)
        (drgnx-history-large-size 1000))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-history--send) (lambda (&rest _) (cl-incf sent) t))
                  ((symbol-function 'nidhogg-buffer-sha256) (lambda (&rest _) (cl-incf sync) "sync-hash"))
                  ((symbol-function 'nidhogg-buffer-sha256-async) (lambda (buf cb) (push (cons buf cb) async) t)))
          (with-current-buffer b (insert (make-string 5000 ?x)))
          (drgnx-history--adopt b "b-1")
          (with-current-buffer b (dotimes (i 10) (goto-char (+ 5 i)) (insert "y")))
          ;; not idle: a large buffer's ring waits, nothing hashed, nothing sent
          (drgnx-history--drain)
          (should (and (= sent 0) (= sync 0) (null async)))
          (should (nidhogg-history-pending-p))
          ;; idle: the changes are drained and the text goes to the worker; nothing is hashed here, nothing sent yet
          (cl-letf (((symbol-function 'drgnx-history--idle-time) (lambda () 1.0)))
            (drgnx-history--drain)
            (should (= (length async) 1))
            (should (eq (car (car async)) b))
            (should (= sync 0))
            (should (= sent 0))
            (should-not (nidhogg-history-pending-p))
            ;; the ring waits while the hash is out: a drain meanwhile asks for no second one
            (with-current-buffer b (goto-char 3) (insert "z"))
            (drgnx-history--drain)
            (should (= (length async) 1))
            ;; the hash lands: the batches go with it, and the change made meanwhile drains next
            (funcall (cdr (car async)) "worker-hash")
            (should (> sent 0))
            (should (= sync 0))
            (let ((before sent))
              (drgnx-history--drain)
              (should (= (length async) 2))
              (funcall (cdr (car async)) "worker-hash-2")
              (should (> sent before))
              (should (= sync 0)))))
      (drgnx-history--forget b)
      (kill-buffer b))))

(ert-deftest drgnx-history/a-small-buffer-hashes-at-once ()
  (drgnx-test-require-nidhogg (fboundp 'nidhogg-history-track) "nidhogg-history-track")
  (let ((b (generate-new-buffer "history-small")) (sent 0) (sync 0) (async nil))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-history--send) (lambda (&rest _) (cl-incf sent) t))
                  ((symbol-function 'nidhogg-buffer-sha256) (lambda (&rest _) (cl-incf sync) "sync-hash"))
                  ((symbol-function 'nidhogg-buffer-sha256-async) (lambda (&rest a) (push a async) t)))
          (with-current-buffer b (insert "short text"))
          (drgnx-history--adopt b "b-2")
          (with-current-buffer b (insert "!"))
          (drgnx-history--drain)
          (should (and (= sync 1) (null async) (> sent 0))))
      (drgnx-history--forget b)
      (kill-buffer b))))

(provide 'history-perf-test)
;;; history-perf-test.el ends here
