;;; drgnx-buffers.el --- The Buffers panel: open editors in the left dock -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The files you have open, in the order you opened them — switching never re-sorts, so a row
;; never moves under the pointer.  Each row: × (close), ● when modified, the name and its folder.
;; The panel listens to the change bus and re-renders only when its signature (the rows and
;; their modified flags) changed; the view and the selection are restored by buffer identity,
;; and the title lives in the window, where no mode can erase it.  The active editor's row is
;; marked with an overlay, without re-rendering.  See docs/workbench.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'text-property-search)
(require 'hl-line)
(require 'drgnx-wb)

(defface drgnx-buffers-close '((t :inherit shadow)) "The × of each row.")
(defface drgnx-buffers-modified '((t :inherit warning)) "The ● of a modified buffer.")
(defface drgnx-buffers-dir '((t :inherit shadow)) "The folder after each name.")
(defface drgnx-buffers-active '((t :inherit bold)) "The row of the buffer shown in the active editor.")

(defconst drgnx-buffers-buffer-name "*drgnx buffers*")

(defvar drgnx-buffers--order nil "User buffers in the order they were first seen.")
(defvar drgnx-buffers--signature nil "What the panel shows now; a refresh with the same one does nothing.")
(defvar drgnx-buffers--renders 0 "How many times the panel was rendered (tests read it).")
(defvar drgnx-buffers--active nil "Overlay on the active editor's row.")

(defun drgnx-buffers--update-order ()
  (let* ((live (seq-filter (lambda (b) (and (buffer-live-p b) (drgnx-signal-user-buffer-p b))) drgnx-buffers--order))
         (new (seq-remove (lambda (b) (memq b live)) (seq-filter #'drgnx-signal-user-buffer-p (buffer-list)))))
    (setq drgnx-buffers--order (append live new))))

(defun drgnx-buffers--row (b)
  (let* ((file (buffer-file-name b))
         (dir (abbreviate-file-name (directory-file-name (file-name-directory (or file (buffer-local-value 'default-directory b)))))))
    (propertize
     (concat (propertize "×" 'drgnx-close t 'face 'drgnx-buffers-close 'mouse-face 'highlight 'help-echo "Close")
             " " (if (buffer-modified-p b) (propertize "●" 'face 'drgnx-buffers-modified) " ") " "
             (propertize (buffer-name b) 'mouse-face 'highlight)
             "  " (propertize dir 'face 'drgnx-buffers-dir) "\n")
     'drgnx-buffer b)))

(defun drgnx-buffers--row-pos (b)
  "Start of buffer B's row, or nil."
  (save-excursion
    (goto-char (point-min))
    (when-let* ((m (text-property-search-forward 'drgnx-buffer b #'eq))) (prop-match-beginning m))))

(defun drgnx-buffers--buffer ()
  (or (get-buffer drgnx-buffers-buffer-name)
      (with-current-buffer (get-buffer-create drgnx-buffers-buffer-name)
        (drgnx-buffers-mode)
        (drgnx-buffers--refresh)
        (current-buffer))))

(defun drgnx-buffers--refresh (&rest _)
  "Re-render if the rows changed; keep every window's view and selection on the same buffers."
  (drgnx-buffers--update-order)
  (let ((sig (mapcar (lambda (b) (list b (buffer-name b) (buffer-modified-p b))) drgnx-buffers--order)))
    (unless (equal sig drgnx-buffers--signature)
      (setq drgnx-buffers--signature sig)
      (cl-incf drgnx-buffers--renders)
      (with-current-buffer (get-buffer-create drgnx-buffers-buffer-name)
        (unless (derived-mode-p 'drgnx-buffers-mode) (drgnx-buffers-mode))
        (let* ((windows (get-buffer-window-list (current-buffer) nil t))
               (kept (mapcar (lambda (w) (list w (get-text-property (window-start w) 'drgnx-buffer)
                                              (get-text-property (window-point w) 'drgnx-buffer)))
                             windows))
               (at (get-text-property (point) 'drgnx-buffer))
               (inhibit-read-only t))
          (erase-buffer)
          (insert (mapconcat #'drgnx-buffers--row drgnx-buffers--order ""))
          (goto-char (or (and at (drgnx-buffers--row-pos at)) (point-min)))
          (pcase-dolist (`(,w ,top ,pt) kept)
            (when-let* ((p (and top (drgnx-buffers--row-pos top)))) (set-window-start w p t))
            (when-let* ((p (and pt (drgnx-buffers--row-pos pt)))) (set-window-point w p)))
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
  (when-let* ((b (get-text-property pos 'drgnx-buffer)))
    (when (buffer-live-p b) (kill-buffer b))
    (drgnx-buffers--refresh)))

(defun drgnx-buffers-open-at (pos)
  "Show the buffer of the row at POS in the editor and focus it."
  (when-let* ((b (get-text-property pos 'drgnx-buffer)))
    (when (buffer-live-p b) (drgnx-wb-show-in-editor b t))))

(defun drgnx-buffers-next () "Next row." (interactive) (forward-line 1) (when (eobp) (forward-line -1)))
(defun drgnx-buffers-previous () "Previous row." (interactive) (forward-line -1))
(defun drgnx-buffers-open () "Open the row's buffer in the editor." (interactive) (drgnx-buffers-open-at (point)))
(defun drgnx-buffers-close () "Close the row's buffer." (interactive) (drgnx-buffers-close-at (pos-bol)))
(defun drgnx-buffers-focus () "Show the sidebar and focus the Buffers panel."
  (interactive) (drgnx-wb-focus-section 'buffers))

(defvar drgnx-buffers--pressed nil)

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
  (setq drgnx-buffers--pressed nil)
  (let ((pos (posn-point (event-end event))))
    (when (integer-or-marker-p pos)
      (if (get-text-property pos 'drgnx-close) (drgnx-buffers-close-at pos) (drgnx-buffers-open-at pos)))))

(defun drgnx-buffers-mouse-ignore (_event) (interactive "e") (setq drgnx-buffers--pressed nil))

(defvar drgnx-buffers-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map drgnx-wb-dock-map)
    (keymap-set map "<down-mouse-1>" #'drgnx-buffers-mouse-press)
    (keymap-set map "<mouse-1>" #'drgnx-buffers-mouse-click)
    (keymap-set map "<double-down-mouse-1>" #'ignore)
    (keymap-set map "<double-mouse-1>" #'drgnx-buffers-mouse-ignore)
    (keymap-set map "<drag-mouse-1>" #'drgnx-buffers-mouse-ignore)
    map)
  "Keys of the Buffers panel; keyboard keys come from the key profiles.")

(define-derived-mode drgnx-buffers-mode nil "Buffers"
  "The drgnx Buffers panel (open editors)."
  (setq buffer-read-only t buffer-undo-list t truncate-lines t cursor-type nil mode-line-format nil)
  (setq-local hl-line-sticky-flag t)
  (hl-line-mode 1))

(defun drgnx-buffers-setup ()
  "Put the Buffers panel in the dock (above the Explorer) and keep it current."
  (drgnx-wb-define-section 'buffers :slot -1 :title " BUFFERS" :height 0.3 :buffer #'drgnx-buffers--buffer)
  (drgnx-signal-subscribe 'buffer-set-changed #'drgnx-buffers--refresh)
  (drgnx-signal-subscribe 'modified-changed #'drgnx-buffers--refresh)
  (drgnx-signal-subscribe 'editor-changed #'drgnx-buffers--mark-active))

(provide 'drgnx-buffers)
;;; drgnx-buffers.el ends here
