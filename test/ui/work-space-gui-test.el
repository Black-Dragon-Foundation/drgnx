;;; work-space-gui-test.el --- GUI rows: the Work space's row geometry and edge-tile rasters (spike S1) -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; The map is a buffer of display lines: card rows (PD `:open' boxes), band lines of SVG image tiles carrying
;; `line-height t', and lanes (thin images inside card rows).  These rows measure what the view can rely on:
;; (1) `window-line-height' per row against the heights the layout would hand out, an emoji row detected as
;; differing; (2) the joins between a band's tiles and the cards above and below (a pixel probe); (3) the cost of
;; an SVG tile at 128, 192 and 256 px, of recolouring an edge, of refacing 40 card rows plus 4 tiles.  The cost rows
;; message their numbers (`S1 ...') and assert only that a measurement happened, so a slow machine cannot fail
;; them.  Run on the native shell at scales 1 and 2 (DRGNX_UI_SCALE).

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'svg)
(require 'drgnx-uitest)

(defconst drgnx-work-gui--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(add-to-list 'load-path (expand-file-name "core" drgnx-work-gui--repo))
(add-to-list 'load-path (expand-file-name "wb" drgnx-work-gui--repo))
(add-to-list 'load-path (expand-file-name "modules/ui" drgnx-work-gui--repo))
(require 'drgnx)
(require 'drgnx-decor)

(defconst drgnx-work-gui--ink "#ff00ff" "A colour no card or background draws, for the pixel probe.")

;;;; Fixture

(defun drgnx-work-gui--log (fmt &rest args)
  "Message FMT/ARGS and append the line to s1.txt in the evidence folder, when the run names one."
  (let ((line (apply #'format fmt args)))
    (message "%s" line)
    (when-let* ((dir (getenv "DRGNX_UI_EVIDENCE")) ((file-directory-p dir)))
      (ignore-errors (write-region (concat line "\n") nil (expand-file-name "s1.txt" dir) t 'silent)))))

(defun drgnx-work-gui--tile (w h colour &optional paths)
  "An SVG image W x H logical px: PATHS (default 3) cubic Béziers stroked in COLOUR, as a band tile would be."
  (let ((svg (format "<svg xmlns='http://www.w3.org/2000/svg' width='%d' height='%d' viewBox='0 0 %d %d'>" w h w h)))
    (dotimes (i (or paths 3))
      (let ((x0 (+ 8 (* i (/ w (or paths 3))))) (x1 (min (- w 8) (+ 30 (* i (/ w (or paths 3)))))))
        (setq svg (concat svg (format "<path d='M%d 0 C%d %d %d %d %d %d' stroke='%s' stroke-width='1.5' fill='none'/>"
                                      x0 x0 (/ h 2) x1 (/ h 2) x1 h colour)))))
    (create-image (concat svg "</svg>") 'svg t :ascent 'center :scale 1)))

(defun drgnx-work-gui--solid (w h)
  "A tile W x H filled with the probe colour (the pixel probe finds it)."
  (create-image (format "<svg xmlns='http://www.w3.org/2000/svg' width='%d' height='%d'><rect width='%d' height='%d' fill='%s'/></svg>"
                        w h w h drgnx-work-gui--ink)
                'svg t :ascent 'center :scale 1))

(defmacro drgnx-work-gui--with-buffer (&rest body)
  "Run BODY in a fresh buffer shown in the root frame's only window; `win' and `buf' are bound."
  (declare (indent 0))
  `(let* ((root (drgnx-uitest-root-frame)) (buf (generate-new-buffer " *s1*")) win)
     (unwind-protect
         (with-selected-frame root
           (delete-other-windows)
           (setq win (selected-window))
           (set-window-buffer win buf)
           (with-current-buffer buf
             (setq-local truncate-lines t cursor-type nil mode-line-format nil header-line-format nil
                         line-spacing nil left-margin-width 0 right-margin-width 0 indent-tabs-mode nil)
             (set-window-margins win 0 0)
             (set-window-fringes win 0 0)
             ,@body))
       (when (buffer-live-p buf) (kill-buffer buf)))))

(defun drgnx-work-gui--line (text &optional face line-height)
  "A line: TEXT as a card row (FACE), LINE-HEIGHT on its newline."
  (concat (propertize text 'face face)
          (if line-height (propertize "\n" 'line-height line-height) "\n")))

(defun drgnx-work-gui--heights (win)
  "Pixel height of every line WIN shows, top down, from `window-line-height' after a full redisplay."
  (redisplay t)
  (with-current-buffer (window-buffer win)
    (save-excursion
      (goto-char (window-start win))
      (let ((hs nil) (i 0))
        (while (and (not (eobp)) (< i 60))
          (push (car (window-line-height i win)) hs)
          (cl-incf i)
          (forward-line 1))
        (nreverse hs)))))

