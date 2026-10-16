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
