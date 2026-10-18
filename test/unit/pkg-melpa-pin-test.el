;;; pkg-melpa-pin-test.el --- batch tests: the lock records an archive's commit; a locked version that left the archive is restored from it -*- lexical-binding: t -*-
;; Offline and in temp dirs: archives are local directories whose archive-contents carry MELPA's :commit and :url, the
;; repositories they name are local git repositories made here.  Never the network or the real MELPA.
(require 'ert)
(require 'drgnx-paths)
(require 'drgnx-pkg)
(load (expand-file-name "test/fixtures/pkg-fixture" drgnx-dir) nil t)   ; archives as local dirs, the sandbox

(defun drgnx-pkg-pin-test--want (root &rest names)
  "packages.eld in ROOT's config asking for NAMES."
  (drgnx-pkg-test--write (concat root "config/packages.eld") (list :packages names)))

(defun drgnx-pkg-pin-test--git (repo &rest args)
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory repo))
          (process-environment (append '("GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@t.invalid" "GIT_COMMITTER_NAME=t"
                                         "GIT_COMMITTER_EMAIL=t@t.invalid" "GIT_CONFIG_GLOBAL=/dev/null")
                                       process-environment)))
      (unless (eql 0 (apply #'call-process "git" nil t nil args)) (error "git %S: %s" args (buffer-string)))
      (string-trim (buffer-string)))))

