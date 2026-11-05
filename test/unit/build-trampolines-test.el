;;; build-trampolines-test.el --- `drgnx build' compiles the trampolines of the primitives drgnx advises -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: a static scan of source text, and the build's loop with the native compiler stubbed (it is an outside
;; tool; what is checked is which primitives drgnx hands it).
(require 'ert)
(require 'cl-lib)
(require 'drgnx-build)
(require 'drgnx-paths)

(defun drgnx-build-trampolines-test--root (files)
  "A temp checkout with FILES, an alist (NAME . TEXT), under core/."
  (let ((root (make-temp-file "drgnx-tramp" t)))
    (make-directory (expand-file-name "core" root))
    (pcase-dolist (`(,name . ,text) files)
      (with-temp-file (expand-file-name name root) (insert text)))
    root))

(ert-deftest drgnx-build/the-scan-finds-advised-and-replaced-primitives-only ()
  (let ((root (drgnx-build-trampolines-test--root
               '(("core/a.el" . "(advice-add 'car :around #'ignore)
(defun f () (cl-letf (((symbol-function 'cons) #'ignore)) 1))
(drgnx-module-advice #'cdr :before named ())
(advice-add 'seq-uniq :around #'ignore)       ; Lisp: no trampoline
(advice-add fn :before #'ignore)              ; not by name: the lists below
")
                 ("core/drgnx-guard.el" . "(defvar drgnx-guard-prompt-functions '(mapconcat nonexistent-function))
")))))
    (unwind-protect
        (should (equal (drgnx-build-advised-primitives root) '(car cdr cons mapconcat)))
      (delete-directory root t))))

(ert-deftest drgnx-build/trampolines-cover-advised-primitives ()
  "What the build compiles is what the scan of the checkout finds, and only primitives."
  (let ((want (drgnx-build-advised-primitives drgnx-dir)) (compiled nil) (dir (make-temp-file "drgnx-eln" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-build--native-p) (lambda () t))
                  ((symbol-function 'comp-trampoline-compile) (lambda (s) (push s compiled)))
                  ((symbol-function 'comp--trampoline-search) (lambda (_) nil))
                  ((symbol-function 'drgnx-build-trampoline-dir) (lambda () dir)))
          (should (equal (drgnx-build-trampolines drgnx-dir) want))
          (should (equal (sort compiled #'string<) want))
          (dolist (s '(require call-process make-process read-from-minibuffer))
            (should (memq s want)))
          (should-not (memq 'flymake-start want))
          (dolist (s want) (should (subr-primitive-p (symbol-function s)))))
      (delete-directory dir t))))

(ert-deftest drgnx-build/trampolines-skip-what-is-there ()
  (let ((compiled nil) (dir (make-temp-file "drgnx-eln" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-build--native-p) (lambda () t))
                  ((symbol-function 'comp-trampoline-compile) (lambda (s) (push s compiled)))
                  ((symbol-function 'comp--trampoline-search) (lambda (s) (eq s 'require)))
                  ((symbol-function 'drgnx-build-trampoline-dir) (lambda () dir)))
          (drgnx-build-trampolines drgnx-dir)
          (should compiled)
          (should-not (memq 'require compiled)))
      (delete-directory dir t))))

(ert-deftest drgnx-build/trampolines-use-the-test-eln-dir ()
  (let ((dir (make-temp-file "drgnx-eln" t)))
    (unwind-protect
        (let ((process-environment (cons (concat "DRGNX_TEST_ELN_DIR=" dir) process-environment)))
          (should (equal (drgnx-build-trampoline-dir) (expand-file-name dir))))
      (delete-directory dir t))))

;;; build-trampolines-test.el ends here
