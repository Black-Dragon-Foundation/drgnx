;;; lint-with-modules-test.el --- lint: nothing a module defines is stubbed or bound around drgnx-test-with-modules -*- lexical-binding: t -*-
;; test-class: det
;; `drgnx-test-with-modules' loads the module files itself (`drgnx-test-modules--load'), after the test made its
;; bindings: a `cl-letf' of a function a module file defines is undone by that load (the `defun' runs again), and a
;; `let' of a variable it defines is shadowed or reset by its `defvar' / `defcustom'.  The stub or the value belongs
;; INSIDE the body, where the modules are set up; or the test requires the module's library first.  This lint reads
;; every test file (never loads it) and names each `drgnx-test-with-modules' form that sits inside such a binding.
(require 'ert)
(require 'seq)
(require 'cl-lib)
(require 'drgnx-paths)

(defconst drgnx-lint-with-modules--definers
  '(defun cl-defun defsubst cl-defsubst defmacro cl-defmacro defvar defcustom defconst defvar-local cl-defgeneric cl-defmethod)
  "The forms of a module file that define the name after them.")

(defun drgnx-lint-with-modules--forms (file)
  "The top-level forms of FILE, read; `error' for a file that does not read (a lint that skips it proves nothing)."
  (with-temp-buffer
    (insert-file-contents file)
    (let (forms)
      (condition-case nil (while t (push (read (current-buffer)) forms)) (end-of-file nil))
      (nreverse forms))))

(defun drgnx-lint-with-modules--defined ()
  "The names the files under modules/ define at their top level, in a hash table."
  (let ((names (make-hash-table :test #'eq)))
    (dolist (file (directory-files-recursively (expand-file-name "modules" drgnx-dir) "\\.el\\'"))
      (dolist (form (drgnx-lint-with-modules--forms file))
        (when (and (consp form) (memq (car form) drgnx-lint-with-modules--definers) (symbolp (cadr form)))
          (puthash (cadr form) t names))))
    names))

(defun drgnx-lint-with-modules--bound (binding)
  "The name a let or `cl-letf' BINDING binds: a variable, or the function of `(symbol-function 'NAME)'."
  (let ((place (if (consp binding) (car binding) binding)))
    (cond ((symbolp place) place)
          ((and (eq (car-safe place) 'symbol-function) (eq (car-safe (cadr place)) 'quote)) (cadr (cadr place))))))

(defun drgnx-lint-with-modules--hits (form defined &optional bound)
  "The names in the DEFINED table that FORM binds around a `drgnx-test-with-modules' form inside it.  BOUND: what the
forms around FORM bind (a list of names)."
  (cond
   ((not (consp form)) nil)
   ((eq (car form) 'drgnx-test-with-modules)
    (seq-filter (lambda (n) (gethash n defined)) (seq-uniq bound)))
   ((and (memq (car form) '(let let* cl-letf cl-letf* letf)) (listp (cadr form)))
    (let ((inner (append (delq nil (mapcar #'drgnx-lint-with-modules--bound (cadr form))) bound)))
      (seq-mapcat (lambda (sub) (drgnx-lint-with-modules--hits sub defined inner)) (cddr form))))
   (t (let ((out nil) (x form))
        (while (consp x)
          (setq out (append out (drgnx-lint-with-modules--hits (car x) defined bound)))
          (setq x (cdr x)))
        out))))

(defun drgnx-lint-with-modules--sites (files defined)
  "Strings \"FILE: NAME\" for every name in DEFINED that a form of FILES binds around `drgnx-test-with-modules'."
  (let (bad)
    (dolist (file files)
      (dolist (top (drgnx-lint-with-modules--forms file))
        (dolist (name (drgnx-lint-with-modules--hits top defined))
          (push (format "%s: %s" (file-relative-name file drgnx-dir) name) bad))))
    (nreverse (seq-uniq bad))))

(defun drgnx-lint-with-modules--pending ()
  "The sites test/lint-with-modules-pending.eld lists: not swept yet."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "test/lint-with-modules-pending.eld" drgnx-dir))
    (read (current-buffer))))

(defun drgnx-lint-with-modules--all-sites ()
  (drgnx-lint-with-modules--sites
   (directory-files-recursively (expand-file-name "test" drgnx-dir) "-test\\.el\\'")
   (drgnx-lint-with-modules--defined)))

(ert-deftest drgnx-lint/nothing-a-module-defines-is-bound-around-with-modules ()
  (should (equal (mapconcat #'identity (seq-difference (drgnx-lint-with-modules--all-sites)
                                                       (drgnx-lint-with-modules--pending))
                            "\n")
                 "")))

(ert-deftest drgnx-lint/no-stale-with-modules-pending-rows ()
  (should (equal (mapconcat #'identity (seq-difference (drgnx-lint-with-modules--pending)
                                                       (drgnx-lint-with-modules--all-sites))
                            "\n")
                 "")))

(ert-deftest drgnx-lint/the-with-modules-lint-bites ()
  (let ((defined (make-hash-table :test #'eq)) (file (make-temp-file "drgnx-lint-wm" nil ".el")))
    (puthash 'mod-fn t defined) (puthash 'mod-var t defined)
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "(ert-deftest a () (cl-letf (((symbol-function 'mod-fn) #'ignore)) (drgnx-test-with-modules '(m) (mod-fn))))\n"
                    "(ert-deftest b () (let ((mod-var 1) (other 2)) (drgnx-test-with-modules '(m) mod-var)))\n"
                    ;; inside the body, or not a module's, or not around: fine
                    "(ert-deftest c () (drgnx-test-with-modules '(m) (cl-letf (((symbol-function 'mod-fn) #'ignore)) (mod-fn))))\n"
                    "(ert-deftest d () (let ((other 2)) (drgnx-test-with-modules '(m) other)))\n"
                    "(ert-deftest e () (let ((mod-var 1)) mod-var) (drgnx-test-with-modules '(m) nil))\n"))
          (should (equal (drgnx-lint-with-modules--sites (list file) defined)
                         (list (format "%s: mod-fn" (file-relative-name file drgnx-dir))
                               (format "%s: mod-var" (file-relative-name file drgnx-dir))))))
      (delete-file file))))

(provide 'lint-with-modules-test)
;;; lint-with-modules-test.el ends here
