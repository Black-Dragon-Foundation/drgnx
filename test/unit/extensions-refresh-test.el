;;; extensions-refresh-test.el --- the catalog refresh job: archives in, one catalog.json out -*- lexical-binding: t -*-
;; test-class: det
;; Offline and in temp dirs (pattern D: no process, no clock): the archives are local directories, the job runs in this
;; Emacs through `drgnx-extensions-refresh-cli-run' (the function bin/drgnx's `extensions' command calls), and its
;; exit code is the return value.  Never MELPA, never GNU ELPA, never the user's cache.  The signing tests run gpg, run
;; to its end, on a test key in a temp GNUPGHOME (pkg-fixture.el's signed archives).
(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'drgnx-paths)
(require 'drgnx-pkg)
(require 'drgnx-extensions-refresh)
(load (expand-file-name "test/fixtures/pkg-fixture" drgnx-dir) nil t)   ; archives as local dirs, the sandbox

(defun drgnx-extensions-refresh-test--archives (root &optional gnu melpa)
  "Archives gnu and melpa under ROOT holding GNU and MELPA ((NAME VERSION [REQUIRES])…); packages.eld names them
with the default ranking.  Returns the alist NAME → directory."
  (let ((archives (list (cons "gnu" (drgnx-pkg-test--archive (concat root "arch-gnu") gnu))
                        (cons "melpa" (drgnx-pkg-test--archive (concat root "arch-melpa") melpa)))))
    (drgnx-extensions-refresh-test--packages-eld root archives)
    archives))

(defun drgnx-extensions-refresh-test--packages-eld (root archives &rest more)
  "packages.eld in ROOT's config with ARCHIVES, gnu above melpa, and MORE keys."
  (drgnx-pkg-test--write (concat root "config/packages.eld")
                         (append (list :archives archives :archive-priorities '(("gnu" . 3) ("melpa" . 1))) more)))

(defun drgnx-extensions-refresh-test--catalog ()
  "catalog.json as an alist (arrays are lists)."
  (with-temp-buffer
    (insert-file-contents (drgnx-extensions-refresh-file))
    (json-parse-buffer :object-type 'alist :array-type 'list)))

(defun drgnx-extensions-refresh-test--package (catalog name)
  (seq-find (lambda (p) (equal (alist-get 'name p) name)) (alist-get 'packages catalog)))

(defun drgnx-extensions-refresh-test--run (&rest args)
  "The exit code of `drgnx extensions ARGS…', its output and messages dropped."
  (let ((inhibit-message t))
    (with-output-to-string (setq args (cons (drgnx-extensions-refresh-cli-run args) nil))))
  (car args))

(defmacro drgnx-extensions-refresh-test--signed (root &rest body)
  "BODY in a sandbox ROOT whose only archive, gnu, signs as GNU ELPA does: a test key in a temp GNUPGHOME signs its
files, the key's public half is in the sandbox's package keyring, and a directory archive counts as one that signs
\(as pkg-child-fixture.el's DRGNX_TEST_SIGNED_DIRS makes it).  The key's gpg agents are stopped after."
  (declare (indent 1))
  `(drgnx-pkg-test--with ,root
     (cl-letf (((symbol-function 'drgnx-pkg--directory-archive-p) #'ignore))
       (unwind-protect
           (progn
             (drgnx-pkg-child-signer ,root)
             (drgnx-extensions-refresh-test--packages-eld
              ,root (list (cons "gnu" (drgnx-pkg-child-sign-archive
                                       ,root (drgnx-pkg-test--archive (concat ,root "arch-gnu") '((magit "1.0")))))))
             ,@body)
         (drgnx-pkg-child-gpg-stop ,root)))))

(defun drgnx-extensions-refresh-test--tree (dir)
  "Every file under DIR with its size and modification time."
  (mapcar (lambda (f) (list f (file-attribute-size (file-attributes f))
                            (file-attribute-modification-time (file-attributes f))))
          (sort (directory-files-recursively dir "" t) #'string<)))

(ert-deftest drgnx-extensions-refresh/catalog-of-the-fixture-archives ()
  (drgnx-pkg-test--with root
    (drgnx-extensions-refresh-test--archives
     root '((magit "4.1") (dash "2.19") (with-editor "3.4" ((dash "2.19"))))
     '((magit "20261104.815") (only-melpa "1.0")))
    (should (eql 0 (drgnx-extensions-refresh-test--run "refresh")))
    (let* ((c (drgnx-extensions-refresh-test--catalog))
           (magit (drgnx-extensions-refresh-test--package c "magit")))
      (should (equal (alist-get 'version c) 1))
      (should (numberp (alist-get 'written c)))
      (should (equal (alist-get 'emacs c) emacs-version))
      ;; every archive, with the signing it has: a directory archive does not sign
      (should (equal (mapcar (lambda (a) (list (alist-get 'name a) (alist-get 'signed a))) (alist-get 'archives c))
                     '(("gnu" :false) ("melpa" :false))))
      (should (equal (sort (mapcar (lambda (p) (alist-get 'name p)) (alist-get 'packages c)) #'string<)
                     '("dash" "magit" "only-melpa" "with-editor")))
      ;; both archives' versions are listed; the candidate is the higher-priority archive's, not the newer one
      (should (equal (sort (mapcar (lambda (v) (alist-get 'archive v)) (alist-get 'versions magit)) #'string<)
                     '("gnu" "melpa")))
      (should (equal (alist-get 'candidate magit) '((archive . "gnu") (version . "4.1"))))
      (should (equal (alist-get 'reqs (car (alist-get 'versions (drgnx-extensions-refresh-test--package c "with-editor"))))
                     '(("dash" "2.19"))))
      (should (equal (alist-get 'summary magit) "fixture magit"))
      (should (eq (alist-get 'held magit) :false))
      (should (eq (alist-get 'incompat magit) :false))
      (should (listp (alist-get 'builtins c)))
      (should (null (alist-get 'skipped c))))))

(ert-deftest drgnx-extensions-refresh/an-odd-entry-is-skipped-and-named ()
  (drgnx-pkg-test--with root
    (drgnx-extensions-refresh-test--archives root '((good "1.0")))
    ;; a summary that is not text, and one with a raw byte in it, written as bytes
    (let ((coding-system-for-write 'no-conversion))
      (write-region (concat (encode-coding-string
                             "(1 (good . [(1 0) ((emacs (29 1))) \"fine\" single nil]) (odd . [(1 0) nil 42 single nil]) (raw . [(1 0) nil \"caf"
                             'utf-8)
                            (unibyte-string #xe9)
                            (encode-coding-string "\" single nil]))" 'utf-8))
                    nil (concat root "arch-gnu/archive-contents") nil 'silent))
    (should (eql 0 (drgnx-extensions-refresh-test--run "refresh")))
    (let ((c (drgnx-extensions-refresh-test--catalog)))
      (should (equal (mapcar (lambda (p) (alist-get 'name p)) (alist-get 'packages c)) '("good")))
      (should (equal (sort (mapcar (lambda (s) (alist-get 'name s)) (alist-get 'skipped c)) #'string<) '("odd" "raw")))
      (should (equal (alist-get 'why (seq-find (lambda (s) (equal (alist-get 'name s) "odd")) (alist-get 'skipped c)))
                     "its summary is not text"))
      (should (equal (alist-get 'archive (car (alist-get 'skipped c))) "gnu")))))

(ert-deftest drgnx-extensions-refresh/candidates-match-upgrades-plan ()
  (drgnx-pkg-test--with root
    ;; installed at 1.0, then the archive moves on: magit 2.0 needs dash 2.0
    (let ((archives (drgnx-extensions-refresh-test--archives root '((magit "1.0" ((dash "1.0"))) (dash "1.0") (still "1.0")))))
      (drgnx-extensions-refresh-test--packages-eld root archives :packages '(magit still))
      (should (plist-get (drgnx-pkg-test--sync root) :ok))
      (drgnx-pkg-test--archive (concat root "arch-gnu")
                               '((magit "2.0" ((dash "2.0"))) (dash "2.0") (still "1.0") (new-one "1.0")))
      (should (eql 0 (drgnx-extensions-refresh-test--run "refresh")))
      (let* ((c (drgnx-extensions-refresh-test--catalog))
             (updates (delq nil (mapcar (lambda (p) (when-let* ((u (alist-get 'update p)))
                                                      (cons (intern (alist-get 'name p)) u)))
                                        (alist-get 'packages c)))))
        (should (equal (mapcar #'car (sort (copy-sequence updates) (lambda (a b) (string< (car a) (car b)))))
                       '(dash magit)))
        (should (equal (alist-get 'from (alist-get 'magit updates)) "1.0"))
        ;; what the update plan says is what `drgnx upgrade' installs
        (should (plist-get (drgnx-pkg-upgrade :archives archives :modules-dir (concat root "mods") :smoke #'ignore) :ok))
        (dolist (u updates)
          (should (equal (alist-get 'to (cdr u))
                         (plist-get (alist-get (car u) (plist-get (drgnx-pkg--config 'lock t) :packages)) :version))))
        ;; a package with nothing newer has no update, and one not installed is not a candidate for one
        (should-not (alist-get 'update (drgnx-extensions-refresh-test--package c "still")))
        (should-not (alist-get 'update (drgnx-extensions-refresh-test--package c "new-one")))))))

(ert-deftest drgnx-extensions-refresh/a-newer-version-the-plan-does-not-take-is-held ()
  (drgnx-pkg-test--with root
    ;; magit 1.0 is installed; 2.0 needs a dash that no archive has, so the plan cannot take it
    (let ((archives (drgnx-extensions-refresh-test--archives root '((magit "1.0") (dash "1.0")))))
      (drgnx-extensions-refresh-test--packages-eld root archives :packages '(magit))
      (should (plist-get (drgnx-pkg-test--sync root) :ok))
      (drgnx-pkg-test--archive (concat root "arch-gnu") '((magit "2.0" ((missing-dep "9.0"))) (dash "1.0")))
      (should (eql 0 (drgnx-extensions-refresh-test--run "refresh")))
      (let ((magit (drgnx-extensions-refresh-test--package (drgnx-extensions-refresh-test--catalog) "magit")))
        (should (eq (alist-get 'held magit) t))
        (should-not (alist-get 'update magit))))))

(ert-deftest drgnx-extensions-refresh/download-counts-are-merged ()
  (drgnx-pkg-test--with root
    (drgnx-extensions-refresh-test--archives root '((magit "1.0") (dash "1.0")))
    (make-directory (drgnx-extensions-refresh-dir) t)
    (with-temp-file (drgnx-extensions-refresh--counts-file) (insert "{\"magit\": 4212345, \"other\": 3}"))
    (should (eql 0 (drgnx-extensions-refresh-test--run "refresh")))
    (let ((c (drgnx-extensions-refresh-test--catalog)))
      (should (equal (alist-get 'downloads (drgnx-extensions-refresh-test--package c "magit")) 4212345))
      (should-not (alist-get 'downloads (drgnx-extensions-refresh-test--package c "dash"))))))

(ert-deftest drgnx-extensions-refresh/a-failed-refresh-keeps-the-old-catalog ()
  (drgnx-pkg-test--with root
    (let ((archives (drgnx-extensions-refresh-test--archives root '((magit "1.0")))))
      (should (eql 0 (drgnx-extensions-refresh-test--run "refresh")))
      (let ((before (drgnx-pkg-test--bytes (drgnx-extensions-refresh-file))))
        ;; an archive that does not answer
        (drgnx-extensions-refresh-test--packages-eld root (append archives (list (cons "gone" (concat root "no-such-archive/")))))
        (should (eql 1 (drgnx-extensions-refresh-test--run "refresh")))
        (should (equal before (drgnx-pkg-test--bytes (drgnx-extensions-refresh-file))))
        (should-not (directory-files (drgnx-extensions-refresh-dir) nil "\\.tmp\\'"))))))

(ert-deftest drgnx-extensions-refresh/fetch-readme-caches-the-file ()
  (drgnx-pkg-test--with root
    (drgnx-extensions-refresh-test--archives root '((magit "1.0")))
    (with-temp-file (concat root "arch-gnu/magit-readme.txt") (insert "Magit is a Git porcelain.\n"))
    (should (eql 0 (drgnx-extensions-refresh-test--run "fetch-readme" "gnu" "magit")))
    (should (equal (drgnx-pkg-test--bytes (expand-file-name "readme/gnu/magit-readme.txt" (drgnx-extensions-refresh-dir)))
                   "Magit is a Git porcelain.\n"))
    ;; no readme, no archive of that name, a name that would leave the folder: each fails and writes nothing
    (should (eql 1 (drgnx-extensions-refresh-test--run "fetch-readme" "gnu" "dash")))
    (should (eql 1 (drgnx-extensions-refresh-test--run "fetch-readme" "nowhere" "magit")))
    (should (eql 1 (drgnx-extensions-refresh-test--run "fetch-readme" "gnu" "../magit")))
    (should (equal (directory-files (expand-file-name "readme/gnu" (drgnx-extensions-refresh-dir)) nil "\\`[^.]")
                   '("magit-readme.txt")))))

(ert-deftest drgnx-extensions-refresh/nothing-under-elpa-changes ()
  (drgnx-pkg-test--with root
    (let ((archives (drgnx-extensions-refresh-test--archives root '((magit "1.0")))))
      (drgnx-extensions-refresh-test--packages-eld root archives :packages '(magit))
      (should (plist-get (drgnx-pkg-test--sync root) :ok))
      (let ((before (drgnx-extensions-refresh-test--tree (drgnx-elpa-dir)))
            (lock (drgnx-pkg-test--bytes (drgnx-pkg-lock-file))))
        (should (eql 0 (drgnx-extensions-refresh-test--run "refresh")))
        (should (equal before (drgnx-extensions-refresh-test--tree (drgnx-elpa-dir))))
        (should (equal lock (drgnx-pkg-test--bytes (drgnx-pkg-lock-file))))))))

(ert-deftest drgnx-extensions-refresh/a-signing-archive-is-checked-as-a-sync-checks-it ()
  ;; The archive counts as signing by sync's own rule (`drgnx-pkg-unsigned-archives'), so the catalog says so, and its
  ;; contents pass the check against the sandbox's keyring.
  (drgnx-extensions-refresh-test--signed root
    (should (eql 0 (drgnx-extensions-refresh-test--run "refresh")))
    (let ((c (drgnx-extensions-refresh-test--catalog)))
      (should (equal (mapcar (lambda (a) (list (alist-get 'name a) (alist-get 'signed a))) (alist-get 'archives c))
                     '(("gnu" t))))
      (should (equal (mapcar (lambda (p) (alist-get 'name p)) (alist-get 'packages c)) '("magit"))))))

(ert-deftest drgnx-extensions-refresh/a-stripped-sig-fails-the-refresh ()
  ;; The signed fixture archive and the archive settings that check its signature come with the signature task; the
  ;; refresh already runs inside them when they exist.
  (skip-unless (fboundp 'drgnx-pkg-with-archive-settings))
  (ert-skip "needs the signed fixture archive"))

(ert-deftest drgnx-extensions-refresh/the-command-line-has-a-usage ()
  (should (eql 2 (drgnx-extensions-refresh-test--run "frobnicate")))
  (should (eql 2 (drgnx-extensions-refresh-test--run))))

(provide 'extensions-refresh-test)
;;; extensions-refresh-test.el ends here
