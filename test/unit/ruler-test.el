;;; ruler-test.el --- batch tests: the overview ruler hands Nidhogg its strip and marks -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; Batch Emacs has a terminal frame, where there is no ruler and no fringe: Nidhogg's side is stubbed (the feature, the
;; fringes as `set-window-fringes' last set them).  What Glitnir draws from the parameter is Nidhogg's own GUI test
;; (glitnir-gui/the-ruler-marks-the-buffer-by-position); drgnx's look scenes show it against the mockup.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-ruler)

(defvar ruler-test--marks nil "What the test's producer hands the ruler.")

(defun ruler-test--source () ruler-test--marks)

(defmacro ruler-test--with (&rest body)
  "BODY in a buffer of 100 lines shown in the selected window, Nidhogg's ruler stubbed: FRINGES is the window's
\(LEFT RIGHT), SETS counts the sets of `glitnir-ruler'; all taken back after."
  (declare (indent 0))
  `(let* ((b (generate-new-buffer " ruler")) (w (selected-window)) (was (window-buffer w))
          (ruler-test--marks nil) (fringes (list 8 8)) (sets 0) (fringe-sets 0)
          (swp (symbol-function 'set-window-parameter)))
     (cl-letf (((symbol-function 'drgnx-ruler-available-p) (lambda () t))
               ((symbol-function 'window-fringes) (lambda (&optional _) (list (car fringes) (cadr fringes) nil nil)))
               ((symbol-function 'set-window-fringes)
                (lambda (_w l r &rest _) (setq fringes (list l r) fringe-sets (1+ fringe-sets))))
               ((symbol-function 'set-window-parameter)
                (lambda (win p v) (when (eq p 'glitnir-ruler) (setq sets (1+ sets))) (funcall swp win p v))))
       (unwind-protect
           (progn
             (with-current-buffer b (dotimes (i 100) (insert (format "line %d\n" (1+ i)))) (goto-char (point-min)))
             (set-window-buffer w b)
             (with-current-buffer b ,@body))
         (with-current-buffer b (drgnx-ruler-mode -1))
         (set-window-buffer w was)
         (set-window-parameter w 'glitnir-ruler nil)
         (set-window-parameter w 'drgnx-ruler-fringe nil)
         (kill-buffer b)))))

(defun ruler-test--pos (line) (save-excursion (goto-char (point-min)) (forward-line (1- line)) (point)))

(ert-deftest drgnx-ruler/hands-nidhogg-the-strip-and-marks ()
  "The producers' marks become the window's `glitnir-ruler': the strip 12 px in the right fringe, beside the text
