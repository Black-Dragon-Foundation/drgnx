;;; notice-toast-gui-test.el --- GUI tests: a notice floats as a toast above the status bar (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det

;; A notice offered to the toast route shows in a child frame at the bottom right of the editor frame, above the
;; status bar and inside the outer gap, and takes no focus.  Pattern D: the geometry is read after
;; `drgnx-test-wait-presented'.  The row skips unless Glitnir draws the frames (the native shell).

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-notice-toast-gui-test--repo     ; the session runs the repository's test/ui
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-notice-toast-gui-test--repo)))
(require 'drgnx)
(require 'drgnx-notice-toast)

(defun drgnx-notice-toast-gui-test--edges (frame)
  "FRAME's edges (LEFT TOP RIGHT BOTTOM) in its parent's pixels: its position and its size."
  (let ((p (frame-position frame)))
    (list (car p) (cdr p) (+ (car p) (frame-pixel-width frame)) (+ (cdr p) (frame-pixel-height frame)))))

(ert-deftest drgnx-ui-notice-toast/placed-above-the-status-bar ()
  "Pattern D: the toast's bottom edge is above the mode line's top; its right edge is inside the outer gap."
  (skip-unless (drgnx-uitest-glitnir-p))
  (drgnx-uitest-bare-frame)
  (let ((root (drgnx-uitest-root-frame)) (drgnx-notice-style 'float)
        (drgnx-notice-toast--visible nil) (drgnx-notice-toast--waiting nil))
    (unwind-protect
        (progn
          (drgnx-notice-toast-admit '(:source config :id 1 :severity warn :life event :text "A toast" :detail "More"))
          (drgnx-notice-toast--sync)
          (drgnx-test-wait-presented)
          (let* ((toast (seq-find (lambda (f) (frame-parameter f 'drgnx-notice-toast)) (frame-list)))
                 (win (car (sort (seq-filter (lambda (w) (not (window-minibuffer-p w))) (window-list root))
                                 (lambda (a b) (> (nth 3 (window-pixel-edges a)) (nth 3 (window-pixel-edges b)))))))
                 (mode-line-top (- (nth 3 (window-pixel-edges win)) (window-mode-line-height win)))
                 (e (drgnx-notice-toast-gui-test--edges toast)))
            (should toast)
            (should (frame-visible-p toast))
            (should (eq (frame-parent toast) root))
            (should (<= (nth 3 e) mode-line-top))
            (should (<= (nth 2 e) (- (frame-pixel-width root) (frame-parameter root 'internal-border-width))))
            (should (frame-parameter toast 'no-accept-focus))
            (should (eq (selected-frame) root))))
      (drgnx-notice-toast-delete-all))))

(provide 'notice-toast-gui-test)
;;; notice-toast-gui-test.el ends here
