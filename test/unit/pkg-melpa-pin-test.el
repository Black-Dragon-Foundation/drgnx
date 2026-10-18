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
                                             '((mp "abc123abc123abc123abc123abc123abc123abcd" "https://example.invalid/mp")))))
      (drgnx-pkg-pin-test--want root 'mp 'mq)
      (should (plist-get (drgnx-pkg-test--sync root :archives `(("melpa" . ,arch))) :ok))
      (let ((e (alist-get 'mp (drgnx-pkg-read-lock))))
        (should (equal (plist-get e :commit) "abc123abc123abc123abc123abc123abc123abcd"))
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
      (drgnx-pkg-write-lock (list (drgnx-pkg-pin-test--pin 'mp "20260101.1200" :commit "abc123abc123abc123abc123abc123abc123abcd" :url (concat root "no/such/repo"))))
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


;;;; Review fixes: the commit is a full id, the URL a safe one, lisp/ layouts

(defun drgnx-pkg-pin-test--missing-with (root url commit pattern)
  "A sync where the lock pins mp (gone from the archive) at COMMIT from URL: mp is MISSING with a reason matching
PATTERN, nothing installed, no clone made."
  (let ((arch (drgnx-pkg-pin-test--archive (concat root "melpa") '((mp "20260201.1200")) nil)))
    (drgnx-pkg-write-lock (list (drgnx-pkg-pin-test--pin 'mp "20260101.1200" :commit commit :url url)))
    (drgnx-pkg-pin-test--want root 'mp)
    (let ((r (drgnx-pkg-test--sync root :archives `(("melpa" . ,arch)))))
      (should-not (plist-get r :ok))
      (should (string-match-p pattern (cdr (assq 'mp (plist-get r :missing)))))
      (should-not (plist-get r :installed)))
    (should-not (drgnx-pkg-test--installed))
    (should-not (file-directory-p (expand-file-name "git" (drgnx-package-cache-dir))))))

(ert-deftest drgnx-pkg-pin/a-commit-that-is-not-a-full-id-is-refused ()
  ;; A branch, a symbolic name or a prefix resolves to whatever it names today; the commit is the only check.
  (dolist (commit '("main" "HEAD~0" "HEAD"))
    (drgnx-pkg-test--with root
      (let* ((repo (concat root "src/mp/")) (sha (drgnx-pkg-pin-test--commit repo "mp" "1.0")))
        (drgnx-pkg-pin-test--missing-with root repo commit "full commit id"))))
  (drgnx-pkg-test--with root
    (let* ((repo (concat root "src/mp/")) (sha (drgnx-pkg-pin-test--commit repo "mp" "1.0")))
      (drgnx-pkg-pin-test--missing-with root repo (substring sha 0 6) "full commit id")))
  (drgnx-pkg-test--with root                                    ; an archive's non-id :commit is not recorded either
    (let ((arch (drgnx-pkg-pin-test--archive (concat root "melpa") '((mp "20260101.1200")) '((mp "main" "/x")))))
      (drgnx-pkg-pin-test--want root 'mp)
      (should (plist-get (drgnx-pkg-test--sync root :archives `(("melpa" . ,arch))) :ok))
      (should-not (plist-member (alist-get 'mp (drgnx-pkg-read-lock)) :commit)))))   ; not recorded either

(ert-deftest drgnx-pkg-pin/only-https-urls-and-local-directories-are-cloned ()
  (dolist (url (list "ext::touch /tmp/drgnx-pin-test-pwned" "ssh://git@example.invalid/mp" "git://example.invalid/mp"
                     "http://example.invalid/mp" "--upload-pack=touch /tmp/drgnx-pin-test-pwned" "relative/dir"))
    (drgnx-pkg-test--with root
      (drgnx-pkg-pin-test--missing-with root url "0123456789abcdef0123456789abcdef01234567" "https")
      (should-not (file-exists-p "/tmp/drgnx-pin-test-pwned")))))

(ert-deftest drgnx-pkg-pin/git-restore-allows-only-https-and-file-even-with-a-permissive-global-config ()
  ;; A user's protocol.allow=always must not turn an archive's URL into a command (ext::).
  (drgnx-pkg-test--with root
    (let ((cfg (concat root "gitconfig")) (flag (concat root "pwned")))
      (write-region "[protocol]\n\tallow = always\n" nil cfg nil 'silent)
      (let ((process-environment (cons (concat "GIT_CONFIG_GLOBAL=" cfg) process-environment))
            (drgnx-pkg--git-env drgnx-pkg--restore-git-env))
        (should-error (drgnx-pkg--git-fetch 'x (list :url (concat "ext::touch " flag))) :type 'drgnx-pkg-error))
      (should-not (file-exists-p flag)))))

(ert-deftest drgnx-pkg-pin/a-failed-set-url-never-fetches-the-old-origin ()
  (drgnx-pkg-test--with root
    (let* ((repo (concat root "src/mp/")))
      (drgnx-pkg-pin-test--commit repo "mp" "1.0")
      (drgnx-pkg--git-fetch 'mp (list :url repo))                                  ; cloned
      (should-error (drgnx-pkg--git-fetch 'mp (list :url "--upload-pack=false")) :type 'drgnx-pkg-error))))

(ert-deftest drgnx-pkg-pin/a-package-whose-code-is-in-lisp-is-restored ()
  ;; forge, ghub and closql keep their sources in lisp/.
  (drgnx-pkg-test--with root
    (let* ((repo (concat root "src/mp/")))
      (make-directory (concat repo "lisp") t)
      (drgnx-pkg-pin-test--git repo "init" "-q" "-b" "main")
      (write-region ";;; mp.el --- fixture  -*- lexical-binding: t -*-\n;; Version: 1.0\n;; Package-Requires: ((emacs \"29.1\"))\n;;; Code:\n(defun mp-hello () \"1.0\")\n(provide 'mp)\n;;; mp.el ends here\n"
                    nil (concat repo "lisp/mp.el") nil 'silent)
      (write-region "docs\n" nil (concat repo "README") nil 'silent)
      (drgnx-pkg-pin-test--git repo "add" "-A")
      (drgnx-pkg-pin-test--git repo "commit" "-q" "-m" "1.0")
      (let ((old (drgnx-pkg-pin-test--git repo "rev-parse" "HEAD"))
            (arch (drgnx-pkg-pin-test--archive (concat root "melpa") '((mq "1.0")) nil)))
        (drgnx-pkg-write-lock (list (drgnx-pkg-pin-test--pin 'mp "20260101.1200" :commit old :url repo)))
        (drgnx-pkg-pin-test--want root 'mp)
        (should (plist-get (drgnx-pkg-test--sync root :archives `(("melpa" . ,arch))) :ok))
        (should (equal (drgnx-pkg-test--installed) '("mp-20260101.1200")))
        (should (equal (drgnx-pkg-pin-test--hello 'mp) "1.0"))))))

(ert-deftest drgnx-pkg-pin/the-offline-reason-says-how-to-rebuild ()
  (drgnx-pkg-test--with root
    (let* ((repo (concat root "src/mp/")) (old (drgnx-pkg-pin-test--commit repo "mp" "1.0")))
      (drgnx-pkg-write-lock (list (drgnx-pkg-pin-test--pin 'mp "20260101.1200" :commit old :url repo)))
      (drgnx-pkg-pin-test--want root 'mp)
      (should (string-match-p "sync online to rebuild it from its commit"
                              (cdr (assq 'mp (plist-get (drgnx-pkg-test--sync root :offline t) :missing))))))))

(provide 'pkg-melpa-pin-test)
;;; pkg-melpa-pin-test.el ends here
