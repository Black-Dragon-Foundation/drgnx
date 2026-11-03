;;; gate-fixture.el --- children that start their work together, on the test's word -*- lexical-binding: t -*-
;; A test that races several child Emacsen against one file starts them all, waits until each is loaded and idle at a
;; gate, then opens every gate at once.  Nothing sleeps until a guessed time: a child's work begins when the test has
;; seen every child ready.  `drgnx-test-gate-form' is the first form of a child's work (a batch Emacs started with a
;; pipe for its standard input, `:connection-type' `pipe'); `drgnx-test-gate-open' opens the gates.
;; docs/develop/harness.md, "Gated children"
(require 'cl-lib)
(require 'drgnx-wait-fixture (expand-file-name "wait-fixture" (file-name-directory (macroexp-file-name))))

(defconst drgnx-test-gate-ready "DRGNX-GATE-READY"
  "What a child says on its error stream when it is at the gate.")

(defconst drgnx-test-gate-form
  (format "(progn (message %S) (read-string \"\"))" drgnx-test-gate-ready)
  "A form for a child to run first: say it is ready, then wait for one line of its standard input.")

(defun drgnx-test-gate-open (procs &optional secs)
  "Wait until every process in PROCS, children running `drgnx-test-gate-form', is at its gate, then open every gate.
Each child's output goes to its process buffer (the default filter).  SECS bounds a failure (default 30)."
  (drgnx-test-wait
   (lambda ()
     (cl-every (lambda (p)
                 (with-current-buffer (process-buffer p)
                   (save-excursion (goto-char (point-min)) (search-forward drgnx-test-gate-ready nil t))))
               procs))
   :secs (or secs 30) :what "every child at its gate")
  (dolist (p procs) (process-send-string p "\n")))

(provide 'drgnx-gate-fixture)
;;; gate-fixture.el ends here
