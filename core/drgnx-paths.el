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

(defun drgnx-paths-env-dir (var)
  "The value of the environment variable VAR when it begins with \"/\", else nil.  Unset, empty, relative and \"~/…\"
values all mean \"the default\" (the XDG spec ignores a relative one, else it would mean the current directory).
bin/drgnx-paths.sh's xdg_dir has the same rule."
  (let ((v (getenv var)))
    (and v (string-prefix-p "/" v) v)))

(defconst drgnx-paths--kinds
  '((config "DRGNX_CONFIG_DIR" "XDG_CONFIG_HOME" "~/.config")
    (state nil "XDG_STATE_HOME" "~/.local/state")
    (cache nil "XDG_CACHE_HOME" "~/.cache")
    (data "DRGNX_DATA_DIR" "XDG_DATA_HOME" "~/.local/share"))
  "KIND → (drgnx's own variable, the XDG variable, the XDG default) of `drgnx-paths-dir'.")

(defun drgnx-paths-config-moved-p ()
  "Where the config dir belongs ($XDG_CONFIG_HOME/drgnx/) while the old ~/.config/drgnx/ is used instead, else nil.
That is when DRGNX_CONFIG_DIR is unset, $XDG_CONFIG_HOME/drgnx is missing and ~/.config/drgnx is a directory: an install
from before XDG_CONFIG_HOME counted keeps working, and the doctor says to move it."
  (let ((default-directory "/") (file-name-handler-alist nil))
    (when-let* (((not (drgnx-paths-env-dir "DRGNX_CONFIG_DIR")))
                (xdg (drgnx-paths-env-dir "XDG_CONFIG_HOME"))
                (new (file-name-as-directory (expand-file-name "drgnx" xdg)))
                (old (file-name-as-directory (expand-file-name "~/.config/drgnx"))))
      (and (not (equal new old)) (not (file-directory-p new)) (file-directory-p old) new))))

(defun drgnx-paths-dir (kind)
  "Where drgnx keeps files of KIND (`config', `state', `cache' or `data'): a directory name ending in \"/\".
config: $DRGNX_CONFIG_DIR, else $XDG_CONFIG_HOME/drgnx, else ~/.config/drgnx (also while `drgnx-paths-config-moved-p');
state: $XDG_STATE_HOME/drgnx, else ~/.local/state/drgnx; cache: $XDG_CACHE_HOME/drgnx, else ~/.cache/drgnx;
data: $DRGNX_DATA_DIR, else $XDG_DATA_HOME/drgnx, else ~/.local/share/drgnx.  Only absolute values count
\(`drgnx-paths-env-dir').  Never remote: `default-directory' is \"/\" and no file name handler runs, so a remote buffer
never makes Tramp connect.  Nothing is memoized; bin/drgnx-paths.sh's drgnx_dir is the same rule in bash."
  (pcase-let ((`(,own ,xdg ,base) (or (alist-get kind drgnx-paths--kinds) (error "drgnx: no path kind %S" kind))))
    (let ((default-directory "/") (file-name-handler-alist nil))
      (file-name-as-directory
       (expand-file-name
        (or (and own (drgnx-paths-env-dir own))
            (and (eq kind 'config) (drgnx-paths-config-moved-p) "~/.config/drgnx")
            (expand-file-name "drgnx" (or (drgnx-paths-env-dir xdg) base))))))))

(declare-function drgnx-file-read-bounded "drgnx-file")

(defun drgnx-emacs-program ()
  "The Emacs that is running: the one to start as a subprocess.  Never the bare name `emacs': a machine with only
Nidhogg has none on PATH.  bash uses `$(emacs_bin)' / $DRGNX_EMACS."
  (expand-file-name invocation-name invocation-directory))

(defun drgnx-paths-recorded-emacs ()
  "The Emacs install.sh recorded: the first line of `emacs' in the data dir, else in the config dir (where older installs
wrote it), trimmed, when it is an absolute name of an executable regular file; else nil.  Never evaluated, never
prompts.  bin/drgnx's emacs_bin has the same rule."
  (require 'drgnx-file (expand-file-name "core/drgnx-file" drgnx-dir))   ; by file: the harness loads this alone
  (catch 'found
    (dolist (kind '(data config))
      (let* ((file (expand-file-name "emacs" (drgnx-paths-dir kind)))
             (text (condition-case nil (drgnx-file-read-bounded file :max-bytes 4096) (error nil)))
             (line (and text (string-trim (car (split-string text "\n"))))))
        (when (and line (string-prefix-p "/" line))
          (let ((default-directory "/") (file-name-handler-alist nil))
            (when (and (file-regular-p line) (file-executable-p line))
              (throw 'found line))))))
    nil))

(defun drgnx-paths-ignored ()
  "The path variables of `drgnx-paths-dir' set to a value that does not count (neither empty nor absolute):
a list of (VAR VALUE DIR), DIR being the folder drgnx uses instead.  The doctor's `config-dir' check names them."
  (let (out)
    (pcase-dolist (`(,kind . ,vars) drgnx-paths--kinds)
      (dolist (var (delq nil (list (car vars) (cadr vars))))
        (let ((v (getenv var)))
          (when (and v (not (equal v "")) (not (drgnx-paths-env-dir var)))
            (push (list var v (drgnx-paths-dir kind)) out)))))
    (nreverse out)))

(defun drgnx-user-dir ()
  "The user's drgnx configuration: (drgnx-paths-dir \\='config)."
  (drgnx-paths-dir 'config))

(defun drgnx-state-dir ()
  "drgnx state: (drgnx-paths-dir \\='state)."
  (drgnx-paths-dir 'state))

(defun drgnx-cache-dir ()
  "drgnx caches: (drgnx-paths-dir \\='cache)."
  (drgnx-paths-dir 'cache))

(defun drgnx-data-dir ()
  "drgnx data: (drgnx-paths-dir \\='data)."
  (drgnx-paths-dir 'data))

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
