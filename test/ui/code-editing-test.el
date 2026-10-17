;;; code-editing-test.el --- GUI tests: sticky scroll, indent guides, smooth scrolling on a graphical frame (run by `drgnx test --ui') -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-uitest)

(defconst drgnx-code-ui-test--repo                          ; the session runs the repository's test/ui
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(add-to-list 'load-path (expand-file-name "core" drgnx-code-ui-test--repo))
(dolist (m '("editor/drgnx-sticky" "ui/drgnx-smooth" "extra/drgnx-guides"))
  (load (expand-file-name (concat "modules/" m) drgnx-code-ui-test--repo) nil t))

(defconst drgnx-code-ui-test--elpa (expand-file-name (or (getenv "DRGNX_USER_ELPA") "~/.config/emacs/elpa")))

(ert-deftest drgnx-ui-code/sticky-guides-smooth ()
  (let* ((root (drgnx-uitest-root-frame)) (dir (make-temp-file "drgnx-code-shot" t))
         (file (expand-file-name "core/drgnx-job.el" drgnx-code-ui-test--repo))
         (guides (and (file-directory-p drgnx-code-ui-test--elpa)
                      (car (directory-files drgnx-code-ui-test--elpa t "\\`indent-bars-[0-9]"))))
         (buf nil))
    (unwind-protect
        (with-selected-frame root
          (when guides (add-to-list 'load-path guides))
          (delete-other-windows)
          (setq buf (find-file-noselect file))
          (switch-to-buffer buf)
          (drgnx-sticky-mode 1)
          (when guides (require 'indent-bars) (drgnx-guides--maybe))
          (drgnx-smooth--setup)
          ;; into a long function: its first line has scrolled off
          (goto-char (point-min))
          (re-search-forward "^(defun drgnx-job-step ")
          (forward-line 12)
          (set-window-start (selected-window) (line-beginning-position))
          (redisplay t) (sit-for 0.3)
          (should (string-search "(defun drgnx-job-step" (drgnx-sticky--segment (selected-window))))
          (should (or (bound-and-true-p ultra-scroll-mode) (bound-and-true-p pixel-scroll-precision-mode)))
          (when guides (should (bound-and-true-p indent-bars-mode)))
          (let ((shot (plist-get (drgnx-uitest-capture dir) :root)))
            (should (file-exists-p shot))
            (copy-file shot (expand-file-name "code-editing.png" temporary-file-directory) t)
            (message "code editing screenshot: %s" (expand-file-name "code-editing.png" temporary-file-directory))))
      (when (buffer-live-p buf) (kill-buffer buf))
      (when (bound-and-true-p pixel-scroll-precision-mode) (pixel-scroll-precision-mode -1))
      (delete-directory dir t))))

;;; code-editing-test.el ends here
