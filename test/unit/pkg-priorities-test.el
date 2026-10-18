;;; pkg-priorities-test.el --- batch tests: archive priorities — releases over snapshots unless the user says otherwise -*- lexical-binding: t -*-
;; Offline and in temp dirs: the archives are local directories NAMED gnu, nongnu and melpa (the names the default
;; priorities are keyed by); never the network or the real ELPA.
(require 'ert)
(require 'drgnx-paths)
(require 'drgnx-pkg)
(load (expand-file-name "test/fixtures/pkg-fixture" drgnx-dir) nil t)   ; archives as local dirs, the sandbox

(defun drgnx-pkg-priorities-test--archives (root &optional gnu nongnu melpa)
  "Archives gnu, nongnu and melpa under ROOT with the packages GNU, NONGNU and MELPA ((NAME VERSION [REQUIRES])…):
the alist for `drgnx-pkg-sync'."
  (mapcar (lambda (a) (cons (car a) (drgnx-pkg-test--archive (concat root "arch-" (car a)) (cdr a))))
          `(("gnu" ,@gnu) ("nongnu" ,@nongnu) ("melpa" ,@melpa))))

(defun drgnx-pkg-priorities-test--ship (name version archive file)
  "The shipped lock pinning NAME at VERSION from ARCHIVE (the archive's name; FILE its file in the cache dir)."
  (drgnx-pkg-test--write (drgnx-pkg-shipped-lock-file)
                         (list :version 1 :packages (list (cons name (list :version version :archive archive :kind 'single
                                                                           :file file :requires nil :summary "fixture"))))))

(defun drgnx-pkg-priorities-test--want (root &rest names)
  "packages.eld in ROOT's config asking for NAMES."
  (drgnx-pkg-test--write (concat root "config/packages.eld") (list :packages names)))

(defun drgnx-pkg-priorities-test--version (name)
  (plist-get (alist-get name (drgnx-pkg-read-lock)) :version))

(ert-deftest drgnx-pkg-priorities/the-default-prefers-releases-to-snapshots ()
  (should (equal drgnx-pkg-default-archive-priorities '(("gnu" . 3) ("nongnu" . 2) ("melpa" . 1)))))

(ert-deftest drgnx-pkg-priorities/upgrade-keeps-a-nongnu-release-over-a-melpa-snapshot ()
  ;; The first upgrade after the shipped lock: magit 4.7.1 (NonGNU) stays; MELPA's newer snapshot does not take it over.
  (drgnx-pkg-test--with root
    (let ((archives (drgnx-pkg-priorities-test--archives root nil '((magit "4.7.1")) '((magit "20261017.1200")))))
      (drgnx-pkg-priorities-test--want root 'magit)
      (should (plist-get (drgnx-pkg-test--sync root :archives archives) :ok))
      (should (equal (drgnx-pkg-test--installed) '("magit-4.7.1")))          ; a sync with no lock: the release
      (should (equal (drgnx-pkg-priorities-test--version 'magit) "4.7.1"))
      (should (plist-get (drgnx-pkg-upgrade :archives archives :modules-dir (concat root "mods") :smoke #'ignore) :ok))
      (should (equal (drgnx-pkg-test--installed) '("magit-4.7.1")))
      (should (equal (drgnx-pkg-priorities-test--version 'magit) "4.7.1")))))

(ert-deftest drgnx-pkg-priorities/upgrade-still-moves-a-release-to-its-newer-release ()
  ;; Priorities rank archives; within the winning archive the newest still wins.
  (drgnx-pkg-test--with root
    (let ((archives (drgnx-pkg-priorities-test--archives root nil '((magit "4.7.1")) '((magit "20261017.1200")))))
      (drgnx-pkg-priorities-test--want root 'magit)
      (should (plist-get (drgnx-pkg-test--sync root :archives archives) :ok))
      (setq archives (drgnx-pkg-priorities-test--archives root nil '((magit "4.7.1") (magit "4.8.0")) '((magit "20261018.1000"))))
      (should (plist-get (drgnx-pkg-upgrade :archives archives :modules-dir (concat root "mods") :smoke #'ignore) :ok))
      (should (equal (drgnx-pkg-test--installed) '("magit-4.8.0"))))))

(ert-deftest drgnx-pkg-priorities/a-user-set-value-is-untouched ()
  (drgnx-pkg-test--with root
    ;; their own priorities: melpa first
    (let ((archives (drgnx-pkg-priorities-test--archives root nil '((magit "4.7.1")) '((magit "20261017.1200")))))
      (drgnx-pkg-test--write (concat root "config/packages.eld")
                             '(:packages (magit) :archive-priorities (("melpa" . 9) ("nongnu" . 1))))
      (should (plist-get (drgnx-pkg-test--sync root :archives archives) :ok))
      (should (equal (drgnx-pkg-test--installed) '("magit-20261017.1200"))))))

(ert-deftest drgnx-pkg-priorities/an-empty-user-value-means-no-priorities ()
  ;; :archive-priorities () is the user's setting too: the newest version wins, as package.el does by default.
  (drgnx-pkg-test--with root
    (let ((archives (drgnx-pkg-priorities-test--archives root nil '((magit "4.7.1")) '((magit "20261017.1200")))))
      (drgnx-pkg-test--write (concat root "config/packages.eld") '(:packages (magit) :archive-priorities nil))
      (should (plist-get (drgnx-pkg-test--sync root :archives archives) :ok))
      (should (equal (drgnx-pkg-test--installed) '("magit-20261017.1200"))))))

(ert-deftest drgnx-pkg-priorities/a-melpa-only-dependency-still-resolves ()
  ;; magit (NonGNU) needs mx (MELPA only) and dd 2.0, which only MELPA has (NonGNU's dd is 1.0): both come from MELPA.
  (drgnx-pkg-test--with root
    (let ((archives (drgnx-pkg-priorities-test--archives
                     root nil '((magit "4.7.1" ((mx "1.0") (dd "2.0"))) (dd "1.0"))
                     '((mx "20261017.1200") (dd "20261017.1200") (dd "2.0")))))
      (drgnx-pkg-priorities-test--want root 'magit)
      (let ((r (drgnx-pkg-test--sync root :archives archives)))
        (should (plist-get r :ok))
        (should-not (plist-get r :missing)))
      (should (member "magit-4.7.1" (drgnx-pkg-test--installed)))
      (should (member "mx-20261017.1200" (drgnx-pkg-test--installed)))
      (should (seq-find (lambda (d) (string-prefix-p "dd-" d)) (drgnx-pkg-test--installed))))))

(ert-deftest drgnx-pkg-priorities/the-first-sync-installs-the-shipped-release-and-an-upgrade-keeps-it ()
  ;; The scenario of the finding: a shipped lock with the NonGNU release, then `drgnx upgrade`.
  (drgnx-pkg-test--with root
    (let ((archives (drgnx-pkg-priorities-test--archives root nil '((magit "4.7.1")) '((magit "20261017.1200")))))
      (drgnx-pkg-priorities-test--ship 'magit "4.7.1" "nongnu" "magit-4.7.1.el")
      (drgnx-pkg-priorities-test--want root 'magit)
      (should (plist-get (drgnx-pkg-test--sync root :archives archives) :ok))
      (should (plist-get (drgnx-pkg-upgrade :archives archives :modules-dir (concat root "mods") :smoke #'ignore) :ok))
      (should (equal (drgnx-pkg-test--installed) '("magit-4.7.1"))))))


(ert-deftest drgnx-pkg-priorities/the-default-is-not-applied-to-archives-the-user-names ()
  ;; package.el ranks an unlisted archive 0, below MELPA's 1: a user's own :archives get "newest wins" unless they rank them.
  (drgnx-pkg-test--with root
    (let ((mine (drgnx-pkg-test--archive (concat root "mine") '((magit "20261018.1200"))))
          (melpa (drgnx-pkg-test--archive (concat root "melpa") '((magit "20261017.1200")))))
      (drgnx-pkg-test--write (concat root "config/packages.eld")
                             `(:packages (magit) :archives (("melpa" . ,melpa) ("mine" . ,mine))))
      (should-not (drgnx-pkg-archive-priorities))
      (should (plist-get (drgnx-pkg-test--sync root) :ok))
      (should (equal (drgnx-pkg-test--installed) '("magit-20261018.1200"))))))

(ert-deftest drgnx-pkg-priorities/a-malformed-value-is-reported ()
  (dolist (bad '(t (("melpa" . "high")) ((melpa . 1)) ("melpa")))
    (drgnx-pkg-test--with root
      (drgnx-pkg-test--write (concat root "config/packages.eld") `(:packages (magit) :archive-priorities ,bad))
      (let ((err (should-error (drgnx-pkg-archive-priorities) :type 'drgnx-pkg-error)))
        (should (string-match-p "archive-priorities" (cadr err)))))))

(provide 'pkg-priorities-test)
;;; pkg-priorities-test.el ends here
