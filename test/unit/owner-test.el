;;; owner-test.el --- batch tests: who owns a Lisp file — a package, Emacs or a drgnx module -*- lexical-binding: t -*-
(require 'ert)
(require 'package)                      ; loaded before its variables are let-bound below
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-owner)

(defconst drgnx-owner-test--elpa (expand-file-name "test/fixtures/heap/" drgnx-dir)
  "A packages directory holding the fixture package wdheap-1.0.")

(defconst drgnx-owner-test--dir (expand-file-name "wdheap-1.0/" drgnx-owner-test--elpa))

(ert-deftest drgnx-owner/package-dir ()
  (let ((desc (package-desc-create :name 'wdheap :version '(1 0) :dir drgnx-owner-test--dir))
        (package-directory-list nil))
    ;; From `package-alist': the source, the byte code and the .elc name load-history keeps for native code.
    (let ((package-alist (list (list 'wdheap desc))) (package-user-dir "/nonexistent-elpa/"))
      (should (equal (drgnx-owner-of-file (expand-file-name "wdheap.el" drgnx-owner-test--dir)) '("wdheap" . "wdheap")))
      (should (equal (drgnx-owner-of-file (expand-file-name "wdheap.elc" drgnx-owner-test--dir)) '("wdheap" . "wdheap"))))
    ;; The map follows `package-alist': without the package, the file is not wdheap's.
    (let ((package-alist nil) (package-user-dir "/nonexistent-elpa/"))
      (should-not (equal (car (drgnx-owner-of-file (expand-file-name "wdheap.el" drgnx-owner-test--dir))) "wdheap")))
    ;; A session started from the quickstart file has no `package-alist': the directory under `package-user-dir'
    ;; names the package, its version taken off.
    (let ((package-alist nil) (package-user-dir drgnx-owner-test--elpa))
      (should (equal (drgnx-owner-of-file (expand-file-name "wdheap.elc" drgnx-owner-test--dir)) '("wdheap" . "wdheap"))))
    (let ((package-alist nil) (package-user-dir "/srv/elpa") (package-directory-list '("/usr/share/emacs/site-elpa/")))
      (should (equal (drgnx-owner-of-file "/srv/elpa/emacsql-sqlite3-1.0.20240101/x.el") '("emacsql-sqlite3" . "x")))
      (should (equal (drgnx-owner-of-file "/usr/share/emacs/site-elpa/s-1.13.0/s.elc") '("s" . "s")))
      (should (equal (drgnx-owner-of-file "/srv/elpa/vc-only/vc-only.el") '("vc-only" . "vc-only")))
      (should-not (drgnx-owner-of-file "/srv/elpa/drgnx-quickstart.el")))))

(ert-deftest drgnx-owner/emacs-lib ()
  (should (equal (drgnx-owner-of-file (expand-file-name "simple.elc" lisp-directory)) '("emacs" . "simple")))
  (should (equal (drgnx-owner-of-file (expand-file-name "emacs-lisp/subr-x.el.gz" lisp-directory))
                 '("emacs" . "subr-x")))
  ;; a preloaded file's name in `load-history' is relative to `lisp-directory'
  (should (equal (drgnx-owner-of-file "emacs-lisp/cl-preloaded.elc") '("emacs" . "cl-preloaded"))))

(ert-deftest drgnx-owner/drgnx-module ()
  (let ((drgnx-modules--table
         `((tools/fixture :file ,(expand-file-name "modules/tools/drgnx-fixture-ui.elc" drgnx-dir) :packages (wdheap))
           (extra/other :file ,(expand-file-name "modules/extra/drgnx-other.el" drgnx-dir) :packages nil))))
    ;; a module's file, whatever its suffix
    (should (equal (drgnx-owner-of-file (expand-file-name "modules/tools/drgnx-fixture-ui.el" drgnx-dir))
                   '("drgnx" . "tools/fixture")))
    ;; any other file of the tree: its path in it
    (should (equal (drgnx-owner-of-file (expand-file-name "core/drgnx-gc.elc" drgnx-dir)) '("drgnx" . "core/drgnx-gc")))
    (should (eq (drgnx-owner-module-for-package 'wdheap) 'tools/fixture))
    (should (eq (drgnx-owner-module-for-package "wdheap") 'tools/fixture))
    (should-not (drgnx-owner-module-for-package 'nothing))))

(ert-deftest drgnx-owner/unknown ()
  (let ((package-alist nil) (package-user-dir "/nonexistent-elpa/") (package-directory-list nil))
    (should-not (drgnx-owner-of-file "/nowhere/else/thing.el"))
    (should-not (drgnx-owner-of-file nil))))

;;; owner-test.el ends here
