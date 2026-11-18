;;; rail-gui-test.el --- GUI tests: the layout A rail beside the side bar and under the status bar (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; The rail is a left side window outside the grid, 44 logical px wide at every scale; the status bar across the frame
;; splits the root, so it spans the frame under the rail and the grid's root is the editor area between them.  Each
;; item is its 32 px row.  Pattern D: every measurement is taken after `drgnx-test-wait-presented'.

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-look-gui-fixture (expand-file-name "../fixtures/look-gui-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-rail-ui-test--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-rail-ui-test--repo)))
(require 'drgnx)
(require 'drgnx-state)
(dolist (m '("drgnx-look-scale" "drgnx-statusbar" "drgnx-rail"))
  (load (expand-file-name (concat "modules/ui/" m) drgnx-rail-ui-test--repo) nil t))

(declare-function drgnx-look-scale-apply-frame "drgnx-look-scale" (frame percent))
(declare-function drgnx-look-scale--roots "drgnx-look-scale" ())
(declare-function drgnx-look-scale--follow "drgnx-look-scale" ())
(declare-function drgnx-grid-root "drgnx-grid" (&optional frame))

(defun drgnx-rail-ui-test--window (role)
  (seq-find (lambda (w) (eq (window-parameter w 'drgnx-role) role)) (window-list nil 'nomini)))

(load (expand-file-name "test/fixtures/grid-fixture" drgnx-rail-ui-test--repo) nil t)

(defmacro drgnx-rail-ui-test--with-rail (&rest body)
  "BODY on a frame of its own with the grid fixture (the grid backend), the status bar across it and the rail on;
every frame BODY made deleted after, the modes as they were."
  (declare (indent 0))
  `(let* ((frames (frame-list)) (selected (selected-frame)) (frame (make-frame '((width . 160) (height . 50)))))
     (unwind-protect
         (with-selected-frame frame
           (drgnx-grid-test--with
             (let ((drgnx-statusbar-place 'frame) (drgnx-statusbar-mode t) (rail-was drgnx-rail-mode))   ; the bar's variable only: no mode function, no chrome of the session's frames
               (drgnx-test-wait (lambda () (redisplay t) (frame-visible-p frame)) :secs 10 :what "the frame mapped")
               (unwind-protect
                   (progn (drgnx-state-define-role 'statusbar)
                          (drgnx-rail-mode 1)
                          (drgnx-rail--ensure frame)
                          (drgnx-statusbar--frame-ensure frame)
                          (drgnx-test-wait-presented :frame frame)
                          ,@body)
                 (drgnx-rail-mode (if rail-was 1 -1))))))
       (dolist (f (frame-list)) (unless (memq f frames) (delete-frame f t)))
       (when (frame-live-p selected) (select-frame selected)))))

(defun drgnx-rail-ui-test--check-geometry ()
  "The rail's width, its place beside the bar and the grid's root, and its items' rows, at the frame's scale."
  (let* ((frame (selected-frame)) (rail (drgnx-rail-ui-test--window 'rail)) (bar (drgnx-rail-ui-test--window 'statusbar)))
    (unless rail
      (ert-fail (format "no rail: workbench %S grid %S backend %S hidden %S mode %S windows %S"
                        (drgnx-state-workbench-frame-p frame) (drgnx-wb-grid-p) (bound-and-true-p drgnx-pane-backend)
                        (frame-parameter frame 'drgnx-rail) drgnx-rail-mode
                        (mapcar (lambda (w) (list (window-parameter w 'drgnx-role) (window-parameter w 'window-side)))
                                (window-list frame 'nomini)))))
    (should (eq 'left (window-parameter rail 'window-side)))
    (should (= (drgnx-px drgnx-rail-width frame) (window-pixel-width rail)))
    (should (= 0 (nth 0 (window-pixel-edges rail))))
    ;; the 6 px inset, then each item its 32 px row and the 6 px gap below it: the tops of the lines, top down
    (let* ((item (drgnx-px 32 frame)) (gap (drgnx-px 6 frame))
           (tops (with-current-buffer (window-buffer rail)
                   (save-excursion
                     (goto-char (point-min))
                     (cl-loop until (eobp) collect (cdr (posn-x-y (posn-at-point (point) rail)))
                              do (forward-line 1)))))
           (heights (cl-loop for (a b) on tops while b collect (- b a))))
      (should (equal (list gap) (list (car heights))))
      ;; heights: gap, item, gap, item, ...
      (should (equal (cl-loop for i from 1 below (* 2 (length drgnx-rail-places)) collect (if (cl-oddp i) item gap))
                     (seq-take (cdr heights) (1- (* 2 (length drgnx-rail-places)))))))
    (when bar
      ;; the bar spans the frame and is under the rail
      (should (= (window-pixel-width bar) (window-pixel-width (frame-root-window frame))))
      (should (= 0 (nth 0 (window-pixel-edges bar))))
      (should (<= (nth 3 (window-pixel-edges rail)) (nth 1 (window-pixel-edges bar))))
      (when (fboundp 'drgnx-grid-root)
        (let ((root (drgnx-grid-root frame)))
          (should (>= (nth 0 (window-pixel-edges root)) (nth 2 (window-pixel-edges rail))))
          (should (<= (nth 3 (window-pixel-edges root)) (nth 1 (window-pixel-edges bar)))))))))

(drgnx-look-gui-deftest drgnx-rail-ui/rail-is-44-px-at-every-scale ()
  "The rail is 44 logical px wide at the run's scale and at a UI scale of 125 %, sits above the status bar, which still
spans the frame, and the grid's root is right of it and above the bar."
  (skip-unless (display-graphic-p))
  (drgnx-rail-ui-test--with-rail
    (drgnx-rail-ui-test--check-geometry)
    (unwind-protect
        (progn
          (drgnx-look-scale-apply-frame (selected-frame) 125)
          (drgnx-look-scale--follow)               ; as a setting or a zoom key does: the rail follows
          (drgnx-test-wait-presented)
          (drgnx-statusbar--frame-ensure (selected-frame))
          (drgnx-test-wait-presented)
          (drgnx-rail-ui-test--check-geometry))
      (dolist (f (drgnx-look-scale--roots)) (drgnx-look-scale-apply-frame f 100))
      (drgnx-look-scale--follow))))

(provide 'rail-gui-test)
;;; rail-gui-test.el ends here
