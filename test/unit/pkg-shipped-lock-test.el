;;; pkg-shipped-lock-test.el --- batch tests: the shipped lock as soft pins for packages added later; its coverage -*- lexical-binding: t -*-
;; Offline and in temp dirs, like pkg-test.el: archives are local directories, the shipped lock is the sandbox's.  The
;; coverage test alone reads the checkout (modules/ and etc/drgnx.lock.eld), read-only.
(require 'ert)
(require 'drgnx-paths)
(require 'drgnx-pkg)
(load (expand-file-name "test/fixtures/pkg-fixture" drgnx-dir) nil t)   ; archives as local dirs, the sandbox

(defun drgnx-pkg-shipped-test--want (root &rest names)
  "packages.eld in ROOT's config asking for NAMES."
  (drgnx-pkg-test--write (concat root "config/packages.eld") (list :packages names)))

(defun drgnx-pkg-shipped-test--ship (&rest entries)
  "ENTRIES as the shipped lock (the sandbox's, never the checkout's)."
  (drgnx-pkg-test--write (drgnx-pkg-shipped-lock-file) (list :version 1 :packages entries)))

(defun drgnx-pkg-shipped-test--versions ()
  (mapcar (lambda (e) (cons (car e) (plist-get (cdr e) :version))) (drgnx-pkg-read-lock)))

(defun drgnx-pkg-shipped-test--archive (root)
  "Archive fx: fa, fc and fd at 1.0 and 1.1 (fd 1.0 needs fa 1.0; fd 1.1 needs fa 1.1)."
  (drgnx-pkg-test--archive (concat root "fx") '((fa "1.0") (fa "1.1") (fc "1.0") (fc "1.1")
                                                (fd "1.0" ((fa "1.0"))) (fd "1.1" ((fa "1.1"))))))

;;;; Coverage: the shipped lock has every package a module names

(ert-deftest drgnx-pkg-shipped/every-manifest-package-is-in-the-shipped-lock ()
  ;; The policy: a merge that adds a package to a module refreshes etc/drgnx.lock.eld (drgnx lock --ship), so a module
  ;; turned on later installs the tested version.  The checkout's own files, read, never changed.
  (let* ((lock (drgnx-pkg--read-lock-file (expand-file-name "etc/drgnx.lock.eld" drgnx-dir)))
         (lacking (seq-mapcat (lambda (m) (mapcar (lambda (p) (format "%s: %s" (car m) p))
                                                  (seq-remove (lambda (p) (assq p lock)) (cdr m))))
                              (drgnx-pkg--module-packages (expand-file-name "modules" drgnx-dir)))))
    (should lock)
    (should-not lacking)))

;;;; Modules turned on later

(ert-deftest drgnx-pkg-shipped/a-module-turned-on-later-installs-the-shipped-version ()
  (drgnx-pkg-test--with root
    (let ((fx (drgnx-pkg-shipped-test--archive root)))
      (drgnx-pkg-shipped-test--ship (drgnx-pkg-test--entry fx 'fa "1.0") (drgnx-pkg-test--entry fx 'fc "1.0"))
      (drgnx-pkg-shipped-test--want root 'fa)
      (should (plist-get (drgnx-pkg-test--sync root :archives `(("fx" . ,fx))) :ok))      ; the first sync: fa only
      (should (equal (drgnx-pkg-shipped-test--versions) '((fa . "1.0"))))                 ; the user lock holds installed ones
      (drgnx-pkg-shipped-test--want root 'fa 'fc)                                         ; fc's module is turned on
      (let ((r (drgnx-pkg-test--sync root :archives `(("fx" . ,fx)))))
        (should (plist-get r :ok))
        (should (equal (plist-get r :installed) '(fc))))
      (should (equal (drgnx-pkg-test--installed) '("fa-1.0" "fc-1.0")))                   ; not the archive's newest, 1.1
      (should (equal (drgnx-pkg-shipped-test--versions) '((fa . "1.0") (fc . "1.0"))))
      (should (plist-get (alist-get 'fc (drgnx-pkg-read-lock)) :sha256))                  ; hashed, as any entry
      ;; and a plain sync after that keeps it
      (should (plist-get (drgnx-pkg-test--sync root :archives `(("fx" . ,fx))) :ok))
      (should (equal (drgnx-pkg-test--installed) '("fa-1.0" "fc-1.0"))))))

(ert-deftest drgnx-pkg-shipped/a-dependency-of-a-package-turned-on-later-comes-from-the-shipped-lock-too ()
  (drgnx-pkg-test--with root
    (let ((fx (drgnx-pkg-shipped-test--archive root)))
      (drgnx-pkg-shipped-test--ship (drgnx-pkg-test--entry fx 'fa "1.0")
                                    (drgnx-pkg-test--entry fx 'fd "1.0" '((fa "1.0"))))
      (drgnx-pkg-write-lock (list (drgnx-pkg-test--entry fx 'fc "1.1")))
      (drgnx-pkg-shipped-test--want root 'fc 'fd)
      (should (plist-get (drgnx-pkg-test--sync root :archives `(("fx" . ,fx))) :ok))
      (should (equal (drgnx-pkg-test--installed) '("fa-1.0" "fc-1.1" "fd-1.0"))))))

(ert-deftest drgnx-pkg-shipped/the-users-lock-wins-over-the-shipped-one ()
  (drgnx-pkg-test--with root
    (let ((fx (drgnx-pkg-shipped-test--archive root)))
      (drgnx-pkg-shipped-test--ship (drgnx-pkg-test--entry fx 'fa "1.0") (drgnx-pkg-test--entry fx 'fc "1.0"))
      (drgnx-pkg-write-lock (list (drgnx-pkg-test--entry fx 'fa "1.1")))
      (drgnx-pkg-shipped-test--want root 'fa 'fc)
      (should (plist-get (drgnx-pkg-test--sync root :archives `(("fx" . ,fx))) :ok))
      (should (equal (drgnx-pkg-test--installed) '("fa-1.1" "fc-1.0"))))))

(ert-deftest drgnx-pkg-shipped/a-shipped-pin-nobody-serves-falls-back-with-a-warning ()
  ;; The same fallback as the first sync's (M12a-55): the archive's current version, a warning, exit 0.
  (drgnx-pkg-test--with root
    (let ((fx (drgnx-pkg-shipped-test--archive root)))
      (drgnx-pkg-shipped-test--ship (drgnx-pkg-test--entry fx 'fa "1.0")
                                    (cons 'fc (list :version "0.9" :archive "fx" :kind 'single :file "fc-0.9.el"
                                                    :sha256 "00" :requires nil :summary "gone")))
      (drgnx-pkg-write-lock (list (drgnx-pkg-test--entry fx 'fa "1.0")))
      (drgnx-pkg-shipped-test--want root 'fa 'fc)
      (let ((r (drgnx-pkg-test--sync root :archives `(("fx" . ,fx)))))
        (should (plist-get r :ok))
        (should-not (plist-get r :missing))
        (should (member "fc: shipped 0.9 no longer served; installed 1.1" (plist-get r :warnings))))
      (should (equal (drgnx-pkg-test--installed) '("fa-1.0" "fc-1.1")))
      (should (equal (drgnx-pkg-shipped-test--versions) '((fa . "1.0") (fc . "1.1")))))))

(ert-deftest drgnx-pkg-shipped/the-users-own-pin-nobody-serves-is-still-reported ()
  ;; Soft is for the shipped lock's pins only: a pin in the user's lock stays a reported, kept pin.
  (drgnx-pkg-test--with root
    (let ((fx (drgnx-pkg-shipped-test--archive root)))
      (drgnx-pkg-shipped-test--ship (drgnx-pkg-test--entry fx 'fc "1.0"))
      (drgnx-pkg-write-lock (list (cons 'fa (list :version "0.9" :archive "fx" :kind 'single :file "fa-0.9.el"
                                                  :sha256 "00" :requires nil :summary "gone"))))
      (drgnx-pkg-shipped-test--want root 'fa 'fc)
      (let ((r (drgnx-pkg-test--sync root :archives `(("fx" . ,fx)))))
        (should-not (plist-get r :ok))
        (should (assq 'fa (plist-get r :missing)))
        (should-not (plist-get r :warnings)))
      (should (equal (drgnx-pkg-shipped-test--versions) '((fa . "0.9")))))))   ; the lock as it was

(ert-deftest drgnx-pkg-shipped/an-installed-package-the-lock-lacks-is-not-moved ()
  ;; Installed by hand (or in a lock lost): the user's choice, not the shipped lock's to replace.
  (drgnx-pkg-test--with root
    (let ((fx (drgnx-pkg-shipped-test--archive root)))
      (drgnx-pkg-shipped-test--want root 'fa 'fc)
      (should (plist-get (drgnx-pkg-test--sync root :archives `(("fx" . ,fx))) :ok))        ; no shipped lock: 1.1, 1.1
      (drgnx-pkg-write-lock (list (drgnx-pkg-test--entry fx 'fa "1.1")))                      ; fc left the lock
      (drgnx-pkg-shipped-test--ship (drgnx-pkg-test--entry fx 'fc "1.0"))
      (should (plist-get (drgnx-pkg-test--sync root :archives `(("fx" . ,fx))) :ok))
      (should (equal (drgnx-pkg-test--installed) '("fa-1.1" "fc-1.1"))))))

(ert-deftest drgnx-pkg-shipped/upgrade-and-offline-sync-leave-the-shipped-lock-alone ()
  (drgnx-pkg-test--with root
    (let ((fx (drgnx-pkg-shipped-test--archive root)))
      (drgnx-pkg-shipped-test--ship (drgnx-pkg-test--entry fx 'fa "1.0") (drgnx-pkg-test--entry fx 'fc "1.0"))
      (drgnx-pkg-shipped-test--want root 'fa)
      (should (plist-get (drgnx-pkg-test--sync root :archives `(("fx" . ,fx))) :ok))
      (drgnx-pkg-shipped-test--want root 'fa 'fc)
      ;; offline: fc is not in the lock and the cache has no shipped extras to install — reported, as before
      (let ((r (drgnx-pkg-test--sync root :offline t)))
        (should-not (plist-get r :ok))
        (should (assq 'fc (plist-get r :missing)))
        (should (equal (drgnx-pkg-test--installed) '("fa-1.0"))))
      ;; upgrade takes the archives' newest, not the shipped 1.0
      (should (plist-get (drgnx-pkg-upgrade :archives `(("fx" . ,fx)) :modules-dir (concat root "mods") :smoke #'ignore) :ok))
      (should (equal (drgnx-pkg-test--installed) '("fa-1.1" "fc-1.1"))))))

(ert-deftest drgnx-pkg-shipped/a-seeded-sync-does-not-pull-the-shipped-lock-in ()
  (drgnx-pkg-test--with root
    (let ((fx (drgnx-pkg-shipped-test--archive root)))
      (drgnx-pkg-shipped-test--ship (drgnx-pkg-test--entry fx 'fc "1.0"))
      (drgnx-pkg-shipped-test--want root 'fc)
      (make-directory (concat root "other/elpa") t)
      (should (plist-get (drgnx-pkg-test--sync root :archives `(("fx" . ,fx)) :seed (concat root "other/elpa")) :ok))
      (should (equal (drgnx-pkg-test--installed) '("fc-1.1"))))))

;;;; A Git package turned on later

(defun drgnx-pkg-shipped-test--git (repo &rest args)
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory repo))
          (process-environment (append '("GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@t.invalid" "GIT_COMMITTER_NAME=t"
                                         "GIT_COMMITTER_EMAIL=t@t.invalid" "GIT_CONFIG_GLOBAL=/dev/null")
                                       process-environment)))
      (unless (eql 0 (apply #'call-process "git" nil t nil args)) (error "git %S: %s" args (buffer-string)))
      (string-trim (buffer-string)))))

(defun drgnx-pkg-shipped-test--commit (repo name version)
  "Commit NAME.el at VERSION into REPO (made if new): the commit's sha."
  (unless (file-directory-p (expand-file-name ".git" repo))
    (make-directory repo t) (drgnx-pkg-shipped-test--git repo "init" "-q" "-b" "main"))
  (write-region (format ";;; %s.el --- fixture  -*- lexical-binding: t -*-\n;; Version: %s\n;; Package-Requires: ((emacs \"29.1\"))\n;;; Code:\n(provide '%s)\n;;; %s.el ends here\n"
                        name version name name)
                nil (expand-file-name (format "%s.el" name) repo) nil 'silent)
  (drgnx-pkg-shipped-test--git repo "add" "-A")
  (drgnx-pkg-shipped-test--git repo "commit" "-q" "-m" version)
  (drgnx-pkg-shipped-test--git repo "rev-parse" "HEAD"))

(ert-deftest drgnx-pkg-shipped/a-git-package-turned-on-later-installs-the-shipped-commit ()
  (drgnx-pkg-test--with root
    (let* ((fx (drgnx-pkg-shipped-test--archive root)) (repo (concat root "src/gp/"))
           (one (drgnx-pkg-shipped-test--commit repo "gp" "0.3")))
      (drgnx-pkg-shipped-test--commit repo "gp" "0.4")                       ; the source has moved on
      (drgnx-pkg-shipped-test--ship (drgnx-pkg-test--entry fx 'fa "1.0")
                                    (cons 'gp (list :kind 'git :url repo :rev "main" :commit one :version "0.3" :requires nil)))
      (drgnx-pkg-write-lock (list (drgnx-pkg-test--entry fx 'fa "1.0")))
      (drgnx-pkg-test--write (concat root "config/packages.eld") `(:packages (fa) :git ((gp :url ,repo :rev "main"))))
      (should (plist-get (drgnx-pkg-test--sync root :archives `(("fx" . ,fx))) :ok))
      (should (member "gp-0.3" (drgnx-pkg-test--installed)))
      (should (equal (plist-get (alist-get 'gp (drgnx-pkg-read-lock)) :commit) one)))))

(provide 'pkg-shipped-lock-test)
;;; pkg-shipped-lock-test.el ends here
