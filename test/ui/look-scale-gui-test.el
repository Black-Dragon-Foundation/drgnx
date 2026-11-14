;;; look-scale-gui-test.el --- GUI tests: the UI scale and its per-monitor overrides (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: every measurement is taken after `drgnx-test-wait-presented'.  The run's display scale is DRGNX_UI_SCALE
;; (1, 1.25, 4/3, 2), or DRGNX_UI_SCALES for two monitors.  The UI scale multiplies it; Nidhogg's text zoom opens the
;; fonts at 96 dpi × scale × zoom.

(require 'ert)
(require 'drgnx-look-gui-fixture (expand-file-name "../fixtures/look-gui-fixture" (file-name-directory (macroexp-file-name))))
(require 'cl-lib)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-look-scale-ui-test--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-look-scale-ui-test--repo)))
(require 'drgnx)
(dolist (m '("drgnx-look-fonts" "drgnx-look-density" "drgnx-look-scale" "drgnx-statusbar"))
  (load (expand-file-name (concat "modules/ui/" m) drgnx-look-scale-ui-test--repo) nil t))

(defvar drgnx-look-scale)
(defvar drgnx-look-scale-monitors)
(declare-function nidhogg-frame-text-zoom "nidhogg-scale" (&optional frame))

(defun drgnx-look-scale-ui-test--font-px (frame)
  "The pixel size of FRAME's default font."
  (aref (font-info (face-font 'default frame) frame) 2))

(defun drgnx-look-scale-ui-test--fresh-px (frame)
  "The pixel size a fresh open of the default font's height gives on FRAME: HEIGHT/10 × 96 × scale × zoom / 72,
half up.  The height is the one set for new frames, else the one Nidhogg keeps for FRAME."
  (let ((h (face-attribute 'default :height t)))
    (unless (integerp h) (setq h (car (frame-parameter frame 'nidhogg--font-height))))
    (floor (+ (/ (* (/ h 10.0) 96.0 (frame-scale-factor frame) (nidhogg-frame-text-zoom frame)) 72.0) 0.5))))

(defun drgnx-look-scale-ui-test--code-line (frame)
  "The pixel height of a line of code in a buffer shown in FRAME's selected window."
  (let ((w (frame-selected-window frame)) (was (window-buffer (frame-selected-window frame))))
    (with-temp-buffer
      (insert "code\ncode\n")
      (set-window-buffer w (current-buffer))
      (drgnx-test-wait-presented :frame frame)
      (prog1 (with-selected-window w (goto-char (point-min)) (line-pixel-height))
        (set-window-buffer w was)))))

(defun drgnx-look-scale-ui-test--sizes-at (frame s)
  "FRAME's sizes are those of total scale S (display × UI): the pixel rule, the default font, the code line and
the status bar's row."
  (should (< (abs (- (drgnx-pixels-scale frame) s)) 1e-6))
  (should (= (drgnx-look-scale-ui-test--font-px frame) (drgnx-look-scale-ui-test--fresh-px frame)))
  (should (= (drgnx-look-scale-ui-test--code-line frame) (floor (+ (* 21 s) 0.5 1e-9))))
  (should (= (drgnx-statusbar--row-height frame) (floor (+ (* 24 s) 0.5 1e-9)))))

(defmacro drgnx-look-scale-ui-test--with (&rest body)
  "BODY with the density on at comfortable; the UI scale back to 100 % on every root frame afterwards, and the repeat
map a zoom command left waiting for the next key ended (`set-transient-map': no next command runs here)."
  (declare (indent 0))
  `(let ((drgnx-look-density 'comfortable) (pre-was (default-value 'pre-command-hook)))
     (unwind-protect
         (progn (drgnx-look-density-on) ,@body)
       (let ((this-command 'ignore))                     ; as a key outside the map would: each clears itself
         (dolist (fn (default-value 'pre-command-hook)) (unless (memq fn pre-was) (funcall fn))))
       (dolist (f (drgnx-look-scale--roots)) (drgnx-look-scale-apply-frame f 100))
       (drgnx-look-scale--follow)
       (drgnx-look-density-off))))

(drgnx-look-gui-deftest drgnx-ui-look-scale/ui-scale-scales-rows-and-fonts ()
  "Pattern D: at 110 % every size is the display scale × 1.1: the pixel rule, the default font (a fresh open at 96 ×
s × 1.1 dpi), the code line (21 there) and the status bar's row (24); back at 100 % they are the scale's own."
  (skip-unless (and (display-graphic-p) (fboundp 'nidhogg-set-frame-text-zoom)))
  (let* ((f (selected-frame)) (s (float (frame-scale-factor f))) (px100 (drgnx-look-scale-ui-test--font-px f)))
    (drgnx-look-scale-ui-test--with
      (drgnx-look-scale-apply-frame f 110)
      (drgnx-look-scale--follow)
      (drgnx-test-wait-presented)
      (should (= (nidhogg-frame-text-zoom f) 1.1))
      (drgnx-look-scale-ui-test--sizes-at f (* s 1.1))
      (should (> (drgnx-look-scale-ui-test--font-px f) px100))
      (drgnx-look-scale-apply-frame f 100)
      (drgnx-look-scale--follow)
      (drgnx-test-wait-presented)
      (drgnx-look-scale-ui-test--sizes-at f s)
      (should (= (drgnx-look-scale-ui-test--font-px f) px100)))))

(drgnx-look-gui-deftest drgnx-ui-look-scale/applies-at-once ()
  "Pattern D: Zoom In shows the new sizes at the next redisplay, in the same frame (no new frame, no restart); Reset
Zoom gives the old ones back."
  (skip-unless (and (display-graphic-p) (fboundp 'nidhogg-set-frame-text-zoom)))
  (let* ((f (selected-frame)) (s (float (frame-scale-factor f))) (frames (length (frame-list)))
         (px100 (drgnx-look-scale-ui-test--font-px f)))
    ;; the setting itself, not a binding of it: the commands save it (the session's own HOME)
    (should (= drgnx-look-scale 100))
    (drgnx-look-scale-ui-test--with
      (unwind-protect
          (progn
            (call-interactively #'drgnx-look-scale-zoom-in)
            (drgnx-test-wait-presented)
            (should (= drgnx-look-scale 110))
            (should (eq (selected-frame) f))
            (should (= (length (frame-list)) frames))
            (drgnx-look-scale-ui-test--sizes-at f (* s 1.1)))
        (call-interactively #'drgnx-look-scale-zoom-reset)
        (drgnx-test-wait-presented))
      (should (= drgnx-look-scale 100))
      (should (= (drgnx-look-scale-ui-test--font-px f) px100)))))

(drgnx-look-gui-deftest drgnx-ui-look-scale/monitor-override-wins ()
  "Pattern D: with DRGNX_UI_SCALES=\"1.25 2\", an override of 110 % for the frame's monitor (100 % for the other)
gives the frame the monitor's scale × 1.1 (1.375 on the first); clearing it gives the global 100 % back, at once."
  (skip-unless (and (display-graphic-p) (fboundp 'nidhogg-set-frame-text-zoom)
                    (>= (length (display-monitor-attributes-list)) 2)))
  (let* ((f (selected-frame)) (s (float (frame-scale-factor f)))
         (mine (drgnx-look-scale--monitor f))
         (other (seq-find (lambda (n) (and n (not (equal n mine))))
                          (mapcar (lambda (m) (alist-get 'name m)) (display-monitor-attributes-list)))))
    (should mine)
    (drgnx-look-scale-ui-test--with
      (let ((drgnx-look-scale 100)
            (drgnx-look-scale-monitors (list (cons mine 110) (cons other 100))))
        (drgnx-look-scale--refresh-frame f)
        (drgnx-test-wait-presented)
        (should (= (drgnx-pixels-ui-scale f) 1.1))
        (drgnx-look-scale-ui-test--sizes-at f (* s 1.1))
        (setq drgnx-look-scale-monitors (list (cons other 100)))
        (drgnx-look-scale--monitors-changed)
        (drgnx-test-wait-presented)
        (should (= (drgnx-pixels-ui-scale f) 1.0))
        (drgnx-look-scale-ui-test--sizes-at f s)))))

(provide 'look-scale-gui-test)
;;; look-scale-gui-test.el ends here
