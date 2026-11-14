;;; agents-editor-five-fixture.el --- five mock agents in a real hub, editing the file you type in -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The session side of the agents-in-the-editor budget rows (docs/develop/perf.md, "The agents-in-the-editor workloads"):
;; a repository with one 3,000-line file (`src/main.el'), a worktree for each of five agents, and a hub of the session's
;; own (`$DRGNX_RATATOSKR_BIN', a test-hooks build, with `ratatoskr-mock' beside it).  Each agent is a `ratatoskr-mock
;; acp' whose script edits `src/main.el' in its worktree every half second (`provider:edit-stream', a different line each time) and reads it
;; between the edits; with PAIR the fifth is a chat that edits the user's file itself through the drgnx tool `edit_file'
;; (so the editor applies it) and a stale whole-file write every ten edits.  `drgnx-agents-five-premise' says whether what
;; a workload measures holds: it signals when it does not.  The mock agents only; nothing here reaches a subscription.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-paths)

(defconst drgnx-agents-five-lines 3000 "The lines of the file the user types in.")
(defconst drgnx-agents-five-seconds 600 "How long the agents go on: an edit about every half second.")

(defvar drgnx-agents-five--dir nil "The temp directory: the repository, the worktrees, the hub's settings.")
(defvar drgnx-agents-five--hub nil "The hub process.")
(defvar drgnx-agents-five--mirrors nil "The five session mirrors.")
(defvar drgnx-agents-five--pair nil "Whether the fifth agent is the paired chat.")
(defvar drgnx-agents-five--file nil "The user's file: `src/main.el' in the repository.")
(defvar drgnx-agents-five--editor nil "The window the keys are typed in.")

