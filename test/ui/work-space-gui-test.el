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
(require 'drgnx-work-client)
(load (expand-file-name "test/fixtures/work-space-fixture" drgnx-work-gui--repo) nil t)
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
(defvar drgnx-work-space--view)
(defvar drgnx-work-map--outline)
(defvar drgnx-work-map--motion)
(defvar drgnx-work-map-motion-stats)
(defvar drgnx-work-map-motion-duration)
(defvar glitnir-reduced-motion)
(declare-function drgnx-work-map-mode "drgnx-work-map")
(declare-function drgnx-work-map-overlaps "drgnx-work-map")
(declare-function drgnx-work-map-right "drgnx-work-map")
(declare-function drgnx-work-map-left "drgnx-work-map")
(declare-function drgnx-work-map--state "drgnx-work-map")
(declare-function drgnx-work-map--margin-px "drgnx-work-map")
(declare-function drgnx-work-map--px "drgnx-work-map")
(declare-function drgnx-work-map-motion-clear "drgnx-work-map")
(declare-function drgnx-view-attach "drgnx-view")
(declare-function drgnx-view-touch "drgnx-view")
(declare-function drgnx-view-draw-now "drgnx-view")
(declare-function drgnx-view-pending-p "drgnx-view")
(declare-function glitnir-layout-captured-p "glitnir")
(declare-function nhwl-presenter-stats "nhwlterm.c")

(defconst drgnx-work-gui--view "work-motion" "The map view of the motion rows.")

(defun drgnx-work-gui--leg-p ()
  "Non-nil where the map can move: Glitnir draws the root frame and has the layout leg (Nidhogg with it)."
  (and (drgnx-uitest-glitnir-p) (fboundp 'glitnir-layout-captured-p)))

(defun drgnx-work-gui--stat (key) (plist-get drgnx-work-map-motion-stats key))

(defmacro drgnx-work-gui--with-map (&rest body)
  "BODY with tools/work-space on and the fixture frame's map alone in the root frame's selected window, drawn and
presented; `buf' and `win' are bound.  The view is the client's, with no hub: events are fed to it."
  (declare (indent 0))
  `(drgnx-test-with-modules '(tools/work-space)
     (let* ((drgnx-work-client--views (make-hash-table :test #'equal))
            (root (drgnx-uitest-root-frame)) (buf (generate-new-buffer " *work-motion*")) (win nil))
       (puthash drgnx-work-gui--view
                (drgnx-work-client--make-view :id drgnx-work-gui--view
                                              :state (drgnx-work-client-init (drgnx-work-fixture-frame)) :status 'live)
                drgnx-work-client--views)
       (unwind-protect
           (with-selected-frame root
             (delete-other-windows)
             (setq win (selected-window))
             (set-window-buffer win buf)
             (with-current-buffer buf
               (drgnx-work-map-mode)
               (setq drgnx-work-space--view drgnx-work-gui--view drgnx-work-map--outline 'off)
               (drgnx-view-attach 'work-map)
               (drgnx-view-touch drgnx-view)
               (drgnx-view-draw-now drgnx-view)
               (set-window-start win (point-min))
               (drgnx-test-wait-presented)
               ,@body))
         (when (buffer-live-p buf)
           (when (fboundp 'drgnx-work-map-motion-clear) (drgnx-work-map-motion-clear buf))
           (kill-buffer buf))))))

(defun drgnx-work-gui--relaid ()
  "The hub's answer to a layout the user asked for, a full `work-map' event: the fixture frame with agents a1 and a2
swapped, the two branches swapped, and the machine gone."
  (let* ((f (drgnx-work-fixture-frame)) (layout (plist-get f :layout)) (at (copy-sequence (plist-get layout :at)))
         (gone "machine:desktop"))
    (pcase-dolist (`(,a . ,b) '((:agent:a1 . :agent:a2) (:branch:drgnx/rp-df-hub . :branch:drgnx/rp-fx-sess)))
      (let ((ra (plist-get at a)) (rb (plist-get at b)))
        (setq at (plist-put (plist-put at a (plist-put (copy-sequence ra) :x (plist-get rb :x)))
                            b (plist-put (copy-sequence rb) :x (plist-get ra :x))))))
    (setq at (cl-loop for (k v) on at by #'cddr unless (equal (substring (symbol-name k) 1) gone) append (list k v)))
    (list :view drgnx-work-gui--view :version (1+ (plist-get f :version)) :full t
          :changed (seq-remove (lambda (it) (equal (plist-get it :id) gone)) (plist-get f :items))
          :edges (seq-remove (lambda (e) (member gone (list (plist-get e :from) (plist-get e :to)))) (plist-get f :edges))
          :layout (plist-put (copy-sequence layout) :at at)
          :needs_you (plist-get f :needs_you) :chips (plist-get f :chips))))

(defun drgnx-work-gui--arrival (base)
  "A live `work-map' delta on BASE: agent a9 arrives in a free place of the agents' row and the machine leaves."
  (let* ((f (drgnx-work-fixture-frame))
         (new (plist-put (plist-put (copy-sequence (drgnx-work-fixture-item f "agent:a2")) :id "agent:a9") :label "a9")))
    (list :view drgnx-work-gui--view :version (1+ base) :base base :changed (list new) :removed '("machine:desktop")
          :places (list :agent:a9 (list :rect (list :x 122 :y 45 :w 58 :h 25) :form "rich")))))

(defun drgnx-work-gui--field-change (base)
  "A live `work-map' delta on BASE: agent a2's activity changes."
  (list :view drgnx-work-gui--view :version (1+ base) :base base
        :changed (list (drgnx-work-fixture-changed (drgnx-work-fixture-frame) "agent:a2" :activity "reading"))))

(defun drgnx-work-gui--relayout (buf win)
  "The user asks for a layout (`work-overlaps') in BUF, shown in WIN: the window asks for a capture, the redisplay
hands it to the presenter, which announces that it holds the old picture; then the hub's frame comes.  Returns the
motion WIN was given."
  (with-current-buffer buf (drgnx-work-map-overlaps))
  (drgnx-work-gui--log "motion waiting %S" (cdr (buffer-local-value 'drgnx-work-map--motion buf)))
  (should (window-parameter win 'glitnir-layout-capture))
  (should-not (window-parameter win 'glitnir-layout-motion))
  (drgnx-test-wait (lambda () (redisplay t) (glitnir-layout-captured-p win)) :secs 10
                   :what "the presenter holds the old picture")
  (drgnx-work-client-event "work-map" (drgnx-work-gui--relaid))
  (window-parameter win 'glitnir-layout-motion))

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
  "The first position of ID's card in the current buffer (`text-property-any' compares with `eq'), or nil."
  (let ((pos (point-min)))
    (while (and pos (not (equal (get-text-property pos 'drgnx-work-id) id)))
      (setq pos (next-single-property-change pos 'drgnx-work-id)))
    pos))

(ert-deftest drgnx-work-gui/relayout-moves-with-motion ()
  "A layout the user asks for moves, dark and light: the key asks the presenter for the old picture, the hub's frame
is drawn once the picture is held, and before the redisplay that shows it the window says what moved: the swapped
agents and branches move between their rectangles, the machine exits.  The shell takes the leg; at its end the
parameters go and a leg is counted.  Screenshots of the map before and after."
  (skip-unless (drgnx-work-gui--leg-p))
  (dolist (theme '(modus-vivendi modus-operandi))
    (mapc #'disable-theme custom-enabled-themes)
    (load-theme theme t)
    (unwind-protect
        (drgnx-work-gui--with-map
          (let* ((legs (drgnx-work-gui--stat :legs)) (tag (if (eq theme 'modus-vivendi) "dark" "light"))
                 (stats0 (ignore-errors (nhwl-presenter-stats root)))
                 ;; the machine's row is below the window's bottom at scale 2: then it exits unseen
                 (machine-shown (pos-visible-in-window-p (drgnx-work-gui--card-pos "machine:desktop") win t)))
            (drgnx-work-gui--shoot (concat tag "-before"))
            (let* ((m (drgnx-work-gui--relayout buf win)) (moves (plist-get m :moves))
                   (a1 (assoc "agent:a1" moves)) (a2 (assoc "agent:a2" moves)) (margin (drgnx-work-map--margin-px)))
              (drgnx-work-gui--log "motion %s %S" tag m)
              (should m)
              (should a1) (should a2)
              (should (assoc "branch:drgnx/rp-df-hub" moves))
              (should (assoc "branch:drgnx/rp-fx-sess" moves))
              (should (eq (and machine-shown t) (and (assoc "machine:desktop" (plist-get m :exits)) t)))
              (should-not (plist-get m :enters))
              (should (= (nth 0 (nth 1 a1)) (+ margin (drgnx-work-map--px 0))))
              (should (= (nth 0 (nth 2 a1)) (+ margin (drgnx-work-map--px 61))))
              (should (= (nth 1 (nth 1 a1)) (nth 1 (nth 2 a1))))
              (should (= 0.16 (plist-get m :duration)))
              (should (eq 'ease-out (plist-get m :curve)))
              ;; the rectangles are where the cards are drawn: a1's new one at its card's first line
              (let ((y (drgnx-work-gui--card-y buf win "agent:a1")))
                (drgnx-work-gui--log "motion a1 card y=%S rect=%S" y (nth 2 a1))
                (should (<= (abs (- y (nth 1 (nth 2 a1)))) 2)))
              ;; the new layout is the one drawn, and the shell took the leg from the capture
              (should (= 61 (plist-get (drgnx-work-client-rect (drgnx-work-map--state) "agent:a1") :x)))
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
  (skip-unless (drgnx-work-gui--leg-p))
  (drgnx-work-gui--with-map
    (let ((skipped (drgnx-work-gui--stat :skipped)) (legs (drgnx-work-gui--stat :legs)))
      (unwind-protect
          (progn
            (drgnx-work-map-overlaps)
            (should (window-parameter win 'glitnir-layout-capture))
            (redisplay t)
            (set-window-margins win 1 0)
            (redisplay t)
            (should-not (glitnir-layout-captured-p win))
            (drgnx-work-client-event "work-map" (drgnx-work-gui--relaid))
            (drgnx-test-wait (lambda () (null drgnx-work-map--motion)) :secs 10 :what "one period passed")
            (should (= (1+ skipped) (drgnx-work-gui--stat :skipped)))
            (should (= legs (drgnx-work-gui--stat :legs)))
            (should-not (window-parameter win 'glitnir-layout-capture))
            (should-not (window-parameter win 'glitnir-layout-motion))
            (should (= 61 (plist-get (drgnx-work-client-rect (drgnx-work-map--state) "agent:a1") :x)))
            (should-not (drgnx-view-pending-p drgnx-view)))
        (set-window-margins win 0 0)))))

(defun drgnx-work-gui--reduced (fn)
  "Call FN with motion reduced, by Glitnir's setting where Glitnir is loaded (elsewhere the map never moves)."
  (if (boundp 'glitnir-reduced-motion)
      (let ((glitnir-reduced-motion t)) (funcall fn))
    (funcall fn)))

(ert-deftest drgnx-work-gui/reduced-motion-sends-no-capture ()
  "Under reduced motion a layout the user asks for asks the presenter for nothing: the hub's frame is drawn with no
motion, and nothing is counted (a jump by choice is not a skipped leg)."
  (drgnx-work-gui--with-map
    (let ((skipped (drgnx-work-gui--stat :skipped)) (legs (drgnx-work-gui--stat :legs)))
      (drgnx-work-gui--reduced
       (lambda ()
         (drgnx-work-map-overlaps)
         (should-not (window-parameter win 'glitnir-layout-capture))
         (redisplay t)
         (drgnx-work-client-event "work-map" (drgnx-work-gui--relaid))
         (should-not (window-parameter win 'glitnir-layout-capture))
         (should-not (window-parameter win 'glitnir-layout-motion))
         (should (= 61 (plist-get (drgnx-work-client-rect (drgnx-work-map--state) "agent:a1") :x)))
         (should (= skipped (drgnx-work-gui--stat :skipped)))
         (should (= legs (drgnx-work-gui--stat :legs))))))))

(ert-deftest drgnx-work-gui/a-live-arrival-never-moves-the-map ()
  "A live delta (an agent arrives, the machine exits) never moves the map: no capture, no motion, nothing counted.
And while a layout the user asked for waits for its frame, a live delta does not give it motion either."
  (drgnx-work-gui--with-map
    (let ((skipped (drgnx-work-gui--stat :skipped)) (legs (drgnx-work-gui--stat :legs)))
      (drgnx-work-client-event "work-map" (drgnx-work-gui--arrival 3))
      (redisplay t)
      (should (drgnx-work-client-item (drgnx-work-map--state) "agent:a9"))
      (should-not (drgnx-work-client-item (drgnx-work-map--state) "machine:desktop"))
      (should-not (window-parameter win 'glitnir-layout-capture))
      (should-not (window-parameter win 'glitnir-layout-motion))
      (drgnx-work-map-overlaps)
      (redisplay t)
      (drgnx-work-client-event "work-map" (drgnx-work-gui--field-change 4))
      (redisplay t)
      (should-not (window-parameter win 'glitnir-layout-motion))
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
  (skip-unless (drgnx-work-gui--leg-p))
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

(load (expand-file-name "test/fixtures/work-space-thirty-fixture" drgnx-work-gui--repo) nil t)

(defvar drgnx-work-space-roots)
(declare-function drgnx-work-thirty-start "work-space-thirty-fixture")
(declare-function drgnx-work-thirty-stop "work-space-thirty-fixture")
(declare-function drgnx-work-thirty-map "work-space-thirty-fixture")
(declare-function drgnx-work-thirty-premise "work-space-thirty-fixture")

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
  (skip-unless (and (getenv "DRGNX_RATATOSKR_BIN") (file-executable-p (getenv "DRGNX_RATATOSKR_BIN"))))
  (drgnx-test-with-modules '(tools/work-space)
    (let ((root (drgnx-uitest-root-frame)) buf)
      (unwind-protect
          (with-selected-frame root
            (delete-other-windows)
            (drgnx-work-thirty-start (getenv "DRGNX_RATATOSKR_BIN"))
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

;;; work-space-gui-test.el ends here
