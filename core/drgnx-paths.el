;;; drgnx-paths.el --- Where drgnx lives and keeps its files -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The checkout is read-only code; user configuration lives in `drgnx-user-dir', state and
;; caches in XDG directories — never inside the checkout (docs/develop/core.md).

;;; Code:
(defconst drgnx-dir
  (file-name-directory (directory-file-name (file-name-directory (or load-file-name buffer-file-name))))
  "The drgnx checkout.")

(defun drgnx-platform ()
  "The platform drgnx runs on: `macos', else `linux' (the BSDs and others count as Linux)."
  (if (eq system-type 'darwin) 'macos 'linux))

(defun drgnx-user-dir ()
  "The user's drgnx configuration: $DRGNX_CONFIG_DIR, else ~/.config/drgnx/.  An empty variable counts as unset, as
in bin/drgnx and install.sh (\"${VAR:-…}\"), so all three pick the same dir."
  (let ((dir (getenv "DRGNX_CONFIG_DIR")))
    (file-name-as-directory (expand-file-name (if (member dir '(nil "")) "~/.config/drgnx" dir)))))

(defun drgnx-state-dir ()
  "drgnx state: $XDG_STATE_HOME/drgnx/ (default ~/.local/state/drgnx/)."
  (file-name-as-directory (expand-file-name "drgnx" (or (getenv "XDG_STATE_HOME") "~/.local/state"))))

(defun drgnx-cache-dir ()
  "drgnx caches: $XDG_CACHE_HOME/drgnx/ (default ~/.cache/drgnx/)."
  (file-name-as-directory (expand-file-name "drgnx" (or (getenv "XDG_CACHE_HOME") "~/.cache"))))

(defun drgnx-data-dir ()
  "drgnx data: $DRGNX_DATA_DIR, else $XDG_DATA_HOME/drgnx/ (default ~/.local/share/drgnx/)."
  (file-name-as-directory
   (expand-file-name (or (getenv "DRGNX_DATA_DIR")
                         (expand-file-name "drgnx" (or (getenv "XDG_DATA_HOME") "~/.local/share"))))))

(defun drgnx-elpa-dir ()
  "The packages every session uses — a fixed real path (generations are copied into it)."
  (file-name-as-directory (expand-file-name "elpa" (drgnx-data-dir))))

(defun drgnx-generations-dir ()
  "Snapshots of the packages directory, one per sync or upgrade."
  (file-name-as-directory (expand-file-name "generations" (drgnx-data-dir))))

(defun drgnx-package-cache-dir ()
  "Every package file drgnx downloaded (for offline syncs): cache/packages/."
  (file-name-as-directory (expand-file-name "packages" (drgnx-cache-dir))))

(defun drgnx-command-ignoring-sigpipe (command)
  "COMMAND (a list: program and arguments) run so that SIGPIPE is ignored: through `sh -c \"trap '' PIPE; exec …\"'.
A write to a pipe whose reader left is then an error in the child, not its end.  Emacs resets SIGPIPE for the
processes it starts, and so does libuv in an agent's children.  Unchanged on Windows (no sh there)."
  (if (eq system-type 'windows-nt) command
    (append (list "sh" "-c" "trap '' PIPE; exec \"$0\" \"$@\"") command)))

(provide 'drgnx-paths)
;;; drgnx-paths.el ends here
