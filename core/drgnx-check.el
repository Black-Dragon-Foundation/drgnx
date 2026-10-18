;;; drgnx-check.el --- bin/drgnx check: build, then every test tier, in parallel where it is safe -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx check' runs in phases.  1: the build (an error stops everything).  2, in parallel: the unit suite in
;; shards, the test/ui session, the live tests in shards, the scenario tier — the GUI ones (each starts headless
;; Emacs sessions) no more at a time than free memory allows.  3: the bench, alone.  4: perf, alone (it measures
;; latency).  Every job writes its own log in a run directory; one summary at the end, exit 0 only when all
;; passed.  Shards are balanced by how long their files took last time.  See docs/develop/check.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-paths)

(defconst drgnx-check-timeouts
  '((build . 300) (unit . 900) (ui . 900) (tty . 1500) (live . 1500) (scenario . 1500) (bench . 1200) (perf . 2400))
  "Seconds before a job of each kind is ended (each tier has its own, shorter, timeouts inside).")

;;;; Memory and shards

(defun drgnx-check--mem-available ()
  "MiB of memory available (Linux /proc/meminfo), or nil."
  (ignore-errors
    (with-temp-buffer
      (insert-file-contents "/proc/meminfo")
      (and (re-search-forward "^MemAvailable: *\\([0-9]+\\) kB" nil t) (/ (string-to-number (match-string 1)) 1024)))))

(defun drgnx-check-gui-slots (&optional available)
  "How many GUI jobs may run at once with AVAILABLE MiB (default: now): 1 GiB each beyond 1.5 GiB kept free,
at least 1, at most 4."
  (let ((mb (or available (drgnx-check--mem-available) 0)))
    (max 1 (min 4 (floor (- mb 1536) 1024)))))

