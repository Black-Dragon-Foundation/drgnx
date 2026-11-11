;;; debug-gutter-gui-test.el --- GUI test: the breakpoint column's hover dot (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake

;; A file with the column (`always'), a breakpoint on line 3, dark theme.  At rest no hover dot shows anywhere in the
;; margin: on a plain line, on the current line (hl-line), on a region line, or on a line with a coloured band (the
;; stand-in of a session's stopped-line band, whose line carries the arrow mark and so no dot).  The pointer noted on a
;; line's dot (`nidhogg--note-mouse', as a shell notes it) lights it in the hover colour.  Needs Nidhogg's margin
;; `mouse-face' (feature `glitnir-margin-mouse-face'); writes the column at rest and hovered to the evidence folder.

(require 'ert)
(require 'cl-lib)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)
(require 'drgnx-look-gui-fixture (expand-file-name "../fixtures/look-gui-fixture" (file-name-directory (macroexp-file-name))))

(defconst drgnx-ui-debug-gutter--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-debug-gutter--repo)))
(require 'drgnx)
(require 'drgnx-color)
(load (expand-file-name "themes/drgnx-theme-gen" drgnx-ui-debug-gutter--repo) nil t)
(dolist (m '("drgnx-debug-launch" "drgnx-debug-gutter"))
  (load (expand-file-name (concat "modules/extra/" m) drgnx-ui-debug-gutter--repo) nil t))

(defun drgnx-ui-debug-gutter--margin (line)
  "(LEFT RIGHT Y) of the left margin on LINE of the selected window, device pixels (a Lisp pixel is one), Y the row's
middle."
  (save-excursion
    (goto-char (point-min)) (forward-line (1- line))
    (pcase-let* ((`(,_ . ,y) (posn-x-y (posn-at-point (point))))
                 (`(,left ,top . ,_) (window-inside-pixel-edges))
                 (cw (frame-char-width))
                 (right (- left (if (nth 2 (window-fringes)) 0 (car (window-fringes)))))
                 (l (- right (* (car (window-margins)) cw))))
      (list l right (+ top y (/ (line-pixel-height) 2))))))

(defun drgnx-ui-debug-gutter--row (snap line)
  "The pixels (R G B) across the margin's middle row on LINE."
  (pcase-let ((`(,l ,r ,y) (drgnx-ui-debug-gutter--margin line)))
    (cl-loop for x from l below r collect (cdr (drgnx-uitest-pixel snap x y)))))

(defun drgnx-ui-debug-gutter--near (px colour)
  "Whether pixel PX (R G B, 0..255) is COLOUR within 6 per channel."
  (cl-every (lambda (p c) (<= (abs (- p c)) 6)) px (mapcar (lambda (c) (round (* 255 c))) (drgnx-color-rgb colour))))

(defun drgnx-ui-debug-gutter--shot (name)
  "Copy the frame's picture to the evidence folder as NAME-s<scale>.png, when the session has one."
  (when-let* ((dir (getenv "DRGNX_UI_EVIDENCE")) ((file-directory-p dir)))
    (copy-file (plist-get (drgnx-uitest-capture (make-temp-file "debug-gutter" t)) :root)
               (expand-file-name (format "%s-s%s.png" name (drgnx-pixels-scale)) dir) t)))

(drgnx-look-gui-deftest drgnx-ui-debug-gutter/no-dot-at-rest-the-pointer-shows-it ()
  "No hover dot at rest on a plain, current, region or banded line; the pointer on a line's dot lights it."
  (skip-unless (display-graphic-p))
  (skip-unless (featurep 'glitnir-margin-mouse-face))
  (let* ((root (drgnx-uitest-root-frame))
         (dir (file-name-as-directory (make-temp-file "debug-gutter-gui" t)))
         (file (expand-file-name "a.py" dir))
         (config (with-selected-frame root (current-window-configuration)))
         (drgnx-debug-gutter-show 'always)
         buf band)
    (unwind-protect
        (with-selected-frame root
          (delete-other-windows)
          (mapc #'disable-theme custom-enabled-themes)
          (load-theme 'drgnx-dark t)
          (with-temp-file file (dotimes (i 14) (insert (format "value_%d = compute(%d)\n" (1+ i) (1+ i)))))
          (setq buf (find-file-noselect file))
          (switch-to-buffer buf)
          (cl-letf (((symbol-function 'drgnx-hub-call) #'ignore)
                    ((symbol-function 'drgnx-debug-launch-root) (lambda () dir)))
            (drgnx-debug-gutter-mode 1)
            (drgnx-debug-gutter--apply (list :version 1 :breakpoints (list (list :id 1 :line 3 :enabled t :verified t)))))
          ;; the band's stand-in: the warn colour at 15 % over the editor, to the window's edge
          (setq band (make-overlay (save-excursion (goto-char (point-min)) (forward-line 8) (point))
                                   (save-excursion (goto-char (point-min)) (forward-line 9) (point))))
          (overlay-put band 'face (list :background (drgnx-color-over (face-foreground 'drgnx-status-warn nil t)
                                                                      (face-background 'default nil t) 0.15)
                                        :extend t))
          (hl-line-mode 1)
          (transient-mark-mode 1)
          (goto-char (point-min)) (forward-line 4)              ; line 5: the current line
          (nidhogg--note-mouse nil 'leave nil)
          (drgnx-test-wait-presented)
          (let ((bg (drgnx-debug-gutter--margin-background)) snap)
            ;; the current line (5) and a plain line (11)
            (setq snap (drgnx-uitest-snapshot))
            (dolist (line '(5 11))
              (should (cl-every (lambda (px) (drgnx-ui-debug-gutter--near px bg)) (drgnx-ui-debug-gutter--row snap line))))
            ;; the breakpoint's line shows its glyph (the rows read the margin)
            (should-not (cl-every (lambda (px) (drgnx-ui-debug-gutter--near px bg)) (drgnx-ui-debug-gutter--row snap 3)))
            ;; the banded line (9)
            (should (cl-every (lambda (px) (drgnx-ui-debug-gutter--near px bg)) (drgnx-ui-debug-gutter--row snap 9)))
            ;; a region over line 7
            (goto-char (point-min)) (forward-line 6) (push-mark (point) t t) (end-of-line)
            (drgnx-test-wait-presented)
            (should (region-active-p))
            (setq snap (drgnx-uitest-snapshot))
            (should (cl-every (lambda (px) (drgnx-ui-debug-gutter--near px bg)) (drgnx-ui-debug-gutter--row snap 7)))
            (deactivate-mark)
            (drgnx-test-wait-presented)
            (drgnx-ui-debug-gutter--shot "debug-gutter-rest")
            ;; the pointer on line 11's dot: it lights in the hover colour, and only there
            (pcase-let* ((`(,l ,_ ,y) (drgnx-ui-debug-gutter--margin 11))
                         (cw (frame-char-width))
                         (x (+ l (* cw (+ (drgnx-margins-offset 'debug) (/ (1- (drgnx-debug-gutter--columns)) 2)))
                               (/ cw 2))))
              (should (nidhogg--note-mouse nil x y))
              (drgnx-test-wait-presented)
              (setq snap (drgnx-uitest-snapshot))
              (let ((hover (drgnx-color-over (face-foreground 'drgnx-debug-hover nil t) bg 0.38)))
                (should (cl-some (lambda (px) (drgnx-ui-debug-gutter--near px hover)) (drgnx-ui-debug-gutter--row snap 11))))
              (should (cl-every (lambda (px) (drgnx-ui-debug-gutter--near px bg)) (drgnx-ui-debug-gutter--row snap 12)))
              (drgnx-ui-debug-gutter--shot "debug-gutter-hover"))))
      (nidhogg--note-mouse nil 'leave nil)
      (when (overlayp band) (delete-overlay band))
      (when (buffer-live-p buf)
        (with-current-buffer buf (hl-line-mode -1) (drgnx-debug-gutter-mode -1) (set-buffer-modified-p nil))
        (kill-buffer buf))
      (mapc #'disable-theme custom-enabled-themes)
      (with-selected-frame root (set-window-configuration config))
      (delete-directory dir t))))

(provide 'debug-gutter-gui-test)
;;; debug-gutter-gui-test.el ends here
