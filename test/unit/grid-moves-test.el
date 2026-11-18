;;; grid-moves-test.el --- batch tests: moving tiles by keys (focus, move, swap, stack, unstack, resize) -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/grid-fixture" drgnx-dir) nil t)
(require 'drgnx-groups)
(require 'drgnx-grid-ops)

(defun drgnx-grid-moves-test--pick (window name)
  "Split a new tile below tool tile WINDOW showing the kind titled NAME (the picker answered)."
  (select-window window)
  (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) name))) (drgnx-groups-split-down)))

(defun drgnx-grid-moves-test--by-id (id)
  (seq-find (lambda (w) (eql (window-parameter w 'drgnx-tile-id) id)) (drgnx-grid-tiles)))

(defun drgnx-grid-moves-test--places ()
  "Every tile's edges, sorted: the places, whatever shows in them."
  (sort (mapcar (lambda (w) (window-pixel-edges (drgnx-grid--tile-root w))) (drgnx-grid-tiles))
        (lambda (a b) (or (< (car a) (car b)) (and (= (car a) (car b)) (< (cadr a) (cadr b)))))))

(defun drgnx-grid-moves-test--all ()
  "Every window and its edges, in one order."
  (sort (drgnx-grid-test--edges) (lambda (a b) (let ((ea (window-pixel-edges (car a))) (eb (window-pixel-edges (car b))))
                                                 (or (< (car ea) (car eb))
                                                     (and (= (car ea) (car eb)) (< (cadr ea) (cadr eb))))))))

(ert-deftest drgnx-grid-moves/focus-by-direction-across-a-dock ()
  (drgnx-grid-test--with
    (let ((editor (selected-window)))
      (dolist (k '(g-tree g-term g-chat)) (drgnx-pane-show k))
      (let ((tree (drgnx-grid-tile-main (drgnx-pane-window 'g-tree)))
            (term (drgnx-pane-window 'g-term)) (chat (drgnx-pane-window 'g-chat)))
        (select-window editor)
        (drgnx-grid-focus-direction 'right)
        (should (eq (drgnx-grid-tile-main (selected-window)) chat))       ; past the panel, which is below
        (drgnx-grid-focus-direction 'left)
        (should (eq (selected-window) editor))
        (drgnx-grid-focus-direction 'down)
        (should (eq (selected-window) term))
        (drgnx-grid-focus-direction 'left)
        (should (eq (drgnx-grid-tile-main (selected-window)) tree))       ; the left dock runs the full height
        (drgnx-grid-focus-direction 'left)                                ; the edge: nothing changes
        (should (eq (drgnx-grid-tile-main (selected-window)) tree))))))

(ert-deftest drgnx-grid-moves/move-left-puts-it-left-of-its-neighbour ()
  (drgnx-grid-test--with
    (let* ((one (selected-window)) (two (drgnx-groups-split-right)) (id (window-parameter two 'drgnx-tile-id))
           (b (get-buffer-create "*g-two*")))
      (set-window-buffer two b)
      (drgnx-grid-move-tile-left)
      (let ((moved (drgnx-grid-moves-test--by-id id)))
        (should (window-live-p one))
        (should (eq (window-buffer moved) b))
        (should (eq (selected-window) moved))
        (should (= (nth 2 (window-pixel-edges moved)) (nth 0 (window-pixel-edges one))))
        (should (= (window-pixel-top moved) (window-pixel-top one)))
        (should (eq (plist-get (car drgnx-grid--stack) :why) 'move))))))

(ert-deftest drgnx-grid-moves/stack-merges-the-tab-rows ()
  (drgnx-grid-test--with
    (let* ((chat (drgnx-pane-show 'g-chat)))
      (drgnx-grid-moves-test--pick chat "Term")
      (let ((term (drgnx-pane-window 'g-term)))
        (drgnx-grid-moves-test--pick term "Problems")
        (let ((problems (drgnx-pane-window 'g-problems)) (n (length (drgnx-grid-tiles))))
          (should (eq (window-parameter problems 'drgnx-role) 'tile))
          (drgnx-grid-stack problems term)
          (should-not (window-live-p problems))
          (should (= (length (drgnx-grid-tiles)) (1- n)))
          (should (equal (window-parameter term 'drgnx-pane-stack) '(g-problems g-term)))
          (let ((row (substring-no-properties (window-parameter term 'drgnx-grid-tab-row))))
            (should (string-match-p "Term" row))
            (should (string-match-p "Problems" row))))))))

(ert-deftest drgnx-grid-moves/unstack-makes-a-tile-beside ()
  (drgnx-grid-test--with
    (let ((chat (drgnx-pane-show 'g-chat)))
      (drgnx-grid-moves-test--pick chat "Term")
      (let ((term (drgnx-pane-window 'g-term)))
        (drgnx-grid-moves-test--pick term "Problems")
        (drgnx-grid-stack (drgnx-pane-window 'g-problems) term)
        (let ((new (drgnx-grid-unstack term)))
          (should (window-live-p new))
          (should (equal (window-parameter new 'drgnx-pane-stack) '(g-problems)))
          (should (equal (window-parameter term 'drgnx-pane-stack) '(g-term)))
          (should (eq (window-buffer term) (get-buffer " *drgnx g-term*")))
          ;; beside, on the side with more room: right when the tile was at least as wide as tall, else below
          (should (or (and (= (window-pixel-left new) (nth 2 (window-pixel-edges term)))
                           (= (window-pixel-top new) (window-pixel-top term)))
                      (and (= (window-pixel-top new) (nth 3 (window-pixel-edges term)))
                           (= (window-pixel-left new) (window-pixel-left term)))))
          (should-error (drgnx-grid-unstack term) :type 'user-error))))))

(ert-deftest drgnx-grid-moves/swap-exchanges-places-and-sizes ()
  (drgnx-grid-test--with
    (let* ((one (selected-window)) (two (drgnx-groups-split-right))
           (a (get-buffer-create "*g-a*")) (b (get-buffer-create "*g-b*")))
      (set-window-buffer one a) (set-window-buffer two b)
      (let ((window-resize-pixelwise t)) (window-resize one 7 t nil t))
      (let ((places (drgnx-grid-moves-test--places))
            (left (window-pixel-edges one)) (right (window-pixel-edges two)))
        (select-window one)
        (drgnx-grid-swap one two)
        (should (equal (drgnx-grid-moves-test--places) places))
        (let ((at-left (window-at (car left) (cadr left))) (at-right (window-at (car right) (cadr right))))
          (should (eq (window-buffer (seq-find (lambda (w) (equal (window-pixel-edges w) left)) (drgnx-grid-tiles))) b))
          (should (eq (window-buffer (seq-find (lambda (w) (equal (window-pixel-edges w) right)) (drgnx-grid-tiles))) a))
          (ignore at-left at-right))
        (should (eq (window-buffer (selected-window)) a))))))

(ert-deftest drgnx-grid-moves/a-swapped-dock-stays-a-tile ()
  ;; a docked area's window swapped into an editor's place is no dock's any more but still a tile, holding the kind
  ;; (it was no tile at all).  The dock's preserved height staying with its place is I11's (drgnx-inv/i11-…): a batch
  ;; frame does not trade the sizes even without the fix.
  (drgnx-grid-test--with
    (let ((two (drgnx-groups-split-right)))
      (drgnx-pane-show 'g-term)
      (let* ((term (drgnx-pane-window 'g-term)) (id (window-parameter term 'drgnx-tile-id))
             (places (drgnx-grid-moves-test--places)))
        (should (window-parameter term 'drgnx-tile-dock))
        (drgnx-grid-swap two term)
        (should (equal (drgnx-grid-moves-test--places) places))
        (let ((moved (drgnx-grid-moves-test--by-id id)))
          (should (drgnx-grid-tool-tile-p moved))
          (should-not (window-parameter moved 'drgnx-tile-dock))
          (should (memq 'g-term (mapcar (lambda (e) (or (car-safe e) e)) (window-parameter moved 'drgnx-pane-stack)))))))))

(ert-deftest drgnx-grid-moves/an-editor-tile-moves-with-its-tabs ()
  (drgnx-grid-test--with
    (let* ((one (selected-window)) (two (drgnx-groups-split-right))
           (a (get-buffer-create "*g-a*")) (b (get-buffer-create "*g-b*")) (id (window-parameter two 'drgnx-tile-id)))
      (set-window-buffer two b)
      (set-window-parameter two 'drgnx-tabs (list a b))
      (drgnx-grid-move two one 'below)
      (let ((moved (drgnx-grid-moves-test--by-id id)))
        (should (drgnx-grid-editor-tile-p moved))
        (should (eq (window-buffer moved) b))
        (should (equal (window-parameter moved 'drgnx-tabs) (list a b)))
        (should (= (window-pixel-top moved) (nth 3 (window-pixel-edges one))))))))

(ert-deftest drgnx-grid-moves/an-atom-moves-whole ()
  (drgnx-grid-test--with
    (let ((composer (get-buffer-create "*g-composer*")))
      (drgnx-pane-define-kind 'g-agent :title "Agent" :home 'right
                              :buffer (drgnx-grid-test--buffer "*g-agent*")
                              :companions (lambda (_b) (list nil composer)))
      ;; a tile of the grid's own showing the kind, its composer a part of it
      (drgnx-grid-moves-test--pick (drgnx-pane-show 'g-chat) "Agent")
      (drgnx-pane-hide 'g-chat)
      (let* ((editor (car (drgnx-grid-tiles nil 'editor))) (agent (drgnx-pane-window 'g-agent))
             (root (drgnx-grid--tile-root agent)) (id (window-parameter agent 'drgnx-tile-id)))
        (should-not (window-live-p root))                 ; an atom: the agent and its composer
        (select-window agent)
        (drgnx-grid-move-tile-left)
        (let* ((moved (drgnx-grid-moves-test--by-id id)) (root (drgnx-grid--tile-root moved))
               (parts nil))
          (should (eq (window-buffer moved) (get-buffer "*g-agent*")))
          (should-not (window-live-p root))
          (walk-window-subtree (lambda (w) (push w parts)) root)
          (should (= 2 (length parts)))
          (should (memq composer (mapcar #'window-buffer parts)))
          (should (window-parameter (window-parent moved) 'window-atom))
          ;; left of the editor
          (should (= (nth 2 (window-pixel-edges root)) (nth 0 (window-pixel-edges editor))))
          (should-not (window-parameter moved 'drgnx-tile-dock)))))))

(defun drgnx-grid-moves-test--key-hints (s)
  "The keys of the kit key hints in string S, in order (their `help-echo' is \"key KEYS\")."
  (let ((i 0) out)
    (while (< i (length s))
      (let ((h (get-text-property i 'help-echo s)) (next (next-single-property-change i 'help-echo s (length s))))
        (when (and (stringp h) (string-prefix-p "key " h)) (push (substring h 4) out))
        (setq i next)))
    (nreverse out)))

(ert-deftest drgnx-grid-moves/resize-hint-is-the-kit ()
  "Resize Tiles' hint names the arrows as kit key hints."
  (should (string-prefix-p "Resize Tiles: " (drgnx-grid-resize-hint)))
  (should (equal (drgnx-grid-moves-test--key-hints (drgnx-grid-resize-hint)) '("←" "→" "↑" "↓"))))

(ert-deftest drgnx-grid-moves/placeholder-row-is-the-kit ()
  "A tile placeholder's line is a kit row in the selected state (`drgnx-row-selected', which follows the tile's
focus), its keys kit key hints; its words stay."
  (let ((b (drgnx-grid-tile-placeholder 'g-not-defined)))
    (unwind-protect
        (with-current-buffer b
          (should (string-match-p "\\`g-not-defined · waits for its module · .* choose · .* close\\'" (buffer-string)))
          (should (equal (drgnx-grid-moves-test--key-hints (buffer-string)) '("↵" "x")))
          (should (equal (get-text-property (point-min) 'face) (drgnx-ui-kit-row-face 'selected)))
          ;; written again unchanged: still the kit's
          (drgnx-grid-tile-placeholder 'g-not-defined)
          (should (equal (drgnx-grid-moves-test--key-hints (buffer-string)) '("↵" "x"))))
      (kill-buffer b))))

(ert-deftest drgnx-grid-moves/resize-mode-steps-and-replays-the-other-key ()
  (drgnx-grid-test--with
    (let* ((one (selected-window)) (two (drgnx-groups-split-right)) (b (get-buffer-create "*g-typed*")))
      (with-current-buffer b (erase-buffer))
      (set-window-buffer one b)
      (select-window one)
      (let ((w (window-pixel-width one)) (step (drgnx-grid--step (selected-frame) t))
            ;; the arrows the profiles bind (keys/*.eld, tile-resize-left/right/up/down)
            (drgnx-grid-resize-map (define-keymap "<left>" #'drgnx-grid-resize-left "<right>" #'drgnx-grid-resize-right
                                     "<up>" #'drgnx-grid-resize-up "<down>" #'drgnx-grid-resize-down))
            ;; the command run from a key, as Resize Tiles is: <f13> here
            (emulation-mode-map-alists (cons (list (cons t (define-keymap "<f13>" #'drgnx-grid-resize-mode)))
                                             emulation-mode-map-alists)))
        (execute-kbd-macro (kbd "<f13> <right> <right> a"))
        (should (= (window-pixel-width one) (+ w (* 2 step))))
        (should (= (window-pixel-width two) (- (window-pixel-width (drgnx-grid-root)) (window-pixel-width one))))
        (should (equal (with-current-buffer b (buffer-string)) "a"))
        ;; the mode ended with the other key: an arrow is the arrow again (moves point, not the edge)
        (goto-char (point-min))
        (execute-kbd-macro (kbd "<right>"))
        (should (= (point) 2))
        (should (= (window-pixel-width one) (+ w (* 2 step))))))))

(ert-deftest drgnx-grid-moves/no-room-in-a-tiny-frame-changes-nothing ()
  ;; Review Focus 4: six tiles in a frame too small to split any of them; every move, split and unstack changes
  ;; nothing and says so
  (drgnx-grid-test--with
    (let ((one (selected-window)))
      (dolist (k '(g-tree g-term g-chat)) (drgnx-pane-show k))
      (select-window one)
      (drgnx-groups-split-right) (select-window one) (drgnx-groups-split-down)
      (should (= 6 (length (drgnx-grid-tiles))))
      (set-frame-size nil 60 16)
      (let ((drgnx-grid-min-columns 40) (drgnx-grid-min-lines 11) (before (drgnx-grid-moves-test--all)) said)
        (dolist (w (drgnx-grid-tiles))
          (select-window w)
          (dolist (f '(drgnx-grid-move-tile-left drgnx-grid-move-tile-right drgnx-grid-move-tile-up
                                                 drgnx-grid-move-tile-down drgnx-grid-unstack-tile
                                                 drgnx-groups-split-right drgnx-groups-split-down))
            (condition-case err (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "Problems")))
                                  (funcall f))
              (user-error (push (cadr err) said)))
            (ert-info ((format "%s on %s" f w)) (should (equal (drgnx-grid-moves-test--all) before)))))
        (should (member "No room there" said))
        (should (seq-every-p (lambda (m) (member m '("No room there" "No tile there" "One tab: nothing to unstack"))) said))))))

(ert-deftest drgnx-grid-moves/evil-window-moves-become-tile-moves ()
  ;; C-w H/L/K/J (evil's moves to the far side) move the tile; C-w x swaps it
  (require 'drgnx)
  (load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
  (drgnx-test-with-modules '(core/workbench)
    (pcase-dolist (`(,evil . ,ours) '((evil-window-move-far-left . drgnx-grid-move-tile-left)
                                      (evil-window-move-far-right . drgnx-grid-move-tile-right)
                                      (evil-window-move-very-top . drgnx-grid-move-tile-up)
                                      (evil-window-move-very-bottom . drgnx-grid-move-tile-down)
                                      (evil-window-exchange . drgnx-grid-exchange)))
      (should (eq (command-remapping evil nil global-map) ours)))))

(provide 'grid-moves-test)
;;; grid-moves-test.el ends here
