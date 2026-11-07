;;; work-edges-test.el --- the map's edges: SVG band tiles, lanes and ports -*- lexical-binding: t -*-
;; test-class: det
;; An edge tile is a function of the band's curves, the chain and the colours the faces give: strings and image
;; specs, no hub, process or clock.  Pattern D: pure.
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-work-client)
(load (expand-file-name "test/fixtures/work-space-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-work-map" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-work-edges" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/work-space))

(declare-function drgnx-work-edges-tile-svg "drgnx-work-edges")
(declare-function drgnx-work-edges-tile "drgnx-work-edges")
(declare-function drgnx-work-edges-colours "drgnx-work-edges")
(declare-function drgnx-work-edges-stroke "drgnx-work-edges")
(declare-function drgnx-work-edges-lane "drgnx-work-edges")
(declare-function drgnx-work-edges-row-metrics "drgnx-work-edges")
(declare-function drgnx-work-edges-geometry "drgnx-work-edges")
(declare-function drgnx-work-edges-lane-parts "drgnx-work-edges")
(declare-function drgnx-work-map-row-text "drgnx-work-map")
(defvar drgnx-work-map-scale)

(defconst drgnx-work-edges-test--colours
  '((edge . "#101010") (edit . "#202020") (accent . "#303030") (warn . "#404040") (chip-bg . "#505050")
    (chip-fg . "#606060") (agent-1 . "#a1a1a1") (agent-2 . "#a2a2a2") (agent-3 . "#a3a3a3")
    (agent-4 . "#a4a4a4") (agent-5 . "#a5a5a5") (agent-6 . "#a6a6a6"))
  "Distinct colours, so a test can tell which one a stroke took.")

(defun drgnx-work-edges-test--geometry (&optional chain)
  "A scale-1 geometry with no margin; CHAIN a list of (KEY . N-or-t)."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (c chain) (puthash (car c) (cdr c) table))
    (list :scale 1 :tile 192 :margin 0 :chain table :agents (make-hash-table :test #'equal)
          :labels (make-hash-table :test #'equal))))

(defun drgnx-work-edges-test--band (&rest segs)
  (list :row 1 :height_units 8 :segs segs))

(defun drgnx-work-edges-test--seg (from to kind x0 x1 &optional arc)
  (list :from from :to to :kind kind :x0 x0 :x1 x1 :arc arc))

(ert-deftest drgnx-work-edges/tile-string-golden ()
  ;; one came-from curve from unit 5 to unit 12 in a band of 8 units: 20 px to 48 px over 32 px
  (let ((band (drgnx-work-edges-test--band (drgnx-work-edges-test--seg "a" "b" "came-from" 5 12))))
    (should (equal (drgnx-work-edges-tile-svg band 0 (drgnx-work-edges-test--geometry)
                                              drgnx-work-edges-test--colours)
                   (concat "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"192\" height=\"32\" "
                           "viewBox=\"0 0 192 32\"><path d=\"M20 0C20 16 48 16 48 32\" fill=\"none\" "
                           "stroke=\"#101010\" stroke-width=\"1\"/></svg>")))))

(ert-deftest drgnx-work-edges/only-crossed-tiles-rebuild ()
  ;; two curves, one in tile 0 and one in tile 2; the chain moves to the second: tile 0 is the very same image,
  ;; tile 2 a new one, tile 1 (crossed by nothing) has none
  (let* ((a (drgnx-work-edges-test--seg "a" "b" "came-from" 5 6))
         (b (drgnx-work-edges-test--seg "c" "d" "came-from" 100 101))
         (band (drgnx-work-edges-test--band a b))
         (plain (drgnx-work-edges-test--geometry))
         (chained (drgnx-work-edges-test--geometry '(("c>d>came-from" . t))))
         (tiles (lambda (g) (mapcar (lambda (i) (drgnx-work-edges-tile band i g drgnx-work-edges-test--colours))
                                    '(0 1 2)))))
    (let ((before (funcall tiles plain)) (after (funcall tiles chained)) (again (funcall tiles plain)))
      (should (null (nth 1 before)))
      (should (null (nth 1 after)))
      (should (eq (nth 0 before) (nth 0 after)))
      (should-not (eq (nth 2 before) (nth 2 after)))
      (should (eq (nth 2 before) (nth 2 again))))))

(ert-deftest drgnx-work-edges/colours-come-from-faces ()
  ;; a face's colour is what the stroke takes: no literal in the module
  (let ((old (face-default-spec 'drgnx-work-edge))
        (band (drgnx-work-edges-test--band (drgnx-work-edges-test--seg "a" "b" "came-from" 5 12))))
    (unwind-protect
        (progn
          (face-spec-set 'drgnx-work-edge '((t :foreground "#123456")) 'face-defface-spec)
          (should (equal "#123456" (alist-get 'edge (drgnx-work-edges-colours))))
          (should (string-search "stroke=\"#123456\""
                                 (drgnx-work-edges-tile-svg band 0 (drgnx-work-edges-test--geometry)
                                                            (drgnx-work-edges-colours))))
          (face-spec-set 'drgnx-work-edge '((t :foreground "#654321")) 'face-defface-spec)
          (should (string-search "stroke=\"#654321\""
                                 (drgnx-work-edges-tile-svg band 0 (drgnx-work-edges-test--geometry)
                                                            (drgnx-work-edges-colours)))))
      (face-spec-set 'drgnx-work-edge old 'face-defface-spec))))

(ert-deftest drgnx-work-edges/edit-edges-neutral-off-the-chain ()
  (let ((band (drgnx-work-edges-test--band (drgnx-work-edges-test--seg "b" "f" "edits" 5 12))))
    (let ((off (drgnx-work-edges-tile-svg band 0 (drgnx-work-edges-test--geometry)
                                          drgnx-work-edges-test--colours))
          (on (drgnx-work-edges-tile-svg band 0 (drgnx-work-edges-test--geometry '(("b>f>edits" . 3)))
                                         drgnx-work-edges-test--colours)))
      (should (string-search "stroke=\"#202020\" stroke-width=\"2\"" off))
      (should-not (string-search "#a3a3a3" off))
      ;; on the chain: the agent's colour, one pixel wider
      (should (string-search "stroke=\"#a3a3a3\" stroke-width=\"3\"" on))
      (should-not (string-search "#202020" on)))
    ;; a chain edge that is not an edit takes the accent
    (let ((on (drgnx-work-edges-tile-svg
               (drgnx-work-edges-test--band (drgnx-work-edges-test--seg "a" "b" "came-from" 5 12)) 0
               (drgnx-work-edges-test--geometry '(("a>b>came-from" . t))) drgnx-work-edges-test--colours)))
      (should (string-search "stroke=\"#303030\" stroke-width=\"2\"" on)))))

(ert-deftest drgnx-work-edges/patterns-differ-not-only-colour ()
  ;; every edge kind has its own (width, dash): colour is never the only difference
  (let* ((kinds '("came-from" "edits" "reads" "runs-on" "based-on" "overlap" "read-vs-edit"))
         (looks (mapcar (lambda (k) (cdr (drgnx-work-edges-stroke k))) kinds)))
    (should (= (length kinds) (length (delete-dups (copy-sequence looks)))))
    (should (equal "6 4" (nth 1 (cdr (drgnx-work-edges-stroke "overlap")))))
    (should (equal 2 (car (cdr (drgnx-work-edges-stroke "overlap")))))))

(ert-deftest drgnx-work-edges/alt-names-the-edges ()
  (let* ((geometry (drgnx-work-edges-test--geometry))
         (band (drgnx-work-edges-test--band
                (drgnx-work-edges-test--seg "agent:a1" "branch:x" "came-from" 5 12)
                (drgnx-work-edges-test--seg "agent:a1" "agent:a2" "overlap" 5 40 t))))
    (puthash "agent:a1" "hub rows" (plist-get geometry :labels))
    (puthash "branch:x" "rp-df-hub" (plist-get geometry :labels))
    (let ((alt (plist-get (cdr (drgnx-work-edges-tile band 0 geometry drgnx-work-edges-test--colours)) :alt)))
      (should (string-search "hub rows" alt))
      (should (string-search "rp-df-hub" alt))
      (should (string-search "came from" alt))
      (should (string-search "overlaps" alt))
      ;; an item without a label is named by its id
      (should (string-search "agent:a2" alt)))))

(ert-deftest drgnx-work-edges/lane-takes-the-row-ascent ()
  ;; the lane is as high as the row's text and carries the row's ascent, so the row does not grow
  (let* ((geometry (drgnx-work-edges-test--geometry))
         (image (drgnx-work-edges-lane '(:kind "edits" :from "b" :to "f") geometry
                                       drgnx-work-edges-test--colours 18 78)))
    (should (eq 'image (car image)))
    (should (equal 78 (plist-get (cdr image) :ascent)))
    (should (string-search "height=\"18\"" (plist-get (cdr image) :data)))
    (should (string-search "width=\"2\"" (plist-get (cdr image) :data)))
    (should (string-search "stroke=\"#202020\"" (plist-get (cdr image) :data))))
  (let ((m (drgnx-work-edges-row-metrics)))
    (should (and (integerp (car m)) (> (car m) 0)))
    (should (and (integerp (cdr m)) (<= 1 (cdr m) 100)))))

(ert-deftest drgnx-work-edges/lanes-on-one-column-draw-once ()
  ;; lanes at the same x are one line on screen; drawn one image each, side by side in the text, five of them took
  ;; 10 px of a 12 px gap and pushed the next card right.  One image per column: the chain's stroke when one of them
  ;; is on the chain, its alt naming every edge there
  (let* ((geometry (drgnx-work-edges-test--geometry '(("p>s2>came-from" . t))))
         (lanes (list (list :row 3 :x 150 :from "p" :to "s1" :kind "came-from")
                      (list :row 3 :x 150 :from "p" :to "s2" :kind "came-from")
                      (list :row 3 :x 150 :from "p" :to "s3" :kind "came-from")
                      (list :row 3 :x 149 :from "q" :to "s4" :kind "came-from")
                      (list :row 4 :x 150 :from "p" :to "s5" :kind "came-from")))
         (parts (drgnx-work-edges-lane-parts 3 lanes geometry drgnx-work-edges-test--colours)))
    (should (equal (mapcar #'car parts) '(599 595)))
    (let ((image (get-text-property 1 'display (cdr (car parts)))))
      (should (string-search "stroke=\"#303030\"" (plist-get (cdr image) :data)))
      (dolist (to '("s1" "s2" "s3")) (should (string-search to (plist-get (cdr image) :alt)))))))

(ert-deftest drgnx-work-edges/the-fixture-draws-bands-lanes-and-a-port ()
  (let* ((drgnx-work-map-scale 1) (state (drgnx-work-client-init (drgnx-work-fixture-frame)))
         (has-image (lambda (s) (let ((pos 0) found)
                                  (while (and (not found) (< pos (length s)))
                                    (when (eq 'image (car-safe (get-text-property pos 'display s))) (setq found t))
                                    (setq pos (1+ pos)))
                                  found))))
    ;; every band of the fixture carries curves; the lane rows carry lanes
    (dolist (key '((:band 2 0 0) (:band 3 0 0) (:band 4 0 0) (:band 5 0 0) (:band 4 0 1) (:band 6 0 0)))
      (should (funcall has-image (drgnx-work-map-row-text state key))))
    ;; the branches' row holds a lane, the agents' first row none
    (should (funcall has-image (drgnx-work-map-row-text state '(:row 5 0 0))))
    (should-not (funcall has-image (drgnx-work-map-row-text state '(:row 4 0 0))))))

(provide 'work-edges-test)
;;; work-edges-test.el ends here
