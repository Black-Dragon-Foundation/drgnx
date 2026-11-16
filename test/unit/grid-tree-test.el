;;; grid-tree-test.el --- batch tests: the grid's tree as data (format, validation, sizes, zones, letters) -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-paths)
(require 'drgnx-grid-tree)

(defconst drgnx-grid-tree-test--six
  '(row :px nil :share 1.0
        (tile :px 300 :share 0.25 :id 1 :kinds (side-bar) :shown side-bar :dock left :state (:place explorer))
        (col :px 600 :share 0.5
             (row :px 500 :share 0.7
                  (editor :px 300 :share 0.5 :id 2 :tabs ("/tmp/a.el" "/tmp/b.el") :shown "/tmp/a.el" :point 1 :start 1)
                  (editor :px 300 :share 0.5 :id 3 :tabs ("/tmp/c.el") :shown "/tmp/c.el" :point 4 :start 1))
             (tile :px 200 :share 0.3 :id 4 :kinds (terminal problems) :shown terminal :dock bottom :state nil))
        (col :px 300 :share 0.25
             (tile :px 400 :share 0.5 :id 5 :kinds (agent-panel) :shown agent-panel :dock right :state nil)
             (tile :px 400 :share 0.5 :id 6 :kinds (work-map) :shown work-map :dock nil :state (:view map))))
  "Six leaves: a docked side bar, two editors over a panel, and a right column of two tiles.")

