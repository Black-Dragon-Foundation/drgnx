;;; fmt-tree-test.el --- batch test: all of drgnx's Emacs Lisp is formatted (bin/drgnx fmt) -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-fmt)

(ert-deftest drgnx-fmt/every-file-of-drgnx-is-formatted ()
  (let ((bad (seq-remove (lambda (r) (eq (cadr r) 'same))
                         (mapcar (lambda (f) (list (file-relative-name f drgnx-dir) (car (drgnx-fmt-file f nil t))))
                                 (drgnx-fmt-files)))))
    (should-not bad)))

;;; fmt-tree-test.el ends here
