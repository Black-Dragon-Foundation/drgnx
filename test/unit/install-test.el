;;; install-test.el --- batch tests: install.sh plans (dry runs) -*- lexical-binding: t -*-
;; The installer is bash (it must run before any Emacs exists); these tests call it with
;; detection overridden through DRGNX_INSTALL_* and check the plan it prints.
(require 'ert)

(defconst drgnx-install-test--root
  (expand-file-name "../../" (file-name-directory (or load-file-name buffer-file-name))))

(defun drgnx-install-test--os (name)
  (expand-file-name (concat "test/fixtures/os-release/" name) drgnx-install-test--root))

(defun drgnx-install-test--run (env &rest args)
  "Run install.sh ARGS with ENV (\"K=V\" strings) in a new session (no terminal); return (EXIT . OUTPUT)."
  (let ((process-environment (append env (list "DRGNX_INSTALL_EMACS=none" "HOME=/tmp/drgnx-install-test-home")
                                     process-environment))
        (default-directory drgnx-install-test--root))     ; not "~/…": HOME is changed above
    (with-temp-buffer
      (cons (apply #'call-process "setsid" nil t nil "-w" "bash"
                   (expand-file-name "install.sh" drgnx-install-test--root) args)
            (buffer-string)))))

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
                              "pacman -S --needed --noconfirm emacs-wayland")
  (drgnx-install-test--expect (drgnx-install-test--plan "endeavouros" "DRGNX_INSTALL_SESSION=x11")
                              "pacman -S --needed --noconfirm emacs"))

(ert-deftest drgnx-install/debian-family-builds-from-source ()
  (dolist (os '("debian-13" "ubuntu-26.04" "linuxmint"))
    (drgnx-install-test--expect (drgnx-install-test--plan os "DRGNX_INSTALL_SESSION=x11")
                                "build GNU Emacs 31.1 from source" "apt-get build-dep -y emacs"
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
    (should (string-search "docs/install.md" (cdr r)))))

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
  (let ((r (drgnx-install-test--run (list (concat "DRGNX_INSTALL_OS_RELEASE=" (drgnx-install-test--os "fedora-45"))
                                          "DRGNX_INSTALL_UNAME=Linux"))))
    (should (= (car r) 3))
    (should (string-search "--yes" (cdr r)))
    (should-not (file-exists-p "/tmp/drgnx-install-test-home/.local/share/drgnx"))))

(ert-deftest drgnx-install/plan-names-the-drgnx-steps ()
  (drgnx-install-test--expect (drgnx-install-test--plan "fedora-45")
                              "git clone" ".local/share/drgnx/drgnx" "bin/drgnx" "drgnx doctor"))
