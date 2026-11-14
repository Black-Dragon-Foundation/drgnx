;;; look-bars-test.el --- GUI tests: the status bar and the top line in pixels (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det

;; Pattern D: every picture is taken after `drgnx-test-wait-presented'.  A probe segment (or hint) whose text sits on
;; the `region' face paints a block of exactly its own width, so the rows find where the text ends by colour, not by
;; the ink of a letter.  Run at whatever scale the session has (DRGNX_UI_SCALE: 1, 1.25, 2).

(require 'ert)
(require 'drgnx-look-gui-fixture (expand-file-name "../fixtures/look-gui-fixture" (file-name-directory (macroexp-file-name))))
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
(require 'drgnx-color)
(load (expand-file-name "themes/drgnx-theme-gen" drgnx-ui-look-bars--repo) nil t)
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

(defun drgnx-ui-look-bars--scale ()
  "Device pixels per Lisp pixel of a snapshot (1 on the native shell, whose frames are in device pixels)."
  (float (drgnx-uitest-device-scale (selected-frame))))

(defun drgnx-ui-look-bars--logical (key)
  "The density size KEY in device pixels: its logical pixels at the frame's scale."
  (round (* (drgnx-look-density-value key) (if (fboundp 'frame-scale-factor) (frame-scale-factor) 1.0))))

(defmacro drgnx-ui-look-bars--with-bar (&rest body)
  "BODY in a bare frame with one window on an Emacs Lisp buffer, the status bar on, and a right segment `edge' whose
text is one block on the `region' face.  Everything undone after: the modes, the default mode line and the window's
parameters (a row that runs the chrome leaves its tab and header lines there; the next look row reuses the window)."
  (declare (indent 0))
  `(let ((state-was (bound-and-true-p drgnx-state-mode)) (bar-was (bound-and-true-p drgnx-statusbar-mode))
         (mode-line-was (default-value 'mode-line-format))   ; the bar's off adds the modal indicator to it
         (window (selected-window)) (params-was (window-parameters))   ; the chrome sets its tab and header lines
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
             (drgnx-state-define-role 'statusbar)     ; as the module's setup does
             (drgnx-statusbar-mode 1))
           (set-window-parameter (selected-window) 'mode-line-format drgnx-statusbar--host)
           (drgnx-test-wait-presented)
           ,@body)
       (cl-letf (((symbol-function 'drgnx-chrome-apply) #'ignore))
         (drgnx-statusbar-mode (if bar-was 1 -1))
         (drgnx-state-mode (if state-was 1 -1)))
       (set-window-parameter (selected-window) 'mode-line-format nil)
       (when (window-live-p window)
         (pcase-dolist (`(,p . ,_) (window-parameters window)) (set-window-parameter window p (alist-get p params-was))))
       (setq-default mode-line-format mode-line-was)
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

(defun drgnx-ui-look-bars--end-room ()
  "Device pixels from the last segment's text to the bar's right edge in the design (window-dark.png): the bar's
padding 8 and the segment's own room 6, in logical pixels."
  (round (* 14 (if (fboundp 'frame-scale-factor) (frame-scale-factor) 1.0))))

(drgnx-look-gui-deftest drgnx-ui-look-bars/right-edge-in-pixels ()
  "Pattern D: the rightmost status segment's text ends within 1 device pixel of the window's right edge minus the
design's room (`drgnx-ui-look-bars--end-room')."
  (skip-unless (display-graphic-p))
  (drgnx-ui-look-bars--with-bar
    (let ((want (drgnx-ui-look-bars--end-room)))
      (should (member (drgnx-ui-look-bars--right-gap) (list (1- want) want (1+ want)))))))

(drgnx-look-gui-deftest drgnx-ui-look-bars/right-edge-after-zoom ()
  "Pattern D: after `global-text-scale-adjust' +2 and a change of the code font size, the bar is laid out again:
the segment still ends the design's room from the edge."
  (skip-unless (display-graphic-p))
  (drgnx-ui-look-bars--with-bar
    (let ((want (drgnx-ui-look-bars--end-room))
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

(defun drgnx-ui-look-bars--token-rgb (name variant)
  "The token NAME of VARIANT as the (R G B) a snapshot pixel holds."
  (mapcar (lambda (c) (round (* 255 c))) (drgnx-color-rgb (drgnx-look-token name variant))))

(drgnx-look-gui-deftest drgnx-ui-look-bars/status-bar-height-and-surface ()
  "Pattern D: the mode line is round (24 x scale) pixels high, and a pixel of it where no text is equals the `gap'
token under each of the three themes."
  (skip-unless (display-graphic-p))
  (drgnx-ui-look-bars--with-bar
    (unwind-protect
        (progn
          (should (= (drgnx-ui-look-bars--logical 'status-bar) (window-mode-line-height)))
          (pcase-dolist (`(,variant . ,theme) '((dark . drgnx-dark) (light . drgnx-light) (hc . drgnx-high-contrast)))
            (mapc #'disable-theme custom-enabled-themes)
            (load-theme theme t)
            (drgnx-test-wait-presented)
            (let* ((w (selected-window)) (s (drgnx-ui-look-bars--scale)) (edges (window-pixel-edges w))
                   (x (round (* s (/ (+ (nth 0 edges) (nth 2 edges)) 2.0))))
                   (y (round (* s (- (nth 3 edges) (/ (window-mode-line-height w) 2.0)))))
                   (top (round (* s (- (nth 3 edges) (window-mode-line-height w) -1))))   ; the box's padding row
                   (snap (drgnx-uitest-snapshot)))
              (dolist (row (list y top))
                (let ((px (cdr (drgnx-uitest-pixel snap x row))))
                  (should (equal (list variant px)
                                 (list variant (cl-mapcar (lambda (a b) (if (<= (abs (- a b)) 2) b a))
                                                          px (drgnx-ui-look-bars--token-rgb 'gap variant))))))))))
      (mapc #'disable-theme custom-enabled-themes))))

(drgnx-look-gui-deftest drgnx-ui-look-bars/status-bar-height-at-every-density ()
  "Pattern D: after a density change, with no restart, the mode line is round (H x scale) pixels high, H the
density's `status-bar' (22, 24, 28): an odd difference between the row and its text included."
  (skip-unless (display-graphic-p))
  (drgnx-ui-look-bars--with-bar
    (let ((was drgnx-look-density) (got nil))
      (unwind-protect
          (dolist (d '(compact roomy comfortable))
            (setq drgnx-look-density d)
            (run-hooks 'drgnx-look-density-changed-hook)
            (drgnx-test-wait-presented)
            (push (list d (drgnx-ui-look-bars--logical 'status-bar) (window-mode-line-height)) got))
        (setq drgnx-look-density was)
        (run-hooks 'drgnx-look-density-changed-hook))
      (should (equal (mapcar (lambda (r) (list (nth 0 r) (nth 1 r))) got)
                     (mapcar (lambda (r) (list (nth 0 r) (nth 2 r))) got))))))

(drgnx-look-gui-deftest drgnx-ui-look-bars/one-bar-across-the-window ()
  "Design §4 (window-dark.png): with two editors side by side there is one bar, the frame's bottom row as wide as the
frame, the density's `status-bar' high; the editors have no mode line; the bar shows the `edge' block of the editor
you are in, 14 logical pixels from the frame's right edge."
  (skip-unless (display-graphic-p))
  (drgnx-ui-look-bars--with-bar
    (let ((drgnx-statusbar-place 'frame) (editor (selected-window)))
      (set-window-parameter editor 'mode-line-format nil)
      (unwind-protect
          (progn
            (drgnx-statusbar--frame-apply)
            (split-window editor nil 'right)
            (drgnx-statusbar--frame-ensure (selected-frame))
            (drgnx-chrome-apply (selected-frame))          ; the editors' mode line, as the mode's switch does
            (drgnx-test-wait-presented)
            (let* ((bars (seq-filter (lambda (w) (eq (window-parameter w 'drgnx-role) 'statusbar)) (window-list nil 'nomini)))
                   (bar (car bars)) (s (drgnx-ui-look-bars--scale)))
              (should (= 1 (length bars)))
              (should (eq (window-parent bar) (frame-root-window)))
              (should-not (window-next-sibling bar))
              (should (= (window-pixel-width bar) (window-pixel-width (frame-root-window))))
              (should (= (drgnx-ui-look-bars--logical 'status-bar) (window-mode-line-height bar)))
              (should (= 0 (window-mode-line-height editor)))
              (let* ((edges (window-pixel-edges bar))
                     (y (round (* s (- (nth 3 edges) (/ (window-mode-line-height bar) 2.0)))))
                     (span (drgnx-ui-look-bars--span (drgnx-uitest-snapshot) y (drgnx-ui-look-bars--rgb 'region)))
                     (want (drgnx-ui-look-bars--end-room)))
                (should span)
                (should (member (- (round (* s (nth 2 edges))) (1+ (cdr span))) (list (1- want) want (1+ want)))))))
        (let ((drgnx-statusbar-place 'editors)) (drgnx-statusbar--frame-apply) (drgnx-chrome-apply (selected-frame)))
        (delete-other-windows editor)))))

(drgnx-look-gui-deftest drgnx-ui-look-bars/double-click-on-the-title-row-is-bound ()
  "Pattern D: with the top line on, a double click in the tab bar finds Maximize or Restore Window in the keymap Emacs
builds for the bar (the harness's synthetic clicks do not reach the tab bar's own prefix, so the binding is read, not
clicked)."
  (skip-unless (display-graphic-p))
  (drgnx-uitest-bare-frame)
  (let ((buf (get-buffer-create "*look-bars-dbl*")))
    (switch-to-buffer buf)
    (unwind-protect
        (progn
          (drgnx-topline-setup)
          (drgnx-test-wait-presented)
          (should (eq 'tab-bar (posn-area (drgnx-uitest-posn (/ (frame-pixel-width) 2) (/ (tab-bar-height nil t) 2)))))
          (should (eq 'drgnx-topline-toggle-maximized (key-binding [tab-bar double-mouse-1])))
          (should (eq 'drgnx-topline-toggle-maximized (lookup-key (tab-bar-make-keymap) [double-mouse-1]))))
      (drgnx-topline--off)
      (kill-buffer buf))))

(drgnx-look-gui-deftest drgnx-ui-look-bars/hint-centred ()
  "Pattern D: the title row's search box (a block on the `region' face, as wide as the box) is drawn where the row's
layout puts it (after the left items and the first gap, within 1 device pixel), and the same with the design's chips
shown as without them: it never moves when a chip comes or goes."
  (skip-unless (display-graphic-p))
  (drgnx-uitest-bare-frame)
  (let ((buf (get-buffer-create "*look-bars-top*")) (spans nil))
    (switch-to-buffer buf)
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-topline--search-box)
                   (lambda ()
                     (drgnx-topline--item 'drgnx-topline-search (propertize "                  " 'face 'region)))))
          (drgnx-topline-setup)
          (dolist (counts '((1 . 2) (0 . 0)))
            (cl-letf (((symbol-function 'drgnx-topline--attention-count) (lambda () (car counts)))
                      ((symbol-function 'drgnx-topline--agents-count) (lambda () (cdr counts))))
              (drgnx-memo-forget 'topline)
              (force-mode-line-update t)
              (drgnx-test-wait-presented)
              (let* ((snap (drgnx-uitest-snapshot)) (s (drgnx-ui-look-bars--scale))
                     (y (/ (round (* s (tab-bar-height nil t))) 2))
                     (span (drgnx-ui-look-bars--span snap y (drgnx-ui-look-bars--rgb 'region)))
                     (items (drgnx-topline--line)) (measure (drgnx-statusbar--measure-fn nil 'tab-bar))
                     (before (seq-take items (cl-position 'drgnx-topline-search (mapcar #'car items)))))
                (should span)
                (should (<= (abs (- (car span) (round (* s (drgnx-topline--width before measure))))) 1))
                (push span spans))))
          (should (<= (abs (- (car (nth 0 spans)) (car (nth 1 spans)))) 1)))
      (drgnx-topline--off)
      (kill-buffer buf))))

(drgnx-look-gui-deftest drgnx-ui-look-bars/title-row-is-38-px-on-the-gap ()
  "Design §4: the title row is the `title-row' density's height (38 px at the default) and, where nothing is drawn,
the `gap' token's colour."
  (skip-unless (display-graphic-p))
  (drgnx-uitest-bare-frame)
  (let ((buf (get-buffer-create "*look-bars-title*")))
    (switch-to-buffer buf)
    (unwind-protect
        (progn
          (mapc #'disable-theme custom-enabled-themes)
          (load-theme 'drgnx-dark t)
          (drgnx-topline-setup)
          (drgnx-test-wait-presented)
          (should (= (drgnx-ui-look-bars--logical 'title-row) (tab-bar-height nil t)))
          (let* ((s (drgnx-ui-look-bars--scale)) (snap (drgnx-uitest-snapshot))
                 (px (cdr (drgnx-uitest-pixel snap (round (* s 300)) (round (* s 3))))))
            (should (cl-every (lambda (a b) (<= (abs (- a b)) 2)) px (drgnx-ui-look-bars--token-rgb 'gap 'dark)))))
      (drgnx-topline--off)
      (mapc #'disable-theme custom-enabled-themes)
      (kill-buffer buf))))

(drgnx-look-gui-deftest drgnx-ui-look-bars/title-row-controls-take-a-real-click ()
  "Design §4: the title row's window controls are buttons.  A real pointer (mutter's virtual one, through the
compositor and the shell as a mouse's motion and buttons go; `drgnx-uitest-pointer-click') on Minimise runs its
registry command, Minimize Window.  On Nidhogg's native shell this needs its line from 0f89eff4 (the tab bar takes a
real press with its item: NH-TITLE-CLICK-1); the .6 tarball predates it."
  (skip-unless (display-graphic-p))
  (skip-unless (drgnx-uitest-pointer-available-p))
  (drgnx-uitest-bare-frame)
  (let ((buf (get-buffer-create "*look-bars-controls*")) (frame (selected-frame)) (ran nil)
        (was drgnx-face-title-bar))
    (switch-to-buffer buf)
    (unwind-protect
        (cl-letf (((symbol-function 'iconify-frame) (lambda (&optional _f) (interactive) (setq ran t)))
                  ;; as on GNOME (the session's mutter names no desktop)
                  ((symbol-function 'drgnx-face--drawn-wanted-p) (lambda (_f) (eq drgnx-face-title-bar 'drgnx))))
          ;; drgnx draws the title: the frame is undecorated, so no system title bar takes the press
          (setq drgnx-face-title-bar 'drgnx)
          (drgnx-face--apply-title frame)
          (should (drgnx-face-drawn-title-p frame))
          (drgnx-topline-setup)
          (should (eq 'iconify-frame (drgnx-cmd-command (drgnx-commands-get 'title-row-minimize))))
          (drgnx-test-wait-presented)
          (let* ((items (drgnx-topline--line)) (keys (mapcar #'car items))
                 (measure (drgnx-statusbar--measure-fn nil 'tab-bar))
                 (before (drgnx-topline--width (seq-take items (cl-position 'drgnx-topline-minimize keys)) measure))
                 (x (+ before (round (* (drgnx-pixels-scale frame) (+ 4 13)))))   ; the 4 px gap, then the middle
                 (y (/ (tab-bar-height frame t) 2)))
            (let ((got (drgnx-uitest-pointer-click x y (lambda () ran))))
              (ert-info ((format "keys %S" drgnx-uitest-pointer-keys))
                (should (eq t got))))))
      (setq drgnx-face-title-bar was)
      (cl-letf (((symbol-function 'drgnx-face--drawn-wanted-p) #'ignore)) (drgnx-face--apply-title frame))
      (drgnx-topline--off)
      (kill-buffer buf))))

(drgnx-look-gui-deftest drgnx-ui-look-bars/title-row-images-are-whole-pixels ()
  "The title row's images (the mark, the branch chip, the search box, the window controls) take as many of the frame's
pixels as the row counts for them, at any scale: at 1.25 a 26 px control is 33 wide, not 32.5 drawn and 32 counted,
so the row never runs past the frame and its last control never wraps to a second line (the row stays one
`title-row' high)."
  (skip-unless (display-graphic-p))
  (drgnx-uitest-bare-frame)
  (let ((buf (get-buffer-create "*look-bars-whole*")) (frame (selected-frame)) (was drgnx-face-title-bar))
    (switch-to-buffer buf)
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-face--drawn-wanted-p) (lambda (_f) (eq drgnx-face-title-bar 'drgnx))))
          (setq drgnx-face-title-bar 'drgnx)
          (drgnx-face--apply-title frame)
          (drgnx-topline-setup)
          (drgnx-test-wait-presented)
          (let (wrong)
            (dolist (i (drgnx-topline--line))
              (let* ((s (nth 2 i)) (known (drgnx-topline--known-px s)))
                (when (and known (/= known (string-pixel-width s)))
                  (push (list (car i) :counted known :drawn (string-pixel-width s)) wrong))))
            (should-not wrong))
          (should (= (tab-bar-height frame t) (drgnx-px (drgnx-look-density-value 'title-row) frame))))
      (setq drgnx-face-title-bar was)
      (cl-letf (((symbol-function 'drgnx-face--drawn-wanted-p) #'ignore)) (drgnx-face--apply-title frame))
      (drgnx-topline--off)
      (kill-buffer buf))))

(drgnx-look-gui-deftest drgnx-ui-look-bars/title-row-control-hover-is-a-circle ()
  "Design §4 (`.wctl span:hover'): a real pointer (mutter's virtual one) resting on Close lights a 26 px circle in the
hover colour: about 26 px across through its middle, and a chord of about 14 px 11 px above it (a square would be 26)."
  (skip-unless (display-graphic-p))
  (skip-unless (drgnx-uitest-pointer-available-p))
  (drgnx-uitest-bare-frame)
  (let ((buf (get-buffer-create "*look-bars-hover*")) (frame (selected-frame)) (was drgnx-face-title-bar))
    (switch-to-buffer buf)
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-face--drawn-wanted-p) (lambda (_f) (eq drgnx-face-title-bar 'drgnx))))
          (setq drgnx-face-title-bar 'drgnx)
          (drgnx-face--apply-title frame)
          (drgnx-topline-setup)
          (drgnx-test-wait-presented)
          (let* ((items (drgnx-topline--line)) (keys (mapcar #'car items))
                 (measure (drgnx-statusbar--measure-fn nil 'tab-bar))
                 (sc (drgnx-pixels-scale frame))
                 (before (drgnx-topline--width (seq-take items (cl-position 'drgnx-topline-close keys)) measure))
                 (x (+ before (round (* sc (+ 4 13)))))
                 (y (/ (tab-bar-height frame t) 2))
                 (hover (drgnx-ui-look-bars--rgb 'drgnx-topline-hover)))
            (should-not (equal hover (drgnx-ui-look-bars--rgb 'drgnx-topline)))
            (drgnx-uitest-pointer-move x y)
            (drgnx-test-wait-presented)
            (let* ((snap (drgnx-uitest-snapshot)) (s (drgnx-ui-look-bars--scale))
                   (mid (drgnx-ui-look-bars--span snap (round (* s y)) hover))
                   (chord (drgnx-ui-look-bars--span snap (round (* s (- y (* 11 sc)))) hover))
                   (px (lambda (span) (and span (- (cdr span) (car span) -1)))))
              (ert-info ((format "spans: middle %S, chord %S" mid chord))
                (should (and mid (<= (* 22 sc s) (funcall px mid) (* 27 sc s))))
                (should (and chord (< (funcall px chord) (* 18 sc s))))))))
      (setq drgnx-face-title-bar was)
      (cl-letf (((symbol-function 'drgnx-face--drawn-wanted-p) #'ignore)) (drgnx-face--apply-title frame))
      (drgnx-topline--off)
      (kill-buffer buf))))

(provide 'look-bars-test)
;;; look-bars-test.el ends here
