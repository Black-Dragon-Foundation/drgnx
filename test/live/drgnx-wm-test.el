;;; drgnx-wm-test.el --- live: move and restore across monitors under sway, X11 and i3; mutter explains -*- lexical-binding: t -*-
;; Each test runs only in its compositor's tier (`bin/drgnx test --ui --compositor sway|x11|i3', or in the GUI
;; container: `bin/drgnx test --container --ui --compositor C'; the default tier is mutter); elsewhere it is skipped.
;; Every session has two monitors of 1280x800 (one in the missing-monitor test), config `drgnx', a temp state root.
;; The sessions are daemons: `emacsclient -c' opens the main window, as a user does.
(require 'ert)
(require 'seq)
(require 'subr-x)
(require 'drgnx-ui)

;;;; Helpers

(defun drgnx-wm-move--eval (sess form)
  "FORM's value (any Lisp value, printed) from SESS.  FORM runs in whatever frame is selected."
  (car (read-from-string
        (plist-get (drgnx-ui-call sess (format "(drgnx-uitest--json (list :v (prin1-to-string %s)))" form)) :v))))

(defun drgnx-wm-move--until (thunk &optional seconds)
  "Call THUNK every 0.2 s until it returns non-nil (that value) or SECONDS (default 8) pass (nil)."
  (let ((deadline (+ (float-time) (or seconds 8))) r)
    (while (and (not (setq r (funcall thunk))) (< (float-time) deadline))
      (sleep-for 0.2))
    r))

(defmacro drgnx-wm-move--in-root (root &rest body)
  "BODY with ROOT a temp directory that is the harness state root (and where saved layouts go)."
  (declare (indent 1))
  `(let* ((,root (make-temp-file "drgnx-wmm" t))
          (process-environment (cons (concat "DRGNX_UI_STATE=" ,root) process-environment)))
     (unwind-protect (progn ,@body) (delete-directory ,root t))))

