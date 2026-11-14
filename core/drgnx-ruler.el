;;; drgnx-ruler.el --- The overview ruler: a file's marks scaled to the window's height, at its right edge -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; One owner draws the ruler; producers hand it marks.  A producer registers a function in a buffer
;; (`drgnx-ruler-source'), which returns the marks it has now: (POS LANE FACE PRIORITY), LANE `left', `middle',
;; `right' or `full' (all three).  The ruler asks its producers again when one says its marks changed
;; (`drgnx-ruler-refresh') and, debounced, after an edit.
;;
;; Nidhogg draws it (Glitnir's overview ruler, the window parameter `glitnir-ruler'): a strip 12 logical pixels wide
;; in the window's right fringe, widened by that much while the ruler is on, next to the text.  The fringe's own
;; pixels stay outermost, so the card edge's drag (`drgnx-look-edge-drag') keeps its place.  Marks sit at their
;; position's fraction of the buffer, by characters as Emacs's scroll bar measures (a file of very long lines looks
;; uneven), and the band over the part shown moves with a scroll in C: nothing here runs on a scroll.  The parameter
;; is set only when the marks or the window's fringe change.  A click on the strip goes there.  Without Nidhogg's
;; feature `glitnir-ruler', or in a terminal, there is no ruler.  docs/develop/core.md, "The overview ruler".

;;; Code:
(require 'cl-lib)
(require 'drgnx-pixels)
(require 'drgnx-timer)

(declare-function glitnir-ruler-position "glitnir" (posn))

(defface drgnx-ruler-view '((t :inherit shadow))
  "The ruler's band over the part of the file the window shows (its foreground)." :group 'drgnx)

(defconst drgnx-ruler--lanes '((left 0 . 3) (middle 3 . 9) (right 9 . 12) (full 0 . 12))
  "Each lane's x range in the strip, in logical pixels.")

(defconst drgnx-ruler--width 12 "The strip's width in logical pixels.")

(defvar-local drgnx-ruler--sources nil "This buffer's producers: an alist OWNER → FUNCTION (no arguments) → marks.")
(defvar-local drgnx-ruler--marks nil "The marks as last asked, drawn in this order: (POS LANE FACE PRIORITY) each.")

(defvar drgnx-ruler-mode)

(defun drgnx-ruler-available-p ()
  "Whether this Emacs draws the ruler: Nidhogg's Glitnir on a graphical frame."
  (and (featurep 'glitnir-ruler) (display-graphic-p)))

(defun drgnx-ruler-source (owner function &optional buffer)
  "OWNER's marks in BUFFER (default current) come from FUNCTION; nil FUNCTION takes OWNER's marks away."
  (with-current-buffer (or buffer (current-buffer))
    (setq drgnx-ruler--sources (if function
                                   (cons (cons owner function) (assq-delete-all owner drgnx-ruler--sources))
                                 (assq-delete-all owner drgnx-ruler--sources)))
    (if drgnx-ruler--sources
        (if drgnx-ruler-mode (drgnx-ruler-refresh) (drgnx-ruler-mode 1))
      (when drgnx-ruler-mode (drgnx-ruler-mode -1)))))

(defun drgnx-ruler--ask ()
  "The producers' marks, the highest PRIORITY last (drawn on top)."
  (let (marks)
    (pcase-dolist (`(,_ . ,f) drgnx-ruler--sources) (setq marks (nconc (copy-sequence (funcall f)) marks)))
    (sort marks (lambda (a b) (< (or (nth 3 a) 0) (or (nth 3 b) 0))))))

