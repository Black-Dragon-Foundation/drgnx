;;; drgnx-palette.el --- The command palette -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Every available registry command by "Category: Title", with its key shown beside it;
;; choosing one runs it as if typed and shows the key tip.  Works with any completion UI.
;; Input starting with `#' is a Semantic Search question.  The completion UI does not require a match (an
;; orderless or other style may never offer `#words' as a candidate); the answer is resolved here.

;;; Code:
(require 'drgnx-registry)
(require 'drgnx-surfaces)
(require 'cl-lib)
(require 'subr-x)

(defun drgnx-palette-candidates ()
  "(LABEL . ID) for every command the palette offers, in registry order."
  (mapcar (lambda (c) (cons (drgnx-commands-label c) (drgnx-cmd-id c)))
          (seq-filter #'drgnx-surfaces--showable-p (drgnx-commands-all))))

(defun drgnx-palette--search (question)
  "Run Semantic Search for QUESTION; an empty one prompts for it."
  (let* ((cmd (drgnx-commands-get 'search-semantic))
         (fn (and cmd (drgnx-commands-available-p cmd) (drgnx-cmd-command cmd))))
    (unless fn (user-error "Semantic Search is not available (module tools/search)"))
    (if (string-empty-p question)
        (drgnx-surfaces-run 'search-semantic)
      (setq this-command fn)
      (funcall fn question))))

(defun drgnx-palette--complete (answer cands)
  "The labels of CANDS that ANSWER completes to under the current `completion-styles' (the way
`minibuffer-complete-and-exit' resolved a partial label when a match was required)."
  (let ((all (completion-all-completions answer (mapcar #'car cands) nil (length answer))))
    (when all (setcdr (last all) nil))     ; the last cdr holds the base size
    (mapcar #'substring-no-properties all)))

(defun drgnx-palette ()
  "Run any drgnx command by name; `#' followed by words is a Semantic Search.
The answer is resolved here, not by the completion UI (`require-match' is nil): a command label runs it;
text starting with `#' is a question; empty does nothing; a partial label that completes to one command
runs it; several is an \"Ambiguous\" error naming up to three; none is \"No command\"."
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
         (choice (string-trim (completing-read "Command (# for a code question): " table nil nil))))
    (cond ((string-empty-p choice))
          ((assoc choice cands) (drgnx-surfaces-run (cdr (assoc choice cands))))
          ((string-prefix-p "#" choice) (drgnx-palette--search (string-trim (substring choice 1))))
          (t (let ((labels (drgnx-palette--complete choice cands)))
               (pcase (length labels)
                 (0 (user-error "No command: %s" choice))
                 (1 (drgnx-surfaces-run (cdr (assoc (car labels) cands))))
                 (_ (user-error "Ambiguous: %s%s" (string-join (seq-take labels 3) ", ")
                                (if (> (length labels) 3) ", …" "")))))))))

(provide 'drgnx-palette)
;;; drgnx-palette.el ends here
