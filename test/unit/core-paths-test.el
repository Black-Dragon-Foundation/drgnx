;;; core-paths-test.el --- batch tests: drgnx paths -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)

(ert-deftest drgnx-paths/user-and-state-dirs ()
  (let ((process-environment (append '("DRGNX_CONFIG_DIR=/tmp/drgnx-cfg" "XDG_STATE_HOME=/tmp/xs" "XDG_CACHE_HOME=/tmp/xc")
                                     process-environment)))
    (should (equal (drgnx-user-dir) "/tmp/drgnx-cfg/"))
    (should (equal (drgnx-state-dir) "/tmp/xs/drgnx/"))
    (should (equal (drgnx-cache-dir) "/tmp/xc/drgnx/"))))

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

(defun drgnx-paths-test--start-custom (tmp)
  "Start a batch Emacs on TMP/init as `drgnx-paths-test--start' does, with TMP/config as the drgnx config dir, whose
init.el saves `fill-column' with Customize (as Save in Customize, and `package-install', do); what it says:
\(CUSTOM-FILE FILL-COLUMN-AT-START)."
  (let ((init (expand-file-name "init/" tmp)))
    (make-directory init t)
    (make-directory (expand-file-name "home" tmp) t)
    (write-region (format "(load %S nil t)\n" (expand-file-name "init/early-init.el" drgnx-dir)) nil (concat init "early-init.el") nil 'silent)
    (write-region "(princ (format \"%S\" (list custom-file fill-column)))\n(customize-save-variable 'fill-column 72)\n"
                  nil (concat init "init.el") nil 'silent)
    (with-temp-buffer
      (let ((process-environment (append (list "DRGNX_UI_RUN")
                                         (mapcar (lambda (v) (format "%s=%s%s" (car v) tmp (cdr v)))
                                                 '(("HOME" . "home") ("XDG_STATE_HOME" . "state") ("XDG_CACHE_HOME" . "cache")
                                                   ("DRGNX_CONFIG_DIR" . "config")))
                                         process-environment)))
        (call-process (expand-file-name invocation-name invocation-directory) nil '(t nil) nil
                      "--batch" "--user" "" (concat "--init-directory=" init)))
      (car (read-from-string (buffer-string))))))

(ert-deftest drgnx-paths/customize-saves-into-the-config-dir-never-the-checkout ()
  ;; Customize and `package-install' write `custom-set-variables' into `custom-file', else into the init file —
  ;; the checkout's tracked init/init.el (whose dirt then stops install.sh's updates).  custom.el in the config dir:
  ;; made when missing, loaded at start.
  (let* ((tmp (file-name-as-directory (make-temp-file "drgnx-init" t)))
         (custom (concat tmp "config/custom.el"))
         (init (concat tmp "init/init.el")))
    (unwind-protect
        (progn
          (pcase-let ((`(,file ,_) (drgnx-paths-test--start-custom tmp)))
            (should (equal file custom)))
          (should (string-search "(fill-column 72)" (with-temp-buffer (insert-file-contents custom) (buffer-string))))
          (should-not (string-search "custom-set-variables" (with-temp-buffer (insert-file-contents init) (buffer-string))))
          ;; the next start loads it
          (should (equal (cadr (drgnx-paths-test--start-custom tmp)) 72)))
      (delete-directory tmp t))))

(ert-deftest drgnx-paths/a-harness-session-keeps-its-state-in-its-run-directory ()
  (let ((tmp (file-name-as-directory (make-temp-file "drgnx-init" t))))
    (unwind-protect
        (should (equal (car (drgnx-paths-test--start tmp (concat "DRGNX_UI_RUN=" tmp "run")))
                       (concat tmp "init/")))
      (delete-directory tmp t))))
