;;; settings-doc-test.el --- batch tests: the generated reference of drgnx's settings -*- lexical-binding: t -*-
;; The reference is generated in a child `emacs --batch -Q' by the command docs/develop/core.md gives, so this
;; process's own declarations never reach it.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(add-to-list 'load-path (expand-file-name "harness" drgnx-dir))
(require 'drgnx-settings-doc)

(defun drgnx-settings-doc-test--command ()
  "The command docs/develop/core.md gives for regenerating the settings reference, on one line."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix)) (insert-file-contents (expand-file-name "docs/develop/core.md" drgnx-dir)))
    (goto-char (point-min))
    (unless (re-search-forward "^```sh\n\\(emacs --batch [^`]*drgnx-settings-doc[^`]*\\)```" nil t)
      (ert-fail "docs/develop/core.md does not give the command that regenerates the settings reference"))
    (string-trim (replace-regexp-in-string "\\\\\n[ \t]*" "" (match-string 1)))))

(defun drgnx-settings-doc-test--read (file)
  "The text of FILE."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix)) (insert-file-contents file))
    (buffer-string)))

(ert-deftest drgnx-settings-doc/the-reference-is-current ()
  (let* ((tmp (make-temp-file "drgnx-settings-doc" nil ".md"))
         (home (make-temp-file "drgnx-settings-doc-home" t))
         (documented (drgnx-settings-doc-test--command))
         (command (replace-regexp-in-string "docs/reference/settings\\.md" tmp documented t t))
         (emacs (shell-quote-argument (drgnx-emacs-program)))
         (default-directory drgnx-dir)
         (process-environment
          (append (list (concat "HOME=" home) (concat "XDG_CONFIG_HOME=" home "/config")
                        (concat "XDG_STATE_HOME=" home "/state") (concat "XDG_DATA_HOME=" home "/data")
                        (concat "XDG_CACHE_HOME=" home "/cache"))
                  process-environment)))
    (should (string-search tmp command))
    (unwind-protect
        (progn
          (should (eql 0 (call-process "sh" nil nil nil "-c"
                                       (replace-regexp-in-string "\\`emacs --batch -Q"
                                                                 (concat emacs " --batch -Q --eval '(setq load-prefer-newer t)'")
                                                                 command t t))))
          (unless (equal (drgnx-settings-doc-test--read tmp)
                         (drgnx-settings-doc-test--read (expand-file-name "docs/reference/settings.md" drgnx-dir)))
            (ert-fail (format "docs/reference/settings.md is out of date; regenerate it with:\n  %s" documented))))
      (delete-file tmp)
      (delete-directory home t))))

(ert-deftest drgnx-settings-doc/the-markdown-describes-a-setting ()
  (require 'drgnx-setting)
  (unwind-protect
      (progn
        (eval '(drgnx-defsetting drgnx-settings-doc-test-a 7 "The first test setting."
                 :type 'integer :scope 'global :workspace 'safe)
              t)
        (let ((text (drgnx-settings-doc-markdown)))
          (should (string-prefix-p "# Settings\n" text))
          (should (string-suffix-p "\n" text))
          (should (string-match-p "^## drgnx-settings-doc-test-a\n\nThe first test setting\\.\n\n" text))
          (should (string-match-p "| Default | `7` |" text))
          (should (string-match-p "| `:scope` | `global` |" text))
          (should (string-match-p "| `:workspace` | `safe` |" text))
          (should (string-match-p "| `:apply` | - |" text))))
    (makunbound 'drgnx-settings-doc-test-a)
    (setplist 'drgnx-settings-doc-test-a nil)
    (setq drgnx-setting--names (delq 'drgnx-settings-doc-test-a drgnx-setting--names))))
