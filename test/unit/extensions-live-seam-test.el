;;; extensions-live-seam-test.el --- the job layer drives live activation: what a job's end passes, which jobs count -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: no process and no real clock.  The job layer runs as in extensions-jobs-test.el (the hub stubbed at the
;; job client, the batch sync played by the test, the progress reads on the virtual clock) with the live layer's hooks
;; on it, so the live layer sees what a real job's end gives it, never a hand-made object.  Package directories are
;; empty folders (or a descriptor and an autoloads file) under a temp data directory.  See docs/guide/extensions.md,
;; "When a restart is needed".
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-paths)
(require 'drgnx-file)
(require 'drgnx-timer)
(require 'drgnx-exec)
(require 'drgnx-pkg-wants)
(require 'drgnx-pkg)
(require 'package)
(load (expand-file-name "modules/tools/drgnx-extensions-jobs" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-extensions-live" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)

(defvar drgnx-extensions-live-seam-test--starts nil "The jobs started, newest first: (:id ID :argv ARGV :load-path LP).")
(defvar drgnx-extensions-live-seam-test--list nil "The callback of the last `exec/list' call.")
(defvar drgnx-extensions-live-seam-test--notify nil "The progress watch's callback.")
(defvar drgnx-extensions-live-seam-test--calls nil "What the live layer did when a job ended, newest first.")

(defun drgnx-extensions-live-seam-test--start (name argv &rest keys)
  "The stub of `drgnx-exec-start': records the start, with `load-path' as it was then, and answers at once."
  (let ((id (format "job-%d" (1+ (length drgnx-extensions-live-seam-test--starts)))))
    (push (list :id id :name name :argv argv :load-path (copy-sequence load-path)) drgnx-extensions-live-seam-test--starts)
    (funcall (plist-get keys :callback) id nil)
    nil))

(defmacro drgnx-extensions-live-seam-test--with (&rest body)
  "BODY with every drgnx location a temp directory (ROOT names it), the hub stubbed, the job layer and the live
layer's hooks set up (torn down after), on the virtual clock; `--settle' and `--point-back' record that they ran."
  (declare (indent 0) (debug t))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-ext-seam" t)))
          (process-environment (append (list (concat "XDG_STATE_HOME=" root "state") (concat "DRGNX_DATA_DIR=" root "data")
                                             (concat "DRGNX_CONFIG_DIR=" root "config") (concat "XDG_CACHE_HOME=" root "cache"))
                                       process-environment))
          (load-path load-path) (package-activated-list package-activated-list)
          (drgnx-exec--jobs (make-hash-table :test #'equal)) (drgnx-exec--stale nil)
          (drgnx-hub-event-functions nil) (drgnx-hub-disconnect-functions nil) (drgnx-exec-listed-hook nil)
          (drgnx-extensions-jobs-changed-functions nil) (drgnx-extensions-jobs-plan-functions nil)
          (drgnx-extensions-jobs-done-functions nil) (drgnx-extensions-jobs-before-functions nil)
          (drgnx-extensions-jobs-plan-gone-functions nil) (kill-emacs-hook nil)
          (drgnx-extensions-live--restart nil) (drgnx-extensions-live--moved nil) (drgnx-extensions-live--marked nil)
          (drgnx-extensions-live--removing nil) (drgnx-extensions-live--keys nil)
          (drgnx-extensions-live-seam-test--starts nil) (drgnx-extensions-live-seam-test--list nil)
          (drgnx-extensions-live-seam-test--notify nil) (drgnx-extensions-live-seam-test--calls nil))
     (make-directory (concat root "config") t)
     (unwind-protect
         (drgnx-test-with-clock ()
           (cl-letf (((symbol-function 'drgnx-exec-start) #'drgnx-extensions-live-seam-test--start)
                     ((symbol-function 'drgnx-exec-stop) #'ignore)
                     ((symbol-function 'drgnx-hub-call)
                      (lambda (method _params callback &rest _)
                        (when (equal method "exec/list") (setq drgnx-extensions-live-seam-test--list callback))))
                     ((symbol-function 'drgnx-hub-connect) #'ignore)
                     ((symbol-function 'file-notify-add-watch)
                      (lambda (_dir _flags callback) (setq drgnx-extensions-live-seam-test--notify callback) 'watch))
                     ((symbol-function 'file-notify-rm-watch) #'ignore)
                     ((symbol-function 'drgnx-modules-retry-waiting) #'ignore)
                     ((symbol-function 'drgnx-pkg-current-generation) (lambda () 1)))
             (unwind-protect
                 (progn (drgnx-extensions-jobs-setup)
                        (drgnx-extensions-live-setup)
                        (funcall drgnx-extensions-live-seam-test--list (list :jobs nil) nil)
                        ,@body)
               (drgnx-extensions-jobs-teardown))))
       (delete-directory root t))))

(defmacro drgnx-extensions-live-seam-test--spying (&rest body)
  "BODY with `--settle' and `--point-back' recording that they ran, and doing nothing else."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'drgnx-extensions-live--settle)
              (lambda () (push 'settle drgnx-extensions-live-seam-test--calls)))
             ((symbol-function 'drgnx-extensions-live--point-back)
              (lambda () (push 'point-back drgnx-extensions-live-seam-test--calls))))
     ,@body))

(defun drgnx-extensions-live-seam-test--job (n)
  (nth (- (length drgnx-extensions-live-seam-test--starts) n) drgnx-extensions-live-seam-test--starts))

(defun drgnx-extensions-live-seam-test--file (job) (cadr (member "--progress" (plist-get job :argv))))

(defun drgnx-extensions-live-seam-test--write (file object)
  (make-directory (file-name-directory file) t)
  (with-temp-file file (insert (json-serialize object))))

(defun drgnx-extensions-live-seam-test--take (job)
  "What JOB's `drgnx sync --pending' does: take the queue, write its start step."
  (let ((tickets (mapcar (lambda (e) (plist-get e :ticket)) (drgnx-pkg-pending-take))))
    (drgnx-extensions-live-seam-test--write (drgnx-extensions-live-seam-test--file job)
                                            (list :step "start" :command "sync" :tickets (vconcat tickets)))))

(defun drgnx-extensions-live-seam-test--seen (&optional file)
  "The watch tells of a change to FILE (nil: an event that names no file), and the read it asks for runs."
  (funcall drgnx-extensions-live-seam-test--notify (if file (list 'watch 'changed file) (list 'watch 'changed)))
  (drgnx-test-advance 1))

(defun drgnx-extensions-live-seam-test--done (job &optional exit)
  "The hub's exec-done event for JOB, EXIT (default 0)."
  (run-hook-with-args 'drgnx-hub-event-functions "exec-done"
                      (list :id (plist-get job :id) :status "done" :exit (or exit 0)
                            :summary (list :exit (or exit 0) :lines nil))))

(defun drgnx-extensions-live-seam-test--package (root dir &optional generation)
  "An empty package directory DIR (\"fa-1.0\") in ROOT's elpa/ (or in GENERATION's): its file name."
  (let ((d (if generation (format "%sdata/generations/%d/elpa/%s" root generation dir) (format "%sdata/elpa/%s" root dir))))
    (make-directory d t)
    d))

(ert-deftest drgnx-extensions-live-seam/a-sync-that-ends-well-settles-and-one-that-fails-points-back ()
  ;; the job layer's own end of a real queue run, not a progress file's done object
  (drgnx-extensions-live-seam-test--with
    (drgnx-extensions-live-seam-test--spying
      (dolist (exit '(0 1))
        (setq drgnx-extensions-live-seam-test--calls nil)
        (drgnx-extensions-jobs-queue '(:add fb))
        (let* ((job (car drgnx-extensions-live-seam-test--starts)) (file (drgnx-extensions-live-seam-test--file job)))
          (drgnx-extensions-live-seam-test--take job)
          (drgnx-extensions-live-seam-test--write (concat file ".plan.json")
                                                  '(:step "plan" :seq 1 :generation 1 :replaces [] :removes [] :adds ["fb-1.0"]))
          (drgnx-extensions-live-seam-test--seen (concat file ".plan.json"))
          (drgnx-extensions-live-seam-test--done job exit)
          (should (equal drgnx-extensions-live-seam-test--calls (if (= exit 0) '(settle) '(point-back)))))))))

(ert-deftest drgnx-extensions-live-seam/a-queued-click-repoints-before-its-job-starts ()
  (drgnx-extensions-live-seam-test--with
    (let ((now (drgnx-extensions-live-seam-test--package root "fa-1.0"))
          (copy (drgnx-extensions-live-seam-test--package root "fa-1.0" 1)))
      (push now load-path)
      (drgnx-extensions-jobs-queue '(:remove fa))
      ;; when the hub was asked to start the job, the session already used generation 1's copy
      (let ((lp (plist-get (car drgnx-extensions-live-seam-test--starts) :load-path)))
        (should (member copy lp))
        (should-not (member now lp)))
      ;; an update of it too
      (setq load-path (cons now (delete copy load-path)))
      (drgnx-extensions-jobs-run 'upgrade '(fa))
      (should (member copy (plist-get (car drgnx-extensions-live-seam-test--starts) :load-path))))))

(ert-deftest drgnx-extensions-live-seam/another-jobs-end-leaves-the-repoint ()
  (drgnx-extensions-live-seam-test--with
    (drgnx-extensions-live-seam-test--spying
      (let ((now (drgnx-extensions-live-seam-test--package root "fa-1.0"))
            (copy (drgnx-extensions-live-seam-test--package root "fa-1.0" 1)))
        (push now load-path)
        (drgnx-extensions-jobs-run 'upgrade '(fa))
        (let* ((sync (car drgnx-extensions-live-seam-test--starts)) (file (drgnx-extensions-live-seam-test--file sync)))
          (drgnx-extensions-live-seam-test--write (concat file ".plan.json")
                                                  '(:step "plan" :seq 1 :generation 1 :replaces ["fa-1.0"] :removes [] :adds ["fa-1.1"]))
          (drgnx-extensions-live-seam-test--seen (concat file ".plan.json"))
          (should (member copy load-path))
          ;; a readme job ends while the update is between its plan and its end: nothing moves
          (drgnx-extensions-jobs-run 'fetch-readme "melpa" "fb")
          (drgnx-extensions-live-seam-test--done (car drgnx-extensions-live-seam-test--starts))
          (should-not drgnx-extensions-live-seam-test--calls)
          (should (member copy load-path))
          ;; the update's own end settles
          (drgnx-extensions-live-seam-test--done sync)
          (should (equal drgnx-extensions-live-seam-test--calls '(settle))))))))

(ert-deftest drgnx-extensions-live-seam/a-plan-of-another-session-settles-when-it-goes ()
  (drgnx-extensions-live-seam-test--with
    (drgnx-extensions-live-seam-test--spying
      (let ((now (drgnx-extensions-live-seam-test--package root "fa-1.0"))
            (copy (drgnx-extensions-live-seam-test--package root "fa-1.0" 1))
            (theirs (expand-file-name "4242-1-abcdef.json.plan.json" (drgnx-extensions-jobs-dir))))
        (push now load-path)
        (drgnx-extensions-live-seam-test--write theirs '(:step "plan" :seq 1 :generation 1 :replaces ["fa-1.0"] :removes [] :adds []))
        (drgnx-extensions-live-seam-test--seen theirs)
        (should (member copy load-path))
        (should-not drgnx-extensions-live-seam-test--calls)
        ;; its job ended in the other session, which deleted the plan file: this one settles
        (delete-file theirs)
        (drgnx-extensions-live-seam-test--seen theirs)
        (should (equal drgnx-extensions-live-seam-test--calls '(settle)))))))

(ert-deftest drgnx-extensions-live-seam/a-repoint-walks-load-path-once ()
  (drgnx-extensions-live-seam-test--with
    (let ((dirs (mapcar (lambda (i) (format "p%d-1.0" i)) (number-sequence 1 40))) (calls 0))
      (dolist (d dirs)
        (push (drgnx-extensions-live-seam-test--package root d) load-path)
        (drgnx-extensions-live-seam-test--package root d 1))
      (let ((where (symbol-function 'drgnx-extensions-live--where)))
        (cl-letf (((symbol-function 'drgnx-extensions-live--where)
                   (lambda (&rest args) (cl-incf calls) (apply where args))))
          (drgnx-extensions-live-plan (list :generation 1 :replaces (vconcat dirs) :removes [] :file "x.plan.json"))))
      (should (= 40 (seq-count (lambda (e) (string-search "/generations/1/elpa/" e)) load-path)))
      ;; one walk to repoint, one to name the generations in use: not one walk per package
      (should (<= calls (* 2 (length load-path)))))))

(ert-deftest drgnx-extensions-live-seam/settling-reads-only-the-new-packages-descriptors ()
  (drgnx-extensions-live-seam-test--with
    (dotimes (i 30)
      (let ((d (drgnx-extensions-live-seam-test--package root (format "old%d-1.0" i))))
        (write-region (format "(define-package \"old%d\" \"1.0\" \"old\" nil)\n" i) nil
                      (format "%s/old%d-pkg.el" d i) nil 'silent)
        (push d load-path)))
    (let ((d (drgnx-extensions-live-seam-test--package root "fnew-1.0")) (all 0) (one 0))
      (write-region "(define-package \"fnew\" \"1.0\" \"new\" nil)\n" nil (concat d "/fnew-pkg.el") nil 'silent)
      (write-region "(defun drgnx-extensions-live-seam-test-fnew () 'fnew)\n" nil (concat d "/fnew-autoloads.el") nil 'silent)
      (let ((load-all (symbol-function 'package-load-all-descriptors))
            (load-one (symbol-function 'package-load-descriptor)))
        (cl-letf (((symbol-function 'package-load-all-descriptors) (lambda () (cl-incf all) (funcall load-all)))
                  ((symbol-function 'package-load-descriptor) (lambda (dir) (cl-incf one) (funcall load-one dir))))
          ;; the job layer's result of a job that went well
          (drgnx-extensions-live-after '(:status done :kind sync))))
      (should (memq 'fnew package-activated-list))
      (should (fboundp 'drgnx-extensions-live-seam-test-fnew))
      (should (= all 0))
      (should (<= one 3)))))

;;; extensions-live-seam-test.el ends here
