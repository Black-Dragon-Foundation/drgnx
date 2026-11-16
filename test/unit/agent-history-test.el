;;; agent-history-test.el --- batch tests: Past Sessions, against a real hub reading a temp home's CLI files -*- lexical-binding: t -*-
;; The hub (DRGNX_RATATOSKR_BIN) reads hand-written session files under the test's own HOME (never the user's), and
;; the list and the transcript arrive as its rows.
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'drgnx-notice)
(require 'drgnx-agents)                 ; `drgnx-agents-history-resume-writes-original'
(require 'json)
(load (expand-file-name "test/fixtures/hub-client-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-agent-history" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/notice-fixture" drgnx-dir) nil t)

(defun agent-history-test--claude (home id cwd said)
  "Write Claude Code session ID under HOME, run in CWD, whose user said SAID; its file."
  (let ((file (expand-file-name (format "-w/%s.jsonl" id) (expand-file-name ".claude/projects" home))))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert (json-encode `((type . "user") (uuid . "u1") (sessionId . ,id) (cwd . ,cwd)
                             (timestamp . "2026-11-01T10:00:00Z") (message . ((role . "user") (content . ,said)))))
              "\n"
              (json-encode `((type . "assistant") (uuid . "u2") (sessionId . ,id) (timestamp . "2026-11-01T10:00:05Z")
                             (message . ((role . "assistant") (content . [((type . "text") (text . "Done that."))])))))
              "\n"))
    file))

(defmacro agent-history-test--with (&rest body)
  "BODY with the tools/agent-panel module's commands, Ratatoskr serving and connected, and `home' the hub's HOME,
the CLIs' own folder variables unset (so the hub reads only HOME)."
  (declare (indent 0))
  `(let ((process-environment (append '("CLAUDE_CONFIG_DIR" "CODEX_HOME" "GEMINI_CLI_HOME") process-environment)))
     (drgnx-notice-test-with-model
       (drgnx-hub-client-test--with-ratatoskr
         (let ((home (expand-file-name "home" root)))
           (make-directory home t)
           (drgnx-hub-connect)
           (drgnx-hub-client-test--wait (lambda () (and (processp drgnx-hub--events) (process-get drgnx-hub--events :drgnx-proven)))
                                        "the event connection proves itself")
           (unwind-protect (progn ,@body)
             (drgnx-agent-history-teardown)))))))

(ert-deftest drgnx-agent-history/the-hub-finds-searches-and-opens-a-homes-sessions ()
  :tags '(:cond)                        ; a real hub process and socket
  (agent-history-test--with
    (let ((cwd (file-name-as-directory (expand-file-name "orchard" home))) started)
      (make-directory cwd t)
      (agent-history-test--claude home "a1" (directory-file-name cwd) "count the apples")
      (agent-history-test--claude home "b2" "/elsewhere" "weigh the pears")
      (should (equal (drgnx-hub-call-sync "agents/history/rescan" nil 20) '(:sessions 2)))
      (should (equal (mapcar (lambda (h) (plist-get (plist-get h :session) :id))
                             (plist-get (drgnx-hub-call-sync "agents/history/search" '(:query "pears") 20) :hits))
                     '("b2")))
      ;; Open: the transcript's view, and the terminal's command as argv in the session's folder
      (let (opened)
        (cl-letf (((symbol-function 'pop-to-buffer) #'ignore)
                  ((symbol-function 'drgnx-view-env-register) #'ignore))
          (drgnx-agent-history-open '(:provider "claude" :id "a1"))
          (drgnx-hub-client-test--wait
           (lambda () (setq opened (cl-find-if (lambda (b) (buffer-local-value 'drgnx-agent-history--opened b))
                                               (buffer-list))))
           "the transcript's buffer"))
        (with-current-buffer opened
          (should (eq major-mode 'drgnx-agent-history-transcript-mode))
          (should buffer-read-only)
          (should (equal (plist-get drgnx-agent-history--opened :view) "agent-history/claude:a1"))
          (cl-letf (((symbol-function 'drgnx-term-start) (lambda (dir argv) (setq started (list dir argv)))))
            (drgnx-agent-history-resume-in-terminal)
            (drgnx-hub-client-test--wait (lambda () started) "the terminal starts")))
        (kill-buffer opened))
      (should (equal started (list (directory-file-name cwd) '("claude" "--resume" "a1")))))))

(ert-deftest drgnx-agent-history/the-list-asks-for-its-workspace-and-query ()
  (let ((asked nil) (default-directory temporary-file-directory))
    (cl-letf (((symbol-function 'drgnx-agent-history--call) (lambda (method params _cb) (push (cons method params) asked)))
              ((symbol-function 'drgnx-view-env-register) #'ignore))
      (unwind-protect
          (progn
            (drgnx-agent-history-buffer)
            (drgnx-agent-history-search "apples pears")
            (drgnx-agent-history-search "  "))
        (kill-buffer drgnx-agent-history-buffer-name)))
    (setq asked (nreverse asked))
    (should (equal (car (nth 0 asked)) "agents/history/subscribe"))
    (should (equal (plist-get (cdr (nth 0 asked)) :view) drgnx-agent-history-view))
    (should (equal (plist-get (cdr (nth 0 asked)) :workspace) (directory-file-name temporary-file-directory)))
    (should-not (plist-member (cdr (nth 0 asked)) :query))
    (should (equal (plist-get (cdr (car (last asked 2))) :query) "apples pears"))
    ;; a blank search shows all again
    (should-not (plist-member (cdr (car (last asked))) :query))))

(ert-deftest drgnx-agent-history/a-gone-folder-is-said-not-guessed ()
  (should-error (drgnx-agent-history-resume-command '(:argv ["codex" "resume" "x"] :session (:cwd "/no/such/folder")))
                :type 'user-error)
  (should (equal (drgnx-agent-history-resume-command
                  (list :argv ["codex" "resume" "x"] :session (list :cwd temporary-file-directory)))
                 (cons temporary-file-directory '("codex" "resume" "x")))))

(ert-deftest drgnx-agent-history/resume-here-defaults-to-a-copy ()
  (let ((drgnx-agents-history-resume-writes-original nil) asked)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt choices &rest args) (setq asked choices) (nth 4 args))))
      (should (eq (drgnx-agent-history-read-route) 'copy))
      (should (cl-some (lambda (c) (string-match-p "lets the jailed agent write this one CLI session file" c)) asked)))
    (setq drgnx-agents-history-resume-writes-original t)
    (cl-letf (((symbol-function 'completing-read) (lambda (_prompt _choices &rest args) (nth 4 args))))
      (should (eq (drgnx-agent-history-read-route) 'original)))))

;; The Agents list's Past sessions section: the hub's rows (a hub view the list's buffer keeps beside its own) drawn
;; after the live sessions, in the hub's order, RET on one opening its transcript, the same search narrowing them.

(defun agent-history-test--row (key text &optional past)
  (list :key key :text text :props (and past (list (list 0 (length text) "drgnx-past" (list :provider "claude" :id past))))))

(ert-deftest drgnx-agent-history/the-agents-list-shows-past-sessions-after-its-own ()
  (load (expand-file-name "modules/tools/drgnx-agent-panel-list" drgnx-dir) nil t)
  (let ((drgnx-view-patch--buffers (make-hash-table :test #'equal)) (drgnx-view-patch--hooked nil)
        (default-directory temporary-file-directory) asked opened)
    (cl-letf (((symbol-function 'drgnx-agent-history--call)
               (lambda (method params cb) (push (cons method params) asked) (when (equal method "agents/history/open") (setq opened params)) (ignore cb)))
              ((symbol-function 'drgnx-view-env-register) #'ignore)
              ((symbol-function 'drgnx-agents-sessions) #'ignore)
              (drgnx-hub--events (start-process "agent-history-test-events" nil "cat")))
      (unwind-protect
          (with-current-buffer (drgnx-agent-panel-list-buffer)
            ;; the section asks for a few sessions, this workspace's first
            (let ((p (cdr (assoc "agents/history/subscribe" asked))))
              (should (equal (plist-get p :view) drgnx-agent-history-section-view))
              (should (equal (plist-get p :limit) drgnx-agent-panel-list-past-limit))
              (should (equal (plist-get p :workspace) (directory-file-name temporary-file-directory))))
            (drgnx-view-apply-patch
             (list :view drgnx-agent-history-section-view :class "unshown" :hub 7 :base 0 :version 1 :env_epoch 0
                   :ops (list (list :reset (list (agent-history-test--row "h:past" "Past sessions")
                                                 (agent-history-test--row "h:claude:a1" "  count the apples" "a1"))))))
            (drgnx-view-draw-now drgnx-view)
            (should (string-match-p "No agent sessions yet.*\nPast sessions\n  count the apples" (buffer-string)))
            ;; a row the hub inserts lands where it says, one it removes goes
            (drgnx-view-apply-patch
             (list :view drgnx-agent-history-section-view :class "unshown" :hub 7 :base 1 :version 2 :env_epoch 0
                   :ops (list (list :insert (list :after "h:past" :rows (list (agent-history-test--row "h:claude:b2" "  weigh the pears" "b2")))))))
            (drgnx-view-draw-now drgnx-view)
            (should (string-match-p "Past sessions\n  weigh the pears\n  count the apples" (buffer-string)))
            (drgnx-view-apply-patch
             (list :view drgnx-agent-history-section-view :class "unshown" :hub 7 :base 2 :version 3 :env_epoch 0
                   :ops (list (list :remove (list "h:claude:a1")))))
            (drgnx-view-draw-now drgnx-view)
            (should-not (string-match-p "apples" (buffer-string)))
            ;; RET on a past row opens its transcript
            (goto-char (point-min))
            (search-forward "weigh the pears")
            (drgnx-agent-panel-list-open)
            (should (equal opened '(:provider "claude" :id "b2")))
            ;; the same search narrows the section, not the Past Sessions list
            (setq asked nil)
            (drgnx-agent-history-search "pears")
            (should (equal (plist-get (cdr (assoc "agents/history/subscribe" asked)) :view) drgnx-agent-history-section-view))
            (should (equal (plist-get (cdr (assoc "agents/history/subscribe" asked)) :query) "pears"))
            (should-not (get-buffer drgnx-agent-history-buffer-name)))
        (delete-process drgnx-hub--events)
        (kill-buffer drgnx-agent-panel-list-buffer-name)))))

;;; agent-history-test.el ends here
