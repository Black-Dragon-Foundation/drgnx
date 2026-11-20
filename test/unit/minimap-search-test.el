;;; minimap-search-test.el --- batch tests: the minimap's search, focus and line selection -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; modules/editor/drgnx-minimap-search.el (design X1, X2, X7): the search's hits from the line model or, for a
;; query it cannot read, from Lisp, the same either way; the focused minimap's n/N with "N of M", Esc putting point
;; back, RET jumping; a Shift-drag's events selecting whole lines; the folded lines the Outline is told.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/editor/drgnx-minimap" drgnx-dir) nil t)
(load (expand-file-name "modules/editor/drgnx-fold" drgnx-dir) nil t)

(declare-function nidhogg-lines-enable "nidhogg-lines" (&optional buffer wait))
(declare-function nidhogg-lines-disable "nidhogg-lines" (&optional buffer))
(defvar drgnx-minimap--focus)

(defmacro minimap-search-test--with (&rest body)
  "BODY in a buffer of 100 lines, every 10th holding \"needle\", shown in the selected window, point at its start."
  (declare (indent 0))
  `(let ((b (generate-new-buffer "minimap-search")))
     (unwind-protect
         (save-window-excursion
           (switch-to-buffer b)
           (dotimes (i 100) (insert (format "line %d%s\n" (1+ i) (if (zerop (% (1+ i) 10)) " needle" ""))))
           (goto-char (point-min))
           ,@body)
       (kill-buffer b))))

(defun minimap-search-test--line (n)
  "The start of line N."
  (save-excursion (goto-char (point-min)) (forward-line (1- n)) (point)))

(ert-deftest drgnx-minimap/the-lisp-search-skips-empty-matches ()
  "Lisp's search finds each hit once, in order, as (POS . END), and an empty match is no hit (`how-many''s count)."
  (minimap-search-test--with
    (let ((hits (drgnx-minimap-search-lisp "needle" nil t)))
      (should (= 10 (length hits)))
      (should (= (how-many "needle" (point-min) (point-max)) (length hits)))
      (should (equal (cons (+ (minimap-search-test--line 10) 8) (+ (minimap-search-test--line 10) 14)) (car hits))))
    (should-not (drgnx-minimap-search-lisp "x*" t nil))
    (should-not (drgnx-minimap-search-lisp "[" t nil))))

(ert-deftest drgnx-minimap/the-models-search-finds-what-lisp-finds ()
  "With a line model, `drgnx-minimap-search-run' scans in Rust and gives Lisp's hits; a query it cannot read (a
back-reference) falls back to Lisp, with the same hits."
  (minimap-search-test--with
    (skip-unless (fboundp 'nidhogg-lines-search))
    (nidhogg-lines-enable nil t)
    (unwind-protect
        (progn
          (should (equal (drgnx-minimap-search-lisp "needle" nil t) (drgnx-minimap-search-run "needle" nil t)))
          (should (equal (drgnx-minimap-search-lisp "ne\\(e\\)\\1" t t) (drgnx-minimap-search-run "ne\\(e\\)\\1" t t))))
      (nidhogg-lines-disable))))

(ert-deftest drgnx-minimap/focus-steps-through-the-hits-and-esc-puts-point-back ()
  "In a focused minimap, `/' finds the hits and goes to the first, n and N step with \"N of M\" (wrapping), and
Esc leaves with point where it was; RET instead jumps to the row."
  (minimap-search-test--with
    (drgnx-test-with-modules '(editor/minimap)
      (cl-letf* ((said nil)
                 ((symbol-function 'message) (lambda (fmt &rest args) (setq said (and fmt (apply #'format fmt args)))))
                 ((symbol-function 'drgnx-minimap-window-p) (lambda (_) t))
                 ((symbol-function 'drgnx-minimap--place) #'ignore)
                 ((symbol-function 'drgnx-minimap--model-p) (lambda (&rest _) nil)))
        (goto-char (minimap-search-test--line 5))
        (drgnx-minimap-focus)
        (drgnx-minimap-focus-search "needle")
        (should (= (minimap-search-test--line 10) (plist-get drgnx-minimap--focus :cursor)))
        (drgnx-minimap-focus-next)
        (should (= (minimap-search-test--line 20) (plist-get drgnx-minimap--focus :cursor)))
        (should (equal "2 of 10" said))
        (drgnx-minimap-focus-previous)
        (drgnx-minimap-focus-previous)
        (should (= (minimap-search-test--line 100) (plist-get drgnx-minimap--focus :cursor)))
        (should (equal "10 of 10" said))
        (drgnx-minimap-focus-leave)
        (should-not drgnx-minimap--focus)
        (should (= (minimap-search-test--line 5) (window-point)))
        (drgnx-minimap-focus)
        (drgnx-minimap-focus-down)
        (drgnx-minimap-focus-down)
        (drgnx-minimap-focus-go)
        (should-not drgnx-minimap--focus)
        (should (= 7 (line-number-at-pos (window-point) t)))))))

(ert-deftest drgnx-minimap/a-shift-drag-selects-whole-lines ()
  "A Shift-drag's start, extend and end events select whole lines between where it started and where it is, either
way; its end opens the chip over that range."
  (minimap-search-test--with
    (let (shown)
      (cl-letf (((symbol-function 'drgnx-minimap--show-card)
                 (lambda (kind _w range &rest _) (setq shown (cons kind range)))))
        (drgnx-minimap--search-event 'select-start (selected-window) (+ 3 (minimap-search-test--line 30)))
        (drgnx-minimap--search-event 'select-extend (selected-window) (minimap-search-test--line 25))
        (should (region-active-p))
        (should (= (minimap-search-test--line 25) (region-beginning)))
        (should (= (minimap-search-test--line 31) (region-end)))
        (drgnx-minimap--search-event 'select-end (selected-window) (+ 2 (minimap-search-test--line 33)))
        (should (equal (cons 'chip (cons (minimap-search-test--line 30) (minimap-search-test--line 34))) shown))))))

(ert-deftest drgnx-minimap/the-chip-text-names-its-actions ()
  "The chip counts the lines and offers Copy, Fold, Pin and Ask Agent, each carrying its command."
  (let ((text (drgnx-minimap--chip-text 4)))
    (should (string-prefix-p " 4 lines " text))
    (dolist (a '("Copy" "Fold" "Pin" "Ask Agent")) (should (string-search a text)))
    (should (eq 'drgnx-minimap-chip-fold
                (get-text-property (string-search "Fold" text) 'drgnx-minimap-chip text)))))

(ert-deftest drgnx-minimap/the-outline-is-told-the-folded-lines ()
  "`drgnx-fold-folded-lines' names each folded range's first line, and a fold change runs
`drgnx-fold-changed-hook' (the Outline follows it)."
  (minimap-search-test--with
    (skip-unless (fboundp 'nidhogg-lines-set-hidden))
    (prog-mode)
    (drgnx-test-with-modules '(editor/fold)
      ;; the counter leaves the hook before the module's teardown runs it again (a stub gone by then was void there)
      (let* ((ran 0) (count (lambda () (cl-incf ran))))
        (add-hook 'drgnx-fold-changed-hook count nil t)
        (unwind-protect
            (progn
              (drgnx-fold-create (minimap-search-test--line 12) (minimap-search-test--line 16))
              (drgnx-fold-create (minimap-search-test--line 40) (minimap-search-test--line 44))
              (should (equal '(12 40) (drgnx-fold-folded-lines)))
              (should (> ran 0)))
          (remove-hook 'drgnx-fold-changed-hook count t))))))

(provide 'minimap-search-test)
;;; minimap-search-test.el ends here
