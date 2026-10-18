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
(defcustom drgnx-platform-watchdog-margin 1.0
  "Seconds added to an operation's deadline before the public function gives up waiting for its adapter.
The adapter's calls each have the deadline; the watchdog catches an adapter that never calls back
\(an error in one of its own timers or callbacks) and reports (:error \"timed out\") once."
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
      (let* ((chunks nil) (timer nil) (finished nil) (proc nil) (errproc nil) (exit nil)
             (errbuf (generate-new-buffer " *drgnx-wm-stderr*" t))
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
                        (err (if (buffer-live-p errbuf) (with-current-buffer errbuf (buffer-string)) "")))
                    (when (buffer-live-p errbuf) (kill-buffer errbuf))
                    (funcall cb status (if (and (string-empty-p out) (not (eq status 'ok))) err out))))))
             ;; a failed call is reported once its standard error has been read to the end (its own pipe)
             (maybe-finish
              (lambda ()
                (when (and exit (or (eq exit 'ok) (not (process-live-p errproc))))
                  (funcall finish exit nil)))))
        (condition-case err
            (let ((process-environment (append env process-environment)))
              (setq proc (make-process
                          :name "drgnx-wm" :command argv :connection-type 'pipe :noquery t
                          :coding 'utf-8 :buffer nil :stderr errbuf
                          :filter (lambda (_p s) (push s chunks))
                          :sentinel (lambda (p _e)
                                      (unless (process-live-p p)
                                        (setq exit (if (eq (process-exit-status p) 0) 'ok 'error))
                                        (funcall maybe-finish)))))
              (when-let* ((p (get-buffer-process errbuf)))
                (setq errproc p)
                (set-process-coding-system p 'utf-8 'utf-8)
                (set-process-sentinel p (lambda (_p _e) (funcall maybe-finish)))
                (set-process-query-on-exit-flag p nil))
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

(defvar drgnx-platform--registering-builtins nil
  "Non-nil while the built-in adapters are defined: they are appended in the order written.")

(defun drgnx-platform-define-adapter (name &rest spec)
  "Define (or extend: keys given here replace those of an earlier definition) the adapter NAME.
SPEC keys: :detect (fn ENV WINDOW-SYSTEM -> non-nil), :title, :tool, :version (argv), :status
(`verified' or `reported'), :monitors (fn CTX CALLBACK), :frame-monitor (fn CTX CALLBACK), :move
(fn CTX MONITOR CALLBACK), :place (fn CTX MONITOR CALLBACK; default :move), :can-move (fn CTX -> t or
\(REASON . FIX)), :doctor (fn ENV -> plist :monitors :answers).  A new adapter is tried before `x11'
(so one for an X window manager like bspwm or xmonad wins over plain X) and before the catch-alls `tty',
`other-wayland' and `none'."
  (let ((cell (assq name drgnx-platform--adapters)))
    (if cell
        (let ((old (cdr cell)) (new (copy-sequence spec)))
          (while new (setq old (plist-put old (pop new) (pop new))))
          (setcdr cell old))
      (let* ((entry (cons name (copy-sequence spec)))
             (tail (and (not drgnx-platform--registering-builtins)
                        (seq-some (lambda (n) (memq (assq n drgnx-platform--adapters) drgnx-platform--adapters))
                                  '(x11 tty other-wayland none)))))
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
                    ;; an adapter's detect function that signals matches nothing
                    (and (ignore-errors (funcall fn env wsys)) (car cell))))
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
  (condition-case err
      (let* ((ctx (drgnx-platform-ctx frame)) (spec (drgnx-platform-adapter (plist-get ctx :wm))))
        (cond ((plist-get spec :can-move) (funcall (plist-get spec :can-move) ctx))
              ((plist-get spec :move) t)
              (t (cons (format "drgnx has no adapter to move windows here (%s)"
                               (or (plist-get spec :title) (plist-get ctx :wm)))
                       nil))))
    (error (cons (format "the window-manager adapter failed: %s" (error-message-string err)) nil))))

(defun drgnx-platform--reason (can)
  (if (consp can) (concat (car can) (and (cdr can) (concat " — " (cdr can)))) "cannot move"))

(defun drgnx-platform--error-p (r) (and (consp r) (eq (car r) :error)))

(defun drgnx-platform--operation (timeout callback starter transform)
  "Run STARTER with an adapter callback; CALLBACK gets what TRANSFORM makes of the adapter's answer, or
(:error MESSAGE) when the adapter or TRANSFORM signals, or (:error \"timed out\") when the adapter has not
answered `drgnx-platform-watchdog-margin' seconds after TIMEOUT.  CALLBACK runs exactly once, later."
  (let* ((cb (drgnx-platform--once callback)) (timer nil)
         (reply (lambda (r)
                  (when timer (cancel-timer timer))
                  (funcall cb (condition-case err
                                  (if (drgnx-platform--error-p r) r (funcall transform r))
                                (error (list :error (error-message-string err))))))))
    (setq timer (run-at-time (+ timeout drgnx-platform-watchdog-margin) nil
                             (lambda () (funcall cb (list :error "timed out")))))
    (condition-case err (funcall starter reply)
      (error (let ((msg (error-message-string err)))
               (drgnx-platform--later (lambda () (funcall reply (list :error msg)))))))
    nil))

(defun drgnx-platform--refuse (callback result)
  "Later, call CALLBACK once with RESULT."
  (let ((cb (drgnx-platform--once callback)))
    (drgnx-platform--later (lambda () (funcall cb result)))))

(defun drgnx-platform-monitors (frame callback)
  "Call CALLBACK with FRAME's monitors, numbered (`drgnx-platform-number-monitors'), or (:error MESSAGE)."
  (let* ((ctx (drgnx-platform-ctx frame)) (fn (drgnx-platform--spec (plist-get ctx :wm) :monitors)))
    (if (not fn)
        (drgnx-platform--refuse
         callback (list :error (drgnx-platform--reason (drgnx-platform-can-move frame))))
      (drgnx-platform--operation (plist-get ctx :timeout) callback
                                 (lambda (reply) (funcall fn ctx reply))
                                 #'drgnx-platform-number-monitors))))

(defun drgnx-platform-frame-monitor (frame callback)
  "Call CALLBACK with the monitor FRAME is on (a plist), or nil when unknown, failing or not applicable."
  (let* ((ctx (drgnx-platform-ctx frame)) (fn (drgnx-platform--spec (plist-get ctx :wm) :frame-monitor))
         (done (lambda (r) (funcall callback (and (not (drgnx-platform--error-p r)) r)))))
    (if (not fn)
        (drgnx-platform--refuse done nil)
      (drgnx-platform--operation (plist-get ctx :timeout) done
                                 (lambda (reply) (funcall fn ctx reply))
                                 #'identity))))

(defun drgnx-platform--move (key timeout frame monitor callback)
  (let* ((ctx (drgnx-platform-ctx frame timeout))
         (spec (drgnx-platform-adapter (plist-get ctx :wm)))
         (fn (or (plist-get spec key) (plist-get spec :move)))
         (can (drgnx-platform-can-move frame)))
    (if (or (not fn) (not (eq can t)))
        (drgnx-platform--refuse callback (list :error (drgnx-platform--reason can)))
      (drgnx-platform--operation timeout callback
                                 (lambda (reply) (funcall fn ctx monitor reply))
                                 (lambda (_r) 'ok)))))

(defun drgnx-platform-move-frame (frame monitor callback)
  "Move FRAME to MONITOR (a plist); a command's path, so `drgnx-platform-command-timeout'.
CALLBACK gets `ok' or (:error MESSAGE)."
  (drgnx-platform--move :move drgnx-platform-command-timeout frame monitor callback))

(defun drgnx-platform-place-frame (frame monitor callback)
  "Place FRAME on MONITOR while restoring; `drgnx-platform-restore-timeout'.  CALLBACK as above."
  (drgnx-platform--move :place drgnx-platform-restore-timeout frame monitor callback))

;;;; Monitors: numbering, labels, matching

(defun drgnx-platform--geometry (m)
  "M's geometry as a list (X Y W H) (a saved one may have been read back as a vector)."
  (append (plist-get m :geometry) nil))

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
        (name (plist-get saved :name)) (geometry (drgnx-platform--geometry saved)))
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
             (seq-find (lambda (m) (equal (drgnx-platform--geometry m) geometry)) monitors)))))

;;;; Built-in adapters: frame positions (x11, ns)

(defun drgnx-platform--attrs-monitor (attrs &optional frame)
  "A monitor plist from an entry of `display-monitor-attributes-list'.
Under pgtk the name is GDK's model string (\"Unknown\", \"MetaVirtualMonitor\"), not the compositor's output
name: it is no identity, so the monitor of a pgtk FRAME gets the name \"\" (only an adapter that knows the
compositor vouches for a name)."
  (list :name (if (eq (and frame (drgnx-platform--frame-window-system frame)) 'pgtk)
                  ""
                (or (alist-get 'name attrs) ""))
        :make "" :model "" :serial ""
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
     callback (lambda () (mapcar (lambda (a) (drgnx-platform--attrs-monitor a frame)) (display-monitor-attributes-list frame))))))

(defun drgnx-platform--emacs-frame-monitor (ctx callback)
  "CALLBACK with the monitor CTX's frame is on, later."
  (let ((frame (plist-get ctx :frame)))
    (drgnx-platform--answer-later
     callback (lambda () (and (frame-live-p frame)
                              (drgnx-platform--attrs-monitor (frame-monitor-attributes frame) frame))))))

(defun drgnx-platform--graphic-can-move (ctx)
  (if (display-graphic-p (plist-get ctx :frame)) t
    '("a terminal window has no monitor" . nil)))

(defun drgnx-platform--position (v)
  "V as a `left' or `top' frame parameter: a negative number is an offset from the left/top, (+ V)."
  (if (< v 0) (list '+ v) v))

(defun drgnx-platform--move-by-position (ctx monitor callback)
  "Keep the frame's `fullscreen' value, clear it, set `left' and `top' to MONITOR's workarea origin,
re-apply the value (the window manager moves a frame by position; a fullscreen one would not move).
A negative coordinate is written (+ N): a plain negative integer would count from the right or bottom edge.
On macOS a natively fullscreen frame lives in its own Space; whether clearing `fullscreen' moves it back to
a desktop first is for the macOS tier to check."
  (let* ((frame (plist-get ctx :frame))
         (area (or (plist-get monitor :workarea) (plist-get monitor :geometry)))
         (fs (frame-parameter frame 'fullscreen)))
    (set-frame-parameter frame 'fullscreen nil)
    (set-frame-parameter frame 'left (drgnx-platform--position (nth 0 area)))
    (set-frame-parameter frame 'top (drgnx-platform--position (nth 1 area)))
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
  "Monitors from Mutter's DisplayConfig when the D-Bus call answers within `drgnx-platform-doctor-timeout'.
The :session connection is opened once, from the daemon's environment at that time: binding
DBUS_SESSION_BUS_ADDRESS here does not select another frame's session bus (it only helps while no
connection has been made yet).  The doctor reports the daemon's session."
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

(setq drgnx-platform--registering-builtins t)

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

(setq drgnx-platform--registering-builtins nil)

;;;; sway and i3
;; Both speak the same IPC through swaymsg and i3-msg (`-t get_outputs', `-t get_tree', a command string with a
;; criteria prefix), so one set of functions serves both; WM is `sway' or `i3'.  Facts: m12c facts, "sway IPC
;; facts" and "X11: Xvfb and i3".  sway finds a window by `pid' and title (con_id); i3 has no pid in its tree and
;; finds it by the X window id, which is the frame parameter `outer-window-id'.

(defconst drgnx-platform-wm--refusal
  "drgnx moves only its own window while it has focus: click this window, then run the command again"
  "Why a move is refused when the focused window is not this frame.")

(defconst drgnx-platform-wm--place-polls '(0.1 0.3 0.7 1.5 3.0)
  "Seconds after the start of a placement at which the tree is read; later one more every second.")

(defvar drgnx-platform-wm--place-counter 0 "Makes each placing title unique.")

(defun drgnx-platform-wm--parse (text)
  "TEXT (JSON) as plists and lists (null and false are nil), or nil when it is not JSON."
  (and (stringp text) (not (string-blank-p text))
       (condition-case nil
           (json-parse-string text :object-type 'plist :array-type 'list :null-object nil :false-object nil)
         (error nil))))

(defun drgnx-platform-wm--sway-monitors (json)
  "Monitor plists (:name :make :model :serial :geometry) of the active outputs in JSON, a `get_outputs' reply.
An inactive output stays in the reply with a zero rectangle and is left out.  i3 has no make, model or serial."
  (let (out)
    (dolist (o (drgnx-platform-wm--parse json))
      (when (and (consp o) (plist-get o :active))
        (let ((r (plist-get o :rect)))
          (push (list :name (or (plist-get o :name) "") :make (or (plist-get o :make) "")
                      :model (or (plist-get o :model) "") :serial (or (plist-get o :serial) "")
                      :geometry (list (plist-get r :x) (plist-get r :y) (plist-get r :width) (plist-get r :height)))
                out))))
    (nreverse out)))

(defun drgnx-platform-wm--cons (tree)
  "The window cons of TREE (a `get_tree' reply, parsed), depth first, as plists
\(:id :pid :name :output :fullscreen :focused :window).  Split containers, workspaces and outputs are not windows."
  (let (out)
    (cl-labels ((walk (node output)
                  (let ((type (plist-get node :type)))
                    (when (equal type "output") (setq output (plist-get node :name)))
                    (when (and (member type '("con" "floating_con"))
                               (or (plist-get node :pid) (plist-get node :window)))
                      (push (list :id (plist-get node :id) :pid (plist-get node :pid) :name (plist-get node :name)
                                  :output output :focused (plist-get node :focused)
                                  :fullscreen (let ((m (plist-get node :fullscreen_mode))) (and (memql m '(1 2)) m))
                                  :window (plist-get node :window))
                            out))
                    (dolist (c (append (plist-get node :nodes) (plist-get node :floating_nodes)))
                      (walk c output)))))
      (walk tree nil))
    (nreverse out)))

(defun drgnx-platform-wm--sway-focused (tree)
  "The focused window con of TREE (:id :pid :output :fullscreen :name ...), or nil."
  (seq-find (lambda (c) (plist-get c :focused)) (drgnx-platform-wm--cons tree)))

(defun drgnx-platform-wm--sway-find (tree pid title)
  "The window con of TREE with process PID and the window title TITLE, or nil."
  (seq-find (lambda (c) (and (eql (plist-get c :pid) pid) (equal (plist-get c :name) title)))
            (drgnx-platform-wm--cons tree)))

(defun drgnx-platform-wm--i3-find (tree xid)
  "The window con of TREE whose X window id is XID, or nil."
  (seq-find (lambda (c) (eql (plist-get c :window) xid)) (drgnx-platform-wm--cons tree)))

(defun drgnx-platform-wm--label (wm) (if (eq wm 'i3) "i3" "sway"))
(defun drgnx-platform-wm--tool (wm) (if (eq wm 'i3) "i3-msg" "swaymsg"))

(defun drgnx-platform-wm--need-tool (wm)
  "Signal the message for a missing tool; the operation turns it into (:error MESSAGE)."
  (unless (executable-find (drgnx-platform-wm--tool wm))
    (error "%s: %s is not installed, so drgnx cannot move windows"
           (drgnx-platform-wm--label wm) (drgnx-platform-wm--tool wm))))

(defun drgnx-platform-wm--xid (frame)
  "FRAME's X window id (its `outer-window-id' parameter) as a number."
  (let ((id (frame-parameter frame 'outer-window-id)))
    (or (and id (let ((n (if (numberp id) id (string-to-number id)))) (and (> n 0) n)))
        (error "i3: this frame has no X window id, so drgnx cannot move it"))))

(defun drgnx-platform-wm--selector (wm con)
  "The criteria prefix that picks CON in a command."
  (if (eq wm 'i3) (format "[id=%d]" (plist-get con :window)) (format "[con_id=%d]" (plist-get con :id))))

(defun drgnx-platform-wm--output-arg (monitor)
  "MONITOR's output name as the argument of `move container to output', quoted when it needs it."
  (let ((name (plist-get monitor :name)))
    (unless (drgnx-platform--filled name) (error "this monitor has no output name, so drgnx cannot move the window to it"))
    (when (string-match-p "[[:cntrl:]]" name) (error "this monitor's output name has a control character, so drgnx cannot move the window to it"))
    (if (string-match-p "\\`[A-Za-z0-9_.:-]+\\'" name) name
      (concat "\"" (replace-regexp-in-string "[\"\\]" "\\\\\\&" name) "\""))))

(defun drgnx-platform-wm--json-error (text)
  "The `error' text of the first failed command in TEXT (a reply array), or nil."
  (let ((r (drgnx-platform-wm--parse text)))
    (when (and (consp r) (consp (car r)))
      (when-let* ((bad (seq-find (lambda (e) (and (plist-member e :success) (not (plist-get e :success)))) r)))
        (or (plist-get bad :error) "the command failed")))))

(defun drgnx-platform-wm--failure (wm ctx status out what)
  "The message for a call that failed (STATUS, OUT as `drgnx-platform-call' gives them), or nil.
WHAT, when given, ends the timeout message (\"the window was not moved\")."
  (cond ((eq status 'timeout)
         (format "%s did not answer within %g s%s" (drgnx-platform-wm--label wm) (plist-get ctx :timeout)
                 (if what (concat "; " what) "")))
        ((eq status 'error)
         (or (drgnx-platform-wm--json-error out)
             (let ((s (string-trim (or out ""))))
               (if (string-empty-p s) (format "%s failed" (drgnx-platform-wm--tool wm)) s))))
        (t (drgnx-platform-wm--json-error out))))

(defun drgnx-platform-wm--run (wm ctx until args fail k)
  "Run the tool of WM with ARGS and call K with STATUS and OUTPUT, inside the operation's deadline UNTIL
\(a `float-time').  A signal in K is passed to FAIL as (:error MESSAGE)."
  (drgnx-platform-ctx-call
   (plist-put (copy-sequence ctx) :timeout (max 0.05 (- until (float-time))))
   (cons (drgnx-platform-wm--tool wm) args)
   (lambda (status out)
     (condition-case err (funcall k status out)
       (error (funcall fail (list :error (error-message-string err))))))))

(defun drgnx-platform-wm--tree (wm ctx until what fail k)
  "Read the window tree; K gets (TREE ERROR): the parsed tree or nil, and a message or nil."
  (drgnx-platform-wm--run
   wm ctx until '("-t" "get_tree") fail
   (lambda (status out)
     (let ((err (drgnx-platform-wm--failure wm ctx status out what)))
       (funcall k (and (not err) (drgnx-platform-wm--parse out)) err)))))

(defun drgnx-platform-wm--command (wm ctx until what command fail k)
  "Run COMMAND (one argument); K gets nil or the message of the failure, and the call's STATUS."
  (drgnx-platform-wm--run
   wm ctx until (list command) fail
   (lambda (status out) (funcall k (drgnx-platform-wm--failure wm ctx status out what) status))))

(defun drgnx-platform-wm--monitors (wm ctx callback)
  "The adapter's :monitors for WM."
  (drgnx-platform-wm--need-tool wm)
  (let ((until (+ (float-time) (plist-get ctx :timeout))))
    (drgnx-platform-wm--run
     wm ctx until '("-t" "get_outputs") callback
     (lambda (status out)
       (let ((err (drgnx-platform-wm--failure wm ctx status out nil)))
         (funcall callback
                  (cond (err (list :error err))
                        ((drgnx-platform-wm--sway-monitors out))
                        (t (list :error (format "%s lists no active output" (drgnx-platform-wm--label wm)))))))))))

(defun drgnx-platform-wm--move-con (wm ctx until con monitor focus callback)
  "Move CON to MONITOR's output; with FOCUS take focus again, and keep a fullscreen window fullscreen.
Task 1 found fullscreen kept by the move; `fullscreen enable' is idempotent, so it is re-applied anyway
\(mode 1: on its output; mode 2: `fullscreen enable global').  CALLBACK gets `ok' or (:error MESSAGE).
The core's callback has no \"succeeded with a warning\", so when the move worked and the follow-up did not,
the error says the window WAS moved and what was not restored."
  (let* ((sel (drgnx-platform-wm--selector wm con)) (what "the window was not moved")
         (fail callback)
         (fs (pcase (plist-get con :fullscreen) (1 "fullscreen enable") (2 "fullscreen enable global"))))
    (drgnx-platform-wm--command
     wm ctx until what (format "%s move container to output %s" sel (drgnx-platform-wm--output-arg monitor)) fail
     (lambda (err _status)
       (let* ((more (append (and focus (list (format "%s focus" sel)))
                            (and fs (list (format "%s %s" sel fs)))))
              (lost (if focus "focus" "fullscreen"))
              (what (format "the window was moved but %s was not restored" lost)))
         (cond (err (funcall callback (list :error err)))
               ((null more) (funcall callback 'ok))
               (t (drgnx-platform-wm--command
                   wm ctx until what (string-join more "; ") fail
                   (lambda (err status)
                     (funcall callback
                              (cond ((null err) 'ok)
                                    ;; a timeout message already ends with WHAT
                                    ((eq status 'timeout) (list :error err))
                                    (t (list :error (format "%s: %s (%s)" (drgnx-platform-wm--label wm) what err))))))))))))))

(defun drgnx-platform-wm--own-focused-con (wm tree frame)
  "The focused window con of TREE when it is FRAME's own and FRAME has focus, else nil."
  (when (eq (frame-focus-state frame) t)
    (let ((focused (seq-find (lambda (c) (plist-get c :focused)) (drgnx-platform-wm--cons tree))))
      (and focused
           (if (eq wm 'i3)
               (eql (plist-get focused :window) (drgnx-platform-wm--xid frame))
             (eql (plist-get focused :pid) (emacs-pid)))
           focused))))

(defun drgnx-platform-wm--move (wm ctx monitor callback)
  "The adapter's :move for WM: only the focused window of this Emacs, and focus stays with it."
  (drgnx-platform-wm--need-tool wm)
  (let ((until (+ (float-time) (plist-get ctx :timeout))) (frame (plist-get ctx :frame))
        (what "the window was not moved"))
    (drgnx-platform-wm--output-arg monitor)
    (drgnx-platform-wm--tree
     wm ctx until what callback
     (lambda (tree err)
       (let ((con (and tree (drgnx-platform-wm--own-focused-con wm tree frame))))
         (cond (err (funcall callback (list :error err)))
               ((null tree) (funcall callback (list :error (format "%s gave no window tree" (drgnx-platform-wm--tool wm)))))
               ((null con) (funcall callback (list :error drgnx-platform-wm--refusal)))
               (t (drgnx-platform-wm--move-con wm ctx until con monitor t callback))))))))

(defun drgnx-platform-wm--place (wm ctx monitor callback)
  "The adapter's :place for WM: find the restored window, then move it without taking focus.
sway: the frame's `title' parameter is set to \"drgnx [placing PID-N]\" so the window can be told from the
other frames of this process; the previous value is put back however the placement ends.  The tree is read
at `drgnx-platform-wm--place-polls' seconds, then every second, until the window shows or the deadline passes."
  (drgnx-platform-wm--need-tool wm)
  (let* ((frame (plist-get ctx :frame)) (start (float-time)) (until (+ start (plist-get ctx :timeout)))
         (what "the window was not placed") (old-title (frame-parameter frame 'title))
         (xid (and (eq wm 'i3) (drgnx-platform-wm--xid frame)))
         (title (and (eq wm 'sway)
                     (format "drgnx [placing %d-%d]" (emacs-pid) (cl-incf drgnx-platform-wm--place-counter))))
         (done nil) (timers nil) (n 0) finish poll)
    (drgnx-platform-wm--output-arg monitor)
    (setq finish (lambda (result)
                   (unless done
                     (setq done t)
                     (mapc #'cancel-timer timers)
                     (when (and title (frame-live-p frame))
                       (ignore-errors (set-frame-parameter frame 'title old-title)))
                     (funcall callback result)))
          poll (lambda ()
                 (unless done
                   (drgnx-platform-wm--tree
                    wm ctx until what finish
                    (lambda (tree err)
                      (let ((con (and tree (if xid (drgnx-platform-wm--i3-find tree xid)
                                             (drgnx-platform-wm--sway-find tree (emacs-pid) title)))))
                        (cond (done)
                              (err (funcall finish (list :error err)))
                              (con (drgnx-platform-wm--move-con wm ctx until con monitor nil finish))
                              (t (let ((at (+ start (or (nth n drgnx-platform-wm--place-polls)
                                                        (+ 3.0 (- n (1- (length drgnx-platform-wm--place-polls))))))))
                                   (cl-incf n)
                                   (when (< at until)
                                     (push (run-at-time (max 0 (- at (float-time))) nil poll) timers)))))))))))
    (push (run-at-time (plist-get ctx :timeout) nil
                       (lambda () (funcall finish (list :error (format "%s did not show the window within %g s; %s"
                                                                       (drgnx-platform-wm--label wm)
                                                                       (plist-get ctx :timeout) what)))))
          timers)
    (when title (set-frame-parameter frame 'title title))
    ;; the first read waits for the first poll time, so the title has reached the window manager
    (push (run-at-time (car drgnx-platform-wm--place-polls) nil
                       (lambda () (setq n 1) (funcall poll)))
          timers)))

(dolist (wm '(sway i3))
  (let ((wm wm))
    (drgnx-platform-define-adapter
     wm
     :monitors (lambda (ctx callback) (drgnx-platform-wm--monitors wm ctx callback))
     ;; Emacs' own answer (its geometry matches an output's): Next and Previous need the current monitor
     :frame-monitor #'drgnx-platform--emacs-frame-monitor
     :move(lambda (ctx monitor callback) (drgnx-platform-wm--move wm ctx monitor callback))
     :place (lambda (ctx monitor callback) (drgnx-platform-wm--place wm ctx monitor callback)))))

;;;; Hyprland and niri (reported: written from their sources and documented replies, not yet run on the real WM)

;; Both adapters share one contract.  `monitors' lists the outputs.  A command move acts on the focused window
;; only when it is Emacs' own (pid) and the frame has focus; a restore (`place') finds the window by Emacs' pid
;; and a temporary title, polling, and gives the title back whatever happens.  A move makes several calls, so
;; they share ONE deadline (the operation's timeout, `drgnx-platform-wm--hn-caller'): the watchdog margin stays
;; the default.

(defconst drgnx-platform-wm--hn-not-focused
  "drgnx moves only its own window while it has focus: click this window, then run the command again"
  "The answer to a command move when Emacs' window is not the focused one.")

(defconst drgnx-platform-wm--hn-poll-times '(0.1 0.3 0.7 1.5 3.0)
  "Seconds after setting the temporary title at which a restored window is looked for.")

(defvar drgnx-platform-wm--hn-placing-counter 0 "Makes each temporary title unique.")

(defun drgnx-platform-wm--hn-json (text)
  "TEXT parsed: objects as alists (symbol keys), arrays as lists, null and false as nil."
  (json-parse-string text :object-type 'alist :array-type 'list :null-object nil :false-object nil))

(defun drgnx-platform-wm--hn-refuse (callback message)
  "Later, call CALLBACK with (:error MESSAGE)."
  (drgnx-platform--later (lambda () (funcall callback (list :error message)))))

(defun drgnx-platform-wm--hn-caller (name ctx &optional moving end late)
  "A function (ARGV ON-OK FAIL) running ARGV for the adapter NAME inside ONE deadline: CTX's timeout from now.
ON-OK gets the output; FAIL gets (:error MESSAGE) for a missing tool, a failed call (the tool's own text) or the
deadline.  A signal in ON-OK also goes to FAIL.  MOVING adds \"the window was not moved\" to the timeout message.
END (a `float-time') replaces the deadline so that several callers share one; LATE replaces the timeout message."
  (let* ((limit (plist-get ctx :timeout)) (end (or end (+ (float-time) limit)))
         (title (or (drgnx-platform--spec name :title) (symbol-name name)))
         (tool (drgnx-platform--spec name :tool))
         (late (or late (format "%s did not answer within %g s%s" title limit (if moving "; the window was not moved" "")))))
    (lambda (argv on-ok fail)
      (let ((left (- end (float-time))))
        (cond
         ((not (executable-find (car argv)))
          (drgnx-platform-wm--hn-refuse
           fail (format "%s: %s is not installed, so drgnx cannot move windows" title (or tool (car argv)))))
         ((< left 0.05) (drgnx-platform-wm--hn-refuse fail late))
         (t (drgnx-platform-ctx-call
             (plist-put (copy-sequence ctx) :timeout left) argv
             (lambda (status output)
               (condition-case err
                   (pcase status
                     ('ok (funcall on-ok output))
                     ('timeout (funcall fail (list :error late)))
                     (_ (funcall fail (list :error (let ((m (string-trim output))) (if (string-empty-p m) "the call failed" m))))))
                 (error (funcall fail (list :error (error-message-string err)))))))))))))

(defun drgnx-platform-wm--hn-own-focused-p (ctx)
  "Non-nil when CTX's frame has input focus."
  (eq (frame-focus-state (plist-get ctx :frame)) t))

(defun drgnx-platform-wm--hn-place (name ctx callback list-argv find move)
  "Place CTX's frame for the adapter NAME (the restore path), then call CALLBACK with `ok' or (:error MESSAGE).
Sets the frame's `title' to a temporary one, runs LIST-ARGV at `drgnx-platform-wm--hn-poll-times' until
\(FIND OUTPUT PID TITLE) gives a window, calls (MOVE CALL WINDOW ON-OK FAIL) on it, and puts the previous title
back in every case.  Everything shares the one deadline of CTX.  A deadline that passes while the window is
still not found answers \"did not show the window\".  A missing tool is reported before the title is touched."
  (let* ((frame (plist-get ctx :frame)) (end (+ (float-time) (plist-get ctx :timeout)))
         (call (drgnx-platform-wm--hn-caller
                name ctx t end (format "%s did not show the window within %g s; it was not placed"
                                       (drgnx-platform--spec name :title) (plist-get ctx :timeout))))
         (move-call (drgnx-platform-wm--hn-caller name ctx t end))
         (previous (frame-parameter frame 'title)) (done nil)
         (title (format "drgnx [placing %d-%d]" (emacs-pid) (cl-incf drgnx-platform-wm--hn-placing-counter)))
         (start (float-time))
         (finish (lambda (r)
                   (unless done
                     (setq done t)
                     (when (frame-live-p frame) (ignore-errors (set-frame-parameter frame 'title previous)))
                     (funcall callback r)))))
    (cl-labels
        ((poll (times)
           (condition-case err
               (funcall call list-argv
                        (lambda (out)
                          (if-let* ((w (funcall find out (emacs-pid) title)))
                              (funcall move move-call w (lambda () (funcall finish 'ok)) finish)
                            (if (cdr times)
                                (run-at-time (max 0 (- (cadr times) (- (float-time) start))) nil
                                             (lambda () (poll (cdr times))))
                              (funcall finish (list :error (format "%s did not show the window within %g s; it was not placed"
                                                                   (drgnx-platform--spec name :title)
                                                                   (plist-get ctx :timeout)))))))
                        finish)
             (error (funcall finish (list :error (error-message-string err)))))))
      (if (not (executable-find (car list-argv)))
          (funcall call list-argv #'ignore callback)
        (set-frame-parameter frame 'title title)
        (run-at-time (car drgnx-platform-wm--hn-poll-times) nil (lambda () (poll drgnx-platform-wm--hn-poll-times)))))))

;;;;; Hyprland

(defvar drgnx-platform-wm--hypr-config nil
  "Alist (INSTANCE-SIGNATURE . `lua' or `hyprlang'): which dispatch syntax a running Hyprland took.
Hyprland 0.56 has a Lua config (`hyprctl dispatch' takes a Lua dispatcher) and the hyprlang one (the legacy
dispatchers).  A Lua config answers `hl.dsp...' with \"ok\"; a hyprlang config answers a dispatcher it does not
know with \"Invalid dispatcher\" (HyprCtl.cpp dispatchRequest).  That reply is the signal: the Lua form is tried
first and the first answer is remembered for the instance.")

(defun drgnx-platform-wm--hypr-window (w)
  "A window plist (:id :pid :title :fullscreen) from the window object W of `hyprctl -j', or nil."
  (when (and w (alist-get 'address w))
    (list :id (alist-get 'address w) :pid (alist-get 'pid w) :title (alist-get 'title w)
          :fullscreen (let ((f (alist-get 'fullscreen w))) (if (numberp f) f 0)))))

(defun drgnx-platform-wm--hypr-monitors (text)
  "Monitor plists from `hyprctl -j monitors' TEXT, in logical pixels (the size Emacs sees): the mode size
divided by the scale, width and height swapped for a transform of 90 or 270 degrees.  Disabled monitors are left out."
  (let (out)
    (dolist (m (drgnx-platform-wm--hn-json text))
      (unless (alist-get 'disabled m)
        (let* ((scale (let ((s (alist-get 'scale m))) (if (and (numberp s) (> s 0)) s 1)))
               (w (alist-get 'width m)) (h (alist-get 'height m))
               (turned (cl-oddp (or (alist-get 'transform m) 0))))
          (push (list :name (or (alist-get 'name m) "") :make (or (alist-get 'make m) "")
                      :model (or (alist-get 'model m) "") :serial (or (alist-get 'serial m) "")
                      :geometry (list (alist-get 'x m) (alist-get 'y m)
                                      (round (/ (if turned h w) scale)) (round (/ (if turned w h) scale))))
                out))))
    (nreverse out)))

(defun drgnx-platform-wm--hypr-focused (text)
  "The focused window (a plist) from `hyprctl -j activewindow' TEXT, or nil (Hyprland answers {}, or nothing)."
  (and (not (string-blank-p text))
       (drgnx-platform-wm--hypr-window (drgnx-platform-wm--hn-json text))))

(defun drgnx-platform-wm--hypr-find (text pid title)
  "The window of `hyprctl -j clients' TEXT with PID and TITLE (a plist), or nil."
  (seq-some (lambda (w) (and (eql (alist-get 'pid w) pid) (equal (alist-get 'title w) title)
                             (alist-get 'mapped w t) (drgnx-platform-wm--hypr-window w)))
            (drgnx-platform-wm--hn-json text)))

(defun drgnx-platform-wm--lua-string (s)
  "S as a Lua string literal."
  (let ((s (replace-regexp-in-string "[\\\\\"]" "\\\\\\&" s)))
    (dolist (c '(("\n" . "\\n") ("\r" . "\\r") ("\0" . "\\0")))
      (setq s (string-replace (car c) (cdr c) s)))
    (concat "\"" s "\"")))

(defun drgnx-platform-wm--hypr-dispatch (call args k fail)
  "Run `hyprctl dispatch ARGS...' with CALL; K gets Hyprland's reply (\"ok\" or an error text)."
  (funcall call (append '("hyprctl" "dispatch") args) (lambda (out) (funcall k (string-trim out))) fail))

(defun drgnx-platform-wm--hypr-dispatch-ok (call args on-ok fail)
  "`drgnx-platform-wm--hypr-dispatch' where anything but \"ok\" is a failure with Hyprland's own text."
  (drgnx-platform-wm--hypr-dispatch
   call args (lambda (reply) (if (equal reply "ok") (funcall on-ok) (funcall fail (list :error reply)))) fail))

(defun drgnx-platform-wm--hypr-move-legacy (ctx call address name follow focused on-ok fail)
  "Move ADDRESS to monitor NAME with the hyprlang dispatchers.  They act on the focused window: so unless it
FOCUSED already, focus it first; unless FOLLOW, move it silently and give the focus back to the window that had it.
If the move then fails (or the deadline passes) the window that had the focus gets it back, best effort, in a
call of its own (1 s) whose answer is ignored.  The arguments of a dispatcher are split at spaces and commas
and a `;' may separate commands: a name or address with such a character is refused."
  (let ((move (lambda (&optional prior)
                (drgnx-platform-wm--hypr-dispatch-ok
                 call (append (list "movewindow" (concat "mon:" name)) (unless follow '("silent")))
                 (lambda ()
                   (if prior
                       (drgnx-platform-wm--hypr-dispatch-ok call (list "focuswindow" (concat "address:" prior)) on-ok fail)
                     (funcall on-ok)))
                 (lambda (err)
                   (when prior
                     (funcall (drgnx-platform-wm--hn-caller 'hyprland (plist-put (copy-sequence ctx) :timeout 1.0))
                              (list "hyprctl" "dispatch" "focuswindow" (concat "address:" prior)) #'ignore #'ignore))
                   (funcall fail err)))))
        (focus (lambda (k)
                 (drgnx-platform-wm--hypr-dispatch-ok call (list "focuswindow" (concat "address:" address)) k fail))))
    (cond ((string-match-p "[[:space:],;]" (concat name address))
           (drgnx-platform-wm--hn-refuse
            fail (format "Hyprland: a hyprlang config cannot be given the monitor name \"%s\"" name)))
          (focused (funcall move))
          (follow (funcall focus move))
          (t (funcall call '("hyprctl" "-j" "activewindow")
                      (lambda (out)
                        (let ((prior (plist-get (drgnx-platform-wm--hypr-focused out) :id)))
                          (funcall focus (lambda () (funcall move (and prior (not (equal prior address)) prior))))))
                      fail)))))

(defun drgnx-platform-wm--hypr-send (ctx call address name follow focused on-ok fail)
  "Move the window ADDRESS to monitor NAME: the Lua form, or the hyprlang one when this instance answered the
Lua form \"Invalid dispatcher\" (remembered in `drgnx-platform-wm--hypr-config').  FOLLOW: the focus goes with
the window.  FOCUSED: the window has the focus (the hyprlang form needs it)."
  (let* ((sig (funcall (plist-get ctx :env) "HYPRLAND_INSTANCE_SIGNATURE"))
         (remember (lambda (type) (setf (alist-get sig drgnx-platform-wm--hypr-config nil nil #'equal) type)))
         (legacy (lambda ()
                   (funcall remember 'hyprlang)
                   (drgnx-platform-wm--hypr-move-legacy ctx call address name follow focused on-ok fail))))
    (if (eq (cdr (assoc sig drgnx-platform-wm--hypr-config)) 'hyprlang)
        (funcall legacy)
      (drgnx-platform-wm--hypr-dispatch
       call (list (format "hl.dsp.window.move({ window = %s, monitor = %s, follow = %s })"
                          (drgnx-platform-wm--lua-string (concat "address:" address))
                          (drgnx-platform-wm--lua-string name) (if follow "true" "false")))
       (lambda (reply)
         (cond ((equal reply "ok") (funcall remember 'lua) (funcall on-ok))
               ((string-prefix-p "Invalid dispatcher" reply) (funcall legacy))
               (t (funcall fail (list :error reply)))))
       fail))))

(defun drgnx-platform-wm--hypr-monitors-fn (ctx callback)
  (funcall (drgnx-platform-wm--hn-caller 'hyprland ctx) '("hyprctl" "-j" "monitors")
           (lambda (out) (funcall callback (drgnx-platform-wm--hypr-monitors out))) callback))

(defun drgnx-platform-wm--hypr-move (ctx monitor callback)
  "Move CTX's frame to MONITOR when it is the focused window; the focus goes with it."
  (if (not (drgnx-platform-wm--hn-own-focused-p ctx))
      (drgnx-platform-wm--hn-refuse callback drgnx-platform-wm--hn-not-focused)
    (let ((call (drgnx-platform-wm--hn-caller 'hyprland ctx t)))
      (funcall call '("hyprctl" "-j" "activewindow")
               (lambda (out)
                 (let ((w (drgnx-platform-wm--hypr-focused out)))
                   (if (not (and w (eql (plist-get w :pid) (emacs-pid))))
                       (funcall callback (list :error drgnx-platform-wm--hn-not-focused))
                     (drgnx-platform-wm--hypr-send ctx call (plist-get w :id) (plist-get monitor :name) t t
                                                   (lambda () (funcall callback 'ok)) callback))))
               callback))))

(defun drgnx-platform-wm--hypr-place (ctx monitor callback)
  "Move the restored window of CTX's frame to MONITOR without taking the focus.  A fullscreen window is moved
the other way (the focus follows): Hyprland's following move re-applies the fullscreen mode itself."
  (drgnx-platform-wm--hn-place
   'hyprland ctx callback '("hyprctl" "-j" "clients") #'drgnx-platform-wm--hypr-find
   (lambda (call w on-ok fail)
     (drgnx-platform-wm--hypr-send ctx call (plist-get w :id) (plist-get monitor :name)
                                   (> (plist-get w :fullscreen) 0) nil on-ok fail))))

;;;;; niri

(defun drgnx-platform-wm--niri-monitors (text)
  "Monitor plists from `niri msg --json outputs' TEXT (an object keyed by output name); an output without a
logical position (switched off) is left out.  The geometry is niri's logical one, the size Emacs sees."
  (let (out)
    (dolist (cell (drgnx-platform-wm--hn-json text))
      (let* ((o (cdr cell)) (l (alist-get 'logical o)))
        (when l
          (push (list :name (or (alist-get 'name o) (symbol-name (car cell))) :make (or (alist-get 'make o) "")
                      :model (or (alist-get 'model o) "") :serial (or (alist-get 'serial o) "")
                      :geometry (list (alist-get 'x l) (alist-get 'y l) (alist-get 'width l) (alist-get 'height l)))
                out))))
    (nreverse out)))

(defun drgnx-platform-wm--niri-window (w)
  (list :id (alist-get 'id w) :pid (alist-get 'pid w) :title (alist-get 'title w)))

(defun drgnx-platform-wm--niri-focused (text)
  "The focused window (a plist :id :pid :title) in `niri msg --json windows' TEXT, or nil."
  (when-let* ((w (seq-find (lambda (w) (alist-get 'is_focused w)) (drgnx-platform-wm--hn-json text))))
    (drgnx-platform-wm--niri-window w)))

(defun drgnx-platform-wm--niri-find (text pid title)
  "The window of `niri msg --json windows' TEXT with PID and TITLE (a plist), or nil."
  (when-let* ((w (seq-find (lambda (w) (and (eql (alist-get 'pid w) pid) (equal (alist-get 'title w) title)))
                           (drgnx-platform-wm--hn-json text))))
    (drgnx-platform-wm--niri-window w)))

(defun drgnx-platform-wm--niri-send (call id name on-ok fail)
  "Move the window ID to output NAME.  niri exits 0 and does nothing for an unknown output, so the output is
looked up first.  With `--id' a window that is the active one stays so, one that is not does not take the focus."
  (funcall call '("niri" "msg" "--json" "outputs")
           (lambda (out)
             (if (not (seq-some (lambda (m) (equal (plist-get m :name) name)) (drgnx-platform-wm--niri-monitors out)))
                 (funcall fail (list :error (format "niri has no output named \"%s\"; the window was not moved" name)))
               (funcall call (list "niri" "msg" "action" "move-window-to-monitor" "--id" (number-to-string id) name)
                        (lambda (_out) (funcall on-ok)) fail)))
           fail))

(defun drgnx-platform-wm--niri-monitors-fn (ctx callback)
  (funcall (drgnx-platform-wm--hn-caller 'niri ctx) '("niri" "msg" "--json" "outputs")
           (lambda (out) (funcall callback (drgnx-platform-wm--niri-monitors out))) callback))

(defun drgnx-platform-wm--niri-move (ctx monitor callback)
  "Move CTX's frame to MONITOR when it is the focused window."
  (if (not (drgnx-platform-wm--hn-own-focused-p ctx))
      (drgnx-platform-wm--hn-refuse callback drgnx-platform-wm--hn-not-focused)
    (let ((call (drgnx-platform-wm--hn-caller 'niri ctx t)))
      (funcall call '("niri" "msg" "--json" "windows")
               (lambda (out)
                 (let ((w (drgnx-platform-wm--niri-focused out)))
                   (if (not (and w (eql (plist-get w :pid) (emacs-pid))))
                       (funcall callback (list :error drgnx-platform-wm--hn-not-focused))
                     (drgnx-platform-wm--niri-send call (plist-get w :id) (plist-get monitor :name)
                                                   (lambda () (funcall callback 'ok)) callback))))
               callback))))

(defun drgnx-platform-wm--niri-place (ctx monitor callback)
  "Move the restored window of CTX's frame to MONITOR.  The window keeps its focus state, but niri warps the
cursor to the target output when a window is moved with `--id', and this cannot be turned off."
  (drgnx-platform-wm--hn-place
   'niri ctx callback '("niri" "msg" "--json" "windows") #'drgnx-platform-wm--niri-find
   (lambda (call w on-ok fail)
     (drgnx-platform-wm--niri-send call (plist-get w :id) (plist-get monitor :name) on-ok fail))))

(drgnx-platform-define-adapter
 'hyprland :monitors #'drgnx-platform-wm--hypr-monitors-fn
 :move #'drgnx-platform-wm--hypr-move :place #'drgnx-platform-wm--hypr-place)
(drgnx-platform-define-adapter
 'niri :monitors #'drgnx-platform-wm--niri-monitors-fn
 ;; Emacs' own answer (its geometry matches an output's): Next and Previous need the current monitor
 :frame-monitor #'drgnx-platform--emacs-frame-monitor
 :move #'drgnx-platform-wm--niri-move :place #'drgnx-platform-wm--niri-place)

;;;; KWin (KDE Plasma 6): its scripting API over D-Bus
;;
;; KWin has no command-line tool that lists or moves windows, so the adapter loads a small JavaScript file
;; into KWin (`/Scripting loadScript', then `/Scripting start') and the script reports back with
;; `callDBus' to a method Emacs registers for the length of the call.  Only Emacs' own `dbus.el' is used (no
;; `qdbus', no shell) and every D-Bus call is `dbus-call-method-asynchronously' with the call's deadline as
;; its `:timeout': nothing here blocks, so restore may use it.  The `Reply' method is registered under Emacs'
;; unique bus name (`dbus-get-unique-name'), at an object path of its own per call: a well-known name such as
;; org.drgnx.Wm<PID> would need `dbus-register-service' and `dbus-unregister-service', which wait for the bus
;; (RequestName, ReleaseName), and one path per call lets two calls run at once without sharing a reply.
;; Everything a call made (script, object, file) is undone on success, error and deadline alike.
;;
;; Facts: KWin 6.7.5 ran headless (`kwin_wayland --virtual') in podman and the scripts' replies are recorded
;; in test/fixtures/wm/kwin/.  The adapter itself (listing, a command's move, Next, a restore's placement) runs
;; against that KWin with two outputs in the window managers' container tier (test/live/drgnx-wm-other-test.el):
;; status `verified'.  Not run on a full Plasma session.  KWin 5 (another scripting API) is not supported.

(require 'json)
(declare-function dbus-get-unique-name "dbusbind.c" (bus))
(declare-function dbus-register-method "dbus" (bus service path interface method handler &optional dont-register-service))
(declare-function dbus-unregister-object "dbus" (object))
(declare-function dbus-call-method-asynchronously "dbus" (bus service path interface method handler &rest args))

(defun drgnx-platform-kwin--js-string (s)
  "S as a JavaScript string literal: JSON, with U+2028 and U+2029 escaped (older JavaScript ends a line there)."
  (replace-regexp-in-string "[\u2028\u2029]" (lambda (c) (format "\\u%04x" (aref c 0))) (json-encode-string s) t t))

(defconst drgnx-platform-kwin--no-dbus
  '("this Emacs has no D-Bus support" . "use an Emacs built with D-Bus (the installer's builds have it)"))

(defconst drgnx-platform-kwin--no-bus
  '("Emacs has no D-Bus session bus here"
    . "start Emacs from the Plasma session (DBUS_SESSION_BUS_ADDRESS must name its session bus)"))

(defvar drgnx-platform-kwin--counter 0 "Counts the calls, for their script names and object paths.")

(defun drgnx-platform-kwin--dbus-p ()
  "Non-nil when this Emacs was built with D-Bus."
  (featurep 'dbusbind))

(defun drgnx-platform-kwin--can-move (_ctx)
  "t when D-Bus and the session bus are there, else (REASON . FIX)."
  (cond ((not (drgnx-platform-kwin--dbus-p)) drgnx-platform-kwin--no-dbus)
        ((not (and (require 'dbus nil t) (ignore-errors (dbus-get-unique-name :session))))
         drgnx-platform-kwin--no-bus)
        (t t)))

(defun drgnx-platform-kwin--script (kind args)
  "The KWin JavaScript for KIND: `screens', `windows' or `move'.  Pure.
ARGS (a plist): :service and :path, where the script reports (`callDBus' of Reply, with a JSON string);
for `move' also :pid, :screen (an output name, may be \"\"), :geometry (X Y W H of the target screen, the
fallback when no name matches) and either :active t with :caption (the active window, which must be the window
of :pid with that caption) or :caption alone (the window of :pid with that caption, else the only normal window of
:pid).
The reply is an array of screens or of windows (the shape of test/fixtures/wm/kwin/), or {\"ok\":true} or
{\"error\":MESSAGE}."
  (let ((str #'drgnx-platform-kwin--js-string))
    (concat
     "(function () {\n"
     "function reply(x) { callDBus(" (funcall str (plist-get args :service)) ", " (funcall str (plist-get args :path))
     ", \"org.drgnx.Wm\", \"Reply\", JSON.stringify(x)); }\n"
     "function box(g) { return { x: g.x, y: g.y, width: g.width, height: g.height }; }\n"
     "try {\n"
     (pcase kind
       ('screens
        (concat "reply(workspace.screens.map(function (s) {\n"
                "  return { name: s.name, manufacturer: s.manufacturer, model: s.model,\n"
                "           serialNumber: s.serialNumber, geometry: box(s.geometry) };\n"
                "}));\n"))
       ('windows
        (concat "reply(workspace.windowList().map(function (w) {\n"
                "  return { pid: w.pid, caption: w.caption, output: w.output ? w.output.name : null,\n"
                "           fullScreen: w.fullScreen, normalWindow: w.normalWindow,\n"
                "           resourceClass: w.resourceClass, internalId: String(w.internalId),\n"
                "           geometry: box(w.frameGeometry), active: workspace.activeWindow === w };\n"
                "}));\n"))
       ('move
        (concat
         "var w = null;\n"
         (if (plist-get args :active)
             (concat "w = workspace.activeWindow;\n"
                     (format "if (!w || w.pid !== %d) { reply({ error: \"the active window is not this Emacs\" }); return; }\n"
                             (plist-get args :pid))
                     "if (w.caption !== " (funcall str (or (plist-get args :caption) ""))
                     ") { reply({ error: \"the active window is another window of this Emacs\" }); return; }\n")
           (concat (format "var mine = workspace.windowList().filter(function (x) { return x.pid === %d && x.normalWindow; });\n"
                           (plist-get args :pid))
                   "var named = mine.filter(function (x) { return x.caption === "
                   (funcall str (or (plist-get args :caption) "")) "; });\n"
                   "w = named.length > 0 ? named[0] : (mine.length === 1 ? mine[0] : null);\n"
                   "if (!w) { reply({ error: \"KWin has no window of this Emacs with that caption\" }); return; }\n"))
         "var want = " (funcall str (or (plist-get args :screen) "")) ";\n"
         (format "var geo = [%s];\n" (mapconcat (lambda (n) (format "%d" n)) (plist-get args :geometry) ", "))
         "var screens = workspace.screens;\nvar s = null;\n"
         "for (var i = 0; i < screens.length && !s; i++) { if (want !== \"\" && screens[i].name === want) s = screens[i]; }\n"
         "for (var j = 0; j < screens.length && !s; j++) {\n"
         "  var g = screens[j].geometry;\n"
         "  if (geo.length === 4 && g.x === geo[0] && g.y === geo[1] && g.width === geo[2] && g.height === geo[3]) s = screens[j];\n"
         "}\n"
         "if (!s) { reply({ error: \"KWin has no such screen\" }); return; }\n"
         "workspace.sendClientToScreen(w, s);\n"
         "reply({ ok: true });\n"))
       (_ (error "No KWin script called %S" kind)))
     "} catch (e) { reply({ error: String(e) }); }\n"
     "})();\n")))

(defun drgnx-platform-kwin--parse (json)
  "The Lisp value of the script's reply JSON: plists, lists, nil for null and false."
  (condition-case nil
      (json-parse-string json :object-type 'plist :array-type 'list :null-object nil :false-object nil)
    (error (list :error "KWin's script answered something unreadable"))))

(defun drgnx-platform-kwin--run (kind args timeout callback)
  "Run the script KIND (with ARGS plus the reply address) in KWin; call CALLBACK once, later, with the parsed
reply or (:error MESSAGE).  TIMEOUT seconds bound every step: when KWin has not answered by then the call
ends with an error.  Script, reply object and temporary file are gone by the time CALLBACK runs."
  (let ((cb (drgnx-platform--once callback)) (can (drgnx-platform-kwin--can-move nil)))
    (if (not (eq can t))
        (drgnx-platform--refuse cb (list :error (drgnx-platform--reason can)))
      (let* ((n (cl-incf drgnx-platform-kwin--counter))
             (name (format "drgnx-%d-%d" (emacs-pid) n))
             (ms (max 1 (round (* 1000 timeout))))
             (object nil) (file nil) (timer nil) (sent nil) (done nil) (serials nil) (on-error nil)
             (finish
              (lambda (result)
                (unless done
                  (setq done t)
                  (when timer (cancel-timer timer))
                  (when on-error (remove-hook 'dbus-event-error-functions on-error))
                  (when object (ignore-errors (dbus-unregister-object object)))
                  (when sent
                    (ignore-errors
                      (dbus-call-method-asynchronously :session "org.kde.KWin" "/Scripting" "org.kde.kwin.Scripting"
                                                       "unloadScript" nil :timeout ms name)))
                  (when file (ignore-errors (delete-file file)))
                  (drgnx-platform--later (lambda () (funcall cb result)))))))
        ;; A D-Bus error reply (KWin is not running, no such method) does not reach the handler of an
        ;; asynchronous call: dbus.el runs `dbus-event-error-functions' with the event, whose serial is that of
        ;; the call.  This call's function is in the hook until `finish' removes it.
        (setq on-error (lambda (event err)
                         (when (and (not done) (eq (nth 1 event) :session) (memq (nth 3 event) serials))
                           (funcall finish (list :error (format "KWin: %s" (string-join (mapcar (lambda (x) (format "%s" x)) (cdr err)) ": ")))))))
        (add-hook 'dbus-event-error-functions on-error)
        (condition-case err
            (let* ((service (dbus-get-unique-name :session)) ; the first use opens the session connection (local, no round trip to a name owner)
                   (path (format "/org/drgnx/Wm%d" n))
                   (script (drgnx-platform-kwin--script
                            kind (append (list :service service :path path) args))))
              (setq object (dbus-register-method
                            :session service path "org.drgnx.Wm" "Reply"
                            (lambda (json) (funcall finish (drgnx-platform-kwin--parse json)) :ignore)
                            t))
              (setq timer (run-at-time timeout nil
                                       (lambda ()
                                         (funcall finish (list :error (format "KWin did not answer within %s s" timeout))))))
              (setq file (let ((coding-system-for-write 'utf-8-unix))
                           (make-temp-file "drgnx-kwin-" nil ".js" script)))
              (setq sent t)
              (push (nth 2 (dbus-call-method-asynchronously
                            :session "org.kde.KWin" "/Scripting" "org.kde.kwin.Scripting" "loadScript"
                            ;; `:timeout' right after the handler: anywhere else dbus.el sends it as an argument
                            (lambda (id)
                              (unless done
                                (if (not (and (integerp id) (>= id 0)))
                                    (funcall finish (list :error "KWin could not load the script"))
                                  ;; `start' runs every loaded script not running yet.  Not `run' on
                                  ;; /Scripting/Script<id>: KWin numbers scripts by how many are loaded, so after
                                  ;; an unload two loaded scripts share an id and one object, and `run' there runs
                                  ;; another call's script (two calls at once, seen on KWin 6.7.5)
                                  (push (nth 2 (dbus-call-method-asynchronously
                                                :session "org.kde.KWin" "/Scripting" "org.kde.kwin.Scripting" "start"
                                                nil :timeout ms))
                                        serials))))
                            :timeout ms file name))
                    serials))
          (error (funcall finish (list :error (error-message-string err)))))))
    nil))

(defun drgnx-platform-kwin--reply-error (reply)
  "REPLY if it is an error answer, else nil: an (:error MESSAGE) plist from the script or the runner."
  (and (drgnx-platform--error-p reply) reply))

(defun drgnx-platform-kwin--monitors (ctx callback)
  "CALLBACK with KWin's screens as monitor plists (:name :make :model :serial :geometry), or (:error MESSAGE)."
  (drgnx-platform-kwin--run
   'screens nil (plist-get ctx :timeout)
   (lambda (reply)
     (funcall callback
              (or (drgnx-platform-kwin--reply-error reply)
                  (mapcar (lambda (s)
                            (let ((g (plist-get s :geometry)))
                              (list :name (or (plist-get s :name) "")
                                    :make (or (plist-get s :manufacturer) "")
                                    :model (or (plist-get s :model) "")
                                    :serial (or (plist-get s :serialNumber) "")
                                    :geometry (list (plist-get g :x) (plist-get g :y)
                                                    (plist-get g :width) (plist-get g :height)))))
                          reply))))))

(defun drgnx-platform-kwin--send (ctx monitor extra callback)
  "Run the move script for MONITOR with EXTRA script arguments; CALLBACK gets `ok' or (:error MESSAGE)."
  (drgnx-platform-kwin--run
   'move (append (list :pid (emacs-pid) :screen (or (plist-get monitor :name) "")
                       :geometry (drgnx-platform--geometry monitor))
                 extra)
   (plist-get ctx :timeout)
   (lambda (reply)
     (funcall callback (cond ((drgnx-platform-kwin--reply-error reply))
                             ((eq (plist-get reply :ok) t) 'ok)
                             (t (list :error "KWin's script did not report a move")))))))

(defun drgnx-platform-kwin--move (ctx monitor callback)
  "Move CTX's frame to MONITOR: the path of a command the user typed.  As with every adapter the frame must have
focus; and KWin's active window must be Emacs' (pid) and this very frame (its caption: the title, else the name),
never another frame of this Emacs, such as the main one."
  (let ((frame (plist-get ctx :frame)))
    (if (not (drgnx-platform-wm--hn-own-focused-p ctx))
        (drgnx-platform-wm--hn-refuse callback drgnx-platform-wm--hn-not-focused)
      (drgnx-platform-kwin--send
       ctx monitor (list :active t :caption (or (frame-parameter frame 'title) (frame-parameter frame 'name) ""))
       callback))))

(defun drgnx-platform-kwin--place (ctx monitor callback)
  "Move CTX's frame (found by Emacs' pid and the frame's title) to MONITOR: the restore path, any window.
KWin places a new window where it likes when it first shows it, and that can come after a move made at once (a
restored window is placed as it is made): so after each move Emacs' own answer (`frame-monitor-attributes') is
checked at `drgnx-platform-wm--hn-poll-times', and the move made again while the frame is elsewhere, all within
CTX's one deadline."
  (let* ((frame (plist-get ctx :frame)) (start (float-time)) (end (+ start (plist-get ctx :timeout)))
         (want (drgnx-platform--geometry monitor))
         (there (lambda () (ignore-errors (equal (append (alist-get 'geometry (frame-monitor-attributes frame)) nil) want)))))
    (cl-labels ((try (times)
                  (drgnx-platform-kwin--send
                   (plist-put (copy-sequence ctx) :timeout (max 0.05 (- end (float-time)))) monitor
                   (list :caption (frame-parameter frame 'name))
                   (lambda (r) (if (drgnx-platform--error-p r) (funcall callback r) (check times)))))
                (check (times)
                  (cond ((funcall there) (funcall callback 'ok))
                        ((or (null times) (>= (+ start (car times)) end))
                         (funcall callback (list :error "KWin keeps the window on another screen; it was not placed")))
                        (t (run-at-time (max 0 (- (+ start (car times)) (float-time))) nil
                                        (lambda () (if (funcall there) (funcall callback 'ok) (try (cdr times)))))))))
      (try drgnx-platform-wm--hn-poll-times))))

(drgnx-platform-define-adapter
 'kwin :status 'verified :tool nil
 :monitors #'drgnx-platform-kwin--monitors
 ;; Emacs' own answer (its geometry matches a screen's; no script): Next and Previous need the current monitor
 :frame-monitor #'drgnx-platform--emacs-frame-monitor
 :move #'drgnx-platform-kwin--move :place #'drgnx-platform-kwin--place
 :can-move #'drgnx-platform-kwin--can-move)

(provide 'drgnx-platform)
;;; drgnx-platform.el ends here
