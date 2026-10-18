;;; sandbox-test.el --- batch tests: the sandbox spec and its bubblewrap argv -*- lexical-binding: t -*-
;; Mostly pure: the tests build a spec and an argv and look at them.  Two smoke tests run the generated argv under the
;; real bwrap (`true', a shell's checks, a socket's round trip) where bwrap can run, and skip with the reason where
;; it cannot.  Every path is in the test's temporary directory: its HOME, its XDG_RUNTIME_DIR, its state, data and
;; config dirs.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-sandbox)
(require 'drgnx-ai)

(defconst drgnx-sandbox-test--system-read drgnx-sandbox-system-read "The real system reads, for the smoke tests.")

(defmacro drgnx-sandbox-test--with (&rest body)
  "BODY with a fixture tree under ROOT (true names, no trailing slash):
HOME the user's home, RUN the runtime dir, SID a session's socket dir under RUN/drgnx/s/, FOLDER a task folder in a
repository under HOME, PHOME a private home under the state dir, TOOL a toolchain root under HOME, SECRET a file in
it, SSH the ssh agent's socket.  The environment points at them, the system reads are /usr only, there is no
resolver file, and bwrap and sandbox-exec are /usr/bin's."
  (declare (indent 0))
  `(let* ((root (directory-file-name (file-truename (make-temp-file "drgnx-sb" t))))
          (home (concat root "/home")) (run (concat root "/run")) (sid (concat run "/drgnx/s/7"))
          (folder (concat home "/repo/.claude/worktrees/1-1"))
          (phome (concat root "/state/drgnx/sandbox/1/home-1"))
          (tool (concat home "/.local/share/mise/installs/node/20")) (secret (concat tool "/.npmrc"))
          (ssh (concat root "/ssh-x/agent.1"))
          (process-environment (append (list (concat "HOME=" home) (concat "XDG_RUNTIME_DIR=" run)
                                             (concat "XDG_STATE_HOME=" root "/state") (concat "DRGNX_DATA_DIR=" root "/data")
                                             (concat "DRGNX_CONFIG_DIR=" home "/.config/drgnx")
                                             (concat "SSH_AUTH_SOCK=" ssh)
                                             (concat "DBUS_SESSION_BUS_ADDRESS=unix:path=" root "/dbus/bus,guid=1"))
                                       process-environment))
          (drgnx-sandbox-system-read '((ro-try "/usr")))
          (drgnx-sandbox-resolv-conf (concat root "/no-resolv.conf"))
          (drgnx-sandbox--programs '(("bwrap" . "/usr/bin/bwrap") ("sandbox-exec" . "/usr/bin/sandbox-exec"))))
     (unwind-protect
         (progn
           (dolist (d (list folder phome tool sid (concat folder "/.git") (concat home "/.ssh") (concat run "/drgnx/s/8")
                            (concat root "/data") (concat home "/.config/drgnx") (concat root "/state/drgnx/jobs")
                            (concat root "/ssh-x") (concat root "/dbus")))
             (make-directory d t))
           (write-region "" nil (concat root "/data/work.db") nil 'silent)
           (write-region "" nil (concat home "/.config/drgnx/agents.eld") nil 'silent)
           (write-region "token" nil secret nil 'silent)
           (write-region "x" nil (concat run "/bus") nil 'silent)
           (write-region "x" nil (concat run "/drgnx/hub-0.sock") nil 'silent)
           ,@body)
       (delete-directory root t))))

(defun drgnx-sandbox-test--sources (argv)
  "The outside paths ARGV binds: what follows each bind flag."
  (cl-loop for (a b) on argv
           when (member a '("--bind" "--bind-try" "--ro-bind" "--ro-bind-try" "--dev-bind" "--dev-bind-try"))
           collect b))

(defun drgnx-sandbox-test--within-p (path dir)
  (or (string= path dir) (string-prefix-p (file-name-as-directory dir) path)))

(defun drgnx-sandbox-test--refused (spec)
  "SPEC's refusal: `drgnx-sandbox-validate''s reason, which must also be what `drgnx-sandbox-bwrap-argv' signals."
  (let ((reason (drgnx-sandbox-validate spec)))
    (should (stringp reason))
    (should (equal (should-error (drgnx-sandbox-bwrap-argv spec '("agent")) :type 'drgnx-sandbox-refused)
                   (list 'drgnx-sandbox-refused reason)))
    reason))

(ert-deftest drgnx-sandbox/exact-argv ()
  "The whole argv for a session's spec, in its order."
  (drgnx-sandbox-test--with
    (let ((spec (drgnx-sandbox-spec :home (cons phome home) :read (list tool) :write (list folder) :run sid
                                    :binds (list (list 'ro (concat folder "/.git") (concat folder "/.git")))
                                    :hide (list secret) :env `(("PATH" . "/usr/bin") ("HOME" . ,home)) :chdir folder)))
      (should-not (drgnx-sandbox-validate spec))
      (should (equal (drgnx-sandbox-bwrap-argv spec '("agent" "--acp"))
                     `("/usr/bin/bwrap" "--unshare-all" "--unshare-user" "--share-net" "--disable-userns"
                       "--die-with-parent" "--new-session"
                       "--clearenv" "--setenv" "PATH" "/usr/bin" "--setenv" "HOME" ,home
                       "--ro-bind-try" "/usr" "/usr"
                       "--dev" "/dev" "--proc" "/proc" "--tmpfs" "/tmp" "--tmpfs" "/run" "--tmpfs" "/var/tmp"
                       "--bind" ,phome ,home
                       "--ro-bind-try" ,tool ,tool
                       "--bind" ,folder ,folder
                       "--ro-bind" ,sid "/run/drgnx"
                       "--ro-bind" ,(concat folder "/.git") ,(concat folder "/.git")
                       "--ro-bind" "/dev/null" ,secret
                       "--chdir" ,folder "--" "agent" "--acp"))))))

(ert-deftest drgnx-sandbox/mandatory-flags ()
  "The mandatory flags are always there, before any bind, whatever the spec holds (an empty one too):
`--disable-userns' needs an explicit `--unshare-user' (`--unshare-all' only tries one)."
  (drgnx-sandbox-test--with
    (dolist (spec (list (drgnx-sandbox-spec)
                        (drgnx-sandbox-spec :net 'isolated :write (list folder) :chdir folder)
                        (drgnx-sandbox-spec :home (cons phome home) :run sid :env '(("A" . "b")))))
      (let* ((argv (drgnx-sandbox-bwrap-argv spec '("true")))
             (first-bind (cl-position-if (lambda (a) (string-prefix-p "--ro-bind" a)) argv)))
        (should (equal (car argv) "/usr/bin/bwrap"))
        (should (< (cl-position "--unshare-user" argv :test #'equal) (cl-position "--disable-userns" argv :test #'equal)))
        (dolist (flag '("--unshare-all" "--unshare-user" "--disable-userns" "--die-with-parent" "--new-session"
                        "--clearenv"))
          (should (member flag argv))
          (should (< (cl-position flag argv :test #'equal) first-bind)))
        (dolist (tmpfs '("/tmp" "/run" "/var/tmp"))
          (should (cl-loop for (a b) on argv thereis (and (equal a "--tmpfs") (equal b tmpfs)))))
        (should (equal (last argv 2) '("--" "true")))))))

(ert-deftest drgnx-sandbox/never-binds-home-or-runtime ()
  "$HOME, /run/user/UID, the runtime dir, the hub's socket dir and their parents are refused in every place a spec
binds from, `//' spellings too; so is anything inside the runtime dir, drgnx's data, config and state dirs (but the
private homes), /proc, /sys, /dev, the Emacs server's /tmp dir, the ssh agent's and D-Bus's sockets, and any
session's dir but as `:run'.  An accepted spec's argv binds none of them."
  (drgnx-sandbox-test--with
    (let ((forbidden (list home root "/" (format "/run/user/%d" (user-uid)) "/run/user" "/run" run (concat run "/drgnx")
                           (concat run "/drgnx/s") (concat run "/bus") (concat run "/drgnx/hub-0.sock")
                           (concat root "/data") (concat root "/state") (concat home "/.config")
                           "//" "///" (concat "/" home) "//run/user" (concat "//" run)
                           (concat root "/data/work.db") (concat home "/.config/drgnx/agents.eld")
                           (concat root "/state/drgnx/jobs") (concat root "/state/drgnx/sandbox")
                           "/proc" "/proc/1" "/sys" "/sys/kernel" "/dev" "/dev/shm"
                           (format "/tmp/emacs%d" (user-uid)) ssh (concat root "/ssh-x") (concat root "/dbus/bus")
                           sid (concat sid "/out") (concat run "/drgnx/s/8"))))
      (dolist (path forbidden)
        (dolist (spec (list (drgnx-sandbox-spec :read (list path)) (drgnx-sandbox-spec :write (list path))
                            (drgnx-sandbox-spec :binds (list (list 'ro path "/x")))
                            (drgnx-sandbox-spec :binds (list (list 'rw path "/x")))
                            (drgnx-sandbox-spec :home (cons path home))))
          (ert-info ((format "%S" spec))
            (should (string-match-p "would expose\\|is inside" (drgnx-sandbox-test--refused spec)))))))
    ;; another session's dir: never, not even next to the spec's own :run
    (dolist (spec (list (drgnx-sandbox-spec :run sid :write (list (concat run "/drgnx/s/8")))
                        (drgnx-sandbox-spec :run sid :binds (list (list 'rw (concat run "/drgnx/s/8") "/run/drgnx")))
                        (drgnx-sandbox-spec :run sid :binds (list (list 'rw (concat sid "/out") "/run/drgnx/out")))))
      (make-directory (concat sid "/out") t)
      (ert-info ((format "%S" spec)) (drgnx-sandbox-test--refused spec)))
    ;; what is accepted binds nothing of them
    (let* ((spec (drgnx-sandbox-spec :home (cons phome home) :read (list tool) :write (list folder) :run sid))
           (argv (drgnx-sandbox-bwrap-argv spec '("agent"))))
      (dolist (src (drgnx-sandbox-test--sources argv))
        (dolist (dir (list home run (format "/run/user/%d" (user-uid))))
          (should-not (drgnx-sandbox-test--within-p dir src)))
        (when (drgnx-sandbox-test--within-p src run)
          (should (string-prefix-p (concat run "/drgnx/s/") src))))
      (should-not (cl-find-if (lambda (a) (string-match-p "\\`/run/user" a)) argv)))))

(ert-deftest drgnx-sandbox/write-of-home-refused ()
  (drgnx-sandbox-test--with
    (dolist (spec (list (drgnx-sandbox-spec :write (list home)) (drgnx-sandbox-spec :write '("~"))
                        (drgnx-sandbox-spec :write (list (concat home "/"))) (drgnx-sandbox-spec :home (cons home home))
                        (drgnx-sandbox-spec :binds (list (list 'rw home home)))))
      (should (string-match-p "would expose your home directory" (drgnx-sandbox-test--refused spec))))
    ;; inside it is fine: a task folder, a toolchain
    (should-not (drgnx-sandbox-validate (drgnx-sandbox-spec :write (list folder) :read (list tool))))))

(ert-deftest drgnx-sandbox/symlinks-resolve ()
  "A link is bound as its target: a link to ~ planted in the task folder is a write of ~ (refused); a link inside the
folder binds what it points to.  A link swapped in after the spec was made is refused, and so is a spec whose paths
were never resolved."
  (drgnx-sandbox-test--with
    (make-symbolic-link home (concat folder "/escape"))
    (drgnx-sandbox-test--refused (drgnx-sandbox-spec :write (list (concat folder "/escape"))))
    (drgnx-sandbox-test--refused (drgnx-sandbox-spec :read (list (concat folder "/escape"))))
    (make-directory (concat folder "/real"))
    (make-symbolic-link (concat folder "/real") (concat folder "/inner"))
    (let ((spec (drgnx-sandbox-spec :write (list (concat folder "/inner")))))
      (should (equal (plist-get spec :write) (list (concat folder "/real"))))
      (should (member (concat folder "/real") (drgnx-sandbox-bwrap-argv spec '("a"))))
      (should-not (member (concat folder "/inner") (drgnx-sandbox-bwrap-argv spec '("a")))))
    ;; swapped for a link to ~ after the spec was made
    (make-directory (concat folder "/later"))
    (let ((spec (drgnx-sandbox-spec :write (list (concat folder "/later")))))
      (delete-directory (concat folder "/later"))
      (make-symbolic-link home (concat folder "/later"))
      (drgnx-sandbox-test--refused spec))
    ;; a spec made by hand with a link in it
    (drgnx-sandbox-test--refused (list :write (list (concat folder "/inner")) :net 'shared))))

(ert-deftest drgnx-sandbox/hostile-paths-refused ()
  "Relative paths, NUL and newline, and paths that a bind needs but are not there are refused; nothing is quoted."
  (drgnx-sandbox-test--with
    (dolist (spec (list (drgnx-sandbox-spec :write '("repo")) (drgnx-sandbox-spec :read '("./x"))
                        (drgnx-sandbox-spec :write (list (concat folder "\n/x"))) (drgnx-sandbox-spec :read (list (concat folder "\0x")))
                        (drgnx-sandbox-spec :chdir "repo") (drgnx-sandbox-spec :write (list (concat folder "/missing")))
                        (drgnx-sandbox-spec :write '("/ssh:host:/x")) (drgnx-sandbox-spec :home (cons (concat root "/nohome") home))
                        (drgnx-sandbox-spec :binds '((rw "/x"))) (drgnx-sandbox-spec :binds (list (list 'xx folder folder)))
                        (drgnx-sandbox-spec :net 'open) (drgnx-sandbox-spec :writes (list folder))
                        (drgnx-sandbox-spec :env '(("A=B" . "c"))) (drgnx-sandbox-spec :env '(("A" . "c\0d")))
                        ;; made by hand, so never resolved: not in canonical form
                        '(:read ("//")) '(:read ("///usr")) `(:read (,(concat "/" home)))
                        '(:read ("/usr/./bin")) '(:read ("/usr/bin/..")) '(:read ("/usr/../etc"))
                        `(:write (,(concat folder "/"))) `(:write (,(concat folder "//x")))))
      (ert-info ((format "%S" spec)) (drgnx-sandbox-test--refused spec)))
    ;; a path with spaces, quotes and a leading dash in its name is one argv element, as it is
    (let ((odd (concat folder "/a b'\"$(x) -c")))
      (make-directory odd)
      (should (member odd (drgnx-sandbox-bwrap-argv (drgnx-sandbox-spec :write (list odd)) '("a")))))
    (should-error (drgnx-sandbox-bwrap-argv (drgnx-sandbox-spec) nil) :type 'drgnx-sandbox-refused)))

(ert-deftest drgnx-sandbox/run-is-a-sessions-dir ()
  "`:run' must be one session's dir directly in the runtime dir's drgnx/s/; `:sockets' must be in it."
  (drgnx-sandbox-test--with
    (should-not (drgnx-sandbox-validate (drgnx-sandbox-spec :run sid :sockets (list (concat sid "/mcp.sock")))))
    (make-directory (concat sid "/sub"))
    (dolist (spec (list (drgnx-sandbox-spec :run (concat run "/drgnx/s")) (drgnx-sandbox-spec :run (concat run "/drgnx"))
                        (drgnx-sandbox-spec :run (concat sid "/sub"))
                        (drgnx-sandbox-spec :run folder) (drgnx-sandbox-spec :run run)
                        (drgnx-sandbox-spec :run sid :sockets (list (concat run "/drgnx/hub-0.sock")))
                        (drgnx-sandbox-spec :sockets (list (concat sid "/mcp.sock")))))
      (ert-info ((format "%S" spec)) (drgnx-sandbox-test--refused spec)))))

(ert-deftest drgnx-sandbox/order-of-binds ()
  "The `:binds' pins come after `:write' and `:run', in their own order, and before `:hide'."
  (drgnx-sandbox-test--with
    (let* ((pin1 (concat folder "/.git")) (pin2 (concat folder "/.git/config")))
      (write-region "" nil pin2 nil 'silent)
      (let* ((argv (drgnx-sandbox-bwrap-argv
                    (drgnx-sandbox-spec :write (list folder) :run sid :hide (list secret) :read (list tool)
                                        :binds (list (list 'ro pin1 pin1) (list 'rw pin2 pin2)))
                    '("a")))
             (pos (lambda (flag path) (cl-loop for i from 0 for (a b) on argv
                                               when (and (equal a flag) (equal b path)) return i))))
        (should (< (funcall pos "--ro-bind-try" tool) (funcall pos "--bind" folder) (funcall pos "--ro-bind" sid)
                   (funcall pos "--ro-bind" pin1) (funcall pos "--bind" pin2) (funcall pos "--ro-bind" "/dev/null")))))))

(ert-deftest drgnx-sandbox/hide-files-and-dirs ()
  "`:hide': a file is covered by /dev/null, a directory by an empty tmpfs; a path that is not there is left out."
  (drgnx-sandbox-test--with
    (let ((argv (drgnx-sandbox-bwrap-argv (drgnx-sandbox-spec :read (list tool)
                                                              :hide (list secret (concat home "/.ssh") (concat tool "/none")))
                                          '("a"))))
      (should (equal (cl-subseq argv (- (length argv) 7))
                     `("--ro-bind" "/dev/null" ,secret "--tmpfs" ,(concat home "/.ssh") "--" "a"))))))

(ert-deftest drgnx-sandbox/share-net-only-when-shared ()
  (drgnx-sandbox-test--with
    (should (eq (plist-get (drgnx-sandbox-spec) :net) 'shared))
    (should (member "--share-net" (drgnx-sandbox-bwrap-argv (drgnx-sandbox-spec) '("a"))))
    (should (member "--share-net" (drgnx-sandbox-bwrap-argv (drgnx-sandbox-spec :net 'shared) '("a"))))
    (let ((argv (drgnx-sandbox-bwrap-argv (drgnx-sandbox-spec :net 'isolated) '("a"))))
      (should-not (member "--share-net" argv))
      (should (member "--unshare-all" argv)))
    ;; a spec made by hand without :net is isolated
    (should-not (member "--share-net" (drgnx-sandbox-bwrap-argv '(:env nil) '("a"))))))

(ert-deftest drgnx-sandbox/env-is-only-the-spec ()
  "The environment is cleared, then exactly the spec's `:env' is set — nothing of the caller's, and never a socket
variable or the data dir, even when a spec asks for one."
  (drgnx-sandbox-test--with
    (let* ((process-environment (append '("SSH_AUTH_SOCK=/run/user/1/ssh" "DBUS_SESSION_BUS_ADDRESS=unix:path=/x"
                                          "OPENROUTER_API_KEY=sk-or" "LEAK=1")
                                        process-environment))
           (argv (drgnx-sandbox-bwrap-argv (drgnx-sandbox-spec :env '(("PATH" . "/usr/bin") ("TERM" . "dumb"))) '("a")))
           (setenvs (cl-loop for (a n v) on argv when (equal a "--setenv") collect (cons n v))))
      (should (equal setenvs '(("PATH" . "/usr/bin") ("TERM" . "dumb"))))
      (should (< (cl-position "--clearenv" argv :test #'equal) (cl-position "--setenv" argv :test #'equal)))
      (should-not (cl-find-if (lambda (a) (string-match-p "sk-or\\|LEAK\\|SSH_AUTH" a)) argv)))
    (should (member "DRGNX_AGENT" drgnx-sandbox-env-deny))
    (dolist (name drgnx-sandbox-env-deny)
      (drgnx-sandbox-test--refused (drgnx-sandbox-spec :env (list (cons name "x")))))))

(ert-deftest drgnx-sandbox/base-env-has-no-sockets-or-keys ()
  (let* ((keys (delq nil (mapcar (lambda (p) (plist-get (cdr p) :key-env)) drgnx-ai-presets)))
         (process-environment
          (append (list "SSH_AUTH_SOCK=/run/user/1/ssh" "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1/bus"
                        "XDG_RUNTIME_DIR=/run/user/1" "DISPLAY=:0" "WAYLAND_DISPLAY=wayland-0" "DRGNX_DATA_DIR=/d"
                        "PATH=/usr/bin:/bin" "HOME=/home/u" "USER=u" "LANG=C.UTF-8" "LC_ALL=C" "LC_TIME=en_GB.UTF-8"
                        "SHELL=/bin/zsh" "TERM=xterm-256color" "TMPDIR=/var/tmp/u")
                  (mapcar (lambda (k) (concat k "=secret")) keys)
                  (cl-remove-if (lambda (e) (string-prefix-p "LC_" e)) process-environment)))
         (env (drgnx-sandbox-base-env)))
    (should keys)
    (should (equal env '(("PATH" . "/usr/bin:/bin") ("HOME" . "/home/u") ("USER" . "u") ("LANG" . "C.UTF-8")
                         ("LC_ALL" . "C") ("LC_TIME" . "en_GB.UTF-8") ("TERM" . "dumb") ("SHELL" . "/bin/zsh")
                         ("TMPDIR" . "/tmp"))))
    (dolist (name (append keys drgnx-sandbox-env-deny))
      (should-not (assoc name env)))
    (should-not (cl-find-if (lambda (e) (string-match-p "secret" (cdr e))) env))))

(ert-deftest drgnx-sandbox/system-reads ()
  "The system's read-only roots; /bin, /lib, /lib64 and /sbin are links into /usr where the host's are, else bound."
  (should (equal (mapcar #'cadr drgnx-sandbox-system-read)
                 '("/usr" "/etc" "/opt" "/nix" "/gnu" "/var/lib/flatpak" "/bin" "/lib" "/lib64" "/sbin")))
  (should (cl-every (lambda (e) (memq (car e) '(ro-try link))) drgnx-sandbox-system-read))
  (let ((tmp (directory-file-name (file-truename (make-temp-file "drgnx-sb-sys" t)))))
    (unwind-protect
        (progn
          (make-symbolic-link "usr/bin" (concat tmp "/bin"))
          (make-directory (concat tmp "/lib"))
          (let ((drgnx-sandbox-system-read `((ro-try "/usr") (link ,(concat tmp "/bin")) (link ,(concat tmp "/lib"))
                                             (link ,(concat tmp "/lib64")))))
            (should (equal (drgnx-sandbox--system-argv)
                           `("--ro-bind-try" "/usr" "/usr" "--symlink" "usr/bin" ,(concat tmp "/bin")
                             "--ro-bind-try" ,(concat tmp "/lib") ,(concat tmp "/lib")))))
          (let ((argv (drgnx-sandbox--system-argv)))
            (dolist (dir '("/bin" "/lib" "/lib64" "/sbin"))
              (when (file-symlink-p dir)
                (should (cl-loop for (a b c) on argv thereis (and (equal a "--symlink") (equal c dir))))))))
      (delete-directory tmp t))))

(ert-deftest drgnx-sandbox/backend-from-system ()
  (let ((drgnx-sandbox--programs '(("bwrap" . "/usr/bin/bwrap") ("sandbox-exec" . "/usr/bin/sandbox-exec"))))
    (let ((system-type 'gnu/linux)) (should (eq (drgnx-sandbox-backend) 'bwrap)))
    (let ((system-type 'darwin)) (should (eq (drgnx-sandbox-backend) 'seatbelt)))
    (let ((system-type 'windows-nt)) (should-not (drgnx-sandbox-backend))))
  (let ((drgnx-sandbox--programs '(("bwrap") ("sandbox-exec"))))
    (let ((system-type 'gnu/linux)) (should-not (drgnx-sandbox-backend)))
    (let ((system-type 'darwin)) (should-not (drgnx-sandbox-backend)))
    ;; no back end: refused, never the command as it was
    (let ((system-type 'gnu/linux))
      (should-error (drgnx-sandbox-wrap (drgnx-sandbox-spec) '("agent")) :type 'drgnx-sandbox-refused))
    (should-error (drgnx-sandbox-bwrap-argv (drgnx-sandbox-spec) '("agent")) :type 'drgnx-sandbox-refused)))

(ert-deftest drgnx-sandbox/programs-only-root-can-change ()
  "bwrap and sandbox-exec are taken only as files root owns, in a dir root owns, writable by nobody else; found once.
One on the PATH in a dir of the user's is never taken."
  (let ((bin (make-temp-file "drgnx-sb-bin" t)))
    (unwind-protect
        (progn
          (dolist (p '("bwrap" "sandbox-exec"))
            (write-region "" nil (expand-file-name p bin) nil 'silent)
            (set-file-modes (expand-file-name p bin) #o755))
          ;; a dir others can write: never, whoever owns it (the container's tests run as root)
          (set-file-modes bin #o777)
          (let ((drgnx-sandbox--programs nil) (drgnx-sandbox-trusted-programs nil) (exec-path (list bin)))
            (should-not (drgnx-sandbox-program "bwrap"))
            (should-not (drgnx-sandbox-program "sandbox-exec"))
            (should (equal drgnx-sandbox--programs '(("sandbox-exec") ("bwrap")))))
          ;; a dir and file of the user's: never
          (set-file-modes bin #o755)
          (unless (zerop (user-uid))
            (let ((drgnx-sandbox--programs nil) (drgnx-sandbox-trusted-programs nil) (exec-path (list bin)))
              (should-not (drgnx-sandbox-program "bwrap"))))
          (let* ((true (file-truename "/usr/bin/true")) (a (file-attributes true 'integer)))
            (when (and a (eql 0 (file-attribute-user-id a)))
              (let ((drgnx-sandbox--programs nil) (drgnx-sandbox-trusted-programs `(("x" . ,true))) (exec-path (list bin)))
                (should (equal (drgnx-sandbox-program "x") true))
                ;; cached: found once, whatever appears later
                (let ((drgnx-sandbox-trusted-programs nil)) (should (equal (drgnx-sandbox-program "x") true)))
                (drgnx-sandbox-program-reset)
                (should-not drgnx-sandbox--programs)))))
      (delete-directory bin t))))

(ert-deftest drgnx-sandbox/writes-never-on-exec-path ()
  "A read-write bind of a dir the hub finds programs in, or of a dir holding one, is refused: the sandbox would plant
a `bwrap' the hub runs next.  Reading it is fine."
  (drgnx-sandbox-test--with
    (let* ((bin (concat home "/go/bin")) (exec-path (cons bin exec-path)))
      (make-directory bin t)
      (dolist (spec (list (drgnx-sandbox-spec :write (list bin)) (drgnx-sandbox-spec :write (list (concat home "/go")))
                          (drgnx-sandbox-spec :binds (list (list 'rw bin "/x")))
                          (drgnx-sandbox-spec :home (cons (concat home "/go") home))))
        (should (string-match-p "where the hub finds its programs" (drgnx-sandbox-test--refused spec))))
      (should-not (drgnx-sandbox-validate (drgnx-sandbox-spec :read (list bin) :binds (list (list 'ro bin "/x"))))))))

(ert-deftest drgnx-sandbox/resolver-file-bound ()
  "Where /etc/resolv.conf leads under /run (systemd-resolved's stub), that file — only it — is bound read-only after
the empty /run, so names resolve; anywhere else, or under /run/user, nothing."
  (drgnx-sandbox-test--with
    (let ((conf (concat root "/resolv.conf")) (stub "/run/systemd/resolve/stub-resolv.conf")
          (drgnx-sandbox-resolv-conf (concat root "/resolv.conf")))
      (make-symbolic-link stub conf)
      (let ((argv (drgnx-sandbox-bwrap-argv (drgnx-sandbox-spec) '("a"))))
        (should (equal (cl-subseq argv (cl-position "/var/tmp" argv :test #'equal))
                       `("/var/tmp" "--ro-bind-try" ,stub ,stub "--" "a"))))
      (delete-file conf)
      (make-symbolic-link "/run/user/1/x" conf)
      (should-not (member "/run/user/1/x" (drgnx-sandbox-bwrap-argv (drgnx-sandbox-spec) '("a"))))
      (delete-file conf)
      (write-region "nameserver 127.0.0.1\n" nil conf nil 'silent)
      (should-not (member conf (drgnx-sandbox-bwrap-argv (drgnx-sandbox-spec) '("a")))))))

(defun drgnx-sandbox-test--bwrap-or-skip ()
  "The trusted bwrap, once a probe shows it can make a user namespace here; else skip the test with the reason."
  (let ((bwrap (let ((drgnx-sandbox--programs nil)) (drgnx-sandbox-program "bwrap"))))
    (unless bwrap (ert-skip "no bwrap that only root can change"))
    (when (or (file-exists-p "/run/.containerenv") (file-exists-p "/.dockerenv")) (ert-skip "inside a container"))
    (with-temp-buffer
      (unless (eq 0 (call-process bwrap nil t nil "--unshare-all" "--unshare-user" "--disable-userns"
                                  "--ro-bind" "/" "/" "true"))
        (ert-skip (format "bwrap cannot run here: %s" (string-trim (buffer-string))))))
    bwrap))

(defmacro drgnx-sandbox-test--real (&rest body)
  "BODY with the real system reads, resolver file and bwrap (skipped where bwrap cannot run)."
  (declare (indent 0))
  `(let ((drgnx-sandbox-system-read drgnx-sandbox-test--system-read)
         (drgnx-sandbox-resolv-conf "/etc/resolv.conf")
         (drgnx-sandbox--programs nil))
     (drgnx-sandbox-test--bwrap-or-skip)
     ,@body))

(ert-deftest drgnx-sandbox/bwrap-argv-runs ()
  "The generated argv starts under the real bwrap: a shell runs in the task folder; names resolve and the resolver's
file is readable; /run/user and the runtime dir are absent; /run/drgnx is read-only, so nothing can be planted there."
  (drgnx-sandbox-test--with
    (drgnx-sandbox-test--real
      (let* ((spec (drgnx-sandbox-spec :home (cons phome home) :write (list folder) :run sid
                                       :env (drgnx-sandbox-base-env) :chdir folder))
             (script (concat "test \"$PWD\" = " (shell-quote-argument folder) " || echo NOT-IN-FOLDER\n"
                             "getent hosts localhost >/dev/null || echo NO-NAMES\n"
                             "test -r /etc/resolv.conf || echo NO-RESOLV\n"
                             "test -e /run/user && echo RUN-USER\n"
                             "test -e " (shell-quote-argument run) " && echo RUNTIME-DIR\n"
                             "ln -s / /run/drgnx/out 2>&1\n"
                             "test -L /run/drgnx/out && echo PLANTED\n"
                             "echo DONE\n"))
             (argv (drgnx-sandbox-bwrap-argv spec (list "/bin/sh" "-c" script)))
             (out nil) (exit nil))
        (with-temp-buffer
          (setq exit (apply #'call-process (car argv) nil t nil (cdr argv)) out (buffer-string)))
        (ert-info (out)
          (should (eq exit 0))
          (should (string-match-p "DONE" out))
          (should (string-match-p "Read-only file system" out))
          (dolist (bad '("NOT-IN-FOLDER" "NO-NAMES" "RUN-USER" "RUNTIME-DIR" "PLANTED"))
            (should-not (string-match-p bad out)))
          (when (file-readable-p "/etc/resolv.conf") (should-not (string-match-p "NO-RESOLV" out))))
        (should-not (file-symlink-p (concat sid "/out")))))))

(ert-deftest drgnx-sandbox/run-dir-sockets-connect ()
  "A socket the hub listens on in the session's dir answers from inside, through the read-only /run/drgnx."
  (drgnx-sandbox-test--with
    (drgnx-sandbox-test--real
      (let ((emacs (file-truename (expand-file-name invocation-name invocation-directory))))
        (unless (string-prefix-p "/usr/" emacs) (ert-skip "this Emacs is not under /usr, so not inside the sandbox"))
        (let* ((server (make-network-process :name "drgnx-sb-test" :family 'local :service (concat sid "/t.sock")
                                             :server t :filter (lambda (p _s) (process-send-string p "pong\n"))))
               (client (concat "(let ((p (make-network-process :name \"c\" :family 'local"
                               " :service \"/run/drgnx/t.sock\" :filter (lambda (_p s) (princ s) (kill-emacs 0)))))"
                               " (process-send-string p \"ping\\n\") (accept-process-output p 10) (kill-emacs 3))"))
               (argv (drgnx-sandbox-bwrap-argv (drgnx-sandbox-spec :home (cons phome home) :run sid
                                                                   :env (drgnx-sandbox-base-env))
                                               (list emacs "--batch" "-Q" "--eval" client)))
               (buf (generate-new-buffer " *drgnx-sb-client*"))
               (proc (make-process :name "drgnx-sb-client" :buffer buf :command argv :connection-type 'pipe))
               (deadline (+ (float-time) 30)))
          (unwind-protect
              (progn
                (while (and (process-live-p proc) (< (float-time) deadline)) (accept-process-output nil 0.05))
                (ert-info ((with-current-buffer buf (buffer-string)))
                  (should (eq (process-exit-status proc) 0))
                  (should (string-match-p "pong" (with-current-buffer buf (buffer-string))))))
            (delete-process server)
            (when (process-live-p proc) (delete-process proc))
            (kill-buffer buf)))))))

(ert-deftest drgnx-sandbox/wrap-on-linux-is-the-bwrap-argv ()
  (drgnx-sandbox-test--with
    (let ((spec (drgnx-sandbox-spec :backend 'bwrap :write (list folder) :chdir folder)))
      (should (equal (drgnx-sandbox-wrap spec '("agent")) (drgnx-sandbox-bwrap-argv spec '("agent")))))
    (drgnx-sandbox-test--refused (drgnx-sandbox-spec :backend 'bwrap :write (list home)))
    (should-error (drgnx-sandbox-wrap (drgnx-sandbox-spec :backend 'bwrap :write (list home)) '("a"))
                  :type 'drgnx-sandbox-refused)))

(ert-deftest drgnx-sandbox/seatbelt-wraps-with-sandbox-exec ()
  "On macOS the profile goes to `:profile-file' (0600, replacing what an earlier start left), and the command
is run by sandbox-exec with it.  A link planted there is refused; the profile file must be in a session's dir;
a refused spec writes nothing."
  (drgnx-sandbox-test--with
    (let* ((file (concat sid "/profile.sb")) (target (concat root "/target")) (seen nil)
           (spec (drgnx-sandbox-spec :backend 'seatbelt :write (list folder) :run sid :profile-file file)))
      (write-region "keep" nil target nil 'silent)
      (write-region "an earlier start's" nil file nil 'silent)
      (set-file-modes file #o644)
      (cl-letf (((symbol-function 'drgnx-sandbox-sbpl) (lambda (spec) (setq seen spec) "(version 1)\n(deny default)\n")))
        (should (equal (drgnx-sandbox-wrap spec '("agent" "--acp"))
                       (list "/usr/bin/sandbox-exec" "-f" file "agent" "--acp")))
        (should (eq seen spec))
        (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) "(version 1)\n(deny default)\n"))
        (should (equal (file-modes file) #o600))
        ;; a link planted where the profile goes: refused, the link's target untouched
        (delete-file file)
        (make-symbolic-link target file)
        (setq seen nil)
        (should-error (drgnx-sandbox-wrap spec '("agent")) :type 'drgnx-sandbox-refused)
        (should (equal (with-temp-buffer (insert-file-contents target) (buffer-string)) "keep"))
        (dolist (spec (list (drgnx-sandbox-spec :backend 'seatbelt :write (list folder))
                            (drgnx-sandbox-spec :backend 'seatbelt :profile-file (concat folder "/p.sb"))
                            (drgnx-sandbox-spec :backend 'seatbelt :write (list home) :profile-file file)))
          (should-error (drgnx-sandbox-wrap spec '("agent")) :type 'drgnx-sandbox-refused))
        (should-not seen)
        (should-not (file-exists-p (concat folder "/p.sb")))))))

;;; sandbox-test.el ends here
