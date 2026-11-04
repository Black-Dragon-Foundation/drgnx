;;; handshake-fixture.el --- a real child that waits for the test after each state it reports -*- lexical-binding: t -*-
;; A child announces a state with a line `DRGNX-STATE: NAME' on its standard output and then waits for a line `GO' on its
;; standard input: it is parked.  The test awaits the announcement (`drgnx-test-child-await'), asserts or signals the
;; parked child, and lets it go (`drgnx-test-child-go').  Only a parked child may be signalled: it is alive and not
;; yet reaped, so its pid cannot belong to anyone else.  A child Emacs loads this file with `-l' and calls
;; `drgnx-test-child-announce'.  docs/develop/harness.md, "Announce and park"
(require 'cl-lib)

(defconst drgnx-handshake--dir (file-name-directory (or load-file-name (macroexp-file-name)))
  "The directory of this file.")

(defconst drgnx-handshake--prefix "DRGNX-STATE: " "The start of an announcement line.")

;; child side

(defun drgnx-test-child-announce (state)
  "Say STATE on the standard output, then read standard input until a line `GO'.  For a child Emacs, loaded with `-l'."
  (send-string-to-terminal (format "%s%s\n" drgnx-handshake--prefix state))
  (while (not (equal (read-string "") "GO"))))

;; test side

(declare-function drgnx-test-wait "wait-fixture")

(defun drgnx-handshake--filter (proc text)
  "Process filter of a child: record each announcement line of TEXT, ignore the rest."
  (let ((lines (split-string (concat (process-get proc :hs-partial) text) "\n")))
    (process-put proc :hs-partial (car (last lines)))
    (dolist (line (butlast lines))
      (when (string-prefix-p drgnx-handshake--prefix line)
        (process-put proc :hs-state (substring line (length drgnx-handshake--prefix)))
        (process-put proc :hs-signals nil)
        (process-put proc :hs-parked t)))))

(cl-defun drgnx-test-child-start (&key name command shim group)
  "Start COMMAND (a list: program and arguments) as a child that speaks the announce-and-park protocol; return the process.
A child announces `DRGNX-STATE: NAME' lines on stdout and, after each, waits for a line `GO' on stdin.
SHIM, non-nil, wraps COMMAND, a third-party binary, in `handshake-shim.sh', which announces RUNNING once the job is
started and, after the job and its whole group are gone, STOPPED, and parks after each (the job runs on while the shim
is parked at RUNNING; the shim waits for it only after GO).  GROUP, non-nil, runs it in its own process group, which
is the shim too."
  (let ((command (if (or shim group)
                     (append (list "sh" (expand-file-name "handshake-shim.sh" drgnx-handshake--dir)) command)
                   command)))
    ;; the test drives it: a peer, which the delivery gate never waits on for the code under test
    (let ((p (make-process :name (or name "drgnx-test-child") :command command :connection-type 'pipe :noquery t
                           :coding 'utf-8-unix :filter #'drgnx-handshake--filter)))
      (process-put p :drgnx-test-peer t)
      p)))

(defun drgnx-test-child-parked-p (proc)
  "Non-nil when PROC has announced a state and has not been sent GO since."
  (and (process-get proc :hs-parked) t))

(cl-defun drgnx-test-child-await (proc state &key (secs 30))
  "Wait until PROC has announced STATE; the child is then parked.  SECS bounds a failure."
  (require 'drgnx-wait-fixture (expand-file-name "wait-fixture" drgnx-handshake--dir))
  (drgnx-test-wait (lambda () (and (drgnx-test-child-parked-p proc) (equal (process-get proc :hs-state) state)))
                   :secs secs :what (format "child %s to announce %s" (process-name proc) state)))

(defun drgnx-test-child-go (proc)
  "Send PROC the line `GO': it is no longer parked.  Signals an error when it is not parked."
  (unless (drgnx-test-child-parked-p proc)
    (error "drgnx-test-child-go: %s is not parked (await its announcement first)" (process-name proc)))
  (process-put proc :hs-parked nil)
  (process-send-string proc "GO\n"))

(defun drgnx-test-child-signal (proc sig)
  "Send SIG (a symbol or number) to PROC, which must be parked, and not have had SIG since its last announcement.
Otherwise signal an error naming the rule: a child that is not parked may be gone and its pid reused."
  (unless (drgnx-test-child-parked-p proc)
    (error "drgnx-test-child-signal: only a parked child may be signalled; %s is not parked (await an announcement)"
           (process-name proc)))
  (when (memq sig (process-get proc :hs-signals))
    (error "drgnx-test-child-signal: %s has had %s since its last announcement; await another before signalling it again"
           (process-name proc) sig))
  (process-put proc :hs-signals (cons sig (process-get proc :hs-signals)))
  (signal-process proc sig))

(provide 'drgnx-handshake-fixture)
;;; handshake-fixture.el ends here
