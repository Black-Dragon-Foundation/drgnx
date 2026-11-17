;;; drgnx-fold.el --- Module editor/fold: folding on the line model's fold table -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Folding as in VS Code, on Nidhogg's line model (docs/guide/editing.md, "Folding"; docs/develop/core.md, "The ruler
;; and the minimap").  The model keeps one table of fold ranges per buffer text, shifted with every edit, from its
;; sources: the buffer's tree-sitter parser, through its language pack's fold query, which Nidhogg runs at each reparse
;; (`nidhogg-treesit-fold-query'); indentation and Markdown headings the model finds itself
;; (`nidhogg-lines-set-fold-sources'); notebook cells and manual folds this module sends (`nidhogg-lines-set-folds').  A command looks a range up
;; (`nidhogg-lines-fold-at', `nidhogg-lines-folds') and hides it with an `invisible' overlay whose `display' is the
;; summary (`⋯ N lines'); isearch opens a fold it passes through.  The hidden ranges go back to the model, which leaves
;; their lines out of the scroll bar and the minimap.  Org folds through Org's own `org-fold'.  Nothing here runs on a
;; scroll or a keystroke; a fold command reads the table once.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-setting)
(require 'drgnx-faces)

(declare-function drgnx-notify "drgnx-notice")
(declare-function nidhogg-lines-enable "nidhogg-lines" (&optional buffer wait))
(declare-function nidhogg-lines-folds "nidhogg-lines" (buffer &optional beg end))
(declare-function nidhogg-lines-fold-at "nidhogg-lines" (buffer pos))
(declare-function nidhogg-lines-set-folds "nidhogg-lines" (buffer source folds &optional max))
(declare-function nidhogg-lines-set-fold-sources "nidhogg-lines" (buffer indent heading-regexp))
(declare-function nidhogg-lines-set-hidden "nidhogg-lines" (buffer ranges))
(declare-function drgnx-packs-language-dir "drgnx-packs" (language))
(declare-function nidhogg-treesit-refold "treesit.c" (parser))
(declare-function treesit-parser-list "treesit.c" (&optional buffer language tag))
(declare-function treesit-parser-language "treesit.c" (parser))
(declare-function treesit-parser-root-node "treesit.c" (parser))
(declare-function treesit-query-compile "treesit.c" (language query &optional eager))
(defvar nidhogg-treesit-fold-query)
(defvar treesit-primary-parser)
(declare-function org-back-to-heading "org" (&optional invisible-ok))
(declare-function org-fold-hide-subtree "org-fold")
(declare-function org-fold-show-subtree "org-fold")
(declare-function org-fold-show-all "org-fold" (&optional types))
(declare-function org-content "org" (&optional arg))
(declare-function org-overview "org")
(declare-function org-cycle "org-cycle" (&optional arg))
(declare-function drgnx-notebook--rescan "drgnx-notebook")
(defvar drgnx-notebook--cells)
(defvar evil-fold-list)

;;;; Settings and faces

(defvar-local drgnx-fold--sources nil
  "The sources the buffer's line model was last given: `treesit', `indent', `headings', `cells' or `off'; nil, none
yet.")

(defvar-local drgnx-fold--bounds nil
  "The accessible region (BEG . END) the buffer's tree-sitter folds were last run over: a narrowing that changed it
runs them again (`nidhogg-treesit-refold').")

(defvar-local drgnx-fold--level nil
  "Vim's fold level of the buffer (`z m', `z r'): blocks this deep or deeper are folded (0: all); nil, none.")

(defvar-local drgnx-fold--manual nil
  "The buffer's manual folds: (BEG-MARKER END-MARKER NAME) each, NAME nil or a string.")

(defun drgnx-fold--setting-changed (&rest _)
  "A fold setting changed: every buffer's sources again, and every fold's summary."
  (dolist (b (buffer-list))
    (with-current-buffer b
      (when drgnx-fold--sources
        (setq drgnx-fold--sources nil)
        (drgnx-fold--ensure))
      (dolist (o (drgnx-fold--overlays))
        (overlay-put o 'display (drgnx-fold--summary o))))))

(drgnx-defsetting drgnx-fold-source 'auto
  "Where fold ranges come from: `auto', the best source the buffer has (Markdown headings, notebook cells, the
buffer's tree-sitter parser through its language pack's fold query, else indentation; Org folds its own headings);
`indent', indentation always; `off', no folding but manual folds."
  :type '(choice (const auto) (const indent) (const off)) :group 'drgnx-fold :scope 'global
  :apply #'drgnx-fold--setting-changed :schema '(enum auto indent off))

(drgnx-defsetting drgnx-fold-summary 'full
  "What a folded line shows after it: `full', the hidden lines' count and what is inside; `lines', the count only;
nil, an ellipsis."
  :type '(choice (const full) (const lines) (const :tag "Ellipsis" nil)) :group 'drgnx-fold :scope 'global
  :apply #'drgnx-fold--setting-changed)

(drgnx-defsetting drgnx-fold-max 20000
  "The most fold ranges a buffer keeps (the smallest go first past it), as VS Code's editor.foldingMaximumRegions."
  :type 'natnum :group 'drgnx-fold :scope 'global :apply #'drgnx-fold--setting-changed)

(defface drgnx-fold-summary '((t :inherit drgnx-chip-quiet))
  "The summary after a folded line (`⋯ 38 lines')." :group 'drgnx-fold)

(defface drgnx-fold-name '((t :inherit drgnx-chip-accent))
  "A named fold's name after its folded line." :group 'drgnx-fold)

;;;; The fold table

(defconst drgnx-fold-kinds [block function class comment import test region cell heading]
  "The fold kinds, each at its number in the line model (design §7.4: the fold query's `@fold.KIND' names).")

(defun drgnx-fold--kind (kind)
  "KIND's number in the line model, or nil."
  (seq-position drgnx-fold-kinds kind))

(defconst drgnx-fold--source-treesit 0 "The model's source number of tree-sitter folds.")
(defconst drgnx-fold--source-cells 3 "The model's source number of notebook cells.")
(defconst drgnx-fold--source-manual 5 "The model's source number of manual folds.")

(defconst drgnx-fold-markdown-heading "^(#{1,6})\\s"
  "Markdown's headings for the line model (Rust regex syntax): the `#'s are the level.")

(defun drgnx-fold--org-p ()
  (derived-mode-p 'org-mode))

;;;; Tree-sitter fold queries

(defvar drgnx-fold--queries (make-hash-table :test #'eq)
  "Each tree-sitter language's compiled fold query, or `none' (no pack, or a query that does not compile).  One
entry a language; emptied when the module goes off.")

(defun drgnx-fold--tags-query (tags)
  "TAGS, a pack's `tags.scm', as a fold query: each `@definition.KIND' capture a fold of its kind (function, method,
macro and constructor a function; class, struct, interface, module, enum, union, trait, impl, namespace and type a
class; any other a block).  The other captures fold nothing (Nidhogg folds only `@fold' ones)."
  (replace-regexp-in-string
   "@definition\\.\\([a-z_]+\\)"
   (lambda (m)
     (let ((k (match-string 1 m)))
       (cond ((member k '("function" "method" "macro" "constructor")) "@fold.function")
             ((member k '("class" "struct" "interface" "module" "enum" "union" "trait" "impl" "namespace" "type"))
              "@fold.class")
             (t "@fold"))))
   tags t t))

(defun drgnx-fold--query (language)
  "LANGUAGE's compiled fold query: its pack's `queries/folds.scm', else its `queries/tags.scm' as one
(`drgnx-fold--tags-query'); nil when it has neither, or it does not compile.  Compiled once a language."
  (let ((q (gethash language drgnx-fold--queries)))
    (unless q
      (setq q (or (when-let* ((dir (and (require 'drgnx-packs nil t) (drgnx-packs-language-dir language))))
                    (let ((folds (expand-file-name "queries/folds.scm" dir))
                          (tags (expand-file-name "queries/tags.scm" dir)))
                      (when-let* ((src (cond ((file-readable-p folds)
                                              (with-temp-buffer (insert-file-contents folds) (buffer-string)))
                                             ((file-readable-p tags)
                                              (drgnx-fold--tags-query
                                               (with-temp-buffer (insert-file-contents tags) (buffer-string)))))))
                        (ignore-errors (treesit-query-compile language src t)))))
                  'none))
      (puthash language q drgnx-fold--queries))
    (and (not (eq q 'none)) q)))

(defun drgnx-fold--parser ()
  "The current buffer's tree-sitter parser to fold by: its primary parser, else its first, that has a fold query
and a Nidhogg that runs it; nil when none."
  (when (and (fboundp 'nidhogg-treesit-refold) (fboundp 'treesit-parser-list))
    (seq-find (lambda (p) (drgnx-fold--query (treesit-parser-language p)))
              (delete-dups (delq nil (cons (bound-and-true-p treesit-primary-parser) (treesit-parser-list)))))))

(defun drgnx-fold--wanted ()
  "The sources the current buffer's model should have."
  (cond ((eq drgnx-fold-source 'off) 'off)
        ((eq drgnx-fold-source 'indent) 'indent)
        ((derived-mode-p 'markdown-mode) 'headings)
        ((derived-mode-p 'drgnx-notebook-mode) 'cells)
        ((drgnx-fold--parser) 'treesit)
        (t 'indent)))

(defun drgnx-fold--send-cells ()
  "The notebook's cells to the line model, each from its first line to its last."
  (when (fboundp 'drgnx-notebook--rescan)
    (drgnx-notebook--rescan)
    (nidhogg-lines-set-folds
     nil drgnx-fold--source-cells
     (mapcar (lambda (c) (list (1+ (plist-get c :head)) (plist-get c :tail) (drgnx-fold--kind 'cell)))
             drgnx-notebook--cells)
     drgnx-fold-max)))

(defun drgnx-fold--send-manual ()
  "The manual folds to the line model."
  (setq drgnx-fold--manual
        (cl-remove-if (lambda (m) (>= (marker-position (nth 0 m)) (marker-position (nth 1 m)))) drgnx-fold--manual))
  (nidhogg-lines-set-folds nil drgnx-fold--source-manual
                           (mapcar (lambda (m) (list (marker-position (nth 0 m)) (marker-position (nth 1 m))
                                                     (drgnx-fold--kind 'region)))
                                   drgnx-fold--manual)
                           drgnx-fold-max))

(defun drgnx-fold--ensure ()
  "Give the current buffer's line model its fold sources (`drgnx-fold-source'), waiting for its lines.  Nil when the
buffer cannot fold through the model (no Nidhogg, or Org)."
  (when (and (fboundp 'nidhogg-lines-enable) (not (drgnx-fold--org-p)))
    (nidhogg-lines-enable nil t)
    (let* ((want (drgnx-fold--wanted)) (parser (and (eq want 'treesit) (drgnx-fold--parser))))
      ;; off tree-sitter (another source, or a setting changed): its query and its ranges go
      (when (and (not (eq want 'treesit)) (local-variable-p 'nidhogg-treesit-fold-query))
        (kill-local-variable 'nidhogg-treesit-fold-query)
        (nidhogg-lines-set-folds nil drgnx-fold--source-treesit nil drgnx-fold-max))
      (unless (eq want drgnx-fold--sources)
        (setq drgnx-fold--sources want drgnx-fold--bounds nil)
        (nidhogg-lines-set-fold-sources nil (eq want 'indent) (and (eq want 'headings) drgnx-fold-markdown-heading))
        (unless (eq want 'cells) (nidhogg-lines-set-folds nil drgnx-fold--source-cells nil drgnx-fold-max)))
      (pcase want
        ('cells (drgnx-fold--send-cells))
        ('treesit
         ;; Nidhogg publishes each reparse's changed ranges itself; a query set after the parse, or a narrowing
         ;; that moved, runs over the whole tree once
         (let ((bounds (cons (point-min) (point-max))))
           (if (and (equal bounds drgnx-fold--bounds)
                    (eq nidhogg-treesit-fold-query (drgnx-fold--query (treesit-parser-language parser))))
               (treesit-parser-root-node parser)   ; an edit not yet parsed is, and its ranges go to the model
             (setq-local nidhogg-treesit-fold-query (drgnx-fold--query (treesit-parser-language parser)))
             (setq drgnx-fold--bounds bounds)
             (nidhogg-treesit-refold parser))))))
    t))

(defun drgnx-fold-ranges (&optional beg end)
  "The current buffer's fold ranges overlapping BEG..END (default all): (BEG END KIND DEPTH SOURCE) each, in order,
an outer range before those it holds.  Nil when the buffer cannot fold through the line model."
  (and (drgnx-fold--ensure) (nidhogg-lines-folds nil beg end)))

(defun drgnx-fold--manual-at (pos)
  "The manual fold starting on POS's line, else the innermost holding POS, or nil."
  (let ((bol (save-excursion (goto-char pos) (line-beginning-position)))
        (eol (save-excursion (goto-char pos) (line-end-position))))
    (or (seq-find (lambda (m) (<= bol (nth 0 m) eol)) drgnx-fold--manual)
        (car (sort (seq-filter (lambda (m) (<= (nth 0 m) pos (nth 1 m))) drgnx-fold--manual)
                   (lambda (a b) (< (- (nth 1 a) (nth 0 a)) (- (nth 1 b) (nth 0 b)))))))))

(defun drgnx-fold--range-at (pos)
  "The range to fold at POS: a manual fold on its line wins (design F4), else the line model's (the largest
starting on POS's line, else the innermost holding POS)."
  (when (drgnx-fold--ensure)
    (let ((m (drgnx-fold--manual-at pos)))
      (if (and m (save-excursion (goto-char pos) (<= (line-beginning-position) (nth 0 m) (line-end-position))))
          (seq-find (lambda (r) (and (= (nth 0 r) (nth 0 m)) (= (nth 1 r) (nth 1 m))))
                    (nidhogg-lines-folds nil (nth 0 m) (1+ (nth 0 m))))
        (nidhogg-lines-fold-at nil pos)))))

;;;; Hiding

(defun drgnx-fold--overlays (&optional beg end)
  "The fold overlays from BEG to END (default the whole buffer)."
  (seq-filter (lambda (o) (overlay-get o 'drgnx-fold))
              (overlays-in (or beg (point-min)) (or end (point-max)))))

(defun drgnx-fold--start (beg)
  "Where the hidden part of a range starting at BEG starts: its first line's end."
  (save-excursion (goto-char beg) (line-end-position)))

(defun drgnx-fold--overlay-of (range)
  "The overlay hiding RANGE, or nil."
  (let ((s (drgnx-fold--start (nth 0 range))))
    (seq-find (lambda (o) (and (= (overlay-start o) s) (= (overlay-end o) (nth 1 range))))
              (drgnx-fold--overlays s (1+ s)))))

(defun drgnx-fold--summary (ov)
  "The display string of fold overlay OV: its name, then `⋯ N lines' (`drgnx-fold-summary')."
  (let* ((s (overlay-start ov)) (e (overlay-end ov))
         ;; the newlines from S to E, counted over the range alone (`line-number-at-pos' counts from the buffer's start)
         (n (let ((c (count-lines s e))) (if (save-excursion (goto-char e) (bolp)) c (1- c))))
         (name (overlay-get ov 'drgnx-fold-name))
         (count (pcase drgnx-fold-summary
                  ('nil "⋯")
                  (_ (format "⋯ %d line%s" n (if (= n 1) "" "s"))))))
    (concat " "
            (and name (concat (propertize (format " %s " name) 'face 'drgnx-fold-name) " "))
            (propertize (format " %s " count) 'face 'drgnx-fold-summary))))

(defun drgnx-fold--isearch-show (ov hide)
  "`isearch-open-invisible-temporary': show OV while isearch is in it; HIDE non-nil folds it again."
  (overlay-put ov 'invisible (and hide 'drgnx-fold))
  (overlay-put ov 'display (and hide (drgnx-fold--summary ov))))

(defun drgnx-fold--isearch-open (ov)
  "`isearch-open-invisible': isearch ended in OV, which unfolds."
  (delete-overlay ov)
  (drgnx-fold--report))

(defun drgnx-fold--report ()
  "Tell the line model which ranges are hidden (the scroll bar and the minimap leave their lines out)."
  (when (and (fboundp 'nidhogg-lines-set-hidden) (not (drgnx-fold--org-p)) drgnx-fold--sources)
    (nidhogg-lines-set-hidden nil (mapcar (lambda (o) (cons (overlay-start o) (overlay-end o)))
                                          (drgnx-fold--overlays)))))

(defun drgnx-fold--hide (range)
  "Hide RANGE (BEG END …) after its first line, unless it is hidden already or holds one line; the overlay or nil."
  (let ((s (drgnx-fold--start (nth 0 range))) (e (nth 1 range)))
    (when (< s e)
      (or (drgnx-fold--overlay-of range)
          (let ((ov (make-overlay s e nil t nil))
                (m (seq-find (lambda (m) (and (= (nth 0 m) (nth 0 range)) (= (nth 1 m) e))) drgnx-fold--manual)))
            (add-to-invisibility-spec 'drgnx-fold)
            (overlay-put ov 'drgnx-fold t)
            (overlay-put ov 'drgnx-fold-name (nth 2 m))
            (overlay-put ov 'invisible 'drgnx-fold)
            (overlay-put ov 'evaporate t)
            (overlay-put ov 'isearch-open-invisible #'drgnx-fold--isearch-open)
            (overlay-put ov 'isearch-open-invisible-temporary #'drgnx-fold--isearch-show)
            (overlay-put ov 'display (drgnx-fold--summary ov))
            ov)))))

(defun drgnx-fold--show (ov)
  (delete-overlay ov))

(defun drgnx-fold--after (fn)
  "Run FN, then tell the model what is hidden and keep point out of a hidden part."
  (prog1 (funcall fn)
    (drgnx-fold--report)
    (when-let* ((ov (seq-find (lambda (o) (< (overlay-start o) (point) (overlay-end o))) (drgnx-fold--overlays (point) (1+ (point))))))
      (goto-char (overlay-start ov)))))

(defun drgnx-fold--hide-all (ranges)
  "Hide each of RANGES; the number hidden."
  (let ((n 0)) (dolist (r ranges) (when (drgnx-fold--hide r) (cl-incf n))) n))

(defun drgnx-fold--line-overlays ()
  "The fold overlays that start on point's line (its folds)."
  (let ((bol (line-beginning-position)) (eol (line-end-position)))
    (seq-filter (lambda (o) (<= bol (overlay-start o) eol)) (drgnx-fold--overlays bol (1+ eol)))))

(defun drgnx-fold--holds (range beg end)
  "Whether RANGE holds BEG..END."
  (and (<= (nth 0 range) beg) (<= end (nth 1 range))))

(defun drgnx-fold--here ()
  "Point, or the selection: (BEG . END)."
  (if (use-region-p) (cons (region-beginning) (region-end)) (cons (point) (point))))

(defmacro drgnx-fold--org-or (org &rest body)
  "In Org, ORG (a form); else BODY, with the model's ranges, after which the hidden ranges are reported."
  (declare (indent 1))
  `(if (drgnx-fold--org-p)
       ,org
     (unless (drgnx-fold--ensure) (user-error "Folding needs Nidhogg's line model"))
     (drgnx-fold--after (lambda () ,@body))))

;;;; Commands

(defun drgnx-fold-fold ()
  "Fold the block at point: the largest range starting on this line, else the innermost holding point; on a line
already folded, the range around it."
  (interactive)
  (drgnx-fold--org-or (save-excursion (org-back-to-heading t) (org-fold-hide-subtree))
    (let ((r (drgnx-fold--range-at (point))))
      (while (and r (drgnx-fold--overlay-of r))
        (setq r (car (last (seq-filter (lambda (o) (and (< (nth 3 o) (nth 3 r)) (drgnx-fold--holds o (nth 0 r) (nth 1 r))))
                                       (drgnx-fold-ranges (nth 0 r) (1+ (nth 0 r))))))))
      (unless r (user-error "Nothing to fold here"))
      (drgnx-fold--hide r))))

(defun drgnx-fold-unfold ()
  "Unfold the folds of point's line."
  (interactive)
  (drgnx-fold--org-or (save-excursion (org-back-to-heading t) (org-fold-show-subtree))
    (let ((os (drgnx-fold--line-overlays)))
      (unless os (user-error "Nothing folded here"))
      (mapc #'drgnx-fold--show os))))

(defun drgnx-fold-toggle ()
  "Unfold point's line when it is folded, else fold the block at point."
  (interactive)
  (if (drgnx-fold--org-p)
      (org-cycle)
    (if (and (drgnx-fold--ensure) (drgnx-fold--line-overlays)) (drgnx-fold-unfold) (drgnx-fold-fold))))

(defun drgnx-fold-fold-recursive ()
  "Fold the block at point and every block inside it."
  (interactive)
  (drgnx-fold--org-or (save-excursion (org-back-to-heading t) (org-fold-hide-subtree))
    (let ((r (drgnx-fold--range-at (point))))
      (unless r (user-error "Nothing to fold here"))
      (drgnx-fold--hide-all (seq-filter (lambda (o) (drgnx-fold--holds r (nth 0 o) (nth 1 o)))
                                        (drgnx-fold-ranges (nth 0 r) (nth 1 r)))))))

(defun drgnx-fold-unfold-recursive ()
  "Unfold the block at point and every block inside it."
  (interactive)
  (drgnx-fold--org-or (save-excursion (org-back-to-heading t) (org-fold-show-subtree))
    (let* ((os (drgnx-fold--line-overlays))
           (r (if os (list (line-beginning-position) (apply #'max (mapcar #'overlay-end os)))
                (drgnx-fold--range-at (point)))))
      (unless r (user-error "Nothing folded here"))
      (mapc #'drgnx-fold--show (drgnx-fold--overlays (nth 0 r) (nth 1 r))))))

(defun drgnx-fold-fold-all ()
  "Fold every block."
  (interactive)
  (drgnx-fold--org-or (org-overview)
    (setq drgnx-fold--level 0)
    (drgnx-fold--hide-all (drgnx-fold-ranges))))

(defun drgnx-fold-unfold-all ()
  "Unfold every fold."
  (interactive)
  (drgnx-fold--org-or (org-fold-show-all)
    (setq drgnx-fold--level nil)
    (mapc #'drgnx-fold--show (drgnx-fold--overlays))))

(defun drgnx-fold--set-level (step)
  "Vim's fold level moved by STEP (-1 folds one level more, 1 one less): every block as deep as the level or deeper
folded, the rest open."
  (let* ((ranges (drgnx-fold-ranges))
         (deepest (if ranges (1+ (apply #'max (mapcar (lambda (r) (nth 3 r)) ranges))) 0))
         (level (max 0 (+ (or drgnx-fold--level deepest) step))))
    (setq drgnx-fold--level (and (< level deepest) level))
    (mapc #'drgnx-fold--show (drgnx-fold--overlays))
    (when drgnx-fold--level
      (drgnx-fold--hide-all (seq-filter (lambda (r) (>= (nth 3 r) level)) ranges)))))

(defun drgnx-fold-more ()
  "Fold one level more, as Vim's `z m': the deepest blocks still open fold."
  (interactive)
  (drgnx-fold--org-or (user-error "In Org, use Fold Level")
    (drgnx-fold--set-level -1)))

(defun drgnx-fold-less ()
  "Fold one level less, as Vim's `z r': the deepest folded blocks open."
  (interactive)
  (drgnx-fold--org-or (user-error "In Org, use Fold Level")
    (drgnx-fold--set-level 1)))

(defun drgnx-fold-fold-level (level)
  "Fold every block at nesting LEVEL (1 outermost, to 7) but those holding point, as VS Code's Fold Level N.
Interactively, the prefix argument, else asked."
  (interactive (list (cond (current-prefix-arg (prefix-numeric-value current-prefix-arg))
                           ;; VS Code's C-k C-1 … C-k C-7: the digit of the key
                           ((memq (event-basic-type last-command-event) '(?1 ?2 ?3 ?4 ?5 ?6 ?7))
                            (- (event-basic-type last-command-event) ?0))
                           (t (read-number "Fold level (1–7): " 1)))))
  (unless (<= 1 level 7) (user-error "Fold level from 1 to 7"))
  (drgnx-fold--org-or (org-content level)
    (pcase-let ((`(,b . ,e) (drgnx-fold--here)))
      (drgnx-fold--hide-all (seq-filter (lambda (r) (and (= (nth 3 r) (1- level)) (not (drgnx-fold--holds r b e))))
                                        (drgnx-fold-ranges))))))

(defun drgnx-fold--kinds-here ()
  "The kinds the buffer's ranges have, as symbols."
  (delete-dups (mapcar (lambda (r) (and (< (nth 2 r) (length drgnx-fold-kinds)) (aref drgnx-fold-kinds (nth 2 r)))) (drgnx-fold-ranges))))

(defun drgnx-fold-fold-kind (kind)
  "Fold every block of KIND (a symbol of `drgnx-fold-kinds': functions, classes, comments, imports, tests, regions,
cells…).  Interactively, asked among the kinds the buffer has; on VS Code's C-k C-/, comments."
  (interactive (list (if (eq (event-basic-type last-command-event) ?/)
                         'comment
                       (let ((ks (drgnx-fold--kinds-here)))
                         (unless ks (user-error "Nothing to fold here"))
                         (intern (completing-read "Fold by kind: " (mapcar #'symbol-name ks) nil t))))))
  (drgnx-fold--org-or (user-error "In Org, fold headings with Fold or Fold Level")
    (let ((n (drgnx-fold--kind kind)))
      (unless n (user-error "No fold kind %s" kind))
      (drgnx-fold--hide-all (seq-filter (lambda (r) (= (nth 2 r) n)) (drgnx-fold-ranges))))))

(defun drgnx-fold-fold-focus ()
  "Fold every block that does not hold point (or the selection), and unfold those that do: what you work on stays."
  (interactive)
  (drgnx-fold--org-or (user-error "In Org, Fold Level shows the outline")
    (pcase-let ((`(,b . ,e) (drgnx-fold--here)))
      (dolist (o (drgnx-fold--overlays))
        (when (and (<= (overlay-start o) e) (>= (overlay-end o) b)) (drgnx-fold--show o)))
      (drgnx-fold--hide-all (seq-remove (lambda (r) (drgnx-fold--holds r b e)) (drgnx-fold-ranges))))))

(defun drgnx-fold-unfold-focus ()
  "Unfold every fold that does not hold point (or the selection)."
  (interactive)
  (drgnx-fold--org-or (org-fold-show-all)
    (pcase-let ((`(,b . ,e) (drgnx-fold--here)))
      (dolist (o (drgnx-fold--overlays))
        (unless (and (<= (overlay-start o) b) (>= (overlay-end o) e)) (drgnx-fold--show o))))))

(defun drgnx-fold-create (beg end &optional name)
  "Make a fold of the lines from BEG to END (the selection) and fold it; NAME, asked for, is shown when folded and
nil or empty for none."
  (interactive (if (use-region-p)
                   (list (region-beginning) (region-end)
                         (let ((s (read-string "Fold name (optional): "))) (and (not (string-empty-p s)) s)))
                 (user-error "Select the lines to fold first")))
  (drgnx-fold--org-or (user-error "Org folds its headings")
    (let* ((b (save-excursion (goto-char beg) (line-beginning-position)))
           (e (save-excursion (goto-char (if (and (> end beg) (= end (save-excursion (goto-char end) (line-beginning-position))))
                                             (1- end) end))
                              (line-end-position))))
      (unless (< (drgnx-fold--start b) e) (user-error "A fold needs two lines or more"))
      (setq drgnx-fold--manual (cl-remove-if (lambda (m) (and (= (nth 0 m) b) (= (nth 1 m) e))) drgnx-fold--manual))
      (push (list (copy-marker b) (copy-marker e t) name) drgnx-fold--manual)
      (drgnx-fold--send-manual)
      (deactivate-mark)
      (goto-char b)
      (drgnx-fold--hide (list b e)))))

(defun drgnx-fold-remove ()
  "Remove the manual fold at point (its overlay too)."
  (interactive)
  (drgnx-fold--org-or (user-error "Org folds its headings")
    (let ((m (drgnx-fold--manual-at (point))))
      (unless m (user-error "No manual fold here"))
      (when-let* ((ov (drgnx-fold--overlay-of (list (nth 0 m) (nth 1 m))))) (drgnx-fold--show ov))
      (setq drgnx-fold--manual (delq m drgnx-fold--manual))
      (drgnx-fold--send-manual))))

(defun drgnx-fold-rename (name)
  "Name the manual fold at point NAME (empty: no name)."
  (interactive (let ((m (or (drgnx-fold--manual-at (point)) (user-error "No manual fold here"))))
                 (list (read-string "Fold name: " (nth 2 m)))))
  (drgnx-fold--org-or (user-error "Org folds its headings")
    (let ((m (or (drgnx-fold--manual-at (point)) (user-error "No manual fold here"))))
      (setf (nth 2 m) (and (not (string-empty-p name)) name))
      (when-let* ((ov (drgnx-fold--overlay-of (list (nth 0 m) (nth 1 m)))))
        (overlay-put ov 'drgnx-fold-name (nth 2 m))
        (overlay-put ov 'display (drgnx-fold--summary ov))))))

(defun drgnx-fold--step (dir)
  "Go to the start of the next (DIR 1) or previous (-1) range's line."
  (let* ((bol (line-beginning-position))
         (starts (delete-dups (mapcar #'car (drgnx-fold-ranges))))
         (to (if (> dir 0) (seq-find (lambda (s) (> s (line-end-position))) starts)
               (car (last (seq-filter (lambda (s) (< s bol)) starts))))))
    (unless to (user-error "No %s fold" (if (> dir 0) "next" "previous")))
    (goto-char to)
    (back-to-indentation)))

(defun drgnx-fold-next ()
  "Go to the next fold's first line."
  (interactive)
  (drgnx-fold--org-or (user-error "In Org, use the heading motions") (drgnx-fold--step 1)))

(defun drgnx-fold-previous ()
  "Go to the previous fold's first line."
  (interactive)
  (drgnx-fold--org-or (user-error "In Org, use the heading motions") (drgnx-fold--step -1)))

;;;; Mode, evil, hideshow

(defvar drgnx-fold-mode-map (make-sparse-keymap)
  "Keys of folding (the Emacs profile binds hideshow's `C-c @' keys here, keys/emacs.eld).")

(define-minor-mode drgnx-fold-mode
  "Folding on the line model (module editor/fold): its keys, and evil's fold keys act on drgnx's folds."
  :global t :keymap drgnx-fold-mode-map :group 'drgnx-fold)

(defun drgnx-fold--with-provider (list)
  "LIST, an `evil-fold-list', with drgnx's folds first (once)."
  (cons '((drgnx-fold-mode)
          :open-all drgnx-fold-unfold-all :close-all drgnx-fold-fold-all
          :toggle drgnx-fold-toggle :open drgnx-fold-unfold :open-rec drgnx-fold-unfold-recursive
          :close drgnx-fold-fold)
        (drgnx-fold--without-provider list)))

(defun drgnx-fold--without-provider (list)
  "LIST, an `evil-fold-list', without drgnx's folds."
  (seq-remove (lambda (e) (equal (car e) '(drgnx-fold-mode))) list))

(defun drgnx-fold--evil-provider ()
  "Put drgnx's folds first in evil's `evil-fold-list', so `zc', `zo', `za', `zM', `zR' and the rest act on them."
  (when (boundp 'evil-fold-list)
    (setq evil-fold-list (drgnx-fold--with-provider evil-fold-list))))

(defun drgnx-fold--hideshow-note ()
  "`hs-minor-mode-hook': hideshow's folds and drgnx's are apart; say so once."
  (when (bound-and-true-p hs-minor-mode)
    (drgnx-notify 'fold 'info "hideshow's folds are separate from drgnx's (Fold, Unfold): the scroll bar and the minimap do not see them"
                  :id 'hideshow)))

(defconst drgnx-fold--commands
  '((edit-fold "Fold" drgnx-fold-fold "Fold the block at point")
    (edit-unfold "Unfold" drgnx-fold-unfold "Unfold the block at point")
    (fold-toggle "Toggle Fold" drgnx-fold-toggle "Fold or unfold the block at point")
    (fold-recursive "Fold Recursively" drgnx-fold-fold-recursive "Fold the block at point and every block inside it")
    (unfold-recursive "Unfold Recursively" drgnx-fold-unfold-recursive "Unfold the block at point and every block inside it")
    (fold-all "Fold All" drgnx-fold-fold-all "Fold every block in the file")
    (unfold-all "Unfold All" drgnx-fold-unfold-all "Unfold every fold in the file")
    (fold-level "Fold Level…" drgnx-fold-fold-level "Fold every block at a nesting level (1–7)")
    (fold-more "Fold One Level More" drgnx-fold-more "Fold the deepest blocks still open (Vim's z m)")
    (fold-less "Fold One Level Less" drgnx-fold-less "Open the deepest folded blocks (Vim's z r)")
    (fold-kind "Fold by Kind…" drgnx-fold-fold-kind "Fold every function, class, comment, import, test, region or cell")
    (fold-focus "Fold All Except Here" drgnx-fold-fold-focus "Fold every block but those holding the cursor or the selection")
    (unfold-focus "Unfold All Except Here" drgnx-fold-unfold-focus "Unfold every fold but those holding the cursor or the selection")
    (fold-create "Create Fold from Selection" drgnx-fold-create "Fold the selected lines, with an optional name")
    (fold-remove "Remove Manual Fold" drgnx-fold-remove "Remove the fold made from a selection at the cursor")
    (fold-rename "Name Fold…" drgnx-fold-rename "Name the fold made from a selection at the cursor")
    (fold-next "Next Fold" drgnx-fold-next "Go to the next fold's first line")
    (fold-previous "Previous Fold" drgnx-fold-previous "Go to the previous fold's first line"))
  "The module's commands: (ID TITLE FUNCTION DOC) each.")

(defun drgnx-fold--teardown ()
  "The module off: its mode, notes and evil provider gone, every fold unfolded."
  (drgnx-fold-mode -1)
  (when (boundp 'evil-fold-list)
    (setq evil-fold-list (drgnx-fold--without-provider evil-fold-list)))
  (remove-hook 'hs-minor-mode-hook #'drgnx-fold--hideshow-note)
  (dolist (b (buffer-list))
    (with-current-buffer b
      (mapc #'delete-overlay (drgnx-fold--overlays))
      (drgnx-fold--report)
      (when (local-variable-p 'nidhogg-treesit-fold-query) (kill-local-variable 'nidhogg-treesit-fold-query))
      (setq drgnx-fold--sources nil drgnx-fold--manual nil drgnx-fold--level nil drgnx-fold--bounds nil)))
  (clrhash drgnx-fold--queries))

(drgnx-module-define 'editor/fold
                     :doc "Folding as in VS Code on the line model: by indentation, headings and cells; fold all, by level, by kind, all but here; manual and named folds."
                     :stage 'startup
                     :teardown #'drgnx-fold--teardown
                     :setup (lambda ()
                              (pcase-dolist (`(,id ,title ,fn ,doc) drgnx-fold--commands)
                                (drgnx-command-define id :category "Edit" :title title :command fn :scope 'editing
                                                      :doc doc))
                              (drgnx-fold-mode 1)
                              (add-hook 'hs-minor-mode-hook #'drgnx-fold--hideshow-note)
                              (with-eval-after-load 'evil (drgnx-fold--evil-provider))))

(provide 'drgnx-fold)
;;; drgnx-fold.el ends here
