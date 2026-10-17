;;; drgnx-compat-gryphn.el --- Load gryphn's feature files as an external module -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; gryphn (the configuration drgnx grew out of) defines its commands with `gryphn-command-define'
;; and its right-click contexts with `gryphn-surfaces-define-context'.  This shim provides both on
;; top of drgnx's registry and surfaces, so gryphn's board, run, agents and search files load
;; unchanged as an external module (modules.eld :external, docs/guide/modules.md): their commands are in
;; the palette and menus, and their keys join the VS Code key profile.

;;; Code:
(require 'cl-lib)
(require 'drgnx-registry)
(require 'drgnx-surfaces)
(require 'drgnx-keys)

(cl-defun gryphn-command-define (id &key title category command key map menu context context-first doc native)
  "gryphn's command definition, in drgnx's registry; KEY joins the VS Code key profile.
NATIVE commands (Emacs keys gryphn only documents) are skipped."
  (unless native
    (drgnx-command-define id :title title :category category :command command :map map :menu menu
                          :context context :context-first context-first :doc doc)
    (when key (drgnx-keys-define 'vscode (list (if map (list id key :map map) (list id key))))))
  id)

(defun gryphn-surfaces-define-context (context predicate)
  "gryphn's right-click context, as a drgnx one."
  (drgnx-surfaces-define-context context predicate))

(provide 'gryphn-commands)
(provide 'gryphn-surfaces)
(provide 'drgnx-compat-gryphn)
;;; drgnx-compat-gryphn.el ends here
