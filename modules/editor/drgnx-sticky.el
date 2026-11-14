;;; drgnx-sticky.el --- Module editor/sticky: sticky scroll — the scopes scrolled past, after the breadcrumb -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Like VS Code's sticky scroll: when the start of the function (class, block) you are in has scrolled off the top,
;; its name shows in the header, after the breadcrumb — up to three enclosing scopes, outermost first, one
;; line (`a › b › c'), in the breadcrumb's caption face (the look shows symbol names, never the code line).  The header line is always there (the breadcrumb), so nothing shifts as you scroll.  Scopes
;; come from tree-sitter when the buffer has a parser (functions, classes, …), else from the hub: the definitions the
;; Outline lists around the line (`outline/scopes', unsaved text included), asked once per start line and text, the
;; header drawn again when the answer comes.  Each window start is worked out once (a memo, rebuilt when the start
;; moves, the text above it changes or the hub answers).  drgnx's own; no package.  See docs/guide/editing.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-memo)
(require 'drgnx-large-file)
(require 'drgnx-timer)
(require 'drgnx-type-faces)             ; `drgnx-ui-caption'

(declare-function drgnx-chrome-add-tail-provider "drgnx-chrome")
(declare-function drgnx-chrome-remove-tail-provider "drgnx-chrome")
(declare-function nidhogg-treesit-parser-ready-p "nidhogg-treesit-bg.c" (parser))
(declare-function treesit-parser-p "treesit.c")
(declare-function drgnx-chrome-apply "drgnx-chrome")
(declare-function drgnx-outline-scopes "drgnx-outline" (buffer line callback))
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

(defface drgnx-sticky '((t :inherit (drgnx-ui-caption drgnx-text-muted)))
  "Sticky scroll's scope names in the header line: the breadcrumb's caption." :group 'drgnx)

(defun drgnx-sticky--treesit-scopes (pos)
  (let ((node (treesit-node-at (save-excursion (goto-char pos) (back-to-indentation) (point)))) (bol (save-excursion (goto-char pos) (line-beginning-position))) out)
    (while node
      (when (and (treesit-node-parent node)                        ; the root is the file, not a scope
                 (member (treesit-node-type node) drgnx-sticky-node-types)
                 (< (treesit-node-start node) bol))
        (push (save-excursion (goto-char (treesit-node-start node)) (line-beginning-position)) out))
      (setq node (treesit-node-parent node)))
    out))

(defun drgnx-sticky--parse-pending-p ()
  "Non-nil when this buffer's tree-sitter tree is not ready: on Nidhogg (`nidhogg-treesit-parser-ready-p') a parse job,
a large file's first parse, may still run, and reading a node now would wait for it in the header's `:eval'."
  (and (fboundp 'nidhogg-treesit-parser-ready-p)
       (let ((p (or (bound-and-true-p treesit-primary-parser) (car (treesit-parser-list)))))
         (and (treesit-parser-p p) (not (nidhogg-treesit-parser-ready-p p))))))

(defun drgnx-sticky--parse-landed (buffer)
  "The poll `drgnx-sticky--treesit-p' starts: once BUFFER's tree is ready, raise its `sticky' epoch and redraw the headers
once, so the scopes come from tree-sitter again.  Non-nil ends the poll."
  (or (not (buffer-live-p buffer))
      (with-current-buffer buffer
        (unless (drgnx-sticky--parse-pending-p)
          (drgnx-epoch-bump 'sticky buffer)
          (force-mode-line-update t)
          t))))

(defun drgnx-sticky--treesit-p ()
  "Non-nil when this buffer's scopes come from its tree-sitter tree: it has a parser and the tree is ready.  On Nidhogg a
parse job (a large file's first parse) may still run; reading a node then would wait for it in the header's `:eval', so
the hub answers meanwhile and a poll redraws the header once the tree is there."
  (and (fboundp 'treesit-parser-list) (treesit-parser-list)
       (or (not (drgnx-sticky--parse-pending-p))
           (progn (drgnx-timer-poll (cons 'sticky-parse (current-buffer)) 0.05 #'drgnx-sticky--parse-landed
                                    :deadline 30 :args (list (current-buffer)) :owner 'editor/sticky)
                  nil))))

(defconst drgnx-sticky--lisp-name
  "(\\(?:[[:alnum:]-]+[:/]\\)?def[[:alnum:]-]*\\*?[ \t]+'?(?\\([^][ \t\n()\"]+\\)"
  "A Lisp definition's name: `(defun NAME', `(cl-defmethod NAME', `(defvar NAME'.")

(defconst drgnx-sticky--keyword-name
  (concat "\\_<\\(?:def\\|fn\\|func\\|function\\|class\\|struct\\|enum\\|union\\|trait\\|impl\\|interface\\|module"
          "\\|mod\\|namespace\\|object\\|record\\|type\\|macro_rules!\\)\\_>[ \t]+\\([[:alpha:]_$][[:alnum:]_$]*\\)")
  "A definition's name after its keyword: `def area', `class Shape', `fn main', `impl Foo'.")

(defconst drgnx-sticky--call-name "\\([[:alpha:]_][[:alnum:]_:.~]*\\)[ \t]*("
  "A C-like definition's name: the identifier before its parameter list (`int main(void) {').")

(defconst drgnx-sticky--key-name "\\`\\([[:alpha:]_][[:alnum:]_.-]*\\)[ \t]*:"
  "A key that opens a block (`build:' in YAML).")

(defconst drgnx-sticky--not-names '("if" "for" "while" "switch" "catch" "return" "sizeof" "else" "do")
  "Words before a `(' that are statements, not definitions.")

(defun drgnx-sticky--name (line lisp)
  "The symbol name LINE (a scope's first line, trimmed) defines, or nil when it names nothing (`(let ((x', `if (a)').
LISP: the buffer is a Lisp, where only a definition form names a scope."
  (save-match-data
    (cond ((string-match drgnx-sticky--lisp-name line) (match-string 1 line))
          (lisp nil)
          ((string-match drgnx-sticky--keyword-name line) (match-string 1 line))
          ((and (string-match drgnx-sticky--call-name line)
                (not (member (match-string 1 line) drgnx-sticky--not-names)))
           (match-string 1 line))
          ((string-match drgnx-sticky--key-name line) (match-string 1 line)))))

(defun drgnx-sticky--text (start)
  "The symbol name the scope at START defines (the look: a breadcrumb shows names, never code), or nil."
  (save-excursion
    (goto-char start)
    (drgnx-sticky--name (string-trim (buffer-substring-no-properties (progn (back-to-indentation) (point))
                                                                     (line-end-position)))
                        (derived-mode-p 'lisp-data-mode))))

(drgnx-epoch-define 'sticky :per 'buffer
                    :doc "Raised by an edit at or above a window's start in the buffer (its scopes may have changed).")

(drgnx-memo-define sticky-segment :on window
                   :keys ((window-start object) (window-buffer object) (drgnx-epoch 'sticky (window-buffer object)))
                   :doc "A window's sticky part of the header, until its start moves, it shows another buffer or the text above changes.")

(defun drgnx-sticky--after-change (beg _end _len)
  "`after-change-functions': an edit above the top of a window showing this buffer changes its scopes."
  (when (seq-some (lambda (w) (<= beg (window-start w))) (get-buffer-window-list nil nil t))
    (drgnx-epoch-bump 'sticky (current-buffer))))

(defvar-local drgnx-sticky--last nil
  "[TICK SCOPES SEGMENT]: the segment last made from this buffer's tree, for the scopes starting at SCOPES, at change
TICK.")

(defvar-local drgnx-sticky--hub nil
  "[TICK LINE SEGMENT]: the segment made from the hub's answer for the scopes above LINE, at change TICK.")

(defvar-local drgnx-sticky--asked nil
  "(TICK . LINE): the start line, at change TICK, whose scopes the hub is to be asked for or was asked for last.")

(defun drgnx-sticky--join (names)
  "The segment showing NAMES (outermost first): \" › A › B\" in the caption face, or \"\" for none."
  (let ((s (if names (concat " › " (string-replace "%" "%%" (string-join names " › "))) "")))   ; the mode line's %
    (add-face-text-property 0 (length s) 'drgnx-sticky t s)
    s))

(defun drgnx-sticky--treesit-segment (w)
  "Window W's segment from the buffer's tree.  A start under the same scopes as the last one, with the text unchanged,
takes that segment: the scope lines are read once."
  (let* ((scopes (seq-take (drgnx-sticky--treesit-scopes (window-start w)) drgnx-sticky-max))
         (last drgnx-sticky--last) (tick (buffer-chars-modified-tick)))
    (cond ((null scopes) "")
          ((and last (eql (aref last 0) tick) (equal (aref last 1) scopes)) (aref last 2))
          (t (let ((s (drgnx-sticky--join (delq nil (mapcar #'drgnx-sticky--text scopes)))))
               (setq drgnx-sticky--last (vector tick scopes s))
               s)))))

(defun drgnx-sticky--hub-segment (w)
  "Window W's segment from the hub: the answer kept for its start line and the buffer's text; else the hub is asked
\(once, after this redisplay) and the last segment made stays until it answers."
  (let ((tick (buffer-chars-modified-tick)) (line (line-number-at-pos (window-start w))) (kept drgnx-sticky--hub))
    (if (and kept (eql (aref kept 0) tick) (eql (aref kept 1) line))
        (aref kept 2)
      (unless (equal drgnx-sticky--asked (cons tick line))
        (setq drgnx-sticky--asked (cons tick line))
        (drgnx-timer-debounce (cons 'sticky-ask (current-buffer)) 0 #'drgnx-sticky--ask   ; the buffer owns it
                              :args (list (current-buffer)) :owner (current-buffer)))
      (if kept (aref kept 2) ""))))

(defun drgnx-sticky--ask (buffer)
  "Ask the hub for the scopes of BUFFER's start line `drgnx-sticky--asked' names (`drgnx-outline-scopes')."
  (when (buffer-live-p buffer)
    (pcase-let ((`(,tick . ,line) (buffer-local-value 'drgnx-sticky--asked buffer)))
      (when line
        (require 'drgnx-outline)
        (drgnx-outline-scopes buffer line
                              (lambda (scopes) (drgnx-sticky--answered buffer tick line scopes)))))))

(defun drgnx-sticky--answered (buffer tick line scopes)
  "The hub's SCOPES (plists, outermost first) of LINE of BUFFER at change TICK: those that start above LINE make the
segment, kept for (TICK, LINE), and the header is drawn again."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((names (seq-take (delq nil (mapcar (lambda (s) (and (< (plist-get s :line) line) (plist-get s :name)))
                                               scopes))
                             drgnx-sticky-max)))
        (setq drgnx-sticky--hub (vector tick line (drgnx-sticky--join names)))
        (drgnx-epoch-bump 'sticky buffer)
        (force-mode-line-update t)))))

(defun drgnx-sticky--segment (w)
  "Window W's sticky part of the header: \" › SCOPE › …\" for its start, or \"\" (the memo `sticky-segment': built
again only when the start moves, the text above it changes or the hub answers).  From the buffer's tree-sitter tree
when it is ready (`drgnx-sticky--treesit-p'), else from the hub (`drgnx-sticky--hub-segment')."
  (drgnx-memo sticky-segment w
              (with-current-buffer (window-buffer w)
                (if (drgnx-sticky--treesit-p) (drgnx-sticky--treesit-segment w) (drgnx-sticky--hub-segment w)))))

(defun drgnx-sticky--tail (w)
  "The chrome's tail provider (depth 20, after the large-file header): window W's sticky part,
in a buffer with sticky scroll."
  (and (buffer-local-value 'drgnx-sticky-mode (window-buffer w)) (drgnx-sticky--segment w)))

(define-minor-mode drgnx-sticky-mode
  "Sticky scroll: the scopes scrolled off the top, in the header after the breadcrumb."
  :lighter nil
  (if drgnx-sticky-mode
      (add-hook 'after-change-functions #'drgnx-sticky--after-change nil t)
    (remove-hook 'after-change-functions #'drgnx-sticky--after-change t))
  (when (and (bound-and-true-p drgnx-chrome-mode) (get-buffer-window)) (drgnx-chrome-apply)))   ; the header shows it now

(defun drgnx-sticky--maybe ()
  "`prog-mode-hook': sticky scroll in file buffers, not in a large file's."
  (when (and buffer-file-name (not (drgnx-large-file-p))) (drgnx-sticky-mode 1)))

(defun drgnx-sticky--teardown ()
  "Sticky scroll off in every live buffer that has it (the hook and the command go with the setup)."
  (when (fboundp 'drgnx-chrome-remove-tail-provider) (drgnx-chrome-remove-tail-provider #'drgnx-sticky--tail))
  (dolist (b (buffer-list))
    (with-current-buffer b (when drgnx-sticky-mode (drgnx-sticky-mode -1)))))

(drgnx-module-define 'editor/sticky
                     :doc "Sticky scroll: the function (class, block) you are in, when its start has scrolled off, after the breadcrumb."
                     :stage 'startup
                     :teardown #'drgnx-sticky--teardown
                     :setup (lambda ()
                              (drgnx-memo-activate 'sticky-segment)
                              (eval-after-load 'drgnx-chrome
                                (drgnx-modules-with-owner (drgnx-chrome-add-tail-provider #'drgnx-sticky--tail 20)))
                              (add-hook 'prog-mode-hook #'drgnx-sticky--maybe)
                              (drgnx-command-define 'toggle-sticky-scroll :category "View" :title "Toggle Sticky Scroll"
                                                    :command #'drgnx-sticky-mode :doc "The enclosing scopes in the header, off or on")))

(provide 'drgnx-sticky)
;;; drgnx-sticky.el ends here
