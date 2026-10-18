;;; install-test.el --- batch tests: install.sh plans (dry runs) -*- lexical-binding: t -*-
;; The installer is bash (it must run before any Emacs exists); these tests call it with
;; detection overridden through DRGNX_INSTALL_* and check the plan it prints.
(require 'ert)

(defconst drgnx-install-test--root
  (expand-file-name "../../" (file-name-directory (or load-file-name buffer-file-name))))

(defun drgnx-install-test--os (name)
  (expand-file-name (concat "test/fixtures/os-release/" name) drgnx-install-test--root))

(defvar drgnx-install-test--stdin nil
  "A file that install.sh reads as its standard input (nil: /dev/null).  `curl … | bash' hands it a pipe.")

(defun drgnx-install-test--run (env &rest args)
  "Run install.sh ARGS with ENV (\"K=V\" strings), without a terminal (DRGNX_INSTALL_TTY=none); return
\(EXIT . OUTPUT).  HOME is a new empty directory, deleted afterwards (ENV may name another)."
  (let* ((home (make-temp-file "drgnx-install-home" t))
         (process-environment (append env (list "DRGNX_INSTALL_EMACS=none" "DRGNX_INSTALL_TTY=none"
                                                "DRGNX_INSTALL_MACOS_APP=none"   ; never this Mac's /Applications/Emacs.app
                                                (concat "HOME=" home)
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
  (drgnx-install-test--run (append (list (concat "DRGNX_INSTALL_OS_RELEASE=" (drgnx-install-test--os os))
                                         "DRGNX_INSTALL_UNAME=Linux" "DRGNX_INSTALL_ARCH=x86_64")
                                   env)
                           "--dry-run"))

(defmacro drgnx-install-test--expect (result &rest substrings)
  `(let ((r ,result))
     (should (= (car r) 0))
     (dolist (s (list ,@substrings))
       (should (string-search s (cdr r))))))

(ert-deftest drgnx-install/syntax ()
  (should (= 0 (call-process "bash" nil nil nil "-n" (expand-file-name "install.sh" drgnx-install-test--root)))))

(ert-deftest drgnx-install/script-runs-only-from-main ()
  ;; A truncated download must run nothing: everything is a function, `main' is called on the last line.
  (with-temp-buffer
    (insert-file-contents (expand-file-name "install.sh" drgnx-install-test--root))
    (goto-char (point-max))
    (skip-chars-backward " \n")
    (should (string= (buffer-substring (line-beginning-position) (point)) "main \"$@\""))))

(ert-deftest drgnx-install/fedora-44-builds-from-source ()
  (drgnx-install-test--expect (drgnx-install-test--plan "fedora-44" "DRGNX_INSTALL_SESSION=wayland")
                              "Fedora Linux 44" "build GNU Emacs 31.1 from source" "dnf builddep -y emacs"
                              "--with-native-compilation=aot" "--with-pgtk" "gnu-keyring.gpg"))

(ert-deftest drgnx-install/fedora-45-uses-the-package ()
  (drgnx-install-test--expect (drgnx-install-test--plan "fedora-45" "DRGNX_INSTALL_SESSION=wayland")
                              "dnf install -y emacs-pgtk")
  (drgnx-install-test--expect (drgnx-install-test--plan "fedora-45" "DRGNX_INSTALL_SESSION=x11")
                              "dnf install -y emacs-gtk+x11"))

(ert-deftest drgnx-install/arch-family-uses-the-package ()
  (drgnx-install-test--expect (drgnx-install-test--plan "arch" "DRGNX_INSTALL_SESSION=wayland")
                              "pacman -Syu --needed --noconfirm emacs-wayland")
  (drgnx-install-test--expect (drgnx-install-test--plan "endeavouros" "DRGNX_INSTALL_SESSION=x11")
                              "pacman -Syu --needed --noconfirm emacs"))

(ert-deftest drgnx-install/debian-family-builds-from-source ()
  (dolist (os '("debian-13" "ubuntu-26.04" "linuxmint"))
    (drgnx-install-test--expect (drgnx-install-test--plan os "DRGNX_INSTALL_SESSION=x11")
                                "build GNU Emacs 31.1 from source" "apt-get build-dep -y emacs"
                                ;; Ubuntu 26.04 builds its emacs with gcc-14 but defaults to gcc 15:
                                ;; build-dep alone leaves the default gcc without libgccjit.
                                "libgccjit for the default gcc"
                                "--with-x-toolkit=gtk3")))

(ert-deftest drgnx-install/macos ()
  (drgnx-install-test--expect
   (drgnx-install-test--run '("DRGNX_INSTALL_UNAME=Darwin" "DRGNX_INSTALL_ARCH=arm64" "DRGNX_INSTALL_MACOS=15.4") "--dry-run")
   "brew install --cask emacs-plus-app" "brew trust d12frosted/emacs-plus")
  (drgnx-install-test--expect
   (drgnx-install-test--run '("DRGNX_INSTALL_UNAME=Darwin" "DRGNX_INSTALL_ARCH=x86_64" "DRGNX_INSTALL_MACOS=14.6") "--dry-run")
   "brew install emacs-plus@31"))

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
    (should (< (string-search "Install Homebrew" out) (string-search "brew install --cask emacs-plus-app" out))))
  (let ((r (drgnx-install-test--run (cons "DRGNX_INSTALL_BREW=none" drgnx-install-test--macos))))
    (should (= (car r) 3))
    (should (string-search "--yes" (cdr r)))))

(ert-deftest drgnx-install/macos-with-homebrew-does-not-offer-it ()
  (let ((out (cdr (drgnx-install-test--run (cons "DRGNX_INSTALL_BREW=/opt/homebrew/bin/brew" drgnx-install-test--macos)
                                           "--dry-run"))))
    (should (string-search "/opt/homebrew/bin/brew install --cask emacs-plus-app" out))
    (should-not (string-search "Install Homebrew" out))
    (should-not (string-search "Rosetta" out))))

(ert-deftest drgnx-install/macos-with-intel-homebrew-on-apple-silicon ()
  ;; Homebrew for Intel in /usr/local on an arm64 Mac runs under Rosetta: used, but the plan says so.
  (let ((r (drgnx-install-test--run (cons "DRGNX_INSTALL_BREW=/usr/local/bin/brew" drgnx-install-test--macos)
                                    "--dry-run")))
    (should (= (car r) 0))
    (should (string-search "/usr/local/bin/brew install --cask emacs-plus-app" (cdr r)))
    (should (string-search "Rosetta" (cdr r)))
    (should-not (string-search "Install Homebrew" (cdr r)))))

(ert-deftest drgnx-install/macos-keeps-an-emacs-app-that-is-good-enough ()
  (let ((tmp (make-temp-file "drgnx-install" t)))
    (unwind-protect
        (let ((r (drgnx-install-test--run
                  (append (list (concat "DRGNX_INSTALL_EMACS=" (drgnx-install-test--fake-emacs tmp "31.1 t ns"))
                                "DRGNX_INSTALL_BREW=none")
                          drgnx-install-test--macos)
                  "--dry-run")))
          (should (= (car r) 0))
          (should (string-search "keep the installed Emacs 31.1" (cdr r)))
          (should-not (string-search "brew install" (cdr r)))
          (should-not (string-search "Install Homebrew" (cdr r))))
      (delete-directory tmp t))))

(ert-deftest drgnx-install/macos-probes-emacs-app-in-applications ()
  ;; Emacs.app is not on PATH: /Applications/Emacs.app/Contents/MacOS/Emacs is probed too (DRGNX_INSTALL_MACOS_APP
  ;; stands for it). Good enough: kept and remembered. Older: the cask would install over it — stopped before
  ;; Homebrew, with the two ways on; --method formula (emacs-plus@31, beside it) goes on.
  (let ((tmp (make-temp-file "drgnx-install" t)))
    (unwind-protect
        (let* ((good (let ((d (expand-file-name "good" tmp))) (make-directory d) (drgnx-install-test--fake-emacs d "31.1 t ns")))
               (old (let ((d (expand-file-name "old" tmp))) (make-directory d) (drgnx-install-test--fake-emacs d "30.2 t ns")))
               (run (lambda (app &rest args)
                      (apply #'drgnx-install-test--run
                             (append (list (concat "DRGNX_INSTALL_MACOS_APP=" app) "DRGNX_INSTALL_BREW=none") drgnx-install-test--macos)
                             "--dry-run" args))))
          (let ((r (funcall run good)))
            (should (= (car r) 0))
            (should (string-search (concat "keep the installed Emacs 31.1 (" good ")") (cdr r)))
            (should (string-search (concat "Remember Emacs: " good) (cdr r)))
            (should-not (string-search "brew install" (cdr r)))
            (should-not (string-search "Install Homebrew" (cdr r))))
          (let ((r (funcall run old)))
            (should (= (car r) 2))
            (should (string-search "an older Emacs.app is in /Applications (Emacs 30.2): move it aside, or run with --method formula" (cdr r)))
            (should-not (string-search "1. Emacs" (cdr r)))
            (should-not (string-search "Homebrew" (cdr r))))
          (let ((r (funcall run old "--method" "formula")))
            (should (= (car r) 0))
            (should (string-search "install emacs-plus@31" (cdr r)))
            (should-not (string-search "--cask emacs-plus-app" (cdr r))))
          ;; none there: as before
          (let ((r (funcall run (expand-file-name "missing/Emacs" tmp))))
            (should (= (car r) 0))
            (should (string-search "install --cask emacs-plus-app" (cdr r))))
          ;; DRGNX_INSTALL_EMACS still comes first
          (let ((r (drgnx-install-test--run (append (list (concat "DRGNX_INSTALL_EMACS=" good) (concat "DRGNX_INSTALL_MACOS_APP=" old)
                                                          "DRGNX_INSTALL_BREW=none")
                                                    drgnx-install-test--macos)
                                            "--dry-run")))
            (should (= (car r) 0))
            (should (string-search (concat "keep the installed Emacs 31.1 (" good ")") (cdr r))))
          ;; formula is a macOS method
          (let ((r (drgnx-install-test--run (list (concat "DRGNX_INSTALL_OS_RELEASE=" (drgnx-install-test--os "fedora-45"))
                                                  "DRGNX_INSTALL_UNAME=Linux")
                                            "--dry-run" "--method" "formula")))
            (should (= (car r) 2))
            (should (string-search "--method formula is for macOS" (cdr r)))))
      (delete-directory tmp t))))

(ert-deftest drgnx-install/homebrew-installer-runs-noninteractive-and-its-failure-stops-the-run ()
  ;; A fake curl hands out a Homebrew "installer" that reports its environment and fails; nothing after it
  ;; (tap, install) runs.  A download that fails is its own message.
  ;; The installer also tries to read: run as `curl … | bash' its stdin is the script's pipe, so --yes must
  ;; hand it /dev/null (M12a-2); the test gives install.sh a stdin that has input to take.
  (let* ((tmp (make-temp-file "drgnx-install" t)) (bin (expand-file-name "bin" tmp))
         (drgnx-install-test--stdin (expand-file-name "stdin" tmp)))
    (unwind-protect
        (progn
          (make-directory bin)
          (write-region "PIPED-SCRIPT-TEXT\n" nil drgnx-install-test--stdin)
          (dolist (curl '("echo 'echo HB-INSTALLER NONINTERACTIVE=$NONINTERACTIVE; exit 1'"
                          "exit 22"))
            (write-region (format "#!/bin/sh\n%s\n" curl) nil (expand-file-name "curl" bin))
            (set-file-modes (expand-file-name "curl" bin) #o755)
            (let ((r (drgnx-install-test--run
                      (append (list "DRGNX_INSTALL_BREW=none" (concat "PATH=" bin ":" (getenv "PATH")))
                              drgnx-install-test--macos)
                      "--yes" "--source-dir" drgnx-install-test--root "--prefix" (expand-file-name "prefix" tmp))))
              (should (= (car r) 1))
              ;; the plan names brew; once Homebrew's installer failed, no brew command ran
              (should-not (string-search "Tapped" (cdr r)))
              (should-not (string-search "emacs-plus" (substring (cdr r) (string-search "Emacs comes from Homebrew" (cdr r)))))
              (if (string-search "exit 1" curl)
                  (progn (should (string-search "HB-INSTALLER NONINTERACTIVE=1" (cdr r)))
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
  ;; is evaluated, the profile line is offered (--yes only prints it) and tap and install run through it.
  (let ((tmp (make-temp-file "drgnx-install" t)))
    (unwind-protect
        (let ((r (drgnx-install-test--run
                  (append (drgnx-install-test--fake-homebrew tmp) (list "SHELL=/bin/zsh") drgnx-install-test--macos)
                  "--yes" "--source-dir" drgnx-install-test--root "--prefix" (expand-file-name "prefix" tmp))))
          (should (= (car r) 0))
          (should (string-search "FAKE-HB-INSTALLED" (cdr r)))
          (should (string-search "Homebrew must be on your PATH in new terminals." (cdr r)))
          (should (string-match-p (concat "add this to [^ ]*/\\.zprofile: eval \"\\$(" (regexp-quote tmp) "/hb/brew shellenv)\"")
                                  (cdr r)))
          (should (string-search "FAKE-BREW tap d12frosted/emacs-plus" (cdr r)))
          (should (string-search "FAKE-BREW install --cask emacs-plus-app" (cdr r)))
          (should-not (string-search "Homebrew was installed but brew was not found" (cdr r))))
      (delete-directory tmp t))))

(ert-deftest drgnx-install/no-bash-4-constructs ()
  ;; macOS ships bash 3.2: it must run there.
  (let ((code (with-temp-buffer
                (insert-file-contents (expand-file-name "install.sh" drgnx-install-test--root))
                (goto-char (point-min))
                (while (re-search-forward "^[ \t]*#.*$\\|[ \t]#[ \t].*$" nil t) (replace-match ""))
                (buffer-string))))
    (dolist (re '("\\bmapfile\\b" "\\breadarray\\b" "declare -A" "local -n" "\\${[a-zA-Z_]*,,}" "\\${[a-zA-Z_]*\\^\\^}"
                  ";&" "|&" "\\[-[0-9]+\\]"))
      (should-not (string-match-p re code)))))

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
                                   (concat "DRGNX_INSTALL_EMACS=" (drgnx-install-test--fake-emacs tmp "31.1 t ns")))
                             drgnx-install-test--macos)))
            (let ((plan (drgnx-install-test--run env "--dry-run")))
              (should (= (car plan) 0))
              (should-not (string-search ".emacs.d" (cdr plan)))
              (should-not (string-search ".config/emacs" (cdr plan))))
            (let ((run (drgnx-install-test--run env "--yes" "--prefix" (expand-file-name "prefix" tmp)
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
            ;; the real run remembers the Emacs it kept, in drgnx's own config directory
            (should (equal (with-temp-buffer (insert-file-contents (expand-file-name ".config/drgnx/emacs" home))
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
                  "--yes" "--prefix" (expand-file-name "prefix" tmp) "--source-dir" drgnx-install-test--root)))
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
                 "--yes" "--prefix" (expand-file-name "prefix" tmp) "--source-dir" drgnx-install-test--root)))
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

(ert-deftest drgnx-install/unknown-distribution-gets-the-guide ()
  (let ((r (drgnx-install-test--plan "unknown")))
    (should (= (car r) 2))
    (should (string-search "Plan 9 from Bell Labs" (cdr r)))
    (should (string-search "docs/guide/install.md" (cdr r)))))

(ert-deftest drgnx-install/a-good-emacs-is-kept ()
  (let ((fake (make-temp-file "fake-emacs")))
    (unwind-protect
        (progn
          (write-region "#!/bin/sh\necho '31.1 t pgtk'\n" nil fake)
          (set-file-modes fake #o755)
          (drgnx-install-test--expect
           (drgnx-install-test--plan "fedora-44" (concat "DRGNX_INSTALL_EMACS=" fake))
           "keep the installed Emacs 31.1"))
      (delete-file fake))))

(ert-deftest drgnx-install/the-plan-remembers-the-emacs ()
  (drgnx-install-test--expect
   (drgnx-install-test--run (append '("DRGNX_INSTALL_UNAME=Darwin" "DRGNX_INSTALL_ARCH=arm64" "DRGNX_INSTALL_MACOS=15.4"
                                      "DRGNX_INSTALL_BREW=none")
                                    nil)
                            "--dry-run")
   "Remember Emacs: /Applications/Emacs.app/Contents/MacOS/Emacs")
  (let ((tmp (make-temp-file "drgnx-install" t)))
    (unwind-protect
        (let ((fake (drgnx-install-test--fake-emacs tmp "31.1 t ns")))
          (drgnx-install-test--expect
           (drgnx-install-test--run
            (append (list (concat "DRGNX_INSTALL_EMACS=" fake) "DRGNX_INSTALL_BREW=none") drgnx-install-test--macos)
            "--dry-run")
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

(ert-deftest drgnx-install/a-method-without-a-recipe-is-refused ()
  ;; M2.5-2: --method package/source where there is no such recipe — refused before the plan (exit 2),
  ;; never an empty "sudo" line (bash 5) or "unbound variable" (bash 3.2).
  (let ((macos '("DRGNX_INSTALL_UNAME=Darwin" "DRGNX_INSTALL_ARCH=arm64" "DRGNX_INSTALL_MACOS=15.4")))
    (dolist (r (list (apply #'drgnx-install-test--run macos '("--dry-run" "--method" "package"))
                     (apply #'drgnx-install-test--run macos '("--dry-run" "--method" "source"))
                     (drgnx-install-test--run (list (concat "DRGNX_INSTALL_OS_RELEASE=" (drgnx-install-test--os "arch"))
                                                    "DRGNX_INSTALL_UNAME=Linux")
                                              "--dry-run" "--method" "source")
                     (drgnx-install-test--run (list (concat "DRGNX_INSTALL_OS_RELEASE=" (drgnx-install-test--os "unknown"))
                                                    "DRGNX_INSTALL_UNAME=Linux")
                                              "--dry-run" "--method" "package")))
      (should (= (car r) 2))
      (should (string-match-p "no --method \\(package\\|source\\) recipe for" (cdr r)))
      (should-not (string-search "1. Emacs" (cdr r))))))

(ert-deftest drgnx-install/image-based-fedora-gets-toolbox-or-layering ()
  ;; M2.5-11: Silverblue, Kinoite, Bazzite (/run/ostree-booted): dnf cannot install there — refused before
  ;; the plan with the two ways that work; an Emacs that is already good is kept.
  (let ((booted (make-temp-file "ostree-booted")) (fake (make-temp-file "fake-emacs")))
    (unwind-protect
        (progn
          (dolist (os '("fedora-45" "fedora-44"))
            (let ((r (drgnx-install-test--plan os (concat "DRGNX_INSTALL_OSTREE_BOOTED=" booted))))
              (should (= (car r) 2))
              (should (string-search "toolbox" (cdr r)))
              (should (string-search "rpm-ostree install emacs-pgtk" (cdr r)))
              (should (string-search "--method keep" (cdr r)))
              (should-not (string-search "dnf install" (cdr r)))))
          (write-region "#!/bin/sh\necho '31.1 t pgtk'\n" nil fake)
          (set-file-modes fake #o755)
          (drgnx-install-test--expect (drgnx-install-test--plan "fedora-45" (concat "DRGNX_INSTALL_OSTREE_BOOTED=" booted)
                                                                (concat "DRGNX_INSTALL_EMACS=" fake))
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

(ert-deftest drgnx-install/bad-signature-installs-nothing ()
  (skip-unless (/= 0 (user-uid)))     ; as root, as_root runs commands without sudo: they would really run
  ;; The tarball is verified before anything is installed (build dependencies included).  A fake
  ;; sudo on PATH: a regression must fail here, never escalate on the developer's machine.
  (let* ((tmp (make-temp-file "drgnx-install" t))
         (mirror (expand-file-name "mirror" tmp))
         (bin (expand-file-name "bin" tmp))
         (prefix (expand-file-name "prefix" tmp)))
    (unwind-protect
        (progn
          (make-directory mirror)
          (make-directory bin)
          (dolist (f '("emacs-31.1.tar.xz" "emacs-31.1.tar.xz.sig" "keyring")) ; not *.gpg: EasyPG would encrypt it
            (write-region "not what it claims to be\n" nil (expand-file-name f mirror)))
          (write-region "#!/bin/sh\necho \"FAKE-SUDO $*\"\nexit 1\n" nil (expand-file-name "sudo" bin))
          (set-file-modes (expand-file-name "sudo" bin) #o755)
          (let ((r (drgnx-install-test--run
                    (list (concat "DRGNX_INSTALL_OS_RELEASE=" (drgnx-install-test--os "fedora-44"))
                          "DRGNX_INSTALL_UNAME=Linux"
                          (concat "DRGNX_INSTALL_MIRROR=file://" mirror)
                          (concat "DRGNX_INSTALL_KEYRING=file://" mirror "/keyring")
                          (concat "XDG_CACHE_HOME=" tmp "/cache")
                          (concat "PATH=" bin ":" (getenv "PATH")))
                    "--yes" "--method" "source" "--prefix" prefix "--source-dir" drgnx-install-test--root)))
            (should (= (car r) 1))
            (should (string-search "does not verify" (cdr r)))
            (should-not (string-search "As root:" (cdr r)))     ; no dependency step ran
            (should-not (string-search "FAKE-SUDO" (cdr r)))
            (should-not (file-exists-p (expand-file-name "bin/emacs" prefix)))))
      (delete-directory tmp t))))

(ert-deftest drgnx-install/a-failed-download-installs-nothing ()
  ;; M2.5-4: a mirror without the tarball (not synced yet, no network) — a clear message, exit 1, nothing
  ;; installed, no half file kept.
  (skip-unless (/= 0 (user-uid)))     ; as root, as_root runs commands without sudo: they would really run
  (let* ((tmp (make-temp-file "drgnx-install" t))
         (mirror (expand-file-name "mirror" tmp))
         (bin (expand-file-name "bin" tmp))
         (prefix (expand-file-name "prefix" tmp)))
    (unwind-protect
        (progn
          (make-directory mirror)
          (make-directory bin)
          (write-region "#!/bin/sh\necho \"FAKE-SUDO $*\"\nexit 1\n" nil (expand-file-name "sudo" bin))
          (set-file-modes (expand-file-name "sudo" bin) #o755)
          (let ((r (drgnx-install-test--run
                    (list (concat "DRGNX_INSTALL_OS_RELEASE=" (drgnx-install-test--os "fedora-44"))
                          "DRGNX_INSTALL_UNAME=Linux"
                          (concat "DRGNX_INSTALL_MIRROR=file://" mirror)
                          (concat "DRGNX_INSTALL_KEYRING=file://" mirror "/keyring")
                          (concat "XDG_CACHE_HOME=" tmp "/cache")
                          (concat "PATH=" bin ":" (getenv "PATH")))
                    "--yes" "--method" "source" "--prefix" prefix "--source-dir" drgnx-install-test--root)))
            (should (= (car r) 1))
            (should (string-search (concat "could not download file://" mirror "/emacs-31.1.tar.xz") (cdr r)))
            (should (string-search "nothing was installed" (cdr r)))
            (should-not (string-search "As root:" (cdr r)))
            (should-not (string-search "FAKE-SUDO" (cdr r)))
            (should-not (directory-files (expand-file-name "cache/drgnx/build" tmp) nil "\\.tar\\.xz"))
            (should-not (file-exists-p (expand-file-name "bin/emacs" prefix)))))
      (delete-directory tmp t))))

(ert-deftest drgnx-install/the-path-hint-names-the-shell-startup-file ()
  ;; M2.5-3: zsh (macOS's default) never reads ~/.profile.  A run with --yes keeps a good (fake) Emacs,
  ;; links drgnx into a temp prefix that is not on PATH, and prints the hint.
  (let* ((tmp (make-temp-file "drgnx-install" t))
         (fake (expand-file-name "emacs" tmp)))
    (unwind-protect
        (progn
          (write-region "#!/bin/sh\necho '31.1 t pgtk'\n" nil fake)
          (set-file-modes fake #o755)
          (pcase-dolist (`(,shell ,file) '(("/bin/zsh" "/.zprofile") ("/bin/bash" "/.profile")))
            (let ((r (drgnx-install-test--run
                      (list (concat "DRGNX_INSTALL_OS_RELEASE=" (drgnx-install-test--os "fedora-45"))
                            "DRGNX_INSTALL_UNAME=Linux" (concat "DRGNX_INSTALL_EMACS=" fake) (concat "SHELL=" shell))
                      "--yes" "--prefix" (expand-file-name "prefix" tmp) "--source-dir" drgnx-install-test--root)))
              (should (= (car r) 0))
              (should (string-match-p (concat "add this to [^ ]*" (regexp-quote file) ": export PATH=") (cdr r))))))
      (delete-directory tmp t))))

(ert-deftest drgnx-install/root-steps-are-announced-even-with-yes ()
  (skip-unless (/= 0 (user-uid)))     ; as root, as_root runs commands without sudo: they would really run
  (let* ((tmp (make-temp-file "drgnx-install" t))
         (bin (expand-file-name "bin" tmp)))
    (unwind-protect
        (progn
          (make-directory bin)
          (write-region "#!/bin/sh\necho \"FAKE-SUDO $*\"\nexit 1\n" nil (expand-file-name "sudo" bin))
          (set-file-modes (expand-file-name "sudo" bin) #o755)
          (let ((r (drgnx-install-test--run
                    (list (concat "DRGNX_INSTALL_OS_RELEASE=" (drgnx-install-test--os "fedora-45"))
                          "DRGNX_INSTALL_UNAME=Linux" "DRGNX_INSTALL_SESSION=wayland"
                          (concat "PATH=" bin ":" (getenv "PATH")))
                    "--yes" "--source-dir" drgnx-install-test--root)))
            (should (= (car r) 1))
            (should (string-search "As root: dnf install -y emacs-pgtk" (cdr r)))
            (should (string-search "FAKE-SUDO dnf install -y emacs-pgtk" (cdr r)))))
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
                    "--yes" "--dir" (expand-file-name "checkout" tmp))))
            (should (= (car r) 1))
            (should (string-search "As root: dnf install -y git" (cdr r)))))
      (delete-directory tmp t))))

