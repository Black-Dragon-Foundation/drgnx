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
      (should (equal (plist-get spec :marks)
                     (list (list (ruler-test--pos 50) 0 (drgnx-px 3) 'warning)
                           (list (ruler-test--pos 50) (drgnx-px 3) (drgnx-px 9) 'error)
                           (list (ruler-test--pos 10) 0 (drgnx-px 12) 'success)))))
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

;;; ruler-test.el ends here
