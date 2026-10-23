;;; drgnx-settings-migrate.el --- Settings: the move from the old files into settings.el -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A skeleton for unified-settings Task 14: the one-time migration of the old settings files into settings.el,
;; and the shim in `drgnx-config-get'.  `drgnx-init' calls `drgnx-settings-migrate-maybe' first, also in safe
;; mode (docs/develop/settings.md, "The start-up order").  Until Task 14 it does nothing.

;;; Code:

(defun drgnx-settings-migrate-maybe ()
  "Move the old settings files into settings.el, once: only while settings.el does not exist.
Called first at every start, also in safe mode.  A stub: it does nothing yet."
  nil)

(provide 'drgnx-settings-migrate)
;;; drgnx-settings-migrate.el ends here
