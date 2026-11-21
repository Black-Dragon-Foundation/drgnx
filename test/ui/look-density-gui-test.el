;;; look-density-gui-test.el --- GUI tests: the code line follows the density (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: every measurement is taken after `drgnx-test-wait-presented'.  The code line is 21 logical pixels
;; (comfortable), 19 compact and 23 roomy, at whatever scale the run has (DRGNX_UI_SCALE: 1, 1.25, 4/3, 1.5, 2), in
;; the frame's pixels by the pixel rule (`drgnx-px', half up), and never under the font's own line: at 4/3 the
;; font's line is 26 pixels, over compact's 25, and the line stays the font's.

(require 'ert)
(require 'drgnx-look-gui-fixture (expand-file-name "../fixtures/look-gui-fixture" (file-name-directory (macroexp-file-name))))
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

(drgnx-look-gui-deftest drgnx-ui-look-density/code-line-is-21 ()
  "Pattern D: `line-pixel-height' in a code buffer is 21 logical pixels when comfortable, and 19 / 23 for compact
and roomy after a setting change, with no restart; never under the font's own line (`frame-char-height')."
  (skip-unless (display-graphic-p))
  (let ((was (window-buffer)))
    (unwind-protect
        (progn
          (drgnx-look-density-on)
          (dolist (row '((comfortable . 21) (compact . 19) (roomy . 23) (comfortable . 21)))
            (let ((drgnx-look-density (car row)))
              (drgnx-look-density-apply)
              (should (= (max (drgnx-px (cdr row)) (frame-char-height)) (drgnx-look-density-ui-test--line-pixels))))))
      (drgnx-look-density-off)
      (set-window-buffer (selected-window) was))))

(drgnx-look-gui-deftest drgnx-ui-look-density/a-new-frame-gets-the-code-line ()
  "Pattern D: a frame made after the density is on (as `C-x 5 2', `emacsclient -c' and a daemon's first graphical
frame make one: the store's `frame-added') has 21 logical pixel lines too (`drgnx-px'), not the font's own."
  (skip-unless (display-graphic-p))
  (let ((state-was (bound-and-true-p drgnx-state-mode)) (frame nil) (buf (get-buffer-create " *look-density-new*")))
    (with-current-buffer buf (erase-buffer) (insert "code\ncode\n"))
    (unwind-protect
        (progn
          (drgnx-state-mode 1)
          (drgnx-look-density-on)
          (setq frame (make-frame '((name . "look-density-new"))))
          (set-window-buffer (frame-selected-window frame) buf)
          (let ((sample (drgnx-test-wait-presented
                         :frame frame
                         :value (lambda ()
                                  (with-selected-window (frame-selected-window frame)
                                    (goto-char (point-min))
                                    (list (max (drgnx-px 21 frame) (frame-char-height frame))
                                          (line-pixel-height)))))))
            (should (= (nth 0 sample) (nth 1 sample)))))
      (drgnx-look-density-off)
      (when (frame-live-p frame) (delete-frame frame))
      (drgnx-state-mode (if state-was 1 -1))
      (kill-buffer buf))))

(provide 'look-density-gui-test)
;;; look-density-gui-test.el ends here
