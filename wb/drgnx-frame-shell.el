;;; drgnx-frame-shell.el --- Each window's own shell: its title bar, rail and right side -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Every workbench frame has a shell of its own, the frame parameter `drgnx-shell': the plist
;;   (:title BOOL :rail BOOL :right BOOL :place PLACE)
;; :title is whether the title bar shows, :rail whether the rail does (written to the kit's `drgnx-rail' frame
;; parameter: `hidden' when off), :right whether the right dock's tile shows, :place the place the frame shows.  A
;; frame gets its defaults the first time it is asked (`drgnx-shell-defaults'): a frame whose tiles are only Work and
;; its Detail, or only one conversation, starts with no rail.  The toggles act on the selected frame only.
;; (Not core/drgnx-shell.el, the rc line of the user's shell.)  See docs/develop/core.md, "Each window's shell".

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-grid-tree)

(declare-function drgnx-grid-tree "drgnx-grid" (&optional frame))
(declare-function drgnx-grid-dock "drgnx-grid" (dock &optional frame))
(declare-function drgnx-grid-toggle-dock "drgnx-grid" (dock))
(declare-function drgnx-grid--named-buffer "drgnx-grid" (name))

(defvar drgnx-shell-focus-modes '(drgnx-work-map-mode)
  "Major modes of an editor that, with only its Detail beside it, makes a frame focused (no rail at first): Work.")

(defconst drgnx-shell-keys '(:title :rail :right :place) "The keys of a frame's shell.")

(defun drgnx-shell--leaf-kinds (leaf)
  "The pane kinds LEAF (a tool tile) holds, instances as their kind."
  (mapcar (lambda (e) (if (consp e) (car e) e)) (plist-get (cdr leaf) :kinds)))

(defun drgnx-shell--focus-editor-p (leaf)
  "Non-nil when LEAF is an editor showing a buffer in one of `drgnx-shell-focus-modes'."
  (and (eq (car leaf) 'editor)
       (when-let* ((b (drgnx-grid--named-buffer (plist-get (cdr leaf) :shown))))
         (memq (buffer-local-value 'major-mode b) drgnx-shell-focus-modes))))

(defun drgnx-shell-focused-p (tree)
  "Non-nil when TREE's tiles are only Work (an editor in `drgnx-shell-focus-modes') and its Detail, or only one
conversation (one tile of the agent panel)."
  (let ((leaves (drgnx-grid-tree-leaves tree)))
    (or (and (seq-some #'drgnx-shell--focus-editor-p leaves)
             (seq-every-p (lambda (l) (or (drgnx-shell--focus-editor-p l)
                                          (and (eq (car l) 'tile) (equal (drgnx-shell--leaf-kinds l) '(work-detail)))))
                          leaves))
        (and (= (length leaves) 1) (eq (car (car leaves)) 'tile)
             (equal (drgnx-shell--leaf-kinds (car leaves)) '(agent-panel))))))

(defun drgnx-shell-defaults (tree)
  "The shell a frame whose grid is TREE starts with: everything shown, but no rail when it is focused
\(`drgnx-shell-focused-p')."
  (list :title t :rail (not (drgnx-shell-focused-p tree)) :right t :place nil))

(defun drgnx-shell--of (frame)
  "FRAME's shell, given its defaults the first time."
  (or (frame-parameter frame 'drgnx-shell)
      (let ((shell (drgnx-shell-defaults (drgnx-grid-tree frame))))
        (set-frame-parameter frame 'drgnx-shell shell)
        (drgnx-shell--write-rail frame (plist-get shell :rail))
        shell)))

(defun drgnx-shell-get (frame key)
  "KEY (one of `drgnx-shell-keys') of FRAME's (default the selected frame's) shell."
  (plist-get (drgnx-shell--of (or frame (selected-frame))) key))

(defun drgnx-shell--write-rail (frame on)
  "The kit's `drgnx-rail' frame parameter for ON: nil shown, `hidden' not."
  (unless (eq (frame-parameter frame 'drgnx-rail) (if on nil 'hidden))
    (set-frame-parameter frame 'drgnx-rail (if on nil 'hidden))))

(defun drgnx-shell-set (frame key value)
  "Set KEY of FRAME's (default the selected frame's) shell to VALUE, on that frame only: :rail writes the kit's
`drgnx-rail' frame parameter, :right shows or hides the right dock's tile.  VALUE."
  (unless (memq key drgnx-shell-keys) (error "drgnx-shell: no key %S" key))
  (let* ((frame (or frame (selected-frame))) (shell (copy-sequence (drgnx-shell--of frame))))
    (set-frame-parameter frame 'drgnx-shell (plist-put shell key value))
    (pcase key
      (:rail (drgnx-shell--write-rail frame value))
      (:right (with-selected-frame frame
                (unless (eq (and (drgnx-grid-dock 'right frame) t) (and value t))
                  (drgnx-grid-toggle-dock 'right)))))
    value))

(defun drgnx-shell--toggle (key)
  (drgnx-shell-set nil key (not (drgnx-shell-get nil key))))

(defun drgnx-shell-toggle-rail ()
  "Show or hide this window's rail (only this window's)."
  (interactive)
  (drgnx-shell--toggle :rail))

(defun drgnx-shell-toggle-title ()
  "Show or hide this window's title bar (only this window's)."
  (interactive)
  (drgnx-shell--toggle :title))

(defun drgnx-shell-toggle-right ()
  "Show or hide this window's right side (only this window's)."
  (interactive)
  (drgnx-shell--toggle :right))

(defun drgnx-shell-right-for (place)
  "The kind the right side shows for PLACE: Work's Detail for `work', the agents' side for every other place."
  (if (eq place 'work) 'work-detail 'agents-side))

(provide 'drgnx-frame-shell)
;;; drgnx-frame-shell.el ends here
