;;; chrome-scale-gui-test.el --- GUI test: each frame's chrome reads its own frame's scale (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det

;; Two frames, one at the UI scale 100 % and one at 200 %, the first selected throughout: the tab row, the status bar's
;; row and the stretches the chrome puts in its text are in the pixels of the frame they are for, not of the selected
;; one.  (Task 29 of the frontend flow plan; its other rows wait for the Agents side.)

(require 'ert)
(require 'drgnx-look-gui-fixture (expand-file-name "../fixtures/look-gui-fixture" (file-name-directory (macroexp-file-name))))
(require 'cl-lib)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-ui-chrome-scale--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-chrome-scale--repo)))
(require 'drgnx)
(require 'drgnx-chrome)
(dolist (m '("drgnx-look-fonts" "drgnx-look-density" "drgnx-look-scale" "drgnx-statusbar"))
  (load (expand-file-name (concat "modules/ui/" m) drgnx-ui-chrome-scale--repo) nil t))

(declare-function drgnx-look-scale-apply-frame "drgnx-look-scale" (frame &optional percent))
(declare-function drgnx-look-scale--follow "drgnx-look-scale" ())
(declare-function drgnx-look-scale--roots "drgnx-look-scale" ())
(declare-function drgnx-look-density-on "drgnx-look-density" ())
(declare-function drgnx-look-density-off "drgnx-look-density" ())
(declare-function drgnx-chrome--tab-rows "drgnx-chrome" (w))
(declare-function drgnx-statusbar--row-height "drgnx-statusbar" (frame))
(defvar drgnx-look-density)

(drgnx-look-gui-deftest chrome-scale/chrome-reads-its-own-frames-scale ()
  "With the first frame selected, the second at twice its UI scale has twice the chrome: the tab row, the status
bar's row and the stretches (`drgnx-chrome--px') are the second frame's own pixels."
  (skip-unless (display-graphic-p))
  (let* ((a (selected-frame)) (b nil) (drgnx-look-density 'comfortable))
    (unwind-protect
        (progn
          (drgnx-look-density-on)
          (setq b (make-frame '((width . 80) (height . 20) (title . "drgnx-chrome-scale-b"))))
          (select-frame-set-input-focus a)
          (drgnx-look-scale-apply-frame a 100)
          (drgnx-look-scale-apply-frame b 200)
          (drgnx-look-scale--follow)
          (drgnx-test-wait-presented :frame a)
          (drgnx-test-wait-presented :frame b)
          (should (eq a (selected-frame)))
          (let ((sa (drgnx-pixels-scale a)) (sb (drgnx-pixels-scale b)))
            (should (< (abs (- sb (* 2 sa))) 1e-6))
            (dolist (f (list a b))
              (let ((s (drgnx-pixels-scale f)) (win (frame-root-window f)))
                ;; the tab row: its height in this frame's pixels
                (should (= (car (drgnx-chrome--tab-rows win))
                           (round (* s (if (fboundp 'drgnx-look-density-value) (drgnx-look-density-value 'tab-row) 34)))))
                ;; the status bar's row
                (should (= (drgnx-statusbar--row-height f)
                           (drgnx-px (drgnx-look-density-value 'status-bar) f)))
                ;; a stretch of the chrome: 10 logical pixels, in the pixels of the frame it is for
                (should (equal (drgnx-chrome--px 10 f) `(space :width (,(floor (+ (* 10 s) 0.5 1e-9))))))))
            ;; the second frame's chrome is twice the first's, the selected frame being the first
            (should (= (car (drgnx-chrome--tab-rows (frame-root-window b)))
                       (* 2 (car (drgnx-chrome--tab-rows (frame-root-window a))))))))
      (when (frame-live-p b) (delete-frame b t))
      (dolist (f (drgnx-look-scale--roots)) (drgnx-look-scale-apply-frame f 100))
      (drgnx-look-scale--follow)
      (drgnx-look-density-off))))

(provide 'chrome-scale-gui-test)
;;; chrome-scale-gui-test.el ends here
