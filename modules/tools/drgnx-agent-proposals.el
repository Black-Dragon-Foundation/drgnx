;;; drgnx-agent-proposals.el --- Proposals in the viewed file: the data and the commands (library of tools/agents-in-editor) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; An agent working in its own worktree changes the file you are looking at: the hub's frame for the buffer carries
;; its hunks as `:proposals' ((:session :op :index :start_line :end_line :text :reason) ...).  This library holds them
;; per buffer and gives two commands at point, the same in every profile: accept (`review/mark accepted', which
;; reaches your checkout through the merge, never as a second writer) and revert (`history/revert/hunk' in the agent's
;; worktree).  A paired agent's edits land in the buffer itself and make no proposal.  Each proposal is drawn as a kit
;; diff block after its last line, one overlay per window showing the buffer (the block's pads are the window's frame's).
;; Loaded by tools/agents-in-editor; defines no module.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'project)
(require 'drgnx-registry)
(require 'drgnx-hub-client)
(require 'drgnx-ui-kit)

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

(defvar-local drgnx-agent-proposals--ovs nil "The overlays of the proposals' blocks, one per proposal and window.")

(defun drgnx-agent-proposals--overlays ()
  "The live overlays of the blocks drawn in the current buffer."
  (setq drgnx-agent-proposals--ovs (cl-remove-if-not #'overlay-buffer drgnx-agent-proposals--ovs)))

(defun drgnx-agent-proposals--clear ()
  "Take every block away from the current buffer."
  (mapc #'delete-overlay drgnx-agent-proposals--ovs)
  (setq drgnx-agent-proposals--ovs nil))

(defun drgnx-agent-proposals--block (p window)
  "Proposal P as a kit diff block for WINDOW: the file, the agent's session and reason, the added lines, Accept and
Revert."
  (let* ((lines (split-string (or (plist-get p :text) "") "\n"))
         (n (plist-get p :start_line)) (i -1)
         (frame (window-frame window))
         (width (max 20 (- (window-body-width window) 2))))
    (drgnx-ui-kit-diff-block
     (file-name-nondirectory (or buffer-file-name (buffer-name))) (length lines) 0
     (list (cons (format "@@ %s \u00b7 %s @@" (plist-get p :session) (or (plist-get p :reason) "no reason recorded"))
                 (mapcar (lambda (l) (setq i (1+ i)) (list 'add (+ n i) l)) lines)))
     width
     (list (list "Accept" "a: accept the agent's hunk" (lambda () (drgnx-agent-proposals-accept p)))
           (list "Revert" "D: revert the agent's hunk" (lambda () (drgnx-agent-proposals-revert p))))
     frame)))

(defun drgnx-agent-proposals--draw ()
  "Draw the current buffer's proposals: a block after each one's last line, in each window showing the buffer."
  (drgnx-agent-proposals--clear)
  (dolist (win (get-buffer-window-list nil nil t))
    (dolist (p drgnx-agent-proposals--list)
      (save-excursion
        (goto-char (point-min))
        (forward-line (1- (plist-get p :end_line)))
        (let ((ov (make-overlay (line-end-position) (line-end-position) nil t)))
          (overlay-put ov 'window win)
          (overlay-put ov 'drgnx-agent-proposal p)
          (overlay-put ov 'after-string
                       (let ((b (drgnx-agent-proposals--block p win)))
                         (concat "\n" (substring b 0 (max 0 (1- (length b)))))))
          (push ov drgnx-agent-proposals--ovs))))))

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
      (drgnx-agent-proposals-mode (if drgnx-agent-proposals--list 1 -1))
      (if drgnx-agent-proposals--list (drgnx-agent-proposals--draw) (drgnx-agent-proposals--clear)))))

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

(defun drgnx-agent-proposals--remove (p)
  "Take proposal P away: from the list and from the drawing."
  (setq drgnx-agent-proposals--list (delq p drgnx-agent-proposals--list))
  (if drgnx-agent-proposals--list (drgnx-agent-proposals--draw) (drgnx-agent-proposals--clear))
  (unless drgnx-agent-proposals--list (drgnx-agent-proposals-mode -1)))

(defun drgnx-agent-proposals-accept (&optional proposal)
  "Accept the agent's hunk at point (or PROPOSAL): a review mark for the merge gate; nothing is written into your
checkout.  Its block goes."
  (interactive)
  (let* ((p (or proposal (drgnx-agent-proposals--at-point))) (buf (current-buffer)) (path (drgnx-agent-proposals--path))
         (hash (secure-hash 'sha1 (or (plist-get p :text) ""))))
    (drgnx-hub-call "review/mark"
                    (list :agent (plist-get p :session) :path path :state "accepted" :hash hash
                          :event (list :kind "accept" :summary (format "you accepted a hunk of %s" path)
                                       :data (list :by "user" :path path :hunk (plist-get p :index) :hash hash)))
                    (lambda (_r err)
                      (message (if err "Proposal: %s" "Accepted a hunk of %s: a review mark; the merge brings it")
                               (or err path))
                      (when (and (not err) (buffer-live-p buf))
                        (with-current-buffer buf (drgnx-agent-proposals--remove p)))))))

(defun drgnx-agent-proposals-revert (&optional proposal)
  "Revert the agent's hunk at point (or PROPOSAL) in the agent's own worktree."
  (interactive)
  (let* ((p (or proposal (drgnx-agent-proposals--at-point))) (buf (current-buffer))
         (path (drgnx-agent-proposals--path))
         (worktree (or (and (fboundp 'drgnx-work-code--worktree) (drgnx-work-code--worktree (plist-get p :session)))
                       (user-error "The agent's worktree is not known here"))))
    (drgnx-hub-call "history/revert/hunk"
                    (list :worktree worktree :op (plist-get p :op) :path path :hunk (plist-get p :index))
                    (lambda (r err)
                      (message "Proposal: %s" (or err (plist-get r :state) "reverted"))
                      (when (and (not err) (buffer-live-p buf))
                        (with-current-buffer buf (drgnx-agent-proposals--remove p)))))))

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
