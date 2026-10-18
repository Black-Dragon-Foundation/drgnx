;;; drgnx-cockpit-feed.el --- Module tools/cockpit: what happened, questions everywhere, the timeline -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The Work cockpit's feed, in place of the long transcript: per agent, "what happened" — one line per event
;; (`drgnx-cockpit-happened': decisions, edits with file counts, tests `12/12 ✓', questions, reviews), each a button
;; to its target, the full transcript one click away and a reply field that queues — and the timeline: one row per
;; agent, chips left to right by time, the newest shown, the older ones one click away.  A question waiting on you is
;; marked ◐ (`drgnx-cockpit-waiting') in both, in the graph (drgnx-cockpit.el) and, through
;; `drgnx-cockpit-waiting-count', in the status bar.  `drgnx-cockpit-answer' (A) answers it from any of them: queued
;; to its agent, never interrupting it, and an `answer' event closes it.
;; The feed's buffers follow the store as the graph does — hub events and a look every
;; `drgnx-cockpit-check-interval' s, at most one update per `drgnx-cockpit-redraw-delay', only while one shows, and
;; nothing when the store did not change — and an update only appends lines and chips (a row is one line, patched).
;; It never prompts on an automatic path.  This file is loaded by drgnx-cockpit.el.  See docs/guide/cockpit.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'button)
(require 'text-property-search)
(require 'drgnx-cockpit-model)
(eval-when-compile (require 'drgnx-agents))     ; its session struct's places (`cl-letf' of a mode)

(declare-function drgnx-cockpit--db-key "drgnx-cockpit")
(declare-function drgnx-cockpit--targeter "drgnx-cockpit-model")
(declare-function drgnx-cockpit-graph--glyph-table "drgnx-cockpit-graph")
(declare-function drgnx-cockpit-graph--ascii-p "drgnx-cockpit-graph")
(declare-function drgnx-cockpit-graph-buffer "drgnx-cockpit")
(declare-function drgnx-cockpit-schedule "drgnx-cockpit")
(declare-function drgnx-cockpit-sessions "drgnx-cockpit")
(declare-function drgnx-cockpit--shown-node "drgnx-cockpit")
(declare-function drgnx-cockpit--open-file "drgnx-cockpit")
(declare-function drgnx-cockpit--call "drgnx-cockpit")
(declare-function drgnx-pane-kind "drgnx-panes")
(declare-function drgnx-pane-show "drgnx-panes")
(declare-function drgnx-pane-define-kind "drgnx-panes")
(declare-function drgnx-command-define "drgnx-registry")
(declare-function drgnx-agents-sessions "drgnx-agents")
(declare-function drgnx-agents-send "drgnx-agents")
(declare-function drgnx-agents-ui-transcript "drgnx-agents-ui")
(declare-function drgnx-agent-session-remote "drgnx-agents")
(declare-function drgnx-agent-session-id "drgnx-agents")
(declare-function drgnx-agent-session-mode "drgnx-agents")
(declare-function drgnx-agent-session-status "drgnx-agents")
(declare-function drgnx-hub-call "drgnx-hub")
(declare-function drgnx-statusbar-refresh "drgnx-statusbar")
(defvar drgnx-cockpit-graph-mode-map)
(defvar drgnx-cockpit-graph-buffer-name)
(defvar drgnx-cockpit-open-functions)
(defvar drgnx-cockpit-redraw-delay)
(defvar drgnx-cockpit-check-interval)
(defvar drgnx-cockpit--quiet-events)
(defvar drgnx-cockpit--silent)
(defvar drgnx-cockpit--svg)
(defvar drgnx-cockpit--selected)
(defvar drgnx-cockpit--model)

(defcustom drgnx-cockpit-timeline-name-width 14
  "Columns the timeline gives an agent's name, before its chips."
  :type 'natnum :group 'drgnx-cockpit)

(defface drgnx-cockpit-chip '((t))
  "A chip of the timeline (no look of its own: set one to make chips stand apart).  A question waiting on you is in
`drgnx-cockpit-waiting', a failure in `drgnx-cockpit-blocked'."
  :group 'drgnx-cockpit)

(defvar drgnx-cockpit-feed--buffers nil "The feed's live buffers (what happened, the timeline): they own its hooks.")
(defvar drgnx-cockpit-feed--timer nil "The update on its way: one at a time.")
(defvar drgnx-cockpit-feed--check-timer nil "The repeating look at the store, while a feed buffer lives.")
(defvar drgnx-cockpit-feed--waiting nil
  "(KEY QUESTIONS . TOTAL): `drgnx-cockpit-feed--waiting-pair' for the store at KEY.")
(defvar drgnx-cockpit-feed--told nil "The waiting count the status bar was last told of (`drgnx-cockpit-feed-tell-statusbar').")
(defvar drgnx-cockpit-feed--in-flight nil
  "The questions whose answer is on its way to the hub: ((QUESTION . SENT-AT)…), QUESTION an event id or (card . ID).
A second answer is refused until the hub answers, the call fails, or `drgnx-cockpit-feed-in-flight-timeout' passes
\(a hub that went away never answers); entries that old are dropped whenever one is added.")

(defvar drgnx-cockpit-feed-in-flight-timeout 30
  "Seconds after which an answer still on its way to the hub no longer blocks a second one.")

(defvar drgnx-cockpit-feed--questions-now nil
  "While an update runs: a box (READ . QUESTIONS), so that its buffers and the waiting count read the open questions
once (`drgnx-cockpit-feed--open-questions'); nil outside an update.")

(defvar-local drgnx-cockpit-feed--key nil
  "The feed's key (`drgnx-cockpit-feed--key-now') at this buffer's last successful update.")
(defvar-local drgnx-cockpit-feed--stale nil "Something may have changed while this buffer was hidden: it updates when shown.")
(defvar-local drgnx-cockpit-feed--agent nil "What happened: the agent it shows.")
(defvar-local drgnx-cockpit-feed--last 0 "The newest event this buffer shows (its id).")
(defvar-local drgnx-cockpit-feed--end nil "What happened: a marker where the event lines end (the transcript and reply lines follow).")
(defvar-local drgnx-cockpit-feed--lines 0 "What happened: how many event lines it shows.")
(defvar-local drgnx-cockpit-feed--asking nil "The open questions (event ids) this buffer shows marked: calmed when answered.")
(defvar-local drgnx-cockpit-feed--footer nil "What happened: what its last lines were drawn for (`drgnx-cockpit-feed--footer-key').")
(defvar-local drgnx-cockpit-feed--rows nil
  "The timeline's rows, top to bottom: each (KEY NAME CHIPS SHOWN), CHIPS newest first, SHOWN the waiting question ids
its line marks.  Row I is the buffer's line I + 2 (the first line is the head).")
(defvar-local drgnx-cockpit-feed--fit nil
  "What this buffer was fitted to (`drgnx-cockpit-feed--fit-now'): the timeline's width, What happened's line count.")
(defvar-local drgnx-cockpit-feed--head nil "The timeline: its first line as drawn.")
(defvar-local drgnx-cockpit-feed--old nil
  "The timeline: the open questions whose events are older than every chip it holds, as chips, newest first (pinned
in their agents' rows).")
(defvar-local drgnx-cockpit-feed--cards nil
  "The timeline: the open ask cards no open question names, as chips of the `jobs' row (pinned, waiting).")

;;;; Text: glyphs, buttons

(defconst drgnx-cockpit-feed--ascii-glyphs
  '(("✓" . "+") ("⚠" . "!") ("…" . "...") ("—" . "-") ("▸" . ">") ("‹" . "<") ("◐" . "?") ("·" . "|"))
  "What a terminal that does not write UTF-8 shows for the feed's glyphs (the graph's own come from its table).")

(defconst drgnx-cockpit-feed--ascii-regexp (regexp-opt (mapcar #'car drgnx-cockpit-feed--ascii-glyphs))
  "Any of `drgnx-cockpit-feed--ascii-glyphs'.")

(defun drgnx-cockpit-feed--glyphs (text)
  "TEXT for the selected frame: its glyphs in ASCII on a terminal that does not write UTF-8."
  (if (drgnx-cockpit-graph--ascii-p)
      (replace-regexp-in-string drgnx-cockpit-feed--ascii-regexp
                                (lambda (g) (cdr (assoc g drgnx-cockpit-feed--ascii-glyphs))) text t t)
    text))

(defun drgnx-cockpit-feed--waiting-mark () (alist-get 'waiting (drgnx-cockpit-graph--glyph-table)))

(defun drgnx-cockpit-feed--button (text action &rest props)
  "TEXT as a button that calls ACTION with the button's position; PROPS are its other properties (face, help-echo…)."
  (apply #'make-text-button (copy-sequence text) nil 'action action 'follow-link t
         (append props (unless (plist-member props 'face) (list 'face nil)))))

(defun drgnx-cockpit-feed--replace-line (n text)
  "Make line N of the current buffer TEXT, faces and all.  Only what differs is replaced (`replace-buffer-contents'),
so point and every window's point and start stay where they were in the text that stays: no window is touched."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- n))
    (let ((beg (point)) (end (line-end-position)) (buf (current-buffer)) (inhibit-read-only t))
      (unless (equal-including-properties (buffer-substring beg end) text)
        (with-temp-buffer
          (insert text)
          (let ((src (current-buffer)))
            (with-current-buffer buf
              (save-restriction
                (narrow-to-region beg end)
                (replace-buffer-contents src)
                ;; the same characters may come with other properties (a question calmed)
                (set-text-properties (point-min) (point-max) nil)
                (pcase-dolist (`(,s ,e ,props) (object-intervals text))
                  (set-text-properties (+ (point-min) s) (+ (point-min) e) props))))))))))

;;;; Following the store

(defun drgnx-cockpit-feed--key-now ()
  "(DB-KEY SESSIONS): the store's `drgnx-cockpit--db-key' (one query) and the ids of the sessions in this Emacs (their
transcript links).  It changes when this Emacs or another process writes the store, or a session comes or goes."
  (list (drgnx-cockpit--db-key)
        (and (fboundp 'drgnx-agents-sessions)
             (mapcar (lambda (s) (or (drgnx-agent-session-remote s) (drgnx-agent-session-id s))) (drgnx-agents-sessions)))))

(defun drgnx-cockpit-feed--watch ()
  "Follow the store while a feed buffer lives: hub events, agent sessions and a look every
`drgnx-cockpit-check-interval' s (idempotent)."
  (add-hook 'drgnx-hub-event-functions #'drgnx-cockpit-feed--hub-event)
  (add-hook 'drgnx-agents-changed-functions #'drgnx-cockpit-feed--agent-changed)
  (unless (timerp drgnx-cockpit-feed--check-timer)
    (setq drgnx-cockpit-feed--check-timer
          (run-with-timer drgnx-cockpit-check-interval drgnx-cockpit-check-interval #'drgnx-cockpit-feed--check))))

(defun drgnx-cockpit-feed--unwatch ()
  "A feed buffer is killed (its `kill-buffer-hook'): release its marker; the last one takes the hooks and timers."
  (when (markerp drgnx-cockpit-feed--end) (set-marker drgnx-cockpit-feed--end nil))
  (setq drgnx-cockpit-feed--buffers (delq (current-buffer) (seq-filter #'buffer-live-p drgnx-cockpit-feed--buffers)))
  (unless drgnx-cockpit-feed--buffers
    (remove-hook 'drgnx-hub-event-functions #'drgnx-cockpit-feed--hub-event)
    (remove-hook 'drgnx-agents-changed-functions #'drgnx-cockpit-feed--agent-changed)
    (dolist (tm (list drgnx-cockpit-feed--timer drgnx-cockpit-feed--check-timer)) (when (timerp tm) (cancel-timer tm)))
    (setq drgnx-cockpit-feed--timer nil drgnx-cockpit-feed--check-timer nil)))

(defun drgnx-cockpit-feed--hub-event (event _data)
  "`drgnx-hub-event-functions': a job, a card, an agent or a lease changed — the feed updates soon."
  (unless (member event drgnx-cockpit--quiet-events) (drgnx-cockpit-feed-schedule)))

(defun drgnx-cockpit-feed--agent-changed (_session)
  "`drgnx-agents-changed-functions' (also every transcript chunk): a session may have come or gone.  The update's key
holds only the sessions' ids, so a chunk costs one comparison."
  (drgnx-cockpit-feed-schedule))

(defun drgnx-cockpit-feed--visible ()
  "The feed buffers that show in a window of a visible frame."
  (seq-filter (lambda (b) (get-buffer-window b 'visible)) drgnx-cockpit-feed--buffers))

(defun drgnx-cockpit-feed--check ()
  "Every `drgnx-cockpit-check-interval' s while a feed buffer lives (a timer): the status bar hears of a new waiting
count (`drgnx-cockpit-feed-tell-statusbar'); when a feed buffer shows and the store changed since its update
\(another process wrote it), update soon."
  (drgnx-cockpit--call #'drgnx-cockpit-feed-tell-statusbar)
  (when-let* ((shown (drgnx-cockpit-feed--visible)))
    (drgnx-cockpit--call
     (lambda ()
       (let ((key (drgnx-cockpit-feed--key-now)))
         (unless (seq-every-p (lambda (b) (equal key (buffer-local-value 'drgnx-cockpit-feed--key b))) shown)
           (drgnx-cockpit-feed-schedule)))))))

(defun drgnx-cockpit-feed-schedule (&optional delay)
  "Update the feed's buffers within DELAY seconds (`drgnx-cockpit-redraw-delay'): one update however many calls come
meanwhile, only while one shows (a hidden one updates when it shows).  Cheap: called from every event."
  (when drgnx-cockpit-feed--buffers
    (if (not (drgnx-cockpit-feed--visible))
        (dolist (b drgnx-cockpit-feed--buffers) (with-current-buffer b (setq drgnx-cockpit-feed--stale t)))
      (unless (timerp drgnx-cockpit-feed--timer)
        (setq drgnx-cockpit-feed--timer
              (run-at-time (or delay drgnx-cockpit-redraw-delay) nil #'drgnx-cockpit-feed--tick))))))

(defun drgnx-cockpit-feed--tick ()
  "The scheduled update (a timer): each shown feed buffer appends what is new; a hidden one is marked stale."
  (setq drgnx-cockpit-feed--timer nil)
  (drgnx-cockpit--call
   (lambda ()
     (let ((key (drgnx-cockpit-feed--key-now)) (open nil) (open-known nil)
           (drgnx-cockpit-feed--questions-now (cons nil nil)))
       (dolist (b drgnx-cockpit-feed--buffers)
         (with-current-buffer b
           (cond ((not (get-buffer-window b 'visible)) (setq drgnx-cockpit-feed--stale t))
                 ((or (not (equal key drgnx-cockpit-feed--key)) (not (eql drgnx-cockpit-feed--fit (drgnx-cockpit-feed--fit-now))))
                  (unless open-known (setq open (drgnx-cockpit-feed--open-ids) open-known t))
                  ;; one buffer's error leaves the others' update, and its own key, as it was: tried again next time
                  (drgnx-cockpit--call
                   (lambda ()
                     (if (derived-mode-p 'drgnx-cockpit-timeline-mode)
                         (drgnx-cockpit-feed--timeline-update open)
                       (drgnx-cockpit-feed--happened-update open))
                     (setq drgnx-cockpit-feed--key key drgnx-cockpit-feed--stale nil))))
                 (t (setq drgnx-cockpit-feed--stale nil)))))))))

(defun drgnx-cockpit-feed--on-show (window)
  "A feed pane shows in WINDOW: catch up with what changed while it was hidden (soon, never while showing it)."
  (when (buffer-local-value 'drgnx-cockpit-feed--stale (window-buffer window)) (drgnx-cockpit-feed-schedule 0)))

(defun drgnx-cockpit-feed--shown (&rest _)
  "A window started showing a feed buffer, or changed size: update (each fits its window, `drgnx-cockpit-feed--fit')."
  (drgnx-cockpit-feed-schedule 0))

(defun drgnx-cockpit-feed--fit-now ()
  "What the current feed buffer fits now: the timeline its widest window's width (else 80 columns), What happened
as many lines as its tallest window shows below its head and above its last lines (else
`drgnx-cockpit-happened-limit'), so that the newest is always in view and an update writes only below point."
  (let ((ws (get-buffer-window-list (current-buffer) nil t)))
    (if (derived-mode-p 'drgnx-cockpit-timeline-mode)
        (if ws (apply #'max (mapcar #'window-body-width ws)) 80)
      (if ws (max 3 (min drgnx-cockpit-happened-limit (- (apply #'max (mapcar #'window-body-height ws)) 4)))
        drgnx-cockpit-happened-limit))))

(defun drgnx-cockpit-feed--open-questions ()
  "The open questions (`drgnx-coord-open-questions'), read once per update (`drgnx-cockpit-feed--questions-now')."
  (let ((box drgnx-cockpit-feed--questions-now))
    (cond ((null box) (drgnx-coord-open-questions))
          ((car box) (cdr box))
          (t (setcdr box (drgnx-coord-open-questions)) (setcar box t) (cdr box)))))

(defun drgnx-cockpit-feed--open-ids ()
  "The open questions' event ids."
  (delq nil (mapcar (lambda (q) (plist-get q :id)) (drgnx-cockpit-feed--open-questions))))

;;;; The modes

(defvar drgnx-cockpit-map
  (let ((m (make-sparse-keymap))) (set-keymap-parent m special-mode-map) m)
  "Keys of every cockpit buffer — the graph, what happened, the timeline (from the key profiles: A answers).")

(defvar drgnx-cockpit-happened-mode-map (let ((m (make-sparse-keymap))) (set-keymap-parent m drgnx-cockpit-map) m)
  "What happened's keys: A answers; RET or a click follows a line.")

(defvar drgnx-cockpit-timeline-mode-map (let ((m (make-sparse-keymap))) (set-keymap-parent m drgnx-cockpit-map) m)
  "The timeline's keys: A answers; RET or a click follows a chip.")

(defun drgnx-cockpit-feed--setup-buffer ()
  "What both feed modes do: a generated, read-only buffer that owns the feed's hooks while it lives."
  (setq truncate-lines t buffer-read-only t)
  (buffer-disable-undo)
  (setq-local revert-buffer-function #'drgnx-cockpit-feed--revert)
  (add-hook 'window-buffer-change-functions #'drgnx-cockpit-feed--shown nil t)
  (add-hook 'window-size-change-functions #'drgnx-cockpit-feed--shown nil t)
  (add-hook 'kill-buffer-hook #'drgnx-cockpit-feed--unwatch nil t)
  (cl-pushnew (current-buffer) drgnx-cockpit-feed--buffers)
  (drgnx-cockpit-feed--watch))

(define-derived-mode drgnx-cockpit-happened-mode special-mode "What happened"
  "What one agent did, one line per event (docs/guide/cockpit.md)."
  (drgnx-cockpit-feed--setup-buffer))

(define-derived-mode drgnx-cockpit-timeline-mode special-mode "Timeline"
  "Every agent's events as chips, one row per agent (docs/guide/cockpit.md)."
  (drgnx-cockpit-feed--setup-buffer))

(with-eval-after-load 'evil                     ; their own letters, also in the Vim profile
  (when (fboundp 'evil-set-initial-state)
    (dolist (m '(drgnx-cockpit-happened-mode drgnx-cockpit-timeline-mode)) (evil-set-initial-state m 'emacs))))

(defun drgnx-cockpit-feed--revert (&rest _)
  "g: draw the buffer anew from the store."
  (if (derived-mode-p 'drgnx-cockpit-timeline-mode) (drgnx-cockpit-feed--timeline-build)
    (drgnx-cockpit-feed--happened-build)))

;;;; Following a target

(defun drgnx-cockpit-feed--node (id)
  "Node ID as the graph shows it, else as the store has it now (a command: it may read the store)."
  (or (drgnx-cockpit--shown-node id)
      (seq-find (lambda (n) (equal (plist-get n :id) id))
                (plist-get (drgnx-cockpit-model :sessions (drgnx-cockpit-sessions) :silent drgnx-cockpit--silent) :nodes))))

(defun drgnx-cockpit-feed-open-target (target)
  "Open TARGET (:node ID :event ID) of a line or a chip: its node's tab, as the graph opens it
\(`drgnx-cockpit-open-functions')."
  (let ((node (and (plist-get target :node) (drgnx-cockpit-feed--node (plist-get target :node)))))
    (if node (funcall (or (alist-get (plist-get node :kind) drgnx-cockpit-open-functions) #'drgnx-cockpit--open-file) node)
      (message "Work cockpit: %s is no longer in the work" (or (plist-get target :node) "that event's target")))))

(defun drgnx-cockpit-feed--follow (pos)
  "The button at POS was pushed: open its target."
  (drgnx-cockpit-feed-open-target (get-text-property pos 'drgnx-cockpit-target)))

;;;; What happened

(defun drgnx-cockpit-feed--session (agent)
  "AGENT's session in this Emacs (its own or a mirror of the hub's), or nil."
  (and agent (fboundp 'drgnx-agents-sessions)
       (seq-find (lambda (s) (equal (or (drgnx-agent-session-remote s) (drgnx-agent-session-id s)) agent))
                 (drgnx-agents-sessions))))

(defun drgnx-cockpit-feed--outside-p (agent)
  "Whether AGENT is an agent outside drgnx (an `ext:' id, or registered with a kind) with no session here."
  (and (stringp agent) (not (drgnx-cockpit-feed--session agent))
       (or (string-prefix-p "ext:" agent) (and (plist-get (drgnx-coord-agent agent) :kind) t))))

(defun drgnx-cockpit-feed--name (agent)
  "AGENT's name: its session's, else its registered one, else its id."
  (or (plist-get (seq-find (lambda (s) (equal (plist-get s :id) agent)) (drgnx-cockpit-sessions)) :name)
      (plist-get (drgnx-coord-agent agent) :name)
      agent))

(defun drgnx-cockpit-feed-happened-buffer (agent)
  "AGENT's \"what happened\" buffer, `*happened: AGENT*', made and drawn the first time; it then follows the store."
  (let ((name (format "*happened: %s*" agent)))
    (or (get-buffer name)
        (with-current-buffer (get-buffer-create name)
          (drgnx-cockpit-happened-mode)
          (setq drgnx-cockpit-feed--agent agent)
          (drgnx-cockpit-feed--happened-build)
          (current-buffer)))))

(defun drgnx-cockpit-feed--line-text (l open)
  "Line L of `drgnx-cockpit-happened' as text: its time, then its text — a question still OPEN (ids) marked and in
`drgnx-cockpit-waiting' — a button to its target."
  (let* ((eid (plist-get (plist-get l :target) :event))
         (question (and (equal (plist-get l :kind) "question") eid))
         (waiting (and question (memql eid open)))
         (text (drgnx-cockpit-feed--glyphs (plist-get l :text))))
    (propertize
     (concat (propertize (format-time-string "%H:%M" (plist-get l :at)) 'face 'drgnx-cockpit-edge) "  "
             (drgnx-cockpit-feed--button (if waiting (concat (drgnx-cockpit-feed--waiting-mark) " " text) text)
                                         #'drgnx-cockpit-feed--follow
                                         'face (and waiting 'drgnx-cockpit-waiting)
                                         'drgnx-cockpit-target (plist-get l :target)
                                         'help-echo (format-time-string "%F %T — RET or a click opens it" (plist-get l :at))))
     'drgnx-cockpit-event eid 'drgnx-cockpit-question question)))

(defun drgnx-cockpit-feed--footer-key (agent)
  "What the last lines of AGENT's buffer say: `session' (its transcript is here), `silent' (a worktree nobody
reports from), `outside' or `none'."
  (cond ((drgnx-cockpit-feed--session agent) 'session)
        ((and (stringp agent) (string-prefix-p "silent:" agent)) 'silent)
        ((drgnx-cockpit-feed--outside-p agent) 'outside)
        (t 'none)))

(defun drgnx-cockpit-feed--footer-text (agent kind)
  "The last lines of AGENT's buffer for KIND (`drgnx-cockpit-feed--footer-key'): the transcript, the reply field."
  (concat "\n"
          (pcase kind
            ('session (drgnx-cockpit-feed--button (drgnx-cockpit-feed--glyphs "Open the full transcript ▸")
                                                  (lambda (_) (drgnx-cockpit-feed--transcript agent))
                                                  'help-echo "Every message, tool call and permission of this agent"))
            ('outside (propertize "no transcript: an outside agent" 'face 'drgnx-cockpit-edge))
            ('silent (propertize (drgnx-cockpit-feed--glyphs "not reporting — add drgnx on its settings page") 'face 'drgnx-cockpit-edge))
            (_ (propertize "no transcript in this Emacs" 'face 'drgnx-cockpit-edge)))
          "\n"
          (drgnx-cockpit-feed--button (drgnx-cockpit-feed--glyphs "Reply… (queues, never interrupts)")
                                      (lambda (_) (call-interactively #'drgnx-cockpit-feed-reply))
                                      'help-echo "Answers its open question, else a message it gets when its turn ends")
          "\n"))

(defun drgnx-cockpit-feed--transcript (agent)
  "Open AGENT's transcript, when its session is here."
  (if-let* ((s (drgnx-cockpit-feed--session agent)) ((fboundp 'drgnx-agents-ui-transcript)))
      (drgnx-agents-ui-transcript s)
    (message "Work cockpit: %s has no transcript in this Emacs" agent)))

(defun drgnx-cockpit-feed--happened-head (agent)
  "What happened's first line for AGENT: its name, then its oldest open question, marked, in `drgnx-cockpit-waiting'
— there however far its line has scrolled out (A answers it)."
  (let ((q (seq-find (lambda (q) (equal (plist-get q :agent) agent)) (drgnx-cockpit-feed--open-questions))))
    (concat (propertize (drgnx-cockpit-feed--glyphs (format "What happened: %s" (drgnx-cockpit-feed--name agent))) 'face 'drgnx-cockpit-kind)
            (if (null q) ""
              (concat (drgnx-cockpit-feed--glyphs " · ")
                      (propertize (drgnx-cockpit-feed--glyphs
                                   (format "%s asks you: %s" (drgnx-cockpit-feed--waiting-mark)
                                           (drgnx-cockpit--line (drgnx-cockpit--question-text (plist-get q :summary)) 120)))
                                  'face 'drgnx-cockpit-waiting 'drgnx-cockpit-question (plist-get q :id)
                                  'help-echo "A answers it (queued, never interrupting)"))))))

(defun drgnx-cockpit-feed--happened-build ()
  "Draw this \"what happened\" buffer anew: a head line, its agent's newest lines (as many as fit,
`drgnx-cockpit-feed--fit-now'), the transcript and reply lines; point on the head line."
  (let* ((key (drgnx-cockpit-feed--key-now))           ; first: what changes while it draws is drawn next time
         (agent drgnx-cockpit-feed--agent) (open (drgnx-cockpit-feed--open-ids)) (fit (drgnx-cockpit-feed--fit-now))
         (lines (last (drgnx-cockpit-happened agent) fit)) (inhibit-read-only t))
    (setq drgnx-cockpit-feed--fit fit)
    (erase-buffer)
    (insert (drgnx-cockpit-feed--happened-head agent) "\n")
    (dolist (l lines) (insert (drgnx-cockpit-feed--line-text l open) "\n"))
    (unless lines (insert (propertize "Nothing yet." 'face 'drgnx-cockpit-edge 'drgnx-cockpit-event 0) "\n"))
    (if (markerp drgnx-cockpit-feed--end) (set-marker drgnx-cockpit-feed--end (point)) (setq drgnx-cockpit-feed--end (point-marker)))
    (setq drgnx-cockpit-feed--footer (drgnx-cockpit-feed--footer-key agent)
          drgnx-cockpit-feed--last (or (plist-get (plist-get (car (last lines)) :target) :event) drgnx-cockpit-feed--last)
          drgnx-cockpit-feed--lines (length lines)
          drgnx-cockpit-feed--asking (seq-filter (lambda (id) (memql id open))
                                                 (delq nil (mapcar (lambda (l) (and (equal (plist-get l :kind) "question")
                                                                                    (plist-get (plist-get l :target) :event)))
                                                                   lines))))
    (insert (drgnx-cockpit-feed--footer-text agent drgnx-cockpit-feed--footer))
    (set-buffer-modified-p nil)
    (setq drgnx-cockpit-feed--key key drgnx-cockpit-feed--stale nil)
    ;; above every update: the windows' point and start never move (all of it fits, the newest in view)
    (goto-char (point-min))))

(defun drgnx-cockpit-feed--event-line (id)
  "The line number of event ID's line in this buffer, or nil."
  (save-excursion
    (goto-char (point-min))
    (when-let* ((m (text-property-search-forward 'drgnx-cockpit-event id t)))
      (line-number-at-pos (prop-match-beginning m)))))

(defun drgnx-cockpit-feed--happened-update (open)
  "Append the events that came since this buffer's last one (OPEN: the open questions' ids), calm the questions
answered since, keep as many lines as fit (the oldest go), and redo the last lines only when they changed.  A
window of another height: drawn anew."
  (let* ((agent drgnx-cockpit-feed--agent) (lines (drgnx-cockpit-happened agent))
         (n (length lines)) (now (drgnx-cockpit-feed--fit-now))
         (limit (if (= (min n now) (min n drgnx-cockpit-feed--fit)) (setq drgnx-cockpit-feed--fit now) drgnx-cockpit-feed--fit))
         (new (seq-filter (lambda (l) (> (or (plist-get (plist-get l :target) :event) 0) drgnx-cockpit-feed--last)) lines)))
    (if (or (not (eql limit now))                     ; another height that shows other lines
            (and new (>= (length new) drgnx-cockpit-happened-limit) (> drgnx-cockpit-feed--last 0)))
        (drgnx-cockpit-feed--happened-build)          ; resized, or more came than it reads: the whole of it
      (let ((inhibit-read-only t))
        (when new
          (when (zerop drgnx-cockpit-feed--lines)       ; "Nothing yet." goes
            (when-let* ((n (drgnx-cockpit-feed--event-line 0)))
              (save-excursion (goto-char (point-min)) (forward-line (1- n)) (delete-region (point) (progn (forward-line 1) (point))))))
          (save-excursion
            (goto-char drgnx-cockpit-feed--end)
            (dolist (l new) (insert (drgnx-cockpit-feed--line-text l open) "\n"))
            (set-marker drgnx-cockpit-feed--end (point)))
          (setq drgnx-cockpit-feed--last (plist-get (plist-get (car (last new)) :target) :event)
                drgnx-cockpit-feed--lines (+ drgnx-cockpit-feed--lines (length new)))
          (dolist (l new)
            (let ((id (plist-get (plist-get l :target) :event)))
              (when (and (equal (plist-get l :kind) "question") (memql id open)) (push id drgnx-cockpit-feed--asking)))))
        ;; questions answered since: their lines lose the mark
        (dolist (id (seq-remove (lambda (id) (memql id open)) drgnx-cockpit-feed--asking))
          (setq drgnx-cockpit-feed--asking (delq id drgnx-cockpit-feed--asking))
          (when-let* ((n (drgnx-cockpit-feed--event-line id))
                      (l (seq-find (lambda (l) (eql (plist-get (plist-get l :target) :event) id)) lines)))
            (drgnx-cockpit-feed--replace-line n (drgnx-cockpit-feed--line-text l open))))
        ;; at most LIMIT lines: the oldest go (below the head line, where point is)
        (when (> drgnx-cockpit-feed--lines limit)
          (save-excursion
            (goto-char (point-min))
            (forward-line 1)
            (delete-region (point) (progn (forward-line (- drgnx-cockpit-feed--lines limit)) (point))))
          (setq drgnx-cockpit-feed--lines limit))
        (drgnx-cockpit-feed--replace-line 1 (drgnx-cockpit-feed--happened-head agent))
        (let ((footer (drgnx-cockpit-feed--footer-key agent)))
          (unless (eq footer drgnx-cockpit-feed--footer)
            (setq drgnx-cockpit-feed--footer footer)
            (save-excursion
              (delete-region drgnx-cockpit-feed--end (point-max))
              (goto-char drgnx-cockpit-feed--end)
              (insert (drgnx-cockpit-feed--footer-text agent footer)))))
        (set-buffer-modified-p nil)))))

(defun drgnx-cockpit-happened-show (agent)
  "Show what AGENT did, one line per event, in the `happened' pane (beside the editor), and focus it."
  (interactive
   (let* ((agents (mapcar (lambda (a) (cons (format "%s (%s)" (or (plist-get a :name) (plist-get a :id)) (plist-get a :id))
                                            (plist-get a :id)))
                          (plist-get (drgnx-cockpit-model :sessions (drgnx-cockpit-sessions) :silent drgnx-cockpit--silent) :agents))))
     (unless agents (user-error "No agent has done anything yet"))
     (list (cdr (assoc (completing-read "What happened, for agent: " agents nil t) agents)))))
  (let ((b (drgnx-cockpit-feed-happened-buffer agent)))
    (if (drgnx-pane-kind 'happened) (drgnx-pane-show 'happened :buffer b :select t) (pop-to-buffer b))
    (drgnx-cockpit-feed-schedule 0)
    b))

(defun drgnx-cockpit-feed--happened-placeholder ()
  "The `happened' pane before an agent is picked."
  (or (get-buffer " *happened*")
      (with-current-buffer (get-buffer-create " *happened*" t)
        (special-mode)
        (let ((inhibit-read-only t))
          (insert "What happened: pick an agent — Show What Happened… (cockpit-happened), or an agent's name in the timeline.\n"))
        (current-buffer))))

;;;; The timeline

(defconst drgnx-cockpit-timeline-buffer-name "*Timeline*")

(defun drgnx-cockpit-timeline-buffer ()
  "The timeline's buffer, made and drawn the first time; it then follows the store."
  (or (get-buffer drgnx-cockpit-timeline-buffer-name)
      (with-current-buffer (get-buffer-create drgnx-cockpit-timeline-buffer-name)
        (drgnx-cockpit-timeline-mode)
        (drgnx-cockpit-feed--timeline-build)
        (current-buffer))))

(defun drgnx-cockpit-feed--row-key (chip)
  "The row of CHIP: its agent, \"user\" (your answers) or \"\" (jobs' events of no agent)."
  (or (plist-get chip :agent) ""))

(defun drgnx-cockpit-feed--row-name (key)
  (cond ((equal key "user") "you") ((equal key "") "jobs") (t (drgnx-cockpit-feed--name key))))

(defun drgnx-cockpit-feed--waiting-p (chip open)
  "Whether CHIP waits on you: an open ask card's, or a question still OPEN (ids)."
  (or (plist-get chip :card) (and (equal (plist-get chip :kind) "question") (memql (plist-get chip :id) open))))

(defun drgnx-cockpit-feed--mark (chip) (if (plist-get chip :card) (cons 'card (plist-get chip :card)) (plist-get chip :id)))

(defun drgnx-cockpit-feed--mark-open-p (mark open)
  "Whether MARK (`drgnx-cockpit-feed--mark') still waits: its question in OPEN (ids), its card still open."
  (if (consp mark) (seq-find (lambda (c) (eql (plist-get c :card) (cdr mark))) drgnx-cockpit-feed--cards) (memql mark open)))

(defun drgnx-cockpit-feed--failed-p (chip)
  "Whether CHIP tells of a failure, by its event's kind: tests with failures (the warning glyph or `N failed', which
only `drgnx-cockpit--tests' writes from their counts), a failing review verdict, a failed status."
  (let ((label (or (plist-get chip :label) "")))
    (pcase (plist-get chip :kind)
      ("test" (or (and (string-search (drgnx-cockpit--glyph 'warning "⚠") label) t) (string-match-p " failed\\'" label)))
      ("review" (string-match-p "review: \\(fail\\|critical\\|reject\\|changes\\)" label))
      ("status" (string-match-p " failed\\'" label)))))

(defun drgnx-cockpit-feed--chip-text (chip open)
  "CHIP as a button: one waiting on you (`drgnx-cockpit-feed--waiting-p', OPEN the open questions' ids) marked and in
`drgnx-cockpit-waiting', a failure in `drgnx-cockpit-blocked'."
  (let ((waiting (drgnx-cockpit-feed--waiting-p chip open))
        (label (drgnx-cockpit-feed--glyphs (plist-get chip :label))))
    (drgnx-cockpit-feed--button (if waiting (concat (drgnx-cockpit-feed--waiting-mark) " " label) label)
                                #'drgnx-cockpit-feed--follow
                                'face (cond (waiting 'drgnx-cockpit-waiting) ((drgnx-cockpit-feed--failed-p chip) 'drgnx-cockpit-blocked)
                                            (t 'drgnx-cockpit-chip))
                                'drgnx-cockpit-target (plist-get chip :target)
                                'drgnx-cockpit-event (plist-get chip :id)
                                'drgnx-cockpit-question (and (equal (plist-get chip :kind) "question") (plist-get chip :id))
                                'drgnx-cockpit-card (plist-get chip :card)
                                'help-echo (format "%s  %s — RET or a click opens it"
                                                   (format-time-string "%F %T" (plist-get chip :at)) (plist-get chip :label)))))

(defun drgnx-cockpit-feed--row-chips (key chips)
  "Row KEY's CHIPS (newest first), with the open ask cards for the `jobs' row (KEY \"\") first and its open
questions older than the chips it holds last (`drgnx-cockpit-feed--old')."
  (append (and (equal key "") (reverse drgnx-cockpit-feed--cards))
          chips
          (seq-filter (lambda (c) (equal (drgnx-cockpit-feed--row-key c) key)) drgnx-cockpit-feed--old)))

(defun drgnx-cockpit-feed--row-text (row width open)
  "ROW (KEY NAME CHIPS SHOWN) as one line narrower than WIDTH columns: its name, `‹ N' (the N chips not drawn, one
click away; `‹ N ◐' when one of them waits), the chips that wait on you whatever their age (OPEN: the open
questions' ids; the `jobs' row also gets the open ask cards), then as many of its newest other chips as fit, each
group oldest first.  Second value: the marks (`drgnx-cockpit-feed--mark') of the waiting chips it draws."
  (pcase-let* ((`(,key ,name ,chips . ,_) row)
               (chips (drgnx-cockpit-feed--row-chips key chips))
               (nw drgnx-cockpit-timeline-name-width)
               (mark (drgnx-cockpit-feed--waiting-mark))
               (label (truncate-string-to-width (drgnx-cockpit-feed--glyphs name) nw nil ?\s (drgnx-cockpit-feed--glyphs "…")))
               (head (if (member key '("" "user")) (propertize label 'face 'drgnx-cockpit-edge)
                       (drgnx-cockpit-feed--button label (lambda (_) (drgnx-cockpit-happened-show key))
                                                   'face 'drgnx-cockpit-kind 'help-echo "What this agent did, line by line")))
               (sep (alist-get 'sep (drgnx-cockpit-graph--glyph-table))) (sw (string-width sep))
               (pins (nreverse (seq-filter (lambda (c) (drgnx-cockpit-feed--waiting-p c open)) chips)))   ; oldest first
               (rest (seq-remove (lambda (c) (drgnx-cockpit-feed--waiting-p c open)) chips))              ; newest first
               ;; a terminal keeps the last column for its `$'
               (room (- width nw 2 (string-width (format "‹ %d %s " (length chips) mark))))
               (used 0) (shown-pins nil) (shown-rest nil) (marks nil))
    ;; the waiting ones first: newer chips make room for them
    (dolist (c pins)
      (let* ((text (drgnx-cockpit-feed--chip-text c open)) (w (+ (string-width text) (if shown-pins sw 0))))
        (when (or (null shown-pins) (<= (+ used w) room))
          (push text shown-pins) (push (drgnx-cockpit-feed--mark c) marks) (setq used (+ used w)))))
    (cl-loop for c in rest
             for text = (drgnx-cockpit-feed--chip-text c open)
             for w = (+ (string-width text) (if (or shown-pins shown-rest) sw 0))
             while (or (and (null shown-pins) (null shown-rest)) (<= (+ used w) room))
             do (push text shown-rest) (setq used (+ used w)))
    (let ((more (- (length chips) (length shown-pins) (length shown-rest)))
          (hidden-waiting (> (length pins) (length shown-pins))))
      (list (concat head " "
                    (if (> more 0)
                        (concat (drgnx-cockpit-feed--button (drgnx-cockpit-feed--glyphs
                                                             (if hidden-waiting (format "‹ %d %s" more mark) (format "‹ %d" more)))
                                                            (lambda (_) (drgnx-cockpit-feed--earlier key))
                                                            'face (if hidden-waiting 'drgnx-cockpit-waiting 'drgnx-cockpit-edge)
                                                            'help-echo "The older events of this row")
                                " ")
                      "")
                    (string-join (append (nreverse shown-pins) shown-rest) sep))
            marks))))

(defun drgnx-cockpit-feed--head-text (n)
  "The timeline's first line: what it is, and N questions waiting on you."
  (concat (propertize "Timeline" 'face 'drgnx-cockpit-kind)
          (propertize (drgnx-cockpit-feed--glyphs " · oldest left, newest right") 'face 'drgnx-cockpit-edge)
          (if (> n 0)
              (concat (drgnx-cockpit-feed--glyphs " · ")
                      (propertize (format "%s %d waiting on you" (drgnx-cockpit-feed--waiting-mark) n) 'face 'drgnx-cockpit-waiting))
            "")))

(defun drgnx-cockpit-feed--add-chips (chips)
  "Put CHIPS (oldest first) into their rows, at most `drgnx-cockpit-timeline-limit' per row: the keys of the rows
they reached, and of the rows they made (at the end, in order)."
  (let ((touched nil) (limit drgnx-cockpit-timeline-limit))
    (dolist (c chips)
      (let* ((key (drgnx-cockpit-feed--row-key c)) (row (assoc key drgnx-cockpit-feed--rows)))
        (unless row
          (setq row (list key (drgnx-cockpit-feed--row-name key) nil nil))
          (setq drgnx-cockpit-feed--rows (append drgnx-cockpit-feed--rows (list row))))
        (setf (nth 2 row) (let ((l (cons c (nth 2 row)))) (if (> (length l) limit) (seq-take l limit) l)))
        (cl-pushnew key touched :test #'equal)
        (setq drgnx-cockpit-feed--last (max drgnx-cockpit-feed--last (plist-get c :id)))))
    touched))

(defun drgnx-cockpit-feed--card-chips ()
  "The open ask cards no open question names (`drgnx-cockpit-feed--open-cards'), as waiting chips of the `jobs' row,
oldest first: `T3 asks you: TITLE', each a button to its task."
  (when-let* ((cards (drgnx-cockpit-feed--open-cards)))
    (let ((target (drgnx-cockpit--targeter)))
      (mapcar (lambda (c)
                (pcase-let ((`(,cid ,job ,task ,title ,at) c))
                  (list :id nil :card cid :at at :agent nil :kind "question"
                        :label (drgnx-cockpit--line (format "%s asks you: %s" (drgnx-cockpit--short-task (or task job)) title) 40)
                        :target (funcall target (list :job job :task task)))))
              cards))))

(defun drgnx-cockpit-feed--old-chips (open)
  "The open questions (OPEN: their ids) whose events none of the timeline's rows holds — older than the events it
read — as chips, newest first: one `id in (…)' query, none when every open question is held."
  (let ((held (make-hash-table)))
    (dolist (row drgnx-cockpit-feed--rows) (dolist (c (nth 2 row)) (puthash (plist-get c :id) t held)))
    (when-let* ((missing (seq-remove (lambda (id) (gethash id held)) open)))
      (let ((target (drgnx-cockpit--targeter)))
        (mapcar (lambda (e) (list :id (plist-get e :id) :at (plist-get e :at) :agent (plist-get e :agent) :kind (plist-get e :kind)
                                  :label (drgnx-cockpit--label e) :target (funcall target e)))
                (drgnx-cockpit--events (format "select %%s from event where id in (%s) order by id desc"
                                               (mapconcat (lambda (_) "?") missing ", "))
                                       missing))))))

(defun drgnx-cockpit-feed--ensure-rows ()
  "Rows for the pinned chips that have none yet: the `jobs' row for open ask cards, an agent's row for its old open
questions (`drgnx-cockpit-feed--old').  Their keys."
  (let ((made nil))
    (dolist (k (delete-dups (append (and drgnx-cockpit-feed--cards (list ""))
                                    (mapcar #'drgnx-cockpit-feed--row-key drgnx-cockpit-feed--old))))
      (unless (assoc k drgnx-cockpit-feed--rows)
        (setq drgnx-cockpit-feed--rows (append drgnx-cockpit-feed--rows (list (list k (drgnx-cockpit-feed--row-name k) nil nil))))
        (push k made)))
    made))

(defun drgnx-cockpit-feed--timeline-build ()
  "Draw the timeline anew from the store: a head line, then one line per agent."
  (let ((key (drgnx-cockpit-feed--key-now))            ; first: what changes while it draws is drawn next time
        (inhibit-read-only t) (open (drgnx-cockpit-feed--open-ids)))
    (setq drgnx-cockpit-feed--rows nil drgnx-cockpit-feed--last 0
          drgnx-cockpit-feed--cards (drgnx-cockpit-feed--card-chips)
          drgnx-cockpit-feed--fit (drgnx-cockpit-feed--fit-now))
    (drgnx-cockpit-feed--add-chips (drgnx-cockpit-timeline))
    (setq drgnx-cockpit-feed--old (drgnx-cockpit-feed--old-chips open))
    (drgnx-cockpit-feed--ensure-rows)
    (erase-buffer)
    (setq drgnx-cockpit-feed--head (drgnx-cockpit-feed--head-text (drgnx-cockpit-feed--head-count)))
    (insert drgnx-cockpit-feed--head "\n")
    (dolist (row drgnx-cockpit-feed--rows)
      (pcase-let ((`(,text ,marks) (drgnx-cockpit-feed--row-text row drgnx-cockpit-feed--fit open)))
        (setf (nth 3 row) marks)
        (insert text "\n")))
    (unless drgnx-cockpit-feed--rows (insert (propertize "Nothing yet: events show here as agents work." 'face 'drgnx-cockpit-edge) "\n"))
    (set-buffer-modified-p nil)
    (setq drgnx-cockpit-feed--key key drgnx-cockpit-feed--stale nil)
    (goto-char (point-min))))             ; above every update: the windows' point never moves

(defun drgnx-cockpit-feed--timeline-update (open)
  "Add the chips that came since the last one (OPEN: the open questions' ids): only the rows they reach, the rows
whose marked questions or cards were answered, the `jobs' row when the open ask cards changed, and the head are
drawn again — all rows when the window's width changed.  It reads at most `drgnx-cockpit-timeline-limit' (300)
events past its last chip: more between two updates (at most one per `drgnx-cockpit-redraw-delay', so over 600
events a second) leaves the older of them out of the rows until the timeline is drawn anew (g)."
  (if (null drgnx-cockpit-feed--rows)
      (drgnx-cockpit-feed--timeline-build)
    (let* ((width (drgnx-cockpit-feed--fit-now))
           (old (length drgnx-cockpit-feed--rows))
           (cards (drgnx-cockpit-feed--card-chips))
           (cards-changed (not (equal (mapcar #'drgnx-cockpit-feed--mark cards)
                                      (mapcar #'drgnx-cockpit-feed--mark drgnx-cockpit-feed--cards))))
           (touched (progn (setq drgnx-cockpit-feed--cards cards)
                           (drgnx-cockpit-feed--add-chips (drgnx-cockpit-timeline :since drgnx-cockpit-feed--last))))
           (inhibit-read-only t))
      (let ((old-chips (drgnx-cockpit-feed--old-chips open)))
        (unless (equal (mapcar #'drgnx-cockpit-feed--mark old-chips) (mapcar #'drgnx-cockpit-feed--mark drgnx-cockpit-feed--old))
          (setq touched (append (mapcar #'drgnx-cockpit-feed--row-key (append old-chips drgnx-cockpit-feed--old)) touched)
                drgnx-cockpit-feed--old old-chips)))
      (setq touched (append (drgnx-cockpit-feed--ensure-rows) touched))
      (when cards-changed (push "" touched))
      (unless (eql width drgnx-cockpit-feed--fit)
        (setq drgnx-cockpit-feed--fit width touched (mapcar #'car drgnx-cockpit-feed--rows)))
      (let ((head (drgnx-cockpit-feed--head-text (drgnx-cockpit-feed--head-count))))
        (unless (equal-including-properties head drgnx-cockpit-feed--head)
          (setq drgnx-cockpit-feed--head head)
          (drgnx-cockpit-feed--replace-line 1 head)))
      (cl-loop for row in drgnx-cockpit-feed--rows
               for i from 0
               when (or (member (car row) touched) (seq-some (lambda (m) (not (drgnx-cockpit-feed--mark-open-p m open))) (nth 3 row)))
               do (pcase-let ((`(,text ,marks) (drgnx-cockpit-feed--row-text row width open)))
                    (setf (nth 3 row) marks)
                    (if (< i old) (drgnx-cockpit-feed--replace-line (+ i 2) text)
                      (save-excursion
                        (goto-char (point-max))
                        (when (and (zerop old) (= i 0))       ; "Nothing yet" goes
                          (delete-region (progn (goto-char (point-min)) (forward-line 1) (point)) (point-max)))
                        (goto-char (point-max))
                        (insert text "\n")))))
      (set-buffer-modified-p nil))))

(defun drgnx-cockpit-feed--earlier (key)
  "Show every chip the timeline holds for row KEY, one per line with its time, oldest first: each a button."
  (let* ((row (assoc key (buffer-local-value 'drgnx-cockpit-feed--rows (drgnx-cockpit-timeline-buffer))))
         (open (drgnx-cockpit-feed--open-ids))
         (b (get-buffer-create (format "*timeline: %s*" (nth 1 row)))))
    (with-current-buffer b
      (special-mode)
      (setq truncate-lines t)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (format "Timeline: %s — every event it holds, oldest first" (nth 1 row)) 'face 'drgnx-cockpit-kind) "\n")
        (dolist (c (reverse (with-current-buffer (drgnx-cockpit-timeline-buffer)
                              (drgnx-cockpit-feed--row-chips key (nth 2 row)))))
          (insert (propertize (format-time-string "%F %H:%M" (plist-get c :at)) 'face 'drgnx-cockpit-edge) "  "
                  (drgnx-cockpit-feed--chip-text c open) "\n")))
      (goto-char (point-max))
      (forward-line -1))
    (pop-to-buffer b)
    b))

(defun drgnx-cockpit-timeline-show ()
  "Show the timeline (every agent's events as chips, one row per agent) in its pane, and focus it."
  (interactive)
  (let ((b (drgnx-cockpit-timeline-buffer)))
    (if (drgnx-pane-kind 'timeline) (drgnx-pane-show 'timeline :buffer b :select t) (pop-to-buffer b))
    (drgnx-cockpit-feed-schedule 0)
    b))

;;;; Questions everywhere

(defun drgnx-cockpit-feed--waiting-pair ()
  "(QUESTIONS . TOTAL), cached as `(STORE-KEY QUESTIONS . TOTAL)' in `drgnx-cockpit-feed--waiting'.
QUESTIONS: the open questions the jobs count does not hold — not an ask card (`:card' in its data) and not a job's
message (`:message' in its data and a `:job').  TOTAL: today's number (every open question, and the open ask cards
no question names), which the timeline's head shows."
  (let ((key (cons drgnx-cockpit-include-closed-jobs (drgnx-cockpit--db-key))))
    (if (equal key (car drgnx-cockpit-feed--waiting)) (cdr drgnx-cockpit-feed--waiting)
      (let* ((qs (drgnx-cockpit-feed--open-questions))
             (own (seq-count (lambda (q) (let ((d (plist-get q :data)))
                                           (not (or (plist-get d :card) (and (plist-get d :message) (plist-get q :job))))))
                             qs))
             (pair (cons own (+ (length qs) (length (drgnx-cockpit-feed--open-cards))))))
        (setq drgnx-cockpit-feed--waiting (cons key pair))
        pair))))

(defun drgnx-cockpit-waiting-count ()
  "How many questions wait on you that no other count holds (see `drgnx-cockpit-feed--waiting-pair'): for the status
bar's `drgnx-statusbar-waiting-functions', next to the jobs count."
  (car (drgnx-cockpit-feed--waiting-pair)))

(defun drgnx-cockpit-feed--head-count ()
  "Everything waiting on you that the timeline marks: its head's number."
  (cdr (drgnx-cockpit-feed--waiting-pair)))

(defun drgnx-cockpit-feed--open-cards ()
  "The open ask cards (of open jobs, unless `drgnx-cockpit-include-closed-jobs') that no open question
(`drgnx-cockpit-feed--open-questions') names — as the model counts them: ((ID JOB TASK TITLE AT)…), oldest first."
  (let ((asked (delq nil (mapcar (lambda (q) (plist-get (plist-get q :data) :card)) (drgnx-cockpit-feed--open-questions)))))
    (seq-remove (lambda (c) (memql (car c) asked))
                (sqlite-select (drgnx-work-db) (concat "select c.id, c.job, c.task, c.title, c.at from card c join job j on j.id = c.job"
                                                       " where c.state = 'open' and c.kind = 'ask'"
                                                       (if drgnx-cockpit-include-closed-jobs "" " and j.status is not 'done'")
                                                       " order by c.id")))))

(defun drgnx-cockpit-feed-tell-statusbar ()
  "Tell the status bar when `drgnx-cockpit-waiting-count' changed since it was last told (`drgnx-statusbar-refresh',
when it is loaded): so its count moves when another process asks, with no hub event.  One query when the store did
not change.  Called by the graph's and the feed's checks (timers).  The count counts as told only once the refresh
returned: a failed one is tried again at the next check."
  (let ((n (drgnx-cockpit-waiting-count)))
    (when (and (not (eql n drgnx-cockpit-feed--told)) (fboundp 'drgnx-statusbar-refresh))
      (drgnx-statusbar-refresh)
      (setq drgnx-cockpit-feed--told n))))

(defun drgnx-cockpit-feed--questions ()
  "Everything waiting on you that can be answered: the model's open questions (each with the :node it is about),
then each permission an agent session here waits on, as (:kind \"permission\" :agent ID :permission PID :summary
TITLE :node NODE).  Reads the store: for commands."
  (let ((sessions (drgnx-cockpit-sessions)))
    (append (plist-get (drgnx-cockpit-model :sessions sessions :silent drgnx-cockpit--silent) :questions)
            (cl-loop for s in sessions
                     append (mapcar (lambda (p) (list :kind "permission" :agent (plist-get s :id) :permission (plist-get p :id)
                                                      :summary (format "permission: %s" (or (plist-get p :title) "a tool call"))
                                                      :node (concat "agent:" (plist-get s :id))))
                                    (plist-get s :permissions))))))

(defun drgnx-cockpit-feed--describe (q)
  "Question Q in one line, for choosing it."
  (format "%s: %s" (drgnx-cockpit-feed--name (or (plist-get q :agent) (plist-get q :job) "a job"))
          (drgnx-cockpit--line (drgnx-cockpit--question-text (plist-get q :summary)) 100)))

(defun drgnx-cockpit-feed--question-here ()
  "The question to answer: the one on this line or chip (what happened, the timeline), else the one about the
graph's node on this line or selected, else what happened's agent's oldest, else one you pick.  nil in what
happened when its agent has none (a reply then)."
  (let* ((qs (drgnx-cockpit-feed--questions))
         (here (get-text-property (point) 'drgnx-cockpit-question))
         (card (get-text-property (point) 'drgnx-cockpit-card))
         (node (and (derived-mode-p 'drgnx-cockpit-graph-mode)
                    (or (and (not drgnx-cockpit--svg) (get-text-property (line-beginning-position) 'drgnx-cockpit-node))
                        drgnx-cockpit--selected))))
    (cond ((and here (seq-find (lambda (q) (eql (plist-get q :id) here)) qs)))
          ((and card (seq-find (lambda (q) (eql (plist-get q :card) card)) qs)))
          ((or here card) (user-error "That question was answered already"))
          ((and node (seq-find (lambda (q) (equal (plist-get q :node) node)) qs)))
          ((derived-mode-p 'drgnx-cockpit-happened-mode)
           (seq-find (lambda (q) (equal (plist-get q :agent) drgnx-cockpit-feed--agent)) qs))
          ((null qs) (user-error "Nothing waits on you"))
          (t (let ((choices (mapcar (lambda (q) (cons (drgnx-cockpit-feed--describe q) q)) qs)))
               (cdr (assoc (completing-read "Answer: " choices nil t) choices)))))))

(defun drgnx-cockpit-feed--hub (method params done &optional flight)
  "Ask the hub METHOD with PARAMS; DONE runs when it answered without an error, an error is said.  No hub: an error.
FLIGHT, when given, is the question on its way: a second answer to it is refused (`drgnx-cockpit-feed--in-flight')
until the hub answers, the call fails or `drgnx-cockpit-feed-in-flight-timeout' passes."
  (unless (fboundp 'drgnx-hub-call) (require 'drgnx-hub))
  (when flight
    (let ((cut (- (float-time) drgnx-cockpit-feed-in-flight-timeout)))
      ;; older entries are free: a hub that went away never answers them
      (setq drgnx-cockpit-feed--in-flight (seq-filter (lambda (e) (> (cdr e) cut)) drgnx-cockpit-feed--in-flight)))
    (when (assoc flight drgnx-cockpit-feed--in-flight) (user-error "The answer to that question is on its way already"))
    (push (cons flight (float-time)) drgnx-cockpit-feed--in-flight))
  (let ((land (lambda () (when flight (setq drgnx-cockpit-feed--in-flight
                                            (seq-remove (lambda (e) (equal (car e) flight)) drgnx-cockpit-feed--in-flight))))))
    (condition-case err
        (drgnx-hub-call method params (lambda (_r err)
                                        (funcall land)
                                        (if err (message "Work cockpit: %s" err) (funcall done))))
      (error (funcall land) (signal (car err) (cdr err))))))

(defun drgnx-cockpit-feed--changed ()
  "Something was answered or sent: the feed, the graph and the status bar look again soon."
  (drgnx-cockpit-feed-schedule 0)
  (drgnx-cockpit-schedule 0)
  (when (fboundp 'drgnx-statusbar-refresh) (drgnx-statusbar-refresh)))

(defun drgnx-cockpit-feed--queue (agent text done &optional flight answers)
  "Queue TEXT for AGENT, never interrupting it, then DONE (FLIGHT: as `drgnx-cockpit-feed--hub''s; ANSWERS: the id of
the message of AGENT's that TEXT answers, which a message in the store names):
- a session of this Emacs takes it as if its mode were `queue' (or `steer', which steers its turn): it starts a turn
  when the session is free, else it waits in its queue — its mode `interrupt' never cancels the turn here;
- a hub session's mirror: the hub's `agents/send' (queued), unless its mode interrupts;
- a mirror whose mode interrupts, an exited or failed session, or an agent with no session here: a message in the
  store, which the hub gives its sessions when they are free (an outside agent reads it).
`session', `message', or nil when the store held it back."
  (let* ((s (drgnx-cockpit-feed--session agent))
         (live (and s (not (memq (drgnx-agent-session-status s) '(exited failed))))))
    (cond
     ((and live (not (drgnx-agent-session-remote s)))
      (if (eq (drgnx-agent-session-mode s) 'interrupt)
          (cl-letf (((drgnx-agent-session-mode s) 'queue)) (drgnx-agents-send s text))
        (drgnx-agents-send s text))
      (funcall done)
      'session)
     ((and live (not (eq (drgnx-agent-session-mode s) 'interrupt)))
      (drgnx-cockpit-feed--hub "agents/send" (list :id (drgnx-agent-session-remote s) :text text) done flight)
      'session)
     (t
      (let ((r (drgnx-coord-send :recipient agent :text text :answers answers)))
        (if (equal (plist-get r :state) "held")
            (progn (message "Work cockpit: held, not sent — %s" (or (plist-get (drgnx-coord-message (plist-get r :id)) :reason) "too many messages"))
                   nil)
          (funcall done)
          (when (fboundp 'drgnx-hub-call) (ignore-errors (drgnx-hub-call "coord/notify" nil #'ignore)))   ; deliver now
          'message))))))

(defun drgnx-cockpit-answer (question text)
  "Answer QUESTION (an open question of `drgnx-cockpit-feed--questions') with TEXT, never interrupting anyone; an
`answer' event (by \"user\", data (:question ID)) then closes it.  How it goes, by what asked:
- an ask card: settled with TEXT (`drgnx-coord-card-settle', which writes the answer) — `card';
- a job's agent's message: the hub's `job/reply' (a message the hub delivers when the agent is free) — `job';
- an outside agent: a message to it in the store (it reads its inbox) — `message';
- a native session: queued in it, never cancelling its turn (`drgnx-cockpit-feed--queue') — `session' or `message';
  nil when the store held the message back (said; nothing is closed).
A second answer while one to the same question is on its way to the hub is refused.
- a permission: its transcript opens at it, where it is answered; nothing is written — `transcript'.
Interactively: the question on this line or chip, the one about the graph's node here, what happened's agent's,
else one you pick; then the text is asked for.  In what happened, an agent with no question gets a reply."
  (interactive
   (let ((q (drgnx-cockpit-feed--question-here)))
     (if (null q) (list nil nil)
       (list q (and (not (equal (plist-get q :kind) "permission"))
                    (read-string (format "Answer %s (queues, never interrupts): " (drgnx-cockpit-feed--describe q))))))))
  (if (null question)
      (call-interactively #'drgnx-cockpit-feed-reply)
    (let* ((data (plist-get question :data)) (qid (plist-get question :id)) (agent (plist-get question :agent))
           (card (or (plist-get question :card) (plist-get data :card)))
           (mid (plist-get data :message))
           (job (or (plist-get question :job) (and mid (plist-get (drgnx-coord-message mid) :job))))
           (answered (lambda ()
                       (when qid
                         (drgnx-coord-event-add :agent "user" :job (plist-get question :job) :task (plist-get question :task)
                                                :kind "answer" :summary text :data (list :question qid)))
                       (when mid (drgnx-coord-mark mid "acted"))
                       (drgnx-cockpit-feed--changed))))
      (when (and (not (equal (plist-get question :kind) "permission")) (or (null text) (string-blank-p text)))
        (user-error "An empty answer: nothing sent"))
      (let* ((flight (or qid (and card (cons 'card card))))
             (route
              (cond
               ((equal (plist-get question :kind) "permission")
                (drgnx-cockpit-feed--transcript agent)
                (message "Answer the permission in %s's transcript" (drgnx-cockpit-feed--name agent))
                'transcript)
               (card
                (unless (drgnx-coord-card-settle card text) (user-error "That card was settled already"))
                (drgnx-cockpit-feed--changed)
                'card)
               ((and mid job)
                (drgnx-cockpit-feed--hub "job/reply" (list :message mid :text text) answered flight)
                'job)
               (t (drgnx-cockpit-feed--queue agent text answered flight mid)))))
        ;; nil: the store held it back, and said so
        (when (and route (not (eq route 'transcript)))
          ;; through the hub, it is not queued yet: the hub's answer (or error) comes later
          (message (if (or (eq route 'job)
                           (and (eq route 'session)
                                (let ((s (drgnx-cockpit-feed--session agent))) (and s (drgnx-agent-session-remote s)))))
                       "Answer sent to the hub for %s: it never interrupts"
                     "Answer queued for %s: it never interrupts")
                   (if agent (drgnx-cockpit-feed--name agent) (format "job %s" (or job (plist-get question :job))))))
        route))))

(defun drgnx-cockpit-feed-reply (agent text)
  "Send TEXT to AGENT (what happened's), queued, never interrupting it: the answer to its oldest open question
when it has one (`drgnx-cockpit-answer'), else a message it gets when its turn ends."
  (interactive
   (let ((agent (or drgnx-cockpit-feed--agent (user-error "Reply from an agent's What happened"))))
     (list agent (read-string (format "Reply to %s (queues, never interrupts): " (drgnx-cockpit-feed--name agent))))))
  (when (string-blank-p (or text "")) (user-error "An empty reply: nothing sent"))
  (if-let* ((q (seq-find (lambda (q) (and (equal (plist-get q :agent) agent) (not (equal (plist-get q :kind) "permission"))))
                         (drgnx-cockpit-feed--questions))))
      (drgnx-cockpit-answer q text)
    (drgnx-cockpit-feed--queue agent text #'drgnx-cockpit-feed--changed)))

;;;; The module's part

(defun drgnx-cockpit-feed--setup ()
  "tools/cockpit's setup, the feed's part: the `happened' and `timeline' pane kinds, their commands, and the
questions only the cockpit counts in the status bar (`drgnx-cockpit-waiting-count')."
  (drgnx-pane-define-kind 'happened :title " WHAT HAPPENED" :home 'right :placeholder #'drgnx-cockpit-feed--happened-placeholder
                          :on-show #'drgnx-cockpit-feed--on-show)
  (drgnx-pane-define-kind 'timeline :title " TIMELINE" :home 'bottom :buffer #'drgnx-cockpit-timeline-buffer
                          :on-show #'drgnx-cockpit-feed--on-show)
  (drgnx-command-define 'cockpit-answer :category "Work" :title "Answer Question…" :command #'drgnx-cockpit-answer
                        :doc "Answer what waits on you: queued to the agent, never interrupting it" :map 'drgnx-cockpit-map)
  (drgnx-command-define 'cockpit-happened :category "Work" :title "Show What Happened…" :command #'drgnx-cockpit-happened-show
                        :doc "One agent's events, one line each: decisions, edits, tests, questions")
  (drgnx-command-define 'cockpit-timeline :category "Work" :title "Show Timeline" :command #'drgnx-cockpit-timeline-show
                        :doc "Every agent's events as chips, one row per agent")
  ;; the questions no jobs count holds join the status bar's "waiting on you"
  (add-hook 'drgnx-statusbar-waiting-functions #'drgnx-cockpit-waiting-count))

(provide 'drgnx-cockpit-feed)
;;; drgnx-cockpit-feed.el ends here
