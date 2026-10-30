;;; sandbox-mcp-test.el --- batch tests: drgnx's MCP servers through a session's own socket -*- lexical-binding: t -*-
;; The hub side of a sandboxed session's MCP servers.  No sandbox runs here: the tests connect to the session's
;; sockets at their outside paths, through the bridge (as the agent does) or directly (as anything else in the
;; sandbox could).  Every path is in the test's temporary directory: its HOME, runtime, data and state dirs.
(require 'ert)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'cl-lib)
(require 'drgnx-sandbox-mcp)
(require 'drgnx-sandbox)
(require 'drgnx-sandbox-vc)
(require 'drgnx-coord)
(require 'drgnx-coord-mcp)
(require 'drgnx-work)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/work-fixture" drgnx-dir) nil t)   ; seeding as the hub's stand-in

(defvar drgnx-sandbox-mcp-test--id 0)

(defmacro drgnx-sandbox-mcp-test--with (&rest body)
  "BODY with ROOT a temporary dir holding the environment's HOME, runtime, data and state dirs, REPO a project in
HOME, TREE a task folder in it, and A and B two sessions of job j (tasks 1 and 2) working in TREE.  Both are closed
after."
  (declare (indent 0))
  `(let* ((root (directory-file-name (file-truename (make-temp-file "drgnx-sbm" t))))
          (repo (concat root "/home/repo")) (tree (concat repo "/.claude/worktrees/j-1"))
          (process-environment (append (list (concat "HOME=" root "/home") (concat "XDG_RUNTIME_DIR=" root "/run")
                                             (concat "XDG_STATE_HOME=" root "/state") (concat "DRGNX_DATA_DIR=" root "/data")
                                             (concat "DRGNX_CONFIG_DIR=" root "/config") "DRGNX_RATATOSKR_BIN=/usr/bin/true")
                                       process-environment))
          (drgnx-work-db--handles nil)
          (a (drgnx-agents--make :id "s-aaaa0001" :name "a" :profile "claude" :cwd tree :job "j" :task "1"))
          (b (drgnx-agents--make :id "s-bbbb0002" :name "b" :profile "claude" :cwd tree :job "j" :task "2"
                                 :mcp-sid "x2" :mcp-socket "/x/mcp.sock")))   ; b has a hub session (not sandboxed)
     (unwind-protect
         (progn
           (dolist (d '("/home" "/run" "/data" "/state" "/config")) (make-directory (concat root d) t))
           (make-directory tree t)
           (drgnx-work-fixture-as-hub (drgnx-coord-job-create :id "j" :tasks '((:n 1 :title "one") (:n 2 :title "two"))))
           ,@body)
       (drgnx-sandbox-mcp-close a)
       (drgnx-sandbox-mcp-close b)
       (drgnx-work-db-close-all)
       (delete-directory root t))))

(defun drgnx-sandbox-mcp-test--wait (pred &optional secs)
  "Wait until PRED is true (at most SECS, default 20): its value."
  (drgnx-test-wait pred :secs (or secs 20) :what "the sandbox condition"))

(defun drgnx-sandbox-mcp-test--collect (p s) (process-put p :out (concat (process-get p :out) s)))

(defun drgnx-sandbox-mcp-test--connect (sock)
  "A direct connection to SOCK, as anything inside the sandbox could make."
  (make-network-process :name "sbm-client" :family 'local :service sock :noquery t :coding 'utf-8-unix
                        :filter #'drgnx-sandbox-mcp-test--collect :sentinel #'ignore))

(defun drgnx-sandbox-mcp-test--bridge (sock)
  "The bridge to SOCK, started with a forged DRGNX_AGENT and DRGNX_JOB in its environment."
  (let ((process-environment (append '("DRGNX_AGENT=forged" "DRGNX_JOB=other") process-environment)))
    (make-process :name "sbm-bridge" :noquery t :connection-type 'pipe :coding 'utf-8-unix
                  :command (drgnx-mcp-bridge-command sock) :filter #'drgnx-sandbox-mcp-test--collect :sentinel #'ignore)))

(defun drgnx-sandbox-mcp-test--rpc (p method &optional params)
  "Send METHOD (PARAMS) on P and wait for its answer (a plist), or nil after 20 s."
  (let ((id (cl-incf drgnx-sandbox-mcp-test--id)))
    (process-send-string p (concat (json-serialize (list :jsonrpc "2.0" :id id :method method
                                                         :params (or params (make-hash-table))))
                                   "\n"))
    (drgnx-sandbox-mcp-test--wait
     (lambda ()
       (seq-find (lambda (j) (equal (plist-get j :id) id))
                 (mapcar (lambda (l) (ignore-errors (json-parse-string l :object-type 'plist :null-object nil
                                                                       :false-object nil)))
                         (split-string (or (process-get p :out) "") "\n" t)))))))

(defun drgnx-sandbox-mcp-test--whoami (p)
  "The identity the coordination server behind P answers `hello' with."
  (let* ((r (plist-get (drgnx-sandbox-mcp-test--rpc p "tools/call" (list :name "hello" :arguments (make-hash-table)))
                       :result))
         (text (plist-get (aref (plist-get r :content) 0) :text)))
    (should-not (plist-get r :isError))
    (plist-get (json-parse-string text :object-type 'plist :null-object nil) :agent)))

(defun drgnx-sandbox-mcp-test--servers (s)
  "The live servers the hub started for S's connections."
  (seq-filter (lambda (p) (and (process-live-p p) (eq (process-type p) 'real)
                               (equal (process-get p :drgnx-sandbox-mcp) (drgnx-agent-session-id s))))
              (process-list)))

(defun drgnx-sandbox-mcp-test--fake-git (root)
  "`process-environment' with a git first on PATH that only notes where it ran (`pwd -P', in ROOT/git-ran)."
  (let ((bin (concat root "/bin")))
    (make-directory bin t)
    (write-region (format "#!/bin/sh\npwd -P >> '%s/git-ran'\nexit 128\n" root) nil (concat bin "/git") nil 'silent)
    (set-file-modes (concat bin "/git") #o755)
    (cons (concat "PATH=" bin path-separator (getenv "PATH")) process-environment)))

(defun drgnx-sandbox-mcp-test--git-ran (root)
  "The dirs the fake git ran in, oldest first."
  (let ((file (concat root "/git-ran")))
    (and (file-exists-p file)
         (split-string (with-temp-buffer (insert-file-contents file) (buffer-string)) "\n" t))))

(defun drgnx-sandbox-mcp-test--call (p tool args)
  "Call TOOL with ARGS on P: (TEXT . IS-ERROR)."
  (let ((r (plist-get (drgnx-sandbox-mcp-test--rpc p "tools/call" (list :name tool :arguments args)) :result)))
    (cons (plist-get (aref (plist-get r :content) 0) :text) (plist-get r :isError))))

(defun drgnx-sandbox-mcp-test--environ (pid)
  "PID's environment (Linux /proc), or nil where it cannot be read."
  (let ((file (format "/proc/%d/environ" pid)))
    (and (file-readable-p file)
         (split-string (with-temp-buffer (insert-file-contents-literally file) (buffer-string)) "\0" t))))

(ert-deftest drgnx-sandbox-mcp/identity-comes-from-the-socket ()
  :tags '(:frozen)
  (drgnx-sandbox-mcp-test--with
    ;; the hub's own environment names someone else too: the server's identity is set from the session alone
    (let ((process-environment (append '("DRGNX_AGENT=hub-forged" "DRGNX_AGENT_KIND=claude" "DRGNX_TASK=9")
                                       process-environment))
          (dir (drgnx-sandbox-mcp-open a)) bridge)
      (unwind-protect
          (progn
            (setq bridge (drgnx-sandbox-mcp-test--bridge (expand-file-name "mcp.sock" dir)))
            (should (equal (drgnx-sandbox-mcp-test--whoami bridge) "s-aaaa0001"))
            (let* ((server (car (drgnx-sandbox-mcp-test--servers a)))
                   (env (and server (drgnx-sandbox-mcp-test--environ (process-id server)))))
              (should server)
              (when (eq system-type 'gnu/linux)
                (should (member "DRGNX_AGENT=s-aaaa0001" env))
                (should (member "DRGNX_JOB=j" env))
                (should (member "DRGNX_TASK=1" env))
                (should-not (seq-find (lambda (e) (string-prefix-p "DRGNX_AGENT_KIND=" e)) env))
                (should-not (member "DRGNX_AGENT=hub-forged" env)))))
        (when (process-live-p bridge) (delete-process bridge))))))

(ert-deftest drgnx-sandbox-mcp/one-session-cannot-reach-another ()
  :tags '(:frozen)
  (drgnx-sandbox-mcp-test--with
    (let* ((da (drgnx-sandbox-mcp-open a)) (db (drgnx-sandbox-mcp-open b))
           (a1 (drgnx-sandbox-mcp-test--connect (expand-file-name "mcp.sock" da)))
           (a2 (drgnx-sandbox-mcp-test--connect (expand-file-name "mcp.sock" da)))
           (b1 (drgnx-sandbox-mcp-test--connect (expand-file-name "mcp.sock" db))))
      (should-not (equal da db))
      (should (equal (drgnx-sandbox-mcp-test--whoami a1) "s-aaaa0001"))
      (should (equal (drgnx-sandbox-mcp-test--whoami b1) "s-bbbb0002"))
      (should (equal (drgnx-sandbox-mcp-test--whoami a2) "s-aaaa0001"))
      ;; A's sandbox gets A's dir alone: B's socket is never one it may name
      (should-not (drgnx-sandbox-validate (drgnx-sandbox-spec :run da :sockets (list (expand-file-name "mcp.sock" da)))))
      (should (string-match-p "not in the session's dir"
                              (drgnx-sandbox-validate (drgnx-sandbox-spec :run da :sockets (list (expand-file-name "mcp.sock" db))))))
      ;; B closed: A still answers as A
      (drgnx-sandbox-mcp-close b)
      (should-not (file-exists-p db))
      (should (equal (drgnx-sandbox-mcp-test--whoami a1) "s-aaaa0001")))))

(ert-deftest drgnx-sandbox-mcp/dir-is-private ()
  (drgnx-sandbox-mcp-test--with
    (let* ((dir (drgnx-sandbox-mcp-open a)) (top (file-name-directory dir)))
      (should (equal dir (concat root "/run/drgnx/s/s-aaaa0001")))
      (should (equal (drgnx-agent-session-mcp-dir a) dir))
      (dolist (d (list dir top))
        (should (= (file-modes d 'nofollow) #o700))
        (should (eql (file-attribute-user-id (file-attributes d)) (user-uid))))
      ;; the sandbox may bind it as the session's :run
      (should-not (drgnx-sandbox-validate (drgnx-sandbox-spec :run dir)))
      ;; a link planted where a session's dir goes is never followed
      (make-symbolic-link (concat root "/home") (concat top "s-link0003"))
      (should-error (drgnx-sandbox-mcp-dir "s-link0003"))
      ;; an id is a name, never a path
      (dolist (bad '("" "." ".." "../x" "a/b" "a\nb"))
        (should-error (drgnx-sandbox-mcp-dir bad)))
      ;; a socket's path fits 103 bytes, or there is none
      (should-error (drgnx-sandbox-mcp-dir (make-string 64 ?x))))))

(ert-deftest drgnx-sandbox-mcp/servers-end-with-the-connection ()
  :tags '(:frozen)
  (drgnx-sandbox-mcp-test--with
    (let* ((sock (expand-file-name "mcp.sock" (drgnx-sandbox-mcp-open a)))
           (c (drgnx-sandbox-mcp-test--connect sock)) server)
      ;; the connection closes: its server ends
      (should (equal (drgnx-sandbox-mcp-test--whoami c) "s-aaaa0001"))
      (setq server (car (drgnx-sandbox-mcp-test--servers a)))
      (should server)
      (delete-process c)
      (should (drgnx-sandbox-mcp-test--wait (lambda () (not (process-live-p server)))))
      ;; the server ends: its connection closes
      (setq c (drgnx-sandbox-mcp-test--connect sock))
      (should (drgnx-sandbox-mcp-test--whoami c))
      (setq server (car (drgnx-sandbox-mcp-test--servers a)))
      (delete-process server)
      (should (drgnx-sandbox-mcp-test--wait (lambda () (not (process-live-p c)))))
      ;; a line that is not a JSON object closes the connection and ends its server, unforwarded
      (setq c (drgnx-sandbox-mcp-test--connect sock))
      (should (drgnx-sandbox-mcp-test--whoami c))
      (setq server (car (drgnx-sandbox-mcp-test--servers a)))
      (process-send-string c "[1,2]\n")
      (should (drgnx-sandbox-mcp-test--wait (lambda () (not (or (process-live-p c) (process-live-p server))))))
      ;; a sandbox that opens many connections gets a few servers, not one each
      (let ((cs (cl-loop repeat (1+ drgnx-sandbox-mcp-max-connections) collect (drgnx-sandbox-mcp-test--connect sock))))
        (unwind-protect
            (progn
              (should (drgnx-sandbox-mcp-test--wait
                       (lambda () (= (cl-count-if-not #'process-live-p cs) 1))))
              (should (= (length (drgnx-sandbox-mcp-test--servers a)) drgnx-sandbox-mcp-max-connections)))
          (mapc #'delete-process cs))))))

(ert-deftest drgnx-sandbox-mcp/close-removes-everything ()
  :tags '(:frozen)
  (drgnx-sandbox-mcp-test--with
    (let* ((dir (drgnx-sandbox-mcp-open a repo))
           (c (drgnx-sandbox-mcp-test--connect (expand-file-name "mcp.sock" dir))))
      (should (drgnx-sandbox-mcp-test--whoami c))
      (should (drgnx-sandbox-mcp-test--servers a))
      (drgnx-sandbox-mcp-close a)
      (should-not (file-exists-p dir))
      (should-not (drgnx-agent-session-mcp-dir a))
      (should-not (seq-find (lambda (p) (and (process-live-p p) (equal (process-get p :drgnx-sandbox-mcp) "s-aaaa0001")))
                            (process-list)))
      (should (drgnx-sandbox-mcp-test--wait (lambda () (not (process-live-p c)))))
      ;; the session's end closes them too
      (setq dir (drgnx-sandbox-mcp-open a))
      (drgnx-agents-kill a)
      (should-not (file-exists-p dir))
      (should-not (drgnx-agent-session-mcp-dir a)))))

(ert-deftest drgnx-sandbox-mcp/entries-have-no-env ()
  (drgnx-sandbox-mcp-test--with
    (drgnx-sandbox-mcp-open a)
    (let ((entries (drgnx-sandbox-mcp-server-specs a "/run/drgnx"))
          (argv (drgnx-mcp-bridge-command "/run/drgnx/mcp.sock")))
      (should (equal (mapcar (lambda (e) (plist-get e :name)) entries) '("drgnx")))
      (let ((e (car entries)))
        (should (equal (plist-get e :env) []))
        (should (equal (cons (plist-get e :command) (append (plist-get e :args) nil)) argv))
        (should-not (seq-find (lambda (x) (string-search "s-aaaa0001" x))
                              (cons (plist-get e :command) (append (plist-get e :args) nil))))))))

(ert-deftest drgnx-sandbox-mcp/non-sandboxed-sessions-unchanged ()
  (drgnx-sandbox-mcp-test--with
    ;; B has no socket dir: the bridge to its hub session
    (should (equal (aref (drgnx-agents--mcp-servers b) 0) (drgnx-coord-mcp-server-spec (list :sid "x2" :socket "/x/mcp.sock"))))
    ;; A has one: the bridges replace the stdio servers
    (drgnx-sandbox-mcp-open a)
    (should (equal (drgnx-agents--mcp-servers a)
                   (vconcat (drgnx-sandbox-mcp-server-specs a (if (eq system-type 'darwin) (drgnx-agent-session-mcp-dir a)
                                                                "/run/drgnx")))))
    (should (equal (aref (drgnx-agents--mcp-servers b) 0) (drgnx-coord-mcp-server-spec (list :sid "x2" :socket "/x/mcp.sock"))))))

(ert-deftest drgnx-sandbox-mcp/search-only-when-asked ()
  (drgnx-sandbox-mcp-test--with
    (let ((da (drgnx-sandbox-mcp-open a)) (db (drgnx-sandbox-mcp-open b repo)))
      (should-not (file-exists-p (expand-file-name "search.sock" da)))
      (should (equal (mapcar (lambda (e) (plist-get e :name)) (drgnx-sandbox-mcp-server-specs a "/run/drgnx")) '("drgnx")))
      (should (file-exists-p (expand-file-name "search.sock" db)))
      (should (equal (mapcar (lambda (e) (plist-get e :name)) (drgnx-sandbox-mcp-server-specs b "/run/drgnx"))
                     '("drgnx" "drgnx-search")))
      (should (equal (plist-get (cadr (drgnx-sandbox-mcp-server-specs b "/run/drgnx")) :args)
                     (vconcat (cdr (drgnx-mcp-bridge-command "/run/drgnx/search.sock")))))
      ;; its socket reaches the search server, for the project asked for
      (let* ((c (drgnx-sandbox-mcp-test--connect (expand-file-name "search.sock" db)))
             (r (drgnx-sandbox-mcp-test--rpc c "initialize" (list :protocolVersion "2025-06-18" :capabilities (make-hash-table)
                                                                  :clientInfo (list :name "t" :version "1")))))
        (should (equal (plist-get (plist-get (plist-get r :result) :serverInfo) :name) "drgnx-search"))
        (should (member repo (process-command (car (drgnx-sandbox-mcp-test--servers b)))))))))

(ert-deftest drgnx-sandbox-mcp/search-path-pinned ()
  (drgnx-sandbox-mcp-test--with
    ;; the root is the project, given: never the task folder, nor anything in it
    (should-error (drgnx-sandbox-mcp-open a t))
    (should-error (drgnx-sandbox-mcp-open a tree))
    (should-error (drgnx-sandbox-mcp-open a (concat tree "/sub")))
    (should-not (drgnx-agent-session-mcp-dir a))
    (let* ((other (concat root "/home/other"))
           (process-environment (drgnx-sandbox-mcp-test--fake-git root))
           (dir (progn (make-directory other t) (drgnx-sandbox-mcp-open a repo)))
           (c (drgnx-sandbox-mcp-test--connect (expand-file-name "search.sock" dir))))
      ;; a `path' outside the root is refused; one inside searches the root
      (let ((r (drgnx-sandbox-mcp-test--call c "search" (list :query "x" :path other))))
        (should (cdr r))
        (should (string-match-p "outside" (car r))))
      (let ((r (drgnx-sandbox-mcp-test--call c "search" (list :query "x" :path tree))))
        (should (string-match-p (regexp-quote repo) (car r))))
      ;; and git ran neither in the other project nor in the task folder
      (should-not (seq-find (lambda (d) (not (equal d repo))) (drgnx-sandbox-mcp-test--git-ran root))))))

(ert-deftest drgnx-sandbox-mcp/search-root-not-a-guarded-folder ()
  (drgnx-sandbox-mcp-test--with
    ;; a folder Task 9's guard lists (a snapshot's task folder) is no search root, nor is anything in it
    (let ((guarded (concat root "/home/guarded")))
      (make-directory (concat guarded "/sub") t)
      (drgnx-sandbox-vc-register guarded)
      (should-error (drgnx-sandbox-mcp-open a guarded))
      (should-error (drgnx-sandbox-mcp-open a (concat guarded "/sub")))
      (should-not (drgnx-agent-session-mcp-dir a))
      ;; the project, unguarded, still opens
      (should (drgnx-sandbox-mcp-open a repo)))))

(ert-deftest drgnx-sandbox-mcp/job-hello-keeps-the-hubs-row ()
  :tags '(:frozen)
  (drgnx-sandbox-mcp-test--with
    ;; as `drgnx-job--launch-task' registers a job's agent
    (drgnx-coord-agent-register :id "s-aaaa0001" :kind "job" :name "a" :cwd tree :worktree tree :branch "job/j-1"
                                :base "abc1234")
    (let* ((process-environment (drgnx-sandbox-mcp-test--fake-git root))
           (c (drgnx-sandbox-mcp-test--connect (expand-file-name "mcp.sock" (drgnx-sandbox-mcp-open a))))
           (r (drgnx-sandbox-mcp-test--call c "hello" (list :cwd "/" :branch "evil" :name "someone else")))
           (hello (json-parse-string (car r) :object-type 'plist :null-object nil)))
      (should-not (cdr r))
      (should (equal (plist-get hello :agent) "s-aaaa0001"))
      (should (equal (plist-get hello :cwd) tree))
      (should (equal (plist-get hello :base) "abc1234"))
      (let ((row (drgnx-coord-agent "s-aaaa0001")))
        (should (equal (list (plist-get row :cwd) (plist-get row :worktree) (plist-get row :branch) (plist-get row :base)
                             (plist-get row :name))
                       (list tree tree "job/j-1" "abc1234" "a"))))
      ;; its edits are the task folder's
      (should-not (cdr (drgnx-sandbox-mcp-test--call c "report_edit" (list :paths (vector (concat tree "/a.el"))))))
      (should-not (drgnx-sandbox-mcp-test--git-ran root)))))

;;; sandbox-mcp-test.el ends here
