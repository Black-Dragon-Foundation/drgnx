;;; drgnx-platform.el --- Window-manager adapters: monitors, moving a frame, and every call with a deadline -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Emacs cannot move a frame to another monitor by itself under Wayland, and a tiling window manager
;; ignores `set-frame-position'.  An adapter knows one window manager (or none): how to list its
;; monitors, which one a frame is on, and how to move a frame.  The adapter is found per frame from the
;; frame's own environment (`SWAYSOCK' and friends), because one daemon serves frames from several
;; sessions.  Every call to a window manager is asynchronous with a deadline (`drgnx-platform-call'):
;; nothing on an automatic path (frame creation, monitors-changed, restore) blocks, prompts or signals.
;; The sync call is for the doctor and for commands the user typed.  See docs/develop/core.md.
;;
;; Monitor facts that shaped this file (m12c facts): pgtk's monitor `name' is GDK's model string, not
;; the window manager's output name, and Emacs lists monitors in no stable order, so monitors are
;; matched by geometry and numbered by position.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-guard)

(defgroup drgnx-platform nil "Window-manager adapters." :group 'drgnx)

(defcustom drgnx-platform-command-timeout 2.0
  "Seconds a window-manager call from a command may take before it is cut."
  :type 'number :group 'drgnx-platform)
(defcustom drgnx-platform-restore-timeout 5.0
  "Seconds a window-manager call while restoring frames may take before it is cut."
  :type 'number :group 'drgnx-platform)
(defcustom drgnx-platform-doctor-timeout 1.0
  "Seconds a synchronous call (the doctor, a typed command) may take before it is cut."
  :type 'number :group 'drgnx-platform)

;;;; Environment

(defconst drgnx-platform-env-vars
  '("SWAYSOCK" "I3SOCK" "HYPRLAND_INSTANCE_SIGNATURE" "NIRI_SOCKET" "WAYLAND_DISPLAY" "DISPLAY"
    "XAUTHORITY" "XDG_RUNTIME_DIR" "XDG_CURRENT_DESKTOP" "XDG_SESSION_TYPE" "DBUS_SESSION_BUS_ADDRESS")
  "The variables a window-manager tool needs from the session its frame belongs to.")

(defun drgnx-platform-env (frame)
  "A function VAR -> value (nil when unset or empty): FRAME's own environment first, then the daemon's.
Frames made by emacsclient carry the environment of the shell that asked; the daemon's belongs to
whoever started it."
  (lambda (var)
    (let ((v (or (and frame (frame-live-p frame) (getenv var frame)) (getenv var))))
      (and v (not (string-empty-p v)) v))))

(defun drgnx-platform-process-env (frame)
  "The window-manager variables of FRAME as \"K=V\" strings, to prepend to `process-environment'."
  (let ((env (drgnx-platform-env frame)))
    (delq nil (mapcar (lambda (var) (when-let* ((v (funcall env var))) (concat var "=" v)))
                      drgnx-platform-env-vars))))

;;;; The asynchronous runner

(defun drgnx-platform--later (fn)
  "Run FN from a 0-second timer: callbacks are never called before the function that takes them returns."
  (run-at-time 0 nil fn))

(defun drgnx-platform--once (callback)
  "A function that calls CALLBACK (nil: nothing) at most once and turns an error in it into a message."
  (let ((done nil))
    (lambda (&rest args)
      (unless done
        (setq done t)
        (when callback
          (condition-case err
              (drgnx-automatic (apply callback args))
            (error (message "drgnx-platform: callback failed: %s" (error-message-string err)))))))))

