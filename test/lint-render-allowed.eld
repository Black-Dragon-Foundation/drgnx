;;; lint-render-allowed.eld --- today's sites for test/unit/lint-render-test.el  -*- lexical-binding: t -*-
;; Each entry: (:file F :in DEFUN :what CALL :kind KIND :why STRING [:until TASK] [:n COUNT]), one per
;; (file, defun, call); :n is the number of sites when it is more than one.  KIND: document (drawn once on a
;; user action), listing (Explorer and Buffers: jit-lock styling, a spec non-goal), job-window (retired by C8),
;; migrate (a live view; :until names the task that rewrites it), recovery (the view core's own reset).
;; Counts can only fall: the task that rewrites a site deletes its entry.  A branch merged later adds its sites.
(
 (:file "modules/tools/drgnx-agents-session.el" :in drgnx-agents-session-job-log :what erase-buffer :kind document :why "the job log is shown on the user's action")
 (:file "modules/tools/drgnx-live.el" :in drgnx-live--render-notes :what delete-region :kind migrate :why "the notes below the live page are cut and redrawn on a state change (no render task owns this file: the manager assigns one)" :until "phase 2 (live browser notes)")
 (:file "wb/drgnx-explorer.el" :in drgnx-explorer--render-old :what erase-buffer :kind listing :why "Explorer is styled by jit-lock and rebuilt on a root change (spec non-goal)")
 (:file "wb/drgnx-explorer.el" :in drgnx-explorer--find-draw-old :what erase-buffer :kind listing :why "the find-in-tree result is the same listing, built whole (spec non-goal)")
 (:file "wb/drgnx-buffers.el" :in drgnx-buffers--render :what erase-buffer :kind listing :why "Buffers is styled by jit-lock and rebuilt on a list change (spec non-goal)")
 (:file "wb/drgnx-view.el" :in drgnx-view--remove-rows :what delete-region :kind recovery :why "the fallback when the row starts no longer match the text (a foreign edit); the normal path removes rows in slices")
 (:file "wb/drgnx-view.el" :in drgnx-view--self-check :what delete-region :kind recovery :why "a view whose region is not as long as its entries resets it, then draws every row again")
 (:file "modules/lang/drgnx-markdown.el" :in drgnx-markdown--insert-html :what erase-buffer :kind document :why "the html preview is built when the user opens it")
 (:file "modules/lang/drgnx-markdown.el" :in drgnx-markdown--render :what erase-buffer :kind document :why "the markdown view is built when the user opens it")
 (:file "modules/tools/drgnx-agent-settings.el" :in drgnx-agent-settings--render :what erase-buffer :kind document :why "the settings page is drawn on the user's action")
 (:file "modules/tools/drgnx-plugins-ui.el" :in drgnx-plugins--render :what erase-buffer :kind document :why "the plugins page is drawn on the user's action and when the hub says a plugin changed")
 (:file "modules/tools/drgnx-agents-editor-here.el" :in drgnx-agents-editor-here-show :what erase-buffer :kind document :why "the who-is-here list is drawn when the user asks for it, a handful of rows")
 (:file "modules/tools/drgnx-ai-ui.el" :in drgnx-ai--answer-buffer :what erase-buffer :kind document :why "an answer is shown when the user asks")
 (:file "modules/tools/drgnx-browser.el" :in drgnx-browser--placeholder :what erase-buffer :kind document :why "the placeholder page is drawn once")
 (:file "modules/tools/drgnx-browser.el" :in drgnx-browser--show-screenshot :what erase-buffer :kind document :why "a screenshot is shown on the user's action")
 (:file "modules/tools/drgnx-extensions-trust.el" :in drgnx-extensions-trust--render :what erase-buffer :kind document :why "the trust card is drawn when the user's Install opens it, and again when the hub has answered what it brings")
 (:file "modules/tools/drgnx-diff.el" :in drgnx-diff--render :what erase-buffer :kind document :why "a diff is drawn once when the user opens it")
 (:file "modules/tools/drgnx-diff.el" :in drgnx-diff--load :what erase-buffer :kind document :why "the diff buffer shows \"Loading\" and then the diff (two sites)" :n 2)
 (:file "modules/tools/drgnx-runners.el" :in drgnx-runners-show-log :what erase-buffer :kind document :why "a runner's record is drawn on the user's action")
 (:file "modules/tools/drgnx-layouts.el" :in drgnx-layouts--agent-buffer :what erase-buffer :kind document :why "the no-agent page is drawn once")
 (:file "modules/tools/drgnx-prs.el" :in drgnx-prs--draw :what tabulated-list-print :kind document :why "the pull-request list is printed on the user's refresh")
 (:file "modules/tools/drgnx-review.el" :in drgnx-review--draw :what erase-buffer :kind document :why "a review is drawn when the user opens it")
 (:file "modules/tools/drgnx-shortcuts.el" :in drgnx-shortcuts--draw :what erase-buffer :kind document :why "the shortcuts page is drawn on the user's action")
 (:file "modules/tools/drgnx-work-code.el" :in drgnx-work-code-files :what erase-buffer :kind document :why "the picker's waiting line is drawn when the user opens the list")
 (:file "modules/tools/drgnx-work-code.el" :in drgnx-work-files--fill :what erase-buffer :kind document :why "the picker lists one agent's files once, when the hub has answered")
 (:file "modules/ui/drgnx-quickhelp.el" :in drgnx-quickhelp--render :what erase-buffer :kind document :why "the quick help is drawn when the user opens it")
 (:file "modules/ui/drgnx-start.el" :in drgnx-start--render :what erase-buffer :kind document :why "the start page is drawn when the user opens it")
 (:file "modules/ui/drgnx-tty-frames.el" :in drgnx-tty-frames-terminal-check :what erase-buffer :kind document :why "the terminal check report is drawn on the user's action")
 (:file "wb/drgnx-rules.el" :in drgnx-wb-show-unrouted :what erase-buffer :kind document :why "the unrouted list is shown on the user's action")
 (:file "modules/tools/drgnx-search-edit.el" :in drgnx-search-edit--open :what erase-buffer :kind document :why "Edit Results is built when the user opens it; afterwards the user edits it")
 (:file "modules/tools/drgnx-search-handoff.el" :in drgnx-search-handoff--draw :what erase-buffer :kind document :why "the Ask an Agent card (a dozen lines) is drawn when the user opens it, chooses who, switches hidden files, and once when the hub sends its context box; the instruction is kept")
 (:file "modules/tools/drgnx-search-edit.el" :in drgnx-search-edit--faces :what erase-buffer :kind document :why "a hidden buffer holding one line to fontify, never shown"))
