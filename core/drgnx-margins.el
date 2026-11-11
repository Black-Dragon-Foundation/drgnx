;;; drgnx-margins.el --- One owner of the window margins: claims per buffer, centring per window -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Several things want the left margin: zen centres the text, and in terminals the change marks (extra/hunks), the
;; agents' strip and the debug column draw characters there.  Setting the margins directly, whichever ran last won.
;; Here each owner makes a claim instead: (OWNER COLUMNS ORDER) on a side of a buffer, and zen sets a centring per
;; window.  A window's margin on a side is its centring plus the sum of its buffer's claims there, set again when a
;; claim or a centring changes, when a window shows another buffer and when a window's size changes.
;;
;; Claims sit side by side, lowest ORDER outermost (on the left side: leftmost).  An owner puts its margin strings
;; after `drgnx-margins-pad' (blanks up to its claim), so the columns keep their places whatever else is on.  The pad
;; is the same in every window of a buffer: it is computed for the buffer's first window, and owners draw again when
;; `drgnx-margins-changed-functions' says the places moved.
;;
;; The window hooks are on only while some buffer has a claim or some window a centring.

;;; Code:
(require 'cl-lib)

(defvar-local drgnx-margins--claims nil
  "This buffer's claims: a list of (OWNER SIDE COLUMNS ORDER), SIDE `left' or `right'.")

(defvar drgnx-margins-changed-functions nil
  "Called with a buffer whose claims' places (`drgnx-margins-offset') may have moved: its owners draw again.")

(defun drgnx-margins--sum (buffer side)
  "The columns BUFFER's claims take on SIDE."
  (let ((n 0))
    (dolist (c (buffer-local-value 'drgnx-margins--claims buffer) n)
      (when (eq (nth 1 c) side) (setq n (+ n (nth 2 c)))))))

(defun drgnx-margins-centring (window)
  "The columns zen centres WINDOW's text by, on each side (0 when none)."
  (or (window-parameter window 'drgnx-margins-centre) 0))

(defun drgnx-margins-apply (window)
  "Set WINDOW's margins: its centring plus its buffer's claims, on each side."
  (when (window-live-p window)
    (let* ((b (window-buffer window)) (c (drgnx-margins-centring window))
           (l (+ c (drgnx-margins--sum b 'left))) (r (+ c (drgnx-margins--sum b 'right))))
      (unless (equal (window-margins window) (cons (and (> l 0) l) (and (> r 0) r)))
        (set-window-margins window l r)))))

(defun drgnx-margins--apply-buffer (buffer)
  "Set the margins of every window showing BUFFER, its default widths, and tell its owners."
  (with-current-buffer buffer
    (let ((l (drgnx-margins--sum buffer 'left)) (r (drgnx-margins--sum buffer 'right)))
      (if (> l 0) (setq-local left-margin-width l) (kill-local-variable 'left-margin-width))
      (if (> r 0) (setq-local right-margin-width r) (kill-local-variable 'right-margin-width))))
  (dolist (w (get-buffer-window-list buffer nil t)) (drgnx-margins-apply w))
  (run-hook-with-args 'drgnx-margins-changed-functions buffer))

(cl-defun drgnx-margins-claim (owner columns &key (side 'left) (order 0) (buffer (current-buffer)))
  "OWNER claims COLUMNS on SIDE of BUFFER's margins at ORDER (lowest outermost); COLUMNS nil or 0 takes it back."
  (with-current-buffer buffer
    (let* ((old (assq owner drgnx-margins--claims))
           (new (and columns (> columns 0) (list owner side columns order))))
      (unless (equal old new)
        (setq drgnx-margins--claims
              (sort (if new (cons new (remq old drgnx-margins--claims)) (remq old drgnx-margins--claims))
                    (lambda (a b) (< (nth 3 a) (nth 3 b)))))
        (drgnx-margins--watch)
        (drgnx-margins--apply-buffer buffer)))))

(defun drgnx-margins-centre (window columns)
  "Centre WINDOW's text by COLUMNS on each side (zen); nil or 0 takes the centring away."
  (let ((columns (and columns (> columns 0) columns)))
    (unless (eql columns (window-parameter window 'drgnx-margins-centre))
      (set-window-parameter window 'drgnx-margins-centre columns)
      (drgnx-margins--watch)
      (drgnx-margins-apply window)
      (run-hook-with-args 'drgnx-margins-changed-functions (window-buffer window)))))

(defun drgnx-margins-offset (owner &optional buffer)
  "The columns before OWNER's claim in BUFFER's margin on its side: the centring of BUFFER's first window, then the
claims before it; nil when OWNER has no claim."
  (let* ((buffer (or buffer (current-buffer)))
         (claims (buffer-local-value 'drgnx-margins--claims buffer))
         (mine (assq owner claims)))
    (when mine
      (let ((w (get-buffer-window buffer t)) (n 0))
        (cl-loop for c in claims until (eq (car c) owner)
                 when (eq (nth 1 c) (nth 1 mine)) do (setq n (+ n (nth 2 c))))
        (+ n (if w (drgnx-margins-centring w) 0))))))

(defun drgnx-margins-pad (owner &optional buffer)
  "Blanks up to OWNER's claim in BUFFER's margin: what its margin strings start with."
  (make-string (or (drgnx-margins-offset owner buffer) 0) ?\s))

;;;; The window hooks, on only while needed

(defun drgnx-margins--window-buffer-changed (frame-or-window)
  "`window-buffer-change-functions': the windows of FRAME-OR-WINDOW take their buffers' claims."
  (dolist (w (if (framep frame-or-window) (window-list frame-or-window 'nomini) (list frame-or-window)))
    (drgnx-margins-apply w)))

(defun drgnx-margins--live-p ()
  "Whether some buffer has a claim or some window a centring."
  (or (cl-some (lambda (b) (buffer-local-value 'drgnx-margins--claims b)) (buffer-list))
      (cl-some (lambda (f) (cl-some (lambda (w) (window-parameter w 'drgnx-margins-centre)) (window-list f 'nomini)))
               (frame-list))))

(defun drgnx-margins--watch ()
  "Hold the window hooks while `drgnx-margins--live-p', and only then."
  (if (drgnx-margins--live-p)
      (progn (add-hook 'window-buffer-change-functions #'drgnx-margins--window-buffer-changed)
             (add-hook 'window-size-change-functions #'drgnx-margins--window-buffer-changed))
    (remove-hook 'window-buffer-change-functions #'drgnx-margins--window-buffer-changed)
    (remove-hook 'window-size-change-functions #'drgnx-margins--window-buffer-changed)))

(provide 'drgnx-margins)
;;; drgnx-margins.el ends here
