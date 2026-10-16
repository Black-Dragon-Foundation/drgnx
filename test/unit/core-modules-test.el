;;; core-modules-test.el --- batch tests: the module system -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-modules)

(defmacro drgnx-test--fresh-modules (&rest body)
  `(let ((drgnx-modules--table nil) (drgnx-modules--report nil)) ,@body))

(ert-deftest drgnx-modules/define-and-run-by-stage ()
  (drgnx-test--fresh-modules
   (let (ran)
     (drgnx-module-define 'test/early :doc "early" :stage 'startup :setup (lambda () (push 'early ran)))
     (drgnx-module-define 'test/late :doc "late" :stage 'idle :setup (lambda () (push 'late ran)))
     (drgnx-modules-run 'startup)
     (should (equal ran '(early)))
     (drgnx-modules-run 'idle)
     (should (equal ran '(late early))))))

(ert-deftest drgnx-modules/errors-are-isolated-and-reported ()
  (drgnx-test--fresh-modules
   (let (ran)
     (drgnx-module-define 'test/broken :doc "b" :stage 'startup :setup (lambda () (error "kaputt")))
     (drgnx-module-define 'test/fine :doc "f" :stage 'startup :setup (lambda () (setq ran t)))
     (drgnx-modules-run 'startup)
     (should ran)
     (let ((broken (alist-get 'test/broken (drgnx-modules-report))))
       (should (string-search "kaputt" (plist-get broken :error)))
       (should (integerp (plist-get broken :ms))))
     (should (eq (plist-get (alist-get 'test/fine (drgnx-modules-report)) :error) nil)))))

(ert-deftest drgnx-modules/load-directory ()
  (drgnx-test--fresh-modules
   (let ((dir (make-temp-file "drgnx-mods" t)))
     (unwind-protect
         (progn
           (make-directory (expand-file-name "test" dir))
           (write-region "(drgnx-module-define 'test/from-file :doc \"x\" :stage 'startup :setup #'ignore)\n"
                         nil (expand-file-name "test/drgnx-from-file.el" dir))
           (write-region "(error \"does not load\")\n" nil (expand-file-name "test/drgnx-bad.el" dir))
           (drgnx-modules-load-directory dir)
           (should (assq 'test/from-file drgnx-modules--table))
           (should (string-search "does not load"
                                  (plist-get (alist-get 'test/drgnx-bad (drgnx-modules-report)) :error))))
       (delete-directory dir t)))))

(ert-deftest drgnx-modules/a-built-module-runs-compiled ()
  (let ((dir (make-temp-file "drgnx-modules" t)) (drgnx-modules--table nil) (drgnx-modules--report nil))
    (unwind-protect
        (let ((f (expand-file-name "drgnx-test-compiled.el" dir)))
          (with-temp-file f
            (insert ";;; -*- lexical-binding: t -*-\n(defun drgnx-test-compiled-fn () 1)\n"))
          (byte-compile-file f)
          (let ((load-prefer-newer t)) (drgnx-modules-load-directory dir))
          (should (byte-code-function-p (symbol-function 'drgnx-test-compiled-fn))))
      (delete-directory dir t))))
