;;; look-box-widths-gui-test.el --- GUI tests: boxes made in frame pixels are drawn at those widths (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: every width is read from what is drawn, after `drgnx-test-wait-presented'.  Nidhogg's shells take a
;; face's `:box' line widths in logical pixels and draw them at the display scale, so a box width the look makes in
;; frame pixels goes through `drgnx-pixels-box-width'; these rows hold each such box to the width it was made at, at
;; the run's scale (DRGNX_UI_SCALE): a box given frame pixels as they are is drawn twice as wide at 2.

(require 'ert)
(require 'cl-lib)
(require 'drgnx-look-gui-fixture (expand-file-name "../fixtures/look-gui-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-ui-look-box--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-look-box--repo)))
(require 'drgnx)
(require 'drgnx-color)
(require 'drgnx-ui-kit)
(require 'drgnx-wb)
(load (expand-file-name "themes/drgnx-theme-gen" drgnx-ui-look-box--repo) nil t)
(load (expand-file-name "modules/ui/drgnx-statusbar" drgnx-ui-look-box--repo) nil t)

(declare-function drgnx-statusbar--row "drgnx-statusbar" (w))
(declare-function drgnx-statusbar--row-face "drgnx-statusbar" (w))
(declare-function drgnx-statusbar--lead "drgnx-statusbar" (w pad))
(defvar drgnx-statusbar--bar-face)

(defconst drgnx-ui-look-box--buffer " *look-box-widths*")

(defmacro drgnx-ui-look-box--with (text &rest body)
  "BODY with TEXT (a string with its faces) as the only line of a buffer shown in the selected window of a bare
frame, dark theme, no cursor.  Everything undone after."
  (declare (indent 1))
  `(let ((buf (get-buffer-create drgnx-ui-look-box--buffer)))
     (drgnx-uitest-bare-frame)
     (delete-other-windows)
     (mapc #'disable-theme custom-enabled-themes)
     (load-theme 'drgnx-dark t)
     (unwind-protect
         (progn
           (with-current-buffer buf
             (erase-buffer) (insert "x\n" ,text "\n") (setq-local cursor-type nil) (goto-char (point-min)))
           (set-window-buffer (selected-window) buf)
           (drgnx-test-wait-presented)
           ,@body)
       (mapc #'disable-theme custom-enabled-themes)
       (kill-buffer buf))))

(defun drgnx-ui-look-box--rgb (color)
  "COLOR as (R G B), 8 bits."
  (mapcar (lambda (c) (round (/ c 257.0))) (color-values color)))

(defun drgnx-ui-look-box--ring (color)
  "How many device pixels of COLOR the box on the buffer's second line draws at its left edge, across the line's
middle: the drawn ring's width.  Read from the root frame's picture, from the first character's left edge inward."
  (let* ((s (drgnx-uitest-device-scale (selected-frame))) (origin (drgnx-uitest--text-origin (selected-window)))
         (pos (with-current-buffer drgnx-ui-look-box--buffer (save-excursion (goto-char (point-min)) (forward-line 1) (point))))
         (xy (posn-x-y (posn-at-point pos)))
         (y (round (* s (+ (cdr origin) (cdr xy) (/ (with-current-buffer drgnx-ui-look-box--buffer
                                                      (save-excursion (goto-char pos) (line-pixel-height)))
                                                    2)))))
         (x0 (round (* s (+ (car origin) (car xy)))))
         (want (drgnx-ui-look-box--rgb color))
         (snap (drgnx-uitest-snapshot)))
    (cl-flet ((ring-p (x) (cl-every (lambda (a b) (<= (abs (- a b)) 24)) (cdr (drgnx-uitest-pixel snap x y)) want)))
      (let ((x x0))
        (while (and (< x (+ x0 40)) (not (ring-p x))) (setq x (1+ x)))   ; to the ring
        (let ((start x))
          (while (and (< x (+ x0 40)) (ring-p x)) (setq x (1+ x)))
          (- x start))))))

(defun drgnx-ui-look-box--focus-colour ()
  (let ((c (plist-get (face-attribute 'drgnx-focus :box nil t) :color))) (and (stringp c) c)))

(drgnx-look-gui-deftest drgnx-ui-look-box/a-focused-button-ring-is-two-logical-pixels ()
  "Pattern D, look.css `.btn.focus': the focus ring of a button (`drgnx-ui-button-focus-box') is drawn 2 logical
pixels wide, `drgnx-px-line' 2 device pixels at the run's scale."
  (skip-unless (and (display-graphic-p) (featurep 'glitnir)))
  (drgnx-ui-look-box--with (propertize "        " 'face `(:background ,(face-background 'default nil t)
                                                                      :box ,(drgnx-ui-button-focus-box)))
    (should (drgnx-ui-look-box--focus-colour))
    (should (equal (drgnx-ui-look-box--ring (drgnx-ui-look-box--focus-colour)) (drgnx-px-line 2)))))

(drgnx-look-gui-deftest drgnx-ui-look-box/a-focused-row-ring-is-one-logical-pixel ()
  "Pattern D, window-dark.html `.row.focus': a row's ring (`drgnx-wb-row-box' with a colour) is drawn 1 logical pixel
wide, `drgnx-px-line' 1 device pixels at the run's scale."
  (skip-unless (and (display-graphic-p) (featurep 'glitnir)))
  (drgnx-ui-look-box--with (propertize "        " 'face `(:background ,(face-background 'default nil t)
                                                                      :box ,(drgnx-wb-row-box (drgnx-ui-look-box--focus-colour))))
    (should (drgnx-ui-look-box--focus-colour))
    (should (equal (drgnx-ui-look-box--ring (drgnx-ui-look-box--focus-colour)) (drgnx-px-line 1)))))

(drgnx-look-gui-deftest drgnx-ui-look-box/the-status-bar-row-is-its-height ()
  "Pattern D, window-dark.html `.status': text in the bar's faces (`drgnx-statusbar--row-face') makes a row the
bar's height at the run's scale (`drgnx-statusbar--row'), short only by the LEFTOVER pixels the box cannot make (the
lead takes them)."
  (skip-unless (display-graphic-p))
  (drgnx-ui-look-box--with (propertize "Ln 1, Col 1" 'face (drgnx-statusbar--row-face (selected-window)))
    (pcase-let ((`(,height ,_text ,_box ,leftover) (drgnx-statusbar--row (selected-window))))
      (should (equal (with-current-buffer drgnx-ui-look-box--buffer
                       (save-excursion (goto-char (point-min)) (forward-line 1) (line-pixel-height)))
                     (- height leftover))))))

(defun drgnx-ui-look-box--ink-rows (snap x y0 y1 ink bg)
  "The device rows from Y0 below Y1 where column X of SNAP is nearer the colour INK than BG (each an (R G B)), as
\(FIRST . LAST), or nil."
  (let (first last)
    (cl-flet ((dist (a b) (apply #'+ (cl-mapcar (lambda (p q) (abs (- p q))) a b))))
      (cl-loop for y from y0 below y1
               for px = (cdr (drgnx-uitest-pixel snap x y))
               when (< (dist px ink) (dist px bg))
               do (setq first (or first y) last y)))
    (and first (cons first last))))

(drgnx-look-gui-deftest drgnx-ui-look-box/the-status-bar-text-sits-in-the-middle ()
  "Pattern D, window-dark.html `.status': the bar's text is in the middle of its row.  The row is the box above and
below the font and its lead's LEFTOVER pixels (`drgnx-statusbar--row', up to 3 at 2 where the box cannot draw every
width); half of them go above the text and half below, so the font's box is as far from the row's top as from its
bottom, within a pixel.  The baseline is read from what is drawn: the foot of an H's stem.  The row is made 18 pixels
taller than the font (a box of 9 above and below), which a scale of 2 cannot draw: it draws 8, and 2 pixels are left."
  (skip-unless (display-graphic-p))
  (cl-letf* ((height (symbol-function 'drgnx-statusbar--row-height))
             ((symbol-function 'drgnx-statusbar--row-height)
              (lambda (frame)
                (ignore height)
                (+ (car (drgnx-pixels-font-metrics drgnx-statusbar--bar-face frame)) 18))))
    (progn
      (drgnx-ui-look-box--with (concat (drgnx-statusbar--lead (selected-window) 4)
                                       (propertize "HHHH" 'face (cons `(:foreground ,(face-foreground 'error nil t))
                                                                      (drgnx-statusbar--row-face (selected-window)))))
        ;; the colours under the theme the macro loads
        (pcase-let* ((mark (drgnx-ui-look-box--rgb (face-foreground 'error nil t)))
                     (bg (drgnx-ui-look-box--rgb (face-background drgnx-statusbar--bar-face nil t)))
                     (w (selected-window))
                     (`(,_height ,_text ,box ,leftover) (drgnx-statusbar--row w))
                     (`(,asc . ,desc) (drgnx-pixels-font-extent drgnx-statusbar--bar-face (window-frame w)))
                     (s (drgnx-uitest-device-scale (selected-frame)))
                     (origin (drgnx-uitest--text-origin w))
                     (pos (with-current-buffer drgnx-ui-look-box--buffer
                            (save-excursion (goto-char (point-min)) (forward-line 1) (1+ (point)))))   ; the first H
                     (xy (posn-x-y (posn-at-point pos w)))
                     (top (round (* s (+ (cdr origin) (cdr xy)))))
                     (rowh (with-current-buffer drgnx-ui-look-box--buffer (save-excursion (goto-char pos) (line-pixel-height))))
                     (x0 (round (* s (+ (car origin) (car xy)))))
                     (snap (drgnx-uitest-snapshot))
                     ;; the H's left stem: the first column from the glyph's left edge with ink at the row's middle
                     (stem (cl-loop for x from x0 below (+ x0 40)
                                    when (drgnx-ui-look-box--ink-rows snap x (+ top (/ rowh 2)) (+ top (/ rowh 2) 1) mark bg)
                                    return x))
                     (ink (and stem (drgnx-ui-look-box--ink-rows snap stem top (+ top rowh) mark bg)))
                     (baseline (and ink (1+ (cdr ink))))
                     (above (and ink (- baseline top asc box)))
                     (below (and ink (- (+ top rowh) baseline desc box))))
          ;; the premise at 2: pixels the box leaves, so where they go shows
          (when (>= (frame-scale-factor) 2) (should (>= leftover 2)))
          (should ink)
          (unless (<= (abs (- above below)) 1)
            (ert-fail (list 'off-centre :above above :below below :leftover leftover :box box :ascent asc :descent desc
                            :top top :rowh rowh :x0 x0 :stem stem :ink ink :mark mark :bg bg
                            :column (cl-loop for y from top below (+ top rowh) by 2
                                             collect (cdr (drgnx-uitest-pixel snap stem y)))))))))))

(provide 'look-box-widths-gui-test)
;;; look-box-widths-gui-test.el ends here
