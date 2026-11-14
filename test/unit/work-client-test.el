;;; work-client-test.el --- the Work map client: its views, their subscriptions and their status -*- lexical-binding: t -*-
;; test-class: det
;; `core/drgnx-work-client.el' keeps the map views this Emacs subscribed and calls the hub for them; the hub's rows
;; come as patches, so nothing here holds a frame.  The calls are caught at `drgnx-work-client--call' (the hub is
;; another process); the answers are given by hand, in the order the test names.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-work-client)

(defmacro drgnx-work-client-test--with (&rest body)
  "Run BODY with no views, the hub's calls caught in `asked' ((METHOD PARAMS CALLBACK) …, newest first) and the
status changes in `said' ((VIEW . STATUS) …, newest first)."
  (declare (indent 0))
  `(let ((drgnx-work-client--views (make-hash-table :test #'equal)) (asked nil) (said nil))
     (cl-letf (((symbol-function 'drgnx-work-client--call)
                (lambda (method params callback) (push (list method params callback) asked) t)))
       (let ((drgnx-work-client-status-functions (list (lambda (view status) (push (cons view status) said)))))
         ,@body))))

(ert-deftest drgnx-work-client/open-asks-for-the-hubs-rows ()
  (drgnx-work-client-test--with
    (drgnx-work-client-open "v1" '(:id "workspace:abc" :roots ("/r/")) :width 100 :density "roomy")
    (pcase-let ((`(,method ,params ,_) (car asked)))
      (should (equal "work/map/subscribe" method))
      (should (equal "v1" (plist-get params :view)))
      ;; the hub has only rows views: it refuses a field it does not know
      (should-not (plist-member params :rows))
      (should (equal 100 (plist-get params :width_units)))
      (should (equal "roomy" (plist-get params :density))))
    (should (equal "subscribing" (drgnx-work-client-status "v1")))))

(ert-deftest drgnx-work-client/a-stale-answer-says-nothing ()
  ;; the view subscribed again (a reconnect) before the first answer came: only the second answer counts
  (drgnx-work-client-test--with
    (drgnx-work-client-open "v1" '(:id "w" :roots ("/r/")))
    (let ((first (nth 2 (car asked))))
      (drgnx-work-client-connected)
      (funcall first nil "gone")
      (should (equal "subscribing" (drgnx-work-client-status "v1")))
      (funcall (nth 2 (car asked)) '(:ok t) nil)
      (should (equal "live" (drgnx-work-client-status "v1")))
      (should (equal '(("v1" . "live")) said)))))

(ert-deftest drgnx-work-client/set-keeps-the-saved-params-for-the-next-subscription ()
  (drgnx-work-client-test--with
    (drgnx-work-client-open "v1" '(:id "w" :roots ("/r/")))
    (drgnx-work-client-set "v1" :outline "on" :shown :false)
    (should (equal "work/map/set" (car (car asked))))
    (should-not (drgnx-work-client-shown-p "v1"))
    ;; a hidden view's answer says hidden; the next subscription carries the outline and not :shown
    (drgnx-work-client-connected)
    (let ((params (nth 1 (car asked))))
      (should (equal "on" (plist-get params :outline)))
      (should-not (plist-member params :shown)))
    (funcall (nth 2 (car asked)) '(:ok t) nil)
    (should (equal "hidden" (drgnx-work-client-status "v1")))))

(ert-deftest drgnx-work-client/disconnect-and-close ()
  (drgnx-work-client-test--with
    (drgnx-work-client-open "v1" '(:id "w" :roots ("/r/")))
    (funcall (nth 2 (car asked)) '(:ok t) nil)
    (drgnx-work-client-disconnected)
    (should (equal "reconnecting" (drgnx-work-client-status "v1")))
    (let ((pending (progn (drgnx-work-client-connected) (nth 2 (car asked)))))
      (should (drgnx-work-client-close "v1"))
      (should (equal "work/map/close" (car (car asked))))
      (should-not (drgnx-work-client-views))
      ;; the answer to a closed view's subscription goes nowhere
      (funcall pending '(:ok t) nil)
      (should-not (drgnx-work-client-status "v1")))))

(provide 'work-client-test)
;;; work-client-test.el ends here
