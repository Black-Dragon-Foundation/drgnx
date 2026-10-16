;;; pkg-test.el --- batch tests: drgnx-pkg — manifest, lock, sync, generations, upgrade -*- lexical-binding: t -*-
;; Everything runs offline against package archives that are local directories, in temp dirs:
;; never the network, the user's ELPA, ~/.local/share/drgnx or ~/.config/drgnx.
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
          (drgnx-pkg-native-compile nil)
          (package-check-signature nil)
          (package-alist nil) (package-archive-contents nil) (package-activated-list nil)
          (package--initialized nil) (package-user-dir (expand-file-name "unused-elpa" ,root))
          (load-path load-path) (features features))
     (make-directory (concat ,root "config") t)
     (unwind-protect (progn ,@body)
       (delete-directory ,root t))))

(defun drgnx-pkg-test--write (file data)
  (make-directory (file-name-directory file) t)
  (with-temp-file file (prin1 data (current-buffer))))

(defun drgnx-pkg-test--want (root &rest names)
  "packages.eld in ROOT's config asking for NAMES; no modules (an empty modules dir)."
  (drgnx-pkg-test--write (concat root "config/packages.eld") (list :packages names)))

(defun drgnx-pkg-test--installed ()
  (sort (seq-filter (lambda (d) (not (string-prefix-p "." d)))
                    (seq-filter (lambda (d) (file-directory-p (expand-file-name d (drgnx-elpa-dir))))
                                (directory-files (drgnx-elpa-dir))))
        #'string<))

(defun drgnx-pkg-test--bytes (file)
  (with-temp-buffer (set-buffer-multibyte nil) (insert-file-contents-literally file) (buffer-string)))

(defun drgnx-pkg-test--sync (root &rest args)
  "drgnx-pkg-sync with ROOT's (empty) modules dir and ARGS."
  (make-directory (concat root "mods") t)
  (apply #'drgnx-pkg-sync :modules-dir (concat root "mods") args))

;;;; Task 1: paths, manifest, lock

(ert-deftest drgnx-pkg/paths-follow-the-environment ()
  (drgnx-pkg-test--with root
    (should (equal (drgnx-data-dir) (concat root "data/")))
    (should (equal (drgnx-elpa-dir) (concat root "data/elpa/")))
    (should (equal (drgnx-generations-dir) (concat root "data/generations/")))
    (should (equal (drgnx-package-cache-dir) (concat root "cache/drgnx/packages/")))))

(ert-deftest drgnx-pkg/the-manifest-is-enabled-modules-packages-eld-and-ensures ()
  (drgnx-pkg-test--with root
    (let ((mods (concat root "mods/x/")))
      (make-directory mods t)
      ;; read, never run: the files would error if evaluated
      (write-region "(error \"never run\")\n(drgnx-module-define 'x/a :stage 'idle :packages '(pa pb) :setup #'ignore)\n(drgnx-module-define 'x/b :packages '(pz))\n(drgnx-module-define 'x/c :doc \"no packages\")\n"
                    nil (concat mods "drgnx-x.el") nil 'silent)
      (drgnx-pkg-test--write (concat root "config/modules.eld") '(:version 1 :disabled (x/b)))
      (drgnx-pkg-test--write (concat root "config/packages.eld") '(:packages (pc pa)))
      (drgnx-pkg-test--write (concat root "state/drgnx/packages-wanted.eld") '(pw))
      (should (equal (drgnx-pkg-manifest (concat root "mods")) '(pa pb pc pw))))))

(ert-deftest drgnx-pkg/lock-round-trip ()
  (drgnx-pkg-test--with root
    (should-not (drgnx-pkg-read-lock))
    (drgnx-pkg-write-lock '((zz :version "2.0" :sha256 "b") (aa :version "1.0" :sha256 "a")))
    (should (equal (drgnx-pkg-read-lock) '((aa :version "1.0" :sha256 "a") (zz :version "2.0" :sha256 "b"))))
    (should (string-match-p "\\`;; drgnx package lock" (with-temp-buffer (insert-file-contents (drgnx-pkg-lock-file)) (buffer-string))))))

(ert-deftest drgnx-pkg/an-unreadable-lock-is-an-error-and-is-never-overwritten ()
  (drgnx-pkg-test--with root
    (write-region "(:version 1 :packages ((aa :version" nil (drgnx-pkg-lock-file) nil 'silent)
    (let ((before (drgnx-pkg-test--bytes (drgnx-pkg-lock-file))))
      (should-error (drgnx-pkg-read-lock) :type 'drgnx-pkg-error)
      (drgnx-pkg-test--want root 'fa)
      (should-error (drgnx-pkg-test--sync root :archives `(("fx" . ,(drgnx-pkg-test--archive (concat root "arch") '((fa "1.0"))))))
                    :type 'drgnx-pkg-error)
      (should (equal (drgnx-pkg-test--bytes (drgnx-pkg-lock-file)) before)))))

;;;; Task 2: sync, cache, offline, refusals

(ert-deftest drgnx-pkg/sync-installs-the-manifest-with-its-dependencies ()
  (drgnx-pkg-test--with root
    (let ((arch (drgnx-pkg-test--archive (concat root "arch") '((fa "1.0") (fb "1.0" ((fa "1.0")))))))
      (drgnx-pkg-test--want root 'fb)
      (let ((r (drgnx-pkg-test--sync root :archives `(("fx" . ,arch)))))
        (should (plist-get r :ok))
        (should (equal (drgnx-pkg-test--installed) '("fa-1.0" "fb-1.0")))
        (should (file-exists-p (expand-file-name "fb-1.0/fb.elc" (drgnx-elpa-dir))))     ; byte-compiled
        (should (file-exists-p (expand-file-name "drgnx-quickstart.el" (drgnx-elpa-dir))))
        (let ((lock (drgnx-pkg-read-lock)))
          (should (equal (mapcar #'car lock) '(fa fb)))
          (should (equal (plist-get (alist-get 'fb lock) :version) "1.0"))
          (should (equal (plist-get (alist-get 'fb lock) :archive) "fx"))
          (should (equal (plist-get (alist-get 'fb lock) :sha256)
                         (secure-hash 'sha256 (drgnx-pkg-test--bytes (concat arch "fb-1.0.el"))))))
        (should (file-exists-p (expand-file-name "fb-1.0.el" (drgnx-package-cache-dir))))
        (should (equal (mapcar #'car (drgnx-pkg-generations)) '(1)))
        (should (eql (plist-get r :generation) 1))))))

(ert-deftest drgnx-pkg/offline-sync-from-the-lock-into-an-empty-dir ()
  (drgnx-pkg-test--with root
    (let ((arch (drgnx-pkg-test--archive (concat root "arch") '((fa "1.0") (fb "1.0" ((fa "1.0")))))))
      (drgnx-pkg-test--want root 'fb)
      (drgnx-pkg-test--sync root :archives `(("fx" . ,arch)))
      (delete-directory arch t)                                        ; no archive any more
      (let ((process-environment (cons (concat "DRGNX_DATA_DIR=" root "data2") process-environment)))
        (let ((r (drgnx-pkg-test--sync root :offline t)))
          (should (plist-get r :ok))
          (should (equal (drgnx-pkg-test--installed) '("fa-1.0" "fb-1.0"))))))))

(ert-deftest drgnx-pkg/a-wrong-hash-refuses-and-leaves-elpa-and-lock-alone ()
  (drgnx-pkg-test--with root
    (let ((arch (drgnx-pkg-test--archive (concat root "arch") '((fa "1.0") (fb "1.0" ((fa "1.0")))))))
      (drgnx-pkg-test--want root 'fb)
      (drgnx-pkg-test--sync root :archives `(("fx" . ,arch)))
      (write-region "(error \"tampered\")\n" nil (expand-file-name "fb-1.0.el" (drgnx-package-cache-dir)) nil 'silent)
      (let ((process-environment (cons (concat "DRGNX_DATA_DIR=" root "data2") process-environment))
            (lock (drgnx-pkg-test--bytes (drgnx-pkg-lock-file))))
        (should-error (drgnx-pkg-test--sync root :offline t) :type 'drgnx-pkg-error)
        (should-not (file-exists-p (drgnx-elpa-dir)))                  ; nothing half-installed
        (should (equal (drgnx-pkg-test--bytes (drgnx-pkg-lock-file)) lock))))))

(ert-deftest drgnx-pkg/a-locked-version-nobody-has-is-reported-and-the-rest-installed ()
  (drgnx-pkg-test--with root
    (let ((arch (drgnx-pkg-test--archive (concat root "arch") '((fa "1.0") (fc "1.0")))))
      (drgnx-pkg-test--want root 'fa 'fc)
      (drgnx-pkg-write-lock '((fc :version "0.9" :archive "fx" :kind single :file "fc-0.9.el" :sha256 "x")))
      (let ((lock (drgnx-pkg-test--bytes (drgnx-pkg-lock-file)))
            (r (drgnx-pkg-test--sync root :archives `(("fx" . ,arch)))))
        (should-not (plist-get r :ok))
        (should (equal (mapcar #'car (plist-get r :missing)) '(fc)))
        (should (equal (drgnx-pkg-test--installed) '("fa-1.0")))
        (should (equal (drgnx-pkg-test--bytes (drgnx-pkg-lock-file)) lock))))))

(ert-deftest drgnx-pkg/a-second-sync-refuses-while-one-runs ()
  (drgnx-pkg-test--with root
    (make-directory (drgnx-data-dir) t)
    (drgnx-pkg-test--want root)
    (write-region (format "%d" (emacs-pid)) nil (expand-file-name "sync.lock" (drgnx-data-dir)) nil 'silent)
    (should-error (drgnx-pkg-test--sync root :archives nil) :type 'drgnx-pkg-error)
    ;; a lock left by a process that is gone is taken over
    (write-region "999999999" nil (expand-file-name "sync.lock" (drgnx-data-dir)) nil 'silent)
    (should (plist-get (drgnx-pkg-test--sync root :archives nil) :ok))
    (should-not (file-exists-p (expand-file-name "sync.lock" (drgnx-data-dir))))))

(ert-deftest drgnx-pkg/seeding-copies-an-existing-elpa ()
  ;; The cutover: the packages of today's Emacs, copied, then recorded in the lock.
  (drgnx-pkg-test--with root
    (let ((arch (drgnx-pkg-test--archive (concat root "arch") '((fa "1.0"))))
          (old (concat root "old-elpa/")))
      (drgnx-pkg-test--want root 'fa)
      (drgnx-pkg-test--sync root :archives `(("fx" . ,arch)))
      (copy-directory (expand-file-name "fa-1.0" (drgnx-elpa-dir)) (expand-file-name "fa-1.0" old) nil t t)
      (let ((process-environment (cons (concat "DRGNX_DATA_DIR=" root "data2") process-environment)))
        (let ((r (drgnx-pkg-test--sync root :offline t :seed old)))
          (should (plist-get r :ok))
          (should (equal (drgnx-pkg-test--installed) '("fa-1.0"))))))))

;;;; Task 3: generations, rollback, upgrade

(ert-deftest drgnx-pkg/rollback-restores-the-files-byte-for-byte-at-the-same-path ()
  (drgnx-pkg-test--with root
    (let ((arch (concat root "arch")))
      (drgnx-pkg-test--archive arch '((fa "1.0")))
      (drgnx-pkg-test--want root 'fa)
      (drgnx-pkg-test--sync root :archives `(("fx" . ,arch)))
      (let ((v1 (drgnx-pkg-test--bytes (expand-file-name "fa-1.0/fa.elc" (drgnx-elpa-dir)))))
        (drgnx-pkg-test--archive arch '((fa "2.0")))
        (should (plist-get (drgnx-pkg-upgrade :archives `(("fx" . ,arch)) :modules-dir (concat root "mods") :smoke #'ignore) :ok))
        (should (equal (drgnx-pkg-test--installed) '("fa-2.0")))
        (should (equal (mapcar #'car (drgnx-pkg-generations)) '(2 1)))
        (should (eql (drgnx-pkg-rollback) 1))
        (should (equal (drgnx-pkg-test--installed) '("fa-1.0")))
        (should (equal (drgnx-pkg-test--bytes (expand-file-name "fa-1.0/fa.elc" (drgnx-elpa-dir))) v1))
        (should (equal (plist-get (alist-get 'fa (drgnx-pkg-read-lock)) :version) "1.0"))))))

(ert-deftest drgnx-pkg/a-broken-upgrade-restores-the-previous-generation ()
  (drgnx-pkg-test--with root
    (let ((arch (concat root "arch")))
      (drgnx-pkg-test--archive arch '((fa "1.0")))
      (drgnx-pkg-test--want root 'fa)
      (drgnx-pkg-test--sync root :archives `(("fx" . ,arch)))
      (drgnx-pkg-test--archive arch '((fa "2.0" nil "(error \"fa 2.0 is broken\")")))
      ;; the default smoke test: a fresh Emacs that activates the packages and loads every one
      (let ((r (drgnx-pkg-upgrade :archives `(("fx" . ,arch)) :modules-dir (concat root "mods"))))
        (should-not (plist-get r :ok))
        (should (string-match-p "fa 2.0 is broken" (plist-get r :smoke)))
        (should (eql (plist-get r :restored) 1))
        (should (equal (drgnx-pkg-test--installed) '("fa-1.0")))
        (should (equal (plist-get (alist-get 'fa (drgnx-pkg-read-lock)) :version) "1.0"))
        (should (equal (mapcar #'car (drgnx-pkg-generations)) '(1)))))))

(ert-deftest drgnx-pkg/five-generations-are-kept ()
  (drgnx-pkg-test--with root
    (drgnx-pkg-test--want root)
    (dotimes (_ 7) (drgnx-pkg-snapshot))
    (should (equal (mapcar #'car (drgnx-pkg-generations)) '(7 6 5 4 3)))))

;;; pkg-test.el ends here
