;;; platform-kwin-test.el --- batch tests: the KWin adapter (scripting over D-Bus, stubbed) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'drgnx-paths)
(require 'drgnx-platform)

;; Every test runs under `drgnx-platform-test--deftest' (platform-test.el): no session, no bus.  Here D-Bus is a
;; stub inside that macro: `dbus-call-method-asynchronously' records the calls and plays KWin, the others record
;; what the adapter registers.  `dbus-call-method', `dbus-register-service' and `dbus-unregister-service' are
;; SYNCHRONOUS (they wait for the bus), so any call to one of them fails a test.

(unless (featurep 'platform-test)
  (load (expand-file-name "test/unit/platform-test.el" drgnx-dir) nil t))

(defun drgnx-platform-kwin-test--fixture (name)
  (with-temp-buffer
    (insert-file-contents (expand-file-name (concat "test/fixtures/wm/kwin/" name) drgnx-dir))
    (buffer-string)))

(defvar drgnx-platform-kwin-test--calls nil "The recorded D-Bus calls, oldest last: (SERVICE PATH METHOD ARGS).")
(defvar drgnx-platform-kwin-test--unregistered nil "Objects passed to `dbus-unregister-object'.")
(defvar drgnx-platform-kwin-test--registered nil "Objects returned by `dbus-register-method' that are still registered.")
(defvar drgnx-platform-kwin-test--script nil "The text of the script file when KWin was told to run it.")
(defvar drgnx-platform-kwin-test--script-file nil "The script file's name.")

(defmacro drgnx-platform-kwin-test--with-kwin (answer &rest body)
  "Run BODY with D-Bus stubbed.  KWin loads a script (id 7) and runs it; ANSWER (a function of the script text
or nil for \"never answers\") gives the JSON the script reports by calling `Reply'.  The temporary directory is
empty again afterwards (checked by the tests that care)."
  (declare (indent 1))
  `(let* ((drgnx-platform-kwin-test--calls nil) (drgnx-platform-kwin-test--unregistered nil)
          (drgnx-platform-kwin-test--registered nil) (drgnx-platform-kwin-test--script nil)
          (drgnx-platform-kwin-test--script-file nil)
          (tmp (make-temp-file "drgnx-kwin-test" t)) (temporary-file-directory (file-name-as-directory tmp))
          (answer ,answer) (handlers nil))
     (unwind-protect
         (cl-letf (((symbol-function 'drgnx-platform-kwin--dbus-p) (lambda () t))
                   ((symbol-function 'dbus-get-unique-name) (lambda (&rest _) ":1.99"))
                   ((symbol-function 'dbus-register-service) (lambda (&rest _) (error "synchronous dbus-register-service")))
                   ((symbol-function 'dbus-unregister-service) (lambda (&rest _) (error "synchronous dbus-unregister-service")))
                   ((symbol-function 'dbus-register-method)
                    (lambda (_bus service path interface method handler &optional dont-register)
                      (unless dont-register (error "dbus-register-method would register a service (synchronous)"))
                      (push (list service path interface method handler) handlers)
                      (let ((object (list (list :method :session interface method) (list service path handler))))
                        (push object drgnx-platform-kwin-test--registered)
                        object)))
                   ((symbol-function 'dbus-unregister-object)
                    (lambda (object)
                      (push object drgnx-platform-kwin-test--unregistered)
                      (setq drgnx-platform-kwin-test--registered (delq object drgnx-platform-kwin-test--registered))
                      t))
                   ((symbol-function 'dbus-call-method-asynchronously)
                    (lambda (bus service path interface method handler &rest args)
                      (should (eq bus :session))
                      (should (memq :timeout args))
                      (setq args (cl-loop for (a . rest) on args until (eq a :timeout) collect a))
                      (setq drgnx-platform-kwin-test--calls
                            (append drgnx-platform-kwin-test--calls (list (list service path method args))))
                      (should (equal service "org.kde.KWin"))
                      (cond
                       ((equal method "loadScript")
                        (setq drgnx-platform-kwin-test--script-file (car args)
                              drgnx-platform-kwin-test--script
                              (with-temp-buffer (insert-file-contents (car args)) (buffer-string)))
                        (when handler (run-at-time 0 nil handler 7)))
                       ((equal method "run")
                        (should (equal path "/Scripting/Script7"))
                        (when-let* ((json (and answer (funcall answer drgnx-platform-kwin-test--script))))
                          ;; the script calls back into Emacs at the registered object
                          (let ((h (car handlers)))
                            (run-at-time 0 nil (lambda () (funcall (nth 4 h) json)))))))
                      nil)))
           ,@body)
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
                                (should (= 1 (length drgnx-platform-kwin-test--unregistered)))
                                (should-not drgnx-platform-kwin-test--registered)
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
                                (should (= 1 (length drgnx-platform-kwin-test--unregistered)))
                                (should-not (file-exists-p drgnx-platform-kwin-test--script-file))))

(drgnx-platform-test--deftest drgnx-platform-kwin/two-calls-at-once-do-not-share-a-reply ()
                              (let (handlers (results nil))
                                (drgnx-platform-kwin-test--with-kwin nil
                                  (let ((ctx (drgnx-platform-ctx nil 2.0)))
                                    (drgnx-platform-kwin--monitors ctx (lambda (r) (push (cons 'a r) results)))
                                    (drgnx-platform-kwin--monitors ctx (lambda (r) (push (cons 'b r) results)))
                                    (should (drgnx-platform-test--await (lambda () (= 4 (length drgnx-platform-kwin-test--calls))) 3))
                                    (setq handlers (reverse drgnx-platform-kwin-test--registered))
                                    ;; each call has its own object path, so answering one leaves the other pending
                                    (should (= 2 (length handlers)))
                                    (should-not (equal (nth 1 (cadr (nth 0 handlers))) (nth 1 (cadr (nth 1 handlers)))))
                                    (funcall (nth 2 (cadr (nth 1 handlers))) "[]")
                                    (should (drgnx-platform-test--await (lambda () results) 2))
                                    (should (equal results '((b))))
                                    (funcall (nth 2 (cadr (nth 0 handlers))) "[]")
                                    (should (drgnx-platform-test--await (lambda () (= 2 (length results))) 2))
                                    (should-not drgnx-platform-kwin-test--registered)))))

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

(drgnx-platform-test--deftest drgnx-platform-kwin/the-adapter-is-declared-reported ()
                              (let ((spec (drgnx-platform-adapter 'kwin)))
                                (should (eq 'reported (plist-get spec :status)))
                                (should-not (plist-get spec :tool))
                                (should (functionp (plist-get spec :monitors)))
                                (should (functionp (plist-get spec :move)))
                                (should (functionp (plist-get spec :place)))
                                ;; detection survived the merge
                                (should (drgnx-platform-detect (drgnx-platform-test--env '(("WAYLAND_DISPLAY" . "w") ("XDG_CURRENT_DESKTOP" . "KDE"))) 'pgtk))))

(provide 'platform-kwin-test)
;;; platform-kwin-test.el ends here
