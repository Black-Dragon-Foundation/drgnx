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

(defconst drgnx-test-env-ambient-variables
  '("SSH_AUTH_SOCK" "SSH_AGENT_PID" "GPG_AGENT_INFO" "XAUTHORITY" "XDG_DATA_DIRS" "XDG_CONFIG_DIRS"
    "GIT_CONFIG_GLOBAL" "GIT_CONFIG_SYSTEM" "GIT_SSH" "GIT_SSH_COMMAND" "EMACSLOADPATH"
    "CLAUDE_CODE_EXECPATH" "CLAUDE_CODE_MESSAGING_SOCKET" "CLAUDE_CODE_MESSAGING_TOKEN")
  "Variables of the caller's login session that reach its agents, keys, display authority or Emacs: a test sees none.
XAUTHORITY is the caller's; a GUI tier gets the harness compositor's own (from `:display').  The system data and
configuration directories fall back to /usr/share and /etc/xdg when unset.")

(defconst drgnx-test-env-scan-exempt '("HOME" "PATH" "PWD" "OLDPWD" "DRGNX_USER_ELPA" "DRGNX_RATATOSKR_BIN" "DRGNX_HUGINN_DUMP")
  "Variables that may hold a path under the real HOME: the tools on PATH, the working directory, the read-only
package directory (`DRGNX_USER_ELPA', deliberate: tests that load packages read it, never write it), the
Ratatoskr the client's tests run (`DRGNX_RATATOSKR_BIN': macOS CI builds it in the checkout, which is under HOME)
and huginn's dump example (`DRGNX_HUGINN_DUMP': the differential test runs it).")

(defconst drgnx-test-env-set-variables
  '("HOME" "XDG_CONFIG_HOME" "XDG_DATA_HOME" "XDG_STATE_HOME" "XDG_CACHE_HOME" "XDG_RUNTIME_DIR" "DRGNX_CONFIG_DIR"
    "DRGNX_DATA_DIR" "TMPDIR" "GNUPGHOME" "DBUS_SESSION_BUS_ADDRESS" "DRGNX_EMACS")
  "Variables `drgnx-test-env' sets to something in the run: the scan of the caller's environment leaves them alone.")

(defun drgnx-test-env--under-home (env)
  "The names of the variables in ENV (a list like `process-environment') whose value holds a path under the real
HOME, other than `drgnx-test-env-scan-exempt'."
  (let* ((home (getenv "HOME"))
         (re (and home (not (string-empty-p home)) (not (equal home "/"))
                  (concat "\\(?:\\`\\|[:, ]\\)" (regexp-quote (directory-file-name home)) "\\(?:/\\|:\\|\\'\\)")))
         names)
    (when re
      (dolist (e env)
        (when (string-match "\\`\\([^=]+\\)=\\(.*\\)\\'" e)
          (let ((name (match-string 1 e)))
            (when (and (string-match-p re (match-string 2 e)) (not (member name drgnx-test-env-scan-exempt)))
              (cl-pushnew name names :test #'equal))))))
    names))

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
session bus, no provider key, DRGNX_TEST_ISOLATED, no durable hub, DRGNX_EMACS naming this Emacs.  The desktop variables are unset, except in a GUI
tier, which gets DISPLAY, the \"K=V\" strings of the harness compositor's display.  CONFIG: an external configuration
directory whose code directories (`drgnx-test-env-config-links') are linked into RUN/config.
Also unset: `drgnx-test-env-ambient-variables' (SSH agent, X authority, git configuration, agent sockets …) and any
other variable of the caller holding a path under the real HOME (`drgnx-test-env--under-home'); GNUPGHOME is RUN/gnupg."
  (unless (memq tier drgnx-test-env-tiers) (error "Unknown test tier %S" tier))
  (let* ((run (directory-file-name (expand-file-name run)))
         (gui (memq tier drgnx-test-env-gui-tiers))
         (shown (and gui (mapcar (lambda (kv) (car (split-string kv "="))) display)))
         (scanned (drgnx-test-env--under-home process-environment)))
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
            ;; the Emacs a test's bin/drgnx or child runs is this one: never PATH's, a record in the real HOME, or
            ;; none (the scan below would drop a caller's DRGNX_EMACS under HOME: macOS CI's Nidhogg.app is there)
            (list (concat "DRGNX_EMACS=" (expand-file-name invocation-name invocation-directory)))
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
            ;; no agent, key, authority or load path of the caller; a private GnuPG home (gpg wants mode 700)
            (cl-remove-if (lambda (v) (or (member v shown) (member v drgnx-test-env-set-variables)))
                          (append drgnx-test-env-ambient-variables scanned))
            (list (concat "GNUPGHOME=" (drgnx-test-env--private-dir (expand-file-name "gnupg" run))))
            (and gui display))))

(defun drgnx-test-env-outer ()
  "What a parent sets in a child's C environment before Emacs starts (dbus.el reads that one, not the Lisp
variable): the dead session bus and the desktop variables unset."
  (cons (concat "DBUS_SESSION_BUS_ADDRESS=" drgnx-test-env-dead-bus) (copy-sequence drgnx-test-env-desktop-variables)))

(provide 'drgnx-test-env)
;;; drgnx-test-env.el ends here
