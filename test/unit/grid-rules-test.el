;;; grid-rules-test.el --- batch tests: the tiled grid's rules R1–R8 on its docked tiles and editor tiles -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/grid-fixture" drgnx-dir) nil t)

(ert-deftest drgnx-grid/stack-switch-keeps-the-window ()
  ;; R1: a kind already in a stack comes to the front in the same window; nothing moves
  (drgnx-grid-test--with
    (let* ((term (drgnx-pane-show 'g-term)) (problems (drgnx-pane-show 'g-problems)) (before (drgnx-grid-test--edges)))
      (should (eq term problems))
      (should (eq (drgnx-wb-area-tab 'panel) 'g-problems))
      (should (eq (drgnx-pane-show 'g-term) term))
      (should (eq (drgnx-wb-area-tab 'panel) 'g-term))
      (should (eq (window-buffer term) (get-buffer " *drgnx g-term*")))
      (should (equal before (drgnx-grid-test--edges)))
      (should (eq (drgnx-pane-window 'g-term) term))
      (should-not (drgnx-pane-window 'g-problems)))))

(ert-deftest drgnx-grid/showing-takes-space-only-from-the-neighbour ()
  ;; R2: the bottom dock takes its height from the editor above it only; the side docks keep their edges
  (drgnx-grid-test--with
    (let* ((tree (drgnx-pane-show 'g-tree)) (chat (drgnx-pane-show 'g-chat))
           (editor (car (drgnx-grid-tiles nil 'editor)))
           (before (drgnx-grid-test--edges editor))
           (term (drgnx-pane-show 'g-term)))
      (should (equal (window-pixel-edges tree) (alist-get tree before)))
      (should (equal (window-pixel-edges chat) (alist-get chat before)))
      ;; the panel sits under the editor only, between the side docks
      (should (= (nth 0 (window-pixel-edges term)) (nth 0 (window-pixel-edges editor))))
      (should (= (nth 2 (window-pixel-edges term)) (nth 2 (window-pixel-edges editor))))
      (should (= (nth 1 (window-pixel-edges term)) (nth 3 (window-pixel-edges editor)))))))

(ert-deftest drgnx-grid/hiding-gives-space-back-to-the-neighbour-only ()
  ;; R3: hiding a dock gives its space to the tiles along its edge only
  (drgnx-grid-test--with
    (let* ((tree (drgnx-pane-show 'g-tree)) (term (drgnx-pane-show 'g-term)) (chat (drgnx-pane-show 'g-chat))
           (editor (car (drgnx-grid-tiles nil 'editor)))
           (tree-edges (window-pixel-edges tree)) (term-height (window-pixel-height term)))
      (ignore chat)
      (drgnx-pane-hide 'g-chat)
      ;; the left dock is untouched; the editor and the panel grew to the frame's right edge
      (should (equal (window-pixel-edges tree) tree-edges))
      (should (= term-height (window-pixel-height term)))
      (should (= (nth 2 (window-pixel-edges editor)) (frame-pixel-width)))
      (should (= (nth 2 (window-pixel-edges term)) (frame-pixel-width)))
      ;; hiding the left dock: the right edge of the panel stays
      (drgnx-pane-hide 'g-tree)
      (should (= (nth 0 (window-pixel-edges editor)) 0))
      (should (= term-height (window-pixel-height term))))))

(ert-deftest drgnx-grid/hiding-gives-space-only-to-the-tiles-along-its-edge ()
  ;; R3 inside the neighbour: the left dock beside (two editors over the panel) gives its width to the editor and the
  ;; panel along its edge; the editor on the far side keeps its width
  (drgnx-grid-test--with
    (let* ((term (drgnx-pane-show 'g-term))
           (left-editor (car (drgnx-grid-tiles nil 'editor)))
           (right-editor (split-window left-editor nil 'right))
           (_ (drgnx-grid--adopt-editors))
           (tree (drgnx-pane-show 'g-tree))
           (far (window-pixel-width right-editor)) (tree-width (window-pixel-width tree)))
      (let ((root (window-pixel-edges (frame-root-window))))
        (should (equal (window-pixel-edges tree) (list 0 (nth 1 root) tree-width (nth 3 root)))))
      (let ((near (window-pixel-width left-editor)))
        (drgnx-pane-hide 'g-tree)
        (should (= far (window-pixel-width right-editor)))
        (should (= (+ near tree-width) (window-pixel-width left-editor)))
        (should (= 0 (nth 0 (window-pixel-edges term))))))))

(ert-deftest drgnx-grid/a-tile-keeps-its-size-across-hide-and-show ()
  ;; R4: ±0 px, ten times, for each dock
  (drgnx-grid-test--with
    (drgnx-pane-show 'g-tree) (drgnx-pane-show 'g-term) (drgnx-pane-show 'g-chat)
    (pcase-dolist (`(,kind . ,horizontal) '((g-term . nil) (g-chat . t) (g-tree . t)))
      (let* ((w (drgnx-pane-window kind)))
        (window-resize w 3 horizontal nil t)
        (let ((size (window-size (drgnx-pane-window kind) horizontal t))
              (all (drgnx-grid-test--edges)))
          (dotimes (_ 10)
            (drgnx-pane-hide kind)
            (drgnx-pane-show kind)
            (should (= size (window-size (drgnx-pane-window kind) horizontal t))))
          ;; and every other tile is back where it was
          (should (equal (mapcar #'cdr all) (mapcar #'cdr (drgnx-grid-test--edges)))))))))

(ert-deftest drgnx-grid/showing-never-selects ()
  ;; R5
  (drgnx-grid-test--with
    (let ((editor (selected-window)))
      (dolist (k '(g-term g-chat g-tree g-problems))
        (drgnx-pane-show k)
        (should (eq (selected-window) editor)))
      (let ((w (drgnx-pane-focus 'g-chat)))
        (should (eq (selected-window) w)))
      (select-window editor)
      (drgnx-pane-show 'g-term :select t)
      (should (eq (selected-window) (drgnx-pane-window 'g-term))))))

(ert-deftest drgnx-grid/killing-a-shown-buffer-shows-its-placeholder ()
  ;; R6
  (drgnx-grid-test--with
    (let* ((b (get-buffer-create "*g-shell*"))
           (w (drgnx-pane-show 'g-term :buffer b)))
      (should (eq (window-buffer w) b))
      (kill-buffer b)
      (should (window-live-p w))
      (should (eq (window-buffer w) (get-buffer " *drgnx g-term*")))
      (should (eq (drgnx-wb-area-tab 'panel) 'g-term)))))

(ert-deftest drgnx-grid/foreign-buffers-are-routed-away ()
  ;; R6: another buffer never slips into a tool tile
  (drgnx-grid-test--with
    (let* ((w (drgnx-pane-show 'g-term)) (foreign (get-buffer-create "*g-foreign*")))
      (should (eq (window-dedicated-p w) 'drgnx))
      (with-selected-window w
        (should-not (eq (display-buffer foreign '(display-buffer-same-window)) w))
        (should-not (eq (display-buffer foreign '(display-buffer-reuse-window display-buffer-use-some-window)) w)))
      (should (eq (window-buffer w) (get-buffer " *drgnx g-term*"))))))

(ert-deftest drgnx-grid/delete-window-on-a-tool-tile-hides-it ()
  ;; R7: C-x 0 on a tool tile hides it; it comes back at its size
  (drgnx-grid-test--with
    (let* ((w (drgnx-pane-show 'g-term)) (h (window-pixel-height w)))
      (delete-window w)
      (should-not (window-live-p w))
      (should-not (drgnx-pane-window 'g-term))
      (should (= h (window-pixel-height (drgnx-pane-show 'g-term)))))))

(ert-deftest drgnx-grid/balance-windows-balances-editors-only ()
  ;; R7: a package's `balance-windows' leaves the docks' sizes
  (drgnx-grid-test--with
    (let* ((tree (drgnx-pane-show 'g-tree)) (term (drgnx-pane-show 'g-term)) (chat (drgnx-pane-show 'g-chat))
           (sizes (list (window-pixel-width tree) (window-pixel-height term) (window-pixel-width chat)))
           (editor (car (drgnx-grid-tiles nil 'editor))))
      (split-window editor nil 'right)
      (drgnx-grid-mode 1)
      (unwind-protect (balance-windows) (drgnx-grid-mode -1))
      (should (equal sizes (list (window-pixel-width tree) (window-pixel-height term) (window-pixel-width chat))))
      (let ((editors (drgnx-grid-tiles nil 'editor)))
        (should (= 2 (length editors)))
        (should (<= (abs (- (window-pixel-width (car editors)) (window-pixel-width (cadr editors)))) 1))))))

(ert-deftest drgnx-grid/the-last-editor-tile-stays ()
  ;; R8
  (drgnx-grid-test--with
    (drgnx-pane-show 'g-term) (drgnx-pane-show 'g-chat)
    (let ((editor (car (drgnx-grid-tiles nil 'editor))))
      (should (window-parameter editor 'drgnx-tile-id))
      (should-error (delete-window editor) :type 'user-error)
      (should (window-live-p editor))
      ;; with two, one may go
      (let ((other (split-window editor nil 'right)))
        (drgnx-state-sync)
        (drgnx-grid--adopt-editors)
        (delete-window other)
        (should-not (window-live-p other))
        (should (window-live-p editor))))))

(ert-deftest drgnx-grid/no-tile-is-a-side-window ()
  (drgnx-grid-test--with
    (dolist (k '(g-tree g-term g-chat)) (drgnx-pane-show k))
    (should (= 4 (length (drgnx-grid-tiles))))
    (dolist (w (drgnx-grid-tiles))
      (should-not (window-parameter w 'window-side))
      (should (window-parameter w 'drgnx-tile-id))
      (should (window-parameter w 'no-delete-other-windows)))
    (should (eq (drgnx-grid-root) (frame-root-window)))))

(ert-deftest drgnx-grid/first-arrangement-matches-the-docks ()
  ;; the docks as tiles sit where the side-window docks sat: left dock | (editor over panel) | right dock
  (drgnx-grid-test--with
    (let ((window-sides-vertical t) (drgnx-wb-dock-columns 30) area-edges)
      (drgnx-wb-define-area 'panel :side 'bottom :size 10)
      (drgnx-wb-define-area 'right :side 'right :size 40)
      ;; today's docks: side windows, the same sizes
      (let ((drgnx-pane-backend 'areas))
        (drgnx-wb-show-sidebar)
        (let ((left (car (drgnx-wb--dock-windows)))
              (panel (drgnx-wb-area-show 'panel 'g-term))
              (right (drgnx-wb-area-show 'right 'g-chat)))
          (should (window-parameter left 'window-side))
          (setq area-edges (mapcar #'window-pixel-edges (list left panel right))))
        (drgnx-wb-area-hide 'panel) (drgnx-wb-area-hide 'right) (drgnx-wb-hide-sidebar))
      (drgnx-grid-test--reset)
      (let ((grid-edges (mapcar #'window-pixel-edges (mapcar #'drgnx-pane-show '(g-tree g-term g-chat)))))
        (ert-info ((format "left, bottom, right: areas %S, grid %S" area-edges grid-edges))
          (cl-mapc (lambda (a g) (dotimes (i 4) (should (<= (abs (- (nth i a) (nth i g))) 1))))
                   area-edges grid-edges))))))

(ert-deftest drgnx-grid/delete-other-windows-cannot-collapse ()
  ;; work-space §16 escape-quit-never-collapses-tiles: Esc with nothing to do (VS Code's `keyboard-escape-quit') and
  ;; C-x 1 leave every tile
  (drgnx-grid-test--with
    (dolist (k '(g-tree g-term g-chat)) (drgnx-pane-show k))
    (let ((before (drgnx-grid-test--edges)))
      (keyboard-escape-quit)
      (should (equal before (drgnx-grid-test--edges)))
      (delete-other-windows)
      (should (equal before (drgnx-grid-test--edges))))))

(provide 'grid-rules-test)
;;; grid-rules-test.el ends here
