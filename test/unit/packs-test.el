;;; packs-test.el --- batch tests: language packs — manifests, the lock, the pack job's hand-off, active.eld, rollback -*- lexical-binding: t -*-
;; test-class: det
;; Offline and in a temp sandbox, like pkg-test.el: the pack job is a function that stages fake libraries, so no grammar
;; is built here (the Rust side has its own tests: runtime/crates/skald/tests/job.rs, drgnx-ratatoskr/tests/packs_sync.rs).
(require 'ert)
(require 'drgnx-paths)
(require 'drgnx-pkg)
(require 'drgnx-packs)
(load (expand-file-name "test/fixtures/pkg-fixture" drgnx-dir) nil t)

(defun drgnx-packs-test--pack (dir name &rest manifest)
  "Pack NAME in the packs folder DIR with MANIFEST's keys added to the required ones."
  (make-directory (expand-file-name name dir) t)
  (with-temp-file (expand-file-name (concat name "/pack.eld") dir)
    (prin1 (append (list :pack name :schema 1 :version "1" :name name :summary "s" :license "MIT") manifest)
           (current-buffer))))

(defun drgnx-packs-test--grammar (name &optional required)
  (list :name (intern name) :repo (format "https://example.org/tree-sitter-%s" name) :commit (make-string 40 ?a)
        :tree-sha256 (make-string 64 ?b) :src "src" :required required))

(defun drgnx-packs-test--job (&optional calls)
  "A job function that stages a fake library per unit and records the plans in the cons CALLS."
  (lambda (plan)
    (when calls (setcdr calls (cons plan (cdr calls))))
    (list :ok t
          :staged (mapcar (lambda (u)
                            (let* ((name (plist-get u :name)) (commit (plist-get u :commit))
                                   (dir (expand-file-name (format "grammars/%s/%s/" name commit) (plist-get plan :staging)))
                                   (lib (expand-file-name (format "libtree-sitter-%s.so" name) dir)))
                              (make-directory dir t)
                              (with-temp-file lib (insert "fake " name))
                              (list :name name :commit commit :tree-sha256 (plist-get u :tree-sha256) :lib lib
                                    :lib-sha256 (make-string 64 ?c) :abi 14)))
                          (plist-get plan :units)))))

(defmacro drgnx-packs-test--with (root &rest body)
  "BODY in a sandbox ROOT whose built-in packs are `alpha' (owns the alpha grammar) and `beta' (references it, owns beta)."
  (declare (indent 1))
  `(drgnx-pkg-test--with ,root
     (let ((drgnx-packs-dir (concat ,root "packs/")) (drgnx-packs--manifests nil)
           (drgnx-packs-job-function (drgnx-packs-test--job)))
       (drgnx-packs-test--pack drgnx-packs-dir "alpha" :grammars (list (drgnx-packs-test--grammar "alpha" t))
                               :mode '(:ts alpha-ts-mode :builtin t))
       (make-directory (concat drgnx-packs-dir "alpha/queries") t)
       (write-region "(function) @definition.function" nil (concat drgnx-packs-dir "alpha/queries/tags.scm") nil 'silent)
       (drgnx-packs-test--pack drgnx-packs-dir "beta"
                               :grammars (list (list :name 'alpha :from-pack "alpha" :required t)
                                               (drgnx-packs-test--grammar "beta")))
       ,@body)))

(defun drgnx-packs-test--active-names ()
  (mapcar #'car (plist-get (drgnx-packs-active) :packs)))

;;;; Manifests

(ert-deftest drgnx-packs/the-shipped-packs-read-and-name-their-folders ()
  (let ((drgnx-packs-dir nil) (drgnx-packs--manifests nil))
    (let ((packs (drgnx-packs-builtins)))
      (should (>= (length packs) 19))
      (dolist (p packs) (should (equal (car p) (plist-get (cdr p) :pack))))
      (should (eq (plist-get (plist-get (drgnx-packs-manifest "python") :mode) :ts) 'python-ts-mode))
      (should (equal (plist-get (plist-get (drgnx-packs-manifest "tsx") :files) :extensions) '("tsx"))))))

(ert-deftest drgnx-packs/a-manifest-with-a-reader-macro-or-a-wrong-schema-is-refused ()
  (drgnx-packs-test--with root
    (let ((f (concat root "packs/bad.eld")))
      (with-temp-file f (insert "(:pack \"bad\" :schema 2)"))
      (should-error (drgnx-packs-read-manifest f) :type 'drgnx-packs-error)
      (with-temp-file f (insert "(:pack \"bad\" :schema 1 :x #.(delete-file \"/nonexistent\"))"))
      (should-error (drgnx-packs-read-manifest f)))))

(ert-deftest drgnx-packs/the-tree-hash-matches-the-rust-one ()
  ;; the known answer of runtime/crates/skald/tests/job.rs
  (let ((d (make-temp-file "tree" t)))
    (unwind-protect
        (progn (make-directory (concat d "/a/") t)
               (write-region "hi\n" nil (concat d "/a/b.txt") nil 'silent)
               (write-region "x\n" nil (concat d "/c.sh") nil 'silent)
               (set-file-modes (concat d "/c.sh") #o755)
               (make-directory (concat d "/.git/") t)
               (write-region "ref" nil (concat d "/.git/HEAD") nil 'silent)
               (should (equal (drgnx-packs-tree-hash d) "516c92587f97152e1089d58248b0bac1062d8b2203d1d64e2e51bb98d208facf")))
      (delete-directory d t))))

;;;; Sync

(ert-deftest drgnx-packs/sync-builds-writes-the-lock-then-the-folders-then-active ()
  (drgnx-packs-test--with root
    (let* ((calls (list nil)) (drgnx-packs-job-function (drgnx-packs-test--job calls))
           (r (drgnx-packs-sync :add '("alpha"))))
      (should (equal (plist-get r :packs) '("alpha")))
      (should (equal (plist-get r :built) '("alpha")))
      (should (= 1 (length (cdr calls))))
      (let ((plan (cadr calls)))
        (should (= 14 (plist-get plan :min-abi)))
        (should (equal (plist-get (car (plist-get plan :units)) :name) "alpha"))
        ;; the pack's own query files are compiled against its main grammar by the job
        (should (equal (mapcar (lambda (q) (list (plist-get q :grammar) (plist-get q :file))) (plist-get plan :queries))
                       '(("alpha" "queries/tags.scm")))))
      (let ((e (assq 'alpha (drgnx-packs-locked))))
        (should (eq (plist-get (cdr e) :wanted) 'user))
        (should (equal (plist-get (cdr e) :commit) (drgnx-packs-tree-hash (concat root "packs/alpha/")))))
      (let ((g (assq 'alpha (drgnx-packs-locked-grammars))))
        (should (equal (plist-get (cdr g) :commit) (make-string 40 ?a)))
        (should (equal (plist-get (cdr g) :owner) "alpha")))
      (should (file-exists-p (expand-file-name "libtree-sitter-alpha.so" (drgnx-packs-grammar-dir 'alpha (make-string 40 ?a)))))
      (should-not (file-exists-p (drgnx-packs-staging-dir)))
      (should (equal (drgnx-packs-test--active-names) '(alpha)))
      (let ((a (cdr (assq 'alpha (plist-get (drgnx-packs-active) :packs)))))
        (should (equal (car (car (plist-get a :grammars))) 'alpha))
        (should (file-directory-p (cdr (car (plist-get a :grammars))))))
      (should (drgnx-pkg-current-generation)))))

(ert-deftest drgnx-packs/a-built-grammar-is-not-built-again ()
  (drgnx-packs-test--with root
    (drgnx-packs-sync :add '("alpha"))
    (let* ((calls (list nil)) (drgnx-packs-job-function (drgnx-packs-test--job calls)))
      (drgnx-packs-sync :add '("alpha"))
      (should-not (cdr calls)))))

(ert-deftest drgnx-packs/a-failing-job-changes-nothing ()
  (drgnx-packs-test--with root
    (drgnx-packs-sync :add '("alpha"))
    (let ((lock-before (with-temp-buffer (insert-file-contents (drgnx-pkg-lock-file)) (buffer-string)))
          (active-before (with-temp-buffer (insert-file-contents (drgnx-packs-active-file)) (buffer-string)))
          (drgnx-packs-job-function (lambda (_) (list :ok nil :error "the beta tree hash is wrong"))))
      (should-error (drgnx-packs-sync :add '("beta")) :type 'drgnx-packs-error)
      (should (equal lock-before (with-temp-buffer (insert-file-contents (drgnx-pkg-lock-file)) (buffer-string))))
      (should (equal active-before (with-temp-buffer (insert-file-contents (drgnx-packs-active-file)) (buffer-string))))
      (should-not (file-exists-p (drgnx-packs-staging-dir)))
      (should-not (file-exists-p (drgnx-packs-grammar-dir 'beta (make-string 40 ?a)))))))

(ert-deftest drgnx-packs/a-failure-after-the-lock-leaves-active-and-the-folders-alone ()
  (drgnx-packs-test--with root
    (drgnx-packs-sync :add '("alpha"))
    (let ((active-before (with-temp-buffer (insert-file-contents (drgnx-packs-active-file)) (buffer-string))))
      (cl-letf (((symbol-function 'drgnx-pkg-snapshot) (lambda (&rest _) (error "disk full"))))
        (should-error (drgnx-packs-sync :add '("beta"))))
      (should (equal active-before (with-temp-buffer (insert-file-contents (drgnx-packs-active-file)) (buffer-string))))
      (should-not (file-exists-p (expand-file-name "libtree-sitter-beta.so" (drgnx-packs-grammar-dir 'beta (make-string 40 ?a)))))
      (should-not (file-exists-p (drgnx-packs-staging-dir)) ))))

(ert-deftest drgnx-packs/an-unknown-pack-is-refused-before-anything-changes ()
  (drgnx-packs-test--with root
    (should-error (drgnx-packs-sync :add '("nope")) :type 'drgnx-packs-error)
    (should-not (drgnx-packs-locked))
    (should-not (file-exists-p (drgnx-packs-active-file)))))

(ert-deftest drgnx-packs/a-pack-that-references-a-grammar-brings-its-owner ()
  (drgnx-packs-test--with root
    (let ((r (drgnx-packs-sync :add '("beta"))))
      (should (equal (sort (copy-sequence (plist-get r :packs)) #'string<) '("alpha" "beta")))
      (should (equal (sort (mapcar #'symbol-name (mapcar #'car (drgnx-packs-locked-grammars))) #'string<) '("alpha" "beta"))))
    (should-error (drgnx-packs-sync :remove '("alpha")) :type 'drgnx-packs-error)
    (drgnx-packs-sync :remove '("beta"))
    (should (equal (mapcar #'car (drgnx-packs-locked)) '(alpha)))))

(ert-deftest drgnx-packs/removing-a-pack-drops-its-grammar-from-the-lock-and-the-folder ()
  (drgnx-packs-test--with root
    (drgnx-packs-sync :add '("alpha" "beta"))
    (let ((beta (drgnx-packs-grammar-dir 'beta (make-string 40 ?a))))
      (should (file-directory-p beta))
      (drgnx-packs-sync :remove '("beta"))
      (should-not (assq 'beta (drgnx-packs-locked-grammars)))
      (should (equal (drgnx-packs-test--active-names) '(alpha)))
      ;; the generation before still names it, so the folder stays until that generation goes
      (should (file-directory-p beta)))))

;;;; The generic mode's queries

(ert-deftest drgnx-packs/a-generic-pack-gets-its-queries-translated-before-the-lock-is-written ()
  (drgnx-packs-test--with root
    (drgnx-packs-test--pack drgnx-packs-dir "gen" :grammars (list (drgnx-packs-test--grammar "gen" t)) :mode '(:generic t))
    (let* ((calls nil)
           (drgnx-packs-translate-function (lambda (dir out) (push (list dir out) calls) (write-region "(:version 1)" nil out nil 'silent))))
      (drgnx-packs-sync :add '("alpha" "gen"))
      (should (= 1 (length calls)))                                       ; alpha is not generic
      (let ((entry (cdr (assq 'gen (plist-get (drgnx-packs-active) :packs)))))
        (should (equal (plist-get entry :translated) (cadr (car calls))))
        (should (file-exists-p (plist-get entry :translated))))
      (should-not (plist-get (cdr (assq 'alpha (plist-get (drgnx-packs-active) :packs))) :translated))
      ;; a refused predicate stops the sync before anything changes
      (let ((lock-before (with-temp-buffer (insert-file-contents (drgnx-pkg-lock-file)) (buffer-string)))
            (drgnx-packs-translate-function (lambda (_d _o) (drgnx-packs--error "queries/highlights.scm: #set! is not in the portable subset"))))
        (drgnx-packs-sync :remove '("gen"))
        (should-not (assq 'gen (drgnx-packs-locked)))
        (drgnx-packs-test--pack drgnx-packs-dir "gen2" :grammars (list (drgnx-packs-test--grammar "gen2" t)) :mode '(:generic t))
        (drgnx-packs-forget)
        (should-error (drgnx-packs-sync :add '("gen2")) :type 'drgnx-packs-error)
        (should-not (assq 'gen2 (drgnx-packs-locked)))
        (should (equal lock-before lock-before))))))

;;;; Packages a pack requires

(ert-deftest drgnx-packs/the-emacs-packages-a-pack-requires-are-installed-first-and-a-failure-changes-nothing ()
  (drgnx-packs-test--with root
    (drgnx-packs-test--pack drgnx-packs-dir "hs" :grammars (list (drgnx-packs-test--grammar "hs" t))
                            :mode '(:ts hs-ts-mode :package hs-ts-mode) :requires '(:packages (hs-ts-mode)))
    (drgnx-packs-forget)
    (let ((asked nil))
      (let ((drgnx-packs-install-packages-function (lambda (names) (push names asked) (drgnx-packs--error "no network"))))
        (should-error (drgnx-packs-sync :add '("hs")) :type 'drgnx-packs-error)
        (should (equal asked '((hs-ts-mode))))
        (should-not (drgnx-packs-locked)))
      (setq asked nil)
      (let ((drgnx-packs-install-packages-function (lambda (names) (push names asked))))
        (drgnx-packs-sync :add '("hs"))
        (should (equal asked '((hs-ts-mode))))
        (should (assq 'hs (drgnx-packs-locked))))
      ;; a package already in the lock is not asked for again
      (setq asked nil)
      (drgnx-pkg-write-lock (list (cons 'hs-ts-mode (list :version "1.0" :archive "x" :kind 'single :file "f" :sha256 "s" :size 1))))
      (let ((drgnx-packs-install-packages-function (lambda (names) (push names asked))))
        (drgnx-packs-sync :add '("alpha"))
        (should-not asked)))))

;;;; The build before packs

(ert-deftest drgnx-packs/migrate-installs-the-packs-the-hub-parses-with-once ()
  ;; the hub reads code through these packs' grammars, so install and update put them in (`drgnx packs migrate'); those
  ;; that are already in the lock, and names that are no built-in pack, are left alone
  (drgnx-packs-test--with root
    (let ((drgnx-packs-hub-defaults '("alpha" "beta" "nosuch")))
      (should (equal (sort (copy-sequence (drgnx-packs-migrate)) #'string<) '("alpha" "beta")))
      (should (eq (plist-get (cdr (assq 'beta (drgnx-packs-locked))) :wanted) 'default))
      (should (null (drgnx-packs-migrate))))))

(ert-deftest drgnx-packs/the-build-before-packs-becomes-packs-and-its-folder-goes ()
  (drgnx-packs-test--with root
    (let ((legacy (drgnx-packs--legacy-dir)))
      (make-directory legacy t)
      (write-region "x" nil (expand-file-name "libtree-sitter-alpha.so" legacy) nil 'silent)
      (should (equal (drgnx-packs-migrate) '("alpha")))
      (should (eq (plist-get (cdr (assq 'alpha (drgnx-packs-locked))) :wanted) 'default))
      (should (equal (drgnx-packs-test--active-names) '(alpha)))
      (should-not (file-exists-p legacy))
      (should (null (drgnx-packs-migrate))))))                            ; nothing left to do

(ert-deftest drgnx-packs/the-old-folder-stays-while-a-language-in-it-has-no-pack-build ()
  (drgnx-packs-test--with root
    (let ((legacy (drgnx-packs--legacy-dir)))
      (make-directory legacy t)
      (dolist (l '("alpha" "zzz")) (write-region "x" nil (expand-file-name (format "libtree-sitter-%s.so" l) legacy) nil 'silent))
      (drgnx-packs-migrate)
      (should (file-directory-p legacy)))))

(ert-deftest drgnx-packs/a-failed-build-keeps-the-old-folder-and-says-so ()
  (drgnx-packs-test--with root
    (let ((legacy (drgnx-packs--legacy-dir)) (drgnx-packs-job-function (lambda (_) (list :ok nil :error "no compiler"))))
      (make-directory legacy t)
      (write-region "x" nil (expand-file-name "libtree-sitter-alpha.so" legacy) nil 'silent)
      (should-error (drgnx-packs-migrate) :type 'drgnx-packs-error)
      (should (file-directory-p legacy))
      (should-not (drgnx-packs-locked)))))

;;;; Rollback

(ert-deftest drgnx-packs/rollback-restores-the-active-packs ()
  (drgnx-packs-test--with root
    (let ((first (plist-get (drgnx-packs-sync :add '("alpha")) :generation)))
      (drgnx-packs-sync :add '("beta"))
      (should (equal (sort (mapcar #'symbol-name (drgnx-packs-test--active-names)) #'string<) '("alpha" "beta")))
      (drgnx-pkg-rollback first)
      (should (equal (mapcar #'car (drgnx-packs-locked)) '(alpha)))
      (should (equal (drgnx-packs-test--active-names) '(alpha))))))

;;;; Sweep

(ert-deftest drgnx-packs/the-sweep-keeps-what-a-lock-a-generation-or-a-live-session-names ()
  (drgnx-packs-test--with root
    (drgnx-packs-sync :add '("alpha"))
    (let ((stray (drgnx-packs-grammar-dir 'zeta (make-string 40 ?d)))
          (claimed (drgnx-packs-grammar-dir 'eta (make-string 40 ?e)))
          (named (drgnx-packs-grammar-dir 'alpha (make-string 40 ?a))))
      (dolist (d (list stray claimed)) (make-directory d t))
      (drgnx-packs-claim (list (cons "eta" (make-string 40 ?e))))
      (should (equal (mapcar #'file-name-nondirectory (mapcar #'directory-file-name (drgnx-packs-sweep)))
                     (list (make-string 40 ?d))))
      (should-not (file-exists-p stray))
      (should (file-directory-p claimed))
      (should (file-directory-p named))
      (should-not (file-exists-p (file-name-directory (directory-file-name stray)))))))

;;;; The command line

(ert-deftest drgnx-packs/the-command-line-lists-and-syncs ()
  (drgnx-packs-test--with root
    (should (equal (with-output-to-string (should (= 0 (drgnx-packs-cli '("list")))))
                   "alpha        available  alpha\nbeta         available  beta\n"))
    (should (string-match-p "packs: alpha; built: alpha; generation [0-9]"
                            (with-output-to-string (should (= 0 (drgnx-packs-cli '("sync" "--add" "alpha")))))))
    (should (string-match-p "alpha        installed"
                            (with-output-to-string (drgnx-packs-cli '("list")))))
    (should-error (drgnx-packs-cli '("sync" "--bogus")) :type 'drgnx-packs-error)))

(provide 'packs-test)
;;; packs-test.el ends here

(ert-deftest drgnx-packs/an-installed-pack-with-its-own-mode-can-be-off-in-a-project ()
  ;; the Extensions modes index gets pack:NAME for an installed pack with a tree-sitter mode and file names; a pack of
  ;; the generic mode shares its one mode, so it gets none
  (drgnx-packs-test--with root
    (drgnx-packs-test--pack drgnx-packs-dir "gamma" :grammars (list (drgnx-packs-test--grammar "gamma" t))
                            :mode '(:ts gamma-ts-mode :classic gamma-mode) :files '(:extensions ("gm")))
    (drgnx-packs-test--pack drgnx-packs-dir "delta" :grammars (list (drgnx-packs-test--grammar "delta" t))
                            :mode '(:generic t) :files '(:extensions ("dl")))
    (drgnx-packs-forget)
    (should-not (drgnx-packs-project-index))
    (let ((drgnx-packs-translate-function (lambda (_dir out) (write-region "(:version 1)" nil out nil 'silent))))
      (drgnx-packs-sync :add '("gamma" "delta")))
    (should (equal (drgnx-packs-project-index)
                   (list (list 'pack:gamma :scope 'narrow :auto (list (cons "\\.\\(gm\\)\\'" 'gamma-ts-mode))
                               :remap-from '(gamma-mode)))))))
