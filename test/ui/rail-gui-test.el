;;; rail-gui-test.el --- GUI tests: the layout A rail beside the side bar and under the status bar (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; The rail is a left side window outside the grid, 44 logical px wide at every scale; the status bar across the frame
;; splits the root, so it spans the frame under the rail and the grid's root is the editor area between them.  Each
;; item is its 32 px row.  Pattern D: every measurement is taken after `drgnx-test-wait-presented'.

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-look-gui-fixture (expand-file-name "../fixtures/look-gui-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-rail-ui-test--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness" "themes"))
  (add-to-list 'load-path (expand-file-name d drgnx-rail-ui-test--repo)))
(require 'drgnx)
(require 'drgnx-state)
(require 'drgnx-theme-gen)
(dolist (m '("drgnx-look-scale" "drgnx-statusbar" "drgnx-rail"))
  (load (expand-file-name (concat "modules/ui/" m) drgnx-rail-ui-test--repo) nil t))

(declare-function drgnx-look-scale-apply-frame "drgnx-look-scale" (frame percent))
(declare-function drgnx-look-scale--roots "drgnx-look-scale" ())
(declare-function drgnx-look-scale--follow "drgnx-look-scale" ())
(declare-function drgnx-grid-root "drgnx-grid" (&optional frame))

(defun drgnx-rail-ui-test--window (role)
  (seq-find (lambda (w) (eq (window-parameter w 'drgnx-role) role)) (window-list nil 'nomini)))

(load (expand-file-name "test/fixtures/grid-fixture" drgnx-rail-ui-test--repo) nil t)

(defmacro drgnx-rail-ui-test--with-rail (&rest body)
  "BODY on a frame of its own with the grid fixture (the grid backend), the status bar across it and the rail on;
every frame BODY made deleted after, the modes as they were."
  (declare (indent 0))
  `(let* ((frames (frame-list)) (selected (selected-frame)) (frame (make-frame '((width . 160) (height . 50)))))
     (unwind-protect
         (with-selected-frame frame
           (drgnx-grid-test--with
             (let ((drgnx-statusbar-place 'frame) (drgnx-statusbar-mode t) (rail-was drgnx-rail-mode))   ; the bar's variable only: no mode function, no chrome of the session's frames
               (drgnx-test-wait (lambda () (redisplay t) (frame-visible-p frame)) :secs 10 :what "the frame mapped")
               (unwind-protect
                   (progn (drgnx-state-define-role 'statusbar)
                          (drgnx-rail-mode 1)
                          (drgnx-rail--ensure frame)
                          (drgnx-statusbar--frame-ensure frame)
                          (drgnx-test-wait-presented :frame frame)
                          ,@body)
                 (drgnx-rail-mode (if rail-was 1 -1))))))
       (dolist (f (frame-list)) (unless (memq f frames) (delete-frame f t)))
       (when (frame-live-p selected) (select-frame selected)))))

(defun drgnx-rail-ui-test--check-geometry ()
  "The rail's width, its place beside the bar and the grid's root, and its items' rows, at the frame's scale."
  (let* ((frame (selected-frame)) (rail (drgnx-rail-ui-test--window 'rail)) (bar (drgnx-rail-ui-test--window 'statusbar)))
    (unless rail
      (ert-fail (format "no rail: workbench %S grid %S backend %S hidden %S mode %S windows %S"
                        (drgnx-state-workbench-frame-p frame) (drgnx-wb-grid-p) (bound-and-true-p drgnx-pane-backend)
                        (frame-parameter frame 'drgnx-rail) drgnx-rail-mode
                        (mapcar (lambda (w) (list (window-parameter w 'drgnx-role) (window-parameter w 'window-side)))
                                (window-list frame 'nomini)))))
    (should (eq 'left (window-parameter rail 'window-side)))
    ;; the items are 44 logical px wide: the text area is, whatever the window has round it (the gap's divider)
    (should (= (drgnx-px drgnx-rail-width frame) (window-body-width rail t)))
    (should (= 0 (nth 0 (window-pixel-edges rail))))
    ;; the 6 px inset, then each item its 32 px row and the 6 px gap below it: the tops of the lines, top down
    (let* ((item (drgnx-px 32 frame)) (gap (drgnx-px 6 frame))
           (tops (with-current-buffer (window-buffer rail)
                   (save-excursion
                     (goto-char (point-min))
                     (cl-loop until (eobp) collect (cdr (posn-x-y (posn-at-point (point) rail)))
                              do (forward-line 1)))))
           (heights (cl-loop for (a b) on tops while b collect (- b a))))
      (should (equal (list gap) (list (car heights))))
      ;; no item is wider than the window's text area (a line as wide as the window is cut off): each is narrower than
      ;; the text area
      (let ((body (window-body-width rail t))
            (widths (with-current-buffer (window-buffer rail)
                      (save-excursion
                        (goto-char (point-min))
                        (cl-loop until (eobp)
                                 when (> (- (line-end-position) (line-beginning-position)) 1)
                                 collect (car (window-text-pixel-size rail (line-beginning-position) (line-end-position)))
                                 do (forward-line 1))))))
        (should (equal (list 'cut nil)
                       (list 'cut (and (seq-some (lambda (w) (>= w body)) widths) (list 'body body 'widths widths))))))
      ;; heights: gap, item, gap, item, ...
      (should (equal (cl-loop for i from 1 below (* 2 (length drgnx-rail-places)) collect (if (cl-oddp i) item gap))
                     (seq-take (cdr heights) (1- (* 2 (length drgnx-rail-places)))))))
    (when bar
      ;; the bar spans the frame and is under the rail
      (should (= (window-pixel-width bar) (window-pixel-width (frame-root-window frame))))
      (should (= 0 (nth 0 (window-pixel-edges bar))))
      (should (<= (nth 3 (window-pixel-edges rail)) (nth 1 (window-pixel-edges bar))))
      (when (fboundp 'drgnx-grid-root)
        (let ((root (drgnx-grid-root frame)))
          (should (>= (nth 0 (window-pixel-edges root)) (nth 2 (window-pixel-edges rail))))
          (should (<= (nth 3 (window-pixel-edges root)) (nth 1 (window-pixel-edges bar)))))))))

(defun drgnx-rail-ui-test--rgb (hex)
  "HEX as the (A R G B) a snapshot gives."
  (cons 255 (mapcar (lambda (i) (string-to-number (substring hex i (+ i 2)) 16)) '(1 3 5))))

(defun drgnx-rail-ui-test--check-pictures (rail)
  "At a UI scale of 100 %: the current item (the first) has its accent bar down the cell's left edge and the cell's
fill beside it; the changed one (Changes, the fourth) has the warn dot on its cell's top right corner.  Offsets are
logical px from the rail's text area (the item: 6 inset, 8 icon inset, 16 icon, 8 right inset; its row 32 high)."
  (let* ((frame (window-frame rail)) (s (drgnx-uitest-device-scale frame)) (edges (window-inside-pixel-edges rail))
         (variant (drgnx-look-variant frame))
         (line (lambda (i) (with-current-buffer (window-buffer rail)
                             (save-excursion (goto-char (point-min)) (forward-line (1+ (* 2 i))) (point)))))
         (snap (drgnx-uitest-snapshot frame))
         (at (lambda (i dx dy)
               (let ((top (cdr (posn-x-y (posn-at-point (funcall line i) rail)))))
                 (drgnx-uitest-pixel snap (round (* s (+ (car edges) dx))) (round (* s (+ (cadr edges) top dy))))))))
    (should (= 1 (drgnx-pixels-scale frame)))
    ;; an SVG picture is antialiased and colour-managed: a pixel inside it is its colour to within 16 a channel (the cell's
    ;; fill is the kit sheet's row: `drgnx-kit-sheet/rail-item' reads it per pad)
    (cl-flet ((near (want got) (if (cl-every (lambda (a b) (<= (abs (- a b)) 16)) want got) want got)))
      ;; (the dot is read in the scenes' pictures: its place on the cell's corner is a look, not a pixel)
      (let ((bar (drgnx-rail-ui-test--rgb (drgnx-look-token 'accent variant)))
            ;; the surface's colour beside the cell (the last 6 px of the text area, where a truncation `$' is drawn
            ;; over a line the window cannot end), read in the gap above the first item
            (surface (funcall at 0 43 -3)))
        (should (equal (list 'bar bar) (list 'bar (near bar (funcall at 0 7 16)))))
        (should (equal (list 'beside-the-cell nil)
                       (list 'beside-the-cell
                             (cl-find-if-not (lambda (p) (equal p surface))
                                             (cl-loop for dx from 39 to 43
                                                      append (cl-loop for dy from 4 to 28 collect (funcall at 0 dx dy)))))))))))

(drgnx-look-gui-deftest drgnx-rail-ui/rail-is-44-px-at-every-scale ()
  "The rail is 44 logical px wide at the run's scale and at a UI scale of 125 %, sits above the status bar, which still
spans the frame, and the grid's root is right of it and above the bar."
  (skip-unless (display-graphic-p))
  (drgnx-rail-ui-test--with-rail
    ;; a current place (its accent bar) and a changed one (its dot): the picture parts are as high as the rest
    (set-frame-parameter nil 'drgnx-rail-place 'work)
    (drgnx-rail-mark-changed 'changes)
    (drgnx-rail-ui-test--check-geometry)
    (when (= 1 (drgnx-pixels-scale)) (drgnx-rail-ui-test--check-pictures (drgnx-rail-ui-test--window 'rail)))
    (unwind-protect
        (progn
          (drgnx-look-scale-apply-frame (selected-frame) 125)
          (drgnx-look-scale--follow)               ; as a setting or a zoom key does: the rail follows
          (drgnx-test-wait-presented)
          (drgnx-statusbar--frame-ensure (selected-frame))
          (drgnx-test-wait-presented)
          (drgnx-rail-ui-test--check-geometry))
      (dolist (f (drgnx-look-scale--roots)) (drgnx-look-scale-apply-frame f 100))
      (drgnx-look-scale--follow)
      (drgnx-rail-clear-changed 'changes)
      (set-frame-parameter nil 'drgnx-rail-place nil))))

(provide 'rail-gui-test)
;;; rail-gui-test.el ends here
