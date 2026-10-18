;;; platform-wm-test.el --- batch tests: the sway and i3 adapters on recorded replies -*- lexical-binding: t -*-
;; The fake tool (test/fixtures/wm/fake-wm.sh) replays test/fixtures/wm/{sway,i3}/; nothing here talks to a real
;; window manager.  The helpers (isolation, fake tool, frame) come from platform-test.el.
(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'drgnx-paths)
(require 'drgnx-platform)
(unless (fboundp 'drgnx-platform-test--deftest)
  (load (expand-file-name "platform-test.el" (file-name-directory (or load-file-name buffer-file-name))) nil t))

;;;; Helpers

(defun drgnx-platform-wm-test--text (rel)
  "The recorded reply test/fixtures/wm/REL as text."
  (with-temp-buffer
    (insert-file-contents (expand-file-name (concat "test/fixtures/wm/" rel) drgnx-dir))
    (buffer-string)))

(defun drgnx-platform-wm-test--tree (rel fn)
  "The recorded tree REL as JSON text, after FN changed each node (a hash table)."
  (let ((tree (json-parse-string (drgnx-platform-wm-test--text rel))))
    (cl-labels ((walk (n) (when (hash-table-p n)
                            (funcall fn n)
                            (dolist (k '("nodes" "floating_nodes")) (mapc #'walk (gethash k n))))))
      (walk tree))
    (json-serialize tree)))

(defun drgnx-platform-wm-test--ours (&optional title fullscreen)
  "get_tree.json of sway with the Emacs con (id 7) being this process, optionally titled and fullscreen."
  (drgnx-platform-wm-test--tree
   "sway/get_tree.json"
   (lambda (n) (when (equal (gethash "id" n) 7)
                 (puthash "pid" (emacs-pid) n)
                 (when title (puthash "name" title n))
                 (when fullscreen (puthash "fullscreen_mode" 1 n))))))

(defconst drgnx-platform-wm-test--map
  "get_tree get_tree\nget_outputs get_outputs\n(move container|focus|fullscreen) ok\n"
  "The fake tool's replies: the queries from the reply directory, any command succeeds.")

(defvar drgnx-platform-wm-test--dir nil "The directory of the replies of the running test.")

(defun drgnx-platform-wm-test--write (name text)
  (with-temp-file (expand-file-name name drgnx-platform-wm-test--dir) (insert text)))

(defmacro drgnx-platform-wm-test--with-replies (files &rest body)
  "Run BODY inside `drgnx-platform-test--with-fake-wm' with a reply directory holding FILES, an alist
\(NAME . TEXT) evaluated now, plus ok.json.  Write more with `drgnx-platform-wm-test--write'."
  (declare (indent 1))
  `(drgnx-platform-test--with-fake-wm (:map drgnx-platform-wm-test--map)
     (let* ((drgnx-platform-wm-test--dir (make-temp-file "drgnx-wm-replies" t))
            (process-environment (cons (concat "DRGNX_FAKE_WM_DIR=" drgnx-platform-wm-test--dir)
                                       process-environment)))
       (unwind-protect
           (progn (drgnx-platform-wm-test--write "ok.json" "[{\"success\":true}]")
                  (dolist (f (list ,@(mapcar (lambda (f) `(cons ,(car f) ,(cdr f))) files)))
                    (drgnx-platform-wm-test--write (car f) (cdr f)))
                  ,@body)
         (delete-directory drgnx-platform-wm-test--dir t)))))

(defmacro drgnx-platform-wm-test--focused (state &rest body)
  "Run BODY with `frame-focus-state' answering STATE for every frame."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'frame-focus-state) (lambda (&optional _f) ,state))) ,@body))

(defun drgnx-platform-wm-test--monitor (name x)
  (list :name name :make "Unknown" :model "Unknown" :serial "Unknown" :geometry (list x 0 1280 800)))

(defun drgnx-platform-wm-test--result (starter)
  "Call STARTER with a callback; wait for it and return what it was called with (or `none')."
  (let ((res 'none))
    (funcall starter (lambda (r) (setq res r)))
    (drgnx-platform-test--await (lambda () (not (eq res 'none))) 5)
    res))

(defun drgnx-platform-wm-test--commands ()
  "The logged calls without the tool name."
  (mapcar (lambda (l) (replace-regexp-in-string "\\`[^ ]+ " "" l)) (drgnx-platform-test--log-lines)))

(defconst drgnx-platform-wm-test--refusal
  "drgnx moves only its own window while it has focus: click this window, then run the command again")

;;;; The pure helpers on the recorded replies

(drgnx-platform-test--deftest drgnx-platform-wm/sway-monitors-from-get-outputs ()
                              (let ((ms (drgnx-platform-wm--sway-monitors (drgnx-platform-wm-test--text "sway/get_outputs.json"))))
                                (should (equal (mapcar (lambda (m) (plist-get m :name)) ms) '("HEADLESS-1" "HEADLESS-2")))
                                (should (equal (plist-get (cadr ms) :geometry) '(1280 0 1280 800)))
                                (should (equal (mapcar (lambda (m) (list (plist-get m :make) (plist-get m :model) (plist-get m :serial))) ms)
                                               '(("Unknown" "Unknown" "Unknown") ("Unknown" "Unknown" "Unknown")))))
                              ;; an inactive output stays in sway's array but is not a monitor
                              (let ((ms (drgnx-platform-wm--sway-monitors (drgnx-platform-wm-test--text "sway/get_outputs-one-disabled.json"))))
                                (should (equal (mapcar (lambda (m) (plist-get m :name)) ms) '("HEADLESS-1")))
                                (should (equal (plist-get (car ms) :geometry) '(0 0 1280 800))))
                              ;; i3: no make/model/serial, and the whole-screen xroot-0 is inactive
                              (let ((ms (drgnx-platform-wm--sway-monitors (drgnx-platform-wm-test--text "i3/get_outputs.json"))))
                                (should (equal (mapcar (lambda (m) (plist-get m :name)) ms) '("left" "right")))
                                (should (equal (plist-get (car ms) :make) "")))
                              (should (null (drgnx-platform-wm--sway-monitors "not json"))))

(drgnx-platform-test--deftest drgnx-platform-wm/the-tree-helpers-read-the-recorded-trees ()
                              (let* ((tree (json-parse-string (drgnx-platform-wm-test--text "sway/get_tree.json")
                                                              :object-type 'plist :array-type 'list :null-object nil :false-object nil))
                                     (other (json-parse-string (drgnx-platform-wm-test--text "sway/get_tree-unfocused.json")
                                                               :object-type 'plist :array-type 'list :null-object nil :false-object nil))
                                     (focused (drgnx-platform-wm--sway-focused tree)))
                                (should (equal (list (plist-get focused :id) (plist-get focused :pid) (plist-get focused :output)
                                                     (plist-get focused :fullscreen) (plist-get focused :name))
                                               '(7 9 "HEADLESS-1" nil "drgnx - workbench")))
                                ;; two Emacs processes are told apart by pid
                                (should (= 10 (plist-get (drgnx-platform-wm--sway-focused other) :id)))
                                (should (= 7 (plist-get (drgnx-platform-wm--sway-find other 9 "drgnx - workbench") :id)))
                                (should (= 10 (plist-get (drgnx-platform-wm--sway-find other 3472 "other emacs") :id)))
                                (should-not (drgnx-platform-wm--sway-find other 3472 "drgnx - workbench"))
                                (should-not (drgnx-platform-wm--sway-find other 9 "other emacs")))
                              (let ((i3 (json-parse-string (drgnx-platform-wm-test--text "i3/get_tree-unfocused.json")
                                                           :object-type 'plist :array-type 'list :null-object nil :false-object nil)))
                                (should (equal "other emacs" (plist-get (drgnx-platform-wm--i3-find i3 8388937) :name)))
                                (should (equal "drgnx - workbench" (plist-get (drgnx-platform-wm--i3-find i3 6291785) :name)))
                                (should-not (drgnx-platform-wm--i3-find i3 1))))

;;;; sway

(drgnx-platform-test--deftest drgnx-platform-wm/sway-lists-monitors-through-the-core ()
                              (drgnx-platform-wm-test--with-replies (("get_outputs.json" . (drgnx-platform-wm-test--text "sway/get_outputs.json")))
                                (drgnx-platform-test--with-frame 'pgtk '("SWAYSOCK=/frame/sway.sock" "WAYLAND_DISPLAY=wayland-1")
                                  (let ((res (drgnx-platform-wm-test--result (lambda (cb) (drgnx-platform-monitors frame cb)))))
                                    (should (equal (mapcar (lambda (m) (plist-get m :name)) res) '("HEADLESS-1" "HEADLESS-2")))
                                    (should (equal (mapcar (lambda (m) (plist-get m :number)) res) '(1 2)))
                                    (should (equal (drgnx-platform-wm-test--commands) '("-t get_outputs")))))))

(drgnx-platform-test--deftest drgnx-platform-wm/sway-moves-the-focused-emacs-window-and-keeps-focus ()
                              (drgnx-platform-wm-test--with-replies (("get_tree.json" . (drgnx-platform-wm-test--ours)))
                                (drgnx-platform-test--with-frame 'pgtk '("SWAYSOCK=/frame/sway.sock" "WAYLAND_DISPLAY=wayland-1")
                                  (drgnx-platform-wm-test--focused t
                                    (let ((res (drgnx-platform-wm-test--result
                                                (lambda (cb) (drgnx-platform-move-frame frame (drgnx-platform-wm-test--monitor "HEADLESS-2" 1280) cb)))))
                                      (should (eq res 'ok))
                                      ;; the move and the focus command with the con id of the recording, nothing else
                                      (should (equal (drgnx-platform-wm-test--commands)
                                                     '("-t get_tree"
                                                       "[con_id=7] move container to output HEADLESS-2"
                                                       "[con_id=7] focus"))))))))

(drgnx-platform-test--deftest drgnx-platform-wm/sway-keeps-a-fullscreen-window-fullscreen ()
                              (drgnx-platform-wm-test--with-replies (("get_tree.json" . (drgnx-platform-wm-test--ours nil t)))
                                (drgnx-platform-test--with-frame 'pgtk '("SWAYSOCK=/s" "WAYLAND_DISPLAY=wayland-1")
                                  (drgnx-platform-wm-test--focused t
                                    (should (eq 'ok (drgnx-platform-wm-test--result
                                                     (lambda (cb) (drgnx-platform-move-frame frame (drgnx-platform-wm-test--monitor "HEADLESS-2" 1280) cb)))))
                                    (let ((cmds (drgnx-platform-wm-test--commands)))
                                      (should (equal (nth 1 cmds) "[con_id=7] move container to output HEADLESS-2"))
                                      (should (equal (nth 2 cmds) "[con_id=7] focus; [con_id=7] fullscreen enable"))
                                      (should (= 3 (length cmds))))))))

(drgnx-platform-test--deftest drgnx-platform-wm/sway-refuses-when-another-app-has-focus ()
                              ;; Review focus 4: the focused con is another Emacs process (pid 3472)
                              (drgnx-platform-wm-test--with-replies (("get_tree.json" . (drgnx-platform-wm-test--text "sway/get_tree-unfocused.json")))
                                (drgnx-platform-test--with-frame 'pgtk '("SWAYSOCK=/s" "WAYLAND_DISPLAY=wayland-1")
                                  (drgnx-platform-wm-test--focused t
                                    (should (equal (list :error drgnx-platform-wm-test--refusal)
                                                   (drgnx-platform-wm-test--result
                                                    (lambda (cb) (drgnx-platform-move-frame frame (drgnx-platform-wm-test--monitor "HEADLESS-2" 1280) cb)))))
                                    (should (equal (drgnx-platform-wm-test--commands) '("-t get_tree")))))))

(drgnx-platform-test--deftest drgnx-platform-wm/sway-refuses-when-the-frame-has-no-focus ()
                              ;; the focused con is ours, but Emacs says this frame is not the focused one
                              (drgnx-platform-wm-test--with-replies (("get_tree.json" . (drgnx-platform-wm-test--ours)))
                                (drgnx-platform-test--with-frame 'pgtk '("SWAYSOCK=/s" "WAYLAND_DISPLAY=wayland-1")
                                  (dolist (state '(nil unknown))
                                    (drgnx-platform-wm-test--focused state
                                      (should (equal (list :error drgnx-platform-wm-test--refusal)
                                                     (drgnx-platform-wm-test--result
                                                      (lambda (cb) (drgnx-platform-move-frame frame (drgnx-platform-wm-test--monitor "HEADLESS-2" 1280) cb))))))
                                    (should-not (cl-some (lambda (c) (string-match-p "move container" c)) (drgnx-platform-wm-test--commands)))))))

(drgnx-platform-test--deftest drgnx-platform-wm/sway-places-a-restored-window-by-pid-and-title-then-gives-the-title-back ()
                              (drgnx-platform-wm-test--with-replies (("get_tree.json" . (drgnx-platform-wm-test--text "sway/get_tree.json")))
                                (drgnx-platform-test--with-frame 'pgtk '("SWAYSOCK=/s" "WAYLAND_DISPLAY=wayland-1")
                                  (set-frame-parameter frame 'title "before")
                                  (let ((seen nil))
                                    ;; the window shows up with its placing title only after about 0.3 s
                                    (run-at-time 0.3 nil (lambda ()
                                                           (setq seen (frame-parameter frame 'title))
                                                           (drgnx-platform-wm-test--write "get_tree.json" (drgnx-platform-wm-test--ours seen))))
                                    (should (eq 'ok (drgnx-platform-wm-test--result
                                                     (lambda (cb) (drgnx-platform-place-frame frame (drgnx-platform-wm-test--monitor "HEADLESS-2" 1280) cb)))))
                                    (should (string-match-p (format "\\`drgnx \\[placing %d-[0-9]+\\]\\'" (emacs-pid)) seen))
                                    (should (equal "before" (frame-parameter frame 'title)))
                                    (let ((cmds (drgnx-platform-wm-test--commands)))
                                      ;; polled until the con appeared, then moved without taking focus
                                      (should (equal (car (last cmds)) "[con_id=7] move container to output HEADLESS-2"))
                                      (should (>= (cl-count "-t get_tree" cmds :test #'equal) 2))
                                      (should-not (cl-some (lambda (c) (string-match-p "focus" c)) cmds)))))))

(drgnx-platform-test--deftest drgnx-platform-wm/sway-place-gives-up-at-the-deadline ()
                              ;; the tree never holds a window with our pid and the placing title: the error comes at the (scaled) deadline
                              (drgnx-platform-wm-test--with-replies (("get_tree.json" . (drgnx-platform-wm-test--text "sway/get_tree.json")))
                                (drgnx-platform-test--with-frame 'pgtk '("SWAYSOCK=/s" "WAYLAND_DISPLAY=wayland-1")
                                  (set-frame-parameter frame 'title "before")
                                  (let* ((drgnx-platform-restore-timeout 0.5) (start (float-time))
                                         (res (drgnx-platform-wm-test--result
                                               (lambda (cb) (drgnx-platform-place-frame frame (drgnx-platform-wm-test--monitor "HEADLESS-2" 1280) cb))))
                                         (took (- (float-time) start)))
                                    (should (eq :error (car-safe res)))
                                    (should (stringp (cadr res)))
                                    (should (and (>= took 0.4) (< took 1.4)))
                                    (should (equal "before" (frame-parameter frame 'title)))
                                    (should-not (cl-some (lambda (c) (string-match-p "move container" c)) (drgnx-platform-wm-test--commands)))))))

(drgnx-platform-test--deftest drgnx-platform-wm/every-call-carries-the-frames-swaysock ()
                              (drgnx-platform-wm-test--with-replies (("get_tree.json" . (drgnx-platform-wm-test--ours))
                                                                     ("get_outputs.json" . (drgnx-platform-wm-test--text "sway/get_outputs.json")))
                                (drgnx-platform-test--with-frame 'pgtk '("SWAYSOCK=/frame/sway.sock" "WAYLAND_DISPLAY=wayland-1")
                                  (should-not (getenv "SWAYSOCK"))
                                  (drgnx-platform-wm-test--focused t
                                    (drgnx-platform-wm-test--result (lambda (cb) (drgnx-platform-monitors frame cb)))
                                    (drgnx-platform-wm-test--result
                                     (lambda (cb) (drgnx-platform-move-frame frame (drgnx-platform-wm-test--monitor "HEADLESS-2" 1280) cb)))
                                    (let ((envs (with-temp-buffer (insert-file-contents (concat drgnx-platform-test--log ".env"))
                                                                  (split-string (buffer-string) "\n" t))))
                                      (should (= (length envs) (length (drgnx-platform-test--log-lines))))
                                      (should (>= (length envs) 4))
                                      (dolist (e envs) (should (string-prefix-p "SWAYSOCK=/frame/sway.sock " e))))))))

;;;; Messages

(drgnx-platform-test--deftest drgnx-platform-wm/a-failed-command-gives-sways-own-error-text ()
                              ;; exit status 2 with the JSON on standard output, as sway answers an unknown con
                              (drgnx-platform-wm-test--with-replies (("get_tree.json" . (drgnx-platform-wm-test--ours))
                                                                     ("fail.json" . "[{\"success\":false,\"parse_error\":false,\"error\":\"No matching node.\"}]"))
                                (drgnx-platform-test--with-frame 'pgtk '("SWAYSOCK=/s" "WAYLAND_DISPLAY=wayland-1")
                                  (drgnx-platform-wm-test--focused t
                                    (let ((process-environment (cons "DRGNX_FAKE_WM_MAP=get_tree get_tree\nmove container fail\n" process-environment)))
                                      (should (equal '(:error "No matching node.")
                                                     (drgnx-platform-wm-test--result
                                                      (lambda (cb) (drgnx-platform-move-frame frame (drgnx-platform-wm-test--monitor "HEADLESS-2" 1280) cb)))))
                                      ;; the focus command is not sent after a failed move
                                      (should-not (cl-some (lambda (c) (string-match-p "focus" c)) (drgnx-platform-wm-test--commands))))))
                                (drgnx-platform-test--with-frame 'pgtk '("SWAYSOCK=/s" "WAYLAND_DISPLAY=wayland-1")
                                  (let ((process-environment (append '("DRGNX_FAKE_WM_EXIT=2"
                                                                       "DRGNX_FAKE_WM_OUT=[{\"success\":false,\"error\":\"Can't find output with name/direction 'NOPE'\"}]")
                                                                     process-environment)))
                                    (should (equal '(:error "Can't find output with name/direction 'NOPE'")
                                                   (drgnx-platform-wm-test--result (lambda (cb) (drgnx-platform-monitors frame cb)))))))))

(drgnx-platform-test--deftest drgnx-platform-wm/a-missing-tool-and-a-silent-one-are-explained ()
                              (drgnx-platform-test--with-frame 'pgtk '("SWAYSOCK=/s" "WAYLAND_DISPLAY=wayland-1")
                                (let ((exec-path nil))
                                  (should (equal '(:error "sway: swaymsg is not installed, so drgnx cannot move windows")
                                                 (drgnx-platform-wm-test--result
                                                  (lambda (cb) (drgnx-platform-move-frame frame (drgnx-platform-wm-test--monitor "HEADLESS-2" 1280) cb)))))))
                              (drgnx-platform-wm-test--with-replies (("get_tree.json" . (drgnx-platform-wm-test--ours)))
                                (drgnx-platform-test--with-frame 'pgtk '("SWAYSOCK=/s" "WAYLAND_DISPLAY=wayland-1")
                                  (drgnx-platform-wm-test--focused t
                                    (let ((process-environment (cons "DRGNX_FAKE_WM_DELAY=3" process-environment))
                                          (drgnx-platform-command-timeout 0.3))
                                      (should (equal '(:error "sway did not answer within 0.3 s; the window was not moved")
                                                     (drgnx-platform-wm-test--result
                                                      (lambda (cb) (drgnx-platform-move-frame frame (drgnx-platform-wm-test--monitor "HEADLESS-2" 1280) cb))))))))))

(drgnx-platform-test--deftest drgnx-platform-wm/a-whole-move-stays-inside-one-deadline ()
                              ;; two tool calls (tree, then move) share the operation's deadline: with a delay of 0.4 s each and a 0.6 s
                              ;; deadline the second call is cut at the deadline, not 0.4 s after it
                              (drgnx-platform-wm-test--with-replies (("get_tree.json" . (drgnx-platform-wm-test--ours)))
                                (drgnx-platform-test--with-frame 'pgtk '("SWAYSOCK=/s" "WAYLAND_DISPLAY=wayland-1")
                                  (drgnx-platform-wm-test--focused t
                                    (let ((process-environment (cons "DRGNX_FAKE_WM_DELAY=0.4" process-environment))
                                          (drgnx-platform-command-timeout 0.6) (start (float-time)) res)
                                      (setq res (drgnx-platform-wm-test--result
                                                 (lambda (cb) (drgnx-platform-move-frame frame (drgnx-platform-wm-test--monitor "HEADLESS-2" 1280) cb))))
                                      (should (equal '(:error "sway did not answer within 0.6 s; the window was not moved") res))
                                      (should (< (- (float-time) start) 0.95)))))))

;;;; i3

(drgnx-platform-test--deftest drgnx-platform-wm/i3-moves-by-x-window-id ()
                              (drgnx-platform-wm-test--with-replies (("get_tree.json" . (drgnx-platform-wm-test--text "i3/get_tree.json"))
                                                                     ("get_outputs.json" . (drgnx-platform-wm-test--text "i3/get_outputs.json")))
                                (drgnx-platform-test--with-frame 'x '("I3SOCK=/frame/i3.sock" "DISPLAY=:0")
                                  (set-frame-parameter frame 'outer-window-id "6291785")
                                  (should (eq 'i3 (drgnx-platform-wm frame)))
                                  (let ((ms (drgnx-platform-wm-test--result (lambda (cb) (drgnx-platform-monitors frame cb)))))
                                    (should (equal (mapcar (lambda (m) (plist-get m :name)) ms) '("left" "right"))))
                                  (drgnx-platform-wm-test--focused t
                                    (should (eq 'ok (drgnx-platform-wm-test--result
                                                     (lambda (cb) (drgnx-platform-move-frame frame (drgnx-platform-wm-test--monitor "right" 1280) cb)))))
                                    (should (equal (cdr (drgnx-platform-wm-test--commands))
                                                   '("-t get_tree"
                                                     "[id=6291785] move container to output right"
                                                     "[id=6291785] focus")))
                                    (should (cl-every (lambda (l) (string-prefix-p "i3-msg " l)) (drgnx-platform-test--log-lines)))
                                    ;; the window of another application has focus: refuse, nothing is moved
                                    (drgnx-platform-wm-test--write "get_tree.json" (drgnx-platform-wm-test--text "i3/get_tree-unfocused.json"))
                                    (should (equal (list :error drgnx-platform-wm-test--refusal)
                                                   (drgnx-platform-wm-test--result
                                                    (lambda (cb) (drgnx-platform-move-frame frame (drgnx-platform-wm-test--monitor "right" 1280) cb)))))
                                    (should (= 1 (cl-count-if (lambda (c) (string-match-p "move container" c)) (drgnx-platform-wm-test--commands))))))))

(drgnx-platform-test--deftest drgnx-platform-wm/i3-places-a-restored-window-without-a-title ()
                              (drgnx-platform-wm-test--with-replies (("get_tree.json" . (drgnx-platform-wm-test--text "i3/get_tree-unfocused.json")))
                                (drgnx-platform-test--with-frame 'x '("I3SOCK=/i3.sock" "DISPLAY=:0")
                                  (set-frame-parameter frame 'outer-window-id "6291785")
                                  (set-frame-parameter frame 'title "before")
                                  (should (eq 'ok (drgnx-platform-wm-test--result
                                                   (lambda (cb) (drgnx-platform-place-frame frame (drgnx-platform-wm-test--monitor "right" 1280) cb)))))
                                  (should (equal "before" (frame-parameter frame 'title)))
                                  (should (equal (drgnx-platform-wm-test--commands)
                                                 '("-t get_tree" "[id=6291785] move container to output right"))))))

(provide 'platform-wm-test)
;;; platform-wm-test.el ends here
