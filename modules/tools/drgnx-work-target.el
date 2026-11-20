;;; drgnx-work-target.el --- A spec's or plan's target date, set in Detail's field (library of tools/work-space) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Detail's Target field of a spec or a plan (timeline and budget spec §7.2): a date typed there is sent as
;; `work/target/set' (the item and the time in seconds), an empty field clears the target (null).  A task has no target.
;; Never a prompt: the command takes the item and the text.  Loaded by tools/work-space; defines no module.

;;; Code:
(require 'subr-x)

(declare-function drgnx-hub-call "drgnx-hub-client")

(defun drgnx-work-target-set (item text)
  "Set ITEM's (`spec:ID' or `plan:ID') target to the date TEXT (`2026-12-01', `2026-12-01 18:00'), or clear it when TEXT
is empty."
  (interactive (list (let ((id (get-text-property (pos-bol) 'drgnx-work-id))) (or id (user-error "Select a spec or a plan")))
                     (read-string "Target date (empty clears): ")))
  (unless (and (stringp item) (or (string-prefix-p "spec:" item) (string-prefix-p "plan:" item)))
    (user-error "A target is for a spec or a plan"))
  (let ((text (string-trim text)))
    (drgnx-hub-call "work/target/set"
                    (list :item item
                          :target_at (and (not (string-empty-p text))
                                          (float-time (date-to-time (if (string-match-p ":" text) text (concat text " 00:00:00"))))))
                    #'ignore)))

(provide 'drgnx-work-target)
;;; drgnx-work-target.el ends here
