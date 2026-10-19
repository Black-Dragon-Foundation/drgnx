;;; drgnx-sticky.el --- Module editor/sticky: sticky scroll — the scopes scrolled past, after the breadcrumb -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Like VS Code's sticky scroll: when the start of the function (class, block) you are in has scrolled off the top,
;; its first line shows in the header, after the breadcrumb — up to three enclosing scopes, outermost first, one
;; line (`a › b › c').  The header line is always there (the breadcrumb), so nothing shifts as you scroll.  Scopes
;; come from tree-sitter when the buffer has a parser (functions, classes, …), else from indentation.  Each window
;; start is worked out once (a memo, rebuilt when the start moves or the text above it changes).  drgnx's own; no package.  See docs/guide/editing.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-memo)

(defvar drgnx-chrome-header-tail)
(declare-function drgnx-chrome-apply "drgnx-chrome")
(declare-function treesit-parser-list "treesit.c")
(declare-function treesit-node-at "treesit")
(declare-function treesit-node-parent "treesit.c")
(declare-function treesit-node-type "treesit.c")
(declare-function treesit-node-start "treesit.c")

(defvar drgnx-sticky-max 3 "Scopes shown at most (the outermost).")

(defvar drgnx-sticky-node-types
  '("function_definition" "function_declaration" "function_item" "function_expression" "function" "arrow_function"
    "generator_function_declaration" "method_definition" "method_declaration" "method" "singleton_method"
    "constructor_declaration" "class_definition" "class_declaration" "abstract_class_declaration" "class_specifier"
    "class" "struct_specifier" "struct_item" "impl_item" "trait_item" "mod_item" "module" "namespace_definition"
    "internal_module" "interface_declaration" "enum_declaration" "enum_item" "enum_specifier" "object_declaration"
    "type_declaration")
  "Tree-sitter node types that are scopes (never the root node: python's is `module').")

(defvar drgnx-sticky-scan-chars 300000 "How far back (characters) the indentation fallback looks for a scope.")

(defface drgnx-sticky '((t :inherit drgnx-wb-bar)) "Sticky scroll's scopes in the header line." :group 'drgnx)

(defun drgnx-sticky--line-indent ()
  "The current line's indentation, or nil when it is blank."
  (save-excursion (back-to-indentation) (unless (eolp) (current-indentation))))

(defun drgnx-sticky--treesit-scopes (pos)
  (let ((node (treesit-node-at (save-excursion (goto-char pos) (back-to-indentation) (point)))) (bol (save-excursion (goto-char pos) (line-beginning-position))) out)
    (while node
      (when (and (treesit-node-parent node)                        ; the root is the file, not a scope
                 (member (treesit-node-type node) drgnx-sticky-node-types)
                 (< (treesit-node-start node) bol))
        (push (save-excursion (goto-char (treesit-node-start node)) (line-beginning-position)) out))
      (setq node (treesit-node-parent node)))
    out))

(defun drgnx-sticky--skip-line-p ()
  "Is this line no scope: a comment, a preprocessor line (`#'), or a line inside a string or comment?"
  (save-excursion
    (back-to-indentation)
    (or (eq (char-after) ?#)
        (let ((s (syntax-ppss))) (or (nth 3 s) (nth 4 s)))
        (let ((p (point))) (forward-comment 1) (> (point) p)))))

(defun drgnx-sticky--indent-scopes (pos)
  "Line starts of the lines above POS's that open its indentation levels, outermost first.  One regexp search per
level (not a walk over every line), at most `drgnx-sticky-scan-chars' back."
  (save-excursion
    (goto-char pos)
    (beginning-of-line)
    (let ((indent (or (drgnx-sticky--line-indent)                 ; a blank line: the next line's level
                      (save-excursion (and (zerop (forward-line 1)) (drgnx-sticky--line-indent)))
                      0))
          (limit (max (point-min) (- pos drgnx-sticky-scan-chars)))
          out)
      (while (and (> indent 0) (not (bobp))
                  (progn (backward-char)                         ; the line above
                         (re-search-backward (format "^[ \t]\\{0,%d\\}[^ \t\n]" (1- indent)) limit t)))
        (let ((i (current-indentation)))                         ; a tab counts as its width: checked again here
          (when (and (< i indent) (not (drgnx-sticky--skip-line-p)))
            (push (line-beginning-position) out)
            (setq indent i))))
      out)))

(defun drgnx-sticky-scopes (pos)
  "Line starts of the scopes that enclose POS's line and start above it, outermost first."
  (if (and (fboundp 'treesit-parser-list) (treesit-parser-list))
      (drgnx-sticky--treesit-scopes pos)
    (drgnx-sticky--indent-scopes pos)))

(defun drgnx-sticky--text (start)
  "The line at START, as the buffer shows it, trimmed."
  (save-excursion
    (goto-char start)
    (let ((end (line-end-position)))
      (when (fboundp 'font-lock-ensure) (ignore-errors (font-lock-ensure start end)))
      (string-trim (buffer-substring (progn (back-to-indentation) (point)) end)))))

(drgnx-epoch-define 'sticky :per 'buffer
                    :doc "Raised by an edit at or above a window's start in the buffer (its scopes may have changed).")

(drgnx-memo-define sticky-segment :on window
                   :keys ((window-start object) (window-buffer object) (drgnx-epoch 'sticky (window-buffer object)))
                   :doc "A window's sticky part of the header, until its start moves, it shows another buffer or the text above changes.")

(defun drgnx-sticky--after-change (beg _end _len)
  "`after-change-functions': an edit above the top of a window showing this buffer changes its scopes."
  (when (seq-some (lambda (w) (<= beg (window-start w))) (get-buffer-window-list nil nil t))
    (drgnx-epoch-bump 'sticky (current-buffer))))

(defun drgnx-sticky--segment (w)
  "Window W's sticky part of the header: \" › SCOPE › …\" for its start, or \"\" (the memo `sticky-segment': built
again only when the start moves or the text above it changes)."
  (drgnx-memo sticky-segment w
              (with-current-buffer (window-buffer w)
                (let* ((scopes (seq-take (drgnx-sticky-scopes (window-start w)) drgnx-sticky-max)))
                  (if scopes
                      (let ((text (string-replace "%" "%%" (mapconcat #'drgnx-sticky--text scopes " › "))))  ; the mode line's %
                        (add-face-text-property 0 (length text) 'drgnx-sticky t text)          ; the buffer's colours stay
                        (concat " › " text))
                    "")))))

(defconst drgnx-sticky--tail '(:eval (drgnx-sticky--segment (selected-window)))
  "The header's tail in a buffer with sticky scroll (evaluated in the window being drawn).")

(define-minor-mode drgnx-sticky-mode
  "Sticky scroll: the scopes scrolled off the top, in the header after the breadcrumb."
  :lighter nil
  (if drgnx-sticky-mode
      (progn (setq-local drgnx-chrome-header-tail drgnx-sticky--tail)
             (add-hook 'after-change-functions #'drgnx-sticky--after-change nil t))
    (kill-local-variable 'drgnx-chrome-header-tail)
    (remove-hook 'after-change-functions #'drgnx-sticky--after-change t))
  (when (and (bound-and-true-p drgnx-chrome-mode) (get-buffer-window)) (drgnx-chrome-apply)))   ; the header shows it now

(defun drgnx-sticky--maybe ()
  "`prog-mode-hook': sticky scroll in file buffers."
  (when buffer-file-name (drgnx-sticky-mode 1)))

(defun drgnx-sticky--teardown ()
  "Sticky scroll off in every live buffer that has it (the hook and the command go with the setup)."
  (dolist (b (buffer-list))
    (with-current-buffer b (when drgnx-sticky-mode (drgnx-sticky-mode -1)))))

(drgnx-module-define 'editor/sticky
                     :doc "Sticky scroll: the function (class, block) you are in, when its start has scrolled off, after the breadcrumb."
                     :stage 'startup
                     :teardown #'drgnx-sticky--teardown
                     :setup (lambda ()
                              (drgnx-memo-activate 'sticky-segment)
                              (add-hook 'prog-mode-hook #'drgnx-sticky--maybe)
                              (drgnx-command-define 'toggle-sticky-scroll :category "View" :title "Toggle Sticky Scroll"
                                                    :command #'drgnx-sticky-mode :doc "The enclosing scopes in the header, off or on")))

(provide 'drgnx-sticky)
;;; drgnx-sticky.el ends here
