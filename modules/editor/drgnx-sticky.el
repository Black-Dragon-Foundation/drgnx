;;; drgnx-sticky.el --- Module editor/sticky: sticky scroll — the scopes scrolled past, after the breadcrumb -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Like VS Code's sticky scroll: when the start of the function (class, block) you are in has scrolled off the top,
;; its first line shows in the header, after the breadcrumb — up to three enclosing scopes, outermost first, one
;; line (`a › b › c').  The header line is always there (the breadcrumb), so nothing shifts as you scroll.  Scopes
;; come from tree-sitter when the buffer has a parser (functions, classes, …), else from indentation.  Each window
;; start is worked out once (cached).  drgnx's own; no package.  See docs/guide/editing.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-registry)

(defvar drgnx-chrome-header-tail)
(declare-function treesit-parser-list "treesit.c")
(declare-function treesit-node-at "treesit")
(declare-function treesit-node-parent "treesit.c")
(declare-function treesit-node-type "treesit.c")
(declare-function treesit-node-start "treesit.c")

(defvar drgnx-sticky-max 3 "Scopes shown at most (the outermost).")

(defvar drgnx-sticky-node-regexp
  (concat "\\`\\(?:function\\|method\\|class\\|struct\\|impl\\|module\\|namespace\\|interface\\|object\\|enum\\|trait\\)"
          "\\(?:_definition\\|_declaration\\|_item\\|_specifier\\)?\\'\\|\\`\\(?:function\\|method\\|class\\|arrow_function\\)\\'")
  "Tree-sitter node types that are scopes.")

(defface drgnx-sticky '((t :inherit header-line)) "Sticky scroll's scopes in the header line." :group 'drgnx)

(defun drgnx-sticky--line-indent ()
  "The current line's indentation, or nil when it is blank."
  (save-excursion (back-to-indentation) (unless (eolp) (current-indentation))))

(defun drgnx-sticky--treesit-scopes (pos)
  (let ((node (treesit-node-at (save-excursion (goto-char pos) (back-to-indentation) (point)))) (line (line-number-at-pos pos)) out)
    (while node
      (when (and (string-match-p drgnx-sticky-node-regexp (treesit-node-type node))
                 (< (line-number-at-pos (treesit-node-start node)) line))
        (push (save-excursion (goto-char (treesit-node-start node)) (line-beginning-position)) out))
      (setq node (treesit-node-parent node)))
    out))

(defun drgnx-sticky--indent-scopes (pos)
  "Line starts of the lines above POS's that open its indentation levels, outermost first."
  (save-excursion
    (goto-char pos)
    (beginning-of-line)
    (let ((indent (or (drgnx-sticky--line-indent)                 ; a blank line: the next line's level
                      (save-excursion (and (zerop (forward-line 1)) (drgnx-sticky--line-indent)))
                      0))
          out)
      (while (and (> indent 0) (zerop (forward-line -1)))
        (when-let* ((i (drgnx-sticky--line-indent)))
          (when (and (< i indent)
                     ;; not a line inside a string (a docstring at column 0) or a comment
                     (let ((s (syntax-ppss (save-excursion (back-to-indentation) (point))))) (not (or (nth 3 s) (nth 4 s)))))
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

(defun drgnx-sticky--segment (w)
  "Window W's sticky part of the header: \" › SCOPE › …\" for its start, or \"\" (cached per start and buffer change)."
  (with-current-buffer (window-buffer w)
    (let ((start (window-start w)) (tick (buffer-chars-modified-tick)) (cache (window-parameter w 'drgnx-sticky)))
      (if (and cache (eql (nth 0 cache) start) (eql (nth 1 cache) tick) (eq (nth 2 cache) (current-buffer)))
          (nth 3 cache)
        (let* ((scopes (seq-take (drgnx-sticky-scopes start) drgnx-sticky-max))
               (s (if scopes (concat " › " (propertize (mapconcat #'drgnx-sticky--text scopes " › ") 'face 'drgnx-sticky)) "")))
          (set-window-parameter w 'drgnx-sticky (list start tick (current-buffer) s))
          s)))))

(defconst drgnx-sticky--tail '(:eval (drgnx-sticky--segment (selected-window)))
  "The header's tail in a buffer with sticky scroll (evaluated in the window being drawn).")

(define-minor-mode drgnx-sticky-mode
  "Sticky scroll: the scopes scrolled off the top, in the header after the breadcrumb."
  :lighter nil
  (if drgnx-sticky-mode
      (setq-local drgnx-chrome-header-tail drgnx-sticky--tail)
    (kill-local-variable 'drgnx-chrome-header-tail))
  (when (and (fboundp 'drgnx-chrome-apply) (get-buffer-window)) (drgnx-chrome-apply)))   ; the header shows it now

(defun drgnx-sticky--maybe ()
  "`prog-mode-hook': sticky scroll in file buffers."
  (when buffer-file-name (drgnx-sticky-mode 1)))

(drgnx-module-define 'editor/sticky
                     :doc "Sticky scroll: the function (class, block) you are in, when its start has scrolled off, after the breadcrumb."
                     :stage 'startup
                     :setup (lambda ()
                              (add-hook 'prog-mode-hook #'drgnx-sticky--maybe)
                              (drgnx-command-define 'toggle-sticky-scroll :category "View" :title "Toggle Sticky Scroll"
                                                    :command #'drgnx-sticky-mode :doc "The enclosing scopes in the header, off or on")))

(provide 'drgnx-sticky)
;;; drgnx-sticky.el ends here
