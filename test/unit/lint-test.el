;;; lint-test.el --- batch tests: source lints -*- lexical-binding: t -*-
(require 'ert)

(defconst drgnx-lint--root
  (expand-file-name "../../" (file-name-directory (or load-file-name buffer-file-name))))

(defun drgnx-lint--files ()
  (apply #'append (mapcar (lambda (d) (directory-files-recursively (expand-file-name d drgnx-lint--root) "\\.el\\'"))
                          '("core" "harness" "init" "modules"))))

(ert-deftest drgnx-lint/no-macros-obsolete-in-emacs-31 ()
  ;; `if-let' and `when-let' are obsolete as of 31.1 (warnings in every batch run); use the starred forms.
  (let (hits)
    (dolist (f (drgnx-lint--files))
      (with-temp-buffer
        (insert-file-contents f)
        (goto-char (point-min))
        (while (re-search-forward "(\\(if\\|when\\)-let (" nil t)
          (push (format "%s:%d" (file-relative-name f drgnx-lint--root) (line-number-at-pos)) hits))))
    (should (equal hits nil))))
