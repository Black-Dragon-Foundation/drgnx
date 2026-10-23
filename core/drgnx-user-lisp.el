;;; drgnx-user-lisp.el --- Settings: your Lisp files (on/off, early files, bisect) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A skeleton for unified-settings Task 29: the Lisp files listed in `drgnx-user-lisp-files' (settings.el),
;; loaded after config.el, and the `:early t' ones, loaded by early-init.el.  early-init.el loads this file by
;; its path, before anything else of drgnx's but drgnx-paths, so it may only load what it needs the same way
;; (docs/develop/settings.md, "The start-up order").  Until Task 29 both functions do nothing.

;;; Code:

(defun drgnx-user-lisp-load-all ()
  "Load your Lisp files that are on, after config.el; never in safe mode.  A stub: it does nothing yet."
  nil)

(defun drgnx-user-lisp-load-early ()
  "Load your `:early t' Lisp files, from early-init.el; never in safe mode.  A stub: it does nothing yet."
  nil)

(provide 'drgnx-user-lisp)
;;; drgnx-user-lisp.el ends here
