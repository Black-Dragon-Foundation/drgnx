;;; drgnx-hooks.el --- Staged hooks: first input, first file, first GUI frame -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Work that need not happen at startup hangs on a stage and runs once, when that stage is
;; first reached.  Each function runs under its own error guard; failures are notices of
;; source `hooks' (`drgnx-notify'), never shown as prompts.

;;; Code:
(require 'drgnx-frame-kind)

(defvar drgnx-first-input-hook nil "Run once, before the first command the user gives.")
(defvar drgnx-first-file-hook nil "Run once, when the first file is visited.")
(defvar drgnx-first-gui-frame-hook nil "Run once, when the first graphical frame exists.")

(defvar drgnx-hooks--done nil "Staged hooks that have run.")
(defvar drgnx-hooks-problems nil
  "Errors the terminal modules (`modules/ui/drgnx-tty-*') catch in their own hooks (newest first).
Staged-hook errors are notices of source `hooks' instead.")

(declare-function drgnx-notify "drgnx-notice" (source severity text &rest args))

(defun drgnx-hooks--problem (hook fn err)
  "Say that FN, on staged HOOK, signalled ERR: a `warn' event of source `hooks' (the model loads at the first error).
Never signals."
  (let ((text (format "%s: %s: %s" hook fn (error-message-string err))))
    (condition-case failed
        (progn (require 'drgnx-notice)
               (drgnx-notify 'hooks 'warn text :id (cons hook fn)))
      (error (message "drgnx: %s (not recorded: %s)" text (error-message-string failed))))))

(defun drgnx-hooks-run-once (hook)
  "Run HOOK's functions once; isolate and record errors."
  (unless (memq hook drgnx-hooks--done)
    (push hook drgnx-hooks--done)
    (dolist (fn (and (boundp hook) (ensure-list (default-value hook))))
      (unless (eq fn t)
        (condition-case err
            (funcall fn)
          (error (drgnx-hooks--problem hook fn err)))))))

(defun drgnx-hooks--first-input ()
  (remove-hook 'pre-command-hook #'drgnx-hooks--first-input)
  (drgnx-hooks-run-once 'drgnx-first-input-hook))

(defun drgnx-hooks--first-file ()
  (remove-hook 'find-file-hook #'drgnx-hooks--first-file)
  (drgnx-hooks-run-once 'drgnx-first-file-hook))

(defun drgnx-hooks--gui-frame (&optional frame)
  (when (eq (drgnx-state-frame-kind (or frame (selected-frame))) 'gui)
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
