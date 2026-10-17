;;; drgnx-palette.el --- The command palette -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Every available registry command by "Category: Title", with its key shown beside it;
;; choosing one runs it as if typed and shows the key tip.  Works with any completion UI.
;; Input starting with `#' (and not the start of a command label) is a Semantic Search question: the table
;; accepts it as typed, so completion still requires a match for everything else.

;;; Code:
(require 'drgnx-registry)
(require 'drgnx-surfaces)
(require 'cl-lib)
(require 'subr-x)

(defun drgnx-palette-candidates ()
  "(LABEL . ID) for every command the palette offers, in registry order."
  (mapcar (lambda (c) (cons (drgnx-commands-label c) (drgnx-cmd-id c)))
          (seq-filter #'drgnx-surfaces--showable-p (drgnx-commands-all))))

(defun drgnx-palette--question (string cands)
  "The question in STRING when it is a `#' query — it starts with `#' and no command label does — else nil.
The question is the text after the `#', trimmed (possibly empty)."
  (and (string-prefix-p "#" string)
       (not (cl-some (lambda (c) (string-prefix-p string (car c))) cands))
       (string-trim (substring string 1))))

(defun drgnx-palette--search (question)
  "Run Semantic Search for QUESTION; an empty one prompts for it."
  (let* ((cmd (drgnx-commands-get 'search-semantic))
         (fn (and cmd (drgnx-commands-available-p cmd) (drgnx-cmd-command cmd))))
    (unless fn (user-error "Semantic Search is not available (module tools/search)"))
    (if (string-empty-p question)
        (drgnx-surfaces-run 'search-semantic)
      (setq this-command fn)
      (funcall fn question))))

(defun drgnx-palette ()
  "Run any drgnx command by name; `#' followed by words is a Semantic Search."
  (interactive)
  (let* ((cands (drgnx-palette-candidates))
         (annotate (lambda (label)
                     (when-let* ((c (drgnx-commands-get (cdr (assoc label cands)))))
                       (let ((key (drgnx-surfaces-key c)))
                         (concat (if (string-empty-p key) "" (concat "  " key))
                                 (if (drgnx-cmd-doc c) (concat "  — " (drgnx-cmd-doc c)) ""))))))
         (table (lambda (string pred action)
                  (cond ((eq action 'metadata)
                         `(metadata (annotation-function . ,annotate) (category . drgnx-command)))
                        ((drgnx-palette--question string cands)
                         (complete-with-action action (list string) string pred))
                        (t (complete-with-action action cands string pred)))))
         (choice (completing-read "Command: " table nil t)))
    (if-let* ((id (cdr (assoc choice cands))))
        (drgnx-surfaces-run id)
      (when-let* ((question (drgnx-palette--question choice cands)))
        (drgnx-palette--search question)))))

(provide 'drgnx-palette)
;;; drgnx-palette.el ends here
