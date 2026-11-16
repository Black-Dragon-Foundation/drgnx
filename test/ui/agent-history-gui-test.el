;;; agent-history-gui-test.el --- GUI tests: Past Sessions on a real hub's rows (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake

;; A real session and a real hub (the checkout's test-hooks Ratatoskr) whose HOME holds hand-written Claude Code
;; session files (invented content; never the user's): the Past Sessions list draws the hub's rows, this workspace's
;; first; a search narrows it; a line appended to a session file shows as one more turn without a rescan; RET opens the
;; transcript read-only, drawn from the hub's rows.

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'json)
(require 'drgnx-uitest)

(defconst drgnx-ui-agent-history--repo         ; the session runs the repository's test/ui
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness" "modules/tools"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-agent-history--repo)))
(require 'drgnx)
(require 'drgnx-agents)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-ui-agent-history--repo) nil t)
(load (expand-file-name "test/fixtures/hub-client-fixture" drgnx-ui-agent-history--repo) nil t)
(load (expand-file-name "modules/tools/drgnx-agent-history" drgnx-ui-agent-history--repo) nil t)

(defun drgnx-ui-agent-history--bin ()
  "The hub: DRGNX_RATATOSKR_BIN, else the checkout's test-hooks build (a GUI session does not inherit the variable)."
  (or (getenv "DRGNX_RATATOSKR_BIN")
      (seq-find #'file-executable-p
                (mapcar (lambda (rel) (expand-file-name rel drgnx-ui-agent-history--repo))
                        '("runtime/target/rec-ert/ratatoskr" "runtime/target/debug/ratatoskr")))
      (ert-fail "needs a test-hooks ratatoskr built in the checkout")))

(defun drgnx-ui-agent-history--line (id type cwd text)
  (json-encode `((type . ,type) (uuid . ,(format "%s-%s" id (random 100000))) (sessionId . ,id) (cwd . ,cwd)
                 (timestamp . "2026-11-01T10:00:00Z")
                 (message . ((role . ,type) (content . ,(if (equal type "user") text
                                                          (vector `((type . "text") (text . ,text))))))))))

(defun drgnx-ui-agent-history--session (home id cwd said)
  "Claude Code session ID under HOME, run in CWD: you said SAID, it answered; its file."
  (let ((file (expand-file-name (format "-w/%s.jsonl" id) (expand-file-name ".claude/projects" home))))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert (drgnx-ui-agent-history--line id "user" cwd said) "\n"
              (drgnx-ui-agent-history--line id "assistant" cwd (concat "Answered: " said)) "\n"))
    file))

(defun drgnx-ui-agent-history--text (buffer)
  (with-current-buffer buffer (buffer-substring-no-properties (point-min) (point-max))))

(defun drgnx-ui-agent-history--shows (buffer regexp what)
  "Wait until BUFFER, drawn in its window, shows REGEXP."
  (drgnx-test-wait (lambda () (redisplay t) (string-match-p regexp (drgnx-ui-agent-history--text buffer)))
                   :secs 30 :what what))

(ert-deftest drgnx-ui-agent-history/the-list-the-search-a-live-turn-and-a-transcript ()
  (skip-unless (display-graphic-p))
  (let ((process-environment (append (list (concat "DRGNX_RATATOSKR_BIN=" (drgnx-ui-agent-history--bin))
                                           "CLAUDE_CONFIG_DIR" "CODEX_HOME" "GEMINI_CLI_HOME")
                                     process-environment)))
    (drgnx-hub-client-test--with-ratatoskr
      (let* ((home (expand-file-name "home" root))
             (here (expand-file-name "orchard" home))
             (a (progn (make-directory here t) (drgnx-ui-agent-history--session home "a1" here "count the apples")))
             (frame (drgnx-uitest-root-frame)) list transcript)
        (drgnx-ui-agent-history--session home "b2" "/elsewhere" "weigh the pears")
        (drgnx-hub-connect)
        (drgnx-test-wait (lambda () (and (processp drgnx-hub--events) (process-get drgnx-hub--events :drgnx-proven)))
                         :secs 30 :what "the event connection proves itself")
        (unwind-protect
            (with-selected-frame frame
              (delete-other-windows)
              (let ((default-directory (file-name-as-directory here)))
                (setq list (drgnx-agent-history-buffer)))
              (set-window-buffer (selected-window) list)
              ;; the workspace's session first, the other under its own header
              (drgnx-ui-agent-history--shows list "This workspace\n.*count the apples.*\nOther projects\n.*weigh the pears"
                                             "both sessions, the workspace's first")
              (should (string-match-p "Claude.*count the apples.*orchard.*1 turn\\b" (drgnx-ui-agent-history--text list)))
              ;; a search narrows it to the hit
              (drgnx-agent-history-search "pears")
              (drgnx-test-wait (lambda () (redisplay t) (not (string-match-p "apples" (drgnx-ui-agent-history--text list))))
                               :secs 30 :what "the search narrows the list")
              (should (string-match-p "weigh the pears" (drgnx-ui-agent-history--text list)))
              (drgnx-agent-history-search "")
              ;; a turn appended to the file shows without a rescan (the hub reads on from where it was)
              (write-region (concat (drgnx-ui-agent-history--line "a1" "user" here "and the plums") "\n") nil a t 'silent)
              (drgnx-ui-agent-history--shows list "count the apples.*2 turns" "the appended turn")
              ;; RET on the session opens its transcript, read-only, from the hub's rows
              (with-current-buffer list
                (goto-char (point-min))
                (search-forward "count the apples")
                (drgnx-agent-history-open))
              (drgnx-test-wait (lambda () (setq transcript (seq-find (lambda (b) (buffer-local-value 'drgnx-agent-history--opened b))
                                                                     (buffer-list))))
                               :secs 30 :what "the transcript's buffer")
              (set-window-buffer (selected-window) transcript)
              (drgnx-ui-agent-history--shows transcript "Answered: count the apples" "the transcript's rows")
              (should (string-match-p "and the plums" (drgnx-ui-agent-history--text transcript)))
              (should (buffer-local-value 'buffer-read-only transcript)))
          (drgnx-agent-history-teardown))))))

;;; agent-history-gui-test.el ends here
