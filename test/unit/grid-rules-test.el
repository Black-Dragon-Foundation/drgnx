;;; grid-rules-test.el --- batch tests: the tiled grid's rules R1–R8 on tool and editor tiles -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(require 'drgnx-grid)
(require 'drgnx-area)

(defun drgnx-grid-test--buffer (name)
  (lambda () (with-current-buffer (get-buffer-create name t) (special-mode) (current-buffer))))

(defun drgnx-grid-test--reset ()
  "Back to one editor window, no tiles, no grid memory."
  (let ((ignore-window-parameters t)) (delete-other-windows))
  (dolist (p '(drgnx-tile-id drgnx-role drgnx-pane-stack drgnx-tile-dock no-delete-other-windows delete-window
                             tab-line-format window-preserved-size))
    (set-window-parameter nil p nil))
  (set-window-dedicated-p nil nil)
  (dolist (p '(drgnx-grid-memory drgnx-grid-next-id drgnx-intent-by drgnx-wb-panel-px drgnx-wb-right-px
                                 drgnx-wb-dock-px drgnx-wb-areas))
    (set-frame-parameter nil p nil))
  (remhash (selected-frame) drgnx-grid--kinds))

(defmacro drgnx-grid-test--with (&rest body)
  "BODY with the grid backend, a 160 × 50 frame of one editor window and four kinds: `g-term' and `g-problems' at
the bottom, `g-chat' at the right, `g-tree' at the left."
  (declare (indent 0))
  `(drgnx-test-with-state
     (let ((drgnx-pane--kinds nil) (drgnx-pane-backend 'grid) (drgnx-state--kind-owners nil)
           (drgnx-wb--sections nil) (drgnx-wb--areas (copy-tree drgnx-wb--areas))
           (drgnx-rules--table (copy-sequence drgnx-rules--table))
           (display-buffer-alist nil) (display-buffer-overriding-action '(nil))
           (window-min-width 2) (window-min-height 2))
       (set-frame-size nil 160 50)
       (drgnx-grid-test--reset)
       (drgnx-pane-define-kind 'g-term :title "Term" :home 'bottom :size 10
                               :placeholder (drgnx-grid-test--buffer " *drgnx g-term*"))
       (drgnx-pane-define-kind 'g-problems :title "Problems" :home 'bottom
                               :placeholder (drgnx-grid-test--buffer " *drgnx g-problems*"))
       (drgnx-pane-define-kind 'g-chat :title "Chat" :home 'right :size 40
                               :placeholder (drgnx-grid-test--buffer " *drgnx g-chat*"))
       (drgnx-pane-define-kind 'g-tree :title "Tree" :home 'left :size 30
                               :buffer (drgnx-grid-test--buffer " *drgnx g-tree*"))
       (drgnx-state-sync)
       (unwind-protect (progn ,@body)
         (drgnx-grid-test--reset)
         (dolist (b (buffer-list))
           (when (string-match-p "\\` \\*drgnx g-\\|\\`\\*g-" (buffer-name b)) (kill-buffer b)))))))

(defun drgnx-grid-test--edges (&optional except)
  "Alist WINDOW → pixel edges of every live window on the frame but EXCEPT."
  (mapcar (lambda (w) (cons w (window-pixel-edges w))) (remq except (window-list nil 'nomini))))

(ert-deftest drgnx-grid/stack-switch-keeps-the-window ()
  ;; R1: a kind already in a stack comes to the front in the same window; nothing moves
  (drgnx-grid-test--with
    (let* ((term (drgnx-pane-show 'g-term)) (problems (drgnx-pane-show 'g-problems)) (before (drgnx-grid-test--edges)))
      (should (eq term problems))
      (should (equal (window-parameter term 'drgnx-pane-stack) '(g-problems g-term)))
      (should (eq (drgnx-pane-show 'g-term) term))
      (should (eq (car (window-parameter term 'drgnx-pane-stack)) 'g-term))
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
      (should (eq (car (window-parameter w 'drgnx-pane-stack)) 'g-term)))))

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
    (let ((window-sides-vertical t) area-edges)
      ;; today's docks: side windows, the same sizes
      (drgnx-wb-define-section 'g-tree :slot 0 :title "Tree" :buffer (drgnx-grid-test--buffer " *drgnx g-tree*"))
      (let ((drgnx-wb-dock-columns 30)) (drgnx-wb-show-sidebar))
      (drgnx-wb-define-area 'panel :side 'bottom :size 10)
      (drgnx-wb-define-area 'right :side 'right :size 40)
      (drgnx-wb-define-tab 'right 'g-chat :title "Chat")
      (let ((left (car (drgnx-wb--dock-windows))) (panel (drgnx-wb-area-show 'panel 'output))
            (right (drgnx-wb-area-show 'right 'g-chat)))
        (setq area-edges (mapcar #'window-pixel-edges (list left panel right))))
      (drgnx-wb-area-hide 'panel) (drgnx-wb-area-hide 'right) (drgnx-wb-hide-sidebar)
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
