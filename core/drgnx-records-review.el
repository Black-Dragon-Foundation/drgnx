;;; drgnx-records-review.el --- review a hand edit to a plan file in the editor -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The hub writes the org folder's record files (plans, ledgers, DEFERRED) as views of its graph.  A hand edit to one is
;; not written back: the hub keeps it as a proposal (`records/proposals') and sends `view-proposal'.  Here the event is
;; a notice, never a prompt (it comes down the daemon path), whose command is Records: Review Proposal.  That command
;; shows the proposal's diff in a `diff-mode' buffer; `C-c C-a' accepts and `C-c C-r' rejects (`records/decide').  See
;; docs/guide/agents.md, "Reviewing a hand edit to a plan file".

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'diff-mode)
(require 'drgnx-notice)
(require 'drgnx-registry)

(declare-function drgnx-hub-call-sync "drgnx-hub-client")
(defvar drgnx-hub--event-conn)

(defvar-local drgnx-records-review--id nil "The id of the proposal this buffer shows.")

(defun drgnx-records-review--notice-id (id)
  "The notice id for the proposal ID."
  (intern (concat "proposal-" id)))

(defun drgnx-records-review--event (event data)
  "`drgnx-hub-event-functions': a `view-proposal' from a hub that proved itself is a notice.  Nothing asks, nothing
waits: the notice carries the command that does."
  (when (and (equal event "view-proposal")
             (stringp (plist-get data :id))
             (processp (bound-and-true-p drgnx-hub--event-conn))
             (process-get drgnx-hub--event-conn :drgnx-proven))
    (let ((id (plist-get data :id)))
      (drgnx-notify 'hub 'info
                    (format "A hand edit to %s is waiting for review"
                            (file-name-nondirectory (or (plist-get data :path) "a plan file")))
                    :id (drgnx-records-review--notice-id id) :life 'condition
                    :detail (and (plist-get data :by) (format "Edited by %s" (plist-get data :by)))
                    :fix "Records: Review Proposal"
                    :command (list 'drgnx-records-review id)))))

(defun drgnx-records-review--fetch (id)
  "The open proposal ID (a plist of `records/proposals'), or nil."
  (cl-find id (plist-get (drgnx-hub-call-sync "records/proposals" nil 10) :proposals)
           :key (lambda (p) (plist-get p :id)) :test #'equal))

(defun drgnx-records-review--summary (proposal)
  "A line saying what PROPOSAL would do."
  (let ((ops (plist-get proposal :ops)))
    (format "%s: %d operation%s%s%s"
            (file-name-nondirectory (plist-get proposal :path)) (length ops) (if (= (length ops) 1) "" "s")
            (if (plist-get proposal :unmapped) ", with parts that map to none (a note on accept)" "")
            (if (cl-some (lambda (o) (plist-get o :user_only)) ops) ", touching a user-only field" ""))))

(defvar drgnx-records-review-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c C-a") #'drgnx-records-review-accept)
    (define-key m (kbd "C-c C-r") #'drgnx-records-review-reject)
    m)
  "Keys of a proposal's diff buffer.")

(define-minor-mode drgnx-records-review-mode
  "In a proposal's diff buffer: \\[drgnx-records-review-accept] accepts, \\[drgnx-records-review-reject] rejects."
  :lighter " Proposal" :keymap drgnx-records-review-mode-map)

;;;###autoload
(defun drgnx-records-review (&optional id)
  "Show the diff of the proposal ID (asked for when nil and several are open) in a `diff-mode' buffer."
  (interactive)
  (let* ((open (cl-remove-if-not (lambda (p) (equal (plist-get p :status) "open"))
                                 (plist-get (drgnx-hub-call-sync "records/proposals" nil 10) :proposals)))
         (id (or id (pcase open
                      ('nil (user-error "No hand edit is waiting for review"))
                      (`(,only) (plist-get only :id))
                      (_ (completing-read "Proposal: " (mapcar (lambda (p) (plist-get p :id)) open) nil t)))))
         (proposal (or (cl-find id open :key (lambda (p) (plist-get p :id)) :test #'equal)
                       (user-error "Proposal %s is not open" id)))
         (buffer (get-buffer-create (format "*drgnx proposal: %s*" (file-name-nondirectory (plist-get proposal :path))))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (plist-get proposal :diff))
        (goto-char (point-min)))
      (diff-mode)
      (drgnx-records-review-mode 1)
      (setq drgnx-records-review--id id
            header-line-format (concat (drgnx-records-review--summary proposal) "  [C-c C-a accept, C-c C-r reject]")))
    (pop-to-buffer buffer)))

(defun drgnx-records-review--decide (accept)
  "Accept or, when ACCEPT is nil, reject the proposal of this buffer; the buffer goes and so does the notice."
  (unless drgnx-records-review--id (user-error "Not a proposal buffer"))
  (let* ((id drgnx-records-review--id)
         (result (drgnx-hub-call-sync "records/decide" (list :id id :accept (if accept t :false)) 10))
         (status (plist-get result :status)))
    (message "Proposal %s: %s%s" id status (if (plist-get result :note) (concat " (" (plist-get result :note) ")") ""))
    (unless (equal status "stale")
      (drgnx-notice-clear 'hub (drgnx-records-review--notice-id id))
      (kill-buffer (current-buffer)))
    result))

(defun drgnx-records-review-accept ()
  "Accept this proposal: the hub applies its operations (if the records did not move) and rewrites the file."
  (interactive)
  (drgnx-records-review--decide t))

(defun drgnx-records-review-reject ()
  "Reject this proposal: the hub keeps the edited file in its records backup and rewrites the file."
  (interactive)
  (drgnx-records-review--decide nil))

(defun drgnx-records-review-register-commands ()
  "The review commands."
  (drgnx-command-define 'records-review-proposal :category "Agents" :title "Records: Review Proposal"
                        :command #'drgnx-records-review
                        :doc "Show a hand edit to a plan file as a diff, to accept or reject")
  (drgnx-command-define 'records-accept-proposal :category "Agents" :title "Records: Accept Proposal"
                        :command #'drgnx-records-review-accept
                        :doc "Accept the proposal shown in this buffer")
  (drgnx-command-define 'records-reject-proposal :category "Agents" :title "Records: Reject Proposal"
                        :command #'drgnx-records-review-reject
                        :doc "Reject the proposal shown in this buffer"))

(provide 'drgnx-records-review)
;;; drgnx-records-review.el ends here
