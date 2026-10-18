;;; drgnx-ui-test.el --- batch tests: harness session controller -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-ui)
(require 'drgnx-uitest)
(require 'drgnx-check)

(defmacro drgnx-ui-test--with-state (&rest body)
  "Run BODY with `root' bound to a fresh DRGNX_UI_STATE directory.  No systemd unit counts as active:
the real ones belong to sessions running next to the tests (bin/drgnx check's live shards)."
  (declare (indent 0))
  `(let* ((root (make-temp-file "drgnx-ui-state" t))
          ;; a short base, as a real runtime dir is: macOS's temp dir is too long for a socket under it
          (runtime (make-temp-file "/tmp/drgnx-xdg" t))
          (process-environment (append (list (concat "DRGNX_UI_STATE=" root)
                                             (concat "XDG_RUNTIME_DIR=" runtime))
                                       process-environment)))
     (set-file-modes runtime #o700)
     (unwind-protect
         (cl-letf (((symbol-function 'drgnx-ui-unit-active-p) #'ignore)) ,@body)
       (delete-directory runtime t)
       (delete-directory root t))))

(defun drgnx-ui-test--slurp (file)
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(ert-deftest drgnx-ui/prepare-minimal-layout ()
  (drgnx-ui-test--with-state
    (let* ((s (drgnx-ui-prepare-run "drgnx-ui-1" nil "1600x900" root))
           (run (plist-get s :run)))
      (should (equal (file-name-nondirectory (plist-get s :socket)) "drgnx-ui-1"))
      (should (= (file-modes (file-name-directory (plist-get s :socket))) #o700))
      (should (string-search "prelude.el" (drgnx-ui-test--slurp (expand-file-name "init/early-init.el" run))))
      (should (string-search "drgnx-ui-load-config" (drgnx-ui-test--slurp (expand-file-name "init/init.el" run))))
      (should (equal (plist-get s :config) "minimal"))
      (should (equal (plist-get s :config_dir) ""))
      (should (file-exists-p (expand-file-name "session.json" run))))))

(ert-deftest drgnx-ui/socket-path-is-short-whatever-the-state-root ()
  (drgnx-ui-test--with-state
    (let* ((deep (expand-file-name (make-string 150 ?d) root))
           (process-environment (cons (concat "DRGNX_UI_STATE=" deep) process-environment))
           (s (drgnx-ui-prepare-run "drgnx-ui-1")))
      (should (< (length (plist-get s :socket)) 100))
      (should-not (string-prefix-p deep (plist-get s :socket)))
      (should (member (concat "DRGNX_UI_SOCKET_DIR=" (directory-file-name (file-name-directory (plist-get s :socket))))
                      (drgnx-ui-session-env s)))
      (drgnx-ui-stop "drgnx-ui-1")
      (should-not (file-exists-p (file-name-directory (plist-get s :socket))))
      (should-not (file-exists-p (drgnx-ui-socket-dir "" deep))))))   ; the per-root dir, once empty

(ert-deftest drgnx-ui/socket-dirs-differ-between-state-roots ()
  (drgnx-ui-test--with-state
    (let* ((a (drgnx-ui-prepare-run "drgnx-ui-1" nil nil (expand-file-name "a" root)))
           (b (drgnx-ui-prepare-run "drgnx-ui-1" nil nil (expand-file-name "b" root))))
      (should-not (equal (plist-get a :socket) (plist-get b :socket)))
      (dolist (s (list a b)) (delete-directory (file-name-directory (plist-get s :socket)) t)))))

(ert-deftest drgnx-ui/prepare-external-config-links-code-copies-custom-skips-state ()
  (drgnx-ui-test--with-state
    (let ((cfg (expand-file-name "cfg" root)))
      (dolist (d '("lisp" "extras" "elpa")) (make-directory (expand-file-name d cfg) t))
      (dolist (f '("init.el" "custom.el" "history")) (write-region ";;\n" nil (expand-file-name f cfg)))
      (let* ((s (drgnx-ui-prepare-run "drgnx-ui-2" cfg "800x600" root))
             (init (expand-file-name "init" (plist-get s :run))))
        (should (file-symlink-p (expand-file-name "lisp" init)))
        (should (file-symlink-p (expand-file-name "extras" init)))
        (should (file-regular-p (expand-file-name "custom.el" init)))
        (should-not (file-symlink-p (expand-file-name "custom.el" init)))
        (should-not (file-exists-p (expand-file-name "history" init)))
        (should-not (file-exists-p (expand-file-name "elpa" init)))
        (should (equal (plist-get s :config_dir) (file-truename cfg)))))))

(ert-deftest drgnx-ui/prepare-never-reuses-a-run-dir ()
  (drgnx-ui-test--with-state
    (drgnx-ui-prepare-run "drgnx-ui-1" nil "1600x900" root)
    (should-error (drgnx-ui-prepare-run "drgnx-ui-1" nil "1600x900" root))))

(ert-deftest drgnx-ui/prepare-rejects-bad-size-and-config ()
  (drgnx-ui-test--with-state
    (should-error (drgnx-ui-prepare-run "drgnx-ui-3" nil "big" root) :type 'drgnx-ui-error)
    (should-error (drgnx-ui-prepare-run "drgnx-ui-4" (expand-file-name "nope" root) "1600x900" root)
                  :type 'drgnx-ui-error)))

(ert-deftest drgnx-ui/env-is-allowlisted ()
  (drgnx-ui-test--with-state
    (let* ((process-environment (cons "DRGNX_FAKE_API_KEY=x" process-environment))
           (s (drgnx-ui-prepare-run "drgnx-ui-5" nil "1600x900" root))
           (env (drgnx-ui-session-env s)))
      (should-not (seq-find (lambda (kv) (string-prefix-p "DRGNX_FAKE_API_KEY=" kv)) env))
      (should (member "DRGNX_UI_NAME=drgnx-ui-5" env))
      (should (member "DRGNX_NO_LANGUAGE_SERVERS=1" env))      ; no pyright per fixture project (a test opts in)
      (should (member (concat "EMACS_SOCKET_NAME=" (plist-get s :socket)) env))
      (should (equal (drgnx-ui-env-argv '("A=1")) '("env" "-i" "A=1"))))))

(ert-deftest drgnx-ui/compositor-argv ()
  (drgnx-ui-test--with-state
    (let* ((s (drgnx-ui-prepare-run "drgnx-ui-6" nil "1024x768" root))
           (argv (drgnx-ui-compositor-argv s)))
      (should (equal (seq-take argv 3) '("dbus-run-session" "--" "mutter")))
      (dolist (flag '("--headless" "--wayland" "--no-x11")) (should (member flag argv)))
      (should (equal (cadr (member "--virtual-monitor" argv)) "1024x768"))
      (should (equal (cadr (member "--wayland-display" argv)) "drgnx-ui-6"))
      (should-not (member "-Q" argv))
      (should (equal (cadr (member "--init-directory" argv))
                     (expand-file-name "init" (plist-get s :run)))))))

(ert-deftest drgnx-ui/launch-argv ()
  (drgnx-ui-test--with-state
    (let* ((s (drgnx-ui-prepare-run "drgnx-ui-1" nil "1600x900" root))
           (argv (drgnx-ui-launch-argv s)))
      (should (equal (seq-take argv 6) '("systemd-run" "--user" "--quiet" "--collect" "--unit" "drgnx-ui-1")))
      (should (member "RuntimeMaxSec=1800" argv))
      (should (member "MemoryMax=3G" argv))
      ;; CHK-2: a stop returns within the check's 15 s grace (systemd's default is 90 s before it kills what is left)
      (should (member "TimeoutStopSec=10" argv))
      (should (equal (seq-take (cdr (member "--" argv)) 2) '("env" "-i"))))))

(ert-deftest drgnx-ui/el-quoting-roundtrip ()
  (let ((s "he said \"hi\"\\ \n✓ \t"))
    (should (equal (car (read-from-string (drgnx-ui-el s))) s)))
  (should (equal (list (drgnx-ui-el nil) (drgnx-ui-el t) (drgnx-ui-el 3)) '("nil" "t" "3"))))

(ert-deftest drgnx-ui/parse-reply-handles-elisp-string-printing ()
  (let ((printed (prin1-to-string (drgnx-uitest--json (list :t "a\"b\nc ✓")))))
    (should (equal (drgnx-ui-parse-reply printed) '(:t "a\"b\nc ✓")))))

(ert-deftest drgnx-ui/next-name-skips-stale-dirs ()
  (drgnx-ui-test--with-state
    (make-directory (expand-file-name "drgnx-ui-1" root))
    (should (equal (drgnx-ui-next-name root) "drgnx-ui-2"))))

(ert-deftest drgnx-ui/reap-removes-stale-dirs ()
  (drgnx-ui-test--with-state
    (drgnx-ui-prepare-run "drgnx-ui-7" nil "1600x900")
    (should (member "drgnx-ui-7" (append (drgnx-ui-reap) nil)))
    (should-not (file-exists-p (expand-file-name "drgnx-ui-7" root)))))

(ert-deftest drgnx-ui/reap-removes-old-kept-test-runs ()
  ;; DEFERRED M2-5: a failed --ui/--scenario run keeps its run dir for debugging, but not for ever
  (drgnx-ui-test--with-state
    (let ((old (expand-file-name "drgnx-ui-test-111-222" root))
          (new (expand-file-name "drgnx-ui-test-333-444" root))
          (other (expand-file-name "drgnx-ui-test-notes" root)))
      (dolist (d (list old new other)) (make-directory d))
      (write-region "log" nil (expand-file-name "session.log" old))
      (dolist (d (list old other))
        (set-file-times d (time-subtract nil (* 86400 (1+ drgnx-ui-test-run-max-days)))))
      (cl-letf (((symbol-function 'drgnx-ui--run) (lambda (&rest _) (cons 0 ""))))
        (drgnx-ui-reap))
      (should-not (file-exists-p old))
      (should (file-directory-p new))
      (should (file-directory-p other)))))

(ert-deftest drgnx-ui/the-shared-eln-cache-is-pruned ()
  ;; DEFERRED M8-4: the sessions' shared eln cache (ROOT/eln-cache) keeps only what was used lately; the
  ;; cache of an Emacs no longer run goes with its last file
  (drgnx-ui-test--with-state
    (let* ((cache (expand-file-name "eln-cache" root))
           (old (time-subtract nil (* 86400 (1+ drgnx-ui-eln-max-days))))
           (file (lambda (rel &optional time)
                   (let ((f (expand-file-name rel cache)))
                     (make-directory (file-name-directory f) t)
                     (write-region "" nil f)
                     (when time (set-file-times f time))
                     f))))
      (let ((stale (funcall file "30.2-aaaa/subr--trampoline-x.eln" old))
            (used (funcall file "30.2-aaaa/subr--trampoline-y.eln"))
            (preloaded (funcall file "30.2-aaaa/preloaded/z.eln" old))
            (gone (funcall file "29.4-bbbb/w.eln" old))
            (other (funcall file "30.2-aaaa/notes.txt" old)))
        (cl-letf (((symbol-function 'drgnx-ui--run) (lambda (&rest _) (cons 0 ""))))
          (drgnx-ui-reap))
        (should-not (file-exists-p stale))
        (should-not (file-exists-p preloaded))
        (should (file-exists-p used))
        (should (file-exists-p other))
        (should-not (file-exists-p (file-name-directory preloaded)))
        (should-not (file-exists-p (file-name-directory gone)))
        (should (file-directory-p cache))))))

(ert-deftest drgnx-ui/reap-leaves-other-state-roots-alone ()
  (drgnx-ui-test--with-state
    (let ((units "drgnx-ui-41.service loaded active running x\ndrgnx-ui-42.service loaded active running y\n")
          (cmdlines `(("drgnx-ui-41" . ,(format "argv[]=env DRGNX_UI_RUN=%s/drgnx-ui-41 ..." root))
                      ("drgnx-ui-42" . "argv[]=env DRGNX_UI_RUN=/elsewhere/drgnx-ui-42 ..."))))
      (should (equal (drgnx-ui-reap-targets root units (lambda (n) (alist-get n cmdlines nil nil #'equal)))
                     '("drgnx-ui-41"))))))

(ert-deftest drgnx-ui/foreign-sessions-refused ()
  (drgnx-ui-test--with-state
    (dolist (name '("server" "../drgnx-ui-1" "/run/user/1000/emacs/server" "drgnx-ui-1x" "drgnx-ui-9" 7))
      (should-error (drgnx-ui-own-session name) :type 'drgnx-ui-refused))))

(ert-deftest drgnx-ui/own-session-needs-its-socket ()
  (drgnx-ui-test--with-state
    (let ((s (drgnx-ui-prepare-run "drgnx-ui-3" nil "1600x900")))
      (should-error (drgnx-ui-own-session "drgnx-ui-3") :type 'drgnx-ui-refused)
      (let ((server (make-network-process :name "drgnx-ui-test-sock" :family 'local :server t
                                          :service (plist-get s :socket) :noquery t)))
        (unwind-protect
            (should (equal (plist-get (drgnx-ui-own-session "drgnx-ui-3") :name) "drgnx-ui-3"))
          (delete-process server))))))

(ert-deftest drgnx-ui/composite-argv ()
  (should (equal (drgnx-ui-composite-argv '(:root "/r.png" :children [(:path "/c0.png" :x 307 :y 338)]) "/o.png")
                 '("magick" "/r.png" "/c0.png" "-geometry" "+307+338" "-composite" "/o.png"))))

(ert-deftest drgnx-ui/act-rejects-unknown-actions ()
  (should-error (drgnx-ui-act '(:socket "/nonexistent") '(:fly 1)) :type 'drgnx-ui-error))

(ert-deftest drgnx-ui/cli-args ()
  (should (equal (drgnx-ui--parse-args '("drgnx-ui-1" "--buffer" "*scratch*" "--hold-ms" "300"))
                 '(("drgnx-ui-1") :buffer "*scratch*" :hold_ms "300"))))

(ert-deftest drgnx-ui/cli-click-needs-pixel-coordinates ()
  ;; DEFERRED M1-3: a missing or non-numeric X/Y used to click at (0,0)
  (should (equal (drgnx-ui--click-action '("drgnx-ui-1" "10" "20") '(:count "2")) '(:x 10 :y 20 :count 2)))
  (dolist (pos '(("drgnx-ui-1") ("drgnx-ui-1" "10") ("drgnx-ui-1" "a" "3") ("drgnx-ui-1" "-1" "3")
                 ("drgnx-ui-1" "1.5" "3") ("drgnx-ui-1" "10" "20px")))
    (should-error (drgnx-ui--click-action pos nil) :type 'drgnx-ui-error)))

(ert-deftest drgnx-ui/launcher-choice ()
  (should (equal (drgnx-ui--choose-launcher nil t nil) "systemd"))
  (should (equal (drgnx-ui--choose-launcher "podman" t nil) "detached"))
  (should (equal (drgnx-ui--choose-launcher nil nil nil) "detached"))
  (should (equal (drgnx-ui--choose-launcher "docker" nil "systemd") "systemd"))
  (should (equal (drgnx-ui--choose-launcher nil t "detached") "detached")))

(ert-deftest drgnx-ui/runtime-dir-fallback-without-xdg ()
  (drgnx-ui-test--with-state
    (let* ((process-environment (cons "XDG_RUNTIME_DIR" process-environment))   ; unset
           (s (drgnx-ui-prepare-run "drgnx-ui-1")))
      (should (equal (drgnx-ui-runtime-dir)
                     (expand-file-name (format "drgnx-ui-%d" (user-uid)) temporary-file-directory)))
      (should (= (file-modes (drgnx-ui-runtime-dir)) #o700))
      (should (member (concat "XDG_RUNTIME_DIR=" (drgnx-ui-runtime-dir)) (drgnx-ui-session-env s)))
      (drgnx-ui-stop "drgnx-ui-1"))))

(ert-deftest drgnx-ui/runtime-dir-fallback-must-be-private ()
  ;; DEFERRED M1-8: an existing /tmp/drgnx-ui-UID is used only if it is our own directory, mode 0700 —
  ;; not one another user made (or left open), nor a symlink to elsewhere
  (let* ((tmp (make-temp-file "drgnx-ui-tmp" t))
         (temporary-file-directory (file-name-as-directory tmp))
         (dir (expand-file-name (format "drgnx-ui-%d" (user-uid)) tmp))
         (process-environment (cons "XDG_RUNTIME_DIR" process-environment)))   ; unset
    (unwind-protect
        (progn
          (should (equal (drgnx-ui-runtime-dir) dir))                       ; created, private
          (should (= (file-modes dir) #o700))
          (should (equal (drgnx-ui-runtime-dir) dir))                       ; reused
          (set-file-modes dir #o755)
          (should-error (drgnx-ui-runtime-dir) :type 'drgnx-ui-error)
          (delete-directory dir)
          (make-directory (expand-file-name "elsewhere" tmp))
          (set-file-modes (expand-file-name "elsewhere" tmp) #o700)
          (make-symbolic-link (expand-file-name "elsewhere" tmp) dir)
          (should-error (drgnx-ui-runtime-dir) :type 'drgnx-ui-error))
      (delete-directory tmp t))))

(ert-deftest drgnx-ui/next-name-skips-taken-wayland-displays ()
  (drgnx-ui-test--with-state
    (write-region "" nil (expand-file-name "drgnx-ui-1" runtime))
    (should (equal (drgnx-ui-next-name root) "drgnx-ui-2"))))

(ert-deftest drgnx-ui/stop-asks-emacs-to-exit-before-stopping-the-unit ()
  ;; SIGTERM to the whole unit can take the compositor first: Emacs loses its display and exits
  ;; without its kill-emacs-hook (no layout saved).  Emacs is asked to exit first.
  (drgnx-ui-test--with-state
    (let* ((s (drgnx-ui-prepare-run "drgnx-ui-5")) (calls nil))
      (make-directory (file-name-directory (plist-get s :socket)) t)
      (write-region "" nil (plist-get s :socket))
      (cl-letf (((symbol-function 'drgnx-ui--ask-to-exit) (lambda (sock &rest _) (push (list 'ask sock) calls)))
                ((symbol-function 'drgnx-ui--unit-owned-p) (lambda (&rest _) t))
                ((symbol-function 'drgnx-ui--run) (lambda (&rest a) (push (cons 'run a) calls))))
        (drgnx-ui-stop "drgnx-ui-5"))
      (setq calls (nreverse calls))
      (should (equal (car calls) (list 'ask (plist-get s :socket))))
      (should (equal (car (cadr calls)) 'run)))))

(ert-deftest drgnx-ui/a-session-runs-at-most-its-budget ()
  (let ((sess (list :name "drgnx-ui-9" :run "/tmp/x" :size "800x600" :socket "/tmp/s")))
    (should (member "RuntimeMaxSec=1800" (let ((process-environment (cons "DRGNX_UI_MAX_RUNTIME" process-environment)))
                                           (drgnx-ui-launch-argv sess))))
    (should (member "RuntimeMaxSec=2700" (let ((process-environment (cons "DRGNX_UI_MAX_RUNTIME=2700" process-environment)))
                                           (drgnx-ui-launch-argv sess))))))

(ert-deftest drgnx-ui/detached-launch-is-capped ()
  ;; DEFERRED M1-6: the systemd launcher has RuntimeMaxSec and MemoryMax; the detached one needs the same caps
  (let ((sess (list :name "drgnx-ui-9" :run "/tmp/x" :size "800x600" :socket "/tmp/s"))
        (calls nil))
    (cl-letf (((symbol-function 'call-process) (lambda (&rest a) (push a calls) 0))
              ((symbol-function 'drgnx-ui--read-pgid) (lambda (&rest _) "123")))
      (drgnx-ui--launch-detached sess)
      (let ((cmd (car (last (car calls)))))
        (should (string-match-p "ulimit -v [0-9]+ " cmd))
        (should (string-match-p "exec timeout -k 10 1800 env " cmd))
        (should (string-match-p "pgid; ulimit" cmd)))
      (setq calls nil)
      (let ((process-environment (cons "DRGNX_UI_MAX_RUNTIME=2700" process-environment)))
        (drgnx-ui--launch-detached sess))
      (should (string-match-p "exec timeout -k 10 2700 env " (car (last (car calls))))))))

(ert-deftest drgnx-ui/stop-removes-the-wayland-display-socket ()
  (drgnx-ui-test--with-state
    ;; a name no real session has (tests run next to live shards' sessions: drgnx-ui-4 may be one)
    (let ((name (format "drgnx-ui-%d" (+ 900000 (random 99999)))))
      (drgnx-ui-prepare-run name)
      (dolist (f (list name (concat name ".lock"))) (write-region "" nil (expand-file-name f runtime)))
      (drgnx-ui-stop name)
      (should-not (file-exists-p (expand-file-name name runtime)))
      (should-not (file-exists-p (expand-file-name (concat name ".lock") runtime))))))

(ert-deftest drgnx-ui/process-groups-are-verified-before-signalling ()
  (should-not (drgnx-ui--group-ours-p "1" "/any/run"))
  (should-not (drgnx-ui--group-ours-p "0" "/any/run"))
  (should-not (drgnx-ui--group-ours-p nil "/any/run"))
  (should-not (drgnx-ui--group-ours-p (number-to-string (emacs-pid)) "/not/this/run/drgnx-ui-1")))

(ert-deftest drgnx-ui/stop-ends-the-group-of-a-partly-started-detached-session ()
  ;; DEFERRED M1-7: a run dir whose session.json has no :launcher yet (start failed before saving it)
  ;; but holds a pgid file is a detached session: stop ends its group, not a systemd unit
  (drgnx-ui-test--with-state
    (let ((run (expand-file-name "drgnx-ui-3" root)) (groups nil))
      (make-directory run)
      (write-region "12345\n" nil (expand-file-name "pgid" run))
      (cl-letf (((symbol-function 'drgnx-ui--stop-group) (lambda (pgid r) (push (list pgid r) groups)))
                ((symbol-function 'drgnx-ui--unit-owned-p) (lambda (&rest _) (error "not a unit"))))
        (drgnx-ui-stop "drgnx-ui-3"))
      (should (equal groups (list (list "12345" run))))
      (should-not (file-exists-p run)))))

(ert-deftest drgnx-ui/a-failed-detached-launch-stops-its-group ()
  ;; DEFERRED M1-7: setsid wrote its pgid but the start failed — the group is stopped, the run removed
  (drgnx-ui-test--with-state
    (let ((groups nil))
      (cl-letf (((symbol-function 'drgnx-ui-launcher) (lambda () "detached"))
                ((symbol-function 'drgnx-ui--launch-detached)
                 (lambda (s)
                   (write-region "12345\n" nil (expand-file-name "pgid" (plist-get s :run)))
                   (drgnx-ui--fail "setsid did not start %s" (plist-get s :name))))
                ((symbol-function 'drgnx-ui--stop-group) (lambda (pgid r) (push (list pgid r) groups))))
        (should-error (drgnx-ui--claim-and-launch nil "1600x900" root) :type 'drgnx-ui-error))
      (should (equal groups (list (list "12345" (expand-file-name "drgnx-ui-1" root)))))
      (should-not (file-exists-p (expand-file-name "drgnx-ui-1" root))))))

(ert-deftest drgnx-ui/daemon-session-argv ()
  (drgnx-ui-test--with-state
    (let* ((s (drgnx-ui-prepare-run "drgnx-ui-8" nil "1600x900" root t))
           (argv (drgnx-ui-compositor-argv s)))
      (should (eq (plist-get s :daemon) t))
      (should (member "--fg-daemon" argv))
      (should-not (member "--fullscreen" argv)))))

(ert-deftest drgnx-ui/cli-boolean-flags ()
  (should (equal (drgnx-ui--parse-args '("--daemon" "--config" "gryphn"))
                 '(nil :daemon t :config "gryphn"))))

(ert-deftest drgnx-ui/config-drgnx-is-the-checkouts-init ()
  (should (equal (drgnx-ui-resolve-config "drgnx") (expand-file-name "init" drgnx-ui-repo-dir))))

(ert-deftest drgnx-ui/frame-outcome ()
  (should (eq (car (drgnx-ui--frame-outcome '(100 200 300) '(0 0 0) 500 nil)) 'green))
  (should (eq (car (drgnx-ui--frame-outcome '(600 700 800) '(0 0 0) 500 t)) 'known))
  (should (eq (car (drgnx-ui--frame-outcome '(600 700 800) '(0 0 0) 500 nil)) 'red))
  (should (eq (car (drgnx-ui--frame-outcome '(100 200 300) '(0 0 0) 500 t)) 'red))        ; known red that passes
  (should (eq (car (drgnx-ui--frame-outcome '(:null :null :null) '(0 0 0) 500 t)) 'error)) ; never visible
  (should (eq (car (drgnx-ui--frame-outcome '(100 200 300) '(0 1 0) 500 nil)) 'error))) ; emacsclient failed

(ert-deftest drgnx-ui/mistyped-scenario-config-fails ()
  (let ((out (with-output-to-string
               (should (= (drgnx-ui-run-scenarios "/no/such/config/dir") 2)))))
    (should (string-search "no init.el" out))))

(ert-deftest drgnx-ui/missing-gryphn-config-skips ()
  (let ((process-environment (cons "DRGNX_GRYPHN_CONFIG=/no/such/gryphn" process-environment)))
    (should (= (drgnx-ui-run-scenarios "gryphn") 0))))

(ert-deftest drgnx-ui/sessions-never-touch-the-users-drgnx-files ()
  ;; A session's drgnx config and state live in its run dir, not in ~/.config/drgnx and
  ;; ~/.local/state (a drgnx session writes keys-report.eld on every boot).
  (drgnx-ui-test--with-state
    (let* ((s (drgnx-ui-prepare-run "drgnx-ui-1"))
           (env (drgnx-ui-session-env s)))
      (should (member (concat "DRGNX_CONFIG_DIR=" (expand-file-name "drgnx-config" (plist-get s :run))) env))
      (should (member (concat "XDG_STATE_HOME=" (expand-file-name "state" (plist-get s :run))) env))
      (should (member (concat "DRGNX_DATA_DIR=" (expand-file-name "drgnx-data" (plist-get s :run))) env))
      (drgnx-ui-stop "drgnx-ui-1"))))

(ert-deftest drgnx-ui/two-monitors ()
  ;; mutter gets one --virtual-monitor per monitor (multi-window tests).
  (drgnx-ui-test--with-state
    (let* ((s (drgnx-ui-prepare-run "drgnx-ui-7" nil "1024x768" root nil 2))
           (argv (drgnx-ui-compositor-argv s)))
      (should (= 2 (seq-count (lambda (a) (equal a "--virtual-monitor")) argv)))
      (should (= 2 (plist-get (drgnx-ui--parse-json (with-temp-buffer (insert-file-contents (expand-file-name "session.json" (plist-get s :run))) (buffer-string))) :monitors))))))

(ert-deftest drgnx-ui/two-sessions-starting-at-once-take-different-names ()
  ;; bin/drgnx check starts sessions from several processes: a name taken between the choice and the claim
  ;; moves on to the next one, never a failed start
  (drgnx-ui-test--with-state
    (let ((orig (symbol-function 'drgnx-ui-next-name)) (first t))
      (cl-letf (((symbol-function 'drgnx-ui-next-name)
                 (lambda (r) (if first (progn (setq first nil) (make-directory (expand-file-name "drgnx-ui-1" r)) "drgnx-ui-1")
                               (funcall orig r)))))
        (let ((s (drgnx-ui-claim-run nil "1600x900" root)))
          (should (equal (plist-get s :name) "drgnx-ui-2")))))))

(ert-deftest drgnx-ui/a-unit-name-another-session-holds-moves-on-to-the-next ()
  ;; unit names are global to the user: a session of another state root (a parallel shard) may hold
  ;; drgnx-ui-1 while this root has no run of that name — systemd says so, and the start takes the next name
  (drgnx-ui-test--with-state
    (let ((tries nil) (stopped nil))
      (cl-letf (((symbol-function 'drgnx-ui-launcher) (lambda () "systemd"))
                ((symbol-function 'drgnx-ui-unit-active-p) (lambda (_n) nil))
                ((symbol-function 'drgnx-ui-stop) (lambda (n) (push n stopped) (delete-directory (expand-file-name n root) t)))
                ((symbol-function 'drgnx-ui--run)
                 (lambda (&rest args)
                   (let ((unit (cadr (member "--unit" args))))
                     (push unit tries)
                     (if (equal unit "drgnx-ui-1")
                         (cons 1 "Failed to start transient service unit: Unit drgnx-ui-1.service was already loaded or has a fragment file.")
                       (cons 0 ""))))))
        (let ((s (drgnx-ui--claim-and-launch nil "1600x900" root)))
          (should (equal (plist-get s :name) "drgnx-ui-2"))
          (should (equal stopped '("drgnx-ui-1"))))))))

(ert-deftest drgnx-ui/a-unit-that-already-exists-moves-on-too ()
  ;; CHK-4: systemd also refuses a taken name as "Unit … already exists" (UnitExists); parallel shards hit either wording
  (drgnx-ui-test--with-state
    (let ((tries nil) (stopped nil))
      (cl-letf (((symbol-function 'drgnx-ui-launcher) (lambda () "systemd"))
                ((symbol-function 'drgnx-ui-unit-active-p) (lambda (_n) nil))
                ((symbol-function 'drgnx-ui-stop) (lambda (n) (push n stopped) (delete-directory (expand-file-name n root) t)))
                ((symbol-function 'drgnx-ui--run)
                 (lambda (&rest args)
                   (let ((unit (cadr (member "--unit" args))))
                     (push unit tries)
                     (if (equal unit "drgnx-ui-1")
                         (cons 1 "Failed to start transient service unit: Unit drgnx-ui-1.service already exists.")
                       (cons 0 ""))))))
        (let ((s (drgnx-ui--claim-and-launch nil "1600x900" root)))
          (should (equal (plist-get s :name) "drgnx-ui-2"))
          (should (equal stopped '("drgnx-ui-1"))))))))

(ert-deftest drgnx-ui/a-test-process-ending-stops-the-sessions-it-started ()
  ;; bin/drgnx check (and the test-* tiers) set DRGNX_UI_STOP_ON_EXIT: a test process that is ended — a
  ;; timeout, C-c — stops its own sessions on the way out; `drgnx ui start' sessions are meant to outlive it
  (let ((drgnx-ui--own nil) (stopped nil))
    (cl-letf (((symbol-function 'drgnx-ui-stop) (lambda (n) (push (cons n (getenv "DRGNX_UI_STATE")) stopped))))
      (drgnx-ui--own-add "drgnx-ui-7" "/tmp/root-a")
      (let ((process-environment (cons "DRGNX_UI_STOP_ON_EXIT" process-environment)))   ; unset
        (drgnx-ui--stop-own-on-exit)
        (should-not stopped))
      (let ((process-environment (cons "DRGNX_UI_STOP_ON_EXIT=1" process-environment)))
        (drgnx-ui--stop-own-on-exit)
        (should (equal stopped '(("drgnx-ui-7" . "/tmp/root-a")))))))     ; in the root it was started in
  (let ((drgnx-ui--own nil))
    (drgnx-ui--own-add "drgnx-ui-8" "/tmp/r")
    (drgnx-ui--own-remove "drgnx-ui-8")                                   ; a session stopped normally is forgotten
    (should-not drgnx-ui--own)))

(ert-deftest drgnx-ui/ending-stops-all-own-units-without-blocking-before-it-waits ()
  ;; CHK-2: the stops run side by side — one slow session cannot use up the grace the others need
  (let ((drgnx-ui--own nil) (events nil))
    (cl-letf (((symbol-function 'drgnx-ui-stop) (lambda (n) (push (list 'stop n) events)))
              ((symbol-function 'drgnx-ui--unit-owned-p) (lambda (n run) (and (string-suffix-p n run) t)))
              ((symbol-function 'drgnx-ui--run) (lambda (&rest args) (push (cons 'run args) events) (cons 0 ""))))
      (drgnx-ui--own-add "drgnx-ui-7" "/tmp/root-a")
      (drgnx-ui--own-add "drgnx-ui-8" "/tmp/root-b")
      (let ((process-environment (cons "DRGNX_UI_STOP_ON_EXIT=1" process-environment)))
        (drgnx-ui--stop-own-on-exit))
      (should (equal (reverse events)
                     '((run "systemctl" "--user" "stop" "--no-block" "drgnx-ui-8")
                       (run "systemctl" "--user" "stop" "--no-block" "drgnx-ui-7")
                       (stop "drgnx-ui-8") (stop "drgnx-ui-7")))))))

(ert-deftest drgnx-check/the-grace-covers-a-session-stop ()
  ;; ask-to-exit (3 s + 5 s) + TimeoutStopSec (10 s) + margin
  (should (>= drgnx-check-grace 25)))

(ert-deftest drgnx-ui/a-failed-action-ends-the-measurement-and-names-itself ()
  ;; DEFERRED M1-1: an action that fails (a bad key, a target not on screen) must not leave the
  ;; recorder's timer and hooks running in the session, and the error says which action it was
  (let ((calls nil))
    (cl-letf (((symbol-function 'drgnx-ui-call)
               (lambda (_sess form &rest _)
                 (push form calls)
                 (cond ((string-search "api-keys \"bad\"" form) (drgnx-ui--fail "no such key"))
                       ((string-search "api-status" form) '(:busy :false :settled t))
                       (t '(:ok t))))))
      (let ((err (should-error (drgnx-ui-measure '(:name "drgnx-ui-1") '((:keys "a") (:keys "bad") (:keys "c")))
                               :type 'drgnx-ui-error)))
        (should (string-match-p "action 2 (:keys .*bad.*): no such key" (error-message-string err))))
      (should (equal (car calls) "(drgnx-uitest-api-measure-end)"))
      (should-not (seq-find (lambda (f) (string-search "\"c\"" f)) calls)))))

(ert-deftest drgnx-ui/cli-arguments-are-utf-8-without-a-locale ()
  ;; DEFERRED M1-2: without a UTF-8 locale Emacs hands the arguments over as raw bytes, before
  ;; `drgnx-ui-batch-setup' can say UTF-8; `drgnx ui' decodes them itself
  (drgnx-ui-test--with-state
    (let ((process-environment (append '("LANG" "LC_ALL" "LC_CTYPE") process-environment))   ; unset
          (locale-coding-system 'utf-8-unix)
          (coding-system-for-read 'utf-8-unix))
      (with-temp-buffer
        (call-process (expand-file-name invocation-name invocation-directory) nil t nil
                      "--batch" "-Q" "-L" drgnx-ui-harness-dir "-L" (expand-file-name "core" drgnx-ui-repo-dir)
                      "-l" "drgnx-ui" "-f" "drgnx-ui-cli" "--" "stop" "drgnx-ui-✓")
        (should (string-search "not a drgnx harness session" (buffer-string)))
        (should (string-search "drgnx-ui-✓" (buffer-string)))))))
