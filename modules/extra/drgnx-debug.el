;;; drgnx-debug.el --- Module extra/debug: a debugger (the hub's, the Debug Adapter Protocol) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Debugging through the hub's DAP client (docs/develop/debugging.md) — the Debug Adapter Protocol, so the same
;; adapters as VS Code (debugpy, the JS debugger, delve, CodeLLDB, …) — with VS Code's keys in that profile: F5 starts
;; (or continues), F9 toggles a breakpoint, F10 steps over, F11 steps into while a session runs (Zen Mode otherwise),
;; S-F11 steps out, S-F5 stops.  The sessions are what the hub's `debug-state' last said.  See docs/guide/debugging.md.

;;; Code:
(require 'seq)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-file)
(require 'drgnx-debug-gutter (expand-file-name "drgnx-debug-gutter" (file-name-directory (macroexp-file-name))))
(require 'drgnx-debug-fork (expand-file-name "drgnx-debug-fork" (file-name-directory (macroexp-file-name))))
(require 'drgnx-debug-timeline (expand-file-name "drgnx-debug-timeline" (file-name-directory (macroexp-file-name))))
(require 'drgnx-debug-bisect (expand-file-name "drgnx-debug-bisect" (file-name-directory (macroexp-file-name))))
(require 'drgnx-debug-share (expand-file-name "drgnx-debug-share" (file-name-directory (macroexp-file-name))))
(require 'drgnx-debug-investigation
         (expand-file-name "drgnx-debug-investigation" (file-name-directory (macroexp-file-name))))
(require 'drgnx-debug-origin (expand-file-name "drgnx-debug-origin" (file-name-directory (macroexp-file-name))))
(require 'drgnx-debug-toolbar (expand-file-name "drgnx-debug-toolbar" (file-name-directory (macroexp-file-name))))
(require 'drgnx-debug-view (expand-file-name "drgnx-debug-view" (file-name-directory (macroexp-file-name))))
(require 'drgnx-debug-console (expand-file-name "drgnx-debug-console" (file-name-directory (macroexp-file-name))))
(require 'drgnx-debug-memory (expand-file-name "drgnx-debug-memory" (file-name-directory (macroexp-file-name))))
(require 'drgnx-debug-disassembly
         (expand-file-name "drgnx-debug-disassembly" (file-name-directory (macroexp-file-name))))
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
follow them, a running session's stop marks go), `debug-frame' marks and opens a stop's line, `debug-inline' shows
its values at line ends, `debug-ended' takes its marks away, `debug-output' goes to the debug console,
`debug-terminal' shows a task's or the program's terminal; the disassembly view follows `debug-frame' and a
session's instruction breakpoints (`debug-breakpoints' with a session and no path)."
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
    ("debug-frame"
     (drgnx-debug-disassembly-frame data)
     (drgnx-debug-gutter-show-frame data))
    ("debug-breakpoints"
     (when (and (plist-get data :session) (not (plist-get data :path)))
       (drgnx-debug-disassembly-breakpoints data)))
    ("debug-inline" (drgnx-debug-gutter-inline data))
    ("debug-ended" (drgnx-debug-gutter-stop-clear (plist-get data :session)))
    ("debug-terminal" (drgnx-debug-launch-show-terminal data))))

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
    (drgnx-hub-call "debug/control"
                    (append (list :session (plist-get s :id) :op op)
                            ;; the disassembly view has focus: one instruction a step
                            (and (member op '("next" "step-in" "step-out")) (drgnx-debug-disassembly-instruction-step-p)
                                 (list :granularity "instruction")))
                    #'drgnx-debug--answered)))

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
  (drgnx-debug-memory--teardown)
  (drgnx-debug-disassembly--teardown)
  (drgnx-debug-session-mode -1)
  (drgnx-debug-timeline-mode -1)
  (when-let* ((card (get-buffer drgnx-debug-share-buffer))) (kill-buffer card))
  (drgnx-debug-bisect-events-mode -1)
  (drgnx-debug-origin-events-mode -1)
  (drgnx-debug-select-config-forget)
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
  "Continue this project's stopped session, or start one (the selected configuration, else one is picked)."
  (interactive)
  (if-let* ((s (drgnx-debug--session "stopped")))
      (drgnx-hub-call "debug/control" (list :session (plist-get s :id) :op "continue") #'drgnx-debug--answered)
    (let ((root (drgnx-debug-launch-root)))
      (drgnx-debug-launch-start root (drgnx-debug--config root)))))

;;;; Run Without Debugging, configurations, launch.json, function breakpoints, evaluate (spec §14)

(defvar drgnx-debug--selected (make-hash-table :test #'equal)
  "Project root → the configuration Select Debug Configuration chose: Start uses it without asking.  As many entries
as projects the user selected in, cleared by the module's teardown.")

(defun drgnx-debug--config (root)
  "The configuration to start in ROOT: the selected one, else picked."
  (or (gethash root drgnx-debug--selected) (drgnx-debug-launch-read-config root)))

(defun drgnx-debug-select-config ()
  "Pick this project's configuration once: Start Debugging and Run Without Debugging use it without asking."
  (interactive)
  (let* ((root (drgnx-debug-launch-root)) (id (drgnx-debug-launch-read-config root)))
    (puthash root id drgnx-debug--selected)
    id))

(defun drgnx-debug-select-config-forget ()
  "Forget every project's selected configuration (Start asks again)."
  (clrhash drgnx-debug--selected))

(defun drgnx-debug-run-no-debug ()
  "Run the configuration without the debugger: the adapter launches it with `noDebug'; breakpoints do not stop it."
  (interactive)
  (let ((root (drgnx-debug-launch-root)))
    (drgnx-debug-launch-start root (drgnx-debug--config root) t)))

(defun drgnx-debug-open-launch-json ()
  "Open this project's .vscode/launch.json, made with an empty list of configurations when there is none."
  (interactive)
  (let ((file (expand-file-name ".vscode/launch.json" (drgnx-debug-launch-root))))
    (unless (file-exists-p file)
      (make-directory (file-name-directory file) t)
      (drgnx-file-write-text file "{\n  \"version\": \"0.2.0\",\n  \"configurations\": [\n  ]\n}\n"))
    (find-file file)
    (goto-char (point-min))
    (when (search-forward "\"configurations\": [" nil t) (forward-line 1))))

(defun drgnx-debug-breakpoints-toggle-all ()
  "Turn every breakpoint of the project off when any is on, else all on."
  (interactive)
  (drgnx-hub-call "debug/breakpoints" (list :root (drgnx-debug-launch-root) :op (list :op "toggle-all"))
                  #'drgnx-debug--answered))

(defun drgnx-debug-function-breakpoint (name)
  "Stop when the function NAME is called (a function breakpoint of the project)."
  (interactive (list (read-string "Function breakpoint: " (thing-at-point 'symbol t))))
  (when (string-empty-p (string-trim name)) (user-error "No function named"))
  (drgnx-hub-call "debug/breakpoints" (list :root (drgnx-debug-launch-root)
                                            :op (list :op "add-function" :name (string-trim name)))
                  #'drgnx-debug--answered))

(defun drgnx-debug-hover-eldoc (_callback)
  "Nothing, for the echo area: an expression is evaluated only when the mouse rests on it (quick help's card asks
`drgnx-debug-hover-doc' instead, `drgnx-quickhelp-fuller-functions')."
  nil)

(defun drgnx-debug-hover-doc (callback)
  "The data tip of the expression at point (the selection when point is in it) for quick help's card: evaluated
in the stopped session of this project (`hover'), CALLBACK given \"EXPR = VALUE  (TYPE)\" when it comes, or nil
on an error.  Nil (nothing asked) without a stopped session or an expression."
  (when-let* ((s (drgnx-debug--session "stopped"))
              (expr (if (and (use-region-p) (<= (region-beginning) (point) (region-end)))
                        (buffer-substring-no-properties (region-beginning) (region-end))
                      (let ((mark-active nil)) (drgnx-debug--expression-at-point)))))
    (drgnx-hub-call "debug/evaluate" (list :session (plist-get s :id) :expr expr :context "hover")
                    (lambda (r error)
                      (funcall callback
                               (unless error
                                 (format "%s = %s%s" expr (plist-get r :result)
                                         (if-let* ((ty (plist-get r :type))) (format "  (%s)" ty) ""))))))
    t))

(defun drgnx-debug--expression-at-point ()
  "The active region's text, else the symbol at point with the member chain before it (`self.items'); nil if none."
  (if (use-region-p)
      (buffer-substring-no-properties (region-beginning) (region-end))
    (when-let* ((b (bounds-of-thing-at-point 'symbol)))
      (save-excursion
        (goto-char (car b))
        (while (and (memq (char-before) '(?.)) (progn (backward-char) (skip-syntax-backward "w_") t)))
        (buffer-substring-no-properties (point) (cdr b))))))

(defun drgnx-debug-evaluate (expr)
  "Evaluate EXPR (the selection, else the expression at point) in the Debug Console, in the stopped frame; the
console's tab shows without taking the focus."
  (interactive (list (or (drgnx-debug--expression-at-point) (read-string "Evaluate: "))))
  (unless (drgnx-debug--session) (user-error "No debug session to evaluate in"))
  (if (fboundp 'drgnx-debug-console-evaluate)
      (drgnx-debug-console-evaluate expr)
    (user-error "The Debug Console cannot evaluate from here yet")))

(defun drgnx-debug-show-value ()
  "Show the value of the selection, else of the expression at point, in the echo area (the adapter's hover)."
  (interactive)
  (let ((expr (or (drgnx-debug--expression-at-point) (user-error "No expression at point")))
        (s (or (drgnx-debug--session "stopped") (user-error "No stopped debug session"))))
    (let ((r (drgnx-hub-call-sync "debug/evaluate" (list :session (plist-get s :id) :expr expr :context "hover") 5)))
      (message "%s = %s%s" expr (plist-get r :result)
               (if-let* ((ty (plist-get r :type))) (format "  (%s)" ty) "")))))

(drgnx-module-define 'extra/debug
                     :doc "A debugger (the hub's, Debug Adapter Protocol): breakpoints, stepping, VS Code's keys in that profile."
                     :stage 'idle
                     :teardown #'drgnx-debug--teardown
                     :setup (lambda ()
                              (drgnx-debug-mode 1)
                              (add-hook 'drgnx-hub-event-functions #'drgnx-debug-fork--event)
                              ;; data tips: quick help's card asks the fuller one when the mouse rests on an expression
                              (add-hook 'eldoc-documentation-functions #'drgnx-debug-hover-eldoc)
                              (drgnx-module-alist-put 'drgnx-quickhelp-fuller-functions
                                                      'drgnx-debug-hover-eldoc 'drgnx-debug-hover-doc)
                              (pcase-dolist (`(,id ,title ,fn ,doc)
                                             '((debug-start "Start Debugging…" drgnx-debug-start-or-continue "Start a session, or continue the stopped one")
                                               (debug-breakpoint "Toggle Breakpoint" drgnx-debug-gutter-toggle "A breakpoint on this line, or none")
                                               (debug-breakpoint-conditional "Add Conditional Breakpoint…" drgnx-debug-breakpoint-conditional "A breakpoint that stops only when its condition holds")
                                               (debug-logpoint "Add Logpoint…" drgnx-debug-logpoint "Print a message here instead of stopping")
                                               (debug-inline-breakpoint "Inline Breakpoint" drgnx-debug-inline-breakpoint "A breakpoint at this column of the line, or none")
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
                                               (debug-convert-dape "Convert dape Configurations…" drgnx-debug-convert-dape-configs "Turn your dape configurations into launch configurations, once")
                                               (debug-run-no-debug "Run Without Debugging" drgnx-debug-run-no-debug "Run the configuration without the debugger: breakpoints do not stop it")
                                               (debug-select-config "Select Debug Configuration…" drgnx-debug-select-config "The configuration Start uses in this project, without asking")
                                               (debug-open-launch-json "Open launch.json" drgnx-debug-open-launch-json "This project's launch configurations (made when there are none)")
                                               (debug-breakpoints-toggle-all "Toggle All Breakpoints" drgnx-debug-breakpoints-toggle-all "Every breakpoint off when any is on, else all on")
                                               (debug-function-breakpoint "Add Function Breakpoint…" drgnx-debug-function-breakpoint "Stop when a function is called")
                                               (debug-evaluate "Evaluate in Debug Console" drgnx-debug-evaluate "The selection, or the expression at point, in the stopped frame")
                                               (debug-show-value "Show Value at Point" drgnx-debug-show-value "The value of the expression at point, in the echo area")))
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
                              ;; own map.  The panel is the workbench's: without it (a bare Emacs) there is no tab
                              ;; to define, as for Review's
                              (when (fboundp 'drgnx-wb-define-tab)
                                (drgnx-wb-define-tab 'panel 'debug-console :title "Debug Console"))
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
                              ;; the memory view (drgnx-debug-memory.el): its keys in its own map
                              (let ((in-memory (lambda () (derived-mode-p 'drgnx-debug-memory-mode))))
                                (pcase-dolist (`(,id ,title ,fn ,doc) drgnx-debug-memory-commands)
                                  (drgnx-command-define id :category "Debug" :title title :command fn :doc doc
                                                        :map 'drgnx-debug-memory-mode-map :when in-memory)))
                              ;; the disassembly view (drgnx-debug-disassembly.el): Open Disassembly View, and its
                              ;; keys in its own map
                              (drgnx-command-define 'debug-open-disassembly :category "Debug"
                                                    :title "Open Disassembly View" :command #'drgnx-debug-open-disassembly
                                                    :doc "The instructions around the stopped session's current frame")
                              (let ((in-dis (lambda () (derived-mode-p 'drgnx-debug-disassembly-mode))))
                                (pcase-dolist (`(,id ,title ,fn ,doc) drgnx-debug-disassembly-commands)
                                  (drgnx-command-define id :category "Debug" :title title :command fn :doc doc
                                                        :map 'drgnx-debug-disassembly-mode-map :when in-dis)))
                              ;; recorded runs: probes, the stop timeline, past stops (drgnx-debug-timeline.el)
                              (drgnx-debug-timeline-mode 1)
                              (pcase-dolist (`(,id ,title ,fn ,doc) drgnx-debug-timeline-commands)
                                (drgnx-command-define id :category "Debug" :title title :command fn :doc doc))
                              ;; sending a run: Send Run…, its card, Open Sent Run… (drgnx-debug-share.el)
                              (let ((in-card (lambda () (derived-mode-p 'drgnx-debug-share-mode))))
                                (pcase-dolist (`(,id ,title ,fn ,doc) drgnx-debug-share-commands)
                                  (if (memq id '(debug-send-run debug-open-sent-run))
                                      (drgnx-command-define id :category "Debug" :title title :command fn :doc doc)
                                    (drgnx-command-define id :category "Debug" :title title :command fn :doc doc
                                                          :map 'drgnx-debug-share-mode-map :when in-card))))
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
