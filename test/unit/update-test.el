;;; update-test.el --- batch tests: drgnx update (bin/drgnx updates its own checkout) -*- lexical-binding: t -*-
;; A temp "origin" (bare), a seed clone that pushes to it and an install clone (holding a copy of bin/drgnx) are built per
;; test; sync and build are stubbed through DRGNX_UPDATE_SYNC_CMD / DRGNX_UPDATE_BUILD_CMD; systemctl and launchctl are
;; stubs on PATH that log their arguments.  Nothing here touches the real HOME, XDG directories, systemd, launchd, the
;; network or the real install.
(require 'ert)

(defconst drgnx-update-test--root
  (expand-file-name "../../" (file-name-directory (or load-file-name buffer-file-name))))

(defun drgnx-update-test--env (dir &rest extra)
  "The environment of a run in DIR: its own HOME, XDG directories, PATH (stubs first) and git identity, plus EXTRA."
  (append extra
          (list (concat "HOME=" dir) (concat "XDG_STATE_HOME=" dir "/state") (concat "XDG_CONFIG_HOME=" dir "/config")
                (concat "PATH=" dir "/stubs:/usr/bin:/bin") "GIT_CONFIG_GLOBAL=/dev/null" "GIT_CONFIG_NOSYSTEM=1"
                "GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@example.org" "GIT_COMMITTER_NAME=t" "GIT_COMMITTER_EMAIL=t@example.org"
                (concat "DRGNX_UPDATE_SYNC_CMD=echo sync $* >> " dir "/hooks.log")
                (concat "DRGNX_UPDATE_BUILD_CMD=echo build $* >> " dir "/hooks.log"))))

(defun drgnx-update-test--run (dir extra-env program &rest args)
  "Run PROGRAM with ARGS in DIR's environment (plus EXTRA-ENV); return (EXIT . OUTPUT), stderr included."
  (let ((process-environment (append (apply #'drgnx-update-test--env dir extra-env)
                                     (list "DRGNX_EMACS" "DRGNX_UPDATE_PLATFORM") process-environment))
        (default-directory (file-name-as-directory dir)))
    (with-temp-buffer
      (cons (apply #'call-process program nil t nil args) (buffer-string)))))

(defun drgnx-update-test--git (dir repo &rest args)
  "git ARGS in DIR/REPO; the trimmed output (an error if git fails)."
  (let ((r (apply #'drgnx-update-test--run dir nil "git" "-C" (expand-file-name repo dir) args)))
    (unless (eq (car r) 0) (error "git %S failed: %s" args (cdr r)))
    (string-trim (cdr r))))

(defun drgnx-update-test--write (file text)
  (make-directory (file-name-directory file) t)
  (write-region text nil file))

(defun drgnx-update-test--slurp (file)
  (if (file-exists-p file) (with-temp-buffer (insert-file-contents file) (buffer-string)) ""))

(defun drgnx-update-test--push (dir name text msg)
  "Commit file NAME with TEXT in the seed clone and push it to origin's main."
  (drgnx-update-test--write (expand-file-name name (expand-file-name "seed" dir)) text)
  (drgnx-update-test--git dir "seed" "add" "-A")
  (drgnx-update-test--git dir "seed" "commit" "-q" "-m" msg)
  (drgnx-update-test--git dir "seed" "push" "-q" "origin" "main"))

(defmacro drgnx-update-test--with-install (&rest body)
  "Run BODY with DIR (a temp directory, deleted afterwards) holding origin.git, seed/ and install/ (a clone with
bin/drgnx), the stubs, and BIN (the install's bin/drgnx).  Origin and the install are at the same commit."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "drgnx-update-test" t))
          (bin (expand-file-name "install/bin/drgnx" dir))
          (state (expand-file-name "state/drgnx/update" dir)))
     (ignore bin state)
     (unwind-protect
         (progn
           (make-directory (expand-file-name "stubs" dir))
           (dolist (tool '("systemctl" "launchctl"))
             (let ((f (expand-file-name tool (expand-file-name "stubs" dir))))
               (write-region (format "#!/bin/sh\necho \"$*\" >> '%s/%s.log'\ncase \"$*\" in *is-enabled*) echo enabled;; esac\n" dir tool)
                             nil f)
               (set-file-modes f #o755)))
           (drgnx-update-test--git dir "." "init" "-q" "--bare" "-b" "main" "origin.git")
           (drgnx-update-test--git dir "." "init" "-q" "-b" "main" "seed")
           (drgnx-update-test--git dir "seed" "remote" "add" "origin" (expand-file-name "origin.git" dir))
           (make-directory (expand-file-name "seed/bin" dir))
           (copy-file (expand-file-name "bin/drgnx" drgnx-update-test--root) (expand-file-name "seed/bin/drgnx" dir))
           (set-file-modes (expand-file-name "seed/bin/drgnx" dir) #o755)
           (copy-file (expand-file-name "bin/drgnx-paths.sh" drgnx-update-test--root) (expand-file-name "seed/bin/" dir))
           (drgnx-update-test--push dir "README" "one\n" "first")
           (drgnx-update-test--git dir "." "clone" "-q" (expand-file-name "origin.git" dir) "install")
           ,@body)
       (delete-directory dir t))))

(defun drgnx-update-test--head (dir)
  (drgnx-update-test--git dir "install" "rev-parse" "HEAD"))

(defun drgnx-update-test--hooks (dir)
  (drgnx-update-test--slurp (expand-file-name "hooks.log" dir)))

(ert-deftest drgnx-update/current-is-a-no-op ()
  (drgnx-update-test--with-install
    (let ((head (drgnx-update-test--head dir))
          (r (drgnx-update-test--run dir nil bin "update")))
      (should (eq (car r) 0))
      (should (string-match-p "already up to date" (cdr r)))
      (should (equal head (drgnx-update-test--head dir)))
      (should (string-empty-p (drgnx-update-test--hooks dir)))
      (should (string-match-p "already current" (drgnx-update-test--slurp (expand-file-name "last-run" state))))
      (should-not (file-exists-p (expand-file-name "previous" state)))
      ;; quiet: nothing at all
      (should (equal '(0 . "") (drgnx-update-test--run dir nil bin "update" "--quiet"))))))

(ert-deftest drgnx-update/a-new-commit-is-fast-forwarded-and-the-previous-one-recorded ()
  (drgnx-update-test--with-install
    (let ((old (drgnx-update-test--head dir)))
      (drgnx-update-test--push dir "README" "two\n" "second change")
      (let ((r (drgnx-update-test--run dir nil bin "update"))
            (new (drgnx-update-test--git dir "seed" "rev-parse" "HEAD")))
        (should (eq (car r) 0))
        (should (equal new (drgnx-update-test--head dir)))
        (should (equal old (string-trim (drgnx-update-test--slurp (expand-file-name "previous" state)))))
        (should (equal "sync\nbuild\n" (drgnx-update-test--hooks dir)))
        (should (string-match-p (regexp-quote (format "%s..%s" (substring old 0 7) (substring new 0 7))) (cdr r)))
        (should (string-match-p "second change" (cdr r)))
        (should (string-match-p "Restart drgnx" (cdr r)))
        (should (string-match-p "updated" (drgnx-update-test--slurp (expand-file-name "last-run" state))))))))

(ert-deftest drgnx-update/quiet-says-one-line-on-an-update ()
  (drgnx-update-test--with-install
    (drgnx-update-test--push dir "README" "two\n" "second")
    (let ((r (drgnx-update-test--run dir nil bin "update" "--quiet")))
      (should (eq (car r) 0))
      (should (= 1 (length (split-string (string-trim (cdr r)) "\n"))))
      (should (string-match-p "updated" (cdr r)))
      (should (string-match-p "auto" (drgnx-update-test--slurp (expand-file-name "last-run" state)))))))

(ert-deftest drgnx-update/a-dirty-checkout-is-refused-unchanged ()
  (drgnx-update-test--with-install
    (drgnx-update-test--push dir "README" "two\n" "second")
    (let ((head (drgnx-update-test--head dir))
          (readme (expand-file-name "install/README" dir)))
      (write-region "mine\n" nil readme)
      (let ((r (drgnx-update-test--run dir nil bin "update")))
        (should (eq (car r) 1))
        (should (string-match-p "local changes" (cdr r)))
        (should (string-match-p "Nothing changed" (cdr r)))
        (should (equal head (drgnx-update-test--head dir)))
        (should (equal "mine\n" (drgnx-update-test--slurp readme)))
        (should (string-empty-p (drgnx-update-test--hooks dir)))))))

(ert-deftest drgnx-update/another-branch-or-no-checkout-is-refused ()
  (drgnx-update-test--with-install
    (drgnx-update-test--git dir "install" "switch" "-q" "-c" "side")
    (let ((r (drgnx-update-test--run dir nil bin "update")))
      (should (eq (car r) 1))
      (should (string-match-p "not main" (cdr r)))))
  (drgnx-update-test--with-install
    ;; a copy of the install without .git is not a checkout
    (let ((plain (expand-file-name "plain" dir)))
      (make-directory (expand-file-name "bin" plain) t)
      (copy-file bin (expand-file-name "bin/drgnx" plain))
      (set-file-modes (expand-file-name "bin/drgnx" plain) #o755)
      (copy-file (expand-file-name "bin/drgnx-paths.sh" drgnx-update-test--root) (expand-file-name "bin/" plain))
      (let ((r (drgnx-update-test--run dir nil (expand-file-name "bin/drgnx" plain) "update")))
        (should (eq (car r) 1))
        (should (string-match-p "not a git checkout" (cdr r)))))))

(ert-deftest drgnx-update/a-diverged-checkout-is-refused ()
  (drgnx-update-test--with-install
    (drgnx-update-test--write (expand-file-name "install/local" dir) "x\n")
    (drgnx-update-test--git dir "install" "add" "local")
    (drgnx-update-test--git dir "install" "commit" "-q" "-m" "local only")
    (drgnx-update-test--push dir "README" "two\n" "second")
    (let* ((head (drgnx-update-test--head dir))
           (r (drgnx-update-test--run dir nil bin "update")))
      (should (eq (car r) 1))
      (should (string-match-p "diverged" (cdr r)))
      (should (string-match-p "reset --hard origin/main" (cdr r)))
      (should (equal head (drgnx-update-test--head dir)))
      (should (string-empty-p (drgnx-update-test--hooks dir))))))

(defun drgnx-update-test--fail-once (dir step)
  "The hook for STEP (\"SYNC\" or \"BUILD\") that fails its first call and logs the later ones."
  (format "DRGNX_UPDATE_%s_CMD=if [ ! -e %s/%s.flag ]; then touch %s/%s.flag; exit 3; fi; echo %s $* >> %s/hooks.log"
          step dir step dir step (downcase step) dir))

(ert-deftest drgnx-update/a-failing-sync-or-build-moves-the-checkout-back-and-resyncs ()
  (dolist (step '("SYNC" "BUILD"))
    (drgnx-update-test--with-install
      (let ((old (drgnx-update-test--head dir)))
        (drgnx-update-test--push dir "README" "two\n" "second")
        (let ((r (drgnx-update-test--run dir (list (drgnx-update-test--fail-once dir step)) bin "update")))
          (should (eq (car r) 1))
          (should (string-match-p "moved the checkout back" (cdr r)))
          (should (string-match-p "re-synced" (cdr r)))
          (should (string-match-p (if (equal step "SYNC") "sync failed" "build failed") (cdr r)))
          (should (equal old (drgnx-update-test--head dir)))
          (should-not (file-exists-p (expand-file-name "previous" state)))
          (should (equal "one\n" (drgnx-update-test--slurp (expand-file-name "install/README" dir))))
          ;; the old commit's packages come back (offline first), then its build
          (should (equal (if (equal step "SYNC") "sync --offline\nbuild\n" "sync\nsync --offline\nbuild\n")
                         (drgnx-update-test--hooks dir)))
          (should (file-exists-p (expand-file-name "last.log" state))))
        ;; the timer does not retry the commit that failed; a manual update does
        (should (equal '(0 . "") (drgnx-update-test--run dir nil bin "update" "--quiet")))
        (should (equal old (drgnx-update-test--head dir)))
        (should (eq 0 (car (drgnx-update-test--run dir nil bin "update"))))
        (should-not (equal old (drgnx-update-test--head dir)))))))

(ert-deftest drgnx-update/a-failed-resync-is-said-plainly ()
  (drgnx-update-test--with-install
    (let ((old (drgnx-update-test--head dir)))
      (drgnx-update-test--push dir "README" "two\n" "second")
      (let ((r (drgnx-update-test--run dir '("DRGNX_UPDATE_SYNC_CMD=exit 3") bin "update")))
        (should (eq (car r) 1))
        (should (equal old (drgnx-update-test--head dir)))
        (should (string-match-p "may be newer than this commit" (cdr r)))))))

(ert-deftest drgnx-update/an-interrupted-update-is-rolled-back ()
  (drgnx-update-test--with-install
    (let ((old (drgnx-update-test--head dir)))
      (drgnx-update-test--push dir "README" "two\n" "second")
      ;; the first sync terminates the update script itself (its pid is in the lock) while it runs
      (let ((r (drgnx-update-test--run
                dir (list (format "DRGNX_UPDATE_SYNC_CMD=if [ ! -e %s/k.flag ]; then touch %s/k.flag; kill -TERM $(cat %s/lock/pid); sleep 1; fi; echo sync $* >> %s/hooks.log"
                                  dir dir state dir))
                bin "update")))
        (should (eq (car r) 143))
        (should (equal old (drgnx-update-test--head dir)))
        (should (string-match-p "interrupted" (cdr r)))
        (should (equal "sync\nsync --offline\nbuild\n" (drgnx-update-test--hooks dir)))
        (should-not (file-exists-p (expand-file-name "lock" state)))
        (should-not (file-exists-p (expand-file-name "previous" state)))
        (should (string-match-p "interrupted" (drgnx-update-test--slurp (expand-file-name "last-run" state))))))))

(ert-deftest drgnx-update/an-unreachable-origin-fails-without-changes ()
  (drgnx-update-test--with-install
    (let ((head (drgnx-update-test--head dir)))
      (drgnx-update-test--git dir "install" "remote" "set-url" "origin" (expand-file-name "nowhere.git" dir))
      (let ((r (drgnx-update-test--run dir nil bin "update")))
        (should (eq (car r) 1))
        (should (string-match-p "could not fetch" (cdr r)))
        (should (equal head (drgnx-update-test--head dir)))
        (should (string-empty-p (drgnx-update-test--hooks dir)))
        (should (string-match-p "failed" (drgnx-update-test--slurp (expand-file-name "last-run" state))))))))

(ert-deftest drgnx-update/the-lock-refuses-a-live-owner-and-replaces-a-dead-one ()
  (drgnx-update-test--with-install
    (make-directory (expand-file-name "lock" state) t)
    (write-region (format "%d\n" (emacs-pid)) nil (expand-file-name "lock/pid" state))
    (let ((r (drgnx-update-test--run dir nil bin "update")))
      (should (eq (car r) 1))
      (should (string-match-p "another update is running" (cdr r))))
    (should (file-exists-p (expand-file-name "lock/pid" state)))   ; the live owner's lock stays
    (write-region "99999999\n" nil (expand-file-name "lock/pid" state))
    (should (eq 0 (car (drgnx-update-test--run dir nil bin "update"))))
    (should-not (file-exists-p (expand-file-name "lock" state)))))

(ert-deftest drgnx-update/back-returns-to-the-commit-before-the-update ()
  (drgnx-update-test--with-install
    (let ((old (drgnx-update-test--head dir)))
      (should (eq 1 (car (drgnx-update-test--run dir nil bin "update" "--back"))))   ; nothing to go back to yet
      (drgnx-update-test--push dir "README" "two\n" "second")
      (drgnx-update-test--run dir nil bin "update")
      (write-region "" nil (expand-file-name "hooks.log" dir))
      (let ((r (drgnx-update-test--run dir nil bin "update" "--back")))
        (should (eq (car r) 0))
        (should (equal old (drgnx-update-test--head dir)))
        (should (equal "sync\nbuild\n" (drgnx-update-test--hooks dir)))
        (should (string-match-p "went back" (cdr r))))
      ;; the timer leaves the commit you went back from alone
      (should (equal '(0 . "") (drgnx-update-test--run dir nil bin "update" "--quiet")))
      (should (equal old (drgnx-update-test--head dir)))
      ;; a dirty checkout is refused here too
      (write-region "mine\n" nil (expand-file-name "install/README" dir))
      (should (eq 1 (car (drgnx-update-test--run dir nil bin "update" "--back")))))))

(ert-deftest drgnx-update/back-refuses-a-commit-unrelated-to-this-checkout ()
  (drgnx-update-test--with-install
    (let ((head (drgnx-update-test--head dir))
          (stray (drgnx-update-test--git dir "install" "commit-tree" "-m" "stray" "4b825dc642cb6eb9a060e54bf8d69288fbee4904")))
      (make-directory state t)
      (write-region (concat stray "\n") nil (expand-file-name "previous" state))
      (let ((r (drgnx-update-test--run dir nil bin "update" "--back")))
        (should (eq (car r) 1))
        (should (string-match-p "Nothing changed" (cdr r)))
        (should (equal head (drgnx-update-test--head dir)))
        (should (string-empty-p (drgnx-update-test--hooks dir)))))))

(ert-deftest drgnx-update/auto-on-writes-a-systemd-timer-and-off-removes-it ()
  (drgnx-update-test--with-install
    (let* ((units (expand-file-name "config/systemd/user" dir))
           (timer (expand-file-name "drgnx-update.timer" units))
           (service (expand-file-name "drgnx-update.service" units))
           (ctl (expand-file-name "systemctl.log" dir))
           (env '("DRGNX_UPDATE_PLATFORM=Linux")))   ; every call: a macOS host would ask launchd
      (should (string-match-p "off" (cdr (drgnx-update-test--run dir env bin "update" "--auto" "status"))))
      (should (eq 0 (car (drgnx-update-test--run dir env bin "update" "--auto" "on"))))
      (let ((timer-text (drgnx-update-test--slurp timer))
            (service-text (drgnx-update-test--slurp service)))
        (should (string-match-p "^OnCalendar=daily$" timer-text))
        (should (string-match-p "^RandomizedDelaySec=" timer-text))
        (should (string-match-p "^Persistent=true$" timer-text))
        (should (string-match-p "^WantedBy=timers.target$" timer-text))
        (should (string-match-p "^Type=oneshot$" service-text))
        (should (string-match-p "^Nice=" service-text))
        (should (string-match-p "^TimeoutStartSec=" service-text))
        (should (string-match-p "^TimeoutStopSec=30min$" service-text))
        ;; the PATH names the real home (no specifier left as text), and the state directory the timer shares with you
        (should (string-match-p (format "^Environment=\"PATH=%s/.local/bin:" (regexp-quote dir)) service-text))
        (should-not (string-match-p "%" service-text))
        (should (string-match-p (format "^Environment=\"XDG_STATE_HOME=%s/state\"$" (regexp-quote dir)) service-text))
        ;; …and the config dir: XDG_CONFIG_HOME counts for it
        (should (string-match-p (format "^Environment=\"XDG_CONFIG_HOME=%s/config\"$" (regexp-quote dir)) service-text))
        (should (string-match-p (format "^ExecStart=\"%s\" update --quiet$" (regexp-quote bin)) service-text)))
      (should (string-match-p "--user enable --now drgnx-update.timer" (drgnx-update-test--slurp ctl)))
      (drgnx-update-test--run dir env bin "update")    ; a run to report
      (let ((status (cdr (drgnx-update-test--run dir env bin "update" "--auto" "status"))))
        (should (string-match-p "automatic updates: on" status))
        (should (string-match-p "last run: .*already current" status)))
      (should (eq 0 (car (drgnx-update-test--run dir env bin "update" "--auto" "off"))))
      (should-not (file-exists-p timer))
      (should-not (file-exists-p service))
      (should (string-match-p "--user disable --now drgnx-update.timer" (drgnx-update-test--slurp ctl)))
      (should (string-match-p "automatic updates: off" (cdr (drgnx-update-test--run dir env bin "update" "--auto" "status"))))
      ;; nothing leaked outside the temp config directory
      (should-not (file-exists-p (expand-file-name ".config" dir))))))

(ert-deftest drgnx-update/auto-on-writes-a-launchd-agent-on-macos ()
  (drgnx-update-test--with-install
    (let* ((plist (expand-file-name "Library/LaunchAgents/org.blackdragonfoundation.drgnx-update.plist" dir))
           (ctl (expand-file-name "launchctl.log" dir))
           (env '("DRGNX_UPDATE_PLATFORM=Darwin")))
      (should (eq 0 (car (drgnx-update-test--run dir env bin "update" "--auto" "on"))))
      (let ((text (drgnx-update-test--slurp plist)))
        (should (string-match-p (format "<string>%s</string>" (regexp-quote bin)) text))
        (should (string-match-p "<string>update</string>\\s-*<string>--quiet</string>" text))
        (should (string-match-p "<key>StartCalendarInterval</key>" text))
        (should (string-match-p "<key>ExitTimeOut</key><integer>1800</integer>" text))
        (should (string-match-p "<key>Hour</key><integer>[0-9]+</integer>" text)))
      (should (string-match-p "bootstrap gui/[0-9]+ " (drgnx-update-test--slurp ctl)))
      (should (string-match-p "automatic updates: on" (cdr (drgnx-update-test--run dir env bin "update" "--auto" "status"))))
      (should (eq 0 (car (drgnx-update-test--run dir env bin "update" "--auto" "off"))))
      (should-not (file-exists-p plist))
      (should (string-match-p "bootout" (drgnx-update-test--slurp ctl))))))

(ert-deftest drgnx-update/bad-arguments-are-a-usage-error-and-the-usage-lists-update ()
  (drgnx-update-test--with-install
    (should (eq 2 (car (drgnx-update-test--run dir nil bin "update" "--auto" "sideways"))))
    (should (eq 2 (car (drgnx-update-test--run dir nil bin "update" "--nope"))))
    (let ((help (cdr (drgnx-update-test--run dir nil bin "help"))))
      (dolist (s '("drgnx update" "update --back" "update --auto on|off|status"))
        (should (string-search s help))))))

;;; update-test.el ends here
