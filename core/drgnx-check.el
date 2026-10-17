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
  '((build . 300) (unit . 900) (ui . 900) (live . 1500) (scenario . 1500) (bench . 1200) (perf . 2400))
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

(cl-defun drgnx-check-plan (&key (root drgnx-dir) (unit-shards 4) (live-shards 2) perf (gui t) dir)
  "The jobs of a check of the checkout ROOT: (:name :phase :command :gui :env :timeout)…  DIR: where shard
results go (default: none)."
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
                               :env (cons "DRGNX_TEST_SELECTOR=(not (tag :timing))" (funcall results name)))
                      jobs))
    ;; the unit tests that measure time, alone once the parallel phase is over
    (push (funcall job "unit-timing" 3 'unit
                   (append (list (drgnx-check--emacs) "--batch" "-Q" "--eval" "(setq load-prefer-newer t)")
                           paths (list "-l" run-ert "-f" "drgnx-run-ert-batch" (expand-file-name "test/unit" root)))
                   :env (cons "DRGNX_TEST_SELECTOR=(tag :timing)" (funcall results "unit-timing")))
          jobs)
    (when gui
      (push (funcall job "ui" 2 'ui (list bin "ui" "test-ui-session") :gui t) jobs)
      (cl-loop for files in (drgnx-check-shard (directory-files-recursively (expand-file-name "test/live" root) "-test\\.el\\'")
                                               live-shards durations)
               for i from 1
               for name = (format "live-%d" i)
               do (push (funcall job name 2 'live
                                 (append (list (drgnx-check--emacs) "--batch" "-Q" "--eval" "(setq load-prefer-newer t)")
                                         paths (list "-l" "drgnx-ui" "-l" run-ert "--eval"
                                                     (format "(kill-emacs (if (drgnx-run-ert '%S (getenv \"DRGNX_TEST_RESULTS\")) 0 1))" files)))
                                 :gui t :env (funcall results name))
                        jobs))
      (push (funcall job "scenario" 2 'scenario (list bin "test" "--scenario" "--config" "drgnx") :gui t
                     :env (list "DRGNX_SCENARIO_TIMEOUT=600"))
            jobs)
      (push (funcall job "bench" 4 'bench (list bin "test" "--bench") :gui t) jobs)
      (when perf (push (funcall job "perf" 5 'perf (list bin "test" "--perf") :gui t) jobs)))
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
                    (plist-put j :status (if (eql (process-exit-status p) 0) 'ok 'failed)))
                  (when verbose (princ (format "check: %s %s (%.0f s)\n" (plist-get j :name) (plist-get j :status) (plist-get j :seconds)))))))))
        (when (and (eql phase 1) (seq-find (lambda (j) (and (eql (plist-get j :phase) 1) (not (eq (plist-get j :status) 'ok)))) all))
          (setq stop t))))
    (list :ok (seq-every-p (lambda (j) (eq (plist-get j :status) 'ok)) all) :jobs all :seconds (- (float-time) t0))))

(defun drgnx-check--end (p)
  "End job process P and everything it started (its process group: Emacs starts each child in its own)."
  (let ((pid (process-id p)))
    (ignore-errors (signal-process (- pid) 'TERM))
    (sleep-for 0.3)
    (ignore-errors (signal-process (- pid) 'KILL))
    (when (process-live-p p) (delete-process p))))

(defun drgnx-check--start (job dir)
  "Start JOB, its output to DIR/NAME.log."
  (let* ((log (expand-file-name (concat (plist-get job :name) ".log") dir))
         (process-environment (append (plist-get job :env) process-environment)))
    (plist-put job :log log)
    (plist-put job :start (float-time))
    (plist-put job :process
               (make-process :name (concat "check-" (plist-get job :name)) :noquery t :connection-type 'pipe
                             ;; no `exec': its pipe to Emacs must stay open until it ends — a job whose pipe is
                             ;; at end-of-file while it runs hides every other job's end from Emacs until it ends
                             :command (list "sh" "-c" (format "%s > %s 2>&1"
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
                            ('ok "ok") ('skipped "skipped") ('timeout "TIMED OUT")
                            (_ (format "FAILED (exit %s)" (plist-get j :exit))))
                          (or (plist-get j :seconds) 0) (or (plist-get j :log) "")))
                jobs "\n")
     (format "\ncheck: %s in %.0f s (one after another: %.0f s)\n"
             (if (plist-get result :ok) "all green" "RED")
             (plist-get result :seconds)
             (apply #'+ (mapcar (lambda (j) (or (plist-get j :seconds) 0)) jobs))))))

(defun drgnx-check-exit-code (result) (if (plist-get result :ok) 0 1))

;;;; Command line

(defun drgnx-check-cli-run (args)
  "`drgnx check [--no-perf] [--no-gui] [--jobs N] [--shards N]'; the exit code."
  (let* ((num (lambda (flag default) (if-let* ((m (member flag args))) (string-to-number (cadr m)) default)))
         (slots (drgnx-check-gui-slots))
         (dir (expand-file-name (format-time-string "check/%Y%m%d-%H%M%S") (drgnx-state-dir)))
         (jobs (drgnx-check-plan :unit-shards (funcall num "--shards" 4) :live-shards (max 1 (min 3 slots))
                                 :perf (not (member "--no-perf" args)) :gui (not (member "--no-gui" args)) :dir dir))
         (_ (princ (format "check: %d jobs, %d GUI at a time (%s MiB free), logs in %s\n"
                           (length jobs) slots (or (drgnx-check--mem-available) "?") dir)))
         (r (drgnx-check-run jobs :dir dir :jobs (funcall num "--jobs" 8) :gui-slots slots :verbose t)))
    (ignore-errors (drgnx-check--save-durations dir))
    (princ (drgnx-check-summary r))
    (drgnx-check-exit-code r)))

(defun drgnx-check-cli ()
  "bin/drgnx check: the arguments after --."
  (let ((args (cdr (member "--" command-line-args-left))))
    (setq command-line-args-left nil)
    (add-hook 'kill-emacs-hook (lambda () (dolist (p (process-list)) (ignore-errors (delete-process p)))))
    (kill-emacs (drgnx-check-cli-run args))))

(provide 'drgnx-check)
;;; drgnx-check.el ends here
