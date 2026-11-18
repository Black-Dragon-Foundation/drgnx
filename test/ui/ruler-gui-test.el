;;; ruler-gui-test.el --- GUI test: a scroll bar strip changed while a child frame has the focus (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake

;; Glitnir resolves a window's `glitnir-ruler' into the vector C draws (`glitnir--ruler') in `pre-redisplay-functions',
;; which redisplay runs only for the windows it passes.  A strip set on the root frame's window while a child frame has
;; the focus (the palette, a card) is resolved at the next redisplay only when the setter marks the window
;; (`drgnx-ruler--set'); without it the strip stayed as it was until something else redrew the root frame.  Needs
;; Nidhogg's feature `glitnir-ruler'.

(require 'ert)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)
(require 'drgnx-look-gui-fixture (expand-file-name "../fixtures/look-gui-fixture" (file-name-directory (macroexp-file-name))))

(defconst drgnx-ui-ruler--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-ruler--repo)))
(require 'drgnx)
(require 'drgnx-ruler)

(defvar drgnx-minimap-hide-short)
(declare-function drgnx-ruler--show "drgnx-ruler" (window))
(declare-function drgnx-ruler--hide "drgnx-ruler" (window))
(declare-function glitnir--ruler-vector "glitnir" (spec frame))

(drgnx-look-gui-deftest drgnx-ui-ruler/a-strip-changed-under-a-focused-child-frame-is-resolved ()
  "The root frame's window gets a strip, then a child frame takes the focus and the strip's spec changes: the next
redisplay resolves the new spec into `glitnir--ruler'."
  (skip-unless (display-graphic-p))
  (skip-unless (featurep 'glitnir-ruler))
  (let* ((root (drgnx-uitest-root-frame))
         (buffer (generate-new-buffer "ruler-gui"))
         (child nil)
         (w nil))
    (unwind-protect
        (progn
          (select-frame-set-input-focus root)
          (setq w (frame-selected-window root))
          (set-window-buffer w buffer)
          (with-current-buffer buffer (dotimes (i 400) (insert (format "line %d\n" i))) (goto-char (point-min)))
          (let ((drgnx-minimap-hide-short t)) (drgnx-ruler--show w))
          (drgnx-test-wait-presented :frame root)
          (let ((before (window-parameter w 'glitnir--ruler)))
            (should before)
            (setq child (make-frame `((parent-frame . ,root) (minibuffer . nil) (width . 20) (height . 4)
                                      (left . 20) (top . 20) (no-other-frame . t))))
            (select-frame-set-input-focus child)
            (drgnx-test-wait-presented :frame child)
            ;; the root has nothing else to redraw now: only the strip's new spec
            (let ((drgnx-minimap-hide-short nil)) (drgnx-ruler--show w))
            (redisplay t)
            (drgnx-test-wait-presented :frame child)
            (should-not (equal (window-parameter w 'glitnir--ruler) before))
            (should (equal (window-parameter w 'glitnir--ruler)
                           (glitnir--ruler-vector (window-parameter w 'glitnir-ruler) root)))))
      (when (frame-live-p child) (delete-frame child t))
      (when (window-live-p w) (drgnx-ruler--hide w))
      (when (frame-live-p root) (select-frame-set-input-focus root))
      (kill-buffer buffer))))

(provide 'ruler-gui-test)
;;; ruler-gui-test.el ends here
