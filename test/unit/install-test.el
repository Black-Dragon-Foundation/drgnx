;;; install-test.el --- batch tests: install.sh plans (dry runs) -*- lexical-binding: t -*-
;; The installer is bash (it must run before any Emacs exists); these tests call it with
;; detection overridden through DRGNX_INSTALL_* and check the plan it prints.
(require 'ert)

(defconst drgnx-install-test--root
  (expand-file-name "../../" (file-name-directory (or load-file-name buffer-file-name))))

(defun drgnx-install-test--os (name)
  (expand-file-name (concat "test/fixtures/os-release/" name) drgnx-install-test--root))

(defun drgnx-install-test--run (env &rest args)
  "Run install.sh ARGS with ENV (\"K=V\" strings) in a new session (no terminal); return (EXIT . OUTPUT).
HOME is a new empty directory, deleted afterwards (ENV may name another)."
  (let* ((home (make-temp-file "drgnx-install-home" t))
         (process-environment (append env (list "DRGNX_INSTALL_EMACS=none" (concat "HOME=" home)
                                                ;; never this machine's /run/ostree-booted
                                                (concat "DRGNX_INSTALL_OSTREE_BOOTED=" home "/no-ostree"))
                                      process-environment))
         (default-directory drgnx-install-test--root))    ; not "~/…": HOME is changed above
    (unwind-protect
        (with-temp-buffer
          (cons (apply #'call-process "setsid" nil t nil "-w" "bash"
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

(ert-deftest drgnx-install/debian-source-lists-are-mirrored-and-always-removed ()
  ;; Linux Mint keeps its archives in a one-line .list; build-dep needs deb-src for them.  When a step
  ;; fails, drgnx's deb-src list is removed anyway.  A tarball signed by a throwaway key gets past the
  ;; signature check; fake sudo runs the command, fake apt-get records what build-dep would see, then fails.
  (skip-unless (/= 0 (user-uid)))
  (skip-unless (executable-find "gpg"))
  (let* ((tmp (make-temp-file "drgnx-install" t))
         (gnupg (expand-file-name "g" tmp)) (mirror (expand-file-name "mirror" tmp))
         (apt (expand-file-name "apt" tmp)) (bin (expand-file-name "bin" tmp))
         (log (expand-file-name "apt-get.log" tmp))
         (sh (lambda (&rest args) (should (= 0 (apply #'call-process "sh" nil nil nil "-c" args))))))
    (unwind-protect
        (progn
          (dolist (d (list gnupg mirror bin (expand-file-name "src/emacs-31.1" tmp) (expand-file-name "sources.list.d" apt)))
            (make-directory d t))
          (set-file-modes gnupg #o700)
          (write-region "" nil (expand-file-name "sources.list" apt))
          (write-region "deb http://packages.linuxmint.com zena main upstream\ndeb http://archive.ubuntu.com/ubuntu noble main\n"
                        nil (expand-file-name "sources.list.d/official-package-repositories.list" apt))
          (write-region "#!/bin/sh\nexec \"$@\"\n" nil (expand-file-name "sudo" bin))
          (write-region (format "#!/bin/sh\necho \"apt-get $*\" >>%s\ncase \"$*\" in *build-dep*) cat %s/sources.list.d/drgnx-deb-src.* >>%s; exit 100 ;; esac\nexit 0\n"
                                log apt log)
                        nil (expand-file-name "apt-get" bin))
          (dolist (f '("sudo" "apt-get")) (set-file-modes (expand-file-name f bin) #o755))
          (funcall sh (format "tar -C %s/src -cJf %s/emacs-31.1.tar.xz emacs-31.1" tmp mirror))
          (funcall sh (format "gpg --homedir %s --batch --passphrase '' --quick-gen-key 'drgnx test <test@drgnx.invalid>' default default never 2>/dev/null" gnupg))
          (funcall sh (format "gpg --homedir %s --batch --pinentry-mode loopback --passphrase '' --detach-sign -o %s/emacs-31.1.tar.xz.sig %s/emacs-31.1.tar.xz 2>/dev/null" gnupg mirror mirror))
          (funcall sh (format "gpg --homedir %s --export >%s/keyring 2>/dev/null; gpgconf --homedir %s --kill all" gnupg mirror gnupg))
          (let ((r (drgnx-install-test--run
                    (list (concat "DRGNX_INSTALL_OS_RELEASE=" (drgnx-install-test--os "linuxmint"))
                          "DRGNX_INSTALL_UNAME=Linux"
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
