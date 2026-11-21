;;; drgnx-grid-tree.el --- The grid's tree as data: format, validation, logical sizes, zones, letters -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The tiled grid is Emacs's own window tree; this file is only its snapshot format (`TREE'), used for full size, the
;; layout undo stack and saved layouts.  Pure functions, safe in batch.  A TREE is one of:
;;   (row :px N :share F CHILD...)   children side by side
;;   (col :px N :share F CHILD...)   children stacked
;;   (tile :px N :share F :id I :kinds (ENTRY...) :shown ENTRY :dock DOCK :state PLIST)
;;   (editor :px N :share F :id I :tabs (FILE...) :shown FILE :point P :start S)
;; An ENTRY is a pane kind (a symbol) or (KIND . KEY), one instance of a kind (an agent panel's session: KEY a string,
;; number or symbol).
;; :px is logical pixels along the parent's direction (nil at the root), :share the node's part of its parent, in
;; (0, 1].  A restored tree is checked by `drgnx-grid-valid-tree-p' before anything is built from it.
;; See docs/develop/core.md, "The grid".

;;; Code:
(require 'cl-lib)

(defconst drgnx-grid-tree-max-depth 16 "The deepest a valid TREE nests.")
(defconst drgnx-grid-tree-max-leaves 64 "The most leaves a valid TREE has.")
(defconst drgnx-grid-tree-max-px 20000 "The largest :px a valid TREE gives a node.")
(defconst drgnx-grid-zone-edge 0.25 "The part of a tile's width or height, from each side, that is that side's drop zone.")

(defun drgnx-grid-tree--plist-p (plist)
  "Non-nil when PLIST is a proper list of keyword and value pairs."
  (and (proper-list-p plist) (cl-evenp (length plist))
       (cl-loop for (k _v) on plist by #'cddr always (keywordp k))))

(defun drgnx-grid-tree-entry-p (x)
  "Non-nil when X is a tile's stack entry: a kind (a symbol), or (KIND . KEY), KEY a string, number or symbol."
  (or (symbolp x)
      (and (consp x) (car x) (symbolp (car x)) (or (stringp (cdr x)) (numberp (cdr x)) (symbolp (cdr x))))))

(defun drgnx-grid-tree--plain-p (x depth)
  "Non-nil when X holds only plain data (numbers, strings, symbols, conses), no deeper than DEPTH: never a buffer, a
marker, a window, a frame, a process or any other object that cannot be written and read back."
  (cond ((or (null x) (numberp x) (stringp x) (symbolp x)) t)
        ((consp x) (and (> depth 0)
                        (let ((ok t) (n 0))
                          (while (and ok (consp x) (< n 10000))
                            (setq ok (drgnx-grid-tree--plain-p (car x) (1- depth)) x (cdr x) n (1+ n)))
                          (and ok (< n 10000) (drgnx-grid-tree--plain-p x (1- depth))))))
        (t nil)))

(defun drgnx-grid-tree--px-ok (px root)
  (if root (or (null px) (and (integerp px) (<= 1 px drgnx-grid-tree-max-px)))
    (and (integerp px) (<= 1 px drgnx-grid-tree-max-px))))

(defun drgnx-grid-tree--share-ok (share)
  (or (null share) (and (numberp share) (> share 0) (<= share 1))))

(defun drgnx-grid-tree--check (node depth root leaves)
  "Check NODE at DEPTH (ROOT non-nil at the top); LEAVES is a one-element list counting leaves.  Throws `bad' on junk."
  (unless (and (consp node) (proper-list-p node) (<= depth drgnx-grid-tree-max-depth)) (throw 'bad nil))
  (let ((type (car node)))
    (pcase type
      ((or 'row 'col)
       (let* ((props (list (nth 1 node) (nth 2 node) (nth 3 node) (nth 4 node)))
              (children (nthcdr 5 node)))
         (unless (and (eq (nth 0 props) :px) (eq (nth 2 props) :share)
                      (drgnx-grid-tree--px-ok (nth 1 props) root) (drgnx-grid-tree--share-ok (nth 3 props))
                      (>= (length children) 2))
           (throw 'bad nil))
         (dolist (c children) (drgnx-grid-tree--check c (1+ depth) nil leaves))))
      ((or 'tile 'editor)
       (let ((p (cdr node)))
         (unless (and (drgnx-grid-tree--plist-p p)
                      (drgnx-grid-tree--px-ok (plist-get p :px) root)
                      (drgnx-grid-tree--share-ok (plist-get p :share))
                      (let ((id (plist-get p :id))) (or (null id) (natnump id)))
                      (drgnx-grid-tree--plain-p p 8))
           (throw 'bad nil))
         (if (eq type 'tile)
             (let ((kinds (plist-get p :kinds)))
               (unless (and (proper-list-p kinds) (cl-every #'drgnx-grid-tree-entry-p kinds)
                            (drgnx-grid-tree-entry-p (plist-get p :shown))
                            (memq (plist-get p :dock) '(nil left right bottom))
                            (drgnx-grid-tree--plist-p (plist-get p :state)))
                 (throw 'bad nil)))
           (let ((tabs (plist-get p :tabs)) (shown (plist-get p :shown)))
             (unless (and (proper-list-p tabs) (cl-every #'stringp tabs) (or (null shown) (stringp shown))
                          (let ((pt (plist-get p :point)) (st (plist-get p :start)))
                            (and (or (null pt) (natnump pt)) (or (null st) (natnump st)))))
               (throw 'bad nil))))
         (when (> (cl-incf (car leaves)) drgnx-grid-tree-max-leaves) (throw 'bad nil))))
      (_ (throw 'bad nil)))))

(defun drgnx-grid-valid-tree-p (tree)
  "t when TREE is a valid grid tree (see the Commentary), else nil.
It rejects non-lists, objects that cannot be read back (buffers, markers, windows), a depth over
`drgnx-grid-tree-max-depth', more than `drgnx-grid-tree-max-leaves' leaves, a non-symbol kind, a :px outside
1–`drgnx-grid-tree-max-px', a :share outside (0, 1] and a row or col with fewer than two children.  Unknown kinds are
valid: their tiles become placeholders."
  (catch 'bad
    (drgnx-grid-tree--check tree 0 t (list 0))
    t))

(defun drgnx-grid-tree-join (type children pxs total scale)
  "CHILDREN (nodes) as one node of TYPE (`row' or `col'), each given its part of TOTAL frame pixels at SCALE (frame
pixels per logical pixel): its PXS entry, nil an equal share of what the others leave; each child gets its :px
(logical, clamped) and :share (a child taken from a root, which has none, too).  One child alone is that child."
  (if (null (cdr children)) (car children)
    (let* ((known (apply #'+ (delq nil (copy-sequence pxs))))
           (rest (max 1 (- total known)))
           (pxs (mapcar (lambda (p) (or p (max 1 (/ rest (max 1 (cl-count nil pxs)))))) pxs))
           (sum (float (apply #'+ pxs))))
      (append (list type :px nil :share nil)
              (cl-mapcar (lambda (c p)
                           (let ((sizes (list :px (max 1 (min drgnx-grid-tree-max-px (drgnx-grid-tree-to-logical p scale)))
                                              :share (max 1e-4 (min 1.0 (/ p sum))))))
                             (if (memq (car c) '(row col))
                                 (append (list (car c)) sizes (nthcdr 5 c))
                               (cons (car c) (append sizes (cl-loop for (k v) on (cdr c) by #'cddr
                                                                    unless (memq k '(:px :share)) append (list k v)))))))
                         children pxs)))))

(defun drgnx-grid-tree-leaves (tree)
  "The leaves (`tile' and `editor' nodes) of TREE in order, top-left to bottom-right."
  (if (memq (car-safe tree) '(row col))
      (mapcan #'drgnx-grid-tree-leaves (nthcdr 5 tree))
    (list tree)))

(defconst drgnx-grid-tree--epsilon 1e-9 "As `drgnx-pixels--epsilon': forgives a product its last float bit.")

(defun drgnx-grid-tree-to-logical (px scale)
  "PX frame pixels as logical pixels at SCALE (frame pixels per logical pixel), rounded half up."
  (floor (+ (/ (float px) scale) 0.5 drgnx-grid-tree--epsilon)))

(defun drgnx-grid-tree-from-logical (logical scale)
  "LOGICAL pixels as frame pixels at SCALE, rounded half up, as `drgnx-px' rounds."
  (floor (+ (* logical scale) 0.5 drgnx-grid-tree--epsilon)))

(defun drgnx-grid-zone (edges x y)
  "Where X, Y falls in a tile with pixel EDGES (LEFT TOP RIGHT BOTTOM): `left', `right', `above' or `below' in the
outer `drgnx-grid-zone-edge' of that side (a split there), else `center' (a stack).  A corner goes to the nearer
side, a tie to the left or right side."
  (let* ((w (max 1 (- (nth 2 edges) (nth 0 edges)))) (h (max 1 (- (nth 3 edges) (nth 1 edges))))
         (fx (/ (float (- x (nth 0 edges))) w)) (fy (/ (float (- y (nth 1 edges))) h))
         (best 'center) (d drgnx-grid-zone-edge))
    (pcase-dolist (`(,side . ,dist) `((left . ,fx) (right . ,(- 1 fx)) (above . ,fy) (below . ,(- 1 fy))))
      (when (< dist d) (setq best side d dist)))
    best))

(defconst drgnx-grid-letters-home '(?a ?s ?d ?f ?j ?k ?l ?\; ?g ?h) "The switcher's first letters, home row first.")

(defun drgnx-grid-letters (n)
  "The first N switcher letters: `drgnx-grid-letters-home', then the rest of a–z in order (at most 27)."
  (let ((all (append drgnx-grid-letters-home
                     (cl-loop for c from ?a to ?z unless (memq c drgnx-grid-letters-home) collect c))))
    (cl-subseq all 0 (min n (length all)))))

(provide 'drgnx-grid-tree)
;;; drgnx-grid-tree.el ends here
