;;; sandbox-fixture.el --- for the sandbox's escape tests: a fake user, their sockets, a repository and a hub -*- lexical-binding: t -*-
;; `drgnx-sandbox-fixture-with' runs BODY inside a user's world made under the test's temporary directory, every part
;; of it somewhere the sandbox must keep a job agent away from:
;;   - a HOME with canaries of random text (~/.ssh/id_canary, ~/other-repo/secret) and an agents.eld;
;;   - a runtime dir with an Emacs server, a D-Bus `bus' and an ssh-agent socket (`SSH_AUTH_SOCK'), each a listener that
;;     records every connection, and the environment variables that name them;
;;   - an abstract socket @drgnx-test-RAND and a TCP listener on the host's 127.0.0.1, the same;
;;   - a repository with a tracked file changed and not committed, an untracked .env, a remote URL holding a token, a
;;     branch job/fixture, a linked worktree (the task's folder), another task's folder and a standalone repository
;;     (the agent's own copy of a .git);
;;   - the hub served here (DRGNX_HUB_PARENT_PID names this Emacs), two open cards, and an empty work store.
;; `drgnx-sandbox-fixture-canaries' lists every random string planted: a test fails when one appears in a transcript.
;; `drgnx-sandbox-fixture-probe-env' is the MOCK_PROBE_* environment for the mock agent's `probe' word (a profile's :env):
;; paths and ids, never contents.  The macro skips with `drgnx-sandbox-check''s reason where the sandbox cannot run;
;; with :unsandboxed first in BODY it does not ask (the probes' own tests run the mock with no sandbox).
;; Nothing here reaches the real HOME, the user's runtime dir, bus or Emacs.
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-hub)
(require 'drgnx-coord)
(require 'drgnx-sandbox)

(defvar drgnx-sandbox-fixture-root nil "The fixture's temporary directory (a true name, a trailing slash).")
(defvar drgnx-sandbox-fixture-home nil "The fixture user's HOME.")
(defvar drgnx-sandbox-fixture-run nil "The fixture user's runtime directory.")
(defvar drgnx-sandbox-fixture-repo nil "The fixture repository (a true name, no trailing slash).")
(defvar drgnx-sandbox-fixture-folder nil "The task's folder: a linked worktree of the repository.")
(defvar drgnx-sandbox-fixture-own nil "A standalone repository, as the agent's own copy of a .git would be.")
(defvar drgnx-sandbox-fixture-cards nil "The two open cards' ids: (WITH-HELLO . WITHOUT-HELLO).")
(defvar drgnx-sandbox-fixture-probe-env nil "The MOCK_PROBE_* environment, a list of \"NAME=VALUE\" strings.")
(defvar drgnx-sandbox-fixture-abstract nil "The abstract socket's name, @drgnx-test-RAND.")
(defvar drgnx-sandbox-fixture-loopback nil "The TCP listener's \"127.0.0.1:PORT\".")
(defvar drgnx-sandbox-fixture--canaries nil)
(defvar drgnx-sandbox-fixture--listeners nil "The listening processes.")
(defvar drgnx-sandbox-fixture--connections nil "Alist listener name → connections it got.")

(defun drgnx-sandbox-fixture--random ()
  "64 hex digits nobody could guess."
  (random t)
  (secure-hash 'sha256 (format "%s|%s|%s|%s" (random) (random) (float-time) (emacs-pid))))

(defun drgnx-sandbox-fixture--canary ()
  "A new canary: random text, remembered."
  (let ((c (concat "canary-" (drgnx-sandbox-fixture--random))))
    (push c drgnx-sandbox-fixture--canaries)
    c))

(defun drgnx-sandbox-fixture-canaries ()
  "Every canary the fixture planted: files' contents, the token in a remote URL, a key in the environment."
  (copy-sequence drgnx-sandbox-fixture--canaries))

(defun drgnx-sandbox-fixture-connections ()
  "How many connections each listener got: ((NAME . COUNT)…), NAME one of emacs-server, bus, ssh-agent, abstract, loopback."
  (mapcar (lambda (l) (cons (car l) (cdr l))) drgnx-sandbox-fixture--connections))

(defun drgnx-sandbox-fixture--note (name)
  (cl-incf (alist-get name drgnx-sandbox-fixture--connections 0 nil #'equal)))

(defun drgnx-sandbox-fixture--listen (name &rest args)
  "A listener called NAME (see `drgnx-sandbox-fixture-connections') made with ARGS for `make-network-process'."
  (setf (alist-get name drgnx-sandbox-fixture--connections nil nil #'equal) 0)
  (let ((p (apply #'make-network-process :name (concat "fixture-" name) :server t :noquery t :filter #'ignore
                  :sentinel #'ignore :log (lambda (_server client _msg) (drgnx-sandbox-fixture--note name) (set-process-query-on-exit-flag client nil))
                  args)))
    (push p drgnx-sandbox-fixture--listeners)
    p))

(defun drgnx-sandbox-fixture--write (file text)
  (make-directory (file-name-directory file) t)
  (write-region text nil file nil 'silent))

(defun drgnx-sandbox-fixture--git (dir &rest args)
  "Run git ARGS in DIR; its output without the newline.  An error when it fails."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (unless (eql 0 (apply #'call-process "git" nil t nil "-c" "user.name=fixture" "-c" "user.email=fixture@example.invalid"
                            "-c" "init.defaultBranch=main" args))
        (error "git %S: %s" args (buffer-string)))
      (string-trim (buffer-string)))))

(defun drgnx-sandbox-fixture--repository (home)
  "Make the fixture repository under HOME and its neighbours; return an alist of the paths the probes use."
  (let* ((repo (concat home "/repo")) (git (concat repo "/.git"))
         (folder (concat repo "/.claude/worktrees/fixture-1"))
         (other (concat repo "/.claude/worktrees/other-1")) (own (concat repo "/.claude/worktrees/own-1"))
         (env (concat repo "/.env")) (dirty (concat repo "/tracked.txt"))
         (token (drgnx-sandbox-fixture--canary)) (blob nil))
    (make-directory repo t)
    (drgnx-sandbox-fixture--git repo "init" "-q")
    (drgnx-sandbox-fixture--write (concat repo "/README") "fixture\n")
    (drgnx-sandbox-fixture--write dirty "committed\n")
    (drgnx-sandbox-fixture--git repo "add" "README" "tracked.txt")
    (drgnx-sandbox-fixture--git repo "commit" "-q" "-m" "start")
    (drgnx-sandbox-fixture--git repo "branch" "job/fixture")
    (drgnx-sandbox-fixture--git repo "remote" "add" "origin" (format "https://fixture:%s@example.invalid/fixture.git" token))
    (drgnx-sandbox-fixture--git repo "worktree" "add" "-q" "-b" "job/fixture-1/work" folder "job/fixture")
    ;; what the user has not committed: a change to a tracked file, and an untracked .env
    (drgnx-sandbox-fixture--write dirty (concat "committed\n" (drgnx-sandbox-fixture--canary) "\n"))
    (drgnx-sandbox-fixture--write env (concat "API_KEY=" (drgnx-sandbox-fixture--canary) "\n"))
    ;; a loose object the object-delete probe can lose without hurting the repository's history
    (setq blob (with-temp-buffer
                 (let ((default-directory (file-name-as-directory repo)))
                   (insert (drgnx-sandbox-fixture--random))
                   (call-process-region (point-min) (point-max) "git" t t nil "hash-object" "-w" "--stdin")
                   (string-trim (buffer-string)))))
    (drgnx-sandbox-fixture--write (concat other "/file") (concat (drgnx-sandbox-fixture--canary) "\n"))
    (make-directory own t)
    (drgnx-sandbox-fixture--git own "init" "-q")
    `((:repo . ,repo) (:folder . ,folder) (:own . ,own) (:dot-env . ,env) (:dirty . ,dirty)
      (:config . ,(concat git "/config")) (:hook . ,(concat git "/hooks/post-merge"))
      (:ref-main . ,(concat git "/refs/heads/main")) (:ref-job . ,(concat git "/refs/heads/job/fixture"))
      (:pointer . ,(concat folder "/.git")) (:other-task . ,(concat other "/file"))
      (:object . ,(format "%s/objects/%s/%s" git (substring blob 0 2) (substring blob 2))))))

(defun drgnx-sandbox-fixture--call (unsandboxed body)
  "Run the function BODY in the fixture's world.  Skips when the sandbox cannot run, unless UNSANDBOXED."
  (unless unsandboxed
    (let ((check (drgnx-sandbox-check)))
      (unless (plist-get check :ok)
        (ert-skip (or (plist-get check :reason) "the sandbox cannot run here")))))
  (let* ((root (file-name-as-directory (directory-file-name (file-truename (make-temp-file "drgnx-sbfx" t)))))
         (home (concat root "home")) (run (concat root "run"))
         (drgnx-sandbox-fixture-root root) (drgnx-sandbox-fixture-home home) (drgnx-sandbox-fixture-run run)
         (drgnx-sandbox-fixture--canaries nil) (drgnx-sandbox-fixture--listeners nil) (drgnx-sandbox-fixture--connections nil)
         (drgnx-sandbox-fixture-abstract (format "@drgnx-test-%s" (substring (drgnx-sandbox-fixture--random) 0 12)))
         (drgnx-sandbox-fixture-loopback nil) (drgnx-sandbox-fixture-repo nil) (drgnx-sandbox-fixture-folder nil)
         (drgnx-sandbox-fixture-own nil) (drgnx-sandbox-fixture-cards nil) (drgnx-sandbox-fixture-probe-env nil)
         (api-key (drgnx-sandbox-fixture--canary))
         (process-environment
          (append (list (concat "HOME=" home) (concat "XDG_RUNTIME_DIR=" run) (concat "DRGNX_DATA_DIR=" root "data")
                        (concat "DRGNX_CONFIG_DIR=" home "/.config/drgnx") (concat "XDG_STATE_HOME=" root "state")
                        (concat "XDG_DATA_HOME=" root "xdg-data") (concat "XDG_CONFIG_HOME=" home "/.config")
                        (concat "SSH_AUTH_SOCK=" run "/ssh-agent.sock")
                        (concat "DBUS_SESSION_BUS_ADDRESS=unix:path=" run "/bus")
                        (concat "OPENROUTER_API_KEY=" api-key) (format "DRGNX_HUB_PARENT_PID=%d" (emacs-pid))
                        "DRGNX_NO_HUB_START=1" "GIT_CONFIG_GLOBAL=/dev/null" "GIT_CONFIG_NOSYSTEM=1"
                        "GIT_AUTHOR_NAME=fixture" "GIT_AUTHOR_EMAIL=fixture@example.invalid"
                        "GIT_COMMITTER_NAME=fixture" "GIT_COMMITTER_EMAIL=fixture@example.invalid")
                  process-environment))
         (drgnx-work-db--handles nil))
    (unwind-protect
        (progn
          (dolist (d (list (concat home "/.ssh") (concat home "/other-repo") (concat home "/.config/drgnx") (concat root "data")
                           (concat root "state") (concat run "/emacs")))
            (make-directory d t))
          (drgnx-sandbox-fixture--write (concat home "/.ssh/id_canary") (concat (drgnx-sandbox-fixture--canary) "\n"))
          (drgnx-sandbox-fixture--write (concat home "/other-repo/secret") (concat (drgnx-sandbox-fixture--canary) "\n"))
          (drgnx-sandbox-fixture--write (concat home "/.config/drgnx/agents.eld") "()\n")
          (let ((paths (drgnx-sandbox-fixture--repository home)))
            (setq drgnx-sandbox-fixture-repo (cdr (assq :repo paths)) drgnx-sandbox-fixture-folder (cdr (assq :folder paths))
                  drgnx-sandbox-fixture-own (cdr (assq :own paths)))
            ;; the user's sockets: listeners that count who connects
            (drgnx-sandbox-fixture--listen "emacs-server" :family 'local :service (concat run "/emacs/server"))
            (drgnx-sandbox-fixture--listen "bus" :family 'local :service (concat run "/bus"))
            (drgnx-sandbox-fixture--listen "ssh-agent" :family 'local :service (concat run "/ssh-agent.sock"))
            (drgnx-sandbox-fixture--listen "abstract" :family 'local :service (concat "\0" (substring drgnx-sandbox-fixture-abstract 1)))
            (let ((tcp (drgnx-sandbox-fixture--listen "loopback" :family 'ipv4 :host "127.0.0.1" :service t)))
              (setq drgnx-sandbox-fixture-loopback (format "127.0.0.1:%d" (aref (process-contact tcp :local) 4))))
            (drgnx-hub-serve (drgnx-hub-socket))
            (setq drgnx-sandbox-fixture-cards
                  (cons (drgnx-coord-card-create :job "fixture" :kind "probe" :title "A card the agent must not answer")
                        (drgnx-coord-card-create :job "fixture" :kind "probe" :title "A second one, for the call without hello")))
            (setq drgnx-sandbox-fixture-probe-env
                  (mapcar
                   (lambda (kv) (concat "MOCK_PROBE_" (car kv) "=" (cdr kv)))
                   `(("HUB_SOCKET" . ,(drgnx-hub-socket))
                     ("HUB_CAP" . ,(concat (file-name-sans-extension (drgnx-hub-socket)) ".cap"))
                     ("CARD" . ,(format "%s" (car drgnx-sandbox-fixture-cards)))
                     ("CARD_NO_HELLO" . ,(format "%s" (cdr drgnx-sandbox-fixture-cards)))
                     ("WORK_DB" . ,(concat (drgnx-data-dir) "/work.db"))
                     ("OTHER_AGENT" . "OTHER")
                     ("GIT_CONFIG" . ,(cdr (assq :config paths))) ("GIT_HOOKS" . ,(cdr (assq :hook paths)))
                     ("GIT_REF_MAIN" . ,(cdr (assq :ref-main paths))) ("GIT_REF_JOB" . ,(cdr (assq :ref-job paths)))
                     ("GIT_POINTER" . ,(cdr (assq :pointer paths))) ("GIT_OBJECT" . ,(cdr (assq :object paths)))
                     ("DOT_ENV" . ,(cdr (assq :dot-env paths))) ("DIRTY_FILE" . ,(cdr (assq :dirty paths)))
                     ("EMACS_SERVER" . ,(concat run "/emacs/server")) ("BUS" . ,(concat run "/bus"))
                     ("SSH_AGENT" . ,(concat run "/ssh-agent.sock")) ("ABSTRACT" . ,drgnx-sandbox-fixture-abstract)
                     ("LOOPBACK" . ,drgnx-sandbox-fixture-loopback)
                     ("SSH_KEY" . ,(concat home "/.ssh/id_canary")) ("OTHER_REPO" . ,(concat home "/other-repo/secret"))
                     ("OTHER_TASK" . ,(cdr (assq :other-task paths)))
                     ("NESTED" . ,(concat drgnx-sandbox-fixture-folder "/sub"))
                     ("OWN_GIT" . ,(concat drgnx-sandbox-fixture-own "/.git"))
                     ("FSMONITOR_CANARY" . ,(concat root "fsmonitor-canary"))))))
          (funcall body))
      (dolist (p drgnx-sandbox-fixture--listeners) (ignore-errors (delete-process p)))
      (dolist (p (process-list)) (when (string-prefix-p "fixture-" (process-name p)) (ignore-errors (delete-process p))))
      (ignore-errors (drgnx-hub-disconnect))
      (ignore-errors (drgnx-hub-stop))
      (ignore-errors (drgnx-work-db-close-all))
      (condition-case nil (delete-directory root t)
        (file-error (accept-process-output nil 0.3) (ignore-errors (delete-directory root t)))))))

(defmacro drgnx-sandbox-fixture-with (&rest body)
  "BODY in the fixture's world (see the file's header).  Skips when the sandbox cannot run here; with :unsandboxed as
the first form of BODY it never asks."
  (declare (indent 0) (debug t))
  (let ((unsandboxed (eq (car body) :unsandboxed)))
    `(drgnx-sandbox-fixture--call ,unsandboxed (lambda () ,@(if unsandboxed (cdr body) body)))))

(defun drgnx-sandbox-fixture-mock-profile (&optional name &rest props)
  "An agent profile NAME (\"mock\") that runs the mock ACP agent with the fixture's MOCK_PROBE_* environment.  PROPS
(for example :env more) are added; their :env goes after the probes'."
  (let ((env (append drgnx-sandbox-fixture-probe-env (plist-get props :env))))
    (append (list (or name "mock")
                  :command (list "sh" (expand-file-name "test/fixtures/mock-acp-stdin.sh" drgnx-dir)
                                 (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                 "-l" (expand-file-name "test/fixtures/mock-acp.el" drgnx-dir))
                  :env env)
            (cl-loop for (k v) on props by #'cddr unless (eq k :env) append (list k v)))))

(provide 'sandbox-fixture)
;;; sandbox-fixture.el ends here
