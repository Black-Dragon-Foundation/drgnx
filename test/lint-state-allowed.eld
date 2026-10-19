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
(:file "modules/ui/drgnx-tty-popups.el" :what "window-configuration-change-hook"
 :why "windows made on an ASCII terminal get the ASCII table" :until "B11")
