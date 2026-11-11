;;; term-remote-test.el --- batch tests: the terminal in a remote folder (the command, folders, links, clipboard) -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'tramp)
(defvar drgnx-chrome-tab-icon)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-terminal" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-term" drgnx-dir) nil t)

(defmacro drgnx-term-remote-test--clean (&rest body)
  "BODY with no proxies of the user's or an earlier test's (multi-hop adds ad-hoc ones)."
  (declare (indent 0))
  `(let ((tramp-default-proxies-alist nil) (tramp-save-ad-hoc-proxies nil)) ,@body))

(defun drgnx-term-remote-test--decoded (shell line)
  "What the folder of LINE (a remote command line, as ssh hands it to the login shell) decodes to under SHELL: LINE
run by SHELL with its script cut before the `cd' and printing the folder instead."
  (let* ((cut (string-search "cd -- " line))
         (line (concat (substring line 0 cut) "printf %s \"$d\"'")))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (should (eql 0 (let ((coding-system-for-read 'binary)) (call-process shell nil t nil "-c" line))))
      (buffer-string))))

(ert-deftest drgnx-term-remote/ssh-command-with-port-user-and-folder ()
  (drgnx-term-remote-test--clean
    (let* ((cmd (drgnx-term-remote-command "/ssh:dev@build-box#2222:/srv/app/"))
           (line (car (last cmd))))
      (should (equal (butlast cmd) '("ssh" "-t" "-p" "2222" "-l" "dev" "build-box")))
      (should (string-prefix-p "exec /bin/sh -c '" line))
      (should (string-search "exec \"$s\" -l" line))
      ;; no control options from TRAMP: the user's ssh config decides
      (should-not (seq-find (lambda (a) (member a '("-o" "-S" "-M"))) cmd))
      (should (equal (drgnx-term-remote-host "/ssh:dev@build-box#2222:/srv/app/") "build-box")))))

(ert-deftest drgnx-term-remote/earlier-hops-are-jumps ()
  (drgnx-term-remote-test--clean
    (let ((cmd (drgnx-term-remote-command "/ssh:me@gate#2200|ssh:inner|ssh:box:/x/")))
      (should (equal (butlast cmd) '("ssh" "-t" "-J" "me@gate:2200,inner" "box")))
      (should (equal (drgnx-term-remote-host "/ssh:me@gate#2200|ssh:inner|ssh:box:/x/") "box")))))

(ert-deftest drgnx-term-remote/a-last-sudo-doas-or-su-hop-runs-on-the-host ()
  (drgnx-term-remote-test--clean
    (let ((sudo (car (last (drgnx-term-remote-command "/ssh:box|sudo:root@box:/etc/"))))
          (doas (car (last (drgnx-term-remote-command "/ssh:box|doas:ops@box:/etc/"))))
          (su (car (last (drgnx-term-remote-command "/ssh:box|su:ops@box:/etc/")))))
      (should (string-prefix-p "exec sudo -u root -H -- /bin/sh -c '" sudo))
      (should (string-prefix-p "exec doas -u ops /bin/sh -c '" doas))
      (should (string-prefix-p "exec su -l ops -s /bin/sh -c '" su))
      (should (equal (butlast (drgnx-term-remote-command "/ssh:box|sudo:root@box:/etc/")) '("ssh" "-t" "box")))
      (should (equal (drgnx-term-remote-host "/ssh:box|sudo:root@box:/etc/") "box")))))

(ert-deftest drgnx-term-remote/containers-and-methods-with-no-terminal ()
  (drgnx-term-remote-test--clean
    (let ((docker (drgnx-term-remote-command "/docker:web:/app/"))
          (podman (drgnx-term-remote-command "/podman:dev@db:/var/lib/")))
      (should (equal (butlast docker) '("docker" "exec" "-it" "-w" "/app/" "web" "/bin/sh" "-c")))
      (should (equal (butlast podman) '("podman" "exec" "-it" "-w" "/var/lib/" "-u" "dev" "db" "/bin/sh" "-c")))
      ;; the script goes to /bin/sh as one argument, not through a shell
      (should (string-prefix-p "d=" (car (last docker)))))
    (should-not (drgnx-term-remote-command "/ftp:host:/pub/"))
    (should-not (drgnx-term-remote-command "/sudo::/etc/"))
    (should-not (drgnx-term-remote-command "/tmp/"))))

(ert-deftest drgnx-term-remote/the-folder-survives-every-login-shell ()
  ;; a quote, `!', `$', a backslash, a newline and a non-ASCII name reach the host's sh as they are, whatever shell
  ;; parses the command line: none of them is in it
  (drgnx-term-remote-test--clean
    (should (equal (car (last (drgnx-term-remote-command "/ssh:box:/srv/my app/")))
                   (concat "exec " (drgnx-term-remote--sh (drgnx-term-remote-script "/srv/my app/"))))))
  (dolist (dir '("/srv/my app/" "/tmp/it's here/" "/x/a!b$c\\d`e\"f/" "/x/line\nbreak/" "/x/naïve 日本/" "/x/endx/"))
    (let ((line (concat "exec " (drgnx-term-remote--sh (drgnx-term-remote-script dir)))))
      (should (= 2 (cl-count ?' line)))
      (should-not (string-search "!" line))
      (should-not (string-search "\n" line))
      (dolist (shell '("sh" "bash" "zsh" "fish"))
        (should (equal (decode-coding-string (drgnx-term-remote-test--decoded shell line) 'utf-8) dir))))))

(ert-deftest drgnx-term-remote/the-ssh-gets-no-local-only-environment ()
  (let ((drgnx-term-env nil) (drgnx-term-term "xterm-ghostty")
        (process-environment (append '("EDITOR=emacsclient -s /x" "VISUAL=v" "GIT_EDITOR=g" "DRGNX_SERVER_NAME=/x"
                                       "LANG=C.UTF-8")
                                     process-environment)))
    (cl-letf (((symbol-function 'drgnx-term--terminfo) (lambda () "/terminfo")))
      (let* ((drgnx-term-ssh-terminfo 'fallback)
             (env (mapcar (lambda (e) (cons (aref e 0) (aref e 1))) (drgnx-term--remote-env))))
        (dolist (n '("EDITOR" "VISUAL" "GIT_EDITOR" "DRGNX_SERVER_NAME" "TERMINFO")) (should-not (assoc n env)))
        (should (equal (cdr (assoc "TERM" env)) "xterm-256color"))
        (should (equal (cdr (assoc "LANG" env)) "C.UTF-8")))
      (let* ((drgnx-term-ssh-terminfo 'install)
             (env (mapcar (lambda (e) (cons (aref e 0) (aref e 1))) (drgnx-term--remote-env))))
        (should-not (assoc "EDITOR" env))
        (should (equal (cdr (assoc "TERMINFO" env)) "/terminfo"))))))

(ert-deftest drgnx-term-remote/install-runs-ssh-through-the-terminfo-script ()
  (drgnx-term-remote-test--clean
    (let* ((drgnx-term-ssh-terminfo 'install)
           (plain (let ((drgnx-term-ssh-terminfo 'fallback)) (drgnx-term--remote-program "/ssh:dev@box:/srv/")))
           (cmd (drgnx-term--remote-program "/ssh:dev@box:/srv/")))
      (should (equal (seq-take cmd 2) (list "/bin/sh" (expand-file-name "etc/shell/drgnx-ssh-terminfo.sh" drgnx-dir))))
      (should (equal (nth 2 cmd) (car (last plain))))
      (should (equal (nthcdr 3 cmd) '("-l" "dev" "box")))
      (should (file-exists-p (nth 1 cmd)))
      ;; a container needs no terminfo on a host
      (should (equal (car (drgnx-term--remote-program "/docker:web:/app/")) "docker")))))

(ert-deftest drgnx-term-remote/folders-follow-the-host-not-a-nested-ssh ()
  (with-temp-buffer
    (setq drgnx-term--remote "/ssh:box:")
    (drgnx-term--cwd "file://box.lan/srv/app")
    (should (equal default-directory "/ssh:box:/srv/app/"))
    (should (equal drgnx-term--remote-host "box.lan"))
    ;; an ssh typed inside: another host's folder is not followed
    (drgnx-term--cwd "file://elsewhere/home/x")
    (should (equal default-directory "/ssh:box:/srv/app/"))
    (drgnx-term--cwd "kitty-shell-cwd://box.lan/srv/my app")
    (should (equal default-directory "/ssh:box:/srv/my app/"))
    ;; the record's first cwd is the local folder ssh started in, never the host's
    (drgnx-term--cwd "/home/me")
    (should (equal default-directory "/ssh:box:/srv/my app/"))))

(ert-deftest drgnx-term-remote/a-file-link-opens-the-remote-file ()
  (with-temp-buffer
    (setq drgnx-term--remote "/ssh:box:" drgnx-term--remote-host "box.lan")
    (should (equal (drgnx-term--link-file "file://box.lan/etc/hosts") "/ssh:box:/etc/hosts"))
    (should (equal (drgnx-term--link-file "file:///etc/my%20file") "/ssh:box:/etc/my file"))
    (should-not (drgnx-term--link-file (format "file://%s/etc/hosts" (system-name))))
    (setq drgnx-term--remote nil)
    (should (equal (drgnx-term--link-file "file:///etc/hosts") "/etc/hosts"))))

(ert-deftest drgnx-term-remote/the-clipboard-asks-allows-or-denies ()
  ;; `ask': a notice naming the host, never the text; Allow puts it on the clipboard, Deny drops it, Always adds the
  ;; host (written to the settings) so it is not asked again
  (let ((drgnx-term--buffers (make-hash-table :test #'equal)) (drgnx-term--notices nil) (drgnx-term--offered nil)
        (drgnx-term-remote-clipboard-hosts nil) (posted nil) (written nil) (kill-ring nil)
        (b (generate-new-buffer "*terminal*")))
    (cl-letf (((symbol-function 'drgnx-notice-set) (lambda (_s items &rest _) (setq posted items)))
              ((symbol-function 'drgnx-settings-file-put) (lambda (_f _h _s var value &rest _) (push (cons var value) written)))
              ((symbol-function 'drgnx-config-file) (lambda (&rest _) "/nowhere/settings.el"))
              ((symbol-function 'drgnx-term-buffers) (lambda () (list b))))
      (unwind-protect
          (with-current-buffer b
            (setq drgnx-term--remote "/ssh:box:" drgnx-term--remote-host "box" drgnx-term--id "t9")
            (let ((drgnx-term-remote-clipboard-write 'ask))
              (drgnx-term--remote-clipboard "s3cret")
              (should (equal (mapcar (lambda (i) (plist-get i :text)) posted) '("box wants to set the clipboard")))
              (should-not (string-search "s3cret" (format "%S" posted)))
              (should-not kill-ring)
              (drgnx-term--clipboard-answered b 'deny)
              (should-not kill-ring)
              (should-not posted)
              (drgnx-term--remote-clipboard "one")
              (drgnx-term--clipboard-answered b 'allow)
              (should (equal kill-ring '("one")))
              (drgnx-term--remote-clipboard "two")
              (drgnx-term--clipboard-answered b 'always)
              (should (equal drgnx-term-remote-clipboard-hosts '("box")))
              (should (equal written '((drgnx-term-remote-clipboard-hosts "box"))))
              (drgnx-term--remote-clipboard "three")
              (should (equal (car kill-ring) "three"))
              (should-not posted))
            (setq kill-ring nil drgnx-term-remote-clipboard-hosts nil)
            (let ((drgnx-term-remote-clipboard-write 'deny))
              (drgnx-term--remote-clipboard "no")
              (should-not kill-ring)
              (should-not posted)))
        (kill-buffer b)))))

(ert-deftest drgnx-term-remote/a-lost-connection-keeps-the-buffer-with-reconnect ()
  (let ((drgnx-term--buffers (make-hash-table :test #'equal)) (opened nil)
        (b (generate-new-buffer "*terminal*")))
    (cl-letf (((symbol-function 'drgnx-term--open) (lambda (buf) (push buf opened))))
      (unwind-protect
          (with-current-buffer b
            (drgnx-term-mode)
            (setq drgnx-term--remote "/ssh:box:" drgnx-term--shell t drgnx-term--id "t1" drgnx-term--state 'open)
            (puthash "t1" b drgnx-term--buffers)
            (drgnx-term--exited (list :code 255))
            (should (buffer-live-p b))
            (should (string-search "Connection lost (exit 255)" (car header-line-format)))
            (drgnx-term-reconnect)
            (should (equal opened (list b)))
            (should-not header-line-format))
        (with-current-buffer b (setq drgnx-term--state 'exited))
        (kill-buffer b)))))

(ert-deftest drgnx-term-remote/a-reattached-remote-terminal-knows-its-host ()
  (let ((sent nil) (b nil))
    (cl-letf (((symbol-function 'drgnx-hub--call-on) (lambda (_c m p _f) (push (cons m p) sent))))
      (unwind-protect
          (progn
            (setq b (drgnx-term-reattach-one (list :id "r1" :remote "/ssh:box:" :cwd "file://box/srv/app"
                                                   :command ["ssh" "-t" "box" "exec /bin/sh -c 'x'"] :title "")))
            (with-current-buffer b
              (should (equal drgnx-term--remote "/ssh:box:"))
              (should (equal default-directory "/ssh:box:/srv/app/"))
              (should drgnx-term--shell)
              (should (equal (buffer-name) "*terminal: box*"))
              (should (eq drgnx-chrome-tab-icon 'server)))
            (should (equal (caar sent) "term/attach")))
        (when (buffer-live-p b)
          (with-current-buffer b (setq drgnx-term--state 'exited))
          (kill-buffer b))))))

(ert-deftest drgnx-term-remote/a-remote-folder-is-usable-when-a-command-reaches-it ()
  (drgnx-term-remote-test--clean
    (cl-letf (((symbol-function 'drgnx-modules--ok-p) (lambda (_) t)))
      (should (drgnx-term-usable-p "/ssh:box:/srv/"))
      (should-not (drgnx-term-usable-p "/ftp:box:/pub/"))
      (should (drgnx-term-usable-p "/tmp/")))))

(provide 'term-remote-test)
;;; term-remote-test.el ends here
