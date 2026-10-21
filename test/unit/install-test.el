;;; install-test.el --- batch tests: install.sh plans (dry runs) -*- lexical-binding: t -*-
;; The installer is bash (it must run before any Emacs exists); these tests call it with
;; detection overridden through DRGNX_INSTALL_* and check the plan it prints.
(require 'ert)
(require 'cl-lib)

(defconst drgnx-install-test--root
  (expand-file-name "../../" (file-name-directory (or load-file-name buffer-file-name))))

(defun drgnx-install-test--os (name)
  (expand-file-name (concat "test/fixtures/os-release/" name) drgnx-install-test--root))

(defvar drgnx-install-test--stdin nil
  "A file that install.sh reads as its standard input (nil: /dev/null).  `curl … | bash' hands it a pipe.")

(defun drgnx-install-test--run (env &rest args)
  "Run install.sh ARGS with ENV (\"K=V\" strings), without a terminal (DRGNX_INSTALL_TTY=none); return
\(EXIT . OUTPUT).  HOME is a new empty directory, deleted afterwards (ENV may name another).  Unless ENV says
otherwise there is no podman and this is no container, so a Linux Nidhogg plan is a host build, whatever this
machine has."
  (let* ((home (make-temp-file "drgnx-install-home" t))
         (process-environment (append env
                                      (unless (cl-some (lambda (e) (string-prefix-p "DRGNX_INSTALL_PODMAN=" e)) env)
                                        (list "DRGNX_INSTALL_PODMAN=none"))
                                      (unless (cl-some (lambda (e) (string-prefix-p "DRGNX_INSTALL_IN_CONTAINER=" e)) env)
                                        (list "DRGNX_INSTALL_IN_CONTAINER=no"))
                                      (list "DRGNX_INSTALL_EMACS=none" "DRGNX_INSTALL_TTY=none"
                                            "DRGNX_INSTALL_RUNTIME=none"   ; no Rust toolchain probe or build, unless a test asks
                                            "DRGNX_INSTALL_MACOS_APP=none"   ; never this Mac's /Applications/Emacs.app
                                            (concat "HOME=" home)
                                            ;; never this machine's drgnx config (a DRGNX_CONFIG_DIR in the caller's environment)
                                            (concat "DRGNX_CONFIG_DIR=" home "/.config/drgnx")
                                            ;; …nor its data dir (the Emacs record goes there)
                                            (concat "DRGNX_DATA_DIR=" home "/.local/share/drgnx")
                                            ;; never this machine's /run/ostree-booted
                                            (concat "DRGNX_INSTALL_OSTREE_BOOTED=" home "/no-ostree"))
                                      process-environment))
         (default-directory drgnx-install-test--root))    ; not "~/…": HOME is changed above
    (unwind-protect
        (with-temp-buffer
          (cons (apply #'call-process "bash" drgnx-install-test--stdin t nil
                       (expand-file-name "install.sh" drgnx-install-test--root) args)
                (buffer-string)))
      (delete-directory home t))))

(defun drgnx-install-test--plan (os &rest env)
  "The dry-run plan on OS (a fixtures name).  ENV entries without an = are install.sh options."
  (apply #'drgnx-install-test--run
         (append (list (concat "DRGNX_INSTALL_OS_RELEASE=" (drgnx-install-test--os os))
                       "DRGNX_INSTALL_UNAME=Linux" "DRGNX_INSTALL_ARCH=x86_64")
                 (cl-remove-if-not (lambda (e) (string-search "=" e)) env))
         "--dry-run" (cl-remove-if (lambda (e) (string-search "=" e)) env)))

(defmacro drgnx-install-test--expect (result &rest substrings)
  `(let ((r ,result))
     (should (= (car r) 0))
     (dolist (s (list ,@substrings))
       (should (string-search s (cdr r))))))

(ert-deftest drgnx-install/syntax ()
  (should (= 0 (call-process "bash" nil nil nil "-n" (expand-file-name "install.sh" drgnx-install-test--root)))))

(ert-deftest drgnx-install/stock-methods-are-gone ()
  ;; drgnx runs on Nidhogg: the methods that installed a stock GNU Emacs were removed, whatever the system.
  (dolist (m '("package" "source" "cask" "formula"))
    (dolist (r (list (drgnx-install-test--plan "fedora-45" "--method" m)
                     (drgnx-install-test--run drgnx-install-test--macos "--dry-run" "--method" m)))
      (should (= (car r) 2))
      (should (string-search (format "method %s was removed: drgnx runs on Nidhogg (see docs/guide/install.md, \"Nidhogg\")" m)
                             (cdr r)))
      (should-not (string-search "1. Emacs" (cdr r)))))
  (should (= 2 (car (drgnx-install-test--plan "fedora-45" "--method" "nonsense")))))

(ert-deftest drgnx-install/no-recipe-says-so ()
  ;; A system without a Nidhogg recipe: exit 1 and the reason, never a stock Emacs; --method nidhogg says the same.
  (dolist (args '(("debian-13") ("arch") ("linuxmint") ("unknown") ("rocky-9") ("nobara-42") ("debian-13" "--method" "nidhogg")))
    (let ((r (apply #'drgnx-install-test--plan args)))
      (should (= (car r) 1))
      (should (string-search "no Nidhogg recipe for " (cdr r)))
      (should (string-search "yet (NIDHOGG-DISTROS-1)" (cdr r)))
      (should (string-search "docs/guide/install.md" (cdr r)))
      (should-not (string-search "1. Emacs" (cdr r))))))

(ert-deftest drgnx-install/script-runs-only-from-main ()
  ;; A truncated download must run nothing: everything is a function, `main' is called on the last line.
  (with-temp-buffer
    (insert-file-contents (expand-file-name "install.sh" drgnx-install-test--root))
    (goto-char (point-max))
    (skip-chars-backward " \n")
    (should (string= (buffer-substring (line-beginning-position) (point)) "main \"$@\""))))

(defconst drgnx-install-test--macos
  '("DRGNX_INSTALL_UNAME=Darwin" "DRGNX_INSTALL_ARCH=arm64" "DRGNX_INSTALL_MACOS=15.4")
  "Pretend this is macOS 15.4 on Apple silicon.")

(defun drgnx-install-test--fake-emacs (dir info)
  "A script in DIR that answers like an Emacs probe printing INFO; return its file name."
  (let ((fake (expand-file-name "emacs" dir)))
    (write-region (format "#!/bin/sh\necho '%s'\n" info) nil fake)
    (set-file-modes fake #o755)
    fake))

(ert-deftest drgnx-install/macos-without-homebrew-offers-it ()
  ;; Homebrew is installed (asked) before the brew commands; without a terminal and without --yes: exit 3.
  (let* ((r (drgnx-install-test--run (cons "DRGNX_INSTALL_BREW=none" drgnx-install-test--macos) "--dry-run"))
         (out (cdr r)))
    (should (= (car r) 0))
    (should (string-search "Install Homebrew" out))
    (should (string-search "Homebrew/install/HEAD/install.sh" out))
    (should (< (string-search "Install Homebrew" out) (string-search "Homebrew formulae from nidhogg/deps/macos.build" out))))
  (let ((r (drgnx-install-test--run (cons "DRGNX_INSTALL_BREW=none" drgnx-install-test--macos))))
    (should (= (car r) 3))
    (should (string-search "--yes" (cdr r)))))

(ert-deftest drgnx-install/the-plan-names-the-shell-profile-for-homebrews-line ()
  (pcase-dolist (`(,shell ,file) '(("/bin/zsh" ".zprofile") ("/bin/bash" ".profile")))
    (let ((out (cdr (drgnx-install-test--run (append (list "DRGNX_INSTALL_BREW=none" (concat "SHELL=" shell))
                                                     drgnx-install-test--macos)
                                             "--dry-run"))))
      (should (string-match-p (concat "then add its shellenv line to [^ ]*/" (regexp-quote file) " (asked)") out)))))

(ert-deftest drgnx-install/macos-with-homebrew-does-not-offer-it ()
  (let ((out (cdr (drgnx-install-test--run (cons "DRGNX_INSTALL_BREW=/opt/homebrew/bin/brew" drgnx-install-test--macos)
                                           "--dry-run"))))
    (should (string-search "Homebrew formulae from nidhogg/deps/macos.build" out))
    (should-not (string-search "Install Homebrew" out))
    (should-not (string-search "Rosetta" out))))

(ert-deftest drgnx-install/macos-with-intel-homebrew-on-apple-silicon ()
  ;; Homebrew for Intel in /usr/local on an arm64 Mac runs under Rosetta: used, but the plan says so.
  (let ((r (drgnx-install-test--run (cons "DRGNX_INSTALL_BREW=/usr/local/bin/brew" drgnx-install-test--macos)
                                    "--dry-run")))
    (should (= (car r) 0))
    (should (string-search "Homebrew formulae from nidhogg/deps/macos.build" (cdr r)))
    (should (string-search "Rosetta" (cdr r)))
    (should-not (string-search "Install Homebrew" (cdr r)))))

(ert-deftest drgnx-install/macos-keeps-an-emacs-app-that-is-good-enough ()
  (let ((tmp (make-temp-file "drgnx-install" t)))
    (unwind-protect
        (let ((r (drgnx-install-test--run
                  (append (list (concat "DRGNX_INSTALL_EMACS=" (drgnx-install-test--fake-emacs tmp "31.1 t ns"))
                                "DRGNX_INSTALL_BREW=none")
                          drgnx-install-test--macos)
                  "--dry-run" "--method" "keep")))
          (should (= (car r) 0))
          (should (string-search "keep the installed Emacs 31.1" (cdr r)))
          (should-not (string-search "brew install" (cdr r)))
          (should-not (string-search "Install Homebrew" (cdr r))))
      (delete-directory tmp t))))

(ert-deftest drgnx-install/macos-probes-emacs-app-in-applications ()
  ;; Emacs.app is not on PATH: /Applications/Emacs.app/Contents/MacOS/Emacs is probed too (DRGNX_INSTALL_MACOS_APP
  ;; stands for it). Good enough: kept and remembered. An older one is not kept: Nidhogg is built beside it.
  (let ((tmp (make-temp-file "drgnx-install" t)))
    (unwind-protect
        (let* ((good (let ((d (expand-file-name "good" tmp))) (make-directory d) (drgnx-install-test--fake-emacs d "31.1 t ns")))
               (old (let ((d (expand-file-name "old" tmp))) (make-directory d) (drgnx-install-test--fake-emacs d "30.2 t ns")))
               (run (lambda (app &rest args)
                      (apply #'drgnx-install-test--run
                             (append (list (concat "DRGNX_INSTALL_MACOS_APP=" app) "DRGNX_INSTALL_BREW=none") drgnx-install-test--macos)
                             "--dry-run" args))))
          (let ((r (funcall run good "--method" "keep")))
            (should (= (car r) 0))
            (should (string-search (concat "keep the installed Emacs 31.1 (" good ")") (cdr r)))
            (should (string-search (concat "Remember Emacs: " good) (cdr r)))
            (should-not (string-search "Install Homebrew" (cdr r))))
          (let ((r (funcall run old)))
            (should (= (car r) 0))
            (should (string-search "build Nidhogg 31.1-nidhogg.1" (cdr r)))
            (should-not (string-search "keep the installed" (cdr r))))
          ;; DRGNX_INSTALL_EMACS still comes first
          (let ((r (drgnx-install-test--run (append (list (concat "DRGNX_INSTALL_EMACS=" good) (concat "DRGNX_INSTALL_MACOS_APP=" old)
                                                          "DRGNX_INSTALL_BREW=none")
                                                    drgnx-install-test--macos)
                                            "--dry-run" "--method" "keep")))
            (should (= (car r) 0))
            (should (string-search (concat "keep the installed Emacs 31.1 (" good ")") (cdr r)))))
      (delete-directory tmp t))))

(ert-deftest drgnx-install/homebrew-installer-runs-noninteractive-and-its-failure-stops-the-run ()
  ;; A fake curl hands out a Homebrew "installer" that reports its environment and fails; nothing after it
  ;; (tap, install) runs.  A download that fails is its own message.
  ;; The installer also tries to read: run as `curl … | bash' its stdin is the script's pipe, so --yes must
  ;; hand it /dev/null (M12a-2); the test gives install.sh a stdin that has input to take.
  (let* ((tmp (make-temp-file "drgnx-install" t)) (bin (expand-file-name "bin" tmp))
         (drgnx-install-test--stdin (expand-file-name "stdin" tmp)))
    (unwind-protect
        (let ((fx (drgnx-install-test--nidhogg-fixture tmp)))
          (write-region "PIPED-SCRIPT-TEXT\n" nil drgnx-install-test--stdin)
          (dolist (curl '("echo 'echo HB-INSTALLER NONINTERACTIVE=$NONINTERACTIVE; read x && echo GOT || echo STDIN-EOF; exit 1'"
                          "exit 22"))
            (write-region (format "#!/bin/sh\n%s\n" curl) nil (expand-file-name "curl" bin))
            (set-file-modes (expand-file-name "curl" bin) #o755)
            (let ((r (drgnx-install-test--run
                      (append (list "DRGNX_INSTALL_BREW=none" (concat "PATH=" bin ":" (getenv "PATH")))
                              (drgnx-install-test--macos-env fx))
                      "--yes" "--source-dir" (expand-file-name "drgnx" tmp))))
              (should (= (car r) 1))
              ;; once Homebrew's installer failed, nothing was built
              (should-not (drgnx-install-test--file (expand-file-name "log" tmp)))
              (should (string-search "come from Homebrew, which is not installed" (cdr r)))
              (if (string-search "exit 1" curl)
                  (progn (should (string-search "HB-INSTALLER NONINTERACTIVE=1" (cdr r)))
                         (should (string-search "STDIN-EOF" (cdr r)))
                         (should-not (string-search "GOT" (cdr r)))
                         (should (string-search "Homebrew's installer failed" (cdr r))))
                (should (string-search "could not download Homebrew's installer" (cdr r)))))))
      (delete-directory tmp t))))

(defun drgnx-install-test--fake-homebrew (tmp)
  "In TMP: a fake `curl' whose Homebrew \"installer\" succeeds by creating a fake brew (answering `shellenv',
`--prefix', anything else by printing FAKE-BREW and its arguments).  Return the environment that makes
install.sh find that brew after the install (DRGNX_INSTALL_BREW_PATHS), starting from no Homebrew."
  (let* ((bin (expand-file-name "bin" tmp))
         (hb (expand-file-name "hb" tmp))
         (installer (expand-file-name "installer.sh" tmp)))
    (make-directory bin t)
    (write-region (concat "mkdir -p \"$FAKE_HB_DIR\"\n"
                          "cat > \"$FAKE_HB_DIR/brew\" <<'EOF'\n"
                          "#!/bin/sh\n"
                          "case \"$1\" in\n"
                          "  shellenv) echo 'export FAKE_SHELLENV=1' ;;\n"
                          "  --prefix) echo \"$FAKE_HB_DIR/opt\" ;;\n"
                          "  *) echo \"FAKE-BREW $*\" ;;\n"
                          "esac\n"
                          "EOF\n"
                          "chmod +x \"$FAKE_HB_DIR/brew\"\n"
                          "echo FAKE-HB-INSTALLED\n")
                  nil installer)
    (write-region "#!/bin/sh\ncat \"$FAKE_HB_INSTALLER\"\n" nil (expand-file-name "curl" bin))
    (set-file-modes (expand-file-name "curl" bin) #o755)
    (list "DRGNX_INSTALL_BREW=none" (concat "DRGNX_INSTALL_BREW_PATHS=" hb "/brew")
          (concat "FAKE_HB_DIR=" hb) (concat "FAKE_HB_INSTALLER=" installer)
          (concat "PATH=" bin ":" (getenv "PATH")))))

(ert-deftest drgnx-install/homebrew-installer-success-path ()
  ;; The installer succeeds (a fake one that makes a fake brew): the brew it made is found, its shellenv
  ;; is evaluated, the profile line is offered (--yes only prints it) and Nidhogg is built after it.
  (let ((tmp (make-temp-file "drgnx-install" t)))
    (unwind-protect
        (let* ((fx (drgnx-install-test--nidhogg-fixture tmp))
               (r (drgnx-install-test--run
                   (append (drgnx-install-test--fake-homebrew tmp) (list "SHELL=/bin/zsh") (drgnx-install-test--macos-env fx))
                   "--yes" "--source-dir" (expand-file-name "drgnx" tmp))))
          (should (= (car r) 0))
          (should (string-search "FAKE-HB-INSTALLED" (cdr r)))
          (should (string-search "Homebrew must be on your PATH in new terminals." (cdr r)))
          (should (string-match-p (concat "add this to [^ ]*/\\.zprofile: eval \"\\$(" (regexp-quote tmp) "/hb/brew shellenv)\"")
                                  (cdr r)))
          (should (string-search "build.sh --host " (drgnx-install-test--file (expand-file-name "log" tmp))))
          (should-not (string-search "Homebrew was installed but brew was not found" (cdr r))))
      (delete-directory tmp t))))

(ert-deftest drgnx-install/brew-profile-hint-follows-the-shell ()
  ;; The Homebrew line goes to the file the user's shell reads, as the PATH line and the doctor do: zsh
  ;; ~/.zprofile; with SHELL unset ~/.zprofile if it exists, else ~/.profile; any other shell ~/.profile.
  (let ((tmp (make-temp-file "drgnx-install" t)))
    (unwind-protect
        (let* ((fx (drgnx-install-test--nidhogg-fixture tmp))
               (hint (lambda (shell &optional zprofile)
                       (let* ((home (make-temp-file "drgnx-install-home" t))
                              (r (unwind-protect
                                     (progn
                                       (when zprofile (write-region "" nil (expand-file-name ".zprofile" home)))
                                       (drgnx-install-test--run
                                        (append (drgnx-install-test--fake-homebrew tmp) (list (concat "HOME=" home))
                                                (if shell (list (concat "SHELL=" shell)) (list "SHELL="))
                                                (drgnx-install-test--macos-env fx))
                                        "--yes" "--source-dir" (expand-file-name "drgnx" tmp)))
                                   (delete-directory home t))))
                         (should (= (car r) 0))
                         (and (string-match "add this to [^ ]*/\\(\\.z?profile\\): eval " (cdr r))
                              (match-string 1 (cdr r)))))))
          (should (equal (funcall hint "/bin/zsh") ".zprofile"))
          (should (equal (funcall hint "/bin/bash") ".profile"))
          (should (equal (funcall hint "/usr/bin/fish") ".profile"))
          (should (equal (funcall hint nil) ".profile"))
          (should (equal (funcall hint nil t) ".zprofile")))
      (delete-directory tmp t))))

(ert-deftest drgnx-install/no-bash-4-constructs ()
  ;; macOS ships bash 3.2: it must run there.  Each pattern comes with a line it must match, so a mistyped
  ;; pattern cannot pass for ever (`;;&' is caught by `;&').
  (let ((code (with-temp-buffer
                (insert-file-contents (expand-file-name "install.sh" drgnx-install-test--root))
                (goto-char (point-min))
                (while (re-search-forward "^[ \t]*#.*$\\|[ \t]#[ \t].*$" nil t) (replace-match ""))
                (buffer-string))))
    (dolist (case '(("\\bmapfile\\b" . "mapfile -t lines < file")
                    ("\\breadarray\\b" . "readarray -t lines < file")
                    ("declare -A" . "declare -A map")
                    ("local -n" . "local -n ref=other")
                    ("\\${[a-zA-Z_]*,,}" . "x=${name,,}")
                    ("\\${[a-zA-Z_]*\\^\\^}" . "x=${name^^}")
                    (";&" . "  a) cmd ;& b) other ;;")
                    (";&" . "  a) cmd ;;& b) other ;;")
                    ("|&" . "cmd |& tee log")
                    ("\\[-[0-9]+\\]" . "last=${arr[-1]}")
                    ("\\[\\[ -v" . "if [[ -v name ]]; then")
                    ("&>>" . "cmd &>> log")
                    ("\\${[A-Za-z_]+@[QEPAa]}" . "x=${name@Q}")
                    ("\\${[A-Za-z_]+[,^]}" . "x=${name^}")
                    ("\\bread\\b[^\n]* -[a-zA-Z]*t " . "read -t 0.1 line")
                    ("\\bwait -n\\b" . "wait -n")
                    ("declare -g" . "declare -g name=1")
                    ("\\bcoproc\\b" . "coproc cat")))
      (should (string-match-p (car case) (cdr case)))
      (should-not (string-match-p (car case) code)))))

(ert-deftest drgnx-install/never-touches-the-users-emacs-config ()
  ;; The plan names neither ~/.emacs.d nor ~/.config/emacs; a real run (a kept fake Emacs, --source-dir)
  ;; leaves both byte for byte as they were and writes no shell startup file.
  (let* ((home (make-temp-file "drgnx-install-home" t))
         (files (mapcar (lambda (f) (expand-file-name f home)) '(".emacs.d/init.el" ".config/emacs/init.el")))
         (tmp (make-temp-file "drgnx-install" t)))
    (unwind-protect
        (progn
          (dolist (f files)
            (make-directory (file-name-directory f) t)
            (write-region (format "(message \"mine: %s\")\n" (file-name-nondirectory f)) nil f))
          (let ((before (mapcar (lambda (f) (with-temp-buffer (insert-file-contents-literally f) (buffer-string))) files))
                (env (append (list (concat "HOME=" home) "SHELL=/bin/zsh"
                                   (concat "DRGNX_CONFIG_DIR=" home "/.config/drgnx")
                                   (concat "DRGNX_DATA_DIR=" home "/.local/share/drgnx")
                                   (concat "DRGNX_INSTALL_EMACS=" (drgnx-install-test--fake-emacs tmp "31.1 t ns")))
                             drgnx-install-test--macos)))
            (let ((plan (drgnx-install-test--run env "--dry-run" "--method" "keep")))
              (should (= (car plan) 0))
              (should-not (string-search ".emacs.d" (cdr plan)))
              (should-not (string-search ".config/emacs" (cdr plan))))
            (let ((run (drgnx-install-test--run env "--yes" "--method" "keep" "--prefix" (expand-file-name "prefix" tmp)
                                                "--source-dir" drgnx-install-test--root)))
              (should (= (car run) 0))
              (should (string-search "Next time: open drgnx with Spotlight (⌘Space, type \"drgnx\") or Launchpad, or run \"drgnx .\" in a project" (cdr run)))
              (should (string-search "drag ~/Applications/drgnx.app there" (cdr run)))
              (should (string-match-p "^Done\\.$" (cdr run)))                 ; macOS: no Emacs command line to start it
              (should-not (string-search "Start drgnx with" (cdr run)))
              (should-not (string-search "--init-directory" (cdr run)))
              (should-not (string-search "from Applications" (cdr run))))
            (should (equal before (mapcar (lambda (f) (with-temp-buffer (insert-file-contents-literally f) (buffer-string)))
                                          files)))
            ;; the real run remembers the Emacs it kept, in drgnx's data dir (machine-local), not the config dir
            (should-not (file-exists-p (expand-file-name ".config/drgnx/emacs" home)))
            (should (equal (with-temp-buffer (insert-file-contents (expand-file-name ".local/share/drgnx/emacs" home))
                                             (buffer-string))
                           (concat (expand-file-name "emacs" tmp) "\n")))
            (should-not (file-exists-p (expand-file-name ".zprofile" home)))
            (should-not (file-exists-p (expand-file-name ".profile" home)))))
      (delete-directory home t)
      (delete-directory tmp t))))

(ert-deftest drgnx-install/linux-final-message-stays ()
  (let ((tmp (make-temp-file "drgnx-install" t)))
    (unwind-protect
        (let ((r (drgnx-install-test--run
                  (list (concat "DRGNX_INSTALL_OS_RELEASE=" (drgnx-install-test--os "fedora-45"))
                        "DRGNX_INSTALL_UNAME=Linux"
                        (concat "DRGNX_INSTALL_EMACS=" (drgnx-install-test--fake-emacs tmp "31.1 t pgtk")))
                  "--yes" "--method" "keep" "--prefix" (expand-file-name "prefix" tmp) "--source-dir" drgnx-install-test--root)))
          (should (= (car r) 0))
          (should (string-search "Done. Start drgnx with:" (cdr r)))
          (should-not (string-search "Next time" (cdr r)))
          (should-not (string-search "drgnx app" (cdr r)))
          (should-not (string-search "Opening drgnx" (cdr r))))
      (delete-directory tmp t))))

(ert-deftest drgnx-install/the-macos-plan-names-the-app-and-linux-does-not ()
  (drgnx-install-test--expect (drgnx-install-test--run (cons "DRGNX_INSTALL_BREW=none" drgnx-install-test--macos) "--dry-run")
                              "5. Install the drgnx app into " "/Applications/drgnx.app" "Finder, Spotlight, the Dock, Open With"
                              "6. Run drgnx doctor" "7. Open the drgnx app")
  (drgnx-install-test--expect (drgnx-install-test--plan "fedora-45") "5. Run drgnx doctor")
  (should-not (string-search "drgnx app" (cdr (drgnx-install-test--plan "fedora-45")))))

(ert-deftest drgnx-install/macos-installs-the-app-and-opens-it-only-in-a-desktop-session ()
  ;; A fake Emacs answers the probe and, for `drgnx macos-app', makes the app; a fake `open' logs its argv.
  ;; The app opens only with a terminal and not over SSH; a failed app step warns and the run goes on.
  (let* ((tmp (make-temp-file "drgnx-install" t))
         (bin (expand-file-name "bin" tmp))
         (log (expand-file-name "open.log" tmp))
         (fake (expand-file-name "emacs" tmp))
         (run (lambda (&rest env)
                (when (file-exists-p log) (delete-file log))
                (drgnx-install-test--run
                 (append env (list (concat "DRGNX_INSTALL_EMACS=" fake) (concat "PATH=" bin ":" (getenv "PATH")))
                         drgnx-install-test--macos)
                 "--yes" "--method" "keep" "--prefix" (expand-file-name "prefix" tmp) "--source-dir" drgnx-install-test--root)))
         (opened (lambda () (and (file-exists-p log) (with-temp-buffer (insert-file-contents log) (buffer-string))))))
    (unwind-protect
        (progn
          (make-directory bin)
          (write-region (format "#!/bin/sh\necho \"open $*\" >> '%s'\n" log) nil (expand-file-name "open" bin))
          (set-file-modes (expand-file-name "open" bin) #o755)
          (write-region (concat "#!/bin/sh\ncase \"$*\" in\n"
                                "  *drgnx-macos-cli*) [ -n \"$FAIL_APP\" ] && exit 1\n"
                                "    mkdir -p \"$HOME/Applications/drgnx.app\" && echo \"$HOME/Applications/drgnx.app\" ;;\n"
                                "  *) echo '31.1 t ns' ;;\nesac\n")
                        nil fake)
          (set-file-modes fake #o755)
          ;; a terminal, no SSH: installed, then opened
          (let ((r (funcall run "DRGNX_INSTALL_TTY=yes" "SSH_CONNECTION")))
            (should (= (car r) 0))
            (should (string-match-p "/Applications/drgnx\\.app\n" (cdr r)))
            ;; the app first, then the doctor (which checks it): never "the app is missing" just before installing it
            (should (< (string-search "Installing the drgnx app" (cdr r)) (string-search "31.1 t ns" (cdr r))))
            (should (string-search "Opening drgnx…" (cdr r)))
            (should (string-search "Next time: open drgnx with Spotlight" (cdr r)))
            (should (string-match-p "\\`open -a .*/Applications/drgnx\\.app\n\\'" (funcall opened))))
          ;; --yes without a terminal, or over SSH: installed, not opened
          (dolist (env '(("DRGNX_INSTALL_TTY=none" "SSH_CONNECTION") ("DRGNX_INSTALL_TTY=yes" "SSH_CONNECTION=10.0.0.1 22 10.0.0.2 22")))
            (let ((r (apply run env)))
              (should (= (car r) 0))
              (should-not (string-search "Opening drgnx" (cdr r)))
              (should-not (funcall opened))))
          ;; the app step fails: a warning, the rest of the run as before, nothing opened
          (let ((r (funcall run "DRGNX_INSTALL_TTY=yes" "SSH_CONNECTION" "FAIL_APP=1")))
            (should (= (car r) 0))
            (should (string-search "the drgnx app was not installed" (cdr r)))
            (should (string-search "Next time: open drgnx with Spotlight" (cdr r)))
            (should-not (funcall opened))))
      (delete-directory tmp t))))

(ert-deftest drgnx-install/a-good-emacs-is-kept ()
  (let ((fake (make-temp-file "fake-emacs")))
    (unwind-protect
        (progn
          (write-region "#!/bin/sh\necho '31.1 t pgtk'\n" nil fake)
          (set-file-modes fake #o755)
          (drgnx-install-test--expect
           (drgnx-install-test--plan "fedora-44" (concat "DRGNX_INSTALL_EMACS=" fake) "--method" "keep")
           "keep the installed Emacs 31.1"))
      (delete-file fake))))

(ert-deftest drgnx-install/the-plan-remembers-the-emacs ()
  (drgnx-install-test--expect
   (drgnx-install-test--run (append '("DRGNX_INSTALL_UNAME=Darwin" "DRGNX_INSTALL_ARCH=arm64" "DRGNX_INSTALL_MACOS=15.4"
                                      "DRGNX_INSTALL_BREW=none")
                                    nil)
                            "--dry-run")
   "Remember Emacs: " "/.local/opt/nidhogg/31.1-nidhogg.1/Nidhogg.app/Contents/MacOS/Emacs")
  (let ((tmp (make-temp-file "drgnx-install" t)))
    (unwind-protect
        (let ((fake (drgnx-install-test--fake-emacs tmp "31.1 t ns")))
          (drgnx-install-test--expect
           (drgnx-install-test--run
            (append (list (concat "DRGNX_INSTALL_EMACS=" fake) "DRGNX_INSTALL_BREW=none") drgnx-install-test--macos)
            "--dry-run" "--method" "keep")
           (concat "Remember Emacs: " fake)))
      (delete-directory tmp t))))

(ert-deftest drgnx-install/no-terminal-without-yes-refuses-before-acting ()
  (let ((home (make-temp-file "drgnx-install-home" t)))
    (unwind-protect
        (let ((r (drgnx-install-test--run (list (concat "DRGNX_INSTALL_OS_RELEASE=" (drgnx-install-test--os "fedora-45"))
                                                "DRGNX_INSTALL_UNAME=Linux" (concat "HOME=" home)))))
          (should (= (car r) 3))
          (should (string-search "--yes" (cdr r)))
          (should-not (directory-files home nil directory-files-no-dot-files-regexp)))   ; nothing written
      (delete-directory home t))))

(ert-deftest drgnx-install/each-run-has-its-own-home ()
  ;; M2.5-8: never a fixed, shared HOME — a new one per run, gone afterwards.
  (let ((homes (mapcar (lambda (_)
                         (let ((r (drgnx-install-test--plan "fedora-45")))
                           (should (string-match " into \\(.*\\)/\\.local/share/drgnx/drgnx" (cdr r)))
                           (match-string 1 (cdr r))))
                       '(1 2))))
    (should-not (equal (car homes) (cadr homes)))
    (dolist (h homes)
      (should (string-prefix-p (file-name-as-directory (file-truename temporary-file-directory)) (file-truename h)))
      (should-not (file-exists-p h)))))

(ert-deftest drgnx-install/a-missing-option-value-is-a-bad-option ()
  ;; M2.5-6: exit 2, as docs/guide/install.md says for a bad option.
  (dolist (opt '("--prefix" "--dir" "--source-dir" "--method" "--branch"))
    (let ((r (drgnx-install-test--run nil "--dry-run" opt)))
      (should (= (car r) 2))
      (should (string-search (concat opt " needs") (cdr r))))))

(ert-deftest drgnx-install/image-based-fedora-gets-toolbox ()
  ;; M2.5-11: Silverblue, Kinoite, Bazzite (/run/ostree-booted): dnf cannot install there — refused before
  ;; the plan with the way that works; an Emacs asked to be kept is kept.
  (let ((booted (make-temp-file "ostree-booted")) (fake (make-temp-file "fake-emacs")))
    (unwind-protect
        (progn
          (dolist (os '("fedora-45" "fedora-44"))
            (let ((r (drgnx-install-test--plan os (concat "DRGNX_INSTALL_OSTREE_BOOTED=" booted))))
              (should (= (car r) 2))
              (should (string-search "toolbox" (cdr r)))
              (should-not (string-search "dnf install" (cdr r)))))
          (write-region "#!/bin/sh\necho '31.1 t pgtk'\n" nil fake)
          (set-file-modes fake #o755)
          (drgnx-install-test--expect (drgnx-install-test--plan "fedora-45" (concat "DRGNX_INSTALL_OSTREE_BOOTED=" booted)
                                                                (concat "DRGNX_INSTALL_EMACS=" fake) "--method" "keep")
                                      "keep the installed Emacs 31.1"))
      (delete-file booted)
      (delete-file fake))))

(ert-deftest drgnx-install/plan-names-the-drgnx-steps ()
  (drgnx-install-test--expect (drgnx-install-test--plan "fedora-45")
                              "git clone" ".local/share/drgnx/drgnx" "bin/drgnx" "drgnx build" "drgnx doctor"))

(ert-deftest drgnx-install/rerun-updates-the-existing-checkout ()
  (let ((dir (make-temp-file "drgnx-checkout" t)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".git" dir))
          (drgnx-install-test--expect
           (drgnx-install-test--run (list (concat "DRGNX_INSTALL_OS_RELEASE=" (drgnx-install-test--os "fedora-45"))
                                          "DRGNX_INSTALL_UNAME=Linux")
                                    "--dry-run" "--dir" dir)
           (format "update %s (git pull --ff-only)" dir)))
      (delete-directory dir t))))

(ert-deftest drgnx-install/the-path-hint-names-the-shell-startup-file ()
  ;; M2.5-3: zsh (macOS's default) never reads ~/.profile.  A run with --yes keeps a good (fake) Emacs,
  ;; links drgnx into a temp prefix that is not on PATH, and prints the hint.
  (let* ((tmp (make-temp-file "drgnx-install" t))
         (fake (expand-file-name "emacs" tmp)))
    (unwind-protect
        (progn
          (write-region "#!/bin/sh\necho '31.1 t pgtk'\n" nil fake)
          (set-file-modes fake #o755)
          (pcase-dolist (`(,shell ,file) '(("/bin/zsh" "/.zprofile") ("/bin/bash" "/.profile") ("" "/.profile")))
            (let ((r (drgnx-install-test--run
                      (list (concat "DRGNX_INSTALL_OS_RELEASE=" (drgnx-install-test--os "fedora-45"))
                            "DRGNX_INSTALL_UNAME=Linux" (concat "DRGNX_INSTALL_EMACS=" fake) (concat "SHELL=" shell))
                      "--yes" "--method" "keep" "--prefix" (expand-file-name "prefix" tmp) "--source-dir" drgnx-install-test--root)))
              (should (= (car r) 0))
              (should (string-match-p (concat "add this to [^ ]*" (regexp-quote file) ": export PATH=") (cdr r))))))
      (delete-directory tmp t))))

(ert-deftest drgnx-install/root-steps-are-announced-even-with-yes ()
  (skip-unless (/= 0 (user-uid)))     ; as root, as_root runs commands without sudo: they would really run
  ;; The fixture's sudo only logs: nothing escalates on the developer's machine.
  (let ((tmp (make-temp-file "drgnx-install" t)))
    (unwind-protect
        (let* ((fx (drgnx-install-test--nidhogg-fixture tmp))
               (r (drgnx-install-test--nidhogg-run tmp fx))
               (log (drgnx-install-test--file (expand-file-name "log" tmp))))
          (should (= (car r) 0))
          (should (string-search "As root: dnf install -y libbuildfoo libbuildbar" (cdr r)))
          (should (string-search "sudo dnf install -y libbuildfoo libbuildbar" log)))
      (delete-directory tmp t))))

(ert-deftest drgnx-install/e2e-tier-names-its-images ()
  ;; `drgnx test --install IMAGE…' runs install.sh in fresh containers; an unknown name lists the known ones.
  (should (= 0 (call-process "bash" nil nil nil "-n" (expand-file-name "test/install/in-container.sh" drgnx-install-test--root))))
  (with-temp-buffer
    (let ((default-directory drgnx-install-test--root))
      (should (= 2 (call-process (expand-file-name "bin/drgnx" drgnx-install-test--root) nil t nil "test" "--install" "plan9")))
      (dolist (name '("fedora-44" "fedora-45" "debian-trixie" "ubuntu-26.04" "archlinux"))
        (should (string-search name (buffer-string)))))))

(ert-deftest drgnx-install/git-is-installed-when-missing ()
  (skip-unless (/= 0 (user-uid)))     ; as root, as_root runs commands without sudo: they would really run
  ;; Cloning drgnx needs git; a package install (Arch, Fedora 45) does not bring it.  PATH: /usr/bin
  ;; without git, plus a fake sudo.
  (let* ((tmp (make-temp-file "drgnx-install" t))
         (bin (expand-file-name "bin" tmp))
         (fake-emacs (expand-file-name "emacs" tmp)))
    (unwind-protect
        (progn
          (make-directory bin)
          (dolist (f (directory-files "/usr/bin" t directory-files-no-dot-files-regexp))
            (unless (string-match-p "\\`git" (file-name-nondirectory f))
              (make-symbolic-link f (expand-file-name (file-name-nondirectory f) bin))))
          (delete-file (expand-file-name "sudo" bin))
          (write-region "#!/bin/sh\necho \"FAKE-SUDO $*\"\nexit 1\n" nil (expand-file-name "sudo" bin))
          (set-file-modes (expand-file-name "sudo" bin) #o755)
          (write-region "#!/bin/sh\necho '31.1 t pgtk'\n" nil fake-emacs)
          (set-file-modes fake-emacs #o755)
          (let ((r (drgnx-install-test--run
                    (list (concat "DRGNX_INSTALL_OS_RELEASE=" (drgnx-install-test--os "fedora-45"))
                          "DRGNX_INSTALL_UNAME=Linux"
                          (concat "DRGNX_INSTALL_EMACS=" fake-emacs)
                          (concat "PATH=" bin))
                    "--yes" "--method" "keep" "--dir" (expand-file-name "checkout" tmp))))
            (should (= (car r) 1))
            (should (string-search "As root: dnf install -y git" (cdr r)))))
      (delete-directory tmp t))))

(ert-deftest drgnx-install/fedora-family-is-fedora-itself ()
  ;; RHEL clones and Amazon Linux carry `fedora' in ID_LIKE but have no Fedora packages: no recipe.
  ;; Fedora remixes (Nobara) have a Fedora PLATFORM_ID (42 here, which has no recipe either; 44 and 45 do).
  (dolist (os '("rocky-9" "amazon-2023" "nobara-42"))
    (let ((r (drgnx-install-test--plan os)))
      (should (= (car r) 1))
      (should (string-search "no Nidhogg recipe for" (cdr r))))))

(ert-deftest drgnx-install/relative-paths-become-absolute ()
  ;; `--source-dir .' from a clone: the drgnx link must not dangle.
  (let ((r (drgnx-install-test--run (list (concat "DRGNX_INSTALL_OS_RELEASE=" (drgnx-install-test--os "fedora-45"))
                                          "DRGNX_INSTALL_UNAME=Linux")
                                    "--dry-run" "--source-dir" "." "--prefix" "rel-prefix")))
    (should (= (car r) 0))
    (should (string-search (concat "→ " (directory-file-name drgnx-install-test--root)) (cdr r)))
    (should (string-search (concat "Link " (directory-file-name drgnx-install-test--root)) (cdr r)))))

(ert-deftest drgnx-install/build-jobs-fit-in-memory ()
  ;; Native compilation runs one Emacs per make job: one job per CPU on a big machine starved the host of
  ;; memory (systemd-oomd killed the desktop session).  At most one job per 1.5 GiB of available memory.
  (cl-flet ((plan (cpus mem-kb)
              (drgnx-install-test--plan "fedora-44" (format "DRGNX_INSTALL_NPROC=%d" cpus)
                                        (format "DRGNX_INSTALL_MEMORY_KB=%d" mem-kb))))
    (drgnx-install-test--expect (plan 16 (* 6 1024 1024)) "make -j4 ")
    (drgnx-install-test--expect (plan 16 (* 64 1024 1024)) "make -j16 ")
    (drgnx-install-test--expect (plan 4 (* 64 1024 1024)) "make -j4 ")
    (drgnx-install-test--expect (plan 16 (* 1 1024 1024)) "make -j1 ")))

;;; Nidhogg: the plan (Task 10)

(defun drgnx-install-test--podman (dir status)
  "A podman stub in DIR whose `info' exits with STATUS; return its file name."
  (let ((f (expand-file-name "podman" dir)))
    (write-region (format "#!/bin/sh\ncase \"$1\" in info) exit %d ;; esac\nexit 0\n" status) nil f)
    (set-file-modes f #o755)
    f))

(defmacro drgnx-install-test--with-tmp (var &rest body)
  (declare (indent 1))
  `(let ((,var (make-temp-file "drgnx-install" t)))
     (unwind-protect (progn ,@body) (delete-directory ,var t))))

(defconst drgnx-install-test--roomy
  (list "DRGNX_INSTALL_NPROC=16" (format "DRGNX_INSTALL_MEMORY_KB=%d" (* 16 1024 1024)))
  "16 CPUs and 16 GiB available.")

(ert-deftest drgnx-install/fedora-44-builds-nidhogg-in-a-container ()
  (drgnx-install-test--with-tmp tmp
    (drgnx-install-test--expect
     (apply #'drgnx-install-test--plan "fedora-44"
            (concat "DRGNX_INSTALL_PODMAN=" (drgnx-install-test--podman tmp 0)) drgnx-install-test--roomy)
     "build Nidhogg 31.1-nidhogg.1" "podman container (registry.fedoraproject.org/fedora:44)" "capped at 6g"
     "make -j4" "/.local/opt/nidhogg/31.1-nidhogg.1" "nidhogg/deps/fedora-44.runtime"
     "Remember Emacs: " "/.local/opt/nidhogg/31.1-nidhogg.1/bin/nidhogg"
     "check that it is commit " "link " "/bin/nidhogg and " "refresh drgnx.service's Emacs if it is installed")))

(ert-deftest drgnx-install/without-podman-nidhogg-builds-on-the-host ()
  (let ((out (cdr (apply #'drgnx-install-test--plan "fedora-44" "DRGNX_INSTALL_PODMAN=none" drgnx-install-test--roomy))))
    (dolist (s '("build Nidhogg 31.1-nidhogg.1" "build on this machine (podman is not installed): make -j10"
                 "nidhogg/deps/fedora-44.build"))
      (should (string-search s out)))
    (should-not (string-search "podman container" out))))

(ert-deftest drgnx-install/inside-a-container-builds-on-the-host ()
  (drgnx-install-test--with-tmp tmp
    (drgnx-install-test--expect
     (drgnx-install-test--plan "fedora-44" (concat "DRGNX_INSTALL_PODMAN=" (drgnx-install-test--podman tmp 0))
                               "DRGNX_INSTALL_IN_CONTAINER=yes")
     "build on this machine (you are inside a container)" "nidhogg/deps/fedora-44.build")))

(ert-deftest drgnx-install/podman-that-cannot-run-falls-back ()
  (drgnx-install-test--with-tmp tmp
    (let ((out (cdr (drgnx-install-test--plan "fedora-44" (concat "DRGNX_INSTALL_PODMAN=" (drgnx-install-test--podman tmp 125))))))
      (should (string-search "build on this machine (podman cannot run containers here)" out))
      (should-not (string-search "podman container" out)))))

(ert-deftest drgnx-install/fedora-45-and-ubuntu-26.04-build-nidhogg ()
  (drgnx-install-test--with-tmp tmp
    (let ((podman (concat "DRGNX_INSTALL_PODMAN=" (drgnx-install-test--podman tmp 0))))
      (drgnx-install-test--expect (apply #'drgnx-install-test--plan "fedora-45" podman drgnx-install-test--roomy)
                                  "(registry.fedoraproject.org/fedora:45)" "nidhogg/deps/fedora-45.runtime")
      (drgnx-install-test--expect (apply #'drgnx-install-test--plan "ubuntu-26.04" podman drgnx-install-test--roomy)
                                  "(docker.io/library/ubuntu:26.04)" "nidhogg/deps/ubuntu-26.04.runtime")
      (drgnx-install-test--expect (drgnx-install-test--plan "ubuntu-26.04" "DRGNX_INSTALL_PODMAN=none")
                                  "nidhogg/deps/ubuntu-26.04.build"))))

(ert-deftest drgnx-install/macos-builds-nidhogg-app ()
  (let* ((r (drgnx-install-test--run (cons "DRGNX_INSTALL_BREW=/opt/homebrew/bin/brew" drgnx-install-test--macos) "--dry-run"))
         (out (cdr r)))
    (should (= (car r) 0))
    (dolist (s '("build Nidhogg 31.1-nidhogg.1" "Nidhogg.app into " "/.local/opt/nidhogg/31.1-nidhogg.1"
                 "nidhogg/deps/macos.build" "Nidhogg.app/Contents/MacOS/Emacs"))
      (should (string-search s out)))
    (should-not (string-search "emacs-plus" out))
    (should-not (string-search "refresh drgnx.service" out))))

(ert-deftest drgnx-install/a-current-nidhogg-is-kept ()
  (drgnx-install-test--with-tmp tmp
    (let ((r (drgnx-install-test--plan "fedora-44" (concat "DRGNX_INSTALL_EMACS=" (drgnx-install-test--fake-emacs tmp "31.1 t pgtk 31.1-nidhogg.1")))))
      (should (= (car r) 0))
      (should (string-search "keep the installed Nidhogg 31.1-nidhogg.1 (" (cdr r)))
      (should-not (string-search "build Nidhogg" (cdr r)))
      (should-not (string-search "build on this machine" (cdr r))))))

(ert-deftest drgnx-install/an-older-nidhogg-is-rebuilt ()
  (drgnx-install-test--with-tmp tmp
    (drgnx-install-test--expect
     (drgnx-install-test--plan "fedora-44" (concat "DRGNX_INSTALL_EMACS=" (drgnx-install-test--fake-emacs tmp "31.1 t pgtk 31.1-nidhogg.0")))
     "build Nidhogg 31.1-nidhogg.1")))

(ert-deftest drgnx-install/a-stock-emacs-gets-nidhogg-unless-kept ()
  (drgnx-install-test--with-tmp tmp
    (let ((emacs (concat "DRGNX_INSTALL_EMACS=" (drgnx-install-test--fake-emacs tmp "31.1 t pgtk"))))
      (drgnx-install-test--expect (drgnx-install-test--plan "fedora-44" emacs) "build Nidhogg 31.1-nidhogg.1")
      (let ((out (cdr (drgnx-install-test--plan "fedora-44" emacs "--method" "keep"))))
        (should (string-search "keep the installed Emacs 31.1" out))
        (should-not (string-search "build Nidhogg" out)))
      ;; no recipe: a stock Emacs is not a reason to go on, only --method keep does
      (should (= 1 (car (drgnx-install-test--plan "debian-13" emacs))))
      (drgnx-install-test--expect (drgnx-install-test--plan "debian-13" emacs "--method" "keep") "keep the installed Emacs 31.1"))))

(ert-deftest drgnx-install/low-memory-shrinks-or-refuses ()
  (drgnx-install-test--with-tmp tmp
    (let ((podman (concat "DRGNX_INSTALL_PODMAN=" (drgnx-install-test--podman tmp 0))))
      (drgnx-install-test--expect
       (drgnx-install-test--plan "fedora-44" podman "DRGNX_INSTALL_NPROC=16" (format "DRGNX_INSTALL_MEMORY_KB=%d" (* 5 1024 1024)))
       "capped at 4g" "make -j2")
      (let ((r (drgnx-install-test--plan "fedora-44" podman "DRGNX_INSTALL_NPROC=16" (format "DRGNX_INSTALL_MEMORY_KB=%d" (* 3 1024 1024)))))
        (should (= (car r) 1))
        (should (string-search "needs 3 GiB of free memory" (cdr r)))
        (should-not (string-search "1. Emacs" (cdr r)))))))

;;; Nidhogg: fetch, build, install (Task 11)

(defun drgnx-install-test--script (file text)
  (write-region text nil file)
  (set-file-modes file #o755))

(defun drgnx-install-test--nidhogg-fixture (tmp)
  "In TMP: a git repo `nidhogg' (tag v31.1-nidhogg.1) with a stub nidhogg/build.sh that logs its arguments to $NH_LOG
and writes PREFIX/bin/{nidhogg,emacs,nidhoggclient} answering the probe (NH_FAIL=1: exits 1; NH_BROKEN=1: binaries that do
not start) and deps lists; `bin' with a sudo and an rpm stub (RPM_ALL=1: everything installed); `drgnx', a checkout whose
bin/drgnx logs its arguments.  Return (ENV . COMMIT): the environment of a real run on Fedora 44."
  (let* ((repo (expand-file-name "nidhogg" tmp)) (bin (expand-file-name "bin" tmp))
         (checkout (expand-file-name "drgnx" tmp)) (home (expand-file-name "home" tmp))
         (git (lambda (&rest args)
                (should (= 0 (apply #'call-process "git" nil nil nil "-C" repo "-c" "user.name=t" "-c" "user.email=t@t.invalid"
                                    "-c" "commit.gpgsign=false" "-c" "core.hooksPath=/dev/null" args))))))
    (dolist (d (list (expand-file-name "nidhogg/deps" repo) bin (expand-file-name "bin" checkout) home))
      (make-directory d t))
    (drgnx-install-test--script
     (expand-file-name "nidhogg/build.sh" repo)
     (concat "#!/bin/sh\necho \"build.sh $*\" >> \"$NH_LOG\"\n[ -z \"$NH_FAIL\" ] || exit 1\n"
             "while [ $# -gt 0 ]; do case $1 in --prefix) P=$2; shift ;; esac; shift; done\nmkdir -p \"$P/bin\"\n"
             "for n in nidhogg emacs nidhoggclient; do\n"
             "  if [ -n \"$NH_BROKEN\" ]; then printf '#!/bin/sh\\nexit 127\\n' > \"$P/bin/$n\"\n"
             "  else printf '#!/bin/sh\\necho \"31.1 t pgtk 31.1-nidhogg.1\"\\n' > \"$P/bin/$n\"; fi\n"
             "  chmod +x \"$P/bin/$n\"\ndone\n"
             ;; and the macOS layout (Nidhogg.app)
             "A=\"$P/Nidhogg.app/Contents/MacOS\"; mkdir -p \"$A/bin\"\n"
             "printf '#!/bin/sh\\necho \"31.1 t ns 31.1-nidhogg.1\"\\n' > \"$A/Emacs\"; chmod +x \"$A/Emacs\"\n"
             "cp \"$A/Emacs\" \"$A/bin/emacsclient\"\n"))
    (dolist (f '(("fedora-44.runtime" . "# runtime\nlibfoo\nlibbar\n") ("fedora-44.build" . "# build\n\nlibbuildfoo\nlibbuildbar\n")
                 ("macos.build" . "# build\nlibmacfoo\n")))
      (write-region (cdr f) nil (expand-file-name (concat "nidhogg/deps/" (car f)) repo)))
    (funcall git "init" "-q")
    (funcall git "add" "-A")
    (funcall git "commit" "-qm" "nidhogg: fixture")
    (funcall git "tag" "v31.1-nidhogg.1")
    (drgnx-install-test--script (expand-file-name "sudo" bin) "#!/bin/sh\necho \"sudo $*\" >> \"$NH_LOG\"\n")
    (drgnx-install-test--script (expand-file-name "rpm" bin) "#!/bin/sh\n[ -n \"$RPM_ALL\" ]\n")
    (drgnx-install-test--script (expand-file-name "bin/drgnx" checkout)
                                "#!/bin/sh\necho \"drgnx $* [DRGNX_EMACS=$DRGNX_EMACS]\" >> \"$NH_LOG\"\n")
    (cons (list (concat "DRGNX_INSTALL_OS_RELEASE=" (drgnx-install-test--os "fedora-44")) "DRGNX_INSTALL_UNAME=Linux"
                (concat "DRGNX_INSTALL_NIDHOGG_REPO=" repo)
                (concat "NH_LOG=" tmp "/log") (concat "HOME=" home)
                (concat "DRGNX_DATA_DIR=" home "/.local/share/drgnx") (concat "DRGNX_CONFIG_DIR=" home "/.config/drgnx")
                (concat "XDG_CACHE_HOME=" tmp "/cache") (concat "PATH=" bin ":" (getenv "PATH")))
          (with-temp-buffer (call-process "git" nil t nil "-C" repo "rev-parse" "HEAD") (string-trim (buffer-string))))))

(defun drgnx-install-test--macos-env (fixture)
  "The environment of FIXTURE for a run on macOS 15.4 instead of Fedora 44 (the first entry of a name wins)."
  (append drgnx-install-test--macos (list (concat "DRGNX_INSTALL_NIDHOGG_COMMIT=" (cdr fixture))) (car fixture)))

(defun drgnx-install-test--nidhogg-run (tmp fixture &optional env commit)
  "Run install.sh --yes in the fixture of TMP with ENV added; COMMIT overrides the pinned one."
  (drgnx-install-test--run (append env (list (concat "DRGNX_INSTALL_NIDHOGG_COMMIT=" (or commit (cdr fixture)))) (car fixture))
                           "--yes" "--source-dir" (expand-file-name "drgnx" tmp)))

(defun drgnx-install-test--file (file)
  (and (file-exists-p file) (with-temp-buffer (insert-file-contents file) (buffer-string))))

(ert-deftest drgnx-install/nidhogg-pin-mismatch-installs-nothing ()
  (skip-unless (/= 0 (user-uid)))     ; as root, as_root runs commands without sudo: they would really run
  (drgnx-install-test--with-tmp tmp
    (let* ((fx (drgnx-install-test--nidhogg-fixture tmp))
           (r (drgnx-install-test--nidhogg-run tmp fx nil (make-string 40 ?0))))
      (should (= (car r) 1))
      (should (string-search "not the commit drgnx pins" (cdr r)))
      (should (string-search "nothing was installed" (cdr r)))
      (should-not (string-search "As root:" (cdr r)))
      (should-not (file-exists-p (expand-file-name "home/.local/opt" tmp)))
      (should-not (file-exists-p (expand-file-name "home/.local/share/drgnx/emacs" tmp)))
      (should-not (drgnx-install-test--file (expand-file-name "log" tmp))))))

(ert-deftest drgnx-install/nidhogg-container-build-runs-capped ()
  (skip-unless (/= 0 (user-uid)))
  (drgnx-install-test--with-tmp tmp
    (let* ((fx (drgnx-install-test--nidhogg-fixture tmp))
           (home (expand-file-name "home" tmp))
           (r (drgnx-install-test--nidhogg-run
               tmp fx (append (list (concat "DRGNX_INSTALL_PODMAN=" (drgnx-install-test--podman tmp 0))) drgnx-install-test--roomy)))
           (log (drgnx-install-test--file (expand-file-name "log" tmp)))
           (prefix (concat home "/.local/opt/nidhogg/31.1-nidhogg.1")))
      (should (= (car r) 0))
      (should (string-search (concat "build.sh --container fedora-44 --memory 6g --jobs 4 --prefix " prefix) log))
      (should (string-search "--build-dir " log))
      (should (string-search "sudo dnf install -y libfoo libbar" log))
      (should-not (string-search "libbuildfoo" log))
      (should (equal (drgnx-install-test--file (expand-file-name ".local/share/drgnx/emacs" home))
                     (concat prefix "/bin/nidhogg\n")))
      (should (equal (file-truename (expand-file-name ".local/bin/nidhogg" home)) (file-truename (concat prefix "/bin/nidhogg"))))
      (should (file-symlink-p (expand-file-name ".local/bin/nidhoggclient" home)))
      ;; the bootstrap steps ran in the new Emacs
      (should (string-search (concat "drgnx build [DRGNX_EMACS=" prefix "/bin/nidhogg]") log)))))

(ert-deftest drgnx-install/nidhogg-host-build-without-podman ()
  (skip-unless (/= 0 (user-uid)))
  (drgnx-install-test--with-tmp tmp
    (let* ((fx (drgnx-install-test--nidhogg-fixture tmp))
           (r (drgnx-install-test--nidhogg-run tmp fx drgnx-install-test--roomy))
           (log (drgnx-install-test--file (expand-file-name "log" tmp))))
      (should (= (car r) 0))
      (should (string-match-p "build\\.sh --host --jobs 10 --prefix " log))
      (should-not (string-search "--container" log))
      (should (string-search "sudo dnf install -y libbuildfoo libbuildbar" log))
      (should-not (string-search "libfoo" log)))))

(ert-deftest drgnx-install/deps-already-installed-need-no-root ()
  (skip-unless (/= 0 (user-uid)))
  (drgnx-install-test--with-tmp tmp
    (let* ((fx (drgnx-install-test--nidhogg-fixture tmp))
           (r (drgnx-install-test--nidhogg-run tmp fx '("RPM_ALL=1")))
           (log (drgnx-install-test--file (expand-file-name "log" tmp))))
      (should (= (car r) 0))
      (should-not (string-search "As root:" (cdr r)))
      (should-not (string-search "sudo " log))
      (should (string-search "build.sh " log)))))

(ert-deftest drgnx-install/a-failed-nidhogg-build-keeps-the-old-emacs ()
  (skip-unless (/= 0 (user-uid)))
  (drgnx-install-test--with-tmp tmp
    (let* ((fx (drgnx-install-test--nidhogg-fixture tmp))
           (home (expand-file-name "home" tmp))
           (record (expand-file-name ".local/share/drgnx/emacs" home)))
      (make-directory (file-name-directory record) t)
      (write-region "/old/emacs\n" nil record)
      (let ((r (drgnx-install-test--nidhogg-run tmp fx '("NH_FAIL=1"))))
        (should (= (car r) 1))
        (should (string-search "the Nidhogg build failed" (cdr r)))
        (should (string-search "drgnx still uses the Emacs it used" (cdr r)))
        (should (equal (drgnx-install-test--file record) "/old/emacs\n"))
        (should-not (file-exists-p (expand-file-name ".local/bin/nidhogg" home)))
        (should-not (file-exists-p (expand-file-name ".local/opt/nidhogg/31.1-nidhogg.1" home)))
        (should-not (string-search "drgnx build" (drgnx-install-test--file (expand-file-name "log" tmp))))))))

(ert-deftest drgnx-install/a-built-nidhogg-that-does-not-start-is-refused ()
  (skip-unless (/= 0 (user-uid)))
  (drgnx-install-test--with-tmp tmp
    (let* ((fx (drgnx-install-test--nidhogg-fixture tmp))
           (home (expand-file-name "home" tmp))
           (record (expand-file-name ".local/share/drgnx/emacs" home)))
      (make-directory (file-name-directory record) t)
      (write-region "/old/emacs\n" nil record)
      (let ((r (drgnx-install-test--nidhogg-run tmp fx '("NH_BROKEN=1"))))
        (should (= (car r) 1))
        (should (string-search "does not start or is incomplete" (cdr r)))
        (should (string-search "not found" (cdr r)))
        (should (equal (drgnx-install-test--file record) "/old/emacs\n"))
        (should-not (file-exists-p (expand-file-name ".local/bin/nidhogg" home)))))))

(ert-deftest drgnx-install/nidhogg-install-refreshes-the-unit ()
  (skip-unless (/= 0 (user-uid)))
  (drgnx-install-test--with-tmp tmp
    (let* ((fx (drgnx-install-test--nidhogg-fixture tmp))
           (r (drgnx-install-test--nidhogg-run tmp fx))
           (log (drgnx-install-test--file (expand-file-name "log" tmp)))
           (prefix (concat tmp "/home/.local/opt/nidhogg/31.1-nidhogg.1")))
      (should (= (car r) 0))
      (should (string-search (concat "drgnx service-unit --refresh [DRGNX_EMACS=" prefix "/bin/nidhogg]") log))
      ;; after the build, before the doctor
      (should (< (string-search "drgnx build" log) (string-search "service-unit --refresh" log)))
      (should (< (string-search "service-unit --refresh" log) (string-search "drgnx doctor" log))))))

;;; Fix round: keep of an installed Nidhogg, the build's sizing, the pin

(defun drgnx-install-test--installed-nidhogg (tmp)
  "Put a Nidhogg of the pinned version at the fixture's prefix in TMP; return its nidhogg binary."
  (let* ((prefix (concat tmp "/home/.local/opt/nidhogg/31.1-nidhogg.1")) (bin (concat prefix "/bin")))
    (make-directory bin t)
    (dolist (n '("nidhogg" "emacs" "nidhoggclient"))
      (drgnx-install-test--script (concat bin "/" n) "#!/bin/sh\necho \"31.1 t pgtk 31.1-nidhogg.1\"\n"))
    (concat bin "/nidhogg")))

(ert-deftest drgnx-install/keep-of-an-installed-nidhogg-links-it ()
  (skip-unless (/= 0 (user-uid)))
  (drgnx-install-test--with-tmp tmp
    (let* ((fx (drgnx-install-test--nidhogg-fixture tmp))
           (home (expand-file-name "home" tmp))
           (nid (drgnx-install-test--installed-nidhogg tmp))
           (r (drgnx-install-test--nidhogg-run tmp fx (list (concat "DRGNX_INSTALL_EMACS=" nid)) nil)))
      (should (= (car r) 0))
      (should (equal (file-truename (expand-file-name ".local/bin/nidhogg" home)) (file-truename nid)))
      (should (file-symlink-p (expand-file-name ".local/bin/nidhoggclient" home)))
      ;; an installed Nidhogg of the pinned version is not rebuilt: no fetch, no build, no root step
      (should-not (string-search "build.sh" (or (drgnx-install-test--file (expand-file-name "log" tmp)) "")))
      (should-not (string-search "As root:" (cdr r))))))

(ert-deftest drgnx-install/explicit-keep-links-an-installed-nidhogg ()
  (skip-unless (/= 0 (user-uid)))
  (drgnx-install-test--with-tmp tmp
    (let* ((fx (drgnx-install-test--nidhogg-fixture tmp))
           (home (expand-file-name "home" tmp))
           (nid (drgnx-install-test--installed-nidhogg tmp))
           (r (drgnx-install-test--run (append (list (concat "DRGNX_INSTALL_EMACS=" nid)) (car fx))
                                       "--yes" "--method" "keep" "--source-dir" (expand-file-name "drgnx" tmp))))
      (should (= (car r) 0))
      (should (file-symlink-p (expand-file-name ".local/bin/nidhogg" home)))
      (should (file-symlink-p (expand-file-name ".local/bin/nidhoggclient" home)))
      (should-not (string-search "build.sh" (or (drgnx-install-test--file (expand-file-name "log" tmp)) ""))))))

(ert-deftest drgnx-install/jobs-and-memory-are-passed-through ()
  (drgnx-install-test--with-tmp tmp
    (let ((podman (concat "DRGNX_INSTALL_PODMAN=" (drgnx-install-test--podman tmp 0))))
      ;; the environment
      (drgnx-install-test--expect
       (drgnx-install-test--plan "fedora-44" podman "DRGNX_INSTALL_JOBS=3" "DRGNX_INSTALL_MEMORY=5" "DRGNX_INSTALL_NPROC=16"
                                 (format "DRGNX_INSTALL_MEMORY_KB=%d" (* 64 1024 1024)))
       "capped at 5g" "make -j3")
      ;; the flags win over the environment
      (drgnx-install-test--expect
       (drgnx-install-test--plan "fedora-44" podman "DRGNX_INSTALL_JOBS=3" "--jobs" "2" "--memory" "4" "DRGNX_INSTALL_NPROC=16"
                                 (format "DRGNX_INSTALL_MEMORY_KB=%d" (* 64 1024 1024)))
       "capped at 4g" "make -j2")
      ;; nothing given: the installer's own sizing
      (drgnx-install-test--expect
       (drgnx-install-test--plan "fedora-44" podman "DRGNX_INSTALL_NPROC=16" (format "DRGNX_INSTALL_MEMORY_KB=%d" (* 64 1024 1024)))
       "capped at 6g" "make -j4")
      (should (= 2 (car (drgnx-install-test--plan "fedora-44" "--jobs" "0"))))
      (should (= 2 (car (drgnx-install-test--plan "fedora-44" podman "--memory" "2")))))))

(ert-deftest drgnx-install/the-build-gets-the-jobs-and-memory-asked-for ()
  (skip-unless (/= 0 (user-uid)))
  (drgnx-install-test--with-tmp tmp
    (let* ((fx (drgnx-install-test--nidhogg-fixture tmp))
           (r (drgnx-install-test--nidhogg-run
               tmp fx (append (list (concat "DRGNX_INSTALL_PODMAN=" (drgnx-install-test--podman tmp 0))
                                    "DRGNX_INSTALL_JOBS=2" "DRGNX_INSTALL_MEMORY=5")
                              drgnx-install-test--roomy)))
           (log (drgnx-install-test--file (expand-file-name "log" tmp))))
      (should (= (car r) 0))
      (should (string-search "build.sh --container fedora-44 --memory 5g --jobs 2 --prefix " log)))))

(ert-deftest drgnx-install/the-pin-is-the-published-series-head ()
  (drgnx-install-test--expect (drgnx-install-test--plan "fedora-44" "--method" "nidhogg")
                              "at v31.1-nidhogg.1" "commit 29f76866bd1d"))

;;; Ratatoskr: the Rust toolchain and the build (Task 19)
;; A PATH of its own (symlinks to the basic tools plus stubs) keeps this machine's cargo, dnf and apt out of the plan.
;; The other tests run with DRGNX_INSTALL_RUNTIME=none (no Ratatoskr step); these name it empty.

(defconst drgnx-install-test--basic-tools
  '("sed" "awk" "sort" "head" "tail" "cat" "getconf" "uname" "grep" "dirname" "basename" "tr" "cut" "ls" "rm" "mkdir" "mv"
    "ln" "mktemp" "id" "date" "env" "chmod" "cp" "tee" "git" "sleep" "wc" "xargs" "sha256sum")
  "What install.sh needs on PATH for a plan or a keep run.")

(defun drgnx-install-test--rust-path (tmp stubs)
  "PATH=… of TMP/rbin: the basic tools and STUBS, an alist (NAME . SHELL-BODY)."
  (let ((bin (expand-file-name "rbin" tmp)))
    (when (file-exists-p bin) (delete-directory bin t))   ; the stubs of an earlier case in this test
    (make-directory bin t)
    (dolist (tool drgnx-install-test--basic-tools)
      (when-let* ((p (executable-find tool))) (make-symbolic-link p(expand-file-name tool bin) t)))
    (pcase-dolist (`(,name . ,body) stubs)
      (drgnx-install-test--script (expand-file-name name bin) (concat "#!/bin/sh\n" body "\n")))
    (concat "PATH=" bin)))

(defconst drgnx-install-test--rustc '("rustc" . "echo 'rustc 1.99.0 (abc 2026-01-01)'"))
(defconst drgnx-install-test--cargo '("cargo" . "echo cargo"))
(defconst drgnx-install-test--cc '("cc" . "exit 0"))
(defconst drgnx-install-test--dnf '("dnf" . "[ \"$1\" = repoquery ] && echo \"$RUST_CAND\"; exit 0"))
(defconst drgnx-install-test--apt-cache
  '("apt-cache" . "case \"$1\" in policy) printf 'rustc:\\n  Installed: (none)\\n  Candidate: %s\\n' \"$RUST_CAND\" ;; search) printf '%s\\n' \"$APT_SEARCH\" ;; esac"))

(defun drgnx-install-test--rust-plan (os tmp stubs &rest env)
  (apply #'drgnx-install-test--plan os "DRGNX_INSTALL_RUNTIME=" (drgnx-install-test--rust-path tmp stubs) env))

(ert-deftest drgnx-install/plan-names-the-rust-toolchain-path ()
  (drgnx-install-test--with-tmp tmp
    ;; 1. cargo and rustc >= 1.88 on PATH
    (let ((out (cdr (drgnx-install-test--rust-plan "fedora-45" tmp (list drgnx-install-test--cargo drgnx-install-test--rustc
                                                                         drgnx-install-test--cc drgnx-install-test--dnf)
                                                   "RUST_CAND=1.99.0"))))
      (should (string-search "Rust toolchain: cargo and rustc 1.99.0 on PATH" out))
      (should (string-search "C compiler: cc" out))
      (should-not (string-search "dnf install -y cargo" out))
      (should (string-search "/cargo (the update timer finds the same cargo)" out)))
    ;; 2. the distro's default package, when its candidate is >= 1.88
    (let ((out (cdr (drgnx-install-test--rust-plan "fedora-45" tmp (list drgnx-install-test--dnf) "RUST_CAND=1.99.0"))))
      (should (string-search "Rust toolchain: sudo dnf install -y cargo rust gcc (the distro's rust 1.99.0)" out)))
    (let ((out (cdr (drgnx-install-test--rust-plan "ubuntu-26.04" tmp (list drgnx-install-test--apt-cache) "RUST_CAND=1.93.1+dfsg1-0ubuntu1"))))
      (should (string-search "Rust toolchain: sudo apt-get install -y cargo rustc gcc (the distro's rust 1.93.1)" out)))
    ;; 3. a versioned package where the default is too old (Ubuntu 24.04: 1.75 and rustc-1.91); the newest >= 1.88 is taken
    (let ((out (cdr (drgnx-install-test--rust-plan
                     "ubuntu-26.04" tmp (list drgnx-install-test--apt-cache) "RUST_CAND=1.75.0+dfsg0ubuntu1"
                     (concat "APT_SEARCH=rustc-1.91 - Rust\ncargo-1.91 - Cargo\nrustc-1.85 - Rust\ncargo-1.85 - Cargo\n"
                             "rustc-1.89 - Rust\nrustc-1.75 - Rust\ncargo-1.75 - Cargo\n")))))
      (should (string-search "Rust toolchain: sudo apt-get install -y rustc-1.91 cargo-1.91 gcc" out))
      (should (string-search "/usr/lib/rust-1.91/bin" out))
      (should-not (string-search "1.75" out)))
    ;; 4. Debian trixie (1.85) and no versioned package: a private rustup, from the versioned archive
    (let ((out (cdr (drgnx-install-test--rust-plan "debian-13" tmp (list drgnx-install-test--apt-cache) "RUST_CAND=1.85.0+dfsg1-1"
                                                   ;; no Nidhogg recipe for Debian 13: a Nidhogg already installed is kept
                                                   (concat "DRGNX_INSTALL_EMACS=" (drgnx-install-test--fake-emacs tmp "31.1 t pgtk 31.1-nidhogg.1"))
                                                   "APT_SEARCH=rustc-1.85 - Rust\ncargo-1.85 - Cargo\n"))))
      (should (string-search "Rust toolchain: a private rustup 1.28.2" out))
      (should (string-search "/rustup with Rust 1.93.1" out))
      (should (string-search "https://static.rust-lang.org/rustup/archive/1.28.2/x86_64-unknown-linux-gnu/rustup-init" out))
      (should (string-search "sha256" out)))))

(ert-deftest drgnx-install/a-too-old-default-package-is-not-offered ()
  (drgnx-install-test--with-tmp tmp
    (let ((out (cdr (drgnx-install-test--rust-plan "fedora-45" tmp (list drgnx-install-test--dnf) "RUST_CAND=1.75.0"))))
      (should-not (string-search "dnf install -y cargo" out))
      (should-not (string-search "1.75" out))
      (should (string-search "a private rustup" out)))))

(ert-deftest drgnx-install/no-cc-names-its-package ()
  (drgnx-install-test--with-tmp tmp
    (let ((stubs (list drgnx-install-test--cargo drgnx-install-test--rustc)))
      (should (string-search "C compiler: sudo dnf install -y gcc"
                             (cdr (drgnx-install-test--rust-plan "fedora-45" tmp stubs))))
      (should (string-search "C compiler: sudo apt-get install -y gcc"
                             (cdr (drgnx-install-test--rust-plan "ubuntu-26.04" tmp stubs))))
      (should (string-search "C compiler: sudo pacman -S --needed --noconfirm gcc"
                             (cdr (drgnx-install-test--rust-plan   ; no recipe for Arch: an installed Nidhogg is kept
                                   "arch" tmp stubs
                                   (concat "DRGNX_INSTALL_EMACS=" (drgnx-install-test--fake-emacs tmp "31.1 t pgtk 31.1-nidhogg.1"))))))
      (should (string-search "C compiler: xcode-select --install"
                             (cdr (apply #'drgnx-install-test--run
                                         (append (list "DRGNX_INSTALL_RUNTIME=" (drgnx-install-test--rust-path tmp stubs)
                                                       "DRGNX_INSTALL_BREW=none")
                                                 drgnx-install-test--macos)
                                         '("--dry-run")))))
      ;; the packages of a distro install bring gcc themselves
      (should-not (string-search "C compiler: sudo"
                                 (cdr (drgnx-install-test--rust-plan "fedora-45" tmp (list drgnx-install-test--dnf) "RUST_CAND=1.99.0")))))))

(defun drgnx-install-test--keep-run (tmp stubs &rest env)
  "A real `--yes --method keep' run in TMP with a stub checkout (bin/drgnx logs to TMP/drgnx.log; RT_FAIL=1 fails
`runtime build') and a fake Emacs, on Fedora 45, with the Ratatoskr step on.  Return (EXIT . OUTPUT)."
  (let* ((checkout (expand-file-name "drgnx" tmp)) (home (expand-file-name "home" tmp)))
    (make-directory (expand-file-name "bin" checkout) t)
    (make-directory home t)
    (drgnx-install-test--script
     (expand-file-name "bin/drgnx" checkout)
     (concat "#!/bin/sh\necho \"drgnx $*\" >> \"$DRGNX_LOG\"\n"
             "[ \"$1 $2\" = 'runtime build' ] && [ -n \"$RT_FAIL\" ] && exit 1\nexit 0\n"))
    (apply #'drgnx-install-test--run
           (append env
                   (list "DRGNX_INSTALL_RUNTIME=" (drgnx-install-test--rust-path tmp stubs)
                         (concat "DRGNX_LOG=" tmp "/drgnx.log") (concat "HOME=" home)
                         (concat "DRGNX_DATA_DIR=" home "/.local/share/drgnx") (concat "DRGNX_CONFIG_DIR=" home "/.config/drgnx")
                         (concat "XDG_CACHE_HOME=" tmp "/cache") (concat "XDG_STATE_HOME=" tmp "/state")
                         (concat "DRGNX_INSTALL_EMACS=" (drgnx-install-test--fake-emacs tmp "31.1 t pgtk"))
                         (concat "DRGNX_INSTALL_OS_RELEASE=" (drgnx-install-test--os "fedora-45")) "DRGNX_INSTALL_UNAME=Linux"
                         "DRGNX_INSTALL_ARCH=x86_64"))
           "--yes" "--method" "keep" "--prefix" (expand-file-name "prefix" tmp) (list "--source-dir" checkout))))

(ert-deftest drgnx-install/the-toolchain-is-recorded ()
  (drgnx-install-test--with-tmp tmp
    (let* ((r (drgnx-install-test--keep-run tmp (list drgnx-install-test--cargo drgnx-install-test--rustc drgnx-install-test--cc)))
           (record (drgnx-install-test--file (expand-file-name "home/.local/share/drgnx/cargo" tmp)))
           (log (drgnx-install-test--file (expand-file-name "drgnx.log" tmp))))
      (should (= (car r) 0))
      ;; line 1: the absolute path of the cargo that was found; a distro or PATH cargo adds no other lines
      (should (equal record (concat tmp "/rbin/cargo\n")))
      ;; the build, then the install into the prefix, both after drgnx build
      (should (< (string-search "drgnx build" log) (string-search "drgnx runtime build" log)))
      (should (< (string-search "drgnx runtime build" log)
                 (string-search (concat "drgnx runtime install --prefix " tmp "/prefix") log))))))

(ert-deftest drgnx-install/a-failed-runtime-build-warns-and-goes-on ()
  (drgnx-install-test--with-tmp tmp
    (let* ((r (drgnx-install-test--keep-run tmp (list drgnx-install-test--cargo drgnx-install-test--rustc drgnx-install-test--cc)
                                            "RT_FAIL=1"))
           (log (drgnx-install-test--file (expand-file-name "drgnx.log" tmp))))
      (should (= (car r) 0))
      (should (string-search "the Ratatoskr build failed" (cdr r)))
      (should (string-search (concat tmp "/state/drgnx/runtime-build.log") (cdr r)))   ; the log path
      (should (string-search "drgnx runtime build" (cdr r)))                           ; the fix
      (should (string-search "Ratatoskr is not built" (cdr r)))
      (should-not (string-search "runtime install" log))
      (should (string-search "drgnx doctor" log))                                       ; drgnx still runs
      (should (file-exists-p (expand-file-name "home/.local/share/drgnx/cargo" tmp))))))