(ert-deftest drgnx-install/fedora-family-is-fedora-itself ()
  ;; RHEL clones and Amazon Linux carry `fedora' in ID_LIKE but have no Fedora packages: the guide.
  ;; Fedora remixes (Nobara) have a Fedora PLATFORM_ID.
  (dolist (os '("rocky-9" "amazon-2023"))
    (let ((r (drgnx-install-test--plan os)))
      (should (= (car r) 2))
      (should (string-search "docs/guide/install.md" (cdr r)))))
  (drgnx-install-test--expect (drgnx-install-test--plan "nobara-42") "build GNU Emacs 31.1 from source" "dnf builddep -y emacs"))

(ert-deftest drgnx-install/relative-paths-become-absolute ()
  ;; `--source-dir .' from a clone: the drgnx link must not dangle.
  (let ((r (drgnx-install-test--run (list (concat "DRGNX_INSTALL_OS_RELEASE=" (drgnx-install-test--os "fedora-45"))
                                          "DRGNX_INSTALL_UNAME=Linux")
                                    "--dry-run" "--source-dir" "." "--prefix" "rel-prefix")))
    (should (= (car r) 0))
    (should (string-search (concat "→ " (directory-file-name drgnx-install-test--root)) (cdr r)))
    (should (string-search (concat "Link " (directory-file-name drgnx-install-test--root)) (cdr r)))))

