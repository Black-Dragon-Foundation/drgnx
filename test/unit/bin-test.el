;;; bin-test.el --- batch tests: bin/drgnx runs every subcommand in one Emacs -*- lexical-binding: t -*-
;; Fake Emacs scripts record their argv; bin/drgnx runs in a temp HOME and config dir, never the user's.
(require 'ert)
(require 'seq)

(defconst drgnx-bin-test--root
  (expand-file-name "../../" (file-name-directory (or load-file-name buffer-file-name))))

(defun drgnx-bin-test--fake (file log)
  "Make FILE an executable that appends its argv to LOG and exits 0; return FILE."
  (write-region (format "#!/bin/sh\necho \"$0 $*\" >> '%s'\n" log) nil file)
  (set-file-modes file #o755)
  file)

(defun drgnx-bin-test--slurp (file)
  (if (file-exists-p file)
      (with-temp-buffer (insert-file-contents file) (buffer-string))
    ""))

(defvar drgnx-bin-test--cwd nil "The directory bin/drgnx runs in (nil: the temp dir).")

(defun drgnx-bin-test--call (bin env &rest args)
  "Run BIN (a bin/drgnx) with ENV (\"K=V\" strings) and ARGS in `drgnx-bin-test--cwd'; return (EXIT . OUTPUT),
stderr included.  DRGNX_EMACS is unset unless ENV sets it; HOME is the caller's temp directory in ENV."
  (let ((process-environment (append env (list "DRGNX_EMACS") process-environment))
        (default-directory (file-name-as-directory (or drgnx-bin-test--cwd temporary-file-directory))))
    (with-temp-buffer
      (cons (apply #'call-process bin nil t nil args) (buffer-string)))))

(defmacro drgnx-bin-test--with-setup (vars &rest body)
  "Bind VARS: DIR (temp directory, deleted afterwards), PATHDIR (first on PATH, holds a fake `emacs'
logging to PATHLOG), CONFIG (a DRGNX_CONFIG_DIR) and ENV (the environment lists that isolate the run)."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "drgnx-bin-test" t))
          (pathdir (expand-file-name "path" dir))
          (pathlog (expand-file-name "path.log" dir))
          (config (expand-file-name "config" dir))
          (env (list (concat "HOME=" dir) (concat "DRGNX_CONFIG_DIR=" config)
                     (concat "PATH=" pathdir ":/usr/bin:/bin"))))
     (ignore pathlog config env)
     (make-directory pathdir)
     (make-directory config)
     (drgnx-bin-test--fake (expand-file-name "emacs" pathdir) pathlog)
     (unwind-protect (let ,vars ,@body)
       (delete-directory dir t))))

(defconst drgnx-bin-test--bin (expand-file-name "bin/drgnx" drgnx-bin-test--root))

(ert-deftest drgnx-bin/the-recorded-emacs-is-used ()
  (drgnx-bin-test--with-setup ()
    (let ((log (expand-file-name "recorded.log" dir))
          (fake (expand-file-name "recorded-emacs" dir)))
      (drgnx-bin-test--fake fake log)
      (write-region (concat fake "\n") nil (expand-file-name "emacs" config))
      (dolist (args '(("build") ("keys" "diff" "--help") ("ui" "--help") ("search" "index" "--help") ("macos-app")))
        (delete-file log)
        (apply #'drgnx-bin-test--call drgnx-bin-test--bin env args)
        (should (string-search fake (drgnx-bin-test--slurp log))))
      (should (string-empty-p (drgnx-bin-test--slurp pathlog))))))

(ert-deftest drgnx-bin/drgnx-emacs-wins-over-the-recorded-one ()
  (drgnx-bin-test--with-setup ()
    (let ((rec-log (expand-file-name "recorded.log" dir))
          (env-log (expand-file-name "env.log" dir)))
      (write-region (concat (drgnx-bin-test--fake (expand-file-name "recorded-emacs" dir) rec-log) "\n")
                    nil (expand-file-name "emacs" config))
      (let ((chosen (drgnx-bin-test--fake (expand-file-name "env-emacs" dir) env-log)))
        (drgnx-bin-test--call drgnx-bin-test--bin (append env (list (concat "DRGNX_EMACS=" chosen))) "build")
        (should (string-search chosen (drgnx-bin-test--slurp env-log)))
        (should (string-empty-p (drgnx-bin-test--slurp rec-log)))))))

(ert-deftest drgnx-bin/a-recorded-emacs-that-is-gone-falls-back-to-path ()
  (drgnx-bin-test--with-setup ()
    (write-region (concat (expand-file-name "no-such-emacs" dir) "\n") nil (expand-file-name "emacs" config))
    (drgnx-bin-test--call drgnx-bin-test--bin env "build")
    (should (string-search "emacs" (drgnx-bin-test--slurp pathlog)))
    (should (string-search "--batch" (drgnx-bin-test--slurp pathlog)))))

(ert-deftest drgnx-bin/only-the-first-line-of-the-record-counts-and-is-never-run-as-shell ()
  (drgnx-bin-test--with-setup ()
    (let ((marker (expand-file-name "ran-as-shell" dir))
          (log (expand-file-name "recorded.log" dir))
          (fake (expand-file-name "recorded-emacs" dir)))
      (drgnx-bin-test--fake fake log)
      (write-region (format "  %s  \ntouch %s\n" fake marker) nil (expand-file-name "emacs" config))
      (drgnx-bin-test--call drgnx-bin-test--bin env "build")
      (should (string-search fake (drgnx-bin-test--slurp log)))
      (should-not (file-exists-p marker)))))

(ert-deftest drgnx-bin/a-recorded-emacs-path-with-spaces-is-used ()
  (drgnx-bin-test--with-setup ()
    (let* ((sub (expand-file-name "Emacs App/Contents MacOS" dir))
           (log (expand-file-name "recorded.log" dir))
           (fake (progn (make-directory sub t) (drgnx-bin-test--fake (expand-file-name "Emacs" sub) log))))
      (write-region (concat fake "\n") nil (expand-file-name "emacs" config))
      (dolist (args '(("build") ("ui" "--help") ("macos-app")))
        (delete-file log)
        (apply #'drgnx-bin-test--call drgnx-bin-test--bin env args)
        (should (string-search fake (drgnx-bin-test--slurp log))))
      (should (string-empty-p (drgnx-bin-test--slurp pathlog))))))

(ert-deftest drgnx-bin/a-relative-recorded-emacs-is-ignored ()
  ;; The record is an absolute path (install.sh writes one); a relative line would mean whatever directory
  ;; the command happens to run in.
  (drgnx-bin-test--with-setup ()
    (let ((log (expand-file-name "recorded.log" dir))
          (drgnx-bin-test--cwd dir))
      (drgnx-bin-test--fake (expand-file-name "local-emacs" dir) log)
      (dolist (line '("local-emacs" "./local-emacs"))
        (write-region (concat line "\n") nil (expand-file-name "emacs" config))
        (delete-file log)
        (drgnx-bin-test--call drgnx-bin-test--bin env "build")
        (should (string-empty-p (drgnx-bin-test--slurp log)))
        (should (string-search "--batch" (drgnx-bin-test--slurp pathlog)))))))

(ert-deftest drgnx-bin/the-launcher-probe-prefers-newer-sources ()
  ;; `doctor --dev' loads harness/drgnx-ui.el in a batch Emacs: with a stale .elc beside it Emacs would
  ;; print "Source file … newer than byte-compiled" into the probe's answer.
  (drgnx-bin-test--with-setup ()
    (drgnx-bin-test--call drgnx-bin-test--bin (append env (list "DRGNX_CONTAINER=none")) "doctor" "--dev")
    (let ((probe (seq-find (lambda (l) (string-search "-l drgnx-ui" l))
                           (split-string (drgnx-bin-test--slurp pathlog) "\n" t))))
      (should probe)
      (should (string-search "load-prefer-newer" probe)))))

(ert-deftest drgnx-bin/doctor-json-starts-with-the-json-when-an-elc-is-stale ()
  ;; A pull leaves an .elc older than its .el; without load-prefer-newer Emacs prints "Source file … newer
  ;; than byte-compiled" before the JSON.  A temp copy of bin/ and core/, so the real files stay untouched.
  (let* ((dir (make-temp-file "drgnx-bin-test" t))
         (emacs (expand-file-name invocation-name invocation-directory))
         (core (expand-file-name "core" dir)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "bin" dir))
          (copy-file drgnx-bin-test--bin (expand-file-name "bin/drgnx" dir))
          (set-file-modes (expand-file-name "bin/drgnx" dir) #o755)
          (make-directory core)
          (dolist (f (directory-files (expand-file-name "core" drgnx-bin-test--root) t "\\.el\\'"))
            (copy-file f (expand-file-name (file-name-nondirectory f) core)))
          (should (= 0 (call-process emacs nil nil nil "--batch" "-Q" "-L" core
                                     "-f" "batch-byte-compile" (expand-file-name "drgnx-doctor.el" core))))
          (set-file-times (expand-file-name "drgnx-doctor.elc" core) '(1000 0))   ; older than the .el
          (let ((r (drgnx-bin-test--call (expand-file-name "bin/drgnx" dir)
                                         (list (concat "HOME=" dir) (concat "DRGNX_EMACS=" emacs)
                                               (concat "DRGNX_CONFIG_DIR=" dir "/config"))
                                         "doctor" "--json")))
            (should (string-prefix-p "[" (cdr r)))))
      (delete-directory dir t))))

;;;; drgnx PATH / drgnx open — fake emacs, emacsclient and systemctl; never a real server

(defconst drgnx-bin-test--server "drgnx-bin-test"
  "The server name the open tests use: never `drgnx' (the user's may be running), except where faked.")

(defun drgnx-bin-test--open-fakes (dir pathdir)
  "Fake `emacs', `emacsclient' and `systemctl' in PATHDIR.  State files in DIR: running (the server
answers), gui (a window is open), enabled (the systemd unit is), slow-probe (each `-e t' takes 0.3 s), delay (seconds the daemon takes to answer
once started, or `never'; absent: at once).  emacsclient logs each call to
client.log, one line per call, every argument followed by \\037; emacs and systemctl log theirs."
  (let ((f (lambda (name) (shell-quote-argument (expand-file-name name dir)))))
    (dolist (spec `(("emacsclient"
                     ,(format "printf '%%s\\037' \"$@\" >> %s; echo >> %s
for a in \"$@\"; do last=\"$a\"; [ \"$a\" = -c ] && c=1; done
[ \"$last\" = t ] && [ -f \"${0%%/*}/../slow-probe\" ] && sleep 0.3
if [ -n \"$c\" ]; then
  if [ -f %s ]; then (sleep 0.5; touch %s) >/dev/null 2>&1 & else touch %s; fi
fi
case \"$last\" in
  t) [ -f %s ] || exit 1 ;;
  '(drgnx-session-gui-frame-p)') if [ -f %s ]; then echo t; else echo nil; fi ;;
  '(emacs-version)') echo '\"GNU Emacs 99.1 (fake)\"' ;;
  '(kill-emacs)') rm -f %s ;;
esac"
                              (funcall f "client.log") (funcall f "client.log")
                              (funcall f "slow-c") (funcall f "gui") (funcall f "gui")
                              (funcall f "running") (funcall f "gui") (funcall f "running")))
                    ("emacs" ,(format "echo \"$*\" >> %s
case \"$*\" in *--bg-daemon=*)
  echo \"fake daemon started\"
  d=0; [ -f %s ] && d=$(cat %s)
  if [ \"$d\" = 0 ]; then touch %s
  elif [ \"$d\" != never ]; then (sleep \"$d\"; touch %s) >/dev/null 2>&1 & fi ;;
esac"
                                      (funcall f "emacs.log") (funcall f "delay") (funcall f "delay")
                                      (funcall f "running") (funcall f "running")))
                    ("systemctl" ,(format "echo \"$*\" >> %s
case \"$*\" in *is-enabled*) [ -f %s ] ;; *start*) touch %s ;; esac"
                                          (funcall f "systemctl.log") (funcall f "enabled") (funcall f "running")))))
      (let ((file (expand-file-name (car spec) pathdir)))
        (write-region (concat "#!/bin/sh\n" (cadr spec) "\n") nil file)
        (set-file-modes file #o755)))))

(defun drgnx-bin-test--client-calls (dir)
  "The fake emacsclient's calls so far, each a list of its arguments."
  (mapcar (lambda (line) (split-string line "\037" t))
          (split-string (drgnx-bin-test--slurp (expand-file-name "client.log" dir)) "\n" t)))

(defun drgnx-bin-test--touch (dir &rest names)
  (dolist (n names) (write-region "" nil (expand-file-name n dir))))

(defmacro drgnx-bin-test--with-open (&rest body)
  "BODY in `drgnx-bin-test--with-setup' with the open fakes; ENV names the test's server."
  (declare (indent 0))
  `(drgnx-bin-test--with-setup ()
     (drgnx-bin-test--open-fakes dir pathdir)
     (let ((env (append (list (concat "DRGNX_SERVER_NAME=" drgnx-bin-test--server)
                              (concat "XDG_STATE_HOME=" dir "/state"))
                        env)))
       ,@body)))

(defun drgnx-bin-test--c (&rest args)
  "An emacsclient call to the test's server with ARGS, as the fake logs it."
  (append (list "-a" "false" "-s" drgnx-bin-test--server) args))

(defun drgnx-bin-test--p (&rest args)
  "A question to the test's server with ARGS: an emacsclient call that gives up after 5 s."
  (apply #'drgnx-bin-test--c "--timeout=5" args))

(defconst drgnx-bin-test--load-keys "(progn (require 'drgnx-ai) (drgnx-ai-load-keys-soon))"
  "What `drgnx open' asks the daemon after raising its window: the AI keys, once per daemon (from a timer).")

(defun drgnx-bin-test--folder (dir)
  (format "(drgnx-session-open-folder %S)" (directory-file-name (expand-file-name dir))))

(ert-deftest drgnx-session/open-argv-when-running ()
  (drgnx-bin-test--with-open
    (drgnx-bin-test--touch dir "running" "gui")
    (let ((file (expand-file-name "My Project/café.py" dir)) (sub (expand-file-name "sub" dir)))
      (make-directory (file-name-directory file)) (make-directory sub) (write-region "" nil file)
      (let ((drgnx-bin-test--cwd dir))
        (should (equal (drgnx-bin-test--call drgnx-bin-test--bin env "open" "My Project/café.py" "sub") '(0 . ""))))
      (should (equal (drgnx-bin-test--client-calls dir)
                     (list (drgnx-bin-test--p "-e" "t")
                           (drgnx-bin-test--p "-e" "(drgnx-session-gui-frame-p)")
                           (drgnx-bin-test--c "-n" "-e" "(drgnx-session-raise)")
                           (drgnx-bin-test--c "-n" "-e" drgnx-bin-test--load-keys)
                           (drgnx-bin-test--c "-n" "--" file)
                           (drgnx-bin-test--c "-n" "-e" (drgnx-bin-test--folder sub)))))
      (should (string-empty-p (drgnx-bin-test--slurp (expand-file-name "emacs.log" dir))))
      ;; No window open: one is made first (-c), then the same.
      (delete-file (expand-file-name "gui" dir))
      (delete-file (expand-file-name "client.log" dir))
      (let ((drgnx-bin-test--cwd dir))
        (drgnx-bin-test--call drgnx-bin-test--bin env "open" "My Project/café.py"))
      (should (equal (drgnx-bin-test--client-calls dir)
                     (list (drgnx-bin-test--p "-e" "t")
                           (drgnx-bin-test--p "-e" "(drgnx-session-gui-frame-p)")
                           (drgnx-bin-test--c "-n" "-c")
                           (drgnx-bin-test--p "-e" "(drgnx-session-gui-frame-p)")   ; it waits for the window
                           (drgnx-bin-test--c "-n" "-e" "(drgnx-session-raise)")
                           (drgnx-bin-test--c "-n" "-e" drgnx-bin-test--load-keys)
                           (drgnx-bin-test--c "-n" "--" file)))))))

(ert-deftest drgnx-session/open-argv-when-not-running ()
  (drgnx-bin-test--with-open
    (drgnx-bin-test--touch dir "enabled")          ; an enabled unit serves `drgnx', not this test's name
    (should (equal (drgnx-bin-test--call drgnx-bin-test--bin env "open") '(0 . "")))
    (should (equal (drgnx-bin-test--slurp (expand-file-name "emacs.log" dir))
                   (format "--bg-daemon=%s --init-directory=%s\n" drgnx-bin-test--server
                           (expand-file-name "init" drgnx-bin-test--root))))
    (should (string-empty-p (drgnx-bin-test--slurp (expand-file-name "systemctl.log" dir))))
    (let ((calls (drgnx-bin-test--client-calls dir)))
      (should (equal (car calls) (drgnx-bin-test--p "-e" "t")))
      ;; polled until the server answers, then: no window yet, so one is made — restore only (no path)
      (should (equal (seq-remove (lambda (c) (equal c (drgnx-bin-test--p "-e" "t"))) calls)
                     (list (drgnx-bin-test--p "-e" "(drgnx-session-gui-frame-p)")
                           (drgnx-bin-test--c "-n" "-c")
                           (drgnx-bin-test--p "-e" "(drgnx-session-gui-frame-p)")   ; it waits for the window
                           (drgnx-bin-test--c "-n" "-e" "(drgnx-session-raise)")
                           (drgnx-bin-test--c "-n" "-e" drgnx-bin-test--load-keys)))))))

(ert-deftest drgnx-bin/open-waits-for-a-slow-daemon ()
  ;; DRGNX_OPEN_WAIT seconds (30 by default) for the daemon; it says so a third of the way in (10 s of 30).
  (drgnx-bin-test--with-open
    (write-region "2" nil (expand-file-name "delay" dir))
    (let ((r (drgnx-bin-test--call drgnx-bin-test--bin (cons "DRGNX_OPEN_WAIT=3" env) "open")))
      (should (eql 0 (car r)))
      (should (string-search "still starting" (cdr r)))
      (should (file-exists-p (expand-file-name "running" dir))))
    ;; a daemon that never answers: the wait is DRGNX_OPEN_WAIT, and the message names it
    (delete-file (expand-file-name "running" dir))
    (write-region "never" nil (expand-file-name "delay" dir))
    (let ((r (drgnx-bin-test--call drgnx-bin-test--bin (cons "DRGNX_OPEN_WAIT=1" env) "open")))
      (should (eql 1 (car r)))
      (should (string-search "did not start within 1 s" (cdr r))))))

(defun drgnx-bin-test--open-twice (dir env)
  "Run two `drgnx open' at once (one shell, `&' and `wait'); return the elapsed seconds."
  (let ((start (float-time)))
    (drgnx-bin-test--call "sh" (cons (concat "DRGNX_BIN=" drgnx-bin-test--bin) env)
                          "-c" "\"$DRGNX_BIN\" open & \"$DRGNX_BIN\" open & wait")
    (ignore dir)
    (- (float-time) start)))

(ert-deftest drgnx-bin/two-opens-at-once-make-one-window ()
  ;; The daemon takes 1 s to answer and a window 0.5 s to appear: without the lock both opens start a
  ;; daemon and both make a window.
  (drgnx-bin-test--with-open
    (write-region "1" nil (expand-file-name "delay" dir))
    (drgnx-bin-test--touch dir "slow-c")
    (drgnx-bin-test--open-twice dir env)
    (should (= 1 (length (split-string (drgnx-bin-test--slurp (expand-file-name "emacs.log" dir)) "\n" t))))
    (should (= 1 (seq-count (lambda (c) (member "-c" c)) (drgnx-bin-test--client-calls dir))))
    ;; both asked for the window to come to the front
    (should (= 2 (seq-count (lambda (c) (member "(drgnx-session-raise)" c)) (drgnx-bin-test--client-calls dir))))
    ;; and the lock is gone
    (should-not (file-exists-p (expand-file-name (format "state/drgnx/open-%s.lock" drgnx-bin-test--server) dir)))))

(ert-deftest drgnx-bin/an-open-lock-is-waited-for-and-a-stale-one-taken-over ()
  (drgnx-bin-test--with-open
    (let ((lock (expand-file-name (format "state/drgnx/open-%s.lock" drgnx-bin-test--server) dir)))
      (make-directory lock t)
      ;; a lock from long ago (its owner was killed): taken over at once
      (write-region "1\n" nil (expand-file-name "since" lock))
      (let ((start (float-time)))
        (should (eql 0 (car (drgnx-bin-test--call drgnx-bin-test--bin env "open"))))
        (should (< (- (float-time) start) 5)))
      (should (string-search "--bg-daemon=" (drgnx-bin-test--slurp (expand-file-name "emacs.log" dir))))
      (should-not (file-exists-p lock))
      ;; a lock another open holds right now: waited for, until it is released
      (delete-file (expand-file-name "emacs.log" dir))
      (delete-file (expand-file-name "running" dir))
      (delete-file (expand-file-name "gui" dir))
      (make-directory lock t)
      (write-region (format "%d\n" (truncate (float-time))) nil (expand-file-name "since" lock))
      (let ((start (float-time)))
        (should (eql 0 (car (drgnx-bin-test--call
                             "sh" (cons (concat "DRGNX_BIN=" drgnx-bin-test--bin)
                                        (cons (concat "LOCK=" lock) env))
                             "-c" "(sleep 1; rm -rf \"$LOCK\") & \"$DRGNX_BIN\" open; wait"))))
        (should (>= (- (float-time) start) 0.9)))
      (should (string-search "--bg-daemon=" (drgnx-bin-test--slurp (expand-file-name "emacs.log" dir)))))))

(ert-deftest drgnx-bin/the-daemon-log-is-appended-to ()
  ;; A second start (or the losing one of two) must not wipe what the first one said.
  (drgnx-bin-test--with-open
    (let ((log (expand-file-name "state/drgnx/daemon.log" dir)))
      (make-directory (file-name-directory log) t)
      (write-region "earlier start\n" nil log)
      (should (eql 0 (car (drgnx-bin-test--call drgnx-bin-test--bin env "open"))))
      (should (equal (drgnx-bin-test--slurp log) "earlier start\nfake daemon started\n")))))

(defun drgnx-bin-test--lock (dir)
  (expand-file-name (format "state/drgnx/open-%s.lock" drgnx-bin-test--server) dir))

(ert-deftest drgnx-bin/open-waits-count-seconds-not-polls ()
  ;; Each poll costs its sleep and a client call (0.3 s here): 20 polls would be 8 s, not the 2 s asked for.
  (drgnx-bin-test--with-open
    (write-region "never" nil (expand-file-name "delay" dir))
    (drgnx-bin-test--touch dir "slow-probe")
    (let* ((start (float-time))
           (r (drgnx-bin-test--call drgnx-bin-test--bin (cons "DRGNX_OPEN_WAIT=2" env) "open")))
      (should (eql 1 (car r)))
      (should (string-search "did not start within 2 s" (cdr r)))
      (should (< (- (float-time) start) 4.5)))))

(ert-deftest drgnx-bin/open-wait-is-decimal-and-a-bad-value-is-refused ()
  (drgnx-bin-test--with-open
    (dolist (v '("08" "09"))                      ; octal in bash arithmetic
      (let ((r (drgnx-bin-test--call drgnx-bin-test--bin (cons (concat "DRGNX_OPEN_WAIT=" v) env) "open")))
        (should (eql 0 (car r)))
        (should (string-empty-p (cdr r)))
        (delete-file (expand-file-name "running" dir))))
    (dolist (v '("abc" "0" "-3" "2.5"))
      (let ((r (drgnx-bin-test--call drgnx-bin-test--bin (cons (concat "DRGNX_OPEN_WAIT=" v) env) "open")))
        (should (eql 0 (car r)))                 ; the default (30 s) is used
        (should (string-search "DRGNX_OPEN_WAIT must be a whole number of seconds above 0" (cdr r)))
        (delete-file (expand-file-name "running" dir))))))

(ert-deftest drgnx-bin/the-still-starting-notice-comes-while-waiting ()
  (drgnx-bin-test--with-open
    (write-region "3" nil (expand-file-name "delay" dir))
    (let* ((out "") (done nil)
           (process-environment (append (cons "DRGNX_OPEN_WAIT=6" env) process-environment))
           (proc (make-process :name "drgnx-open" :command (list drgnx-bin-test--bin "open") :connection-type 'pipe
                               :noquery t :filter (lambda (_p s) (setq out (concat out s)))
                               :sentinel (lambda (_p _e) (setq done t)))))
      (unwind-protect
          (let ((limit (+ (float-time) 2.5)))      ; the notice is due after 2 s, the daemon answers after 3 s
            (while (and (not (string-search "still starting" out)) (< (float-time) limit))
              (accept-process-output proc 0.1))
            (should (string-search "still starting" out))
            (should (process-live-p proc))
            (while (not done) (accept-process-output proc 0.1))
            (should (eql 0 (process-exit-status proc))))
        (when (process-live-p proc) (delete-process proc))))))

(ert-deftest drgnx-bin/the-open-lock-is-released-when-open-fails-or-is-stopped ()
  (drgnx-bin-test--with-open
    (let ((lock (drgnx-bin-test--lock dir)))
      ;; a daemon that never answers
      (write-region "never" nil (expand-file-name "delay" dir))
      (should (eql 1 (car (drgnx-bin-test--call drgnx-bin-test--bin (cons "DRGNX_OPEN_WAIT=1" env) "open"))))
      (should-not (file-exists-p lock))
      ;; stopped while it waits: TERM and a closed terminal (HUP); a background job cannot be sent INT
      (dolist (sig '("TERM" "HUP"))
        (drgnx-bin-test--call "bash" (append (list (concat "DRGNX_BIN=" drgnx-bin-test--bin) (concat "SIG=" sig)
                                                   "DRGNX_OPEN_WAIT=20")
                                             env)
                              "-c" "\"$DRGNX_BIN\" open & pid=$!; sleep 1; kill -s \"$SIG\" \"$pid\"; wait \"$pid\"")
        (should-not (file-exists-p lock))
        (delete-file (expand-file-name "running" dir))))))

(ert-deftest drgnx-bin/an-open-never-removes-a-lock-that-became-another-opens ()
  ;; The lock was taken over while this open waited for its daemon: when it finishes, the lock is not its own.
  (drgnx-bin-test--with-open
    (let ((lock (drgnx-bin-test--lock dir)))
      (write-region "2" nil (expand-file-name "delay" dir))
      (drgnx-bin-test--call "bash" (append (list (concat "DRGNX_BIN=" drgnx-bin-test--bin) (concat "LOCK=" lock)
                                                 "DRGNX_OPEN_WAIT=6")
                                           env)
                            "-c" "\"$DRGNX_BIN\" open & sleep 1; echo someone-else > \"$LOCK/owner\"; wait")
      (should (equal (drgnx-bin-test--slurp (expand-file-name "owner" lock)) "someone-else\n")))))

(ert-deftest drgnx-bin/a-lock-without-a-stamp-is-taken-over-after-a-few-seconds ()
  (drgnx-bin-test--with-open
    (let ((lock (drgnx-bin-test--lock dir)) (start (float-time)))
      (make-directory lock t)                    ; made, its owner died before it stamped it
      (should (eql 0 (car (drgnx-bin-test--call drgnx-bin-test--bin env "open"))))
      (should (>= (- (float-time) start) 3.5))   ; whole seconds: 5 of them can be 4.01 s
      (should (< (- (float-time) start) 9))
      (should-not (file-exists-p lock))
      (should (string-search "--bg-daemon=" (drgnx-bin-test--slurp (expand-file-name "emacs.log" dir)))))))

(ert-deftest drgnx-session/the-systemd-unit-is-started-when-enabled ()
  (drgnx-bin-test--with-open
    (let ((env (cons "DRGNX_SERVER_NAME" env)))   ; unset: the default name, `drgnx' (fake emacsclient)
      (drgnx-bin-test--touch dir "enabled")
      (should (eql 0 (car (drgnx-bin-test--call drgnx-bin-test--bin env "open"))))
      (should (equal (drgnx-bin-test--slurp (expand-file-name "systemctl.log" dir))
                     "--user is-enabled --quiet drgnx\n--user start drgnx\n"))
      (should (string-empty-p (drgnx-bin-test--slurp (expand-file-name "emacs.log" dir))))
      (should (equal (car (drgnx-bin-test--client-calls dir)) '("-a" "false" "-s" "drgnx" "--timeout=5" "-e" "t"))))))

(ert-deftest drgnx-session/paths-with-spaces-and-accents-stay-one-argument ()
  (drgnx-bin-test--with-open
    (drgnx-bin-test--touch dir "running" "gui")
    (let* ((proj (expand-file-name "My Project" dir))
           (odd (expand-file-name "q\"uote \\ back" dir))
           (file (expand-file-name "café.py" proj)))
      (make-directory proj) (make-directory odd)
      (drgnx-bin-test--call drgnx-bin-test--bin env "open" file "--check" odd)
      (let ((calls (drgnx-bin-test--client-calls dir)))
        (should (member (drgnx-bin-test--c "-n" "--" file (expand-file-name "--check" temporary-file-directory)) calls))
        ;; a folder name with a quote and a backslash is still one string to Emacs
        (should (equal (read (car (last (car (last calls))))) `(drgnx-session-open-folder ,odd)))))))

(ert-deftest drgnx-bin/a-path-is-opened-a-word-is-an-error ()
  (drgnx-bin-test--with-open
    (drgnx-bin-test--touch dir "running" "gui")
    (let ((proj (expand-file-name "My Project" dir)))
      (make-directory proj)
      (let ((drgnx-bin-test--cwd proj))
        (should (eql 0 (car (drgnx-bin-test--call drgnx-bin-test--bin env ".")))))
      (should (equal (car (last (drgnx-bin-test--client-calls dir))) (drgnx-bin-test--c "-n" "-e" (drgnx-bin-test--folder proj))))
      (let ((drgnx-bin-test--cwd dir))
        (should (eql 0 (car (drgnx-bin-test--call drgnx-bin-test--bin env "My Project"))))
        (should (equal (car (last (drgnx-bin-test--client-calls dir))) (drgnx-bin-test--c "-n" "-e" (drgnx-bin-test--folder proj))))
        (should (eql 0 (car (drgnx-bin-test--call drgnx-bin-test--bin env "./new.py"))))   ; a new file: like code new.py
        (should (equal (car (last (drgnx-bin-test--client-calls dir))) (drgnx-bin-test--c "-n" "--" (expand-file-name "new.py" dir))))
        (delete-file (expand-file-name "client.log" dir))
        (let ((r (drgnx-bin-test--call drgnx-bin-test--bin env "frobnicate")))
          (should (eql 2 (car r)))
          (should (string-search "unknown command 'frobnicate'" (cdr r))))
        (should-not (drgnx-bin-test--client-calls dir))))))

(ert-deftest drgnx-bin/open-wait-returns-when-you-are-done ()
  ;; drgnx as $EDITOR: `drgnx open --wait FILE' is emacsclient without -n, so it returns when you are done with
  ;; FILE (C-x #).  A folder cannot be waited on; without a display (ssh, a console) it waits in this terminal.
  (drgnx-bin-test--with-open
    (drgnx-bin-test--touch dir "running" "gui")
    (let ((file (expand-file-name "COMMIT_EDITMSG" dir)) (gui (append env '("DISPLAY=:99"))))
      (let ((drgnx-bin-test--cwd dir))
        (should (equal (drgnx-bin-test--call drgnx-bin-test--bin gui "open" "--wait" "COMMIT_EDITMSG") '(0 . ""))))
      (should (equal (drgnx-bin-test--client-calls dir)
                     (list (drgnx-bin-test--p "-e" "t")
                           (drgnx-bin-test--p "-e" "(drgnx-session-gui-frame-p)")
                           (drgnx-bin-test--c "-n" "-e" "(drgnx-session-raise)")
                           (drgnx-bin-test--c "-n" "-e" drgnx-bin-test--load-keys)
                           (drgnx-bin-test--c "--" file))))
      (delete-file (expand-file-name "client.log" dir))
      (dolist (args `(("open" "--wait" ,dir) ("open" "--wait") ("open" "--wait" ,file ,dir)))
        (let ((r (apply #'drgnx-bin-test--call drgnx-bin-test--bin gui args)))
          (should (eql 2 (car r)))
          (should (string-search "--wait opens files" (cdr r)))))
      (should-not (drgnx-bin-test--client-calls dir))
      (unless (eq system-type 'darwin)          ; a Mac always has its display
        (should (eql 0 (car (drgnx-bin-test--call drgnx-bin-test--bin (append env '("DISPLAY" "WAYLAND_DISPLAY"))
                                                  "open" "--wait" file))))
        (should (equal (drgnx-bin-test--client-calls dir)
                       (list (drgnx-bin-test--p "-e" "t") (drgnx-bin-test--c "-t" "--" file))))))))

(ert-deftest drgnx-bin/open-check-stops-only-a-daemon-it-started ()
  (drgnx-bin-test--with-open
    (let ((r (drgnx-bin-test--call drgnx-bin-test--bin env "open" "--check")))
      (should (equal r '(0 . "GNU Emacs 99.1 (fake)\n"))))
    (should (string-search "--bg-daemon=" (drgnx-bin-test--slurp (expand-file-name "emacs.log" dir))))
    (should (member (drgnx-bin-test--c "-e" "(kill-emacs)") (drgnx-bin-test--client-calls dir)))
    (should-not (seq-find (lambda (c) (member "-c" c)) (drgnx-bin-test--client-calls dir)))   ; never a window
    ;; already running: asked, left running
    (delete-file (expand-file-name "client.log" dir))
    (drgnx-bin-test--touch dir "running")
    (should (eql 0 (car (drgnx-bin-test--call drgnx-bin-test--bin env "open" "--check"))))
    (should-not (member (drgnx-bin-test--c "-e" "(kill-emacs)") (drgnx-bin-test--client-calls dir)))
    (should (file-exists-p (expand-file-name "running" dir)))))

(ert-deftest drgnx-bin/open-check-with-a-real-daemon ()
  ;; The CI check end to end, headless: the real Emacs starts drgnx as a daemon under a test name (its own
  ;; runtime dir), answers, and is gone afterwards.
  (let* ((dir (make-temp-file "drgnx-bin-check" t))
         (run (expand-file-name "run" dir))
         (name (format "drgnx-check-%d" (emacs-pid)))
         (emacs (expand-file-name invocation-name invocation-directory))
         (env (list (concat "HOME=" dir) (concat "DRGNX_EMACS=" emacs) (concat "DRGNX_CONFIG_DIR=" dir "/config")
                    (concat "XDG_RUNTIME_DIR=" run) (concat "DRGNX_SERVER_NAME=" name) "DISPLAY" "WAYLAND_DISPLAY")))
    (make-directory run) (set-file-modes run #o700)
    (unwind-protect
        (let ((r (drgnx-bin-test--call drgnx-bin-test--bin env "open" "--check")))
          (should (eql 0 (car r)))
          (should (string-search (format "GNU Emacs %s" emacs-version) (cdr r)))
          (should-not (file-exists-p (expand-file-name (concat "emacs/" name) run))))
      (let ((process-environment (append env process-environment)))   ; never left running, even when it failed
        (call-process (expand-file-name "emacsclient" invocation-directory) nil nil nil
                      "-a" "false" "-s" name "-e" "(kill-emacs)"))
      (delete-directory dir t))))

;;;; drgnx test — a run leaves nothing behind in the parent temp dir (/tmp is RAM)

(defun drgnx-bin-test--leaky-suite (dir probe &optional hang)
  "Write a one-test suite into DIR.  The test leaks a temp dir and a temp file, records its
`temporary-file-directory' in PROBE and its Emacs pid in PROBE.pid and, with HANG, then waits for a signal."
  (with-temp-file (expand-file-name "leaky-test.el" dir)
    (insert (format "(require 'ert)
(ert-deftest tmp-probe/leaks ()
  (make-temp-file \"leaked-dir\" t)
  (make-temp-file \"leaked-file\")
  (write-region (number-to-string (emacs-pid)) nil %S nil 'silent)
  (write-region temporary-file-directory nil %S nil 'silent)
  %s
  (should t))
" (concat probe ".pid") probe (if hang "(sleep-for 120)" "")))))

(defun drgnx-bin-test--left (parent)
  "What a test run left in PARENT."
  (directory-files parent nil directory-files-no-dot-files-regexp))

(defun drgnx-bin-test--slurp-number (file)
  (string-to-number (drgnx-bin-test--slurp file)))

(defun drgnx-bin-test--env (dir parent &rest more)
  (append more   ; first: it wins over the unsets below
          (list (concat "HOME=" dir) (concat "DRGNX_CONFIG_DIR=" dir "/config") (concat "TMPDIR=" parent)
                "DRGNX_TEST_SELECTOR=\"tmp-probe/leaks\"" "DRGNX_TEST_RESULTS" "DRGNX_RUN_TMP")))

(defun drgnx-bin-test--spawn (env &rest args)
  "Start bin/drgnx ARGS with ENV; return the process."
  (let ((process-environment (append env process-environment)))
    (make-process :name "drgnx-bin-test-run" :command (cons drgnx-bin-test--bin args)
                  :buffer nil :noquery t :connection-type 'pipe)))

(defun drgnx-bin-test--wait-for (pred secs)
  (let ((until (+ (float-time) secs)))
    (while (and (not (funcall pred)) (< (float-time) until)) (sleep-for 0.1))
    (funcall pred)))

(defun drgnx-bin-test--wait-exit (proc secs)
  (let ((until (+ (float-time) secs)))
    (while (and (process-live-p proc) (< (float-time) until)) (accept-process-output proc 0.1))
    (not (process-live-p proc))))

(defun drgnx-bin-test--pid-alive-p (pid)
  (and (> pid 0) (file-exists-p (format "/proc/%d" pid))
       (not (string-match-p "^State:\\s-*Z" (with-temp-buffer (insert-file-contents (format "/proc/%d/status" pid))
                                                              (buffer-string))))))

(ert-deftest drgnx-bin/a-test-run-leaves-nothing-in-the-parent-temp-dir ()
  ;; TMP-1: every run has a TMPDIR of its own (so tests, libgccjit and the runner all write there) that
  ;; the run removes on exit; the tests here leak a dir and a file on purpose.
  (let* ((dir (make-temp-file "drgnx-bin-tmp" t))
         (parent (expand-file-name "parent" dir))
         (suite (expand-file-name "suite" dir))
         (probe (expand-file-name "probe" dir))
         (emacs (expand-file-name invocation-name invocation-directory)))
    (unwind-protect
        (progn
          (make-directory parent) (make-directory suite)
          (drgnx-bin-test--leaky-suite suite probe)
          (let ((r (drgnx-bin-test--call drgnx-bin-test--bin
                                         (drgnx-bin-test--env dir parent (concat "DRGNX_EMACS=" emacs)
                                                              (concat "DRGNX_TEST_DIR=" suite))
                                         "test")))
            (should (eql 0 (car r))))
          ;; the test did run in a temp dir of its own (in the runner's short root, so its sockets fit), not in
          ;; PARENT itself …
          (let ((seen (drgnx-bin-test--slurp probe)))
            ;; (in /tmp, or in the run's TMPDIR where /tmp cannot be written)
            (should (string-match-p "/drgnx-t-[A-Za-z0-9]\\{6\\}/drgnx-run\\.[A-Za-z0-9]\\{6\\}/\\'" seen))
            ;; … and nothing of it is left, there nor in PARENT
            (should-not (file-exists-p (file-name-directory (directory-file-name seen)))))
          (should-not (drgnx-bin-test--left parent)))
      (delete-directory dir t))))

(defun drgnx-bin-test--fake-emacs (file body)
  "A fake Emacs script FILE running the shell BODY."
  (write-region (concat "#!/bin/sh\n" body "\n") nil file nil 'silent)
  (set-file-modes file #o755)
  file)

(ert-deftest drgnx-bin/the-unit-tier-starts-emacs-without-the-users-desktop ()
  ;; The C environment of the batch Emacs decides where dbus.el connects (a Lisp `setenv' does not reach it):
  ;; a dead session bus, no display or compositor, a runtime directory of its own (mode 700, in the run's TMPDIR).
  (let* ((dir (make-temp-file "drgnx-bin-tmp" t))
         (parent (expand-file-name "parent" dir))
         (seen (expand-file-name "seen" dir))
         (emacs (drgnx-bin-test--fake-emacs
                 (expand-file-name "fake-emacs" dir)
                 (format "echo \"$DBUS_SESSION_BUS_ADDRESS|${DISPLAY-unset}|${WAYLAND_DISPLAY-unset}|${SWAYSOCK-unset}|${I3SOCK-unset}|${HYPRLAND_INSTANCE_SIGNATURE-unset}|${NIRI_SOCKET-unset}|$XDG_RUNTIME_DIR|$TMPDIR\" > %s; ls -ld \"$XDG_RUNTIME_DIR\" >> %s" seen seen)))
         (drgnx-bin-test--cwd dir))
    (unwind-protect
        (progn
          (make-directory parent)
          (should (eql 0 (car (drgnx-bin-test--call
                               drgnx-bin-test--bin
                               (drgnx-bin-test--env dir parent (concat "DRGNX_EMACS=" emacs)
                                                    "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus" "DISPLAY=:0"
                                                    "WAYLAND_DISPLAY=wayland-0" "SWAYSOCK=/run/sway" "I3SOCK=/run/i3"
                                                    "HYPRLAND_INSTANCE_SIGNATURE=abc" "NIRI_SOCKET=/run/niri"
                                                    "XDG_RUNTIME_DIR=/run/user/1000")
                               "test"))))
          (let* ((lines (split-string (drgnx-bin-test--slurp seen) "\n" t))
                 (v (split-string (car lines) "|")))
            (should (equal (seq-take v 7)
                           '("unix:path=/nonexistent/drgnx-unit-test" "unset" "unset" "unset" "unset" "unset" "unset")))
            (should (equal (nth 7 v) (concat (nth 8 v) "/run")))
            (should (string-prefix-p "drwx------" (nth 1 lines)))))
      (delete-directory dir t))))

(ert-deftest drgnx-bin/a-container-run-forwards-the-test-selector ()
  ;; A narrowed `bin/drgnx test --container' stays narrow inside the container.
  (let* ((dir (make-temp-file "drgnx-bin-tmp" t))
         (log (expand-file-name "rt.log" dir))
         (rt (drgnx-bin-test--fake-emacs (expand-file-name "fake-rt" dir)
                                         (format "for a in \"$@\"; do echo \"$a\" >> %s; done" log)))
         (drgnx-bin-test--cwd dir))
    (unwind-protect
        (dolist (selector '("\"foo/bar\"" nil))
          (when (file-exists-p log) (delete-file log))
          (should (eql 0 (car (drgnx-bin-test--call
                               drgnx-bin-test--bin
                               (list (concat "HOME=" dir) (concat "DRGNX_CONFIG_DIR=" dir "/config")
                                     (concat "DRGNX_CONTAINER=" rt) "DRGNX_TEST_IMAGE=an-image"
                                     (if selector (concat "DRGNX_TEST_SELECTOR=" selector) "DRGNX_TEST_SELECTOR"))
                               "test" "--container"))))
          (let ((args (split-string (drgnx-bin-test--slurp log) "\n" t)))
            (should (member "run" args))
            (if selector
                (should (member (concat "DRGNX_TEST_SELECTOR=" selector) args))
              (should-not (seq-find (lambda (a) (string-prefix-p "DRGNX_TEST_SELECTOR" a)) args)))))
      (delete-directory dir t))))

(ert-deftest drgnx-bin/a-relative-tmpdir-is-made-absolute ()
  ;; the child (and what it starts) must see absolute TMPDIR and DRGNX_RUN_TMP, whatever the caller's TMPDIR
  (let* ((dir (make-temp-file "drgnx-bin-tmp" t))
         (parent (expand-file-name "parent" dir))
         (seen (expand-file-name "seen" dir))
         (emacs (drgnx-bin-test--fake-emacs (expand-file-name "fake-emacs" dir)
                                            (format "echo \"$TMPDIR|$DRGNX_RUN_TMP\" > %s" seen)))
         (drgnx-bin-test--cwd dir))
    (unwind-protect
        (progn
          (make-directory parent)
          (should (eql 0 (car (drgnx-bin-test--call drgnx-bin-test--bin
                                                    (drgnx-bin-test--env dir "parent" (concat "DRGNX_EMACS=" emacs))
                                                    "test"))))
          (let ((s (split-string (string-trim (drgnx-bin-test--slurp seen)) "|")))
            (should (= 2 (length s)))
            (dolist (v s)
              (should (string-prefix-p (file-name-as-directory (file-truename parent)) v))))
          (should-not (drgnx-bin-test--left parent)))
      (delete-directory dir t))))

(ert-deftest drgnx-bin/a-test-run-stopped-by-a-signal-leaves-nothing-and-no-emacs ()
  ;; TMP-1: a run stopped half way (INT/TERM/HUP, as systemd, Ctrl-C and a closing terminal send) removes its
  ;; TMPDIR and its Emacs is gone.
  (dolist (sig '(TERM INT HUP))
    (let* ((dir (make-temp-file "drgnx-bin-tmp" t))
           (parent (expand-file-name "parent" dir))
           (suite (expand-file-name "suite" dir))
           (probe (expand-file-name "probe" dir))
           (emacs (expand-file-name invocation-name invocation-directory))
           proc)
      (unwind-protect
          (progn
            (make-directory parent) (make-directory suite)
            (drgnx-bin-test--leaky-suite suite probe 'hang)
            (setq proc (drgnx-bin-test--spawn (drgnx-bin-test--env dir parent (concat "DRGNX_EMACS=" emacs)
                                                                   (concat "DRGNX_TEST_DIR=" suite))
                                              "test"))
            (should (drgnx-bin-test--wait-for (lambda () (file-exists-p probe)) 60))   ; the test is under way
            (should (drgnx-bin-test--left parent))                                      ; using its temp dir
            (let ((pid (drgnx-bin-test--slurp-number (concat probe ".pid"))))
              (should (drgnx-bin-test--pid-alive-p pid))
              (signal-process proc sig)
              (should (drgnx-bin-test--wait-exit proc 30))
              (should (drgnx-bin-test--wait-for (lambda () (not (drgnx-bin-test--pid-alive-p pid))) 10)))
            (should-not (drgnx-bin-test--left parent))
            ;; nor the runner's short root its test ran in
            (should-not (file-exists-p (file-name-directory (directory-file-name (drgnx-bin-test--slurp probe))))))
        (when (process-live-p proc) (kill-process proc))
        (delete-directory dir t)))))

(ert-deftest drgnx-bin/a-gui-tier-stopped-by-a-signal-leaves-no-process-and-no-dir ()
  ;; TMP-1: the GUI tiers run a function that starts the controller Emacs (not exec'd): the whole process
  ;; group is stopped.  The fake Emacs starts a child and ignores TERM; a second TERM during the grace period
  ;; does not cut the cleanup short.
  (let* ((dir (make-temp-file "drgnx-bin-tmp" t))
         (parent (expand-file-name "parent" dir))
         (pids (expand-file-name "pids" dir))
         (emacs (drgnx-bin-test--fake-emacs
                 (expand-file-name "fake-emacs" dir)
                 (format "trap '' TERM\nsleep 300 &\necho \"$$ $!\" > %s.tmp && mv %s.tmp %s\nwait" pids pids pids)))
         proc)
    (unwind-protect
        (progn
          (make-directory parent)
          (setq proc (drgnx-bin-test--spawn (drgnx-bin-test--env dir parent (concat "DRGNX_EMACS=" emacs) "DRGNX_RUN_GRACE=2")
                                            "test" "--scenario"))
          (should (drgnx-bin-test--wait-for (lambda () (file-exists-p pids)) 30))
          (let* ((ids (mapcar #'string-to-number (split-string (drgnx-bin-test--slurp pids))))
                 (alive (lambda () (seq-filter #'drgnx-bin-test--pid-alive-p ids))))
            (should (= 2 (length (funcall alive))))
            (signal-process proc 'TERM)
            (sleep-for 0.5)
            (signal-process proc 'TERM)
            (should (drgnx-bin-test--wait-exit proc 30))
            (should-not (funcall alive))
            (should-not (drgnx-bin-test--left parent))))
      (when (process-live-p proc) (kill-process proc))
      (delete-directory dir t))))

(ert-deftest drgnx-bin/a-stopped-check-gets-the-time-to-end-its-jobs-before-the-dir-goes ()
  ;; TMP-1 re-review: `drgnx check' ends its jobs (each in a session of its own, outside bin's process group)
  ;; with a grace of its own (15 s) before it KILLs them.  bin waits for the check to end, not a fixed 5 s, and
  ;; only then removes the dir.  The fake check lets its TERM-ignoring job live 7 s after the TERM.
  (let* ((dir (make-temp-file "drgnx-bin-tmp" t))
         (parent (expand-file-name "parent" dir))
         (job (expand-file-name "job.pid" dir))
         (emacs (drgnx-bin-test--fake-emacs
                 (expand-file-name "fake-check" dir)
                 (format "setsid sh -c 'trap \"\" TERM; echo $$ > %s.tmp && mv %s.tmp %s; exec sleep 300' &
trap 'kill -TERM $(cat %s); sleep 7; kill -KILL $(cat %s); exit 0' TERM
while :; do wait; done" job job job job job)))
         proc)
    (unwind-protect
        (progn
          (make-directory parent)
          (setq proc (drgnx-bin-test--spawn (drgnx-bin-test--env dir parent (concat "DRGNX_EMACS=" emacs)) "check"))
          (should (drgnx-bin-test--wait-for (lambda () (file-exists-p job)) 30))
          (sleep-for 0.3)                                  ; the fake has set its trap
          (let ((pid (drgnx-bin-test--slurp-number job)))
            (should (drgnx-bin-test--pid-alive-p pid))
            (signal-process proc 'TERM)
            (should (drgnx-bin-test--wait-exit proc 45))
            (should-not (drgnx-bin-test--pid-alive-p pid))   ; ended by the check, not orphaned
            (should-not (drgnx-bin-test--left parent))))
      (when (process-live-p proc) (kill-process proc))
      (when (file-exists-p job) (ignore-errors (signal-process (drgnx-bin-test--slurp-number job) 'KILL)))
      (delete-directory dir t))))

(ert-deftest drgnx-bin/check-runs-in-a-tmpdir-of-its-own-and-its-shards-make-theirs ()
  ;; TMP-1: `drgnx check' starts many runs at once: they share the TMPDIR (removed at the end) but not
  ;; DRGNX_RUN_TMP, or the first to end would delete the others' dir.
  (let* ((dir (make-temp-file "drgnx-bin-tmp" t))
         (parent (expand-file-name "parent" dir))
         (seen (expand-file-name "seen" dir))
         (emacs (drgnx-bin-test--fake-emacs
                 (expand-file-name "fake-emacs" dir)
                 (format "echo \"$TMPDIR|${DRGNX_RUN_TMP-unset}\" > %s" seen))))
    (unwind-protect
        (progn
          (make-directory parent)
          (should (eql 0 (car (drgnx-bin-test--call
                               drgnx-bin-test--bin
                               (drgnx-bin-test--env dir parent (concat "DRGNX_EMACS=" emacs) "DRGNX_RUN_TMP=/nonexistent/x")
                               "check"))))
          (let ((s (split-string (string-trim (drgnx-bin-test--slurp seen)) "|")))
            (should (string-prefix-p (file-name-as-directory parent) (car s)))
            (should (equal (cadr s) "unset")))
          (should-not (drgnx-bin-test--left parent)))
      (delete-directory dir t))))

;;; bin-test.el ends here

(ert-deftest drgnx-bin/test-one-process-flag ()
  ;; `bin/drgnx test' runs each test file in an Emacs of its own; --one-process keeps them all in one (for hunting a
  ;; leak across files): the runner reads DRGNX_TEST_ONE_PROCESS.
  (let* ((dir (make-temp-file "drgnx-bin-tmp" t))
         (parent (expand-file-name "parent" dir))
         (seen (expand-file-name "seen" dir))
         (emacs (drgnx-bin-test--fake-emacs (expand-file-name "fake-emacs" dir)
                                            (format "echo \"${DRGNX_TEST_ONE_PROCESS-unset}\" >> %s" seen)))
         (drgnx-bin-test--cwd dir))
    (unwind-protect
        (progn
          (make-directory parent)
          (dolist (args '(("test") ("test" "--one-process")))
            (should (eql 0 (car (apply #'drgnx-bin-test--call drgnx-bin-test--bin
                                       (drgnx-bin-test--env dir parent (concat "DRGNX_EMACS=" emacs) "DRGNX_TEST_ONE_PROCESS")
                                       args)))))
          (should (equal (split-string (drgnx-bin-test--slurp seen) "\n" t) '("unset" "1"))))
      (delete-directory dir t))))
