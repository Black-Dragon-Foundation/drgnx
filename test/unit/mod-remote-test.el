;;; mod-remote-test.el --- batch tests: Open Remote…, the remote segment, Reconnect, language servers on the remote side -*- lexical-binding: t -*-
;; No real host is reached: the TRAMP method `drgnx-mock' (test/fixtures/tramp-mock.el) logs in with a local sh, and
;; the "hosts" and "containers" are a temp HOME's ssh config and a fake `podman' script on a temp PATH.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-registry)
(require 'drgnx-explorer)
(require 'eglot)
(require 'python)
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
finds: test/fixtures/lsp-stub.sh) and `src/', no roots, no probes, no hints, the language-server switch off the environment, and everything
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
          (drgnx-lang--remote-pending nil)
          (drgnx-lang--user-command nil)
          (drgnx-remote-may-prompt nil)
          (explorer-roots nil)
          (messages nil))
     (make-directory bin) (make-directory (expand-file-name "src" dir))
     (copy-file (expand-file-name "test/fixtures/lsp-stub.sh" drgnx-dir) (expand-file-name "drgnx-lsp" bin))
     (set-file-modes (expand-file-name "drgnx-lsp" bin) #o755)
     (drgnx-tramp-mock-setup)
     (drgnx-lang--install-eglot-guards)                           ; the production guards, as the lang module's setup puts them
     (cl-letf (((symbol-function 'drgnx-explorer-roots) (lambda () explorer-roots))
               ((symbol-function 'message) (lambda (fmt &rest args) (when fmt (push (apply #'format fmt args) messages)) nil)))
       (unwind-protect (progn ,@body)
         (drgnx-lang--teardown-eglot-guards)
         (when (boundp 'eglot--servers-by-project)
           (maphash (lambda (_ servers) (dolist (s servers) (ignore-errors (eglot-shutdown s nil 1 t))))
                    eglot--servers-by-project))
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
          (make-directory (expand-file-name "conf.d/folder.conf" ssh))            ; a glob also matches a folder: not a config
          (should (equal (drgnx-remote-ssh-hosts) '("a" "b" "f" "g" "x" "y" "z"))))
      (delete-directory home t))))

(ert-deftest drgnx-remote/no-ssh-config-no-hosts ()
  (let* ((home (make-temp-file "drgnx-home" t)) (process-environment (cons (concat "HOME=" home) process-environment)))
    (unwind-protect (should-not (drgnx-remote-ssh-hosts)) (delete-directory home t))))

(ert-deftest drgnx-remote/containers-from-podman ()
  (let* ((sleep (executable-find "sleep")) (bin (make-temp-file "drgnx-podman" t))
         (exec-path (list bin)) (process-environment (cons (concat "PATH=" bin) process-environment)))
    (unwind-protect
        (progn
          (should-not (drgnx-remote-containers))                         ; no podman: nil
          (drgnx-remote-test--script bin "podman" "[ \"$*\" = 'ps --format {{.Names}}' ] && printf 'web\\ndb\\n'")
          (should (equal (drgnx-remote-containers) '("web" "db")))
          (drgnx-remote-test--script bin "podman" (concat "exec " sleep " 30"))   ; a podman that hangs: nil at the limit
          (let ((drgnx-remote-podman-timeout 0.5) (start (float-time)))
            (should-not (drgnx-remote-containers))
            (should (>= (- (float-time) start) 0.5))
            (should (< (- (float-time) start) 3))
            (should-not (seq-filter (lambda (p) (string-prefix-p "drgnx-podman" (process-name p))) (process-list)))))
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

(ert-deftest drgnx-remote/probe-is-one-shell-call ()
  ;; forty more entries: asking the host once per program and PATH folder would be hundreds of round trips
  (drgnx-remote-test--with
    (let ((eglot-server-programs (append eglot-server-programs
                                         (cl-loop for i below 40 collect (cons (intern (format "x%d-mode" i))
                                                                               (list (format "drgnx-none-%d" i))))))
          (root (drgnx-remote-test--root dir)))
      (should (file-directory-p root))                                  ; the connection's own set-up is not the probe's
      (setq drgnx-tramp-mock-sends 0)
      (drgnx-lang-probe-remote root)
      (should (< drgnx-tramp-mock-sends 8)))))

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

(ert-deftest drgnx-remote/a-server-starts-in-a-users-command-only ()
  (drgnx-remote-test--with
    (let* ((root (drgnx-remote-test--root dir)) (connects 0)
           (b (drgnx-remote-test--code-buffer (concat root "app.py"))))
      (drgnx-lang-probe-remote root)
      (cl-letf (((symbol-function 'eglot--connect) (lambda (&rest _) (cl-incf connects))))
        (with-current-buffer b
          (drgnx-lang--maybe-eglot)                                   ; a timer, a process, a restored session
          (should (= connects 0))
          (let ((drgnx-lang--user-command t))                         ; a command of the user is running
            (drgnx-lang--maybe-eglot)
            (should (= connects 1))
            (should (eq drgnx-lang--user-command t))                  ; a start does not use the command up
            (drgnx-lang--maybe-eglot)                                 ; the same project again: no second server
            (should (= connects 1)))
          (drgnx-remote-test--lose root)                              ; the connection is lost: even a command waits
          (setq drgnx-lang--remote-pending nil)
          (let ((drgnx-lang--user-command t)) (drgnx-lang--maybe-eglot))
          (should (= connects 1)))
        (should-not messages)))))

(ert-deftest drgnx-remote/visiting-outside-a-command-starts-nothing ()
  (drgnx-remote-test--with
    (let* ((root (drgnx-remote-test--root dir)) (connects 0) (prog-mode-hook nil) (python-mode-hook nil)
           (visit (lambda (name) (let ((before drgnx-tramp-mock-sends))
                                   (kill-buffer (find-file-noselect (concat root name)))
                                   (- drgnx-tramp-mock-sends before)))))
      (dolist (n '("warm.py" "a.py" "b.py" "c.py")) (with-temp-file (expand-file-name n (concat dir "src")) (insert "x = 1\n")))
      (drgnx-lang-probe-remote root)
      (funcall visit "warm.py")
      (let ((plain (funcall visit "a.py")))                         ; what a visit costs by itself
        (cl-letf (((symbol-function 'eglot--connect) (lambda (&rest _) (cl-incf connects))))
          (setq prog-mode-hook (list #'drgnx-lang--maybe-eglot)) ; python-mode or python-ts-mode: both are prog modes
          (should (= (funcall visit "b.py") plain))                  ; the hook adds nothing
          (should (= connects 0))
          (let ((drgnx-lang--user-command t))                         ; the user's command visits a file: one start
            (funcall visit "c.py")
            (should (= connects 1))))))))

(ert-deftest drgnx-remote/a-remote-server-is-never-reconnected-by-eglot ()
  ;; eglot reconnects a server that dies after `eglot-autoreconnect' seconds from its process sentinel, and TRAMP
  ;; would log in again there: a prompt, from nowhere.  A real (stub) server on the mock host.
  (drgnx-remote-test--with
    (let* ((root (drgnx-remote-test--root dir)) (connects 0) (prog-mode-hook nil) (python-mode-hook nil)
           (eglot-autoreconnect 1) (eglot-sync-connect nil)
           (eglot-connect-hook (cons #'drgnx-lang--no-remote-autoreconnect eglot-connect-hook))
           (wait (lambda (secs) (let ((end (+ (float-time) secs))) (while (< (float-time) end) (accept-process-output nil 0.1))))))
      (with-temp-file (expand-file-name "src/app.py" dir) (insert "x = 1\n"))
      (drgnx-lang-probe-remote root)
      (advice-add 'eglot--connect :before (lambda (&rest _) (cl-incf connects)) '((name . drgnx-remote-test)))
      (unwind-protect
          (with-current-buffer (find-file-noselect (concat root "app.py"))
            (should (or (drgnx-lang-start-remote-server) (error "not started: %S" messages)))
            (with-timeout (15 (error "the stub server did not connect: %S" messages))
              (while (not (eglot-current-server)) (accept-process-output nil 0.1)))
            (let ((server (eglot-current-server)))
              (should (eq (eieio-oref server 'inhibit-autoreconnect) t))   ; not the timer eglot set
              (funcall wait 1.5)                                         ; past the 1 s window: eglot would reconnect
              (kill-process (jsonrpc--process server))
              (with-timeout (5 (error "the server did not die")) (while (jsonrpc-running-p server) (accept-process-output nil 0.1)))
              (setq drgnx-tramp-mock-sends 0)
              (funcall wait 1.5)
              (should (= connects 1))
              (should (= drgnx-tramp-mock-sends 0))))
        (advice-remove 'eglot--connect 'drgnx-remote-test)))))

(ert-deftest drgnx-remote/the-reconnect-hook-leaves-local-servers-alone ()
  (let ((server (make-symbol "local-server")) (set nil))
    (cl-letf (((symbol-function 'eglot--project) (lambda (_) '(transient . "/tmp/")))
              ((symbol-function 'project-root) (lambda (p) (cdr p)))
              ((symbol-function 'eieio-oref) (lambda (&rest _) 'timer-not-touched))
              ((symbol-function 'eieio-oset) (lambda (&rest _) (setq set t))))
      (drgnx-lang--no-remote-autoreconnect server)
      (should-not set))))

(ert-deftest drgnx-remote/hint-when-not-installed ()
  (drgnx-remote-test--with
    (let* ((root (drgnx-remote-test--root dir)) (started 0)
           (b (drgnx-remote-test--code-buffer (concat root "app.py"))))
      (delete-file (expand-file-name "drgnx-lsp" bin))
      (drgnx-lang-probe-remote root)
      (cl-letf (((symbol-function 'eglot--connect) (lambda (&rest _) (cl-incf started))))
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
      (cl-letf (((symbol-function 'eglot--connect) (lambda (&rest _) (cl-incf started))))
        (let ((drgnx-lang--user-command t)) (with-current-buffer b (drgnx-lang--maybe-eglot))))
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
                ((symbol-function 'eglot--connect) (lambda (&rest _) (cl-incf started))))
        (drgnx-remote-open-folder root)
        (let* ((b (find-file-noselect file))
               (terminal (let ((default-directory root)) (start-file-process "drgnx-keep" nil "sleep" "60"))))
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
          (should (process-live-p terminal))                           ; what else runs on the host is not killed
          (delete-process terminal)
          (should (= started 1)))))))

(ert-deftest drgnx-remote/open-starts-servers-for-the-code-already-open ()
  (drgnx-remote-test--with
    (let* ((root (drgnx-remote-test--root dir)) (connects 0) (prog-mode-hook nil) (python-mode-hook nil))
      (with-temp-file (expand-file-name "src/app.py" dir) (insert "x = 1\n"))
      (cl-letf (((symbol-function 'drgnx-session-open-folder) (lambda (d) (setq explorer-roots (list d))))
                ((symbol-function 'eglot--connect) (lambda (&rest _) (cl-incf connects))))
        (find-file-noselect (concat root "app.py"))                  ; opened by typing the path: nothing started
        (should (= connects 0))
        (drgnx-remote-open-folder root)
        (should (= connects 1))))))

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
      (drgnx-remote--teardown)
      (setq global-mode-string nil))
    (dolist (profile '("vscode" "emacs" "vim"))
      (let ((text (with-temp-buffer (insert-file-contents (expand-file-name (format "keys/%s.eld" profile) drgnx-dir)) (buffer-string))))
        (dolist (id '("remote-open" "remote-reconnect"))
          (should (string-match-p (concat "(" id " ") text)))))))

;;;; Nothing asks from nowhere

(ert-deftest drgnx-remote/a-prompt-outside-a-command-is-refused ()
  (let* ((ran nil) (drgnx-lang--user-command nil) (drgnx-remote-may-prompt nil)
         (ask (lambda (&rest _) (setq ran t))))
    (should-error (drgnx-remote--guard-prompt ask 'proc 'vec) :type 'remote-file-error)
    (should-not ran)
    (let ((drgnx-lang--user-command t)) (drgnx-remote--guard-prompt ask 'proc 'vec))   ; a command: C-x C-f /ssh:HOST:
    (should ran)
    (setq ran nil)
    (let ((drgnx-remote-may-prompt t)) (drgnx-remote--guard-prompt ask 'proc 'vec))   ; Open Remote…, Reconnect
    (should ran)))

(ert-deftest drgnx-remote/the-commands-may-prompt ()
  (drgnx-remote-test--with
    (let ((root (drgnx-remote-test--root dir)) (seen nil))
      (cl-letf (((symbol-function 'drgnx-session-open-folder) (lambda (_) (push (cons 'open drgnx-remote-may-prompt) seen)))
                ((symbol-function 'drgnx-lang-probe-remote) (lambda (_) (push (cons 'probe drgnx-remote-may-prompt) seen) nil)))
        (drgnx-remote-open-folder root)
        (should (equal seen '((probe . t) (open . t))))
        (should-not drgnx-remote-may-prompt)))))

(ert-deftest drgnx-remote/the-flag-follows-the-users-commands ()
  (let ((drgnx-lang--user-command nil))
    (drgnx-remote--command-start)
    (should (eq drgnx-lang--user-command t))
    (drgnx-remote--command-end)
    (should-not drgnx-lang--user-command)
    (drgnx-remote--command-start)
    (cl-letf (((symbol-function 'minibuffer-depth) (lambda () 1)))     ; a key in the minibuffer: the outer command goes on
      (drgnx-remote--command-end))
    (should (eq drgnx-lang--user-command t))
    (drgnx-remote--command-failed)                                    ; an error or C-g ends it too
    (should-not drgnx-lang--user-command)))

(ert-deftest drgnx-remote/the-module-puts-everything-back ()
  (let ((global-mode-string nil) (pre pre-command-hook) (post post-command-hook) (err command-error-function)
        (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
        (actions '(tramp-action-login tramp-action-password tramp-action-yesno tramp-action-yn tramp-action-otp-password
                                      tramp-action-show-and-confirm-message)))
    (unwind-protect
        (progn
          (drgnx-remote--setup)
          (drgnx-remote--setup)                                        ; twice: still once
          (should (= 1 (length global-mode-string)))
          (should (memq #'drgnx-remote--command-start pre-command-hook))
          (should (memq #'drgnx-remote--command-end post-command-hook))
          (dolist (a actions) (should (advice-member-p #'drgnx-remote--guard-prompt a)))
          (should (advice-member-p #'drgnx-remote--timer-without-command 'timer-event-handler)))
      (drgnx-remote--teardown))
    (should-not global-mode-string)
    (should (equal pre-command-hook pre))
    (should (equal post-command-hook post))
    (should (equal command-error-function err))
    (should-not (advice-member-p #'drgnx-remote--timer-without-command 'timer-event-handler))
    (dolist (a actions) (should-not (advice-member-p #'drgnx-remote--guard-prompt a)))))

;;;; A timer, a filter or a sentinel is not a command of the user's

(ert-deftest drgnx-remote/a-timer-a-filter-and-a-sentinel-get-no-command ()
  ;; the flag is set (a command waits, say in sit-for) while they run: C binds inhibit-quit for filters and
  ;; sentinels, the timer machinery for timers, and a timer body may undo that with with-local-quit
  (drgnx-remote-test--with
    (let* ((root (drgnx-remote-test--root dir)) (connects 0) (results nil) (hooks nil)
           (b (drgnx-remote-test--code-buffer (concat root "app.py")))
           (try (lambda () (push (condition-case nil (drgnx-remote--guard-prompt (lambda (&rest _) 'asked) 1)
                                   (remote-file-error 'refused))
                                 results)
                  (with-current-buffer b (drgnx-lang--maybe-eglot))))
           (global-mode-string nil) (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
      (drgnx-lang-probe-remote root)
      (cl-letf (((symbol-function 'eglot--connect) (lambda (&rest _) (cl-incf connects))))
        (unwind-protect
            (progn
              (drgnx-remote--setup)
              (let ((drgnx-lang--user-command t) (drgnx-remote-may-prompt t))   ; a command is waiting
                (run-at-time 0.05 nil try)
                (run-at-time 0.05 nil (lambda () (with-local-quit (funcall try))))
                (let ((p (make-process :name "drgnx-test-filter" :command '("sh" "-c" "echo hi") :noquery t
                                       :filter (lambda (_p _s) (funcall try)) :sentinel #'ignore)))
                  (while (process-live-p p) (accept-process-output p 0.1)))
                (let ((p (make-process :name "drgnx-test-sentinel" :command '("sh" "-c" "true") :noquery t
                                       :sentinel (lambda (&rest _) (funcall try)))))
                  (while (process-live-p p) (accept-process-output p 0.1)))
                (accept-process-output nil 0.4)
                (should (equal results '(refused refused refused refused)))
                (should (= connects 0))
                (setq results nil)
                (funcall try)                                            ; the command itself
                (should (equal results '(asked)))
                (should (= connects 1))))
          (drgnx-remote--teardown))))))

(ert-deftest drgnx-remote/a-second-file-of-the-project-joins-the-running-server ()
  (drgnx-remote-test--with
    (let* ((root (drgnx-remote-test--root dir)) (connects 0) (prog-mode-hook (list #'drgnx-lang--maybe-eglot))
           (eglot-sync-connect nil) (python-mode-hook nil)
           (eglot-connect-hook (cons #'drgnx-lang--no-remote-autoreconnect eglot-connect-hook)))
      (dolist (n '("a.py" "b.py")) (with-temp-file (expand-file-name n (concat dir "src")) (insert "x = 1\n")))
      (drgnx-lang-probe-remote root)
      (advice-add 'eglot--connect :before (lambda (&rest _) (cl-incf connects)) '((name . drgnx-remote-test)))
      (unwind-protect
          (let ((drgnx-lang--user-command t))
            (with-current-buffer (find-file-noselect (concat root "a.py"))
              (with-timeout (15 (error "no server: %S" messages))
                (while (not (eglot-current-server)) (accept-process-output nil 0.1))))
            (should (= connects 1))
            (setq drgnx-lang--remote-pending nil)                       ; even without the memory of the first start
            (with-current-buffer (find-file-noselect (concat root "b.py"))
              (should (= connects 1))
              (should eglot--managed-mode)))
        (advice-remove 'eglot--connect 'drgnx-remote-test)))))

(defun drgnx-remote-test--managed-p (buffer) (buffer-local-value 'eglot--managed-mode buffer))

(defun drgnx-remote-test--wait-for-server (buffer)
  "Wait until a server has answered for BUFFER's project, then let the attaching finish."
  (with-timeout (15 (error "no server: %S" messages))
    (while (not (with-current-buffer buffer (eglot-current-server))) (accept-process-output nil 0.1)))
  (accept-process-output nil 0.5))

(ert-deftest drgnx-remote/the-starting-buffer-and-the-project-are-managed ()
  "Eglot attaches buffers to a new server in a process filter; the guard skips remote buffers there, so the lang
module attaches the project's buffers from `eglot-connect-hook'.  A buffer whose mode changed outside a command
is attached by the next start (a Reconnect) and one of another host never is."
  (drgnx-remote-test--with
    (let* ((root (drgnx-remote-test--root dir)) (prog-mode-hook (list #'drgnx-lang--maybe-eglot))
           (eglot-sync-connect nil) (python-mode-hook nil) a b other)
      (dolist (n '("a.py" "b.py")) (with-temp-file (expand-file-name n (concat dir "src")) (insert "x = 1\n")))
      (drgnx-lang-probe-remote root)
      (let ((drgnx-lang--user-command t))                          ; the user's command visits the file
        (setq a (find-file-noselect (concat root "a.py"))))
      (setq b (find-file-noselect (concat root "b.py")))           ; opened by a timer: skipped, a server runs already
      (setq other (generate-new-buffer " *drgnx-other-host*"))
      (with-current-buffer other                                   ; looks like a file on another host; nothing is read
        (setq buffer-file-name "/ssh:elsewhere:/srv/p/c.py" default-directory "/ssh:elsewhere:/srv/p/" major-mode 'python-mode))
      (drgnx-remote-test--wait-for-server a)
      (should (drgnx-remote-test--managed-p a))                    ; the buffer whose visit started the server
      (should (drgnx-remote-test--managed-p b))                    ; the project's other buffer, from the connect hook
      (should-not (drgnx-remote-test--managed-p other))
      (with-current-buffer b (eglot--managed-mode -1))
      (should-not (drgnx-remote-test--managed-p b))
      (let ((drgnx-lang--user-command t)) (drgnx-lang-start-remote-server b))   ; Reconnect repairs it
      (should (drgnx-remote-test--managed-p b)))))

(ert-deftest drgnx-remote/open-remote-manages-the-buffers-it-started-servers-for ()
  (drgnx-remote-test--with
    (let* ((root (drgnx-remote-test--root dir)) (prog-mode-hook nil) (eglot-sync-connect nil) (python-mode-hook nil) a b)
      (dolist (n '("a.py" "b.py")) (with-temp-file (expand-file-name n (concat dir "src")) (insert "x = 1\n")))
      (setq a (find-file-noselect (concat root "a.py")) b (find-file-noselect (concat root "b.py")))
      (should-not (drgnx-remote-test--managed-p a))
      (cl-letf (((symbol-function 'drgnx-session-open-folder) (lambda (d) (setq explorer-roots (list d)))))
        (drgnx-remote-open-folder root))
      (drgnx-remote-test--wait-for-server a)
      (should (drgnx-remote-test--managed-p a))
      (should (drgnx-remote-test--managed-p b)))))

(ert-deftest drgnx-remote/opening-forgets-only-its-own-hosts-starts ()
  (drgnx-remote-test--with
    (let ((root (drgnx-remote-test--root dir)) (other (cons (cons "/ssh:other:/srv/p/" '("x")) 1.0e+INF)))
      (setq drgnx-lang--remote-pending (list other (cons (cons (concat root "p/") '("y")) 1.0e+INF)))
      (drgnx-remote--start-servers (file-remote-p root))
      (should (equal drgnx-lang--remote-pending (list other))))))

;;;; eglot's own reconnect

(ert-deftest drgnx-remote/eglot-does-not-reconnect-a-remote-server-outside-a-command ()
  (let ((calls nil) (remote nil))
    (cl-letf (((symbol-function 'eglot--project) (lambda (_) (if remote '(transient . "/ssh:h:/p/") '(transient . "/tmp/"))))
              ((symbol-function 'project-root) (lambda (p) (cdr p))))
      (let ((reconnect (lambda (server &rest _) (push server calls) 'reconnected)))
        (let ((drgnx-lang--user-command nil))
          (setq remote nil)
          (should (eq (drgnx-lang--guard-reconnect reconnect 'local) 'reconnected))   ; a local server: as always
          (setq remote t)
          (should-not (drgnx-lang--guard-reconnect reconnect 'remote))              ; a remote one: refused, said
          (should (equal calls '(local))))
        (let ((drgnx-lang--user-command t))                                        ; M-x eglot-reconnect: allowed
          (should (eq (drgnx-lang--guard-reconnect reconnect 'remote) 'reconnected)))))))

(ert-deftest drgnx-remote/the-lang-module-wires-the-remote-guards-into-eglot ()
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
        (eglot-connect-hook eglot-connect-hook) (prog-mode-hook prog-mode-hook)
        (was (advice-member-p #'drgnx-lang--guard-reconnect 'eglot-reconnect)))
    (unwind-protect
        (progn
          (remove-hook 'eglot-connect-hook #'drgnx-lang--no-remote-autoreconnect)
          (advice-remove 'eglot-reconnect #'drgnx-lang--guard-reconnect)
          (advice-remove 'eglot--maybe-activate-editing-mode #'drgnx-lang--guard-eglot-activation)
          (funcall (plist-get (alist-get 'lang/eglot drgnx-modules--table) :setup))
          (should (memq #'drgnx-lang--no-remote-autoreconnect eglot-connect-hook))
          (should (advice-member-p #'drgnx-lang--guard-reconnect 'eglot-reconnect))
          (should (advice-member-p #'drgnx-lang--guard-eglot-activation 'eglot--maybe-activate-editing-mode))
          (drgnx-lang--teardown-eglot-guards)                  ; and the teardown takes all three away
          (should-not (memq #'drgnx-lang--no-remote-autoreconnect eglot-connect-hook))
          (should-not (advice-member-p #'drgnx-lang--guard-reconnect 'eglot-reconnect))
          (should-not (advice-member-p #'drgnx-lang--guard-eglot-activation 'eglot--maybe-activate-editing-mode)))
      (unless was (advice-remove 'eglot-reconnect #'drgnx-lang--guard-reconnect))
      (advice-remove 'eglot--maybe-activate-editing-mode #'drgnx-lang--guard-eglot-activation)
      (remove-hook 'eglot-connect-hook #'drgnx-lang--no-remote-autoreconnect))))

(ert-deftest drgnx-remote/an-eglot-without-the-activation-function-is-reported-once ()
  (let ((warned nil) (drgnx-lang--eglot-warned nil) (orig (symbol-function 'fboundp)))
    (unwind-protect
        (cl-letf (((symbol-function 'fboundp)
                   (lambda (s) (and (not (eq s 'eglot--maybe-activate-editing-mode)) (funcall orig s))))
                  ((symbol-function 'display-warning)
                   (lambda (type msg &rest _) (push (list type warning-minimum-level msg) warned))))
          (drgnx-lang--teardown-eglot-guards)
          (drgnx-lang--install-eglot-guards)
          (drgnx-lang--install-eglot-guards)                         ; twice: still one report
          (should (= (length warned) 1))
          (should (eq (car (car warned)) 'drgnx-lang))
          (should (eq (nth 1 (car warned)) :error))                  ; logged, no window pops up
          (should (string-match-p "eglot--maybe-activate-editing-mode" (nth 2 (car warned))))
          (should-not (advice-member-p #'drgnx-lang--guard-eglot-activation 'eglot--maybe-activate-editing-mode)))
      (drgnx-lang--teardown-eglot-guards))))

(ert-deftest drgnx-remote/the-warning-waits-for-startup-and-never-shows-a-window ()
  ;; before `after-init-time' (and in a real session) `display-warning' keeps the warning and shows it at the global level
  (let ((drgnx-lang--eglot-warned nil) (orig (symbol-function 'fboundp)) (after-init-hook nil)
        (delayed-warnings-list nil) (warning-minimum-level :warning))
    (when (get-buffer "*Warnings*") (kill-buffer "*Warnings*"))
    (unwind-protect
        (cl-letf (((symbol-function 'fboundp)
                   (lambda (s) (and (not (eq s 'eglot--maybe-activate-editing-mode)) (funcall orig s)))))
          (drgnx-lang--teardown-eglot-guards)
          (let ((after-init-time nil) (noninteractive nil))
            (drgnx-lang--install-eglot-guards)
            (should-not delayed-warnings-list)                        ; nothing kept for the end of startup
            (should (memq #'drgnx-lang--report-missing-activation after-init-hook)))
          (drgnx-lang--report-missing-activation)                      ; what the hook does, with the real display-warning
          (should-not (memq #'drgnx-lang--report-missing-activation after-init-hook))
          (should (eq warning-minimum-level :warning))                 ; the caller's level is back
          (should-not (get-buffer-window "*Warnings*" t))              ; logged, no window
          (should (with-current-buffer "*Warnings*"
                    (string-match-p "eglot--maybe-activate-editing-mode" (buffer-string)))))
      (when (get-buffer "*Warnings*") (kill-buffer "*Warnings*"))
      (drgnx-lang--teardown-eglot-guards))))

(ert-deftest drgnx-remote/a-project-under-the-remote-home-is-attached ()
  "The project may name its root the way the user typed it (`/method:host:~/proj/'); file names are expanded."
  (drgnx-remote-test--with
    (let* ((home (file-name-as-directory (expand-file-name "home" dir)))
           (process-environment (cons (concat "HOME=" home) process-environment))
           (tramp-histfile-override nil)                                ; its default names a file under the home
           (prog-mode-hook (list #'drgnx-lang--maybe-eglot)) (eglot-sync-connect nil) (python-mode-hook nil)
           (project-find-functions (list (lambda (_dir) (cons 'transient "/drgnx-mock::~/proj/"))))
           (root (expand-file-name "/drgnx-mock::~/proj/")) a b)
      (make-directory (expand-file-name "proj" home) t)
      (dolist (n '("a.py" "b.py")) (with-temp-file (expand-file-name (concat "proj/" n) home) (insert "x = 1\n")))
      (drgnx-lang-probe-remote root)
      (let ((drgnx-lang--user-command t))                          ; the user's command visits the file
        (setq a (find-file-noselect "/drgnx-mock::~/proj/a.py")))
      (setq b (find-file-noselect "/drgnx-mock::~/proj/b.py"))     ; opened by something else: skipped
      (drgnx-remote-test--wait-for-server a)
      (should (string-match-p "~/proj" (project-root (eglot--project (with-current-buffer a (eglot-current-server))))))
      (should (drgnx-remote-test--managed-p a))                    ; on connect
      (should (drgnx-remote-test--managed-p b))
      (setq explorer-roots (list root) drgnx-remote--roots (list (cons (file-remote-p root) (list :root root))))
      (dolist (buf (list a b)) (with-current-buffer buf (eglot--managed-mode -1)))
      (drgnx-remote-reconnect (file-remote-p root))                ; and through Reconnect
      (with-timeout (15 (error "not attached after Reconnect: %S" messages))
        (while (not (and (drgnx-remote-test--managed-p a) (drgnx-remote-test--managed-p b)))
          (accept-process-output nil 0.1))))))

(defmacro drgnx-remote-test--counting-activation (&rest body)
  "BODY with `eglot--maybe-activate-editing-mode' replaced, below the guard, by a function that records the buffer
\(or fails in a buffer named \"bad\") in `calls'."
  (declare (indent 0))
  `(let* ((calls nil)
          (count (lambda (_orig &rest _) (push (buffer-name) calls) (when (equal (buffer-name) "bad") (error "bad buffer")))))
     (advice-remove 'eglot--maybe-activate-editing-mode #'drgnx-lang--guard-eglot-activation)
     (advice-add 'eglot--maybe-activate-editing-mode :around count)
     (advice-add 'eglot--maybe-activate-editing-mode :around #'drgnx-lang--guard-eglot-activation)
     (unwind-protect (progn ,@body)
       (advice-remove 'eglot--maybe-activate-editing-mode count))))

(defun drgnx-remote-test--fake-buffer (name file mode)
  "A buffer NAME that looks like it visits FILE in MODE; nothing is read."
  (with-current-buffer (generate-new-buffer name)
    (setq buffer-file-name file default-directory (file-name-directory file) major-mode mode)
    (current-buffer)))

(ert-deftest drgnx-remote/attaching-lets-through-the-servers-project-only ()
  (drgnx-remote-test--with
    (let* ((root (drgnx-remote-test--root dir))
           (mine (drgnx-remote-test--fake-buffer "mine" (concat root "a.py") 'python-mode))
           (other (drgnx-remote-test--fake-buffer "other" "/ssh:elsewhere:/srv/p/c.py" 'python-mode)))
      (drgnx-remote-test--counting-activation
        (setq drgnx-tramp-mock-sends 0)
        (let ((drgnx-lang--attaching (file-name-as-directory root)))
          (with-current-buffer mine (eglot--maybe-activate-editing-mode))
          (should (equal calls '("mine")))
          (with-current-buffer other (eglot--maybe-activate-editing-mode))     ; another host: skipped
          (should (equal calls '("mine")))
          ;; a timer that fires inside the attaching is not part of it, for either buffer
          (drgnx-remote--timer-without-command
           (lambda (_)
             (with-current-buffer other (eglot--maybe-activate-editing-mode))
             (with-current-buffer mine (eglot--maybe-activate-editing-mode)))
           nil)
          (should (equal calls '("mine"))))
        (should (= drgnx-tramp-mock-sends 0))))))

(ert-deftest drgnx-remote/attaching-skips-other-modes-and-survives-a-bad-buffer ()
  (drgnx-remote-test--with
    (let* ((root (drgnx-remote-test--root dir))
           (bad (drgnx-remote-test--fake-buffer "bad" (concat root "a.py") 'python-mode))
           (good (drgnx-remote-test--fake-buffer "good" (concat root "b.py") 'python-mode))
           (text (drgnx-remote-test--fake-buffer "text" (concat root "c.txt") 'text-mode))
           (other (drgnx-remote-test--fake-buffer "other" "/ssh:elsewhere:/srv/p/c.py" 'python-mode)))
      (drgnx-remote-test--counting-activation
        (cl-letf (((symbol-function 'eglot--project) (lambda (_s) (cons 'transient root)))
                  ((symbol-function 'eglot--major-modes) (lambda (_s) '(python-mode))))
          (drgnx-lang--attach-buffers 'a-server))
        (should (equal (sort (copy-sequence calls) #'string<) '("bad" "good")))   ; "text" and "other" left alone
        (ignore bad good text other)))))

(ert-deftest drgnx-remote/a-sentinel-of-the-explorer-lists-nothing ()
  "The Explorer's trash sentinel refreshes a folder; it is not the user's command that happens to wait."
  (let* ((dir (file-name-as-directory (make-temp-file "drgnx-gio" t))) (file (expand-file-name "f.txt" dir))
         (sentinel nil) (seen 'unset))
    (write-region "" nil file nil 'silent)
    (get-buffer-create drgnx-explorer-buffer-name)
    (unwind-protect
        (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) "/usr/bin/gio"))
                  ((symbol-function 'make-process) (lambda (&rest args) (setq sentinel (plist-get args :sentinel)) 'proc))
                  ((symbol-function 'drgnx-explorer--refresh-dir)
                   (lambda (_d) (setq seen drgnx-explorer--remote-reads))))
          (should (drgnx-explorer--gio-trash file))
          (let ((drgnx-explorer--remote-reads t))                    ; the user's listing is waiting for the host
            (funcall sentinel 'proc "finished\n"))
          (should (null seen)))
      (kill-buffer drgnx-explorer-buffer-name)
      (delete-directory dir t))))

(ert-deftest drgnx-remote/the-attach-hook-goes-last ()
  (let ((eglot-connect-hook '(first-hook)))
    (unwind-protect
        (progn (drgnx-lang--install-eglot-guards)
               (should (eq (car (last eglot-connect-hook)) 'drgnx-lang--attach-buffers)))
      (drgnx-lang--teardown-eglot-guards))))

;;;; The fixture

(ert-deftest drgnx-remote/the-mock-puts-tramp-back ()
  (let ((regexp tramp-method-regexp) (methods (copy-sequence tramp-methods)) (hosts tramp-default-host-alist)
        (verbose tramp-verbose) (file tramp-persistency-file-name))
    (drgnx-tramp-mock-setup)
    (should (tramp-tramp-file-p "/drgnx-mock::/tmp/x"))
    (drgnx-tramp-mock-teardown)
    (should-not (tramp-tramp-file-p "/drgnx-mock::/tmp/x"))
    (should (equal tramp-method-regexp regexp))
    (should (equal tramp-methods methods))
    (should (equal tramp-default-host-alist hosts))
    (should (equal tramp-verbose verbose))
    (should (equal tramp-persistency-file-name file))))

;;; mod-remote-test.el ends here
