;;; grid-home-size-test.el --- batch tests: a dock's size as a fraction of the frame, at least a minimum -*- lexical-binding: t -*-
;; test-class: det
;; `drgnx-grid-home-size' is what a terminal's layout gives its docks (ui/terminal-layout): the size the dock's tile
;; has now, if it shows, and comes back at (the `:sizes' intent).  The fixture's frame is 160 × 50, one pixel a column.
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/grid-fixture" drgnx-dir) nil t)

(ert-deftest drgnx-grid/home-size-is-a-fraction-at-least-the-minimum ()
  (drgnx-grid-test--with
    (drgnx-grid-show 'g-tree)
    (let* ((tree (drgnx-grid-dock 'left)) (cw (frame-char-width))
           ;; a batch frame keeps the terminal's width: 80 columns
           (quarter (round (* 0.25 (frame-width)))))
      (should tree)
      (should (> quarter 12))
      ;; a quarter of the columns
      (should (= (drgnx-grid-home-size 'left 0.25 12) (* quarter cw)))
      (should (= (window-total-width tree) quarter))
      (should (equal (drgnx-state-intent nil :sizes 'left) (list :px (* quarter cw) :by 'auto)))
      ;; a twentieth is less than 15: the minimum wins
      (should (< (round (* 0.05 (frame-width))) 15))
      (should (= (drgnx-grid-home-size 'left 0.05 15) (* 15 cw)))
      (should (= (window-total-width tree) 15)))))

(ert-deftest drgnx-grid/home-size-of-a-hidden-dock-is-its-next-size ()
  (drgnx-grid-test--with
    (should-not (drgnx-grid-dock 'bottom))
    (should (= (drgnx-grid-home-size 'bottom 0.30 6) (* 15 (frame-char-height))))
    (should (equal (plist-get (drgnx-state-intent nil :sizes 'bottom) :px) (* 15 (frame-char-height))))
    (drgnx-grid-show 'g-term)
    (should (= (window-total-height (drgnx-grid-dock 'bottom)) 15))))

(provide 'grid-home-size-test)
;;; grid-home-size-test.el ends here
