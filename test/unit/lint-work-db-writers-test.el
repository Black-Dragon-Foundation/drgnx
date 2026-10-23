;;; lint-work-db-writers-test.el --- lint: the one-writer gate's exemption stays with Rust-bound code -*- lexical-binding: t -*-
;; In gate mode (DRGNX_WORK_DB_GATE=1, test/support/work-db-gate.el) opening work.db read-write signals, and the
;; tests tagged `:work-db-writer' are left out.  The tag is for tests of the `local' writer mode of Lisp that a plan
;; replaces with Rust: it may be used only in the test files listed here, and the test's body must bind
;; `drgnx-coord-writer' to `local' (`drgnx-work-db-writer-deftest' does).  So the tag cannot hide an editor writer or
;; a backend reader: those run in gate mode.  Phase 7 deletes the tagged tests and this list.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)

(defconst drgnx-lint-work-db--files
  '("coord-test.el" "coord-events-test.el" "coord-delivery-test.el" "coord-mcp-test.el" "hub-events-test.el"
    "work-db-read-test.el" "work-db-migrate-test.el" "job-budget-test.el" "job-cards-test.el" "job-clash-review-test.el"
    "job-clash-test.el" "job-cockpit-test.el" "job-exit-test.el" "job-gate-test.el" "job-liveness-test.el"
    "job-mcp-policy-test.el" "job-policy-test.el" "job-propose-test.el" "job-review-test.el" "job-run-test.el"
    "job-safe-test.el")
  "The test files (test/unit/) of the Rust-bound Lisp whose tests may carry `:work-db-writer'.")

(defun drgnx-lint-work-db--forms (file)
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

(defun drgnx-lint-work-db--mentions-p (tree thing)
  "Whether the symbol THING occurs in TREE."
  (cond ((eq tree thing) t)
        ((consp tree) (or (drgnx-lint-work-db--mentions-p (car tree) thing) (drgnx-lint-work-db--mentions-p (cdr tree) thing)))))

(defun drgnx-lint-work-db--binds-local-p (tree)
  "Whether TREE holds a binding `(drgnx-coord-writer (quote local))' (a `let' of `local')."
  (cond ((not (consp tree)) nil)
        ((and (eq (car tree) 'drgnx-coord-writer) (equal (cadr tree) '(quote local))) t)
        (t (or (drgnx-lint-work-db--binds-local-p (car tree)) (drgnx-lint-work-db--binds-local-p (cdr tree))))))

(defun drgnx-lint-work-db--tags-name-p (rest)
  "Whether REST, the part of an `ert-deftest' after its argument list, has a leading `:tags' that names the tag."
  (when (stringp (car rest)) (setq rest (cdr rest)))
  (while (and (keywordp (car rest)) (not (and (eq (car rest) :tags) (drgnx-lint-work-db--mentions-p (cadr rest) :work-db-writer))))
    (setq rest (cddr rest)))
  (keywordp (car rest)))

(defun drgnx-lint-work-db--tagged-p (form)
  "Non-nil when FORM defines a test with the tag: a `drgnx-work-db-writer-deftest', or an `ert-deftest' whose `:tags'
names `:work-db-writer'.  The value is `macro' or `tag'."
  (cond ((not (consp form)) nil)
        ((eq (car form) 'drgnx-work-db-writer-deftest) 'macro)
        ((and (eq (car form) 'ert-deftest) (drgnx-lint-work-db--tags-name-p (cdddr form))) 'tag)))

(defun drgnx-lint-work-db--problems (forms file)
  "The problems of the test FILE (a base name) whose top-level FORMS are given: each tagged test outside the list,
and each one that does not bind `drgnx-coord-writer' to `local'."
  (let (problems)
    (dolist (form forms)
      (when-let* ((how (drgnx-lint-work-db--tagged-p form)))
        (unless (member file drgnx-lint-work-db--files)
          (push (format "%s: %s carries :work-db-writer, but %s is not a Rust-bound test file" file (cadr form) file) problems))
        (when (and (eq how 'tag) (not (drgnx-lint-work-db--binds-local-p (cdddr form))))
          (push (format "%s: %s carries :work-db-writer but does not bind drgnx-coord-writer to local" file (cadr form)) problems))))
    (nreverse problems)))

(ert-deftest drgnx-lint/work-db-writer-tags-only-in-local-mode ()
  (let ((dir (expand-file-name "test/unit/" drgnx-dir)) problems)
    (dolist (name drgnx-lint-work-db--files)
      (should (file-exists-p (expand-file-name name dir))))
    (dolist (file (directory-files dir t "-test\\.el\\'"))
      (setq problems (append problems (drgnx-lint-work-db--problems (drgnx-lint-work-db--forms file)
                                                                    (file-name-nondirectory file)))))
    (should-not problems)))

(ert-deftest drgnx-lint/work-db-writer-tag-without-local-fails-the-lint ()
  ;; a tagged test that does not bind `local' fails; one that does, and the macro (which does), pass
  (let ((listed (car drgnx-lint-work-db--files)))
    (should (drgnx-lint-work-db--problems
             '((ert-deftest a/reads () :tags '(:work-db-writer) (should (drgnx-work-node "x")))) listed))
    (should-not (drgnx-lint-work-db--problems
                 '((ert-deftest a/writes () :tags '(:work-db-writer) (let ((drgnx-coord-writer 'local)) (should t)))) listed))
    (should-not (drgnx-lint-work-db--problems '((drgnx-work-db-writer-deftest a/macro () (should t))) listed))
    (should-not (drgnx-lint-work-db--problems '((ert-deftest a/untagged () (should t))) "cockpit-model-test.el"))))

(ert-deftest drgnx-lint/work-db-writer-tag-outside-the-listed-files-fails-the-lint ()
  ;; the tag cannot hide an editor writer or a backend reader: their test files are not on the list
  (should (drgnx-lint-work-db--problems '((drgnx-work-db-writer-deftest a/macro () (should t))) "cockpit-model-test.el"))
  (should (drgnx-lint-work-db--problems
           '((ert-deftest a/writes () :tags '(:work-db-writer) (let ((drgnx-coord-writer 'local)) (should t))))
           "work-ui-test.el")))
