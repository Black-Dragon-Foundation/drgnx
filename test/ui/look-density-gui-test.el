;;; look-density-gui-test.el --- GUI tests: the code line follows the density (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: every measurement is taken after `drgnx-test-wait-presented'.  The code line is 21 logical pixels
;; (comfortable), 19 compact and 23 roomy, at whatever scale the run has (DRGNX_UI_SCALE: 1, 1.25, 2).

(require 'ert)
(require 'cl-lib)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-look-density-ui-test--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-look-density-ui-test--repo)))
(require 'drgnx)
(load (expand-file-name "modules/ui/drgnx-look-fonts" drgnx-look-density-ui-test--repo) nil t)
(load (expand-file-name "modules/ui/drgnx-look-density" drgnx-look-density-ui-test--repo) nil t)

(defvar drgnx-look-density)

(defun drgnx-look-density-ui-test--line-pixels ()
  "The pixel height of a line of code in a code buffer in the selected window."
  (with-temp-buffer
    (insert "code\ncode\n")
    (set-window-buffer (selected-window) (current-buffer))
    (drgnx-test-wait-presented)
    (goto-char (point-min))
    (line-pixel-height)))

(ert-deftest drgnx-ui-look-density/code-line-is-21 ()
  "Pattern D: `line-pixel-height' in a code buffer is round (21 x scale) when comfortable, and 19 / 23 for compact
and roomy after a setting change, with no restart."
  (skip-unless (display-graphic-p))
  (let ((scale (if (fboundp 'frame-scale-factor) (float (frame-scale-factor)) 1.0))
        (was (window-buffer)))
    (unwind-protect
        (progn
          (drgnx-look-density-on)
          (dolist (row '((comfortable . 21) (compact . 19) (roomy . 23) (comfortable . 21)))
            (let ((drgnx-look-density (car row)))
              (drgnx-look-density-apply)
              (should (= (round (* (cdr row) scale)) (drgnx-look-density-ui-test--line-pixels))))))
      (drgnx-look-density-off)
      (set-window-buffer (selected-window) was))))

(provide 'look-density-gui-test)
;;; look-density-gui-test.el ends here
