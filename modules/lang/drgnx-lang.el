;;; drgnx-lang.el --- Module lang/eglot: language servers, tree-sitter, code navigation -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Code buffers get a language server (eglot) when the server for their mode is installed — never a
;; question about which server to run — and the tree-sitter mode when its grammar is installed.
;; Go to Definition, Find References, Rename Symbol and Show Hover work with or without a server
;; (xref and eldoc fall back on what the mode knows).  See docs/guide/modules.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-modules)
(require 'drgnx-registry)
(defvar eglot-server-programs)
(defvar xref-prompt-for-identifier)
(declare-function eglot-ensure "eglot")
(declare-function eglot-rename "eglot")
(declare-function eglot-current-server "eglot")
(declare-function eglot-code-actions "eglot")
(declare-function eglot-format-buffer "eglot")
(declare-function eldoc-doc-buffer "eldoc")

(defconst drgnx-lang-tree-sitter-modes
  '((python python-mode python-ts-mode) (javascript js-mode js-ts-mode) (json js-json-mode json-ts-mode)
    (css css-mode css-ts-mode) (bash sh-mode bash-ts-mode) (c c-mode c-ts-mode) (cpp c++-mode c++-ts-mode)
    (java java-mode java-ts-mode) (ruby ruby-mode ruby-ts-mode) (yaml yaml-mode yaml-ts-mode)
    (rust rust-mode rust-ts-mode) (go go-mode go-ts-mode) (typescript typescript-mode typescript-ts-mode))
  "LANGUAGE MODE TS-MODE: MODE becomes TS-MODE when LANGUAGE's grammar is installed.")

(defvar eglot-sync-connect)

(defun drgnx-lang-remap-modes ()
  "Use the tree-sitter mode of every language whose grammar is installed."
  (when (fboundp 'treesit-language-available-p)
    (pcase-dolist (`(,lang ,mode ,ts) drgnx-lang-tree-sitter-modes)
      (when (and (treesit-language-available-p lang) (fboundp ts))
        (setf (alist-get mode major-mode-remap-alist) ts)))))

(defun drgnx-lang--program (contact)
  "The program CONTACT (an `eglot-server-programs' value) runs, or nil.  A function (such as
`eglot-alternatives') is asked non-interactively; one that would prompt or fails counts as none."
  (pcase contact
    (`(,(and prog (pred stringp)) . ,_) prog)
    ((pred stringp) contact)
    ((pred functionp)
     (let ((inhibit-interaction t))
       (drgnx-lang--program (ignore-errors (if (eql (cdr (func-arity contact)) 1) (funcall contact nil)
                                             (funcall contact nil nil))))))))

(defun drgnx-lang-server-available-p ()
  "Non-nil if a language server for the current major mode is installed (on `exec-path')."
  (require 'eglot)
  (seq-some (lambda (entry)
              (let ((modes (ensure-list (car entry))))
                (and (seq-some (lambda (m) (derived-mode-p (if (consp m) (car m) m))) modes)
                     (when-let* ((prog (drgnx-lang--program (cdr entry)))) (executable-find prog)))))
            eglot-server-programs))

(defun drgnx-lang--maybe-eglot ()
  "In a file's code buffer: start eglot when the server is installed (never asks)."
  (when (and buffer-file-name (not (file-remote-p buffer-file-name)) (drgnx-lang-server-available-p))
    (eglot-ensure)))

(defun drgnx-lang-rename ()
  "Rename the symbol at point everywhere (a language server is needed)."
  (interactive)
  (if (and (fboundp 'eglot-current-server) (eglot-current-server)) (call-interactively #'eglot-rename)
    (user-error "Rename Symbol needs a language server for this file (none is installed)")))

(defun drgnx-lang--server-p () (and (fboundp 'eglot-current-server) (eglot-current-server)))

(defun drgnx-lang-quick-fix ()
  "The language server's fixes and actions here."
  (interactive)
  (unless (drgnx-lang--server-p) (user-error "Quick Fix needs a language server for this file (none is installed)"))
  (call-interactively #'eglot-code-actions))

(defun drgnx-lang-format ()
  "Format the buffer with the language server; without one, re-indent it."
  (interactive)
  (if (drgnx-lang--server-p) (call-interactively #'eglot-format-buffer)
    (indent-region (point-min) (point-max))))

(defun drgnx-lang-hover ()
  "Show the documentation of the symbol at point (in the panel's Help tab)."
  (interactive)
  (eldoc-doc-buffer t))

(drgnx-module-define 'lang/eglot
                     :doc "Language servers when installed, tree-sitter modes when the grammar is, definitions, references, rename, hover."
                     :stage 'startup
                     :setup
                     (lambda ()
                       (drgnx-lang-remap-modes)
                       (add-hook 'prog-mode-hook #'drgnx-lang--maybe-eglot)
                       (setq xref-prompt-for-identifier nil
                             eglot-sync-connect nil)                ; a slow server never blocks opening the file
                       (pcase-dolist (`(,id ,title ,fn ,doc)
                                      '((code-definition "Go to Definition" xref-find-definitions "Jump to where the symbol is defined")
                                        (code-references "Find References" xref-find-references "Every use of the symbol (in the panel)")
                                        (code-rename "Rename Symbol" drgnx-lang-rename "Rename the symbol everywhere (language server)")
                                        (code-hover "Show Hover" drgnx-lang-hover "The symbol's documentation, in the panel")
                                        (code-quick-fix "Quick Fix" drgnx-lang-quick-fix "The language server's fixes and actions here")
                                        (code-problems "Problems" flymake-show-project-diagnostics "Errors and warnings of the project (in the panel)")
                                        (code-format "Format Document" drgnx-lang-format "Format with the language server (else re-indent)")))
                         (drgnx-command-define id :category "Code" :title title :command fn :scope 'editing :doc doc))))

(provide 'drgnx-lang)
;;; drgnx-lang.el ends here
