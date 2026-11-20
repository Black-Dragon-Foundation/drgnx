;;; minimap-peek-gui-test.el --- GUI test: the minimap's peek and problems card (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; Task 15 (design M2, X8): with the minimap module on, a `dwell' event of Nidhogg's minimap (`glitnir-minimap-event',
;; as the compositor sends it after 300 ms at rest) opens the peek: a child frame left of the minimap, out of the
;; minimap and ruler, on the editor's own buffer from the rested row's lines, its header naming the line, at once
;; (its time, ≤ 80 ms, is the perf row minimap-peek); RET jumps there and closes it, a click elsewhere on the minimap closes it.  A `dwell-marks' event over a
;; section with diagnostics opens the problems card instead.

(require 'ert)
(require 'cl-lib)

(defconst drgnx-ui-peek--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST")
                                                         (file-name-directory (or load-file-name buffer-file-name))))))
(dolist (d '("core" "wb" "modules/editor"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-peek--repo)))
(defvar drgnx-dir)
(setq drgnx-dir (or (bound-and-true-p drgnx-dir) drgnx-ui-peek--repo))
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-ui-peek--repo) nil t)
(require 'drgnx-ruler)
(require 'drgnx-pkg)   ; the module's setup loads it: its hook default is loaded here, before the census

(defvar drgnx-minimap--card)
(defvar drgnx-minimap-peek-lines)
(declare-function drgnx-minimap--hub-p "drgnx-minimap")
(declare-function drgnx-minimap-card-jump "drgnx-minimap-peek")
(declare-function glitnir-minimap-event "glitnir" (event))
(declare-function flymake-make-diagnostic "flymake" (locus beg end type text &optional data overlay-properties))

(defmacro drgnx-ui-peek--with (&rest body)
  "BODY with the minimap module set up (torn down after), in the selected window W showing BUF, a file of 200 lines;
no hub."
  (declare (indent 0))
  `(let ((w (selected-window)) (buf (generate-new-buffer "peek-gui")))
     (skip-unless (and (display-graphic-p) (fboundp 'glitnir-minimap-event)))
     (unwind-protect
         (drgnx-test-with-modules '(editor/minimap)
           (cl-letf (((symbol-function 'drgnx-minimap--hub-p) (lambda () nil)))
             (save-window-excursion
               (delete-other-windows)
               (switch-to-buffer buf)
               (dotimes (i 200) (insert (format "line %d of the peek\n" (1+ i))))
               (prog-mode)
               (goto-char (point-min))
               (drgnx-ruler--place w)
               (redisplay t)
               ,@body)))
       (kill-buffer buf))))

(defun drgnx-ui-peek--line (n)
  "The start of line N."
  (save-excursion (goto-char (point-min)) (forward-line (1- n)) (point)))

(ert-deftest drgnx-ui-minimap/a-dwell-opens-the-peek-on-the-rows-lines ()
  "A dwell on the row of line 120 opens the peek at once (within 80 ms: perf row minimap-peek): a visible child frame of W's frame, marked out of the
minimap, its window on BUF from line 118 (6 lines, the row's in the middle) with a header \"Line 120\"; RET jumps W
to line 120 and closes it."
  (drgnx-ui-peek--with
    (let* ((pos (drgnx-ui-peek--line 120)))
      ;; the card is there when the event returns (no timer in between); its time is the perf row minimap-peek's
      (glitnir-minimap-event (list 'glitnir-minimap (list 'dwell w pos)))
      (should drgnx-minimap--card)
      (redisplay t)
      (let* ((frame (aref drgnx-minimap--card 0)) (cw (frame-root-window frame)))
        (should (frame-visible-p frame))
        (should (eq (window-frame w) (frame-parent frame)))
        (should (frame-parameter frame 'drgnx-minimap-exclude))
        (should (eq buf (window-buffer cw)))
        (should (= (drgnx-ui-peek--line (- 120 (/ (1- drgnx-minimap-peek-lines) 2))) (window-start cw)))
        (should (string-match-p "Line 120" (format-mode-line (window-parameter cw 'header-line-format))))
        ;; RET jumps and closes
        (drgnx-minimap-card-jump)
        (should-not drgnx-minimap--card)
        (should-not (frame-visible-p frame))
        (should (eq w (selected-window)))
        (should (= 120 (line-number-at-pos (window-point w) t)))))))

(ert-deftest drgnx-ui-minimap/a-click-on-the-minimap-closes-the-peek ()
  "With the peek open, a click on the minimap closes it."
  (drgnx-ui-peek--with
    (glitnir-minimap-event (list 'glitnir-minimap (list 'dwell w (drgnx-ui-peek--line 50))))
    (should drgnx-minimap--card)
    (glitnir-minimap-event (list 'glitnir-minimap (list 'click w (drgnx-ui-peek--line 10))))
    (should-not drgnx-minimap--card)))

(ert-deftest drgnx-ui-minimap/a-dwell-on-the-marks-lane-opens-the-problems-card ()
  "A dwell on the marks lane where the buffer has diagnostics opens the problems card, a line per diagnostic, its
header counting them; with no diagnostics it opens the peek."
  (require 'flymake)
  (drgnx-ui-peek--with
    (cl-letf* ((diags (list (flymake-make-diagnostic buf (drgnx-ui-peek--line 30) (drgnx-ui-peek--line 31)
                                                     :error "bad thing")
                            (flymake-make-diagnostic buf (drgnx-ui-peek--line 31) (drgnx-ui-peek--line 32)
                                                     :warning "odd thing")))
               ((symbol-function 'flymake-diagnostics) (lambda (&optional _ _) diags)))
      (setq-local flymake-mode t)
      (glitnir-minimap-event (list 'glitnir-minimap (list 'dwell-marks w (drgnx-ui-peek--line 30))))
      (let* ((frame (aref drgnx-minimap--card 0)) (cw (frame-root-window frame)))
        (should (eq 'problems (aref drgnx-minimap--card 1)))
        (should (string-match-p "1 error, 1 warning" (format-mode-line (window-parameter cw 'header-line-format))))
        (should (= 2 (with-current-buffer (window-buffer cw) (count-lines (point-min) (point-max))))))
      (setq diags nil)
      (glitnir-minimap-event (list 'glitnir-minimap (list 'dwell-marks w (drgnx-ui-peek--line 30))))
      (should (eq 'peek (aref drgnx-minimap--card 1)))
      (setq-local flymake-mode nil))))

(provide 'minimap-peek-gui-test)
;;; minimap-peek-gui-test.el ends here
