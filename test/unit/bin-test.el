;;; bin-test.el --- batch tests: bin/drgnx runs every subcommand in one Emacs -*- lexical-binding: t -*-
;; Fake Emacs scripts record their argv; bin/drgnx runs in a temp HOME and config dir, never the user's.
(require 'ert)

(defconst drgnx-bin-test--root
  (expand-file-name "../../" (file-name-directory (or load-file-name buffer-file-name))))

(defun drgnx-bin-test--fake (file log)
  "Make FILE an executable that appends its argv to LOG and exits 0; return FILE."
  (write-region (format "#!/bin/sh\necho \"$0 $*\" >> '%s'\n" log) nil file)
  (set-file-modes file #o755)
  file)

(defun drgnx-bin-test--slurp (file)
  (if (file-exists-p file)
      (with-temp-buffer (insert-file-contents file) (buffer-string))
    ""))

(defun drgnx-bin-test--call (bin env &rest args)
  "Run BIN (a bin/drgnx) with ENV (\"K=V\" strings) and ARGS; return (EXIT . OUTPUT), stderr included.
DRGNX_EMACS is unset unless ENV sets it; HOME is the caller's temp directory in ENV."
  (let ((process-environment (append env (list "DRGNX_EMACS") process-environment))
        (default-directory temporary-file-directory))
    (with-temp-buffer
      (cons (apply #'call-process bin nil t nil args) (buffer-string)))))

(defmacro drgnx-bin-test--with-setup (vars &rest body)
  "Bind VARS: DIR (temp directory, deleted afterwards), PATHDIR (first on PATH, holds a fake `emacs'
logging to PATHLOG), CONFIG (a DRGNX_CONFIG_DIR) and ENV (the environment lists that isolate the run)."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "drgnx-bin-test" t))
          (pathdir (expand-file-name "path" dir))
          (pathlog (expand-file-name "path.log" dir))
          (config (expand-file-name "config" dir))
          (env (list (concat "HOME=" dir) (concat "DRGNX_CONFIG_DIR=" config)
                     (concat "PATH=" pathdir ":/usr/bin:/bin"))))
     (ignore pathlog config env)
     (make-directory pathdir)
     (make-directory config)
     (drgnx-bin-test--fake (expand-file-name "emacs" pathdir) pathlog)
     (unwind-protect (let ,vars ,@body)
       (delete-directory dir t))))

(defconst drgnx-bin-test--bin (expand-file-name "bin/drgnx" drgnx-bin-test--root))

(ert-deftest drgnx-bin/the-recorded-emacs-is-used ()
  (drgnx-bin-test--with-setup ()
    (let ((log (expand-file-name "recorded.log" dir))
          (fake (expand-file-name "recorded-emacs" dir)))
      (drgnx-bin-test--fake fake log)
      (write-region (concat fake "\n") nil (expand-file-name "emacs" config))
      (dolist (args '(("build") ("keys" "diff" "--help") ("ui" "--help")))
        (delete-file log)
        (apply #'drgnx-bin-test--call drgnx-bin-test--bin env args)
        (should (string-search fake (drgnx-bin-test--slurp log))))
      (should (string-empty-p (drgnx-bin-test--slurp pathlog))))))

(ert-deftest drgnx-bin/drgnx-emacs-wins-over-the-recorded-one ()
  (drgnx-bin-test--with-setup ()
    (let ((rec-log (expand-file-name "recorded.log" dir))
          (env-log (expand-file-name "env.log" dir)))
      (write-region (concat (drgnx-bin-test--fake (expand-file-name "recorded-emacs" dir) rec-log) "\n")
                    nil (expand-file-name "emacs" config))
      (let ((chosen (drgnx-bin-test--fake (expand-file-name "env-emacs" dir) env-log)))
        (drgnx-bin-test--call drgnx-bin-test--bin (append env (list (concat "DRGNX_EMACS=" chosen))) "build")
        (should (string-search chosen (drgnx-bin-test--slurp env-log)))
        (should (string-empty-p (drgnx-bin-test--slurp rec-log)))))))

(ert-deftest drgnx-bin/a-recorded-emacs-that-is-gone-falls-back-to-path ()
  (drgnx-bin-test--with-setup ()
    (write-region (concat (expand-file-name "no-such-emacs" dir) "\n") nil (expand-file-name "emacs" config))
    (drgnx-bin-test--call drgnx-bin-test--bin env "build")
    (should (string-search "emacs" (drgnx-bin-test--slurp pathlog)))
    (should (string-search "--batch" (drgnx-bin-test--slurp pathlog)))))

(ert-deftest drgnx-bin/only-the-first-line-of-the-record-counts-and-is-never-run-as-shell ()
  (drgnx-bin-test--with-setup ()
    (let ((marker (expand-file-name "ran-as-shell" dir))
          (log (expand-file-name "recorded.log" dir))
          (fake (expand-file-name "recorded-emacs" dir)))
      (drgnx-bin-test--fake fake log)
      (write-region (format "  %s  \ntouch %s\n" fake marker) nil (expand-file-name "emacs" config))
      (drgnx-bin-test--call drgnx-bin-test--bin env "build")
      (should (string-search fake (drgnx-bin-test--slurp log)))
      (should-not (file-exists-p marker)))))

(ert-deftest drgnx-bin/doctor-json-starts-with-the-json-when-an-elc-is-stale ()
  ;; A pull leaves an .elc older than its .el; without load-prefer-newer Emacs prints "Source file … newer
  ;; than byte-compiled" before the JSON.  A temp copy of bin/ and core/, so the real files stay untouched.
  (let* ((dir (make-temp-file "drgnx-bin-test" t))
         (emacs (expand-file-name invocation-name invocation-directory))
         (core (expand-file-name "core" dir)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "bin" dir))
          (copy-file drgnx-bin-test--bin (expand-file-name "bin/drgnx" dir))
          (set-file-modes (expand-file-name "bin/drgnx" dir) #o755)
          (make-directory core)
          (dolist (f (directory-files (expand-file-name "core" drgnx-bin-test--root) t "\\.el\\'"))
            (copy-file f (expand-file-name (file-name-nondirectory f) core)))
          (should (= 0 (call-process emacs nil nil nil "--batch" "-Q" "-L" core
                                     "-f" "batch-byte-compile" (expand-file-name "drgnx-doctor.el" core))))
          (set-file-times (expand-file-name "drgnx-doctor.elc" core) '(1000 0))   ; older than the .el
          (let ((r (drgnx-bin-test--call (expand-file-name "bin/drgnx" dir)
                                         (list (concat "HOME=" dir) (concat "DRGNX_EMACS=" emacs)
                                               (concat "DRGNX_CONFIG_DIR=" dir "/config"))
                                         "doctor" "--json")))
            (should (string-prefix-p "[" (cdr r)))))
      (delete-directory dir t))))

;;; bin-test.el ends here
