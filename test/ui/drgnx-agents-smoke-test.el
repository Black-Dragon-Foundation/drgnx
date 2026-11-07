;;; drgnx-agents-smoke-test.el --- the agent smoke script: recorded once, replayed from the recording -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; The script runs against a real hub in its own process (as for the user), this Emacs playing the editor: two
;; worker sessions, each editing a toy project, asking for the edit's permission, answering it, recording a decision
;; through the hub's MCP tool and committing.  The same script runs three ways (docs/develop/recordings.md):
;;  - DRGNX_RECORD=DIR (`bin/drgnx record start'): the outside ends are recorded; with DRGNX_SMOKE_PROFILES=mock they
;;    are the scripted mocks, with `live' the user's own profiles (a host session, never started by an agent);
;;  - DRGNX_REPLAY=DIR (`bin/drgnx replay'): the outside ends come from that recording;
;;  - neither (every normal run): the repository's fixture test/fixtures/recordings/smoke-mock, replayed at speed 0
;;    with every recorded line used (strict).
;; Its asserts hold in all three: the permission card shows, the reply arrives, the decision is in work.db, the
;; sessions end.  On a replay it adds: the normalized transcript equals the recording's, and there are no misses.
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'drgnx-agents)
(require 'drgnx-agents-mirror)
(require 'drgnx-hub-client)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/ratatoskr-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/runtime-settings-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/hub-client-fixture" drgnx-dir) nil t)   ; its Ratatoskr helpers

(defconst drgnx-agents-smoke--fixture "test/fixtures/recordings/smoke-mock"
  "The repository's recording of the script made from the mocks, relative to the checkout.")

(defconst drgnx-agents-smoke--live-profiles '("claude (Kimi via OpenRouter)" "claude")
  "The live run's profiles, in the user's own settings: a gateway profile, then the Claude subscription.")

(defvar drgnx-agents-smoke--user-config nil "The user's own config dir, captured before the run's roots replace it.")

(defun drgnx-agents-smoke--mode ()
  "`record', `replay' or `fixture': what the environment asks for."
  (cond ((getenv "DRGNX_RECORD") 'record)
        ((getenv "DRGNX_REPLAY") 'replay)
        (t 'fixture)))

(defun drgnx-agents-smoke--live-p ()
  "Whether this run is the live one (DRGNX_SMOKE_PROFILES=live)."
  (equal (getenv "DRGNX_SMOKE_PROFILES") "live"))

(defun drgnx-agents-smoke--git (dir &rest args)
  "git ARGS in DIR with a fixed identity and fixed dates, so the toy project's commit is the same everywhere."
  (let ((process-environment (append (list "GIT_AUTHOR_DATE=2026-01-01T00:00:00Z" "GIT_COMMITTER_DATE=2026-01-01T00:00:00Z"
                                           "GIT_CONFIG_GLOBAL=/dev/null" "GIT_CONFIG_SYSTEM=/dev/null")
                                     process-environment))
        (default-directory (file-name-as-directory dir)))
    (with-temp-buffer
      (unless (eql 0 (apply #'call-process "git" nil t nil "-c" "user.name=smoke" "-c" "user.email=smoke@example.invalid"
                            "-c" "commit.gpgsign=false" args))
        (error "git %s failed: %s" args (buffer-string))))))

(defun drgnx-agents-smoke--project (dir)
  "The toy project in DIR: hello.txt and hello2.txt, one commit."
  (make-directory dir t)
  (write-region "hello\n" nil (expand-file-name "hello.txt" dir) nil 'silent)
  (write-region "hello two\n" nil (expand-file-name "hello2.txt" dir) nil 'silent)
  (drgnx-agents-smoke--git dir "init" "-q" "-b" "main")
  (drgnx-agents-smoke--git dir "add" "hello.txt" "hello2.txt")
  (drgnx-agents-smoke--git dir "commit" "-q" "-m" "base")
  dir)

(defun drgnx-agents-smoke--profiles (root)
  "The profile names of the run, with ROOT's settings.el holding them: the mocks (a gateway profile and a plain one),
or, for the live run, the user's own (their settings.el, read here and copied)."
  (let ((names (if (drgnx-agents-smoke--live-p) drgnx-agents-smoke--live-profiles '("mock-gateway" "mock-claude")))
        (matrix '(:cells ((:action code.edit :column (:role worker) :verdict ask)))))
    (if (drgnx-agents-smoke--live-p)
        (let ((own (expand-file-name "settings.el" drgnx-agents-smoke--user-config)))
          ;; their profiles and permission matrix as they are (the worker's edits ask, as in the mocks' run)
          (when (file-readable-p own) (copy-file own (concat root "config/settings.el") t)))
      (let ((mock (expand-file-name "ratatoskr-mock" (file-name-directory (drgnx-hub-client-test--bin)))))
        (drgnx-test-write-settings
         (concat root "config/settings.el")
         'drgnx-agents-profiles (mapcar (lambda (n) (list n :provider 'claude :command (list mock "acp" "--as" "claude"))) names)
         'drgnx-agents-matrix matrix)))
    names))

(defun drgnx-agents-smoke--wait (pred what)
  (drgnx-hub-client-test--wait pred what))

(defun drgnx-agents-smoke--mirror (id)
  (seq-find (lambda (s) (equal (drgnx-agent-session-remote s) id)) drgnx-agents--sessions))

(defun drgnx-agents-smoke--text (s)
  (mapconcat (lambda (e) (format "%s" (or (plist-get e :text) ""))) (drgnx-agent-session-entries s) " "))

(defun drgnx-agents-smoke--turn (profile project file subject)
  "One worker session on PROFILE in PROJECT: the edit of FILE, its permission (the card shows; allowed), a decision
about SUBJECT and a commit; then the session is killed.  The session's transcript text."
  (let* ((id (plist-get (drgnx-hub-call-sync "agents/start" (list :profile profile :cwd project :role "worker") 30) :id))
         (m (drgnx-agents-smoke--wait
             (lambda () (let ((s (drgnx-agents-smoke--mirror id))) (and s (eq (drgnx-agent-session-status s) 'idle) s)))
             (format "%s's session, idle" profile)))
         request text)
    (drgnx-agents-mirror-show id)
    (drgnx-agents-send m (format "tool:edit %s\nask:permission edit\ncall:record_decision {\"kind\": \"build\", \"subject\": \"%s\", \"reason\": \"the smoke\", \"seen_version\": 0}\ncommit smoke"
                                 file subject))
    (drgnx-agents-smoke--wait (lambda () (drgnx-agent-session-permissions m)) "the permission card")
    (setq request (car (drgnx-agent-session-permissions m)))
    (should (plist-get request :id))
    (should (plist-get request :options))
    (drgnx-agents-answer-permission m request "allow_once")
    (drgnx-agents-smoke--wait (lambda () (and (string-search "committed: smoke" (drgnx-agents-smoke--text m))
                                              (eq (drgnx-agent-session-status m) 'idle)))
                              "the reply: the commit")
    (setq text (drgnx-agents-smoke--text m))
    (drgnx-agents-kill m)
    (drgnx-agents-smoke--wait (lambda () (eq (drgnx-agent-session-status m) 'exited)) "the session ends")
    text))

(defun drgnx-agents-smoke--normalize (text root)
  "TEXT with ROOT and the hub's session ids named, so two runs' transcripts agree."
  (replace-regexp-in-string
   "\\<a[0-9a-f]\\{12\\}\\>" "$SID"
   (replace-regexp-in-string (regexp-quote (directory-file-name root)) "$ROOT" text t t) t t))

(defun drgnx-agents-smoke--decisions (root)
  "The number of decision rows in ROOT's work.db (nil: no way to read it here)."
  (let ((file (expand-file-name "data/work.db" root)))
    (when (and (fboundp 'sqlite-open) (file-exists-p file))
      (let ((db (sqlite-open file)))
        (unwind-protect (caar (sqlite-select db "select count(*) from decision"))
          (sqlite-close db))))))

(defun drgnx-agents-smoke--bundle (dir transcript root)
  "Into DIR/bundle: the normalized TRANSCRIPT and a backup of the hub's work.db (the hub makes the copy in ROOT/data)."
  (let ((bundle (expand-file-name "bundle" dir)))
    (make-directory bundle t)
    (let ((coding-system-for-write 'utf-8-unix))
      (with-temp-file (expand-file-name "transcript.json" bundle)
        (insert (json-serialize (apply #'vector transcript)) "\n")))
    (let* ((r (ignore-errors (drgnx-hub-call-sync "graph/backup" nil 60)))
           (path (plist-get r :path)))
      (when (and (stringp path) (file-readable-p path) (string-prefix-p root path))
        (copy-file path (expand-file-name "work.db" bundle) t)))))

(defun drgnx-agents-smoke--recorded-transcript (dir)
  "The transcript of the recording DIR: its fixture file, else its bundle's."
  (let ((file (seq-find #'file-exists-p (list (expand-file-name "transcript.json" dir)
                                              (expand-file-name "bundle/transcript.json" dir)))))
    (unless file (ert-fail (format "no transcript.json in the recording %s" dir)))
    (let ((coding-system-for-read 'utf-8))
      (with-temp-buffer (insert-file-contents file) (json-parse-buffer :array-type 'list)))))

(defun drgnx-agents-smoke--misses ()
  "The replay's misses file's text, or the empty string."
  (let ((file (expand-file-name "replay/misses.jsonl" (or (getenv "DRGNX_RUN_TMP") (getenv "TMPDIR") "/tmp"))))
    (if (file-exists-p file) (with-temp-buffer (insert-file-contents file) (buffer-string)) "")))

(defun drgnx-agents-smoke--script (root mode replay)
  "The script against the hub serving ROOT, in MODE (`record', `replay' or `fixture'); REPLAY is the recording
replayed, or nil."
  (let* ((names (drgnx-agents-smoke--profiles root))
         (project (drgnx-agents-smoke--project (concat root "home/smoke-project")))
         (drgnx-agents--sessions nil) (drgnx-hub-event-functions nil)
         transcript decisions)
    (unwind-protect
        (progn
          (drgnx-agents-mirror-sync)
          (setq transcript
                (list (drgnx-agents-smoke--turn (nth 0 names) project "hello.txt" "smoke ok")
                      (drgnx-agents-smoke--turn (nth 1 names) project "hello2.txt" "smoke ok two")))
          (setq decisions (drgnx-agents-smoke--decisions root))
          (setq transcript (mapcar (lambda (tx) (drgnx-agents-smoke--normalize tx root)) transcript))
          (when (eq mode 'record)
            (drgnx-agents-smoke--bundle (getenv "DRGNX_RECORD") transcript root)))
      (drgnx-agents-mirror-stop))
    ;; what holds in every mode
    (should (cl-every (lambda (tx) (string-search "committed: smoke" tx)) transcript))
    (when decisions (should (>= decisions 1)))
    ;; the replays: the same transcript, and nothing the recording did not have
    (when replay
      (should (equal transcript (drgnx-agents-smoke--recorded-transcript replay)))
      (should (equal (drgnx-agents-smoke--misses) "")))))

(ert-deftest drgnx-agents-smoke/two-sessions-edit-ask-decide-and-commit ()
  (let* ((mode (drgnx-agents-smoke--mode))
         (fixture (expand-file-name drgnx-agents-smoke--fixture drgnx-dir))
         (drgnx-agents-smoke--user-config (drgnx-user-dir))
         (process-environment
          (if (eq mode 'fixture)
              (append (list (concat "DRGNX_REPLAY=" fixture) "DRGNX_REPLAY_SPEED=0" "DRGNX_REPLAY_STRICT=1")
                      process-environment)
            process-environment))
         (replay (cond ((eq mode 'fixture) fixture) ((eq mode 'replay) (getenv "DRGNX_REPLAY")))))
    (when (and replay (not (file-exists-p (expand-file-name "manifest.json" replay))))
      (ert-fail (format "no recording at %s" (if (eq mode 'fixture) drgnx-agents-smoke--fixture replay))))
    (drgnx-hub-client-test--with-ratatoskr
      (drgnx-agents-smoke--script root mode replay))))

;;; drgnx-agents-smoke-test.el ends here
