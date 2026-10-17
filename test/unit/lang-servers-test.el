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

;;; lang-servers-test.el ends here
