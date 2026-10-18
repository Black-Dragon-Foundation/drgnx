;;; platform-test.el --- batch tests: window-manager adapters, detection, monitors, the async runner -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-paths)
(require 'drgnx-platform)

;;;; Helpers

(defconst drgnx-platform-test--wm-vars
  '("WAYLAND_DISPLAY" "DISPLAY" "SWAYSOCK" "I3SOCK" "HYPRLAND_INSTANCE_SIGNATURE" "NIRI_SOCKET"
    "XDG_CURRENT_DESKTOP" "XDG_SESSION_TYPE")
  "Never let a test see the session it runs in.")

(defmacro drgnx-platform-test--no-session (&rest body)
  "Run BODY with none of the window-manager variables of the real session."
  `(let ((process-environment (append drgnx-platform-test--wm-vars process-environment)))
     ,@body))

(defvar drgnx-platform-test--log nil "The fake tools' log file, inside `drgnx-platform-test--with-fake-wm'.")

(defmacro drgnx-platform-test--with-fake-wm (opts &rest body)
  "Run BODY with swaymsg, i3-msg, hyprctl and niri on PATH being test/fixtures/wm/fake-wm.sh.
OPTS: (:delay SECONDS :exit CODE :map \"ARGS-REGEXP FILE\\n...\").  `drgnx-platform-test--log' is the log file."
  (declare (indent 1))
  `(drgnx-platform-test--no-session
    (let* ((dir (make-temp-file "drgnx-fake-wm" t)) (bin (expand-file-name "bin" dir))
           (fixtures (expand-file-name "test/fixtures/wm" drgnx-dir))
           (drgnx-platform-test--log (expand-file-name "log" dir))
           (opts (list ,@opts))
           (exec-path (cons bin exec-path))
           (process-environment
            (append (list (concat "PATH=" bin ":" (getenv "PATH"))
                          (concat "DRGNX_FAKE_WM_LOG=" drgnx-platform-test--log)
                          (concat "DRGNX_FAKE_WM_DIR=" fixtures)
                          (concat "DRGNX_FAKE_WM_MAP=" (or (plist-get opts :map) ""))
                          (concat "DRGNX_FAKE_WM_DELAY=" (if (plist-get opts :delay) (format "%s" (plist-get opts :delay)) ""))
                          (concat "DRGNX_FAKE_WM_EXIT=" (format "%s" (or (plist-get opts :exit) 0))))
                    process-environment)))
      (make-directory bin t)
      (dolist (n '("swaymsg" "i3-msg" "hyprctl" "niri"))
        (make-symbolic-link (expand-file-name "fake-wm.sh" fixtures) (expand-file-name n bin)))
      (unwind-protect (progn ,@body) (delete-directory dir t)))))

(defun drgnx-platform-test--log-lines ()
  (when (file-exists-p drgnx-platform-test--log)
    (with-temp-buffer (insert-file-contents drgnx-platform-test--log) (split-string (buffer-string) "\n" t))))

(defun drgnx-platform-test--await (pred &optional seconds)
  "Wait (running timers and processes) until PRED is non-nil or SECONDS (default 3) pass; return PRED's value."
  (let ((deadline (+ (float-time) (or seconds 3))))
    (while (and (not (funcall pred)) (< (float-time) deadline)) (accept-process-output nil 0.02))
    (funcall pred)))

(defun drgnx-platform-test--env (alist) (lambda (var) (cdr (assoc var alist))))

(defmacro drgnx-platform-test--with-frame (window-system env &rest body)
  "Run BODY with the selected frame (a terminal one in batch) acting as a frame of WINDOW-SYSTEM with the
`environment' parameter ENV (a list of \"K=V\") and no cached adapter name."
  (declare (indent 2))
  `(let* ((frame (selected-frame)) (old-env (frame-parameter frame 'environment)))
     (cl-letf (((symbol-function 'drgnx-platform--frame-window-system) (lambda (_f) ,window-system)))
       (unwind-protect
           (progn (modify-frame-parameters frame (list (cons 'environment ,env) (cons 'drgnx-platform-wm nil)))
                  ,@body)
         (modify-frame-parameters frame (list (cons 'environment old-env) (cons 'drgnx-platform-wm nil)))))))

;;;; Detection

(ert-deftest drgnx-platform/detection-follows-the-spec-order ()
  (dolist (row '((ns nil ns)
                 ;; pgtk: the compositor's own variable, in the order sway, hyprland, niri, kwin, gnome
                 (pgtk (("SWAYSOCK" . "/s")) sway)
                 (pgtk (("HYPRLAND_INSTANCE_SIGNATURE" . "h")) hyprland)
                 (pgtk (("NIRI_SOCKET" . "/n")) niri)
                 (pgtk (("XDG_CURRENT_DESKTOP" . "KDE")) kwin)
                 (pgtk (("XDG_CURRENT_DESKTOP" . "plasma:KDE")) kwin)
                 (pgtk (("XDG_CURRENT_DESKTOP" . "GNOME")) gnome)
                 (pgtk (("XDG_CURRENT_DESKTOP" . "ubuntu:GNOME")) gnome)
                 (pgtk (("XDG_CURRENT_DESKTOP" . "GNOME-Classic:GNOME")) gnome)
                 (pgtk (("SWAYSOCK" . "/s") ("HYPRLAND_INSTANCE_SIGNATURE" . "h") ("NIRI_SOCKET" . "/n")) sway)
                 (pgtk (("HYPRLAND_INSTANCE_SIGNATURE" . "h") ("NIRI_SOCKET" . "/n")) hyprland)
                 (pgtk (("SWAYSOCK" . "/s") ("XDG_CURRENT_DESKTOP" . "KDE")) sway)
                 (pgtk (("XDG_CURRENT_DESKTOP" . "KDE:GNOME")) kwin)
                 (pgtk (("XDG_CURRENT_DESKTOP" . "river")) other-wayland)
                 (pgtk nil other-wayland)
                 (pgtk (("DISPLAY" . ":0")) other-wayland)
                 ;; x: i3 by I3SOCK, else plain X
                 (x (("I3SOCK" . "/i")) i3)
                 (x (("DISPLAY" . ":0")) x11)
                 (x nil x11)
                 (x (("DISPLAY" . ":0") ("XDG_CURRENT_DESKTOP" . "GNOME")) x11)
                 ;; a terminal frame, whatever the environment says
                 (tty (("SWAYSOCK" . "/s") ("DISPLAY" . ":0")) tty)
                 (tty nil tty)
                 ;; batch: WAYLAND_DISPLAY stands for pgtk, DISPLAY for x, neither is none
                 (nil (("WAYLAND_DISPLAY" . "wayland-1") ("SWAYSOCK" . "/s")) sway)
                 (nil (("WAYLAND_DISPLAY" . "wayland-1")) other-wayland)
                 (nil (("DISPLAY" . ":0")) x11)
                 (nil (("DISPLAY" . ":0") ("I3SOCK" . "/i")) i3)
                 (nil (("SWAYSOCK" . "/s")) none)
                 (nil nil none)))
    (pcase-let ((`(,ws ,env ,expected) row))
      (should (equal (list ws env (drgnx-platform-detect (drgnx-platform-test--env env) ws))
                     (list ws env expected))))))

