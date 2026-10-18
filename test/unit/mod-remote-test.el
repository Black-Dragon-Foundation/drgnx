;;; mod-remote-test.el --- batch tests: Open Remote…, the remote segment, Reconnect, language servers on the remote side -*- lexical-binding: t -*-
;; No real host is reached: the TRAMP method `drgnx-mock' (test/fixtures/tramp-mock.el) logs in with a local sh, and
;; the "hosts" and "containers" are a temp HOME's ssh config and a fake `podman' script on a temp PATH.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-registry)
(require 'eglot)
(load (expand-file-name "test/fixtures/tramp-mock" drgnx-dir) nil t)
(load (expand-file-name "modules/lang/drgnx-lang" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-remote" drgnx-dir) nil t)
(defvar drgnx-remote-test--answers nil "The answers `completing-read' gives, in order.")

(defun drgnx-remote-test--script (dir name body)
  "An executable shell script NAME with BODY in DIR; its file name."
  (let ((file (expand-file-name name dir)))
    (with-temp-file file (insert "#!/bin/sh\n" body "\n"))
    (set-file-modes file #o755)
    file))

(defmacro drgnx-remote-test--with (&rest body)
  "BODY with the mock method set up, `dir' a temp directory holding `bin/drgnx-lsp' (a language server the \"remote\"
finds) and `src/', no roots, no probes, no hints, the language-server switch off the environment, and everything
closed afterwards.  The servers eglot knows are four invented ones, so the machine's own tools do not decide a
test: python-mode runs `drgnx-lsp', python-ts-mode the first found of two, rust-mode one nobody has, c-mode a
choice of two nobody has."
  (declare (indent 0))
  `(let* ((dir (file-name-as-directory (make-temp-file "drgnx-remote" t)))
          (bin (expand-file-name "bin" dir))
          (process-environment (cons "DRGNX_NO_LANGUAGE_SERVERS" process-environment))
          (tramp-remote-path (cons bin tramp-remote-path))
          (eglot-server-programs `((python-mode . ("drgnx-lsp" "--stdio"))
                                   (python-ts-mode . ,(eglot-alternatives '("drgnx-nope" "drgnx-lsp")))
                                   (rust-mode . ("drgnx-lsp-missing"))
                                   (c-mode . ,(eglot-alternatives '("drgnx-nope-1" "drgnx-nope-2")))))
          (create-lockfiles nil)
          (drgnx-remote--roots nil)
          (drgnx-lang--remote-servers (make-hash-table :test #'equal))
          (drgnx-lang--remote-wanted (make-hash-table :test #'equal))
          (drgnx-lang--remote-hinted nil)
          (explorer-roots nil)
          (messages nil))
     (make-directory bin) (make-directory (expand-file-name "src" dir))
     (drgnx-remote-test--script bin "drgnx-lsp" "exit 0")
     (drgnx-tramp-mock-setup)
     (cl-letf (((symbol-function 'drgnx-explorer-roots) (lambda () explorer-roots))
               ((symbol-function 'message) (lambda (fmt &rest args) (when fmt (push (apply #'format fmt args) messages)) nil)))
       (unwind-protect (progn ,@body)
         (dolist (b (buffer-list))
           (when (and (buffer-file-name b) (file-remote-p (buffer-file-name b)))
             (with-current-buffer b (set-buffer-modified-p nil))
             (kill-buffer b)))
         (drgnx-tramp-mock-teardown)
         (delete-directory dir t)))))

(defun drgnx-remote-test--lose (root)
  "Kill the connection of ROOT, as a network drop would, and wait until Emacs sees it dead."
  (let ((proc (tramp-get-connection-process (tramp-dissect-file-name root))))
    (kill-process proc)
    (with-timeout (5 (error "the connection process did not die"))
      (while (process-live-p proc) (accept-process-output nil 0.05)))))

(defun drgnx-remote-test--root (dir)
  "The mock-remote name of DIR's src/ folder, as TRAMP spells it once it knows the host."
  (expand-file-name (drgnx-tramp-mock-name (expand-file-name "src/" dir))))

(defun drgnx-remote-test--code-buffer (name)
  "A buffer that looks like the remote file NAME, in Python mode (nothing is read or visited)."
  (let ((b (generate-new-buffer " *drgnx-remote-code*")))
    (with-current-buffer b
      (require 'python)
      (setq buffer-file-name name default-directory (file-name-directory name) major-mode 'python-mode))
    b))

;;;; Hosts and containers

(ert-deftest drgnx-remote/ssh-hosts-from-config ()
  (let* ((home (make-temp-file "drgnx-home" t))
         (ssh (expand-file-name ".ssh" home))
         (process-environment (cons (concat "HOME=" home) process-environment)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "conf.d" ssh) t)
          (with-temp-file (expand-file-name "config" ssh)
            (insert "# my hosts\nHost a b\n  HostName 10.0.0.1\nhost   *\n  User me\nHost !c d* e? f\nInclude extra.conf\n"
                    "Include conf.d/*.conf\nHost=g\n"))
          (with-temp-file (expand-file-name "extra.conf" ssh) (insert "Host x\nInclude nested.conf\nHost y # comment\n"))
          (with-temp-file (expand-file-name "nested.conf" ssh) (insert "Host never\n"))
          (with-temp-file (expand-file-name "conf.d/one.conf" ssh) (insert "Host z\n"))
          (should (equal (drgnx-remote-ssh-hosts) '("a" "b" "f" "g" "x" "y" "z"))))
      (delete-directory home t))))

(ert-deftest drgnx-remote/no-ssh-config-no-hosts ()
  (let* ((home (make-temp-file "drgnx-home" t)) (process-environment (cons (concat "HOME=" home) process-environment)))
    (unwind-protect (should-not (drgnx-remote-ssh-hosts)) (delete-directory home t))))

(ert-deftest drgnx-remote/containers-from-podman ()
  (let* ((bin (make-temp-file "drgnx-podman" t))
         (exec-path (list bin)) (process-environment (cons (concat "PATH=" bin) process-environment)))
    (unwind-protect
        (progn
          (should-not (drgnx-remote-containers))                         ; no podman: nil
          (drgnx-remote-test--script bin "podman" "[ \"$*\" = 'ps --format {{.Names}}' ] && printf 'web\\ndb\\n'")
          (should (equal (drgnx-remote-containers) '("web" "db")))
          (drgnx-remote-test--script bin "podman" "exec sleep 30")            ; a podman that hangs: nil after the limit
          (let ((drgnx-remote-podman-timeout 0.3) (start (float-time)))
            (should-not (drgnx-remote-containers))
            (should (< (- (float-time) start) 5))))
      (delete-directory bin t))))

;;;; Open Remote…

(ert-deftest drgnx-remote/open-sets-the-root ()
  (drgnx-remote-test--with
    (let* ((root (drgnx-remote-test--root dir)) (calls nil))
      (cl-letf (((symbol-function 'drgnx-session-open-folder) (lambda (d) (push (list 'open d) calls) (setq explorer-roots (list d))))
                ((symbol-function 'drgnx-lang-probe-remote) (lambda (d) (push (list 'probe d) calls) nil)))
        (drgnx-remote-open-folder root))
      (should (equal (reverse calls) (list (list 'open root) (list 'probe root))))   ; the folder first, then the probe
      (should (equal (plist-get (cdr (assoc (file-remote-p root) drgnx-remote--roots)) :root) root))
      (should (equal (drgnx-remote-segment) "⇄ localhost")))))

(ert-deftest drgnx-remote/open-offers-hosts-and-containers ()
  (drgnx-remote-test--with
    (let ((asked nil) (opened nil))
      (cl-letf (((symbol-function 'drgnx-remote-ssh-hosts) (lambda () '("alpha")))
                ((symbol-function 'drgnx-remote-containers) (lambda () '("web")))
                ((symbol-function 'completing-read) (lambda (_p coll &rest _) (push (copy-sequence coll) asked) (pop drgnx-remote-test--answers)))
                ((symbol-function 'read-directory-name) (lambda (_p start &rest _) start))
                ((symbol-function 'read-string) (lambda (&rest _) "me@other"))
                ((symbol-function 'drgnx-remote-open-folder) (lambda (d) (push d opened))))
        (let ((drgnx-remote-test--answers (list "ssh: alpha" "podman: web" "Other host…")))
          (drgnx-remote-open) (drgnx-remote-open) (drgnx-remote-open))
        (should (equal (car asked) '("ssh: alpha" "podman: web" "Other host…")))
        (should (equal (reverse opened) '("/ssh:alpha:~/" "/podman:web:/" "/ssh:me@other:~/")))))))

;;;; Language servers on the remote side

(ert-deftest drgnx-remote/probe-finds-and-misses ()
  (drgnx-remote-test--with
    (let* ((root (drgnx-remote-test--root dir)) (result (drgnx-lang-probe-remote root)))
      (should (equal (gethash (file-remote-p root) drgnx-lang--remote-servers) result))
      (should (equal (mapcar #'car result) '(python-mode python-ts-mode rust-mode c-mode)))
      (should (equal (cdr (assq 'python-mode result)) "drgnx-lsp"))
      (should (string-suffix-p "drgnx-lsp" (cdr (assq 'python-ts-mode result))))   ; the function found it on the host
      (should-not (cdr (assq 'rust-mode result)))
      (should-not (cdr (assq 'c-mode result)))
      (should (equal (cdr (assq 'c-mode (gethash (file-remote-p root) drgnx-lang--remote-wanted))) "drgnx-nope-1")))))

(ert-deftest drgnx-remote/eglot-starts-when-the-probe-found-it ()
  (drgnx-remote-test--with
    (let* ((root (drgnx-remote-test--root dir)) (started 0)
           (b (drgnx-remote-test--code-buffer (concat root "app.py"))))
      (drgnx-lang-probe-remote root)
      (cl-letf (((symbol-function 'eglot-ensure) (lambda () (cl-incf started))))
        (with-current-buffer b (drgnx-lang--maybe-eglot))
        (should (= started 1))
        (should-not messages)
        ;; the connection is lost: nothing automatic tries to reach it again, the user's Reconnect does
        (drgnx-remote-test--lose root)
        (with-current-buffer b (drgnx-lang--maybe-eglot))
        (should (= started 1))))))

(ert-deftest drgnx-remote/hint-when-not-installed ()
  (drgnx-remote-test--with
    (let* ((root (drgnx-remote-test--root dir)) (started 0)
           (b (drgnx-remote-test--code-buffer (concat root "app.py"))))
      (delete-file (expand-file-name "drgnx-lsp" bin))
      (drgnx-lang-probe-remote root)
      (cl-letf (((symbol-function 'eglot-ensure) (lambda () (cl-incf started))))
        (with-current-buffer b (drgnx-lang--maybe-eglot) (drgnx-lang--maybe-eglot))
        (should (= started 0))
        (should (equal messages '("No language server for python-mode on localhost: install drgnx-lsp there")))   ; once
        (with-current-buffer b (setq major-mode 'rust-mode) (drgnx-lang--maybe-eglot))   ; another mode: another hint
        (should (= (length messages) 2))
        (should (string-match-p "rust-mode on localhost: install drgnx-lsp-missing there" (car messages)))
        (with-current-buffer b (setq major-mode 'c-mode) (drgnx-lang--maybe-eglot))     ; a choice: the first it tries
        (should (string-match-p "c-mode on localhost: install drgnx-nope-1 there" (car messages)))
        (with-current-buffer b (setq major-mode 'org-mode) (drgnx-lang--maybe-eglot))   ; no entry for the mode: silence
        (should (= (length messages) 3))))))

(ert-deftest drgnx-remote/hook-never-probes ()
  (drgnx-remote-test--with
    (let* ((root (drgnx-remote-test--root dir)) (started 0)
           (b (drgnx-remote-test--code-buffer (concat root "app.py"))))
      (should (file-directory-p root))                                   ; connected by the user's command
      (setq drgnx-tramp-mock-sends 0)
      (cl-letf (((symbol-function 'eglot-ensure) (lambda () (cl-incf started))))
        (with-current-buffer b (drgnx-lang--maybe-eglot)))
      (should (= drgnx-tramp-mock-sends 0))                              ; never probed: nothing sent, nothing started
      (should (= started 0))
      (should-not messages)
      (should (zerop (hash-table-count drgnx-lang--remote-servers))))))

(ert-deftest drgnx-remote/local-files-keep-the-old-rule ()
  (let ((started 0) (file (make-temp-file "drgnx-lang" nil ".py")))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-lang-server-available-p) (lambda () t))
                  ((symbol-function 'eglot-ensure) (lambda () (cl-incf started))))
          (let ((process-environment (cons "DRGNX_NO_LANGUAGE_SERVERS" process-environment)))
            (with-current-buffer (find-file-noselect file)
              (drgnx-lang--maybe-eglot)
              (set-buffer-modified-p nil) (kill-buffer)))
          (should (= started 1)))
      (delete-file file))))

;;;; The segment

(ert-deftest drgnx-remote/segment-states-without-io ()
  (drgnx-remote-test--with
    (let ((root (drgnx-remote-test--root dir)))
      (with-temp-buffer
        (should (equal (drgnx-remote-segment) ""))                       ; nothing remote: no segment
        (cl-letf (((symbol-function 'drgnx-session-open-folder) (lambda (d) (setq explorer-roots (list d)))))
          (drgnx-remote-open-folder root))
        (setq drgnx-tramp-mock-sends 0)
        (let ((s (drgnx-remote-segment)))
          (should (equal (substring-no-properties s) "⇄ localhost"))
          (should (eq (get-text-property 0 'face s) 'drgnx-remote-connected))
          (should (keymapp (get-text-property 0 'local-map s))))
        (drgnx-remote-test--lose root)
        (setq drgnx-tramp-mock-sends 0)
        (should (eq (get-text-property 0 'face (drgnx-remote-segment)) 'drgnx-remote-lost))
        (drgnx-remote-segment) (drgnx-remote-segment)
        (should (= drgnx-tramp-mock-sends 0))                            ; no connection, no command: reading is no I/O
        (setq explorer-roots nil)
        (should (equal (drgnx-remote-segment) ""))                       ; the folder was closed
        (setq default-directory root)                                    ; a remote buffer shows it too
        (should (equal (substring-no-properties (drgnx-remote-segment)) "⇄ localhost"))
        (should (= drgnx-tramp-mock-sends 0))))
    (should (face-documentation 'drgnx-remote-connected))
    (should (memq 'success (ensure-list (face-attribute 'drgnx-remote-connected :inherit))))
    (should (memq 'warning (ensure-list (face-attribute 'drgnx-remote-lost :inherit))))))

(ert-deftest drgnx-remote/segment-ascii-in-a-terminal ()
  (drgnx-remote-test--with
    (let ((root (drgnx-remote-test--root dir)))
      (setq explorer-roots (list root)
            drgnx-remote--roots (list (cons (file-remote-p root) (list :root root))))
      (cl-letf (((symbol-function 'char-displayable-p) (lambda (_) nil)))
        (should (equal (substring-no-properties (drgnx-remote-segment)) "<> localhost")))
      (cl-letf (((symbol-function 'char-displayable-p) (lambda (_) t)))
        (should (equal (substring-no-properties (drgnx-remote-segment)) "⇄ localhost"))))))

;;;; Reconnect

(ert-deftest drgnx-remote/reconnect-keeps-buffers ()
  (drgnx-remote-test--with
    (let* ((root (drgnx-remote-test--root dir)) (started 0)
           (file (concat root "app.py")) (prog-mode-hook nil) (python-mode-hook nil)
           (vec (tramp-dissect-file-name root)))
      (with-temp-file (expand-file-name "src/app.py" dir) (insert "print(1)\n"))
      (cl-letf (((symbol-function 'drgnx-session-open-folder) (lambda (d) (setq explorer-roots (list d))))
                ((symbol-function 'eglot-ensure) (lambda () (cl-incf started))))
        (drgnx-remote-open-folder root)
        (let ((b (find-file-noselect file)))
          (with-current-buffer b
            (goto-char (point-max)) (insert "print(2)\n") (goto-char 4)
            (should (buffer-modified-p)))
          (drgnx-remote-test--lose root)
          (should (eq (get-text-property 0 'face (drgnx-remote-segment)) 'drgnx-remote-lost))
          (setq started 0)
          (drgnx-remote-reconnect (file-remote-p root))
          (should (buffer-live-p b))
          (with-current-buffer b
            (should (buffer-modified-p))
            (should (equal (buffer-string) "print(1)\nprint(2)\n"))
            (should (= (point) 4)))
          (should (process-live-p (tramp-get-connection-process vec)))
          (should (eq (get-text-property 0 'face (drgnx-remote-segment)) 'drgnx-remote-connected))
          (should (= started 1)))))))

(ert-deftest drgnx-remote/reconnect-shuts-servers-down-without-killing-buffers ()
  (drgnx-remote-test--with
    (let* ((root (drgnx-remote-test--root dir)) (shut nil))
      (setq explorer-roots (list root) drgnx-remote--roots (list (cons (file-remote-p root) (list :root root))))
      (cl-letf (((symbol-function 'drgnx-remote--servers) (lambda (_key) '(server-a server-b)))
                ((symbol-function 'eglot-shutdown) (lambda (s &optional _i _timeout preserve) (push (list s preserve) shut))))
        (drgnx-remote-reconnect (file-remote-p root)))
      (should (equal (reverse shut) '((server-a t) (server-b t)))))))

(ert-deftest drgnx-remote/reconnect-asks-only-when-several ()
  (drgnx-remote-test--with
    (let ((a "/drgnx-mock:localhost:/tmp/a/") (b "/ssh:other:/srv/b/") (asked nil))
      (cl-letf (((symbol-function 'completing-read) (lambda (_p coll &rest _) (setq asked t) (car coll))))
        (setq explorer-roots (list a))
        (with-temp-buffer (should (equal (drgnx-remote--pick) (file-remote-p a))))
        (should-not asked)
        (setq explorer-roots (list a b))
        (with-temp-buffer (should (drgnx-remote--pick)))
        (should asked)
        (setq asked nil)
        (with-temp-buffer (setq default-directory b)                     ; the buffer's own remote needs no question
                          (should (equal (drgnx-remote--pick) (file-remote-p b))))
        (should-not asked))
      (setq explorer-roots nil)
      (with-temp-buffer (should-error (drgnx-remote--pick) :type 'user-error)))))

;;;; The commands

(ert-deftest drgnx-remote/commands-are-in-the-registry-and-every-profile ()
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
        (global-mode-string nil))
    (unwind-protect
        (progn
          (funcall (plist-get (alist-get 'tools/remote drgnx-modules--table) :setup))
          (dolist (id '(remote-open remote-reconnect))
            (should (equal (drgnx-cmd-category (drgnx-commands-get id)) "Remote")))
          (should (equal (drgnx-cmd-title (drgnx-commands-get 'remote-open)) "Open Remote…"))
          (should (equal (drgnx-cmd-title (drgnx-commands-get 'remote-reconnect)) "Reconnect"))
          (should (= 1 (seq-count (lambda (e) (and (consp e) (eq (car e) :eval))) global-mode-string))))
      (setq global-mode-string nil))
    (dolist (profile '("vscode" "emacs" "vim"))
      (let ((text (with-temp-buffer (insert-file-contents (expand-file-name (format "keys/%s.eld" profile) drgnx-dir)) (buffer-string))))
        (dolist (id '("remote-open" "remote-reconnect"))
          (should (string-match-p (concat "(" id " ") text)))))))

;;; mod-remote-test.el ends here
