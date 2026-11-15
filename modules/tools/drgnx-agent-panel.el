;;; drgnx-agent-panel.el --- Module tools/agent-panel: one agent session's steps, live, in the right dock -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The agent panel shows one session of the hub in three windows of the right area: the header (who, what it is doing,
;; the lens, the chips and the strip), the transcript and the composer.  This file is the transcript's buffer, the
;; panel's main one: the cards, then a row per entry (a tool call is a step on one line, its thinking folded under it),
;; then the review cards.  Every row is the hub's (docs/develop/hub.md, "The agent panel's rows"): the buffer is the
;; hub-fed view `agent-panel/SESSION', held in Sjá where this Emacs has it (`drgnx-view-patch-attach' with SJA), so a
;; stream never re-renders what is already there.  Emacs scrolls it as any buffer: a window whose point is at the end
;; keeps the end in view (`scroll-conservatively'), a window scrolled back stays on its row (Sjá keeps it there).
;;
;; A panel is a buffer per session.  It asks the hub for the session's entries (`agents/entries/subscribe') only
;; while a window shows it, and takes the last page of steps (`drgnx-agent-panel-page-steps', 50) from the hub with
;; the entries of their messages (`timeline/get', then `agents/slice'); older rows come when the window scrolls to its
;; top.  The entries draw nothing: the cards, the pins and the commands on the step at point read them.  The snapshot
;; comes from the `agent' event.  Which step types are open, the rows opened by hand and how far back the rows go are
;; told to the hub (`agents/panel/look').  Until the hub sends the first rows the buffer says it waits for it.  Nothing
;; here writes to an agent's worktree or builds a queue of its own: the composer, the cards and the pinned cards are in
;; the sibling files, loaded from here.
;; See docs/guide/agent-panel.md.

;;; Code:
(require 'seq)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-view)
(defvar drgnx-view-sja-tail)                  ; drgnx-view-sja, loaded when Sjá holds the rows
(require 'drgnx-hub-client)
(require 'drgnx-panes)                   ; the right island the panel opens in
(require 'drgnx-view-nav)                ; the moves between steps of a kind, through the replica
(require 'text-property-search)          ; the moves look through the drawn rows

(declare-function drgnx-hub--call-on "drgnx-hub-client")
(declare-function drgnx-view-env-register "drgnx-view-env")
(declare-function drgnx-view-env-update "drgnx-view-env")
(declare-function drgnx-view-env-twin "drgnx-view-env" (class prefixes &optional setup))
(declare-function drgnx-view-env--twin-copy "drgnx-view-env" (from prefixes))
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
(defface drgnx-agent-panel-added '((t :inherit (diff-added drgnx-code-small))) "An added line of a step's diff."
  :group 'drgnx-agent-panel)
(defface drgnx-agent-panel-removed '((t :inherit (diff-removed drgnx-code-small))) "A removed line of a step's diff."
  :group 'drgnx-agent-panel)
(defface drgnx-agent-panel-context '((t :inherit drgnx-code-small)) "An unchanged line of a step's diff."
  :group 'drgnx-agent-panel)
(defface drgnx-agent-panel-output '((t :inherit drgnx-code-small)) "A line of a tool's output."
  :group 'drgnx-agent-panel)

;;;; The panel's state, per buffer

(defvar drgnx-agent-panel-mode-map (make-sparse-keymap)
  "Keys of an agent panel.  The key profiles bind them (`drgnx-command-define' with this map).")

(defvar-local drgnx-agent-panel--session nil "The hub session this panel shows.")
(defvar-local drgnx-agent-panel--snap nil "The session's latest snapshot (the `agent' event's `session'), a plist.")
(defvar-local drgnx-agent-panel--entries nil "Entry index → entry (a plist), of the pages loaded and the entries the hub sent.")
(defvar-local drgnx-agent-panel--live nil "Entry indexes the hub sent live: a slice never overwrites them.")
(defvar-local drgnx-agent-panel--steps nil "Step seq → step (the hub's timeline row): time and cost of the entries that name it.")
(defvar-local drgnx-agent-panel--first-step nil "The lowest step seq loaded, or nil.")
(defvar-local drgnx-agent-panel--more nil "Non-nil while the hub may have steps before the loaded ones.")
(defvar-local drgnx-agent-panel--loading nil "Non-nil while a page is being asked for.")
(defvar-local drgnx-agent-panel--loaded nil "Non-nil once the first page has come.")
(defvar-local drgnx-agent-panel--subscribed nil "Non-nil while the hub sends this session's entries here.")
(defvar-local drgnx-agent-panel--open nil "A hash: row key → non-nil when its row is open (thinking and detail shown).")

(defvar drgnx-agent-panel--disclosure)
(defvar drgnx-agent-panel--by-session (make-hash-table :test #'equal :weakness 'value)
  "Hub session id → its panel's buffer.  Weak in the buffers: a killed panel's entry goes with it.")

(declare-function drgnx-agent-panel--row-toggle "drgnx-agent-panel-steps")
(defvar drgnx-agent-panel--pins)
(defvar drgnx-agent-panel--ledger-open)
(declare-function drgnx-agent-panel--preset-in-force "drgnx-agent-panel-steps")
(defvar drgnx-agent-panel-presets)
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
(declare-function drgnx-agent-panel-composer-setup "drgnx-agent-panel-composer")
(declare-function drgnx-agent-panel-composer-redraw "drgnx-agent-panel-composer")

(declare-function drgnx-agent-panel-cards-setup "drgnx-agent-panel-cards")

(unless (featurep 'drgnx-agent-panel-cards)
  (load (expand-file-name "drgnx-agent-panel-cards" (file-name-directory (or load-file-name buffer-file-name))) nil t))
(unless (featurep 'drgnx-agent-panel-composer)
  (load (expand-file-name "drgnx-agent-panel-composer" (file-name-directory (or load-file-name buffer-file-name))) nil t))
(unless (featurep 'drgnx-agent-panel-header)
  (load (expand-file-name "drgnx-agent-panel-header" (file-name-directory (or load-file-name buffer-file-name))) nil t))
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

;;;; Entries

(defun drgnx-agent-panel--entry (idx) (gethash idx drgnx-agent-panel--entries))

;;;; The hub's rows

(defvar-local drgnx-agent-panel--waiting nil
  "The overlay of the line saying the panel waits for the hub, until its first rows are drawn.")

(defun drgnx-agent-panel--wait-for-hub ()
  "Show the line saying the panel waits for the hub; the first rows it sends take the line away."
  (unless (overlayp drgnx-agent-panel--waiting)
    (setq drgnx-agent-panel--waiting (make-overlay (point-min) (point-min)))
    (overlay-put drgnx-agent-panel--waiting 'before-string
                 (propertize "  Waiting for the hub to send the agent's steps…\n" 'face 'shadow))))

(defun drgnx-agent-panel--patched (_view _keys)
  "`drgnx-view-patch-patched-functions' of a panel: the hub's rows are drawn, the waiting line goes."
  (when drgnx-agent-panel--waiting
    (delete-overlay drgnx-agent-panel--waiting)
    (setq drgnx-agent-panel--waiting nil)))

(defun drgnx-agent-panel--look-params ()
  "What this panel tells the hub about its rows: the step types open and the rows opened or folded by hand."
  (list :open (vconcat (mapcar #'symbol-name drgnx-agent-panel--disclosure))
        :lens (vconcat (mapcar (lambda (p) (symbol-name (car p))) drgnx-agent-panel-presets))
        :lens_on (or (drgnx-agent-panel--preset-in-force) 0)
        :pins (vconcat (mapcar #'cdr drgnx-agent-panel--pins))
        :ledger_open (if drgnx-agent-panel--ledger-open t :false)
        :rows (let (rows)
                (maphash (lambda (k v) (when (eq (car-safe k) :e) (push (vector (cadr k) (if (eq v 'open) t :false)) rows)))
                         drgnx-agent-panel--open)
                (vconcat rows))))

(defun drgnx-agent-panel--hub-up-p ()
  "Whether this Emacs's subscribed connection to the hub is up."
  (and (boundp 'drgnx-hub--events) (process-live-p drgnx-hub--events)))

(defun drgnx-agent-panel--send-look (&optional older)
  "Tell the hub what this panel shows (`agents/panel/look'); OLDER: one window further back.  With the hub down
nothing is sent: it hears the look when it connects (`drgnx-agent-panel--look-again')."
  (when (and drgnx-view-patch (drgnx-agent-panel--hub-up-p))
    (funcall drgnx-view-patch-send-function "agents/panel/look"
             (append (list :view (drgnx-view-patch-view drgnx-view-patch)) (drgnx-agent-panel--look-params)
                     (and older (list :older t))))))

(defun drgnx-agent-panel--look-again (view)
  "RESUBSCRIBE of the panel's view: after a reconnect, the hub hears its look again."
  (when-let* ((b (drgnx-agent-panel--panel-for (string-remove-prefix "agent-panel/" view))))
    (with-current-buffer b (drgnx-agent-panel--send-look))))

(defun drgnx-agent-panel--rows-attach (session)
  "Make this panel the hub-fed view of SESSION's transcript, held in Sjá where this Emacs has it: its env goes out
while a window shows it, and it says it waits for the hub until the first rows are drawn."
  (let ((view (concat "agent-panel/" session)))
    (drgnx-view-patch-attach view "unshown" :sja t)
    (setq-local drgnx-view-patch-twin-function #'drgnx-agent-panel--twin)
    (add-hook 'drgnx-view-patch-patched-functions #'drgnx-agent-panel--patched nil t)
    (drgnx-agent-panel--wait-for-hub)
    (require 'drgnx-view-env)
    (drgnx-view-env-register view (current-buffer) #'drgnx-agent-panel--look-again)
    (drgnx-agent-panel--send-look)))

(defun drgnx-agent-panel--twin-from ()
  "In a panel's twin: the panel's buffer, whose state it shows; else nil."
  (and drgnx-view-patch-twin-of (buffer-live-p drgnx-view-patch-twin-of) drgnx-view-patch-twin-of))

(defun drgnx-agent-panel--twin-give ()
  "`post-command-hook' of a twin: what the command changed of the panel's state goes back to the panel."
  (when-let* ((from (drgnx-agent-panel--twin-from)))
    (let ((twin (current-buffer)))
      (with-current-buffer from (drgnx-view-env--twin-copy twin '("drgnx-agent-panel-"))))))

(defun drgnx-agent-panel--twin-setup ()
  "In a new twin: killing it leaves the session's entries coming to the panel, and its commands give the panel's state
back."
  (remove-hook 'kill-buffer-hook #'drgnx-agent-panel--killed t)
  (add-hook 'post-command-hook #'drgnx-agent-panel--twin-give nil t))

(defun drgnx-agent-panel--twin (class)
  "The panel's buffer in display CLASS (`drgnx-view-patch-twin-function'): the generic twin (`drgnx-view-env-twin')
of the hub's rows of CLASS, the panel's state read before each command and given back after it.  It subscribes
nothing."
  (require 'drgnx-view-env)
  (drgnx-view-env-twin class '("drgnx-agent-panel-") #'drgnx-agent-panel--twin-setup))

(defun drgnx-agent-panel--key-at ()
  "The key of the step at point: `(:e INDEX)' of the entry the hub's row there draws, or nil."
  (when-let* ((i (get-text-property (pos-bol) 'drgnx-agent-panel-entry))) (list :e i)))

;;;; Taking snapshots and entries

(defun drgnx-agent-panel--take-snapshot (snap)
  "SNAP, the session's snapshot, is the latest: what the commands, the composer and the cards read.  The header and the
chips are the hub's rows, which it builds from its own snapshot."
  (setq drgnx-agent-panel--snap snap)
  (drgnx-agent-panel-composer-redraw))

(defun drgnx-agent-panel--take-entries (pairs &optional from-slice)
  "PAIRS, (INDEX ENTRY) as the hub sends them, are kept for the cards, the pins and the step at point; the hub draws
them.  FROM-SLICE: they come from a page, which never overwrites an entry the hub sent live.  Returns the indexes kept."
  (let (touched)
    (seq-doseq (pair pairs)
      (let ((idx (elt pair 0)) (e (elt pair 1)))
        (unless (and from-slice (gethash idx drgnx-agent-panel--live))
          (unless from-slice (puthash idx t drgnx-agent-panel--live))
          (puthash idx e drgnx-agent-panel--entries)
          (push idx touched))))
    touched))

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
                   (setq drgnx-agent-panel--loading nil drgnx-agent-panel--loaded t drgnx-agent-panel--more nil)
                 (drgnx-agent-panel--ask
                  "agents/slice" (list :id id :from_step (plist-get first :seq) :n n)
                  (lambda (r2 err2)
                    (when (buffer-live-p buf)
                      (with-current-buffer buf
                        (setq drgnx-agent-panel--loading nil drgnx-agent-panel--loaded t)
                        (drgnx-agent-panel--take-steps (append (if err2 steps (or (plist-get r2 :steps) steps)) nil))
                        (unless err2 (drgnx-agent-panel--take-entries (plist-get r2 :entries) t)))))))))))))))

(defun drgnx-agent-panel-older ()
  "Show the rows of one window further back, and load the page of steps before the first one held when the hub has
one."
  (interactive)
  (drgnx-agent-panel--send-look t)
  (when (and drgnx-agent-panel--more (not drgnx-agent-panel--loading)) (drgnx-agent-panel--load t)))

(defun drgnx-agent-panel--scrolled (window start)
  "`window-scroll-functions': WINDOW scrolled to START, at the hub's `more' row (the top of the transcript): the rows
before are asked for.  It moves no window."
  (with-current-buffer (window-buffer window)
    (unless drgnx-agent-panel--loading
      (when-let* ((more (drgnx-view-row-start drgnx-view "more")) ((<= start (1+ more))))
        (with-current-buffer (or (drgnx-agent-panel--twin-from) (current-buffer)) (drgnx-agent-panel-older))))))

(defun drgnx-agent-panel--subscribe ()
  "This panel is shown: the hub sends the session's entries here; the last page comes when it has answered."
  (unless drgnx-agent-panel--subscribed
    (setq drgnx-agent-panel--subscribed t)
    ;; the hub's rows follow the env of the window that now shows them
    (drgnx-view-env-update (drgnx-view-patch-view drgnx-view-patch))
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
  ;; the panel's text in the UI font (agent-panel.html); output, diffs and code name the code font's faces
  (face-remap-add-relative 'default 'drgnx-ui-text)
  ;; Emacs keeps the end in view: a window whose point is at the end (Sjá keeps it there through a draw) scrolls by
  ;; as little as the appended rows need, never recentring
  (setq-local scroll-conservatively 101 scroll-margin 0)
  ;; it opens at its end: its first rows leave point there (Sjá's draw), so it opens on the latest step
  (setq-local drgnx-view-sja-tail t)
  (add-hook 'window-scroll-functions #'drgnx-agent-panel--scrolled nil t)
  (add-hook 'kill-buffer-hook #'drgnx-agent-panel--killed nil t))

(defun drgnx-agent-panel--killed ()
  (when (eq (gethash drgnx-agent-panel--session drgnx-agent-panel--by-session) (current-buffer))
    (remhash drgnx-agent-panel--session drgnx-agent-panel--by-session))
  (drgnx-agent-panel--unsubscribe))

(defun drgnx-agent-panel-buffers ()
  "The panels: one per session (a panel's buffer in another display class is not one, `drgnx-agent-panel--twin')."
  (seq-filter (lambda (b) (and (eq (buffer-local-value 'major-mode b) 'drgnx-agent-panel-mode) (not (drgnx-view-patch-twin-p b))))
              (buffer-list)))

(defun drgnx-agent-panel-buffer (session)
  "The panel of hub SESSION, made when there is none.  It shows nothing until a window does."
  (let ((buffer (get-buffer-create (format "*drgnx agent: %s*" session))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'drgnx-agent-panel-mode)
        (drgnx-agent-panel-mode)
        (puthash session buffer drgnx-agent-panel--by-session)
        (setq drgnx-agent-panel--session session
              drgnx-agent-panel--entries (make-hash-table :test #'eql) drgnx-agent-panel--live (make-hash-table :test #'eql)
              drgnx-agent-panel--steps (make-hash-table :test #'eql)
              drgnx-agent-panel--open (make-hash-table :test #'equal))
        (drgnx-agent-panel-steps-init)
        (drgnx-agent-panel--rows-attach session)
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
  "The panel of session ID, or nil: a lookup in `drgnx-agent-panel--by-session', no walk over the buffers."
  (let ((b (gethash id drgnx-agent-panel--by-session)))
    (and (buffer-live-p b) b)))

(defun drgnx-agent-panel--refresh-steps ()
  "Ask the hub again for the steps this panel holds (a revert or fork changed `revertible' and `undone_by', which the
commands on the step at point read; the hub draws its rows again itself)."
  (when (and drgnx-agent-panel--first-step (> (hash-table-count drgnx-agent-panel--steps) 0))
    (let ((buf (current-buffer)))
      (drgnx-agent-panel--ask
       "timeline/get" (list :scope "session" :id drgnx-agent-panel--session
                            :limit (min 200 (hash-table-count drgnx-agent-panel--steps))
                            :before (1+ (apply #'max (hash-table-keys drgnx-agent-panel--steps))))
       (lambda (r err)
         (when (and (not err) (buffer-live-p buf))
           (with-current-buffer buf
             (drgnx-agent-panel--take-steps (append (plist-get r :steps) nil)))))))))

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

;;;; The module

(declare-function drgnx-agent-panel--composer-of "drgnx-agent-panel-composer")
(declare-function drgnx-agent-panel--header-of "drgnx-agent-panel-header")
(declare-function drgnx-agent-panel-header--for "drgnx-agent-panel-header" (header buffer))

(defun drgnx-agent-panel--companions (buffer)
  "The area companions of panel BUFFER (`drgnx-pane-define-kind' :companions): (ABOVE BELOW), the header above and the
composer below.  BUFFER may be the transcript's twin in another display class: the header is then its twin of that
class (`drgnx-agent-panel-header--for'); the composer, plain text, is the same buffer in every class."
  (list (drgnx-agent-panel-header--for (drgnx-agent-panel--header-of buffer) buffer)
        (drgnx-agent-panel--composer-of buffer)))

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
  (drgnx-pane-define-kind 'agent-panel :title " AGENT" :home 'right :buffer #'drgnx-agent-panel--current-buffer
                          :companions #'drgnx-agent-panel--companions)
  (drgnx-module-hook 'drgnx-hub-event-functions panel-event (event data)
    :events '("history/applied" "agent" "agent-entries")
    (drgnx-agent-panel--event event data))
  (drgnx-module-hook 'drgnx-hub-connected-functions panel-resubscribe () (drgnx-agent-panel--resubscribe))
  (drgnx-module-hook 'window-buffer-change-functions panel-windows (frame) (drgnx-agent-panel-sync-windows frame))
  (drgnx-agent-panel-steps-setup)
  (drgnx-agent-panel-composer-setup)
  (drgnx-agent-panel-explain-setup)
  (drgnx-agent-panel-huddle-setup)
  (drgnx-module-hook 'drgnx-hub-event-functions huddle-event (event data)
    :events '("huddle")
    (drgnx-agent-panel-huddle--event event data))
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
  "Open or fold the thinking and the detail of the step at point (off a step: the selected one).  A fold is this
panel's own state at once; the hub hears it after (`agents/panel/look') and draws the rows again."
  (interactive)
  (let ((key (drgnx-agent-panel--key-at)))
    (unless (eq (car-safe key) :e)
      (when-let* ((id (drgnx-view-nav-selection)))
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
