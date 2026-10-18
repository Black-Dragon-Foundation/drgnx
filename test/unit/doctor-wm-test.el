;;; doctor-wm-test.el --- batch tests: the doctor's Desktop row (the window manager) -*- lexical-binding: t -*-
;; Nothing here reaches the session the tests run in: every window-manager variable is set or unset per test, the
;; session bus is a dead address and D-Bus calls signal, the tools are scripts in a temp bin (the WM's one query is
;; test/fixtures/wm/fake-wm.sh), the system is a fixture os-release.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-doctor)
(require 'drgnx-platform)
(require 'drgnx-tty-recommend)

(defconst drgnx-doctor-wm-test--vars
  '("SWAYSOCK" "I3SOCK" "HYPRLAND_INSTANCE_SIGNATURE" "NIRI_SOCKET" "WAYLAND_DISPLAY" "DISPLAY" "XAUTHORITY"
    "XDG_CURRENT_DESKTOP" "XDG_SESSION_TYPE" "SSH_CONNECTION" "SSH_TTY")
  "Unset in every test unless the test sets it.")

(defvar drgnx-doctor-wm-test--bin nil "The temp bin of the running test.")
(defvar drgnx-doctor-wm-test--log nil "The log the fake tools write.")

(defmacro drgnx-doctor-wm-test--with (env &rest body)
  "Run BODY with ENV (a list of \"K=V\") as the only window-manager variables, an empty temp bin first on PATH
and `exec-path' (`drgnx-doctor-wm-test--tool' adds to it), a dead session bus and no D-Bus call."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "drgnx-doctor-wm" t))
          (drgnx-doctor-wm-test--bin (expand-file-name "bin" dir))
          (drgnx-doctor-wm-test--log (expand-file-name "log" dir))
          (exec-path (list drgnx-doctor-wm-test--bin))
          (process-environment
           (append ,env
                   drgnx-doctor-wm-test--vars
                   (list (concat "PATH=" drgnx-doctor-wm-test--bin ":/usr/bin:/bin")
                         "XDG_RUNTIME_DIR=/nonexistent/drgnx-test-xdg"
                         "DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/drgnx-test"
                         (concat "DRGNX_FAKE_WM_LOG=" drgnx-doctor-wm-test--log)
                         (concat "DRGNX_FAKE_WM_DIR=" (expand-file-name "test/fixtures/wm" drgnx-dir)))
                   process-environment)))
     (make-directory drgnx-doctor-wm-test--bin t)
     (require 'dbus nil t)
     (unwind-protect
         (cl-letf (((symbol-function 'x-window-property) (lambda (&rest _) nil))
                   ((symbol-function 'dbus-call-method) (lambda (&rest _) (error "Isolated test: no bus"))))
           ,@body)
       (delete-directory dir t))))

(defun drgnx-doctor-wm-test--fake (name)
  "NAME in the temp bin: the fake window-manager tool."
  (make-symbolic-link (expand-file-name "test/fixtures/wm/fake-wm.sh" drgnx-dir)
                      (expand-file-name name drgnx-doctor-wm-test--bin)))

(defun drgnx-doctor-wm-test--script (name text)
  "NAME in the temp bin: a script that logs its call and prints TEXT."
  (let ((file (expand-file-name name drgnx-doctor-wm-test--bin)))
    (with-temp-file file
      (insert "#!/bin/sh\necho \"" name " $*\" >> \"$DRGNX_FAKE_WM_LOG\"\nprintf '%s\\n' '" text "'\n"))
    (set-file-modes file #o755)))

(defun drgnx-doctor-wm-test--calls ()
  (when (file-exists-p drgnx-doctor-wm-test--log)
    (with-temp-buffer (insert-file-contents drgnx-doctor-wm-test--log) (split-string (buffer-string) "\n" t))))

(defun drgnx-doctor-wm-test--row (&optional os)
  "The window-manager row (STATUS DETAIL FIX) for this test's environment, on OS (a fixture name, default fedora-45)."
  (let ((fixture (let ((system-type 'gnu/linux))
                   (drgnx-tty-os (expand-file-name (concat "test/fixtures/os-release/" (or os "fedora-45")) drgnx-dir)))))
    (cl-letf (((symbol-function 'drgnx-tty-os) (lambda (&rest _) fixture)))
      (drgnx-doctor-check 'window-manager (list :window-manager (drgnx-platform-doctor-facts))))))

(defconst drgnx-doctor-wm-test--sway '("WAYLAND_DISPLAY=wayland-test" "SWAYSOCK=/nonexistent/drgnx-test-sway.sock"))

(ert-deftest drgnx-doctor-wm/sway-with-two-monitors-is-ok ()
  (drgnx-doctor-wm-test--with (cons "DRGNX_FAKE_WM_MAP=get_outputs sway/get_outputs" drgnx-doctor-wm-test--sway)
    (drgnx-doctor-wm-test--fake "swaymsg")
    (drgnx-doctor-wm-test--script "sway" "sway version 1.10")
    (let ((f (drgnx-platform-doctor-facts)))
      (should (eq (plist-get f :wm) 'sway))
      (should (equal (plist-get f :version) "1.10"))
      (should (eql (plist-get f :monitors) 2))
      (should (equal (plist-get f :tool) "swaymsg"))
      (should (plist-get f :tool-found))
      (should (plist-get f :answers))
      (should (eq (plist-get f :can-move) t))
      (should (eq (plist-get f :status) 'verified)))
    (should (equal (drgnx-doctor-wm-test--row)
                   '(ok "sway 1.10, 2 monitors: Move to Monitor and restore work" nil)))
    ;; the version from sway's own flag (no IPC), and one read-only query per run
    (should (equal (seq-uniq (drgnx-doctor-wm-test--calls)) '("sway --version" "swaymsg -t get_outputs")))
    (should (= 2 (seq-count (lambda (c) (string-prefix-p "swaymsg" c)) (drgnx-doctor-wm-test--calls))))
    ;; the version and the count are left out when unknown
    (delete-file (expand-file-name "sway" drgnx-doctor-wm-test--bin))
    (let ((process-environment (cons "DRGNX_FAKE_WM_MAP=" process-environment)))
      (should (equal (drgnx-doctor-wm-test--row)
                     '(ok "sway: Move to Monitor and restore work" nil))))))

(ert-deftest drgnx-doctor-wm/gnome-is-ok-with-the-key ()
  (drgnx-doctor-wm-test--with '("WAYLAND_DISPLAY=wayland-test" "XDG_CURRENT_DESKTOP=ubuntu:GNOME")
    (should (equal (drgnx-doctor-wm-test--row)
                   '(ok "GNOME (Wayland): apps cannot move windows; use Super+Shift+←/→" nil)))))

(ert-deftest drgnx-doctor-wm/a-missing-tool-warns-with-this-systems-install-line ()
  (drgnx-doctor-wm-test--with drgnx-doctor-wm-test--sway
    (should (equal (drgnx-doctor-wm-test--row "fedora-45")
                   '(warn "sway: swaymsg not found: Move to Monitor and restore need it" "sudo dnf install sway")))
    (should (equal (nth 2 (drgnx-doctor-wm-test--row "debian-13")) "sudo apt install sway"))
    (should (equal (nth 2 (drgnx-doctor-wm-test--row "arch")) "sudo pacman -S sway"))
    (should (equal (nth 2 (drgnx-doctor-wm-test--row "unknown")) "install sway with your package manager")))
  (drgnx-doctor-wm-test--with '("WAYLAND_DISPLAY=wayland-test" "HYPRLAND_INSTANCE_SIGNATURE=test")
    (should (equal (drgnx-doctor-wm-test--row "arch")
                   '(warn "Hyprland: hyprctl not found: Move to Monitor and restore need it" "sudo pacman -S hyprland")))
    ;; Fedora's repositories have no Hyprland: no dnf line that would fail
    (should (equal (nth 2 (drgnx-doctor-wm-test--row "fedora-45")) "install hyprland with your package manager"))))

(ert-deftest drgnx-doctor-wm/a-silent-wm-warns-within-a-second ()
  (drgnx-doctor-wm-test--with (append '("DRGNX_FAKE_WM_DELAY=5" "DRGNX_FAKE_WM_MAP=get_outputs sway/get_outputs")
                                      drgnx-doctor-wm-test--sway)
    (drgnx-doctor-wm-test--fake "swaymsg")
    (drgnx-doctor-wm-test--script "sway" "sway version 1.10")
    (let* ((start (float-time)) (row (drgnx-doctor-wm-test--row)))
      (should (< (- (float-time) start) 1.5))
      (should (equal row '(warn "sway did not answer within 1 s" "run drgnx doctor from a terminal inside your sway session"))))))

(ert-deftest drgnx-doctor-wm/over-ssh-it-is-info ()
  (let ((info '(info "no graphical session here: run drgnx doctor in your desktop's terminal to check its window manager" nil)))
    (drgnx-doctor-wm-test--with '("SSH_CONNECTION=192.0.2.1 50000 192.0.2.2 22" "SSH_TTY=/dev/pts/3")
      (should (equal (drgnx-doctor-wm-test--row) info)))
    ;; over SSH with a forwarded display: still not the desktop this machine shows
    (drgnx-doctor-wm-test--with '("SSH_CONNECTION=192.0.2.1 50000 192.0.2.2 22" "DISPLAY=localhost:10.0")
      (should (equal (drgnx-doctor-wm-test--row) info)))
    ;; no display at all
    (drgnx-doctor-wm-test--with nil
      (should (equal (drgnx-doctor-wm-test--row) info)))))

(ert-deftest drgnx-doctor-wm/the-doctor-never-installs ()
  (drgnx-doctor-wm-test--with drgnx-doctor-wm-test--sway
    (dolist (p '("sudo" "dnf" "apt" "apt-get" "pacman" "rpm-ostree" "brew"))
      (drgnx-doctor-wm-test--script p ""))
    (should (eq (car (drgnx-doctor-wm-test--row)) 'warn))
    (let ((results (cl-letf (((symbol-function 'drgnx-tty-os) (lambda (&rest _) '(:system linux :ids ("fedora")))))
                     (drgnx-doctor-run (list :window-manager (drgnx-platform-doctor-facts)) nil "Desktop"))))
      (should (equal (mapcar (lambda (r) (plist-get r :name)) results) '(window-manager))))
    (should-not (drgnx-doctor-wm-test--calls))))

(ert-deftest drgnx-doctor-wm/x11-and-macos-move-by-frame-positions ()
  (drgnx-doctor-wm-test--with '("DISPLAY=:99")
    (drgnx-doctor-wm-test--script "xrandr" "Monitors: 2\n 0: +*DP-1 1920/527x1080/296+0+0  DP-1\n 1: +HDMI-1 1280/340x800/210+1920+0  HDMI-1")
    (should (equal (drgnx-doctor-wm-test--row)
                   '(ok "X11, 2 monitors: Move to Monitor and restore work (frame positions)" nil))))
  ;; no xrandr: X11 moves frames without it, the count is left out
  (drgnx-doctor-wm-test--with '("DISPLAY=:99")
    (should (equal (drgnx-doctor-wm-test--row)
                   '(ok "X11: Move to Monitor and restore work (frame positions)" nil))))
  (should (equal (drgnx-doctor-check 'window-manager
                                     '(:window-manager (:wm ns :title "macOS" :can-move t :frame-positions t)))
                 '(ok "macOS: Move to Monitor and restore work (frame positions)" nil))))

(ert-deftest drgnx-doctor-wm/drgnx-doctor-in-a-mac-terminal-is-macos ()
  ;; final review I4: `drgnx doctor' in Terminal.app is batch Emacs with no DISPLAY or WAYLAND_DISPLAY: the real
  ;; facts path (not a made-up plist) must still find macOS
  (drgnx-doctor-wm-test--with nil
    (let ((system-type 'darwin))
      (should (eq (plist-get (drgnx-platform-doctor-facts) :wm) 'ns))
      (should (eq (drgnx-platform-wm) 'ns))
      (should (equal (drgnx-doctor-wm-test--row)
                     '(ok "macOS: Move to Monitor and restore work (frame positions)" nil)))))
  ;; over SSH into a Mac it is still not the desktop in front of you
  (drgnx-doctor-wm-test--with '("SSH_CONNECTION=192.0.2.1 50000 192.0.2.2 22")
    (let ((system-type 'darwin))
      (should (eq (car (drgnx-doctor-wm-test--row)) 'info))))
  ;; and Linux without a display stays "no graphical session"
  (drgnx-doctor-wm-test--with nil
    (let ((system-type 'gnu/linux))
      (should (eq (plist-get (drgnx-platform-doctor-facts) :wm) 'none)))))

(ert-deftest drgnx-doctor-wm/another-wayland-compositor-is-info ()
  (drgnx-doctor-wm-test--with '("WAYLAND_DISPLAY=wayland-test" "XDG_CURRENT_DESKTOP=river")
    (should (equal (drgnx-doctor-wm-test--row)
                   '(info "river (Wayland): no adapter; drgnx leaves window placement to it" nil)))))

(ert-deftest drgnx-doctor-wm/kwin-without-a-session-bus-says-why ()
  (drgnx-doctor-wm-test--with '("WAYLAND_DISPLAY=wayland-test" "XDG_CURRENT_DESKTOP=KDE")
    (cl-letf (((symbol-function 'drgnx-platform-kwin--can-move) (lambda (_ctx) '("no session bus" . "start it"))))
      (should (equal (drgnx-doctor-wm-test--row) '(warn "KDE Plasma (KWin): no session bus" "start it"))))
    (cl-letf (((symbol-function 'drgnx-platform-kwin--can-move) (lambda (_ctx) t)))
      (drgnx-doctor-wm-test--script "kwin_wayland" "kwin 6.7.5")
      (should (equal (drgnx-doctor-wm-test--row)
                     '(ok "KDE Plasma (KWin) 6.7.5: Move to Monitor and restore work" nil))))))

(ert-deftest drgnx-doctor-wm/the-row-is-in-the-doctors-facts ()
  (drgnx-doctor-wm-test--with nil
    (let ((f (cl-letf (((symbol-function 'drgnx-doctor--search) #'ignore)) (drgnx-doctor-facts))))
      (should (eq (plist-get (plist-get f :window-manager) :wm) 'none))
      (should (member "Desktop" (mapcar (lambda (r) (plist-get r :group)) (drgnx-doctor-run f)))))))

;;; doctor-wm-test.el ends here
