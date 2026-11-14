;;; pkg-fixture.el --- for package tests outside pkg-test.el: archives as local dirs, a sandbox -*- lexical-binding: t -*-
;; The same helpers as pkg-test.el's (a test file cannot load another: ERT refuses tests defined twice).
(require 'ert)
(require 'drgnx-paths)
(require 'drgnx-pkg)

(defun drgnx-pkg-test--package (dir name version &optional requires body)
  "Write the single-file package NAME-VERSION.el into archive DIR; return its archive-contents entry."
  (write-region (format ";;; %s.el --- fixture %s  -*- lexical-binding: t -*-\n;; Version: %s\n;; Package-Requires: %S\n;;; Code:\n%s\n(defun %s-hello () %S)\n(provide '%s)\n;;; %s.el ends here\n"
                        name name version (cons '(emacs "29.1") (mapcar (lambda (r) (list (car r) (cadr r))) requires))
                        (or body "") name version name name)
                nil (expand-file-name (format "%s-%s.el" name version) dir) nil 'silent)
  (cons name (vector (version-to-list version)
                     (cons '(emacs (29 1)) (mapcar (lambda (r) (list (car r) (version-to-list (cadr r)))) requires))
                     (format "fixture %s" name) 'single nil)))

(defun drgnx-pkg-test--archive (dir packages)
  "Make DIR a package archive holding PACKAGES: (NAME VERSION [REQUIRES [BODY]])…"
  (make-directory dir t)
  (dolist (f (directory-files dir t "\\.el\\'")) (delete-file f))
  (let ((entries (mapcar (lambda (p) (apply #'drgnx-pkg-test--package dir p)) packages)))
    (with-temp-file (expand-file-name "archive-contents" dir)
      (prin1 (cons 1 entries) (current-buffer))))
  (file-name-as-directory dir))

(defmacro drgnx-pkg-test--with (root &rest body)
  "BODY with ROOT a temp dir and every drgnx and package.el location inside it."
  (declare (indent 1))
  `(let* ((,root (file-name-as-directory (make-temp-file "drgnx-pkg" t)))
          (process-environment (append (list (concat "DRGNX_DATA_DIR=" ,root "data")
                                             (concat "DRGNX_CONFIG_DIR=" ,root "config")
                                             (concat "XDG_CACHE_HOME=" ,root "cache")
                                             (concat "XDG_STATE_HOME=" ,root "state"))
                                       process-environment))
          (drgnx-modules--state nil)
          (drgnx-pkg-shipped-lock (concat ,root "shipped.lock.eld"))   ; never the checkout's etc/
          (drgnx-pkg-native-compile nil)
          (package-check-signature nil)
          (package-alist nil) (package-archive-contents nil) (package-activated-list nil)
          (package--initialized nil) (package-user-dir (expand-file-name "unused-elpa" ,root))
          (package-quickstart nil) (package-quickstart-file (expand-file-name "other-emacs/package-quickstart.el" ,root))
          (load-path load-path) (features features))
     (make-directory (concat ,root "config") t)
     (unwind-protect (progn ,@body)
       (delete-directory ,root t))))

(defun drgnx-pkg-test--write (file data)
  (make-directory (file-name-directory file) t)
  (with-temp-file file (prin1 data (current-buffer))))

(defun drgnx-pkg-test--installed ()
  (sort (seq-filter (lambda (d) (not (string-prefix-p "." d)))
                    (seq-filter (lambda (d) (file-directory-p (expand-file-name d (drgnx-elpa-dir))))
                                (directory-files (drgnx-elpa-dir))))
        #'string<))

(defun drgnx-pkg-test--sync (root &rest args)
  "drgnx-pkg-sync with ROOT's (empty) modules dir and ARGS."
  (make-directory (concat root "mods") t)
  (apply #'drgnx-pkg-sync :modules-dir (concat root "mods") args))

(defun drgnx-pkg-test--bytes (file)
  (with-temp-buffer (set-buffer-multibyte nil) (insert-file-contents-literally file) (buffer-string)))

(defun drgnx-pkg-test--entry (arch name version &optional requires)
  "The lock entry of the archive ARCH's file NAME-VERSION.el (REQUIRES: ((NAME VERSION)…))."
  (let ((file (format "%s-%s.el" name version)))
    (cons name (list :version version :archive "fx" :kind 'single :file file
                     :sha256 (secure-hash 'sha256 (drgnx-pkg-test--bytes (concat arch file)))
                     :requires requires :summary (format "fixture %s" name)))))

;;;; Batch children: `drgnx sync' as bin/drgnx runs it, in a sandbox of its own (pkg-child-fixture.el)

(declare-function drgnx-handshake--filter "handshake-fixture" (proc text))
(declare-function drgnx-test-child-start "handshake-fixture" (&rest args))

(defun drgnx-pkg-child-root ()
  "A new temp directory for a child's every drgnx location (HOME too), with an empty modules directory: its name."
  (let ((root (file-name-as-directory (make-temp-file "drgnx-pkg-child" t))))
    (dolist (d '("config" "mods" "home")) (make-directory (concat root d) t))
    root))

(defmacro drgnx-pkg-child-with (root &rest body)
  "BODY with ROOT a new sandbox (`drgnx-pkg-child-root') and this Emacs's drgnx locations in it too, deleted after."
  (declare (indent 1))
  `(let* ((,root (drgnx-pkg-child-root))
          (process-environment (drgnx-pkg-child-env ,root))
          (drgnx-modules--state nil))
     (unwind-protect (progn ,@body)
       (delete-directory ,root t))))

(defun drgnx-pkg-child-env (root &optional more)
  "The environment of a child sandboxed in ROOT, with MORE (\"VAR=VALUE\"…) first."
  (append more
          (list (concat "HOME=" root "home") (concat "DRGNX_DATA_DIR=" root "data") (concat "DRGNX_CONFIG_DIR=" root "config")
                (concat "XDG_CACHE_HOME=" root "cache") (concat "XDG_STATE_HOME=" root "state")
                (concat "XDG_CONFIG_HOME=" root "home/.config") (concat "XDG_DATA_HOME=" root "home/.local/share")
                (concat "DRGNX_TEST_MODULES_DIR=" root "mods") (concat "DRGNX_TEST_SHIPPED=" root "shipped.lock.eld"))
          process-environment))

(defun drgnx-pkg-child-command (args)
  "The child Emacs running the package CLI with ARGS (strings), as bin/drgnx does, after pkg-child-fixture.el."
  (append (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                "--eval" "(setq load-prefer-newer t)" "-L" (expand-file-name "core" drgnx-dir)
                "-l" "drgnx-pkg" "-l" (expand-file-name "test/fixtures/pkg-child-fixture.el" drgnx-dir)
                "-f" "drgnx-pkg-cli" "--")
          args))

(defun drgnx-pkg-child-run (root args &optional env)
  "Run the package CLI with ARGS in ROOT's sandbox (ENV: more variables) to its end: (EXIT . OUTPUT)."
  (with-temp-buffer
    (let* ((process-environment (drgnx-pkg-child-env root env))
           (default-directory root)
           (command (drgnx-pkg-child-command args))
           (exit (apply #'call-process (car command) nil t nil (cdr command))))
      (cons exit (buffer-string)))))

(defun drgnx-pkg-child--filter (proc text)
  "A child's filter: its whole output kept as :out, and the announcements read by the handshake fixture."
  (process-put proc :out (concat (process-get proc :out) text))
  (drgnx-handshake--filter proc text))

(defun drgnx-pkg-child-start (root args announce &optional env)
  "Start the package CLI with ARGS in ROOT's sandbox as a handshake child that announces and parks at each state of
ANNOUNCE (a list of strings); its output is the process property :out."
  (require 'drgnx-handshake-fixture (expand-file-name "test/fixtures/handshake-fixture" drgnx-dir))
  (let* ((process-environment (drgnx-pkg-child-env root (cons (concat "DRGNX_TEST_ANNOUNCE=" (string-join announce " ")) env)))
         (default-directory root)
         (p (drgnx-test-child-start :name "drgnx-pkg-child" :command (drgnx-pkg-child-command args))))
    (set-process-filter p #'drgnx-pkg-child--filter)
    p))

(defun drgnx-pkg-child-tree (dir)
  "Every file under DIR with its sha256, sorted: ((RELATIVE-NAME . SHA)…); nil when DIR is not there."
  (when (file-directory-p dir)
    (sort (mapcar (lambda (f) (cons (file-relative-name f dir) (secure-hash 'sha256 (drgnx-pkg-test--bytes f))))
                  (directory-files-recursively dir "" nil))
          (lambda (a b) (string< (car a) (car b))))))

(defun drgnx-pkg-child-want (root &rest names)
  "packages.eld in ROOT's config asking for NAMES, with the archive fx at ROOT's arch/."
  (drgnx-pkg-test--write (concat root "config/packages.eld") (list :packages names :archives `(("fx" . ,(concat root "arch/"))))))

(defun drgnx-pkg-child-module (root module packages)
  "A module MODULE (on by default) asking for PACKAGES in ROOT's modules directory."
  (write-region (format "(drgnx-module-define '%s :packages '%S)\n" module packages) nil
                (format "%smods/drgnx-%s.el" root (replace-regexp-in-string "/" "-" (symbol-name module))) nil 'silent))

(defun drgnx-pkg-child-lock (root)
  "The lock of ROOT's sandbox: its entries (NAME . PLIST), nil when there is none."
  (let ((file (concat root "config/drgnx.lock.eld")))
    (when (file-exists-p file)
      (plist-get (with-temp-buffer (insert-file-contents file) (read (current-buffer))) :packages))))

(defun drgnx-pkg-child-generations (root)
  "ROOT's generations, newest first: ((N . NOTE)…)."
  (let ((dir (concat root "data/generations/")))
    (sort (delq nil (mapcar (lambda (d)
                              (when (string-match-p "\\`[0-9]+\\'" d)
                                (cons (string-to-number d)
                                      (plist-get (with-temp-buffer (insert-file-contents (format "%s%s/generation.eld" dir d))
                                                                   (read (current-buffer)))
                                                 :note))))
                            (and (file-directory-p dir) (directory-files dir))))
          (lambda (a b) (> (car a) (car b))))))

(defun drgnx-pkg-child-elpa (root)
  "The package directories in ROOT's elpa/, sorted."
  (let ((dir (concat root "data/elpa/")))
    (and (file-directory-p dir)
         (sort (seq-filter (lambda (d) (and (not (string-prefix-p "." d)) (file-directory-p (expand-file-name d dir))))
                           (directory-files dir))
               #'string<))))

;;;; Signed archives: a test key in ROOT/signer/ (a GNUPGHOME of its own), its public half in the sandbox's keyring

(defun drgnx-pkg-child--gpg (home &rest args)
  "Run gpg on the GNUPGHOME HOME with ARGS: its output; a failure is an error with it."
  (with-temp-buffer
    (let ((rc (apply #'call-process "gpg" nil t nil "--homedir" home "--batch" "--no-tty" "--quiet" args)))
      (unless (eql rc 0) (error "gpg %s failed (%s): %s" (string-join args " ") rc (buffer-string)))
      (buffer-string))))

(defun drgnx-pkg-child-signer (root)
  "Make a signing key without a passphrase in ROOT/signer/, and import its public half into ROOT's package keyring
\(data/gnupg: the sandbox's `package-gnupghome-dir')."
  (let ((home (concat root "signer")) (ring (concat root "data/gnupg")) (pub (concat root "signer.asc")))
    (dolist (d (list home ring)) (make-directory d t) (set-file-modes d #o700))
    (drgnx-pkg-child--gpg home "--pinentry-mode" "loopback" "--passphrase" ""
                          "--quick-gen-key" "drgnx test <test@example.invalid>" "ed25519" "sign" "never")
    (drgnx-pkg-child--gpg home "--yes" "--armor" "--output" pub "--export")
    (drgnx-pkg-child--gpg ring "--import" pub)))

(defun drgnx-pkg-child-gpg-stop (root)
  "Stop the gpg agents of ROOT's GNUPGHOMEs (the signer's and the keyring's)."
  (dolist (home (list (concat root "signer") (concat root "data/gnupg")))
    (when (file-directory-p home)
      (ignore-errors (call-process "gpgconf" nil nil nil "--homedir" home "--kill" "all")))))

(defun drgnx-pkg-child-sign-archive (root dir)
  "Sign the archive DIR with ROOT's test key: an armored FILE.sig beside archive-contents and each package file.  DIR."
  (dolist (f (cons (expand-file-name "archive-contents" dir) (directory-files dir t "\\.el\\'")))
    (drgnx-pkg-child--gpg (concat root "signer") "--yes" "--pinentry-mode" "loopback" "--passphrase" ""
                          "--armor" "--detach-sign" "--output" (concat f ".sig") f))
  dir)

(provide 'pkg-fixture)
;;; pkg-fixture.el ends here
