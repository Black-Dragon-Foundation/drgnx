;;; hub-chaos-fixture.el --- seeded answer delays per hub connection, for the pre-flight -*- lexical-binding: t -*-
;; With DRGNX_TEST_HUB_CHAOS=SEED (the pre-flight's P3-hub step sets it), every answer the hub sends on one connection
;; settles after that connection's own delay, drawn from SEED and the connection's number: none (a third of them) or
;; 10-200 ms.  A connection keeps its order; two connections do not keep theirs, as with a hub whose threads answer
;; them in any order.  CPU limits (P2) slow every connection alike, so an order such as "the subscribe connection is
;; answered after the test body started" needs this.  Without the variable nothing changes.  Loaded by wait-fixture.el.
(require 'cl-lib)

(defvar drgnx-test-hub-chaos--seed
  (let ((s (getenv "DRGNX_TEST_HUB_CHAOS"))) (and s (not (string-empty-p s)) s))
  "The seed (a string), or nil when hub chaos is off.")

(defvar drgnx-test-hub-chaos--count 0 "The hub connections given a delay so far in this Emacs.")

(defun drgnx-test-hub-chaos-draw (seed n)
  "The answer delay in seconds of the Nth hub connection under SEED: 0, or 0.010 to 0.200.  Same SEED, same N, same delay."
  (let ((h (abs (sxhash-equal (format "drgnx-hub-chaos/%s/%d" seed n)))))
    (if (zerop (% h 3)) 0 (/ (+ 10 (% (/ h 3) 191)) 1000.0))))

(defun drgnx-test-hub-chaos--delay (conn)
  "CONN's answer delay, drawn the first time it is asked for."
  (or (process-get conn :drgnx-test-chaos-delay)
      (let ((d (drgnx-test-hub-chaos-draw drgnx-test-hub-chaos--seed drgnx-test-hub-chaos--count)))
        (setq drgnx-test-hub-chaos--count (1+ drgnx-test-hub-chaos--count))
        (process-put conn :drgnx-test-chaos-delay d)
        d)))

(defun drgnx-test-hub-chaos--settle (orig id &rest args)
  "Around `drgnx-hub--settle': call ID's answer settles after its connection's delay."
  (let* ((entry (and (boundp 'drgnx-hub--pending) (gethash id drgnx-hub--pending)))
         (conn (plist-get entry :conn))
         (d (if (processp conn) (drgnx-test-hub-chaos--delay conn) 0)))
    (if (and (numberp d) (> d 0))
        (run-at-time d nil (lambda () (apply orig id args)))
      (apply orig id args))))

(when drgnx-test-hub-chaos--seed
  (message "drgnx test: hub chaos seed %s (replay: DRGNX_TEST_HUB_CHAOS=%s)" drgnx-test-hub-chaos--seed drgnx-test-hub-chaos--seed)
  (with-eval-after-load 'drgnx-hub-client
    (advice-add 'drgnx-hub--settle :around #'drgnx-test-hub-chaos--settle)))

(provide 'hub-chaos-fixture)
;;; hub-chaos-fixture.el ends here
