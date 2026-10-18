;;; editor-m11c2-test.el --- GUI tests: agent settings pages, MCP Test, Open Remote and Reconnect (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; One walk through M11c-2's surfaces on a graphical frame, a screenshot of each (their paths are printed).  Every agent
;; home is a temp directory (test/fixtures/agent-config-fixture.el); the MCP servers are test/fixtures/mock-mcp.el in
;; a batch Emacs.  Open Remote goes into a podman container the test starts and removes (no podman: that part is
;; not shown); nothing of the user's is read or written.
(require 'ert)
(require 'cl-lib)
(require 'tramp)
(require 'drgnx-uitest)

(defconst drgnx-m11c2-ui-test--repo                         ; the session runs the repository's test/ui
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(add-to-list 'load-path (expand-file-name "core" drgnx-m11c2-ui-test--repo))
(add-to-list 'load-path (expand-file-name "wb" drgnx-m11c2-ui-test--repo))
(require 'drgnx)
(require 'drgnx-wb)
(require 'drgnx-area)
(require 'drgnx-rules)
(require 'drgnx-agents)
(require 'drgnx-explorer)
(require 'drgnx-session)
(load (expand-file-name "test/fixtures/agent-config-fixture" drgnx-m11c2-ui-test--repo) nil t)
(load (expand-file-name "test/fixtures/mock-mcp" drgnx-m11c2-ui-test--repo) nil t)
(dolist (m '("tools/drgnx-agents-ui" "tools/drgnx-agent-settings" "lang/drgnx-lang" "tools/drgnx-remote"))
  (load (expand-file-name (concat "modules/" m) drgnx-m11c2-ui-test--repo) nil t))

(defconst drgnx-m11c2-ui-test--secret "s3cr3t-env-value-0123456789"
  "The fixture's environment value: it must never reach the page.")

(defun drgnx-m11c2-ui-test--wait (pred &optional secs)
  "Wait (SECS, default 10) until PRED holds, reading process output; PRED's last value."
  (let ((deadline (+ (float-time) (or secs 10))))
    (while (and (not (funcall pred)) (< (float-time) deadline)) (accept-process-output nil 0.05)))
  (funcall pred))

(defun drgnx-m11c2-ui-test--shot (dir name)
  "Capture the root frame into DIR and keep it as NAME in the session's temp dir; print where."
  (let ((shot (plist-get (drgnx-uitest-capture dir) :root)) (out (expand-file-name name temporary-file-directory)))
    (should (file-exists-p shot))
    (copy-file shot out t)
    (message "m11c-2 screenshot: %s" out)
    out))

(defun drgnx-m11c2-ui-test--write (file text)
  (make-directory (file-name-directory file) t)
  (write-region text nil file nil 'silent))

(defun drgnx-m11c2-ui-test--mock (mode marker)
  "An MCP server entry (a JSON object as text) that runs the mock in MODE, MARKER on its command line."
  (json-serialize
   (list :type "stdio"
         :command (expand-file-name invocation-name invocation-directory)
         :args (vector "--batch" "-Q" "-l" (expand-file-name "test/fixtures/mock-mcp.el" drgnx-m11c2-ui-test--repo)
                       "-f" "drgnx-mock-mcp-main" mode marker))))

(defun drgnx-m11c2-ui-test--claude-files (root)
  "Claude Code's fixture under the temp agent homes: user servers (one with a secret env value, two mocks), a project
server, a hook, a skill, a rules file, and a settings.json env that overrides the profiles' route."
  (let ((home (getenv "CLAUDE_CONFIG_DIR")))
    (drgnx-m11c2-ui-test--write
     (expand-file-name ".claude.json" home)
     (format "{\n  \"mcpServers\": {\n    \"github\": {\"type\": \"stdio\", \"command\": \"drgnx-no-such-command\", \"args\": [\"--stdio\"], \"env\": {\"GITHUB_TOKEN\": \"%s\"}},\n    \"mock-ok\": %s,\n    \"mock-hang\": %s\n  }\n}\n"
             drgnx-m11c2-ui-test--secret
             (drgnx-m11c2-ui-test--mock "ok" "drgnx-m11c2-ok") (drgnx-m11c2-ui-test--mock "hang" "drgnx-m11c2-hang")))
    (drgnx-m11c2-ui-test--write
     (expand-file-name ".mcp.json" root)
     "{\"mcpServers\": {\"docs\": {\"type\": \"http\", \"url\": \"https://example.invalid/mcp\", \"headers\": {\"X-Api\": \"hdr-s3cr3t-9876543210\"}}}}\n")
    (drgnx-m11c2-ui-test--write
     (expand-file-name "settings.json" home)
     "{\n  \"env\": {\"ANTHROPIC_BASE_URL\": \"https://proxy.example.com\"},\n  \"hooks\": {\n    \"PreToolUse\": [\n      {\"matcher\": \"Bash\", \"hooks\": [{\"type\": \"command\", \"command\": \"echo drgnx-hook\"}]}\n    ]\n  }\n}\n")
    (drgnx-m11c2-ui-test--write (expand-file-name "skills/my-skill/SKILL.md" home)
                                "---\nname: my-skill\ndescription: Does one thing well\n---\n\nBody.\n")
    (drgnx-m11c2-ui-test--write (expand-file-name "CLAUDE.md" home) "# rules\n")))

(defun drgnx-m11c2-ui-test--codex-files ()
  "Codex's fixture: two servers and a skill."
  (let ((home (getenv "CODEX_HOME")))
    (drgnx-m11c2-ui-test--write
     (expand-file-name "config.toml" home)
     (format "model = \"gpt-5\"\n\n[mcp_servers.docs]\ncommand = \"drgnx-no-such-command\"\nargs = [\"-y\", \"docs-mcp\"]\nenv = { TOKEN = \"%s\" }\n\n[mcp_servers.remote]\nurl = \"https://example.invalid/mcp\"\n"
             drgnx-m11c2-ui-test--secret))
    (drgnx-m11c2-ui-test--write (expand-file-name "skills/codex-skill/SKILL.md" home)
                                "---\nname: codex-skill\ndescription: A skill for Codex\n---\n\nBody.\n")
    (drgnx-m11c2-ui-test--write (expand-file-name "AGENTS.md" home) "# codex rules\n")))

(defun drgnx-m11c2-ui-test--goto-item (name)
  "Point on the first line of the item NAME on the page."
  (goto-char (point-min))
  (while (not (equal (nth 2 (car (get-text-property (point) 'drgnx-agent-settings-item))) name))
    (when (eobp) (error "No item %s on the page" name))
    (forward-line 1)))

(defun drgnx-m11c2-ui-test--item-line (name)
  (save-excursion (drgnx-m11c2-ui-test--goto-item name)
                  (buffer-substring-no-properties (line-beginning-position) (line-end-position))))

(defun drgnx-m11c2-ui-test--test-item (name)
  "Test the server NAME on the page; wait for the result."
  (drgnx-m11c2-ui-test--goto-item name)
  (drgnx-agent-settings-test)
  (should (drgnx-m11c2-ui-test--wait (lambda () (zerop (hash-table-count drgnx-agent-settings--running))) 30))
  (redisplay t))

(defun drgnx-m11c2-ui-test--show (buffer)
  "BUFFER in the one window of the selected frame, which is selected; the window."
  (let ((win (frame-root-window)))
    (set-window-buffer win buffer)
    (select-window win)
    win))

(defun drgnx-m11c2-ui-test--settings-part (shots)
  "The Claude page, two MCP Tests and the Codex page; SHOTS the screenshot directory."
  (let ((display-buffer-overriding-action '(display-buffer-same-window)) (drgnx-agent-check-timeout 2) (win nil))
    (drgnx-agent-config-test-env
      (let ((drgnx-agents-profiles nil))
        (unwind-protect
            (progn
              (drgnx-m11c2-ui-test--claude-files root)
              (drgnx-m11c2-ui-test--codex-files)
              ;; 1. the Claude page: every section, the env value masked, the route conflict said
              (delete-other-windows)
              (with-current-buffer (drgnx-agent-settings-open 'claude root)
                (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                  (dolist (word '("Routes" "MCP Servers" "Hooks" "Skills" "Rules:" "CLAUDE.md" "Project:"))
                    (should (string-search word text)))
                  (should (string-search "GITHUB_TOKEN=" text))
                  (should-not (string-search drgnx-m11c2-ui-test--secret text))
                  (should-not (string-search "hdr-s3cr3t" text))
                  (should (string-search "overrides every profile's route" text))
                  (should (string-search "ANTHROPIC_BASE_URL" text)))
                (should (string-search "command not found" (drgnx-m11c2-ui-test--item-line "github")))
                (should (string-search "Test (runs the command)" (drgnx-m11c2-ui-test--item-line "PreToolUse Bash")))
                (setq win (drgnx-m11c2-ui-test--show (current-buffer)))
                (goto-char (point-min))
                (redisplay t)
                (drgnx-m11c2-ui-test--shot shots "m11c2-claude-page.png")
                ;; 2. a Test that passes against the mock, and one that times out
                (should (string-search "[Test]" (drgnx-m11c2-ui-test--item-line "mock-ok")))
                (drgnx-m11c2-ui-test--test-item "mock-ok")
                (should (string-search "ok, 2 tools" (drgnx-m11c2-ui-test--item-line "mock-ok")))
                (drgnx-m11c2-ui-test--test-item "mock-hang")
                (should (string-search "timed out" (drgnx-m11c2-ui-test--item-line "mock-hang")))
                (should-not (string-search drgnx-m11c2-ui-test--secret (buffer-substring-no-properties (point-min) (point-max))))
                (drgnx-m11c2-ui-test--goto-item "mock-ok")
                (set-window-point win (point))
                (set-window-start win (save-excursion (forward-line -3) (point)))   ; the servers at the top
                (redisplay t)
                (drgnx-m11c2-ui-test--shot shots "m11c2-mcp-test.png"))
              ;; 3. the Codex page
              (with-current-buffer (drgnx-agent-settings-open 'codex root)
                (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                  (should (equal (buffer-name) "*agent settings: Codex*"))
                  (dolist (word '("Routes" "MCP Servers" "Hooks" "Skills" "AGENTS.md"))
                    (should (string-search word text)))
                  (should-not (string-search drgnx-m11c2-ui-test--secret text)))
                (should (string-search "command not found" (drgnx-m11c2-ui-test--item-line "docs")))
                (drgnx-m11c2-ui-test--show (current-buffer))
                (goto-char (point-min))
                (redisplay t)
                (drgnx-m11c2-ui-test--shot shots "m11c2-codex-page.png")))
          (dolist (b (buffer-list))
            (when (string-prefix-p "*agent settings: " (buffer-name b)) (kill-buffer b)))
          (clrhash drgnx-agent-settings--running)
          (delete-other-windows)
          (switch-to-buffer "*scratch*"))))))

;;;; Open Remote into a container

(defun drgnx-m11c2-ui-test--podman-env ()
  "`process-environment' for podman and for the connection to the container: the user's runtime directory (a
session has a private one of its own, in which podman finds none of its containers) and bus."
  (let* ((run (format "/run/user/%d" (user-uid))) (bus (concat run "/bus")))
    (append (list (concat "XDG_RUNTIME_DIR=" run))
            (and (file-exists-p bus) (list (concat "DBUS_SESSION_BUS_ADDRESS=unix:path=" bus)))
            process-environment)))

(defun drgnx-m11c2-ui-test--podman (&rest args)
  "Run podman with ARGS: (EXIT . OUTPUT)."
  (let ((process-environment (drgnx-m11c2-ui-test--podman-env)) (default-directory temporary-file-directory))
    (with-temp-buffer
      (cons (apply #'call-process "podman" nil t nil args) (string-trim (buffer-string))))))

(defun drgnx-m11c2-ui-test--segment ()
  "The remote segment as the current buffer's window would show it: (TEXT . FACE)."
  (let ((s (drgnx-remote-segment)))
    (cons (get-text-property 0 'help-echo s) (get-text-property 0 'face s))))

(defun drgnx-m11c2-ui-test--remote-part (shots name)
  "Open Remote into the container NAME: the Explorer, the segment connected, the connection killed (lost), Reconnect
(connected, the buffer and its change kept)."
  (let* ((root (format "/podman:%s:/" name)) (file (concat root "tmp/m11c2-demo.txt"))
         (process-environment (drgnx-m11c2-ui-test--podman-env))
         (drgnx-remote--roots nil)
         (drgnx-lang--remote-servers (make-hash-table :test #'equal))
         (drgnx-lang--remote-wanted (make-hash-table :test #'equal))
         (drgnx-lang--remote-hinted nil) (drgnx-lang--remote-pending nil) (drgnx-lang--user-command nil)
         (drgnx-remote-may-prompt nil)
         (drgnx-explorer--roots nil) (drgnx-explorer--cache (make-hash-table :test #'equal))
         (drgnx-explorer--expanded (make-hash-table :test #'equal))
         (global-mode-string global-mode-string))
    (unwind-protect
        (progn
          (drgnx-wb-define-section 'explorer :slot 0 :title " EXPLORER" :buffer #'drgnx-explorer--buffer)
          (drgnx-remote--setup)
          (drgnx-wb-show-sidebar)
          ;; Open Remote… as the user runs it: the choice and the folder are answered, a command is running
          (let ((drgnx-lang--user-command t) (asked nil))
            (cl-letf (((symbol-function 'drgnx-remote-ssh-hosts) (lambda () nil))
                      ((symbol-function 'completing-read)
                       (lambda (_prompt collection &rest _) (setq asked (all-completions "" collection)) (concat "podman: " name)))
                      ((symbol-function 'read-directory-name) (lambda (&rest _) root)))
              (drgnx-remote-open))
            (should (member (concat "podman: " name) asked))
            (write-region "hello from the container\n" nil file)
            (find-file file))
          (setq drgnx-signal--editor-window (selected-window))
          (should (equal (car (drgnx-explorer-roots)) root))                 ; first, before the default folder
          (with-current-buffer drgnx-explorer-buffer-name
            (should (string-search "▸ etc\n" (buffer-string)))
            (should-not (string-search drgnx-explorer--not-listed (buffer-string))))
          ;; the Explorer keeps point on the row it had (the local home): show the new folder's top
          (when-let* ((w (drgnx-wb-section-window 'explorer)))
            (set-window-point w (with-current-buffer drgnx-explorer-buffer-name (point-min)))
            (set-window-start w (with-current-buffer drgnx-explorer-buffer-name (point-min))))
          ;; an unsaved change that Reconnect must keep
          (let ((buffer (current-buffer)))
            (goto-char (point-max)) (insert "unsaved change\n") (goto-char (+ (point-min) 6))
            (let ((point (point)))
              ;; connected
              (let ((seg (drgnx-m11c2-ui-test--segment)))
                (should (string-search "connected" (car seg)))
                (should (eq (cdr seg) 'drgnx-remote-connected)))
              (force-mode-line-update t) (redisplay t)
              (drgnx-m11c2-ui-test--shot shots "m11c2-remote-connected.png")
              ;; the connection process killed: the segment says lost, nothing is sent to find out
              (let ((proc (tramp-get-connection-process (tramp-dissect-file-name root))))
                (kill-process proc)
                (should (drgnx-m11c2-ui-test--wait (lambda () (not (process-live-p proc))))))
              (let ((seg (drgnx-m11c2-ui-test--segment)))
                (should (string-search "connection lost" (car seg)))
                (should (eq (cdr seg) 'drgnx-remote-lost)))
              (force-mode-line-update t) (redisplay t)
              (drgnx-m11c2-ui-test--shot shots "m11c2-remote-lost.png")
              ;; Reconnect
              (let ((drgnx-lang--user-command t))
                (drgnx-remote-reconnect))
              (let ((seg (drgnx-m11c2-ui-test--segment)))
                (should (string-search "connected" (car seg)))
                (should (eq (cdr seg) 'drgnx-remote-connected)))
              (should (buffer-live-p buffer))
              (should (eq (current-buffer) buffer))
              (should (buffer-modified-p buffer))
              (should (= (point) point))
              (should (string-suffix-p "unsaved change\n" (buffer-string)))
              (force-mode-line-update t) (redisplay t)
              (drgnx-m11c2-ui-test--shot shots "m11c2-remote-reconnected.png"))))
      (drgnx-remote--teardown)
      (when-let* ((b (find-buffer-visiting file))) (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b))
      (when (get-buffer drgnx-explorer-buffer-name) (kill-buffer drgnx-explorer-buffer-name))
      (ignore-errors (tramp-cleanup-all-connections))
      (drgnx-wb-hide-sidebar))))

(ert-deftest drgnx-ui-m11c2/agent-settings-and-remote ()
  (let* ((root (drgnx-uitest-root-frame)) (shots (make-temp-file "drgnx-m11c2-shot" t))
         (state (make-temp-file "drgnx-m11c2-state" t))
         (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" state "/config") (concat "XDG_STATE_HOME=" state "/state"))
                                      process-environment))
         (drgnx-wb--sections nil) (drgnx-signal--editor-window nil)
         (drgnx-wb--areas (copy-tree drgnx-wb--areas))
         (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
         (display-buffer-alist nil) (display-buffer-overriding-action '(nil))
         (name (format "drgnx-m11c2-%d" (emacs-pid))) (container nil) (podman (executable-find "podman")))
    (make-directory (concat state "/config") t)
    (unwind-protect
        (with-selected-frame root
          (delete-other-windows)
          (dolist (p '(drgnx-wb-view drgnx-wb-areas drgnx-wb-panel-px drgnx-wb-right-px drgnx-wb-dock-px))
            (set-frame-parameter nil p nil))
          (drgnx-m11c2-ui-test--settings-part shots)
          (if (not podman)
              (message "m11c-2: no podman, Open Remote is not shown")
            (let ((run (drgnx-m11c2-ui-test--podman "run" "-d" "--rm" "--memory" "256m" "--name" name
                                                    "registry.fedoraproject.org/fedora:44" "sleep" "600")))
              (should (eql (car run) 0))
              (setq container name)
              (drgnx-m11c2-ui-test--remote-part shots name))))
      (when container (drgnx-m11c2-ui-test--podman "rm" "-f" container))
      (with-selected-frame root
        (delete-other-windows)
        (dolist (p '(drgnx-wb-view drgnx-wb-areas drgnx-wb-panel-px drgnx-wb-right-px drgnx-wb-dock-px))
          (set-frame-parameter nil p nil))
        (dolist (p '(tab-line-format header-line-format mode-line-format)) (set-window-parameter nil p nil))
        (switch-to-buffer "*scratch*"))
      (delete-directory shots t)
      (delete-directory state t))))

;;; editor-m11c2-test.el ends here
