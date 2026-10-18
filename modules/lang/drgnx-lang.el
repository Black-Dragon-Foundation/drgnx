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
(defvar drgnx-grammars-modes)
;; The language/mode table is lang/grammars's: one table for both modules (its file sits beside this one).
(unless (featurep 'drgnx-grammars)
  (load (expand-file-name "drgnx-grammars" (file-name-directory (or load-file-name buffer-file-name))) nil t))
(defvar eglot-server-programs)
(defvar xref-prompt-for-identifier)
(declare-function eglot-ensure "eglot")
(declare-function eglot-rename "eglot")
(declare-function eglot-current-server "eglot")
(declare-function eglot-code-actions "eglot")
(declare-function eglot-format-buffer "eglot")
(declare-function eldoc-doc-buffer "eldoc")

(defvar eglot-sync-connect)
(defvar eglot-autoshutdown)

(defun drgnx-lang-remap-modes ()
  "Use the tree-sitter mode of every language whose grammar is installed."
  (when (fboundp 'treesit-language-available-p)
    (pcase-dolist (`(,lang ,mode ,ts . ,_) drgnx-grammars-modes)
      (when (and mode (treesit-language-available-p lang) (fboundp ts))
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

;;;; Language servers on a remote host
;; Nothing here reaches a remote by itself.  `drgnx-lang-probe-remote' runs only from the user's commands (Open
;; Remote…, Reconnect); the hook below reads what it found, and starts eglot only on a connection that is up.

(declare-function tramp-dissect-file-name "tramp")
(declare-function tramp-get-connection-process "tramp")

(defvar drgnx-lang--remote-servers (make-hash-table :test #'equal)
  "Connection (\"/ssh:HOST:\") → what `drgnx-lang-probe-remote' found there: ((MODES . PROGRAM-or-nil)…).")
(defvar drgnx-lang--remote-wanted (make-hash-table :test #'equal)
  "Connection → ((MODES . NAME)…): the program each entry looks for, found or not (the hint names it).")
(defvar drgnx-lang--remote-hinted nil "(CONNECTION . MODE) of the hints already given (one each).")

(defun drgnx-lang--wanted (contact)
  "The program CONTACT looks for, found or not; for `eglot-alternatives' the first alternative it tries."
  (let ((asked nil))
    (cl-letf (((symbol-function 'executable-find) (lambda (name &rest _) (push name asked) nil)))
      (or (drgnx-lang--program contact) (car (last asked))))))

(defun drgnx-lang-probe-remote (root)
  "Look up, on the host of the remote folder ROOT, the program of every `eglot-server-programs' entry (TRAMP
keeps `executable-find' answers per connection); remember the result for that connection and return it:
((MODES . PROGRAM-or-nil)…).  This may open the connection, so it is only for the user's commands."
  (require 'eglot)
  (let* ((default-directory root) (key (file-remote-p root)) (asked (make-hash-table :test #'equal)) result wanted)
    (dolist (entry eglot-server-programs)
      (let* ((contact (cdr entry)) (prog (drgnx-lang--program contact))
             (found (and prog (or (functionp contact)          ; a function looked on the host itself
                                  (with-memoization (gethash prog asked) (and (executable-find prog t) t))))))
        (push (cons (car entry) (and found prog)) result)
        (push (cons (car entry) (or prog (drgnx-lang--wanted contact))) wanted)))
    (puthash key (nreverse result) drgnx-lang--remote-servers)
    (puthash key (nreverse wanted) drgnx-lang--remote-wanted)
    (gethash key drgnx-lang--remote-servers)))

(defun drgnx-lang--remote-live-p (file)
  "Is the connection of the remote FILE up?  Asks the process table only."
  (and (featurep 'tramp)
       (ignore-errors (process-live-p (tramp-get-connection-process (tramp-dissect-file-name file))))))

(defun drgnx-lang--maybe-eglot-remote (file)
  "The code buffer of the remote FILE: eglot when the probe found a server there and the connection is up; a
one-time hint when the probe found none; nothing when the connection was never probed."
  (when-let* ((key (file-remote-p file))
              (result (gethash key drgnx-lang--remote-servers))
              (entries (seq-filter (lambda (e) (seq-some (lambda (m) (derived-mode-p (if (consp m) (car m) m)))
                                                         (ensure-list (car e))))
                                   result)))
    (cond ((seq-some #'cdr entries) (when (drgnx-lang--remote-live-p file) (eglot-ensure)))
          ((not (member (cons key major-mode) drgnx-lang--remote-hinted))
           (push (cons key major-mode) drgnx-lang--remote-hinted)
           (message "No language server for %s on %s: install %s there" major-mode (file-remote-p file 'host)
                    (or (alist-get (car (car entries)) (gethash key drgnx-lang--remote-wanted) nil nil #'equal)
                        "one"))))))

(defun drgnx-lang--maybe-eglot ()
  "In a file's code buffer: start eglot when the server is installed (never asks) — unless DRGNX_NO_LANGUAGE_SERVERS
is set non-empty (headless test sessions).  A remote file only looks at what Open Remote… or Reconnect found."
  (when (and buffer-file-name (member (getenv "DRGNX_NO_LANGUAGE_SERVERS") '(nil "")))
    (if (file-remote-p buffer-file-name)
        (drgnx-lang--maybe-eglot-remote buffer-file-name)
      (when (drgnx-lang-server-available-p) (eglot-ensure)))))

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
                             eglot-sync-connect nil                 ; a slow server never blocks opening the file
                             eglot-autoshutdown t)                  ; a server goes with its project's last buffer
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
