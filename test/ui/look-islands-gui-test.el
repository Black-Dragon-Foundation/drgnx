;;; look-islands-gui-test.el --- GUI tests: the cards under each theme and scale (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det

;; Pattern D: the picture is taken after `drgnx-test-wait-presented'.  The dock is a card while ui/look runs under
;; Glitnir; under dark, light and high contrast its corner shows the `gap' token and its body the `panel' token.  The
;; session's scale (1, 1.25, 2) is the runner's: run the row at each (look-ui.sh SCALE).

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)
(require 'drgnx-look-gui-fixture (expand-file-name "../fixtures/look-gui-fixture" (file-name-directory (macroexp-file-name))))

(defconst drgnx-ui-look-islands--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-look-islands--repo)))
(require 'drgnx)
(require 'drgnx-wb)
(require 'drgnx-color)
(load (expand-file-name "themes/drgnx-theme-gen" drgnx-ui-look-islands--repo) nil t)
(load (expand-file-name "modules/ui/drgnx-look" drgnx-ui-look-islands--repo) nil t)

(declare-function drgnx-look-cards-apply "drgnx-look")
(declare-function drgnx-look-cards-clear "drgnx-look")
(declare-function drgnx-look-token "drgnx-theme-gen")

(defun drgnx-ui-look-islands--argb (hex)
  "HEX as the (A R G B) a snapshot pixel is."
  (cons 255 (mapcar (lambda (c) (round (* 255 c))) (drgnx-color-rgb hex))))

(drgnx-look-gui-deftest drgnx-ui-look-islands/a-card-is-the-panel-on-the-gap-in-every-variant ()
  "LOOK-ISLANDS-LIGHT-HC-SCALES-1, pattern D: under drgnx-dark, -light and -high-contrast the dock's top-left corner
pixel is the `gap' token (the card's corner is cut away) and a pixel low in the middle of its body is the `panel' token."
  (skip-unless (drgnx-uitest-glitnir-p))
  (drgnx-uitest-bare-frame)
  (let ((drgnx-wb--sections nil))
    (drgnx-wb-define-section 'islands :slot 0 :title " EXPLORER"
                             :buffer (lambda () (with-current-buffer (get-buffer-create "*islands*")
                                                  (erase-buffer) (insert "dock text\n")
                                                  (face-remap-add-relative 'default 'drgnx-surface-panel)   ; as the dock's rows are
                                                  (current-buffer))))
    (unwind-protect
        (pcase-dolist (`(,theme . ,variant) '((drgnx-dark . dark) (drgnx-light . light) (drgnx-high-contrast . hc)))
          (mapc #'disable-theme custom-enabled-themes)
          (load-theme theme t)
          (drgnx-wb-show-sidebar)
          (drgnx-look-cards-apply)
          (drgnx-test-wait-presented)
          (let* ((dock (car (drgnx-wb--dock-windows)))
                 (s (drgnx-uitest-device-scale (window-frame dock)))
                 (r (mapcar (lambda (e) (round (* s e))) (window-pixel-edges dock)))
                 (snap (drgnx-uitest-snapshot)))
            (should dock)
            (should (equal (drgnx-ui-look-islands--argb (drgnx-look-token 'gap variant))
                           (drgnx-uitest-pixel snap (nth 0 r) (nth 1 r))))
            (should (equal (drgnx-ui-look-islands--argb (drgnx-look-token 'panel variant))
                           (drgnx-uitest-pixel snap (/ (+ (nth 0 r) (nth 2 r)) 2)
                                               (+ (nth 1 r) (round (* 0.8 (- (nth 3 r) (nth 1 r)))))))))
          (drgnx-look-cards-clear)
          (drgnx-wb-hide-sidebar))
      (drgnx-look-cards-clear)
      (when (drgnx-wb-sidebar-showing-p) (drgnx-wb-hide-sidebar))
      (drgnx-wb-undefine-section 'islands)
      (when (get-buffer "*islands*") (kill-buffer "*islands*"))
      (mapc #'disable-theme custom-enabled-themes))))

(provide 'look-islands-gui-test)
;;; look-islands-gui-test.el ends here
