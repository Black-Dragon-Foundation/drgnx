;;; drgnx-buffers.el --- The Buffers panel: open editors in the left dock -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The files you have open, in the order you opened them — switching never re-sorts, so a row
;; never moves under the pointer.  Each row: × (close), ● when modified, the name and its folder.
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
(require 'drgnx-git)

(defface drgnx-buffers-close '((t :inherit shadow)) "The × of each row." :group 'drgnx)
(defface drgnx-buffers-modified '((t :inherit warning)) "The ● of a modified buffer." :group 'drgnx)
(defface drgnx-buffers-dir '((t :inherit shadow)) "The folder after each name." :group 'drgnx)
(defface drgnx-buffers-active '((t :inherit bold)) "The row of the buffer shown in the active editor." :group 'drgnx)

(defconst drgnx-buffers-buffer-name " *drgnx buffers*" "Internal (a leading space): not in C-x b or ibuffer.")

(defvar drgnx-buffers--order nil "User buffers in the order they were first seen.")
(defvar drgnx-buffers--signature nil "What the panel shows now; a refresh with the same one does nothing.")
(defvar drgnx-buffers--renders 0 "How many times the panel was rendered (tests read it).")
(defvar drgnx-buffers--active nil "Overlay on the active editor's row.")
(defvar drgnx-buffers--filter nil "Show only buffers whose names contain this text (any case), or nil.")
(defvar drgnx-buffers--title)          ; defined below, with its buttons

(defvar drgnx-buffers-all-windows nil
  "With several windows open: nil lists the buffers of the window you work in, t all of them.")
(declare-function drgnx-frame-buffers "drgnx-frames")
(declare-function drgnx-frames-count "drgnx-frames")

(defun drgnx-buffers--in-window ()
  "The buffers in open order: all, or with several windows those of the selected one."
  (if (and (not drgnx-buffers-all-windows) (fboundp 'drgnx-frame-buffers) (> (drgnx-frames-count) 1))
      (let ((mine (drgnx-frame-buffers))) (seq-filter (lambda (b) (memq b mine)) drgnx-buffers--order))
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
         (new (seq-remove (lambda (b) (memq b live)) (seq-filter #'drgnx-signal-user-buffer-p (buffer-list)))))
    (setq drgnx-buffers--order (append live new))))

(defvar-local drgnx-buffers--rows []
  "The buffer of each line, in order (a virtual list: the panel holds plain text).")

(defvar drgnx-buffers--dirs nil
  "During a render: folder → its abbreviated text (computed once per folder).")

(defun drgnx-buffers--dir (b)
  (let ((dir (file-name-directory (or (buffer-file-name b) (buffer-local-value 'default-directory b)))))
    (or (and drgnx-buffers--dirs (gethash dir drgnx-buffers--dirs))
        (let ((text (abbreviate-file-name (directory-file-name dir))))
          (when drgnx-buffers--dirs (puthash dir text drgnx-buffers--dirs))
          text))))

(defun drgnx-buffers--row (b)
  "Buffer B's row as plain text: × ● name  folder (faces come from jit-lock, for visible rows)."
  (concat "× " (if (buffer-modified-p b) "●" " ") " " (drgnx-wb-display-name (buffer-name b)) "  "
          (drgnx-wb-display-name (drgnx-buffers--dir b)) "\n"))

(defun drgnx-buffers--index (pos) (1- (line-number-at-pos pos t)))

(defun drgnx-buffers-buffer-at (pos)
  "The buffer of the row at POS, or nil."
  (when pos
    (let ((i (drgnx-buffers--index pos)))
      (and (< -1 i (length drgnx-buffers--rows)) (aref drgnx-buffers--rows i)))))

(defun drgnx-buffers--close-p (pos)
  "Non-nil if POS is on a row's × (its first character)."
  (and (drgnx-buffers-buffer-at pos) (save-excursion (goto-char pos) (bolp))))

(defun drgnx-buffers--row-pos (b)
  "Start of buffer B's row, or nil."
  (when-let* ((i (seq-position drgnx-buffers--rows b #'eq)))
    (save-excursion (goto-char (point-min)) (forward-line i) (point))))

(defun drgnx-buffers--fontify (beg end)
  "Paint the rows between BEG and END (jit-lock): ×, ●, the name's hover highlight, the folder, the
git status (the name's colour and its letter at the right edge)."
  (save-excursion
    (goto-char beg)
    (forward-line 0)
    (let ((inhibit-read-only t) (end (save-excursion (goto-char end) (pos-eol))))
      (remove-overlays (point) end 'drgnx-git t)
      (with-silent-modifications
        (while (< (point) end)
          (let* ((bol (point)) (eol (pos-eol))
                 (name-end (or (save-excursion (goto-char (+ bol 4)) (search-forward "  " eol t)) eol)))
            (when (< (+ bol 4) eol)
              (add-text-properties bol (1+ bol) '(face drgnx-buffers-close mouse-face highlight help-echo "Close"))
              (put-text-property (+ bol 2) (+ bol 3) 'face 'drgnx-buffers-modified)
              (put-text-property (+ bol 4) (- name-end 2) 'mouse-face 'highlight)
              (put-text-property (- name-end 2) eol 'face 'drgnx-buffers-dir)
              (when-let* ((b (drgnx-buffers-buffer-at bol)) (file (buffer-file-name b))
                          (status (drgnx-git-status file)) (letter (car (drgnx-git-look status))))
                ;; The letter right after the name: the folder hint after it is cut at the panel's edge.
                (let ((face (cadr (drgnx-git-look status))) (o (make-overlay (- name-end 2) (- name-end 2))))
                  (add-face-text-property (+ bol 4) (- name-end 2) face)
                  (overlay-put o 'drgnx-git t)
                  (overlay-put o 'after-string (concat " " (propertize letter 'face face)))))))
          (forward-line 1)))))
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
  (let ((sig (cons drgnx-buffers--filter
                   (mapcar (lambda (b) (list b (buffer-name b) (buffer-modified-p b))) (drgnx-buffers--shown)))))
    (unless (equal sig drgnx-buffers--signature)
      (setq drgnx-buffers--signature sig)
      (cl-incf drgnx-buffers--renders)
      (with-current-buffer (get-buffer-create drgnx-buffers-buffer-name)
        (unless (derived-mode-p 'drgnx-buffers-mode) (drgnx-buffers-mode))
        (let* ((windows (get-buffer-window-list (current-buffer) nil t))
               (kept (mapcar (lambda (w) (list w (drgnx-buffers-buffer-at (window-start w))
                                               (drgnx-buffers-buffer-at (window-point w))))
                             windows))
               (at (drgnx-buffers-buffer-at (point)))
               (inhibit-read-only t))
          (erase-buffer)
          (let ((drgnx-buffers--dirs (make-hash-table :test #'equal)))
            ;; One insertion of plain text (faces: jit-lock, for the visible rows only).
            (insert (mapconcat #'drgnx-buffers--row (drgnx-buffers--shown) "")))
          (setq drgnx-buffers--rows (vconcat (drgnx-buffers--shown)))
          (goto-char (or (and at (drgnx-buffers--row-pos at)) (point-min)))
          (pcase-dolist (`(,w ,top ,pt) kept)
            (drgnx-wb-with-owned-windows (list w)           ; the panel's own windows
              (when-let* ((p (and top (drgnx-buffers--row-pos top)))) (set-window-start w p t))
              (when-let* ((p (and pt (drgnx-buffers--row-pos pt)))) (set-window-point w p))))
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
(defun drgnx-buffers--user-buffers () (seq-filter #'buffer-live-p drgnx-buffers--order))

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
    (set-window-parameter w 'header-line-format (drgnx-buffers--current-title))))

(defun drgnx-buffers--current-title ()
  "The panel's title: the filter while one is on, else the title with its buttons."
  (if drgnx-buffers--filter (format " BUFFERS — %s" drgnx-buffers--filter) drgnx-buffers--title))

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
  "Release: × closes that row's buffer; elsewhere on the row, show it in the editor."
  (interactive "e")
  (let ((pos (posn-point (event-end event))))
    ;; Act on the rows the user saw, then run a refresh that waited for the release.
    (when (integer-or-marker-p pos)
      (if (drgnx-buffers--close-p pos) (drgnx-buffers-close-at pos) (drgnx-buffers-open-at pos))))
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
  (jit-lock-register #'drgnx-buffers--fontify))

(defun drgnx-buffers--button (label command)
  "LABEL as a header-line button running COMMAND."
  (let ((map (make-sparse-keymap)))
    (keymap-set map "<header-line> <mouse-1>" (lambda (_e) (interactive "e") (call-interactively command)))
    (propertize label 'mouse-face 'highlight 'help-echo (documentation command) 'local-map map)))

(defvar drgnx-buffers--title
  (concat " BUFFERS   " (drgnx-buffers--button "save all" #'drgnx-buffers-save-all)
          " · " (drgnx-buffers--button "close saved" #'drgnx-buffers-close-saved))
  "The panel's title, with buttons.")

(defun drgnx-buffers-setup ()
  "Put the Buffers panel in the dock (above the Explorer) and keep it current."
  (drgnx-wb-define-section 'buffers :slot -1 :title #'drgnx-buffers--current-title :height 0.3
                           :buffer #'drgnx-buffers--buffer)
  (drgnx-signal-subscribe 'buffer-set-changed #'drgnx-buffers--refresh)
  (drgnx-signal-subscribe 'modified-changed #'drgnx-buffers--refresh)
  (drgnx-signal-subscribe 'editor-changed #'drgnx-buffers--mark-active)
  (drgnx-signal-subscribe 'editor-changed #'drgnx-buffers--refresh)
  (drgnx-signal-subscribe 'frame-changed #'drgnx-buffers--refresh)           ; another window: its buffers
  (drgnx-signal-subscribe 'tabs-changed #'drgnx-buffers--refresh)
  (add-function :after after-focus-change-function #'drgnx-buffers--focus-changed '((name . drgnx-buffers)))
  (add-hook 'drgnx-git-changed-functions
            (lambda (_root) (when-let* ((b (get-buffer drgnx-buffers-buffer-name)))
                              (with-current-buffer b (jit-lock-refontify))))))

(provide 'drgnx-buffers)
;;; drgnx-buffers.el ends here
