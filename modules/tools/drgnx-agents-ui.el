;;; drgnx-agents-ui.el --- Module tools/agents: the Agents tab, transcripts, answers, edit review -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The right dock's Agents tab lists agent sessions and durable jobs (status, queued messages,
;; context %, what waits for you).  RET opens a session's transcript in the editor: turns, thinking,
;; tool calls with their subagents, plans, and what the agent asks — permissions to answer, edits to
;; review hunk by hunk.  Typing to a busy agent queues; only Stop cancels.  See docs/guide/agents.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'diff)
(require 'diff-mode)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-agents)
(require 'drgnx-jobs)

(declare-function drgnx-wb-area-show "drgnx-area")
(declare-function drgnx-wb-define-tab "drgnx-area")
(declare-function drgnx-wb-place "drgnx-rules")
(declare-function project-root "project")

(defface drgnx-agents-ui-dim '((t :inherit shadow)) "Thoughts and finished tool calls." :group 'drgnx)
(defface drgnx-agents-ui-user '((t :inherit bold)) "What you said." :group 'drgnx)
(defface drgnx-agents-ui-ask '((t :inherit warning)) "What the agent waits for." :group 'drgnx)

(defvar-local drgnx-agents-ui--session nil "The session this transcript shows.")

;;;; The list (Agents tab)

(defvar drgnx-agents-ui--jobs-cache nil "(TIME . JOBS): the list redraws often; jobs are read every 5 s at most.")


(defvar drgnx-agents-list-mode-map
  (let ((m (make-sparse-keymap))) (set-keymap-parent m tabulated-list-mode-map) m)
  "Keys come from the key profiles (command `agents-open').")

(define-derived-mode drgnx-agents-list-mode tabulated-list-mode "Agents"
  "Agent sessions and durable jobs: RET opens one."
  (setq tabulated-list-format [("Name" 26 nil) ("Status" 9 nil) ("Ctx" 5 nil) ("Via" 8 nil) ("Waiting" 0 nil)])
  (add-hook 'tabulated-list-revert-hook (lambda () (setq drgnx-agents-ui--jobs-cache nil)) nil t)   ; g reads jobs now
  (tabulated-list-init-header))

(defun drgnx-agents-ui--waiting (s)
  (string-join (delq nil (list (and (drgnx-agent-session-queue s)
                                    (format "%d queued%s" (length (drgnx-agent-session-queue s))
                                            (if (drgnx-agent-session-paused s) " (paused)" "")))
                               (and (drgnx-agent-session-permissions s) (format "%d to answer" (length (drgnx-agent-session-permissions s))))
                               (and (drgnx-agent-session-reviews s) (format "%d edit to review" (length (drgnx-agent-session-reviews s))))))
               ", "))

(defun drgnx-agents-ui--jobs ()
  (unless (and drgnx-agents-ui--jobs-cache (< (- (float-time) (car drgnx-agents-ui--jobs-cache)) 5))
    (setq drgnx-agents-ui--jobs-cache (cons (float-time) (ignore-errors (drgnx-jobs-list)))))
  (cdr drgnx-agents-ui--jobs-cache))

(defun drgnx-agents-ui--entries ()
  (append
   (mapcar (lambda (s)
             (list s (vector (drgnx-agent-session-name s) (symbol-name (drgnx-agent-session-status s))
                             (if-let* ((p (drgnx-agents-context-percent s))) (format "%d%%" p) "")
                             (pcase (drgnx-agent-session-via s) ('gateway "gateway") ('direct "direct") (_ ""))
                             (drgnx-agents-ui--waiting s))))
           (drgnx-agents-sessions))
   (mapcar (lambda (j)
             (list (plist-get j :id)
                   (vector (concat "job: " (plist-get j :name)) (symbol-name (plist-get j :status)) "" ""
                           (if (plist-get j :exit) (format "exit %s" (plist-get j :exit)) ""))))
           (drgnx-agents-ui--jobs))))

(defun drgnx-agents-ui-list-buffer ()
  (let ((b (get-buffer-create "*drgnx Agents*")))
    (with-current-buffer b
      (unless (derived-mode-p 'drgnx-agents-list-mode) (drgnx-agents-list-mode))
      (setq tabulated-list-entries #'drgnx-agents-ui--entries)
      (tabulated-list-print t))
    b))

(defun drgnx-agents-ui-view ()
  "Show the Agents tab in the right dock."
  (interactive)
  (let ((b (drgnx-agents-ui-list-buffer)))
    (if (fboundp 'drgnx-wb-area-show) (drgnx-wb-area-show 'right 'agents b) (display-buffer b))))

(defun drgnx-agents-ui-open-at-point ()
  "Open the session (its transcript) or job (its log) on this line."
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (cond ((drgnx-agent-session-p id) (drgnx-agents-ui-transcript id))
          ((stringp id) (drgnx-agents-ui-job-log id)))))

;;;; Transcripts

(defvar drgnx-agents-transcript-mode-map
  (let ((m (make-sparse-keymap))) (set-keymap-parent m special-mode-map) m)
  "Keys come from the key profiles (command `agents-reply').")

(define-derived-mode drgnx-agents-transcript-mode special-mode "Agent"
  "A live agent transcript: RET sends (queued while the agent works); Stop cancels; g redraws."
  (setq-local truncate-lines nil
              revert-buffer-function (lambda (&rest _) (drgnx-agents-ui-refresh))))

(defun drgnx-agents-ui--insert-tool (e depth)
  (insert (make-string (* 2 depth) ?\s)
          (propertize (format "⚙ %s [%s]" (or (plist-get e :title) "tool") (or (plist-get e :status) ""))
                      'face (if (equal (plist-get e :status) "completed") 'drgnx-agents-ui-dim 'default))
          "\n")
  (dolist (c (plist-get e :children)) (drgnx-agents-ui--insert-tool c (1+ depth))))

(defun drgnx-agents-ui--button (label action)
  (insert-text-button label 'action (lambda (_) (funcall action)) 'follow-link t))

(defun drgnx-agents-ui-render (s)
  "Insert session S's transcript (and what waits for an answer) at point."
  (when-let* ((cmds (drgnx-agent-session-commands s)))
    (insert (propertize (concat "Commands: " (mapconcat (lambda (c) (concat "/" (plist-get c :name))) cmds " ")) 'face 'drgnx-agents-ui-dim)
            "\n\n"))
  (dolist (e (drgnx-agent-session-entries s))
    (pcase (plist-get e :type)
      ('user (insert (propertize (concat (if (plist-get e :steer) "↪ " "▸ ") (plist-get e :text)) 'face 'drgnx-agents-ui-user) "\n\n"))
      ('agent (insert (plist-get e :text) "\n\n"))
      ('thought (insert (propertize (concat "… " (plist-get e :text)) 'face 'drgnx-agents-ui-dim) "\n"))
      ('tool (drgnx-agents-ui--insert-tool e 0))
      ('plan (dolist (p (plist-get e :entries))
               (insert (pcase (plist-get p :status) ("completed" "☑ ") ("in_progress" "◐ ") (_ "☐ ")) (plist-get p :content) "\n"))
             (insert "\n"))
      ('error (insert (propertize (concat "! " (plist-get e :text)) 'face 'error) "\n"))
      ('stop (when (equal (plist-get e :stop) "cancelled") (insert (propertize "■ stopped\n\n" 'face 'drgnx-agents-ui-dim))))))
  (dolist (p (drgnx-agent-session-permissions s))
    (insert (propertize (format "? %s  " (plist-get p :title)) 'face 'drgnx-agents-ui-ask))
    (dolist (o (plist-get p :options))
      (let ((o o) (p p))
        (drgnx-agents-ui--button (format "[%s]" (plist-get o :name))
                                 (lambda () (drgnx-agents-answer-permission s p (plist-get o :optionId))))
        (insert " ")))
    (insert "\n"))
  (dolist (r (drgnx-agent-session-reviews s))
    (let ((r r))
      (insert (propertize (format "? the agent wants to change %s  " (plist-get r :path)) 'face 'drgnx-agents-ui-ask))
      (drgnx-agents-ui--button "[Review]" (lambda () (drgnx-agents-ui-review s r)))
      (insert "\n")))
  (pcase (drgnx-agent-session-status s)
    ('busy (insert (propertize "working…  " 'face 'drgnx-agents-ui-dim))
           (drgnx-agents-ui--button "[Stop]" (lambda () (drgnx-agents-stop s))))
    ('exited (insert (propertize (format "the agent exited%s\n%s" (if (drgnx-agent-session-exit s) (format " (%s)" (drgnx-agent-session-exit s)) "")
                                         (or (drgnx-agent-session-stderr s) ""))
                                 'face 'error))))
  (when (drgnx-agent-session-queue s)
    (insert (propertize (format "\n%d queued%s:" (length (drgnx-agent-session-queue s))
                                (if (drgnx-agent-session-paused s) " (held by Stop)" ""))
                        'face 'drgnx-agents-ui-dim))
    (when (drgnx-agent-session-paused s)
      (insert " ") (drgnx-agents-ui--button "[Deliver]" (lambda () (drgnx-agents-deliver-queue s))))
    (seq-do-indexed (lambda (text i)
                      (insert "\n  " (propertize text 'face 'drgnx-agents-ui-dim) " ")
                      (drgnx-agents-ui--button "[×]" (lambda () (drgnx-agents-unqueue s i))))
                    (drgnx-agent-session-queue s))))

(defun drgnx-agents-ui--buffer (s) (get-buffer-create (format "*agent: %s*" (drgnx-agent-session-name s))))

(defun drgnx-agents-ui-refresh (&optional s)
  "Redraw the transcript of S (default: this buffer's)."
  (interactive)
  (let* ((s (or s drgnx-agents-ui--session)) (b (and s (get-buffer (format "*agent: %s*" (drgnx-agent-session-name s))))))
    (when (buffer-live-p b)
      (with-current-buffer b
        (let ((at-end (= (point) (point-max))) (pt (point)) (inhibit-read-only t))
          (erase-buffer)
          (drgnx-agents-ui-render s)
          (goto-char (if at-end (point-max) (min pt (point-max)))))))))

(defun drgnx-agents-ui-transcript (s)
  "Show session S's transcript."
  (let ((b (drgnx-agents-ui--buffer s)))
    (with-current-buffer b
      (unless (derived-mode-p 'drgnx-agents-transcript-mode) (drgnx-agents-transcript-mode))
      (setq drgnx-agents-ui--session s))
    (drgnx-agents-ui-refresh s)
    (pop-to-buffer b)
    b))

(defvar drgnx-agents-ui--dirty nil)
(defvar drgnx-agents-ui--timer nil)

(defun drgnx-agents-ui--changed (s)
  "A session changed: redraw its transcript and the list, at most every 0.1 s (from a timer)."
  (cl-pushnew s drgnx-agents-ui--dirty)
  (unless (timerp drgnx-agents-ui--timer)
    (setq drgnx-agents-ui--timer
          (run-with-timer 0.1 nil (lambda ()
                                    (setq drgnx-agents-ui--timer nil)
                                    (let ((dirty drgnx-agents-ui--dirty))
                                      (setq drgnx-agents-ui--dirty nil)
                                      (mapc #'drgnx-agents-ui-refresh dirty))
                                    (when-let* ((b (get-buffer "*drgnx Agents*")))
                                      (with-current-buffer b (tabulated-list-print t))))))))

;;;; Commands

(defun drgnx-agents-ui--session (&optional prompt)
  (or drgnx-agents-ui--session
      (let ((live (drgnx-agents-sessions)))
        (cond ((null live) (user-error "No agent session (Agents: New Session)"))
              ((null (cdr live)) (car live))
              (t (let ((name (completing-read (or prompt "Session: ") (mapcar #'drgnx-agent-session-name live) nil t)))
                   (seq-find (lambda (s) (equal (drgnx-agent-session-name s) name)) live)))))))

(defun drgnx-agents-ui--cwd ()
  (or (when-let* ((p (and (fboundp 'project-current) (project-current)))) (project-root p)) default-directory))

(declare-function drgnx-agents-mirror-sync "drgnx-agents-mirror")
(declare-function drgnx-hub-socket "drgnx-hub")
(declare-function drgnx-hub-ensure "drgnx-hub")
(declare-function drgnx-hub-call-sync "drgnx-hub")

(defun drgnx-agents-ui--maybe-mirror ()
  "At idle: mirror the hub's agent sessions when a hub runs.  Never waits and never starts one: only a socket that
exists is connected to (asynchronously)."
  (require 'drgnx-hub)
  (when (file-exists-p (drgnx-hub-socket))
    (require 'drgnx-agents-mirror)
    (with-demoted-errors "drgnx: the agent hub does not answer: %S" (drgnx-agents-mirror-sync))))

(defun drgnx-agents-ui-new-durable (profile)
  "Start an agent session of PROFILE in this project, held by the hub: it keeps working when Emacs closes."
  (interactive (list (completing-read "Durable agent profile: " (drgnx-agents-profile-names) nil t)))
  (require 'drgnx-agents-mirror)
  (drgnx-hub-ensure)
  (drgnx-agents-mirror-sync)
  (let ((r (drgnx-hub-call-sync "agents/start" (list :profile profile :cwd (drgnx-agents-ui--cwd)))))
    (message "Agent %s started in the hub (it keeps working when Emacs closes)" (plist-get r :name))))

(defun drgnx-agents-ui-new (profile)
  "Start an agent session of PROFILE in this project."
  (interactive (list (completing-read "Agent profile: " (drgnx-agents-profile-names) nil t)))
  (drgnx-agents-ui-transcript (drgnx-agents-start profile (drgnx-agents-ui--cwd))))

(defun drgnx-agents-ui-send (text)
  "Send TEXT to the agent — queued while it works; it never cancels the running turn."
  (interactive (list (read-string (format "To %s: " (drgnx-agent-session-name (drgnx-agents-ui--session))))))
  (drgnx-agents-send (drgnx-agents-ui--session) text))

(defun drgnx-agents-ui-stop ()
  "Stop the agent's running turn (the only thing that cancels)."
  (interactive)
  (drgnx-agents-stop (drgnx-agents-ui--session)))

(defun drgnx-agents-ui-deliver ()
  "Send the messages a Stop held back."
  (interactive)
  (drgnx-agents-deliver-queue (drgnx-agents-ui--session)))

(defun drgnx-agents-ui-take-over (profile session-id)
  "Resume the agent session SESSION-ID with PROFILE here."
  (interactive (list (completing-read "Agent profile: " (drgnx-agents-profile-names) nil t) (read-string "Session id: ")))
  (drgnx-agents-ui-transcript (drgnx-agents-take-over profile (drgnx-agents-ui--cwd) session-id)))

(defun drgnx-agents-ui-answer ()
  "Answer what the agent asks (permission to run a tool)."
  (interactive)
  (let* ((s (drgnx-agents-ui--session)) (p (or (car (drgnx-agent-session-permissions s)) (user-error "Nothing to answer")))
         (choice (completing-read (format "%s: " (plist-get p :title)) (mapcar (lambda (o) (plist-get o :name)) (plist-get p :options)) nil t)))
    (drgnx-agents-answer-permission s p (plist-get (seq-find (lambda (o) (equal (plist-get o :name) choice)) (plist-get p :options)) :optionId))))

(defun drgnx-agents-ui-job-log (id)
  "Show durable job ID's log."
  (interactive (list (completing-read "Job: " (mapcar (lambda (j) (plist-get j :id)) (drgnx-jobs-list)) nil t)))
  (with-current-buffer (get-buffer-create (format "*job: %s*" id))
    (let ((inhibit-read-only t)) (erase-buffer) (insert (drgnx-jobs-log id)))
    (special-mode)
    (pop-to-buffer (current-buffer))))

(defun drgnx-agents-ui-job-stop (id)
  "Stop durable job ID."
  (interactive (list (completing-read "Stop job: " (mapcar (lambda (j) (plist-get j :id))
                                                           (seq-filter (lambda (j) (eq (plist-get j :status) 'running)) (drgnx-jobs-list)))
                                      nil t)))
  (drgnx-jobs-stop id))

;;;; Edit review (the agent's fs/write_text_file)

(defvar-local drgnx-agents-ui--review nil "(SESSION ITEM COPY) this diff answers; COPY takes the hunks you apply.")

(defvar drgnx-agents-review-mode-map (make-sparse-keymap)
  "Keys come from the key profiles (commands `agents-review-done', `agents-review-reject').")

(define-minor-mode drgnx-agents-review-mode
  "An edit an agent proposes: C-c C-a applies a hunk (to a copy of the file), C-c C-c writes what you
applied to the file, C-c C-k rejects — nothing touches the file before Done."
  :lighter " Review")

(defun drgnx-agents-ui-review (s item)
  "Show the change ITEM proposes as a diff against a copy of its file: apply the hunks you want (to
the copy), then Done writes the copy to the file (Reject, or closing the diff, writes nothing)."
  (let* ((path (plist-get item :path))
         (copy (make-temp-file "drgnx-review-" nil (concat "-" (file-name-nondirectory path))))
         (new (make-temp-file "drgnx-proposed-"))
         (cwd (drgnx-agent-session-cwd s)))
    (when (file-exists-p path) (copy-file path copy t))
    (with-temp-file new (insert (plist-get item :content)))
    (let ((b (diff-no-select copy new "-u" t (get-buffer-create (format "*review: %s*" (abbreviate-file-name path))))))
      (delete-file new)                             ; hunks can apply to the copy alone
      (with-current-buffer b
        (drgnx-agents-review-mode 1)
        (setq drgnx-agents-ui--review (list s item copy))
        (setq header-line-format
              (concat (format " %s wants to change %s" (drgnx-agent-session-name s) (abbreviate-file-name path))
                      (if (and cwd (not (file-in-directory-p path cwd))) "  — OUTSIDE the session's project" "")
                      "  (C-c C-a apply a hunk · C-c C-c done · C-c C-k reject)"))
        (add-hook 'kill-buffer-hook #'drgnx-agents-ui--review-killed nil t))
      (pop-to-buffer b)
      b)))

(defun drgnx-agents-ui--review-cleanup (copy)
  (when-let* ((cb (find-buffer-visiting copy))) (with-current-buffer cb (set-buffer-modified-p nil)) (kill-buffer cb))
  (when (file-exists-p copy) (delete-file copy)))

(defun drgnx-agents-ui--review-killed ()
  "A review closed without Done or Reject: the agent hears it was rejected."
  (when drgnx-agents-ui--review
    (pcase-let ((`(,s ,item ,copy) drgnx-agents-ui--review))
      (setq drgnx-agents-ui--review nil)
      (drgnx-agents-ui--review-cleanup copy)
      (when (memq item (drgnx-agent-session-reviews s)) (drgnx-agents-finish-review s item t)))))

(defun drgnx-agents-ui-review-done ()
  "Write what you applied to the file; tell the agent."
  (interactive)
  (pcase-let ((`(,s ,item ,copy) (or drgnx-agents-ui--review (user-error "Not an agent's edit"))))
    (let* ((path (plist-get item :path)) (visiting (find-buffer-visiting path)) (cb (find-buffer-visiting copy)))
      (when (and visiting (buffer-modified-p visiting))
        (user-error "%s has unsaved changes: save or revert them first" (abbreviate-file-name path)))
      (let ((text (if cb (with-current-buffer cb (buffer-substring-no-properties (point-min) (point-max)))
                    (with-temp-buffer (insert-file-contents copy) (buffer-string))))
            (coding (and cb (with-current-buffer cb buffer-file-coding-system))))
        (make-directory (file-name-directory path) t)
        (let ((coding-system-for-write (or coding 'utf-8-unix))) (write-region text nil path nil 'silent))
        (when visiting (with-current-buffer visiting (revert-buffer t t t))))
      (setq drgnx-agents-ui--review nil)
      (drgnx-agents-ui--review-cleanup copy)
      (drgnx-agents-finish-review s item)
      (kill-buffer (current-buffer)))))

(defun drgnx-agents-ui-review-reject ()
  "Reject the agent's edit: the file stays as it is."
  (interactive)
  (pcase-let ((`(,s ,item ,copy) (or drgnx-agents-ui--review (user-error "Not an agent's edit"))))
    (setq drgnx-agents-ui--review nil)
    (drgnx-agents-ui--review-cleanup copy)
    (drgnx-agents-finish-review s item t)
    (kill-buffer (current-buffer))))

(defun drgnx-agents-ui-edit-queued ()
  "Change or remove (empty text) a queued message before it is sent."
  (interactive)
  (let* ((s (drgnx-agents-ui--session)) (q (or (drgnx-agent-session-queue s) (user-error "Nothing queued")))
         (pick (completing-read "Queued message: " q nil t))
         (n (seq-position q pick)))
    (drgnx-agents-requeue s n (read-string "Text (empty: remove): " pick))))

;;;; The module

(drgnx-module-define 'tools/agents
                     :doc "Agents: sessions over ACP in the right dock's Agents tab, durable jobs, edit review."
                     :stage 'startup :requires '(core/workbench)
                     :setup
                     (lambda ()
                       (add-hook 'drgnx-agents-changed-functions #'drgnx-agents-ui--changed)
                       ;; the hub's sessions (they outlive this Emacs), once Emacs is idle
                       (run-with-idle-timer 3 nil #'drgnx-agents-ui--maybe-mirror)
                       (when (fboundp 'drgnx-wb-define-tab) (drgnx-wb-define-tab 'right 'agents :title "Agents"))
                       (when (fboundp 'drgnx-wb-place)
                         (drgnx-wb-place 'drgnx-agents-list-mode 'right :tab 'agents)
                         (drgnx-wb-place '(drgnx-agents-transcript-mode) 'editor)
                         (drgnx-wb-place "\\`\\*\\(review\\|job\\): " 'editor))
                       (pcase-dolist (`(,id ,title ,fn ,doc)
                                      '((agents-view "Show Agents" drgnx-agents-ui-view "Agent sessions and durable jobs, in the right dock")
                                        (agents-new "New Agent Session…" drgnx-agents-ui-new "Start an agent (a profile) in this project")
                                        (agents-new-durable "New Durable Agent Session…" drgnx-agents-ui-new-durable
                                                            "An agent held by the hub: it keeps working when Emacs closes")
                                        (agents-send "Send to Agent…" drgnx-agents-ui-send "Queued while the agent works; never cancels")
                                        (agents-stop "Stop Agent" drgnx-agents-ui-stop "Cancel the running turn (the only thing that does)")
                                        (agents-deliver "Deliver Queued Messages" drgnx-agents-ui-deliver "Send what a Stop held back")
                                        (agents-edit-queued "Edit Queued Message…" drgnx-agents-ui-edit-queued "Change or remove a message before it is sent")
                                        (agents-take-over "Take Over Agent Session…" drgnx-agents-ui-take-over "Resume a session by its id")
                                        (agents-answer "Answer Agent…" drgnx-agents-ui-answer "Allow or reject what the agent asks")
                                        (jobs-log "Show Job Log…" drgnx-agents-ui-job-log "A durable job's output")
                                        (jobs-stop "Stop Job…" drgnx-agents-ui-job-stop "Stop a durable job")))
                         (drgnx-command-define id :category "Agents" :title title :command fn :doc doc))
                       (drgnx-command-define 'agents-open :category "Agents" :title "Open" :command #'drgnx-agents-ui-open-at-point
                                             :map 'drgnx-agents-list-mode-map :doc "The session's transcript, or the job's log")
                       (drgnx-command-define 'agents-reply :category "Agents" :title "Reply" :command #'drgnx-agents-ui-send
                                             :map 'drgnx-agents-transcript-mode-map :doc "Send to this agent (queued while it works)")
                       (drgnx-command-define 'agents-review-done :category "Agents" :title "Done Reviewing" :command #'drgnx-agents-ui-review-done
                                             :map 'drgnx-agents-review-mode-map :doc "Keep the hunks you applied; tell the agent")
                       (drgnx-command-define 'agents-review-reject :category "Agents" :title "Reject Edit" :command #'drgnx-agents-ui-review-reject
                                             :map 'drgnx-agents-review-mode-map :doc "Tell the agent the edit was rejected")))

(provide 'drgnx-agents-ui)
;;; drgnx-agents-ui.el ends here
