;;; drgnx-work-edges.el --- The Work map's edges: SVG band tiles, lanes and ports (library of tools/work-space) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The bands between the map's rows are blank lines of the band's height; the edges are drawn into them as images.  A
;; band is cut into tiles TILE pixels wide (192 logical pixels: S1's verdict), and a tile is an SVG string of the cubic
;; curves that cross it, built without a DOM.  A chain change makes new images only for the tiles whose strokes
;; changed; the rest are the very images the cache holds.  In a card row an edge that skips the row is a lane: a 2 px
;; wide image segment as high as the row's text, with the row's ascent.  Edges bundled for want of lanes end in a port
;; chip, "↑ N", on the top edge of their target, drawn into the band above it.
;;
;; Everything here is a function of the layout's geometry, the chain and the colours.  The colours are read from the
;; `drgnx-work-*' faces whenever a tile is made: the image cache is keyed on the SVG text, so a theme change makes new
;; tiles by itself, and nothing here holds a colour.  All sizes are device pixels (the layout's units times 4 times the
;; display scale).  Defines no module.  See docs/develop/work-space.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-work-client)

(defconst drgnx-work-edges-tile-width 192
  "The width of an edge tile in logical pixels: any width from 128 to 256 costs the same to raster, so it is a layout
choice.")

(defconst drgnx-work-edges--strokes
  '(("came-from" edge 1 nil)
    ("edits" edit 2 nil)
    ("reads" agent 1.5 "1.5 4")
    ("runs-on" edge 1 "6 3 1 3")
    ("based-on" edge 1 "4 2")
    ("overlap" warn 2 "6 4")
    ("read-vs-edit" warn 1 "2 2"))
  "Edge kind → (COLOUR-KEY WIDTH DASH): the look of an edge off the selection's chain, in logical pixels.  Every kind
differs from every other in width or dash, so colour is never the only difference.  An edit is neutral off the chain
(`edit'); a read takes its agent's colour (`agent').")

(defconst drgnx-work-edges--kind-words
  '(("came-from" . "came from") ("edits" . "edits") ("reads" . "reads") ("runs-on" . "runs on")
    ("based-on" . "based on") ("overlap" . "overlaps") ("read-vs-edit" . "reads what another edits"))
  "Edge kind → the words an image's alternative text uses.")

(defvar drgnx-work-edges--images (make-hash-table :test #'equal)
  "(SVG . ALT) → the image made from it, so an unchanged tile is the very same object.  Emptied when it holds 600
entries; the map draws what it shows again, so only the visible tiles come back.")

(defun drgnx-work-edges-stroke (kind)
  "KIND's look off the chain: (COLOUR-KEY WIDTH DASH).  An unknown kind looks like a came-from edge."
  (cdr (or (assoc kind drgnx-work-edges--strokes) (assoc "came-from" drgnx-work-edges--strokes))))

;;;; Colours

(defun drgnx-work-edges--face-colour (face)
  "FACE's foreground, resolved through its inheritance; the default face's when it has none."
  (let ((c (face-attribute face :foreground nil t)))
    (if (or (not (stringp c)) (string-prefix-p "unspecified" c))
        (let ((d (face-attribute 'default :foreground nil t)))
          (if (and (stringp d) (not (string-prefix-p "unspecified" d))) d "currentColor"))
      c)))

(defun drgnx-work-edges-colours ()
  "The colours of the edges, read from the faces now: an alist KEY → colour.  KEY is `edge' (came from, runs on, based
on), `edit', `accent' (the chain), `warn' (overlaps), `chip-bg', `chip-fg' (the ports) and `agent-1' to `agent-6'."
  (append (list (cons 'edge (drgnx-work-edges--face-colour 'drgnx-work-edge))
                (cons 'edit (drgnx-work-edges--face-colour 'drgnx-work-edge-strong))
                (cons 'accent (drgnx-work-edges--face-colour 'drgnx-work-chain))
                (cons 'warn (drgnx-work-edges--face-colour 'drgnx-work-overlap))
                (cons 'chip-fg (drgnx-work-edges--face-colour 'drgnx-work-chip))
                (cons 'chip-bg (let ((b (face-attribute 'drgnx-work-chip :background nil t)))
                                 (if (and (stringp b) (not (string-prefix-p "unspecified" b))) b
                                   (drgnx-work-edges--face-colour 'shadow)))))
          (mapcar (lambda (n) (cons (intern (format "agent-%d" n))
                                    (drgnx-work-edges--face-colour (intern (format "drgnx-work-agent-%d" n)))))
                  '(1 2 3 4 5 6))))

;;;; Geometry

(defun drgnx-work-edges-key (edge)
  "The key a chain table holds EDGE (a plist with :from :to :kind) under."
  (format "%s>%s>%s" (plist-get edge :from) (plist-get edge :to) (plist-get edge :kind)))

(defun drgnx-work-edges-agent-number (item)
  "The agent colour number (1 to 6) of the agent ITEM."
  (1+ (mod (1- (or (plist-get item :order) 1)) 6)))

(defun drgnx-work-edges-geometry (state chain-edges scale margin)
  "The geometry plist the tiles are made from, for STATE's frame and the selection's CHAIN-EDGES at display SCALE and
a left MARGIN in pixels: :scale, :tile (the tile's width in pixels), :margin, :chain (edge key → the number of the
agent whose colour an edit takes, or t for the accent), :agents (agent id → number) and :labels (id → label)."
  (let ((chain (make-hash-table :test #'equal)) (agents (make-hash-table :test #'equal))
        (labels (make-hash-table :test #'equal))
        (edges (drgnx-work-client-edges state)))
    (dolist (id (drgnx-work-client-ids state))
      (let ((item (drgnx-work-client-item state id)))
        (puthash id (plist-get item :label) labels)
        (when (member (plist-get item :kind) '("agent" "subagent"))
          (puthash id (drgnx-work-edges-agent-number item) agents))))
    (dolist (e chain-edges)
      (puthash (drgnx-work-edges-key e)
               (or (and (equal (plist-get e :kind) "edits")
                        (when-let* ((owner (seq-find (lambda (c) (and (equal (plist-get c :kind) "came-from")
                                                                      (equal (plist-get c :to) (plist-get e :from))))
                                                     edges)))
                          (gethash (plist-get owner :from) agents)))
                   t)
               chain))
    (list :scale scale :tile (* scale drgnx-work-edges-tile-width) :margin margin :chain chain :agents agents
          :labels labels)))

(defun drgnx-work-edges--px (units geometry)
  "UNITS (4 logical pixels each) as a pixel column of the map, margin included."
  (+ (plist-get geometry :margin) (round (* units 4 (plist-get geometry :scale)))))

(defun drgnx-work-edges--look (seg geometry colours)
  "SEG's stroke: (COLOUR WIDTH DASH) in logical pixels; on the chain the accent (an edit: its agent's colour), +1 px."
  (let* ((kind (plist-get seg :kind)) (stroke (drgnx-work-edges-stroke kind))
         (chain (gethash (drgnx-work-edges-key seg) (plist-get geometry :chain)))
         (agent (or (and (integerp chain) chain) (gethash (plist-get seg :from) (plist-get geometry :agents)))))
    (list (cond ((integerp chain) (alist-get (intern (format "agent-%d" chain)) colours))
                (chain (alist-get 'accent colours))
                ((eq (nth 0 stroke) 'agent)
                 (alist-get (if agent (intern (format "agent-%d" agent)) 'edit) colours))
                (t (alist-get (nth 0 stroke) colours)))
          (+ (nth 1 stroke) (if chain 1 0))
          (nth 2 stroke))))

(defun drgnx-work-edges--dash (dash scale)
  "The dash pattern DASH (a string of lengths) scaled to device pixels."
  (mapconcat (lambda (n) (format "%g" (* scale (string-to-number n)))) (split-string dash) " "))

(defun drgnx-work-edges--stroke-attrs (look scale)
  (format " fill=\"none\" stroke=\"%s\" stroke-width=\"%g\"%s/>" (nth 0 look) (* scale (nth 1 look))
          (if (nth 2 look) (format " stroke-dasharray=\"%s\"" (drgnx-work-edges--dash (nth 2 look) scale)) "")))

(defun drgnx-work-edges--seg-crosses-p (seg geometry i)
  "Whether the curve SEG touches tile I."
  (let* ((w (plist-get geometry :tile)) (a (drgnx-work-edges--px (plist-get seg :x0) geometry))
         (b (drgnx-work-edges--px (plist-get seg :x1) geometry)) (slack 2))
    (and (< (min a b) (+ (* (1+ i) w) slack)) (> (max a b) (- (* i w) slack)))))

(defun drgnx-work-edges--port-centre (port geometry)
  "The pixel column of PORT's chip, PORT being (X-UNITS . COUNT)."
  (drgnx-work-edges--px (car port) geometry))

(defun drgnx-work-edges--chip-width (geometry) (round (* 30 (plist-get geometry :scale))))

(defun drgnx-work-edges--port-crosses-p (port geometry i)
  (let ((c (drgnx-work-edges--port-centre port geometry)) (half (/ (drgnx-work-edges--chip-width geometry) 2))
        (w (plist-get geometry :tile)))
    (and (< (- c half) (* (1+ i) w)) (> (+ c half) (* i w)))))

(defun drgnx-work-edges--tile-count (band geometry)
  "How many tiles BAND's curves and ports reach across, counting from the left edge of the map."
  (let ((w (plist-get geometry :tile)) (far 0))
    (dolist (s (plist-get band :segs))
      (setq far (max far (drgnx-work-edges--px (plist-get s :x0) geometry) (drgnx-work-edges--px (plist-get s :x1) geometry))))
    (dolist (p (plist-get band :ports))
      (setq far (max far (+ (drgnx-work-edges--port-centre p geometry) (/ (drgnx-work-edges--chip-width geometry) 2)))))
    (1+ (/ far w))))

;;;; Tiles

(defun drgnx-work-edges--path (seg i geometry height)
  "The path of the curve SEG in the coordinates of tile I, HEIGHT pixels high: a cubic from the band's top to its
bottom, or (an arc between two cards of the row below) an arch that rises from the bottom."
  (let* ((w (plist-get geometry :tile)) (x0 (- (drgnx-work-edges--px (plist-get seg :x0) geometry) (* i w)))
         (x1 (- (drgnx-work-edges--px (plist-get seg :x1) geometry) (* i w))))
    (if (plist-get seg :arc)
        (let ((c (round (* 0.4 height))))
          (format "M%d %dC%d %d %d %d %d %d" x0 height x0 c x1 c x1 height))
      (let ((m (round (/ height 2.0))))
        (format "M%d 0C%d %d %d %d %d %d" x0 x0 m x1 m x1 height)))))

(defun drgnx-work-edges--port-svg (port i geometry colours height)
  "PORT's chip in tile I: a rounded box on the band's bottom edge with \"↑ N\" in it."
  (let* ((scale (plist-get geometry :scale)) (w (plist-get geometry :tile))
         (cw (drgnx-work-edges--chip-width geometry)) (ch (min height (round (* 12 scale))))
         (cx (- (drgnx-work-edges--port-centre port geometry) (* i w))))
    (format (concat "<rect x=\"%d\" y=\"%d\" width=\"%d\" height=\"%d\" rx=\"%d\" fill=\"%s\"/>"
                    "<text x=\"%d\" y=\"%d\" font-size=\"%d\" text-anchor=\"middle\" fill=\"%s\">↑ %d</text>")
            (- cx (/ cw 2)) (- height ch) cw ch (/ ch 2) (alist-get 'chip-bg colours)
            cx (- height (round (* ch 0.22))) (max 6 (round (* ch 0.75))) (alist-get 'chip-fg colours) (cdr port))))

(defun drgnx-work-edges--tile-segs (band i geometry colours)
  "The curves of BAND that cross tile I, with their looks, the chain's last (they draw on top): ((SEG . LOOK) …)."
  (let* ((all (mapcar (lambda (s) (cons s (drgnx-work-edges--look s geometry colours)))
                      (seq-filter (lambda (s) (drgnx-work-edges--seg-crosses-p s geometry i)) (plist-get band :segs))))
         (on (seq-filter (lambda (c) (gethash (drgnx-work-edges-key (car c)) (plist-get geometry :chain))) all)))
    (append (seq-remove (lambda (c) (memq c on)) all) on)))

(defun drgnx-work-edges-tile-svg (band i geometry colours)
  "The SVG text of tile I of BAND (a plist :row :height_units :segs, and :ports as ((X-UNITS . COUNT) …)), or nil when
nothing crosses it.  GEOMETRY and COLOURS are as `drgnx-work-edges-geometry' and `drgnx-work-edges-colours' make them."
  (let* ((scale (plist-get geometry :scale)) (w (plist-get geometry :tile))
         (height (round (* (plist-get band :height_units) 4 scale)))
         (segs (drgnx-work-edges--tile-segs band i geometry colours))
         (ports (seq-filter (lambda (p) (drgnx-work-edges--port-crosses-p p geometry i)) (plist-get band :ports))))
    (when (or segs ports)
      (concat (format "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\">"
                      w height w height)
              (mapconcat (lambda (c)
                           (concat "<path d=\"" (drgnx-work-edges--path (car c) i geometry height) "\""
                                   (drgnx-work-edges--stroke-attrs (cdr c) scale)))
                         segs "")
              (mapconcat (lambda (p) (drgnx-work-edges--port-svg p i geometry colours height)) ports "")
              "</svg>"))))

