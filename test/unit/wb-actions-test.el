;;; wb-actions-test.el --- batch tests: Buffers and Explorer row actions, panel tabs, the mode menu -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(require 'drgnx-actions)

(defmacro drgnx-actions-test--with (root &rest body)
  "BODY with an Explorer rooted at ROOT (a.txt, sub/b.txt), the Buffers panel, rules on."
  (declare (indent 1))
  `(drgnx-test-with-state
     (let* ((,root (file-name-as-directory (make-temp-file "drgnx-actions" t)))
            (drgnx-wb--sections nil)
            (drgnx-buffers--order nil) (drgnx-buffers--signature nil) (display-buffer-alist nil))
       (unwind-protect
           (progn
             (make-directory (expand-file-name "sub" ,root))
             (dolist (f '("a.txt" "sub/b.txt")) (write-region "x\n" nil (expand-file-name f ,root) nil 'silent))
             (delete-other-windows)
             (drgnx-rules-mode 1)
             (drgnx-explorer-setup) (drgnx-buffers-setup)
             (drgnx-explorer-set-roots (list ,root))
             (drgnx-wb-show-sidebar)
             ,@body)
         (drgnx-rules-mode -1)
         (drgnx-explorer-set-roots nil)                 ; its watches go: no events from the folder's removal
         (drgnx-wb-hide-sidebar) (drgnx-wb-area-hide 'panel)
         (delete-other-windows)
         (dolist (b (buffer-list))
           (when (or (and (buffer-file-name b) (string-prefix-p ,root (buffer-file-name b)))
                     (with-current-buffer b (and (derived-mode-p 'dired-mode) (string-prefix-p ,root default-directory))))
             (kill-buffer b)))
         (delete-directory ,root t)))))

(defun drgnx-actions-test--explorer-at (name)
  (select-window (drgnx-wb-section-window 'explorer))
  (goto-char (point-min))
  (re-search-forward (regexp-quote name))
  (current-buffer))

(ert-deftest drgnx-actions/buffers-rows ()
  (drgnx-actions-test--with root
    (let ((a (find-file-noselect (expand-file-name "a.txt" root))))
      (drgnx-signal--flush) (drgnx-buffers--refresh)
      (with-current-buffer a (insert "y"))
      (select-window (drgnx-wb-section-window 'buffers))
      (goto-char (drgnx-buffers--row-pos a))
      (drgnx-buffers-save-row)
      (should-not (buffer-modified-p a))
      (drgnx-buffers-copy-path-row)
      (should (equal (current-kill 0) (expand-file-name "a.txt" root)))
      (drgnx-buffers-reveal-row)
      (should (eq (selected-window) (drgnx-wb-section-window 'explorer)))
      (should (equal (drgnx-explorer-node-at (point)) (expand-file-name "a.txt" root))))))

(ert-deftest drgnx-actions/explorer-rows ()
  (drgnx-actions-test--with root
    (let ((a (find-file-noselect (expand-file-name "a.txt" root))))
      (drgnx-signal--flush) (drgnx-buffers--refresh)
      (drgnx-actions-test--explorer-at "a.txt")
      (drgnx-explorer-reveal-in-buffers)
      (should (eq (selected-window) (drgnx-wb-section-window 'buffers)))
      (should (eq (drgnx-buffers-buffer-at (point)) a))
      (drgnx-actions-test--explorer-at "sub")
      (drgnx-explorer-open-in-dired)
      (should (with-current-buffer (window-buffer (drgnx-wb-editor-window)) (derived-mode-p 'dired-mode))))))

(ert-deftest drgnx-actions/panel-tabs-cycle ()
  (let ((display-buffer-alist nil))
    (delete-other-windows)
    (set-frame-parameter nil 'drgnx-wb-areas nil)
    (unwind-protect
        (progn
          (drgnx-wb-area-show 'panel 'problems)
          (drgnx-wb-panel-next-tab)
          (should (eq (drgnx-wb-area-tab 'panel) 'output))
          (dotimes (_ 4) (drgnx-wb-panel-next-tab))
          (should (eq (drgnx-wb-area-tab 'panel) 'problems)))   ; wraps
      (drgnx-wb-area-hide 'panel))))

(ert-deftest drgnx-actions/the-mode-menu ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (should (keymapp (drgnx-actions--mode-menu)))))
