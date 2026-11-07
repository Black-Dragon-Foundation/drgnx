;;; history-perf-test.el --- batch tests: the drain tick does not grow with the buffer -*- lexical-binding: t -*-
;; The drain runs on the typing path (a 10 Hz timer): a tick may not cost more than a fixed bound however large the
;; buffer is.  A large buffer is drained only when Emacs is idle, so the hash of its whole text (the hub's check) never
;; sits between two keystrokes.  Skips on a Nidhogg built without `--with-nidhogg-history'
;; (fails there under DRGNX_NIDHOGG_STRICT=1).
;; test-class: timing
(require 'ert)
(require 'cl-lib)
(require 'drgnx-history)

(ert-deftest drgnx-history/drain-tick-on-a-huge-buffer-is-cheap ()
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
            (should (< (- (float-time) t0) 0.002)))
          ;; typing is not stalled, and nothing is lost: the changes go once Emacs is idle
          (should (= sent 0))
          (should (nidhogg-history-pending-p))
          (cl-letf (((symbol-function 'drgnx-history--idle-time) (lambda () 1.0)))
            (drgnx-history--drain))
          (should (> sent 0))
          (should-not (nidhogg-history-pending-p)))
      (drgnx-history--forget b)
      (kill-buffer b))))

(provide 'history-perf-test)
;;; history-perf-test.el ends here
