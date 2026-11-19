;;; work-start-plan-gui-test.el --- GUI tests: starting a plan with a budget (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; Detail's Start proposes the job, asks the hub for the start step (`forecast/start') and shows it: the budget field
;; prefilled with the p90 rounded up, the week warning that never blocks, the prior's chip.  RET starts with the fields'
;; limits (`job/approve'), M-RET with none.  The hub is stubbed at `drgnx-hub-call'.

(require 'ert)
(require 'cl-lib)
(require 'drgnx-uitest)

(defconst drgnx-ui-work-start--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "modules/tools"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-work-start--repo)))
(require 'drgnx)
(require 'drgnx-work-start)

(defmacro drgnx-ui-work-start--with (view calls &rest body)
  "BODY with the hub stubbed: `job/propose' answers job J1, `forecast/start' VIEW; each call is pushed on CALLS."
  (declare (indent 2))
  `(let ((,calls nil))
     (skip-unless (display-graphic-p))
     (cl-letf (((symbol-function 'drgnx-hub-call)
                (lambda (method params &optional cb)
                  (push (cons method params) ,calls)
                  (when cb
                    (pcase method
                      ("job/propose" (funcall cb (list :id "J1") nil))
                      ("forecast/start" (funcall cb ,view nil))))))
               ((symbol-function 'quit-window) #'ignore))
       (unwind-protect (progn (drgnx-work-start-plan "p1") (with-current-buffer "*Start plan*" ,@body))
         (when (get-buffer "*Start plan*") (kill-buffer "*Start plan*"))))))

(defun drgnx-ui-work-start--approve (calls) (cdr (cl-find "job/approve" calls :key #'car :test #'equal)))

(ert-deftest drgnx-ui-work-start-plan/start-with-the-prefilled-share ()
  (drgnx-ui-work-start--with (list :fields (vector (list :unit "limit-share" :prefill 0.14)) :prior nil) calls
    (should (string-search "14" (buffer-string)))
    (drgnx-work-start-go)
    (let ((a (drgnx-ui-work-start--approve calls)))
      (should (equal "J1" (plist-get a :job)))
      (should (equal (vector (list :amount 0.14 :unit "limit-share")) (plist-get a :limits))))))

(ert-deftest drgnx-ui-work-start-plan/start-with-no-budget-sets-none ()
  (drgnx-ui-work-start--with (list :fields (vector (list :unit "usd" :prefill 31.0))) calls
    (drgnx-work-start-none)
    (should (equal [] (plist-get (drgnx-ui-work-start--approve calls) :limits)))))

(ert-deftest drgnx-ui-work-start-plan/an-empty-field-is-no-limit-and-never-blocks ()
  (drgnx-ui-work-start--with (list :fields (vector (list :unit "usd" :prefill 31.0))) calls
    (let ((inhibit-read-only t))
      (let ((m (text-property-search-forward 'drgnx-start-field "usd" #'equal)))
        (delete-region (prop-match-beginning m) (prop-match-end m))))
    (drgnx-work-start-go)
    (should (equal [] (plist-get (drgnx-ui-work-start--approve calls) :limits)))))

(ert-deftest drgnx-ui-work-start-plan/week-warning-never-blocks ()
  (drgnx-ui-work-start--with (list :fields (vector (list :unit "limit-share" :prefill 0.7))
                                   :week_warning "\N{WARNING SIGN} at p90 the week runs out Thu 14:00") calls
    (should (string-search "at p90 the week runs out Thu 14:00" (buffer-string)))
    (drgnx-work-start-go)
    (should (drgnx-ui-work-start--approve calls))))

(ert-deftest drgnx-ui-work-start-plan/prior-basis-shows-its-chip ()
  (drgnx-ui-work-start--with (list :fields (vector (list :unit "usd" :prefill 3.0)) :prior t) calls
    (should (string-search "from the prior: no history" (buffer-string)))))

(ert-deftest drgnx-ui-work-start-plan/no-pace-yet-leaves-the-field-empty-and-says-why ()
  (drgnx-ui-work-start--with (list :fields (vector (list :unit "limit-share" :note "no pace yet: there is no share to forecast"))) calls
    (should (string-search "no pace yet" (buffer-string)))
    (drgnx-work-start-go)
    (should (equal [] (plist-get (drgnx-ui-work-start--approve calls) :limits)))))

(provide 'work-start-plan-gui-test)
;;; work-start-plan-gui-test.el ends here