(defvar drgnx-agents-five--events nil "Newest first: (SECONDS-SINCE-START WHAT) for the premise's failure message.")
(defvar drgnx-agents-five--t0 nil "When `drgnx-agents-five-start' began (float seconds).")
(defvar drgnx-agents-five--last (make-hash-table :test #'eq) "Session -> the last status noted.")

(defun drgnx-agents-five--note (what)
  (push (list (round (* 10 (- (float-time) (or drgnx-agents-five--t0 (float-time)))) ) what) drgnx-agents-five--events))

(defun drgnx-agents-five--changed (s)
  "`drgnx-agents-changed-functions': note a session's change of status (the turns' ends and starts)."
  (let ((st (drgnx-agent-session-status s)))
    (unless (eq st (gethash s drgnx-agents-five--last))
      (puthash s st drgnx-agents-five--last)
      (drgnx-agents-five--note (format "%s %s" (drgnx-agent-session-name s) st)))))

(defun drgnx-agents-five--wait (secs pred)
  "Let the session run until PRED holds (at most SECS s); whether it does."
  (let ((d (+ (float-time) secs)))
    (while (and (not (funcall pred)) (< (float-time) d)) (accept-process-output nil 0.05))
    (and (funcall pred) t)))

(defun drgnx-agents-five--git (dir &rest args)
  (let ((default-directory (file-name-as-directory dir)))
    (unless (zerop (apply #'call-process "git" nil nil nil "-c" "user.name=perf" "-c" "user.email=perf@localhost"
                          "-c" "commit.gpgsign=false" args))
      (error "git %S failed in %s" args dir))))

(defun drgnx-agents-five--program (i pair)
  "Agent I's turn as the mock reads it: one line, `\\n' between the words.  The paired chat (PAIR, the fifth) edits the
user's file through the drgnx tool (and writes it whole from a stale read every 5 s); the others edit their own
worktree's copy."
  (let ((words
         (if (and pair (= i 5))
             ;; an edit every 2.5 s through the drgnx tool, and every second one (so every 5 s) a stale whole-file write
             ;; from a read the hub never served: the hub refuses it whole (U1), so it never reaches the editor's count
             (cl-loop for n from 1 to (/ drgnx-agents-five-seconds 2)
                      append (append
                              (list (format "call:edit_file {\"path\": %S, \"old\": \"five-var-%d=%d\", \"new\": \"five-var-%d=%d\"}"
                                            drgnx-agents-five--file (* n 7) (* n 7) (* n 7) (1+ (* n 7))))
                              (and (zerop (% n 2))
                                   (list (format "call:write_file {\"path\": %S, \"content\": \"stale %d\\n\"}"
                                                 drgnx-agents-five--file n)))
                              (list "silent 2.5")))
           ;; exactly the shape of the thirty-agent fixture's turns (proven there): one edit of the file in the agent's own
           ;; worktree (`tool:edit' appends a line), then a chunk, a read of another offset (a step that moves the agent's
           ;; cursor; the hub pauses an agent that repeats a call, so no two reads are the same) and a second of quiet
           (append (list "say starting" "tool:edit src/main.el")
                   (cl-loop for n from 1 to drgnx-agents-five-seconds
                            append (list "say still working on it, a line a second"
                                         (format "provider:read src/main.el %d 1" (+ n (* 100 i)))
                                         "silent 1"))))))
    (mapconcat #'identity words "\\n")))

(defun drgnx-agents-five--build (dir)
  "The repository with the 3,000-line file and a worktree for each of five agents under DIR."
  (let ((repo (expand-file-name "project" dir)))
    (make-directory (expand-file-name "src" repo) t)
    (setq drgnx-agents-five--file (expand-file-name "src/main.el" repo))
    (with-temp-file drgnx-agents-five--file
      (dotimes (n drgnx-agents-five-lines) (insert (format "five-var-%d=%d\n" n n))))
    (drgnx-agents-five--git repo "init" "-q" "-b" "main")
    (drgnx-agents-five--git repo "add" "src")
    (drgnx-agents-five--git repo "commit" "-q" "-m" "init")
    (cl-loop for i from 1 to 5
             collect (let ((wt (expand-file-name (format "wt-%d" i) dir)))
                       (drgnx-agents-five--git repo "worktree" "add" "-q" "-b" (format "agent-%d" i) wt)
                       wt))))

(defun drgnx-agents-five-start (bin &optional pair)
  "Build the fixture, start a hub of BIN, five agents (with PAIR the fifth a paired chat) and wait until all are busy.
Returns the mirrors."
  (require 'drgnx-agents-mirror)
  (require 'drgnx-hub-client)
  (let ((mock (and bin (expand-file-name "ratatoskr-mock" (file-name-directory bin)))))
    (unless (and mock (file-executable-p bin) (file-executable-p mock))
      (error "The agents-in-the-editor workloads need DRGNX_RATATOSKR_BIN (a test-hooks ratatoskr) with ratatoskr-mock beside it"))
    (setq drgnx-agents-five--dir (make-temp-file "drgnx-agents-five" t) drgnx-agents-five--pair pair
          drgnx-agents-five--t0 (float-time) drgnx-agents-five--events nil)
    (clrhash drgnx-agents-five--last)
    (add-hook 'drgnx-agents-changed-functions #'drgnx-agents-five--changed)
    (let* ((dir drgnx-agents-five--dir) (trees (drgnx-agents-five--build dir)) (config (expand-file-name "config" dir)) profiles)
      (make-directory config t)
      (cl-loop for i from 1 to 5
               do (let ((script (expand-file-name (format "agent-%d.txt" i) config)))
                    (with-temp-file script (insert (drgnx-agents-five--program i pair) "\n"))
                    (push (list (format "mock-%d" i) :command (list mock "acp" "--as" "claude" "--script" script "--log" (concat script ".log"))) profiles)))
      (with-temp-file (expand-file-name "settings.el" config)
        (prin1 (list 'drgnx-settings :version 1 (list 'drgnx-agents-profiles (nreverse profiles))) (current-buffer)))
      (let ((process-environment (append (list (concat "DRGNX_CONFIG_DIR=" config) "RATATOSKR_SUPERVISOR=none"
                                               (concat "DRGNX_DIR=" (directory-file-name drgnx-dir)))
                                         process-environment)))
        (setq drgnx-agents-five--hub
              (make-process :name "ratatoskr" :noquery t :connection-type 'pipe
                            :buffer (generate-new-buffer " *ratatoskr-five*")
                            :command (list bin "serve" "--foreground" "--parent-pid" (number-to-string (emacs-pid))))))
      (unless (drgnx-agents-five--wait 30 #'drgnx-hub-running-p) (error "Ratatoskr did not answer a ping"))
      (drgnx-hub-connect)
      (drgnx-hub-ensure)
      (cl-loop for i from 1 to 5 for wt in trees
               do (let ((s (drgnx-agents-mirror-start (format "mock-%d" i) (if (and pair (= i 5)) (expand-file-name "project" dir) wt))))
                    (unless s (error "Agent %d did not start" i))
                    (push s drgnx-agents-five--mirrors)
                    (drgnx-agents-send s "go")))
      (setq drgnx-agents-five--mirrors (nreverse drgnx-agents-five--mirrors))
      (when pair
        (drgnx-hub-call-sync "agents/pair" (list :id (drgnx-agent-session-remote (nth 4 drgnx-agents-five--mirrors)) :on t)))
      (unless (drgnx-agents-five--wait 60 (lambda () (seq-every-p (lambda (s) (eq (drgnx-agent-session-status s) 'busy))
                                                                  drgnx-agents-five--mirrors)))
        (error "Not all five agents are streaming: %d busy"
               (seq-count (lambda (s) (eq (drgnx-agent-session-status s) 'busy)) drgnx-agents-five--mirrors)))
      drgnx-agents-five--mirrors)))

(defun drgnx-agents-five-visit ()
  "Visit the user's file in the selected window, with the change marks on when the module is loaded; the buffer."
  (drgnx-agents-five--note "visit")
  ;; the keys a workload types go to the editor window, never to a follow window (its keys stop and take the wheel)
  (unless (window-live-p drgnx-agents-five--editor) (setq drgnx-agents-five--editor (selected-window)))
  (select-window drgnx-agents-five--editor)
  (let ((b (find-file-noselect drgnx-agents-five--file)))
    (switch-to-buffer b)
    (goto-char (point-min))
    (forward-line (/ drgnx-agents-five-lines 2))
    (when (fboundp 'drgnx-hunks-mode) (drgnx-hunks-mode 1))
    b))

(defun drgnx-agents-five-follow ()
  "A follow window on the second agent."
  (require 'drgnx-agents-follow)
  (drgnx-agents-five--note "follow starts")
  (drgnx-agents-follow-start (drgnx-agent-session-remote (nth 1 drgnx-agents-five--mirrors))))

(defun drgnx-agents-five-premise ()
  "Signals unless the five agents are streaming (and the file is the one typed in); t."
  (unless (and drgnx-agents-five--mirrors
               (= 5 (seq-count (lambda (s) (eq (drgnx-agent-session-status s) 'busy)) drgnx-agents-five--mirrors)))
    (error "Premise: %d of 5 agents are streaming: %S; timeline in tenths of a second since the start: %S; agent 1 exit/entries %S stderr %S; its mock log has %d lines, last %S"
           (seq-count (lambda (s) (eq (drgnx-agent-session-status s) 'busy)) drgnx-agents-five--mirrors)
           (mapcar #'drgnx-agent-session-status drgnx-agents-five--mirrors)
           (reverse (seq-take drgnx-agents-five--events 60))
           (list (drgnx-agent-session-exit (car drgnx-agents-five--mirrors))
                 (mapcar (lambda (e) (truncate-string-to-width (format "%S" e) 240))
                         (last (append (plist-get (drgnx-hub-call-sync "agents/get" (list :id (drgnx-agent-session-remote (car drgnx-agents-five--mirrors))))
                                                  :entries)
                                       nil)
                               4)))
           (let ((e (drgnx-agent-session-stderr (car drgnx-agents-five--mirrors)))) (if (stringp e) (substring e (max 0 (- (length e) 300))) e))
           (let ((log (expand-file-name "config/agent-1.txt.log" drgnx-agents-five--dir)))
             (if (file-exists-p log) (with-temp-buffer (insert-file-contents log) (count-lines (point-min) (point-max))) 0))
           (let ((log (expand-file-name "config/agent-1.txt.log" drgnx-agents-five--dir)))
             (if (file-exists-p log)
                 (with-temp-buffer (insert-file-contents log)
                                   (mapconcat (lambda (l) (truncate-string-to-width l 160)) (split-string (buffer-string) "\n" t) " | "))
               "no log"))))
  (unless (file-exists-p drgnx-agents-five--file) (error "Premise: the fixture's file is gone"))
  t)

(defvar drgnx-agent-pair--answers)

(defun drgnx-agents-five-pair-applied-ratio ()
  "The share of the paired chat's writes the editor answered `applied' (1.0 with none answered yet)."
  (let ((all 0) (applied 0))
    (when (boundp 'drgnx-agent-pair--answers)
      (maphash (lambda (_ a) (cl-incf all) (when (equal (plist-get a :result) "applied") (cl-incf applied)))
               drgnx-agent-pair--answers))
    (if (zerop all) 1.0 (/ (float applied) all))))

(defun drgnx-agents-five-stop ()
  "End the agents and the hub, drop the mirrors, the buffer and the fixture's folder."
  (remove-hook 'drgnx-agents-changed-functions #'drgnx-agents-five--changed)
  (ignore-errors (when (fboundp 'drgnx-agents-follow-stop) (drgnx-agents-follow-stop)))
  (dolist (s drgnx-agents-five--mirrors) (ignore-errors (drgnx-agents-kill s)))
  (ignore-errors (drgnx-agents-mirror-stop))
  (ignore-errors (drgnx-hub-disconnect))
  (when (process-live-p drgnx-agents-five--hub)
    (signal-process drgnx-agents-five--hub 'term)
    (unless (drgnx-agents-five--wait 10 (lambda () (not (process-live-p drgnx-agents-five--hub))))
      (signal-process drgnx-agents-five--hub 'kill)))
  (when (and drgnx-agents-five--hub (buffer-live-p (process-buffer drgnx-agents-five--hub)))
    (kill-buffer (process-buffer drgnx-agents-five--hub)))
  (when-let* ((b (and drgnx-agents-five--file (find-buffer-visiting drgnx-agents-five--file))))
    (with-current-buffer b (set-buffer-modified-p nil))
    (kill-buffer b))
  (setq drgnx-agents-five--hub nil drgnx-agents-five--mirrors nil drgnx-agents-five--editor nil
        drgnx-agents--sessions (seq-remove #'drgnx-agent-session-remote drgnx-agents--sessions))
  (when drgnx-agents-five--dir
    (ignore-errors (delete-directory drgnx-agents-five--dir t))
    (setq drgnx-agents-five--dir nil))
  t)

(provide 'agents-editor-five-fixture)
;;; agents-editor-five-fixture.el ends here
