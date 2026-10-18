;;; core-paths-test.el --- batch tests: drgnx paths -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)

(ert-deftest drgnx-paths/user-and-state-dirs ()
  (let ((process-environment (append '("DRGNX_CONFIG_DIR=/tmp/drgnx-cfg" "XDG_STATE_HOME=/tmp/xs" "XDG_CACHE_HOME=/tmp/xc")
                                     process-environment)))
    (should (equal (drgnx-user-dir) "/tmp/drgnx-cfg/"))
    (should (equal (drgnx-state-dir) "/tmp/xs/drgnx/"))
    (should (equal (drgnx-cache-dir) "/tmp/xc/drgnx/"))))

(ert-deftest drgnx-paths/no-helper-ever-asks-tramp ()
  "REMOTE-PATHS-1: with a remote `default-directory' and no XDG variable set, expanding \"~\" must stay local."
  (let* ((asked nil)
         (home "/tmp/drgnx-remote-paths-home")
         (process-environment (append (list (concat "HOME=" home))
                                      (seq-remove (lambda (v) (string-match-p "\\`\\(HOME\\|XDG_[A-Z_]+\\|DRGNX_\\(CONFIG\\|DATA\\)_DIR\\)\\(=\\|\\'\\)" v))
                                                  process-environment)))
         (file-name-handler-alist
          (cons (cons "\\`/ssh:" (lambda (op &rest _) (push op asked) (error "Tramp was asked")))
                file-name-handler-alist))
         (default-directory "/ssh:nohost.invalid:/tmp/"))
    (dolist (fn '(drgnx-user-dir drgnx-state-dir drgnx-cache-dir drgnx-data-dir drgnx-elpa-dir
                                 drgnx-generations-dir drgnx-package-cache-dir))
      (let ((dir (funcall fn)))
        (should (stringp dir))
        (should (file-name-absolute-p dir))
        (should-not (file-remote-p dir))
        (should (string-prefix-p home dir))
        (should (string-suffix-p "/" dir))))
    (should-not asked)))

(defun drgnx-paths-test--sigpipe-ignored-p (command)
  "Does COMMAND (a list) run with SIGPIPE ignored?  Its /proc/self/status says (bit 12 of SigIgn)."
  (with-temp-buffer
    (apply #'call-process (car command) nil t nil (append (cdr command) '("-c" "grep SigIgn /proc/self/status")))
    (string-match "SigIgn:[ \t]*\\([0-9a-f]+\\)" (buffer-string))
    (/= 0 (logand #x1000 (string-to-number (match-string 1 (buffer-string)) 16)))))

(ert-deftest drgnx-paths/a-command-can-run-with-sigpipe-ignored ()
  (skip-unless (file-readable-p "/proc/self/status"))
  (should-not (drgnx-paths-test--sigpipe-ignored-p '("sh")))
  (let ((wrapped (drgnx-command-ignoring-sigpipe '("sh"))))
    (should (equal (car wrapped) "sh"))
    (should (drgnx-paths-test--sigpipe-ignored-p wrapped)))
  ;; no sh on Windows: the command as it was
  (let ((system-type 'windows-nt))
    (should (equal (drgnx-command-ignoring-sigpipe '("agent" "--x")) '("agent" "--x")))))

(ert-deftest drgnx-paths/checkout ()
  (should (file-exists-p (expand-file-name "core/drgnx-paths.el" drgnx-dir))))

(defun drgnx-paths-test--start (tmp &rest env)
  "Start a batch Emacs on TMP/init — an init directory whose early-init.el is drgnx's, whose init.el writes
a file where Emacs keeps its own state — with temp XDG dirs and ENV; what it says: (UED ELN AUTO-SAVE)."
  (let ((init (expand-file-name "init/" tmp)))
    (make-directory init t)
    (make-directory (expand-file-name "home" tmp) t)
    (write-region (format "(load %S nil t)\n" (expand-file-name "init/early-init.el" drgnx-dir)) nil (concat init "early-init.el") nil 'silent)
    (write-region "(write-region \"x\" nil (locate-user-emacs-file \"probe\") nil 'silent)
(princ (format \"%S\" (list user-emacs-directory (and (featurep 'native-compile) (car native-comp-eln-load-path)) auto-save-list-file-prefix)))\n"
                  nil (concat init "init.el") nil 'silent)
    (with-temp-buffer
      (let ((process-environment (append env (mapcar (lambda (v) (format "%s=%s%s" (car v) tmp (cdr v)))
                                                     '(("HOME" . "home") ("XDG_STATE_HOME" . "state") ("XDG_CACHE_HOME" . "cache")))
                                         process-environment)))
        ;; batch loads no init file; --user "" makes it load this init directory's
        (call-process (expand-file-name invocation-name invocation-directory) nil '(t nil) nil
                      "--batch" "--user" "" (concat "--init-directory=" init)))
      (car (read-from-string (buffer-string))))))

(ert-deftest drgnx-paths/emacs-keeps-its-state-and-native-code-out-of-the-checkout ()
  (let ((tmp (file-name-as-directory (make-temp-file "drgnx-init" t))))
    (unwind-protect
        (pcase-let ((`(,ued ,eln ,saves) (drgnx-paths-test--start tmp "DRGNX_UI_RUN")))
          (should (equal ued (concat tmp "state/drgnx/emacs/")))
          (should (string-prefix-p (concat tmp "state/drgnx/emacs/") saves))
          (when eln (should (equal eln (concat tmp "cache/drgnx/eln-cache/"))))
          (should (file-exists-p (concat tmp "state/drgnx/emacs/probe")))
          (should (equal (directory-files (concat tmp "init") nil "\\`[^.]") '("early-init.el" "init.el"))))
      (delete-directory tmp t))))

(ert-deftest drgnx-paths/a-harness-session-keeps-its-state-in-its-run-directory ()
  (let ((tmp (file-name-as-directory (make-temp-file "drgnx-init" t))))
    (unwind-protect
        (should (equal (car (drgnx-paths-test--start tmp (concat "DRGNX_UI_RUN=" tmp "run")))
                       (concat tmp "init/")))
      (delete-directory tmp t))))
