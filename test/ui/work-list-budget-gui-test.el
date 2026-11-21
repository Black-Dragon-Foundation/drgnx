;;; work-list-budget-gui-test.el --- GUI tests: the limit editor of a List row's meter (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; The hub draws the List's meters (work/map/list.rs) and gives each row's meter `drgnx-work-meter' (item, unit, limit).
;; `$' (`work-budget-set') opens a one-line text input prefilled with the limit and a unit chip; RET sends `budget/set'
;; on the row's scope with the scope's other units kept, an empty field removes that unit's limit, the chip cycles the
;; units, Esc cancels.  Never a prompt, never a modal.  The hub is stubbed at `drgnx-hub-call'.

(require 'ert)
(require 'cl-lib)
(require 'drgnx-uitest)

(defconst drgnx-ui-work-budget--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "modules/tools"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-work-budget--repo)))
(require 'drgnx)
(require 'drgnx-ui-kit)
(require 'drgnx-work-budget)

(defmacro drgnx-ui-work-budget--with (calls row &rest body)
  "BODY with the hub stubbed (each call pushed on CALLS as (METHOD . PARAMS); `budget/get' answers the scope's limits: 15 %
of the week and 12 dollars) and the current buffer holding ROW's meter (a plist :item :unit :limit) on its first line."
  (declare (indent 2))
  `(let ((,calls nil))
     (skip-unless (display-graphic-p))
     (cl-letf (((symbol-function 'drgnx-hub-call)
                (lambda (method params &optional cb)
                  (push (cons method params) ,calls)
                  (when (and cb (equal method "budget/get"))
                    (funcall cb (list :scope (plist-get params :scope)
                                      :limits (vector (list :amount 0.15 :unit "limit-share") (list :amount 12.0 :unit "usd")))
                             nil))))
               ((symbol-function 'read-string) (lambda (&rest _) (error "A prompt: the editor never prompts")))
               ((symbol-function 'read-from-minibuffer) (lambda (&rest _) (error "A prompt: the editor never prompts")))
               ((symbol-function 'quit-window) #'ignore))
       (with-temp-buffer
         (insert (propertize "  Anchor the card  $9/$12\n" 'drgnx-work-id "task:t2" 'drgnx-work-meter ,row))
         (goto-char (point-min))
         (unwind-protect (progn ,@body)
           (when (get-buffer "*Set budget*") (kill-buffer "*Set budget*")))))))

(defun drgnx-ui-work-budget--set-calls (calls) (cl-remove-if-not (lambda (c) (equal (car c) "budget/set")) calls))

(ert-deftest drgnx-ui-work-list/meter-shows-spend-and-limit ()
  "`$' on a row opens the input prefilled with the limit, its unit chip showing the row's unit."
  (drgnx-ui-work-budget--with calls (list :item "task:t2" :unit "usd" :limit 12.0)
    (drgnx-work-budget-set)
    (with-current-buffer "*Set budget*"
      (should (derived-mode-p 'drgnx-work-budget-input-mode))
      (should (equal "12" (string-trim (buffer-substring-no-properties (point-min) (point-max)))))
      (should (equal "usd" (drgnx-work-budget--unit-label)))
      (should header-line-format))))

(ert-deftest drgnx-ui-work-list/dollar-edits-the-limit-in-place ()
  (drgnx-ui-work-budget--with calls (list :item "task:t2" :unit "usd" :limit 12.0)
    (drgnx-work-budget-set)
    (with-current-buffer "*Set budget*"
      (erase-buffer) (insert "20")
      (drgnx-work-budget-send))
    (let* ((set (car (drgnx-ui-work-budget--set-calls calls))) (p (cdr set)))
      (should set)
      (should (equal '(:task "t2") (plist-get p :scope)))
      (let ((limits (append (plist-get p :limits) nil)))
        ;; the new dollar limit, and the scope's other unit kept
        (should (member (list :amount 20.0 :unit "usd") limits))
        (should (member (list :amount 0.15 :unit "limit-share") limits))
        (should (= 2 (length limits)))))))

(ert-deftest drgnx-ui-work-list/empty-limit-clears-it ()
  (drgnx-ui-work-budget--with calls (list :item "task:t2" :unit "usd" :limit 12.0)
    (drgnx-work-budget-set)
    (with-current-buffer "*Set budget*"
      (erase-buffer)
      (drgnx-work-budget-send))
    (let ((limits (append (plist-get (cdr (car (drgnx-ui-work-budget--set-calls calls))) :limits) nil)))
      (should-not (cl-find "usd" limits :key (lambda (l) (plist-get l :unit)) :test #'equal))
      (should (member (list :amount 0.15 :unit "limit-share") limits)))))

(ert-deftest drgnx-ui-work-list/unit-chip-cycles-units ()
  "The chip cycles % wk, usd, tokens, count (a share is typed in percent and sent as a fraction)."
  (drgnx-ui-work-budget--with calls (list :item "plan:p1" :unit "limit-share" :limit 0.15)
    (drgnx-work-budget-set)
    (with-current-buffer "*Set budget*"
      (should (equal "% wk" (drgnx-work-budget--unit-label)))
      (should (equal "15" (string-trim (buffer-substring-no-properties (point-min) (point-max)))))
      (drgnx-work-budget-unit)
      (should (equal "usd" (drgnx-work-budget--unit-label)))
      (drgnx-work-budget-unit)
      (should (equal "tokens" (drgnx-work-budget--unit-label)))
      (drgnx-work-budget-unit)
      (should (equal "count" (drgnx-work-budget--unit-label)))
      (drgnx-work-budget-unit)
      (should (equal "% wk" (drgnx-work-budget--unit-label))))))

(ert-deftest drgnx-ui-work-list/a-share-is-typed-in-percent-and-sent-as-a-fraction ()
  (drgnx-ui-work-budget--with calls (list :item "plan:p1" :unit "limit-share" :limit 0.15)
    (drgnx-work-budget-set)
    (with-current-buffer "*Set budget*" (erase-buffer) (insert "20") (drgnx-work-budget-send))
    (let ((limits (append (plist-get (cdr (car (drgnx-ui-work-budget--set-calls calls))) :limits) nil)))
      (should (member (list :amount 0.2 :unit "limit-share") limits)))))

(ert-deftest drgnx-ui-work-list/escape-cancels-and-sends-nothing ()
  (drgnx-ui-work-budget--with calls (list :item "task:t2" :unit "usd" :limit 12.0)
    (drgnx-work-budget-set)
    (with-current-buffer "*Set budget*" (insert "9") (drgnx-work-budget-cancel))
    (should-not (drgnx-ui-work-budget--set-calls calls))))

(provide 'work-list-budget-gui-test)
;;; work-list-budget-gui-test.el ends here
