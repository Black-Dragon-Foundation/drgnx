;;; hub-chaos-fixture.el --- seeded delivery delays per hub connection, for the pre-flight -*- lexical-binding: t -*-
;; With DRGNX_TEST_HUB_CHAOS=SEED (the pre-flight's P3-hub step sets it), what the hub sends on one real connection
;; (`drgnx-hub--open') reaches the client after that connection's own delay, drawn from SEED and the connection's
;; number: none (a third of them) or 10-200 ms.  Its output and its end keep their order; two connections do not keep
;; theirs, as with a hub whose threads answer them in any order and a network that delivers them so.  The client's own
;; handling of what arrives is untouched.  CPU limits (P2) slow every connection alike, so an order such as "the
;; subscribe connection is answered after the test body started" needs this.  Without the variable nothing changes.
;; Loaded by wait-fixture.el.
(require 'cl-lib)

(defvar drgnx-test-hub-chaos--seed
  (let ((s (getenv "DRGNX_TEST_HUB_CHAOS"))) (and s (not (equal s "")) s))
  "The seed (a string), or nil when hub chaos is off.")

(defvar drgnx-test-hub-chaos--count 0 "The hub connections given a delay so far in this Emacs.")

(defun drgnx-test-hub-chaos-draw (seed n)
  "The delivery delay in seconds of the Nth hub connection under SEED: 0, or 0.010 to 0.200.  Same SEED, same N, same
delay."
  (let ((h (abs (sxhash-equal (format "drgnx-hub-chaos/%s/%d" seed n)))))
    (if (zerop (% h 3)) 0 (/ (+ 10 (% (/ h 3) 191)) 1000.0))))

(defun drgnx-test-hub-chaos--late (d)
  "Advice for a connection's filter or sentinel: it runs D seconds after the process calls it."
  (lambda (orig &rest args) (run-at-time d nil (lambda () (apply orig args)))))

(defun drgnx-test-hub-chaos--open (conn)
  "After `drgnx-hub--open': CONN's output and end reach the client after its delay."
  (when (processp conn)
    (let ((d (drgnx-test-hub-chaos-draw drgnx-test-hub-chaos--seed drgnx-test-hub-chaos--count)))
      (setq drgnx-test-hub-chaos--count (1+ drgnx-test-hub-chaos--count))
      (when (> d 0)
        (add-function :around (process-filter conn) (drgnx-test-hub-chaos--late d))
        (add-function :around (process-sentinel conn) (drgnx-test-hub-chaos--late d)))))
  conn)

(when drgnx-test-hub-chaos--seed
  (message "drgnx test: hub chaos seed %s (replay: DRGNX_TEST_HUB_CHAOS=%s)" drgnx-test-hub-chaos--seed drgnx-test-hub-chaos--seed)
  (with-eval-after-load 'drgnx-hub-client
    (advice-add 'drgnx-hub--open :filter-return #'drgnx-test-hub-chaos--open)))

(provide 'hub-chaos-fixture)
;;; hub-chaos-fixture.el ends here
