;;; lint-echo-test.el --- lint: drgnx's own messages on automatic paths only fall -*- lexical-binding: t -*-
;; A `message' that is the direct reply to a command just run stays a message.  Anything else that drgnx says on its
;; own (a filter, sentinel, timer or hook) is a notice (docs/develop/core.md "Notices"), so the user sees it in the
;; Notices list and, when it matters, once in the echo area.  This lint counts `(message "drgnx' in `core/', `wb/' and `modules/'
;; against `drgnx-lint-echo--counts'.  What is left there is one of: a command's reply, a line of a process that has
;; no notice model of its own (the hub, the sandbox relay and proxy, the MCP bridge, batch entry points), a last
;; resort for the notice model itself (the recorder could not record), or a fallback for code that runs before the
;; model loads.  A site that becomes a notice lowers its file's count; a new message cannot raise one.
(require 'ert)
(require 'subr-x)
(require 'drgnx-paths)

(defconst drgnx-lint-echo--counts
  '(;; replies to a command just run (the user invoked it)
    ("core/drgnx-config.el" . 4)        ; 2 replies, the recorder's fallback, the line before the model loads
    ("core/drgnx-macos.el" . 2)         ; install-app and its CLI
    ("core/drgnx-modules.el" . 1)       ; say-problems after turning modules on or off
    ("core/drgnx-session.el" . 2)       ; the quit questions
    ("core/drgnx-shell-env.el" . 2)     ; Reload Shell Environment
    ("core/drgnx-agents.el" . 2)        ; starting an agent: the old adapter, no hub (said once, at the command)
    ("core/drgnx.el" . 1)               ; safe mode's banner, asked for on the command line
    ;; the recorder or the model could not record: nowhere else to say it
    ("core/drgnx-guard.el" . 1)
    ("core/drgnx-hooks.el" . 1)
    ("core/drgnx-keys.el" . 1)
    ("core/drgnx-notice.el" . 2)
    ("core/drgnx-notice-save.el" . 1)
    ("core/drgnx-settings-apply.el" . 1) ; settings.el's problems when the notice itself failed
    ("core/drgnx-settings-workspace.el" . 1) ; a workspace file's problems when the notice itself failed
    ("core/drgnx-timer.el" . 1)
    ("core/drgnx-tty-fallback.el" . 1)
    ;; processes with no notice model of their own: the hub, the sandbox plumbing, the MCP bridge, batch entry
    ;; points (their lines are their log; Rust-bound)
    ("core/drgnx-coord.el" . 1)
    ("core/drgnx-hub-client.el" . 2)
    ("core/drgnx-hub.el" . 8)          ; + Gleipnir 13b: the backend's refused connection, two serve-env errors
    ("core/drgnx-mcp-bridge.el" . 1)
    ("core/drgnx-sandbox-mcp.el" . 3)
    ("core/drgnx-sandbox-proxy.el" . 2)
    ("core/drgnx-sandbox-relay.el" . 2)
    ("core/drgnx-search-mcp.el" . 1)
    ("core/drgnx-settings-defaults.el" . 1) ; the batch entry points' settings.el apply (hub, search CLIs, onboard)
    ;; gryphn is dead: no work on or for it
    ("core/drgnx-compat-gryphn.el" . 1)
    ;; modules/: replies to a command just run
    ("modules/tools/drgnx-prs.el" . 1)           ; "fetching pull request #N…" (Show Changes, a progress line)
    ("modules/tools/drgnx-commit-message.el" . 4) ; Generate Commit Message's own answer: progress, no answer, kill ring
    ("modules/tools/drgnx-browser.el" . 7)       ; Test Report / Show Browser: a command's refusals (NT-T21-1: the sentinel ones)
    ("modules/tools/drgnx-cockpit-cards.el" . 8) ; card commands' errors (NT-T21-1: the callbacks among them)
    ("modules/tools/drgnx-cockpit-graph.el" . 1)
    ("modules/tools/drgnx-cockpit-edits.el" . 1)
    ("modules/tools/drgnx-cockpit.el" . 1)
    ("modules/ui/drgnx-statusbar.el" . 1)        ; Show Test Output: no output to show
    ;; modules/: automatic paths still messages, waiting for their module's own source (NT-T21-1)
    ("modules/editor/drgnx-clipboard.el" . 1)
    ("modules/editor/drgnx-evil.el" . 1)
    ("modules/lang/drgnx-markdown.el" . 1)
    ("modules/tools/drgnx-layouts.el" . 2)
    ("modules/tools/drgnx-replace.el" . 3)
    ("modules/ui/drgnx-face.el" . 2)
    ("modules/ui/drgnx-look.el" . 1)
    ("modules/ui/drgnx-start.el" . 1))
  "File (relative to the checkout) → how many `(message \"drgnx' it has.  The count can only fall: lower it in the
change that makes a site a notice.")

(defun drgnx-lint-echo--actual ()
  "The alist FILE → count, over `core/', `wb/' and `modules/' (every group), for the files that have any."
  (let (rows)
    (dolist (f (append (directory-files (expand-file-name "core" drgnx-dir) t "\\.el\\'")
                       (directory-files (expand-file-name "wb" drgnx-dir) t "\\.el\\'")
                       (directory-files-recursively (expand-file-name "modules" drgnx-dir) "\\.el\\'")))
      (with-temp-buffer
        (insert-file-contents f)
        (let ((n 0))
          (while (re-search-forward "(message \"drgnx" nil t) (setq n (1+ n)))
          (when (> n 0) (push (cons (file-relative-name f drgnx-dir) n) rows)))))
    (sort rows (lambda (a b) (string< (car a) (car b))))))

(ert-deftest drgnx-lint/echo-messages-only-fall ()
  (let ((actual (drgnx-lint-echo--actual)) (bad nil))
    (dolist (a actual)
      (let ((allowed (or (cdr (assoc (car a) drgnx-lint-echo--counts)) 0)))
        (when (> (cdr a) allowed)
          (push (format "%s has %d `(message \"drgnx' and may have %d: post a notice (drgnx-notify) instead"
                        (car a) (cdr a) allowed)
                bad))))
    (dolist (c drgnx-lint-echo--counts)
      (let ((n (or (cdr (assoc (car c) actual)) 0)))
        (when (< n (cdr c))
          (push (format "%s has %d and the table says %d: lower it" (car c) n (cdr c)) bad))))
    (should-not bad)))

(provide 'lint-echo-test)
;;; lint-echo-test.el ends here
