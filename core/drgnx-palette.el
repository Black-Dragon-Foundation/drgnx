;;; drgnx-palette.el --- The command palette -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Every available registry command by "Category: Title", with its key shown beside it;
;; choosing one runs it as if typed and shows the key tip.  Works with any completion UI.

;;; Code:
(require 'drgnx-registry)
(require 'drgnx-surfaces)

(defun drgnx-palette-candidates ()
  "(LABEL . ID) for every command the palette offers, in registry order."
  (mapcar (lambda (c) (cons (drgnx-commands-label c) (drgnx-cmd-id c)))
          (seq-filter #'drgnx-surfaces--showable-p (drgnx-commands-all))))

(defun drgnx-palette ()
  "Run any drgnx command by name."
  (interactive)
  (let* ((cands (drgnx-palette-candidates))
         (annotate (lambda (label)
                     (when-let* ((c (drgnx-commands-get (cdr (assoc label cands)))))
                       (let ((key (drgnx-surfaces-key c)))
                         (concat (if (string-empty-p key) "" (concat "  " key))
                                 (if (drgnx-cmd-doc c) (concat "  — " (drgnx-cmd-doc c)) ""))))))
         (table (lambda (string pred action)
                  (if (eq action 'metadata)
                      `(metadata (annotation-function . ,annotate) (category . drgnx-command))
                    (complete-with-action action cands string pred))))
         (choice (completing-read "Command: " table nil t)))
    (when-let* ((id (cdr (assoc choice cands))))
      (drgnx-surfaces-run id))))

(provide 'drgnx-palette)
;;; drgnx-palette.el ends here
