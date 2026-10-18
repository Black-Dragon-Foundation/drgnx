;;; agents-mirror-permission-test.el --- batch tests: a permission request outlives the editor that saw it -*- lexical-binding: t -*-
;; The hub runs as its own process (as it does for the user); this Emacs plays the editor, twice.
(require 'ert)
(require 'drgnx-agents)
(require 'drgnx-agents-mirror)
(require 'drgnx-hub)

(defmacro drgnx-agents-mirror-permission-test--with (&rest body)
  "BODY with drgnx's dirs under ROOT, a hub process serving them (profile \"mock\" in its agents.eld), no mirrors yet."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-mirror-perm" t)))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" root "config") (concat "DRGNX_DATA_DIR=" root "data")
                                             (concat "XDG_STATE_HOME=" root "state") "DRGNX_NO_HUB_START" "DRGNX_JOBS_LAUNCHER=detached")
                                       process-environment))
          (drgnx-agents--sessions nil) (drgnx-agents-profiles nil) (drgnx-hub-event-functions nil))
     (unwind-protect
         (progn
           (make-directory (concat root "config") t)
           (with-temp-file (concat root "config/agents.eld")
             (prin1 (list :profiles (list (list "mock" :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                                                      "-l" (expand-file-name "test/fixtures/mock-acp.el" drgnx-dir)))))
                    (current-buffer)))
           (drgnx-hub-ensure)
           ,@body)
       (ignore-errors (drgnx-hub-call-sync "shutdown" nil 3))
       (let ((deadline (+ (float-time) 5))) (while (and (drgnx-hub-running-p) (< (float-time) deadline)) (sleep-for 0.1)))
       (drgnx-agents-mirror-stop)
       (drgnx-hub-disconnect)
       (delete-directory root t))))

(defun drgnx-agents-mirror-permission-test--wait (pred &optional secs)
  (let ((deadline (+ (float-time) (or secs 10)))) (while (and (not (funcall pred)) (< (float-time) deadline)) (accept-process-output nil 0.02)))
  (funcall pred))

(defun drgnx-agents-mirror-permission-test--mirror (id) (seq-find (lambda (s) (equal (drgnx-agent-session-remote s) id)) drgnx-agents--sessions))

(defun drgnx-agents-mirror-permission-test--text (s)
  (mapconcat (lambda (e) (format "%s" (or (plist-get e :text) ""))) (drgnx-agent-session-entries s) " "))

(defun drgnx-agents-mirror-permission-test--start ()
  (let ((id (plist-get (drgnx-hub-call-sync "agents/start" (list :profile "mock" :cwd temporary-file-directory)) :id)))
    (drgnx-agents-mirror-permission-test--wait
     (lambda () (eq (plist-get (car (read-from-string (plist-get (drgnx-hub-call-sync "agents/get" (list :id id)) :lisp))) :status) 'idle)))
    id))

(ert-deftest drgnx-agents-mirror-permission/a-new-editor-sees-the-pending-request-and-answers-it ()
  (drgnx-agents-mirror-permission-test--with
    (let ((id (drgnx-agents-mirror-permission-test--start)))
      (drgnx-agents-mirror-sync)
      (should (drgnx-agents-mirror-permission-test--wait (lambda () (drgnx-agents-mirror-permission-test--mirror id))))
      (drgnx-agents-send (drgnx-agents-mirror-permission-test--mirror id) "permission please")
      (should (drgnx-agents-mirror-permission-test--wait
               (lambda () (drgnx-agent-session-permissions (drgnx-agents-mirror-permission-test--mirror id)))))
      ;; the editor goes away with the request unanswered
      (drgnx-agents-mirror-stop) (drgnx-hub-disconnect) (setq drgnx-agents--sessions nil)
      (should-not (drgnx-agents-mirror-permission-test--mirror id))
      ;; a new editor: the request is still there, and answering it lets the agent go on
      (drgnx-agents-mirror-sync)
      (should (drgnx-agents-mirror-permission-test--wait
               (lambda () (let ((m (drgnx-agents-mirror-permission-test--mirror id))) (and m (drgnx-agent-session-permissions m))))))
      (let* ((m (drgnx-agents-mirror-permission-test--mirror id)) (request (car (drgnx-agent-session-permissions m))))
        (should (plist-get request :id))
        (should (plist-get request :options))
        (drgnx-agents-answer-permission m request "allow")
        (should (drgnx-agents-mirror-permission-test--wait
                 (lambda () (string-search "permission: allow" (drgnx-agents-mirror-permission-test--text m)))))
        (should (drgnx-agents-mirror-permission-test--wait (lambda () (null (drgnx-agent-session-permissions m)))))))))

;;; agents-mirror-permission-test.el ends here
