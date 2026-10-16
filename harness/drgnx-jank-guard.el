;;; drgnx-jank-guard.el --- Record window-moving calls made from timers -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:
(defvar drgnx-jank-guard-log nil
  "Recorded violations, newest first: plists (:time :fn :window :timer).")

(defvar drgnx-jank-guard--timer-fn nil
  "Function of the timer running now (dynamically bound), or nil.")

(defun drgnx-jank-guard-enable ()
  "Start recording window-moving calls made from timers.")

(provide 'drgnx-jank-guard)
;;; drgnx-jank-guard.el ends here
