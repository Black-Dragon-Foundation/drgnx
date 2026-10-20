;;; drgnx-sandbox.el --- Job agents in a sandbox: the spec, and its bubblewrap argv -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A job agent's whole process tree runs inside a boundary the kernel enforces.  What it may see is a spec — pure
;; data — and a back end turns the spec into a command line: `bwrap' on Linux, `sandbox-exec' on macOS
;; (drgnx-sandbox-macos.el).  Default deny: nothing of the host exists inside but the system's read-only roots and
;; what the spec binds; ~ is a private home; the hub's socket, $XDG_RUNTIME_DIR (D-Bus, the Emacs server, ssh-agent)
;; and every other socket of the user's are absent; the environment is the spec's alone.  This file builds data and
;; argv and runs nothing.  See docs/develop/sandbox.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-timer)

(declare-function drgnx-hub-socket "drgnx-hub" ())
(declare-function drgnx-sandbox-sbpl "drgnx-sandbox-macos" (spec))
(declare-function drgnx-sandbox-macos-program "drgnx-sandbox-macos" (program path))

(define-error 'drgnx-sandbox-refused "Sandbox refused")

(defconst drgnx-sandbox-system-read
  '((ro-try "/usr") (ro-try "/etc") (ro-try "/opt") (ro-try "/nix") (ro-try "/gnu") (ro-try "/var/lib/flatpak")
    (link "/bin") (link "/lib") (link "/lib64") (link "/sbin"))
  "The system's roots every sandbox reads: (ro-try PATH) is bound read-only where it exists; (link PATH) is the same
link inside where the host's PATH is a link (/bin → usr/bin on a merged /usr), else bound read-only where it exists.")

(defconst drgnx-sandbox-env-deny
  '("SSH_AUTH_SOCK" "DBUS_SESSION_BUS_ADDRESS" "XDG_RUNTIME_DIR" "DISPLAY" "WAYLAND_DISPLAY" "XAUTHORITY"
    "GPG_AGENT_INFO" "DRGNX_DATA_DIR" "DRGNX_AGENT")
  "Variables a spec's `:env' may never hold: they name the user's sockets, display or drgnx's store, or the agent
\(its identity comes from the socket it connects on, never from anything inside).")

(defconst drgnx-sandbox-trusted-programs
  '(("bwrap" . "/usr/bin/bwrap") ("sandbox-exec" . "/usr/bin/sandbox-exec") ("systemd-run" . "/usr/bin/systemd-run"))
  "Where each sandbox program is looked for first, before `exec-path'.")

(defcustom drgnx-sandbox-memory-max "4G"
  "The memory cap of each sandboxed agent, the `:memory-max' of a spec that does not give one: a systemd size (4G,
512M, 50%) or nil for none.  It applies where a systemd user manager answers (`drgnx-sandbox-memory-prefix').  An
operational guard, so that one agent's build cannot run the session out of memory; not a security boundary."
  :type '(choice (const :tag "No cap" nil) string) :group 'drgnx)

(defcustom drgnx-sandbox-secret-files
  '(".npmrc" "etc/npmrc" ".yarnrc" ".yarnrc.yml" ".pypirc" ".netrc" ".git-credentials" ".env" "credentials"
    "credentials.toml" "credentials.json" "auth.json")
  "Where package managers keep tokens, relative to a toolchain root: each that exists inside a root of
`drgnx-sandbox-toolchain-roots' is hidden in the sandbox (`drgnx-sandbox-toolchain-hide').  npm's global config is
PREFIX/etc/npmrc."
  :type '(repeat string) :group 'drgnx)

