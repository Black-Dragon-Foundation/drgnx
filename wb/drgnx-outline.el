;;; drgnx-outline.el --- The Outline section: the editor's definitions -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A dock section below the Explorer listing the definitions of the file in the editor (imenu),
;; nested as imenu nests them.  A click shows the definition in the editor and keeps you in the
;; Outline (browse on); RET goes there.  It follows the editor (the bus's `editor-changed' edge)
;; and, half a second after you stop typing, the file's changes.  Files without an index, remote
;; files and very large buffers get a one-line notice instead — computing an index never blocks
;; typing.  See docs/guide/workbench.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'imenu)
(require 'drgnx-wb)

(defface drgnx-outline-group '((t :inherit shadow)) "A group of definitions (imenu submenu)." :group 'drgnx)

(defcustom drgnx-outline-max-size (* 1024 1024)
  "Buffers larger than this (characters) get no outline." :type 'integer :group 'drgnx)
(defcustom drgnx-outline-delay 0.5 "Idle seconds after an edit before the Outline follows it."
  :type 'number :group 'drgnx)

(defconst drgnx-outline-buffer-name " *drgnx outline*" "Internal (a leading space): not in C-x b or ibuffer.")
(defvar drgnx-outline--rows [] "Per line: [NAME DEPTH POSITION-or-nil].")
(defvar drgnx-outline--source nil "The buffer the Outline shows.")
(defvar drgnx-outline--timer nil)

(defvar drgnx-outline-mode-map
  (let ((m (make-sparse-keymap)))
    (set-keymap-parent m drgnx-wb-dock-map)
    (define-key m [mouse-1] #'drgnx-outline-mouse-jump)
    m))

(define-derived-mode drgnx-outline-mode special-mode "Outline"
  "The editor's definitions."
  (setq-local truncate-lines t cursor-type nil mode-line-format nil)
  (hl-line-mode 1))

(defun drgnx-outline--buffer ()
  (or (get-buffer drgnx-outline-buffer-name)
      (with-current-buffer (get-buffer-create drgnx-outline-buffer-name)
        (drgnx-outline-mode)
        (current-buffer))))

(defun drgnx-outline--flatten (index depth)
  "IMENU INDEX as rows."
  (cl-loop for (name . rest) in index
           when (and (stringp name)                     ; imenu answers (nil) when it found nothing
                     (not (equal name (car imenu--rescan-item))))
           append (if (imenu--subalist-p (cons name rest))
                      (cons (vector name depth nil) (drgnx-outline--flatten rest (1+ depth)))
                    (list (vector name depth (if (overlayp rest) (overlay-start rest) rest))))))

(defun drgnx-outline--index (src)
  "SRC's rows, or a notice string."
  (with-current-buffer src
    (cond ((and buffer-file-name (file-remote-p buffer-file-name)) "Outline is off for remote files")
          ((> (buffer-size) drgnx-outline-max-size) "This file is too large for an outline")
          (t (let ((rows (while-no-input            ; a key pressed meanwhile wins: try again later
                           (ignore-errors
                             (let ((imenu-auto-rescan t) (imenu--index-alist nil) (non-essential t))
                               (drgnx-outline--flatten (imenu--make-index-alist t) 0))))))
               (cond ((eq rows t) 'interrupted)
                     (rows)
                     (t "No outline for this file")))))))

(defun drgnx-outline--watch (src)
  "Follow SRC's edits (and stop following the previous source)."
  (unless (eq src drgnx-outline--source)
    (when (buffer-live-p drgnx-outline--source)
      (with-current-buffer drgnx-outline--source (remove-hook 'after-change-functions #'drgnx-outline--changed t)))
    (setq drgnx-outline--source src)
    (when (buffer-live-p src)
      (with-current-buffer src (add-hook 'after-change-functions #'drgnx-outline--changed nil t)))))

(defun drgnx-outline--changed (&rest _)
  "An edit in the source: refresh once typing pauses."
  (unless (timerp drgnx-outline--timer)
    (setq drgnx-outline--timer (run-with-idle-timer drgnx-outline-delay nil #'drgnx-outline--idle))))

(defun drgnx-outline--idle ()
  (setq drgnx-outline--timer nil)
  (drgnx-outline-refresh))

(defun drgnx-outline-refresh (&rest _)
  "Show the definitions of the file in the editor — only while the Outline is shown (showing it
refreshes it): an index can take most of a second to build.  Hidden, it stops following edits."
  (if (get-buffer-window drgnx-outline-buffer-name t)
      (drgnx-outline--refresh-1)
    (drgnx-outline--watch nil)))

(defun drgnx-outline--refresh-1 ()
  (let* ((editor (drgnx-wb-editor-window)) (src (and editor (window-buffer editor)))
         (rows (and src (drgnx-outline--index src))))
    (drgnx-outline--watch src)
    (if (eq rows 'interrupted)
        (drgnx-outline--changed)                     ; you typed meanwhile: at the next pause
      (with-current-buffer (drgnx-outline--buffer)
        (let ((rows (or rows "")) (inhibit-read-only t) (line (line-number-at-pos)))
          (erase-buffer)
          (if (stringp rows)
              (progn (setq drgnx-outline--rows []) (insert (propertize (concat " " rows) 'face 'shadow)))
            (setq drgnx-outline--rows (vconcat rows))
            (insert (mapconcat (lambda (r)
                                 (let ((text (concat (make-string (1+ (* 2 (aref r 1))) ?\s) (drgnx-wb-display-name (aref r 0)))))
                                   (if (aref r 2) text (propertize text 'face 'drgnx-outline-group))))
                               rows "\n")))
          (goto-char (point-min))
          (forward-line (1- line)))))))

(defun drgnx-outline-jump (i &optional select)
  "Show row I's definition in the editor (SELECT: and go there)."
  (when-let* ((r (and (< -1 i (length drgnx-outline--rows)) (aref drgnx-outline--rows i)))
              (pos (aref r 2)) (editor (drgnx-wb-editor-window)) ((buffer-live-p drgnx-outline--source)))
    (unless (eq (window-buffer editor) drgnx-outline--source) (set-window-buffer editor drgnx-outline--source))
    (set-window-point editor (if (markerp pos) (marker-position pos) pos))
    (with-selected-window editor (recenter 3))
    (when select (select-window editor))))

(defun drgnx-outline-open () "Go to the definition at point." (interactive)
       (drgnx-outline-jump (1- (line-number-at-pos)) t))

(defun drgnx-outline-mouse-jump (event)
  "Show the clicked definition; stay in the Outline."
  (interactive "e")
  (when-let* ((posn (event-start event)) (pos (posn-point posn)))
    (with-selected-window (posn-window posn)
      (goto-char pos)
      (drgnx-outline-jump (1- (line-number-at-pos pos))))))

(defun drgnx-outline-focus () "Show the sidebar and focus the Outline." (interactive) (drgnx-wb-focus-section 'outline))

(defun drgnx-outline-setup ()
  "Put the Outline in the dock, below the Explorer, following the editor."
  (drgnx-wb-define-section 'outline :slot 1 :title " OUTLINE" :height 0.25 :buffer #'drgnx-outline--buffer
                           :on-show (lambda (_w) (drgnx-outline-refresh)))
  (drgnx-signal-subscribe 'editor-changed #'drgnx-outline-refresh))

(provide 'drgnx-outline)
;;; drgnx-outline.el ends here
