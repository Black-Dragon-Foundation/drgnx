;;; work-space-thirty-fixture.el --- the 30-agent workspace in a real hub: three repos, 30 mock agents streaming -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; One description, test/fixtures/work-space/thirty.json (4 plans, 3 specs, 6 asks, 30 agents, 30 branches over
;; three repositories, 120 edited files), built into a hub of the session's own: `drgnx-work-thirty-start' makes the
;; repositories (org, drgnx, nidhogg) and a worktree per agent in a temp directory, starts Ratatoskr with one profile
;; per agent (each a `ratatoskr-mock acp' running that agent's script: it edits the files the description names, then
;; streams one chunk a second for fifteen minutes) and sends every agent the text of its ask.  The perf workloads
;; (harness/drgnx-perf-run.el) and the GUI scenes (test/ui/work-space-gui-test.el) both use it, through the mock
;; agents only.  `drgnx-work-thirty-premise' says whether what a workload measures holds: it signals when it does not.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'json)
(require 'drgnx-paths)

(defvar drgnx-work-thirty--dir nil "The temp directory of the fixture: repositories, worktrees, hub settings.")
(defvar drgnx-work-thirty--hub nil "The hub process.")
(defvar drgnx-work-thirty--mirrors nil "The 30 session mirrors, in the description's order.")
(defvar drgnx-work-thirty--roots nil "The three repositories (org, drgnx, nidhogg), with a trailing slash.")
(defvar drgnx-work-thirty--started nil "When the 30 agents were all busy (float seconds).")
(defvar drgnx-work-thirty--agents nil "The built agents: plists :id :profile :cwd :branch :edits.")

(defconst drgnx-work-thirty-streaming-seconds 900 "How long a mock agent's turn lasts: one chunk a second.")

(defun drgnx-work-thirty--desc ()
  "The description, parsed (objects as alists with symbol keys, arrays as lists)."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "test/fixtures/work-space/thirty.json" drgnx-dir))
    (json-parse-buffer :object-type 'alist :array-type 'list)))

(defun drgnx-work-thirty--git (dir &rest args)
  "Run git ARGS in DIR; an error when it fails."
  (let ((default-directory (file-name-as-directory dir)))
    (unless (zerop (apply #'call-process "git" nil nil nil "-c" "user.name=perf" "-c" "user.email=perf@localhost"
                          "-c" "commit.gpgsign=false" args))
      (error "git %S failed in %s" args dir))))

(defun drgnx-work-thirty--wait (secs pred)
  "Let the session run until PRED holds (at most SECS s); whether it does."
  (let ((d (+ (float-time) secs)))
    (while (and (not (funcall pred)) (< (float-time) d)) (accept-process-output nil 0.05))
    (and (funcall pred) t)))

