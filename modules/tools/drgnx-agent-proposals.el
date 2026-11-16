;;; drgnx-agent-proposals.el --- Proposals in the viewed file: the data and the commands (library of tools/agents-in-editor) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; An agent working in its own worktree changes the file you are looking at: the hub's frame for the buffer carries
;; its hunks as `:proposals' ((:session :op :index :start_line :end_line :text :reason) ...).  This library holds them
;; per buffer and gives two commands at point, the same in every profile: accept (`review/mark accepted', which
;; reaches your checkout through the merge, never as a second writer) and revert (`history/revert/hunk' in the agent's
;; worktree).  A paired agent's edits land in the buffer itself and make no proposal.  The drawing is Task 25's.
;; Loaded by tools/agents-in-editor; defines no module.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'project)
(require 'drgnx-registry)
(require 'drgnx-hub-client)

(defvar drgnx-agents-editor-apply-functions)
(declare-function drgnx-work-code--worktree "drgnx-work-code")

(defvar-local drgnx-agent-proposals--list nil
  "The proposals the hub's last frame for this buffer holds: plists (:session :op :index :start_line :end_line :text
:reason).")

(defvar drgnx-agent-proposals-paired-function nil
  "A function of a session id, non-nil when that agent is paired with you (its edits are in the buffer, no proposal).")

(defvar drgnx-agent-proposals-mode-map (make-sparse-keymap)
  "Keys at point in a proposal's block; the key profiles bind them (keys/*.eld).")

(define-minor-mode drgnx-agent-proposals-mode
  "On in a buffer an agent in its own worktree proposes changes to: `a' accepts the hunk at point, `D' reverts it."
  :lighter nil :keymap drgnx-agent-proposals-mode-map)

(defun drgnx-agent-proposals-set (buffer frame)
  "Take the proposals of the hub's FRAME for BUFFER (a paired agent's dropped), and turn the mode on while there are
any."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq drgnx-agent-proposals--list
            (cl-remove-if (lambda (p)
                            (and drgnx-agent-proposals-paired-function
                                 (funcall drgnx-agent-proposals-paired-function (plist-get p :session))))
                          (append (plist-get frame :proposals) nil)))
      (drgnx-agent-proposals-mode (if drgnx-agent-proposals--list 1 -1)))))

(defun drgnx-agent-proposals--at-point ()
  "The proposal whose lines hold point, or an error."
  (let ((line (line-number-at-pos)))
    (or (cl-find-if (lambda (p) (<= (plist-get p :start_line) line (plist-get p :end_line)))
                    drgnx-agent-proposals--list)
        (user-error "No agent's proposal here"))))

(defun drgnx-agent-proposals--path ()
  "This buffer's file relative to its project, the path the agent's worktree holds it at."
  (let ((root (and buffer-file-name (project-root (project-current nil (file-name-directory buffer-file-name))))))
    (if root (file-relative-name buffer-file-name root) (user-error "This buffer is in no project"))))

(defun drgnx-agent-proposals-accept ()
  "Accept the agent's hunk at point: a review mark for the merge gate; nothing is written into your checkout."
  (interactive)
  (let* ((p (drgnx-agent-proposals--at-point)) (path (drgnx-agent-proposals--path))
         (hash (secure-hash 'sha1 (or (plist-get p :text) ""))))
    (drgnx-hub-call "review/mark"
                    (list :agent (plist-get p :session) :path path :state "accepted" :hash hash
                          :event (list :kind "accept" :summary (format "you accepted a hunk of %s" path)
                                       :data (list :by "user" :path path :hunk (plist-get p :index) :hash hash)))
                    (lambda (_r err) (message (if err "Proposal: %s" "Accepted a hunk of %s: a review mark; the merge brings it")
                                              (or err path))))))

(defun drgnx-agent-proposals-revert ()
  "Revert the agent's hunk at point in the agent's own worktree."
  (interactive)
  (let* ((p (drgnx-agent-proposals--at-point)) (path (drgnx-agent-proposals--path))
         (worktree (or (and (fboundp 'drgnx-work-code--worktree) (drgnx-work-code--worktree (plist-get p :session)))
                       (user-error "The agent's worktree is not known here"))))
    (drgnx-hub-call "history/revert/hunk"
                    (list :worktree worktree :op (plist-get p :op) :path path :hunk (plist-get p :index))
                    (lambda (r err) (message "Proposal: %s" (or err (plist-get r :state) "reverted"))))))

(defun drgnx-agent-proposals-setup ()
  "tools/agents-in-editor's setup: the commands, and the frames' proposals taken per buffer."
  (drgnx-command-define 'agents-proposal-accept :category "Agents" :title "Accept the Agent's Hunk"
                        :command #'drgnx-agent-proposals-accept :map 'drgnx-agent-proposals-mode-map
                        :doc "A review mark for the hunk at point; it reaches your checkout through the merge")
  (drgnx-command-define 'agents-proposal-revert :category "Agents" :title "Revert the Agent's Hunk"
                        :command #'drgnx-agent-proposals-revert :map 'drgnx-agent-proposals-mode-map
                        :doc "Revert the hunk at point in the agent's worktree")
  (add-hook 'drgnx-agents-editor-apply-functions #'drgnx-agent-proposals-set))

(defun drgnx-agent-proposals-teardown ()
  "Undo `drgnx-agent-proposals-setup''s hook."
  (remove-hook 'drgnx-agents-editor-apply-functions #'drgnx-agent-proposals-set))

(provide 'drgnx-agent-proposals)
;;; drgnx-agent-proposals.el ends here
