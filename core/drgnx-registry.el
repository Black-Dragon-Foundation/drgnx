;;; drgnx-registry.el --- One registry for every drgnx command -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Each command is registered once — title, category, scope, menu path, right-click contexts,
;; documentation, availability — and `drgnx-surfaces' generates every surface from that: the
;; menu bar, context menus, which-key labels, the palette, the key sheet, the markdown cheat
;; sheet and "next time" tips.  Commands carry no keys: key profiles bind them
;; (`drgnx-keys', docs/guide/keys.md) and record the active keys in each command's `bound' slot.
;; Ported from the gryphn layer's registry (same ids), with `:when'.  See docs/develop/core.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(cl-defstruct (drgnx-cmd (:constructor drgnx-cmd--make) (:copier nil))
  id title category command map menu context context-first doc when scope
  (bound nil :documentation "Active keys, a list of (KEY . MAP-SPEC); set by `drgnx-keys'."))

(defvar drgnx-commands--table (make-hash-table :test #'eq) "ID → `drgnx-cmd'.")
(defvar drgnx-commands--order nil "IDs in first-definition order.")
(defvar drgnx-commands-problems nil "Messages about entries that could not be applied.")

(defconst drgnx-command-scopes '(app editing window)
  "Scopes a command can belong to; a key-profile layer applies to some of them (docs/guide/keys.md).")

(defun drgnx-commands--keymap-spec (map)
  "MAP as (FEATURE . KEYMAP-SYMBOL); FEATURE nil means the keymap exists now."
  (cond ((null map) (cons nil 'global-map))
        ((symbolp map) (cons nil map))
        (t map)))

(cl-defun drgnx-command-define (id &key title category command map menu context context-first doc when scope
                                      (key nil key-p) (native nil native-p))
  "Register command ID (a symbol).  Returns ID.
TITLE, CATEGORY and COMMAND are required.  MAP: the keymap its keys belong in by default — nil
(global), a keymap symbol, or (FEATURE . KEYMAP-SYMBOL).  MENU: menu-bar path, e.g.
(\"View\").  CONTEXT: symbol or list of right-click contexts (`drgnx-surfaces-define-context');
CONTEXT-FIRST puts the item at the top of the context menu.  WHEN: a predicate; the command is
offered only while it returns non-nil.  SCOPE: `app' (default), `editing' or `window' — which
key-profile layers key it.  Keys are not given here: profiles bind them (docs/guide/keys.md)."
  (ignore key native)
  (when (or key-p native-p)
    (error "drgnx-command-define %s: keys come from key profiles now (keys/*.eld, docs/guide/keys.md), not :key/:native" id))
  (unless (and title category) (error "drgnx-command-define %s: :title and :category are required" id))
  (unless command (error "drgnx-command-define %s: :command is required" id))
  (unless (memq (or scope 'app) drgnx-command-scopes)
    (error "drgnx-command-define %s: :scope must be one of %s" id drgnx-command-scopes))
  (let* ((old (gethash id drgnx-commands--table))
         (cmd (drgnx-cmd--make :id id :title title :category category :command command
                               :map map :menu menu :context (ensure-list context)
                               :context-first context-first :doc doc :when when :scope (or scope 'app)
                               :bound (and old (drgnx-cmd-bound old)))))
    (unless old
      (setq drgnx-commands--order (append drgnx-commands--order (list id))))
    (puthash id cmd drgnx-commands--table)
    id))

(defun drgnx-commands-all ()
  "Every registered command, in first-definition order."
  (mapcar (lambda (id) (gethash id drgnx-commands--table)) drgnx-commands--order))

(defun drgnx-commands-get (id) (gethash id drgnx-commands--table))

(defun drgnx-commands-label (cmd)
  (format "%s: %s" (drgnx-cmd-category cmd) (drgnx-cmd-title cmd)))

(defun drgnx-commands-available-p (cmd)
  "Non-nil if CMD can run now: its `:when' holds, and it is a keymap, a lambda, or a command
whose library exists."
  (and (or (null (drgnx-cmd-when cmd)) (ignore-errors (funcall (drgnx-cmd-when cmd))))
       (let ((c (drgnx-cmd-command cmd)))
         (cond ((keymapp c) t)
               ((functionp c) (if (and (symbolp c) (autoloadp (symbol-function c)))
                                  (and (locate-library (cadr (symbol-function c))) t)
                                (commandp c)))
               (t nil)))))

(provide 'drgnx-registry)
;;; drgnx-registry.el ends here
