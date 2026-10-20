;;; handler-trap-fixture-test.el --- batch tests: the file name handler trap itself -*- lexical-binding: t -*-
;; The trap (test/fixtures/handler-trap.el) records the handler calls an agent's name causes.  Emacs loading one of
;; its own libraries while a test visits a file (`set-auto-mode' autoloads image.el; a warning loads warnings.el) is
;; not one: installs that ship the lisp as `.el.gz' (Homebrew, Debian/Ubuntu, Fedora) load it through jka-compr.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/handler-trap" drgnx-dir) nil t)

(ert-deftest drgnx-handler-trap/emacs-own-libraries-load-as-usual ()
  ;; a library of Emacs not loaded yet, required inside the trap: it loads (from its `.el.gz' when that is newer or
  ;; the only one) and the trap records nothing; an agent's `.gz' name is still recorded
  (let ((lib (cl-find-if (lambda (l) (and (not (featurep l)) (locate-library (symbol-name l))))
                         '(ezimage iimage image-file thumbs))))
    (skip-unless lib)
    (let ((load-prefer-newer t))                    ; as the runner sets it: `load' then looks at the `.el.gz' too
      (drgnx-test-with-handler-trap
        (require lib)
        (should (featurep lib))
        (should-not drgnx-test-handler-calls)
        (file-exists-p (expand-file-name "x.gz" temporary-file-directory))
        (should drgnx-test-handler-calls)))))

;;; handler-trap-fixture-test.el ends here
