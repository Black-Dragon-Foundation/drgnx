;;; drgnx-buffers.el --- The Buffers panel: open editors in the left dock -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The files you have open, in the order you opened them — switching never re-sorts, so a row
;; never moves under the pointer.  Each row: the file's icon and its name; at the right edge the git letter and the
;; close button (hidden until the row is hovered), or ● in its place while the buffer has unsaved changes.
;; The panel listens to the change bus and re-renders only when its signature (the rows and
;; their modified flags) changed; the view and the selection are restored by buffer identity,
;; and the title lives in the window, where no mode can erase it.  The active editor's row is
;; marked with an overlay, without re-rendering.  See docs/guide/workbench.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'text-property-search)
(require 'hl-line)
(require 'drgnx-wb)
(require 'drgnx-view)                   ; `drgnx-view-with-kept-windows'
(require 'drgnx-git)

(defface drgnx-buffers-close '((t :inherit shadow)) "The × of each row." :group 'drgnx)
(defface drgnx-buffers-modified '((t :inherit warning)) "The ● of a modified buffer." :group 'drgnx)
(defface drgnx-buffers-active '((t :inherit bold)) "The row of the buffer shown in the active editor." :group 'drgnx)

(defconst drgnx-buffers-buffer-name " *drgnx buffers*" "Internal (a leading space): not in C-x b or ibuffer.")

(defvar drgnx-buffers--order nil "User buffers in the order they were first seen.")
(defvar drgnx-buffers--signature nil "What the panel shows now; a refresh with the same one does nothing.")
(defvar drgnx-buffers--renders 0 "How many times the panel was rendered (tests read it).")
(defvar drgnx-buffers--active nil "Overlay on the active editor's row.")
(defvar drgnx-buffers--filter nil "Show only buffers whose names contain this text (any case), or nil.")
(defvar drgnx-buffers--title)          ; defined below

(defvar drgnx-buffers-all-windows nil
  "With several windows open: nil lists the buffers of the window you work in, t all of them.")
(declare-function drgnx-frame-buffers "drgnx-frames")
(declare-function drgnx-frames-count "drgnx-frames")

(defun drgnx-buffers--in-window ()
  "The buffers in open order: all, or with several windows those of the selected one."
  (if (and (not drgnx-buffers-all-windows) (fboundp 'drgnx-frame-buffers) (> (drgnx-frames-count) 1))
      (let ((mine (make-hash-table :test #'eq)))      ; a set: thousands of buffers stay linear
        (dolist (b (drgnx-frame-buffers)) (puthash b t mine))
        (seq-filter (lambda (b) (gethash b mine)) drgnx-buffers--order))
    drgnx-buffers--order))

(defun drgnx-buffers--shown ()
  "The buffers on rows: the window's (see `drgnx-buffers--in-window'), those the filter lets through."
  (let ((rows (drgnx-buffers--in-window)))
    (if drgnx-buffers--filter
        (let ((q (downcase drgnx-buffers--filter)))
          (seq-filter (lambda (b) (string-search q (downcase (buffer-name b)))) rows))
      rows)))

(defun drgnx-buffers-toggle-all-windows ()
  "List the buffers of every window, or of the window you work in."
  (interactive)
  (setq drgnx-buffers-all-windows (not drgnx-buffers-all-windows))
  (drgnx-buffers--refresh)
  (message "Buffers: %s" (if drgnx-buffers-all-windows "all windows" "this window")))

(defun drgnx-buffers--update-order ()
  (let* ((live (seq-filter (lambda (b) (and (buffer-live-p b) (drgnx-signal-user-buffer-p b))) drgnx-buffers--order))
         (seen (make-hash-table :test #'eq))           ; a set: thousands of buffers stay linear
         (new (progn (dolist (b live) (puthash b t seen))
                     (seq-filter (lambda (b) (and (not (gethash b seen)) (drgnx-signal-user-buffer-p b))) (buffer-list)))))
    (setq drgnx-buffers--order (append live new))))

(defvar-local drgnx-buffers--rows []
  "The buffer of each line, in order (a virtual list: the panel holds plain text).")

(defun drgnx-buffers--row (b)
  "Buffer B's row as plain text: two characters of room, then the name (window-dark.html's Open rows).  The first
lines the icon up with the Explorer's top files, the second shows the icon on a graphical frame; faces, the icon and
the right edge come from jit-lock, for visible rows."
  (concat "  " (drgnx-wb-display-name (buffer-name b)) "\n"))

(defun drgnx-buffers--index (pos) (1- (line-number-at-pos pos t)))

(defun drgnx-buffers-buffer-at (pos)
  "The buffer of the row at POS, or nil."
  (when pos
    (let ((i (drgnx-buffers--index pos)))
      (and (< -1 i (length drgnx-buffers--rows)) (aref drgnx-buffers--rows i)))))

(defun drgnx-buffers--on-control-p (posn)
  "Non-nil if POSN (a mouse position) is on a row's close button or ● at its right edge."
  (when-let* ((s (posn-string posn)))
    (and (stringp (car s)) (integerp (cdr s)) (< (cdr s) (length (car s)))
         (get-text-property (cdr s) 'drgnx-row-control (car s)))))

(defun drgnx-buffers--row-pos (b)
  "Start of buffer B's row, or nil."
  (when-let* ((i (seq-position drgnx-buffers--rows b #'eq)))
    (save-excursion (goto-char (point-min)) (forward-line i) (point))))

(defun drgnx-buffers--fontify (beg end)
  "Paint the rows between BEG and END (jit-lock): the icon, the hover highlight, and at the right edge the git
letter and the close button (`drgnx-wb-row-tail-overlay': shown on the row at point, else hidden until hovered), or
an always shown ● while the buffer has unsaved changes.  The name keeps the text colour; an ignored file is dimmed."
  (let ((point (point)))
    (save-excursion
      (goto-char beg)
      (forward-line 0)
      (let ((inhibit-read-only t) (end (save-excursion (goto-char end) (pos-eol))))
        (remove-overlays (point) (min (1+ end) (point-max)) 'drgnx-git t)
        (with-silent-modifications
          (while (< (point) end)
            (let* ((bol (point)) (eol (pos-eol)) (b (drgnx-buffers-buffer-at bol)))
              (when (and (buffer-live-p b) (< (+ bol 2) eol))
                (put-text-property bol eol 'mouse-face 'drgnx-hover-row)
                (when-let* ((icon (get-text-property 0 'display (drgnx-look-icon (drgnx-look-file-name-icon-name
                                                                                  (or (buffer-file-name b) (buffer-name b)))))))
                  (put-text-property (1+ bol) (+ bol 2) 'display (drgnx-wb-icon-gap icon)))
                (let* ((file (buffer-file-name b)) (status (and file (drgnx-git-status file)))
                       (letter (and status (car (drgnx-git-look status)))))
                  (when (eq status 'ignored) (add-face-text-property (+ bol 2) eol (cadr (drgnx-git-look status))))
                  (drgnx-wb-row-tail-overlay eol letter (and letter (drgnx-wb-git-mark-face status)) (<= bol point eol)
                                             (if (buffer-modified-p b)
                                                 (propertize (drgnx-face-glyph 'dot) 'face 'drgnx-buffers-modified
                                                             'help-echo "Unsaved changes")
                                               (propertize (drgnx-face-glyph 'close) 'help-echo "Close"))))))
            (forward-line 1))))))
  `(jit-lock-bounds ,beg . ,end))

(defun drgnx-buffers--buffer ()
  (or (get-buffer drgnx-buffers-buffer-name)
      (with-current-buffer (get-buffer-create drgnx-buffers-buffer-name)
        (drgnx-buffers-mode)
        (drgnx-buffers--refresh)
        (current-buffer))))

(defvar drgnx-buffers--pressed nil "Non-nil while a mouse button pressed in the panel is held.")
(defvar drgnx-buffers--pending nil "A refresh that waits for the button's release.")

(defun drgnx-buffers--refresh (&rest _)
  "Re-render if the rows changed; keep every window's view and selection on the same buffers.
While a button is held in the panel, wait for the release: rows never move under the pointer."
  (if drgnx-buffers--pressed (setq drgnx-buffers--pending t) (drgnx-buffers--render)))

(defun drgnx-buffers--release ()
  "The button came up: run a refresh that waited for it."
  (setq drgnx-buffers--pressed nil)
  (when drgnx-buffers--pending (setq drgnx-buffers--pending nil) (drgnx-buffers--render)))

(defun drgnx-buffers--focus-changed ()
  "Emacs lost focus: a press is over — its release will not come here (Wayland)."
  (when (and drgnx-buffers--pressed (not (seq-some #'frame-focus-state (frame-list)))) (drgnx-buffers--release)))

(defun drgnx-buffers--render ()
  (drgnx-buffers--update-order)
  (let* ((shown (drgnx-buffers--shown))          ; once per render: the rows, the signature and the row index share it
         (sig (cons drgnx-buffers--filter
                    (mapcar (lambda (b) (list b (buffer-name b) (buffer-modified-p b))) shown))))
    (unless (equal sig drgnx-buffers--signature)
      (setq drgnx-buffers--signature sig)
      (cl-incf drgnx-buffers--renders)
      (with-current-buffer (get-buffer-create drgnx-buffers-buffer-name)
        (unless (derived-mode-p 'drgnx-buffers-mode) (drgnx-buffers-mode))
        (let ((inhibit-read-only t))
          (drgnx-view-with-kept-windows (:key-at #'drgnx-buffers-buffer-at :pos-of #'drgnx-buffers--row-pos)
            (erase-buffer)
            ;; One insertion of plain text (faces: jit-lock, for the visible rows only).
            (insert (mapconcat #'drgnx-buffers--row shown ""))
            (setq drgnx-buffers--rows (vconcat shown)))
          (when hl-line-mode (hl-line-highlight))
          (drgnx-buffers--mark-active))))))

(defun drgnx-buffers--mark-active (&rest _)
  "Mark the row of the buffer in the active editor (an overlay; no re-render)."
  (when-let* ((panel (get-buffer drgnx-buffers-buffer-name)))
    (with-current-buffer panel
      (let ((pos (when-let* ((w (drgnx-wb-editor-window))) (drgnx-buffers--row-pos (window-buffer w)))))
        (unless (overlayp drgnx-buffers--active)
          (setq drgnx-buffers--active (make-overlay 1 1))
          (overlay-put drgnx-buffers--active 'face 'drgnx-buffers-active))
        (if pos
            (move-overlay drgnx-buffers--active pos (save-excursion (goto-char pos) (pos-eol)) panel)
          (delete-overlay drgnx-buffers--active))))))

;;;; Commands

(defun drgnx-buffers-close-at (pos)
  "Close (kill) the buffer of the row at POS."
  (when-let* ((b (drgnx-buffers-buffer-at pos)))
    (when (buffer-live-p b) (kill-buffer b))
    (drgnx-buffers--refresh)))

(defun drgnx-buffers-open-at (pos)
  "Show the buffer of the row at POS in the editor and focus it."
  (when-let* ((b (drgnx-buffers-buffer-at pos)))
    (when (buffer-live-p b) (drgnx-wb-show-in-editor b t))))

(defun drgnx-buffers-next () "Next row." (interactive) (forward-line 1) (when (eobp) (forward-line -1)))
(defun drgnx-buffers-previous () "Previous row." (interactive) (forward-line -1))
(defun drgnx-buffers-open () "Open the row's buffer in the editor." (interactive) (drgnx-buffers-open-at (point)))
(defun drgnx-buffers-close () "Close the row's buffer." (interactive) (drgnx-buffers-close-at (pos-bol)))
(defun drgnx-buffers--user-buffers ()
  "The live buffers on rows: those the filter and the window let through (never ones hidden)."
  (seq-filter #'buffer-live-p (drgnx-buffers--shown)))

(defun drgnx-buffers-save-all () "Save every buffer with unsaved changes (no questions)."
       (interactive) (save-some-buffers t) (drgnx-buffers--refresh))

(defun drgnx-buffers-close-saved () "Close every buffer without unsaved changes."
       (interactive)
       (dolist (b (drgnx-buffers--user-buffers)) (unless (buffer-modified-p b) (kill-buffer b)))
       (drgnx-buffers--refresh))

(defun drgnx-buffers-close-others () "Close every buffer but the one of the row here."
       (interactive)
       (let ((keep (or (drgnx-buffers-buffer-at (point)) (user-error "No buffer here"))))
         (dolist (b (drgnx-buffers--user-buffers)) (unless (eq b keep) (kill-buffer b))))
       (drgnx-buffers--refresh))

(defun drgnx-buffers-close-all () "Close every buffer in the panel (unsaved ones ask first)."
       (interactive)
       (dolist (b (drgnx-buffers--user-buffers)) (kill-buffer b))
       (drgnx-buffers--refresh))

(defun drgnx-buffers--filter-apply (text)
  "Show only buffers whose names contain TEXT."
  (setq drgnx-buffers--filter (and text (not (string-empty-p text)) text))
  (drgnx-buffers--refresh)
  (when-let* ((w (drgnx-wb-section-window 'buffers)))
    (set-window-parameter w 'header-line-format (drgnx-wb-section-header (drgnx-buffers--current-title)))))

(defun drgnx-buffers--current-title ()
  "The panel's title: the filter while one is on, else the title with its buttons."
  (if drgnx-buffers--filter (format "Open — %s" drgnx-buffers--filter) drgnx-buffers--title))

(defun drgnx-buffers-filter-clear () "Show every buffer again." (interactive) (drgnx-buffers--filter-apply nil))

(defun drgnx-buffers-filter ()
  "Show only buffers whose names contain what you type (live); empty input shows all."
  (interactive)
  (minibuffer-with-setup-hook
      (lambda () (add-hook 'after-change-functions
                           (lambda (&rest _) (drgnx-buffers--filter-apply (minibuffer-contents-no-properties))) nil t))
    (condition-case nil
        (drgnx-buffers--filter-apply (read-string "Filter buffers: " drgnx-buffers--filter))
      (quit (drgnx-buffers--filter-apply nil)))))

(defun drgnx-buffers-mouse-close (event)
  "Middle click: close that row's buffer (as VS Code)."
  (interactive "e")
  (let ((pos (posn-point (event-end event))))
    (when (integer-or-marker-p pos)
      (with-current-buffer (window-buffer (posn-window (event-end event))) (drgnx-buffers-close-at pos)))))

(defun drgnx-buffers-focus () "Show the sidebar and focus the Buffers panel."
       (interactive) (drgnx-wb-focus-section 'buffers))

(defun drgnx-buffers-mouse-press (event)
  "Press: select the row; the action happens on release."
  (interactive "e")
  (setq drgnx-buffers--pressed t)
  (let* ((posn (event-start event)) (w (posn-window posn)) (pos (posn-point posn)))
    (when (window-live-p w)
      (unless (eq w (selected-window)) (select-window w))
      (when (integer-or-marker-p pos) (goto-char pos)))))

(defun drgnx-buffers-mouse-click (event)
  "Release: the close button (or ●) at the row's right edge closes that row's buffer; elsewhere on the row, show it
in the editor."
  (interactive "e")
  (let* ((posn (event-end event)) (pos (posn-point posn)) (w (posn-window posn)))
    ;; Act on the rows the user saw, then run a refresh that waited for the release.
    (when (and (integer-or-marker-p pos) (window-live-p w))
      (with-current-buffer (window-buffer w)
        (if (drgnx-buffers--on-control-p posn) (drgnx-buffers-close-at pos) (drgnx-buffers-open-at pos)))))
  (drgnx-buffers--release))

(defun drgnx-buffers-mouse-ignore (_event) (interactive "e") (drgnx-buffers--release))

(defvar drgnx-buffers-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map drgnx-wb-dock-map)
    (keymap-set map "<down-mouse-1>" #'drgnx-buffers-mouse-press)
    (keymap-set map "<mouse-1>" #'drgnx-buffers-mouse-click)
    (keymap-set map "<double-down-mouse-1>" #'ignore)
    (keymap-set map "<double-mouse-1>" #'drgnx-buffers-mouse-ignore)
    (keymap-set map "<drag-mouse-1>" #'drgnx-buffers-mouse-ignore)
    (keymap-set map "<mouse-2>" #'drgnx-buffers-mouse-close)
    map)
  "Keys of the Buffers panel; keyboard keys come from the key profiles.")

(define-derived-mode drgnx-buffers-mode nil "Buffers"
  "The drgnx Buffers panel (open editors)."
  (setq buffer-read-only t buffer-undo-list t truncate-lines t cursor-type nil mode-line-format nil)
  (setq-local hl-line-sticky-flag t)
  ;; A press on a partly visible row must not scroll: the row would move under the pointer.
  (setq-local scroll-margin 0 make-cursor-line-fully-visible nil)
  (hl-line-mode 1)
  (drgnx-wb-rows-setup)
  (jit-lock-register #'drgnx-buffers--fontify))

(defvar drgnx-buffers--title "Open"
  "The panel's title (window-dark.html `.sec'); Save All and Close Saved are on the island header's ⋯.")

(defun drgnx-buffers-setup ()
  "Put the Buffers panel in the dock (above the Explorer) and keep it current."
  (drgnx-wb-define-section 'buffers :slot -1 :title #'drgnx-buffers--current-title :height 0.3
                           :buffer #'drgnx-buffers--buffer)
  (drgnx-state-subscribe 'selected-changed #'drgnx-wb--selected-changed)
  (drgnx-wb-rows-follow)
  (drgnx-signal-subscribe 'buffer-set-changed #'drgnx-buffers--refresh)
  (drgnx-signal-subscribe 'modified-changed #'drgnx-buffers--refresh)
  (drgnx-signal-subscribe 'editor-changed #'drgnx-buffers--mark-active)
  (drgnx-signal-subscribe 'editor-changed #'drgnx-buffers--refresh)
  (drgnx-signal-subscribe 'frame-changed #'drgnx-buffers--refresh)           ; another window: its buffers
  (drgnx-signal-subscribe 'tabs-changed #'drgnx-buffers--refresh)
  (add-function :after after-focus-change-function #'drgnx-buffers--focus-changed '((name . drgnx-buffers)))
  (drgnx-modules-push-undo "after-focus-change-function drgnx-buffers"
                           (lambda () (remove-function after-focus-change-function 'drgnx-buffers)))
  (add-hook 'drgnx-git-changed-functions
            (lambda (_root) (when-let* ((b (get-buffer drgnx-buffers-buffer-name)))
                              (with-current-buffer b (jit-lock-refontify))))))

(provide 'drgnx-buffers)
;;; drgnx-buffers.el ends here
