;;; platform-hypr-niri-test.el --- batch tests: the Hyprland and niri adapters on fake CLIs -*- lexical-binding: t -*-
;; The fake `hyprctl' and `niri' replay test/fixtures/wm/{hyprland,niri}/ (Hyprland's are invented values in the
;; source's JSON shape, niri's are recorded; see SOURCES).  Nothing talks to a real compositor.
(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'drgnx-paths)
(require 'drgnx-platform)
(load (expand-file-name "test/unit/platform-test" drgnx-dir) nil t) ; the isolation, fake-WM and frame helpers

;;;; Helpers

(defun drgnx-platform-wm-test--fixture (rel)
  (with-temp-buffer (insert-file-contents (expand-file-name (concat "test/fixtures/wm/" rel) drgnx-dir))
                    (buffer-string)))

(defun drgnx-platform-wm-test--write (dir name text)
  (with-temp-file (expand-file-name name dir) (insert text)))

(defmacro drgnx-platform-wm-test--session (wm files map &rest body)
  "Run BODY with the fake tools replaying FILES (alist NAME . TEXT, each a file in a temp dir) by MAP (the
fake's \"REGEXP FILE\" lines), a pgtk frame of WM (`hyprland' or `niri') that has focus, and `emacs-pid'
being the pid in the fixtures (4242 for Hyprland, 118 for niri).  `dir' is the reply directory."
  (declare (indent 3))
  `(drgnx-platform-test--with-fake-wm (:map ,map)
     (let ((dir (make-temp-file "drgnx-wm-replies" t)) (drgnx-platform-wm--hypr-config nil))
       (dolist (f ,files) (drgnx-platform-wm-test--write dir (car f) (cdr f)))
       (unwind-protect
           (let ((process-environment (cons (concat "DRGNX_FAKE_WM_DIR=" dir) process-environment)))
             (drgnx-platform-test--with-frame 'pgtk
                 (if (eq ,wm 'hyprland)
                     '("HYPRLAND_INSTANCE_SIGNATURE=sig1" "WAYLAND_DISPLAY=wayland-1")
                   '("NIRI_SOCKET=/run/niri.sock" "WAYLAND_DISPLAY=wayland-1"))
               (cl-letf (((symbol-function 'emacs-pid) (lambda () (if (eq ,wm 'hyprland) 4242 118)))
                         ((symbol-function 'frame-focus-state) (lambda (&optional _f) t)))
                 ,@body)))
         (delete-directory dir t)))))

(defun drgnx-platform-wm-test--do (fn &rest args)
  "Call FN with ARGS and a callback; wait for it (at most 8 s) and return what it got (`timeout-in-test' if none)."
  (let (res done)
    (apply fn (append args (list (lambda (r) (setq res r done t)))))
    (if (drgnx-platform-test--await (lambda () done) 8) res 'timeout-in-test)))

(defun drgnx-platform-wm-test--hypr-files ()
  (list (cons "monitors" (drgnx-platform-wm-test--fixture "hyprland/monitors.json"))
        (cons "clients" (drgnx-platform-wm-test--fixture "hyprland/clients.json"))
        (cons "activewindow" (drgnx-platform-wm-test--fixture "hyprland/activewindow.json"))
        (cons "activewindow-other" (drgnx-platform-wm-test--fixture "hyprland/activewindow-other.json"))
        (cons "ok" "ok") (cons "invalid" "Invalid dispatcher")
        (cons "nomonitor" "Invalid monitor / monitor doesn't exist")))

(defun drgnx-platform-wm-test--niri-files ()
  (list (cons "outputs" (drgnx-platform-wm-test--fixture "niri/outputs.json"))
        (cons "windows" (drgnx-platform-wm-test--fixture "niri/windows.json"))))

(defconst drgnx-platform-wm-test--hypr-lua-move
  "hyprctl dispatch hl.dsp.window.move({ window = \"address:0x5581a3c4d2f0\", monitor = \"HDMI-A-1\", follow = true })")

(defun drgnx-platform-wm-test--placing-title-hook (dir name from-fixture swap-from)
  "A `set-frame-parameter' replacement: when drgnx sets the `title' parameter, write FROM-FIXTURE into
DIR/NAME with SWAP-FROM replaced by that title (what the window manager would report once the title is set)."
  (let ((orig (symbol-function 'set-frame-parameter)))
    (lambda (f p v)
      (when (and (eq p 'title) (stringp v) (string-prefix-p "drgnx [placing" v))
        (drgnx-platform-wm-test--write
         dir name (string-replace swap-from v (drgnx-platform-wm-test--fixture from-fixture))))
      (funcall orig f p v))))

;;;; Pure helpers on the replies

(drgnx-platform-test--deftest drgnx-platform-wm/hyprland-monitors-helper ()
                              (let ((ms (drgnx-platform-wm--hypr-monitors (drgnx-platform-wm-test--fixture "hyprland/monitors.json"))))
                                (should (equal (mapcar (lambda (m) (plist-get m :name)) ms) '("DP-1" "HDMI-A-1")))
                                (should (equal (plist-get (car ms) :geometry) '(0 0 2560 1440)))
                                (should (equal (plist-get (cadr ms) :geometry) '(2560 0 1920 1080)))
                                (should (equal (list (plist-get (car ms) :make) (plist-get (car ms) :model) (plist-get (car ms) :serial))
                                               '("Dell Inc." "DELL U2720Q" "ABC1234"))))
                              ;; a disabled monitor is left out; a scale of 2 halves the size; a rotated one swaps width and height
                              (let* ((raw (drgnx-platform-wm-test--fixture "hyprland/monitors.json"))
                                     (i (string-search "\"disabled\": false" raw))
                                     (text (concat (substring raw 0 i) "\"disabled\": true"
                                                   (substring raw (+ i (length "\"disabled\": false"))))))
                                (should (equal (mapcar (lambda (m) (plist-get m :name)) (drgnx-platform-wm--hypr-monitors text)) '("HDMI-A-1"))))
                              (let* ((text (string-replace "\"scale\": 1.0" "\"scale\": 2.0" (drgnx-platform-wm-test--fixture "hyprland/monitors.json")))
                                     (text (string-replace "\"transform\": 0" "\"transform\": 1" text)))
                                (should (equal (plist-get (car (drgnx-platform-wm--hypr-monitors text)) :geometry) '(0 0 720 1280)))))

(drgnx-platform-test--deftest drgnx-platform-wm/hyprland-windows-helpers ()
                              (let ((w (drgnx-platform-wm--hypr-focused (drgnx-platform-wm-test--fixture "hyprland/activewindow.json"))))
                                (should (equal (list (plist-get w :id) (plist-get w :pid) (plist-get w :title) (plist-get w :fullscreen))
                                               '("0x5581a3c4d2f0" 4242 "drgnx - workbench" 0))))
                              (should-not (drgnx-platform-wm--hypr-focused "{}"))
                              (let ((c (drgnx-platform-wm-test--fixture "hyprland/clients.json")))
                                (should (equal (plist-get (drgnx-platform-wm--hypr-find c 4343 "foot") :id) "0x5581a3c5e810"))
                                (should-not (drgnx-platform-wm--hypr-find c 4343 "drgnx - workbench"))
                                (should-not (drgnx-platform-wm--hypr-find c 1 "foot"))))

(drgnx-platform-test--deftest drgnx-platform-wm/niri-helpers ()
                              (let ((ms (drgnx-platform-wm--niri-monitors (drgnx-platform-wm-test--fixture "niri/outputs.json"))))
                                (should (equal (mapcar (lambda (m) (plist-get m :name)) ms) '("winit")))
                                (should (equal (plist-get (car ms) :geometry) '(0 0 1596 871)))
                                (should (equal (plist-get (car ms) :make) "Smithay")))
                              ;; an output without a logical position (switched off) is left out
                              (should-not (drgnx-platform-wm--niri-monitors "{\"DP-1\":{\"name\":\"DP-1\",\"logical\":null}}"))
                              (let ((w (drgnx-platform-wm--niri-focused (drgnx-platform-wm-test--fixture "niri/windows.json"))))
                                (should (equal (list (plist-get w :id) (plist-get w :pid)) '(2 118)))
                                (should (equal (plist-get (drgnx-platform-wm--niri-find (drgnx-platform-wm-test--fixture "niri/windows.json")
                                                                                        118 "*scratch* - GNU Emacs at 921b33ddc885")
                                                          :id)
                                               2)))
                              (should-not (drgnx-platform-wm--niri-find (drgnx-platform-wm-test--fixture "niri/windows.json") 118 "other"))
                              (should-not (drgnx-platform-wm--niri-focused "[]")))

;;;; Monitors

(drgnx-platform-test--deftest drgnx-platform-wm/hyprland-monitors ()
                              (drgnx-platform-wm-test--session 'hyprland (drgnx-platform-wm-test--hypr-files) "-j monitors monitors"
                                (should (eq 'hyprland (drgnx-platform-wm frame)))
                                (let ((ms (drgnx-platform-wm-test--do #'drgnx-platform-monitors frame)))
                                  (should (equal (mapcar (lambda (m) (plist-get m :number)) ms) '(1 2)))
                                  (should (equal (mapcar (lambda (m) (plist-get m :name)) ms) '("DP-1" "HDMI-A-1")))
                                  (should (string-match-p "right of 1" (plist-get (cadr ms) :label))))
                                (should (equal (drgnx-platform-test--log-lines) '("hyprctl -j monitors")))
                                (should (member "HYPRLAND_INSTANCE_SIGNATURE=sig1"
                                                (drgnx-platform-process-env frame)))))

(drgnx-platform-test--deftest drgnx-platform-wm/niri-monitors ()
                              (drgnx-platform-wm-test--session 'niri (drgnx-platform-wm-test--niri-files) "msg --json outputs outputs"
                                (should (eq 'niri (drgnx-platform-wm frame)))
                                (let ((ms (drgnx-platform-wm-test--do #'drgnx-platform-monitors frame)))
                                  (should (equal (mapcar (lambda (m) (list (plist-get m :number) (plist-get m :name) (plist-get m :geometry))) ms)
                                                 '((1 "winit" (0 0 1596 871))))))
                                (should (equal (drgnx-platform-test--log-lines) '("niri msg --json outputs")))))

;;;; Moving the focused Emacs window

(drgnx-platform-test--deftest drgnx-platform-wm/hyprland-moves-the-focused-emacs-window ()
                              (drgnx-platform-wm-test--session 'hyprland (drgnx-platform-wm-test--hypr-files)
                                                               "-j activewindow activewindow\ndispatch hl\\.dsp ok"
                                (should (eq t (drgnx-platform-can-move frame)))
                                (should (eq 'ok (drgnx-platform-wm-test--do #'drgnx-platform-move-frame frame '(:name "HDMI-A-1"))))
                                ;; the focused window, then one dispatch naming it by address and the monitor by name, following it
                                (should (equal (drgnx-platform-test--log-lines)
                                               (list "hyprctl -j activewindow" drgnx-platform-wm-test--hypr-lua-move)))
                                (should (eq 'lua (cdr (assoc "sig1" drgnx-platform-wm--hypr-config))))))

(drgnx-platform-test--deftest drgnx-platform-wm/hyprland-moves-with-the-hyprlang-form ()
                              ;; a hyprlang config answers the Lua form "Invalid dispatcher": fall back to the legacy dispatcher, and remember
                              (drgnx-platform-wm-test--session 'hyprland (drgnx-platform-wm-test--hypr-files)
                                                               "-j activewindow activewindow\ndispatch hl\\.dsp invalid\ndispatch movewindow ok"
                                (should (eq 'ok (drgnx-platform-wm-test--do #'drgnx-platform-move-frame frame '(:name "HDMI-A-1"))))
                                (should (equal (drgnx-platform-test--log-lines)
                                               (list "hyprctl -j activewindow" drgnx-platform-wm-test--hypr-lua-move
                                                     "hyprctl dispatch movewindow mon:HDMI-A-1")))
                                (should (eq 'hyprlang (cdr (assoc "sig1" drgnx-platform-wm--hypr-config))))
                                ;; the second move does not try the Lua form again
                                (delete-file drgnx-platform-test--log)
                                (should (eq 'ok (drgnx-platform-wm-test--do #'drgnx-platform-move-frame frame '(:name "DP-1"))))
                                (should (equal (drgnx-platform-test--log-lines)
                                               '("hyprctl -j activewindow" "hyprctl dispatch movewindow mon:DP-1")))))

(drgnx-platform-test--deftest drgnx-platform-wm/hyprland-reports-hyprlands-own-error ()
                              (drgnx-platform-wm-test--session 'hyprland (drgnx-platform-wm-test--hypr-files)
                                                               "-j activewindow activewindow\ndispatch hl\\.dsp nomonitor"
                                (should (equal (drgnx-platform-wm-test--do #'drgnx-platform-move-frame frame '(:name "NOPE"))
                                               '(:error "Invalid monitor / monitor doesn't exist")))
                                ;; and the failure of the tool itself (the fake exits 1 with the text on stderr)
                                (let ((process-environment (append '("DRGNX_FAKE_WM_MAP=" "DRGNX_FAKE_WM_EXIT=1" "DRGNX_FAKE_WM_STDERR=Couldn't connect to the socket")
                                                                   process-environment)))
                                  (should (equal (drgnx-platform-wm-test--do #'drgnx-platform-move-frame frame '(:name "DP-1"))
                                                 '(:error "Couldn't connect to the socket"))))))

(drgnx-platform-test--deftest drgnx-platform-wm/niri-moves-the-focused-emacs-window ()
                              (drgnx-platform-wm-test--session 'niri (drgnx-platform-wm-test--niri-files)
                                                               "--json windows windows\n--json outputs outputs"
                                (should (eq t (drgnx-platform-can-move frame)))
                                (should (eq 'ok (drgnx-platform-wm-test--do #'drgnx-platform-move-frame frame '(:name "winit"))))
                                ;; the window by id (so it stays the active one), after checking the output exists
                                (should (equal (drgnx-platform-test--log-lines)
                                               '("niri msg --json windows" "niri msg --json outputs"
                                                 "niri msg action move-window-to-monitor --id 2 winit")))))

(drgnx-platform-test--deftest drgnx-platform-wm/niri-an-unknown-output-is-an-error-and-nothing-moves ()
                              ;; niri itself exits 0 and does nothing for an unknown output: drgnx checks the output first
                              (drgnx-platform-wm-test--session 'niri (drgnx-platform-wm-test--niri-files)
                                                               "--json windows windows\n--json outputs outputs"
                                (let ((r (drgnx-platform-wm-test--do #'drgnx-platform-move-frame frame '(:name "DP-9"))))
                                  (should (eq :error (car r)))
                                  (should (string-match-p "no output named \"DP-9\"" (cadr r))))
                                (should-not (seq-some (lambda (l) (string-match-p " action " l)) (drgnx-platform-test--log-lines)))))

;;;; Another app has focus

(drgnx-platform-test--deftest drgnx-platform-wm/hyprland-refuses-when-another-app-has-focus ()
                              (drgnx-platform-wm-test--session 'hyprland (drgnx-platform-wm-test--hypr-files)
                                                               "-j activewindow activewindow-other\ndispatch hl\\.dsp ok"
                                (let ((r (drgnx-platform-wm-test--do #'drgnx-platform-move-frame frame '(:name "HDMI-A-1"))))
                                  (should (equal r (list :error drgnx-platform-wm--not-focused))))
                                (should (string-match-p "while it has focus" drgnx-platform-wm--not-focused))
                                (should (equal (drgnx-platform-test--log-lines) '("hyprctl -j activewindow")))
                                ;; Emacs' frame itself without focus: not even asked
                                (delete-file drgnx-platform-test--log)
                                (cl-letf (((symbol-function 'frame-focus-state) (lambda (&optional _f) nil)))
                                  (should (equal (drgnx-platform-wm-test--do #'drgnx-platform-move-frame frame '(:name "HDMI-A-1"))
                                                 (list :error drgnx-platform-wm--not-focused))))
                                (should-not (drgnx-platform-test--log-lines))))

(drgnx-platform-test--deftest drgnx-platform-wm/niri-refuses-when-another-app-has-focus ()
                              (let* ((one (drgnx-platform-wm-test--fixture "niri/windows.json"))
                                     (other (concat (string-replace "\"is_focused\":true" "\"is_focused\":false" (string-trim-right one "]\n?"))
                                                    ",{\"id\":7,\"title\":\"foot\",\"app_id\":\"foot\",\"pid\":999,\"workspace_id\":1,\"is_focused\":true}]")))
                                (drgnx-platform-wm-test--session 'niri (list (cons "windows" other)
                                                                             (cons "outputs" (drgnx-platform-wm-test--fixture "niri/outputs.json")))
                                                                 "--json windows windows\n--json outputs outputs"
                                  (should (equal (drgnx-platform-wm-test--do #'drgnx-platform-move-frame frame '(:name "winit"))
                                                 (list :error drgnx-platform-wm--not-focused)))
                                  (should-not (seq-some (lambda (l) (string-match-p " action " l)) (drgnx-platform-test--log-lines)))
                                  (delete-file drgnx-platform-test--log)
                                  (cl-letf (((symbol-function 'frame-focus-state) (lambda (&optional _f) nil)))
                                    (should (equal (drgnx-platform-wm-test--do #'drgnx-platform-move-frame frame '(:name "winit"))
                                                   (list :error drgnx-platform-wm--not-focused))))
                                  (should-not (drgnx-platform-test--log-lines)))))

;;;; Placing a restored window by pid and title

(drgnx-platform-test--deftest drgnx-platform-wm/hyprland-places-a-restored-window-by-pid-and-title ()
                              (drgnx-platform-wm-test--session 'hyprland (drgnx-platform-wm-test--hypr-files)
                                                               "-j clients clients\ndispatch hl\\.dsp ok"
                                (set-frame-parameter frame 'title "before")
                                (cl-letf (((symbol-function 'set-frame-parameter)
                                           (drgnx-platform-wm-test--placing-title-hook dir "clients" "hyprland/clients.json" "drgnx - workbench")))
                                  (let ((start (float-time)))
                                    (should (eq 'ok (drgnx-platform-wm-test--do #'drgnx-platform-place-frame frame '(:name "HDMI-A-1"))))
                                    (should (< (- (float-time) start) 2))))
                                ;; the title is back, and the move named the window by address, silently
                                (should (equal (frame-parameter frame 'title) "before"))
                                (should (equal (drgnx-platform-test--log-lines)
                                               (list "hyprctl -j clients"
                                                     (string-replace "follow = true" "follow = false" drgnx-platform-wm-test--hypr-lua-move))))))

(drgnx-platform-test--deftest drgnx-platform-wm/hyprland-places-with-the-hyprlang-form-and-gives-focus-back ()
                              (drgnx-platform-wm-test--session 'hyprland (drgnx-platform-wm-test--hypr-files)
                                                               "-j clients clients\n-j activewindow activewindow-other\ndispatch hl\\.dsp invalid\ndispatch (focuswindow|movewindow) ok"
                                (setq drgnx-platform-wm--hypr-config '(("sig1" . hyprlang)))
                                (cl-letf (((symbol-function 'set-frame-parameter)
                                           (drgnx-platform-wm-test--placing-title-hook dir "clients" "hyprland/clients.json" "drgnx - workbench")))
                                  (should (eq 'ok (drgnx-platform-wm-test--do #'drgnx-platform-place-frame frame '(:name "HDMI-A-1")))))
                                ;; focus the window, move it without following, give focus back to the window that had it
                                (should (equal (drgnx-platform-test--log-lines)
                                               '("hyprctl -j clients" "hyprctl -j activewindow"
                                                 "hyprctl dispatch focuswindow address:0x5581a3c4d2f0"
                                                 "hyprctl dispatch movewindow mon:HDMI-A-1 silent"
                                                 "hyprctl dispatch focuswindow address:0x5581a3c5e810")))))

(drgnx-platform-test--deftest drgnx-platform-wm/hyprland-a-fullscreen-window-is-moved-with-its-fullscreen ()
                              ;; Hyprland's non-silent move re-applies the fullscreen mode itself, so a fullscreen window is moved that way
                              (drgnx-platform-wm-test--session 'hyprland (drgnx-platform-wm-test--hypr-files)
                                                               "-j clients clients\ndispatch hl\\.dsp ok"
                                (cl-letf (((symbol-function 'set-frame-parameter)
                                           (let ((hook (drgnx-platform-wm-test--placing-title-hook dir "clients" "hyprland/clients.json" "drgnx - workbench")))
                                             (lambda (f p v)
                                               (funcall hook f p v)
                                               (when (and (eq p 'title) (stringp v) (string-prefix-p "drgnx [placing" v))
                                                 (let ((file (expand-file-name "clients" dir)))
                                                   (with-temp-file file
                                                     (insert (string-replace "\"fullscreen\": 0" "\"fullscreen\": 2"
                                                                             (with-temp-buffer (insert-file-contents file) (buffer-string)))))))))))
                                  (should (eq 'ok (drgnx-platform-wm-test--do #'drgnx-platform-place-frame frame '(:name "HDMI-A-1")))))
                                (should (member drgnx-platform-wm-test--hypr-lua-move (drgnx-platform-test--log-lines)))))

(drgnx-platform-test--deftest drgnx-platform-wm/niri-places-a-restored-window-by-pid-and-title ()
                              (drgnx-platform-wm-test--session 'niri (drgnx-platform-wm-test--niri-files)
                                                               "--json windows windows\n--json outputs outputs"
                                (set-frame-parameter frame 'title "before")
                                (cl-letf (((symbol-function 'set-frame-parameter)
                                           (drgnx-platform-wm-test--placing-title-hook dir "windows" "niri/windows.json"
                                                                                       "*scratch* - GNU Emacs at 921b33ddc885")))
                                  (should (eq 'ok (drgnx-platform-wm-test--do #'drgnx-platform-place-frame frame '(:name "winit")))))
                                (should (equal (frame-parameter frame 'title) "before"))
                                ;; by window id, no focus command, no focus taken
                                (should (equal (drgnx-platform-test--log-lines)
                                               '("niri msg --json windows" "niri msg --json outputs"
                                                 "niri msg action move-window-to-monitor --id 2 winit")))))

(drgnx-platform-test--deftest drgnx-platform-wm/place-polls-and-gives-the-title-back-at-the-deadline ()
                              ;; no window ever has the title: the answer is an error within the deadline, and the title is back
                              (dolist (wm '(hyprland niri))
                                (let ((drgnx-platform-restore-timeout 0.6))
                                  (drgnx-platform-wm-test--session wm (append (drgnx-platform-wm-test--hypr-files) (drgnx-platform-wm-test--niri-files))
                                                                   (if (eq wm 'hyprland) "-j clients clients" "--json windows windows")
                                    (set-frame-parameter frame 'title "before")
                                    (let* ((start (float-time))
                                           (r (drgnx-platform-wm-test--do #'drgnx-platform-place-frame frame '(:name "HDMI-A-1"))))
                                      (should (eq :error (car r)))
                                      (should (string-match-p "0.6 s" (cadr r)))
                                      (should (< (- (float-time) start) 1.4)))
                                    (should (equal (frame-parameter frame 'title) "before"))
                                    ;; polled more than once, never moved anything
                                    (let ((lines (drgnx-platform-test--log-lines)))
                                      (should (> (length lines) 1))
                                      (should-not (seq-some (lambda (l) (string-match-p "dispatch\\| action " l)) lines)))))))

(drgnx-platform-test--deftest drgnx-platform-wm/place-finds-a-window-that-appears-late ()
                              (drgnx-platform-wm-test--session 'hyprland (drgnx-platform-wm-test--hypr-files)
                                                               "-j clients clients\ndispatch hl\\.dsp ok"
                                (let ((hook (drgnx-platform-wm-test--placing-title-hook dir "clients" "hyprland/clients.json" "drgnx - workbench"))
                                      (orig (symbol-function 'set-frame-parameter)))
                                  ;; the title shows in the replies only 0.4 s after it is set: the polls at 0.1 and 0.3 s find nothing
                                  (cl-letf (((symbol-function 'set-frame-parameter)
                                             (lambda (f p v)
                                               (if (and (eq p 'title) (stringp v) (string-prefix-p "drgnx [placing" v))
                                                   (progn (funcall orig f p v)
                                                          (run-at-time 0.4 nil (lambda () (funcall hook f p v))))
                                                 (funcall orig f p v)))))
                                    (should (eq 'ok (drgnx-platform-wm-test--do #'drgnx-platform-place-frame frame '(:name "HDMI-A-1"))))
                                    (should (>= (length (seq-filter (lambda (l) (string-match-p "-j clients" l)) (drgnx-platform-test--log-lines))) 3))))))

;;;; One deadline for a move that makes several calls

(drgnx-platform-test--deftest drgnx-platform-wm/a-move-with-several-calls-is-cut-at-one-deadline ()
                              ;; each call takes 0.4 s, the move may take 0.6 s: the second call gets what is left and is cut; the adapter
                              ;; answers with its own message, not the watchdog's
                              (let ((drgnx-platform-command-timeout 0.6))
                                (drgnx-platform-wm-test--session 'hyprland (drgnx-platform-wm-test--hypr-files)
                                                                 "-j activewindow activewindow\ndispatch hl\\.dsp ok"
                                  (let ((process-environment (cons "DRGNX_FAKE_WM_DELAY=0.4" process-environment))
                                        (start (float-time)))
                                    (should (equal (drgnx-platform-wm-test--do #'drgnx-platform-move-frame frame '(:name "HDMI-A-1"))
                                                   '(:error "Hyprland did not answer within 0.6 s; the window was not moved")))
                                    (should (< (- (float-time) start) 1.2))))))

;;;; A missing tool

(drgnx-platform-test--deftest drgnx-platform-wm/hyprland-missing-tool-message ()
                              (let* ((empty (make-temp-file "drgnx-no-tools" t))
                                     (exec-path (list empty)) (process-environment (cons (concat "PATH=" empty) process-environment)))
                                (unwind-protect
                                    (drgnx-platform-test--with-frame 'pgtk '("HYPRLAND_INSTANCE_SIGNATURE=sig1" "WAYLAND_DISPLAY=wayland-1")
                                      (cl-letf (((symbol-function 'frame-focus-state) (lambda (&optional _f) t)))
                                        (let ((msg "Hyprland: hyprctl is not installed, so drgnx cannot move windows"))
                                          (should (equal (drgnx-platform-wm-test--do #'drgnx-platform-monitors frame) (list :error msg)))
                                          (should (equal (drgnx-platform-wm-test--do #'drgnx-platform-move-frame frame '(:name "DP-1")) (list :error msg)))
                                          (should (equal (drgnx-platform-wm-test--do #'drgnx-platform-place-frame frame '(:name "DP-1")) (list :error msg))))))
                                  (delete-directory empty t))))

(drgnx-platform-test--deftest drgnx-platform-wm/niri-missing-tool-message ()
                              (let* ((empty (make-temp-file "drgnx-no-tools" t))
                                     (exec-path (list empty)) (process-environment (cons (concat "PATH=" empty) process-environment)))
                                (unwind-protect
                                    (drgnx-platform-test--with-frame 'pgtk '("NIRI_SOCKET=/run/niri.sock" "WAYLAND_DISPLAY=wayland-1")
                                      (cl-letf (((symbol-function 'frame-focus-state) (lambda (&optional _f) t)))
                                        (let ((msg "niri: niri is not installed, so drgnx cannot move windows"))
                                          (should (equal (drgnx-platform-wm-test--do #'drgnx-platform-monitors frame) (list :error msg)))
                                          (should (equal (drgnx-platform-wm-test--do #'drgnx-platform-move-frame frame '(:name "winit")) (list :error msg)))
                                          (should (equal (drgnx-platform-wm-test--do #'drgnx-platform-place-frame frame '(:name "winit")) (list :error msg))))))
                                  (delete-directory empty t))))

(drgnx-platform-test--deftest drgnx-platform-wm/hyprland-and-niri-stay-reported ()
                              (should (eq 'reported (plist-get (drgnx-platform-adapter 'hyprland) :status)))
                              (should (eq 'reported (plist-get (drgnx-platform-adapter 'niri) :status)))
                              (should (plist-get (drgnx-platform-adapter 'hyprland) :detect)))

(provide 'platform-hypr-niri-test)
;;; platform-hypr-niri-test.el ends here
