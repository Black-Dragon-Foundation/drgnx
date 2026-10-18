;;; hub-agents-test.el --- batch tests: agent sessions held by the hub -*- lexical-binding: t -*-
;; The hub is served in this Emacs; its agents are the mock ACP agent (test/fixtures/mock-acp.el).
(require 'ert)
(require 'drgnx-hub)
(require 'drgnx-agents)
(require 'drgnx-coord)

(defmacro drgnx-hub-agents-test--with (&rest body)
  "BODY with drgnx's dirs under ROOT, the hub served here, profile \"mock\", EVENTS what subscribers heard."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-hub-agents" t)))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" root "config") (concat "DRGNX_DATA_DIR=" root "data")
                                             (concat "XDG_STATE_HOME=" root "state") "DRGNX_NO_HUB_START")
                                       process-environment))
          (drgnx-work-db--handles nil) (drgnx-agents--sessions nil) (drgnx-hub--exit-function #'drgnx-hub-stop)
          (drgnx-gateway--registrations (make-hash-table :test #'equal))
          (drgnx-agents-profiles
           (list (list "mock" :command (list "sh" (expand-file-name "test/fixtures/mock-acp-stdin.sh" drgnx-dir) (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                             "-l" (expand-file-name "test/fixtures/mock-acp.el" drgnx-dir)))))
          (events nil)
          (drgnx-hub-event-functions (list (lambda (e d) (push (cons e d) events)))))
     (unwind-protect
         (progn (make-directory (concat root "config") t)
                (drgnx-hub-serve (drgnx-hub-socket))
                (drgnx-hub-connect)
                ,@body)
       (dolist (s drgnx-agents--sessions) (ignore-errors (drgnx-agents-kill s)))
       (drgnx-hub-disconnect)
       (drgnx-hub-stop)
       (drgnx-work-db-close-all)
       (delete-directory root t))))

(defun drgnx-hub-agents-test--wait (pred &optional secs)
  (let ((deadline (+ (float-time) (or secs 10)))) (while (and (not (funcall pred)) (< (float-time) deadline)) (accept-process-output nil 0.02)))
  (funcall pred))

(defun drgnx-hub-agents-test--snapshot (id)
  (car (read-from-string (plist-get (drgnx-hub-call-sync "agents/get" (list :id id)) :lisp))))

(defun drgnx-hub-agents-test--text (id)
  "Everything in session ID's transcript, as the hub has it."
  (let ((entries (car (read-from-string (plist-get (drgnx-hub-call-sync "agents/get" (list :id id)) :entries)))))
    (mapconcat (lambda (e) (format "%s" (or (plist-get e :text) ""))) entries " ")))

(defun drgnx-hub-agents-test--start ()
  (let ((r (drgnx-hub-call-sync "agents/start" (list :profile "mock" :cwd temporary-file-directory))))
    (drgnx-hub-agents-test--wait (lambda () (eq (plist-get (drgnx-hub-agents-test--snapshot (plist-get r :id)) :status) 'idle)))
    (plist-get r :id)))

(ert-deftest drgnx-hub-agents/start-send-and-the-transcript ()
  (drgnx-hub-agents-test--with
    (let ((id (drgnx-hub-agents-test--start)))
      (should (string-prefix-p "s-" id))
      (drgnx-hub-call-sync "agents/send" (list :id id :text "hello hub"))
      (should (drgnx-hub-agents-test--wait (lambda () (string-search "You said: hello hub" (drgnx-hub-agents-test--text id)))))
      ;; subscribers heard it as it came
      (should (drgnx-hub-agents-test--wait
               (lambda () (seq-find (lambda (e) (and (equal (car e) "agent-entries")
                                                     (string-search "hello hub" (format "%s" (plist-get (cdr e) :entries)))))
                                    events))))
      (should (seq-find (lambda (e) (equal (car e) "agent")) events))
      (should (seq-find (lambda (s) (equal (plist-get (car (read-from-string s)) :id) id))
                        (plist-get (drgnx-hub-call-sync "agents/list" nil) :sessions))))))

(ert-deftest drgnx-hub-agents/the-agent-gets-the-coordination-tools ()
  (drgnx-hub-agents-test--with
    (drgnx-coord-job-create :id "j" :tasks '((:n 1 :title "one")))
    (let ((id (drgnx-hub-agents-test--start)))
      (drgnx-hub-call-sync "agents/send" (list :id id :text "coord task_status {\"job\":\"j\"}"))
      (should (drgnx-hub-agents-test--wait (lambda () (string-search "coord: " (drgnx-hub-agents-test--text id))) 15))
      (should (string-search "\"id\":\"j#1\"" (drgnx-hub-agents-test--text id)))
      ;; its identity is its session's id (a name repeats across hubs and editors; an id does not)
      (let ((env (plist-get (aref (drgnx-agents--mcp-servers (drgnx-agents-get id)) 0) :env)))
        (should (equal (plist-get (seq-find (lambda (e) (equal (plist-get e :name) "DRGNX_AGENT")) env) :value) id))))))

(ert-deftest drgnx-hub-agents/a-permission-waits-for-the-user ()
  (drgnx-hub-agents-test--with
    (let ((id (drgnx-hub-agents-test--start)))
      (drgnx-hub-call-sync "agents/send" (list :id id :text "permission please"))
      (should (drgnx-hub-agents-test--wait (lambda () (plist-get (drgnx-hub-agents-test--snapshot id) :permissions))))
      (let ((req (plist-get (car (plist-get (drgnx-hub-agents-test--snapshot id) :permissions)) :id)))
        (drgnx-hub-call-sync "agents/permission" (list :id id :request req :option "allow")))
      (should (drgnx-hub-agents-test--wait (lambda () (string-search "permission: allow" (drgnx-hub-agents-test--text id))))))))

(ert-deftest drgnx-hub-agents/sessions-outlive-the-client ()
  (drgnx-hub-agents-test--with
    (let* ((rc nil) (p (make-process :name "client" :noquery t :buffer nil
                                     :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                                    "--eval" "(setq load-prefer-newer t)" "-L" (expand-file-name "core" drgnx-dir)
                                                    "-l" "drgnx-hub"
                                                    "--eval" (format "(kill-emacs (if (drgnx-hub-call-sync \"agents/start\" (list :profile \"mock\" :cwd %S) 10) 0 1))"
                                                                     temporary-file-directory))
                                     :sentinel (lambda (p _) (unless (process-live-p p) (setq rc (process-exit-status p)))))))
      (ignore p)
      (should (drgnx-hub-agents-test--wait (lambda () rc) 20))
      (should (= rc 0))
      (let ((sessions (plist-get (drgnx-hub-call-sync "agents/list" nil) :sessions)))
        (should (= (length sessions) 1))
        (let ((id (plist-get (car (read-from-string (car sessions))) :id)))
          (should (drgnx-hub-agents-test--wait (lambda () (eq (plist-get (drgnx-hub-agents-test--snapshot id) :status) 'idle)))))))))

;;; hub-agents-test.el ends here
