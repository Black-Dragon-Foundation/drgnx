;;; minimap-peek-test.el --- batch tests: the minimap's trail, describe and problems card (module editor/minimap) -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; modules/editor/drgnx-minimap-peek.el over Nidhogg's line model (design M4, A2, X8): the trail noted after the
;; idle dwell (virtual time) and on a next-mark jump, which also flashes; `trail-clear'; the words `minimap-describe'
;; speaks; the problems card's lines.  The peek's child frame is a GUI row (test/ui/minimap-peek-gui-test.el).
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/editor/drgnx-minimap" drgnx-dir) nil t)

(declare-function nidhogg-lines-enable "nidhogg-lines" (&optional buffer wait))
(declare-function nidhogg-lines-disable "nidhogg-lines" (&optional buffer))
(declare-function nidhogg-lines-trail "nidhogg-lines" (buffer))
(declare-function nidhogg-lines-set-marks "nidhogg-lines" (buffer kind marks))
(declare-function flymake-make-diagnostic "flymake" (locus beg end type text &optional data overlay-properties))
(defvar drgnx-minimap-trail)
(defvar drgnx-minimap-trail-dwell)
(defvar drgnx-ruler-kinds)

(defmacro minimap-peek-test--with (&rest body)
  "BODY in a buffer of 60 lines with a line model, shown in the selected window, point at its start."
  (declare (indent 0))
  `(progn
     (skip-unless (fboundp 'nidhogg-lines-trail-note))
     (let ((b (generate-new-buffer "minimap-peek")))
       (unwind-protect
           (save-window-excursion
             (switch-to-buffer b)
             (dotimes (i 60) (insert (format "line %d\n" (1+ i))))
             (goto-char (point-min))
             (nidhogg-lines-enable nil t)
             ,@body)
         (with-current-buffer b (nidhogg-lines-disable))
         (kill-buffer b)))))

(defun minimap-peek-test--line (n)
  "The start of line N."
  (save-excursion (goto-char (point-min)) (forward-line (1- n)) (point)))

(ert-deftest drgnx-minimap/the-trail-notes-a-line-after-the-idle-dwell ()
  "With the module on, point resting `drgnx-minimap-trail-dwell' seconds puts its line on the trail; a shorter pause
does not, and with the trail off nothing is noted."
  (minimap-peek-test--with
    (drgnx-test-with-clock ()
      (drgnx-test-with-modules '(editor/minimap)
        (goto-char (minimap-peek-test--line 30))
        (drgnx-test-idle (/ drgnx-minimap-trail-dwell 2.0))
        (should-not (nidhogg-lines-trail nil))
        (drgnx-test-idle (+ drgnx-minimap-trail-dwell 0.1))
        (should (equal (list (minimap-peek-test--line 30)) (nidhogg-lines-trail nil)))
        (let ((drgnx-minimap-trail nil))
          (goto-char (minimap-peek-test--line 40))
          (drgnx-test-idle (+ drgnx-minimap-trail-dwell 0.1))
          (should (equal (list (minimap-peek-test--line 30)) (nidhogg-lines-trail nil))))))))

(ert-deftest drgnx-minimap/a-mark-jump-joins-the-trail-and-flashes-its-row ()
  "A next-mark key's jump notes its line on the trail and flashes the row in the selected window's minimap."
  (minimap-peek-test--with
    (let (flashed)
      (drgnx-test-with-modules '(editor/minimap)
        (cl-letf (((symbol-function 'glitnir-minimap-flash) (lambda (w p) (push (list w p) flashed) t)))
          (run-hook-with-args 'drgnx-marks-jump-functions (minimap-peek-test--line 12))))
      (should (equal (list (list (selected-window) (minimap-peek-test--line 12))) flashed))
      (should (equal (list (minimap-peek-test--line 12)) (nidhogg-lines-trail nil))))))

(ert-deftest drgnx-minimap/trail-clear-empties-the-trail ()
  "`trail-clear' forgets the buffer's visits."
  (minimap-peek-test--with
    (drgnx-minimap-trail-note (minimap-peek-test--line 5))
    (drgnx-minimap-trail-note (minimap-peek-test--line 9))
    (should (= 2 (length (nidhogg-lines-trail nil))))
    (drgnx-minimap-trail-clear)
    (should-not (nidhogg-lines-trail nil))))

(ert-deftest drgnx-minimap/describe-says-the-section-its-marks-and-lines ()
  "`minimap-describe' speaks the section around point (here the whole buffer: no folds or MARK sections), its lines
and its marks by kind, plural when more than one."
  (minimap-peek-test--with
    (nidhogg-lines-set-marks nil (cl-position 'error drgnx-ruler-kinds)
                             (list (vector (minimap-peek-test--line 3) nil 2 0 9)
                                   (vector (minimap-peek-test--line 7) nil 2 0 9)))
    (nidhogg-lines-set-marks nil (cl-position 'warning drgnx-ruler-kinds)
                             (list (vector (minimap-peek-test--line 8) nil 2 0 8)))
    (let ((words (drgnx-minimap-description (minimap-peek-test--line 5))))
      (should (string-match-p "lines 1 to 6[01]" words))
      (should (string-match-p "2 errors, 1 warning" words)))
    (nidhogg-lines-set-marks nil (cl-position 'error drgnx-ruler-kinds) nil)
    (nidhogg-lines-set-marks nil (cl-position 'warning drgnx-ruler-kinds) nil)
    (should (string-match-p "no marks" (drgnx-minimap-description (minimap-peek-test--line 5))))))

(ert-deftest drgnx-minimap/the-problems-card-lists-each-diagnostic-with-its-place ()
  "The problems card has a line per diagnostic, in order: its icon, its message's first line and its line number,
the line carrying the diagnostic's place; the counts are by kind."
  (require 'flymake)
  (minimap-peek-test--with
    (let* ((d1 (flymake-make-diagnostic (current-buffer) (minimap-peek-test--line 4) (minimap-peek-test--line 5)
                                        :error "mismatched types\nmore"))
           (d2 (flymake-make-diagnostic (current-buffer) (minimap-peek-test--line 9) (minimap-peek-test--line 10)
                                        :warning "unused variable"))
           (made (drgnx-minimap-problems-text (list d1 d2) (selected-frame)))
           (lines (split-string (car made) "\n" t)))
      (should (= 2 (length lines)))
      (should (string-match-p "mismatched types  line 4\\'" (nth 0 lines)))
      (should-not (string-match-p "more" (nth 0 lines)))
      (should (string-match-p "unused variable  line 9\\'" (nth 1 lines)))
      (should (= (minimap-peek-test--line 9)
                 (get-text-property (1+ (length (nth 0 lines))) 'drgnx-minimap-pos (car made))))
      (should (equal '((error . 1) (warning . 1) (info . 0)) (cdr made))))))

(provide 'minimap-peek-test)
;;; minimap-peek-test.el ends here
