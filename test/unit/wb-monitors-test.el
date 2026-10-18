;;; wb-monitors-test.el --- batch tests: Move to Monitor…, Next and Previous -*- lexical-binding: t -*-
;; A fake adapter stands in for the window manager; the real compositor, D-Bus and display are never reached
;; (the isolation macro of platform-test.el wraps every test).  The frame is batch Emacs' only frame, a terminal
;; one, so `display-graphic-p' is stubbed where a graphical frame is needed.
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx)
(require 'drgnx-paths)
(require 'drgnx-platform)
(require 'drgnx-monitors)
(unless (fboundp 'drgnx-platform-test--deftest)
  (load (expand-file-name "platform-test.el" (file-name-directory (or load-file-name buffer-file-name))) nil t))

;;;; Helpers

(defvar drgnx-monitors-test--current 0 "Index of the fake monitor the frame is on.")
(defvar drgnx-monitors-test--moves nil "Names of the monitors the fake adapter was asked to move to, oldest first.")
(defvar drgnx-monitors-test--calls nil "Counts of the fake adapter's calls: (:monitors N :frame-monitor N).")

(defconst drgnx-monitors-test--two
  '((:name "DP-1" :geometry (0 0 1920 1080)) (:name "DP-2" :geometry (1920 0 2560 1440)))
  "Two monitors, DP-2 to the right.")

(defun drgnx-monitors-test--later (delay fn) (run-at-time delay nil fn))

(defun drgnx-monitors-test--count (key)
  (setq drgnx-monitors-test--calls
        (plist-put drgnx-monitors-test--calls key (1+ (or (plist-get drgnx-monitors-test--calls key) 0)))))

(defmacro drgnx-monitors-test--with-fake (opts &rest body)
  "BODY with the selected frame (`frame') on a fake window manager and a graphical `display-graphic-p'.
