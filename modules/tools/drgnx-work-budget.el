;;; drgnx-work-budget.el --- Set a budget limit from a List row's meter (library of tools/work-space) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The hub draws each List row's meter (runtime/crates/drgnx-ratatoskr/src/work/map/list.rs) and gives it the text
;; property `drgnx-work-meter' (:item :unit :limit).  `$' (`work-budget-set') on the row opens a one-line `text-input'
;; prefilled with the limit and a unit chip that cycles the units a scope takes (% wk, usd, tokens, count).  RET sends
;; `budget/set' on the row's scope (a spec, plan or task by its own, an agent as a worker) with the scope's other units
;; kept; an empty field removes this unit's limit; Esc cancels.  Never a prompt, never a modal: the input is a small buffer
;; the way the review's request is.  A share is typed in percent of the week and sent as a fraction.
;; Loaded by tools/work-space (drgnx-work-space.el); defines no module.  See docs/develop/work-space.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)

(declare-function drgnx-hub-call "drgnx-hub-client")
(declare-function drgnx-ui-kit-text-input "drgnx-ui-kit")

(defconst drgnx-work-budget-units '("limit-share" "usd" "tokens" "count") "The units the editor cycles, in order.")
(defconst drgnx-work-budget--labels '(("limit-share" . "% wk") ("usd" . "usd") ("usd-est" . "usd") ("tokens" . "tokens") ("count" . "count")))

(defvar-local drgnx-work-budget--item nil "The row's item: `spec:ID', `plan:ID', `task:ID' or `agent:ID'.")
(defvar-local drgnx-work-budget--unit "usd" "The unit being edited.")

(defvar drgnx-work-budget-input-mode-map (make-sparse-keymap)
  "Keys of the limit input (the key profiles bind them: RET sends, Esc cancels, TAB cycles the unit).")

(define-derived-mode drgnx-work-budget-input-mode text-mode "Set budget"
  "The one-line input of a budget limit: the text is the limit, the header's chip its unit."
  (setq-local truncate-lines t))

(defun drgnx-work-budget--unit-label ()
  (or (cdr (assoc drgnx-work-budget--unit drgnx-work-budget--labels)) drgnx-work-budget--unit))

(defun drgnx-work-budget--scope (item)
  "The `budget/set' scope of ITEM (`KIND:ID'): a spec, plan or task by its own; an agent as a worker."
  (pcase (split-string item ":")
    (`("task" . ,rest) (list :task (string-join rest ":")))
    (`("plan" . ,rest) (list :plan (string-join rest ":")))
    (`("spec" . ,rest) (list :spec (string-join rest ":")))
    (`("agent" . ,rest) (list :worker (string-join rest ":")))
    (_ (user-error "No budget for %s" item))))

(defun drgnx-work-budget--shown (limit unit)
  "LIMIT as the field shows it: a share in percent, others as they are."
  (if (null limit) ""
    (format "%g" (if (equal unit "limit-share") (* 100 limit) limit))))

(defun drgnx-work-budget--header ()
  "The kit's text-input round the field, with the unit chip."
  (when (fboundp 'drgnx-ui-kit-text-input)
    (let ((lines (drgnx-ui-kit-text-input "limit" 'single
                                          (list (list (drgnx-work-budget--unit-label) 'neutral #'drgnx-work-budget-unit))
                                          (max 20 (window-width)) 'header-line t)))
      (concat (car (car lines)) (cdr (car lines))))))

(defun drgnx-work-budget-set ()
  "Set the budget limit of the row at point: a one-line input prefilled with its limit and a unit chip."
  (interactive)
  (let* ((meter (or (get-text-property (pos-bol) 'drgnx-work-meter) (user-error "This row has no budget")))
         (item (plist-get meter :item)) (unit (or (plist-get meter :unit) "usd")))
    (when (equal unit "usd-est") (setq unit "usd"))
    (with-current-buffer (get-buffer-create "*Set budget*")
      (drgnx-work-budget-input-mode)
      (setq drgnx-work-budget--item item drgnx-work-budget--unit unit)
      (insert (drgnx-work-budget--shown (plist-get meter :limit) unit))
      (setq header-line-format (drgnx-work-budget--header))
      (pop-to-buffer (current-buffer)))))

(defun drgnx-work-budget-unit ()
  "Cycle the unit: % wk, usd, tokens, count."
  (interactive)
  (let ((rest (cdr (member drgnx-work-budget--unit drgnx-work-budget-units))))
    (setq drgnx-work-budget--unit (or (car rest) (car drgnx-work-budget-units)))
    (setq header-line-format (drgnx-work-budget--header))
    (force-mode-line-update)))

(defun drgnx-work-budget-send ()
  "Send the limit: `budget/set' on the scope with its other units kept; an empty field removes this unit's limit."
  (interactive)
  (let* ((text (string-trim (buffer-substring-no-properties (point-min) (point-max))))
         (unit drgnx-work-budget--unit) (scope (drgnx-work-budget--scope drgnx-work-budget--item))
         (amount (and (not (string-empty-p text))
                      (let ((n (string-to-number text)))
                        (if (and (zerop n) (not (string-match-p "\\`[0.]+\\'" text))) (user-error "A limit is a number") n)))))
    (when amount (setq amount (float (if (equal unit "limit-share") (/ amount 100.0) amount))))
    (drgnx-hub-call "budget/get" (list :scope scope)
                    (lambda (result err)
                      (when err (user-error "Budget: %s" err))
                      (let ((limits (cl-remove-if (lambda (l) (equal (plist-get l :unit) unit))
                                                  (append (plist-get result :limits) nil))))
                        (when amount (setq limits (append limits (list (list :amount amount :unit unit)))))
                        (drgnx-hub-call "budget/set" (list :scope scope :limits (vconcat limits)) #'ignore)
                        (message "Budget: %s" (if amount "limit set" "limit removed")))))
    (quit-window t)))

(defun drgnx-work-budget-cancel ()
  "Drop the input; nothing is sent."
  (interactive)
  (quit-window t))

(provide 'drgnx-work-budget)
;;; drgnx-work-budget.el ends here
