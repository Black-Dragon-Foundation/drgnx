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
    (setq head (seq-take head 200))
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
                 "no `1 needs you' or `2 agents' chips: the mock agent's turn does not run yet (look step 8)"
                 "no agent badges (C, R) in the Explorer: agent system part 3 (G9)"
                 "drgnx-job.el is not a preview (italic) tab: only transient buffers preview"
                 "the status bar has no `1 job', `● Claude editing' or `● 1 needs you': no job or agent turn runs yet (look step 8)"
                 "the status bar's problems are Flymake's real ones for the file (the mockup's `✕ 1' is made up), and
no `● eglot': the session runs no language server")
    (agent-panel "the mockup is the Work space (mission strip, Board, Timeline: G9, other plans); compare its right-hand panel"
                 "the panel opens as a tab of the editor group, not the right island (look step 8)"
                 "the mock agent's panel shows no turn yet (replay idle): look step 8")
    (magit "the scene's repository is the window mockups' (main, nothing staged, one commit); the Magit mockup's
branch gateway-queue, staged file and history come with the Magit adapter (look step 7)"
           "the mockup's right-hand org card and floating transient are not opened by the scene")
    (palette "the mockup's palette rows come from its own commands; the line lists the registry's"))
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
  "The step's JSON answer: its errors and MORE, then the echo area cleared."
  (prog1 (drgnx-uitest--json (append (list :errors (vconcat (nreverse drgnx-look-scene--errors))) more))
    (setq drgnx-look-scene--errors nil)
    (message nil)))

(defun drgnx-look-scene--theme (theme)
  (drgnx-look-scene--try "theme"
    (mapc #'disable-theme custom-enabled-themes)
    (load-theme theme t)))

(defun drgnx-look-scene--packages (elpa)
  "Activate the packages in ELPA, as the user's install has them (a session has none of its own)."
  (when (and elpa (file-directory-p elpa))
    (drgnx-look-scene--try "packages"
      (require 'package)
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
  (forward-line (- line start)) (move-to-column column))

(defun drgnx-look-scene-setup (elpa)
  "The mockups' state: the project at ~/code/drgnx, trusted; ELPA's packages active; tabs drgnx-gateway.el,
gateway-test.el (changed, not saved), drgnx-job.el and Magit; the Explorer; drgnx-gateway.el at 216:34, from 201."
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
    (drgnx-look-scene--open "core/drgnx-job.el"))
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
          (concat "tool:read src/main.el\\nsay Reading the gateway: replies to a closed client are lost.\\n"
                  "tool:exec echo 1 of 14 failed\\nsay 1 of 14 failed: gateway/reply-after-close.\\n"
                  "tool:edit src/main.el\\nsay Queue the reply when the client went away.\\n"
                  "tool:exec echo 9 of 14 passed\\n"
                  "ask:permission execute\nsay done")))
      (setq drgnx-look-scene--panel (drgnx-panel-replay-up bin))))
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
      ;; where the line puts it today: a tab of the editor (the limit says so)
      (drgnx-wb-focus-editor)
      (drgnx-look-scene--show drgnx-look-scene--panel)))
  (drgnx-look-scene--answer))

(defun drgnx-look-scene-palette ()
  "The editor focused; the session's own keys open the palette (`drgnx ui look-scenes' types them)."
  (drgnx-look-scene--theme 'drgnx-dark)
  (drgnx-look-scene--editor)
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
  (drgnx-look-scene--try "work space" (drgnx-work-space-open))
  (drgnx-look-scene--answer))

(defun drgnx-look-scene-facts (file &optional scene)
  "Write what SCENE realised to FILE: what the line cannot show yet (`drgnx-look-scene-limits'), themes, fonts of the
chrome faces, frame metrics, windows, modules."
  (drgnx-look-scene--try "facts"
    (let* ((f (selected-frame)) (print-length nil) (print-level nil))
      (with-temp-file file
        (pp (list :limits (cdr (assq scene drgnx-look-scene-limits))
                  :themes custom-enabled-themes
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
                                                     :mode (buffer-local-value 'major-mode (window-buffer w))))
                                   (window-list f 'no-mini))
                  :children (cl-count-if (lambda (c) (and (frame-visible-p c) (frame-parent c))) (frame-list))
                  :modules (ignore-errors (mapcar (lambda (r) (list (car r) (plist-get (cdr r) :status)))
                                                  (drgnx-modules-report))))
            (current-buffer)))))
  (drgnx-look-scene--answer))

(provide 'drgnx-look-scenes-session)
;;; drgnx-look-scenes-session.el ends here
