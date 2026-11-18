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

(defun drgnx-kit-sheet--face-variants (variants)
  "VARIANTS as the kit's faces see them: a chip of an agent's tone is the neutral chip with the agent's colour on its text
\(`agent' has no face of its own)."
  (mapcar (lambda (v) (if (eq v 'agent) 'neutral v)) variants))

(defun drgnx-kit-sheet--bg (id variants &optional theme)
  "The fill token component ID's binding for VARIANTS (values) gives its own face, or nil: the most specific binding
whose values VARIANTS all have.  In THEME `hc' a binding marked `:hc-ring' has no fill (a ring instead): nil."
  (let (best (n -1))
    (dolist (b (plist-get (drgnx-ui-kit-component id) :bind))
      (when (and (cl-every (lambda (v) (memq v (drgnx-kit-sheet--face-variants variants))) (car b)) (> (length (car b)) n))
        (setq best b n (length (car b)))))
    (and (not (and (eq theme 'hc) (plist-get (cdr best) :hc-ring)))
         (plist-get (cdr best) :bg))))

(defun drgnx-kit-sheet--edge (id variants)
  "The ring token of component ID's binding for VARIANTS (see `drgnx-kit-sheet--bg'), or nil."
  (let (best (n -1))
    (dolist (b (plist-get (drgnx-ui-kit-component id) :bind))
      (when (and (cl-every (lambda (v) (memq v variants)) (car b)) (> (length (car b)) n))
        (setq best b n (length (car b)))))
    (plist-get (cdr best) :edge)))

(defun drgnx-kit-sheet--tab-fill (id variants state)
  "A shown tab's fill token (its own, not the state table's `sel'): an editor tab's the editor's surface, a panel tab's
the quiet selection; nil for any other cell."
  (and (eq id 'tab) (memq state '(selected selected-inactive))
       (plist-get (cdr (assq (if (equal variants '(panel)) 'panel-current 'current)
                             (mapcar (lambda (b) (cons (car-safe (car b)) (cdr b)))
                                     (plist-get (drgnx-ui-kit-component 'tab) :bind))))
                  :bg)))

(defvar drgnx-kit-sheet--edges nil
  "Non-nil while a sheet also checks that hovered and selected cells have no edge (`drgnx-kit-sheet/state-table').")

(defun drgnx-kit-sheet--baseline (beg s edges)
  "The device row of the baseline of BEG's line, at device scale S in a window at EDGES: a marker image whose bottom is
the baseline (`:ascent 100') is drawn at the line's end in the fill's face, its lowest pixel found, and taken away."
  (let* ((at (save-excursion (goto-char beg) (line-end-position)))
         (img (create-image "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"4\" height=\"6\"><rect width=\"4\" height=\"6\" fill=\"currentColor\"/></svg>"
                            'svg t :ascent 100 :scale 1))
         (inhibit-read-only t))
    (save-excursion
      (goto-char at)
      (insert (propertize "m" 'display img 'face 'drgnx-kit-progress-fill)))
    (unwind-protect
        (progn
          (drgnx-test-wait-presented)
          (let* ((snap (drgnx-uitest-snapshot))
                 (want (drgnx-kit-sheet--rgb (face-foreground 'drgnx-kit-progress-fill nil t)))
                 (x (+ (drgnx-kit-sheet--x at s edges) 1))
                 (top (round (* s (+ (cadr edges) (cdr (posn-x-y (posn-at-point at)))))))
                 (h (round (* s (save-excursion (goto-char at) (line-pixel-height))))))
            (1+ (or (cl-loop for y from (+ top h -1) downto top when (equal want (drgnx-uitest-pixel snap x y)) return y)
                    (error "No baseline marker drawn at %s" at)))))
      (save-excursion (goto-char at) (delete-char 1)))))

(defun drgnx-kit-sheet--check-range (what e s edges snap beg variant)
  "The range bar E (an expansion) drawn at BEG: down the column halfway into each part, the part's colour (its face's
foreground; the tail's is the `range-tail' token of VARIANT, the bar's colour tinted over the surface, not the full
colour) fills the bar's height (`drgnx-ui-kit-range-bar-heights' by the density, logical px) in device px of the cell's
line."
  (let* ((top (round (* s (+ (cadr edges) (cdr (posn-x-y (posn-at-point beg)))))))
         (h (round (* s (save-excursion (goto-char beg) (line-pixel-height))))))
    (dolist (sp (append (plist-get e :spaces) nil))
      (when-let* ((run (cl-find-if (lambda (r) (and (<= (aref r 0) (aref sp 0)) (< (aref sp 0) (aref r 1)))) (plist-get e :runs)))
                  ((> (or (aref sp 2) 0) 0))             ; a gap between parts has no part colour
                  (face (intern (aref run 2))))
        (let* ((colour (drgnx-kit-sheet--rgb (if (eq face 'drgnx-kit-range-bar-tail)
                                                 (drgnx-look-token 'range-tail variant)
                                               (face-foreground face nil t))))
               (xm (+ (drgnx-kit-sheet--x (+ beg (aref sp 0)) s edges) (/ (aref sp 1) 2)))
               (rows (cl-loop for y from (max 0 (- top h)) below (+ top h h) ; the whole neighbourhood of the line: the bar is the only thing in the part's colour in this column
                              when (equal colour (drgnx-uitest-pixel snap xm y)) collect y)))
          (should (equal (list what face 'range-bar-height (aref sp 2) nil)
                         ;; on a mismatch, where and what was read
                         (list what face 'range-bar-height (length rows)
                               (unless (= (length rows) (aref sp 2))
                                 (list :colour colour :xm xm :top top :h h :found rows
                                       :column (mapcar (lambda (y) (drgnx-uitest-pixel snap xm y)) (number-sequence top (+ top 12)))))))))))))

(defun drgnx-kit-sheet--check-fill (what fill track want total height snap beg s edges)
  "The bar drawn at BEG (WHAT the cell, for the failures), TOTAL device px wide: down the column halfway into its
fill, the fill (FILL, an (A R G B)) is HEIGHT device px high and its middle on the caption's centre line (within a
device px: the baseline less half the caption font's ascent less its descent, the line icons and the bar are centred
on, whatever pads the line box); along its middle row the fill is WANT device px (within one per rounded end), and
the track (TRACK, unless nil or the fill is the whole bar) follows it.  Returns the bar's middle device row."
  (let* ((x0 (drgnx-kit-sheet--x beg s edges))
         (xm (+ x0 (/ want 2)))
         (top (round (* s (+ (cadr edges) (cdr (posn-x-y (posn-at-point beg)))))))
         (h (round (* s (save-excursion (goto-char beg) (line-pixel-height)))))
         (rows (cl-loop for y from top below (+ top h) when (equal fill (drgnx-uitest-pixel snap xm y)) collect y)))
    (should (equal (list what 'bar-drawn t) (list what 'bar-drawn (and rows t))))
    ;; the bar's height, and its middle on the caption's centre line
    (should (equal (list what 'bar-height height) (list what 'bar-height (length rows))))
    (let* ((font (font-info (face-font 'drgnx-ui-caption)))
           (base (drgnx-kit-sheet--baseline beg s edges))
           ;; `font-info': [OPENED-NAME FULL-NAME SIZE HEIGHT BASELINE-OFFSET RELATIVE-COMPOSE DEFAULT-ASCENT MAX-WIDTH
           ;; ASCENT DESCENT ...]
           (centre (- base (* s (/ (- (aref font 8) (aref font 9)) 2.0))))
           (off (- (+ (car rows) (/ (length rows) 2.0)) centre)))
      (should (equal (list what 'bar-on-the-caption-centre-line t)
                     (list what 'bar-on-the-caption-centre-line
                           (or (<= (abs off) 1.0) (list off 'baseline base 'centre centre 'rows (car rows) (length rows)))))))
    ;; the fill's width: its pixels along the middle row (the rounded start may lose one to its edge's blend), the
    ;; track's right after them
    (let* ((y (nth (/ (length rows) 2) rows))
           (xs (cl-loop for x from x0 below (+ x0 total 4) when (equal fill (drgnx-uitest-pixel snap x y)) collect x)))
      ;; within one device px a rounded end, two for a fill that is the whole bar (both ends rounded)
      (should (equal (list what 'bar-fill want t)
                     (list what 'bar-fill want (<= (abs (- want (length xs))) (if (>= want total) 2 1)))))
      (when (and track (< want total))
        (should (equal (list what 'bar-track track)
                       (list what 'bar-track (drgnx-uitest-pixel snap (1+ (car (last xs))) y)))))
      y)))

(defun drgnx-kit-sheet--check-bar (what props variant scale snap beg s edges)
  "The progress bar of PROPS drawn at BEG at SCALE (`drgnx-kit-sheet--check-fill'): the fill (`progress-fill')
`drgnx-ui-kit-progress-bar-px' high, VALUE of the width's device px rounded half up, then the track (`progress-track')."
  (let ((total (drgnx-px (plist-get props :width) nil scale)))
    (drgnx-kit-sheet--check-fill what (drgnx-kit-sheet--rgb (drgnx-look-token 'progress-fill variant))
                                 (drgnx-kit-sheet--rgb (drgnx-look-token 'progress-track variant))
                                 (floor (+ (* total (plist-get props :value)) 0.5 1e-9)) total
                                 (drgnx-px drgnx-ui-kit-progress-bar-px nil scale) snap beg s edges)))

(defun drgnx-kit-sheet--check-meter (what props variant scale snap beg s edges)
  "The meter of PROPS drawn at BEG at SCALE.  With no bar (no limit, unpriced): no pixel of the fill's colour along
the line's middle.  Else (`drgnx-kit-sheet--check-fill') the fill in its state's colour, its size's height, SPENT of
LIMIT of the bar's device px, then the track (an inherited limit's: an outline, unchecked); the forecast's p50 a tick
in its colour in the middle of its slot (all of the slot in high contrast); a `wide' meter's span to p90 filled in
`meter-span', in high contrast an outline: its top edge `meter-span', its middle not."
  (let* ((state (intern (plist-get props :state))) (size (intern (plist-get props :size)))
         (limit (plist-get props :limit)) (spent (float (plist-get props :spent)))
         (total (drgnx-px (if (eq size 'row) drgnx-ui-kit-meter-row-px (plist-get props :width)) nil scale))
         (fill (drgnx-kit-sheet--rgb (drgnx-look-token (pcase state ('nearing 'meter-near)
                                                              ((or 'reached 'over) 'meter-reached) (_ 'meter-fill))
                                                       variant)))
         (x0 (drgnx-kit-sheet--x beg s edges)))
    (if (or (null limit) (memq state '(none unpriced)))
        (let ((y (round (* s (+ (cadr edges) (cdr (posn-x-y (posn-at-point beg)))
                                (/ (save-excursion (goto-char beg) (line-pixel-height)) 2.0))))))
          (should (equal (list what 'no-bar nil)
                         (list what 'no-bar (cl-loop for x from x0 below (+ x0 total)
                                                     thereis (equal fill (drgnx-uitest-pixel snap x y)))))))
      (cl-flet ((at (x) (floor (+ (* total (max 0.0 (min 1.0 (/ x (float limit))))) 0.5 1e-9)))
                (rgb (token) (drgnx-kit-sheet--rgb (drgnx-look-token token variant))))
        (let* ((h (drgnx-px (alist-get size drgnx-ui-kit-meter-heights) nil scale))
               (y (drgnx-kit-sheet--check-fill what fill (unless (eq state 'inherited) (rgb 'progress-track))
                                               (at spent) total h snap beg s edges))
               (fc (plist-get props :forecast)) (hc (eq variant 'hc)))
          (when fc
            (let* ((tw (min total (drgnx-px drgnx-ui-kit-meter-tick-px nil scale)))
                   (line (drgnx-px-line 1 nil scale))
                   (t0 (min (max 0 (- (at (aref fc 0)) (/ tw 2))) (- total tw)))
                   (tick (rgb (if (eq state 'forecast-over) 'meter-near 'meter-tick))))
              (should (equal (list what 'tick tick)
                             (list what 'tick (drgnx-uitest-pixel snap (+ x0 t0 (if hc 0 (/ (- tw line) 2))) y))))
              (when hc
                (should (equal (list what 'tick-full tick)
                               (list what 'tick-full (drgnx-uitest-pixel snap (+ x0 t0 tw -1) y)))))
              (when (eq size 'wide)
                (let* ((s0 (+ t0 tw)) (s1 (max (at (aref fc 1)) s0)) (span (rgb 'meter-span))
                       (xm (+ x0 (/ (+ s0 s1) 2))))
                  (when (> (- s1 s0) 4)
                    (if hc
                        (progn
                          (should-not (equal (list what 'span-hollow span)
                                             (list what 'span-hollow (drgnx-uitest-pixel snap xm y))))
                          ;; its top edge: the bar's first row
                          (should (equal (list what 'span-edge span)
                                         (list what 'span-edge (drgnx-uitest-pixel snap xm (- y (/ h 2)))))))
                      (should (equal (list what 'span span)
                                     (list what 'span (drgnx-uitest-pixel snap xm y)))))))))))))))

(defun drgnx-kit-sheet--check-cells (id variant scale)
  "Check every cell of the catalogue in the selected window, drawn for component ID at SCALE in theme VARIANT.
Returns the number of cells checked."
  (let* ((frame (selected-frame)) (s (drgnx-uitest-device-scale frame))
         (cells (drgnx-kit-catalogue-cells)) (snap nil) (n 0))
    (pcase-dolist (`(,id ,variants ,state ,beg ,end) cells)
      ;; the cell's whole line on screen (a tall row at the window's foot is only partly there)
      (unless (and snap (drgnx-kit-sheet--whole-p beg) (drgnx-kit-sheet--whole-p end))
        (set-window-start nil (save-excursion (goto-char beg) (forward-line -1) (point)))
        (drgnx-test-wait-presented)
        (setq snap (drgnx-uitest-snapshot)))
      (let* ((edges (window-inside-pixel-edges))
             (what (list id variants state variant scale))
             (e (let ((drgnx-ui-kit--icons (drgnx-ui-kit-icon-function nil)))
                  (let ((props (drgnx-kit-sheet--props id variants state)))
                    (drgnx-ui-kit-expand (intern (plist-get props :c)) props scale nil))))
             (spaces (append (plist-get e :spaces) nil))
             (y (round (* s (+ (cadr edges) (cdr (posn-x-y (posn-at-point beg))) (/ (save-excursion (goto-char beg) (line-pixel-height)) 2.0))))))
        ;; (a) each pad its device px; the cell is its pads and its text
        (dolist (sp spaces)
          (let ((at (+ beg (aref sp 0))))
            (should (equal (list what 'pad (aref sp 0) (aref sp 1))
                           (list what 'pad (aref sp 0) (- (drgnx-kit-sheet--x (1+ at) s edges)
                                                          (drgnx-kit-sheet--x at s edges)))))))
        ;; the start and end pads, and between them the text (its icons and their gaps drawn as they are); a meter
        ;; ends in its text, not a pad
        (when (and spaces (not (equal variants '(meter))))
          (let ((pads (if (eq id 'range-bar)   ; a bar is its parts and nothing else: its width is theirs
                          (apply #'+ (mapcar (lambda (sp) (aref sp 1)) spaces))
                        (+ (aref (car spaces) 1) (aref (car (last spaces)) 1))))
                (text (if (eq id 'range-bar) 0 (round (* s (string-pixel-width (buffer-substring (1+ beg) (1- end))))))))
            (should (equal (list what 'width (+ pads text))
                           (list what 'width (- (drgnx-kit-sheet--x end s edges) (drgnx-kit-sheet--x beg s edges)))))))
        ;; (a') a row the expansion gives a height (`:height (density tree-row)'; an inline component, a chip, gives none)
        ;; is that tall, in device px
        (when-let* ((h (plist-get (plist-get e :height) :unit)) ((> h 0)))
          (should (equal (list what 'height h)
                         (list what 'height (round (* s (save-excursion (goto-char beg) (line-pixel-height))))))))
        ;; (b) the fill inside the start pad, halfway in (clear of a focus ring and of a rounded corner): the state's,
        ;; the component's own, an agent mark's its agent's colour (a bar's is checked on its own row, below)
        (when (and spaces (not (memq id '(progress range-bar))))
          (let* ((token (or (drgnx-kit-sheet--tab-fill id variants state)
                            (plist-get (drgnx-ui-kit-state state) :fill) (drgnx-kit-sheet--bg id variants variant)
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
        ;; (b') a component with a ring has it at rest: its leftmost column, halfway down, is the ring's token
        (when-let* (((eq state 'rest)) (edge (drgnx-kit-sheet--edge id variants)) (x0 (drgnx-kit-sheet--x beg s edges)))
          (should (equal (list what 'ring edge (drgnx-kit-sheet--rgb (drgnx-look-token edge variant)))
                         (list what 'ring edge (drgnx-uitest-pixel snap x0 y)))))
        ;; (b'') a progress bar: on the bar's own device row, its fill is VALUE of its width (rounded half up) in the
        ;; fill's colour, then the track's colour
        (when (and (eq id 'progress) (equal variants '(bar)))
          (drgnx-kit-sheet--check-bar what (drgnx-kit-sheet--props id variants state) variant scale snap beg s edges))
        ;; (b4) a range bar: down the column halfway into its first part, that part's colour is the bar's height
        ;; (10 logical px, 8 compact, 12 roomy) in device px
        (when (and (eq id 'range-bar) spaces)
          (drgnx-kit-sheet--check-range what e s edges snap beg variant))
        ;; (b3) a meter: its bar, tick and span, or no bar
        (when (and (eq id 'progress) (equal variants '(meter)))
          (drgnx-kit-sheet--check-meter what (drgnx-kit-sheet--props id variants state) variant scale snap beg s edges))
        ;; (c) high contrast: no shadow, so the column right of the cell is the surface
        (when (eq variant 'hc)
          (let ((x (+ (drgnx-kit-sheet--x end s edges) (round (* s 4)))))
            (when (< x (round (* s (nth 2 edges))))
              (should (equal (list what 'no-shadow (drgnx-kit-sheet--rgb (drgnx-look-token 'editor variant)))
                             (list what 'no-shadow (drgnx-uitest-pixel snap x y)))))))
        ;; the state table's rows (§7.6): a hovered or selected cell has no edge, so its leftmost column and its top
        ;; row are its fill (a 1 px ring would show there)
        (when (and drgnx-kit-sheet--edges spaces (memq state '(hover selected selected-inactive)))
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

(drgnx-look-gui-deftest drgnx-kit-sheet/button ()
  "The button's sheet: 4 styles x 2 sizes x 7 states, each pad exact, its own fill (the state's above it), in every theme
and density."
  (skip-unless (display-graphic-p))
  (drgnx-kit-sheet-check 'button))

(drgnx-look-gui-deftest drgnx-kit-sheet/key-hint ()
  "The key hint's sheet: its two variants x 7 states in every theme and density."
  (skip-unless (display-graphic-p))
  (drgnx-kit-sheet-check 'key-hint))
(drgnx-look-gui-deftest drgnx-kit-sheet/agent-mark ()
  "The agent mark's sheet: its handle between exact pads on its agent's colour, in every theme and density."
  (skip-unless (display-graphic-p))
  (drgnx-kit-sheet-check 'agent-mark))

(drgnx-look-gui-deftest drgnx-kit-sheet/range-bar ()
  "The range bar's sheet: its three variants, each part's space exact and its colour the bar's height tall, in every
theme and density."
  (skip-unless (display-graphic-p))
  (drgnx-kit-sheet-check 'range-bar))

(drgnx-look-gui-deftest drgnx-kit-sheet/progress ()
  "Progress's sheet: a bar (its fill VALUE of its width, then the track) and a ring, in every theme and density."
  (skip-unless (display-graphic-p))
  (drgnx-kit-sheet-check 'progress))

(drgnx-look-gui-deftest drgnx-kit-sheet/meter ()
  "The meter's sheet: each state at each size (row, card, wide), its fill SPENT of LIMIT in the state's colour, its
height, on the caption's centre line, its forecast tick and span (an outline in high contrast), no bar without a limit,
in every theme and density."
  (skip-unless (display-graphic-p))
  (drgnx-kit-sheet-check 'meter))

(drgnx-look-gui-deftest drgnx-kit-sheet/board-card-bar ()
  "The Work board's card bar as the hub sends it (`work::trail::board': the kit's progress bar with the card's bottom
face under it), dressed by the inserter: 4 px high and centred on its line, its fill a quarter of its width, on the
card, in every theme at the session's scale."
  (skip-unless (display-graphic-p))
  (drgnx-uitest-bare-frame)
  (let* ((frame (selected-frame)) (old (window-buffer)) (scale (drgnx-pixels-scale frame))
         (s (drgnx-uitest-device-scale frame)) (props '(:c "progress" :kind "bar" :value 0.25 :width 184))
         (buf (get-buffer-create " *kit-board-bar*")))
    (unwind-protect
        (pcase-dolist (`(,variant . ,theme) drgnx-kit-sheet-themes)
          (mapc #'disable-theme custom-enabled-themes)
          (load-theme theme t)
          (let* ((e (drgnx-ui-kit-expand 'progress props scale nil))
                 (n (length (plist-get e :text)))
                 (row (list :text (plist-get e :text)
                            :runs (append (mapcar (lambda (r) (append r nil)) (plist-get e :runs))
                                          (list (list 0 n "drgnx-card-bottom")))
                            :props (mapcar (lambda (p) (append p nil)) (plist-get e :props))
                            :spaces (mapcar (lambda (sp) (append sp nil)) (plist-get e :spaces))))
                 (state (drgnx-view-patch--make :view "kit-board-bar" :class "kit" :epoch 1)))
            (switch-to-buffer buf)
            (setq-local cursor-type nil)
            (let ((inhibit-read-only t))
              (erase-buffer)
              (insert "\n" (drgnx-view-patch--dress state "cards:0:2" row (copy-sequence (plist-get e :text))) "\n"))
            (drgnx-test-wait-presented)
            (drgnx-kit-sheet--check-bar (list 'board-card-bar variant) props variant scale (drgnx-uitest-snapshot)
                                        (save-excursion (goto-char (point-min)) (forward-line 1) (point))
                                        s (window-inside-pixel-edges))))
      (switch-to-buffer old)
      (kill-buffer buf)
      (mapc #'disable-theme custom-enabled-themes))))

(drgnx-look-gui-deftest drgnx-kit-sheet/section-header ()
  "The section header's sheet: collapsible or not x 7 states, each pad exact, in every theme and density."
  (skip-unless (display-graphic-p))
  (drgnx-kit-sheet-check 'section-header))

(drgnx-look-gui-deftest drgnx-kit-sheet/card ()
  "The card's sheet: 3 kinds x 4 shapes, each pad exact, the panel's fill and the kind's ring, in every theme and density."
  (skip-unless (display-graphic-p))
  (drgnx-kit-sheet-check 'card))

(drgnx-look-gui-deftest drgnx-kit-sheet/card-rows-have-no-ring-between-lines ()
  "A card of three lines (`drgnx-ui-kit-card-lines'): its ring is open between the lines (the pixels each side of a seam
are the card's fill), and closed on its top edge."
  (skip-unless (and (display-graphic-p) (fboundp 'glitnir-active-p) (glitnir-active-p)))
  (drgnx-uitest-bare-frame)
  (load-theme 'drgnx-dark t)
  (let ((buf (get-buffer-create " *kit-card*")))
    (unwind-protect
        (progn
          (switch-to-buffer buf)
          (setq-local cursor-type nil)
          (erase-buffer)
          (insert (drgnx-ui-kit-card-lines '("one" "two" "three") 'plain 12))
          (goto-char (point-min))
          (drgnx-test-wait-presented)
          (let* ((s (drgnx-uitest-device-scale (selected-frame))) (snap (drgnx-uitest-snapshot))
                 (edges (window-inside-pixel-edges))
                 (ring (drgnx-kit-sheet--rgb (drgnx-look-token 'border-strong 'dark)))
                 (fill (drgnx-kit-sheet--rgb (drgnx-look-token 'panel 'dark)))
                 (x (round (* s (+ (car edges) 24))))
                 (top (round (* s (cadr edges))))
                 (seam (round (* s (+ (cadr edges)
                                      (cdr (posn-x-y (posn-at-point (save-excursion (goto-char (point-min)) (forward-line 1) (point))))))))))
            (should (equal (list 'top ring) (list 'top (drgnx-uitest-pixel snap x top))))
            (should (equal (list 'above-seam fill) (list 'above-seam (drgnx-uitest-pixel snap x (1- seam)))))
            (should (equal (list 'below-seam fill) (list 'below-seam (drgnx-uitest-pixel snap x seam))))))
      (kill-buffer buf)
      (mapc #'disable-theme custom-enabled-themes))))

(drgnx-look-gui-deftest drgnx-kit-sheet/chip ()
  "The chip's sheet: its two variants x 7 states in every theme and density."
  (skip-unless (display-graphic-p))
  (drgnx-kit-sheet-check 'chip))

(drgnx-look-gui-deftest drgnx-kit-sheet/status-dot ()
  "The status dot's sheet: its two variants x 7 states in every theme and density."
  (skip-unless (display-graphic-p))
  (drgnx-kit-sheet-check 'status-dot))

(drgnx-look-gui-deftest drgnx-kit-sheet/tab ()
  "The tab's sheet: editor and panel x 7 states, each pad exact (its 18 px close slot too), the shown tab on its own
fill (an editor tab the editor's surface, a panel tab the quiet selection), the others on the row, in every theme and
density."
  (skip-unless (display-graphic-p))
  (drgnx-kit-sheet-check 'tab))

(drgnx-look-gui-deftest drgnx-kit-sheet/segmented ()
  "The segmented switch's sheet: one track in its ring (the border's colour at its left edge), each pad exact, the first
item on the surface, in every theme and density."
  (skip-unless (display-graphic-p))
  (drgnx-kit-sheet-check 'segmented))

(declare-function drgnx-wb-area-show "drgnx-wb")
(declare-function drgnx-wb-area-hide "drgnx-wb")
(declare-function drgnx-wb-area-window "drgnx-wb")
(declare-function drgnx-state-mode "drgnx-state")

(drgnx-look-gui-deftest drgnx-kit-sheet/panel-tab-pill ()
  "The panel's tab row (debugging.html `.ptabs' and `.pt.on'): the row is 32 px tall and the shown tab's pill on the
quiet selection is 24 px of it, 4 above and 4 below (one device px of rounding allowed), read down a column 7 px
past the pill's left edge: inside its start pad, clear of its rounded corners.  Red first: the pill was as tall as the row's text line."
  (skip-unless (and (display-graphic-p) (fboundp 'glitnir-active-p) (glitnir-active-p)))
  (require 'drgnx-area)
  (require 'drgnx-state)
  (let* ((root (drgnx-uitest-root-frame))
         (config (with-selected-frame root (current-window-configuration)))
         (saved (mapcar (lambda (p) (cons p (frame-parameter root p))) '(drgnx-wb-areas drgnx-wb-panel-px)))
         (main (get-buffer-create "*panel-pill main*")))
    (unwind-protect
        (with-selected-frame root
          (drgnx-uitest-bare-frame)
          (load-theme 'drgnx-dark t)
          (delete-other-windows)
          (switch-to-buffer main)
          (drgnx-state-mode 1)
          (set-frame-parameter root 'drgnx-wb-areas nil)
          (set-frame-parameter root 'drgnx-wb-panel-px nil)
          (drgnx-wb-area-show 'panel 'results)
          (drgnx-test-wait-presented)
          (let* ((w (drgnx-wb-area-window 'panel)) (edges (window-pixel-edges w)) (top (nth 1 edges))
                 (s (drgnx-uitest-device-scale root)) (row (window-header-line-height w))
                 (mid (+ top (/ row 2))) (x (nth 0 edges)) (at nil))
            (should (equal (list 'row (drgnx-px 32 root)) (list 'row row)))
            ;; the shown tab's first pixel, from what lies under the header line
            (while (and (not at) (< x (nth 2 edges)))
              (let* ((posn (posn-at-x-y x mid root)) (str (and posn (posn-string posn))))
                (when (and str (stringp (car str))
                           (equal (cdr-safe (get-text-property (cdr str) 'drgnx-tab (car str))) 'results))
                  (setq at x)))
              (setq x (1+ x)))
            (should at)
            (let* ((snap (drgnx-uitest-snapshot root)) (fill (drgnx-kit-sheet--argb 'drgnx-kit-tab-panel-current))
                   ;; the pill's left edge: its first fill pixel across the row's middle (the tab's string may start
                   ;; with the gap before it)
                   (left (cl-loop for dx from (round (* s at)) below (round (* s (nth 2 edges)))
                                  when (equal fill (drgnx-uitest-pixel snap dx (round (* s mid)))) return dx))
                   ;; past its 6 px corner, before its 9 px pad ends
                   (col (+ (or left 0) (round (* s (drgnx-px 7 root)))))
                   ;; the row's own colour, at its top (4 px above the pill)
                   (bar (drgnx-uitest-pixel snap col (round (* s top))))
                   ;; the pill: what is not the row's colour down the column (its ring and its fill)
                   (ys (cl-loop for y from (round (* s top)) below (round (* s (+ top row)))
                                unless (equal bar (drgnx-uitest-pixel snap col y)) collect y))
                   (pill (drgnx-px 24 root)) (dev (lambda (n) (round (* s n)))))
              (ert-info ((format "pill rows %S, left %S, col %d, row %d, ring %S, fill %S" ys left col row
                                 (and ys (drgnx-uitest-pixel snap col (car ys))) fill))
                (should left)
                (should ys)
                ;; the tab's text in the kit face's own size: the header line's relative height is not applied twice
                (let* ((st (posn-string (posn-at-x-y (+ at 20) mid root)))
                       (size (lambda (font) (aref (font-info font root) 2))))
                  (should (equal (funcall size (font-at (cdr st) w (car st)))
                                 (funcall size (face-font 'drgnx-kit-tab-panel-current root ?x)))))
                ;; filled with the quiet selection in its middle
                (should (equal fill (drgnx-uitest-pixel snap col (nth (/ (length ys) 2) ys))))
                ;; one run, 24 px (or one short), in the row's middle
                (should (= (length ys) (1+ (- (car (last ys)) (car ys)))))
                (should (<= (1- (funcall dev pill)) (length ys) (funcall dev pill)))
                (should (<= (abs (- (- (car ys) (funcall dev top))
                                    (- (funcall dev (+ top row)) (1+ (car (last ys))))))
                            1))))))
      (ignore-errors (with-selected-frame root (drgnx-wb-area-hide 'panel)))
      (drgnx-state-mode -1)
      (pcase-dolist (`(,p . ,v) saved) (set-frame-parameter root p v))
      (with-selected-frame root (set-window-configuration config))
      (kill-buffer main)
      (mapc #'disable-theme custom-enabled-themes))))

(drgnx-look-gui-deftest drgnx-kit-sheet/diff-block ()
  "The diff block's sheet: its head row in every theme and density, each pad exact."
  (skip-unless (display-graphic-p))
  (drgnx-kit-sheet-check 'diff-block))

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
