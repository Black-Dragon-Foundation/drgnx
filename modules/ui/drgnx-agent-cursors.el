;;; drgnx-agent-cursors.el --- Agent cursors: where each agent is editing, in its colour -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; One overlay per agent and buffer: a 2 px bar in the agent's colour where the text is unboxed, the underlying box
;; restated where it is boxed, with the agent's name tag for 2 s after a move (Glitnir's box `:label').  Moves are
;; batched into one 50 ms flush, or applied at once (`drgnx-agent-cursor-move-now').  The agents' editor overlay
;; (modules/tools/drgnx-agents-editor-draw.el) draws its bars with these.  Moved out of the decorations
;; (modules/ui/drgnx-decor.el).  See docs/guide/modules.md, ui/look, and docs/develop/agents-editor.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-timer)

(defun drgnx-agent-cursors--glitnir-p ()
  "Non-nil when this Emacs accepts the Glitnir box keys (the bar's open sides, the name tag)."
  (featurep 'glitnir))

(cl-defstruct (drgnx-agent-cursors--cursor (:constructor drgnx-agent-cursors--cursor-make))
  overlay color name pending label-until)

(defvar drgnx-agent-cursors--cursors (make-hash-table :test #'equal)
  "(BUFFER . AGENT) to its `drgnx-agent-cursors--cursor'.")

(defconst drgnx-agent-cursor-batch 0.05 "Seconds in which an agent's cursor moves are collected into one.")
(defconst drgnx-agent-cursor-label-time 2 "Seconds a cursor's name tag shows after a move.")

(defun drgnx-agent-cursors--face-box (face)
  "The `:box' FACE (a face, a list of faces, or a plist) specifies, or nil."
  (cond ((null face) nil)
        ((keywordp (car-safe face)) (plist-get face :box))
        ((consp face) (cl-some #'drgnx-agent-cursors--face-box face))
        ((facep face) (let ((box (face-attribute face :box nil t))) (and box (not (eq box 'unspecified)) box)))))

(defun drgnx-agent-cursors--box-at (pos)
  "The box of the text at POS, from its `face' property and the overlays other than agent cursors; nil if unboxed."
  (and (<= (point-min) pos) (< pos (point-max))
       (or (drgnx-agent-cursors--face-box (get-text-property pos 'face))
           (cl-some (lambda (ov)
                      (and (not (overlay-get ov 'drgnx-agent-cursor)) (drgnx-agent-cursors--face-box (overlay-get ov 'face))))
                    (sort (overlays-at pos) (lambda (a b) (> (or (overlay-get a 'priority) 0)
                                                             (or (overlay-get b 'priority) 0))))))))

(defun drgnx-agent-cursors--cursor-face (pos color name label)
  "The face of an agent cursor at POS in the current buffer, in COLOR; NAME is its tag when LABEL.
Where the glyph and both neighbours are unboxed: the bar (a 2 px left edge).  Otherwise the underlying box,
restated, with only the background and the tag changed (a boxed cursor face would take its neighbour's edge)."
  (let* ((glitnir (drgnx-agent-cursors--glitnir-p))
         (under (or (drgnx-agent-cursors--box-at pos) (drgnx-agent-cursors--box-at (1- pos)) (drgnx-agent-cursors--box-at (1+ pos))))
         (tag (and glitnir label (list :label name))))
    (cond (under
           (list :background color
                 :box (if (and tag (keywordp (car-safe under))) (append under tag) under)))
          (glitnir (list :background color
                         :box (append (list :line-width '(-2 . -1) :color color :open '(top right bottom)) tag)))
          ((display-graphic-p) (list :background color))
          ;; a terminal has no 2 px edge: the character under the bar in the colour's inverse
          (t (list :foreground color :inverse-video t)))))

(defun drgnx-agent-cursors--cursor-apply (cur)
  "Put CUR's overlay's face in line with its position and name tag."
  (let ((ov (drgnx-agent-cursors--cursor-overlay cur)))
    (with-current-buffer (overlay-buffer ov)
      (let ((pos (overlay-start ov)) (color (drgnx-agent-cursors--cursor-color cur)) (name (drgnx-agent-cursors--cursor-name cur)))
        (overlay-put ov 'face (drgnx-agent-cursors--cursor-face
                               pos color name (and (drgnx-agent-cursors--cursor-label-until cur) t)))
        (overlay-put ov 'mouse-face (drgnx-agent-cursors--cursor-face pos color name t))))))

(defun drgnx-agent-cursors--cursor-key (buffer agent) (cons buffer agent))

(defun drgnx-agent-cursors--sweep ()
  "Prune cursors of dead buffers; drop the name tags that are due and arm the timer for the next one."
  (let ((now (drgnx-timer-now)) next)
    (maphash
     (lambda (key cur)
       (if (not (buffer-live-p (car key)))
           (progn (remhash key drgnx-agent-cursors--cursors) (ignore-errors (delete-overlay (drgnx-agent-cursors--cursor-overlay cur))))
         (let ((until (drgnx-agent-cursors--cursor-label-until cur)))
           (when (and until (not (eq until 'always)))
             (if (<= until (+ now 1e-6))
                 (progn (setf (drgnx-agent-cursors--cursor-label-until cur) nil) (drgnx-agent-cursors--cursor-apply cur))
               (setq next (min until (or next until))))))))
     drgnx-agent-cursors--cursors)
    (when next (drgnx-timer-start 'agent-cursor-label (- next now) #'drgnx-agent-cursors--sweep))))

(defun drgnx-agent-cursors--flush ()
  "Apply every agent's last pending position (one overlay move each) and show their name tags."
  (let (moved)
    (maphash
     (lambda (key cur)
       (let ((pos (drgnx-agent-cursors--cursor-pending cur)))
         (when (and pos (buffer-live-p (car key)))
           (with-current-buffer (car key)
             (let ((pos (max (point-min) (min pos (max (point-min) (1- (point-max)))))))
               (move-overlay (drgnx-agent-cursors--cursor-overlay cur) pos (min (point-max) (1+ pos)))))
           (setf (drgnx-agent-cursors--cursor-pending cur) nil
                 (drgnx-agent-cursors--cursor-label-until cur) (+ (drgnx-timer-now) drgnx-agent-cursor-label-time))
           (drgnx-agent-cursors--cursor-apply cur)
           (setq moved t))))
     drgnx-agent-cursors--cursors)
    (when moved (drgnx-timer-start 'agent-cursor-label drgnx-agent-cursor-label-time #'drgnx-agent-cursors--sweep))))

(defun drgnx-agent-cursor-put (buffer agent pos color name)
  "Show AGENT's cursor in BUFFER at POS, in COLOR (a theme colour), tagged NAME: one overlay at (POS, POS+1).
An existing cursor of AGENT in BUFFER is replaced.  The tag shows for 2 s."
  (drgnx-agent-cursor-remove buffer agent)
  (with-current-buffer buffer
    (let* ((pos (max (point-min) (min pos (point-max))))
           (ov (make-overlay pos (min (point-max) (1+ pos)) buffer))
           (cur (drgnx-agent-cursors--cursor-make :overlay ov :color color :name name
                                                  :label-until (+ (drgnx-timer-now) drgnx-agent-cursor-label-time))))
      (overlay-put ov 'drgnx-agent-cursor agent)
      (overlay-put ov 'priority 100)
      (puthash (drgnx-agent-cursors--cursor-key buffer agent) cur drgnx-agent-cursors--cursors)
      (drgnx-agent-cursors--cursor-apply cur)
      (drgnx-timer-start 'agent-cursor-label drgnx-agent-cursor-label-time #'drgnx-agent-cursors--sweep)
      ov)))

(defun drgnx-agent-cursor-move (buffer agent pos)
  "Move AGENT's cursor in BUFFER to POS.  Moves are batched: one 50 ms timer for all agents applies the last."
  (when-let* ((cur (gethash (drgnx-agent-cursors--cursor-key buffer agent) drgnx-agent-cursors--cursors)))
    (setf (drgnx-agent-cursors--cursor-pending cur) pos)
    (drgnx-timer-soon 'agent-cursor-flush drgnx-agent-cursor-batch #'drgnx-agent-cursors--flush)))

(defvar drgnx-agent-cursors--label-mode 'activity
  "How name tags show on cursors moved now: `activity' (2 s after a move) or `never'; `drgnx-agent-cursor-keep-label'
holds one tag on.")

;; A frame the editor client applies at once does not wait for the 50 ms batch.

(defun drgnx-agent-cursor-move-now (buffer agent pos)
  "Move AGENT's cursor in BUFFER to POS now: the same overlay moves, no batch timer.  Its name tag follows the tag mode
\(`drgnx-agent-cursor-label-mode')."
  (when-let* ((cur (gethash (drgnx-agent-cursors--cursor-key buffer agent) drgnx-agent-cursors--cursors)))
    (with-current-buffer buffer
      (let ((pos (max (point-min) (min pos (max (point-min) (1- (point-max)))))))
        (move-overlay (drgnx-agent-cursors--cursor-overlay cur) pos (min (point-max) (1+ pos)))))
    (setf (drgnx-agent-cursors--cursor-pending cur) nil)
    (unless (eq (drgnx-agent-cursors--cursor-label-until cur) 'always)
      (setf (drgnx-agent-cursors--cursor-label-until cur)
            (and (not (eq drgnx-agent-cursors--label-mode 'never)) (+ (drgnx-timer-now) drgnx-agent-cursor-label-time))))
    (drgnx-agent-cursors--cursor-apply cur)
    (when (numberp (drgnx-agent-cursors--cursor-label-until cur))
      (drgnx-timer-start 'agent-cursor-label drgnx-agent-cursor-label-time #'drgnx-agent-cursors--sweep))))

(defun drgnx-agent-cursor-label-mode (mode)
  "Set the tag mode for cursors moved now: `activity' or `never'."
  (setq drgnx-agent-cursors--label-mode mode))

(defun drgnx-agent-cursor-keep-label (buffer agent keep)
  "KEEP non-nil: AGENT's name tag in BUFFER stays on; nil: it follows the tag mode again."
  (when-let* ((cur (gethash (drgnx-agent-cursors--cursor-key buffer agent) drgnx-agent-cursors--cursors)))
    (setf (drgnx-agent-cursors--cursor-label-until cur)
          (cond (keep 'always) ((eq drgnx-agent-cursors--label-mode 'never) nil)
                (t (+ (drgnx-timer-now) drgnx-agent-cursor-label-time))))
    (drgnx-agent-cursors--cursor-apply cur)))

(defun drgnx-agent-cursor-overlay (buffer agent)
  "AGENT's cursor overlay in BUFFER, or nil."
  (when-let* ((cur (gethash (drgnx-agent-cursors--cursor-key buffer agent) drgnx-agent-cursors--cursors)))
    (drgnx-agent-cursors--cursor-overlay cur)))

(defun drgnx-agent-cursor-label-state (buffer agent)
  "AGENT's tag in BUFFER: `always', the time it is due off, or nil (not shown)."
  (when-let* ((cur (gethash (drgnx-agent-cursors--cursor-key buffer agent) drgnx-agent-cursors--cursors)))
    (drgnx-agent-cursors--cursor-label-until cur)))

(defun drgnx-agent-cursor-remove (buffer agent)
  "Remove AGENT's cursor from BUFFER."
  (let ((key (drgnx-agent-cursors--cursor-key buffer agent)))
    (when-let* ((cur (gethash key drgnx-agent-cursors--cursors)))
      (delete-overlay (drgnx-agent-cursors--cursor-overlay cur))
      (remhash key drgnx-agent-cursors--cursors)
      (when (zerop (hash-table-count drgnx-agent-cursors--cursors))
        (drgnx-timer-cancel 'agent-cursor-flush)
        (drgnx-timer-cancel 'agent-cursor-label)))))

(provide 'drgnx-agent-cursors)
;;; drgnx-agent-cursors.el ends here
