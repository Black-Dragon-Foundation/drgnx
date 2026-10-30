;;; drgnx-session-keep-or-quit-test.el --- live: drgnx PATH reaches the daemon; the last window closes, it stays or quits -*- lexical-binding: t -*-
;; Scenario session-keep-or-quit: a daemon session of config drgnx.  `bin/drgnx open' reaches it (its socket as
;; DRGNX_SERVER_NAME), a file and a folder with a space and an accent; then the last window's close button (the
;; `delete-frame' event's binding) in keep-running mode → the daemon stays; in quit mode → it is gone.
(require 'ert)
(require 'drgnx-ui)

(defun drgnx-session-live--eval (sess form)
  "FORM's value (printed and read back) in daemon session SESS, its graphical window selected when it has one."
  (car (read-from-string
        (plist-get (drgnx-ui-call sess (format "(drgnx-uitest--json
                                                 (list :v (prin1-to-string
                                                           (let ((f (seq-find (lambda (f) (and (display-graphic-p f) (not (frame-parent f)))) (frame-list))))
                                                             (if f (with-selected-frame f %s) %s)))))" form form))
                   :v))))

(defun drgnx-session-live--alive-p (sess)
  (condition-case nil (progn (drgnx-ui-call sess "(drgnx-uitest--json (list :v 1))" 5) t) (error nil)))

(defun drgnx-session-live--close-last-window (sess)
  "Press the close button of SESS's graphical window: its `delete-frame' event, run from a timer so the
request returns before drgnx may quit."
  (drgnx-ui-call sess "(let ((f (seq-find (lambda (f) (and (display-graphic-p f) (not (frame-parent f)))) (frame-list))))
                         (run-at-time 0.1 nil (lambda () (funcall (lookup-key special-event-map [delete-frame])
                                                                  (list 'delete-frame (list f)))))
                         (drgnx-uitest--json (list :v 1)))"))

(defun drgnx-session-live--gui-count (sess)
  (plist-get (drgnx-ui-call sess "(drgnx-uitest-api-gui-frames)") :count))

(ert-deftest drgnx-live/session-keep-or-quit ()
  (let* ((root (make-temp-file "drgnx-session-live" t))
         (project (expand-file-name "My Project" root))
         (file (expand-file-name "café.py" project))
         (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
         (s (progn (make-directory project) (write-region "print(1)\n" nil file nil 'silent)
                   (drgnx-ui-start "drgnx" "1200x700" 30 t)))
         (name (plist-get s :name))
         (sess (drgnx-ui-own-session name)))
    (unwind-protect
        (progn
          ;; drgnx PATH: the running daemon, no second Emacs; a window is made, the file and folder in front
          (let ((process-environment (append (list (concat "DRGNX_SERVER_NAME=" (plist-get sess :socket))
                                                   (concat "DRGNX_EMACS=" (drgnx-ui-emacs-bin))
                                                   (concat "WAYLAND_DISPLAY=" name)
                                                   (concat "XDG_RUNTIME_DIR=" (drgnx-ui-session-runtime-dir name))
                                                   "DISPLAY")
                                             process-environment)))
            (with-temp-buffer
              (let ((exit (call-process (expand-file-name "bin/drgnx" drgnx-ui-repo-dir) nil t nil "open" file project)))
                (should (equal (list exit (buffer-string)) '(0 ""))))))
          (should (= 1 (drgnx-session-live--gui-count sess)))
          (should (drgnx-session-live--eval sess (format "(and (seq-some (lambda (w) (equal (buffer-file-name (window-buffer w)) %S)) (window-list)) t)" file)))
          (should (equal (drgnx-session-live--eval sess "(car (drgnx-explorer-roots))") (file-name-as-directory project)))
          (should (drgnx-session-live--eval sess "(drgnx-wb-sidebar-showing-p)"))
          ;; Keep running (the default): the last window closes, drgnx stays.
          (drgnx-session-live--eval sess "(drgnx-session-set-keep-running t)")
          (drgnx-session-live--close-last-window sess)
          (let ((deadline (+ (float-time) 10)))
            (while (and (< (float-time) deadline) (/= 0 (drgnx-session-live--gui-count sess))) (sleep-for 0.1)))
          (should (= 0 (drgnx-session-live--gui-count sess)))
          (sleep-for 1)
          (should (drgnx-session-live--alive-p sess))
          (should (eq t (drgnx-session-live--eval sess "(daemonp)")))
          ;; Quit when the last window closes: it opens again, closes, and drgnx is gone.
          (should (eql 0 (plist-get (drgnx-ui-new-frame sess) :exit)))
          (drgnx-session-live--eval sess "(drgnx-session-set-keep-running nil)")
          (drgnx-session-live--close-last-window sess)
          (let ((deadline (+ (float-time) 10)))
            (while (and (< (float-time) deadline) (drgnx-session-live--alive-p sess)) (sleep-for 0.2)))
          (should-not (drgnx-session-live--alive-p sess)))
      (drgnx-ui-stop name)
      (delete-directory root t))))

;;; drgnx-session-keep-or-quit-test.el ends here
