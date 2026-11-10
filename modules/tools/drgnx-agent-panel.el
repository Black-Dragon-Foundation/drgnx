;;; drgnx-agent-panel.el --- Module tools/agent-panel: one agent session's steps, live, in the right dock -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The agent panel shows one session of the hub: a header (who, and what it is doing), a row of chips (only the ones
;; the hub feeds), then the transcript as rows, one per entry: a tool call is a step on one line, its thinking folded
;; under it.  It is a `drgnx-view' (wb/drgnx-view.el): a new entry is appended and a changed one is patched in place,
;; so a stream never re-renders what is already there.  Rows are drawn visible first, in slices of at most 4 ms that
;; stop on input.
;;
;; A panel is a buffer per session.  It asks the hub for the session's entries (`agents/entries/subscribe') only
;; while a window shows it, and takes the last page of steps (`drgnx-agent-panel-page-steps', 50) from the hub with
;; the entries of their messages (`timeline/get', then `agents/slice'); older pages come when the view scrolls to its
;; top.  The snapshot comes from the `agent' event.  Nothing here writes to an agent's worktree or builds a queue of
;; its own: the composer, the cards and the pinned cards are in the sibling files, loaded from here.
;;
;; The transcript's rows are the hub's (docs/develop/hub.md, "The agent panel's rows"): the panel is the hub-fed view
;; `agent-panel/SESSION' too (`drgnx-view-patch-attach' with KEEP), and its patches go between the rows above the
;; transcript and the `(:rows-end)' row (`drgnx-agent-panel--apply-rows').  The header, the chips, the strip, the cards
;; and the composer stay the panel's own rows.  Which step types are open, the rows opened by hand and how far back the
;; rows go are told to the hub (`agents/panel/look').  The entries still come (the cards, the pins and the step at
;; point read them), but draw nothing.  Behind `drgnx-view-old-path', or made while the hub is down, the panel draws
;; every row itself, as before.
;; See docs/guide/agent-panel.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-view)
(require 'drgnx-hub-client)
(require 'drgnx-panes)                   ; the right island the panel opens in
(require 'drgnx-view-nav)                ; the moves between steps of a kind, through the replica
(require 'text-property-search)          ; the moves look through the drawn rows

(declare-function drgnx-hub--call-on "drgnx-hub-client")
(declare-function drgnx-view-env-register "drgnx-view-env")
(declare-function drgnx-view-env-update "drgnx-view-env")
(defvar drgnx-hub--events)

(defgroup drgnx-agent-panel nil "The agent panel." :group 'drgnx)

(defcustom drgnx-agent-panel-page-steps 50
  "How many steps a page of the panel holds: it opens with the last page and asks for the one before when you scroll
to its top.  The hub gives at most 50."
  :type 'integer :group 'drgnx-agent-panel)

(defcustom drgnx-agent-panel-slow-seconds 10
  "A step that took longer than this many seconds shows its time in the warning face."
  :type 'number :group 'drgnx-agent-panel)

(defcustom drgnx-agent-panel-expensive-cost 0.5
  "A step that cost more than this (in the step's own unit) shows its cost in the warning face."
  :type 'number :group 'drgnx-agent-panel)

;;;; Faces: all inherit the look's semantic faces

(defface drgnx-agent-panel-title '((t :inherit bold)) "The panel header's agent name." :group 'drgnx-agent-panel)
(defface drgnx-agent-panel-subtle '((t :inherit drgnx-text-muted)) "Secondary text: results, thinking, hints."
  :group 'drgnx-agent-panel)
(defface drgnx-agent-panel-chip '((t :inherit drgnx-chip)) "A chip of the header row." :group 'drgnx-agent-panel)
(defface drgnx-agent-panel-code '((t :inherit drgnx-code-small)) "A step's time and cost." :group 'drgnx-agent-panel)
(defface drgnx-agent-panel-warn '((t :inherit drgnx-status-warn)) "A slow or expensive step." :group 'drgnx-agent-panel)
(defface drgnx-agent-panel-ok '((t :inherit drgnx-status-ok)) "A step that finished." :group 'drgnx-agent-panel)
(defface drgnx-agent-panel-fail '((t :inherit drgnx-status-fail)) "A step that failed." :group 'drgnx-agent-panel)
(defface drgnx-agent-panel-run '((t :inherit drgnx-status-info)) "A step that has not finished." :group 'drgnx-agent-panel)
(defface drgnx-agent-panel-you '((t :inherit drgnx-accent)) "Your messages." :group 'drgnx-agent-panel)
(defface drgnx-agent-panel-md-emph '((t :inherit italic)) "Emphasis in an agent message." :group 'drgnx-agent-panel)
(defface drgnx-agent-panel-md-strong '((t :inherit bold)) "Strong text in an agent message." :group 'drgnx-agent-panel)
(defface drgnx-agent-panel-md-strike '((t :strike-through t)) "Struck-out text in an agent message."
  :group 'drgnx-agent-panel)
(defface drgnx-agent-panel-md-link '((t :inherit link)) "A link in an agent message." :group 'drgnx-agent-panel)
(defface drgnx-agent-panel-md-code '((t :inherit drgnx-code-small)) "Code in an agent message."
  :group 'drgnx-agent-panel)
(defface drgnx-agent-panel-md-heading '((t :inherit drgnx-ui-heading)) "A heading in an agent message."
  :group 'drgnx-agent-panel)
(defface drgnx-agent-panel-md-quote '((t :inherit (drgnx-text-muted italic))) "A quote in an agent message."
  :group 'drgnx-agent-panel)
(defface drgnx-agent-panel-md-rule '((t :inherit drgnx-border)) "A horizontal rule in an agent message."
  :group 'drgnx-agent-panel)
(defface drgnx-agent-panel-added '((t :inherit diff-added)) "An added line of a step's diff." :group 'drgnx-agent-panel)
(defface drgnx-agent-panel-removed '((t :inherit diff-removed)) "A removed line of a step's diff."
  :group 'drgnx-agent-panel)

;;;; The panel's state, per buffer

(defvar drgnx-agent-panel-mode-map (make-sparse-keymap)
  "Keys of an agent panel.  The key profiles bind them (`drgnx-command-define' with this map).")

(defvar-local drgnx-agent-panel--session nil "The hub session this panel shows.")
(defvar-local drgnx-agent-panel--snap nil "The session's latest snapshot (the `agent' event's `session'), a plist.")
(defvar-local drgnx-agent-panel--busy-since nil "When the snapshot first said `busy' in this run, a float time.")
(defvar-local drgnx-agent-panel--entries nil "Entry index → entry (a plist), of the pages loaded and the entries the hub sent.")
(defvar-local drgnx-agent-panel--live nil "Entry indexes the hub sent live: a slice never overwrites them.")
(defvar-local drgnx-agent-panel--steps nil "Step seq → step (the hub's timeline row): time and cost of the entries that name it.")
(defvar-local drgnx-agent-panel--first-step nil "The lowest step seq loaded, or nil.")
(defvar-local drgnx-agent-panel--more nil "Non-nil while the hub may have steps before the loaded ones.")
(defvar-local drgnx-agent-panel--loading nil "Non-nil while a page is being asked for.")
(defvar-local drgnx-agent-panel--loaded nil "Non-nil once the first page has come.")
(defvar-local drgnx-agent-panel--subscribed nil "Non-nil while the hub sends this session's entries here.")
(defvar-local drgnx-agent-panel--shown-keys nil "A hash: the row keys the view has been told about.")
(defvar-local drgnx-agent-panel--open nil "A hash: row key → non-nil when its row is open (thinking and detail shown).")

(defvar drgnx-agent-panel--disclosure)
(defvar drgnx-agent-panel--stats-render 0 "Rows rendered since Emacs started (a test reads the difference).")

(declare-function drgnx-agent-panel--header-row "drgnx-agent-panel-steps")
(declare-function drgnx-agent-panel--chips-row "drgnx-agent-panel-steps")
(declare-function drgnx-agent-panel--entry-row "drgnx-agent-panel-steps")
(declare-function drgnx-agent-panel--block-row "drgnx-agent-panel-steps")
(declare-function drgnx-agent-panel--row-toggle "drgnx-agent-panel-steps")
(declare-function drgnx-agent-panel--redraw-steps "drgnx-agent-panel-steps")
(declare-function drgnx-agent-panel--strip-row "drgnx-agent-panel-steps")
(declare-function drgnx-agent-panel-steps-init "drgnx-agent-panel-steps")
(declare-function drgnx-agent-panel-steps-teardown "drgnx-agent-panel-steps")
(declare-function drgnx-agent-panel-steps-setup "drgnx-agent-panel-steps")

(declare-function drgnx-agent-panel-explain-setup "drgnx-agent-panel-explain")
(declare-function drgnx-agent-panel-huddle-setup "drgnx-agent-panel-huddle")
(declare-function drgnx-agent-panel-list-setup "drgnx-agent-panel-list")
(declare-function drgnx-agent-panel-explain-load-grants "drgnx-agent-panel-explain")
(defvar drgnx-agent-panel-list-buffer-name)
(declare-function drgnx-agent-panel-huddle-teardown "drgnx-agent-panel-huddle")
(declare-function drgnx-agent-panel-huddle--event "drgnx-agent-panel-huddle")
(declare-function drgnx-agent-panel-composer-keys "drgnx-agent-panel-composer")
(declare-function drgnx-agent-panel-composer-redraw "drgnx-agent-panel-composer")
(declare-function drgnx-agent-panel-composer-setup "drgnx-agent-panel-composer")
(declare-function drgnx-agent-panel-composer--queue-row "drgnx-agent-panel-composer")
(declare-function drgnx-agent-panel-composer--row "drgnx-agent-panel-composer")

(declare-function drgnx-agent-panel-cards-keys "drgnx-agent-panel-cards")
(declare-function drgnx-agent-panel-cards-top-keys "drgnx-agent-panel-cards")
(declare-function drgnx-agent-panel-cards--pin-row "drgnx-agent-panel-cards")
(declare-function drgnx-agent-panel-cards--todo-row "drgnx-agent-panel-cards")
(declare-function drgnx-agent-panel-cards--ledger-row "drgnx-agent-panel-cards")
(declare-function drgnx-agent-panel-cards-redraw "drgnx-agent-panel-cards")
(declare-function drgnx-agent-panel-cards-setup "drgnx-agent-panel-cards")
(declare-function drgnx-agent-panel-cards-load "drgnx-agent-panel-cards")
(declare-function drgnx-agent-panel-cards-note-entries "drgnx-agent-panel-cards")
(declare-function drgnx-agent-panel-cards--diff-row "drgnx-agent-panel-cards")
(declare-function drgnx-agent-panel-cards--perm-row "drgnx-agent-panel-cards")

(unless (featurep 'drgnx-agent-panel-cards)
  (load (expand-file-name "drgnx-agent-panel-cards" (file-name-directory (or load-file-name buffer-file-name))) nil t))
(unless (featurep 'drgnx-agent-panel-composer)
  (load (expand-file-name "drgnx-agent-panel-composer" (file-name-directory (or load-file-name buffer-file-name))) nil t))
(unless (featurep 'drgnx-agent-panel-explain)
  (load (expand-file-name "drgnx-agent-panel-explain" (file-name-directory (or load-file-name buffer-file-name))) nil t))
(unless (featurep 'drgnx-agent-panel-huddle)
  (load (expand-file-name "drgnx-agent-panel-huddle" (file-name-directory (or load-file-name buffer-file-name))) nil t))
(unless (featurep 'drgnx-agent-panel-list)
  (load (expand-file-name "drgnx-agent-panel-list" (file-name-directory (or load-file-name buffer-file-name))) nil t))
(unless (featurep 'drgnx-agent-panel-steps)
  (load (expand-file-name "drgnx-agent-panel-steps" (file-name-directory (or load-file-name buffer-file-name))) nil t))

;;;; Reading what the hub sends

(defun drgnx-agent-panel--type (entry)
  "ENTRY's type as a symbol (the hub's JSON gives a string, a decoded record a symbol)."
  (let ((ty (plist-get entry :type))) (and ty (intern (format "%s" ty)))))

(defun drgnx-agent-panel--text-of (content)
  "The first text found in CONTENT, a string, a plist or a list of them, or nil."
  (cond ((stringp content) content)
        ((and (consp content) (keywordp (car content)))
         (or (and (stringp (plist-get content :text)) (plist-get content :text))
             (drgnx-agent-panel--text-of (plist-get content :content))))
        ((or (consp content) (vectorp content))
         (seq-some #'drgnx-agent-panel--text-of content))))

(defun drgnx-agent-panel--one-line (text &optional width)
  "TEXT's first non-empty line, cut to WIDTH columns (default 60)."
  (let ((line (or (seq-find (lambda (l) (not (string-blank-p l))) (split-string (or text "") "\n")) "")))
    (truncate-string-to-width (string-trim line) (or width 60) nil nil "…")))

(defun drgnx-agent-panel--seconds (step)
  "How long STEP took, in seconds, or nil while it is open or the hub gave no times."
  (let ((s (plist-get step :start)) (e (plist-get step :end)))
    (and (numberp s) (numberp e) (max 0 (- e s)))))

(defun drgnx-agent-panel--duration-string (secs)
  (cond ((< secs 1) (format "%d ms" (round (* 1000 secs))))
        ((< secs 60) (format "%.1f s" secs))
        (t (format "%d m %02d s" (floor secs 60) (mod (floor secs) 60)))))

(defun drgnx-agent-panel--cost-of (step)
  (let ((c (plist-get step :cost))) (and (numberp c) (> c 0) c)))

;;;; Which entries are rows

(defun drgnx-agent-panel--entry (idx) (gethash idx drgnx-agent-panel--entries))

(defun drgnx-agent-panel--host-of (idx)
  "The index of the tool entry a thought at IDX folds under: the nearest tool entry before it with only thoughts
between, else nil."
  (let ((i (1- idx)) host stop)
    (while (and (not stop) (>= i 0) (drgnx-agent-panel--entry i))
      (pcase (drgnx-agent-panel--type (drgnx-agent-panel--entry i))
        ('thought (cl-decf i))
        ('tool (setq host i stop t))
        (_ (setq stop t))))
    host))

(defun drgnx-agent-panel--thoughts-of (idx)
  "The thought entries right after the tool entry IDX, in order."
  (let ((i (1+ idx)) out)
    (while (and (drgnx-agent-panel--entry i) (eq (drgnx-agent-panel--type (drgnx-agent-panel--entry i)) 'thought))
      (push (drgnx-agent-panel--entry i) out)
      (cl-incf i))
    (nreverse out)))

(defun drgnx-agent-panel--row-p (idx)
  "Non-nil when entry IDX is a row of its own: plans go to the to-do list, usage is a chip, a thought with a step
folds under it."
  (let ((e (drgnx-agent-panel--entry idx)))
    (and e (pcase (drgnx-agent-panel--type e)
             ((or 'plan 'usage) nil)
             ('thought (not (drgnx-agent-panel--host-of idx)))
             (_ t)))))

(defun drgnx-agent-panel--row-key-of (idx)
  "The key of the row entry IDX is drawn in."
  (if (and (eq (drgnx-agent-panel--type (drgnx-agent-panel--entry idx)) 'thought) (drgnx-agent-panel--host-of idx))
      (list :e (drgnx-agent-panel--host-of idx))
    (list :e idx)))

(defun drgnx-agent-panel--render (key)
  "The row of KEY (the view type's RENDER): a hub row (a string key) as the hub built it, else the panel's own."
  (cl-incf drgnx-agent-panel--stats-render)
  (if (stringp key) (drgnx-view-patch-render key) (drgnx-agent-panel--own-row key)))

(defun drgnx-agent-panel--own-row (key)
  "The panel's own row of KEY."
  (pcase (car-safe key)
    (:header (drgnx-agent-panel--header-row))
    (:chips (drgnx-agent-panel--chips-row))
    (:more (propertize "  ↑ earlier steps load when you scroll up\n" 'face 'drgnx-agent-panel-subtle))
    (:e (drgnx-agent-panel--entry-row (cadr key)))
    (:b (drgnx-agent-panel--block-row (cadr key) (nth 2 key)))
    (:strip (drgnx-agent-panel--strip-row))
    (:pin (drgnx-agent-panel-cards--pin-row (cadr key)))
    (:todo (drgnx-agent-panel-cards--todo-row))
    (:ledger (drgnx-agent-panel-cards--ledger-row))
    (:diff (drgnx-agent-panel-cards--diff-row (cadr key) (nth 2 key)))
    (:perm (drgnx-agent-panel-cards--perm-row (cadr key)))
    (:q (drgnx-agent-panel-composer--queue-row (cadr key)))
    (:composer (drgnx-agent-panel-composer--row))
    (:rows-end "\n")
    (_ "\n")))

(defun drgnx-agent-panel--patched (view keys)
  "PATCHED of the panel's view: the hub rows among KEYS get the inserter's last step (the stale shade, the classes)."
  (when drgnx-view-patch
    (when-let* ((rows (seq-filter #'stringp keys))) (drgnx-view-patch--patched view rows))))

(defun drgnx-agent-panel--sync (view)
  "SYNC of the panel's view: with the hub's rows, the models their patches named go to Sjá before they are drawn."
  (when drgnx-view-patch (drgnx-view-patch--sync view)))

(drgnx-view-define 'agent-panel :render #'drgnx-agent-panel--render :follow-tail t :slice drgnx-view-slice
                   :patched #'drgnx-agent-panel--patched :sync #'drgnx-agent-panel--sync)

;;;; The hub's rows

(defun drgnx-agent-panel--rows-p ()
  "Whether this panel's transcript is the hub's rows (not `drgnx-view-old-path')."
  (and drgnx-view-patch (not drgnx-view-old-path) t))

(defun drgnx-agent-panel--rows-after ()
  "The panel's own row the transcript's first row goes after: the last of those above the transcript."
  (car (last (append (list (list :header) (list :chips) (list :strip)) (drgnx-agent-panel-cards-top-keys)))))

(defun drgnx-agent-panel--apply-rows (state view patch)
  "`drgnx-view-patch-apply-function' of a panel: PATCH applied as `drgnx-view-patch--apply-ops' does, with its rows
placed between the rows above the transcript and `(:rows-end)': a reset removes the hub rows there were and inserts
its own there, an insert after no row goes there too."
  (let ((after (drgnx-agent-panel--rows-after)) ops)
    (dolist (op (plist-get patch :ops))
      (cond
       ((plist-member op :reset)
        (let ((old (hash-table-keys (drgnx-view-patch-rows state))))
          (clrhash (drgnx-view-patch-images state))
          (clrhash (drgnx-view-patch-ids state))
          (when old (push (list :remove old) ops))
          (push (list :insert (list :after after :rows (plist-get op :reset))) ops)))
       ((and (plist-member op :insert) (null (plist-get (plist-get op :insert) :after)))
        (push (list :insert (list :after after :rows (plist-get (plist-get op :insert) :rows))) ops))
       (t (push op ops))))
    (drgnx-view-patch--apply-ops state view (append (list :ops (nreverse ops)) patch))))

(defun drgnx-agent-panel--look-params ()
  "What this panel tells the hub about its rows: the step types open and the rows opened or folded by hand."
  (list :open (vconcat (mapcar #'symbol-name drgnx-agent-panel--disclosure))
        :rows (let (rows)
                (maphash (lambda (k v) (when (eq (car-safe k) :e) (push (vector (cadr k) (if (eq v 'open) t :false)) rows)))
                         drgnx-agent-panel--open)
                (vconcat rows))))

(defun drgnx-agent-panel--send-look (&optional older)
  "Tell the hub what this panel shows (`agents/panel/look'); OLDER: one window further back."
  (when (drgnx-agent-panel--rows-p)
    (funcall drgnx-view-patch-send-function "agents/panel/look"
             (append (list :view (drgnx-view-patch-view drgnx-view-patch)) (drgnx-agent-panel--look-params)
                     (and older (list :older t))))))

(defun drgnx-agent-panel--look-again (view)
  "RESUBSCRIBE of the panel's view: after a reconnect, the hub hears its look again."
  (when-let* ((b (drgnx-agent-panel--panel-for (string-remove-prefix "agent-panel/" view))))
    (with-current-buffer b (drgnx-agent-panel--send-look))))

(defun drgnx-agent-panel--hub-up-p ()
  "Whether this Emacs's subscribed connection to the hub is up: a panel made without it draws its rows itself."
  (and (boundp 'drgnx-hub--events) (process-live-p drgnx-hub--events)))

(defun drgnx-agent-panel--rows-attach (session)
  "Make this panel the hub-fed view of SESSION's rows: its env goes out while a window shows it."
  (let ((view (concat "agent-panel/" session)))
    (drgnx-view-patch-attach view "unshown" :keep t)
    (setq-local drgnx-view-patch-apply-function #'drgnx-agent-panel--apply-rows)
    (require 'drgnx-view-env)
    (drgnx-view-env-register view (current-buffer) #'drgnx-agent-panel--look-again)
    (drgnx-agent-panel--send-look)))

(defun drgnx-agent-panel--key-at ()
  "The key of the row at point, a hub row read as the `(:e INDEX)' of the entry it draws."
  (let ((key (and (drgnx-view-p drgnx-view) (drgnx-view-key-at))))
    (if (stringp key)
        (when-let* ((i (get-text-property (pos-bol) 'drgnx-agent-panel-entry))) (list :e i))
      key)))

;;;; Keeping the view's rows in step with the model

(defun drgnx-agent-panel--blocks (idx)
  "The Markdown blocks of the agent message at IDX (a vector), or nil when the hub sent none."
  (let ((e (drgnx-agent-panel--entry idx)))
    (and e (eq (drgnx-agent-panel--type e) 'agent)
         (let ((b (plist-get e :blocks))) (and (> (length b) 0) b)))))

(defun drgnx-agent-panel--row-keys (idx)
  "The keys of the rows entry IDX is drawn in: one per Markdown block of an agent message, else one."
  (if-let* ((blocks (drgnx-agent-panel--blocks idx)))
      (cl-loop for n below (length blocks) collect (list :b idx n))
    (list (list :e idx))))

(defun drgnx-agent-panel--merge-blocks (old new)
  "NEW, an entry as the hub sent it, with its `blocks' complete: the hub's `patch' replaces (or adds) only its blocks of
OLD's, and an event with neither keeps OLD's.  The result has no `patch'."
  (let* ((blocks (if (plist-member new :blocks) (plist-get new :blocks) (plist-get old :blocks)))
         (patch (plist-get new :patch)))
    (when (> (length patch) 0)
      (setq blocks (append blocks nil))
      (seq-doseq (p patch)
        (let ((n (plist-get p :block)))
          (while (< (length blocks) n) (setq blocks (append blocks (list nil))))
          (if (< n (length blocks)) (setcar (nthcdr n blocks) p) (setq blocks (append blocks (list p)))))))
    (let ((out (cl-loop for (k v) on new by #'cddr unless (memq k '(:patch :blocks)) append (list k v))))
      (if blocks (append out (list :blocks (vconcat blocks))) out))))

(defun drgnx-agent-panel--wanted-keys ()
  "Every row key of the panel's own it should hold now, in order (the hub's rows go before `(:rows-end)')."
  (append (list (list :header) (list :chips))
          (list (list :strip))
          (drgnx-agent-panel-cards-top-keys)
          (if (drgnx-agent-panel--rows-p) (list (list :rows-end))
            (append (and drgnx-agent-panel--more drgnx-agent-panel--loaded (list (list :more)))
                    (let ((idxs (sort (hash-table-keys drgnx-agent-panel--entries) #'<)))
                      (mapcan #'drgnx-agent-panel--row-keys (seq-filter #'drgnx-agent-panel--row-p idxs)))))
          (drgnx-agent-panel-cards-keys)
          (drgnx-agent-panel-composer-keys)))

(defun drgnx-agent-panel--reconcile ()
  "Tell the view which rows appeared or went: new keys go in after the key before them, none is drawn again."
  (when (drgnx-view-p drgnx-view)
    (let* ((wanted (drgnx-agent-panel--wanted-keys)) (shown drgnx-agent-panel--shown-keys)
           (want-set (make-hash-table :test #'equal)) prev run run-after)
      (dolist (k wanted) (puthash k t want-set))
      (let (gone) (maphash (lambda (k _) (unless (gethash k want-set) (push k gone))) shown)
           (when gone (drgnx-view-remove drgnx-view gone) (dolist (k gone) (remhash k shown))))
      (dolist (k wanted)
        (if (gethash k shown)
            (progn (when run (drgnx-view-insert drgnx-view (nreverse run) :after run-after) (setq run nil)))
          (unless run (setq run-after prev))
          (push k run) (puthash k t shown))
        (setq prev k))
      (when run (drgnx-view-insert drgnx-view (nreverse run) :after run-after)))))

(defun drgnx-agent-panel--dirty (&rest keys)
  (when (drgnx-view-p drgnx-view) (drgnx-view-dirty drgnx-view keys)))

;;;; Taking snapshots and entries

(defun drgnx-agent-panel--take-snapshot (snap)
  "SNAP, the session's snapshot, is the latest: the header and the chips are drawn again."
  (let ((was (format "%s" (plist-get drgnx-agent-panel--snap :status))) (now (format "%s" (plist-get snap :status))))
    (setq drgnx-agent-panel--snap snap)
    (cond ((and (equal now "busy") (not (equal was "busy"))) (setq drgnx-agent-panel--busy-since (float-time)))
          ((not (equal now "busy")) (setq drgnx-agent-panel--busy-since nil)))
    (drgnx-agent-panel--dirty (list :header) (list :chips))
    (drgnx-agent-panel--reconcile)
    (drgnx-agent-panel-composer-redraw)
    (drgnx-agent-panel-cards-redraw)))

(defun drgnx-agent-panel--take-entries (pairs &optional from-slice)
  "PAIRS, (INDEX ENTRY) as the hub sends them, are in the transcript: a new entry is appended, a changed one patched.
FROM-SLICE: they come from a page, which never overwrites an entry the hub sent live.  With the hub's rows the entries
are only kept (`drgnx-agent-panel--keep-entries')."
  (if (drgnx-agent-panel--rows-p) (drgnx-agent-panel--keep-entries pairs from-slice)
    (drgnx-agent-panel--take-entries-old pairs from-slice)))

(defun drgnx-agent-panel--keep-entries (pairs from-slice)
  "PAIRS are kept for the cards, the pins and the step at point; the hub draws them.  The rows above the transcript
change only with a plan or a finished edit."
  (let (touched cards)
    (seq-doseq (pair pairs)
      (let ((idx (elt pair 0)) (e (elt pair 1)))
        (unless (and from-slice (gethash idx drgnx-agent-panel--live))
          (unless from-slice (puthash idx t drgnx-agent-panel--live))
          (puthash idx e drgnx-agent-panel--entries)
          (push idx touched)
          (when (or (eq (drgnx-agent-panel--type e) 'plan)
                    (and (equal (plist-get e :kind) "edit") (equal (plist-get e :status) "completed")))
            (setq cards t)))))
    (when touched
      (when cards (drgnx-agent-panel--reconcile))
      (drgnx-agent-panel-cards-note-entries (current-buffer) touched from-slice))))

(defun drgnx-agent-panel--take-entries-old (pairs from-slice)
  "`drgnx-agent-panel--take-entries' behind `drgnx-view-old-path': every row drawn here."
  (let (touched block-keys)
    (seq-doseq (pair pairs)
      (let ((idx (elt pair 0)) (e (elt pair 1)))
        (unless (and from-slice (gethash idx drgnx-agent-panel--live))
          (unless from-slice (puthash idx t drgnx-agent-panel--live))
          (let* ((old (gethash idx drgnx-agent-panel--entries))
                 (e (if (eq (drgnx-agent-panel--type e) 'agent) (drgnx-agent-panel--merge-blocks old e) e)))
            (puthash idx e drgnx-agent-panel--entries)
            ;; a message's block rows that differ from the ones drawn are the ones to draw again
            (dotimes (n (length (plist-get e :blocks)))
              (unless (equal (aref (plist-get e :blocks) n) (and (< n (length (plist-get old :blocks)))
                                                                 (aref (plist-get old :blocks) n)))
                (push (list :b idx n) block-keys)))
            (when (or (not old) (not (equal old e))) (push idx touched))))))
    (when touched
      (drgnx-agent-panel--reconcile)
      (let ((keys block-keys))
        (dolist (idx touched)
          (cl-pushnew (drgnx-agent-panel--row-key-of idx) keys :test #'equal)
          (when (eq (drgnx-agent-panel--type (drgnx-agent-panel--entry idx)) 'tool)
            (cl-pushnew (list :e idx) keys :test #'equal)))
        (when (drgnx-view-p drgnx-view)
          (drgnx-view-dirty drgnx-view (seq-filter (lambda (k) (gethash k drgnx-agent-panel--shown-keys)) keys))))
      (drgnx-agent-panel-cards-note-entries (current-buffer) touched from-slice))))

(defun drgnx-agent-panel--take-steps (steps)
  (dolist (s steps)
    (puthash (plist-get s :seq) s drgnx-agent-panel--steps)
    (setq drgnx-agent-panel--first-step
          (if drgnx-agent-panel--first-step (min drgnx-agent-panel--first-step (plist-get s :seq)) (plist-get s :seq)))))

;;;; Asking the hub

(defun drgnx-agent-panel--ask (method params &optional callback)
  "Ask the hub METHOD with PARAMS; the entry subscription goes on the connection the events come on."
  (let ((cb (or callback #'ignore)))
    (if (and (member method '("agents/entries/subscribe" "agents/entries/unsubscribe"))
             (boundp 'drgnx-hub--events) (process-live-p drgnx-hub--events))
        (drgnx-hub--call-on drgnx-hub--events method params cb)
      (drgnx-hub-call method params cb))))

(defun drgnx-agent-panel--load (&optional older)
  "Ask for a page of steps and the entries of their messages: the last page, or with OLDER the one before."
  (unless drgnx-agent-panel--loading
    (let* ((buf (current-buffer)) (id drgnx-agent-panel--session) (n (min 50 drgnx-agent-panel-page-steps))
           (before (and older drgnx-agent-panel--first-step drgnx-agent-panel--first-step)))
      (setq drgnx-agent-panel--loading t)
      (drgnx-agent-panel--ask
       "timeline/get" (append (list :scope "session" :id id :limit n) (and before (list :before before)))
       (lambda (r err)
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (let* ((steps (and (not err) (append (plist-get r :steps) nil))) (first (car steps)))
               (setq drgnx-agent-panel--more (and first (>= (length steps) n)))
               (if (null first)
                   (progn (setq drgnx-agent-panel--loading nil drgnx-agent-panel--loaded t drgnx-agent-panel--more nil)
                          (drgnx-agent-panel--reconcile)
                          (unless older (drgnx-agent-panel-cards-load buf)))
                 (drgnx-agent-panel--ask
                  "agents/slice" (list :id id :from_step (plist-get first :seq) :n n)
                  (lambda (r2 err2)
                    (when (buffer-live-p buf)
                      (with-current-buffer buf
                        (setq drgnx-agent-panel--loading nil drgnx-agent-panel--loaded t)
                        (drgnx-agent-panel--take-steps (append (if err2 steps (or (plist-get r2 :steps) steps)) nil))
                        (unless err2 (drgnx-agent-panel--take-entries (plist-get r2 :entries) t))
                        (drgnx-agent-panel--reconcile)
                        (unless older (drgnx-agent-panel-cards-load buf)))))))))))))))

(defun drgnx-agent-panel-older ()
  "Load the page of steps before the first one shown, when the hub has one; with the hub's rows, they go one window
further back too."
  (interactive)
  (when (drgnx-agent-panel--rows-p) (drgnx-agent-panel--send-look t))
  (when (and drgnx-agent-panel--more (not drgnx-agent-panel--loading)) (drgnx-agent-panel--load t)))

(defun drgnx-agent-panel--scrolled (window start)
  "The window scrolled to START: at the top of the transcript, the page before is asked for."
  (with-current-buffer (window-buffer window)
    (let ((rows (drgnx-agent-panel--rows-p)))
      (when (and (or rows drgnx-agent-panel--more) (not drgnx-agent-panel--loading) (drgnx-view-p drgnx-view))
        (let ((more (drgnx-view-row-start drgnx-view (if rows "more" (list :more)))))
          (when (and more (<= start (1+ more))) (drgnx-agent-panel-older)))))))

(defun drgnx-agent-panel--subscribe ()
  "This panel is shown: the hub sends the session's entries here; the last page comes when it has answered."
  (unless drgnx-agent-panel--subscribed
    (setq drgnx-agent-panel--subscribed t)
    ;; the hub's rows follow the env of the window that now shows them
    (when (drgnx-agent-panel--rows-p) (drgnx-view-env-update (drgnx-view-patch-view drgnx-view-patch)))
    (let ((buf (current-buffer)))
      (drgnx-agent-panel--ask
       "agents/entries/subscribe" (list :session drgnx-agent-panel--session)
       (lambda (_r err)
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (if err (setq drgnx-agent-panel--subscribed nil)
               (unless drgnx-agent-panel--loaded (drgnx-agent-panel--load))))))))))

(defun drgnx-agent-panel--unsubscribe ()
  "No window shows this panel: the hub stops sending the session's entries.  Without the events connection nothing is
asked: the subscription went with it, and this runs from `kill-buffer-hook' (a call would open a connection, and
signal when no hub serves)."
  (when drgnx-agent-panel--subscribed
    (setq drgnx-agent-panel--subscribed nil)
    (when (drgnx-agent-panel--hub-up-p)
      (drgnx-agent-panel--ask "agents/entries/unsubscribe" (list :session drgnx-agent-panel--session)))))

;;;; Panels

(define-derived-mode drgnx-agent-panel-mode special-mode "Agent"
  "One agent session's steps, live."
  (setq-local truncate-lines t cursor-type nil)
  (add-hook 'window-scroll-functions #'drgnx-agent-panel--scrolled nil t)
  (add-hook 'kill-buffer-hook #'drgnx-agent-panel--killed nil t))

(defun drgnx-agent-panel--killed () (drgnx-agent-panel--unsubscribe))

(defun drgnx-agent-panel-buffers ()
  (seq-filter (lambda (b) (eq (buffer-local-value 'major-mode b) 'drgnx-agent-panel-mode)) (buffer-list)))

(defun drgnx-agent-panel-buffer (session)
  "The panel of hub SESSION, made when there is none.  It shows nothing until a window does."
  (let ((buffer (get-buffer-create (format "*drgnx agent: %s*" session))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'drgnx-agent-panel-mode)
        (drgnx-agent-panel-mode)
        (setq drgnx-agent-panel--session session
              drgnx-agent-panel--entries (make-hash-table :test #'eql) drgnx-agent-panel--live (make-hash-table :test #'eql)
              drgnx-agent-panel--steps (make-hash-table :test #'eql) drgnx-agent-panel--shown-keys (make-hash-table :test #'equal)
              drgnx-agent-panel--open (make-hash-table :test #'equal))
        (drgnx-view-attach 'agent-panel)
        (drgnx-agent-panel-steps-init)
        (when (and (not drgnx-view-old-path) (drgnx-agent-panel--hub-up-p)) (drgnx-agent-panel--rows-attach session))
        (drgnx-agent-panel--reconcile)
        (drgnx-agent-panel--ask "agents/list" nil
                                (lambda (r _err)
                                  (when-let* (((buffer-live-p buffer))
                                              (snap (seq-find (lambda (s) (equal (plist-get s :id) session))
                                                              (append (plist-get r :sessions) nil))))
                                    (with-current-buffer buffer (drgnx-agent-panel--take-snapshot snap)))))))
    buffer))

(defun drgnx-agent-panel-sync-windows (&optional _frame)
  "A panel a window shows takes the session's entries; one no window shows lets them go."
  (dolist (b (drgnx-agent-panel-buffers))
    (with-current-buffer b
      (if (get-buffer-window b 'visible) (drgnx-agent-panel--subscribe) (drgnx-agent-panel--unsubscribe)))))

(defun drgnx-agent-panel--current-buffer ()
  (or (seq-find (lambda (b) (get-buffer-window b 'visible)) (drgnx-agent-panel-buffers))
      (car (drgnx-agent-panel-buffers))
      (get-buffer-create "*drgnx agent*")))

(defun drgnx-agent-panel-open (session)
  "Show SESSION's panel in the right dock, one tab for each open agent."
  (interactive (list (drgnx-agent-panel--read-session)))
  (let ((buf (drgnx-agent-panel-buffer session)))
    (drgnx-pane-show 'agent-panel :buffer buf :select t)
    (with-current-buffer buf
      (drgnx-agent-panel-sync-windows)
      (drgnx-agent-panel-explain-load-grants))
    buf))

(defun drgnx-agent-panel--read-session ()
  (or (and (derived-mode-p 'drgnx-agent-panel-mode) drgnx-agent-panel--session)
      (and (boundp 'drgnx-agents--sessions)
           (let ((ids (delq nil (mapcar (lambda (s) (and (fboundp 'drgnx-agent-session-remote) (drgnx-agent-session-remote s)))
                                        drgnx-agents--sessions))))
             (if (cdr ids) (completing-read "Agent: " ids nil t) (car ids))))
      (user-error "No agent session to show")))

(defvar drgnx-agents--sessions)
(declare-function drgnx-agent-session-remote "drgnx-agents")

;;;; Events

(defun drgnx-agent-panel--panel-for (id)
  (seq-find (lambda (b) (equal (buffer-local-value 'drgnx-agent-panel--session b) id)) (drgnx-agent-panel-buffers)))

(defun drgnx-agent-panel--refresh-steps ()
  "Ask the hub again for the step rows this panel holds (a revert or fork changed `revertible' and `undone_by')."
  (when (and drgnx-agent-panel--first-step (> (hash-table-count drgnx-agent-panel--steps) 0))
    (let ((buf (current-buffer)))
      (drgnx-agent-panel--ask
       "timeline/get" (list :scope "session" :id drgnx-agent-panel--session
                            :limit (min 200 (hash-table-count drgnx-agent-panel--steps))
                            :before (1+ (apply #'max (hash-table-keys drgnx-agent-panel--steps))))
       (lambda (r err)
         (when (and (not err) (buffer-live-p buf))
           (with-current-buffer buf
             (drgnx-agent-panel--take-steps (append (plist-get r :steps) nil))
             (drgnx-agent-panel--redraw-steps))))))))

(defun drgnx-agent-panel--event (event data)
  "An event from the hub (`drgnx-hub-event-functions'): a snapshot or entries of a session whose panel exists;
`history/applied' (it names no session) reloads the step rows of every panel."
  (when (equal event "history/applied")
    (dolist (b (drgnx-agent-panel-buffers))
      (with-current-buffer b (drgnx-agent-panel--refresh-steps))))
  (when (member event '("agent" "agent-entries"))
    (when-let* ((b (drgnx-agent-panel--panel-for (plist-get data :id))))
      (with-current-buffer b
        (if (equal event "agent")
            (when-let* ((s (plist-get data :session))) (drgnx-agent-panel--take-snapshot s))
          (when drgnx-agent-panel--subscribed (drgnx-agent-panel--take-entries (plist-get data :entries))))))))

(defun drgnx-agent-panel--resubscribe ()
  "A new connection to the hub: the shown panels ask for their entries and their last page again."
  (dolist (b (drgnx-agent-panel-buffers))
    (with-current-buffer b
      (setq drgnx-agent-panel--subscribed nil drgnx-agent-panel--loaded nil drgnx-agent-panel--loading nil)
      (when (get-buffer-window b 'visible) (drgnx-agent-panel--subscribe)))))

;;;; The probe

(defun drgnx-agent-panel-stream-probe (buffer n)
  "Time N updates of one agent message arriving in BUFFER as markdown patches (20 a second), each taken and drawn:
a list of milliseconds (the probe for `agent-panel-stream-tick').  BUFFER is a panel; the message is made up and
stays in it.  Every fifth update opens a new block, the others grow the last one."
  (with-current-buffer buffer
    (let ((idx (hash-table-count drgnx-agent-panel--entries)) ms)
      (dotimes (u n)
        (let* ((b (/ u 5)) (words (1+ (% u 5)))
               (block (list :block b :kind "paragraph"
                            :spans (vector (list :text (mapconcat #'identity (make-list words "word") " ") :style "text")
                                           (list :text " tail" :style "strong"))))
               (e (list :type "agent" :text (format "message %d" u) :patch (vector block))))
          (push (* 1000 (car (benchmark-run 1 (drgnx-agent-panel--take-entries (list (list idx e)))
                                            (drgnx-view-draw-now drgnx-view))))
                ms)))
      (nreverse ms))))

;;;; The module

(defun drgnx-agent-panel--setup ()
  (drgnx-command-define 'agents-panel :category "Agents" :title "Open the Agent Panel"
                        :command #'drgnx-agent-panel-open
                        :doc "One agent session's steps, live, in the right dock")
  (drgnx-command-define 'agents-panel-toggle :category "Agents" :title "Open or Fold the Step"
                        :command #'drgnx-agent-panel-toggle :map 'drgnx-agent-panel-mode-map
                        :doc "Show or fold the thinking and the detail under the step at point")
  (drgnx-command-define 'agents-panel-older :category "Agents" :title "Load Earlier Steps"
                        :command #'drgnx-agent-panel-older :map 'drgnx-agent-panel-mode-map
                        :doc "The page of steps before the first one shown")
  (dolist (c '((agents-panel-next-tool "Next Tool Call" drgnx-agent-panel-next-tool
                                       "Go to the next tool call in the panel, wrapping")
               (agents-panel-previous-tool "Previous Tool Call" drgnx-agent-panel-previous-tool
                                           "Go to the previous tool call in the panel, wrapping")
               (agents-panel-next-change "Next Change" drgnx-agent-panel-next-change
                                         "Go to the next step that changed a file, wrapping")
               (agents-panel-previous-change "Previous Change" drgnx-agent-panel-previous-change
                                             "Go to the previous step that changed a file, wrapping")
               (agents-panel-next-prompt "Next Message You Sent" drgnx-agent-panel-next-prompt
                                         "Go to your next message in the panel, wrapping")
               (agents-panel-previous-prompt "Previous Message You Sent" drgnx-agent-panel-previous-prompt
                                             "Go to your previous message in the panel, wrapping")))
    (drgnx-command-define (nth 0 c) :category "Agents" :title (nth 1 c) :command (nth 2 c)
                          :map 'drgnx-agent-panel-mode-map :doc (nth 3 c)))
  (drgnx-pane-define-kind 'agent-panel :title " AGENT" :home 'right :buffer #'drgnx-agent-panel--current-buffer)
  (drgnx-module-hook 'drgnx-hub-event-functions panel-event (event data) (drgnx-agent-panel--event event data))
  (drgnx-module-hook 'drgnx-hub-connected-functions panel-resubscribe () (drgnx-agent-panel--resubscribe))
  (drgnx-module-hook 'window-buffer-change-functions panel-windows (frame) (drgnx-agent-panel-sync-windows frame))
  (drgnx-agent-panel-steps-setup)
  (drgnx-agent-panel-composer-setup)
  (drgnx-agent-panel-explain-setup)
  (drgnx-agent-panel-huddle-setup)
  (drgnx-module-hook 'drgnx-hub-event-functions huddle-event (event data) (drgnx-agent-panel-huddle--event event data))
  (drgnx-agent-panel-cards-setup)
  (drgnx-agent-panel-list-setup)
  (drgnx-agent-panel-sync-windows))

(defun drgnx-agent-panel--teardown ()
  "Every panel gives its subscription back and goes."
  (drgnx-agent-panel-steps-teardown)
  (drgnx-agent-panel-huddle-teardown)
  (when-let* ((b (get-buffer drgnx-agent-panel-list-buffer-name))) (kill-buffer b))
  (dolist (b (drgnx-agent-panel-buffers)) (kill-buffer b)))

(defun drgnx-agent-panel-toggle ()
  "Open or fold the thinking and the detail of the step at point (with the hub's rows, off a step: the selected one).
A fold is this panel's own state at once; the hub hears it after (`agents/panel/look') and draws the rows again."
  (interactive)
  (let ((key (drgnx-agent-panel--key-at)))
    (unless (eq (car-safe key) :e)
      (when-let* (((drgnx-agent-panel--rows-p)) (id (drgnx-view-nav-selection)))
        (setq key (list :e (drgnx-view-nav-field "entry" id)))))
    (unless (eq (car-safe key) :e) (user-error "Point is not on a step"))
    (drgnx-agent-panel--row-toggle key)))

;;;; Moving between the steps of a kind (the hub's model, in Sjá)

(declare-function nidhogg-view-get "nidhogg-views" (h what &optional arg arg2))

(defun drgnx-agent-panel--of-kind-p (h id kind)
  "Whether step ID of the panel's model (handle H) is of KIND: `tool', `hunk' (a tool call with an edit) or `ask'
\(your message)."
  (pcase kind
    ("tool" (equal (nidhogg-view-get h 'kind id) "tool"))
    ("hunk" (eql (nidhogg-view-get h 'field "diff" id) 1))
    (_ (equal (nidhogg-view-get h 'kind id) "user"))))

(defun drgnx-agent-panel--find-step (h kind step from)
  "The first step of KIND after (STEP 1) or before (STEP -1) the step FROM among the drawn rows, from point, wrapping
past the ends; nil when none is drawn."
  (let ((pred (lambda (_ v) (and v (not (equal v from)) (drgnx-agent-panel--of-kind-p h v kind))))
        (search (if (> step 0) #'text-property-search-forward #'text-property-search-backward)))
    (save-excursion
      (or (when-let* ((m (funcall search 'drgnx-work-id nil pred))) (prop-match-value m))
          (progn (goto-char (if (> step 0) (point-min) (point-max)))
                 (when-let* ((m (funcall search 'drgnx-work-id nil pred))) (prop-match-value m)))
          ;; FROM is the only one: it stays
          (and from (drgnx-agent-panel--of-kind-p h from kind) from)))))

(defun drgnx-agent-panel--move (kind step)
  "Select the next (STEP 1) or previous (STEP -1) step of KIND from point and put point on it, wrapping: KIND
`tool', `hunk' (a step with an edit) or `ask' (your message).  Each step's kind comes from the panel's model in Sjá,
which then selects it."
  (unless (drgnx-agent-panel--rows-p) (user-error "The panel moves between steps with the hub's rows only"))
  (let* ((h (drgnx-view-patch-handle drgnx-view-patch))
         (to (and h (drgnx-agent-panel--find-step h kind step (get-text-property (point) 'drgnx-work-id)))))
    (if to (drgnx-view-nav 'select to) (message "No step of that kind"))))

(defun drgnx-agent-panel-next-tool ()
  "The next tool call in the panel, wrapping."
  (interactive)
  (drgnx-agent-panel--move "tool" 1))

(defun drgnx-agent-panel-previous-tool ()
  "The previous tool call in the panel, wrapping."
  (interactive)
  (drgnx-agent-panel--move "tool" -1))

(defun drgnx-agent-panel-next-change ()
  "The next step that changed a file, wrapping."
  (interactive)
  (drgnx-agent-panel--move "hunk" 1))

(defun drgnx-agent-panel-previous-change ()
  "The previous step that changed a file, wrapping."
  (interactive)
  (drgnx-agent-panel--move "hunk" -1))

(defun drgnx-agent-panel-next-prompt ()
  "Your next message in the panel, wrapping."
  (interactive)
  (drgnx-agent-panel--move "ask" 1))

(defun drgnx-agent-panel-previous-prompt ()
  "Your previous message in the panel, wrapping."
  (interactive)
  (drgnx-agent-panel--move "ask" -1))

(drgnx-module-define 'tools/agent-panel
                     :doc "One agent session's steps, live, in the right dock: a step on a line, thinking folded under it."
                     :stage 'idle :setup #'drgnx-agent-panel--setup :teardown #'drgnx-agent-panel--teardown)

(provide 'drgnx-agent-panel)
;;; drgnx-agent-panel.el ends here
