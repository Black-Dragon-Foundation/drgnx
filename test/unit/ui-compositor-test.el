;;; ui-compositor-test.el --- batch tests: harness sessions under mutter, sway, Xvfb and i3 -*- lexical-binding: t -*-
;; No compositor is started: the WM tools are fake scripts on a temp `exec-path', state and runtime
;; directories are temporary, the caller's WM variables point at paths that do not exist.
(require 'ert)
(require 'seq)
(require 'drgnx-ui)
(require 'drgnx-ui-mcp)

(defconst drgnx-ui-compositor-test--fakes
  '(("sway" . "exit 0")
    ;; the args and the WM variables a client saw, as its JSON reply
    ;; (the command "fail" fails as swaymsg does: not JSON on stdout, the reason on stderr, exit 2)
    ;; ("late": the reason reaches stderr only once Emacs has reaped it — the order a loaded macOS runner gave)
    ("swaymsg" . "for last; do :; done; if [ \"$last\" = fail ]; then printf 'not json'; echo boom >&2; exit 2; fi
if [ \"$last\" = late ]; then (while kill -0 $$ 2>/dev/null; do :; done; echo late-boom >&2) & printf 'not json'; exit 2; fi
printf '{\"args\":\"%s\",\"swaysock\":\"%s\",\"i3sock\":\"%s\"}' \"$*\" \"${SWAYSOCK-unset}\" \"${I3SOCK-unset}\"")
    ("i3-msg" . "printf '{\"args\":\"%s\",\"swaysock\":\"%s\",\"i3sock\":\"%s\"}' \"$*\" \"${SWAYSOCK-unset}\" \"${I3SOCK-unset}\"")
    ("Xvfb" . "exit 0") ("xrandr" . "exit 0") ("i3" . "exit 0") ("emacs-lucid" . "exit 0")
    ("setpriv" . "exit 0") ("dbus-run-session" . "exit 0") ("kwin_wayland" . "exit 0") ("niri" . "exit 0"))
  "Fake programs: (NAME . SHELL BODY).")

(defun drgnx-ui-compositor-test--fake-bin (dir &optional names)
  "Make DIR hold the fake programs NAMES (default all); return DIR."
  (make-directory dir t)
  (dolist (f drgnx-ui-compositor-test--fakes)
    (when (or (null names) (member (car f) names))
      (let ((file (expand-file-name (car f) dir)))
        (write-region (concat "#!/bin/sh\n" (cdr f) "\n") nil file nil 'silent)
        (set-file-modes file #o755))))
  dir)

(defmacro drgnx-ui-compositor-test--with (&rest body)
  "BODY with `root' a fresh state root, `runtime' its XDG_RUNTIME_DIR, `xdir' where X servers keep their
locks, the fake programs first on `exec-path', no systemd unit active, and the caller's WM variables set to
paths no WM serves."
  (declare (indent 0))
  `(let* ((root (make-temp-file "duic" t))
          ;; short, as a real one is (/run/user/UID): sway's sockets go two levels below it, in 108 bytes
          (runtime (make-temp-file "/tmp/duic" t))
          (xdir (expand-file-name "x" root))
          (drgnx-ui--x11-dir xdir)
          (exec-path (cons (drgnx-ui-compositor-test--fake-bin (expand-file-name "bin" root)) exec-path))
          (process-environment (append (list (concat "DRGNX_UI_STATE=" root) (concat "XDG_RUNTIME_DIR=" runtime)
                                             "DRGNX_UI_COMPOSITOR" "DRGNX_UI_X11_EMACS"
                                             "SWAYSOCK=/nonexistent/caller-sway.sock"
                                             "I3SOCK=/nonexistent/caller-i3.sock")
                                       process-environment)))
     (set-file-modes runtime #o700)
     (make-directory (expand-file-name ".X11-unix" xdir) t)
     (unwind-protect
         (cl-letf (((symbol-function 'drgnx-ui-unit-active-p) #'ignore)) ,@body)
       (delete-directory runtime t)
       (delete-directory root t))))

(defun drgnx-ui-compositor-test--lines (file)
  (split-string (with-temp-buffer (insert-file-contents file) (buffer-string)) "\n" t))

(ert-deftest drgnx-ui-compositor/mutter-argv-is-unchanged ()
  (drgnx-ui-compositor-test--with
    (dolist (monitors '(nil 2))
      (let* ((name (if monitors "drgnx-ui-2-00000a" "drgnx-ui-1-00000a"))
             (s (drgnx-ui-prepare-run name nil "1024x768" root nil monitors))
             (env (drgnx-ui-session-env s)))
        (should (equal (plist-get s :compositor) "mutter"))
        (should (equal (drgnx-ui-compositor-argv s)
                       (append (list "dbus-run-session" "--" "mutter" "--headless" "--wayland" "--no-x11"
                                     "--wayland-display" name "--virtual-monitor" "1024x768")
                               (and monitors '("--virtual-monitor" "1024x768"))
                               (list "--" (drgnx-ui-emacs-bin) "--init-directory"
                                     (expand-file-name "init" (plist-get s :run)) "--fullscreen"))))
        (should (member (concat "XDG_RUNTIME_DIR=" runtime) env))
        (should-not (seq-find (lambda (kv) (string-match-p "\\`\\(WLR_\\|DISPLAY=\\)" kv)) env))
        (should (equal (drgnx-ui--display-env s)
                       (list (concat "WAYLAND_DISPLAY=" name) (concat "XDG_RUNTIME_DIR=" runtime))))))))

(ert-deftest drgnx-ui-compositor/sway-config-places-outputs-side-by-side ()
  (drgnx-ui-compositor-test--with
    (let* ((s (drgnx-ui-prepare-run "drgnx-ui-1-00000a" nil "1280x800" root nil 2 "sway"))
           (conf (expand-file-name "sway.conf" (plist-get s :run)))
           (lines (drgnx-ui-compositor-test--lines conf))
           (exec (seq-find (lambda (l) (string-prefix-p "exec " l)) lines)))
      (should (equal (drgnx-ui-compositor-argv s) (list "dbus-run-session" "--" "sway" "-c" conf)))
      (should (member "output HEADLESS-1 resolution 1280x800 position 0 0" lines))
      (should (member "output HEADLESS-2 resolution 1280x800 position 1280 0" lines))
      (should (member "default_border none" lines))
      (should (string-search (expand-file-name "init" (plist-get s :run)) exec))
      (should (string-match-p "swaymsg exit\"?\\'" exec))
      (should-not (string-search "--fullscreen" exec))         ; sway tiles it
      (should-not (string-search "--fg-daemon" exec))
      (should-not (seq-find (lambda (l) (string-match-p "\\`\\(include\\|bar\\)\\_>\\|~" l)) lines)))
    ;; a daemon session: no frame until a client asks
    (let ((s (drgnx-ui-prepare-run "drgnx-ui-2-00000a" nil "1280x800" root t nil "sway")))
      (should (string-search "--fg-daemon; swaymsg exit"
                             (seq-find (lambda (l) (string-prefix-p "exec " l))
                                       (drgnx-ui-compositor-test--lines
                                        (expand-file-name "sway.conf" (plist-get s :run)))))))))

