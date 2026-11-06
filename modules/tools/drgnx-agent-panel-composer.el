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

(defvar drgnx-agent-panel--session)
(defvar drgnx-agent-panel--snap)
(defvar drgnx-agent-panel--shown-keys)
(defvar drgnx-agent-panel-mode-map)
(defvar drgnx-work-resume-text)
(declare-function drgnx-agent-panel--ask "drgnx-agent-panel")
(declare-function drgnx-agent-panel--one-line "drgnx-agent-panel")

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

(defun drgnx-agent-panel-composer--row ()
  (let ((pair (drgnx-agent-panel-composer--pair-chip)))
    (concat (propertize "  ▍ s write to the agent · x stop · p stop after this step · u resume" 'face 'drgnx-agent-panel-subtle)
            (if pair (concat "  " pair) "")
            "\n")))

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
               (agents-panel-pair "Pair With the Agent" drgnx-agent-panel-pair "Pair mode, when it is available")))
    (drgnx-command-define (nth 0 c) :category "Agents" :title (nth 1 c) :command (nth 2 c)
                          :map 'drgnx-agent-panel-mode-map :doc (nth 3 c))))

(provide 'drgnx-agent-panel-composer)
;;; drgnx-agent-panel-composer.el ends here
