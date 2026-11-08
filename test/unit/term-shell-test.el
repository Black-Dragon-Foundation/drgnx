;;; term-shell-test.el --- batch tests: the shell side of drgnx's terminal (integration, ssh, terminfo, environment) -*- lexical-binding: t -*-
;; Each shell runs with a temp HOME, no rc files of its own and no controlling terminal (setsid when there is one):
;; never the user's rc files or live Emacs.  bash and zsh must be here; fish's parts skip without it, and so do the
;; terminfo parts without tic and infocmp.  Synchronous `call-process' only.
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-terminal" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-term" drgnx-dir) nil t)

(defconst drgnx-term-shell-test--dir (expand-file-name "etc/shell" drgnx-dir) "The shell files' directory.")

(defconst drgnx-term-shell-test--shells
  '((bash "drgnx.bash" ("--norc" "--noprofile")) (zsh "drgnx.zsh" ("-f")) (fish "drgnx.fish" ("-N")))
  "Per shell: its file and the arguments that keep its own rc files out.")

(defun drgnx-term-shell-test--shells ()
  "The shells here: bash and zsh must be, fish may be."
  (should (executable-find "bash"))
  (should (executable-find "zsh"))
  (seq-filter (lambda (s) (executable-find (symbol-name s))) '(bash zsh fish)))

(defun drgnx-term-shell-test--file (shell)
  "SHELL's drgnx file."
  (expand-file-name (nth 1 (assq shell drgnx-term-shell-test--shells)) drgnx-term-shell-test--dir))

(defun drgnx-term-shell-test--run (shell args env &optional input path)
  "Run SHELL with its rc files off, then ARGS, in a temp HOME (also its XDG_STATE_HOME's parent) with ENV added to
a clean environment; INPUT is its stdin, PATH (a directory) goes first on PATH.  Returns (EXIT OUTPUT HOME-STATE-FILE),
OUTPUT being stdout and stderr together and HOME-STATE-FILE the text of the ssh hosts record, or nil."
  (let* ((home (make-temp-file "drgnx-term-shell" t))
         (in (expand-file-name "stdin" home))
         (process-environment
          (append env
                  (list (concat "HOME=" home) (concat "ZDOTDIR=" home) (concat "XDG_CONFIG_HOME=" home "/.config")
                        (concat "XDG_STATE_HOME=" home "/state") (concat "XDG_DATA_HOME=" home "/data")
                        (concat "PATH=" (if path (concat path ":") "") "/usr/bin:/bin")
                        "HISTFILE" "PROMPT_COMMAND" "PS1=$ ")
                  (seq-remove (lambda (e) (string-match-p "\\`\\(HOME\\|ZDOTDIR\\|XDG_[A-Z_]*\\|TERM\\|INSIDE_EMACS\\|PATH\\|EAT_[A-Z_]*\\|GHOSTTY_[A-Z_]*\\|DRGNX_[A-Z_]*\\|TERMINFO\\|TERM_PROGRAM\\)=" e))
                              process-environment))))
    (unwind-protect
        (progn
          (write-region (or input "") nil in nil 'silent)
          (with-temp-buffer
            (let* ((exe (executable-find (symbol-name shell)))
                   (argv (append (nth 2 (assq shell drgnx-term-shell-test--shells)) args))
                   (exit (if (executable-find "setsid")
                             (apply #'call-process "setsid" in t nil "-w" exe argv)
                           (apply #'call-process exe in t nil argv)))
                   (record (expand-file-name "state/drgnx/terminal-ssh-hosts" home)))
              (list exit (buffer-string)
                    (and (file-exists-p record) (with-temp-buffer (insert-file-contents record) (buffer-string)))))))
      (delete-directory home t))))

(defconst drgnx-term-shell-test--inside
  '("DRGNX_TERMINAL=1" "INSIDE_EMACS=31.1,drgnx" "TERM=xterm-256color"
    "GHOSTTY_SHELL_FEATURES=cursor,title,sudo,ssh-env,ssh-terminfo" "GHOSTTY_BIN_DIR=/nonexistent/ghostty/bin")
  "The environment drgnx's terminal gives its shell (as `drgnx-term--env' makes it), plus what a Ghostty around
drgnx would leave: ssh features and a bin dir.")

(ert-deftest drgnx-term-shell/shell-integration-marks-prompts ()
  ;; inside drgnx's terminal the shell's file loads Ghostty's integration: prompt (133;A), output (133;C) and end
  ;; (133;D with the status) marks, the folder (OSC 7) and the title (OSC 2); ssh features off, no Ghostty bin dir
  (dolist (shell (drgnx-term-shell-test--shells))
    (let* ((file (drgnx-term-shell-test--file shell))
           (show "echo \"f=$GHOSTTY_SHELL_FEATURES r=$GHOSTTY_RESOURCES_DIR b=${GHOSTTY_BIN_DIR-unset}\"")
           (r (pcase shell
                ('fish (drgnx-term-shell-test--run
                        'fish (list "-i" "-c" (format "source '%s'; echo \"f=$GHOSTTY_SHELL_FEATURES r=$GHOSTTY_RESOURCES_DIR b=$GHOSTTY_BIN_DIR\"; emit fish_prompt; cd /tmp; emit fish_preexec 'echo hi'; echo hi; emit fish_postexec 'echo hi'; emit fish_prompt" file))
                        drgnx-term-shell-test--inside))
                (_ (drgnx-term-shell-test--run
                    shell '("-i") drgnx-term-shell-test--inside
                    (format "source '%s'\n%s\ncd /tmp\necho hi\nexit\n" file show)))))
           (out (nth 1 r)))
      (should (equal (list shell (nth 0 r)) (list shell 0)))
      (should (string-search (format "f=cursor,title,sudo r=%s/ghostty b=%s" drgnx-term-shell-test--dir
                                     (if (eq shell 'fish) "" "unset"))
                             out))
      (dolist (mark '("\e]133;A" "\e]133;C" "\e]133;D;0"))
        (should (equal (list shell mark (and (string-search mark out) t)) (list shell mark t))))
      (should (equal (list shell 'cwd (and (string-match-p "\e]7;[a-z-]+://[^/\a]*/tmp\a" out) t)) (list shell 'cwd t)))
      (unless (eq shell 'fish)                 ; fish sets its own title, from its prompt loop, not from these events
        (should (equal (list shell 'title (and (string-search "\e]2;" out) t)) (list shell 'title t)))))))

(ert-deftest drgnx-term-shell/no-integration-outside-or-when-off ()
  ;; outside drgnx's terminal, or with the integration off (no GHOSTTY_SHELL_FEATURES), or meant for another shell:
  ;; no marks and no Ghostty variables
  (dolist (shell (seq-remove (lambda (s) (eq s 'fish)) (drgnx-term-shell-test--shells)))
    (dolist (env (list nil
                       (remove "GHOSTTY_SHELL_FEATURES=cursor,title,sudo,ssh-env,ssh-terminfo" drgnx-term-shell-test--inside)
                       (cons "DRGNX_TERMINAL_SHELL=fish" drgnx-term-shell-test--inside)))
      (let* ((r (drgnx-term-shell-test--run
                 shell '("-i") env
                 (format "source '%s'\necho \"r=${GHOSTTY_RESOURCES_DIR-unset}\"\necho hi\nexit\n"
                         (drgnx-term-shell-test--file shell)))))
        (should (equal (list shell env (nth 0 r)) (list shell env 0)))
        (should (string-search "r=unset" (nth 1 r)))
        (should-not (string-search "\e]133;" (nth 1 r)))))))

(ert-deftest drgnx-term-shell/bash-3-2-gets-cwd-and-title ()
  ;; macOS's /bin/bash is 3.2: Ghostty's file then uses bash-preexec.  Only where a 3.2 binary is installed
  (let ((bash32 (seq-find #'executable-find '("bash-3.2" "bash32"))))
    (unless bash32 (ert-skip "no bash 3.2 here (macOS CI has it as /bin/bash)"))
    (let* ((home (make-temp-file "drgnx-term-shell" t))
           (process-environment (append drgnx-term-shell-test--inside (list (concat "HOME=" home)) process-environment)))
      (unwind-protect
          (with-temp-buffer
            (insert (format "source '%s'\ncd /tmp\necho hi\nexit\n" (drgnx-term-shell-test--file 'bash)))
            (call-process-region (point-min) (point-max) (executable-find bash32) t t nil "--norc" "--noprofile" "-i")
            (should (string-match-p "\e]7;[a-z-]+://[^/\a]*/tmp\a" (buffer-string)))
            (should (string-search "\e]2;" (buffer-string))))
        (delete-directory home t)))))

(defun drgnx-term-shell-test--ssh-stubs (dir)
  "Stub `ssh' and `infocmp' in DIR: ssh -G answers a config, every other ssh logs TERM, its arguments and (for tic)
its stdin to DIR/ssh.log; infocmp prints a one-line entry.  Returns DIR."
  (let ((log (expand-file-name "ssh.log" dir)))
    (dolist (spec `(("ssh" . ,(format "if [ \"$1\" = -G ]; then printf 'user me\\nhostname example.org\\nport 2222\\n'; exit 0; fi
printf 'TERM=%%s args=%%s\\n' \"$TERM\" \"$*\" >> '%s'
case \"$*\" in *tic*) printf 'stdin=%%s\\n' \"$(cat)\" >> '%s' ;; esac" log log))
                    ("infocmp" . "printf 'xterm-ghostty|stub,\\n'")))
      (let ((file (expand-file-name (car spec) dir)))
        (write-region (concat "#!/bin/sh\n" (cdr spec) "\n") nil file nil 'silent)
        (set-file-modes file #o755)))
    dir))

(defun drgnx-term-shell-test--ssh (shell mode calls &optional args)
  "Source SHELL's file inside drgnx's terminal (TERM=xterm-ghostty, ssh terminfo MODE) and run `ssh ARGS' (default
\"host\") CALLS times against the stubs; returns (EXIT LOG RECORD)."
  (let ((stubs (make-temp-file "drgnx-term-ssh" t)))
    (unwind-protect
        (let* ((env (list "DRGNX_TERMINAL=1" "TERM=xterm-ghostty" (concat "DRGNX_TERMINAL_SSH=" mode)))
               (script (format "source '%s'; %s" (drgnx-term-shell-test--file shell)
                               (string-join (make-list calls (concat "ssh " (or args "host"))) "; ")))
               (r (drgnx-term-shell-test--run shell (list "-c" script) env nil
                                              (drgnx-term-shell-test--ssh-stubs stubs)))
               (log (expand-file-name "ssh.log" stubs)))
          (list (nth 0 r) (and (file-exists-p log) (with-temp-buffer (insert-file-contents log) (buffer-string)))
                (nth 2 r)))
      (delete-directory stubs t))))

(ert-deftest drgnx-term-shell/ssh-fallback-sets-xterm-256color ()
  ;; a remote host without Ghostty's entry: ssh sees TERM=xterm-256color, nothing is installed or recorded
  (dolist (shell (drgnx-term-shell-test--shells))
    (should (equal (cons shell (drgnx-term-shell-test--ssh shell "fallback" 1))
                   (list shell 0 "TERM=xterm-256color args=host\n" nil)))))

(ert-deftest drgnx-term-shell/ssh-install-runs-tic-once ()
  ;; install: the first ssh to a host sends the entry to the host's tic and records it; later ones just connect
  (dolist (shell (drgnx-term-shell-test--shells))
    ;; the tic call keeps the options and drops the command: the host's tic runs instead of `uptime'
    (pcase-let ((`(,exit ,log ,record) (drgnx-term-shell-test--ssh shell "install" 2 "-p 2222 -A host uptime")))
      (should (equal (list shell exit) (list shell 0)))
      (should (equal (list shell log)
                     (list shell (concat "TERM=xterm-256color args=-p 2222 -A -- host tic -x -\n"
                                         "stdin=xterm-ghostty|stub,\n"
                                         "TERM=xterm-ghostty args=-p 2222 -A host uptime\n"
                                         "TERM=xterm-ghostty args=-p 2222 -A host uptime\n"))))
      (should (equal (list shell record) (list shell "me@example.org:2222 xterm-ghostty\n"))))))

(ert-deftest drgnx-term-shell/ssh-untouched-outside-the-terminal ()
  ;; outside drgnx's terminal there is no ssh function: the stub sees the shell's own TERM
  (dolist (shell (drgnx-term-shell-test--shells))
    (let ((stubs (make-temp-file "drgnx-term-ssh" t)))
      (unwind-protect
          (let ((r (drgnx-term-shell-test--run
                    shell (list "-c" (format "source '%s'; ssh host" (drgnx-term-shell-test--file shell)))
                    '("TERM=xterm-ghostty") nil (drgnx-term-shell-test--ssh-stubs stubs))))
            (should (equal (list shell (nth 0 r)) (list shell 0)))
            (should (equal (with-temp-buffer (insert-file-contents (expand-file-name "ssh.log" stubs)) (buffer-string))
                           "TERM=xterm-ghostty args=host\n")))
        (delete-directory stubs t)))))

(ert-deftest drgnx-term-shell/terminfo-entry-resolves ()
  ;; `drgnx build terminfo' compiles Ghostty's entry into <data>/terminfo; the terminal then says TERM=xterm-ghostty
  ;; with TERMINFO there, and xterm-256color while it is missing
  (unless (and (executable-find "tic") (executable-find "infocmp")) (ert-skip "no tic and infocmp here"))
  (let* ((data (make-temp-file "drgnx-term-data" t))
         (process-environment (append (list (concat "DRGNX_DATA_DIR=" data) (concat "HOME=" data)) process-environment))
         (dir (expand-file-name "terminfo" data))
         (env (lambda () (append (drgnx-term--env) nil)))
         (get (lambda (env name) (seq-some (lambda (e) (and (equal (aref e 0) name) (aref e 1))) env))))
    (unwind-protect
        (progn
          (let ((e (funcall env)))
            (should (equal (funcall get e "TERM") "xterm-256color"))
            (should-not (funcall get e "TERMINFO")))
          (should (eql 0 (call-process (expand-file-name "bin/drgnx" drgnx-dir) nil nil nil "build" "terminfo")))
          (should (file-exists-p (expand-file-name "x/xterm-ghostty" dir)))
          (with-temp-buffer
            (should (eql 0 (call-process "infocmp" nil t nil "-x" "-A" dir "xterm-ghostty")))
            (should (string-search "Smulx=" (buffer-string)))
            (should (string-search "colors#" (buffer-string))))
          (let ((e (funcall env)))
            (should (equal (funcall get e "TERM") "xterm-ghostty"))
            (should (equal (funcall get e "TERMINFO") (directory-file-name dir))))
          ;; a second build is quiet and leaves it
          (should (eql 0 (call-process (expand-file-name "bin/drgnx" drgnx-dir) nil nil nil "build" "terminfo")))
          (should (file-exists-p (expand-file-name "x/xterm-ghostty" dir))))
      (delete-directory data t))))

(ert-deftest drgnx-term-shell/environment-names-the-terminal ()
  ;; TERM_PROGRAM, INSIDE_EMACS, DRGNX_TERMINAL, the integration's features and shell, the ssh choice; a Ghostty
  ;; around drgnx leaves none of its own variables
  (let* ((process-environment (append '("GHOSTTY_BIN_DIR=/x" "GHOSTTY_RESOURCES_DIR=/y" "GHOSTTY_SHELL_FEATURES=ssh-env"
                                        "GHOSTTY_SHELL_INTEGRATION_XDG_DIR=/z")
                                      process-environment))
         (get (lambda (name) (seq-some (lambda (e) (and (equal (aref e 0) name) (aref e 1))) (drgnx-term--env)))))
    (should (equal (funcall get "TERM_PROGRAM") "drgnx"))
    (should (equal (funcall get "INSIDE_EMACS") (format "%s,drgnx" emacs-version)))
    (should (equal (funcall get "DRGNX_TERMINAL") "1"))
    (should (equal (funcall get "COLORTERM") "truecolor"))
    (should (equal (funcall get "GHOSTTY_SHELL_FEATURES") "cursor,title,sudo"))
    (should (equal (funcall get "DRGNX_TERMINAL_SSH") "fallback"))
    (dolist (n '("GHOSTTY_BIN_DIR" "GHOSTTY_RESOURCES_DIR" "GHOSTTY_SHELL_INTEGRATION_XDG_DIR" "DRGNX_TERMINAL_SHELL"))
      (should-not (funcall get n)))
    (let ((drgnx-term-shell-integration 'zsh) (drgnx-term-shell-integration-features '("title"))
          (drgnx-term-ssh-terminfo 'install))
      (should (equal (funcall get "DRGNX_TERMINAL_SHELL") "zsh"))
      (should (equal (funcall get "GHOSTTY_SHELL_FEATURES") "title"))
      (should (equal (funcall get "DRGNX_TERMINAL_SSH") "install")))
    (let ((drgnx-term-shell-integration 'none))
      (should-not (funcall get "GHOSTTY_SHELL_FEATURES"))
      (should (equal (funcall get "DRGNX_TERMINAL") "1")))))

(ert-deftest drgnx-term-shell/kitty-cwd-url-moves-the-buffer ()
  ;; Ghostty's bash and zsh report the folder as kitty-shell-cwd://HOST/PATH (the path raw, not URL-encoded)
  (let ((dir (make-temp-file "drgnx term cwd%20" t)))
    (unwind-protect
        (with-temp-buffer
          (drgnx-term--cwd (concat "kitty-shell-cwd://" (system-name) dir))
          (should (equal default-directory (file-name-as-directory dir)))
          (setq default-directory "/")
          (drgnx-term--cwd (concat "kitty-shell-cwd://another-host" dir))
          (should (equal default-directory "/")))
      (delete-directory dir t))))

(ert-deftest drgnx-term-shell/an-open-reuses-its-environment-colours-and-word-table ()
  ;; an open builds the environment, the colours and the word table once and reuses them: the environment again when
  ;; it or a setting changes (`setenv' edits it in place), the colours after a theme change
  (drgnx-test-with-modules '(tools/term)
    (let* ((process-environment (cons "DRGNX_TERM_T=1" process-environment))
           (get (lambda (name) (seq-some (lambda (e) (and (equal (aref e 0) name) (aref e 1))) (drgnx-term--env)))))
      (should (eq (drgnx-term--env) (drgnx-term--env)))
      (should (eq (drgnx-term--colours) (drgnx-term--colours)))
      (with-temp-buffer
        (drgnx-term--set-locals)
        (let ((table (syntax-table)))
          (with-temp-buffer (drgnx-term--set-locals) (should (eq (syntax-table) table)))))
      (setenv "DRGNX_TERM_T" "2")
      (should (equal (funcall get "DRGNX_TERM_T") "2"))
      (let ((drgnx-term-env '("DRGNX_TERM_U=3")))
        (should (equal (funcall get "DRGNX_TERM_U") "3")))
      (should-not (funcall get "DRGNX_TERM_U"))
      (let ((colours (drgnx-term--colours)))
        (drgnx-term--theme-changed)
        (should-not (eq colours (drgnx-term--colours)))))))

(provide 'term-shell-test)
;;; term-shell-test.el ends here
