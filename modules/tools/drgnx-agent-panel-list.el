;;; drgnx-agent-panel-list.el --- the agents list: one line for each session, RET opens its panel -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Part of module tools/agent-panel.  `agents-view' shows the sessions the hub runs, one row each (name, status,
;; context, what waits for you); RET opens that session's panel.  The rows are a view (wb/drgnx-view.el): a change of a
;; session draws that row again, and nothing is drawn while no window shows the list.  Below them, a Past sessions
;; section: your other CLIs' sessions (drgnx-agent-history.el), a few, this workspace's first, as the hub builds those
;; rows (a hub view this buffer places after its own rows); RET opens one, and the Past Sessions keys (search, resume,
;; resume in terminal) work on them.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-view)
(require 'drgnx-registry)
(require 'drgnx-modules)
(unless (featurep 'drgnx-agent-history)
  (load (expand-file-name "drgnx-agent-history" (file-name-directory (or load-file-name buffer-file-name))) nil t))

(declare-function drgnx-agents-sessions "drgnx-agents")
(declare-function drgnx-agent-session-name "drgnx-agents")
(declare-function drgnx-agent-session-status "drgnx-agents")
(declare-function drgnx-agent-session-remote "drgnx-agents")
(declare-function drgnx-agent-session-queue "drgnx-agents")
(declare-function drgnx-agent-session-permissions "drgnx-agents")
(declare-function drgnx-agent-session-reviews "drgnx-agents")
(declare-function drgnx-agents-context-percent "drgnx-agents")
(declare-function drgnx-agent-panel-open "drgnx-agent-panel")
(declare-function drgnx-agent-history-section "drgnx-agent-history" (limit))
(declare-function drgnx-agent-history-open "drgnx-agent-history" (&optional session))
(declare-function drgnx-view-patch-render "drgnx-view" (key))
(defvar drgnx-agent-history-mode-map)
(defvar drgnx-view-patch)
(defvar drgnx-view-patch-apply-function)
(declare-function drgnx-wb-area-show "drgnx-wb")

(defconst drgnx-agent-panel-list-buffer-name "*drgnx Agents*")

(defconst drgnx-agent-panel-list-past-limit 8 "How many past sessions the Agents list shows (Show Past Sessions: all).")

(defvar-local drgnx-agent-panel-list--past nil "The Past sessions section's hub row keys, in the hub's order.")

(defvar drgnx-agent-panel-list--last (make-hash-table :test #'eq :weakness 'key)
  "Session → the time (`float-time') it last changed, as this list heard it.")

(defun drgnx-agent-panel-list-last-active (s)
  "The time session S last changed (status, entries, queue, what waits), or nil."
  (gethash s drgnx-agent-panel-list--last))

(defun drgnx-agent-panel-list--session (id)
  (seq-find (lambda (s) (equal (drgnx-agent-session-remote s) id)) (drgnx-agents-sessions)))

(defun drgnx-agent-panel-list--waiting (s)
  (string-join
   (delq nil (list (and (drgnx-agent-session-queue s) (format "%d queued" (length (drgnx-agent-session-queue s))))
                   (and (drgnx-agent-session-permissions s) (format "%d to answer" (length (drgnx-agent-session-permissions s))))
                   (and (drgnx-agent-session-reviews s) (format "%d edit to review" (length (drgnx-agent-session-reviews s))))))
   ", "))

(defun drgnx-agent-panel-list--past-key (key)
  "The hub's key of the Past sessions row KEY (\"past/HUB-KEY\"), or nil when KEY is a live session's."
  (and (stringp key) (string-prefix-p "past/" key) (substring key 5)))

