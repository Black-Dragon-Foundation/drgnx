;;; drgnx-history-revert.el --- revert to here, fork from here, redo, and the cards they open -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The editor's side of reverting an agent's work (docs/develop/history.md, "Revert, redo and fork").  The commands take
;; a session and a step (`drgnx-history-revert-to-here', `-fork-here', `-redo'); asked from M-x without them they take
;; the session of the work trail or the one running session, and its last step.
;; - The revert card is a buffer a command opens, never an event: what the revert cannot undo first, then the files and
;;   the user's later edits it meets, then the level of the conversation.  Keys: `k' keep mine / `r' roll back mine, `t'
;;   takes the reverted file at an overlap, `e' writes the message a summary-level revert needs, `a' applies, `f' forks
;;   instead (offered when the revert is blocked or the worker has finished).
;; - Fork from here reads the user's message with `read-string' inside the command; the prompt carries part 5's forecast
;;   line when `drgnx-forecast-line' exists and the hub answers `forecast/session'.  No job, no card.
;; - `history/applied' (the hub's broadcast after a revert, redo or take) is a notice and a quiet revert of the clean
;;   buffers; a buffer with unsaved changes in the files is never touched, a card (keep mine / take theirs / edit) waits
;;   behind the notice (`drgnx-history-resolve-dirty').  Nothing in the event path prompts or waits.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'drgnx-history)
(require 'drgnx-notice)
(require 'drgnx-registry)
(require 'drgnx-ui-kit)

(declare-function drgnx-hub-call "drgnx-hub-client" (method params callback &rest keys))
(declare-function drgnx-hub-call-sync "drgnx-hub-client" (method params &optional timeout))
(declare-function drgnx-history-compare "drgnx-history-compare" (a b))
(declare-function drgnx-forecast-line "drgnx-say" (forecast))
(declare-function diff-no-select "diff" (old new &optional switches no-async buf))
(declare-function ediff-buffers "ediff" (buffer-a buffer-b &optional startup-hooks job-name merge-buffer-file))
(defvar nidhogg-history-origin)
(defvar drgnx-hub--event-conn)
(defvar drgnx-work-trail--session)
(defvar drgnx-agents--sessions)
(declare-function drgnx-agent-session-remote "drgnx-agents" (session))

(defface drgnx-history-heading '((t :inherit bold)) "A section's title on a revert card." :group 'drgnx)
(defface drgnx-history-effect '((t :inherit warning)) "A thing a revert cannot undo." :group 'drgnx)
(defface drgnx-history-label '((t :inherit shadow)) "A note on a revert card: a label, a level, a count." :group 'drgnx)

;;;; Finding the session and the step

(defun drgnx-history-revert--sessions ()
  "The ids of the hub sessions this Emacs mirrors, newest first."
  (and (boundp 'drgnx-agents--sessions)
       (delq nil (mapcar (lambda (s) (drgnx-agent-session-remote s)) drgnx-agents--sessions))))

(defun drgnx-history-revert--default-session ()
  "The session a command run from M-x means: the work trail's here, else the only mirrored one, else asked."
  (or (and (boundp 'drgnx-work-trail--session) drgnx-work-trail--session)
      (pcase (drgnx-history-revert--sessions)
        ('nil (user-error "No agent session to go back in"))
        (`(,only) only)
        (all (completing-read "Session: " all nil t)))))

(defun drgnx-history-revert--steps (session params)
  "The steps `timeline/get' answers for SESSION with PARAMS (limit, before), oldest first."
  (plist-get (drgnx-hub-call-sync "timeline/get" (append (list :scope "session" :id session) params) 10) :steps))

(defun drgnx-history-revert--last-seq (session)
  "The `seq' of SESSION's newest step."
  (let ((step (car (last (drgnx-history-revert--steps session '(:limit 1))))))
    (or (and step (plist-get step :seq)) (user-error "Session %s has no steps" session))))

(defun drgnx-history-revert--step (session seq)
  "SESSION's step SEQ (a `timeline/get' step plist), or nil."
  (let ((step (car (last (drgnx-history-revert--steps session (list :before (1+ seq) :limit 1))))))
    (and step (eql (plist-get step :seq) seq) step)))

(defun drgnx-history-revert--args ()
  "The (SESSION SEQ) a command run from M-x takes: the default session and its last step."
  (let ((session (drgnx-history-revert--default-session)))
    (list session (drgnx-history-revert--last-seq session))))

(defun drgnx-history-revert--resolve (session seq)
  "(SESSION SEQ) with a missing SESSION or SEQ filled in as M-x would."
  (let ((session (or session (drgnx-history-revert--default-session))))
    (list session (or seq (drgnx-history-revert--last-seq session)))))

;;;; The revert card

(defvar-local drgnx-history-revert--preview nil "The hub's preview this card shows.")
(defvar-local drgnx-history-revert--mode nil "`keep-mine' or `roll-back-mine'.")
(defvar-local drgnx-history-revert--taken nil "Paths of overlaps whose answer is the reverted file.")
(defvar-local drgnx-history-revert--message nil "The user's message for a summary-level revert.")

(defvar drgnx-history-revert-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "k") #'drgnx-history-revert-keep-mine)
    (define-key m (kbd "r") #'drgnx-history-revert-roll-back-mine)
    (define-key m (kbd "t") #'drgnx-history-revert-take-reverted)
    (define-key m (kbd "e") #'drgnx-history-revert-message)
    (define-key m (kbd "a") #'drgnx-history-revert-apply)
    (define-key m (kbd "f") #'drgnx-history-revert-fork)
    m)
  "Keys of the revert card.")

(define-derived-mode drgnx-history-revert-mode special-mode "Revert"
  "The card of one revert to a step: nothing happens until \\[drgnx-history-revert-apply]."
  (setq-local truncate-lines nil)
  (buffer-disable-undo))

(defun drgnx-history-revert--finished-p (preview)
  "Whether PREVIEW says the conversation is not restored."
  (equal (plist-get (plist-get preview :conversation) :state) "not-restored"))

(defun drgnx-history-revert--section (title)
  "Insert TITLE as a section's heading."
  (insert (propertize title 'face 'drgnx-history-heading) "\n"))

(defun drgnx-history-revert--insert-effects (effects)
  "Insert what a revert cannot undo, from the hub's EFFECTS, and return how many lines that was."
  (let ((n 0))
    (cl-flet ((line (text) (insert "  " (drgnx-ui-status 'warn text) "\n") (cl-incf n)))
      (dolist (p (plist-get effects :pushed))
        (line (format "pushed: %s (%s)" (plist-get p :commit) (string-join (plist-get p :refs) ", "))))
      (dolist (m (plist-get effects :merges)) (line (format "merged: %s" m)))
      (dolist (j (plist-get effects :jobs_running)) (line (format "job running: %s" j)))
      (dolist (s (plist-get effects :settings)) (line (format "setting changed: %s" s)))
      (dolist (tk (plist-get effects :tasks_filed)) (line (format "task filed: %s" tk)))
      (when (plist-get effects :messages_read)
        (line (format "%d message%s already read" (length (plist-get effects :messages_read))
                      (if (cdr (plist-get effects :messages_read)) "s" ""))))
      (when (plist-get effects :decisions_relied_on)
        (line (format "decisions others rely on: %s"
                      (string-join (mapcar #'number-to-string (plist-get effects :decisions_relied_on)) ", "))))
      (let ((spent (plist-get effects :spent)))
        (when (and spent (> (or (plist-get spent :tokens) 0) 0))
          (line (format "%s tokens spent after this step" (plist-get spent :tokens))))))
    (when (and (> n 0) (plist-get effects :label))
      (insert (propertize (format "  (%s)\n" (plist-get effects :label)) 'face 'drgnx-history-label)))
    n))

(defun drgnx-history-revert--insert-card ()
  "Draw the card of `drgnx-history-revert--preview' in the current buffer."
  (let* ((p drgnx-history-revert--preview) (inhibit-read-only t) (here (point)))
    (erase-buffer)
    (insert (propertize (format "Revert %s to step %s\n\n" (plist-get p :session) (plist-get p :seq))
                        'face 'drgnx-history-heading))
    (drgnx-history-revert--section "What this cannot undo")
    (when (zerop (drgnx-history-revert--insert-effects (plist-get p :effects)))
      (insert (propertize "  nothing the hub knows of\n" 'face 'drgnx-history-label)))
    (insert "\n")
    (drgnx-history-revert--section "Files")
    (dolist (f (plist-get p :files)) (insert "  " f "\n"))
    (dolist (f (plist-get p :non_overlapping_files))
      (insert "  " f (propertize "  (merged with your edit)" 'face 'drgnx-history-label) "\n"))
    (dolist (s (plist-get p :skipped))
      (insert "  " (plist-get s :path)
              (propertize (format "  (%s)" (if (member (plist-get s :reason) '("hook" "refused-by-hook" "refused by hook"))
                                               "refused by hook" (plist-get s :reason)))
                          'face 'drgnx-history-label)
              "\n"))
    (when (plist-get p :overlaps)
      (insert "\n")
      (drgnx-history-revert--section "Your later edits it meets")
      (dolist (o (plist-get p :overlaps))
        (let ((path (plist-get o :path)))
          (insert (propertize "  " 'drgnx-history-overlap path)
                  (propertize path 'drgnx-history-overlap path) "  "
                  (propertize (if (member path drgnx-history-revert--taken) "[reverted file]" "[your file stays]")
                              'face 'drgnx-history-label 'drgnx-history-overlap path)
                  "\n"))))
    (insert "\n")
    (drgnx-history-revert--section "Conversation")
    (insert "  " (pcase (plist-get p :level)
                   ("message" "back to the step's message")
                   ("turn" "back to the last turn that finished at or before the step")
                   (_ (concat (propertize "Summary" 'face 'drgnx-history-effect)
                              ": a new conversation told a summary, not the original")))
            "\n")
    (when (drgnx-history-revert--finished-p p)
      (insert "  " (drgnx-ui-status 'warn (plist-get (plist-get p :conversation) :label)) "\n"))
    (when (eq (plist-get p :needs_message) t)
      (insert "  message: "
              (if drgnx-history-revert--message (propertize drgnx-history-revert--message 'face 'drgnx-history-label)
                (propertize "(none yet; e writes it)" 'face 'drgnx-history-effect))
              "\n"))
    (insert "\n")
    (drgnx-history-revert--section "Your later edits")
    (insert "  " (if (eq drgnx-history-revert--mode 'roll-back-mine) "roll back mine too" "keep mine") "  ")
    (drgnx-ui-insert-button "keep mine" #'drgnx-history-revert-keep-mine :help "Only the agent's changes go")
    (insert " ")
    (drgnx-ui-insert-button "roll back mine" #'drgnx-history-revert-roll-back-mine
                            :help "Every file goes back; your versions are kept under undone")
    (insert "\n\n")
    (if (and (plist-get p :blocked) (not (eq (plist-get p :blocked) :false)))
        (progn
          (dolist (b (plist-get p :blocked))
            (insert "  " (drgnx-ui-status 'fail (format "blocked: %s on %s depends on decision %s"
                                                        (plist-get b :commit) (plist-get b :branch) (plist-get b :decision)))
                    "\n"))
          (drgnx-ui-insert-button "Fork" #'drgnx-history-revert-fork :help "A second agent from this step instead"))
      (drgnx-ui-insert-button "Apply" #'drgnx-history-revert-apply :help "Revert: one record, one forward commit")
      (when (eq (plist-get p :fork) t)
        (insert "  ")
        (drgnx-ui-insert-button "Fork" #'drgnx-history-revert-fork :help "A second agent from this step instead")))
    (insert "\n")
    (goto-char (min here (point-max)))))

(defun drgnx-history-revert--open (preview)
  "Open the card for the hub's PREVIEW; the buffer."
  (let ((buffer (get-buffer-create (format "*drgnx revert: %s step %s*" (plist-get preview :session) (plist-get preview :seq)))))
    (with-current-buffer buffer
      (drgnx-history-revert-mode)
      (setq drgnx-history-revert--preview preview drgnx-history-revert--mode 'keep-mine
            drgnx-history-revert--taken nil drgnx-history-revert--message nil)
      (drgnx-history-revert--insert-card)
      (goto-char (point-min)))
    (pop-to-buffer buffer)
    buffer))

;;;###autoload
(defun drgnx-history-revert-to-here (&optional session seq)
  "Open the card of reverting SESSION's work to its step SEQ; nothing changes until the card's Apply.
From M-x: the work trail's session (or the one running), and its last step."
  (interactive (drgnx-history-revert--args))
  (pcase-let ((`(,session ,seq) (drgnx-history-revert--resolve session seq)))
    (drgnx-history-revert--open (drgnx-hub-call-sync "history/revert/preview" (list :session session :seq seq) 15))))

(defun drgnx-history-revert--require-card ()
  "The preview of this buffer's card, or a user error."
  (or drgnx-history-revert--preview (user-error "Not a revert card")))

(defun drgnx-history-revert-keep-mine ()
  "On the card: only the agent's changes go; the user's later edits stay."
  (interactive)
  (drgnx-history-revert--require-card)
  (setq drgnx-history-revert--mode 'keep-mine)
  (drgnx-history-revert--insert-card))

(defun drgnx-history-revert-roll-back-mine ()
  "On the card: every file goes back to the step; the user's later versions are kept under undone."
  (interactive)
  (drgnx-history-revert--require-card)
  (setq drgnx-history-revert--mode 'roll-back-mine)
  (drgnx-history-revert--insert-card))

(defun drgnx-history-revert-take-reverted ()
  "On the card, at an overlap: toggle between the user's file staying and the reverted file."
  (interactive)
  (drgnx-history-revert--require-card)
  (let ((path (get-text-property (point) 'drgnx-history-overlap)))
    (unless path (user-error "Put point on one of your later edits"))
    (setq drgnx-history-revert--taken (if (member path drgnx-history-revert--taken)
                                          (delete path drgnx-history-revert--taken)
                                        (cons path drgnx-history-revert--taken)))
    (drgnx-history-revert--insert-card)))

(defun drgnx-history-revert-message ()
  "On the card: write the message the restored conversation is told first."
  (interactive)
  (drgnx-history-revert--require-card)
  (setq drgnx-history-revert--message (read-string "Message to the agent: " drgnx-history-revert--message))
  (drgnx-history-revert--insert-card))

(defun drgnx-history-revert--choices (preview taken)
  "One hub choice per overlap of PREVIEW, in its order: the reverted file for the paths in TAKEN."
  (mapcar (lambda (o) (list :choice (if (member (plist-get o :path) taken) "take-reverted" "keep-users")))
          (plist-get preview :overlaps)))

(defun drgnx-history-revert--applied (buffer result err)
  "The hub's answer to Apply, for the card in BUFFER."
  (if err
      (message "Revert refused: %s" err)
    (when (buffer-live-p buffer) (kill-buffer buffer))
    (message "Reverted %s (record %s)" (plist-get result :session) (plist-get result :op))))

(defun drgnx-history-revert-apply ()
  "On the card: apply the revert (a blocked one cannot be applied; fork instead)."
  (interactive)
  (let ((p (drgnx-history-revert--require-card)))
    (when (and (plist-get p :blocked) (not (eq (plist-get p :blocked) :false)))
      (user-error "This revert is blocked; fork from the step instead"))
    (when (and (eq (plist-get p :needs_message) t) (not drgnx-history-revert--message))
      (setq drgnx-history-revert--message (read-string "Message to the agent (this conversation comes back as a summary): ")))
    (let ((buffer (current-buffer)))
      (drgnx-hub-call "history/revert/apply"
                      (append (list :preview_id (plist-get p :preview_id)
                                    :mode (symbol-name drgnx-history-revert--mode)
                                    :choices (drgnx-history-revert--choices p drgnx-history-revert--taken))
                              (and drgnx-history-revert--message (list :message drgnx-history-revert--message)))
                      (lambda (result err) (drgnx-history-revert--applied buffer result err))
                      :deadline 60))))

(defun drgnx-history-revert-fork ()
  "On the card: fork from this step instead."
  (interactive)
  (let ((p (drgnx-history-revert--require-card)))
    (drgnx-history-fork-here (plist-get p :session) (plist-get p :seq))))

;;;; Fork from here

(defun drgnx-history-revert--forecast-line (session)
  "Part 5's one-line forecast of one more run like SESSION, or nil: without `drgnx-forecast-line', or when the hub
cannot say."
  (when (fboundp 'drgnx-forecast-line)
    (condition-case nil
        (let ((forecast (drgnx-hub-call-sync "forecast/session" (list :session session) 5)))
          (and forecast (drgnx-forecast-line forecast)))
      (error nil))))

;;;###autoload
(defun drgnx-history-fork-here (&optional session seq)
  "Start a second agent from SESSION's step SEQ, in its own tree, and compare its work with the first's.
Asks for the first message (the prompt says what one more run like this costs when part 5's forecast is there).
From M-x: the work trail's session (or the one running), and its last step."
  (interactive (drgnx-history-revert--args))
  (pcase-let* ((`(,session ,seq) (drgnx-history-revert--resolve session seq))
               (line (drgnx-history-revert--forecast-line session))
               (message (read-string (if line (format "Fork from step %s (%s): " seq line) (format "Fork from step %s: " seq))))
               (fork (drgnx-hub-call-sync "history/fork" (list :session session :seq seq :message message) 30)))
    (message "Forked %s from step %s: %s" session seq (plist-get fork :id))
    (when (and (plist-get fork :source_branch) (plist-get fork :branch) (require 'drgnx-history-compare nil t))
      (drgnx-history-compare (plist-get fork :source_branch) (plist-get fork :branch)))
    fork))

;;;###autoload
(defun drgnx-history-redo (&optional session seq)
  "Redo the revert that abandoned SESSION's step SEQ: its files go back to what they were before it.
From M-x: the work trail's session (or the one running), and its last step."
  (interactive (drgnx-history-revert--args))
  (pcase-let* ((`(,session ,seq) (drgnx-history-revert--resolve session seq))
               (step (drgnx-history-revert--step session seq))
               (op (and step (plist-get step :undone_by))))
    (unless (integerp op) (user-error "Step %s of %s was not undone by a revert" seq session))
    (let ((out (drgnx-hub-call-sync "history/redo" (list :session session :op op) 30)))
      (message "Redone: %d file%s written" (length (plist-get out :written)) (if (cdr (plist-get out :written)) "s" ""))
      out)))

;;;; The events: the files a revert wrote
;; Nothing between here and the end marker prompts or waits: it runs from the hub's event connection.

(defvar drgnx-history-revert--waiting nil
  "List of (OP . BUFFER): buffers with unsaved changes in a file a revert wrote, whose card has not been answered.
Bounded: `drgnx-history-revert--waiting-max' newest, dead buffers dropped at each event.")

(defconst drgnx-history-revert--waiting-max 50 "Most buffers kept waiting for their card.")

(defun drgnx-history-revert--buffers (worktree paths)
  "The live buffers visiting PATHS (relative to WORKTREE, or absolute)."
  (let ((files (mapcar (lambda (p) (expand-file-name p worktree)) paths)) (found nil))
    (dolist (b (buffer-list))
      (let ((f (buffer-local-value 'buffer-file-name b)))
        (when (and f (member f files)) (push b found))))
    (nreverse found)))

(defun drgnx-history-revert--refresh (buffer)
  "Revert the clean BUFFER to its file's new text, as the hub's change, not the user's."
  (with-current-buffer buffer
    (when (file-exists-p buffer-file-name)
      (drgnx-history-with-origin "revert" (revert-buffer t t t)))))

(defun drgnx-history-revert--event (event data)
  "`drgnx-hub-event-functions': after `history/applied' from a hub that proved itself, clean buffers of the written
files revert quietly; a buffer with unsaved changes waits behind a notice (never a prompt)."
  (when (and (equal event "history/applied") (processp (bound-and-true-p drgnx-hub--event-conn))
             (process-get drgnx-hub--event-conn :drgnx-proven))
    (setq drgnx-history-revert--waiting
          (cl-remove-if-not (lambda (e) (buffer-live-p (cdr e))) drgnx-history-revert--waiting))
    (let ((op (plist-get data :op)) (dirty nil))
      (dolist (b (drgnx-history-revert--buffers (plist-get data :worktree) (plist-get data :paths)))
        (if (buffer-modified-p b)
            (push b dirty)
          (condition-case nil (drgnx-history-revert--refresh b) (error nil))))
      (when dirty
        (dolist (b (nreverse dirty)) (push (cons op b) drgnx-history-revert--waiting))
        (setq drgnx-history-revert--waiting
              (seq-take drgnx-history-revert--waiting drgnx-history-revert--waiting-max))
        (drgnx-notify 'hub 'warn
                      (format "%d file%s with unsaved changes met a revert" (length dirty) (if (cdr dirty) "s" ""))
                      :id (intern (format "history-dirty-%s" op)) :life 'condition
                      :fix "History: Resolve Unsaved Changes"
                      :command (list 'drgnx-history-resolve-dirty op))))))
;; end of the event path

;;;; A buffer with unsaved changes that met a revert

(defvar-local drgnx-history-revert--target nil "The buffer this merge card decides for.")

(defvar drgnx-history-merge-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "k") #'drgnx-history-merge-keep-mine)
    (define-key m (kbd "t") #'drgnx-history-merge-take-theirs)
    (define-key m (kbd "e") #'drgnx-history-merge-edit)
    m)
  "Keys of the merge card.")

(define-derived-mode drgnx-history-merge-mode special-mode "Merge"
  "The card of one buffer whose unsaved changes met a revert: \\[drgnx-history-merge-keep-mine], \\[drgnx-history-merge-take-theirs] or \\[drgnx-history-merge-edit]."
  (buffer-disable-undo))

(defun drgnx-history-revert--disk-text (buffer)
  "The text of BUFFER's file on disk."
  (with-temp-buffer
    (insert-file-contents (buffer-local-value 'buffer-file-name buffer))
    (buffer-string)))

(defun drgnx-history-revert--insert-merge-card (buffer)
  "Draw the merge card of BUFFER in the current buffer: the diff from the new file to the unsaved text."
  (let ((inhibit-read-only t) (disk (drgnx-history-revert--disk-text buffer)) (mine nil))
    (erase-buffer)
    (insert (propertize (format "%s has unsaved changes, and a revert changed the file\n\n"
                                (file-name-nondirectory (buffer-local-value 'buffer-file-name buffer)))
                        'face 'drgnx-history-heading))
    (drgnx-ui-insert-button "keep mine" #'drgnx-history-merge-keep-mine :help "Your text stays; saving overwrites the revert")
    (insert " ")
    (drgnx-ui-insert-button "take theirs" #'drgnx-history-merge-take-theirs :help "The reverted file replaces your unsaved text")
    (insert " ")
    (drgnx-ui-insert-button "edit" #'drgnx-history-merge-edit :help "Merge the two in Ediff")
    (insert "\n\nChanges from the file on disk to your buffer:\n\n")
    (setq mine (with-current-buffer buffer (buffer-substring-no-properties (point-min) (point-max))))
    (let ((a (generate-new-buffer " *drgnx disk*" t)) (b (generate-new-buffer " *drgnx mine*" t)))
      (unwind-protect
          (progn
            (with-current-buffer a (insert disk))
            (with-current-buffer b (insert mine))
            (let ((d (diff-no-select a b "-u" t)))
              (unwind-protect (insert-buffer-substring d) (kill-buffer d))))
        (kill-buffer a) (kill-buffer b)))
    (goto-char (point-min))))

;;;###autoload
(defun drgnx-history-resolve-dirty (&optional op)
  "Open the card of a buffer whose unsaved changes met a revert (OP's, else any); nothing changes until it is answered."
  (interactive)
  (setq drgnx-history-revert--waiting
        (cl-remove-if-not (lambda (e) (buffer-live-p (cdr e))) drgnx-history-revert--waiting))
  (let ((entry (or (cl-find op drgnx-history-revert--waiting :key #'car)
                   (car drgnx-history-revert--waiting)
                   (user-error "No buffer is waiting on a revert"))))
    (let ((card (get-buffer-create (format "*drgnx merge: %s*" (buffer-name (cdr entry))))))
      (with-current-buffer card
        (drgnx-history-merge-mode)
        (setq drgnx-history-revert--target (cdr entry))
        (drgnx-history-revert--insert-merge-card (cdr entry)))
      (pop-to-buffer card))))

(defun drgnx-history-revert--done ()
  "Forget the buffer of this merge card and kill the card; the notice goes when no buffer waits on its record."
  (let ((target drgnx-history-revert--target) (card (current-buffer)))
    (unless target (user-error "Not a merge card"))
    (let ((entry (rassq target drgnx-history-revert--waiting)))
      (setq drgnx-history-revert--waiting (delq entry drgnx-history-revert--waiting))
      (when (and entry (not (assq (car entry) drgnx-history-revert--waiting)))
        (drgnx-notice-clear 'hub (intern (format "history-dirty-%s" (car entry))))))
    (kill-buffer card)
    target))

(defun drgnx-history-merge-keep-mine ()
  "On the merge card: the unsaved text stays, and saving it is accepted over the file the revert wrote."
  (interactive)
  (let ((target (drgnx-history-revert--done)))
    (with-current-buffer target (set-visited-file-modtime))
    (message "Kept your unsaved text in %s" (buffer-name target))))

(defun drgnx-history-merge-take-theirs ()
  "On the merge card: the reverted file replaces the unsaved text (as the hub's change, not the user's)."
  (interactive)
  (let ((target (drgnx-history-revert--done)))
    (with-current-buffer target (set-buffer-modified-p nil))
    (drgnx-history-revert--refresh target)
    (message "%s now holds the reverted file" (buffer-name target))))

(defun drgnx-history-merge-edit ()
  "On the merge card: merge the two by hand in Ediff (your buffer and the file on disk)."
  (interactive)
  (require 'ediff)
  (let* ((target (drgnx-history-revert--done))
         (disk (generate-new-buffer (format "%s (reverted)" (buffer-name target)))))
    (with-current-buffer disk (insert (drgnx-history-revert--disk-text target)))
    (with-current-buffer target (set-visited-file-modtime))
    (ediff-buffers target disk)))

;;;; Commands

(defun drgnx-history-revert-register-commands ()
  "The history commands."
  (drgnx-command-define 'history-revert-to-here :category "Agents" :title "History: Revert to Here"
                        :command #'drgnx-history-revert-to-here
                        :doc "Show what going back to an agent's step would do, then apply it from the card")
  (drgnx-command-define 'history-fork-here :category "Agents" :title "History: Fork from Here"
                        :command #'drgnx-history-fork-here
                        :doc "Start a second agent from an agent's step, in its own tree")
  (drgnx-command-define 'history-redo :category "Agents" :title "History: Redo a Revert"
                        :command #'drgnx-history-redo
                        :doc "Put back what a revert took away")
  (drgnx-command-define 'history-resolve-dirty :category "Agents" :title "History: Resolve Unsaved Changes"
                        :command #'drgnx-history-resolve-dirty
                        :doc "Decide for a buffer whose unsaved changes met a revert")
  (drgnx-command-define 'history-merge-keep-mine :category "Agents" :title "History: Keep My Unsaved Text"
                        :command #'drgnx-history-merge-keep-mine
                        :doc "On a merge card: your unsaved text stays")
  (drgnx-command-define 'history-merge-take-theirs :category "Agents" :title "History: Take the Reverted File"
                        :command #'drgnx-history-merge-take-theirs
                        :doc "On a merge card: the reverted file replaces your unsaved text")
  (drgnx-command-define 'history-merge-edit :category "Agents" :title "History: Merge by Hand"
                        :command #'drgnx-history-merge-edit
                        :doc "On a merge card: merge the two in Ediff"))

(provide 'drgnx-history-revert)
;;; drgnx-history-revert.el ends here
