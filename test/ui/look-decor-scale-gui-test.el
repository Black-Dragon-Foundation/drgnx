;;; look-decor-scale-gui-test.el --- GUI tests: the decoration boxes at the frame's scale (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: the boxes are read from the frame's faces after each change.  The run's scale is DRGNX_UI_SCALE (1,
;; 1.25, 4/3, 2); the UI scale (the root frame's `drgnx-ui-scale') takes the frame to 2 within the row.

(require 'ert)
(require 'cl-lib)
(require 'drgnx-uitest)

(defconst drgnx-look-decor-scale-ui-test--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-look-decor-scale-ui-test--repo)))
(require 'drgnx)
(load (expand-file-name "modules/ui/drgnx-decor" drgnx-look-decor-scale-ui-test--repo) nil t)

(defconst drgnx-look-decor-scale-ui-test--want
  '((1.0 1 2 8) (1.25 1 3 10) (1.3333333333333333 1 3 11) (2.0 2 4 16))
  "Per scale: a card's edge, the focus ring's width, a card's radius, in device pixels.")

(defun drgnx-look-decor-scale-ui-test--check (frame)
  "The boxes on FRAME are the table's at FRAME's whole scale."
  (let* ((s (drgnx-pixels-scale frame))
         (want (cdr (seq-find (lambda (r) (< (abs (- (car r) s)) 0.001)) drgnx-look-decor-scale-ui-test--want)))
         (card (face-attribute 'drgnx-card-single :box frame))
         (ring (face-attribute 'drgnx-focus-ring :box frame)))
    (should want)
    (should (equal (plist-get card :line-width) (nth 0 want)))
    (should (equal (plist-get ring :line-width) (nth 1 want)))
    (when (featurep 'glitnir)
      (should (equal (plist-get card :corner-radius) (nth 2 want))))))

(ert-deftest drgnx-ui-look-decor/boxes-follow-the-scale ()
  "Pattern D: with the boxes on, the frame's card edge, focus ring and card radius are the run's scale's; a UI scale
that takes the frame to 2 gives 2's at once (the density's change hook, which the UI scale runs); a scale change
\(Nidhogg's `nidhogg-frame-scale-change-functions') after the UI scale goes gives the run's values back; off, the
logical boxes come back."
  (skip-unless (display-graphic-p))
  (let ((f (selected-frame)) (faces '(drgnx-card-single drgnx-focus-ring)))
    (unwind-protect
        (progn
          ;; the Glitnir boxes (radius too), as ui/look's `drgnx-decor-faces-on' gives them
          (dolist (face faces)
            (face-spec-set face `((t :inherit secondary-selection :box ,(drgnx-decor-box face)))))
          (drgnx-decor-scale-on)
          (drgnx-look-decor-scale-ui-test--check f)
          (set-frame-parameter f 'drgnx-ui-scale (/ 2.0 (drgnx-pixels-scale f)))
          (run-hooks 'drgnx-look-density-changed-hook)
          (should (< (abs (- (drgnx-pixels-scale f) 2.0)) 0.001))
          (drgnx-look-decor-scale-ui-test--check f)
          (set-frame-parameter f 'drgnx-ui-scale nil)
          (run-hook-with-args 'nidhogg-frame-scale-change-functions f)
          (drgnx-look-decor-scale-ui-test--check f)
          (drgnx-decor-scale-off)
          (should (equal (plist-get (face-attribute 'drgnx-card-single :box f) :line-width) 1)))
      (set-frame-parameter f 'drgnx-ui-scale nil)
      (drgnx-decor-scale-off)
      (dolist (face faces) (face-spec-set face (get face 'face-defface-spec))))))

(provide 'look-decor-scale-gui-test)
;;; look-decor-scale-gui-test.el ends here