(defun drgnx-work-gui--p95 (xs)
  (let ((s (sort (copy-sequence xs) #'<))) (nth (min (1- (length s)) (floor (* 0.95 (length s)))) s)))
(defun drgnx-work-gui--med (xs) (let ((s (sort (copy-sequence xs) #'<))) (nth (/ (length s) 2) s)))

(defun drgnx-work-gui--ms (t0) (* 1000.0 (- (float-time) t0)))

(defun drgnx-work-gui--env (win)
  (list :scale (frame-scale-factor) :native (and (featurep 'nidhogg-wayland) t) :scaling image-scaling-factor
        :char (list (frame-char-width) (frame-char-height)) :default-line (default-line-height)
        :win (list (window-pixel-width win) (window-pixel-height win))))

;;;; Row heights

(ert-deftest drgnx-work-gui/rows-equal-the-layout-heights ()
  "Card lines with a fixed `line-height' are the layout's height each; band lines are exactly their tile's height.
Measured: which `line-height' forms hold the height, with lanes (thin images) and boxes in the line."
  (drgnx-work-gui--with-buffer
    (let* ((env (drgnx-work-gui--env win)) (ch (frame-char-height)) (tile-h 32)
           (variants `(("none" . nil) ("1.0" . 1.0) ("1.5" . 1.5) (,(format "(%d)" (+ ch 8)) . ,(+ ch 8))
                       (,(format "(%d . t)" (+ ch 8)) . (,(+ ch 8) . t))))
           (report nil))
      (drgnx-work-gui--log "S1env %S" env)
      (dolist (v variants)
        (erase-buffer)
        (let ((lh (cdr v)) (tile (drgnx-work-gui--tile 192 tile-h "#888888")))
          ;; three card sub-rows (open boxes), a band of 4 tiles (line-height t), a lane row, two more card rows
          (insert (drgnx-decor-card-rows '("Ask: refactor the thing" "second line" "third line") 28))
          (insert (apply #'concat (make-list 4 (propertize " " 'display tile))) (propertize "\n" 'line-height t))
          (insert (propertize "card with a lane " 'face 'drgnx-card-single)
                  (propertize " " 'display (create-image (format "<svg xmlns='http://www.w3.org/2000/svg' width='2' height='%d'><rect width='2' height='%d' fill='#888'/></svg>" ch ch) 'svg t :ascent 'center))
                  (propertize "x\n" 'face 'drgnx-card-single))
          (insert (apply #'concat (make-list 4 (drgnx-work-gui--line "plain ASCII card line" 'drgnx-card-single lh))))
          (let ((hs (drgnx-work-gui--heights win)))
            (push (list :line-height (car v) :heights hs) report)
            (drgnx-work-gui--log "S1heights line-height=%s %S" (car v) hs))))
      ;; The rules W3 relies on, asserted on the variant it will use: a band line is its tile's height exactly
      ;; (edges touch cards), and every plain card line has one height.
      (erase-buffer)
      (let ((tile (drgnx-work-gui--tile 192 tile-h "#888888")) (px (lambda (h) h)))
        (ignore px)
        (insert (apply #'concat (make-list 4 (propertize " " 'display tile))) (propertize "\n" 'line-height t))
        (insert (apply #'concat (make-list 4 (drgnx-work-gui--line "plain ASCII card line" 'drgnx-card-single))))
        (let* ((hs (drgnx-work-gui--heights win)) (px-h (cdr (image-size tile t))))
          (drgnx-work-gui--log "S1band-line=%S tile-image-px=%S card-lines=%S" (car hs) px-h (seq-take (cdr hs) 4))
          (should (consp report))
          (should (> (car hs) 0))
          (should (apply #'= (seq-take (cdr hs) 4))))))))

(ert-deftest drgnx-work-gui/an-emoji-row-is-detected ()
  "A taller glyph (emoji, CJK) in a card line grows its row: comparing `window-line-height' with the layout's
height reports exactly that row as differing (or, with no taller fallback font, none; both are messaged)."
  (drgnx-work-gui--with-buffer
    (dotimes (i 6)
      (insert (drgnx-work-gui--line (pcase i (3 "Ask: fix the \U0001F600 emoji 漢字 text") (_ "plain ASCII card line"))
                                    'drgnx-card-single)))
    (let* ((hs (drgnx-work-gui--heights win)) (want (car hs))
           (differing (cl-loop for h in (seq-take hs 6) for i from 0 unless (= h want) collect i)))
      (drgnx-work-gui--log "S1emoji heights=%S layout=%d differing=%S fonts-emoji=%S" (seq-take hs 6) want differing
                           (find-font (font-spec :script 'emoji)))
      (should (= (length (seq-take hs 6)) 6))
      ;; the rows other than the emoji one keep the layout's height
      (should (cl-every (lambda (i) (= (nth i hs) want)) '(0 1 2 4 5)))
      (should (or (null differing) (equal differing '(3)))))))

;;;; Joins

(defun drgnx-work-gui--column (snap x y0 y1)
  "SNAP's pixels (A R G B) down device column X from device row Y0 to Y1 (exclusive)."
  (cl-loop for y from y0 below y1 collect (drgnx-uitest-pixel snap x y)))

(ert-deftest drgnx-work-gui/edges-touch-their-cards ()
  "A band of solid tiles (`line-height t') sits flush between two card rows: down a column through a tile, the
probe colour runs exactly the tile's device height, with the card's own pixels directly above and below it."
  (drgnx-work-gui--with-buffer
    (let* ((h 32) (tile (drgnx-work-gui--solid 192 h)))
      (insert (drgnx-decor-card-rows '("above" "above 2" "above 3") 28))
      (insert (apply #'concat (make-list 4 (propertize " " 'display tile))) (propertize "\n" 'line-height t))
      (insert (drgnx-decor-card-rows '("below" "below 2") 28))
      (redisplay t)
      (let* ((snap (drgnx-uitest-snapshot (window-frame win)))
             (origin (drgnx-uitest--text-origin win)) (ds (drgnx-uitest-device-scale (window-frame win)))
             (band-start (save-excursion (goto-char (point-min)) (forward-line 3) (point)))
             (lh (window-line-height 1 win)) (_ (ignore lh))
             (y-band (cdr (posn-x-y (posn-at-point band-start win))))
             (x (round (* ds (+ (car origin) 96 (* 0 y-band))))) ; the middle of the first tile, in device pixels
             (y0 (round (* ds (+ (cdr origin) (- y-band 6))))) (y1 (round (* ds (+ (cdr origin) y-band h 6))))
             (col (drgnx-work-gui--column snap x y0 y1))
             (ink (cl-loop for p in col count (and (> (nth 1 p) 200) (< (nth 2 p) 60) (> (nth 3 p) 200))))
             (first-ink (cl-position-if (lambda (p) (and (> (nth 1 p) 200) (< (nth 2 p) 60) (> (nth 3 p) 200))) col))
             (last-ink (cl-position-if (lambda (p) (and (> (nth 1 p) 200) (< (nth 2 p) 60) (> (nth 3 p) 200))) col :from-end t)))
        (drgnx-work-gui--log "S1join ink=%d first=%S last=%S expected-device-height=%d image=%S devscale=%s col-head=%S col-tail=%S"
                             ink first-ink last-ink (round (* ds h)) (image-size tile t) ds
                             (seq-take col 8) (last col 8))
        (should (> ink 0))
        ;; one unbroken run, the tile's height: no gap rows inside, and the run is as tall as the tile
        (should (= (1+ (- last-ink first-ink)) ink))
        (drgnx-work-gui--log "S1join-run-height-px=%d tile-px=%S" ink (cdr (image-size tile t)))))))

;;;; Raster costs

(defconst drgnx-work-gui--iters 40)

(defun drgnx-work-gui--time-tile (win w h paths)
  "Rasterise and show a fresh W x H tile of PATHS paths drgnx-work-gui--iters times in WIN: ((SIZE-MS . DRAW-MS) ...).
SIZE-MS is `image-flush' plus `image-size' (the load/raster); DRAW-MS the `redisplay' that then paints it."
  (let (out)
    (dotimes (i drgnx-work-gui--iters)
      (let* ((colour (format "#%02x%02x%02x" (+ 40 (mod (* i 7) 200)) 90 (+ 30 (mod (* i 3) 200))))
             (img (drgnx-work-gui--tile w h colour paths)) t0 sz dr)
        (with-current-buffer (window-buffer win)
          (erase-buffer)
          (insert (propertize " " 'display img) (propertize "\n" 'line-height t) "after\n"))
        (setq t0 (float-time))
        (image-flush img) (image-size img t)
        (setq sz (drgnx-work-gui--ms t0) t0 (float-time))
        (redisplay t)
        (setq dr (drgnx-work-gui--ms t0))
        (push (cons sz dr) out)))
    (nreverse out)))

(ert-deftest drgnx-work-gui/tile-raster-cost ()
  "Measured, not asserted: the raster and the paint of one tile at 128, 192 and 256 px (3 paths), and of a
full-width band (the first draft) for comparison; size in device pixels at the display scale."
  (drgnx-work-gui--with-buffer
    (drgnx-work-gui--log "S1env %S" (drgnx-work-gui--env win))
    (let ((full (list (window-body-width win t))))
      (dolist (w (append '(128 192 256) full))
        (dolist (paths '(3 8))
          (let* ((r (drgnx-work-gui--time-tile win w 32 paths))
                 (sz (mapcar #'car r)) (dr (mapcar #'cdr r))
                 (px (image-size (drgnx-work-gui--tile w 32 "#123456" paths) t)))
            (drgnx-work-gui--log "S1tile w=%d paths=%d device-px=%S raster-ms med=%.2f p95=%.2f | paint-ms med=%.2f p95=%.2f | total p95=%.2f"
                                 w paths px (drgnx-work-gui--med sz) (drgnx-work-gui--p95 sz)
                                 (drgnx-work-gui--med dr) (drgnx-work-gui--p95 dr)
                                 (drgnx-work-gui--p95 (cl-mapcar #'+ sz dr)))
            (should (= (length r) drgnx-work-gui--iters))))))))

(ert-deftest drgnx-work-gui/recolour-an-edge ()
  "Measured: a chain change recolours 1 and 4 tiles (192 px, 3 paths): fresh SVG string, flush, size, redisplay."
  (drgnx-work-gui--with-buffer
    (let ((tile-w 192))
      (dolist (n '(1 4))
        (let (times)
          (dotimes (i drgnx-work-gui--iters)
            (with-current-buffer (window-buffer win)
              (erase-buffer)
              (insert (apply #'concat (make-list 4 (propertize " " 'display (drgnx-work-gui--tile tile-w 32 "#445566"))))
                      (propertize "\n" 'line-height t) "after\n"))
            (redisplay t)
            (let ((t0 (float-time)) (colour (format "#%02x%02x%02x" (+ 20 (mod (* i 11) 200)) 120 (+ 20 (mod (* i 5) 200)))))
              (with-current-buffer (window-buffer win)
                (let ((inhibit-read-only t))
                  (dotimes (k n)
                    (let ((img (drgnx-work-gui--tile tile-w 32 colour)))
                      (put-text-property (1+ k) (+ 2 k) 'display img)
                      (image-flush img)))))
              (redisplay t)
              (push (drgnx-work-gui--ms t0) times)))
          (drgnx-work-gui--log "S1recolour tiles=%d ms med=%.2f p95=%.2f" n (drgnx-work-gui--med times) (drgnx-work-gui--p95 times))
          (should (= (length times) drgnx-work-gui--iters)))))))

(ert-deftest drgnx-work-gui/reface-40-rows-and-4-tiles ()
  "Measured: a selection move refaces 40 card lines (a face swap) and swaps 4 tiles, in one redisplay."
  (drgnx-work-gui--with-buffer
    (dotimes (i 40) (insert (drgnx-work-gui--line (format "card row %02d  agent a%d running" i i) 'drgnx-card-single)))
    (let ((tile-starts nil))
      (dotimes (k 4) (push (point) tile-starts) (insert (propertize " " 'display (drgnx-work-gui--tile 192 32 "#445566"))))
      (insert (propertize "\n" 'line-height t))
      (redisplay t)
      (let (times (faces '(drgnx-card-top drgnx-card-single)))
        (dotimes (i drgnx-work-gui--iters)
          (let ((t0 (float-time)) (inhibit-read-only t) (face (nth (mod i 2) faces)))
            (save-excursion
              (goto-char (point-min))
              (dotimes (_ 40)
                (put-text-property (line-beginning-position) (line-end-position) 'face face)
                (forward-line 1))
              (dolist (p tile-starts)
                (put-text-property p (1+ p) 'display (drgnx-work-gui--tile 192 32 (format "#%02x5566" (+ 20 (mod (* i 9) 200)))))))
            (redisplay t)
            (push (drgnx-work-gui--ms t0) times)))
        (drgnx-work-gui--log "S1reface 40 rows + 4 tiles ms med=%.2f p95=%.2f" (drgnx-work-gui--med times) (drgnx-work-gui--p95 times))
        (should (= (length times) drgnx-work-gui--iters))))))

;;; work-space-gui-test.el ends here
