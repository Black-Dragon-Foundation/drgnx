;;; drgnx-minimap-search.el --- The minimap's focus, search, line selection and outline sync -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Part of the editor/minimap module (docs/guide/minimap.md; design X1, X2, X7).
;; - Search (X1): the hits of the buffer's search come from the line model's scan (`nidhogg-lines-search', Rust, in
;;   4 ms slices; core/drgnx-marks.el runs it for isearch) and the minimap draws them as bars with the current one
;;   ringed (`:hit' in its spec).  A query the model cannot read falls back to Lisp's `re-search-forward', so the
;;   count is always `how-many''s.
;; - Focus (`minimap-focus'): the minimap stays open and takes keys: `j'/`k' (and the arrows) move a row, `/' searches
;;   without leaving it, `n'/`N' go from hit to hit ("12 of 87"), `SPC' peeks, `z' folds the range there, `RET' jumps,
;;   `Esc' leaves with point where it was.
;; - Selection (X2): a Shift-drag on the minimap selects whole lines (Nidhogg's `select-start', `select-extend' and
;;   `select-end' events); at its end a chip offers Copy, Fold, Pin and Ask Agent.
;; - Outline sync (X7): the label under the pointer (`label-hover', sent once per change) lights its row in the
;;   Outline, locally: Sjá names the row (`at-line'), an overlay lights it; no hub call.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-minimap-peek)

(declare-function drgnx-fold-toggle "drgnx-fold" ())
(declare-function drgnx-fold-create "drgnx-fold" (beg end &optional name))
(declare-function drgnx-pin-region "drgnx-sticky" (beg end &optional name))
(declare-function drgnx-agents-ask-about-this "drgnx-agents-ask" ())
(declare-function drgnx-minimap--place "drgnx-minimap" (window on))
(declare-function drgnx-minimap-window-p "drgnx-minimap" (window))
(declare-function drgnx-outline--handle "drgnx-outline" ())
(declare-function drgnx-view-row-start "drgnx-view" (buffer id))
(declare-function nidhogg-lines-search "nidhogg-lines.c" (buffer query &optional literal case-fold))
(declare-function nidhogg-lines-search-step "nidhogg-lines.c" (buffer))
(declare-function nidhogg-lines-search-hits "nidhogg-lines.c" (buffer &optional beg end))
(declare-function nidhogg-lines-search-current "nidhogg-lines.c" (buffer pos))
(declare-function nidhogg-view-get "nidhogg-views" (h what &optional arg arg2))
(defvar drgnx-outline-buffer-name)

;;;; Search: the line model's scan, else Lisp's

(defun drgnx-minimap-search-run (query regexp case-fold)
  "Search the current buffer's whole text for QUERY (a regexp when REGEXP, folding case with CASE-FOLD) to its end:
the hits as (POS . END), in order, empty matches left out.  The line model scans when it can read QUERY (its hits are
then the minimap's); else `re-search-forward' or `search-forward' do, and the model's search is ended."
  (let ((ans (and (drgnx-minimap--model-p) (fboundp 'nidhogg-lines-search)
                  (nidhogg-lines-search nil query (not regexp) (and case-fold t)))))
    (while (eq ans 'running) (setq ans (nidhogg-lines-search-step nil)))
    (if (numberp ans)
        (nidhogg-lines-search-hits nil)
      (when (and (drgnx-minimap--model-p) (fboundp 'nidhogg-lines-search)) (nidhogg-lines-search nil nil))
      (drgnx-minimap-search-lisp query regexp case-fold))))

(defun drgnx-minimap-search-lisp (query regexp case-fold)
  "QUERY's hits in the current buffer as Lisp finds them: (POS . END) each, empty matches left out (`how-many''s)."
  (let ((case-fold-search case-fold) hits)
    (save-excursion
      (goto-char (point-min))
      (while (condition-case nil
                 (if regexp (re-search-forward query nil t) (search-forward query nil t))
               (invalid-regexp nil))
        (if (= (match-beginning 0) (match-end 0))
            (unless (eobp) (forward-char 1))
          (push (cons (match-beginning 0) (match-end 0)) hits))))
    (nreverse hits)))

;;;; Focus

(defvar drgnx-minimap--focus nil
  "The focused minimap: a plist (:window W :cursor POS :point P :start S :hits HITS :model BOOL), or nil.")

(defun drgnx-minimap-focus-window ()
  "The window whose minimap has the focus, or nil."
  (plist-get drgnx-minimap--focus :window))

(defun drgnx-minimap--focus-move (pos)
  "Put the focused minimap's cursor on POS's line: its window shows the line in the middle and the row flashes."
  (let ((w (plist-get drgnx-minimap--focus :window)))
    (with-current-buffer (window-buffer w)
      (let ((bol (save-excursion (goto-char pos) (line-beginning-position))))
        (setq drgnx-minimap--focus (plist-put drgnx-minimap--focus :cursor bol))
        (set-window-point w bol)
        (with-selected-window w (recenter))
        (when (fboundp 'glitnir-minimap-flash) (glitnir-minimap-flash w bol))))))

(defun drgnx-minimap-focus ()
  "Give the selected window's minimap the focus: it stays open and takes the keys of `drgnx-minimap-focus-map'."
  (interactive)
  (let ((w (selected-window)))
    (unless (and (fboundp 'drgnx-minimap-window-p) (drgnx-minimap-window-p w))
      (user-error "No minimap in this window"))
    (setq drgnx-minimap--focus (list :window w :cursor (line-beginning-position) :point (point)
                                     :start (window-start w)))
    (drgnx-minimap--place w t)
    (set-transient-map drgnx-minimap-focus-map #'drgnx-minimap--focus-keep-p #'drgnx-minimap--focus-exit)
    (message "Minimap: j/k move, / search, n/N next/previous, SPC peek, z fold, RET go, Esc leave")))

(defvar drgnx-minimap--focus-commands
  '(drgnx-minimap-focus-down drgnx-minimap-focus-up drgnx-minimap-focus-search drgnx-minimap-focus-next
                             drgnx-minimap-focus-previous drgnx-minimap-focus-peek drgnx-minimap-focus-fold)
  "The focused minimap's commands that keep the focus.")

(defun drgnx-minimap--focus-keep-p ()
  "Keep the focus while its own keys run, and while its search reads a query."
  (and drgnx-minimap--focus (or (minibufferp) (memq this-command drgnx-minimap--focus-commands))))

(defun drgnx-minimap--focus-exit ()
  "The focus ended without a jump: point and the window's start back where they were, the minimap closed again."
  (when-let* ((f drgnx-minimap--focus))
    (setq drgnx-minimap--focus nil)
    (drgnx-minimap--focus-end f t)))

(defun drgnx-minimap--focus-end (f restore)
  "End focus F: its search ended, its window's minimap placed again (closed); RESTORE puts point and the start back."
  (let ((w (plist-get f :window)))
    (when (window-live-p w)
      (with-current-buffer (window-buffer w)
        (when (and (plist-get f :model) (fboundp 'nidhogg-lines-search)) (nidhogg-lines-search nil nil)))
      (when restore
        (set-window-point w (plist-get f :point))
        (set-window-start w (plist-get f :start)))
      (drgnx-minimap--place w t))))

(defun drgnx-minimap-focus-leave ()
  "Leave the focused minimap, point where it was."
  (interactive)
  (drgnx-minimap--focus-exit))

(defun drgnx-minimap-focus-go ()
  "Go to the focused minimap's row and leave it."
  (interactive)
  (when-let* ((f drgnx-minimap--focus))
    (setq drgnx-minimap--focus nil)
    (drgnx-minimap--focus-end f nil)
    (drgnx-minimap--jump (plist-get f :window) (plist-get f :cursor))))

(defun drgnx-minimap--focus-step (n)
  "Move the focused minimap's cursor N lines."
  (with-current-buffer (window-buffer (plist-get drgnx-minimap--focus :window))
    (drgnx-minimap--focus-move (save-excursion (goto-char (plist-get drgnx-minimap--focus :cursor))
                                               (forward-line n) (point)))))

(defun drgnx-minimap-focus-down () "Move the focused minimap's row down." (interactive) (drgnx-minimap--focus-step 1))
(defun drgnx-minimap-focus-up () "Move the focused minimap's row up." (interactive) (drgnx-minimap--focus-step -1))

(defun drgnx-minimap-focus-search (query)
  "Search the focused minimap's buffer for QUERY (plain text; case folds while it is all lower case), without leaving
the minimap: its hits show, the cursor goes to the first at or after it."
  (interactive (list (read-string "Search the minimap: ")))
  (when-let* ((f drgnx-minimap--focus))
    (with-current-buffer (window-buffer (plist-get f :window))
      (let* ((hits (drgnx-minimap-search-run query nil (string= query (downcase query))))
             (model (and (drgnx-minimap--model-p) (fboundp 'nidhogg-lines-search-hits) hits
                         (equal hits (nidhogg-lines-search-hits nil)))))
        (setq drgnx-minimap--focus (plist-put (plist-put drgnx-minimap--focus :hits hits) :model model))
        (if (null hits)
            (message "No match for %s" query)
          (drgnx-minimap--focus-hit (or (seq-position hits (plist-get f :cursor) (lambda (h c) (>= (car h) c))) 0)))))))

(defun drgnx-minimap--focus-hit (i)
  "Put the focused minimap's cursor on its hit I and say which: \"12 of 87\"."
  (let* ((hits (plist-get drgnx-minimap--focus :hits)) (h (nth i hits)))
    (with-current-buffer (window-buffer (plist-get drgnx-minimap--focus :window))
      (when (and (plist-get drgnx-minimap--focus :model) (fboundp 'nidhogg-lines-search-current))
        (nidhogg-lines-search-current nil (car h))))
    (drgnx-minimap--focus-move (car h))
    (message "%d of %d" (1+ i) (length hits))))

(defun drgnx-minimap--focus-turn (dir)
  "Go to the next hit after the focused minimap's cursor (DIR > 0) or the previous one before it, wrapping."
  (let* ((hits (plist-get drgnx-minimap--focus :hits)) (c (plist-get drgnx-minimap--focus :cursor))
         (cend (with-current-buffer (window-buffer (plist-get drgnx-minimap--focus :window))
                 (save-excursion (goto-char c) (line-end-position)))))
    (if (null hits)
        (message "Search first: /")
      (drgnx-minimap--focus-hit
       (if (> dir 0)
           (or (seq-position hits cend (lambda (h e) (> (car h) e))) 0)
         (or (cl-position-if (lambda (h) (< (car h) c)) hits :from-end t) (1- (length hits))))))))

(defun drgnx-minimap-focus-next () "The focused minimap's next hit." (interactive) (drgnx-minimap--focus-turn 1))
(defun drgnx-minimap-focus-previous () "The focused minimap's previous hit." (interactive) (drgnx-minimap--focus-turn -1))

(defun drgnx-minimap-focus-peek ()
  "Peek at the focused minimap's row."
  (interactive)
  (when-let* ((f drgnx-minimap--focus))
    (drgnx-minimap-peek-show (plist-get f :window) (plist-get f :cursor))))

(defun drgnx-minimap-focus-fold ()
  "Fold or unfold the range at the focused minimap's row."
  (interactive)
  (when-let* ((f drgnx-minimap--focus) ((fboundp 'drgnx-fold-toggle)))
    (with-selected-window (plist-get f :window)
      (save-excursion (goto-char (plist-get f :cursor)) (drgnx-fold-toggle)))))

(defvar drgnx-minimap-focus-map
  (let ((m (make-sparse-keymap)))
    (dolist (k '("j" "<down>")) (define-key m (kbd k) #'drgnx-minimap-focus-down))
    (dolist (k '("k" "<up>")) (define-key m (kbd k) #'drgnx-minimap-focus-up))
    (define-key m "/" #'drgnx-minimap-focus-search)
    (define-key m "n" #'drgnx-minimap-focus-next)
    (define-key m "N" #'drgnx-minimap-focus-previous)
    (define-key m " " #'drgnx-minimap-focus-peek)
    (define-key m "z" #'drgnx-minimap-focus-fold)
    (define-key m (kbd "RET") #'drgnx-minimap-focus-go)
    (define-key m [return] #'drgnx-minimap-focus-go)
    (define-key m [escape] #'drgnx-minimap-focus-leave)
    m)
  "The keys of a focused minimap (`minimap-focus').")

;;;; Line selection (X2)

(defvar drgnx-minimap--select nil "The minimap's line selection in progress: (WINDOW . ANCHOR), or nil.")

(defun drgnx-minimap--select-lines (window anchor pos)
  "Select in WINDOW's buffer the whole lines from ANCHOR's to POS's (either order); return (BEG . END)."
  (with-current-buffer (window-buffer window)
    (let* ((a (save-excursion (goto-char (min anchor pos)) (line-beginning-position)))
           (z (save-excursion (goto-char (max anchor pos)) (forward-line 1) (point))))
      (set-mark a)
      (set-window-point window z)
      (goto-char z)
      (activate-mark)
      (cons a z))))

(defconst drgnx-minimap--chip-actions
  '(("c" "Copy" drgnx-minimap-chip-copy) ("f" "Fold" drgnx-minimap-chip-fold) ("p" "Pin" drgnx-minimap-chip-pin)
    ("a" "Ask Agent" drgnx-minimap-chip-ask))
  "The selection chip's actions: (KEY TITLE COMMAND) each.")

(defun drgnx-minimap--chip-text (lines)
  "The selection chip's text: the actions, each a span with its key and `drgnx-minimap-chip' (the command)."
  (concat (format " %d line%s " lines (if (= lines 1) "" "s"))
          (mapconcat (lambda (a)
                       (propertize (format " [%s] %s " (nth 0 a) (nth 1 a)) 'drgnx-minimap-chip (nth 2 a)
                                   'mouse-face 'drgnx-hover 'face 'drgnx-ui-text))
                     drgnx-minimap--chip-actions "")))

(defun drgnx-minimap--chip-region ()
  "The selection the chip acts on: (WINDOW BEG END), from the card."
  (let ((card drgnx-minimap--card))
    (list (aref card 2) (car (aref card 3)) (cdr (aref card 3)))))

(defmacro drgnx-minimap--with-chip (args &rest body)
  "BODY with ARGS (WINDOW BEG END) bound to the chip's selection, the chip hidden and WINDOW selected."
  (declare (indent 1))
  `(when drgnx-minimap--card
     (cl-destructuring-bind ,args (drgnx-minimap--chip-region)
       (drgnx-minimap-card-hide)
       (when (window-live-p ,(car args))
         (select-window ,(car args))
         ,@body))))

(defun drgnx-minimap-chip-copy ()
  "Copy the minimap's selected lines."
  (interactive)
  (drgnx-minimap--with-chip (w beg end)
    (ignore w)
    (kill-ring-save beg end)
    (message "Copied %d lines" (count-lines beg end))))

(defun drgnx-minimap-chip-fold ()
  "Fold the minimap's selected lines (a fold of their own, unnamed)."
  (interactive)
  (drgnx-minimap--with-chip (w beg end)
    (ignore w)
    (if (fboundp 'drgnx-fold-create) (drgnx-fold-create beg end) (user-error "Folding is off"))))

(defun drgnx-minimap-chip-pin ()
  "Pin the minimap's selected lines."
  (interactive)
  (drgnx-minimap--with-chip (w beg end)
    (ignore w)
    (if (fboundp 'drgnx-pin-region) (drgnx-pin-region beg end) (user-error "Pinned regions are off"))))

(defun drgnx-minimap-chip-ask ()
  "Ask an agent about the minimap's selected lines: the composer opens with them attached."
  (interactive)
  (drgnx-minimap--with-chip (w beg end)
    (ignore w)
    (set-mark beg) (goto-char end) (activate-mark)
    (if (fboundp 'drgnx-agents-ask-about-this) (drgnx-agents-ask-about-this) (user-error "The agent panel is off"))))

(defun drgnx-minimap-chip-click (event)
  "A click on the selection chip (EVENT): run the action clicked."
  (interactive "e")
  (let* ((posn (event-start event)) (cw (posn-window posn))
         (cmd (and (windowp cw) (posn-point posn)
                   (get-text-property (posn-point posn) 'drgnx-minimap-chip (window-buffer cw)))))
    (if cmd (call-interactively cmd) (drgnx-minimap-card-hide))))

(defvar drgnx-minimap-chip-map
  (let ((m (make-sparse-keymap)))
    (pcase-dolist (`(,k ,_ ,cmd) drgnx-minimap--chip-actions) (define-key m k cmd))
    (define-key m [escape] #'drgnx-minimap-card-hide)
    (define-key m [down-mouse-1] #'ignore)
    (define-key m [mouse-1] #'drgnx-minimap-chip-click)
    m)
  "The selection chip's keys: c, f, p, a and a click on an action; Esc closes it.")

(defvar drgnx-minimap--chip-buffer " *drgnx-minimap-chip*" "The selection chip's buffer's name.")

(defun drgnx-minimap--select-event (kind window pos)
  "A step KIND of a Shift-drag on WINDOW's minimap at POS: select the lines, and at its end show the chip."
  (pcase kind
    ('select-start
     (drgnx-minimap-card-hide)
     (setq drgnx-minimap--select (cons window pos))
     (drgnx-minimap--select-lines window pos pos))
    ('select-extend
     (when (eq (car drgnx-minimap--select) window)
       (drgnx-minimap--select-lines window (cdr drgnx-minimap--select) pos)))
    ('select-end
     (when (eq (car drgnx-minimap--select) window)
       (let* ((range (drgnx-minimap--select-lines window (cdr drgnx-minimap--select) pos))
              (lines (with-current-buffer (window-buffer window) (count-lines (car range) (cdr range))))
              (cb (get-buffer-create drgnx-minimap--chip-buffer)))
         (setq drgnx-minimap--select nil)
         (with-current-buffer cb
           (let ((inhibit-read-only t)) (erase-buffer) (insert (drgnx-minimap--chip-text lines)))
           (setq-local cursor-type nil truncate-lines t buffer-read-only t)
           (buffer-disable-undo))
         (drgnx-minimap--show-card 'chip window range 1 (cons "Selected lines" "Esc close") cb 1
                                   drgnx-minimap-chip-map))))))

;;;; Outline sync (X7)

(defvar drgnx-minimap--outline-lit nil "The overlay lighting the Outline's row of the hovered label, or nil.")

(defun drgnx-minimap--label-hover (window pos)
  "The label under the pointer on WINDOW's minimap changed: light its definition's row in the Outline (POS its line's
start), or nothing lit (POS nil)."
  (let ((outline (and (boundp 'drgnx-outline-buffer-name) (get-buffer drgnx-outline-buffer-name))))
    (when (overlayp drgnx-minimap--outline-lit) (delete-overlay drgnx-minimap--outline-lit))
    (setq drgnx-minimap--outline-lit nil)
    (when (and pos outline (fboundp 'drgnx-outline--handle))
      (let ((line (with-current-buffer (window-buffer window) (line-number-at-pos pos t))))
        (with-current-buffer outline
          (when-let* ((h (drgnx-outline--handle))
                      (id (nidhogg-view-get h 'at-line "order" line))
                      (start (drgnx-view-row-start nil id)))
            (setq drgnx-minimap--outline-lit
                  (make-overlay start (save-excursion (goto-char start) (line-beginning-position 2))))
            (overlay-put drgnx-minimap--outline-lit 'face 'drgnx-hover)
            (overlay-put drgnx-minimap--outline-lit 'drgnx-minimap-lit t)))))))

;;;; Events and setup

(defun drgnx-minimap--search-event (kind window pos)
  "`glitnir-minimap-functions': the selection's steps and the label hover."
  (when (window-live-p window)
    (pcase kind
      ((or 'select-start 'select-extend 'select-end) (drgnx-minimap--select-event kind window pos))
      ('label-hover (drgnx-minimap--label-hover window pos)))))

(defun drgnx-minimap-search-on ()
  "The module's setup of this file: the selection and hover events."
  (add-hook 'glitnir-minimap-functions #'drgnx-minimap--search-event))

(defun drgnx-minimap-search-off ()
  "Undo `drgnx-minimap-search-on': the events gone, a focus left, the lit row and the chip's buffer gone."
  (remove-hook 'glitnir-minimap-functions #'drgnx-minimap--search-event)
  (when drgnx-minimap--focus (drgnx-minimap--focus-exit))
  (when (overlayp drgnx-minimap--outline-lit) (delete-overlay drgnx-minimap--outline-lit))
  (setq drgnx-minimap--outline-lit nil drgnx-minimap--select nil)
  (when (get-buffer drgnx-minimap--chip-buffer) (kill-buffer drgnx-minimap--chip-buffer)))

(provide 'drgnx-minimap-search)
;;; drgnx-minimap-search.el ends here
