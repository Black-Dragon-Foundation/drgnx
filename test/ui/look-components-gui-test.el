;;; look-components-gui-test.el --- GUI tests: buttons and chips as the look draws them (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; Design §3.5 (`.btn', `.chip'): a button is 26 px tall with its ring, on the quiet selection's fill; the primary one
;; is on the accent's fill; a chip is on its tint with no ring in the text colour.  Pattern D: every measurement is
;; taken after `drgnx-test-wait-presented', at whatever scale the run has (DRGNX_UI_SCALE).  Also writes a picture of
;; the buttons and chips to the session's evidence folder when there is one.

(require 'ert)
(require 'cl-lib)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-look-components-ui-test--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness" "themes"))
  (add-to-list 'load-path (expand-file-name d drgnx-look-components-ui-test--repo)))
(add-to-list 'custom-theme-load-path (expand-file-name "themes" drgnx-look-components-ui-test--repo))
(require 'drgnx)
(require 'drgnx-ui-kit)
(load (expand-file-name "modules/ui/drgnx-decor" drgnx-look-components-ui-test--repo) nil t)

(declare-function drgnx-look-token "drgnx-theme-gen")
(declare-function drgnx-decor-chip "drgnx-decor")

(defun drgnx-look-components-ui-test--rgb (hex)
  "HEX as the (A R G B) a snapshot gives."
  (cons 255 (mapcar (lambda (i) (string-to-number (substring hex i (+ i 2)) 16)) '(1 3 5))))

(ert-deftest drgnx-ui-look-components/a-button-is-26-px-on-its-fill ()
  "A UI-kit button (and the primary one) on a line of its own makes the line 26 logical pixels (24 inside the 1 px
ring), and the inside of the button is the theme's fill: the quiet selection, the accent's fill for the primary."
  (skip-unless (display-graphic-p))
  (drgnx-uitest-bare-frame)
  (let ((buf (get-buffer-create "*look-components*")))
    (unwind-protect
        (progn
          (mapc #'disable-theme custom-enabled-themes)
          (load-theme 'drgnx-dark t)
          (switch-to-buffer buf)
          (erase-buffer)
          (insert "\n")
          (insert (drgnx-ui-button "Open a folder…" #'ignore :face 'drgnx-ui-button-primary) "\n\n")
          (insert (drgnx-ui-button "All keys" #'ignore) "\n\n")
          (insert (drgnx-decor-chip "claude · opus") " " (drgnx-decor-chip "sandboxed") "\n")
          (goto-char (point-min))
          (drgnx-test-wait-presented)
          (let* ((frame (selected-frame)) (s (drgnx-uitest-device-scale frame))
                 (snap (drgnx-uitest-snapshot))
                 (edges (window-inside-pixel-edges)))
            (when-let* ((dir (getenv "DRGNX_UI_EVIDENCE")) ((file-directory-p dir)))
              (copy-file (plist-get (drgnx-uitest-capture (make-temp-file "components" t)) :root)
                         (expand-file-name (format "components-s%s.png" (drgnx-pixels-scale frame)) dir) t))
            (pcase-dolist (`(,label ,token) '(("Open a folder" accent-fill) ("All keys" sel-quiet)))
              (goto-char (point-min))
              (search-forward label)
              (goto-char (match-beginning 0))
              ;; the room before the label (the pad), a few pixels in from the ring
              (let* ((xy (posn-x-y (posn-at-point (1- (point)))))
                     (x (round (* s (+ (car edges) (car xy) 6))))
                     (y (round (* s (+ (cadr edges) (cdr xy) 4)))))
                (should (equal (list label (round (* (drgnx-pixels-scale frame) 26)))
                               (list label (line-pixel-height))))
                (should (equal (list label (drgnx-look-components-ui-test--rgb (drgnx-look-token token 'dark)))
                               (list label (drgnx-uitest-pixel snap x y))))))))
      (mapc #'disable-theme custom-enabled-themes)
      (kill-buffer buf))))

(provide 'look-components-gui-test)
;;; look-components-gui-test.el ends here