(defun drgnx-agent-panel-list--render (key)
  (if-let* ((past (drgnx-agent-panel-list--past-key key)))
      (drgnx-view-patch-render past)
    (if (eq key :empty)
        (propertize "No agent sessions yet: New Agent Session… starts one; Show Past Sessions lists your other CLIs' sessions\n" 'face 'shadow)
      (if-let* ((s (drgnx-agent-panel-list--session key)))
          (propertize (format "%-26s %-9s %5s  %s\n" (drgnx-agent-session-name s) (symbol-name (drgnx-agent-session-status s))
                              (if-let* ((p (drgnx-agents-context-percent s))) (format "%d%%" p) "")
                              (drgnx-agent-panel-list--waiting s))
                      'drgnx-agent-panel-list-id key)
        "\n"))))

(defun drgnx-agent-panel-list--sig (key)
  (if-let* ((past (drgnx-agent-panel-list--past-key key)))
      (gethash past (drgnx-view-patch-rows drgnx-view-patch))
    (if-let* (((not (eq key :empty))) (s (drgnx-agent-panel-list--session key)))
        (vector (drgnx-agent-session-name s) (drgnx-agent-session-status s) (drgnx-agents-context-percent s)
                (length (drgnx-agent-session-queue s)) (length (drgnx-agent-session-permissions s))
                (length (drgnx-agent-session-reviews s)))
      key)))

(defun drgnx-agent-panel-list--sync (view)
  (let ((ids (delq nil (mapcar #'drgnx-agent-session-remote (drgnx-agents-sessions))))
        (past (mapcar (lambda (k) (concat "past/" k)) drgnx-agent-panel-list--past)))
    (drgnx-view-sync-rows view (append (or ids (list :empty)) past) #'drgnx-agent-panel-list--sig)))

(defun drgnx-agent-panel-list--past-apply (state view patch)
  "The Past sessions section's PATCH (`drgnx-view-patch-apply-function'): its rows stored in STATE, their order kept
in `drgnx-agent-panel-list--past', and VIEW touched so its sync places them after the live sessions."
  (let ((table (drgnx-view-patch-rows state)))
    (when (drgnx-view-patch--reset-p patch) (clrhash (drgnx-view-patch-styles state)))
    (dolist (st (plist-get patch :styles))
      (puthash (car st) (cadr st) (drgnx-view-patch-styles state)))
    (dolist (op (plist-get patch :ops))
      (cond
       ((plist-member op :reset)
        (clrhash table)
        (let ((rows (plist-get op :reset)))
          (dolist (r rows) (puthash (plist-get r :key) r table))
          (setq drgnx-agent-panel-list--past (mapcar (lambda (r) (plist-get r :key)) rows))))
       ((plist-member op :insert)
        (let* ((ins (plist-get op :insert)) (after (plist-get ins :after))
               (keys (mapcar (lambda (r) (puthash (plist-get r :key) r table) (plist-get r :key)) (plist-get ins :rows)))
               (cell (and after (member after drgnx-agent-panel-list--past))))
          (setq drgnx-agent-panel-list--past
                (cond ((null after) (append keys drgnx-agent-panel-list--past))
                      (cell (setcdr cell (append keys (cdr cell))) drgnx-agent-panel-list--past)
                      (t (append drgnx-agent-panel-list--past keys))))))
       ((plist-member op :replace)
        (dolist (r (plist-get op :replace)) (puthash (plist-get r :key) r table)))
       ((plist-member op :remove)
        (dolist (k (plist-get op :remove))
          (remhash k table)
          (setq drgnx-agent-panel-list--past (delete k drgnx-agent-panel-list--past))))))
    (drgnx-view-touch view)))

(drgnx-view-define 'agent-panel-list :render #'drgnx-agent-panel-list--render :sync #'drgnx-agent-panel-list--sync)

(defvar drgnx-agent-panel-list-mode-map
  (let ((m (make-sparse-keymap))) (set-keymap-parent m drgnx-agent-history-mode-map) m)
  "Keys come from the key profiles (command `agents-open'); the Past Sessions keys (`sessions-*') work on its past
rows.")

(define-derived-mode drgnx-agent-panel-list-mode special-mode "Agents"
  "The agent sessions, one on a line: RET opens the panel of the one at point."
  (setq-local truncate-lines t cursor-type nil))

(defun drgnx-agent-panel-list-buffer ()
  "The agents list, up to date."
  (let ((b (get-buffer-create drgnx-agent-panel-list-buffer-name)))
    (with-current-buffer b
      (unless (derived-mode-p 'drgnx-agent-panel-list-mode) (drgnx-agent-panel-list-mode))
      (unless (drgnx-view-p drgnx-view)
        (drgnx-view-attach 'agent-panel-list)
        (setq-local drgnx-view-patch-apply-function #'drgnx-agent-panel-list--past-apply)
        (drgnx-agent-history-section drgnx-agent-panel-list-past-limit))
      (drgnx-view-touch drgnx-view)
      (drgnx-view-draw-now drgnx-view))
    b))

(defun drgnx-agent-panel-list-open ()
  "Open the panel of the session on this line; on a past session, its transcript (read-only)."
  (interactive)
  (if (or (get-text-property (line-beginning-position) 'drgnx-past) (get-text-property (point) 'drgnx-past))
      (drgnx-agent-history-open)
    (let ((id (or (get-text-property (line-beginning-position) 'drgnx-agent-panel-list-id) (user-error "No agent on this line"))))
      (drgnx-agent-panel-open id))))

(defun drgnx-agent-panel-list-show ()
  "Show the agents list in the right dock."
  (interactive)
  (let ((b (drgnx-agent-panel-list-buffer)))
    (if (fboundp 'drgnx-wb-area-show) (drgnx-wb-area-show 'right 'agents b) (display-buffer b))))

(defun drgnx-agent-panel-list-changed (session)
  "A session changed: note when, and the list, when it exists, marks its rows; it draws them only while shown."
  (puthash session (float-time) drgnx-agent-panel-list--last)
  (when-let* ((b (get-buffer drgnx-agent-panel-list-buffer-name)) (view (buffer-local-value 'drgnx-view b))
              ((drgnx-view-p view)))
    (drgnx-view-touch view)))

;;;; The Agents side (Flow Task 24): the hub's kit cards, and a card's conversation in the side

(declare-function drgnx-agent-panel-buffer "drgnx-agent-panel" (session))
(declare-function drgnx-agent-panel--companions "drgnx-agent-panel" (buffer))
(declare-function drgnx-pane-show "drgnx-panes")
(declare-function drgnx-pane-define-kind "drgnx-panes")
(declare-function drgnx-view-patch-attach "drgnx-view")
(declare-function drgnx-view-env-register "drgnx-view-env")
(declare-function drgnx-view-env-unregister "drgnx-view-env")
(declare-function drgnx-wb-rows-setup "drgnx-wb")
(declare-function drgnx-hub-call "drgnx-hub-client")
(defvar drgnx-hub--events)

(defconst drgnx-agents-side-view-id "agents-side" "The hub-fed view of the Agents side's cards.")
(defconst drgnx-agents-side-buffer-name "*drgnx Agents side*")

(defvar drgnx-agents-side--state (list :view 'cards)
  "What the Agents side shows: (:view cards), or (:view conversation :session ID): a card's conversation, compact.")

(defun drgnx-agents-side-state ()
  "What the Agents side shows: (:view cards) or (:view conversation :session ID)."
  drgnx-agents-side--state)

(defvar drgnx-agents-side-mode-map (make-sparse-keymap) "Keys of the Agents side's cards (the key profiles bind them).")

(define-derived-mode drgnx-agents-side-mode special-mode "Agents"
  "The Agents side: a card per session, needs you first (the hub draws them with the kit)."
  (setq-local truncate-lines t cursor-type nil mode-line-format nil)
  (buffer-disable-undo)
  (when (fboundp 'drgnx-wb-rows-setup) (drgnx-wb-rows-setup)))

(defun drgnx-agents-side--subscribe (&optional _view)
  (when (and (boundp 'drgnx-hub--events) (process-live-p drgnx-hub--events))
    (drgnx-hub-call "agents/side/subscribe" (list :view drgnx-agents-side-view-id) #'ignore)))

(defun drgnx-agents-side--cards-buffer ()
  "The cards' buffer, attached as the hub-fed view the first time."
  (or (get-buffer drgnx-agents-side-buffer-name)
      (with-current-buffer (get-buffer-create drgnx-agents-side-buffer-name)
        (drgnx-agents-side-mode)
        (when (fboundp 'nidhogg-view--call)
          (drgnx-view-patch-attach drgnx-agents-side-view-id "unshown" :sja t)
          (require 'drgnx-view-env)
          (drgnx-view-env-register drgnx-agents-side-view-id (current-buffer) #'drgnx-agents-side--subscribe)
          (drgnx-agents-side--subscribe))
        (current-buffer))))

(defun drgnx-agents-side--buffer ()
  "The buffer the side shows now: a card's conversation, or the cards."
  (if (eq (plist-get drgnx-agents-side--state :view) 'conversation)
      (drgnx-agent-panel-buffer (plist-get drgnx-agents-side--state :session))
    (drgnx-agents-side--cards-buffer)))

(defun drgnx-agents-side--back-line ()
  "The compact conversation's header line: a back arrow to the cards."
  (list (propertize " ← Agents " 'mouse-face 'drgnx-hover 'help-echo "Back to the cards"
                    'keymap (let ((m (make-sparse-keymap))) (define-key m [header-line mouse-1] #'drgnx-agents-side-back) m))))

(defun drgnx-agents-side-open-conversation (session)
  "Show SESSION's conversation in the side, in the compact form (the panel's three windows in the right area), with a
back arrow to the cards.  Returns the panel's buffer."
  (let ((buf (drgnx-agent-panel-buffer session)))
    (setq drgnx-agents-side--state (list :view 'conversation :session session))
    (with-current-buffer buf (setq-local header-line-format (drgnx-agents-side--back-line)))
    (drgnx-pane-show 'agents-side :buffer buf)
    buf))

(defun drgnx-agents-side-back ()
  "The Agents side shows the cards again."
  (interactive)
  (when-let* ((s (plist-get drgnx-agents-side--state :session)) (b (get-buffer (format "*drgnx agent: %s*" s))))
    (with-current-buffer b (kill-local-variable 'header-line-format)))
  (setq drgnx-agents-side--state (list :view 'cards))
  (drgnx-pane-show 'agents-side :buffer (drgnx-agents-side--cards-buffer)))

(defun drgnx-agents-side-act ()
  "The card's button at point: Answer, Review or Open shows that session's conversation in the side; All › the list."
  (interactive)
  (pcase (or (get-text-property (point) 'drgnx-action) (get-text-property (pos-bol) 'drgnx-action))
    (`["all"] (drgnx-agent-panel-list-show))
    ((and (pred vectorp) a (guard (>= (length a) 2))) (drgnx-agents-side-open-conversation (aref a 1)))
    (`("all") (drgnx-agent-panel-list-show))
    (`(,_ ,session . ,_) (drgnx-agents-side-open-conversation session))
    (_ (user-error "No card here"))))

(defun drgnx-agents-side-companions (buffer)
  "The side's companions: a conversation's header and composer (the compact form); none for the cards."
  (and (eq (buffer-local-value 'major-mode buffer) 'drgnx-agent-panel-mode) (drgnx-agent-panel--companions buffer)))

(defun drgnx-agents-side-file-chip (file &optional lines)
  "The composer's context item for FILE shown in the frame's last editor: \"@ file\", or \"@ lines a–b\" with the
region's LINES (A . B)."
  (if lines (list :file file :lines lines) (list :file file)))

(defun drgnx-agents-side-on-file-chip (file agents)
  "The chip that offers the conversation of an agent working on FILE: AGENTS is ((SESSION . NAME) ...), the sessions the
presence model has in it.  Nil without one.  Showing it never switches the side."
  (when-let* ((a (car agents)))
    (list :label (format "%s is editing this file ›" (cdr a)) :session (car a) :file file)))

(defun drgnx-agents-side-raise (card)
  "The at-limit card's Raise: `budget/raise' for CARD (:card :unit :limit, the new limit) with `resume'."
  (drgnx-hub-call "budget/raise"
                  (list :card (plist-get card :card)
                        :limits (vector (list :unit (plist-get card :unit) :amount (plist-get card :limit)))
                        :resume t)
                  (lambda (_r err) (when err (message "Budget: %s" (if (stringp err) err (plist-get err :message)))))))

(defun drgnx-agents-side-stop-card (card)
  "The at-limit card's Stop: `agents/stop' for a session's card (:session), `job/card' stop for a job's (:job :card)."
  (if-let* ((s (plist-get card :session)))
      (drgnx-hub-call "agents/stop" (list :id s) #'ignore)
    (drgnx-hub-call "job/card" (list :card (plist-get card :card) :action "stop") #'ignore)))

(defun drgnx-agents-side-teardown ()
  "Turning tools/agent-panel off: the cards' buffer goes (the hub forgets the view with it)."
  (when-let* ((b (get-buffer drgnx-agents-side-buffer-name)))
    (when (and (boundp 'drgnx-hub--events) (process-live-p drgnx-hub--events))
      (drgnx-hub-call "agents/side/close" (list :view drgnx-agents-side-view-id) #'ignore))
    (when (fboundp 'drgnx-view-env-unregister) (drgnx-view-env-unregister drgnx-agents-side-view-id))
    (kill-buffer b))
  (setq drgnx-agents-side--state (list :view 'cards)))

(defun drgnx-agent-panel-list-setup ()
  (when (require 'drgnx-panes nil t)
    (drgnx-pane-define-kind 'agents :home 'right :title "Agents" :placeholder #'drgnx-agent-panel-list-buffer))
  (when (fboundp 'drgnx-wb-place) (drgnx-wb-place 'drgnx-agent-panel-list-mode 'right :tab 'agents))
  (drgnx-module-hook 'drgnx-agents-changed-functions list-changed (session) :module 'tools/agent-panel (drgnx-agent-panel-list-changed session))
  (drgnx-command-define 'agents-view :category "Agents" :title "Show Agents" :command #'drgnx-agent-panel-list-show
                        :doc "The agent sessions, one on a line; RET opens a panel")
  (drgnx-command-define 'agents-open :category "Agents" :title "Open" :command #'drgnx-agent-panel-list-open
                        :map 'drgnx-agent-panel-list-mode-map :doc "The panel of the session on this line")
  (drgnx-command-define 'agents-side-act :category "Agents" :title "Open the Card's Conversation"
                        :command #'drgnx-agents-side-act :map 'drgnx-agents-side-mode-map
                        :doc "The card's button: its conversation in the side, compact, with a back arrow")
  (drgnx-command-define 'agents-side-back :category "Agents" :title "Back to the Cards"
                        :command #'drgnx-agents-side-back :doc "The Agents side shows the cards again")
  (when (fboundp 'drgnx-pane-define-kind)
    (drgnx-pane-define-kind 'agents-side :title " AGENTS" :home 'right :buffer #'drgnx-agents-side--buffer
                            :companions #'drgnx-agents-side-companions)))

(provide 'drgnx-agent-panel-list)
;;; drgnx-agent-panel-list.el ends here
