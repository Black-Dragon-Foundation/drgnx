;;; look-bars-test.el --- GUI tests: the status bar and the top line in pixels (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det

;; Pattern D: every picture is taken after `drgnx-test-wait-presented'.  A probe segment (or hint) whose text sits on
;; the `region' face paints a block of exactly its own width, so the rows find where the text ends by colour, not by
;; the ink of a letter.  Run at whatever scale the session has (DRGNX_UI_SCALE: 1, 1.25, 2).

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-ui-look-bars--repo               ; the session runs the repository's test/ui
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-look-bars--repo)))
(require 'drgnx)
(require 'drgnx-state)
(dolist (m '("ui/drgnx-face" "ui/drgnx-look-fonts" "ui/drgnx-look-density" "ui/drgnx-statusbar" "ui/drgnx-topline"))
  (load (expand-file-name (concat "modules/" m) drgnx-ui-look-bars--repo) nil t))

(defun drgnx-ui-look-bars--rgb (face)
  "FACE's background as the (R G B) a snapshot pixel holds."
  (mapcar (lambda (c) (round (/ c 257.0))) (color-values (face-background face nil t))))

(defun drgnx-ui-look-bars--span (snap y rgb)
  "The first and the last x (device pixels) on row Y of SNAP whose colour is within 2 per channel of RGB, or nil."
  (let (first last)
    (dotimes (x (nth 0 snap))
      (when (cl-every (lambda (a b) (<= (abs (- a b)) 2)) (cdr (drgnx-uitest-pixel snap x y)) rgb)
        (unless first (setq first x))
        (setq last x)))
    (and first (cons first last))))

(defun drgnx-ui-look-bars--scale () (float (drgnx-uitest-device-scale (selected-frame))))

(defmacro drgnx-ui-look-bars--with-bar (&rest body)
  "BODY in a bare frame with one window on an Emacs Lisp buffer, the status bar on, and a right segment `edge' whose
text is one block on the `region' face.  Everything undone after."
  (declare (indent 0))
  `(let ((state-was (bound-and-true-p drgnx-state-mode)) (bar-was (bound-and-true-p drgnx-statusbar-mode))
         (drgnx-statusbar--segments (make-hash-table :test #'eq)) (drgnx-statusbar--errors nil)
         (drgnx-statusbar-left nil) (drgnx-statusbar-right '(edge)) (drgnx-statusbar-compact '(edge))
         (buf (get-buffer-create "*look-bars*")))
     (drgnx-uitest-bare-frame)
     (delete-other-windows)
     (with-current-buffer buf (emacs-lisp-mode) (erase-buffer) (insert "(a)\n"))
     (switch-to-buffer buf)
     (drgnx-statusbar-define-segment 'edge :fn (lambda () (propertize "WWWW" 'face 'region)))
     (unwind-protect
         (progn
           (cl-letf (((symbol-function 'drgnx-chrome-apply) #'ignore))
             (drgnx-state-mode 1)
             (drgnx-statusbar-mode 1))
           (set-window-parameter (selected-window) 'mode-line-format drgnx-statusbar--host)
           (drgnx-test-wait-presented)
           ,@body)
       (cl-letf (((symbol-function 'drgnx-chrome-apply) #'ignore))
         (drgnx-statusbar-mode (if bar-was 1 -1))
         (drgnx-state-mode (if state-was 1 -1)))
       (set-window-parameter (selected-window) 'mode-line-format nil)
       (kill-buffer buf))))

(defun drgnx-ui-look-bars--right-gap ()
  "Device pixels between the end of the `edge' block and the right edge of the selected window."
  (let* ((w (selected-window)) (s (drgnx-ui-look-bars--scale))
         (edges (window-pixel-edges w))
         (y (round (* s (- (nth 3 edges) (/ (window-mode-line-height w) 2.0) (window-bottom-divider-width w)))))
         (snap (drgnx-uitest-snapshot))
         (span (drgnx-ui-look-bars--span snap y (drgnx-ui-look-bars--rgb 'region))))
    (should span)
    ;; the window's edge is where its mode line ends: a right divider belongs to the gap, not to the bar
    (- (round (* s (- (nth 2 edges) (window-right-divider-width w)))) (1+ (cdr span)))))

(ert-deftest drgnx-ui-look-bars/right-edge-in-pixels ()
  "Pattern D: the rightmost status segment ends within 1 device pixel of the window's right edge minus the panel
padding (12 logical pixels at the comfortable density)."
  (skip-unless (display-graphic-p))
  (drgnx-ui-look-bars--with-bar
    (let ((want (round (* (drgnx-look-density-value 'panel-padding) (drgnx-ui-look-bars--scale)))))
      (should (member (drgnx-ui-look-bars--right-gap) (list (1- want) want (1+ want)))))))

(ert-deftest drgnx-ui-look-bars/right-edge-after-zoom ()
  "Pattern D: after `global-text-scale-adjust' +2 and a change of the code font size, the bar is laid out again:
the segment still ends one padding from the edge."
  (skip-unless (display-graphic-p))
  (drgnx-ui-look-bars--with-bar
    (let ((want (round (* (drgnx-look-density-value 'panel-padding) (drgnx-ui-look-bars--scale))))
          (height (face-attribute 'default :height)))
      ;; `(global-text-scale-adjust 0)' from Lisp recurses in this Emacs, so the height is put back by hand
      (unwind-protect
          (progn
            (global-text-scale-adjust 2)
            (drgnx-test-wait-presented)
            (should (member (drgnx-ui-look-bars--right-gap) (list (1- want) want (1+ want))))
            (set-face-attribute 'default nil :height (+ 20 (face-attribute 'default :height)))
            (run-hooks 'drgnx-look-fonts-applied-hook)
            (drgnx-test-wait-presented)
            (should (member (drgnx-ui-look-bars--right-gap) (list (1- want) want (1+ want)))))
        (set-face-attribute 'default nil :height height)))))

(ert-deftest drgnx-ui-look-bars/hint-centred ()
  "Pattern D: the top line's hint (a block on the `region' face, as wide as a hint) is centred on the frame within
1 device pixel."
  (skip-unless (display-graphic-p))
  (drgnx-uitest-bare-frame)
  (let ((buf (get-buffer-create "*look-bars-top*")))
    (switch-to-buffer buf)
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-topline--hint)
                   (lambda ()
                     (list (drgnx-topline--item 'drgnx-topline-search (propertize "                  " 'face 'region))))))
          (drgnx-topline-setup)
          (drgnx-test-wait-presented)
          (let* ((snap (drgnx-uitest-snapshot))
                 (y (/ (round (* (drgnx-ui-look-bars--scale) (tab-bar-height nil t))) 2))
                 (span (drgnx-ui-look-bars--span snap y (drgnx-ui-look-bars--rgb 'region))))
            (should span)
            (should (<= (abs (- (nth 0 snap) (+ (car span) (cdr span) 1))) 2))))
      (drgnx-topline--off)
      (kill-buffer buf))))

(provide 'look-bars-test)
;;; look-bars-test.el ends here