(ert-deftest drgnx-ui-compositor/sway-has-its-own-runtime-dir ()
  (drgnx-ui-compositor-test--with
    (let* ((s (drgnx-ui-prepare-run "drgnx-ui-1-00000a" nil "1280x800" root nil 2 "sway"))
           (xdg (plist-get s :xdg_runtime_dir))
           (env (drgnx-ui-session-env s)))
      (should (file-directory-p xdg))
      (should (= (file-modes xdg) #o700))
      (should (<= (string-bytes xdg) 100))
      (should (string-prefix-p (file-name-as-directory (drgnx-ui-socket-dir "" root)) xdg))
      (should (member (concat "XDG_RUNTIME_DIR=" xdg) env))
      (should-not (member (concat "XDG_RUNTIME_DIR=" runtime) env))
      (dolist (kv '("WLR_BACKENDS=headless" "WLR_RENDERER=pixman" "WLR_LIBINPUT_NO_DEVICES=1" "WLR_HEADLESS_OUTPUTS=2"))
        (should (member kv env)))
      ;; a client reaches the session's own Wayland display, never the caller's X display
      (write-region "" nil (expand-file-name "wayland-1" xdg))
      (should (equal (drgnx-ui--display-env s) (list "WAYLAND_DISPLAY=wayland-1" (concat "XDG_RUNTIME_DIR=" xdg) "DISPLAY")))
      ;; stop removes it: no sway serves it
      (drgnx-ui-stop "drgnx-ui-1-00000a")
      (should-not (file-exists-p xdg)))))

(ert-deftest drgnx-ui-compositor/kwin-runs-virtual-outputs-with-its-own-runtime-and-config ()
  (drgnx-ui-compositor-test--with
    (let* ((s (drgnx-ui-prepare-run "drgnx-ui-1-00000a" nil "1280x800" root nil 2 "kwin"))
           (run (plist-get s :run))
           (xdg (plist-get s :xdg_runtime_dir))
           (env (drgnx-ui-session-env s)))
      ;; its own bus; KWin lives as long as the session's Emacs
      (should (equal (drgnx-ui-compositor-argv s)
                     (list "dbus-run-session" "--" "kwin_wayland" "--virtual" "--width" "1280" "--height" "800"
                           "--output-count" "2" "--socket" "wayland-1" "--no-lockscreen" "--no-global-shortcuts"
                           "--exit-with-session"
                           (concat (drgnx-ui-emacs-bin) " --init-directory " (expand-file-name "init" run)))))
      (should (file-directory-p xdg))
      (should (= (file-modes xdg) #o700))
      (should (member (concat "XDG_RUNTIME_DIR=" xdg) env))
      ;; what Plasma sets (drgnx detects KWin by it); KWin's config, data and cache in the run directory, never ~
      (dolist (kv (list "XDG_CURRENT_DESKTOP=KDE" "KDE_FULL_SESSION=true" "XDG_SESSION_TYPE=wayland"
                        (concat "XDG_CONFIG_HOME=" (expand-file-name "xdg/config" run))
                        (concat "XDG_DATA_HOME=" (expand-file-name "xdg/data" run))
                        (concat "XDG_CACHE_HOME=" (expand-file-name "xdg/cache" run))
                        (concat "MESA_SHADER_CACHE_DIR=" (expand-file-name "xdg/cache/mesa" run))))
        (should (member kv env)))
      (should-not (seq-find (lambda (kv) (string-match-p "\\`\\(WAYLAND_\\)?DISPLAY=" kv)) env))
      ;; a client reaches KWin's own display, in the session's runtime directory, once it is there
      (should-error (drgnx-ui--display-env s) :type 'drgnx-ui-error)
      (write-region "" nil (expand-file-name "wayland-1" xdg))
      (should (equal (drgnx-ui--display-env s) (list "WAYLAND_DISPLAY=wayland-1" (concat "XDG_RUNTIME_DIR=" xdg) "DISPLAY")))
      (drgnx-ui-stop "drgnx-ui-1-00000a")
      (should-not (file-exists-p xdg)))
    ;; a daemon: Emacs has no frame until a client asks; one output by default
    (let ((argv (drgnx-ui-compositor-argv (drgnx-ui-prepare-run "drgnx-ui-2-00000a" nil "800x600" root t nil "kwin"))))
      (should (equal (cadr (member "--output-count" argv)) "1"))
      (should (string-suffix-p " --fg-daemon" (car (last argv)))))))

(ert-deftest drgnx-ui-compositor/a-new-frame-gets-none-of-the-callers-wm-variables ()
  ;; server.el gives a frame its client's environment and drgnx reads the WM variables from the frame first: the
  ;; emacsclient of `ui frame' carries the allowlist and the session's display, nothing else of the caller's
  (drgnx-ui-compositor-test--with
    (dolist (c '("kwin" "niri" "sway" "x11"))
      (let* ((s (drgnx-ui-prepare-run (format "drgnx-ui-%d-00000a" (1+ (seq-position '("kwin" "niri" "sway" "x11") c)))
                                      nil "1280x800" root nil nil c))
             (xdg (plist-get s :xdg_runtime_dir))
             (caller '("SWAYSOCK=/user/sway.sock" "I3SOCK=/user/i3.sock" "NIRI_SOCKET=/user/niri.sock"
                       "HYPRLAND_INSTANCE_SIGNATURE=user" "XDG_CURRENT_DESKTOP=GNOME" "XDG_SESSION_TYPE=x11"
                       "DBUS_SESSION_BUS_ADDRESS=unix:path=/user/bus" "WAYLAND_DISPLAY=wayland-0" "DISPLAY=:0"
                       "XAUTHORITY=/user/xauth" "SECRET_TOKEN=x" "HOME=/home/caller"))
             (process-environment (append caller process-environment))
             (visible 0) seen)
        (write-region "" nil (expand-file-name "wayland-1" xdg))
        (write-region "" nil (expand-file-name "niri.wayland-2.42.sock" xdg))
        (cl-letf (((symbol-function 'drgnx-ui-call)
                   (lambda (_s form &rest _) (and (string-search "gui-frames" form) (list :visible (cl-incf visible)))))
                  ((symbol-function 'drgnx-ui--run-with-timeout)
                   (lambda (&rest _) (setq seen process-environment) (list 0 ""))))
          (should (eql 0 (plist-get (drgnx-ui-new-frame s 2) :exit))))
        (should (member (concat "HOME=" (expand-file-name "home" (plist-get s :run))) seen))   ; the run's, not the caller's
        (dolist (kv caller) (should-not (member kv seen)))
        (should-not (seq-find (lambda (kv) (string-match-p "\\`\\(SWAYSOCK\\|I3SOCK\\|NIRI_SOCKET\\|HYPRLAND_INSTANCE_SIGNATURE\\|XDG_CURRENT_DESKTOP\\|XDG_SESSION_TYPE\\|DBUS_SESSION_BUS_ADDRESS\\|SECRET_TOKEN\\)=" kv))
                              seen))
        (if (equal c "x11")
            (should (member (concat "DISPLAY=" (plist-get s :display)) seen))
          (should (member (concat "XDG_RUNTIME_DIR=" xdg) seen))
          (should (member (if (equal c "niri") "WAYLAND_DISPLAY=wayland-2" "WAYLAND_DISPLAY=wayland-1") seen)))))))

(ert-deftest drgnx-ui-compositor/niri-runs-nested-in-sway-with-one-output ()
  (drgnx-ui-compositor-test--with
    (let* ((s (drgnx-ui-prepare-run "drgnx-ui-1-00000a" nil "1280x800" root nil nil "niri"))
           (run (plist-get s :run))
           (xdg (plist-get s :xdg_runtime_dir))
           (conf (expand-file-name "sway.conf" run))
           (lines (drgnx-ui-compositor-test--lines conf))
           (kdl (drgnx-ui-compositor-test--lines (expand-file-name "niri.kdl" run)))
           (script (drgnx-ui-compositor-test--lines (expand-file-name "niri-session.sh" run)))
           (env (drgnx-ui-session-env s)))
      ;; sway (headless, one output) runs niri, which runs Emacs; each ends when what it runs ends
      (should (equal (drgnx-ui-compositor-argv s) (list "dbus-run-session" "--" "sway" "-c" conf)))
      (should (member "output HEADLESS-1 resolution 1280x800 position 0 0" lines))
      (should-not (seq-find (lambda (l) (string-prefix-p "output HEADLESS-2" l)) lines))
      (should (member (format "exec \"niri -c %s; swaymsg exit\"" (expand-file-name "niri.kdl" run)) lines))
      (should (member "WLR_HEADLESS_OUTPUTS=1" env))
      ;; niri's GL (and Mesa's shader cache) writes nothing to the real ~/.cache
      (dolist (kv (list (concat "XDG_CACHE_HOME=" (expand-file-name "xdg/cache" run))
                        (concat "MESA_SHADER_CACHE_DIR=" (expand-file-name "xdg/cache/mesa" run))))
        (should (member kv env)))
      (should (member (concat "XDG_RUNTIME_DIR=" xdg) env))
      (should (member (format "spawn-at-startup \"sh\" %S" (expand-file-name "niri-session.sh" run)) kdl))
      ;; no X server in the shared /tmp, nothing shown over the window
      (dolist (l '("xwayland-satellite { off; }" "hotkey-overlay { skip-at-startup; }"))
        (should (member l kdl)))
      ;; Emacs sees niri, not the sway around it, and niri quits after Emacs
      (should (member "unset SWAYSOCK I3SOCK" script))
      (should (seq-find (lambda (l) (string-search (expand-file-name "init" run) l)) script))
      (should (member "niri msg action quit --skip-confirmation" script))
      ;; a frame goes to niri's display (the one its IPC socket names), never to sway's
      (write-region "" nil (expand-file-name "wayland-1" xdg))
      (should-error (drgnx-ui--display-env s) :type 'drgnx-ui-error)
      (write-region "" nil (expand-file-name "niri.wayland-2.4242.sock" xdg))
      (should (equal (drgnx-ui--display-env s) (list "WAYLAND_DISPLAY=wayland-2" (concat "XDG_RUNTIME_DIR=" xdg) "DISPLAY"))))
    ;; niri has one output here: two monitors are refused before anything is made
    (should (string-match-p "one output"
                            (cadr (should-error (drgnx-ui-prepare-run "drgnx-ui-2-00000a" nil "1280x800" root nil 2 "niri")
                                                :type 'drgnx-ui-error))))
    (should-not (file-exists-p (expand-file-name "drgnx-ui-2-00000a" root)))))

(ert-deftest drgnx-ui/emacs-bin-order ()
  (let* ((dir (make-temp-file "drgnx-ui-bin" t))
         (data (expand-file-name "data" dir)) (bindir (expand-file-name "bin" dir))
         (rec (expand-file-name "rec" dir))
         (process-environment (append (list (concat "DRGNX_DATA_DIR=" data) (concat "DRGNX_CONFIG_DIR=" dir "/config")
                                            "DRGNX_EMACS")
                                      process-environment))
         (exec-path (list bindir)))
    (unwind-protect
        (progn
          (make-directory data) (make-directory bindir)
          (should (equal (drgnx-ui-emacs-bin) (drgnx-emacs-program)))
          (let ((pgtk (expand-file-name "emacs-pgtk" bindir)) (nid (expand-file-name "nidhogg" bindir)))
            (dolist (f (list pgtk nid rec)) (write-region "#!/bin/sh\n" nil f) (set-file-modes f #o755))
            (delete-file nid)
            (should (equal (drgnx-ui-emacs-bin) pgtk))
            (write-region "#!/bin/sh\n" nil nid) (set-file-modes nid #o755)
            (should (equal (drgnx-ui-emacs-bin) nid))
            (write-region (concat rec "\n") nil (expand-file-name "emacs" data))
            (should (equal (drgnx-ui-emacs-bin) rec)))
          (setenv "DRGNX_EMACS" "/opt/chosen")
          (should (equal (drgnx-ui-emacs-bin) "/opt/chosen")))
      (delete-directory dir t))))

(ert-deftest drgnx-ui-compositor/kwin-and-niri-take-only-plain-paths ()
  (drgnx-ui-compositor-test--with
    ;; KWin splits its session command at spaces
    (let ((process-environment (cons "DRGNX_EMACS=/opt/my emacs/emacs" process-environment)))
      (should-error (drgnx-ui-prepare-run "drgnx-ui-1-00000a" nil "800x600" root nil nil "kwin") :type 'drgnx-ui-error))
    ;; niri's config holds the run directory in a string
    (let ((odd (make-temp-file "duic\"q" t)))
      (unwind-protect
          (should-error (drgnx-ui-prepare-run "drgnx-ui-2-00000a" nil "800x600" odd nil nil "niri") :type 'drgnx-ui-error)
        (delete-directory odd t)))))

(defun drgnx-ui-compositor-test--dead-pid ()
  "The pid of a process that has ended."
  (let ((p (make-process :name "dead" :command '("true") :noquery t)))
    (while (process-live-p p) (accept-process-output p 0.01))
    (process-id p)))

(ert-deftest drgnx-ui-compositor/x11-picks-a-free-display-and-two-monitors ()
  (drgnx-ui-compositor-test--with
    ;; :90 has a lock, :91 a socket: taken by an X server we do not know
    (write-region "" nil (expand-file-name ".X90-lock" xdir))
    (write-region "" nil (expand-file-name ".X11-unix/X91" xdir))
    ;; :92 is reserved by a session whose run directory is gone (it crashed): taken over
    (make-directory (expand-file-name "92" (drgnx-ui--display-reservations)) t)
    (write-region "/nonexistent/drgnx-ui-9-00000a" nil (expand-file-name "92/owner" (drgnx-ui--display-reservations)))
    (let* ((s (drgnx-ui-prepare-run "drgnx-ui-1-00000a" nil "1024x768" root nil 2 "x11"))
           (run (plist-get s :run))
           (argv (drgnx-ui-compositor-argv s))
           (script (nth 4 argv)))
      (should (equal (plist-get s :display) ":92"))
      (should (equal (drgnx-ui--reservation-owner 92) run))
      (should (equal (seq-take argv 4) '("dbus-run-session" "--" "sh" "-c")))   ; a bus of its own
      (should (string-search "setpriv --pdeathsig KILL Xvfb :92 -noreset " script))
      (should (string-search (concat "-auth " (expand-file-name "Xauthority" run)) script))
      (should (string-search (concat "-displayfd 3 ") script))
      (should (string-search (concat "3>" (expand-file-name "xvfb.ready" run)) script))
      (should (string-search "-screen 0 2048x768x24" script))
      (should (string-match-p "--setmonitor XVFB-1 1024/[0-9]+x768/[0-9]+\\+0\\+0 screen" script))
      (should (string-match-p "--setmonitor XVFB-2 1024/[0-9]+x768/[0-9]+\\+1024\\+0 none" script))
      ;; nothing of the user's X resources (~/.Xdefaults, $XENVIRONMENT)
      (should (string-search (concat (drgnx-ui-x11-emacs-bin) " --no-x-resources --init-directory "
                                     (expand-file-name "init" run))
                             script))
      (should-not (string-search "i3" script))
      ;; the cookie: only the session's programs reach the display
      (let ((xa (expand-file-name "Xauthority" run)))
        (should (= (file-modes xa) #o600))
        (should (= (file-attribute-size (file-attributes xa)) 46))
        (should (string-search "MIT-MAGIC-COOKIE-1" (with-temp-buffer (insert-file-contents-literally xa) (buffer-string)))))
      (let ((env (drgnx-ui-session-env s))
            (xdg (drgnx-ui-session-runtime-dir "drgnx-ui-1-00000a")))
        (should (member "DISPLAY=:92" env))
        (should (member (concat "XAUTHORITY=" (expand-file-name "Xauthority" run)) env))
        ;; never the caller's runtime directory (its bus, its Wayland display)
        (should (member (concat "XDG_RUNTIME_DIR=" xdg) env))
        (should-not (member (concat "XDG_RUNTIME_DIR=" runtime) env))
        (should (= (file-modes xdg) #o700))
        (should-not (seq-find (lambda (kv) (string-prefix-p "WAYLAND_DISPLAY" kv)) env)))
      (should (equal (drgnx-ui--display-env s)
                     (list "DISPLAY=:92" (concat "XAUTHORITY=" (expand-file-name "Xauthority" run)) "WAYLAND_DISPLAY")))
      ;; the next session does not take :92 before its Xvfb runs; nor does one of another state root
      (let* ((s2 (drgnx-ui-prepare-run "drgnx-ui-2-00000a" nil "1024x768" root nil 1 "i3"))
             (script2 (nth 4 (drgnx-ui-compositor-argv s2)))
             (conf (expand-file-name "i3.conf" (plist-get s2 :run))))
        (should (equal (plist-get s2 :display) ":93"))
        (should (string-search (concat "setpriv --pdeathsig KILL i3 -c " conf) script2))
        (should (member (concat "ipc-socket " (drgnx-ui--i3-socket "drgnx-ui-2-00000a")) (drgnx-ui-compositor-test--lines conf)))
        (should-not (seq-find (lambda (l) (string-match-p "\\`bar\\_>" l)) (drgnx-ui-compositor-test--lines conf))))
      (should (equal (plist-get (drgnx-ui-prepare-run "drgnx-ui-1-00000a" nil "800x600" (expand-file-name "other" root)
                                                      nil nil "x11")
                                :display)
                     ":94"))
      ;; stop removes the socket and lock its own Xvfb left when it was killed (it had listened on :92: -displayfd
      ;; wrote the number), and the reservation
      (write-region (number-to-string (drgnx-ui-compositor-test--dead-pid)) nil (expand-file-name "xvfb.pid" run))
      (write-region "92\n" nil (expand-file-name "xvfb.ready" run))
      (dolist (f (drgnx-ui--x11-files 92)) (write-region "" nil f))
      (drgnx-ui-stop "drgnx-ui-1-00000a")
      (should-not (seq-some #'file-exists-p (drgnx-ui--x11-files 92)))
      (should-not (drgnx-ui--reservation-owner 92))
      ;; a session whose Xvfb never ran leaves the files of :93 alone (not its own), gives the number back
      (dolist (f (drgnx-ui--x11-files 93)) (write-region "" nil f))
      (drgnx-ui-stop "drgnx-ui-2-00000a")
      (should (seq-every-p #'file-exists-p (drgnx-ui--x11-files 93)))
      (should-not (drgnx-ui--reservation-owner 93)))))

(ert-deftest drgnx-ui-compositor/a-forged-display-is-never-cleaned-or-used ()
  ;; session.json is not trusted: a display the harness did not reserve for that session is neither used for a
  ;; frame nor cleaned up, even with a dead xvfb.pid
  (drgnx-ui-compositor-test--with
    (write-region "" nil (expand-file-name ".X11-unix/X91" xdir))
    (write-region "" nil (expand-file-name ".X5-lock" xdir))
    (dolist (forged '(":91" ":5"))
      (let* ((s (drgnx-ui-prepare-run "drgnx-ui-3-00000a" nil "800x600" root nil nil "x11"))
             (run (plist-get s :run))
             (json (expand-file-name "session.json" run))
             (sess (plist-put (drgnx-ui--read-json json) :display forged)))
        (drgnx-ui--write json (drgnx-ui--json sess))
        (write-region (number-to-string (drgnx-ui-compositor-test--dead-pid)) nil (expand-file-name "xvfb.pid" run))
        (write-region (substring forged 1) nil (expand-file-name "xvfb.ready" run))
        (should-error (drgnx-ui--display-env sess) :type 'drgnx-ui-error)
        (drgnx-ui-stop "drgnx-ui-3-00000a")))
    (should (file-exists-p (expand-file-name ".X11-unix/X91" xdir)))
    (should (file-exists-p (expand-file-name ".X5-lock" xdir)))))

(ert-deftest drgnx-ui-compositor/an-xvfb-that-never-listened-leaves-the-displays-files ()
  ;; Xvfb failed to bind :N (another server took it after the reservation): its pid is dead and xvfb.ready is
  ;; empty — the files on :N are the other server's, and stay
  (drgnx-ui-compositor-test--with
    (let* ((s (drgnx-ui-prepare-run "drgnx-ui-1-00000a" nil "800x600" root nil nil "x11"))
           (run (plist-get s :run)))
      (should (equal (plist-get s :display) ":90"))
      (write-region (number-to-string (drgnx-ui-compositor-test--dead-pid)) nil (expand-file-name "xvfb.pid" run))
      (write-region "" nil (expand-file-name "xvfb.ready" run))
      (dolist (f (drgnx-ui--x11-files 90)) (write-region "" nil f))
      (drgnx-ui-stop "drgnx-ui-1-00000a")
      (should (seq-every-p #'file-exists-p (drgnx-ui--x11-files 90)))
      (should-not (drgnx-ui--reservation-owner 90)))))           ; the number is given back all the same

(ert-deftest drgnx-ui-compositor/two-starts-taking-over-one-stale-reservation-get-it-once ()
  (drgnx-ui-compositor-test--with
    (let* ((dir (drgnx-ui--display-reservations))
           (a (expand-file-name "a" root)) (b (expand-file-name "b" root))
           (drgnx-ui--reservation-lock-wait 0.2)
           inner)
      (make-directory a) (make-directory b)
      (make-directory (expand-file-name "95" dir) t)
      (write-region "/nonexistent/drgnx-ui-9-00000a" nil (expand-file-name "95/owner" dir))
      ;; both found 95 stale; B tries while A is inside the takeover (between delete and its owner write)
      (should (drgnx-ui--reservation-stale-p 95))
      (let ((orig (symbol-function 'drgnx-ui--write)))
        (cl-letf (((symbol-function 'drgnx-ui--write)
                   (lambda (file text)
                     (unless inner (setq inner (list (drgnx-ui--take-over-reservation 95 b))))
                     (funcall orig file text))))
          (should (drgnx-ui--take-over-reservation 95 a))))
      (should (equal inner '(nil)))                             ; the lock kept B out
      (should-not (drgnx-ui--take-over-reservation 95 b))       ; and after: 95 is A's, not stale
      (should (equal (drgnx-ui--reservation-owner 95) a))
      (should-not (file-exists-p (expand-file-name ".lock" dir)))
      ;; a lock left by a crashed start (older than 10 s) does not block the next one
      (make-directory (expand-file-name ".lock" dir))
      (set-file-times (expand-file-name ".lock" dir) (time-subtract nil 60))
      (delete-directory a t)
      (should (drgnx-ui--take-over-reservation 95 b))
      (should (equal (drgnx-ui--reservation-owner 95) b)))))

(ert-deftest drgnx-ui-compositor/a-session-json-naming-another-session-is-refused ()
  ;; the session's Emacs can write its session.json: a forged :name or :run must not steer frames or WM calls
  (drgnx-ui-compositor-test--with
    (let* ((s (drgnx-ui-prepare-run "drgnx-ui-1-00000a" nil "800x600" root nil nil "sway"))
           (json (expand-file-name "session.json" (plist-get s :run)))
           (server (drgnx-ui-compositor-test--socket (plist-get s :socket))))
      (unwind-protect
          (progn
            (should (equal (plist-get (drgnx-ui-own-session "drgnx-ui-1-00000a") :name) "drgnx-ui-1-00000a"))
            (dolist (forged (list (list :name "drgnx-ui-7-00000a")
                                  (list :name "../00000000/drgnx-ui-1-00000a")
                                  (list :run (expand-file-name "drgnx-ui-7-00000a" root))
                                  ;; M12c-2-2: a sway session saying mutter would get the caller's runtime dir
                                  (list :compositor "mutter")))
              (drgnx-ui--write json (drgnx-ui--json (apply #'plist-put (copy-sequence s) forged)))
              (should-error (drgnx-ui-own-session "drgnx-ui-1-00000a") :type 'drgnx-ui-refused)))
        (delete-process server)))))

(ert-deftest drgnx-ui-compositor/odd-paths-never-reach-a-wm-config ()
  (drgnx-ui-compositor-test--with
    ;; a newline in a path would add a line to sway's config
    (let ((process-environment (cons (concat "DRGNX_EMACS=/opt/e\nexec rm -rf x/emacs") process-environment)))
      (should-error (drgnx-ui-prepare-run "drgnx-ui-1-00000a" nil "800x600" root nil nil "sway") :type 'drgnx-ui-error))
    ;; an i3 socket path i3 cannot take as it is: the start fails and gives its display number back
    (let* ((odd (make-temp-file "/tmp/duic sp" t))
           (process-environment (cons (concat "XDG_RUNTIME_DIR=" odd) process-environment)))
      (unwind-protect
          (progn
            (set-file-modes odd #o700)
            (should-error (drgnx-ui-prepare-run "drgnx-ui-2-00000a" nil "800x600" root nil nil "i3") :type 'drgnx-ui-error)
            (should-not (drgnx-ui--reservation-owner 90)))
        (delete-directory odd t)))))

(ert-deftest drgnx-ui-compositor/the-belt-and-braces-kill-matches-only-its-own-run ()
  (let ((re (drgnx-ui--name-pattern "drgnx-ui-test-12-3"))
        (grep (lambda (re line) (with-temp-buffer
                                  (insert line)
                                  (eq 0 (call-process-region (point-min) (point-max) "grep" nil nil nil "-qE" "--" re))))))
    (should (funcall grep re "sway -c /s/drgnx-ui-test-12-3/sway.conf"))
    (should (funcall grep re "emacs --init-directory /s/drgnx-ui-test-12-3/init"))
    (should (funcall grep re "Xvfb :90 -auth /s/drgnx-ui-test-12-3 -x"))
    (should-not (funcall grep re "sway -c /s/drgnx-ui-test-12-34/sway.conf"))
    (should-not (funcall grep re "vi notes-drgnx-ui-test-12-3.txt"))))

(ert-deftest drgnx-ui-compositor/a-missing-compositor-says-the-container-command ()
  (drgnx-ui-compositor-test--with
    (let ((exec-path (list (drgnx-ui-compositor-test--fake-bin (expand-file-name "few" root) '("Xvfb" "xrandr" "emacs-lucid")))))
      (dolist (c '(("sway" . "sway is not installed here: run bin/drgnx test --container --ui --compositor sway")
                   ("i3" . "i3 is not installed here: run bin/drgnx test --container --ui --compositor i3")
                   ("kwin" . "kwin_wayland is not installed here: run bin/drgnx test --container --ui --compositor kwin")
                   ("niri" . "sway is not installed here: run bin/drgnx test --container --ui --compositor niri")))
        (let ((err (should-error (drgnx-ui-prepare-run "drgnx-ui-1-00000a" nil nil root nil nil (car c)) :type 'drgnx-ui-error)))
          (should (equal (cadr err) (cdr c)))))
      (let ((exec-path (list (expand-file-name "few" root) (expand-file-name "nothing" root))))
        (delete-file (expand-file-name "few/Xvfb" root))
        (should (equal (cadr (should-error (drgnx-ui-prepare-run "drgnx-ui-1-00000a" nil nil root nil nil "x11")))
                       "Xvfb is not installed here: run bin/drgnx test --container --ui --compositor x11")))
      (should-error (drgnx-ui-prepare-run "drgnx-ui-1-00000a" nil nil root nil nil "weston") :type 'drgnx-ui-error)
      (should-not (file-exists-p (expand-file-name "drgnx-ui-1-00000a" root))))))   ; nothing was made

(ert-deftest drgnx-ui-compositor/the-default-comes-from-the-environment ()
  (dolist (c '(("sway" . "sway") ("x11" . "x11") ("i3" . "i3") ("kwin" . "kwin") ("niri" . "niri")
               ("mutter" . "mutter") ("bogus" . "mutter")
               ("" . "mutter") (nil . "mutter")))
    (let ((process-environment (cons (if (car c) (concat "DRGNX_UI_COMPOSITOR=" (car c)) "DRGNX_UI_COMPOSITOR")
                                     process-environment)))
      (should (equal (drgnx-ui-default-compositor) (cdr c)))))
  (drgnx-ui-compositor-test--with
    (let ((process-environment (cons "DRGNX_UI_COMPOSITOR=sway" process-environment)))
      (should (equal (plist-get (drgnx-ui-prepare-run "drgnx-ui-1-00000a" nil "800x600" root) :compositor) "sway")))))

(defun drgnx-ui-compositor-test--socket (path)
  "A listening Unix socket at PATH (a fake WM's); the server process."
  (make-network-process :name "fake-wm" :server t :family 'local :service path :noquery t))

(ert-deftest drgnx-ui-compositor/ui-wm-never-reads-the-callers-swaysock ()
  (drgnx-ui-compositor-test--with
    (let* ((s (drgnx-ui-prepare-run "drgnx-ui-1-00000a" nil "1280x800" root nil 2 "sway"))
           (sock (drgnx-ui--sway-socket "drgnx-ui-1-00000a"))
           (s2 (drgnx-ui-prepare-run "drgnx-ui-2-00000a" nil "1280x800" root nil 2 "i3"))
           (sock2 (drgnx-ui--i3-socket "drgnx-ui-2-00000a"))
           (servers (list (drgnx-ui-compositor-test--socket sock) (drgnx-ui-compositor-test--socket sock2))))
      (unwind-protect
          (progn
            ;; sway listens where the session's env pins it
            (should (member (concat "SWAYSOCK=" sock) (drgnx-ui-session-env s)))
            (should (equal (file-name-directory sock) (file-name-as-directory (plist-get s :xdg_runtime_dir))))
            (let ((tree (plist-get (drgnx-ui-wm s) :tree)))
              (should (equal (plist-get (drgnx-ui-wm s) :wm) "sway"))
              (should (equal (plist-get tree :args) (concat "-s " sock " -t get_tree -r")))
              (should (equal (plist-get tree :swaysock) "unset"))
              (should (equal (plist-get tree :i3sock) "unset")))
            (should (equal (plist-get (drgnx-ui-wm-command s "output HEADLESS-2 disable") :args)
                           (concat "-s " sock " -r -- output HEADLESS-2 disable")))
            ;; a failure says what the tool printed on stderr
            (should (string-search "boom" (cadr (should-error (drgnx-ui-wm-command s "fail") :type 'drgnx-ui-error))))
            ;; all of it: stderr is a pipe of its own, read to its end after the tool exited
            (let ((msg (cadr (should-error (drgnx-ui-wm-command s "late") :type 'drgnx-ui-error))))
              (should (string-search "late-boom" msg))
              (should-not (string-search "finished" msg)))
            ;; i3: the socket its i3.conf names, not anything on the display
            (let ((tree (plist-get (drgnx-ui-wm s2) :tree)))
              (should (equal (plist-get tree :args) (concat "-s " sock2 " -t get_tree")))
              (should (equal (plist-get tree :i3sock) "unset")))
            ;; session.json says nothing about where the socket is: a forged runtime dir is not followed
            (should (equal (plist-get (plist-get (drgnx-ui-wm (plist-put (copy-sequence s) :xdg_runtime_dir "/nonexistent"))
                                                 :tree)
                                      :args)
                           (concat "-s " sock " -t get_tree -r")))
            ;; a symlink in the socket's place is refused, even to a real socket
            (let ((s5 (drgnx-ui-prepare-run "drgnx-ui-5-00000a" nil "800x600" root nil nil "sway")))
              (make-symbolic-link sock (drgnx-ui--sway-socket "drgnx-ui-5-00000a"))
              (should-error (drgnx-ui-wm s5) :type 'drgnx-ui-error)))
        (mapc #'delete-process servers)))
    ;; no WM to read
    (should (equal (drgnx-ui-wm (drgnx-ui-prepare-run "drgnx-ui-3-00000a" nil "800x600" root)) '(:wm "none")))
    (should (equal (drgnx-ui-wm (drgnx-ui-prepare-run "drgnx-ui-4-00000a" nil "800x600" root nil nil "x11")) '(:wm "none")))
    ;; KWin and niri are named; their window lists are not read
    (should (equal (drgnx-ui-wm (drgnx-ui-prepare-run "drgnx-ui-7-00000a" nil "800x600" root nil nil "kwin")) '(:wm "kwin")))
    (should (equal (drgnx-ui-wm (drgnx-ui-prepare-run "drgnx-ui-8-00000a" nil "800x600" root nil nil "niri")) '(:wm "niri")))
    ;; a sway session whose sway has not started has no socket: an error, never another sway
    (should-error (drgnx-ui-wm (drgnx-ui-prepare-run "drgnx-ui-6-00000a" nil "800x600" root nil nil "sway"))
                  :type 'drgnx-ui-error)))

(ert-deftest drgnx-ui-compositor/a-test-run-gets-a-scope-where-systemd-is ()
  (should (equal (drgnx-ui--test-run-argv "drgnx-ui-test-1-2" 110 nil "S") '("setsid" "-w" "sh" "-c" "S")))
  (let ((argv (drgnx-ui--test-run-argv "drgnx-ui-test-1-2" 110 t "S")))
    (should (equal (seq-take argv 4) '("systemd-run" "--user" "--scope" "--quiet")))
    (should (equal (cadr (member "--unit" argv)) "drgnx-ui-test-1-2"))
    (should (member "MemoryMax=3G" argv))
    (should (member "RuntimeMaxSec=170" argv))
    (should (equal (last argv 5) '("setsid" "-w" "sh" "-c" "S")))))

(ert-deftest drgnx-ui-compositor/a-bad-selector-fails-before-a-session-starts ()
  (let ((process-environment (cons "DRGNX_TEST_SELECTOR=(or \"^a/\"" process-environment)))
    (cl-letf (((symbol-function 'drgnx-ui-run-ert-session) (lambda (&rest _) (error "A session was started"))))
      (should (string-search "not an ERT selector"
                             (cadr (should-error (drgnx-ui-run-ui-session-tests) :type 'drgnx-ui-error)))))))

(ert-deftest drgnx-ui-compositor/pgrep-patterns-are-quoted-for-ere ()
  (let ((s "/tmp/a.b+c(d)[e]{f}|g^$\\h*?"))
    (should (equal (drgnx-ui--ere-quote s) "/tmp/a\\.b\\+c\\(d\\)\\[e\\]\\{f\\}\\|g\\^\\$\\\\h\\*\\?"))
    ;; grep -E agrees: the quoted pattern matches the string itself
    (should (eq 0 (with-temp-buffer
                    (insert s)
                    (call-process-region (point-min) (point-max) "grep" nil nil nil "-qE" "--"
                                         (concat "^" (drgnx-ui--ere-quote s) "$")))))))

(ert-deftest drgnx-ui-compositor/the-mcp-lists-ui-wm-and-compositor ()
  (let* ((tools (append (plist-get (plist-get (drgnx-ui-mcp-handle '(:jsonrpc "2.0" :id 1 :method "tools/list")) :result)
                                   :tools)
                        nil))
         (wm (seq-find (lambda (tl) (equal (plist-get tl :name) "ui_wm")) tools))
         (start (seq-find (lambda (tl) (equal (plist-get tl :name) "ui_start")) tools)))
    (should wm)
    (should (string-match-p "\\`Read only" (plist-get wm :description)))
    (should (equal (plist-get (plist-get wm :inputSchema) :required) ["session"]))
    (should (equal (plist-get (plist-get (plist-get (plist-get start :inputSchema) :properties) :compositor) :enum)
                   (vconcat drgnx-ui-compositors))))
  ;; only the harness's own sessions
  (let ((r (plist-get (drgnx-ui-mcp-handle '(:jsonrpc "2.0" :id 2 :method "tools/call"
                                                      :params (:name "ui_wm" :arguments (:session "server"))))
                      :result)))
    (should (eq (plist-get r :isError) t))))

(defconst drgnx-ui-compositor-test--bin
  (expand-file-name "../../bin/drgnx" (file-name-directory (or load-file-name buffer-file-name))))

(defun drgnx-ui-compositor-test--bin-call (dir env &rest args)
  "Run bin/drgnx with ARGS in DIR, HOME and config there, ENV on top; return (EXIT . OUTPUT)."
  (let ((process-environment (append env (list (concat "HOME=" dir) (concat "DRGNX_CONFIG_DIR=" dir "/config")
                                               "DRGNX_EMACS" "DRGNX_UI_COMPOSITOR" "DRGNX_TEST_SELECTOR")
                                     process-environment))
        (default-directory (file-name-as-directory dir)))
    (with-temp-buffer (cons (apply #'call-process drgnx-ui-compositor-test--bin nil t nil args) (buffer-string)))))

(ert-deftest drgnx-ui-compositor/bin-test-container-ui-is-memory-capped ()
  (let* ((dir (make-temp-file "duic-bin" t))
         (log (expand-file-name "podman.log" dir))
         (path (expand-file-name "path" dir)))
    (unwind-protect
        (progn
          (make-directory path)
          ;; a fake podman: one line per argument, a "---" line per call
          ;; printf, not echo: echo takes "-e" for its own option
          (write-region (format "#!/bin/sh\necho --- >> %s\nfor a in \"$@\"; do printf '%%s\\n' \"$a\" >> %s; done\n" log log)
                        nil (expand-file-name "podman" path) nil 'silent)
          (set-file-modes (expand-file-name "podman" path) #o755)
          (let ((r (drgnx-ui-compositor-test--bin-call
                    dir (list (concat "PATH=" path ":/usr/bin:/bin") "DRGNX_CONTAINER=podman" "DRGNX_TEST_GUI_IMAGE=an-image"
                              "DRGNX_TEST_SELECTOR=\"^drgnx-wm/\"" "DRGNX_UI_COMPOSITOR=x11" "DRGNX_TEST_GUI_MEMORY")
                    "test" "--container" "--ui" "--compositor" "sway")))
            (should (eql (car r) 0)))
          (let* ((args (split-string (with-temp-buffer (insert-file-contents log) (buffer-string)) "\n" t))
                 (run (cdr (member "run" args))))
            (should run)
            ;; 3 GB and no swap on top
            (should (equal (cadr (member "--memory" run)) "3g"))
            (should (equal (cadr (member "--memory-swap" run)) "3g"))
            (dolist (kv '("DRGNX_TEST_SELECTOR=\"^drgnx-wm/\"" "DRGNX_UI_COMPOSITOR=x11"))
              (should (equal (nth (1- (or (seq-position run kv) 0)) run) "-e")))
            (should (equal (last run 5) '("bin/drgnx" "test" "--ui" "--compositor" "sway"))))
          ;; DRGNX_TEST_GUI_MEMORY overrides both
          (delete-file log)
          (drgnx-ui-compositor-test--bin-call
           dir (list (concat "PATH=" path ":/usr/bin:/bin") "DRGNX_CONTAINER=podman" "DRGNX_TEST_GUI_IMAGE=an-image"
                     "DRGNX_TEST_GUI_MEMORY=5g")
           "test" "--container" "--ui")
          (let ((run (cdr (member "run" (split-string (with-temp-buffer (insert-file-contents log) (buffer-string)) "\n" t)))))
            (should (equal (cadr (member "--memory" run)) "5g"))
            (should (equal (cadr (member "--memory-swap" run)) "5g")))
          ;; a compositor the harness does not know is refused before any container runs
          (delete-file log)
          (should (eql 2 (car (drgnx-ui-compositor-test--bin-call
                               dir (list (concat "PATH=" path ":/usr/bin:/bin") "DRGNX_CONTAINER=podman"
                                         "DRGNX_TEST_GUI_IMAGE=an-image")
                               "test" "--container" "--ui" "--compositor" "weston"))))
          (should-not (file-exists-p log)))
      (delete-directory dir t))))

(ert-deftest drgnx-ui-compositor/bin-test-container-kwin-and-niri-use-the-wm-image ()
  (let* ((dir (make-temp-file "duic-bin" t))
         (log (expand-file-name "podman.log" dir))
         (path (expand-file-name "path" dir)))
    (unwind-protect
        (progn
          (make-directory path)
          (write-region (format "#!/bin/sh\necho --- >> %s\nfor a in \"$@\"; do printf '%%s\\n' \"$a\" >> %s; done\n" log log)
                        nil (expand-file-name "podman" path) nil 'silent)
          (set-file-modes (expand-file-name "podman" path) #o755)
          (dolist (c '("kwin" "niri"))
            (when (file-exists-p log) (delete-file log))
            ;; the GUI image (mutter, sway, X11) has neither: its prebuilt override does not apply
            (should (eql 0 (car (drgnx-ui-compositor-test--bin-call
                                 dir (list (concat "PATH=" path ":/usr/bin:/bin") "DRGNX_CONTAINER=podman"
                                           "DRGNX_TEST_GUI_IMAGE=an-image" "DRGNX_TEST_GUI_MEMORY" "DRGNX_TEST_WM_IMAGE"
                                           "DRGNX_TEST_BUILD_MEMORY")
                                 "test" "--container" "--ui" "--compositor" c))))
            (let* ((args (split-string (with-temp-buffer (insert-file-contents log) (buffer-string)) "\n" t))
                   (build (cdr (member "build" args)))
                   (run (cdr (member "run" args))))
              (should (equal (cadr (member "-t" build)) "drgnx-test-wm:f45"))
              (should (string-suffix-p "test/container/Containerfile.wm" (cadr (member "-f" build))))
              (should (member "drgnx-test-wm:f45" run))
              ;; the build is capped too (an uncapped image build once took the whole session down)
              (should (equal (cadr (member "--memory" build)) "3g"))
              (should (equal (cadr (member "--memory-swap" build)) "3g"))
              (should (equal (cadr (member "--memory" run)) "3g"))
              (should (equal (cadr (member "--memory-swap" run)) "3g"))
              (should (equal (last run 5) (list "bin/drgnx" "test" "--ui" "--compositor" c)))))
          ;; its own prebuilt override
          (delete-file log)
          (drgnx-ui-compositor-test--bin-call
           dir (list (concat "PATH=" path ":/usr/bin:/bin") "DRGNX_CONTAINER=podman" "DRGNX_TEST_WM_IMAGE=wm-image")
           "test" "--container" "--ui" "--compositor" "kwin")
          (let ((args (split-string (with-temp-buffer (insert-file-contents log) (buffer-string)) "\n" t)))
            (should-not (member "build" args))
            (should (member "wm-image" args)))
          ;; DRGNX_UI_COMPOSITOR alone picks the image too; DRGNX_TEST_BUILD_MEMORY sizes every build
          (delete-file log)
          (should (eql 0 (car (drgnx-ui-compositor-test--bin-call
                               dir (list (concat "PATH=" path ":/usr/bin:/bin") "DRGNX_CONTAINER=podman"
                                         "DRGNX_UI_COMPOSITOR=niri" "DRGNX_TEST_BUILD_MEMORY=4g" "DRGNX_TEST_WM_IMAGE")
                               "test" "--container" "--ui"))))
          (let* ((args (split-string (with-temp-buffer (insert-file-contents log) (buffer-string)) "\n" t))
                 (build (cdr (member "build" args))))
            (should (equal (cadr (member "-t" build)) "drgnx-test-wm:f45"))
            (should (equal (cadr (member "--memory" build)) "4g"))
            (should (equal (cadr (member "--memory-swap" build)) "4g")))
          (delete-file log)
          (drgnx-ui-compositor-test--bin-call
           dir (list (concat "PATH=" path ":/usr/bin:/bin") "DRGNX_CONTAINER=podman" "DRGNX_TEST_BUILD_MEMORY=4g"
                     "DRGNX_UI_COMPOSITOR" "DRGNX_TEST_GUI_IMAGE")
           "test" "--container" "--ui")
          (let ((build (cdr (member "build" (split-string (with-temp-buffer (insert-file-contents log) (buffer-string)) "\n" t)))))
            (should (equal (cadr (member "-t" build)) "drgnx-test-gui:f45"))
            (should (equal (cadr (member "--memory" build)) "4g")))
          ;; an image override is an image reference, never an option for podman
          (delete-file log)
          (dolist (bad '(("DRGNX_TEST_WM_IMAGE=-v/:/host" "--ui" "--compositor" "kwin")
                         ("DRGNX_TEST_GUI_IMAGE=--privileged" "--ui")
                         ("DRGNX_TEST_IMAGE=a b")))
            (should (eql 2 (car (apply #'drgnx-ui-compositor-test--bin-call
                                       dir (list (concat "PATH=" path ":/usr/bin:/bin") "DRGNX_CONTAINER=podman" (car bad))
                                       "test" "--container" (cdr bad))))))
          (should-not (file-exists-p log)))
      (delete-directory dir t))))

(ert-deftest drgnx-ui-compositor/bin-test-ui-exports-the-compositor ()
  (let* ((dir (make-temp-file "duic-bin" t))
         (seen (expand-file-name "seen" dir))
         (emacs (expand-file-name "fake-emacs" dir)))
    (unwind-protect
        (progn
          (write-region (format "#!/bin/sh\necho \"${DRGNX_UI_COMPOSITOR-unset} $*\" > %s\n" seen) nil emacs nil 'silent)
          (set-file-modes emacs #o755)
          (should (eql 0 (car (drgnx-ui-compositor-test--bin-call dir (list (concat "DRGNX_EMACS=" emacs))
                                                                  "test" "--ui" "--compositor" "i3"))))
          (let ((line (with-temp-buffer (insert-file-contents seen) (buffer-string))))
            (should (string-prefix-p "i3 " line))
            (should (string-search "test-ui" line)))
          (dolist (c '("kwin" "niri"))
            (should (eql 0 (car (drgnx-ui-compositor-test--bin-call dir (list (concat "DRGNX_EMACS=" emacs))
                                                                    "test" "--ui" "--compositor" c))))
            (should (string-prefix-p (concat c " ") (with-temp-buffer (insert-file-contents seen) (buffer-string)))))
          (should (eql 2 (car (drgnx-ui-compositor-test--bin-call dir (list (concat "DRGNX_EMACS=" emacs))
                                                                  "test" "--ui" "--compositor" "bogus")))))
      (delete-directory dir t))))

;;; ui-compositor-test.el ends here
