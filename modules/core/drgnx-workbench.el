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
      :command #'drgnx-wb-focus-editor :map 'drgnx-wb-dock-map :doc "From the sidebar back to the editor")
    ;; The Explorer.
    (require 'drgnx-explorer)
    (drgnx-explorer-setup)
    (drgnx-command-define 'focus-explorer :category "View" :title "Focus Explorer" :scope 'window
      :command #'drgnx-explorer-focus :menu '("View") :doc "Show the sidebar and move focus to the file tree")
    (let ((in-explorer (lambda () (derived-mode-p 'drgnx-explorer-mode))))
      (pcase-dolist (`(,id ,title ,fn ,doc)
                     '((explorer-next "Next Row" drgnx-explorer-next "Move the selection down")
                       (explorer-previous "Previous Row" drgnx-explorer-previous "Move the selection up")
                       (explorer-expand "Expand" drgnx-explorer-expand "Expand the folder, or go to its first entry")
                       (explorer-collapse "Collapse" drgnx-explorer-collapse "Collapse the folder, or go to its parent")
                       (explorer-open "Open" drgnx-explorer-open "Open the file (and focus it), or toggle the folder")
                       (explorer-preview "Open to the Side" drgnx-explorer-preview "Open the file, keep the Explorer focused")
                       (explorer-toggle "Toggle Folder" drgnx-explorer-toggle "Expand or collapse the folder")
                       (explorer-refresh "Refresh" drgnx-explorer-refresh "Re-read changed folders")))
        (drgnx-command-define id :category "Explorer" :title title :command fn :doc doc
          :map 'drgnx-explorer-mode-map :when in-explorer)))
    ;; The Buffers panel (open editors), above the Explorer.
    (require 'drgnx-buffers)
    (drgnx-buffers-setup)
    (drgnx-command-define 'focus-buffers :category "View" :title "Focus Buffers" :scope 'window
      :command #'drgnx-buffers-focus :menu '("View") :doc "Show the sidebar and move focus to the open files")
    (let ((in-buffers (lambda () (derived-mode-p 'drgnx-buffers-mode))))
      (pcase-dolist (`(,id ,title ,fn ,doc)
                     '((buffers-next "Next Row" drgnx-buffers-next "Move the selection down")
                       (buffers-previous "Previous Row" drgnx-buffers-previous "Move the selection up")
                       (buffers-open "Open" drgnx-buffers-open "Show the buffer in the editor")
                       (buffers-close "Close" drgnx-buffers-close "Close the buffer")))
        (drgnx-command-define id :category "Buffers" :title title :command fn :doc doc
          :map 'drgnx-buffers-mode-map :when in-buffers)))))

;;; drgnx-workbench.el ends here
