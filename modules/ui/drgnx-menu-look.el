;;; drgnx-menu-look.el --- The look of Nidhogg's native menus: the ☰ list and the context menus -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Nidhogg's menus (lisp/term/nhwl-menu.el) are child frames showing one text row per item.  Left alone, `nhwl-menu' inherits
;; the stock `menu' face (the fixed-pitch default at 13 px) and a row is one text line high with no room at its ends:
;; unusably small beside the 16 px UI.  This file makes them usable and nothing more (the card's look waits for the
;; shared component system): the text is the UI sans at the UI size on the overlay surface, every row is
;; `drgnx-menu-look-row' px high with `drgnx-menu-look-pad' px of room each side (a spacer and spaces drawn into the
;; row, scaled by the frame's pixel rule), and the row under the pointer is read from the text (nhwl-menu.el finds it
;; as the pointer's y over `frame-char-height', which taller rows break).
;; Part of the module ui/face: set up by its setup, undone by its teardown.  docs/guide/face.md, "The menu bar".

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-pixels)
(require 'drgnx-modules)

(defconst drgnx-menu-look-row 28 "A menu row's height, logical pixels.")
(defconst drgnx-menu-look-pad 12 "The room at either end of a menu row, logical pixels.")

(defvar nhwl-menu--rows)

(defun drgnx-menu-look--dress-buffer (buffer)
  "Give each row of menu BUFFER its height and its room at either end."
  (with-current-buffer buffer
    (let* ((inhibit-read-only t) (height (drgnx-px drgnx-menu-look-row)) (pad (drgnx-px drgnx-menu-look-pad))
           (extent (drgnx-pixels-font-extent 'nhwl-menu))
           (descent (if extent (+ (cdr extent) (/ (- height (car extent) (cdr extent)) 2)) 0))
           (lead (concat (propertize " " 'display `(space :width (,pad)))
                         (or (and extent (drgnx-pixels-spacer 'nhwl-menu height descent)) "")))
           (tail (propertize " " 'display `(space :width (,pad)))))
      (save-excursion
        (goto-char (point-min))
        (while (not (eobp))
          (insert lead)
          (end-of-line)
          (insert tail)
          (forward-line 1))))
    buffer))

(defun drgnx-menu-look--row-of (at event)
  "AT, what `nhwl-menu--locate' answered for pointer EVENT, with its row read from the text under the pointer.
Nidhogg finds the row as the pointer's y over `frame-char-height' (nhwl-menu.el, `nhwl-menu--locate'), which is right
only for rows one text line high; ours are taller."
  (if-let* ((at) (posn (ignore-errors (event-end event))) ((posnp posn))
            (window (nth 2 at)) ((window-live-p window))
            (y (cdr-safe (posn-x-y posn))) ((numberp y)))
      (with-current-buffer (window-buffer window)
        (let* ((point (posn-point posn))
               (row (and point (>= y 0) (1- (line-number-at-pos point)))))
          (list (nth 0 at) (and row (< row (length nhwl-menu--rows)) row) window)))
    at))

(defun drgnx-menu-look-setup ()
  "Make Nidhogg's menus follow the look: their faces, their rows and their frames (called by the module ui/face)."
  (drgnx-module-face-spec 'nhwl-menu '((t :inherit (drgnx-ui-text drgnx-surface-overlay))))
  (drgnx-module-advice 'nhwl-menu--buffer :filter-return menu-look-rows (buffer)
    :module 'ui/face
    (drgnx-menu-look--dress-buffer buffer))
  (drgnx-module-advice 'nhwl-menu--locate :around menu-look-locate (orig event)
    :module 'ui/face
    (drgnx-menu-look--row-of (funcall orig event) event)))

(provide 'drgnx-menu-look)
;;; drgnx-menu-look.el ends here
