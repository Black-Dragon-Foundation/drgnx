;;; debug-toolbar-gui-test.el --- GUI test: the debug toolbar's card fits its buttons (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake

;; A stopped session's floating toolbar on a graphical frame: the card is as tall as its one row of buttons and its
;; padding, no taller (it once kept a row's height of empty card below the buttons, over the code).

(require 'ert)
(require 'cl-lib)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)
(require 'drgnx-look-gui-fixture (expand-file-name "../fixtures/look-gui-fixture" (file-name-directory (macroexp-file-name))))

(defconst drgnx-ui-debug-toolbar--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-debug-toolbar--repo)))
(require 'drgnx)
(load (expand-file-name "themes/drgnx-theme-gen" drgnx-ui-debug-toolbar--repo) nil t)
(load (expand-file-name "modules/extra/drgnx-debug" drgnx-ui-debug-toolbar--repo) nil t)

(drgnx-look-gui-deftest drgnx-ui-debug-toolbar/the-card-fits-its-buttons ()
  "The card's height is its row of buttons and its padding, top and bottom."
  (skip-unless (display-graphic-p))
  (let* ((root (drgnx-uitest-root-frame))
         (session (list :id "s1" :name "Python: plan the week" :state "stopped" :caps nil))
         (drgnx-debug-toolbar 'floating)
         (drgnx-debug-toolbar--children (make-hash-table :test #'eq :weakness 'key))
         (drgnx-debug-toolbar--drawn (make-hash-table :test #'eq :weakness 'key))
         card)
    (unwind-protect
        (with-selected-frame root
          (mapc #'disable-theme custom-enabled-themes)
          (load-theme 'drgnx-dark t)
          (drgnx-debug-toolbar--show root session (list session))
          (setq card (gethash root drgnx-debug-toolbar--children))
          (drgnx-test-wait-presented)
          (let* ((win (frame-root-window card))
                 (row (cdr (window-text-pixel-size win nil nil 10000 10000)))
                 (pad (* 2 (frame-parameter card 'internal-border-width))))
            (should (> row 0))
            (should (<= (frame-pixel-height card) (+ row pad)))))
      (when (frame-live-p card) (delete-frame card))
      (mapc #'disable-theme custom-enabled-themes))))

(provide 'debug-toolbar-gui-test)
;;; debug-toolbar-gui-test.el ends here
