;;; drgnx-persist.el --- The workbench survives a restart -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The layout you leave is the layout you find: the left dock, the panel (and its tab), the right
;; dock — each with its pixel size — the editor groups with their sizes, tabs and shown files, and
;; the Explorer's folders.  Saved when Emacs exits (only from a graphical session: a batch run
;; never writes your state) to $XDG_STATE_HOME/drgnx/workbench.eld; restored at the first
;; graphical frame.  Files that no longer exist are skipped; sizes are clamped to the frame; a
;; state written by another format version is ignored.  See docs/workbench.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-groups)

(defcustom drgnx-persist-restore-on-start t
  "Restore the last workbench layout at the first graphical frame."
  :type 'boolean :group 'drgnx)

(defvar drgnx-persist-file nil "The state file; nil means $XDG_STATE_HOME/drgnx/workbench.eld.")
(defconst drgnx-persist-version 1 "Format of the state file.")
(defvar drgnx-explorer--roots)
(declare-function drgnx-explorer-set-roots "drgnx-explorer")

(defun drgnx-persist--file ()
  (or drgnx-persist-file
      (expand-file-name "drgnx/workbench.eld" (or (getenv "XDG_STATE_HOME") (expand-file-name "~/.local/state")))))

(defun drgnx-persist--area (area)
  (let ((w (drgnx-wb-area-window area)))
    (list :shown (and w t) :tab (drgnx-wb-area-tab area)
          :px (if w (if (eq area 'right) (window-pixel-width w) (window-pixel-height w))
                (frame-parameter nil (intern (format "drgnx-wb-%s-px" area)))))))

(defun drgnx-persist-state (&optional frame)
  "FRAME's workbench as a plist (see the commentary)."
  (with-selected-frame (or frame (selected-frame))
    (let ((dock (car (drgnx-wb--dock-windows))))
      (list :version drgnx-persist-version
            :left (list :shown (and dock t)
                        :px (if dock (window-pixel-width dock) (frame-parameter nil 'drgnx-wb-dock-px)))
            :panel (drgnx-persist--area 'panel)
            :right (drgnx-persist--area 'right)
            :roots (and (boundp 'drgnx-explorer--roots) drgnx-explorer--roots)
            :main (window-state-get (window-main-window) t)
            :groups (mapcar (lambda (g) (list :tabs (delq nil (mapcar #'buffer-file-name (drgnx-chrome-tabs g)))
                                              :shown (buffer-file-name (window-buffer g))))
                            (drgnx-groups-list))))))

(defun drgnx-persist-save (&optional file)
  "Write the selected frame's workbench to FILE (default: `drgnx-persist-file')."
  (interactive)
  (let ((file (or file (drgnx-persist--file))) (state (drgnx-persist-state)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (let ((print-length nil) (print-level nil)) (prin1 state (current-buffer))))
    file))

(defun drgnx-persist--read (file)
  (when (file-readable-p file)
    (ignore-errors (with-temp-buffer (insert-file-contents file) (read (current-buffer))))))

(defun drgnx-persist--clamp (px limit) (and (integerp px) (max 1 (min px (floor limit)))))

(defun drgnx-persist--files (files) (delq nil (mapcar (lambda (f) (and f (file-exists-p f) (find-file-noselect f))) files)))

(defun drgnx-persist-restore (&optional file)
  "Bring back the workbench saved in FILE; non-nil if a state was restored."
  (interactive)
  (let* ((file (or file (drgnx-persist--file))) (state (drgnx-persist--read file)))
    (cond
     ((null state) nil)
     ((not (eql (plist-get state :version) drgnx-persist-version))
      (message "drgnx: %s has format %S, not %d; not restored" file (plist-get state :version) drgnx-persist-version)
      nil)
     (t
      (drgnx-wb-area-hide 'panel)
      (drgnx-wb-area-hide 'right)
      (drgnx-wb-hide-sidebar)
      (when-let* ((roots (seq-filter #'file-directory-p (plist-get state :roots))) ((fboundp 'drgnx-explorer-set-roots)))
        (drgnx-explorer-set-roots roots))
      ;; Editor groups: their tree and sizes, then each one's tabs and shown file.
      (let ((groups (plist-get state :groups)))
        (when-let* ((main (plist-get state :main))) (ignore-errors (window-state-put main (window-main-window) 'safe)))
        (while (< (length (drgnx-groups-list)) (length groups))      ; the tree did not fit: side by side
          (split-window (car (last (drgnx-groups-list))) nil 'right))
        (cl-loop for g in (drgnx-groups-list) for spec in groups
                 do (let ((tabs (drgnx-persist--files (plist-get spec :tabs)))
                          (shown (car (drgnx-persist--files (list (plist-get spec :shown))))))
                      (set-window-parameter g 'drgnx-tabs tabs)
                      (set-window-parameter g 'drgnx-closed nil)
                      (set-window-buffer g (or shown (car tabs) (window-buffer g)))
                      (set-window-prev-buffers g nil))))
      ;; Docks and panel: sizes first (clamped), then shown as they were.
      (let ((left (plist-get state :left)) (panel (plist-get state :panel)) (right (plist-get state :right)))
        (set-frame-parameter nil 'drgnx-wb-dock-px (drgnx-persist--clamp (plist-get left :px) (* 0.5 (frame-pixel-width))))
        (set-frame-parameter nil 'drgnx-wb-panel-px (drgnx-persist--clamp (plist-get panel :px) (* 0.7 (frame-pixel-height))))
        (set-frame-parameter nil 'drgnx-wb-right-px (drgnx-persist--clamp (plist-get right :px) (* 0.5 (frame-pixel-width))))
        (when (plist-get left :shown) (drgnx-wb-show-sidebar))
        (when (plist-get panel :shown) (drgnx-wb-area-show 'panel (plist-get panel :tab)))
        (when (plist-get right :shown) (drgnx-wb-area-show 'right (plist-get right :tab))))
      (drgnx-chrome-apply)
      t))))

(defun drgnx-persist--on-exit ()
  "Save from a graphical session only (a batch run must never write the user's state)."
  (when (seq-some #'display-graphic-p (frame-list))
    (ignore-errors (drgnx-persist-save))))

(defun drgnx-persist--on-start ()
  (when drgnx-persist-restore-on-start (ignore-errors (drgnx-persist-restore))))

(define-minor-mode drgnx-persist-mode
  "Save the workbench when Emacs exits; restore it at the first graphical frame."
  :global t :group 'drgnx
  (if drgnx-persist-mode
      (progn (add-hook 'kill-emacs-hook #'drgnx-persist--on-exit)
             (add-hook 'drgnx-first-gui-frame-hook #'drgnx-persist--on-start))
    (remove-hook 'kill-emacs-hook #'drgnx-persist--on-exit)
    (remove-hook 'drgnx-first-gui-frame-hook #'drgnx-persist--on-start)))

(provide 'drgnx-persist)
;;; drgnx-persist.el ends here
