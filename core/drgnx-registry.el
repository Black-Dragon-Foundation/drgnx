;;; drgnx-registry.el --- One registry for every drgnx command -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Each command is registered once — title, category, key, menu path, right-click contexts,
;; documentation, availability — and `drgnx-surfaces' generates every surface from that:
;; keybindings, the menu bar, context menus, which-key labels, the palette, the F1 sheet,
;; the markdown cheat sheet and "next time" tips.  Ported from the gryphn layer's registry
;; (same entries), with `:when'.  See docs/core.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(cl-defstruct (drgnx-cmd (:constructor drgnx-cmd--make) (:copier nil))
  id title category command key map menu context context-first doc native when)

(defvar drgnx-commands--table (make-hash-table :test #'eq) "ID → `drgnx-cmd'.")
(defvar drgnx-commands--order nil "IDs in first-definition order.")
(defvar drgnx-commands-problems nil "Messages about entries that could not be applied.")

(defun drgnx-commands--keymap-spec (map)
  "MAP as (FEATURE . KEYMAP-SYMBOL); FEATURE nil means the keymap exists now."
  (cond ((null map) (cons nil 'global-map))
        ((symbolp map) (cons nil map))
        (t map)))

(defun drgnx-commands--bind (cmd)
  "Bind CMD's key in its keymap, now or once the keymap's feature loads."
  (pcase-let ((`(,feature . ,mapsym) (drgnx-commands--keymap-spec (drgnx-cmd-map cmd))))
    (let ((apply
           (lambda ()
             (condition-case err
                 (keymap-set (symbol-value mapsym) (drgnx-cmd-key cmd) (drgnx-cmd-command cmd))
               (error (push (format "%s: cannot bind %s in %s: %s" (drgnx-cmd-id cmd)
                                    (drgnx-cmd-key cmd) mapsym (error-message-string err))
                            drgnx-commands-problems))))))
      (if feature (with-eval-after-load feature (funcall apply)) (funcall apply)))))

(cl-defun drgnx-command-define (id &key title category command key map menu context context-first doc native when)
  "Register command ID (a symbol) and bind its KEY.  Returns ID.
TITLE and CATEGORY are required; COMMAND is required unless NATIVE.  MAP: nil (global), a
keymap symbol, or (FEATURE . KEYMAP-SYMBOL).  MENU: menu-bar path, e.g. (\"View\").
CONTEXT: symbol or list of right-click contexts (`drgnx-surfaces-define-context');
CONTEXT-FIRST puts the item at the top of the context menu.  NATIVE: an Emacs key that is
documented on every surface but never rebound.  WHEN: a predicate; the command is offered
only while it returns non-nil."
  (unless (and title category) (error "drgnx-command-define %s: :title and :category are required" id))
  (unless (or native command) (error "drgnx-command-define %s: :command is required" id))
  (let ((cmd (drgnx-cmd--make :id id :title title :category category :command command :key key
                              :map map :menu menu :context (ensure-list context)
                              :context-first context-first :doc doc :native native :when when)))
    (unless (gethash id drgnx-commands--table)
      (setq drgnx-commands--order (append drgnx-commands--order (list id))))
    (puthash id cmd drgnx-commands--table)
    (when (and key (not native)) (drgnx-commands--bind cmd))
    id))

(defun drgnx-commands-all ()
  "Every registered command, in first-definition order."
  (mapcar (lambda (id) (gethash id drgnx-commands--table)) drgnx-commands--order))

(defun drgnx-commands-get (id) (gethash id drgnx-commands--table))

(defun drgnx-commands-label (cmd)
  (format "%s: %s" (drgnx-cmd-category cmd) (drgnx-cmd-title cmd)))

(defun drgnx-commands-available-p (cmd)
  "Non-nil if CMD can run now: its `:when' holds, and it is native, a keymap, a lambda, or a
command whose library exists."
  (and (or (null (drgnx-cmd-when cmd)) (ignore-errors (funcall (drgnx-cmd-when cmd))))
       (or (drgnx-cmd-native cmd)
           (let ((c (drgnx-cmd-command cmd)))
             (cond ((keymapp c) t)
                   ((functionp c) (if (and (symbolp c) (autoloadp (symbol-function c)))
                                      (and (locate-library (cadr (symbol-function c))) t)
                                    (commandp c)))
                   (t nil))))))

(defun drgnx-commands-conflicts ()
  "Entries claiming the same key in the same keymap: list of (KEYMAP-SYMBOL KEY ID…)."
  (let ((seen (make-hash-table :test #'equal)) out)
    (dolist (c (drgnx-commands-all))
      (when (and (drgnx-cmd-key c) (not (drgnx-cmd-native c)))
        (push (drgnx-cmd-id c)
              (gethash (list (cdr (drgnx-commands--keymap-spec (drgnx-cmd-map c))) (drgnx-cmd-key c)) seen))))
    (maphash (lambda (k ids) (when (cdr ids) (push (append k (reverse ids)) out))) seen)
    out))

(provide 'drgnx-registry)
;;; drgnx-registry.el ends here