(ert-deftest drgnx-platform/x11-emacs-under-wayland-uses-the-compositor ()
  ;; Review focus 5: an X frame with WAYLAND_DISPLAY (XWayland) belongs to the compositor, not to X11 or i3
  (let ((det (lambda (env ws) (drgnx-platform-detect (drgnx-platform-test--env env) ws))))
    (should (eq 'sway (funcall det '(("WAYLAND_DISPLAY" . "w") ("DISPLAY" . ":0") ("SWAYSOCK" . "/s") ("I3SOCK" . "/s")) 'x)))
    (should (eq 'gnome (funcall det '(("WAYLAND_DISPLAY" . "w") ("DISPLAY" . ":0") ("XDG_CURRENT_DESKTOP" . "ubuntu:GNOME")) 'x)))
    (should (eq 'kwin (funcall det '(("WAYLAND_DISPLAY" . "w") ("DISPLAY" . ":0") ("XDG_CURRENT_DESKTOP" . "KDE")) 'x)))
    (should (eq 'other-wayland (funcall det '(("WAYLAND_DISPLAY" . "w") ("DISPLAY" . ":0")) 'x)))
    (should (eq 'other-wayland (funcall det '(("DISPLAY" . ":0")) 'pgtk)))))

(ert-deftest drgnx-platform/i3-is-found-by-the-root-window-property ()
  (cl-letf (((symbol-function 'x-window-property) (lambda (prop &rest _) (and (equal prop "I3_SOCKET_PATH") "/run/i3/sock"))))
    (should (eq 'i3 (drgnx-platform-detect (drgnx-platform-test--env '(("DISPLAY" . ":0"))) 'x)))
    ;; batch has no frame to ask
    (should (eq 'x11 (drgnx-platform-detect (drgnx-platform-test--env '(("DISPLAY" . ":0"))) nil))))
  (cl-letf (((symbol-function 'x-window-property) (lambda (&rest _) nil)))
    (should (eq 'x11 (drgnx-platform-detect (drgnx-platform-test--env '(("DISPLAY" . ":0"))) 'x)))))

(ert-deftest drgnx-platform/the-frame-environment-wins-over-the-daemons ()
  ;; Review focus 1: the daemon has no SWAYSOCK, the frame (made by emacsclient in a sway session) does
  (drgnx-platform-test--with-fake-wm ()
    (drgnx-platform-test--with-frame 'pgtk '("SWAYSOCK=/frame/sway.sock" "WAYLAND_DISPLAY=wayland-1")
      (should-not (getenv "SWAYSOCK"))
      (should (eq 'sway (drgnx-platform-wm frame)))
      (should (member "SWAYSOCK=/frame/sway.sock" (drgnx-platform-process-env frame)))
      (let (res)
        (drgnx-platform-call '("swaymsg" "-t" "get_outputs") :env (drgnx-platform-process-env frame)
                             :callback (lambda (s o) (setq res (list s o))))
        (should (drgnx-platform-test--await (lambda () res)))
        (should (eq 'ok (car res))))
      (should (member "SWAYSOCK=/frame/sway.sock I3SOCK= HYPRLAND_INSTANCE_SIGNATURE= NIRI_SOCKET="
                      (with-temp-buffer (insert-file-contents (concat drgnx-platform-test--log ".env"))
                                        (split-string (buffer-string) "\n" t)))))))

(ert-deftest drgnx-platform/detection-is-cached-and-makes-no-call ()
  (drgnx-platform-test--with-fake-wm ()
    (drgnx-platform-test--with-frame 'pgtk '("SWAYSOCK=/s" "WAYLAND_DISPLAY=w")
      (let ((n 0))
        (advice-add 'drgnx-platform-detect :before (lambda (&rest _) (cl-incf n)) '((name . platform-test-count)))
        (unwind-protect
            (progn (should (eq 'sway (drgnx-platform-wm frame)))
                   (should (eq 'sway (drgnx-platform-wm frame)))
                   (should (= n 1))
                   (should (eq 'sway (frame-parameter frame 'drgnx-platform-wm))))
          (advice-remove 'drgnx-platform-detect 'platform-test-count))
        (sleep-for 0.1)
        (should-not (drgnx-platform-test--log-lines))))))

(ert-deftest drgnx-platform/adapters-are-registered-in-order-and-extended-by-name ()
  (should (equal (drgnx-platform-adapters)
                 '(ns sway hyprland niri kwin gnome i3 x11 tty other-wayland none)))
  (let ((drgnx-platform--adapters (copy-tree drgnx-platform--adapters)))
    (drgnx-platform-define-adapter 'labwc :detect (lambda (env _ws) (funcall env "LABWC_PID")) :title "labwc")
    ;; a new adapter goes before the catch-alls (other-wayland, none): after them it would never be tried
    (should (equal (drgnx-platform-adapters) '(ns sway hyprland niri kwin gnome i3 x11 tty labwc other-wayland none)))
    (should (eq 'labwc (drgnx-platform-detect (drgnx-platform-test--env '(("LABWC_PID" . "1"))) 'pgtk)))
    (should (eq 'sway (drgnx-platform-detect (drgnx-platform-test--env '(("SWAYSOCK" . "/s"))) 'pgtk)))
    ;; extending keeps the position and the keys not given
    (drgnx-platform-define-adapter 'sway :status 'reported)
    (should (eq 'reported (plist-get (drgnx-platform-adapter 'sway) :status)))
    (should (eq 'sway (drgnx-platform-detect (drgnx-platform-test--env '(("SWAYSOCK" . "/s"))) 'pgtk)))
    (should (eq 'sway (nth 1 (drgnx-platform-adapters))))))

;;;; The runner

(ert-deftest drgnx-platform/the-runner-returns-the-output-of-the-tool ()
  (drgnx-platform-test--with-fake-wm (:map "get_outputs sway/get_outputs")
    (let (res)
      (should-not (drgnx-platform-call '("swaymsg" "-t" "get_outputs")
                                       :callback (lambda (s o) (setq res (list s o)))))
      (should-not res)                  ; never before the function returns
      (should (drgnx-platform-test--await (lambda () res)))
      (should (eq 'ok (car res)))
      (should (string-match-p "HEADLESS-2" (cadr res)))
      (should (equal (drgnx-platform-test--log-lines) '("swaymsg -t get_outputs"))))))

(ert-deftest drgnx-platform/a-failing-tool-is-an-error-with-its-output ()
  (drgnx-platform-test--with-fake-wm (:exit 2 :map "get_tree sway/get_tree")
    (let (res)
      (drgnx-platform-call '("swaymsg" "-t" "get_tree") :callback (lambda (s o) (setq res (list s o))))
      (should (drgnx-platform-test--await (lambda () res)))
      (should (eq 'error (car res)))
      (should (string-match-p "HEADLESS-1" (cadr res))))))

(ert-deftest drgnx-platform/a-hanging-tool-is-cut-at-the-deadline ()
  ;; Review focus 2
  (drgnx-platform-test--with-fake-wm (:delay 10 :map "get_outputs sway/get_outputs")
    (let* ((calls nil) (start (float-time))
           (_ (drgnx-platform-call '("swaymsg" "-t" "get_outputs") :timeout 0.3
                                   :callback (lambda (s o) (push (list s o) calls))))
           (proc (seq-find (lambda (p) (equal (process-name p) "drgnx-wm")) (process-list)))
           (pid (process-id proc)))
      (should proc)
      (should (drgnx-platform-test--await (lambda () calls) 2))
      (should (< (- (float-time) start) 1.0))
      (should (equal (car calls) '(timeout "")))
      (should-not (process-live-p proc))
      (should (drgnx-platform-test--await (lambda () (not (file-exists-p (format "/proc/%d" pid)))) 1))
      (sleep-for 0.3)                   ; a line arriving later calls nothing
      (should (= 1 (length calls))))))

(ert-deftest drgnx-platform/a-missing-tool-calls-back-an-error-never-signals ()
  (drgnx-platform-test--no-session
   (let (res)
     (should-not (drgnx-platform-call '("drgnx-no-such-wm-tool" "x") :callback (lambda (s o) (setq res (list s o)))))
     (should-not res)
     (should (drgnx-platform-test--await (lambda () res)))
     (should (equal res '(error "drgnx-no-such-wm-tool is not installed")))
     (should (equal (drgnx-platform-call-sync '("drgnx-no-such-wm-tool"))
                    '(error . "drgnx-no-such-wm-tool is not installed")))
     (should-not (drgnx-platform-call '("drgnx-no-such-wm-tool"))))))      ; no callback: nothing to call

(ert-deftest drgnx-platform/an-error-in-a-callback-is-a-message ()
  (drgnx-platform-test--with-fake-wm ()
    (let ((msgs nil) (n 0))
      (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) msgs))))
        (drgnx-platform-call '("swaymsg") :callback (lambda (_s _o) (cl-incf n) (error "boom")))
        (should (drgnx-platform-test--await (lambda () msgs)))
        (sleep-for 0.1))
      (should (= n 1))
      (should (string-match-p "boom" (car msgs))))))

(ert-deftest drgnx-platform/the-sync-call-is-bounded ()
  (drgnx-platform-test--with-fake-wm (:delay 10)
    (let ((start (float-time)))
      (should (eq 'timeout (car (drgnx-platform-call-sync '("swaymsg") :timeout 0.3))))
      (should (< (- (float-time) start) 1.5))))
  (drgnx-platform-test--with-fake-wm (:map "get_outputs sway/get_outputs")
    (let ((r (drgnx-platform-call-sync '("swaymsg" "-t" "get_outputs"))))
      (should (eq 'ok (car r)))
      (should (string-match-p "HEADLESS-1" (cdr r))))))

;;;; Monitors

(defun drgnx-platform-test--mon (name x y w h &rest more)
  (append (list :name name :geometry (list x y w h)) more))

(ert-deftest drgnx-platform/numbering-left-to-right-then-top-to-bottom ()
  (let ((r (drgnx-platform-number-monitors
            (list (drgnx-platform-test--mon "DP-2" 2560 0 2560 1440)
                  (drgnx-platform-test--mon "eDP-1" 0 0 1920 1200)
                  (drgnx-platform-test--mon "HDMI-1" -1920 0 1920 1080)))))
    (should (equal (mapcar (lambda (m) (plist-get m :name)) r) '("HDMI-1" "eDP-1" "DP-2")))
    (should (equal (mapcar (lambda (m) (plist-get m :number)) r) '(1 2 3)))
    (should (equal (mapcar (lambda (m) (plist-get m :label)) r)
                   '("1 — HDMI-1, 1920×1080" "2 — eDP-1, 1920×1200, right of 1" "3 — DP-2, 2560×1440, right of 1"))))
  ;; the same X: top first; below, above and left of monitor 1 by the larger offset
  (let ((r (drgnx-platform-number-monitors
            (list (drgnx-platform-test--mon "B" 0 1080 1920 1080)
                  (drgnx-platform-test--mon "A" 0 0 1920 1080)))))
    (should (equal (mapcar (lambda (m) (plist-get m :label)) r)
                   '("1 — A, 1920×1080" "2 — B, 1920×1080, below 1"))))
  (let ((r (drgnx-platform-number-monitors
            (list (drgnx-platform-test--mon "L" 0 500 1920 1080)
                  (drgnx-platform-test--mon "U" 100 -1080 1920 1080)))))
    (should (equal (plist-get (cadr r) :label) "2 — U, 1920×1080, above 1")))
  (let ((r (drgnx-platform-number-monitors
            (list (drgnx-platform-test--mon "R" 0 0 1920 1080) (drgnx-platform-test--mon "S" 1920 1080 1920 1080)))))
    (should (string-suffix-p ", right of 1" (plist-get (cadr r) :label))))   ; a tie counts as sideways
  (should-not (drgnx-platform-number-monitors nil))
  ;; the input is not modified
  (let ((in (list (drgnx-platform-test--mon "A" 0 0 10 10))))
    (drgnx-platform-number-monitors in)
    (should-not (plist-member (car in) :number))))

(ert-deftest drgnx-platform/matching-prefers-serial-then-name-then-geometry ()
  ;; Review focus 3
  (let* ((saved (drgnx-platform-test--mon "DP-2" 1920 0 2560 1440 :make "Dell" :model "U2720Q" :serial "ABC123"))
         (renamed (drgnx-platform-test--mon "DP-3" 0 0 2560 1440 :make "Dell" :model "U2720Q" :serial "ABC123"))
         (other (drgnx-platform-test--mon "DP-2" 1920 0 2560 1440 :make "LG" :model "X" :serial "ZZZ")))
    ;; DP-2 -> DP-3, same serial: found despite name and geometry
    (should (eq renamed (drgnx-platform-match-monitor saved (list other renamed)))))
  ;; two identical monitors without serial: by name
  (let* ((saved (drgnx-platform-test--mon "DP-2" 1920 0 1920 1080 :make "X" :model "Y" :serial ""))
         (a (drgnx-platform-test--mon "DP-1" 0 0 1920 1080 :make "X" :model "Y" :serial ""))
         (b (drgnx-platform-test--mon "DP-2" 1920 0 1920 1080 :make "X" :model "Y" :serial "")))
    (should (eq b (drgnx-platform-match-monitor saved (list a b))))
    (should (eq b (drgnx-platform-match-monitor saved (list b a)))))
  ;; renamed and no serial: by geometry
  (let* ((saved (drgnx-platform-test--mon "DP-2" 1920 0 1920 1080))
         (a (drgnx-platform-test--mon "DP-5" 0 0 1920 1080))
         (b (drgnx-platform-test--mon "DP-6" 1920 0 1920 1080)))
    (should (eq b (drgnx-platform-match-monitor saved (list a b)))))
  ;; names that are not unique (pgtk gives "Unknown" to all) do not match; geometry decides
  (let* ((saved (drgnx-platform-test--mon "Unknown" 1280 0 1280 800))
         (a (drgnx-platform-test--mon "Unknown" 0 0 1280 800))
         (b (drgnx-platform-test--mon "Unknown" 1280 0 1280 800)))
    (should (eq b (drgnx-platform-match-monitor saved (list a b)))))
  ;; an empty make/model/serial never matches by itself
  (let* ((saved (drgnx-platform-test--mon "" 0 0 10 10 :make "" :model "" :serial ""))
         (a (drgnx-platform-test--mon "" 500 0 10 10 :make "" :model "" :serial "")))
    (should-not (drgnx-platform-match-monitor saved (list a))))
  ;; nothing
  (should-not (drgnx-platform-match-monitor (drgnx-platform-test--mon "DP-9" 9 9 9 9)
                                            (list (drgnx-platform-test--mon "DP-1" 0 0 1 1))))
  (should-not (drgnx-platform-match-monitor (drgnx-platform-test--mon "DP-9" 9 9 9 9) nil)))

;;;; Built-in adapters

(ert-deftest drgnx-platform/gnome-explains-and-names-the-key ()
  (drgnx-platform-test--no-session
   (drgnx-platform-test--with-frame 'pgtk '("XDG_CURRENT_DESKTOP=ubuntu:GNOME" "WAYLAND_DISPLAY=wayland-0")
     (should (eq 'gnome (drgnx-platform-wm frame)))
     (should (equal (drgnx-platform-can-move frame)
                    '("GNOME does not let apps move their windows"
                      . "press Super+Shift+→ or Super+Shift+← (GNOME's \"Move window one monitor to the right/left\")")))
     (let (res mon (done nil))
       (drgnx-platform-move-frame frame (drgnx-platform-test--mon "x" 0 0 1 1) (lambda (r) (setq res r done t)))
       (should (drgnx-platform-test--await (lambda () done)))
       (should (eq :error (car res)))
       (should (string-match-p "GNOME does not let apps move" (cadr res)))
       (setq done nil)
       (drgnx-platform-frame-monitor frame (lambda (m) (setq mon m done t)))
       (should (drgnx-platform-test--await (lambda () done)))
       (should-not mon)))))

(ert-deftest drgnx-platform/other-wayland-names-the-compositor ()
  (drgnx-platform-test--no-session
   (drgnx-platform-test--with-frame 'pgtk '("XDG_CURRENT_DESKTOP=river")
     (should (eq 'other-wayland (drgnx-platform-wm frame)))
     (should (equal (drgnx-platform-can-move frame)
                    '("river: drgnx has no adapter for this compositor"
                      . "use its own key to move a window to another output")))))
  (drgnx-platform-test--no-session
   (drgnx-platform-test--with-frame 'pgtk nil
     (should (equal (car (drgnx-platform-can-move frame))
                    "This compositor: drgnx has no adapter for this compositor")))))

(ert-deftest drgnx-platform/x11-move-sets-left-and-top-and-keeps-fullscreen ()
  (drgnx-platform-test--no-session
   (drgnx-platform-test--with-frame 'x '("DISPLAY=:0")
     (let* ((params (list (cons 'fullscreen 'maximized) (cons 'left 5) (cons 'top 6)))
            (sets nil) (done nil) res)
       (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
                 ((symbol-function 'frame-parameter)
                  (let ((orig (symbol-function 'frame-parameter)))
                    (lambda (f p) (if (assq p params) (cdr (assq p params)) (funcall orig f p)))))
                 ((symbol-function 'set-frame-parameter)
                  (let ((orig (symbol-function 'set-frame-parameter)))
                    (lambda (f p v) (if (memq p '(fullscreen left top))
                                        (progn (push (cons p v) sets) (setf (alist-get p params) v))
                                      (funcall orig f p v))))))
         (should (eq 'x11 (drgnx-platform-wm frame)))
         (should (eq t (drgnx-platform-can-move frame)))
         (drgnx-platform-move-frame frame (drgnx-platform-test--mon "DP-2" 1920 0 2560 1440 :workarea '(1920 30 2560 1410))
                                    (lambda (r) (setq res r done t)))
         (should (drgnx-platform-test--await (lambda () done)))
         (should (eq 'ok res))
         (should (equal (nreverse sets) '((fullscreen) (left . 1920) (top . 30) (fullscreen . maximized))))
         ;; no fullscreen to keep: it is not set
         (setq sets nil done nil params (list (cons 'fullscreen nil)))
         (drgnx-platform-place-frame frame (drgnx-platform-test--mon "DP-1" -1920 0 1920 1080) (lambda (r) (setq res r done t)))
         (should (drgnx-platform-test--await (lambda () done)))
         (should (equal (nreverse sets) '((fullscreen) (left . -1920) (top . 0)))))))))

(ert-deftest drgnx-platform/x11-lists-emacs-monitors-numbered ()
  (drgnx-platform-test--no-session
   (drgnx-platform-test--with-frame 'x '("DISPLAY=:0")
     (cl-letf (((symbol-function 'display-monitor-attributes-list)
                (lambda (&optional _) '(((name . "DP-2") (geometry 1920 0 2560 1440) (workarea 1920 0 2560 1400))
                                        ((name . "eDP-1") (geometry 0 0 1920 1200) (workarea 0 0 1920 1160)))))
               ((symbol-function 'frame-monitor-attributes)
                (lambda (&optional _) '((name . "DP-2") (geometry 1920 0 2560 1440) (workarea 1920 0 2560 1400)))))
       (let (res fm)
         (drgnx-platform-monitors frame (lambda (r) (setq res r)))
         (should (drgnx-platform-test--await (lambda () res)))
         (should (equal (mapcar (lambda (m) (plist-get m :label)) res)
                        '("1 — eDP-1, 1920×1200" "2 — DP-2, 2560×1440, right of 1")))
         (should (equal (plist-get (cadr res) :make) ""))
         (drgnx-platform-frame-monitor frame (lambda (m) (setq fm (or m 'none))))
         (should (drgnx-platform-test--await (lambda () fm)))
         (should (equal (plist-get fm :name) "DP-2"))
         (should (equal (plist-get fm :geometry) '(1920 0 2560 1440))))))))

(ert-deftest drgnx-platform/a-terminal-frame-has-no-monitor ()
  (drgnx-platform-test--no-session
   (let ((frame (selected-frame)) (res nil) (fm 'unset))
     (set-frame-parameter frame 'drgnx-platform-wm nil)
     (unwind-protect
         (progn
           (should (eq 'tty (drgnx-platform-wm frame)))
           (should (equal (drgnx-platform-can-move frame) '("a terminal window has no monitor")))
           (drgnx-platform-monitors frame (lambda (r) (setq res r)))
           (should (drgnx-platform-test--await (lambda () res)))
           (should (equal res '(:error "a terminal window has no monitor")))
           (setq res nil)
           (drgnx-platform-move-frame frame (drgnx-platform-test--mon "x" 0 0 1 1) (lambda (r) (setq res r)))
           (should (drgnx-platform-test--await (lambda () res)))
           (should (eq :error (car res)))
           (drgnx-platform-frame-monitor frame (lambda (m) (setq fm m)))
           (should (drgnx-platform-test--await (lambda () (null fm)))))
       (set-frame-parameter frame 'drgnx-platform-wm nil)))
   ;; batch without a frame and without a display: none
   (should (eq 'none (drgnx-platform-wm)))))

(ert-deftest drgnx-platform/a-failing-adapter-is-an-error-not-a-signal ()
  (drgnx-platform-test--no-session
   (drgnx-platform-test--with-frame 'x '("DISPLAY=:0")
     (cl-letf (((symbol-function 'display-monitor-attributes-list) (lambda (&optional _) (error "no display"))))
       (let (res)
         (drgnx-platform-monitors frame (lambda (r) (setq res r)))
         (should (drgnx-platform-test--await (lambda () res)))
         (should (eq :error (car res)))
         (should (string-match-p "no display" (cadr res))))))))

(ert-deftest drgnx-platform/the-doctors-monitors ()
  (should (equal (mapcar (lambda (m) (list (plist-get m :name) (plist-get m :geometry)))
                         (drgnx-platform--xrandr-monitors
                          "Monitors: 2\n 0: +*DP-1 1920/527x1080/296+0+0  DP-1\n 1: +HDMI-1 1280/340x800/210+-1280+0  HDMI-1\n"))
                 '(("DP-1" (0 0 1920 1080)) ("HDMI-1" (-1280 0 1280 800)))))
  ;; Mutter's GetCurrentState: (serial monitors logical-monitors properties)
  (let* ((ids0 '("Meta-0" "MetaVendor" "MetaVirtualMonitor" "0x00"))
         (ids1 '("Meta-1" "MetaVendor" "MetaVirtualMonitor" "0x01"))
         (mode (lambda (w h cur) (list "id" w h 60.0 1.0 '(1.0) (and cur '(("is-current" t))))))
         (state (list 2 (list (list ids0 (list (funcall mode 640 480 nil) (funcall mode 1280 800 t)) nil)
                              (list ids1 (list (funcall mode 1280 800 t)) nil))
                      (list (list 0 0 1.0 0 t (list ids0) nil) (list 1280 0 1.0 0 nil (list ids1) nil))
                      '(("layout-mode" 1)))))
    (should (equal (mapcar (lambda (m) (list (plist-get m :name) (plist-get m :serial) (plist-get m :geometry)))
                           (drgnx-platform--dbus-monitors state))
                   '(("Meta-0" "0x00" (0 0 1280 800)) ("Meta-1" "0x01" (1280 0 1280 800))))))
  ;; the gnome doctor with a stubbed bus; a silent bus is "did not answer", never an error
  ;; (dbus is loaded first: the doctor's require would otherwise replace the stub with the real function
  ;; and ask the bus of the session the test runs in)
  (require 'dbus nil t)
  (cl-letf (((symbol-function 'dbus-call-method) (lambda (&rest _) (signal 'dbus-error '("timeout"))))
            (process-environment (cons "DBUS_SESSION_BUS_ADDRESS" process-environment)))
    (let ((r (funcall (drgnx-platform--spec 'gnome :doctor) (drgnx-platform-test--env nil))))
      (should-not (plist-get r :monitors))
      (should (string-match-p "did not answer" (cdar (plist-get r :answers)))))))

(provide 'platform-test)
;;; platform-test.el ends here
