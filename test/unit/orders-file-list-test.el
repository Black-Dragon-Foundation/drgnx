;;; orders-file-list-test.el --- `drgnx test --orders' picks the files the runner calls gated -*- lexical-binding: t -*-
;; test-class: det
;; `bin/drgnx test --orders' lists its gated files in bash (`orders_files': `head -n 15 | grep -E'), because the hub-chaos
;; job has no host Emacs; the runner reads the same line with `drgnx-run-ert--file-patterns'.  Nothing else ties the two
;; together, so this runs the script's own grep over the sample lines and over every test file and compares.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-run-ert)

(defun drgnx-orders-list-test--grep-regexp ()
  "The extended regexp `orders_files' in bin/drgnx greps for, read from the script."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "bin/drgnx" drgnx-dir))
    (re-search-forward "^orders_files() {")
    (re-search-forward "head -n 15 \"\\$f\" | grep -Eq '\\([^']+\\)'")
    (match-string 1)))

(defun drgnx-orders-list-test--bash-gated-p (file regexp)
  "Does the script's `head -n 15 FILE | grep -Eq REGEXP' pick FILE?"
  (eql 0 (call-process "bash" nil nil nil "-c" "head -n 15 \"$1\" | grep -Eq \"$2\"" "bash" file regexp)))

(defun drgnx-orders-list-test--lisp-gated-p (file)
  (and (memq 'gated (drgnx-run-ert--file-patterns file)) t))

(ert-deftest drgnx-orders/bash-and-runner-agree-on-the-sample-lines ()
  (let* ((regexp (drgnx-orders-list-test--grep-regexp))
         (dir (make-temp-file "drgnx-orders" t)) (n 0) (yes 0) (no 0))
    (unwind-protect
        (dolist (case (append
                       (mapcar (lambda (l) (list l 0)) '(";; test-pattern: gated" ";; test-pattern: orders gated"
                                                         ";; test-pattern: gated handshake"
                                                         ";; test-pattern: orders handshake gated orders"))
                       (mapcar (lambda (l) (list l 0)) '(";; test-pattern: orders" ";; test-pattern: pure"
                                                         ";; test-pattern: gated and more" ";; test-pattern: gated  orders"
                                                         ";; test-pattern:" ";; test-patterns: gated"
                                                         ";;test-pattern: gated" " ;; test-pattern: gated"
                                                         ";; test-pattern: gated " ";; test-pattern: ungated"))
                       ;; the line's position: the 15th line counts, the 16th does not
                       '((";; test-pattern: gated" 14) (";; test-pattern: gated" 15))))
          (let* ((file (expand-file-name (format "case-%d.el" (cl-incf n)) dir)) (pad (cadr case)))
            (with-temp-file file
              (dotimes (_ pad) (insert ";; filler\n"))
              (insert (car case) "\n"))
            (should (eq (drgnx-orders-list-test--lisp-gated-p file)
                        (drgnx-orders-list-test--bash-gated-p file regexp)))
            (if (drgnx-orders-list-test--lisp-gated-p file) (cl-incf yes) (cl-incf no))))
      (delete-directory dir t))
    (should (and (= n 16) (> yes 0) (> no 0)))))

(ert-deftest drgnx-orders/bash-and-runner-agree-on-every-test-file ()
  (let ((regexp (drgnx-orders-list-test--grep-regexp)) (gated 0))
    (dolist (file (directory-files-recursively (expand-file-name "test" drgnx-dir) "-test\\.el\\'"))
      (let ((lisp (drgnx-orders-list-test--lisp-gated-p file)))
        (when lisp (cl-incf gated))
        (should (eq lisp (drgnx-orders-list-test--bash-gated-p file regexp)))))
    (should (> gated 0))))

(provide 'orders-file-list-test)
;;; orders-file-list-test.el ends here