(the fringe's own width outside it), each mark's lane in pixels and its face, the highest priority drawn last; the
fringe is widened once, and the parameter set only when the marks change."
  (ruler-test--with
    (setq ruler-test--marks (list (list (ruler-test--pos 50) 'middle 'error 2) (list (ruler-test--pos 10) 'full 'success 3)
                                  (list (ruler-test--pos 50) 'left 'warning 1)))
    (drgnx-ruler-source 'test #'ruler-test--source)
    (should drgnx-ruler-mode)
    (let ((spec (window-parameter (selected-window) 'glitnir-ruler)))
      (should (equal (plist-get spec :width) (drgnx-px 12)))
      (should (equal (plist-get spec :right) 8))
      ;; the mockup's lanes (minimap.css): left 1–4, middle 4–8, full 0–12; marks 2 px, radius 1
      (should (equal (plist-get spec :marks)
                     (list (list (ruler-test--pos 50) (drgnx-px 1) (drgnx-px 4) 'warning (drgnx-px 2) (drgnx-px 1))
                           (list (ruler-test--pos 50) (drgnx-px 4) (drgnx-px 8) 'error (drgnx-px 2) (drgnx-px 1))
                           (list (ruler-test--pos 10) 0 (drgnx-px 12) 'success (drgnx-px 2) (drgnx-px 1)))))
      ;; the thumb: inset 3, radius 3, the foreground at 26 %, hidden while the text fits
      (should (equal (list (plist-get spec :thumb-inset) (plist-get spec :radius) (plist-get spec :band)
                           (plist-get spec :hide-short))
                     (list (drgnx-px 3) (drgnx-px 3) '(drgnx-ruler-view . 0.26) t))))
    (should (equal fringes (list 8 (+ 8 (drgnx-px 12)))))
    (should (equal (list sets fringe-sets) '(1 1)))
    ;; the same marks again: nothing is set; new marks: the parameter only
    (drgnx-ruler-refresh)
    (should (equal (list sets fringe-sets) '(1 1)))
    (setq ruler-test--marks (cdr ruler-test--marks))
    (drgnx-ruler-refresh)
    (should (equal (list sets fringe-sets) '(2 1)))
    ;; no producer left: the ruler goes, and the fringe has its own width back
    (drgnx-ruler-source 'test nil)
    (should-not drgnx-ruler-mode)
    (should-not (window-parameter (selected-window) 'glitnir-ruler))
    (should (equal fringes '(8 8)))))

(declare-function drgnx-theme--faces "drgnx-theme-gen" (variant tok))
(declare-function drgnx-look-token "drgnx-theme-gen" (name &optional variant))

(ert-deftest drgnx-ruler/the-thumb-is-the-text-colour-in-every-theme ()
  "The thumb is `drgnx-ruler-view's foreground at 26 %, and that foreground is the text colour (the look's `.sbar
.thumb', --fg at 26 %), in every variant: a fill token (`hover', next to the surfaces' own colours) at 26 % left the
thumb a step or two from the surface under it."
  (require 'drgnx-theme-gen)
  (dolist (variant '(dark light hc))
    (let ((faces (drgnx-theme--faces variant (lambda (name) (drgnx-look-token name variant)))))
      (should (equal (plist-get (alist-get 'drgnx-ruler-view faces) :foreground)
                     (plist-get (alist-get 'default faces) :foreground))))))

(ert-deftest drgnx-ruler/another-buffer-in-the-window-has-none ()
  "A window that shows another buffer loses the strip and its fringe width; showing the buffer again brings them."
  (ruler-test--with
    (setq ruler-test--marks (list (list 1 'middle 'error 1)))
    (drgnx-ruler-source 'test #'ruler-test--source)
    (let ((other (get-buffer-create " ruler-other")) (w (selected-window)))
      (unwind-protect
          (progn
            (set-window-buffer w other)
            (drgnx-ruler--buffer-changed w)
            (should-not (window-parameter w 'glitnir-ruler))
            (should (equal fringes '(8 8)))
            (set-window-buffer w (current-buffer))
            (drgnx-ruler--buffer-changed w)
            (should (window-parameter w 'glitnir-ruler))
            (should (equal fringes (list 8 (+ 8 (drgnx-px 12))))))
        (kill-buffer other)))))

(ert-deftest drgnx-ruler/none-without-nidhogg ()
  "Without Nidhogg's ruler (or in a terminal) the mode keeps its marks and sets nothing on the window."
  (ruler-test--with
    (cl-letf (((symbol-function 'drgnx-ruler-available-p) #'ignore))
      (setq ruler-test--marks (list (list 1 'middle 'error 1)))
      (drgnx-ruler-source 'test #'ruler-test--source)
      (should drgnx-ruler-mode)
      (should-not (window-parameter (selected-window) 'glitnir-ruler))
      (should (equal (list sets fringe-sets) '(0 0))))))

(ert-deftest drgnx-ruler/a-click-goes-there ()
  "A click on the strip shows the place Nidhogg reads from its y (`glitnir-ruler-position'), centred."
  (ruler-test--with
    (setq ruler-test--marks (list (list 1 'middle 'error 1)))
    (drgnx-ruler-source 'test #'ruler-test--source)
    (cl-letf (((symbol-function 'glitnir-ruler-position) (lambda (_posn) (ruler-test--pos 60)))
              ((symbol-function 'recenter) #'ignore))
      (drgnx-ruler-click (list 'mouse-1 (list (selected-window) 'right-fringe '(0 . 0) 0)))
      (should (= (line-number-at-pos (window-point)) 60)))))

(ert-deftest drgnx-ruler/the-edge-drag-keeps-its-place ()
  "The card edge's drag takes the outer half of the fringe's own width, not of the fringe the strip widened: a press
there drags the gap, a press further in (the strip's side, its click bound) does not."
  (ruler-test--with
    (setq ruler-test--marks (list (list 1 'middle 'error 1)))
    (drgnx-ruler-source 'test #'ruler-test--source)
    (let ((w (selected-window)) (dragged nil))
      (load (expand-file-name "modules/ui/drgnx-look" drgnx-dir) nil t)
      (cl-letf (((symbol-function 'window-pixel-edges) (lambda (&optional _) '(0 0 800 600)))
                ((symbol-function 'window-right-divider-width) (lambda (&optional _) 0))
                ((symbol-function 'window-at-x-y) (lambda (&rest _) w))
                ((symbol-function 'mouse-drag-line) (lambda (&rest _) (setq dragged t))))
        (let ((press (lambda (x) (setq dragged nil)
                       (drgnx-look-edge-drag (list 'down-mouse-1 (list w 'right-fringe (cons x 10) 0)))
                       dragged)))
          (should (funcall press 797))          ; the outer half of the fringe's own 8 px
          (should-not (funcall press 794)))))))  ; inside: the widened fringe's half would have taken it

;;;; The scroll bar on every surface

(defmacro ruler-test--with-scrollbar (&rest body)
  "BODY as `ruler-test--with', with the scroll bar on (`drgnx-scrollbar-mode') and no producer; off after."
  (declare (indent 0))
  `(ruler-test--with
     (unwind-protect (progn (drgnx-scrollbar-mode 1) ,@body)
       (drgnx-scrollbar-mode -1)
       (dolist (p '(drgnx-role drgnx-popup drgnx-minimap-exclude window-side))
         (set-window-parameter (selected-window) p nil)))))

(ert-deftest drgnx-scrollbar/every-surface-kind-gets-a-strip ()
  "With the scroll bar on, a window of every scrollable kind gets the strip though its buffer has no marks: an editor
group, a docked pane (the Explorer's, the panel's, the right dock's), a popup lane, each with `:hide-short' so C hides
it while the content fits; the fringe is widened once."
  (ruler-test--with-scrollbar
    (let ((w (selected-window)))
      (should-not drgnx-ruler-mode)
      (should (plist-get (window-parameter w 'glitnir-ruler) :hide-short))
      (should (null (plist-get (window-parameter w 'glitnir-ruler) :marks)))
      (should (equal fringes (list 8 (+ 8 (drgnx-px 12)))))
      (dolist (params '(((drgnx-role . dock)) ((drgnx-role . panel)) ((drgnx-role . right)) ((drgnx-popup . t))))
        (pcase-dolist (`(,p . ,v) params) (set-window-parameter w p v))
        (drgnx-ruler--place w)
        (should (window-parameter w 'glitnir-ruler))
        (pcase-dolist (`(,p . ,_) params) (set-window-parameter w p nil)))
      (should (= fringe-sets 1)))))

(ert-deftest drgnx-scrollbar/chrome-windows-get-no-strip ()
  "Chrome never gets the strip or a widened fringe: the status bar (a `drgnx-role' that is not a pane), a package's
side window, and a window marked `drgnx-minimap-exclude' (the peek card's, the sticky header's)."
  (ruler-test--with-scrollbar
    (let ((w (selected-window)))
      (dolist (params '(((drgnx-role . statusbar)) ((window-side . bottom)) ((drgnx-minimap-exclude . t))))
        (pcase-dolist (`(,p . ,v) params) (set-window-parameter w p v))
        (drgnx-ruler--place w)
        (should-not (window-parameter w 'glitnir-ruler))
        (should (equal fringes '(8 8)))
        (pcase-dolist (`(,p . ,_) params) (set-window-parameter w p nil))
        (drgnx-ruler--place w)
        (should (window-parameter w 'glitnir-ruler))))))

(ert-deftest drgnx-scrollbar/off-takes-every-strip ()
  "The scroll bar off: windows without marks lose the strip and get their fringe back; a buffer with a producer's
marks keeps its strip (the debugger's breakpoints show either way)."
  (ruler-test--with-scrollbar
    (drgnx-scrollbar-mode -1)
    (should-not (window-parameter (selected-window) 'glitnir-ruler))
    (should (equal fringes '(8 8)))
    (setq ruler-test--marks (list (list 1 'middle 'error 1)))
    (drgnx-ruler-source 'test #'ruler-test--source)
    (should (window-parameter (selected-window) 'glitnir-ruler))))

(ert-deftest drgnx-scrollbar/sja-thumb-follows-the-view-window ()
  "A buffer holding a window of a view's rows (`drgnx-ruler-span-function') gives C the span, so the thumb stands for
the whole view; when the hub moves the window, `drgnx-ruler-update' sets the new span once, and nothing when it did
not move."
  (ruler-test--with-scrollbar
    (let* ((span (list 400 100 2000)))
      (setq-local drgnx-ruler-span-function (lambda () span))
      (drgnx-ruler-update)
      (should (equal (plist-get (window-parameter (selected-window) 'glitnir-ruler) :span) '(400 100 2000)))
      (let ((before sets))
        (drgnx-ruler-update)
        (should (= sets before))
        (setq span (list 900 100 2000))
        (drgnx-ruler-update)
        (should (= sets (1+ before)))
        (should (equal (plist-get (window-parameter (selected-window) 'glitnir-ruler) :span) '(900 100 2000)))))))

(ert-deftest drgnx-scrollbar/a-press-outside-the-held-rows-asks-for-them ()
  "A press on the strip of a view with a span, at a fraction outside the rows held, goes to
`drgnx-ruler-goto-fraction-function' with that fraction; inside them, to the place by the buffer's characters."
  (ruler-test--with-scrollbar
    (let ((asked nil) (w (selected-window)))
      (setq-local drgnx-ruler-span-function (lambda () (list 400 100 1000)))
      (setq-local drgnx-ruler-goto-fraction-function (lambda (win frac) (setq asked (list win frac))))
      (cl-letf (((symbol-function 'glitnir-ruler-fraction) (lambda (_) 0.9))
                ((symbol-function 'glitnir-ruler-position) (lambda (_) (ruler-test--pos 50)))
                ((symbol-function 'recenter) #'ignore))
        (drgnx-ruler--goto w (list w 'right-fringe '(0 . 0) 0))
        (should (equal asked (list w 0.9)))
        (setq asked nil)
        (cl-letf (((symbol-function 'glitnir-ruler-fraction) (lambda (_) 0.45)))
          (drgnx-ruler--goto w (list w 'right-fringe '(0 . 0) 0)))
        (should-not asked)
        (should (= (line-number-at-pos (window-point w)) 50))))))

(ert-deftest drgnx-scrollbar/scale-and-theme-apply-at-once ()
  "A scale change (the density hook's refresh) gives every strip its new widths at once, the fringe widened by the
new width over its own; the thumb names a face, so a theme change needs nothing here (Glitnir resolves it again)."
  (ruler-test--with-scrollbar
    (let ((w (selected-window)) (px (symbol-function 'drgnx-px)))
      (cl-letf (((symbol-function 'drgnx-px) (lambda (n &rest _) (* 2 (funcall px n)))))
        (drgnx-scrollbar-refresh-all)
        (should (equal (plist-get (window-parameter w 'glitnir-ruler) :width) (* 2 (funcall px 12))))
        (should (equal fringes (list 8 (+ 8 (* 2 (funcall px 12))))))
        (should (symbolp (car (plist-get (window-parameter w 'glitnir-ruler) :band))))))))

;;;; The minimap (modules/editor/drgnx-minimap.el)

(defvar drgnx-hub--events)

(defmacro ruler-test--with-minimap (&rest body)
  "BODY as `ruler-test--with-scrollbar', the buffer visiting a file, with the minimap's placement hooked and the
hub's connection taken as up: CALLS holds the hub calls made, (METHOD PARAMS) each, oldest first."
  (declare (indent 0))
  `(let ((calls nil) (file (make-temp-file "drgnx-minimap" nil ".el"))
         ;; the hub's connection as the calls name it (the hub client is not loaded here: nothing loads it inside)
         (drgnx-hub--events 'ruler-test-hub))
     (load (expand-file-name "modules/editor/drgnx-minimap" drgnx-dir) nil t)
     (cl-letf (((symbol-function 'drgnx-minimap--hub-p) (lambda () t))
               ((symbol-function 'drgnx-hub--call-on)
                (lambda (_proc method params &rest _) (setq calls (append calls (list (list method params)))))))
       (add-hook 'drgnx-ruler-place-functions #'drgnx-minimap--place)
       (unwind-protect
           (ruler-test--with-scrollbar
             (setq buffer-file-name file)
             (goto-char (point-max))
             (insert ";;;; Commands\n")
             (set-buffer-modified-p nil)
             (drgnx-ruler--place (selected-window))
             ,@body)
         (remove-hook 'drgnx-ruler-place-functions #'drgnx-minimap--place)
         (delete-file file)))))

(ert-deftest drgnx-minimap/an-editor-window-gets-the-minimap-and-its-labels ()
  "An editor window with the strip gets `glitnir-minimap': 120 px, the labels on with their colours, the file's true
name (Sjá's key for the hub's labels); the hub is told once that the file is shown, and the buffer text's line model
finds the MARK sections with the default expression."
  (skip-unless (fboundp 'nidhogg-lines-set-section-regexp))
  (ruler-test--with-minimap
    (let ((spec (window-parameter (selected-window) 'glitnir-minimap)))
      (should (equal (plist-get spec :width) 120))
      (should (eq (plist-get spec :labels) t))
      (should (equal (plist-get spec :file) (file-truename file)))
      (should (equal (list (plist-get spec :accent) (plist-get spec :mark)) '(drgnx-accent warning)))
      (should (equal calls (list (list "minimap/watch" (list :file (file-truename file) :on t)))))
      (should (equal (nidhogg-lines-sections nil) (list (cons (ruler-test--pos 101) "Commands"))))
      ;; placed again: nothing new is sent
      (drgnx-ruler--place (selected-window))
      (should (= (length calls) 1)))))

(ert-deftest drgnx-minimap/marks-only-and-off ()
  "`marks-only': the labels stay on but name no file, and the hub is told the file is shown no more; nil: no labels
at all, and no MARK expression in the model."
  (skip-unless (fboundp 'nidhogg-lines-set-section-regexp))
  (ruler-test--with-minimap
    (let ((drgnx-minimap-labels 'marks-only))
      (drgnx-ruler--place (selected-window))
      (let ((spec (window-parameter (selected-window) 'glitnir-minimap)))
        (should (eq (plist-get spec :labels) 'marks-only))
        (should-not (plist-get spec :file)))
      (should (equal (cadr calls) (list "minimap/watch" (list :file (file-truename file) :on :false)))))
    (let ((drgnx-minimap-labels nil))
      (drgnx-ruler--place (selected-window))
      (should-not (plist-get (window-parameter (selected-window) 'glitnir-minimap) :labels))
      (should-not (nidhogg-lines-sections nil)))))

(defvar drgnx-minimap-layer)
(defvar drgnx-minimap-coverage-files)
(defvar drgnx-minimap-profile-file)
(defvar drgnx-hunks-mode)
(defvar drgnx-hunks--data)

(ert-deftest drgnx-minimap/the-heat-layer-is-in-the-spec-and-the-watch ()
  "A heat layer (X3): the spec names it with the ramp's two faces and the file, labels on or off; the hub's watch asks
for it with the coverage reports' places or the profile; back to none, the watch asks for none, once."
  (skip-unless (fboundp 'nidhogg-lines-set-section-regexp))
  (ruler-test--with-minimap
    (let ((truename (file-truename file)) (w (selected-window)))
      (let ((drgnx-minimap-layer 'coverage) (drgnx-minimap-coverage-files '("coverage/*.info"))
            (drgnx-minimap-labels nil))
        (drgnx-ruler--place w)
        (let ((spec (window-parameter w 'glitnir-minimap)))
          (should (equal (plist-get spec :heat) "coverage"))
          (should (eq (plist-get spec :heat-low) 'drgnx-border-strong))
          (should (eq (plist-get spec :heat-high) 'drgnx-agent-2))
          (should (equal (plist-get spec :file) truename)))
        (should (equal (car (last calls))
                       (list "minimap/watch" (list :file truename :on t :heat "coverage" :coverage ["coverage/*.info"])))))
      (let ((drgnx-minimap-layer 'profile) (drgnx-minimap-profile-file "/p/cpu.pprof"))
        (drgnx-ruler--place w)
        (should (equal (car (last calls))
                       (list "minimap/watch" (list :file truename :on t :heat "profile" :profile "/p/cpu.pprof")))))
      (drgnx-ruler--place w)
      (should (equal (car (last calls)) (list "minimap/watch" (list :file truename :on t))))
      (should-not (plist-get (window-parameter w 'glitnir-minimap) :heat))
      (let ((n (length calls)))
        (drgnx-ruler--place w)
        (should (= (length calls) n))))))

(defconst ruler-test--diff
  (concat "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,3 +1,4 @@\n a\n-b\n+B\n+C\n c\n@@ -10,2 +11,0 @@\n-y\n-z\n"
          "--- a/q\n+++ b/q\n@@ -1 +1 @@\n-q\n+Q\n")
  "A diff of three hunks: at lines 4 (+2 -1), 10 (+0 -2, then the next file's header) and 15 (+1 -1).")

(ert-deftest drgnx-minimap/a-diff-buffer-gets-a-label-at-each-hunk-and-goes-by-hunk ()
  "A diff buffer with no file gets the minimap with a label at each @@ hunk, its added and removed lines counted from
the text (X6); the change commands go by hunk, wrapping."
  (skip-unless (fboundp 'nidhogg-lines-set-section-regexp))
  (ruler-test--with-minimap
    (let* ((w (selected-window)) (was (window-buffer w)) (b (generate-new-buffer " *ruler-test-diff*" t)))
      (unwind-protect
          (progn
            (with-current-buffer b (insert ruler-test--diff) (diff-mode) (goto-char (point-min)))
            (set-window-buffer w b)
            (drgnx-ruler--place w)
            (should (equal (plist-get (window-parameter w 'glitnir-minimap) :hunk-labels)
                           [[4 "hunk 1 · +2 −1"] [10 "hunk 2 · +0 −2"] [15 "hunk 3 · +1 −1"]]))
            (should (eq (plist-get (window-parameter w 'glitnir-minimap) :hunk) 'drgnx-text-muted))
            (with-current-buffer b
              (let ((line (lambda () (line-number-at-pos))))
                (drgnx-marks-next-change)
                (should (= (funcall line) 4))
                (drgnx-marks-next-change)
                (should (= (funcall line) 10))
                (drgnx-marks-next-change)
                (drgnx-marks-next-change)
                (should (= (funcall line) 4))
                (drgnx-marks-previous-change)
                (should (= (funcall line) 15))))
            ;; labels off: none
            (let ((drgnx-minimap-labels nil))
              (should-not (plist-member (drgnx-minimap--spec w) :hunk-labels))))
        (set-window-buffer w was)
        (kill-buffer b)))))

;;;; The horizontal strip (design 2026-11-18 §3.1, Task 21f)

(defvar drgnx-minimap-hstrip)

(ert-deftest drgnx-minimap/the-hstrip-spec-is-on-editors-only ()
  "An editor window gets `glitnir-hstrip' (12 px, the 8 px hit lane, the vertical thumb's face and opacity); the
Explorer's (a docked special-mode list) and a popup's do not, unless the buffer sets `drgnx-hscrollbar'; the setting
off, or the scroll bar off, takes it away."
  (ruler-test--with-minimap
    (let ((w (selected-window)))
      (let ((spec (window-parameter w 'glitnir-hstrip)))
        (should (equal (plist-get spec :height) (drgnx-px 12)))
        (should (equal (plist-get spec :lane) (drgnx-px 8)))
        (should (equal (plist-get spec :band) (cons 'drgnx-ruler-view drgnx-ruler--thumb-opacity))))
      ;; the Explorer: a docked list
      (setq buffer-file-name nil)
      (special-mode)
      (set-window-parameter w 'drgnx-role 'dock)
      (drgnx-ruler--place w)
      (should (window-parameter w 'glitnir-ruler))
      (should-not (window-parameter w 'glitnir-hstrip))
      ;; a docked buffer that asks for it
      (setq-local drgnx-hscrollbar t)
      (drgnx-ruler--place w)
      (should (window-parameter w 'glitnir-hstrip))
      (kill-local-variable 'drgnx-hscrollbar)
      (set-window-parameter w 'drgnx-role nil)
      ;; a popup's text buffer
      (text-mode)
      (set-window-parameter w 'drgnx-popup t)
      (drgnx-ruler--place w)
      (should-not (window-parameter w 'glitnir-hstrip))
      (set-window-parameter w 'drgnx-popup nil)
      (drgnx-ruler--place w)
      (should (window-parameter w 'glitnir-hstrip))
      (let ((drgnx-minimap-hstrip nil))
        (drgnx-ruler--place w)
        (should-not (window-parameter w 'glitnir-hstrip)))
      (drgnx-ruler--place w)
      (drgnx-scrollbar-mode -1)
      (should-not (window-parameter w 'glitnir-hstrip)))))

(ert-deftest drgnx-minimap/an-hstrip-drag-scrolls-and-keeps-point ()
  "Nidhogg's (glitnir-hstrip WINDOW HSCROLL) event scrolls WINDOW sideways to HSCROLL columns; point, the window's
point and the selected window stay; a dead window or a bad column is ignored."
  (ruler-test--with-minimap
    (let ((w (selected-window)) (other (split-window)))
      (unwind-protect
          (progn
            (setq truncate-lines t)
            (goto-char (point-min))
            (insert (make-string 400 ?x) "\n")
            (goto-char 10)
            (set-window-point w 10)
            (select-window other)
            (drgnx-minimap-hstrip-scroll (list 'glitnir-hstrip w 30))
            (should (= (window-hscroll w) 30))
            (should (= (window-point w) 10))
            (should (eq (selected-window) other))
            (drgnx-minimap-hstrip-scroll (list 'glitnir-hstrip w -1))
            (should (= (window-hscroll w) 30))
            (let ((dead (split-window other)))
              (delete-window dead)
              (drgnx-minimap-hstrip-scroll (list 'glitnir-hstrip dead 5))))
        (select-window w)
        (delete-window other)
        (set-window-hscroll w 0)))))

(ert-deftest drgnx-minimap/a-sideways-wheel-in-a-wrapped-buffer-does-nothing ()
  "★7: a sideways wheel, tilt or Shift-wheel over a window that wraps its lines leaves it wrapping at hscroll 0 (any
scroll would cut its lines); over a window that cuts them, it scrolls sideways."
  (ruler-test--with-minimap
    (let ((w (selected-window)) (mouse-wheel-tilt-scroll t) (mouse-wheel-flip-direction nil))
      (goto-char (point-min))
      (insert (make-string 400 ?x) "\n")
      (goto-char (point-min))
      (setq truncate-lines nil)
      (dolist (e '(wheel-left wheel-right S-wheel-up S-wheel-down))
        (drgnx-hscroll-wheel (list e (list w (point) '(0 . 0) 0)))
        (should (= (window-hscroll w) 0))
        (should-not truncate-lines))
      (setq truncate-lines t)
      (unwind-protect
          (progn
            (drgnx-hscroll-wheel (list 'wheel-left (list w (point) '(0 . 0) 0)))
            (should (> (window-hscroll w) 0)))
        (set-window-hscroll w 0)))))

(ert-deftest drgnx-minimap/a-files-change-hunks-are-labelled ()
  "A file with its change marks on gets a label at each of the hub's hunks (`drgnx-hunks--data'): a deletion at the
line before it; none without the marks."
  (skip-unless (fboundp 'nidhogg-lines-set-section-regexp))
  (ruler-test--with-minimap
    (should-not (plist-member (drgnx-minimap--spec (selected-window)) :hunk-labels))
    (setq-local drgnx-hunks-mode t)
    (setq-local drgnx-hunks--data (list (list :old-start 3 :old-count 0 :new-start 3 :new-count 2)
                                        (list :old-start 9 :old-count 2 :new-start 10 :new-count 0)))
    (should (equal (plist-get (drgnx-minimap--spec (selected-window)) :hunk-labels)
                   [[3 "hunk 1 · +2 −0"] [10 "hunk 2 · +0 −2"]]))
    (goto-char (point-min))
    (drgnx-marks-next-change)
    (should (= (line-number-at-pos) 3))
    (kill-local-variable 'drgnx-hunks-mode)
    (kill-local-variable 'drgnx-hunks--data)))

(ert-deftest drgnx-minimap/no-minimap-for-views-special-buffers-or-when-off ()
  "A Sjá view (it has a span function), a special-mode buffer and `drgnx-minimap' nil get no minimap; the strip
stays."
  (skip-unless (fboundp 'nidhogg-lines-set-section-regexp))
  (ruler-test--with-minimap
    (let ((w (selected-window)))
      (should (window-parameter w 'glitnir-minimap))
      (let ((drgnx-minimap nil))
        (drgnx-ruler--place w)
        (should-not (window-parameter w 'glitnir-minimap))
        (should (window-parameter w 'glitnir-ruler)))
      (setq-local drgnx-ruler-span-function (lambda () '(0 10 100)))
      (drgnx-ruler--place w)
      (should-not (window-parameter w 'glitnir-minimap))
      (kill-local-variable 'drgnx-ruler-span-function)
      (drgnx-ruler--place w)
      (should (window-parameter w 'glitnir-minimap))
      (special-mode)
      (drgnx-ruler--place w)
      (should-not (window-parameter w 'glitnir-minimap)))))

(defun ruler-test--python-grammar-p ()
  "Whether a python grammar is here (as fold-test.el's: a promised grammar that is not loadable fails)."
  (when-let* ((dir (getenv "DRGNX_TEST_TS_GRAMMARS")) ((file-directory-p dir)))
    (add-to-list 'treesit-extra-load-path dir))
  (let ((here (and (fboundp 'treesit-available-p) (treesit-available-p) (treesit-language-available-p 'python))))
    (when (and (not here) (or (getenv "DRGNX_TEST_TS_GRAMMARS") (getenv "DRGNX_TEST_TS_REQUIRED")))
      (ert-fail "a python grammar was promised (DRGNX_TEST_TS_GRAMMARS or DRGNX_TEST_TS_REQUIRED) and is not loadable"))
    here))

(defvar nidhogg-treesit-highlight-query)
(declare-function nidhogg-lines-classes "nidhogg-lines" (buffer line))
(declare-function nidhogg-lines-disable "nidhogg-lines" (&optional buffer))

(ert-deftest drgnx-minimap/a-tree-sitter-buffer-is-coloured-by-class ()
  "A tree-sitter buffer's minimap colours its bars by class: by its pack's highlights query, else by its own
font-lock rules' queries that are on; the spec gives each class its standard face, and leaving takes the query away."
  (skip-unless (and (fboundp 'nidhogg-lines-classes) (ruler-test--python-grammar-p)))
  (load (expand-file-name "modules/editor/drgnx-minimap" drgnx-dir) nil t)
  ;; loaded before the lookup is replaced below: a first load inside `cl-letf' would define the real one over it
  (require 'drgnx-packs)
  (should (eq (alist-get 'keyword (plist-get (drgnx-minimap--spec (selected-window)) :classes))
              'font-lock-keyword-face))
  (let ((dir (make-temp-file "drgnx-pack" t)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "queries" dir))
          (with-temp-file (expand-file-name "queries/highlights.scm" dir)
            (insert "(function_definition name: (identifier) @function)\n"))
          ;; by the pack's query: the function's name only
          (clrhash drgnx-minimap--queries)
          (cl-letf (((symbol-function 'drgnx-packs-language-dir) (lambda (_) dir)))
            (with-temp-buffer
              (insert "def norm(x):\n    return 1\n")
              (python-ts-mode)
              (nidhogg-lines-enable nil t)
              (drgnx-minimap--highlight)
              (should (equal (nidhogg-lines-classes nil 0) '((4 4 2))))
              (should-not (nidhogg-lines-classes nil 1))
              (nidhogg-lines-disable)))
          ;; no pack query: python-ts-mode's own rules (`def' and `return' keywords, the name a function, 1 a
          ;; constant)
          (clrhash drgnx-minimap--queries)
          (cl-letf (((symbol-function 'drgnx-packs-language-dir) (lambda (_) nil)))
            (with-temp-buffer
              (insert "def norm(x):\n    return 1\n")
              (python-ts-mode)
              (nidhogg-lines-enable nil t)
              (drgnx-minimap--highlight)
              (should (equal (assoc 0 (nidhogg-lines-classes nil 0)) '(0 3 1)))
              (should (equal (assoc 4 (nidhogg-lines-classes nil 0)) '(4 4 2)))
              (should (equal (assoc 4 (nidhogg-lines-classes nil 1)) '(4 6 1)))
              (should (equal (assoc 11 (nidhogg-lines-classes nil 1)) '(11 1 6)))
              (drgnx-minimap--off)
              (should-not (local-variable-p 'nidhogg-treesit-highlight-query))
              (nidhogg-lines-disable)))
          ;; rules that are off do not colour: at level 1 the keywords are not on
          (clrhash drgnx-minimap--queries)
          (cl-letf (((symbol-function 'drgnx-packs-language-dir) (lambda (_) nil)))
            (with-temp-buffer
              (insert "def norm(x):\n    return 1\n")
              (require 'treesit)
              (let ((treesit-font-lock-level 1)) (python-ts-mode))
              (nidhogg-lines-enable nil t)
              (drgnx-minimap--highlight)
              (should-not (assoc 0 (nidhogg-lines-classes nil 0)))
              (should (equal (assoc 4 (nidhogg-lines-classes nil 0)) '(4 4 2)))
              (nidhogg-lines-disable))))
      (delete-directory dir t))))

;;; ruler-test.el ends here
