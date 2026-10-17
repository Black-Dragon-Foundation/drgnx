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
          (let ((r (drgnx-build root)))
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
