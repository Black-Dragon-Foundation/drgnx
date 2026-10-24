;;; drgnx-settings-defaults.el --- Settings: the shipped runtime defaults, and saving a runtime setting -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Unified-settings Task 15 (design §5.4, §11.1; docs/develop/settings.md, "Agents, AI and the shipped defaults").
;; - `drgnx-settings-defaults-value' reads <checkout>/settings/runtime-defaults.el as data (never `load'ed), once per
;;   file stamp: the three constants of drgnx-ai.el and drgnx-agents.el take their values from it, and so does the
;;   strict default of each `:on-error strict' setting.
;; - `drgnx-settings-defaults-save' writes one setting's entry to settings.el and applies it at once.  A settings.el
;;   with a mistake is never replaced: `drgnx-settings-refused' (a `user-error') says so.
;; Nothing here prompts.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-file)
(require 'drgnx-config)
(require 'drgnx-settings-file)

(declare-function drgnx-settings-live-sync "drgnx-settings-live" (file))

(defconst drgnx-settings-defaults-file (expand-file-name "settings/runtime-defaults.el" drgnx-dir)
  "The shipped defaults: a settings file of head `drgnx-settings', in the checkout.")

(defvar drgnx-settings-defaults--cache nil
  "(STAMP . ((VAR . VALUE)…)): the shipped defaults as last read.  One entry; replaced when the file's stamp changes.")

(defun drgnx-settings-defaults-all ()
  "The shipped defaults as ((VAR . VALUE)…), in file order.  Signals an `error' when the file does not read."
  (let ((stamp (drgnx-file-stamp drgnx-settings-defaults-file)))
    (unless (and drgnx-settings-defaults--cache (equal (car drgnx-settings-defaults--cache) stamp))
      (let ((doc (drgnx-settings-file-read drgnx-settings-defaults-file 'drgnx-settings)))
        (when (or (drgnx-settings-doc-failed doc) (null (drgnx-settings-doc-text doc)) (drgnx-settings-doc-problems doc))
          (error "drgnx: %s does not read: %s" drgnx-settings-defaults-file
                 (or (plist-get (car (drgnx-settings-doc-problems doc)) :text) "it is missing")))
        (setq drgnx-settings-defaults--cache
              (cons stamp (mapcar (lambda (e) (cons (drgnx-settings-entry-var e) (drgnx-settings-entry-value e)))
                                  (drgnx-settings-doc-entries doc))))))
    (cdr drgnx-settings-defaults--cache)))

(defun drgnx-settings-defaults-value (var)
  "VAR's shipped default value.  An `error' when the defaults file has no entry for VAR."
  (let ((cell (assq var (drgnx-settings-defaults-all))))
    (unless cell (error "drgnx: %s has no entry for %s" drgnx-settings-defaults-file var))
    (cdr cell)))

(declare-function drgnx-settings-apply-global "drgnx-settings-apply" (&rest args))

(defun drgnx-settings-defaults-apply ()
  "In a batch entry point (a CLI, the hub), which loads no init: apply drgnx's own entries of settings.el, so the
agents' profiles and routes and the AI providers and roles are the user's.  Never signals; nil when it failed."
  (condition-case err
      (when (and (require 'drgnx-settings-apply nil t)
                 (require 'drgnx-agents nil t)    ; their settings are declared once loaded
                 (require 'drgnx-ai nil t))
        (drgnx-settings-apply-global :owned-only t)
        t)
    (error (message "drgnx: settings.el was not applied: %s" (error-message-string err)) nil)))

(defun drgnx-settings-defaults-save (var value)
  "Set VAR to VALUE in the user's settings.el and apply it at once; VALUE.
Only that entry changes (comments and the rest stay).  A settings.el with a mistake, or a value that is not data,
is a `drgnx-settings-refused' and nothing is written."
  (let ((file (drgnx-config-file 'settings))
        (drgnx-settings-file-tool "default:settings"))
    (drgnx-settings-file-put file 'drgnx-settings nil var value)
    (when (or (featurep 'drgnx-settings-live) (require 'drgnx-settings-live nil t))
      (drgnx-settings-live-sync file))
    value))

(provide 'drgnx-settings-defaults)
;;; drgnx-settings-defaults.el ends here
