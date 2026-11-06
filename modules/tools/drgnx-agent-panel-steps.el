;;; drgnx-agent-panel-steps.el --- The agent panel's rows: header, chips, steps, messages (library of tools/agent-panel) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; How the panel's rows look.  A tool call is a step on one line: a dot for its state, its title, its result after `·',
;; its time and cost right-aligned in the code face (the warning face when slow or expensive).  Thinking folds under
;; its step.  Loaded by tools/agent-panel (drgnx-agent-panel.el); defines no module.  See docs/guide/agent-panel.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defvar drgnx-agent-panel--session)
(defvar drgnx-agent-panel--snap)
(defvar drgnx-agent-panel--busy-since)
(defvar drgnx-agent-panel--entries)
(defvar drgnx-agent-panel--steps)
(defvar drgnx-agent-panel--open)
(defvar drgnx-agent-panel-slow-seconds)
(defvar drgnx-agent-panel-expensive-cost)
(declare-function drgnx-agent-panel--entry "drgnx-agent-panel")
(declare-function drgnx-agent-panel--thoughts-of "drgnx-agent-panel")
(declare-function drgnx-agent-panel--duration-string "drgnx-agent-panel")
(declare-function drgnx-agent-panel--type "drgnx-agent-panel")
(declare-function drgnx-agent-panel--text-of "drgnx-agent-panel")
(declare-function drgnx-agent-panel--one-line "drgnx-agent-panel")
(declare-function drgnx-agent-panel--seconds "drgnx-agent-panel")
(declare-function drgnx-agent-panel--cost-of "drgnx-agent-panel")

(defun drgnx-agent-panel--align (meta)
  "A space that pushes META to the right edge, then META."
  (concat (propertize " " 'display `(space :align-to (- right ,(1+ (string-width meta))))) meta))

(defun drgnx-agent-panel--status-line (snap since now)
  "What the agent is doing, for the header: \"Claude · running 6 min\", \"held by you\" or \"Pair · editing your checkout\".
SNAP is the snapshot, SINCE when it began running (float seconds) and NOW the time."
  (let* ((who (or (plist-get snap :profile) "Agent"))
         (status (format "%s" (plist-get snap :status)))
         (what (cond ((plist-get snap :paused) "held by you")
                     ((and (plist-get snap :paired) (not (eq (plist-get snap :paired) :json-false))) "Pair · editing your checkout")
                     ((equal status "busy")
                      (if since (format "running %d min" (max 1 (round (/ (- now since) 60.0)))) "running"))
                     ((equal status "waiting") "waiting for you")
                     ((equal status "exited") "ended")
                     ((equal status "idle") "idle")
                     (t status))))
    (if (and (plist-get snap :paired) (not (plist-get snap :paused))
             (not (eq (plist-get snap :paired) :json-false)))
        what
      (format "%s · %s" who what))))

(defun drgnx-agent-panel--header-row ()
  (let* ((snap drgnx-agent-panel--snap)
         (name (or (plist-get snap :name) drgnx-agent-panel--session "agent")))
    (concat (propertize (format " %s" name) 'face 'drgnx-agent-panel-title)
            (propertize (format "  %s" (drgnx-agent-panel--status-line snap drgnx-agent-panel--busy-since
                                                                       (float-time)))
                        'face 'drgnx-agent-panel-subtle)
            "\n")))

(defun drgnx-agent-panel--chips (snap)
  "The chips the snapshot feeds, a list of strings; one the hub did not feed is not there."
  (let* ((usage (plist-get snap :usage))
         (used (plist-get usage :used)) (size (plist-get usage :size)) (cost (plist-get usage :cost))
         (files (plist-get snap :files_edited)) (checks (plist-get snap :checkpoints))
         (mcp (plist-get snap :mcp)) (sandbox (plist-get snap :sandbox))
         (model (plist-get snap :model)) (mode (plist-get snap :mode)))
    (delq nil
          (list (and (stringp model) model)
                (and (numberp used) (numberp size) (> size 0)
                     (let ((p (round (* 100 (/ (float used) size)))))
                       (format "%s %d%%" (cond ((< p 13) "○") ((< p 38) "◔") ((< p 63) "◑") ((< p 88) "◕") (t "●")) p)))
                (and cost (let ((c (if (listp cost) (plist-get cost :amount) cost))) (and (numberp c) (format "$%.2f" c))))
                (and mode (format "%s" mode))
                (and sandbox (format "%s" (if (eq sandbox t) "sandboxed" sandbox)))
                (and mcp (format "MCP %s" (if (numberp mcp) mcp (length mcp))))
                (and (numberp files) (format "%d files" files))
                (and (numberp checks) (format "%d checkpoints" checks))))))

(defun drgnx-agent-panel--chips-row ()
  (let ((chips (drgnx-agent-panel--chips drgnx-agent-panel--snap)))
    (concat " " (mapconcat (lambda (c) (propertize (concat " " c " ") 'face 'drgnx-agent-panel-chip)) chips " ") "\n")))

