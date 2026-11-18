;;; look-explorer-gui-test.el --- GUI tests: the Explorer's rows (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake

;; Pattern D: every picture is taken after `drgnx-test-wait-presented'.  The hover rows move a real pointer (sway's
;; `drgnx-uitest-pointer-set'; the pointer-down rows also mutter's RemoteDesktop pointer), so they skip elsewhere and
;; the real-compositor lane must report them passed.  The Explorer buffer is shown in the selected window of a bare frame, over a temporary folder; its rows come
;; from a real hub (`drgnx-rows-demo-with': a test-hooks build), and every row first checks there are rows to look at.

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)
(require 'drgnx-look-gui-fixture (expand-file-name "../fixtures/look-gui-fixture" (file-name-directory (macroexp-file-name))))

(defconst drgnx-ui-look-explorer--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-look-explorer--repo)))
(load (expand-file-name "test/fixtures/rows-demo-fixture" drgnx-ui-look-explorer--repo) nil t)
(require 'drgnx)
(require 'drgnx-color)
(require 'drgnx-explorer)
(load (expand-file-name "modules/ui/drgnx-look-fonts" drgnx-ui-look-explorer--repo) nil t)
(load (expand-file-name "modules/ui/drgnx-look-density" drgnx-ui-look-explorer--repo) nil t)
(load (expand-file-name "themes/drgnx-theme-gen" drgnx-ui-look-explorer--repo) nil t)
(load (expand-file-name "test/fixtures/ui-hub-fixture" drgnx-ui-look-explorer--repo) nil t)   ; the docked row's hub
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-ui-look-explorer--repo) nil t)
(load (expand-file-name "modules/ui/drgnx-look" drgnx-ui-look-explorer--repo) nil t)
(require 'drgnx-buffers)
(require 'drgnx-state)
(defvar drgnx-look-echo-row)                ; drgnx-look loads drgnx-look-echo above

(defmacro drgnx-ui-look-explorer--with (root &rest body)
  "BODY with the Explorer rooted at ROOT (a temporary folder with a.txt, b.txt and c.txt, all `modified' in git) shown
in the selected window of a bare frame under the dark theme.  Everything undone after."
  (declare (indent 1))
  ;; the folder under a name of its own: `drgnx-rows-demo-with' binds `root' (its hub's) around BODY
  (let ((dir (make-symbol "dir")))
    `(let* ((,dir (file-name-as-directory (make-temp-file "look-explorer" t)))
            (drgnx-explorer--roots nil) (drgnx-explorer-compact-folders nil) (drgnx-explorer--hub-view nil)
            (drgnx-explorer--expanded (make-hash-table :test #'equal)) (drgnx-explorer--window-asker nil))
       (dolist (n '("a.txt" "b.txt" "c.txt")) (write-region "" nil (expand-file-name n ,dir) nil 'silent))
       ;; a repository whose three files are modified: the hub reads git itself and marks the rows from it
       (let ((default-directory ,dir))
         (dolist (args '(("init" "-q") ("add" ".")
                         ("-c" "user.name=t" "-c" "user.email=t@t" "commit" "-q" "--no-gpg-sign" "-m" "t")))
           (should (eq 0 (apply #'call-process "git" nil nil nil args)))))
       (dolist (n '("a.txt" "b.txt" "c.txt")) (write-region "x\n" nil (expand-file-name n ,dir) nil 'silent))
       (drgnx-uitest-bare-frame)
       (delete-other-windows)
       (mapc #'disable-theme custom-enabled-themes)
       (load-theme 'drgnx-dark t)
       (unwind-protect
           (drgnx-rows-demo-with
             (cl-letf (((symbol-function 'drgnx-git-unread-p) (lambda (&rest _) nil))
                       ((symbol-function 'drgnx-git-status) (lambda (&rest _) 'modified)))
               (drgnx-look-density-on)
               (setq drgnx-explorer--roots (list ,dir))
               (let ((b (drgnx-explorer--buffer)))
                 (set-window-buffer (selected-window) b)
                 (with-current-buffer b (drgnx-explorer--render))   ; attaches to the hub's view and subscribes
                 (drgnx-view-env-update drgnx-explorer-hub-view-name)
                 ;; rows to look at, or the row fails here: never a pass over an empty Explorer
                 (condition-case err
                     (drgnx-test-wait (lambda () (with-current-buffer b (string-match-p "c\\.txt" (buffer-string))))
                                      :secs 20 :what "the Explorer's rows from the hub")
                   (ert-test-failed
                    (ert-fail (list "no Explorer rows from the hub" (cadr err)
                                    :text (with-current-buffer b (buffer-substring-no-properties
                                                                  (point-min) (min (point-max) 400)))
                                    :view drgnx-explorer--hub-view :hub-lists (drgnx-explorer--hub-lists-p))))))
               (drgnx-test-wait-presented)
               (let ((,root ,dir)) ,@body)))
         (drgnx-look-density-off)
         (mapc #'disable-theme custom-enabled-themes)
         (when (get-buffer drgnx-explorer-buffer-name) (kill-buffer drgnx-explorer-buffer-name))
         (delete-directory ,dir t)))))

(defun drgnx-ui-look-explorer--row-y (line)
  "The y pixel (in the window's text area) of the middle of the Explorer's LINE-th line.  The row's padding grows
with the scale (the native shell's Lisp pixels are device pixels), so a fixed offset from its top misses the text."
  (with-current-buffer drgnx-explorer-buffer-name
    (goto-char (point-min)) (forward-line (1- line))
    (let ((pos (pos-visible-in-window-p (point) nil t)))
      (+ (cadr pos) (/ (line-pixel-height) 2)))))

(defun drgnx-ui-look-explorer--right-edge (snap line)
  "The x pixel of the right edge of the last mark drawn on the Explorer's LINE-th line: the rightmost pixel in the
row that is not its background, scanning the row from the window's right edge inwards."
  (let* ((s (drgnx-uitest-device-scale (selected-frame))) (e (window-body-pixel-edges))
         (y (round (* s (+ (nth 1 e) (drgnx-ui-look-explorer--row-y line)))))
         (bg (cdr (drgnx-uitest-pixel snap (round (* s (+ (nth 2 e) -2))) y))))
    (cl-loop for x from (round (* s (- (nth 2 e) 2))) downto (round (* s (nth 0 e)))
             unless (equal bg (cdr (drgnx-uitest-pixel snap x y))) return x)))

(defvar drgnx-scrollbar-mode)
(declare-function drgnx-scrollbar-mode "drgnx-ruler" (&optional arg))

(drgnx-look-gui-deftest drgnx-ui-look-explorer/no-row-runs-under-the-scroll-strip ()
  "With the scroll bar's strip in the window's right fringe (12 px more fringe), every row of a narrow Explorer ends
inside the body: the hub fits the rows to the body the strip leaves, so Emacs cuts none and draws no truncation glyph
at its end.  Each row's end (the newline after its tail) is in sight."
  (skip-unless (and (display-graphic-p) (featurep 'glitnir-ruler)))
  (require 'drgnx-ruler)
  (drgnx-ui-look-explorer--with root
    (let* ((w (selected-window)) (other (split-window w (drgnx-px 170) 'left t)))
      (unwind-protect
          (progn
            (drgnx-scrollbar-mode 1)
            (drgnx-ruler--place w)
            (drgnx-test-wait (lambda () (window-parameter w 'drgnx-ruler-fringe)) :secs 5 :what "the strip's fringe")
            (redisplay t)
            (drgnx-view-env-update drgnx-explorer-hub-view-name)
            (let ((rows 0) (cut nil))
              (cl-flet ((measure ()
                          (redisplay t)
                          (setq rows 0 cut nil)
                          (with-current-buffer (window-buffer w)
                            (save-excursion
                              (goto-char (point-min))
                              (while (not (eobp))
                                (let ((bol (point)) (eol (line-end-position)))
                                  (when (and (stringp (ignore-errors (drgnx-view-key-at bol))) (not (invisible-p bol))
                                             (pos-visible-in-window-p bol w))
                                    (setq rows (1+ rows))
                                    (unless (pos-visible-in-window-p eol w)
                                      (push (list (buffer-substring-no-properties bol eol)
                                                  (car (window-text-pixel-size w bol (min (point-max) (1+ eol)))))
                                            cut))))
                                (forward-line 1))))
                          (and (> rows 2) (null cut))))
                ;; the hub's rows for the width the strip leaves: they come once it has the env
                (condition-case nil
                    (drgnx-test-wait #'measure :secs 5 :what "every row inside the body")
                  (ert-test-failed
                   (ert-fail (list "rows cut at the window's edge" cut :rows rows :body (window-body-width w t)
                                   :fringes (window-fringes w)
                                   :env (mapcar (lambda (c) (plist-get (cdr c) :width_px))
                                                (drgnx-view-env--envs drgnx-explorer-hub-view-name)))))))))
        (drgnx-scrollbar-mode -1)
        (when (window-live-p other) (delete-window other))))))

(drgnx-look-gui-deftest drgnx-ui-look-explorer/a-section-shows-whole-rows ()
  "Pattern D: a dock section with another below it ends at a whole row, so no part of a row (a glyph fragment) is
drawn at its foot; the section below takes the pixels left over, and a second fit changes nothing."
  (skip-unless (display-graphic-p))
  (drgnx-ui-look-explorer--with root
    (let* ((top (selected-window))
           (below (split-window top (+ 7 (round (/ (window-pixel-height top) 2))) 'below t)))
      (dolist (w (list top below))                 ; as the dock's sections are
        (set-window-parameter w 'drgnx-role 'dock)
        (set-window-parameter w 'no-other-window t))
      (unwind-protect
          (let ((total (+ (window-pixel-height top) (window-pixel-height below)))
                (row (- (drgnx-ui-look-explorer--row-y 3) (drgnx-ui-look-explorer--row-y 2))))   ; drawn, not the font's
            (drgnx-wb--rows-whole (selected-frame))
            (should (= 0 (mod (window-body-height top t) row)))
            (should (= total (+ (window-pixel-height top) (window-pixel-height below))))
            (let ((h (window-pixel-height top)))
              (drgnx-wb--rows-whole (selected-frame))
              (should (= h (window-pixel-height top)))))
        (delete-window below)
        (set-window-parameter top 'drgnx-role nil)
        (set-window-parameter top 'no-other-window nil)))))

(drgnx-look-gui-deftest drgnx-ui-look-explorer/a-section-header-is-one-colour-to-the-edge ()
  "Pattern D, window-dark.html `.sec': a section's header row is the bar's colour over the right fringe too (the
rows' inset), not a strip of the header line's own colour at its right end."
  (skip-unless (display-graphic-p))
  (drgnx-ui-look-explorer--with root
    (set-window-parameter nil 'header-line-format (drgnx-wb-section-header "Files"))
    (unwind-protect
        (progn
          (drgnx-test-wait-presented)
          (let* ((snap (drgnx-uitest-snapshot)) (s (drgnx-uitest-device-scale (selected-frame)))
                 (e (window-edges nil nil nil t))
                 (y (round (* s (+ (nth 1 e) (/ (window-header-line-height) 2)))))
                 (bar (mapcar (lambda (c) (round (/ c 257.0))) (color-values (face-background 'drgnx-wb-bar nil t))))
                 (near (lambda (x) (cl-every (lambda (p c) (<= (abs (- p c)) 6)) (cdr (drgnx-uitest-pixel snap x y)) bar))))
            (should (> (cadr (window-fringes)) 0))
            (should (funcall near (round (* s (- (nth 2 e) 2)))))                     ; over the right fringe
            (should (funcall near (round (* s (- (nth 2 e) (cadr (window-fringes)) 2)))))))
      (set-window-parameter nil 'header-line-format nil))))

(drgnx-look-gui-deftest drgnx-ui-look-explorer/row-height ()
  "Pattern D: a row of the Explorer is round (26 x scale) device pixels high at the comfortable density."
  (skip-unless (display-graphic-p))
  (drgnx-ui-look-explorer--with root
    (let ((y2 (drgnx-ui-look-explorer--row-y 2)) (y3 (drgnx-ui-look-explorer--row-y 3)))
      (unless (= (round (* 26 (drgnx-pixels-scale))) (- y3 y2))
        (ert-fail (list 'expected (round (* 26 (drgnx-pixels-scale))) 'got (- y3 y2)
                        'line-spacing (buffer-local-value 'line-spacing (get-buffer drgnx-explorer-buffer-name))
                        'info (font-info (face-font 'drgnx-ui-text nil ?x)) 'cell (frame-char-height)))))))

(drgnx-look-gui-deftest drgnx-ui-look-explorer/row-height-follows-the-density ()
  "Pattern D: after a density change, with no restart, a row of the Explorer is round (H x scale) device pixels high,
H the density's `tree-row' (22 compact, 30 roomy)."
  (skip-unless (display-graphic-p))
  (drgnx-ui-look-explorer--with root
    (let ((was drgnx-look-density) (got nil))
      (drgnx-wb-rows-follow)                ; as the Explorer's setup does
      (unwind-protect
          (dolist (d '(compact roomy))
            (setq drgnx-look-density d)
            (run-hooks 'drgnx-look-density-changed-hook)
            (drgnx-test-wait-presented)
            (push (list d (round (* (drgnx-look-density-value 'tree-row) (drgnx-pixels-scale)))
                        (- (drgnx-ui-look-explorer--row-y 3) (drgnx-ui-look-explorer--row-y 2)))
                  got))
        (setq drgnx-look-density was)
        (run-hooks 'drgnx-look-density-changed-hook)
        (remove-hook 'drgnx-look-density-changed-hook #'drgnx-wb-rows-refresh)
        (drgnx-state-unsubscribe 'windows-changed #'drgnx-wb--rows-frame-changed)
        (drgnx-state-unsubscribe 'frame-resized #'drgnx-wb--rows-frame-changed))
      (should (equal (mapcar (lambda (r) (list (nth 0 r) (nth 1 r))) got)
                     (mapcar (lambda (r) (list (nth 0 r) (nth 2 r))) got))))))

(drgnx-look-gui-deftest drgnx-ui-look-explorer/marks-line-up ()
  "Pattern D: the right edges of the git marks of two rows agree within one device pixel."
  (skip-unless (display-graphic-p))
  (drgnx-ui-look-explorer--with root
    (with-current-buffer drgnx-explorer-buffer-name (goto-char (point-min)))   ; the point row shows its ⋯: not these
    ;; the pointer off the rows (a hover row before this one leaves it on a tail): a lit row's tint ends right of its
    ;; mark, and the scan would stop there
    (when (eq t (drgnx-uitest-pointer-set 0 0)) (drgnx-uitest-run nil))
    (drgnx-test-wait-presented)
    (let* ((snap (drgnx-uitest-snapshot))
           (a (drgnx-ui-look-explorer--right-edge snap 3)) (b (drgnx-ui-look-explorer--right-edge snap 4)))
      (should a) (should b)
      (should (<= (abs (- a b)) 1)))))

(drgnx-look-gui-deftest drgnx-ui-look-explorer/hover-reveals-the-ellipsis ()
  "Pattern D (sway): the ⋯ of a row that is not at point is drawn in the row's background until the pointer is on
the row, and again after the pointer leaves."
  (skip-unless (display-graphic-p))
  (skip-unless (eq t (drgnx-uitest-pointer-set 0 0)))
  (drgnx-ui-look-explorer--with root
    (with-current-buffer drgnx-explorer-buffer-name (goto-char (point-min)))
    (drgnx-test-wait-presented)
    (let* ((s (drgnx-uitest-device-scale (selected-frame))) (e (window-body-pixel-edges))
           (y (drgnx-ui-look-explorer--row-y 4))
           (px-y (round (* s (+ (nth 1 e) y)))) (x1 (round (* s (- (nth 2 e) 14)))) (x0 (round (* s (- (nth 2 e) 40))))
           (fg (mapcar (lambda (c) (round (* 255 c))) (drgnx-color-rgb (drgnx-look-token 'fg 'dark))))
           (has-fg (lambda ()
                     (let ((snap (drgnx-uitest-snapshot)))
                       (cl-loop for x from x0 to x1
                                thereis (cl-loop for yy from (- px-y 4) to (+ px-y 4)
                                                 thereis (cl-every (lambda (p c) (<= (abs (- p c)) 24))
                                                                   (cdr (drgnx-uitest-pixel snap x yy)) fg)))))))
      (should-not (funcall has-fg))
      ;; a Lisp pixel is a device pixel; sway takes logical ones
      (should (eq t (drgnx-uitest-pointer-set (round (/ (+ x0 x1) 2.0 (drgnx-pixels-scale)))
                                              (round (/ px-y (drgnx-pixels-scale) 1.0)))))
      (drgnx-uitest-run nil)
      (drgnx-test-wait-presented)
      (skip-unless (cadr (mouse-pixel-position)))
      (should (funcall has-fg)))))

(defun drgnx-ui-look-explorer--pointer-kind ()
  "The real pointer this session can move: `sway' (`drgnx-uitest-pointer-set'), `mutter' (RemoteDesktop,
`drgnx-uitest-pointer-move'), or nil."
  (cond ((eq t (drgnx-uitest-pointer-set 0 0)) 'sway)
        ((drgnx-uitest-pointer-available-p) 'mutter)))

(defmacro drgnx-ui-look-explorer--with-sensors (&rest body)
  "BODY with Nidhogg's mouse sensors on, as the product runs (the Open rows' hover, extra/buffers, turns them on)."
  `(let ((old (symbol-value 'mouse-sensor-enabled)))
     (set 'mouse-sensor-enabled t)
     (unwind-protect (progn ,@body) (set 'mouse-sensor-enabled old))))

(drgnx-look-gui-deftest drgnx-ui-look-explorer/a-pointer-moved-down-the-rows-leaves-one-lit ()
  "Pattern D (sway, mutter; the user's Explorer, 2026-11-16, 8.png: ten rows in a run drawn with the hover's box and
⋯ after the pointer went down the list).  The pointer moves down ten rows one by one; drawn after, only the row
under it has the hover's tint."
  :tags '(:compositor)
  (skip-unless (display-graphic-p))
  (skip-unless (boundp 'mouse-sensor-enabled))
  (let ((kind (drgnx-ui-look-explorer--pointer-kind)))
    (skip-unless kind)
    (drgnx-ui-look-explorer--with-sensors
     (drgnx-ui-look-explorer--with root (drgnx-ui-look-explorer--pointer-down-rows (selected-window) root kind)))))

(drgnx-look-gui-deftest drgnx-ui-look-explorer/a-pointer-swept-down-the-rows-leaves-one-lit ()
  "Pattern D (sway, mutter; 8.png as the user moves): the pointer sweeps down ten rows without a settle between moves."
  :tags '(:compositor)
  (skip-unless (display-graphic-p))
  (skip-unless (boundp 'mouse-sensor-enabled))
  (let ((kind (drgnx-ui-look-explorer--pointer-kind)))
    (skip-unless kind)
    (drgnx-ui-look-explorer--with-sensors
     (drgnx-ui-look-explorer--with root (drgnx-ui-look-explorer--pointer-down-rows (selected-window) root kind 'fast)))))

(drgnx-look-gui-deftest drgnx-ui-look-explorer/a-pointer-moved-down-patched-rows-leaves-one-lit ()
  "Pattern D (sway, mutter; 8.png with the hub's patches): each move also changes a file, so the rows are patched
under the pointer."
  :tags '(:compositor)
  (skip-unless (display-graphic-p))
  (skip-unless (boundp 'mouse-sensor-enabled))
  (let ((kind (drgnx-ui-look-explorer--pointer-kind)))
    (skip-unless kind)
    (drgnx-ui-look-explorer--with-sensors
     (drgnx-ui-look-explorer--with root
       (drgnx-ui-look-explorer--pointer-down-rows (selected-window) root kind nil 'touch)))))

(drgnx-look-gui-deftest drgnx-ui-look-explorer/a-pointer-swept-down-the-docked-explorer-leaves-one-lit ()
  "Pattern D (mutter, the user's compositor; 8.png as the product runs): the Explorer docked in the workbench beside
the Open section, ui/look on (cards, decoration boxes, the look's hover), Open's mouse sensors on through its own
setup; the pointer sweeps down ten rows; only the row under it has the hover's tint."
  :tags '(:compositor)
  (skip-unless (display-graphic-p))
  (skip-unless (boundp 'mouse-sensor-enabled))
  (let ((kind (drgnx-ui-look-explorer--pointer-kind)))
    (skip-unless kind)
    (let* ((root (drgnx-uitest-root-frame))
           (dir (file-name-as-directory (make-temp-file "look-explorer-dock" t)))
           (config (with-selected-frame root (current-window-configuration)))
           (themes custom-enabled-themes) (state-was (bound-and-true-p drgnx-state-mode))
           (sensors (symbol-value 'mouse-sensor-enabled))
           (size (list (frame-pixel-width root) (frame-pixel-height root)))
           (drgnx-wb--sections nil)
           (drgnx-explorer--roots (list dir)) (drgnx-explorer-compact-folders nil)
           (drgnx-explorer--expanded (make-hash-table :test #'equal)) (drgnx-explorer--window-asker nil)
           ;; the classic echo row: with the box, ui/look's setup and teardown would each swap the root frame
           (drgnx-look-echo-row 'classic))
      (dotimes (i 15) (write-region "" nil (expand-file-name (format "m%02d.txt" i) dir) nil 'silent))
      (unwind-protect
          (with-selected-frame root
            (delete-other-windows)
            (mapc #'disable-theme custom-enabled-themes)
            (load-theme 'drgnx-dark t)
            (drgnx-state-mode 1)
            (drgnx-ui-hub-start drgnx-ui-look-explorer--repo)
            (drgnx-test-with-modules '(ui/look)
              (let ((drgnx-modules--current 'look-explorer-dock-row) (drgnx-modules--setup-load load-file-name))
                (drgnx-buffers-setup)
                (drgnx-explorer-setup))
              (drgnx-wb-show-sidebar)
              (drgnx-view-env-update drgnx-explorer-hub-view-name)
              (drgnx-test-wait (lambda () (and (get-buffer drgnx-explorer-buffer-name)
                                               (with-current-buffer drgnx-explorer-buffer-name
                                                 (string-match-p "m14" (buffer-string)))))
                               :secs 20 :what "the docked Explorer's rows from the hub")
              (drgnx-test-wait-presented)
              (let ((w (get-buffer-window drgnx-explorer-buffer-name root)))
                (should w)
                (drgnx-ui-look-explorer--pointer-down-rows w dir kind 'fast))))
        (drgnx-wb-hide-sidebar)
        (dolist (u (alist-get 'look-explorer-dock-row drgnx-modules--stacks)) (funcall (cdr u)))
        (setf (alist-get 'look-explorer-dock-row drgnx-modules--stacks nil t) nil)
        ;; the setups' focus functions (core/workbench's teardown removes them; this row is not that module)
        (remove-function after-focus-change-function #'drgnx-buffers--focus-changed)
        (remove-function after-focus-change-function #'drgnx-explorer--focus-changed)
        (set 'mouse-sensor-enabled sensors)
        (drgnx-ui-hub-stop)
        (drgnx-state-mode (if state-was 1 -1))
        (mapc #'disable-theme custom-enabled-themes)
        (dolist (th (reverse themes)) (enable-theme th))
        (with-selected-frame root (set-window-configuration config))
        (dolist (b (list drgnx-buffers-buffer-name drgnx-explorer-buffer-name)) (when (get-buffer b) (kill-buffer b)))
        (delete-directory dir t)
        ;; the compositor gives the frame its size back after ui/look goes (the next row checks it)
        (drgnx-test-wait (lambda () (equal size (list (frame-pixel-width root) (frame-pixel-height root))))
                         :secs 5 :what "the frame's size from before ui/look")))))

(defun drgnx-ui-look-explorer--pointer-down-rows (w root kind &optional fast touch)
  "Move the KIND pointer (`drgnx-ui-look-explorer--pointer-kind') down rows 3 to 12 of the Explorer in window W
\(rooted at ROOT), then check only row 12 has the hover's tint.  FAST moves without a settle between moves; TOUCH
writes a file each move (the hub patches the rows).  A row is lit when the middle of its empty stretch has the
hover's tint (`drgnx-hover''s background); point stays on the first row, so no row below is selected.  Under mutter
the pointer is placed on the first row, then goes down by a row's height (relative motion, as a hand moves it)."
  (with-current-buffer (window-buffer w)
    (unless (string-match-p "m11" (buffer-string))
      (dotimes (i 12) (write-region "" nil (expand-file-name (format "m%02d.txt" i) root) nil 'silent))))
  (drgnx-test-wait (lambda () (with-current-buffer (window-buffer w) (string-match-p "m11" (buffer-string))))
                   :secs 20 :what "the twelve new rows")
  (with-current-buffer (window-buffer w) (goto-char (point-min)))
  (set-window-point w (with-current-buffer (window-buffer w) (point-min)))
  (drgnx-test-wait-presented)
  (let* ((frame (window-frame w)) (s (drgnx-uitest-device-scale frame)) (e (window-body-pixel-edges w))
         (lys (with-current-buffer (window-buffer w)
                (save-excursion
                  (cl-loop for line from 1 to 12
                           collect (progn (goto-char (point-min)) (forward-line (1- line))
                                          (+ (nth 1 e) (cadr (pos-visible-in-window-p (point) w t))
                                             (/ (line-pixel-height) 2)))))))
         (ys (mapcar (lambda (y) (round (* s y))) lys))
         (mid (round (* s (/ (+ (nth 0 e) (nth 2 e)) 2.0))))         ; right of the short names, left of the tails
         (ltail (- (nth 2 e) 27))
         (logical (/ (frame-scale-factor frame) s))                  ; Lisp pixels per logical one (mutter's motion)
         ;; sway's points are the layout's: the frame's corner is where the compositor put it (kwin: not at 0,0)
         (origin (if (eq kind 'sway) (drgnx-uitest-frame-origin frame) '(0 . 0)))
         (tint (mapcar (lambda (c) (round (* 255 c))) (color-name-to-rgb (face-background 'drgnx-hover frame t))))
         (lit (lambda (snap line)
                (cl-every (lambda (p c) (<= (abs (- p c)) 6)) (cdr (drgnx-uitest-pixel snap mid (nth (1- line) ys))) tint))))
    ;; the pointer starts on the first row (the point row, left out), wherever an earlier row left it
    (pcase kind
      ('sway (should origin)
             (should (eq t (drgnx-uitest-pointer-set (+ (car origin) (round (/ (* s ltail) (drgnx-pixels-scale))))
                                                     (+ (cdr origin) (round (/ (* s (car lys)) (drgnx-pixels-scale)))))))
             (drgnx-uitest-run nil))
      (_ (drgnx-uitest-pointer-move ltail (car lys) frame)))
    (drgnx-test-wait-presented)
    ;; the probe tells: at rest no row below the first has the tint
    (let ((snap (drgnx-uitest-snapshot)))
      (should-not (cl-loop for line from 3 to 12 when (funcall lit snap line) collect line)))
    (cl-loop for line from 3 to 12
             for prev = (car lys) then ly
             for ly = (nth (1- line) lys)
             do (pcase kind
                  ('sway (should (eq t (drgnx-uitest-pointer-set (+ (car origin) (round (/ (* s ltail) (drgnx-pixels-scale))))
                                                                 (+ (cdr origin) (round (/ (* s ly) (drgnx-pixels-scale))))))))
                  (_ (drgnx-uitest--pointer-by 0 (/ (- ly prev) logical))))
             (when touch (write-region (format "%d" line) nil (expand-file-name "m00.txt" root) nil 'silent))
             (cond (fast (redisplay))                                ; the next move comes as soon as it is drawn
                   ((eq kind 'mutter) (drgnx-uitest--pointer-seen frame) (drgnx-test-wait-presented))
                   (t (drgnx-uitest-run nil) (drgnx-test-wait-presented))))
    (if (eq kind 'mutter) (drgnx-uitest--pointer-seen frame) (drgnx-uitest-run nil))   ; mutter's motion is read here
    (drgnx-test-wait-presented)
    (unless (cadr (mouse-pixel-position)) (ert-skip "no pointer position"))
    (let ((snap (drgnx-uitest-snapshot)))
      (should (funcall lit snap 12))                            ; the probe tells: the row under the pointer is lit
      (should-not (cl-loop for line from 3 to 11 when (funcall lit snap line) collect line)))))

(drgnx-look-gui-deftest drgnx-ui-look-explorer/the-pointer-on-a-row-tail-tints-the-whole-row ()
  "Pattern D (sway, LOOK-FIX-OPEN-HOVER-TINT-1): with the pointer on a row's tail (where its ⋯ is), the hover tint
reaches the row's first glyph too: the row and the tail its after-string draws are one lit run (Nidhogg)."
  (skip-unless (display-graphic-p))
  (skip-unless (eq t (drgnx-uitest-pointer-set 0 0)))
  (drgnx-ui-look-explorer--with root
    (with-current-buffer drgnx-explorer-buffer-name (goto-char (point-min)))
    (drgnx-test-wait-presented)
    (let* ((s (drgnx-uitest-device-scale (selected-frame))) (e (window-body-pixel-edges))
           (px-y (round (* s (+ (nth 1 e) (drgnx-ui-look-explorer--row-y 4)))))
           (bol-x (with-current-buffer drgnx-explorer-buffer-name
                    (save-excursion (goto-char (point-min)) (forward-line 3)
                                    (car (posn-x-y (posn-at-point (point) (get-buffer-window)))))))
           (start (round (* s (+ (nth 0 e) bol-x 2))))   ; the row's first glyph, left of its icon
           (at (lambda () (cdr (drgnx-uitest-pixel (drgnx-uitest-snapshot) start px-y))))
           (rest (funcall at))
           (shot (lambda (name)                  ; the look crops, when the session keeps evidence
                   (when-let* ((dir (getenv "DRGNX_UI_EVIDENCE")) ((file-directory-p dir)))
                     (copy-file (plist-get (drgnx-uitest-capture (make-temp-file "explorer-hover" t)) :root)
                                (expand-file-name (format "%s-s%g.png" name (drgnx-pixels-scale)) dir) t)))))
      (funcall shot "explorer-rest")
      (should (eq t (drgnx-uitest-pointer-set (round (/ (- (nth 2 e) 30) (drgnx-pixels-scale) 1.0))   ; logical, as sway
                                              (round (/ px-y (drgnx-pixels-scale) 1.0)))))
      (drgnx-uitest-run nil)
      (drgnx-test-wait-presented)
      (skip-unless (cadr (mouse-pixel-position)))
      (funcall shot "explorer-hovered")
      (should-not (equal rest (funcall at))))))

(drgnx-look-gui-deftest drgnx-ui-look-explorer/the-selected-row-is-one-inset-run ()
  "Pattern D, window-dark.html `.row.sel.focus': the focused selection is one fill from the card's inset to the inset
on the right (the tail does not open a gap, and nothing runs past the row), the fringes either side in the panel's
colour, 6 logical pixels wide; under Glitnir its corners are rounded (the corner pixel is not the fill)."
  (skip-unless (display-graphic-p))
  (drgnx-ui-look-explorer--with root
    (with-current-buffer drgnx-explorer-buffer-name
      (goto-char (point-min)) (forward-line 2) (drgnx-wb-selection-sync))
    (drgnx-test-wait-presented)
    (let* ((snap (drgnx-uitest-snapshot)) (s (drgnx-uitest-device-scale (selected-frame)))
           (e (window-body-pixel-edges))
           (top (with-current-buffer drgnx-explorer-buffer-name
                  (save-excursion (goto-char (point-min)) (forward-line 2)
                                  (cadr (pos-visible-in-window-p (point) nil t)))))
           ;; the row's middle: clear of the rounded corners and the ring (no text so near either edge)
           (y (round (* s (+ (nth 1 e) (drgnx-ui-look-explorer--row-y 3)))))
           (rgb (lambda (token) (mapcar (lambda (c) (round (* 255 c))) (drgnx-color-rgb (drgnx-look-token token 'dark)))))
           (near (lambda (x yy token) (cl-every (lambda (p c) (<= (abs (- p c)) 6))
                                                (cdr (drgnx-uitest-pixel snap x yy)) (funcall rgb token))))
           (left (round (* s (nth 0 e)))) (right (round (* s (nth 2 e)))))
      (should (= (drgnx-px 6) (car (window-fringes))))
      (should (= (drgnx-px 6) (cadr (window-fringes))))
      (should (funcall near (- left 2) y 'panel))                        ; the left fringe
      (should (funcall near (+ left (round (* 3 s))) y 'sel))            ; the fill starts at the inset
      (should (funcall near (- right (round (* 3 s))) y 'sel))           ; and reaches the right inset: no tail gap
      (should (funcall near (+ right 1) y 'panel))                       ; the right fringe
      (when (and (fboundp 'glitnir-active-p) (glitnir-active-p))
        (should-not (funcall near left (round (* s (+ (nth 1 e) top))) 'sel))))))

(defun drgnx-ui-look-explorer--line-of (name)
  "The Explorer's line (1-based) whose row is NAME, or nil."
  (with-current-buffer drgnx-explorer-buffer-name
    (save-excursion
      (goto-char (point-min))
      (when (re-search-forward (concat "[▸▾ ]" (regexp-quote name) "$") nil t) (line-number-at-pos)))))

(defun drgnx-ui-look-explorer--command-on (name command)
  "Put point on NAME's row and run COMMAND there as the command loop would (its post-command hook after)."
  (with-current-buffer drgnx-explorer-buffer-name
    (goto-char (point-min)) (forward-line (1- (drgnx-ui-look-explorer--line-of name)))
    (set-window-point (get-buffer-window (current-buffer)) (point))
    (setq this-command command)
    (when command (call-interactively command))
    (run-hooks 'post-command-hook)))

(drgnx-look-gui-deftest drgnx-ui-look-explorer/an-expanded-folder-keeps-the-selection-on-its-row ()
  "Pattern D (the user's Explorer, 2026-11-16, 11.png: etc/ expanded, then etc/shell/ selected and expanded; the
selected fill's tail was drawn six rows lower, on harness, and stayed).  After the expand only the selected folder's
row is drawn in the selection: in the buffer (no other row's tail is painted selected) and on the screen (no other
row's stretch has the selection's fill)."
  (skip-unless (display-graphic-p))
  (drgnx-ui-look-explorer--with root
    (dolist (f '("etc/images/x.png" "etc/shell/_drgnx" "etc/shell/drgnx.bash" "etc/shell/drgnx.fish"
                 "etc/shell/drgnx.zsh" "etc/drgnx.lock.eld" "harness/h.el" "init/i.el" "keys/k.eld" "modules/m.el"))
      (make-directory (file-name-directory (expand-file-name f root)) t)
      (write-region "" nil (expand-file-name f root) nil 'silent))
    (drgnx-test-wait (lambda () (drgnx-ui-look-explorer--line-of "modules")) :secs 20 :what "the folders' rows")
    (drgnx-test-wait-presented)
    (drgnx-ui-look-explorer--command-on "etc" #'drgnx-explorer-toggle)
    (drgnx-test-wait (lambda () (drgnx-ui-look-explorer--line-of "shell")) :secs 20 :what "etc's rows")
    (drgnx-test-wait-presented)
    (drgnx-ui-look-explorer--command-on "shell" nil)
    (drgnx-test-wait-presented)
    (drgnx-ui-look-explorer--command-on "shell" #'drgnx-explorer-toggle)
    (drgnx-test-wait (lambda () (drgnx-ui-look-explorer--line-of "drgnx.zsh")) :secs 20 :what "shell's rows")
    (drgnx-test-wait-presented)
    (let* ((shell (drgnx-ui-look-explorer--line-of "shell"))
           ;; read before `drgnx-ui-look-explorer--row-y', which moves the (selected) window's point
           (point (with-current-buffer drgnx-explorer-buffer-name
                    (line-number-at-pos (window-point (get-buffer-window (current-buffer))))))
           (painted (with-current-buffer drgnx-explorer-buffer-name
                      (sort (delete-dups
                             (cl-loop for o in (overlays-in (point-min) (point-max))
                                      when (and (overlay-get o 'drgnx-row-tail) (overlay-get o 'drgnx-row-face))
                                      collect (line-number-at-pos (overlay-start o))))
                            #'<)))
           (snap (drgnx-uitest-snapshot)) (s (drgnx-uitest-device-scale (selected-frame)))
           (e (window-body-pixel-edges))
           (mid (round (* s (/ (+ (nth 0 e) (nth 2 e)) 2.0))))
           (sel (mapcar (lambda (c) (round (* 255 c))) (drgnx-color-rgb (drgnx-look-token 'sel 'dark))))
           (lines (with-current-buffer drgnx-explorer-buffer-name (count-lines (point-min) (point-max))))
           (filled (cl-loop for line from 2 to lines
                            for y = (round (* s (+ (nth 1 e) (drgnx-ui-look-explorer--row-y line))))
                            when (cl-every (lambda (p c) (<= (abs (- p c)) 6)) (cdr (drgnx-uitest-pixel snap mid y)) sel)
                            collect line)))
      ;; point (the window's) on shell, and the selection's paint on its row alone
      (should (equal (list :point point
                           :selected (with-current-buffer drgnx-explorer-buffer-name
                                       (and (overlayp drgnx-wb--selected-overlay)
                                            (line-number-at-pos (overlay-start drgnx-wb--selected-overlay))))
                           :painted painted :filled filled)
                     (list :point shell :selected shell :painted (list shell) :filled (list shell)))))))

(drgnx-look-gui-deftest drgnx-ui-look-explorer/the-focused-row-is-ringed ()
  "Pattern D, window-dark.html `.row.sel.focus' (`box-shadow: inset 0 0 0 1px var(--focus)'): with the Explorer
focused, the selected row is ringed in the focus colour on its left, top and right (the right side at the text
area's edge, after the tail), and the ring has no seam where the row's text meets its tail (the fill there, above the
text, is the selection's)."
  (skip-unless (and (display-graphic-p) (fboundp 'glitnir-active-p) (glitnir-active-p)))
  (drgnx-ui-look-explorer--with root
    (with-current-buffer drgnx-explorer-buffer-name
      (goto-char (point-min)) (forward-line 2) (drgnx-wb-selection-sync))
    (drgnx-test-wait-presented)
    (let* ((snap (drgnx-uitest-snapshot)) (s (drgnx-uitest-device-scale (selected-frame)))
           (e (window-body-pixel-edges))
           (row (with-current-buffer drgnx-explorer-buffer-name
                  (save-excursion (goto-char (point-min)) (forward-line 2)
                                  ;; the seam: where the name's last character ends (the newline is after the tail)
                                  (let ((last (posn-at-point (1- (pos-eol)))))
                                    (list (cadr (pos-visible-in-window-p (point) nil t))
                                          (+ (car (posn-x-y last)) (car (posn-object-width-height last))))))))
           (y (round (* s (+ (nth 1 e) (drgnx-ui-look-explorer--row-y 3)))))
           (above (round (* s (+ (nth 1 e) (nth 0 row) 4))))
           (rgb (lambda (token) (mapcar (lambda (c) (round (* 255 c))) (drgnx-color-rgb (drgnx-look-token token 'dark)))))
           (near (lambda (x yy token) (cl-every (lambda (p c) (<= (abs (- p c)) 6))
                                                (cdr (drgnx-uitest-pixel snap x yy)) (funcall rgb token))))
           (left (round (* s (nth 0 e)))) (right (round (* s (nth 2 e))))
           (seam (round (* s (+ (nth 0 e) (nth 1 row)))))
           (top (round (* s (+ (nth 1 e) (nth 0 row)))))
           ;; the ring within 3 logical pixels of an edge (where the snapping puts a 1 px line), inward by DX, DY;
           ;; else the pixels seen, for the failure
           (ringed (lambda (x0 y0 dx dy)
                     (or (cl-loop for i from 0 to (round (* 3 s))
                                  thereis (funcall near (+ x0 (* i dx)) (+ y0 (* i dy)) 'focus))
                         (list x0 y0 (car snap) (cl-loop for i from -4 to (round (* 8 s))
                                                         for x = (+ x0 (* i dx)) for yy = (+ y0 (* i dy))
                                                         when (and (< -1 x (car snap)) (< -1 yy (cadr snap)))
                                                         collect (cdr (drgnx-uitest-pixel snap x yy))))))))
      (should (eq t (funcall ringed left y 1 0)))
      (should (eq t (funcall ringed (1- right) y -1 0)))
      ;; the box's top: the first pixel below the row's top (its spacing is the panel) that is not the panel
      (should (eq t (let ((x (+ seam (round (* 4 s)))))
                      (cl-loop for yy from top to y
                               unless (funcall near x yy 'panel)
                               return (or (funcall near x yy 'focus) (list x yy (cdr (drgnx-uitest-pixel snap x yy))))
                               finally return (list x 'no-box)))))
      (dolist (x (list (1- seam) seam (1+ seam)))
        (should (equal (list 'seam x 'sel) (list 'seam x (and (funcall near x above 'sel) 'sel))))))))

(provide 'look-explorer-gui-test)
;;; look-explorer-gui-test.el ends here