(defun drgnx-ruler--spec (window)
  "WINDOW's `glitnir-ruler': the strip in its fringe, beside the text, and the marks."
  (let ((frame (window-frame window)))
    (list :width (drgnx-px drgnx-ruler--width frame)
          :right (or (window-parameter window 'drgnx-ruler-fringe) 0)
          :height (drgnx-px 3 frame)
          :band '(drgnx-ruler-view . 0.35)
          :marks (mapcar (lambda (m)
                           (let ((lane (alist-get (nth 1 m) drgnx-ruler--lanes)))
                             (list (car m) (drgnx-px (car lane) frame) (drgnx-px (cdr lane) frame) (nth 2 m))))
                         drgnx-ruler--marks))))

(defun drgnx-ruler--show (window)
  "Give WINDOW the strip: its right fringe widened by the strip (once), and the marks, set only when they changed."
  (let* ((fr (window-fringes window))
         (width (drgnx-px drgnx-ruler--width (window-frame window)))
         (own (or (window-parameter window 'drgnx-ruler-fringe) (cadr fr))))
    (unless (and (window-parameter window 'drgnx-ruler-fringe) (= (cadr fr) (+ own width)))
      (setq own (if (window-parameter window 'drgnx-ruler-fringe) own (cadr fr)))
      (set-window-parameter window 'drgnx-ruler-fringe own)
      (set-window-fringes window (car fr) (+ own width) (nth 2 fr)))
    (let ((spec (drgnx-ruler--spec window)))
      (unless (equal spec (window-parameter window 'glitnir-ruler))
        (set-window-parameter window 'glitnir-ruler spec)))))

(defun drgnx-ruler--hide (window)
  "Take the strip from WINDOW: the marks, and its fringe back to its own width."
  (when (window-live-p window)
    (when-let* ((own (window-parameter window 'drgnx-ruler-fringe)))
      (let ((fr (window-fringes window)))
        (set-window-fringes window (car fr) own (nth 2 fr)))
      (set-window-parameter window 'drgnx-ruler-fringe nil))
    (when (window-parameter window 'glitnir-ruler)
      (set-window-parameter window 'glitnir-ruler nil))))

(defun drgnx-ruler-refresh (&optional buffer)
  "Ask BUFFER's producers again (default current), and give every window showing it the marks."
  (with-current-buffer (or buffer (current-buffer))
    (when drgnx-ruler-mode
      (setq drgnx-ruler--marks (drgnx-ruler--ask))
      (dolist (w (get-buffer-window-list nil nil t))
        (if (and drgnx-ruler--marks (with-selected-frame (window-frame w) (drgnx-ruler-available-p)))
            (drgnx-ruler--show w)
          (drgnx-ruler--hide w))))))

(defun drgnx-ruler--buffer-changed (frame-or-window)
  "`window-buffer-change-functions' (global): a window that now shows another buffer loses this one's strip, and
one that shows a buffer with the ruler gets it."
  (dolist (w (if (windowp frame-or-window) (list frame-or-window) (window-list frame-or-window 'nomini)))
    (if (buffer-local-value 'drgnx-ruler-mode (window-buffer w))
        (with-current-buffer (window-buffer w)
          (when (and drgnx-ruler--marks (drgnx-ruler-available-p)) (drgnx-ruler--show w)))
      (when (or (window-parameter w 'glitnir-ruler) (window-parameter w 'drgnx-ruler-fringe))
        (drgnx-ruler--hide w)))))

(defun drgnx-ruler--changed (&rest _)
  "`after-change-functions': the marks are asked again once the typing rests."
  (drgnx-timer-debounce (cons 'ruler (current-buffer)) 0.3 #'drgnx-ruler-refresh :args (list (current-buffer))
                        :owner (current-buffer)))

(defun drgnx-ruler--off ()
  "`change-major-mode-hook' and `kill-buffer-hook': the ruler goes before the buffer's locals do."
  (drgnx-ruler-mode -1))

(defun drgnx-ruler-click (event)
  "Mouse EVENT on the ruler's strip: its window shows that place of the file, centred."
  (interactive "e")
  (let* ((posn (event-start event))
         (pos (and (fboundp 'glitnir-ruler-position) (glitnir-ruler-position posn))))
    (when pos
      (with-selected-window (posn-window posn)
        (goto-char pos)
        (recenter)))))

(defvar-keymap drgnx-ruler-mode-map
  :doc "The ruler's mouse: a click on the strip goes there."
  "<right-fringe> <mouse-1>" #'drgnx-ruler-click)

(define-minor-mode drgnx-ruler-mode
  "The overview ruler at this buffer's windows' right edge, while producers have marks (`drgnx-ruler-source')."
  :group 'drgnx :keymap drgnx-ruler-mode-map
  (if drgnx-ruler-mode
      (progn
        (add-hook 'after-change-functions #'drgnx-ruler--changed nil t)
        (add-hook 'change-major-mode-hook #'drgnx-ruler--off nil t)
        (add-hook 'kill-buffer-hook #'drgnx-ruler--off nil t)
        (add-hook 'window-buffer-change-functions #'drgnx-ruler--buffer-changed)
        (drgnx-ruler-refresh))
    (remove-hook 'after-change-functions #'drgnx-ruler--changed t)
    (remove-hook 'change-major-mode-hook #'drgnx-ruler--off t)
    (remove-hook 'kill-buffer-hook #'drgnx-ruler--off t)
    (drgnx-timer-cancel (cons 'ruler (current-buffer)))
    (mapc #'drgnx-ruler--hide (get-buffer-window-list nil nil t))
    (setq drgnx-ruler--marks nil drgnx-ruler--sources nil)
    (unless (seq-some (lambda (b) (and (not (eq b (current-buffer))) (buffer-local-value 'drgnx-ruler-mode b)))
                      (buffer-list))
      (remove-hook 'window-buffer-change-functions #'drgnx-ruler--buffer-changed))))

(provide 'drgnx-ruler)
;;; drgnx-ruler.el ends here
