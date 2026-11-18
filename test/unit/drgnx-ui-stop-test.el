;;; drgnx-ui-stop-test.el --- batch tests: stopping a session's process group, with real processes -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; Real process groups (setsid, sh, sleep): each member announces itself with a file once its TERM trap is set.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-ui)

(defun drgnx-ui-stop-test--read (file)
  (ignore-errors (with-temp-buffer (insert-file-contents file) (string-trim (buffer-string)))))

(ert-deftest drgnx-ui/stopping-a-group-waits-for-every-member ()
  "A session's group holds processes whose command lines do not name its run directory (Emacs under the compositor,
saving its state into it on TERM).  Stopping the group waits for all of them, not only for those naming the run: the
caller deletes the run directory next (latency-includes-redisplay-work failed \"Directory not empty\").
drgnx-ui's sessions run under a Linux compositor; macOS has no setsid(1) to make the group with."
  (unless (executable-find "setsid")
    (ert-skip "no setsid(1): drgnx-ui's sessions run under a Linux compositor"))
  (let* ((run (directory-file-name (make-temp-file "drgnx-ui-run" t))) (aside (make-temp-file "drgnx-ui-pgid" t))
         (pgid-file (expand-file-name "pgid" aside)) (ready (expand-file-name "ready" aside)) pgid)
    (unwind-protect
        (progn
          ;; the leader names RUN and ends at once on TERM; the other member does not, and ends half a second later
          (call-process "setsid" nil 0 nil "-f" "sh" "-c"
                        (format "echo $$ > %s; sh -c 'trap \"sleep 0.5; exit 0\" TERM; touch %s; while :; do sleep 0.05; done' &
                                 exec sh -c 'trap \"exit 0\" TERM; while :; do sleep 0.05; done' %s"
                                (shell-quote-argument pgid-file) (shell-quote-argument ready)
                                (shell-quote-argument (concat run "/leader"))))
          (setq pgid (drgnx-test-wait (lambda () (drgnx-ui-stop-test--read pgid-file)) :secs 5 :what "the group's id"))
          (drgnx-test-wait (lambda () (and (file-exists-p ready) (drgnx-ui--group-ours-p pgid run)))
                           :secs 5 :what "both members up, the trap set")
          (drgnx-ui--stop-group pgid run)
          (should-not (eq 0 (call-process "pgrep" nil nil nil "-g" pgid))))
      (when pgid (call-process "kill" nil nil nil "-KILL" "--" (concat "-" pgid)))
      (delete-directory run t) (delete-directory aside t))))

(ert-deftest drgnx-ui/a-launched-group-is-ours-while-its-command-execs ()
  "While a process execs, its /proc command line reads empty for an instant.  The detached launcher's leader (sh)
once exec'd `timeout' as its last step, so at that instant no member of the new group named the run directory, and
`drgnx-ui-alive-p' said the session's processes were gone (drgnx-inv/i2-every-area-keeps-its-size failed 0.05 s
into its start on a loaded machine).  A `timeout' whose command line names no run stands in for that instant, held:
the group is still the session's."
  (unless (executable-find "setsid")
    (ert-skip "no setsid(1): drgnx-ui's sessions run under a Linux compositor"))
  (let* ((run (directory-file-name (make-temp-file "drgnx-ui-run" t))) (bin (make-temp-file "drgnx-ui-bin" t))
         (fake (expand-file-name "timeout" bin)) pgid)
    (write-region "#!/bin/bash\nexec -a drgnx-ui-stand-in sleep 30\n" nil fake)
    (set-file-modes fake #o755)
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-ui-session-env) #'ignore)
                  ((symbol-function 'drgnx-ui-env-argv) (lambda (_) '("env")))
                  ((symbol-function 'drgnx-ui-compositor-argv) (lambda (_) '("sleep" "30"))))
          (let ((process-environment (cons (concat "PATH=" bin ":" (getenv "PATH")) process-environment)))
            (setq pgid (drgnx-ui--launch-detached (list :name "drgnx-ui-9-00000a" :run run))))
          (drgnx-test-wait (lambda () (eq 0 (call-process "pgrep" nil nil nil "-g" pgid "-f" "drgnx-ui-stand-in")))
                           :secs 5 :what "the stand-in for the exec in the group")
          (should (drgnx-ui--group-ours-p pgid run)))
      (when pgid (call-process "kill" nil nil nil "-KILL" "--" (concat "-" pgid)))
      (delete-directory run t) (delete-directory bin t))))

(provide 'drgnx-ui-stop-test)
;;; drgnx-ui-stop-test.el ends here
