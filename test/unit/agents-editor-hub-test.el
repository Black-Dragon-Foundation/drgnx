;;; agents-editor-hub-test.el --- batch tests: following an agent and the wheel against a real hub -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: gated
;; The hub runs as its own process; this Emacs plays the editor inside the delivery gate (`drgnx-test-gated').  The
;; agent is `ratatoskr-mock acp --as claude' (beside the hub's binary): what it did is a condition the test sees after
;; each release of the hub's lines (the helpers of agents-mirror-test.el), never a deadline.  Skipped without the hub.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-modules)
(require 'drgnx-agents)
(require 'drgnx-hub-client)
(load (expand-file-name "test/unit/agents-mirror-test" drgnx-dir) nil t)   ; its helpers and the hub fixtures
(load (expand-file-name "modules/tools/drgnx-agents-editor" drgnx-dir) nil t)   ; it loads the follow code
(defvar drgnx-hub-event-functions)
(defvar drgnx-agents-follow--session)
(defvar drgnx-agents-follow--view)
(defvar drgnx-agents-follow--window)
(declare-function drgnx-agents-follow-start "drgnx-agents-follow")
(declare-function drgnx-agents-follow-stop "drgnx-agents-follow")
(declare-function drgnx-agents-follow--event "drgnx-agents-follow")

(defmacro drgnx-agents-editor-hub-test--with (&rest body)
  "BODY with a gated hub whose profile \"asks\" is the mock Claude, the follow code listening to the hub's events and
this Emacs connected; `dir' is a folder with `a.txt' (twelve lines) inside the hub's root.  The module's own setup is
not used: the module fixture moves the config, and the hub's socket with it."
  (declare (indent 0))
  `(drgnx-agents-mirror-test--with '()
     (drgnx-agents-mirror-test--asking root)
     (save-window-excursion
       (delete-other-windows)
       (add-hook 'drgnx-hub-event-functions #'drgnx-agents-follow--event)
       (let* ((dir (file-name-as-directory (expand-file-name "work" root)))
              (file (expand-file-name "a.txt" dir)))
         (unwind-protect
             (progn
               (make-directory dir t)
               (write-region (mapconcat (lambda (i) (format "line %d\n" i)) (number-sequence 1 12) "") nil file nil 'silent)
               (drgnx-agents-mirror-sync)
               ,@body)
           (remove-hook 'drgnx-hub-event-functions #'drgnx-agents-follow--event)
           (drgnx-agents-follow-stop)
           (when-let* ((b (get-file-buffer file))) (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))))))

(defun drgnx-agents-editor-hub-test--start (dir &optional role)
  "Start the mock Claude in DIR (as ROLE, default worker); its session id, once its mirror is idle."
  (let ((id (plist-get (drgnx-agents-mirror-test--ask
                        "agents/start" (list :profile "asks" :role (or role "worker") :cwd (directory-file-name dir)))
                       :id)))
    (drgnx-agents-mirror-test--settle (lambda () (drgnx-agents-mirror-test--idle-mirror id)) "the new session's mirror, idle")
    id))

(defun drgnx-agents-editor-hub-test--line (window)
  (and (window-live-p window) (with-current-buffer (window-buffer window) (line-number-at-pos (window-point window) t))))

(ert-deftest drgnx-agents-editor-hub/follow-moves-with-the-agent ()
  (drgnx-agents-editor-hub-test--with
    (let ((id (drgnx-agents-editor-hub-test--start dir)))
      (drgnx-agents-follow-start id)
      (drgnx-agents-mirror-test--ask "agents/send" (list :id id :text (format "provider:read %s 7" file)))
      (drgnx-agents-mirror-test--settle
       (lambda () (equal 7 (drgnx-agents-editor-hub-test--line drgnx-agents-follow--window)))
       "the follow window on line 7 of the agent's file")
      (should (equal file (buffer-file-name (window-buffer drgnx-agents-follow--window))))
      (should (window-parameter drgnx-agents-follow--window 'header-line-format)))))

(ert-deftest drgnx-agents-editor-hub/follow-here-stops-on-navigation ()
  (drgnx-agents-editor-hub-test--with
    (let ((id (drgnx-agents-editor-hub-test--start dir)) (here (selected-window)) (view nil))
      (drgnx-agents-follow-start id t)
      (setq view drgnx-agents-follow--view)
      (drgnx-agents-mirror-test--ask "agents/send" (list :id id :text (format "provider:read %s 5" file)))
      (drgnx-agents-mirror-test--settle
       (lambda () (equal 5 (drgnx-agents-editor-hub-test--line here))) "the user's window on line 5 of the agent's file")
      (should (eq here drgnx-agents-follow--window))
      ;; any command in the window ends the follow, at the hub too
      (with-current-buffer (window-buffer here)
        (forward-line 1)
        (let ((this-command 'next-line)) (run-hooks 'post-command-hook)))
      (should-not drgnx-agents-follow--session)
      (should (memq (drgnx-agents-mirror-test--ask "agents/unfollow" (list :view view)) '(nil :json-false))))))

(provide 'agents-editor-hub-test)
;;; agents-editor-hub-test.el ends here
