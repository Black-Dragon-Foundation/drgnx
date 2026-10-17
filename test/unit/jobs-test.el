;;; jobs-test.el --- batch tests: durable jobs (detached launcher; no systemd units created) -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-jobs)

(defmacro drgnx-jobs-test--with (&rest body)
  `(let* ((root (make-temp-file "drgnx-jobs" t))
          (process-environment (append (list (concat "XDG_STATE_HOME=" root) "DRGNX_JOBS_LAUNCHER=detached")
                                       process-environment)))
     (unwind-protect (progn ,@body)
       (dolist (j (drgnx-jobs-list)) (ignore-errors (drgnx-jobs-stop (plist-get j :id))))
       (delete-directory root t))))

(defun drgnx-jobs-test--wait (pred &optional secs)
  (let ((deadline (+ (float-time) (or secs 10))) v)
    (while (and (not (setq v (funcall pred))) (< (float-time) deadline)) (sleep-for 0.05))
    v))

(defun drgnx-jobs-test--status (id) (plist-get (drgnx-jobs-get id) :status))

(ert-deftest drgnx-jobs/a-job-outlives-the-emacs-that-started-it ()
  (skip-unless (executable-find "setsid"))
  (drgnx-jobs-test--with
   ;; started by another Emacs, which exits at once
   (let* ((out (with-temp-buffer
                 (call-process (expand-file-name invocation-name invocation-directory) nil t nil
                               "--batch" "-Q" "-L" (file-name-directory (locate-library "drgnx-jobs")) "-l" "drgnx-jobs"
                               "--eval" "(princ (drgnx-jobs-start \"test\" '(\"sh\" \"-c\" \"sleep 1; echo done\")))")
                 (buffer-string)))
          (id (car (last (split-string out "\n" t)))))
     (should (eq (drgnx-jobs-test--status id) 'running))
     (should (drgnx-jobs-test--wait (lambda () (eq (drgnx-jobs-test--status id) 'exited))))
     (should (eql (plist-get (drgnx-jobs-get id) :exit) 0))
     (should (string-match-p "done" (drgnx-jobs-log id))))))

(ert-deftest drgnx-jobs/a-failing-job-says-its-exit-code ()
  (skip-unless (executable-find "setsid"))
  (drgnx-jobs-test--with
   (let ((id (drgnx-jobs-start "fails" '("sh" "-c" "echo oops >&2; exit 7"))))
     (should (drgnx-jobs-test--wait (lambda () (eq (drgnx-jobs-test--status id) 'exited))))
     (should (eql (plist-get (drgnx-jobs-get id) :exit) 7))
     (should (string-match-p "oops" (drgnx-jobs-log id))))))

(ert-deftest drgnx-jobs/stop-ends-the-whole-job ()
  (skip-unless (executable-find "setsid"))
  (drgnx-jobs-test--with
   (let ((id (drgnx-jobs-start "long" '("sh" "-c" "sleep 30"))))
     (should (drgnx-jobs-test--wait (lambda () (eq (drgnx-jobs-test--status id) 'running))))
     (drgnx-jobs-stop id)
     (should (drgnx-jobs-test--wait (lambda () (memq (drgnx-jobs-test--status id) '(exited stopped))) 3))
     (should-not (seq-find (lambda (p) (string-match-p "sleep 30" (or (cdr (assq 'args (process-attributes p))) "")))
                           (list-system-processes))))))

(ert-deftest drgnx-jobs/a-job-whose-process-vanished-is-gone ()
  (drgnx-jobs-test--with
   (let* ((dir (expand-file-name "drgnx/jobs/20261017-000000-1" (getenv "XDG_STATE_HOME"))))
     (make-directory dir t)
     (with-temp-file (expand-file-name "job.eld" dir)
       (prin1 '(:id "20261017-000000-1" :name "old" :command ("x") :launcher detached :started "then") (current-buffer)))
     (write-region "999999999" nil (expand-file-name "pid" dir) nil 'silent)
     (should (eq (drgnx-jobs-test--status "20261017-000000-1") 'gone))
     (should (equal (mapcar (lambda (j) (plist-get j :name)) (drgnx-jobs-list)) '("old"))))))

;;; jobs-test.el ends here
