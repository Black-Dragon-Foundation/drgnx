;;; drgnx-terminal.el --- Module tools/terminal: terminals in the panel -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; New Terminal opens your own shell in a real terminal (eat, module tools/terminal-eat) in the
;; panel's Terminal tab and focuses it; for a remote folder, on Windows, and until eat is installed
;; it is eshell instead (New Eshell asks for eshell anywhere).  Open Terminal Here does so in the
;; folder of the Explorer row.  The terminal's environment names this Emacs's server (EDITOR,
;; GIT_EDITOR, DRGNX_SERVER_NAME), so `git commit' and `drgnx' reach the Emacs hosting the terminal.
;; See docs/guide/modules.md.

;;; Code:
(require 'server)
(require 'drgnx-modules)
(require 'drgnx-registry)
(defvar eshell-buffer-name)
(declare-function drgnx-explorer-node-at "drgnx-explorer")
(declare-function drgnx-terminal-eat-start "drgnx-terminal-eat")

(defconst drgnx-terminal-eat-missing-notice
  "New Terminal: eat is not installed yet, so this is eshell — run drgnx sync (docs/guide/shell.md)"
  "Said once per session when New Terminal falls back to eshell because eat is missing.")

(defvar drgnx-terminal--notice-shown nil "Non-nil once `drgnx-terminal-eat-missing-notice' was said.")

(defun drgnx-terminal-shell ()
  "The user's shell: $SHELL when it names an executable file, else `shell-file-name'."
  (let ((shell (getenv "SHELL")))
    (if (and (stringp shell) (not (string-empty-p shell)) (file-executable-p shell) (not (file-directory-p shell)))
        shell
      shell-file-name)))

(defun drgnx-terminal-server-socket ()
  "The absolute socket of this Emacs's live server, or nil when it has none."
  (when (process-live-p server-process)
    (expand-file-name server-name (if server-use-tcp server-auth-dir server-socket-dir))))

(defun drgnx-terminal--emacsclient ()
  "The emacsclient of this Emacs: beside it (Emacs.app: in bin/), else the one on PATH's name."
  (or (seq-some (lambda (dir)
                  (seq-some (lambda (rel)
                              (let ((f (expand-file-name rel dir)))
                                (and (file-executable-p f) (not (file-directory-p f)) f)))
                            '("emacsclient" "bin/emacsclient")))
                (delete-dups (list invocation-directory (file-truename invocation-directory))))
      "emacsclient"))

(defun drgnx-terminal-environment ()
  "Environment entries that make a terminal's editor and `drgnx' reach this Emacs, or nil without a live server."
  (when-let* ((sock (drgnx-terminal-server-socket)))
    (let ((editor (format "%s -s %s" (shell-quote-argument (drgnx-terminal--emacsclient)) (shell-quote-argument sock))))
      (list (concat "DRGNX_SERVER_NAME=" sock)
            (concat "EDITOR=" editor)
            (concat "VISUAL=" editor)
            (concat "GIT_EDITOR=" editor)))))

(defun drgnx-terminal-eat-usable-p (dir)
  "Non-nil when a terminal in DIR can be eat: not on Windows, DIR not remote, module tools/terminal-eat has run."
  (and (not (eq system-type 'windows-nt))
       (not (file-remote-p dir))
       (fboundp 'drgnx-terminal-eat-start)
       (drgnx-modules--ok-p 'tools/terminal-eat)))

(defun drgnx-terminal-new-eshell (&optional dir)
  "A new eshell in DIR (default: here), in the panel; returns its buffer."
  (interactive)
  (require 'eshell)
  (let ((default-directory (file-name-as-directory (expand-file-name (or dir default-directory))))
        (eshell-buffer-name (generate-new-buffer-name "*eshell*")))
    (save-window-excursion (eshell))          ; made here, shown by the rules (the panel)
    (let ((b (get-buffer eshell-buffer-name)))
      (pop-to-buffer b)
      b)))

(defun drgnx-terminal-new (&optional dir)
  "A new terminal in DIR (default: here), in the panel; returns its buffer.
Your shell in eat; eshell for a remote folder, on Windows, and (with a notice, once) while eat is not installed."
  (interactive)
  (let ((dir (or dir default-directory)))
    (if (drgnx-terminal-eat-usable-p dir)
        (drgnx-terminal-eat-start dir)
      (unless (or (file-remote-p dir) (eq system-type 'windows-nt) drgnx-terminal--notice-shown)
        (setq drgnx-terminal--notice-shown t)
        (message "%s" drgnx-terminal-eat-missing-notice))
      (drgnx-terminal-new-eshell dir))))

(defun drgnx-terminal-here ()
  "A new terminal in the folder of the Explorer row (or of this file)."
  (interactive)
  (let ((path (and (fboundp 'drgnx-explorer-node-at) (derived-mode-p 'drgnx-explorer-mode) (drgnx-explorer-node-at (point)))))
    (drgnx-terminal-new (if (and path (file-directory-p path)) path
                          (if path (file-name-directory path) default-directory)))))

(drgnx-module-define 'tools/terminal
                     :doc "New Terminal (your shell in eat), New Eshell and Open Terminal Here, in the panel."
                     :stage 'startup
                     :setup
                     (lambda ()
                       (drgnx-command-define 'terminal-new :category "Terminal" :title "New Terminal" :scope 'window
                                             :command #'drgnx-terminal-new :doc "A new terminal in the panel")
                       (drgnx-command-define 'terminal-new-eshell :category "Terminal" :title "New Eshell" :scope 'window
                                             :command #'drgnx-terminal-new-eshell :doc "A new eshell in the panel")
                       (drgnx-command-define 'explorer-terminal-here :category "Terminal" :title "Open Terminal Here" :scope 'window
                                             :command #'drgnx-terminal-here :context 'explorer :doc "A new terminal in this folder")))

(provide 'drgnx-terminal)
;;; drgnx-terminal.el ends here
