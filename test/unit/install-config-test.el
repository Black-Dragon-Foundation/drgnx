;;; install-config-test.el --- batch tests: install.sh and the config dir that travels -*- lexical-binding: t -*-
;; install.sh's functions run alone in bash with a temp HOME: never the user's ~/.config or ~/.local.
(require 'ert)

(defconst drgnx-install-config-test--root
  (expand-file-name "../../" (file-name-directory (or load-file-name buffer-file-name))))

(defun drgnx-install-config-test--function (name env script)
  "Run install.sh's function NAME's definition (with its copy of drgnx-paths.sh), then SCRIPT, in bash with ENV
\(\"K=V\" strings, a bare name unsets it); return (EXIT . OUTPUT).  The definition is `eval'ed: macOS's bash 3.2
sources nothing from `<(…)'."
  (let ((process-environment (append env process-environment))
        (default-directory drgnx-install-config-test--root))
    (with-temp-buffer
      (cons (call-process "bash" nil t nil "-c"
                          (format "eval \"$(sed -n '/^# >>> drgnx-paths/,/^# <<< drgnx-paths/p' install.sh)\"; eval \"$(sed -n '/^%s()/,/^}/p' install.sh)\"; warn() { echo \"warn: $*\"; }; %s"
                                  name script))
            (buffer-string)))))

(ert-deftest drgnx-install-config/remember-emacs-writes-the-data-dir ()
  ;; The Emacs's path is this machine's: it goes to the data dir, so the config dir can travel as it is.
  (let ((home (make-temp-file "drgnx-install-config" t)))
    (unwind-protect
        (let ((emacs (expand-file-name "bin/emacs" home)))
          (make-directory (file-name-directory emacs))
          (write-region "#!/bin/sh\n" nil emacs)
          (set-file-modes emacs #o755)
          (let ((r (drgnx-install-config-test--function
                    "remember_emacs" (list (concat "HOME=" home) "DRGNX_DATA_DIR" "XDG_DATA_HOME" "DRGNX_CONFIG_DIR")
                    (concat "EMACS_BIN=" (shell-quote-argument emacs) "; remember_emacs"))))
            (should (equal r '(0 . ""))))
          (should (equal (with-temp-buffer (insert-file-contents (expand-file-name ".local/share/drgnx/emacs" home))
                                           (buffer-string))
                         (concat emacs "\n")))
          (should-not (file-exists-p (expand-file-name ".config/drgnx" home)))
          ;; $XDG_DATA_HOME, then $DRGNX_DATA_DIR, as drgnx-data-dir reads them
          (let ((r (drgnx-install-config-test--function
                    "remember_emacs" (list (concat "HOME=" home) (concat "XDG_DATA_HOME=" home "/xdg") "DRGNX_DATA_DIR")
                    (concat "EMACS_BIN=" (shell-quote-argument emacs) "; remember_emacs"))))
            (should (= (car r) 0))
            (should (file-exists-p (expand-file-name "xdg/drgnx/emacs" home))))
          (let ((r (drgnx-install-config-test--function
                    "remember_emacs" (list (concat "HOME=" home) (concat "DRGNX_DATA_DIR=" home "/own data"))
                    (concat "EMACS_BIN=" (shell-quote-argument emacs) "; remember_emacs"))))
            (should (= (car r) 0))
            (should (file-exists-p (expand-file-name "own data/emacs" home)))))
      (delete-directory home t))))

;;; `install.sh --config URL': the one command (plans are dry runs; hand-overs run against a fake checkout)

(defvar drgnx-install-config-test--stdin nil
  "A file install.sh reads as its standard input (nil: /dev/null); `curl … | bash' hands it a pipe.")

(defun drgnx-install-config-test--run (env &rest args)
  "Run install.sh ARGS on a Fedora fixture, no terminal, in a temp HOME, with ENV (\"K=V\"); return (EXIT . OUTPUT)."
  (let* ((home (make-temp-file "drgnx-install-config" t))
         (process-environment
          (append env
                  (list (concat "DRGNX_INSTALL_OS_RELEASE="
                                (expand-file-name "test/fixtures/os-release/fedora-45" drgnx-install-config-test--root))
                        "DRGNX_INSTALL_UNAME=Linux" "DRGNX_INSTALL_ARCH=x86_64" "DRGNX_INSTALL_TTY=none"
                        "DRGNX_INSTALL_MACOS_APP=none" (concat "HOME=" home)
                        (concat "DRGNX_CONFIG_DIR=" home "/.config/drgnx")
                        (concat "DRGNX_DATA_DIR=" home "/.local/share/drgnx")
                        (concat "DRGNX_INSTALL_OSTREE_BOOTED=" home "/no-ostree"))
                  process-environment))
         (default-directory drgnx-install-config-test--root))
    (unwind-protect
        (with-temp-buffer
          (cons (apply #'call-process "bash" drgnx-install-config-test--stdin t nil
                       (expand-file-name "install.sh" drgnx-install-config-test--root) args)
                (buffer-string)))
      (delete-directory home t))))

(defun drgnx-install-config-test--plan (&rest args)
  (apply #'drgnx-install-config-test--run nil "--dry-run" args))

(ert-deftest drgnx-install-config/plan-names-the-bootstrap ()
  (let ((r (drgnx-install-config-test--plan "--config" "https://example.invalid/c.git")))
    (should (= (car r) 0))
    (should (string-search "Then: drgnx bootstrap --config https://example.invalid/c.git (asks before keys, desktop and shell)"
                           (cdr r)))
    ;; bootstrap runs the doctor: the plan promises no doctor of its own
    (should-not (string-search "Run drgnx doctor" (cdr r))))
  (let ((r (drgnx-install-config-test--plan)))
    (should-not (string-search "bootstrap" (cdr r)))
    (should (string-search "Run drgnx doctor" (cdr r)))))

(ert-deftest drgnx-install-config/plan-with-yes-says-what-stays-manual ()
  (let ((r (drgnx-install-config-test--plan "--yes" "--chezmoi" "https://example.invalid/d.git")))
    (should (string-search "Then: drgnx bootstrap --chezmoi https://example.invalid/d.git --yes (" (cdr r)))
    ;; what bootstrap's --yes confirms, and what it never does
    (should (string-search "the key import and chezmoi init" (cdr r)))
    (should (string-search "the desktop entry" (cdr r)))
    (should-not (string-search "confirms only" (cdr r)))
    (should-not (string-search "asks before keys" (cdr r)))))

(ert-deftest drgnx-install-config/config-needs-a-value ()
  (dolist (opt '("--config" "--chezmoi" "--identity"))
    (let ((r (drgnx-install-config-test--plan opt)))
      (should (= (car r) 2))
      (should (string-search (concat opt " needs") (cdr r))))))

(ert-deftest drgnx-install-config/config-and-chezmoi-exclude ()
  (let ((r (drgnx-install-config-test--plan "--config" "https://example.invalid/c.git"
                                            "--chezmoi" "https://example.invalid/d.git")))
    (should (= (car r) 2))
    (should (string-search "--config and --chezmoi" (cdr r)))))

(ert-deftest drgnx-install-config/identity-passes-through ()
  (let ((r (drgnx-install-config-test--plan "--config" "https://example.invalid/c.git" "--identity" "/x/identity.txt")))
    (should (= (car r) 0))
    (should (string-search "Then: drgnx bootstrap --config https://example.invalid/c.git --identity /x/identity.txt ("
                           (cdr r)))))

(ert-deftest drgnx-install-config/identity-needs-a-configuration ()
  (let ((r (drgnx-install-config-test--plan "--identity" "/x/identity.txt")))
    (should (= (car r) 2))
    (should (string-search "--identity needs --config or --chezmoi" (cdr r)))))

(ert-deftest drgnx-install-config/only-https-or-a-local-path ()
  ;; A URL on a `curl | sh' line is the user's, but a scheme that runs a helper (ext::, file, ssh with a
  ;; ProxyCommand), a password in argv and ps, or an unencrypted http clone is refused before anything happens.
  (dolist (bad '("http://example.invalid/c.git" "ssh://git@example.invalid/c.git" "git@example.invalid:me/c.git"
                 "file:///srv/c.git" "ext::sh -c touch% /tmp/pwned" "git://example.invalid/c.git"
                 "https://me:tok@example.invalid/c.git" "https://me@example.invalid/c.git"
                 "https://example.invalid/a b.git" "https://example.invalid/a\nb.git"
                 ;; git keeps a query (a token) in .git/config and its logs
                 "https://example.invalid/c.git?token=x" "https://example.invalid/c.git#x"))
    (dolist (opt '("--config" "--chezmoi"))
      (let ((r (drgnx-install-config-test--plan opt bad)))
        (should (= (car r) 2))
        (should (string-search "https URL or a local path" (cdr r)))
        (should-not (string-search "Then:" (cdr r))))))
  (dolist (good '("https://example.invalid/c.git" "https://codeberg.org/me/c.git"))
    (should (= (car (drgnx-install-config-test--plan "--config" good)) 0)))
  ;; local paths are made absolute (the hand-over runs in another directory's context), ~/ is HOME
  (let ((r (drgnx-install-config-test--plan "--config" "rel/c.git")))
    (should (string-search (format "--config %s/rel/c.git " (string-trim-right drgnx-install-config-test--root "/"))
                           (cdr r))))
  (should (string-search "--config /srv/c.git " (cdr (drgnx-install-config-test--plan "--config" "/srv/c.git")))))

(ert-deftest drgnx-install-config/script-still-runs-only-from-main ()
  ;; a truncated `curl | sh' download must do nothing: the last line is the only top-level call
  (with-temp-buffer
    (insert-file-contents (expand-file-name "install.sh" drgnx-install-config-test--root))
    (goto-char (point-max))
    (skip-chars-backward "\n")
    (should (equal (buffer-substring (line-beginning-position) (point)) "main \"$@\""))
    (should-not (re-search-backward "^\\(eval\\|exec\\) " nil t))))

;; --- the hand-over -----------------------------------------------------------------------------------

(defmacro drgnx-install-config-test--with-fake-checkout (vars &rest body)
  "Run BODY with VARS = (TMP LOG ENV SRC): a fake keep-able Emacs and a fake drgnx checkout whose bin/drgnx
records each call (arguments, DRGNX_EMACS, how many bytes it could read from stdin) to LOG, and exits with
FAKE_BOOTSTRAP_EXIT for `bootstrap'."
  (declare (indent 1))
  `(let* ((,(nth 0 vars) (make-temp-file "drgnx-install-config" t))
          (,(nth 1 vars) (expand-file-name "log" ,(nth 0 vars)))
          (,(nth 3 vars) (expand-file-name "src" ,(nth 0 vars)))
          (fake-emacs (expand-file-name "emacs" ,(nth 0 vars)))
          (,(nth 2 vars) (list (concat "DRGNX_INSTALL_EMACS=" fake-emacs)
                               (concat "FAKE_LOG=" ,(nth 1 vars)))))
     (unwind-protect
         (progn
           (write-region "#!/bin/sh\necho '31.1 t pgtk'\n" nil fake-emacs)
           (set-file-modes fake-emacs #o755)
           (make-directory (expand-file-name "bin" ,(nth 3 vars)) t)
           (write-region (concat "#!/bin/sh\n"
                                 "printf '%s|%s|stdin=%s\\n' \"$1\" \"$DRGNX_EMACS\" \"$(cat | wc -c | tr -d ' ')\" >>\"$FAKE_LOG\"\n"
                                 "printf '%s\\n' \"$*\" >>\"$FAKE_LOG.args\"\n"
                                 "if [ \"$1\" = bootstrap ]; then exit \"${FAKE_BOOTSTRAP_EXIT:-0}\"; fi\n")
                         nil (expand-file-name "bin/drgnx" ,(nth 3 vars)))
           (set-file-modes (expand-file-name "bin/drgnx" ,(nth 3 vars)) #o755)
           ,@body)
       (delete-directory ,(nth 0 vars) t))))

(defun drgnx-install-config-test--file (file)
  (if (file-exists-p file) (with-temp-buffer (insert-file-contents file) (buffer-string)) ""))

(ert-deftest drgnx-install-config/hands-over-to-bootstrap ()
  (drgnx-install-config-test--with-fake-checkout (tmp log env src)
    (let* ((r (drgnx-install-config-test--run
               (append env (list "FAKE_BOOTSTRAP_EXIT=7"))
               "--yes" "--prefix" (expand-file-name "prefix" tmp) "--source-dir" src
               "--config" "https://example.invalid/c.git"))
           (calls (drgnx-install-config-test--file log))
           (args (drgnx-install-config-test--file (concat log ".args"))))
      ;; its exit code is bootstrap's
      (should (= (car r) 7))
      ;; build, then bootstrap; no doctor of install.sh's own, no "Done" line
      (should (equal (split-string args "\n" t)
                     '("build" "bootstrap --config https://example.invalid/c.git --yes")))
      (should-not (string-search "doctor" calls))
      (should-not (string-search "Done" (cdr r)))
      ;; the Emacs just chosen, and no stdin: the rest of a `curl | bash' script is not for bootstrap
      (should (string-search (format "bootstrap|%s|stdin=0" (expand-file-name "emacs" tmp)) calls)))))

(ert-deftest drgnx-install-config/the-hand-over-never-reads-the-script ()
  (drgnx-install-config-test--with-fake-checkout (tmp log env src)
    (let ((piped (expand-file-name "piped" tmp)))
      (write-region "main \"$@\"\nrm -rf /nonexistent\n" nil piped)
      (let* ((drgnx-install-config-test--stdin piped)
             (r (drgnx-install-config-test--run
                 env "--yes" "--prefix" (expand-file-name "prefix" tmp) "--source-dir" src
                 "--config" "https://example.invalid/c.git")))
        (should (= (car r) 0))
        (should (string-search "|stdin=0" (drgnx-install-config-test--file log)))))))

(ert-deftest drgnx-install-config/no-config-keeps-the-doctor-and-done ()
  (drgnx-install-config-test--with-fake-checkout (tmp log env src)
    (let ((r (drgnx-install-config-test--run env "--yes" "--prefix" (expand-file-name "prefix" tmp) "--source-dir" src)))
      (should (= (car r) 0))
      (should (equal (split-string (drgnx-install-config-test--file (concat log ".args")) "\n" t)
                     '("build" "doctor")))
      (should (string-search "Done." (cdr r))))))

(ert-deftest drgnx-install-config/the-url-is-never-evaluated ()
  ;; shell syntax in the value stays a string: argv to bootstrap, not a command line
  (drgnx-install-config-test--with-fake-checkout (tmp log env src)
    (let* ((marker (expand-file-name "pwned" tmp))
           (evil (expand-file-name "c$(touch $PWNED)`touch $PWNED`;touch $PWNED" tmp))
           (r (progn
                (make-directory evil t)
                (drgnx-install-config-test--run (cons (concat "PWNED=" marker) env)
                                                "--yes" "--prefix" (expand-file-name "prefix" tmp) "--source-dir" src
                                                "--config" evil))))
      (should-not (file-exists-p marker))
      (should (= (car r) 0))
      (should (string-search (concat "bootstrap --config " evil " --yes")
                             (drgnx-install-config-test--file (concat log ".args")))))))

(ert-deftest drgnx-install-config/a-missing-local-config-stops-before-anything ()
  (drgnx-install-config-test--with-fake-checkout (tmp log env src)
    (let ((r (drgnx-install-config-test--run env "--yes" "--prefix" (expand-file-name "prefix" tmp) "--source-dir" src
                                             "--config" (expand-file-name "no-such.git" tmp))))
      (should (= (car r) 2))
      (should (string-search "does not exist" (cdr r)))
      (should-not (file-exists-p log))
      (should-not (file-exists-p (expand-file-name "prefix" tmp))))))

(ert-deftest drgnx-install-config/the-identity-file-is-checked-and-never-printed ()
  (drgnx-install-config-test--with-fake-checkout (tmp log env src)
    (let* ((id (expand-file-name "identity.txt" tmp))
           (sentinel "SENTINEL-not-a-real-identity")
           (run (lambda (&rest more)
                  (apply #'drgnx-install-config-test--run env "--yes" "--prefix" (expand-file-name "prefix" tmp)
                         "--source-dir" src "--config" "https://example.invalid/c.git" more))))
      ;; missing → exit 2, before anything is installed
      (let ((r (funcall run "--identity" id)))
        (should (= (car r) 2))
        (should (string-search "identity file" (cdr r)))
        (should-not (file-exists-p log)))
      (write-region sentinel nil id)
      ;; readable by group or others → refused, with the fix, and the content stays out of the output
      (set-file-modes id #o644)
      (let ((r (funcall run "--identity" id)))
        (should (= (car r) 2))
        (should (string-search (format "chmod 600 %s" id) (cdr r)))
        (should-not (string-search sentinel (cdr r)))
        (should-not (file-exists-p log)))
      ;; a directory is no identity
      (let ((r (funcall run "--identity" tmp))) (should (= (car r) 2)))
      ;; private → passed on as a path, never its content
      (set-file-modes id #o600)
      (let ((r (funcall run "--identity" id)))
        (should (= (car r) 0))
        (should-not (string-search sentinel (cdr r)))
        (should (string-search (format "bootstrap --config https://example.invalid/c.git --identity %s --yes" id)
                               (drgnx-install-config-test--file (concat log ".args"))))
        (should-not (string-search sentinel (drgnx-install-config-test--file log)))))))

;;; install-config-test.el ends here