(cl-defun drgnx-platform-call (argv &key env timeout callback)
  "Run ARGV (program and arguments) without blocking; call CALLBACK once with STATUS and OUTPUT.
STATUS is `ok' (exit 0), `error' (exit not 0, program missing or not startable) or `timeout' (killed
after TIMEOUT seconds, default `drgnx-platform-command-timeout'; its later output is dropped).  OUTPUT is
the standard output, or the standard error when that is empty.  ENV is a list of \"K=V\" strings put in
front of `process-environment'.  Always asynchronous; an error in CALLBACK is shown with `message'."
  (let* ((cb (drgnx-platform--once callback))
         (default-directory temporary-file-directory)
         (program (car argv)))
    (if (not (and program (executable-find program)))
        (drgnx-platform--later
         (lambda () (funcall cb 'error (format "%s is not installed" (or program "(no program)")))))
      (let* ((chunks nil) (timer nil) (finished nil) (proc nil)
             (errbuf (generate-new-buffer " *drgnx-wm-stderr*"))
             (finish
              (lambda (status output)
                (unless finished
                  (setq finished t)
                  (when timer (cancel-timer timer))
                  (when (process-live-p proc)
                    (set-process-filter proc #'ignore)
                    (set-process-sentinel proc #'ignore)
                    (ignore-errors (signal-process proc 'KILL))
                    (delete-process proc))
                  (let ((out (or output (string-join (nreverse chunks))))
                        (err (with-current-buffer errbuf (buffer-string))))
                    (when (buffer-live-p errbuf) (kill-buffer errbuf))
                    (funcall cb status (if (and (string-empty-p out) (not (eq status 'ok))) err out)))))))
        (condition-case err
            (let ((process-environment (append env process-environment)))
              (setq proc (make-process
                          :name "drgnx-wm" :command argv :connection-type 'pipe :noquery t
                          :buffer nil :stderr errbuf
                          :filter (lambda (_p s) (push s chunks))
                          :sentinel (lambda (p _e)
                                      (unless (process-live-p p)
                                        (funcall finish (if (eq (process-exit-status p) 0) 'ok 'error)
                                                 nil)))))
              (when-let* ((errproc (get-buffer-process errbuf)))
                (set-process-sentinel errproc #'ignore)
                (set-process-query-on-exit-flag errproc nil))
              (setq timer (run-at-time (or timeout drgnx-platform-command-timeout) nil
                                       (lambda () (funcall finish 'timeout "")))))
          (error
           (setq finished t)
           (when (buffer-live-p errbuf) (kill-buffer errbuf))
           (let ((msg (error-message-string err)))
             (drgnx-platform--later (lambda () (funcall cb 'error msg))))))))
    nil))

(cl-defun drgnx-platform-call-sync (argv &key env timeout)
  "Run ARGV and wait at most TIMEOUT seconds (default `drgnx-platform-doctor-timeout'): (STATUS . OUTPUT).
For the doctor and for commands the user typed; never from an automatic path."
  (let* ((limit (or timeout drgnx-platform-doctor-timeout)) (result nil)
         (deadline (+ (float-time) limit 0.5)))
    (drgnx-platform-call argv :env env :timeout limit
                         :callback (lambda (status out) (setq result (cons status out))))
    (while (and (not result) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (or result (cons 'timeout ""))))

;;;; Adapters

(defvar drgnx-platform--adapters nil
  "Alist (NAME . SPEC) in definition order; detection tries them in that order.")

(defun drgnx-platform-define-adapter (name &rest spec)
  "Define (or extend: keys given here replace those of an earlier definition) the adapter NAME.
SPEC keys: :detect (fn ENV WINDOW-SYSTEM -> non-nil), :title, :tool, :version (argv), :status
(`verified' or `reported'), :monitors (fn CTX CALLBACK), :frame-monitor (fn CTX CALLBACK), :move
(fn CTX MONITOR CALLBACK), :place (fn CTX MONITOR CALLBACK; default :move), :can-move (fn CTX -> t or
\(REASON . FIX)), :doctor (fn ENV -> plist :monitors :answers).  A new adapter goes before the catch-alls
`other-wayland' and `none' (after them it would never be tried)."
  (let ((cell (assq name drgnx-platform--adapters)))
    (if cell
        (let ((old (cdr cell)) (new (copy-sequence spec)))
          (while new (setq old (plist-put old (pop new) (pop new))))
          (setcdr cell old))
      (let* ((entry (cons name (copy-sequence spec)))
             (tail (and (not (eq name 'none))
                        (or (memq (assq 'other-wayland drgnx-platform--adapters) drgnx-platform--adapters)
                            (memq (assq 'none drgnx-platform--adapters) drgnx-platform--adapters)))))
        (setq drgnx-platform--adapters
              (append (seq-take-while (lambda (c) (not (eq c (car tail)))) drgnx-platform--adapters)
                      (list entry) tail))))
    name))

(defun drgnx-platform-adapters () "The names of the adapters, in detection order."
       (mapcar #'car drgnx-platform--adapters))

(defun drgnx-platform-adapter (name) "The spec plist of the adapter NAME, or nil."
       (cdr (assq name drgnx-platform--adapters)))

(defun drgnx-platform--spec (name key) (plist-get (drgnx-platform-adapter name) key))

;;;; Detection

(defvar drgnx-platform--detect-frame nil "The frame being detected for (the i3 root-window property).")

(defun drgnx-platform--effective-ws (env ws)
  "WS, or for batch (WS nil) what the environment says: `pgtk' with WAYLAND_DISPLAY, `x' with DISPLAY."
  (cond (ws ws)
        ((funcall env "WAYLAND_DISPLAY") 'pgtk)
        ((funcall env "DISPLAY") 'x)))

(defun drgnx-platform--wayland-p (env ws)
  "Non-nil when the frame is on a Wayland compositor: pgtk, or an X frame (XWayland) with WAYLAND_DISPLAY."
  (let ((eff (drgnx-platform--effective-ws env ws)))
    (or (eq eff 'pgtk) (and (eq eff 'x) (funcall env "WAYLAND_DISPLAY") t))))

(defun drgnx-platform--desktop-has (env name)
  "Non-nil when XDG_CURRENT_DESKTOP (colon separated, like ubuntu:GNOME) lists NAME."
  (when-let* ((d (funcall env "XDG_CURRENT_DESKTOP")))
    (seq-some (lambda (tok) (string-equal-ignore-case tok name)) (split-string d ":" t))))

(defun drgnx-platform--wayland-var (var)
  "A detect function: on a Wayland compositor and VAR set."
  (lambda (env ws) (and (drgnx-platform--wayland-p env ws) (funcall env var) t)))

(defun drgnx-platform--wayland-desktop (name)
  "A detect function: on a Wayland compositor and XDG_CURRENT_DESKTOP lists NAME."
  (lambda (env ws) (and (drgnx-platform--wayland-p env ws) (drgnx-platform--desktop-has env name) t)))

(defun drgnx-platform--i3-detect (env ws)
  "An X frame (not under a Wayland compositor) with I3SOCK, or the root window's I3_SOCKET_PATH."
  (and (eq (drgnx-platform--effective-ws env ws) 'x)
       (not (drgnx-platform--wayland-p env ws))
       (or (and (funcall env "I3SOCK") t)
           (and (eq ws 'x) (fboundp 'x-window-property)
                (ignore-errors
                  (and (x-window-property "I3_SOCKET_PATH" drgnx-platform--detect-frame nil 0) t))))))

(defun drgnx-platform-detect (env wsys)
  "The adapter name for ENV (a function VAR -> value) and WSYS (the window system): pure, no process.
WSYS is `ns', `pgtk', `x', `tty' (a terminal frame) or nil (batch: WAYLAND_DISPLAY stands for
pgtk, DISPLAY for x, neither gives `none')."
  (or (seq-some (lambda (cell)
                  (when-let* ((fn (plist-get (cdr cell) :detect)))
                    (and (funcall fn env wsys) (car cell))))
                drgnx-platform--adapters)
      'none))

(defun drgnx-platform--frame-window-system (frame)
  "`x', `pgtk', `ns', ... for a graphic FRAME, `tty' for a terminal frame."
  (let ((k (framep frame))) (if (eq k t) 'tty k)))

(defun drgnx-platform-wm (&optional frame)
  "The adapter name for FRAME (default: the selected frame), cached in its parameter `drgnx-platform-wm'.
No process, no window-manager call.  Without FRAME in batch Emacs: from the process environment."
  (if (and (null frame) noninteractive)
      (drgnx-platform-detect (drgnx-platform-env nil) nil)
    (let ((frame (or frame (selected-frame))))
      (or (frame-parameter frame 'drgnx-platform-wm)
          (let ((name (let ((drgnx-platform--detect-frame frame))
                        (drgnx-platform-detect (drgnx-platform-env frame)
                                               (drgnx-platform--frame-window-system frame)))))
            (set-frame-parameter frame 'drgnx-platform-wm name)
            name)))))

;;;; Context and public operations

(defun drgnx-platform-ctx (frame &optional timeout)
  "The context an adapter function gets: (:frame FRAME :env ENV :wm NAME :timeout SECONDS)."
  (list :frame frame :env (drgnx-platform-env frame) :wm (drgnx-platform-wm frame)
        :timeout (or timeout drgnx-platform-command-timeout)))

(defun drgnx-platform-ctx-call (ctx argv callback)
  "`drgnx-platform-call' ARGV with CTX's frame environment and deadline; CALLBACK (STATUS OUTPUT)."
  (drgnx-platform-call argv :env (drgnx-platform-process-env (plist-get ctx :frame))
                       :timeout (plist-get ctx :timeout) :callback callback))

(defun drgnx-platform-can-move (frame)
  "t when drgnx can move FRAME to another monitor, else (REASON . FIX) (FIX may be nil)."
  (let* ((ctx (drgnx-platform-ctx frame)) (spec (drgnx-platform-adapter (plist-get ctx :wm))))
    (cond ((plist-get spec :can-move) (funcall (plist-get spec :can-move) ctx))
          ((plist-get spec :move) t)
          (t (cons (format "drgnx has no adapter to move windows here (%s)"
                           (or (plist-get spec :title) (plist-get ctx :wm)))
                   nil)))))

(defun drgnx-platform--reason (can)
  (if (consp can) (concat (car can) (and (cdr can) (concat " — " (cdr can)))) "cannot move"))

(defun drgnx-platform--error-p (r) (and (consp r) (eq (car r) :error)))

(defun drgnx-platform--run (fn &rest args)
  "Call FN with ARGS; a signal becomes (:error MESSAGE) given to the last of ARGS (the callback)."
  (let ((cb (car (last args))))
    (condition-case err (apply fn args)
      (error (let ((msg (error-message-string err))) (drgnx-platform--later (lambda () (funcall cb (list :error msg)))))))))

(defun drgnx-platform-monitors (frame callback)
  "Call CALLBACK with FRAME's monitors, numbered (`drgnx-platform-number-monitors'), or (:error MESSAGE)."
  (let* ((cb (drgnx-platform--once callback)) (ctx (drgnx-platform-ctx frame))
         (fn (drgnx-platform--spec (plist-get ctx :wm) :monitors)))
    (if (not fn)
        (drgnx-platform--later
         (lambda () (funcall cb (list :error (drgnx-platform--reason (drgnx-platform-can-move frame))))))
      (drgnx-platform--run fn ctx
                           (lambda (r) (funcall cb (if (drgnx-platform--error-p r) r
                                                     (drgnx-platform-number-monitors r))))))))

(defun drgnx-platform-frame-monitor (frame callback)
  "Call CALLBACK with the monitor FRAME is on (a plist), or nil when unknown or not applicable."
  (let* ((cb (drgnx-platform--once callback)) (ctx (drgnx-platform-ctx frame))
         (fn (drgnx-platform--spec (plist-get ctx :wm) :frame-monitor)))
    (if (not fn)
        (drgnx-platform--later (lambda () (funcall cb nil)))
      (drgnx-platform--run fn ctx (lambda (r) (funcall cb (and (not (drgnx-platform--error-p r)) r)))))))

(defun drgnx-platform--move (key timeout frame monitor callback)
  (let* ((cb (drgnx-platform--once callback)) (ctx (drgnx-platform-ctx frame timeout))
         (spec (drgnx-platform-adapter (plist-get ctx :wm)))
         (fn (or (plist-get spec key) (plist-get spec :move)))
         (can (drgnx-platform-can-move frame)))
    (if (or (not fn) (not (eq can t)))
        (drgnx-platform--later (lambda () (funcall cb (list :error (drgnx-platform--reason can)))))
      (drgnx-platform--run fn ctx monitor
                           (lambda (r) (funcall cb (if (drgnx-platform--error-p r) r 'ok)))))))

(defun drgnx-platform-move-frame (frame monitor callback)
  "Move FRAME to MONITOR (a plist); a command's path, so `drgnx-platform-command-timeout'.
CALLBACK gets `ok' or (:error MESSAGE)."
  (drgnx-platform--move :move drgnx-platform-command-timeout frame monitor callback))

(defun drgnx-platform-place-frame (frame monitor callback)
  "Place FRAME on MONITOR while restoring; `drgnx-platform-restore-timeout'.  CALLBACK as above."
  (drgnx-platform--move :place drgnx-platform-restore-timeout frame monitor callback))

;;;; Monitors: numbering, labels, matching

(defun drgnx-platform--geometry (m) (plist-get m :geometry))

(defun drgnx-platform--relation (m first)
  "How M lies relative to FIRST: right of, left of, above or below (the larger offset wins)."
  (let* ((g (drgnx-platform--geometry m)) (f (drgnx-platform--geometry first))
         (dx (- (nth 0 g) (nth 0 f))) (dy (- (nth 1 g) (nth 1 f))))
    (if (>= (abs dx) (abs dy)) (if (> dx 0) "right of" "left of") (if (< dy 0) "above" "below"))))

(defun drgnx-platform-number-monitors (monitors)
  "MONITORS sorted left to right, then top to bottom, each with :number (1-based) and :label."
  (let* ((sorted (sort (mapcar #'copy-sequence monitors)
                       (lambda (a b) (let ((ga (drgnx-platform--geometry a)) (gb (drgnx-platform--geometry b)))
                                       (or (< (nth 0 ga) (nth 0 gb))
                                           (and (= (nth 0 ga) (nth 0 gb)) (< (nth 1 ga) (nth 1 gb))))))))
         (first (car sorted)) (n 0))
    (mapcar (lambda (m)
              (setq n (1+ n))
              (let* ((g (drgnx-platform--geometry m))
                     (base (format "%d — %s, %d×%d" n (let ((nm (plist-get m :name)))
                                                        (if (or (null nm) (string-empty-p nm)) "monitor" nm))
                                   (nth 2 g) (nth 3 g))))
                (setq m (plist-put m :number n))
                (plist-put m :label (if (= n 1) base
                                      (format "%s, %s 1" base (drgnx-platform--relation m first))))))
            sorted)))

(defun drgnx-platform--filled (s) (and (stringp s) (not (string-empty-p s))))

(defun drgnx-platform-match-monitor (saved monitors)
  "The monitor of MONITORS that SAVED (a monitor plist) was: the one whose make, model and serial are all
non-empty and equal (if exactly one); else the one with SAVED's name (if exactly one); else the one
with SAVED's geometry; else nil."
  (let ((make (plist-get saved :make)) (model (plist-get saved :model)) (serial (plist-get saved :serial))
        (name (plist-get saved :name)) (geometry (plist-get saved :geometry)))
    (or (and (drgnx-platform--filled make) (drgnx-platform--filled model) (drgnx-platform--filled serial)
             (let ((hits (seq-filter (lambda (m) (and (equal (plist-get m :make) make)
                                                      (equal (plist-get m :model) model)
                                                      (equal (plist-get m :serial) serial)))
                                     monitors)))
               (and (null (cdr hits)) (car hits))))
        (and (drgnx-platform--filled name)
             (let ((hits (seq-filter (lambda (m) (equal (plist-get m :name) name)) monitors)))
               (and (null (cdr hits)) (car hits))))
        (and geometry
             (seq-find (lambda (m) (equal (plist-get m :geometry) geometry)) monitors)))))

;;;; Built-in adapters: frame positions (x11, ns)

(defun drgnx-platform--attrs-monitor (attrs)
  "A monitor plist from an entry of `display-monitor-attributes-list'."
  (list :name (or (alist-get 'name attrs) "") :make "" :model "" :serial ""
        :geometry (alist-get 'geometry attrs) :workarea (alist-get 'workarea attrs)))

(defun drgnx-platform--answer-later (callback thunk)
  "Later, call CALLBACK with the value of THUNK, or (:error MESSAGE) when THUNK signals."
  (drgnx-platform--later
   (lambda () (funcall callback (condition-case err (funcall thunk)
                                  (error (list :error (error-message-string err))))))))

(defun drgnx-platform--emacs-monitors (ctx callback)
  "CALLBACK with Emacs' own monitor list for CTX's frame, later."
  (let ((frame (plist-get ctx :frame)))
    (drgnx-platform--answer-later
     callback (lambda () (mapcar #'drgnx-platform--attrs-monitor (display-monitor-attributes-list frame))))))

(defun drgnx-platform--emacs-frame-monitor (ctx callback)
  "CALLBACK with the monitor CTX's frame is on, later."
  (let ((frame (plist-get ctx :frame)))
    (drgnx-platform--answer-later
     callback (lambda () (and (frame-live-p frame)
                              (drgnx-platform--attrs-monitor (frame-monitor-attributes frame)))))))

(defun drgnx-platform--graphic-can-move (ctx)
  (if (display-graphic-p (plist-get ctx :frame)) t
    '("a terminal window has no monitor" . nil)))

(defun drgnx-platform--move-by-position (ctx monitor callback)
  "Keep the frame's `fullscreen' value, clear it, set `left' and `top' to MONITOR's workarea origin,
re-apply the value (the window manager moves a frame by position; a fullscreen one would not move)."
  (let* ((frame (plist-get ctx :frame))
         (area (or (plist-get monitor :workarea) (plist-get monitor :geometry)))
         (fs (frame-parameter frame 'fullscreen)))
    (set-frame-parameter frame 'fullscreen nil)
    (set-frame-parameter frame 'left (nth 0 area))
    (set-frame-parameter frame 'top (nth 1 area))
    (when fs (set-frame-parameter frame 'fullscreen fs))
    (drgnx-platform--later (lambda () (funcall callback 'ok)))))

(defun drgnx-platform--xrandr-monitors (text)
  "Monitor plists from `xrandr --listmonitors' TEXT."
  (let (out)
    (dolist (line (split-string text "\n" t))
      (when (string-match
             (concat "^ *[0-9]+: *[+*]*\\([^ ]+\\) +\\([0-9]+\\)/[0-9]+x\\([0-9]+\\)/[0-9]+"
                     "\\+\\(-?[0-9]+\\)\\+\\(-?[0-9]+\\)")
             line)
        (push (list :name (match-string 1 line) :make "" :model "" :serial ""
                    :geometry (list (string-to-number (match-string 4 line))
                                    (string-to-number (match-string 5 line))
                                    (string-to-number (match-string 2 line))
                                    (string-to-number (match-string 3 line))))
              out)))
    (nreverse out)))

(defun drgnx-platform--x11-doctor (env)
  "Monitors from `xrandr --listmonitors' (batch Emacs only; a frame asks Emacs itself), synchronous."
  (if (not noninteractive)
      (list :monitors nil :answers nil)
    (let ((r (drgnx-platform-call-sync
              '("xrandr" "--listmonitors")
              :env (delq nil (mapcar (lambda (v) (when-let* ((x (funcall env v))) (concat v "=" x)))
                                     drgnx-platform-env-vars)))))
      (list :monitors (and (eq (car r) 'ok) (drgnx-platform--xrandr-monitors (cdr r)))
            :answers (list (cons "xrandr" (if (eq (car r) 'ok) "answered" (format "%s: %s" (car r) (cdr r)))))))))

;;;; Built-in adapters: gnome (explains, does not move)

(defconst drgnx-platform--gnome-cannot-move
  '("GNOME does not let apps move their windows"
    . "press Super+Shift+→ or Super+Shift+← (GNOME's \"Move window one monitor to the right/left\")"))

(defun drgnx-platform--dict-ref (dict key)
  "The value of KEY in a D-Bus a{sv} DICT as dbus.el returns it: entries (KEY VALUE) or (KEY . VALUE)."
  (let ((v (cdr (assoc key dict)))) (if (consp v) (car v) v)))

(defun drgnx-platform--dbus-monitors (state)
  "Monitor plists from a Mutter DisplayConfig GetCurrentState reply STATE (serial monitors logical props)."
  (let* ((monitors (nth 1 state)) (logical (nth 2 state))
         (physical-p (equal 2 (drgnx-platform--dict-ref (nth 3 state) "layout-mode")))
         out)
    (dolist (lm logical)
      (let ((x (nth 0 lm)) (y (nth 1 lm)) (scale (or (nth 2 lm) 1.0)))
        (dolist (spec (nth 5 lm))
          (let* ((entry (seq-find (lambda (m) (equal (car (car m)) (car spec))) monitors))
                 (ids (car entry))
                 (mode (seq-find (lambda (md) (drgnx-platform--dict-ref (nth 6 md) "is-current")) (nth 1 entry)))
                 (w (nth 1 mode)) (h (nth 2 mode)))
            (push (list :name (or (nth 0 ids) "") :make (or (nth 1 ids) "") :model (or (nth 2 ids) "")
                        :serial (or (nth 3 ids) "")
                        :geometry (list x y
                                        (and w (if physical-p w (round (/ w scale))))
                                        (and h (if physical-p h (round (/ h scale))))))
                  out)))))
    (nreverse out)))

(defun drgnx-platform--gnome-doctor (env)
  "Monitors from Mutter's DisplayConfig when the D-Bus call answers within `drgnx-platform-doctor-timeout'."
  (let ((answer
         (and (require 'dbus nil t) (fboundp 'dbus-call-method)
              (let ((process-environment
                     (append (delq nil (mapcar (lambda (v) (when-let* ((x (funcall env v))) (concat v "=" x)))
                                               '("DBUS_SESSION_BUS_ADDRESS")))
                             process-environment)))
                (ignore-errors
                  (dbus-call-method :session "org.gnome.Mutter.DisplayConfig"
                                    "/org/gnome/Mutter/DisplayConfig" "org.gnome.Mutter.DisplayConfig"
                                    "GetCurrentState"
                                    :timeout (round (* 1000 drgnx-platform-doctor-timeout))))))))
    (list :monitors (and answer (ignore-errors (drgnx-platform--dbus-monitors answer)))
          :answers (list (cons "Mutter DisplayConfig"
                               (if answer "answered"
                                 (format "did not answer within %s s" drgnx-platform-doctor-timeout)))))))

;;;; Built-in adapters: other-wayland, tty, none

(defun drgnx-platform--other-wayland-can-move (ctx)
  (let* ((d (funcall (plist-get ctx :env) "XDG_CURRENT_DESKTOP"))
         (who (if (and d (not (string-empty-p d))) d "This compositor")))
    (cons (format "%s: drgnx has no adapter for this compositor" who)
          "use its own key to move a window to another output")))

(defun drgnx-platform--no-monitor (_ctx) '("a terminal window has no monitor" . nil))

;;;; Registration, in detection order (later milestones' adapters extend the declared ones)

(drgnx-platform-define-adapter
 'ns :title "macOS" :status 'verified
 :detect (lambda (_env ws) (eq ws 'ns))
 :monitors #'drgnx-platform--emacs-monitors :frame-monitor #'drgnx-platform--emacs-frame-monitor
 :move #'drgnx-platform--move-by-position :can-move #'drgnx-platform--graphic-can-move
 :doctor (lambda (_env) (list :monitors nil :answers nil)))

(drgnx-platform-define-adapter
 'sway :title "sway" :tool "swaymsg" :version '("swaymsg" "-t" "get_version") :status 'verified
 :detect (drgnx-platform--wayland-var "SWAYSOCK"))
(drgnx-platform-define-adapter
 'hyprland :title "Hyprland" :tool "hyprctl" :version '("hyprctl" "version") :status 'reported
 :detect (drgnx-platform--wayland-var "HYPRLAND_INSTANCE_SIGNATURE"))
(drgnx-platform-define-adapter
 'niri :title "niri" :tool "niri" :version '("niri" "--version") :status 'reported
 :detect (drgnx-platform--wayland-var "NIRI_SOCKET"))
(drgnx-platform-define-adapter
 'kwin :title "KDE Plasma (KWin)" :status 'verified
 :detect (drgnx-platform--wayland-desktop "KDE"))

(drgnx-platform-define-adapter
 'gnome :title "GNOME (Mutter)" :status 'verified
 :detect (drgnx-platform--wayland-desktop "GNOME")
 :monitors #'drgnx-platform--emacs-monitors
 :frame-monitor (lambda (_ctx callback) (drgnx-platform--later (lambda () (funcall callback nil))))
 :can-move (lambda (_ctx) drgnx-platform--gnome-cannot-move)
 :doctor #'drgnx-platform--gnome-doctor)

(drgnx-platform-define-adapter
 'i3 :title "i3" :tool "i3-msg" :version '("i3-msg" "-t" "get_version") :status 'verified
 :detect #'drgnx-platform--i3-detect)

(drgnx-platform-define-adapter
 'x11 :title "X11" :tool "xrandr" :version '("xrandr" "--version") :status 'verified
 :detect (lambda (env ws) (and (eq (drgnx-platform--effective-ws env ws) 'x)
                               (not (drgnx-platform--wayland-p env ws))))
 :monitors #'drgnx-platform--emacs-monitors :frame-monitor #'drgnx-platform--emacs-frame-monitor
 :move #'drgnx-platform--move-by-position :can-move #'drgnx-platform--graphic-can-move
 :doctor #'drgnx-platform--x11-doctor)

(drgnx-platform-define-adapter
 'tty :title "terminal" :status 'verified
 :detect (lambda (_env ws) (eq ws 'tty))
 :can-move #'drgnx-platform--no-monitor
 :frame-monitor (lambda (_ctx callback) (drgnx-platform--later (lambda () (funcall callback nil)))))

(drgnx-platform-define-adapter
 'other-wayland :title "another Wayland compositor" :status 'verified
 :detect #'drgnx-platform--wayland-p
 :can-move #'drgnx-platform--other-wayland-can-move)

(drgnx-platform-define-adapter
 'none :title "no display" :status 'verified
 :detect (lambda (_env _ws) t)
 :can-move #'drgnx-platform--no-monitor
 :frame-monitor (lambda (_ctx callback) (drgnx-platform--later (lambda () (funcall callback nil)))))

(provide 'drgnx-platform)
;;; drgnx-platform.el ends here
