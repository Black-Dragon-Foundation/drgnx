;;; jobs-test.el --- batch tests: durable jobs (detached launcher; no systemd units created) -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-jobs)
(require 'drgnx-timer)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)

(defmacro drgnx-jobs-test--with (&rest body)
  `(let* ((root (make-temp-file "drgnx-jobs" t))
          (process-environment (append (list (concat "XDG_STATE_HOME=" root) "DRGNX_JOBS_LAUNCHER=detached")
                                       process-environment)))
     (unwind-protect (progn ,@body)
       (drgnx-jobs-test--stop-all)
       (delete-directory root t))))

(defun drgnx-jobs-test--wait (pred &optional secs)
  (drgnx-test-wait pred :secs (max 30 (or secs 0)) :what "the job's condition"))

(defun drgnx-jobs-test--stop-all ()
  "Stop every running job and wait until each has written its exit file: a stopped job's shell is still writing
(head, exit) when the signal returns, and the fixture's clean-up deleting its directory under it fails."
  (let ((ids (delq nil (mapcar (lambda (j) (and (eq (plist-get j :status) 'running)
                                                ;; a `drgnx-jobs-test--job-dir' names this Emacs: no shell, no exit file
                                                (not (eql (plist-get j :pid) (emacs-pid)))
                                                (plist-get j :id)))
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
     (should (drgnx-jobs-test--wait (lambda () (eq (drgnx-jobs-test--status id) 'exited))))
     (should (eql (plist-get (drgnx-jobs-get id) :exit) 0))
     (should (string-match-p "done" (drgnx-jobs-log id))))))

(defun drgnx-jobs-test--survives-its-starter ()
  "A job's launcher detaches it from the Emacs that started it, which is still running.
Emacs's own children already lead a session, so `its session differs' proves nothing.  What a detaching launcher
changes is the parent: the job is not the starter's child (a plain `call-process' would leave it that), and
killing the starter's whole process group does not take the job along."
  (drgnx-jobs-test--with
   (let* ((idfile (expand-file-name "starter-id" root))
          (starter (make-process
                    :name "drgnx-jobs-starter" :noquery t :connection-type 'pipe :buffer nil
                    :sentinel (lambda (p _e) (process-put p :done t))
                    :command (list (expand-file-name invocation-name invocation-directory)
                                   "--batch" "-Q" "-L" (file-name-directory (locate-library "drgnx-jobs"))
                                   "-l" "drgnx-jobs"
                                   "--eval" (format "(setq drgnx-jobs--setsid %S)" drgnx-jobs--setsid)
                                   ;; the id goes in whole, by a rename: `write-region' creates the file before it
                                   ;; writes, and a wait on the file's existence could read it empty (macOS CI)
                                   "--eval" (format (concat "(progn (write-region (drgnx-jobs-start \"test\" "
                                                            "'(\"sh\" \"-c\" \"sleep 4; echo done\")) "
                                                            "nil %S) (rename-file %S %S) (sleep-for 60))")
                                                    (concat idfile ".new") (concat idfile ".new") idfile))))
          (spid (process-id starter)) id)
     (unwind-protect
         (progn
           (should (drgnx-jobs-test--wait (lambda () (file-exists-p idfile))))
           (setq id (drgnx-jobs--text idfile))
           (should (drgnx-jobs-test--wait (lambda () (eq (drgnx-jobs-test--status id) 'running))))
           (should (process-live-p starter))
           (let ((pid (plist-get (drgnx-jobs-get id) :pid)))
             (should-not (eql (alist-get 'ppid (process-attributes pid)) spid))   ; not the starter's child
             (ignore-errors (signal-process (- spid) 'SIGKILL))                   ; the starter's whole group
             (signal-process spid 'SIGKILL)
             (should (drgnx-jobs-test--wait (lambda () (process-get starter :done)) 5))
             (drgnx-test-pause 0.3)                                                   ; a window in which nothing may happen
             (should (eq (drgnx-jobs-test--status id) 'running))
             (should (process-attributes pid)))
           (should (drgnx-jobs-test--wait (lambda () (eq (drgnx-jobs-test--status id) 'exited))))
           (should (string-match-p "done" (drgnx-jobs-log id))))
       (when (process-live-p starter) (delete-process starter))))))

(ert-deftest drgnx-jobs/a-job-survives-its-starter-and-is-not-its-child ()
  (drgnx-jobs-test--survives-its-starter))

(ert-deftest drgnx-jobs/a-job-survives-its-starter-without-setsid ()
  (skip-unless (executable-find "perl"))
  (let ((drgnx-jobs--setsid nil)) (drgnx-jobs-test--survives-its-starter)))

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
           ;; as `process-attributes' gives it (a list): the (TICKS . HZ) of `time-add' is beyond 64 bits, which
           ;; job.eld's reader refuses
           (funcall write (time-convert (time-add start 0.01) 'list))
           (should (eq (drgnx-jobs-test--status id) 'running))
           (funcall write (time-convert (time-add start 5) 'list))
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
       (drgnx-test-wait (lambda () (plist-get (drgnx-jobs--read job-file) :start)) :what "the job's start stamp")
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

;; The no-wait stamp on the clock fixture: a job that is this Emacs (its pid file holds our pid), never started for real.
(defmacro drgnx-jobs-test--no-wait (&rest body)
  "BODY on the virtual clock with a launcher that starts nothing; `id' and `dir' are the :no-wait job's."
  `(drgnx-jobs-test--with
    (drgnx-test-with-clock ()
      (cl-letf (((symbol-function 'drgnx-jobs--detach) #'ignore))
        (let* ((kill-emacs-hook nil) (id (drgnx-jobs-start "stamp" '("true") :no-wait t))
               (dir (drgnx-jobs--dir id)) (key (cons 'jobs-stamp id)))
          (unwind-protect (progn ,@body)
            (drgnx-timer-cancel key)
            (delete-directory dir t)))))))

(defun drgnx-jobs-test--stamped-p (dir)
  (plist-get (drgnx-jobs--read (expand-file-name "job.eld" dir)) :start))

(ert-deftest drgnx-jobs/no-wait-stamps-when-the-pid-appears ()
  (drgnx-jobs-test--no-wait
   (should (drgnx-timer-active-p key))
   (drgnx-test-advance 0.5)                                       ; no pid yet: polling, not stamped
   (should (drgnx-timer-active-p key))
   (should-not (drgnx-jobs-test--stamped-p dir))
   (write-region (number-to-string (emacs-pid)) nil (expand-file-name "pid" dir) nil 'silent)
   (drgnx-test-advance 0.05)
   (should (drgnx-jobs-test--stamped-p dir))
   (should (equal (plist-get (drgnx-jobs--read (expand-file-name "job.eld" dir)) :boot) (drgnx-jobs--boot-id)))
   (should-not (drgnx-timer-active-p key))))                      ; the poll ended

(ert-deftest drgnx-jobs/no-wait-gives-up-after-2s ()
  (drgnx-jobs-test--no-wait
   (drgnx-test-advance 1.9)
   (should (drgnx-timer-active-p key))
   (drgnx-test-advance 0.2)
   (should-not (drgnx-timer-active-p key))
   (should-not (drgnx-jobs-test--stamped-p dir))
   (should-not drgnx-timer-errors)))                              ; the job never started: gave up quietly

(ert-deftest drgnx-jobs/no-wait-stamps-at-exit ()
  ;; M12a-44: Emacs exiting before the poll fires still leaves :boot and :start (the hook runs once)
  (drgnx-jobs-test--no-wait
   (let ((hooks kill-emacs-hook))
     (should (memq #'drgnx-jobs--stamp-at-exit hooks))
     (write-region (number-to-string (emacs-pid)) nil (expand-file-name "pid" dir) nil 'silent)
     (should-not (drgnx-jobs-test--stamped-p dir))
     (mapc #'funcall hooks)
     (should-not (drgnx-timer-active-p key))                      ; the poll ended with it
     (funcall #'drgnx-jobs--stamp-at-exit)                        ; a second exit stamps nothing again
     (should (= 1 (length (seq-filter (lambda (k) (eq k :boot)) (drgnx-jobs--read (expand-file-name "job.eld" dir))))))
     (should (drgnx-jobs-test--stamped-p dir))
     (should (equal (plist-get (drgnx-jobs--read (expand-file-name "job.eld" dir)) :boot) (drgnx-jobs--boot-id))))))

(ert-deftest drgnx-jobs/no-wait-adds-one-exit-hook ()
  ;; T9-1: one named hook however many jobs, and none of their polls left behind
  (drgnx-jobs-test--no-wait
   (let ((ids (list id (drgnx-jobs-start "stamp2" '("true") :no-wait t) (drgnx-jobs-start "stamp3" '("true") :no-wait t))))
     (unwind-protect
         (progn
           (dolist (i ids)
             (write-region (number-to-string (emacs-pid)) nil (expand-file-name "pid" (drgnx-jobs--dir i)) nil 'silent))
           (drgnx-test-advance 0.05)
           (should (= 1 (cl-count #'drgnx-jobs--stamp-at-exit kill-emacs-hook)))
           (should-not (seq-find (lambda (e) (eq (car-safe (car e)) 'jobs-stamp)) (drgnx-timer-pending)))
           (dolist (i ids) (should (drgnx-jobs-test--stamped-p (drgnx-jobs--dir i)))))
       (dolist (i (cdr ids)) (delete-directory (drgnx-jobs--dir i) t))))))

;;;; job.eld goes through the file layer (config Task 18)

(defun drgnx-jobs-test--job-dir (text)
  "A job directory holding a job.eld of TEXT and a pid file naming this Emacs, so that a stamp has work to do."
  (let ((dir (drgnx-jobs--dir "20261019-000000-1")))
    (make-directory dir t)
    (with-temp-file (expand-file-name "job.eld" dir) (insert text))
    (write-region (number-to-string (emacs-pid)) nil (expand-file-name "pid" dir) nil 'silent)
    dir))

(defun drgnx-jobs-test--bytes (file)
  (with-temp-buffer (set-buffer-multibyte nil) (insert-file-contents-literally file) (buffer-string)))

(ert-deftest drgnx-jobs/job-eld-is-written-atomically ()
  (drgnx-jobs-test--with
   (cl-letf (((symbol-function 'drgnx-jobs--detach) #'ignore))
     (let* ((written nil) (orig (symbol-function 'drgnx-file-write))
            (id (cl-letf (((symbol-function 'drgnx-file-write)
                           (lambda (file &rest args) (push file written) (apply orig file args))))
                  ;; a command assembled from buffer text carries text properties: still startable
                  (drgnx-jobs-start "atomic" (list "echo" (propertize "hi" 'face 'bold)) :no-wait t)))
            (dir (drgnx-jobs--dir id)) (file (expand-file-name "job.eld" dir)))
       (unwind-protect
           (progn
             (should (equal written (list file)))                  ; through the layer, once
             (should (equal (plist-get (drgnx-jobs--read file) :command) '("echo" "hi")))
             (should (equal (plist-get (drgnx-jobs--read file) :name) "atomic"))
             (should-not (directory-files dir nil "\\`\\.#\\|tmp\\|~\\'"))   ; no temp file left beside it
             (should (eq (plist-get (drgnx-file-read file) :status) 'ok)))
         (drgnx-timer-cancel (cons 'jobs-stamp id)))))))

(ert-deftest drgnx-jobs/the-stamp-keeps-the-rest ()
  ;; an existing file (one prin1 form, no newline: what every older drgnx wrote) with a key this code does not know
  (drgnx-jobs-test--with
   (let* ((dir (drgnx-jobs-test--job-dir
                (prin1-to-string '(:id "x" :name "old" :command ("a" "b") :launcher detached :future (1 2) :started "then"))))
          (file (expand-file-name "job.eld" dir)))
     (drgnx-jobs--stamp dir)
     (let ((job (drgnx-jobs--read file)))
       (should (equal (cl-subseq job 0 12) '(:id "x" :name "old" :command ("a" "b") :launcher detached :future (1 2) :started "then")))
       (should (equal (plist-get job :boot) (drgnx-jobs--boot-id)))
       (should (plist-get job :start)))
     (let ((once (drgnx-jobs-test--bytes file)))
       ;; a second stamp changes nothing and repeats no key, though Emacs's reading of the start jitters by a tick
       (let ((real (symbol-function 'process-attributes)))
         (cl-letf (((symbol-function 'process-attributes)
                    (lambda (pid)
                      (let ((a (funcall real pid))) (setf (alist-get 'start a) (time-add (alist-get 'start a) 0.01)) a))))
           (drgnx-jobs--stamp dir)))
       (should (equal (drgnx-jobs-test--bytes file) once))
       (should (= 1 (cl-count :boot (drgnx-jobs--read file))))))))

(ert-deftest drgnx-jobs/an-unreadable-job-eld-is-not-overwritten ()
  (drgnx-jobs-test--with
   (dolist (text '("(:id \"x\" :name " "(:id \"x\") (:extra 1)" "#1=(:id . #1#)" ""))
     (let* ((dir (drgnx-jobs-test--job-dir text)) (file (expand-file-name "job.eld" dir))
            (before (drgnx-jobs-test--bytes file)) (said nil))
       (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) said))))
         (should-not (drgnx-jobs--stamp dir))                      ; the error is caught
         (drgnx-jobs--stamp-at-exit)
         (should-not (drgnx-jobs--stamp-anyway dir)))
       (should (equal (drgnx-jobs-test--bytes file) before))
       (should-not (directory-files dir nil "\\.lock\\|\\.#"))     ; no lock left
       (should-not (drgnx-jobs--read file))
       (delete-directory dir t)))))

(ert-deftest drgnx-jobs/a-busy-job-eld-skips-the-stamp-without-waiting ()
  (drgnx-jobs-test--with
   (let* ((dir (drgnx-jobs-test--job-dir (prin1-to-string '(:id "x" :name "n"))))
          (file (expand-file-name "job.eld" dir)) (waited nil) (said nil))
     (cl-letf (((symbol-function 'drgnx-file--sleep) (lambda (_) (setq waited t)))
               ((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) said))))
       (drgnx-file-update file (lambda (data) (drgnx-jobs--stamp dir) data)))   ; the lock is ours: the stamp finds it busy
     (should-not waited)
     (should-not said)                                             ; skipped, quietly
     (should-not (plist-get (drgnx-jobs--read file) :boot)))))

(ert-deftest drgnx-jobs/a-stamp-never-creates-job-eld-nor-its-directory ()
  (drgnx-jobs-test--with
   (let ((dir (drgnx-jobs-test--job-dir "")))                      ; empty job.eld: nothing to add the stamp to
     (delete-file (expand-file-name "job.eld" dir))
     (drgnx-jobs--stamp dir)
     (should-not (file-exists-p (expand-file-name "job.eld" dir)))
     (delete-directory dir t)
     (drgnx-jobs--stamp dir)
     (should-not (file-exists-p dir)))))

(ert-deftest drgnx-jobs/the-exit-stamp-takes-the-default-timeout-and-never-prompts ()
  (drgnx-jobs-test--no-wait
   (write-region (number-to-string (emacs-pid)) nil (expand-file-name "pid" dir) nil 'silent)
   (let ((timeouts nil) (interaction nil) (orig (symbol-function 'drgnx-file-update)))
     (cl-letf (((symbol-function 'drgnx-file-update)
                (lambda (file fn &rest args)
                  (push (plist-get args :timeout) timeouts) (push inhibit-interaction interaction)
                  (apply orig file fn args))))
       (drgnx-jobs--stamp-at-exit)                                 ; kill-emacs-hook: the layer's default (1 s)
       (drgnx-jobs--stamp dir))                                    ; automatic paths: one attempt
     (should (equal timeouts '(0 1.0)))
     (should (equal interaction '(t t))))))
