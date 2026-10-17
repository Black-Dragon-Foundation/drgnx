;;; agents-mirror-test.el --- batch tests: the editing Emacs mirrors the hub's agent sessions -*- lexical-binding: t -*-
;; The hub runs as its own process (as it does for the user); this Emacs plays the editor.
(require 'ert)
(require 'drgnx-agents)
(require 'drgnx-agents-mirror)
(require 'drgnx-hub)

(defmacro drgnx-agents-mirror-test--with (&rest body)
  "BODY with drgnx's dirs under ROOT, a hub process serving them (profile \"mock\" in its agents.eld), no mirrors yet."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-mirror" t)))
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

(defun drgnx-agents-mirror-test--wait (pred &optional secs)
  (let ((deadline (+ (float-time) (or secs 10)))) (while (and (not (funcall pred)) (< (float-time) deadline)) (accept-process-output nil 0.02)))
  (funcall pred))

(defun drgnx-agents-mirror-test--mirror (id) (seq-find (lambda (s) (equal (drgnx-agent-session-remote s) id)) drgnx-agents--sessions))

(defun drgnx-agents-mirror-test--text (s)
  (mapconcat (lambda (e) (format "%s" (or (plist-get e :text) ""))) (drgnx-agent-session-entries s) " "))

(defun drgnx-agents-mirror-test--start ()
  (let ((id (plist-get (drgnx-hub-call-sync "agents/start" (list :profile "mock" :cwd temporary-file-directory)) :id)))
    (drgnx-agents-mirror-test--wait
     (lambda () (eq (plist-get (car (read-from-string (plist-get (drgnx-hub-call-sync "agents/get" (list :id id)) :lisp))) :status) 'idle)))
    id))

(ert-deftest drgnx-agents-mirror/hub-sessions-appear-and-stay-current ()
  (drgnx-agents-mirror-test--with
    (let ((id (drgnx-agents-mirror-test--start)))
      (drgnx-agents-mirror-sync)
      (should (drgnx-agents-mirror-test--wait (lambda () (drgnx-agents-mirror-test--mirror id))))
      (let ((m (drgnx-agents-mirror-test--mirror id)))
        (should (eq (drgnx-agent-session-status m) 'idle))
        (should-not (drgnx-agent-session-conn m))                   ; a mirror: the agent runs in the hub
        (drgnx-agents-send m "hello mirror")
        (should (drgnx-agents-mirror-test--wait (lambda () (string-search "You said: hello mirror" (drgnx-agents-mirror-test--text m)))))))))

(ert-deftest drgnx-agents-mirror/actions-on-a-mirror-go-to-the-hub ()
  (drgnx-agents-mirror-test--with
    (let ((id (drgnx-agents-mirror-test--start)))
      (drgnx-agents-mirror-sync)
      (should (drgnx-agents-mirror-test--wait (lambda () (drgnx-agents-mirror-test--mirror id))))
      (let ((m (drgnx-agents-mirror-test--mirror id)))
        (drgnx-agents-send m "permission please")
        (should (drgnx-agents-mirror-test--wait (lambda () (drgnx-agent-session-permissions m))))
        (drgnx-agents-answer-permission m (car (drgnx-agent-session-permissions m)) "allow")
        (should (drgnx-agents-mirror-test--wait (lambda () (string-search "permission: allow" (drgnx-agents-mirror-test--text m)))))
        (drgnx-agents-kill m)
        (should (drgnx-agents-mirror-test--wait (lambda () (eq (drgnx-agent-session-status m) 'exited))))))))

(ert-deftest drgnx-agents-mirror/a-new-emacs-reattaches ()
  (drgnx-agents-mirror-test--with
    (let ((id (drgnx-agents-mirror-test--start)))
      (drgnx-agents-mirror-sync)
      (drgnx-agents-mirror-test--wait (lambda () (drgnx-agents-mirror-test--mirror id)))
      (drgnx-hub-call-sync "agents/send" (list :id id :text "slow work"))       ; it streams while this Emacs goes away
      (sleep-for 0.5)
      (drgnx-agents-mirror-stop) (drgnx-hub-disconnect) (setq drgnx-agents--sessions nil)
      (sleep-for 0.7)
      (drgnx-agents-mirror-sync)                                             ; a new editor
      (should (drgnx-agents-mirror-test--wait (lambda () (let ((m (drgnx-agents-mirror-test--mirror id)))
                                                           (and m (string-search "part 10" (drgnx-agents-mirror-test--text m)))))
                                              15))
      (drgnx-agents-mirror-test--wait (lambda () (eq (drgnx-agent-session-status (drgnx-agents-mirror-test--mirror id)) 'idle)))
      (sleep-for 0.3) (accept-process-output nil 0.2)
      ;; nothing lost: the mirror's transcript is the hub's
      (let ((hub (car (read-from-string (plist-get (drgnx-hub-call-sync "agents/get" (list :id id)) :entries)))))
        (should (equal (drgnx-agent-session-entries (drgnx-agents-mirror-test--mirror id)) hub))
        ;; and once the session is quiet (no event will come): a new editor still gets the whole transcript
        (drgnx-agents-mirror-stop) (drgnx-hub-disconnect) (setq drgnx-agents--sessions nil)
        (drgnx-agents-mirror-sync)
        (should (drgnx-agents-mirror-test--wait
                 (lambda () (let ((m (drgnx-agents-mirror-test--mirror id))) (and m (equal (drgnx-agent-session-entries m) hub))))
                 5))))))

;;; agents-mirror-test.el ends here
