;;; drgnx-groups.el --- Editor groups -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; An editor group is an editor window with its own tabs (drgnx-chrome).  Groups are made only by
;; commands — Split Editor Right / Down, Focus Group N one past the last, Move Editor to Next
;; Group — never by Emacs on its own (drgnx-rules).  Groups are numbered in visual order, left to
;; right and top to bottom.  The `other-group' place shows a buffer next to the one you work in
;; (diffs, logs).  See docs/workbench.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-chrome)

(defun drgnx-groups-list (&optional frame)
  "FRAME's editor groups in visual order."
  (seq-filter #'drgnx-signal-editor-window-p
              (window-list frame 'nomini (frame-first-window frame))))

(defun drgnx-groups--current ()
  "The group you are in, else the one used last."
  (if (drgnx-signal-editor-window-p (selected-window)) (selected-window) (drgnx-wb-editor-window)))

(defun drgnx-groups--split (side)
  (let* ((g (drgnx-groups--current)) (b (window-buffer g))
         (new (split-window g nil side)))
    (set-window-parameter new 'drgnx-tabs nil)
    (set-window-parameter new 'drgnx-closed nil)
    (set-window-buffer new b)
    (select-window new)
    (drgnx-chrome-apply)
    new))

(defun drgnx-groups-split-right () "Split the editor: a new group to the right, same file." (interactive) (drgnx-groups--split 'right))
(defun drgnx-groups-split-down () "Split the editor: a new group below, same file." (interactive) (drgnx-groups--split 'below))

(defun drgnx-groups-close ()
  "Close this editor group (its files stay open); the last group stays."
  (interactive)
  (let ((g (drgnx-groups--current)))
    (when (<= (length (drgnx-groups-list)) 1) (user-error "The last editor group stays"))
    (delete-window g)
    (select-window (drgnx-wb-editor-window))))

(defun drgnx-groups-focus (n)
  "Focus group N (1-based); one past the last makes a new group to the right."
  (let ((groups (drgnx-groups-list)))
    (cond ((<= n (length groups)) (select-window (nth (1- n) groups)))
          ((= n (1+ (length groups))) (select-window (car (last groups))) (drgnx-groups-split-right))
          (t (user-error "There are %d editor groups" (length groups))))))

(defun drgnx-groups-focus-1 () "Focus the first editor group." (interactive) (drgnx-groups-focus 1))
(defun drgnx-groups-focus-2 () "Focus the second editor group (made if there is one group)." (interactive) (drgnx-groups-focus 2))
(defun drgnx-groups-focus-3 () "Focus the third editor group (made if there are two)." (interactive) (drgnx-groups-focus 3))

(defun drgnx-groups-move-to-next ()
  "Move the shown file to the next group (made to the right if there is none)."
  (interactive)
  (let* ((g (drgnx-groups--current)) (b (window-buffer g)) (groups (drgnx-groups-list))
         (next (cadr (memq g groups))))
    (unless next
      (setq next (split-window g nil 'right))
      (set-window-parameter next 'drgnx-tabs nil)
      (set-window-parameter next 'drgnx-closed nil))
    (drgnx-chrome--close g b)
    (set-window-buffer next b)
    (select-window next)
    (drgnx-chrome-apply)))

(defun drgnx-groups--other-group (buffer alist _props)
  "The `other-group' place: the group used last other than the one you are in, else that one."
  (let* ((here (drgnx-groups--current))
         (other (or (let ((mru (get-mru-window nil nil t)))
                      (and mru (not (eq mru here)) (drgnx-rules--free-p mru) mru))
                    (seq-find (lambda (w) (and (not (eq w here)) (drgnx-rules--free-p w))) (drgnx-groups-list)))))
    (window--display-buffer buffer (or other here) 'reuse alist)))

(drgnx-wb-define-place 'other-group #'drgnx-groups--other-group)
(drgnx-wb-place '(diff-mode log-view-mode vc-annotate-mode magit-diff-mode magit-log-mode magit-revision-mode)
                'other-group)

(provide 'drgnx-groups)
;;; drgnx-groups.el ends here
