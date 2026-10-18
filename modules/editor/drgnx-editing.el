;;; drgnx-editing.el --- Module editor/editing: folding, case, selection -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Editing commands people expect from VS Code, on built-ins: fold and unfold (hideshow in code,
;; outline elsewhere), change case (camelCase, snake_case, kebab-case, cycle), expand and shrink
;; the selection (tree-sitter nodes when the buffer has a parser, else words and balanced
;; expressions), go to line; the VS Code line commands (move, select, duplicate, delete, new line
;; above/below), redo, comment, back/forward; VS Code's cursor moves and deletes (Home, End, word,
;; file start/end, delete word or line left — Cmd+←, Option+←, Cmd+⌫ on a Mac).  See docs/guide/modules.md.

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

(defcustom drgnx-editing-prefix-delay 0.3
  "Seconds C-c or C-x wait with a selection for a key that makes it Emacs' prefix; nil: act at once.
In the VS Code profile C-c copies and C-x cuts the selection.  Typed as the start of `C-x b', `C-x C-s' or a
mode's `C-c C-c', they would cut or copy the text first.  So they wait this long for the next key: one that
arrives in time drops the selection and goes on as the prefix; none, and they copy or cut.  Like CUA mode's
prefix delay.  Keys that are no prefix (Cmd+C on a Mac) act at once."
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
            (if (eq event ?\C-g)
                (progn (deactivate-mark) (keyboard-quit))    ; C-x C-g would be undefined
              (drgnx-editing--hand-back (append (listify-key-sequence keys) (list event))))
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
                                        (go-line "Go to Line…" goto-line "Go to a line number")
                                        (edit-select-all "Select All" mark-whole-buffer "Select the whole buffer")
                                        (edit-select-line "Select Line" drgnx-editing-select-line "Select the line; again for the next")
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
                       (add-to-list 'emulation-mode-map-alists 'drgnx-editing--region-alist)))

(provide 'drgnx-editing)
;;; drgnx-editing.el ends here