(defun drgnx-install-test--signed-mirror (tmp)
  "TMP/mirror: an emacs-31.1.tar.xz signed by a throwaway key, its .sig and the key as keyring.  Returns
the key's fingerprint."
  (let ((gnupg (expand-file-name "g" tmp)) (mirror (expand-file-name "mirror" tmp))
        (sh (lambda (&rest args) (should (= 0 (apply #'call-process "sh" nil nil nil "-c" args))))))
    (dolist (d (list gnupg mirror (expand-file-name "src/emacs-31.1" tmp))) (make-directory d t))
    (set-file-modes gnupg #o700)
    (funcall sh (format "tar -C %s/src -cJf %s/emacs-31.1.tar.xz emacs-31.1" tmp mirror))
    (funcall sh (format "gpg --homedir %s --batch --passphrase '' --quick-gen-key 'drgnx test <test@drgnx.invalid>' default default never 2>/dev/null" gnupg))
    (funcall sh (format "gpg --homedir %s --batch --pinentry-mode loopback --passphrase '' --detach-sign -o %s/emacs-31.1.tar.xz.sig %s/emacs-31.1.tar.xz 2>/dev/null" gnupg mirror mirror))
    (funcall sh (format "gpg --homedir %s --export >%s/keyring 2>/dev/null" gnupg mirror))
    (prog1 (with-temp-buffer
             (call-process "gpg" nil t nil "--homedir" gnupg "--batch" "--with-colons" "--list-keys")
             (goto-char (point-min))
             (re-search-forward "^fpr:+\\([0-9A-F]+\\):")
             (match-string 1))
      (call-process "gpgconf" nil nil nil "--homedir" gnupg "--kill" "all"))))

(ert-deftest drgnx-install/only-the-release-key-is-trusted ()
  ;; M2.5-5: a good signature by any key of the keyring is not enough — it must be the key that signs the
  ;; release (DRGNX_INSTALL_SIGNER overrides the published one here).
  (skip-unless (/= 0 (user-uid)))     ; as root, as_root runs commands without sudo: they would really run
  (skip-unless (executable-find "gpg"))
  (let* ((tmp (make-temp-file "drgnx-install" t))
         (bin (expand-file-name "bin" tmp)) (prefix (expand-file-name "prefix" tmp)))
    (unwind-protect
        (let ((signer (drgnx-install-test--signed-mirror tmp)))
          (make-directory bin)
          (write-region "#!/bin/sh\necho \"FAKE-SUDO $*\"\nexit 1\n" nil (expand-file-name "sudo" bin))
          (set-file-modes (expand-file-name "sudo" bin) #o755)
          (dolist (want (list "0123456789ABCDEF0123456789ABCDEF01234567" signer))
            (let ((r (drgnx-install-test--run
                      (list (concat "DRGNX_INSTALL_OS_RELEASE=" (drgnx-install-test--os "fedora-44"))
                            "DRGNX_INSTALL_UNAME=Linux" (concat "DRGNX_INSTALL_SIGNER=" want)
                            (concat "DRGNX_INSTALL_MIRROR=file://" tmp "/mirror")
                            (concat "DRGNX_INSTALL_KEYRING=file://" tmp "/mirror/keyring")
                            (concat "XDG_CACHE_HOME=" tmp "/cache")
                            (concat "PATH=" bin ":" (getenv "PATH")))
                      "--yes" "--method" "source" "--prefix" prefix "--source-dir" drgnx-install-test--root)))
              (should (= (car r) 1))
              (if (equal want signer)          ; past the check: the first root step (fake sudo refuses it)
                  (should (string-search "FAKE-SUDO dnf install" (cdr r)))
                (should (string-search "not by the key that signs Emacs releases" (cdr r)))
                (should (string-search "nothing was installed" (cdr r)))
                (should-not (string-search "As root:" (cdr r)))
                (should-not (directory-files (expand-file-name "cache/drgnx/build" tmp) nil "\\.tar\\.xz"))))))
      (delete-directory tmp t))))

(ert-deftest drgnx-install/debian-source-lists-are-mirrored-and-always-removed ()
  ;; Linux Mint keeps its archives in a one-line .list; build-dep needs deb-src for them.  When a step
  ;; fails, drgnx's deb-src list is removed anyway.  A tarball signed by a throwaway key gets past the
  ;; signature check; fake sudo runs the command, fake apt-get records what build-dep would see, then fails.
  (skip-unless (/= 0 (user-uid)))
  (skip-unless (executable-find "gpg"))
  (let* ((tmp (make-temp-file "drgnx-install" t))
         (mirror (expand-file-name "mirror" tmp))
         (apt (expand-file-name "apt" tmp)) (bin (expand-file-name "bin" tmp))
         (log (expand-file-name "apt-get.log" tmp)))
    (unwind-protect
        (let ((signer (drgnx-install-test--signed-mirror tmp)))
          (dolist (d (list bin (expand-file-name "sources.list.d" apt)))
            (make-directory d t))
          (write-region "" nil (expand-file-name "sources.list" apt))
          (write-region "deb http://packages.linuxmint.com zena main upstream\ndeb http://archive.ubuntu.com/ubuntu noble main\n"
                        nil (expand-file-name "sources.list.d/official-package-repositories.list" apt))
          (write-region "#!/bin/sh\nexec \"$@\"\n" nil (expand-file-name "sudo" bin))
          (write-region (format "#!/bin/sh\necho \"apt-get $*\" >>%s\ncase \"$*\" in *build-dep*) cat %s/sources.list.d/drgnx-deb-src.* >>%s; exit 100 ;; esac\nexit 0\n"
                                log apt log)
                        nil (expand-file-name "apt-get" bin))
          (dolist (f '("sudo" "apt-get")) (set-file-modes (expand-file-name f bin) #o755))
          (let ((r (drgnx-install-test--run
                    (list (concat "DRGNX_INSTALL_OS_RELEASE=" (drgnx-install-test--os "linuxmint"))
                          "DRGNX_INSTALL_UNAME=Linux" (concat "DRGNX_INSTALL_SIGNER=" signer)
                          (concat "DRGNX_INSTALL_MIRROR=file://" mirror)
                          (concat "DRGNX_INSTALL_KEYRING=file://" mirror "/keyring")
                          (concat "DRGNX_INSTALL_APT_DIR=" apt)
                          (concat "XDG_CACHE_HOME=" tmp "/cache")
                          (concat "PATH=" bin ":" (getenv "PATH")))
                    "--yes" "--method" "source" "--prefix" (expand-file-name "prefix" tmp)
                    "--source-dir" drgnx-install-test--root)))
            (should (/= (car r) 0))
            (should (string-search "Good signature" (cdr r)))
            (let ((seen (with-temp-buffer (insert-file-contents log) (buffer-string))))
              (should (string-search "deb-src http://packages.linuxmint.com zena main upstream" seen))
              (should (string-search "deb-src http://archive.ubuntu.com/ubuntu noble main" seen)))
            (should-not (directory-files (expand-file-name "sources.list.d" apt) nil "\\`drgnx-deb-src"))
            (should-not (file-exists-p (expand-file-name "prefix/bin/emacs" tmp)))))
      (delete-directory tmp t))))

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