(defun drgnx-agent-panel--dot (status)
  (pcase status
    ((or "completed" "done") (propertize "●" 'face 'drgnx-agent-panel-ok))
    ("failed" (propertize "●" 'face 'drgnx-agent-panel-fail))
    (_ (propertize "○" 'face 'drgnx-agent-panel-run))))

(defun drgnx-agent-panel--meta (entry)
  "The right-hand time and cost of tool ENTRY, a propertized string, or nil."
  (when-let* ((seq (plist-get entry :step)) (step (gethash seq drgnx-agent-panel--steps)))
    (let* ((secs (drgnx-agent-panel--seconds step)) (cost (drgnx-agent-panel--cost-of step))
           (slow (and secs (> secs drgnx-agent-panel-slow-seconds)))
           (dear (and cost (> cost drgnx-agent-panel-expensive-cost)))
           (parts (delq nil (list (and secs (propertize (drgnx-agent-panel--duration-string secs)
                                                        'face (if slow '(drgnx-agent-panel-warn drgnx-agent-panel-code)
                                                                'drgnx-agent-panel-code)))
                                  (and cost (propertize (format "$%.2f" cost)
                                                        'face (if dear '(drgnx-agent-panel-warn drgnx-agent-panel-code)
                                                                'drgnx-agent-panel-code)))))))
      (and parts (mapconcat #'identity parts (propertize " · " 'face 'drgnx-agent-panel-code))))))

(defun drgnx-agent-panel--indented (text face &optional limit)
  "TEXT as lines indented by four columns in FACE, at most LIMIT lines (default 40)."
  (let* ((lines (split-string (string-trim-right (or text "")) "\n")) (limit (or limit 40)))
    (mapconcat (lambda (l) (propertize (concat "    " l "\n") 'face face))
               (append (seq-take lines limit) (and (> (length lines) limit) (list "…"))) "")))

(defun drgnx-agent-panel--open-p (key) (and drgnx-agent-panel--open (gethash key drgnx-agent-panel--open)))

(defun drgnx-agent-panel--tool-row (idx e)
  (let* ((key (list :e idx)) (status (format "%s" (or (plist-get e :status) "")))
         (title (drgnx-agent-panel--one-line (or (plist-get e :title) (plist-get e :kind) "tool") 50))
         (result (drgnx-agent-panel--one-line (drgnx-agent-panel--text-of (plist-get e :content)) 40))
         (meta (drgnx-agent-panel--meta e))
         (thoughts (drgnx-agent-panel--thoughts-of idx))
         (open (drgnx-agent-panel--open-p key)))
    (concat (format "  %s %s" (drgnx-agent-panel--dot status) title)
            (if (string-empty-p result) ""
              (propertize (concat "  · " result) 'face 'drgnx-agent-panel-subtle))
            (if meta (drgnx-agent-panel--align meta) "")
            "\n"
            (when thoughts
              (let ((text (mapconcat (lambda (th) (or (plist-get th :text) "")) thoughts "\n")))
                (if open
                    (concat (propertize "    ▾ thinking\n" 'face 'drgnx-agent-panel-subtle)
                            (drgnx-agent-panel--indented text 'drgnx-agent-panel-subtle))
                  (propertize (format "    ▸ thinking · %d lines\n" (length (split-string (string-trim-right text) "\n")))
                              'face 'drgnx-agent-panel-subtle))))
            (when (and open (drgnx-agent-panel--text-of (plist-get e :content)))
              (drgnx-agent-panel--indented (drgnx-agent-panel--text-of (plist-get e :content)) 'default 12)))))

(defun drgnx-agent-panel--entry-row (idx)
  (let ((e (drgnx-agent-panel--entry idx)))
    (pcase (drgnx-agent-panel--type e)
      ('tool (drgnx-agent-panel--tool-row idx e))
      ('user (concat (propertize "  ▍ you  " 'face 'drgnx-agent-panel-you)
                     (drgnx-agent-panel--one-line (plist-get e :text) 70) "\n"))
      ('agent (concat (propertize (concat "  " (replace-regexp-in-string "\n" "\n  " (string-trim-right (or (plist-get e :text) ""))))
                                  'face 'default)
                      "\n"))
      ('thought (concat (propertize "  ▸ thinking\n" 'face 'drgnx-agent-panel-subtle)
                        (if (drgnx-agent-panel--open-p (list :e idx))
                            (drgnx-agent-panel--indented (plist-get e :text) 'drgnx-agent-panel-subtle) "")))
      ('stop (propertize "  — turn ended\n" 'face 'drgnx-agent-panel-subtle))
      ('error (propertize (format "  ✗ %s\n" (drgnx-agent-panel--one-line (or (plist-get e :text) (plist-get e :title) "error") 80))
                          'face 'drgnx-agent-panel-fail))
      ('compaction (propertize "  — context compacted\n" 'face 'drgnx-agent-panel-subtle))
      (_ (propertize (format "  %s\n" (drgnx-agent-panel--one-line (plist-get e :text) 80)) 'face 'drgnx-agent-panel-subtle)))))


(provide 'drgnx-agent-panel-steps)
;;; drgnx-agent-panel-steps.el ends here
