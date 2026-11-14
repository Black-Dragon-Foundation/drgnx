;;; statusbar-frame-test.el --- batch tests: one status bar across the frame -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-chrome)
(load (expand-file-name "modules/ui/drgnx-face" drgnx-dir) nil t)
(load (expand-file-name "modules/ui/drgnx-statusbar" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(require 'drgnx-notices)

(defmacro drgnx-statusbar-frame-test--with (&rest body)
  "BODY with the bar across the frame (`drgnx-statusbar-place' `frame', in batch too), the bar on, segments a and c
\(text A, C), the selected window the frame's editor, one window on the frame first; everything put back after."
  (declare (indent 0))
  `(drgnx-test-with-state
     (let ((config (current-window-configuration))
           (drgnx-statusbar-place 'frame) (drgnx-statusbar--frame-in-batch t)
           (drgnx-statusbar--segments (make-hash-table :test #'eq))
           (drgnx-statusbar--texts (make-hash-table :test #'eq))
           (drgnx-statusbar--errors nil)
           (drgnx-statusbar-left '(a)) (drgnx-statusbar-right '(c)) (drgnx-statusbar-other '(a))
           (drgnx-statusbar--window nil)
           (was drgnx-statusbar-mode))
       (delete-other-windows)
       (drgnx-state-define-role 'statusbar)     ; as the setup does
       (drgnx-test-use-editor (selected-window))
       (drgnx-statusbar-define-segment 'a :fn (lambda () "A") :click (lambda () (interactive) (push (selected-window) drgnx-statusbar-frame-test--ran)))
       (drgnx-statusbar-define-segment 'c :fn (lambda () (format "in %s" (buffer-name))))
       (unwind-protect
           (progn (drgnx-statusbar-mode 1) ,@body)
         (drgnx-statusbar-mode (if was 1 -1))
         (dolist (w (window-list nil 'nomini))
           (when (eq (window-parameter w 'drgnx-role) 'statusbar) (ignore-errors (delete-window w))))
         (set-window-configuration config)))))

(defvar drgnx-statusbar-frame-test--ran nil "The windows a segment's click ran in.")

(defun drgnx-statusbar-frame-test--bar-window ()
  "The frame's bar window, or nil."
  (seq-find (lambda (w) (eq (window-parameter w 'drgnx-role) 'statusbar)) (window-list nil 'nomini)))

(defun drgnx-statusbar-frame-test--spans-p (w)
  "Non-nil when W is the frame's bottom row: the root's last child, as wide as the root."
  (and (eq (window-parent w) (frame-root-window)) (null (window-next-sibling w))
       (= (window-total-width w) (window-total-width (frame-root-window)))))

(ert-deftest drgnx-statusbar-frame/one-window-across-the-bottom ()
  "Design §4: one bar for the window, under every card, as wide as the frame.  The editors have no mode line."
  (drgnx-statusbar-frame-test--with
    (let ((editor (selected-window)))
      (split-window editor nil 'right)
      (drgnx-statusbar--frame-ensure (selected-frame))
      (let ((bar (drgnx-statusbar-frame-test--bar-window)))
        (should bar)
        (should (drgnx-statusbar-frame-test--spans-p bar))
        (should (window-dedicated-p bar))
        (should (window-parameter bar 'no-other-window))
        (should (equal (window-parameter bar 'mode-line-format) drgnx-statusbar--frame-host))
        (should (eq (drgnx-state-window-role bar) 'statusbar))
        (should-not (drgnx-signal-editor-window-p bar))
        (should (eq drgnx-chrome-editor-mode-line 'none))
        ;; again: nothing changes
        (drgnx-statusbar--frame-ensure (selected-frame))
        (should (eq bar (drgnx-statusbar-frame-test--bar-window)))
        (should (= 1 (cl-count-if (lambda (w) (eq (window-parameter w 'drgnx-role) 'statusbar)) (window-list nil 'nomini))))))))

(ert-deftest drgnx-statusbar-frame/stays-the-bottom-row-when-a-side-window-comes ()
  "A side window made after the bar splits the frame's root beside it; the bar is made again under both, once."
  (drgnx-statusbar-frame-test--with
    (drgnx-statusbar--frame-ensure (selected-frame))
    (let ((side (display-buffer-in-side-window (get-buffer-create " *frame-test side*") '((side . left)))))
      (should side)
      (drgnx-statusbar--frame-ensure (selected-frame))
      (let ((bars (seq-filter (lambda (w) (eq (window-parameter w 'drgnx-role) 'statusbar)) (window-list nil 'nomini))))
        (should (= 1 (length bars)))
        (should (drgnx-statusbar-frame-test--spans-p (car bars))))
      (should (window-live-p side))
      ;; a window that shows the bar's buffer but is not the bar (a layout put back) goes
      (let ((stray (split-window (selected-window) nil 'below)))
        (set-window-buffer stray (drgnx-statusbar--frame-buffer))
        (drgnx-statusbar--frame-ensure (selected-frame))
        (should-not (window-live-p stray))))
    (kill-buffer " *frame-test side*")))

(ert-deftest drgnx-statusbar-frame/shows-the-editor-you-used-last ()
  "The bar's mode line is the most recently used editor's bar, at the bar window's width, its own kind of bar for
a buffer that is not a file."
  (drgnx-statusbar-frame-test--with
    (let* ((one (selected-window)) (two (split-window one nil 'right))
           (b1 (get-buffer-create "frame-test-one.el")) (b2 (get-buffer-create "*frame-test two*")))
      (with-current-buffer b1 (emacs-lisp-mode))
      (with-current-buffer b2 (special-mode))
      (set-window-buffer one b1) (set-window-buffer two b2)
      (drgnx-statusbar--frame-ensure (selected-frame))
      (let ((bar (drgnx-statusbar-frame-test--bar-window)))
        (drgnx-test-use-editor one)
        (let ((s (with-selected-window bar (drgnx-statusbar-frame-mode-line))))
          (should (string-match-p "A.*in frame-test-one\\.el" (substring-no-properties s))))
        (drgnx-test-use-editor two)
        (let ((s (substring-no-properties (with-selected-window bar (drgnx-statusbar-frame-mode-line)))))
          (should (string-match-p "A" s))
          (should-not (string-match-p "in " s))))     ; the other bar: no right side
      (kill-buffer b1) (kill-buffer b2))))

(ert-deftest drgnx-statusbar-frame/the-editors-own-bar-is-not-reused ()
  "The bar drawn in the bar's window is laid out for that window (its fringe), not taken from the memo of the editor's
own mode line at the same width."
  (drgnx-statusbar-frame-test--with
    (drgnx-statusbar--frame-ensure (selected-frame))
    (let* ((editor (selected-window)) (bar (drgnx-statusbar-frame-test--bar-window))
           (drgnx-look-bars-measure-function (lambda (s &optional _f) (* 10 (string-width s))))
           (gap (lambda (s) (let ((pos (next-single-property-change 0 'display s)) found)
                              (while (and pos (not found))
                                (let ((d (get-text-property pos 'display s)))
                                  (when (and (eq (car-safe d) 'space) (plist-get (cdr d) :align-to)) (setq found d)))
                                (setq pos (next-single-property-change pos 'display s)))
                              found))))
      (with-current-buffer (window-buffer editor) (emacs-lisp-mode))
      ;; a batch frame's pixels are its columns: wide enough for every segment at ten a column
      (cl-letf (((symbol-function 'drgnx-statusbar--right-fringe) (lambda (w) (if (eq (or drgnx-statusbar--drawn-in w) bar) 0 8)))
                ((symbol-function 'drgnx-statusbar--window-width) (lambda (_w) 2000)))
        (let ((own (with-selected-window editor
                     (with-current-buffer (window-buffer editor)
                       (let ((drgnx-statusbar--window editor)) (drgnx-statusbar--bar editor 2000 nil)))))
              (across (with-selected-window bar (drgnx-statusbar-frame-mode-line))))
          (should (funcall gap own))
          (should (funcall gap across))
          (should-not (equal (funcall gap own) (funcall gap across))))))))

(ert-deftest drgnx-statusbar-frame/a-click-runs-in-the-editor ()
  "A click on a segment of the bar runs its command in the editor it shows, not in the bar's window."
  (drgnx-statusbar-frame-test--with
    (setq drgnx-statusbar-frame-test--ran nil)
    (drgnx-statusbar--frame-ensure (selected-frame))
    (let* ((editor (selected-window)) (bar (drgnx-statusbar-frame-test--bar-window))
           (s (with-selected-window bar (drgnx-statusbar-frame-mode-line)))
           (pos (text-property-any 0 (length s) 'drgnx-statusbar-segment 'a s)))
      (should pos)
      (drgnx-statusbar-click (list 'mouse-1 (list bar 'mode-line '(0 . 0) 0 (cons s pos))))
      (should (equal drgnx-statusbar-frame-test--ran (list editor))))))

(ert-deftest drgnx-statusbar-frame/off-takes-it-away ()
  "Turning the bar off, or the place back to `editors', deletes the bar's window and gives the editors their mode line."
  (drgnx-statusbar-frame-test--with
    (drgnx-statusbar--frame-ensure (selected-frame))
    (should (drgnx-statusbar-frame-test--bar-window))
    (customize-set-variable 'drgnx-statusbar-place 'editors)
    (should-not (drgnx-statusbar-frame-test--bar-window))
    (should (equal drgnx-chrome-editor-mode-line drgnx-statusbar--host))
    (customize-set-variable 'drgnx-statusbar-place 'frame)
    (should (drgnx-statusbar-frame-test--bar-window))
    (drgnx-statusbar-mode -1)
    (should-not (drgnx-statusbar-frame-test--bar-window))
    (should-not (get-buffer drgnx-statusbar--frame-buffer-name))))

(provide 'statusbar-frame-test)
;;; statusbar-frame-test.el ends here
