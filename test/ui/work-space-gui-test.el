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
;; The motion rows drive the map's side of Glitnir's layout leg against the real presenter, which announces that it
;; holds the old picture (`glitnir-layout-captured-p'): a layout the user asks for moves, one whose picture is not
;; held jumps, reduced motion asks for nothing, a live arrival never moves the map, and keys stay fast during a leg.
;; They run on the hub's rows: the map of the 30-agent workspace (test/fixtures/work-space-thirty-fixture.el, a
;; test-hooks ratatoskr with ratatoskr-mock beside it, every agent streaming), with its first eight agents so the layout
;; fits at scale 2 too (a layout that does not fit is the outline, which never moves), so they need Sjá.

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
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-work-gui--repo) nil t)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-work-gui--repo) nil t)

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

;;;; Motion: the map's side of the layout leg

(defvar drgnx-view)
(defvar drgnx-view-patch)
(defvar drgnx-work-map--motion)
(defvar drgnx-work-map--asked)
(defvar drgnx-work-map-motion-stats)
(defvar drgnx-work-map-motion-duration)
(defvar drgnx-work-thirty--agents)
(defvar drgnx-work-thirty--mirrors)
(defvar glitnir-reduced-motion)
(declare-function drgnx-work-map-collapse-layer "drgnx-work-map")
(declare-function drgnx-work-map-right "drgnx-work-map")
(declare-function drgnx-work-map-left "drgnx-work-map")
(declare-function drgnx-work-map--margin-px "drgnx-work-map")
(declare-function drgnx-work-map--px "drgnx-work-map")
(declare-function drgnx-work-map--motion-begin "drgnx-work-map")
(declare-function drgnx-work-map--drawn-ids "drgnx-work-map")
(declare-function drgnx-work-map-motion-clear "drgnx-work-map")
(declare-function drgnx-view-draw-now "drgnx-view")
(declare-function drgnx-view-touch "drgnx-view")
(declare-function drgnx-view-pending-p "drgnx-view")
(declare-function drgnx-view-stats "drgnx-view")
(declare-function drgnx-view-key-at "drgnx-view")
(declare-function drgnx-view-patch-handle "drgnx-view")
(declare-function drgnx-view-patch-version "drgnx-view")
(declare-function drgnx-view-patch-stale "drgnx-view")
(declare-function drgnx-view-patch-resync "drgnx-view")
(declare-function drgnx-agents-mirror-start "drgnx-agents-mirror")
(declare-function drgnx-agents-send "drgnx-agents")
(declare-function nidhogg-view-get "nidhogg-views")
(declare-function glitnir-layout-captured-p "glitnir")
(declare-function nhwl-presenter-stats "nhwlterm.c")

(load (expand-file-name "test/fixtures/work-space-thirty-fixture" drgnx-work-gui--repo) nil t)

(declare-function drgnx-work-thirty-start "work-space-thirty-fixture")
(declare-function drgnx-work-thirty-stop "work-space-thirty-fixture")
(declare-function drgnx-work-thirty-map "work-space-thirty-fixture")
(declare-function drgnx-work-thirty-agent-items "work-space-thirty-fixture")
(declare-function drgnx-work-thirty-premise "work-space-thirty-fixture")

(defun drgnx-work-gui--leg-p ()
  "Non-nil where the map can move: Glitnir draws the root frame and has the layout leg (Nidhogg with it)."
  (and (drgnx-uitest-glitnir-p) (fboundp 'glitnir-layout-captured-p)))

(defun drgnx-work-gui--stat (key) (plist-get drgnx-work-map-motion-stats key))

(defun drgnx-work-gui--rows-p ()
  "Non-nil where the map is on the hub's rows: a graphical frame and Sjá."
  (and (display-graphic-p) (fboundp 'nidhogg-view--call)))

(defun drgnx-work-gui--bin ()
  "The hub: DRGNX_RATATOSKR_BIN, else the checkout's own build (a GUI session does not inherit the variable)."
  (let ((bin (or (getenv "DRGNX_RATATOSKR_BIN") (expand-file-name "runtime/target/debug/ratatoskr" drgnx-work-gui--repo))))
    (unless (file-executable-p bin) (ert-fail (format "needs a test-hooks ratatoskr built in the checkout (%s)" bin)))
    bin))

(defun drgnx-work-gui--settle (buffer)
  "Wait until BUFFER's view holds a version, is not stale and asks no resync; draw it.  The agents keep streaming, so
this never waits for the hub to fall quiet."
  (drgnx-test-wait (lambda ()
                     (redisplay t)
                     (let ((s (buffer-local-value 'drgnx-view-patch buffer)))
                       (and s (drgnx-view-patch-version s) (not (drgnx-view-patch-stale s))
                            (not (drgnx-view-patch-resync s)) (> (buffer-size buffer) 0))))
                   :secs 30 :what "the hub's rows drawn")
  (with-current-buffer buffer (drgnx-view-draw-now drgnx-view)))

(defvar drgnx-work-gui--agents 4
  "How many of the 30-agent workspace's agents `drgnx-work-gui--with-map' starts: few enough that the layout, with
every file they edit, fits at scale 2 (one that does not is the outline), and one more agent still fits.")

(defmacro drgnx-work-gui--with-map (&rest body)
  "BODY in the map of the 30-agent workspace's first `drgnx-work-gui--agents' agents (`drgnx-work-gui--with-map-of')."
  (declare (indent 0))
  `(drgnx-work-gui--with-map-of drgnx-work-gui--agents ,@body))

(defmacro drgnx-work-gui--with-map-of (count &rest body)
  "BODY in the map of the 30-agent workspace's first COUNT agents on the hub's rows, alone in the root frame's selected
window from its top, drawn and presented; `root', `buf' and `win' are bound.  Needs Sjá (the map takes the hub's rows
only with it): an error without it (the rows' `skip-unless' says so first)."
  (declare (indent 1))
  `(progn
     (unless (drgnx-work-gui--rows-p) (error "The map's motion rows need Sjá in a graphical frame"))
     (drgnx-test-with-modules '(tools/work-space)
       (require 'drgnx-work-map)
       (let ((root (drgnx-uitest-root-frame)) (buf nil) (win nil))
         (unwind-protect
             (with-selected-frame root
               (delete-other-windows)
               (drgnx-work-thirty-start (drgnx-work-gui--bin) ,count)
               (setq buf (drgnx-work-thirty-map t))
               (delete-other-windows)
               (setq win (selected-window))
               (set-window-buffer win buf)
               (should (buffer-local-value 'drgnx-view-patch buf))
               (drgnx-work-gui--settle buf)
               ;; the layout's cards, not the outline
               (drgnx-test-wait (lambda ()
                                  (with-current-buffer buf
                                    (drgnx-view-draw-now drgnx-view)
                                    (> (hash-table-count (drgnx-work-map--drawn-ids)) 0)))
                                :secs 30 :what "the map's card rows")
               (set-window-start win (with-current-buffer buf (point-min)))
               (drgnx-test-wait-presented)
               (with-current-buffer buf ,@body))
           (when (buffer-live-p buf)
             (drgnx-work-map-motion-clear buf)
             (kill-buffer buf))
           (drgnx-work-thirty-stop))))))

(defun drgnx-work-gui--model (id field)
  "FIELD (a string) of item ID in the current map's model in Sjá."
  (nidhogg-view-get (drgnx-view-patch-handle drgnx-view-patch) 'field field id))

(defun drgnx-work-gui--relayout (buf win)
  "The user asks for a layout in BUF, shown in WIN (the first layer, the asks, collapsed: every row below moves up):
the window asks for a capture, the redisplay hands it to the presenter (as the command loop's redisplay does before
the hub's answer is read), which announces that it holds the old picture; the hub's answer comes and the new layout is
drawn.  Returns the motion WIN was given."
  (with-current-buffer buf (drgnx-work-map-collapse-layer 1))
  (drgnx-work-gui--log "motion waiting %S" (cdr (buffer-local-value 'drgnx-work-map--motion buf)))
  (should (window-parameter win 'glitnir-layout-capture))
  (should-not (window-parameter win 'glitnir-layout-motion))
  (redisplay t)
  (drgnx-test-wait (lambda () (redisplay t) (glitnir-layout-captured-p win)) :secs 10
                   :what "the presenter holds the old picture")
  (drgnx-test-wait (lambda () (null (buffer-local-value 'drgnx-work-map--motion buf))) :secs 30
                   :what "the hub's answer drawn")
  (window-parameter win 'glitnir-layout-motion))

(defun drgnx-work-gui--one-more-agent ()
  "Start one more agent on the fixture's first profile and send it an ask: the hub's live patch adds its card.  The
fixture's stop ends it."
  (let* ((a (car drgnx-work-thirty--agents))
         (s (drgnx-agents-mirror-start (plist-get a :profile) (plist-get a :cwd))))
    (should s)
    (push s drgnx-work-thirty--mirrors)
    (drgnx-agents-send s "one more agent, on the map while the others stream")
    s))

(defun drgnx-work-gui--shoot (name)
  "Capture the root frame and keep it in the evidence folder as work-motion-NAME-sSCALE.png."
  (let ((shot (plist-get (drgnx-uitest-capture (make-temp-file "work-motion" t)) :root))
        (out (expand-file-name (format "work-motion-%s-s%d.png" name (round (frame-scale-factor))) temporary-file-directory)))
    (should (file-exists-p shot))
    (copy-file shot out t)
    (drgnx-uitest--evidence out)
    (drgnx-work-gui--log "motion shot %s" out)))

(defun drgnx-work-gui--card-y (buf win id)
  "The y of the first line of ID's card in BUF below WIN's first line, after a redisplay (both text, so both
`posn-at-point' answers have the same origin)."
  (redisplay t)
  (with-current-buffer buf
    (- (cdr (posn-x-y (posn-at-point (drgnx-work-gui--card-pos id) win)))
       (cdr (posn-x-y (posn-at-point (window-start win) win))))))

(defun drgnx-work-gui--card-pos (id)
  "The first position of ID's card on the layout's card rows (keys \"row:…\"; a band's lanes carry ids too) in the
current buffer (`text-property-any' compares with `eq'), or nil."
  (let ((pos (point-min)))
    (while (and pos (not (and (equal (get-text-property pos 'drgnx-work-id) id)
                              (let ((key (drgnx-view-key-at pos))) (and (stringp key) (string-prefix-p "row:" key))))))
      (setq pos (next-single-property-change pos 'drgnx-work-id)))
    pos))

(ert-deftest drgnx-work-gui/relayout-moves-with-motion ()
  "A layout the user asks for moves, dark and light: the key asks the presenter for the old picture, the hub's frame
is drawn once the picture is held, and before the redisplay that shows it the window says what moved: the swapped
agents and branches move between their rectangles, the machine exits.  The shell takes the leg; at its end the
parameters go and a leg is counted.  Screenshots of the map before and after."
  (skip-unless (and (drgnx-work-gui--rows-p) (drgnx-work-gui--leg-p)))
  (dolist (theme '(modus-vivendi modus-operandi))
    (mapc #'disable-theme custom-enabled-themes)
    (load-theme theme t)
    (unwind-protect
        (drgnx-work-gui--with-map
          (let* ((legs (drgnx-work-gui--stat :legs)) (tag (if (eq theme 'modus-vivendi) "dark" "light"))
                 (stats0 (ignore-errors (nhwl-presenter-stats root))))
            (drgnx-work-gui--shoot (concat tag "-before"))
            (let* ((m (drgnx-work-gui--relayout buf win)) (moves (plist-get m :moves))
                   (margin (drgnx-work-map--margin-px)))
              (drgnx-work-gui--log "motion %s %S" tag m)
              (should m)
              (should moves)
              (should (= 0.16 (plist-get m :duration)))
              (should (eq 'ease-out (plist-get m :curve)))
              ;; each move ends at its card's rectangle: x and w the model's, y where its first line is drawn
              (let ((off nil))
                (pcase-dolist (`(,id ,_old ,new) moves)
                  (let ((x (drgnx-work-gui--model id "x")) (w (drgnx-work-gui--model id "w")))
                    (should (= (nth 0 new) (+ margin (drgnx-work-map--px x))))
                    (should (= (+ (nth 0 new) (nth 2 new)) (+ margin (drgnx-work-map--px (+ x w)))))
                    (when (pos-visible-in-window-p (drgnx-work-gui--card-pos id) win)
                      (let ((y (drgnx-work-gui--card-y buf win id)))
                        (drgnx-work-gui--log "motion %s card y=%S rect=%S" id y new)
                        (unless (<= (abs (- y (nth 1 new))) 2) (push (list id y new) off))))))
                (should-not off))
              ;; an exit is a card the new layout no longer draws
              (dolist (e (plist-get m :exits))
                (should-not (drgnx-work-gui--card-pos (car e))))
              ;; the redisplay that shows the new layout hands the leg to the shell, from the capture
              (redisplay t)
              (let ((sent (window-parameter win 'glitnir--leg-sent)))
                (should (> (nth 2 sent) 0))
                (should (nth 4 sent))))
            (drgnx-test-wait (lambda () (null (window-parameter win 'glitnir-layout-capture))) :secs 10
                             :what "the leg's end takes the capture off")
            (should-not (window-parameter win 'glitnir-layout-motion))
            (should (= (1+ legs) (drgnx-work-gui--stat :legs)))
            (drgnx-test-wait-presented)
            (drgnx-work-gui--log "motion presenter %s before=%S after=%S" tag stats0
                                 (ignore-errors (nhwl-presenter-stats root)))
            (drgnx-work-gui--shoot (concat tag "-after"))))
      (disable-theme theme))))

(ert-deftest drgnx-work-gui/no-ack-is-a-jump ()
  "A capture the presenter does not hold means no leg: here the window's text area moved after the capture was asked
for, so the picture is dropped.  One period after the hub's frame came, the new layout is drawn plain, the window
keeps no capture and no motion, and a skipped leg is counted."
  (skip-unless (and (drgnx-work-gui--rows-p) (drgnx-work-gui--leg-p)))
  (drgnx-work-gui--with-map
    (let ((skipped (drgnx-work-gui--stat :skipped)) (legs (drgnx-work-gui--stat :legs)))
      (unwind-protect
          (progn
            (drgnx-work-map-collapse-layer 1)
            (should (window-parameter win 'glitnir-layout-capture))
            (redisplay t)
            (set-window-margins win 1 0)
            (redisplay t)
            (should-not (glitnir-layout-captured-p win))
            ;; the hub's answer comes; one period later the new layout is drawn plain
            (drgnx-test-wait (lambda () (null drgnx-work-map--motion)) :secs 30 :what "the answer, and one period")
            (should (= (1+ skipped) (drgnx-work-gui--stat :skipped)))
            (should (= legs (drgnx-work-gui--stat :legs)))
            (should-not (window-parameter win 'glitnir-layout-capture))
            (should-not (window-parameter win 'glitnir-layout-motion)))
        (set-window-margins win 0 0)))))

(defun drgnx-work-gui--reduced (fn)
  "Call FN with motion reduced, by Glitnir's setting where Glitnir is loaded (elsewhere the map never moves)."
  (if (boundp 'glitnir-reduced-motion)
      (let ((glitnir-reduced-motion t)) (funcall fn))
    (funcall fn)))

(ert-deftest drgnx-work-gui/reduced-motion-sends-no-capture ()
  "Under reduced motion a layout the user asks for asks the presenter for nothing: the hub's frame is drawn with no
motion, and nothing is counted (a jump by choice is not a skipped leg)."
  (skip-unless (drgnx-work-gui--rows-p))
  (drgnx-work-gui--with-map
    (let ((skipped (drgnx-work-gui--stat :skipped)) (legs (drgnx-work-gui--stat :legs)))
      (drgnx-work-gui--reduced
       (lambda ()
         (drgnx-work-map-collapse-layer 1)
         (should-not (window-parameter win 'glitnir-layout-capture))
         (redisplay t)
         (drgnx-test-wait (lambda () (null drgnx-work-map--asked)) :secs 30 :what "the hub's answer")
         (redisplay t)
         (should-not (window-parameter win 'glitnir-layout-capture))
         (should-not (window-parameter win 'glitnir-layout-motion))
         (should (= skipped (drgnx-work-gui--stat :skipped)))
         (should (= legs (drgnx-work-gui--stat :legs))))))))

(ert-deftest drgnx-work-gui/a-live-arrival-never-moves-the-map ()
  "A live patch never moves the map: an agent arrives (the hub's patch adds its card) with no capture, no motion and
nothing counted.  And while a layout the user asked for waits for its answer, the live patches drawn meanwhile do not
give it motion either."
  (skip-unless (drgnx-work-gui--rows-p))
  (drgnx-work-gui--with-map
    (let ((skipped (drgnx-work-gui--stat :skipped)) (legs (drgnx-work-gui--stat :legs))
          (agents (drgnx-work-thirty-agent-items buf)))
      (drgnx-work-gui--one-more-agent)
      (drgnx-test-wait (lambda () (redisplay t) (> (drgnx-work-thirty-agent-items buf) agents)) :secs 30
                       :what "the new agent's card")
      (drgnx-work-gui--settle buf)
      (redisplay t)
      (should-not (window-parameter win 'glitnir-layout-capture))
      (should-not (window-parameter win 'glitnir-layout-motion))
      ;; a layout waits (the capture a layout key asks for before it sends); the agents' patches keep coming
      (set-window-start win (point-min))
      (redisplay t)
      (drgnx-work-map--motion-begin)
      (drgnx-work-gui--log "motion live: start key %S, waiting %S" (drgnx-view-key-at (window-start win))
                           (cdr drgnx-work-map--motion))
      (when (drgnx-work-gui--leg-p) (should drgnx-work-map--motion))
      (let ((drawn (plist-get (drgnx-view-stats drgnx-view) :rows-drawn)))
        (drgnx-test-wait (lambda () (redisplay t) (> (plist-get (drgnx-view-stats drgnx-view) :rows-drawn) drawn))
                         :secs 30 :what "a live patch drawn"))
      (should-not (window-parameter win 'glitnir-layout-motion))
      (drgnx-work-map-motion-clear)
      (should (= skipped (drgnx-work-gui--stat :skipped)))
      (should (= legs (drgnx-work-gui--stat :legs))))))

(defun drgnx-work-gui--key-times ()
  "Milliseconds of 40 map keys (the selection right, then left), each with its redisplay."
  (let ((times nil))
    (dotimes (i 40)
      (let ((t0 (float-time)))
        (if (cl-evenp i) (drgnx-work-map-right) (drgnx-work-map-left))
        (redisplay t)
        (push (drgnx-work-gui--ms t0) times)))
    times))

(ert-deftest drgnx-work-gui/keys-stay-fast-during-a-leg ()
  "Measured on a long leg: a key on the map (the selection moves, rows are refaced) with its redisplay while the leg
runs, 40 times: p95 under 16 ms."
  :tags '(:timing)
  (skip-unless (and (drgnx-work-gui--rows-p) (drgnx-work-gui--leg-p)))
  (drgnx-work-gui--with-map
    (let ((drgnx-work-map-motion-duration 3.0) (times nil) (base (drgnx-work-gui--key-times)))
      (should (drgnx-work-gui--relayout buf win))
      (redisplay t)
      (setq times (drgnx-work-gui--key-times))
      (let ((sent (window-parameter win 'glitnir--leg-sent)))
        (drgnx-work-gui--log "motion keys: no leg med=%.2f p95=%.2f max=%.2f | during a leg med=%.2f p95=%.2f max=%.2f leg=%S"
                             (drgnx-work-gui--med base) (drgnx-work-gui--p95 base) (apply #'max base)
                             (drgnx-work-gui--med times) (drgnx-work-gui--p95 times) (apply #'max times) (nth 2 sent))
        (should (> (nth 2 sent) 0))
        (should (< (drgnx-work-gui--p95 times) 16))))))

;;;; Scenes: the 30-agent map, dark, light and high contrast

(defun drgnx-work-gui--scene-shoot (theme)
  "Capture the root frame as work-space-THEME-sSCALE.png in the evidence folder; the file's name."
  (let ((shot (plist-get (drgnx-uitest-capture (make-temp-file "work-scene" t)) :root))
        (out (expand-file-name (format "work-space-%s-s%g.png" theme (frame-scale-factor)) temporary-file-directory)))
    (should (file-exists-p shot))
    (copy-file shot out t)
    (drgnx-uitest--evidence out)
    (drgnx-work-gui--log "scene shot %s" out)
    out))

(ert-deftest drgnx-work-gui/thirty-agent-scenes ()
  "The map of the 30-agent workspace in a real hub (mock agents, all streaming), alone in the root frame: a screenshot
in the drgnx dark, light and high-contrast themes at the session's scale (the lab runs scales 1, 1.25 and 2).  Asserts
the premise (30 agents streaming and on the map), that the map drew rows, and that each shot exists; the eye judges the
rest."
  ;; the UI session does not inherit DRGNX_RATATOSKR_BIN: the checkout's own build is the fallback
  (let ((bin (or (getenv "DRGNX_RATATOSKR_BIN") (expand-file-name "runtime/target/debug/ratatoskr" drgnx-work-gui--repo))))
    (unless (file-executable-p bin) (ert-fail (format "needs a test-hooks ratatoskr built in the checkout (%s)" bin)))
    (drgnx-work-gui--scenes bin)))

(defun drgnx-work-gui--scenes (bin)
  "The scenes' body: the 30-agent map in the hub BIN, shot in three themes."
  (drgnx-test-with-modules '(tools/work-space)
    (let ((root (drgnx-uitest-root-frame)) buf)
      (unwind-protect
          (with-selected-frame root
            (delete-other-windows)
            (drgnx-work-thirty-start bin)
            (setq buf (drgnx-work-thirty-map t))
            (delete-other-windows)
            (set-window-buffer (selected-window) buf)
            (dolist (theme '(drgnx-dark drgnx-light drgnx-high-contrast))
              (mapc #'disable-theme custom-enabled-themes)
              (load-theme theme t)
              (with-current-buffer buf (drgnx-view-touch drgnx-view))
              (drgnx-test-wait (lambda () (redisplay t) (not (drgnx-view-pending-p (buffer-local-value 'drgnx-view buf))))
                               :secs 30 :what "the map drawn")
              (set-window-start (selected-window) (point-min))
              (drgnx-test-wait-presented)
              (drgnx-work-thirty-premise buf t)
              (should (> (plist-get (drgnx-view-stats (buffer-local-value 'drgnx-view buf)) :rows-drawn) 0))
              (drgnx-work-gui--scene-shoot theme)))
        (mapc #'disable-theme custom-enabled-themes)
        (when (buffer-live-p buf) (kill-buffer buf))
        (drgnx-work-thirty-stop)))))

;;;; Cards inside their rectangles

(defun drgnx-work-gui--card-runs ()
  "Each card text run on the layout's card rows (keys \"row:…\") of the current buffer: (ID FROM TO), TO after its
closing `align-to' space."
  (let ((pos (point-min)) out)
    (while (< pos (point-max))
      (let ((next (or (next-single-property-change pos 'drgnx-work-id) (point-max))) (id (get-text-property pos 'drgnx-work-id))
            (key (drgnx-view-key-at pos)))
        (when (and id (stringp key) (string-prefix-p "row:" key)) (push (list id pos next) out))
        (setq pos next)))
    (nreverse out)))

(defun drgnx-work-gui--cards-outside (win)
  "The cards on screen in WIN (the map is taller than the window) whose line does not start at its model rectangle's
left or whose text ends past its right: ((ID :left … :drawn-at … :right … :closes-at …) …), and how many were checked,
as (BAD . N)."
  (redisplay t)
  (let ((margin (drgnx-work-map--margin-px)) (bad nil) (n 0))
    (pcase-dolist (`(,id ,from ,to) (drgnx-work-gui--card-runs))
      (let ((x (drgnx-work-gui--model id "x")) (w (drgnx-work-gui--model id "w"))
            (p0 (posn-at-point from win)) (p1 (posn-at-point (1- to) win)))
        (when (and x w p0 p1)
          (let ((left (+ margin (drgnx-work-map--px x))) (right (+ margin (drgnx-work-map--px (+ x w))))
                (x0 (car (posn-x-y p0))) (x1 (car (posn-x-y p1))))
            (cl-incf n)
            (unless (and (<= (abs (- x0 left)) 2) (<= x1 right))
              (push (list id :left left :drawn-at x0 :right right :closes-at x1) bad))))))
    (cons bad n)))

(defun drgnx-work-gui--cards-inside (width)
  "The 30-agent map on the hub's rows in the drgnx dark theme, in a window WIDTH px wide (nil: the whole frame): once
the hub has laid it out for that width, each card on screen is inside its rectangle; the shot of the frame is kept in
the evidence folder.  Below scale 2 all 30 agents; at 2 the 30 do not fit (the hub draws the outline), so the first
`drgnx-work-gui--agents'.  More cards are checked than there are agents."
  (drgnx-work-gui--with-map-of (if (< (frame-scale-factor) 2) 30 drgnx-work-gui--agents)
    (unwind-protect
        (let ((want (length drgnx-work-thirty--mirrors)) found)
          (when width (split-window win width 'right t))
          (load-theme 'drgnx-dark t)
          (set-window-start win (point-min))
          ;; the hub lays the map out again for the narrower window: its patches come while the agents stream
          (drgnx-test-wait (lambda ()
                             (drgnx-view-draw-now drgnx-view)
                             (setq found (drgnx-work-gui--cards-outside win))
                             (and (> (cdr found) want) (null (car found))))
                           :secs 30 :what "every card on screen inside its rectangle")
          (drgnx-test-wait-presented)
          (drgnx-work-gui--scene-shoot (format "cards-%dpx" (window-pixel-width win)))
          (drgnx-work-gui--log "%d px: cards checked %d, outside %d: %S" (window-pixel-width win) (cdr found)
                               (length (car found)) (seq-take (car found) 6))
          (should (> (cdr found) want))
          (should-not (car found)))
      (disable-theme 'drgnx-dark))))

(ert-deftest drgnx-work-gui/thirty-cards-stay-inside-their-rectangles ()
  "The 30-agent map on the hub's rows at 1000 px (in a window that wide) and in the whole frame, every busy agent's
label far longer than its card, in the drgnx dark theme: each card line starts at its rectangle's left and its text
ends by its right, so the space that closes it starts no later than the right edge and no card is drawn over the next
\(the map once ran off the right edge, each line drawing the cards of the line before again, and lanes on one column
side by side pushing the next card)."
  (skip-unless (drgnx-work-gui--rows-p))
  (drgnx-work-gui--cards-inside 1000)
  (drgnx-work-gui--cards-inside nil))

;;; work-space-gui-test.el ends here
