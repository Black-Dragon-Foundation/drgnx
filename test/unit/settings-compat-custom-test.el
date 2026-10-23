;;; settings-compat-custom-test.el --- design §15's rows C4 and C20: what writes custom.el -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Rows C4 and C20 (unified-settings Task 30), each in a child Emacs under a temp HOME (test/settings-child.el), with
;; drgnx's `custom-file' (custom.el in the config dir, as init/early-init.el sets it) and `user-init-file' standing
;; for the checkout's init/init.el.  Customize, package.el, the local-variables `!' answer and disable-command write
;; custom.el; settings.el and the checkout stay as they were; no root goes into `safe-local-variable-directories'.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/settings-child" drgnx-dir) nil t)

(defconst drgnx-settings-compat-custom--settings "(drgnx-settings :version 1\n (sat-cu-w 5))\n"
  "The rows' settings.el: one entry.")

(defconst drgnx-settings-compat-custom--init ";;; init.el --- the checkout's -*- lexical-binding: t -*-\n"
  "The rows' stand-in for the checkout's init/init.el.")

(defconst drgnx-settings-compat-custom--start
  '((progn (setq custom-file (expand-file-name "custom.el" (drgnx-user-dir))
                 user-init-file (expand-file-name "~/checkout/init/init.el")
                 after-init-time (or after-init-time (current-time)))
           (defcustom sat-cu-w 0 "A width." :type 'integer :group 'emacs)
           (drgnx-settings-apply-global)
           t))
  "drgnx's start for the rows: its custom-file, the checkout's init.el, settings.el applied.")

(defun drgnx-settings-compat-custom--run (forms)
  "FORMS' values in a child after the rows' start, with settings.el, an empty custom.el and the checkout's init.el."
  (let ((r (drgnx-settings-test-child
            (append drgnx-settings-compat-custom--start forms)
            :files `(("settings.el" . ,drgnx-settings-compat-custom--settings)
                     ("custom.el" . ";;; custom.el -*- lexical-binding: t -*-\n")
                     ("~/checkout/init/init.el" . ,drgnx-settings-compat-custom--init)))))
    (should (equal (plist-get r :error) nil))
    (nthcdr (length drgnx-settings-compat-custom--start) (plist-get r :values))))

(ert-deftest drgnx-settings-compat/c4-customize-save-writes-custom-el ()
  ;; Customize's Save (`customize-save-variable', what the Save button calls) over settings.el's 5.
  (pcase-let ((`(,before ,row ,source ,custom ,settings)
               (drgnx-settings-compat-custom--run
                '(sat-cu-w
                  (progn (customize-save-variable 'sat-cu-w 9)
                         (drgnx-settings-test-check-row 'sat-cu-w :value 9 :state 'saved))
                  (plist-get (drgnx-settings-explain 'sat-cu-w) :source)
                  (drgnx-file-read-bounded custom-file)
                  (drgnx-file-read-bounded (expand-file-name "settings.el" (drgnx-user-dir)))))))
    (should (equal before 5))
    (should (eq row t))
    (should (string-prefix-p "Customize" source))
    (should (string-match-p "^ '(sat-cu-w 9))$" custom))
    (should (equal settings drgnx-settings-compat-custom--settings))))

(ert-deftest drgnx-settings-compat/c20-package-install-the-bang-answer-and-disable-command-write-custom-el ()
  (pcase-let ((`(,custom ,init ,settings ,dirs)
               (drgnx-settings-compat-custom--run
                '((progn (require 'package)
                         (package--save-selected-packages '(sat-pkg-b sat-pkg-a))  ; what package-install calls
                         ;; the local-variables `!' answer (files.el, `hack-local-variables-confirm')
                         (customize-push-and-save 'safe-local-variable-values '((sat-cu-local . 1)))
                         (defun sat-cu-cmd () (interactive) t)
                         (disable-command 'sat-cu-cmd)
                         (drgnx-file-read-bounded custom-file))
                  (drgnx-file-read-bounded user-init-file)
                  (drgnx-file-read-bounded (expand-file-name "settings.el" (drgnx-user-dir)))
                  safe-local-variable-directories))))
    (should (string-match-p "^ '(package-selected-packages '(sat-pkg-a sat-pkg-b))$" custom))
    (should (string-match-p "^ '(safe-local-variable-values '((sat-cu-local \\. 1)))" custom))
    (should (string-match-p "^(put 'sat-cu-cmd 'disabled t)$" custom))
    (should (equal init drgnx-settings-compat-custom--init))
    (should (equal settings drgnx-settings-compat-custom--settings))
    (should-not dirs)))

(provide 'settings-compat-custom-test)
;;; settings-compat-custom-test.el ends here