(defun drgnx-work-edges--label (geometry id)
  (let ((labels (plist-get geometry :labels)))
    (or (and (hash-table-p labels) (gethash id labels)) (and (functionp labels) (funcall labels id)) id)))

(defun drgnx-work-edges--alt (band i geometry)
  "The alternative text of tile I: the edges that cross it, in words (\"hub rows → rp-df-hub (came from)\")."
  (let ((segs (seq-filter (lambda (s) (drgnx-work-edges--seg-crosses-p s geometry i)) (plist-get band :segs)))
        (ports (seq-filter (lambda (p) (drgnx-work-edges--port-crosses-p p geometry i)) (plist-get band :ports))))
    (concat "Edges: "
            (mapconcat (lambda (s) (format "%s → %s (%s)" (drgnx-work-edges--label geometry (plist-get s :from))
                                           (drgnx-work-edges--label geometry (plist-get s :to))
                                           (or (cdr (assoc (plist-get s :kind) drgnx-work-edges--kind-words)) (plist-get s :kind))))
                       segs ", ")
            (if (and segs ports) ", " "")
            (mapconcat (lambda (p) (format "%d more arrive by a port" (cdr p))) ports ", "))))

(defun drgnx-work-edges--image (svg alt)
  "The image of SVG, the very same object for the same SVG and ALT."
  (let ((key (cons svg alt)))
    (or (gethash key drgnx-work-edges--images)
        (progn
          (when (> (hash-table-count drgnx-work-edges--images) 600) (clrhash drgnx-work-edges--images))
          (puthash key (list 'image :type 'svg :data svg :ascent 100 :scale 1 :alt alt) drgnx-work-edges--images)))))

