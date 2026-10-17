;;; drgnx-jobs.el --- Durable jobs: background work that outlives Emacs and an interrupted chat -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A job is a command run detached from Emacs — a systemd user unit (`systemd-run --user') where
;; systemd runs the session, else its own process group (`setsid') — so closing a frame, restarting
;; Emacs or interrupting a chat cannot kill it.  Everything about a job lives in its directory under
;; the state dir (jobs/ID: job.eld, log, pid, exit), so a new Emacs lists it, shows its log and stops
;; it.  See docs/agents.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-paths)

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

(defun drgnx-jobs--wrapper (dir command)
  "A shell line running COMMAND in its own group: output to DIR/log, its pid to DIR/pid, its exit
code to DIR/exit (143 when stopped)."
  (let ((q (lambda (f) (shell-quote-argument (expand-file-name f dir)))))
    ;; the paths in shell variables: quoting stays right inside the trap's single quotes
    (format "p=%s; e=%s; l=%s; echo $$ > \"$p\"; trap 'echo 143 > \"$e\"; exit 143' TERM; %s > \"$l\" 2>&1 & wait $!; echo $? > \"$e\""
            (funcall q "pid") (funcall q "exit") (funcall q "log")
            (mapconcat #'shell-quote-argument command " "))))

(defun drgnx-jobs--boot-id ()
  (ignore-errors (string-trim (with-temp-buffer (insert-file-contents "/proc/sys/kernel/random/boot_id") (buffer-string)))))

(cl-defun drgnx-jobs-start (name command &key cwd)
  "Run COMMAND (a list) as the durable job NAME in CWD.  Returns the job's id."
  (let* ((id (drgnx-jobs--new-id)) (dir (drgnx-jobs--dir id))
         (cwd (expand-file-name (or cwd default-directory)))
         (launcher (drgnx-jobs-launcher))
         (line (drgnx-jobs--wrapper dir command)))
    (make-directory dir t)
    (with-temp-file (expand-file-name "job.eld" dir)
      (prin1 (list :id id :name name :command command :cwd cwd :launcher launcher
                   :unit (and (eq launcher 'systemd) (concat "drgnx-job-" id))
                   :started (format-time-string "%FT%T%z"))
             (current-buffer)))
    (let ((default-directory (file-name-as-directory cwd)))
      (pcase launcher
        ('systemd
         (with-temp-buffer
           (unless (eql 0 (call-process "systemd-run" nil t nil "--user" "--quiet" "--collect"
                                        (concat "--unit=drgnx-job-" id) (concat "--working-directory=" cwd)
                                        (concat "--setenv=PATH=" (or (getenv "PATH") "")) (concat "--setenv=HOME=" (or (getenv "HOME") ""))
                                        "sh" "-c" line))
             (error "The job %s did not start: %s" name (string-trim (buffer-string))))))
        (_ (call-process "setsid" nil 0 nil "-f" "sh" "-c" line))))
    ;; the pid file appears once the job's shell runs; the boot and the process's start time make
    ;; the pid trustworthy later (a pid from before a reboot may be another process)
    (let ((deadline (+ (float-time) 2)) (pidf (expand-file-name "pid" dir)))
      (while (and (not (file-exists-p pidf)) (< (float-time) deadline)) (sleep-for 0.02))
      (when-let* ((pid (and (file-exists-p pidf) (string-to-number (or (drgnx-jobs--text pidf) "0"))))
                  (attrs (and (> pid 0) (process-attributes pid))))
        (let ((job (drgnx-jobs--read (expand-file-name "job.eld" dir))))
          (with-temp-file (expand-file-name "job.eld" dir)
            (prin1 (append job (list :boot (drgnx-jobs--boot-id) :start (alist-get 'start attrs))) (current-buffer))))))
    id))

(defun drgnx-jobs-get (id)
  "Job ID: its job.eld plus :status (running, exited, stopped or gone) and :exit."
  (let* ((dir (drgnx-jobs--dir id)) (job (drgnx-jobs--read (expand-file-name "job.eld" dir))))
    (when job
      (let* ((exit (drgnx-jobs--text (expand-file-name "exit" dir)))
             (pid (string-to-number (or (drgnx-jobs--text (expand-file-name "pid" dir)) "0")))
             (attrs (and (> pid 0) (process-attributes pid)))
             (alive (and attrs
                         (or (null (plist-get job :boot)) (equal (plist-get job :boot) (drgnx-jobs--boot-id)))
                         (or (null (plist-get job :start)) (equal (plist-get job :start) (alist-get 'start attrs))))))
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

(defun drgnx-jobs-stop (id)
  "Stop job ID (its whole process group, or its unit)."
  (let ((job (drgnx-jobs-get id)))
    (when (eq (plist-get job :status) 'running)
      (if (eq (plist-get job :launcher) 'systemd)
          (call-process "systemctl" nil nil nil "--user" "stop" (plist-get job :unit))
        ;; only a pid verified as the job's (status `running' checked the boot and the start time)
        (when-let* ((pid (plist-get job :pid))) (signal-process (- pid) 'SIGTERM))))))

(provide 'drgnx-jobs)
;;; drgnx-jobs.el ends here
