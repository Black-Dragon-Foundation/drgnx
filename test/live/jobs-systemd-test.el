;;; jobs-systemd-test.el --- live tests: durable jobs under a real systemd user manager -*- lexical-binding: t -*-
;; These need the user's systemd and its session bus, which the unit tier hides from its tests (it starts Emacs with
;; a dead bus and its own XDG_RUNTIME_DIR, see docs/develop/harness.md): so they live here, for `drgnx test --ui'
;; (`drgnx check''s live shards are sandboxed too).  Without a systemd user manager they skip.
(require 'ert)
(require 'drgnx-jobs)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))

(defmacro drgnx-jobs-test--with (&rest body)
  `(let* ((root (make-temp-file "drgnx-jobs" t))
          (process-environment (append (list (concat "XDG_STATE_HOME=" root) "DRGNX_JOBS_LAUNCHER=detached")
                                       process-environment)))
     (unwind-protect (progn ,@body)
       (drgnx-jobs-test--stop-all)
       (delete-directory root t))))

(defun drgnx-jobs-test--wait (pred &optional secs)
  (drgnx-test-wait pred :secs (max 30 (or secs 0)) :what "the systemd jobs test's predicate"))

(defun drgnx-jobs-test--stop-all ()
  "Stop every running job and wait until each has written its exit file."
  (let ((ids (delq nil (mapcar (lambda (j) (and (eq (plist-get j :status) 'running) (plist-get j :id)))
                               (drgnx-jobs-list)))))
    (dolist (id ids) (ignore-errors (drgnx-jobs-stop id)))
    (dolist (id ids)
      (drgnx-jobs-test--wait (lambda () (file-exists-p (expand-file-name "exit" (drgnx-jobs--dir id)))) 5))))

(defun drgnx-jobs-test--status (id) (plist-get (drgnx-jobs-get id) :status))

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

(defun drgnx-jobs-test--unit-state (id)
  (with-temp-buffer
    (call-process "systemctl" nil t nil "--user" "is-active" (concat "drgnx-job-" id))
    (string-trim (buffer-string))))

(ert-deftest drgnx-jobs/stop-returns-once-the-whole-unit-is-down ()
  ;; fix round 1: the wrapper shell ends at once on TERM, but a child needing a moment to clean up is still in the
  ;; unit; a caller restarting the work right after Stop must not overlap it
  (skip-unless (drgnx-jobs-test--systemd-p))
  (drgnx-jobs-test--with
   (let ((process-environment (cons "DRGNX_JOBS_LAUNCHER=systemd" process-environment)) (drgnx-jobs-stop-wait 3) id)
     (unwind-protect
         (progn
           (setq id (drgnx-jobs-start
                     "tidy" '("sh" "-c" "trap 'sleep 1; exit 0' TERM; while :; do sleep 0.1; done")))
           (should (eq (drgnx-jobs-test--status id) 'running))
           (let ((t0 (float-time)))
             (drgnx-jobs-stop id)
             (should (< (- (float-time) t0) 3.5)))
           (should-not (member (drgnx-jobs-test--unit-state id) '("active" "activating" "deactivating"))))
       (when id (call-process "systemctl" nil nil nil "--user" "kill" "--signal=SIGKILL" (concat "drgnx-job-" id)))))))

(ert-deftest drgnx-jobs/a-systemd-job-keeps-its-dollars ()
  ;; systemd's ExecStart reads `$$' and `${NAME}' itself: the user's command gets its own `$$' (the shell's pid) and
  ;; `${HOME}' as written, run under a real unit
  (skip-unless (drgnx-jobs-test--systemd-p))
  (drgnx-jobs-test--with
   (let ((process-environment (cons "DRGNX_JOBS_LAUNCHER=systemd" process-environment)) id)
     (unwind-protect
         (progn
           (setq id (drgnx-jobs-start "dollars" '("sh" "-c" "echo \"pid=$$ home=${HOME}\"")))
           (should (drgnx-jobs-test--wait (lambda () (eq (drgnx-jobs-test--status id) 'exited))))
           (should (string-match "\\`pid=\\([0-9]+\\) home=\\(.*\\)\n?\\'" (drgnx-jobs-log id)))
           (should (equal (match-string 2 (drgnx-jobs-log id)) (getenv "HOME"))))
       (when id (call-process "systemctl" nil nil nil "--user" "stop" (concat "drgnx-job-" id)))))))

;;; jobs-systemd-test.el ends here
