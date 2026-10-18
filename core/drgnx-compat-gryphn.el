;;; drgnx-compat-gryphn.el --- Load gryphn's feature files as an external module -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; gryphn (the configuration drgnx grew out of) defines its commands with `gryphn-command-define'
;; and its right-click contexts with `gryphn-surfaces-define-context'.  This shim provides both on
;; top of drgnx's registry and surfaces, so gryphn's board, run, agents and search files load
;; unchanged as an external module (modules.eld :external, docs/guide/modules.md): their commands are in
;; the palette and menus, and their keys join the key profiles.

;;; Code:
(require 'cl-lib)
(require 'drgnx-registry)
(require 'drgnx-surfaces)
(require 'drgnx-keys)

(cl-defun gryphn-command-define (id &key title category command key map menu context context-first doc native)
  "gryphn's command definition, in drgnx's registry; KEY joins every key profile: the VS Code and Emacs
profiles bind it, the Vim profile leaves it to the palette (no profile may forget a command).
NATIVE commands (Emacs keys gryphn only documents) are skipped."
  (unless native
    (drgnx-command-define id :title title :category category :command command :map map :menu menu
                          :context context :context-first context-first :doc doc)
    (when key
      (dolist (profile '(vscode emacs))
        (drgnx-keys-define profile (list (if map (list id key :map map) (list id key)))))
      (drgnx-keys-define 'vim (list (list id :none "the palette")))))
  id)

(defun gryphn-surfaces-define-context (context predicate)
  "gryphn's right-click context, as a drgnx one."
  (drgnx-surfaces-define-context context predicate))

(provide 'gryphn-commands)
(provide 'gryphn-surfaces)
(provide 'drgnx-compat-gryphn)
;;; drgnx-compat-gryphn.el ends here
