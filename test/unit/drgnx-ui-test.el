;;; drgnx-ui-test.el --- batch tests: harness session controller -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-ui)
(require 'drgnx-uitest)
(require 'drgnx-check)

(defmacro drgnx-ui-test--with-state (&rest body)
  "Run BODY with `root' bound to a fresh DRGNX_UI_STATE directory.  No systemd unit counts as active:
the real ones belong to sessions running next to the tests (bin/drgnx check's live shards)."
  (declare (indent 0))
  `(let* ((root (make-temp-file "duis" t))              ; short: a check shard's temp dir is already deep, a socket path holds 108 bytes
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
    (let* ((s (drgnx-ui-prepare-run "drgnx-ui-1-00000a" nil "1600x900" root))
           (run (plist-get s :run)))
      (should (equal (file-name-nondirectory (plist-get s :socket)) "drgnx-ui-1-00000a"))
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
           (s (drgnx-ui-prepare-run "drgnx-ui-1-00000a")))
      (should (< (length (plist-get s :socket)) 100))
      (should-not (string-prefix-p deep (plist-get s :socket)))
      (should (member (concat "DRGNX_UI_SOCKET_DIR=" (directory-file-name (file-name-directory (plist-get s :socket))))
                      (drgnx-ui-session-env s)))
      (drgnx-ui-stop "drgnx-ui-1-00000a")
      (should-not (file-exists-p (file-name-directory (plist-get s :socket))))
      (should-not (file-exists-p (drgnx-ui-socket-dir "" deep))))))   ; the per-root dir, once empty

(ert-deftest drgnx-ui/socket-dirs-differ-between-state-roots ()
  (drgnx-ui-test--with-state
    (let* ((a (drgnx-ui-prepare-run "drgnx-ui-1-00000a" nil nil (expand-file-name "a" root)))
           (b (drgnx-ui-prepare-run "drgnx-ui-1-00000a" nil nil (expand-file-name "b" root))))
      (should-not (equal (plist-get a :socket) (plist-get b :socket)))
      (dolist (s (list a b)) (delete-directory (file-name-directory (plist-get s :socket)) t)))))

(ert-deftest drgnx-ui/prepare-external-config-links-code-copies-custom-skips-state ()
  (drgnx-ui-test--with-state
    (let ((cfg (expand-file-name "cfg" root)))
      (dolist (d '("lisp" "extras" "elpa")) (make-directory (expand-file-name d cfg) t))
      (dolist (f '("init.el" "custom.el" "history")) (write-region ";;\n" nil (expand-file-name f cfg)))
      (let* ((s (drgnx-ui-prepare-run "drgnx-ui-2-00000a" cfg "800x600" root))
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
    (drgnx-ui-prepare-run "drgnx-ui-1-00000a" nil "1600x900" root)
    (should-error (drgnx-ui-prepare-run "drgnx-ui-1-00000a" nil "1600x900" root))))

(ert-deftest drgnx-ui/prepare-rejects-bad-size-and-config ()
  (drgnx-ui-test--with-state
    (should-error (drgnx-ui-prepare-run "drgnx-ui-3-00000a" nil "big" root) :type 'drgnx-ui-error)
    (should-error (drgnx-ui-prepare-run "drgnx-ui-4-00000a" (expand-file-name "nope" root) "1600x900" root)
                  :type 'drgnx-ui-error)))

(ert-deftest drgnx-ui/env-is-allowlisted ()
  (drgnx-ui-test--with-state
    (let* ((process-environment (cons "DRGNX_FAKE_API_KEY=x" process-environment))
           (s (drgnx-ui-prepare-run "drgnx-ui-5-00000a" nil "1600x900" root))
           (env (drgnx-ui-session-env s)))
      (should-not (seq-find (lambda (kv) (string-prefix-p "DRGNX_FAKE_API_KEY=" kv)) env))
      (should (member "DRGNX_UI_NAME=drgnx-ui-5-00000a" env))
      (should (member "DRGNX_NO_LANGUAGE_SERVERS=1" env))      ; no pyright per fixture project (a test opts in)
      (should (member "DRGNX_NO_SHELL_ENV=1" env))             ; never the login shell's PATH
      (should (member (concat "EMACS_SOCKET_NAME=" (plist-get s :socket)) env))
      (should (equal (drgnx-ui-env-argv '("A=1")) '("env" "-i" "A=1"))))))

(ert-deftest drgnx-ui/a-session-test-run-keeps-the-no-timing-switch ()
  ;; CI's GUI jobs say DRGNX_TEST_NO_TIMING=1; the session's Emacs starts under `env -i', so it is passed on by name
  (let ((process-environment (cons "DRGNX_TEST_NO_TIMING=1" process-environment)))
    (should (equal (drgnx-ui--run-control-env) '("DRGNX_TEST_NO_TIMING=1"))))
  (let ((process-environment (cons "DRGNX_TEST_NO_TIMING=" process-environment)))
    (should-not (drgnx-ui--run-control-env))))

(ert-deftest drgnx-ui/a-session-never-gets-the-provider-keys ()
  ;; the session's processes start under `env -i' with the allowlist: no key of the starting process reaches them
  (drgnx-ui-test--with-state
    (let* ((keys '("OPENROUTER_API_KEY" "ANTHROPIC_API_KEY" "ANTHROPIC_AUTH_TOKEN" "OPENAI_API_KEY"))
           (process-environment (append (mapcar (lambda (k) (concat k "=x")) keys) process-environment))
           (s (drgnx-ui-prepare-run "drgnx-ui-5-00000a" nil "1600x900" root))
           (argv (drgnx-ui-launch-argv s)))
      (should (equal (seq-take (member "env" argv) 2) '("env" "-i")))
      (dolist (k keys)
        (should-not (seq-find (lambda (a) (string-prefix-p (concat k "=") a)) argv)))
      (drgnx-ui-stop "drgnx-ui-5-00000a"))))

(ert-deftest drgnx-ui/mutter-caches-stay-in-the-run-dir ()
  ;; M12c-12-5: mutter and the session's Emacs write their font and GL shader caches under RUN, never ~/.cache
  (drgnx-ui-test--with-state
    (let* ((s (drgnx-ui-prepare-run "drgnx-ui-5-00000a" nil "1600x900" root nil nil "mutter"))
           (env (drgnx-ui-session-env s))
           (cache (expand-file-name "xdg/cache" (plist-get s :run))))
      (should (member (concat "XDG_CACHE_HOME=" cache) env))
      (should (member (concat "MESA_SHADER_CACHE_DIR=" (expand-file-name "mesa" cache)) env))
      (should-not (seq-find (lambda (kv) (and (string-prefix-p "XDG_CACHE_HOME=" kv)
                                              (not (equal kv (concat "XDG_CACHE_HOME=" cache)))))
                            env)))))

(ert-deftest drgnx-ui/session-ids-are-never-reused ()
  ;; HARNESS-SESS-2: agents in other worktrees addressed each other's sessions when a stopped session's name came
  ;; back (the lowest free drgnx-ui-N).  An id is drgnx-ui-N-HEX: N one above the highest in this state root, HEX
  ;; from the pid and the time; a stopped session's id is refused, never handed out again.
  (drgnx-ui-test--with-state
    (let* ((first (plist-get (drgnx-ui-claim-run nil "1600x900" root) :name))
           (ids (list first)))
      (should (string-match-p "\\`drgnx-ui-1-[0-9a-f]\\{6\\}\\'" first))
      (should (string-match-p drgnx-ui-name-regexp first))
      ;; a second one while the first runs: one above the highest
      (let ((second (plist-get (drgnx-ui-claim-run nil "1600x900" root) :name)))
        (should (string-prefix-p "drgnx-ui-2-" second))
        (drgnx-ui-stop second))
      (drgnx-ui-stop first)
      (should-error (drgnx-ui-own-session first) :type 'drgnx-ui-refused)
      (dotimes (_ 20)
        (let ((name (plist-get (drgnx-ui-claim-run nil "1600x900" root) :name)))
          (should-not (member name ids))
          (push name ids)
          (drgnx-ui-stop name)
          (should-error (drgnx-ui-own-session name) :type 'drgnx-ui-refused))))))

(ert-deftest drgnx-ui/compositor-argv ()
  (drgnx-ui-test--with-state
    (let* ((s (drgnx-ui-prepare-run "drgnx-ui-6-00000a" nil "1024x768" root))
           (argv (drgnx-ui-compositor-argv s)))
      (should (equal (seq-take argv 3) '("dbus-run-session" "--" "mutter")))
      (dolist (flag '("--headless" "--wayland" "--no-x11")) (should (member flag argv)))
      (should (equal (cadr (member "--virtual-monitor" argv)) "1024x768"))
      (should (equal (cadr (member "--wayland-display" argv)) "drgnx-ui-6-00000a"))
      (should-not (member "-Q" argv))
      (should (equal (cadr (member "--init-directory" argv))
                     (expand-file-name "init" (plist-get s :run)))))))

(ert-deftest drgnx-ui/launch-argv ()
  (drgnx-ui-test--with-state
    (let* ((s (drgnx-ui-prepare-run "drgnx-ui-1-00000a" nil "1600x900" root))
           (argv (drgnx-ui-launch-argv s)))
      (should (equal (seq-take argv 6) '("systemd-run" "--user" "--quiet" "--collect" "--unit" "drgnx-ui-1-00000a")))
      (should (member "RuntimeMaxSec=1800" argv))
      (should (member "MemoryMax=3G" argv))
      ;; CHK-2: a stop returns within the check's 15 s grace (systemd's default is 90 s before it kills what is left)
      (should (member "TimeoutStopSec=10" argv))
      (should (equal (seq-take (cdr (member "--" argv)) 2) '("env" "-i"))))))

;; every variable that could carry the real home's paths into a test: the child must see it unset or inside its run
(defconst drgnx-ui-test--path-classes
  '("XDG_CONFIG_HOME" "XDG_DATA_HOME" "XDG_CACHE_HOME" "XDG_RUNTIME_DIR" "XDG_DATA_DIRS" "XDG_CONFIG_DIRS"
    "DRGNX_CONFIG_DIR" "DRGNX_DATA_DIR" "DRGNX_UI_STATE" "TMPDIR" "SSH_AUTH_SOCK" "SSH_AGENT_PID" "GNUPGHOME" "XAUTHORITY"
    "CLAUDE_CONFIG_DIR" "CODEX_HOME" "KIMI_CODE_HOME" "GIT_CONFIG_GLOBAL" "SOME_TOOL_DIR"))
;; (EMACSLOADPATH is read by the child Emacs itself at startup, before the runner can unset it: test-env-test covers it)

;; URGENT-3-UI-LIVE: `test --ui' ran test/live in its own process with the real HOME, state directory, bus and keys
(ert-deftest drgnx-ui/the-ui-tiers-live-half-runs-sandboxed ()
  (let* ((base (make-temp-file "drgnx-ui-live" t))
         (real-home (expand-file-name "real-home" base))
         (suite (expand-file-name "suite" base))
         (out (expand-file-name "seen.eld" base)))
    (unwind-protect
        (progn
          (make-directory real-home)
          (make-directory suite)
          (make-directory (expand-file-name "tmpdir" base))          ; the fake TMPDIR must exist, as the real one does
          (with-temp-file (expand-file-name "probe-test.el" suite)
            (insert (format "(require 'ert)\n(require 'drgnx-ui)
(ert-deftest live-probe/record ()
  (let ((root (drgnx-ui-state-root)))
    (make-directory (expand-file-name \"scenarios\" root) t)
    (write-region \"x\" nil (expand-file-name \"scenarios/minimal.json\" root))
    (with-temp-file %S
      (prin1 (list (getenv \"HOME\") (getenv \"OPENROUTER_API_KEY\") (getenv \"DISPLAY\") (getenv \"DBUS_SESSION_BUS_ADDRESS\") root
                   (expand-file-name \"~/probe\") (getenv \"XDG_STATE_HOME\")
                   ;; every path class: its value in this process, and Emacs' own directory
                   (mapcar (lambda (v) (cons v (getenv v))) '%S)
                   user-emacs-directory)
             (current-buffer)))))\n" out drgnx-ui-test--path-classes)))
          (let ((process-environment
                 (append (list (concat "HOME=" real-home) (concat "XDG_STATE_HOME=" real-home "/.local/state")
                               (concat "DRGNX_UI_STATE=" real-home "/ui-state") "OPENROUTER_API_KEY=sk-x" "DISPLAY=:0"
                               "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1/bus" "DRGNX_TEST_SELECTOR")
                         (mapcar (lambda (v) (format "%s=%s/%s" v real-home (downcase v))) (remove "TMPDIR" drgnx-ui-test--path-classes))
                         ;; (the runner makes its own directory under TMPDIR before anything is faked: outside the real home)
                         (list (concat "TMPDIR=" base "/tmpdir"))
                         process-environment))
                ok)
            (let ((log (with-output-to-string (setq ok (drgnx-ui-run-live-tests suite)))))
              (unless ok (message "live child:\n%s" log)))
            (should ok))
          (pcase-let ((`(,home ,key ,display ,bus ,state ,tilde ,xdg-state ,classes ,emacs-dir)
                       (with-temp-buffer (insert-file-contents out) (read (current-buffer)))))
            (should-not key)
            (should-not display)
            (should (equal bus "unix:path=/nonexistent/drgnx-unit-test"))
            ;; everything it wrote is under the run's temp directory, nothing under the real home
            (should-not (string-prefix-p real-home home))
            (should (string-prefix-p (file-name-directory home) state))
            (should (string-prefix-p (file-name-directory home) xdg-state))
            (should (string-prefix-p home tilde))
            ;; every path class is unset or inside the run; user-emacs-directory too
            (should (equal (mapcar #'car classes) drgnx-ui-test--path-classes))
            (dolist (c classes)
              (should-not (and (cdr c) (string-search real-home (cdr c)))))
            (should-not (string-search real-home emacs-dir))
            (should-not (equal (cdr (assoc "TMPDIR" classes)) (concat base "/tmpdir")))
            (should (string-prefix-p (file-name-directory home) emacs-dir))
            (should-not (directory-files-recursively real-home ".")))
          )
      (delete-directory base t))))

(ert-deftest drgnx-ui/an-interactive-session-holds-a-light-slot-while-it-lives ()
  (skip-unless (executable-find "flock"))
  (drgnx-ui-test--with-state
    (let* ((process-environment (append '("DRGNX_LEASE_HELD" "DRGNX_LEASE" "CI=false" "DRGNX_LEASE_DIR=/leases/x/lease")
                                        process-environment))
           (s (drgnx-ui-prepare-run "drgnx-ui-6-00000a" nil "1600x900" root))
           (argv (drgnx-ui-launch-argv s))
           (lease (member "lease" argv)))
      (should (member "DRGNX_LEASE_DIR=/leases/x/lease" argv))      ; the session's environment is `env -i'
      (should (equal (seq-take lease 6) '("lease" "light" "--wait" "120" "--" "dbus-run-session")))
      (should (string-suffix-p "/bin/drgnx" (car (last (butlast argv (length lease)) 1))))
      (should (member "DRGNX_LEASE_CAP=off" argv))                  ; the unit is capped already
      (drgnx-ui-stop "drgnx-ui-6-00000a"))))

(ert-deftest drgnx-ui/a-test-session-takes-no-slot ()
  (drgnx-ui-test--with-state
    (dolist (off '("DRGNX_LEASE_HELD=light:1" "CI=true" "DRGNX_LEASE=off"))
      (let* ((process-environment (append (list off "DRGNX_LEASE_DIR=/leases/x/lease") process-environment))
             (s (drgnx-ui-prepare-run (format "drgnx-ui-%d-00000a" (+ 10 (length off))) nil "1600x900" root))
             (argv (drgnx-ui-launch-argv s)))
        (should-not (member "lease" argv))
        (should-not (seq-find (lambda (a) (string-prefix-p "DRGNX_LEASE_DIR=" a)) argv))
        (drgnx-ui-stop (plist-get s :name))))))

(ert-deftest drgnx-ui/a-refused-lease-is-reported-with-its-holders ()
  (should (equal "no light slot free in 120 s: light 1 42 /w bin/drgnx test since t; light 2 43 /w2 bin/drgnx test since t"
                 (drgnx-ui--lease-refusal
                  "x\ndrgnx lease: no light slot free in 120 s; holders:\nlight 1 42 /w bin/drgnx test since t\nlight 2 43 /w2 bin/drgnx test since t\n")))
  (should-not (drgnx-ui--lease-refusal "dbus-run-session: failed\n")))

(ert-deftest drgnx-ui/el-quoting-roundtrip ()
  (let ((s "he said \"hi\"\\ \n✓ \t"))
    (should (equal (car (read-from-string (drgnx-ui-el s))) s)))
  (should (equal (list (drgnx-ui-el nil) (drgnx-ui-el t) (drgnx-ui-el 3)) '("nil" "t" "3"))))

(ert-deftest drgnx-ui/parse-reply-handles-elisp-string-printing ()
  (let ((printed (prin1-to-string (drgnx-uitest--json (list :t "a\"b\nc ✓")))))
    (should (equal (drgnx-ui-parse-reply printed) '(:t "a\"b\nc ✓")))))

(ert-deftest drgnx-ui/next-name-skips-stale-dirs ()
  (drgnx-ui-test--with-state
    (make-directory (expand-file-name "drgnx-ui-1-00000a" root))
    (should (string-match-p "\\`drgnx-ui-2-[0-9a-f]\\{6\\}\\'" (drgnx-ui-next-name root)))
    ;; a run dir of the old shape (drgnx-ui-N) counts too
    (make-directory (expand-file-name "drgnx-ui-5" root))
    (should (string-prefix-p "drgnx-ui-6-" (drgnx-ui-next-name root)))))

(ert-deftest drgnx-ui/reap-removes-stale-dirs ()
  (drgnx-ui-test--with-state
    (drgnx-ui-prepare-run "drgnx-ui-7-00000a" nil "1600x900")
    (should (member "drgnx-ui-7-00000a" (append (drgnx-ui-reap) nil)))
    (should-not (file-exists-p (expand-file-name "drgnx-ui-7-00000a" root)))))

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
      (let ((stale (funcall file "31.1-aaaa/subr--trampoline-x.eln" old))
            (used (funcall file "31.1-aaaa/subr--trampoline-y.eln"))
            (preloaded (funcall file "31.1-aaaa/preloaded/z.eln" old))
            (gone (funcall file "29.4-bbbb/w.eln" old))
            (other (funcall file "31.1-aaaa/notes.txt" old)))
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
    (let ((units "drgnx-ui-41-00000a.service loaded active running x\ndrgnx-ui-42-00000a.service loaded active running y\n")
          (cmdlines `(("drgnx-ui-41-00000a" . ,(format "argv[]=env DRGNX_UI_RUN=%s/drgnx-ui-41-00000a ..." root))
                      ("drgnx-ui-42-00000a" . "argv[]=env DRGNX_UI_RUN=/elsewhere/drgnx-ui-42-00000a ..."))))
      (should (equal (drgnx-ui-reap-targets root units (lambda (n) (alist-get n cmdlines nil nil #'equal)))
                     '("drgnx-ui-41-00000a"))))))

(ert-deftest drgnx-ui/foreign-sessions-refused ()
  (drgnx-ui-test--with-state
    (dolist (name '("server" "../drgnx-ui-1-00000a" "/run/user/1000/emacs/server" "drgnx-ui-1x" "drgnx-ui-9-00000a" 7))
      (should-error (drgnx-ui-own-session name) :type 'drgnx-ui-refused))))

(ert-deftest drgnx-ui/own-session-needs-its-socket ()
  (drgnx-ui-test--with-state
    (let ((s (drgnx-ui-prepare-run "drgnx-ui-3-00000a" nil "1600x900")))
      (should-error (drgnx-ui-own-session "drgnx-ui-3-00000a") :type 'drgnx-ui-refused)
      (let ((server (make-network-process :name "drgnx-ui-test-sock" :family 'local :server t
                                          :service (plist-get s :socket) :noquery t)))
        (unwind-protect
            (should (equal (plist-get (drgnx-ui-own-session "drgnx-ui-3-00000a") :name) "drgnx-ui-3-00000a"))
          (delete-process server))))))

(ert-deftest drgnx-ui/composite-argv ()
  (should (equal (drgnx-ui-composite-argv '(:root "/r.png" :children [(:path "/c0.png" :x 307 :y 338)]) "/o.png")
                 '("magick" "/r.png" "/c0.png" "-geometry" "+307+338" "-composite" "/o.png"))))

(ert-deftest drgnx-ui/act-rejects-unknown-actions ()
  (should-error (drgnx-ui-act '(:socket "/nonexistent") '(:fly 1)) :type 'drgnx-ui-error))

(ert-deftest drgnx-ui/drag-actions-take-pixels-in-any-shape ()
  ;; (:drag (:from (X . Y) :to (X . Y) :steps N)), and the same from JSON: arrays and objects
  (should (equal (drgnx-ui--drag-spec '(:from (10 . 20) :to (110 . 20))) '(10 20 110 20 1 nil)))
  (should (equal (drgnx-ui--drag-spec '(:from (10 . 20) :to (110 . 25) :steps 3 :button 2)) '(10 20 110 25 2 3)))
  (should (equal (drgnx-ui--drag-spec '(:from (1 . 2) :to (3 . 4) :steps 200)) '(1 2 3 4 1 200))) ; the cap fits the wait
  (should (equal (drgnx-ui--drag-spec '(:from [10 20] :to (110 25))) '(10 20 110 25 1 nil)))
  (should (equal (drgnx-ui--drag-spec '(:from (:x 10 :y 20) :to (:x 1 :y 2))) '(10 20 1 2 1 nil)))
  (dolist (bad '(nil (:from (1 . 2)) (:from (1 . 2) :to (3 . nil)) (:from (1 . 2) :to (3 . -4))
                     (:from (1 . 2) :to (3 . 4.5)) (:from (1 . 2) :to "x") (:from (1 . 2) :to (3 . 4) :steps 0)
                     (:from (1 . 2) :to (3 . 4) :steps 201) (:from (1 . 2) :to (3 . 4) :button 9)))
    (should-error (drgnx-ui--drag-spec bad) :type 'drgnx-ui-error))
  ;; an action with a bad drag fails before anything is sent to the session
  (should-error (drgnx-ui-act '(:socket "/nonexistent") '(:drag (:from (1 . 2)))) :type 'drgnx-ui-error))

(ert-deftest drgnx-ui/cli-args ()
  (should (equal (drgnx-ui--parse-args '("drgnx-ui-1-00000a" "--buffer" "*scratch*" "--hold-ms" "300"))
                 '(("drgnx-ui-1-00000a") :buffer "*scratch*" :hold_ms "300"))))

(ert-deftest drgnx-ui/cli-click-needs-pixel-coordinates ()
  ;; DEFERRED M1-3: a missing or non-numeric X/Y used to click at (0,0)
  (should (equal (drgnx-ui--click-action '("drgnx-ui-1-00000a" "10" "20") '(:count "2")) '(:x 10 :y 20 :count 2)))
  (dolist (pos '(("drgnx-ui-1-00000a") ("drgnx-ui-1-00000a" "10") ("drgnx-ui-1-00000a" "a" "3") ("drgnx-ui-1-00000a" "-1" "3")
                 ("drgnx-ui-1-00000a" "1.5" "3") ("drgnx-ui-1-00000a" "10" "20px")))
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
           (s (drgnx-ui-prepare-run "drgnx-ui-1-00000a")))
      (should (equal (drgnx-ui-runtime-dir)
                     (expand-file-name (format "drgnx-ui-%d" (user-uid)) temporary-file-directory)))
      (should (= (file-modes (drgnx-ui-runtime-dir)) #o700))
      (should (member (concat "XDG_RUNTIME_DIR=" (drgnx-ui-runtime-dir)) (drgnx-ui-session-env s)))
      (drgnx-ui-stop "drgnx-ui-1-00000a"))))

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
    (write-region "" nil (expand-file-name "drgnx-ui-1-00000a" runtime))
    (should (string-prefix-p "drgnx-ui-2-" (drgnx-ui-next-name root)))
    ;; and an id whose display is taken (another state root's session) is drawn again
    (let* ((taken (drgnx-ui-next-name root)) (drawn (list taken)) (orig (symbol-function 'md5)))
      (write-region "" nil (expand-file-name taken runtime))
      (cl-letf (((symbol-function 'md5)
                 (lambda (&rest args) (if (cdr drawn) (apply orig args) (push t drawn) (substring taken -6)))))
        (should-not (equal (drgnx-ui-next-name root) taken))))))

(ert-deftest drgnx-ui/stop-asks-emacs-to-exit-before-stopping-the-unit ()
  ;; SIGTERM to the whole unit can take the compositor first: Emacs loses its display and exits
  ;; without its kill-emacs-hook (no layout saved).  Emacs is asked to exit first.
  (drgnx-ui-test--with-state
    (let* ((s (drgnx-ui-prepare-run "drgnx-ui-5-00000a")) (calls nil))
      (make-directory (file-name-directory (plist-get s :socket)) t)
      (write-region "" nil (plist-get s :socket))
      (cl-letf (((symbol-function 'drgnx-ui--ask-to-exit) (lambda (sock &rest _) (push (list 'ask sock) calls)))
                ((symbol-function 'drgnx-ui--unit-owned-p) (lambda (&rest _) t))
                ((symbol-function 'drgnx-ui--run) (lambda (&rest a) (push (cons 'run a) calls))))
        (drgnx-ui-stop "drgnx-ui-5-00000a"))
      (setq calls (nreverse calls))
      (should (equal (car calls) (list 'ask (plist-get s :socket))))
      (should (equal (car (cadr calls)) 'run)))))

(ert-deftest drgnx-ui/a-session-runs-at-most-its-budget ()
  (let ((sess (list :name "drgnx-ui-9-00000a" :run (make-temp-file "dux" t) :size "800x600" :socket "/tmp/s")))
    (should (member "RuntimeMaxSec=1800" (let ((process-environment (cons "DRGNX_UI_MAX_RUNTIME" process-environment)))
                                           (drgnx-ui-launch-argv sess))))
    (should (member "RuntimeMaxSec=2700" (let ((process-environment (cons "DRGNX_UI_MAX_RUNTIME=2700" process-environment)))
                                           (drgnx-ui-launch-argv sess))))))

(ert-deftest drgnx-ui/detached-launch-is-capped ()
  ;; DEFERRED M1-6: the systemd launcher has RuntimeMaxSec and MemoryMax; the detached one needs the same caps
  (let ((sess (list :name "drgnx-ui-9-00000a" :run (make-temp-file "dux" t) :size "800x600" :socket "/tmp/s"))
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
    ;; a name no real session has (tests run next to live shards' sessions: drgnx-ui-4-00000a may be one)
    (let ((name (format "drgnx-ui-%d-00000a" (+ 900000 (random 99999)))))
      (drgnx-ui-prepare-run name)
      (dolist (f (list name (concat name ".lock"))) (write-region "" nil (expand-file-name f runtime)))
      (drgnx-ui-stop name)
      (should-not (file-exists-p (expand-file-name name runtime)))
      (should-not (file-exists-p (expand-file-name (concat name ".lock") runtime))))))

(ert-deftest drgnx-ui/process-groups-are-verified-before-signalling ()
  (should-not (drgnx-ui--group-ours-p "1" "/any/run"))
  (should-not (drgnx-ui--group-ours-p "0" "/any/run"))
  (should-not (drgnx-ui--group-ours-p nil "/any/run"))
  (should-not (drgnx-ui--group-ours-p (number-to-string (emacs-pid)) "/not/this/run/drgnx-ui-1-00000a")))

(ert-deftest drgnx-ui/stop-ends-the-group-of-a-partly-started-detached-session ()
  ;; DEFERRED M1-7: a run dir whose session.json has no :launcher yet (start failed before saving it)
  ;; but holds a pgid file is a detached session: stop ends its group, not a systemd unit
  (drgnx-ui-test--with-state
    (let ((run (expand-file-name "drgnx-ui-3-00000a" root)) (groups nil))
      (make-directory run)
      (write-region "12345\n" nil (expand-file-name "pgid" run))
      (cl-letf (((symbol-function 'drgnx-ui--stop-group) (lambda (pgid r) (push (list pgid r) groups)))
                ((symbol-function 'drgnx-ui--unit-owned-p) (lambda (&rest _) (error "not a unit"))))
        (drgnx-ui-stop "drgnx-ui-3-00000a"))
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
      (should (equal (mapcar #'car groups) '("12345")))
      (should (string-match-p drgnx-ui-name-regexp (file-name-nondirectory (cadr (car groups)))))
      (should-not (file-exists-p (cadr (car groups)))))))

(ert-deftest drgnx-ui/daemon-session-argv ()
  (drgnx-ui-test--with-state
    (let* ((s (drgnx-ui-prepare-run "drgnx-ui-8-00000a" nil "1600x900" root t))
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
    (let* ((s (drgnx-ui-prepare-run "drgnx-ui-1-00000a"))
           (env (drgnx-ui-session-env s)))
      (should (member (concat "DRGNX_CONFIG_DIR=" (expand-file-name "drgnx-config" (plist-get s :run))) env))
      (should (member (concat "XDG_STATE_HOME=" (expand-file-name "state" (plist-get s :run))) env))
      (should (member (concat "DRGNX_DATA_DIR=" (expand-file-name "drgnx-data" (plist-get s :run))) env))
      (drgnx-ui-stop "drgnx-ui-1-00000a"))))

(ert-deftest drgnx-ui/extra-env-reaches-the-sessions-started-under-it ()
  ;; the kitty exit test puts kkp on its daemon's load path; other sessions get nothing extra
  (drgnx-ui-test--with-state
    (let ((s (drgnx-ui-prepare-run "drgnx-ui-1-00000a")))
      (should-not (seq-find (lambda (kv) (string-prefix-p "EMACSLOADPATH=" kv)) (drgnx-ui-launch-argv s)))
      (let ((drgnx-ui-session-extra-env '("EMACSLOADPATH=/elpa/kkp:")))
        (should (member "EMACSLOADPATH=/elpa/kkp:" (drgnx-ui-launch-argv s)))
        ;; the caller's EXTRA still comes last
        (should (equal (last (drgnx-ui-session-env s '("EMACSLOADPATH=/other:"))) '("EMACSLOADPATH=/other:"))))
      ;; only names on the allow-list: nothing can move the session's home, display, bus or temp dir
      (dolist (kv '("HOME=/x" "DISPLAY=:0" "DBUS_SESSION_BUS_ADDRESS=x" "XDG_RUNTIME_DIR=/x" "TMPDIR=/x" "no-equals"))
        (let ((drgnx-ui-session-extra-env (list kv)))
          (should-error (drgnx-ui-session-env s) :type 'drgnx-ui-error)
          (should-error (drgnx-ui-launch-argv s) :type 'drgnx-ui-error)))
      (drgnx-ui-stop "drgnx-ui-1-00000a"))))

(ert-deftest drgnx-ui/a-session-has-a-temp-dir-in-its-run-dir ()
  ;; TMP-1: what the session's Emacs and its tests put in /tmp goes in the run dir, removed with it.
  (drgnx-ui-test--with-state
    (let* ((s (drgnx-ui-prepare-run "drgnx-ui-1-00000a"))
           (tmp (expand-file-name "tmp" (plist-get s :run))))
      (should (member (concat "TMPDIR=" tmp) (drgnx-ui-session-env s)))
      (should (file-directory-p tmp))
      (drgnx-ui-stop "drgnx-ui-1-00000a")
      (should-not (file-exists-p tmp)))))

(ert-deftest drgnx-ui/two-monitors ()
  ;; mutter gets one --virtual-monitor per monitor (multi-window tests).
  (drgnx-ui-test--with-state
    (let* ((s (drgnx-ui-prepare-run "drgnx-ui-7-00000a" nil "1024x768" root nil 2))
           (argv (drgnx-ui-compositor-argv s)))
      (should (= 2 (seq-count (lambda (a) (equal a "--virtual-monitor")) argv)))
      (should (= 2 (plist-get (drgnx-ui--parse-json (with-temp-buffer (insert-file-contents (expand-file-name "session.json" (plist-get s :run))) (buffer-string))) :monitors))))))

(ert-deftest drgnx-ui/two-sessions-starting-at-once-take-different-names ()
  ;; bin/drgnx check starts sessions from several processes: a name taken between the choice and the claim
  ;; moves on to the next one, never a failed start
  (drgnx-ui-test--with-state
    (let ((orig (symbol-function 'drgnx-ui-next-name)) (first t))
      (cl-letf (((symbol-function 'drgnx-ui-next-name)
                 (lambda (r) (if first (progn (setq first nil) (make-directory (expand-file-name "drgnx-ui-1-00000a" r)) "drgnx-ui-1-00000a")
                               (funcall orig r)))))
        (let ((s (drgnx-ui-claim-run nil "1600x900" root)))
          (should (string-prefix-p "drgnx-ui-2-" (plist-get s :name))))))))

(ert-deftest drgnx-ui/a-unit-name-another-session-holds-moves-on-to-the-next ()
  ;; unit names are global to the user: a session of another state root (a parallel shard) may hold
  ;; drgnx-ui-1-00000a while this root has no run of that name — systemd says so, and the start takes the next name
  (drgnx-ui-test--with-state
    (let ((tries nil) (stopped nil))
      (cl-letf (((symbol-function 'drgnx-ui-launcher) (lambda () "systemd"))
                ((symbol-function 'drgnx-ui-unit-active-p) (lambda (_n) nil))
                ((symbol-function 'drgnx-ui-stop) (lambda (n) (push n stopped) (delete-directory (expand-file-name n root) t)))
                ((symbol-function 'drgnx-ui--run)
                 (lambda (&rest args)
                   (let ((unit (cadr (member "--unit" args))))
                     (push unit tries)
                     (if (null (cdr tries))   ; the first id tried
                         (cons 1 "Failed to start transient service unit: Unit drgnx-ui-1-00000a.service was already loaded or has a fragment file.")
                       (cons 0 ""))))))
        (let ((s (drgnx-ui--claim-and-launch nil "1600x900" root)))
          (should (string-prefix-p "drgnx-ui-2-" (plist-get s :name)))
          (should (equal stopped (last tries))))))))

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
                     (if (null (cdr tries))   ; the first id tried
                         (cons 1 "Failed to start transient service unit: Unit drgnx-ui-1-00000a.service already exists.")
                       (cons 0 ""))))))
        (let ((s (drgnx-ui--claim-and-launch nil "1600x900" root)))
          (should (string-prefix-p "drgnx-ui-2-" (plist-get s :name)))
          (should (equal stopped (last tries))))))))

(ert-deftest drgnx-ui/a-test-process-ending-stops-the-sessions-it-started ()
  ;; bin/drgnx check (and the test-* tiers) set DRGNX_UI_STOP_ON_EXIT: a test process that is ended — a
  ;; timeout, C-c — stops its own sessions on the way out; `drgnx ui start' sessions are meant to outlive it
  (let ((drgnx-ui--own nil) (stopped nil))
    (cl-letf (((symbol-function 'drgnx-ui-stop) (lambda (n) (push (cons n (getenv "DRGNX_UI_STATE")) stopped))))
      (drgnx-ui--own-add "drgnx-ui-7-00000a" "/tmp/root-a")
      (let ((process-environment (cons "DRGNX_UI_STOP_ON_EXIT" process-environment)))   ; unset
        (drgnx-ui--stop-own-on-exit)
        (should-not stopped))
      (let ((process-environment (cons "DRGNX_UI_STOP_ON_EXIT=1" process-environment)))
        (drgnx-ui--stop-own-on-exit)
        (should (equal stopped '(("drgnx-ui-7-00000a" . "/tmp/root-a")))))))     ; in the root it was started in
  (let ((drgnx-ui--own nil))
    (drgnx-ui--own-add "drgnx-ui-8-00000a" "/tmp/r")
    (drgnx-ui--own-remove "drgnx-ui-8-00000a")                                   ; a session stopped normally is forgotten
    (should-not drgnx-ui--own)))

(ert-deftest drgnx-ui/ending-stops-all-own-units-without-blocking-before-it-waits ()
  ;; CHK-2: the stops run side by side — one slow session cannot use up the grace the others need
  (let ((drgnx-ui--own nil) (events nil))
    (cl-letf (((symbol-function 'drgnx-ui-stop) (lambda (n) (push (list 'stop n) events)))
              ((symbol-function 'drgnx-ui--unit-owned-p) (lambda (n run) (and (string-suffix-p n run) t)))
              ((symbol-function 'drgnx-ui--run) (lambda (&rest args) (push (cons 'run args) events) (cons 0 ""))))
      (drgnx-ui--own-add "drgnx-ui-7-00000a" "/tmp/root-a")
      (drgnx-ui--own-add "drgnx-ui-8-00000a" "/tmp/root-b")
      (let ((process-environment (cons "DRGNX_UI_STOP_ON_EXIT=1" process-environment)))
        (drgnx-ui--stop-own-on-exit))
      (should (equal (reverse events)
                     '((run "systemctl" "--user" "stop" "--no-block" "drgnx-ui-8-00000a")
                       (run "systemctl" "--user" "stop" "--no-block" "drgnx-ui-7-00000a")
                       (stop "drgnx-ui-8-00000a") (stop "drgnx-ui-7-00000a")))))))

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
      (let ((err (should-error (drgnx-ui-measure '(:name "drgnx-ui-1-00000a") '((:keys "a") (:keys "bad") (:keys "c")))
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

;;;; Session safety: ids, tombstones, owner, the run-id check (HARNESS-SESS-1/2)

(defconst drgnx-ui-test--claim-script
  "(progn (fset 'drgnx-ui-unit-active-p #'ignore)
         (let ((names nil))
           (dolist (r (list (getenv \"CLAIM_A\") (getenv \"CLAIM_B\")))
             (dotimes (_ 250)
               (push (plist-get (drgnx-ui-prepare-run (drgnx-ui-next-name r) nil nil r) :name) names)))
           (with-temp-file (getenv \"CLAIM_OUT\") (prin1 names (current-buffer)))))"
  "What the second Emacs of the claim test runs: 250 claims in each of the two roots.")

(ert-deftest drgnx-ui/a-thousand-claims-across-two-roots-never-collide ()
  ;; ids stay unique while two Emacs claim in the same two roots at once: uniqueness is the hex and the claim
  ;; (prepare-run makes the run directory and signals when it exists), not the shared counter
  (drgnx-ui-test--with-state
    (let* ((a (expand-file-name "a" root)) (b (expand-file-name "b" root))
           (out (expand-file-name "claimed.eld" root))
           (names nil)
           (proc (let ((process-environment (append (list (concat "CLAIM_A=" a) (concat "CLAIM_B=" b)
                                                          (concat "CLAIM_OUT=" out))
                                                    process-environment)))
                   (start-process "claims" (generate-new-buffer " *claims*")
                                  (expand-file-name invocation-name invocation-directory)
                                  "--batch" "-Q" "-L" drgnx-ui-harness-dir
                                  "-L" (expand-file-name "core" drgnx-ui-repo-dir)
                                  "-l" "drgnx-ui" "--eval" drgnx-ui-test--claim-script))))
      (set-process-query-on-exit-flag proc nil)
      (dolist (r (list a b))
        (dotimes (_ 250)
          (push (plist-get (drgnx-ui-prepare-run (drgnx-ui-next-name r) nil nil r) :name) names)))
      (let ((deadline (+ (float-time) 120)))
        (while (and (process-live-p proc) (< (float-time) deadline)) (accept-process-output proc 0.1)))
      (unless (eq 0 (process-exit-status proc))
        (ert-fail (list "the second Emacs failed" (process-exit-status proc) (with-current-buffer (process-buffer proc) (buffer-string)))))
      (kill-buffer (process-buffer proc))
      (setq names (append names (with-temp-buffer (insert-file-contents out) (read (current-buffer)))))
      (should (= (length names) 1000))
      (should (= (length (delete-dups (copy-sequence names))) 1000))
      (dolist (r (list a b))
        (should (= 500 (length (directory-files r nil drgnx-ui-name-regexp))))))))

(ert-deftest drgnx-ui/n-counts-past-tombstones-and-the-counter ()
  (drgnx-ui-test--with-state
    (make-directory (expand-file-name "ended" root))
    (write-region "" nil (expand-file-name "ended/drgnx-ui-9-aaaaaa.eld" root))
    (should (string-prefix-p "drgnx-ui-10-" (drgnx-ui-next-name root)))
    (should (equal (string-trim (drgnx-ui-test--slurp (expand-file-name "counter" root))) "10"))
    ;; the counter alone, with nothing else left in the root
    (delete-directory (expand-file-name "ended" root) t)
    (should (string-prefix-p "drgnx-ui-11-" (drgnx-ui-next-name root)))
    (write-region "40" nil (expand-file-name "counter" root))
    (should (string-prefix-p "drgnx-ui-41-" (drgnx-ui-next-name root)))
    (should (equal (string-trim (drgnx-ui-test--slurp (expand-file-name "counter" root))) "41"))))

(ert-deftest drgnx-ui/test-sessions-use-the-generator ()
  (drgnx-ui-test--with-state
    (should (string-match-p "\\`drgnx-ui-test-1-[0-9a-f]\\{6\\}\\'" (drgnx-ui-next-name root "test")))
    ;; …and the session `drgnx-ui-run-ert-session' makes is named so, not drgnx-ui-test-PID-RANDOM
    (let (seen)
      (cl-letf (((symbol-function 'drgnx-ui--run-with-timeout)
                 (lambda (_timeout &rest args) (push args seen) (list 0 "")))
                ((symbol-function 'drgnx-ui--run) (lambda (&rest _) (cons 0 "")))
                ((symbol-function 'drgnx-ui-launcher) (lambda () "detached")))
        (drgnx-ui-run-ert-session root 5))
      (should (string-match-p "/drgnx-ui-test-2-[0-9a-f]\\{6\\}\\(/\\| \\|\\'\\)" (format "%S" seen)))
      (should-not (string-match-p "drgnx-ui-test-[0-9]+-[0-9]\\{5\\}\\b" (format "%S" seen))))))

(ert-deftest drgnx-ui/stop-writes-a-tombstone ()
  (drgnx-ui-test--with-state
    (drgnx-ui-prepare-run "drgnx-ui-4-00000a" nil "1600x900")
    (drgnx-ui-stop "drgnx-ui-4-00000a")
    (let ((tomb (car (read-from-string (drgnx-ui-test--slurp (expand-file-name "ended/drgnx-ui-4-00000a.eld" root))))))
      (should (equal (plist-get tomb :reason) 'stopped))
      (should (eq (plist-get tomb :by) (emacs-pid)))
      (should (string-match-p "\\`[0-9]\\{4\\}-[0-9][0-9]-[0-9][0-9]T[0-9:]+[+-][0-9]\\{4\\}\\'" (plist-get tomb :ended)))
      (should (stringp (plist-get tomb :worktree))))
    (should-not (file-exists-p (expand-file-name "drgnx-ui-4-00000a" root)))))

(ert-deftest drgnx-ui/tombstones-older-than-7-days-are-pruned ()
  (drgnx-ui-test--with-state
    (let ((old (expand-file-name "ended/drgnx-ui-1-aaaaaa.eld" root))
          (new (expand-file-name "ended/drgnx-ui-2-bbbbbb.eld" root)))
      (make-directory (file-name-directory old))
      (dolist (f (list old new)) (write-region "()" nil f))
      (set-file-times old (time-subtract nil (* 86400 (1+ drgnx-ui-tombstone-days))))
      (drgnx-ui--prune-tombstones root)
      (should-not (file-exists-p old))
      (should (file-exists-p new))
      ;; a pruned id is only unknown: still refused, and N does not go back below the counter
      (should-error (drgnx-ui-own-session "drgnx-ui-1-aaaaaa") :type 'drgnx-ui-refused))))

(ert-deftest drgnx-ui/a-stopped-id-is-refused-with-its-tombstone ()
  (drgnx-ui-test--with-state
    (drgnx-ui-prepare-run "drgnx-ui-7-3fa9c1" nil "1600x900")
    (drgnx-ui-stop "drgnx-ui-7-3fa9c1")
    (let ((err (should-error (drgnx-ui-own-session "drgnx-ui-7-3fa9c1") :type 'drgnx-ui-refused)))
      (should (string-match-p
               "\\`drgnx-ui-7-3fa9c1 ended at [0-9T:+-]+ (stopped); ids are never reused: start a new session\\'"
               (cadr err))))))

(ert-deftest drgnx-ui/a-legacy-id-is-refused-but-reaped ()
  (drgnx-ui-test--with-state
    (make-directory (expand-file-name "drgnx-ui-5" root))
    (let ((err (should-error (drgnx-ui-own-session "drgnx-ui-5") :type 'drgnx-ui-refused)))
      (should (equal (cadr err) "harness upgraded: ids are drgnx-ui-N-xxxxxx; start a new session (drgnx ui start)")))
    ;; anything else keeps the old message
    (should (string-search "is not a drgnx harness session"
                           (cadr (should-error (drgnx-ui-own-session "drgnx-ui-5x") :type 'drgnx-ui-refused))))
    ;; stop refuses a legacy name too; reap finds it, removes it and leaves a `reaped' tombstone
    (should-error (drgnx-ui-stop "drgnx-ui-5") :type 'drgnx-ui-refused)
    (should (equal (drgnx-ui-reap-targets root "" #'ignore) '("drgnx-ui-5")))
    (cl-letf (((symbol-function 'drgnx-ui--run) (lambda (&rest _) (cons 0 ""))))
      (should (member "drgnx-ui-5" (append (drgnx-ui-reap) nil))))
    (should-not (file-exists-p (expand-file-name "drgnx-ui-5" root)))
    (should (eq 'reaped (plist-get (car (read-from-string
                                         (drgnx-ui-test--slurp (expand-file-name "ended/drgnx-ui-5.eld" root))))
                                   :reason)))))

(ert-deftest drgnx-ui/a-session-json-with-another-id-is-refused ()
  (drgnx-ui-test--with-state
    (let* ((s (drgnx-ui-prepare-run "drgnx-ui-3-00000a" nil "1600x900"))
           (server (make-network-process :name "drgnx-ui-test-sock" :family 'local :server t
                                         :service (plist-get s :socket) :noquery t)))
      (unwind-protect
          (progn
            (should (equal (plist-get (drgnx-ui-own-session "drgnx-ui-3-00000a") :id) "drgnx-ui-3-00000a"))
            (let ((file (expand-file-name "session.json" (plist-get s :run))))
              (write-region (replace-regexp-in-string "\"id\":\"drgnx-ui-3-00000a\"" "\"id\":\"drgnx-ui-3-ffffff\""
                                                      (drgnx-ui-test--slurp file))
                            nil file nil 'silent))
            (should (string-search "names another session"
                                   (cadr (should-error (drgnx-ui-own-session "drgnx-ui-3-00000a")
                                                       :type 'drgnx-ui-refused)))))
        (delete-process server)))))

(ert-deftest drgnx-ui/every-call-carries-its-id ()
  (let (forms)
    (cl-letf (((symbol-function 'drgnx-ui--run-with-timeout)
               (lambda (_timeout &rest args) (push (cadr (member "-e" args)) forms) (list 0 "\"{}\""))))
      (drgnx-ui-call '(:name "drgnx-ui-1-abcdef" :socket "/x") "(drgnx-uitest-api-state)"))
    (should (string-prefix-p "(drgnx-uitest-api-as \"drgnx-ui-1-abcdef\" (drgnx-uitest-api-state)" (car forms)))))

(ert-deftest drgnx-ui/a-refusing-session-and-an-old-session-are-refusals ()
  ;; the session answers {"refused": …} for another id; a session started before the upgrade has no
  ;; `drgnx-uitest-api-as' at all
  (should (string-search "this session is a, not b"
                         (cadr (should-error (drgnx-ui-parse-reply (prin1-to-string "{\"refused\":\"this session is a, not b\"}"))
                                             :type 'drgnx-ui-refused))))
  (cl-letf (((symbol-function 'drgnx-ui--run-with-timeout)
             (lambda (&rest _) (list 1 "*ERROR*: Symbol’s function definition is void: drgnx-uitest-api-as\n"))))
    (should (string-search "harness upgraded"
                           (cadr (should-error (drgnx-ui-call '(:name "drgnx-ui-1-abcdef" :socket "/x") "(f)")
                                               :type 'drgnx-ui-refused))))))

(ert-deftest drgnx-ui/session-json-records-the-owner ()
  (drgnx-ui-test--with-state
    (let ((process-environment (append '("DRGNX_CHECK" "DRGNX_TEST_ISOLATED") process-environment))   ; unset
          (read-owner (lambda (name)
                        (let ((s (drgnx-ui-prepare-run name nil "1600x900")))
                          (plist-get (drgnx-ui--read-json (expand-file-name "session.json" (plist-get s :run)))
                                     :owner)))))
      (let ((json (drgnx-ui--read-json (expand-file-name "session.json"
                                                         (plist-get (drgnx-ui-prepare-run "drgnx-ui-1-00000a" nil "1600x900")
                                                                    :run)))))
        (should (equal (plist-get json :id) "drgnx-ui-1-00000a"))
        (let ((owner (plist-get json :owner)))
          (should (equal (plist-get owner :kind) "cli"))
          (should (eq (plist-get owner :pid) (emacs-pid)))
          (should (equal (plist-get owner :worktree) (directory-file-name drgnx-ui-repo-dir)))
          (should-not (stringp (plist-get owner :client)))))
      (let ((drgnx-ui-owner-kind 'mcp) (drgnx-ui-owner-client "0123456789abcdef"))
        (let ((owner (funcall read-owner "drgnx-ui-2-00000a")))
          (should (equal (plist-get owner :kind) "mcp"))
          (should (equal (plist-get owner :client) "0123456789abcdef"))))
      (let ((drgnx-ui-owner-kind 'mcp) (process-environment (cons "DRGNX_TEST_ISOLATED=1" process-environment)))
        (should (equal (plist-get (funcall read-owner "drgnx-ui-3-00000a") :kind) "test")))
      ;; the check wins over the test
      (let ((process-environment (append '("DRGNX_CHECK=1" "DRGNX_TEST_ISOLATED=1") process-environment)))
        (should (equal (plist-get (funcall read-owner "drgnx-ui-4-00000a") :kind) "check"))))))

(ert-deftest drgnx-ui/scenarios-pass-the-selector ()
  (drgnx-ui-test--with-state
    (let (env)
      (cl-letf (((symbol-function 'drgnx-ui-run-ert-session)
                 (lambda (_dir &optional _timeout _config extra-env) (setq env extra-env) (list 1 nil root))))
        (let ((process-environment (cons "DRGNX_TEST_SELECTOR=\"^drgnx-scn/\"" process-environment))
              (standard-output #'ignore))
          (drgnx-ui-run-scenarios "minimal" root)))
      (should (member "DRGNX_TEST_SELECTOR=\"^drgnx-scn/\"" env))
      (should (member "DRGNX_SCENARIO_CONFIG=minimal" env)))))

(defun drgnx-ui-test--env-value (env name)
  "The value of NAME in ENV (\"K=V\" strings) as `env -i' sees it: the last entry wins."
  (let (v) (dolist (kv env v) (when (string-prefix-p (concat name "=") kv) (setq v (substring kv (1+ (length name))))))))

(ert-deftest drgnx-ui/a-session-home-is-in-its-run ()
  (drgnx-ui-test--with-state
    (let* ((process-environment (cons "HOME=/home/not-the-sessions" process-environment))
           (s (drgnx-ui-prepare-run "drgnx-ui-1-00000a"))
           (env (drgnx-ui-session-env s)))
      (should (equal (drgnx-ui-test--env-value env "HOME") (expand-file-name "home" (plist-get s :run))))
      (should (file-directory-p (expand-file-name "home" (plist-get s :run))))
      (should-not (member "HOME" drgnx-ui-keep-env))
      (should (member (concat "HOME=" (expand-file-name "home" (plist-get s :run))) (drgnx-ui--client-env s)))
      (drgnx-ui-stop "drgnx-ui-1-00000a"))))

(ert-deftest drgnx-ui/a-session-never-sees-the-callers-xdg-dirs ()
  (drgnx-ui-test--with-state
    (let* ((process-environment (append '("XDG_CONFIG_HOME=/caller/c" "XDG_DATA_HOME=/caller/d" "XDG_CACHE_HOME=/caller/k"
                                          "XDG_STATE_HOME=/caller/s")
                                        process-environment))
           (s (drgnx-ui-prepare-run "drgnx-ui-1-00000a"))
           (run (plist-get s :run))
           (env (drgnx-ui-session-env s)))
      (dolist (n '("XDG_CONFIG_HOME" "XDG_DATA_HOME" "XDG_CACHE_HOME" "XDG_STATE_HOME"))
        (should (string-prefix-p run (drgnx-ui-test--env-value env n))))
      (should-not (seq-find (lambda (kv) (string-search "/caller/" kv)) env))
      (drgnx-ui-stop "drgnx-ui-1-00000a"))))

(ert-deftest drgnx-ui/the-gryphn-config-is-still-linked-read-only ()
  (drgnx-ui-test--with-state
    (let ((cfg (expand-file-name "cfg" root)))
      (make-directory (expand-file-name "lisp" cfg) t)
      (with-temp-file (expand-file-name "init.el" cfg) (insert ";; i\n"))
      (with-temp-file (expand-file-name "custom.el" cfg) (insert ";; c\n"))
      (let* ((s (drgnx-ui-prepare-run "drgnx-ui-1-00000a" cfg))
             (init (expand-file-name "init" (plist-get s :run))))
        (should (file-symlink-p (expand-file-name "lisp" init)))
        (should-not (file-symlink-p (expand-file-name "custom.el" init)))
        (should (file-exists-p (expand-file-name "custom.el" init)))
        (drgnx-ui-stop "drgnx-ui-1-00000a")))))

(ert-deftest drgnx-ui/the-tier-of-a-session-is-ui-unless-a-controller-says-so ()
  (should (eq drgnx-ui-session-tier 'ui))
  (drgnx-ui-test--with-state
    (let ((drgnx-ui-session-tier 'bench))
      (let* ((s (drgnx-ui-prepare-run "drgnx-ui-1-00000a")))
        ;; every tier's session gets the run's home and the dead bus
        (should (string-prefix-p (plist-get s :run)
                                 (drgnx-ui-test--env-value (drgnx-ui-session-env s) "HOME")))
        (should (string-prefix-p "unix:path=/nonexistent"
                                 (drgnx-ui-test--env-value (drgnx-ui-session-env s) "DBUS_SESSION_BUS_ADDRESS")))
        (drgnx-ui-stop "drgnx-ui-1-00000a")))))

;;;; Scales and sizes (Glitnir plan Task 7)

(ert-deftest drgnx-ui/scale-argv-mutter ()
  ;; mutter: gdctl sets one logical monitor per virtual monitor (Meta-N) before the session's Emacs is exec'd
  (drgnx-ui-test--with-state
    (let* ((s (drgnx-ui-prepare-run "drgnx-ui-7-00000a" nil "2880x1800" root nil 2 "mutter" '(1.25 2)))
           (argv (drgnx-ui-compositor-argv s))
           (script (nth (1+ (cl-position "-c" argv :test #'equal)) argv)))
      (should (equal (append (plist-get s :scales) nil) '(1.25 2)))
      (should (string-match-p "gdctl set" script))
      (should (string-match-p "--monitor Meta-0 --scale 1.25 --x 0" script))
      ;; the second monitor starts at the first's logical width: 2880 / 1.25
      (should (string-match-p "--monitor Meta-1 --scale 2 --x 2304" script))
      (should (string-match-p "exec \"\\$@\"" script))
      (should (member "--init-directory" argv)))
    ;; scale 1 everywhere: untouched argv, no gdctl
    (let* ((s (drgnx-ui-prepare-run "drgnx-ui-8-00000a" nil "1600x900" root))
           (argv (drgnx-ui-compositor-argv s)))
      (should-not (plist-get s :scales))
      (should-not (member "sh" argv)))))

(ert-deftest drgnx-ui/scale-gdctl-failure-is-loud ()
  ;; UI-SCALE-1: the image lacked gdctl's python3-gobject; every `gdctl set' failed, the loop gave up silently and
  ;; Emacs started at scale 1.  Now the last error is printed and the session's command never runs.
  (drgnx-ui-test--with-state
    (let* ((s (drgnx-ui-prepare-run "drgnx-ui-7-00000b" nil "2880x1800" root nil 1 "mutter" 2))
           (argv (drgnx-ui-compositor-argv s))
           (script (nth (1+ (cl-position "-c" argv :test #'equal)) argv))
           (bin (expand-file-name "fake-bin" root)))
      (make-directory bin t)
      ;; a `sleep' that returns at once: the 50 tries take no time
      (dolist (f '(("sleep" . "exit 0")
                   ("gdctl" . "echo 'Traceback (most recent call last):' >&2; echo \"ModuleNotFoundError: No module named 'gi'\" >&2; exit 1")))
        (with-temp-file (expand-file-name (car f) bin) (insert "#!/bin/sh\n" (cdr f) "\n"))
        (set-file-modes (expand-file-name (car f) bin) #o755))
      (let ((process-environment (cons (concat "PATH=" bin ":" (getenv "PATH")) process-environment)))
        (with-temp-buffer
          (should-not (eq 0 (call-process "sh" nil t nil "-c" script "sh" "echo" "EMACS-RAN")))
          (should (string-match-p "scale not applied: gdctl set failed .*No module named 'gi'" (buffer-string)))
          (should-not (string-search "EMACS-RAN" (buffer-string))))
        ;; gdctl works: the session's command runs
        (with-temp-file (expand-file-name "gdctl" bin) (insert "#!/bin/sh\nexit 0\n"))
        (with-temp-buffer
          (should (eq 0 (call-process "sh" nil t nil "-c" script "sh" "echo" "EMACS-RAN")))
          (should (string-search "EMACS-RAN" (buffer-string))))))))

(ert-deftest drgnx-ui/scale-sway-conf ()
  (drgnx-ui-test--with-state
    (cl-letf (((symbol-function 'drgnx-ui--check-compositor) #'ignore))
      (let* ((s (drgnx-ui-prepare-run "drgnx-ui-9-00000a" nil "1920x1080" root nil 2 "sway" '(2 1.25)))
             (conf (drgnx-ui-test--slurp (expand-file-name "sway.conf" (plist-get s :run)))))
        (should (string-match-p "^output HEADLESS-1 resolution 1920x1080 position 0 0$" conf))
        (should (string-match-p "^output HEADLESS-1 scale 2$" conf))
        (should (string-match-p "^output HEADLESS-2 scale 1.25$" conf))
        ;; the second output starts at the first's logical width: 1920 / 2
        (should (string-match-p "^output HEADLESS-2 resolution 1920x1080 position 960 0$" conf))))))

(ert-deftest drgnx-ui/scales-need-one-per-monitor ()
  (drgnx-ui-test--with-state
    (should-error (drgnx-ui-prepare-run "drgnx-ui-10-00000a" nil "1600x900" root nil 2 "mutter" '(1 2 3))
                  :type 'drgnx-ui-error)
    (should-error (drgnx-ui-prepare-run "drgnx-ui-11-00000a" nil "1600x900" root nil 1 "mutter" '(0))
                  :type 'drgnx-ui-error)
    ;; DRGNX_UI_SCALES: one per monitor; DRGNX_UI_SCALE: the same for all
    (let ((process-environment (cons "DRGNX_UI_SCALES=1 2" process-environment)))
      (should (equal (plist-get (drgnx-ui-prepare-run "drgnx-ui-12-00000a" nil "1600x900" root nil 2) :scales) [1 2]))
      (should-error (drgnx-ui-prepare-run "drgnx-ui-13-00000a" nil "1600x900" root nil 3) :type 'drgnx-ui-error))
    (let ((process-environment (cons "DRGNX_UI_SCALE=2" process-environment)))
      (should (equal (plist-get (drgnx-ui-prepare-run "drgnx-ui-14-00000a" nil "1600x900" root nil 2) :scales) [2 2])))
    ;; x11 has no monitor scale
    (should-error (drgnx-ui-prepare-run "drgnx-ui-15-00000a" nil "1600x900" root nil 1 "x11" '(2))
                  :type 'drgnx-ui-error)))

(ert-deftest drgnx-ui/size-from-env ()
  (drgnx-ui-test--with-state
    (let ((process-environment (cons "DRGNX_UI_SIZE=3840x2160" process-environment)))
      (should (equal (plist-get (drgnx-ui-prepare-run "drgnx-ui-16-00000a" nil nil root) :size) "3840x2160"))
      ;; a size given to start wins
      (should (equal (plist-get (drgnx-ui-prepare-run "drgnx-ui-17-00000a" nil "1024x768" root) :size) "1024x768")))
    (should (equal (plist-get (drgnx-ui-prepare-run "drgnx-ui-18-00000a" nil nil root) :size) "1600x900"))))

(ert-deftest drgnx-ui/fractional-scale-wait-condition ()
  ;; integer: the frame's factor is the scale
  (should (drgnx-uitest-scale-ready-p 2 "1600x900" 2 '(0 0 800 450)))
  (should-not (drgnx-uitest-scale-ready-p 2 "1600x900" 1 '(0 0 1600 900)))
  ;; fractional: GTK3 reports ceil(S) and a geometry of (WxH / S) * ceil(S): 2880x1800 at 1.25 -> 4608x2880
  (should (drgnx-uitest-scale-ready-p 1.25 "2880x1800" 2 '(0 0 4608 2880)))
  (should-not (drgnx-uitest-scale-ready-p 1.25 "2880x1800" 1 '(0 0 2880 1800)))
  (should-not (drgnx-uitest-scale-ready-p 1.25 "2880x1800" 2 '(0 0 2880 1800)))
  (should (drgnx-uitest-scale-ready-p 1.5 "1920x1080" 2 '(0 0 2560 1440))))
