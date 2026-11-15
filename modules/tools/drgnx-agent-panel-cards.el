;;; drgnx-agent-panel-cards.el --- The agent panel's cards: diffs and permissions (library of tools/agent-panel) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Two kinds of card sit under the transcript, both the hub's rows (view/panel_review.rs); this library is what their
;; buttons and keys run.  A diff card is one hunk of a file the agent edited (flat, bordered):
;; `a' accepts it and `D' rejects it, both through the review view (`drgnx-work-review.el'): accept writes the review
;; mark the merge gate compares, reject marks the file pending and queues the "take it back" message to the agent.
;; The panel never writes a file of a live agent's worktree and builds no queue of its own.  A permission card is a
;; request the agent waits on: Allow (RET), Always (`A') or Deny (`D'), ringed in the attention colour.
;; Loaded by tools/agent-panel (drgnx-agent-panel.el); defines no module.  See docs/guide/agent-panel.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-view)
(require 'drgnx-registry)

(declare-function drgnx-agent-panel--send-look "drgnx-agent-panel")
(declare-function drgnx-agent-panel--key-at "drgnx-agent-panel")
(declare-function drgnx-agent-panel-explain-note-always "drgnx-agent-panel-explain")
(defvar drgnx-agent-panel--session)
(defvar drgnx-agent-panel--snap)
(defvar drgnx-agent-panel-mode-map)
(defvar drgnx-work-review--session)
(defvar drgnx-work-review--diffs)
(declare-function drgnx-agent-panel--entry "drgnx-agent-panel")
(declare-function drgnx-agent-panel--type "drgnx-agent-panel")
(declare-function drgnx-agent-panel--ask "drgnx-agent-panel")
(declare-function drgnx-agent-panel--one-line "drgnx-agent-panel")
(declare-function drgnx-agent-panel-toggle "drgnx-agent-panel")
(declare-function drgnx-work-review--accept "drgnx-work-review")
(declare-function drgnx-work-review--reject "drgnx-work-review")
(declare-function drgnx-history--hash "drgnx-history")
(declare-function drgnx-history--st-id "drgnx-history")
(defvar drgnx-history--buffers)
(defvar nidhogg-history-origin)

(defface drgnx-agent-panel-perm-head '((t :inherit (drgnx-ui-text drgnx-chip-attention) :weight bold))
  "The card of a request that waits on you (window-dark.html `.acard.perm'): its ring is in the attention colour (a
card's ring takes its text's colour), on the attention tint." :group 'drgnx-agent-panel)

;;;; Which cards there are

(defun drgnx-agent-panel-cards--permissions ()
  "The requests the agent waits on, from the latest snapshot (the hub builds their cards)."
  (append (plist-get drgnx-agent-panel--snap :permissions) nil))

;;;; The cards at point

(defun drgnx-agent-panel-cards--request (id)
  "The request whose id is ID (a number or a string: the hub's rows carry it as text)."
  (seq-find (lambda (p) (equal (format "%s" (plist-get p :id)) (format "%s" id))) (drgnx-agent-panel-cards--permissions)))

(defun drgnx-agent-panel-cards--option (request kinds)
  "The id of REQUEST's first option whose kind is one of KINDS, or nil."
  (seq-some (lambda (o) (and (member (format "%s" (plist-get o :kind)) kinds) (plist-get o :optionId)))
            (append (plist-get request :options) nil)))

;;;; Commands

(defun drgnx-agent-panel-cards--card-here ()
  "The hub's card the row at point belongs to, as a list: (\"diff\" PATH HUNK) or (\"perm\" ID), or nil."
  (when-let* ((card (get-text-property (point) 'drgnx-agent-panel-card))) (append card nil)))

(defun drgnx-agent-panel-cards--hunk-here ()
  "The diff card at point as (PATH . HUNK), or nil."
  (let ((card (drgnx-agent-panel-cards--card-here)))
    (and (equal (car card) "diff") (cons (nth 1 card) (nth 2 card)))))

(defun drgnx-agent-panel-cards--perm-here ()
  "The permission request the card at point is, or nil."
  (let ((card (drgnx-agent-panel-cards--card-here)))
    (and (equal (car card) "perm") (drgnx-agent-panel-cards--request (nth 1 card)))))

(defun drgnx-agent-panel-cards--with-review (path fn)
  "Ask the hub for PATH's diff, then call FN, a function of the review view, as that view would with this session and
that diff (the mark and the hash read it)."
  (unless (fboundp 'drgnx-work-review--accept) (user-error "The review view is not loaded (module tools/work-space)"))
  (let ((session drgnx-agent-panel--session))
    (drgnx-agent-panel--ask
     "work/hunks" (list :session session :path path)
     (lambda (r err)
       (if err (message "Review: %s" err)
         (let ((drgnx-work-review--session session)
               (drgnx-work-review--diffs (list (cons path (or (plist-get r :diff) "")))))
           (funcall fn)))))))

(defun drgnx-agent-panel-accept ()
  "Accept the hunk at point: a review mark for the merge gate; nothing is merged and the agent is not told."
  (interactive)
  (let ((h (or (drgnx-agent-panel-cards--hunk-here) (user-error "Point is not on a diff card"))))
    (drgnx-agent-panel-cards--with-review (car h) (lambda () (drgnx-work-review--accept (car h))))))

(defun drgnx-agent-panel--answer (request option)
  (drgnx-agent-panel--ask "agents/permission"
                          (append (list :id drgnx-agent-panel--session :request (plist-get request :id))
                                  (and option (list :option option)))))

(defun drgnx-agent-panel-cards--apply-in-buffer (op result)
  "The hub handed the revert of OP's hunk to the editor: RESULT's edits apply to the buffer it names as the revert's
own change, when the buffer's text is still the one the hub meant; otherwise nothing changes."
  (let ((buf (seq-find (lambda (b) (let ((st (gethash b drgnx-history--buffers)))
                                     (and st (equal (drgnx-history--st-id st) (plist-get result :buffer_id)))))
                       (hash-table-keys drgnx-history--buffers))))
    (cond ((null buf) (message "Reject: the buffer is gone; try again"))
          ((not (equal (drgnx-history--hash buf) (plist-get result :version)))
           (message "Reject: the file changed meanwhile; try again"))
          (t (with-current-buffer buf
               (let ((nidhogg-history-origin (format "revert:%s" op)))
                 (save-excursion
                   (dolist (e (append (plist-get result :edits) nil))
                     (goto-char (1+ (plist-get e :start)))
                     (delete-region (point) (+ (point) (plist-get e :old_len)))
                     (insert (plist-get e :inserted)))))
               (message "Rejected"))))))

(defun drgnx-agent-panel-cards--reject-paired (h)
  "Reject H, a paired chat's hunk (OP PATH INDEX): part 4's revert of that one hunk, the user's later typing kept."
  (let ((op (nth 0 h)))
    (drgnx-agent-panel--ask
     "history/revert/hunk" (list :worktree (plist-get drgnx-agent-panel--snap :cwd) :op op :path (nth 1 h) :hunk (nth 2 h))
     (lambda (r err)
       (if err (message "Reject refused: %s" err)
         (pcase (plist-get r :state)
           ("in-buffer" (drgnx-agent-panel-cards--apply-in-buffer op r))
           ("applied" (message "Rejected"))
           ("undone" (message "Already undone"))
           ("conflict" (message "Reject: your later edits are in the way; nothing changed"))
           (_ (message "Reject: %s" (plist-get r :state))))
         ;; the ledger's hunks are the hub's: it reads them again when the revert is applied (`history/applied')
         )))))

(defun drgnx-agent-panel-reject ()
  "On a diff card: reject the hunk, queue \"take it back\" to the agent.  On a permission card: deny it.
On a paired chat's ledger line: take that hunk back through the edit history, keeping your later typing."
  (interactive)
  (cond ((get-text-property (point) 'drgnx-agent-panel-op-hunk)
         (drgnx-agent-panel-cards--reject-paired (get-text-property (point) 'drgnx-agent-panel-op-hunk)))
        ((drgnx-agent-panel-cards--hunk-here)
         (let ((h (drgnx-agent-panel-cards--hunk-here)))
           (drgnx-agent-panel-cards--with-review (car h) (lambda () (drgnx-work-review--reject (car h) (cdr h))))))
        ((drgnx-agent-panel-cards--perm-here)
         (let ((r (drgnx-agent-panel-cards--perm-here)))
           (drgnx-agent-panel--answer r (drgnx-agent-panel-cards--option r '("reject_once" "reject_always")))))
        (t (user-error "Point is not on a card"))))

(defun drgnx-agent-panel-allow ()
  "On a permission card: allow it once.  On a step: open or fold it."
  (interactive)
  (if-let* ((r (drgnx-agent-panel-cards--perm-here)))
      (drgnx-agent-panel--answer r (drgnx-agent-panel-cards--option r '("allow_once" "allow")))
    (drgnx-agent-panel-toggle)))

(defun drgnx-agent-panel-always ()
  "On a permission card: allow it, and the same kind of request from now on."
  (interactive)
  (let ((r (or (drgnx-agent-panel-cards--perm-here) (user-error "Point is not on a permission card"))))
    (let ((always (drgnx-agent-panel-cards--option r '("allow_always"))))
      (drgnx-agent-panel--answer r (or always (drgnx-agent-panel-cards--option r '("allow_once" "allow"))))
      (when always (drgnx-agent-panel-explain-note-always r)))))

;;;; Pinned cards and the edits ledger (the hub's cards; the to-do list is the hub's alone)

(defvar-local drgnx-agent-panel--pins nil "Pinned cards of this chat, newest last: a list of (KEY . TEXT).")
(defvar-local drgnx-agent-panel--ledger-open nil "Non-nil while the ledger lists its files (the hub builds the card).")

(defun drgnx-agent-panel--pin-text (key)
  "A line that stands for the row KEY, for a pinned card."
  (pcase (car-safe key)
    (:e (let ((e (drgnx-agent-panel--entry (cadr key))))
          (drgnx-agent-panel--one-line (or (plist-get e :title) (plist-get e :text) (format "%s" (plist-get e :type))) 80)))
    (:card (pcase (cadr key)
             ("diff" (format "%s hunk %d" (nth 2 key) (1+ (nth 3 key))))
             ("perm" (plist-get (drgnx-agent-panel-cards--request (nth 2 key)) :title))))
    (_ nil)))

(defun drgnx-agent-panel-pin ()
  "Pin the card or step at point under the strip; again to unpin it.  A pinned card is the hub's row: its text goes
to the hub with the look (`agents/panel/look' `pins'), which builds the card."
  (interactive)
  (let ((n (get-text-property (point) 'drgnx-agent-panel-pin)))
    (if (integerp n)
        (setq drgnx-agent-panel--pins (append (seq-take drgnx-agent-panel--pins n) (nthcdr (1+ n) drgnx-agent-panel--pins)))
      (let* ((card (drgnx-agent-panel-cards--card-here))
             (key (if card (cons :card card) (drgnx-agent-panel--key-at))) (text (and key (drgnx-agent-panel--pin-text key))))
        (unless text (user-error "Point is not on something to pin"))
        (if (assoc key drgnx-agent-panel--pins)
            (setq drgnx-agent-panel--pins (assoc-delete-all key drgnx-agent-panel--pins))
          (setq drgnx-agent-panel--pins (append drgnx-agent-panel--pins (list (cons key text)))))))
    (drgnx-agent-panel--send-look)))

(defun drgnx-agent-panel-ledger ()
  "List or fold the edits ledger (the hub's card): opening it sets the mark, so the next \"new\" counts from there."
  (interactive)
  (setq drgnx-agent-panel--ledger-open (not drgnx-agent-panel--ledger-open))
  (drgnx-agent-panel--send-look))

(defun drgnx-agent-panel-cards-setup ()
  (dolist (c '((agents-panel-pin "Pin the Card" drgnx-agent-panel-pin "Pin the card or step at point under the chips; again to unpin")
               (agents-panel-ledger "List the Edits" drgnx-agent-panel-ledger
                                    "The files the agent edited, and how many edits came since you last looked")
               (agents-panel-accept "Accept the Hunk" drgnx-agent-panel-accept
                                    "A review mark for the merge gate; nothing is merged")
               (agents-panel-reject "Reject the Hunk or Deny" drgnx-agent-panel-reject
                                    "A diff card: the agent is told, queued, to take it back. A permission card: deny")
               (agents-panel-allow "Allow or Open" drgnx-agent-panel-allow
                                   "A permission card: allow once. A step: open or fold it")
               (agents-panel-always "Always Allow" drgnx-agent-panel-always
                                    "A permission card: allow this and requests like it from now on")))
    (drgnx-command-define (nth 0 c) :category "Agents" :title (nth 1 c) :command (nth 2 c)
                          :map 'drgnx-agent-panel-mode-map :doc (nth 3 c))))

(provide 'drgnx-agent-panel-cards)
;;; drgnx-agent-panel-cards.el ends here
