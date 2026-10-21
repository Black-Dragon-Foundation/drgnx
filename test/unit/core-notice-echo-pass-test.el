;;; core-notice-echo-pass-test.el --- batch tests: drgnx's automatic-path messages in core and wb are notices -*- lexical-binding: t -*-
;; Task 20 (N6).  One test per converted site that a stub can reach: the site's failure posts a notice and says
;; nothing in *Messages* under its own "drgnx" prefix.  The sites a stub cannot reach are held by the count lint
;; (lint-echo-test.el).  Prefixes `drgnx-notice-core/' and `drgnx-notice-wb/'.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-config)
(require 'drgnx-cockpit-model)
(require 'drgnx-agents)
(require 'drgnx-agents-mirror)
(require 'drgnx-modal-choose)
(require 'drgnx-platform)
(require 'drgnx-shell-env)
(load (expand-file-name "test/fixtures/notice-fixture" drgnx-dir) nil t)

(defmacro drgnx-notice-echo-pass-test--notice (source severity &rest body)
  "Run BODY on a fresh model, no *Messages* line starting \"drgnx\" allowed; then exactly one SOURCE notice of
SEVERITY must be there.  Returns it."
  (declare (indent 2))
  `(drgnx-notice-test-with-model
     (let ((said nil))
       (cl-letf (((symbol-function 'message)
                  (lambda (fmt &rest args)
                    (when (and (stringp fmt) (string-prefix-p "drgnx" fmt)) (push (apply #'format fmt args) said)))))
         ,@body)
       (should-not said)
       (let ((ns (drgnx-notices :source ,source)))
         (should (= (length ns) 1))
         (should (eq (plist-get (car ns) :severity) ,severity))
         (car ns)))))

(ert-deftest drgnx-notice-core/config-last-good-not-kept-is-a-notice ()
  (drgnx-notice-echo-pass-test--notice 'config 'warn
    (cl-letf (((symbol-function 'drgnx-config--good-file) (lambda (_d) "/nonexistent-dir/good"))
              ((symbol-function 'drgnx-file-read-bounded) (lambda (&rest _) (error "no disk"))))
      (drgnx-config--keep-good '(:file "x.eld") "(:a 1)"))))

(ert-deftest drgnx-notice-core/config-changed-function-failure-is-a-notice ()
  (drgnx-notice-echo-pass-test--notice 'config 'warn
    (let ((drgnx-config-changed-functions (list (lambda (_n) (error "Boom"))))
          (drgnx-config--in-changed nil))
      (drgnx-config--run-changed 'x))))

(ert-deftest drgnx-notice-core/config-after-save-failure-is-a-notice ()
  (drgnx-notice-echo-pass-test--notice 'config 'warn
    (let ((drgnx-config--visiting 'x))
      (cl-letf (((symbol-function 'drgnx-config-defined-p) (lambda (_n) t))
                ((symbol-function 'drgnx-config-reread) (lambda (_n) (error "Boom"))))
        (drgnx-config--after-save)))))

(ert-deftest drgnx-notice-core/cockpit-call-failure-is-a-notice ()
  (drgnx-notice-echo-pass-test--notice 'render 'warn
    (should-not (drgnx-cockpit--call (lambda () (error "Boom"))))))

(ert-deftest drgnx-notice-core/a-hub-call-error-on-an-agent-is-a-notice ()
  (drgnx-notice-echo-pass-test--notice 'agents 'warn
    (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (_m _p cb) (funcall cb nil "no such session"))))
      (drgnx-agents--remote (drgnx-agents--make :name "a1" :remote "r1") "stop" nil))))

(ert-deftest drgnx-notice-core/a-platform-callback-error-is-a-notice ()
  (drgnx-notice-echo-pass-test--notice 'guard 'warn
    (funcall (drgnx-platform--once (lambda (&rest _) (error "Boom"))))))

(ert-deftest drgnx-notice-core/a-shell-env-failure-is-a-notice ()
  (drgnx-notice-echo-pass-test--notice 'config 'warn
    (drgnx-shell-env--fail "it timed out")))

(ert-deftest drgnx-notice-core/a-pending-key-stack-failure-is-a-notice ()
  (drgnx-notice-echo-pass-test--notice 'keys 'warn
    (cl-letf (((symbol-function 'drgnx-modal--pending) (lambda () (error "Boom"))))
      (should-not (drgnx-modal-apply-pending)))))

(ert-deftest drgnx-notice-core/an-undecodable-hub-record-is-a-notice ()
  (drgnx-notice-echo-pass-test--notice 'hub 'warn
    (cl-letf (((symbol-function 'drgnx-records-from-json) (lambda (&rest _) (error "Boom"))))
      (should-not (drgnx-agents-mirror--decode nil nil)))))

(ert-deftest drgnx-notice-core/a-hub-of-another-layout-is-a-condition-that-clears ()
  (drgnx-notice-test-with-model
    (let ((drgnx-agents-mirror--paused nil))
      (drgnx-agents-mirror--skew nil (list :records (1+ drgnx-hub-records)))
      (let ((ns (drgnx-notices :source 'hub)))
        (should (= (length ns) 1))
        (should (eq (plist-get (car ns) :life) 'condition)))
      (drgnx-agents-mirror--skew nil (list :records drgnx-hub-records))
      (should-not (drgnx-notices :source 'hub)))))

(provide 'core-notice-echo-pass-test)
;;; core-notice-echo-pass-test.el ends here
