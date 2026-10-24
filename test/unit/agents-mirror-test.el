;;; agents-mirror-test.el --- batch tests: the editing Emacs mirrors the hub's agent sessions -*- lexical-binding: t -*-
;; The hub runs as its own process (as it does for the user); this Emacs plays the editor.
(require 'ert)
(require 'drgnx-agents)
(require 'drgnx-agents-mirror)
(require 'drgnx-records)
(require 'drgnx-hub)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/lisp-hub-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/runtime-settings-fixture" drgnx-dir) nil t)

(defmacro drgnx-agents-mirror-test--with (&rest body)
  "BODY with drgnx's dirs under ROOT, a hub process serving them (profile \"mock\" in its settings.el), no mirrors yet."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-mirror" t)))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" root "config") (concat "DRGNX_DATA_DIR=" root "data")
                                             (concat "XDG_STATE_HOME=" root "state") "DRGNX_NO_HUB_START" "DRGNX_JOBS_LAUNCHER=detached")
                                       process-environment))
          (drgnx-agents--sessions nil) (drgnx-agents-profiles nil) (drgnx-hub-event-functions nil))
     (unwind-protect
         (progn
           (make-directory (concat root "config") t)
           (setq drgnx-agents-profiles
                 (list (list "mock" :command (list "sh" (expand-file-name "test/fixtures/mock-acp-stdin.sh" drgnx-dir) (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                                   "-l" (expand-file-name "test/fixtures/mock-acp.el" drgnx-dir)))))
           (drgnx-test-write-settings (concat root "config/settings.el") 'drgnx-agents-profiles drgnx-agents-profiles)
           (drgnx-test-lisp-hub-ensure)
           ,@body)
       (ignore-errors (drgnx-hub-call-sync "shutdown" nil 3))
       (ignore-errors (drgnx-test-wait (lambda () (not (drgnx-hub-running-p))) :what "the hub gone"))
       ;; the socket goes while the hub still exits; its job's wrapper then writes the exit code into ROOT: ROOT is
       ;; removed once no job of it runs (the wrapper has ended)
       (ignore-errors (drgnx-test-wait (lambda () (not (seq-find (lambda (j) (eq (plist-get j :status) 'running)) (drgnx-jobs-list))))
                                       :what "the hub's job ended"))
       (drgnx-agents-mirror-stop)
       (drgnx-hub-disconnect)
       (delete-directory root t))))

(defun drgnx-agents-mirror-test--wait (pred &optional secs)
  (drgnx-test-wait pred :secs (max 30 (or secs 0)) :what "a mirror's condition"))

(defun drgnx-agents-mirror-test--mirror (id) (seq-find (lambda (s) (equal (drgnx-agent-session-remote s) id)) drgnx-agents--sessions))

(defun drgnx-agents-mirror-test--text (s)
  (mapconcat (lambda (e) (format "%s" (or (plist-get e :text) ""))) (drgnx-agent-session-entries s) " "))

(defun drgnx-agents-mirror-test--start ()
  (let ((id (plist-get (drgnx-hub-call-sync "agents/start" (list :profile "mock" :cwd temporary-file-directory)) :id)))
    (drgnx-agents-mirror-test--wait
     (lambda () (equal (plist-get (plist-get (drgnx-hub-call-sync "agents/get" (list :id id)) :session) :status) "idle")))
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

(ert-deftest drgnx-agents-mirror/when-the-hub-ends-its-mirrors-say-so ()
  ;; a hub's sessions are its children: they end with it, and the editor must not show them working
  (drgnx-agents-mirror-test--with
    (let ((id (drgnx-agents-mirror-test--start)))
      (drgnx-agents-mirror-sync)
      (should (drgnx-agents-mirror-test--wait (lambda () (drgnx-agents-mirror-test--mirror id))))
      (drgnx-hub-call-sync "shutdown" nil)
      (should (drgnx-agents-mirror-test--wait (lambda () (eq (drgnx-agent-session-status (drgnx-agents-mirror-test--mirror id)) 'exited))))
      (should (string-search "hub" (or (drgnx-agent-session-stderr (drgnx-agents-mirror-test--mirror id)) ""))))))

(ert-deftest drgnx-agents-mirror/a-new-emacs-reattaches ()
  (drgnx-agents-mirror-test--with
    (let ((id (drgnx-agents-mirror-test--start)))
      (drgnx-agents-mirror-sync)
      (drgnx-agents-mirror-test--wait (lambda () (drgnx-agents-mirror-test--mirror id)))
      (drgnx-hub-call-sync "agents/send" (list :id id :text "slow work"))       ; it streams while this Emacs goes away
      (drgnx-agents-mirror-test--wait (lambda () (string-search "part 1" (drgnx-agents-mirror-test--text (drgnx-agents-mirror-test--mirror id)))))
      (drgnx-agents-mirror-stop) (drgnx-hub-disconnect) (setq drgnx-agents--sessions nil)
      (drgnx-agents-mirror-test--wait (lambda () (string-search "part 3" (format "%S" (plist-get (drgnx-hub-call-sync "agents/get" (list :id id)) :entries)))))   ; it went on in the hub
      (drgnx-agents-mirror-sync)                                             ; a new editor
      (should (drgnx-agents-mirror-test--wait (lambda () (let ((m (drgnx-agents-mirror-test--mirror id)))
                                                           (and m (string-search "part 10" (drgnx-agents-mirror-test--text m)))))
                                              15))
      (drgnx-agents-mirror-test--wait (lambda () (eq (drgnx-agent-session-status (drgnx-agents-mirror-test--mirror id)) 'idle)))
      ;; nothing lost: the mirror's transcript is the hub's
      (let ((hub (mapcar (lambda (e) (drgnx-records-from-json 'drgnx-records-entry e))
                         (plist-get (drgnx-hub-call-sync "agents/get" (list :id id)) :entries))))
        (should (drgnx-agents-mirror-test--wait (lambda () (equal (drgnx-agent-session-entries (drgnx-agents-mirror-test--mirror id)) hub))))
        ;; and once the session is quiet (no event will come): a new editor still gets the whole transcript
        (drgnx-agents-mirror-stop) (drgnx-hub-disconnect) (setq drgnx-agents--sessions nil)
        (drgnx-agents-mirror-sync)
        (should (drgnx-agents-mirror-test--wait
                 (lambda () (let ((m (drgnx-agents-mirror-test--mirror id))) (and m (equal (drgnx-agent-session-entries m) hub))))
                 5))))))

;; From the old UI list ("a malformed RUN_STARTED aborting the board refresh"): one unreadable record from the
;; hub must not stop the others from being mirrored.
(ert-deftest drgnx-agents-mirror/a-malformed-session-record-does-not-abort-the-sync ()
  (let ((drgnx-agents--sessions nil) (drgnx-hub-event-functions nil) (drgnx-hub-disconnect-functions nil))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-hub-connect) #'ignore)
                  ((symbol-function 'drgnx-hub-call)
                   (lambda (method _params &optional cb)
                     (when (equal method "agents/list")
                       (funcall cb (list :sessions '((:id "bad" :name "cut off" :status "nonsense")
                                                     (:id "s-good" :name "Good" :status "idle")
                                                     42))
                                nil))))
                  ((symbol-function 'drgnx-agents-mirror--fetch) #'ignore))
          (let ((inhibit-message t)) (drgnx-agents-mirror-sync))
          (should (drgnx-agents-mirror-test--mirror "s-good"))
          (should-not (drgnx-agents-mirror-test--mirror "bad")))
      (drgnx-agents-mirror-stop))))

(ert-deftest drgnx-agents-mirror/a-malformed-transcript-entry-does-not-lose-the-others ()
  (let ((m (drgnx-agents--make :remote "s-x" :id "s-x")))
    (let ((inhibit-message t))
      (drgnx-agents-mirror--apply-entries m '((0 (:text "one")) (1 (:type "bogus")) (2 (:text "three")))))
    (should (equal (plist-get (nth 0 (drgnx-agent-session-entries m)) :text) "one"))
    (should (equal (plist-get (nth 2 (drgnx-agent-session-entries m)) :text) "three"))))

(ert-deftest drgnx-agents-mirror/an-old-snapshot-never-overwrites ()
  ;; a snapshot that came while the transcript was fetched, numbered before the fetch's answer, is older than it
  (let ((drgnx-agents--sessions nil) (answer nil))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-hub-call)
                   (lambda (method _params &optional cb) (when (equal method "agents/get") (setq answer cb)))))
          (let ((m (drgnx-agents--make :remote "s-o" :id "s-o")))
            (push m drgnx-agents--sessions)
            (drgnx-agents-mirror--fetch m)
            (drgnx-agents-mirror--event "agent" (list :id "s-o" :seq 3 :session '(:id "s-o" :name "old" :status "busy")))
            (funcall answer (list :seq 5 :session '(:id "s-o" :name "new" :status "idle") :entries '((:text "hi"))) nil)
            (should (equal (drgnx-agent-session-name m) "new"))
            (should (eq (drgnx-agent-session-status m) 'idle))
            ;; and later, live: an older number is skipped, a newer one applied
            (drgnx-agents-mirror--event "agent" (list :id "s-o" :seq 5 :session '(:id "s-o" :name "old" :status "busy")))
            (should (equal (drgnx-agent-session-name m) "new"))
            (drgnx-agents-mirror--event "agent" (list :id "s-o" :seq 6 :session '(:id "s-o" :name "newer" :status "idle")))
            (should (equal (drgnx-agent-session-name m) "newer"))))
      (drgnx-agents-mirror-stop))))

(ert-deftest drgnx-agents-mirror/a-record-that-does-not-decode-is-skipped ()
  ;; not an object, or an unknown entry type: never a snapshot or an entry
  (let ((drgnx-agents--sessions nil) (inhibit-message t) (m (drgnx-agents--make :remote "s-n" :id "s-n")))
    (drgnx-agents-mirror--event "agent" (list :id "s-n" :seq 1 :session 42))
    (should-not drgnx-agents--sessions)
    (drgnx-agents-mirror--apply-entries m '((0 (:type "no-such-type" :text "x")) (1 (:type "agent" :text "y"))))
    (should (equal (mapcar (lambda (e) (plist-get e :text)) (drgnx-agent-session-entries m)) '(nil "y")))))

(ert-deftest drgnx-agents-mirror/sessions-and-entries-arrive-as-json ()
  ;; a session from a mock-acp agent in a hub: status and entry types reach the mirror as symbols
  (drgnx-agents-mirror-test--with
    (let ((id (drgnx-agents-mirror-test--start)))
      (drgnx-hub-call-sync "agents/send" (list :id id :text "hello json"))
      (drgnx-agents-mirror-sync)
      (should (drgnx-agents-mirror-test--wait
               (lambda () (let ((m (drgnx-agents-mirror-test--mirror id)))
                            (and m (string-search "You said: hello json" (drgnx-agents-mirror-test--text m)))))))
      (let ((m (drgnx-agents-mirror-test--mirror id)))
        (should (memq (drgnx-agent-session-status m) '(busy idle)))
        (should (cl-every (lambda (e) (symbolp (plist-get e :type))) (drgnx-agent-session-entries m)))
        (should (memq 'agent (mapcar (lambda (e) (plist-get e :type)) (drgnx-agent-session-entries m))))))))

(ert-deftest drgnx-agents-mirror/no-read-of-hub-data ()
  (let ((drgnx-agents--sessions nil) (inhibit-message t))
    (cl-letf (((symbol-function 'drgnx-hub-call) #'ignore))
      (advice-add 'read-from-string :before #'drgnx-agents-mirror-test--no-read)
      (advice-add 'read :before #'drgnx-agents-mirror-test--no-read)
      (unwind-protect
          (progn
            (drgnx-agents-mirror--event "agent" (list :id "s-r" :seq 1 :session '(:id "s-r" :name "r" :status "idle")))
            (let ((m (drgnx-agents-mirror--find "s-r")))
              (should m)
              (clrhash drgnx-agents-mirror--fetching)       ; the transcript fetch (a no-op call here) is not waited on
              (drgnx-agents-mirror--event "agent-entries" (list :id "s-r" :seq 2 :entries '((0 (:type "agent" :text "hi")))))
              (should (equal (plist-get (car (drgnx-agent-session-entries m)) :text) "hi"))))
        (advice-remove 'read-from-string #'drgnx-agents-mirror-test--no-read)
        (advice-remove 'read #'drgnx-agents-mirror-test--no-read)))))

(defun drgnx-agents-mirror-test--no-read (&rest _) (error "The mirror read hub data as Lisp"))

(ert-deftest drgnx-agents-mirror/not-enforced-label ()
  (let ((drgnx-agents--sessions nil) (drgnx-agents-mirror--lock (make-hash-table :test #'equal)))
    (cl-letf (((symbol-function 'drgnx-notify) #'ignore))
      (let* ((snap (drgnx-records-from-json 'drgnx-records-session
                                            '(:id "h1" :name "a" :status "idle" :enforced_why "no sandbox here")))
             (m (car (drgnx-agents-mirror--apply-snapshot snap)))
             (ok (car (drgnx-agents-mirror--apply-snapshot
                       (drgnx-records-from-json 'drgnx-records-session '(:id "h2" :name "b" :status "idle" :enforced t))))))
        (should (equal (drgnx-agents-mirror-lock-label m) "not enforced: no sandbox here"))
        (should-not (drgnx-agents-mirror-lock-label ok))))))

(load (expand-file-name "test/unit/hub-client-test" drgnx-dir) nil t)   ; its Ratatoskr helpers

(ert-deftest drgnx-agents-mirror/start-goes-through-the-hub ()
  ;; a real Ratatoskr (mock profile): the editor's start is the hub's agents/start, and the mirror follows the session
  (drgnx-hub-client-test--with-ratatoskr
    (drgnx-hub-client-test--mock-profile root)
    (drgnx-hub-client-test--backend-up)
    (let ((drgnx-agents--sessions nil) (drgnx-agents-profiles nil) (drgnx-hub-event-functions nil))
      (unwind-protect
          (let* ((m (drgnx-agents-mirror-start "mock" root)) (id (drgnx-agent-session-remote m)))
            (should (stringp id))
            (should (seq-find (lambda (s) (equal (plist-get s :id) id))
                              (plist-get (drgnx-hub-call-sync "agents/list" nil 10) :sessions)))
            (should-not (drgnx-agent-session-conn m))                ; the agent runs in the hub
            (drgnx-hub-client-test--wait (lambda () (eq (drgnx-agent-session-status m) 'idle)) "the mirror is idle")
            (drgnx-agents-send m "hello hub")
            (drgnx-hub-client-test--wait
             (lambda () (string-search "hello hub" (drgnx-agents-mirror-test--text m))) "the mirror follows the session"))
        (drgnx-agents-mirror-stop)))))

;;; agents-mirror-test.el ends here
