;;; lint-state-allowed.eld --- window-change sites in modules/ that have not moved to the state store yet  -*- lexical-binding: nil -*-
;; Read by test/unit/lint-state-test.el.  One entry per (file, what) found in modules/:
;;   (:file FILE :what WHAT :why STRING :until TASK)
;; FILE is relative to the checkout root.  WHAT is the hook variable the file adds to, or `get-buffer-window'
;; for a call with a second argument.  UNTIL names the task that moves the site: the task deletes its line
;; (a line that matches nothing fails `drgnx-lint/no-stale-allowlist-entries').

(:file "modules/tools/drgnx-diff.el" :what "window-size-change-functions"
 :why "a diff view re-renders at its window's width (buffer-local)" :until "B12")
(:file "modules/extra/drgnx-blame.el" :what "window-size-change-functions"
 :why "the inline blame refits to its window's width (buffer-local)" :until "B12")
(:file "modules/tools/drgnx-layouts.el" :what "window-size-change-functions"
 :why "Zen centres its text again after a resize" :until "B10")
(:file "modules/ui/drgnx-tty-layout.el" :what "window-size-change-functions"
 :why "a terminal frame re-applies its dock sizes after a resize" :until "B11")
(:file "modules/ui/drgnx-look-echo.el" :what "window-size-change-functions"
 :why "a swapped frame's split takes its widths once the compositor has sized the frame; removed when applied"
 :until "never: one-shot, gone once the widths land")
(:file "modules/ui/drgnx-tty-popups.el" :what "window-configuration-change-hook"
 :why "windows made on an ASCII terminal get the ASCII table" :until "B11")

(:file "modules/tools/drgnx-agents-editor.el" :what "window-buffer-change-functions"
 :why "a file buffer is watched while a window shows it (as the transcript mirror does)" :until "never: the hub is told what is visible")
(:file "modules/tools/drgnx-agents-editor-draw.el" :what "window-size-change-functions"
 :why "ring rows are rebuilt for the rows a resized window shows" :until "never: rows are the window's")
(:file "modules/tools/drgnx-agents-editor.el" :what "window-size-change-functions"
 :why "a resize can reveal or hide a buffer in a window" :until "never: the hub is told what is visible")
(:file "modules/tools/drgnx-agent-panel.el" :what "window-buffer-change-functions"
 :why "a panel is subscribed to its session's entries while a window shows it" :until "never: the hub is told what is visible")
(:file "modules/tools/drgnx-agent-panel.el" :what "get-buffer-window"
 :why "a panel asks whether a window of a visible frame shows it, to subscribe to its session's entries" :until "never: the hub is told what is visible")
