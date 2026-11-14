;;; gated-hub-fixture.el --- a real hub inside the delivery gate, this Emacs connected -*- lexical-binding: t -*-
;;
;; (drgnx-test-with-gated-hub BODY...)  BODY on the manual clock with a gated Ratatoskr serving ROOT (`root' is bound)
;;                                      and this Emacs connected to it (the subscribed connection up); needs Sjá
;; (drgnx-test-hub-settle PRED WHAT)    wait until PRED holds: before each look the hub's clock moves past its
;;                                      throttles and what it wrote is released (`drgnx-test-hub-advance')
;;
;; For tests of a hub-fed panel whose rows the hub builds (the Buffers panel): nothing of the hub's side is stubbed.
;; The fixtures are the hub client tests' (hub-client-fixture.el); docs/develop/harness.md, "The delivery gate".
(require 'ert)
(require 'drgnx-hub-client)
(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (dolist (f '("wait-fixture" "ratatoskr-fixture" "delivery-gate-fixture" "runtime-settings-fixture"
               "hub-client-fixture" "clock-fixture"))
    (load (expand-file-name f dir) nil t)))

(defun drgnx-test-hub-settle (pred what)
  "Wait until PRED holds, the hub's clock moved by 100 ms and what it has written released before each look.  PRED's
value; WHAT names it in a failure."
  (drgnx-test-wait (lambda () (drgnx-test-hub-advance 100) (funcall pred)) :what what))

(defmacro drgnx-test-with-gated-hub (&rest body)
  "BODY with a gated hub this Emacs is connected to (`root' is the hub's root).  Skipped without Sjá or the hub."
  (declare (indent 0))
  `(progn
     (drgnx-test-require-nidhogg (fboundp 'nidhogg-view-push) "nidhogg-view-push")
     (drgnx-test-with-clock (:allow-pending t)
       (drgnx-hub-client-test--with-hub
         (let ((drgnx-test-gate-unnamed-ok t))   ; a thread's writes (a git status read) are held like the named ones
           (drgnx-test-gated '()
             (drgnx-hub-connect)
             (drgnx-test-hub-settle (lambda () (process-live-p drgnx-hub--events)) "the subscribed connection")
             ,@body))))))

(provide 'gated-hub-fixture)
;;; gated-hub-fixture.el ends here
