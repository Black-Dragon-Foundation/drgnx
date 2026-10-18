;;; drgnx-close.el --- Esc and q close help panes, popups and side panes -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Part of module ui/face.  Every help pane, popup and side pane has a ✕ in its header (wb/drgnx-area.el,
;; wb/drgnx-popup.el, wb/drgnx-wb.el) and closes with Esc or q.  The two keys are bound by the key profiles in
;; `drgnx-close-mode-map', which is on only while the selected window is a lane or an area (the panel, the right
;; dock) and its buffer is not one you type into (`drgnx-close-input-modes': a shell, eshell, a terminal): so the
;; minibuffer, the editors and a terminal tab keep their Esc and q.  `drgnx-close--here' is recomputed when the
;; selection or a window's buffer changes, never while typing.  The left dock's sections are not in it: Esc there
;; already goes back to the editor (Back to the Editor, invariant I1), and hiding the sidebar is its ✕ or Close Pane
;; from the palette.  In a writable buffer the keys do what they do without this map
;; (q types q, Esc leaves Vim's insert state).  See docs/guide/workbench.md.

;;; Code:
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-modal)
(require 'drgnx-chrome)
(require 'drgnx-popup)

(defcustom drgnx-close-input-modes '(comint-mode eshell-mode term-mode vterm-mode eat-mode)
  "Modes (and the modes derived from them) whose buffers you type into: Esc and q are theirs, never close the pane."
  :type '(repeat symbol) :group 'drgnx-face)

(defvar drgnx-close-input-functions '(drgnx-close--driving-p)
  "Functions called with a buffer (until one returns non-nil): non-nil means its keys go elsewhere, so Esc and q are
not Close Pane there.  A mode that takes the keyboard for itself adds its predicate.")

(defvar drgnx-close-mode-map (make-sparse-keymap)
  "Esc and q (the key profiles bind them to Close Pane), active while `drgnx-close--here'.")

(defvar drgnx-close--here nil
  "Non-nil while the selected window is a lane or an area showing a buffer you do not type into.")

(defvar drgnx-close--emulation (list (cons 'drgnx-close--here drgnx-close-mode-map))
  "The `emulation-mode-map-alists' entry: the map is on only where `drgnx-close--here' is.")

(defun drgnx-close--driving-p (buffer)
  "Non-nil when BUFFER is a live page being driven (`drgnx-live-driving-mode': keys go to the page)."
  (and (boundp 'drgnx-live-driving-mode) (buffer-local-value 'drgnx-live-driving-mode buffer)))

(defun drgnx-close--input-buffer-p (buffer)
  "Non-nil when BUFFER is one you type into: a mode of `drgnx-close-input-modes', or `drgnx-close-input-functions' says so."
  (or (apply #'provided-mode-derived-p (buffer-local-value 'major-mode buffer) drgnx-close-input-modes)
      (run-hook-with-args-until-success 'drgnx-close-input-functions buffer)))

(defun drgnx-close--update (&rest _)
  "Recompute `drgnx-close--here' for the selected window (on `window-selection-change-functions' and
`window-buffer-change-functions'; reads two window parameters and a mode)."
  (let ((w (selected-window)))
    (setq drgnx-close--here
          (and (memq (drgnx-chrome--role w) '(lane area))
               (buffer-local-value 'buffer-read-only (window-buffer w))
               (not (drgnx-close--input-buffer-p (window-buffer w)))
               t))))

(defun drgnx-close--underneath ()
  "Run what the key just typed runs without Close Pane's map.  Esc with nothing of its own stays what it is
elsewhere, the Meta prefix: an ESC goes back to the reader.  Anything else unbound dings."
  (let ((cmd (let ((drgnx-close--here nil)) (key-binding (vector last-command-event) t))))
    (cond ((commandp cmd) (setq this-command cmd) (call-interactively cmd))
          ((eq last-command-event 'escape) (push (cons 'no-record ?\e) unread-command-events))
          (t (ding)))))

(defun drgnx-close-pane ()
  "Close the pane you are in: end a popup, hide the panel or the right dock, hide the sidebar; focus goes to the
editor.  Typed as Esc or q in a buffer you can edit, it is the key's own command instead (q types a q); so is Esc in
the modal engine's visual state (it leaves the selection)."
  (interactive)
  (if (and (memq last-command-event '(escape ?q))
           (or (not buffer-read-only) (drgnx-close--input-buffer-p (current-buffer))
               (and (eq last-command-event 'escape) (eq drgnx-modal-state 'visual))))
      (drgnx-close--underneath)
    (let ((w (selected-window)))
      (pcase (drgnx-chrome--role w)
        ('lane (drgnx-wb-focus-editor) (drgnx-popup--end w))
        ('area (drgnx-wb-area-hide (window-parameter w 'drgnx-role)))
        ('dock (drgnx-wb-hide-sidebar))
        (_ (user-error "No pane to close here"))))))

(define-minor-mode drgnx-close-mode
  "Esc and q close help panes, popups and side panes (the keys come from the key profiles)."
  :global t :group 'drgnx-face
  (if drgnx-close-mode
      (progn
        (add-to-list 'emulation-mode-map-alists 'drgnx-close--emulation)
        ;; in front of the modal engine's maps (evil's normal state takes Esc and q), after quick help's
        (add-to-list 'drgnx-modal-front-alists 'drgnx-close--emulation t)
        (drgnx-modal-order-alists)
        (add-hook 'window-selection-change-functions #'drgnx-close--update)
        (add-hook 'window-buffer-change-functions #'drgnx-close--update)
        (drgnx-close--update))
    (setq drgnx-modal-front-alists (delq 'drgnx-close--emulation drgnx-modal-front-alists)
          emulation-mode-map-alists (delq 'drgnx-close--emulation emulation-mode-map-alists))
    (remove-hook 'window-selection-change-functions #'drgnx-close--update)
    (remove-hook 'window-buffer-change-functions #'drgnx-close--update)
    (setq drgnx-close--here nil)))

;; `define-minor-mode' registered `drgnx-close-mode-map' for every buffer while the mode is on; the map is meant to be
;; on only where `drgnx-close--here' is (the emulation entry above).
(setq minor-mode-map-alist (assq-delete-all 'drgnx-close-mode minor-mode-map-alist))

(defun drgnx-close-setup ()
  "Define Close Pane and turn the mode on (ui/face's setup)."
  (drgnx-command-define 'close-pane :category "View" :title "Close Pane" :command #'drgnx-close-pane
                        :map 'drgnx-close-mode-map
                        :doc "Close the help pane, popup or side pane you are in (Esc or q there; the ✕ in its header does the same)")
  (drgnx-close-mode 1))

(provide 'drgnx-close)
;;; drgnx-close.el ends here
