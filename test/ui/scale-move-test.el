;;; scale-move-test.el --- GUI test: a frame's monitor scale changes under it (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: the scale is changed in the session's own mutter (`gdctl set', as the user's display settings do), and
;; every size is read after the frame took the new scale and `drgnx-test-wait-presented'.  Mutter only, 2880x1800
;; (1.25, 4/3 and 2 all fit it exactly); other compositors skip.

(require 'ert)
(require 'cl-lib)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-scale-move-test--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-scale-move-test--repo)))
(require 'drgnx)
(dolist (m '("drgnx-look-fonts" "drgnx-look-density" "drgnx-look-scale" "drgnx-statusbar" "drgnx-decor"))
  (load (expand-file-name (concat "modules/ui/" m) drgnx-scale-move-test--repo) nil t))

(defvar drgnx-look-density)
(defvar drgnx-look-scale)
(declare-function nidhogg-frame-text-zoom "nidhogg-scale" (&optional frame))

(defun drgnx-scale-move-test--set-scale (scale)
  "Put the session's one monitor (Meta-0, primary) at SCALE through mutter's display config; non-nil when it took."
  (and (executable-find "gdctl")
       (eq 0 (call-process "gdctl" nil nil nil "set" "--logical-monitor" "--primary" "--monitor" "Meta-0"
                           "--scale" (number-to-string scale)))))

(defun drgnx-scale-move-test--read-events ()
  "Read input for a moment, so the special events waiting (a scale's `config-changed-event') are handled."
  (dotimes (_ 5) (read-event nil nil 0.02)))

(defun drgnx-scale-move-test--sizes (frame)
  "FRAME's sizes in its pixels: (FONT CODE-LINE STATUS-BAR GAP RADIUS RING)."
  (let ((w (frame-selected-window frame)) (was (window-buffer (frame-selected-window frame))))
    (list (aref (font-info (face-font 'default frame) frame) 2)
          (with-temp-buffer
            (insert "code\ncode\n")
            (set-window-buffer w (current-buffer))
            (drgnx-test-wait-presented :frame frame)
            (prog1 (with-selected-window w (goto-char (point-min)) (line-pixel-height))
              (set-window-buffer w was)))
          (drgnx-statusbar--row-height frame)
          (drgnx-px (drgnx-look-density-value 'gap) frame)
          (plist-get (face-attribute 'drgnx-card-single :box frame) :corner-radius)
          (plist-get (face-attribute 'drgnx-focus-ring :box frame) :line-width))))

(defun drgnx-scale-move-test--fresh (frame s)
  "The sizes a fresh session at total scale S shows on FRAME, as `drgnx-scale-move-test--sizes' lists them."
  (let ((h (face-attribute 'default :height t)) (px (lambda (v) (floor (+ (* v s) 0.5 1e-9)))))
    (unless (integerp h) (setq h (car (frame-parameter frame 'nidhogg--font-height))))
    (list (floor (+ (/ (* (/ h 10.0) 96.0 s) 72.0) 0.5))
          (funcall px 21) (funcall px 24) (funcall px (drgnx-look-density-value 'gap))
          (and (featurep 'glitnir) (funcall px 8))
          (drgnx-px-line 2 nil s))))

(ert-deftest drgnx-ui-scale/screen-move-keeps-every-size ()
  "Pattern D: the monitor goes 1.25 → 1 → 2 → 1.25 under the frame; at each step the default font, the code line,
the status bar, the gap, a card's radius and the focus ring are a fresh session's at that scale, and at the end
everything is what it was at the start (no drift).  Then the same at a UI scale of 110 %."
  ;; only mutter takes a `gdctl set'
  (skip-unless (and (display-graphic-p) (fboundp 'nidhogg-set-frame-text-zoom) (drgnx-scale-move-test--set-scale 1.25)))
  (let ((f (selected-frame)) (drgnx-look-density 'comfortable) (faces '(drgnx-card-single drgnx-focus-ring)))
    (unwind-protect
        (progn
          ;; the Glitnir boxes, as ui/look's `drgnx-decor-faces-on' gives them
          (dolist (face faces) (face-spec-set face `((t :inherit secondary-selection :box ,(drgnx-decor-box face)))))
          (drgnx-look-density-on)
          (drgnx-look-scale-on)
          (drgnx-decor-scale-on)
          (dolist (ui '(100 110))
            ;; the setting, which the scale hooks read again at each change
            (setq drgnx-look-scale ui)
            (drgnx-look-scale-apply)
            (let (start)
              (dolist (scale '(1.25 1 2 1.25))
                (should (drgnx-scale-move-test--set-scale scale))
                (should (drgnx-test-wait-presented
                         :value (lambda () (< (abs (- (frame-scale-factor f) scale)) 0.001))))
                (should (< (abs (- (frame-scale-factor f) scale)) 0.001))
                ;; the scale's special event (fonts reopened, then the scale hooks) runs where input is read, as in
                ;; the command loop
                (drgnx-scale-move-test--read-events)
                (drgnx-test-wait-presented)
                (let ((got (drgnx-scale-move-test--sizes f)))
                  (message "scale-move: ui %d scale %s: %S" ui scale got)
                  (should (equal got (drgnx-scale-move-test--fresh f (* scale (/ ui 100.0)))))
                  (if start (when (= scale 1.25) (should (equal got start))) (setq start got)))))))
      (setq drgnx-look-scale 100)
      (drgnx-look-scale-apply-frame f 100)
      (drgnx-look-scale--follow)
      (drgnx-decor-scale-off)
      (drgnx-look-scale-off)
      (drgnx-look-density-off)
      (dolist (face faces) (face-spec-set face (get face 'face-defface-spec)))
      (drgnx-scale-move-test--set-scale (string-to-number (or (getenv "DRGNX_UI_SCALE") "1"))))))

(provide 'scale-move-test)
;;; scale-move-test.el ends here
