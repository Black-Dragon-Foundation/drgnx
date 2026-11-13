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

(declare-function drgnx-uitest--json "drgnx-uitest")
(declare-function drgnx-trust-folder "drgnx-trust")
(declare-function drgnx-wb-view-explorer "drgnx-wb")
(declare-function drgnx-wb-focus-editor "drgnx-wb")
(declare-function drgnx-modules-retry-waiting "drgnx-modules")
(declare-function drgnx-modules-report "drgnx-modules")
(declare-function drgnx-panel-replay-up "panel-replay-fixture")
(declare-function drgnx-work-space-open "drgnx-work-space")
(declare-function drgnx-statusbar-note-tests "drgnx-statusbar")
(declare-function magit-status-setup-buffer "magit-status")
(defvar drgnx-panel-replay-prefix)
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
    (send-run-code-light "the code and the size are the scene's own: the container has no keyring, so no run is recorded to export"))
  "What the line cannot show of each scene's mockup yet, written to the scene's facts (:limits).  A scene is never
changed to hide a gap: the gap is named here instead.")

(defun drgnx-look-scene--no-prompt (&rest args)
  "A prompt in a scene's setup is an error naming it (ARGS: the prompt's), not a session waiting for an answer."
  (error "Prompted: %S" (substring-no-properties (format "%s" (car args)))))

(defmacro drgnx-look-scene--try (what &rest body)
  "Run BODY; an error, a prompt included, is kept in `drgnx-look-scene--errors' under WHAT, not raised."
  (declare (indent 1))
  `(condition-case err
       (cl-letf (((symbol-function 'yes-or-no-p) #'drgnx-look-scene--no-prompt)
                 ((symbol-function 'y-or-n-p) #'drgnx-look-scene--no-prompt)
                 ((symbol-function 'read-from-minibuffer) #'drgnx-look-scene--no-prompt)
                 ((symbol-function 'completing-read) #'drgnx-look-scene--no-prompt)
                 ((symbol-function 'read-char-choice) #'drgnx-look-scene--no-prompt)
                 ((symbol-function 'read-key) #'drgnx-look-scene--no-prompt))
         ,@body)
     (error (push (format "%s: %s" ,what (error-message-string err)) drgnx-look-scene--errors) nil)))

(defun drgnx-look-scene--answer (&rest more)
  "The step's JSON answer: its errors and MORE, then the echo area cleared, and the status bar's message with it (a
message there lasts some seconds, so the previous scene's last one, its palette's \"Quit\", would show in this one's)."
  (prog1 (drgnx-uitest--json (append (list :errors (vconcat (nreverse drgnx-look-scene--errors))) more))
    (setq drgnx-look-scene--errors nil)
    (message nil)
    (when (fboundp 'drgnx-look-echo--status-clear) (drgnx-look-echo--status-clear))))

(defun drgnx-look-scene--theme (theme)
  (drgnx-look-scene--try "theme"
    (mapc #'disable-theme custom-enabled-themes)
    (load-theme theme t)
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

(defun drgnx-look-scene-setup (elpa)
  "The mockups' state: the project at ~/code/drgnx, trusted; ELPA's packages active; tabs drgnx-gateway.el,
gateway-test.el (changed, not saved), drgnx-job.el (a preview) and Magit; the Explorer; drgnx-gateway.el at 216:34,
from 201."
  (drgnx-look-scene--packages elpa)
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
  (drgnx-look-scene--answer :project drgnx-look-scene--project))

(defun drgnx-look-scene-agent (bin)
  "A mock agent (BIN: a test-hooks ratatoskr with ratatoskr-mock beside it) reads, runs, edits and asks."
  (if (not (and bin (file-executable-p bin)))
      (push "agent: no ratatoskr binary (DRGNX_RATATOSKR_BIN)" drgnx-look-scene--errors)
    (drgnx-look-scene--try "agent"
      (load (expand-file-name "test/fixtures/panel-replay-fixture" (bound-and-true-p drgnx-dir)) nil t)
      (setq drgnx-panel-replay-prefix 3)
      (defalias 'drgnx-panel-replay-program
        (lambda ()
          ;; the mockup's figures: a slow run (past `drgnx-agent-panel-slow-seconds'), a quick one, then a read
          ;; that asks and stays open, so the permission card shows.  The replay session is a chat: the matrix
          ;; answers a chat's edit or run Never (no card), and asks for its reads
          (concat "tool:read core/drgnx-gateway.el\\nsay Reading the gateway: replies to a closed client are lost.\\n"
                  "tool:run sleep 11; echo 1 of 14 failed\\nsay 1 of 14 failed: gateway/reply-after-close.\\n"
                  "tool:edit test/unit/gateway-test.el\\nsay Queue the reply when the client went away.\\n"
                  "tool:run sleep 2; echo 9 of 14 passed\\n"
                  "ask:tool {\"kind\": \"read\", \"title\": \"Read the gateway's log\"}\nsay done")))
      ;; the replay's hub is the scenes' hub from here on: it seeds the plan run as `drgnx-look-scene--hub' does
      ;; and the agent works in the scenes' project, so the status bar and the Explorer show it there
      (setq drgnx-look-scene--panel (let ((process-environment (cons "RATATOSKR_SEED_SCENE=1" process-environment))
                                          (drgnx-panel-replay-project drgnx-look-scene--project))
                                      (drgnx-panel-replay-up bin)))
      ;; the turn runs on past the prefix to its ask: the scene shows every step's time and the open card
      (unless (drgnx-panel-replay--wait 30 (lambda () (with-current-buffer drgnx-look-scene--panel
                                                        (drgnx-agent-panel-cards--permissions))))
        (push "agent: no permission card within 30 s" drgnx-look-scene--errors))))
  (drgnx-look-scene--answer :panel (if (buffer-live-p drgnx-look-scene--panel) (buffer-name drgnx-look-scene--panel) :null)))

(defun drgnx-look-scene--editor ()
  "The editor on the gateway file, with the Explorer's Files section drawn: its rows come from the hub, so the scenes'
hub is started first and the shot waits for them (a session starts no hub: without one the section is empty)."
  (drgnx-look-scene--try "hub" (drgnx-look-scene--hub))
  (drgnx-look-scene--try "editor"
    (drgnx-wb-focus-editor)
    (drgnx-look-scene--goto "core/drgnx-gateway.el" 216 33 201))
  (drgnx-look-scene--until 20 "explorer files rows"
                           (lambda () (when-let* ((b (get-buffer drgnx-explorer-buffer-name)))
                                        (with-current-buffer b
                                          (save-excursion (goto-char (point-min)) (search-forward "Makefile" nil t)))))))

(declare-function drgnx-hub-call "drgnx-hub-client")
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

(defun drgnx-look-scene--eglot ()
  "The current buffer managed by a stand-in eglot (window-dark.html's `● eglot'): its server a JSON-RPC connection to
