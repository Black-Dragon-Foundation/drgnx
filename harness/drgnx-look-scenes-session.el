;;; drgnx-look-scenes-session.el --- The look's scenes, set up inside a harness session -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Loaded into a `drgnx ui look-scenes' session (harness/drgnx-look-scenes.el) through its socket.  Each scene
;; function puts the frame in the state one approved mockup shows (docs/develop/harness.md, "Look scenes") and
;; answers JSON.  Nothing here asserts a pixel: the pictures are put beside the mockups and looked at.  Errors are
;; caught per step and returned, so one missing package leaves the other scenes standing.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-palette)                ; the palette scene's commands and history
(declare-function drgnx-pane-show "drgnx-panes")
(declare-function drgnx-pkg-jit-guard "drgnx-pkg-activate")
(declare-function drgnx-panel-replay--wait "panel-replay-fixture")
(declare-function drgnx-agent-panel-cards--permissions "drgnx-agent-panel-cards")
(declare-function drgnx-agent-panel-act "drgnx-agent-panel-steps")
(declare-function drgnx-uitest-run "drgnx-uitest")
(declare-function drgnx-uitest-click-events "drgnx-uitest")
(defvar pixel-scroll-precision-mode)
(declare-function pixel-scroll-precision-mode "pixel-scroll")

(declare-function drgnx-uitest--json "drgnx-uitest")
(declare-function drgnx-trust-folder "drgnx-trust")
(declare-function drgnx-wb-view-explorer "drgnx-wb")
(declare-function drgnx-wb-focus-editor "drgnx-wb")
(declare-function drgnx-wb-editor-window "drgnx-wb")
(declare-function drgnx-modules-retry-waiting "drgnx-modules")
(declare-function drgnx-modules-report "drgnx-modules")
(declare-function drgnx-panel-replay-up "panel-replay-fixture")
(declare-function drgnx-work-space-open "drgnx-work-space")
(declare-function drgnx-statusbar-note-tests "drgnx-statusbar")
(declare-function magit-status-setup-buffer "magit-status")
(declare-function drgnx-area--tab-row "drgnx-area" (area))
(defvar drgnx-panel-replay-prefix)
(declare-function drgnx-view-env--envs "drgnx-view-env")
(defvar drgnx-panel-replay-project)
(defvar package-directory-list)
(defvar magit-save-repository-buffers)
(declare-function drgnx-chrome--note "drgnx-chrome")
(declare-function drgnx-chrome-note-preview "drgnx-chrome")
(declare-function drgnx-start-show "drgnx-start")
(declare-function drgnx-wb--selected-changed "drgnx-wb")
(declare-function drgnx-wb--tail-paint "drgnx-wb")
(declare-function drgnx-wb-row-hover-face "drgnx-wb")
(declare-function diff-refine-hunk "diff-mode")
(declare-function diff-hunk-next "diff-mode")
(defvar drgnx-explorer-buffer-name)
(defvar drgnx-start-buffer-name)

