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
bar's height at the run's scale (`drgnx-statusbar--row'), short only by the pixel an odd difference leaves."
  (skip-unless (display-graphic-p))
  (drgnx-ui-look-box--with (propertize "Ln 1, Col 1" 'face (drgnx-statusbar--row-face (selected-window)))
    (pcase-let ((`(,height ,_text ,_box ,leftover) (drgnx-statusbar--row (selected-window))))
      (should (equal (with-current-buffer drgnx-ui-look-box--buffer
                       (save-excursion (goto-char (point-min)) (forward-line 1) (line-pixel-height)))
                     (- height leftover))))))

(provide 'look-box-widths-gui-test)
;;; look-box-widths-gui-test.el ends here
