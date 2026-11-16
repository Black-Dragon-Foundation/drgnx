;;; grid-tree-live-test.el --- batch tests: a frame's grid as a tree, its apply, full size -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/grid-fixture" drgnx-dir) nil t)   ; `drgnx-grid-test--with' and its kinds
(require 'drgnx-groups)

(defun drgnx-grid-tree-live-test--six ()
  "Six tiles: the left tile (Tree), three editor tiles (two side by side, one below), Chat at the right, Term at the
bottom.  Returns the editors."
  (let* ((one (selected-window)) (two (drgnx-groups-split-right)))
    (select-window one)
    (let ((three (drgnx-groups-split-down)))
      (drgnx-pane-show 'g-tree) (drgnx-pane-show 'g-chat) (drgnx-pane-show 'g-term)
      (select-window one)
      (drgnx-state-sync)
      (list one two three))))

(defun drgnx-grid-tree-live-test--by-id ()
  "Alist tile id → (WINDOW . pixel edges) of the frame's tiles."
  (mapcar (lambda (w) (cons (window-parameter w 'drgnx-tile-id) (cons w (window-pixel-edges w))))
          (drgnx-grid-tiles)))

(defun drgnx-grid-tree-live-test--edges ()
  (sort (mapcar (lambda (e) (cons (car e) (cddr e))) (drgnx-grid-tree-live-test--by-id))
        (lambda (a b) (< (car a) (car b)))))

(defun drgnx-grid-tree-live-test--shares (tree)
  "Every node's :share in TREE, in order."
  (cons (plist-get (cdr tree) :share)
        (and (memq (car tree) '(row col)) (mapcan #'drgnx-grid-tree-live-test--shares (nthcdr 5 tree)))))

(ert-deftest drgnx-grid-tree-live/round-trip-six-tiles-exact ()
  (drgnx-grid-test--with
    (pcase-let ((`(,_one ,two ,_three) (drgnx-grid-tree-live-test--six)))
      (let* ((tree (drgnx-grid-tree)) (edges (drgnx-grid-tree-live-test--edges)))
        (should (drgnx-grid-valid-tree-p tree))
        (should (= 6 (length (drgnx-grid-tree-leaves tree))))
        ;; change it: a tile hidden, an editor closed, a size changed
        (drgnx-pane-hide 'g-term)
        (let ((window-resize-pixelwise t)) (window-resize (drgnx-pane-window 'g-chat) 7 t nil t))
        (let ((ignore-window-parameters t)) (delete-window two))
        (should (drgnx-grid-apply-tree tree))
        (should (equal (drgnx-grid-tree-live-test--edges) edges))
        (should (equal (drgnx-grid-tree) tree))))))

(ert-deftest drgnx-grid-tree-live/apply-keeps-surviving-windows ()
  (drgnx-grid-test--with
    (drgnx-grid-tree-live-test--six)
    (let* ((tree (drgnx-grid-tree)))
      (drgnx-pane-hide 'g-chat)
      (let ((kept (drgnx-grid-tree-live-test--by-id)))
        (drgnx-grid-apply-tree tree)
        (pcase-dolist (`(,id ,w . ,_) kept)
          (should (eq (window-parameter w 'drgnx-tile-id) id))
          (should (window-live-p w))
          (should (memq w (drgnx-grid-tiles))))
        (should (= 6 (length (drgnx-grid-tiles))))
        (should (drgnx-grid-tool-tile-p (drgnx-pane-window 'g-chat)))))))

(ert-deftest drgnx-grid-tree-live/apply-at-another-scale-keeps-shares ()
  (drgnx-grid-test--with
    (drgnx-grid-tree-live-test--six)
    (let ((tree (drgnx-grid-tree)))
      (unwind-protect
          (progn
            (drgnx-pixels-set-ui-scale (selected-frame) 2)
            (drgnx-pane-hide 'g-term)
            (should (drgnx-grid-apply-tree tree))
            (let ((again (drgnx-grid-tree)))
              (should (= 6 (length (drgnx-grid-tree-leaves again))))
              (cl-loop for a in (drgnx-grid-tree-live-test--shares tree)
                       for b in (drgnx-grid-tree-live-test--shares again)
                       do (should (if a (< (abs (- a b)) 0.005) (null b))))))
        (drgnx-pixels-set-ui-scale (selected-frame) nil)))))

(ert-deftest drgnx-grid-tree-live/apply-never-kills-a-buffer ()
  (drgnx-grid-test--with
    (let* ((tree (drgnx-grid-tree)) (one (selected-window))
           (b (get-buffer-create "*g-only-in-two*")))
      (let ((two (drgnx-groups-split-right)))
        (set-window-buffer two b)
        (drgnx-state-sync)
        (select-window one)
        (should (drgnx-grid-apply-tree tree))
        (should-not (window-live-p two))
        (should (buffer-live-p b))
        (should (memq b (window-parameter one 'drgnx-tabs)))))))

(ert-deftest drgnx-grid-tree-live/junk-tree-is-ignored-with-a-notice ()
  (drgnx-grid-test--with
    (drgnx-grid-tree-live-test--six)
    (let ((edges (drgnx-grid-tree-live-test--edges)) (notices nil))
      (cl-letf (((symbol-function 'drgnx-notify) (lambda (&rest args) (push args notices))))
        (should-not (drgnx-grid-apply-tree '(row :px nil :share nil (tile :id 1))))
        (should-not (drgnx-grid-apply-tree (list 'editor :id 1 :tabs (list (current-buffer))))))
      (should (= 2 (length notices)))
      (should (eq 'warn (nth 1 (car notices))))
      (should (equal (drgnx-grid-tree-live-test--edges) edges)))))

(ert-deftest drgnx-grid-tree-live/full-size-and-back-exact ()
  (drgnx-grid-test--with
    (pcase-let ((`(,_one ,two ,_three) (drgnx-grid-tree-live-test--six)))
      (let ((edges (drgnx-grid-tree-live-test--edges)) (root (window-pixel-edges (drgnx-grid-root))))
        (drgnx-grid-full-size-toggle two)
        (should (drgnx-grid-full-size-p))
        (should (equal (drgnx-grid-tiles) (list two)))
        (should (equal (window-pixel-edges two) root))
        (should (string-match-p "Full size · 1 of 6 · " (format "%s" (window-parameter two 'drgnx-grid-full-note))))
        (drgnx-grid-full-size-toggle two)
        (should-not (drgnx-grid-full-size-p))
        (should-not (window-parameter two 'drgnx-grid-full-note))
        (should (equal (drgnx-grid-tree-live-test--edges) edges))))))

(ert-deftest drgnx-grid-tree-live/full-size-then-move-leaves-full-size-first ()
  ;; a grid command while a tile is full size: every tile comes back first, then the command acts
  (drgnx-grid-test--with
    (pcase-let ((`(,one ,_two ,_three) (drgnx-grid-tree-live-test--six)))
      (let ((ids (mapcar #'car (drgnx-grid-tree-live-test--edges))))
        (select-window one)
        (drgnx-grid-full-size-toggle)
        (let ((new (drgnx-groups-split-right)))
          (should-not (drgnx-grid-full-size-p))
          (should (= 7 (length (drgnx-grid-tiles))))
          (should (cl-subsetp ids (mapcar #'car (drgnx-grid-tree-live-test--edges))))
          (should (drgnx-grid-editor-tile-p new)))
        (drgnx-grid-full-size-toggle one)
        (drgnx-pane-hide 'g-chat)                    ; hiding a tile that full size left out
        (should-not (drgnx-grid-full-size-p))
        (should-not (drgnx-pane-window 'g-chat))
        (should (= 6 (length (drgnx-grid-tiles))))))))

(ert-deftest drgnx-grid-tree-live/zen-is-full-size-with-margins ()
  (require 'drgnx)
  (load (expand-file-name "modules/ui/drgnx-look" drgnx-dir) nil t)
  (drgnx-grid-test--with
    (drgnx-grid-tree-live-test--six)
    (let ((edges (drgnx-grid-tree-live-test--edges)) (editor (selected-window)))
      (unwind-protect
          (progn
            (drgnx-look-zen)
            (should (drgnx-grid-full-size-p))
            (should (equal (drgnx-grid-tiles) (list editor)))
            (should (> (or (car (window-margins editor)) 0) 0))
            (drgnx-look-zen)
            (should-not (drgnx-grid-full-size-p))
            (should (memq (car (window-margins editor)) (quote (nil 0))))
            (should (equal (drgnx-grid-tree-live-test--edges) edges)))
        (set-frame-parameter nil 'drgnx-look-zen nil)))))

;;; grid-tree-live-test.el ends here
