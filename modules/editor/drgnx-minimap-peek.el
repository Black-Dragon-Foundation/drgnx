;;; drgnx-minimap-peek.el --- The minimap's hover peek, problems card, visited trail and describe -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Part of the editor/minimap module (docs/guide/minimap.md; design M2, X8, M4, A2).  Nidhogg draws the minimap and
;; decides when the pointer rests: 300 ms on a row is one `dwell' event, on the marks lane `dwell-marks', on a label
;; `dwell-label' (`glitnir-minimap-functions').  Each is the one hover-time Lisp call:
;; - `dwell': the peek, a child frame beside the minimap on the same buffer (Emacs draws its text), the row's lines
;;   with a header "Line N · definition   ↵ jump"; RET or a click jumps there, Esc or the pointer leaving closes it;
;; - `dwell-marks': the problems card in its place, the diagnostics of the section (the innermost fold range) around
;;   the row, with their counts;
;; - `dwell-label': the section's description, spoken on the echo line (`minimap-describe' at point does the same).
;; The visited trail (M4): the line model keeps the last 64 lines visited (`nidhogg-lines-trail-note'), noted after
;; `drgnx-minimap-trail-dwell' seconds idle and on every jump (xref, the next-mark keys, the peek); the minimap draws
;; the last `drgnx-minimap-trail-length' as fading bars (`:trail' in its spec).  A jump also flashes its row
;; (`glitnir-minimap-flash').  Nothing here runs per scroll, per command or per pointer move: the pointer's leaving is
;; polled only while a card is shown.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-setting)
(require 'drgnx-timer)
(require 'drgnx-ruler)
(require 'drgnx-marks)
(require 'drgnx-pixels)

(declare-function drgnx-fold-ranges "drgnx-fold" (&optional beg end))
(declare-function drgnx-minimap--file "drgnx-minimap" (buffer))
(declare-function drgnx-minimap--setting-changed "drgnx-minimap" (&rest _))
(declare-function drgnx-face-glyph "drgnx-ui-kit" (name &optional frame))
(declare-function drgnx-look-chrome-current "drgnx-look" ())
(declare-function flymake-diagnostics "flymake" (&optional beg end))
(declare-function flymake-diagnostic-beg "flymake" (diag))
(declare-function flymake-diagnostic-type "flymake" (diag))
(declare-function flymake-diagnostic-text "flymake" (diag))
(declare-function glitnir-minimap-flash "nhwlterm.c" (window pos))
(declare-function nidhogg-lines-counts "nidhogg-lines.c" (buffer beg end))
(declare-function nidhogg-lines-describe "nidhogg-lines.c" (&optional buffer))
(declare-function nidhogg-lines-sections "nidhogg-lines.c" (&optional buffer beg end))
(declare-function nidhogg-lines-trail-note "nidhogg-lines.c" (buffer pos))
(declare-function nidhogg-lines-trail-clear "nidhogg-lines.c" (buffer))
(declare-function nidhogg-view-minimap "nidhogg-views" (what file &optional layer line))
(defvar drgnx-minimap-layer)
(defvar flymake-mode)
(defvar glitnir-minimap-functions)

(defun drgnx-minimap-peek--respec (&rest _)
  "A trail setting changed: every minimap's spec again, now."
  (when (fboundp 'drgnx-minimap--setting-changed) (drgnx-minimap--setting-changed)))

(drgnx-defsetting drgnx-minimap-peek t
  "Non-nil: resting 300 ms on a minimap row opens a peek beside the minimap, the real lines there at full size."
  :type 'boolean :group 'drgnx-minimap :scope 'global)

(drgnx-defsetting drgnx-minimap-peek-lines 6
  "How many lines the minimap's peek shows."
  :type 'natnum :group 'drgnx-minimap :scope 'global)

(drgnx-defsetting drgnx-minimap-trail t
  "Non-nil: the places you stayed or jumped to show as fading bars at the minimap's left edge (the visited trail)."
  :type 'boolean :group 'drgnx-minimap :scope 'global :apply #'drgnx-minimap-peek--respec)

(drgnx-defsetting drgnx-minimap-trail-dwell 2
  "Seconds point rests on a line, Emacs idle, before the line joins the visited trail."
  :type 'number :group 'drgnx-minimap :scope 'global :apply #'drgnx-minimap-peek--restart)

(drgnx-defsetting drgnx-minimap-trail-length 20
  "How many visits the minimap's trail shows, 1 to 64."
  :type 'natnum :group 'drgnx-minimap :scope 'global :apply #'drgnx-minimap-peek--respec)

(defface drgnx-minimap-peek-header '((t :inherit (drgnx-ui-caption drgnx-text-muted)))
  "The header line of the minimap's peek and problems card."
  :group 'drgnx-minimap)

;;;; The trail (M4)

(defun drgnx-minimap--model-p (&optional buffer)
  "Whether BUFFER (default current) has a line model."
  (and (fboundp 'nidhogg-lines-describe) (nidhogg-lines-describe buffer)))

(defun drgnx-minimap-trail-note (&optional pos)
  "Note a visit to POS (default point) on the current buffer's trail, when it has a line model and the trail is on."
  (when (and drgnx-minimap-trail (drgnx-minimap--model-p))
    (nidhogg-lines-trail-note nil (or pos (point)))))

(defun drgnx-minimap--trail-idle ()
  "The idle timer's step: point rested `drgnx-minimap-trail-dwell' seconds; note its line in the selected window."
  (with-current-buffer (window-buffer (selected-window))
    (drgnx-minimap-trail-note (window-point (selected-window)))))

(defun drgnx-minimap-peek--restart (&rest _)
  "Start the trail's idle timer again at the current `drgnx-minimap-trail-dwell' (when the module runs it)."
  (when (drgnx-timer-active-p 'minimap-trail)
    (drgnx-timer-start 'minimap-trail drgnx-minimap-trail-dwell #'drgnx-minimap--trail-idle :idle t :repeat t
                       :owner 'editor/minimap)))

(defun drgnx-minimap-jumped (&optional window pos)
  "A jump landed at POS (default point) in WINDOW (default selected): note it on the trail and flash its row."
  (let ((w (or window (selected-window))))
    (with-current-buffer (window-buffer w)
      (let ((p (or pos (window-point w))))
        (drgnx-minimap-trail-note p)
        (when (fboundp 'glitnir-minimap-flash)
          (glitnir-minimap-flash w p))))))

(defun drgnx-minimap--after-xref ()
  "`xref-after-jump-hook': the jump joins the trail and flashes."
  (drgnx-minimap-jumped))

(defun drgnx-minimap--after-mark-jump (pos)
  "`drgnx-marks-jump-functions': a next-mark key landed at POS."
  (drgnx-minimap-jumped nil pos))

(defun drgnx-minimap-trail-clear ()
  "Clear this buffer's visited trail on the minimap."
  (interactive)
  (when (drgnx-minimap--model-p)
    (nidhogg-lines-trail-clear nil)
    (force-window-update (current-buffer)))
  (message "Visited trail cleared"))

;;;; Sections and describe (A2)

(defun drgnx-minimap--section (pos)
  "The section around POS: (BEG END NAME), the innermost fold range holding it, named by its first line, else the
MARK section it is in, else the whole buffer."
  (save-excursion
    (let* ((ranges (and (fboundp 'drgnx-fold-ranges) (ignore-errors (drgnx-fold-ranges pos (1+ pos)))))
           (r (car (last (seq-filter (lambda (r) (and (<= (nth 0 r) pos) (< pos (nth 1 r)))) ranges)))))
      (if r
          (list (nth 0 r) (nth 1 r)
                (progn (goto-char (nth 0 r))
                       (truncate-string-to-width
                        (string-trim (buffer-substring-no-properties (line-beginning-position) (line-end-position)))
                        60 nil nil "…")))
        (let* ((secs (and (drgnx-minimap--model-p) (nidhogg-lines-sections nil)))
               (before (seq-filter (lambda (s) (<= (car s) pos)) secs))
               (s (car (last before)))
               (next (seq-find (lambda (n) (> (car n) pos)) secs)))
          (if s (list (car s) (if next (car next) (point-max)) (cdr s))
            (list (point-min) (point-max) (buffer-name))))))))

(defun drgnx-minimap--count-words (beg end)
  "The marks from BEG to END in words: \"2 errors, 1 warning\", nil when there are none."
  (when (drgnx-minimap--model-p)
    (let ((c (nidhogg-lines-counts nil beg end)) out)
      (cl-loop for kind in drgnx-ruler-kinds for i from 0
               for n = (aref c i)
               when (> n 0)
               do (push (format "%d %s%s" n (alist-get kind drgnx-marks--names "mark") (if (= n 1) "" "s")) out))
      (and out (string-join (nreverse out) ", ")))))

(defun drgnx-minimap--heat-words (pos)
  "The heat layer's value at POS's line in words (\"blame: 2 days ago · …\"), or nil."
  (when-let* ((layer (bound-and-true-p drgnx-minimap-layer))
              ((fboundp 'nidhogg-view-minimap))
              ((fboundp 'drgnx-minimap--file))
              (file (drgnx-minimap--file (current-buffer)))
              (heat (ignore-errors (nidhogg-view-minimap 'heat-at file (symbol-name layer)
                                                         (line-number-at-pos pos t)))))
    (format "%s: %s" layer (or (nth 1 heat) (format "%d%%" (round (car heat) 10))))))

(defun drgnx-minimap-description (pos)
  "The words `minimap-describe' speaks for POS: its section, the section's lines, its marks and the heat there."
  (pcase-let ((`(,beg ,end ,name) (drgnx-minimap--section pos)))
    (string-join
     (delq nil (list (format "%s, lines %d to %d" name (line-number-at-pos beg t)
                             (line-number-at-pos (max beg (1- end)) t))
                     (or (drgnx-minimap--count-words beg end) "no marks")
                     (drgnx-minimap--heat-words pos)))
     "; ")))

(defun drgnx-minimap-describe (&optional pos)
  "Say where POS (default point) is: the section around it, its marks and the minimap's heat value there."
  (interactive)
  (message "%s" (drgnx-minimap-description (or pos (point)))))

;;;; The cards: the peek (M2) and the problems card (X8)

(defvar drgnx-minimap--card nil
  "The card shown: [FRAME KIND WINDOW POS] (KIND `peek' or `problems', WINDOW the editor's), or nil.")
(defvar drgnx-minimap--card-frame nil "The card's child frame, kept for reuse (one for the session).")
(defvar drgnx-minimap--problems-buffer " *drgnx-minimap-problems*" "The problems card's buffer's name.")

(defun drgnx-minimap--card-params (parent)
  "The card's frame parameters under PARENT: no focus, the popups' chrome, out of the minimap and the ruler."
  `((parent-frame . ,parent) (minibuffer . nil) (name . "drgnx-minimap-card") (drgnx-minimap-exclude . t)
    (undecorated . t) (no-accept-focus . t) (no-focus-on-map . t) (no-other-frame . t) (skip-taskbar . t)
    (unsplittable . t) (desktop-dont-save . t) (border-width . 0) (internal-border-width . 0)
    (child-frame-border-width . 1) (menu-bar-lines . 0) (tool-bar-lines . 0) (tab-bar-lines . 0)
    (left-fringe . 0) (right-fringe . 0) (vertical-scroll-bars) (horizontal-scroll-bars) (cursor-type . nil)
    (visibility . nil)
    ,@(let ((font (frame-parameter parent 'font))) (and font (list (cons 'font font))))
    ,@(and (fboundp 'drgnx-look-chrome-current) (drgnx-look-chrome-current))))

(defun drgnx-minimap--card-frame (parent)
  "The card's frame, a child of PARENT, made or moved there."
  (unless (and (frame-live-p drgnx-minimap--card-frame)
               (eq parent (frame-parent drgnx-minimap--card-frame)))
    (when (frame-live-p drgnx-minimap--card-frame) (delete-frame drgnx-minimap--card-frame t))
    (setq drgnx-minimap--card-frame
          (let ((after-make-frame-functions nil) (before-make-frame-hook nil))
            (make-frame (drgnx-minimap--card-params parent))))
    (let ((w (frame-root-window drgnx-minimap--card-frame)))
      (set-window-parameter w 'drgnx-minimap-exclude t)
      (set-window-dedicated-p w nil)))
  drgnx-minimap--card-frame)

(defun drgnx-minimap--card-place (frame window lines)
  "Put FRAME left of WINDOW's minimap, LINES text lines and a header tall, at the pointer's height (kept inside the
window)."
  (let* ((parent (window-frame window))
         (edges (window-inside-pixel-edges window))
         (mm (drgnx-px (or (plist-get (window-parameter window 'glitnir-minimap) :width) 120) parent))
         (lh (with-selected-window window (default-line-height)))
         (h (* (1+ lines) lh))
         (w (min (* 90 (frame-char-width parent)) (max 200 (round (* 0.6 (- (nth 2 edges) (nth 0 edges) mm))))))
         (mouse (mouse-pixel-position))
         (y (if (and (eq (car mouse) parent) (cddr mouse)) (- (cddr mouse) (/ h 2)) (nth 1 edges)))
         (y (max (nth 1 edges) (min y (- (nth 3 edges) h)))))
    (set-frame-size frame w h t)
    (set-frame-position frame (max (nth 0 edges) (- (nth 2 edges) mm w (drgnx-px 8 parent))) y)))

(defun drgnx-minimap--header (text)
  "A card's header line: TEXT, then `↵ jump' at the right."
  (concat (propertize (concat " " text) 'face 'drgnx-minimap-peek-header)
          (propertize " " 'display '(space :align-to (- right 8)) 'face 'drgnx-minimap-peek-header)
          (propertize "↵ jump " 'face 'drgnx-minimap-peek-header)))

(defun drgnx-minimap--show-card (kind window pos lines header buffer start)
  "Show the card of KIND for POS of editor WINDOW: BUFFER from START, LINES tall, HEADER on top."
  (let* ((frame (drgnx-minimap--card-frame (window-frame window)))
         (cw (frame-root-window frame)))
    (set-window-buffer cw buffer)
    (set-window-start cw start t)
    (set-window-parameter cw 'header-line-format (drgnx-minimap--header header))
    (set-window-parameter cw 'mode-line-format 'none)
    (drgnx-minimap--card-place frame window lines)
    (unless (frame-visible-p frame) (make-frame-visible frame))
    (setq drgnx-minimap--card (vector frame kind window pos))
    (set-transient-map drgnx-minimap-card-map #'drgnx-minimap--card-keep-p #'drgnx-minimap-card-hide)
    (drgnx-timer-start 'minimap-card-away 0.15 #'drgnx-minimap--card-away :repeat 0.15 :owner 'editor/minimap)
    frame))

(defun drgnx-minimap--card-keep-p ()
  "Keep the card's keys while the card shows and the key was one of its own."
  (and drgnx-minimap--card (memq this-command '(drgnx-minimap-card-jump drgnx-minimap-card-click))))

(defun drgnx-minimap-card-hide ()
  "Hide the minimap's card."
  (interactive)
  (drgnx-timer-cancel 'minimap-card-away)
  (when (and drgnx-minimap--card (frame-live-p (aref drgnx-minimap--card 0)))
    (make-frame-invisible (aref drgnx-minimap--card 0)))
  (setq drgnx-minimap--card nil))

(defun drgnx-minimap--card-away ()
  "The poll while a card shows: hide it once the pointer is over neither the card nor its window's minimap, or the
window is gone."
  (let ((card drgnx-minimap--card))
    (if (not (and card (window-live-p (aref card 2)) (frame-live-p (aref card 0))))
        (drgnx-minimap-card-hide)
      (let* ((mouse (mouse-pixel-position)) (f (car mouse)) (x (cadr mouse)) (y (cddr mouse))
             (w (aref card 2)) (edges (window-inside-pixel-edges w))
             (mm (drgnx-px (or (plist-get (window-parameter w 'glitnir-minimap) :width) 120) (window-frame w))))
        (unless (or (eq f (aref card 0))
                    (and (eq f (window-frame w)) x y
                         (<= (- (nth 2 edges) mm) x (nth 2 edges)) (<= (nth 1 edges) y (nth 3 edges))))
          (drgnx-minimap-card-hide))))))

(defun drgnx-minimap--jump (window pos)
  "Select editor WINDOW and go to POS there, as a jump: the mark pushed, the line centred, the trail noted, the row
flashed."
  (when (window-live-p window)
    (select-window window)
    (push-mark nil t)
    (goto-char pos)
    (recenter)
    (drgnx-minimap-jumped window pos)))

(defun drgnx-minimap-card-jump ()
  "Jump to the card's place: the peek's row, or the problem on the card's line at point."
  (interactive)
  (when-let* ((card drgnx-minimap--card))
    (let ((w (aref card 2))
          (pos (if (eq (aref card 1) 'problems)
                   (with-current-buffer (window-buffer (frame-root-window (aref card 0)))
                     (or (get-text-property (window-point (frame-root-window (aref card 0))) 'drgnx-minimap-pos)
                         (aref card 3)))
                 (aref card 3))))
      (drgnx-minimap-card-hide)
      (drgnx-minimap--jump w pos))))

(defun drgnx-minimap-card-click (event)
  "A click on the card (EVENT): jump to the line clicked (a problem's place on the problems card)."
  (interactive "e")
  (let* ((card drgnx-minimap--card) (posn (event-start event)) (cw (posn-window posn)))
    (if (not (and card (windowp cw) (eq (window-frame cw) (aref card 0))))
        (drgnx-minimap-card-hide)
      (let ((pos (if (eq (aref card 1) 'problems)
                     (or (and (posn-point posn)
                              (get-text-property (posn-point posn) 'drgnx-minimap-pos (window-buffer cw)))
                         (aref card 3))
                   (or (posn-point posn) (aref card 3))))
            (w (aref card 2)))
        (drgnx-minimap-card-hide)
        (drgnx-minimap--jump w pos)))))

(defvar drgnx-minimap-card-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET") #'drgnx-minimap-card-jump)
    (define-key m [return] #'drgnx-minimap-card-jump)
    (define-key m [escape] #'drgnx-minimap-card-hide)
    (define-key m [down-mouse-1] #'ignore)
    (define-key m [mouse-1] #'drgnx-minimap-card-click)
    m)
  "The keys while a minimap card shows: RET or a click jumps, Esc closes; any other key closes it and does its own.")

(defun drgnx-minimap-peek-show (window pos)
  "Open the peek of POS beside WINDOW's minimap: `drgnx-minimap-peek-lines' lines around it, the header naming the
line and the definition it is in."
  (let* ((buffer (window-buffer window)) (n (max 1 drgnx-minimap-peek-lines))
         start header)
    (with-current-buffer buffer
      (save-excursion
        (goto-char pos)
        (let ((line (line-number-at-pos pos t)) (sec (nth 2 (drgnx-minimap--section pos))))
          (forward-line (- (/ (1- n) 2)))
          (setq start (point)
                header (if (equal sec (buffer-name)) (format "Line %d" line) (format "Line %d · %s" line sec))))))
    (drgnx-minimap--show-card 'peek window pos n header buffer start)))

(defun drgnx-minimap--diagnostics (beg end)
  "Flymake's diagnostics from BEG to END, in buffer order, or nil."
  (and (bound-and-true-p flymake-mode)
       (sort (flymake-diagnostics beg end) (lambda (a b) (< (flymake-diagnostic-beg a) (flymake-diagnostic-beg b))))))

(defun drgnx-minimap--diag-kind (d)
  "Diagnostic D's kind: `error', `warning' or `info'."
  (pcase (flymake-diagnostic-type d)
    ((or :error 'eglot-error) 'error)
    ((or :warning 'eglot-warning) 'warning)
    (_ (let ((cat (and (symbolp (flymake-diagnostic-type d)) (get (flymake-diagnostic-type d) 'flymake-category))))
         (pcase cat ('flymake-error 'error) ('flymake-warning 'warning) (_ 'info))))))

(defun drgnx-minimap-problems-text (diags frame)
  "The problems card's text for DIAGS on FRAME: a line each, its icon, message and line, `drgnx-minimap-pos' its
place; the header's counts as the second value: (TEXT . COUNTS)."
  (let ((counts (list (cons 'error 0) (cons 'warning 0) (cons 'info 0))) lines)
    (dolist (d diags)
      (let* ((kind (drgnx-minimap--diag-kind d)) (p (flymake-diagnostic-beg d))
             (icon (or (drgnx-face-glyph (pcase kind ('error 'fail) ('warning 'warn) (_ 'info)) frame) "•")))
        (cl-incf (alist-get kind counts))
        (push (propertize (concat " " (propertize icon 'face (pcase kind ('error 'error) ('warning 'warning) (_ 'success)))
                                  " " (car (split-string (flymake-diagnostic-text d) "\n"))
                                  (propertize (format "  line %d" (line-number-at-pos p t)) 'face 'drgnx-text-muted)
                                  "\n")
                          'drgnx-minimap-pos p 'help-echo "RET or click: go there")
              lines)))
    (cons (apply #'concat (nreverse lines)) counts)))

(defun drgnx-minimap-problems-show (window pos)
  "Open the problems card for the section around POS beside WINDOW's minimap; nothing when it holds no diagnostics."
  (let* ((buffer (window-buffer window))
         (section (with-current-buffer buffer (drgnx-minimap--section pos)))
         (diags (with-current-buffer buffer (drgnx-minimap--diagnostics (nth 0 section) (nth 1 section)))))
    (when diags
      (let* ((made (with-current-buffer buffer (drgnx-minimap-problems-text diags (window-frame window))))
             (counts (cdr made))
             (cb (get-buffer-create drgnx-minimap--problems-buffer)))
        (with-current-buffer cb
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert (car made))
            (goto-char (point-min)))
          (setq-local cursor-type nil truncate-lines t buffer-read-only t)
          (buffer-disable-undo))
        (drgnx-minimap--show-card
         'problems window pos (min 8 (length diags))
         (format "%s · %s" (nth 2 section)
                 (string-join (delq nil (mapcar (lambda (c) (and (> (cdr c) 0)
                                                                 (format "%d %s%s" (cdr c) (car c)
                                                                         (if (= (cdr c) 1) "" "s"))))
                                                counts))
                              ", "))
         cb 1)))))

;;;; Nidhogg's events

(defun drgnx-minimap--event (kind window pos)
  "`glitnir-minimap-functions': KIND at POS of WINDOW's minimap (see `glitnir-minimap-functions')."
  (when (window-live-p window)
    (pcase kind
      ('dwell (when drgnx-minimap-peek (drgnx-minimap-peek-show window pos)))
      ('dwell-marks (or (drgnx-minimap-problems-show window pos)
                        (when drgnx-minimap-peek (drgnx-minimap-peek-show window pos))))
      ('dwell-label (with-current-buffer (window-buffer window) (drgnx-minimap-describe pos)))
      ((or 'click 'drag) (drgnx-minimap-card-hide)))))

;;;; Setup

(defun drgnx-minimap-peek-on ()
  "The module's setup of this file: the events, the trail's idle timer and its jump hooks."
  (add-hook 'glitnir-minimap-functions #'drgnx-minimap--event)
  (add-hook 'xref-after-jump-hook #'drgnx-minimap--after-xref)
  (add-hook 'drgnx-marks-jump-functions #'drgnx-minimap--after-mark-jump)
  (drgnx-timer-start 'minimap-trail drgnx-minimap-trail-dwell #'drgnx-minimap--trail-idle :idle t :repeat t
                     :owner 'editor/minimap))

(defun drgnx-minimap-peek-off ()
  "Undo `drgnx-minimap-peek-on': the hooks and the timers gone, the card's frame and buffer deleted."
  (remove-hook 'glitnir-minimap-functions #'drgnx-minimap--event)
  (remove-hook 'xref-after-jump-hook #'drgnx-minimap--after-xref)
  (remove-hook 'drgnx-marks-jump-functions #'drgnx-minimap--after-mark-jump)
  (drgnx-timer-cancel 'minimap-trail)
  (drgnx-minimap-card-hide)
  (when (frame-live-p drgnx-minimap--card-frame) (delete-frame drgnx-minimap--card-frame t))
  (setq drgnx-minimap--card-frame nil)
  (when (get-buffer drgnx-minimap--problems-buffer) (kill-buffer drgnx-minimap--problems-buffer)))

(provide 'drgnx-minimap-peek)
;;; drgnx-minimap-peek.el ends here
