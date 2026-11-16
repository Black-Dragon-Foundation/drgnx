;;; marks-test.el --- batch tests: the scroll bar's marks are produced once per change -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; The producers of core/drgnx-marks.el: change runs, Flymake's report, isearch hits, the Problems rows.
;; The strip they feed is core/drgnx-ruler.el's (ruler-test.el); Nidhogg draws it (glitnir-gui ruler rows).
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-marks)
(require 'bookmark)

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

;;;; Kinds, the line model and the next-mark keys

(defmacro marks-test--owned (&rest body)
  "BODY in a buffer of 100 lines whose marks the real owner holds (`drgnx-ruler-source' not stubbed)."
  (declare (indent 0))
  `(let ((b (generate-new-buffer " marks-owned")))
     (unwind-protect
         (with-current-buffer b
           (dotimes (i 100) (insert (format "line %d foo\n" (1+ i))))
           (goto-char (point-min))
           ,@body)
       (with-current-buffer b (drgnx-ruler-mode -1))
       (kill-buffer b))))

(defun marks-test--fixture ()
  "Marks of every kind the producers give: changes, problems, a hit, a breakpoint, a bookmark, an agent edit."
  (let ((p #'marks-test--pos))
    (drgnx-ruler-source 'hunks (lambda () (list (list (funcall p 10) 'left 'drgnx-marks-added 1 nil (funcall p 12))
                                                (list (funcall p 60) 'left 'drgnx-marks-changed 1))))
    (drgnx-ruler-source 'flymake (lambda () (list (list (funcall p 20) 'right 'drgnx-marks-error 3)
                                                  (list (funcall p 30) 'right 'drgnx-marks-warning 2)
                                                  (list (funcall p 70) 'right 'drgnx-marks-error 3))))
    (drgnx-ruler-source 'search (lambda () (list (list (funcall p 25) 'middle 'drgnx-marks-hit 2))))
    (drgnx-ruler-source 'debug (lambda () (list (list (funcall p 40) 'middle 'drgnx-debug-ruler-breakpoint 2 'dot))))
    (drgnx-ruler-source 'bookmarks (lambda () (list (list (funcall p 50) 'middle 'drgnx-marks-bookmark 2))))
    (drgnx-ruler-source 'agent (lambda () (list (list (funcall p 80) 'left 'drgnx-marks-agent 2 nil (funcall p 82)))))))

(ert-deftest drgnx-marks/each-mark-has-its-kind ()
  "A mark's kind comes from its face (a problem's severity), else its producer; kinds not shown are left out."
  (marks-test--owned
    (marks-test--fixture)
    (let ((kinds (mapcar (lambda (m) (cons (line-number-at-pos (car m)) (nth 6 m)))
                         (sort (copy-sequence drgnx-ruler--marks) (lambda (a c) (< (car a) (car c)))))))
      (should (equal kinds '((10 . change) (20 . error) (25 . hit) (30 . warning) (40 . breakpoint) (50 . bookmark)
                             (60 . change) (70 . error) (80 . agent)))))
    (let ((drgnx-marks-kinds '(error)))
      (drgnx-ruler-refresh)
      (should (equal (mapcar (lambda (m) (nth 6 m)) drgnx-ruler--marks) '(error error))))))

(defun marks-test--steps (kinds dir n)
  "The lines N steps of KINDS in DIR visit from line 1, each with what it said."
  (goto-char (point-min))
  (let (out)
    (dotimes (_ n (nreverse out))
      (let ((pos (drgnx-marks-step kinds dir)))
        (push (cons (and pos (line-number-at-pos pos)) (drgnx-marks-announcement (point) kinds)) out)))))

(defun marks-test--check-steps ()
  "The next-mark keys over the fixture: per kind, all kinds, backwards, wrapping, and the words said."
  (marks-test--fixture)
  (should (equal (mapcar #'car (marks-test--steps '(change) 1 3)) '(10 60 10)))
  (should (equal (mapcar #'car (marks-test--steps '(error warning info) 1 4)) '(20 30 70 20)))
  (should (equal (mapcar #'car (marks-test--steps '(error warning info) -1 2)) '(70 30)))
  (should (equal (mapcar #'car (marks-test--steps '(bookmark) 1 1)) '(50)))
  (should (equal (mapcar #'car (marks-test--steps '(agent) 1 1)) '(80)))
  (should (equal (mapcar #'car (marks-test--steps drgnx-marks-kinds 1 9)) '(10 20 25 30 40 50 60 70 80)))
  (should (equal (cdr (car (marks-test--steps '(change) 1 1))) "change 1 of 2, line 10"))
  (cl-letf (((symbol-function 'drgnx-marks--message)
             (lambda (pos kind) (and (eq kind 'error) (= pos (marks-test--pos 70)) "unused variable `x'"))))
    (goto-char (marks-test--pos 31))
    (drgnx-marks-step '(error warning info) 1)
    (should (equal (drgnx-marks-announcement (point) '(error warning info))
                   "error 3 of 3: unused variable `x', line 70")))
  ;; a kind with no marks says so and stays
  (goto-char (point-min))
  (should-not (drgnx-marks-step '(pin) 1))
  (should (= (point) (point-min))))

(ert-deftest drgnx-marks/next-and-previous-by-kind ()
  "Next and previous per kind and over all kinds, wrapping at the ends, from the marks as last asked."
  (marks-test--owned
    (cl-letf (((symbol-function 'drgnx-marks--model-p) #'ignore))
      (marks-test--check-steps))))

(ert-deftest drgnx-marks/the-line-model-answers-the-keys ()
  "On Nidhogg the owner gives the line model each kind's marks, once per change of that kind; the model answers the
next-mark keys, and an edit moves the marks without asking the producers again."
  (skip-unless (fboundp 'nidhogg-lines-set-marks))
  (marks-test--owned
    (let ((sets 0))
      (advice-add 'nidhogg-lines-set-marks :before (lambda (&rest _) (cl-incf sets)) '((name . marks-test-count)))
      (unwind-protect
          (progn
            (marks-test--fixture)
            (should (drgnx-marks--model-p))
            ;; every kind was set as it came, and asking again with nothing changed sets nothing
            (let ((before sets))
              (drgnx-ruler-refresh)
              (should (= sets before)))
            ;; an edit above every mark: the model's marks move with it
            (let ((at (marks-test--pos 10)))
              (goto-char (point-min))
              (insert "new
lines
")
              (should (= (nidhogg-lines-next-mark nil 1 (list (cl-position 'change drgnx-ruler-kinds)))
                         (+ 10 at)))))
        (advice-remove 'nidhogg-lines-set-marks 'marks-test-count)))
    (erase-buffer)
    (dotimes (i 100) (insert (format "line %d foo\n" (1+ i))))
    (marks-test--check-steps)))

(ert-deftest drgnx-marks/bookmarks-agent-edits-and-symbol-uses ()
  "The new producers: a bookmark in the file, an agent's change (from the edit history's drain, shifted by the
changes after it), the uses of the symbol at point."
  (marks-test--with
    (let ((file (make-temp-file "marks-test" nil ".el")))
      (unwind-protect
          (progn
            (setq buffer-file-name file)
            (let ((bookmark-alist `(("here" (filename . ,file) (position . 42))
                                    ("elsewhere" (filename . "/nowhere.el") (position . 7)))))
              (drgnx-marks--bookmarks-now))
            (should (equal (cdr (assq 'bookmarks sources)) '((42 middle drgnx-marks-bookmark 2))))
            ;; an agent inserted 5 characters at 0-based 100, then the user inserted 3 before it
            (drgnx-marks--agent-drained b 1 '((:start 100 :old_len 0 :inserted "abcde" :origin "agent:s#1")
                                              (:start 10 :old_len 0 :inserted "xyz")
                                              (:start 300 :old_len 2 :inserted "q" :origin "external:disk")))
            (should (equal (cdr (assq 'agent sources)) '((104 left drgnx-marks-agent 2 nil 109))))
            (drgnx-marks--agent-clear)
            ;; symbol uses: "foo" on each of the 100 lines
            (emacs-lisp-mode)
            (goto-char (+ (marks-test--pos 3) 7))
            (drgnx-marks--symbol-scan)
            (should (= (length (cdr (assq 'symbol sources))) 100)))
        (setq buffer-file-name nil)
        (delete-file file)))))

;;; marks-test.el ends here
