;;; drgnx-work-start.el --- Starting a plan with a budget (library of tools/work-space) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Detail's Start (or `work-start-plan' on a plan's row) proposes the job (`job/propose'), asks the hub for its start step
;; (`forecast/start': the budget fields prefilled with the forecast's p90 rounded up in the plan's unit, % wk for
;; subscription tasks, usd for gateway tasks, both for a mixed one; the week warning; whether a task rests on the prior),
;; and shows it in `*Start plan*': the warning and the chips as lines, a field for each unit, and the keys: RET starts with
;; what the fields say (`job/approve' with the limits), M-RET starts with no budget (empty limits), Esc cancels the
;; start (the job stays proposed).  Nothing blocks a start for lack of a budget, and the week warning never blocks.
;; Loaded by tools/work-space (drgnx-work-space.el); defines no module.  See docs/develop/work-space.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)

(declare-function drgnx-hub-call "drgnx-hub-client")

(defvar-local drgnx-work-start--job nil "The proposed job this start step is for.")

(defvar drgnx-work-start-mode-map (make-sparse-keymap)
  "Keys of the start step (the key profiles bind them: RET starts, M-RET starts with no budget, Esc cancels).")

(define-derived-mode drgnx-work-start-mode text-mode "Start plan"
  "The start step of a proposed plan: its warnings, and a budget field for each unit."
  (buffer-disable-undo))

(defconst drgnx-work-start--labels '(("limit-share" . "% wk") ("usd" . "usd") ("tokens" . "tokens") ("count" . "count")))

(defun drgnx-work-start--shown (unit amount)
  (if (null amount) "" (format "%g" (if (equal unit "limit-share") (* 100 amount) amount))))

(defun drgnx-work-start--insert (view)
  "Draw VIEW (the `forecast/start' answer) in the current buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize "Start the plan\n\n" 'face 'bold 'read-only t 'rear-nonsticky t))
    (when-let* ((w (plist-get view :week_warning)))
      (insert (propertize (concat w "\n") 'face 'warning 'read-only t 'rear-nonsticky t)))
    (when (plist-get view :prior)
      (insert (propertize "from the prior: no history\n" 'face 'warning 'read-only t 'rear-nonsticky t)))
    (insert (propertize "\nBudget (empty: no limit on that unit)\n" 'read-only t 'rear-nonsticky t))
    (dolist (f (append (plist-get view :fields) nil))
      (let ((unit (plist-get f :unit)))
        (insert (propertize (format "  %-8s " (or (cdr (assoc unit drgnx-work-start--labels)) unit)) 'read-only t 'rear-nonsticky t))
        (insert (propertize (drgnx-work-start--shown unit (plist-get f :prefill)) 'drgnx-start-field unit))
        (when-let* ((note (plist-get f :note)))
          (insert (propertize (concat "  " note) 'read-only t 'rear-nonsticky t 'face 'shadow)))
        (insert (propertize "\n" 'read-only t))))
    (insert (propertize "\nRET starts with these limits · M-RET starts with no budget · Esc cancels\n" 'read-only t 'face 'shadow))))

(defun drgnx-work-start--field (unit)
  "The text of UNIT's field: (START . END)."
  (let ((m (text-property-search-forward 'drgnx-start-field unit #'equal)))
    (when m (cons (prop-match-beginning m) (prop-match-end m)))))

(defun drgnx-work-start--limits ()
  "The limits the fields say: ((:amount A :unit U)…), a share typed in percent; an empty field gives none."
  (let (out)
    (goto-char (point-min))
    (let (m)
      (while (setq m (text-property-search-forward 'drgnx-start-field nil (lambda (_ v) v)))
        (let* ((unit (prop-match-value m))
               (text (string-trim (buffer-substring-no-properties (prop-match-beginning m) (prop-match-end m)))))
          (unless (string-empty-p text)
            (let ((n (string-to-number text)))
              (push (list :amount (float (if (equal unit "limit-share") (/ n 100.0) n)) :unit unit) out))))))
    (nreverse out)))

(defvar drgnx-work-lens--map)
(defvar drgnx-work-map--selection)

(defun drgnx-work-start--plan-here ()
  "The plan on this row, or the plan selected in this view's map (Detail's Start button runs in the Detail)."
  (let ((id (or (get-text-property (pos-bol) 'drgnx-work-id)
                (and (boundp 'drgnx-work-lens--map) (buffer-live-p drgnx-work-lens--map)
                     (cdr-safe (buffer-local-value 'drgnx-work-map--selection drgnx-work-lens--map))))))
    (and (stringp id) (string-prefix-p "plan:" id) (substring id 5))))

(defun drgnx-work-start-plan (plan)
  "Propose PLAN (a row's id, `plan:ID', or the plan itself) and show its start step."
  (interactive (list (or (drgnx-work-start--plan-here) (user-error "Select a plan to start"))))
  (drgnx-hub-call "job/propose" (list :plan plan)
                  (lambda (job err)
                    (if err (message "Start: %s" err)
                      (let ((id (plist-get job :id)))
                        (drgnx-hub-call "forecast/start" (list :job id :utc_offset (car (current-time-zone)))
                                        (lambda (view err2)
                                          (if err2 (message "Start: %s" err2)
                                            (with-current-buffer (get-buffer-create "*Start plan*")
                                              (drgnx-work-start-mode)
                                              (setq drgnx-work-start--job id)
                                              (drgnx-work-start--insert view)
                                              (goto-char (point-min))
                                              (when-let* ((m (text-property-search-forward 'drgnx-start-field nil (lambda (_ v) v))))
                                                (goto-char (prop-match-beginning m)))
                                              (pop-to-buffer (current-buffer)))))))))))

(defun drgnx-work-start--approve (limits)
  (drgnx-hub-call "job/approve" (list :job drgnx-work-start--job :limits (vconcat limits)) #'ignore)
  (message "Start: the plan runs%s" (if limits "" " with no budget"))
  (quit-window t))

(defun drgnx-work-start-go ()
  "Start the plan with the limits the fields say (an empty field: no limit on that unit)."
  (interactive)
  (drgnx-work-start--approve (drgnx-work-start--limits)))

(defun drgnx-work-start-none ()
  "Start the plan with no budget."
  (interactive)
  (drgnx-work-start--approve nil))

(defun drgnx-work-start-cancel ()
  "Leave the start step; the job stays proposed."
  (interactive)
  (quit-window t))

(provide 'drgnx-work-start)
;;; drgnx-work-start.el ends here
