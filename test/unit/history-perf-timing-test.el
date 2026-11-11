;;; history-perf-timing-test.el --- timing lane: the drain of a 20 MB buffer -*- lexical-binding: t -*-
;; The 20 MB drain, run for the timing lane (`test/timing-lane.sh', the row `drgnx-history': the lane judges the run
;; against the island's calibration, not against a bound here).  It prints the idle drain's milliseconds (the copy of the
;; text for the worker; `secure-hash' of the same text took about 60 ms) and asserts nothing about a clock.  The
;; structure (a worker hashes, nothing is hashed on the main thread) is asserted by counting in history-perf-test.el.
;; test-class: timing
(require 'ert)
(require 'cl-lib)
(require 'drgnx-history)

(ert-deftest drgnx-history/the-20-mb-idle-drain-timing-run ()
  :tags '(:timing)
  (drgnx-test-require-nidhogg (fboundp 'nidhogg-history-track) "nidhogg-history-track")
  (let ((b (generate-new-buffer "history-huge")) (sent 0))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-history--send) (lambda (&rest _) (cl-incf sent) t)))
          (with-current-buffer b (insert (make-string (* 20 1024 1024) ?x)))
          (drgnx-history--adopt b "b-1")
          (with-current-buffer b (dotimes (i 10) (goto-char (+ 5 i)) (insert "y")))
          (let ((t0 (float-time)))
            (drgnx-history--drain)
            (message "history-huge: busy drain tick of 20 MB took %.2f ms" (* 1000 (- (float-time) t0))))
          (should (= sent 0))
          (let (idle-drain)
            (cl-letf (((symbol-function 'drgnx-history--idle-time) (lambda () 1.0)))
              (let ((t0 (float-time)))
                (drgnx-history--drain)
                (setq idle-drain (- (float-time) t0))))
            (message "history-huge: idle drain of 20 MB took %.1f ms" (* 1000 idle-drain)))
          (should (nidhogg-workers--test-await-landed 'nh-save 10000))
          (should (> sent 0))
          (should-not (nidhogg-history-pending-p)))
      (drgnx-history--forget b)
      (kill-buffer b))))

(provide 'history-perf-timing-test)
;;; history-perf-timing-test.el ends here
