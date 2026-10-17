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
answers), gui (a window is open), enabled (the systemd unit is).  emacsclient logs each call to
client.log, one line per call, every argument followed by \\037; emacs and systemctl log theirs."
  (let ((f (lambda (name) (shell-quote-argument (expand-file-name name dir)))))
    (dolist (spec `(("emacsclient"
                     ,(format "printf '%%s\\037' \"$@\" >> %s; echo >> %s
for a in \"$@\"; do last=\"$a\"; done
case \"$last\" in
  t) [ -f %s ] || exit 1 ;;
  '(drgnx-session-gui-frame-p)') if [ -f %s ]; then echo t; else echo nil; fi ;;
  '(emacs-version)') echo '\"GNU Emacs 99.1 (fake)\"' ;;
  '(kill-emacs)') rm -f %s ;;
esac"
                              (funcall f "client.log") (funcall f "client.log") (funcall f "running")
                              (funcall f "gui") (funcall f "running")))
                    ("emacs" ,(format "echo \"$*\" >> %s\ncase \"$*\" in *--bg-daemon=*) touch %s ;; esac"
                                      (funcall f "emacs.log") (funcall f "running")))
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
     (let ((env (cons (concat "DRGNX_SERVER_NAME=" drgnx-bin-test--server) env)))
       ,@body)))

(defun drgnx-bin-test--c (&rest args)
  "An emacsclient call to the test's server with ARGS, as the fake logs it."
  (append (list "-a" "false" "-s" drgnx-bin-test--server) args))

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
                     (list (drgnx-bin-test--c "-e" "t")
                           (drgnx-bin-test--c "-e" "(drgnx-session-gui-frame-p)")
                           (drgnx-bin-test--c "-n" "-e" "(drgnx-session-raise)")
                           (drgnx-bin-test--c "-n" "--" file)
                           (drgnx-bin-test--c "-n" "-e" (drgnx-bin-test--folder sub)))))
      (should (string-empty-p (drgnx-bin-test--slurp (expand-file-name "emacs.log" dir))))
      ;; No window open: one is made first (-c), then the same.
      (delete-file (expand-file-name "gui" dir))
      (delete-file (expand-file-name "client.log" dir))
      (let ((drgnx-bin-test--cwd dir))
        (drgnx-bin-test--call drgnx-bin-test--bin env "open" "My Project/café.py"))
      (should (equal (drgnx-bin-test--client-calls dir)
                     (list (drgnx-bin-test--c "-e" "t")
                           (drgnx-bin-test--c "-e" "(drgnx-session-gui-frame-p)")
                           (drgnx-bin-test--c "-n" "-c")
                           (drgnx-bin-test--c "-n" "-e" "(drgnx-session-raise)")
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
      (should (equal (car calls) (drgnx-bin-test--c "-e" "t")))
      ;; polled until the server answers, then: no window yet, so one is made — restore only (no path)
      (should (equal (seq-remove (lambda (c) (equal c (drgnx-bin-test--c "-e" "t"))) calls)
                     (list (drgnx-bin-test--c "-e" "(drgnx-session-gui-frame-p)")
                           (drgnx-bin-test--c "-n" "-c")
                           (drgnx-bin-test--c "-n" "-e" "(drgnx-session-raise)")))))))

(ert-deftest drgnx-session/the-systemd-unit-is-started-when-enabled ()
  (drgnx-bin-test--with-open
    (let ((env (cons "DRGNX_SERVER_NAME" env)))   ; unset: the default name, `drgnx' (fake emacsclient)
      (drgnx-bin-test--touch dir "enabled")
      (should (eql 0 (car (drgnx-bin-test--call drgnx-bin-test--bin env "open"))))
      (should (equal (drgnx-bin-test--slurp (expand-file-name "systemctl.log" dir))
                     "--user is-enabled --quiet drgnx\n--user start drgnx\n"))
      (should (string-empty-p (drgnx-bin-test--slurp (expand-file-name "emacs.log" dir))))
      (should (equal (car (drgnx-bin-test--client-calls dir)) '("-a" "false" "-s" "drgnx" "-e" "t"))))))

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

;;; bin-test.el ends here
