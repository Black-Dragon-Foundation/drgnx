;;; drgnx-editing.el --- Module editor/editing: folding, case, selection -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Editing commands people expect from VS Code, on built-ins: fold and unfold (hideshow in code,
;; outline elsewhere), change case (camelCase, snake_case, kebab-case, cycle), expand and shrink
;; the selection (tree-sitter nodes when the buffer has a parser, else words and balanced
;; expressions), go to line.  See docs/modules.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'hideshow)
(require 'outline)
(require 'drgnx-modules)
(require 'drgnx-registry)
(declare-function treesit-node-on "treesit.c")
(declare-function treesit-node-start "treesit.c")
(declare-function treesit-node-end "treesit.c")
(declare-function treesit-node-parent "treesit.c")

;;;; Fold

(defun drgnx-editing-fold ()
  "Fold the block at point (code: the definition or block; text: the section)."
  (interactive)
  (if (derived-mode-p 'prog-mode)
      (progn (unless hs-minor-mode (hs-minor-mode 1)) (hs-hide-block))
    (unless outline-minor-mode (outline-minor-mode 1))
    (outline-hide-subtree)))

(defun drgnx-editing-unfold ()
  "Unfold the block at point."
  (interactive)
  (if (derived-mode-p 'prog-mode)
      (progn (unless hs-minor-mode (hs-minor-mode 1)) (hs-show-block))
    (unless outline-minor-mode (outline-minor-mode 1))
    (outline-show-subtree)))

;;;; Case

(defun drgnx-editing--words (s)
  "S split into lower-case words: fooBar, foo_bar, foo-bar, HTTPServer → (\"foo\" \"bar\") …"
  (let ((case-fold-search nil))
    (setq s (replace-regexp-in-string "\\([[:lower:][:digit:]]\\)\\([[:upper:]]\\)" "\\1 \\2" s))
    (setq s (replace-regexp-in-string "\\([[:upper:]]+\\)\\([[:upper:]][[:lower:]]\\)" "\\1 \\2" s))
    (mapcar #'downcase (split-string s "[-_ ]+" t))))

(defun drgnx-editing--convert (s style)
  "S in STYLE: `camel', `snake' or `kebab'."
  (let ((w (drgnx-editing--words s)))
    (pcase style
      ('camel (concat (car w) (mapconcat #'capitalize (cdr w) "")))
      ('snake (string-join w "_"))
      ('kebab (string-join w "-")))))

(defun drgnx-editing--bounds ()
  (if (use-region-p) (cons (region-beginning) (region-end)) (bounds-of-thing-at-point 'symbol)))

(defun drgnx-editing--case (style)
  (when-let* ((b (drgnx-editing--bounds)))
    (let ((pt (point)) (new (drgnx-editing--convert (buffer-substring-no-properties (car b) (cdr b)) style)))
      (save-excursion (goto-char (car b)) (delete-region (car b) (cdr b)) (insert new))
      (goto-char (min pt (+ (car b) (length new)))))))

(defun drgnx-editing-case-camel () "Change the word to camelCase." (interactive) (drgnx-editing--case 'camel))
(defun drgnx-editing-case-snake () "Change the word to snake_case." (interactive) (drgnx-editing--case 'snake))
(defun drgnx-editing-case-kebab () "Change the word to kebab-case." (interactive) (drgnx-editing--case 'kebab))

(defun drgnx-editing-case-cycle ()
  "Cycle the word through camelCase → snake_case → kebab-case."
  (interactive)
  (when-let* ((b (drgnx-editing--bounds)))
    (let ((s (buffer-substring-no-properties (car b) (cdr b))))
      (drgnx-editing--case (cond ((string-search "_" s) 'kebab) ((string-search "-" s) 'camel) (t 'snake))))))

;;;; Expand / shrink the selection

(defvar-local drgnx-editing--expansions nil "Selections before each expansion (for shrinking).")

(defun drgnx-editing--select (beg end)
  (goto-char beg) (push-mark end t t) (activate-mark))

(defun drgnx-editing--next-region (beg end)
  "The smallest region strictly around BEG..END, or nil."
  (if (and (fboundp 'treesit-parser-list) (treesit-parser-list))
      (let ((node (treesit-node-on beg end)))
        (while (and node (<= (- (treesit-node-end node) (treesit-node-start node)) (- end beg)))
          (setq node (treesit-node-parent node)))
        (and node (cons (treesit-node-start node) (treesit-node-end node))))
    (or (and (= beg end) (bounds-of-thing-at-point 'symbol))
        (save-excursion
          (goto-char beg)
          (when (ignore-errors (backward-up-list 1 t t) t)
            (let ((s (point)))
              (forward-sexp 1)
              (cons s (point))))))))

(defun drgnx-editing-expand ()
  "Select a bit more: the word, then the enclosing expression, and so on."
  (interactive)
  (let* ((beg (if (use-region-p) (region-beginning) (point))) (end (if (use-region-p) (region-end) (point)))
         (next (drgnx-editing--next-region beg end)))
    (when next
      (push (cons beg end) drgnx-editing--expansions)
      (drgnx-editing--select (car next) (cdr next)))))

(defun drgnx-editing-shrink ()
  "Select what was selected before the last expansion."
  (interactive)
  (when-let* ((prev (pop drgnx-editing--expansions)))
    (if (= (car prev) (cdr prev)) (progn (deactivate-mark) (goto-char (car prev)))
      (drgnx-editing--select (car prev) (cdr prev)))))

(drgnx-module-define 'editor/editing
  :doc "Fold, change case, expand and shrink the selection, go to line."
  :stage 'startup
  :setup
  (lambda ()
    (pcase-dolist (`(,id ,title ,fn ,doc)
                   '((edit-fold "Fold" drgnx-editing-fold "Fold the block at point")
                     (edit-unfold "Unfold" drgnx-editing-unfold "Unfold the block at point")
                     (edit-case-cycle "Change Case: Cycle" drgnx-editing-case-cycle "camelCase → snake_case → kebab-case")
                     (edit-case-camel "Change Case: camelCase" drgnx-editing-case-camel "The word or selection in camelCase")
                     (edit-case-snake "Change Case: snake_case" drgnx-editing-case-snake "The word or selection in snake_case")
                     (edit-case-kebab "Change Case: kebab-case" drgnx-editing-case-kebab "The word or selection in kebab-case")
                     (edit-expand "Expand Selection" drgnx-editing-expand "Select the enclosing word, then expression, …")
                     (edit-shrink "Shrink Selection" drgnx-editing-shrink "Back to the previous selection")
                     (go-line "Go to Line…" goto-line "Go to a line number")))
      (drgnx-command-define id :category "Edit" :title title :command fn :scope 'editing :doc doc))))

(provide 'drgnx-editing)
;;; drgnx-editing.el ends here
