;;; kit-sheets-gui-test.el --- GUI tests: the kit's screenshot sheets, one row per component (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; Each row `drgnx-kit-sheet/ID' opens Design: Component Catalogue for component ID in the dark, light and high-contrast
;; themes at the three densities, at the session's scale (and 1.25 too at scale 1), and per cell (variant x state)
;; asserts: (a) each pad the expansion gives is drawn exactly its device px wide, and the cell is its pads plus its
;; text; (b) the fill inside the start pad is the state's token (the surface's when the state has no fill); (c) in
;; high contrast, nothing outside the cell's rows is drawn (no shadow).  Pattern D: every pixel is read after
;; `drgnx-test-wait-presented'.  The sheet's picture at the comfortable density is written to the evidence folder
;; (DRGNX_UI_EVIDENCE) as kit-sheet-ID-THEME-sSCALE.png, and at scale 1 as kit-sheet-ID-THEME.png, which
;; `bin/drgnx design --shots' copies to docs/design/img/kit-ID-THEME.png.  docs/develop/design-system.md.

(require 'ert)
(require 'cl-lib)
(require 'drgnx-look-gui-fixture (expand-file-name "../fixtures/look-gui-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-kit-sheet--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness" "themes"))
  (add-to-list 'load-path (expand-file-name d drgnx-kit-sheet--repo)))
(add-to-list 'custom-theme-load-path (expand-file-name "themes" drgnx-kit-sheet--repo))
(require 'drgnx)
(require 'drgnx-ui-kit)
(require 'drgnx-theme-gen)
(load (expand-file-name "modules/ui/drgnx-look-density" drgnx-kit-sheet--repo) nil t)
(load (expand-file-name "modules/ui/drgnx-kit-catalogue" drgnx-kit-sheet--repo) nil t)

(defvar drgnx-look-density)
(declare-function drgnx-kit-catalogue-open "drgnx-kit-catalogue" (&optional component theme density scale))
(declare-function drgnx-kit-catalogue-cells "drgnx-kit-catalogue")

(defconst drgnx-kit-sheet-themes '((dark . drgnx-dark) (light . drgnx-light) (hc . drgnx-high-contrast))
  "The sheets' themes: (VARIANT . THEME).")

(defun drgnx-kit-sheet--rgb (hex)
  "HEX as the (A R G B) a snapshot gives."
  (cons 255 (mapcar (lambda (i) (string-to-number (substring hex i (+ i 2)) 16)) '(1 3 5))))

(defun drgnx-kit-sheet--x (pos s edges)
  "The device x of POS's left edge in the selected window (S the device scale, EDGES its inside pixel edges)."
  (round (* s (+ (car edges) (car (posn-x-y (posn-at-point pos)))))))

(defun drgnx-kit-sheet--props (id variants state)
  "The props the catalogue gives a cell of ID with VARIANTS (values, in axis order) in STATE."
  (drgnx-kit-catalogue--props id (cl-mapcar #'cons (mapcar #'car (plist-get (drgnx-ui-kit-component id) :variants)) variants)
                              state))

(defun drgnx-kit-sheet--check-cells (id variant scale)
  "Check every cell of the catalogue in the selected window, drawn for component ID at SCALE in theme VARIANT.
Returns the number of cells checked."
  (let* ((frame (selected-frame)) (s (drgnx-uitest-device-scale frame))
         (cells (drgnx-kit-catalogue-cells)) (snap nil) (n 0))
    (pcase-dolist (`(,_ ,variants ,state ,beg ,end) cells)
      (unless (and snap (pos-visible-in-window-p beg) (pos-visible-in-window-p end))
        (set-window-start nil (save-excursion (goto-char beg) (forward-line -1) (point)))
        (drgnx-test-wait-presented)
        (setq snap (drgnx-uitest-snapshot)))
      (let* ((edges (window-inside-pixel-edges))
             (what (list id variants state variant scale))
             (e (drgnx-ui-kit-expand id (drgnx-kit-sheet--props id variants state) scale nil))
             (spaces (append (plist-get e :spaces) nil))
             (y (round (* s (+ (cadr edges) (cdr (posn-x-y (posn-at-point beg))) (/ (save-excursion (goto-char beg) (line-pixel-height)) 2.0))))))
        ;; (a) each pad its device px; the cell is its pads and its text
        (dolist (sp spaces)
          (let ((at (+ beg (aref sp 0))))
            (should (equal (list what 'pad (aref sp 0) (aref sp 1))
                           (list what 'pad (aref sp 0) (- (drgnx-kit-sheet--x (1+ at) s edges)
                                                          (drgnx-kit-sheet--x at s edges)))))))
        (let ((pads (apply #'+ (mapcar (lambda (sp) (aref sp 1)) spaces)))
              (text (round (* s (string-pixel-width (buffer-substring (1+ beg) (1- end)))))))
          (should (equal (list what 'width (+ pads text))
                         (list what 'width (- (drgnx-kit-sheet--x end s edges) (drgnx-kit-sheet--x beg s edges))))))
        ;; (b) the fill inside the start pad, halfway in (clear of a focus ring and of a rounded corner)
        (let* ((token (or (plist-get (drgnx-ui-kit-state state) :fill) 'editor))
               (x (+ (drgnx-kit-sheet--x beg s edges) (/ (aref (car spaces) 1) 2))))
          (let* ((want (drgnx-kit-sheet--rgb (drgnx-look-token token variant)))
                 (got (drgnx-uitest-pixel snap x y))
                 ;; on a mismatch, what is drawn there
                 (at (unless (equal want got)
                       (let ((p (posn-point (posn-at-x-y (- (round (/ x s)) (car edges)) (- (round (/ y s)) (cadr edges))))))
                         (list :at p :beg beg :char (and p (char-after p)) :start (window-start))))))
            (should (equal (list what 'fill token want nil) (list what 'fill token got at)))))
        ;; (c) high contrast: no shadow, so the column right of the cell is the surface
        (when (eq variant 'hc)
          (let ((x (+ (drgnx-kit-sheet--x end s edges) (round (* s 4)))))
            (when (< x (round (* s (nth 2 edges))))
              (should (equal (list what 'no-shadow (drgnx-kit-sheet--rgb (drgnx-look-token 'editor variant)))
                             (list what 'no-shadow (drgnx-uitest-pixel snap x y)))))))
        (cl-incf n)))
    n))

(defun drgnx-kit-sheet-check (id)
  "Component ID's sheet: the catalogue for ID in each theme of `drgnx-kit-sheet-themes' at each density, at the
session's scale (and 1.25 at scale 1); every cell checked (`drgnx-kit-sheet--check-cells').  The comfortable sheet's
picture goes to the evidence folder.  The caller skips a session with no graphical frame."
  (drgnx-uitest-bare-frame)
  (let* ((frame (selected-frame)) (old (window-buffer)) (fs (drgnx-pixels-scale frame))
         (scales (if (= fs 1) (list 1 1.25) (list fs)))
         (evidence (getenv "DRGNX_UI_EVIDENCE")) buf)
    (unwind-protect
        (pcase-dolist (`(,variant . ,theme) drgnx-kit-sheet-themes)
          (dolist (density '(comfortable compact roomy))   ; comfortable first: its picture is kept
            (dolist (scale scales)
              (let ((drgnx-look-density density))
                (setq buf (drgnx-kit-catalogue-open id theme density scale))
                (switch-to-buffer buf)
                (goto-char (point-min))
                (drgnx-test-wait-presented)
                ;; the picture first, so a failing sheet still leaves it
                (when (and evidence (file-directory-p evidence) (eq density 'comfortable) (= scale fs))
                  (let ((root (plist-get (drgnx-uitest-capture (make-temp-file "kit-sheet" t)) :root)))
                    (copy-file root (expand-file-name (format "kit-sheet-%s-%s-s%s.png" id variant fs) evidence) t)
                    (when (= fs 1)
                      (copy-file root (expand-file-name (format "kit-sheet-%s-%s.png" id variant) evidence) t))))
                (should (< 0 (drgnx-kit-sheet--check-cells id variant scale)))))))
      (switch-to-buffer old)
      (when (buffer-live-p buf) (kill-buffer buf))
      (mapc #'disable-theme custom-enabled-themes))))

(drgnx-look-gui-deftest drgnx-kit-sheet/row ()
  "The row's sheet: 3 kinds x 7 states, each pad exact and each state's fill its token, in every theme and density."
  (skip-unless (display-graphic-p))
  (drgnx-kit-sheet-check 'row))

(provide 'kit-sheets-gui-test)
;;; kit-sheets-gui-test.el ends here
