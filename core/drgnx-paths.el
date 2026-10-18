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

(defun drgnx-paths--expand (name &optional dir)
  "`expand-file-name' of NAME in DIR, with `default-directory' \"/\" so that \"~\" is the local home.
In a remote buffer a \"~\" would otherwise be expanded on the remote host, and Tramp would connect to it
from timers, hooks and persistence."
  (let ((default-directory "/"))
    (expand-file-name name dir)))

(defun drgnx-user-dir ()
  "The user's drgnx configuration: $DRGNX_CONFIG_DIR, else ~/.config/drgnx/."
  (file-name-as-directory (drgnx-paths--expand (or (getenv "DRGNX_CONFIG_DIR") "~/.config/drgnx"))))

(defun drgnx-paths--xdg (var default)
  "The XDG base directory in the environment variable VAR, else DEFAULT.  Only an absolute path counts: the XDG spec
says an empty or relative value is to be ignored (else it would mean the current directory), as bin/drgnx's xdg_dir."
  (let ((dir (getenv var)))
    (if (and dir (file-name-absolute-p dir) (not (string-prefix-p "~" dir))) dir default)))

(defun drgnx-state-dir ()
  "drgnx state: $XDG_STATE_HOME/drgnx/ (default ~/.local/state/drgnx/)."
  (file-name-as-directory (drgnx-paths--expand "drgnx" (drgnx-paths--xdg "XDG_STATE_HOME" "~/.local/state"))))

(defun drgnx-cache-dir ()
  "drgnx caches: $XDG_CACHE_HOME/drgnx/ (default ~/.cache/drgnx/)."
  (file-name-as-directory (drgnx-paths--expand "drgnx" (drgnx-paths--xdg "XDG_CACHE_HOME" "~/.cache"))))

(defun drgnx-data-dir ()
  "drgnx data: $DRGNX_DATA_DIR, else $XDG_DATA_HOME/drgnx/ (default ~/.local/share/drgnx/)."
  (file-name-as-directory
   (drgnx-paths--expand (or (getenv "DRGNX_DATA_DIR")
                            (drgnx-paths--expand "drgnx" (drgnx-paths--xdg "XDG_DATA_HOME" "~/.local/share"))))))

(defun drgnx-elpa-dir ()
  "The packages every session uses — a fixed real path (generations are copied into it)."
  (file-name-as-directory (drgnx-paths--expand "elpa" (drgnx-data-dir))))

(defun drgnx-generations-dir ()
  "Snapshots of the packages directory, one per sync or upgrade."
  (file-name-as-directory (drgnx-paths--expand "generations" (drgnx-data-dir))))

(defun drgnx-package-cache-dir ()
  "Every package file drgnx downloaded (for offline syncs): cache/packages/."
  (file-name-as-directory (drgnx-paths--expand "packages" (drgnx-cache-dir))))

(defun drgnx-command-ignoring-sigpipe (command)
  "COMMAND (a list: program and arguments) run so that SIGPIPE is ignored: through `sh -c \"trap '' PIPE; exec …\"'.
A write to a pipe whose reader left is then an error in the child, not its end.  Emacs resets SIGPIPE for the
processes it starts, and so does libuv in an agent's children.  Unchanged on Windows (no sh there)."
  (if (eq system-type 'windows-nt) command
    (append (list "sh" "-c" "trap '' PIPE; exec \"$0\" \"$@\"") command)))

(provide 'drgnx-paths)
;;; drgnx-paths.el ends here
