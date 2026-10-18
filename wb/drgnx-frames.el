;;; drgnx-frames.el --- Several windows: roles, moving editors, each window's buffers -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Every frame (OS window) is its own workbench.  The first graphical frame is the **main** one;
;; frames made later are **auxiliary**: editor-only (no sidebar until you toggle one there).
;; Commands move or open the shown file — or a whole editor group — in a new window.  Each window
;; has its own buffers: the tabs of its groups (the main window also has the open files that are a
;; tab nowhere); the Buffers panel lists the window you work in, or all of them.  drgnx never
;; positions or sizes a window: the window manager places it.  See docs/guide/workbench.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-groups)

(defun drgnx-frames--workbench-p (f)
  "F is a frame the workbench works in: live, visible, not a child frame, not the daemon's initial frame
(a client's terminal frame, or `emacs -nw''s, is one)."
  (and (frame-live-p f) (frame-visible-p f) (not (frame-parent f))
       (not (and (daemonp) (equal (terminal-name (frame-terminal f)) "initial_terminal")))))

(defun drgnx-frames--candidate-p (f)
  "F can be the main window: a workbench frame not kept for one file (an EDITOR frame, role `editor')."
  (and (drgnx-frames--workbench-p f) (not (eq (frame-parameter f 'drgnx-frame-role) 'editor))))

(defun drgnx-frames--main ()
  (seq-find (lambda (f) (and (frame-live-p f) (eq (frame-parameter f 'drgnx-frame-role) 'main))) (frame-list)))

(defun drgnx-frames-mark-main (&optional frame)
  "Make FRAME — default: the oldest workbench frame (`frame-list' is newest first; a daemon's first
client frame; never a child frame, never an EDITOR frame) — the main window unless one exists."
  (unless (drgnx-frames--main)
    (when-let* ((f (or frame (seq-find #'drgnx-frames--candidate-p (reverse (frame-list))))))
      (set-frame-parameter f 'drgnx-frame-role 'main))))

(defun drgnx-frame-role (&optional frame)
  "FRAME's role: `main' or `aux'."
  (let ((f (or frame (selected-frame))))
    (drgnx-frames-mark-main)
    (if (eq (frame-parameter f 'drgnx-frame-role) 'main) 'main 'aux)))

(defun drgnx-frames--deleted (frame)
  "The main window closes: the next workbench window (not an EDITOR frame) becomes main."
  (when (eq (frame-parameter frame 'drgnx-frame-role) 'main)
    (when-let* ((next (seq-find (lambda (f) (and (not (eq f frame)) (drgnx-frames--candidate-p f))) (reverse (frame-list)))))
      (set-frame-parameter next 'drgnx-frame-role 'main)))
  (drgnx-signal-post 'tabs-changed))

(defun drgnx-frames--made (frame)
  "`after-make-frame-functions': a new terminal frame (a client's) is the main window when none is — not a child
frame, not one on the daemon's initial terminal.  A graphical frame waits for `drgnx-first-gui-frame-hook' (it
may not be mapped yet)."
  (when (and (not (display-graphic-p frame)) (drgnx-frames--candidate-p frame))
    (drgnx-frames-mark-main frame)))

(defun drgnx-frames--first-gui ()
  "`drgnx-first-gui-frame-hook': the first graphical window is the main one — also when the daemon's first client
was a terminal, whose frame took the role (`drgnx-frames--made'); that frame is auxiliary then.  The graphical
frame need not be mapped yet: not a child frame, not an EDITOR frame is enough."
  (let ((main (drgnx-frames--main))
        (gui (seq-find (lambda (f) (and (frame-live-p f) (display-graphic-p f) (not (frame-parent f))
                                        (not (eq (frame-parameter f 'drgnx-frame-role) 'editor))))
                       (reverse (frame-list)))))
    (when (and main gui (not (display-graphic-p main)))
      (set-frame-parameter main 'drgnx-frame-role nil))
    (drgnx-frames-mark-main gui)))

(defun drgnx-frames-count ()
  "How many workbench windows are open."
  (seq-count #'drgnx-frames--workbench-p (frame-list)))

;;;; Each window's buffers

(defun drgnx-frames--tabs (frame)
  (seq-uniq (seq-mapcat #'drgnx-chrome-tabs (drgnx-groups-list frame))))

(defun drgnx-frame-buffers (&optional frame)
  "FRAME's buffers: the tabs of its groups; the main window also has the open files that are a
tab in no window."
  (let* ((f (or frame (selected-frame))) (mine (drgnx-frames--tabs f)))
    (if (not (eq (drgnx-frame-role f) 'main))
        mine
      (let ((tabbed (make-hash-table :test #'eq)))   ; a tab in any window (a set: thousands stay linear)
        (dolist (b mine) (puthash b t tabbed))
        (dolist (g (frame-list))
          (when (and (not (eq g f)) (drgnx-frames--workbench-p g))
            (dolist (b (drgnx-frames--tabs g)) (puthash b t tabbed))))
        (append mine (seq-filter (lambda (b) (and (not (gethash b tabbed)) (drgnx-signal-user-buffer-p b)))
                                 (buffer-list)))))))

;;;; C-x b: this window's buffers first

(defun drgnx-frames--order (names)
  "NAMES (buffer names) with this window's buffers first, then the rest; each part keeps its order.
Sorts, never filters: every buffer stays a candidate."
  (let ((mine (make-hash-table :test #'equal)) first rest)
    (dolist (b (drgnx-frame-buffers))
      (when (buffer-live-p b) (puthash (buffer-name b) t mine)))
    (dolist (n names) (push n (if (gethash (if (consp n) (car n) n) mine) first rest)))
    (nconc (nreverse first) (nreverse rest))))

;; The order rides on the `buffer' completion category: `read-buffer-to-switch' (C-x b) swaps in its own
;; table, but the category, and so its overrides, stay.
(defconst drgnx-frames--sort-overrides
  `((display-sort-function . ,#'drgnx-frames--order) (cycle-sort-function . ,#'drgnx-frames--order))
  "The `buffer' category's entries the mode adds to `completion-category-overrides'.")

(defun drgnx-frames--sort-overrides (on)
  "Add (ON) or take away (nil) the buffer order in `completion-category-overrides'; a user's own
`display-sort-function' for the category stays, and so do their other entries."
  (let* ((entry (assq 'buffer completion-category-overrides)) (rest (cdr entry)))
    (if on
        (unless (assq 'display-sort-function rest)
          (setq completion-category-overrides
                (cons (cons 'buffer (append drgnx-frames--sort-overrides rest))
                      (assq-delete-all 'buffer (copy-sequence completion-category-overrides)))))
      (when (eq (cdr (assq 'display-sort-function rest)) #'drgnx-frames--order)
        (let ((left (seq-remove (lambda (c) (member c drgnx-frames--sort-overrides)) rest)))
          (setq completion-category-overrides
                (if left (cons (cons 'buffer left) (assq-delete-all 'buffer (copy-sequence completion-category-overrides)))
                  (assq-delete-all 'buffer (copy-sequence completion-category-overrides)))))))))

;;;; New windows

(defun drgnx-frames--new (buffer tabs)
  "A new auxiliary window showing BUFFER with TABS; selected."
  (let ((f (make-frame '((drgnx-frame-role . aux)))))
    (let ((w (frame-first-window f)))
      (set-window-buffer w buffer)
      (set-window-prev-buffers w nil)
      (set-window-parameter w 'drgnx-tabs tabs))
    (select-frame-set-input-focus f)
    (drgnx-chrome-apply f t)
    (drgnx-signal-post 'tabs-changed)
    f))

(defun drgnx-frames-move-editor ()
  "Move the shown file to a new window (it leaves this group's tabs)."
  (interactive)
  (let* ((g (drgnx-groups--current)) (b (window-buffer g)))
    (drgnx-chrome--close g b)
    (drgnx-frames--new b (list b))))

(defun drgnx-frames-open-editor ()
  "Open the shown file in a new window too (both show it)."
  (interactive)
  (let ((b (window-buffer (drgnx-groups--current))))
    (drgnx-frames--new b (list b))))

(defun drgnx-frames-move-group ()
  "Move this editor group — its tabs and shown file — to a new window."
  (interactive)
  (let* ((g (drgnx-groups--current)) (b (window-buffer g)) (tabs (drgnx-chrome-tabs g)))
    (if (> (length (drgnx-groups-list)) 1)
        (delete-window g)
      (set-window-parameter g 'drgnx-tabs nil)
      (set-window-buffer g (get-scratch-buffer-create)))
    (drgnx-frames--new b (or tabs (list b)))))

(define-minor-mode drgnx-frames-mode
  "Several windows: the main one, auxiliary ones (editor-only), each with its buffers."
  :global t :group 'drgnx
  (if drgnx-frames-mode
      (progn (drgnx-frames--sort-overrides t)
             (add-hook 'delete-frame-functions #'drgnx-frames--deleted)
             (add-hook 'drgnx-first-gui-frame-hook #'drgnx-frames--first-gui -10)  ; before the restore
             (add-hook 'after-make-frame-functions #'drgnx-frames--made)      ; a client's terminal frame too
             (drgnx-frames-mark-main))                ; a frame that exists already (not a daemon's terminal)
    (drgnx-frames--sort-overrides nil)
    (remove-hook 'after-make-frame-functions #'drgnx-frames--made)
    (remove-hook 'delete-frame-functions #'drgnx-frames--deleted)
    (remove-hook 'drgnx-first-gui-frame-hook #'drgnx-frames--first-gui)))

(provide 'drgnx-frames)
;;; drgnx-frames.el ends here
