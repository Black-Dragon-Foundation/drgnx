;;; drgnx-ruler.el --- The overview ruler: a file's marks scaled to the window's height, at its right edge -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; One owner draws the ruler; producers hand it marks.  A producer registers a function in a buffer
;; (`drgnx-ruler-source'), which returns the marks it has now: (LINE LANE FACE PRIORITY), LANE `left', `middle',
;; `right' or `full' (all three).  The ruler asks its producers again when one says its marks changed
;; (`drgnx-ruler-refresh') and, debounced, after an edit; it keeps the marks sorted by line, and draws from them.
;;
;; The ruler is a claim on the right margin (`drgnx-margins'), as many columns as 12 logical pixels take, held while
;; the buffer has a mark.  Each window shows its own: its shown lines are its rows, row R standing for the file's
;; lines R·N/H to (R+1)·N/H (N lines, H rows; one row a line when the file is shorter than the window).  A row is a
;; margin string on its line (one overlay per row, moved on scroll): three lanes, 3, 6 and 3 logical pixels wide,
;; each in the face of its best mark (highest PRIORITY), else the rows the window shows in `drgnx-ruler-view'.  Rows'
;; lanes are cached on (lines, rows, marks); a scroll moves the overlays and changes only the rows whose strings
;; differ.  In a terminal a row is one character, in the face of its best mark.  A click on a row scrolls there.
;; Rows are lines, not screen lines: a wrapped line makes the window show fewer rows than it is high.
;; docs/develop/core.md, "The overview ruler".

;;; Code:
(require 'cl-lib)
(require 'drgnx-margins)
(require 'drgnx-pixels)
(require 'drgnx-timer)

(defface drgnx-ruler-view '((t :inherit highlight))
  "The ruler's rows for the lines the window shows (its background)." :group 'drgnx)

(defconst drgnx-ruler--lanes '((left . 3) (middle . 6) (right . 3))
  "The lanes, left to right, and their widths in logical pixels.")

(defvar-local drgnx-ruler--sources nil "This buffer's producers: an alist OWNER → FUNCTION (no arguments) → marks.")
(defvar-local drgnx-ruler--marks [] "The marks, sorted by line: a vector of (LINE LANE FACE PRIORITY).")
(defvar-local drgnx-ruler--tick 0 "Counts the times the marks were asked again (a cache key).")
(defvar-local drgnx-ruler--lines 1 "The buffer's lines when the marks were last asked.")
(defvar-local drgnx-ruler--windows nil "Alist WINDOW → overlays, one per row, in row order.")
(defvar-local drgnx-ruler--rows nil "(KEY . VECTOR): each row's lanes (a vector of three faces or nil) for KEY.")
(defvar-local drgnx-ruler--strings nil
  "Rows' `before-string's by (LANES BAND LINE): a hash, emptied with the rows' cache and when the margin moves (a
row's lanes and line depend only on (lines, rows, marks), so it holds at most two strings a row).")

(defvar drgnx-ruler-mode)

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
  "The producers' marks, sorted by line."
  (let (marks)
    (pcase-dolist (`(,_ . ,f) drgnx-ruler--sources) (setq marks (nconc (copy-sequence (funcall f)) marks)))
    (vconcat (sort marks (lambda (a b) (< (car a) (car b)))))))

(defun drgnx-ruler--columns ()
  "The columns 12 logical pixels take in the selected frame (one in a terminal)."
  (if (display-graphic-p)
      (max 1 (ceiling (drgnx-px 12) (frame-char-width)))
    1))

(defun drgnx-ruler-refresh (&optional buffer)
  "Ask BUFFER's producers again (default current), and draw every window showing it."
  (with-current-buffer (or buffer (current-buffer))
    (when drgnx-ruler-mode
      (setq drgnx-ruler--marks (drgnx-ruler--ask)
            drgnx-ruler--lines (max 1 (line-number-at-pos (point-max) t))
            drgnx-ruler--tick (1+ drgnx-ruler--tick))
      (drgnx-margins-claim 'ruler (and (> (length drgnx-ruler--marks) 0) (drgnx-ruler--columns))
                           :side 'right :order 100)
      (drgnx-ruler--draw-all))))

(defun drgnx-ruler--draw-all ()
  "Draw the ruler in each window showing this buffer; drop the rows of windows that no longer do."
  (dolist (cell drgnx-ruler--windows)
    (unless (and (window-live-p (car cell)) (eq (window-buffer (car cell)) (current-buffer)))
      (mapc #'delete-overlay (cdr cell))
      (setq drgnx-ruler--windows (delq cell drgnx-ruler--windows))))
  (dolist (w (get-buffer-window-list nil nil t)) (drgnx-ruler--draw w)))

(defun drgnx-ruler--find (line)
  "The index of the first mark at LINE or after (binary search)."
  (let ((lo 0) (hi (length drgnx-ruler--marks)))
    (while (< lo hi)
      (let ((mid (/ (+ lo hi) 2)))
        (if (< (car (aref drgnx-ruler--marks mid)) line) (setq lo (1+ mid)) (setq hi mid))))
    lo))

(defun drgnx-ruler--lanes-of (from to)
  "The lanes of lines FROM..TO: a vector of three faces (or nil), each its lane's best mark."
  (let ((v (make-vector 3 nil)) (best (make-vector 3 -1)) (n (length drgnx-ruler--marks)) (i (drgnx-ruler--find from)))
    (while (and (< i n) (<= (car (aref drgnx-ruler--marks i)) to))
      (pcase-let ((`(,_ ,lane ,face ,prio) (aref drgnx-ruler--marks i)))
        (dolist (k (pcase lane ('left '(0)) ('middle '(1)) ('right '(2)) (_ '(0 1 2))))
          (when (> (or prio 0) (aref best k)) (aset best k (or prio 0)) (aset v k face))))
      (setq i (1+ i)))
    (and (seq-some #'identity v) v)))

(defun drgnx-ruler--row-lines (r rows)
  "The first and last line row R of ROWS stands for: (FROM . TO)."
  (let ((n drgnx-ruler--lines))
    (if (<= n rows) (cons (1+ r) (1+ r))
      (cons (1+ (/ (* r n) rows)) (max (1+ (/ (* r n) rows)) (/ (* (1+ r) n) rows))))))

(defun drgnx-ruler--row-lanes (rows)
  "Each of ROWS rows' lanes, cached on (lines, rows, marks)."
  (let ((key (list drgnx-ruler--lines rows drgnx-ruler--tick)))
    (unless (equal key (car drgnx-ruler--rows))
      (clrhash drgnx-ruler--strings)
      (setq drgnx-ruler--rows
            (cons key (vconcat (cl-loop for r below rows
                                        collect (let ((l (drgnx-ruler--row-lines r rows)))
                                                  (drgnx-ruler--lanes-of (car l) (cdr l))))))))
    (cdr drgnx-ruler--rows)))

(defun drgnx-ruler--string (lanes band line)
  "A row's `before-string' (the same string for the same arguments until the cache is emptied): its margin string of
LANES (three faces or nil), BAND non-nil for a shown row; a click goes to LINE."
  (let ((key (list lanes band line)))
    (or (gethash key drgnx-ruler--strings)
        (puthash key
                 (propertize
                  " " 'display
                  `((margin right-margin)
                    ,(propertize
                      (concat
                       (drgnx-margins-pad 'ruler)
                       (if (display-graphic-p)
                           (let* ((px (mapcar (lambda (l) (drgnx-px (cdr l))) drgnx-ruler--lanes))
                                  (lead (- (* (drgnx-ruler--columns) (frame-char-width)) (apply #'+ px))))
                             (apply #'concat
                                    (propertize " " 'display `(space :width (,(max 0 lead))))
                                    (cl-loop for w in px for i from 0
                                             collect (propertize " " 'display `(space :width (,w))
                                                                 'face (or (and lanes (aref lanes i))
                                                                           (and band 'drgnx-ruler-view))))))
                         (propertize " " 'face (or (and lanes (or (aref lanes 1) (aref lanes 0) (aref lanes 2)))
                                                   (and band 'drgnx-ruler-view)))))
                      'drgnx-ruler-line line)))
                 drgnx-ruler--strings))))

(defun drgnx-ruler--draw (window)
  "Lay WINDOW's rows on the lines it shows, from the cached marks."
  (when (and (window-live-p window) (eq (window-buffer window) (current-buffer)))
    (let* ((cell (or (assq window drgnx-ruler--windows)
                     (car (push (list window) drgnx-ruler--windows))))
           (old (cdr cell)) (new nil))
      (when (and (drgnx-margins-offset 'ruler) (> (length drgnx-ruler--marks) 0))
        (save-excursion
          (goto-char (window-start window))
          (let* ((first (line-number-at-pos nil t))
                 (rows (min (max 1 (window-body-height window)) drgnx-ruler--lines))
                 (lanes (drgnx-ruler--row-lanes rows))
                 (shown-to (+ first (window-body-height window) -1)))
            (dotimes (r rows)
              (unless (and (> r 0) (eobp))
                (let* ((lines (drgnx-ruler--row-lines r rows))
                       (band (and (<= (car lines) shown-to) (>= (cdr lines) first)))
                       (str (drgnx-ruler--string (aref lanes r) band (car lines)))
                       (o (pop old)))
                  (if o (move-overlay o (point) (point))
                    (setq o (make-overlay (point) (point) nil t nil))
                    (overlay-put o 'window window)
                    (overlay-put o 'drgnx-ruler t))
                  (unless (eq (overlay-get o 'before-string) str)
                    (overlay-put o 'before-string str))
                  (push o new)
                  (forward-line 1)))))))
      (mapc #'delete-overlay old)
      (setcdr cell (nreverse new)))))

(defun drgnx-ruler--scrolled (window _start)
  "`window-scroll-functions': WINDOW's rows move to the lines it shows now."
  (drgnx-ruler--draw window))

(defun drgnx-ruler--resized (window)
  "`window-size-change-functions' and `window-buffer-change-functions' (local): WINDOW draws again."
  (when (windowp window) (drgnx-ruler--draw window)))

(defun drgnx-ruler--changed (&rest _)
  "`after-change-functions': the marks and the line count are asked again once the typing rests."
  (drgnx-timer-debounce (cons 'ruler (current-buffer)) 0.3 #'drgnx-ruler-refresh :args (list (current-buffer))
                        :owner (current-buffer)))

(defun drgnx-ruler--restring (buffer)
  "`drgnx-margins-changed-functions': the ruler's place moved in BUFFER's margin; its strings are made again."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when drgnx-ruler-mode
        (clrhash drgnx-ruler--strings)
        (dolist (cell drgnx-ruler--windows) (mapc (lambda (o) (overlay-put o 'before-string nil)) (cdr cell)))
        (drgnx-ruler--draw-all)))))

(defun drgnx-ruler--off ()
  "`change-major-mode-hook' and `kill-buffer-hook': the ruler goes before the buffer's locals do."
  (drgnx-ruler-mode -1))

(defun drgnx-ruler-click (event)
  "Mouse EVENT on a ruler row: its window shows the row's first line, centred."
  (interactive "e")
  (let* ((posn (event-start event)) (str (posn-string posn))
         (line (and str (get-text-property (cdr str) 'drgnx-ruler-line (car str)))))
    (when line
      (with-selected-window (posn-window posn)
        (goto-char (point-min))
        (forward-line (1- line))
        (recenter)))))

(defvar-keymap drgnx-ruler-mode-map
  :doc "The ruler's mouse: a click on a row goes there."
  "<right-margin> <mouse-1>" #'drgnx-ruler-click
  "<right-margin> <down-mouse-1>" #'ignore)

(define-minor-mode drgnx-ruler-mode
  "The overview ruler in this buffer's right margin, while producers have marks (`drgnx-ruler-source')."
  :group 'drgnx :keymap drgnx-ruler-mode-map
  (if drgnx-ruler-mode
      (progn
        (setq drgnx-ruler--strings (make-hash-table :test #'equal))
        (add-hook 'window-scroll-functions #'drgnx-ruler--scrolled nil t)
        (add-hook 'window-size-change-functions #'drgnx-ruler--resized nil t)
        (add-hook 'window-buffer-change-functions #'drgnx-ruler--resized nil t)
        (add-hook 'after-change-functions #'drgnx-ruler--changed nil t)
        (add-hook 'change-major-mode-hook #'drgnx-ruler--off nil t)
        (add-hook 'kill-buffer-hook #'drgnx-ruler--off nil t)
        (add-hook 'drgnx-margins-changed-functions #'drgnx-ruler--restring)
        (drgnx-ruler-refresh))
    (remove-hook 'window-scroll-functions #'drgnx-ruler--scrolled t)
    (remove-hook 'window-size-change-functions #'drgnx-ruler--resized t)
    (remove-hook 'window-buffer-change-functions #'drgnx-ruler--resized t)
    (remove-hook 'after-change-functions #'drgnx-ruler--changed t)
    (remove-hook 'change-major-mode-hook #'drgnx-ruler--off t)
    (remove-hook 'kill-buffer-hook #'drgnx-ruler--off t)
    (drgnx-timer-cancel (cons 'ruler (current-buffer)))
    (dolist (cell drgnx-ruler--windows) (mapc #'delete-overlay (cdr cell)))
    (setq drgnx-ruler--windows nil drgnx-ruler--rows nil drgnx-ruler--marks [] drgnx-ruler--sources nil)
    (drgnx-margins-claim 'ruler nil)
    (unless (seq-some (lambda (b) (buffer-local-value 'drgnx-ruler-mode b)) (buffer-list))
      (remove-hook 'drgnx-margins-changed-functions #'drgnx-ruler--restring))))

(provide 'drgnx-ruler)
;;; drgnx-ruler.el ends here
