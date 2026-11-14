;;; history-perf-test.el --- batch tests: the drain tick does not grow with the buffer -*- lexical-binding: t -*-
;; The drain runs on the typing path (a 10 Hz timer): its cost may not grow with the buffer.  A batch carries the hash
;; of the buffer's whole text (the hub's check) only up to `drgnx-history-large-size' bytes, where hashing costs at most a
;; millisecond; a larger buffer's batches carry none and go at once, at any size.  The structure is asserted by counting
;; (no clock) here; the time is the timing lane's (`test/timing-lane.sh', the row `drgnx-history',
;; history-perf-timing-test.el).  Skips on a Nidhogg built without `--with-nidhogg-history' (fails there under
;; DRGNX_NIDHOGG_STRICT=1).
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'drgnx-history)

(ert-deftest drgnx-history/a-large-buffers-drain-sends-at-once-and-hashes-nothing ()
  (drgnx-test-require-nidhogg (fboundp 'nidhogg-history-track) "nidhogg-history-track")
  (let ((b (generate-new-buffer "history-large")) (sent nil) (sync 0)
        (drgnx-history-large-size 1000))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-history--send) (lambda (_m params _cb) (push params sent) t))
                  ((symbol-function 'nidhogg-buffer-sha256) (lambda (&rest _) (cl-incf sync) "sync-hash")))
          (with-current-buffer b (insert (make-string 5000 ?x)))
          (drgnx-history--adopt b "b-1")
          (with-current-buffer b (dotimes (i 10) (goto-char (+ 5 i)) (insert "y")))
          ;; not idle, and the ring goes on this tick: no hash made, none sent
          (drgnx-history--drain)
          (should sent)
          (should (= sync 0))
          (should-not (seq-some (lambda (p) (plist-member p :region_hash)) sent))
          (should-not (nidhogg-history-pending-p)))
      (drgnx-history--forget b)
      (kill-buffer b))))

(ert-deftest drgnx-history/a-small-buffer-hashes-at-once ()
  (drgnx-test-require-nidhogg (fboundp 'nidhogg-history-track) "nidhogg-history-track")
  (let ((b (generate-new-buffer "history-small")) (sent 0) (sync 0))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-history--send) (lambda (&rest _) (cl-incf sent) t))
                  ((symbol-function 'nidhogg-buffer-sha256) (lambda (&rest _) (cl-incf sync) "sync-hash")))
          (with-current-buffer b (insert "short text"))
          (drgnx-history--adopt b "b-2")
          (with-current-buffer b (insert "!"))
          (drgnx-history--drain)
          (should (and (= sync 1) (> sent 0))))
      (drgnx-history--forget b)
      (kill-buffer b))))

(provide 'history-perf-test)
;;; history-perf-test.el ends here
