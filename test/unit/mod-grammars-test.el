;;; mod-grammars-test.el --- batch tests: tree-sitter grammars on request — a hint, never a prompt; installs as a job -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)
(load (expand-file-name "modules/lang/drgnx-grammars" drgnx-dir) nil t)

(defmacro drgnx-grammars-test--with (&rest body)
  "BODY with no grammar available, prompts that fail, and the hints forgotten; buffers made in it killed after."
  (declare (indent 0))
  `(let ((drgnx-grammars--hinted nil) (made nil))
     (cl-letf (((symbol-function 'treesit-language-available-p) (lambda (&rest _) nil))
               ((symbol-function 'read-string) (lambda (&rest _) (error "Prompted")))
               ((symbol-function 'y-or-n-p) (lambda (&rest _) (error "Prompted")))
               ((symbol-function 'yes-or-no-p) (lambda (&rest _) (error "Prompted"))))
       (unwind-protect (progn ,@body)
         (dolist (b made) (when (buffer-live-p b) (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))))))

(defun drgnx-grammars-test--buffer (name mode)
  (with-current-buffer (get-buffer-create name)
    (setq buffer-file-name (expand-file-name name temporary-file-directory))
    (funcall mode)
    (current-buffer)))

(ert-deftest drgnx-grammars/the-language-of-a-buffer ()
  (with-temp-buffer (python-mode) (should (eq (drgnx-grammars-language) 'python)))
  (with-temp-buffer (c++-mode) (should (eq (drgnx-grammars-language) 'cpp)))
  (with-temp-buffer (sh-mode) (should (eq (drgnx-grammars-language) 'bash)))
  (with-temp-buffer (setq buffer-file-name "/x/a.tsx") (should (eq (drgnx-grammars-language) 'tsx)))
  (with-temp-buffer (fundamental-mode) (should-not (drgnx-grammars-language))))

(ert-deftest drgnx-grammars/a-missing-grammar-is-a-hint-once ()
  (drgnx-grammars-test--with
    (let ((messages nil))
      (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
        (dolist (n '("a.py" "b.py"))
          (with-current-buffer (car (push (drgnx-grammars-test--buffer n #'python-mode) made))
            (drgnx-grammars--hint))))
      (should (= 1 (seq-count (lambda (m) (string-search "Install Language Support" m)) messages)))
      (should (string-search "python" (car messages))))))

(ert-deftest drgnx-grammars/install-is-a-job ()
  (drgnx-grammars-test--with
    (let ((started nil))
      (cl-letf (((symbol-function 'drgnx-jobs-start) (lambda (name command &rest _) (setq started (list name command)) "J1"))
                ((symbol-function 'drgnx-grammars--watch) #'ignore))
        (drgnx-grammars-install '(python tsx)))
      (should (equal (car started) "grammars"))
      (let ((line (format "%S" (cadr started))))
        (should (string-search "--batch" line))
        (should (string-search "tree-sitter-python" line))
        (should (string-search "tsx/src" line))
        (should (string-search (drgnx-grammars-dir) line))
        ;; --eval code is lexical: the recipes are set after treesit is loaded, never let-bound
        (should (string-match-p "(require 'treesit).*(setq treesit-language-source-alist" line))))))

(ert-deftest drgnx-grammars/after-the-job-buffers-switch ()
  (drgnx-grammars-test--with
    (let ((b (car (push (drgnx-grammars-test--buffer "c.py" #'python-mode) made))) (switched nil))
      (cl-letf (((symbol-function 'treesit-language-available-p) (lambda (lang &rest _) (eq lang 'python)))
                ((symbol-function 'python-ts-mode) (lambda () (setq switched (current-buffer)))))
        (drgnx-grammars--installed '(python)))
      (should (eq switched b)))))

;;; mod-grammars-test.el ends here
