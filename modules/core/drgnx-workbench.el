;;; drgnx-workbench.el --- Module core/workbench: change bus, left dock, editor windows -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-surfaces)
(require 'drgnx-memo)
(declare-function drgnx-signal-mode "drgnx-signal")
(declare-function drgnx-state-mode "drgnx-state")
(declare-function drgnx-state-subscribe "drgnx-state")
(declare-function drgnx-state-intent--user-resized "drgnx-state-intent")
(declare-function drgnx-view--windows-changed "drgnx-view")
(declare-function drgnx-wb-toggle-sidebar "drgnx-wb")
(declare-function drgnx-wb-view-explorer "drgnx-wb")
(declare-function drgnx-wb-view-search "drgnx-wb")
(declare-function drgnx-wb-focus-editor "drgnx-wb")
(declare-function drgnx-explorer-setup "drgnx-explorer")
(declare-function drgnx-rules-mode "drgnx-rules")
(declare-function drgnx-chrome-mode "drgnx-chrome")
(declare-function drgnx-buffers-save-row "drgnx-actions")
(declare-function drgnx-buffers-copy-path-row "drgnx-actions")
(declare-function drgnx-buffers-reveal-row "drgnx-actions")
(declare-function drgnx-buffers-full-view "drgnx-actions")
(declare-function drgnx-explorer-reveal-in-buffers "drgnx-actions")
(declare-function drgnx-explorer-open-in-dired "drgnx-actions")
(declare-function drgnx-explorer-other-window "drgnx-actions")
(declare-function drgnx-wb-panel-next-tab "drgnx-actions")
(declare-function drgnx-help-mode-menu "drgnx-actions")
(declare-function drgnx-frames-mode "drgnx-frames")
(declare-function drgnx-frames-move-editor "drgnx-frames")
(declare-function drgnx-frames-open-editor "drgnx-frames")
(declare-function drgnx-frames-move-group "drgnx-frames")
(declare-function drgnx-buffers-toggle-all-windows "drgnx-buffers")
(declare-function drgnx-monitors-mode "drgnx-monitors")
(declare-function drgnx-monitors-available-p "drgnx-monitors")
(declare-function drgnx-monitors--context-p "drgnx-monitors")
(declare-function drgnx-monitors-move-to "drgnx-monitors")
(declare-function drgnx-monitors-move-next "drgnx-monitors")
(declare-function drgnx-monitors-move-previous "drgnx-monitors")
(declare-function drgnx-outline-setup "drgnx-outline")
(declare-function drgnx-outline-focus "drgnx-outline")
(declare-function drgnx-outline-open "drgnx-outline")
(declare-function drgnx-persist-mode "drgnx-persist")
(declare-function drgnx-persist-save "drgnx-persist")
(declare-function drgnx-persist-restore "drgnx-persist")
(declare-function drgnx-groups-split-right "drgnx-groups")
(declare-function drgnx-groups-split-down "drgnx-groups")
(declare-function drgnx-groups-close "drgnx-groups")
(declare-function drgnx-groups-close-all-editors "drgnx-groups")
(declare-function drgnx-groups-focus-1 "drgnx-groups")
(declare-function drgnx-groups-focus-2 "drgnx-groups")
(declare-function drgnx-groups-focus-3 "drgnx-groups")
(declare-function drgnx-groups-move-to-next "drgnx-groups")
(declare-function drgnx-chrome-close-tab "drgnx-chrome")
(declare-function drgnx-chrome-next-tab "drgnx-chrome")
(declare-function drgnx-chrome-previous-tab "drgnx-chrome")
(declare-function drgnx-wb-toggle-panel "drgnx-area")
(declare-function drgnx-wb-focus-panel "drgnx-area")
(declare-function drgnx-wb-toggle-right-dock "drgnx-area")
(declare-function drgnx-wb-show-unrouted "drgnx-rules")
(declare-function drgnx-explorer-focus "drgnx-explorer")
(declare-function drgnx-buffers-setup "drgnx-buffers")
(declare-function drgnx-buffers-focus "drgnx-buffers")
(declare-function drgnx-buffers-save-all "drgnx-buffers")
(declare-function drgnx-buffers-close-saved "drgnx-buffers")
(declare-function drgnx-buffers-close-all "drgnx-buffers")

(drgnx-module-define 'core/workbench
                     :doc "The workbench: the change bus, the left dock (Buffers, Explorer) and editor windows."
                     :stage 'startup
                     ;; Everything it sets is recorded (a test turns it off cleanly), but live windows, frames and
                     ;; buffers are laid out by it: Preferences stops it at the next start.
                     :teardown 'restart
                     :setup
                     (lambda ()
                       (require 'drgnx-wb)
                       ;; Views draw only while the store sees them shown; subscribed before it first observes.
                       (require 'drgnx-view)
                       (dolist (event '(windows-changed frame-visibility frame-removed))
                         (drgnx-state-subscribe event #'drgnx-view--windows-changed :lane 'now))
                       (drgnx-state-mode 1)    ; the state store first: the bus follows its window events
                       (drgnx-signal-mode 1)
                       ;; A size you set by hand is intent; the docks keep it when the frame resizes.
                       (drgnx-state-subscribe 'pane-resized #'drgnx-state-intent--user-resized)
                       ;; Where buffers go.
                       (require 'drgnx-rules)
                       (drgnx-rules-mode 1)
                       ;; The bottom panel and the right dock; popups borrow the panel.
                       (require 'drgnx-area)
                       (require 'drgnx-popup)
                       (drgnx-command-define 'toggle-panel :category "View" :title "Toggle Panel" :scope 'window
                                             :command #'drgnx-wb-toggle-panel :menu '("View") :doc "Show or hide the bottom panel (Terminal, Problems, Output, Results, Help)")
                       (drgnx-command-define 'focus-panel :category "View" :title "Focus Panel" :scope 'window
                                             :command #'drgnx-wb-focus-panel :doc "Show the bottom panel and move focus to it")
                       (drgnx-command-define 'toggle-right-dock :category "View" :title "Toggle Right Dock" :scope 'window
                                             :command #'drgnx-wb-toggle-right-dock :menu '("View") :doc "Show or hide the right dock")
                       ;; The Notices list (core) is a panel tab.
                       (drgnx-wb-place "\\`\\*drgnx Notices\\*\\'" 'panel)
                       ;; Chrome by role: tab lines and breadcrumbs in editor windows.
                       (require 'drgnx-chrome)
                       (drgnx-chrome-mode 1)
                       ;; Editor groups (made only by these commands).
                       (require 'drgnx-groups)
                       (pcase-dolist (`(,id ,title ,fn ,doc)
                                      '((split-editor-right "Split Editor Right" drgnx-groups-split-right "A new editor group to the right, same file")
                                        (split-editor-down "Split Editor Down" drgnx-groups-split-down "A new editor group below, same file")
                                        (close-group "Close Editor Group" drgnx-groups-close "Close this group (its files stay open); the last one stays")
                                        (close-group-editors "Close All Editors in Group" drgnx-groups-close-all-editors "Close every tab of this group (its files stay open); the group closes unless it is the last")
                                        (focus-group-1 "Focus First Editor Group" drgnx-groups-focus-1 "Focus group 1")
                                        (focus-group-2 "Focus Second Editor Group" drgnx-groups-focus-2 "Focus group 2 (made if there is one group)")
                                        (focus-group-3 "Focus Third Editor Group" drgnx-groups-focus-3 "Focus group 3 (made if there are two)")
                                        (move-editor-to-next-group "Move Editor into Next Group" drgnx-groups-move-to-next "Move the shown file to the next group")))
                         (drgnx-command-define id :category "View" :title title :scope 'window :command fn :doc doc))
                       ;; Several windows (frames): roles, moving editors, each window's buffers.
                       (require 'drgnx-frames)
                       (drgnx-frames-mode 1)
                       (pcase-dolist (`(,id ,title ,fn ,doc)
                                      '((move-editor-to-new-window "Move Editor into New Window" drgnx-frames-move-editor "Move the shown file to a new window")
                                        (open-editor-in-new-window "Open Editor in New Window" drgnx-frames-open-editor "Show the file in a new window too")
                                        (move-group-to-new-window "Move Editor Group into New Window" drgnx-frames-move-group "Move this group and its tabs to a new window")
                                        (buffers-toggle-all-windows "Buffers: Show All Windows" drgnx-buffers-toggle-all-windows "List the buffers of every window, or of this one")))
                         (drgnx-command-define id :category "View" :title title :scope 'window :command fn :doc doc))
                       ;; Moving a window to another monitor: only where the window manager allows it.
                       (require 'drgnx-monitors)
                       (drgnx-monitors-mode 1)
                       (drgnx-surfaces-define-context 'monitors #'drgnx-monitors--context-p)
                       (pcase-dolist (`(,id ,title ,fn ,ctx ,doc)
                                      '((window-move-to-monitor "Move to Monitor…" drgnx-monitors-move-to monitors "Pick the monitor to move this window to")
                                        (window-move-to-next-monitor "Move to Next Monitor" drgnx-monitors-move-next nil "Move this window to the next monitor, from the last back to the first")
                                        (window-move-to-previous-monitor "Move to Previous Monitor" drgnx-monitors-move-previous nil "Move this window to the previous monitor, from the first to the last")))
                         (drgnx-command-define id :category "Window" :title title :scope 'window :command fn :context ctx
                                               :when #'drgnx-monitors-available-p :doc doc))
                       ;; Row actions across panels, panel tabs, the mode's menu.
                       (require 'drgnx-actions)
                       (pcase-dolist (`(,id ,title ,fn ,ctx ,doc)
                                      '((buffers-save "Save" drgnx-buffers-save-row buffers "Save the buffer on this row")
                                        (buffers-copy-path "Copy Path" drgnx-buffers-copy-path-row buffers "Copy the path of this row's file")
                                        (buffers-reveal "Reveal in Explorer" drgnx-buffers-reveal-row buffers "Show this file in the Explorer")
                                        (buffers-full-view "Full Buffer Manager" drgnx-buffers-full-view nil "All buffers in a table (ibuffer)")
                                        (explorer-reveal-in-buffers "Reveal in Buffers" drgnx-explorer-reveal-in-buffers explorer "Show this open file in the Buffers panel")
                                        (explorer-open-in-dired "Open Folder in Dired" drgnx-explorer-open-in-dired explorer "This folder in dired")
                                        (explorer-other-window "Open in Other Group" drgnx-explorer-other-window explorer "Open the file in the other editor group")
                                        (view-panel-next "Next Panel Tab" drgnx-wb-panel-next-tab nil "Show the panel's next tab")
                                        (help-mode-menu "Menu for This Mode" drgnx-help-mode-menu nil "The major mode's menu, at point")))
                         (drgnx-command-define id :category "View" :title title :scope 'window :command fn :context ctx :doc doc))
                       (pcase-dolist (`(,id ,title ,fn ,doc)
                                      '((focus-left "Focus Left" drgnx-wb-focus-left "Move focus to the editor group or dock on the left")
                                        (focus-right "Focus Right" drgnx-wb-focus-right "Move focus to the editor group or dock on the right")
                                        (focus-up "Focus Above" drgnx-wb-focus-up "Move focus to the editor group or dock above")
                                        (focus-down "Focus Below" drgnx-wb-focus-down "Move focus to the editor group or dock below")))
                         (drgnx-command-define id :category "View" :title title :scope 'window :command fn :doc doc))
                       ;; The layout survives a restart.
                       (require 'drgnx-persist)
                       (drgnx-persist-mode 1)
                       (drgnx-command-define 'wb-save-layout :category "View" :title "Save Workbench Layout" :scope 'window
                                             :command #'drgnx-persist-save :doc "Save docks, panel, editor groups and tabs now (also done on exit)")
                       (drgnx-command-define 'wb-restore-layout :category "View" :title "Restore Workbench Layout" :scope 'window
                                             :command #'drgnx-persist-restore :doc "Bring back the last saved layout (also done at start)")
                       (drgnx-command-define 'close-tab :category "View" :title "Close Tab" :scope 'window
                                             :command #'drgnx-chrome-close-tab :doc "Close the shown tab (the buffer stays open)")
                       (drgnx-command-define 'next-tab :category "View" :title "Next Tab" :scope 'window
                                             :command #'drgnx-chrome-next-tab :doc "Show the next tab of this editor group")
                       (drgnx-command-define 'previous-tab :category "View" :title "Previous Tab" :scope 'window
                                             :command #'drgnx-chrome-previous-tab :doc "Show the previous tab of this editor group")
                       (drgnx-command-define 'wb-unrouted :category "View" :title "Show Unrouted Buffers" :scope 'window
                                             :command #'drgnx-wb-show-unrouted :doc "Buffers no placement rule matched (each one is a rule to add)")
                       (drgnx-command-define 'toggle-sidebar :category "View" :title "Toggle Sidebar" :scope 'window
                                             :command #'drgnx-wb-toggle-sidebar :menu '("View") :doc "Show or hide the Buffers panel and the Explorer")
                       (drgnx-command-define 'view-explorer :category "View" :title "View: Explorer" :scope 'window
                                             :command #'drgnx-wb-view-explorer
                                             :doc "Show the Buffers panel and the Explorer in the sidebar and focus the file tree")
                       (drgnx-command-define 'view-search :category "View" :title "View: Search" :scope 'window
                                             :command #'drgnx-wb-view-search
                                             :doc "Show the Search view in the sidebar and focus it")
                       (drgnx-command-define 'focus-editor :category "View" :title "Focus Editor" :scope 'window
                                             :command #'drgnx-wb-focus-editor :doc "Move focus to the editor you used last")
                       (drgnx-command-define 'dock-back :category "View" :title "Back to the Editor" :scope 'window
                                             :command #'drgnx-wb-focus-editor :map 'drgnx-wb-dock-map :doc "From the sidebar back to the editor")
                       ;; The Explorer.
                       (require 'drgnx-explorer)
                       (drgnx-memo-activate 'git-status 'explorer-listing) ; capped caches: emptied on teardown
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
                                          (explorer-preview "Open, Keep Focus" drgnx-explorer-preview "Open the file, keep the Explorer focused")
                                          (explorer-toggle "Toggle Folder" drgnx-explorer-toggle "Expand or collapse the folder")
                                          (explorer-refresh "Refresh" drgnx-explorer-refresh "Re-read changed folders")
                                          (explorer-select-down "Select Down" drgnx-explorer-select-down "Extend the selection down")
                                          (explorer-select-up "Select Up" drgnx-explorer-select-up "Extend the selection up")
                                          (explorer-mark "Mark" drgnx-explorer-mark "Add to the selection (or take out), go on")
                                          (explorer-find "Find…" drgnx-explorer-find "Show only files whose names contain the text (empty: all again)")
                                          (explorer-find-clear "Clear Find" drgnx-explorer-find-clear "Show the whole tree again")))
                           (drgnx-command-define id :category "Explorer" :title title :command fn :doc doc
                                                 :map 'drgnx-explorer-mode-map :when in-explorer))
                         ;; File operations: also on the Explorer's right-click menu.
                         (drgnx-surfaces-define-context 'explorer (lambda (_) (derived-mode-p 'drgnx-explorer-mode)))
                         (pcase-dolist (`(,id ,title ,fn ,doc)
                                        '((explorer-new-file "New File…" drgnx-explorer-new-file "A file (a/b/c.txt makes folders) or a folder (end with /)")
                                          (explorer-rename "Rename…" drgnx-explorer-rename "Rename; open buffers follow")
                                          (explorer-delete "Delete" drgnx-explorer-delete "Move to the trash (asks first)")
                                          (explorer-delete-permanently "Delete Permanently" drgnx-explorer-delete-permanently "Delete without the trash (asks first)")
                                          (explorer-copy "Copy" drgnx-explorer-copy "Copy, for Paste")
                                          (explorer-cut "Cut" drgnx-explorer-cut "Cut, for Paste (moves)")
                                          (explorer-paste "Paste" drgnx-explorer-paste "Paste into this folder (never overwrites)")
                                          (explorer-copy-path "Copy Path" drgnx-explorer-copy-path "The absolute path, to the clipboard")
                                          (explorer-copy-relative-path "Copy Relative Path" drgnx-explorer-copy-relative-path "The path from the root, to the clipboard")
                                          (explorer-reveal-externally "Reveal in File Manager" drgnx-explorer-reveal-externally "Open the folder in the system's file manager")))
                           (drgnx-command-define id :category "Explorer" :title title :command fn :doc doc
                                                 :map 'drgnx-explorer-mode-map :when in-explorer :context 'explorer)))
                       ;; The Outline, below the Explorer.
                       (require 'drgnx-outline)
                       (drgnx-outline-setup)
                       (drgnx-command-define 'focus-outline :category "View" :title "Focus Outline" :scope 'window
                                             :command #'drgnx-outline-focus :doc "Show the sidebar and move focus to the editor's definitions")
                       (drgnx-command-define 'outline-open :category "Outline" :title "Go to Definition" :command #'drgnx-outline-open
                                             :map 'drgnx-outline-mode-map :when (lambda () (derived-mode-p 'drgnx-outline-mode))
                                             :doc "Go to the definition of the row (focuses the editor)")
                       ;; The Buffers panel (open editors), above the Explorer.
                       (require 'drgnx-buffers)
                       (drgnx-buffers-setup)
                       (drgnx-surfaces-define-context 'buffers (lambda (_) (derived-mode-p 'drgnx-buffers-mode)))
                       (drgnx-command-define 'save-all :category "File" :title "Save All" :command #'drgnx-buffers-save-all
                                             :menu '("File") :context 'buffers :doc "Save every buffer with unsaved changes")
                       (drgnx-command-define 'close-saved :category "View" :title "Close Saved Editors" :command #'drgnx-buffers-close-saved
                                             :doc "Close every buffer without unsaved changes")
                       (drgnx-command-define 'close-all :category "View" :title "Close All Editors" :command #'drgnx-buffers-close-all
                                             :doc "Close every open file (unsaved ones ask first)")
                       (drgnx-command-define 'focus-buffers :category "View" :title "Focus Buffers" :scope 'window
                                             :command #'drgnx-buffers-focus :menu '("View") :doc "Show the sidebar and move focus to the open files")
                       (let ((in-buffers (lambda () (derived-mode-p 'drgnx-buffers-mode))))
                         (pcase-dolist (`(,id ,title ,fn ,doc)
                                        '((buffers-next "Next Row" drgnx-buffers-next "Move the selection down")
                                          (buffers-previous "Previous Row" drgnx-buffers-previous "Move the selection up")
                                          (buffers-open "Open" drgnx-buffers-open "Show the buffer in the editor")
                                          (buffers-close "Close" drgnx-buffers-close "Close the buffer")
                                          (buffers-close-others "Close Others" drgnx-buffers-close-others "Close every buffer but this one")
                                          (buffers-filter "Filter…" drgnx-buffers-filter "Show only buffers whose names contain the text")))
                           (drgnx-command-define id :category "Buffers" :title title :command fn :doc doc
                                                 :map 'drgnx-buffers-mode-map :when in-buffers
                                                 :context (and (memq id '(buffers-open buffers-close buffers-close-others)) 'buffers))))))

;;; drgnx-workbench.el ends here
