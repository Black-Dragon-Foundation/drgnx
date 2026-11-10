;;; look-open-fit-gui-test.el --- GUI tests: the Open section fits its rows (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake

;; Pattern D: the dock (Open above the Explorer) on the root frame with the store on; the frame is resized by a pixel
;; and the store's `frame-resized' runs through `drgnx-uitest-run'.  Run at each scale (s1, s1.25, s2): the Open
;; section is as tall as its rows (at s2 this frame caps it: whole rows, scrolled), and the Explorer's top does not
;; move.

(require 'ert)
(require 'cl-lib)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-ui-look-open-fit--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-look-open-fit--repo)))
(require 'drgnx)
(require 'drgnx-state)
(require 'drgnx-buffers)
(require 'drgnx-explorer)
(load (expand-file-name "modules/ui/drgnx-look-fonts" drgnx-ui-look-open-fit--repo) nil t)
(load (expand-file-name "modules/ui/drgnx-look-density" drgnx-ui-look-open-fit--repo) nil t)
(load (expand-file-name "themes/drgnx-theme-gen" drgnx-ui-look-open-fit--repo) nil t)

(defun drgnx-ui-look-open-fit--settle ()
  "Run the store's events and wait for the picture, until the dock's edges stop moving (a header line's height is
known after the first redisplay, and the store sees the change on the next observation; at most 5 rounds)."
  (let ((edges nil) (n 0))
    (while (and (< n 5) (not (equal edges (setq edges (mapcar #'window-pixel-edges (drgnx-wb--dock-windows))))))
      (setq n (1+ n))
      (drgnx-uitest-run (drgnx-uitest-key-events "C-l"))
      (drgnx-signal--flush)
      (drgnx-test-wait-presented))))

(ert-deftest drgnx-ui-look-open-fit/a-pixel-of-frame-never-moves-the-explorer ()
  "Four open files: the Open section's body is their rows exactly (no empty row below the last), or the whole rows
that fit in 0.3 of the frame, and growing or shrinking the frame by one pixel leaves the Explorer's top where it was."
  (let* ((root (drgnx-uitest-root-frame))
         (dir (file-name-as-directory (make-temp-file "look-open-fit" t)))
         (size (list (frame-pixel-width root) (frame-pixel-height root)))
         (config (with-selected-frame root (current-window-configuration)))
         (drgnx-wb--sections nil) (drgnx-buffers--order nil) (drgnx-buffers--signature nil)
         (drgnx-explorer--roots (list dir)) opened want)
    (unwind-protect
        (with-selected-frame root
          (delete-other-windows)
          (mapc #'disable-theme custom-enabled-themes)
          (load-theme 'drgnx-dark t)
          (drgnx-look-density-on)
          (drgnx-state-mode 1)
          (drgnx-buffers-setup)
          (drgnx-explorer-setup)
          (dolist (n '("a.txt" "b.txt" "c.txt" "d.txt"))
            (let ((f (expand-file-name n dir)))
              (write-region "x\n" nil f nil 'silent)
              (push (find-file-noselect f) opened)))
          (drgnx-signal--flush)                       ; the store has seen the frame: the sidebar is a change
          (drgnx-wb-show-sidebar)
          (drgnx-ui-look-open-fit--settle)
          (let* ((open (get-buffer-window drgnx-buffers-buffer-name root))
                 (explorer (get-buffer-window drgnx-explorer-buffer-name root))
                 (rows (with-current-buffer drgnx-buffers-buffer-name (count-lines (point-min) (point-max))))
                 (row (round (* (drgnx-pixels-scale root) (drgnx-look-density-value 'tree-row))))
                 (top (window-pixel-top explorer)))
            (should (>= rows 4))
            ;; all its rows, or, past 0.3 of the frame (s2 in this 900-pixel frame), the whole rows that fit there
            (setq want (min (* rows row)
                            (* row (/ (- (floor (* 0.3 (frame-inner-height root)))
                                         (- (window-pixel-height open) (window-body-height open t)))
                                      row))))
            (should (= (window-body-height open t) want))
            (dolist (dh '(1 -1 -1 1))
              (set-frame-size root (car size) (+ (frame-pixel-height root) dh) t)
              (drgnx-ui-look-open-fit--settle)
              (should (equal (list dh (frame-inner-height root) (window-pixel-top explorer) (window-body-height open t))
                             (list dh (frame-inner-height root) top want))))))
      (drgnx-state-mode -1)
      (drgnx-wb-hide-sidebar)
      (drgnx-look-density-off)
      (mapc #'disable-theme custom-enabled-themes)
      (set-frame-size root (car size) (cadr size) t)
      (with-selected-frame root (set-window-configuration config))
      (dolist (b opened) (kill-buffer b))
      (dolist (b (list drgnx-buffers-buffer-name drgnx-explorer-buffer-name)) (when (get-buffer b) (kill-buffer b)))
      (delete-directory dir t))))

(provide 'look-open-fit-gui-test)
;;; look-open-fit-gui-test.el ends here
