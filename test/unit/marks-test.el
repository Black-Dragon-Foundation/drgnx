;;; marks-test.el --- batch tests: the scroll bar's marks are produced once per change -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; The producers of core/drgnx-marks.el: change runs, Flymake's report, isearch hits, the Problems rows.
;; The strip they feed is core/drgnx-ruler.el's (ruler-test.el); Nidhogg draws it (glitnir-gui ruler rows).
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-marks)

(defmacro marks-test--with (&rest body)
  "BODY in a buffer of 100 lines, `drgnx-ruler-source' recorded in SOURCES ((OWNER . MARKS) each call)."
  (declare (indent 0))
  `(let ((b (generate-new-buffer " marks")) (sources nil))
     (cl-letf (((symbol-function 'drgnx-ruler-source)
                (lambda (owner fn &optional _) (push (cons owner (and fn (funcall fn))) sources))))
       (unwind-protect
           (with-current-buffer b
             (dotimes (i 100) (insert (format "line %d foo\n" (1+ i))))
             (goto-char (point-min))
             ,@body)
         (kill-buffer b)))))

(defun marks-test--pos (line) (save-excursion (goto-char (point-min)) (forward-line (1- line)) (point)))

(ert-deftest drgnx-marks/change-runs-are-one-mark-each ()
  "The change bars' per-line marks become one mark per run of lines of one kind, in the left lane, from the run's
first line to its last; a single line has no end."
  (marks-test--with
    (setq-local drgnx-hunks-mode t)
    (setq-local drgnx-hunks--marks
                (list (cons (marks-test--pos 10) (cons 10 'added)) (cons (marks-test--pos 11) (cons 11 'added))
                      (cons (marks-test--pos 12) (cons 12 'added)) (cons (marks-test--pos 13) (cons 13 'changed))
                      (cons (marks-test--pos 40) (cons 40 'deleted))))
    (drgnx-marks--hunks-drawn)
    (should (equal (cdr (assq 'hunks sources))
                   (list (list (marks-test--pos 10) 'left 'drgnx-marks-added 1 nil (marks-test--pos 12))
                         (list (marks-test--pos 13) 'left 'drgnx-marks-changed 1 nil nil)
                         (list (marks-test--pos 40) 'left 'drgnx-marks-deleted 1 nil nil))))
    ;; the bars cleared: the marks go
    (setq-local drgnx-hunks--marks nil)
    (drgnx-marks--hunks-drawn)
    (should (equal (car sources) '(hunks)))))

(ert-deftest drgnx-marks/flymake-reports-set-marks-once ()
  "Several reports in a row (one per backend) set the problem marks once, after the debounce; errors, warnings and
notes in the right lane at their priorities."
  (marks-test--with
    (let ((calls 0) (timers nil))
      (setq-local flymake-mode t)
      (cl-letf (((symbol-function 'drgnx-timer-debounce)
                 (lambda (key _delay fn &rest args) (setf (alist-get key timers nil nil #'equal) (cons fn args))))
                ((symbol-function 'flymake-diagnostics)
                 (lambda (&rest _) (cl-incf calls) (list 'e 'w)))
                ((symbol-function 'flymake-diagnostic-type) (lambda (d) d))
                ((symbol-function 'flymake-diagnostic-beg) (lambda (d) (if (eq d 'e) 5 9)))
                ((symbol-function 'flymake--lookup-type-property)
                 (lambda (type _prop &optional _) (if (eq type 'e) 'flymake-error 'flymake-warning))))
        (drgnx-marks--flymake-reported b)
        (drgnx-marks--flymake-reported b)
        (drgnx-marks--flymake-reported b)
        (should (= (length timers) 1))
        (should-not sources)
        (pcase-let ((`(,_ ,fn . ,args) (car timers))) (apply fn (plist-get args :args)))
        (should (= (length sources) 1))
        (should (equal (cdr (assq 'flymake sources))
                       '((5 right drgnx-marks-error 3) (9 right drgnx-marks-warning 2))))))))

(ert-deftest drgnx-marks/search-hits-match-how-many ()
  "An isearch's hits are the whole buffer's, as many as `how-many' counts, in the middle lane; scanned once per search
string (the same string again scans nothing); the search's end takes them away."
  (marks-test--with
    (setq-local isearch-mode t)
    (let ((isearch-string "line 1") (isearch-regexp nil) (isearch-case-fold-search nil))
      (drgnx-marks--search-scan b)
      (let ((hits (cdr (assq 'search sources))))
        (should (= (length hits) (save-excursion (goto-char (point-min)) (how-many "line 1"))))
        (should (equal (car hits) (list (marks-test--pos 1) 'middle 'drgnx-marks-hit 2))))
      (setq sources nil)
      (drgnx-marks--search-scan b)
      (should-not sources)
      (let ((isearch-string "line [0-9]+0 ") (isearch-regexp t))
        (drgnx-marks--search-scan b)
        (should (= (length (cdr (assq 'search sources))) 10))))
    (drgnx-marks--search-ended)
    (should (equal (car sources) '(search)))))

(ert-deftest drgnx-marks/list-views-carry-marks ()
  "The Problems list's error and warning rows are marks in the right lane, its notes and file headers none."
  (marks-test--with
    (erase-buffer)
    (insert "file.el  dir  2\n")
    (let ((rows '((drgnx-status-fail "✕") (drgnx-status-warn "⚠") (drgnx-status-info "ⓘ"))) starts)
      (pcase-dolist (`(,face ,glyph) rows)
        (let ((start (point)))
          (push start starts)
          (insert "    " (propertize glyph 'face face) " message\n")
          (put-text-property start (point) 'drgnx-problem (cons b 1))))
      (setq starts (nreverse starts))
      (should (equal (drgnx-marks--problem-rows)
                     (list (list (nth 0 starts) 'right 'drgnx-marks-error 3)
                           (list (nth 1 starts) 'right 'drgnx-marks-warning 2)))))))

;;; marks-test.el ends here
