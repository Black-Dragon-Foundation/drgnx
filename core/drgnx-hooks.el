;;; drgnx-hooks.el --- Staged hooks: first input, first file, first GUI frame -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Work that need not happen at startup hangs on a stage and runs once, when that stage is
;; first reached.  Each function runs under its own error guard; failures are collected in
;; `drgnx-hooks-problems', never shown as prompts.

;;; Code:
(defvar drgnx-first-input-hook nil "Run once, before the first command the user gives.")
(defvar drgnx-first-file-hook nil "Run once, when the first file is visited.")
(defvar drgnx-first-gui-frame-hook nil "Run once, when the first graphical frame exists.")

(defvar drgnx-hooks--done nil "Staged hooks that have run.")
(defvar drgnx-hooks-problems nil "Errors raised by staged-hook functions (newest first).")

(defun drgnx-hooks-run-once (hook)
  "Run HOOK's functions once; isolate and record errors."
  (unless (memq hook drgnx-hooks--done)
    (push hook drgnx-hooks--done)
    (dolist (fn (and (boundp hook) (ensure-list (default-value hook))))
      (unless (eq fn t)
        (condition-case err
            (funcall fn)
          (error (push (format "%s: %s: %s" hook fn (error-message-string err)) drgnx-hooks-problems)))))))

(defun drgnx-hooks--first-input ()
  (remove-hook 'pre-command-hook #'drgnx-hooks--first-input)
  (drgnx-hooks-run-once 'drgnx-first-input-hook))

(defun drgnx-hooks--first-file ()
  (remove-hook 'find-file-hook #'drgnx-hooks--first-file)
  (drgnx-hooks-run-once 'drgnx-first-file-hook))

(defun drgnx-hooks--gui-frame (&optional frame)
  (when (display-graphic-p frame)
    (drgnx-hooks-run-once 'drgnx-first-gui-frame-hook)))

(defun drgnx-hooks-install ()
  "Arm the staged hooks."
  (add-hook 'pre-command-hook #'drgnx-hooks--first-input)
  (add-hook 'find-file-hook #'drgnx-hooks--first-file)
  (add-hook 'after-make-frame-functions #'drgnx-hooks--gui-frame)
  (add-hook 'window-setup-hook #'drgnx-hooks--gui-frame))

(defun drgnx-hooks-uninstall ()
  (remove-hook 'pre-command-hook #'drgnx-hooks--first-input)
  (remove-hook 'find-file-hook #'drgnx-hooks--first-file)
  (remove-hook 'after-make-frame-functions #'drgnx-hooks--gui-frame)
  (remove-hook 'window-setup-hook #'drgnx-hooks--gui-frame))

(provide 'drgnx-hooks)
;;; drgnx-hooks.el ends here
