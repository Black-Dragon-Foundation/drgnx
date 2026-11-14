;;; wb-actions-test.el --- batch tests: Buffers and Explorer row actions, panel tabs, the mode menu -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(require 'drgnx-actions)
(setq drgnx-explorer--lisp-listing t)       ; the Lisp listing (a remote root's, plan sja-complete Q3): on local folders here

(defmacro drgnx-actions-test--with (root &rest body)
  "BODY with an Explorer rooted at ROOT (a.txt, sub/b.txt), the Buffers panel, rules on."
  (declare (indent 1))
  `(drgnx-test-with-state
     (let* ((,root (file-name-as-directory (make-temp-file "drgnx-actions" t)))
            (drgnx-wb--sections nil)
            (display-buffer-alist nil))
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
