;;; history-perf-timing-test.el --- timing lane: the drain of a 20 MB buffer, and the hash at the limit -*- lexical-binding: t -*-
;; Run for the timing lane (`test/timing-lane.sh', the row `drgnx-history': the lane judges the run against the island's
;; calibration, not against a bound here; large files v2 stage 0's budgets are 2 ms for the huge drain and 1 ms for the
;; drain at the limit, judged pinned in the combined gate pass).  They print their milliseconds and assert nothing about
;; a clock.  The structure (no hash above the limit, the ring drained at once) is asserted by counting in
;; history-perf-test.el.
;; test-class: timing
(require 'ert)
(require 'cl-lib)
(require 'drgnx-history)

(ert-deftest drgnx-history/drain-tick-on-a-huge-buffer-is-cheap ()
  :tags '(:timing)
  (drgnx-test-require-nidhogg (fboundp 'nidhogg-history-track) "nidhogg-history-track")
  (let ((b (generate-new-buffer "history-huge")) (sent nil))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-history--send) (lambda (_m params _cb) (push params sent) t)))
          (with-current-buffer b (insert (make-string (* 20 1024 1024) ?x)))
          (drgnx-history--adopt b "b-1")
          (with-current-buffer b (dotimes (i 10) (goto-char (+ 5 i)) (insert "y")))
          (let ((t0 (float-time)))
            (drgnx-history--drain)
            (message "history-huge: drain tick of 20 MB took %.2f ms" (* 1000 (- (float-time) t0))))
          ;; sent on this tick, with no hash, nothing left in the ring: no idle time is faked
          (should sent)
          (should-not (seq-some (lambda (p) (plist-member p :region_hash)) sent))
          (should-not (nidhogg-history-pending-p)))
      (drgnx-history--forget b)
      (kill-buffer b))))

(ert-deftest drgnx-history/hash-at-the-limit-fits-a-millisecond ()
  :tags '(:timing)
  (drgnx-test-require-nidhogg (fboundp 'nidhogg-history-track) "nidhogg-history-track")
  (let ((b (generate-new-buffer "history-limit")) (hashed 0) (times nil))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-history--send)
                   (lambda (_m params _cb) (when (plist-get params :region_hash) (cl-incf hashed)) t)))
          (with-current-buffer b (insert (make-string (- drgnx-history-large-size 10) ?x)))
          (drgnx-history--adopt b "b-1")
          (dotimes (r 21)
            ;; 10 changes that leave the text at the limit: one in, then out again, and so on
            (with-current-buffer b
              (dotimes (i 10)
                (goto-char (+ 5 i))
                (if (cl-evenp r) (insert "y") (delete-char 1))))
            (let ((t0 (float-time)))
              (drgnx-history--drain)
              (push (* 1000 (- (float-time) t0)) times)))
          (should (= hashed 21))
          (message "history-limit: drain of 10 changes at %d bytes, hash included: median %.3f ms"
                   drgnx-history-large-size (nth 10 (sort times #'<))))
      (drgnx-history--forget b)
      (kill-buffer b))))

(provide 'history-perf-timing-test)
;;; history-perf-timing-test.el ends here
