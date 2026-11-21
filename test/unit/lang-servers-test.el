;;; lang-servers-test.el --- batch tests: when language servers start and stop -*- lexical-binding: t -*-
;; test-class: cond
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
  :tags '(:timing)                                              ; asserts how long the teardown took
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

(ert-deftest drgnx-lang/quiet-in-a-large-file-buffer ()
  ;; the flag editor/large-files sets (by hand here): no language server, and none is looked for
  (require 'drgnx-large-file)
  (with-temp-buffer
    (setq buffer-file-name (expand-file-name "big.py" temporary-file-directory))
    (setq-local drgnx-large-file 'lean)
    (let ((process-environment (cons "DRGNX_NO_LANGUAGE_SERVERS" process-environment)) ; unset: servers may start
          (looked 0))
      (cl-letf (((symbol-function 'drgnx-lang-server-available-p) (lambda (&rest _) (setq looked (1+ looked)) t))
                ((symbol-function 'eglot-ensure) (lambda () (ert-fail "eglot-ensure in a large file"))))
        (drgnx-lang--maybe-eglot))
      (should (= looked 0)))
    (setq buffer-file-name nil)))

;;; lang-servers-test.el ends here
