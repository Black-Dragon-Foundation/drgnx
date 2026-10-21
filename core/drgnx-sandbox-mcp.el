;;; drgnx-sandbox-mcp.el --- drgnx's MCP servers for a sandboxed agent, through its own socket -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A sandboxed agent cannot run drgnx's MCP servers itself: inside it has no work.db, no hub socket and no keys.  So
;; the hub runs them outside.  Each sandboxed session SID gets a private dir, s/SID/ beside the hub's socket
;; (`drgnx-sandbox-mcp-dir'), which the sandbox binds as its `:run' (/run/drgnx on Linux).  The hub listens there on
;; mcp.sock (coordination) and, when asked, search.sock.  For each connection it starts the real server outside,
;; with an identity it sets itself: DRGNX_AGENT is SID, DRGNX_JOB and DRGNX_TASK are the session's.  The socket a
;; connection comes in on is the capability, and nothing inside the sandbox names the agent.  The agent reaches the
;; socket through its bridge (drgnx-mcp-bridge.el).
;;
;; Every byte from the socket is hostile.  A line is at most `drgnx-mcp-bridge-max-line' bytes and one JSON object,
;; or the connection closes.  A peer that stops reading is dropped the way a hub client is (`drgnx-hub--enqueue').
;; At most `drgnx-sandbox-mcp-max-connections' connections per socket get a server.  A connection and its server end
;; together, and all of them end with the session (`drgnx-sandbox-mcp-close').  See docs/develop/hub.md,
;; "Per-session sockets".

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-guard)
(require 'drgnx-hub-client)
(require 'drgnx-agents)
(require 'drgnx-mcp-bridge)
(require 'drgnx-sandbox-vc)

(declare-function drgnx-coord-mcp-server-spec "drgnx-coord-mcp" (agent &rest props))
(declare-function drgnx-search-mcp-server-spec "drgnx-search-mcp" (root))

(defconst drgnx-sandbox-mcp-inside "/run/drgnx"
  "Where a session's dir is inside a Linux sandbox: `drgnx-sandbox-bwrap-argv' binds `:run' there.")

(defconst drgnx-sandbox-mcp--sockets '("mcp.sock" "search.sock" "hub.sock")
  "The sockets a session's dir may hold: each one's path must fit a socket address.  hub.sock is kept for the hub
protocol's agent class, which is not served yet.")

(defvar drgnx-sandbox-mcp-max-connections 4
  "Connections one session's socket serves at once.  Each one starts a server outside the sandbox, so a sandbox that
opens more has them closed at once.")

;;;; Where

(defun drgnx-sandbox-mcp--valid-id (sid)
  "SID when it can name a dir (letters, digits, `-' and `_', at most 64), else an error: it is never a path."
  (if (and (stringp sid) (let ((case-fold-search nil)) (string-match-p "\\`[A-Za-z0-9][A-Za-z0-9_-]\\{0,63\\}\\'" sid)))
      sid
    (error "Not a session id for a socket dir: %S" sid)))

(defun drgnx-sandbox-mcp-dir (sid)
  "Session SID's own socket dir, made: s/SID beside the hub's socket — $XDG_RUNTIME_DIR/drgnx/s/SID, or s/SID beside
the hub socket's fallback place — so it is one of `drgnx-sandbox-sessions-dirs'' and a sandbox may bind it as
`:run'.  Each level is made by `drgnx-hub--private-dir' (0700, this user's, never a link).  An error when a socket in
it would pass 103 bytes.  Returned without a trailing slash."
  (let* ((hub (file-name-directory (drgnx-hub-socket)))
         (top (expand-file-name "s" hub))
         (dir (expand-file-name (drgnx-sandbox-mcp--valid-id sid) top)))
    (dolist (name drgnx-sandbox-mcp--sockets)
      (let ((path (expand-file-name name dir)))
        ;; as `drgnx-hub-socket' counts: encoded, ending in a NUL within macOS's 104 bytes
        (when (> (length (encode-coding-string path (or file-name-coding-system default-file-name-coding-system))) 103)
          (error "%s is too long for a socket (at most 103 bytes)" path))))
    (dolist (d (list hub top dir)) (drgnx-hub--private-dir d))
    dir))

(defun drgnx-sandbox-mcp-inside-dir (s)
  "Where S's socket dir is inside its sandbox: /run/drgnx on Linux, its own path on macOS."
  (if (eq system-type 'darwin) (drgnx-agent-session-mcp-dir s) drgnx-sandbox-mcp-inside))

;;;; Opening and closing

(defun drgnx-sandbox-mcp--processes (sid)
  "The hub's processes for session SID: listeners, connections, servers and their stderr pipes."
  (seq-filter (lambda (p) (equal (process-get p :drgnx-sandbox-mcp) sid)) (process-list)))

(defun drgnx-sandbox-mcp--search-root (s search)
  "SEARCH as the root S's search server is pinned to (a true name), or an error: it must be an existing directory
given by name — the job's project — and never S's folder nor inside it, nor a folder the VC guard lists
\(`drgnx-sandbox-vc-guarded-p').  The search server runs git in its root, and nothing outside the sandbox runs git
in a task folder."
  (unless (stringp search) (error "The search root is the job's project, given by name: not %S" search))
  (let ((root (directory-file-name (file-truename (expand-file-name search))))
        (cwd (directory-file-name (file-truename (drgnx-agent-session-cwd s)))))
    (unless (file-directory-p root) (error "The search root %s is not a directory" root))
    (when (string-prefix-p (file-name-as-directory cwd) (file-name-as-directory root))
      (error "The search root %s is the session's own folder or inside it: give the job's project" root))
    (when (drgnx-sandbox-vc-guarded-p root)
      (error "The search root %s is a guarded job folder (no git of drgnx's runs there): give the job's project" root))
    root))

(defun drgnx-sandbox-mcp-open (s &optional search)
  "Serve drgnx's MCP servers to session S through its own dir (`drgnx-sandbox-mcp-dir'), and return the dir.
The hub listens on mcp.sock there, and on search.sock when SEARCH is given: the job's project root, to which the
search server is pinned (`drgnx-sandbox-mcp--search-root' says what is refused).  Sets S's `mcp-dir', so its agent
gets bridges to these sockets (`drgnx-agents--mcp-servers').  An S already open is closed first."
  (drgnx-sandbox-mcp-close s)
  (let ((root (and search (drgnx-sandbox-mcp--search-root s search)))
        (dir (drgnx-sandbox-mcp-dir (drgnx-agent-session-id s))))
    (condition-case err
        (progn
          (drgnx-sandbox-mcp--listen s dir "mcp.sock" 'coord)
          (when root (drgnx-sandbox-mcp--listen s dir "search.sock" root))
          (setf (drgnx-agent-session-mcp-dir s) dir))
      (error (setf (drgnx-agent-session-mcp-dir s) dir)
             (drgnx-sandbox-mcp-close s)
             (signal (car err) (cdr err))))))

(defun drgnx-sandbox-mcp-close (s)
  "End S's MCP sockets: every server and connection, the listeners, and S's dir.  S's `mcp-dir' becomes nil.  Safe
to call again."
  (let ((dir (drgnx-agent-session-mcp-dir s)))
    (dolist (p (drgnx-sandbox-mcp--processes (drgnx-agent-session-id s))) (delete-process p))
    (setf (drgnx-agent-session-mcp-dir s) nil)
    ;; the hub's own dir, bound read-only into the sandbox: nothing there is the agent's
    (when dir (ignore-errors (delete-directory dir t)))))

(defun drgnx-sandbox-mcp--listen (s dir name serves)
  "Listen on NAME in DIR for S: each connection gets a server of SERVES (`coord', or a project root for search)."
  (let ((path (expand-file-name name dir)))
    (ignore-errors (delete-file path))          ; a hub that ended without closing left it
    (let ((p (make-network-process :name (format "drgnx-sandbox-mcp %s %s" (drgnx-agent-session-id s) name)
                                   :family 'local :server t :service path :noquery t :coding 'binary
                                   :log #'drgnx-sandbox-mcp--accept
                                   :filter (drgnx-guard-wrap #'drgnx-sandbox-mcp--from-agent "sandbox MCP agent")
                                   :sentinel (drgnx-guard-wrap #'drgnx-sandbox-mcp--conn-sentinel "sandbox MCP agent"))))
      ;; copied to each connection's plist
      (process-put p :drgnx-sandbox-mcp (drgnx-agent-session-id s))
      (process-put p :session s)
      (process-put p :serves serves)
      (process-put p :listener p)
      (process-put p :dir dir)
      p)))

;;;; A connection and its server

(defun drgnx-sandbox-mcp--accept (listener conn _message)
  "LISTENER accepted CONN: start its server — unless the socket serves its most already: CONN is closed."
  (let ((n (cl-count-if (lambda (p) (and (not (eq p conn)) (eq (process-get p :listener) listener)
                                         (eq (process-status p) 'open)))
                        (process-list))))
    (if (>= n drgnx-sandbox-mcp-max-connections)
        (progn (message "drgnx: session %s opened more than %d MCP connections; one is closed"
                        (process-get conn :drgnx-sandbox-mcp) drgnx-sandbox-mcp-max-connections)
               (delete-process conn))
      (process-put conn :lines (drgnx-mcp-bridge--state))
      (condition-case err
          (process-put conn :server (drgnx-sandbox-mcp--start conn))
        (error (message "drgnx: session %s's MCP server did not start: %s" (process-get conn :drgnx-sandbox-mcp)
                        (error-message-string err))
               (delete-process conn))))))

(defun drgnx-sandbox-mcp--spec (s serves)
  "The server entry for S: the coordination server as S (SERVES `coord'), else the search server for SERVES."
  (if (eq serves 'coord)
      (progn (require 'drgnx-coord-mcp)
             (drgnx-coord-mcp-server-spec (drgnx-agent-session-id s) :job (drgnx-agent-session-job s)
                                          :task (drgnx-agent-session-task s)))
    (require 'drgnx-search-mcp)
    (drgnx-search-mcp-server-spec serves)))

(defun drgnx-sandbox-mcp--start (conn)
  "Start CONN's server outside the sandbox, its identity set from the session alone: the spec's variables, and no
DRGNX_AGENT, DRGNX_AGENT_KIND, DRGNX_JOB or DRGNX_TASK of the hub's own.  A search server is pinned to its root
\(DRGNX_SEARCH_PINNED: `drgnx-search-mcp--call').  It works in the session's dir, never in the task folder: the
coordination server runs git where it starts."
  (let* ((serves (process-get conn :serves))
         (spec (drgnx-sandbox-mcp--spec (process-get conn :session) serves))
         (sid (process-get conn :drgnx-sandbox-mcp))
         (default-directory (file-name-as-directory (process-get conn :dir)))
         (process-environment (append (mapcar (lambda (e) (concat (plist-get e :name) "=" (plist-get e :value)))
                                              (plist-get spec :env))
                                      (and (stringp serves) '("DRGNX_SEARCH_PINNED=1"))
                                      '("DRGNX_AGENT" "DRGNX_AGENT_KIND" "DRGNX_JOB" "DRGNX_TASK" ; unset
                                        "DRGNX_SEARCH_PINNED")
                                      process-environment))
         (err (make-pipe-process :name (format "drgnx-sandbox-mcp %s stderr" sid) :noquery t :coding 'binary
                                 :filter #'ignore :sentinel #'ignore))
         (server (progn (process-put err :drgnx-sandbox-mcp sid)
                        (make-process :name (format "drgnx-sandbox-mcp %s server" sid)
                                      :command (cons (plist-get spec :command) (append (plist-get spec :args) nil))
                                      :connection-type 'pipe :coding 'binary :noquery t :stderr err
                                      :filter (drgnx-guard-wrap #'drgnx-sandbox-mcp--from-server "sandbox MCP server")
                                      :sentinel (drgnx-guard-wrap #'drgnx-sandbox-mcp--server-sentinel
                                                                  "sandbox MCP server")))))
    (process-put server :drgnx-sandbox-mcp sid)
    (process-put server :conn conn)
    (process-put server :stderr err)
    server))

(defun drgnx-sandbox-mcp--end (conn)
  "Close CONN and end its server."
  (let ((server (process-get conn :server)))
    (when (process-live-p conn) (delete-process conn))
    (when (process-live-p server) (delete-process server))))

(defun drgnx-sandbox-mcp--from-agent (conn chunk)
  "Forward CHUNK from the sandbox (CONN) to its server, a whole line at a time.  A line too large or not a JSON
object closes CONN and ends its server, unforwarded."
  (let ((server (process-get conn :server)))
    (when (process-live-p server)
      (condition-case err
          (drgnx-mcp-bridge--feed
           (process-get conn :lines) chunk
           (lambda (line)
             (unless (string-empty-p line)
               (drgnx-mcp-bridge--message line)
               (drgnx-hub--enqueue server (concat line "\n"))
               (drgnx-hub--drain server))))
        (error (message "drgnx: session %s's MCP connection is closed: %s" (process-get conn :drgnx-sandbox-mcp)
                        (error-message-string err))
               (drgnx-sandbox-mcp--end conn))))))

(defun drgnx-sandbox-mcp--from-server (server chunk)
  "Forward CHUNK from SERVER to its connection, as it comes."
  (let ((conn (process-get server :conn)))
    (when (process-live-p conn)
      (drgnx-hub--enqueue conn chunk)
      (drgnx-hub--drain conn))))

(defun drgnx-sandbox-mcp--conn-sentinel (conn _event)
  "A connection that closed ends its server."
  (unless (process-live-p conn) (drgnx-sandbox-mcp--end conn)))

(defun drgnx-sandbox-mcp--server-sentinel (server _event)
  "A server that ended closes its connection (what it wrote is out already) and its stderr pipe."
  (unless (process-live-p server)
    (when-let* ((err (process-get server :stderr))) (delete-process err))
    (when-let* ((conn (process-get server :conn))) (when (process-live-p conn) (delete-process conn)))))

;;;; What the agent gets

(defun drgnx-sandbox-mcp-server-specs (s inside-dir)
  "The `mcpServers' entries for S's sandboxed agent: `drgnx', and `drgnx-search' when S's search.sock listens.  Each
runs the bridge (`drgnx-mcp-bridge-command') to its socket in INSIDE-DIR, where S's dir is inside the sandbox
\(`drgnx-sandbox-mcp-inside-dir').  The environment is empty: who the agent is, the hub knows from the socket."
  (let ((listening (mapcar (lambda (p) (and (eq (process-status p) 'listen) (process-get p :serves)))
                           (drgnx-sandbox-mcp--processes (drgnx-agent-session-id s)))))
    (cl-loop for (name socket on) in `(("drgnx" "mcp.sock" ,(memq 'coord listening))
                                       ("drgnx-search" "search.sock" ,(cl-some #'stringp listening)))
             when on
             collect (let ((argv (drgnx-mcp-bridge-command (expand-file-name socket inside-dir))))
                       (list :name name :command (car argv) :args (vconcat (cdr argv)) :env [])))))

(provide 'drgnx-sandbox-mcp)
;;; drgnx-sandbox-mcp.el ends here