(defun drgnx-work-thirty--first (path) (car (split-string path "/" t)))
(defun drgnx-work-thirty--rest (path) (mapconcat #'identity (cdr (split-string path "/" t)) "/"))
(defun drgnx-work-thirty--slug (id) (replace-regexp-in-string "[^A-Za-z0-9]+" "-" id))

(defun drgnx-work-thirty--touch (file)
  "Make FILE (with its folders) holding one line."
  (make-directory (file-name-directory file) t)
  (unless (file-exists-p file) (with-temp-file file (insert "one line\n"))))

(defun drgnx-work-thirty--agent-list (desc)
  "The description's agents as plists :id :parent :repo :branch :files :reads :decide, subagents given their parent's repository."
  (let ((all (alist-get 'agents desc)) (by-id (make-hash-table :test #'equal)) out)
    (dolist (a all) (puthash (alist-get 'id a) a by-id))
    (dolist (a all)
      (let* ((id (alist-get 'id a)) (parent (and (string-search "/" id) (car (split-string id "/"))))
             (pa (and parent (gethash parent by-id)))
             (files (mapcar (lambda (f) (symbol-name (car f))) (alist-get 'files a)))
             (files (append files (alist-get 'edits a)))
             (branch (alist-get 'branch a))
             (repo (cond (branch (drgnx-work-thirty--first branch))
                         (files (drgnx-work-thirty--first (car files)))
                         (pa (drgnx-work-thirty--first (or (alist-get 'branch pa) "drgnx/x")))
                         (t "drgnx"))))
        (push (list :id id :parent parent :repo repo
                    :branch (if branch (drgnx-work-thirty--rest branch)
                              (format "%s-%s" (drgnx-work-thirty--slug (or parent id)) (drgnx-work-thirty--slug id)))
                    :files files :reads (alist-get 'reads a) :decide (alist-get 'conclusion a)
                    :name (alist-get 'name a))
              out)))
    (nreverse out)))

(defun drgnx-work-thirty--program (agent dir)
  "AGENT's turn as the mock reads it: one line, `\\n' between the words.  The edits first (files of the agent's own
repository inside its worktree, the others in their repository's folder), then a subagent for a parent, a decision for
an agent with a conclusion, then a chunk a second."
  (let* ((repo (plist-get agent :repo))
         (edits (mapcar (lambda (f) (if (equal (drgnx-work-thirty--first f) repo) (drgnx-work-thirty--rest f)
                                      (expand-file-name f dir)))
                        (delete-dups (copy-sequence (plist-get agent :files)))))
         (words (append (list "say starting")
                        (mapcar (lambda (r) (concat "tool:read " (if (equal (drgnx-work-thirty--first r) repo)
                                                                     (drgnx-work-thirty--rest r)
                                                                   (expand-file-name r dir))))
                                (plist-get agent :reads))
                        (mapcar (lambda (e) (concat "tool:edit " e)) edits)
                        (and (plist-get agent :parent) (list "provider:task look around"))
                        (and (plist-get agent :decide) (list (concat "decide " (plist-get agent :decide))))
                        ;; a chunk, a read (a step, so the map's fields change) and a second of quiet, over and over
                        ;; the read differs in its offset each time: the hub's supervisor pauses an agent that makes
                        ;; the same call three times in a turn (its `repeat' rule), and the turn would end
                        (cl-loop for i from 1 to drgnx-work-thirty-streaming-seconds
                                 append (append (list "say still working on it, a line a second")
                                                (and edits (list (format "provider:read %s %d 1" (car edits) i)))
                                                (list "silent 1"))))))
    (mapconcat #'identity words "\\n")))

(defun drgnx-work-thirty-build (dir)
  "Make the three repositories and a worktree per agent under DIR; the agents, as plists (:id :profile :cwd :script-line…).
Sets `drgnx-work-thirty--roots'."
  (let* ((desc (drgnx-work-thirty--desc)) (agents (drgnx-work-thirty--agent-list desc))
         (repos '("org" "drgnx" "nidhogg")) (seen (make-hash-table :test #'equal)))
    (dolist (r repos) (make-directory (expand-file-name r dir) t))
    (dolist (a agents)
      (dolist (f (append (plist-get a :files) (plist-get a :reads)))
        (drgnx-work-thirty--touch (expand-file-name f dir))))
    (dolist (p (alist-get 'plans desc))
      (let ((file (expand-file-name (format "org/docs/plans/%s.md" (alist-get 'id p)) dir)))
        (drgnx-work-thirty--touch file)
        (with-temp-file file (insert (format "# %s\n\n- [ ] first task\n" (alist-get 'title p))))))
    (dolist (s (alist-get 'specs desc))
      (let ((file (expand-file-name (format "org/docs/specs/%s.md" (alist-get 'id s)) dir)))
        (drgnx-work-thirty--touch file)
        (with-temp-file file (insert (format "# %s\n\nA spec.\n" (alist-get 'title s))))))
    (dolist (r repos)
      (let ((root (expand-file-name r dir)))
        (drgnx-work-thirty--git root "init" "-q" "-b" "main")
        (drgnx-work-thirty--git root "add" "-A")
        (drgnx-work-thirty--git root "commit" "-q" "-m" "perf fixture")))
    (setq drgnx-work-thirty--roots (mapcar (lambda (r) (file-name-as-directory (expand-file-name r dir))) repos))
    (mapcar (lambda (a)
              (let* ((id (plist-get a :id)) (repo (plist-get a :repo))
                     (branch (let ((b (plist-get a :branch)) (n 1))
                               (while (gethash (cons repo b) seen) (setq b (format "%s-%d" (plist-get a :branch) (cl-incf n))))
                               (puthash (cons repo b) t seen) b))
                     (cwd (expand-file-name (concat "wt/" (drgnx-work-thirty--slug id)) dir)))
                (make-directory (file-name-directory cwd) t)
                (drgnx-work-thirty--git (expand-file-name repo dir) "worktree" "add" "-q" "-b" branch cwd "main")
                (append (list :profile (concat "perf-" (drgnx-work-thirty--slug id)) :cwd cwd :branch branch
                              :line (drgnx-work-thirty--program (plist-put (copy-sequence a) :repo repo) dir))
                        a)))
            agents)))

(defun drgnx-work-thirty--ask-text (desc index id)
  "The ask the agent INDEX (0-based) of ID got: the description's ask that names it, else asks 1 to 4 in turn."
  (let* ((asks (alist-get 'asks desc))
         (named (seq-find (lambda (a) (member (format "agent:%s" id) (alist-get 'to a))) asks)))
    (alist-get 'text (or named (nth (% index 4) asks)))))

(defvar drgnx-hub-event-functions)
(declare-function drgnx-hub-running-p "drgnx-hub-client")
(declare-function drgnx-hub-connect "drgnx-hub-client")
(declare-function drgnx-hub-ensure "drgnx-hub-client")
(declare-function drgnx-hub-disconnect "drgnx-hub-client")
(declare-function drgnx-agents-mirror-start "drgnx-agents-mirror")
(declare-function drgnx-agents-mirror-stop "drgnx-agents-mirror")
(declare-function drgnx-agents-send "drgnx-agents")
(declare-function drgnx-agents-kill "drgnx-agents")
(declare-function drgnx-agent-session-status "drgnx-agents")
(declare-function drgnx-agent-session-remote "drgnx-agents")
(defvar drgnx-agents--sessions)

(defun drgnx-work-thirty-start (bin)
  "Build the fixture, start a hub of BIN (a test-hooks ratatoskr with `ratatoskr-mock' beside it) with one profile per
agent, start the 30 agents and send each its ask; wait until all 30 are busy.  Returns the mirrors."
  (require 'drgnx-agents-mirror)
  (require 'drgnx-hub-client)
  (let* ((mock (and bin (expand-file-name "ratatoskr-mock" (file-name-directory bin)))))
    (unless (and mock (file-executable-p bin) (file-executable-p mock))
      (error "The 30-agent fixture needs DRGNX_RATATOSKR_BIN (a test-hooks ratatoskr) with ratatoskr-mock beside it"))
    (setq drgnx-work-thirty--dir (make-temp-file "drgnx-work-thirty" t))
    (let* ((dir drgnx-work-thirty--dir) (desc (drgnx-work-thirty--desc))
           (agents (drgnx-work-thirty-build dir)) (config (expand-file-name "config" dir)) profiles)
      (setq drgnx-work-thirty--agents agents)
      (make-directory config t)
      (dolist (a agents)
        (let ((script (expand-file-name (concat (plist-get a :profile) ".txt") config)))
          (with-temp-file script (insert (plist-get a :line) "\n"))
          (push (list (plist-get a :profile) :command (list mock "acp" "--as" "claude" "--script" script
                                                            "--log" (concat script ".log"))) profiles)))
      (with-temp-file (expand-file-name "settings.el" config)
        (prin1 (list 'drgnx-settings :version 1 (list 'drgnx-agents-profiles (nreverse profiles))) (current-buffer)))
      (let ((process-environment (append (list (concat "DRGNX_CONFIG_DIR=" config) "RATATOSKR_SUPERVISOR=none"
                                               (concat "DRGNX_DIR=" (directory-file-name drgnx-dir)))
                                         process-environment)))
        (setq drgnx-work-thirty--hub
              (make-process :name "ratatoskr" :noquery t :connection-type 'pipe
                            :buffer (generate-new-buffer " *ratatoskr-thirty*")
                            :command (list bin "serve" "--foreground" "--parent-pid" (number-to-string (emacs-pid))))))
      (unless (drgnx-work-thirty--wait 30 #'drgnx-hub-running-p) (error "Ratatoskr did not answer a ping"))
      (drgnx-hub-connect)
      (drgnx-hub-ensure)
      (let ((i 0))
        (dolist (a agents)
          (let ((s (drgnx-agents-mirror-start (plist-get a :profile) (plist-get a :cwd))))
            (unless s (error "Agent %s did not start" (plist-get a :id)))
            (push s drgnx-work-thirty--mirrors)
            (drgnx-agents-send s (drgnx-work-thirty--ask-text desc i (plist-get a :id)))
            (cl-incf i))))
      (setq drgnx-work-thirty--mirrors (nreverse drgnx-work-thirty--mirrors))
      (unless (drgnx-work-thirty--wait 60 (lambda () (seq-every-p (lambda (s) (eq (drgnx-agent-session-status s) 'busy))
                                                                  drgnx-work-thirty--mirrors)))
        (error "Not all 30 agents are streaming: %d busy"
               (seq-count (lambda (s) (eq (drgnx-agent-session-status s) 'busy)) drgnx-work-thirty--mirrors)))
      (setq drgnx-work-thirty--started (float-time))
      drgnx-work-thirty--mirrors)))

(defun drgnx-work-thirty-stop ()
  "End the agents and the hub, drop the mirrors and the fixture's folder."
  (dolist (s drgnx-work-thirty--mirrors) (ignore-errors (drgnx-agents-kill s)))
  (ignore-errors (drgnx-agents-mirror-stop))
  (ignore-errors (drgnx-hub-disconnect))
  (when (process-live-p drgnx-work-thirty--hub)
    (signal-process drgnx-work-thirty--hub 'term)
    (unless (drgnx-work-thirty--wait 10 (lambda () (not (process-live-p drgnx-work-thirty--hub))))
      (signal-process drgnx-work-thirty--hub 'kill)))
  (when (and drgnx-work-thirty--hub (buffer-live-p (process-buffer drgnx-work-thirty--hub)))
    (kill-buffer (process-buffer drgnx-work-thirty--hub)))
  (setq drgnx-work-thirty--hub nil drgnx-work-thirty--mirrors nil drgnx-work-thirty--agents nil
        drgnx-agents--sessions (seq-remove #'drgnx-agent-session-remote drgnx-agents--sessions))
  (when drgnx-work-thirty--dir
    (ignore-errors (delete-directory drgnx-work-thirty--dir t))
    (setq drgnx-work-thirty--dir nil))
  t)

;;;; The map over the fixture

(defvar drgnx-work-space-roots)
(declare-function drgnx-work-space-open "drgnx-work-space")
(declare-function drgnx-work-space-workspace "drgnx-work-space")
(declare-function drgnx-work-space-sync-shown "drgnx-work-space")
(declare-function drgnx-work-client-view-state "drgnx-work-client")
(declare-function drgnx-work-client-live-p "drgnx-work-client")
(declare-function drgnx-work-client-ids "drgnx-work-client")
(declare-function drgnx-work-client-shown-p "drgnx-work-client")
(declare-function drgnx-work-client-counter "drgnx-work-client")
(declare-function drgnx-view-shown-p "drgnx-view")
(declare-function drgnx-modules-report "drgnx-modules")
(defvar drgnx-work-space--view)
(defvar drgnx-view)

(defun drgnx-work-thirty-agent-items (buffer)
  "How many agent items the frame of BUFFER's map holds."
  (let ((state (drgnx-work-client-view-state (buffer-local-value 'drgnx-work-space--view buffer))))
    (if (and state (drgnx-work-client-live-p state))
        (seq-count (lambda (id) (string-prefix-p "agent:" id)) (drgnx-work-client-ids state))
      0)))

(defun drgnx-work-thirty-map (shown)
  "The map of the fixture's workspace: in a window beside the selected one when SHOWN, else open and shown nowhere
(the hub told).  Waits for the frame with 30 agents.  The selected window is the one selected before.  The buffer."
  (unless (eq 'ok (plist-get (cdr (assq 'tools/work-space (drgnx-modules-report))) :status))
    (error "The module tools/work-space is not running"))
  (setq drgnx-work-space-roots drgnx-work-thirty--roots)
  (let* ((editor (selected-window)) (workspace (drgnx-work-space-workspace))
         (buffer (drgnx-work-space-open workspace t)))
    (if shown
        (progn (unless (get-buffer-window buffer) (set-window-buffer (split-window editor nil 'right) buffer))
               (select-window editor))
      (when-let* ((w (get-buffer-window buffer t))) (ignore-errors (delete-window w))))
    (redisplay t)
    (unless (drgnx-work-thirty--wait 60 (lambda ()
                                          (drgnx-work-space-sync-shown) ; tells the hub what the windows show
                                          (>= (drgnx-work-thirty-agent-items buffer) 30)))
      (error "The map holds %d agents, not 30" (drgnx-work-thirty-agent-items buffer)))
    buffer))

(defun drgnx-work-thirty-premise (&optional buffer shown)
  "Whether what a workload measures holds, else an error naming what does not: 30 sessions streaming (busy) and, with
BUFFER, its map holds 30 agents and is shown to the hub when SHOWN, hidden when not."
  (let ((busy (seq-count (lambda (s) (eq (drgnx-agent-session-status s) 'busy)) drgnx-work-thirty--mirrors)))
    (unless (= busy 30)
      (error "Premise: %d of 30 agents are streaming, %.0f s after all were (statuses %S)" busy
             (- (float-time) (or drgnx-work-thirty--started (float-time)))
             (let (l) (dolist (s drgnx-work-thirty--mirrors l)
                        (let ((c (assq (drgnx-agent-session-status s) l)))
                          (if c (cl-incf (cdr c)) (push (cons (drgnx-agent-session-status s) 1) l)))))))
    (when buffer
      (let ((id (buffer-local-value 'drgnx-work-space--view buffer)))
        (unless (>= (drgnx-work-thirty-agent-items buffer) 30)
          (error "Premise: the map holds %d agents" (drgnx-work-thirty-agent-items buffer)))
        (unless (eq (and shown t) (and (drgnx-work-client-shown-p id) t))
          (error "Premise: the map should be %s to the hub" (if shown "shown" "hidden")))
        (unless (eq (and shown t) (and (get-buffer-window buffer t) t))
          (error "Premise: the map should be %s on screen" (if shown "shown" "hidden")))))
    t))

(provide 'work-space-thirty-fixture)
;;; work-space-thirty-fixture.el ends here
