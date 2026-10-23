;;; drgnx-settings-prov.el --- Settings: provenance (who set this) and drgnx-settings-explain -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A skeleton for unified-settings Task 11: which form of your Lisp set a variable, recorded while it loads,
;; watchers on managed variables, and `drgnx-settings-explain' over every layer.  `drgnx--load-user-config'
;; wraps its load in `drgnx-settings-prov-with-load' (docs/develop/settings.md, "The start-up order").  Until
;; Task 11 the macro is BODY alone.

;;; Code:

(defmacro drgnx-settings-prov-with-load (file &rest body)
  "Run BODY, which loads FILE (your Lisp), recording who sets which variable while it runs.
A stub: it expands to BODY alone (FILE is not evaluated)."
  (declare (indent 1) (debug (form body)))
  (ignore file)
  `(progn ,@body))

(provide 'drgnx-settings-prov)
;;; drgnx-settings-prov.el ends here
