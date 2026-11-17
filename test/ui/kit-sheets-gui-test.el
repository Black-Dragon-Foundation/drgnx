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

(defun drgnx-kit-sheet--whole-p (pos)
  "Non-nil when POS's line, its whole height, is inside the selected window's text area (a tall row at the window's
foot shows only in part)."
  (when-let* ((xy (posn-x-y (posn-at-point pos))))
    (<= (+ (cdr xy) (save-excursion (goto-char pos) (line-pixel-height))) (window-body-height nil t))))

(defvar drgnx-kit-sheet--edges nil
  "Non-nil while a sheet also checks that hovered and selected cells have no edge (`drgnx-kit-sheet/state-table').")

(defun drgnx-kit-sheet--check-bar (what props variant scale snap beg s edges)
  "The progress bar of PROPS drawn at BEG (WHAT the cell, for the failures): its fill, found down the column 1 device
px into it, is VALUE of its width's device px at SCALE, rounded half up, in `progress-fill', and the track follows."
  (let* ((fill (drgnx-kit-sheet--rgb (drgnx-look-token 'progress-fill variant)))
         (track (drgnx-kit-sheet--rgb (drgnx-look-token 'progress-track variant)))
         (want (floor (+ (* (drgnx-px (plist-get props :width) nil scale) (plist-get props :value)) 0.5 1e-9)))
         (x0 (drgnx-kit-sheet--x beg s edges))
         (top (round (* s (+ (cadr edges) (cdr (posn-x-y (posn-at-point beg)))))))
         (h (round (* s (save-excursion (goto-char beg) (line-pixel-height)))))
         (y (cl-loop for y from top below (+ top h) when (equal fill (drgnx-uitest-pixel snap (1+ x0) y)) return y)))
    (should (equal (list what 'bar-drawn t) (list what 'bar-drawn (and y t))))
    (let ((n (cl-loop for x from x0 while (equal fill (drgnx-uitest-pixel snap x y)) count t)))
      (should (equal (list what 'bar-fill want) (list what 'bar-fill n)))
      (should (equal (list what 'bar-track track) (list what 'bar-track (drgnx-uitest-pixel snap (+ x0 n) y)))))))

(defun drgnx-kit-sheet--check-cells (id variant scale)
  "Check every cell of the catalogue in the selected window, drawn for component ID at SCALE in theme VARIANT.
Returns the number of cells checked."
  (let* ((frame (selected-frame)) (s (drgnx-uitest-device-scale frame))
         (cells (drgnx-kit-catalogue-cells)) (snap nil) (n 0))
    (pcase-dolist (`(,_ ,variants ,state ,beg ,end) cells)
      ;; the cell's whole line on screen (a tall row at the window's foot is only partly there)
      (unless (and snap (drgnx-kit-sheet--whole-p beg) (drgnx-kit-sheet--whole-p end))
        (set-window-start nil (save-excursion (goto-char beg) (forward-line -1) (point)))
        (drgnx-test-wait-presented)
        (setq snap (drgnx-uitest-snapshot)))
      (let* ((edges (window-inside-pixel-edges))
             (what (list id variants state variant scale))
             (e (let ((drgnx-ui-kit--icons (drgnx-ui-kit-icon-function nil)))
                  (drgnx-ui-kit-expand id (drgnx-kit-sheet--props id variants state) scale nil)))
             (spaces (append (plist-get e :spaces) nil))
             (y (round (* s (+ (cadr edges) (cdr (posn-x-y (posn-at-point beg))) (/ (save-excursion (goto-char beg) (line-pixel-height)) 2.0))))))
        ;; (a) each pad its device px; the cell is its pads and its text
        (dolist (sp spaces)
          (let ((at (+ beg (aref sp 0))))
            (should (equal (list what 'pad (aref sp 0) (aref sp 1))
                           (list what 'pad (aref sp 0) (- (drgnx-kit-sheet--x (1+ at) s edges)
                                                          (drgnx-kit-sheet--x at s edges)))))))
        ;; the start and end pads, and between them the text (its icons and their gaps drawn as they are)
        (when spaces
          (let ((pads (+ (aref (car spaces) 1) (aref (car (last spaces)) 1)))
                (text (round (* s (string-pixel-width (buffer-substring (1+ beg) (1- end)))))))
            (should (equal (list what 'width (+ pads text))
                           (list what 'width (- (drgnx-kit-sheet--x end s edges) (drgnx-kit-sheet--x beg s edges)))))))
        ;; (a') a row is its geometry's height (`:height (density tree-row)'), in device px
        (when-let* ((h (plist-get (drgnx-ui-kit-geometry id variants) :height)) ((> h 0)) (h (drgnx-px h nil scale)))
          (should (equal (list what 'height h)
                         (list what 'height (round (* s (save-excursion (goto-char beg) (line-pixel-height))))))))
        ;; (b) the fill inside the start pad, halfway in (clear of a focus ring and of a rounded corner): the state's,
        ;; an agent mark's its agent's colour (a bar's is checked on its own row, below)
        (when (and spaces (not (eq id 'progress)))
          (let* ((token (or (plist-get (drgnx-ui-kit-state state) :fill)
                            (and (eq id 'agent-mark)
                                 (intern (format "a%d" (plist-get (drgnx-kit-sheet--props id variants state) :slot))))
                            'editor))
                 (x (+ (drgnx-kit-sheet--x beg s edges) (/ (aref (car spaces) 1) 2))))
            (let* ((want (drgnx-kit-sheet--rgb (drgnx-look-token token variant)))
                   (got (drgnx-uitest-pixel snap x y))
                   ;; on a mismatch, what is drawn there
                   (at (unless (equal want got)
                         (let ((p (posn-point (posn-at-x-y (- (round (/ x s)) (car edges)) (- (round (/ y s)) (cadr edges))))))
                           (list :at p :beg beg :char (and p (char-after p)) :start (window-start))))))
              (should (equal (list what 'fill token want nil) (list what 'fill token got at))))))
        ;; (b'') a progress bar: on the bar's own device row, its fill is VALUE of its width (rounded half up) in the
        ;; fill's colour, then the track's colour
        (when (and (eq id 'progress) (equal variants '(bar)))
          (drgnx-kit-sheet--check-bar what (drgnx-kit-sheet--props id variants state) variant scale snap beg s edges))
        ;; (c) high contrast: no shadow, so the column right of the cell is the surface
        (when (eq variant 'hc)
          (let ((x (+ (drgnx-kit-sheet--x end s edges) (round (* s 4)))))
            (when (< x (round (* s (nth 2 edges))))
              (should (equal (list what 'no-shadow (drgnx-kit-sheet--rgb (drgnx-look-token 'editor variant)))
                             (list what 'no-shadow (drgnx-uitest-pixel snap x y)))))))
        ;; the state table's rows (§7.6): a hovered or selected cell has no edge, so its leftmost column and its top
        ;; row are its fill (a 1 px ring would show there)
        (when (and drgnx-kit-sheet--edges (memq state '(hover selected selected-inactive)))
          (let* ((want (drgnx-kit-sheet--rgb (drgnx-look-token (plist-get (drgnx-ui-kit-state state) :fill) variant)))
                 (x0 (drgnx-kit-sheet--x beg s edges))
                 (top (round (* s (+ (cadr edges) (cdr (posn-x-y (posn-at-point beg)))))))
                 (xm (+ x0 (/ (aref (car spaces) 1) 2))))
            (should (equal (list what 'left-edge want) (list what 'left-edge (drgnx-uitest-pixel snap x0 y))))
            (should (equal (list what 'top-edge want) (list what 'top-edge (drgnx-uitest-pixel snap xm top))))))
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
                (setq-local cursor-type nil)       ; the cursor sits on a cell's first column, where the edges are read
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

(drgnx-look-gui-deftest drgnx-kit-sheet/agent-mark ()
  "The agent mark's sheet: its handle between exact pads on its agent's colour, in every theme and density."
  (skip-unless (display-graphic-p))
  (drgnx-kit-sheet-check 'agent-mark))

(drgnx-look-gui-deftest drgnx-kit-sheet/progress ()
  "Progress's sheet: a bar (its fill VALUE of its width, then the track) and a ring, in every theme and density."
  (skip-unless (display-graphic-p))
  (drgnx-kit-sheet-check 'progress))

(drgnx-look-gui-deftest drgnx-kit-sheet/state-table ()
  "The state table's rows in every theme and density: each state's fill, and no edge round a hovered or selected row."
  (skip-unless (display-graphic-p))
  (let ((drgnx-kit-sheet--edges t))
    (drgnx-kit-sheet-check 'row)))

;;;; The selection Sjá draws: one rounded row block per window (Task 10)

(require 'drgnx-view-sja)
(require 'drgnx-view-nav)

(defvar drgnx-kit-sheet--n 0 "A counter for each selection test's own view name (Sjá's views are the process's).")

(defconst drgnx-kit-sheet--sel-model
  (concat "{\"ops\":[{\"reset\":{\"descriptor\":{\"scheme\":\"links\",\"chain_kinds\":[\"link\"],"
          "\"match_fields\":[\"label\"],\"lists\":[\"all\"],\"classes\":[\"selected\"],\"start\":\"all\"},"
          "\"nodes\":[{\"id\":\"n1\",\"kind\":\"row\",\"nav\":{\"down\":\"n2\"},\"fields\":[[\"label\",\"a\"]]},"
          "{\"id\":\"n2\",\"kind\":\"row\",\"nav\":{\"up\":\"n1\"},\"fields\":[[\"label\",\"b\"]]}],"
          "\"edges\":[],\"lists\":[{\"name\":\"all\",\"ids\":[\"n1\",\"n2\"]}]}}]}")
  "Two list rows, n1 above n2, with the class `selected'.")

(defun drgnx-kit-sheet--argb (face)
  "FACE's background as the (A R G B) a snapshot gives."
  (cons 255 (mapcar (lambda (v) (/ v 257)) (color-values (face-background face nil t)))))

(defmacro drgnx-kit-sheet--with-list (&rest body)
  "BODY with the selected window showing `buf', a hub list in Sjá of two rows: n1 \"name  CHIP  Accept\" (a chip and a
primary button, each with a background of its own) and n2 \"other\", in the dark theme, the window's fringes the rows'
inset.  `view' is the view's name."
  (declare (indent 0))
  `(let ((drgnx-view-patch--buffers (make-hash-table :test #'equal))
         (drgnx-view-patch--hooked nil)
         (drgnx-view-model--views (make-hash-table :test #'equal))
         (drgnx-view-patch-send-function #'ignore)
         (buf (get-buffer-create " *kit-sel*"))
         (view (format "kit-sel-%d" (cl-incf drgnx-kit-sheet--n))))
     (drgnx-uitest-bare-frame)
     (load-theme 'drgnx-dark t)
     (delete-other-windows)
     (unwind-protect
         (progn
           (switch-to-buffer buf)
           (setq-local cursor-type nil)
           (let ((inset (drgnx-px drgnx-wb--row-inset)))
             (set-window-fringes nil inset inset))
           (drgnx-view-sja-attach view "c" :ack t :delay 0)
           (drgnx-view-model-event (list :view view :hub 7 :base 0 :version 1 :reset t :model drgnx-kit-sheet--sel-model))
           (drgnx-view-model-line
            (json-serialize
             (list :event "view-model"
                   :data (list :view view
                               :rows (list :view view :class "c" :hub 7 :base 0 :version 1 :env_epoch 0 :model 1
                                           :ops (vector
                                                 (list :reset
                                                       (vector (list :key "a" :text "  name  CHIP  Accept"   ; a lead: the start probe meets no glyph
                                                                     :runs [[8 12 "drgnx-chip-attention"]
                                                                            [14 20 "drgnx-ui-button-primary"]]
                                                                     :props [[0 20 "drgnx-work-id" "n1"]])
                                                               (list :key "b" :text "other"
                                                                     :props [[0 5 "drgnx-work-id" "n2"]])))))))))
           (drgnx-view-sja-draw-now buf)
           ,@body)
       (with-current-buffer buf (drgnx-view-nav--sel-clear))
       (drgnx-test-wait-presented)                ; Glitnir drops its own copy of the blocks at the next redisplay
       (drgnx-view-patch-teardown)
       (delete-other-windows)
       (kill-buffer buf)
       (mapc #'disable-theme custom-enabled-themes))))

(defun drgnx-kit-sheet--row-at (window pos s)
  "WINDOW's device y of the middle of POS's row, and its text area's device left and right x (S the device scale)."
  (let ((edges (window-inside-pixel-edges window)) (xy (posn-x-y (posn-at-point pos window))))
    (list (round (* s (+ (cadr edges) (cdr xy)
                         (/ (with-selected-window window (save-excursion (goto-char pos) (line-pixel-height))) 2.0))))
          (round (* s (car edges))) (round (* s (nth 2 edges))))))

(drgnx-look-gui-deftest drgnx-kit-sheet/selected-row-under-a-chip ()
  "A selected hub list row with a chip and a button: the selection's fill runs from inset to inset, the chip and the
button keep their own colours, and its top edge is the fill (no ring)."
  (skip-unless (and (display-graphic-p) (fboundp 'glitnir-active-p) (glitnir-active-p) (fboundp 'nidhogg-view-rows)))
  (drgnx-kit-sheet--with-list
    (should (equal "n1" (drgnx-view-nav 'select "n1")))
    (drgnx-test-wait-presented)
    (pcase-let* ((s (drgnx-uitest-device-scale (selected-frame))) (snap (drgnx-uitest-snapshot))
                 (`(,y ,x0 ,x1) (drgnx-kit-sheet--row-at (selected-window) (point-min) s))
                 (fill (drgnx-kit-sheet--argb 'drgnx-selected))
                 (px (lambda (x y) (drgnx-uitest-pixel snap x y)))
                 (at (lambda (pos) (round (* s (+ (car (window-inside-pixel-edges)) (car (posn-x-y (posn-at-point pos)))))))))
      (should (equal (list 'start fill) (list 'start (funcall px (+ x0 (round (* s 2))) y))))
      (should (equal (list 'end fill) (list 'end (funcall px (- x1 (round (* s 2))) y))))
      (should (equal (list 'gap fill) (list 'gap (funcall px (+ (funcall at (+ (point-min) 6)) (round s)) y))))
      ;; the chip and the button keep their own backgrounds: their colour is among their run's pixels (its glyphs
      ;; cover the rest)
      (pcase-dolist (`(,what ,face ,from ,to) '((chip drgnx-chip-attention 8 12) (button drgnx-ui-button-primary 14 20)))
        (let ((want (drgnx-kit-sheet--argb face)))
          (should (equal (list what want)
                         (list what (cl-loop for x from (funcall at (+ (point-min) from))
                                             below (funcall at (+ (point-min) to))
                                             when (equal want (funcall px x y)) return want))))))
      (let ((top (round (* s (cadr (window-inside-pixel-edges))))))
        (should (equal (list 'top-edge fill) (list 'top-edge (funcall px (+ x0 (round (* s 12))) top)))))
      ;; the next row is not selected
      (pcase-let ((`(,y2 . ,_) (drgnx-kit-sheet--row-at (selected-window) (save-excursion (goto-char (point-min))
                                                                                          (forward-line 1) (point))
                                                        s)))
        (should-not (equal (list 'next fill) (list 'next (funcall px (+ x0 (round (* s 2))) y2))))))))

(drgnx-look-gui-deftest drgnx-kit-sheet/selection-per-window ()
  "The view in two windows: the selection's fill in the focused one, the inactive selection in the other; focus
moved, they swap."
  (skip-unless (and (display-graphic-p) (fboundp 'glitnir-active-p) (glitnir-active-p) (fboundp 'nidhogg-view-rows)))
  (drgnx-kit-sheet--with-list
    (let ((other (split-window-right)))
      (set-window-buffer other buf)
      (let ((inset (drgnx-px drgnx-wb--row-inset))) (set-window-fringes other inset inset))
      (should (equal "n1" (drgnx-view-nav 'select "n1")))
      (let ((check
             (lambda (focused unfocused)
               (drgnx-test-wait-presented)
               (let* ((s (drgnx-uitest-device-scale (selected-frame))) (snap (drgnx-uitest-snapshot)))
                 (dolist (c (list (cons focused 'drgnx-selected) (cons unfocused 'drgnx-selected-inactive)))
                   (pcase-let ((`(,y ,x0 . ,_) (drgnx-kit-sheet--row-at (car c) (with-current-buffer buf (point-min)) s)))
                     (should (equal (list (cdr c) (drgnx-kit-sheet--argb (cdr c)))
                                    (list (cdr c) (drgnx-uitest-pixel snap (+ x0 (round (* s 2))) y))))))))))
        (funcall check (selected-window) other)
        (let ((w (selected-window)))
          (select-window other)
          (funcall check other w))))))

(provide 'kit-sheets-gui-test)
;;; kit-sheets-gui-test.el ends here
