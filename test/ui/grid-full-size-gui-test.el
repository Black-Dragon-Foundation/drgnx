;;; grid-full-size-gui-test.el --- GUI tests: a tile at full size and back, exact to the pixel (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; Six tiles on a graphical frame, the grid backend on: one tile at full size fills the grid, and back every tile has
;; its edges again, ±0 px.  At scale 1 (ui1) and 2 (ui2), where a size rounded to lines or columns would show.

(require 'ert)
(require 'cl-lib)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))

(defconst drgnx-ui-grid-full--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST")
                                                         (file-name-directory (or load-file-name buffer-file-name))))))
(dolist (d '("core" "wb"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-grid-full--repo)))
(defvar drgnx-dir)
(setq drgnx-dir (or (bound-and-true-p drgnx-dir) drgnx-ui-grid-full--repo))
(load (expand-file-name "test/fixtures/grid-fixture" drgnx-ui-grid-full--repo) nil t)
(require 'drgnx-groups)

(defun drgnx-ui-grid-full--scale ()
  (if (fboundp 'frame-scale-factor) (frame-scale-factor) 1.0))

(defun drgnx-ui-grid-full--settled ()
  "The frame's tiles' edges once the window manager's answers to the new frame are in (the same for half a second)."
  (let ((last nil) (since nil))
    (drgnx-test-wait (lambda ()
                       (redisplay t)
                       (let ((now (list (frame-pixel-width) (frame-pixel-height)
                                        (mapcar #'window-pixel-edges (drgnx-grid-tiles)))))
                         (if (equal now last) (>= (- (drgnx-test-wait-now) since) 0.5)
                           (setq last now since (drgnx-test-wait-now))
                           nil)))
                     :secs 10 :what "the frame's size")
    (nth 2 last)))

(defun drgnx-ui-grid-full--check ()
  "Six tiles, the middle editor at full size, then back: every tile's pixel edges as they were."
  (unless (display-graphic-p) (ert-skip "needs a graphical frame"))
  (let ((frame (make-frame '((width . 160) (height . 50)))))
    (unwind-protect
        (with-selected-frame frame
          (drgnx-grid-test--with
            (let* ((one (selected-window)) (two (drgnx-groups-split-right)))
              (select-window one)
              (drgnx-groups-split-down)
              (drgnx-pane-show 'g-tree) (drgnx-pane-show 'g-chat) (drgnx-pane-show 'g-term)
              ;; sizes no whole number of lines or columns gives
              (let ((window-resize-pixelwise t))
                (window-resize (drgnx-pane-window 'g-chat) 3 t nil t)
                (window-resize (drgnx-pane-window 'g-term) 5 nil nil t))
              (let* ((before (drgnx-ui-grid-full--settled)) (tiles (drgnx-grid-tiles))
                     (root (window-pixel-edges (drgnx-grid-root))))
                (drgnx-grid-full-size-toggle two)
                (redisplay t)
                (should (equal (drgnx-grid-tiles) (list two)))
                (should (equal (window-pixel-edges two) root))
                (drgnx-grid-full-size-toggle two)
                (redisplay t)
                (should (= (length (drgnx-grid-tiles)) 6))
                (should (equal (mapcar #'window-pixel-edges (drgnx-grid-tiles)) before))
                (should (memq two (drgnx-grid-tiles)))
                (should (= (length tiles) 6))))))
      (delete-frame frame))))

(ert-deftest drgnx-ui-grid-full-size/and-back-at-s1 ()
  (skip-unless (< (abs (- (drgnx-ui-grid-full--scale) 1)) 0.01))
  (drgnx-ui-grid-full--check))

(ert-deftest drgnx-ui-grid-full-size/at-s2 ()
  (skip-unless (< (abs (- (drgnx-ui-grid-full--scale) 2)) 0.01))
  (drgnx-ui-grid-full--check))

;;; grid-full-size-gui-test.el ends here
