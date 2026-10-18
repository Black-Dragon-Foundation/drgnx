;;; lang-servers-test.el --- batch tests: when language servers start and stop -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
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
  (require 'eglot)
  (let ((was eglot-autoshutdown))
    (setq eglot-autoshutdown nil)
    (unwind-protect
        (progn
          (drgnx-test-with-modules '(lang/eglot) :strict t
                                   (should (eq eglot-autoshutdown t)))
          (should-not eglot-autoshutdown))                   ; the teardown puts it back
      (setq eglot-autoshutdown was))))


(ert-deftest drgnx-lang/turned-off-the-remaps-are-back ()
  (let ((remaps (copy-alist major-mode-remap-alist)))
    (cl-letf (((symbol-function 'treesit-language-available-p) (lambda (lang &rest _) (eq lang 'python))))
      (drgnx-test-with-modules '(lang/eglot) :strict t
                               (should (eq (alist-get 'python-mode major-mode-remap-alist) 'python-ts-mode))))
    (should (equal major-mode-remap-alist remaps))))

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

;;;; Options a user set stay; servers stop with the module

(defcustom drgnx-lang-test-fake-option 'standard "A stand-in for a package's option." :type 'symbol)
(defcustom drgnx-lang-test-fake-other 'standard "A second stand-in." :type 'symbol)

(ert-deftest drgnx-lang/an-option-the-user-set-is-left-alone ()
  (let ((drgnx-lang-test-fake-option 'user) (drgnx-lang-test-fake-other 'standard))   ; the user's setq in config.el
    (drgnx-lang--set-option 'drgnx-lang-test-fake-option 'module)
    (drgnx-lang--set-option 'drgnx-lang-test-fake-other 'module)
    (should (eq drgnx-lang-test-fake-option 'user))
    (should (eq drgnx-lang-test-fake-other 'module))))

(defun drgnx-lang-test--kill-eglot-buffers (before)
  (dolist (b (buffer-list))
    (when (and (not (memq b before)) (string-match-p "\\` ?\\*EGLOT\\|\\`a\\.py\\'" (buffer-name b)))
      (with-current-buffer b (set-buffer-modified-p nil))
      (kill-buffer b))))

(ert-deftest drgnx-lang/turned-off-the-servers-stop ()
  (require 'eglot)
  (require 'python)
  (let* ((dir (file-name-as-directory (make-temp-file "drgnx-lang" t)))
         (before (buffer-list)) (server nil) (buf nil) (took nil))
    (copy-file (expand-file-name "test/fixtures/lsp-stub.sh" drgnx-dir) (expand-file-name "stub" dir))
    (set-file-modes (expand-file-name "stub" dir) #o755)
    (write-region "x = 1\n" nil (expand-file-name "a.py" dir) nil 'silent)
    (unwind-protect
        (progn
          (drgnx-test-with-modules '(lang/eglot)
            (setq buf (find-file-noselect (expand-file-name "a.py" dir)))
            (with-current-buffer buf
              (let ((eglot-sync-connect t))
                (setq server (eglot '(python-mode) `(transient . ,dir) 'eglot-lsp-server
                                    (list (expand-file-name "stub" dir)) "python"))))
            (should (jsonrpc-running-p server))
            (should (buffer-local-value 'eglot--managed-mode buf))
            (let ((start (float-time)))
              (drgnx-module-teardown 'lang/eglot)               ; what turning it off runs
              (setq took (- (float-time) start))))
          (should-not (jsonrpc-running-p server))
          (should-not (buffer-local-value 'eglot--managed-mode buf))
          (should (buffer-live-p buf))                          ; the file stays open
          (should (< took 3)))                                  ; short timeouts: never waits long
      (when (and server (jsonrpc-running-p server)) (ignore-errors (eglot-shutdown server nil 1 t)))
      (drgnx-lang-test--kill-eglot-buffers before)
      (delete-directory dir t))))

;;; lang-servers-test.el ends here