(defvar drgnx-sandbox--programs nil
  "Program name → its checked absolute path, or nil when there is none (`drgnx-sandbox-program'), cached until
`drgnx-sandbox-program-reset'.")

(defvar drgnx-sandbox--checked nil
  "The check's answer (`drgnx-sandbox-check'), kept until `drgnx-sandbox-check-reset'.")

(defvar drgnx-sandbox-resolv-conf "/etc/resolv.conf"
  "The resolver's configuration.  Where it is a link to a file under /run (systemd-resolved's stub), that file is
bound read-only inside, so names resolve under the empty /run.")

(defconst drgnx-sandbox--size "\\`[0-9]+\\(?:\\.[0-9]+\\)?[KMGT]?\\'\\|\\`[0-9]+%\\'"
  "What a `:memory-max' must look like: a systemd size (4G, 512M, 1.5G) or a percentage (50%), nothing else.")

(defconst drgnx-sandbox--keys
  '(:backend :read :write :hide :binds :home :run :sockets :env :chdir :net :proxy :gateway :tmp :profile-file
             :memory-max)
  "The keys of a sandbox spec (docs/develop/sandbox.md).")

;;;; The spec

(defun drgnx-sandbox--bad-name (path)
  "Why PATH cannot stand for a file as it is, or nil."
  (cond ((not (stringp path)) (format "%S is not a file name" path))
        ((string-match-p "[\0\n]" path) (format "%S holds a NUL or a newline" path))
        ((not (file-name-absolute-p path)) (format "%s is a relative file name" path))))

(defun drgnx-sandbox--canonical-p (path)
  "Is PATH in canonical form: no `//' (a leading one too: Emacs keeps it, the kernel reads it as `/'), no `.' or
`..' component, no trailing slash (but `/' itself)?"
  (or (string= path "/") (not (string-match-p "//\\|/\\.\\.?\\(?:/\\|\\'\\)\\|/\\'" path))))

(defun drgnx-sandbox--truename (path)
  "PATH's true name — every link resolved, no trailing slash, a leading `//' as `/' — or nil when it cannot be
resolved (a cycle of links).  No file name handler takes part: a remote-looking name is a local path like any
other."
  (let ((file-name-handler-alist nil))
    (condition-case nil
        (let ((true (directory-file-name (file-truename (expand-file-name path)))))
          (if (string-match "\\`//+" true) (replace-match "/" t t true) true))
      (error nil))))

(defun drgnx-sandbox--resolve (path)
  "PATH's true name; PATH itself when it is no usable absolute name (`drgnx-sandbox-validate' refuses it)."
  (or (and (not (drgnx-sandbox--bad-name path)) (drgnx-sandbox--truename path)) path))

(defun drgnx-sandbox--resolve-value (key value)
  "VALUE of spec KEY with its paths resolved; a value of the wrong shape as it is (validation refuses it)."
  (pcase key
    ((or :read :write :hide :sockets) (if (proper-list-p value) (mapcar #'drgnx-sandbox--resolve value) value))
    (:binds (if (proper-list-p value)
                (mapcar (lambda (b)
                          (if (and (proper-list-p b) (= (length b) 3))
                              (list (car b) (drgnx-sandbox--resolve (nth 1 b)) (drgnx-sandbox--resolve (nth 2 b)))
                            b))
                        value)
              value))
    (:home (if (consp value) (cons (drgnx-sandbox--resolve (car value)) (drgnx-sandbox--resolve (cdr value))) value))
    ((or :run :chdir :tmp :profile-file) (drgnx-sandbox--resolve value))
    (_ value)))

(defun drgnx-sandbox-spec (&rest props)
  "A sandbox spec from PROPS, with every path through `file-truename' and `:net' `shared' unless given.
The keys:
  :backend bwrap|seatbelt   the back end (default: `drgnx-sandbox-backend')
  :read (PATH…)              read-only at their own path (where they exist)
  :write (PATH…)             read-write at their own path
  :hide (PATH…)              covered inside: a file by /dev/null, a directory by an empty tmpfs
  :binds ((ro|rw OUTSIDE INSIDE)…)   applied last, in order (the git modes' pins)
  :home (OUTSIDE . INSIDE)   the private home, bound at the user's $HOME path
  :run OUTSIDE               the session's socket dir: /run/drgnx inside on Linux, its own path on macOS
  :sockets (PATH…)           the Unix sockets the agent may connect to (Seatbelt; on Linux they are in :run)
  :env ((NAME . VALUE)…)     the whole environment
  :chdir DIR                 where the command starts
  :net shared|isolated       the host's network, or none
  :proxy PORT :gateway PORT  localhost ports for macOS (phase 2)
  :tmp DIR :profile-file FILE   macOS: the session's TMPDIR and where its profile is written
  :memory-max STRING         the memory cap (default `drgnx-sandbox-memory-max'; nil: none)
Nothing is checked here: `drgnx-sandbox-validate' says what is refused, and the back ends refuse it."
  (let ((spec (cl-loop for (key value) on props by #'cddr
                       nconc (list key (drgnx-sandbox--resolve-value key value)))))
    (unless (plist-get spec :net) (setq spec (append spec (list :net 'shared))))
    (if (plist-member spec :memory-max) spec (append spec (list :memory-max drgnx-sandbox-memory-max)))))

;;;; What is refused

(defun drgnx-sandbox--within-p (path dir)
  "Is PATH DIR or inside it?  Both true names (case does not count on macOS)."
  (let ((fold (eq system-type 'darwin)))
    (or (eq t (compare-strings path nil nil dir nil nil fold))
        (string-prefix-p (file-name-as-directory dir) path fold))))

(defun drgnx-sandbox--under-p (path dir)
  "Is PATH strictly inside DIR?"
  (string-prefix-p (file-name-as-directory dir) path (eq system-type 'darwin)))

(defun drgnx-sandbox--hub-dirs ()
  "Every directory the hub's socket may be in: where `drgnx-hub-socket' puts it now, and its other places."
  (require 'drgnx-hub)
  (let ((run (getenv "XDG_RUNTIME_DIR")))
    (list (file-name-directory (drgnx-hub-socket))
          (and run (file-name-absolute-p run) (expand-file-name "drgnx" run))
          (expand-file-name "hub" (drgnx-state-dir))
          (expand-file-name (format "drgnx-hub-%d" (user-uid)) temporary-file-directory))))

(defun drgnx-sandbox-sessions-dirs ()
  "The directories a session's own socket dir (`:run') is made in: drgnx/s/ under $XDG_RUNTIME_DIR, and s/ beside
the hub's socket (its fallback place when there is no runtime dir).  True names."
  (require 'drgnx-hub)
  (let ((run (getenv "XDG_RUNTIME_DIR")))
    (delete-dups (delq nil (mapcar (lambda (d) (and d (drgnx-sandbox--truename d)))
                                   (list (and run (file-name-absolute-p run) (expand-file-name "drgnx/s" run))
                                         (expand-file-name "s" (file-name-directory (drgnx-hub-socket)))))))))

(defun drgnx-sandbox--bus-socket (address)
  "The file of a `unix:path=' D-Bus ADDRESS, or nil."
  (and address (string-match "unix:path=\\([^,;]+\\)" address) (match-string 1 address)))

(defun drgnx-sandbox--context ()
  "What validation compares paths with, as true names:
  :never ((PATH . WHAT)…)   no bind may be one of these or hold one;
  :closed ((DIR . WHAT)…)   …nor be inside one of these, unless inside a job's dir of an :open dir;
  :open (DIR…)              <state>/sandbox/: only what is inside its ID/ dirs (the private homes ID/home-N) is
                            open, never the dir itself nor what sits directly in it (folders.eld, the VC guard's
                            registry);
  :sessions (DIR…)          `drgnx-sandbox-sessions-dirs': `:run' alone may be a dir directly in one;
  :path (DIR…)              `exec-path': no read-write bind may be one of these or hold one."
  (let* ((uid (user-uid))
         (abs (lambda (d) (and (stringp d) (file-name-absolute-p d) d)))
         (true (lambda (pairs) (cl-loop for (d . what) in pairs for tn = (and d (drgnx-sandbox--truename d))
                                        when tn collect (cons tn what))))
         (run (funcall abs (getenv "XDG_RUNTIME_DIR")))
         (closed (funcall true
                          `(("/run/user" . "the users' runtime directories") (,run . "your runtime directory")
                            ,@(mapcar (lambda (d) (cons d "the hub's socket directory")) (drgnx-sandbox--hub-dirs))
                            (,(drgnx-data-dir) . "drgnx's data directory")
                            (,(drgnx-user-dir) . "drgnx's configuration")
                            (,(drgnx-state-dir) . "drgnx's state directory")
                            ("/proc" . "the host's processes") ("/sys" . "the host's /sys")
                            ("/dev" . "the host's devices")
                            ("/tmp/.X11-unix" . "the X11 sockets") ("/tmp/.ICE-unix" . "the ICE sockets")
                            (,(format "/tmp/emacs%d" uid) . "the Emacs server's sockets")
                            (,(expand-file-name (format "emacs%d" uid) (or (funcall abs (getenv "TMPDIR")) "/tmp"))
                             . "the Emacs server's sockets"))))
         ;; sockets that may sit in a shared directory (/tmp/ssh-XXXX/agent.N): the socket and what holds it
         (never (funcall true
                         `((,(or (funcall abs (getenv "HOME")) "~") . "your home directory")
                           (,drgnx-dir . "the drgnx checkout")
                           (,(funcall abs (getenv "SSH_AUTH_SOCK")) . "the ssh agent's socket")
                           (,(funcall abs (drgnx-sandbox--bus-socket (getenv "DBUS_SESSION_BUS_ADDRESS")))
                            . "the D-Bus socket")))))
    (list :never (append never closed) :closed closed
          :open (delq nil (list (drgnx-sandbox--truename (expand-file-name "sandbox" (drgnx-state-dir)))))
          :sessions (drgnx-sandbox-sessions-dirs)
          :path (delete-dups (delq nil (mapcar (lambda (d) (and (funcall abs d) (drgnx-sandbox--truename d)))
                                               exec-path))))))

(defun drgnx-sandbox--session-dir-p (ctx path)
  "Is PATH one session's dir: directly in one of CTX's :sessions dirs?"
  (let ((parent (directory-file-name (file-name-directory path))))
    (and (not (string= parent path))
         (cl-some (lambda (s) (eq t (compare-strings parent nil nil s nil nil (eq system-type 'darwin))))
                  (plist-get ctx :sessions)))))

(defun drgnx-sandbox--in-job-dir-p (ctx path)
  "Is PATH inside a job's dir of one of CTX's :open dirs: OPEN/ID/…, never OPEN/ID itself nor OPEN/FILE?"
  (cl-some (lambda (o)
             (and (drgnx-sandbox--under-p path o)
                  (string-search "/" (substring path (length (file-name-as-directory o))))))
           (plist-get ctx :open)))

(defun drgnx-sandbox--refuse (fmt &rest args)
  "End `drgnx-sandbox-validate' with the reason (`format' FMT ARGS)."
  (throw 'drgnx-sandbox--refused (apply #'format fmt args)))

(defun drgnx-sandbox--check-path (key path)
  "Refuse PATH (of spec KEY) unless it is an absolute name in canonical form, without NUL or newline, that is its
own true name."
  (when-let* ((why (drgnx-sandbox--bad-name path))) (drgnx-sandbox--refuse "%s: %s" key why))
  (unless (drgnx-sandbox--canonical-p path)
    (drgnx-sandbox--refuse "%s: %s is not in canonical form (a `//', `.' or `..', or a trailing slash)" key path))
  (let ((true (drgnx-sandbox--truename path)))
    (unless true (drgnx-sandbox--refuse "%s: %s does not resolve (a cycle of links?)" key path))
    (unless (string= true path)
      (drgnx-sandbox--refuse "%s: %s is %s once resolved (a link, or changed since the spec was made)" key path true))))

(defun drgnx-sandbox--check-source (ctx key path &optional must-exist writable)
  "Refuse binding PATH (of spec KEY) from outside: never one of CTX's :never paths nor a parent of one; nothing
inside a :closed dir but inside a job's dir of an :open one (`drgnx-sandbox--in-job-dir-p') — except that `:run' is
a session's own dir.  MUST-EXIST: refuse it when it is not there.  WRITABLE (a read-write bind): refuse it when it is
or holds a dir of `exec-path'."
  (drgnx-sandbox--check-path key path)
  (pcase-dolist (`(,dir . ,what) (plist-get ctx :never))
    (when (drgnx-sandbox--within-p dir path)
      (drgnx-sandbox--refuse "%s: %s would expose %s (%s)" key path what dir)))
  (unless (and (eq key :run) (drgnx-sandbox--session-dir-p ctx path))
    (pcase-dolist (`(,dir . ,what) (plist-get ctx :closed))
      (when (and (drgnx-sandbox--within-p path dir) (not (drgnx-sandbox--in-job-dir-p ctx path)))
        (drgnx-sandbox--refuse "%s: %s is inside %s (%s)" key path what dir))))
  (when writable
    (dolist (dir (plist-get ctx :path))
      (when (drgnx-sandbox--within-p dir path)
        (drgnx-sandbox--refuse "%s: %s would let the sandbox change %s, where the hub finds its programs" key path
                               dir))))
  (when (and must-exist (not (file-exists-p path)))
    (drgnx-sandbox--refuse "%s: %s does not exist" key path)))

(defun drgnx-sandbox--check-shape (spec)
  "Refuse SPEC unless it is a plist of known keys whose values have their shapes."
  (unless (and (proper-list-p spec) (cl-evenp (length spec))) (drgnx-sandbox--refuse "the spec is not a plist"))
  (cl-loop for (key value) on spec by #'cddr
           do (unless (memq key drgnx-sandbox--keys) (drgnx-sandbox--refuse "unknown key %S" key))
           when (and (memq key '(:read :write :hide :sockets :binds :env)) (not (proper-list-p value)))
           do (drgnx-sandbox--refuse "%s is not a list" key))
  (unless (memq (plist-get spec :backend) '(nil bwrap seatbelt))
    (drgnx-sandbox--refuse ":backend %S is neither bwrap nor seatbelt" (plist-get spec :backend)))
  (unless (memq (plist-get spec :net) '(nil shared isolated))
    (drgnx-sandbox--refuse ":net %S is neither shared nor isolated" (plist-get spec :net)))
  (dolist (b (plist-get spec :binds))
    (unless (and (proper-list-p b) (= (length b) 3) (memq (car b) '(ro rw)))
      (drgnx-sandbox--refuse ":binds: %S is not (ro|rw OUTSIDE INSIDE)" b)))
  (unless (or (null (plist-get spec :home)) (consp (plist-get spec :home)))
    (drgnx-sandbox--refuse ":home is not (OUTSIDE . INSIDE)"))
  (dolist (e (plist-get spec :env))
    (unless (and (consp e) (stringp (car e)) (stringp (cdr e))
                 (string-match-p "\\`[A-Za-z_][A-Za-z0-9_]*\\'" (car e)) (not (string-match-p "\0" (cdr e))))
      (drgnx-sandbox--refuse ":env: %S is not (NAME . VALUE)" e))
    (when (member (car e) drgnx-sandbox-env-deny)
      (drgnx-sandbox--refuse ":env: %s is never passed into a sandbox" (car e))))
  (dolist (key '(:proxy :gateway))
    (unless (or (null (plist-get spec key)) (natnump (plist-get spec key)))
      (drgnx-sandbox--refuse "%s is not a port" key)))
  (let ((max (plist-get spec :memory-max)))
    (unless (or (null max) (and (stringp max) (string-match-p drgnx-sandbox--size max)))
      (drgnx-sandbox--refuse ":memory-max %S is not a size (4G, 512M, 50%%)" max))))

(defun drgnx-sandbox-validate (spec)
  "Why SPEC must not be used, or nil.  Refused:
- a spec that is not a plist of `drgnx-sandbox--keys' with values of their shape; an `:env' name in
  `drgnx-sandbox-env-deny';
- a path that is relative, holds a NUL or a newline, is not in canonical form (`//', `.', `..', a trailing slash),
  or is not its own true name (a link, or one swapped in since `drgnx-sandbox-spec' resolved it);
- binding from outside (`:read', `:write', `:binds', `:home', `:run', `:tmp') $HOME, the checkout, the ssh agent's
  or the D-Bus socket, or any parent of them; and anything in or above /run/user, $XDG_RUNTIME_DIR, the hub's socket
  dirs, drgnx's data, config and state dirs (but inside a job's dir, <state>/sandbox/ID/…), /proc, /sys, /dev, the X11
  and ICE socket dirs or the Emacs server's /tmp/emacsUID — but `:run', one session's own dir;
- a read-write bind (`:write', `:binds' rw, `:home', `:tmp') of a dir of `exec-path' or a parent of one: the hub
  would run what the sandbox put there;
- a `:write', `:binds' or `:home' source, or `:run', that does not exist;
- a `:run' that is not one session's dir, directly in a dir of `drgnx-sandbox-sessions-dirs' (another session's
  dir is refused everywhere else); a `:sockets' entry outside `:run'; a `:profile-file' outside a sessions dir."
  (catch 'drgnx-sandbox--refused
    (drgnx-sandbox--check-shape spec)
    (let ((ctx (drgnx-sandbox--context)) (home (plist-get spec :home)) (run (plist-get spec :run))
          (file-name-handler-alist nil))                ; a remote-looking name is a local path, never TRAMP
      (dolist (p (plist-get spec :read)) (drgnx-sandbox--check-source ctx :read p))
      (dolist (p (plist-get spec :write)) (drgnx-sandbox--check-source ctx :write p t t))
      (pcase-dolist (`(,mode ,outside ,inside) (plist-get spec :binds))
        (drgnx-sandbox--check-source ctx :binds outside t (eq mode 'rw))
        (drgnx-sandbox--check-path :binds inside))
      (when home
        (drgnx-sandbox--check-source ctx :home (car home) t t)
        (drgnx-sandbox--check-path :home (cdr home)))
      (when run
        (drgnx-sandbox--check-path :run run)
        (unless (drgnx-sandbox--session-dir-p ctx run)
          (drgnx-sandbox--refuse ":run: %s is not a session's dir directly in %s" run
                                 (string-join (plist-get ctx :sessions) " or ")))
        (drgnx-sandbox--check-source ctx :run run t))
      (when (plist-get spec :tmp) (drgnx-sandbox--check-source ctx :tmp (plist-get spec :tmp) nil t))
      (dolist (s (plist-get spec :sockets))
        (drgnx-sandbox--check-path :sockets s)
        (unless (and run (drgnx-sandbox--under-p s run))
          (drgnx-sandbox--refuse ":sockets: %s is not in the session's dir (:run)" s)))
      (dolist (p (plist-get spec :hide)) (drgnx-sandbox--check-path :hide p))
      (when (plist-get spec :chdir) (drgnx-sandbox--check-path :chdir (plist-get spec :chdir)))
      (when-let* ((file (plist-get spec :profile-file)))
        (drgnx-sandbox--check-path :profile-file file)
        (unless (cl-some (lambda (s) (drgnx-sandbox--under-p file s)) (plist-get ctx :sessions))
          (drgnx-sandbox--refuse ":profile-file: %s is not in a session's dir" file))))
    nil))

(defun drgnx-sandbox--assert (spec command)
  "Signal `drgnx-sandbox-refused' when SPEC is refused or COMMAND is not a program and its arguments."
  (when-let* ((reason (or (drgnx-sandbox-validate spec)
                          (and (not (and (consp command) (proper-list-p command) (cl-every #'stringp command)
                                         (not (cl-some (lambda (a) (string-match-p "\0" a)) command))))
                               (format "the command %S is not a list of strings" command)))))
    (signal 'drgnx-sandbox-refused (list reason))))

;;;; Linux: bubblewrap

(defun drgnx-sandbox--system-argv ()
  "The bwrap arguments for `drgnx-sandbox-system-read' on this host."
  (let ((file-name-handler-alist nil))
    (cl-loop for (kind path) in drgnx-sandbox-system-read
             nconc (pcase kind
                     ('ro-try (list "--ro-bind-try" path path))
                     ('link (let ((target (file-symlink-p path)))
                              (cond (target (list "--symlink" target path))
                                    ((file-directory-p path) (list "--ro-bind-try" path path)))))))))

(defun drgnx-sandbox--resolv-argv ()
  "The bwrap arguments that keep name resolution working under the empty /run: where `drgnx-sandbox-resolv-conf'
leads to a file under /run (systemd-resolved's stub-resolv.conf, NetworkManager's), that file read-only.  Only the
file: never its directory, which may hold sockets."
  (let ((true (drgnx-sandbox--truename drgnx-sandbox-resolv-conf)))
    (and true (string-prefix-p "/run/" true) (not (string-prefix-p "/run/user/" true))
         (list "--ro-bind-try" true true))))

(defun drgnx-sandbox-bwrap-argv (spec command)
  "The bwrap command line that runs COMMAND (a list) inside SPEC, every path its own element.  In order:
the trusted bwrap (`drgnx-sandbox-program'), the namespaces and `--clearenv'; `--setenv' for each `:env' entry; the
system's reads, then a fresh /dev, /proc and empty /tmp, /run and /var/tmp, and the resolver's file; `:home', `:read'
\(where they exist), `:write'; `:run' read-only at /run/drgnx; `:binds' in order; `:hide' (where they exist);
`--chdir'; `--' and COMMAND.  Signals `drgnx-sandbox-refused' with `drgnx-sandbox-validate''s reason, or when there
is no trusted bwrap."
  (drgnx-sandbox--assert spec command)
  (let ((file-name-handler-alist nil) (bwrap (drgnx-sandbox-program "bwrap"))
        (home (plist-get spec :home)) (run (plist-get spec :run)) (chdir (plist-get spec :chdir)))
    (unless bwrap
      (signal 'drgnx-sandbox-refused (list "no bwrap that only root can change (install bubblewrap)")))
    (append
     ;; --unshare-all unshares the user namespace only if it can (--unshare-user-try); --disable-userns needs it
     (list bwrap "--unshare-all" "--unshare-user")
     (and (eq (plist-get spec :net) 'shared) (list "--share-net"))
     (list "--disable-userns" "--die-with-parent" "--new-session" "--clearenv")
     (cl-loop for (name . value) in (plist-get spec :env) nconc (list "--setenv" name value))
     (drgnx-sandbox--system-argv)
     (list "--dev" "/dev" "--proc" "/proc" "--tmpfs" "/tmp" "--tmpfs" "/run" "--tmpfs" "/var/tmp")
     (drgnx-sandbox--resolv-argv)
     (and home (list "--bind" (car home) (cdr home)))
     (cl-loop for p in (plist-get spec :read) when (file-exists-p p) nconc (list "--ro-bind-try" p p))
     (cl-loop for p in (plist-get spec :write) nconc (list "--bind" p p))
     ;; read-only: the agent connects to the hub's sockets there, but can plant nothing the hub reads later
     (and run (list "--ro-bind" run "/run/drgnx"))
     (cl-loop for (mode outside inside) in (plist-get spec :binds)
              nconc (list (if (eq mode 'rw) "--bind" "--ro-bind") outside inside))
     (cl-loop for p in (plist-get spec :hide)
              nconc (cond ((file-directory-p p) (list "--tmpfs" p))
                          ((file-exists-p p) (list "--ro-bind" "/dev/null" p))))
     (and chdir (list "--chdir" chdir))
     (cons "--" command))))

;;;; The back ends

(defun drgnx-sandbox--root-only-p (file)
  "Can only root change FILE (a true name) and its directory: both root's, neither writable by group or others?"
  (cl-every (lambda (f)
              (let ((a (file-attributes f 'integer)))
                (and a (eql (file-attribute-user-id a) 0)
                     (eq (file-attribute-type a) (if (equal f file) nil t))
                     (not (eq (aref (file-attribute-modes a) 5) ?w))
                     (not (eq (aref (file-attribute-modes a) 8) ?w)))))
            (list file (directory-file-name (file-name-directory file)))))

(defun drgnx-sandbox-program (name)
  "NAME's absolute true name, when it is a program only root can change (`drgnx-sandbox--root-only-p'), looked for
in `drgnx-sandbox-trusted-programs' first, then on `exec-path'; else nil.  Resolved once and cached (nil too), so a
program planted later on the hub's PATH is never picked up; `drgnx-sandbox-program-reset' looks again."
  (let ((hit (assoc name drgnx-sandbox--programs)))
    (if hit (cdr hit)
      (let* ((file-name-handler-alist nil)
             (found (cl-loop for f in (list (cdr (assoc name drgnx-sandbox-trusted-programs)) (executable-find name))
                             for true = (and f (file-executable-p f) (drgnx-sandbox--truename f))
                             when (and true (drgnx-sandbox--root-only-p true)) return true)))
        (push (cons name found) drgnx-sandbox--programs)
        found))))

(defun drgnx-sandbox-program-reset ()
  "Forget the programs `drgnx-sandbox-program' found."
  (setq drgnx-sandbox--programs nil))

(defun drgnx-sandbox-backend ()
  "The sandbox this system has: `bwrap' (Linux, bubblewrap), `seatbelt' (macOS, sandbox-exec), or nil — each only
as a program only root can change (`drgnx-sandbox-program')."
  (pcase system-type
    ('gnu/linux (and (drgnx-sandbox-program "bwrap") 'bwrap))
    ('darwin (and (drgnx-sandbox-program "sandbox-exec") 'seatbelt))))

(defun drgnx-sandbox--write-private (file text)
  "Write TEXT to FILE, mode 0600, as a new file: whatever was at FILE (a link too) is removed first, never followed."
  (let ((file-name-handler-alist nil) (coding-system-for-write 'utf-8-unix))
    (when (file-attributes file) (delete-file file))
    (with-file-modes #o600 (write-region text nil file nil 'silent nil 'excl))))

(defun drgnx-sandbox-wrap (spec command)
  "The command line that runs COMMAND (a list) inside SPEC, for SPEC's `:backend' or else `drgnx-sandbox-backend':
`drgnx-sandbox-bwrap-argv' on Linux; on macOS, sandbox-exec with SPEC's profile (`drgnx-sandbox-sbpl') written to
its `:profile-file' (-f FILE), or given on the command line (-p PROFILE) when SPEC has none, as a short step's does.
Seatbelt sets neither `:env' nor `:chdir': the caller starts the command with them (`drgnx-sandbox-run' does).
The memory cap's scope (`drgnx-sandbox-memory-prefix') comes first, where there is one.  Signals
`drgnx-sandbox-refused' when SPEC is refused or there is no sandbox: never the command as it was."
  (let ((argv (pcase (or (plist-get spec :backend) (drgnx-sandbox-backend))
                ('bwrap (drgnx-sandbox-bwrap-argv spec command))
                ('seatbelt
                 (drgnx-sandbox--assert spec command)
                 (let ((file (plist-get spec :profile-file)) (exe (drgnx-sandbox-program "sandbox-exec")))
                   (unless exe (signal 'drgnx-sandbox-refused (list "no sandbox-exec that only root can change")))
                   (unless (fboundp 'drgnx-sandbox-sbpl) (require 'drgnx-sandbox-macos))
                   (let ((profile (drgnx-sandbox-sbpl spec)))
                     (if (not file)
                         ;; a short step of the hub's has no session dir to write it in: on the command line
                         (append (list exe "-p" profile) command)
                       (drgnx-sandbox--write-private file profile)
                       (append (list exe "-f" file) command)))))
                (_ (signal 'drgnx-sandbox-refused
                           (list "no sandbox on this system (Linux: install bubblewrap; macOS: sandbox-exec)"))))))
    (append (drgnx-sandbox-memory-prefix spec) argv)))

(defun drgnx-sandbox-memory-prefix (spec)
  "The systemd scope that caps SPEC's memory at its `:memory-max', to put in front of the sandbox: (SYSTEMD-RUN
\"--user\" \"--scope\" \"--quiet\" \"-p\" \"MemoryMax=M\" \"-p\" \"MemorySwapMax=0\" \"--\"), with the trusted
systemd-run (`drgnx-sandbox-program').  Nil when `:memory-max' is nil, or when the last check
(`drgnx-sandbox--checked') did not find a user manager that answers — or has not run: this never runs a process.
Signals `drgnx-sandbox-refused' when `:memory-max' is not a size (`drgnx-sandbox--size'), whoever built SPEC."
  (let ((max (plist-get spec :memory-max)))
    (unless (or (null max) (and (stringp max) (string-match-p drgnx-sandbox--size max)))
      (signal 'drgnx-sandbox-refused (list (format ":memory-max %S is not a size (4G, 512M, 50%%)" max))))
    (when-let* (((and max (plist-get drgnx-sandbox--checked :scope))) (run (drgnx-sandbox-program "systemd-run")))
      (list run "--user" "--scope" "--quiet" "-p" (concat "MemoryMax=" max) "-p" "MemorySwapMax=0" "--"))))

;;;; Running: short sandboxed steps

(defvar drgnx-job-git-timeout)

(defun drgnx-sandbox--timed-out (p)
  "The deadline of the step process P (`drgnx-sandbox--spawn'): mark it timed out and end it."
  (when (process-live-p p) (process-put p :timed-out t) (delete-process p)))

(defun drgnx-sandbox--spawn (name argv timeout done &optional dir)
  "Run ARGV as process NAME, started in DIR (default /), stdin closed, never waiting for it.  DONE gets (EXIT . OUTPUT)
once it ended — OUTPUT is its stdout and stderr together, trimmed — or (:timeout . \"did not finish in TIMEOUT s\")
when it ran past TIMEOUT seconds (the timer layer's (sandbox-step-timeout . PROCESS), owned by the process) and was
ended.  The process; signals when it cannot start, leaving nothing behind."
  (let* ((out (generate-new-buffer (format " *%s*" name) t))
         (default-directory (if dir (file-name-as-directory dir) "/"))
         (p (condition-case e
                (make-process
                 :name name :buffer out :noquery t :connection-type 'pipe :command argv
                 :sentinel (lambda (p _event)
                             (unless (process-live-p p)
                               (drgnx-timer-cancel (cons 'sandbox-step-timeout p))
                               (let ((text (string-trim (with-current-buffer out (buffer-string)))))
                                 (kill-buffer out)
                                 (with-demoted-errors "drgnx sandbox: %S"
                                   (funcall done (if (process-get p :timed-out)
                                                     (cons :timeout (format "did not finish in %s s" timeout))
                                                   (cons (process-exit-status p) text))))))))
              (error (kill-buffer out) (signal (car e) (cdr e))))))
    (drgnx-timer-start (cons 'sandbox-step-timeout p) timeout #'drgnx-sandbox--timed-out :args (list p) :owner p)
    (ignore-errors (process-send-eof p))
    p))

(defun drgnx-sandbox-run (spec argv done &optional timeout)
  "Run ARGV inside SPEC (`drgnx-sandbox-wrap': under the memory cap where there is one) as a process of its own: a
short step of the hub's, such as a checkout or a bundle.  It never blocks.  DONE gets (EXIT . OUTPUT), stdout and
stderr together, trimmed; or (:timeout . MSG) when it ran past TIMEOUT seconds (default `drgnx-job-git-timeout') and
was ended.  Returns the process.  Signals `drgnx-sandbox-refused' when SPEC is refused or there is no sandbox:
nothing runs then.  On Seatbelt, which sets neither, the step starts in SPEC's `:chdir' with its `:env' alone: never
the hub's environment, and an xcrun shim it would run is the developer dir's tool (`drgnx-sandbox-macos-program')."
  (let* ((timeout (or timeout (bound-and-true-p drgnx-job-git-timeout) 300))
         (seatbelt (eq (or (plist-get spec :backend) (drgnx-sandbox-backend)) 'seatbelt))
         (wrapped (drgnx-sandbox-wrap spec (if (not seatbelt) argv
                                             (require 'drgnx-sandbox-macos)
                                             (cons (drgnx-sandbox-macos-program
                                                    (car argv) (cdr (assoc "PATH" (plist-get spec :env))))
                                                   (cdr argv)))))
         (process-environment (if seatbelt
                                  (cl-loop for (name . value) in (plist-get spec :env) collect (concat name "=" value))
                                process-environment)))
    (drgnx-sandbox--spawn "drgnx-sandbox-step" wrapped timeout
                          (lambda (r)
                            (funcall done (if (eq (car r) :timeout) (cons :timeout (concat "the sandboxed step " (cdr r))) r)))
                          (and seatbelt (plist-get spec :chdir)))))

;;;; The check

(defvar drgnx-sandbox-check-timeout 5 "Seconds each probe of the sandbox's check may take.")

(defvar drgnx-sandbox--check-waiting nil
  "While a check runs: (GENERATION . DONES), the DONEs of `drgnx-sandbox-check-async' waiting for it, newest first.")

(defvar drgnx-sandbox--check-generation 0
  "Bumped by `drgnx-sandbox-check-reset': a check started before it does not keep its answer.")

(defvar drgnx-sandbox-container-files '("/run/.containerenv" "/.dockerenv")
  "Files that are there when this Emacs runs in a container (podman's, docker's).")

(defvar drgnx-sandbox-os-release "/etc/os-release" "The file that names this Linux distribution.")

(defconst drgnx-sandbox--installers
  '(("fedora" . "sudo dnf install bubblewrap") ("rhel" . "sudo dnf install bubblewrap")
    ("centos" . "sudo dnf install bubblewrap") ("debian" . "sudo apt install bubblewrap")
    ("ubuntu" . "sudo apt install bubblewrap") ("arch" . "sudo pacman -S bubblewrap")
    ("suse" . "sudo zypper install bubblewrap") ("opensuse" . "sudo zypper install bubblewrap"))
  "A distribution's ID (/etc/os-release's ID or ID_LIKE) → how to install bubblewrap there.")

(defconst drgnx-sandbox--apparmor-fix
  (concat "let bwrap make user namespaces with Ubuntu's bwrap-userns-restrict AppArmor profile: "
          "sudo cp /usr/share/apparmor/extra-profiles/bwrap-userns-restrict /etc/apparmor.d/ && "
          "sudo apparmor_parser -r /etc/apparmor.d/bwrap-userns-restrict  "
          "(https://discourse.ubuntu.com/t/understanding-apparmor-user-namespace-restriction/58007)")
  "The fix for Ubuntu's (23.10 and later) rule on unprivileged user namespaces.")

(defun drgnx-sandbox--install-fix ()
  "How to install bubblewrap on this distribution: by the first ID, then ID_LIKE, of `drgnx-sandbox-os-release'."
  (let ((ids (ignore-errors
               (with-temp-buffer
                 (insert-file-contents drgnx-sandbox-os-release)
                 (cl-loop for key in '("ID" "ID_LIKE")
                          do (goto-char (point-min))
                          when (re-search-forward (concat "^" key "=\"?\\([^\"\n]*\\)") nil t)
                          append (split-string (match-string 1)))))))
    (or (cl-loop for id in ids thereis (cdr (assoc id drgnx-sandbox--installers)))
        "install bubblewrap (the package with bwrap) with your package manager")))

(defun drgnx-sandbox--explain (stderr)
  "Why the sandbox cannot run, and how to fix that: (REASON . FIX), FIX nil when there is nothing to do.  STDERR is
what the probe printed, nil when there is no program to run it with."
  (let ((first (and stderr (car (split-string stderr "\n" t "[ \t]+")))))
    (cond ((cl-some #'file-exists-p drgnx-sandbox-container-files)
           (cons "inside a container: there is no sandbox for jobs' agents here (bubblewrap needs user namespaces the container does not give)"
                 nil))
          ((and (null stderr) (eq system-type 'darwin))
           (cons "sandbox-exec was not found where only root can change it"
                 "it ships with macOS at /usr/bin/sandbox-exec: check that it is there"))
          ((null stderr)
           (cons "bubblewrap (bwrap) is not installed, or not where only root can change it" (drgnx-sandbox--install-fix)))
          ((string-match-p "setting up uid map: Permission denied" stderr)
           (cons "AppArmor restricts unprivileged user namespaces" drgnx-sandbox--apparmor-fix))
          ((string-match-p "user namespaces\\|creating new namespace" stderr)
           (cons "the kernel does not allow unprivileged user namespaces"
                 "allow them: sudo sysctl -w kernel.unprivileged_userns_clone=1 (Debian's switch) or user.max_user_namespaces=15000"))
          (t (cons (format "the sandbox cannot start here: %s" (or first "no message"))
                   (and (not (eq system-type 'darwin))
                        "run the probe by hand to see more: bwrap --unshare-all --unshare-user --disable-userns --ro-bind / / true"))))))

(defun drgnx-sandbox--probes (backend)
  "The check's probes for BACKEND, ((KEY . ARGV)…), each run by the hub: :probe, the sandbox's smallest run (the
argv every agent gets, around /usr/bin/true); :version (bwrap); :scope, a systemd scope like the memory cap's, where
there is a trusted systemd-run.  Nil when the back end's program is not there."
  (pcase backend
    ('bwrap
     (when-let* ((bwrap (drgnx-sandbox-program "bwrap")))
       (let ((run (drgnx-sandbox-program "systemd-run")))
         `((:probe . ,(drgnx-sandbox-bwrap-argv (drgnx-sandbox-spec :memory-max nil) '("/usr/bin/true")))
           (:version ,bwrap "--version")
           ,@(and run `((:scope ,run "--user" "--scope" "--quiet" "-p" "MemoryMax=64M" "-p" "MemorySwapMax=0" "--"
                                "/usr/bin/true")))))))
    ('seatbelt
     (when-let* ((exe (drgnx-sandbox-program "sandbox-exec")))
       `((:probe ,exe "-p" "(version 1)(allow default)" "/usr/bin/true"))))))

(defun drgnx-sandbox--answer (backend probes)
  "The check's plist for BACKEND from PROBES: ((KEY EXIT . OUTPUT)…) of what its probes gave, nil when its program
is not there, or a string: why even the probe was refused."
  (let* ((probe (cdr (assq :probe probes)))
         (v (cdr (assq :version probes)))
         (version (and (eql (car v) 0) (string-match "[0-9]+\\(?:\\.[0-9]+\\)+" (cdr v)) (match-string 0 (cdr v)))))
    (if (eql (car probe) 0)
        (list :ok t :backend backend :version version :scope (eql (car (cdr (assq :scope probes))) 0))
      (let ((why (cond ((null backend)
                        (cons "no sandbox on this system: jobs' agents are sandboxed on Linux (bubblewrap) and macOS" nil))
                       ((stringp probes) (cons probes nil))
                       ((eq (car probe) :timeout) (cons (concat "the sandbox's probe " (cdr probe)) nil))
                       (t (drgnx-sandbox--explain (cdr probe))))))
        (list :ok nil :backend backend :version version :reason (car why) :fix (cdr why))))))

(defun drgnx-sandbox--check-done (run answer)
  "End the check RUN, (GENERATION . DONES), with ANSWER: keep it unless `drgnx-sandbox-check-reset' came since, and
hand it to each DONE of RUN.  A second call for the same RUN does nothing."
  (let ((waiting (reverse (cdr run))))
    (setcdr run nil)
    (when (eq drgnx-sandbox--check-waiting run) (setq drgnx-sandbox--check-waiting nil))
    (when (eql (car run) drgnx-sandbox--check-generation) (setq drgnx-sandbox--checked answer))
    (setcar run :done)
    (dolist (done waiting) (with-demoted-errors "drgnx sandbox check: %S" (funcall done answer)))))

(defun drgnx-sandbox-check-async (done)
  "Check, never blocking, that job agents can be sandboxed here; DONE gets `drgnx-sandbox-check''s plist.  For the hub.
The probes (`drgnx-sandbox--probes') run side by side as processes of their own, each for at most
`drgnx-sandbox-check-timeout' seconds.  Their programs are looked for again (`drgnx-sandbox-program-reset'), so a
bubblewrap installed since is seen.  The answer is kept until `drgnx-sandbox-check-reset': with one kept, or when no
probe can run, DONE is called before this returns; a call while a check runs waits for that one.  Any error ends the
check with an answer that says so: every DONE is always called.  Never prompts."
  (cond (drgnx-sandbox--checked (funcall done drgnx-sandbox--checked))
        (drgnx-sandbox--check-waiting (push done (cdr drgnx-sandbox--check-waiting)))
        (t
         (let* ((run (list drgnx-sandbox--check-generation done))
                (backend (pcase system-type ('gnu/linux 'bwrap) ('darwin 'seatbelt)))
                (fail (lambda (e) (list :ok nil :backend backend
                                        :reason (format "the sandbox's check failed: %s" (error-message-string e))
                                        :fix nil)))
                (finish (lambda (thunk)
                          (drgnx-sandbox--check-done run (condition-case e (funcall thunk) (error (funcall fail e))))))
                (results nil) (left 0))
           (setq drgnx-sandbox--check-waiting run)
           (condition-case e
               (progn
                 (drgnx-sandbox-program-reset)
                 (let ((probes (condition-case e (and backend (drgnx-sandbox--probes backend))
                                 (drgnx-sandbox-refused (format "the sandbox refuses even its probe: %s" (cadr e))))))
                   (if (not (consp probes))
                       (funcall finish (lambda () (drgnx-sandbox--answer backend probes)))
                     (setq left (length probes))
                     (pcase-dolist (`(,key . ,argv) probes)
                       (let ((land (lambda (r)
                                     (push (cons key r) results)
                                     (when (and (zerop (cl-decf left)) (not (eq (car run) :done)))
                                       (funcall finish (lambda () (drgnx-sandbox--answer backend results)))))))
                         (condition-case e
                             (drgnx-sandbox--spawn "drgnx-sandbox-check" argv drgnx-sandbox-check-timeout land)
                           (error (funcall land (cons 127 (error-message-string e))))))))))
             (error (unless (eq (car run) :done) (drgnx-sandbox--check-done run (funcall fail e))))))))
  nil)

(defun drgnx-sandbox-check ()
  "Can job agents be sandboxed here: (:ok BOOL :backend SYM :version STRING :reason STRING :fix STRING :scope BOOL).
:reason and :fix say why not and what to do (nil :fix: nothing can be done here); :scope, whether a systemd user
manager answers, so agents run under the memory cap.  Synchronous, for the doctor and the CLI: it waits for
`drgnx-sandbox-check-async' (about `drgnx-sandbox-check-timeout' seconds at most), which the hub uses instead.  Kept
until `drgnx-sandbox-check-reset'."
  (or drgnx-sandbox--checked
      (let ((answer nil) (deadline (+ (float-time) drgnx-sandbox-check-timeout 1)))
        (drgnx-sandbox-check-async (lambda (a) (setq answer a)))
        (while (and (not answer) (< (float-time) deadline)) (accept-process-output nil 0.05))
        (or answer (list :ok nil :reason "the sandbox's check did not answer" :fix nil)))))

(defun drgnx-sandbox-check-reset ()
  "Forget the check's answer and the programs found (`drgnx-sandbox-program-reset'): the next check looks again.  A
check that runs still answers its own callers, but its answer is not kept, and later calls start a new one."
  (setq drgnx-sandbox--checked nil drgnx-sandbox--check-waiting nil)
  (cl-incf drgnx-sandbox--check-generation)
  (drgnx-sandbox-program-reset))

;;;; Toolchains

(defconst drgnx-sandbox--toolchain-layouts
  '("\\.local/share/mise/installs/[^/]+/[^/]+" "\\.cargo/bin" "\\.rustup/toolchains" "go/bin" "\\.nvm/versions/node/[^/]+"
    "\\.npm-global" "\\.local/lib/node_modules/\\(?:@[^/]+/\\)?[^/]+" "\\.local/share/pipx/venvs/[^/]+"
    "\\.local/pipx/venvs/[^/]+" "\\.local/share/uv/tools/[^/]+" "\\.local/share/uv/python/[^/]+"
    "\\.local/share/claude/versions")
  "Where a toolchain installs under HOME, as regexps on a path relative to HOME, each matching whole path
components from the start: what one matches is the root.  mise's installs/TOOL/VER in its default data dir (and in
the one $MISE_DATA_DIR or $XDG_DATA_HOME names: `drgnx-sandbox--layouts'), cargo, rustup, go, nvm, npm's prefix
\(~/.npm-global, or ~/.local's node_modules/PKG), pipx's and uv's tool venvs and uv's Pythons, Claude Code's
versioned binaries.")

(defun drgnx-sandbox--layouts (home)
  "`drgnx-sandbox--toolchain-layouts', with mise's installs/TOOL/VER in the data dir the environment gives it
\($MISE_DATA_DIR, else $XDG_DATA_HOME/mise) where that is inside HOME (a true name with a slash)."
  (let* ((env (lambda (v) (let ((d (getenv v))) (and d (file-name-absolute-p d) d))))
         (data (or (funcall env "MISE_DATA_DIR")
                   (let ((x (funcall env "XDG_DATA_HOME"))) (and x (expand-file-name "mise" x)))))
         (true (and data (drgnx-sandbox--truename data))))
    (if (and true (string-prefix-p home true) (> (length true) (length home)))
        (cons (concat (regexp-quote (substring true (length home))) "/installs/[^/]+/[^/]+")
              drgnx-sandbox--toolchain-layouts)
      drgnx-sandbox--toolchain-layouts)))

(defconst drgnx-sandbox--toolchain-also '((".cargo/bin" . ".rustup/toolchains"))
  "A root (relative to HOME) → another root it runs: cargo's proxies run rustup's toolchains.")

(defconst drgnx-sandbox--home-config '(".config" ".local/share" ".local/state" ".cache")
  "Dirs of HOME where every tool keeps its config, state and tokens (drgnx's own too): nothing in them is a toolchain
root but a known layout (`drgnx-sandbox--toolchain-layouts').")

(defconst drgnx-sandbox--home-closed '(".ssh" ".gnupg" ".aws" ".kube" ".docker" ".password-store")
  "Dirs of HOME no toolchain root is in: keys and credentials.")

(defun drgnx-sandbox--toolchain-layout (path home)
  "The root of the toolchain layout PATH is in (`drgnx-sandbox--layouts'), or nil.  PATH is a true name strictly
inside HOME (a true name with a slash)."
  (let ((rel (substring path (length home))))
    (cl-loop for re in (drgnx-sandbox--layouts home)
             when (string-match (concat "\\`\\(" re "\\)\\(?:/\\|\\'\\)") rel)
             return (concat home (match-string 1 rel)))))

(defun drgnx-sandbox--toolchain-root (path home)
  "PATH's install root: the root of the toolchain layout it is in, else PATH itself (see
`drgnx-sandbox--toolchain-layout')."
  (or (drgnx-sandbox--toolchain-layout path home) path))

(defun drgnx-sandbox--program-file-p (file home)
  "May FILE, a link's target in no toolchain layout, be bound alone: is it a program — a regular file with an
execute bit, not directly in HOME (a true name with a slash; ~/.netrc, ~/.npmrc live there), its name none of
`drgnx-sandbox-secret-files'?"
  (let ((name (file-name-nondirectory file)))
    (and (file-regular-p file) (file-executable-p file)
         (not (string= (file-name-directory file) home))
         (not (cl-some (lambda (s) (string= name (file-name-nondirectory s))) drgnx-sandbox-secret-files)))))

(defun drgnx-sandbox--root-ok-p (root home)
  "May ROOT be a toolchain root, HOME's (with a slash) true name: strictly inside it; not ~/.local, nor in ~/.ssh,
~/.gnupg and the like (`drgnx-sandbox--home-closed'); in ~/.config, ~/.local/share, ~/.local/state or ~/.cache
only as a known layout's root."
  (and (string-prefix-p home root)
       (not (string= root (concat home ".local")))
       (not (cl-some (lambda (d) (drgnx-sandbox--within-p root (concat home d))) drgnx-sandbox--home-closed))
       (or (equal (drgnx-sandbox--toolchain-layout root home) root)
           (not (cl-some (lambda (d) (drgnx-sandbox--within-p root (concat home d))) drgnx-sandbox--home-config)))))

(defun drgnx-sandbox-toolchain-roots (path-dirs home)
  "The read-only roots under HOME that the PATH-DIRS there need, sorted true names: dirs, and single files.
- Each dir of PATH-DIRS inside HOME, its links resolved, gives its install root: the root of its toolchain layout
  (`drgnx-sandbox--toolchain-layouts': mise's installs/TOOL/VER, ~/.cargo/bin and ~/.rustup/toolchains, ~/go/bin,
  nvm's versions/node/V, npm's prefix, pipx's and uv's venvs …), else the dir itself.
- Each link in such a dir (~/.local/bin's) gives the root of the layout it leads into; a link into no layout gives
  its target file alone, read-only — never the dir it is in — and a link to a dir in no layout gives nothing.
- A link into drgnx's data dir or checkout gives nothing: drgnx's own files reach a sandbox only by an explicit bind.
Never a root: HOME nor a parent of it, ~/.local, anything in ~/.ssh, ~/.gnupg and the like, or in ~/.config,
~/.local/share, ~/.local/state or ~/.cache but a known layout; nor what `drgnx-sandbox-validate' refuses to read.  A
root inside another is left to it.  Dirs outside HOME are the system's reads."
  (let* ((file-name-handler-alist nil)
         (true-home (and (stringp home) (drgnx-sandbox--truename home)))
         (home (and true-home (file-name-as-directory true-home)))
         (own (delq nil (mapcar #'drgnx-sandbox--truename (list (drgnx-data-dir) drgnx-dir))))
         (roots nil)
         (add (lambda (r)
                (when (and r (drgnx-sandbox--root-ok-p r home)) (push r roots) r))))
    (when home
      (dolist (dir path-dirs)
        (let* ((true (and (stringp dir) (file-name-absolute-p dir) (file-directory-p dir) (drgnx-sandbox--truename dir)))
               (root (and true (string-prefix-p home true) (funcall add (drgnx-sandbox--toolchain-root true home)))))
          (when root
            (pcase-dolist (`(,from . ,to) drgnx-sandbox--toolchain-also)
              (when (and (string= root (concat home from)) (file-directory-p (concat home to)))
                (funcall add (concat home to))))
            (dolist (f (directory-files true t "\\`[^.]" t))
              (when (file-symlink-p f)
                (let ((target (drgnx-sandbox--truename f)))
                  (when (and target (string-prefix-p home target) (file-exists-p target)
                             (not (cl-some (lambda (o) (drgnx-sandbox--within-p target o)) own)))
                    (funcall add (or (drgnx-sandbox--toolchain-layout target home)
                                     (and (drgnx-sandbox--program-file-p target home) target))))))))))
      ;; what Task 3's rules refuse to read is never a root either
      (let* ((ctx (drgnx-sandbox--context))
             (all (cl-remove-if (lambda (r)
                                  (or (not (file-exists-p r))
                                      (catch 'drgnx-sandbox--refused (drgnx-sandbox--check-source ctx :read r) nil)))
                                (delete-dups roots))))
        (sort (cl-remove-if (lambda (r) (cl-some (lambda (o) (drgnx-sandbox--under-p r o)) all)) all) #'string<)))))

(defun drgnx-sandbox-toolchain-hide (roots)
  "The `:hide' list for ROOTS: each of `drgnx-sandbox-secret-files' inside a root, where it is there, as its true
name (a link to a file in a root hides that file); sorted.  Only those exact places: a token deeper in a toolchain's
tree is not found."
  (let ((file-name-handler-alist nil))
    (sort (delete-dups
           (cl-loop for root in roots
                    nconc (cl-loop for name in drgnx-sandbox-secret-files
                                   for f = (expand-file-name name root)
                                   for true = (and (file-exists-p f) (drgnx-sandbox--truename f))
                                   when (and true (cl-some (lambda (r) (drgnx-sandbox--under-p true r)) roots))
                                   collect true)))
          #'string<)))

;;;; The environment

(defun drgnx-sandbox-base-env ()
  "The environment every sandbox starts from, from this Emacs's: PATH, HOME, USER, LANG and LC_* where set,
TERM=dumb, SHELL, TMPDIR=/tmp.  Nothing else: no socket, display, key or drgnx variable."
  (let ((pass (lambda (name) (let ((v (getenv name))) (and v (cons name v))))))
    (delq nil (append (mapcar pass '("PATH" "HOME" "USER" "LANG"))
                      (mapcar pass (sort (delete-dups (cl-loop for e in process-environment
                                                               when (string-match "\\`\\(LC_[A-Z_]+\\)=" e)
                                                               collect (match-string 1 e)))
                                         #'string<))
                      (list (cons "TERM" "dumb") (funcall pass "SHELL") (cons "TMPDIR" "/tmp"))))))

(provide 'drgnx-sandbox)
;;; drgnx-sandbox.el ends here
