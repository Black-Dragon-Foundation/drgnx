;;; agents-mirror-permission-test.el --- batch tests: a permission request outlives the editor that saw it -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: gated
;; The hub runs as its own process (as it does for the user); this Emacs plays the editor, twice.  The test runs inside
;; the delivery gate (`drgnx-test-gated'); the agent is a real child, so its progress is a condition the test sees in
;; the mirror after each release of the hub's lines.
(require 'ert)
(require 'drgnx-agents)
(require 'drgnx-agents-mirror)
(require 'drgnx-hub-client)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/ratatoskr-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/delivery-gate-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/runtime-settings-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/unit/hub-client-test" drgnx-dir) nil t)   ; its Ratatoskr helpers

(defmacro drgnx-agents-mirror-permission-test--with (schedule &rest body)
  "BODY inside `drgnx-test-gated' SCHEDULE (quoted, as there) with a gated Ratatoskr serving drgnx's dirs under ROOT
\(profile \"mock\" in its settings.el), this Emacs not connected, no mirrors yet; skipped without the binary
\(`drgnx-hub-client-test--with-hub')."
  (declare (indent 1))
  `(drgnx-hub-client-test--with-hub
     ;; the profile "mock" is `ratatoskr-mock acp' (beside the hub's binary); a worker's edits ask the user, so the hub
     ;; hands that permission request to the editor
     (drgnx-test-write-settings
      (concat root "config/settings.el")
      'drgnx-agents-profiles
      (list (list "mock" :provider 'claude
                  :command (list (expand-file-name "ratatoskr-mock" (file-name-directory (drgnx-hub-client-test--bin)))
                                 "acp" "--as" "claude")))
      'drgnx-agents-matrix '(:cells ((:action code.edit :column (:role worker) :verdict ask))))
     (let ((drgnx-agents--sessions nil) (drgnx-agents-profiles nil) (drgnx-test-gate-unnamed-ok t))
       (drgnx-test-gated ,schedule
         (unwind-protect (progn ,@body)
           (drgnx-agents-mirror-stop))))))

(defun drgnx-agents-mirror-permission-test--settle (pred what)
  "Wait until PRED holds, the hub's clock moved past its update throttle and what it has written released
\(`drgnx-test-hub-advance') before each look.  The agent is a real child: its progress is what PRED sees.  PRED's value."
  (drgnx-test-wait (lambda () (drgnx-test-hub-advance 100) (funcall pred)) :what what))

(defun drgnx-agents-mirror-permission-test--ask (method params)
  "The hub's answer (the result) to METHOD with PARAMS, asked without a wait of its own (no schedule step to meet)."
  (let (done result)
    (drgnx-hub-call method params (lambda (r _err) (setq result r done t)))
    (drgnx-agents-mirror-permission-test--settle (lambda () done) (format "the hub's answer to %s" method))
    result))

(defun drgnx-agents-mirror-permission-test--mirror (id) (seq-find (lambda (s) (equal (drgnx-agent-session-remote s) id)) drgnx-agents--sessions))

(defun drgnx-agents-mirror-permission-test--text (s)
  (mapconcat (lambda (e) (format "%s" (or (plist-get e :text) ""))) (drgnx-agent-session-entries s) " "))

(defun drgnx-agents-mirror-permission-test--start ()
  "Start a worker in the hub; its mirror once it is idle.  The caller's schedule has the answer to `agents/start', and
this Emacs mirrors the hub."
  (let ((id (plist-get (drgnx-agents-mirror-permission-test--ask "agents/start" (list :profile "mock" :cwd (getenv "HOME") :role "worker")) :id)))   ; ROOT/home
    (drgnx-agents-mirror-permission-test--settle
     (lambda () (let ((m (drgnx-agents-mirror-permission-test--mirror id))) (and m (eq (drgnx-agent-session-status m) 'idle) m)))
     "the new session's mirror, idle")))

(ert-deftest drgnx-agents-mirror-permission/a-new-editor-sees-the-pending-request-and-answers-it ()
  (drgnx-agents-mirror-permission-test--with '()
    (drgnx-agents-mirror-sync)
    (let* ((m (drgnx-agents-mirror-permission-test--start)) (id (drgnx-agent-session-remote m)) request gone)
      (drgnx-agents-send m "ask:permission edit")
      (drgnx-agents-mirror-permission-test--settle (lambda () (drgnx-agent-session-permissions m)) "the request in the first editor")
      ;; the editor goes away with the request unanswered
      (drgnx-agents-mirror-stop) (drgnx-hub-disconnect) (setq drgnx-agents--sessions nil)
      (setq gone (not (drgnx-agents-mirror-permission-test--mirror id)))
      ;; a new editor: the request is still there, and answering it lets the agent go on
      (drgnx-agents-mirror-sync)
      (setq m (drgnx-agents-mirror-permission-test--settle
               (lambda () (let ((m (drgnx-agents-mirror-permission-test--mirror id))) (and m (drgnx-agent-session-permissions m) m)))
               "the request in the new editor"))
      (setq request (car (drgnx-agent-session-permissions m)))
      (when (and (plist-get request :id) (plist-get request :options))
        (drgnx-agents-answer-permission m request "allow_once"))
      (drgnx-agents-mirror-permission-test--settle
       (lambda () (string-search "permission: allow_once" (drgnx-agents-mirror-permission-test--text m))) "the agent's word on the answer")
      (drgnx-agents-mirror-permission-test--settle (lambda () (null (drgnx-agent-session-permissions m))) "the request answered")
      (drgnx-test-deliver-all)
      (should gone)
      (should (plist-get request :id))
      (should (plist-get request :options)))))

;;; agents-mirror-permission-test.el ends here
