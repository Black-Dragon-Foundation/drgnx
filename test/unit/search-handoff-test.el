;;; search-handoff-test.el --- batch tests: Ask an Agent, the Search view's matches handed to an agent -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; No hub and no agent: `drgnx-hub--call-on' answers from a table and records the calls; the Search view is a buffer
;; whose rows the stubs below describe; the hub's `search-handoff-state' is given by hand.  Each test names its pattern.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "modules/tools/drgnx-search-handoff" drgnx-dir) nil t)

(defvar drgnx-search-handoff-test--calls nil "The hub calls made, newest first: (METHOD PARAMS).")
(defvar drgnx-hub--events nil)          ; the hub client is not loaded: the stub below takes its calls
(defvar drgnx-replace-view)
(defvar drgnx-replace--root)
(defvar drgnx-replace--hub-counts)
(defvar drgnx-replace-buffer-name "*drgnx-search-handoff-test view*")

(defmacro drgnx-search-handoff-test--with (spec &rest body)
  "BODY with the Search view a buffer of SPEC (:off UNTICKED-IDS :total N :row ID :replace R :sessions SESSIONS),
each session (ID NAME CWD); the hub answers `search/handoff' with ANSWER from SPEC, every call recorded."
  (declare (indent 1))
  `(let* ((spec ,spec) (drgnx-search-handoff-test--calls nil) (searched 0) (statuses 0) (asked 0)
          (view (get-buffer-create drgnx-replace-buffer-name)))
     (with-current-buffer view
       (setq-local drgnx-replace-view "s" drgnx-replace--root "/r/"
                   drgnx-replace--hub-counts (cons 2 (plist-get spec :total))))
     (cl-letf (((symbol-function 'drgnx-hub--call-on)
                (lambda (_conn method params cb &rest _)
                  (push (list method params) drgnx-search-handoff-test--calls)
                  (funcall cb (plist-get spec :answer) nil)))
               ((symbol-function 'drgnx-replace--live-view) (lambda () view))
               ((symbol-function 'drgnx-replace--rows-p) (lambda () t))
               ((symbol-function 'drgnx-replace--rows-off)
                (lambda () (let ((h (make-hash-table :test #'equal)))
                             (dolist (id (plist-get spec :off) h) (puthash id t h)))))
               ((symbol-function 'drgnx-replace--rows-group-p) (lambda (id) (string-prefix-p "f:" id)))
               ((symbol-function 'drgnx-replace--rows-file-matches) (lambda (_) '("m:1:4" "m:1:5")))
               ((symbol-function 'drgnx-view-nav-selection) (lambda () (plist-get spec :row)))
               ((symbol-function 'drgnx-replace--text)
                (lambda (f) (if (eq f 'find) "pending" (or (plist-get spec :replace) ""))))
               ((symbol-function 'drgnx-replace--update-status) (lambda () (cl-incf statuses)))
               ((symbol-function 'drgnx-replace--search-now) (lambda () (cl-incf searched)))
               ((symbol-function 'drgnx-agents-default-profile) (lambda () "claude"))
               ((symbol-function 'drgnx-agents-sessions) (lambda () (plist-get spec :sessions)))
               ((symbol-function 'drgnx-agent-session-remote) #'car)
               ((symbol-function 'drgnx-agent-session-name) #'cadr)
               ((symbol-function 'drgnx-agent-session-cwd) #'caddr)
               ((symbol-function 'drgnx-agent-session-status) (lambda (_) 'idle))
               ((symbol-function 'drgnx-agents-editor-ordinal) (lambda (_) 2))
               ((symbol-function 'drgnx-agent-identity) (lambda (_) '(:face drgnx-agent-two :glyph "■")))
               ((symbol-function 'drgnx-agents-profile) (lambda (name) (assoc name (plist-get spec :profiles))))
               ((symbol-function 'drgnx-agent-session-profile) #'cadddr)
               ((symbol-function 'drgnx-ai-confirm-project-route) (lambda () (cl-incf asked) t))
               ((symbol-function 'drgnx-ai-agent-gateway-chain)
                (lambda (kind _model) (alist-get kind (plist-get spec :chains))))
               ((symbol-function 'drgnx-ai-remote-p) (lambda (id) (eq id 'openrouter)))
               ((symbol-function 'pop-to-buffer) #'set-buffer)
               ((symbol-function 'quit-window) #'ignore))
       (unwind-protect (progn ,@body)
         (kill-buffer view)
         (when-let* ((b (get-buffer drgnx-search-handoff-buffer-name))) (kill-buffer b))))))

(defun drgnx-search-handoff-test--sent ()
  "The params of the last `search/handoff'."
  (cadr (assoc "search/handoff" drgnx-search-handoff-test--calls)))

(ert-deftest drgnx-search-handoff/the-card-is-prefilled-and-says-who ()
  "Pattern D: the card's text is prefilled from the replacement; who is a new worker of the default profile first, a
new pair in the checkout, then each live session with its state, the one in the search's checkout as a pair; Next
Agent goes round them."
  (drgnx-search-handoff-test--with (list :total 3 :replace "queued"
                                         :sessions '(("a1" "codex-1" "/r/") ("a2" "claude-2" "/elsewhere/")))
    (drgnx-search-to-agent)
    (with-current-buffer drgnx-search-handoff-buffer-name
      (should (derived-mode-p 'drgnx-search-handoff-mode))
      (should (equal (buffer-string) "Replace `pending' with `queued' in these places, keeping behaviour."))
      (should (equal (mapcar #'car (plist-get drgnx-search-handoff--ask :choices))
                     '("New worker, own worktree" "New pair here" "Pair · codex-1 (idle)" "claude-2 (idle)")))
      (should (equal (cdr (nth 1 (plist-get drgnx-search-handoff--ask :choices))) '(:pair (:profile "claude"))))
      (should (string-match-p "Ask an Agent · 3 matches  Who: New worker" drgnx-search-handoff--header-text))
      (drgnx-search-handoff-next-who)
      (should (string-match-p "Who: New pair here" drgnx-search-handoff--header-text))
      (drgnx-search-handoff-next-who)
      (should (string-match-p "Who: Pair · codex-1 (idle)" drgnx-search-handoff--header-text))
      (drgnx-search-handoff-next-who)
      (drgnx-search-handoff-next-who)
      (should (string-match-p "Who: New worker" drgnx-search-handoff--header-text))
      (drgnx-search-handoff-hidden)
      (should (string-match-p "hidden files in" drgnx-search-handoff--header-text)))))

(ert-deftest drgnx-search-handoff/send-hands-off-the-ticked-or-the-row ()
  "Pattern D: with matches ticked, Send hands off all but the unticked (`off'); to a session, with the agent's mark for
the rows; with none ticked, the selected row's matches (a file's, by `ids').  An empty instruction is refused."
  (drgnx-search-handoff-test--with (list :total 3 :off '("m:1:2")
                                         :sessions '(("a1" "codex-1" "/r/"))
                                         :answer '(:handoff "h:1" :session "a1" :ids ["m:1:1" "m:1:3"] :sent 2 :more 0))
    (drgnx-search-to-agent)
    (with-current-buffer drgnx-search-handoff-buffer-name
      (should-error (drgnx-search-handoff-send) :type 'user-error)
      (insert "Rename it.")
      (drgnx-search-handoff-next-who)
      (drgnx-search-handoff-next-who)
      (drgnx-search-handoff-send))
    (should (equal (drgnx-search-handoff-test--sent)
                   '(:view "s" :instruction "Rename it." :to (:session (:id "a1")) :off ["m:1:2"]
                           :mark (:face "drgnx-agent-two" :glyph "■"))))
    (with-current-buffer view
      (should (equal (plist-get (car drgnx-search-handoff--live) :ids) '("m:1:1" "m:1:3")))
      (should (equal (drgnx-search-handoff-chip)
                     (concat " · " (propertize " Pair · codex-1: sent " 'face 'drgnx-search-handoff-chip))))))
  ;; nothing ticked: the selected file row's matches, to a new worker (no mark yet: it has no ordinal)
  (drgnx-search-handoff-test--with (list :total 2 :off '("m:1:4" "m:1:5") :row "f:a.el"
                                         :answer '(:handoff "h:2" :session "a9" :worktree "/wt/" :ids ["m:1:4" "m:1:5"]
                                                            :sent 2 :more 0))
    (drgnx-search-to-agent)
    (with-current-buffer drgnx-search-handoff-buffer-name
      (insert "Look at these.")
      (drgnx-search-handoff-send))
    (should (equal (drgnx-search-handoff-test--sent)
                   '(:view "s" :instruction "Look at these." :to (:new (:profile "claude")) :ids ["m:1:4" "m:1:5"])))))

(ert-deftest drgnx-search-handoff/the-chip-follows-the-state-and-rerun-searches-the-worktree ()
  "Pattern D: `search-handoff-state' updates the view's chip (`editing, N done', then `done N / M skipped'); Re-run in
Worktree searches the worker's worktree."
  (drgnx-search-handoff-test--with (list :total 3 :off nil
                                         :answer '(:handoff "h:3" :session "a9" :worktree "/wt/" :ids ["a" "b" "c"]
                                                            :sent 3 :more 0))
    (drgnx-search-to-agent)
    (with-current-buffer drgnx-search-handoff-buffer-name
      (insert "Do it.")
      (drgnx-search-handoff-send))
    (should (drgnx-search-handoff-event "search-handoff-state"
                                        '(:handoff "h:3" :phase "editing" :done ["a"] :left ["b" "c"])))
    (with-current-buffer view
      (should (string-match-p " Worker: editing, 1 done" (drgnx-search-handoff-chip))))
    (drgnx-search-handoff-event "search-handoff-state" '(:handoff "h:3" :phase "done" :done ["a" "b"] :left ["c"]))
    (with-current-buffer view
      (should (string-match-p ": done 2 / 1 skipped $" (drgnx-search-handoff-chip)))
      (drgnx-search-handoff-rerun)
      (should (equal drgnx-replace--root "/wt/")))
    (should (= searched 1))
    (should-not (drgnx-search-handoff-event "search-change" nil))))

(ert-deftest drgnx-search-handoff/a-new-workers-rows-are-marked-from-its-first-snapshot ()
  "Pattern D: a new worker has no ordinal when `search/handoff' answers, so its rows go unmarked; its first `agent'
snapshot brings the ordinal, and the hand-off's rows get its mark (`search/handoff-mark') once."
  (drgnx-search-handoff-test--with (list :total 2 :off '("m:1:4" "m:1:5") :row "f:a.el"
                                         :answer '(:handoff "h:3" :session "w1" :worktree "/wt/" :ids ["m:1:4" "m:1:5"]
                                                            :sent 2 :more 0))
    (cl-letf (((symbol-function 'drgnx-agents-editor-ordinal) #'ignore)
              ((symbol-function 'drgnx-agent-identity)
               (lambda (n) (and (eql n 3) '(:face drgnx-agent-three :glyph "▲")))))
      (drgnx-search-to-agent)
      (with-current-buffer drgnx-search-handoff-buffer-name
        (insert "Look at these.")
        (drgnx-search-handoff-send))
      (should-not (plist-get (drgnx-search-handoff-test--sent) :mark))
      (should-not (assoc "search/handoff-mark" drgnx-search-handoff-test--calls))
      ;; another session's snapshot marks nothing; the worker's does, once
      (drgnx-search-handoff-event "agent" '(:id "a1" :session (:ordinal 3)))
      (should-not (assoc "search/handoff-mark" drgnx-search-handoff-test--calls))
      (drgnx-search-handoff-event "agent" '(:id "w1" :session (:ordinal 3)))
      (drgnx-search-handoff-event "agent" '(:id "w1" :session (:ordinal 3)))
      (should (equal (seq-filter (lambda (c) (equal (car c) "search/handoff-mark")) drgnx-search-handoff-test--calls)
                     '(("search/handoff-mark" (:handoff "h:3" :mark (:face "drgnx-agent-three" :glyph "▲")))))))))

(ert-deftest drgnx-search-handoff/the-card-says-where-the-agent-sends-and-refuses-no-route ()
  "Pattern D: the card asks about the project's remote routes once as it opens (a command the user ran), and says
where the chosen agent sends its requests: a vendor's agent its own service, a gateway one its chain's providers,
remote or local; a chain the project's routes leave empty is said in red and Send refuses it."
  (drgnx-search-handoff-test--with
      (list :total 1 :off nil
            :profiles '(("claude") ("or" :ai claude-openrouter) ("none" :ai claude-anthropic))
            :chains '((claude-openrouter (openrouter . "m") (ollama)))
            :sessions '(("a1" "or-1" "/elsewhere/" "or") ("a2" "none-1" "/elsewhere/" "none")))
    (drgnx-search-to-agent)
    (should (= asked 1))
    (with-current-buffer drgnx-search-handoff-buffer-name
      (should (string-match-p "via its vendor's own service" drgnx-search-handoff--header-text))
      (drgnx-search-handoff-next-who)
      (drgnx-search-handoff-next-who)
      (should (string-match-p "Who: or-1 (idle)  via openrouter (remote) → ollama (local)"
                              drgnx-search-handoff--header-text))
      (drgnx-search-handoff-next-who)
      (should (string-match-p "via no provider the project's routes allow" drgnx-search-handoff--header-text))
      (insert "Do it.")
      (should-error (drgnx-search-handoff-send) :type 'user-error)
      (should-not (assoc "search/handoff" drgnx-search-handoff-test--calls)))))
