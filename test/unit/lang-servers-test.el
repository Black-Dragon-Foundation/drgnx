;;; lang-servers-test.el --- batch tests: when language servers start and stop -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)
(load (expand-file-name "modules/lang/drgnx-lang" drgnx-dir) nil t)

(ert-deftest drgnx-lang/no-server-where-servers-are-off ()
  ;; harness sessions: a scenario's fixture projects must not each start a pyright
  (let ((file (make-temp-file "drgnx-lang" nil ".py")) (started 0))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-lang-server-available-p) (lambda () t))
                  ((symbol-function 'eglot-ensure) (lambda () (cl-incf started))))
          (with-current-buffer (find-file-noselect file)
            (let ((process-environment (cons "DRGNX_NO_LANGUAGE_SERVERS=1" process-environment)))
              (drgnx-lang--maybe-eglot))
            (should (= started 0))
            (let ((process-environment (cons "DRGNX_NO_LANGUAGE_SERVERS" process-environment)))
              (drgnx-lang--maybe-eglot))
            (should (= started 1))
            (set-buffer-modified-p nil)
            (kill-buffer)))
      (delete-file file))))

(ert-deftest drgnx-lang/a-server-stops-with-its-last-buffer ()
  (defvar eglot-autoshutdown)
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
        (was (and (boundp 'eglot-autoshutdown) eglot-autoshutdown)))
    (unwind-protect
        (progn
          (setq eglot-autoshutdown nil)
          (funcall (plist-get (alist-get 'lang/eglot drgnx-modules--table) :setup))
          (should (eq eglot-autoshutdown t)))
      (remove-hook 'prog-mode-hook #'drgnx-lang--maybe-eglot)
      (setq eglot-autoshutdown was))))


(ert-deftest drgnx-lang/the-remap-comes-from-the-one-grammar-table ()
  ;; M11a-2: the grammars module owns the language/mode table; lang/eglot reads it, it keeps none of its own
  (should-not (boundp 'drgnx-lang-tree-sitter-modes))
  (let ((major-mode-remap-alist nil))
    (cl-letf (((symbol-function 'treesit-language-available-p) (lambda (&rest _) t)))
      (drgnx-lang-remap-modes))
    (should (eq (alist-get 'python-mode major-mode-remap-alist) 'python-ts-mode))
    (should (eq (alist-get 'typescript-mode major-mode-remap-alist) 'typescript-ts-mode))
    (should major-mode-remap-alist)
    (dolist (pair major-mode-remap-alist)
      (should (seq-some (lambda (e) (and (eq (nth 1 e) (car pair)) (eq (nth 2 e) (cdr pair)))) drgnx-grammars-modes)))))

;;; lang-servers-test.el ends here
