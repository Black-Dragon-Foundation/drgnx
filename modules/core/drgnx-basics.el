;;; drgnx-basics.el --- Module core/basics: defaults every drgnx session gets -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:
(drgnx-module-define 'core/basics
  :doc "Quiet, predictable defaults and the basic file and view commands."
  :stage 'startup
  :setup
  (lambda ()
    (setq ring-bell-function #'ignore
          use-dialog-box nil
          use-short-answers t
          inhibit-startup-screen t)
    (drgnx-command-define 'open-file :category "File" :title "Open File…" :native "C-x C-f"
      :doc "Open a file")
    (drgnx-command-define 'save-file :category "File" :title "Save" :native "C-x C-s"
      :doc "Save this buffer")
    (drgnx-command-define 'line-numbers :category "View" :title "Toggle Line Numbers"
      :command #'display-line-numbers-mode :menu '("View") :doc "Line numbers in this buffer")))

;;; drgnx-basics.el ends here
