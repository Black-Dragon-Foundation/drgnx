;;; platform-kwin-test.el --- batch tests: the KWin adapter (scripting over D-Bus, stubbed) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'drgnx-paths)
(require 'drgnx-platform)

;; Every test runs under `drgnx-platform-test--deftest' (platform-test.el): no session, no bus.  Inside it the
;; real dbus.el runs, with its own registry (`dbus-registered-objects-table', a fresh table per test), so
;; `dbus-register-method' and `dbus-unregister-object' are the real ones.  Only what would reach a bus is stubbed:
;; `dbus-get-unique-name', `dbus-call-method-asynchronously' (records the calls and plays KWin) and
;; `dbus-call-method', which is SYNCHRONOUS (it waits for the bus): it only records that it was called, and every
;; test using the macro below fails when it was.  `dbus-register-service', `dbus-unregister-service' and
;; `dbus-list-names' end in it, so a change that makes the adapter register a service name fails the tests.

(unless (featurep 'platform-test)
  (load (expand-file-name "test/unit/platform-test.el" drgnx-dir) nil t))

(defun drgnx-platform-kwin-test--fixture (name)
  (with-temp-buffer
    (insert-file-contents (expand-file-name (concat "test/fixtures/wm/kwin/" name) drgnx-dir))
    (buffer-string)))

(defvar drgnx-platform-kwin-test--calls nil "The recorded D-Bus calls, oldest last: (SERVICE PATH METHOD ARGS SERIAL).")
(defvar drgnx-platform-kwin-test--sync-calls nil "Calls of the synchronous `dbus-call-method'.")
(defvar drgnx-platform-kwin-test--script nil "The text of the script file when KWin was told to run it.")
(defvar drgnx-platform-kwin-test--script-file nil "The script file's name.")
(defvar drgnx-platform-kwin-test--reply-return nil "What the last `Reply' handler returned.")
(defvar drgnx-platform-kwin-test--fail-load nil "Non-nil: KWin answers loadScript with a D-Bus error (an error event).")
(defvar drgnx-platform-kwin-test--held-load nil "Non-nil: loadScript's reply is held back; set to the handler.")

(defun drgnx-platform-kwin-test--entries ()
  "The `Reply' methods registered now: entries (nil SERVICE PATH HANDLER)."
  (gethash (list :method :session "org.drgnx.Wm" "Reply") dbus-registered-objects-table))

(defmacro drgnx-platform-kwin-test--with-kwin (answer &rest body)
  "Run BODY with D-Bus stubbed as described above.  KWin loads a script (id 7) and runs it; ANSWER (a function
of the script text, or nil for \"never answers\") gives the JSON the script reports by calling `Reply'.  The
temporary directory is private to the test."
  (declare (indent 1))
  `(let* ((drgnx-platform-kwin-test--calls nil) (drgnx-platform-kwin-test--sync-calls nil)
          (drgnx-platform-kwin-test--script nil) (drgnx-platform-kwin-test--script-file nil)
          (drgnx-platform-kwin-test--reply-return nil) (drgnx-platform-kwin-test--fail-load nil)
          (drgnx-platform-kwin-test--held-load nil)
          (dbus-registered-objects-table (make-hash-table :test 'equal))
          (dbus-event-error-functions nil)
          (tmp (make-temp-file "drgnx-kwin-test" t)) (temporary-file-directory (file-name-as-directory tmp))
          (answer ,answer) (serial 0))
     (unwind-protect
         (cl-letf (((symbol-function 'drgnx-platform-kwin--dbus-p) (lambda () t))
                   ((symbol-function 'dbus-get-unique-name) (lambda (&rest _) ":1.99"))
                   ((symbol-function 'dbus-call-method)
                    (lambda (&rest args) (push args drgnx-platform-kwin-test--sync-calls) (error "synchronous dbus-call-method")))
                   ((symbol-function 'dbus-call-method-asynchronously)
                    (lambda (bus service path interface method handler &rest args)
                      (should (eq bus :session))
                      ;; dbus.el takes `:timeout' only right after the handler: anywhere else it is marshalled as a
                      ;; method argument and the call fails ("Wrong type argument: D-Bus, :timeout", seen on KWin)
                      (should (eq (car args) :timeout))
                      (should (natnump (cadr args)))
                      (setq args (cddr args))
                      (setq serial (1+ serial))
                      (setq drgnx-platform-kwin-test--calls
                            (append drgnx-platform-kwin-test--calls (list (list service path method args serial))))
                      (should (equal service "org.kde.KWin"))
                      (let ((this serial))
                        (cond
                         ((equal method "loadScript")
                          (setq drgnx-platform-kwin-test--script-file (car args)
                                drgnx-platform-kwin-test--script
                                (with-temp-buffer (insert-file-contents (car args)) (buffer-string)))
                          (cond (drgnx-platform-kwin-test--fail-load
                                 ;; dbus.el hands an error reply to `dbus-event-error-functions', not to the handler
                                 (run-at-time 0 nil #'run-hook-with-args 'dbus-event-error-functions
                                              (list 'dbus-event :session 3 this "org.freedesktop.DBus" ":1.99" "/"
                                                    "org.freedesktop.DBus" "org.freedesktop.DBus.Error.ServiceUnknown" nil)
                                              '(dbus-error "org.freedesktop.DBus.Error.ServiceUnknown"
                                                           "The name org.kde.KWin was not provided")))
                                (drgnx-platform-kwin-test--held-load
                                 (setq drgnx-platform-kwin-test--held-load handler))
                                (handler (run-at-time 0 nil handler 7))))
                         ((equal method "run")
                          (should (equal path "/Scripting/Script7"))
                          (when-let* ((json (and answer (funcall answer drgnx-platform-kwin-test--script))))
                            ;; the script calls back into Emacs at the registered object
                            (run-at-time 0 nil
                                         (lambda ()
                                           (setq drgnx-platform-kwin-test--reply-return
                                                 (funcall (nth 3 (car (drgnx-platform-kwin-test--entries))) json))))))))
                      (list :serial bus serial))))
           (prog1 (progn ,@body)
             (should-not drgnx-platform-kwin-test--sync-calls)))
       (delete-directory tmp t))))

(defun drgnx-platform-kwin-test--methods ()
  (mapcar #'caddr drgnx-platform-kwin-test--calls))

(defun drgnx-platform-kwin-test--ask (fn)
  "Call FN with a callback; wait for it; return the single result (failing when it is called twice or never)."
  (let ((results nil))
    (funcall fn (lambda (r) (push r results)))
    (should (drgnx-platform-test--await (lambda () results) 5))
    (accept-process-output nil 0.2)
    (should (= 1 (length results)))
    (car results)))


;;;; The script text (pure)

(drgnx-platform-test--deftest drgnx-platform-kwin/scripts-are-pure-text ()
                              (let ((args (list :service ":1.5" :path "/org/drgnx/Wm1" :pid 4242 :caption "a \"quoted\" title"
                                                :screen "Virtual-1" :geometry '(1280 0 1280 800))))
                                (dolist (kind '(screens windows move))
                                  (let ((s (drgnx-platform-kwin--script kind args)))
                                    (should (stringp s))
                                    (should (string-match-p "callDBus" s))
                                    (should (string-match-p (regexp-quote "\":1.5\"") s))
                                    (should (string-match-p (regexp-quote "\"/org/drgnx/Wm1\"") s))))
                                (should (string-match-p "workspace\\.screens" (drgnx-platform-kwin--script 'screens args)))
                                (should (string-match-p "windowList" (drgnx-platform-kwin--script 'windows args)))
                                ;; the quotes of a caption cannot end the JavaScript string
                                (should (string-match-p (regexp-quote "\"a \\\"quoted\\\" title\"") (drgnx-platform-kwin--script 'move args)))
                                (should-error (drgnx-platform-kwin--script 'bogus args))))

;;;; Screens become monitors

(drgnx-platform-test--deftest drgnx-platform-kwin/screens-become-monitors ()
                              (drgnx-platform-kwin-test--with-kwin
                                  (lambda (_script) (drgnx-platform-kwin-test--fixture "kwin-screens.json"))
                                (let ((r (drgnx-platform-kwin-test--ask
                                          (lambda (cb) (drgnx-platform-kwin--monitors (drgnx-platform-ctx nil 2.0) cb)))))
                                  (should (= 2 (length r)))
                                  (should (equal (plist-get (nth 0 r) :name) "Virtual-0"))
                                  (should (equal (plist-get (nth 0 r) :geometry) '(0 0 1280 800)))
                                  (should (equal (plist-get (nth 1 r) :name) "Virtual-1"))
                                  (should (equal (plist-get (nth 1 r) :geometry) '(1280 0 1280 800)))
                                  (should (equal (plist-get (nth 1 r) :make) ""))
                                  ;; the script that ran is the screens script, sent to Emacs' own bus name at a path of this call
                                  (should (string-match-p "workspace\\.screens" drgnx-platform-kwin-test--script))
                                  (should (string-match-p (regexp-quote "\":1.99\"") drgnx-platform-kwin-test--script))
                                  (should (equal (drgnx-platform-kwin-test--methods) '("loadScript" "run" "unloadScript"))))))

(drgnx-platform-test--deftest drgnx-platform-kwin/the-public-monitors-are-numbered ()
                              (drgnx-platform-kwin-test--with-kwin
                                  (lambda (_script) (drgnx-platform-kwin-test--fixture "kwin-screens.json"))
                                (cl-letf (((symbol-function 'drgnx-platform-wm) (lambda (&rest _) 'kwin)))
                                  (let ((r (drgnx-platform-kwin-test--ask (lambda (cb) (drgnx-platform-monitors nil cb)))))
                                    (should (equal (mapcar (lambda (m) (plist-get m :number)) r) '(1 2)))
                                    (should (equal (plist-get (nth 1 r) :label) "2 — Virtual-1, 1280×800, right of 1"))))))

;;;; The command moves only Emacs' active window

(drgnx-platform-test--deftest drgnx-platform-kwin/the-command-moves-only-emacs-active-window ()
                              (let ((monitor (list :name "Virtual-1" :geometry '(1280 0 1280 800))))
                                ;; Emacs' window is the active one: the script names Emacs' pid, the active window and sendClientToScreen
                                (drgnx-platform-kwin-test--with-kwin (lambda (_s) "{\"ok\":true}")
                                  (let ((r (drgnx-platform-kwin-test--ask
                                            (lambda (cb) (drgnx-platform-kwin--move (drgnx-platform-ctx nil 2.0) monitor cb)))))
                                    (should (eq r 'ok))
                                    (should (string-match-p (format "\\b%d\\b" (emacs-pid)) drgnx-platform-kwin-test--script))
                                    (should (string-match-p "activeWindow" drgnx-platform-kwin-test--script))
                                    (should (string-match-p "sendClientToScreen" drgnx-platform-kwin-test--script))
                                    (should (string-match-p (regexp-quote "\"Virtual-1\"") drgnx-platform-kwin-test--script))
                                    ;; it does not look windows up by caption
                                    (should-not (string-match-p "caption ===" drgnx-platform-kwin-test--script))))
                                ;; another application is active: KWin's script says so, and the answer is (:error ...)
                                (drgnx-platform-kwin-test--with-kwin
                                    (lambda (_s) "{\"error\":\"the active window is not this Emacs\"}")
                                  (let ((r (drgnx-platform-kwin-test--ask
                                            (lambda (cb) (drgnx-platform-kwin--move (drgnx-platform-ctx nil 2.0) monitor cb)))))
                                    (should (equal r '(:error "the active window is not this Emacs")))))))

(drgnx-platform-test--deftest drgnx-platform-kwin/the-public-move-reports-ok-or-an-error ()
                              (cl-letf (((symbol-function 'drgnx-platform-wm) (lambda (&rest _) 'kwin)))
                                (let ((monitor (list :name "Virtual-1" :geometry '(1280 0 1280 800))))
                                  (drgnx-platform-kwin-test--with-kwin (lambda (_s) "{\"ok\":true}")
                                    (should (eq 'ok (drgnx-platform-kwin-test--ask
                                                     (lambda (cb) (drgnx-platform-move-frame nil monitor cb))))))
                                  (drgnx-platform-kwin-test--with-kwin (lambda (_s) "not json")
                                    (let ((r (drgnx-platform-kwin-test--ask (lambda (cb) (drgnx-platform-move-frame nil monitor cb)))))
                                      (should (eq :error (car r))))))))

;;;; Restore: pid and caption

(drgnx-platform-test--deftest drgnx-platform-kwin/place-finds-the-window-by-pid-and-caption ()
                              (let ((monitor (list :name "Virtual-1" :geometry '(1280 0 1280 800))))
                                (drgnx-platform-kwin-test--with-kwin (lambda (_s) "{\"ok\":true}")
                                  (cl-letf (((symbol-function 'frame-parameter)
                                             (lambda (_f p) (and (eq p 'name) "drgnx - workbench"))))
                                    (let ((r (drgnx-platform-kwin-test--ask
                                              (lambda (cb) (drgnx-platform-kwin--place (drgnx-platform-ctx nil 5.0) monitor cb)))))
                                      (should (eq r 'ok))))
                                  (should (string-match-p (format "\\b%d\\b" (emacs-pid)) drgnx-platform-kwin-test--script))
                                  (should (string-match-p (regexp-quote "\"drgnx - workbench\"") drgnx-platform-kwin-test--script))
                                  (should (string-match-p "windowList" drgnx-platform-kwin-test--script))
                                  (should (string-match-p "sendClientToScreen" drgnx-platform-kwin-test--script))
                                  (should-not (string-match-p "activeWindow" drgnx-platform-kwin-test--script)))))

(drgnx-platform-test--deftest drgnx-platform-kwin/the-move-script-selects-by-pid-then-caption ()
                              ;; The search in the script is plain JavaScript; run the same selection in Lisp over the recorded windows to
                              ;; pin down what it must do: two Emacs processes, told apart by pid; the caption picks among one's windows.
                              (let* ((windows (json-parse-string (drgnx-platform-kwin-test--fixture "kwin-windows.json")
                                                                 :object-type 'plist :array-type 'list))
                                     (pick (lambda (pid caption)
                                             (let ((mine (seq-filter (lambda (w) (and (equal (plist-get w :pid) pid) (plist-get w :normalWindow)))
                                                                     windows)))
                                               (or (seq-find (lambda (w) (equal (plist-get w :caption) caption)) mine)
                                                   (and (= 1 (length mine)) (car mine)))))))
                                (should (equal (plist-get (funcall pick 296 "drgnx - workbench") :internalId) "{764ae6db-39c8-4d78-9829-1f70289ad521}"))
                                (should (equal (plist-get (funcall pick 296 "renamed since") :pid) 296))
                                (should-not (funcall pick 1 "drgnx - workbench"))
                                ;; and the generated script has that shape (selection by pid, then caption, then the only one of that pid)
                                (let ((s (drgnx-platform-kwin--script 'move (list :service ":1.5" :path "/p" :pid 296 :caption "x"
                                                                                  :screen "Virtual-0" :geometry '(0 0 1280 800)))))
                                  (should (string-match-p "pid === 296" s))
                                  (should (string-match-p "caption ===" s))
                                  (should (string-match-p "length === 1" s)))))

;;;; Cleanup

(drgnx-platform-test--deftest drgnx-platform-kwin/everything-is-cleaned-up-after-a-deadline ()
                              (drgnx-platform-kwin-test--with-kwin nil       ; KWin runs the script, which never reports
                                (let ((r (drgnx-platform-kwin-test--ask
                                          (lambda (cb) (drgnx-platform-kwin--monitors (drgnx-platform-ctx nil 0.3) cb)))))
                                  (should (eq :error (car r)))
                                  (should (string-match-p "did not answer" (cadr r))))
                                ;; the script is unloaded (by the name it was loaded with), the object unregistered, the file deleted
                                (should (equal (drgnx-platform-kwin-test--methods) '("loadScript" "run" "unloadScript")))
                                (should (equal (nth 3 (nth 2 drgnx-platform-kwin-test--calls))
                                               (list (nth 1 (nth 3 (nth 0 drgnx-platform-kwin-test--calls))))))
                                (should-not (drgnx-platform-kwin-test--entries))
                                (should-not dbus-event-error-functions)
                                (should drgnx-platform-kwin-test--script-file)
                                (should-not (file-exists-p drgnx-platform-kwin-test--script-file))
                                (should-not (directory-files temporary-file-directory nil directory-files-no-dot-files-regexp))
                                ;; a reply arriving after the deadline changes nothing (and does not signal)
                                (accept-process-output nil 0.1)))

(drgnx-platform-test--deftest drgnx-platform-kwin/a-reply-cleans-up-too ()
                              (drgnx-platform-kwin-test--with-kwin (lambda (_s) "[]")
                                (should (null (drgnx-platform-kwin-test--ask
                                               (lambda (cb) (drgnx-platform-kwin--monitors (drgnx-platform-ctx nil 2.0) cb)))))
                                (should (equal (drgnx-platform-kwin-test--methods) '("loadScript" "run" "unloadScript")))
                                (should-not (drgnx-platform-kwin-test--entries))
                                (should-not dbus-event-error-functions)
                                ;; the reply method answers :ignore (an empty reply), not a value
                                (should (eq :ignore drgnx-platform-kwin-test--reply-return))
                                (should-not (file-exists-p drgnx-platform-kwin-test--script-file))))

(drgnx-platform-test--deftest drgnx-platform-kwin/two-calls-at-once-do-not-share-a-reply ()
                              (let (handlers (results nil))
                                (drgnx-platform-kwin-test--with-kwin nil
                                  (let ((ctx (drgnx-platform-ctx nil 2.0)))
                                    (drgnx-platform-kwin--monitors ctx (lambda (r) (push (cons 'a r) results)))
                                    (drgnx-platform-kwin--monitors ctx (lambda (r) (push (cons 'b r) results)))
                                    (should (drgnx-platform-test--await (lambda () (= 4 (length drgnx-platform-kwin-test--calls))) 3))
                                    (setq handlers (reverse (drgnx-platform-kwin-test--entries)))
                                    ;; each call has its own object path, so answering one leaves the other pending
                                    (should (= 2 (length handlers)))
                                    (should-not (equal (nth 2 (nth 0 handlers)) (nth 2 (nth 1 handlers))))
                                    (funcall (nth 3 (nth 1 handlers)) "[]")
                                    (should (drgnx-platform-test--await (lambda () results) 2))
                                    (should (equal results '((b))))
                                    (funcall (nth 3 (nth 0 handlers)) "[]")
                                    (should (drgnx-platform-test--await (lambda () (= 2 (length results))) 2))
                                    (should-not (drgnx-platform-kwin-test--entries))))))

;; A D-Bus error reply (KWin is not running) does not reach an asynchronous call's handler; dbus.el runs
;; `dbus-event-error-functions' with an event whose serial is the call's.
(drgnx-platform-test--deftest drgnx-platform-kwin/a-dbus-error-reply-is-reported-at-once ()
                              (drgnx-platform-kwin-test--with-kwin nil
                                (setq drgnx-platform-kwin-test--fail-load t)
                                (let* ((start (float-time))
                                       (r (drgnx-platform-kwin-test--ask
                                           (lambda (cb) (drgnx-platform-kwin--monitors (drgnx-platform-ctx nil 5.0) cb)))))
                                  (should (< (- (float-time) start) 2))
                                  (should (equal r '(:error "KWin: org.freedesktop.DBus.Error.ServiceUnknown: The name org.kde.KWin was not provided")))
                                  ;; cleaned up as after any end
                                  (should (equal (drgnx-platform-kwin-test--methods) '("loadScript" "unloadScript")))
                                  (should-not (drgnx-platform-kwin-test--entries))
                                  (should-not dbus-event-error-functions)
                                  (should-not (file-exists-p drgnx-platform-kwin-test--script-file)))))

(drgnx-platform-test--deftest drgnx-platform-kwin/an-error-for-another-call-is-not-ours ()
                              (drgnx-platform-kwin-test--with-kwin nil
                                (let ((results nil))
                                  (drgnx-platform-kwin--monitors (drgnx-platform-ctx nil 0.4) (lambda (r) (push r results)))
                                  (should (drgnx-platform-test--await (lambda () (= 2 (length drgnx-platform-kwin-test--calls))) 3))
                                  (should (= 1 (length dbus-event-error-functions)))
                                  ;; another serial, another bus: ignored
                                  (run-hook-with-args 'dbus-event-error-functions (list 'dbus-event :session 3 99 "x" "y" "/" "i" "m" nil) '(dbus-error "n" "m"))
                                  (run-hook-with-args 'dbus-event-error-functions (list 'dbus-event :system 3 1 "x" "y" "/" "i" "m" nil) '(dbus-error "n" "m"))
                                  (should-not results)
                                  (should (drgnx-platform-test--await (lambda () results) 3))
                                  (should (string-match-p "did not answer" (cadr (car results)))))))

(drgnx-platform-test--deftest drgnx-platform-kwin/nothing-runs-after-a-deadline ()
                              (drgnx-platform-kwin-test--with-kwin (lambda (_s) "[]")
                                (setq drgnx-platform-kwin-test--held-load t)    ; loadScript's reply comes late
                                (let ((r (drgnx-platform-kwin-test--ask
                                          (lambda (cb) (drgnx-platform-kwin--monitors (drgnx-platform-ctx nil 0.3) cb)))))
                                  (should (eq :error (car r))))
                                (should (functionp drgnx-platform-kwin-test--held-load))
                                (funcall drgnx-platform-kwin-test--held-load 7)  ; the late reply
                                (accept-process-output nil 0.1)
                                ;; no `run' was sent for a script the call has given up on
                                (should (equal (drgnx-platform-kwin-test--methods) '("loadScript" "unloadScript")))))

;;;; Strings in the script

(drgnx-platform-test--deftest drgnx-platform-kwin/line-separators-are-escaped-in-the-script ()
                              (let* ((args (list :service ":1.5" :path "/p" :pid 1 :screen "S" :geometry '(0 0 1 1)
                                                 :caption (concat "a" (string #x2028) "b" (string #x2029) "c")))
                                     (s (drgnx-platform-kwin--script 'move args)))
                                (should-not (string-match-p (string #x2028) s))
                                (should-not (string-match-p (string #x2029) s))
                                (should (string-match-p (regexp-quote "\"a\\u2028b\\u2029c\"") s))))

;;;; No D-Bus

(drgnx-platform-test--deftest drgnx-platform-kwin/no-dbus-explains ()
                              (cl-letf (((symbol-function 'drgnx-platform-kwin--dbus-p) (lambda () nil)))
                                (should (equal (drgnx-platform-kwin--can-move (drgnx-platform-ctx nil))
                                               '("this Emacs has no D-Bus support"
                                                 . "use an Emacs built with D-Bus (the installer's builds have it)")))
                                ;; through the public function, with the adapter selected
                                (cl-letf (((symbol-function 'drgnx-platform-wm) (lambda (&rest _) 'kwin)))
                                  (should (equal (car (drgnx-platform-can-move nil)) "this Emacs has no D-Bus support"))
                                  (let ((r (drgnx-platform-kwin-test--ask (lambda (cb) (drgnx-platform-move-frame nil '(:name "x") cb)))))
                                    (should (eq :error (car r)))
                                    (should (string-match-p "no D-Bus support" (cadr r)))))))

(drgnx-platform-test--deftest drgnx-platform-kwin/no-session-bus-explains ()
                              (cl-letf (((symbol-function 'drgnx-platform-kwin--dbus-p) (lambda () t))
                                        ((symbol-function 'dbus-get-unique-name) (lambda (&rest _) (signal 'dbus-error '("No connection to bus" :session)))))
                                (let ((can (drgnx-platform-kwin--can-move (drgnx-platform-ctx nil))))
                                  (should (consp can))
                                  (should (string-match-p "session bus" (car can))))))

(drgnx-platform-test--deftest drgnx-platform-kwin/it-can-move-when-dbus-answers ()
                              (cl-letf (((symbol-function 'drgnx-platform-kwin--dbus-p) (lambda () t))
                                        ((symbol-function 'dbus-get-unique-name) (lambda (&rest _) ":1.99")))
                                (should (eq t (drgnx-platform-kwin--can-move (drgnx-platform-ctx nil))))))

(drgnx-platform-test--deftest drgnx-platform-kwin/the-adapter-is-declared-verified ()
                              (let ((spec (drgnx-platform-adapter 'kwin)))
                                ;; run headless in the window managers' container tier (test/live/drgnx-wm-other-test.el)
                                (should (eq 'verified (plist-get spec :status)))
                                (should (eq (plist-get spec :frame-monitor) #'drgnx-platform--emacs-frame-monitor))
                                (should-not (plist-get spec :tool))
                                (should (functionp (plist-get spec :monitors)))
                                (should (functionp (plist-get spec :move)))
                                (should (functionp (plist-get spec :place)))
                                ;; detection survived the merge
                                (should (drgnx-platform-detect (drgnx-platform-test--env '(("WAYLAND_DISPLAY" . "w") ("XDG_CURRENT_DESKTOP" . "KDE"))) 'pgtk))))

(drgnx-platform-test--deftest drgnx-platform-kwin/it-says-which-monitor-from-emacs-own-geometry ()
                              ;; Next and Previous need the monitor the window is on: Emacs' own answer, no script
                              (drgnx-platform-test--with-frame 'pgtk '("XDG_CURRENT_DESKTOP=KDE" "WAYLAND_DISPLAY=w")
                                (cl-letf (((symbol-function 'frame-monitor-attributes)
                                           (lambda (&optional _) '((name . "") (geometry 1280 0 1280 800) (workarea 1280 0 1280 800))))
                                          ((symbol-function 'dbus-call-method-asynchronously)
                                           (lambda (&rest _) (error "no D-Bus call expected"))))
                                  (let (fm)
                                    (should (eq 'kwin (drgnx-platform-wm frame)))
                                    (drgnx-platform-frame-monitor frame (lambda (m) (setq fm (or m 'none))))
                                    (should (drgnx-platform-test--await (lambda () fm)))
                                    (should (equal (plist-get fm :geometry) '(1280 0 1280 800)))))))

(provide 'platform-kwin-test)
;;; platform-kwin-test.el ends here
