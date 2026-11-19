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

(defun drgnx-agent-panel-list-setup ()
  (when (require 'drgnx-panes nil t)
    (drgnx-pane-define-kind 'agents :home 'right :title "Agents" :placeholder #'drgnx-agent-panel-list-buffer))
  (when (fboundp 'drgnx-wb-place) (drgnx-wb-place 'drgnx-agent-panel-list-mode 'right :tab 'agents))
  (drgnx-module-hook 'drgnx-agents-changed-functions list-changed (session) :module 'tools/agent-panel (drgnx-agent-panel-list-changed session))
  (drgnx-command-define 'agents-view :category "Agents" :title "Show Agents" :command #'drgnx-agent-panel-list-show
                        :doc "The agent sessions, one on a line; RET opens a panel")
  (drgnx-command-define 'agents-open :category "Agents" :title "Open" :command #'drgnx-agent-panel-list-open
                        :map 'drgnx-agent-panel-list-mode-map :doc "The panel of the session on this line"))

(provide 'drgnx-agent-panel-list)
;;; drgnx-agent-panel-list.el ends here