(ert-deftest drgnx-grid-tree/valid-accepts-a-six-tile-tree ()
  (should (eq (drgnx-grid-valid-tree-p drgnx-grid-tree-test--six) t))
  (should (= 6 (length (drgnx-grid-tree-leaves drgnx-grid-tree-test--six))))
  ;; a lone tile is a tree too (full size)
  (should (drgnx-grid-valid-tree-p '(editor :px nil :share 1.0 :id 1 :tabs nil :shown nil :point 1 :start 1))))

(ert-deftest drgnx-grid-tree/valid-accepts-instance-entries ()
  ;; a kind's instance (an agent panel's session) is (KIND . KEY) in a tile's stack
  (should (drgnx-grid-valid-tree-p '(tile :px nil :share 1.0 :id 1
                                          :kinds ((agent-panel . "s2") agent-panel (agent-panel . 3))
                                          :shown (agent-panel . "s2"))))
  (dolist (bad '(((agent-panel . ("x"))) (("k" . "s")) ((nil . "s"))))
    (should-not (drgnx-grid-valid-tree-p `(tile :px nil :share 1.0 :id 1 :kinds ,bad :shown nil)))))

(ert-deftest drgnx-grid-tree/valid-rejects-junk ()
  (dolist (junk (list nil 42 "row" '(tile :px "x")
                      '(tile :px 0 :share 0.5 :id 1 :kinds (a) :shown a)       ; px out of range
                      '(tile :px 20001 :share 0.5 :id 1 :kinds (a) :shown a)
                      '(row :px nil :share 1.0 (tile :px 10 :share 1.5 :id 1 :kinds (a) :shown a)
                            (tile :px 10 :share 0.5 :id 2 :kinds (a) :shown a)) ; share > 1
                      '(row :px nil :share 1.0 (tile :px 10 :share 0.5 :id 1 :kinds (a) :shown a)) ; one child
                      '(tile :px 10 :share 0.5 :id 1 :kinds ("a") :shown a)    ; a non-symbol kind
                      '(window :px 10)                                          ; no such node
                      '(tile :px 10 :share 0.5 :id 1 :kinds (a) :shown a :dock top)
                      '(tile :px 10 . 5)))                                      ; not a proper list
    (should-not (drgnx-grid-valid-tree-p junk)))
  ;; a buffer, a marker or a window object anywhere, even in a tile's state
  (with-temp-buffer
    (should-not (drgnx-grid-valid-tree-p `(tile :px 10 :share 0.5 :id 1 :kinds (a) :shown a :state (:b ,(current-buffer)))))
    (should-not (drgnx-grid-valid-tree-p `(editor :px 10 :share 0.5 :id 1 :tabs (,(point-marker)) :shown nil))))
  (should-not (drgnx-grid-valid-tree-p `(tile :px 10 :share 0.5 :id 1 :kinds (a) :shown a :state (:w ,(selected-window)))))
  ;; 10,000 deep: refused without a stack overflow
  (let ((deep '(tile :px 10 :share 0.5 :id 1 :kinds (a) :shown a)))
    (dotimes (i 10000)
      (setq deep (list 'row :px 10 :share 0.5 deep (list 'tile :px 10 :share 0.5 :id (+ i 2) :kinds '(a) :shown 'a))))
    (should-not (drgnx-grid-valid-tree-p deep)))
  ;; 65 leaves in one row: too many; 64 are fine
  (let ((row (lambda (n) (append '(row :px nil :share 1.0)
                                 (cl-loop for i from 1 to n
                                          collect (list 'tile :px 10 :share (/ 1.0 n) :id i :kinds '(a) :shown 'a))))))
    (should (drgnx-grid-valid-tree-p (funcall row 64)))
    (should-not (drgnx-grid-valid-tree-p (funcall row 65)))))

(ert-deftest drgnx-grid-tree/unknown-kinds-are-valid ()
  (should (drgnx-grid-valid-tree-p
           '(row :px nil :share 1.0
                 (tile :px 400 :share 0.5 :id 1 :kinds (a-module-not-loaded) :shown a-module-not-loaded)
                 (editor :px 400 :share 0.5 :id 2 :tabs nil :shown nil :point 1 :start 1)))))

(ert-deftest drgnx-grid-tree/logical-round-trip-at-1-1.25-2 ()
  (dolist (scale '(1.0 1.25 2.0))
    (dotimes (logical 2001)
      (let ((px (drgnx-grid-tree-from-logical logical scale)))
        (should (= px (floor (+ (* logical scale) 0.5 1e-9))))   ; rounded half up, as `drgnx-px'
        (should (= logical (drgnx-grid-tree-to-logical px scale))))))
  ;; half up, never to even
  (should (= 3 (drgnx-grid-tree-to-logical 5 2.0)))
  (should (= 4 (drgnx-grid-tree-to-logical 7 2.0))))

(ert-deftest drgnx-grid-tree/zones-on-400x300 ()
  ;; a 9 × 7 grid of points over a 400 × 300 tile at (100, 50): x = 100 + 50i, y = 50 + 50j
  (let ((edges '(100 50 500 350))
        (expected ;; rows j = 0..6, columns i = 0..8
         ;; the outer quarter of each side is its zone (25 % exactly is the middle), a corner goes to the nearer side
         ;; (a tie to the left or right side)
         '((left  above above above above above above above right)       ; y = 50 (fy 0)
           (left  left  above above above above above right right)       ; y = 100 (fy 1/6)
           (left  left  center center center center center right right)  ; y = 150 (fy 1/3)
           (left  left  center center center center center right right)  ; y = 200 (fy 1/2)
           (left  left  center center center center center right right)  ; y = 250 (fy 2/3)
           (left  left  below below below below below right right)       ; y = 300 (fy 5/6)
           (left  below below below below below below below right))))    ; y = 350 (fy 1)
    (dotimes (j 7)
      (dotimes (i 9)
        (let ((x (+ 100 (* 50 i))) (y (+ 50 (* 50 j))))
          (should (equal (list x y (drgnx-grid-zone edges x y))
                         (list x y (nth i (nth j expected))))))))))

(ert-deftest drgnx-grid-tree/letters-home-row-first ()
  (should (equal (drgnx-grid-letters 10) '(?a ?s ?d ?f ?j ?k ?l ?\; ?g ?h)))
  (should (equal (drgnx-grid-letters 3) '(?a ?s ?d)))
  (let ((all (drgnx-grid-letters 40)))
    (should (= (length all) 27))                        ; 10 home-row keys, then the 17 other letters of a–z
    (should (equal (seq-take (nthcdr 10 all) 3) '(?b ?c ?e)))
    (should (= (length (delete-dups (copy-sequence all))) (length all)))))

(ert-deftest drgnx-grid-tree/leaves-in-reading-order ()
  (should (equal (mapcar (lambda (l) (plist-get (cdr l) :id)) (drgnx-grid-tree-leaves drgnx-grid-tree-test--six))
                 '(1 2 3 4 5 6))))

(provide 'grid-tree-test)
;;; grid-tree-test.el ends here
