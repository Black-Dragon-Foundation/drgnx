;;; grid-drag-gui-test.el --- GUI test: dragging tiles by their grip, and the dividers (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; Pointer events in the session (`drgnx-uitest-drag-events', delivered by the command loop): a tile dragged by its
;; grip onto another tile's right edge splits there, onto its middle stacks; a divider still resizes.  On a
;; frame of its own, deleted after.

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-ui-grid-drag--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST")
                                                         (file-name-directory (or load-file-name buffer-file-name))))))
(dolist (d '("core" "wb"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-grid-drag--repo)))
(defvar drgnx-dir)
(setq drgnx-dir (or (bound-and-true-p drgnx-dir) drgnx-ui-grid-drag--repo))
(load (expand-file-name "test/fixtures/grid-fixture" drgnx-ui-grid-drag--repo) nil t)
(require 'drgnx-groups)
(require 'drgnx-grid-ops)

(defun drgnx-ui-grid-drag--settle ()
  "Wait for the window manager's answers to the new frame: its pixel size the same for half a second."
  (let ((last nil) (since nil))
    (drgnx-test-wait (lambda ()
                       (redisplay t)
                       (let ((now (list (frame-pixel-width) (frame-pixel-height))))
                         (if (equal now last) (>= (- (drgnx-test-wait-now) since) 0.5)
                           (setq last now since (drgnx-test-wait-now))
                           nil)))
                     :secs 10 :what "the frame's size")))

(defmacro drgnx-ui-grid-drag--with (&rest body)
  "BODY on a frame of its own with the grid fixture and `drgnx-grid-mode' on (tiles get their tab rows, as in a
session of the user's), the frame deleted and the mode as it was after (the session's windows untouched)."
  (declare (indent 0))
  `(progn
     (unless (display-graphic-p) (ert-skip "needs a graphical frame"))
     (let ((frame (make-frame '((width . 160) (height . 50)))))
       (unwind-protect
           (with-selected-frame frame
             (drgnx-grid-test--with
               (let ((was drgnx-grid-mode))
                 (unless was (drgnx-grid-mode 1))
                 (unwind-protect (progn (drgnx-ui-grid-drag--settle) ,@body)
                   (unless was (drgnx-grid-mode -1))))))
         (delete-frame frame t)))))

(defun drgnx-ui-grid-drag--grip (window)
  "A posn on WINDOW's grip (the ⠿ at the start of its tab row: its tab line, or a docked area's header line): the
first point down and along its top rows whose text says \"Drag to move this tile\"."
  (redisplay t)
  (let* ((e (window-pixel-edges window)) (f (window-frame window)) (cw (frame-char-width f))
         (grip (lambda (p) (and (memq (posn-area p) '(tab-line header-line)) (posn-string p)
                                (equal (get-text-property (cdr (posn-string p)) 'help-echo (car (posn-string p)))
                                       "Drag to move this tile")))))
    (or (seq-some (lambda (y)
                    (seq-some (lambda (x) (let ((p (posn-at-x-y x y f))) (and (funcall grip p) p)))
                              (number-sequence (+ (nth 0 e) (/ cw 2)) (+ (nth 0 e) (* 6 cw)) (max 1 (/ cw 2)))))
                  (number-sequence (+ (nth 1 e) 2) (+ (nth 1 e) (* 3 (frame-char-height f))) 2))
        (ert-fail (list "no grip at the window's top" :edges e
                        :areas (mapcar (lambda (y) (posn-area (posn-at-x-y (+ (nth 0 e) cw) y f)))
                                       (number-sequence (nth 1 e) (+ (nth 1 e) 40) 4))
                        :tab-line (window-parameter window 'tab-line-format)
                        :header-line (window-parameter window 'header-line-format))))))

(defun drgnx-ui-grid-drag--at (window fx fy)
  "A posn at fractions FX, FY of WINDOW's tile's pixel box."
  (let ((e (drgnx-grid--edges window)))
    (posn-at-x-y (round (+ (nth 0 e) (* fx (- (nth 2 e) (nth 0 e))))) (round (+ (nth 1 e) (* fy (- (nth 3 e) (nth 1 e)))))
                 (window-frame window))))

(ert-deftest drgnx-ui-grid-drag/drop-on-an-edge-splits ()
  "The terminal's tile, dragged by its grip to the editor's right edge, becomes a tile right of the editor."
  (drgnx-ui-grid-drag--with
    (let ((editor (selected-window)))
      (drgnx-pane-show 'g-term)
      (let* ((term (drgnx-pane-window 'g-term)) (id (window-parameter term 'drgnx-tile-id))
             (from (drgnx-ui-grid-drag--grip term)))
        (drgnx-uitest-run (drgnx-uitest-drag-events from (drgnx-ui-grid-drag--at editor 0.95 0.5) :lazy t :steps 8))
        (redisplay t)
        (let ((moved (seq-find (lambda (w) (eql (window-parameter w 'drgnx-tile-id) id)) (drgnx-grid-tiles))))
          (should moved)
          (should-not (window-parameter moved 'drgnx-tile-dock))
          (should (= (nth 0 (window-pixel-edges (drgnx-grid--tile-root moved)))
                     (nth 2 (window-pixel-edges editor))))
          (should (= (nth 1 (window-pixel-edges moved)) (nth 1 (window-pixel-edges editor)))))))))

(ert-deftest drgnx-ui-grid-drag/drop-in-the-centre-stacks ()
  "The chat's tile dragged onto the middle of the terminal's: one tile holding both.  Panes stack onto a tile of the
grid's own, so the terminal leaves its dock first (in a session its dock is the panel area)."
  (drgnx-ui-grid-drag--with
    (drgnx-pane-show 'g-term)
    (drgnx-grid-move (drgnx-pane-window 'g-term) (selected-window) 'right)
    (drgnx-pane-show 'g-chat)
    (let* ((term (drgnx-pane-window 'g-term)) (chat (drgnx-pane-window 'g-chat)) (n (length (drgnx-grid-tiles))))
      (drgnx-uitest-run (drgnx-uitest-drag-events (drgnx-ui-grid-drag--grip chat) (drgnx-ui-grid-drag--at term 0.5 0.5)
                                                  :lazy t :steps 8))
      (redisplay t)
      (should (= (length (drgnx-grid-tiles)) (1- n)))
      (let ((stack (mapcar (lambda (e) (or (car-safe e) e)) (window-parameter term 'drgnx-pane-stack))))
        (should (memq 'g-term stack))
        (should (memq 'g-chat stack))))))

(ert-deftest drgnx-ui-grid-drag/drag-a-divider-resizes ()
  "The divider between two editor tiles is Emacs's own: dragged 60 px right, the left tile is 60 px wider."
  (drgnx-ui-grid-drag--with
    (let* ((frame (selected-frame)) (old (frame-parameter frame 'right-divider-width)))
      (unwind-protect
          (progn
            (set-frame-parameter frame 'right-divider-width 6)
            (let* ((left (selected-window)) (right (drgnx-groups-split-right)) (e (window-pixel-edges left))
                   (x (- (nth 2 e) 3)) (y (/ (+ (nth 1 e) (nth 3 e)) 2))
                   (from (posn-at-x-y x y frame)) (before (window-pixel-width left)))
              (ignore right)
              (should (eq (posn-area from) 'right-divider))
              (drgnx-uitest-run (drgnx-uitest-drag-events from (posn-at-x-y (+ x 60) y frame) :lazy t :steps 8))
              (redisplay t)
              (should (> (window-pixel-width left) (+ before 40)))))
        (set-frame-parameter frame 'right-divider-width old)))))

(provide 'grid-drag-gui-test)
;;; grid-drag-gui-test.el ends here
