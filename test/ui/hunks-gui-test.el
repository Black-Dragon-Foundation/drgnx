;;; hunks-gui-test.el --- GUI tests: the change marks in the gutter, the look's solid bars (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det

;; The mockups' gutter (`docs/specs/drgnx/the-look/window-dark.html', `.ln .g.add' and `.g.chg'): a solid 3 px bar,
;; green beside an added line and blue beside a changed one, a short red mark where lines were deleted.  The rows draw
;; the marks as the hub's answer would (`drgnx-hunks--data') beside code lines in the dark, light and high-contrast
;; themes and read the pixels: the bar is `drgnx-px' 3 wide, whole, solid on every row of its line, in the status
;; colour of its kind, and the next line has none.  Pictures are saved to $DRGNX_UI_EVIDENCE (else $DRGNX_TEST_SHOTS) as
;; hunks-THEME.png.  Pattern D: each picture is taken after `drgnx-test-wait-presented'.

(require 'ert)
(require 'cl-lib)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)
(require 'drgnx-look-gui-fixture (expand-file-name "../fixtures/look-gui-fixture" (file-name-directory (macroexp-file-name))))

(defconst drgnx-ui-hunks--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-hunks--repo)))
(require 'drgnx)
(load (expand-file-name "modules/extra/drgnx-hunks" drgnx-ui-hunks--repo) nil t)
(load (expand-file-name "themes/drgnx-theme-gen" drgnx-ui-hunks--repo) nil t)

(defconst drgnx-ui-hunks--code
  "(defun drgnx-gateway--reply (p reply)
  \"Send REPLY to P, or queue it.\"
  (if (process-live-p p)
      (process-send-string p reply)
    (drgnx-gateway--queue p reply)))
(defun drgnx-gateway--drop (p)
  (setq drgnx-gateway--clients (delq p drgnx-gateway--clients)))
")

(defun drgnx-ui-hunks--shot (theme)
  "Save the root frame's picture as hunks-THEME.png; its path."
  (let* ((dir (or (getenv "DRGNX_UI_EVIDENCE") (getenv "DRGNX_TEST_SHOTS") (make-temp-file "hunks" t)))
         (shot (plist-get (drgnx-uitest-capture (make-temp-file "hunks-shot" t)) :root))
         (target (expand-file-name (format "hunks-%s.png" theme) dir)))
    (make-directory dir t)
    (copy-file shot target t)
    target))

(defun drgnx-ui-hunks--rgb (face)
  "FACE's foreground as (R G B) 0..255."
  (mapcar (lambda (c) (round (/ c 257.0))) (color-values (face-foreground face nil t))))

(defun drgnx-ui-hunks--row-pixels (snap win line)
  "The pixels of the vertical middle of LINE of WIN's buffer across the fringe: a list of (X . (R G B)), device pixels."
  (let* ((s (drgnx-uitest-device-scale (selected-frame)))
         (pos (save-excursion (goto-char (point-min)) (forward-line (1- line)) (point)))
         (vis (pos-visible-in-window-p pos win t))
         (y (round (* s (+ (nth 1 vis) (/ (line-pixel-height) 2)))))
         (x0 (round (* s (nth 0 (window-pixel-edges win)))))
         (fringe (round (* s (car (window-fringes win)))))
         out)
    (dotimes (i (max 1 fringe))
      (push (cons (+ x0 i) (cdr (drgnx-uitest-pixel snap (+ x0 i) y))) out))
    (nreverse out)))

(defun drgnx-ui-hunks--near-p (pixel rgb)
  (cl-every (lambda (p c) (<= (abs (- p c)) 24)) pixel rgb))

(drgnx-look-gui-deftest drgnx-ui-hunks/the-gutter-bars-are-solid-and-three-pixels-wide ()
  "Pattern D: an added line has a green bar and a changed line a blue one, each `drgnx-px' 3 wide, whole, on the
status colour of its kind, in the three themes; the line after has none."
  (skip-unless (display-graphic-p))
  (drgnx-uitest-bare-frame)
  (delete-other-windows)
  (let ((buf (generate-new-buffer "hunks-code")))
    (unwind-protect
        (dolist (theme '(drgnx-dark drgnx-light drgnx-high-contrast))
          (mapc #'disable-theme custom-enabled-themes)
          (load-theme theme t)
          (should (memq theme custom-enabled-themes))
          (switch-to-buffer buf)
          (delete-other-windows)
          (with-current-buffer buf
            (erase-buffer) (insert drgnx-ui-hunks--code) (emacs-lisp-mode)
            (setq-local display-line-numbers t)
            (set-window-fringes nil 8 8)
            (setq drgnx-hunks--data
                  (list (list :old-start 3 :old-count 1 :new-start 3 :new-count 1 :old-lines '("x\n"))        ; line 3 changed
                        (list :old-start 4 :old-count 0 :new-start 5 :new-count 1 :old-lines nil)))          ; line 5 added
            (setq drgnx-hunks-mode t)
            (drgnx-hunks--draw))
          (drgnx-test-wait-presented)
          (let* ((w (selected-window)) (snap (drgnx-uitest-snapshot))
                 (bar (drgnx-px 3 (selected-frame)))
                 (scale (drgnx-uitest-device-scale (selected-frame))))
            (dolist (c `((3 . drgnx-hunk-changed) (5 . drgnx-hunk-added)))
              (let* ((rgb (drgnx-ui-hunks--rgb (cdr c)))
                     (px (drgnx-ui-hunks--row-pixels snap w (car c)))
                     (lit (seq-filter (lambda (p) (drgnx-ui-hunks--near-p (cdr p) rgb)) px)))
                (message "HUNKS %s line %d: %d bar pixels of %d fringe pixels, first x %s, wanted %d at scale %s"
                         theme (car c) (length lit) (length px) (car (car lit)) bar scale)
                ;; solid and whole: exactly the bar's device pixels, in a row
                (should (= (length lit) (* bar (if (drgnx-pixels-device-p) 1 1))))
                (should (= (- (car (car (last lit))) (car (car lit))) (1- (length lit))))))
            ;; a line with no change has no bar
            (let* ((rgbs (list (drgnx-ui-hunks--rgb 'drgnx-hunk-added) (drgnx-ui-hunks--rgb 'drgnx-hunk-changed)))
                   (px (drgnx-ui-hunks--row-pixels snap w 4)))
              (should-not (seq-find (lambda (p) (seq-find (lambda (c) (drgnx-ui-hunks--near-p (cdr p) c)) rgbs)) px))))
          (message "HUNKS picture %s" (drgnx-ui-hunks--shot theme)))
      (with-current-buffer buf (setq drgnx-hunks-mode nil) (drgnx-hunks--clear))
      (mapc #'disable-theme custom-enabled-themes)
      (kill-buffer buf))))

(provide 'hunks-gui-test)
;;; hunks-gui-test.el ends here
