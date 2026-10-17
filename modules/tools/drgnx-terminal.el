;;; drgnx-terminal.el --- Module tools/terminal: terminals in the panel -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; New Terminal opens a new shell (eshell: works everywhere, also on Windows and remote) in the
;; panel's Terminal tab and focuses it; Open Terminal Here does so in the folder of the Explorer
;; row.  See docs/guide/modules.md.

;;; Code:
(require 'drgnx-modules)
(require 'drgnx-registry)
(defvar eshell-buffer-name)
(declare-function drgnx-explorer-node-at "drgnx-explorer")

(defun drgnx-terminal-new (&optional dir)
  "A new terminal in DIR (default: here), in the panel; returns its buffer."
  (interactive)
  (require 'eshell)
  (let ((default-directory (file-name-as-directory (expand-file-name (or dir default-directory))))
        (eshell-buffer-name (generate-new-buffer-name "*eshell*")))
    (save-window-excursion (eshell))          ; made here, shown by the rules (the panel)
    (let ((b (get-buffer eshell-buffer-name)))
      (pop-to-buffer b)
      b)))

(defun drgnx-terminal-here ()
  "A new terminal in the folder of the Explorer row (or of this file)."
  (interactive)
  (let ((path (and (fboundp 'drgnx-explorer-node-at) (derived-mode-p 'drgnx-explorer-mode) (drgnx-explorer-node-at (point)))))
    (drgnx-terminal-new (if (and path (file-directory-p path)) path
                          (if path (file-name-directory path) default-directory)))))

(drgnx-module-define 'tools/terminal
                     :doc "New Terminal and Open Terminal Here, in the panel."
                     :stage 'startup
                     :setup
                     (lambda ()
                       (drgnx-command-define 'terminal-new :category "Terminal" :title "New Terminal" :scope 'window
                                             :command #'drgnx-terminal-new :doc "A new terminal in the panel")
                       (drgnx-command-define 'explorer-terminal-here :category "Terminal" :title "Open Terminal Here" :scope 'window
                                             :command #'drgnx-terminal-here :context 'explorer :doc "A new terminal in this folder")))

(provide 'drgnx-terminal)
;;; drgnx-terminal.el ends here
