;;; look-teardown-gui-test.el --- GUI test: ui/look on and off leaves the frame as it was (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake

;; ui/look's setup changes the root frame (the cards' gap as its edge and dividers, the fonts, the density); its
;; teardown gives every one of them back, and the frame its size: under a tiling compositor (sway) the frame's size is
;; the compositor's, and one the teardown asks for is not given back by it.

(require 'ert)
(require 'cl-lib)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)
(require 'drgnx-look-gui-fixture (expand-file-name "../fixtures/look-gui-fixture" (file-name-directory (macroexp-file-name))))

(defconst drgnx-ui-look-teardown--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-look-teardown--repo)))
(require 'drgnx)
(add-to-list 'custom-theme-load-path (expand-file-name "themes" drgnx-ui-look-teardown--repo))
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-ui-look-teardown--repo) nil t)
(load (expand-file-name "modules/ui/drgnx-look" drgnx-ui-look-teardown--repo) nil t)
(defvar drgnx-look-echo-row)                ; drgnx-look loads drgnx-look-echo above

(defun drgnx-ui-look-teardown--frame (f)
  "What of frame F a teardown must give back: its pixel size and the parameters that size it."
  (list (frame-pixel-width f) (frame-pixel-height f) (frame-text-cols f) (frame-text-lines f)
        (mapcar (lambda (p) (frame-parameter f p))
                '(internal-border-width right-divider-width bottom-divider-width left-fringe right-fringe
                                        font line-spacing minibuffer))))

(drgnx-look-gui-deftest drgnx-ui-look-teardown/on-and-off-keeps-the-root-frame ()
  "ui/look set up and torn down, with the classic echo row (the root frame keeps its minibuffer): the root frame has
its size and its sizing parameters back."
  :tags '(:compositor)
  (skip-unless (display-graphic-p))
  (let* ((root (drgnx-uitest-root-frame))
         (before (drgnx-ui-look-teardown--frame root))
         (themes custom-enabled-themes)
         (drgnx-look-echo-row 'classic)
         during)
    (unwind-protect
        (with-selected-frame root
          (drgnx-test-with-modules '(ui/look)
            (drgnx-test-wait-presented)
            (setq during (drgnx-ui-look-teardown--frame root)))
          (drgnx-test-wait-presented)
          (should (equal (list :during during :after (drgnx-ui-look-teardown--frame root))
                         (list :during during :after before))))
      (mapc #'disable-theme custom-enabled-themes)
      (dolist (th (reverse themes)) (enable-theme th)))))

(provide 'look-teardown-gui-test)
;;; look-teardown-gui-test.el ends here
