;;; drgnx-echo-early.el --- early-init: graphical frames born without the echo row -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; ui/look's `drgnx-look-echo-row' `float' (the default) gives a graphical frame no echo row: its minibuffer is a
;; hidden child frame, the box.  A frame cannot gain or lose its minibuffer after it is made, so the first frame has
;; to be born with it: early-init.el calls `drgnx-echo-early-setup' before Emacs makes that frame, on a Nidhogg that
;; makes the first frame that way (lisp/nidhogg-frame.el) or in a daemon.  It reads
;; settings.el as data, and only when the file mentions the setting or ui/look: `classic', or ui/look turned off,
;; leaves the frames as Emacs makes them.  The module's setup then finds the frame as it wants it and swaps nothing.

;;; Code:
(defconst drgnx-echo-early--dir (file-name-directory (or load-file-name buffer-file-name default-directory))
  "The folder of this file, drgnx's core/: early-init.el loads this file before `load-path' has it.")

(defun drgnx-echo-early--require (feature)
  "Require FEATURE from this file's folder, whatever `load-path' says."
  (let ((load-path (cons drgnx-echo-early--dir load-path)))
    (require feature)))

(drgnx-echo-early--require 'drgnx-paths)

(defconst drgnx-echo-early-systems '(x w32 ns pgtk haiku android)
  "The graphical window systems: their frames get the box; a terminal's keeps its row.")

(defconst drgnx-echo-early-box
  '((drgnx-echo . t) (visibility . nil) (minibuffer-exit . t) (undecorated . t) (no-other-frame . t)
    (skip-taskbar . t) (menu-bar-lines . 0) (tool-bar-lines . 0) (tab-bar-lines . 0))
  "The box's parameters a frame is born with (`minibuffer-frame-alist'); ui/look adds the palette's look.")

(declare-function drgnx-user-dir "drgnx-paths" ())
(declare-function drgnx-settings-file-read "drgnx-settings-file" (file &optional type))
(declare-function drgnx-settings-doc-entries "drgnx-settings-file" (doc))
(declare-function drgnx-settings-entry-var "drgnx-settings-file" (entry))
(declare-function drgnx-settings-entry-scope "drgnx-settings-file" (entry))
(declare-function drgnx-settings-entry-value "drgnx-settings-file" (entry))

(defun drgnx-echo-early-wanted-p (file)
  "Non-nil unless the settings FILE sets `drgnx-look-echo-row' to `classic' or lists ui/look in
`drgnx-modules-disabled'.  The file is read as data, and only when it mentions either; unreadable, it counts as
wanted (the module swaps the frames if it is not)."
  (or (not (file-readable-p file))
      (not (with-temp-buffer
             (insert-file-contents file nil 0 1048576)
             (or (search-forward "drgnx-look-echo-row" nil t)
                 (progn (goto-char (point-min)) (search-forward "ui/look" nil t)))))
      (condition-case nil
          (progn
            (drgnx-echo-early--require 'drgnx-settings-file)
            (let (row disabled)
              (dolist (e (drgnx-settings-doc-entries (drgnx-settings-file-read file 'drgnx-settings)))
                (unless (drgnx-settings-entry-scope e)
                  (pcase (drgnx-settings-entry-var e)
                    ('drgnx-look-echo-row (setq row (drgnx-settings-entry-value e)))
                    ('drgnx-modules-disabled (setq disabled (drgnx-settings-entry-value e))))))
              (not (or (eq row 'classic) (memq 'ui/look disabled)))))
        (error t))))

(defun drgnx-echo-early-born-p ()
  "Non-nil when the first graphical frame can be born with the box: Nidhogg makes it so (lisp/nidhogg-frame.el), or
a daemon makes no first graphical frame (its clients' frames are made with the box).  Stock Emacs makes the first frame
with a minibuffer of its own and, asked for another, makes it again after init, waiting for it to show; there the
module swaps the first frame instead."
  (or (featurep 'nidhogg-frame) (daemonp)))

(defun drgnx-echo-early-setup ()
  "From early-init.el: graphical frames are made with the box, unless your settings say otherwise or this Emacs cannot
make the first frame so (`drgnx-echo-early-born-p').  Never signals."
  (condition-case nil
      (when (and (drgnx-echo-early-born-p)
                 (drgnx-echo-early-wanted-p (expand-file-name "settings.el" (drgnx-user-dir))))
        (dolist (sys drgnx-echo-early-systems)
          (setf (alist-get 'minibuffer (alist-get sys window-system-default-frame-alist)) 'child-frame))
        (setq minibuffer-frame-alist (append drgnx-echo-early-box minibuffer-frame-alist)))
    (error nil)))

(provide 'drgnx-echo-early)
;;; drgnx-echo-early.el ends here