(defun drgnx-work-edges-tile (band i geometry colours)
  "The image of tile I of BAND, or nil when nothing crosses it.  Cached by what it draws: a tile whose strokes did not
change is the same object."
  (when-let* ((svg (drgnx-work-edges-tile-svg band i geometry colours)))
    (drgnx-work-edges--image svg (drgnx-work-edges--alt band i geometry))))

(defun drgnx-work-edges-band-tiles (band geometry colours)
  "BAND's tiles from the left: a list with an image or nil for each."
  (mapcar (lambda (i) (drgnx-work-edges-tile band i geometry colours))
          (number-sequence 0 (1- (drgnx-work-edges--tile-count band geometry)))))

(defun drgnx-work-edges-band-text (band geometry colours)
  "The text of BAND's line, without its newline: each tile an image at its column, or nil when the band draws nothing.
The characters are in `drgnx-work-band', so the line is no higher than its tiles."
  (let ((i -1) (w (plist-get geometry :tile)) parts)
    (dolist (image (drgnx-work-edges-band-tiles band geometry colours))
      (cl-incf i)
      (when image
        (push (propertize " " 'display (list 'space :align-to (* i w)) 'face 'drgnx-work-band) parts)
        (push (propertize " " 'display image 'face 'drgnx-work-band) parts)))
    (and parts (apply #'concat (nreverse parts)))))

(defun drgnx-work-edges-flush (old new)
  "Free the cached raster of the tile image OLD when NEW is not the same image."
  (when (and old (not (eq old new)) (display-graphic-p) (fboundp 'image-flush))
    (image-flush old)))

;;;; Lanes

(defun drgnx-work-edges-row-metrics ()
  "What a lane image must match in a card row: (HEIGHT . ASCENT) with HEIGHT the text's height in pixels and ASCENT the
share of it above the baseline, in percent.  The image then takes the row's ascent and descent, and the row keeps its
height."
  (let* ((info (and (display-graphic-p) (ignore-errors (font-info (face-font 'default nil ?a)))))
         (ascent (and info (aref info 4))) (descent (and info (aref info 5))))
    (if (and (integerp ascent) (integerp descent) (> (+ ascent descent) 0))
        (cons (+ ascent descent) (max 1 (min 100 (round (* 100.0 ascent) (+ ascent descent)))))
      (cons (frame-char-height) 80))))

(defun drgnx-work-edges-lane (lane geometry colours height ascent)
  "The image of LANE (a plist with :kind :from :to) in a card row: a vertical stroke HEIGHT pixels high with the row's
ASCENT (percent), as wide as its stroke, 2 px at least."
  (let* ((scale (plist-get geometry :scale)) (look (drgnx-work-edges--look lane geometry colours))
         (width (max 2 (nth 1 look))) (px (round (* width scale))))
    (list 'image :type 'svg :ascent ascent :scale 1
          :alt (format "Edge %s → %s (%s)" (drgnx-work-edges--label geometry (plist-get lane :from))
                       (drgnx-work-edges--label geometry (plist-get lane :to))
                       (or (cdr (assoc (plist-get lane :kind) drgnx-work-edges--kind-words)) (plist-get lane :kind)))
          :data (concat (format "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\">"
                                px height px height)
                        (format "<path d=\"M%g 0V%d\"" (/ px 2.0) height)
                        (drgnx-work-edges--stroke-attrs look scale)
                        "</svg>"))))

(defun drgnx-work-edges-lane-parts (row-index lanes geometry colours)
  "The lanes of card row ROW-INDEX among LANES (plists :row :x :from :to :kind), as ((COLUMN . STRING) …): the string
places the lane's image at its column.  One set for each text line of the row."
  (let ((metrics (drgnx-work-edges-row-metrics)) parts)
    (dolist (lane lanes)
      (when (eql (plist-get lane :row) row-index)
        (let* ((image (drgnx-work-edges-lane lane geometry colours (car metrics) (cdr metrics)))
               (width (round (* (max 2 (nth 1 (drgnx-work-edges--look lane geometry colours))) (plist-get geometry :scale))))
               (column (- (drgnx-work-edges--px (plist-get lane :x) geometry) (/ width 2))))
          (push (cons column
                      (concat (propertize " " 'display (list 'space :align-to column))
                              (propertize " " 'display image)))
                parts))))
    (nreverse parts)))

(provide 'drgnx-work-edges)
;;; drgnx-work-edges.el ends here
