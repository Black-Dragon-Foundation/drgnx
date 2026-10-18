;;; drgnx-jobs.el --- Durable jobs: background work that outlives Emacs and an interrupted chat -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A job is a command run detached from Emacs — a systemd user unit (`systemd-run --user') where
;; systemd runs the session, else its own session and process group (`drgnx-jobs--detach': `setsid',
;; or perl on macOS) — so closing a frame, restarting Emacs or interrupting a chat cannot kill it.
;; Everything about a job lives in its directory under the state dir (jobs/ID: job.eld, log, pid,
;; exit), so a new Emacs lists it, shows its log and stops it.  See docs/guide/agents.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-timer)

(defun drgnx-jobs-dir () (file-name-as-directory (expand-file-name "jobs" (drgnx-state-dir))))
(defun drgnx-jobs--dir (id) (file-name-as-directory (expand-file-name id (drgnx-jobs-dir))))

(defun drgnx-jobs-launcher ()
  "`systemd' when a systemd user manager runs this session, else `detached' ($DRGNX_JOBS_LAUNCHER wins)."
  (let ((env (getenv "DRGNX_JOBS_LAUNCHER")))
    (cond (env (intern env))
          ((and (executable-find "systemd-run") (getenv "XDG_RUNTIME_DIR")
                (file-exists-p (expand-file-name "systemd" (getenv "XDG_RUNTIME_DIR"))))
           'systemd)
          (t 'detached))))

(defun drgnx-jobs--read (file)
  (and (file-readable-p file) (ignore-errors (with-temp-buffer (insert-file-contents file) (read (current-buffer))))))

(defun drgnx-jobs--text (file)
  (and (file-readable-p file) (string-trim (with-temp-buffer (insert-file-contents file) (buffer-string)))))

(defun drgnx-jobs--new-id ()
  (let ((base (format-time-string "%Y%m%d-%H%M%S")) (n 1))
    (while (file-exists-p (drgnx-jobs--dir (format "%s-%d" base n))) (setq n (1+ n)))
    (format "%s-%d" base n)))

(defun drgnx-jobs--wrapper (dir command &optional head)
  "A shell line running COMMAND in its own group: output to DIR/log, its pid to DIR/pid, its exit
code to DIR/exit (143 when stopped); with HEAD, the git HEAD it ended at to DIR/head first."
  (let ((q (lambda (f) (shell-quote-argument (expand-file-name f dir)))))
    ;; the paths in shell variables: quoting stays right inside the trap's single quotes
    (format "p=%s; e=%s; l=%s; h=%s; _drgnx_head() { %s; }; echo $$ > \"$p\"; trap '_drgnx_head; echo 143 > \"$e\"; exit 143' TERM; %s > \"$l\" 2>&1 & wait $!; s=$?; _drgnx_head; echo $s > \"$e\""
            (funcall q "pid") (funcall q "exit") (funcall q "log") (funcall q "head")
            (if head "git rev-parse HEAD > \"$h\" 2>/dev/null" ":")
            (mapconcat #'shell-quote-argument command " "))))

(defvar drgnx-jobs--boot-id-cache nil "This boot's id once found: it cannot change while this Emacs runs.")

(defun drgnx-jobs--boot-id ()
  "This boot's id: Linux's boot_id; on macOS the boot session's UUID (`sysctl -n kern.bootsessionuuid' — not
kern.boottime, which moves when the clock is set); nil when there is none.  Asked once per Emacs: on macOS it
is a process, and `drgnx-jobs-get' wants it for every live job."
  (or drgnx-jobs--boot-id-cache
      (setq drgnx-jobs--boot-id-cache
            (ignore-errors
              (if (eq system-type 'darwin)
                  (with-temp-buffer
                    (and (eql 0 (call-process "sysctl" nil t nil "-n" "kern.bootsessionuuid"))
                         (let ((id (string-trim (buffer-string)))) (and (not (string-empty-p id)) id))))
                (string-trim (with-temp-buffer (insert-file-contents "/proc/sys/kernel/random/boot_id")
                                               (buffer-string))))))))

(defvar drgnx-jobs--setsid (executable-find "setsid")
  "setsid(1) where the system has it (Linux; macOS has none).")

(defun drgnx-jobs--detach (line)
  "Start `sh -c LINE' in its own session and process group, not waited for, outliving this Emacs: `setsid -f'
where there is one, else perl (every macOS has it).  perl forks first, as `setsid -f' does: Emacs's child already
leads its own process group, and setsid(2) refuses a group leader."
  (if drgnx-jobs--setsid
      (call-process "setsid" nil 0 nil "-f" "sh" "-c" line)
    (call-process "perl" nil 0 nil "-MPOSIX" "-e" "fork and exit; POSIX::setsid(); exec @ARGV" "sh" "-c" line)))

(defun drgnx-jobs--systemd-args (id cwd line env &optional task memory-max nice)
  "systemd-run's arguments for job ID running LINE in CWD.  ENV (\"NAME=value\"…) travels in systemd-run's own
environment — `--setenv=NAME' copies it from there — so no value (a key) is ever in a command line.  MEMORY-MAX
(\"1G\"): the unit may use no more memory, and no swap.  NICE (10): its scheduling niceness.
LINE goes through systemd's ExecStart, which reads `$$' as `$' and substitutes `${NAME}': every `$' is doubled
so the shell gets LINE as written (its `echo $$ > pid' records the job's real pid, not a literal `$')."
  (append (list "--user" "--quiet" "--collect" (concat "--unit=drgnx-job-" id) (concat "--working-directory=" cwd)
                (concat "--setenv=PATH=" (or (getenv "PATH") "")) (concat "--setenv=HOME=" (or (getenv "HOME") "")))
          (and task (list (concat "--setenv=DRGNX_TASK=" task)))
          (mapcar (lambda (e) (concat "--setenv=" (car (split-string e "=")))) env)
          (and memory-max (list "-p" (concat "MemoryMax=" memory-max) "-p" "MemorySwapMax=0"))
          (and nice (list "-p" (format "Nice=%d" nice)))
          (list "sh" "-c" (string-replace "$" "$$" line))))

(cl-defun drgnx-jobs-start (name command &key cwd task env memory-max nice no-wait)
  "Run COMMAND (a list) as the durable job NAME in CWD.  Returns the job's id.  TASK (a work-tracker
node id): the job gets it as DRGNX_TASK, and the git HEADs it started and ended at are kept, so the
commits it made are recorded for the task (docs/guide/work.md).  ENV (\"NAME=value\"…, e.g. an agent's
keys) is the job's too, and is kept nowhere: not in its state files, not in a command line.  MEMORY-MAX
(\"1G\"): the systemd launcher caps the job's memory (MemoryMax, no swap); NICE (10) lowers its priority
(Nice=); the detached launcher can do neither and ignores both.  NO-WAIT: return without waiting (up to
two seconds) for the job's pid — its boot and start time are stamped from a short timer once the pid file
appears, or when Emacs exits first — for callers that must not block (a timer started from a sentinel).
Signals a `user-error' (before anything is created) when the detached launcher has neither setsid nor perl."
  (let* ((id (drgnx-jobs--new-id)) (dir (drgnx-jobs--dir id))
         (cwd (expand-file-name (or cwd default-directory)))
         (launcher (drgnx-jobs-launcher))
         (git (lambda (&rest args) (with-temp-buffer
                                     (let ((default-directory (file-name-as-directory cwd)))
                                       (and (eql 0 (apply #'call-process "git" nil t nil args)) (string-trim (buffer-string)))))))
         (head (and task (funcall git "rev-parse" "HEAD")))
         ;; the repository itself: the job's worktree may be gone when its commits are collected
         (git-dir (and task (funcall git "rev-parse" "--path-format=absolute" "--git-common-dir")))
         (process-environment (append env (and task (list (concat "DRGNX_TASK=" task))) process-environment))
         (line (drgnx-jobs--wrapper dir command task)))
    ;; before anything is created: a missing program would surface as `call-process''s "file is missing"
    (unless (or (eq launcher 'systemd) drgnx-jobs--setsid (executable-find "perl"))
      (user-error "Detached jobs need setsid or perl"))
    (make-directory dir t)
    (with-temp-file (expand-file-name "job.eld" dir)
      (prin1 (list :id id :name name :command command :cwd cwd :launcher launcher :task task :head head :git-dir git-dir :start-time (float-time)
                   :unit (and (eq launcher 'systemd) (concat "drgnx-job-" id))
                   :started (format-time-string "%FT%T%z"))
             (current-buffer)))
    (let ((default-directory (file-name-as-directory cwd)))
      (pcase launcher
        ('systemd
         (with-temp-buffer
           (unless (eql 0 (apply #'call-process "systemd-run" nil t nil (drgnx-jobs--systemd-args id cwd line env task memory-max nice)))
             (error "The job %s did not start: %s" name (string-trim (buffer-string))))))
        (_ (drgnx-jobs--detach line))))
    ;; the pid file appears once the job's shell runs; the boot and the process's start time make
    ;; the pid trustworthy later (a pid from before a reboot may be another process)
    (let ((deadline (+ (float-time) 2)) (pidf (expand-file-name "pid" dir)))
      (if no-wait
          (let ((key (cons 'jobs-stamp id)) on-exit)
            ;; the poll stamps once the pid is there, or gives up after 2 s.  When Emacs exits first, this hook
            ;; ends the poll and stamps (waiting out the deadline for the pid at most); a poll that ended
            ;; already leaves nothing to do, so a job is stamped once
            (setq on-exit (lambda ()
                            (remove-hook 'kill-emacs-hook on-exit)
                            (when (drgnx-timer-active-p key)
                              (while (and (not (file-exists-p pidf)) (< (float-time) deadline))
                                (sleep-for 0.02))
                              (drgnx-timer-cancel key)
                              (drgnx-jobs--stamp-anyway dir))))
            (add-hook 'kill-emacs-hook on-exit)
            (drgnx-timer-poll key 0.05 #'drgnx-jobs--stamp-when-ready :deadline 2
                              :on-timeout #'drgnx-jobs--stamp-anyway :args (list dir) :owner :core))
        (while (and (not (file-exists-p pidf)) (< (float-time) deadline)) (sleep-for 0.02))
        (drgnx-jobs--stamp dir)))
    id))

(defun drgnx-jobs--stamp-when-ready (dir)
  "Stamp the job in DIR and return t once its pid file is there; nil until then (the poll's function)."
  (when (file-exists-p (expand-file-name "pid" dir))
    (drgnx-jobs--stamp-anyway dir)
    t))

(defun drgnx-jobs--stamp-anyway (dir)
  "Stamp the job in DIR if it can be; the job's directory may be gone by now (a removed job)."
  (ignore-errors (drgnx-jobs--stamp dir)))

(defun drgnx-jobs--stamp (dir)
  "Add the boot and the start time of the job in DIR's process to its job.eld, once its pid file is there."
  (let ((pidf (expand-file-name "pid" dir)))
    (when-let* ((pid (and (file-exists-p pidf) (string-to-number (or (drgnx-jobs--text pidf) "0"))))
                (attrs (and (> pid 0) (process-attributes pid))))
      (let ((job (drgnx-jobs--read (expand-file-name "job.eld" dir))))
        (with-temp-file (expand-file-name "job.eld" dir)
          (prin1 (append job (list :boot (drgnx-jobs--boot-id) :start (alist-get 'start attrs))) (current-buffer)))))))

(defun drgnx-jobs-get (id)
  "Job ID: its job.eld plus :status (running, exited, stopped or gone) and :exit."
  (let* ((dir (drgnx-jobs--dir id)) (job (drgnx-jobs--read (expand-file-name "job.eld" dir))))
    (when job
      (let* ((exit (drgnx-jobs--text (expand-file-name "exit" dir)))
             (pid (string-to-number (or (drgnx-jobs--text (expand-file-name "pid" dir)) "0")))
             (attrs (and (> pid 0) (process-attributes pid)))
             (alive (and attrs
                         (or (null (plist-get job :boot)) (equal (plist-get job :boot) (drgnx-jobs--boot-id)))
                         ;; the same start, give or take the clock tick Emacs's reading of it jitters by
                         (or (null (plist-get job :start))
                             (< (abs (float-time (time-subtract (plist-get job :start) (alist-get 'start attrs)))) 0.5)))))
        (append job
                (list :exit (and exit (string-to-number exit)) :pid (and (> pid 0) pid)
                      :status (cond (exit (if (equal exit "143") 'stopped 'exited))
                                    (alive 'running)
                                    ((and (eq (plist-get job :launcher) 'systemd)
                                          (equal (plist-get job :boot) (drgnx-jobs--boot-id))
                                          (eql 0 (call-process "systemctl" nil nil nil "--user" "--quiet" "is-active" (plist-get job :unit))))
                                     'running)
                                    (t 'gone))))))))

(defun drgnx-jobs-list ()
  "Every job, newest first."
  (delq nil (mapcar #'drgnx-jobs-get
                    (sort (and (file-directory-p (drgnx-jobs-dir)) (directory-files (drgnx-jobs-dir) nil "\\`[0-9]"))
                          (lambda (a b) (string> a b))))))

(defun drgnx-jobs-log (id &optional max)
  "The end of job ID's log (MAX characters, default 20000)."
  (let ((f (expand-file-name "log" (drgnx-jobs--dir id))))
    (if (not (file-readable-p f)) ""
      (with-temp-buffer
        (insert-file-contents f)
        (buffer-substring (max (point-min) (- (point-max) (or max 20000))) (point-max))))))

(defcustom drgnx-jobs-stop-wait 3
  "Seconds `drgnx-jobs-stop' waits for a systemd job's unit to go down before it returns.
A job that ignores TERM keeps its unit \"deactivating\" until systemd kills it (90 s): Stop returns after this
long and leaves that to systemd."
  :type 'number :group 'drgnx)

(defun drgnx-jobs--unit-down-p (unit)
  "Non-nil when systemd UNIT is neither active nor on its way down (inactive, failed, or gone)."
  (not (member (with-temp-buffer
                 (call-process "systemctl" nil t nil "--user" "is-active" unit)
                 (string-trim (buffer-string)))
               '("active" "activating" "deactivating" "reloading"))))

(defun drgnx-jobs-stop (id)
  "Stop job ID (its whole process group, or its unit).  A systemd unit is asked to stop without waiting for it
\(`systemctl stop' would hold this for the unit's TimeoutStopSec, 90 s, while a process of the job ignores TERM):
this returns once the whole unit is down, so the job's children are gone too, or after `drgnx-jobs-stop-wait'
seconds."
  (let ((job (drgnx-jobs-get id)))
    (when (eq (plist-get job :status) 'running)
      (if (eq (plist-get job :launcher) 'systemd)
          (let ((unit (plist-get job :unit)) (deadline (+ (float-time) drgnx-jobs-stop-wait)))
            (call-process "systemctl" nil nil nil "--user" "--no-block" "stop" unit)
            (while (and (< (float-time) deadline) (not (drgnx-jobs--unit-down-p unit)))
              (sleep-for 0.05)))
        ;; only a pid verified as the job's (status `running' checked the boot and the start time)
        (when-let* ((pid (plist-get job :pid))) (signal-process (- pid) 'SIGTERM))))))

(provide 'drgnx-jobs)
;;; drgnx-jobs.el ends here
