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
(require 'drgnx-persist)
(unless (fboundp 'drgnx-persist-test--graphical)    ; its helpers: a restore in a batch frame
  (load (expand-file-name "wb-persist-test.el" (file-name-directory (or load-file-name buffer-file-name))) nil t))
(unless (fboundp 'drgnx-platform-test--deftest)
  (load (expand-file-name "platform-test.el" (file-name-directory (or load-file-name buffer-file-name))) nil t))

;;;; Helpers

(defvar drgnx-monitors-test--current 0 "Index of the fake monitor the frame is on.")
(defvar drgnx-monitors-test--moves nil "Names of the monitors the fake adapter was asked to move to, oldest first.")
(defvar drgnx-monitors-test--calls nil "Counts of the fake adapter's calls: (:monitors N :frame-monitor N).")
(defvar drgnx-monitors-test--places nil
  "What the fake adapter was asked to place while restoring, oldest first: (FRAME . MONITOR-NAME).")

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
the fake takes to answer), :move-reply (default `ok'), :current (index of the monitor the frame is on),
:sequence (a list of (DELAY . MONITORS) the fake's successive monitor listings follow), :frame-sequence (the same
for the monitor the frame is on: (DELAY . INDEX)), :move-delay (seconds a move takes), :place-reply (what placing a
restored frame answers, default `ok'; `hang': never answers)."
  (declare (indent 1))
  `(let* ((opts (list ,@opts)) (monitors (or (plist-get opts :monitors) drgnx-monitors-test--two))
          (delay (or (plist-get opts :delay) 0))
          (drgnx-monitors-test--current (or (plist-get opts :current) 0))
          (drgnx-monitors-test--moves nil) (drgnx-monitors-test--calls nil) (drgnx-monitors-test--places nil)
          (sequence (plist-get opts :sequence)) (frame-sequence (plist-get opts :frame-sequence))
          (drgnx-monitors--count nil) (drgnx-monitors--pending nil) (drgnx-monitors--timer nil)
          (drgnx-monitors--force nil) (drgnx-monitors--list-gen 0)
          (drgnx-monitors--stamps (make-hash-table :test #'eq :weakness 'key))
          (drgnx-monitors--gens (make-hash-table :test #'eq :weakness 'key))
          (drgnx-monitors--moving (make-hash-table :test #'eq :weakness 'key))
          (drgnx-monitors--placed (make-hash-table :test #'eq :weakness 'key))
          (messages nil) (inhibit-interaction t))
     (drgnx-platform-test--with-adapter
      'fakemon
      (list :title "Fake"
            :can-move (lambda (_ctx) t)
            :monitors (lambda (_ctx cb)
                        (drgnx-monitors-test--count :monitors)
                        (let ((step (if sequence (pop sequence) (cons delay monitors))))
                          (drgnx-monitors-test--later (car step) (lambda () (funcall cb (copy-tree (cdr step)))))))
            :frame-monitor (lambda (_ctx cb)
                             (drgnx-monitors-test--count :frame-monitor)
                             (let ((step (if frame-sequence (pop frame-sequence) (cons delay drgnx-monitors-test--current))))
                               (drgnx-monitors-test--later
                                (car step) (lambda () (funcall cb (copy-tree (nth (cdr step) monitors)))))))
            :move (lambda (_ctx mon cb)
                    (setq drgnx-monitors-test--moves
                          (append drgnx-monitors-test--moves (list (plist-get mon :name))))
                    (let ((reply (if (plist-member opts :move-reply) (plist-get opts :move-reply) 'ok)))
                      (when (eq reply 'ok)
                        (setq drgnx-monitors-test--current
                              (seq-position monitors (plist-get mon :name)
                                            (lambda (m n) (equal (plist-get m :name) n)))))
                      (drgnx-monitors-test--later (or (plist-get opts :move-delay) 0) (lambda () (funcall cb reply)))))
            :place (lambda (ctx mon cb)
                     (setq drgnx-monitors-test--places
                           (append drgnx-monitors-test--places (list (cons (plist-get ctx :frame) (plist-get mon :name)))))
                     (let ((reply (if (plist-member opts :place-reply) (plist-get opts :place-reply) 'ok)))
                       (unless (eq reply 'hang)
                         (drgnx-monitors-test--later 0 (lambda () (funcall cb reply)))))))
      (lambda ()
        (drgnx-platform-test--with-frame 'pgtk '("FAKEMON=1")
          (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
                    ((symbol-function 'message)
                     (lambda (fmt &rest args) (when fmt (push (apply #'format fmt args) messages)) nil)))
            (unwind-protect (progn ,@body)
              (when (timerp drgnx-monitors--timer) (cancel-timer drgnx-monitors--timer))
              (modify-frame-parameters frame '((drgnx-monitor))))))))))

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
                                ;; more focus changes within 10 s: no further call now, but a trailing refresh is armed
                                (dotimes (_ 10) (drgnx-monitors--focus-changed))
                                (drgnx-monitors--run-pending)
                                (accept-process-output nil 0.4)
                                (should (= 1 (plist-get drgnx-monitors-test--calls :frame-monitor)))
                                (should (timerp drgnx-monitors--timer))
                                (should (memq frame drgnx-monitors--pending))
                                ;; 11 s later: one more
                                (puthash frame (- (float-time) 11) drgnx-monitors--stamps)
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
                                      (drgnx-monitors--run-pending)
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

;;;; Races, storms and the rest of the review round

(drgnx-platform-test--deftest drgnx-monitors/an-older-count-reply-arriving-last-does-not-overwrite-the-newer
  ()
  (drgnx-monitors-test--with-fake (:sequence (list (cons 0.3 (append drgnx-monitors-test--two '((:name "DP-3" :geometry (4480 0 1920 1080)))))
                                                   (cons 0 drgnx-monitors-test--two)))
    (drgnx-monitors--fetch-count frame)      ; the first answer (3 monitors) comes last
    (drgnx-monitors--fetch-count frame)      ; the second (2 monitors) comes first
    (should (drgnx-platform-test--await (lambda () drgnx-monitors--count)))
    (should (= drgnx-monitors--count 2))
    (accept-process-output nil 0.5)
    (should (= drgnx-monitors--count 2))))

(drgnx-platform-test--deftest drgnx-monitors/an-older-monitor-reply-arriving-last-does-not-overwrite-the-newer ()
                              (drgnx-monitors-test--with-fake (:frame-sequence '((0.3 . 0) (0 . 1)))
                                (drgnx-monitors--fetch-monitor frame)    ; DP-1, but it comes last
                                (drgnx-monitors--fetch-monitor frame)    ; DP-2, first
                                (should (drgnx-platform-test--await (lambda () (frame-parameter frame 'drgnx-monitor))))
                                (accept-process-output nil 0.5)
                                (should (equal (plist-get (frame-parameter frame 'drgnx-monitor) :name) "DP-2"))))

(drgnx-platform-test--deftest drgnx-monitors/a-hot-plug-storm-is-one-refresh-that-ignores-the-interval ()
                              (drgnx-monitors-test--with-fake ()
                                (puthash frame (float-time) drgnx-monitors--stamps)         ; refreshed just now
                                (dotimes (_ 10) (drgnx-monitors--monitors-changed nil))
                                (should (= 1 (length (seq-filter (lambda (tm) (eq (timer--function tm) #'drgnx-monitors--run-pending))
                                                                 timer-idle-list))))
                                (should-not drgnx-monitors-test--calls)                      ; nothing ran in the hook itself
                                (drgnx-monitors--run-pending)
                                (should (drgnx-platform-test--await (lambda () drgnx-monitors--count)))
                                (accept-process-output nil 0.2)
                                (should (= 1 (plist-get drgnx-monitors-test--calls :monitors)))
                                (should (= 1 (plist-get drgnx-monitors-test--calls :frame-monitor)))
                                (should-not drgnx-monitors-test--moves)))

(drgnx-platform-test--deftest drgnx-monitors/the-monitor-list-is-fetched-once-for-all-frames ()
                              (drgnx-monitors-test--with-fake ()
                                (let ((other (make-symbol "other-frame")))
                                  (cl-letf (((symbol-function 'frame-list) (lambda () (list frame other)))
                                            ((symbol-function 'frame-live-p) (lambda (f) (memq f (list frame other))))
                                            ((symbol-function 'frame-parent) (lambda (&optional _) nil)))
                                    (drgnx-monitors--monitors-changed nil)
                                    (should (= 2 (length drgnx-monitors--pending)))
                                    (cl-letf (((symbol-function 'drgnx-platform-frame-monitor) (lambda (_f cb) (funcall cb nil)))
                                              ((symbol-function 'set-frame-parameter) #'ignore))
                                      (drgnx-monitors--run-pending))
                                    (accept-process-output nil 0.1)
                                    (should (= 1 (plist-get drgnx-monitors-test--calls :monitors)))))))

(drgnx-platform-test--deftest drgnx-monitors/the-hot-plug-hook-survives-a-signalling-adapter ()
                              (drgnx-platform-test--with-adapter
                               'sigmon (list :can-move (lambda (_ctx) t) :monitors (lambda (&rest _) (error "monitors bug"))
                                             :frame-monitor (lambda (&rest _) (error "frame bug")))
                               (lambda ()
                                 (drgnx-platform-test--with-frame 'pgtk '("SIGMON=1")
                                   (let ((drgnx-monitors--pending nil) (drgnx-monitors--timer nil) (drgnx-monitors--force nil)
                                         (drgnx-monitors--count nil) (drgnx-monitors--list-gen 0) (inhibit-interaction t)
                                         (drgnx-monitors--stamps (make-hash-table :test #'eq :weakness 'key))
                                         (drgnx-monitors--gens (make-hash-table :test #'eq :weakness 'key)))
                                     (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
                                               ((symbol-function 'message) (lambda (&rest _) nil))
                                               ((symbol-function 'display-monitor-attributes-list) (lambda (&optional _) (list 'a 'b 'c))))
                                       (unwind-protect
                                           (progn (run-hook-with-args 'display-monitors-changed-functions nil)
                                                  (drgnx-monitors--monitors-changed nil)
                                                  (drgnx-monitors--run-pending)
                                                  (should (drgnx-platform-test--await (lambda () drgnx-monitors--count)))
                                                  (should (= drgnx-monitors--count 3)))   ; Emacs' own count
                                         (when (timerp drgnx-monitors--timer) (cancel-timer drgnx-monitors--timer)))))))))

(drgnx-platform-test--deftest drgnx-monitors/focus-schedules-the-frames-that-have-focus ()
                              (drgnx-monitors-test--with-fake ()
                                (let ((a (make-symbol "a")) (b (make-symbol "b")))
                                  (cl-letf (((symbol-function 'frame-list) (lambda () (list a b)))
                                            ((symbol-function 'frame-live-p) (lambda (f) (memq f (list a b))))
                                            ((symbol-function 'frame-parent) (lambda (&optional _) nil))
                                            ((symbol-function 'frame-focus-state) (lambda (f) (eq f b))))
                                    (drgnx-monitors--focus-changed)
                                    (should (equal drgnx-monitors--pending (list b)))))))

(drgnx-platform-test--deftest drgnx-monitors/a-second-move-while-one-is-pending-is-ignored ()
                              (drgnx-monitors-test--with-fake (:move-delay 0.3)
                                (let (first second)
                                  (drgnx-monitors-move frame 2 (lambda (r) (setq first (list r))))
                                  (should (drgnx-platform-test--await (lambda () drgnx-monitors-test--moves)))   ; the first move is under way
                                  (drgnx-monitors-move frame 1 (lambda (r) (setq second (list r))))
                                  (should (drgnx-platform-test--await (lambda () second)))
                                  (should (eq (car (car second)) :error))
                                  (should (string-match-p "already under way" (cadr (car second))))
                                  (should (drgnx-platform-test--await (lambda () first)))
                                  (should (equal first '(ok)))
                                  (should (equal drgnx-monitors-test--moves '("DP-2")))
                                  (should (eq 'ok (drgnx-monitors-test--move frame 1))))))              ; free again

(drgnx-platform-test--deftest drgnx-monitors/the-picker-waits-a-bounded-time-for-an-adapter-that-never-answers ()
                              (drgnx-monitors-test--with-fake ()
                                (let ((drgnx-platform-command-timeout 0.05) (drgnx-platform-watchdog-margin 0))
                                  (cl-letf (((symbol-function 'drgnx-platform-monitors) (lambda (&rest _) nil))
                                            ((symbol-function 'completing-read) (lambda (&rest _) (ert-fail "a picker opened"))))
                                    (let ((start (float-time)))
                                      (drgnx-monitors-move-to)
                                      (should (< (- (float-time) start) 2)))
                                    (should (equal (car messages) "The window manager did not answer"))))))

(drgnx-platform-test--deftest drgnx-monitors/can-move-is-asked-once-per-command ()
                              (drgnx-monitors-test--with-fake ()
                                (let ((asked 0) (real (symbol-function 'drgnx-platform-can-move)))
                                  (cl-letf (((symbol-function 'drgnx-platform-can-move) (lambda (f) (cl-incf asked) (funcall real f))))
                                    (drgnx-monitors-move-next)
                                    (should (drgnx-platform-test--await (lambda () (drgnx-monitors-test--has-message "^Moved to" messages))))
                                    ;; the core's own move asks again: once here, once there
                                    (should (= asked 2))))))

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

;;;; Restore: auxiliary windows go back to their monitors
;; Batch Emacs has one frame and cannot make another, so the other windows are symbols with a table of
;; parameters, and the few frame functions the code under test uses answer for them.

(defvar drgnx-monitors-test--fakes nil "The fake frames: a list of (SYMBOL . PARAMETERS-ALIST).")

(defun drgnx-monitors-test--fake (name role extra)
  "A fake frame NAME in `drgnx-monitors-test--fakes', of role ROLE, with the persist extras EXTRA."
  (let ((f (make-symbol name)))
    (push (list f (cons 'drgnx-frame-role role) (cons 'drgnx-persist-extra extra)) drgnx-monitors-test--fakes)
    f))

(defmacro drgnx-monitors-test--with-fake-frames (&rest body)
  "BODY with the frames of `drgnx-monitors-test--fakes' listed (newest first, like Emacs) before the selected one and answering as frames."
  (declare (indent 0))
  `(let ((drgnx-monitors-test--fakes nil)
         (real (selected-frame)) (fp (symbol-function 'frame-parameter)) (sfp (symbol-function 'set-frame-parameter))
         (fl (symbol-function 'frame-live-p)) (fpar (symbol-function 'frame-parent)) (ge (symbol-function 'getenv)))
     (cl-letf (((symbol-function 'frame-list) (lambda () (append (mapcar #'car drgnx-monitors-test--fakes) (list real))))
               ((symbol-function 'frame-parameter)
                (lambda (f p) (if-let* ((e (assq f drgnx-monitors-test--fakes))) (cdr (assq p (cdr e))) (funcall fp f p))))
               ((symbol-function 'set-frame-parameter)
                (lambda (f p v) (if-let* ((e (assq f drgnx-monitors-test--fakes))) (setf (alist-get p (cdr e)) v) (funcall sfp f p v))))
               ((symbol-function 'frame-live-p) (lambda (f) (or (assq f drgnx-monitors-test--fakes) (funcall fl f))))
               ((symbol-function 'frame-parent) (lambda (&optional f) (if (assq f drgnx-monitors-test--fakes) nil (funcall fpar f))))
               ((symbol-function 'getenv)
                (lambda (v &optional f) (funcall ge v (if (assq f drgnx-monitors-test--fakes) real f)))))
       ,@body)))

(defconst drgnx-monitors-test--dell
  '(:name "DP-2" :make "DELL" :model "U2720Q" :serial "ABC1" :geometry (1920 0 2560 1440))
  "The saved identity of the second fake monitor.")

(defun drgnx-monitors-test--extra (monitor &optional fullscreen)
  (list :monitors-monitor monitor :monitors-fullscreen fullscreen))

(drgnx-platform-test--deftest drgnx-monitors/the-state-keeps-monitor-and-fullscreen ()
                              (drgnx-monitors-test--with-fake ()
                                (let ((drgnx-persist-state-functions (list #'drgnx-monitors--state)))
                                  (set-frame-parameter nil 'drgnx-monitor
                                                       (list :name "DP-2" :make "DELL" :model "U2720Q" :serial "ABC1"
                                                             :geometry '(1920 0 2560 1440) :workarea '(1920 0 2560 1400)
                                                             :number 2 :label "2 — DP-2, 2560×1440"))
                                  (set-frame-parameter nil 'fullscreen 'maximized)
                                  (unwind-protect
                                      (let ((extra (drgnx-persist--extra)))
                                        (should (equal (plist-get extra :monitors-fullscreen) 'maximized))
                                        (should (equal (plist-get (plist-get extra :monitors-monitor) :name) "DP-2"))
                                        (should (equal (plist-get (plist-get extra :monitors-monitor) :serial) "ABC1"))
                                        (should (equal (plist-get (plist-get extra :monitors-monitor) :geometry) '(1920 0 2560 1440)))
                                        (should (readablep extra))
                                        ;; the frame parameter itself is never saved: only the identity, no numbering
                                        (should-not (plist-member (plist-get extra :monitors-monitor) :number))
                                        (should-not (plist-member extra :drgnx-monitor))
                                        (set-frame-parameter nil 'drgnx-monitor nil)      ; GNOME, other Wayland, a terminal
                                        (should-not (plist-member (drgnx-persist--extra) :monitors-monitor)))
                                    (set-frame-parameter nil 'fullscreen nil)))))

(drgnx-platform-test--deftest drgnx-monitors/the-mode-hooks-persistence-and-unhooks ()
                              (let ((drgnx-persist-state-functions nil) (drgnx-persist-after-restore-functions nil))
                                (cl-letf (((symbol-function 'drgnx-monitors--schedule-frames) #'ignore))
                                  (drgnx-monitors-mode 1)
                                  (unwind-protect
                                      (progn (should (memq #'drgnx-monitors--state drgnx-persist-state-functions))
                                             (should (memq #'drgnx-monitors--place-restored drgnx-persist-after-restore-functions)))
                                    (drgnx-monitors-mode -1))
                                  (should-not (memq #'drgnx-monitors--state drgnx-persist-state-functions))
                                  (should-not (memq #'drgnx-monitors--place-restored drgnx-persist-after-restore-functions)))))

(drgnx-platform-test--deftest drgnx-monitors/restore-places-aux-windows-only ()
                              (drgnx-monitors-test--with-fake ()
                                (drgnx-monitors-test--with-fake-frames
                                  (let* ((extra (drgnx-monitors-test--extra drgnx-monitors-test--dell 'fullboth))
                                         (main (drgnx-monitors-test--fake "main" 'main extra))
                                         (aux (drgnx-monitors-test--fake "aux" 'aux extra))
                                         (editor (drgnx-monitors-test--fake "editor" 'editor extra))
                                         (job (drgnx-monitors-test--fake "job" nil extra))      ; a custom window: no role
                                         (plain (drgnx-monitors-test--fake "plain" 'aux nil)))   ; an older state file's window
                                    (set-frame-parameter job 'drgnx-persist-restore '(ignore))
                                    (drgnx-monitors--place-restored main)
                                    (should (drgnx-platform-test--await (lambda () drgnx-monitors-test--places)))
                                    (drgnx-platform-test--await (lambda () nil) 0.1)
                                    (should (equal drgnx-monitors-test--places (list (cons aux "DP-2"))))
                                    (should (eq (frame-parameter aux 'fullscreen) 'fullboth))
                                    (dolist (f (list main editor job plain))
                                      (should-not (frame-parameter f 'fullscreen)))
                                    (should (= 1 (plist-get drgnx-monitors-test--calls :monitors)))   ; read once
                                    (should-not messages)
                                    ;; a second call does not place it again
                                    (drgnx-monitors--place-restored main)
                                    (drgnx-platform-test--await (lambda () nil) 0.1)
                                    (should (= 1 (length drgnx-monitors-test--places)))))))

(drgnx-platform-test--deftest drgnx-monitors/the-monitor-is-matched-by-identity-not-by-the-pgtk-name ()
                              ;; The saved name is stale (pgtk names are no identity), the serial and the geometry say which one.
                              (drgnx-monitors-test--with-fake (:monitors '((:name "HDMI-A-1" :make "DELL" :model "U2720Q" :serial "ABC1"
                                                                                  :geometry (0 0 2560 1440))
                                                                           (:name "DP-2" :make "LG" :model "X" :serial "Z9"
                                                                                  :geometry (2560 0 1920 1080))))
                                (drgnx-monitors-test--with-fake-frames
                                  (let ((aux (drgnx-monitors-test--fake "aux" 'aux (drgnx-monitors-test--extra drgnx-monitors-test--dell))))
                                    (drgnx-monitors--place-restored (selected-frame))
                                    (should (drgnx-platform-test--await (lambda () drgnx-monitors-test--places)))
                                    (should (equal drgnx-monitors-test--places (list (cons aux "HDMI-A-1"))))))))

(drgnx-platform-test--deftest drgnx-monitors/a-missing-monitor-is-skipped-with-one-message ()
                              (drgnx-monitors-test--with-fake (:monitors '((:name "DP-1" :geometry (0 0 1920 1080))))
                                (drgnx-monitors-test--with-fake-frames
                                  (let ((one (drgnx-monitors-test--fake "one" 'aux (drgnx-monitors-test--extra drgnx-monitors-test--dell)))
                                        (home (drgnx-monitors-test--fake "home" 'aux (drgnx-monitors-test--extra '(:name "DP-1" :geometry (0 0 1920 1080))))))
                                    (drgnx-monitors--place-restored (selected-frame))
                                    (drgnx-platform-test--await (lambda () (and messages drgnx-monitors-test--places)) 1)
                                    (drgnx-platform-test--await (lambda () nil) 0.1)
                                    (should (equal drgnx-monitors-test--places (list (cons home "DP-1"))))   ; the missing one is not placed
                                    (should (equal messages
                                                   '("drgnx: 1 window's monitor is not connected (DELL U2720Q); the window manager placed it")))
                                    (should-not (frame-parameter one 'fullscreen))))))

(drgnx-platform-test--deftest drgnx-monitors/several-missing-monitors-are-one-message ()
                              (drgnx-monitors-test--with-fake (:monitors '((:name "DP-1" :geometry (0 0 1920 1080))))
                                (drgnx-monitors-test--with-fake-frames
                                  (drgnx-monitors-test--fake "a" 'aux (drgnx-monitors-test--extra drgnx-monitors-test--dell))
                                  (drgnx-monitors-test--fake "b" 'aux (drgnx-monitors-test--extra drgnx-monitors-test--dell))
                                  (drgnx-monitors-test--fake "c" 'aux (drgnx-monitors-test--extra '(:name "" :geometry (5000 0 800 600))))
                                  (drgnx-monitors--place-restored (selected-frame))
                                  (drgnx-platform-test--await (lambda () messages) 1)
                                  (drgnx-platform-test--await (lambda () nil) 0.1)
                                  (should (equal drgnx-monitors-test--places nil))
                                  (should (equal messages
                                                 '("drgnx: 3 windows' monitors are not connected (DELL U2720Q, 800×600 at 5000,0); the window manager placed them"))))))

(drgnx-platform-test--deftest drgnx-monitors/an-older-state-file-restores-as-before ()
                              ;; Format 2 without :extra (or with extras of other modules only): nothing placed, no message,
                              ;; not even the monitors read.
                              (drgnx-monitors-test--with-fake ()
                                (drgnx-monitors-test--with-fake-frames
                                  (drgnx-monitors-test--fake "old" 'aux nil)
                                  (drgnx-monitors-test--fake "other" 'aux '(:layout code))
                                  (drgnx-monitors--place-restored (selected-frame))
                                  (drgnx-platform-test--await (lambda () nil) 0.2)
                                  (should-not drgnx-monitors-test--places)
                                  (should-not (plist-get drgnx-monitors-test--calls :monitors))
                                  (should-not messages))))

(drgnx-platform-test--deftest drgnx-monitors/a-failing-adapter-says-so-once-and-stops ()
                              (drgnx-monitors-test--with-fake (:place-reply '(:error "no such output"))
                                (drgnx-monitors-test--with-fake-frames
                                  (drgnx-monitors-test--fake "a" 'aux (drgnx-monitors-test--extra drgnx-monitors-test--dell))
                                  (drgnx-monitors-test--fake "b" 'aux (drgnx-monitors-test--extra drgnx-monitors-test--dell))
                                  (drgnx-monitors--place-restored (selected-frame))
                                  (drgnx-platform-test--await (lambda () messages) 1)
                                  (drgnx-platform-test--await (lambda () nil) 0.1)
                                  (should (= 1 (length drgnx-monitors-test--places)))        ; the second is not tried
                                  (should (= 1 (length messages)))
                                  (should (string-match-p "no such output" (car messages))))))

(drgnx-platform-test--deftest drgnx-monitors/a-hanging-wm-never-delays-the-restore ()
                              ;; The adapter never answers.  `drgnx-persist--restore-into' returns at once with the files and the
                              ;; layout in place; the placement gives up at the deadline and says so, once.
                              (drgnx-monitors-test--with-fake (:place-reply 'hang)
                                (drgnx-persist-test--with dir
                                  (drgnx-persist-test--graphical
                                    (let ((drgnx-platform-restore-timeout 0.3) (drgnx-platform-watchdog-margin 0.1))
                                      (switch-to-buffer (drgnx-persist-test--file dir "a.txt"))
                                      (drgnx-chrome-apply nil t)
                                      (drgnx-persist-save)
                                      (drgnx-persist-test--reset)
                                      (set-frame-parameter nil 'drgnx-persist-restored nil)
                                      (unwind-protect
                                          (let* ((before-layout nil) (start nil)
                                                 (drgnx-persist-after-restore-functions
                                                  (list (lambda (frame)             ; stands for a saved aux window: this one is not main
                                                          (set-frame-parameter frame 'drgnx-frame-role 'aux)
                                                          (set-frame-parameter frame 'drgnx-persist-extra
                                                                               (drgnx-monitors-test--extra drgnx-monitors-test--dell)))
                                                        #'drgnx-monitors--place-restored
                                                        (lambda (_) (setq before-layout (drgnx-persist-test--layout))))))
                                            (setq start (float-time))
                                            (drgnx-persist--restore-into (selected-frame))
                                            (should (< (- (float-time) start) 0.2))                ; did not wait
                                            (should (equal (car (car before-layout)) (list (list (expand-file-name "a.txt" dir)) (expand-file-name "a.txt" dir))))
                                            (should (equal (buffer-file-name (window-buffer (selected-window))) (expand-file-name "a.txt" dir)))
                                            (should (= 0 (length messages)))                       ; not given up yet
                                            (should (drgnx-platform-test--await (lambda () messages) 2))
                                            (should (< (- (float-time) start) 1.5))                ; gave up at the deadline
                                            (should (= 1 (length messages)))
                                            (should (string-match-p "timed out" (car messages))))
                                        (dolist (p '(drgnx-frame-role drgnx-persist-extra drgnx-persist-restored))
                                          (set-frame-parameter nil p nil))))))))

(drgnx-platform-test--deftest drgnx-monitors/a-window-closed-while-waiting-is-not-reported ()
                              (drgnx-monitors-test--with-fake (:delay 0.1 :monitors '((:name "DP-1" :geometry (0 0 1920 1080))))
                                (drgnx-monitors-test--with-fake-frames
                                  (let ((gone (drgnx-monitors-test--fake "gone" 'aux (drgnx-monitors-test--extra drgnx-monitors-test--dell))))
                                    (drgnx-monitors--place-restored (selected-frame))
                                    (setq drgnx-monitors-test--fakes (assq-delete-all gone drgnx-monitors-test--fakes))   ; closed meanwhile
                                    (drgnx-platform-test--await (lambda () (plist-get drgnx-monitors-test--calls :monitors)) 1)
                                    (drgnx-platform-test--await (lambda () nil) 0.3)
                                    (should-not messages)
                                    (should-not drgnx-monitors-test--places)))))

(drgnx-platform-test--deftest drgnx-monitors/a-monitor-listing-that-never-answers-gives-up-with-one-message ()
                              (drgnx-monitors-test--with-fake (:delay 30)
                                (let ((drgnx-platform-restore-timeout 0.3) (drgnx-platform-watchdog-margin 0.1))
                                  (drgnx-monitors-test--with-fake-frames
                                    (drgnx-monitors-test--fake "a" 'aux (drgnx-monitors-test--extra drgnx-monitors-test--dell))
                                    (drgnx-monitors--place-restored (selected-frame))
                                    (should (drgnx-platform-test--await (lambda () messages) 2))
                                    (should (= 1 (length messages)))
                                    (should (string-match-p "timed out" (car messages)))
                                    (should-not drgnx-monitors-test--places)))))

(drgnx-platform-test--deftest drgnx-monitors/the-state-is-nil-for-an-empty-identity ()
                              (drgnx-monitors-test--with-fake ()
                                (set-frame-parameter nil 'drgnx-monitor '(:number 1 :label "1"))
                                (should-not (drgnx-monitors--state))))

(provide 'wb-monitors-test)
;;; wb-monitors-test.el ends here
