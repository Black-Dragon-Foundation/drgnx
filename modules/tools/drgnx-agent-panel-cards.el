;;; drgnx-agent-panel-cards.el --- The agent panel's cards: diffs and permissions (library of tools/agent-panel) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Two kinds of card sit under the transcript.  A diff card is one hunk of a file the agent edited (flat, bordered):
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
(require 'drgnx-timer)

(defvar drgnx-agent-panel--session)
(defvar drgnx-agent-panel--snap)
(defvar drgnx-agent-panel--shown-keys)
(defvar drgnx-agent-panel-mode-map)
(defvar drgnx-work-review--session)
(defvar drgnx-work-review--diffs)
(defvar drgnx-agent-panel--files)
(declare-function drgnx-agent-panel--entry "drgnx-agent-panel")
(declare-function drgnx-agent-panel--type "drgnx-agent-panel")
(declare-function drgnx-agent-panel--ask "drgnx-agent-panel")
(declare-function drgnx-agent-panel--one-line "drgnx-agent-panel")
(declare-function drgnx-agent-panel--reconcile "drgnx-agent-panel")
(declare-function drgnx-agent-panel-toggle "drgnx-agent-panel")
(declare-function drgnx-work-review-parse-hunks "drgnx-work-review")
(declare-function drgnx-work-review--accept "drgnx-work-review")
(declare-function drgnx-work-review--reject "drgnx-work-review")
(declare-function drgnx-history--hash "drgnx-history")
(declare-function drgnx-history--st-id "drgnx-history")
(defvar drgnx-history--buffers)
(defvar nidhogg-history-origin)

(defface drgnx-agent-panel-ring '((t :inherit drgnx-status-attention :box (:line-width 2)))
  "The ring round a card that waits on you." :group 'drgnx-agent-panel)

(defconst drgnx-agent-panel-cards-max-files 20 "How many edited files get diff cards at most.")

(defvar-local drgnx-agent-panel--diffs nil "Alist: path → that file's unified diff (`work/hunks').")
(defvar-local drgnx-agent-panel--op-hunks nil
  "A paired chat's hunks, the user's history filtered to its session (`history/op/hunks'): plists with :op :path
:index :start_line :end_line :state :undone_by.")

(defun drgnx-agent-panel-cards--paired-p ()
  "Whether this chat edits the user's checkout (it has no worktree base or step snapshots, so no `work/hunks')."
  (let ((p (plist-get drgnx-agent-panel--snap :paired))) (and p (not (eq p :json-false)))))

;;;; Which cards there are

(defun drgnx-agent-panel-cards--permissions ()
  (append (plist-get drgnx-agent-panel--snap :permissions) nil))

(defun drgnx-agent-panel-cards--hunks (path)
  (let ((diff (cdr (assoc path drgnx-agent-panel--diffs))))
    (and diff (drgnx-work-review-parse-hunks diff))))

(defun drgnx-agent-panel-cards-keys ()
  "The card rows: each hunk of each edited file, then each permission request."
  (append (and (fboundp 'drgnx-work-review-parse-hunks)
               (cl-loop for (path . _) in drgnx-agent-panel--diffs
                        append (cl-loop for _ in (drgnx-agent-panel-cards--hunks path) for i from 0
                                        collect (list :diff path i))))
          (mapcar (lambda (p) (list :perm (plist-get p :id))) (drgnx-agent-panel-cards--permissions))))

(defun drgnx-agent-panel-cards-redraw ()
  "The snapshot changed: the permission cards are drawn again."
  (when (drgnx-view-p drgnx-view)
    (drgnx-view-dirty drgnx-view (seq-filter (lambda (k) (eq (car-safe k) :perm)) (hash-table-keys drgnx-agent-panel--shown-keys)))))

;;;; Rows

(defun drgnx-agent-panel-cards--box (lines props)
  "LINES (strings without newlines) as a card: top, middle and bottom rows in the card faces, PROPS on every row."
  (let ((n (length lines)) (i -1))
    (mapconcat (lambda (l)
                 (cl-incf i)
                 (let ((card (cond ((= n 1) 'drgnx-card-single) ((= i 0) 'drgnx-card-top)
                                   ((= i (1- n)) 'drgnx-card-bottom) (t 'drgnx-card-mid))))
                   (apply #'propertize (concat " " (if (consp l) (car l) l) " \n")
                          'face (if (consp l) (list (cdr l) card) card) props)))
               lines "")))

(defun drgnx-agent-panel-cards--diff-row (path i)
  (let* ((hunk (nth i (drgnx-agent-panel-cards--hunks path)))
         (body (and hunk (split-string (string-trim-right (plist-get hunk :text)) "\n"))))
    (if (not hunk) "\n"
      (drgnx-agent-panel-cards--box
       (cons (cons (format "%s  %s   (a accept · D reject)" (drgnx-agent-panel--one-line path 50) (plist-get hunk :header))
                   'bold)
             (mapcar (lambda (l) (cons (truncate-string-to-width l 100 nil nil "…")
                                       (pcase (and (not (string-empty-p l)) (aref l 0)) (?+ 'diff-added) (?- 'diff-removed) (_ 'default))))
                     (seq-take body 30)))
       (list 'drgnx-agent-panel-hunk (cons path i))))))

(defun drgnx-agent-panel-cards--request (id)
  (seq-find (lambda (p) (equal (plist-get p :id) id)) (drgnx-agent-panel-cards--permissions)))

(defun drgnx-agent-panel-cards--option (request kinds)
  "The id of REQUEST's first option whose kind is one of KINDS, or nil."
  (seq-some (lambda (o) (and (member (format "%s" (plist-get o :kind)) kinds) (plist-get o :optionId)))
            (append (plist-get request :options) nil)))

(defun drgnx-agent-panel-cards--perm-row (id)
  (if-let* ((r (drgnx-agent-panel-cards--request id)))
      (concat (propertize (concat "  " (drgnx-agent-panel--one-line (or (plist-get r :title) "the agent asks") 70) "\n")
                          'face 'drgnx-agent-panel-ring 'drgnx-agent-panel-perm id)
              (propertize (concat "    ↵ Allow · A Always · D Deny\n")
                          'face 'drgnx-agent-panel-ring 'drgnx-agent-panel-perm id))
    "\n"))

;;;; Commands

(defun drgnx-agent-panel-cards--hunk-here ()
  (get-text-property (point) 'drgnx-agent-panel-hunk))

(defun drgnx-agent-panel-cards--perm-here ()
  (when-let* ((id (get-text-property (point) 'drgnx-agent-panel-perm))) (drgnx-agent-panel-cards--request id)))

(defun drgnx-agent-panel-cards--with-review (fn)
  "Call FN, a function of the review view, as that view would with this session and these diffs."
  (unless (fboundp 'drgnx-work-review--accept) (user-error "The review view is not loaded (module tools/work-space)"))
  (let ((drgnx-work-review--session drgnx-agent-panel--session) (drgnx-work-review--diffs drgnx-agent-panel--diffs))
    (funcall fn)))

(defun drgnx-agent-panel-accept ()
  "Accept the hunk at point: a review mark for the merge gate; nothing is merged and the agent is not told."
  (interactive)
  (let ((h (or (drgnx-agent-panel-cards--hunk-here) (user-error "Point is not on a diff card"))))
    (drgnx-agent-panel-cards--with-review (lambda () (drgnx-work-review--accept (car h))))))

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
  (let ((buffer (current-buffer)) (op (nth 0 h)))
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
         (when (buffer-live-p buffer)
           (with-current-buffer buffer (drgnx-agent-panel-cards--load-paired buffer))))))))

(defun drgnx-agent-panel-reject ()
  "On a diff card: reject the hunk, queue \"take it back\" to the agent.  On a permission card: deny it.
On a paired chat's ledger line: take that hunk back through the edit history, keeping your later typing."
  (interactive)
  (cond ((get-text-property (point) 'drgnx-agent-panel-op-hunk)
         (drgnx-agent-panel-cards--reject-paired (get-text-property (point) 'drgnx-agent-panel-op-hunk)))
        ((drgnx-agent-panel-cards--hunk-here)
         (let ((h (drgnx-agent-panel-cards--hunk-here)))
           (drgnx-agent-panel-cards--with-review (lambda () (drgnx-work-review--reject (car h) (cdr h))))))
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
    (drgnx-agent-panel--answer r (or (drgnx-agent-panel-cards--option r '("allow_always"))
                                     (drgnx-agent-panel-cards--option r '("allow_once" "allow"))))))

;;;; Loading the edited files' diffs

(defun drgnx-agent-panel-cards-load (buffer)
  "Ask the hub for the files the session edited and each one's diff; the cards follow."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (if (drgnx-agent-panel-cards--paired-p)
          (drgnx-agent-panel-cards--load-paired buffer)
        (let ((sid drgnx-agent-panel--session))
          (drgnx-agent-panel--ask
           "work/files" (list :session sid)
           (lambda (r err)
             (when (and (not err) (buffer-live-p buffer))
               (with-current-buffer buffer
                 (setq drgnx-agent-panel--files (append (plist-get r :files) nil))
                 (drgnx-agent-panel--reconcile)
                 (drgnx-agent-panel-cards-plan-or-edits-changed))
               (dolist (f (seq-take (append (plist-get r :files) nil) drgnx-agent-panel-cards-max-files))
                 (let ((path (plist-get f :path)))
                   (drgnx-agent-panel--ask
                    "work/hunks" (list :session sid :path path)
                    (lambda (r2 err2)
                      (when (and (not err2) (buffer-live-p buffer))
                        (with-current-buffer buffer
                          (setf (alist-get path drgnx-agent-panel--diffs nil nil #'equal) (or (plist-get r2 :diff) ""))
                          (drgnx-agent-panel--reconcile)
                          (when (drgnx-view-p drgnx-view)
                            (drgnx-view-dirty drgnx-view (seq-filter (lambda (k) (and (eq (car-safe k) :diff) (equal (cadr k) path)))
                                                                     (hash-table-keys drgnx-agent-panel--shown-keys))))))))))))))))))

(defun drgnx-agent-panel-cards--load-paired (buffer)
  "Ask the user's history for the hunks of this paired chat's session in its checkout; the ledger follows."
  (with-current-buffer buffer
    (when-let* ((cwd (plist-get drgnx-agent-panel--snap :cwd)))
      (drgnx-agent-panel--ask
       "history/op/hunks" (list :worktree cwd :session drgnx-agent-panel--session)
       (lambda (r err)
         (when (and (not err) (buffer-live-p buffer))
           (with-current-buffer buffer
             (setq drgnx-agent-panel--op-hunks (append (plist-get r :hunks) nil))
             (drgnx-agent-panel--reconcile)
             (drgnx-agent-panel-cards-plan-or-edits-changed))))))))

(defun drgnx-agent-panel-cards-note-entries (buffer touched from-slice)
  "Entries TOUCHED arrived in BUFFER: the to-do list and the ledger are drawn again, and when a live one is an edit
that finished, the diffs are asked for again soon.  FROM-SLICE: they came from a page."
  (with-current-buffer buffer
    (drgnx-agent-panel-cards-plan-or-edits-changed)
    (when (and (not from-slice)
               (seq-some (lambda (idx)
                           (let ((e (gethash idx (buffer-local-value 'drgnx-agent-panel--entries buffer))))
                             (and e (equal (plist-get e :kind) "edit") (equal (plist-get e :status) "completed"))))
                         touched))
      (drgnx-timer-soon (cons 'agent-panel-cards buffer) 0.3 #'drgnx-agent-panel-cards-load :args (list buffer) :owner buffer))))

(defvar drgnx-agent-panel--entries)

;;;; Pinned cards, the agent's to-do list, the edits ledger

(defvar-local drgnx-agent-panel--pins nil "Pinned cards of this chat, newest last: a list of (KEY . TEXT).")
(defvar-local drgnx-agent-panel--files nil "The files the session edited, from `work/files': plists with :path :plus :minus.")
(defvar-local drgnx-agent-panel--ledger-mark nil "The entry index when you last looked at the ledger, or nil: never.")
(defvar-local drgnx-agent-panel--ledger-open nil "Non-nil while the ledger lists its files.")

(defun drgnx-agent-panel-cards--plan ()
  "The latest plan entry's items (the agent's to-do list), or nil."
  (let (best)
    (maphash (lambda (idx e) (when (and (eq (drgnx-agent-panel--type e) 'plan) (or (null best) (> idx (car best)))) (setq best (cons idx e))))
             drgnx-agent-panel--entries)
    (and best (append (plist-get (cdr best) :entries) nil))))

(defun drgnx-agent-panel-cards--edit-indexes ()
  "The indexes of the finished edits in the transcript, ascending."
  (let (out)
    (maphash (lambda (idx e)
               (when (and (eq (drgnx-agent-panel--type e) 'tool) (equal (plist-get e :kind) "edit")
                          (equal (plist-get e :status) "completed"))
                 (push idx out)))
             drgnx-agent-panel--entries)
    (sort out #'<)))

(defun drgnx-agent-panel-cards--new-edits ()
  "How many finished edits came after the mark: what changed since you looked."
  (let ((mark (or drgnx-agent-panel--ledger-mark -1)))
    (seq-count (lambda (i) (> i mark)) (drgnx-agent-panel-cards--edit-indexes))))

(defun drgnx-agent-panel-cards-top-keys ()
  "The rows under the chips: pinned cards, the to-do list, the ledger."
  (append (cl-loop for _ in drgnx-agent-panel--pins for n from 0 collect (list :pin n))
          (and (drgnx-agent-panel-cards--plan) (list (list :todo)))
          (and (or drgnx-agent-panel--files drgnx-agent-panel--op-hunks (drgnx-agent-panel-cards--edit-indexes)) (list (list :ledger)))))

(defun drgnx-agent-panel-cards--pin-row (n)
  (drgnx-agent-panel-cards--box
   (list (cons (concat "⚑ " (drgnx-agent-panel--one-line (cdr (nth n drgnx-agent-panel--pins)) 80) "   (P unpin)") 'bold))
   nil))

(defun drgnx-agent-panel-cards--todo-row ()
  (let ((items (drgnx-agent-panel-cards--plan)))
    (drgnx-agent-panel-cards--box
     (cons (cons (format "To do · %d of %d done" (seq-count (lambda (i) (equal (plist-get i :status) "completed")) items)
                         (length items))
                 'bold)
           (mapcar (lambda (i)
                     (let ((st (plist-get i :status)))
                       (format "%s %s" (cond ((equal st "completed") "☑") ((equal st "in_progress") "◐") (t "☐"))
                               (drgnx-agent-panel--one-line (plist-get i :content) 80))))
                   items))
     nil)))

(defun drgnx-agent-panel-cards--undone-note (h)
  "What became of paired hunk H: \"\", \"undone by you\" (a user operation reverted it) or \"undone\" by someone else."
  (let ((state (plist-get h :state)) (by (append (plist-get h :undone_by) nil)))
    (cond ((equal state "live") "")
          ((seq-some (lambda (u) (let ((a (plist-get u :author))) (or (null a) (equal (plist-get a :kind) "user")))) by)
           (format "  · %s by you" (if (equal state "undone") "undone" "partly undone")))
          (t (format "  · %s" (if (equal state "undone") "undone" "partly undone"))))))

(defun drgnx-agent-panel-cards--paired-line (h)
  "One ledger line for paired hunk H, which Reject (\"D\") on it takes back."
  (propertize (format "%s  %s–%s%s" (drgnx-agent-panel--one-line (plist-get h :path) 50)
                      (plist-get h :start_line) (plist-get h :end_line) (drgnx-agent-panel-cards--undone-note h))
              'drgnx-agent-panel-op-hunk (list (plist-get h :op) (plist-get h :path) (plist-get h :index))))

(defun drgnx-agent-panel-cards--ledger-row ()
  (let ((new (drgnx-agent-panel-cards--new-edits))
        (files (or drgnx-agent-panel--files (seq-uniq (mapcar (lambda (h) (list :path (plist-get h :path))) drgnx-agent-panel--op-hunks)
                                                      (lambda (a b) (equal (plist-get a :path) (plist-get b :path)))))))
    (drgnx-agent-panel-cards--box
     (cons (cons (format "Edits · %d file%s%s   (L %s)" (length files) (if (= 1 (length files)) "" "s")
                         (if (> new 0) (format " · %d new since you looked" new) "")
                         (if drgnx-agent-panel--ledger-open "fold" "list"))
                 (if (> new 0) 'drgnx-status-attention 'bold))
           (if (and drgnx-agent-panel--ledger-open drgnx-agent-panel--op-hunks)
               (mapcar #'drgnx-agent-panel-cards--paired-line drgnx-agent-panel--op-hunks)
             (and drgnx-agent-panel--ledger-open
                  (mapcar (lambda (f) (format "%s  +%s −%s" (drgnx-agent-panel--one-line (plist-get f :path) 60)
                                              (or (plist-get f :plus) 0) (or (plist-get f :minus) 0)))
                          files))))
     nil)))

(defun drgnx-agent-panel-cards-plan-or-edits-changed ()
  "Entries arrived: the to-do list and the ledger are drawn again."
  (when (drgnx-view-p drgnx-view)
    (drgnx-view-dirty drgnx-view (seq-filter (lambda (k) (memq (car-safe k) '(:todo :ledger))) (hash-table-keys drgnx-agent-panel--shown-keys)))))

(defun drgnx-agent-panel--pin-text (key)
  "A line that stands for the row KEY, for a pinned card."
  (pcase (car-safe key)
    (:e (let ((e (drgnx-agent-panel--entry (cadr key))))
          (drgnx-agent-panel--one-line (or (plist-get e :title) (plist-get e :text) (format "%s" (plist-get e :type))) 80)))
    (:diff (format "%s %s" (cadr key) (plist-get (nth (nth 2 key) (drgnx-agent-panel-cards--hunks (cadr key))) :header)))
    (:perm (plist-get (drgnx-agent-panel-cards--request (cadr key)) :title))
    (_ nil)))

(defun drgnx-agent-panel-pin ()
  "Pin the card or step at point under the chips; again to unpin it."
  (interactive)
  (let* ((key (and (drgnx-view-p drgnx-view) (drgnx-view-key-at)))
         (key (if (eq (car-safe key) :pin) (car (nth (cadr key) drgnx-agent-panel--pins)) key))
         (text (and key (drgnx-agent-panel--pin-text key))))
    (unless text (user-error "Point is not on something to pin"))
    (if (assoc key drgnx-agent-panel--pins)
        (setq drgnx-agent-panel--pins (assoc-delete-all key drgnx-agent-panel--pins))
      (setq drgnx-agent-panel--pins (append drgnx-agent-panel--pins (list (cons key text)))))
    (drgnx-agent-panel--reconcile)
    (drgnx-view-dirty drgnx-view (seq-filter (lambda (k) (eq (car-safe k) :pin)) (hash-table-keys drgnx-agent-panel--shown-keys)))))

(defun drgnx-agent-panel-ledger ()
  "List or fold the edits ledger; looking at it sets the mark, so the next \"new\" counts from here."
  (interactive)
  (setq drgnx-agent-panel--ledger-open (not drgnx-agent-panel--ledger-open))
  (when drgnx-agent-panel--ledger-open
    (setq drgnx-agent-panel--ledger-mark (let ((m -1)) (maphash (lambda (i _) (setq m (max m i))) drgnx-agent-panel--entries) m)))
  (drgnx-agent-panel-cards-plan-or-edits-changed))

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
