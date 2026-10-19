;;; lint-files-test.el --- lint: drgnx's files are read and written through drgnx-file -*- lexical-binding: t -*-
;; Every file drgnx keeps (a config file, a state file, a report) is read and written through
;; `drgnx-file' (core/drgnx-file.el): it locks, backs up, refuses a file it could not read and keeps
;; the user's bytes.  This lint reads every .el under core/, wb/ and modules/ form by form and flags a
;; top-level form that
;;   - calls `with-temp-file', `write-region' or `rename-file', or
;;   - calls `insert-file-contents' (or `-literally') and also `read' (a hand-made reader).
;; A flagged site is (FILE FN WHAT).  FN is the `defun' / `cl-defun' / `defmacro' name, or `toplevel-N'
;; (the Nth form of the file that is none of those).  WHAT is the function called, or `read-site' for the
;; read pattern.  `test/lint-files-allowed.eld' lists today's sites, each with the task of the
;; config-layer plan that ports it (`:until' N) or `never' (with `:why' naming its category); a port
;; removes its lines, and the second test fails on a line that matches nothing.
(require 'ert)
(require 'seq)
(require 'cl-lib)
(require 'drgnx-paths)

(defconst drgnx-lint-files--writers '(with-temp-file write-region rename-file)
  "Calls that write or move a file by hand.")

(defconst drgnx-lint-files--readers '(insert-file-contents insert-file-contents-literally)
  "Calls that read a file into a buffer; with `read' they make a hand-made reader.")

(defun drgnx-lint-files--forms (file)
  "The top-level forms of FILE, in order."
  (with-temp-buffer
    (insert-file-contents file)
    (let (forms)
      (condition-case nil (while t (push (read (current-buffer)) forms)) (end-of-file nil))
      (nreverse forms))))

(defun drgnx-lint-files--calls (form)
  "The symbols that head a list anywhere in FORM, or follow `function' (#'f), without duplicates."
  (let (out)
    (cl-labels ((walk (x)
                  (when (consp x)
                    (when (symbolp (car x)) (cl-pushnew (car x) out))
                    (when (and (eq (car x) 'function) (symbolp (car-safe (cdr x))))
                      (cl-pushnew (cadr x) out))
                    (while (consp x) (walk (car x)) (setq x (cdr x))))))
      (walk form))
    out))

(defun drgnx-lint-files--sites (file)
  "Flagged sites of FILE (relative name): a list of (FILE FN WHAT)."
  (let ((rel (file-relative-name file drgnx-dir)) (n 0) out)
    (dolist (form (drgnx-lint-files--forms file))
      (let* ((named (and (memq (car-safe form) '(defun cl-defun defmacro)) (symbolp (cadr form))))
             (fn (if named (cadr form) (intern (format "toplevel-%d" (cl-incf n)))))
             (calls (drgnx-lint-files--calls form)))
        (dolist (w drgnx-lint-files--writers)
          (when (memq w calls) (push (list rel fn w) out)))
        (when (and (seq-some (lambda (r) (memq r calls)) drgnx-lint-files--readers) (memq 'read calls))
          (push (list rel fn 'read-site) out))))
    (nreverse out)))

(defun drgnx-lint-files--all-sites ()
  "Every flagged site under core/, wb/ and modules/, except core/drgnx-file.el."
  (seq-mapcat
   (lambda (f) (and (not (string= (file-relative-name f drgnx-dir) "core/drgnx-file.el"))
                    (drgnx-lint-files--sites f)))
   (seq-mapcat (lambda (d) (directory-files-recursively (expand-file-name d drgnx-dir) "\\.el\\'"))
               '("core" "wb" "modules"))))

(defun drgnx-lint-files--allowed ()
  "The allowlist: a list of plists (:file :fn :what :why :until)."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "test/lint-files-allowed.eld" drgnx-dir))
    (goto-char (point-min))
    (read (current-buffer))))

(defun drgnx-lint-files--entry-matches (entry site)
  (and (equal (plist-get entry :file) (nth 0 site))
       (eq (plist-get entry :fn) (nth 1 site))
       (eq (plist-get entry :what) (nth 2 site))))

(defun drgnx-lint-files--unlisted (sites allowed)
  "The members of SITES that no entry of ALLOWED names."
  (seq-remove (lambda (s) (seq-some (lambda (e) (drgnx-lint-files--entry-matches e s)) allowed)) sites))

(defun drgnx-lint-files--stale (sites allowed)
  "The entries of ALLOWED that match no member of SITES."
  (seq-remove (lambda (e) (seq-some (lambda (s) (drgnx-lint-files--entry-matches e s)) sites)) allowed))

(defun drgnx-lint-files--with-file (text fn)
  "Call FN with the name of a temp .el file holding TEXT."
  (let ((f (make-temp-file "drgnx-lint" nil ".el")))
    (unwind-protect (progn (with-temp-file f (insert text)) (funcall fn f))
      (delete-file f))))

(ert-deftest drgnx-lint/files-go-through-drgnx-file ()
  (let ((bad (drgnx-lint-files--unlisted (drgnx-lint-files--all-sites) (drgnx-lint-files--allowed))))
    (should (equal (mapcar (lambda (s) (format "%s %s %s (read and write through drgnx-file, or add a row to test/lint-files-allowed.eld)"
                                               (nth 0 s) (nth 1 s) (nth 2 s)))
                           bad)
                   nil))))

(ert-deftest drgnx-lint/no-stale-file-allowlist-entries ()
  (let ((stale (drgnx-lint-files--stale (drgnx-lint-files--all-sites) (drgnx-lint-files--allowed))))
    (should (equal (mapcar (lambda (e) (format "%S (a port removes its lines; delete this one)" e)) stale)
                   nil))))

(ert-deftest drgnx-lint/every-allowlist-entry-names-its-task ()
  (dolist (e (drgnx-lint-files--allowed))
    (let ((until (plist-get e :until)))
      (should (or (eq until 'never) (and (integerp until) (<= 6 until 27))))
      (should (stringp (plist-get e :why)))
      (when (eq until 'never)
        (should (string-match-p
                 "\\`\\(a user's file\\|a temporary file\\|a directory move\\|its own lock protocol\\|age writes it\\|a developer tool\\|Lisp source\\)"
                 (plist-get e :why)))))))

(ert-deftest drgnx-lint/the-file-check-sees-each-pattern ()
  (drgnx-lint-files--with-file
   (concat "(defun a () (with-temp-file \"x\" (insert 1)))\n"
           "(cl-defun b () (write-region 1 2 \"x\"))\n"
           "(defmacro c () '(rename-file 1 2))\n"
           "(defun d () (insert-file-contents \"x\") (read (current-buffer)))\n"
           "(defun e () (insert-file-contents-literally \"x\"))\n"
           "(defun f () (read \"1\"))\n"
           "(add-hook 'h (lambda () (mapc #'rename-file nil)))\n"
           "(defvar v (with-temp-file \"y\"))\n")
   (lambda (f)
     (let ((drgnx-dir (file-name-directory f)))
       (should (equal (mapcar #'cdr (drgnx-lint-files--sites f))
                      '((a with-temp-file) (b write-region) (c rename-file) (d read-site)
                        (toplevel-1 rename-file) (toplevel-2 with-temp-file))))))))

(ert-deftest drgnx-lint/the-allowlist-matches-by-file-fn-and-what ()
  (let* ((sites '(("core/a.el" f with-temp-file) ("core/a.el" g read-site)))
         (entry '(:file "core/a.el" :fn f :what with-temp-file :why "x" :until 6)))
    (should (equal (drgnx-lint-files--unlisted sites (list entry)) '(("core/a.el" g read-site))))
    (should (equal (drgnx-lint-files--stale sites (list entry '(:file "core/a.el" :fn zz :what write-region)))
                   '((:file "core/a.el" :fn zz :what write-region))))
    (should-not (drgnx-lint-files--stale sites (list entry)))))

(provide 'lint-files-test)
;;; lint-files-test.el ends here
