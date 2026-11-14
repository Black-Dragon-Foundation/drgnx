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
(require 'drgnx-icons)
(require 'drgnx-pixels)
(require 'drgnx-ui-kit)                 ; the buttons

(declare-function drgnx-agent-panel--send-look "drgnx-agent-panel")
(declare-function drgnx-agent-panel--width "drgnx-agent-panel-steps")
(declare-function drgnx-agent-panel--key-at "drgnx-agent-panel")
(declare-function drgnx-agent-panel-explain-note-always "drgnx-agent-panel-explain")
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

(defface drgnx-agent-panel-perm-head '((t :inherit (drgnx-ui-text drgnx-chip-attention) :weight bold))
  "The card of a request that waits on you (window-dark.html `.acard.perm'): its ring is in the attention colour (a
card's ring takes its text's colour), on the attention tint." :group 'drgnx-agent-panel)

(defconst drgnx-agent-panel-cards-max-files 20 "How many edited files get diff cards at most.")

(defvar-local drgnx-agent-panel--diffs nil "Alist: path → that file's unified diff (`work/hunks').")

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
  "LINES (strings without newlines, or (TEXT . FACE)) as a card to the panel's right edge, 12 px in: top, middle and
bottom rows in the card faces, PROPS on every row.  Each row's newline is outside the card's face: the card faces
extend, so in it the run would go on to the window's edge and the ring stay open there."
  (let ((n (length lines)) (i -1))
    (mapconcat (lambda (l)
                 (cl-incf i)
                 (let ((card (cond ((= n 1) 'drgnx-card-single) ((= i 0) 'drgnx-card-top)
                                   ((= i (1- n)) 'drgnx-card-bottom) (t 'drgnx-card-mid))))
                   (concat (apply #'propertize
                                  (concat " " (if (consp l) (car l) l)
                                          (propertize " " 'display `(space :align-to (- right (,(drgnx-px 12))))))
                                  'face (if (consp l) (list (cdr l) card) card) props)
                           (apply #'propertize "\n" props))))
               lines "")))

(defun drgnx-agent-panel-cards--action (label command face help)
  "LABEL in FACE, run COMMAND (a registry command) on a click.  No box of its own: inside a card, a run with another
box would cut the card's ring."
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] command)
    (propertize label 'face face 'mouse-face 'drgnx-hover 'keymap map 'help-echo help)))

(defun drgnx-agent-panel-cards--columns ()
  "How many code columns a card line has in this panel (the panel's width less the card's 12 px either side and the line
number), or 100 when the width is not known."
  (if-let* ((w (drgnx-agent-panel--width)))
      (max 8 (min 100 (- (/ (- w (* 2 (drgnx-px 12))) (max 1 (frame-char-width))) 6)))
    100))

(defun drgnx-agent-panel-cards--numbered (header body)
  "BODY's lines (a hunk's, under HEADER \"@@ -A,B +C,D @@\") as (TEXT . FACE): each after its line number (the new
file's, a removed line the old file's), FACE the panel's code face for its kind, cut to the panel's width."
  (let ((old (if (string-match "-\\([0-9]+\\)" header) (string-to-number (match-string 1 header)) 1))
        (new (if (string-match "\\+\\([0-9]+\\)" header) (string-to-number (match-string 1 header)) 1)))
    (mapcar (lambda (l)
              (let* ((c (and (not (string-empty-p l)) (aref l 0)))
                     (n (if (eq c ?-) (prog1 old (cl-incf old)) (prog1 new (cl-incf new) (unless (eq c ?+) (cl-incf old))))))
                (cons (concat (format "%4d " n)
                              (truncate-string-to-width (concat (if (memq c '(?+ ?-)) (string c) " ")
                                                                (if (memq c '(?+ ?- ?\s)) (substring l 1) l))
                                                        (drgnx-agent-panel-cards--columns) nil nil "…"))
                      (pcase c (?+ 'drgnx-agent-panel-added) (?- 'drgnx-agent-panel-removed) (_ 'drgnx-agent-panel-context)))))
            body)))

(defun drgnx-agent-panel-cards--diff-row (path i)
  "Hunk I of PATH (agent-panel.html `.acard'): a header with the file's icon and name, its lines and which hunk, Reject
and Accept; under it the hunk's lines, numbered, as a card.  The header sits over the card, not in it: a box is drawn
per run of one face, so its several faces would cut the ring; each card line is one face for the same reason."
  (let* ((hunks (drgnx-agent-panel-cards--hunks path)) (hunk (nth i hunks))
         (body (and hunk (seq-take (split-string (string-trim-right (plist-get hunk :text)) "\n") 30)))
         (props (list 'drgnx-agent-panel-hunk (cons path i))))
    (if (not hunk) "\n"
      (let* ((header (plist-get hunk :header))
             (start (if (string-match "\\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)?" header) (string-to-number (match-string 1 header)) 1))
             (len (if (match-string 2 header) (string-to-number (match-string 2 header)) 1))
             (actions (concat (drgnx-agent-panel-cards--action "Reject" #'drgnx-agent-panel-reject 'drgnx-text-muted
                                                               "D: take the change back")
                              "  "
                              (drgnx-agent-panel-cards--action "Accept" #'drgnx-agent-panel-accept 'drgnx-accent
                                                               "a: keep the change")))
             (room (let ((w (drgnx-agent-panel--width))) (and w (- w (string-pixel-width actions) (drgnx-px 20)))))
             (label (propertize (format "%d–%d · hunk %d of %d" start (+ start (max 0 (1- len))) (1+ i) (length hunks))
                                'face 'drgnx-agent-panel-subtle))
             (icon (concat " " (drgnx-look-icon 'file-code 'drgnx-text-muted) " "))
             ;; in a narrow panel the name gives way, then the label, so Reject and Accept stay inside the edge
             (name (let ((cols 50) (name (propertize (drgnx-agent-panel--one-line path 50) 'face 'bold)))
                     (while (and room (> cols 8)
                                 (> (+ (string-pixel-width icon) (string-pixel-width name) (string-pixel-width label)
                                       (string-pixel-width " "))
                                    room)
                                 (progn (setq cols (- cols 4))
                                        (setq name (propertize (drgnx-agent-panel--one-line path cols) 'face 'bold)))))
                     name))
             (label (if (and room (> (+ (string-pixel-width icon) (string-pixel-width name) (string-pixel-width label)
                                        (string-pixel-width " "))
                                     room))
                        "" label))
             (head (concat icon name " " label
                           (propertize " " 'display `(space :align-to (- right (,(+ (string-pixel-width actions) (drgnx-px 20))))))
                           actions "\n"))
             (lines (drgnx-agent-panel-cards--numbered header body)) (n (length lines)) (k -1))
        (add-text-properties 0 (length head) props head)
        (concat head
                (mapconcat (lambda (line)
                             (cl-incf k)
                             (let ((card (cond ((= n 1) 'drgnx-card-single) ((= k 0) 'drgnx-card-top)
                                               ((= k (1- n)) 'drgnx-card-bottom) (t 'drgnx-card-mid))))
                               (concat (apply #'propertize
                                              (concat " " (car line) (propertize " " 'display `(space :align-to (- right (,(drgnx-px 12))))))
                                              'face (list (cdr line) card) props)
                                       "\n")))
                           lines ""))))))

(defun drgnx-agent-panel-cards--request (id)
  (seq-find (lambda (p) (equal (plist-get p :id) id)) (drgnx-agent-panel-cards--permissions)))

(defun drgnx-agent-panel-cards--option (request kinds)
  "The id of REQUEST's first option whose kind is one of KINDS, or nil."
  (seq-some (lambda (o) (and (member (format "%s" (plist-get o :kind)) kinds) (plist-get o :optionId)))
            (append (plist-get request :options) nil)))

(defun drgnx-agent-panel-cards--perm-row (id)
  "Request ID as a card (window-dark.html `.acard.perm'): what the agent asks, one line ringed in the attention colour
on its tint, and under it Allow (the primary), Always and Deny as buttons with their keys.  The buttons sit under the
card, not in it: their boxes would cut its ring."
  (if-let* ((r (drgnx-agent-panel-cards--request id)))
      (concat (propertize (concat " " (drgnx-look-icon 'shield) " "
                                  (drgnx-agent-panel--one-line (or (plist-get r :title) "the agent asks") 70) "?"
                                  (propertize " " 'display `(space :align-to (- right (,(drgnx-px 12))))))
                          'face '(drgnx-agent-panel-perm-head drgnx-card-single) 'drgnx-agent-panel-perm id)
              ;; the newline outside the card's face: in it the run would go on to the window's edge, the ring open
              (propertize "\n" 'drgnx-agent-panel-perm id)
              (propertize (concat " " (drgnx-agent-panel-cards--action " Allow ↵ " #'drgnx-agent-panel-allow
                                                                       'drgnx-ui-button-primary "RET: allow it once")
                                  " " (drgnx-agent-panel-cards--action " Always A " #'drgnx-agent-panel-always
                                                                       'drgnx-ui-button "A: allow it from now on")
                                  " " (drgnx-agent-panel-cards--action " Deny D " #'drgnx-agent-panel-reject
                                                                       'drgnx-ui-button "D: deny it")
                                  "\n")
                          'drgnx-agent-panel-perm id))
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
    (let ((always (drgnx-agent-panel-cards--option r '("allow_always"))))
      (drgnx-agent-panel--answer r (or always (drgnx-agent-panel-cards--option r '("allow_once" "allow"))))
      (when always (drgnx-agent-panel-explain-note-always r)))))

;;;; Loading the edited files' diffs

(defun drgnx-agent-panel-cards-load (buffer)
  "Ask the hub for the files the session edited and each one's diff; the cards follow."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      ;; a paired chat has no worktree diffs: its hunks are the ledger's, which the hub reads
      (unless (drgnx-agent-panel-cards--paired-p)
        (let ((sid drgnx-agent-panel--session))
          (drgnx-agent-panel--ask
           "work/files" (list :session sid)
           (lambda (r err)
             (when (and (not err) (buffer-live-p buffer))
               (with-current-buffer buffer
                 (setq drgnx-agent-panel--files (append (plist-get r :files) nil))
                 (drgnx-agent-panel--reconcile))
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

(defun drgnx-agent-panel-cards-note-entries (buffer touched from-slice)
  "Entries TOUCHED arrived in BUFFER: when a live one is an edit that finished, the diffs are asked for again soon.
FROM-SLICE: they came from a page."
  (with-current-buffer buffer
    (when (and (not from-slice)
               (seq-some (lambda (idx)
                           (let ((e (gethash idx (buffer-local-value 'drgnx-agent-panel--entries buffer))))
                             (and e (equal (plist-get e :kind) "edit") (equal (plist-get e :status) "completed"))))
                         touched))
      (drgnx-timer-soon (cons 'agent-panel-cards buffer) 0.3 #'drgnx-agent-panel-cards-load :args (list buffer) :owner buffer))))

(defvar drgnx-agent-panel--entries)

;;;; Pinned cards and the edits ledger (the hub's cards; the to-do list is the hub's alone)

(defvar-local drgnx-agent-panel--pins nil "Pinned cards of this chat, newest last: a list of (KEY . TEXT).")
(defvar-local drgnx-agent-panel--files nil "The files the session edited, from `work/files': plists with :path :plus :minus.")
(defvar-local drgnx-agent-panel--ledger-open nil "Non-nil while the ledger lists its files (the hub builds the card).")

(defun drgnx-agent-panel--pin-text (key)
  "A line that stands for the row KEY, for a pinned card."
  (pcase (car-safe key)
    (:e (let ((e (drgnx-agent-panel--entry (cadr key))))
          (drgnx-agent-panel--one-line (or (plist-get e :title) (plist-get e :text) (format "%s" (plist-get e :type))) 80)))
    (:diff (format "%s %s" (cadr key) (plist-get (nth (nth 2 key) (drgnx-agent-panel-cards--hunks (cadr key))) :header)))
    (:perm (plist-get (drgnx-agent-panel-cards--request (cadr key)) :title))
    (_ nil)))

(defun drgnx-agent-panel-pin ()
  "Pin the card or step at point under the strip; again to unpin it.  A pinned card is the hub's row: its text goes
to the hub with the look (`agents/panel/look' `pins'), which builds the card."
  (interactive)
  (let ((n (get-text-property (point) 'drgnx-agent-panel-pin)))
    (if (integerp n)
        (setq drgnx-agent-panel--pins (append (seq-take drgnx-agent-panel--pins n) (nthcdr (1+ n) drgnx-agent-panel--pins)))
      (let* ((key (drgnx-agent-panel--key-at)) (text (and key (drgnx-agent-panel--pin-text key))))
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