;; drgnx-gateway.el's lines 201-232 as the mockups show them (window-dark.html), the working copy; the committed copy
;; has the two lines the agent changed (215-217) as they were before
(defconst drgnx-look-scene--gateway-tail
  ";;;; Replies

(defvar drgnx-gateway--pending (make-hash-table :test #'eq)
  \"Client process → the replies still to send, oldest first.\")

(defun drgnx-gateway--queue (p reply)
  \"Keep REPLY for P until P can take it.\"
  (let ((old (gethash p drgnx-gateway--pending)))
    (puthash p (nconc (gethash p drgnx-gateway--pending) (list reply))
             drgnx-gateway--pending)))

;; Send the reply, unless the client went away.
(defun drgnx-gateway--reply (p reply)
  \"Send REPLY to the client process P.\"
  (if (process-live-p p)
      (process-send-string p reply)
    (drgnx-gateway--queue p reply)))

(defun drgnx-gateway--accept (server client _msg)
  \"Take CLIENT from SERVER: a filter, a sentinel, nothing else.\"
  (set-process-filter client #'drgnx-gateway--filter)
  (set-process-sentinel client #'drgnx-gateway--gone)
  (process-put client 'drgnx-server server))

(defun drgnx-gateway--gone (p _event)
  \"Forget P's queue once it closed.\"
  (unless (process-live-p p)
    (remhash p drgnx-gateway--pending)
    (drgnx-gateway--log 'closed p)))

(provide 'drgnx-gateway)
;;; drgnx-gateway.el ends here
"
  "The mockup's lines 201-232 of core/drgnx-gateway.el.")

(defun drgnx-look-scene--gateway (committed)
  "core/drgnx-gateway.el: 200 lines of a gateway, then the mockup's tail (COMMITTED: as before the agent's edit)."
  (let ((head (list ";;; drgnx-gateway.el --- The hub's client gateway -*- lexical-binding: t -*-" ""
                    ";;; Commentary:" ";; Clients connect, send requests and take replies." "" ";;; Code:" "")))
    (dotimes (i 34)
      (setq head (append head (list (format "(defun drgnx-gateway--step-%d (p msg)" i)
                                    (format "  \"Handle step %d of MSG from P.\"" i)
                                    "  (when (process-live-p p)"
                                    (format "    (process-put p 'drgnx-step %d)" i)
                                    "    (drgnx-gateway--reply p msg)))" ""))))
    ;; whole definitions only (32 of them end on line 199): a definition cut open would hold everything after it
    (setq head (append (seq-take head 199) (list "")))
    (concat (mapconcat #'identity head "\n") "\n"
            (if committed
                (string-replace "  (if (process-live-p p)\n      (process-send-string p reply)\n    (drgnx-gateway--queue p reply)))"
                                "  (when (process-live-p p)\n      (process-send-string p reply)))"
                                drgnx-look-scene--gateway-tail)
              drgnx-look-scene--gateway-tail))))

(defconst drgnx-look-scene--files
  '(("core/drgnx-agents.el" . ";;; drgnx-agents.el --- Agents -*- lexical-binding: t -*-\n(provide 'drgnx-agents)\n")
    ("core/drgnx-job.el" . ";;; drgnx-job.el --- Jobs -*- lexical-binding: t -*-\n(provide 'drgnx-job)\n")
    ("core/drgnx-palette.el" . ";;; drgnx-palette.el --- The palette -*- lexical-binding: t -*-\n(provide 'drgnx-palette)\n")
    ("core/drgnx-ui-kit.el" . ";;; drgnx-ui-kit.el --- The UI kit -*- lexical-binding: t -*-\n(provide 'drgnx-ui-kit)\n")
    ("docs/index.md" . "# drgnx\n")
    ("modules/README.md" . "# Modules\n")
    ("runtime/Cargo.toml" . "[workspace]\n")
    ("test/unit/gateway-test.el" . ";;; gateway-test.el --- The gateway's tests -*- lexical-binding: t -*-\n(require 'ert)\n")
    ("test/unit/hub-test.el" . ";;; hub-test.el --- The hub's tests -*- lexical-binding: t -*-\n(require 'ert)\n")
    ("wb/drgnx-wb.el" . ";;; drgnx-wb.el --- The workbench -*- lexical-binding: t -*-\n(provide 'drgnx-wb)\n")
    ("Makefile" . "all:\n\tbin/drgnx build\n")
    ("README.md" . "# drgnx\n")
    (".gitignore" . "drgnx.lock.eld\n")
    ("docs/p2-verify.sh" . "#!/bin/sh\nL=/tmp/l\npython3 - <<PY\nimport ast, subprocess\nFILES=[\"a.py\",\"b.py\"]\ndef els(src):\n    out={}; imp=[]\n    return out\nfor p in FILES:\n    print(\"moved\", p)\nPY\necho \"AST check: $(head -1 $L/ast.log)\"\ngit diff --quiet HEAD -- docs; echo \"changed: $?\"\n"))
  "The project's other files (path . text), committed; the shell script with a heredoc is the user's case.")

(defun drgnx-look-scene--git (dir &rest args)
  (let ((default-directory dir))
    (unless (zerop (apply #'call-process "git" nil nil nil "-c" "user.name=you" "-c" "user.email=you@localhost"
                          "-c" "commit.gpgsign=false" args))
      (error "git %S failed in %s" args dir))))

(defun drgnx-look-scene-project (dir)
  "Make the mockups' project in DIR (a directory named drgnx) and return it: on branch main two commits ahead of its
remote (DIR/../drgnx-origin.git), core/drgnx-gateway.el and test/unit/gateway-test.el modified, test/unit/jobs-test.el
untracked, drgnx.lock.eld ignored."
  (let ((proj (file-name-as-directory (expand-file-name dir))))
    (make-directory proj t)
    (cl-flet ((put (file text) (let ((f (expand-file-name file proj)))
                                 (make-directory (file-name-directory f) t)
                                 (write-region text nil f nil 'silent))))
      (pcase-dolist (`(,file . ,text) drgnx-look-scene--files) (put file text))
      (put "core/drgnx-gateway.el" (drgnx-look-scene--gateway t))
      (drgnx-look-scene--git proj "init" "-q" "-b" "main")
      (drgnx-look-scene--git proj "add" "-A")
      (drgnx-look-scene--git proj "commit" "-q" "-m" "init")
      ;; main ↑2: pushed to a remote beside the project, then two commits more
      (let ((origin (expand-file-name "../drgnx-origin.git" proj)))
        (drgnx-look-scene--git proj "init" "-q" "--bare" origin)
        (drgnx-look-scene--git proj "remote" "add" "origin" origin)
        (drgnx-look-scene--git proj "push" "-q" "-u" "origin" "main"))
      (dolist (file '("README.md" "docs/index.md"))
        (put file (concat (cdr (assoc file drgnx-look-scene--files)) "\n"))
        (drgnx-look-scene--git proj "commit" "-q" "-am" (format "docs: %s" file)))
      (put "core/drgnx-gateway.el" (drgnx-look-scene--gateway nil))
      (put "test/unit/gateway-test.el"
           (concat (cdr (assoc "test/unit/gateway-test.el" drgnx-look-scene--files))
                   "(ert-deftest gateway/reply-after-close () (should t))\n"))
      (put "test/unit/jobs-test.el" ";;; jobs-test.el --- The jobs' tests -*- lexical-binding: t -*-\n")
      (put "drgnx.lock.eld" "()\n"))
    proj))

(defvar drgnx-look-scene--project nil "The scene's project directory (a git repository).")
(defvar drgnx-look-scene--errors nil "The errors of the current step, newest first.")
(defvar drgnx-look-scene--panel nil "The agent panel's buffer, once the mock agent ran.")
(defvar drgnx-look-scene-seed "1"
  "What the session's hub seeds (`RATATOSKR_SEED_SCENE', the hub's `orch::scene'), set by `drgnx look-scenes' from the
scenes' :seed: \"1\", the plan run with the Flow's one agent (the mock agent's hub seeds it too), or \"map\", the Work
map's graph of work-space-dark.html.  The two put different agents on the map, so they cannot share a hub, and the
scenes of each are drawn in a session of their own.")

(defvar drgnx-look-scene-limits
  '((window-dark "the agent panel opens as a tab of the editor group, not the right island (look step 8)"
                 "the title row counts 1 agent, not 2: the scene starts one mock agent"
                 "no agent badges (C, R) in the Explorer: agent system part 3 (G9)"
                 "the status bar's `2 waiting on you' is the mockup's `● 1 needs you': two real items wait (the mock
agent's permission and the seeded run's held card), and drgnx words it so"
                 "the status bar's problems and `● eglot' are the scene's stand-ins (a Flymake backend with the mockup's
two problems, an eglot connection to no language server), drawn by the segments' own code"
                 "the status bar's agent is `● replay-… editing', not `● Claude editing': the mock agent's session is
named as drgnx names every session (its profile, `replay', and an id)")
    (agent-panel "the mockup is the Work space (mission strip, Board, Timeline: G9, other plans); compare its right-hand panel"
                 "the panel opens as a tab of the editor group, not the right island (look step 8)"
                 "the mock agent's panel shows no turn yet (replay idle): look step 8")
    (magit "the scene's repository is the window mockups' (main, nothing staged, one commit); the Magit mockup's
branch gateway-queue, staged file and history come with the Magit adapter (look step 7)"
           "the mockup's right-hand org card and floating transient are not opened by the scene")
    (notebook-dark "the card is a Glitnir ring block (radius 10, the cell faces' band as its fill) on a line that has blocks, the band look elsewhere; against the mockup: (1) the output rows sit outside the ring, because a block takes the rows by their start position and a tail's rows start where the next cell's header does (Glitnir needs to count the rows of overlay strings at the block's END), (2) no card shadow (a ring is one 1 px line), (3) no 8 px gap between cards (a block has no inset above or below), (4) the focused card has one ring, not the mockup's inner focus ring and outer border step"
                   "the mockup's notebook toolbar (Run all, Restart, Clear outputs, the kernel's state) and the cell's hover icons (up, down, delete) are not drawn: the commands are in the palette and keys"
                   "the header is the Lisp stopgap (a chip for the run button and the type); the hub's head string replaces it"
                   "the source takes its syntax colours from tree-sitter where the language has a grammar and a tree-sitter mode (the scene's image may have none)"
                   "the error output is the hub's red bold first line, not the mockup's error-tint block (the tail carries styles, not a kind)"
                   "the picture is a gradient the scene makes (a PPM): in use, images are the hub's PNG or JPEG, fetched from notebook/output")
    (notebook-light "see notebook-dark")
    (notebook-views-light "see notebook-views")
    (notebook-views-running "see notebook-views; the output shown is the running cell's, which reads what it has printed so far")
    (notebook-views "the approved mockup (notebook-views.html): the three views are windows of the editor, not the mockup's cards; with the image's kernel the outline shows a finished, a running and a failed cell and the log has no entries (the kernel logged nothing); the output shown is a 2 500-line cell, moved half a window on, so the cut rows show; the focused outline row has no focus ring (Sjá has no focus-following class)"
                    "the notebook is a file the scene writes and the hub opens (no kernel: no running cell, no log entries), so the rows are the hub's own")
    (palette "the mockup's palette rows come from its own commands; the line lists the registry's")
    (explorer-focused-dark "no agent badges (C, R) in the Explorer: agent system part 3 (G9)")
    (explorer-focused-light "no agent badges (C, R) in the Explorer: agent system part 3 (G9)")
    (explorer-focused-hc "no agent badges (C, R) in the Explorer: agent system part 3 (G9)")
    (debugging "the mock adapter's session has one thread: no price-feed (RUNNING) in the Call Stack"
               "the console's input is empty: the mockup's `item.' with its completion popup is not typed"
               "pricing.py's not-bound breakpoint (77) is not set: the scene's project has no pricing.py"
               "the hover dot on 32 only on a Nidhogg with the margin's mouse-face (glitnir-margin-mouse-face)"
               "no change bars: the scene's inventory.py is new, not a changed file"
               "the container has no keyring: the status bar says the session is not recorded"
               "the project, branch and other tabs are the scenes' shared fixture, not the mockup's stockroom")
    (debug-extras "the extras mockup's panels are cut from these windows (debugging-extras.png has no window)"
                  "a breakpoint being dragged is not shown: the drag lasts only while the mouse button is held")
    (debug-extras-light "the extras mockup's panels are cut from these windows (debugging-extras.png has no window)"
                        "a breakpoint being dragged is not shown: the drag lasts only while the mouse button is held")
    (debug-extras-views "the extras mockup's panels are cut from these windows (debugging-extras.png has no window)")
    (debug-extras-views-light "the extras mockup's panels are cut from these windows (debugging-extras.png has no window)")
    (send-run "the card's run is the scene's record: the container has no keyring, so no run is recorded")
    (send-run-code "the code and the size are the scene's own: the container has no keyring, so no run is recorded to export"
                   "a sent run on the strip is not shown: it needs a recorded run to import (its Sent line has unit tests)")
    (send-run-light "the card's run is the scene's record: the container has no keyring, so no run is recorded")
    (send-run-code-light "the code and the size are the scene's own: the container has no keyring, so no run is recorded to export")
    (heap-graph "the graph is the scene's own two reads (an answer and the next stop's push, as debug/heap_wire.rs
sends them): the mock adapter has no object ids to walk"
                "no Locals card: the hub's graph starts at the variable shown")
    (heap-graph-light "the graph is the scene's own two reads (an answer and the next stop's push, as
debug/heap_wire.rs sends them): the mock adapter has no object ids to walk"
                      "no Locals card: the hub's graph starts at the variable shown"))
  "What the line cannot show of each scene's mockup yet, written to the scene's facts (:limits).  A scene is never
changed to hide a gap: the gap is named here instead.")

(defun drgnx-look-scene--no-prompt (&rest args)
  "A prompt in a scene's setup is an error naming it (ARGS: the prompt's), not a session waiting for an answer."
  (error "Prompted: %S" (substring-no-properties (format "%s" (car args)))))

(defvar drgnx-look-scene--backtrace nil "The backtrace of the error being handled, when DRGNX_LOOK_BT=1.")

(defun drgnx-look-scene--note-backtrace (_err)
  "With DRGNX_LOOK_BT=1, keep the first lines of the backtrace of the error being signalled (they name its caller)."
  (when (equal (getenv "DRGNX_LOOK_BT") "1")
    (setq drgnx-look-scene--backtrace
          (mapconcat #'identity
                     (seq-take (seq-remove (lambda (l) (string-match-p "backtrace\\|handler-bind\\|note-backtrace" l))
                                           (split-string (with-output-to-string (backtrace)) "\n" t))
                               14)
                     " | "))))

(defmacro drgnx-look-scene--try (what &rest body)
  "Run BODY; an error, a prompt included, is kept in `drgnx-look-scene--errors' under WHAT, not raised (with
DRGNX_LOOK_BT=1 its backtrace follows)."
  (declare (indent 1))
  `(condition-case err
       (handler-bind ((error #'drgnx-look-scene--note-backtrace))
         (cl-letf (((symbol-function 'yes-or-no-p) #'drgnx-look-scene--no-prompt)
                   ((symbol-function 'y-or-n-p) #'drgnx-look-scene--no-prompt)
                   ((symbol-function 'read-from-minibuffer) #'drgnx-look-scene--no-prompt)
                   ((symbol-function 'completing-read) #'drgnx-look-scene--no-prompt)
                   ((symbol-function 'read-char-choice) #'drgnx-look-scene--no-prompt)
                   ((symbol-function 'read-key) #'drgnx-look-scene--no-prompt))
           ,@body))
     (error (push (format "%s: %s%s" ,what (error-message-string err)
                          (if drgnx-look-scene--backtrace (format " [%s]" (prog1 drgnx-look-scene--backtrace
                                                                            (setq drgnx-look-scene--backtrace nil)))
                            ""))
                  drgnx-look-scene--errors)
            nil)))

(declare-function drgnx-view-patch-rows "drgnx-view")
(declare-function drgnx-view-env-classes "drgnx-view-env")
(declare-function drgnx-view-patch-view "drgnx-view")
(declare-function drgnx-view-patch-version "drgnx-view")
(declare-function drgnx-view-patch-sja "drgnx-view")
(declare-function drgnx-view-sja-row-start "drgnx-view-sja")
(defvar drgnx-view-patch)

(defvar drgnx-look-scene-rows-wait 20
  "Seconds a step waits for the hub's rows of the views it shows (`drgnx-look-scene--unfed'), as the editor's scene
waits for the Explorer's.")

(defun drgnx-look-scene--unfed-views ()
  "The hub-fed views a window of the selected frame shows without the hub's rows: ((VIEW BUFFER CLASSES) ...).  A
view with no env sent (CLASSES nil), or with no version and an empty buffer, has none."
  (let ((seen nil) (out nil))
    (dolist (w (window-list nil 'never))
      (let* ((b (window-buffer w)) (state (buffer-local-value 'drgnx-view-patch b))
             (view (and state (drgnx-view-patch-view state))))
        (when (and view (not (member view seen)))
          (push view seen)
          (let ((classes (and (fboundp 'drgnx-view-env-classes) (drgnx-view-env-classes view))))
            (unless (and classes (or (drgnx-view-patch-version state) (> (buffer-size b) 0)))
              (push (list view b classes) out))))))
    (nreverse out)))

(defun drgnx-look-scene--unfed ()
  "The hub-fed views a window of the selected frame shows without the hub's rows, while the scenes' hub runs: one
error each, naming the view, the display classes its env went out for (none: the hub never heard it is shown, so it
builds nothing) and the version of the rows it applied (nil: none since the env last re-paired it).  A view whose
Lisp draws part of it (the agent panel) is caught by the first.  A redisplay first, as the shot's: it runs the window
change hooks that send the env of a view a window has just started showing.  The step waits for the rows first
\(`drgnx-look-scene-rows-wait'), as the user does: a view a step's command has just shown, or whose display class the
step changed (a class change pairs the buffer anew, empty until the hub's reset), is drawn a round trip later."
  (redisplay)
  (when (and (fboundp 'drgnx-hub-running-p) (drgnx-hub-running-p))
    (let ((end (+ (float-time) drgnx-look-scene-rows-wait)))
      (while (and (drgnx-look-scene--unfed-views) (< (float-time) end))
        (accept-process-output nil 0.02)
        (redisplay)))
    (pcase-dolist (`(,view ,b ,classes) (drgnx-look-scene--unfed-views))
      (push (format "%s: shown in %s with no rows from the hub (env sent for %S, rows version %S)"
                    view (buffer-name b) classes (drgnx-view-patch-version (buffer-local-value 'drgnx-view-patch b)))
            drgnx-look-scene--errors))))

(defun drgnx-look-scene--answer (&rest more)
  "The step's JSON answer: its errors and MORE, then the echo area cleared, and the status bar's message with it (a
message there lasts some seconds, so the previous scene's last one, its palette's \"Quit\", would show in this one's).
A hub-fed view shown without the hub's rows is one of the errors (`drgnx-look-scene--unfed')."
  (drgnx-look-scene--unfed)
  (prog1 (drgnx-uitest--json (append (list :errors (vconcat (nreverse drgnx-look-scene--errors))) more))
    (setq drgnx-look-scene--errors nil)
    (message nil)
    (when (fboundp 'drgnx-look-echo--status-clear) (drgnx-look-echo--status-clear))))

(defun drgnx-look-scene--forced-theme ()
  "The theme $DRGNX_LOOK_THEME names for every scene (`light', `dark', `hc' or a theme's name), or nil when unset."
  (let ((v (getenv "DRGNX_LOOK_THEME")))
    (pcase v
      ((or 'nil "") nil)
      ("light" 'drgnx-light)
      ("dark" 'drgnx-dark)
      ((or "hc" "high-contrast") 'drgnx-high-contrast)
      (_ (intern v)))))

(defun drgnx-look-scene--theme (theme)
  "Load THEME alone, or the theme $DRGNX_LOOK_THEME names when it is set (`drgnx-look-scene--forced-theme'): every
scene draws in it then, those named for another theme too."
  (drgnx-look-scene--try "theme"
    (mapc #'disable-theme custom-enabled-themes)
    (load-theme (or (drgnx-look-scene--forced-theme) theme) t)
    (drgnx-look-scene--views-settle)))

(defvar drgnx-view-patch--buffers)
(declare-function drgnx-view-patch-stale "drgnx-view")

(defun drgnx-look-scene--stale-views ()
  "The names of the hub-fed views' buffers drawn dimmed (`drgnx-view-stale'): their rows wait for the hub's reset."
  (let (out)
    (when (boundp 'drgnx-view-patch--buffers)
      (maphash (lambda (_ b)
                 (when (and (buffer-live-p b) (buffer-local-value 'drgnx-view-patch b)
                            (drgnx-view-patch-stale (buffer-local-value 'drgnx-view-patch b)))
                   (push (buffer-name b) out)))
               drgnx-view-patch--buffers))
    out))

(defun drgnx-look-scene--views-settle ()
  "After a theme change: the new look is a new env epoch, and a hub-fed view's rows stay dimmed until the hub's reset
for it comes; wait (5 s at most) for it, as the user does for a moment, so the scene shows the rows as they settle."
  (let ((end (+ (float-time) 5)))
    (while (and (drgnx-look-scene--stale-views) (< (float-time) end))
      (accept-process-output nil 0.02)
      (redisplay))
    (when-let* ((stale (drgnx-look-scene--stale-views)))
      (push (format "theme: views still dimmed after 5 s: %S" stale) drgnx-look-scene--errors))))

(defun drgnx-look-scene--packages (elpa)
  "Activate the packages in ELPA, as the user's install has them (a session has none of its own)."
  (when (and elpa (file-directory-p elpa))
    (drgnx-look-scene--try "packages"
      (require 'package)
      ;; packages another Emacs build compiled (the desktop's pinned ELPA is from 30.2) must not meet this Emacs's JIT
      (drgnx-pkg-jit-guard elpa)
      (setq package-directory-list (list elpa))
      (package-initialize)
      ;; `package-initialize' leaves vertico and orderless off the path from a read-only directory list
      (dolist (d (directory-files elpa t "\\`\\(vertico\\|orderless\\|compat\\)-[0-9.]+\\'"))
        (add-to-list 'load-path d))
      (drgnx-modules-retry-waiting))))

(defun drgnx-look-scene--show (buffer)
  "Show BUFFER in the selected window as a tab, as a command opening it would (tabs are noted between commands)."
  (switch-to-buffer buffer)
  (when (fboundp 'drgnx-chrome--note) (drgnx-chrome--note (selected-window))))

(defun drgnx-look-scene--open (file)
  "The project's FILE opened in the selected window, as a tab."
  (drgnx-look-scene--show (find-file-noselect (expand-file-name file drgnx-look-scene--project))))

(defun drgnx-look-scene--goto (file line column start)
  "FILE of the project shown in the editor at LINE and COLUMN (from 0: the bar says COLUMN + 1, `Col 34' for 33), the
window starting at line START."
  (drgnx-look-scene--open file)
  (goto-char (point-min)) (forward-line (1- start))
  (set-window-start (selected-window) (point))
  (forward-line (- line start)) (move-to-column column)
  ;; as after a command: what follows point (the current line's overlay, the breadcrumb) moves to it, else the first
  ;; scene shows them where the file opened
  (run-hooks 'post-command-hook))

(defvar drgnx-look-scene--start nil
  "((:part PART) . STATE): the frame's arrangement (`drgnx-layouts--frame-part') and the state that is checked
\(`drgnx-look-scene--start-state') as the setup left them, which every scene starts from (`drgnx-look-scene-begin').")

(declare-function drgnx-layouts--frame-part "drgnx-layouts" (frame))
(declare-function drgnx-layouts--put "drgnx-layouts" (frame part))

(defun drgnx-look-scene-setup (elpa)
  "The mockups' state: the project at ~/code/drgnx, trusted; ELPA's packages active; tabs drgnx-gateway.el,
gateway-test.el (changed, not saved), drgnx-job.el (a preview) and Magit; the Explorer; drgnx-gateway.el at 216:34,
from 201."
  (drgnx-look-scene--packages elpa)
  ;; $DRGNX_LOOK_THEME: the scenes that set no theme of their own (Magit, Org, …) draw in it too
  (when (drgnx-look-scene--forced-theme) (drgnx-look-scene--theme nil))
  ;; the notebook scenes' kernel, before any scene starts the hub that runs it
  (when-let* ((kernel (drgnx-look-scene--kernel-python)))
    (drgnx-look-scene--try "kernel" (drgnx-look-scene--kernel-env kernel)))
  ;; the title row as on GNOME, the mockups' desktop, where `auto' is `drgnx': the container's headless mutter names
  ;; no desktop, so the frame is told it is GNOME's (the facts' :wm says so)
  (drgnx-look-scene--try "title"
    (set-frame-parameter nil 'drgnx-platform-wm 'gnome)
    (customize-set-variable 'drgnx-face-title-bar 'drgnx))
  (drgnx-look-scene--try "project"
    (setq drgnx-look-scene--project (drgnx-look-scene-project (expand-file-name "~/code/drgnx"))))
  (drgnx-look-scene--try "trust" (drgnx-trust-folder drgnx-look-scene--project))
  (drgnx-look-scene--try "focus" (drgnx-wb-focus-editor))
  (drgnx-look-scene--try "open"
    (drgnx-look-scene--goto "core/drgnx-gateway.el" 216 33 201)
    (drgnx-look-scene--open "test/unit/gateway-test.el")
    (goto-char (point-max)) (insert ";; next\n")                  ; changed, not saved: the tab's dot
    (drgnx-look-scene--open "core/drgnx-job.el")
    (drgnx-chrome-note-preview (current-buffer) t))               ; opened by a single click: the italic preview
  (drgnx-look-scene--try "magit"
    (require 'magit)
    (let ((magit-save-repository-buffers nil))                    ; gateway-test.el stays unsaved
      (magit-status-setup-buffer drgnx-look-scene--project))
    (drgnx-look-scene--show (current-buffer)))
  (drgnx-look-scene--try "explorer" (drgnx-wb-view-explorer))
  ;; the mockups' last test run, as a run reports it (`213 tests' in the status bar)
  (drgnx-look-scene--try "tests" (drgnx-statusbar-note-tests 213 0))
  (drgnx-look-scene--try "back" (drgnx-wb-focus-editor) (drgnx-look-scene--goto "core/drgnx-gateway.el" 216 33 201))
  ;; what every scene starts from (`drgnx-look-scene-begin')
  (drgnx-look-scene--try "start"
    (redisplay t)
    (setq drgnx-look-scene--start (cons (list :part (drgnx-layouts--frame-part (selected-frame)))
                                        (drgnx-look-scene--start-state))))
  (drgnx-look-scene--answer :project drgnx-look-scene--project))

(defconst drgnx-look-scene--panel-more 17
  "The steps of the mock agent's second turn (`agent-panel-long'): with the first turn's, a transcript longer than the
panel's window at either scale.")

(defun drgnx-look-scene-agent (bin)
  "A mock agent (BIN: a test-hooks ratatoskr with ratatoskr-mock beside it) reads, runs, edits and asks."
  (cond
   ;; a scene that needs the agent after another that started it (the panel after the window) finds it running
   ((buffer-live-p drgnx-look-scene--panel))
   ((not (and bin (file-executable-p bin)))
    (push "agent: no ratatoskr binary (DRGNX_RATATOSKR_BIN)" drgnx-look-scene--errors))
   (t
    (drgnx-look-scene--try "agent"
      (load (expand-file-name "test/fixtures/panel-replay-fixture" (bound-and-true-p drgnx-dir)) nil t)
      ;; the mockup's three steps; the `agent-panel-long' scene makes the transcript long with the second turn below
      (setq drgnx-panel-replay-prefix 3)
      (defalias 'drgnx-panel-replay-program
        (lambda ()
          ;; the mockup's figures: a slow run (past `drgnx-agent-panel-slow-seconds'), a quick one, then a read
          ;; that asks and stays open, so the permission card shows.  The replay session is a chat: the matrix
          ;; answers a chat's edit or run Never (no card), and asks for its reads
          (concat (mapconcat (lambda (i) (format "tool:run echo step %d\\nsay Step %d finished.\\n" i i))
                             (number-sequence 1 (- drgnx-panel-replay-prefix 3)) "")
                  "tool:read core/drgnx-gateway.el\\nsay Reading the gateway: replies to a closed client are lost.\\n"
                  "tool:run sleep 11; echo 1 of 14 failed\\nsay 1 of 14 failed: gateway/reply-after-close.\\n"
                  "tool:edit test/unit/gateway-test.el\\nsay Queue the reply when the client went away.\\n"
                  "tool:run sleep 2; echo 9 of 14 passed\\n"
                  "ask:tool {\"kind\": \"read\", \"title\": \"Read the gateway's log\"}\n"
                  ;; the second prompt's turn (the script's next line), which only `agent-panel-long' sends: steps
                  ;; enough to run the transcript past the panel's window
                  (mapconcat (lambda (i) (format "tool:run echo more %d\\nsay More %d finished.\\n" i i))
                             (number-sequence 1 drgnx-look-scene--panel-more) "")
                  "say done")))
      ;; the replay's hub is the scenes' hub from here on: it seeds the plan run as `drgnx-look-scene--hub' does
      ;; and the agent works in the scenes' project, so the status bar and the Explorer show it there
      (setq drgnx-look-scene--panel (let ((process-environment (cons "RATATOSKR_SEED_SCENE=1" process-environment))
                                          (drgnx-panel-replay-project drgnx-look-scene--project))
                                      (drgnx-panel-replay-up bin)))
      ;; the turn runs on past the prefix to its ask: the scene shows every step's time and the open card
      (unless (drgnx-panel-replay--wait 30 (lambda () (with-current-buffer drgnx-look-scene--panel
                                                        (drgnx-agent-panel-cards--permissions))))
        (push "agent: no permission card within 30 s" drgnx-look-scene--errors)))))
  (drgnx-look-scene--answer :panel (if (buffer-live-p drgnx-look-scene--panel) (buffer-name drgnx-look-scene--panel) :null)))

(defvar drgnx-look-scene--windows-rearranged nil
  "Non-nil once a scene took the windows apart by hand (`delete-other-windows', its own splits) while the layout's name
still said `editor': the next scene's start puts the layout back (`drgnx-look-scene--editor-layout').")

(declare-function drgnx-groups-list "drgnx-groups")

(defun drgnx-look-scene--one-editor ()
  "One editor group, the one used last, selected; the docks stay.  Not `delete-other-windows': under the grid an
editor tile is kept from it (`no-delete-other-windows'), so the notebook views split the groups it left again at
every scene, and the side bar gave way to the editors' least widths (the Explorer's rows cut to `…')."
  (let ((keep (drgnx-wb-editor-window)))
    (dolist (g (drgnx-groups-list))
      (unless (eq g keep) (delete-window g)))
    (select-window keep)))

(defun drgnx-look-scene--editor-layout ()
  "The editor layout, when an earlier scene left another (the Work layout's editor group sits beside the map, and the
send-run scenes' layout has none) or took the windows apart by hand (the notebook views' three panes: the scenes after
it had no docks and no margins, and the debugging scene's hover dot read `(car (window-margins))' as nil): a scene that
focuses the editor starts here, or has no editor window to focus."
  (when (or drgnx-look-scene--windows-rearranged
            (and (fboundp 'drgnx-layouts-current) (drgnx-layouts-current) (not (eq (drgnx-layouts-current) 'editor))))
    (when drgnx-look-scene--windows-rearranged
      ;; the notebook views' three panes sit in the editor group: their buffers go (the next notebook scene makes its own),
      ;; and the layout is rebuilt from one window
      (dolist (b (buffer-list))
        (when (string-prefix-p "*Notebook " (buffer-name b)) (let ((kill-buffer-query-functions nil)) (kill-buffer b))))
      (drgnx-look-scene--one-editor))
    (setq drgnx-look-scene--windows-rearranged nil)
    (drgnx-layouts-apply 'editor)))

(defvar drgnx-sticky-style)
(declare-function drgnx-sticky--setting-changed "drgnx-sticky" (&rest _))
(declare-function drgnx-minimap--spec "drgnx-minimap" (window))
(declare-function drgnx-grid-tree-leaves "drgnx-grid-tree" (tree))

(defun drgnx-look-scene--start-state ()
  "What `drgnx-look-scene-begin' puts back and then checks, now: the layout's name, the frame's tiles as (KIND SHOWN)
\(editors with their buffer, tool tiles with their kind), the sticky style, whether the minimap hold's advice is on and
the windows the minimap scenes marked open."
  (list :layout (drgnx-layouts-current)
        :tiles (mapcar (lambda (l) (list (car l) (plist-get (cdr l) :shown)))
                       (drgnx-grid-tree-leaves (plist-get (drgnx-layouts--frame-part (selected-frame)) :tree)))
        :sticky (and (boundp 'drgnx-sticky-style) drgnx-sticky-style)
        :minimap-held (and (advice-member-p #'drgnx-look-scene--minimap-held 'drgnx-minimap--spec) t)
        :minimap-open (seq-filter (lambda (w) (window-parameter w 'drgnx-look-scene-minimap-open))
                                  (window-list-1 nil 'never t))
        :popups (drgnx-look-scene--popups)))

(declare-function drgnx-uitest-root-frame "drgnx-uitest" ())

(defun drgnx-look-scene--popups ()
  "The visible child frames of the root frame, by the name of the buffer each shows."
  (let ((root (drgnx-uitest-root-frame)))
    (sort (mapcar (lambda (f) (buffer-name (window-buffer (frame-root-window f))))
                  (seq-filter (lambda (f) (and (eq (frame-parent f) root) (eq (frame-visible-p f) t))) (frame-list)))
          #'string<)))

(defvar drgnx-debug-share-buffer)
(declare-function drgnx-debug-share--close "drgnx-debug-share")
(declare-function drgnx-inbox-close "drgnx-inbox")

(defun drgnx-look-scene--close-popups ()
  "The cards a scene leaves open closed the way their own Close does, the root frame selected: the Send Run card (a
modal: its Esc asks before closing a written card) and the inbox's drop-down.  Left open, the next scene's begin ran in
the card's frame (\"Window is dedicated to *Send Run*\") and the heap graph drew under it."
  (when-let* ((b (and (boundp 'drgnx-debug-share-buffer) (get-buffer drgnx-debug-share-buffer))))
    (with-current-buffer b (drgnx-debug-share--close)))
  (when (fboundp 'drgnx-inbox-close) (drgnx-inbox-close))
  (let ((root (drgnx-uitest-root-frame)))
    (unless (eq (selected-frame) root) (select-frame-set-input-focus root))))

(defconst drgnx-look-scene--debug-popups '(" *drgnx-debug-toolbar*")
  "The popups a live debug session shows: allowed at the begin of a scene with :debug, which keeps the session.")

(defun drgnx-look-scene--start-again (&optional debug)
  "The frame as the setup left it (`drgnx-look-scene--start'): its layout's name and arrangement (the tiles, the
editors' tabs and shown buffers), what the minimap scenes hold released (the hold's advice and window marks) and the
sticky style the setup had.  A scene that opens its views in the editor layout (the Work Flow's map, Flow, Detail and
Rules tiles: the Work space is a view in the editor) leaves the layout's name `editor', whose `one' shape keeps the
editor area as it is, and under the grid `delete-other-windows' keeps the editor tiles: without this every later scene
drew inside them (scratch splits, a narrow sidebar that cut the Run and Debug rows, the notebook views' panes too small
to split).  Left held, the sticky-lines scene drew the minimap the hover scenes opened, and later scenes kept the card."
  (when drgnx-look-scene--start
    (advice-remove 'drgnx-minimap--spec #'drgnx-look-scene--minimap-held)
    (dolist (w (window-list-1 nil 'never t))
      (when (window-parameter w 'drgnx-look-scene-minimap-open)
        (set-window-parameter w 'drgnx-look-scene-minimap-open nil)
        (when (window-parameter w 'glitnir-minimap)
          (set-window-parameter w 'glitnir-minimap (drgnx-minimap--spec w)))))
    (let ((sticky (plist-get (cdr drgnx-look-scene--start) :sticky)))
      (when (and (featurep 'drgnx-sticky) (not (eq drgnx-sticky-style sticky)))
        (setq drgnx-sticky-style sticky)
        (drgnx-sticky--setting-changed)))
    (drgnx-layouts--put (selected-frame) (plist-get (car drgnx-look-scene--start) :part))
    (set-frame-parameter nil 'drgnx-layouts-current (plist-get (cdr drgnx-look-scene--start) :layout))
    (drgnx-wb-focus-editor)
    ;; the check: anything a scene left that this did not put back is an error of the next scene's begin
    (redisplay t)
    (let ((now (drgnx-look-scene--start-state)) (want (cdr drgnx-look-scene--start)))
      (when debug                       ; the session the scene keeps shows its toolbar
        (setq now (plist-put now :popups (seq-difference (plist-get now :popups) drgnx-look-scene--debug-popups))))
      (dolist (key '(:layout :tiles :sticky :minimap-held :minimap-open :popups))
        (unless (equal (plist-get now key) (plist-get want key))
          (push (format "begin: the scene before left %s %S, not the setup's %S"
                        (substring (symbol-name key) 1) (plist-get now key) (plist-get want key))
                drgnx-look-scene--errors))))))

(defvar drgnx-debug--sessions)

(defun drgnx-look-scene--debug-end ()
  "The scenes' debug sessions ended (a scene with :debug in `drgnx-look-scenes' keeps them: the debugging scenes
share one stopped session).  Left running, the debug toolbar's child frame stayed over every later scene."
  (when (bound-and-true-p drgnx-debug--sessions)
    (dolist (s drgnx-debug--sessions)
      (drgnx-hub-call-sync "debug/control" (list :session (plist-get s :id) :op "stop") 5))
    (drgnx-look-scene--until 15 "the debug sessions' end" (lambda () (null drgnx-debug--sessions)))))

(defun drgnx-look-scene-begin (&optional debug)
  "Before each scene (`drgnx-look-scenes-run'): the editor layout, whatever the scene before left, then the frame as
the setup left it (`drgnx-look-scene--start-again'), checked.  A scene in another layout (the Work map's) applies it
itself; without this the scenes after it drew in its layout (the start page and the notebooks showed the Work map).
DEBUG (the scene's :debug) keeps the debug session a scene before it started; without it the session ends."
  (drgnx-look-scene--try "begin"
    (drgnx-look-scene--close-popups)
    (unless debug (drgnx-look-scene--debug-end))
    (drgnx-look-scene--editor-layout) (drgnx-look-scene--start-again debug))
  ;; not `drgnx-look-scene--answer': the scene's own answer checks its views, once it has shown them
  (prog1 (drgnx-uitest--json (list :errors (vconcat (nreverse drgnx-look-scene--errors))))
    (setq drgnx-look-scene--errors nil)))

(defun drgnx-look-scene--shown (what &rest buffers)
  "An error under WHAT unless the frame is in the editor layout and a window of it shows each of BUFFERS (buffers or
names): a scene drawn after another that left its own layout (the Work map's) must still show its own buffers."
  (redisplay)
  (when (and (fboundp 'drgnx-layouts-current) (drgnx-layouts-current) (not (eq (drgnx-layouts-current) 'editor)))
    (push (format "%s: the frame is in the %s layout, not the editor's" what (drgnx-layouts-current))
          drgnx-look-scene--errors))
  (dolist (b buffers)
    (unless (and (get-buffer b) (get-buffer-window b))
      (push (format "%s: no window shows %s; the frame shows %S" what (if (bufferp b) (buffer-name b) b)
                    (mapcar (lambda (w) (buffer-name (window-buffer w))) (window-list nil 'never)))
            drgnx-look-scene--errors))))

(defun drgnx-look-scene--editor ()
  "The editor on the gateway file, with the Explorer's Files section drawn: its rows come from the hub, so the scenes'
hub is started first and the shot waits for them (a session starts no hub: without one the section is empty)."
  (drgnx-look-scene--try "hub" (drgnx-look-scene--hub))
  (drgnx-look-scene--try "editor"
    ;; a Work scene before this one left the Work layout, whose editor group is beside the map: the editor layout
    ;; again (the Extensions list opened in the Work layout, out of sight, and its scene never saw its rows)
    (drgnx-look-scene--editor-layout)
    (drgnx-wb-focus-editor)
    (drgnx-look-scene--goto "core/drgnx-gateway.el" 216 33 201))
  (drgnx-look-scene--until 20 "explorer files rows"
                           (lambda () (when-let* ((b (get-buffer drgnx-explorer-buffer-name)))
                                        (with-current-buffer b
                                          (save-excursion (goto-char (point-min)) (search-forward "Makefile" nil t)))))))

(declare-function drgnx-hub-call "drgnx-hub-client")
;; tools/jobs's (modules/tools/drgnx-jobs.el); no file named: its feature is the name the deleted Lisp jobs runtime
;; had, which the runtime lints refuse
(declare-function drgnx-jobs-note-jobs nil (jobs))
(declare-function flymake-start "flymake")
(declare-function flymake-make-diagnostic "flymake")
(defvar drgnx-jobs--running)

(defun drgnx-look-scene--problems (report &rest _)
  "window-dark.html's problems for the gateway file (the status bar's `✕ 1 ⚠ 1'), told to Flymake through REPORT: a
stand-in backend, as the palette's commands are stand-ins, with the error and warning the highlights scene marks (the
call on line 229, `old' on line 208)."
  (let ((at (lambda (line text)
              (save-excursion
                (goto-char (point-min)) (forward-line (1- line))
                (search-forward text (pos-eol))
                (cons (- (point) (length text)) (point))))))
    (funcall report
             (list (let ((r (funcall at 229 "drgnx-gateway--log")))
                     (flymake-make-diagnostic (current-buffer) (car r) (cdr r) :error
                                              "Function not known to be defined"))
                   (let ((r (funcall at 208 "old")))
                     (flymake-make-diagnostic (current-buffer) (car r) (cdr r) :warning
                                              "variable `old' is never used"))))))

(defvar eglot--managed-mode)
(defvar eglot--cached-server)
(declare-function eieio-oset "eieio-core")

(defun drgnx-look-scene--eglot ()
  "The current buffer managed by a stand-in eglot (window-dark.html's `● eglot'): its server an `eglot-lsp-server' on a
JSON-RPC connection to `cat', no language server, so the status bar's `lsp' segment draws it by its own code.  It is
a whole server of its kind with no capabilities, as one that has not answered `initialize' is: the product asks a
server what it can do (`eglot-server-capable', the Search view's rename), and a bare connection has no answer."
  (require 'eglot)
  (let ((server (make-instance 'eglot-lsp-server :name "eglot"
                               :process (make-process :name "look-scene-lsp" :command '("cat") :noquery t
                                                      :connection-type 'pipe))))
    (eieio-oset server 'project-nickname "drgnx")
    (setq-local eglot--managed-mode t eglot--cached-server server))
  (run-hooks 'eglot-managed-mode-hook))

(defun drgnx-look-scene-window-dark ()
  "The editor on the gateway file, with the status bar's facts of the mockup: the seeded plan run running (`1 job',
counted from the hub), the file's problems (`drgnx-look-scene--problems') and its language server
(`drgnx-look-scene--eglot')."
  (drgnx-look-scene--theme 'drgnx-dark)
  (drgnx-look-scene--editor)
  (drgnx-look-scene--try "problems"
    (require 'flymake)
    (with-current-buffer (get-file-buffer (expand-file-name "core/drgnx-gateway.el" drgnx-look-scene--project))
      (setq-local flymake-diagnostic-functions (list #'drgnx-look-scene--problems))
      (flymake-mode 1)
      (flymake-start)
      (drgnx-look-scene--eglot)))
  ;; the hub's `job/status', handed to tools/jobs as its own recount does (the module provides the feature name the
  ;; deleted Lisp jobs runtime had, so nothing here declares from it)
  (drgnx-look-scene--try "jobs"
    (drgnx-hub-call "job/status" nil
                    (lambda (r e) (unless e (drgnx-jobs-note-jobs (append (plist-get r :jobs) nil)))))
    (drgnx-look-scene--until 15 "the status bar's job (the seeded run)" (lambda () (eql drgnx-jobs--running 1))))
  (drgnx-look-scene--answer))

(defvar drgnx-look-scene--panel-long nil "Non-nil once `agent-panel-long' sent the mock agent its second prompt.")

(declare-function drgnx-agent-panel--answer "drgnx-agent-panel-cards" (request option))
(declare-function drgnx-agent-panel-cards--option "drgnx-agent-panel-cards" (request kinds))
(declare-function drgnx-agent-panel--ask "drgnx-agent-panel" (method params &optional callback))
(defvar drgnx-agent-panel--session)

(defun drgnx-look-scene--panel-second-turn ()
  "The mock agent's second turn, once: the first turn's open permission allowed (the turn ends), then a prompt, which
runs the script's second line (`drgnx-look-scene--panel-more' steps); done when its last step is in the transcript.
The first turn stays the mockup's three steps for the scenes before."
  (with-current-buffer drgnx-look-scene--panel
    (unless drgnx-look-scene--panel-long
      (when-let* ((req (car (drgnx-agent-panel-cards--permissions))))
        (drgnx-agent-panel--answer req (drgnx-agent-panel-cards--option req '("allow_once" "allow_always"))))
      (drgnx-agent-panel--ask "agents/send" (list :id drgnx-agent-panel--session :text "more"))
      (setq drgnx-look-scene--panel-long t)))
  (let ((last (format "More %d finished." drgnx-look-scene--panel-more)))
    (drgnx-look-scene--until 60 "the second turn's last step"
                             (lambda () (with-current-buffer drgnx-look-scene--panel
                                          (save-excursion (goto-char (point-min)) (search-forward last nil t)))))))

(defun drgnx-look-scene-agent-panel-long ()
  "The agent panel with a transcript longer than its window (the mock agent's second turn).  The checks of the three
windows (header, transcript, composer) replace the old pinned-copy checks (Task 8 of the docks plan)."
  (drgnx-look-scene--try "panel second turn" (drgnx-look-scene--panel-second-turn))
  (prog1 (drgnx-look-scene-agent-panel)
    (drgnx-look-scene--try "panel long"
      (when-let* ((w (get-buffer-window drgnx-look-scene--panel)))
        (when (and (= (window-start w) (with-current-buffer drgnx-look-scene--panel (point-min)))
                   (pos-visible-in-window-p (with-current-buffer drgnx-look-scene--panel (point-max)) w))
          (error "The transcript fits the panel's window after the second turn"))))
    ;; the three windows' checks (docks plan, Task 8); the header clicks leave the transcript scrolled up a page
    (drgnx-look-scene--try "docks wheel" (drgnx-look-scene--panel-docks-wheel drgnx-look-scene--panel))
    (drgnx-look-scene--try "header clicks" (drgnx-look-scene--panel-header-clicks drgnx-look-scene--panel))
    ;; the clicks changed the header's state: the shot shows the rows the hub settles on
    (drgnx-look-scene--try "settled after the clicks" (drgnx-look-scene--panel-settle drgnx-look-scene--panel))))

;;;; The panel's three windows (the docks plan, 2026-11-15-agent-panel-docks.md, Task 8): a header window (hub view
;;;; `agent-panel-top/SID', fitted, never scrolled), the transcript (`agent-panel/SID', the panel's main buffer) and the
;;;; composer, the right area's bottom window.  The companions carry the window parameter `drgnx-area-part' (`above',
;;;; `below'); the transcript is the main buffer.

(defun drgnx-look-scene--has-row-p (buffer key)
  "Whether BUFFER, a hub-fed view, holds the row KEY: drawn by Sjá, or in its Lisp rows."
  (let ((s (buffer-local-value 'drgnx-view-patch buffer)))
    (and s (if (drgnx-view-patch-sja s)
               (and (drgnx-view-sja-row-start key buffer) t)
             (let ((rows (drgnx-view-patch-rows s))) (and rows (gethash key rows) t))))))

(defun drgnx-look-scene--area-windows (window)
  "The windows of WINDOW's area (its `drgnx-role'), top to bottom: (WINDOW PART BUFFER-NAME) each."
  (let ((role (window-parameter window 'drgnx-role)))
    (mapcar (lambda (w) (list w (window-parameter w 'drgnx-area-part) (buffer-name (window-buffer w))))
            (sort (seq-filter (lambda (w) (and role (eq (window-parameter w 'drgnx-role) role)))
                              (window-list (window-frame window) 'nomini))
                  (lambda (a b) (< (window-pixel-top a) (window-pixel-top b)))))))

(defun drgnx-look-scene--docks (buffer)
  "BUFFER's three panel windows (HEADER TRANSCRIPT COMPOSER), or an error naming what is missing."
  (let* ((w (or (get-buffer-window buffer) (error "no window shows the panel")))
         (area (drgnx-look-scene--area-windows w))
         (part (lambda (p) (car (seq-find (lambda (e) (eq (nth 1 e) p)) area)))))
    (unless (window-parameter w 'drgnx-role)
      (error "the transcript's window is in no area (no `drgnx-role'): it is %S" (window-parameters w)))
    (list (or (funcall part 'above)
              (error "no header window (`drgnx-area-part' above) in the panel's area; its windows: %S"
                     (mapcar #'cdr area)))
          w
          (or (funcall part 'below)
              (error "no composer window (`drgnx-area-part' below) in the panel's area; its windows: %S"
                     (mapcar #'cdr area))))))

(defun drgnx-look-scene--fit-error (window what)
  "Nil when WINDOW (WHAT: its name) is fitted to its buffer and starts at its top: its body's pixel height is its
text's (±1 px), as `fit-window-to-buffer' measures it; else what differs."
  (let* ((b (window-buffer window))
         (text (cdr (window-text-pixel-size window (with-current-buffer b (point-min))
                                            (with-current-buffer b (point-max)))))
         (body (window-body-height window t)))
    (cond ((/= (window-start window) (with-current-buffer b (point-min)))
           (format "the %s window does not start at its top (start %d)" what (window-start window)))
          ((/= (window-vscroll window t) 0)
           (format "the %s window is scrolled by %d px" what (window-vscroll window t)))
          ((> (abs (- body text)) 1)
           (format "the %s window is not fitted: body %d px, its text %d px" what body text)))))

(defun drgnx-look-scene--panel-three-windows (buffer)
  "BUFFER, the panel's transcript, is the middle of three windows of its area: the header above it holds `p:head' of
the hub's `agent-panel-top/' view, is fitted and carries the area's tab row; the transcript holds no `p:head'; the
composer is the area's bottom window, fitted."
  (redisplay t)
  (pcase-let* ((`(,h ,w ,c) (drgnx-look-scene--docks buffer))
               (hb (window-buffer h))
               (hs (buffer-local-value 'drgnx-view-patch hb))
               (area (drgnx-look-scene--area-windows w)))
    (unless (and hs (string-prefix-p "agent-panel-top/" (drgnx-view-patch-view hs)))
      (error "the header window shows %s, not the hub's view agent-panel-top/SID (its view %S)"
             (buffer-name hb) (and hs (drgnx-view-patch-view hs))))
    (drgnx-look-scene--until 10 (format "the header window's %s: its `p:head' row" (buffer-name hb))
                             (lambda () (drgnx-look-scene--has-row-p hb "p:head")))
    (when (drgnx-look-scene--has-row-p buffer "p:head")
      (error "the transcript %s still holds `p:head': the header is in the header window only" (buffer-name buffer)))
    (unless (and (< (window-pixel-top h) (window-pixel-top w)) (< (window-pixel-top w) (window-pixel-top c)))
      (error "the windows are not header, transcript, composer from the top: %S" (mapcar #'cdr area)))
    (unless (eq (car (car (last area))) c)
      (error "the composer is not the area's bottom window: %S" (mapcar #'cdr area)))
    ;; the area's row (`drgnx-area--tab-row': `none' in the lone right area) is the header's; the others have none
    (let ((row (lambda (x) (let ((v (window-parameter x 'header-line-format))) (and v (not (eq v 'none)) v)))))
      (unless (and (equal (window-parameter h 'header-line-format)
                          (drgnx-area--tab-row (window-parameter w 'drgnx-role)))
                   (not (seq-find (lambda (e) (and (not (eq (car e) h)) (funcall row (car e)))) area)))
        (error "the area's tab row is not on the header window alone: %S"
               (mapcar (lambda (e) (cons (nth 1 e) (and (funcall row (car e)) t))) area))))
    (when-let* ((e (or (drgnx-look-scene--fit-error h "header") (drgnx-look-scene--fit-error c "composer"))))
      (error "%s" e))))

(defun drgnx-look-scene--edges (window)
  "WINDOW's pixel edges, start and vscroll: what must not change for a window that never moves."
  (list (window-pixel-edges window) (window-start window) (window-vscroll window t)))

(defun drgnx-look-scene--panel-docks-wheel (buffer)
  "Wheel the transcript up and down over its window, with `pixel-scroll-precision-mode' on and off: the transcript
moves each way, and the header window does not move (edges, start, vscroll)."
  (pcase-let* ((`(,h ,w ,_) (drgnx-look-scene--docks buffer))
               (was (bound-and-true-p pixel-scroll-precision-mode))
               (header (drgnx-look-scene--edges h)))
    (select-window w)
    (unwind-protect
        (dolist (precise '(nil t))
          (pixel-scroll-precision-mode (if precise 1 -1))
          (with-current-buffer buffer (goto-char (point-max)))
          (set-window-point w (with-current-buffer buffer (point-max)))
          (redisplay t)
          (let* ((posn (posn-at-x-y 40 (/ (window-body-height w t) 2) w))
                 (dist (lambda () (with-current-buffer buffer (- (point-max) (window-start w)))))
                 (wheel (lambda (head n delta)
                          (put head 'event-kind 'mouse-click)
                          (drgnx-uitest-run (make-list n (if precise
                                                             (list head posn 1 (cons 0 (if (eq head 'wheel-up) -1 1))
                                                                   (cons 0.0 (float (- delta))))
                                                           (list head posn))))
                          (redisplay t)))
                 (start (funcall dist))
                 (still (lambda (how)
                          (unless (equal (drgnx-look-scene--edges h) header)
                            (error "wheel %s (pixel precision %S) moved the header window: %S, was %S"
                                   how precise (drgnx-look-scene--edges h) header)))))
            (funcall wheel 'wheel-up 6 -40)
            (unless (> (funcall dist) start)
              (error "wheel up (pixel precision %S) did not move the transcript (%d from the end, was %d)"
                     precise (funcall dist) start))
            (funcall still "up")
            (let ((from (window-start w)))
              (funcall wheel 'wheel-down 6 40)
              (unless (> (window-start w) from)
                (error "wheel down (pixel precision %S) did not move the transcript back (start %d, was %d)"
                       precise (window-start w) from)))
            (funcall still "down")))
      (pixel-scroll-precision-mode (if was 1 -1))
      ;; Emacs's behaviour: `pixel-scroll-precision-mode' leaves a pixel vscroll (`window-vscroll', 15 px at s1 in a
      ;; transcript shown whole from its start), and a later `scroll-down' in that window leaves its start where it
      ;; was, with no error (the header clicks' check then saw no scroll)
      (set-window-vscroll w 0 t))))

(defun drgnx-look-scene--header-targets (window &optional panel)
  "The first posn in WINDOW (the header window) over each kind of clickable part: an alist (KIND . POSN), KIND `pin',
`lens' or `pill', from the drawn window (`posn-at-x-y'), reading the buffer's text (or a string, should one be shown).
With PANEL, the lens is a segment whose preset is not PANEL's disclosure now (a click on it changes the disclosure)."
  (let ((b (window-buffer window)) found)
    (cl-loop for y from 2 below (window-body-height window t) by 3
             do (cl-loop for x from 2 below (window-body-width window t) by 3
                         do (let* ((p (posn-at-x-y x y window)) (str (posn-string p)) (pt (posn-point p))
                                   (a (cond ((and (consp str) (stringp (car str)))
                                             (get-text-property (cdr str) 'drgnx-agent-panel-action (car str)))
                                            (pt (get-text-property pt 'drgnx-agent-panel-action b))))
                                   (kind (cond ((equal a "pin") 'pin)
                                               ((and (stringp a) (string-prefix-p "lens:" a)
                                                     (not (and panel
                                                               (equal (cdr (nth (1- (string-to-number (substring a 5)))
                                                                                (symbol-value 'drgnx-agent-panel-presets)))
                                                                      (buffer-local-value 'drgnx-agent-panel--disclosure
                                                                                          panel)))))
                                                'lens)
                                               ((and (stringp a) (string-prefix-p "type:" a)) 'pill))))
                              (when (and kind (not (assq kind found))) (push (cons kind p) found)))))
    found))

(defun drgnx-look-scene--header-targets-wait (window &optional panel)
  "`drgnx-look-scene--header-targets' of WINDOW (and PANEL) once it has all three parts: the hub may draw the header
again (a new width, a click's look), so they are looked for again until they are there (at most 5 s)."
  (let ((end (+ (float-time) 5)) targets)
    (while (progn (setq targets (drgnx-look-scene--header-targets window panel))
                  (and (not (and (assq 'pin targets) (assq 'lens targets) (assq 'pill targets)))
                       (< (float-time) end)))
      (accept-process-output nil 0.05)
      (redisplay t))
    (dolist (kind '(pin lens pill) targets)
      (unless (assq kind targets)
        (error "no %s in the header window within 5 s (found %S; the header's first line %S)" kind
               (mapcar #'car targets)
               (with-current-buffer (window-buffer window)
                 (buffer-substring-no-properties (point-min) (line-end-position))))))))

(defun drgnx-look-scene--action-at (window posn)
  "The `drgnx-agent-panel-action' at POSN in WINDOW's buffer (or in the string POSN is over)."
  (let ((str (posn-string posn)))
    (if (and (consp str) (stringp (car str))) (get-text-property (cdr str) 'drgnx-agent-panel-action (car str))
      (get-text-property (posn-point posn) 'drgnx-agent-panel-action (window-buffer window)))))

(defun drgnx-look-scene--entry-in (window buffer &optional n)
  "The position in WINDOW, which shows BUFFER, of the Nth (from 0, default 0) step's row (`drgnx-agent-panel-entry')
from its start, or nil."
  (with-current-buffer buffer
    (let ((pos (window-start window)) (end (min (point-max) (or (window-end window t) (point-max))))
          (n (or n 0)) (found nil))
      (while (and pos (< pos end) (not found))
        (if (and (get-text-property pos 'drgnx-agent-panel-entry) (< (cl-decf n) 0))
            (setq found pos)
          (setq pos (next-single-property-change pos 'drgnx-agent-panel-entry nil end))))
      found)))

(defun drgnx-look-scene--panel-header-clicks (buffer)
  "Scroll the transcript up a page, then click the header window's pin button, a lens segment and a strip pill through
the event loop, as a pointer's press and release arrive: each runs its command, and the header window does not move.
The transcript is left scrolled up: the picture is the scrolled panel."
  (pcase-let* ((`(,h ,w ,_) (drgnx-look-scene--docks buffer)))
    (select-window w)
    (set-window-point w (window-start w))
    (let ((back (with-current-buffer buffer (- (point-max) (window-start w)))))
      (scroll-down 15)
      (redisplay t)
      (unless (> (with-current-buffer buffer (- (point-max) (window-start w))) back)
        (error "the transcript did not scroll up (start %d)" (window-start w))))
    (let ((header (drgnx-look-scene--edges h)) (targets (drgnx-look-scene--header-targets-wait h)))
      ;; each click runs its command for real, on the session's state (the panel's buffer): the pin pins the step
      ;; at the transcript's point, a lens segment sets its preset's disclosure, a pill turns its type's detail over
      ;; the step pinned is the window's second, not its first row's; the transcript is not the selected window and
      ;; the panel buffer's own point is on its first row, so only the window's point names it
      (let ((first (drgnx-look-scene--entry-in w buffer)) (pos (drgnx-look-scene--entry-in w buffer 1)))
        (unless pos (error "no second step's row in the transcript's window to pin"))
        (when (equal (get-text-property pos 'drgnx-agent-panel-entry buffer)
                     (get-text-property first 'drgnx-agent-panel-entry buffer))
          (error "the transcript window's first and second step rows are one step"))
        (select-window h)
        (with-current-buffer buffer (goto-char (point-min)))
        (set-window-point w pos)
        (let ((key (list :e (get-text-property pos 'drgnx-agent-panel-entry buffer)))
              (pins (lambda () (mapcar #'car (buffer-local-value 'drgnx-agent-panel--pins buffer)))))
          (when (member key (funcall pins)) (error "the step %S is pinned before the click" key))
          (when (or (eq w (selected-window)) (= pos (with-current-buffer buffer (point))))
            (error "premise: the transcript is selected, or the panel buffer's point is the step's"))
          (drgnx-uitest-run (drgnx-uitest-click-events (alist-get 'pin targets)))
          (redisplay t)
          (unless (member key (funcall pins))
            (error "a click on the header's pin through the event loop did not pin %S (pins %S)" key (funcall pins)))))
      (setq targets (drgnx-look-scene--header-targets-wait h))
      (let* ((type (intern (substring (drgnx-look-scene--action-at h (alist-get 'pill targets)) 5)))
             (on (lambda () (and (memq type (buffer-local-value 'drgnx-agent-panel--disclosure buffer)) t)))
             (was (funcall on)))
        (drgnx-uitest-run (drgnx-uitest-click-events (alist-get 'pill targets)))
        (redisplay t)
        (unless (eq (funcall on) (not was))
          (error "a click on the header's pill %s through the event loop left its detail %s" type (if was "on" "off"))))
      (setq targets (drgnx-look-scene--header-targets-wait h buffer))
      (let* ((n (string-to-number (substring (drgnx-look-scene--action-at h (alist-get 'lens targets)) 5)))
             (want (cdr (nth (1- n) (symbol-value 'drgnx-agent-panel-presets)))))
        (drgnx-uitest-run (drgnx-uitest-click-events (alist-get 'lens targets)))
        (redisplay t)
        (unless (equal want (buffer-local-value 'drgnx-agent-panel--disclosure buffer))
          (error "a click on the header's lens %d through the event loop left the disclosure %S, not %S" n
                 (buffer-local-value 'drgnx-agent-panel--disclosure buffer) want)))
      (unless (equal (drgnx-look-scene--edges h) header)
        (error "the clicks moved the header window: %S, was %S" (drgnx-look-scene--edges h) header)))))

(defvar drgnx-hub--events)
(declare-function drgnx-hub--call-on "drgnx-hub-client")
(declare-function drgnx-view-sja-p "drgnx-view-sja")
(declare-function drgnx-view-sja-draw-now "drgnx-view-sja")

(defun drgnx-look-scene--hub-caught-up ()
  "Non-nil once a `ping' on the subscribed connection is answered (3 s at most): the hub handles a connection's lines
in order, so every line this Emacs sent before it (an env, a measurement, an ack) has been handled, and what the hub
sent for them came before the answer and has been read."
  (let ((done nil) (end (+ (float-time) 3)))
    (when (process-live-p drgnx-hub--events)
      (drgnx-hub--call-on drgnx-hub--events "ping" nil (lambda (&rest _) (setq done t)))
      (while (and (not done) (< (float-time) end))
        (accept-process-output drgnx-hub--events 0.02)))
    done))

(defvar drgnx-look-scene--asks-open 0
  "The hub's `view-glyphs' asks this session has seen less its `view/glyphs' answers: the hub refits a row after the
answer, so a round trip while one is open proves nothing settled.  A plain count, as an answer sent at once goes out
from the event's handlers before or after the counting one, by their order.")

(defun drgnx-look-scene--ask-seen (event _data)
  "A `drgnx-hub-event-functions' handler: count a `view-glyphs' ask as open."
  (when (equal event "view-glyphs") (setq drgnx-look-scene--asks-open (1+ drgnx-look-scene--asks-open))))

(defun drgnx-look-scene--answer-sent (send method params)
  "Around `drgnx-view-env-send-function' (SEND): a `view/glyphs' METHOD closes an open ask, whenever it is sent."
  (when (equal method "view/glyphs")
    (setq drgnx-look-scene--asks-open (1- drgnx-look-scene--asks-open)))
  (funcall send method params))

;; the whole session: the asks come from the panel's first fit, before any settle
(add-hook 'drgnx-hub-event-functions #'drgnx-look-scene--ask-seen)
(defvar drgnx-view-env-send-function)
(with-eval-after-load 'drgnx-view-env
  (add-function :around drgnx-view-env-send-function #'drgnx-look-scene--answer-sent))

(defun drgnx-look-scene--hub-round (buffers)
  "One round trip to the hub (`drgnx-look-scene--hub-caught-up') and what it sent drawn in BUFFERS, Sjá views; non-nil
when the round trip changed none of their texts and no ask of the hub's is still unanswered
\(`drgnx-look-scene--asks-open': an answer sent later, on a timer, comes after the ping, and so does its refit),
`no-answer' when the hub did not answer."
  (let ((ticks (mapcar #'buffer-chars-modified-tick buffers)))
    (if (not (drgnx-look-scene--hub-caught-up)) 'no-answer
      (accept-process-output nil 0.05)
      (dolist (b buffers) (when (drgnx-view-sja-p b) (drgnx-view-sja-draw-now b)))
      (redisplay t)
      (and (<= drgnx-look-scene--asks-open 0)
           (equal ticks (mapcar #'buffer-chars-modified-tick buffers))))))

(defun drgnx-look-scene--panel-buffers (buffer)
  "The live buffers of the agent panel BUFFER's windows: the transcript, the header and the composer shown with it."
  (let ((w (get-buffer-window buffer)))
    (seq-filter #'buffer-live-p
                (cons buffer (and w (mapcar (lambda (e) (window-buffer (car e))) (drgnx-look-scene--area-windows w)))))))

(defun drgnx-look-scene--panel-settle (buffer)
  "Round trips to the hub until one changes none of the agent panel BUFFER's windows' texts: the hub's first fit of a
row comes before the editor's answers to its asks (the glyph widths), and the refit after them one round trip later.
An error when the hub does not answer, or when the rows still change after 10 s."
  (let ((buffers (drgnx-look-scene--panel-buffers buffer)) (end (+ (float-time) 10)) (r nil))
    (while (and (not (eq r t)) (not (eq r 'no-answer)) (< (float-time) end))
      (setq r (drgnx-look-scene--hub-round buffers)))
    (cond ((eq r 'no-answer) (push "agent-panel: the hub did not answer a ping" drgnx-look-scene--errors))
          ((not r) (push "agent-panel: the panel's rows still changed after 10 s of hub round trips"
                         drgnx-look-scene--errors)))))

(defun drgnx-look-scene--panel-unsettled (buffer)
  "An error when one more hub round trip changes the agent panel BUFFER's windows' texts: the shot would show the
hub's first fit (a chip cut before the editor's glyph widths came), not the rows the hub settles on.  The error names
what changed: the buffers whose text did, each window's body width before and after, and the asks still open."
  (let* ((buffers (drgnx-look-scene--panel-buffers buffer))
         (widths (lambda () (mapcar (lambda (b) (let ((w (get-buffer-window b))) (and w (window-body-width w t))))
                                    buffers)))
         (ticks (mapcar #'buffer-chars-modified-tick buffers))
         (before (funcall widths))
         (r (drgnx-look-scene--hub-round buffers)))
    (unless (eq r t)
      (push (if (eq r 'no-answer) "agent-panel: the hub did not answer a ping"
              (format "agent-panel: one more hub round trip changed the panel's rows: the shot shows the hub's first fit (changed %S, widths %S then %S, asks open %d)"
                      (delq nil (cl-mapcar (lambda (b tick) (and (/= tick (buffer-chars-modified-tick b)) (buffer-name b)))
                                           buffers ticks))
                      before (funcall widths) drgnx-look-scene--asks-open))
            drgnx-look-scene--errors))))

(defun drgnx-look-scene-agent-panel ()
  (drgnx-look-scene--theme 'drgnx-dark)
  (drgnx-look-scene--try "panel"
    (unless (buffer-live-p drgnx-look-scene--panel) (error "No agent panel (the mock agent did not run)"))
    (if-let* ((w (get-buffer-window drgnx-look-scene--panel)))
        (select-window w)
      ;; an earlier scene put the editor back: the panel opens again where opening it puts it, the right island
      (drgnx-pane-show 'agent-panel :buffer drgnx-look-scene--panel :select t))
    ;; the rows the hub settles on, not its first fit (the checks and the shot read them)
    (drgnx-look-scene--panel-settle drgnx-look-scene--panel)
    (drgnx-look-scene--panel-top drgnx-look-scene--panel))
  (drgnx-look-scene--try "three windows" (drgnx-look-scene--panel-three-windows drgnx-look-scene--panel))
  (drgnx-look-scene--try "settled" (drgnx-look-scene--panel-unsettled drgnx-look-scene--panel))
  (drgnx-look-scene--answer))

(defun drgnx-look-scene--panel-top (buffer)
  "An error unless the header window above BUFFER, the agent panel's transcript, holds the hub's header row (`p:head')
and the transcript's window, its point at the end, shows the end whole on its last line (or the whole transcript at
its top, when it fits): what the panel opened by its command path shows first, once the header is fitted to its rows."
  (let* ((w (get-buffer-window buffer))
         (h (and w (car (seq-find (lambda (e) (eq (nth 1 e) 'above)) (drgnx-look-scene--area-windows w)))))
         (hb (and h (window-buffer h)))
         (state (and hb (buffer-local-value 'drgnx-view-patch hb))))
    (unless (drgnx-look-scene--until 10 "the header window's row from the hub"
                                     (lambda () (and hb (drgnx-look-scene--has-row-p hb "p:head"))))
      (push (format "agent-panel: no `p:head' row in the header window; header %S, its view %S, version %S, env classes %S"
                    (and hb (buffer-name hb)) (and state (drgnx-view-patch-view state))
                    (and state (drgnx-view-patch-version state))
                    (and state (drgnx-view-env-classes (drgnx-view-patch-view state))))
            drgnx-look-scene--errors))
    (when w
      ;; the header's fit after its rows changed the transcript's height: the windows as they are drawn now
      (redisplay t)
      ;; the first rows leave point at the end (`drgnx-view-sja-tail'); Emacs scrolls by whole rows, so under the end's
      ;; row (its bottom as redisplay drew it, a card or image included) there is less
      ;; space than the screen line before the start would take.  A start at the top passes only when the end is shown
      ;; whole, that is when the transcript fits
      (let* ((end (with-current-buffer buffer (point-max)))
             (at (pos-visible-in-window-p end w t))
             (body (window-body-height w t)) (start (window-start w))
             ;; the bottom of the screen line redisplay drew at the end's y (its drawn height)
             (bottom (and at (let ((y (cadr at)) (n 0) r b)
                               (while (and (not b) (setq r (window-line-height n w)))
                                 (when (and (<= (nth 2 r) y) (< y (+ (nth 2 r) (car r)))) (setq b (+ (nth 2 r) (car r))))
                                 (setq n (1+ n)))
                               (or b (+ y (window-default-line-height w))))))
             (above (and at (> start (with-current-buffer buffer (point-min)))
                         (let ((prev (with-selected-window w (save-excursion (goto-char start) (vertical-motion -1) (point)))))
                           (if (< prev start) (cdr (window-text-pixel-size w prev start)) 0))))
             (why (cond ((/= (window-point w) end) (format "its point %d is not its end %d" (window-point w) end))
                        ((or (not at) (nth 2 at)) "its end is not shown whole")
                        ((and above (>= (- body bottom) above))
                         (format "its end is not at the bottom of its window (a row of %d px more would fit)" above)))))
        (when why
          (push (format "agent-panel: %s (start %d, end at %S, its row's bottom %d, body %d)" why start at bottom body)
                drgnx-look-scene--errors))))))

(defun drgnx-look-scene--palette-commands ()
  "palette.html's commands for \"run te\": the test runner's three and the terminal's, with the mockup's keys, first in
the registry as the mockup lists them; Rerun Last Tests was run 2 minutes ago.  drgnx has no test runner commands of
its own yet, so the scene registers stand-ins that do nothing."
  (drgnx-look-scene--try "palette commands"
    (pcase-dolist (`(,id ,title ,category ,key)
                   '((look-scene-run-file "Run Tests in This File" "Tests" "C-; f")
                     (look-scene-run-at-point "Run Test at Point" "Tests" "C-; t")
                     (look-scene-rerun "Rerun Last Tests" "Tests" "C-; r")
                     (look-scene-run-in-terminal "Run in Terminal…" "Terminal" nil)))
      (drgnx-command-define id :title title :category category :command #'ignore)
      (when key (setf (drgnx-cmd-bound (drgnx-commands-get id)) (list (cons key nil)))))
    (let ((ids '(look-scene-run-file look-scene-run-at-point look-scene-rerun look-scene-run-in-terminal)))
      (setq drgnx-commands--order (append ids (seq-difference drgnx-commands--order ids))))
    (drgnx-palette--history)
    (setq drgnx-palette--history (cons (list 'look-scene-rerun (- (floor (float-time)) 125))
                                       (assq-delete-all 'look-scene-rerun drgnx-palette--history)))))

(defun drgnx-look-scene-palette ()
  "The editor focused, the mockup's commands registered; the session's own keys open the palette (`drgnx ui
look-scenes' types them)."
  (drgnx-look-scene--theme 'drgnx-dark)
  (drgnx-look-scene--editor)
  (drgnx-look-scene--palette-commands)
  (drgnx-look-scene--answer))

(defun drgnx-look-scene-palette-light ()
  "The palette under the light theme (palette.html is dark only: no mockup, the picture is the evidence)."
  (drgnx-look-scene--theme 'drgnx-light)
  (drgnx-look-scene--editor)
  (drgnx-look-scene--palette-commands)
  (drgnx-look-scene--answer))

(defun drgnx-look-scene-palette-hc ()
  "The palette under the high-contrast theme (palette.html is dark only: no mockup, the picture is the evidence)."
  (drgnx-look-scene--theme 'drgnx-high-contrast)
  (drgnx-look-scene--editor)
  (drgnx-look-scene--palette-commands)
  (drgnx-look-scene--answer))

(defvar drgnx-inbox--pinned)
(defvar drgnx-notice--needs-you)
(declare-function drgnx-notice-set "drgnx-notice")
(declare-function drgnx-inbox-open "drgnx-inbox")
(declare-function drgnx-inbox-pin "drgnx-inbox")
(declare-function drgnx-inbox-close "drgnx-inbox")

(defun drgnx-look-scene--waiting ()
  "Two things waiting on you, for the title row's pill and the inbox: an agent's permission ask and a failed run."
  (drgnx-notice-set 'agents (list (list :id '(permission "s1" . 7) :command 'agents-answer
                                        :text "claude · fix-explorer wants to run a command"
                                        :detail "cargo test -p explorer --release")
                                  (list :id '(permission "s2" . 3) :command 'agents-answer
                                        :text "gemini · docs-sweep wants to edit a file" :detail "README.md"))))

(defun drgnx-look-scene-title-row-dark ()
  "The title row (title-bar.html option B): logo, ☰, project switcher, search box, pill, toggles."
  (drgnx-look-scene--theme 'drgnx-dark)
  (drgnx-look-scene--editor)
  (drgnx-look-scene--waiting)
  (drgnx-look-scene--answer))

(declare-function drgnx-menubar-pick "drgnx-menubar")

(defun drgnx-look-scene-menu-list ()
  "The ☰ list open (`drgnx-menubar-pick' on F20, a key of the scene's own: F10 is the default profile's Step Over),
its first row selected by Down, a submenu not yet: the menu cards in the look."
  (drgnx-look-scene--theme 'drgnx-dark)
  (drgnx-look-scene--editor)
  (keymap-global-set "<f20>" #'drgnx-menubar-pick)
  (drgnx-look-scene--answer))

(defun drgnx-look-scene-context-menu ()
  "The editor's context menu open (S-F10, `context-menu-open'), its first row selected by Down: the menu card in the
look, as the ☰ list's."
  (drgnx-look-scene--theme 'drgnx-dark)
  (drgnx-look-scene--editor)
  (drgnx-look-scene--answer))

(defun drgnx-look-scene-title-row-light ()
  (drgnx-look-scene--theme 'drgnx-light)
  (drgnx-look-scene--editor)
  (drgnx-look-scene--waiting)
  (drgnx-look-scene--answer))

(defun drgnx-look-scene-inbox-dropdown ()
  "The inbox's drop-down under the pill (inbox.html option C)."
  (drgnx-look-scene--theme 'drgnx-dark)
  (drgnx-look-scene--editor)
  (drgnx-look-scene--waiting)
  (setq drgnx-inbox--pinned nil)
  (drgnx-inbox-open)
  (drgnx-look-scene--answer))

(defun drgnx-look-scene-inbox-pinned ()
  "The inbox pinned as a tab of the right side bar."
  (drgnx-inbox-close)
  (drgnx-look-scene--theme 'drgnx-dark)
  (drgnx-look-scene--editor)
  (drgnx-look-scene--waiting)
  (drgnx-inbox-pin)
  (drgnx-look-scene--answer))

(defun drgnx-look-scene-window-light ()
  (drgnx-look-scene--theme 'drgnx-light)
  (drgnx-look-scene--editor)
  (drgnx-look-scene--answer))

(defun drgnx-look-scene-window-hc ()
  (drgnx-look-scene--theme 'drgnx-high-contrast)
  (drgnx-look-scene--editor)
  (drgnx-look-scene--answer))

(defun drgnx-look-scene-magit ()
  (drgnx-look-scene--theme 'drgnx-dark)
  (drgnx-look-scene--try "magit"
    (require 'magit)
    (drgnx-wb-focus-editor)
    (let ((magit-save-repository-buffers nil))
      (magit-status-setup-buffer drgnx-look-scene--project))
    (drgnx-look-scene--show (current-buffer)))
  (drgnx-look-scene--answer))

(defun drgnx-look-scene-org ()
  "An Org buffer as magit.html's right-hand card: headings in the UI font, TODO chips, tags right-aligned by pixel."
  (drgnx-look-scene--theme 'drgnx-dark)
  (drgnx-look-scene--try "org"
    (drgnx-wb-focus-editor)
    (let ((file (expand-file-name "gateway.org" drgnx-look-scene--project)))
      (with-temp-file file
        (insert "* Gateway: replies after close  :core:\n** DONE Reproduce the failure  :test:\n"
                "** NEXT Queue replies to a dead client  :core:agent:\nKeep replies for a client that went away.\n"
                "** Timings\n| run | before | after |\n"))
      (find-file file)
      (goto-char (point-min))))
  (drgnx-look-scene--answer))

(defun drgnx-look-scene-shell-heredoc ()
  "The user's case: a shell script with a Python heredoc (the package faces of sh-script)."
  (drgnx-look-scene--theme 'drgnx-dark)
  (drgnx-look-scene--try "heredoc"
    (drgnx-wb-focus-editor)
    (find-file (expand-file-name "docs/p2-verify.sh" drgnx-look-scene--project))
    (goto-char (point-max)))
  (drgnx-look-scene--answer))

(declare-function drgnx-work-map-rows-p "drgnx-work-map")

(defun drgnx-look-scene--work-map ()
  "The Work map on the scenes' hub (its seeded plan run), drawn from the hub's rows; nil, with an error, when it is not:
a map off the rows path or without a hub draws a placeholder, and a shot of that judges nothing."
  (drgnx-look-scene--hub)
  (let ((map (drgnx-work-space-open)))
    (unless (drgnx-work-map-rows-p)
      (error "The Work map is off the rows path (this Emacs has no Sjá: run the scenes on Nidhogg's line, --line)"))
    ;; the hub sends the map's rows after it opens and the view draws them on a timer once its window shows: the
    ;; shot waits for the first of them (redisplay and timers run in `sit-for'), not an empty window
    (and (drgnx-look-scene--until 15 "work map rows"
                                  (lambda () (with-current-buffer map (drgnx-look-scene--row-ids ""))))
         map)))

(declare-function drgnx-work-detail-buffer "drgnx-work-detail")
(declare-function drgnx-layouts-current "drgnx-layouts")
(declare-function drgnx-layouts-apply "drgnx-layouts")
(defvar drgnx-work-space--panel-trail)
(defvar drgnx-notice--needs-you)
(defvar drgnx-topline-agents-function)
(declare-function drgnx-work-map--needs-you-count "drgnx-work-map")
(declare-function drgnx-work-map--team "drgnx-work-map")
(declare-function drgnx-work-map-set-mode "drgnx-work-map")

(defun drgnx-look-scene--work-selected (theme)
  "The Work map of work-space-*.html in THEME: the first agent selected, its chain lit and its detail in the side panel.
Its session's hub seeds the map's own graph (`drgnx-look-scene-seed' \"map\", the scenes' :seed)."
  (drgnx-look-scene--theme theme)
  (drgnx-look-scene--try "work space"
    (when-let* ((map (drgnx-look-scene--work-map)))
      ;; the Work space is a view in the editor (UX audit S1-1): the map in the editor group beside the Explorer, its
      ;; Detail in the right dock (`drgnx-work-space--follow-layout')
      (unless (get-buffer-window map) (set-window-buffer (drgnx-wb-editor-window) map))
      ;; the mockup is the Graph; a map opens in List mode (the default), whose rows are tasks, not agents
      (with-current-buffer map (drgnx-work-map-set-mode 'graph))
      (unless (drgnx-look-scene--until 15 "the map's seeded graph (the first agent, agent:a1)"
                                       (lambda () (with-current-buffer map
                                                    (member "agent:a1" (drgnx-look-scene--row-ids "agent:")))))
        (error "The map has no seeded agent: is it the `map' seed (`drgnx-look-scene-seed' %S)?"
               drgnx-look-scene-seed))
      ;; the title row's chips (`3 need you', `4 agents') count what the map's model holds, as the notice model and the
      ;; agents module would in a session that ran these agents
      (with-current-buffer map
        (let ((need (drgnx-work-map--needs-you-count)) (agents (length (drgnx-work-map--team))))
          (setq drgnx-notice--needs-you need
                drgnx-topline-agents-function (lambda () agents))))
      (let ((win (get-buffer-window map)))
        (with-selected-window win (drgnx-view-nav 'select "agent:a1")))
      (drgnx-look-scene--until 15 "the side panel of the selected agent (Why, Touches)"
                               (lambda ()
                                 (with-current-buffer (drgnx-work-detail-buffer map)
                                   (save-excursion (goto-char (point-min)) (search-forward "Touches" nil t)))))
      ;; the trail tile follows the selection: its steps and the finding are drawn from the hub's rows
      (drgnx-look-scene--until 15 "the trail under the map (its finding card)"
                               (lambda ()
                                 (and (buffer-live-p drgnx-work-space--panel-trail)
                                      (with-current-buffer drgnx-work-space--panel-trail
                                        (save-excursion (goto-char (point-min)) (search-forward "Finding" nil t))))))))
  (drgnx-look-scene--answer))

(defun drgnx-look-scene-work-space-dark () (drgnx-look-scene--work-selected 'drgnx-dark))
(defun drgnx-look-scene-work-space-light () (drgnx-look-scene--work-selected 'drgnx-light))
(defun drgnx-look-scene-work-space-hc () (drgnx-look-scene--work-selected 'drgnx-high-contrast))

(declare-function drgnx-work-flow-open "drgnx-work-flow")
(declare-function drgnx-work-flow-detail-show "drgnx-work-flow")
(declare-function drgnx-work-flow-detail-buffer "drgnx-work-flow")
(declare-function drgnx-work-flow-rules-buffer "drgnx-work-flow")
(declare-function drgnx-work-flow-rules "drgnx-work-flow")
(declare-function drgnx-view-nav "drgnx-view")

(defun drgnx-look-scene-work-flow ()
  "The Flow lens beside the scene's map (the mockup hub-orchestration), on the hub's seeded plan run: its tasks in each
gate state, the held one, the batch.  A Flow without the run's task rows (its waiting or off-path text) is an error."
  (drgnx-look-scene--theme 'drgnx-dark)
  (drgnx-look-scene--try "work flow"
    (when-let* ((map (drgnx-look-scene--work-map))
                (flow (drgnx-work-flow-open map)))
      (pop-to-buffer-same-window flow)
      ;; the Flow in the editor group beside the Explorer, as any Work lens (UX audit S1-1)
      (unless (get-buffer-window flow) (set-window-buffer (drgnx-wb-editor-window) flow))
      ;; the held task's row (its `drgnx-work-id' is the task's id) and the batch's heading
      (drgnx-look-scene--until 15 "the seeded run's Flow rows (scene-run#5, the batch)"
                               (lambda ()
                                 (with-current-buffer flow
                                   (and (member "scene-run#5" (drgnx-look-scene--row-ids "scene-run#"))
                                        (save-excursion (goto-char (point-min))
                                                        (search-forward "Merge batch" nil t))))))
      ;; the held task selected (Tab walks the held ones): its detail tile where the map's side panel was, and the
      ;; Rules tile in the bottom panel, each waited for with its rows, not its placeholder
      (with-selected-window (get-buffer-window flow) (drgnx-view-nav 'walk "held" 1))
      (drgnx-work-flow-detail-show flow)
      (with-current-buffer flow (drgnx-work-flow-rules))
      (drgnx-look-scene--until 15 "the detail tile of the held task and the Rules tile"
                               (lambda ()
                                 (and (with-current-buffer (drgnx-work-flow-detail-buffer flow)
                                        (save-excursion (goto-char (point-min))
                                                        (search-forward "Why it is held" nil t)))
                                      (with-current-buffer (drgnx-work-flow-rules-buffer flow)
                                        (save-excursion (goto-char (point-min))
                                                        (search-forward "Rules · scene-pack" nil t))))))))
  (drgnx-look-scene--answer))

;; The highlights (look step 5b's audit): no mockup of their own; each is judged against the mockups' tokens
;; (look.css) in strips cut from these shots.  Highlights a command makes (isearch's, show-paren's, eglot's, Flymake's,
;; a rectangle's) are drawn with their faces as overlays, the way those commands draw them, so one shot holds all.

(defconst drgnx-look-scene--diff
  "diff --git a/core/drgnx-gateway.el b/core/drgnx-gateway.el
--- a/core/drgnx-gateway.el
+++ b/core/drgnx-gateway.el
@@ -213,4 +213,4 @@ (defun drgnx-gateway--reply (p reply)
   \"Send REPLY to the client process P.\"
-  (when (process-live-p p)
+  (if (process-live-p p)
       (process-send-string p reply)
-    nil))
+    (drgnx-gateway--queue p reply)))
"
  "A hunk with two changed line pairs, for the diff highlights.  Its header counts its lines (four a side): with a
wrong count `diff-refine-hunk' finds no pairs and refines nothing.")

(defun drgnx-look-scene--hl-put (beg end face)
  "An overlay of the scene's from BEG to END in FACE."
  (let ((o (make-overlay beg end)))
    (overlay-put o 'face face) (overlay-put o 'drgnx-hl-scene t) (overlay-put o 'priority 10)
    o))

(defun drgnx-look-scene--hl-at (line text face &optional nth)
  "FACE over the NTH (from 0) TEXT on LINE of the current buffer."
  (save-excursion
    (goto-char (point-min)) (forward-line (1- line))
    (let ((eol (pos-eol)))
      (dotimes (_ (1+ (or nth 0))) (search-forward text eol))
      (drgnx-look-scene--hl-put (- (point) (length text)) (point) face))))

(defun drgnx-look-scene--highlights (theme)
  "THEME's highlights in one shot: two editor groups (the focused card's ring), the gateway file with the current
line, a multi-line region with a match inside it, a rectangle, isearch's current and other matches, show-paren,
eglot's symbol, Flymake's marks; a diff with a refined pair beside it; a hovered row in the Explorer and in Open."
  (drgnx-look-scene--theme theme)
  (drgnx-look-scene--try "highlights"
    (require 'flymake) (require 'eglot) (require 'paren)     ; their faces
    (drgnx-look-scene--editor)
    (let ((left (selected-window)))
      ;; the diff beside it, in a narrow second group (set directly: showing it would go to the editor window)
      (unless (window-in-direction 'right left)
        (set-window-buffer
         (split-window left (- (round (* 0.36 (window-total-width left)))) 'right)
         (with-current-buffer (get-buffer-create "hl-scene.diff")
           (let ((inhibit-read-only t)) (erase-buffer) (insert drgnx-look-scene--diff))
           (diff-mode) (goto-char (point-min)) (diff-hunk-next) (ignore-errors (diff-refine-hunk))
           (current-buffer))))
      (with-current-buffer (window-buffer left)
        (remove-overlays (point-min) (point-max) 'drgnx-hl-scene t)
        (when (fboundp 'hl-line-mode) (hl-line-mode 1))
        (setq-local highlight-nonselected-windows t)
        ;; isearch on drgnx-gateway--pending: the current match, the others lazily
        (drgnx-look-scene--hl-at 203 "drgnx-gateway--pending" 'isearch)
        (drgnx-look-scene--hl-at 208 "drgnx-gateway--pending" 'lazy-highlight)
        (drgnx-look-scene--hl-at 210 "drgnx-gateway--pending" 'lazy-highlight)
        ;; show-paren on the defun of line 213 and its close, eglot's symbol on `reply'
        (drgnx-look-scene--hl-at 213 "(" 'show-paren-match)
        (drgnx-look-scene--hl-at 217 ")" 'show-paren-match 2)
        (drgnx-look-scene--hl-at 216 "reply" 'eglot-highlight-symbol-face)
        (drgnx-look-scene--hl-at 217 "reply" 'eglot-highlight-symbol-face)
        ;; Flymake: the unused `old' and the unknown function
        (drgnx-look-scene--hl-at 208 "old" 'flymake-warning)
        (drgnx-look-scene--hl-at 229 "drgnx-gateway--log" 'flymake-error)
        ;; a rectangle (rectangle-mark-mode draws its lines as region overlays)
        (dolist (l '(220 221 222))
          (save-excursion (goto-char (point-min)) (forward-line (1- l)) (move-to-column 2)
                          (drgnx-look-scene--hl-put (point) (progn (move-to-column 24) (point)) 'region))))
      ;; the region, lines 225-227, drawn as the region is (its face over the text, so point stays on line 216's
      ;; current line)
      (with-current-buffer (window-buffer left)
        (save-excursion
          (goto-char (point-min)) (forward-line 224) (move-to-column 1)
          (let ((beg (point))) (forward-line 2) (move-to-column 20) (drgnx-look-scene--hl-put beg (point) 'region))
          ;; a match inside it (over the region, as isearch's matches are)
          (forward-line -1) (move-to-column 4)
          (overlay-put (drgnx-look-scene--hl-put (point) (progn (move-to-column 16) (point)) 'lazy-highlight)
                       'priority 20))))
    ;; a hovered row in Open and in the Explorer (the pointer's `mouse-face', drawn as its face: the row's text and
    ;; its tail at the right edge, which the pointer lights with it)
    (dolist (w (window-list nil 'never))
      (when (window-parameter w 'window-side)
        (with-current-buffer (window-buffer w)
          (remove-overlays (point-min) (point-max) 'drgnx-hl-scene t)
          (save-excursion
            (goto-char (point-min)) (forward-line 2)
            (let ((tail (seq-find (lambda (o) (overlay-get o 'drgnx-row-tail)) (overlays-in (pos-bol) (pos-eol))))
                  (hover (drgnx-wb-row-hover-face)))
              (drgnx-look-scene--hl-put (pos-bol) (pos-eol) hover)
              (when tail (drgnx-wb--tail-paint tail hover))))))))
  (drgnx-look-scene--answer))

(defun drgnx-look-scene-highlights-dark () (drgnx-look-scene--highlights 'drgnx-dark))
(defun drgnx-look-scene-highlights-light () (drgnx-look-scene--highlights 'drgnx-light))
(defun drgnx-look-scene-highlights-hc () (drgnx-look-scene--highlights 'drgnx-high-contrast))

(defun drgnx-look-scene--explorer-focused (theme)
  "The window scene under THEME with the Explorer focused: its selected row with the focus ring, the other
sections' with the inactive selection."
  (drgnx-look-scene--theme theme)
  (drgnx-look-scene--editor)
  (when-let* ((w (get-buffer-window drgnx-explorer-buffer-name)))
    (select-window w)
    (drgnx-wb--selected-changed nil))
  (drgnx-look-scene--answer))

(defun drgnx-look-scene-explorer-focused-dark () (drgnx-look-scene--explorer-focused 'drgnx-dark))
(defun drgnx-look-scene-explorer-focused-light () (drgnx-look-scene--explorer-focused 'drgnx-light))
(defun drgnx-look-scene-explorer-focused-hc () (drgnx-look-scene--explorer-focused 'drgnx-high-contrast))

;;;; The Extensions list beside the Explorer: no mockup of its own; its kind icons are judged against the Explorer's rows

(declare-function drgnx-extensions-open "drgnx-extensions-list")
(declare-function drgnx-extensions-list--hub-fed-p "drgnx-extensions-list")
(defvar drgnx-extensions-list-buffer-name)

(defconst drgnx-look-scene--catalog
  (concat "{\"version\":1,\"archives\":[{\"name\":\"gnu\",\"url\":\"https://elpa.gnu.org/packages/\",\"signed\":true}],"
          "\"packages\":["
          "{\"name\":\"dash\",\"summary\":\"A modern list API\",\"versions\":[{\"archive\":\"gnu\",\"version\":\"2.19\",\"reqs\":[]}],"
          "\"candidate\":{\"archive\":\"gnu\",\"version\":\"2.19\"}},"
          "{\"name\":\"magit\",\"summary\":\"A Git porcelain inside Emacs\",\"versions\":[{\"archive\":\"gnu\",\"version\":\"4.2\",\"reqs\":[]}],"
          "\"candidate\":{\"archive\":\"gnu\",\"version\":\"4.2\"},\"update\":{\"from\":\"4.1\",\"to\":\"4.2\"}},"
          "{\"name\":\"vertico\",\"summary\":\"VERTical Interactive COmpletion\",\"versions\":[{\"archive\":\"gnu\",\"version\":\"2.0\",\"reqs\":[]}],"
          "\"candidate\":{\"archive\":\"gnu\",\"version\":\"2.0\"}}],"
          "\"builtins\":[{\"name\":\"eglot\",\"version\":\"1.17\",\"summary\":\"The Emacs Client for LSP servers\"},"
          "{\"name\":\"project\",\"version\":\"0.11\",\"summary\":\"Operations on the current project\"}]}")
  "The scene's catalog: three installed packages (one with an update) and two built-ins.")

(defconst drgnx-look-scene--lock
  (concat "(:version 1 :packages ((dash :version \"2.19\" :archive \"gnu\" :kind tar :sha256 \"aa\" :requires nil :verified t)"
          " (magit :version \"4.1\" :archive \"gnu\" :kind tar :sha256 \"bb\" :requires nil :wanted user)"
          " (vertico :version \"2.0\" :archive \"gnu\" :kind tar :sha256 \"cc\" :requires nil :wanted user)))")
  "The scene's lock: what the catalog's installed rows are.")

(defun drgnx-look-scene--extensions-fixture ()
  "The hub's Extensions sources in the session's temp HOME: the catalog, the lock (when the session has none), and a
plugin installed through the hub (an unapproved plugin row)."
  (let* ((xdg (lambda (var dot) (expand-file-name "drgnx" (or (getenv var) (expand-file-name dot "~")))))
         (cache (expand-file-name "extensions" (funcall xdg "XDG_CACHE_HOME" ".cache")))
         (config (or (getenv "DRGNX_CONFIG_DIR") (funcall xdg "XDG_CONFIG_HOME" ".config")))
         (lock (expand-file-name "drgnx.lock.eld" config))
         (plugin (expand-file-name "look-plugin" temporary-file-directory)))
    (make-directory cache t)
    (with-temp-file (expand-file-name "catalog.json" cache) (insert drgnx-look-scene--catalog))
    (unless (file-exists-p lock)
      (make-directory config t)
      (with-temp-file lock (insert drgnx-look-scene--lock)))
    (make-directory plugin t)
    (with-temp-file (expand-file-name "plugin.json" plugin)
      (insert "{\"name\": \"word-count\", \"version\": \"1.0.0\", \"hosts\": []}"))
    (with-temp-file (expand-file-name "plugin.wasm" plugin) (insert "wasm-one"))
    (call-process (getenv "DRGNX_RATATOSKR_BIN") nil nil nil "plugins" "install" plugin)))

(defun drgnx-look-scene--extensions (theme)
  "The window scene under THEME with the Extensions list (the hub's rows: package, plugin and module icons) in the
editor, the Explorer's rows beside it."
  (drgnx-look-scene--theme theme)
  (drgnx-look-scene--editor)
  (require 'drgnx-extensions-list)
  (unless (get-buffer drgnx-extensions-list-buffer-name)   ; once: the scenes share a session
    (drgnx-look-scene--try "fixture" (drgnx-look-scene--extensions-fixture)))
  (drgnx-look-scene--try "extensions"
    (drgnx-wb-focus-editor)
    (drgnx-extensions-open)
    (drgnx-look-scene--until 20 "extensions rows"
                             (lambda () (and (drgnx-extensions-list--hub-fed-p)
                                             (with-current-buffer drgnx-extensions-list-buffer-name
                                               (> (buffer-size) 0)))))
    (with-current-buffer drgnx-extensions-list-buffer-name (goto-char (point-min))))
  (drgnx-look-scene--answer))

(defvar drgnx-extensions-list--opened)
(declare-function drgnx-extensions-list--ask "drgnx-extensions-list")

(defun drgnx-look-scene-extensions-builtin-open ()
  "The Extensions list with its Built-in section opened (TAB on the header): the packages drgnx provides, each with the
module that uses it."
  (drgnx-look-scene--extensions 'drgnx-dark)
  (drgnx-look-scene--try "built-in section"
    (with-current-buffer drgnx-extensions-list-buffer-name
      (setq drgnx-extensions-list--opened '(bundled))
      (drgnx-extensions-list--ask)
      (drgnx-look-scene--until 20 "built-in rows"
                               (lambda () (save-excursion (goto-char (point-min)) (search-forward "drgnx module" nil t))))
      (goto-char (point-min))
      (when (search-forward "Built-in (" nil t) (beginning-of-line))))
  (drgnx-look-scene--answer))

(defun drgnx-look-scene-extensions-dark () (drgnx-look-scene--extensions 'drgnx-dark))
(defun drgnx-look-scene-extensions-light () (drgnx-look-scene--extensions 'drgnx-light))
(defun drgnx-look-scene-extensions-hc () (drgnx-look-scene--extensions 'drgnx-high-contrast))

;;;; The Search view's preview tile and Replace All sheet (search-view.html)

(defvar drgnx-replace-buffer-name)
(defvar drgnx-replace-sheet-buffer-name)
(defvar drgnx-replace--hub-counts)
(defvar drgnx-replace--preview)
(defvar drgnx-replace--sheet)
(defvar drgnx-replace--kind-counts)
(defvar drgnx-replace--kinds-on)
(defvar drgnx-replace-view)
(defvar drgnx-hub--events)
(declare-function drgnx-replace--open "drgnx-replace")
(declare-function drgnx-replace-kind-toggle "drgnx-replace")
(declare-function drgnx-hub--call-on "drgnx-hub-client")
(declare-function drgnx-settings-file-put "drgnx-settings-file")
(declare-function drgnx-replace-in-files "drgnx-replace")
(declare-function drgnx-replace--opt "drgnx-replace")
(declare-function drgnx-replace--toggle "drgnx-replace")
(declare-function drgnx-replace--fill "drgnx-replace")
(declare-function drgnx-replace--search-now "drgnx-replace")
(declare-function drgnx-replace--rows-tick "drgnx-replace")
(declare-function drgnx-replace--preview-params "drgnx-replace")
(declare-function drgnx-replace-preview-file "drgnx-replace")
(declare-function drgnx-replace-all "drgnx-replace")
(declare-function drgnx-replace--hub-ready-p "drgnx-replace")
(declare-function drgnx-hub-running-p "drgnx-hub-client")
(declare-function drgnx-view-draw-now "drgnx-view")
(declare-function drgnx-view-p "drgnx-view")
(declare-function drgnx-notebook-outline "drgnx-notebook")
(declare-function drgnx-notebook-open-output "drgnx-notebook")
(declare-function drgnx-notebook-run-cell "drgnx-notebook")
(declare-function drgnx-notebook--blocks-update "drgnx-notebook")
(declare-function drgnx-notebook-output-later "drgnx-notebook")
(declare-function drgnx-notebook-kernel-log "drgnx-notebook")
(declare-function drgnx-view-env-update "drgnx-view-env")
(defvar drgnx-notebook-view--id)
(defvar drgnx-view)
(declare-function drgnx-hub-connect "drgnx-hub-client")

(defun drgnx-look-scene--until (secs what pred)
  "Wait (SECS at most) for PRED, as the user does for the hub; an error under WHAT when it never holds."
  (let ((end (+ (float-time) secs)))
    (while (and (not (funcall pred)) (< (float-time) end))
      (accept-process-output nil 0.02)
      (redisplay))
    (or (funcall pred) (progn (push (format "%s: not within %d s" what secs) drgnx-look-scene--errors) nil))))

(defun drgnx-look-scene--hub ()
  "The scenes' hub, started once and connected.  A session starts no hub (DRGNX_NO_HUB_START): the scenes run the
worktree's own ($DRGNX_RATATOSKR_BIN, a test-hooks build) in the foreground, as the perf workloads do, ended with the
session, seeded with `drgnx-look-scene-seed'."
  (unless (drgnx-hub-running-p)
    (let ((bin (getenv "DRGNX_RATATOSKR_BIN"))
          (process-environment (append (list "RATATOSKR_SUPERVISOR=none"
                                             (concat "RATATOSKR_SEED_SCENE=" drgnx-look-scene-seed))
                                       process-environment)))
      (unless (and bin (file-executable-p bin)) (error "No ratatoskr binary (DRGNX_RATATOSKR_BIN)"))
      (make-process :name "ratatoskr" :noquery t :connection-type 'pipe
                    :buffer (generate-new-buffer " *ratatoskr*")
                    :command (list bin "serve" "--foreground" "--parent-pid" (number-to-string (emacs-pid))))
      (drgnx-look-scene--until 30 "hub start" #'drgnx-hub-running-p)))
  (drgnx-hub-connect))

(defun drgnx-look-scene--search ()
  "The mockup's search in the Search view: regexp `(gateway)--pending' replaced by `\\1--queued' in the project, the
match on line 209 (the `puthash' line) unticked; the view's buffer, or nil."
  (drgnx-look-scene--theme 'drgnx-dark)
  (drgnx-look-scene--editor)
  (drgnx-look-scene--try "hub"                 ; the Search view's rows come from the hub
    (unless (drgnx-replace--hub-ready-p)
      (drgnx-look-scene--hub)
      (drgnx-look-scene--until 20 "hub" #'drgnx-replace--hub-ready-p)))
  (drgnx-look-scene--try "search"
    (drgnx-replace-in-files)
    (with-current-buffer (get-buffer drgnx-replace-buffer-name)
      (unless (drgnx-replace--opt :regexp) (drgnx-replace--toggle :regexp))
      (drgnx-replace--fill 'replace "\\1--queued")
      (drgnx-replace--fill 'find "(gateway)--pending")
      (drgnx-replace--search-now)
      (when (drgnx-look-scene--until 15 "search" (lambda () drgnx-replace--hub-counts))
        ;; the third match (line 209, `(puthash p (nconc'): its row's text is cut short, so found by its place
        (when-let* ((id (drgnx-look-scene--until 10 "match rows" (lambda () (nth 2 (drgnx-look-scene--row-ids "m:"))))))
          ;; once: the scenes share a session, and a tick toggles
          (unless (member id (append (plist-get (drgnx-replace--preview-params "") :off) nil))
            (drgnx-replace--rows-tick id))))
      (current-buffer))))

(defun drgnx-look-scene--row-ids (prefix)
  "The Search view's row ids (`drgnx-work-id') that start with PREFIX, in order."
  (let ((pos (point-min)) ids)
    (while (setq pos (next-single-property-change pos 'drgnx-work-id))
      (let ((id (get-text-property pos 'drgnx-work-id)))
        (when (and (stringp id) (string-prefix-p prefix id) (not (member id ids))) (push id ids))))
    (nreverse ids)))

(defun drgnx-look-scene--file-row ()
  "The start of the Search view's first file row (its `drgnx-work-id' `f:…'), or nil."
  (let ((pos (point-min)) found)
    (while (and (not found) (setq pos (next-single-property-change pos 'drgnx-work-id)))
      (let ((id (get-text-property pos 'drgnx-work-id)))
        (when (and (stringp id) (string-prefix-p "f:" id)) (setq found pos))))
    found))

(defun drgnx-look-scene-search-preview ()
  "The preview tile of the first file (core/drgnx-gateway.el) beside the Search view (search-view.html's dark window)."
  (when-let* ((view (drgnx-look-scene--search)))
    (drgnx-look-scene--try "preview"
      (with-current-buffer view
        ;; the first file's row (its id `f:…'), once the hub's rows are drawn: the run's end can come before them
        (goto-char (or (drgnx-look-scene--until 10 "file row" #'drgnx-look-scene--file-row) (point-min)))
        (drgnx-replace-preview-file))
      (drgnx-look-scene--until 10 "preview"
                               (lambda () (cl-some (lambda (b) (and (eq (buffer-local-value 'major-mode b)
                                                                        'drgnx-replace-preview-mode)
                                                                    (cdr (buffer-local-value 'drgnx-replace--preview b))))
                                                   (buffer-list)))))
    (drgnx-look-scene--answer)))

(defun drgnx-look-scene-search-sheet ()
  "The Replace All sheet over the editor (search-view.html's sheet, dark)."
  (when-let* ((view (drgnx-look-scene--search)))
    (drgnx-look-scene--try "sheet"
      (with-current-buffer view (drgnx-replace-all))
      (drgnx-look-scene--until 10 "sheet" (lambda () (when-let* ((b (get-buffer drgnx-replace-sheet-buffer-name)))
                                                       (plist-get (buffer-local-value 'drgnx-replace--sheet b) :hunk)))))
    (drgnx-look-scene--answer)))

(declare-function drgnx-search-to-agent "drgnx-search-handoff")
(declare-function drgnx-settings-runtime-send "drgnx-settings-runtime")
(defvar drgnx-agents-profiles)
(defvar drgnx-search-handoff-buffer-name)
(defvar drgnx-search-handoff--ask)

(defun drgnx-look-scene-search-kinds ()
  "Symbol mode with its kind chips (search-view.html's \"Symbol with kind chips\"): `drgnx-gateway--queue' in the
project, the fn chip on."
  (when-let* ((view (drgnx-look-scene--search)))
    (drgnx-look-scene--try "symbol"
      (with-current-buffer view
        (drgnx-replace--open :text "drgnx-gateway--queue" :mode 'symbol)
        (when (drgnx-look-scene--until 30 "kinds" (lambda () drgnx-replace--kind-counts))
          (unless (memq 'fn drgnx-replace--kinds-on) (drgnx-replace-kind-toggle 'fn))
          (drgnx-look-scene--until 15 "symbol rows"
                                   (lambda () (and drgnx-replace--hub-counts
                                                   (not (save-excursion (goto-char (point-min))
                                                                        (search-forward "--pending" nil t)))))))))
    (drgnx-look-scene--answer)))

(defun drgnx-look-scene-search-handed ()
  "The Search view with four matches handed to an agent (search-view.html's results, `Ada 9/14'): a pair of a
mock profile (the scenes' ratatoskr-mock, written into the settings before the hub starts) in the project; its rows'
colour bar and the file's chip."
  (drgnx-look-scene--try "profile"
    (let ((profile `(("mock-claude" :provider claude
                      :command (,(expand-file-name "ratatoskr-mock"
                                                   (file-name-directory (getenv "DRGNX_RATATOSKR_BIN")))
                                "acp" "--as" "claude")))))
      (if (drgnx-hub-running-p)
          ;; an earlier scene started the hub: the editor's value of the setting goes to it, as it does when the user sets it
          (progn (setq drgnx-agents-profiles profile) (drgnx-settings-runtime-send))
        (drgnx-settings-file-put (expand-file-name "settings.el" (drgnx-user-dir)) 'drgnx-settings nil
                                 'drgnx-agents-profiles profile))))
  (when-let* ((view (drgnx-look-scene--search)))
    (drgnx-look-scene--try "hand off"
      ;; the rows' ids are of the run that drew them: a search the view ran again since (the scenes before this one leave
      ;; the view's fields as they were set, and a run that finishes after the rows were read) has the hub answer "no
      ;; match" for them, so the ids are read again and asked again until a run answers for them
      (let (answered pending)
        (drgnx-look-scene--until
         20 "hand-off ids of the current run"
         (lambda ()
           (or answered
               (progn
                 (unless pending
                   (let ((ids (with-current-buffer view (seq-take (drgnx-look-scene--row-ids "m:") 4))))
                     (when ids
                       (setq pending t)
                       (drgnx-hub--call-on
                        drgnx-hub--events "search/handoff"
                        (list :view drgnx-replace-view :instruction "Rename it." :ids (vconcat ids)
                              :to '(:pair (:profile "mock-claude"))
                              :mark '(:face "drgnx-agent-2" :glyph "◆" :name "Ada"))
                        (lambda (_ err)
                          (setq pending nil)
                          (cond ((null err) (setq answered t))
                                ((string-search "no match to hand off" (format "%s" err)))
                                (t (setq answered t)
                                   (push (format "hand off: %S" err) drgnx-look-scene--errors))))))))
                 nil)))))
      (drgnx-look-scene--until 20 "chip" (lambda () (with-current-buffer view
                                                      (text-property-not-all (point-min) (point-max)
                                                                             'drgnx-search-agent nil)))))
    (drgnx-look-scene--answer)))

(defun drgnx-look-scene-search-ask ()
  "Ask an Agent's card over the editor (search-view.html's \"Ask an Agent (light, modal)\"), its context read."
  (when-let* ((view (drgnx-look-scene--search)))
    (drgnx-look-scene--theme 'drgnx-light)
    (drgnx-look-scene--try "ask"
      (with-current-buffer view (drgnx-search-to-agent))
      (drgnx-look-scene--until 10 "context"
                               (lambda () (when-let* ((b (get-buffer drgnx-search-handoff-buffer-name)))
                                            (plist-get (buffer-local-value 'drgnx-search-handoff--ask b) :context)))))
    (drgnx-look-scene--answer)))

;; The debugging mockup's file (the-look/debugging.html): its lines 13-33, after twelve lines of header.
(defconst drgnx-look-scene--inventory
  (concat "\"\"\"Stock levels and the weekly order.\"\"\"\n\nimport logging\nfrom dataclasses import dataclass\n\n"
          "log = logging.getLogger(__name__)\nPACK_SIZE = 6\n\n\n@dataclass\nclass Item:\n    sku: str; qty: int; min: int\n\n"
          "def reorder_quantities(items: list[Item], threshold: int) -> dict[str, int]:\n"
          "    \"\"\"Packs to order so that no item falls under its minimum.\"\"\"\n"
          "    order: dict[str, int] = {}\n    for i, item in enumerate(items):\n        if item.qty >= item.min:\n"
          "            continue\n        shortfall = item.min - item.qty\n        # large gaps are worth a warning in the log\n"
          "        if shortfall > threshold:\n            log.warning(\"large shortfall: %s\", item.sku)\n"
          "        packs = -(-shortfall // PACK_SIZE)\n        order[item.sku] = packs * PACK_SIZE\n    return order\n\n\n"
          "def plan_week(stock: Stock) -> Plan:\n    items = [i for i in stock.items if i.active]\n"
          "    order = reorder_quantities(items, threshold=10)\n"
          "    cost = sum(prices[s] * n for s, n in order.items())\n    return Plan(order=order, cost=cost)\n"))

(declare-function drgnx-debug-gutter-mode "drgnx-debug-gutter")
(declare-function drgnx-debug-gutter--apply "drgnx-debug-gutter")
(declare-function drgnx-debug-gutter--columns "drgnx-debug-gutter")
(declare-function drgnx-margins-offset "drgnx-margins")
(declare-function drgnx-modules--ok-p "drgnx-modules")
(declare-function drgnx-hub-call-sync "drgnx-hub-client")
(declare-function drgnx-modules--run-one "drgnx-modules")
(defvar drgnx-modules--table)
(defvar drgnx-debug--sessions)
(declare-function drgnx-debug-view "drgnx-debug-view")
(declare-function drgnx-debug-view--buffer "drgnx-debug-view")
(defvar drgnx-debug-view--config)
(declare-function drgnx-debug-view--toggle "drgnx-debug-view")
(declare-function drgnx-debug-console-show "drgnx-debug-console")
(declare-function drgnx-debug-open-disassembly "drgnx-debug-disassembly")
(declare-function drgnx-debug-send-run "drgnx-debug-share" (run path))
(declare-function drgnx-debug-share--close "drgnx-debug-share" ())
(declare-function drgnx-debug-share--render "drgnx-debug-share" ())
(defvar drgnx-debug-share-buffer)
(defvar drgnx-debug-share--card)
(declare-function drgnx-debug-memory-open "drgnx-debug-memory")
(declare-function drgnx-debug-heap-mode "drgnx-debug-heap" ())
(declare-function drgnx-debug-heap--show "drgnx-debug-heap" (answer))
(declare-function drgnx-debug-heap--decorate "drgnx-debug-heap" (&optional faded))
(declare-function drgnx-debug-heap--faded "drgnx-debug-heap" ())
(declare-function drgnx-wb-area-show "drgnx-area" (area &optional tab buffer))
(defvar drgnx-debug-heap-buffer-name)
(defvar drgnx-debug-heap--title)
(defvar drgnx-debug-heap--pick)
(declare-function drgnx-debug-heap-frame "drgnx-debug-heap" (data))
(declare-function drgnx-quickhelp--request "drgnx-quickhelp")
(declare-function drgnx-quickhelp-shown-p "drgnx-quickhelp")
(defvar drgnx-debug-console-timestamps)
(defvar drgnx-debug-gutter--candidates)
(defvar drgnx-debug-disassembly-buffer-name)
(defvar drgnx-debug-disassembly--bps)
(declare-function drgnx-debug-disassembly--line-of "drgnx-debug-disassembly" (address))
(declare-function drgnx-debug-disassembly-toggle-breakpoint "drgnx-debug-disassembly" ())

(defun drgnx-look-scene--debug-script (&optional extras)
  "The mock adapter's script for the debugging mockup's stop: the program's output, a stop on line 24 in
reorder_quantities, its frames, Locals with `item' open, and the three watches.  EXTRAS: the extras mockup's too
(the adapter places breakpoints, reads memory and disassembles; the output has groups; `item' has memory, the
top frame an instruction, `shortfall' a hover value)."
  (let* ((inv (expand-file-name "inventory.py" drgnx-look-scene--project))
         (app (expand-file-name "app.py" drgnx-look-scene--project))
         (var (lambda (name value &optional ref type)
                (append (list :name name :value value :variablesReference (or ref 0)) (and type (list :type type))
                        (and extras (equal name "item") (list :memoryReference "0x7ffd4c20")))))
         (out (lambda (category text &optional line group)
                (list :event "output" :body (append (list :category category :output text)
                                                    (and line (list :source (list :path inv) :line line))
                                                    (and group (list :group group))))))
         (ins (lambda (address bytes text &optional line)
                (append (list :address address :instructionBytes bytes :instruction text)
                        (and line (list :location (list :path inv) :line line))))))
    (vconcat
     (list
      (list :expect "initialize" :ok (append (list :supportsConfigurationDoneRequest t :supportsRestartRequest t
                                                   :supportsCompletionsRequest t
                                                   ;; Breakpoints' first two rows (debugging.html)
                                                   :exceptionBreakpointFilters
                                                   (vector (list :filter "raised" :label "Raised Exceptions")
                                                           (list :filter "uncaught" :label "Uncaught Exceptions"
                                                                 :default t)))
                                             (and extras (list :supportsBreakpointLocationsRequest t
                                                               :supportsReadMemoryRequest t
                                                               :supportsDisassembleRequest t
                                                               :supportsInstructionBreakpoints t
                                                               :supportsSteppingGranularity t))))
      (list :expect "launch")
      (list :event "initialized")
      (list :expect "setBreakpoints"
            :ok (list :breakpoints (vector (list :id 1 :verified t :line 18) (list :id 2 :verified t :line 22)
                                           (list :id 3 :verified t :line 24) (list :id 4 :verified t :line 25))))
      (list :expect "setExceptionBreakpoints")
      (list :expect "configurationDone")
      (funcall out "console" "Launching app.py with debugpy 1.8 · cwd ~/src/stockroom\n"))
     (if (not extras)
         (list (funcall out "console" "order bolt-m4\n" 25)
               (funcall out "stderr" "WARNING:stock:large shortfall: washer-8\n")
               (funcall out "console" "order washer-8\n" 25))
       ;; the extras' console: a group, a repeated line, a folded group, a located line, a warning
       (list (funcall out "stdout" "order nut-m6\n" nil "start")
             (funcall out "stdout" "units=2 min=10\n")
             (funcall out "stdout" "units=2 min=10\n")
             (funcall out "stdout" "units=2 min=10\n")
             (funcall out "stdout" "reservations (4)\n" nil "startCollapsed")
             (funcall out "stdout" "bolt-m4 x6\n")
             (funcall out "stdout" "" nil "end")
             (funcall out "console" "shortfall = 8\n" 20)
             (funcall out "stdout" "" nil "end")
             (funcall out "stderr" "WARNING:stock:large shortfall: nut-m6\n")))
     (list
      (list :event "stopped" :body (list :reason "breakpoint" :threadId 1 :allThreadsStopped t))
      (list :any
            (vconcat
             (and extras
                  (append
                   (list (list :expect "breakpointLocations" :args (list :line 24)
                               :ok (list :breakpoints (vector (list :line 24 :column 9) (list :line 24 :column 20))))
                         (list :expect "breakpointLocations" :args (list :line 25)
                               :ok (list :breakpoints (vector (list :line 25 :column 9) (list :line 25 :column 33))))
                         (list :expect "breakpointLocations" :args (list :line 18) :ok (list :breakpoints []))
                         (list :expect "breakpointLocations" :args (list :line 22) :ok (list :breakpoints []))
                         (list :expect "setInstructionBreakpoints"
                               :ok (list :breakpoints (vector (list :verified t)))))
                   ;; asked again by the light scenes: each answer is taken once
                   (apply #'append
                          (make-list
                           2 (list
                              (list :expect "evaluate" :args (list :expression "shortfall" :context "hover")
                                    :ok (list :result "8" :type "int"))
                              (list :expect "readMemory" :args (list :memoryReference "0x7ffd4c20")
                                    :ok (list :address "0x7ffd4c20" :unreadableBytes 8
                                              :data (base64-encode-string
                                                     (apply #'unibyte-string
                                                            (append (string-to-list "nut-m6")
                                                                    '(0 0 2 0 0 0 10 0 0 0 5 0 0 0 0 0 0 0
                                                                        #xe8 #x4c #xfd #x7f 0 0 0 0 0 0 0 0 0 0 0 0))))))
                              (list :expect "disassemble" :args (list :memoryReference "0x40113f")
                                    :ok (list :instructions
                                              (vector (funcall ins "0x401136" "48 8b 7d f8" "mov rdi, [rbp-0x8]" 24)
                                                      (funcall ins "0x40113a" "e8 c1 ff ff ff" "call pack_size")
                                                      (funcall ins "0x40113f" "89 45 f4" "mov [rbp-0xc], eax")
                                                      (funcall ins "0x401142" "8b 45 f0" "mov eax, [rbp-0x10]" 25)
                                                      (funcall ins "0x401145" "0f af 45 f4" "imul eax, [rbp-0xc]")
                                                      (funcall ins "0x401149" "89 45 ec" "mov [rbp-0x14], eax")))))))))
             (list
              (list :expect "threads" :ok (list :threads (vector (list :id 1 :name "MainThread"))))
              (list :expect "stackTrace"
                    :ok (list :totalFrames 4
                              :stackFrames (vector (append (list :id 1000 :name "reorder_quantities" :line 24 :column 9
                                                                 :source (list :path inv))
                                                           (and extras (list :instructionPointerReference "0x40113f")))
                                                   (list :id 1001 :name "plan_week" :line 31 :column 13
                                                         :source (list :path inv))
                                                   (list :id 1002 :name "main" :line 12 :column 5 :source (list :path app))
                                                   (list :id 1003 :name "<module>" :line 30 :column 1
                                                         :source (list :path app)))))
              (list :expect "scopes" :ok (list :scopes (vector (list :name "Locals" :variablesReference 1)
                                                               (list :name "Globals" :variablesReference 2 :expensive t))))
              (list :expect "variables" :args (list :variablesReference 1)
                    :ok (list :variables (vector (funcall var "items" "[Item(…), …]" 3 "list[Item]")
                                                 (funcall var "threshold" "10" 0 "int")
                                                 (funcall var "order" "{'bolt-m4': 6, 'washer-8': 12}" 4 "dict")
                                                 (funcall var "i" "3" 0 "int")
                                                 (funcall var "item" "Item(sku='nut-m6', qty=2, min=10)" 5 "Item")
                                                 (funcall var "shortfall" "8" 0 "int"))))
              (list :expect "variables" :args (list :variablesReference 5)
                    :ok (list :variables (vector (funcall var "sku" "'nut-m6'" 0 "str") (funcall var "qty" "2" 0 "int")
                                                 (funcall var "min" "10" 0 "int"))))
              (list :expect "evaluate" :args (list :expression "order.get(item.sku, 0)") :ok (list :result "0"))
              (list :expect "evaluate" :args (list :expression "len(items) - i") :ok (list :result "9"))
              (list :expect "evaluate" :args (list :expression "total_cost")
                    :fail "name 'total_cost' is not defined"))))))))

(defun drgnx-look-scene--debug-stopped ()
  "The stopped debug session, or nil."
  (seq-find (lambda (s) (equal (plist-get s :state) "stopped")) drgnx-debug--sessions))

(defvar drgnx-look-scene--debug-extras 'none
  "Which script the scenes' stopped session runs: nil (the debugging mockup's) or t (the extras'); `none' before one.")

(defun drgnx-look-scene--debug-start (extras)
  "A session of the mock adapter stopped on line 24, with the extras' script when EXTRAS: the one there is when it
runs that script, else a new one (an old one ended first).  The breakpoints and watches go into the store once."
  (let* ((bin (getenv "DRGNX_RATATOSKR_BIN"))
         (root (directory-file-name (expand-file-name drgnx-look-scene--project))) ; as the editor names it
         (inv (expand-file-name "inventory.py" root))
         (bp (lambda (op) (drgnx-hub-call-sync "debug/breakpoints" (list :root root :op op) 5))))
    (unless (and (drgnx-look-scene--debug-stopped) (eq drgnx-look-scene--debug-extras extras))
      (when drgnx-debug--sessions
        (dolist (s drgnx-debug--sessions)
          (drgnx-hub-call-sync "debug/control" (list :session (plist-get s :id) :op "stop") 5))
        (drgnx-look-scene--until 15 "the last session's end" (lambda () (null drgnx-debug--sessions))))
      (when (eq drgnx-look-scene--debug-extras 'none)
        (make-directory (expand-file-name ".vscode" root) t)
        (with-temp-file (expand-file-name ".vscode/launch.json" root)
          (insert (json-serialize (list :version "0.2.0"
                                        :configurations (vector (list :type "mock" :request "launch"
                                                                      :name "Python: plan the week" :program "app.py"))))))
        (with-temp-file (expand-file-name "app.py" root) (insert "from inventory import plan_week\n"))
        (funcall bp (list :op "add" :path inv :line 18))
        (funcall bp (list :op "add" :path inv :line 22 :condition "shortfall > 20"))
        (funcall bp (list :op "add" :path inv :line 24))
        (funcall bp (list :op "add" :path inv :line 25 :log "order {item.sku}"))
        (let ((v (funcall bp (list :op "add" :path inv :line 30))))
          (when-let* ((b (seq-find (lambda (b) (eql (plist-get b :line) 30)) (plist-get v :breakpoints))))
            (funcall bp (list :op "edit" :id (plist-get b :id) :enabled :false))))
        (dolist (e '("order.get(item.sku, 0)" "len(items) - i" "total_cost"))
          (drgnx-hub-call-sync "debug/watch" (list :root root :op "add" :expr e) 5))
        (drgnx-hub-call-sync "debug/trust" (list :root root :trusted t) 5))
      (setq drgnx-look-scene--debug-extras extras)
      (let ((script (make-temp-file "drgnx-debug-scene" nil ".json")))
        (let ((coding-system-for-write 'utf-8))
          (with-temp-file script
            (insert (decode-coding-string (json-serialize (drgnx-look-scene--debug-script extras)) 'utf-8))))
        ;; visited before the start: the stop's frame and inline values mark a buffer that visits the file
        (find-file-noselect inv)
        ;; the view's picker shows what Start runs, as when the user picked it (debugging.html `.cfg')
        (with-current-buffer (drgnx-debug-view--buffer)
          (setq drgnx-debug-view--config (cons "launch:0" "Python: plan the week")))
        (drgnx-hub-call-sync
         "debug/start"
         (list :root root :config "launch:0"
               :adapters (vector (list :id "mock" :name "Mock" :types ["mock"] :find (list :path bin)
                                       :start (list :stdio (vector "{program}" "debug-mock" script)))))
         10))
      (drgnx-look-scene--until 15 "the stop" #'drgnx-look-scene--debug-stopped))))

(defun drgnx-look-scene--debug-session (&optional extras)
  "The mockup's stopped session, through the scenes' hub and its mock adapter (`debug-mock', a test-hooks build):
the breakpoints in the store, three watches, launch.json's configuration started and stopped on line 24; the Run
and Debug view in the sidebar and the Debug Console in the panel.  EXTRAS: the extras mockup's script.  Nil when
there is no hub to run it."
  (when-let* ((bin (getenv "DRGNX_RATATOSKR_BIN")) ((file-executable-p bin)))
    ;; the stop's inline values are the hub's, read with the Python pack's grammar: a hub with none shows no value at all
    (unless (getenv "DRGNX_PACK_LOCK")
      (error "No pack grammars for the hub: DRGNX_PACK_LOCK and DRGNX_PACK_GRAMMARS (test/packs/hub-grammars.sh)"))
    (drgnx-look-scene--hub)
    (unless (drgnx-modules--ok-p 'extra/debug)
      (drgnx-modules--run-one 'extra/debug (alist-get 'extra/debug drgnx-modules--table) 'idle))
    (progn
      (drgnx-look-scene--debug-start extras)
      (drgnx-debug-view)
      (drgnx-debug-console-show)
      (drgnx-wb-focus-editor)
      (drgnx-look-scene--goto "inventory.py" 24 8 13)
      ;; Locals' `item' open, as the mockup has it
      (with-current-buffer (drgnx-debug-view--buffer)
        (drgnx-debug-view--toggle (format "v:%s:Locals/item" (plist-get (drgnx-look-scene--debug-stopped) :id)) t))
      (drgnx-look-scene--until 5 "inline values"
                               (lambda ()
                                 (seq-some (lambda (o) (string-search "shortfall" (or (overlay-get o 'after-string) "")))
                                           (overlays-in (point-min) (point-max)))))
      (drgnx-look-scene--until 5 "the Run and Debug rows"
                               (lambda ()
                                 (with-current-buffer (drgnx-debug-view--buffer)
                                   (save-excursion (goto-char (point-min)) (search-forward "sku" nil t)))))
      t)))

(defun drgnx-look-scene-debugging ()
  "The debugging mockup's window: inventory.py from line 13, a session of the mock adapter stopped on line 24 with
the mockup's breakpoints (18 verified, 22 a condition, 24 verified, 25 a logpoint, 30 disabled), watches, Run and
Debug and the Debug Console.  Without a hub only the column is shown: the store's answer as the hub would give it.
The pointer is noted on line 32's hover dot, as the mockup shows it, where Nidhogg lights a margin's mouse face."
  (drgnx-look-scene--theme 'drgnx-dark)
  (drgnx-look-scene--try "debugging"
    (drgnx-wb-focus-editor)
    (let ((f (expand-file-name "inventory.py" drgnx-look-scene--project)))
      (unless (file-exists-p f) (with-temp-file f (insert drgnx-look-scene--inventory)))
      (dolist (m '("drgnx-debug-launch" "drgnx-debug-gutter"))
        (load (expand-file-name (concat "modules/extra/" m) (bound-and-true-p drgnx-dir)) nil t))
      (unless (drgnx-look-scene--debug-session)
        (drgnx-look-scene--goto "inventory.py" 24 8 13)
        ;; the store's answer, as the hub would give it (the scene has no hub)
        (cl-letf (((symbol-function 'drgnx-hub-call) #'ignore))
          (drgnx-debug-gutter-mode 1))
        (drgnx-debug-gutter--apply
         (list :version 1 :breakpoints
               (list (list :id 1 :line 18 :enabled t :verified t)
                     (list :id 2 :line 22 :enabled t :verified t :condition "shortfall > 20")
                     (list :id 3 :line 24 :enabled t :verified t)
                     (list :id 4 :line 25 :enabled t :verified t :log "order {item.sku}")
                     (list :id 5 :line 30 :enabled nil :verified t)))))
      (when (and (featurep 'glitnir-margin-mouse-face) (fboundp 'nidhogg--note-mouse))
        (redisplay t)
        ;; line 32's dot: the column's middle character, after the claim's pad, left of the fringe
        (save-excursion
          (goto-char (point-min)) (forward-line 31)
          (pcase-let* ((`(,_ . ,y) (posn-x-y (posn-at-point (point))))
                       (`(,left ,top . ,_) (window-inside-pixel-edges))
                       (cw (frame-char-width))
                       (l (- left (if (nth 2 (window-fringes)) 0 (car (window-fringes))) (* (car (window-margins)) cw))))
            (nidhogg--note-mouse nil (+ l (* cw (+ (drgnx-margins-offset 'debug) (/ (1- (drgnx-debug-gutter--columns)) 2)))
                                        (/ cw 2))
                                 (+ top y (/ (line-pixel-height) 2))))))))
  (drgnx-look-scene--answer))

(defun drgnx-look-scene--debug-extras (theme views)
  "The debugging extras mockup in THEME, a session of the mock adapter's extras script stopped on line 24.  Without
VIEWS: inventory.py with line 24's candidates, the data tip of `shortfall' and the overview ruler, the Debug Console
with groups and timestamps.  VIEWS: the Disassembly in the editor and the memory of `item'."
  (drgnx-look-scene--theme theme)
  (drgnx-look-scene--try (if views "debug-extras-views" "debug-extras")
    (drgnx-wb-focus-editor)
    (let ((f (expand-file-name "inventory.py" drgnx-look-scene--project)))
      (unless (file-exists-p f) (with-temp-file f (insert drgnx-look-scene--inventory))))
    (dolist (m '("drgnx-debug-launch" "drgnx-debug-gutter"))
      (load (expand-file-name (concat "modules/extra/" m) (bound-and-true-p drgnx-dir)) nil t))
    (setq drgnx-debug-console-timestamps t)
    (when (drgnx-look-scene--debug-session t)
      (let ((session (plist-get (drgnx-look-scene--debug-stopped) :id)))
        (if (not views)
            (progn
              (drgnx-look-scene--goto "inventory.py" 24 8 13)
              (drgnx-look-scene--until 5 "line 24's candidates" (lambda () drgnx-debug-gutter--candidates))
              (goto-char (point-min)) (forward-line 23) (search-forward "shortfall") (backward-char 3)
              (drgnx-quickhelp--request (selected-window) (point) nil)
              (drgnx-look-scene--until 5 "the data tip" #'drgnx-quickhelp-shown-p))
          (drgnx-wb-focus-editor)
          (drgnx-debug-open-disassembly)
          (drgnx-look-scene--until 5 "the instructions"
                                   (lambda () (with-current-buffer drgnx-debug-disassembly-buffer-name
                                                (string-search "pack_size" (buffer-string)))))
          ;; the mockup's instruction breakpoint on the call (the session keeps it for the light scene)
          (with-current-buffer drgnx-debug-disassembly-buffer-name
            (unless drgnx-debug-disassembly--bps
              (goto-char (drgnx-debug-disassembly--line-of #x40113a))
              (drgnx-debug-disassembly-toggle-breakpoint)
              (drgnx-look-scene--until 5 "the instruction breakpoint"
                                       (lambda () drgnx-debug-disassembly--bps))))
          ;; the editor split: the Disassembly above, the memory below (the mockup shows both)
          (unless (get-buffer-window "*Memory: item*")
            (let* ((top (selected-window)) (below (split-window top nil 'below)))
              (drgnx-debug-memory-open session "0x7ffd4c20" "item")
              (set-window-buffer top (get-buffer drgnx-debug-disassembly-buffer-name))
              (set-window-buffer below (get-buffer "*Memory: item*"))
              (select-window top)))
          (drgnx-look-scene--until 5 "the memory"
                                   (lambda () (with-current-buffer "*Memory: item*"
                                                (string-search "nut-m6" (buffer-string)))))))))
  (drgnx-look-scene--answer))

(defconst drgnx-look-scene--send-run
  '(:id "r-scene" :n 4 :name "Python: plan the week" :stops 3 :ended 1763038320.0 :probes [(:id "p1") (:id "p2")])
  "The run the Send Run scenes offer: a record as `debug/runs/list' gives it.")

(defun drgnx-look-scene--send-run (theme written)
  "The Send Run card in THEME over inventory.py: the card before anything is written, or (WRITTEN) the code card, its
code and size the scene's own (the container has no keyring, so no run is recorded to export)."
  (drgnx-look-scene--theme theme)
  (drgnx-look-scene--try (if written "send-run-code" "send-run")
    (when-let* ((b (get-buffer drgnx-debug-share-buffer)))
      (with-current-buffer b (drgnx-debug-share--close)))
    (drgnx-wb-focus-editor)
    (let ((f (expand-file-name "inventory.py" drgnx-look-scene--project)))
      (unless (file-exists-p f) (with-temp-file f (insert drgnx-look-scene--inventory)))
      (find-file f))
    (drgnx-debug-send-run drgnx-look-scene--send-run "~/plan-the-week-run4.drgnx-run")
    (when written
      (with-current-buffer drgnx-debug-share-buffer
        (setq drgnx-debug-share--card
              (plist-put (plist-put (plist-put drgnx-debug-share--card :state 'written)
                                    :code "K7QF-M2XD-9RTA-PL4W-ZB6N-C3HV-Y8EG-UJ5S-QW2M-R7DK-X4PA-N6TB-FHC2")
                         :bytes 188416))
        (drgnx-debug-share--render)))
    (redisplay t))
  (drgnx-look-scene--answer))

(defun drgnx-look-scene-send-run () "Send Run's card, dark." (drgnx-look-scene--send-run 'drgnx-dark nil))
(defun drgnx-look-scene-send-run-code () "Send Run's code card, dark." (drgnx-look-scene--send-run 'drgnx-dark t))
(defun drgnx-look-scene-send-run-light () "Send Run's card, light." (drgnx-look-scene--send-run 'drgnx-light nil))
(defun drgnx-look-scene-send-run-code-light () "Send Run's code card, light." (drgnx-look-scene--send-run 'drgnx-light t))

(defun drgnx-look-scene-debug-extras () "The debugging extras' editor, dark." (drgnx-look-scene--debug-extras 'drgnx-dark nil))
(defun drgnx-look-scene-debug-extras-light () "The debugging extras' editor, light." (drgnx-look-scene--debug-extras 'drgnx-light nil))
(defun drgnx-look-scene-debug-extras-views () "The debugging extras' views, dark." (drgnx-look-scene--debug-extras 'drgnx-dark t))
(defun drgnx-look-scene-debug-extras-views-light () "The debugging extras' views, light." (drgnx-look-scene--debug-extras 'drgnx-light t))

(defun drgnx-look-scene--heap-node (id path &rest fields)
  "A heap node as `debug/heap' sends it: ID of type Node at PATH with FIELDS, each (NAME VALUE TO? CUT?)."
  (list :id id :type "Node" :path path
        :fields (vconcat (mapcar (lambda (f) (append (list :name (nth 0 f) :value (nth 1 f)) (and (nth 2 f) (list :to (nth 2 f)))
                                                     (and (nth 3 f) (list :cut (nth 3 f)))))
                                 fields))))

(defun drgnx-look-scene--heap-answer (second)
  "The graph of the stopped frame's locals at the mockup's first stop, or (SECOND) its next: the frame first (a,
shared = b, threshold), then a → b → d, then the ring a → b → c → a with b's qty changed, c new and d gone, and b's
40 tags cut by the limit (a stub at the end of a dashed edge); the cells laid out by the hub's rules (layers left to
right, forward edges through the gap before the target, back edges in a lane above the cards)."
  (let ((frame (list :id "frame" :type "frame" :path "Locals"
                     :fields (vector (list :name "a" :value "<Node>" :to "a") (list :name "shared" :value "<Node>" :to "b")
                                     (list :name "threshold" :value "10"))))
        (a (drgnx-look-scene--heap-node "a" "a" '("sku" "'nut-m6'") '("qty" "20") '("next" "<Node>" "b")))
        (b (drgnx-look-scene--heap-node "b" "b" '("sku" "'bolt-m4'") (list "qty" (if second "3" "5"))
                                        (list "next" "<Node>" (if second "c" "d")) '("tags" "list · 40" nil 40)))
        (c (drgnx-look-scene--heap-node "c" "c" '("sku" "'washer-8'") '("qty" "0") '("next" "<Node>" "a")))
        (d (drgnx-look-scene--heap-node "d" "d" '("sku" "'pin-2'") '("qty" "0") '("next" "None"))))
    (list :graph "scene-heap" :session "scene" :expr "" :locals t :node "frame" :cut 40
          :nodes (vconcat (list frame a b (if second c d)))
          :cards (vconcat (list (list :id "frame" :col 3 :row 2 :width 18 :height 4)
                                (list :id "a" :col 27 :row 2 :width 18 :height 4)
                                (list :id "b" :col 51 :row 2 :width 18 :height 5))
                          (list (if second (list :id "c" :col 75 :row 2 :width 18 :height 4)
                                  (list :id "d" :col 27 :row 9 :width 18 :height 4))))
          :cuts (vector (list :from "b" :field 3 :count 40 :col 75 :row 8 :width 15))
          :edges (vconcat (list (list :from "frame" :field 0 :to "a" :points [[21 3] [24 3] [24 2] [27 2]])
                                (list :from "frame" :field 1 :to "b" :points [[21 4] [23 4] [23 7] [48 7] [48 2] [51 2]])
                                (list :from "a" :field 2 :to "b" :points [[45 5] [48 5] [48 2] [51 2]])
                                (list :from "b" :field 3 :to "" :cut t :points [[69 6] [72 6] [72 8] [75 8]]))
                          (if second
                              (list (list :from "b" :field 2 :to "c" :points [[69 5] [72 5] [72 2] [75 2]])
                                    (list :from "c" :field 2 :to "a" :points [[93 5] [96 5] [96 0] [36 0] [36 2]]))
                            (list (list :from "b" :field 2 :to "d" :points [[69 5] [70 5] [70 8] [25 8] [25 9] [27 9]]))))
          :width 99 :height 13
          :added (if second ["c"] []) :changed (if second ["b"] []) :gone (if second ["d"] []))))

(defun drgnx-look-scene--heap-graph (theme)
  "The heap graph in THEME: the Graph tab after the second stop, the frame's locals shown from `a' (the
debugging-extras mockup's)."
  (drgnx-look-scene--theme theme)
  (drgnx-look-scene--try (if (eq theme 'drgnx-light) "heap-graph-light" "heap-graph")
    ;; the Graph tab is extra/debug's: set it up when the session has not (its tab in the panel's strip)
    (unless (drgnx-modules--ok-p 'extra/debug)
      (drgnx-modules--run-one 'extra/debug (alist-get 'extra/debug drgnx-modules--table) 'idle))
    ;; the Send Run scenes before this one leave their card where the editor was: closed first, as they close each other's
    (when-let* ((b (get-buffer drgnx-debug-share-buffer)))
      (with-current-buffer b (drgnx-debug-share--close)))
    (drgnx-look-scene--editor-layout)
    (drgnx-wb-focus-editor)
    (let ((f (expand-file-name "inventory.py" drgnx-look-scene--project)))
      (unless (file-exists-p f) (with-temp-file f (insert drgnx-look-scene--inventory)))
      (find-file f))
    (when-let* ((old (get-buffer drgnx-debug-heap-buffer-name))) (kill-buffer old))
    (drgnx-debug-heap-frame (list :session "scene" :name "reorder_quantities" :epoch 2))
    (let ((b (get-buffer-create drgnx-debug-heap-buffer-name)))
      (with-current-buffer b
        (drgnx-debug-heap-mode)
        (setq drgnx-debug-heap--title "a" drgnx-debug-heap--pick "a"))
      (let ((w (drgnx-wb-area-show 'panel 'debug-graph b)))
        (with-current-buffer b
          (drgnx-debug-heap--show (drgnx-look-scene--heap-answer nil))
          (drgnx-debug-heap--show (drgnx-look-scene--heap-answer t))
          (goto-char (point-min)))
        (when (window-live-p w)
          (ignore-errors (window-resize w (- 16 (window-total-height w)) nil t))
          (with-current-buffer b (drgnx-debug-heap--decorate (drgnx-debug-heap--faded)))))))
  (drgnx-look-scene--answer))

(defun drgnx-look-scene-heap-graph () "The heap graph, dark." (drgnx-look-scene--heap-graph 'drgnx-dark))
(defun drgnx-look-scene-heap-graph-light () "The heap graph, light." (drgnx-look-scene--heap-graph 'drgnx-light))

(defun drgnx-look-scene--start-page (theme)
  "The start page in the editor in THEME."
  (drgnx-look-scene--theme theme)
  (drgnx-look-scene--try "start page"
    (drgnx-wb-focus-editor)
    (drgnx-start-show))
  (drgnx-look-scene--shown "start page" drgnx-start-buffer-name)
  (drgnx-look-scene--answer))

(defun drgnx-look-scene-start-page ()
  "The start page in the editor, dark (no mockup: its buttons, keycaps and shield are the components of design §3.5)."
  (drgnx-look-scene--start-page 'drgnx-dark))

(defun drgnx-look-scene-start-page-light ()
  "The start page in the editor, light (the design system's empty-state shot)."
  (drgnx-look-scene--start-page 'drgnx-light))

;;;; The notebook (the-look/notebook.html: a markdown cell, a finished code cell, the selected cell running, a failed cell)

(declare-function drgnx-notebook-mode "drgnx-notebook")
(declare-function drgnx-notebook--install "drgnx-notebook" (result))
(declare-function drgnx-notebook--status "drgnx-notebook" (data))
(declare-function drgnx-notebook--cell-by-id "drgnx-notebook" (id))
(declare-function drgnx-notebook--select-at "drgnx-notebook" (pos))
(defvar drgnx-notebook--images)
(defvar drgnx-notebook--cells)

(defun drgnx-look-scene--gradient-image (width height)
  "An image spec of a WIDTH by HEIGHT diagonal gradient (a binary PPM, which Emacs draws without a decoder): the
notebook scene's picture output."
  (let ((rows nil))
    (dotimes (y height)
      (let ((row (make-string (* 3 width) 0)))
        (dotimes (x width)
          (let ((tt (/ (float (+ x y)) (+ width height))))
            (aset row (* 3 x) (round (+ 40 (* 60 tt))))
            (aset row (+ 1 (* 3 x)) (round (+ 80 (* 70 (- 1.0 tt)))))
            (aset row (+ 2 (* 3 x)) (round (+ 120 (* 90 tt))))))
        (push row rows)))
    (list 'image :type 'pbm :data (concat (format "P6\n%d %d\n255\n" width height) (apply #'concat (nreverse rows)))
          :ascent 'center :max-height (if (fboundp 'drgnx-px) (drgnx-px 160) 160))))

(defun drgnx-look--nb-parts (count language busy)
  "The parts of a code cell's head as the hub sends them: the run (BUSY: stop) button,
the COUNT chip (accent while BUSY), the LANGUAGE chip."
  (list (list :role "run" :text "" :action (if busy "stop" "run"))
        (list :role "count" :text count :chip (if busy "accent" "quiet"))
        (list :role "language" :text language :chip "quiet")))

(defun drgnx-look-scene--notebook-buffer ()
  "A notebook buffer, `cache-experiments.ipynb', with the mockup's four cells and their outputs put as the hub's tails
would be (no kernel, no hub: the scene draws the buffer's own chrome)."
  (load (expand-file-name "modules/lang/drgnx-notebook" (bound-and-true-p drgnx-dir)) nil t)
  (when-let* ((old (get-buffer "cache-experiments.ipynb")))   ; the dark scene's, when the light one follows
    (with-current-buffer old (set-buffer-modified-p nil))
    (kill-buffer old))
  (let ((buffer (generate-new-buffer "cache-experiments.ipynb")))
    (with-current-buffer buffer
      (drgnx-notebook-mode)
      (puthash (list "c2" 1 "image/png" 640 360) (drgnx-look-scene--gradient-image 640 360) drgnx-notebook--images)
      (drgnx-notebook--install
       (list :id "nbscene" :language "python" :kernelspec "python3"
             :cells (list (list :id "c0" :type "markdown" :source "# Cache experiments\nHow the hit rate moves with the capacity.")
                          (list :id "c1" :type "code"
                                :source "import numpy as np\nrng = np.random.default_rng(7)\nhits = rng.random(10_000)")
                          (list :id "c2" :type "code"
                                :source "for cap in (16, 64, 256):\n    print(cap, (hits < cap / 256).mean())")
                          (list :id "c3" :type "code" :source "plot(missing)"))
             :tails (list (list :cell "c1" :version 1 :stream "stream" :text "done: 10000 samples" :head (list :text "[1]  python" :state "idle" :parts (drgnx-look--nb-parts "[1]" "python" nil)))
                          (list :cell "c2" :version 1 :stream "stream" :head (list :text "[*]  python" :state "running" :parts (drgnx-look--nb-parts "[*]" "python" t)) :text (concat "16 0.0612\n64 0.2487\n" (string #xfffc))
                                :images (list (list :at 20 :output 1 :mime "image/png" :width 640 :height 360)))
                          (list :cell "c3" :version 1 :stream "error" :head (list :text "[3]  python" :state "idle" :parts (drgnx-look--nb-parts "[3]" "python" nil))
                                :text "NameError: name 'missing' is not defined\n  Cell In[3], line 1"
                                :runs (list (list :start 0 :end 9 :fg 1 :bold t))))))
      (drgnx-notebook--status (list :state "busy" :cell "c2" :queue 0))
      (goto-char (1+ (plist-get (drgnx-notebook--cell-by-id "c2") :head)))
      (drgnx-notebook--select-at (point)))
    buffer))

(defvar drgnx-look-scene--notebook-blocks nil
  "The Glitnir blocks of the notebook scene's window, as the facts write them (:notebook :blocks).")

(defun drgnx-look-scene--notebook (theme)
  "The notebook in THEME, in the editor, with the scenes' hub started so the sidebar has the
Explorer's rows, not \"Waiting for the hub\"."
  (drgnx-look-scene--theme theme)
  (drgnx-look-scene--try "hub" (drgnx-look-scene--hub))
  (drgnx-look-scene--try "notebook"
    (drgnx-wb-focus-editor)
    (drgnx-look-scene--show (drgnx-look-scene--notebook-buffer))
    ;; what the card's window holds, for a look that does not match the blocks: kind, rows, spans, colours (the facts'
    ;; :notebook :blocks); none at all is an error: the cells are drawn without their cards
    (with-current-buffer "cache-experiments.ipynb"
      (drgnx-notebook--blocks-update)
      (redisplay)
      (setq drgnx-look-scene--notebook-blocks
            (mapcar (lambda (b) (cons (car b) (cons (marker-position (nth 1 b)) (cons (marker-position (nth 2 b))
                                                                                      (cl-loop for (k v) on (nthcdr 3 b) by #'cddr
                                                                                               unless (eq k :overlay) append (list k v))))))
                    (window-parameter (get-buffer-window "cache-experiments.ipynb" t) 'glitnir-blocks)))
      (unless drgnx-look-scene--notebook-blocks
        (push "notebook: the notebook's window has no Glitnir blocks (no cards)" drgnx-look-scene--errors))))
  (drgnx-look-scene--shown "notebook" "cache-experiments.ipynb")
  (drgnx-look-scene--answer))

(defun drgnx-look-scene--kernel-python ()
  "The pinned kernel venv's python of the GUI test image: `DRGNX_NB_KERNEL_PYTHON', which the harness's Emacs does not
inherit, else the image's own path; nil without one."
  (seq-find #'file-executable-p (delq nil (list (getenv "DRGNX_NB_KERNEL_PYTHON") "/opt/nb-kernel/bin/python3"))))

(defun drgnx-look-scene--kernel-env (kernel)
  "A kernelspec for KERNEL (a python) in a folder `JUPYTER_PATH' names (the image has none), and a runtime folder short
enough for a kernel's sockets, in the session's environment.  The hub reads them when it starts, so the setup makes
them before any scene starts a hub (in a full run the agent scene's hub serves the notebook scenes)."
  (let ((dir (expand-file-name "jupyter/kernels/python3" temporary-file-directory)))
    (make-directory dir t)
    (with-temp-file (expand-file-name "kernel.json" dir)
      (insert (format "{\"argv\": [\"%s\", \"-m\", \"ipykernel_launcher\", \"-f\", \"{connection_file}\"], \"display_name\": \"Python 3 (ipykernel)\", \"language\": \"python\"}\n" kernel)))
    (setenv "JUPYTER_PATH" (expand-file-name "jupyter" temporary-file-directory))
    ;; a kernel's socket path must fit a unix socket's 108 bytes: the harness's runtime folder is too long
    (make-directory "/tmp/nbrt" t)
    (set-file-modes "/tmp/nbrt" #o700)
    (setenv "XDG_RUNTIME_DIR" "/tmp/nbrt")))

(defun drgnx-look-scene--notebook-file (&optional kernel)
  "A `.ipynb' the scene writes: the mockup's four cells.  With KERNEL (a python): three code cells to run, no outputs,
and a kernelspec for it in a folder `JUPYTER_PATH' names (the image has none); else the cells a finished run left."
  (let ((file (expand-file-name "cache-experiments.ipynb" temporary-file-directory)))
    (when kernel (drgnx-look-scene--kernel-env kernel))
    (with-temp-file file
      (insert "{\"cells\": [\n"
              "{\"cell_type\": \"markdown\", \"id\": \"c0\", \"metadata\": {}, \"source\": [\"# Cache experiments\\n\", \"How the hit rate moves with the capacity.\"]},\n"
              (if kernel
                  (concat
                   "{\"cell_type\": \"code\", \"id\": \"c1\", \"metadata\": {}, \"execution_count\": null, \"outputs\": [], \"source\": [\"hits = [i % 7 for i in range(10_000)]\\n\", \"print('done:', len(hits), 'samples')\"]},\n"
                   "{\"cell_type\": \"code\", \"id\": \"c2\", \"metadata\": {}, \"execution_count\": null, \"outputs\": [], \"source\": [\"import time\\n\", \"for cap in (16, 64, 256):\\n\", \"    print(cap, sum(h < 3 for h in hits) / cap, flush=True)\\n\", \"    time.sleep(60)\"]},\n"
                   "{\"cell_type\": \"code\", \"id\": \"c3\", \"metadata\": {}, \"execution_count\": null, \"outputs\": [], \"source\": [\"plot(missing)\"]},\n"
                   "{\"cell_type\": \"code\", \"id\": \"c4\", \"metadata\": {}, \"execution_count\": null, \"outputs\": [], \"source\": [\"for i in range(2500):\\n\", \"    print(f'epoch {i + 1}  loss {1 / (i + 1):.4f}')\"]}\n")
                (concat
                 "{\"cell_type\": \"code\", \"id\": \"c1\", \"metadata\": {}, \"execution_count\": 1, \"outputs\": [{\"output_type\": \"stream\", \"name\": \"stdout\", \"text\": [\"done: 10000 samples\"]}], \"source\": [\"import numpy as np\\n\", \"rng = np.random.default_rng(7)\"]},\n"
                 "{\"cell_type\": \"code\", \"id\": \"c2\", \"metadata\": {}, \"execution_count\": null, \"outputs\": [], \"source\": [\"for cap in (16, 64, 256):\\n\", \"    print(cap)\"]},\n"
                 "{\"cell_type\": \"code\", \"id\": \"c3\", \"metadata\": {}, \"execution_count\": 3, \"outputs\": [{\"output_type\": \"error\", \"ename\": \"NameError\", \"evalue\": \"name 'missing' is not defined\", \"traceback\": []}], \"source\": [\"plot(missing)\"]}\n"))
              "], \"metadata\": {\"kernelspec\": {\"display_name\": \"Python 3 (ipykernel)\", \"language\": \"python\", \"name\": \"python3\"}}, \"nbformat\": 4, \"nbformat_minor\": 5}\n"))
    file))

(defun drgnx-look-scene--run-cell (buffer id done secs)
  "Run cell ID of notebook BUFFER and wait up to SECS until DONE (a function of the cell's last tails) holds.  A scene
command must answer the harness within 20 s, so the waits are short and a miss is an error, not a hang."
  (with-current-buffer buffer
    (goto-char (1+ (plist-get (drgnx-notebook--cell-by-id id) :head)))
    (drgnx-notebook-run-cell))
  (drgnx-look-scene--until secs (format "cell %s runs" id)
                           (lambda () (funcall done (buffer-local-value 'drgnx-notebook--last-tails buffer) id))))

(defun drgnx-look-scene--notebook-views (theme &optional running)
  "The notebook opened through the hub (a real file), its three views side by side in the editor, in THEME: the
outline, the full output of a cell (RUNNING: the one that keeps running; else the 2 500-line one), the kernel's log.
With the image's kernel the cells run: one finishes, one fails and one keeps running; without it, the cells show what
a finished run left."
  (drgnx-look-scene--theme theme)
  (drgnx-look-scene--try "notebook-views"
    (drgnx-wb-focus-editor)
    (let ((kernel (drgnx-look-scene--kernel-python)))
      (unless kernel
        (push "notebook-views: no kernel (DRGNX_NB_KERNEL_PYTHON is unset or not executable): the cells show a finished run's, nothing runs"
              drgnx-look-scene--errors))
      (drgnx-look-scene--notebook-file kernel)       ; first: it sets JUPYTER_PATH, which the hub's process inherits
      (drgnx-look-scene--hub)
      (load (expand-file-name "modules/lang/drgnx-notebook" (bound-and-true-p drgnx-dir)) nil t)
      ;; the dark scene's notebook and views, when the light one follows
      (dolist (b (buffer-list))
        (when (string-prefix-p "*Notebook " (buffer-name b)) (let ((kill-buffer-query-functions nil)) (kill-buffer b))))
      (when-let* ((old (get-buffer "cache-experiments.ipynb")))
        (with-current-buffer old (set-buffer-modified-p nil))
        (kill-buffer old))
      (let* ((buffer (find-file-noselect (drgnx-look-scene--notebook-file kernel))) (base (buffer-name buffer)) views)
        (drgnx-look-scene--show buffer)
        (when (drgnx-look-scene--until 30 "the notebook opens" (lambda () (buffer-local-value 'drgnx-notebook--id buffer)))
          (when kernel
            (let ((ran (lambda (tails id) (let ((h (plist-get (gethash id tails) :head))) (and h (not (equal (plist-get h :state) "queued")) (string-match-p "\\[[0-9]+\\]" (or (plist-get h :text) "")))))))
              (drgnx-look-scene--run-cell buffer "c1" ran 7)
              (drgnx-look-scene--run-cell buffer "c3" ran 3)
              (drgnx-look-scene--run-cell buffer "c4" ran 5)
              (drgnx-look-scene--run-cell buffer "c2" (lambda (tails id) (string-search "16" (or (plist-get (gethash id tails) :text) ""))) 3))
            (let ((end (+ (float-time) 1.5)))   ; the log's first entries and the output's second line
              (while (< (float-time) end) (accept-process-output nil 0.05) (redisplay))))
          (with-current-buffer buffer
            (goto-char (1+ (plist-get (drgnx-notebook--cell-by-id (if kernel "c2" "c3")) :head)))
            (drgnx-notebook--select-at (point))      ; no command ran: the hub is told which cell point is in
            (drgnx-notebook-outline)
            ;; the output shown is the long one (2 500 lines), moved half a window on below: rows above and below
            (goto-char (1+ (plist-get (drgnx-notebook--cell-by-id (if kernel (if running "c2" "c4") "c3")) :head)))
            (drgnx-notebook-open-output)
            (goto-char (1+ (plist-get (drgnx-notebook--cell-by-id (if kernel "c2" "c3")) :head)))
            (drgnx-notebook--select-at (point))
            (drgnx-notebook-kernel-log))
          (setq views (list (format "*Notebook outline: %s*" base) (format "*Notebook output: %s %s*" base (if kernel (if running "c2" "c4") "c3"))
                            (format "*Notebook log: %s*" base)))
          (drgnx-look-scene--until 30 "the views' buffers" (lambda () (seq-every-p #'get-buffer views)))
          (drgnx-look-scene--one-editor)
          (setq drgnx-look-scene--windows-rearranged t)
          (let* ((w1 (selected-window)) (w2 (split-window-right)) (w3 (with-selected-window w2 (split-window-right))))
            (cl-loop for w in (list w1 w2 w3) for name in views
                     do (set-window-buffer w (get-buffer name))
                     (with-current-buffer name (drgnx-view-env-update drgnx-notebook-view--id))))
          (drgnx-look-scene--until 30 "the views' rows"
                                   (lambda () (seq-every-p (lambda (name)
                                                             (with-current-buffer name
                                                               (when (drgnx-view-p drgnx-view) (drgnx-view-draw-now drgnx-view))
                                                               (> (buffer-size) 0)))
                                                           views)))
          (apply #'drgnx-look-scene--shown "notebook-views" views)
          (when (and kernel (not running))
            (with-current-buffer (cadr views) (drgnx-notebook-output-later))
            (drgnx-look-scene--until 12 "the output's window moves"
                                     (lambda () (with-current-buffer (cadr views)
                                                  (when (drgnx-view-p drgnx-view) (drgnx-view-draw-now drgnx-view))
                                                  ;; the cut row's mark: a narrow pane drops its "N lines above"
                                                  (string-search "▲" (buffer-string)))))
            ;; the window shows the rows from the top, the cut row above them first
            (when-let* ((w (get-buffer-window (cadr views) t)))
              (with-current-buffer (cadr views) (goto-char (point-min)))
              (set-window-point w (point-min))
              (set-window-start w (point-min))))))))
  (drgnx-look-scene--answer))

(defun drgnx-look-scene-notebook-views-running () "The three notebook views, the output of the running cell." (drgnx-look-scene--notebook-views 'drgnx-dark t))
(defun drgnx-look-scene-notebook-views-light () "The three notebook views, light." (drgnx-look-scene--notebook-views 'drgnx-light))
(defun drgnx-look-scene-notebook-views () "The notebook and its outline view." (drgnx-look-scene--notebook-views 'drgnx-dark))
(defun drgnx-look-scene-notebook-dark () "The notebook, dark." (drgnx-look-scene--notebook 'drgnx-dark))
(defun drgnx-look-scene-notebook-light () "The notebook, light." (drgnx-look-scene--notebook 'drgnx-light))

;;;; Widths: no hub-fed row wider than its window

(declare-function drgnx-view-patch-class "drgnx-view")
(declare-function drgnx-view-key-at "drgnx-view")
(declare-function drgnx-view-env-face "drgnx-view-env")

(defvar drgnx-look-scene--widths-log nil
  "What the current scene's width check measured, newest first: (VIEW BUFFER HOW BODY-PX ROWS WIDE) per window and
width, written to the scene's widths file.")

(defvar drgnx-look-scene--widths-seen (make-hash-table :test #'equal)
  "(BUFFER-NAME CHARS-TICK BODY-PX) → t for the view states already checked narrow and wide, so a view no scene changed
is not resized again (bounded by the scenes: one entry per view per scene at most).")

(defconst drgnx-look-scene-widths-max-rows 4000
  "The most lines of a view's buffer `drgnx-look-scene--wide-rows' measures.")

(defvar drgnx-look-scene--rows-measured 0 "How many rows the last `drgnx-look-scene--wide-rows' measured.")

(defun drgnx-look-scene--fed-windows ()
  "The live windows of the visible frames that show a hub-fed view (a buffer with a `drgnx-view-patch')."
  (cl-remove-if-not (lambda (w) (and (boundp 'drgnx-view-patch) (buffer-local-value 'drgnx-view-patch (window-buffer w))))
                    (cl-mapcan (lambda (f) (and (eq (frame-visible-p f) t) (window-list f 'never))) (frame-list))))

(defun drgnx-look-scene--px (window from to)
  "The px from FROM to TO in WINDOW (its buffer current) as drawn.  `window-text-pixel-size' from a position right
after invisible text (the Explorer's hidden root row, its newline hidden too, so the next row starts mid screen line)
leaves out an image at FROM; this measures from where the invisible run starts and takes off the px before FROM."
  (let ((s from))
    (while (and (> s (point-min)) (invisible-p (1- s)))
      (setq s (1- s)))
    (if (= s from)
        (car (window-text-pixel-size window from to))
      (- (car (window-text-pixel-size window s to)) (car (window-text-pixel-size window s from))))))

(defun drgnx-look-scene--row-parts (window bol eol)
  "The parts of the row BOL..EOL in WINDOW's buffer as drawn, for the log of a row wider than its window: ((TEXT FACE
PX HOW) ...), one per stretch of one face, PX its width in WINDOW and HOW the face's answer to the hub
\(`drgnx-view-env-face'), so a wrong guess shows where it is."
  (let ((pos bol) parts)
    (while (< pos eol)
      (let* ((next (min eol (next-single-property-change pos 'face nil eol)))
             (face (get-text-property pos 'face))
             (top (if (consp face) (car face) face)))
        (push (list (buffer-substring-no-properties pos next) face
                    (drgnx-look-scene--px window pos next)
                    (and (symbolp top) top (drgnx-view-env-face (symbol-name top) (current-buffer))))
              parts)
        (setq pos next)))
    (nreverse parts)))

(defun drgnx-look-scene--wide-rows (window)
  "The hub's rows in WINDOW's buffer (lines that start a row with a string key: a Lisp-drawn line, such as the agent
panel's composer, is not one) drawn wider than WINDOW's body: ((PX LINE TEXT PARTS FONTS) ...), TEXT the row's
first 60 characters, LINE its line number, PARTS its stretches as drawn (`drgnx-look-scene--row-parts') and FONTS the
roles the hub measured it in.  The number of rows measured is in `drgnx-look-scene--rows-measured'."
  (let ((body (window-body-width window t)) (n 0) (rows 0) wide)
    (with-current-buffer (window-buffer window)
      (save-excursion
        (save-restriction
          (widen)
          (goto-char (point-min))
          (while (and (not (eobp)) (< n drgnx-look-scene-widths-max-rows))
            (setq n (1+ n))
            (let* ((bol (point)) (eol (line-end-position)))
              (when (stringp (ignore-errors (drgnx-view-key-at bol)))
                (setq rows (1+ rows))
                (let ((px (drgnx-look-scene--px window bol eol)))
                  (when (> px body)
                    (push (list px n (buffer-substring-no-properties bol (min eol (+ bol 60)))
                                (drgnx-look-scene--row-parts window bol eol)
                                ;; the roles the hub measured the row in
                                (ignore-errors
                                  (plist-get (gethash (drgnx-view-key-at bol) (drgnx-view-patch-rows drgnx-view-patch))
                                             :fonts)))
                          wide)))))
            (forward-line 1)))))
    (setq drgnx-look-scene--rows-measured rows)
    (nreverse wide)))

(defun drgnx-look-scene--rows-settle (buffer how)
  "Wait for BUFFER's rows after its window's width changed (HOW names the width): its env goes out now (not after the
idle debounce), then a round trip to the hub (`drgnx-look-scene--hub-caught-up') and the patches it sent drawn, again
until a round trip changes nothing (the editor's answers to the hub's asks, a refit, go out in between).  An error
when the hub does not answer, or when its rows still change after 10 s."
  (let ((view (drgnx-view-patch-view (buffer-local-value 'drgnx-view-patch buffer)))
        (end (+ (float-time) 10)) (settled nil))
    (redisplay t)
    (drgnx-view-env-update view)
    (while (and (not settled) (< (float-time) end))
      (let ((tick (buffer-chars-modified-tick buffer)))
        (unless (drgnx-look-scene--hub-caught-up)
          (push (format "widths: %s (%s) %s: the hub did not answer a ping" view (buffer-name buffer) how)
                drgnx-look-scene--errors)
          (setq end 0))
        ;; the patches it sent, drawn (a coalescing timer runs here)
        (accept-process-output nil 0.05)
        (with-current-buffer buffer (when (drgnx-view-p drgnx-view) (drgnx-view-draw-now drgnx-view)))
        (redisplay t)
        (setq settled (= tick (buffer-chars-modified-tick buffer)))))
    (unless (or settled (zerop end))
      (push (format "widths: %s (%s) %s: the rows still changed after 10 s" view (buffer-name buffer) how)
            drgnx-look-scene--errors))))

(defun drgnx-look-scene--widths-check (window how)
  "One error per WINDOW whose hub rows are wider than its body, HOW naming the width (as drawn, narrow, wide)."
  (let* ((wide (drgnx-look-scene--wide-rows window))
         (buffer (window-buffer window)) (state (buffer-local-value 'drgnx-view-patch buffer))
         (view (drgnx-view-patch-view state)))
    (push (list view (buffer-name buffer) how (window-body-width window t) drgnx-look-scene--rows-measured
                (length wide) (seq-take wide 4))
          drgnx-look-scene--widths-log)
    (when wide
      (push (format "widths: %s (%s, class %s) %s at %d px (env width %S): %d rows wider than the body, e.g. %S"
                    view (buffer-name buffer) (drgnx-view-patch-class state) how (window-body-width window t)
                    (mapcar (lambda (c) (plist-get (cdr c) :width_px)) (drgnx-view-env--envs view))
                    (length wide) (seq-take wide 4))
            drgnx-look-scene--errors))))

(defun drgnx-look-scene--resize (window delta)
  "Make WINDOW DELTA pixels wider (narrower when negative), as far as the frame allows, its neighbours' preserved
sizes ignored (a dock's side window keeps its width otherwise); the pixels it moved."
  (let* ((d (if (> delta 0) (min delta (window-max-delta window t t nil nil nil t))
              (- (min (- delta) (window-min-delta window t t nil nil nil t)))))
         (from (window-pixel-width window)))
    (unless (zerop d) (window-resize window d t t t))
    (- (window-pixel-width window) from)))

(defun drgnx-look-scene--widths-save ()
  "The selected frame's windows with their pixel widths, to put back after a window's resize."
  (mapcar (lambda (w) (cons w (window-pixel-width w))) (window-list nil 'nomini)))

(defun drgnx-look-scene--widths-restore (sizes)
  "Give each window of SIZES (`drgnx-look-scene--widths-save') its width back.  A resize takes the pixels from a
neighbour, so giving one window back its width moves another: pass again until none moves (at most four passes).
Without this each checked window leaves its neighbours (the Explorer too) wider or narrower for the next one."
  (let ((window-resize-pixelwise t) (n 0))
    (while (and (< n 4)
                (let ((moved nil))
                  (pcase-dolist (`(,w . ,px) sizes)
                    (when (and (window-live-p w) (/= px (window-pixel-width w)))
                      (ignore-errors (window-resize w (- px (window-pixel-width w)) t t t))
                      (setq moved t)))
                  moved))
      (setq n (1+ n)))))

(defconst drgnx-look-scene-widths-slack 10
  "The px the hub keeps short of a segment's end (`drgnx_rows::fit::SLACK').")

(defconst drgnx-look-scene-widths-gap 10
  "The logical px a view keeps between a cut text and a text after it on its row (the Flow's column gap, the Run and
Debug rows' two gaps before a frame's place).")

(defun drgnx-look-scene--blank-p (q)
  "Non-nil when the char at Q is a blank: a space, a tab or a stop's space."
  (or (memq (char-after q) '(?\s ?\t)) (eq (car-safe (get-text-property q 'display)) 'space)))

(defun drgnx-look-scene--filled-p (q frame)
  "Non-nil when the char at Q is drawn in a face with a box or a background of its own on FRAME: part of a block (a
card, a chip), whose width its row's layout sets, not the text's."
  (let ((faces (get-text-property q 'face)) (bg (face-background 'default frame)))
    (setq faces (if (or (not (listp faces)) (keywordp (car faces))) (list faces) faces))
    (seq-some (lambda (f)
                (if (and (consp f) (keywordp (car f)))
                    (or (plist-get f :box) (plist-get f :background))
                  (and f (facep f)
                       (or (not (memq (face-attribute f :box frame t) '(nil unspecified)))
                           (let ((b (face-attribute f :background frame t)))
                             (and (stringp b) (not (equal b bg))))))))
              faces)))

(defun drgnx-look-scene--free-after (window bol pos eol)
  "The px free after POS on its row BOL..EOL in WINDOW: the blanks and stops' spaces from POS on, and, when they reach
EOL, the body's px past the row's end.  A blank in a block's face (`drgnx-look-scene--filled-p': a card's fill or
edge) ends the count: when the row ends in that block, its end pad less the row's start pad in the same face (the
block's own padding, kept on both sides) counts, and the px past the block are not the text's."
  (let ((q pos) (frame (window-frame window)) (block nil))
    (while (and (< q eol) (drgnx-look-scene--blank-p q) (not block))
      (if (drgnx-look-scene--filled-p q frame) (setq block q) (setq q (1+ q))))
    (let ((free (if (> q pos) (car (window-text-pixel-size window pos q)) 0)))
      (cond
       ((not block)
        (+ free (if (< q eol) 0
                  (max 0 (- (window-body-width window t) (drgnx-look-scene--px window bol eol))))))
       (t
        (let ((e block) (face (get-text-property block 'face)) (s bol))
          (while (and (< e eol) (drgnx-look-scene--blank-p e) (equal (get-text-property e 'face) face))
            (setq e (1+ e)))
          (while (and (< s pos) (drgnx-look-scene--blank-p s) (equal (get-text-property s 'face) face))
            (setq s (1+ s)))
          (if (< e eol) free
            (+ free (max 0 (- (car (window-text-pixel-size window block eol))
                              (if (> s bol) (drgnx-look-scene--px window bol s) 0)))))))))))

(defun drgnx-look-scene--cut-rows (window how)
  "Each cut drawn in the hub's rows in WINDOW's buffer (none in hidden text): (KEY HOW BODY-PX PREFIX AFTER FREE
ELLIPSIS-PX ROW-PARTS FONTS),
PREFIX the row's text before the `…', AFTER its text after it, FREE the px free after it
\(`drgnx-look-scene--free-after', less `drgnx-look-scene-widths-gap' when a text follows), FONTS the roles
the hub measured the row in."
  (let ((out nil) (n 0))
    (with-current-buffer (window-buffer window)
      (save-excursion
        (save-restriction
          (widen)
          (goto-char (point-min))
          (while (and (not (eobp)) (< n drgnx-look-scene-widths-max-rows))
            (setq n (1+ n))
            (let* ((bol (point)) (eol (line-end-position)) (key (ignore-errors (drgnx-view-key-at bol))))
              (when (stringp key)
                (goto-char bol)
                (while (search-forward "…" eol t)
                  ;; a hidden row (the Explorer's root: its name is the side bar's title) draws no cut
                  (unless (invisible-p (1- (point)))
                    (push (list key how (window-body-width window t)
                                (buffer-substring-no-properties bol (1- (point)))
                                (buffer-substring-no-properties (point) eol)
                                ;; a text after the cut on the row keeps the hub's gap from it (a column's, a
                                ;; place's at the right edge): not the cut text's room
                                (let ((free (drgnx-look-scene--free-after window bol (point) eol)))
                                  (if (string-blank-p (buffer-substring-no-properties (point) eol)) free
                                    (max 0 (- free (drgnx-px drgnx-look-scene-widths-gap (window-frame window))))))
                                ;; with its faces, as the cut text is measured (`drgnx-look-scene--over-cut'):
                                ;; `window-text-pixel-size' of a char past the body's edge gives the whole line's
                                (string-pixel-width (let ((e (buffer-substring (1- (point)) (point))))
                                                      (remove-text-properties 0 1 '(read-only nil front-sticky nil) e)
                                                      e)
                                                    (current-buffer))
                                (drgnx-look-scene--row-parts window bol eol)
                                (ignore-errors (plist-get (gethash key (drgnx-view-patch-rows drgnx-view-patch)) :fonts)))
                          out)))))
            (goto-char (line-end-position))
            (forward-line 1)))))
    (nreverse out)))

(defun drgnx-look-scene--row-texts (window)
  "KEY → the hub row's text as drawn in WINDOW's buffer (with its faces), for the rows with a string key."
  (let ((rows (make-hash-table :test #'equal)) (n 0))
    (with-current-buffer (window-buffer window)
      (save-excursion
        (save-restriction
          (widen)
          (goto-char (point-min))
          (while (and (not (eobp)) (< n drgnx-look-scene-widths-max-rows))
            (setq n (1+ n))
            (let ((key (ignore-errors (drgnx-view-key-at (point)))))
              (when (stringp key) (puthash key (buffer-substring (point) (line-end-position)) rows)))
            (forward-line 1)))))
    rows))

(defun drgnx-look-scene--over-cut (cut wide buffer)
  "CUT (one of `drgnx-look-scene--cut-rows') when the text it cut off fits the px free after its `…': the same row's
text WIDE (from `drgnx-look-scene--row-texts' at the widest width) gives what was cut (from the end of its prefix to
the text after the `…', blanks trimmed), measured in BUFFER with its faces; the hub keeps the slack short of an end.
Nil when the row changed otherwise, or is cut there at that width too.  Else CUT with the cut text and its px."
  (pcase-let ((`(,key ,_how ,_body ,prefix ,after ,free ,ell . ,_) cut))
    (when-let* ((full (gethash key wide))
                ((string-prefix-p prefix (substring-no-properties full)))
                (rest (substring full (length prefix)))
                ((not (string-prefix-p "…" rest)))
                (next (string-trim-left after))
                (to (if (string-empty-p next) (length rest)
                      (string-search (substring next 0 (min 4 (length next))) (substring-no-properties rest))))
                (gone (string-trim-right (substring rest 0 to)))
                ((not (string-empty-p gone)))
                ;; its faces kept, not the view's `read-only' (`string-pixel-width' inserts it in a work buffer)
                (px (string-pixel-width (let ((s (copy-sequence gone)))
                                          (remove-text-properties 0 (length s) '(read-only nil front-sticky nil) s)
                                          s)
                                        buffer))
                ((<= (+ (- px ell) drgnx-look-scene-widths-slack) (1- free))))
      (append cut (list :cut-off (substring-no-properties gone) :cut-off-px px)))))

(defvar drgnx-look-scene-widths-fixed nil
  "Regexps of the buffer names whose windows a scene may show at a width the frame cannot change by 40 px (measured as
drawn only); any other fed window that cannot be resized fails the width check.")

(defvar drgnx-look-scene--asks (make-hash-table :test #'equal)
  "VIEW → (EVENTS GLYPHS FACES MEASURES ASKED): what the hub asked this Emacs about VIEW's rows (`view-glyphs'), for
the widths file (bounded by the views the scenes open); ASKED the last 16 texts it asked to measure, each its roles key
and its first 40 chars.")

(defun drgnx-look-scene--count-asks (event data)
  "Count a `view-glyphs' EVENT's asks (DATA) under its view in `drgnx-look-scene--asks'."
  (when (equal event "view-glyphs")
    (let ((c (or (gethash (plist-get data :view) drgnx-look-scene--asks) (list 0 0 0 0 nil))))
      (puthash (plist-get data :view)
               (list (1+ (nth 0 c)) (+ (nth 1 c) (length (plist-get data :ask)))
                     (+ (nth 2 c) (length (plist-get data :faces))) (+ (nth 3 c) (length (plist-get data :measure)))
                     (seq-take (append (mapcar (lambda (m) (list (nth 0 m) (truncate-string-to-width (nth 1 m) 40)))
                                               (reverse (append (plist-get data :measure) nil)))
                                       (nth 4 c))
                               16))
               drgnx-look-scene--asks))))

(with-eval-after-load 'drgnx-view-env
  (advice-add 'drgnx-view-env-event :before #'drgnx-look-scene--count-asks))

(defun drgnx-look-scene-widths (file)
  "No hub-fed view's row is wider than its window's body, and none is cut with `…' where its full text fits: every
window of the visible frames that shows one, as the shot drew it, then narrower (by a third, at most 300 px) and
wider (300 px, as far as the frame allows), each once the hub's rows for that width came
\(`drgnx-look-scene--rows-settle'), then back.  A cut row at the drawn and narrow widths is checked against the same
row at the wide one (`drgnx-look-scene--over-cut').  A window the frame cannot resize by 40 px fails, unless its
buffer is named in `drgnx-look-scene-widths-fixed'.  A view state already checked (same text, same width) is not
resized again.  What was measured goes to FILE."
  (setq drgnx-look-scene--widths-log nil)
  (drgnx-look-scene--try "widths"
    (dolist (w (drgnx-look-scene--fed-windows))
      (drgnx-look-scene--widths-check w "as drawn")
      (let* ((buffer (window-buffer w))
             (key (list (buffer-name buffer) (buffer-chars-modified-tick buffer) (window-body-width w t)))
             (view (drgnx-view-patch-view (buffer-local-value 'drgnx-view-patch buffer)))
             (cuts (drgnx-look-scene--cut-rows w "as drawn")))
        ;; the same width once a round trip to the hub drew what it still had for it.  When that changed the rows, the
        ;; shot was taken before the hub's refit (the scene's wait is short): its cuts are logged with the rows the
        ;; hub settled on, and those are checked instead
        (drgnx-look-scene--rows-settle buffer "settled")
        (unless (= (nth 1 key) (buffer-chars-modified-tick buffer))
          (push (list view (buffer-name buffer) :changed-after-the-shot :cuts-in-the-shot cuts)
                drgnx-look-scene--widths-log)
          (drgnx-look-scene--widths-check w "settled")
          (setq cuts (drgnx-look-scene--cut-rows w "settled")))
        (unless (gethash key drgnx-look-scene--widths-seen)
          (puthash key t drgnx-look-scene--widths-seen)
          (let ((moved 0) (wide nil) (sizes (drgnx-look-scene--widths-save)))
            (unwind-protect
                (pcase-dolist (`(,how . ,delta) (list (cons "narrow" (- (min 300 (/ (window-body-width w t) 3))))
                                                      (cons "wide" 300)))
                  (when (/= moved 0) (window-resize w (- moved) t t t) (setq moved 0))
                  (setq moved (drgnx-look-scene--resize w delta))
                  (if (< (abs moved) 40)
                      (progn
                        (push (list (buffer-name buffer) how :not-resizable moved) drgnx-look-scene--widths-log)
                        (unless (seq-some (lambda (re) (string-match-p re (buffer-name buffer)))
                                          drgnx-look-scene-widths-fixed)
                          (push (format "widths: %s (%s) %s: the window moved %d px, not 40 (a scene must leave room \
to resize a fed window, or name it in `drgnx-look-scene-widths-fixed')" view (buffer-name buffer) how moved)
                                drgnx-look-scene--errors)))
                    (drgnx-look-scene--rows-settle buffer how)
                    (drgnx-look-scene--widths-check w how)
                    (if (equal how "wide") (setq wide (drgnx-look-scene--row-texts w))
                      (setq cuts (append cuts (drgnx-look-scene--cut-rows w how))))))
              (unless (zerop moved) (window-resize w (- moved) t t t))
              (drgnx-look-scene--widths-restore sizes)
              (drgnx-look-scene--rows-settle buffer "back"))
            (when wide
              (let ((over (delq nil (mapcar (lambda (c) (drgnx-look-scene--over-cut c wide buffer)) cuts))))
                (push (list view (buffer-name buffer) :cuts (length cuts) :over-cut (length over) (seq-take over 4)
                            ;; what the hub measures with: the env's fonts, and what it asked of this Emacs
                            :env-fonts (mapcar (lambda (c) (cons (car c) (plist-get (cdr c) :fonts)))
                                               (drgnx-view-env--envs view))
                            :asks (gethash view drgnx-look-scene--asks))
                      drgnx-look-scene--widths-log)
                (when over
                  (push (format "widths: %s (%s): %d rows cut with … whose full text fits, e.g. %S"
                                view (buffer-name buffer) (length over)
                                (mapcar (lambda (o) (list (nth 0 o) (nth 1 o) (nth 2 o) (nth 3 o)
                                                          (plist-get (nthcdr 9 o) :cut-off)
                                                          (plist-get (nthcdr 9 o) :cut-off-px) (nth 5 o)))
                                        (seq-take over 4)))
                        drgnx-look-scene--errors)))))))))
  (let ((print-length nil) (print-level nil))
    (with-temp-file file (pp (reverse drgnx-look-scene--widths-log) (current-buffer))))
  (drgnx-look-scene--answer))

(defun drgnx-look-scene-facts (file &optional scene)
  "Write what SCENE realised to FILE: what the line cannot show yet (`drgnx-look-scene-limits'), themes, fonts of the
chrome faces, frame metrics, windows, modules."
  (drgnx-look-scene--try "facts"
    (let* ((f (selected-frame)) (print-length nil) (print-level nil))
      (with-temp-file file
        (pp (list :limits (cdr (assq scene drgnx-look-scene-limits))
                  :themes custom-enabled-themes
                  ;; the Emacs the scene ran on, and a box the compositor's keys shape (`:fit', `:corner-radius')
                  :emacs (list emacs-version (bound-and-true-p nidhogg-version) :glitnir (featurep 'glitnir))
                  :keycap-box (face-attribute 'drgnx-keycap :box f)
                  ;; the floating palette's frame and window, where it is shown: its insets come from these
                  ;; the Work map, where one is open: what it holds and what feeds it
                  :work-map (when-let* ((b (seq-find (lambda (b) (eq (buffer-local-value 'major-mode b)
                                                                     'drgnx-work-map-mode))
                                                     (buffer-list))))
                              (with-current-buffer b
                                (list :text (buffer-substring-no-properties (point-min) (min (point-max) 600))
                                      :rows (and (fboundp 'drgnx-work-map-rows-p) (drgnx-work-map-rows-p))
                                      :hub (and (fboundp 'drgnx-hub-running-p) (drgnx-hub-running-p))
                                      :line-spacing (list line-spacing (frame-parameter nil 'line-spacing) (default-line-height))
                                      :view (bound-and-true-p drgnx-work-space--view)
                                      :message (bound-and-true-p drgnx-work-space--message))))
                  ;; the notebook, where one is open: what its chrome is made of
                  :notebook (when-let* ((b (seq-find (lambda (b) (eq (buffer-local-value 'major-mode b) 'drgnx-notebook-mode))
                                                     (buffer-list))))
                              (with-current-buffer b
                                (list :overlays (length (overlays-in (point-min) (point-max)))
                                      :heads (length (seq-filter (lambda (o) (overlay-get o 'before-string)) (overlays-in (point-min) (point-max))))
                                      :tails (length (seq-filter (lambda (o) (overlay-get o 'after-string)) (overlays-in (point-min) (point-max))))
                                      :cells (length drgnx-notebook--cells) :text-length (- (point-max) (point-min))
                                      :parsers (and (fboundp 'treesit-parser-list) (mapcar #'treesit-parser-language (treesit-parser-list)))
                                      :font-lock font-lock-mode :undo (length buffer-undo-list)
                                      :blocks drgnx-look-scene--notebook-blocks)))
                  ;; the Flow, where one is open: its first lines, with the text properties that hide or replace text
                  :work-flow (when-let* ((b (seq-find (lambda (b) (eq (buffer-local-value 'major-mode b)
                                                                      'drgnx-work-flow-mode))
                                                      (buffer-list))))
                               (with-current-buffer b
                                 (let ((end (min (point-max) 400)))
                                   (list :text (buffer-substring-no-properties (point-min) end)
                                         :hidden (let (out (pos (point-min)))
                                                   (while (< pos end)
                                                     (let ((next (next-single-char-property-change pos 'invisible nil end)))
                                                       (when (get-char-property pos 'invisible)
                                                         (push (list pos next (get-char-property pos 'invisible)) out))
                                                       (setq pos next)))
                                                   (nreverse out))
                                         :invisibility buffer-invisibility-spec))))
                  :palette (let ((pf (bound-and-true-p drgnx-palette-frame--frame)))
                             (when (and (frame-live-p pf) (frame-visible-p pf))
                               (let ((w (frame-root-window pf)))
                                 (list :px (list (frame-pixel-width pf) (frame-pixel-height pf))
                                       :inner (list (frame-inner-width pf) (frame-text-width pf))
                                       :params (mapcar (lambda (p) (cons p (frame-parameter pf p)))
                                                       '(internal-border-width child-frame-border-width
                                                                               left-fringe right-fringe))
                                       :window (list :edges (window-pixel-edges w) :body (window-body-pixel-edges w)
                                                     :margins (window-margins w) :fringes (window-fringes w))
                                       ;; what starts the input row: the buffer's prefix and the overlays there
                                       :start (with-current-buffer (window-buffer w)
                                                (list :line-prefix line-prefix
                                                      :prompt-end (minibuffer-prompt-end)
                                                      :first-row (window-text-pixel-size w (point-min)
                                                                                         (line-end-position))
                                                      ;; the room before the typed text, with and without the prefix
                                                      :lead (list (car (window-text-pixel-size
                                                                        w (point-min) (minibuffer-prompt-end)))
                                                                  (let ((p line-prefix))
                                                                    (setq-local line-prefix nil)
                                                                    (prog1 (car (window-text-pixel-size
                                                                                 w (point-min) (minibuffer-prompt-end)))
                                                                      (setq-local line-prefix p))))
                                                      :overlays
                                                      (mapcar (lambda (o) (list (overlay-start o) (overlay-end o)
                                                                                (overlay-properties o)))
                                                              (overlays-in (point-min) (1+ (point-min))))))))))
                  :fonts (mapcar (lambda (fc) (list fc (ignore-errors (face-font fc f))))
                                 '(default drgnx-ui-text drgnx-ui-heading drgnx-ui-caption tab-bar tab-line
                                           mode-line header-line))
                  :frame (list :px (list (frame-pixel-width f) (frame-pixel-height f)) :scale (frame-scale-factor f)
                               :line-px (frame-char-height f) :tab-bar-lines (frame-parameter f 'tab-bar-lines)
                               :tab-bar-px (tab-bar-height f t) :wm (frame-parameter f 'drgnx-platform-wm)
                               :drawn-title (and (fboundp 'drgnx-face-drawn-title-p) (drgnx-face-drawn-title-p f)))
                  :windows (mapcar (lambda (w) (list (buffer-name (window-buffer w)) :x (window-pixel-left w)
                                                     :y (window-pixel-top w) :w (window-pixel-width w)
                                                     :h (window-pixel-height w)
                                                     ;; the text area and its line: whole rows or a part of one
                                                     :body (window-body-height w t)
                                                     :header (window-header-line-height w)
                                                     :line (window-default-line-height w)
                                                     :end (cdr (posn-x-y (posn-at-point (window-end w t) w)))
                                                     ;; the gutter: fringes, margins and where the text area starts
                                                     :fringes (window-fringes w) :margins (window-margins w)
                                                     :text-left (car (window-body-pixel-edges w))
                                                     :numbers (with-selected-window w
                                                                (and (bound-and-true-p display-line-numbers-mode)
                                                                     (line-number-display-width t)))
                                                     :mode (buffer-local-value 'major-mode (window-buffer w))))
                                   (window-list f 'no-mini))
                  :children (cl-count-if (lambda (c) (and (frame-visible-p c) (frame-parent c))) (frame-list))
                  ;; each visible child frame: where it is and what it shows (a stray one reads as a band)
                  :child-frames (mapcar (lambda (c)
                                          (list (buffer-name (window-buffer (frame-root-window c)))
                                                :pos (frame-position c) :px (list (frame-pixel-width c) (frame-pixel-height c))
                                                :parent (and (frame-parent c) (frame-parameter (frame-parent c) 'name))))
                                        (cl-remove-if-not (lambda (c) (and (frame-visible-p c) (frame-parent c)))
                                                          (frame-list)))
                  ;; why the palette floats or not, while a minibuffer is open
                  :palette (when-let* ((w (active-minibuffer-window)))
                             (with-current-buffer (window-buffer w)
                               (list :wanted (and (fboundp 'drgnx-palette-frame-wanted-p)
                                                  (drgnx-palette-frame-wanted-p))
                                     :glitnir (and (fboundp 'glitnir-active-p) (glitnir-active-p))
                                     :vertico (ignore-errors (package-get-version))
                                     :vertico-dir (ignore-errors (file-name-directory (locate-library "vertico")))
                                     :entry (assq 'drgnx-command (bound-and-true-p vertico-multiform-categories))
                                     :category (ignore-errors
                                                 (completion-metadata-get
                                                  (completion-metadata "" minibuffer-completion-table
                                                                       minibuffer-completion-predicate)
                                                  'category))
                                     :buffer-mode (bound-and-true-p vertico-buffer-mode)
                                     :action (bound-and-true-p vertico-buffer-display-action)
                                     :shown-in (buffer-name (window-buffer (get-buffer-window (current-buffer) t)))
                                     :frame (and (boundp 'drgnx-palette-frame--frame)
                                                 (frame-live-p drgnx-palette-frame--frame)
                                                 (frame-visible-p drgnx-palette-frame--frame))
                                     ;; the frosting: what was asked, and what Glitnir drew
                                     :frost (and (boundp 'drgnx-palette-frame--frame)
                                                 (frame-live-p drgnx-palette-frame--frame)
                                                 (let ((pf drgnx-palette-frame--frame))
                                                   (list :alpha (frame-parameter pf 'alpha-background)
                                                         :blur (frame-parameter pf 'backdrop-blur)
                                                         :chrome (and (fboundp 'glitnir--chrome)
                                                                      (ignore-errors (glitnir--chrome pf)))
                                                         :stats (and (fboundp 'glitnir-stats)
                                                                     (ignore-errors (glitnir-stats pf)))))))))
                  ;; the echo area's box: the first frame is born with it, so a start swaps no frame
                  :echo (list :row (bound-and-true-p drgnx-look-echo-row)
                              :box (and (fboundp 'drgnx-look-echo-box) (drgnx-look-echo-box f) t)
                              :swaps (bound-and-true-p drgnx-look-echo-swaps)
                              :root-bottom (nth 3 (window-pixel-edges (frame-root-window f)))
                              :inner-height (frame-inner-height f))
                  :modules (ignore-errors (mapcar (lambda (r) (list (car r) (plist-get (cdr r) :status)))
                                                  (drgnx-modules-report))))
            (current-buffer)))))
  (drgnx-look-scene--answer))

;; The scroll bar's own scenes: the surfaces the other scenes do not show, each long enough to scroll, beside a short
;; one (the strip hides there).  Compared with minimap-folding.html's rest state.

(declare-function drgnx-settings-page "drgnx-settings-page")
(declare-function drgnx-shortcuts "drgnx-shortcuts")
(declare-function drgnx-outline-focus "drgnx-outline")
(declare-function drgnx-terminal-new "drgnx-terminal")
(declare-function drgnx-term-send-string "drgnx-term" (text))

(defun drgnx-look-scene--lines-buffer (name n)
  "A buffer NAME of N numbered lines, read-only, at its top."
  (with-current-buffer (get-buffer-create name)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (dotimes (i n) (insert (format "%4d  output line %d of %d\n" (1+ i) (1+ i) n))))
    (goto-char (point-min))
    (setq buffer-read-only t)
    (current-buffer)))

(defun drgnx-look-scene-scrollbars-editor ()
  "A long file in the editor (the strip with its thumb) and the Outline of it in the sidebar."
  (drgnx-look-scene--theme 'drgnx-dark)
  (drgnx-look-scene--try "scrollbars-editor"
    (drgnx-look-scene--editor)
    (drgnx-outline-focus)
    (drgnx-wb-focus-editor))
  (drgnx-look-scene--answer))

(defun drgnx-look-scene-scrollbars-panel ()
  "The panel's Output tab with 400 lines (scrolls); a short buffer in the editor (fits: no strip drawn)."
  (drgnx-look-scene--theme 'drgnx-dark)
  (drgnx-look-scene--try "scrollbars-panel"
    (drgnx-wb-focus-editor)
    (switch-to-buffer (drgnx-look-scene--lines-buffer "*scrollbars short*" 5))
    (drgnx-wb-area-show 'panel 'output (drgnx-look-scene--lines-buffer "*scrollbars output*" 400)))
  (drgnx-look-scene--answer))

(defun drgnx-look-scene-scrollbars-terminal ()
  "A terminal in the panel whose scrollback runs past it."
  (drgnx-look-scene--theme 'drgnx-dark)
  (drgnx-look-scene--try "scrollbars-terminal"
    (drgnx-terminal-new)
    (drgnx-term-send-string "seq 1 400\n")
    (sleep-for 1.5))
  (drgnx-look-scene--answer))

(defun drgnx-look-scene-scrollbars-settings ()
  "The Settings page in the editor."
  (drgnx-look-scene--theme 'drgnx-dark)
  (drgnx-look-scene--try "scrollbars-settings"
    (drgnx-wb-focus-editor)
    (drgnx-settings-page))
  (drgnx-look-scene--answer))

(defun drgnx-look-scene-scrollbars-shortcuts ()
  "The Keyboard Shortcuts page in the editor."
  (drgnx-look-scene--theme 'drgnx-dark)
  (drgnx-look-scene--try "scrollbars-shortcuts"
    (drgnx-wb-focus-editor)
    (drgnx-shortcuts))
  (drgnx-look-scene--answer))

;;;; The scroll bar on every surface (docs/guide/minimap.md)

(declare-function drgnx-uitest-snapshot "drgnx-uitest" (&optional frame))
(declare-function drgnx-uitest-region-equal-p "drgnx-uitest" (a b rect &rest keys))
(declare-function drgnx-scrollbar-window-p "drgnx-ruler" (window))
(defvar drgnx-ruler-span-function)

(defun drgnx-look-scene--settle-frame ()
  "Redisplay and give the compositor the frame (two redisplays around a short wait)."
  (redisplay t)
  (sleep-for 0.3)
  (redisplay t))

(defun drgnx-look-scene--scrollbar-windows ()
  "The windows of the visible frames, child frames too (the palette's list), that are scrollable surfaces."
  (let (out)
    (dolist (f (frame-list))
      (when (eq (frame-visible-p f) t)
        (dolist (w (window-list f 'nomini))
          (when (and (fboundp 'drgnx-scrollbar-window-p) (drgnx-scrollbar-window-p w)) (push w out)))))
    (nreverse out)))

(defun drgnx-look-scene--overflows-p (window)
  "Whether WINDOW shows only part of its content: its buffer's text runs past it, or it holds a window of a view."
  (with-current-buffer (window-buffer window)
    (or (and drgnx-ruler-span-function (funcall drgnx-ruler-span-function) t)
        (> (window-start window) (point-min))
        (< (window-end window t) (point-max)))))

(defun drgnx-look-scene--strip-rect (window)
  "WINDOW's strip as frame device pixels (L T R B), from its fringe and the ruler's width."
  (pcase-let* ((`(,_ ,_ ,right ,_) (window-pixel-edges window))
               (`(,_ ,top ,_ ,bottom) (window-inside-pixel-edges window))
               (own (or (window-parameter window 'drgnx-ruler-fringe) 0))
               (x1 (- right (window-right-divider-width window) (window-scroll-bar-width window) own)))
    (list (- x1 (plist-get (window-parameter window 'glitnir-ruler) :width)) top x1 bottom)))

(defvar drgnx-palette-frame--frame)

(defun drgnx-look-scene--covering (rect frame)
  "The visible child frame of FRAME that lies over RECT (L T R B, FRAME's pixels), or nil: a strip there cannot be seen."
  (seq-find (lambda (f)
              (and (eq (frame-parent f) frame) (frame-visible-p f)
                   (pcase-let ((`(,x . ,y) (frame-position f)) (`(,l ,top ,r ,b) rect))
                     (and (< x r) (> (+ x (frame-pixel-width f)) l)
                          (< y b) (> (+ y (frame-pixel-height f)) top)))))
            (frame-list)))

(defun drgnx-look-scene--expected-cover-p (f covers)
  "Whether child frame F is one the scene opens on purpose: the floating palette, or a frame whose buffer's name
COVERS (a regexp, the scene's :covers in `drgnx-look-scenes': its menu, card or drop-down) matches.  Any other cover,
a toast say, is an error, so an unexpected child frame still fails the scene."
  (or (and (boundp 'drgnx-palette-frame--frame) (eq f drgnx-palette-frame--frame))
      (frame-parameter f 'drgnx-switcher-card)
      (and covers (string-match-p covers (buffer-name (window-buffer (frame-root-window f)))))))

(defun drgnx-look-scene--ruler-set (window spec minimap)
  "WINDOW's `glitnir-ruler' SPEC and `glitnir-minimap' MINIMAP, and the window marked for the next redisplay: a window
parameter alone marks nothing, so on a frame redisplay does not pass (the root, while a popup is selected) Glitnir never
resolved the change and the two snapshots showed the same strip."
  (set-window-parameter window 'glitnir-ruler spec)
  (set-window-parameter window 'glitnir-minimap minimap)
  (force-window-update window))

(defun drgnx-look-scene-scrollbars (file &optional covers)
  "Every scrollable surface shown has the scroll bar: each window `drgnx-scrollbar-window-p' names has its
`glitnir-ruler' with the fringe widened, and on the root frame the strip draws something exactly when the window
shows only part of its content (a snapshot of the root frame with the strips, one without them, compared on each
strip; a child frame's own strips are not in the snapshot, so not judged there; a strip under the palette's child frame
or one COVERS names, `drgnx-look-scene--expected-cover-p', is not judged, one under any other child frame is an
error).  What was seen goes to FILE."
  (let (log)
    (drgnx-look-scene--try "scrollbars"
      (let* ((ws (drgnx-look-scene--scrollbar-windows))
             (root (seq-filter (lambda (w) (not (frame-parent (window-frame w)))) ws))
             (with (and (fboundp 'glitnir-snapshot) root (drgnx-uitest-snapshot)))
             ;; the strip and an open minimap (the strip widened over the text) both go for the snapshot without:
             ;; a minimap left on would cover the strip's rect in both and read as a strip that draws nothing
             (specs (mapcar (lambda (w) (list w (window-parameter w 'glitnir-ruler) (window-parameter w 'glitnir-minimap)))
                            root))
             without)
        (when with
          (unwind-protect
              (progn (dolist (s specs) (drgnx-look-scene--ruler-set (car s) nil nil))
                     (drgnx-look-scene--settle-frame)
                     (setq without (drgnx-uitest-snapshot)))
            (dolist (s specs) (drgnx-look-scene--ruler-set (car s) (nth 1 s) (nth 2 s)))
            (drgnx-look-scene--settle-frame)))
        (dolist (w ws)
          (let* ((spec (window-parameter w 'glitnir-ruler))
                 (over (drgnx-look-scene--overflows-p w))
                 (cover (and spec (not (frame-parent (window-frame w)))
                             (drgnx-look-scene--covering (drgnx-look-scene--strip-rect w) (window-frame w))))
                 (covered (and cover (drgnx-look-scene--expected-cover-p cover covers)))
                 (child (frame-parent (window-frame w)))
                 (drawn (and spec without (not covered) (not (frame-parent (window-frame w)))
                             (not (drgnx-uitest-region-equal-p with without (drgnx-look-scene--strip-rect w)
                                                               :tolerance 2 :ignore-alpha t))))
                 (fact (list :buffer (buffer-name (window-buffer w))
                             :mode (buffer-local-value 'major-mode (window-buffer w))
                             :strip (and spec t) :span (plist-get spec :span) :overflows over
                             ;; what the overflow and the strip were judged on: the window's start, end and the
                             ;; buffer's end, the span the buffer gives now (the spec's may be older) and whether
                             ;; Glitnir resolved the spec it has
                             :shown (list (window-start w) (window-end w t)
                                          (with-current-buffer (window-buffer w) (point-max)))
                             :span-now (with-current-buffer (window-buffer w)
                                         (and drgnx-ruler-span-function (funcall drgnx-ruler-span-function)))
                             :resolved (and (window-parameter w 'glitnir--ruler) t)
                             :drawn (cond (covered 'covered) ((and without (not child)) drawn) (t 'unchecked)))))
            (push fact log)
            (cond ((not spec)
                   (push (format "scrollbars: %s (%s) has no scroll bar" (buffer-name (window-buffer w))
                                 (plist-get fact :mode))
                         drgnx-look-scene--errors))
                  ((and cover (not covered))
                   (push (format "scrollbars: %s (%s): the strip is under an unexpected child frame (%s at %S, %dx%d)"
                                 (buffer-name (window-buffer w)) (plist-get fact :mode)
                                 (buffer-name (window-buffer (frame-root-window cover)))
                                 (frame-position cover) (frame-pixel-width cover) (frame-pixel-height cover))
                         drgnx-look-scene--errors))
                  ((and without (not covered) (not child) (not (eq (and over t) (and drawn t))))
                   (push (format "scrollbars: %s (%s): content %s but the strip %s"
                                 (buffer-name (window-buffer w)) (plist-get fact :mode)
                                 (if over "runs past the window" "fits") (if drawn "draws" "draws nothing"))
                         drgnx-look-scene--errors)))))))
    (let ((print-length nil) (print-level nil))
      (with-temp-file file (pp (nreverse log) (current-buffer))))
    (drgnx-look-scene--answer)))

;;;; The minimap open (docs/guide/minimap.md; minimap-folding.html B)

(declare-function nidhogg-view-minimap "nidhogg-views" (what file &optional layer))
(declare-function drgnx-minimap--spec "drgnx-minimap" (window))
(declare-function drgnx-minimap--file "drgnx-minimap" (buffer))
(declare-function drgnx-ruler--place "drgnx-ruler" (window))

(defun drgnx-look-scene--parser-rs ()
  "minimap-folding.html's parser.rs, about 2,850 lines: five MARK sections, each a struct and an impl of eight
functions whose bodies nest loops and branches (the minimap's shading and labels have something to show)."
  (let ((sections '("Tokens" "Parser" "Rows" "Errors" "Tests"))
        (verbs '("read" "decode" "split" "check" "emit" "merge" "skip" "flush")))
    (with-temp-buffer
      (insert "//! parser.rs: rows decoded from a table of tokens.\n\nuse std::collections::HashMap;\n\n")
      (dolist (sec sections)
        (insert (format "// MARK: - %s\n\npub struct %s {\n    rows: Vec<Row>,\n    seen: HashMap<u64, usize>,\n}\n\n" sec sec))
        (insert (format "impl %s {\n" sec))
        (dolist (v verbs)
          (insert (format "    fn %s_%s(&self, t: &Table) -> Result<(), Error> {\n" v (downcase sec)))
          (dotimes (i 6)
            (insert (format "        for r in t.rows().skip(%d) {\n            if r.len() > %d {\n" i (* 3 i))
                    (format "                let v = r.decode()?;\n                self.seen.get(&v.key()).copied().unwrap_or(%d);\n" i)
                    "                match v.kind() {\n                    Kind::Text => self.emit(v)?,\n"
                    "                    _ => continue,\n                }\n            }\n        }\n"))
          (insert "        Ok(())\n    }\n\n"))
        (insert "}\n\n"))
      (buffer-string))))

(defun drgnx-look-scene--minimap-held (spec-fn window)
  "Around `drgnx-minimap--spec' (SPEC-FN): WINDOW's spec, with `:open t' when a minimap scene marked WINDOW (the
pointer's dwell opens it; the GUI rows judge the dwell)."
  (let ((spec (funcall spec-fn window)))
    (if (window-parameter window 'drgnx-look-scene-minimap-open) (append spec '(:open t)) spec)))

(defun drgnx-look-scene--minimap-open (theme)
  "minimap-folding.html's B in THEME: a 2,850-line Rust file in the editor at its line 812, its minimap held open (the
pointer's dwell is the GUI rows' to judge, `:open' stands for it here) once the hub's labels for the file are in."
  (drgnx-look-scene--theme theme)
  (drgnx-look-scene--editor)
  (drgnx-look-scene--try "minimap-hover"
    ;; the labels are the scenes' hub's, read with the Rust pack's grammar: a hub with none labels nothing
    (unless (getenv "DRGNX_PACK_LOCK")
      (error "No pack grammars for the hub: DRGNX_PACK_LOCK and DRGNX_PACK_GRAMMARS (test/packs/hub-grammars.sh)"))
    (drgnx-look-scene--hub)
    (let ((f (expand-file-name "runtime/src/parser.rs" drgnx-look-scene--project)))
      (unless (file-exists-p f)
        (make-directory (file-name-directory f) t)
        (write-region (drgnx-look-scene--parser-rs) nil f nil 'silent)))
    (drgnx-look-scene--goto "runtime/src/parser.rs" 812 4 800)
    (let* ((w (selected-window)) (file (drgnx-minimap--file (window-buffer w))))
      ;; `get' answers (VERSION COUNT): the file's 50 definitions (5 structs, 5 impls, 40 functions), not just an answer
      (unless (drgnx-look-scene--until 20 "minimap labels"
                                       (lambda () (>= (or (cadr (and file (nidhogg-view-minimap 'get file "labels"))) 0)
                                                      50)))
        (push (format "minimap-hover: labels for %s: %S; the hub said: %s" file
                      (and file (nidhogg-view-minimap 'get file "labels"))
                      (let ((b (get-buffer " *ratatoskr*")))
                        (if b (with-current-buffer b
                                (string-join (seq-filter (lambda (l) (string-match-p "pack\\|grammar\\|minimap\\|outline\\|WARN\\|ERROR" l))
                                                         (split-string (buffer-string) "\n"))
                                             " | "))
                          "no hub buffer")))
              drgnx-look-scene--errors))
      ;; the spec is placed again whenever the strip is (a window change): the window is marked and every placing
      ;; adds `:open'
      (set-window-parameter w 'drgnx-look-scene-minimap-open t)
      (advice-add 'drgnx-minimap--spec :around #'drgnx-look-scene--minimap-held)
      (set-window-parameter w 'glitnir-minimap (drgnx-minimap--spec w))
      (drgnx-look-scene--settle-frame)))
  (drgnx-look-scene--answer))

(defun drgnx-look-scene-minimap-hover ()
  "The minimap open over a long Rust file, dark."
  (drgnx-look-scene--minimap-open 'drgnx-dark))

(defun drgnx-look-scene-minimap-hover-light ()
  "The minimap open over a long Rust file, light."
  (drgnx-look-scene--minimap-open 'drgnx-light))

(defvar drgnx-sticky-style)
(defvar drgnx-sticky--pin-shown)
(declare-function drgnx-sticky--fill "drgnx-sticky" (w positions))

(defun drgnx-look-scene-sticky-lines ()
  "minimap-folding.html's sticky lines (F6): the Rust file inside a function of an impl, the two scope lines over
the window's top rows, dark."
  (drgnx-look-scene--theme 'drgnx-dark)
  (drgnx-look-scene--editor)
  (drgnx-look-scene--try "sticky-lines"
    (let ((f (expand-file-name "runtime/src/parser.rs" drgnx-look-scene--project)))
      (unless (file-exists-p f)
        (make-directory (file-name-directory f) t)
        (write-region (drgnx-look-scene--parser-rs) nil f nil 'silent)))
    (drgnx-look-scene--goto "runtime/src/parser.rs" 40 4 30)
    (require 'drgnx-sticky)
    (setq drgnx-sticky-style 'lines)
    (let* ((w (selected-window))
           (scopes (save-excursion
                     (goto-char (window-start w))
                     (list (progn (re-search-backward "^impl ") (point))
                           (progn (goto-char (window-start w)) (re-search-backward "^    fn ") (point))))))
      ;; held: the header's own refill would show the same scopes; the shot must not race it
      (setq drgnx-sticky--pin-shown (list (cons w 'scene)))
      (drgnx-sticky--fill w scopes)
      (drgnx-look-scene--settle-frame)))
  (drgnx-look-scene--answer))

;;; Tiling (tiling.html): six tiles; the switcher, Resize Tiles and full size are the scenes' keys

(declare-function drgnx-groups-list "drgnx-groups")
(declare-function drgnx-pane-hide "drgnx-panes")
(declare-function drgnx-pane-window "drgnx-panes")
(declare-function drgnx-grid-split-tile "drgnx-grid" (window side))
(declare-function drgnx-grid--make-editor "drgnx-grid" (window))
(defvar drgnx-look-scene--term nil "The tiling scenes' terminal (the panel's tile j).")

(defun drgnx-look-scene--six-tiles ()
  "tiling.html's six tiles, dark: the Explorer (a), the gateway file (s, current), an editor with three tabs (d), the
agent panel (f), the panel's terminal under the editors (j) and the Work map under the agent (k)."
  (drgnx-look-scene--theme 'drgnx-dark)
  (drgnx-look-scene--editor)
  (drgnx-look-scene--try "six tiles"
    (unless (buffer-live-p drgnx-look-scene--panel) (error "No agent panel (the mock agent did not run)"))
    ;; one editor to start from: the other groups an earlier scene left go (`delete-other-windows' keeps tiles)
    (let ((keep (car (drgnx-groups-list))))  ; the first in reading order: the editor area's, not the one under the agent
      (dolist (g (drgnx-groups-list)) (unless (eq g keep) (delete-window g)))
      (select-window keep))
    (let ((map (drgnx-work-space-open nil t)))
      (unless (get-buffer-window drgnx-look-scene--panel)
        (drgnx-pane-show 'agent-panel :buffer drgnx-look-scene--panel))
      (if (buffer-live-p drgnx-look-scene--term)
          (unless (get-buffer-window drgnx-look-scene--term) (pop-to-buffer drgnx-look-scene--term))
        (setq drgnx-look-scene--term (save-selected-window (drgnx-terminal-new))))
      (let* ((s (progn (drgnx-wb-focus-editor) (selected-window)))
             (d (drgnx-grid-split-tile s 'right))
             (k (drgnx-grid-split-tile (get-buffer-window drgnx-look-scene--panel) 'below)))
        (drgnx-grid--make-editor d)
        (dolist (file '("README.md" "test/unit/hub-test.el" "test/unit/gateway-test.el"))
          ;; the agent edited gateway-test.el and the setup left it changed: its buffer, not `find-file''s question
          (let ((f (expand-file-name file drgnx-look-scene--project)))
            (switch-to-buffer (or (get-file-buffer f) (find-file-noselect f)))))
        (drgnx-grid--make-editor k)
        (switch-to-buffer map)
        (select-window s)
        (drgnx-look-scene--goto "core/drgnx-gateway.el" 216 33 201))
      (setq drgnx-look-scene--windows-rearranged t)
      (drgnx-look-scene--until 15 "the Work map tile's rows" (lambda () (with-current-buffer map (drgnx-look-scene--row-ids ""))))
      ;; the map shows its Detail in the right dock once its rows come: the agent's tile is the mockup's there
      (when (drgnx-pane-window 'work-detail) (drgnx-pane-hide 'work-detail))
      (unless (get-buffer-window drgnx-look-scene--panel)
        (save-selected-window (drgnx-pane-show 'agent-panel :buffer drgnx-look-scene--panel)))
      (drgnx-look-scene--settle-frame))))

(defun drgnx-look-scene-tiling ()
  "Six tiles with the switcher open (its keys, C-<escape>): a letter card on every tile."
  (drgnx-look-scene--six-tiles)
  (drgnx-look-scene--answer))

(defun drgnx-look-scene-tiling-resize ()
  "Six tiles in Resize Tiles (its keys, C-k r), one step to the right taken."
  (drgnx-look-scene--six-tiles)
  (drgnx-look-scene--answer))

(defun drgnx-look-scene-tiling-full ()
  "The gateway file's tile at full size (its keys, C-k C-m); the same keys bring the tree back."
  (drgnx-look-scene--six-tiles)
  (drgnx-look-scene--answer))

;; the heat layer (X3) and the diff minimap (X6): drawn by the glue once Nidhogg's 13-N/17-N and hunk-labels steps
;; are on the pin; until then the bars draw by class and the scene checks only that the hub sent the layer

(defvar drgnx-minimap-layer)

(defun drgnx-look-scene--minimap-hold (w)
  "WINDOW W's minimap held open for the shot (as `drgnx-look-scene--minimap-open')."
  (set-window-parameter w 'drgnx-look-scene-minimap-open t)
  (advice-add 'drgnx-minimap--spec :around #'drgnx-look-scene--minimap-held)
  (set-window-parameter w 'glitnir-minimap (drgnx-minimap--spec w))
  (drgnx-look-scene--settle-frame))

(defun drgnx-look-scene-minimap-heat ()
  "minimap-layers.html's heat layer: blame age over a Rust file whose first half was committed a year before its
second half, the minimap held open, dark."
  (drgnx-look-scene--theme 'drgnx-dark)
  (drgnx-look-scene--editor)
  (drgnx-look-scene--try "minimap-heat"
    (drgnx-look-scene--hub)
    (let* ((rel "runtime/src/heat.rs") (f (expand-file-name rel drgnx-look-scene--project))
           (text (drgnx-look-scene--parser-rs)) (half (/ (length text) 2)))
      (unless (file-exists-p f)
        (make-directory (file-name-directory f) t)
        (pcase-dolist (`(,upto ,date) `((,(string-search "\n" text half) "2025-06-01T12:00:00")
                                        (,(length text) "2026-06-01T12:00:00")))
          (write-region (substring text 0 upto) nil f nil 'silent)
          (let ((process-environment (append (list (concat "GIT_AUTHOR_DATE=" date) (concat "GIT_COMMITTER_DATE=" date))
                                             process-environment)))
            (drgnx-look-scene--git drgnx-look-scene--project "add" rel)
            (drgnx-look-scene--git drgnx-look-scene--project "commit" "-q" "-m" (format "heat.rs to %s" date)))))
      (setq drgnx-minimap-layer 'blame)
      (drgnx-look-scene--goto rel 812 4 800)
      (let* ((w (selected-window)) (file (drgnx-minimap--file (window-buffer w))))
        (drgnx-ruler--place w)
        (unless (drgnx-look-scene--until 20 "minimap heat"
                                         (lambda () (and file (nidhogg-view-minimap 'get file "heat:blame"))))
          (push (format "minimap-heat: no heat:blame layer for %s" file) drgnx-look-scene--errors))
        (drgnx-look-scene--minimap-hold w))))
  (drgnx-look-scene--answer))

(defun drgnx-look-scene-minimap-diff ()
  "minimap-layers.html's diff minimap: the project's uncommitted changes as a diff buffer (no file), each hunk
labelled, the minimap held open, dark."
  (drgnx-look-scene--theme 'drgnx-dark)
  (drgnx-look-scene--editor)
  (drgnx-look-scene--try "minimap-diff"
    (let ((b (get-buffer-create "*vc-diff*")))
      (with-current-buffer b
        (let ((inhibit-read-only t) (default-directory drgnx-look-scene--project))
          (erase-buffer)
          (call-process "git" nil t nil "diff" "HEAD")
          (diff-mode)
          (goto-char (point-min))))
      (switch-to-buffer b)
      (let ((w (selected-window)))
        (drgnx-ruler--place w)
        (unless (length> (plist-get (drgnx-minimap--spec w) :hunk-labels) 0)
          (push "minimap-diff: no hunk labels in the spec" drgnx-look-scene--errors))
        (drgnx-look-scene--minimap-hold w))))
  (drgnx-look-scene--answer))

(provide 'drgnx-look-scenes-session)
;;; drgnx-look-scenes-session.el ends here
