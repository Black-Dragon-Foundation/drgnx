;;; held-fixture.el --- a child process that lasts until the test lets it go -*- lexical-binding: t -*-
;; A test that asserts something about a process while it runs cannot ask the real program to be slow: a fast
;; machine finishes it before the look.  `drgnx-test-with-held' puts a stand-in for PROGRAM first on `exec-path'
;; that reads one line of its standard input and then runs the real PROGRAM with the same arguments, so the run is
;; live until `drgnx-test-release'.  It needs a run started by name (`make-process', `start-process'), with its
;; standard input a pipe or a pty from Emacs; a synchronous `call-process' would wait forever.  docs/develop/harness.md, "Test classes"
(require 'ert)

(defmacro drgnx-test-with-held (program &rest body)
  "BODY with the first run of PROGRAM (a name on `exec-path') started inside it held at its start.
The held run reads one line of its standard input before it runs the real PROGRAM; `drgnx-test-release' sends that
line.  Runs after the first go straight through."
  (declare (indent 1))
  (let ((dir (make-symbol "dir")) (hold (make-symbol "hold")) (stand-in (make-symbol "stand-in"))
        (real (make-symbol "real")))
    `(let* ((,real (or (executable-find ,program) (error "drgnx-test-with-held: no %s on exec-path" ,program)))
            (,dir (make-temp-file "drgnx-held" t))
            (,hold (expand-file-name "hold" ,dir))
            (,stand-in (expand-file-name ,program ,dir))
            (exec-path (cons ,dir exec-path)))
       (unwind-protect
           (progn
             (write-region (format "#!/bin/sh\nif [ -e %s ]; then rm -f %s; read _; fi\nexec %s \"$@\"\n"
                                   (shell-quote-argument ,hold) (shell-quote-argument ,hold)
                                   (shell-quote-argument ,real))
                           nil ,stand-in nil 'silent)
             (set-file-modes ,stand-in #o755)
             (write-region "" nil ,hold nil 'silent)
             ,@body)
         (delete-directory ,dir t)))))

(defun drgnx-test-release (proc)
  "Let PROC, a run `drgnx-test-with-held' holds, go on to the real program."
  (process-send-string proc "\n"))

(defvar drgnx-test-held-gate nil
  "The FIFO the run held by `drgnx-test-with-held-gate' waits on, while BODY runs.")

(defmacro drgnx-test-with-held-gate (program &rest body)
  "Like `drgnx-test-with-held', for a run whose code closes its standard input at once (`process-send-eof').
The stand-in waits for the release on a FIFO of its own, `drgnx-test-held-gate', instead of a line on its standard
input; `drgnx-test-release-gate' lets it go.  Needs mkfifo."
  (declare (indent 1))
  (let ((dir (make-symbol "dir")) (hold (make-symbol "hold")) (stand-in (make-symbol "stand-in"))
        (real (make-symbol "real")))
    `(let* ((,real (or (executable-find ,program) (error "drgnx-test-with-held-gate: no %s on exec-path" ,program)))
            (,dir (make-temp-file "drgnx-held" t))
            (,hold (expand-file-name "hold" ,dir))
            (,stand-in (expand-file-name ,program ,dir))
            (drgnx-test-held-gate (expand-file-name "gate" ,dir))
            (exec-path (cons ,dir exec-path)))
       (unwind-protect
           (progn
             (unless (eql 0 (call-process "mkfifo" nil nil nil drgnx-test-held-gate))
               (error "drgnx-test-with-held-gate: no mkfifo"))
             (write-region (format "#!/bin/sh\nif [ -e %s ]; then rm -f %s; read _ < %s; fi\nexec %s \"$@\"\n"
                                   (shell-quote-argument ,hold) (shell-quote-argument ,hold)
                                   (shell-quote-argument drgnx-test-held-gate) (shell-quote-argument ,real))
                           nil ,stand-in nil 'silent)
             (set-file-modes ,stand-in #o755)
             (write-region "" nil ,hold nil 'silent)
             ,@body)
         (delete-directory ,dir t)))))

(defun drgnx-test-release-gate ()
  "Let the run `drgnx-test-with-held-gate' holds go on to the real program."
  (make-process :name "drgnx-held-release" :noquery t :buffer nil
                :command (list "sh" "-c" (format "echo > %s" (shell-quote-argument drgnx-test-held-gate)))))

(provide 'held-fixture)
;;; held-fixture.el ends here
