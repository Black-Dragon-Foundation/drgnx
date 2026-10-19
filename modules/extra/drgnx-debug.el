;;; drgnx-debug.el --- Module extra/debug: a debugger (dape, the Debug Adapter Protocol) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Debugging through dape — the Debug Adapter Protocol, so the same adapters as VS Code (debugpy, the JS debugger,
;; delve, codelldb, …) — with VS Code's keys in that profile: F5 starts (or continues), F9 toggles a breakpoint,
;; F10 steps over, F11 steps into while a session runs (Zen Mode otherwise), S-F11 steps out, S-F5 stops.  dape's
;; windows go to the right, so the panel stays the workbench's.  See docs/guide/editing.md.

;;; Code:
(require 'drgnx-modules)
(require 'drgnx-registry)
(declare-function dape--live-connection "dape")
(declare-function dape "dape")
(declare-function dape-continue "dape")
(defvar dape-active-mode)
(defvar dape-buffer-window-arrangement)

(defvar drgnx-debug-session-map (make-sparse-keymap)
  "Keys while a debugging session runs (key profiles: `:map drgnx-debug-session-map').")

(define-minor-mode drgnx-debug-session-mode
  "On while a debugging session runs: its keys (`drgnx-debug-session-map') come first."
  :global t :group 'drgnx :keymap drgnx-debug-session-map)

(defun drgnx-debug--follow-session ()
  "`dape-active-mode-hook': the session keys while a session runs."
  (drgnx-debug-session-mode (if (and (boundp 'dape-active-mode) dape-active-mode) 1 -1)))

(defun drgnx-debug--teardown ()
  "The session keys go with the module (a running session turned them on, not the setup)."
  (drgnx-debug-session-mode -1))

(defun drgnx-debug-start-or-continue ()
  "Continue the stopped session, or start one (dape asks which configuration)."
  (interactive)
  (if (and (fboundp 'dape--live-connection) (dape--live-connection 'stopped t))
      (call-interactively #'dape-continue)
    (call-interactively #'dape)))

(drgnx-module-define 'extra/debug
                     :doc "A debugger (dape, Debug Adapter Protocol): breakpoints, stepping, VS Code's keys in that profile."
                     :stage 'idle :packages '(dape)
                     :teardown #'drgnx-debug--teardown
                     :setup (lambda ()
                              (require 'dape)
                              (drgnx-module-set 'dape-buffer-window-arrangement 'right)   ; the panel stays the workbench's
                              (add-hook 'dape-active-mode-hook #'drgnx-debug--follow-session)
                              (pcase-dolist (`(,id ,title ,fn ,doc)
                                             '((debug-start "Start Debugging…" drgnx-debug-start-or-continue "Start a session, or continue the stopped one")
                                               (debug-breakpoint "Toggle Breakpoint" dape-breakpoint-toggle "A breakpoint on this line, or none")
                                               (debug-step-over "Step Over" dape-next "To the next line")
                                               (debug-step-in "Step Into" dape-step-in "Into the call on this line")
                                               (debug-step-out "Step Out" dape-step-out "Out of this function")
                                               (debug-stop "Stop Debugging" dape-kill "End the session")))
                                (drgnx-command-define id :category "Debug" :title title :command fn :doc doc))))

(provide 'drgnx-debug)
;;; drgnx-debug.el ends here
