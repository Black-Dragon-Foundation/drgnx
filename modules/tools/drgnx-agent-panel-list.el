;;; drgnx-agent-panel-list.el --- the agents list: one line for each session, RET opens its panel -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Part of module tools/agent-panel.  `agents-view' shows the sessions the hub runs, one row each (name, status,
;; context, what waits for you); RET opens that session's panel.  The rows are a view (wb/drgnx-view.el): a change of a
;; session draws that row again, and nothing is drawn while no window shows the list.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-view)
(require 'drgnx-registry)
(require 'drgnx-modules)

(declare-function drgnx-agents-sessions "drgnx-agents")
(declare-function drgnx-agent-session-name "drgnx-agents")
(declare-function drgnx-agent-session-status "drgnx-agents")
(declare-function drgnx-agent-session-remote "drgnx-agents")
(declare-function drgnx-agent-session-queue "drgnx-agents")
(declare-function drgnx-agent-session-permissions "drgnx-agents")
(declare-function drgnx-agent-session-reviews "drgnx-agents")
(declare-function drgnx-agents-context-percent "drgnx-agents")
(declare-function drgnx-agent-panel-open "drgnx-agent-panel")
(declare-function drgnx-wb-area-show "drgnx-wb")

(defconst drgnx-agent-panel-list-buffer-name "*drgnx Agents*")

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

(defun drgnx-agent-panel-list--render (key)
  (if (eq key :empty)
      (propertize "No agent sessions yet: New Agent Session… starts one\n" 'face 'shadow)
    (if-let* ((s (drgnx-agent-panel-list--session key)))
        (propertize (format "%-26s %-9s %5s  %s\n" (drgnx-agent-session-name s) (symbol-name (drgnx-agent-session-status s))
                            (if-let* ((p (drgnx-agents-context-percent s))) (format "%d%%" p) "")
                            (drgnx-agent-panel-list--waiting s))
                    'drgnx-agent-panel-list-id key)
      "\n")))

(defun drgnx-agent-panel-list--sig (key)
  (if-let* (((not (eq key :empty))) (s (drgnx-agent-panel-list--session key)))
      (vector (drgnx-agent-session-name s) (drgnx-agent-session-status s) (drgnx-agents-context-percent s)
              (length (drgnx-agent-session-queue s)) (length (drgnx-agent-session-permissions s))
              (length (drgnx-agent-session-reviews s)))
    key))

(defun drgnx-agent-panel-list--sync (view)
  (let ((ids (delq nil (mapcar #'drgnx-agent-session-remote (drgnx-agents-sessions)))))
    (drgnx-view-sync-rows view (or ids (list :empty)) #'drgnx-agent-panel-list--sig)))

(drgnx-view-define 'agent-panel-list :render #'drgnx-agent-panel-list--render :sync #'drgnx-agent-panel-list--sync)

(defvar drgnx-agent-panel-list-mode-map (make-sparse-keymap) "Keys come from the key profiles (command `agents-open').")

(define-derived-mode drgnx-agent-panel-list-mode special-mode "Agents"
  "The agent sessions, one on a line: RET opens the panel of the one at point."
  (setq-local truncate-lines t cursor-type nil))

(defun drgnx-agent-panel-list-buffer ()
  "The agents list, up to date."
  (let ((b (get-buffer-create drgnx-agent-panel-list-buffer-name)))
    (with-current-buffer b
      (unless (derived-mode-p 'drgnx-agent-panel-list-mode) (drgnx-agent-panel-list-mode))
      (unless (drgnx-view-p drgnx-view) (drgnx-view-attach 'agent-panel-list))
      (drgnx-view-touch drgnx-view)
      (drgnx-view-draw-now drgnx-view))
    b))

(defun drgnx-agent-panel-list-open ()
  "Open the panel of the session on this line."
  (interactive)
  (let ((id (or (get-text-property (line-beginning-position) 'drgnx-agent-panel-list-id) (user-error "No agent on this line"))))
    (drgnx-agent-panel-open id)))

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
  (when (fboundp 'drgnx-wb-define-tab)
    (drgnx-wb-define-tab 'right 'agents :title "Agents" :placeholder #'drgnx-agent-panel-list-buffer))
  (when (fboundp 'drgnx-wb-place) (drgnx-wb-place 'drgnx-agent-panel-list-mode 'right :tab 'agents))
  (drgnx-module-hook 'drgnx-agents-changed-functions list-changed (session) :module 'tools/agent-panel (drgnx-agent-panel-list-changed session))
  (drgnx-command-define 'agents-view :category "Agents" :title "Show Agents" :command #'drgnx-agent-panel-list-show
                        :doc "The agent sessions, one on a line; RET opens a panel")
  (drgnx-command-define 'agents-open :category "Agents" :title "Open" :command #'drgnx-agent-panel-list-open
                        :map 'drgnx-agent-panel-list-mode-map :doc "The panel of the session on this line"))

(provide 'drgnx-agent-panel-list)
;;; drgnx-agent-panel-list.el ends here
