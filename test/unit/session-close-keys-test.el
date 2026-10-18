;;; session-close-keys-test.el --- batch tests: C-x C-c and C-x 5 0 close the last window like its close button -*- lexical-binding: t -*-
;; M12a-32.  Frames, `kill-emacs', `delete-frame' and the stock commands are stubs.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-session)

(defmacro drgnx-session-close-keys-test--with (spec &rest body)
  "BODY with stubbed frames and quitting.  SPEC: (:keep-running BOOL :windows LIST :graphic BOOL).
Binds KILLED (`kill-emacs' ran), DELETED (frames deleted) and STOCK (stock commands that ran, newest first)."
  (declare (indent 1))
  `(let ((drgnx-keep-running ,(plist-get spec :keep-running)) (killed nil) (deleted nil) (stock nil))
     (cl-letf (((symbol-function 'daemonp) (lambda () t))
               ((symbol-function 'display-graphic-p) (lambda (&optional _) ,(plist-get spec :graphic)))
               ((symbol-function 'drgnx-session--windows) (lambda () ,(plist-get spec :windows)))
               ((symbol-function 'drgnx-session-quit-confirm) (lambda () t))
               ((symbol-function 'select-frame-set-input-focus) #'ignore)
               ((symbol-function 'kill-emacs) (lambda (&rest _) (setq killed t)))
               ((symbol-function 'delete-frame)
                (lambda (&optional f _force) (push f deleted) (push 'delete-frame stock)))
               ((symbol-function 'save-buffers-kill-terminal) (lambda (&optional _) (push 'save-buffers-kill-terminal stock))))
       (ignore killed deleted stock)
       ,@body)))

(ert-deftest drgnx-session/c-x-c-x-c-in-quit-mode-on-the-last-window-quits ()
  (drgnx-session-close-keys-test--with (:keep-running nil :graphic t :windows (list (selected-frame)))
    (drgnx-session-kill-terminal nil)
    (should killed)
    (should-not deleted)
    (should-not stock)))

(ert-deftest drgnx-session/c-x-5-0-in-quit-mode-on-the-last-window-quits ()
  (drgnx-session-close-keys-test--with (:keep-running nil :graphic t :windows (list (selected-frame)))
    (drgnx-session-delete-frame)
    (should killed)
    (should-not deleted)))

(ert-deftest drgnx-session/close-keys-on-a-second-window-only-delete-that-window ()
  (dolist (cmd '(drgnx-session-kill-terminal drgnx-session-delete-frame))
    (drgnx-session-close-keys-test--with (:keep-running nil :graphic t :windows (list (selected-frame) 'f2))
      (funcall cmd)
      (should-not killed)
      (should (equal deleted (list (selected-frame)))))))

(ert-deftest drgnx-session/close-keys-in-keep-running-mode-close-the-window-and-stay ()
  (dolist (cmd '(drgnx-session-kill-terminal drgnx-session-delete-frame))
    (drgnx-session-close-keys-test--with (:keep-running t :graphic t :windows (list (selected-frame)))
      (funcall cmd)
      (should-not killed)
      (should (equal deleted (list (selected-frame)))))))

(ert-deftest drgnx-session/close-keys-in-a-terminal-frame-are-stock-emacs ()
  ;; A tty client leaves as in Emacs; the quit/keep choice is about the window.
  (drgnx-session-close-keys-test--with (:keep-running nil :graphic nil :windows (list (selected-frame)))
    (drgnx-session-kill-terminal nil)
    (drgnx-session-delete-frame)
    (should-not killed)
    (should (equal stock '(delete-frame save-buffers-kill-terminal)))))

(ert-deftest drgnx-session/setup-remaps-the-two-commands ()
  ;; Remapped as commands, so keys follow (`key-binding'); the functions themselves are untouched.
  (let* ((dir (make-temp-file "drgnx-session-keys" t))
         (process-environment (cons (concat "DRGNX_CONFIG_DIR=" dir) process-environment))
         (old (mapcar (lambda (c) (lookup-key global-map (vector 'remap c)))
                      '(save-buffers-kill-terminal delete-frame))))
    (unwind-protect
        (progn
          (drgnx-session-setup)
          (should (eq (lookup-key global-map [remap save-buffers-kill-terminal]) #'drgnx-session-kill-terminal))
          (should (eq (lookup-key global-map [remap delete-frame]) #'drgnx-session-delete-frame))
          (should (eq (key-binding (kbd "C-x C-c")) #'drgnx-session-kill-terminal))
          (should (eq (key-binding (kbd "C-x 5 0")) #'drgnx-session-delete-frame)))
      (define-key global-map [remap save-buffers-kill-terminal] (car old))
      (define-key global-map [remap delete-frame] (cadr old))
      (delete-directory dir t))))
