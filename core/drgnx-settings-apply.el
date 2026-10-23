;;; drgnx-settings-apply.el --- Settings: the applier (theme drgnx, the winner rule) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A skeleton for unified-settings Task 8: settings.el applied through theme `drgnx' after the packages are
;; active and before custom.el — pushed only where drgnx's layer is Emacs's winner, stored in place otherwise —
;; and per-variable teardown.  `drgnx-init' calls `drgnx-settings-apply-global' (in safe mode with :owned-only)
;; (docs/develop/settings.md, "The start-up order").  Until Task 8 it does nothing.

;;; Code:
(require 'cl-lib)

(cl-defun drgnx-settings-apply-global (&key owned-only)
  "Apply settings.el's global entries; with OWNED-ONLY, only drgnx's own settings (safe mode).
Called at start after the packages are activated and before custom.el loads.  A stub: it does nothing yet."
  (ignore owned-only))

(provide 'drgnx-settings-apply)
;;; drgnx-settings-apply.el ends here
