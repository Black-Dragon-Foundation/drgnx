;;; look-explorer-gui-test.el --- GUI tests: the Explorer's rows (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake

;; Pattern D: every picture is taken after `drgnx-test-wait-presented'.  The hover row moves a real pointer
;; (`drgnx-uitest-pointer-set': sway only), so it skips elsewhere and the integration's sway pass must report it
;; passed.  The Explorer buffer is shown in the selected window of a bare frame, over a temporary folder.

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)
(require 'drgnx-look-gui-fixture (expand-file-name "../fixtures/look-gui-fixture" (file-name-directory (macroexp-file-name))))

(defconst drgnx-ui-look-explorer--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-look-explorer--repo)))
(require 'drgnx)
(require 'drgnx-color)
(require 'drgnx-explorer)
(load (expand-file-name "modules/ui/drgnx-look-fonts" drgnx-ui-look-explorer--repo) nil t)
(load (expand-file-name "modules/ui/drgnx-look-density" drgnx-ui-look-explorer--repo) nil t)
(load (expand-file-name "themes/drgnx-theme-gen" drgnx-ui-look-explorer--repo) nil t)

(defmacro drgnx-ui-look-explorer--with (root &rest body)
  "BODY with the Explorer rooted at ROOT (a temporary folder with a.txt, b.txt and c.txt, all `modified' in git) shown
in the selected window of a bare frame under the dark theme.  Everything undone after."
  (declare (indent 1))
  `(let* ((,root (file-name-as-directory (make-temp-file "look-explorer" t)))
          (drgnx-explorer--roots nil) (drgnx-explorer-compact-folders nil))
     (dolist (n '("a.txt" "b.txt" "c.txt")) (write-region "" nil (expand-file-name n ,root) nil 'silent))
     (drgnx-uitest-bare-frame)
     (delete-other-windows)
     (mapc #'disable-theme custom-enabled-themes)
     (load-theme 'drgnx-dark t)
     (unwind-protect
         (cl-letf (((symbol-function 'drgnx-git-unread-p) (lambda (&rest _) nil))
                   ((symbol-function 'drgnx-git-status) (lambda (&rest _) 'modified)))
           (drgnx-look-density-on)
           (setq drgnx-explorer--roots (list ,root))
           (set-window-buffer (selected-window) (drgnx-explorer--buffer))
           (with-current-buffer (drgnx-explorer--buffer) (drgnx-explorer--render))
           (drgnx-test-wait-presented)
           ,@body)
       (drgnx-look-density-off)
       (mapc #'disable-theme custom-enabled-themes)
       (when (get-buffer drgnx-explorer-buffer-name) (kill-buffer drgnx-explorer-buffer-name))
       (delete-directory ,root t))))

(defun drgnx-ui-look-explorer--row-y (line)
  "The y pixel (in the window's text area) of the middle of the Explorer's LINE-th line.  The row's padding grows
with the scale (the native shell's Lisp pixels are device pixels), so a fixed offset from its top misses the text."
  (with-current-buffer drgnx-explorer-buffer-name
    (goto-char (point-min)) (forward-line (1- line))
    (let ((pos (pos-visible-in-window-p (point) nil t)))
      (+ (cadr pos) (/ (line-pixel-height) 2)))))

(defun drgnx-ui-look-explorer--right-edge (snap line)
  "The x pixel of the right edge of the last mark drawn on the Explorer's LINE-th line: the rightmost pixel in the
row that is not its background, scanning the row from the window's right edge inwards."
  (let* ((s (drgnx-uitest-device-scale (selected-frame))) (e (window-body-pixel-edges))
         (y (round (* s (+ (nth 1 e) (drgnx-ui-look-explorer--row-y line)))))
         (bg (cdr (drgnx-uitest-pixel snap (round (* s (+ (nth 2 e) -2))) y))))
    (cl-loop for x from (round (* s (- (nth 2 e) 2))) downto (round (* s (nth 0 e)))
             unless (equal bg (cdr (drgnx-uitest-pixel snap x y))) return x)))

(drgnx-look-gui-deftest drgnx-ui-look-explorer/a-section-shows-whole-rows ()
  "Pattern D: a dock section with another below it ends at a whole row, so no part of a row (a glyph fragment) is
drawn at its foot; the section below takes the pixels left over, and a second fit changes nothing."
  (skip-unless (display-graphic-p))
  (drgnx-ui-look-explorer--with root
    (let* ((top (selected-window))
           (below (split-window top (+ 7 (round (/ (window-pixel-height top) 2))) 'below t)))
      (dolist (w (list top below))                 ; as the dock's sections are
        (set-window-parameter w 'drgnx-role 'dock)
        (set-window-parameter w 'no-other-window t))
      (unwind-protect
          (let ((total (+ (window-pixel-height top) (window-pixel-height below)))
                (row (- (drgnx-ui-look-explorer--row-y 3) (drgnx-ui-look-explorer--row-y 2))))   ; drawn, not the font's
            (drgnx-wb--rows-whole (selected-frame))
            (should (= 0 (mod (window-body-height top t) row)))
            (should (= total (+ (window-pixel-height top) (window-pixel-height below))))
            (let ((h (window-pixel-height top)))
              (drgnx-wb--rows-whole (selected-frame))
              (should (= h (window-pixel-height top)))))
        (delete-window below)
        (set-window-parameter top 'drgnx-role nil)
        (set-window-parameter top 'no-other-window nil)))))

(drgnx-look-gui-deftest drgnx-ui-look-explorer/a-section-header-is-one-colour-to-the-edge ()
  "Pattern D, window-dark.html `.sec': a section's header row is the bar's colour over the right fringe too (the
rows' inset), not a strip of the header line's own colour at its right end."
  (skip-unless (display-graphic-p))
  (drgnx-ui-look-explorer--with root
    (set-window-parameter nil 'header-line-format (drgnx-wb-section-header "Files"))
    (unwind-protect
        (progn
          (drgnx-test-wait-presented)
          (let* ((snap (drgnx-uitest-snapshot)) (s (drgnx-uitest-device-scale (selected-frame)))
                 (e (window-edges nil nil nil t))
                 (y (round (* s (+ (nth 1 e) (/ (window-header-line-height) 2)))))
                 (bar (mapcar (lambda (c) (round (/ c 257.0))) (color-values (face-background 'drgnx-wb-bar nil t))))
                 (near (lambda (x) (cl-every (lambda (p c) (<= (abs (- p c)) 6)) (cdr (drgnx-uitest-pixel snap x y)) bar))))
            (should (> (cadr (window-fringes)) 0))
            (should (funcall near (round (* s (- (nth 2 e) 2)))))                     ; over the right fringe
            (should (funcall near (round (* s (- (nth 2 e) (cadr (window-fringes)) 2)))))))
      (set-window-parameter nil 'header-line-format nil))))

(drgnx-look-gui-deftest drgnx-ui-look-explorer/row-height ()
  "Pattern D: a row of the Explorer is round (26 x scale) device pixels high at the comfortable density."
  (skip-unless (display-graphic-p))
  (drgnx-ui-look-explorer--with root
    (let ((y2 (drgnx-ui-look-explorer--row-y 2)) (y3 (drgnx-ui-look-explorer--row-y 3)))
      (unless (= (round (* 26 (drgnx-pixels-scale))) (- y3 y2))
        (ert-fail (list 'expected (round (* 26 (drgnx-pixels-scale))) 'got (- y3 y2)
                        'line-spacing (buffer-local-value 'line-spacing (get-buffer drgnx-explorer-buffer-name))
                        'info (font-info (face-font 'drgnx-ui-text nil ?x)) 'cell (frame-char-height)))))))

(drgnx-look-gui-deftest drgnx-ui-look-explorer/row-height-follows-the-density ()
  "Pattern D: after a density change, with no restart, a row of the Explorer is round (H x scale) device pixels high,
H the density's `tree-row' (22 compact, 30 roomy)."
  (skip-unless (display-graphic-p))
  (drgnx-ui-look-explorer--with root
    (let ((was drgnx-look-density) (got nil))
      (drgnx-wb-rows-follow)                ; as the Explorer's setup does
      (unwind-protect
          (dolist (d '(compact roomy))
            (setq drgnx-look-density d)
            (run-hooks 'drgnx-look-density-changed-hook)
            (drgnx-test-wait-presented)
            (push (list d (round (* (drgnx-look-density-value 'tree-row) (drgnx-pixels-scale)))
                        (- (drgnx-ui-look-explorer--row-y 3) (drgnx-ui-look-explorer--row-y 2)))
                  got))
        (setq drgnx-look-density was)
        (run-hooks 'drgnx-look-density-changed-hook)
        (remove-hook 'drgnx-look-density-changed-hook #'drgnx-wb-rows-refresh)
        (drgnx-state-unsubscribe 'windows-changed #'drgnx-wb--rows-frame-changed)
        (drgnx-state-unsubscribe 'frame-resized #'drgnx-wb--rows-frame-changed))
      (should (equal (mapcar (lambda (r) (list (nth 0 r) (nth 1 r))) got)
                     (mapcar (lambda (r) (list (nth 0 r) (nth 2 r))) got))))))

(drgnx-look-gui-deftest drgnx-ui-look-explorer/marks-line-up ()
  "Pattern D: the right edges of the git marks of two rows agree within one device pixel."
  (skip-unless (display-graphic-p))
  (drgnx-ui-look-explorer--with root
    (with-current-buffer drgnx-explorer-buffer-name (goto-char (point-min)))   ; the point row shows its ⋯: not these
    (drgnx-test-wait-presented)
    (let* ((snap (drgnx-uitest-snapshot))
           (a (drgnx-ui-look-explorer--right-edge snap 3)) (b (drgnx-ui-look-explorer--right-edge snap 4)))
      (should a) (should b)
      (should (<= (abs (- a b)) 1)))))

(drgnx-look-gui-deftest drgnx-ui-look-explorer/hover-reveals-the-ellipsis ()
  "Pattern D (sway): the ⋯ of a row that is not at point is drawn in the row's background until the pointer is on
the row, and again after the pointer leaves."
  (skip-unless (display-graphic-p))
  (skip-unless (eq t (drgnx-uitest-pointer-set 0 0)))
  (drgnx-ui-look-explorer--with root
    (with-current-buffer drgnx-explorer-buffer-name (goto-char (point-min)))
    (drgnx-test-wait-presented)
    (let* ((s (drgnx-uitest-device-scale (selected-frame))) (e (window-body-pixel-edges))
           (y (drgnx-ui-look-explorer--row-y 4))
           (px-y (round (* s (+ (nth 1 e) y)))) (x1 (round (* s (- (nth 2 e) 14)))) (x0 (round (* s (- (nth 2 e) 40))))
           (fg (mapcar (lambda (c) (round (* 255 c))) (drgnx-color-rgb (drgnx-look-token 'fg 'dark))))
           (has-fg (lambda ()
                     (let ((snap (drgnx-uitest-snapshot)))
                       (cl-loop for x from x0 to x1
                                thereis (cl-loop for yy from (- px-y 4) to (+ px-y 4)
                                                 thereis (cl-every (lambda (p c) (<= (abs (- p c)) 24))
                                                                   (cdr (drgnx-uitest-pixel snap x yy)) fg)))))))
      (should-not (funcall has-fg))
      (should (eq t (drgnx-uitest-pointer-set (round (/ (+ x0 x1) 2.0 s)) (round (/ px-y s)))))
      (drgnx-uitest-run nil)
      (drgnx-test-wait-presented)
      (skip-unless (cadr (mouse-pixel-position)))
      (should (funcall has-fg)))))

(drgnx-look-gui-deftest drgnx-ui-look-explorer/the-selected-row-is-one-inset-run ()
  "Pattern D, window-dark.html `.row.sel.focus': the focused selection is one fill from the card's inset to the inset
on the right (the tail does not open a gap, and nothing runs past the row), the fringes either side in the panel's
colour, 6 logical pixels wide; under Glitnir its corners are rounded (the corner pixel is not the fill)."
  (skip-unless (display-graphic-p))
  (drgnx-ui-look-explorer--with root
    (with-current-buffer drgnx-explorer-buffer-name
      (goto-char (point-min)) (forward-line 2) (drgnx-wb-selection-sync))
    (drgnx-test-wait-presented)
    (let* ((snap (drgnx-uitest-snapshot)) (s (drgnx-uitest-device-scale (selected-frame)))
           (e (window-body-pixel-edges))
           (top (with-current-buffer drgnx-explorer-buffer-name
                  (save-excursion (goto-char (point-min)) (forward-line 2)
                                  (cadr (pos-visible-in-window-p (point) nil t)))))
           ;; the row's middle: clear of the rounded corners and the ring (no text so near either edge)
           (y (round (* s (+ (nth 1 e) (drgnx-ui-look-explorer--row-y 3)))))
           (rgb (lambda (token) (mapcar (lambda (c) (round (* 255 c))) (drgnx-color-rgb (drgnx-look-token token 'dark)))))
           (near (lambda (x yy token) (cl-every (lambda (p c) (<= (abs (- p c)) 6))
                                                (cdr (drgnx-uitest-pixel snap x yy)) (funcall rgb token))))
           (left (round (* s (nth 0 e)))) (right (round (* s (nth 2 e)))))
      (should (= (drgnx-px 6) (car (window-fringes))))
      (should (= (drgnx-px 6) (cadr (window-fringes))))
      (should (funcall near (- left 2) y 'panel))                        ; the left fringe
      (should (funcall near (+ left (round (* 3 s))) y 'sel))            ; the fill starts at the inset
      (should (funcall near (- right (round (* 3 s))) y 'sel))           ; and reaches the right inset: no tail gap
      (should (funcall near (+ right 1) y 'panel))                       ; the right fringe
      (when (and (fboundp 'glitnir-active-p) (glitnir-active-p))
        (should-not (funcall near left (round (* s (+ (nth 1 e) top))) 'sel))))))

(drgnx-look-gui-deftest drgnx-ui-look-explorer/the-focused-row-is-ringed ()
  "Pattern D, window-dark.html `.row.sel.focus' (`box-shadow: inset 0 0 0 1px var(--focus)'): with the Explorer
focused, the selected row is ringed in the focus colour on its left, top and right (the right side at the text
area's edge, after the tail), and the ring has no seam where the row's text meets its tail (the fill there, above the
text, is the selection's)."
  (skip-unless (and (display-graphic-p) (fboundp 'glitnir-active-p) (glitnir-active-p)))
  (drgnx-ui-look-explorer--with root
    (with-current-buffer drgnx-explorer-buffer-name
      (goto-char (point-min)) (forward-line 2) (drgnx-wb-selection-sync))
    (drgnx-test-wait-presented)
    (let* ((snap (drgnx-uitest-snapshot)) (s (drgnx-uitest-device-scale (selected-frame)))
           (e (window-body-pixel-edges))
           (row (with-current-buffer drgnx-explorer-buffer-name
                  (save-excursion (goto-char (point-min)) (forward-line 2)
                                  ;; the seam: where the name's last character ends (the newline is after the tail)
                                  (let ((last (posn-at-point (1- (pos-eol)))))
                                    (list (cadr (pos-visible-in-window-p (point) nil t))
                                          (+ (car (posn-x-y last)) (car (posn-object-width-height last))))))))
           (y (round (* s (+ (nth 1 e) (drgnx-ui-look-explorer--row-y 3)))))
           (above (round (* s (+ (nth 1 e) (nth 0 row) 4))))
           (rgb (lambda (token) (mapcar (lambda (c) (round (* 255 c))) (drgnx-color-rgb (drgnx-look-token token 'dark)))))
           (near (lambda (x yy token) (cl-every (lambda (p c) (<= (abs (- p c)) 6))
                                                (cdr (drgnx-uitest-pixel snap x yy)) (funcall rgb token))))
           (left (round (* s (nth 0 e)))) (right (round (* s (nth 2 e))))
           (seam (round (* s (+ (nth 0 e) (nth 1 row)))))
           (top (round (* s (+ (nth 1 e) (nth 0 row)))))
           ;; the ring within 3 logical pixels of an edge (where the snapping puts a 1 px line), inward by DX, DY;
           ;; else the pixels seen, for the failure
           (ringed (lambda (x0 y0 dx dy)
                     (or (cl-loop for i from 0 to (round (* 3 s))
                                  thereis (funcall near (+ x0 (* i dx)) (+ y0 (* i dy)) 'focus))
                         (list x0 y0 (car snap) (cl-loop for i from -4 to (round (* 8 s))
                                                         for x = (+ x0 (* i dx)) for yy = (+ y0 (* i dy))
                                                         when (and (< -1 x (car snap)) (< -1 yy (cadr snap)))
                                                         collect (cdr (drgnx-uitest-pixel snap x yy))))))))
      (should (eq t (funcall ringed left y 1 0)))
      (should (eq t (funcall ringed (1- right) y -1 0)))
      ;; the box's top: the first pixel below the row's top (its spacing is the panel) that is not the panel
      (should (eq t (let ((x (+ seam (round (* 4 s)))))
                      (cl-loop for yy from top to y
                               unless (funcall near x yy 'panel)
                               return (or (funcall near x yy 'focus) (list x yy (cdr (drgnx-uitest-pixel snap x yy))))
                               finally return (list x 'no-box)))))
      (dolist (x (list (1- seam) seam (1+ seam)))
        (should (equal (list 'seam x 'sel) (list 'seam x (and (funcall near x above 'sel) 'sel))))))))

(provide 'look-explorer-gui-test)
;;; look-explorer-gui-test.el ends here