`messages' collects what `message' says, newest first.  OPTS (a plist, evaluated): :monitors, :delay (seconds
the fake takes to answer), :move-reply (default `ok'), :current (index of the monitor the frame is on)."
  (declare (indent 1))
  `(let* ((opts (list ,@opts)) (monitors (or (plist-get opts :monitors) drgnx-monitors-test--two))
          (delay (or (plist-get opts :delay) 0))
          (drgnx-monitors-test--current (or (plist-get opts :current) 0))
          (drgnx-monitors-test--moves nil) (drgnx-monitors-test--calls nil)
          (drgnx-monitors--count nil) (drgnx-monitors--pending nil) (drgnx-monitors--timer nil)
          (messages nil) (inhibit-interaction t))
     (drgnx-platform-test--with-adapter
      'fakemon
      (list :title "Fake"
            :can-move (lambda (_ctx) t)
            :monitors (lambda (_ctx cb)
                        (drgnx-monitors-test--count :monitors)
                        (drgnx-monitors-test--later delay (lambda () (funcall cb (copy-tree monitors)))))
            :frame-monitor (lambda (_ctx cb)
                             (drgnx-monitors-test--count :frame-monitor)
                             (drgnx-monitors-test--later
                              delay (lambda () (funcall cb (copy-tree (nth drgnx-monitors-test--current monitors))))))
            :move (lambda (_ctx mon cb)
                    (setq drgnx-monitors-test--moves
                          (append drgnx-monitors-test--moves (list (plist-get mon :name))))
                    (let ((reply (if (plist-member opts :move-reply) (plist-get opts :move-reply) 'ok)))
                      (when (eq reply 'ok)
                        (setq drgnx-monitors-test--current
                              (seq-position monitors (plist-get mon :name)
                                            (lambda (m n) (equal (plist-get m :name) n)))))
                      (drgnx-monitors-test--later 0 (lambda () (funcall cb reply))))))
      (lambda ()
        (drgnx-platform-test--with-frame 'pgtk '("FAKEMON=1")
          (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
                    ((symbol-function 'message)
                     (lambda (fmt &rest args) (when fmt (push (apply #'format fmt args) messages)) nil)))
            (unwind-protect (progn ,@body)
              (when (timerp drgnx-monitors--timer) (cancel-timer drgnx-monitors--timer))
              (modify-frame-parameters frame '((drgnx-monitor) (drgnx-monitors-refreshed))))))))))

(defun drgnx-monitors-test--move (frame target)
  "Move FRAME to TARGET and wait for the answer."
  (let (res)
    (drgnx-monitors-move frame target (lambda (r) (setq res (list r))))
    (should (drgnx-platform-test--await (lambda () res)))
    (car res)))

(defun drgnx-monitors-test--has-message (regexp messages)
  (seq-some (lambda (m) (string-match-p regexp m)) messages))

(defmacro drgnx-monitors-test--with-core-commands (&rest body)
  "BODY with a registry holding the core and module commands, nothing else."
  `(let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
         (drgnx-commands-problems nil) (drgnx-modules--table nil) (drgnx-modules--report nil)
         (ring-bell-function ring-bell-function) (use-dialog-box use-dialog-box)
         (use-short-answers use-short-answers) (inhibit-startup-screen inhibit-startup-screen))
     (drgnx--core-commands)
     (drgnx-modules-load-directory (expand-file-name "modules" drgnx-dir))
     (drgnx-modules-run 'startup)
     ,@body))

;;;; Moving

(drgnx-platform-test--deftest drgnx-monitors/move-to-2-then-next-wraps-back-to-1 ()
                              (drgnx-monitors-test--with-fake ()
                                (should (eq 'ok (drgnx-monitors-test--move frame 2)))
                                (should (equal drgnx-monitors-test--moves '("DP-2")))
                                (should (equal (plist-get (frame-parameter frame 'drgnx-monitor) :name) "DP-2"))
                                (should (eq 'ok (drgnx-monitors-test--move frame 'next)))     ; 2 + 1 wraps to 1
                                (should (equal drgnx-monitors-test--moves '("DP-2" "DP-1")))
                                (should (eq 'ok (drgnx-monitors-test--move frame 'previous))) ; 1 - 1 wraps to 2
                                (should (equal drgnx-monitors-test--moves '("DP-2" "DP-1" "DP-2")))
                                (should (equal (plist-get (frame-parameter frame 'drgnx-monitor) :name) "DP-2"))))

(drgnx-platform-test--deftest drgnx-monitors/the-commands-say-moving-then-where ()
                              (drgnx-monitors-test--with-fake ()
                                (drgnx-monitors-move-next)
                                (should (equal (car messages) "Moving…"))
                                (should (drgnx-platform-test--await (lambda () (drgnx-monitors-test--has-message "^Moved to monitor 2 (DP-2)$" messages))))
                                (drgnx-monitors-move-previous)
                                (should (drgnx-platform-test--await (lambda () (drgnx-monitors-test--has-message "^Moved to monitor 1 (DP-1)$" messages))))
                                (should (equal drgnx-monitors-test--moves '("DP-2" "DP-1")))))

(drgnx-platform-test--deftest drgnx-monitors/the-picker-shows-the-labels ()
                              (drgnx-monitors-test--with-fake (:monitors '((:name "DP-1" :geometry (0 0 1920 1080))
                                                                           (:name "DP-2" :geometry (1920 0 2560 1440))))
                                (let (shown)
                                  (cl-letf (((symbol-function 'completing-read)
                                             (lambda (_prompt collection &rest _)
                                               (setq shown (all-completions "" collection))
                                               (cadr shown))))
                                    (drgnx-monitors-move-to))
                                  (should (equal (car shown) "1 — DP-1, 1920×1080"))
                                  (should (equal (cadr shown) "2 — DP-2, 2560×1440, right of 1"))
                                  (should (drgnx-platform-test--await
                                           (lambda () (drgnx-monitors-test--has-message "^Moved to monitor 2 (DP-2)$" messages))))
                                  (should (equal drgnx-monitors-test--moves '("DP-2"))))))

(drgnx-platform-test--deftest drgnx-monitors/a-cancelled-picker-moves-nothing ()
                              (drgnx-monitors-test--with-fake ()
                                (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (signal 'quit nil))))
                                  (drgnx-monitors-move-to))
                                (accept-process-output nil 0.1)
                                (should-not drgnx-monitors-test--moves)))

(drgnx-platform-test--deftest drgnx-monitors/gnome-says-why-and-names-the-key-and-moves-nothing ()
                              (drgnx-platform-test--with-frame 'pgtk '("XDG_CURRENT_DESKTOP=GNOME")
                                (let ((messages nil))
                                  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
                                            ((symbol-function 'completing-read) (lambda (&rest _) (ert-fail "a picker opened on GNOME")))
                                            ((symbol-function 'message)
                                             (lambda (fmt &rest args) (when fmt (push (apply #'format fmt args) messages)) nil)))
                                    (should (eq 'gnome (drgnx-platform-wm frame)))
                                    (dolist (cmd '(drgnx-monitors-move-to drgnx-monitors-move-next drgnx-monitors-move-previous))
                                      (setq messages nil)
                                      (funcall cmd)
                                      (accept-process-output nil 0.05)
                                      (should (= 1 (length messages)))
                                      (should (string-match-p "\\`GNOME does not let apps move their windows: press Super\\+Shift\\+→ or Super\\+Shift\\+←"
                                                              (car messages))))
                                    (let (res)
                                      (drgnx-monitors-move frame 2 (lambda (r) (setq res r)))
                                      (should (drgnx-platform-test--await (lambda () res)))
                                      (should (eq (car res) :error))
                                      (should (string-match-p "\\`GNOME does not let apps move their windows: press Super\\+Shift\\+→ or Super\\+Shift\\+←"
                                                              (cadr res))))))))

(drgnx-platform-test--deftest drgnx-monitors/one-monitor-says-so ()
                              (drgnx-monitors-test--with-fake (:monitors '((:name "DP-1" :geometry (0 0 1920 1080))))
                                (should (equal (drgnx-monitors-test--move frame 'next)
                                               '(:error "Only one monitor: there is nowhere to move this window")))
                                (should-not drgnx-monitors-test--moves)
                                (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (ert-fail "a picker opened with one monitor"))))
                                  (drgnx-monitors-move-to))
                                (should (equal (car messages) "Only one monitor: there is nowhere to move this window"))))

(drgnx-platform-test--deftest drgnx-monitors/a-monitor-that-is-not-there-is-said-so ()
                              (drgnx-monitors-test--with-fake ()
                                (should (equal (drgnx-monitors-test--move frame 3) '(:error "There is no monitor 3: there are 2")))
                                (should-not drgnx-monitors-test--moves)))

(drgnx-platform-test--deftest drgnx-monitors/the-monitor-it-is-on-already-is-no-move ()
                              (drgnx-monitors-test--with-fake (:current 1)
                                (should (eq 'ok (drgnx-monitors-test--move frame 2)))
                                (should-not drgnx-monitors-test--moves)))

(drgnx-platform-test--deftest drgnx-monitors/next-without-knowing-where-the-window-is-says-so ()
                              (drgnx-monitors-test--with-fake (:current 5)         ; the fake answers nil: no monitor known
                                (should (equal (drgnx-monitors-test--move frame 'next)
                                               '(:error "Cannot tell which monitor this window is on")))
                                (should-not drgnx-monitors-test--moves)))

(drgnx-platform-test--deftest drgnx-monitors/a-failed-move-is-a-message-not-an-error ()
                              (drgnx-monitors-test--with-fake (:move-reply '(:error "sway did not answer within 2 s; the window was not moved"))
                                (should (equal (drgnx-monitors-test--move frame 2)
                                               '(:error "sway did not answer within 2 s; the window was not moved")))
                                (should-not (frame-parameter frame 'drgnx-monitor))
                                (drgnx-monitors-move-next)
                                (should (drgnx-platform-test--await
                                         (lambda () (drgnx-monitors-test--has-message "sway did not answer within 2 s" messages))))))

(drgnx-platform-test--deftest drgnx-monitors/an-adapter-that-signals-gives-an-error-result ()
                              (drgnx-platform-test--with-adapter
                               'sigmon (list :can-move (lambda (_ctx) t) :monitors (lambda (&rest _) (error "monitor bug")))
                               (lambda ()
                                 (drgnx-platform-test--with-frame 'pgtk '("SIGMON=1")
                                   (let (res)
                                     (drgnx-monitors-move frame 'next (lambda (r) (setq res r)))
                                     (should (drgnx-platform-test--await (lambda () res)))
                                     (should (eq (car res) :error)))))))

;;;; Refreshing

(drgnx-platform-test--deftest drgnx-monitors/refresh-is-debounced-and-never-blocks ()
                              (drgnx-monitors-test--with-fake (:delay 0.2)
                                (let ((start (float-time)))
                                  (dotimes (_ 10) (drgnx-monitors--focus-changed))
                                  (should (< (- (float-time) start) 0.1)))
                                (should (= 1 (length (seq-filter (lambda (tm) (eq (timer--function tm) #'drgnx-monitors--run-pending))
                                                                 timer-idle-list))))
                                (let ((start (float-time)))
                                  (drgnx-monitors--run-pending)
                                  (should (< (- (float-time) start) 0.1))      ; the adapter answers 0.2 s later: nothing waited for it
                                  (should-not (frame-parameter frame 'drgnx-monitor)))
                                (should (drgnx-platform-test--await (lambda () (frame-parameter frame 'drgnx-monitor))))
                                (should (equal (plist-get (frame-parameter frame 'drgnx-monitor) :name) "DP-1"))
                                (should (drgnx-platform-test--await (lambda () drgnx-monitors--count)))
                                (should (= drgnx-monitors--count 2))
                                (should (= 1 (plist-get drgnx-monitors-test--calls :frame-monitor)))
                                (should (= 1 (plist-get drgnx-monitors-test--calls :monitors)))
                                ;; more focus changes within 10 s: no further call
                                (dotimes (_ 10) (drgnx-monitors--focus-changed))
                                (drgnx-monitors--run-pending)
                                (accept-process-output nil 0.4)
                                (should (= 1 (plist-get drgnx-monitors-test--calls :frame-monitor)))
                                ;; 11 s later: one more
                                (set-frame-parameter frame 'drgnx-monitors-refreshed (- (float-time) 11))
                                (drgnx-monitors--focus-changed)
                                (drgnx-monitors--run-pending)
                                (should (drgnx-platform-test--await (lambda () (= 2 (plist-get drgnx-monitors-test--calls :frame-monitor)))))))

(drgnx-platform-test--deftest drgnx-monitors/no-refresh-for-a-terminal-frame ()
                              (drgnx-monitors-test--with-fake ()
                                (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) nil)))
                                  (drgnx-monitors-refresh frame)
                                  (drgnx-monitors--focus-changed)
                                  (drgnx-monitors--run-pending)
                                  (accept-process-output nil 0.1)
                                  (should-not drgnx-monitors-test--calls))))

(drgnx-platform-test--deftest drgnx-monitors/hot-plug-only-refreshes ()
                              (drgnx-monitors-test--with-fake ()
                                (drgnx-monitors-mode 1)
                                (unwind-protect
                                    (progn
                                      (should (memq #'drgnx-monitors--monitors-changed display-monitors-changed-functions))
                                      (accept-process-output nil 0.1)
                                      (setq drgnx-monitors-test--calls nil drgnx-monitors--count nil)
                                      (run-hook-with-args 'display-monitors-changed-functions nil)
                                      (should (drgnx-platform-test--await (lambda () drgnx-monitors--count)))
                                      (should (plist-get drgnx-monitors-test--calls :monitors))
                                      (should (plist-get drgnx-monitors-test--calls :frame-monitor))
                                      (should-not drgnx-monitors-test--moves))
                                  (drgnx-monitors-mode -1))))

(drgnx-platform-test--deftest drgnx-monitors/the-mode-adds-and-removes-its-hooks ()
                              (unwind-protect
                                  (progn
                                    (drgnx-monitors-mode 1)
                                    (should (memq #'drgnx-monitors--monitors-changed display-monitors-changed-functions))
                                    (should (memq #'drgnx-monitors--frame-moved move-frame-functions))
                                    (should (advice-function-member-p #'drgnx-monitors--focus-changed after-focus-change-function))
                                    (drgnx-monitors-mode -1)
                                    (should-not (memq #'drgnx-monitors--monitors-changed display-monitors-changed-functions))
                                    (should-not (memq #'drgnx-monitors--frame-moved move-frame-functions))
                                    (should-not (advice-function-member-p #'drgnx-monitors--focus-changed after-focus-change-function)))
                                (drgnx-monitors-mode -1)))

;;;; Offering the commands

(drgnx-platform-test--deftest drgnx-monitors/not-offered-in-a-terminal-frame ()
                              (drgnx-monitors-test--with-core-commands
                               (let ((ids '(window-move-to-monitor window-move-to-next-monitor window-move-to-previous-monitor)))
                                 (dolist (id ids)
                                   (should (drgnx-commands-get id))
                                   (should-not (drgnx-commands-available-p (drgnx-commands-get id))))
                                 (should-not (drgnx-monitors-available-p))
                                 (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t)))
                                   (dolist (id ids)
                                     (should (drgnx-commands-available-p (drgnx-commands-get id))))
                                   (should (drgnx-monitors-available-p))
                                   (cl-letf (((symbol-function 'frame-parent) (lambda (&optional _) 'parent)))
                                     (should-not (drgnx-monitors-available-p)))))))

(drgnx-platform-test--deftest drgnx-monitors/only-move-to-monitor-is-in-the-right-click-menu ()
                              (drgnx-monitors-test--with-core-commands
                               (should (equal (drgnx-cmd-context (drgnx-commands-get 'window-move-to-monitor)) '(monitors)))
                               (should-not (drgnx-cmd-context (drgnx-commands-get 'window-move-to-next-monitor)))
                               (should-not (drgnx-cmd-context (drgnx-commands-get 'window-move-to-previous-monitor)))
                               (dolist (id '(window-move-to-monitor window-move-to-next-monitor window-move-to-previous-monitor))
                                 (should (equal (drgnx-cmd-category (drgnx-commands-get id)) "Window"))
                                 (should (eq (drgnx-cmd-scope (drgnx-commands-get id)) 'window)))))

(drgnx-platform-test--deftest drgnx-monitors/the-click-context-needs-more-than-one-monitor ()
                              (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t)))
                                (let ((drgnx-monitors--count 1)) (should-not (drgnx-monitors--context-p nil)))
                                (let ((drgnx-monitors--count 2)) (should (drgnx-monitors--context-p nil)))
                                (cl-letf (((symbol-function 'display-monitor-attributes-list) (lambda (&optional _) (list 'a 'b))))
                                  (let ((drgnx-monitors--count nil)) (should (drgnx-monitors--context-p nil))))   ; unknown: Emacs' own count
                                (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) nil)))
                                  (let ((drgnx-monitors--count 2)) (should-not (drgnx-monitors--context-p nil))))))

(provide 'wb-monitors-test)
;;; wb-monitors-test.el ends here
