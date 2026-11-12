;;; drgnx-debug.el --- Module extra/debug: a debugger (the hub's, the Debug Adapter Protocol) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Debugging through the hub's DAP client (docs/develop/debugging.md) — the Debug Adapter Protocol, so the same
;; adapters as VS Code (debugpy, the JS debugger, delve, CodeLLDB, …) — with VS Code's keys in that profile: F5 starts
;; (or continues), F9 toggles a breakpoint, F10 steps over, F11 steps into while a session runs (Zen Mode otherwise),
;; S-F11 steps out, S-F5 stops.  The sessions are what the hub's `debug-state' last said.  See docs/guide/editing.md.

;;; Code:
(require 'seq)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-debug-gutter (expand-file-name "drgnx-debug-gutter" (file-name-directory (macroexp-file-name))))
(require 'drgnx-debug-fork (expand-file-name "drgnx-debug-fork" (file-name-directory (macroexp-file-name))))
(require 'drgnx-debug-timeline (expand-file-name "drgnx-debug-timeline" (file-name-directory (macroexp-file-name))))
(require 'drgnx-debug-bisect (expand-file-name "drgnx-debug-bisect" (file-name-directory (macroexp-file-name))))
(require 'drgnx-debug-investigation
         (expand-file-name "drgnx-debug-investigation" (file-name-directory (macroexp-file-name))))
(require 'drgnx-debug-origin (expand-file-name "drgnx-debug-origin" (file-name-directory (macroexp-file-name))))
(require 'drgnx-debug-toolbar (expand-file-name "drgnx-debug-toolbar" (file-name-directory (macroexp-file-name))))
(require 'drgnx-debug-view (expand-file-name "drgnx-debug-view" (file-name-directory (macroexp-file-name))))
(require 'drgnx-debug-console (expand-file-name "drgnx-debug-console" (file-name-directory (macroexp-file-name))))
(defvar drgnx-statusbar-left)
(declare-function drgnx-wb-define-tab "drgnx-area")
(declare-function drgnx-hub-call "drgnx-hub-client")
(defvar drgnx-hub-event-functions)

(defvar drgnx-debug-session-map (make-sparse-keymap)
  "Keys while a debugging session runs (key profiles: `:map drgnx-debug-session-map').")

(define-minor-mode drgnx-debug-session-mode
  "On while a debugging session runs: its keys (`drgnx-debug-session-map') come first."
  :global t :group 'drgnx :keymap drgnx-debug-session-map)

(defvar drgnx-debug--sessions nil
  "The debug sessions as the hub's `debug-state' last said: plists (:id :name :parent :root :state :attach …).")

(defvar drgnx-debug--focus nil
  "The id of the session picked on the toolbar's chip (`drgnx-debug-toolbar-pick-session'), or nil: the commands act
on it while it lives.")

(defun drgnx-debug--event (event data)
  "`drgnx-hub-event-functions': `debug-state' gives the sessions (the session keys, the toolbar and the status bar
follow them, a running session's stop marks go), `debug-frame' marks and opens a stop's line, `debug-ended' takes its
marks away, `debug-output' goes to the debug console."
  (pcase event
    ("debug-state"
     (setq drgnx-debug--sessions (append (plist-get data :sessions) nil))
     (unless (seq-find (lambda (s) (equal (plist-get s :id) drgnx-debug--focus)) drgnx-debug--sessions)
       (setq drgnx-debug--focus nil))
     (drgnx-debug-session-mode (if drgnx-debug--sessions 1 -1))
     (drgnx-debug-gutter-stop-sessions drgnx-debug--sessions)
     (drgnx-debug-console-sessions drgnx-debug--sessions)
     (drgnx-debug-toolbar-sync))
    ("debug-output" (drgnx-debug-console-output data))
    ("debug-frame" (drgnx-debug-gutter-show-frame data))
    ("debug-ended" (drgnx-debug-gutter-stop-clear (plist-get data :session)))))

(defun drgnx-debug--session (&optional state)
  "The session the commands act on: the picked one (`drgnx-debug--focus') when it is in STATE (any, STATE nil), else
this project's session in STATE, or (STATE nil) its stopped one, else its first; nil when there is none."
  (let ((focus (and drgnx-debug--focus
                    (seq-find (lambda (s) (equal (plist-get s :id) drgnx-debug--focus)) drgnx-debug--sessions)))
        (mine (seq-filter (lambda (s) (equal (plist-get s :root) (drgnx-debug-launch-root))) drgnx-debug--sessions)))
    (or (and focus (or (null state) (equal (plist-get focus :state) state)) focus)
        (seq-find (lambda (s) (equal (plist-get s :state) (or state "stopped"))) mine)
        (and (not state) (car mine)))))

(defun drgnx-debug--answered (_result error)
  "A `debug/control' answer: its ERROR in the echo area."
  (when error (message "Debug: %s" error)))

(defun drgnx-debug-control (op)
  "OP (`next', `step-in', `step-out', `stop', …: `debug/control') on this project's session."
  (let ((s (drgnx-debug--session)))
    (unless s (user-error "No debug session in this project"))
    (drgnx-hub-call "debug/control" (list :session (plist-get s :id) :op op) #'drgnx-debug--answered)))

(defun drgnx-debug-step-over () "To the next line." (interactive) (drgnx-debug-control "next"))
(defun drgnx-debug-step-in () "Into the call on this line." (interactive) (drgnx-debug-control "step-in"))
(defun drgnx-debug-step-out () "Out of this function." (interactive) (drgnx-debug-control "step-out"))
(defun drgnx-debug-stop () "End the session." (interactive) (drgnx-debug-control "stop"))
(defun drgnx-debug-restart () "Start the session again." (interactive) (drgnx-debug-control "restart"))
(defun drgnx-debug-pause () "Stop the running program where it is." (interactive) (drgnx-debug-control "pause"))
(defun drgnx-debug-disconnect () "Leave an attached program running and end the session." (interactive)
       (drgnx-debug-control "disconnect"))

(defvar drgnx-debug-mode-map (make-sparse-keymap)
  "Keys of the module (key profiles: `:map drgnx-debug-mode-map'); the Emacs profile's `C-x C-a' keys live here, so a
loaded gud's own `C-x C-a' in `global-map' loses to them.")

(defun drgnx-debug--gutter-on ()
  "`find-file-hook': a file's buffer gets the breakpoint column."
  (when buffer-file-name (drgnx-debug-gutter-mode 1)))

(define-minor-mode drgnx-debug-mode
  "The module's own state: its keys (`drgnx-debug-mode-map') and the breakpoint column in every file's buffer; off,
the toolbar's cards go too."
  :global t :group 'drgnx :keymap drgnx-debug-mode-map
  (if drgnx-debug-mode
      (progn (add-hook 'find-file-hook #'drgnx-debug--gutter-on)
             (add-hook 'drgnx-hub-event-functions #'drgnx-debug--event))
    (remove-hook 'find-file-hook #'drgnx-debug--gutter-on)
    (remove-hook 'drgnx-hub-event-functions #'drgnx-debug--event)
    (drgnx-debug-gutter-stop-clear-all)
    (drgnx-debug-toolbar-delete-all)
    (setq drgnx-debug--sessions nil drgnx-debug--focus nil))
  (dolist (b (buffer-list))
    (with-current-buffer b
      (cond ((and drgnx-debug-mode buffer-file-name) (drgnx-debug-gutter-mode 1))
            ((and (not drgnx-debug-mode) drgnx-debug-gutter-mode) (drgnx-debug-gutter-mode -1))))))

(defun drgnx-debug--teardown ()
  "The session keys go with the module (a running session turned them on, not the setup), and the column."
  (drgnx-debug-view--teardown)
  (drgnx-debug-console--teardown)
  (drgnx-debug-session-mode -1)
  (drgnx-debug-timeline-mode -1)
  (drgnx-debug-bisect-events-mode -1)
  (drgnx-debug-origin-events-mode -1)
  (drgnx-debug-mode -1))

(defun drgnx-debug-breakpoint-conditional ()
  "A conditional breakpoint on this line (or edit its condition)."
  (interactive)
  (drgnx-debug-gutter-edit (line-number-at-pos) 'condition))

(defun drgnx-debug-logpoint ()
  "A logpoint on this line (or edit its message)."
  (interactive)
  (drgnx-debug-gutter-edit (line-number-at-pos) 'log))

(defun drgnx-debug-breakpoint-enable ()
  "Enable this line's breakpoint, or disable it."
  (interactive)
  (let ((id (drgnx-debug-gutter--mark-at (line-number-at-pos))))
    (unless id (user-error "No breakpoint on this line"))
    (drgnx-debug-gutter-set-enabled (line-number-at-pos)
                                    (not (plist-get (drgnx-debug-gutter--bp id) :enabled)))))

(defun drgnx-debug-run-to-cursor ()
  "Continue the project's session until it reaches this line."
  (interactive)
  (drgnx-debug-gutter-run-to-cursor (line-number-at-pos)))

(defun drgnx-debug-start-or-continue ()
  "Continue this project's stopped session, or start one (a configuration is picked)."
  (interactive)
  (if-let* ((s (drgnx-debug--session "stopped")))
      (drgnx-hub-call "debug/control" (list :session (plist-get s :id) :op "continue") #'drgnx-debug--answered)
    (let ((root (drgnx-debug-launch-root)))
      (drgnx-debug-launch-start root (drgnx-debug-launch-read-config root)))))

(drgnx-module-define 'extra/debug
                     :doc "A debugger (the hub's, Debug Adapter Protocol): breakpoints, stepping, VS Code's keys in that profile."
                     :stage 'idle
                     :teardown #'drgnx-debug--teardown
                     :setup (lambda ()
                              (drgnx-debug-mode 1)
                              (add-hook 'drgnx-hub-event-functions #'drgnx-debug-fork--event)
                              (pcase-dolist (`(,id ,title ,fn ,doc)
                                             '((debug-start "Start Debugging…" drgnx-debug-start-or-continue "Start a session, or continue the stopped one")
                                               (debug-breakpoint "Toggle Breakpoint" drgnx-debug-gutter-toggle "A breakpoint on this line, or none")
                                               (debug-breakpoint-conditional "Add Conditional Breakpoint…" drgnx-debug-breakpoint-conditional "A breakpoint that stops only when its condition holds")
                                               (debug-logpoint "Add Logpoint…" drgnx-debug-logpoint "Print a message here instead of stopping")
                                               (debug-breakpoint-enable "Enable / Disable Breakpoint" drgnx-debug-breakpoint-enable "Keep this line's breakpoint but stop or start using it")
                                               (debug-run-to-cursor "Run to Cursor" drgnx-debug-run-to-cursor "Continue until this line")
                                               (debug-step-over "Step Over" drgnx-debug-step-over "To the next line")
                                               (debug-step-in "Step Into" drgnx-debug-step-in "Into the call on this line")
                                               (debug-step-out "Step Out" drgnx-debug-step-out "Out of this function")
                                               (debug-stop "Stop Debugging" drgnx-debug-stop "End the session")
                                               (debug-restart "Restart" drgnx-debug-restart "Start the session again (the adapter's restart, else stop and start)")
                                               (debug-pause "Pause" drgnx-debug-pause "Stop the running program where it is")
                                               (debug-disconnect "Disconnect" drgnx-debug-disconnect "End an attach session and leave the program running")
                                               (debug-show-stop "Go to the Stopped Line" drgnx-debug-toolbar-show-stop "Show the line the session stopped at")
                                               (debug-pick-session "Select Debug Session…" drgnx-debug-toolbar-pick-session "Choose the session the controls act on")
                                               (debug-install-adapter "Install Adapter…" drgnx-debug-install-adapter "Download and install a debug adapter, checked against its pinned hash")
                                               (debug-fork "Fork from Here…" drgnx-debug-fork "Replay the recorded run in a sealed copy to this point, change a value or the code, and run on")
                                               (debug-fork-anyway "Fork Anyway" drgnx-debug-fork-anyway "Fork at the same pass again when a value may differ only because the fork does not replay it")
                                               (debug-fork-show "Show What-if" drgnx-debug-fork-show "A fork beside its run: matched hits, the first difference, the values after")
                                               (debug-fork-open "Open Fork" drgnx-debug-fork-open "This file as the fork has it, to edit a code what-if")
                                               (debug-fork-run "Run Fork" drgnx-debug-fork-run "Run a code what-if once its tree is edited")
                                               (debug-fork-take "Take Fork's Change…" drgnx-debug-fork-take "Each file the fork changed as a review card: Apply puts it in your buffer")
                                               (debug-fork-drop "Drop Fork" drgnx-debug-fork-drop "The fork goes, with its tree")
                                               (debug-convert-dape "Convert dape Configurations…" drgnx-debug-convert-dape-configs "Turn your dape configurations into launch configurations, once")))
                                (drgnx-command-define id :category "Debug" :title title :command fn :doc doc))
                              ;; the toolbar (drgnx-debug-toolbar.el): docked in the tab row, the status bar's segment
                              ;; after the branch, the title row's Paused chip
                              (drgnx-module-set 'drgnx-chrome-tab-row-function #'drgnx-debug-toolbar--tab-row)
                              ;; the cards follow their editor windows (moved, resized, another editor chosen)
                              (when (fboundp 'drgnx-state-subscribe)
                                (dolist (e '(windows-changed frame-resized editor-changed))
                                  (drgnx-state-subscribe e 'drgnx-debug-toolbar--replace)))
                              (drgnx-module-set 'drgnx-topline-paused-function #'drgnx-debug-toolbar-paused-p)
                              (when (fboundp 'drgnx-statusbar-define-segment)
                                (drgnx-statusbar-define-segment 'debug :fn #'drgnx-debug-toolbar--segment
                                                                :click 'drgnx-debug-view
                                                                :help "The debug session: click for Run and Debug")
                                (unless (memq 'debug drgnx-statusbar-left)
                                  (let ((tail (cdr (memq 'branch drgnx-statusbar-left))))
                                    (drgnx-module-set 'drgnx-statusbar-left
                                                      (if (memq 'branch drgnx-statusbar-left)
                                                          (append (butlast drgnx-statusbar-left (length tail)) '(debug) tail)
                                                        (cons 'debug drgnx-statusbar-left))))))
                              ;; the Debug Console tab of the panel (drgnx-debug-console.el); its input's keys in its
                              ;; own map
                              (drgnx-wb-define-tab 'panel 'debug-console :title "Debug Console")
                              (let ((in-console (lambda () (derived-mode-p 'drgnx-debug-console-mode))))
                                (pcase-dolist (`(,id ,title ,fn ,doc) drgnx-debug-console-commands)
                                  (if (memq id '(debug-console debug-console-clear))
                                      (drgnx-command-define id :category "Debug" :title title :command fn :doc doc)
                                    (drgnx-command-define id :category "Debug" :title title :command fn :doc doc
                                                          :map 'drgnx-debug-console-mode-map :when in-console))))
                              ;; Run and Debug: the sidebar view the hub builds (drgnx-debug-view.el); its row keys in
                              ;; its own map
                              (drgnx-wb-define-section 'run-and-debug :view 'debug :slot 0 :title " RUN AND DEBUG"
                                                       :buffer #'drgnx-debug-view--buffer)
                              (let ((in-view (lambda () (derived-mode-p 'drgnx-debug-view-mode))))
                                (pcase-dolist (`(,id ,title ,fn ,doc) drgnx-debug-view-commands)
                                  (if (memq id drgnx-debug-view-global-commands)
                                      (drgnx-command-define id :category "Debug" :title title :command fn :doc doc)
                                    (drgnx-command-define id :category "Debug" :title title :command fn :doc doc
                                                          :map 'drgnx-debug-view-mode-map :when in-view))))
                              ;; recorded runs: probes, the stop timeline, past stops (drgnx-debug-timeline.el)
                              (drgnx-debug-timeline-mode 1)
                              (pcase-dolist (`(,id ,title ,fn ,doc) drgnx-debug-timeline-commands)
                                (drgnx-command-define id :category "Debug" :title title :command fn :doc doc))
                              ;; which change broke it: bisect over the edit history (drgnx-debug-bisect.el)
                              (drgnx-debug-bisect-events-mode 1)
                              (pcase-dolist (`(,id ,title ,fn ,doc) drgnx-debug-bisect-commands)
                                (drgnx-command-define id :category "Debug" :title title :command fn :doc doc))
                              ;; where did this come from: the origin trail (drgnx-debug-origin.el)
                              (drgnx-debug-origin-events-mode 1)
                              (pcase-dolist (`(,id ,title ,fn ,doc) drgnx-debug-origin-commands)
                                (drgnx-command-define id :category "Debug" :title title :command fn :doc doc))
                              ;; debugging with an agent: its hypotheses and fixes (drgnx-debug-investigation.el)
                              (add-hook 'drgnx-hub-event-functions #'drgnx-debug-investigation--event)
                              (pcase-dolist (`(,id ,title ,fn ,doc)
                                             '((debug-investigation "Show Investigation" drgnx-debug-investigation-show "An agent's hypotheses with their evidence, and the fixes it offers")
                                               (debug-investigation-explain "Explain Investigation…" drgnx-debug-investigation-explain "Ask the agent debugging with you to tell its investigation in its chat")
                                               (debug-review-fix "Review Agent's Fix" drgnx-debug-investigation-review-fix "The fix an agent offers, which passed in a fresh fork, as a diff against your buffers")
                                               (debug-accept-fix "Accept Agent's Fix" drgnx-debug-investigation-accept-fix "Put the agent's fix in your buffers as its change (undoable, not saved)")))
                                (drgnx-command-define id :category "Debug" :title title :command fn :doc doc))))

(provide 'drgnx-debug)
;;; drgnx-debug.el ends here