(defconst drgnx-wm-move--session-lisp
  "(progn
     (defvar drgnx-wmt-main nil) (defvar drgnx-wmt-aux nil) (defvar drgnx-wmt-result nil)
     (defun drgnx-wmt-gui-frames ()
       (seq-filter (lambda (f) (and (display-graphic-p f) (not (frame-parent f)))) (frame-list)))
     (defun drgnx-wmt-main-frame ()
       (drgnx-frames-mark-main)
       (seq-find (lambda (f) (eq (frame-parameter f 'drgnx-frame-role) 'main)) (drgnx-wmt-gui-frames)))
     (defun drgnx-wmt-aux-frame ()
       (seq-find (lambda (f) (eq (drgnx-frame-role f) 'aux)) (drgnx-wmt-gui-frames)))
     (defun drgnx-wmt-monitor (f)
       (let ((g (alist-get 'geometry (frame-monitor-attributes f))))
         (cond ((null g) nil) ((= (car g) 0) 1) ((= (car g) 1280) 2) (t (car g)))))
     t)"
  "Defined in every session: the graphical windows, the aux one, and which monitor (1 or 2) Emacs says a frame is on.")

(defun drgnx-wm-move--start (monitors saved)
  "Start a daemon session with MONITORS outputs, its layout file SAVED; return the session."
  (let* ((s (drgnx-ui-start "drgnx" "1280x800" 60 t monitors (drgnx-ui-default-compositor)))
         (sess (drgnx-ui-own-session (plist-get s :name))))
    (drgnx-wm-move--eval sess (format "(progn (setq drgnx-persist-file %S) %s)" saved drgnx-wm-move--session-lisp))
    sess))

(defun drgnx-wm-move--open-main (sess &optional file)
  "Open the main window of SESS (`emacsclient -c'); with FILE, it shows that file.  The frame is `drgnx-wmt-main'."
  (should (eql 0 (plist-get (drgnx-ui-new-frame sess) :exit)))
  (should (drgnx-wm-move--until
           (lambda () (drgnx-wm-move--eval sess "(and (drgnx-wmt-main-frame) t)"))))
  (drgnx-wm-move--eval
   sess (format "(progn (setq drgnx-wmt-main (drgnx-wmt-main-frame))
                        %s t)"
                (if file (format "(with-selected-frame drgnx-wmt-main (find-file %S) (drgnx-chrome-apply nil t))" file) "")))
  sess)

(defun drgnx-wm-move--aux (sess)
  "Move the shown file of SESS's main window into a new window; it is `drgnx-wmt-aux'.  Waits until it is mapped."
  (drgnx-wm-move--eval
   sess "(progn (with-selected-frame drgnx-wmt-main (drgnx-frames-move-editor) (setq drgnx-wmt-aux (selected-frame))) t)")
  (should (drgnx-wm-move--until
           (lambda () (eql 2 (drgnx-wm-move--eval sess "(length (drgnx-wmt-gui-frames))")))))
  ;; the window manager has put it somewhere
  (should (drgnx-wm-move--until
           (lambda () (drgnx-wm-move--eval sess "(and (frame-visible-p drgnx-wmt-aux) (drgnx-wmt-monitor drgnx-wmt-aux))")))))

(defun drgnx-wm-move--deliver-focus (sess)
  "Tell the session's Emacs that the aux window has focus, as the window manager has made it so.
Headless sway has no keyboard (its seat has no capabilities), so Emacs never receives the focus-in event a
focused window gets on a real seat, and `frame-focus-state' stays nil.  The command refuses to move a window
without focus, so the test delivers the event itself; sway's own focus (the tree's `focused' flag) is still real.
Under X the window manager (or the pointer) gives Emacs the real event."
  (when (equal (drgnx-ui-default-compositor) "sway")
    (drgnx-wm-move--eval sess "(progn (handle-focus-in (list 'focus-in drgnx-wmt-aux)) t)")))

(defun drgnx-wm-move--move (sess target)
  "Ask `drgnx-monitors-move' to take `drgnx-wmt-aux' to TARGET (a number, `next', `previous'); its callback's value."
  (drgnx-wm-move--deliver-focus sess)
  (drgnx-wm-move--eval
   sess (format "(progn (setq drgnx-wmt-result 'pending)
                        (drgnx-monitors-move drgnx-wmt-aux (quote %S) (lambda (r) (setq drgnx-wmt-result r))) t)"
                target))
  (let ((r (drgnx-wm-move--until (lambda () (let ((v (drgnx-wm-move--eval sess "drgnx-wmt-result")))
                                              (and (not (eq v 'pending)) (list v)))))))
    (should r)
    (car r)))

(defun drgnx-wm-move--aux-monitor (sess)
  "Which monitor (1, 2) Emacs says `drgnx-wmt-aux' is on."
  (drgnx-wm-move--eval sess "(drgnx-wmt-monitor drgnx-wmt-aux)"))

(defun drgnx-wm-move--aux-on (sess n)
  "Wait until Emacs says the aux window is on monitor N; non-nil if it is."
  (drgnx-wm-move--until (lambda () (eql n (drgnx-wm-move--aux-monitor sess)))))

;; The window manager's side (sway, i3): the tree's windows of this session's Emacs.

(defun drgnx-wm-move--nodes (node &optional output)
  "The window nodes of a sway/i3 tree NODE (a pid or an X window), each as (OUTPUT-NAME . NODE)."
  (let* ((output (if (equal (plist-get node :type) "output") (plist-get node :name) output))
         (kids (append (plist-get node :nodes) (plist-get node :floating_nodes) nil)))
    (append (and (equal (plist-get node :type) "con")
                 (or (integerp (plist-get node :pid)) (integerp (plist-get node :window)))
                 (list (cons output node)))
            (seq-mapcat (lambda (k) (drgnx-wm-move--nodes k output)) kids))))

(defun drgnx-wm-move--emacs-nodes (sess)
  "The tree windows of SESS's Emacs as (OUTPUT . NODE): by pid under sway, by X window under i3."
  (let* ((tree (plist-get (drgnx-ui-wm sess) :tree))
         (pid (drgnx-wm-move--eval sess "(emacs-pid)"))
         (xids (and (equal (drgnx-ui-default-compositor) "i3")
                    (mapcar #'string-to-number
                            (drgnx-wm-move--eval
                             sess "(mapcar (lambda (f) (format \"%s\" (frame-parameter f 'outer-window-id))) (drgnx-wmt-gui-frames))")))))
    (seq-filter (lambda (w) (if xids (memql (plist-get (cdr w) :window) xids) (eql (plist-get (cdr w) :pid) pid)))
                (drgnx-wm-move--nodes tree))))

(defun drgnx-wm-move--wm-outputs (sess)
  "The outputs of SESS's Emacs windows in the WM's tree, sorted."
  (sort (mapcar #'car (drgnx-wm-move--emacs-nodes sess)) #'string<))

(defun drgnx-wm-move--focused (sess)
  "The (OUTPUT . NODE) of the focused window of SESS's Emacs, or nil."
  (seq-find (lambda (w) (eq (plist-get (cdr w) :focused) t)) (drgnx-wm-move--emacs-nodes sess)))

(defun drgnx-wm-move--first-output ()
  "The name of the first monitor's output for this tier."
  (pcase (drgnx-ui-default-compositor) ("sway" "HEADLESS-1") (_ "XVFB-1")))

(defun drgnx-wm-move--second-output ()
  (pcase (drgnx-ui-default-compositor) ("sway" "HEADLESS-2") (_ "XVFB-2")))

;;;; Moving

(ert-deftest drgnx-wm/move-to-monitor-2-and-back ()
  (skip-unless (member (drgnx-ui-default-compositor) '("sway" "x11" "i3")))
  (drgnx-wm-move--in-root root
    (let* ((file (expand-file-name "a.txt" root))
           (_ (write-region "a\n" nil file nil 'silent))
           (sess (drgnx-wm-move--start 2 (expand-file-name "saved/workbench.eld" root)))
           (managed (member (drgnx-ui-default-compositor) '("sway" "i3"))))
      (unwind-protect
          (progn
            (drgnx-wm-move--open-main sess file)
            (drgnx-wm-move--aux sess)
            (should (eql 1 (drgnx-wm-move--aux-monitor sess)))
            (drgnx-wm-move--eval sess "(progn (select-frame-set-input-focus drgnx-wmt-aux) t)")
            ;; to monitor 2: Emacs says so, the WM says so, and the window keeps the focus
            (should (eq 'ok (drgnx-wm-move--move sess 2)))
            (should (drgnx-wm-move--aux-on sess 2))
            (if managed
                (progn
                  (should (drgnx-wm-move--until
                           (lambda () (equal (drgnx-wm-move--wm-outputs sess)
                                             (list (drgnx-wm-move--first-output) (drgnx-wm-move--second-output))))))
                  (let ((f (drgnx-wm-move--focused sess)))
                    (should f)
                    (should (equal (car f) (drgnx-wm-move--second-output)))))
              (should (drgnx-wm-move--eval sess "(eq (selected-frame) drgnx-wmt-aux)")))
            ;; Next wraps round to monitor 1
            (should (eq 'ok (drgnx-wm-move--move sess 'next)))
            (should (drgnx-wm-move--aux-on sess 1))
            (when managed
              (should (drgnx-wm-move--until
                       (lambda () (equal (drgnx-wm-move--wm-outputs sess)
                                         (list (drgnx-wm-move--first-output) (drgnx-wm-move--first-output))))))
              (should (equal (car (drgnx-wm-move--focused sess)) (drgnx-wm-move--first-output)))))
        (drgnx-ui-stop (plist-get sess :name))))))

(ert-deftest drgnx-wm/a-fullscreen-window-stays-fullscreen-on-its-new-monitor ()
  (skip-unless (member (drgnx-ui-default-compositor) '("sway" "x11")))
  (drgnx-wm-move--in-root root
    (let* ((file (expand-file-name "a.txt" root))
           (_ (write-region "a\n" nil file nil 'silent))
           (sess (drgnx-wm-move--start 2 (expand-file-name "saved/workbench.eld" root)))
           (sway (equal (drgnx-ui-default-compositor) "sway")))
      (unwind-protect
          (progn
            (drgnx-wm-move--open-main sess file)
            (drgnx-wm-move--aux sess)
            (drgnx-wm-move--eval sess "(progn (set-frame-parameter drgnx-wmt-aux 'fullscreen 'fullboth) t)")
            (when sway
              ;; fullscreen on its output, as the WM sees it
              (should (drgnx-wm-move--until
                       (lambda () (let ((f (drgnx-wm-move--focused sess)))
                                    (and f (eql 1 (plist-get (cdr f) :fullscreen_mode))))))))
            (should (eq 'ok (drgnx-wm-move--move sess 2)))
            (should (drgnx-wm-move--aux-on sess 2))
            (should (eq 'fullboth (drgnx-wm-move--eval sess "(frame-parameter drgnx-wmt-aux 'fullscreen)")))
            (when sway
              (let ((f (should (drgnx-wm-move--until
                                (lambda () (let ((f (drgnx-wm-move--focused sess)))
                                             (and f (equal (car f) "HEADLESS-2") f)))))))
                (should (eql 1 (plist-get (cdr f) :fullscreen_mode)))
                (should (equal (plist-get (cdr f) :rect) '(:x 1280 :y 0 :width 1280 :height 800)))
                (should (equal (plist-get (cdr f) :pid) (drgnx-wm-move--eval sess "(emacs-pid)"))))))
        (drgnx-ui-stop (plist-get sess :name))))))

;;;; Restore

(defun drgnx-wm-move--save-aux-on-2 (root saved)
  "Run a session, put an aux window on monitor 2, stop it: its layout is in file SAVED (under ROOT)."
  (let* ((file (expand-file-name "a.txt" root))
         (_ (write-region "a\n" nil file nil 'silent))
         (sess (drgnx-wm-move--start 2 saved)))
    (unwind-protect
        (progn
          (drgnx-wm-move--open-main sess file)
          (drgnx-wm-move--aux sess)
          (should (eq 'ok (drgnx-wm-move--move sess 2)))
          (should (drgnx-wm-move--aux-on sess 2)))
      (drgnx-ui-stop (plist-get sess :name)))      ; Emacs exits first: the layout is saved
    (should (file-exists-p saved))
    (should (string-match-p ":monitors-monitor" (with-temp-buffer (insert-file-contents saved) (buffer-string))))))

(defun drgnx-wm-move--aux-frame-p (sess)
  (drgnx-wm-move--eval sess "(and (drgnx-wmt-aux-frame) t)"))

(ert-deftest drgnx-wm/restore-puts-the-aux-window-back-on-its-monitor ()
  (skip-unless (member (drgnx-ui-default-compositor) '("sway" "x11")))
  (drgnx-wm-move--in-root root
    (let ((saved (expand-file-name "saved/workbench.eld" root)))
      (drgnx-wm-move--save-aux-on-2 root saved)
      (let ((sess (drgnx-wm-move--start 2 saved)))
        (unwind-protect
            (progn
              (drgnx-wm-move--open-main sess)
              ;; the layout comes back and the aux window is on monitor 2 within the restore deadline (5 s)
              (should (drgnx-wm-move--until (lambda () (drgnx-wm-move--aux-frame-p sess)) 5))
              (should (drgnx-wm-move--until
                       (lambda () (eql 2 (drgnx-wm-move--eval sess "(drgnx-wmt-monitor (drgnx-wmt-aux-frame))")))
                       5))
              ;; the main window is where the WM put it: monitor 1
              (should (eql 1 (drgnx-wm-move--eval sess "(drgnx-wmt-monitor drgnx-wmt-main)")))
              (when (equal (drgnx-ui-default-compositor) "sway")
                (should (drgnx-wm-move--until
                         (lambda () (equal (drgnx-wm-move--wm-outputs sess) '("HEADLESS-1" "HEADLESS-2")))))))
          (drgnx-ui-stop (plist-get sess :name)))))))

(ert-deftest drgnx-wm/a-missing-monitor-on-restore-is-skipped ()
  (skip-unless (equal (drgnx-ui-default-compositor) "sway"))
  (drgnx-wm-move--in-root root
    (let ((saved (expand-file-name "saved/workbench.eld" root)))
      (drgnx-wm-move--save-aux-on-2 root saved)
      (let ((sess (drgnx-wm-move--start 1 saved))
            (messages "(with-current-buffer \"*Messages*\" (buffer-string))"))
        (unwind-protect
            (progn
              (drgnx-wm-move--open-main sess)
              ;; both windows open, on the only output
              (should (drgnx-wm-move--until (lambda () (drgnx-wm-move--aux-frame-p sess)) 5))
              (should (drgnx-wm-move--until
                       (lambda () (equal (drgnx-wm-move--wm-outputs sess) '("HEADLESS-1" "HEADLESS-1")))))
              ;; one message about the monitor that is not there, once the placement has run
              (should (drgnx-wm-move--until
                       (lambda () (string-match-p "monitor is not connected" (drgnx-wm-move--eval sess messages)))
                       6))
              (sleep-for 1)
              (let ((text (drgnx-wm-move--eval sess messages)))
                (should (= 1 (drgnx-wm-move--count "monitor is not connected" text)))
                (should-not (string-match-p "after-restore function\\|was not restored" text))))
          (drgnx-ui-stop (plist-get sess :name)))))))

(defun drgnx-wm-move--count (regexp string)
  "How many times REGEXP matches in STRING."
  (let ((n 0) (start 0))
    (while (string-match regexp string start)
      (setq n (1+ n) start (match-end 0)))
    n))

;;;; Mutter: explains, moves nothing

(ert-deftest drgnx-wm/mutter-explains-and-moves-nothing ()
  (skip-unless (equal (drgnx-ui-default-compositor) "mutter"))
  (drgnx-wm-move--in-root root
    (let* ((file (expand-file-name "a.txt" root))
           (_ (write-region "a\n" nil file nil 'silent))
           (sess (drgnx-wm-move--start 2 (expand-file-name "saved/workbench.eld" root)))
           (where "(mapcar (lambda (f) (list (frame-position f) (alist-get 'geometry (frame-monitor-attributes f))))
                           (drgnx-wmt-gui-frames))"))
      (unwind-protect
          (progn
            (drgnx-wm-move--open-main sess file)
            (drgnx-wm-move--aux sess)
            (let* ((before (drgnx-wm-move--eval sess where))
                   (said (drgnx-wm-move--eval
                          sess "(let (msgs)
                                  (cl-letf (((symbol-function 'message)
                                             (lambda (f &rest a) (push (apply #'format-message f a) msgs))))
                                    (with-selected-frame drgnx-wmt-aux (drgnx-monitors-move-next)))
                                  (nreverse msgs))")))
              ;; the command says it cannot drive the compositor and to use its own key
              (should (= 1 (length said)))
              (should (string-match-p "no adapter for this compositor" (car said)))
              (should (string-match-p "its own key" (car said)))
              ;; and the monitor API answers the same, asynchronously
              (let ((r (drgnx-wm-move--move sess 2)))
                (should (eq :error (car-safe r)))
                (should (string-match-p "its own key" (cadr r))))
              (sleep-for 1)
              (should (equal (drgnx-wm-move--eval sess where) before))))
        (drgnx-ui-stop (plist-get sess :name))))))

;;;; Restore under sway moves nothing else

(defun drgnx-wm-move--start-other-client (sess)
  "A plain `emacs -Q' on SESS's sway (a window of another app); the process."
  (let* ((process-environment (append (drgnx-ui--display-env sess) process-environment)))
    (start-process "drgnx-wm-other" nil (drgnx-ui-emacs-bin) "-Q" "--eval" "(setq frame-title-format \"drgnx-other-app\")")))

(defun drgnx-wm-move--other-app (sess)
  "The (OUTPUT . NODE) of the other app's window in SESS's sway tree, or nil."
  (seq-find (lambda (w) (equal (plist-get (cdr w) :name) "drgnx-other-app"))
            (drgnx-wm-move--nodes (plist-get (drgnx-ui-wm sess) :tree))))

(ert-deftest drgnx-wm/a-restore-under-sway-moves-nothing-else ()
  (skip-unless (equal (drgnx-ui-default-compositor) "sway"))
  (drgnx-wm-move--in-root root
    (let ((saved (expand-file-name "saved/workbench.eld" root)))
      (drgnx-wm-move--save-aux-on-2 root saved)
      (let* ((sess (drgnx-wm-move--start 2 saved))
             (other (drgnx-wm-move--start-other-client sess)))
        (unwind-protect
            (progn
              (should (drgnx-wm-move--until (lambda () (drgnx-wm-move--other-app sess)) 20))
              (let ((other-before (drgnx-wm-move--other-app sess)))
                ;; The first window, with the restore held back: it is the one the report measures.
                (drgnx-wm-move--eval sess "(progn (setq drgnx-persist-restore-on-start nil) t)")
                (drgnx-wm-move--open-main sess)
                (drgnx-ui-call sess "(progn (drgnx-uitest-measure-begin drgnx-wmt-main) (drgnx-uitest--json (list :ok t)))")
                (drgnx-wm-move--eval sess "(progn (drgnx-persist--restore-into drgnx-wmt-main) t)")
                (should (drgnx-wm-move--until (lambda () (drgnx-wm-move--aux-frame-p sess)) 5))
                (should (drgnx-wm-move--until
                         (lambda () (eql 2 (drgnx-wm-move--eval sess "(drgnx-wmt-monitor (drgnx-wmt-aux-frame))")))
                         5))
                (let* ((settled (drgnx-ui-wait sess 500 15))
                       (report (drgnx-ui-call sess "(drgnx-uitest-api-measure-end)"))
                       (other-after (drgnx-wm-move--other-app sess)))
                  (should settled)
                  (should (= 0 (plist-get report :guard_violations)))
                  (should (= 0 (plist-get report :collateral_moves)))
                  ;; the other app's window is still on its output, and still the same window
                  (should other-after)
                  (should (equal (car other-after) (car other-before)))
                  (should (equal (plist-get (cdr other-after) :id) (plist-get (cdr other-before) :id)))
                  ;; Emacs' two windows: the main one stayed on the output the other app is on
                  (should (equal (drgnx-wm-move--wm-outputs sess) '("HEADLESS-1" "HEADLESS-2"))))))
          (when (process-live-p other) (delete-process other))
          (drgnx-ui-stop (plist-get sess :name)))))))

;;; drgnx-wm-test.el ends here
