;;; drgnx-format.el --- Module extra/format: format on save (apheleia) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Saving formats the buffer with its language's formatter (black, prettier, gofmt, rustfmt, … — apheleia's list)
;; when that formatter is installed: in the background, never blocking the save, keeping the point where it was.  A
;; missing or failing formatter leaves the file as you saved it.  See docs/guide/editing.md.

;;; Code:
(require 'drgnx-modules)
(require 'drgnx-registry)
(declare-function apheleia-global-mode "apheleia")
(declare-function apheleia-mode "apheleia")
(defvar apheleia-mode)
(defvar apheleia-global-mode)
(defvar apheleia-log-only-errors)

(defun drgnx-format-toggle (&optional everywhere)
  "Turn format on save off or on in this buffer — or, with a prefix argument (EVERYWHERE), in every buffer."
  (interactive "P")
  (if everywhere
      (progn (apheleia-global-mode (if apheleia-global-mode -1 1))
             (message "Format on save: %s everywhere" (if apheleia-global-mode "on" "off")))
    (apheleia-mode (if apheleia-mode -1 1))
    (message "Format on save: %s in this buffer" (if apheleia-mode "on" "off"))))

(drgnx-module-define 'extra/format
                     :doc "Format on save with the language's formatter when it is installed (apheleia): in the background, never blocking."
                     :stage 'idle :packages '(apheleia)
                     :setup (lambda ()
                              (require 'apheleia)
                              (setq apheleia-log-only-errors t)
                              (apheleia-global-mode 1)
                              (drgnx-command-define 'format-on-save :category "Code" :title "Toggle Format on Save"
                                                    :command #'drgnx-format-toggle
                                                    :doc "This buffer (with a prefix: every buffer)")))

(provide 'drgnx-format)
;;; drgnx-format.el ends here
