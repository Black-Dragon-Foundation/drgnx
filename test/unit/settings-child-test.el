;;; settings-child-test.el --- the settings rows' child Emacs -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/settings-child" drgnx-dir) nil t)

(ert-deftest drgnx-settings-child/a-child-has-a-temp-home ()
  ;; The child's user-emacs-directory, HOME and config dir are under its temp root, its :files land there, and ~
  ;; (the runner's HOME) is never touched.
  (let* ((home (file-name-as-directory (file-truename "~")))
         (before (and (file-directory-p home) (directory-files-recursively home "" t)))
         (r (drgnx-settings-test-child
             '((file-truename user-emacs-directory) (file-truename (getenv "HOME")) (file-truename (drgnx-user-dir))
               (file-truename "~")
               (with-temp-buffer (insert-file-contents (expand-file-name "settings.el" (drgnx-user-dir)))
                                 (buffer-string))
               (with-temp-buffer (insert-file-contents "~/probe.el") (buffer-string))
               (progn (make-directory user-emacs-directory t)
                      (write-region "x" nil (locate-user-emacs-file "probe") nil 'silent)
                      (featurep 'drgnx)))
             :files '(("settings.el" . "(drgnx-settings :version 1)\n") ("~/probe.el" . "probe\n"))))
         (root (plist-get r :root)))
    (should-not (plist-get r :error))
    (should (equal (plist-get r :exit) 0))
    (pcase-let ((`(,ued ,env-home ,config ,tilde ,settings ,probe ,loaded) (plist-get r :values)))
      (dolist (dir (list ued env-home config tilde))
        (should (string-prefix-p root dir))
        (should-not (string-prefix-p home dir)))
      (should (equal env-home tilde))
      (should (equal settings "(drgnx-settings :version 1)\n"))
      (should (equal probe "probe\n"))
      (should (eq loaded t)))
    (should-not (file-exists-p root))                      ; removed on return
    (should (equal (and (file-directory-p home) (directory-files-recursively home "" t)) before))))
