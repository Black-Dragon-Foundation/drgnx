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
(require 'seq)
(require 'drgnx-registry)
(require 'drgnx-surfaces)
(require 'drgnx-keys)

(defun drgnx-compat-gryphn--key= (a b)
  (or (equal a b) (equal (ignore-errors (key-parse a)) (ignore-errors (key-parse b)))))

(defun drgnx-compat-gryphn--takes-p (profile id key)
  "Whether PROFILE's :bind already has an entry for ID or binds KEY (a shipped entry is never replaced)."
  (seq-some (lambda (e)
              (or (eq (car e) id)
                  (seq-some (lambda (k) (and (stringp k) (drgnx-compat-gryphn--key= k key)))
                            (seq-take-while (lambda (x) (not (keywordp x))) (cdr e)))))
            (plist-get (alist-get profile drgnx-keys-profiles) :bind)))

(cl-defun gryphn-command-define (id &key title category command key map menu context context-first doc native)
  "gryphn's command definition, in drgnx's registry; KEY joins the key profiles: VS Code and Emacs bind it, the
Vim profile leaves it to the palette.  A profile that has an entry for ID, or binds KEY already, keeps its own
(shipped keys are never replaced); the Emacs profile also keeps Emacs' own key (gryphn's C-p, C-b).
NATIVE commands (Emacs keys gryphn only documents) are skipped."
  (unless native
    (drgnx-command-define id :title title :category category :command command :map map :menu menu
                          :context context :context-first context-first :doc doc)
    (when key
      (drgnx-keys--ensure-profiles)
      (dolist (profile '(vscode emacs))
        (unless (or (drgnx-compat-gryphn--takes-p profile id key)
                    (and (eq profile 'emacs) (not map)
                         (commandp (ignore-errors (lookup-key drgnx-keys--defaults (key-parse key))))))
          (drgnx-keys-define profile (list (if map (list id key :map map) (list id key))))))
      (unless (assq id (plist-get (alist-get 'vim drgnx-keys-profiles) :bind))
        (drgnx-keys-define 'vim (list (list id :none "the palette"))))))
  id)

(defun gryphn-surfaces-define-context (context predicate)
  "gryphn's right-click context, as a drgnx one."
  (drgnx-surfaces-define-context context predicate))

(provide 'gryphn-commands)
(provide 'gryphn-surfaces)
(provide 'drgnx-compat-gryphn)
;;; drgnx-compat-gryphn.el ends here
