;;; drgnx-open-new-window-test.el --- live: `drgnx DIR' with no window open shows DIR, however slow the window -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; A daemon session with no graphical window and a saved workbench whose Explorer showed another folder.  Its
;; window takes 12 s to be made (as a daily install's did, 10-15 s to its first draw: the daemon serves no other
;; client meanwhile, so bin/drgnx's questions time out).  `bin/drgnx open DIR' makes the window and opens DIR; once the window is made and
;; everything that runs at a new window has run, the Explorer still shows DIR first, and the sidebar is shown.
(require 'ert)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-ui)

(defun drgnx-open-new-window--eval (sess form)
  "FORM's value (printed and read back) in daemon session SESS, its graphical window selected when it has one."
  (car (read-from-string
        (plist-get (drgnx-ui-call sess (format "(drgnx-uitest--json
                                                 (list :v (prin1-to-string
                                                           (let ((f (seq-find (lambda (f) (and (display-graphic-p f) (not (frame-parent f)))) (frame-list))))
                                                             (if f (with-selected-frame f %s) %s)))))" form form))
                   :v))))

(defun drgnx-open-new-window--until (sess form what)
  "Ask SESS for FORM until it is non-nil, at most 30 s; else fail on WHAT."
  (condition-case nil
      (drgnx-test-wait (lambda () (drgnx-open-new-window--eval sess form)) :secs 30 :what what)
    (ert-test-failed nil))
  (should (drgnx-open-new-window--eval sess form)))

(defun drgnx-open-new-window--hub (sess)
  "Start the test hub in SESS's Emacs and connect it (a session starts none by itself: DRGNX_NO_HUB_START), as
drgnx-workbench-test.el's `drgnx-live-wb--hub'.  No hub binary fails the test."
  (let ((bin (seq-some (lambda (kv) (and (string-prefix-p "DRGNX_RATATOSKR_BIN=" kv) (substring kv 20)))
                       (drgnx-ui--hub-env))))
    (unless (and bin (file-executable-p bin)) (ert-fail "needs the test hub: DRGNX_RATATOSKR_BIN"))
    (drgnx-open-new-window--eval
     sess (format "(progn (require 'drgnx-hub-client)
                          (unless (drgnx-hub-running-p)
                            (let ((process-environment (cons \"RATATOSKR_SUPERVISOR=none\" process-environment)))
                              (make-process :name \"ratatoskr-test\" :noquery t :connection-type 'pipe
                                            :buffer (generate-new-buffer \" *ratatoskr-test*\")
                                            :command (list %S \"serve\" \"--foreground\"
                                                           \"--parent-pid\" (number-to-string (emacs-pid))))))
                          t)" bin))
    (drgnx-open-new-window--until sess "(drgnx-hub-running-p)" "the hub running")
    (drgnx-open-new-window--eval sess "(progn (drgnx-hub-connect) t)")
    (drgnx-open-new-window--until sess "(and drgnx-hub--events (eq (process-status drgnx-hub--events) 'open))"
                                  "the hub connected")))

(ert-deftest drgnx-live/drgnx-dir-shows-dir-in-a-window-slow-to-open ()
  (let* ((root (make-temp-file "drgnx-open-new-window" t))
         (old (file-name-as-directory (expand-file-name "old" root)))
         (project (file-name-as-directory (expand-file-name "project" root)))
         (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
         (s (progn (make-directory old t) (make-directory project t)
                   (write-region "x\n" nil (expand-file-name "a.txt" project) nil 'silent)
                   (drgnx-ui-start "drgnx" (drgnx-ui-size-at-scale "1200x700") 30 t)))
         (name (plist-get s :name))
         (sess (drgnx-ui-own-session name)))
    (unwind-protect
        (progn
          (should (eql 0 (plist-get (drgnx-ui-call sess "(drgnx-uitest-api-gui-frames)") :count)))
          ;; the last session's workbench: the Explorer on OLD; a window that takes 12 s to be made
          (drgnx-open-new-window--eval
           sess (format "(progn (make-directory (file-name-directory (drgnx-persist--file)) t)
                                (write-region %S nil (drgnx-persist--file) nil 'silent)
                                (defvar drgnx-open-new-window--made nil)
                                (defun drgnx-open-new-window--slow (f)
                                  (when (display-graphic-p f)
                                    (remove-hook 'after-make-frame-functions #'drgnx-open-new-window--slow)
                                    (let ((end (+ (float-time) 12)))
                                      (while (< (float-time) end)))   ; busy: no other client is served meanwhile
                                    (setq drgnx-open-new-window--made t)))
                                (add-hook 'after-make-frame-functions #'drgnx-open-new-window--slow)
                                t)"
                        (prin1-to-string `(:version 2 :frames ((:role main :roots (,old) :left (:shown t :view explorer)))))))
          (let ((process-environment (append (list (concat "DRGNX_SERVER_NAME=" (plist-get sess :socket))
                                                   (concat "DRGNX_EMACS=" (drgnx-ui-emacs-bin))
                                                   (concat "WAYLAND_DISPLAY=" name)
                                                   (concat "XDG_RUNTIME_DIR=" (drgnx-ui-session-runtime-dir name))
                                                   "DISPLAY")
                                             process-environment)))
            (with-temp-buffer
              (let ((exit (call-process (expand-file-name "bin/drgnx" drgnx-ui-repo-dir) nil t nil "open" project)))
                (should (equal (list exit (buffer-string)) '(0 ""))))))
          (condition-case nil
              (drgnx-test-wait (lambda () (drgnx-open-new-window--eval sess "drgnx-open-new-window--made"))
                               :secs 30 :what "the slow window to be made")
            (ert-test-failed nil))
          (should (drgnx-open-new-window--eval sess "drgnx-open-new-window--made"))
          ;; the new window's hooks ran (the restore marks it; the start page's hook comes after it in the same run), and
          ;; the folder's open, queued behind the window, ran too
          (drgnx-open-new-window--until
           sess (format "(and (frame-parameter nil 'drgnx-persist-restored) (equal (car (drgnx-explorer-roots)) %S))" project)
           "the window restored and DIR opened")
          (should (= 1 (plist-get (drgnx-ui-call sess "(drgnx-uitest-api-gui-frames)") :count)))
          (should (equal (drgnx-open-new-window--eval sess "(car (drgnx-explorer-roots))") project))
          (should (drgnx-open-new-window--eval sess "(drgnx-wb-sidebar-showing-p)"))
          ;; as `code .': the folder and an empty editor, no start page (a launch with no folder still gets it)
          (should-not (drgnx-open-new-window--eval
                       sess "(seq-some (lambda (w) (equal (buffer-name (window-buffer w)) drgnx-start-buffer-name)) (window-list))"))
          ;; the hub comes up only now (a daemon that just restarted starts it late): the Explorer lists DIR then
          (drgnx-open-new-window--hub sess)
          (let ((text "(with-current-buffer drgnx-explorer-buffer-name (buffer-substring-no-properties (point-min) (point-max)))")
                shown)
            (condition-case nil
                (drgnx-test-wait (lambda () (string-match-p "a\\.txt" (setq shown (drgnx-open-new-window--eval sess text))))
                                 :secs 15 :what "DIR's files in the Explorer")
              (ert-test-failed nil))
            (should (string-match-p "a\\.txt" shown))))
      (drgnx-ui-stop name)
      (delete-directory root t))))

;;; drgnx-open-new-window-test.el ends here
