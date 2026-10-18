;;; drgnx-tty-session.el --- Drive Emacs in a terminal: a private tmux server per session -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The tty test tier's driver (docs/develop/harness.md, "Terminal tier").  A session is a run
;; directory prepared by the GUI harness (`drgnx-ui-prepare-run': generated init, own server socket)
;; whose Emacs runs in a pane of its own tmux server (`tmux -L drgnx-tty-PID-N -f /dev/null', socket
;; in the run directory) instead of under mutter: `emacs -nw', or a daemon with `emacsclient -t'
;; clients.  Input goes in as raw bytes (keys and SGR mouse reports encoded here), the screen comes
;; out of `capture-pane', and the inner Emacs's state out of its socket (`drgnx-ui-call').  Everything
;; runs with a rebuilt environment: HOME and the XDG directories are in the run directory, TMUX is
;; unset, the user's tmux server and ~/.tmux.conf are never used.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'subr-x)
(require 'drgnx-ui)

(defconst drgnx-tty-session-send-method 'send-keys-hex
  "How `drgnx-tty-session-send' delivers bytes to a pane: `send-keys -H', one argument per byte.
Proved by `drgnx-tty-harness/raw-bytes-arrive-unchanged' on tmux 3.7c; `load-buffer' plus
`paste-buffer -r -d' altered escape sequences.")

(defconst drgnx-tty-session-server-options
  '(("set" "-s" "set-clipboard" "on")
    ("set" "-s" "extended-keys" "on")
    ("set" "-g" "window-size" "manual")
    ("set" "-g" "status" "off")
    ;; the application in the pane gets the mouse bytes, tmux does not act on them
    ("set" "-g" "mouse" "off")
    ;; pane commands run under sh, whatever the user's login shell is
    ("set" "-g" "default-shell" "/bin/sh"))
  "Options every session's tmux server gets before its first pane.")

(defvar drgnx-tty-session--count 0)
(defvar drgnx-tty-session--live nil "Sessions this process started and has not stopped.")

;;;; Running tmux and commands

(defun drgnx-tty-session--merge-env (env)
  "ENV (\"K=V\" strings) with one entry per variable: a later entry wins."
  (let (seen out)
    (dolist (kv (reverse env))
      (let ((k (car (split-string kv "="))))
        (unless (member k seen)
          (push k seen)
          (push kv out))))
    out))

(defun drgnx-tty-session--env (sess &optional extra)
  "The environment of SESS's programs: the GUI harness's allowlist and session variables, HOME and the XDG
directories in the run directory, TERM, a UTF-8 locale unless one is set; then EXTRA (\"K=V\")."
  (let ((run (plist-get sess :run)))
    (drgnx-tty-session--merge-env
     (drgnx-ui-session-env
      sess
      (append (list (concat "HOME=" (expand-file-name "home" run))
                    (concat "XDG_CONFIG_HOME=" (expand-file-name "xdg/config" run))
                    (concat "XDG_DATA_HOME=" (expand-file-name "xdg/data" run))
                    (concat "XDG_CACHE_HOME=" (expand-file-name "xdg/cache" run))
                    (concat "TERM=" (plist-get sess :term)))
              (unless (or (getenv "LANG") (getenv "LC_ALL")) (list "LANG=C.UTF-8"))
              extra)))))

(defun drgnx-tty-session--argv (env argv)
  "ARGV as one shell command run with exactly ENV."
  (mapconcat #'shell-quote-argument (append '("env" "-i") env argv) " "))

(defun drgnx-tty-session--tmux-argv (sess &rest args)
  "The argv running tmux ARGS on SESS's own server: `-L' its name, `-f /dev/null', SESS's environment."
  (append (list "env" "-i") (plist-get sess :tmux-env)
          (list "tmux" "-L" (plist-get sess :name) "-f" "/dev/null")
          args))

(defun drgnx-tty-session-tmux (sess &rest args)
  "Run tmux ARGS (any tmux command) on SESS's own server; return (EXIT . OUTPUT)."
  (let ((r (apply #'drgnx-ui--run-with-timeout 10 (apply #'drgnx-tty-session--tmux-argv sess args))))
    (cons (if (eq (car r) 'timeout) 124 (car r)) (cadr r))))

(defun drgnx-tty-session--tmux-ok (sess &rest args)
  "Run tmux ARGS on SESS's server; its output, or signal with tmux's message."
  (let ((r (apply #'drgnx-tty-session-tmux sess args)))
    (unless (eq (car r) 0)
      (drgnx-ui--fail "%s: tmux %s: %s" (plist-get sess :name) (string-join args " ") (string-trim (cdr r))))
    (cdr r)))

;;;; Starting and stopping

(defvar drgnx-tty-session--owner nil
  "The PID new sessions are named after (drgnx-tty-PID-N): nil for this Emacs.  Tests set it to a dead one.")

(defconst drgnx-tty-session-name-regexp "drgnx-tty-\\([0-9]+\\)-[0-9]+"
  "A session's name; the number after drgnx-tty- is the PID of the Emacs that owns it.")

(defun drgnx-tty-session--next-name (root)
  (let (name)
    (while (file-exists-p
            (expand-file-name
             (setq name (format "drgnx-tty-%d-%d" (or drgnx-tty-session--owner (emacs-pid))
                                (cl-incf drgnx-tty-session--count)))
             root)))
    name))

(defun drgnx-tty-session--owner-alive-p (pid)
  "Non-nil while PID is a running Emacs (a reused PID of another program does not count)."
  (let ((comm (alist-get 'comm (process-attributes pid))))
    (and comm (string-match-p "emacs" comm))))

(defun drgnx-tty-session--pattern (name run)
  "A `pgrep -f' pattern for the processes of session NAME: its tmux server, and anything naming RUN."
  (format "(%s/|-L %s )" (regexp-quote run) (regexp-quote name)))

(defun drgnx-tty-session--kill-pattern (pattern)
  "KILL the processes matching PATTERN (`pgrep -f'), for up to 2 s."
  (let ((deadline (+ (float-time) 2)))
    (while (and (eq 0 (car (drgnx-ui--run "pgrep" "-u" (number-to-string (user-uid)) "-f" "--" pattern)))
                (< (float-time) deadline))
      (drgnx-ui--run "pkill" "-KILL" "-u" (number-to-string (user-uid)) "-f" "--" pattern)
      (sleep-for 0.05))))

(defun drgnx-tty-session--run-of (pid)
  "The run directory process PID belongs to (its DRGNX_UI_RUN), or nil where /proc cannot tell."
  (let ((file (format "/proc/%d/environ" pid)))
    (when (file-readable-p file)
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (ignore-errors (insert-file-contents-literally file))
        (seq-some (lambda (kv) (and (string-prefix-p "DRGNX_UI_RUN=" kv) (substring kv 13)))
                  (split-string (buffer-string) "\0" t))))))

(defun drgnx-tty-session--remove-stale (name run)
  "End what session NAME (run directory RUN, or nil) left running, then remove its run and socket directories."
  (drgnx-tty-session--kill-pattern (drgnx-tty-session--pattern name (or run (concat "/" name))))
  (when (and run (equal (file-name-nondirectory (directory-file-name run)) name) (file-directory-p run))
    (let ((sock (drgnx-ui-socket-dir name (file-name-directory (directory-file-name run)))))
      (delete-directory run t)
      (when (file-directory-p sock) (delete-directory sock t))
      (ignore-errors (delete-directory (file-name-directory (directory-file-name sock)))))))

(defun drgnx-tty-session--same-pid-namespace-p (pid)
  "Non-nil when process PID is in this Emacs's PID namespace (or /proc cannot tell).  A container's tmux server
is named after the container's PIDs (1, 2, …), which mean nothing here: a sweep must not take it for the leftover
of a dead runner and kill it."
  (let ((mine (file-symlink-p "/proc/self/ns/pid"))
        (theirs (file-symlink-p (format "/proc/%d/ns/pid" pid))))
    (or (null mine) (null theirs) (equal mine theirs))))

(defun drgnx-tty-session--sweep (root)
  "Remove the sessions whose owning Emacs is dead (a runner SIGKILLed mid-test runs no exit hook): the
processes of any state root, found by name, and the run directories in ROOT."
  (let (stale)
    (dolist (line (split-string (cdr (drgnx-ui--run "pgrep" "-u" (number-to-string (user-uid)) "-af" "--"
                                                    "drgnx-tty-[0-9]+-[0-9]+")) "\n" t))
      (let ((pid (string-to-number line)))
        (when (and (drgnx-tty-session--same-pid-namespace-p pid)
                   (string-match (concat "\\(" drgnx-tty-session-name-regexp "\\)\\([/ ]\\|\\'\\)") line))
          (let ((name (match-string 1 line)))
            (unless (or (drgnx-tty-session--owner-alive-p (string-to-number (match-string 2 line)))
                        (assoc name stale))
              (push (cons name (drgnx-tty-session--run-of pid)) stale))))))
    (dolist (name (and (file-directory-p root)
                       (directory-files root nil (concat "\\`" drgnx-tty-session-name-regexp "\\'"))))
      (when (and (string-match drgnx-tty-session-name-regexp name)
                 (not (drgnx-tty-session--owner-alive-p (string-to-number (match-string 1 name))))
                 (not (cdr (assoc name stale))))
        (push (cons name (expand-file-name name root)) stale)))
    (pcase-dolist (`(,name . ,run) stale) (drgnx-tty-session--remove-stale name run))))

(defun drgnx-tty-session--start-server (sess)
  "Start SESS's tmux server in the foreground of its own session (`setsid'), bounded by `timeout': it
ends after $DRGNX_TTY_MAX_RUNTIME seconds (default 1800) even if no one stops it.  Waits for its socket."
  (let ((log (expand-file-name "tmux.log" (plist-get sess :run)))
        (deadline (+ (float-time) 10)))
    (apply #'call-process "setsid" nil (list :file log) nil "-f"
           (drgnx-tty-session--server-argv sess))
    (while (not (file-exists-p (plist-get sess :tmux)))
      (when (> (float-time) deadline)
        (drgnx-ui--fail "%s: the tmux server did not start: %s" (plist-get sess :name)
                        (if (file-exists-p log) (with-temp-buffer (insert-file-contents log) (buffer-string)) "")))
      (sleep-for 0.02))))

(defun drgnx-tty-session--server-argv (sess)
  (let ((budget (or (getenv "DRGNX_TTY_MAX_RUNTIME") "1800")))
    (append (list "env" "-i") (plist-get sess :tmux-env)
            (list "timeout" "-s" "TERM" "-k" "10" budget
                  "tmux" "-L" (plist-get sess :name) "-f" "/dev/null" "-D"))))

(defconst drgnx-tty-session-key-profiles '(vscode emacs vim) "Profiles `:keys' selects.")

(defun drgnx-tty-session--write-keys (dir profile)
  "Write DIR/keys.eld selecting key PROFILE (a symbol or string of `drgnx-tty-session-key-profiles')."
  (let ((p (if (stringp profile) (intern profile) profile)))
    (unless (memq p drgnx-tty-session-key-profiles)
      (drgnx-ui--fail "key profile %S: one of %s" profile drgnx-tty-session-key-profiles))
    (make-directory dir t)
    (drgnx-ui--write (expand-file-name "keys.eld" dir)
                     (format "%S\n" (list :layers (list (list p 'app 'editing 'window)))))))

(defun drgnx-tty-session--emacs-argv (sess daemon)
  (list (drgnx-ui-emacs-bin) "--init-directory" (expand-file-name "init" (plist-get sess :run))
        (if daemon "--fg-daemon" "-nw")))

(defconst drgnx-tty-session-nested-base
  '("set -g default-terminal \"tmux-256color\"" "set -g status off" "set -g default-shell /bin/sh")
  "The lines of a nested session's inner.conf before its own: a terminal type, no status line, sh as the shell.
Nothing else, so tmux's own defaults (set-clipboard external, extended-keys off, focus-events off) are what the
inner tmux has unless the session's lines change them.")

(defun drgnx-tty-session--inner-env (sess)
  "The environment of SESS's inner tmux: its server socket is under RUN/inner-tmux."
  (append (plist-get sess :tmux-env) (list (concat "TMUX_TMPDIR=" (expand-file-name "inner-tmux" (plist-get sess :run))))))

(defun drgnx-tty-session--nested-command (sess env lines argv)
  "The outer pane's command of a nested SESS: a second private tmux (`tmux -L inner -f RUN/inner.conf', its
socket under RUN/inner-tmux) running ARGV (Emacs) in its one window.  inner.conf is the base lines
`drgnx-tty-session-nested-base' and LINES.  The outer tmux is that tmux's terminal.  Emacs gets the inner
tmux's own TMUX and TERM, as in real use: ENV (\"K=V\" strings) is the inner tmux client's, and the inner server
starts from it."
  (let ((run (plist-get sess :run))
        (conf (expand-file-name "inner.conf" (plist-get sess :run))))
    (make-directory (expand-file-name "inner-tmux" run) t)
    (drgnx-ui--write conf (concat (string-join (append drgnx-tty-session-nested-base lines) "\n") "\n"))
    (plist-put sess :nested conf)
    (drgnx-tty-session--argv
     (append env (list (concat "TMUX_TMPDIR=" (expand-file-name "inner-tmux" run))))
     (list "tmux" "-L" "inner" "-f" conf "new-session" "-s" "inner"
           (mapconcat #'shell-quote-argument argv " ")))))

(defun drgnx-tty-session-inner-tmux (sess &rest args)
  "Run tmux ARGS on the inner server of the nested SESS; return (EXIT . OUTPUT)."
  (let ((r (apply #'drgnx-ui--run-with-timeout 10
                  (append (list "env" "-i") (drgnx-tty-session--inner-env sess) (list "tmux" "-L" "inner") args))))
    (cons (if (eq (car r) 'timeout) 124 (car r)) (cadr r))))

(defun drgnx-tty-session--client-command (sess env args)
  "A pane command: `emacsclient -t' on SESS's socket with ARGS and ENV; once it exits, its status and a shell."
  (drgnx-tty-session--argv
   env (list "sh" "-c"
             (concat (mapconcat #'shell-quote-argument
                                (append (list (drgnx-ui--emacsclient) "-a" "false" "-t" "-s" (plist-get sess :socket))
                                        args)
                                " ")
                     "; echo \"[emacsclient exited $?]\"; exec sh -i"))))

(defun drgnx-tty-session--client-frames (sess)
  (drgnx-tty-session-eval sess '(seq-count (lambda (f) (frame-parameter f 'client)) (frame-list)) 5))

(defun drgnx-tty-session--pane-alive-p (sess)
  (eq 0 (car (drgnx-tty-session-tmux sess "has-session"))))

(defun drgnx-tty-session--wait-ready (sess timeout)
  "Wait until SESS's Emacs wrote ready.json and answers on its socket; signal with the screen after TIMEOUT s."
  (let ((ready (expand-file-name "ready.json" (plist-get sess :run)))
        (deadline (+ (float-time) timeout))
        ok)
    (while (not ok)
      (when (or (> (float-time) deadline) (not (drgnx-tty-session--pane-alive-p sess)))
        (drgnx-ui--fail "%s: Emacs did not answer on its socket within %ss:\n%s"
                        (plist-get sess :name) timeout (or (ignore-errors (drgnx-tty-session-screen sess)) "")))
      (setq ok (and (file-exists-p ready) (ignore-errors (drgnx-tty-session-eval sess t 5))))
      (unless ok (sleep-for 0.1)))))

(defun drgnx-tty-session-state-root ()
  "The directory holding tty sessions' run directories: $DRGNX_UI_STATE when set, else a short private one,
tUID in `temporary-file-directory'.  A session's tmux socket is RUN/tmux-UID/NAME, NAME holding the owner's PID
\(up to 7 digits) twice; under `drgnx-ui-state-root' (a long home, or a test run's nested temp directories)
that passed the ~107 bytes a Unix socket path holds, and the Explorer's breadcrumb of the fixtures no longer fit
the screen (TTY-SOCK-1)."
  (let ((base (getenv "DRGNX_UI_STATE")))
    (if (and base (not (string-empty-p base)))
        (drgnx-ui-state-root)
      (drgnx-ui-private-tmp-dir (format "t%d" (user-uid)) "it holds the terminal sessions"))))

(cl-defun drgnx-tty-session-start (&key size config daemon term env keys options command nested)
  "Start a tty session; return its plist once the inner Emacs answers on its socket (30 s).
SIZE \"120x40\" (default) or any WxH; CONFIG \"drgnx\" (default), \"minimal\" or a directory; TERM the
pane's terminal type (default tmux-256color); ENV extra \"K=V\" strings for Emacs; KEYS a key profile
(vscode, emacs or vim) written to the session's keys.eld; OPTIONS extra tmux commands (lists of
strings, e.g. (\"set\" \"-s\" \"extended-keys\" \"off\")) after the defaults.
Not DAEMON: the pane runs `emacs -nw'.  DAEMON: window 0 runs `emacs --fg-daemon', window 1
`emacsclient -t' once the daemon answers; :target is the client's pane.  COMMAND (a shell
command, run in the run directory) replaces Emacs; start then returns once the pane exists.
NESTED (a list of tmux config lines): the pane runs a second private tmux (`tmux -L inner -f RUN/inner.conf',
its socket under RUN/inner-tmux) configured with those lines, and Emacs runs in that; keys, copies and the
screen go through the outer tmux, which is the inner one's terminal.  `drgnx-tty-session-inner-tmux' runs
commands on the inner server.  Not with DAEMON.  With COMMAND, that runs in the inner tmux instead of Emacs.
Sessions whose owning Emacs died are removed first (`drgnx-tty-session--sweep').
The plist has the `drgnx-ui' keys plus :tmux (the server's socket), :target (the pane) and :term."
  (let* ((size (or size "120x40"))
         (root (drgnx-tty-session-state-root))
         (_ (make-directory root t))
         (_ (drgnx-tty-session--sweep root))
         (name (drgnx-tty-session--next-name root))
         (sess (drgnx-ui-prepare-run name (if command "minimal" (or config "drgnx")) size root (and daemon t)))
         (run (plist-get sess :run))
         ;; The tmux socket lives beside the session's socket directory (RUNTIME/drgnx-ui/HASH/tmux-UID/NAME: short and
         ;; private), not under RUN: a state root of a test's own (DRGNX_UI_STATE) or a long home, and a 7-digit PID
         ;; twice in the name, passed the ~107 bytes a Unix socket path holds (TTY-SOCK-1).  HASH/tmux-UID stays
         ;; (empty, the server removes its socket) for the next session: removing it could race with another
         ;; session's server starting in it.
         (tmux-dir (directory-file-name (file-name-directory (directory-file-name (file-name-directory (plist-get sess :socket))))))
         (tmux (expand-file-name (format "tmux-%d/%s" (user-uid) name) tmux-dir)))
    (when (and nested daemon)
      (drgnx-ui--fail "%s: :nested runs Emacs in the inner tmux: not with :daemon" name))
    (when (> (length tmux) 100)
      (drgnx-ui--fail "%s: the tmux socket path is too long for a Unix socket: %s" name tmux))
    ;; plist-put on this (non-empty) plist changes it in place: the list of live sessions sees every key
    (plist-put sess :tmux tmux)
    (plist-put sess :term (or term "tmux-256color"))
    (plist-put sess :tmux-env (append (drgnx-tty-session--env sess) (list (concat "TMUX_TMPDIR=" tmux-dir))))
    (push sess drgnx-tty-session--live)
    (condition-case err
        (pcase-let ((`(,w ,h) (split-string size "x")))
          (dolist (d '("home" "xdg/config" "xdg/data" "xdg/cache")) (make-directory (expand-file-name d run) t))
          (when keys (drgnx-tty-session--write-keys (expand-file-name "drgnx-config" run) keys))
          (drgnx-tty-session--start-server sess)
          (let* ((env (drgnx-tty-session--env sess env))
                 (first (if nested
                            (drgnx-tty-session--nested-command
                             sess env nested (if command (list "sh" "-c" command) (drgnx-tty-session--emacs-argv sess nil)))
                          (drgnx-tty-session--argv
                           env (if command (list "sh" "-c" command) (drgnx-tty-session--emacs-argv sess daemon)))))
                 (setup (append drgnx-tty-session-server-options
                                (list (list "set" "-g" "default-terminal" (plist-get sess :term))
                                      (list "set" "-g" "default-size" size))
                                options))
                 (pane (string-trim
                        (apply #'drgnx-tty-session--tmux-ok sess
                               (append (cdr (apply #'append (mapcar (lambda (o) (cons ";" o)) setup)))
                                       (list ";" "new-session" "-d" "-s" "main" "-x" w "-y" h "-c" run
                                             "-P" "-F" "#{pane_id}" first))))))
            (plist-put sess :target pane)
            (unless command
              (drgnx-tty-session--wait-ready sess 30)
              (when daemon
                (plist-put sess :daemon-target pane)
                (plist-put sess :target (plist-get (drgnx-tty-session-client sess :env env) :target))))
            sess))
      (error (drgnx-tty-session-stop sess)
             (signal (car err) (cdr err))))))

(cl-defun drgnx-tty-session-client (sess &key env args)
  "Open another client of SESS's Emacs: a new tmux window running `emacsclient -t' with ARGS (a list of
emacsclient arguments: files, -e FORM, …) and ENV (extra \"K=V\" variables: TERM=…, say).  Returns
SESS with :target that window's pane, once the new terminal frame exists (30 s)."
  (let* ((before (drgnx-tty-session--client-frames sess))
         (pane (string-trim
                (drgnx-tty-session--tmux-ok sess "new-window" "-d" "-c" (plist-get sess :run) "-P" "-F" "#{pane_id}"
                                            (drgnx-tty-session--client-command
                                             sess (drgnx-tty-session--env sess env) args))))
         (client (append (list :target pane) sess))
         (deadline (+ (float-time) 30)))
    (while (<= (drgnx-tty-session--client-frames sess) before)
      (when (> (float-time) deadline)
        (drgnx-ui--fail "%s: emacsclient -t made no frame within 30s:\n%s"
                        (plist-get sess :name) (drgnx-tty-session-screen client)))
      (sleep-for 0.05))
    client))

(cl-defun drgnx-tty-session-pty-start (&key daemon-sess env)
  "A client of DAEMON-SESS under Emacs's own pty, not tmux: `emacsclient -t' whose terminal output is
read and dropped and whose queries nobody answers (a silent terminal).  TERM is xterm-256color unless ENV
sets it; the pty is 120x40.  Returns the process; `drgnx-tty-session-stop' deletes it."
  (unless (plist-get daemon-sess :socket) (drgnx-ui--fail "pty-start needs :daemon-sess"))
  (let* ((env (drgnx-tty-session--env daemon-sess (cons "TERM=xterm-256color" env)))
         (proc (make-process
                :name "drgnx-tty-pty" :connection-type 'pty :noquery t :filter #'ignore :sentinel #'ignore
                :command (list "sh" "-c" (concat "stty rows 40 cols 120; exec "
                                                 (drgnx-tty-session--argv
                                                  env (list (drgnx-ui--emacsclient) "-a" "false" "-t"
                                                            "-s" (plist-get daemon-sess :socket))))))))
    (plist-put daemon-sess :ptys (cons proc (plist-get daemon-sess :ptys)))
    proc))

(defun drgnx-tty-session-stop (sess)
  "Stop SESS: its Emacs asked to exit, its tmux server killed with everything in it, its pty clients
deleted; then its run and socket directories removed."
  (let ((run (plist-get sess :run))
        (socket (plist-get sess :socket)))
    (setq drgnx-tty-session--live (seq-remove (lambda (s) (equal (plist-get s :run) run)) drgnx-tty-session--live))
    (dolist (p (plist-get sess :ptys)) (ignore-errors (delete-process p)))
    (when (and socket (file-exists-p socket)) (drgnx-ui--ask-to-exit socket 3))
    (when (plist-get sess :nested) (ignore-errors (drgnx-tty-session-inner-tmux sess "kill-server")))
    (ignore-errors (drgnx-tty-session-tmux sess "kill-server"))
    (drgnx-tty-session--kill-pattern (drgnx-tty-session--pattern (plist-get sess :name) run))
    (when (file-directory-p run) (delete-directory run t))
    (let ((sock-dir (and socket (file-name-directory socket))))
      (when (and sock-dir (file-directory-p sock-dir))
        (delete-directory sock-dir t)
        (ignore-errors (delete-directory (file-name-directory (directory-file-name sock-dir))))))
    nil))

(defun drgnx-tty-session--stop-all ()
  "`kill-emacs-hook': the sessions this process did not stop (a test aborted, C-c) go with it."
  (dolist (s drgnx-tty-session--live) (ignore-errors (drgnx-tty-session-stop s))))

(add-hook 'kill-emacs-hook #'drgnx-tty-session--stop-all)

(defmacro drgnx-tty-session-with (spec &rest body)
  "Run BODY with (car SPEC) bound to a session started with START-ARGS (cdr SPEC); stop it afterwards,
also when BODY fails."
  (declare (indent 1) (debug ((symbolp &rest form) body)))
  `(let ((,(car spec) (drgnx-tty-session-start ,@(cdr spec))))
     (unwind-protect (progn ,@body)
       (drgnx-tty-session-stop ,(car spec)))))

;;;; Packages from the user's package directory (read-only)

(defun drgnx-tty-session-user-package-dirs (names &optional elpa lock)
  "The directories of packages NAMES (symbols) in ELPA (default: $DRGNX_USER_ELPA, else ~/.config/emacs/elpa),
read-only, for a test that loads a package (corfu) into the inner Emacs.  For each, the version pinned in LOCK
\(default: etc/drgnx.lock.eld) when that directory exists, else the newest.  Nil when ELPA or any package is missing.
`drgnx-tty-session-packages-hint' says how to supply them."
  (let* ((elpa (expand-file-name (or elpa (getenv "DRGNX_USER_ELPA") "~/.config/emacs/elpa")))
         (lock (or lock (expand-file-name "etc/drgnx.lock.eld" drgnx-ui-repo-dir)))
         (pins (ignore-errors
                 (with-temp-buffer (insert-file-contents lock)
                                   (plist-get (read (current-buffer)) :packages))))
         dirs)
    (when (file-directory-p elpa)
      (catch 'missing
        (dolist (name names)
          (let* ((prefix (format "%s-" name))
                 (found (seq-filter (lambda (d) (and (string-match-p "\\`[0-9][0-9.]*\\'" (substring d (length prefix)))
                                                     (file-directory-p (expand-file-name d elpa))))
                                    (directory-files elpa nil (concat "\\`" (regexp-quote prefix)))))
                 (pinned (plist-get (cdr (assq name pins)) :version))
                 (pick (or (and pinned (car (member (concat prefix pinned) found)))
                           (car (last (sort found (lambda (a b) (version< (substring a (length prefix))
                                                                          (substring b (length prefix))))))))))
            (unless pick (throw 'missing (setq dirs nil)))
            (push (expand-file-name pick elpa) dirs)))
        (nreverse dirs)))))

(defun drgnx-tty-session-packages-hint (names)
  "The message of a test skipped for want of packages NAMES."
  (format "%s not found: put the packages in a directory and set DRGNX_USER_ELPA to it (default ~/.config/emacs/elpa; bin/drgnx sync installs them under ~/.local/share/drgnx/elpa)"
          (mapconcat #'symbol-name names ", ")))

(defun drgnx-tty-session-require-packages (names)
  "`drgnx-tty-session-user-package-dirs' for NAMES, or skip the running test, printing how to supply them."
  (or (drgnx-tty-session-user-package-dirs names)
      (let ((hint (drgnx-tty-session-packages-hint names)))
        (message "SKIPPED: %s" hint)
        (ert-skip hint))))

;;;; The inner Emacs's state

(defun drgnx-tty-session-eval (sess form &optional timeout)
  "FORM's value in SESS's Emacs (through its socket, `drgnx-ui-call').  FORM is a Lisp form or its
text; an unreadable value comes back as its printed text."
  (let* ((text (if (stringp form) form (prin1-to-string form)))
         ;; `drgnx-ui-call' takes JSON back: the value travels as its printed text in a one-element array
         (reply (drgnx-ui-call sess (format "(decode-coding-string (json-serialize (vector (prin1-to-string %s)))
 'utf-8)" text)
                               timeout))
         (printed (aref reply 0)))
    (condition-case nil (car (read-from-string printed)) (invalid-read-syntax printed))))

(defun drgnx-tty-session-wait (sess form &optional timeout)
  "FORM's value once it is non-nil in SESS's Emacs (polled every 50 ms for TIMEOUT s, default 5);
else signal with the last screen."
  (let ((deadline (+ (float-time) (or timeout 5))) v)
    (while (not (setq v (drgnx-tty-session-eval sess form 5)))
      (when (> (float-time) deadline)
        (drgnx-ui--fail "%s: %S stayed nil for %ss; the screen:\n%s"
                        (plist-get sess :name) form (or timeout 5) (drgnx-tty-session-screen sess)))
      (sleep-for 0.05))
    v))

;;;; The screen

(defun drgnx-tty-session-screen (sess &optional escapes)
  "The text of SESS's pane (`capture-pane -p'; with ESCAPES, its attributes as escape sequences).  A kitty session's
is kitty's screen (`drgnx-tty-session-kitty-screen'; ESCAPES is not for it)."
  (if (plist-get sess :kitty)
      (drgnx-tty-session-kitty-screen sess)
    (string-remove-suffix "\n" (apply #'drgnx-tty-session--tmux-ok sess "capture-pane" "-p"
                                      (append (and escapes '("-e")) (list "-t" (plist-get sess :target)))))))

(defun drgnx-tty-session--find-in (screen regexp)
  "(COL . ROW), 1-based cells, of REGEXP's first match in SCREEN's lines, or nil."
  (cl-loop for line in (split-string screen "\n")
           for row from 1
           when (string-match regexp line)
           return (cons (1+ (string-width (substring line 0 (match-beginning 0)))) row)))

(defun drgnx-tty-session-find (sess regexp)
  "(COL . ROW) of REGEXP's first match on SESS's screen, or nil."
  (drgnx-tty-session--find-in (drgnx-tty-session-screen sess) regexp))

(defun drgnx-tty-session-wait-screen (sess regexp &optional timeout)
  "(COL . ROW) of REGEXP once it is on SESS's screen (TIMEOUT s, default 5); else signal with the screen."
  (let ((deadline (+ (float-time) (or timeout 5))) pos)
    (while (not (setq pos (drgnx-tty-session-find sess regexp)))
      (when (> (float-time) deadline)
        (drgnx-ui--fail "%s: %S not on screen within %ss:\n%s"
                        (plist-get sess :name) regexp (or timeout 5) (drgnx-tty-session-screen sess)))
      (sleep-for 0.05))
    pos))

(defun drgnx-tty-session-quiet (sess)
  "The screen of SESS once two captures 100 ms apart are identical (at most 10 s, else signal)."
  (let ((deadline (+ (float-time) 10)) (a (drgnx-tty-session-screen sess)) b)
    (while (progn (sleep-for 0.1)
                  (not (equal a (setq b (drgnx-tty-session-screen sess)))))
      (when (> (float-time) deadline)
        (drgnx-ui--fail "%s: the screen kept changing for 10s:\n%s" (plist-get sess :name) b))
      (setq a b))
    b))

(defun drgnx-tty-session-clipboard (sess)
  "The text of SESS's tmux paste buffer (what an OSC 52 copy put there), or nil."
  (let ((r (drgnx-tty-session-tmux sess "show-buffer")))
    (and (eq (car r) 0) (cdr r))))

(defun drgnx-tty-session-pane-flags (sess)
  "The mouse and key modes SESS's application asked of its pane: (:mouse-sgr N :mouse-any N :key-mode S)."
  (let ((out (string-trim (drgnx-tty-session--tmux-ok sess "display" "-p" "-t" (plist-get sess :target)
                                                      "#{mouse_sgr_flag}|#{mouse_any_flag}|#{pane_key_mode}"))))
    (pcase-let ((`(,sgr ,any ,mode) (split-string out "|")))
      ;; the key mode is text with spaces ("VT10x", "Ext 1", "Ext 2")
      (list :mouse-sgr (string-to-number (or sgr "")) :mouse-any (string-to-number (or any ""))
            :key-mode (or mode "")))))

(defun drgnx-tty-session-resize (sess size)
  "Resize SESS's window to SIZE (\"WxH\"); the pane's application gets SIGWINCH."
  (pcase-let ((`(,w ,h) (split-string size "x")))
    (drgnx-tty-session--tmux-ok sess "resize-window" "-t" (plist-get sess :target) "-x" w "-y" h)
    (plist-put sess :size size)))

;;;; Input: raw bytes

(defun drgnx-tty-session-send (sess bytes)
  "Deliver BYTES unchanged to SESS's pane: a unibyte string as it is, text (multibyte) as UTF-8."
  (let ((bytes (if (multibyte-string-p bytes) (encode-coding-string bytes 'utf-8-unix) bytes)))
    (when (> (length bytes) 0)
      (apply #'drgnx-tty-session--tmux-ok sess "send-keys" "-t" (plist-get sess :target) "-H"
             (mapcar (lambda (b) (format "%02x" b)) bytes)))
    nil))

(defconst drgnx-tty-session--named '((return . 13) (tab . 9) (escape . 27) (backspace . 127))
  "Function keys the encoder knows, with their code points.")

(defconst drgnx-tty-session--xterm-keys
  '((up "[" "A") (down "[" "B") (right "[" "C") (left "[" "D") (home "[" "H") (end "[" "F")
    (f1 "O" "P") (f2 "O" "Q") (f3 "O" "R") (f4 "O" "S")
    (prior "[" "5~") (next "[" "6~") (f5 "[" "15~") (f6 "[" "17~") (f7 "[" "18~") (f8 "[" "19~")
    (f9 "[" "20~") (f10 "[" "21~") (f11 "[" "23~") (f12 "[" "24~"))
  "Keys every terminal sends as xterm does: (KEY INTRODUCER FINAL).  Unmodified: ESC INTRODUCER FINAL;
modified: CSI 1;M FINAL, or CSI N;M ~ for FINAL N~ — M is 1 + shift 1, meta 2, control 4 (kkp adds super 8,
hyper 16).")

(defun drgnx-tty-session--xterm-key (spec mods caps key)
  (pcase-let ((`(,_ ,intro ,final) spec))
    (if (null mods)
        (concat "\e" intro final)
      (let ((m (1+ (drgnx-tty-session--bits
                    mods (append '((shift . 1) (meta . 2) (control . 4))
                                 (and (eq caps 'kkp) '((super . 8) (hyper . 16))))
                    key))))
        (if (string-suffix-p "~" final)
            (format "\e[%s;%d~" (substring final 0 -1) m)
          (format "\e[1;%d%s" m final))))))

(defun drgnx-tty-session--utf8 (char)
  (encode-coding-string (string char) 'utf-8))

(defun drgnx-tty-session--bits (mods table key)
  (let ((bits 0))
    (dolist (m mods bits)
      (let ((b (alist-get m table)))
        (unless b (signal 'drgnx-ui-error (list (format "%s: no encoding for the %s modifier here" key m))))
        (setq bits (logior bits b))))))

(defun drgnx-tty-session--legacy (base named mods key)
  "Bytes a terminal without key protocols sends for BASE with MODS, or signal."
  (let ((meta (memq 'meta mods)) (mods (remq 'meta mods)))
    (concat
     (if meta "\e" "")
     (cond
      ((null mods) (if named (unibyte-string base) (drgnx-tty-session--utf8 base)))
      ((and (equal mods '(shift)) (not named) (/= (upcase base) base)) (drgnx-tty-session--utf8 (upcase base)))
      ((and (equal mods '(control)) (not named) (<= ?a base ?z)) (unibyte-string (- base 96)))
      ((and (equal mods '(control)) (not named) (memq base '(?@ ?\[ ?\\ ?\] ?^ ?_ ?\s)))
       (unibyte-string (logand base 31)))
      ((and (equal mods '(control)) (not named) (eq base ??)) (unibyte-string 127))
      (t (signal 'drgnx-ui-error (list (format "%s: a legacy terminal cannot send it" key))))))))

(defconst drgnx-tty-session--us-shift
  '((?` . ?~) (?1 . ?!) (?2 . ?@) (?3 . ?#) (?4 . ?$) (?5 . ?%) (?6 . ?^) (?7 . ?&) (?8 . ?*) (?9 . ?\() (?0 . ?\))
    (?- . ?_) (?= . ?+) (?\[ . ?{) (?\] . ?}) (?\\ . ?|) (?\; . ?:) (?' . ?\") (?, . ?<) (?. . ?>) (?/ . ??))
  "What Shift makes of a key on a US layout: modifyOtherKeys reports that character.")

(defun drgnx-tty-session--encode-event (ev caps key)
  (let* ((raw (and (integerp ev) (car (rassq ev drgnx-tty-session--named))))   ; RET, TAB, ESC, DEL as chars
         ;; first: it parses a symbol's modifiers, which `event-basic-type' only reads
         (mods (if raw nil (event-modifiers ev)))
         (type (event-basic-type ev))
         (named (or (and raw ev) (and (symbolp type) (alist-get type drgnx-tty-session--named))))
         (base (or named type))
         (xterm (and (symbolp type) (assq type drgnx-tty-session--xterm-keys))))
    (unless (memq caps '(legacy mok kkp))
      (signal 'drgnx-ui-error (list (format "unknown terminal capability %S (kkp, mok or legacy)" caps))))
    (unless (or xterm (integerp base)) (signal 'drgnx-ui-error (list (format "%s: no encoding for %s" key type))))
    (pcase caps
      ((guard xterm) (drgnx-tty-session--xterm-key xterm mods caps key))
      ('legacy (drgnx-tty-session--legacy base named mods key))
      ('mok
       ;; as xterm and tmux send it: the character Shift makes on a US layout (C-S-` is 27;6;126, `~')
       (or (ignore-errors (drgnx-tty-session--legacy base named mods key))
           (format "\e[27;%d;%d~"
                   (1+ (drgnx-tty-session--bits mods '((shift . 1) (meta . 2) (control . 4)) key))
                   (if (and (memq 'shift mods) (not named))
                       (or (alist-get base drgnx-tty-session--us-shift) (upcase base))
                     base))))
      ('kkp
       (cond ((and (null mods) (eq base 27)) "\e[27u")
             ((null mods) (drgnx-tty-session--legacy base named nil key))
             ((and (equal mods '(shift)) (not named) (/= (upcase base) base))
              (drgnx-tty-session--utf8 (upcase base)))
             (t (format "\e[%d;%du" base
                        (1+ (drgnx-tty-session--bits
                             mods '((shift . 1) (meta . 2) (control . 4) (super . 8) (hyper . 16)) key)))))))))

(defun drgnx-tty-session-encode (key caps)
  "The bytes a terminal with CAPS (`kkp', `mok' or `legacy') sends for KEY (`kbd' syntax).
Signals for a key CAPS cannot send."
  (apply #'concat (mapcar (lambda (ev) (drgnx-tty-session--encode-event ev caps key)) (kbd key))))

(defun drgnx-tty-session-key (sess key &optional caps)
  "Send KEY (`kbd' syntax) to SESS as a terminal with CAPS would (default `mok')."
  (drgnx-tty-session-send sess (drgnx-tty-session-encode key (or caps 'mok))))

;;;; Input: SGR mouse reports (1-based cells)

(defun drgnx-tty-session--mouse-mods (mods)
  (drgnx-tty-session--bits mods '((shift . 4) (meta . 8) (control . 16)) "mouse"))

(cl-defun drgnx-tty-session--click-bytes (col row &key button mods double)
  (let* ((b (+ (pcase (or button 1) (1 0) (2 1) (3 2)
                      (_ (signal 'drgnx-ui-error (list (format "mouse button %s: 1, 2 or 3" button)))))
               (drgnx-tty-session--mouse-mods mods)))
         (one (format "\e[<%d;%d;%dM\e[<%d;%d;%dm" b col row b col row)))
    (if double (concat one one) one)))

(defun drgnx-tty-session--wheel-bytes (col row dir)
  (format "\e[<%d;%d;%dM" (pcase dir ('up 64) ('down 65)
                                 (_ (signal 'drgnx-ui-error (list (format "wheel direction %S: up or down" dir)))))
          col row))

(defun drgnx-tty-session--drag-bytes (from to)
  (format "\e[<0;%d;%dM\e[<32;%d;%dM\e[<0;%d;%dm" (car from) (cdr from) (car to) (cdr to) (car to) (cdr to)))

(cl-defun drgnx-tty-session-click (sess col row &key button mods double)
  "Click mouse BUTTON (1, 2 or 3; default 1) at cell COL, ROW with modifier list MODS (shift, meta,
control); DOUBLE: twice."
  (drgnx-tty-session-send sess (drgnx-tty-session--click-bytes col row :button button :mods mods :double double)))

(defun drgnx-tty-session-wheel (sess col row dir)
  "One wheel step DIR (`up' or `down') at cell COL, ROW."
  (drgnx-tty-session-send sess (drgnx-tty-session--wheel-bytes col row dir)))

(defun drgnx-tty-session-drag (sess from to)
  "Drag button 1 from cell FROM to cell TO (conses (COL . ROW))."
  (drgnx-tty-session-send sess (drgnx-tty-session--drag-bytes from to)))

;;;; kitty: the exit test's terminal

(defconst drgnx-tty-session-kitty-skip-message "kitty not installed: run bin/drgnx test --container --tty"
  "Why a kitty test skipped: kitty is installed only in the tty tier's image (test/container/Containerfile.tty).")

(defun drgnx-tty-session--kitty-bin ()
  "kitty: the one $DRGNX_TTY_KITTY names when set, else the one on PATH; nil without either."
  (let ((env (getenv "DRGNX_TTY_KITTY")))
    (if (and env (not (string-empty-p env)))
        (and (file-executable-p env) env)
      (executable-find "kitty"))))

(defun drgnx-tty-session--kitten-bin ()
  "kitten (kitty's remote control): beside kitty, else on PATH."
  (when-let* ((kitty (drgnx-tty-session--kitty-bin)))
    (let ((beside (expand-file-name "kitten" (file-name-directory kitty))))
      (if (file-executable-p beside) beside (executable-find "kitten")))))

(defun drgnx-tty-session-kitty-missing ()
  "The programs a kitty session needs that are not here: kitty, kitten, mutter, dbus-run-session, wl-paste."
  (append (unless (drgnx-tty-session--kitty-bin) '("kitty"))
          (unless (drgnx-tty-session--kitten-bin) '("kitten"))
          (seq-remove #'executable-find '("mutter" "dbus-run-session" "wl-paste"))))

(defun drgnx-tty-session-kitty-require ()
  "Skip the running test with `drgnx-tty-session-kitty-skip-message' unless a kitty session can start here."
  (when-let* ((missing (drgnx-tty-session-kitty-missing)))
    (message "SKIPPED (no %s): %s" (string-join missing ", ") drgnx-tty-session-kitty-skip-message)
    (ert-skip drgnx-tty-session-kitty-skip-message)))

(defconst drgnx-tty-session--keyboard-form
  '(progn
     (require 'dbus)
     (let* ((dest "org.gnome.Mutter.RemoteDesktop")
            (path (dbus-call-method :session dest "/org/gnome/Mutter/RemoteDesktop" dest "CreateSession"))
            (iface (concat dest ".Session")))
       (dbus-call-method :session dest path iface "Start")
       ;; the virtual keyboard comes with the first key: Shift (keysym 0xffe1) down and up, before any window
       (dbus-call-method :session dest path iface "NotifyKeyboardKeysym" :uint32 #xffe1 t)
       (dbus-call-method :session dest path iface "NotifyKeyboardKeysym" :uint32 #xffe1 nil)
       (write-region path nil (car command-line-args-left) nil 'silent)
       ;; mutter ends the remote-desktop session, and its keyboard, when this client leaves the bus
       (while t (sleep-for 60))))
  "Run by a batch Emacs on the session's bus: give headless mutter a keyboard.  Without one its seat has none,
so no window ever has the keyboard focus: kitty cannot own the clipboard (an OSC 52 copy goes nowhere) and
wl-paste cannot read it (\"This seat has no keyboard\").  The argument after the form is the file it writes once
the keyboard is there.")

(defun drgnx-tty-session--detach (sess log argv)
  "Start ARGV (with SESS's kitty environment) in its own session, bounded by $DRGNX_TTY_MAX_RUNTIME (default
1800 s) as the tmux servers are; its output to RUN/LOG."
  (apply #'call-process "setsid" nil (list :file (expand-file-name log (plist-get sess :run))) nil "-f"
         (append (list "timeout" "-s" "TERM" "-k" "10" (or (getenv "DRGNX_TTY_MAX_RUNTIME") "1800")
                       "env" "-i")
                 (plist-get sess :kitty-env) argv)))

(defun drgnx-tty-session--log (sess log)
  (let ((file (expand-file-name log (plist-get sess :run))))
    (if (file-exists-p file) (with-temp-buffer (insert-file-contents file) (buffer-string)) "")))

(defun drgnx-tty-session--kitty-wait (sess what pred log)
  "Wait up to 30 s for PRED (a function of no arguments); else signal that WHAT did not happen, with RUN/LOG."
  (let ((deadline (+ (float-time) 30)))
    (while (not (funcall pred))
      (when (> (float-time) deadline)
        (drgnx-ui--fail "%s: %s within 30s:\n%s" (plist-get sess :name) what (drgnx-tty-session--log sess log)))
      (sleep-for 0.1))))

(cl-defun drgnx-tty-session-kitty-start (&key size env)
  "Start a kitty session: a drgnx daemon under headless mutter (`drgnx-ui-start', with ENV, extra \"K=V\"
strings, in its environment) and kitty on that display running `emacsclient -t' on the daemon's socket.  SIZE
\"120x40\" (default) is kitty's window in cells.  Returns the session plist (the `drgnx-ui' keys, :kitty its
remote-control socket, :kitty-env the environment of kitty, kitten and wl-paste) once the terminal frame exists.
kitty runs as `kitty --config NONE -o allow_remote_control=socket-only -o enable_audio_bell=no --listen-on
unix:RUN/kitty.sock -o initial_window_width=Wc -o initial_window_height=Hc -e emacsclient -t -s SOCKET', with
WAYLAND_DISPLAY the session's name, TERM=xterm-kitty, HOME and the XDG directories in the run directory and the
session's own bus: never the user's display or bus.  Before it, a batch Emacs gives mutter a keyboard
\(`drgnx-tty-session--keyboard-form').  `drgnx-tty-session-kitty-stop' ends it all."
  (let* ((gui (let ((drgnx-ui-session-extra-env env)) (drgnx-ui-start "drgnx" "1920x1200" 60 t)))
         (sess (append (list :kitty (expand-file-name "kitty.sock" (plist-get gui :run)) :term "xterm-kitty") gui)))
    (condition-case err
        (pcase-let* ((`(,w ,h) (split-string (or size "120x40") "x"))
                     (run (plist-get sess :run))
                     ;; the daemon's own (dbus-run-session's), not the emacsclient that asks
                     (bus (drgnx-tty-session-eval sess '(getenv-internal "DBUS_SESSION_BUS_ADDRESS" initial-environment)))
                     (ready (expand-file-name "keyboard" run)))
          (when (> (length (plist-get sess :kitty)) 100)
            (drgnx-ui--fail "%s: kitty's socket path is too long for a Unix socket: %s"
                            (plist-get sess :name) (plist-get sess :kitty)))
          (unless (stringp bus) (drgnx-ui--fail "%s: the session's Emacs has no session bus" (plist-get sess :name)))
          (dolist (d '("home" "xdg/config" "xdg/data" "xdg/cache")) (make-directory (expand-file-name d run) t))
          (plist-put sess :kitty-env (drgnx-tty-session--env
                                      sess (list (concat "WAYLAND_DISPLAY=" (plist-get sess :name))
                                                 (concat "DBUS_SESSION_BUS_ADDRESS=" bus))))
          (drgnx-tty-session--detach sess "keyboard.log"
                                     (list (drgnx-ui-emacs-bin) "--batch" "-Q" "--eval"
                                           (prin1-to-string drgnx-tty-session--keyboard-form) ready))
          (drgnx-tty-session--kitty-wait sess "mutter got no keyboard" (lambda () (file-exists-p ready)) "keyboard.log")
          (drgnx-tty-session--detach
           sess "kitty.log"
           (list (drgnx-tty-session--kitty-bin) "--config" "NONE" "-o" "allow_remote_control=socket-only"
                 "-o" "enable_audio_bell=no" "--listen-on" (concat "unix:" (plist-get sess :kitty))
                 "-o" (concat "initial_window_width=" w "c") "-o" (concat "initial_window_height=" h "c")
                 "-e" (drgnx-ui--emacsclient) "-t" "-s" (plist-get sess :socket)))
          (drgnx-tty-session--kitty-wait sess "kitty made no terminal frame"
                                         (lambda () (and (file-exists-p (plist-get sess :kitty))
                                                         (> (drgnx-tty-session--client-frames sess) 0)))
                                         "kitty.log")
          sess)
      (error (drgnx-tty-session-kitty-stop sess)
             (signal (car err) (cdr err))))))

(defun drgnx-tty-session-kitty-stop (sess)
  "Stop kitty session SESS: kitty and the keyboard's Emacs (their command lines name the run directory's
kitty.sock and keyboard), then the daemon and its compositor (`drgnx-ui-stop')."
  (drgnx-tty-session--kill-pattern (format "%s/(kitty\\.sock|keyboard)( |$)" (regexp-quote (plist-get sess :run))))
  (drgnx-ui-stop (plist-get sess :name)))

(defun drgnx-tty-session--kitten (sess &rest args)
  "Run `kitten @ --to unix:RUN/kitty.sock ARGS' for kitty session SESS; its output, or signal with kitten's."
  (let ((r (apply #'drgnx-ui--run-with-timeout 10
                  (append (list "env" "-i") (plist-get sess :kitty-env)
                          (list (drgnx-tty-session--kitten-bin) "@" "--to" (concat "unix:" (plist-get sess :kitty)))
                          args))))
    (unless (eq (car r) 0)
      (drgnx-ui--fail "%s: kitten @ %s: %s" (plist-get sess :name) (string-join args " ") (string-trim (cadr r))))
    (cadr r)))

(defun drgnx-tty-session-kitty-key (sess key)
  "Press KEY in kitty session SESS through kitty's own key encoder (`kitten @ send-key'): KEY in kitty's syntax,
such as \"ctrl+shift+p\", \"shift+right\" or \"f6\"; one key, pressed and released."
  (drgnx-tty-session--kitten sess "send-key" key)
  nil)

(defun drgnx-tty-session--kitty-escape (text)
  "TEXT as `send-text' reads it (Python escapes): printable ASCII as it is, everything else \\xHH or \\uHHHH."
  (mapconcat (lambda (c)
               (cond ((and (<= 32 c 126) (/= c ?\\)) (string c))
                     ((< c 256) (format "\\x%02x" c))
                     ((< c #x10000) (format "\\u%04x" c))
                     (t (format "\\U%08x" c))))
             text ""))

(defun drgnx-tty-session-kitty-text (sess text)
  "Send TEXT to the program in kitty session SESS as it is (`kitten @ send-text', no bracketed paste): raw
bytes such as an SGR mouse report (`drgnx-tty-session--click-bytes')."
  (drgnx-tty-session--kitten sess "send-text" "--bracketed-paste=disable"(drgnx-tty-session--kitty-escape text))
  nil)

(defun drgnx-tty-session-kitty-screen (sess)
  "The text of kitty session SESS's screen (`kitten @ get-text --extent screen')."
  (string-remove-suffix "\n" (drgnx-tty-session--kitten sess "get-text" "--extent" "screen")))

(defun drgnx-tty-session-kitty-clipboard (sess)
  "The text on the clipboard of kitty session SESS's display (`wl-paste -n'), or nil when it holds none."
  (let ((r (apply #'drgnx-ui--run-with-timeout 5
                  (append (list "env" "-i") (plist-get sess :kitty-env) (list "wl-paste" "-n")))))
    (and (eq (car r) 0) (cadr r))))

(provide 'drgnx-tty-session)
;;; drgnx-tty-session.el ends here
