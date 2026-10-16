;;; drgnx-ui-test.el --- batch tests: harness session controller -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-ui)
(require 'drgnx-uitest)

(defmacro drgnx-ui-test--with-state (&rest body)
  "Run BODY with `root' bound to a fresh DRGNX_UI_STATE directory."
  (declare (indent 0))
  `(let* ((root (make-temp-file "drgnx-ui-state" t))
          (runtime (expand-file-name "xdg-runtime" root))
          (process-environment (append (list (concat "DRGNX_UI_STATE=" root)
                                             (concat "XDG_RUNTIME_DIR=" runtime))
                                       process-environment)))
     (make-directory runtime)
     (set-file-modes runtime #o700)
     (unwind-protect (progn ,@body) (delete-directory root t))))

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

(ert-deftest drgnx-ui/next-name-skips-taken-wayland-displays ()
  (drgnx-ui-test--with-state
    (write-region "" nil (expand-file-name "drgnx-ui-1" runtime))
    (should (equal (drgnx-ui-next-name root) "drgnx-ui-2"))))

(ert-deftest drgnx-ui/stop-removes-the-wayland-display-socket ()
  (drgnx-ui-test--with-state
    (drgnx-ui-prepare-run "drgnx-ui-4")
    (dolist (f '("drgnx-ui-4" "drgnx-ui-4.lock")) (write-region "" nil (expand-file-name f runtime)))
    (drgnx-ui-stop "drgnx-ui-4")
    (should-not (file-exists-p (expand-file-name "drgnx-ui-4" runtime)))
    (should-not (file-exists-p (expand-file-name "drgnx-ui-4.lock" runtime)))))

(ert-deftest drgnx-ui/process-groups-are-verified-before-signalling ()
  (should-not (drgnx-ui--group-ours-p "1" "/any/run"))
  (should-not (drgnx-ui--group-ours-p "0" "/any/run"))
  (should-not (drgnx-ui--group-ours-p nil "/any/run"))
  (should-not (drgnx-ui--group-ours-p (number-to-string (emacs-pid)) "/not/this/run/drgnx-ui-1")))

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
