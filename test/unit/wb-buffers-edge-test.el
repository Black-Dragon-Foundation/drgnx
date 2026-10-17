;;; wb-buffers-edge-test.el --- batch tests: the Buffers panel, edge cases -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-buffers)
(require 'drgnx-explorer)

(defmacro drgnx-buffers-edge--with (dir &rest body)
  "BODY with a fresh bus, an empty Buffers panel shown in the dock, and a temp DIR for files."
  (declare (indent 1))
  `(let* ((,dir (make-temp-file "drgnx-buffers-edge" t))
          (drgnx-signal--subscribers nil) (drgnx-signal--state nil) (drgnx-signal--editor-window nil)
          (drgnx-wb--sections nil) (drgnx-buffers--order nil) (drgnx-buffers--signature nil)
          (drgnx-buffers--filter nil) (drgnx-buffers-all-windows nil))
     (unwind-protect
         (progn
           (delete-other-windows)
           (drgnx-buffers-setup)
           (drgnx-signal--flush)
           (drgnx-wb-show-sidebar)
           ,@body)
       (drgnx-wb-hide-sidebar)
       (delete-other-windows)
       (dolist (b (buffer-list))
         (when (and (buffer-file-name b) (string-prefix-p ,dir (buffer-file-name b)))
           (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))
       (when (get-buffer drgnx-buffers-buffer-name) (kill-buffer drgnx-buffers-buffer-name))
       (delete-directory ,dir t))))

(defun drgnx-buffers-edge--open (dir name)
  (let ((f (expand-file-name name dir)))
    (make-directory (file-name-directory f) t)
    (write-region "x\n" nil f nil 'silent)
    (prog1 (find-file-noselect f) (drgnx-signal--flush))))

(defun drgnx-buffers-edge--header (section)
  (format "%s" (window-parameter (drgnx-wb-section-window section) 'header-line-format)))

(ert-deftest drgnx-buffers/the-filter-title-survives-hide-and-show ()
  (drgnx-buffers-edge--with dir
    (drgnx-buffers-edge--open dir "alpha.txt")
    (drgnx-buffers--filter-apply "alp")
    (should (string-search "alp" (drgnx-buffers-edge--header 'buffers)))
    (drgnx-wb-hide-sidebar)
    (drgnx-wb-show-sidebar)
    (should (string-search "alp" (drgnx-buffers-edge--header 'buffers)))
    (drgnx-buffers--filter-apply nil)
    (drgnx-wb-hide-sidebar)
    (drgnx-wb-show-sidebar)
    (should-not (string-search "alp" (drgnx-buffers-edge--header 'buffers)))
    (should (string-search "save all" (drgnx-buffers-edge--header 'buffers)))))   ; the buttons are back

(ert-deftest drgnx-buffers/the-explorer-find-title-survives-hide-and-show ()
  (let ((dir (file-name-as-directory (make-temp-file "drgnx-find-edge" t)))
        (drgnx-wb--sections nil) (drgnx-signal--editor-window nil) (drgnx-explorer-git nil))
    (unwind-protect
        (progn
          (write-region "x\n" nil (expand-file-name "needle.txt" dir) nil 'silent)
          (delete-other-windows)
          (drgnx-explorer-setup)
          (drgnx-explorer-set-roots (list dir))
          (drgnx-wb-show-sidebar)
          (drgnx-explorer--find-apply "needle")
          (should (string-search "needle" (drgnx-buffers-edge--header 'explorer)))
          (drgnx-wb-hide-sidebar)
          (drgnx-wb-show-sidebar)
          (should (string-search "needle" (drgnx-buffers-edge--header 'explorer))))
      (ignore-errors (drgnx-explorer-find-clear))
      (drgnx-wb-hide-sidebar)
      (drgnx-explorer-set-roots nil)
      (when (get-buffer drgnx-explorer-buffer-name) (kill-buffer drgnx-explorer-buffer-name))
      (delete-directory dir t))))

(provide 'wb-buffers-edge-test)
;;; wb-buffers-edge-test.el ends here
