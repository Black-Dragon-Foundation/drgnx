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
(require 'drgnx-palette)
(load (expand-file-name "modules/ui/drgnx-decor" drgnx-look-components-ui-test--repo) nil t)

(declare-function drgnx-look-token "drgnx-theme-gen")
(declare-function drgnx-decor-chip "drgnx-decor")
(declare-function glitnir-active-p "glitnir")

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

(ert-deftest drgnx-ui-look-components/keycaps-and-buttons-are-in-the-ui-font ()
  "In a buffer whose default font is the code font (the start page's), a keycap is drawn in the caption role's family
and a button in the UI text role's; under Glitnir a button's corner is rounded (its corner pixel is not its fill)."
  (skip-unless (display-graphic-p))
  (drgnx-uitest-bare-frame)
  (let ((buf (get-buffer-create "*look-components-fonts*")))
    (unwind-protect
        (progn
          (mapc #'disable-theme custom-enabled-themes)
          (load-theme 'drgnx-dark t)
          (switch-to-buffer buf)
          (erase-buffer)
          (insert "\n" (drgnx-palette-keycaps "C-p") "\n\n")
          ;; after a space, as on the start page (centred); at a row's first glyph Glitnir fills the left corners
          (insert " " (drgnx-ui-button "Open a folder…" #'ignore :face 'drgnx-ui-button-primary) "\n")
          (goto-char (point-min))
          (drgnx-test-wait-presented)
          (let ((family (lambda (s) (goto-char (point-min)) (search-forward s)
                          (symbol-name (font-get (font-at (1- (point))) :family)))))
            (should (equal (list 'button (face-attribute 'drgnx-ui-text :family nil t))
                           (list 'button (funcall family "folder"))))
            (should (equal (list 'keycap (face-attribute 'drgnx-ui-caption :family nil t))
                           (list 'keycap (funcall family "Ctrl")))))
          (when (and (fboundp 'glitnir-active-p) (glitnir-active-p))   ; drawing, not just loaded
            (goto-char (point-min)) (search-forward "Open")
            (let* ((frame (selected-frame)) (s (drgnx-uitest-device-scale frame)) (edges (window-inside-pixel-edges))
                   (start (posn-x-y (posn-at-point (1+ (line-beginning-position)))))   ; past the space
                   (end (posn-x-y (posn-at-point (line-end-position))))
                   (snap (drgnx-uitest-snapshot))
                   (y (round (* s (+ (cadr edges) (cdr start)))))
                   (fill (drgnx-look-components-ui-test--rgb (drgnx-look-token 'accent-fill 'dark))))
              (should (equal fill (drgnx-uitest-pixel snap (round (* s (+ (car edges) (car start) (drgnx-px 8))))
                                                      (+ y (drgnx-px 8)))))
              (pcase-dolist (`(,corner ,x) `((left ,(round (* s (+ (car edges) (car start)))))
                                             (right ,(1- (round (* s (+ (car edges) (car end))))))))
                (should-not (equal (list corner fill) (list corner (drgnx-uitest-pixel snap x y))))))))
      (mapc #'disable-theme custom-enabled-themes)
      (kill-buffer buf))))

(provide 'look-components-gui-test)
;;; look-components-gui-test.el ends here
