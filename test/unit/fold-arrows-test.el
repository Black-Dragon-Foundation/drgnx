;;; fold-arrows-test.el --- batch tests: the fold arrows in the fringe and named folds' pills (module editor/fold) -*- lexical-binding: t -*-
;; test-class: det
;; Design F1 and F3 (minimap-folding Task 12-D): an editor window's left fringe carries Nidhogg's chevrons
;; (`glitnir-fold-arrows', drawn from the line model at publish: no overlays, no Lisp per scroll), a click on the fringe
;; folds or unfolds the line's range, and a named fold's name goes to the line model for the minimap's pill.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx)
(load (expand-file-name "modules/editor/drgnx-fold" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)

(declare-function nidhogg-lines-disable "nidhogg-lines" (&optional buffer))
(defvar drgnx-fold-arrows)

(defconst fold-arrows-test--text
  "def a():\n    x = 1\n    if x:\n        y = 2\n    z = 3\ndef b():\n    w = 4\n"
  "Three indentation ranges: a (lines 1–5), its `if' (3–4), b (6–7).")

(defmacro fold-arrows-test--with (&rest body)
  "BODY in a `prog-mode' buffer of `fold-arrows-test--text' shown in the selected window, point at its start."
  (declare (indent 0))
  `(progn
     (skip-unless (fboundp 'nidhogg-lines-set-fold-sources))
     (let ((b (generate-new-buffer "fold-arrows")))
       (unwind-protect
           (save-window-excursion
             (switch-to-buffer b)
             (insert fold-arrows-test--text)
             (prog-mode)
             (goto-char (point-min))
             ,@body)
         (with-current-buffer b (nidhogg-lines-disable))
         (kill-buffer b)))))

(defun fold-arrows-test--line (n)
  "The start of line N."
  (save-excursion (goto-char (point-min)) (forward-line (1- n)) (point)))

(ert-deftest drgnx-fold/the-arrows-spec-follows-the-setting ()
  "`hover' and `always' give Nidhogg's spec: a 12 px chevron centred in the 18 px arrows' column (the inset counts from
the fringe's inner edge, past a left scroll bar's strip), an open fold's chevron muted and a folded one's in the
accent; nil gives none."
  (cl-letf (((symbol-function 'drgnx-px) (lambda (n &rest _) n)))
    (let ((spec (drgnx-fold--arrows-spec 'hover nil)))
      (should (eq 'hover (plist-get spec :mode)))
      (should (= 12 (plist-get spec :size)))
      (should (= 3 (plist-get spec :inset)))
      (should (eq 'drgnx-text-muted (car (plist-get spec :colour))))
      (should (eq 'drgnx-accent (car (plist-get spec :folded)))))
    (should (= 15 (plist-get (drgnx-fold--arrows-spec 'hover nil 12) :inset)))
    (should (eq 'always (plist-get (drgnx-fold--arrows-spec 'always nil) :mode)))
    (should-not (drgnx-fold--arrows-spec nil nil))))

(ert-deftest drgnx-fold/an-editor-window-gets-the-arrows-and-its-gutter-and-loses-them ()
  "Placed with its strip on a graphical frame, an editor window gets `glitnir-fold-arrows' and a left fringe of the
arrows' gutter (5 + 18 px); off the strip, or with the setting nil, it has none and its fringe is its own again.  With
a scroll bar on the left the gutter is the fringe's own part, the strip kept beside it."
  (fold-arrows-test--with
    (let ((w (selected-window)) (drgnx-fold-arrows 'hover) (fringes (list 8 8)))
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                ((symbol-function 'drgnx-px) (lambda (n &rest _) n))
                ((symbol-function 'window-fringes) (lambda (&rest _) (list (car fringes) (cadr fringes) nil nil)))
                ((symbol-function 'set-window-fringes) (lambda (_w l r &rest _) (setq fringes (list l r)))))
        (unwind-protect
            (progn
              (drgnx-fold--place-arrows w t)
              (should (eq 'hover (plist-get (window-parameter w 'glitnir-fold-arrows) :mode)))
              (should (equal fringes '(23 8)))
              (drgnx-fold--place-arrows w t)
              (should (equal fringes '(23 8)))
              (drgnx-fold--place-arrows w nil)
              (should-not (window-parameter w 'glitnir-fold-arrows))
              (should (equal fringes '(8 8)))
              (let ((drgnx-fold-arrows nil))
                (drgnx-fold--place-arrows w t)
                (should-not (window-parameter w 'glitnir-fold-arrows))
                (should (equal fringes '(8 8))))
              ;; a scroll bar on the left: the fringe is 8 + its 12 px strip
              (setq fringes (list 20 8))
              (set-window-parameter w 'drgnx-ruler-side 'left)
              (set-window-parameter w 'drgnx-ruler-fringe 8)
              (drgnx-fold--place-arrows w t)
              (should (equal fringes '(35 8)))
              (should (= 23 (window-parameter w 'drgnx-ruler-fringe)))
              (should (= 15 (plist-get (window-parameter w 'glitnir-fold-arrows) :inset)))
              (drgnx-fold--place-arrows w nil)
              (should (equal fringes '(20 8)))
              (should (= 8 (window-parameter w 'drgnx-ruler-fringe))))
          (dolist (p '(glitnir-fold-arrows drgnx-fold-fringe drgnx-ruler-side drgnx-ruler-fringe))
            (set-window-parameter w p nil)))))))

(ert-deftest drgnx-fold/a-click-on-the-fringe-folds-and-unfolds ()
  "A click in the left fringe on a line that starts a range folds it, again unfolds it; on a line inside a range (no
chevron there) it does nothing."
  (fold-arrows-test--with
    (let* ((w (selected-window))
           (click (lambda (line) `(mouse-1 (,w left-fringe (2 . 10) 0 nil ,(fold-arrows-test--line line))))))
      (drgnx-fold-fringe-click (funcall click 6))
      (should (invisible-p (fold-arrows-test--line 7)))
      (drgnx-fold-fringe-click (funcall click 6))
      (should-not (invisible-p (fold-arrows-test--line 7)))
      (drgnx-fold-fringe-click (funcall click 2))
      (should-not (drgnx-fold--overlays))
      (should (= (point) (point-min))))))

(ert-deftest drgnx-fold/a-named-fold-tells-the-model-its-name ()
  "The hidden ranges go to the line model as (BEG END NAME): a named fold's name, nil for the others."
  (fold-arrows-test--with
    (let (sent)
      (cl-letf (((symbol-function 'nidhogg-lines-set-hidden) (lambda (_b ranges) (setq sent ranges))))
        (transient-mark-mode 1)
        (set-mark (fold-arrows-test--line 1))
        (goto-char (fold-arrows-test--line 3))
        (drgnx-fold-create (region-beginning) (region-end) nil)
        (goto-char (fold-arrows-test--line 1))
        (drgnx-fold-rename "setup")
        (should (equal "setup" (nth 2 (car sent))))
        (goto-char (fold-arrows-test--line 6))
        (drgnx-fold-fold)
        (should (= 2 (length sent)))
        (should (equal '("setup" nil) (mapcar (lambda (r) (nth 2 r)) (sort (copy-sequence sent) #'car-less-than-car))))))))

(provide 'fold-arrows-test)
;;; fold-arrows-test.el ends here
