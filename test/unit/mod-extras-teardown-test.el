;;; mod-extras-teardown-test.el --- batch tests: the package-backed extras turn off and leave what the user had -*- lexical-binding: t -*-
;; The 15 `extra/' modules (teardown batch): what a setup sets in another package's options comes back, a mode a
;; module turned on in live buffers goes off, gptel's backend returns.  A module whose package is missing here
;; (`extra/debug': dape) is covered by its teardown function alone.
(require 'ert)
(require 'ert-x)
(require 'cl-lib)
(require 'seq)
(require 'drgnx)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)

(defmacro drgnx-extras-teardown-test--with-packages (&rest body)
  "BODY with the user's ELPA on `load-path' (read-only) and no outside program found."
  `(let* ((elpa (expand-file-name (or (getenv "DRGNX_USER_ELPA") "~/.config/emacs/elpa")))
          (load-path (append load-path (and (file-directory-p elpa)
                                            (seq-filter #'file-directory-p (directory-files elpa t "\\`[^.]"))))))
     (cl-letf (((symbol-function 'executable-find) #'ignore)) ,@body)))

(defun drgnx-extras-teardown-test--installed-p (&rest libs)
  (seq-every-p (lambda (l) (locate-library (symbol-name l))) libs))

(ert-deftest drgnx-extras-teardown/options-come-back ()
  (drgnx-extras-teardown-test--with-packages
   (skip-unless (drgnx-extras-teardown-test--installed-p 'vertico 'orderless 'marginalia 'corfu 'diff-hl 'apheleia
                                                         'indent-bars))
   (dolist (f '(orderless corfu diff-hl apheleia indent-bars)) (require f))
   (let ((vars '(completion-styles completion-category-overrides corfu-auto diff-hl-disable-on-remote
                                   apheleia-log-only-errors apheleia-mode-alist indent-bars-treesit-support))
         before during)
     (setq before (mapcar #'symbol-value vars))
     (drgnx-test-with-modules '(extra/completion extra/hunks extra/format extra/guides) :strict t
                              (setq during (mapcar #'symbol-value vars)))
     (should (equal (nth 0 during) '(orderless basic)))                       ; the setups did set them
     (should (eq (nth 2 during) t))
     (should (eq (nth 3 during) t))
     (should-not (rassq 'lisp-indent (nth 5 during)))
     (should (equal (mapcar #'symbol-value vars) before)))))

(ert-deftest drgnx-extras-teardown/modes-in-live-buffers-go-off ()
  (drgnx-extras-teardown-test--with-packages
   (skip-unless (drgnx-extras-teardown-test--installed-p 'keycast 'indent-bars))
   (let ((buf (generate-new-buffer " *extras-teardown*")))
     (unwind-protect
         (progn
           (drgnx-test-with-modules '(extra/blame extra/keycast extra/guides) :strict t
                                    (with-current-buffer buf
                                      (emacs-lisp-mode)
                                      (drgnx-blame-mode 1)
                                      (setq-local indent-bars-mode t))      ; the mode itself needs a display; its off function runs
                                    (keycast-mode-line-mode 1)
                                    (should (buffer-local-value 'drgnx-blame-mode buf)))
           (should-not (buffer-local-value 'drgnx-blame-mode buf))
           (should-not drgnx-blame--timer)
           (should-not (buffer-local-value 'indent-bars-mode buf))
           (should-not keycast-mode-line-mode))
       (kill-buffer buf)))))

(ert-deftest drgnx-extras-teardown/llm-hook-is-a-name-and-the-backend-returns ()
  (drgnx-extras-teardown-test--with-packages
   (skip-unless (drgnx-extras-teardown-test--installed-p 'gptel))
   (require 'gptel)
   (let ((process-environment (cons "OPENROUTER_API_KEY=sk-or-fake" process-environment))
         (backend gptel-backend) (model gptel-model))
     (drgnx-test-with-modules '(extra/llm) :strict t
                              (should-not (seq-remove #'symbolp drgnx-ai-probe-done-hook))          ; no closure on a global hook
                              (should (memq 'drgnx-llm--configure drgnx-ai-probe-done-hook)))
     (should (eq gptel-backend backend))
     (should (eq gptel-model model)))))

(ert-deftest drgnx-extras-teardown/debug-session-keys-go-with-the-module ()
  (load (expand-file-name "modules/extra/drgnx-debug" drgnx-dir) nil t)
  (let ((teardown (plist-get (cdr (assq 'extra/debug drgnx-modules--table)) :teardown)))
    (should (functionp teardown))
    (unwind-protect
        (progn (drgnx-debug-session-mode 1)
               (funcall teardown)
               (should-not drgnx-debug-session-mode))
      (drgnx-debug-session-mode -1))))

;;; mod-extras-teardown-test.el ends here
