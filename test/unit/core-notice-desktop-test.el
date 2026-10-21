;;; core-notice-desktop-test.el --- batch tests: desktop notifications for what waits on you (backends stubbed) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-notice-desktop)
(when (featurep 'dbusbind) (require 'notifications nil t)) ; before any stub of D-Bus: loading it later undoes one
(load (expand-file-name "test/fixtures/notice-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)

(defmacro drgnx-notice-desktop-test--with (&rest body)
  "BODY on a fresh notice model and virtual time, the desktop route on, a backend there, no frame with focus; the
sends are recorded in `sent' as (TITLE . BODY), oldest first, instead of made."
  (declare (indent 0) (debug t))
  `(drgnx-notice-test-with-model
     (drgnx-test-with-clock ()
       (let ((sent nil) (drgnx-notice-desktop t) (drgnx-notice-desktop--backend 'dbus)
             (drgnx-notice-desktop--seen (make-hash-table :test #'equal)) (drgnx-notice-desktop--queue nil))
         (cl-letf (((symbol-function 'drgnx-notice-desktop-send)
                    (lambda (title body) (setq sent (append sent (list (cons title body))))))
                   ((symbol-function 'frame-focus-state) #'ignore))
           (unwind-protect (progn (drgnx-notice-desktop-mode 1) ,@body)
             (drgnx-notice-desktop-mode -1)))))))

(defun drgnx-notice-desktop-test--item (id)
  "The attention item ID as the model holds it."
  (seq-find (lambda (n) (equal (plist-get n :id) id)) (drgnx-needs-you-items)))

;;;; Taking an item

(ert-deftest drgnx-notice-desktop/a-new-item-is-sent-once ()
  (drgnx-notice-desktop-test--with
    (drgnx-notice-set 'agents (list (list :id '(permission "s1" . 1) :text "s1 asks: run make?")))
    (let ((item (drgnx-notice-desktop-test--item '(permission "s1" . 1))))
      (should (drgnx-notice-desktop-take item))
      (should-not (drgnx-notice-desktop-take item))  ; seen
      (drgnx-test-advance 0)
      (should (equal sent '(("drgnx: agents" . "s1 asks: run make?"))))
      (should-not (drgnx-notice-desktop-take item))
      (drgnx-test-advance 0)
      (should (= 1 (length sent))))))

(ert-deftest drgnx-notice-desktop/seen-is-pruned-to-the-union ()
  (drgnx-notice-desktop-test--with
    (drgnx-notice-set 'agents (list (list :id 'a :text "a?") (list :id 'b :text "b?")))
    (drgnx-notice-set 'hub (list (list :id 'b :text "b?")))
    (should (drgnx-notice-desktop-take (drgnx-notice-desktop-test--item 'a)))
    (should (drgnx-notice-desktop-take (drgnx-notice-desktop-test--item 'b)))
    (drgnx-notice-set 'agents nil)                      ; a leaves the union; b is still held by hub
    (should-not (gethash 'a drgnx-notice-desktop--seen))
    (should (gethash 'b drgnx-notice-desktop--seen))
    (should-not (drgnx-notice-desktop-take (drgnx-notice-desktop-test--item 'b)))
    (drgnx-notice-set 'agents (list (list :id 'a :text "a?")))   ; a comes back: it notifies again
    (should (drgnx-notice-desktop-take (drgnx-notice-desktop-test--item 'a)))
    (drgnx-notice-set 'hub :unknown)                    ; :unknown drops b too
    (should-not (gethash 'b drgnx-notice-desktop--seen))
    (drgnx-test-advance 0)
    (should (equal (mapcar #'cdr sent) '("a?" "b?" "a?")))))

(ert-deftest drgnx-notice-desktop/nothing-while-a-drgnx-frame-has-focus ()
  (drgnx-notice-desktop-test--with
    (drgnx-notice-set 'agents (list (list :id 'a :text "a?")))
    (let ((item (drgnx-notice-desktop-test--item 'a)))
      ;; only t is focus: nil and `unknown' are not
      (cl-letf (((symbol-function 'frame-focus-state) (lambda (&optional _f) 'unknown)))
        (should (drgnx-notice-desktop-take item)))
      (clrhash drgnx-notice-desktop--seen)
      (cl-letf (((symbol-function 'frame-focus-state) (lambda (&optional _f) t)))
        (should-not (drgnx-notice-desktop-take item))
        (should-not (gethash 'a drgnx-notice-desktop--seen))   ; not marked: it notifies once focus goes
        ;; the daemon's initial frame is not a drgnx window
        (cl-letf (((symbol-function 'drgnx-state-frame-kind) (lambda (_f) 'initial)))
          (should (drgnx-notice-desktop-take item))))
      (drgnx-test-advance 0)
      (should (= 2 (length sent))))))

(ert-deftest drgnx-notice-desktop/echo-nil-suppresses-it ()
  (drgnx-notice-desktop-test--with
    (drgnx-notice-set 'agents (list (list :id 'quiet :text "overlap" :echo nil) (list :id 'loud :text "go?" :echo t)))
    (should-not (drgnx-notice-desktop-take (drgnx-notice-desktop-test--item 'quiet)))
    (should (drgnx-notice-desktop-take (drgnx-notice-desktop-test--item 'loud)))
    (drgnx-test-advance 0)
    (should (equal (mapcar #'cdr sent) '("go?")))))

(ert-deftest drgnx-notice-desktop/the-off-switch ()
  (drgnx-notice-desktop-test--with
    (drgnx-notice-set 'agents (list (list :id 'a :text "a?")))
    (let ((item (drgnx-notice-desktop-test--item 'a)))
      (let ((drgnx-notice-desktop nil)) (should-not (drgnx-notice-desktop-take item)))
      (drgnx-notice-desktop-mode -1)
      (should-not (memq #'drgnx-notice-desktop--prune drgnx-notice-functions))
      (should-not (drgnx-notice-desktop-take item))
      (let ((drgnx-notice-desktop--backend nil))        ; no backend: echo says it instead
        (drgnx-notice-desktop-mode 1)
        (should (memq #'drgnx-notice-desktop--prune drgnx-notice-functions))
        (should-not (drgnx-notice-desktop-take item)))
      (should-not sent))))

(ert-deftest drgnx-notice-desktop/sent-off-the-callback ()
  (drgnx-notice-desktop-test--with
    ;; as the echo route will: take each added item inside the now lane
    (let ((taken nil) (sent-in-hook :unset))
      (add-hook 'drgnx-notice-functions
                (lambda (change)
                  (dolist (id (plist-get change :added))
                    (push (drgnx-notice-desktop-take (drgnx-notice-desktop-test--item id)) taken))
                  (setq sent-in-hook (length sent)))
                t)
      (drgnx-notice-set 'agents (list (list :id 'a :text "a?") (list :id 'b :text "b?")))
      (should (equal taken '(t t)))
      (should (eql sent-in-hook 0))
      (should-not sent)                                 ; not inside the set either
      (should (drgnx-timer-active-p 'notice-desktop))
      (drgnx-test-advance 0)
      (should (equal (mapcar #'cdr sent) '("a?" "b?"))))))

(ert-deftest drgnx-notice-desktop/a-failed-send-does-not-stop-the-rest ()
  (drgnx-notice-desktop-test--with
    (drgnx-notice-set 'agents (list (list :id 'a :text "a?") (list :id 'b :text "b?")))
    (should (drgnx-notice-desktop-take (drgnx-notice-desktop-test--item 'a)))
    (should (drgnx-notice-desktop-take (drgnx-notice-desktop-test--item 'b)))
    (let ((said nil))
      (cl-letf (((symbol-function 'drgnx-notice-desktop-send)
                 (lambda (title body) (if (equal body "a?") (error "No bus") (push (cons title body) sent))))
                ((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) said))))
        (drgnx-test-advance 0))
      (should (equal (mapcar #'cdr sent) '("b?")))
      (should (= 1 (length said)))
      (should (string-search "No bus" (car said))))))

;;;; The backends (moved from job-ui-test.el)

;; M9b4-14: the notification goes where the platform has one.
(ert-deftest drgnx-notice-desktop/the-macos-script-takes-the-text-as-arguments ()
  (let ((made nil) (said nil) (drgnx-notice-desktop--backend :unknown) (system-type 'darwin))
    (cl-letf (((symbol-function 'make-process) (lambda (&rest args) (push args made) 'proc))
              ((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) said)))
              ((symbol-function 'executable-find) (lambda (c &rest _) (and (equal c "osascript") "/usr/bin/osascript"))))
      ;; a fixed script (`on run argv'), the text only as argv items after "--": nothing of it is ever script
      (drgnx-notice-desktop-send "say \"hi\" \\ \" & (do shell script \"touch x\") & \"" "j1 — body\nnext -e")
      (should (= 1 (length made)))
      (should (equal (plist-get (car made) :command)
                     '("osascript" "-e" "on run argv"
                       "-e" "display notification (item 1 of argv) with title (item 2 of argv)"
                       "-e" "end run" "--"
                       "j1 — body next -e" "say \"hi\" \\ \" & (do shell script \"touch x\") & \"")))
      (should-not said))))

(ert-deftest drgnx-notice-desktop/dbus-when-available-else-a-message ()
  (let ((made nil) (said nil) (drgnx-notice-desktop--backend :unknown))
    (cl-letf (((symbol-function 'make-process) (lambda (&rest args) (push args made) 'proc))
              ((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) said)))
              ((symbol-function 'executable-find) #'ignore)
              ((symbol-function 'dbus-call-method) (lambda (&rest _) (push 'dbus-sync made)))
              ((symbol-function 'dbus-call-method-asynchronously) (lambda (&rest args) (push args made))))
      ;; macOS without osascript, Linux without a session bus, Windows: the message
      (let ((system-type 'darwin)) (drgnx-notice-desktop-send "t" "b"))
      (setq drgnx-notice-desktop--backend :unknown)
      (let ((system-type 'gnu/linux) (process-environment (cons "DBUS_SESSION_BUS_ADDRESS" process-environment)))
        (drgnx-notice-desktop-send "t" "b"))
      (setq drgnx-notice-desktop--backend :unknown)
      (let ((system-type 'windows-nt)) (drgnx-notice-desktop-send "t" "b"))
      (should-not made)
      (should (equal said '("t — b" "t — b" "t — b")))
      ;; Linux with D-Bus: the Notify method, asynchronously, no reply awaited (a hung notification server cannot
      ;; hold Emacs)
      (when (featurep 'notifications)
        (setq drgnx-notice-desktop--backend :unknown)
        (let ((system-type 'gnu/linux)
              (process-environment (cons "DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/x" process-environment)))
          (should (eq (drgnx-notice-desktop--available-p) 'dbus))
          (drgnx-notice-desktop-send "drgnx: agents" "s1 asks"))
        (should (= 1 (length made)))
        (let ((args (car made)))
          (should (equal (seq-take args 6) '(:session "org.freedesktop.Notifications" "/org/freedesktop/Notifications"
                                                      "org.freedesktop.Notifications" "Notify" nil)))
          (should (member "drgnx: agents" args))
          (should (member "s1 asks" args)))
        (should (= 3 (length said)))))))

;; a failed osascript says so once and is not tried again
(ert-deftest drgnx-notice-desktop/a-failed-osascript-says-so-once ()
  (let ((made nil) (said nil) (sentinel nil) (drgnx-notice-desktop--backend :unknown) (system-type 'darwin))
    (cl-letf (((symbol-function 'make-process) (lambda (&rest args) (push args made) (setq sentinel (plist-get args :sentinel)) 'proc))
              ((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) said)))
              ((symbol-function 'drgnx-notify) (lambda (_s _v text &rest _) (push text said) nil))   ; a notice, Task 20
              ((symbol-function 'executable-find) (lambda (&rest _) "/usr/bin/osascript"))
              ((symbol-function 'process-status) (lambda (_p) 'exit))
              ((symbol-function 'process-exit-status) (lambda (_p) 1)))
      (drgnx-notice-desktop-send "t" "b")
      (should (functionp sentinel))
      (funcall sentinel 'proc "exited abnormally with code 1\n")
      (should (= 1 (length said)))
      (should (string-search "b" (car said)))
      (should (= 1 (length made))))                         ; no second try
    (setq said nil)
    (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) said)))
              ((symbol-function 'process-status) (lambda (_p) 'exit))
              ((symbol-function 'process-exit-status) (lambda (_p) 0)))
      (funcall sentinel 'proc "finished\n")
      (should-not said))))

(provide 'core-notice-desktop-test)
;;; core-notice-desktop-test.el ends here
