;;; tty-recommend-test.el --- batch tests: recommend a capable terminal -*- lexical-binding: t -*-
;; Nothing here touches the machine: PATH is a temp dir holding fake executables that log their calls, the
;; system and the os-release file are stubbed, display and SSH variables are set per test.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-tty-recommend)

(defconst drgnx-tty-rec-test--root
  (expand-file-name "../../" (file-name-directory (or load-file-name buffer-file-name))))

(defun drgnx-tty-rec-test--os-file (name)
  (expand-file-name (concat "test/fixtures/os-release/" name) drgnx-tty-rec-test--root))

(defun drgnx-tty-rec-test--os (name &optional ostree)
  "The OS plist for fixture NAME, as a Linux; image-based (rpm-ostree) when OSTREE."
  (let ((system-type 'gnu/linux))
    (cl-letf (((symbol-function 'file-exists-p)
               (let ((orig (symbol-function 'file-exists-p)))
                 (lambda (f) (if (equal f drgnx-tty-ostree-file) ostree (funcall orig f))))))
      (drgnx-tty-os (drgnx-tty-rec-test--os-file name)))))

(defconst drgnx-tty-rec-test--macos '(:system macos :ostree nil :ids nil))

(defmacro drgnx-tty-rec-test--with-path (names &rest body)
  "BODY with only the fake executables NAMES on PATH and exec-path; each appends its name to `calls'.
NAMES may be empty.  A fixed set of variables is cleared: display, SSH."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "drgnx-rec-bin" t))
          (log (expand-file-name "calls" dir))
          (exec-path (list dir))
          (process-environment
           (append (list (concat "PATH=" dir) "DISPLAY=" "WAYLAND_DISPLAY=" "SSH_CONNECTION=" "SSH_TTY=")
                   process-environment))
          (drgnx-tty-open-in nil)
          (drgnx-tty-mac-app-dirs nil))
     (unwind-protect
         (progn
           (dolist (n ,names)
             (let ((f (expand-file-name n dir)))
               (with-temp-file f (insert "#!/bin/sh\necho \"" n " $*\" >> '" log "'\n"))
               (set-file-modes f #o755)))
           (cl-flet ((calls () (if (file-exists-p log)
                                   (with-temp-buffer (insert-file-contents log) (buffer-string))
                                 "")))
             ,@body))
       (delete-directory dir t))))

(defmacro drgnx-tty-rec-test--with-display (&rest body)
  "BODY with a Wayland display set, so `drgnx-tty-capable-terminal-argv' goes all the way."
  `(let ((process-environment (cons "WAYLAND_DISPLAY=wayland-1" process-environment))) ,@body))

(defconst drgnx-tty-rec-test--all-os
  '("fedora-44" "fedora-45" "debian-13" "ubuntu-26.04" "arch" "linuxmint" "endeavouros" "nobara-42" "rocky-9"
    "amazon-2023" "unknown"))

(ert-deftest drgnx-tty-recommend/os-from-os-release ()
  (should (equal (drgnx-tty-rec-test--os "fedora-45") '(:system linux :ostree nil :ids ("fedora"))))
  (should (equal (drgnx-tty-rec-test--os "debian-13") '(:system linux :ostree nil :ids ("debian"))))
  (should (equal (drgnx-tty-rec-test--os "ubuntu-26.04") '(:system linux :ostree nil :ids ("ubuntu" "debian"))))
  (should (equal (drgnx-tty-rec-test--os "linuxmint") '(:system linux :ostree nil :ids ("linuxmint" "ubuntu" "debian"))))
  (should (equal (drgnx-tty-rec-test--os "arch") '(:system linux :ostree nil :ids ("arch"))))
  (should (equal (drgnx-tty-rec-test--os "endeavouros") '(:system linux :ostree nil :ids ("endeavouros" "arch"))))
  (should (equal (drgnx-tty-rec-test--os "nobara-42") '(:system linux :ostree nil :ids ("nobara" "rhel" "centos" "fedora"))))
  (should (equal (drgnx-tty-rec-test--os "rocky-9") '(:system linux :ostree nil :ids ("rocky" "rhel" "centos" "fedora"))))
  (should (equal (drgnx-tty-rec-test--os "amazon-2023") '(:system linux :ostree nil :ids ("amzn" "fedora"))))
  (should (equal (drgnx-tty-rec-test--os "unknown") '(:system linux :ostree nil :ids ("plan9"))))
  ;; no readable file: still Linux, no ids
  (should (equal (let ((system-type 'gnu/linux))
                   (drgnx-tty-os (drgnx-tty-rec-test--os-file "no-such-file")))
                 '(:system linux :ostree nil :ids nil)))
  ;; macOS comes from the platform, never from a file
  (should (equal (let ((system-type 'darwin)) (drgnx-tty-os (drgnx-tty-rec-test--os-file "fedora-45")))
                 '(:system macos :ostree nil :ids nil))))

(ert-deftest drgnx-tty-recommend/install-commands-per-os ()
  (let ((cmd (lambda (term os) (drgnx-tty-install-command term os))))
    ;; Fedora family: dnf, kitty and foot
    (dolist (name '("fedora-45" "nobara-42"))
      (let ((os (drgnx-tty-rec-test--os name)))
        (should (equal (funcall cmd 'kitty os) "sudo dnf install kitty"))
        (should (equal (funcall cmd 'foot os) "sudo dnf install foot"))))
    ;; Debian family: apt
    (dolist (name '("ubuntu-26.04" "debian-13" "linuxmint"))
      (let ((os (drgnx-tty-rec-test--os name)))
        (should (equal (funcall cmd 'kitty os) "sudo apt install kitty"))
        (should (equal (funcall cmd 'foot os) "sudo apt install foot"))))
    ;; Arch family: pacman, all of them
    (dolist (name '("arch" "endeavouros"))
      (let ((os (drgnx-tty-rec-test--os name)))
        (should (equal (funcall cmd 'kitty os) "sudo pacman -S kitty"))
        (should (equal (funcall cmd 'foot os) "sudo pacman -S foot"))
        (should (equal (funcall cmd 'ghostty os) "sudo pacman -S ghostty"))
        (should (equal (funcall cmd 'wezterm os) "sudo pacman -S wezterm"))
        (should (equal (funcall cmd 'xterm os) "sudo pacman -S xterm"))))
    ;; macOS: brew casks; foot has no macOS build
    (should (equal (funcall cmd 'kitty drgnx-tty-rec-test--macos) "brew install --cask kitty"))
    (should (equal (funcall cmd 'ghostty drgnx-tty-rec-test--macos) "brew install --cask ghostty"))
    (should (equal (funcall cmd 'wezterm drgnx-tty-rec-test--macos) "brew install --cask wezterm"))
    (should-not (funcall cmd 'foot drgnx-tty-rec-test--macos))
    ;; no package in the distribution's index, or a distribution we do not know: the download page
    (should (equal (funcall cmd 'wezterm (drgnx-tty-rec-test--os "fedora-45")) "https://wezterm.org/installation.html"))
    (should (equal (funcall cmd 'ghostty (drgnx-tty-rec-test--os "debian-13")) "https://ghostty.org/docs/install/binary"))
    (dolist (name '("unknown" "amazon-2023" "rocky-9"))
      (let ((os (drgnx-tty-rec-test--os name)))
        (should (equal (funcall cmd 'kitty os) "https://sw.kovidgoyal.net/kitty/binary/"))
        (should (equal (funcall cmd 'foot os) "https://codeberg.org/dnkl/foot"))))))

(ert-deftest drgnx-tty-recommend/legacy-gets-recommendations-installed-first ()
  (let ((os (drgnx-tty-rec-test--os "fedora-45")))
    ;; foot installed: it is named first, with no install line
    (drgnx-tty-rec-test--with-path '("foot")
      (let ((rec (drgnx-tty-recommendation '(:keys legacy) os)))
        (should (equal (plist-get rec :installed) '(foot)))
        (should-not (plist-get rec :install))
        (should (string-match-p "foot is installed: run drgnx -t from foot" (plist-get rec :text)))
        (should-not (string-match-p "sudo dnf" (plist-get rec :text)))
        (should (string-match-p "Alt\\+Shift or F6 then the key" (plist-get rec :text)))))
    ;; installed ones in the order of the list, not of PATH
    (drgnx-tty-rec-test--with-path '("kitty" "xterm" "wezterm")
      (let ((rec (drgnx-tty-recommendation '(:keys legacy) os)))
        (should (equal (plist-get rec :installed) '(wezterm xterm kitty)))
        (should (string-match-p "WezTerm is installed.*xterm is installed.*kitty is installed" (plist-get rec :text)))))
    ;; kitty works, but C-g cannot stop busy Lisp there: the text says so; modifyOtherKeys ones do not
    (drgnx-tty-rec-test--with-path '("kitty")
      (should (string-match-p "kitty is installed.*C-g cannot stop busy Lisp"
                              (plist-get (drgnx-tty-recommendation '(:keys legacy) os) :text))))
    (drgnx-tty-rec-test--with-path '("wezterm")
      (should-not (string-match-p "C-g" (plist-get (drgnx-tty-recommendation '(:keys legacy) os) :text))))
    ;; nothing installed: the first two commands, modifyOtherKeys terminals first, and what to do until then
    (drgnx-tty-rec-test--with-path nil
      (let ((rec (drgnx-tty-recommendation '(:keys legacy) os)))
        (should-not (plist-get rec :installed))
        (should (equal (plist-get rec :install)
                       '((xterm . "sudo dnf install xterm") (foot . "sudo dnf install foot"))))
        (should (string-match-p "sudo dnf install xterm" (plist-get rec :text)))
        (should (string-match-p "Alt\\+Shift or F6 then the key" (plist-get rec :text)))))
    (drgnx-tty-rec-test--with-path nil
      (should (equal (plist-get (drgnx-tty-recommendation '(:keys legacy) (drgnx-tty-rec-test--os "arch")) :install)
                     '((wezterm . "sudo pacman -S wezterm") (xterm . "sudo pacman -S xterm")))))
    ;; only download pages for a distribution that ships none: still two
    (drgnx-tty-rec-test--with-path nil
      (should (equal (mapcar #'car (plist-get (drgnx-tty-recommendation '(:keys legacy) (drgnx-tty-rec-test--os "unknown"))
                                              :install))
                     '(wezterm xterm))))))

(ert-deftest drgnx-tty-recommend/capable-gets-none ()
  (drgnx-tty-rec-test--with-path '("kitty")
    (dolist (keys '(kkp mok))
      (should-not (drgnx-tty-recommendation (list :keys keys) (drgnx-tty-rec-test--os "fedora-45"))))
    (should (drgnx-tty-recommendation '(:keys legacy) (drgnx-tty-rec-test--os "fedora-45")))))

(ert-deftest drgnx-tty-recommend/wezterm-needs-no-kitty-keyboard-line ()
  ;; WezTerm gets its keys through modifyOtherKeys: no `enable_kitty_keyboard' advice anywhere, and it comes first
  (should (eq (car (car drgnx-tty-capable-terminals)) 'wezterm))
  (should (plist-get (drgnx-tty-terminal 'wezterm) :mok))
  (dolist (name drgnx-tty-rec-test--all-os)
    (let ((os (drgnx-tty-rec-test--os name)))
      (drgnx-tty-rec-test--with-path nil
        (let ((rec (drgnx-tty-recommendation '(:keys legacy) os)))
          (should-not (string-match-p "kitty_keyboard" (plist-get rec :text)))
          (should-not (string-match-p "wezterm.lua" (plist-get rec :text)))))
      (drgnx-tty-rec-test--with-path '("wezterm")
        (let ((rec (drgnx-tty-recommendation '(:keys legacy) os)))
          (should (equal (plist-get rec :installed) '(wezterm)))
          (should-not (string-match-p "kitty_keyboard" (plist-get rec :text)))))))
  (should-not (string-match-p "kitty_keyboard"
                              (drgnx-tty-install-command 'wezterm drgnx-tty-rec-test--macos))))

(ert-deftest drgnx-tty-recommend/never-runs-anything ()
  (drgnx-tty-rec-test--with-path '("sudo" "dnf" "apt" "pacman" "brew" "kitty" "foot" "wezterm" "ghostty" "xterm")
    ;; the fakes do log: running one is seen, then the log is cleared
    (call-process "kitty" nil nil nil "--probe")
    (should (equal (calls) "kitty --probe\n"))
    (delete-file log)
    (let ((drgnx-tty-open-in 'auto))
      (drgnx-tty-rec-test--with-display
       (dolist (name drgnx-tty-rec-test--all-os)
         (let ((os (drgnx-tty-rec-test--os name)))
           (dolist (term (mapcar #'car drgnx-tty-capable-terminals))
             (drgnx-tty-install-command term os))
           (drgnx-tty-recommendation '(:keys legacy) os)))
       (dolist (term (mapcar #'car drgnx-tty-capable-terminals))
         (drgnx-tty-install-command term drgnx-tty-rec-test--macos))
       (drgnx-tty-recommendation '(:keys legacy) drgnx-tty-rec-test--macos)
       (drgnx-tty-installed-capable)
       (should (drgnx-tty-capable-terminal-argv))
       (should (equal (calls) ""))))))

(ert-deftest drgnx-tty-recommend/open-in-is-off-by-default ()
  (should (null (default-value 'drgnx-tty-open-in)))
  (drgnx-tty-rec-test--with-path '("kitty" "foot")
    (let ((process-environment (cons "WAYLAND_DISPLAY=wayland-1" process-environment)))
      (should-not (drgnx-tty-capable-terminal-argv))
      (let ((drgnx-tty-open-in 'auto))
        (should (drgnx-tty-capable-terminal-argv))))))

(defun drgnx-tty-rec-test--argv-names (argv)
  "ARGV with its first element reduced to the file name."
  (and argv (cons (file-name-nondirectory (car argv)) (cdr argv))))

(ert-deftest drgnx-tty-recommend/open-in-auto-picks-the-first-installed ()
  (drgnx-tty-rec-test--with-path '("kitty" "foot")
    (let ((process-environment (cons "WAYLAND_DISPLAY=wayland-1" process-environment))
          (drgnx-tty-open-in 'auto))
      ;; foot comes before kitty
      (should (equal (drgnx-tty-rec-test--argv-names (drgnx-tty-capable-terminal-argv)) '("foot")))
      ;; a named terminal: that one, with its own prefix
      (let ((drgnx-tty-open-in 'kitty))
        (should (equal (drgnx-tty-rec-test--argv-names (drgnx-tty-capable-terminal-argv)) '("kitty" "--"))))
      ;; a named terminal that is not installed: nothing (no fallback to another)
      (let ((drgnx-tty-open-in 'wezterm))
        (should-not (drgnx-tty-capable-terminal-argv)))
      ;; the argv runs the installed file
      (should (file-executable-p (car (drgnx-tty-capable-terminal-argv))))))
  (drgnx-tty-rec-test--with-path '("wezterm" "ghostty" "xterm")
    (let ((process-environment (append '("DISPLAY=:0" "WAYLAND_DISPLAY=wayland-1") process-environment))
          (drgnx-tty-open-in 'auto))
      (should (equal (drgnx-tty-rec-test--argv-names (drgnx-tty-capable-terminal-argv)) '("wezterm" "start" "--")))))
  (drgnx-tty-rec-test--with-path '("ghostty")
    (let ((process-environment (cons "WAYLAND_DISPLAY=wayland-1" process-environment))
          (drgnx-tty-open-in 'auto))
      (should (equal (drgnx-tty-rec-test--argv-names (drgnx-tty-capable-terminal-argv)) '("ghostty" "-e")))))
  (drgnx-tty-rec-test--with-path '("xterm")
    (let ((process-environment (cons "DISPLAY=:0" process-environment))
          (drgnx-tty-open-in 'auto))
      (should (equal (drgnx-tty-rec-test--argv-names (drgnx-tty-capable-terminal-argv)) '("xterm" "-e")))))
  ;; none installed: nil
  (drgnx-tty-rec-test--with-path nil
    (let ((process-environment (cons "WAYLAND_DISPLAY=wayland-1" process-environment))
          (drgnx-tty-open-in 'auto))
      (should-not (drgnx-tty-capable-terminal-argv)))))

(ert-deftest drgnx-tty-recommend/no-opener-over-ssh-or-without-a-display ()
  (drgnx-tty-rec-test--with-path '("kitty" "foot")
    (let ((drgnx-tty-open-in 'auto))
      ;; no display: nil
      (should-not (drgnx-tty-capable-terminal-argv))
      ;; a display, over SSH: nil
      (let ((process-environment (append '("WAYLAND_DISPLAY=wayland-1" "SSH_CONNECTION=1.2.3.4 5 6.7.8.9 22")
                                         process-environment)))
        (should-not (drgnx-tty-capable-terminal-argv)))
      (let ((process-environment (append '("DISPLAY=:0" "SSH_TTY=/dev/pts/3") process-environment)))
        (should-not (drgnx-tty-capable-terminal-argv)))
      ;; an X11 display only: foot needs Wayland, so kitty is picked
      (let ((process-environment (cons "DISPLAY=:0" process-environment)))
        (should (equal (drgnx-tty-rec-test--argv-names (drgnx-tty-capable-terminal-argv)) '("kitty" "--"))))
      ;; macOS needs no display variable
      (let ((system-type 'darwin))
        (should (drgnx-tty-capable-terminal-argv))))))

(ert-deftest drgnx-tty-recommend/image-based-fedora-never-gets-dnf ()
  ;; Silverblue, Kinoite and the like: /run/ostree-booted exists; dnf cannot install there
  (let ((os (drgnx-tty-rec-test--os "fedora-45" t)))
    (should (eq (plist-get os :ostree) t))
    (should-not (plist-get (drgnx-tty-rec-test--os "fedora-45") :ostree))
    (should (equal (drgnx-tty-install-command 'kitty os) "rpm-ostree install kitty"))
    (should (equal (drgnx-tty-install-command 'foot os) "rpm-ostree install foot"))
    (should (equal (drgnx-tty-install-command 'xterm os) "rpm-ostree install xterm"))
    ;; no Fedora package: the download page, as on a normal Fedora
    (should (equal (drgnx-tty-install-command 'wezterm os) "https://wezterm.org/installation.html"))
    (should (equal (drgnx-tty-install-command 'ghostty os) "https://ghostty.org/docs/install/binary"))
    (dolist (term (mapcar #'car drgnx-tty-capable-terminals))
      (should-not (string-match-p "dnf" (drgnx-tty-install-command term os))))
    (drgnx-tty-rec-test--with-path nil
      (let ((rec (drgnx-tty-recommendation '(:keys legacy) os)))
        (should (equal (plist-get rec :install)
                       '((xterm . "rpm-ostree install xterm") (foot . "rpm-ostree install foot"))))
        (should-not (string-match-p "dnf" (plist-get rec :text)))
        (should (string-match-p "restart" (plist-get rec :text))))))
  ;; other systems are not affected by the flag
  (should (equal (drgnx-tty-install-command 'kitty (plist-put (drgnx-tty-rec-test--os "ubuntu-26.04") :ostree t))
                 "sudo apt install kitty")))

(defun drgnx-tty-rec-test--make-app (apps app binary)
  "Make an executable APPS/APP/Contents/MacOS/BINARY; return its path."
  (let ((exe (expand-file-name (concat app "/Contents/MacOS/" binary) apps)))
    (make-directory (file-name-directory exe) t)
    (with-temp-file exe (insert "#!/bin/sh\n"))
    (set-file-modes exe #o755)
    exe))

(ert-deftest drgnx-tty-recommend/finds-macos-apps ()
  (let ((apps (make-temp-file "drgnx-rec-apps" t)))
    (unwind-protect
        (drgnx-tty-rec-test--with-path nil
          (let ((system-type 'darwin)
                (drgnx-tty-mac-app-dirs (list apps))
                (drgnx-tty-open-in 'auto))
            ;; Ghostty's CLI cannot start the GUI on macOS: `open -na BUNDLE --args -e'
            (drgnx-tty-rec-test--make-app apps "Ghostty.app" "ghostty")
            (should (equal (drgnx-tty-installed-capable) '(ghostty)))
            (should (equal (drgnx-tty-capable-terminal-argv)
                           (list "/usr/bin/open" "-na" (expand-file-name "Ghostty.app" apps) "--args" "-e")))
            ;; WezTerm and kitty are run through their bundled CLI, which does start the GUI
            (let ((exe (drgnx-tty-rec-test--make-app apps "WezTerm.app" "wezterm")))
              (should (equal (drgnx-tty-installed-capable) '(wezterm ghostty)))
              (should (equal (drgnx-tty-capable-terminal-argv) (list exe "start" "--"))))
            (let ((exe (drgnx-tty-rec-test--make-app apps "kitty.app" "kitty"))
                  (drgnx-tty-open-in 'kitty))
              (should (equal (drgnx-tty-capable-terminal-argv) (list exe "--"))))
            ;; an app directory that does not exist is not an error
            (let ((drgnx-tty-mac-app-dirs (list (expand-file-name "nope" apps))))
              (should-not (drgnx-tty-installed-capable)))
            ;; app bundles count only on macOS
            (let ((system-type 'gnu/linux))
              (should-not (drgnx-tty-installed-capable)))))
      (delete-directory apps t)))
  ;; Ghostty found on PATH (Homebrew) on macOS: still through `open', by the app's name
  (drgnx-tty-rec-test--with-path '("ghostty")
    (let ((system-type 'darwin) (drgnx-tty-open-in 'ghostty))
      (should (equal (drgnx-tty-capable-terminal-argv) '("/usr/bin/open" "-na" "Ghostty.app" "--args" "-e"))))
    ;; on Linux the same ghostty runs directly
    (let ((process-environment (cons "WAYLAND_DISPLAY=wayland-1" process-environment))
          (drgnx-tty-open-in 'ghostty))
      (should (equal (drgnx-tty-rec-test--argv-names (drgnx-tty-capable-terminal-argv)) '("ghostty" "-e"))))))

(ert-deftest drgnx-tty-recommend/xterm-says-what-it-lacks ()
  ;; derived from xterm's row (no OSC 52, no true colour), like the C-g note
  (should (equal (drgnx-tty-terminal-caveat 'xterm) "xterm: no clipboard copy over SSH, 256 colours"))
  (dolist (term '(wezterm ghostty kitty foot alacritty))
    (should-not (drgnx-tty-terminal-caveat term)))
  (let ((os (drgnx-tty-rec-test--os "fedora-45")))
    ;; installed
    (drgnx-tty-rec-test--with-path '("xterm")
      (should (string-match-p "xterm is installed.*xterm: no clipboard copy over SSH, 256 colours"
                              (plist-get (drgnx-tty-recommendation '(:keys legacy) os) :text))))
    ;; to install (xterm is first on Fedora and Debian)
    (drgnx-tty-rec-test--with-path nil
      (let ((rec (drgnx-tty-recommendation '(:keys legacy) os)))
        (should (eq (car (car (plist-get rec :install))) 'xterm))
        (should (string-match-p "xterm: no clipboard copy over SSH, 256 colours" (plist-get rec :text)))))
    ;; no caveat where xterm is not recommended (macOS: no xterm cask)
    (drgnx-tty-rec-test--with-path nil
      (should-not (string-match-p "256 colours"
                                  (plist-get (drgnx-tty-recommendation '(:keys legacy) drgnx-tty-rec-test--macos)
                                             :text)))))
  ;; `auto' picking xterm: the caller can say it
  (drgnx-tty-rec-test--with-path '("xterm")
    (let ((process-environment (cons "DISPLAY=:0" process-environment))
          (drgnx-tty-open-in 'auto))
      (should (eq (drgnx-tty-capable-terminal) 'xterm)))
    (let ((drgnx-tty-open-in nil))
      (should-not (drgnx-tty-capable-terminal)))))

(ert-deftest drgnx-tty-recommend/alacritty-is-recommended-last ()
  (should (eq (car (car (last drgnx-tty-capable-terminals))) 'alacritty))
  (should (equal (mapcar #'car drgnx-tty-capable-terminals) drgnx-tty-best-order))
  (should (equal (drgnx-tty-install-command 'alacritty (drgnx-tty-rec-test--os "fedora-45")) "sudo dnf install alacritty"))
  (should (equal (drgnx-tty-install-command 'alacritty (drgnx-tty-rec-test--os "fedora-45" t)) "rpm-ostree install alacritty"))
  (should (equal (drgnx-tty-install-command 'alacritty (drgnx-tty-rec-test--os "debian-13")) "sudo apt install alacritty"))
  (should (equal (drgnx-tty-install-command 'alacritty (drgnx-tty-rec-test--os "arch")) "sudo pacman -S alacritty"))
  (should (equal (drgnx-tty-install-command 'alacritty drgnx-tty-rec-test--macos) "brew install --cask alacritty"))
  (should (string-prefix-p "https://" (drgnx-tty-install-command 'alacritty (drgnx-tty-rec-test--os "unknown"))))
  (drgnx-tty-rec-test--with-path '("alacritty")
    (let ((process-environment (cons "DISPLAY=:0" process-environment))
          (drgnx-tty-open-in 'auto))
      (should (equal (drgnx-tty-rec-test--argv-names (drgnx-tty-capable-terminal-argv)) '("alacritty" "-e")))
      (should (string-match-p "Alacritty is installed.*C-g cannot stop busy Lisp"
                              (plist-get (drgnx-tty-recommendation '(:keys legacy) (drgnx-tty-rec-test--os "arch")) :text))))))

;;; tty-recommend-test.el ends here
