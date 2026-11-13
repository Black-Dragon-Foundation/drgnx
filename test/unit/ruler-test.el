;;; ruler-test.el --- batch tests: the overview ruler draws producers' marks scaled to the window -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; Batch Emacs has a terminal frame: a row is one character in the face of its best mark.  Redisplay does not run, so
;; a scroll is the hook's call, as redisplay makes it.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-ruler)

(defvar ruler-test--marks nil "What the test's producer hands the ruler.")

(defun ruler-test--source () ruler-test--marks)

(defmacro ruler-test--with (lines &rest body)
  "BODY in a buffer of LINES lines shown in the selected window, its start at the top; all taken back after."
  (declare (indent 1))
  `(let ((b (generate-new-buffer " ruler")) (w (selected-window)) (was (window-buffer (selected-window)))
         (ruler-test--marks nil))
     (unwind-protect
         (progn
           (with-current-buffer b (dotimes (i ,lines) (insert (format "line %d\n" (1+ i)))) (goto-char (point-min)))
           (set-window-buffer w b)
           (set-window-start w 1)
           (with-current-buffer b ,@body))
       (set-window-buffer w was)
       (kill-buffer b))))

(defun ruler-test--rows ()
  "The selected window's rows: (LINE-IT-SITS-ON GOES-TO FACE) each."
  (mapcar (lambda (o)
            (let* ((s (cadr (get-text-property 0 'display (overlay-get o 'before-string))))
                   (face (get-text-property (1- (length s)) 'face s)))
              (list (line-number-at-pos (overlay-start o)) (get-text-property 0 'drgnx-ruler-line s) face)))
          (cddr (assq (selected-window) drgnx-ruler--windows))))

(ert-deftest drgnx-ruler/marks-scaled-to-the-window ()
  "Each row of the window stands for N/H lines and shows its best mark; the rows of the lines shown are the band;
the ruler claims the right margin while there are marks."
  (ruler-test--with 1000
    (let* ((h (window-body-height)) (per (/ 1000.0 h)))
      (setq ruler-test--marks (list (list 500 'middle 'error 1) (list 500 'middle 'warning 2) (list 1000 'full 'success 3)))
      (drgnx-ruler-source 'test #'ruler-test--source)
      (should drgnx-ruler-mode)
      (should (equal (window-margins) '(nil . 1)))
      (let ((rows (ruler-test--rows)))
        (should (= (length rows) h))
        ;; each row sits on the window's next line and goes to its first line
        (should (equal (mapcar #'car rows) (number-sequence 1 h)))
        (should (equal (nth 1 (nth 1 rows)) (1+ (floor per))))
        ;; line 500's row: the higher priority wins; the last row: the stop; rows past the shown lines: none
        (should (eq (nth 2 (nth (floor (/ 499 per)) rows)) 'warning))
        (should (eq (nth 2 (car (last rows))) 'success))
        (should (eq (nth 2 (car rows)) 'drgnx-ruler-view))
        (should-not (nth 2 (nth (- h 2) rows)))))))

(ert-deftest drgnx-ruler/a-scroll-moves-the-band ()
  "Scrolled to the middle, the rows sit on the lines shown now and the band is the rows of those lines."
  (ruler-test--with 1000
    (let ((h (window-body-height)))
      (setq ruler-test--marks (list (list 10 'middle 'error 1)))
      (drgnx-ruler-source 'test #'ruler-test--source)
      (goto-char (point-min)) (forward-line 499)
      (set-window-start (selected-window) (point))
      (run-hook-with-args 'window-scroll-functions (selected-window) (point))
      (let ((rows (ruler-test--rows)))
        (should (equal (mapcar #'car rows) (number-sequence 500 (+ 499 h))))
        (should (eq (nth 2 (car rows)) 'error))   ; line 10's row, outside the band
        (should (equal (cl-loop for r in rows for i from 0 when (eq (nth 2 r) 'drgnx-ruler-view) collect i)
                       (cl-loop for i below h
                                for l = (drgnx-ruler--row-lines i h)
                                when (and (<= (car l) (+ 499 h)) (>= (cdr l) 500) (/= i 0)) collect i)))
        (should (memq (floor (* 499 h) 1000)
                      (cl-loop for r in rows for i from 0 when (eq (nth 2 r) 'drgnx-ruler-view) collect i)))))))

(ert-deftest drgnx-ruler/a-short-file-is-a-row-a-line ()
  (ruler-test--with 5
    (setq ruler-test--marks (list (list 3 'left 'error 1)))
    (drgnx-ruler-source 'test #'ruler-test--source)
    (should (equal (mapcar (lambda (r) (list (car r) (nth 2 r))) (ruler-test--rows))
                   '((1 drgnx-ruler-view) (2 drgnx-ruler-view) (3 error) (4 drgnx-ruler-view) (5 drgnx-ruler-view))))))

(ert-deftest drgnx-ruler/no-marks-no-ruler ()
  "Without marks the ruler takes no margin and draws nothing; with no producer left it turns off, its hooks gone."
  (ruler-test--with 100
    (drgnx-ruler-source 'test #'ruler-test--source)
    (should drgnx-ruler-mode)
    (should (equal (window-margins) '(nil)))
    (should-not (ruler-test--rows))
    (setq ruler-test--marks (list (list 3 'left 'error 1)))
    (drgnx-ruler-refresh)
    (should (ruler-test--rows))
    (drgnx-ruler-source 'test nil)
    (should-not drgnx-ruler-mode)
    (should (equal (window-margins) '(nil)))
    (should-not (overlays-in (point-min) (point-max)))
    (should-not (memq #'drgnx-ruler--restring drgnx-margins-changed-functions))))

(ert-deftest drgnx-ruler/an-edit-asks-again-once-typing-rests ()
  (ruler-test--with 100
    (setq ruler-test--marks (list (list 3 'left 'error 1)))
    (drgnx-ruler-source 'test #'ruler-test--source)
    (setq ruler-test--marks (list (list 50 'left 'error 1)))
    (goto-char (point-max)) (insert "more\n")
    (should (drgnx-timer-active-p (cons 'ruler (current-buffer))))
    (drgnx-ruler-refresh)
    (should (= drgnx-ruler--lines 101))
    (drgnx-ruler-source 'test nil)
    (should-not (drgnx-timer-active-p (cons 'ruler (current-buffer))))))

(ert-deftest drgnx-ruler/a-click-goes-to-the-rows-line ()
  (ruler-test--with 1000
    (setq ruler-test--marks (list (list 700 'middle 'error 1)))
    (drgnx-ruler-source 'test #'ruler-test--source)
    (let* ((row (seq-find (lambda (r) (eq (nth 2 r) 'error)) (ruler-test--rows)))
           (o (seq-find (lambda (o) (= (line-number-at-pos (overlay-start o)) (car row)))
                        (cddr (assq (selected-window) drgnx-ruler--windows))))
           (s (cadr (get-text-property 0 'display (overlay-get o 'before-string)))))
      (drgnx-ruler-click (list 'mouse-1 (list (selected-window) 'right-margin '(0 . 0) 0 (cons s 0) (overlay-start o))))
      (should (= (line-number-at-pos) (nth 1 row))))))

(ert-deftest drgnx-ruler/killing-the-buffer-releases-the-hooks ()
  (let ((b (generate-new-buffer " ruler-kill")))
    (with-current-buffer b
      (insert "a\nb\n")
      (let ((ruler-test--marks (list (list 1 'left 'error 1))))
        (drgnx-ruler-source 'test #'ruler-test--source)))
    (should (memq #'drgnx-ruler--restring drgnx-margins-changed-functions))
    (kill-buffer b)
    (should-not (memq #'drgnx-ruler--restring drgnx-margins-changed-functions))))

;;; ruler-test.el ends here
