;;; tty-chrome-test.el --- batch tests: the chrome reads the terminal frame's breadcrumb parameter -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-chrome)

(defmacro tty-chrome-test--with (&rest body)
  "BODY with chrome on and one editor window showing a file buffer."
  (declare (indent 0))
  `(let ((dir (file-name-as-directory (make-temp-file "drgnx-tty-chrome" t)))
         (display-buffer-alist nil))
     (delete-other-windows)
     (set-window-parameter (selected-window) 'drgnx-tabs nil)
     (set-window-prev-buffers (selected-window) nil)
     (drgnx-rules-mode 1)
     (drgnx-chrome-mode 1)
     (unwind-protect
         (progn
           (let ((f (expand-file-name "a.txt" dir)))
             (write-region "x\n" nil f nil 'silent)
             (switch-to-buffer (find-file-noselect f)))
           ,@body)
       (set-frame-parameter nil 'drgnx-chrome-breadcrumb nil)
       (drgnx-chrome-mode -1)
       (drgnx-rules-mode -1)
       (delete-other-windows)
       (dolist (b (buffer-list))
         (when (and (buffer-file-name b) (string-prefix-p dir (buffer-file-name b)))
           (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))
       (delete-directory dir t))))

(ert-deftest drgnx-chrome/no-breadcrumb-when-the-frame-says-so ()
  (tty-chrome-test--with
    (drgnx-chrome-apply nil t)
    (should (stringp (window-parameter (selected-window) 'header-line-format)))   ; the breadcrumb
    ;; a short terminal frame: no header row for the breadcrumb (the tab line and the mode line stay)
    (set-frame-parameter nil 'drgnx-chrome-breadcrumb 'off)
    (drgnx-chrome-apply nil t)
    (should (eq (window-parameter (selected-window) 'header-line-format) 'none))
    (should (stringp (window-parameter (selected-window) 'tab-line-format)))
    (should (window-parameter (selected-window) 'mode-line-format))
    ;; sticky scroll's scopes are part of that row
    (setq-local drgnx-chrome-header-tail '(:eval " › (defun f ()"))
    (drgnx-chrome-apply nil t)
    (should (eq (window-parameter (selected-window) 'header-line-format) 'none))
    (kill-local-variable 'drgnx-chrome-header-tail)
    ;; a buffer that has a header of its own (column headings) keeps it
    (setq-local header-line-format "Name  Size")
    (drgnx-chrome-apply nil t)
    (should (equal (window-parameter (selected-window) 'header-line-format) drgnx-chrome--own-header))
    (kill-local-variable 'header-line-format)
    ;; room again: the breadcrumb is back
    (set-frame-parameter nil 'drgnx-chrome-breadcrumb nil)
    (drgnx-chrome-apply nil t)
    (should (stringp (window-parameter (selected-window) 'header-line-format)))))

(provide 'tty-chrome-test)
;;; tty-chrome-test.el ends here
