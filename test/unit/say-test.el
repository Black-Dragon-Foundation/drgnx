;;; say-test.el --- batch tests: Say it, from the editor to a real hub and back -*- lexical-binding: t -*-
;; The hub runs as its own process; this Emacs plays the editor.  The planning agent is `ratatoskr-mock acp' (beside the
;; hub's binary) answering from a script with a proposal block, so no provider is called.  Each test runs inside the
;; delivery gate (a test-hooks Ratatoskr, `drgnx-test-gated'); the agent is a real child, so what it did is a condition the
;; test settles on after each release of the hub's lines, never a deadline.
;; test-class: cond
;; test-pattern: gated
(require 'ert)
(require 'cl-lib)
(require 'drgnx-say)
(require 'drgnx-notice)
(require 'drgnx-hub-client)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/ratatoskr-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/delivery-gate-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/runtime-settings-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/unit/hub-client-test" drgnx-dir) nil t)   ; its Ratatoskr helpers

(defconst drgnx-say-test--script
  (concat "say Here is the plan.\\nsay ```drgnx-proposal\\n"
          "say {\"title\": \"Docs pass\", \"tasks\": [{\"n\": 1, \"title\": \"Write the docs\", \"role\": \"docs\", "
          "\"deps\": [], \"body\": \"Write the settings docs.\"}], \"budget\": [{\"amount\": 5, \"unit\": \"usd\"}]}\\n"
          "say ```\n")
  "What the mock planning agent says to a prompt: one script line (the mock reads a literal backslash-n as a line break).")

(defvar drgnx-say-test--repo nil "The git repository of the test's prompt.")

(defmacro drgnx-say-test--with (&rest body)
  "BODY inside `drgnx-test-gated' with a gated Ratatoskr serving drgnx's dirs under ROOT, the profile \"mock-claude\" (the
scripted planning agent) routed for implement and docs, a git repository in `repo', this Emacs subscribed and
`drgnx-say-event' on the hub's events.  Skipped without the binary."
  (declare (indent 0))
  `(drgnx-hub-client-test--with-hub
     (let* ((repo (concat root "repo")) (script (concat root "say.txt")) (drgnx-say-test--repo repo)
            (drgnx-say--sessions nil) (drgnx-test-gate-unnamed-ok t))
       (make-directory repo t)
       (with-temp-file script (insert drgnx-say-test--script))
       (should (zerop (call-process "git" nil nil nil "-C" repo "init" "-q")))
       (should (zerop (call-process "git" nil nil nil "-C" repo "-c" "user.name=t" "-c" "user.email=t@t"
                                    "commit" "-q" "--allow-empty" "-m" "init")))
       (drgnx-test-write-settings
        (concat root "config/settings.el")
        'drgnx-agents-profiles
        (list (list "mock-claude" :provider 'claude
                    :command (list (expand-file-name "ratatoskr-mock" (file-name-directory (drgnx-hub-client-test--bin)))
                                   "acp" "--as" "claude" "--script" script)))
        'drgnx-agents-routes '((implement "mock-claude") (docs "mock-claude")))
       (drgnx-test-gated '()
         (unwind-protect
             (progn
               (add-hook 'drgnx-hub-event-functions #'drgnx-say-event)
               (drgnx-hub-connect)
               (drgnx-say-test--settle (lambda () (process-live-p drgnx-hub--events)) "the subscription")
               ,@body)
           (remove-hook 'drgnx-hub-event-functions #'drgnx-say-event)
           (drgnx-notice-clear 'hub))))))

(defun drgnx-say-test--settle (pred what)
  "Wait until PRED holds, the hub's clock moved and what it has written released before each look."
  (drgnx-test-wait (lambda () (drgnx-test-hub-advance 100) (funcall pred)) :what what))

(defun drgnx-say-test--ask (method params)
  "The hub's answer to METHOD with PARAMS as (RESULT . ERROR), asked without a wait of its own."
  (let (done answer)
    (drgnx-hub-call method params (lambda (r e) (setq answer (cons r e) done t)))
    (drgnx-say-test--settle (lambda () done) (format "the hub's answer to %s" method))
    answer))

(defun drgnx-say-test--notice ()
  "The proposal's notice, or nil."
  (cl-find-if (lambda (n) (eq (car-safe (plist-get n :command)) 'drgnx-say-show)) (drgnx-notices :source 'hub)))

(defun drgnx-say-test--proposed ()
  "Say a prompt in REPO and wait for the proposal's notice; its job id."
  (let ((default-directory (file-name-as-directory drgnx-say-test--repo)))
    (drgnx-say "write the settings docs"))
  (drgnx-say-test--settle #'drgnx-say-test--notice "the proposal's notice")
  (cadr (plist-get (drgnx-say-test--notice) :command)))

(ert-deftest drgnx-say/a-proposal-event-raises-a-notice ()
  (drgnx-say-test--with
    (let ((job (drgnx-say-test--proposed)))
      (drgnx-test-deliver-all)
      (let ((n (drgnx-say-test--notice)))
        (should (stringp job))
        (should (equal (plist-get n :command) (list 'drgnx-say-show job)))
        (should (eq (plist-get n :life) 'condition))))))

(ert-deftest drgnx-say/approve-starts-and-ends-the-session ()
  (drgnx-say-test--with
    (let* ((job (drgnx-say-test--proposed)) (session (drgnx-say--session job)))
      (drgnx-say-show job)
      (drgnx-say-test--settle (lambda () (with-current-buffer (drgnx-say--buffer-name job)
                                           (and (string-search "Docs pass" (buffer-string))
                                                (string-search "1. Write the docs" (buffer-string)))))
                              "the proposal's buffer")
      (with-current-buffer (drgnx-say--buffer-name job) (drgnx-say-approve))
      (drgnx-say-test--settle (lambda () (null (drgnx-say--session job))) "the session forgotten")
      (let ((status (plist-get (car (drgnx-say-test--ask "job/status" (list :id job))) :status))
            (again (drgnx-say-test--ask "say/revise" (list :id session :text "more"))))
        (drgnx-test-deliver-all)
        (should (equal status "running"))
        (should (cdr again))                     ; the planning stopped
        (should-not (drgnx-say-test--notice))))))

(ert-deftest drgnx-say/reject-stops-the-job ()
  (drgnx-say-test--with
    (let* ((job (drgnx-say-test--proposed)) (session (drgnx-say--session job)))
      (drgnx-say-show job)
      (drgnx-say-test--settle (lambda () (with-current-buffer (drgnx-say--buffer-name job)
                                           (string-search "Docs pass" (buffer-string))))
                              "the proposal's buffer")
      (with-current-buffer (drgnx-say--buffer-name job) (drgnx-say-reject))
      (drgnx-say-test--settle (lambda () (null (drgnx-say--session job))) "the session forgotten")
      (let ((status (plist-get (car (drgnx-say-test--ask "job/status" (list :id job))) :status))
            (again (drgnx-say-test--ask "say/revise" (list :id session :text "more"))))
        (drgnx-test-deliver-all)
        (should-not (equal status "running"))
        (should (cdr again))
        (should-not (drgnx-say-test--notice))))))

(ert-deftest drgnx-say/an-unproven-connection-raises-nothing ()
  ;; handshake-free: a stand-in connection that never proved itself (`:drgnx-proven' unset) carries the event
  (let ((conn (make-pipe-process :name "say-unproven" :noquery t :buffer nil)))
    (unwind-protect
        (let ((drgnx-hub--event-conn conn))
          (drgnx-say-event "say-proposal" (list :id "s1" :job "j1"))
          (drgnx-say-event "say-failed" (list :id "s1" :why "no"))
          (should-not (cl-find-if (lambda (n) (string-prefix-p "say-" (symbol-name (plist-get n :id))))
                                  (drgnx-notices :source 'hub))))
      (delete-process conn))))

;;; say-test.el ends here
