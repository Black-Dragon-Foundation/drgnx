;;; affected-test.el --- batch tests: bin/drgnx test --affected picks groups from a diff and caches green runs -*- lexical-binding: t -*-
;; test-class: det
;; Fixed fake diffs over a small fake tree and a fake workspace go through the real map (test/affected.eld) and must name
;; the expected groups; the cache's hit, miss and red-is-never-cached cases run with an injected runner, so no group
;; really runs.  Pattern D (pure: values in, values out).
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-affected)

(defconst drgnx-affected-test--crates
  '(("a" "runtime/crates/a" ())
    ("b" "runtime/crates/b" ("a"))
    ("drgnx-ratatoskr" "runtime/crates/drgnx-ratatoskr" ("b"))
    ("c" "runtime/crates/c" ()))
  "A fake workspace: b depends on a, the hub on b, c on nothing.")

(defun drgnx-affected-test--write (root file text)
  (let ((path (expand-file-name file root)))
    (make-directory (file-name-directory path) t)
    (write-region text nil path nil 'silent)))

(defmacro drgnx-affected-test--with-tree (var &rest body)
  "Run BODY with VAR a temporary tree: core/drgnx-foo.el (a test requires it), core/drgnx-bar.el (none does)."
  (declare (indent 1))
  `(let ((,var (make-temp-file "drgnx-affected" t)))
     (unwind-protect
         (progn
           (drgnx-affected-test--write ,var "core/drgnx-foo.el" "(provide 'drgnx-foo)\n")
           (drgnx-affected-test--write ,var "core/drgnx-bar.el" "(provide 'drgnx-bar)\n")
           (drgnx-affected-test--write ,var "test/unit/foo-test.el" "(require 'drgnx-foo)\n")
           (drgnx-affected-test--write ,var "test/unit/other-test.el" "(require 'ert)\n")
           ,@body)
       (delete-directory ,var t))))

(defun drgnx-affected-test--plan (root files &optional crates)
  (drgnx-affected-plan root files :map (drgnx-affected-map drgnx-dir) :crates (or crates drgnx-affected-test--crates)))

(defun drgnx-affected-test--ids (root files &optional crates)
  (mapcar (lambda (g) (plist-get g :id)) (plist-get (drgnx-affected-test--plan root files crates) :groups)))

(ert-deftest drgnx-affected/a-doc-only-diff-runs-the-docs-checks-only ()
  (drgnx-affected-test--with-tree root
    (should (equal (sort (drgnx-affected-test--ids root '("docs/guide/modules.md" "README.md")) #'string<)
                   '("docs:test/unit/config-doc-test.el" "docs:test/unit/settings-doc-test.el")))))

(ert-deftest drgnx-affected/a-note-nothing-reads-runs-nothing ()
  (drgnx-affected-test--with-tree root
    (should-not (drgnx-affected-test--ids root '("SECURITY.md" "LICENSES/GPL-3.0.txt")))))

(ert-deftest drgnx-affected/a-lisp-file-maps-to-the-tests-that-name-it ()
  (drgnx-affected-test--with-tree root
    (let ((ids (drgnx-affected-test--ids root '("core/drgnx-foo.el"))))
      (should (member "lisp:test/unit/foo-test.el" ids))
      (should-not (member "lisp:test/unit/other-test.el" ids))
      (should-not (member "unit" ids))
      (should (member "rules" ids))
      ;; the Rust tests read core/
      (should (member "rust:drgnx-ratatoskr" ids))
      (should-not (member "ui" ids)))))

(ert-deftest drgnx-affected/a-lisp-file-no-test-names-runs-the-whole-unit-suite-and-says-why ()
  (drgnx-affected-test--with-tree root
    (let* ((plan (drgnx-affected-test--plan root '("core/drgnx-bar.el")))
           (ids (mapcar (lambda (g) (plist-get g :id)) (plist-get plan :groups))))
      (should (member "unit" ids))
      (should-not (seq-some (lambda (id) (string-prefix-p "lisp:" id)) ids))
      (should (seq-some (lambda (w) (string-match-p "drgnx-bar.*no unit test names" w)) (plist-get plan :why))))))

(ert-deftest drgnx-affected/a-ui-path-adds-the-gui-and-scenario-tiers ()
  (drgnx-affected-test--with-tree root
    (let ((ids (drgnx-affected-test--ids root '("wb/drgnx-wb.el"))))
      (should (member "ui" ids))
      (should (member "scenario" ids)))
    (should-not (member "ui" (drgnx-affected-test--ids root '("core/drgnx-foo.el"))))))

(ert-deftest drgnx-affected/a-crate-runs-with-its-dependents-from-the-workspace ()
  (drgnx-affected-test--with-tree root
    (let ((ids (drgnx-affected-test--ids root '("runtime/crates/a/src/lib.rs"))))
      (should (equal (seq-filter (lambda (id) (string-prefix-p "rust:" id)) (sort (copy-sequence ids) #'string<))
                     '("rust:a" "rust:b" "rust:drgnx-ratatoskr")))
      ;; the hub is among them: the conformance rows too
      (should (member "domr" ids))
      (should (member "rust-rules" ids)))
    (let ((ids (drgnx-affected-test--ids root '("runtime/crates/c/src/lib.rs"))))
      (should (member "rust:c" ids))
      (should-not (member "rust:a" ids))
      (should-not (member "domr" ids)))))

(ert-deftest drgnx-affected/no-workspace-metadata-runs-the-whole-workspace-and-says-why ()
  (drgnx-affected-test--with-tree root
    (let* ((plan (drgnx-affected-plan root '("runtime/crates/a/src/lib.rs") :map (drgnx-affected-map drgnx-dir)
                                      :crates (lambda () :unavailable)))
           (ids (mapcar (lambda (g) (plist-get g :id)) (plist-get plan :groups))))
      (should (member "rust-workspace" ids))
      (should-not (member "rust:a" ids))
      (should (seq-some (lambda (w) (string-match-p "cargo metadata" w)) (plist-get plan :why))))))

(ert-deftest drgnx-affected/a-conformance-row-maps-to-its-group ()
  (drgnx-affected-test--with-tree root
    (let ((ids (drgnx-affected-test--ids root '("test/conformance/hub/x.jsonl"))))
      (should (member "domr:hub" ids))
      (should-not (member "domr" ids))
      (should-not (member "rust:c" ids)))))

(ert-deftest drgnx-affected/an-unknown-path-runs-everything-and-says-why ()
  (drgnx-affected-test--with-tree root
    (let* ((plan (drgnx-affected-test--plan root '("some/new/place.txt")))
           (ids (mapcar (lambda (g) (plist-get g :id)) (plist-get plan :groups))))
      (should (equal ids '("unit" "rust-workspace" "domr" "ui" "scenario" "tty")))
      (should (seq-some (lambda (w) (string-match-p "some/new/place.txt.*no row.*everything" w)) (plist-get plan :why))))))

(ert-deftest drgnx-affected/everything-subsumes-the-narrower-groups ()
  (drgnx-affected-test--with-tree root
    (let ((ids (drgnx-affected-test--ids root '("some/new/place.txt" "core/drgnx-foo.el" "runtime/crates/a/src/lib.rs"))))
      (should-not (seq-some (lambda (id) (or (string-prefix-p "lisp:" id) (string-prefix-p "rust:" id))) ids))
      (should (equal (length ids) (length (delete-dups (copy-sequence ids))))))))

(ert-deftest drgnx-affected/the-map-reads-and-every-row-names-known-actions ()
  (let ((map (drgnx-affected-map drgnx-dir)))
    (should (plist-get map :rules))
    (dolist (row (plist-get map :rules))
      (dolist (a (cdr row))
        (should (memq (if (consp a) (car a) a)
                      '(everything none unit names self rules docs rust rust-path rust-workspace rust-rules
                                   domr domr-path ui scenario tty perf)))))))

;;;; The cache

(defun drgnx-affected-test--group (root)
  "A lisp group over ROOT's foo test."
  (car (plist-get (drgnx-affected-test--plan root '("core/drgnx-foo.el")) :groups)))

(defmacro drgnx-affected-test--with-cache (vars &rest body)
  "Bind (ROOT CACHE CALLS RUNNER) in VARS: a tree, an empty cache directory, a counter, a runner that returns (car RESULTS)."
  (declare (indent 1))
  `(drgnx-affected-test--with-tree ,(nth 0 vars)
     (let* ((,(nth 1 vars) (make-temp-file "drgnx-affected-cache" t))
            (,(nth 2 vars) 0)
            (results (list 0)))
       (ignore results)
       (cl-flet ((,(nth 3 vars) (g) (ignore g) (cl-incf ,(nth 2 vars)) (car results)))
         (unwind-protect (progn ,@body) (delete-directory ,(nth 1 vars) t))))))

(defun drgnx-affected-test--run (root cache runner &rest args)
  (let ((standard-output (generate-new-buffer " out")))
    (unwind-protect
        (apply #'drgnx-affected-run root (list (drgnx-affected-test--group root))
               :cache-dir cache :runner runner :stamp "emacs-31.1 rustc-1.95" args)
      (kill-buffer standard-output))))

(ert-deftest drgnx-affected/a-green-run-is-skipped-the-next-time-while-its-inputs-are-unchanged ()
  (drgnx-affected-test--with-cache (root cache calls runner)
    (should (equal (mapcar #'cdr (drgnx-affected-test--run root cache #'runner)) '(green)))
    (should (equal (mapcar #'cdr (drgnx-affected-test--run root cache #'runner)) '(cached)))
    (should (= calls 1))))

(ert-deftest drgnx-affected/a-red-run-is-never-cached-as-a-pass ()
  (drgnx-affected-test--with-cache (root cache calls runner)
    (let ((red (lambda (_g) (cl-incf calls) 1)))
      (should (equal (mapcar #'cdr (drgnx-affected-test--run root cache red)) '(red)))
      (should (equal (mapcar #'cdr (drgnx-affected-test--run root cache red)) '(red)))
      (should (= calls 2))
      ;; …and a green run after the reds is the first that is cached
      (should (equal (mapcar #'cdr (drgnx-affected-test--run root cache #'runner)) '(green)))
      (should (equal (mapcar #'cdr (drgnx-affected-test--run root cache #'runner)) '(cached))))))

(ert-deftest drgnx-affected/a-changed-input-misses ()
  (drgnx-affected-test--with-cache (root cache calls runner)
    (drgnx-affected-test--run root cache #'runner)
    (drgnx-affected-test--write root "core/drgnx-bar.el" "(provide 'drgnx-bar) ; changed\n")
    (should (equal (mapcar #'cdr (drgnx-affected-test--run root cache #'runner)) '(green)))
    (should (= calls 2))))

(ert-deftest drgnx-affected/a-changed-build-or-toolchain-misses ()
  (drgnx-affected-test--with-cache (root cache calls runner)
    (drgnx-affected-test--run root cache #'runner)
    (let ((standard-output (generate-new-buffer " out")))
      (unwind-protect
          (should (equal (mapcar #'cdr (drgnx-affected-run root (list (drgnx-affected-test--group root))
                                                           :cache-dir cache :runner #'runner :stamp "emacs-31.2 rustc-1.95"))
                         '(green)))
        (kill-buffer standard-output)))
    (should (= calls 2))))

(ert-deftest drgnx-affected/no-cache-forces-a-run-and-says-what-was-skipped ()
  (drgnx-affected-test--with-cache (root cache calls runner)
    (drgnx-affected-test--run root cache #'runner)
    (should (equal (mapcar #'cdr (drgnx-affected-test--run root cache #'runner :no-cache t)) '(green)))
    (should (= calls 2))
    (let ((out (generate-new-buffer " out")))
      (unwind-protect
          (let ((standard-output out))
            (drgnx-affected-run root (list (drgnx-affected-test--group root))
                                :cache-dir cache :runner #'runner :stamp "emacs-31.1 rustc-1.95")
            (should (string-match-p "skipped.*inputs unchanged since its last green run"
                                    (with-current-buffer out (buffer-string)))))
        (kill-buffer out)))))

(ert-deftest drgnx-affected/the-cache-never-lives-in-the-checkout ()
  (let ((process-environment (list "XDG_CACHE_HOME=/xdg" "HOME=/h")))
    (should (equal (drgnx-affected-cache-dir) "/xdg/drgnx/affected/")))
  (let ((process-environment (list "DRGNX_AFFECTED_CACHE=/elsewhere" "HOME=/h")))
    (should (equal (drgnx-affected-cache-dir) "/elsewhere/")))
  (let ((process-environment (list "HOME=/h")))
    (should (equal (drgnx-affected-cache-dir) "/h/.cache/drgnx/affected/"))))

(provide 'affected-test)
;;; affected-test.el ends here