`cat', no language server, so the status bar's `lsp' segment draws it by its own code."
  (require 'eglot)
  (setq-local eglot--managed-mode t
              eglot--cached-server
              (make-instance 'jsonrpc-process-connection :name "eglot"
                             :process (make-process :name "look-scene-lsp" :command '("cat") :noquery t
                                                    :connection-type 'pipe)))
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
                    (lambda (r e) (unless e (funcall 'drgnx-jobs-note-jobs (append (plist-get r :jobs) nil)))))
    (drgnx-look-scene--until 15 "the status bar's job (the seeded run)" (lambda () (eql drgnx-jobs--running 1))))
  (drgnx-look-scene--answer))

(defun drgnx-look-scene-agent-panel ()
  (drgnx-look-scene--theme 'drgnx-dark)
  (drgnx-look-scene--try "panel"
    (unless (buffer-live-p drgnx-look-scene--panel) (error "No agent panel (the mock agent did not run)"))
    (if-let* ((w (get-buffer-window drgnx-look-scene--panel)))
        (select-window w)
      ;; an earlier scene put the editor back: the panel opens again where opening it puts it, the right island
      (drgnx-pane-show 'agent-panel :buffer drgnx-look-scene--panel :select t)))
  (drgnx-look-scene--answer))

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

(defun drgnx-look-scene-work-space-dark ()
  (drgnx-look-scene--theme 'drgnx-dark)
  (drgnx-look-scene--try "work space" (drgnx-look-scene--work-map))
  (drgnx-look-scene--answer))

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
session, with one plan run seeded into its fresh store (RATATOSKR_SEED_SCENE, the hub's `orch::scene') for the Work
space's scenes."
  (unless (drgnx-hub-running-p)
    (let ((bin (getenv "DRGNX_RATATOSKR_BIN"))
          (process-environment (append '("RATATOSKR_SUPERVISOR=none" "RATATOSKR_SEED_SCENE=1") process-environment)))
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
  (unless (drgnx-hub-running-p)
    (drgnx-look-scene--try "profile"
      (drgnx-settings-file-put (expand-file-name "settings.el" (drgnx-user-dir)) 'drgnx-settings nil
                               'drgnx-agents-profiles
                               `(("mock-claude" :provider claude
                                  :command (,(expand-file-name "ratatoskr-mock"
                                                               (file-name-directory (getenv "DRGNX_RATATOSKR_BIN")))
                                            "acp" "--as" "claude"))))))
  (when-let* ((view (drgnx-look-scene--search)))
    (drgnx-look-scene--try "hand off"
      (with-current-buffer view
        (let ((ids (seq-take (drgnx-look-scene--row-ids "m:") 4)))
          (drgnx-hub--call-on drgnx-hub--events "search/handoff"
                              (list :view drgnx-replace-view :instruction "Rename it." :ids (vconcat ids)
                                    :to '(:pair (:profile "mock-claude"))
                                    :mark '(:face "drgnx-agent-2" :glyph "◆" :name "Ada"))
                              (lambda (_ err) (when err (push (format "hand off: %S" err) drgnx-look-scene--errors))))))
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

(defun drgnx-look-scene-start-page ()
  "The start page in the editor, dark (no mockup: its buttons, keycaps and shield are the components of design §3.5)."
  (drgnx-look-scene--theme 'drgnx-dark)
  (drgnx-look-scene--try "start page"
    (drgnx-wb-focus-editor)
    (drgnx-start-show))
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
                                      :view (bound-and-true-p drgnx-work-space--view)
                                      :message (bound-and-true-p drgnx-work-space--message))))
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

(provide 'drgnx-look-scenes-session)
;;; drgnx-look-scenes-session.el ends here
