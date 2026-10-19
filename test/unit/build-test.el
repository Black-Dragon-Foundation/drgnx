;;; build-test.el --- batch tests: drgnx builds its own Lisp cleanly -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-build)
(require 'drgnx-paths)

(ert-deftest drgnx-build/compiles-everything-without-warnings ()
  ;; Byte-compiled (then natively compiled when loaded) drgnx is several times faster and makes
  ;; far less garbage than interpreted drgnx.  The build runs on a copy: the checkout is untouched.
  (let ((root (make-temp-file "drgnx-build" t)))
    (unwind-protect
        (progn
          (dolist (d '("core" "wb" "modules"))
            (copy-directory (expand-file-name d drgnx-dir) (expand-file-name d root)))
          (let ((r (drgnx-build-test--build root)))
            (should (null (plist-get r :errors)))
            (should (equal (plist-get r :warnings) nil))
            (should (= (plist-get r :compiled) (length (drgnx-build-files root))))
            (should (file-exists-p (expand-file-name "wb/drgnx-explorer.elc" root)))))
      (delete-directory root t))))

(defun drgnx-build-test--emacs (&rest forms)
  "Run FORMS in a fresh batch Emacs (as `drgnx build' runs); return its output."
  (with-temp-buffer
    (apply #'call-process (expand-file-name invocation-name invocation-directory) nil t nil
           "--batch" "-Q" "-L" (expand-file-name "core" drgnx-dir)
           (mapcan (lambda (f) (list "--eval" (prin1-to-string f))) forms))
    (buffer-string)))

(ert-deftest drgnx-build/a-rebuild-never-compiles-against-stale-dependencies ()
  ;; 1b inlines 2a's defsubst and compiles first (name order).  After 2a changes, a fresh
  ;; `drgnx build' must compile 1b against the new 2a source, not 2a's old .elc.
  (let* ((root (make-temp-file "drgnx-build" t)) (core (expand-file-name "core" root))
         (a (expand-file-name "drgnx-test-2a.el" core)))
    (unwind-protect
        (progn
          (make-directory core)
          (with-temp-file a (insert ";;; -*- lexical-binding: t -*-\n(defsubst drgnx-test-a-val () 1)\n(provide 'drgnx-test-2a)\n"))
          (with-temp-file (expand-file-name "drgnx-test-1b.el" core)
            (insert ";;; -*- lexical-binding: t -*-\n(require 'drgnx-test-2a)\n(defun drgnx-test-b () (drgnx-test-a-val))\n(provide 'drgnx-test-1b)\n"))
          (drgnx-build-test--emacs `(load ,(expand-file-name "core/drgnx-build.el" drgnx-dir) nil t) `(drgnx-build ,root))
          (sleep-for 1.1)
          (with-temp-file a (insert ";;; -*- lexical-binding: t -*-\n(defsubst drgnx-test-a-val () 2)\n(provide 'drgnx-test-2a)\n"))
          (drgnx-build-test--emacs `(load ,(expand-file-name "core/drgnx-build.el" drgnx-dir) nil t) `(drgnx-build ,root))
          (should (string-search "value=2" (drgnx-build-test--emacs
                                            `(add-to-list 'load-path ,core)
                                            `(load ,(expand-file-name "drgnx-test-1b.elc" core) nil t)
                                            '(princ (format "value=%s" (drgnx-test-b)))))))
      (delete-directory root t))))

(defun drgnx-build-test--build (root)
  "`drgnx-build' of ROOT in a fresh batch Emacs (as `drgnx build' runs): what the suite already loaded
never hides a warning.  Returns its result."
  (let ((out (drgnx-build-test--emacs `(load ,(expand-file-name "core/drgnx-build.el" drgnx-dir) nil t)
                                      `(let ((print-length nil) (print-level nil))
                                         (princ "\ndrgnx-build-result: ") (prin1 (drgnx-build ,root))))))
    (if-let* ((at (string-search "\ndrgnx-build-result: " out)))
        (car (read-from-string out (+ at (length "\ndrgnx-build-result: "))))
      (error "No build result from the fresh Emacs: %s" out))))

(ert-deftest drgnx-build/each-file-compiles-in-an-emacs-of-its-own ()
  ;; 1a requires `project' (compiling it loads project); 1b uses `project-root' without declaring it.  In one Emacs
  ;; 1b compiled clean; the native compiler, which compiles each file alone, warned and opened *Warnings* in the
  ;; user's frame.  The build must say what the native compiler says.
  (let* ((root (make-temp-file "drgnx-build" t)) (core (expand-file-name "core" root)))
    (unwind-protect
        (progn
          (make-directory core)
          (with-temp-file (expand-file-name "drgnx-test-1a.el" core)
            (insert ";;; -*- lexical-binding: t -*-\n(require 'project)\n(provide 'drgnx-test-1a)\n"))
          (with-temp-file (expand-file-name "drgnx-test-1b.el" core)
            (insert ";;; -*- lexical-binding: t -*-\n(defun drgnx-test-b (p) (project-root p))\n(provide 'drgnx-test-1b)\n"))
          (let ((r (drgnx-build-test--build root)))
            (should (= (plist-get r :compiled) 2))
            (should (seq-find (lambda (w) (string-search "drgnx-test-1b.el: the function ‘project-root’" w))
                              (plist-get r :warnings)))))
      (delete-directory root t))))

(ert-deftest drgnx-build/the-build-test-never-sees-what-the-suite-loaded ()
  ;; M4-15: a function an earlier test defined (a package it loaded) must not hide a warning.
  (let* ((root (make-temp-file "drgnx-build" t)) (core (expand-file-name "core" root)))
    (fset 'drgnx-build-test--preloaded (lambda () 1))
    (unwind-protect
        (progn
          (make-directory core)
          (with-temp-file (expand-file-name "drgnx-test-uses.el" core)
            (insert ";;; -*- lexical-binding: t -*-\n(defun drgnx-test-uses () (drgnx-build-test--preloaded))\n(provide 'drgnx-test-uses)\n"))
          (should (seq-find (lambda (w) (string-search "drgnx-build-test--preloaded" w))
                            (plist-get (drgnx-build-test--build root) :warnings))))
      (fmakunbound 'drgnx-build-test--preloaded)
      (delete-directory root t))))
