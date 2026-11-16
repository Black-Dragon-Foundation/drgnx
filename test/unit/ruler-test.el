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

;;; ruler-test.el ends here
