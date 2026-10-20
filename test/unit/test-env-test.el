;;; test-env-test.el --- drgnx-test-env: one environment for every tier -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-test-env)

(defconst drgnx-test-env-test--root
  (expand-file-name "../../" (file-name-directory (or load-file-name buffer-file-name))))

(defun drgnx-test-env-test--lookup (env name)
  "The last setting of NAME in ENV: a string, `unset', or nil when ENV does not mention it."
  (let (found)
    (dolist (e env)
      (cond ((equal e name) (setq found 'unset))
            ((string-prefix-p (concat name "=") e) (setq found (substring e (1+ (length name)))))))
    found))

(defun drgnx-test-env-test--under (dir path)
  (string-prefix-p (file-name-as-directory (expand-file-name dir)) (file-name-as-directory (expand-file-name path))))

(ert-deftest drgnx-test-env/no-tier-sees-home-bus-display-or-a-key ()
  (let ((run (make-temp-file "drgnx-test-env" t)))
    (unwind-protect
        (dolist (tier drgnx-test-env-tiers)
          (let* ((process-environment
                  (append '("HOME=/real-home" "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus" "DISPLAY=:0"
                            "WAYLAND_DISPLAY=wayland-0" "OPENROUTER_API_KEY=sk-real" "XDG_CONFIG_HOME=/real-home/.config")
                          process-environment))
                 (env (drgnx-test-env tier run))
                 (all (append env process-environment))
                 (seen (lambda (name) (drgnx-test-env-test--lookup env name))))
            ;; what the test sees is the environment with ENV on top: the real values are gone
            (let ((process-environment (append env process-environment)))
              (should-not (getenv "OPENROUTER_API_KEY"))
              (should-not (getenv "WAYLAND_DISPLAY"))
              (should-not (getenv "DISPLAY"))
              (should (equal (getenv "DBUS_SESSION_BUS_ADDRESS") drgnx-test-env-dead-bus)))
            (dolist (v '("HOME" "XDG_CONFIG_HOME" "XDG_DATA_HOME" "XDG_STATE_HOME" "XDG_CACHE_HOME" "DRGNX_CONFIG_DIR"
                         "DRGNX_DATA_DIR" "TMPDIR" "XDG_RUNTIME_DIR"))
              (let ((val (funcall seen v)))
                (should (stringp val))
                (should (drgnx-test-env-test--under run val))))
            (should (equal "1" (funcall seen "DRGNX_TEST_ISOLATED")))
            (should (equal "1" (funcall seen "DRGNX_NO_HUB_START")))
            (should (equal (number-to-string (emacs-pid)) (funcall seen "DRGNX_HUB_PARENT_PID")))
            (dolist (v drgnx-test-env-provider-variables) (should (eq 'unset (funcall seen v))))
            (should (= #o700 (logand #o777 (file-modes (funcall seen "XDG_RUNTIME_DIR")))))
            (ignore all)))
      (delete-directory run t))))

(ert-deftest drgnx-test-env/gui-tiers-get-only-the-harness-display ()
  (let ((run (make-temp-file "drgnx-test-env" t))
        (display '("DISPLAY=:77" "XAUTHORITY=/x/y")))
    (unwind-protect
        (dolist (tier drgnx-test-env-tiers)
          (let ((env (drgnx-test-env tier run :display display)))
            (if (memq tier drgnx-test-env-gui-tiers)
                (progn
                  (should (equal ":77" (drgnx-test-env-test--lookup env "DISPLAY")))
                  (should (equal "/x/y" (drgnx-test-env-test--lookup env "XAUTHORITY")))
                  (dolist (v (remove "DISPLAY" drgnx-test-env-desktop-variables))
                    (should (eq 'unset (drgnx-test-env-test--lookup env v)))))
              (dolist (v drgnx-test-env-desktop-variables)
                (should (eq 'unset (drgnx-test-env-test--lookup env v))))
              (should-not (drgnx-test-env-test--lookup env "XAUTHORITY")))))
      (delete-directory run t))))

(ert-deftest drgnx-test-env/an-external-config-is-linked-into-the-run ()
  (let ((run (make-temp-file "drgnx-test-env" t)) (cfg (make-temp-file "drgnx-test-env-cfg" t)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "lisp" cfg))
          (write-region "secret" nil (expand-file-name "init.el" cfg))
          (let* ((env (drgnx-test-env 'live run :config cfg))
                 (dest (drgnx-test-env-test--lookup env "DRGNX_CONFIG_DIR")))
            (should (file-symlink-p (expand-file-name "lisp" dest)))
            (should-not (file-exists-p (expand-file-name "init.el" dest)))))
      (delete-directory run t)
      (delete-directory cfg t))))

(ert-deftest drgnx-test-env/an-unknown-tier-is-an-error ()
  (should-error (drgnx-test-env 'nightly "/nonexistent")))

(ert-deftest drgnx-test-env/outer-is-the-dead-bus-and-no-desktop ()
  (let ((outer (drgnx-test-env-outer)))
    (should (member (concat "DBUS_SESSION_BUS_ADDRESS=" drgnx-test-env-dead-bus) outer))
    (dolist (v drgnx-test-env-desktop-variables) (should (member v outer)))))

(ert-deftest drgnx-test-env/the-runner-uses-it ()
  "A one-process run of a one-test suite: the test's environment holds every entry of the unit tier's list."
  (let* ((root (make-temp-file "drgnx-test-env-suite" t))
         (suite (expand-file-name "suite" root))
         (run (expand-file-name "drgnx-run.abc123" root))
         (out (expand-file-name "env.eld" root)))
    (unwind-protect
        (progn
          (make-directory suite)
          (make-directory run)
          (write-region (format "(ert-deftest env-dump/dump () (with-temp-file %S (prin1 (list (emacs-pid) process-environment) (current-buffer))))\n" out)
                        nil (expand-file-name "dump-test.el" suite))
          (let ((process-environment (append (list (concat "DRGNX_RUN_TMP=" run) "DRGNX_TEST_ONE_PROCESS=1" "DRGNX_TEST_SELECTOR")
                                             process-environment)))
            (should (= 0 (call-process (expand-file-name invocation-name invocation-directory) nil nil nil
                                       "--batch" "-Q" "-L" (expand-file-name "harness" drgnx-test-env-test--root)
                                       "-L" (expand-file-name "core" drgnx-test-env-test--root)
                                       "-l" (expand-file-name "harness/run-ert.el" drgnx-test-env-test--root)
                                       "-f" "drgnx-run-ert-batch" suite))))
          (pcase-let* ((`(,pid ,child) (with-temp-buffer (insert-file-contents out) (read (current-buffer))))
                       (expected (let ((process-environment nil)) (drgnx-test-env 'unit run))))
            (dolist (e expected)
              (unless (string-prefix-p "DRGNX_HUB_PARENT_PID=" e)
                (should (member e child))))
            (should (member (format "DRGNX_HUB_PARENT_PID=%d" pid) child))))
      (delete-directory root t))))

(ert-deftest drgnx-test-env/the-runner-keeps-no-copy-of-the-lists ()
  (let ((text (with-temp-buffer (insert-file-contents (expand-file-name "harness/run-ert.el" drgnx-test-env-test--root))
                                (buffer-string))))
    (should (string-search "(drgnx-test-env 'unit" text))
    (dolist (copy '("OPENROUTER_API_KEY" "HYPRLAND_INSTANCE_SIGNATURE" "drgnx-unit-test"))
      (should-not (string-search copy text)))))

(ert-deftest drgnx-test-env/bin-drgnx-matches-it ()
  "bin/drgnx's C-environment line (dbus.el reads that one) names the same variables and the same dead bus."
  (let ((text (with-temp-buffer (insert-file-contents (expand-file-name "bin/drgnx" drgnx-test-env-test--root))
                                (buffer-string))))
    (should (string-match "exec env \\(\\(?:-u [A-Z0-9_]+ \\)+\\)" text))
    (let ((names (mapcar (lambda (s) (string-remove-prefix "-u " s))
                         (split-string (string-trim (match-string 1 text)) " -u" t))))
      (should (equal (sort (mapcar #'string-trim (copy-sequence names)) #'string<)
                     (sort (copy-sequence drgnx-test-env-desktop-variables) #'string<))))
    (should (string-search (concat "DBUS_SESSION_BUS_ADDRESS=" drgnx-test-env-dead-bus) text))))

(provide 'test-env-test)
