;;; jobs-test.el --- batch tests: durable jobs (detached launcher; no systemd units created) -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-jobs)

(defmacro drgnx-jobs-test--with (&rest body)
  `(let* ((root (make-temp-file "drgnx-jobs" t))
          (process-environment (append (list (concat "XDG_STATE_HOME=" root) "DRGNX_JOBS_LAUNCHER=detached")
                                       process-environment)))
     (unwind-protect (progn ,@body)
       (drgnx-jobs-test--stop-all)
       (delete-directory root t))))

(defun drgnx-jobs-test--wait (pred &optional secs)
  (let ((deadline (+ (float-time) (or secs 10))) v)
    (while (and (not (setq v (funcall pred))) (< (float-time) deadline)) (sleep-for 0.05))
    v))

(defun drgnx-jobs-test--stop-all ()
  "Stop every running job and wait until each has written its exit file: a stopped job's shell is still writing
(head, exit) when the signal returns, and the fixture's clean-up deleting its directory under it fails."
  (let ((ids (delq nil (mapcar (lambda (j) (and (eq (plist-get j :status) 'running) (plist-get j :id)))
                               (drgnx-jobs-list)))))
    (dolist (id ids) (ignore-errors (drgnx-jobs-stop id)))
    (dolist (id ids)
      (drgnx-jobs-test--wait (lambda () (file-exists-p (expand-file-name "exit" (drgnx-jobs--dir id)))) 5))))

(defun drgnx-jobs-test--status (id) (plist-get (drgnx-jobs-get id) :status))

(defun drgnx-jobs-test--outlives ()
  "A job started by another Emacs, which exits at once, runs on (that Emacs gets this one's `drgnx-jobs--setsid')."
  (drgnx-jobs-test--with
   (let* ((out (with-temp-buffer
                 (call-process (expand-file-name invocation-name invocation-directory) nil t nil
                               "--batch" "-Q" "-L" (file-name-directory (locate-library "drgnx-jobs")) "-l" "drgnx-jobs"
                               "--eval" (format "(setq drgnx-jobs--setsid %S)" drgnx-jobs--setsid)
                               "--eval" "(princ (drgnx-jobs-start \"test\" '(\"sh\" \"-c\" \"sleep 1; echo done\")))")
                 (buffer-string)))
          (id (car (last (split-string out "\n" t)))))
     (should (eq (drgnx-jobs-test--status id) 'running))
     ;; its own session, not this Emacs's (macOS's attributes have no session)
     (let ((sess (alist-get 'sess (process-attributes (plist-get (drgnx-jobs-get id) :pid)))))
       (when sess (should-not (eql sess (alist-get 'sess (process-attributes (emacs-pid)))))))
     (should (drgnx-jobs-test--wait (lambda () (eq (drgnx-jobs-test--status id) 'exited))))
     (should (eql (plist-get (drgnx-jobs-get id) :exit) 0))
     (should (string-match-p "done" (drgnx-jobs-log id))))))

(ert-deftest drgnx-jobs/a-job-outlives-the-emacs-that-started-it ()
  (drgnx-jobs-test--outlives))

(ert-deftest drgnx-jobs/a-job-outlives-the-emacs-that-started-it-without-setsid ()
  ;; macOS has no setsid: the portable launcher (perl, which every macOS has)
  (skip-unless (executable-find "perl"))
  (let ((drgnx-jobs--setsid nil)) (drgnx-jobs-test--outlives)))

(ert-deftest drgnx-jobs/a-failing-job-says-its-exit-code ()
  (drgnx-jobs-test--with
   (let ((id (drgnx-jobs-start "fails" '("sh" "-c" "echo oops >&2; exit 7"))))
     (should (drgnx-jobs-test--wait (lambda () (eq (drgnx-jobs-test--status id) 'exited))))
     (should (eql (plist-get (drgnx-jobs-get id) :exit) 7))
     (should (string-match-p "oops" (drgnx-jobs-log id))))))

(defun drgnx-jobs-test--stop ()
  "Stop ends a job's whole process group: the job's shell leads its own session and group."
  (drgnx-jobs-test--with
   ;; a length no other process uses (tests run in parallel shards): only this job's sleep can match
   (let* ((marker (format "sleep %d" (+ 30000 (random 30000))))
          (id (drgnx-jobs-start "long" (list "sh" "-c" marker))))
     (should (drgnx-jobs-test--wait (lambda () (eq (drgnx-jobs-test--status id) 'running))))
     (let* ((pid (plist-get (drgnx-jobs-get id) :pid)) (attrs (process-attributes pid)))
       (should (eql (alist-get 'pgrp attrs) pid))
       (when (assq 'sess attrs) (should (eql (alist-get 'sess attrs) pid))))   ; macOS's attributes have no session
     (drgnx-jobs-stop id)
     (should (drgnx-jobs-test--wait (lambda () (memq (drgnx-jobs-test--status id) '(exited stopped))) 3))
     (should-not (seq-find (lambda (p)
                             (string-match-p (regexp-quote marker) (or (cdr (assq 'args (process-attributes p))) "")))
                           (list-system-processes))))))

(ert-deftest drgnx-jobs/stop-ends-the-whole-job ()
  (drgnx-jobs-test--stop))

(ert-deftest drgnx-jobs/stop-ends-the-whole-job-without-setsid ()
  (skip-unless (executable-find "perl"))
  (let ((drgnx-jobs--setsid nil)) (drgnx-jobs-test--stop)))

(ert-deftest drgnx-jobs/the-boot-id-on-macos ()
  ;; macOS has no /proc: the boot session's UUID from `sysctl -n kern.bootsessionuuid' (kern.boottime moves
  ;; when the clock is set: a live job would look gone); nil when sysctl fails, says nothing or is missing
  (let* ((bin (make-temp-file "drgnx-jobs-bin" t)) (sysctl (expand-file-name "sysctl" bin))
         (fake (lambda (body)
                 (with-temp-file sysctl (insert "#!/bin/sh\n[ \"$*\" = \"-n kern.bootsessionuuid\" ] || exit 1\n" body))
                 (set-file-modes sysctl #o755))))
    (unwind-protect
        ;; a found id is kept (M12a-8): the cache is reset for each question
        (let ((exec-path (list bin)) (system-type 'darwin) (drgnx-jobs--boot-id-cache nil)
              (process-environment (cons (concat "PATH=" bin path-separator (getenv "PATH")) process-environment)))
          (funcall fake "echo '  9D3B5C2E-1F4A-4B6C-8E7D-0A1B2C3D4E5F  '\n")
          (should (equal (drgnx-jobs--boot-id) "9D3B5C2E-1F4A-4B6C-8E7D-0A1B2C3D4E5F"))
          (setq drgnx-jobs--boot-id-cache nil)
          (funcall fake "exit 3\n")
          (should-not (drgnx-jobs--boot-id))
          (funcall fake "echo\n")
          (should-not (drgnx-jobs--boot-id))
          (delete-file sysctl)
          (should-not (drgnx-jobs--boot-id)))
      (delete-directory bin t))))

(ert-deftest drgnx-jobs/a-job-whose-process-vanished-is-gone ()
  (drgnx-jobs-test--with
   (let* ((dir (expand-file-name "drgnx/jobs/20261017-000000-1" (getenv "XDG_STATE_HOME"))))
     (make-directory dir t)
     (with-temp-file (expand-file-name "job.eld" dir)
       (prin1 '(:id "20261017-000000-1" :name "old" :command ("x") :launcher detached :started "then") (current-buffer)))
     (write-region "999999999" nil (expand-file-name "pid" dir) nil 'silent)
     (should (eq (drgnx-jobs-test--status "20261017-000000-1") 'gone))
     (should (equal (mapcar (lambda (j) (plist-get j :name)) (drgnx-jobs-list)) '("old"))))))

;;;; Review fixes (M7 final review)

(ert-deftest drgnx-jobs/a-pid-from-before-a-reboot-is-never-trusted ()
  ;; I8: after a reboot the pid may belong to another process: gone, and never signalled.
  (drgnx-jobs-test--with
   (let* ((id "20261017-000000-2") (dir (expand-file-name (concat "drgnx/jobs/" id) (getenv "XDG_STATE_HOME"))) (signalled nil))
     (make-directory dir t)
     (with-temp-file (expand-file-name "job.eld" dir)
       (prin1 (list :id id :name "old" :launcher 'detached :boot "another-boot" :start '(0 0 0 0)) (current-buffer)))
     (write-region (number-to-string (emacs-pid)) nil (expand-file-name "pid" dir) nil 'silent)   ; alive, but not the job
     (should (eq (drgnx-jobs-test--status id) 'gone))
     (cl-letf (((symbol-function 'signal-process) (lambda (&rest a) (push a signalled))))
       (drgnx-jobs-stop id))
     (should-not signalled))))

(ert-deftest drgnx-jobs/a-state-path-with-a-quote-still-runs ()
  (let* ((root (concat (make-temp-file "drgnx-jobs" t) "/o'brien"))
         (process-environment (append (list (concat "XDG_STATE_HOME=" root) "DRGNX_JOBS_LAUNCHER=detached") process-environment)))
    (make-directory root t)
    (unwind-protect
        (let ((id (drgnx-jobs-start "q" '("sh" "-c" "echo fine"))))
          (should (drgnx-jobs-test--wait (lambda () (eq (drgnx-jobs-test--status id) 'exited))))
          (should (string-match-p "fine" (drgnx-jobs-log id))))
      (delete-directory (file-name-directory root) t))))

;;; jobs-test.el ends here

(ert-deftest drgnx-jobs/a-start-time-read-a-tick-apart-is-the-same-process ()
  ;; Emacs computes a process's start from the clock and the uptime read at slightly different moments: two
  ;; reads of one process differ by a clock tick (10 ms).  The job stays its own; a pid of another start (a
  ;; second or more apart) is still never trusted.
  (drgnx-jobs-test--with
   (let* ((id "20261017-000000-3") (dir (expand-file-name (concat "drgnx/jobs/" id) (getenv "XDG_STATE_HOME")))
          (start (alist-get 'start (process-attributes (emacs-pid))))
          (write (lambda (s) (with-temp-file (expand-file-name "job.eld" dir)
                               (prin1 (list :id id :name "me" :launcher 'detached :boot (drgnx-jobs--boot-id) :start s)
                                      (current-buffer))))))
     (make-directory dir t)
     (unwind-protect
         (progn
           (write-region (number-to-string (emacs-pid)) nil (expand-file-name "pid" dir) nil 'silent)
           (funcall write (time-add start 0.01))
           (should (eq (drgnx-jobs-test--status id) 'running))
           (funcall write (time-add start 5))
           (should (eq (drgnx-jobs-test--status id) 'gone)))
       ;; the "job" is this Emacs: never left for the fixture's clean-up to stop
       (delete-directory dir t)))))

(defun drgnx-jobs-test--slow-detach (line)
  "A launcher whose job shell runs 0.7 s late (its pid file too), in its own session as `drgnx-jobs--detach' does."
  (call-process "sh" nil 0 nil "-c" (concat "sleep 0.7; exec setsid -f sh -c " (shell-quote-argument line))))

(ert-deftest drgnx-jobs/no-wait-returns-before-the-pid-and-stamps-it-later ()
  (skip-unless (executable-find "setsid"))
  (drgnx-jobs-test--with
   (cl-letf (((symbol-function 'drgnx-jobs--detach) #'drgnx-jobs-test--slow-detach))
     (let* ((t0 (float-time))
            (id (drgnx-jobs-start "slow" '("sleep" "3") :no-wait t))
            (took (- (float-time) t0))
            (job-file (expand-file-name "job.eld" (drgnx-jobs--dir id))))
       (should (< took 0.5))                                         ; no wait for the pid
       (should-not (file-exists-p (expand-file-name "pid" (drgnx-jobs--dir id))))
       (should-not (plist-get (drgnx-jobs--read job-file) :start))
       ;; the boot and start time still come, from a timer, within two seconds
       (let ((deadline (+ (float-time) 2.5)))
         (while (and (not (plist-get (drgnx-jobs--read job-file) :start)) (< (float-time) deadline))
           (accept-process-output nil 0.05)))
       (should (plist-get (drgnx-jobs--read job-file) :start))
       (should (equal (plist-get (drgnx-jobs--read job-file) :boot) (drgnx-jobs--boot-id)))
       (should (eq (drgnx-jobs-test--status id) 'running))))))

;;;; The systemd launcher: systemd-run's ExecStart treats `$' specially

(ert-deftest drgnx-jobs/the-systemd-argv-escapes-dollars-for-execstart ()
  ;; systemd turns `$$' into `$' (and substitutes `${NAME}'): the shell must get the wrapper's original text
  (let* ((line (drgnx-jobs--wrapper "/tmp/j/" '("sh" "-c" "echo ${HOME} $1")))
         (args (drgnx-jobs--systemd-args "id1" "/tmp" line nil))
         (sent (car (last args))))
    (should (string-search "echo $$ >" line))                       ; the wrapper does need its own pid
    (should (equal (seq-take (last args 3) 2) '("sh" "-c")))
    (should (equal sent (string-replace "$" "$$" line)))
    (should (equal (string-replace "$$" "$" sent) line))))          ; systemd's unescaping gives it back

(defun drgnx-jobs-test--systemd-p ()
  (and (executable-find "systemd-run") (executable-find "systemctl")
       (eql 0 (call-process "systemctl" nil nil nil "--user" "show-environment"))))

(ert-deftest drgnx-jobs/a-systemd-job-records-its-real-pid ()
  (skip-unless (drgnx-jobs-test--systemd-p))
  (drgnx-jobs-test--with
   (let ((process-environment (cons "DRGNX_JOBS_LAUNCHER=systemd" process-environment)) id)
     (unwind-protect
         (progn
           (setq id (drgnx-jobs-start "sd" '("sh" "-c" "sleep 600")))
           (let ((pid (drgnx-jobs--text (expand-file-name "pid" (drgnx-jobs--dir id)))))
             (should (string-match-p "\\`[0-9]+\\'" pid)))
           (should (eq (drgnx-jobs-test--status id) 'running))
           (drgnx-jobs-stop id)
           (should (drgnx-jobs-test--wait (lambda () (not (eq (drgnx-jobs-test--status id) 'running))) 5))
           (should (memq (drgnx-jobs-test--status id) '(stopped exited gone)))
           (should-not (eql 0 (call-process "systemctl" nil nil nil "--user" "--quiet" "is-active"
                                            (concat "drgnx-job-" id)))))
       (when id (call-process "systemctl" nil nil nil "--user" "stop" (concat "drgnx-job-" id)))))))

;;;; Deferred pass B, batch 9

(ert-deftest drgnx-jobs/boot-id-asked-once ()
  ;; M12a-8: on macOS the boot id is a `sysctl' process; every `drgnx-jobs-get' of a live job asks for it
  (let ((drgnx-jobs--boot-id-cache nil) (system-type 'darwin) (calls 0))
    (cl-letf (((symbol-function 'call-process)
               (lambda (program &rest _) (when (equal program "sysctl") (cl-incf calls) (insert "UUID-1\n")) 0)))
      (should (equal (drgnx-jobs--boot-id) "UUID-1"))
      (should (equal (drgnx-jobs--boot-id) "UUID-1"))
      (should (= calls 1)))))

(ert-deftest drgnx-jobs/no-setsid-no-perl-says-so ()
  ;; M12a-9: a clear error before anything is created or run, not a "file is missing" from `call-process'
  (drgnx-jobs-test--with
   (let ((drgnx-jobs--setsid nil) (ran nil) (real-find (symbol-function 'executable-find)))
     (cl-letf (((symbol-function 'executable-find)
                (lambda (name &rest r) (and (not (equal name "perl")) (apply real-find name r))))
               ((symbol-function 'call-process) (lambda (&rest a) (push a ran) 0)))
       (let ((err (should-error (drgnx-jobs-start "x" '("true")) :type 'user-error)))
         (should (equal (cadr err) "Detached jobs need setsid or perl"))))
     (should-not ran)
     (should-not (drgnx-jobs-list)))))

(ert-deftest drgnx-jobs/no-wait-stamps-before-exit ()
  ;; M12a-44: Emacs exiting before the stamping timer fires still leaves :boot and :start (the hook runs once)
  (skip-unless (executable-find "setsid"))
  (drgnx-jobs-test--with
   (let ((kill-emacs-hook nil) id dir hooks)
     (cl-letf (((symbol-function 'run-at-time) (lambda (&rest _) (timer-create))))   ; a timer that never fires
       (setq id (drgnx-jobs-start "short-lived" '("sleep" "3") :no-wait t)))
     (setq dir (drgnx-jobs--dir id) hooks kill-emacs-hook)
     (should (= (length hooks) 1))
     (should (drgnx-jobs-test--wait (lambda () (file-exists-p (expand-file-name "pid" dir)))))
     (should-not (plist-get (drgnx-jobs--read (expand-file-name "job.eld" dir)) :start))
     (mapc #'funcall hooks)
     (should-not kill-emacs-hook)                                 ; once: the hook removed itself
     (should (plist-get (drgnx-jobs--read (expand-file-name "job.eld" dir)) :start))
     (should (equal (plist-get (drgnx-jobs--read (expand-file-name "job.eld" dir)) :boot) (drgnx-jobs--boot-id))))))

(ert-deftest drgnx-jobs/stop-returns-for-a-job-that-ignores-term ()
  ;; JOBS-2: a blocking `systemctl stop' holds for TimeoutStopSec (90 s) while a process in the unit ignores TERM
  (skip-unless (drgnx-jobs-test--systemd-p))
  (drgnx-jobs-test--with
   (let ((process-environment (cons "DRGNX_JOBS_LAUNCHER=systemd" process-environment)) (drgnx-jobs-stop-wait 3) id)
     (unwind-protect
         (progn
           (setq id (drgnx-jobs-start "stubborn" '("sh" "-c" "trap '' TERM; sleep 600")))
           (should (eq (drgnx-jobs-test--status id) 'running))
           (let ((t0 (float-time)))
             (drgnx-jobs-stop id)
             (should (< (- (float-time) t0) 8)))
           (should-not (eq (drgnx-jobs-test--status id) 'running)))
       (when id (call-process "systemctl" nil nil nil "--user" "kill" "--signal=SIGKILL" (concat "drgnx-job-" id)))))))
