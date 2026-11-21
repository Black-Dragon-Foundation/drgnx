;;; drgnx-editing.el --- Module editor/editing: case, selection, lines -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Editing commands people expect from VS Code, on built-ins (folding is editor/fold's): change case (camelCase, snake_case, kebab-case, cycle), expand and shrink
;; the selection (tree-sitter nodes when the buffer has a parser, else words and balanced
;; expressions), go to line; the VS Code line commands (move, select, duplicate, delete, new line
;; above/below), redo, comment, back/forward; VS Code's cursor moves and deletes (Home, End, word,
;; file start/end, delete word or line left — Cmd+←, Option+←, Cmd+⌫ on a Mac).  See docs/guide/modules.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-setting)
(declare-function treesit-node-on "treesit.c")
(declare-function treesit-node-start "treesit.c")
(declare-function treesit-node-end "treesit.c")
(declare-function treesit-node-parent "treesit.c")

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
  "Cycle the word through camelCase → snake_case → kebab-case (a single word has nothing to cycle)."
  (interactive)
  (when-let* ((b (drgnx-editing--bounds)))
    (let ((s (buffer-substring-no-properties (car b) (cdr b))))
      (if (cdr (drgnx-editing--words s))
          (drgnx-editing--case (cond ((string-search "_" s) 'kebab) ((string-search "-" s) 'camel) (t 'snake)))
        (message "One word: nothing to cycle")))))

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

;;;; Lines

(defun drgnx-editing--move-lines (n)
  "Move the current line, or the selected lines, N lines down (up when N is negative)."
  (let ((added (and (> (buffer-size) 0) (/= (char-before (point-max)) ?\n)
                    (save-excursion (goto-char (point-max)) (insert "\n") t))))
    (let* ((region (use-region-p))
           (beg (save-excursion (goto-char (if region (region-beginning) (point))) (line-beginning-position)))
           (end (if region
                    (save-excursion (goto-char (region-end))
                                    (if (and (bolp) (> (point) (region-beginning))) (point) (line-beginning-position 2)))
                  (line-beginning-position 2)))
           (pt (- (point) beg)) (mk (and region (- (mark) beg))))
      (unless (if (> n 0) (= end (point-max)) (= beg (point-min)))    ; nothing to move past
        (let ((text (delete-and-extract-region beg end)))
          (goto-char beg)
          (forward-line n)
          (let ((at (point)))
            (insert text)
            (goto-char (+ at pt))
            (when region (set-mark (+ at mk)) (activate-mark) (setq deactivate-mark nil))))))
    (when added
      (save-excursion (goto-char (point-max)) (when (eq (char-before) ?\n) (delete-char -1))))))

(defun drgnx-editing-move-line-up ()
  "Move the line (or the selected lines) up."
  (interactive)
  (drgnx-editing--move-lines -1))

(defun drgnx-editing-move-line-down ()
  "Move the line (or the selected lines) down."
  (interactive)
  (drgnx-editing--move-lines 1))

(defun drgnx-editing-select-line ()
  "Select the line; again to add the next line."
  (interactive)
  (if (use-region-p)
      (progn (goto-char (region-end)) (forward-line 1))
    (push-mark (line-beginning-position) t t)
    (forward-line 1)))

(defun drgnx-editing-line-below ()
  "Start a new line below this one."
  (interactive)
  (end-of-line)
  (newline)
  (indent-according-to-mode))

(defun drgnx-editing-line-above ()
  "Start a new line above this one."
  (interactive)
  (beginning-of-line)
  (newline)
  (forward-line -1)
  (indent-according-to-mode))

;;;; Moving and deleting, as VS Code (Home, End, Cmd+←, Option+←, Cmd+⌫ on a Mac)

(defun drgnx-editing-line-start ()
  "Move to the line's first non-blank character; there already, to the line's very start."
  (interactive "^")
  (let ((pt (point)))
    (back-to-indentation)
    (when (= pt (point)) (move-beginning-of-line 1))))

(defun drgnx-editing-line-end () "Move to the end of the line." (interactive "^") (move-end-of-line 1))
(defun drgnx-editing-buffer-start () "Move to the start of the file (no mark set)." (interactive "^") (goto-char (point-min)))
(defun drgnx-editing-buffer-end () "Move to the end of the file (no mark set)." (interactive "^") (goto-char (point-max)))
(defun drgnx-editing-word-left () "Move to the start of the word." (interactive "^") (backward-word 1))
(defun drgnx-editing-word-right () "Move to the end of the word." (interactive "^") (forward-word 1))
(defun drgnx-editing-delete-word-back () "Delete the word before the cursor." (interactive) (backward-kill-word 1))

(defun drgnx-editing-delete-line-back ()
  "Delete from the cursor to the line's start; at the start, join the line to the one above."
  (interactive)
  (cond ((not (bolp)) (kill-line 0))
        ((not (bobp)) (delete-char -1))))

;;;; Copy, cut and paste (the VS Code profile's C-c, C-x, C-v)

(defvar drgnx-editing-region-map (make-sparse-keymap)
  "Keys active only while the mark is active: the VS Code profile's C-c and C-x (copy and cut).
Without a selection they stay Emacs' prefixes.")

(defvar drgnx-editing--region-alist (list (cons 'mark-active drgnx-editing-region-map))
  "`emulation-mode-map-alists' entry: `drgnx-editing-region-map' while the mark is active.")

(defun drgnx-editing--region-key-p ()
  "Non-nil if the key that ran this command is one of `drgnx-editing-region-map' (not the palette)."
  (let ((keys (this-command-keys-vector)))
    (and (> (length keys) 0) (eq (lookup-key drgnx-editing-region-map keys) this-command))))

(defcustom drgnx-editing-prefix-delay nil
  "Seconds C-c or C-x wait with a selection for a key that makes it Emacs' prefix; nil (the default): act at once.
In the VS Code profile C-c copies and C-x cuts the selection, at once, as VS Code's do.  Typed as the start of
`C-x b', `C-x C-s' or a mode's `C-c C-c' with a selection, they would copy or cut first: Escape drops the selection
first, and F1 or M-x reaches every command.  Set a number (0.3 was the old default) to have them wait that long for
a next key instead: one that arrives in time drops the selection and goes on as the prefix, none, and they copy or
cut, like CUA mode's prefix delay (the price is that wait on every copy and cut).  Keys that are no prefix (Cmd+C
on a Mac) always act at once."
  :type '(choice (const :tag "Act at once" nil) (number :tag "Seconds"))
  :group 'drgnx)

(defun drgnx-editing--prefix-key-p (keys)
  "Non-nil if KEYS (a vector) start a prefix sequence without the selection-only map."
  (and (> (length keys) 0)
       (let ((emulation-mode-map-alists (remq 'drgnx-editing--region-alist emulation-mode-map-alists)))
         (keymapp (key-binding keys)))))

(defun drgnx-editing--hand-back (events)
  "Drop the selection and give EVENTS to Emacs as typed.
They are `(t . EVENT)': a keyboard macro that is recording has them already."
  (deactivate-mark)
  (setq prefix-arg current-prefix-arg
        unread-command-events (append (mapcar (lambda (e) (cons t e)) events) unread-command-events)))

(defun drgnx-editing--no-selection (what)
  "Called by a region command without a selection.  Typed as its key, give the key back to Emacs
(an empty selection, the mark set and not moved, is not one); from the palette, say what is missing."
  (if (not (drgnx-editing--region-key-p))
      (user-error "Select something to %s first" what)
    (drgnx-editing--hand-back (listify-key-sequence (this-command-keys-vector)))))

(defun drgnx-editing--with-selection (action)
  "Run ACTION on the selection.  Typed as a prefix key (C-c, C-x), first wait
`drgnx-editing-prefix-delay' for a next key: if one comes, it is the prefix after all and the selection stays
untouched.  Only runs as a typed command, and the wait ends at the delay."
  (let ((keys (this-command-keys-vector)))
    (if (and drgnx-editing-prefix-delay (drgnx-editing--region-key-p) (drgnx-editing--prefix-key-p keys))
        (if-let* ((event (condition-case nil        ; a keyboard macro that ends here has no next key
                             (with-timeout (drgnx-editing-prefix-delay nil) (read-key))
                           (args-out-of-range nil))))
            (cond ((eq event ?\C-g)
                   (deactivate-mark) (keyboard-quit))    ; C-x C-g would be undefined
                  ((and (consp event) (symbolp (car event)) (string-match-p "mouse" (symbol-name (car event))))
                   ;; a click is no key of the prefix: the key acts, the click is its own event
                   (funcall action)
                   (setq unread-command-events (cons event unread-command-events)))
                  (t (drgnx-editing--hand-back (append (listify-key-sequence keys) (list event)))))
          (funcall action))
      (funcall action))))

(defun drgnx-editing-copy ()
  "Copy the selection."
  (interactive)
  (if (use-region-p)
      (drgnx-editing--with-selection (lambda () (call-interactively #'kill-ring-save)))
    (drgnx-editing--no-selection "copy")))

(defun drgnx-editing-cut ()
  "Cut the selection (in a read-only buffer, copy it)."
  (interactive)
  (if (use-region-p)
      (drgnx-editing--with-selection (lambda () (let ((kill-read-only-ok t)) (call-interactively #'kill-region))))
    (drgnx-editing--no-selection "cut")))

(defun drgnx-editing-paste (&optional arg)
  "Paste the last copy, replacing the selection.  ARG as for `yank'.
With nothing to paste, nothing changes.  The clipboard is read once: the first `current-kill' puts it in the
kill ring, so a hung owner or a terminal that refuses the read costs its timeout once."
  (interactive "*P")
  (current-kill 0)                      ; signals an empty kill ring before the selection goes
  (when (use-region-p) (delete-region (region-beginning) (region-end)))
  (deactivate-mark)
  (let ((interprogram-paste-function nil)) (yank arg)))

(defvar drgnx-editing-tab-size)
(defvar drgnx-editing-word-wrap)
(defvar drgnx-editing-word-wrap-column)
(declare-function drgnx-look-fonts--settings-apply "drgnx-look-fonts")

;;;; The Editor settings a VS Code user looks for first

(defun drgnx-editing--font-size-p (v) "Non-nil when V is a code size in pixels." (and (numberp v) (<= 6 v 72)))
(defun drgnx-editing--tab-size-p (v) "Non-nil when V is a tab size in columns." (and (integerp v) (<= 1 v 16)))

(defun drgnx-editing--apply-font-size ()
  "`:apply' of `drgnx-editing-font-size': the code font's size is redrawn (ui/look reads the setting as a layer)."
  (when (fboundp 'drgnx-look-fonts--settings-apply) (drgnx-look-fonts--settings-apply)))

(drgnx-defsetting drgnx-editing-font-size 13.5
  "The size of the code font in pixels (VS Code's editor.fontSize).  13.5 is drgnx's own code size; the code font
role (`drgnx-look-font-code') still sets a size of its own on top.  A change applies at once."
  :type 'number :group 'drgnx :scope 'global :agents 'never :apply #'drgnx-editing--apply-font-size
  :schema '(pred drgnx-editing--font-size-p "a size in pixels from 6 to 72"))

(defvar drgnx-editing--tab-saved nil
  "(TAB-WIDTH STANDARD-INDENT INDENT-TABS-MODE) the defaults `drgnx-editing-tab-size' and the spaces default replaced.")

(defun drgnx-editing--apply-tab-size ()
  "`:apply' of `drgnx-editing-tab-size': the default `tab-width' and `standard-indent', as VS Code's editor.tabSize
sets how many columns a tab and an indent are, and indents made of spaces (`indent-tabs-mode' nil by default, VS Code's
editor.insertSpaces), whatever the key profile: with a tab of 4 columns Emacs's default would turn every 4-column
indent into a tab.  Buffers whose mode sets an indent or tabs of its own (Makefile, Go) keep them."
  (unless drgnx-editing--tab-saved
    (setq drgnx-editing--tab-saved (list (default-value 'tab-width) (default-value 'standard-indent)
                                         (default-value 'indent-tabs-mode))))
  (setq-default tab-width drgnx-editing-tab-size standard-indent drgnx-editing-tab-size indent-tabs-mode nil))

(drgnx-defsetting drgnx-editing-tab-size 4
  "How many columns a tab character, and one level of indent where the mode has none of its own, take (VS Code's
editor.tabSize).  A change applies at once.  A mode that sets its own indent keeps it."
  :type 'integer :group 'drgnx :scope 'global :agents 'never :apply #'drgnx-editing--apply-tab-size
  :schema '(pred drgnx-editing--tab-size-p "a number of columns from 1 to 16"))

;;;; Word wrap (the wrap addendum §3.3)

;; Resolved per buffer when its major mode is set (`after-change-major-mode-hook'), and again once its file and
;; directory locals are in (`hack-local-variables-hook': a workspace file's value counts; a file's own
;; `truncate-lines' or `word-wrap' wins).  Only buffers of a code, data or text mode are touched: special buffers set
;; their own.  The mode is buffer-local state: `off' cuts (`truncate-lines'), `on' wraps at a word, `column' and
;; `bounded' wrap at `drgnx-editing-word-wrap-column' (Nidhogg's `nidhogg-wrap-column'; at the window's edge when it
;; is narrower).

(defconst drgnx-editing-wrap-auto-cut
  '(yaml-mode yaml-ts-mode toml-ts-mode conf-toml-mode nxml-mode sgml-mode html-mode mhtml-mode html-ts-mode css-mode
              css-ts-mode json-ts-mode js-json-mode)
  "Data and markup modes `auto' cuts: checked first, since several derive from `text-mode'.")

(defconst drgnx-editing-wrap-auto-prose
  '(markdown-mode markdown-ts-mode gfm-mode org-mode rst-mode adoc-mode tex-mode latex-mode LaTeX-mode git-commit-mode
                  log-edit-mode message-mode)
  "Prose modes `auto' wraps (plain `text-mode' too, matched exactly).")

(defvar-local drgnx-editing--wrap-shown nil
  "The wrap mode drgnx gave this buffer (`off', `on', `column', `bounded'), or nil when it left the buffer alone.")

(defvar-local drgnx-editing--wrap-toggled nil
  "Non-nil when Toggle Word Wrap set this buffer's wrap: it stays until the buffer is killed (no session keeps it).")

(defvar nidhogg-wrap-column)

(defun drgnx-editing--wrap-p (v) "Non-nil when V is a wrap mode." (memq v '(off on column bounded auto)))
(defun drgnx-editing--wrap-column-p (v) "Non-nil when V is a wrap column." (and (integerp v) (<= 20 v 1000)))

(defun drgnx-editing-wrap-resolve (&optional value)
  "The wrap mode VALUE (default `drgnx-editing-word-wrap' here) gives the current buffer: `off', `on', `column' or
`bounded'; nil for a buffer of another kind (left alone).  `auto' goes by the major mode: the data and markup list
cuts, the prose list (and plain `text-mode') wraps, code and configuration cut, other text modes wrap."
  (let ((value (or value drgnx-editing-word-wrap)))
    (cond ((apply #'derived-mode-p drgnx-editing-wrap-auto-cut) (if (eq value 'auto) 'off value))
          ((or (apply #'derived-mode-p drgnx-editing-wrap-auto-prose) (eq major-mode 'text-mode))
           (if (eq value 'auto) 'on value))
          ((derived-mode-p 'prog-mode 'conf-mode) (if (eq value 'auto) 'off value))
          ((derived-mode-p 'text-mode) (if (eq value 'auto) 'on value)))))

(defun drgnx-editing--wrap-set (mode)
  "Give the current buffer wrap MODE (`off', `on', `column', `bounded'), buffer-locally."
  (setq drgnx-editing--wrap-shown mode)
  ;; narrow windows too: Emacs cuts a window under 50 columns whatever `truncate-lines' says
  (setq-local truncate-lines (eq mode 'off) word-wrap (not (eq mode 'off)) truncate-partial-width-windows nil)
  (setq-local nidhogg-wrap-column (and (memq mode '(column bounded)) drgnx-editing-word-wrap-column))
  ;; a line wrapped at a word shows no continuation arrows (VS Code draws none: audit G4)
  (setq-local fringe-indicator-alist
              (if (eq mode 'off) (default-value 'fringe-indicator-alist)
                (cons '(continuation nil nil)
                      (assq-delete-all 'continuation (copy-alist (default-value 'fringe-indicator-alist)))))))

(defun drgnx-editing--wrap-clear ()
  "Take back what `drgnx-editing--wrap-set' gave the current buffer."
  (when drgnx-editing--wrap-shown
    (dolist (v '(truncate-lines word-wrap truncate-partial-width-windows nidhogg-wrap-column fringe-indicator-alist))
      (kill-local-variable v))
    (setq drgnx-editing--wrap-shown nil drgnx-editing--wrap-toggled nil)))

(defun drgnx-editing--wrap-buffer ()
  "`after-change-major-mode-hook' and `hack-local-variables-hook': the current buffer's wrap from the setting.  A file
or directory's own `truncate-lines' or `word-wrap' wins, and so does Toggle Word Wrap."
  (unless (or drgnx-editing--wrap-toggled
              (assq 'truncate-lines file-local-variables-alist) (assq 'word-wrap file-local-variables-alist)
              (assq 'truncate-lines dir-local-variables-alist) (assq 'word-wrap dir-local-variables-alist))
    (let ((mode (drgnx-editing-wrap-resolve)))
      (if mode (drgnx-editing--wrap-set mode) (drgnx-editing--wrap-clear)))))

(defun drgnx-editing--apply-word-wrap ()
  "`:apply' of the wrap settings: every open buffer again."
  (dolist (b (buffer-list))
    (with-current-buffer b (drgnx-editing--wrap-buffer))))

(defun drgnx-editing--wrap-org ()
  "Under `auto' and `on', drgnx owns Org's wrapping: `org-startup-truncated' nil (Org sets `truncate-lines' from it
itself), as the module's claim (`drgnx-module-set'): a value the user set in settings.el, custom.el or their Lisp
wins over it, and the module's undo drops it.  A buffer's wrap is resolved after Org's own mode body, so a later
change of the setting reaches Org buffers through the hook."
  (when (memq (default-value 'drgnx-editing-word-wrap) '(auto on))
    (drgnx-module-set 'org-startup-truncated nil)))

(drgnx-defsetting drgnx-editing-word-wrap 'auto
  "What a line longer than its window does, as VS Code's editor.wordWrap: `off' runs it off the edge, `on' continues it
on the next row at a word, `column' wraps it at `drgnx-editing-word-wrap-column' (VS Code's wordWrapColumn),
`bounded' at that column or the window's edge, whichever comes first.  `auto' (the default) wraps prose (Markdown,
Org, plain text) and cuts code, configuration and data (YAML, HTML, JSON).  Buffers of other kinds keep their own.
A `(:mode MODE …)' entry gives one language another; Toggle Word Wrap flips one buffer.  A change applies at once."
  :type '(choice (const auto) (const on) (const off) (const column) (const bounded)) :group 'drgnx :scope 'buffer
  :agents 'never :apply #'drgnx-editing--apply-word-wrap :schema '(enum off on column bounded auto))

(drgnx-defsetting drgnx-editing-word-wrap-column 80
  "The column long lines wrap at when `drgnx-editing-word-wrap' is `column' or `bounded' (VS Code's
editor.wordWrapColumn); the other modes ignore it.  A change applies at once."
  :type 'integer :group 'drgnx :scope 'buffer :agents 'never :apply #'drgnx-editing--apply-word-wrap
  :schema '(pred drgnx-editing--wrap-column-p "a column from 20 to 1000"))

(defun drgnx-editing-toggle-word-wrap ()
  "Wrap long lines at a word, or cut them at the window's edge, in this buffer only (until it is killed)."
  (interactive)
  (drgnx-editing--wrap-set (if truncate-lines 'on 'off))
  (setq drgnx-editing--wrap-toggled t)
  (force-mode-line-update)
  (message "Word wrap %s" (if truncate-lines "off" "on")))

(drgnx-module-define 'editor/editing
                     :doc "Change case, expand and shrink the selection, go to line."
                     :stage 'startup
                     :setup
                     (lambda ()
                       (pcase-dolist (`(,id ,title ,fn ,doc)
                                      '((edit-case-cycle "Change Case: Cycle" drgnx-editing-case-cycle "camelCase → snake_case → kebab-case")
                                        (edit-case-camel "Change Case: camelCase" drgnx-editing-case-camel "The word or selection in camelCase")
                                        (edit-case-snake "Change Case: snake_case" drgnx-editing-case-snake "The word or selection in snake_case")
                                        (edit-case-kebab "Change Case: kebab-case" drgnx-editing-case-kebab "The word or selection in kebab-case")
                                        (edit-expand "Expand Selection" drgnx-editing-expand "Select the enclosing word, then expression, …")
                                        (edit-shrink "Shrink Selection" drgnx-editing-shrink "Back to the previous selection")
                                        (go-line "Go to Line…" goto-line "Go to a line number")
                                        (edit-select-all "Select All" mark-whole-buffer "Select the whole buffer")
                                        (edit-select-line "Select Line" drgnx-editing-select-line "Select the line; again for the next")
                                        (edit-undo "Undo" undo "Undo the last change (in the selection, with one)")
                                        (edit-redo "Redo" undo-redo "Redo the last undone change")
                                        (edit-comment "Toggle Comment" comment-line "Comment or uncomment the line or the selection")
                                        (edit-delete-line "Delete Line" kill-whole-line "Delete the whole line")
                                        (edit-move-up "Move Line Up" drgnx-editing-move-line-up "Move the line or the selected lines up")
                                        (edit-move-down "Move Line Down" drgnx-editing-move-line-down "Move the line or the selected lines down")
                                        (edit-duplicate "Duplicate Line" duplicate-dwim "Copy the line (or the selection) below")
                                        (edit-line-below "New Line Below" drgnx-editing-line-below "Start a new line below this one")
                                        (edit-line-above "New Line Above" drgnx-editing-line-above "Start a new line above this one")
                                        (edit-line-start "Cursor to Line Start" drgnx-editing-line-start "The first non-blank character, then the line's start")
                                        (edit-line-end "Cursor to Line End" drgnx-editing-line-end "The end of the line")
                                        (edit-buffer-start "Cursor to File Start" drgnx-editing-buffer-start "The start of the file")
                                        (edit-buffer-end "Cursor to File End" drgnx-editing-buffer-end "The end of the file")
                                        (edit-word-left "Cursor Word Left" drgnx-editing-word-left "The start of the word")
                                        (edit-word-right "Cursor Word Right" drgnx-editing-word-right "The end of the word")
                                        (edit-delete-word-back "Delete Word Left" drgnx-editing-delete-word-back "Delete the word before the cursor")
                                        (edit-delete-line-back "Delete to Line Start" drgnx-editing-delete-line-back "Delete from the cursor to the line's start")
                                        (go-back "Back" xref-go-back "Return to where you jumped from")
                                        (go-forward "Forward" xref-go-forward "Undo a Back")
                                        (edit-copy "Copy" drgnx-editing-copy "Copy the selection")
                                        (edit-cut "Cut" drgnx-editing-cut "Cut the selection")
                                        (edit-paste "Paste" drgnx-editing-paste "Paste the last copy, replacing the selection")))
                         (drgnx-command-define id :category (if (string-prefix-p "go-" (symbol-name id)) "Go" "Edit") :title title
                                               :command fn :scope 'editing :doc doc))
                       (drgnx-command-define 'face-toggle-wrap :category "View" :title "Toggle Word Wrap" :menu '("View")
                                             :command #'drgnx-editing-toggle-word-wrap
                                             :doc "Wrap long lines at a word, or cut them at the window's edge, in this buffer")
                       (drgnx-editing--apply-tab-size)
                       (add-hook 'after-change-major-mode-hook #'drgnx-editing--wrap-buffer)
                       (add-hook 'hack-local-variables-hook #'drgnx-editing--wrap-buffer)
                       (drgnx-editing--apply-word-wrap)
                       (drgnx-editing--wrap-org)
                       (add-to-list 'emulation-mode-map-alists 'drgnx-editing--region-alist))
                     :teardown
                     (lambda ()
                       (dolist (b (buffer-list)) (with-current-buffer b (drgnx-editing--wrap-clear)))
                       (when drgnx-editing--tab-saved
                         (setq-default tab-width (nth 0 drgnx-editing--tab-saved)
                                       standard-indent (nth 1 drgnx-editing--tab-saved)
                                       indent-tabs-mode (nth 2 drgnx-editing--tab-saved))
                         (setq drgnx-editing--tab-saved nil))))

(provide 'drgnx-editing)
;;; drgnx-editing.el ends here
