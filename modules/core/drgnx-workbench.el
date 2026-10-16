;;; drgnx-workbench.el --- Module core/workbench: change bus, left dock, editor windows -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:
(drgnx-module-define 'core/workbench
  :doc "The workbench: the change bus, the left dock (Buffers, Explorer) and editor windows."
  :stage 'startup
  :setup
  (lambda ()
    (require 'drgnx-wb)
    (drgnx-signal-mode 1)
    (drgnx-command-define 'toggle-sidebar :category "View" :title "Toggle Sidebar" :scope 'window
      :command #'drgnx-wb-toggle-sidebar :menu '("View") :doc "Show or hide the Buffers panel and the Explorer")
    (drgnx-command-define 'focus-editor :category "View" :title "Focus Editor" :scope 'window
      :command #'drgnx-wb-focus-editor :doc "Move focus to the editor you used last")
    (drgnx-command-define 'dock-back :category "View" :title "Back to the Editor" :scope 'window
      :command #'drgnx-wb-focus-editor :map 'drgnx-wb-dock-map :doc "From the sidebar back to the editor")))

;;; drgnx-workbench.el ends here
