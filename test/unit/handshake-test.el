;;; handshake-test.el --- announce and park -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/handshake-fixture" drgnx-dir) nil t)

(defun drgnx-handshake-test--sh (script)
  "A child command: `sh' running SCRIPT, which announces with the function `say' and parks with `park'."
  (list "sh" "-c" (concat "say() { printf 'DRGNX-STATE: %s\\n' \"$1\"; }; park() { read -r go; }; " script)))

(defmacro drgnx-handshake-test--with-child (var args &rest body)
  "BODY with VAR a child started with ARGS (`drgnx-test-child-start' keys), deleted afterwards."
  (declare (indent 2))
  `(let ((,var (apply #'drgnx-test-child-start ,args)))
     (unwind-protect (progn ,@body)
       (delete-process ,var))))

(defun drgnx-handshake-test--alive-p (pid)
  "Non-nil when process PID exists and is not a zombie."
  (let ((stat (format "/proc/%d/stat" pid)))
    (if (file-exists-p "/proc/self/stat")
        (and (file-exists-p stat)
             (with-temp-buffer
               (insert-file-contents stat)
               (not (string-match-p ") Z " (buffer-string)))))
      (zerop (call-process "kill" nil nil nil "-0" (number-to-string pid))))))

(ert-deftest drgnx-handshake/a-child-parks-after-each-announcement ()
  (drgnx-handshake-test--with-child child
      (list :command (drgnx-handshake-test--sh "say one; park; say two; park"))
    (should-not (drgnx-test-child-parked-p child))
    (drgnx-test-child-await child "one")
    (should (drgnx-test-child-parked-p child))
    (drgnx-test-child-go child)
    (should-not (drgnx-test-child-parked-p child))
    (drgnx-test-child-await child "two")
    (should (drgnx-test-child-parked-p child))))

(ert-deftest drgnx-handshake/signal-refuses-an-unparked-child ()
  (drgnx-handshake-test--with-child child
      (list :command (drgnx-handshake-test--sh "say one; park; say two; park"))
    (should-error (drgnx-test-child-signal child 'usr1))
    (drgnx-test-child-await child "one")
    (drgnx-test-child-go child)
    (let ((err (should-error (drgnx-test-child-signal child 'usr1))))
      (should (string-match-p "only a parked child" (error-message-string err))))))

(ert-deftest drgnx-handshake/signal-refuses-a-second-same-signal-before-an-announcement ()
  (drgnx-handshake-test--with-child child
      (list :command (drgnx-handshake-test--sh "trap '' USR1 USR2; say one; park; say two; park"))
    (drgnx-test-child-await child "one")
    (drgnx-test-child-signal child 'usr1)
    (let ((err (should-error (drgnx-test-child-signal child 'usr1))))
      (should (string-match-p "since its last announcement" (error-message-string err))))
    (drgnx-test-child-signal child 'usr2)
    (drgnx-test-child-go child)
    (drgnx-test-child-await child "two")
    (drgnx-test-child-signal child 'usr1)))

(ert-deftest drgnx-handshake/stopped-means-the-whole-group-ended ()
  (let* ((pidfile (make-temp-file "drgnx-handshake-pid"))
         (script (format "sleep 3600 & echo $! > %s; wait" (shell-quote-argument pidfile))))
    (unwind-protect
        (drgnx-handshake-test--with-child child (list :command (list "sh" "-c" script) :group t)
          (drgnx-test-child-await child "RUNNING")
          (let ((pid (drgnx-test-wait
                      (lambda ()
                        (with-temp-buffer
                          (insert-file-contents pidfile)
                          (and (string-match-p "\n" (buffer-string)) (string-to-number (buffer-string)))))
                      :what "the grandchild's pid")))
            (should (drgnx-handshake-test--alive-p pid))
            (drgnx-test-child-signal child 'term)
            (drgnx-test-child-go child)
            (drgnx-test-child-await child "STOPPED")
            (should-not (drgnx-handshake-test--alive-p pid))))
      (delete-file pidfile))))

(ert-deftest drgnx-handshake/a-shim-parks-at-running-until-go ()
  "The shim's RUNNING is a park: a job that ends at once leaves the shim at RUNNING, saying nothing more, until the test
sends GO; then STOPPED, parked again, and it exits only after the next GO."
  (drgnx-handshake-test--with-child child (list :command (list "true") :shim t)
    (process-put child :exit nil)
    (set-process-sentinel child (lambda (p _e) (when (memq (process-status p) '(exit signal))
                                                 (process-put p :exit (process-exit-status p)))))
    (drgnx-test-child-await child "RUNNING" :secs 5)
    (drgnx-test-child-go child)
    (drgnx-test-child-await child "STOPPED")
    (should-not (process-get child :exit))
    (drgnx-test-child-go child)
    (drgnx-test-wait (lambda () (process-get child :exit)) :what "the shim's exit, after its last GO")
    (should (eql 0 (process-get child :exit)))))

(ert-deftest drgnx-handshake/a-child-emacs-announces-from-lisp ()
  (drgnx-handshake-test--with-child child
      (list :command (list (expand-file-name invocation-name invocation-directory) "-Q" "--batch"
                           "-l" (expand-file-name "test/fixtures/handshake-fixture.el" drgnx-dir)
                           "--eval" "(progn (drgnx-test-child-announce \"loaded\") (drgnx-test-child-announce \"done\"))"))
    (drgnx-test-child-await child "loaded")
    (drgnx-test-child-go child)
    (drgnx-test-child-await child "done")
    (should (drgnx-test-child-parked-p child))))

;;; handshake-test.el ends here
