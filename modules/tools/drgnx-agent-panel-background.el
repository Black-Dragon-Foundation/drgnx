;;; drgnx-agent-panel-background.el --- The agent panel's background work: commands, output, ticking, ends (library of tools/agent-panel) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; What an agent leaves running between turns (ACP v2's list, and drgnx's own jobs) is the hub's: it builds the panel's
;; chip, the pinned list and the transcript's lines (`view/panel_top/background.rs', `view/bgwork.rs').  This file is
;; what Emacs does with them: the commands on a row (fold the list, Stop, Stop all, Output), the one timer that keeps the
;; list's elapsed cells ticking while a panel shows a running item, the question asked before a command ends a chat
;; whose items run (the chat's end stops them), and the notices when an item ends while its chat is not on screen: the
;; status bar's `AGENT: ... failed (exit 1)' and the desktop notice.  The session's items come with its snapshot into the
;; mirror (`drgnx-agent-session-background', `-background-ended': plists, `:can_cancel', `:started_ms', ...).
;; Loaded by tools/agent-panel (drgnx-agent-panel.el); defines no module; its setup is `drgnx-agent-panel-background-setup'.
;; See docs/guide/agents.md, "Background work".

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'text-property-search)

(defvar drgnx-agent-panel--session)
(defvar drgnx-agent-companion--header)
(defvar drgnx-agent-panel--by-session)
(defvar drgnx-agent-panel-mode-map)
(defvar drgnx-guard--automatic)
(declare-function drgnx-agents-get "drgnx-agents" (id))
(declare-function drgnx-agents-kill "drgnx-agents" (s &optional ask))
(declare-function prop-match-value "text-property-search")
(declare-function drgnx-agent-session-background "drgnx-agents")
(declare-function drgnx-agent-session-background-ended "drgnx-agents")
(declare-function drgnx-agent-session-name "drgnx-agents")
(declare-function drgnx-agent-session-profile "drgnx-agents")
(declare-function drgnx-agent-session-remote "drgnx-agents")
(declare-function drgnx-hub-call "drgnx-hub-client")
(declare-function drgnx-agent-panel--main-of "drgnx-agent-panel-composer" (buffer))
(declare-function drgnx-agent-panel--send-look "drgnx-agent-panel" (&optional older))
(declare-function drgnx-agent-panel--output-fetch "drgnx-agent-panel-steps" (session tool from callback))
(declare-function drgnx-agent-panel-open "drgnx-agent-panel" (&optional session))
(declare-function drgnx-save-ask-can-ask-p "drgnx-save-ask")
(declare-function drgnx-notify "drgnx-notice" (source severity text &rest args))
(declare-function drgnx-notice-desktop-take "drgnx-notice-desktop" (item))
(declare-function drgnx-statusbar-refresh "drgnx-statusbar" (&optional changed))
(declare-function drgnx-statusbar-define-segment "drgnx-statusbar")
(declare-function drgnx-command-define "drgnx-commands")
(declare-function drgnx-timer-start "drgnx-timer")
(declare-function drgnx-timer-cancel "drgnx-timer")
(declare-function drgnx-timer-active-p "drgnx-timer")
(declare-function drgnx-px "drgnx-pixels" (logical &optional frame scale))

;;;; The items

(defvar-local drgnx-agent-panel--bg-folded nil "Non-nil while this chat's pinned background list is folded.")
(defvar-local drgnx-agent-panel--bg-selected nil "The id of the background item selected in the list (its actions show), or nil.")

(defun drgnx-agent-panel-background--items (session &optional ended)
  "SESSION's background items (a hub id): the running list, or with ENDED the ended ones."
  (when-let* ((s (drgnx-agents-get session)))
    (if ended (drgnx-agent-session-background-ended s) (drgnx-agent-session-background s))))

(defun drgnx-agent-panel-background--running (session)
  "The items of SESSION that run as far as anyone knows: not ended, and the agent did not say `unknown'."
  (seq-filter (lambda (i) (and (null (plist-get i :end)) (not (equal (plist-get i :status) "unknown"))))
              (drgnx-agent-panel-background--items session)))

(defun drgnx-agent-panel-background--find (session id)
  "The item ID of SESSION, running or ended, or nil."
  (seq-find (lambda (i) (equal (plist-get i :id) id))
            (append (drgnx-agent-panel-background--items session) (drgnx-agent-panel-background--items session t))))

(defun drgnx-agent-panel-background--main ()
  "The panel's buffer of the current one (a panel, its header or a twin)."
  (or (and (fboundp 'drgnx-agent-panel--main-of) (drgnx-agent-panel--main-of (current-buffer))) (current-buffer)))

(defun drgnx-agent-panel-background--here ()
  "The hub session of the panel point is in."
  (or (buffer-local-value 'drgnx-agent-panel--session (drgnx-agent-panel-background--main))
      (user-error "Not in an agent panel")))

(defun drgnx-agent-panel-background--elapsed (item)
  "ITEM's elapsed time as `m:ss'."
  (let ((secs (max 0 (floor (- (float-time) (/ (or (plist-get item :started_ms) 0) 1000.0))))))
    (format "%d:%02d" (/ secs 60) (% secs 60))))

;;;; Fold and selection

(defun drgnx-agent-panel-background--item-id ()
  "The item id point is on, else the one selected in the list of this chat."
  (or (get-text-property (point) 'drgnx-bg-item)
      (buffer-local-value 'drgnx-agent-panel--bg-selected (drgnx-agent-panel-background--main))
      (user-error "No background item selected: b selects one")))

(defun drgnx-agent-panel-background-select (id)
  "Select item ID of this chat's list: its actions show on its row."
  (with-current-buffer (drgnx-agent-panel-background--main)
    (setq drgnx-agent-panel--bg-selected id drgnx-agent-panel--bg-folded nil)
    (drgnx-agent-panel--send-look)))

(defun drgnx-agent-panel-background-list ()
  "The list of this chat's background work: unfold it and select its first item; again, the next one; after the last,
fold it."
  (interactive)
  (let* ((main (drgnx-agent-panel-background--main))
         (ids (mapcar (lambda (i) (plist-get i :id))
                      (drgnx-agent-panel-background--items (buffer-local-value 'drgnx-agent-panel--session main)))))
    (with-current-buffer main
      (cond (drgnx-agent-panel--bg-folded (setq drgnx-agent-panel--bg-folded nil drgnx-agent-panel--bg-selected (car ids)))
            ((null drgnx-agent-panel--bg-selected)
             (if ids (setq drgnx-agent-panel--bg-selected (car ids)) (setq drgnx-agent-panel--bg-folded t)))
            (t (if-let* ((next (cadr (member drgnx-agent-panel--bg-selected ids))))
                   (setq drgnx-agent-panel--bg-selected next)
                 (setq drgnx-agent-panel--bg-selected nil drgnx-agent-panel--bg-folded t))))
      (drgnx-agent-panel--send-look)
      (drgnx-agent-panel-background--tick-sync main))))

(defun drgnx-agent-panel-background-more ()
  "The list shows six items; this picks any other one of the chat's background work (selecting it)."
  (interactive)
  (let* ((sid (drgnx-agent-panel-background--here))
         (items (drgnx-agent-panel-background--items sid))
         (names (mapcar (lambda (i) (cons (format "%s  %s" (plist-get i :id) (plist-get i :description)) (plist-get i :id))) items))
         (pick (and names (completing-read "Background item: " names nil t))))
    (when pick (drgnx-agent-panel-background-select (cdr (assoc pick names))))))

;;;; Stop

(defun drgnx-agent-panel-background--cancel (session id)
  "Ask the hub to stop item ID of SESSION; an answer that it already ended, or that the agent does not allow it, is
said once in the echo area, never an error."
  (drgnx-hub-call "agents/background-cancel" (list :id session :item id)
                  (lambda (_r err)
                    (when err
                      (message "%s" (if (string-match-p "not a running" (format "%s" err))
                                        "That item has already ended."
                                      "This agent can't stop it."))))))

(defun drgnx-agent-panel-background-stop (&optional session item)
  "Stop the background item at point (or ITEM of SESSION).  Only where the agent lets a client stop it."
  (interactive)
  (let* ((session (or session (drgnx-agent-panel-background--here)))
         (item (or item (drgnx-agent-panel-background--item-id)))
         (it (drgnx-agent-panel-background--find session item)))
    (cond ((or (null it) (plist-get it :end)) (message "That item has already ended."))
          ((not (plist-get it :can_cancel)) (message "This agent can't stop it."))
          (t (drgnx-agent-panel-background--cancel session item)))))

(defun drgnx-agent-panel-background--item-line (item)
  "One line of the question's list: kind mark, description and elapsed time."
  (format "  %s %s  %s"
          (pcase (plist-get item :kind) ("terminal" "$") ("subagent" "@") (_ "◉"))
          (truncate-string-to-width (replace-regexp-in-string "\n" " " (or (plist-get item :description) "")) 60 nil nil "…")
          (drgnx-agent-panel-background--elapsed item)))

(defun drgnx-agent-panel-background--ask (_session items &optional kind)
  "Ask about stopping ITEMS (plists): `stop' (Stop them) or `keep'.  KIND `stop-all' words it for Stop all, else for
ending the chat (the mockup: \"End this chat?\", \"Keep it running\", \"Stop them and end\").  Where nobody can answer
the answer is `keep', unasked.  Only a command the user ran calls this."
  (if (not (and (fboundp 'drgnx-save-ask-can-ask-p) (drgnx-save-ask-can-ask-p)))
      'keep
    (let* ((all (eq kind 'stop-all))
           (title (if all "Stop all background work?" "End this chat?"))
           (body (if all "These will be stopped:" "These are still running and will stop when the chat ends:"))
           (stop-label (if all "Stop them" "Stop them and end"))
           (list (mapconcat #'drgnx-agent-panel-background--item-line items "\n")))
      (condition-case nil
          (if (and (consp last-nonmenu-event) use-dialog-box (display-popup-menus-p))
              (or (x-popup-dialog t (list (concat title "\n" body "\n" list)
                                          (cons "Keep it running" 'keep) (cons stop-label 'stop)))
                  'keep)
            (let (answer)
              (while (not answer)
                (let ((key (read-event (format "%s %s\n%s\n(s) %s  (k) Keep it running " title body list stop-label))))
                  (setq answer (pcase key
                                 ((or ?s ?S) 'stop)
                                 ((or ?k ?K ?\e 'escape ?\C-g) 'keep)
                                 ((pred characterp) (ding) nil)))))
              (message nil)
              answer))
        (quit 'keep)))))

(defun drgnx-agent-panel-background-stop-all (&optional session)
  "Stop everything this chat runs in the background, after the same list as ending a chat.  Items the agent does not
let a client stop are left to it."
  (interactive)
  (let* ((session (or session (drgnx-agent-panel-background--here)))
         (items (drgnx-agent-panel-background--items session)))
    (unless items (user-error "Nothing runs in the background"))
    (when (eq (drgnx-agent-panel-background--ask (drgnx-agents-get session) items 'stop-all) 'stop)
      (dolist (i items)
        (when (and (plist-get i :can_cancel) (null (plist-get i :end)))
          (drgnx-agent-panel-background--cancel session (plist-get i :id)))))))

;;;; Ending a chat (`drgnx-agents-kill' with ASK: a command the user ran)

(defun drgnx-agent-panel-background--end-ask (session-struct)
  "`drgnx-agents-end-ask-functions': nil to keep the chat when its items run and the answer is Keep it running; on Stop
them and end, each cancellable item the question listed is cancelled first, and what started meanwhile is named in a
notice (it stops with the chat, but was not asked about)."
  (let* ((sid (drgnx-agent-session-remote session-struct))
         (shown (drgnx-agent-panel-background--running sid)))
    (if (null shown)
        t
      (pcase (drgnx-agent-panel-background--ask session-struct shown)
        ('stop
         (dolist (i shown)
           (when (plist-get i :can_cancel) (drgnx-agent-panel-background--cancel sid (plist-get i :id))))
         (let ((new (seq-remove (lambda (i) (seq-find (lambda (o) (equal (plist-get o :id) (plist-get i :id))) shown))
                                (drgnx-agent-panel-background--running sid))))
           (when (and new (fboundp 'drgnx-notify))
             (drgnx-notify 'agents 'info
                           (format "Also stopped with the chat: %s"
                                   (mapconcat (lambda (i) (or (plist-get i :description) "")) new ", ")))))
         t)
        (_ nil)))))

;;;; Output

(defun drgnx-agent-panel-background-output (&optional session item)
  "The output of the background item at point or selected (or ITEM of SESSION): a subagent opens its own panel; the
others open what the hub kept of the output (`agents/background-output') in a read-only buffer, a snapshot of it."
  (interactive)
  (let* ((session (or session (drgnx-agent-panel-background--here)))
         (item (or item (drgnx-agent-panel-background--item-id)))
         (it (or (drgnx-agent-panel-background--find session item) (user-error "That item is gone"))))
    (if (equal (plist-get it :kind) "subagent")
        (drgnx-agent-panel-open item)
      (let ((name (format "*drgnx output: %s*" (truncate-string-to-width (or (plist-get it :description) item) 50))))
        (drgnx-hub-call
         "agents/background-output" (list :id session :item item)
         (lambda (r err)
           (if (or err (not (stringp (plist-get r :text))))
               (message "No output is kept for that item.")
             ;; a new buffer each time: what was kept is a snapshot, never redrawn in place
             (when-let* ((old (get-buffer name))) (kill-buffer old))
             (with-current-buffer (get-buffer-create name)
               (when (plist-get r :truncated) (insert "[older output was left out]\n"))
               (insert (plist-get r :text))
               (goto-char (point-min))
               (special-mode)
               (display-buffer (current-buffer))))))))))

;;;; Ending a chat by command

(defun drgnx-agent-panel-end ()
  "End this chat: its agent process stops.  While background work runs, it is asked about first (Keep it running, or
Stop them and end).  Closing the panel does not end the chat."
  (interactive)
  (let* ((sid (drgnx-agent-panel-background--here))
         (s (or (drgnx-agents-get sid) (user-error "That chat is gone"))))
    (drgnx-agents-kill s t)))

;;;; The elapsed cells

(defun drgnx-agent-panel-background--patch-elapsed (buffer now)
  "Rewrite the `drgnx-bg-elapsed' cells of BUFFER (their value is when the item began, in ms) for NOW (seconds): the
text of a cell and nothing else."
  (with-current-buffer buffer
    (let ((inhibit-read-only t) (inhibit-modification-hooks t) (modified (buffer-modified-p)) m)
      (save-excursion
        (goto-char (point-min))
        (while (setq m (text-property-search-forward 'drgnx-bg-elapsed nil (lambda (_ v) (numberp v))))
          (let* ((beg (prop-match-beginning m)) (end (prop-match-end m)) (started (prop-match-value m))
                 (secs (max 0 (floor (- now (/ started 1000.0)))))
                 (new (format "%d:%02d" (/ secs 60) (% secs 60))))
            (unless (equal new (buffer-substring-no-properties beg end))
              (let ((props (text-properties-at beg)))
                (goto-char beg)
                (delete-region beg end)
                (insert (apply #'propertize new props)))))))
      (set-buffer-modified-p modified))))

(defun drgnx-agent-panel-background--visible-p (buffer)
  "Whether a window shows the panel BUFFER (or its header)."
  (or (get-buffer-window buffer t)
      (let ((h (buffer-local-value 'drgnx-agent-companion--header buffer)))
        (and (buffer-live-p h) (get-buffer-window h t)))))

(defun drgnx-agent-panel-background--running-p (buffer)
  "Whether the session of the panel BUFFER has an item running."
  (and (buffer-live-p buffer)
       (when-let* ((sid (buffer-local-value 'drgnx-agent-panel--session buffer)))
         (drgnx-agent-panel-background--running sid))))

(defun drgnx-agent-panel-background--tick (buffer)
  "The timer's function: the cells of BUFFER's header, and the timer stops when nothing is left to tick."
  (when (buffer-live-p buffer)
    (let ((h (buffer-local-value 'drgnx-agent-companion--header buffer)))
      (when (buffer-live-p h) (drgnx-agent-panel-background--patch-elapsed h (float-time))))
    (drgnx-agent-panel-background--tick-sync buffer)))

(defun drgnx-agent-panel-background--tick-sync (buffer)
  "One timer for panel BUFFER while it is shown and an item runs; none otherwise."
  (let ((key (cons 'drgnx-bg-elapsed buffer)))
    (if (and (buffer-live-p buffer)
             (drgnx-agent-panel-background--visible-p buffer)
             (drgnx-agent-panel-background--running-p buffer))
        (unless (drgnx-timer-active-p key)
          (drgnx-timer-start key 1 #'drgnx-agent-panel-background--tick :repeat 1 :args (list buffer) :owner buffer))
      (drgnx-timer-cancel key))))

;;;; Ends: the status bar and the desktop

(defvar drgnx-agent-panel-background--status nil
  "(SESSION . TEXT) of the ends nobody saw, newest first: the status bar's agent item shows the first.")

(defvar drgnx-agent-panel-background--noted (make-hash-table :test #'eq :weakness 'key)
  "Mirror → the ids of the ended items it has told about (the first snapshot's are history, not news).")

(defun drgnx-agent-panel-background--chat-visible-p (sid)
  "Whether a window shows the chat SID."
  (when-let* ((b (gethash sid drgnx-agent-panel--by-session)))
    (and (buffer-live-p b) (drgnx-agent-panel-background--visible-p b))))

(defun drgnx-agent-panel-background--end-words (item)
  "(WORD . EXIT) of ITEM's end: `failed', `finished' or `stopped', and its exit code."
  (let ((e (plist-get item :end)))
    (let ((word (pcase (plist-get e :status) ("failed" "failed") ("stopped" "stopped") (_ "finished"))))
      (cons word (and (equal word "failed") (plist-get e :exit_code))))))

(defun drgnx-agent-panel-background--ended (s item)
  "ITEM of mirror S ended: the status bar says so while the chat is not on screen; the desktop route may send it."
  (let* ((sid (drgnx-agent-session-remote s)) (desc (or (plist-get item :description) "background work"))
         (words (drgnx-agent-panel-background--end-words item))
         (word (car words)) (code (cdr words)))
    (unless (equal word "stopped")
      (unless (drgnx-agent-panel-background--chat-visible-p sid)
        (push (cons sid (format "AGENT: %s %s%s" desc word (if code (format " (exit %s)" code) "")))
              drgnx-agent-panel-background--status)
        (when (fboundp 'drgnx-statusbar-refresh) (drgnx-statusbar-refresh t)))
      (when (fboundp 'drgnx-notice-desktop-take)
        (let ((mins (max 1 (round (/ (- (float-time) (/ (or (plist-get item :started_ms) 0) 1000.0)) 60)))))
          (drgnx-notice-desktop-take
           (list :id (list 'agent-background sid (plist-get item :id)) :source 'agents
                 :desktop-title (format "%s %s" desc word)
                 :text (format "%s (%s)%s after %d min" (drgnx-agent-session-name s) (drgnx-agent-session-profile s)
                               (if code (format " · exit %s" code) (format " · %s" word)) mins))))))))

(defun drgnx-agent-panel-background--note-snapshot (s)
  "`drgnx-agents-background-functions': mirror S has a new snapshot: each ended item not told before is news."
  (let ((ended (drgnx-agent-session-background-ended s)) (seen (gethash s drgnx-agent-panel-background--noted 'none)))
    (if (eq seen 'none)
        (puthash s (mapcar (lambda (i) (plist-get i :id)) ended) drgnx-agent-panel-background--noted)
      (dolist (i ended)
        (unless (member (plist-get i :id) seen)
          (push (plist-get i :id) seen)
          (drgnx-agent-panel-background--ended s i)))
      (puthash s seen drgnx-agent-panel-background--noted))))

(defun drgnx-agent-panel-background--snapshot (s)
  "A new snapshot of mirror S: its ends, and the timer of its panel."
  (drgnx-agent-panel-background--note-snapshot s)
  (when-let* ((b (gethash (drgnx-agent-session-remote s) drgnx-agent-panel--by-session)))
    (when (buffer-live-p b) (drgnx-agent-panel-background--tick-sync b))))

(defun drgnx-agent-panel-background--segment ()
  "The status bar's `agent-ended' segment: the newest end nobody saw."
  (cdr (car drgnx-agent-panel-background--status)))

(defun drgnx-agent-panel-background--chat-shown (sid)
  "Chat SID is on screen: what its ends said goes."
  (when (assoc sid drgnx-agent-panel-background--status)
    (setq drgnx-agent-panel-background--status (assoc-delete-all sid drgnx-agent-panel-background--status))
    (when (fboundp 'drgnx-statusbar-refresh) (drgnx-statusbar-refresh t))))

(defun drgnx-agent-panel-background--click ()
  "A click on the segment: the chat whose end it tells."
  (interactive)
  (when-let* ((sid (car (car drgnx-agent-panel-background--status))))
    (drgnx-agent-panel-background--chat-shown sid)
    (drgnx-agent-panel-open sid)))

(defun drgnx-agent-panel-background--windows (frame)
  "`window-buffer-change-functions': a chat shown in FRAME is seen (its ends go), and its timer may start."
  (dolist (w (window-list frame 'nomini))
    (let ((b (window-buffer w)))
      (when (and (buffer-live-p b) (eq (buffer-local-value 'major-mode b) 'drgnx-agent-panel-mode))
        (when-let* ((sid (buffer-local-value 'drgnx-agent-panel--session b)))
          (drgnx-agent-panel-background--chat-shown sid)
          (drgnx-agent-panel-background--tick-sync b))))))

;;;; The selected item's ring: one rounded block ring over both its lines (Glitnir's `glitnir-blocks')

(defvar-local drgnx-agent-panel-background--block nil
  "The ring block last given to the windows of the header (`glitnir-blocks'), or nil.")

(defun drgnx-agent-panel-background--rows-of (id)
  "(FROM . TO) of the rows of item ID in the current buffer: FROM the start of the first, TO the start of the line
after the last; nil when there is none."
  (save-excursion
    (goto-char (point-min))
    (let (from to)
      (while (not (eobp))
        (if (equal (get-text-property (line-beginning-position) 'drgnx-bg-item) id)
            (progn (unless from (setq from (line-beginning-position)))
                   (setq to (min (point-max) (1+ (line-end-position)))))
          (when from (goto-char (point-max))))          ; one item's rows are together
        (forward-line 1))
      (and from (cons from to)))))

(defun drgnx-agent-panel-background--unblock (&optional buffer)
  "Drop the ring from the windows that have it (the header's own, BUFFER's)."
  (with-current-buffer (or buffer (current-buffer))
    (when drgnx-agent-panel-background--block
      (let ((block drgnx-agent-panel-background--block))
        (dolist (w (window-list nil 'nomini))
          (when (eq (window-parameter w 'glitnir-blocks) block) (set-window-parameter w 'glitnir-blocks nil)))
        (set-marker (nth 1 (car block)) nil) (set-marker (nth 2 (car block)) nil)
        (setq drgnx-agent-panel-background--block nil)))))

(defun drgnx-agent-panel-background--blocks (&rest _)
  "`drgnx-view-sja-drawn-functions' of the header: the selected item's two rows get one rounded ring in the focus
colour, inset from the card's edge, over the selection's tint (its corners show the colour under it)."
  (let* ((sel (buffer-local-value 'drgnx-agent-panel--bg-selected (drgnx-agent-panel-background--main)))
         (rows (and sel (drgnx-agent-panel-background--rows-of sel)))
         (windows (get-buffer-window-list (current-buffer) nil t)))
    (drgnx-agent-panel-background--unblock)
    (when (and rows windows)
      (setq drgnx-agent-panel-background--block
            (list `(ring ,(copy-marker (car rows)) ,(copy-marker (cdr rows) t)
                         :x0 ,(drgnx-px 4) :x1 ,(max (drgnx-px 8) (- (window-body-width (car windows) t) (drgnx-px 4)))
                         :radius ,(drgnx-px 6) :ring drgnx-focus-line :beneath default)))
      (dolist (w windows) (set-window-parameter w 'glitnir-blocks drgnx-agent-panel-background--block)))))

;;;; Setup

(defun drgnx-agent-panel-background-setup ()
  "The commands and the status bar's segment; the hooks are the module's (drgnx-agent-panel.el)."
  (drgnx-command-define 'agents-background-list :category "Agents" :title "Background Work: Show or Fold the List"
                        :command #'drgnx-agent-panel-background-list :map 'drgnx-agent-panel-mode-map
                        :doc "Fold or unfold the list of what this chat runs in the background")
  (drgnx-command-define 'agents-background-stop :category "Agents" :title "Background Work: Stop"
                        :command #'drgnx-agent-panel-background-stop :map 'drgnx-agent-panel-mode-map
                        :doc "Stop the background item at point, where its agent lets a client stop it")
  (drgnx-command-define 'agents-background-stop-all :category "Agents" :title "Background Work: Stop All"
                        :command #'drgnx-agent-panel-background-stop-all
                        :doc "Stop everything this chat runs in the background, after listing it")
  (drgnx-command-define 'agents-background-output :category "Agents" :title "Background Work: Output"
                        :command #'drgnx-agent-panel-background-output :map 'drgnx-agent-panel-mode-map
                        :doc "The output of the background item at point; a subagent opens its own panel")
  (drgnx-command-define 'agents-end :category "Agents" :title "End This Chat"
                        :command #'drgnx-agent-panel-end :map 'drgnx-agent-panel-mode-map
                        :doc "End this chat's agent; asks first while it runs background work")
  (when (fboundp 'drgnx-statusbar-define-segment)
    (drgnx-statusbar-define-segment 'agent-ended :fn #'drgnx-agent-panel-background--segment
                                    :click #'drgnx-agent-panel-background--click
                                    :help "A background item of an agent ended; click for the chat")))

(defun drgnx-agent-panel-background-teardown ()
  "The module goes: the timers of the panels' elapsed cells, and what the ends said."
  (setq drgnx-agent-panel-background--status nil)
  (dolist (b (buffer-list))
    (when (eq (buffer-local-value 'major-mode b) 'drgnx-agent-panel-mode)
      (drgnx-timer-cancel (cons 'drgnx-bg-elapsed b)))))

(provide 'drgnx-agent-panel-background)
;;; drgnx-agent-panel-background.el ends here
