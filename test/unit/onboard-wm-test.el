;;; onboard-wm-test.el --- batch tests: onboarding step 7 shows the doctor's Desktop row -*- lexical-binding: t -*-
;; Nothing touches the machine: config, state and data are temp dirs, PATH is an empty temp bin, no display and no
;; window-manager variable (unless a test sets one), nothing is asked and every program run is recorded.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-onboard)
(require 'drgnx-doctor)
(require 'drgnx-platform)
(require 'drgnx-tty)
(require 'drgnx-tty-recommend)

(defmacro onboard-wm-test--step-7 (env &rest body)
  "BODY with step 7's result in `result' and the programs run in `programs'; ENV (\"K=V\" strings) on top of no
display, no window manager, no SSH.  Linux, Fedora 45 (no Hyprland package there), without interaction."
  (declare (indent 1))
  `(let* ((system-type 'gnu/linux)        ; a Linux session (batch Emacs on macOS is the macOS adapter)
          (root (file-name-as-directory (make-temp-file "drgnx-onboard-wm" t)))
          (process-environment (append ,env
                                       (list (concat "DRGNX_CONFIG_DIR=" root "config") (concat "XDG_STATE_HOME=" root "state")
                                             (concat "DRGNX_DATA_DIR=" root "data") (concat "PATH=" root "bin")
                                             "DISPLAY" "WAYLAND_DISPLAY" "SWAYSOCK" "I3SOCK" "HYPRLAND_INSTANCE_SIGNATURE"
                                             "NIRI_SOCKET" "XDG_CURRENT_DESKTOP" "SSH_CONNECTION" "SSH_TTY"
                                             "DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/drgnx-test")
                                       process-environment))
          (exec-path (list (concat root "bin")))
          (drgnx-modules--state nil) (programs nil) result
          (call-process (symbol-function 'call-process))
          (fedora (let ((system-type 'gnu/linux))
                    (drgnx-tty-os (expand-file-name "test/fixtures/os-release/fedora-45" drgnx-dir)))))
     (make-directory (concat root "config") t)
     (make-directory (concat root "bin") t)
     (unwind-protect
         (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'linux))
                   ((symbol-function 'drgnx-tty-os) (lambda (&rest _) fedora))
                   ((symbol-function 'call-process)
                    (lambda (program &rest args) (push program programs) (apply call-process program args)))
                   ((symbol-function 'make-process)
                    (lambda (&rest args) (push (car (plist-get args :command)) programs) (error "No process here")))
                   ((symbol-function 'dbus-call-method) (lambda (&rest _) (error "No bus here")))
                   ((symbol-function 'y-or-n-p) (lambda (&rest _) (error "Asked")))
                   ((symbol-function 'yes-or-no-p) (lambda (&rest _) (error "Asked"))))
           (setq result (car (drgnx-onboard-run :only '(daemon) :non-interactive t)))
           ,@body)
       (delete-directory root t))))

(ert-deftest drgnx-onboard-wm/step-7-shows-the-desktop-row ()
  ;; no graphical session: the row's detail (info: no fix to show)
  (onboard-wm-test--step-7 nil
    (let ((message (nth 2 result)))
      (should (string-suffix-p (concat "; desktop: no graphical session here: run drgnx doctor in your desktop's "
                                       "terminal to check its window manager")
                               message))
      ;; keep-running; platform; terminal; window manager
      (let ((keep (string-search "drgnx keeps running in the background" message))
            (platform (string-search "written (not installed)" message))
            (terminal (string-search (drgnx-tty-onboard-note) message))
            (desktop (string-search "; desktop: " message)))
        (should (and keep platform terminal desktop))
        (should (< keep platform terminal desktop)))
      (should-not (seq-intersection programs '("dnf" "sudo" "rpm-ostree" "apt" "pacman" "brew" "hyprctl")))))
  ;; Hyprland without hyprctl: the warning, with its fix in parentheses
  (onboard-wm-test--step-7 '("WAYLAND_DISPLAY=wayland-test" "HYPRLAND_INSTANCE_SIGNATURE=test")
    (should (string-suffix-p (concat "; desktop: Hyprland: hyprctl not found: Move to Monitor and restore need it"
                                     " (install hyprland with your package manager)")
                             (nth 2 result)))
    (should-not programs))
  ;; GNOME: ok, so no fix is added
  (onboard-wm-test--step-7 '("WAYLAND_DISPLAY=wayland-test" "XDG_CURRENT_DESKTOP=GNOME")
    (should (string-suffix-p "; desktop: GNOME (Wayland): apps cannot move windows; use Super+Shift+←/→"
                             (nth 2 result)))))

;;; onboard-wm-test.el ends here
