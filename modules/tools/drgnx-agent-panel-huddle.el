;;; drgnx-agent-panel-huddle.el --- The agent panel's huddle threads (library of tools/agent-panel) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A huddle is two agents stating their positions about a clash, and you deciding.  Its thread is a panel of its own:
;; the header (state, the clash), each agent's reply with its position quoted (agent text, never an instruction) and
;; the decision it proposes, the outcome, and a composer that writes to both agents.  Opening the thread is joining.
;; The hub sends every change of a huddle as a `huddle' event; the thread and the count of open huddles (the status
;; bar's "huddle" mark) follow it.  Loaded by tools/agent-panel (drgnx-agent-panel.el); defines no module.
;; See docs/guide/agent-panel.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-view)
(require 'drgnx-registry)

(declare-function drgnx-agent-panel--ask "drgnx-agent-panel")

(defvar drgnx-agent-huddle-mode-map (make-sparse-keymap) "Keys of a huddle thread (the key profiles bind them).")

(defvar-local drgnx-agent-panel-huddle--id nil "The huddle this thread shows.")
(defvar-local drgnx-agent-panel-huddle--rec nil "Its latest record (a plist).")
(defvar-local drgnx-agent-panel-huddle--keys nil "The row keys drawn, in order.")

(defvar drgnx-agent-panel-huddle--open (make-hash-table :test #'equal)
  "Huddle id → its latest record while the huddle is asked or open (the status bar and the needs-you strip read them).")

(defun drgnx-agent-panel-huddle-open-count ()
  "How many huddles wait for you or are going on."
  (hash-table-count drgnx-agent-panel-huddle--open))

(defun drgnx-agent-panel-huddle-open-records ()
  "The records of the huddles that wait for you or are going on, oldest id first."
  (mapcar (lambda (id) (gethash id drgnx-agent-panel-huddle--open))
          (sort (hash-table-keys drgnx-agent-panel-huddle--open) #'string<)))

(defun drgnx-agent-panel-huddle-of (session)
  "The record of an open huddle that SESSION is in, or nil."
  (seq-find (lambda (rec) (seq-contains-p (plist-get rec :participants) session #'equal))
            (drgnx-agent-panel-huddle-open-records)))

(defvar drgnx-agent-panel-huddle-changed-hook nil "Run when a huddle opens or ends: the needs-you strip draws again.")

(defun drgnx-agent-panel-huddle--participants ()
  (append (plist-get drgnx-agent-panel-huddle--rec :participants) nil))

(defun drgnx-agent-panel-huddle--face (who)
  (let ((n (or (seq-position (drgnx-agent-panel-huddle--participants) who) 0)))
    (intern (format "drgnx-agent-%d" (1+ (mod n 6))))))

(defun drgnx-agent-panel-huddle--render (key)
  (let ((rec drgnx-agent-panel-huddle--rec))
    (pcase (car-safe key)
      (:h (concat (propertize (format " Huddle · %s" (plist-get rec :state)) 'face 'drgnx-agent-panel-title)
                  (if (plist-get rec :clash) (propertize (format " · about %s" (plist-get rec :clash)) 'face 'drgnx-agent-panel-subtle) "")
                  "\n  "
                  (mapconcat (lambda (p) (propertize p 'face (drgnx-agent-panel-huddle--face p)))
                             (drgnx-agent-panel-huddle--participants) " ⇄ ")
                  "\n"))
      (:r (let ((r (nth (cadr key) (append (plist-get rec :replies) nil))))
            (concat (propertize (format "\n  %s says\n" (plist-get r :from)) 'face (drgnx-agent-panel-huddle--face (plist-get r :from)))
                    (mapconcat (lambda (l) (propertize (concat "  ▎ " l "\n") 'face 'drgnx-agent-panel-md-quote))
                               (split-string (string-trim-right (or (plist-get r :text) "")) "\n") "")
                    (if (plist-get r :proposal)
                        (propertize (format "  → proposes: %s\n" (plist-get r :proposal)) 'face 'drgnx-agent-panel-subtle) ""))))
      (:o (concat "\n" (propertize (format "  %s\n" (if (plist-get rec :outcome)
                                                        (format "Outcome: %s" (plist-get rec :outcome))
                                                      (format "Agreed proposal: %s" (plist-get rec :proposal))))
                                   'face 'drgnx-agent-panel-title)))
      (:composer (propertize "\n  ▍ s write to both agents\n" 'face 'drgnx-agent-panel-subtle))
      (_ "\n"))))

(drgnx-view-define 'agent-huddle :render #'drgnx-agent-panel-huddle--render)

(define-derived-mode drgnx-agent-huddle-mode special-mode "Huddle"
  "A huddle between two agents: their positions, and a composer that writes to both."
  (setq-local truncate-lines t cursor-type nil))

(defun drgnx-agent-panel-huddle--wanted ()
  (append (list (list :h))
          (cl-loop for _ in (append (plist-get drgnx-agent-panel-huddle--rec :replies) nil) for n from 0 collect (list :r n))
          (and (or (plist-get drgnx-agent-panel-huddle--rec :outcome) (plist-get drgnx-agent-panel-huddle--rec :proposal))
               (list (list :o)))
          (list (list :composer))))

(defun drgnx-agent-panel-huddle--take (rec)
  "REC, the huddle's record, is the latest: the thread draws what changed."
  (let ((old drgnx-agent-panel-huddle--rec) (shown drgnx-agent-panel-huddle--keys)
        (wanted nil))
    (setq drgnx-agent-panel-huddle--rec rec wanted (drgnx-agent-panel-huddle--wanted))
    (if (member (format "%s" (plist-get rec :state)) '("asked" "open"))
        (puthash (plist-get rec :id) rec drgnx-agent-panel-huddle--open)
      (remhash (plist-get rec :id) drgnx-agent-panel-huddle--open))
    (when (drgnx-view-p drgnx-view)
      (when-let* ((gone (seq-remove (lambda (k) (member k wanted)) shown))) (drgnx-view-remove drgnx-view gone))
      (let (prev run run-after)
        (dolist (k wanted)
          (if (member k shown)
              (when run (drgnx-view-insert drgnx-view (nreverse run) :after run-after) (setq run nil))
            (unless run (setq run-after prev))
            (push k run))
          (setq prev k))
        (when run (drgnx-view-insert drgnx-view (nreverse run) :after run-after)))
      (setq drgnx-agent-panel-huddle--keys wanted)
      (unless (equal old rec) (drgnx-view-dirty drgnx-view (seq-filter (lambda (k) (member k shown)) wanted))))))

(defun drgnx-agent-panel-huddle-buffer (id)
  "The thread of huddle ID, made when there is none (it shows nothing until a record comes)."
  (let ((buffer (get-buffer-create (format "*drgnx huddle: %s*" id))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'drgnx-agent-huddle-mode)
        (drgnx-agent-huddle-mode)
        (setq drgnx-agent-panel-huddle--id id)
        (drgnx-view-attach 'agent-huddle)))
    buffer))

(defun drgnx-agent-panel-huddle-open-thread (rec)
  "Open the thread of huddle record REC and show it."
  (let ((b (drgnx-agent-panel-huddle-buffer (plist-get rec :id))))
    (with-current-buffer b (drgnx-agent-panel-huddle--take rec))
    (pop-to-buffer b)))

(defun drgnx-agent-panel-huddle-open (id)
  "Join huddle ID: ask the hub for it and open its thread.  Interactively, choose among the open ones."
  (interactive (list (let ((open (hash-table-keys drgnx-agent-panel-huddle--open)))
                       (if open (completing-read "Huddle: " open nil t) (user-error "No huddle is open")))))
  (drgnx-agent-panel--ask "agents/huddle/get" (list :id id)
                          (lambda (r err) (if err (message "agents/huddle/get: %s" err) (drgnx-agent-panel-huddle-open-thread r)))))

(defun drgnx-agent-panel-huddle-send (text)
  "Write TEXT to both agents of the huddle."
  (dolist (p (drgnx-agent-panel-huddle--participants))
    (drgnx-agent-panel--ask "agents/send" (list :id p :text text))))

(defun drgnx-agent-huddle-write ()
  "Write to both agents of this huddle."
  (interactive)
  (let ((text (string-trim (read-string "To both agents: "))))
    (unless (string-empty-p text) (drgnx-agent-panel-huddle-send text))))

(defun drgnx-agent-panel-huddle--event (event data)
  (when (equal event "huddle")
    (let* ((rec (or (plist-get data :huddle) data)))
      (when (plist-get rec :id)
        (when-let* ((b (get-buffer (format "*drgnx huddle: %s*" (plist-get rec :id)))))
          (with-current-buffer b (drgnx-agent-panel-huddle--take rec)))
        (if (member (format "%s" (plist-get rec :state)) '("asked" "open"))
            (puthash (plist-get rec :id) rec drgnx-agent-panel-huddle--open)
          (remhash (plist-get rec :id) drgnx-agent-panel-huddle--open))
        (run-hooks 'drgnx-agent-panel-huddle-changed-hook)))))

(defun drgnx-agent-panel-huddle-setup ()
  (drgnx-command-define 'agents-huddle-send :category "Agents" :title "Write to Both Huddle Agents"
                        :command #'drgnx-agent-huddle-write :map 'drgnx-agent-huddle-mode-map
                        :doc "A message to both agents of the huddle")
  (drgnx-command-define 'agents-huddle-open :category "Agents" :title "Join a Huddle"
                        :command #'drgnx-agent-panel-huddle-open
                        :doc "Open the thread of a huddle that is open or waits for you"))

(defun drgnx-agent-panel-huddle-teardown ()
  (clrhash drgnx-agent-panel-huddle--open)
  (dolist (b (buffer-list))
    (when (eq (buffer-local-value 'major-mode b) 'drgnx-agent-huddle-mode) (kill-buffer b))))

(provide 'drgnx-agent-panel-huddle)
;;; drgnx-agent-panel-huddle.el ends here
