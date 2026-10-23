;;; drgnx-settings-live.el --- Settings: changes apply at once; the end-of-init pass -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A skeleton for unified-settings Task 13: the end-of-init `:apply' pass, and the watches that apply a changed
;; settings file at once.  `drgnx-init' calls `drgnx-settings-apply-pass', then `drgnx-settings-live-start',
;; after your Lisp files (docs/develop/settings.md, "The start-up order").  Until Task 13 both do nothing.

;;; Code:

(defun drgnx-settings-apply-pass ()
  "Run `:apply' for every own setting whose value changed while Emacs started (the end-of-init pass).
A stub: it does nothing yet."
  nil)

(defun drgnx-settings-live-start ()
  "Start watching the settings files, so a change applies at once.  A stub: it does nothing yet."
  nil)

(provide 'drgnx-settings-live)
;;; drgnx-settings-live.el ends here
