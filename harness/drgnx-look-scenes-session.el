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
(declare-function magit-status "magit-status")
(defvar drgnx-panel-replay-prefix)
(defvar package-directory-list)

(defvar drgnx-look-scene--project nil "The scene's project directory (a git repository).")
(defvar drgnx-look-scene--errors nil "The errors of the current step, newest first.")
(defvar drgnx-look-scene--panel nil "The agent panel's buffer, once the mock agent ran.")

(defmacro drgnx-look-scene--try (what &rest body)
  "Run BODY; an error is kept in `drgnx-look-scene--errors' under WHAT, not raised."
  (declare (indent 1))
  `(condition-case err (progn ,@body)
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

(defun drgnx-look-scene-setup (project elpa)
  "PROJECT trusted, three of its files open, the Explorer shown, the editor focused; ELPA's packages active."
  (setq drgnx-look-scene--project (file-name-as-directory project))
  (drgnx-look-scene--packages elpa)
  (drgnx-look-scene--try "trust" (drgnx-trust-folder drgnx-look-scene--project))
  (drgnx-look-scene--try "open"
    (dolist (f '("test/unit/lint-teardown-test.el" "core/drgnx-palette-frame.el" "core/drgnx-palette.el"))
      (find-file (expand-file-name f drgnx-look-scene--project)))
    (goto-char (point-min)) (forward-line 120) (recenter 12))
  (drgnx-look-scene--try "explorer" (drgnx-wb-view-explorer))
  (drgnx-look-scene--try "focus" (drgnx-wb-focus-editor))
  (drgnx-look-scene--answer))

(defun drgnx-look-scene-agent (bin)
  "A mock agent (BIN: a test-hooks ratatoskr with ratatoskr-mock beside it) reads, runs, edits and asks."
  (if (not (and bin (file-executable-p bin)))
      (push "agent: no ratatoskr binary (DRGNX_RATATOSKR_BIN)" drgnx-look-scene--errors)
    (drgnx-look-scene--try "agent"
      (load (expand-file-name "test/fixtures/panel-replay-fixture" (bound-and-true-p drgnx-dir)) nil t)
      (setq drgnx-panel-replay-prefix 3)
      (defalias 'drgnx-panel-replay-program
        (lambda ()
          (concat "tool:read src/main.el\\nsay Reading the gateway: the replies queue is never drained after a close.\\n"
                  "tool:exec git status --short\\nsay Found it: the sentinel never runs the queue.\\n"
                  "tool:edit src/main.el\\nsay Running the tests again.\\ntool:exec echo 9 of 14 passed\\n"
                  "ask:permission execute\nsay done")))
      (setq drgnx-look-scene--panel (drgnx-panel-replay-up bin))))
  (drgnx-look-scene--answer :panel (if (buffer-live-p drgnx-look-scene--panel) (buffer-name drgnx-look-scene--panel) :null)))

(defun drgnx-look-scene--editor ()
  (drgnx-look-scene--try "editor"
    (let ((b (find-buffer-visiting (expand-file-name "core/drgnx-palette.el" drgnx-look-scene--project))))
      (drgnx-wb-focus-editor)
      (when b (switch-to-buffer b)))))

(defun drgnx-look-scene-window-dark ()
  (drgnx-look-scene--theme 'drgnx-dark)
  (drgnx-look-scene--editor)
  (drgnx-look-scene--answer))

(defun drgnx-look-scene-agent-panel ()
  (drgnx-look-scene--theme 'drgnx-dark)
  (drgnx-look-scene--try "panel"
    (if-let* ((w (and (buffer-live-p drgnx-look-scene--panel) (get-buffer-window drgnx-look-scene--panel))))
        (select-window w)
      (error "The agent panel is not in a window")))
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
    (magit-status drgnx-look-scene--project))
  (drgnx-look-scene--answer))

(defun drgnx-look-scene-shell-heredoc ()
  "The user's case: a shell script with a Python heredoc (the package faces of sh-script)."
  (drgnx-look-scene--theme 'drgnx-dark)
  (drgnx-look-scene--try "heredoc"
    (drgnx-wb-focus-editor)
    (find-file (expand-file-name "p2-verify.sh" drgnx-look-scene--project))
    (goto-char (point-max)))
  (drgnx-look-scene--answer))

(defun drgnx-look-scene-work-space-dark ()
  (drgnx-look-scene--theme 'drgnx-dark)
  (drgnx-look-scene--try "work space" (drgnx-work-space-open))
  (drgnx-look-scene--answer))

(defun drgnx-look-scene-facts (file)
  "Write what the scene realised to FILE: themes, fonts of the chrome faces, frame metrics, windows, modules."
  (drgnx-look-scene--try "facts"
    (let* ((f (selected-frame)) (print-length nil) (print-level nil))
      (with-temp-file file
        (pp (list :themes custom-enabled-themes
                  :fonts (mapcar (lambda (fc) (list fc (ignore-errors (face-font fc f))))
                                 '(default drgnx-ui-text drgnx-ui-heading drgnx-ui-caption tab-bar tab-line
                                           mode-line header-line))
                  :frame (list :px (list (frame-pixel-width f) (frame-pixel-height f)) :scale (frame-scale-factor f)
                               :line-px (frame-char-height f) :tab-bar-lines (frame-parameter f 'tab-bar-lines))
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
