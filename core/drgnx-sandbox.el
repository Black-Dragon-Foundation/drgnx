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

(declare-function drgnx-hub-socket "drgnx-hub" ())
(declare-function drgnx-sandbox-sbpl "drgnx-sandbox-macos" (spec))

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

(defconst drgnx-sandbox-trusted-programs '(("bwrap" . "/usr/bin/bwrap") ("sandbox-exec" . "/usr/bin/sandbox-exec"))
  "Where each sandbox program is looked for first, before `exec-path'.")

(defvar drgnx-sandbox--programs nil
  "Program name → its checked absolute path, or nil when there is none (`drgnx-sandbox-program'), cached until
`drgnx-sandbox-program-reset'.")

(defvar drgnx-sandbox-resolv-conf "/etc/resolv.conf"
  "The resolver's configuration.  Where it is a link to a file under /run (systemd-resolved's stub), that file is
bound read-only inside, so names resolve under the empty /run.")

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
  :memory-max STRING         the memory cap
Nothing is checked here: `drgnx-sandbox-validate' says what is refused, and the back ends refuse it."
  (let ((spec (cl-loop for (key value) on props by #'cddr
                       nconc (list key (drgnx-sandbox--resolve-value key value)))))
    (if (plist-get spec :net) spec (append spec (list :net 'shared)))))

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
  :closed ((DIR . WHAT)…)   …nor be inside one of these, unless strictly inside an :open dir;
  :open (DIR…)              the private homes' dir in the state dir;
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
inside a :closed dir but inside an :open one — except that `:run' is a session's own dir.  MUST-EXIST: refuse it
when it is not there.  WRITABLE (a read-write bind): refuse it when it is or holds a dir of `exec-path'."
  (drgnx-sandbox--check-path key path)
  (pcase-dolist (`(,dir . ,what) (plist-get ctx :never))
    (when (drgnx-sandbox--within-p dir path)
      (drgnx-sandbox--refuse "%s: %s would expose %s (%s)" key path what dir)))
  (unless (and (eq key :run) (drgnx-sandbox--session-dir-p ctx path))
    (pcase-dolist (`(,dir . ,what) (plist-get ctx :closed))
      (when (and (drgnx-sandbox--within-p path dir)
                 (not (cl-some (lambda (o) (drgnx-sandbox--under-p path o)) (plist-get ctx :open))))
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
  (unless (or (null (plist-get spec :memory-max)) (stringp (plist-get spec :memory-max)))
    (drgnx-sandbox--refuse ":memory-max is not a string")))

(defun drgnx-sandbox-validate (spec)
  "Why SPEC must not be used, or nil.  Refused:
- a spec that is not a plist of `drgnx-sandbox--keys' with values of their shape; an `:env' name in
  `drgnx-sandbox-env-deny';
- a path that is relative, holds a NUL or a newline, is not in canonical form (`//', `.', `..', a trailing slash),
  or is not its own true name (a link, or one swapped in since `drgnx-sandbox-spec' resolved it);
- binding from outside (`:read', `:write', `:binds', `:home', `:run', `:tmp') $HOME, the checkout, the ssh agent's
  or the D-Bus socket, or any parent of them; and anything in or above /run/user, $XDG_RUNTIME_DIR, the hub's socket
  dirs, drgnx's data, config and state dirs (but the private homes, <state>/sandbox/…), /proc, /sys, /dev, the X11
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
its `:profile-file'.  Signals `drgnx-sandbox-refused' when SPEC is refused or there is no sandbox: never the command
as it was."
  (pcase (or (plist-get spec :backend) (drgnx-sandbox-backend))
    ('bwrap (drgnx-sandbox-bwrap-argv spec command))
    ('seatbelt
     (drgnx-sandbox--assert spec command)
     (let ((file (plist-get spec :profile-file)) (exe (drgnx-sandbox-program "sandbox-exec")))
       (unless file (signal 'drgnx-sandbox-refused (list "no :profile-file for the Seatbelt profile")))
       (unless exe (signal 'drgnx-sandbox-refused (list "no sandbox-exec that only root can change")))
       (unless (fboundp 'drgnx-sandbox-sbpl) (require 'drgnx-sandbox-macos))
       (drgnx-sandbox--write-private file (drgnx-sandbox-sbpl spec))
       (append (list exe "-f" file) command)))
    (_ (signal 'drgnx-sandbox-refused
               (list "no sandbox on this system (Linux: install bubblewrap; macOS: sandbox-exec)")))))

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
