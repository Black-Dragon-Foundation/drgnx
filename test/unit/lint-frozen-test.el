;;; lint-frozen-test.el --- lint: every frozen test is in the register, and the keep-on guards run -*- lexical-binding: t -*-
;; test-class: det
;; A test tagged `:frozen' is left out of every run (harness/run-ert.el) because the code a plan replaces is frozen.  The
;; register, test/frozen.eld, has one row per test file: ((FILE :by "PLAN-OR-DESIGN:LINE" :since DATE :tests (NAME…)
;; :keep (NAME…)) …).  The files are read with the Lisp reader, never loaded.
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-paths)

(defun drgnx-lint-frozen--forms (file)
  "The top-level forms of FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (with-syntax-table emacs-lisp-mode-syntax-table
      (let (forms)
        (goto-char (point-min))
        (condition-case nil
            (while (progn (forward-comment (buffer-size)) (not (eobp)))
              (push (read (current-buffer)) forms))
          (end-of-file nil))
        (nreverse forms)))))

(defun drgnx-lint-frozen--tests (file)
  "The `ert-deftest' forms of FILE as (NAME . FROZEN-P)."
  (let (tests)
    (dolist (form (drgnx-lint-frozen--forms file))
      (when (and (consp form) (eq (car form) 'ert-deftest))
        (let ((rest (cdddr form)) tags)
          (when (stringp (car rest)) (setq rest (cdr rest)))
          (while (keywordp (car rest))
            (when (eq (car rest) :tags) (setq tags (cadr rest)))
            (setq rest (cddr rest)))
          (when (eq (car-safe tags) 'quote) (setq tags (cadr tags)))
          (push (cons (cadr form) (and (memq :frozen tags) t)) tests))))
    (nreverse tests)))

(defun drgnx-lint-frozen--files (root)
  "Every test file under ROOT/test, relative to ROOT."
  (mapcar (lambda (f) (file-relative-name f root))
          (directory-files-recursively (expand-file-name "test" root) "-\\(test\\|isolated\\)\\.el\\'")))

(defun drgnx-lint-frozen--problems (root rows)
  "The problems of the register ROWS against the test files under ROOT: a `:frozen' test with no row, a row naming a file
or a test that is gone, a `:keep' test tagged `:frozen', and a row test that is not tagged."
  (let (problems)
    (dolist (rel (drgnx-lint-frozen--files root))
      (let* ((row (assoc rel rows))
             (listed (plist-get (cdr row) :tests)))
        (dolist (test (drgnx-lint-frozen--tests (expand-file-name rel root)))
          (when (and (cdr test) (not (memq (car test) listed)))
            (push (format "%s: %s is tagged :frozen and not in test/frozen.eld" rel (car test)) problems)))))
    (dolist (row rows)
      (let ((file (expand-file-name (car row) root)))
        (if (not (file-exists-p file))
            (push (format "%s: the file of a register row is gone" (car row)) problems)
          (let ((tests (drgnx-lint-frozen--tests file)))
            (dolist (name (append (plist-get (cdr row) :tests) (plist-get (cdr row) :keep)))
              (unless (assq name tests)
                (push (format "%s: %s of the register is no test of the file" (car row) name) problems)))
            (dolist (name (plist-get (cdr row) :keep))
              (when (cdr (assq name tests))
                (push (format "%s: %s is a keep-on test and tagged :frozen" (car row) name) problems)))
            (dolist (name (plist-get (cdr row) :tests))
              (when (and (assq name tests) (not (cdr (assq name tests))))
                (push (format "%s: %s is in the register and not tagged :frozen" (car row) name) problems)))))))
    (nreverse problems)))

(defun drgnx-lint-frozen--register ()
  (with-temp-buffer
    (insert-file-contents (expand-file-name "test/frozen.eld" drgnx-dir))
    (read (current-buffer))))

(defmacro drgnx-lint-frozen--with-tree (files &rest body)
  "BODY with `root' a temp checkout holding FILES, an alist of (RELATIVE-NAME . TEXT)."
  (declare (indent 1))
  `(let ((root (file-name-as-directory (make-temp-file "frozen-lint" t))))
     (unwind-protect
         (progn (dolist (f ,files)
                  (make-directory (file-name-directory (expand-file-name (car f) root)) t)
                  (write-region (cdr f) nil (expand-file-name (car f) root) nil 'silent))
                ,@body)
       (delete-directory root t))))

(ert-deftest drgnx-lint/frozen-tests-are-registered ()
  (let ((rows (drgnx-lint-frozen--register)))
    (should (consp rows))
    (should-not (drgnx-lint-frozen--problems drgnx-dir rows))))

(ert-deftest drgnx-lint/frozen-register-rows-are-complete ()
  (dolist (row (drgnx-lint-frozen--register))
    (should (stringp (car row)))
    (should (string-match-p "[^ ]:[0-9]" (plist-get (cdr row) :by)))
    (should (stringp (plist-get (cdr row) :since)))
    (should (plist-get (cdr row) :tests))))

(ert-deftest drgnx-lint/frozen-lint-finds-each-kind-of-problem ()
  (drgnx-lint-frozen--with-tree
      '(("test/unit/a-test.el" . "(ert-deftest a/one () :tags '(:frozen) (should t))
(ert-deftest a/two () \"doc\" :tags '(:cond :frozen) (should t))
(ert-deftest a/guard () :tags '(:frozen) (should t))
(ert-deftest a/plain () (should t))
(ert-deftest a/untagged () (should t))"))
    (let ((problems (drgnx-lint-frozen--problems
                     root '(("test/unit/a-test.el" :tests (a/one a/gone a/untagged) :keep (a/guard a/missing))
                            ("test/unit/gone-test.el" :tests (b/x))))))
      (should (seq-some (lambda (p) (string-match-p "a/two is tagged :frozen and not" p)) problems))
      (should (seq-some (lambda (p) (string-match-p "a/gone of the register" p)) problems))
      (should (seq-some (lambda (p) (string-match-p "a/missing of the register" p)) problems))
      (should (seq-some (lambda (p) (string-match-p "a/guard is a keep-on test" p)) problems))
      (should (seq-some (lambda (p) (string-match-p "a/untagged is in the register and not tagged" p)) problems))
      (should (seq-some (lambda (p) (string-match-p "gone-test.el: the file" p)) problems))
      (should-not (seq-some (lambda (p) (string-match-p "a/one\\|a/plain" p)) problems)))
    (should-not (drgnx-lint-frozen--problems
                 root '(("test/unit/a-test.el" :tests (a/one a/two a/guard)))))))

;;; lint-frozen-test.el ends here
