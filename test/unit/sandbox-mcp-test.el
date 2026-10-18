;;; sandbox-mcp-test.el --- batch tests: drgnx's MCP servers through a session's own socket -*- lexical-binding: t -*-
;; The hub side of a sandboxed session's MCP servers.  No sandbox runs here: the tests connect to the session's
;; sockets at their outside paths, through the bridge (as the agent does) or directly (as anything else in the
;; sandbox could).  Every path is in the test's temporary directory: its HOME, runtime, data and state dirs.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-sandbox-mcp)
(require 'drgnx-sandbox)
(require 'drgnx-coord)
(require 'drgnx-coord-mcp)
(require 'drgnx-work)

(defvar drgnx-sandbox-mcp-test--id 0)

(defmacro drgnx-sandbox-mcp-test--with (&rest body)
  "BODY with ROOT a temporary dir holding the environment's HOME, runtime, data and state dirs, and A and B two
sessions of job j (tasks 1 and 2).  Both are closed after."
  (declare (indent 0))
  `(let* ((root (directory-file-name (file-truename (make-temp-file "drgnx-sbm" t))))
          (process-environment (append (list (concat "HOME=" root "/home") (concat "XDG_RUNTIME_DIR=" root "/run")
                                             (concat "XDG_STATE_HOME=" root "/state") (concat "DRGNX_DATA_DIR=" root "/data")
                                             (concat "DRGNX_CONFIG_DIR=" root "/config"))
                                       process-environment))
          (drgnx-work-db--handles nil)
          (a (drgnx-agents--make :id "s-aaaa0001" :name "a" :cwd (concat root "/home") :job "j" :task "1"))
          (b (drgnx-agents--make :id "s-bbbb0002" :name "b" :cwd (concat root "/home") :job "j" :task "2")))
     (unwind-protect
         (progn
           (dolist (d '("/home" "/run" "/data" "/state" "/config")) (make-directory (concat root d) t))
           (drgnx-coord-job-create :id "j" :tasks '((:n 1 :title "one") (:n 2 :title "two")))
           ,@body)
       (drgnx-sandbox-mcp-close a)
       (drgnx-sandbox-mcp-close b)
       (drgnx-work-db-close-all)
       (delete-directory root t))))

(defun drgnx-sandbox-mcp-test--wait (pred &optional secs)
  "Wait until PRED is true (at most SECS, default 20): its value."
  (let ((deadline (+ (float-time) (or secs 20))) v)
    (while (and (not (setq v (funcall pred))) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    v))

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

(defun drgnx-sandbox-mcp-test--environ (pid)
  "PID's environment (Linux /proc), or nil where it cannot be read."
  (let ((file (format "/proc/%d/environ" pid)))
    (and (file-readable-p file)
         (split-string (with-temp-buffer (insert-file-contents-literally file) (buffer-string)) "\0" t))))

(ert-deftest drgnx-sandbox-mcp/identity-comes-from-the-socket ()
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
  (drgnx-sandbox-mcp-test--with
    (let* ((dir (drgnx-sandbox-mcp-open a (concat root "/home")))
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
    ;; B has no socket dir: today's stdio server, as B
    (should (equal (aref (drgnx-agents--mcp-servers b) 0) (drgnx-coord-mcp-server-spec "s-bbbb0002" :job "j" :task "2")))
    ;; A has one: the bridges replace the stdio servers
    (drgnx-sandbox-mcp-open a)
    (should (equal (drgnx-agents--mcp-servers a)
                   (vconcat (drgnx-sandbox-mcp-server-specs a (if (eq system-type 'darwin) (drgnx-agent-session-mcp-dir a)
                                                                "/run/drgnx")))))
    (should (equal (aref (drgnx-agents--mcp-servers b) 0) (drgnx-coord-mcp-server-spec "s-bbbb0002" :job "j" :task "2")))))

(ert-deftest drgnx-sandbox-mcp/search-only-when-asked ()
  (drgnx-sandbox-mcp-test--with
    (let ((da (drgnx-sandbox-mcp-open a)) (db (drgnx-sandbox-mcp-open b (concat root "/home"))))
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
        (should (member (concat root "/home") (process-command (car (drgnx-sandbox-mcp-test--servers b)))))))))

;;; sandbox-mcp-test.el ends here
