;;; pkg-git-test.el --- batch tests: drgnx sync from Git sources — pinned commits, the lock, offline, upgrade -*- lexical-binding: t -*-
;; Offline and in temp dirs, like pkg-test.el: the Git sources are local repositories made here.
(require 'ert)
(require 'drgnx-paths)
(require 'drgnx-pkg)
(load (expand-file-name "test/fixtures/pkg-fixture" drgnx-dir) nil t)   ; archives as local dirs, the sandbox

(defun drgnx-pkg-git-test--git (dir &rest args)
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir))
          (process-environment (append '("GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@t.invalid" "GIT_COMMITTER_NAME=t"
                                         "GIT_COMMITTER_EMAIL=t@t.invalid")
                                       process-environment)))
      (unless (eql 0 (apply #'call-process "git" nil t nil args)) (error "git %S: %s" args (buffer-string)))
      (string-trim (buffer-string)))))

(defun drgnx-pkg-git-test--commit (repo name &optional version requires body)
  "Commit NAME.el (VERSION, REQUIRES, BODY) into REPO (made if new); the commit's sha."
  (unless (file-directory-p (expand-file-name ".git" repo))
    (make-directory repo t) (drgnx-pkg-git-test--git repo "init" "-q" "-b" "main"))
  (write-region (format ";;; %s.el --- fixture %s  -*- lexical-binding: t -*-\n%s;; Package-Requires: %S\n;;; Code:\n%s\n(defun %s-hello () %S)\n(provide '%s)\n;;; %s.el ends here\n"
                        name name (if version (format ";; Version: %s\n" version) "")
                        (cons '(emacs "29.1") (mapcar (lambda (r) (list (car r) (cadr r))) requires))
                        (or body "") name (or version "dev") name name)
                nil (expand-file-name (format "%s.el" name) repo) nil 'silent)
  (drgnx-pkg-git-test--git repo "add" "-A")
  (drgnx-pkg-git-test--git repo "commit" "-q" "-m" (format "%s %s" name (or version "dev")))
  (drgnx-pkg-git-test--git repo "rev-parse" "HEAD"))

(defun drgnx-pkg-git-test--want-git (root git &rest names)
  "packages.eld asking for NAMES, with GIT sources ((NAME :url … :rev …)…)."
  (drgnx-pkg-test--write (concat root "config/packages.eld") (list :packages names :git git)))

(defun drgnx-pkg-git-test--hello (name)
  "NAME-hello as the installed package defines it (loaded from the elpa dir)."
  (let ((dir (car (directory-files (drgnx-elpa-dir) t (format "\\`%s-[0-9]" name)))))
    (load (expand-file-name (format "%s.el" name) dir) nil t)
    (funcall (intern (format "%s-hello" name)))))

(ert-deftest drgnx-pkg-git/a-git-package-installs-at-its-commit-with-its-dependencies ()
  (drgnx-pkg-test--with root
    (let* ((arch (drgnx-pkg-test--archive (concat root "arch") '((fa "1.0"))))
           (repo (concat root "src/gp/")) (sha (drgnx-pkg-git-test--commit repo "gp" "0.3" '((fa "1.0")))))
      (drgnx-pkg-git-test--want-git root `((gp :url ,repo :rev "main")))
      (let ((r (drgnx-pkg-test--sync root :archives `(("fx" . ,arch)))))
        (should (plist-get r :ok))
        (should (equal (sort (mapcar #'symbol-name (plist-get r :installed)) #'string<) '("fa" "gp"))))
      (should (member "gp-0.3" (drgnx-pkg-test--installed)))
      (let ((e (alist-get 'gp (drgnx-pkg-read-lock))))
        (should (eq (plist-get e :kind) 'git))
        (should (equal (plist-get e :commit) sha))
        (should (equal (plist-get e :url) repo))
        (should (equal (plist-get e :version) "0.3"))
        (should (equal (plist-get e :requires) '((fa "1.0")))))
      (should (plist-get (alist-get 'fa (drgnx-pkg-read-lock)) :sha256)))))   ; its dependency: an archive's, hashed

(ert-deftest drgnx-pkg-git/the-lock-holds-the-commit-until-upgrade ()
  (drgnx-pkg-test--with root
    (let* ((repo (concat root "src/gp/")) (one (drgnx-pkg-git-test--commit repo "gp" "0.3")))
      (drgnx-pkg-git-test--want-git root `((gp :url ,repo :rev "main")))
      (drgnx-pkg-test--sync root :archives nil)
      (let ((two (drgnx-pkg-git-test--commit repo "gp" "0.4")))
        ;; the source moved on: sync keeps the locked commit
        (drgnx-pkg-test--sync root :archives nil)
        (should (equal (plist-get (alist-get 'gp (drgnx-pkg-read-lock)) :commit) one))
        (should (equal (drgnx-pkg-git-test--hello "gp") "0.3"))
        ;; upgrade takes the branch's newest commit
        (drgnx-pkg-test--sync root :archives nil :upgrade t)
        (should (equal (plist-get (alist-get 'gp (drgnx-pkg-read-lock)) :commit) two))
        (should (member "gp-0.4" (drgnx-pkg-test--installed)))
        (should-not (member "gp-0.3" (drgnx-pkg-test--installed)))))))

(ert-deftest drgnx-pkg-git/offline-from-the-cached-clone ()
  (drgnx-pkg-test--with root
    (let* ((repo (concat root "src/gp/")) (sha (drgnx-pkg-git-test--commit repo "gp" "0.3")))
      (drgnx-pkg-git-test--want-git root `((gp :url ,repo :rev "main")))
      (drgnx-pkg-test--sync root :archives nil)
      (delete-directory repo t)                                           ; the source is gone
      (delete-directory (drgnx-elpa-dir) t)                               ; so are the packages
      (let ((r (drgnx-pkg-test--sync root :offline t)))
        (should (plist-get r :ok))
        (should (member "gp-0.3" (drgnx-pkg-test--installed)))
        (should (equal (plist-get (alist-get 'gp (drgnx-pkg-read-lock)) :commit) sha))))))

(ert-deftest drgnx-pkg-git/a-rev-that-is-not-there-is-missing-and-the-rest-installs ()
  (drgnx-pkg-test--with root
    (let* ((arch (drgnx-pkg-test--archive (concat root "arch") '((fa "1.0"))))
           (repo (concat root "src/gp/")))
      (drgnx-pkg-git-test--commit repo "gp" "0.3")
      (drgnx-pkg-git-test--want-git root `((gp :url ,repo :rev "no-such-branch")) 'fa)
      (let ((r (drgnx-pkg-test--sync root :archives `(("fx" . ,arch)))))
        (should-not (plist-get r :ok))
        (should (string-search "no-such-branch" (alist-get 'gp (plist-get r :missing))))
        (should (member "fa-1.0" (drgnx-pkg-test--installed)))))))

(ert-deftest drgnx-pkg-git/no-version-header-takes-the-commit-date ()
  (drgnx-pkg-test--with root
    (let ((repo (concat root "src/gp/")))
      (drgnx-pkg-git-test--commit repo "gp")
      (drgnx-pkg-git-test--want-git root `((gp :url ,repo :rev "main")))
      (should (plist-get (drgnx-pkg-test--sync root :archives nil) :ok))
      (should (string-match-p "\\`0\\.0\\.0\\.[0-9]\\{8\\}\\'" (plist-get (alist-get 'gp (drgnx-pkg-read-lock)) :version))))))

(ert-deftest drgnx-pkg-git/a-module-package-with-a-drgnx-git-source ()
  ;; a module names the package; drgnx's table says where it comes from
  (drgnx-pkg-test--with root
    (let* ((repo (concat root "src/gp/")) (mods (concat root "mods/x/"))
           (drgnx-pkg-git-sources `((gp :url ,repo :rev "main"))))
      (drgnx-pkg-git-test--commit repo "gp" "0.3")
      (make-directory mods t)
      (write-region "(drgnx-module-define 'x/gp :packages '(gp))\n" nil (concat mods "drgnx-gp.el") nil 'silent)
      (drgnx-pkg-test--write (concat root "config/packages.eld") nil)
      (should (plist-get (drgnx-pkg-sync :modules-dir (concat root "mods") :archives nil) :ok))
      (should (member "gp-0.3" (drgnx-pkg-test--installed))))))

(ert-deftest drgnx-pkg-git/an-offline-first-sync-names-the-git-packages-and-installs-the-rest ()
  ;; The shipped lock holds a Git entry; a new machine has the archive files in its cache but no clone yet.
  (drgnx-pkg-test--with root
    (let* ((arch (drgnx-pkg-test--archive (concat root "arch") '((fa "1.0"))))
           (repo (concat root "src/gp/")))
      (drgnx-pkg-git-test--commit repo "gp" "0.3")
      (drgnx-pkg-git-test--want-git root `((gp :url ,repo :rev "main")) 'fa)
      (drgnx-pkg-test--sync root :archives `(("fx" . ,arch)))
      (rename-file (drgnx-pkg-lock-file) (drgnx-pkg-shipped-lock-file))     ; that lock, shipped
      (delete-directory (expand-file-name "git" (drgnx-package-cache-dir)) t)
      (let ((process-environment (cons (concat "DRGNX_DATA_DIR=" root "data2") process-environment)))
        (let ((r (drgnx-pkg-test--sync root :offline t)))
          (should-not (plist-get r :ok))
          (should (equal (mapcar #'car (plist-get r :missing)) '(gp)))
          (should (string-match-p "sync online" (alist-get 'gp (plist-get r :missing))))
          (should (equal (drgnx-pkg-test--installed) '("fa-1.0"))))
        (should (eq (plist-get (alist-get 'gp (drgnx-pkg-read-lock)) :kind) 'git))))))   ; the copy stays for the next sync

;;; pkg-git-test.el ends here
