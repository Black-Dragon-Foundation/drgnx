;;; scripted-process.el --- a child process that only does what the test says -*- lexical-binding: t -*-
;; `drgnx-test-scripted-process' starts a `sh' child that waits for commands on a FIFO in the run's temp directory
;; and does nothing else: `drgnx-test-proc-emit' makes it write text to its stdout, `drgnx-test-proc-exit' makes it
;; exit.  A test then forces the orderings that otherwise show up only under load (class C): output and exit both
;; pending when Emacs next reads, the sentinel inside a filter call, `process-send-eof' after the exit.
(require 'ert)
(require 'cl-lib)
;; `drgnx-test-wait--now' (real seconds, also inside the clock fixture) and `drgnx-uitest-settle-scale'
(require 'drgnx-wait-fixture (expand-file-name "wait-fixture" (file-name-directory (macroexp-file-name))))

(defconst drgnx-test-proc--script
  "d=$1
trap 'rm -rf \"$d\"' EXIT
trap 'exit 143' HUP INT TERM
while :; do
  while read -r cmd arg; do
    case $cmd in
      emit) cat \"$d/$arg\" && rm -f \"$d/$arg\" ;;
      exit) exit \"$arg\" ;;
    esac
  done < \"$d/ctl\"
done"
  "The child: it reads one command per line from the FIFO $1/ctl, reopening it after each writer, and removes $1
when it exits.  `emit N' writes the file $1/N to stdout; `exit CODE' exits.  Its stdin is left alone.")

(cl-defun drgnx-test-scripted-process (name &key buffer filter sentinel)
  "Start a scripted child process called NAME with BUFFER, FILTER and SENTINEL; return it.
The child does only what `drgnx-test-proc-emit' and `drgnx-test-proc-exit' tell it, through a FIFO in a fresh
directory under `temporary-file-directory' (the process property `:drgnx-test-proc-dir').  Its stdin is the
process's own, so `process-send-string' and `process-send-eof' reach it as they would a real child."
  (let* ((dir (make-temp-file "drgnx-proc-" t))
         (ctl (expand-file-name "ctl" dir)))
    (unless (eq 0 (call-process "mkfifo" nil nil nil ctl))
      (error "drgnx-test-scripted-process: mkfifo %s failed" ctl))
    (let ((p (make-process :name name :buffer buffer :filter filter :sentinel sentinel :noquery t
                           :connection-type 'pipe :coding 'utf-8-unix
                           :command (list "sh" "-c" drgnx-test-proc--script name dir))))
      (process-put p :drgnx-test-proc-dir dir)
      (process-put p :drgnx-test-proc-n 0)
      p)))

(defun drgnx-test-proc--send (p command)
  "Write the line COMMAND to P's FIFO.  Opening it blocks until the child reads it, so P must not have exited."
  (when (or (process-get p :drgnx-test-proc-exiting) (not (process-live-p p)))
    (error "drgnx-test-proc: %s has exited (or been told to)" (process-name p)))
  (let ((coding-system-for-write 'utf-8-unix))
    (write-region (concat command "\n") nil (expand-file-name "ctl" (process-get p :drgnx-test-proc-dir))
                  t 'silent)))

(defun drgnx-test-proc-emit (p text)
  "Make the scripted process P write TEXT to its stdout.  Return at once: the child writes it in order."
  (let ((n (1+ (process-get p :drgnx-test-proc-n)))
        (coding-system-for-write 'utf-8-unix))
    (process-put p :drgnx-test-proc-n n)
    (write-region text nil (expand-file-name (number-to-string n) (process-get p :drgnx-test-proc-dir)) nil 'silent)
    (drgnx-test-proc--send p (format "emit %d" n))))

(cl-defun drgnx-test-proc-exit (p code &key before-read (secs 30))
  "Make the scripted process P exit with CODE, after everything it was told before.
Without BEFORE-READ, return at once (wait for the sentinel's done flag with `drgnx-test-wait').  With BEFORE-READ,
return only once Emacs has recorded the exit, without reading P's output or running a filter, sentinel or timer:
P's output and its exit are then all pending when Emacs next reads.  That wait blocks in `call-process' and fails
after SECS times `drgnx-uitest-settle-scale' real seconds."
  (drgnx-test-proc--send p (format "exit %d" code))
  (process-put p :drgnx-test-proc-exiting t)
  (when before-read
    (let ((deadline (+ (drgnx-test-wait--now) (* secs (drgnx-uitest-settle-scale)))))
      ;; `process-live-p' only decodes the status Emacs's SIGCHLD handler recorded (it reaps children even while
      ;; `call-process' blocks); `call-process' reads no other process's output.
      (while (process-live-p p)
        (when (> (drgnx-test-wait--now) deadline)
          (signal 'ert-test-failed (list :waited-for (format "%s to exit" (process-name p)) :secs secs)))
        (call-process "sleep" nil nil nil "0.005")))))

(provide 'drgnx-scripted-process)
