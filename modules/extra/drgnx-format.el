;;; drgnx-format.el --- Module extra/format: format on save (apheleia) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Saving formats the buffer with its language's formatter (black, prettier, gofmt, rustfmt, … — apheleia's list)
;; when that formatter is installed: in the background, never blocking the save, keeping the point where it was.  A
;; missing or failing formatter leaves the file as you saved it.  See docs/guide/editing.md.

;;; Code:
(require 'seq)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-packs)
(declare-function apheleia-global-mode "apheleia")
(declare-function apheleia-mode "apheleia")
(defvar apheleia-mode)
(defvar apheleia-global-mode)
(defvar apheleia-log-only-errors)
(defvar apheleia-mode-alist)
(defvar apheleia-inhibit-functions)

(defun drgnx-format--configured-p ()
  "Does this file's project say it formats its code?"
  (and buffer-file-name
       (let ((dir (file-name-directory buffer-file-name)))
         (or (seq-some (lambda (f) (locate-dominating-file dir f)) (drgnx-packs-format-config-files))
             (when-let* ((root (locate-dominating-file dir "pyproject.toml")))
               (with-temp-buffer
                 (insert-file-contents (expand-file-name "pyproject.toml" root))
                 (re-search-forward "^\\[tool\\.\\(?:black\\|ruff\\)" nil t)))))))

(defun drgnx-format--inhibit-p ()
  "`apheleia-inhibit-functions': no format on save here — not a standard-formatter language, and the project has no
formatter of its own (prettier, clang-format, black… would reformat code its authors never ran them on)."
  (not (or (apply #'derived-mode-p (drgnx-packs-format-modes)) (drgnx-format--configured-p))))

(defun drgnx-format--setup ()
  (require 'apheleia)
  (drgnx-module-set 'apheleia-log-only-errors t)
  ;; formatters that need no program re-indent every Lisp and BibTeX file saved: never
  (drgnx-module-set 'apheleia-mode-alist
                    (seq-remove (lambda (e) (memq (cdr e) '(lisp-indent bibtex))) apheleia-mode-alist))
  (add-hook 'apheleia-inhibit-functions #'drgnx-format--inhibit-p)
  (apheleia-global-mode 1))

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
                              (drgnx-format--setup)
                              (drgnx-command-define 'format-on-save :category "Code" :title "Toggle Format on Save"
                                                    :command #'drgnx-format-toggle
                                                    :doc "This buffer (with a prefix: every buffer)")))

(provide 'drgnx-format)
;;; drgnx-format.el ends here
