;;; pkg-signed-test.el --- batch children: signatures verify where archives sign; stock installs take the sync lock -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; Each test runs the package CLI as a batch child, as bin/drgnx does, in temp directories (HOME too) against archives
;; that are local directories.  The signed archive is signed here with a test key made in a temp GNUPGHOME, whose
;; public half goes into the sandbox's package keyring; the child counts directory archives as signing ones
;; (DRGNX_TEST_SIGNED_DIRS, pkg-child-fixture.el), as a URL archive would be.  The child that holds the sync lock
;; parks there (handshake-fixture.el) while this Emacs tries a stock install.  See docs/guide/packages.md, "Signatures".
(require 'ert)
(require 'drgnx-paths)
(require 'drgnx-pkg)
(require 'drgnx-doctor)
(load (expand-file-name "test/fixtures/pkg-fixture" drgnx-dir) nil t)
(require 'drgnx-handshake-fixture (expand-file-name "test/fixtures/handshake-fixture" drgnx-dir))
(require 'drgnx-wait-fixture (expand-file-name "test/fixtures/wait-fixture" drgnx-dir))

(defconst drgnx-pkg-signed-test--env '("DRGNX_TEST_SIGNED_DIRS=1"))

(defmacro drgnx-pkg-signed-test--with (root &rest body)
  "BODY in a child sandbox ROOT with a signing key (`drgnx-pkg-child-signer'); the key's agents stopped after."
  (declare (indent 1))
  `(drgnx-pkg-child-with ,root
     (unwind-protect (progn (drgnx-pkg-child-signer ,root) ,@body)
       (drgnx-pkg-child-gpg-stop ,root))))

(defun drgnx-pkg-signed-test--run (root &rest args)
  (drgnx-pkg-child-run root args drgnx-pkg-signed-test--env))

(defun drgnx-pkg-signed-test--want (root name archive &optional more)
  "packages.eld in ROOT asking for nothing, with the archive NAME at ROOT's ARCHIVE/ and the keys MORE."
  (drgnx-pkg-test--write (concat root "config/packages.eld")
                         (append (list :packages nil :archives `((,name . ,(concat root archive "/")))) more)))

(defun drgnx-pkg-signed-test--signed-archive (root packages)
  "ROOT's gnu/ archive with PACKAGES, every file signed."
  (drgnx-pkg-child-sign-archive root (drgnx-pkg-test--archive (concat root "gnu") packages)))

(ert-deftest drgnx-pkg/a-signed-package-is-verified-in-the-lock ()
  ;; handshake: the child is waited for to its exit
  (drgnx-pkg-signed-test--with root
    (drgnx-pkg-signed-test--signed-archive root '((fa "1.0")))
    (drgnx-pkg-signed-test--want root "gnu" "gnu")
    (let ((r (drgnx-pkg-signed-test--run root "sync" "--add" "fa")))
      (should (eql (car r) 0)))
    (should (eq (plist-get (alist-get 'fa (drgnx-pkg-child-lock root)) :verified) t))))

(ert-deftest drgnx-pkg/a-gnu-package-without-its-sig-fails-the-sync ()
  ;; handshake: the child is waited for to its exit
  (drgnx-pkg-signed-test--with root
    (drgnx-pkg-signed-test--signed-archive root '((fa "1.0") (fb "1.0")))
    (drgnx-pkg-signed-test--want root "gnu" "gnu")
    (should (eql (car (drgnx-pkg-signed-test--run root "sync" "--add" "fb")) 0))
    (delete-file (concat root "gnu/fa-1.0.el.sig"))                          ; stripped
    (let ((tree (drgnx-pkg-child-tree (concat root "data/elpa/")))
          (lock (drgnx-pkg-test--bytes (concat root "config/drgnx.lock.eld")))
          (r (drgnx-pkg-signed-test--run root "sync" "--add" "fa")))
      (should (eql (car r) 1))
      (should (string-match-p "fa-1.0.el: download failed" (cdr r)))
      (should (string-match-p "nothing was changed" (cdr r)))
      (should (equal (drgnx-pkg-child-tree (concat root "data/elpa/")) tree))
      (should (equal (drgnx-pkg-test--bytes (concat root "config/drgnx.lock.eld")) lock))
      (should-not (file-exists-p (concat root "cache/drgnx/packages/fa-1.0.el"))))))

(ert-deftest drgnx-pkg/a-melpa-package-is-never-verified ()
  ;; handshake: the child is waited for to its exit
  (drgnx-pkg-signed-test--with root
    (drgnx-pkg-test--archive (concat root "melpa") '((fa "1.0")))            ; no signatures, as MELPA
    (drgnx-pkg-signed-test--want root "melpa" "melpa")
    (should (eql (car (drgnx-pkg-signed-test--run root "sync" "--add" "fa")) 0))
    (let ((e (alist-get 'fa (drgnx-pkg-child-lock root))))
      (should (equal (plist-get e :version) "1.0"))
      (should-not (plist-member e :verified)))))

(ert-deftest drgnx-pkg/a-cache-hit-keeps-verified-only-for-the-same-hash ()
  ;; handshake: each child is waited for to its exit
  (drgnx-pkg-signed-test--with root
    (drgnx-pkg-signed-test--signed-archive root '((fa "1.0")))
    (drgnx-pkg-signed-test--want root "gnu" "gnu")
    (should (eql (car (drgnx-pkg-signed-test--run root "sync" "--add" "fa")) 0))
    ;; a new packages directory, the same cache and lock: the cached file is the one the lock verified
    (should (eql (car (drgnx-pkg-child-run root '("sync" "--offline") (cons (concat "DRGNX_DATA_DIR=" root "data2")
                                                                            drgnx-pkg-signed-test--env)))
                 0))
    (should (eq (plist-get (alist-get 'fa (drgnx-pkg-child-lock root)) :verified) t))
    ;; 1.1 is in the cache already, put there without a check: the upgrade takes it from there, unverified
    (drgnx-pkg-signed-test--signed-archive root '((fa "1.1")))
    (copy-file (concat root "gnu/fa-1.1.el") (concat root "cache/drgnx/packages/fa-1.1.el"))
    (should (eql (car (drgnx-pkg-signed-test--run root "upgrade")) 0))
    (let ((e (alist-get 'fa (drgnx-pkg-child-lock root))))
      (should (equal (plist-get e :version) "1.1"))
      (should-not (plist-member e :verified)))))

(ert-deftest drgnx-pkg/an-unlisted-unsigned-archive-names-the-fix ()
  ;; handshake: each child is waited for to its exit
  (drgnx-pkg-signed-test--with root
    (drgnx-pkg-test--archive (concat root "mine") '((fa "1.0")))             ; a custom archive that does not sign
    (drgnx-pkg-signed-test--want root "mine" "mine")
    (let ((r (drgnx-pkg-signed-test--run root "sync" "--add" "fa")))
      (should (eql (car r) 1))
      (should (string-match-p ":unsigned-archives" (cdr r)))
      (should (string-match-p "mine" (cdr r)))
      (should-not (drgnx-pkg-child-elpa root)))
    (drgnx-pkg-signed-test--want root "mine" "mine" '(:unsigned-archives ("mine")))
    (should (eql (car (drgnx-pkg-signed-test--run root "sync" "--add" "fa")) 0))
    (should-not (plist-member (alist-get 'fa (drgnx-pkg-child-lock root)) :verified))))

(ert-deftest drgnx-pkg/no-gpg-fails-a-signed-sync-and-the-doctor-says-so ()
  ;; handshake: the child is waited for to its exit; the doctor's check is read in this Emacs
  (drgnx-pkg-signed-test--with root
    (drgnx-pkg-signed-test--signed-archive root '((fa "1.0")))
    (drgnx-pkg-signed-test--want root "gnu" "gnu")
    (let ((r (drgnx-pkg-child-run root '("sync" "--add" "fa") (cons "DRGNX_TEST_GPG=/nonexistent" drgnx-pkg-signed-test--env))))
      (should (eql (car r) 1))
      (should (string-match-p "gpg is needed to check GNU ELPA's signatures" (cdr r)))
      (should-not (drgnx-pkg-child-elpa root)))
    (drgnx-pkg-test--write (concat root "config/packages.eld") '(:archives (("gnu" . "https://elpa.gnu.org/packages/"))))
    (let ((check (lambda () (drgnx-doctor-check 'packages-gpg (list :packages-gpg (drgnx-pkg-gpg-facts))))))
      (let ((epg-gpg-program "/nonexistent"))
        (let ((c (funcall check)))
          (should (eq (car c) 'fail))
          (should (string-match-p "gpg is needed to check GNU ELPA's signatures" (cadr c)))))
      (should (eq (car (funcall check)) 'ok)))))

(ert-deftest drgnx-pkg/a-stock-install-during-a-sync-refuses ()
  ;; handshake: the child holds the sync lock, parked, while this Emacs runs a stock install as a command
  (drgnx-pkg-child-with root
    (drgnx-pkg-child-want root)
    (make-directory (concat root "data/elpa") t)
    (let ((tree (drgnx-pkg-child-tree (concat root "data/elpa/")))
          (p (drgnx-pkg-child-start root '("sync" "--pending") '("held")))
          (installed nil))
      (drgnx-test-child-await p "held" :secs 120)
      (let ((this-command 'package-install) (after-init-time (current-time)))
        (let ((err (should-error (drgnx-pkg--guard (lambda (&rest _) (setq installed t)) 'fa) :type 'user-error)))
          (should (equal (cadr err) "a sync is running; try again when it ends"))))
      (should-not installed)
      (drgnx-test-child-go p)
      (drgnx-test-wait-ended p :secs 120 :what "the sync to end")
      (should (equal (drgnx-pkg-child-tree (concat root "data/elpa/")) tree))
      ;; with the lock free, the user's install runs, holding the lock, which it gives back
      (let ((this-command 'package-install) (after-init-time (current-time)))
        (drgnx-pkg--guard (lambda (&rest _) (setq installed (file-exists-p (concat root "data/sync.lock")))) 'fa))
      (should installed)
      (should-not (file-exists-p (concat root "data/sync.lock"))))))

(ert-deftest drgnx-pkg/a-staged-signed-update-stays-verified ()
  ;; handshake: each child is waited for to its exit
  (drgnx-pkg-signed-test--with root
    (drgnx-pkg-signed-test--signed-archive root '((fa "1.0")))
    (drgnx-pkg-signed-test--want root "gnu" "gnu")
    (should (eql (car (drgnx-pkg-signed-test--run root "sync" "--add" "fa")) 0))
    (drgnx-pkg-signed-test--signed-archive root '((fa "1.1")))
    (should (eql (car (drgnx-pkg-signed-test--run root "upgrade" "--only" "fa" "--stage")) 0))
    (let ((staged (with-temp-buffer (insert-file-contents (concat root "state/drgnx/extensions/staged.eld"))
                                    (read (current-buffer)))))
      (should (eq (plist-get (alist-get 'fa staged) :verified) t)))
    (should (eql (car (drgnx-pkg-signed-test--run root "upgrade" "--staged")) 0))
    (let ((e (alist-get 'fa (drgnx-pkg-child-lock root))))
      (should (equal (plist-get e :version) "1.1"))
      (should (eq (plist-get e :verified) t)))))

;;; pkg-signed-test.el ends here