(defun drgnx-check-shard (files n durations)
  "FILES split into at most N shards of about equal time: the longest first, each onto the shard with least so
far.  DURATIONS: alist file → seconds (a file it lacks weighs 1)."
  (let* ((n (max 1 (min n (length files))))
         (shards (make-vector n nil)) (load (make-vector n 0)))
    (dolist (f (sort (copy-sequence files) (lambda (a b) (> (or (alist-get a durations nil nil #'equal) 1)
                                                            (or (alist-get b durations nil nil #'equal) 1)))))
      (let ((i (seq-position (append load nil) (seq-min load))))
        (aset shards i (cons f (aref shards i)))
        (aset load i (+ (aref load i) (or (alist-get f durations nil nil #'equal) 1)))))
    (seq-remove #'null (mapcar #'nreverse (append shards nil)))))

(defun drgnx-check-durations-file () (expand-file-name "check/durations.eld" (drgnx-state-dir)))

(defun drgnx-check-durations ()
  (ignore-errors (with-temp-buffer (insert-file-contents (drgnx-check-durations-file)) (read (current-buffer)))))

(defun drgnx-check--save-durations (dir)
  "Seconds per test file from the shards' results in DIR, kept for the next run's balance."
  (let ((now nil) (per (drgnx-check-durations)))
    (dolist (f (directory-files dir t "\\`\\(unit\\|live\\)-[0-9]+\\.json\\'"))
      (seq-doseq (te (plist-get (ignore-errors (json-parse-string (with-temp-buffer (insert-file-contents f) (buffer-string))
                                                                  :object-type 'plist :null-object nil))
                                :tests))
        (when-let* ((file (plist-get te :file)))
          (cl-incf (alist-get file now 0 nil #'equal) (or (plist-get te :seconds) 0)))))
    (pcase-dolist (`(,file . ,secs) now) (setf (alist-get file per nil nil #'equal) secs))   ; this run's times win
    (make-directory (file-name-directory (drgnx-check-durations-file)) t)
    (with-temp-file (drgnx-check-durations-file) (prin1 per (current-buffer)))))

;;;; The plan

(defun drgnx-check--emacs () (or (getenv "DRGNX_EMACS") (expand-file-name invocation-name invocation-directory)))

(defconst drgnx-check-unit-env
  '("DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/drgnx-unit-test"
    "DISPLAY" "WAYLAND_DISPLAY" "SWAYSOCK" "I3SOCK" "HYPRLAND_INSTANCE_SIGNATURE" "NIRI_SOCKET")
  "The environment of a unit shard (bare names are unset): a dead session bus and no display or compositor,
so a test cannot reach the user's desktop.  `bin/drgnx test' sets the same, plus a runtime directory of its
own (XDG_RUNTIME_DIR); here the runner (harness/run-ert.el) gives each shard that one inside Emacs, which is
enough for everything but dbus.el: it reads the process's own environment.")

(cl-defun drgnx-check-plan (&key (root drgnx-dir) (unit-shards 4) (live-shards 2) perf (gui t) (tty (and (executable-find "tmux") t)) dir)
  "The jobs of a check of the checkout ROOT: (:name :phase :command :gui :env :timeout)…  DIR: where shard
results go (default: none).  TTY (default: tmux is installed): with GUI, the terminal tier, `bin/drgnx test --tty'."
  (let* ((bin (expand-file-name "bin/drgnx" root))
         (durations (drgnx-check-durations))
         (paths (list "-L" (expand-file-name "harness" root) "-L" (expand-file-name "core" root) "-L" (expand-file-name "wb" root)))
         (run-ert (expand-file-name "harness/run-ert.el" root))
         (results (lambda (name) (and dir (list (concat "DRGNX_TEST_RESULTS=" (expand-file-name (concat name ".json") dir))))))
         (job (lambda (name phase kind command &rest props)
                (append (list :name name :phase phase :command command :timeout (alist-get kind drgnx-check-timeouts)) props)))
         (jobs (list (funcall job "build" 1 'build (list bin "build")))))
    (cl-loop for files in (drgnx-check-shard (directory-files-recursively (expand-file-name "test/unit" root) "-test\\.el\\'")
                                             unit-shards durations)
             for i from 1
             for name = (format "unit-%d" i)
             do (push (funcall job name 2 'unit
                               (append (list (drgnx-check--emacs) "--batch" "-Q" "--eval" "(setq load-prefer-newer t)")
                                       paths (list "-l" run-ert "-f" "drgnx-run-ert-batch") files)
                               :env (append (list "DRGNX_TEST_SELECTOR=(not (tag :timing))") (funcall results name)
                                            drgnx-check-unit-env))
                      jobs))
    ;; the unit tests that measure time, alone once the parallel phase is over, in one Emacs (16 tests: an Emacs
    ;; for each of ~140 files would cost more than they take; each shard above runs a file per Emacs)
    (push (funcall job "unit-timing" 3 'unit
                   (append (list (drgnx-check--emacs) "--batch" "-Q" "--eval" "(setq load-prefer-newer t)")
                           paths (list "-l" run-ert "-f" "drgnx-run-ert-batch" (expand-file-name "test/unit" root)))
                   :env (append (list "DRGNX_TEST_SELECTOR=(tag :timing)" "DRGNX_TEST_ONE_PROCESS=1") (funcall results "unit-timing")
                                drgnx-check-unit-env))
          jobs)
    (when gui
      ;; the session test's 110 s default is too tight beside the parallel shards (a session boots slower under load)
      (push (funcall job "ui" 2 'ui (list bin "ui" "test-ui-session") :gui t :env (list "DRGNX_UI_TEST_TIMEOUT=300")) jobs)
      ;; the terminal tier: Emacs sessions in private tmux servers, a file at a time in an Emacs of its own (the runner
      ;; does that, as for a unit shard).  A GUI job for the memory accounting: one session is an Emacs of its own.
      (when tty (push (funcall job "tty" 2 'tty (list bin "test" "--tty") :gui t :env drgnx-check-unit-env) jobs))
      (cl-loop for files in (drgnx-check-shard (directory-files-recursively (expand-file-name "test/live" root) "-test\\.el\\'")
                                               live-shards durations)
               for i from 1
               for name = (format "live-%d" i)
               ;; in the unit tier's sandbox (temp HOME, dead bus, no provider keys), its files in one Emacs
               do (push (funcall job name 2 'live
                                 (append (list (drgnx-check--emacs) "--batch" "-Q" "--eval" "(setq load-prefer-newer t)")
                                         paths (list "-l" "drgnx-ui" "-l" run-ert "-f" "drgnx-run-ert-batch") files)
                                 :gui t :env (append (list "DRGNX_TEST_ONE_PROCESS=1") (funcall results name) drgnx-check-unit-env))
                        jobs))
      ;; the tiers that measure time, each alone: scenarios hold frame budgets (a frame from the daemon in
      ;; < 500 ms failed at 514 ms next to the parallel phase), then the bench, then perf
      (push (funcall job "scenario" 4 'scenario (list bin "test" "--scenario" "--config" "drgnx") :gui t
                     :env (list "DRGNX_SCENARIO_TIMEOUT=600"))
            jobs)
      (push (funcall job "bench" 5 'bench (list bin "test" "--bench") :gui t) jobs)
      ;; exit 3: the machine stayed too busy to measure — not judged, and not a pass
      (when perf (push (funcall job "perf" 6 'perf (list bin "test" "--perf") :gui t :not-judged 3) jobs)))
    (nreverse jobs)))

;;;; Running

(cl-defun drgnx-check-run (job-list &key dir (jobs 8) (gui-slots (drgnx-check-gui-slots)) verbose)
  "Run JOB-LIST phase by phase (in parallel within a phase: at most JOBS at once, GUI-SLOTS of them GUI jobs),
each logging to DIR/NAME.log.  A failing phase 1 (the build) stops the rest.  Returns (:ok BOOL :jobs
(JOB+RESULT…) :seconds WALL)."
  (let ((t0 (float-time)) (stop nil) (all (mapcar #'copy-sequence job-list)))
    (make-directory dir t)
    (dolist (phase (sort (delete-dups (mapcar (lambda (j) (plist-get j :phase)) all)) #'<))
      (let ((queue (seq-filter (lambda (j) (eql (plist-get j :phase) phase)) all)) (running nil))
        (if stop
            (dolist (j queue) (plist-put j :status 'skipped))
          (while (or queue running)
            ;; start what fits
            (let ((gui-running (seq-count (lambda (j) (plist-get j :gui)) running)))
              (dolist (j (copy-sequence queue))
                (when (and (< (length running) jobs)
                           (or (not (plist-get j :gui)) (< gui-running gui-slots)))
                  (setq queue (delq j queue))
                  (drgnx-check--start j dir)
                  (when verbose (princ (format "check: %s started\n" (plist-get j :name))))
                  (when (plist-get j :gui) (cl-incf gui-running))
                  (push j running))))
            (accept-process-output nil 0.1)
            ;; collect what ended; end what overran
            (dolist (j (copy-sequence running))
              (let ((p (plist-get j :process)))
                (when (and (process-live-p p) (plist-get j :timeout)
                           (> (- (float-time) (plist-get j :start)) (plist-get j :timeout)))
                  (plist-put j :status 'timeout)
                  (drgnx-check--end p))
                (unless (process-live-p p)
                  (setq running (delq j running))
                  (plist-put j :seconds (- (float-time) (plist-get j :start)))
                  (plist-put j :exit (process-exit-status p))
                  (unless (eq (plist-get j :status) 'timeout)
                    (plist-put j :status (cond ((eql (process-exit-status p) 0) 'ok)
                                               ;; perf: the machine was too busy to measure (not a pass)
                                               ((eql (process-exit-status p) (plist-get j :not-judged)) 'not-judged)
                                               (t 'failed))))
                  (when verbose (princ (format "check: %s %s (%.0f s)\n" (plist-get j :name) (plist-get j :status) (plist-get j :seconds)))))))))
        (when (and (eql phase 1) (seq-find (lambda (j) (and (eql (plist-get j :phase) 1) (not (eq (plist-get j :status) 'ok)))) all))
          (setq stop t))))
    (list :ok (seq-every-p (lambda (j) (eq (plist-get j :status) 'ok)) all) :jobs all :seconds (- (float-time) t0))))

(defconst drgnx-check-grace 25
  "Seconds a job told to end (timeout, C-c) has to clean up — its Emacs stops the sessions it started — before
it is killed.")

(defun drgnx-check--group-running-p (pgid)
  "Whether a process of group PGID still runs.  Zombies do not count: in a container whose PID 1 never
reaps (GitHub's job containers), an ended job's processes stay as zombies and signal 0 still reaches them."
  (and (eq 0 (ignore-errors (signal-process (- pgid) 0)))
       (seq-some (lambda (pid)
                   (let ((a (process-attributes pid)))
                     (and (eql (alist-get 'pgrp a) pgid) (not (equal (alist-get 'state a) "Z")))))
                 (list-system-processes))))

(defun drgnx-check--end (&rest ps)
  "End the job processes PS and everything they started (each its own process group): TERM, up to
`drgnx-check-grace' seconds to clean up, then KILL."
  (dolist (p ps) (ignore-errors (signal-process (- (process-id p)) 'TERM)))
  (let ((deadline (+ (float-time) drgnx-check-grace))
        ;; the whole group: the job's shell goes at once, what it started may still be cleaning up
        (group-left (lambda (p) (drgnx-check--group-running-p (process-id p)))))
    (while (and (seq-some group-left ps) (< (float-time) deadline))
      (accept-process-output nil 0.1)))
  (dolist (p ps)
    (ignore-errors (signal-process (- (process-id p)) 'KILL))
    (when (process-live-p p) (delete-process p))))

(defun drgnx-check--start (job dir)
  "Start JOB, its output to DIR/NAME.log."
  (let* ((log (expand-file-name (concat (plist-get job :name) ".log") dir))
         ;; a test process ended early stops the harness sessions it started (harness/drgnx-ui.el)
         (process-environment (append (plist-get job :env) (list "DRGNX_UI_STOP_ON_EXIT=1" "DRGNX_CHECK=1") process-environment)))
    (plist-put job :log log)
    (plist-put job :start (float-time))
    (plist-put job :process
               (make-process :name (concat "check-" (plist-get job :name)) :noquery t :connection-type 'pipe
                             ;; no `exec': its pipe to Emacs must stay open until it ends — a job whose pipe is
                             ;; at end-of-file while it runs hides every other job's end from Emacs until it ends
                             ;; stdin empty: a stray prompt in a test reads end-of-file, never waits
                             ;; SIGPIPE ignored: a write to a closed pipe or socket is an error a test can see, never
                             ;; the end of the shard (exit 141 under the parallel GUI tiers)
                             :command (list "sh" "-c" (format "trap '' PIPE; %s < /dev/null > %s 2>&1"
                                                              (mapconcat #'shell-quote-argument (plist-get job :command) " ")
                                                              (shell-quote-argument log)))))))

;;;; The summary

(defun drgnx-check-summary (result)
  "RESULT (`drgnx-check-run') as a table: each job, how it ended, how long, its log."
  (let ((jobs (plist-get result :jobs)))
    (concat
     (mapconcat (lambda (j)
                  (format "%-10s %-16s %7.1f s  %s" (plist-get j :name)
                          (pcase (plist-get j :status)
                            ('ok "ok") ('skipped "skipped") ('timeout "TIMED OUT") ('not-judged "NOT JUDGED (busy)")
                            (_ (format "FAILED (exit %s)" (plist-get j :exit))))
                          (or (plist-get j :seconds) 0) (or (plist-get j :log) "")))
                jobs "\n")
     (format "\ncheck: %s in %.0f s (one after another: %.0f s)\n"
             (if (plist-get result :ok) "all green" "RED")
             (plist-get result :seconds)
             (apply #'+ (mapcar (lambda (j) (or (plist-get j :seconds) 0)) jobs))))))

(defun drgnx-check-exit-code (result) (if (plist-get result :ok) 0 1))

;;;; Command line

(defun drgnx-check--parse-args (args)
  "ARGS of `drgnx check' as (:jobs N :shards N :perf BOOL :gui BOOL), or (:error WHY)."
  (let ((opts (list :jobs 8 :shards 4 :perf t :gui t)) (err nil))
    (while (and args (not err))
      (let ((a (pop args)))
        (pcase a
          ("--no-perf" (setq opts (plist-put opts :perf nil)))
          ("--no-gui" (setq opts (plist-put opts :gui nil)))
          ((or "--jobs" "--shards")
           (let ((v (pop args)))
             (if (and v (string-match-p "\\`[1-9][0-9]*\\'" v))
                 (setq opts (plist-put opts (intern (concat ":" (substring a 2))) (string-to-number v)))
               (setq err (format "%s needs a whole number above 0, not %s" a (or v "nothing"))))))
          (_ (setq err (format "unknown option %s (--no-perf, --no-gui, --jobs N, --shards N)" a))))))
    (if err (list :error err) opts)))

(defvar drgnx-check--jobs nil "The jobs of the run in progress (C-c ends those still running).")

(defun drgnx-check-cli-run (args)
  "`drgnx check [--no-perf] [--no-gui] [--jobs N] [--shards N]'; the exit code (2: bad arguments)."
  (let ((o (drgnx-check--parse-args args)))
    (if (plist-get o :error)
        (progn (princ (format "drgnx check: %s\n" (plist-get o :error))) 2)
      (let* ((slots (drgnx-check-gui-slots))
             (dir (expand-file-name (format-time-string "check/%Y%m%d-%H%M%S") (drgnx-state-dir)))
             (jobs (drgnx-check-plan :unit-shards (plist-get o :shards) :live-shards (max 1 (min 3 slots))
                                     :perf (plist-get o :perf) :gui (plist-get o :gui) :dir dir))
             (_ (princ (format "check: %d jobs, %d GUI at a time (%s MiB free), logs in %s\n"
                               (length jobs) slots (or (drgnx-check--mem-available) "?") dir)))
             (r (drgnx-check-run jobs :dir dir :jobs (plist-get o :jobs) :gui-slots slots :verbose t)))
        (ignore-errors (drgnx-check--save-durations dir))
        (princ (drgnx-check-summary r))
        (drgnx-check-exit-code r)))))

(defun drgnx-check--end-running ()
  "`kill-emacs-hook' (C-c, TERM): end every job still running, giving each time to stop its sessions."
  (when-let* ((ps (seq-filter #'process-live-p (mapcar (lambda (p) (and (string-prefix-p "check-" (process-name p)) p))
                                                       (process-list)))))
    (princ (format "check: ending %d running jobs (up to %d s for them to clean up)\n" (length ps) drgnx-check-grace))
    (apply #'drgnx-check--end ps)))

(defun drgnx-check-cli ()
  "bin/drgnx check: the arguments after --."
  (let ((args (cdr (member "--" command-line-args-left))))
    (setq command-line-args-left nil)
    (add-hook 'kill-emacs-hook #'drgnx-check--end-running)
    (kill-emacs (drgnx-check-cli-run args))))

(provide 'drgnx-check)
;;; drgnx-check.el ends here
