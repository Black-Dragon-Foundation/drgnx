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
(:file "modules/tools/drgnx-diff.el" :what "window-size-change-functions"
 :why "a diff view re-renders at its window's width (buffer-local)" :until "B12")
(:file "modules/tools/drgnx-layouts.el" :what "window-size-change-functions"
 :why "Zen centres its text again after a resize" :until "B10")
(:file "modules/ui/drgnx-tty-layout.el" :what "window-size-change-functions"
 :why "a terminal frame re-applies its dock sizes after a resize" :until "B11")
(:file "modules/ui/drgnx-tty-popups.el" :what "window-configuration-change-hook"
 :why "windows made on an ASCII terminal get the ASCII table" :until "B11")
;; Sites from the branches merged at Task 14 (m12f-a's close and top line; C-UI's cockpit).
(:file "modules/ui/drgnx-close.el" :what "window-buffer-change-functions"
 :why "Esc and q close a pane: recomputes whether the selected window is a lane or area (global)" :until "Task 18")
(:file "modules/tools/drgnx-cockpit.el" :what "window-size-change-functions"
 :why "the Work graph re-fits at its window's size (buffer-local)" :until "Task 23")
(:file "modules/tools/drgnx-cockpit.el" :what "window-buffer-change-functions"
 :why "the Work graph re-fits when it is shown (buffer-local)" :until "Task 23")
(:file "modules/tools/drgnx-cockpit.el" :what "get-buffer-window"
 :why "asks whether the Work graph shows in a visible frame" :until "Task 23")
(:file "modules/tools/drgnx-cockpit-edits.el" :what "window-buffer-change-functions"
 :why "the Edits pane catches up when it is shown (buffer-local)" :until "Task 24")
(:file "modules/tools/drgnx-cockpit-edits.el" :what "get-buffer-window"
 :why "asks whether the Edits pane shows in a visible frame" :until "Task 24")
(:file "modules/tools/drgnx-cockpit-feed.el" :what "window-buffer-change-functions"
 :why "a feed pane catches up when it is shown (buffer-local)" :until "Task 25")
(:file "modules/tools/drgnx-cockpit-feed.el" :what "window-size-change-functions"
 :why "a feed pane re-fits at its window's size (buffer-local)" :until "Task 25")
(:file "modules/tools/drgnx-cockpit-feed.el" :what "get-buffer-window"
 :why "asks which feed buffers show in a visible frame" :until "Task 25")
(:file "modules/tools/drgnx-cockpit-cards.el" :what "get-buffer-window"
 :why "asks whether a card part shows in a visible frame (shares the feed's refresh)" :until "Task 25")
