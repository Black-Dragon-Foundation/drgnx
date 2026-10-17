;;; core-paths-test.el --- batch tests: drgnx paths -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)

(ert-deftest drgnx-paths/user-and-state-dirs ()
  (let ((process-environment (append '("DRGNX_CONFIG_DIR=/tmp/drgnx-cfg" "XDG_STATE_HOME=/tmp/xs" "XDG_CACHE_HOME=/tmp/xc")
                                     process-environment)))
    (should (equal (drgnx-user-dir) "/tmp/drgnx-cfg/"))
    (should (equal (drgnx-state-dir) "/tmp/xs/drgnx/"))
    (should (equal (drgnx-cache-dir) "/tmp/xc/drgnx/"))))

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
