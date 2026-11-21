;;; palette-pick-test.el --- the palette's list in Sjá: loaded once per open, picked per key, nothing kept -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D (pure): `nidhogg-view-pick' is Sjá's (the door's own test is Nidhogg's); here a recording stand-in counts
;; what the palette asks of it, and a real Sjá, when this Emacs has one, ranks as the Lisp sort did.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-palette)
(require 'nidhogg-views nil t)

(defmacro palette-pick-test--with-commands (&rest body)
  "BODY with a registry of its own: three commands, one run lately."
  (declare (indent 0))
  `(let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
         (drgnx-palette--history nil))
     (pcase-dolist (`(,id ,title ,cat) '((split-right "Split Right" "Window") (split-down "Split Editor Down" "View")
                                         (sidebar "Toggle Sidebar" "View")))
       (drgnx-command-define id :title title :category cat :command #'ignore))
     (setq drgnx-palette--history (list (list 'split-right (floor (float-time)))))
     (cl-letf (((symbol-function 'drgnx-palette-files) (lambda () nil)))
       ,@body)))

(ert-deftest drgnx-palette-pick/the-list-is-loaded-once-per-open-and-dropped-at-close ()
  "The labels' text is built and loaded once when the palette opens, not per key; each new input is one pick and a
repeated one none; each row is dressed once however often it is shown; at close the list is closed in Sjá and the
palette keeps no row of it."
  (palette-pick-test--with-commands
    (let ((calls nil) (dressed 0) (orig (symbol-function 'drgnx-palette--annotation)))
      (cl-letf (((symbol-function 'nidhogg-view-pick)
                 (lambda (what &optional a b _c)
                   (push (list what (if (eq what 'load) (length (split-string a "\n" t)) a) b) calls)
                   (pcase what ('load 7) ('top '(1 0)) ('close nil))))
                ((symbol-function 'drgnx-palette--annotation)
                 (lambda (&rest args) (cl-incf dressed) (apply orig args)))
                ((symbol-function 'completing-read)
                 (lambda (_prompt table &rest _)
                   (let ((annotate (alist-get 'annotation-function (cdr (funcall table "" nil 'metadata)))))
                     (should (equal (all-completions "" table nil) '("View: Split Editor Down" "Window: Split Right")))
                     (all-completions "" table nil)
                     (all-completions "spl" table nil)
                     (dotimes (_ 3) (funcall annotate "Window: Split Right")))
                   "")))
        (drgnx-palette))
      (setq calls (nreverse calls))
      (should (equal (seq-filter (lambda (c) (eq (car c) 'load)) calls) '((load 3 nil))))
      (should (equal (mapcar #'caddr (seq-filter (lambda (c) (eq (car c) 'top)) calls)) '("" "spl")))
      (should (equal (car (last calls)) '(close 7 nil)))
      (should (= dressed 1))
      (should-not drgnx-palette--pick)
      (should-not drgnx-palette--memo))))

(ert-deftest drgnx-palette-pick/the-ask-row-comes-last ()
  "The row that asks an agent with what is typed follows Sjá's rows: the fallback, never first while a row matches."
  (palette-pick-test--with-commands
    (drgnx-command-define 'agents-ask :title "Ask an Agent…" :category "Agents" :command #'ignore)
    (cl-letf (((symbol-function 'nidhogg-view-pick) (lambda (&rest _) '(1 0))))
      (let ((drgnx-palette--pick (list 7 ["Window: Split Right" "View: Split Editor Down"] nil)))
        (should (equal (drgnx-palette--pick-labels "split")
                       (list "View: Split Editor Down" "Window: Split Right" (drgnx-palette-ask-label "split"))))))))

(ert-deftest drgnx-palette-pick/the-loaded-text-names-kind-recency-and-label ()
  "A command's line is 0, its place in the recent runs (or -1) and its label; a file's is 1."
  (palette-pick-test--with-commands
    (let* ((cands (drgnx-palette-candidates))
           (text (drgnx-palette--pick-text cands '(("File: a.el" . "/r/a.el")))))
      (should (equal (split-string text "\n" t)
                     '("0\t0\tWindow: Split Right" "0\t-1\tView: Split Editor Down" "0\t-1\tView: Toggle Sidebar"
                       "1\t-1\tFile: a.el"))))))

(ert-deftest drgnx-palette-pick/sja-ranks-as-the-lisp-sort ()
  "Sjá's pick gives the order the Lisp sort (frozen) gives: recent first with nothing typed, the match first with text."
  (skip-unless (fboundp 'nidhogg-view-pick))
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
    (pcase-dolist (`(,id ,title ,cat) '((run-file "Run Tests in This File" "Tests") (run-point "Run Test at Point" "Tests")
                                        (rerun "Rerun Last Tests" "Tests") (run-term "Run in Terminal…" "Terminal")
                                        (rotate "Rotate Cloud CA" "Runners") (ask "New Session" "Agents")))
      (drgnx-command-define id :title title :category cat :command #'ignore))
    (let* ((drgnx-palette--history (list (list 'rerun (- (floor (float-time)) 125))))
           (cands (drgnx-palette-candidates))
           (labels (vconcat (mapcar #'car cands)))
           (h (nidhogg-view-pick 'load (drgnx-palette--pick-text cands nil))))
      (unwind-protect
          (dolist (input '("" "run te" "run in" "te"))
            (should (equal (mapcar (lambda (i) (aref labels i)) (nidhogg-view-pick 'top h input 100))
                           (drgnx-palette-sort (palette-pick-test--matching input cands) cands nil input))))
        (nidhogg-view-pick 'close h)))))

(defun palette-pick-test--matching (input cands)
  "The labels of CANDS that hold every word of INPUT (any case): what orderless gave the Lisp sort."
  (let ((words (split-string (downcase input) "[ \t]+" t)))
    (seq-filter (lambda (l) (seq-every-p (lambda (w) (string-search w (downcase l))) words)) (mapcar #'car cands))))

(provide 'palette-pick-test)
;;; palette-pick-test.el ends here
