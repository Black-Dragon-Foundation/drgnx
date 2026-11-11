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
(require 'drgnx-debug-gutter (expand-file-name "drgnx-debug-gutter" (file-name-directory (macroexp-file-name))))
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
      (add-hook 'find-file-hook #'drgnx-debug--gutter-on)
    (remove-hook 'find-file-hook #'drgnx-debug--gutter-on))
  (dolist (b (buffer-list))
    (with-current-buffer b
      (cond ((and drgnx-debug-mode buffer-file-name) (drgnx-debug-gutter-mode 1))
            ((and (not drgnx-debug-mode) drgnx-debug-gutter-mode) (drgnx-debug-gutter-mode -1))))))

(defun drgnx-debug--teardown ()
  "The session keys go with the module (a running session turned them on, not the setup), and the column."
  (drgnx-debug-session-mode -1)
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
                              (drgnx-debug-mode 1)
                              (pcase-dolist (`(,id ,title ,fn ,doc)
                                             '((debug-start "Start Debugging…" drgnx-debug-start-or-continue "Start a session, or continue the stopped one")
                                               (debug-breakpoint "Toggle Breakpoint" drgnx-debug-gutter-toggle "A breakpoint on this line, or none")
                                               (debug-breakpoint-conditional "Add Conditional Breakpoint…" drgnx-debug-breakpoint-conditional "A breakpoint that stops only when its condition holds")
                                               (debug-logpoint "Add Logpoint…" drgnx-debug-logpoint "Print a message here instead of stopping")
                                               (debug-breakpoint-enable "Enable / Disable Breakpoint" drgnx-debug-breakpoint-enable "Keep this line's breakpoint but stop or start using it")
                                               (debug-run-to-cursor "Run to Cursor" drgnx-debug-run-to-cursor "Continue until this line")
                                               (debug-step-over "Step Over" dape-next "To the next line")
                                               (debug-step-in "Step Into" dape-step-in "Into the call on this line")
                                               (debug-step-out "Step Out" dape-step-out "Out of this function")
                                               (debug-stop "Stop Debugging" dape-kill "End the session")))
                                (drgnx-command-define id :category "Debug" :title title :command fn :doc doc))))

(provide 'drgnx-debug)
;;; drgnx-debug.el ends here
