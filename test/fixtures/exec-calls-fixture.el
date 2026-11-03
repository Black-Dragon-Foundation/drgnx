;;; exec-calls-fixture.el --- the hub's `exec/start' as a stub that records its params -*- lexical-binding: t -*-
;;
;; (drgnx-test-with-exec-calls VAR BODY...)  BODY with the hub stubbed: `exec/start' answers a job at once, `exec/get'
;;                                           its row; VAR holds the params of every `exec/start' BODY made (newest first),
;;                                           as the plist `drgnx-exec-start' sent (a key it did not send is absent).
;;
;; `drgnx-exec-start' itself runs, so a test sees exactly what a caller asks the hub for.
(require 'cl-lib)
(require 'drgnx-exec)

(defmacro drgnx-test-with-exec-calls (var &rest body)
  "Run BODY with the hub stubbed; VAR is bound to the list of `exec/start' params, newest first."
  (declare (indent 1))
  `(let ((,var nil) (drgnx-exec--jobs (make-hash-table :test #'equal)))
     (cl-letf (((symbol-function 'drgnx-hub--ensure-running) (lambda (callback) (funcall callback nil)))
               ((symbol-function 'drgnx-hub-call)
                (lambda (method params callback &rest _)
                  (when (equal method "exec/start") (push params ,var))
                  (funcall callback
                           (if (equal method "exec/start") (list :id "job-1" :text "job runs")
                             (list :id "job-1" :status "running" :name "x" :cwd "/"))
                           nil))))
       ,@body)))

(provide 'exec-calls-fixture)
;;; exec-calls-fixture.el ends here
