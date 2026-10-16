;;; drgnx-basics.el --- Module core/basics: defaults every drgnx session gets -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:
(defvar native-comp-async-report-warnings-errors)
(drgnx-module-define 'core/basics
  :doc "Quiet, predictable defaults and the basic file and view commands."
  :stage 'startup
  :setup
  (lambda ()
    (setq ring-bell-function #'ignore
          use-dialog-box nil
          use-short-answers t
          inhibit-startup-screen t
          ;; Background native compilation: warnings go to the log, never a window popping up.
          native-comp-async-report-warnings-errors 'silent)
    (drgnx-command-define 'open-file :category "File" :title "Open File…" :command #'find-file
      :doc "Open a file")
    (drgnx-command-define 'save-file :category "File" :title "Save" :command #'save-buffer
      :doc "Save this buffer")
    (drgnx-command-define 'line-numbers :category "View" :title "Toggle Line Numbers"
      :command #'display-line-numbers-mode :menu '("View") :doc "Line numbers in this buffer")))

;;; drgnx-basics.el ends here
