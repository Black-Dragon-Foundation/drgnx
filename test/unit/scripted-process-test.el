;;; scripted-process-test.el --- scripted processes force the class C orderings -*- lexical-binding: t -*-
;; Each ordering is forced 100 times and asserted every time: under load it would only happen sometimes.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/scripted-process" drgnx-dir) nil t)

(defvar drgnx-proc-test--log nil "What the filter and sentinel saw, newest first.")

(defun drgnx-proc-test--start (name &optional filter)
  "Scripted process NAME logging to a fresh `drgnx-proc-test--log' (FILTER or a logging one); done flag `:done'."
  (setq drgnx-proc-test--log nil)
  (drgnx-test-scripted-process
   name
   :filter (or filter (lambda (_p s) (push (list :out s) drgnx-proc-test--log)))
   :sentinel (lambda (p event) (push (list :sentinel event) drgnx-proc-test--log) (process-put p :done t))))

(defun drgnx-proc-test--done (p)
  "Wait for P's sentinel to have run; return the log, oldest first."
  (drgnx-test-wait (lambda () (process-get p :done)) :what (format "%s's sentinel" (process-name p)))
  (reverse drgnx-proc-test--log))

(ert-deftest drgnx-test-proc/output-then-exit-before-emacs-reads ()
  "M3b-19: the child wrote and exited before Emacs read anything.  `process-live-p' is already nil while the
sentinel has not run; the filter then gets all the output, and the sentinel runs after it."
  (dotimes (i 100)
    (let ((p (drgnx-proc-test--start "scripted-output-exit")))
      (drgnx-test-proc-emit p "one\n")
      (drgnx-test-proc-emit p "two\n")
      (drgnx-test-proc-exit p 0 :before-read t)
      (should (equal (list i (process-live-p p) drgnx-proc-test--log) (list i nil nil)))
      (let ((log (drgnx-proc-test--done p)))
        (should (equal (list i (mapconcat #'cadr (butlast log) "") (car (last log)))
                       (list i "one\ntwo\n" '(:sentinel "finished\n"))))
        (should (cl-every (lambda (e) (eq (car e) :out)) (butlast log)))))))

(ert-deftest drgnx-test-proc/sentinel-before-the-last-filter-call ()
  "The sentinel runs before the filter call that was handling the output has returned.
Emacs never calls a filter after the sentinel: before it runs the sentinel it reads all the output left and closes
the pipe (status_notify).  So the ordering is forced the way it happens: the filter waits (a nested
`accept-process-output', as a synchronous call in a filter does) while the child writes its last text and exits.
The nested wait delivers that text, then runs the sentinel, and only then does the first filter call go on."
  (dotimes (i 100)
    (let ((p (drgnx-proc-test--start
              "scripted-sentinel-first"
              (lambda (p s)
                (push (list :enter s) drgnx-proc-test--log)
                (when (equal s "first")
                  (drgnx-test-proc-emit p "last")
                  (drgnx-test-proc-exit p 0 :before-read t)
                  (accept-process-output nil 0))
                (push (list :leave s) drgnx-proc-test--log)))))
      (drgnx-test-proc-emit p "first")
      (should (equal (cons i (drgnx-proc-test--done p))
                     (list i '(:enter "first") '(:enter "last") '(:leave "last") '(:sentinel "finished\n")
                           '(:leave "first")))))))

(ert-deftest drgnx-test-proc/send-eof-after-exit ()
  "A-44: `process-send-eof' on a child that has already exited signals \"not running\", as the git runner hit;
before its sentinel has run and after."
  (dotimes (i 100)
    (let ((p (drgnx-proc-test--start "scripted-eof")))
      (drgnx-test-proc-exit p 0 :before-read t)
      (should (equal (list i (cadr (should-error (process-send-eof p))))
                     (list i "Process scripted-eof not running: finished\n")))
      (drgnx-proc-test--done p)
      (should (equal (list i (cadr (should-error (process-send-eof p))))
                     (list i "Process scripted-eof not running: finished\n"))))))

(ert-deftest drgnx-test-proc/stdin-is-the-processs-own ()
  "`process-send-string' and `process-send-eof' reach the child while it runs, as they would a real child."
  (let ((p (drgnx-proc-test--start "scripted-stdin")))
    (process-send-string p "ignored\n")
    (process-send-eof p)
    (drgnx-test-proc-emit p "still here")
    (drgnx-test-proc-exit p 3)
    (should (equal (drgnx-proc-test--done p) '((:out "still here") (:sentinel "exited abnormally with code 3\n"))))))

(ert-deftest drgnx-test-proc/nothing-outside-the-run-dir ()
  "The FIFO and the emitted text live in a directory under `temporary-file-directory', which the child removes."
  (let* ((p (drgnx-proc-test--start "scripted-dir"))
         (dir (process-get p :drgnx-test-proc-dir)))
    (should (file-in-directory-p dir temporary-file-directory))
    (should (string-prefix-p "p" (file-attribute-modes (file-attributes (expand-file-name "ctl" dir)))))
    (drgnx-test-proc-emit p "x")
    (drgnx-test-proc-exit p 0)
    (drgnx-proc-test--done p)
    (should-not (file-exists-p dir))
    (should-error (drgnx-test-proc-emit p "after the exit"))))
