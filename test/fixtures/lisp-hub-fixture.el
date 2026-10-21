;;; lisp-hub-fixture.el --- start the Lisp hub as `drgnx-hub-ensure' did before Ratatoskr -*- lexical-binding: t -*-
;; `drgnx-hub-ensure' starts Ratatoskr now.  The Lisp hub's server half stays until the runtime replaces it, and its tests
;; (hub-test.el, the mirror tests) still need one started the way an editor once started it: a durable job, SIGPIPE ignored.
(require 'drgnx-hub-client)
(require 'drgnx-jobs)
(require 'drgnx-ai)

(defun drgnx-test-lisp-hub-ensure ()
  "Make sure a Lisp hub runs for this test's dirs, starting it as a durable job if not; t, or an error saying why not."
  (or (drgnx-hub-running-p)
      (and (getenv "DRGNX_NO_HUB_START")
           (error "No drgnx hub runs, and starting one is off here (DRGNX_NO_HUB_START)"))
      (let ((env (delq nil (mapcar (lambda (n) (let ((v (getenv n))) (and v (not (string-empty-p v)) (concat n "=" v))))
                                   '("DRGNX_DATA_DIR" "DRGNX_CONFIG_DIR" "XDG_STATE_HOME" "XDG_DATA_HOME" "XDG_CONFIG_HOME"
                                     "XDG_RUNTIME_DIR" "DRGNX_HUB_PARENT_PID"))))
            (process-environment (append (delq nil (mapcar (lambda (p) (plist-get (cdr p) :key-env)) (drgnx-ai-providers)))
                                         process-environment)))
        (drgnx-jobs-start "drgnx-hub" (list "sh" "-c" "trap '' PIPE; exec \"$0\" \"$@\""
                                            (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                            "--eval" "(setq load-prefer-newer t)" "-L" (expand-file-name "core" drgnx-dir)
                                            "-l" "drgnx-hub" "-f" "drgnx-hub-main")
                          :cwd (expand-file-name "~") :env env)
        (let ((deadline (+ (float-time) 5)))
          (while (and (not (drgnx-hub-running-p)) (< (float-time) deadline)) (sleep-for 0.1)))
        (or (drgnx-hub-running-p) (error "The drgnx hub did not start")))))

(provide 'lisp-hub-fixture)
;;; lisp-hub-fixture.el ends here
