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

;;;; Placement on tiles (work-space §9.3), the popup lane, Close Pane

(require 'drgnx-popup)
(require 'drgnx-groups)

(define-derived-mode drgnx-grid-rules-test-map-mode special-mode "Map" "A stand-in for the Work map.")

(defun drgnx-grid-rules-test--file (name)
  "A buffer visiting a file NAME (not on disk)."
  (with-current-buffer (get-buffer-create name)
    (setq buffer-file-name (expand-file-name name temporary-file-directory))
    (current-buffer)))

(defmacro drgnx-grid-rules-test--routed (&rest body)
  "BODY with the rules on: `display-buffer' and `display-buffer-in-side-window' go through them."
  (declare (indent 0))
  `(progn (drgnx-rules-mode 1) (unwind-protect (progn ,@body) (drgnx-rules-mode -1))))

(defmacro drgnx-grid-rules-test--with-map (map &rest body)
  "BODY with the selected editor tile showing the map buffer MAP (a variable bound to it)."
  (declare (indent 1))
  `(let ((,map (with-current-buffer (get-buffer-create "*g-map*") (drgnx-grid-rules-test-map-mode) (current-buffer)))
         (drgnx-rules-never-cover-modes '(drgnx-grid-rules-test-map-mode)))
     (set-window-buffer (selected-window) ,map)
     ,@body))

(defun drgnx-grid-rules-test--agents ()
  "A kind like the agent panel: one buffer per session, the session its key (`:instance', `:instance-key')."
  (drgnx-pane-define-kind 'g-agent :title "Agent" :home 'right
                          :buffer (lambda () (drgnx-grid-rules-test--agent "a"))
                          :companions (lambda (b) (list nil (get-buffer-create (format "%s composer" (buffer-name b)))))
                          :instance #'drgnx-grid-rules-test--agent
                          :instance-key (lambda (b) (buffer-local-value 'drgnx-grid-rules-test--session b))))

(defvar-local drgnx-grid-rules-test--session nil)

(defun drgnx-grid-rules-test--agent (session)
  (with-current-buffer (get-buffer-create (format "*g-agent %s*" session))
    (special-mode)
    (setq drgnx-grid-rules-test--session session)
    (current-buffer)))

(defun drgnx-grid-rules-test--agent-tiles ()
  "The docked agent window and the tiles holding agent instances."
  (seq-filter (lambda (w) (or (eq w (drgnx-pane-window 'g-agent))
                              (seq-some (lambda (e) (eq (car-safe e) 'g-agent)) (window-parameter w 'drgnx-pane-stack))))
              (drgnx-grid-tiles)))

(ert-deftest drgnx-grid-rules/a-file-goes-to-the-mru-editor-tile ()
  (drgnx-grid-test--with
    (drgnx-grid-rules-test--routed
      (let* ((one (selected-window)) (two (drgnx-groups-split-right)) (chat (drgnx-pane-show 'g-chat))
             (file (drgnx-grid-rules-test--file "g-file.txt")))
        (select-window chat)
        (drgnx-state-use-editor two)
        (should (eq (drgnx-wb-editor-window) two))
        (should (eq (display-buffer file) two))
        (should (eq (window-buffer two) file))
        (should (eq (window-buffer one) (get-buffer "*scratch*")))
        (should (eq (window-buffer chat) (get-buffer " *drgnx g-chat*")))))))

(ert-deftest drgnx-grid-rules/a-file-never-covers-the-map ()
  (drgnx-grid-test--with
    (drgnx-grid-rules-test--routed
      (drgnx-grid-rules-test--with-map map
        (let* ((editor (selected-window)) (file (drgnx-grid-rules-test--file "g-file.txt"))
               (w (display-buffer file)))
          (should (eq (window-buffer editor) map))
          (should-not (eq w editor))
          (should (drgnx-grid-editor-tile-p w))
          (should (= (window-pixel-left w) (nth 2 (window-pixel-edges editor))))   ; split from the map's right
          ;; with another editor tile, that one takes the next file
          (let ((other (drgnx-grid-rules-test--file "g-other.txt")))
            (should (eq (display-buffer other) w))
            (should (eq (window-buffer editor) map))))))))

(ert-deftest drgnx-grid-rules/third-agent-stacks ()
  (drgnx-grid-test--with
    (drgnx-grid-rules-test--agents)
    (let* ((a (drgnx-pane-show 'g-agent :buffer (drgnx-grid-rules-test--agent "a")))
           (b (drgnx-pane-show 'g-agent :buffer (drgnx-grid-rules-test--agent "b"))))
      ;; one session: its panel docks right, as before; a second gets a tile of its own
      (should (eq (window-parameter a 'drgnx-tile-dock) 'right))
      (should-not (eq a b))
      (should (equal (window-parameter b 'drgnx-pane-stack) '((g-agent . "b"))))
      (should (eq (window-buffer b) (get-buffer "*g-agent b*")))
      ;; its companion below it, a part of its tile
      (let ((part (drgnx-grid--part-of b 'below)))
        (should (window-live-p part))
        (should (eq (window-buffer part) (get-buffer "*g-agent b* composer")))
        (should-not (memq part (drgnx-grid-tiles))))
      ;; a third stacks onto an agent tile: no third tile
      (let ((c (drgnx-pane-show 'g-agent :buffer (drgnx-grid-rules-test--agent "c"))))
        (should (memq c (list a b)))
        (should (= 2 (length (drgnx-grid-rules-test--agent-tiles))))
        (should (eq (window-buffer c) (get-buffer "*g-agent c*")))
        (should (member '(g-agent . "c") (window-parameter c 'drgnx-pane-stack))))
      ;; an agent that has a tile comes back to it
      (should (eq (drgnx-pane-show 'g-agent :buffer (get-buffer "*g-agent b*")) b))
      (should (eq (window-buffer b) (get-buffer "*g-agent b*")))
      (should (eq (window-buffer a) (get-buffer "*g-agent a*")))
      ;; its tab row names each instance
      (should (string-match-p "g-agent b.*g-agent c\\|g-agent c.*g-agent b"
                              (substring-no-properties (window-parameter b 'drgnx-grid-tab-row)))))))

(ert-deftest drgnx-grid-rules/trail-stacks-on-detail-when-narrow ()
  (drgnx-grid-test--with
    (drgnx-pane-define-kind 'g-detail :title "Detail" :home 'right
                            :placeholder (drgnx-grid-test--buffer " *drgnx g-detail*"))
    (drgnx-pane-define-kind 'g-trail :title "Trail" :home 'bottom
                            :placeholder (drgnx-grid-test--buffer " *drgnx g-trail*"))
    (drgnx-grid-rules-test--with-map map
      (let ((drgnx-grid-placements '((g-trail :below-map t :narrow g-detail)))
            (editor (selected-window)) (detail (drgnx-pane-show 'g-detail)))
        ;; narrow (a 160-column batch frame is 160 logical px): with the detail; the detail docks in the right area
        ;; here, so the trail is split under it (stacked when the detail is a tile of the grid's own)
        (let ((drgnx-grid-narrow-px 1200))
          (let ((trail (drgnx-pane-show 'g-trail)))
            (should-not (eq trail detail))
            (should (= (window-pixel-left trail) (window-pixel-left detail)))
            (should (= (window-pixel-top trail) (nth 3 (window-pixel-edges detail))))
            (should (eq (window-buffer editor) map))))
        (drgnx-pane-hide 'g-trail)
        ;; wide: a tile below the map
        (let ((drgnx-grid-narrow-px 10))
          (let ((trail (drgnx-pane-show 'g-trail)))
            (should-not (eq trail detail))
            (should (= (window-pixel-top trail) (nth 3 (window-pixel-edges editor))))
            (should (= (window-pixel-left trail) (window-pixel-left editor)))
            (should (eq (window-buffer editor) map))))))))

(ert-deftest drgnx-grid-rules/a-foreign-side-window-request-is-routed ()
  ;; a package's own `display-buffer-in-side-window' (no rule for its buffer): a tile of its own, never a side window
  (drgnx-grid-test--with
    (drgnx-grid-rules-test--routed
      (drgnx-pane-show 'g-term)
      (let* ((b (get-buffer-create "*g-side*"))
             (w (display-buffer-in-side-window b '((side . right) (slot . 0)))))
        (should (window-live-p w))
        (should-not (window-parameter w 'window-side))
        (should (memq w (drgnx-grid-tiles)))
        (should (window-parameter w 'drgnx-tile-temporary))
        (should (= (nth 2 (window-pixel-edges w)) (nth 2 (window-pixel-edges (drgnx-grid-root)))))
        (should (eq (drgnx-grid-root) (frame-root-window)))
        (delete-window w)
        (should-not (window-live-p w))))))

(ert-deftest drgnx-grid-rules/popup-borrows-the-panel-and-leaves-no-trace ()
  (drgnx-grid-test--with
    (let* ((term (drgnx-pane-show 'g-term)) (popup (get-buffer-create "*g-popup*"))
           (edges (drgnx-grid-test--edges)) (windows (window-list nil 'nomini)))
      ;; the panel shows, not selected: the popup borrows it
      (let ((lane (drgnx-popup--show popup nil nil)))
        (should (eq lane term))
        (drgnx-popup--end lane))
      (should (eq (window-buffer term) (get-buffer " *drgnx g-term*")))
      (should (equal (drgnx-grid-test--edges) edges))
      ;; no panel: a row of its own under the grid, gone after
      (drgnx-pane-hide 'g-term)
      (setq edges (drgnx-grid-test--edges) windows (window-list nil 'nomini))
      (let ((lane (drgnx-popup--show popup nil nil)))
        (should-not (memq lane windows))
        (should-not (window-parameter lane 'window-side))
        (should (eq (window-parameter lane 'drgnx-role) 'popup))
        (should (= (nth 3 (window-pixel-edges lane)) (nth 3 (window-pixel-edges (drgnx-grid-root)))))
        (should-not (memq lane (drgnx-grid-tiles)))
        (delete-window lane))
      (should (equal (window-list nil 'nomini) windows))
      (should (equal (drgnx-grid-test--edges) edges)))))

(ert-deftest drgnx-grid-rules/temporary-tiles-are-not-saved ()
  (drgnx-grid-test--with
    (drgnx-grid-rules-test--routed
      (drgnx-pane-show 'g-chat)
      (let ((tree (drgnx-grid-tree)))
        (display-buffer-in-side-window (get-buffer-create "*g-side*") '((side . bottom)))
        (should (= 3 (length (drgnx-grid-tiles))))
        (should (equal (drgnx-grid-tree) tree))))))

(ert-deftest drgnx-grid-rules/foreign-window-calls-leave-the-grid-recoverable ()
  ;; Review Focus 3: a package puts back a one-window configuration and deletes the other windows past their
  ;; parameters; the grid as it was is on the stack (`layout-restore-previous', Task 10, brings it back)
  (drgnx-grid-test--with
    (drgnx-grid-mode 1)
    (unwind-protect
        (let ((one (current-window-configuration)))
          (dolist (k '(g-tree g-term g-chat)) (drgnx-pane-show k))
          (drgnx-state-sync)
          (let ((tree (drgnx-grid-tree)))
            (set-frame-parameter nil 'drgnx-grid-stack nil)
            (set-window-configuration one)
            (let ((ignore-window-parameters t)) (delete-other-windows))
            (drgnx-state-sync)
            (should (equal (car (frame-parameter nil 'drgnx-grid-stack)) (list :why 'foreign :tree tree)))
            ;; the grid's own hides are not foreign
            (set-frame-parameter nil 'drgnx-grid-stack nil)
            (dolist (k '(g-tree g-term g-chat)) (drgnx-pane-show k))
            (drgnx-state-sync)
            (dolist (k '(g-tree g-term g-chat)) (drgnx-pane-hide k))
            (drgnx-state-sync)
            (should-not (frame-parameter nil 'drgnx-grid-stack))))
      (drgnx-grid-mode -1))))

(ert-deftest drgnx-grid-rules/close-pane-hides-a-tool-tile ()
  (load (expand-file-name "modules/ui/drgnx-close" drgnx-dir) nil t)
  (drgnx-grid-test--with
    ;; Term picked into a tile of its own (role `tile', not an area)
    (let ((chat (drgnx-pane-show 'g-chat)) (last-command-event nil))
      (select-window chat)
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "Term"))) (drgnx-groups-split-down))
      (let ((term (drgnx-pane-window 'g-term)))
        (should (eq (window-parameter term 'drgnx-role) 'tile))
        (select-window term)
        (drgnx-close--update)
        (should drgnx-close--here)
        (drgnx-close-pane)
        (should-not (window-live-p term))
        (should-not (drgnx-pane-window 'g-term))
        (should (window-live-p chat))))))

(provide 'grid-rules-test)
;;; grid-rules-test.el ends here