(defun drgnx-pkg-pin-test--commit (repo name header-version &optional requires)
  "Commit NAME.el (its Version: header HEADER-VERSION; NAME-hello answers it) into REPO (made if new): the sha."
  (unless (file-directory-p (expand-file-name ".git" repo))
    (make-directory repo t) (drgnx-pkg-pin-test--git repo "init" "-q" "-b" "main"))
  (write-region (format ";;; %s.el --- fixture  -*- lexical-binding: t -*-\n;; Version: %s\n;; Package-Requires: %S\n;;; Code:\n(defun %s-hello () %S)\n(provide '%s)\n;;; %s.el ends here\n"
                        name header-version (cons '(emacs "29.1") requires) name header-version name name)
                nil (expand-file-name (format "%s.el" name) repo) nil 'silent)
  (drgnx-pkg-pin-test--git repo "add" "-A")
  (drgnx-pkg-pin-test--git repo "commit" "-q" "-m" header-version)
  (drgnx-pkg-pin-test--git repo "rev-parse" "HEAD"))

(defun drgnx-pkg-pin-test--archive (dir packages extras)
  "DIR as an archive of PACKAGES (NAME VERSION [REQUIRES])…, whose entries for the names in EXTRAS ((NAME COMMIT URL)…)
carry MELPA's :commit and :url."
  (drgnx-pkg-test--archive dir packages)
  (let ((contents (with-temp-buffer (insert-file-contents (expand-file-name "archive-contents" dir)) (read (current-buffer)))))
    (pcase-dolist (`(,name ,commit ,url) extras)
      (dolist (e (cdr contents))
        (when (eq (car e) name)
          (aset (cdr e) 4 (list (cons :commit commit) (cons :url url))))))
    (with-temp-file (expand-file-name "archive-contents" dir) (prin1 contents (current-buffer))))
  (file-name-as-directory dir))

(defun drgnx-pkg-pin-test--pin (name version &rest more)
  "A user-lock entry: NAME at VERSION from archive \"melpa\", its file not in any cache; MORE: more of its plist."
  (cons name (append (list :version version :archive "melpa" :kind 'single :file (format "%s-%s.el" name version)
                           :sha256 "00" :requires nil :summary "fixture")
                     more)))

(defun drgnx-pkg-pin-test--hello (name)
  "NAME-hello as the installed package defines it (loaded from the elpa dir)."
  (let ((dir (car (directory-files (drgnx-elpa-dir) t (format "\\`%s-[0-9]" name)))))
    (load (expand-file-name (format "%s.el" name) dir) nil t)
    (funcall (intern (format "%s-hello" name)))))

;;;; The lock records the commit

(ert-deftest drgnx-pkg-pin/the-lock-records-the-commit-and-url-an-archive-carries ()
  (drgnx-pkg-test--with root
    (let ((arch (drgnx-pkg-pin-test--archive (concat root "melpa") '((mp "20260201.1200") (mq "1.0"))
                                             '((mp "abc123" "https://example.invalid/mp")))))
      (drgnx-pkg-pin-test--want root 'mp 'mq)
      (should (plist-get (drgnx-pkg-test--sync root :archives `(("melpa" . ,arch))) :ok))
      (let ((e (alist-get 'mp (drgnx-pkg-read-lock))))
        (should (equal (plist-get e :commit) "abc123"))
        (should (equal (plist-get e :url) "https://example.invalid/mp"))
        (should (eq (plist-get e :kind) 'single)))                       ; still an archive entry, not a Git one
      (let ((e (alist-get 'mq (drgnx-pkg-read-lock))))                    ; an archive that carries none: none recorded
        (should-not (plist-member e :commit))
        (should-not (plist-member e :url))))))

;;;; Restore

(ert-deftest drgnx-pkg-pin/a-locked-version-that-left-the-archive-is-restored-from-its-commit ()
  (drgnx-pkg-test--with root
    (let* ((repo (concat root "src/mp/")) (old (drgnx-pkg-pin-test--commit repo "mp" "1.0"))
           (new (drgnx-pkg-pin-test--commit repo "mp" "2.0"))
           (arch (drgnx-pkg-pin-test--archive (concat root "melpa") '((mp "20260201.1200")) `((mp ,new ,repo))))
           (pin (drgnx-pkg-pin-test--pin 'mp "20260101.1200" :commit old :url repo)))
      (drgnx-pkg-write-lock (list pin))
      (drgnx-pkg-pin-test--want root 'mp)
      (let ((r (drgnx-pkg-test--sync root :archives `(("melpa" . ,arch)))))
        (should (plist-get r :ok))
        (should-not (plist-get r :missing))
        (should (equal (plist-get r :installed) '(mp))))
      (should (equal (drgnx-pkg-test--installed) '("mp-20260101.1200")))     ; the locked version, not the archive's
      (should (equal (drgnx-pkg-pin-test--hello 'mp) "1.0"))                   ; the files of the recorded commit
      (should (equal (alist-get 'mp (drgnx-pkg-read-lock)) (cdr pin)))        ; the lock as it was: still the MELPA entry
      ;; the next sync has nothing to do
      (should-not (plist-get (drgnx-pkg-test--sync root :archives `(("melpa" . ,arch))) :installed))
      (should (equal (drgnx-pkg-test--installed) '("mp-20260101.1200"))))))

(ert-deftest drgnx-pkg-pin/a-restore-is-a-sync-from-an-empty-directory-too ()
  ;; A new machine with the lock and no cache: the version is gone and the commit builds it.
  (drgnx-pkg-test--with root
    (let* ((repo (concat root "src/mp/")) (old (drgnx-pkg-pin-test--commit repo "mp" "1.0"))
           (arch (drgnx-pkg-pin-test--archive (concat root "melpa") '((mq "1.0")) nil)))
      (drgnx-pkg-write-lock (list (drgnx-pkg-pin-test--pin 'mp "20260101.1200" :commit old :url repo)
                                  (cons 'mq (cdr (drgnx-pkg-test--entry arch 'mq "1.0")))))
      (drgnx-pkg-pin-test--want root 'mp 'mq)
      (should (plist-get (drgnx-pkg-test--sync root :archives `(("fx" . ,arch))) :ok))
      (should (equal (drgnx-pkg-test--installed) '("mp-20260101.1200" "mq-1.0"))))))

(ert-deftest drgnx-pkg-pin/a-package-needing-the-restored-one-installs-after-it ()
  (drgnx-pkg-test--with root
    (let* ((repo (concat root "src/mp/")) (old (drgnx-pkg-pin-test--commit repo "mp" "1.0"))
           (arch (drgnx-pkg-pin-test--archive (concat root "melpa") '((mp "20260201.1200") (mq "1.0" ((mp "20260101.1200")))) nil)))
      (drgnx-pkg-write-lock (list (drgnx-pkg-pin-test--pin 'mp "20260101.1200" :commit old :url repo)
                                  (cons 'mq (plist-put (copy-sequence (cdr (drgnx-pkg-test--entry arch 'mq "1.0" '((mp "20260101.1200")))))
                                                       :archive "melpa"))))
      (drgnx-pkg-pin-test--want root 'mq)
      (let ((r (drgnx-pkg-test--sync root :archives `(("melpa" . ,arch)))))
        (should (plist-get r :ok))
        (should (equal (plist-get r :installed) '(mp mq))))
      (should (equal (drgnx-pkg-test--installed) '("mp-20260101.1200" "mq-1.0"))))))

(ert-deftest drgnx-pkg-pin/without-a-commit-the-package-is-missing-and-the-installed-version-kept ()
  ;; Never silently upgraded: the lock says 20260101.1200, the archive has only 20260201.1200, nothing says how to rebuild.
  (drgnx-pkg-test--with root
    (let ((arch (drgnx-pkg-pin-test--archive (concat root "melpa") '((mp "20260201.1200")) nil)))
      (drgnx-pkg-pin-test--want root 'mp)
      (should (plist-get (drgnx-pkg-test--sync root :archives `(("melpa" . ,arch))) :ok))
      (drgnx-pkg-write-lock (list (drgnx-pkg-pin-test--pin 'mp "20260101.1200")))
      (let* ((before (drgnx-pkg-test--bytes (drgnx-pkg-lock-file)))
             (r (drgnx-pkg-test--sync root :archives `(("melpa" . ,arch)))))
        (should-not (plist-get r :ok))
        (should (string-match-p "no commit" (cdr (assq 'mp (plist-get r :missing)))))
        (should (equal (drgnx-pkg-test--installed) '("mp-20260201.1200")))          ; kept
        (should (equal (drgnx-pkg-test--bytes (drgnx-pkg-lock-file)) before))))))

(ert-deftest drgnx-pkg-pin/a-commit-that-cannot-be-had-is-missing-and-nothing-changes ()
  (drgnx-pkg-test--with root
    (let* ((repo (concat root "src/mp/")) (old (drgnx-pkg-pin-test--commit repo "mp" "1.0"))
           (arch (drgnx-pkg-pin-test--archive (concat root "melpa") '((mp "20260201.1200")) nil)))
      (drgnx-pkg-write-lock (list (drgnx-pkg-pin-test--pin 'mp "20260101.1200" :commit "0123456789abcdef0123456789abcdef01234567"
                                                           :url repo)))
      (drgnx-pkg-pin-test--want root 'mp)
      (ignore old)
      (let ((r (drgnx-pkg-test--sync root :archives `(("melpa" . ,arch)))))
        (should-not (plist-get r :ok))
        (should (string-match-p "commit" (cdr (assq 'mp (plist-get r :missing)))))
        (should-not (plist-get r :installed)))
      (should-not (drgnx-pkg-test--installed))
      (should-not (file-exists-p (expand-file-name "elpa.staging" (drgnx-data-dir)))))))

(ert-deftest drgnx-pkg-pin/a-url-that-is-not-a-repository-is-missing ()
  ;; MELPA's :url can be a homepage: the clone fails, the package is reported, the others install.
  (drgnx-pkg-test--with root
    (let ((arch (drgnx-pkg-pin-test--archive (concat root "melpa") '((mp "20260201.1200") (mq "1.0")) nil)))
      (drgnx-pkg-write-lock (list (drgnx-pkg-pin-test--pin 'mp "20260101.1200" :commit "abc123" :url (concat root "no/such/repo"))))
      (drgnx-pkg-pin-test--want root 'mp 'mq)
      (let ((r (drgnx-pkg-test--sync root :archives `(("melpa" . ,arch)))))
        (should-not (plist-get r :ok))
        (should (assq 'mp (plist-get r :missing)))
        (should (equal (plist-get r :installed) '(mq)))))))

(ert-deftest drgnx-pkg-pin/a-version-the-archive-still-serves-is-not-restored ()
  (drgnx-pkg-test--with root
    (let* ((repo (concat root "src/mp/")) (old (drgnx-pkg-pin-test--commit repo "mp" "1.0"))
           (arch (drgnx-pkg-pin-test--archive (concat root "melpa") '((mp "20260101.1200")) nil)))
      (drgnx-pkg-write-lock (list (cons 'mp (append (cdr (drgnx-pkg-test--entry arch 'mp "20260101.1200")) (list :commit old :url repo)))))
      (drgnx-pkg-pin-test--want root 'mp)
      (should (plist-get (drgnx-pkg-test--sync root :archives `(("melpa" . ,arch))) :ok))
      (should-not (file-directory-p (expand-file-name "git" (drgnx-package-cache-dir))))   ; no clone made
      (should (equal (drgnx-pkg-pin-test--hello 'mp) "20260101.1200")))))                 ; the archive's file

(ert-deftest drgnx-pkg-pin/a-soft-shipped-pin-still-falls-back-to-the-archive ()
  ;; The shipped lock's pins stay soft even when they carry a commit: the archive's current version, with a warning.
  (drgnx-pkg-test--with root
    (let* ((repo (concat root "src/mp/")) (old (drgnx-pkg-pin-test--commit repo "mp" "1.0"))
           (arch (drgnx-pkg-pin-test--archive (concat root "melpa") '((mp "20260201.1200")) nil)))
      (drgnx-pkg-test--write (drgnx-pkg-shipped-lock-file)
                             (list :version 1 :packages (list (drgnx-pkg-pin-test--pin 'mp "20260101.1200" :commit old :url repo))))
      (drgnx-pkg-pin-test--want root 'mp)
      (let ((r (drgnx-pkg-test--sync root :archives `(("melpa" . ,arch)))))
        (should (plist-get r :ok))
        (should (member "mp: shipped 20260101.1200 no longer served; installed 20260201.1200" (plist-get r :warnings))))
      (should (equal (drgnx-pkg-test--installed) '("mp-20260201.1200"))))))

(ert-deftest drgnx-pkg-pin/offline-does-not-restore ()
  (drgnx-pkg-test--with root
    (let* ((repo (concat root "src/mp/")) (old (drgnx-pkg-pin-test--commit repo "mp" "1.0")))
      (drgnx-pkg-write-lock (list (drgnx-pkg-pin-test--pin 'mp "20260101.1200" :commit old :url repo)))
      (drgnx-pkg-pin-test--want root 'mp)
      (let ((r (drgnx-pkg-test--sync root :offline t)))
        (should-not (plist-get r :ok))
        (should (assq 'mp (plist-get r :missing))))
      (should-not (drgnx-pkg-test--installed)))))

(provide 'pkg-melpa-pin-test)
;;; pkg-melpa-pin-test.el ends here
