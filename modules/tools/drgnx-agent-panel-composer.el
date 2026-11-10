;;; drgnx-agent-panel-composer.el --- The agent panel's composer and steering queue (library of tools/agent-panel) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Under the transcript: the steering queue (the notes waiting for the turn to end, each editable until it is sent),
;; and the composer.  `s' writes to the agent: a message sent while it works is queued, never a cancel.  `x' stops it
;; (after a confirmation line), `p' stops it after its current step, `u' resumes it.  `@file' and `/command' complete
;; in the composer from the session's folder and the snapshot's commands.  The Pair chip shows the snapshot's `paired'
;; and `waiting' and runs `agents-pair' when that command exists; else it is not there.
;; Loaded by tools/agent-panel (drgnx-agent-panel.el); defines no module.  See docs/guide/agent-panel.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-view)
(require 'drgnx-registry)
(require 'drgnx-ui-kit)                 ; the bar's buttons
(require 'drgnx-pixels)
(require 'drgnx-icons)

(defvar drgnx-agent-panel--session)
(defvar drgnx-agent-panel--snap)
(defvar drgnx-agent-panel--shown-keys)
(defvar drgnx-agent-panel-mode-map)
(defvar drgnx-work-resume-text)
(declare-function drgnx-agent-panel--ask "drgnx-agent-panel")
(declare-function drgnx-agent-panel--one-line "drgnx-agent-panel")
(declare-function drgnx-history-fork-here "drgnx-history-revert")
(defvar drgnx-agent-panel--steps)

(defconst drgnx-agent-panel-composer-max-files 2000 "How many files `@' completion looks through at most.")

(defun drgnx-agent-panel-composer--queue ()
  "The notes waiting in the snapshot, a list of strings."
  (append (plist-get drgnx-agent-panel--snap :queue) nil))

(defun drgnx-agent-panel-composer-keys ()
  "The rows under the transcript: a row for each queued note, then the composer."
  (append (cl-loop for _ in (drgnx-agent-panel-composer--queue) for n from 0 collect (list :q n))
          (list (list :composer))))

(defun drgnx-agent-panel-composer-redraw ()
  "The snapshot changed: the queued notes and the composer are drawn again."
  (when (drgnx-view-p drgnx-view)
    (drgnx-view-dirty drgnx-view
                      (cons (list :composer)
                            (seq-filter (lambda (k) (eq (car-safe k) :q)) (hash-table-keys drgnx-agent-panel--shown-keys))))))

;;;; Rows

(defun drgnx-agent-panel-composer--queue-row (n)
  (propertize (format "  ⏸ queued %d  %s   (e edit · d drop)\n" (1+ n)
                      (drgnx-agent-panel--one-line (nth n (drgnx-agent-panel-composer--queue)) 60))
              'face 'drgnx-agent-panel-subtle))

(defun drgnx-agent-panel-composer--pair-chip ()
  "The Pair chip, or nil when `agents-pair' is not a command."
  (when (drgnx-commands-get 'agents-pair)
    (let ((paired (plist-get drgnx-agent-panel--snap :paired)) (waiting (plist-get drgnx-agent-panel--snap :waiting)))
      (propertize (format " Pair%s " (cond ((and waiting (not (eq waiting :json-false))) " · waiting for you")
                                           ((and paired (not (eq paired :json-false))) " · on")
                                           (t "")))
                  'face 'drgnx-agent-panel-chip))))

(defun drgnx-agent-panel-composer--click (text command face &optional help)
  "TEXT in FACE (nil: its own faces) that runs COMMAND (a registry command) when clicked."
  (let ((map (make-sparse-keymap)) (s (copy-sequence text)))
    (define-key map [mouse-1] command)
    (when face (add-face-text-property 0 (length s) face nil s))
    (add-text-properties 0 (length s) (list 'mouse-face 'drgnx-hover 'keymap map 'help-echo help) s)
    s))

(defun drgnx-agent-panel-composer--field ()
  "The composer's field: one card line to the panel's right edge (12 px in), in one face, since a box is drawn per run
of one face; a click writes to the agent."
  (let ((s (concat " Steer the agent…  (@ file, / command)"
                   (propertize " " 'display `(space :align-to (- right (,(drgnx-px 12))))))))
    (add-face-text-property 0 (length s) '(drgnx-agent-panel-subtle drgnx-card-single) nil s)
    (concat (drgnx-agent-panel-composer--click s #'drgnx-agent-panel-send nil "s: write to the agent") "\n")))

(defun drgnx-agent-panel-fork ()
  "Start a second agent from the chat's last step: the composer's Fork (Fork from the Step at Point picks another)."
  (interactive)
  (let ((seq (and (hash-table-p drgnx-agent-panel--steps)
                  (car (sort (hash-table-keys drgnx-agent-panel--steps) #'>)))))
    (unless seq (user-error "The chat has no step to fork from yet"))
    (require 'drgnx-history-revert)
    (drgnx-history-fork-here drgnx-agent-panel--session seq)))

(defun drgnx-agent-panel-composer--row ()
  "The composer (agent-panel.html `.composer'): the field's card, where a click writes to the agent, and under it the
bar: the model and the mode as chips that switch them, Pair when it is a command, then Fork, the pause icon (stop after
this step) and Send, an arrow, as buttons.
The bar sits under the card, not in it: its chips and buttons have boxes of their own."
  (let* ((snap drgnx-agent-panel--snap) (model (plist-get snap :model)) (mode (plist-get snap :mode))
         (pair (drgnx-agent-panel-composer--pair-chip))
         (buttons (concat (drgnx-agent-panel-composer--click (concat " " (drgnx-look-icon 'git-fork) " Fork ")
                                                             #'drgnx-agent-panel-fork 'drgnx-ui-button
                                                             "Start a second agent from the chat's last step")
                          " "
                          (drgnx-agent-panel-composer--click (concat " " (drgnx-look-icon 'pause) " ") #'drgnx-agent-panel-pause
                                                             'drgnx-ui-button "p: stop the agent after its current step")
                          " "
                          (drgnx-agent-panel-composer--click (concat " " (drgnx-look-icon 'arrow-up) " ")
                                                             #'drgnx-agent-panel-send 'drgnx-ui-button-primary
                                                             "s: write to the agent; while it works it is queued")))
         (bar (concat (if (stringp model)
                          (concat (drgnx-agent-panel-composer--click (concat " " (drgnx-look-icon 'sparkle) " " model " ")
                                                                     #'drgnx-agent-panel-switch-model
                                                                     'drgnx-agent-panel-chip "Switch the model")
                                  " ")
                        "")
                      (if mode
                          (concat (drgnx-agent-panel-composer--click (format " %s ▾ " mode) #'drgnx-agent-panel-switch-mode
                                                                     'drgnx-agent-panel-chip "Switch the mode")
                                  " ")
                        "")
                      (or pair "")
                      (propertize " " 'display `(space :align-to (- right (,(+ (string-pixel-width buttons) (drgnx-px 20))))))
                      buttons)))
    (concat (drgnx-agent-panel-composer--field) " " bar "\n")))

;;;; Completion in the composer

(defun drgnx-agent-panel-composer--command-names ()
  (delq nil (mapcar (lambda (c) (cond ((stringp c) c) ((consp c) (let ((n (plist-get c :name))) (and (stringp n) n)))))
                    (append (plist-get drgnx-agent-panel--snap :commands) nil))))

(defun drgnx-agent-panel-composer--files (dir)
  "Files under DIR, relative, at most `drgnx-agent-panel-composer-max-files', without dot folders."
  (when (and (stringp dir) (file-directory-p dir) (not (file-remote-p dir)))
    (let ((n 0) out)
      (catch 'done
        (dolist (f (directory-files-recursively dir "" nil (lambda (d) (not (string-prefix-p "." (file-name-nondirectory d))))))
          (unless (string-prefix-p "." (file-name-nondirectory f))
            (push (file-relative-name f dir) out)
            (when (> (cl-incf n) drgnx-agent-panel-composer-max-files) (throw 'done nil)))))
      (nreverse out))))

(defun drgnx-agent-panel-composer--capf (names files)
  "A completion-at-point function: `/' completes NAMES at the start of the text, `@' completes FILES anywhere."
  (lambda ()
    (let ((end (point)) (beg (save-excursion (skip-chars-backward "^ \t\n") (point))))
      (cond ((and (< beg end) (eq (char-after beg) ?@))
             (list (1+ beg) end files :exclusive 'no))
            ((and (< beg end) (eq (char-after beg) ?/) (= beg (minibuffer-prompt-end)))
             (list (1+ beg) end names :exclusive 'no))))))

(defun drgnx-agent-panel-composer--read (prompt)
  "Read a message in the minibuffer with `@file' and `/command' completion."
  (let ((names (drgnx-agent-panel-composer--command-names))
        (files (drgnx-agent-panel-composer--files (plist-get drgnx-agent-panel--snap :cwd))))
    (minibuffer-with-setup-hook
        (lambda ()
          (add-hook 'completion-at-point-functions (drgnx-agent-panel-composer--capf names files) nil t))
      (read-string prompt))))

;;;; Commands

(defun drgnx-agent-panel-composer--send-text (text)
  "Send TEXT to the session: the hub queues it while the agent works.  Never a cancel."
  (when (equal (format "%s" (plist-get drgnx-agent-panel--snap :mode)) "interrupt")
    (user-error "This agent's mode would cancel its turn for a message; change its mode first"))
  (let ((busy (equal (format "%s" (plist-get drgnx-agent-panel--snap :status)) "busy")))
    (drgnx-agent-panel--ask "agents/send" (list :id drgnx-agent-panel--session :text text))
    (message (if busy "Agent: queued, it goes in after the current turn" "Agent: sent"))))

(defun drgnx-agent-panel-send ()
  "Write to the agent.  While it works the message is queued; it is not cancelled."
  (interactive)
  (let ((text (string-trim (drgnx-agent-panel-composer--read "To the agent: "))))
    (unless (string-empty-p text) (drgnx-agent-panel-composer--send-text text))))

(defun drgnx-agent-panel-stop ()
  "Stop the agent, after a confirmation line: its turn ends after its current step."
  (interactive)
  (when (y-or-n-p "Stop the agent? Its turn stops after the current step ")
    (drgnx-agent-panel--ask "agents/stop" (list :id drgnx-agent-panel--session))))

(defun drgnx-agent-panel-pause ()
  "Stop the agent after its current step and hold its queue; `u' resumes."
  (interactive)
  (drgnx-agent-panel--ask "agents/pause" (list :id drgnx-agent-panel--session))
  (message "Agent: stops after its current step · u resume"))

(defun drgnx-agent-panel-resume ()
  "Resume the agent with a plain continue prompt."
  (interactive)
  (drgnx-agent-panel--ask "agents/send"
                          (list :id drgnx-agent-panel--session
                                :text (if (boundp 'drgnx-work-resume-text) drgnx-work-resume-text "Please continue.")))
  (message "Agent: resumed"))

(defun drgnx-agent-panel-composer--queue-index ()
  (let ((key (and (drgnx-view-p drgnx-view) (drgnx-view-key-at))))
    (unless (eq (car-safe key) :q) (user-error "Point is not on a queued note"))
    (cadr key)))

(defun drgnx-agent-panel-edit-queued ()
  "Edit the queued note at point, until it is sent."
  (interactive)
  (let* ((n (drgnx-agent-panel-composer--queue-index))
         (text (read-string "Queued note: " (nth n (drgnx-agent-panel-composer--queue)))))
    (drgnx-agent-panel--ask "agents/do" (list :id drgnx-agent-panel--session :op "requeue" :n n :text text))))

(defun drgnx-agent-panel-drop-queued ()
  "Take the queued note at point out of the queue."
  (interactive)
  (drgnx-agent-panel--ask "agents/do" (list :id drgnx-agent-panel--session :op "unqueue"
                                            :n (drgnx-agent-panel-composer--queue-index))))

(defun drgnx-agent-panel-pair ()
  "Pair mode for this agent: runs `agents-pair'."
  (interactive)
  (if-let* ((cmd (drgnx-commands-get 'agents-pair)))
      (call-interactively (drgnx-cmd-command cmd))
    (user-error "Pair mode is not available")))

;;;; Session control: start, move, compact, mode and model

(declare-function drgnx-agent-panel-open "drgnx-agent-panel")
(declare-function drgnx-agents-profile-names "drgnx-agents")
(declare-function drgnx-agent-panel-explain--fresh "drgnx-agent-panel-explain")
(declare-function drgnx-agents-hooks--preview-text "drgnx-agents-hooks")

(defun drgnx-agent-panel--say (method)
  "A callback that says how METHOD went."
  (lambda (_r err) (message "%s" (if err (format "%s: %s" method err) (format "%s: done" method)))))

(defun drgnx-agent-panel--fact (facts name)
  (plist-get (seq-find (lambda (f) (equal (plist-get f :name) name)) (append facts nil)) :value))

(defun drgnx-agent-panel--offer-modes (buffer facts)
  "Offer the modes FACTS (the hub's `agents/explain' for mode) allow switching to, and switch to the one you choose.
When the lock allows none, say why (the hub's reason)."
  (let* ((allowed (drgnx-agent-panel--fact facts "allowed switches"))
         (modes (unless (member allowed '(nil "none")) (split-string allowed ", " t))))
    (unless modes
      (user-error "No mode switch is allowed here: %s"
                  (or (drgnx-agent-panel--fact facts "other modes are refused because") "this agent's lock allows none")))
    (let ((mode (completing-read "Switch mode to: " modes nil t)))
      (with-current-buffer buffer
        (drgnx-agent-panel--ask "agents/config" (list :id drgnx-agent-panel--session :option "mode" :value mode)
                                (drgnx-agent-panel--say "agents/config"))))))

(defun drgnx-agent-panel-switch-mode ()
  "Switch the agent's mode, to one its lock allows (the hub says which, and why the others are not offered)."
  (interactive)
  (let ((buffer (current-buffer)))
    (drgnx-agent-panel--ask "agents/explain" (list :id drgnx-agent-panel--session :item "mode")
                            (lambda (r err)
                              (if err (message "agents/explain: %s" err)
                                (drgnx-agent-panel--offer-modes buffer (plist-get r :facts)))))))

(defun drgnx-agent-panel-switch-model ()
  "Switch the agent's model; the agent refuses one it does not have, and the panel says so."
  (interactive)
  (let ((model (string-trim (read-string "Model: " (plist-get drgnx-agent-panel--snap :model)))))
    (unless (string-empty-p model)
      (drgnx-agent-panel--ask "agents/config" (list :id drgnx-agent-panel--session :option "model" :value model)
                              (drgnx-agent-panel--say "agents/config")))))

(defun drgnx-agent-panel--other-profiles ()
  (require 'drgnx-agents)
  (seq-remove (lambda (n) (equal n (plist-get drgnx-agent-panel--snap :profile))) (drgnx-agents-profile-names)))

(defun drgnx-agent-panel-move ()
  "Move this session to another profile: it stops after its tool call and the new agent continues in the same worktree."
  (interactive)
  (let ((profile (completing-read "Move to profile: " (drgnx-agent-panel--other-profiles) nil t)))
    (when (y-or-n-p (format "Move to %s? The agent stops after its current tool call " profile))
      (drgnx-agent-panel--ask "agents/move" (list :id drgnx-agent-panel--session :profile profile)
                              (lambda (r err)
                                (if err (message "agents/move: %s" err)
                                  (drgnx-agent-panel-open (plist-get r :id))))))))

(defun drgnx-agent-panel-start ()
  "Start another agent in this session's folder and open its panel."
  (interactive)
  (require 'drgnx-agents)
  (let ((profile (completing-read "Start profile: " (drgnx-agents-profile-names) nil t))
        (cwd (plist-get drgnx-agent-panel--snap :cwd)))
    (drgnx-agent-panel--ask "agents/start" (append (list :profile profile) (and cwd (list :cwd cwd)))
                            (lambda (r err)
                              (if err (message "agents/start: %s" err)
                                (drgnx-agent-panel-open (plist-get r :id)))))))

(defun drgnx-agent-panel--compact-after-preview (buffer preview)
  "Show PREVIEW, what a compaction would free and keep, and send /compact to BUFFER's agent when you agree."
  (with-current-buffer (drgnx-agent-panel-explain--fresh "*agent compact preview*")
    (let ((inhibit-read-only t)) (insert (drgnx-agents-hooks--preview-text preview)))
    (special-mode)
    (display-buffer (current-buffer)))
  (when (y-or-n-p "Compact now? ")
    (with-current-buffer buffer (drgnx-agent-panel-composer--send-text "/compact"))))

(defun drgnx-agent-panel-compact ()
  "Compact the agent's context (`/compact').  An agent that can say what it keeps shows that first."
  (interactive)
  (let ((buffer (current-buffer)))
    (if (member "compact-preview" (append (plist-get (plist-get drgnx-agent-panel--snap :panel) :features) nil))
        (drgnx-agent-panel--ask "agents/compact-preview" (list :id drgnx-agent-panel--session)
                                (lambda (r err)
                                  (if err (message "agents/compact-preview: %s" err)
                                    (drgnx-agent-panel--compact-after-preview buffer r))))
      (when (y-or-n-p "Compact the agent's context? ")
        (drgnx-agent-panel-composer--send-text "/compact")))))

(defun drgnx-agent-panel-composer-setup ()
  (dolist (c '((agents-panel-send "Write to the Agent" drgnx-agent-panel-send
                                  "A message to the agent; while it works it is queued, never a cancel")
               (agents-panel-stop "Stop the Agent" drgnx-agent-panel-stop
                                  "Stop the agent after a confirmation line; its turn stops after the current step")
               (agents-panel-pause "Stop the Agent After This Step" drgnx-agent-panel-pause
                                   "Hold the agent after its current step; the queue waits")
               (agents-panel-resume "Resume the Agent" drgnx-agent-panel-resume "A plain continue prompt")
               (agents-panel-edit-queued "Edit the Queued Note" drgnx-agent-panel-edit-queued
                                         "Change the queued note at point until it is sent")
               (agents-panel-drop-queued "Drop the Queued Note" drgnx-agent-panel-drop-queued
                                         "Take the queued note at point out of the queue")
               (agents-panel-fork "Fork the Chat" drgnx-agent-panel-fork
                                  "Start a second agent from the chat's last step (the composer's Fork)")
               (agents-panel-pair "Pair With the Agent" drgnx-agent-panel-pair "Pair mode, when it is available")
               (agents-panel-start "Start Another Agent Here" drgnx-agent-panel-start
                                   "Start an agent of a profile you choose in this session's folder")
               (agents-panel-move "Move to Another Profile" drgnx-agent-panel-move
                                  "Stop after the current tool call and continue in the same worktree with another profile")
               (agents-panel-compact "Compact the Context" drgnx-agent-panel-compact
                                     "/compact, with what it keeps shown first when the agent can say")
               (agents-panel-mode "Switch the Mode" drgnx-agent-panel-switch-mode
                                  "Switch the agent's mode to one its lock allows")
               (agents-panel-model "Switch the Model" drgnx-agent-panel-switch-model
                                   "Switch the agent's model")))
    (drgnx-command-define (nth 0 c) :category "Agents" :title (nth 1 c) :command (nth 2 c)
                          :map 'drgnx-agent-panel-mode-map :doc (nth 3 c))))

(provide 'drgnx-agent-panel-composer)
;;; drgnx-agent-panel-composer.el ends here
