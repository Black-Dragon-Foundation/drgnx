;;; budgets-page-test.el --- the Budgets page: its command and keys, the limit cell, the selection (Flow Task 22c) -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: pure.  The rows are the hub's (view/budgets.rs, tested there: a run's share, the estimates); what stays
;; here is the editor's half: the place's command in every key profile, an edited limit cell asking `budget/set', and a
;; selected row selecting its node in Work.  The perf row `budget-page-open' is in perf-flow-test.el.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-hub-client)

(declare-function drgnx-budgets-set-limit "drgnx-budgets" (scope unit amount))
(declare-function drgnx-budgets-select "drgnx-budgets" (scope))

(ert-deftest drgnx-budgets-page/opens-from-every-profile-key ()
  "`budgets-open' has a key in each key profile (core-keys/budgets-open-in-every-profile)."
  (dolist (profile '("vscode" "emacs" "vim"))
    (let ((text (with-temp-buffer
                  (insert-file-contents (expand-file-name (format "keys/%s.eld" profile) drgnx-dir))
                  (buffer-string))))
      (should (string-match-p "(budgets-open " text)))))

(ert-deftest drgnx-budgets-page/limit-cell-edits-in-place ()
  "A limit cell's new amount asks `budget/set' for its scope with that one limit, and nothing else."
  (require 'drgnx-budgets)
  (let (calls)
    (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (method params &rest _) (push (cons method params) calls))))
      (drgnx-budgets-set-limit '("plan" "p1") "usd-est" 50.0))
    (should (equal "budget/set" (car (car calls))))
    (should (equal '(:plan "p1") (plist-get (cdr (car calls)) :scope)))
    (should (equal 50.0 (plist-get (aref (plist-get (cdr (car calls)) :limits) 0) :amount)))))

(ert-deftest drgnx-budgets-page/the-view-subscribes-on-the-events-connection ()
  "The page's `budgets/page/*' calls go on the events connection, where the hub sends the view's rows; on the call
connection a real hub never sends them."
  (require 'drgnx-budgets)
  (let ((drgnx-hub--events 'events) on)
    (cl-letf (((symbol-function 'process-live-p) (lambda (p) (eq p 'events)))
              ((symbol-function 'drgnx-hub-call) (lambda (&rest _) (error "Not on the call connection")))
              ((symbol-function 'drgnx-hub--call-on) (lambda (conn method &rest _) (push (cons conn method) on))))
      (drgnx-budgets--subscribe))
    (should (equal '((events . "budgets/page/subscribe")) on))))

(ert-deftest drgnx-budgets-page/selecting-selects-in-work ()
  "Selecting a scope's row selects its node in Work: a plan, a task or a run's job."
  (require 'drgnx-budgets)
  (let (picked)
    (cl-letf (((symbol-function 'drgnx-work-select) (lambda (kind id) (setq picked (list kind id)))))
      (drgnx-budgets-select '("plan" "p1")))
    (should (equal '("plan" "p1") picked))))

(provide 'budgets-page-test)
;;; budgets-page-test.el ends here
