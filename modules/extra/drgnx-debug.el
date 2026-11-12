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
(require 'drgnx-debug-origin (expand-file-name "drgnx-debug-origin" (file-name-directory (macroexp-file-name))))
(declare-function drgnx-hub-call "drgnx-hub-client")
(defvar drgnx-hub-event-functions)

(defvar drgnx-debug-session-map (make-sparse-keymap)
  "Keys while a debugging session runs (key profiles: `:map drgnx-debug-session-map').")

(define-minor-mode drgnx-debug-session-mode
  "On while a debugging session runs: its keys (`drgnx-debug-session-map') come first."
  :global t :group 'drgnx :keymap drgnx-debug-session-map)

(defvar drgnx-debug--sessions nil
  "The debug sessions as the hub's `debug-state' last said: plists (:id :name :parent :root :state …).")

(defun drgnx-debug--event (event data)
  "`drgnx-hub-event-functions': `debug-state' gives the sessions, and the session keys follow them."
  (when (equal event "debug-state")
    (setq drgnx-debug--sessions (append (plist-get data :sessions) nil))
    (drgnx-debug-session-mode (if drgnx-debug--sessions 1 -1))))

(defun drgnx-debug--session (&optional state)
  "This project's session in STATE, or (STATE nil) its stopped one, else its first; nil when it has none."
  (let ((mine (seq-filter (lambda (s) (equal (plist-get s :root) (drgnx-debug-launch-root))) drgnx-debug--sessions)))
    (or (seq-find (lambda (s) (equal (plist-get s :state) (or state "stopped"))) mine)
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

(defvar drgnx-debug-mode-map (make-sparse-keymap)
  "Keys of the module (key profiles: `:map drgnx-debug-mode-map'); the Emacs profile's `C-x C-a' keys live here, so a
loaded gud's own `C-x C-a' in `global-map' loses to them.")

(defun drgnx-debug--gutter-on ()
  "`find-file-hook': a file's buffer gets the breakpoint column."
  (when buffer-file-name (drgnx-debug-gutter-mode 1)))

(define-minor-mode drgnx-debug-mode
  "The module's own state: its keys (`drgnx-debug-mode-map') and the breakpoint column in every file's buffer."
  :global t :group 'drgnx :keymap drgnx-debug-mode-map
  (if drgnx-debug-mode
      (progn (add-hook 'find-file-hook #'drgnx-debug--gutter-on)
             (add-hook 'drgnx-hub-event-functions #'drgnx-debug--event))
    (remove-hook 'find-file-hook #'drgnx-debug--gutter-on)
    (remove-hook 'drgnx-hub-event-functions #'drgnx-debug--event)
    (setq drgnx-debug--sessions nil))
  (dolist (b (buffer-list))
    (with-current-buffer b
      (cond ((and drgnx-debug-mode buffer-file-name) (drgnx-debug-gutter-mode 1))
            ((and (not drgnx-debug-mode) drgnx-debug-gutter-mode) (drgnx-debug-gutter-mode -1))))))

(defun drgnx-debug--teardown ()
  "The session keys go with the module (a running session turned them on, not the setup), and the column."
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
                                               (debug-install-adapter "Install Adapter…" drgnx-debug-install-adapter "Download and install a debug adapter, checked against its pinned hash")
                                               (debug-fork "Fork from Here…" drgnx-debug-fork "Replay the recorded run in a sealed copy to this point, change a value or the code, and run on")
                                               (debug-fork-show "Show What-if" drgnx-debug-fork-show "A fork beside its run: matched hits, the first difference, the values after")
                                               (debug-fork-open "Open Fork" drgnx-debug-fork-open "This file as the fork has it, to edit a code what-if")
                                               (debug-fork-run "Run Fork" drgnx-debug-fork-run "Run a code what-if once its tree is edited")
                                               (debug-fork-take "Take Fork's Change…" drgnx-debug-fork-take "Each file the fork changed as a review card: Apply puts it in your buffer")
                                               (debug-fork-drop "Drop Fork" drgnx-debug-fork-drop "The fork goes, with its tree")
                                               (debug-convert-dape "Convert dape Configurations…" drgnx-debug-convert-dape-configs "Turn your dape configurations into launch configurations, once")))
                                (drgnx-command-define id :category "Debug" :title title :command fn :doc doc))
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
                                (drgnx-command-define id :category "Debug" :title title :command fn :doc doc))))

(provide 'drgnx-debug)
;;; drgnx-debug.el ends here
