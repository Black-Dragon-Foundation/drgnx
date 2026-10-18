;;; lint-state-allowed.eld --- window-change sites in modules/ that have not moved to the state store yet  -*- lexical-binding: nil -*-
;; Read by test/unit/lint-state-test.el.  One entry per (file, what) found in modules/:
;;   (:file FILE :what WHAT :why STRING :until TASK)
;; FILE is relative to the checkout root.  WHAT is the hook variable the file adds to, or `get-buffer-window'
;; for a call with a second argument.  UNTIL names the task that moves the site: the task deletes its line
;; (a line that matches nothing fails `drgnx-lint/no-stale-allowlist-entries').

(:file "modules/tools/drgnx-live.el" :what "window-buffer-change-functions"
 :why "the view resumes its screencast when it is in a window again (buffer-local)" :until "Task 13")
(:file "modules/tools/drgnx-live.el" :what "window-size-change-functions"
 :why "the view restarts the screencast at its window's width (buffer-local)" :until "Task 13")
(:file "modules/tools/drgnx-live.el" :what "get-buffer-window"
 :why "asks whether the view is shown in any frame" :until "Task 13")
(:file "modules/tools/drgnx-agents-ui.el" :what "window-buffer-change-functions"
 :why "starts and stops the 30 s tick while the Agents list shows" :until "Task 22")
(:file "modules/tools/drgnx-agents-ui.el" :what "get-buffer-window"
 :why "asks whether the Agents list is visible in any frame" :until "Task 22")
(:file "modules/tools/drgnx-diff.el" :what "window-size-change-functions"
 :why "a diff view re-renders at its window's width (buffer-local)" :until "B12")
(:file "modules/tools/drgnx-layouts.el" :what "window-size-change-functions"
 :why "Zen centres its text again after a resize" :until "B10")
(:file "modules/ui/drgnx-tty-layout.el" :what "window-size-change-functions"
 :why "a terminal frame re-applies its dock sizes after a resize" :until "B11")
(:file "modules/ui/drgnx-tty-popups.el" :what "window-configuration-change-hook"
 :why "windows made on an ASCII terminal get the ASCII table" :until "B11")
