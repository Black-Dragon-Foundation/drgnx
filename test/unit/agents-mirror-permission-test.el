;;; agents-mirror-permission-test.el --- batch tests: a permission request outlives the editor that saw it -*- lexical-binding: t -*-
;; test-class: timing
;; The hub runs as its own process (as it does for the user); this Emacs plays the editor, twice.
(require 'ert)
(require 'drgnx-agents)
(require 'drgnx-agents-mirror)
(require 'drgnx-hub-client)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/runtime-settings-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/unit/hub-client-test" drgnx-dir) nil t)   ; its Ratatoskr helpers

(defmacro drgnx-agents-mirror-permission-test--with (&rest body)
  "BODY with Ratatoskr serving drgnx's dirs under ROOT (profile \"mock\" in its settings.el), no mirrors yet; skipped
without the binary (`drgnx-hub-client-test--with-ratatoskr')."
  (declare (indent 0))
  `(drgnx-hub-client-test--with-ratatoskr
     (drgnx-hub-client-test--mock-profile root)
     (let ((drgnx-agents--sessions nil) (drgnx-agents-profiles nil))
       (unwind-protect (progn ,@body)
         (drgnx-agents-mirror-stop)))))

(defun drgnx-agents-mirror-permission-test--wait (pred &optional secs)
  (drgnx-test-wait pred :secs (max 30 (or secs 0)) :what "a mirror's condition"))

(defun drgnx-agents-mirror-permission-test--mirror (id) (seq-find (lambda (s) (equal (drgnx-agent-session-remote s) id)) drgnx-agents--sessions))

(defun drgnx-agents-mirror-permission-test--text (s)
  (mapconcat (lambda (e) (format "%s" (or (plist-get e :text) ""))) (drgnx-agent-session-entries s) " "))

(defun drgnx-agents-mirror-permission-test--start ()
  (let ((id (plist-get (drgnx-hub-call-sync "agents/start" (list :profile "mock" :cwd (getenv "HOME"))) :id)))   ; ROOT/home
    (drgnx-agents-mirror-permission-test--wait
     (lambda () (equal (plist-get (plist-get (drgnx-hub-call-sync "agents/get" (list :id id)) :session) :status) "idle")))
    id))

(ert-deftest drgnx-agents-mirror-permission/a-new-editor-sees-the-pending-request-and-answers-it ()
  :tags '(:timing)                                      ; a quiet machine: bin/drgnx check runs it alone
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
