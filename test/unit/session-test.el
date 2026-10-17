;;; session-test.el --- batch tests: closing the last window, quitting, the keep-running choice -*- lexical-binding: t -*-
;; Frames, `kill-emacs', `delete-frame' and `save-some-buffers' are stubs; session.eld lives in a temp config dir.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-session)

(defmacro drgnx-session-test--with (spec &rest body)
  "BODY with the stubs SPEC asks for, in a temp config dir.
SPEC: (:keep-running BOOL :daemon BOOL :windows LIST :save FN :unsaved LIST :confirm BOOL) — :windows the
frames that count as windows, :unsaved the file buffers still changed after the save.  Binds KILLED (non-nil once
`kill-emacs' ran), DELETED (frames deleted), SAVED (calls of `save-some-buffers') and ASKED (confirmations)."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "drgnx-session-test" t))
          (process-environment (cons (concat "DRGNX_CONFIG_DIR=" dir) process-environment))
          (drgnx-keep-running ,(plist-get spec :keep-running))
          (killed nil) (deleted nil) (saved 0) (asked 0))
     (unwind-protect
         (cl-letf (((symbol-function 'daemonp) (lambda () ,(plist-get spec :daemon)))
                   ((symbol-function 'drgnx-session--windows) (lambda () ,(plist-get spec :windows)))
                   ((symbol-function 'select-frame-set-input-focus) #'ignore)
                   ((symbol-function 'kill-emacs) (lambda (&rest _) (setq killed t)))
                   ((symbol-function 'delete-frame) (lambda (&optional f _force) (push f deleted)))
                   ((symbol-function 'save-some-buffers)
                    (lambda (&rest _) (cl-incf saved) (funcall (or ,(plist-get spec :save) #'ignore))))
                   ((symbol-function 'drgnx-session--unsaved-buffers) (lambda () ,(plist-get spec :unsaved)))
                   ((symbol-function 'yes-or-no-p) (lambda (&rest _) (cl-incf asked) ,(plist-get spec :confirm))))
           (ignore killed deleted saved asked)
           ,@body)
       (delete-directory dir t))))

(ert-deftest drgnx-session/quit-mode-closing-the-last-window-quits ()
  (drgnx-session-test--with (:keep-running nil :daemon t :windows (list (selected-frame)) :save (lambda () t))
    (drgnx-session-close-frame)
    (should (= saved 1))
    (should killed)
    (should-not deleted)))

(ert-deftest drgnx-session/keep-running-closing-the-last-window-stays ()
  (drgnx-session-test--with (:keep-running t :daemon t :windows (list (selected-frame)))
    (drgnx-session-close-frame)
    (should-not killed)
    (should (= saved 0))
    (should (equal deleted (list (selected-frame))))))

(ert-deftest drgnx-session/another-window-open-just-closes-this-one ()
  (drgnx-session-test--with (:keep-running nil :daemon t :windows (list (selected-frame) 'f2))
    (drgnx-session-close-frame)
    (should-not killed)
    (should (equal deleted (list (selected-frame))))))

(ert-deftest drgnx-session/the-last-window-of-an-emacs-without-a-daemon-quits-in-either-mode ()
  ;; Without a daemon there is nothing to keep running once the last window is gone.
  (drgnx-session-test--with (:keep-running t :daemon nil :windows (list (selected-frame)))
    (drgnx-session-close-frame)
    (should killed)
    (should-not deleted)))

(ert-deftest drgnx-session/the-close-button-closes-the-window-it-belongs-to ()
  ;; The title bar's close button: a `delete-frame' event naming its frame.
  (drgnx-session-test--with (:keep-running t :daemon t :windows (list 'f1 'f2))
    (drgnx-session-close-frame (list 'delete-frame (list 'f2)))
    (should (equal deleted '(f2)))
    (drgnx-session-setup)
    (should (eq (lookup-key special-event-map [delete-frame]) #'drgnx-session-close-frame))))

(ert-deftest drgnx-session/unsaved-work-is-never-lost ()
  ;; C-g in the save question: drgnx stays, the window stays.
  (drgnx-session-test--with (:keep-running nil :daemon t :windows (list (selected-frame)) :save (lambda () (signal 'quit nil)))
    (should (eq 'quit (condition-case nil (progn (drgnx-session-close-frame) 'ran) (quit 'quit))))
    (should-not killed)
    (should-not deleted))
  ;; An error while saving (a read-only directory): the same.
  (drgnx-session-test--with (:keep-running nil :daemon t :windows (list 'f1) :save (lambda () (error "Disk full")))
    (should-error (drgnx-session-quit))
    (should-not killed))
  ;; A file kept unsaved, then "no" to quitting without it: drgnx stays.
  (drgnx-session-test--with (:keep-running nil :daemon t :windows (list 'f1) :unsaved (list 'buf) :confirm nil)
    (drgnx-session-quit)
    (should (= asked 1))
    (should-not killed))
  ;; …"yes": quits.
  (drgnx-session-test--with (:keep-running nil :daemon t :windows (list 'f1) :unsaved (list 'buf) :confirm t)
    (drgnx-session-quit)
    (should killed))
  ;; Everything saved: no extra question.
  (drgnx-session-test--with (:keep-running nil :daemon t :windows (list 'f1))
    (drgnx-session-quit)
    (should (= asked 0))
    (should killed)))

(ert-deftest drgnx-session/the-choice-is-remembered ()
  (drgnx-session-test--with (:keep-running t)
    (drgnx-session-set-keep-running nil)
    (should-not drgnx-keep-running)
    (should (equal (with-temp-buffer (insert-file-contents (expand-file-name "session.eld" dir)) (read (current-buffer)))
                   '(:keep-running nil)))
    (setq drgnx-keep-running t)
    (drgnx-session-load)                      ; what the next start does
    (should-not drgnx-keep-running)
    (drgnx-session-set-keep-running t)
    (setq drgnx-keep-running nil)
    (drgnx-session-load)
    (should (eq drgnx-keep-running t))
    ;; no file, or a broken one: the default stays
    (delete-file (expand-file-name "session.eld" dir))
    (drgnx-session-load)
    (should (eq drgnx-keep-running t))
    (write-region "(:keep-running" nil (expand-file-name "session.eld" dir))
    (drgnx-session-load)
    (should (eq drgnx-keep-running t))))

(ert-deftest drgnx-session/the-preference-toggles-and-says-so ()
  (drgnx-session-test--with (:keep-running t)
    (let ((msg (drgnx-session-toggle-keep-running)))
      (should-not drgnx-keep-running)
      (should (string-match-p "quits" msg)))
    (let ((msg (drgnx-session-toggle-keep-running)))
      (should drgnx-keep-running)
      (should (string-match-p "keeps running" msg)))))

(ert-deftest drgnx-session/commands-are-registered ()
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
    (drgnx-session-register-commands)
    (should (equal (drgnx-commands-label (drgnx-commands-get 'quit)) "File: Quit drgnx"))
    (should (eq (drgnx-cmd-command (drgnx-commands-get 'quit)) #'drgnx-session-quit))
    (should (equal (drgnx-commands-label (drgnx-commands-get 'preferences-keep-running))
                   "Preferences: Keep drgnx Running in the Background"))))

(ert-deftest drgnx-session/no-window-in-batch ()
  ;; A daemon's (or batch Emacs's) own terminal frame is not a window.
  (should-not (drgnx-session-gui-frame-p))
  (should-not (drgnx-session--windows)))

(ert-deftest drgnx-session/a-folder-goes-first-in-the-explorer ()
  (let ((roots (list "/tmp/other/" "/tmp/proj/")) shown raised)
    (cl-letf (((symbol-function 'drgnx-session-raise) (lambda () (setq raised t)))
              ((symbol-function 'drgnx-explorer-roots) (lambda () roots))
              ((symbol-function 'drgnx-explorer-set-roots) (lambda (r) (setq roots r)))
              ((symbol-function 'drgnx-wb-sidebar-showing-p) (lambda (&rest _) shown))
              ((symbol-function 'drgnx-wb-show-sidebar) (lambda () (setq shown t))))
      (drgnx-session-open-folder "/tmp/proj")
      (should raised)
      (should (equal roots '("/tmp/proj/" "/tmp/other/")))
      (should shown)
      (drgnx-session-open-folder "/tmp/new dir/café")
      (should (equal roots '("/tmp/new dir/café/" "/tmp/proj/" "/tmp/other/"))))))

(ert-deftest drgnx-session/the-server-starts-only-where-drgnx-path-should-reach-it ()
  (require 'server)
  (let (started)
    (cl-letf (((symbol-function 'server-start) (lambda (&rest _) (setq started server-name)))
              ((symbol-function 'server-running-p) (lambda (&rest _) nil))
              ((symbol-function 'daemonp) #'ignore))
      (let ((server-name "server") (server-process nil) (initial-window-system 'x) (process-environment process-environment))
        (setenv "DRGNX_UI_RUN") (setenv "DRGNX_SAFE")
        (drgnx-session-start-server)          ; batch Emacs: never
        (should-not started)
        (let ((noninteractive nil))
          (drgnx-session-start-server)
          (should (equal started "drgnx"))
          (setq started nil)
          (cl-letf (((symbol-function 'server-running-p) (lambda (&rest _) t)))   ; another drgnx has the name
            (drgnx-session-start-server))
          (should-not started)
          (setenv "DRGNX_SAFE" "1")
          (drgnx-session-start-server)
          (should-not started))))))

;;; session-test.el ends here
