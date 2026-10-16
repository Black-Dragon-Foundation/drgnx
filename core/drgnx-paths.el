;;; drgnx-paths.el --- Where drgnx lives and keeps its files -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The checkout is read-only code; user configuration lives in `drgnx-user-dir', state and
;; caches in XDG directories — never inside the checkout (docs/core.md).

;;; Code:
(defconst drgnx-dir
  (file-name-directory (directory-file-name (file-name-directory (or load-file-name buffer-file-name))))
  "The drgnx checkout.")

(defun drgnx-user-dir ()
  "The user's drgnx configuration: $DRGNX_CONFIG_DIR, else ~/.config/drgnx/."
  (file-name-as-directory (expand-file-name (or (getenv "DRGNX_CONFIG_DIR") "~/.config/drgnx"))))

(defun drgnx-state-dir ()
  "drgnx state: $XDG_STATE_HOME/drgnx/ (default ~/.local/state/drgnx/)."
  (file-name-as-directory (expand-file-name "drgnx" (or (getenv "XDG_STATE_HOME") "~/.local/state"))))

(defun drgnx-cache-dir ()
  "drgnx caches: $XDG_CACHE_HOME/drgnx/ (default ~/.cache/drgnx/)."
  (file-name-as-directory (expand-file-name "drgnx" (or (getenv "XDG_CACHE_HOME") "~/.cache"))))

(provide 'drgnx-paths)
;;; drgnx-paths.el ends here
