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
                 "the status bar has no `1 job' or `● Claude editing': no job or agent edit runs yet; its `1 waiting on you' is
the mockup's `● 1 needs you'"
                 "the status bar's problems are Flymake's real ones for the file (the mockup's `✕ 1' is made up), and
no `● eglot': the session runs no language server")
    (agent-panel "the mockup is the Work space (mission strip, Board, Timeline: G9, other plans); compare its right-hand panel"
                 "the panel opens as a tab of the editor group, not the right island (look step 8)"
                 "the mock agent's panel shows no turn yet (replay idle): look step 8")
    (magit "the scene's repository is the window mockups' (main, nothing staged, one commit); the Magit mockup's
branch gateway-queue, staged file and history come with the Magit adapter (look step 7)"
           "the mockup's right-hand org card and floating transient are not opened by the scene")
    (palette "the mockup's palette rows come from its own commands; the line lists the registry's")
    (explorer-focused-dark "no agent badges (C, R) in the Explorer: agent system part 3 (G9)")
    (explorer-focused-light "no agent badges (C, R) in the Explorer: agent system part 3 (G9)")
    (explorer-focused-hc "no agent badges (C, R) in the Explorer: agent system part 3 (G9)"))
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
          (concat "tool:read src/main.el\\nsay Reading the gateway: replies to a closed client are lost.\\n"
                  "tool:run sleep 11; echo 1 of 14 failed\\nsay 1 of 14 failed: gateway/reply-after-close.\\n"
                  "tool:edit src/main.el\\nsay Queue the reply when the client went away.\\n"
                  "tool:run sleep 2; echo 9 of 14 passed\\n"
                  "ask:tool {\"kind\": \"read\", \"title\": \"Read the gateway's log\"}\nsay done")))
      (setq drgnx-look-scene--panel (drgnx-panel-replay-up bin))
      ;; the turn runs on past the prefix to its ask: the scene shows every step's time and the open card
      (unless (drgnx-panel-replay--wait 30 (lambda () (with-current-buffer drgnx-look-scene--panel
                                                        (drgnx-agent-panel-cards--permissions))))
        (push "agent: no permission card within 30 s" drgnx-look-scene--errors))))
  (drgnx-look-scene--answer :panel (if (buffer-live-p drgnx-look-scene--panel) (buffer-name drgnx-look-scene--panel) :null)))

(defun drgnx-look-scene--editor ()
  (drgnx-look-scene--try "editor"
    (drgnx-wb-focus-editor)
    (drgnx-look-scene--goto "core/drgnx-gateway.el" 216 33 201)))

(defun drgnx-look-scene-window-dark ()
  (drgnx-look-scene--theme 'drgnx-dark)
  (drgnx-look-scene--editor)
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

(defun drgnx-look-scene-work-space-dark ()
  (drgnx-look-scene--theme 'drgnx-dark)
  (drgnx-look-scene--try "work space"
    (let ((map (drgnx-work-space-open)))
      ;; the hub sends the map's rows after it opens and the view draws them on a timer once its window shows: the
      ;; shot waits for the first of them (redisplay and timers run in `sit-for'), not an empty window
      (let ((end (+ (float-time) 15)))
        (while (and (zerop (buffer-size map)) (< (float-time) end))
          (sit-for 0.05)))
      (when (zerop (buffer-size map))
        (push "work space: no map rows within 15 s" drgnx-look-scene--errors))))
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

;;;; The Search view's preview tile and Replace All sheet (search-view.html)

(defvar drgnx-replace-buffer-name)
(defvar drgnx-replace-sheet-buffer-name)
(defvar drgnx-replace--hub-counts)
(defvar drgnx-replace--preview)
(defvar drgnx-replace--sheet)
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

(defun drgnx-look-scene--search ()
  "The mockup's search in the Search view: regexp `(gateway)--pending' replaced by `\\1--queued' in the project, the
match on line 209 (the `puthash' line) unticked; the view's buffer, or nil."
  (drgnx-look-scene--theme 'drgnx-dark)
  (drgnx-look-scene--editor)
  (drgnx-look-scene--try "hub"                 ; the Search view's rows come from the hub
    ;; a session starts no hub (DRGNX_NO_HUB_START): the scene runs the worktree's own ($DRGNX_RATATOSKR_BIN) in the
    ;; foreground, as the perf workloads do, ended with the session
    (unless (drgnx-replace--hub-ready-p)
      (unless (drgnx-hub-running-p)
        (let ((bin (getenv "DRGNX_RATATOSKR_BIN"))
              (process-environment (cons "RATATOSKR_SUPERVISOR=none" process-environment)))
          (unless (and bin (file-executable-p bin)) (error "No ratatoskr binary (DRGNX_RATATOSKR_BIN)"))
          (make-process :name "ratatoskr" :noquery t :connection-type 'pipe
                        :buffer (generate-new-buffer " *ratatoskr*")
                        :command (list bin "serve" "--foreground" "--parent-pid" (number-to-string (emacs-pid))))
          (drgnx-look-scene--until 30 "hub start" #'drgnx-hub-running-p)))
      (drgnx-hub-connect)
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
