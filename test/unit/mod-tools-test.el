;;; mod-tools-test.el --- batch tests: lang, vc, terminal, search, org modules -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)
(require 'drgnx-area)
(require 'eglot)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(dolist (m '("lang/drgnx-lang" "tools/drgnx-vc" "tools/drgnx-terminal" "tools/drgnx-search" "org/drgnx-org"))
  (load (expand-file-name (concat "modules/" m) drgnx-dir) nil t))

(ert-deftest drgnx-lang/eglot-starts-only-with-a-server-on-the-path ()
  ;; Never a question: eglot runs only when the mode's server program exists.
  (let* ((dir (make-temp-file "drgnx-bin" t)) (prog (expand-file-name "drgnx-fake-ls" dir))
         (exec-path (cons dir exec-path))
         (eglot-server-programs `((python-mode ,prog) ((js-mode js-ts-mode) "drgnx-no-such-ls"))))
    (unwind-protect
        (progn
          (write-region "#!/bin/sh\n" nil prog nil 'silent)
          (set-file-modes prog #o755)
          (with-temp-buffer (python-mode) (should (drgnx-lang-server-available-p)))
          (with-temp-buffer (js-mode) (should-not (drgnx-lang-server-available-p)))
          (with-temp-buffer (fundamental-mode) (should-not (drgnx-lang-server-available-p))))
      (delete-directory dir t))))

(ert-deftest drgnx-lang/tree-sitter-modes-when-the-grammar-is-there ()
  (let ((major-mode-remap-alist nil))
    (cl-letf (((symbol-function 'treesit-language-available-p) (lambda (lang &rest _) (eq lang 'python))))
      (drgnx-lang-remap-modes)
      (should (eq (alist-get 'python-mode major-mode-remap-alist) 'python-ts-mode))
      (should-not (alist-get 'js-mode major-mode-remap-alist)))))

(ert-deftest drgnx-terminal/a-new-terminal-opens-in-the-panel ()
  (let ((display-buffer-alist nil) (drgnx-signal--editor-window nil) (drgnx-wb-unrouted nil))
    (delete-other-windows)
    (drgnx-rules-mode 1)
    (unwind-protect
        (let ((b (drgnx-terminal-new)) (b2 (drgnx-terminal-new)))
          (should (eq (window-buffer (drgnx-wb-area-window 'panel)) b2))
          (should (eq (drgnx-wb-area-tab 'panel) 'terminal))
          (should-not (eq b b2))                      ; a new one each time
          (should-not drgnx-wb-unrouted)
          (dolist (x (list b b2)) (let ((kill-buffer-query-functions nil)) (kill-buffer x))))
      (drgnx-rules-mode -1)
      (drgnx-wb-area-hide 'panel))))

(ert-deftest drgnx-search/project-search-results-go-to-the-panel ()
  (skip-unless (executable-find "git"))
  (let* ((dir (file-name-as-directory (make-temp-file "drgnx-proj" t))) (display-buffer-alist nil)
         (default-directory dir) (drgnx-signal--editor-window nil))
    (let ((default-directory dir)) (call-process "git" nil nil nil "init" "-q"))
    (write-region "needle here\n" nil (expand-file-name "a.txt" dir) nil 'silent)
    (delete-other-windows)
    (drgnx-rules-mode 1)
    (unwind-protect
        (progn
          (drgnx-search-project "needle")
          (should (string-match-p "xref" (buffer-name (window-buffer (drgnx-wb-area-window 'panel)))))
          (should (eq (drgnx-wb-area-tab 'panel) 'results)))
      (drgnx-rules-mode -1)
      (drgnx-wb-area-hide 'panel)
      (delete-directory dir t))))

(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(ert-deftest drgnx-org/the-org-commands-are-registered ()
  (drgnx-test-with-modules '(org/org) :strict t
                           (should (drgnx-commands-get 'org-capture))
                           (should (drgnx-commands-get 'org-agenda)))
  (should-not (drgnx-commands-get 'org-capture)))

(ert-deftest drgnx-lang/server-alternatives-count-and-never-prompt ()
  ;; eglot's own entries are often (eglot-alternatives …) functions: the first installed one counts;
  ;; a function contact that would ask a question counts as no server, and never asks.
  (let* ((dir (make-temp-file "drgnx-bin" t)) (prog (expand-file-name "drgnx-fake-ls2" dir))
         (exec-path (cons dir exec-path))
         (eglot-server-programs `((python-mode . ,(eglot-alternatives (list "drgnx-no-such-ls" prog)))
                                  (js-mode . ,(lambda (&rest _) (read-string "Server: "))))))
    (unwind-protect
        (progn
          (write-region "#!/bin/sh\n" nil prog nil 'silent)
          (set-file-modes prog #o755)
          (with-temp-buffer (python-mode) (should (drgnx-lang-server-available-p)))
          (with-temp-buffer (js-mode) (should-not (drgnx-lang-server-available-p))))
      (delete-directory dir t))))

(ert-deftest drgnx-lang/eglot-connects-in-the-background ()
  (require 'xref)
  (let ((sync eglot-sync-connect) (prompt xref-prompt-for-identifier))
    (setq eglot-sync-connect 3 xref-prompt-for-identifier (eval (car (get 'xref-prompt-for-identifier 'standard-value)) t))
    (unwind-protect
        (progn
          (drgnx-test-with-modules '(lang/eglot) :strict t
                                   (should-not eglot-sync-connect)
                                   (should-not xref-prompt-for-identifier))
          (should (eql eglot-sync-connect 3))                ; and the teardown puts them back
          (should xref-prompt-for-identifier))
      (setq eglot-sync-connect sync xref-prompt-for-identifier prompt))))
