;;; drgnx-test-env.el --- the one environment every test tier runs in -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A test never sees the user's HOME, XDG directories, session bus, display, compositor, provider keys or agent
;; homes.  `drgnx-test-env' builds the strings for `process-environment' that make it so, for every tier; the unit
;; runner (run-ert.el), `drgnx check' and `drgnx test --ui' all use it, so there is one list and no copy to drift
;; (docs/develop/harness.md, "One test environment").  No dependency beyond cl-lib: dbus.el reads the C environment
;; of the process, so a parent also needs `drgnx-test-env-outer' before the child Emacs starts.

;;; Code:
(require 'cl-lib)

(defconst drgnx-test-env-dead-bus "unix:path=/nonexistent/drgnx-unit-test"
  "The session bus address a test sees: no listener, so nothing reaches the user's desktop.")

(defconst drgnx-test-env-desktop-variables
  '("DISPLAY" "WAYLAND_DISPLAY" "SWAYSOCK" "I3SOCK" "HYPRLAND_INSTANCE_SIGNATURE" "NIRI_SOCKET")
  "Variables that point a program at the user's display or compositor.")

(defconst drgnx-test-env-provider-variables
  '("OPENROUTER_API_KEY" "ANTHROPIC_API_KEY" "ANTHROPIC_AUTH_TOKEN" "OPENAI_API_KEY"
    "MOONSHOT_API_KEY" "DEEPSEEK_API_KEY" "GEMINI_API_KEY" "GOOGLE_API_KEY" "OPENAI_BASE_URL"
    "ANTHROPIC_BASE_URL" "ANTHROPIC_MODEL" "ANTHROPIC_SMALL_FAST_MODEL"
    "ANTHROPIC_DEFAULT_HAIKU_MODEL" "ANTHROPIC_DEFAULT_SONNET_MODEL" "ANTHROPIC_DEFAULT_OPUS_MODEL"
    "ANTHROPIC_DEFAULT_FABLE_MODEL" "CLAUDE_CODE_SUBAGENT_MODEL" "CLAUDE_CODE_OAUTH_TOKEN"
    "CLAUDE_CODE_USE_BEDROCK" "CLAUDE_CODE_USE_VERTEX"
    "CLAUDE_CONFIG_DIR" "CODEX_HOME" "KIMI_CODE_HOME")
  "Provider keys and agent homes: a test may not reach a paid model or the user's real agent settings.")

(defconst drgnx-test-env-config-links '("extras" "lisp" "site-lisp" "tree-sitter" "snippets" "themes")
  "Code directories of an external configuration, linked into the run's configuration directory.")

(defconst drgnx-test-env-tiers '(unit live ui scenario bench perf) "The test tiers.")

(defconst drgnx-test-env-gui-tiers '(ui scenario bench perf) "The tiers that run in a harness display.")

(defun drgnx-test-env--private-dir (dir)
  "Make DIR (mode 700) and return it."
  (make-directory dir t)
  (set-file-modes dir #o700)
  dir)

(cl-defun drgnx-test-env (tier run &key display config)
  "The environment of a TIER test run whose private directory is RUN: a list for `process-environment'.
Entries \"K=V\" set, a bare \"K\" unsets.  TIER is one of `drgnx-test-env-tiers'.  Every tier: HOME, the XDG
directories, DRGNX_CONFIG_DIR, DRGNX_DATA_DIR and TMPDIR under RUN, a private XDG_RUNTIME_DIR (RUN/run), a dead
session bus, no provider key, DRGNX_TEST_ISOLATED, no durable hub.  The desktop variables are unset, except in a GUI
tier, which gets DISPLAY, the \"K=V\" strings of the harness compositor's display.  CONFIG: an external configuration
directory whose code directories (`drgnx-test-env-config-links') are linked into RUN/config."
  (unless (memq tier drgnx-test-env-tiers) (error "Unknown test tier %S" tier))
  (let* ((run (directory-file-name (expand-file-name run)))
         (gui (memq tier drgnx-test-env-gui-tiers))
         (shown (and gui (mapcar (lambda (kv) (car (split-string kv "="))) display))))
    (when config
      (let ((dest (expand-file-name "config" run)))
        (make-directory dest t)
        (dolist (n drgnx-test-env-config-links)
          (let ((src (expand-file-name n config)) (link (expand-file-name n dest)))
            (when (and (file-exists-p src) (not (file-exists-p link)))
              (make-symbolic-link src link))))))
    (append (mapcar (lambda (v) (format "%s=%s" (car v) (expand-file-name (cdr v) run)))
                    '(("DRGNX_CONFIG_DIR" . "config") ("DRGNX_DATA_DIR" . "data")
                      ("XDG_STATE_HOME" . "state") ("XDG_CACHE_HOME" . "cache") ("HOME" . "home")
                      ;; a test that unsets DRGNX_CONFIG_DIR or DRGNX_DATA_DIR lands in these, never in
                      ;; ~/.config/drgnx or ~/.local/share/drgnx
                      ("XDG_CONFIG_HOME" . "xdg-config") ("XDG_DATA_HOME" . "xdg-data")
                      ("TMPDIR" . ".")))
            (list "DRGNX_TEST_ISOLATED=1")
            ;; no durable hub that would outlive the run (the hub's own tests unset this) …
            (list "DRGNX_NO_HUB_START=1")
            ;; … and a hub one starts anyway ends with this Emacs (an interrupted run leaves none)
            (list (format "DRGNX_HUB_PARENT_PID=%d" (emacs-pid)))
            drgnx-test-env-provider-variables
            ;; the harness keeps its sessions under XDG_STATE_HOME unless this says otherwise: not the caller's
            (list "DRGNX_UI_STATE")
            (list (concat "DBUS_SESSION_BUS_ADDRESS=" drgnx-test-env-dead-bus)
                  (concat "XDG_RUNTIME_DIR=" (drgnx-test-env--private-dir (expand-file-name "run" run))))
            (cl-remove-if (lambda (v) (member v shown)) drgnx-test-env-desktop-variables)
            (and gui display))))

(defun drgnx-test-env-outer ()
  "What a parent sets in a child's C environment before Emacs starts (dbus.el reads that one, not the Lisp
variable): the dead session bus and the desktop variables unset."
  (cons (concat "DBUS_SESSION_BUS_ADDRESS=" drgnx-test-env-dead-bus) (copy-sequence drgnx-test-env-desktop-variables)))

(provide 'drgnx-test-env)
;;; drgnx-test-env.el ends here
