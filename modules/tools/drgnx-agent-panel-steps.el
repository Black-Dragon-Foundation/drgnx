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
(require 'drgnx-setting)
(require 'drgnx-view)
(require 'drgnx-registry)

(defvar drgnx-agent-panel--session)
(defvar drgnx-agent-panel--shown-keys)
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

;;;; Disclosure: which steps show their detail

(defconst drgnx-agent-panel-step-types '(thinking read search edit execute fetch other)
  "The step types the disclosure strip has a toggle for: a tool step's kind, and the agent's thinking.")

(defconst drgnx-agent-panel-presets
  '((watch) (review edit execute) (debug thinking read search edit execute fetch other))
  "The view presets on 1, 2 and 3: watch shows the steps' titles only, review opens edits and commands, debug opens all.")

(drgnx-defsetting drgnx-agent-panel-disclosure nil
  "The step types whose detail a new agent panel opens: thinking, read, search, edit, execute, fetch, other.
A failed step opens whatever this says.  `M' in a panel makes its current choice the default."
  :type '(set (const thinking) (const read) (const search) (const edit) (const execute) (const fetch) (const other))
  :group 'drgnx-agent-panel :scope 'global :agents 'never
  :schema '(list-of (enum thinking read search edit execute fetch other)))

(defvar-local drgnx-agent-panel--disclosure nil "The step types open in this chat.")
(defvar drgnx-agent-panel--defaults-unsaved nil "Non-nil while the default chosen with `M' is not yet in the settings file.")

(defun drgnx-agent-panel-steps-init ()
  "A new panel starts with the defaults."
  (setq drgnx-agent-panel--disclosure (copy-sequence drgnx-agent-panel-disclosure)))

(defun drgnx-agent-panel--step-type (e)
  (let ((k (and (stringp (plist-get e :kind)) (intern (plist-get e :kind)))))
    (if (memq k drgnx-agent-panel-step-types) k 'other)))

(defun drgnx-agent-panel--override (key) (and drgnx-agent-panel--open (gethash key drgnx-agent-panel--open)))

(defun drgnx-agent-panel--thinking-open-p (key)
  "Whether the thinking under the row KEY shows: your choice for the row, else the chat's toggle for thinking."
  (let ((o (drgnx-agent-panel--override key)))
    (if o (eq o 'open) (and (memq 'thinking drgnx-agent-panel--disclosure) t))))

(defun drgnx-agent-panel--detail-open-p (key e)
  "Whether the detail of tool entry E (row KEY) shows: your choice for the row, else it opens when the step failed,
else when the chat's toggle for its type is on."
  (let ((o (drgnx-agent-panel--override key)))
    (cond (o (eq o 'open))
          ((equal (plist-get e :status) "failed") t)
          (t (and (memq (drgnx-agent-panel--step-type e) drgnx-agent-panel--disclosure) t)))))

(defun drgnx-agent-panel--row-toggle (key)
  "Open or fold row KEY's detail and thinking, whatever the toggles say."
  (let* ((e (drgnx-agent-panel--entry (cadr key)))
         (now (or (drgnx-agent-panel--thinking-open-p key) (and e (drgnx-agent-panel--detail-open-p key e)))))
    (puthash key (if now 'closed 'open) drgnx-agent-panel--open)
    (drgnx-view-dirty drgnx-view (list key))))

(defun drgnx-agent-panel--redraw-steps ()
  "Every step row and the strip are drawn again."
  (when (drgnx-view-p drgnx-view)
    (drgnx-view-dirty drgnx-view
                      (cons (list :strip)
                            (seq-filter (lambda (k) (eq (car-safe k) :e)) (hash-table-keys drgnx-agent-panel--shown-keys))))))

(defun drgnx-agent-panel--set-disclosure (types)
  "TYPES are the open step types of this chat; rows you opened or folded by hand are back under the toggles."
  (setq drgnx-agent-panel--disclosure (copy-sequence types))
  (clrhash drgnx-agent-panel--open)
  (drgnx-agent-panel--redraw-steps))

(defun drgnx-agent-panel-toggle-type (type)
  "Open or close the detail of every step of TYPE in this chat."
  (interactive (list (intern (completing-read "Step type: " (mapcar #'symbol-name drgnx-agent-panel-step-types) nil t))))
  (drgnx-agent-panel--set-disclosure
   (if (memq type drgnx-agent-panel--disclosure) (remq type drgnx-agent-panel--disclosure)
     (cons type drgnx-agent-panel--disclosure))))

(defun drgnx-agent-panel-preset (n)
  "The view preset N: 1 watch, 2 review, 3 debug."
  (drgnx-agent-panel--set-disclosure (cdr (nth (1- n) drgnx-agent-panel-presets))))

(defun drgnx-agent-panel-preset-1 () "Watch: steps as titles only." (interactive) (drgnx-agent-panel-preset 1))
(defun drgnx-agent-panel-preset-2 () "Review: edits and commands open." (interactive) (drgnx-agent-panel-preset 2))
(defun drgnx-agent-panel-preset-3 () "Debug: everything open." (interactive) (drgnx-agent-panel-preset 3))

(declare-function drgnx-settings-editors-commit "drgnx-settings-editors")

(defun drgnx-agent-panel--save-defaults ()
  "Write the default to the user's settings file; nil (and the default stays unsaved) when that is refused."
  (require 'drgnx-settings-editors nil t)
  (when (fboundp 'drgnx-settings-editors-commit)
    (condition-case nil
        (progn (drgnx-settings-editors-commit 'drgnx-agent-panel-disclosure 'user nil drgnx-agent-panel-disclosure) t)
      (error nil))))

(defun drgnx-agent-panel-make-default ()
  "Make this chat's open step types the default for new panels, and save them in your settings."
  (interactive)
  (setq drgnx-agent-panel-disclosure (copy-sequence drgnx-agent-panel--disclosure))
  (setq drgnx-agent-panel--defaults-unsaved (not (drgnx-agent-panel--save-defaults)))
  (message "Agent panel: %s is now the default%s"
           (if drgnx-agent-panel-disclosure (mapconcat #'symbol-name drgnx-agent-panel-disclosure ", ") "titles only")
           (if drgnx-agent-panel--defaults-unsaved " (not saved: your settings file refused it)" "")))

(defun drgnx-agent-panel--strip-row ()
  "The disclosure strip: a toggle for each step type, and the presets."
  (concat " "
          (mapconcat (lambda (ty)
                       (propertize (format " %s %s " (if (memq ty drgnx-agent-panel--disclosure) "▾" "▸") ty)
                                   'face 'drgnx-agent-panel-chip))
                     drgnx-agent-panel-step-types " ")
          (propertize "  1 watch · 2 review · 3 debug · T toggle · M make default" 'face 'drgnx-agent-panel-subtle)
          "\n"))

(defun drgnx-agent-panel-steps-setup ()
  (drgnx-command-define 'agents-panel-toggle-type :category "Agents" :title "Open or Close a Step Type"
                        :command #'drgnx-agent-panel-toggle-type :map 'drgnx-agent-panel-mode-map
                        :doc "Show or hide the detail of every step of one type in this chat")
  (drgnx-command-define 'agents-panel-preset-1 :category "Agents" :title "Panel View: Watch"
                        :command #'drgnx-agent-panel-preset-1 :map 'drgnx-agent-panel-mode-map
                        :doc "Steps as titles only")
  (drgnx-command-define 'agents-panel-preset-2 :category "Agents" :title "Panel View: Review"
                        :command #'drgnx-agent-panel-preset-2 :map 'drgnx-agent-panel-mode-map
                        :doc "Edits and commands open")
  (drgnx-command-define 'agents-panel-preset-3 :category "Agents" :title "Panel View: Debug"
                        :command #'drgnx-agent-panel-preset-3 :map 'drgnx-agent-panel-mode-map
                        :doc "Every step open, thinking included")
  (drgnx-command-define 'agents-panel-make-default :category "Agents" :title "Make the Panel View the Default"
                        :command #'drgnx-agent-panel-make-default :map 'drgnx-agent-panel-mode-map
                        :doc "The step types open now are what new panels open"))

(defun drgnx-agent-panel-steps-teardown ()
  "A default chosen with `M' that the settings file refused is tried once more before the module goes."
  (when drgnx-agent-panel--defaults-unsaved
    (setq drgnx-agent-panel--defaults-unsaved (not (drgnx-agent-panel--save-defaults)))))


(defun drgnx-agent-panel--tool-row (idx e)
  (let* ((key (list :e idx)) (status (format "%s" (or (plist-get e :status) "")))
         (title (drgnx-agent-panel--one-line (or (plist-get e :title) (plist-get e :kind) "tool") 50))
         (result (drgnx-agent-panel--one-line (drgnx-agent-panel--text-of (plist-get e :content)) 40))
         (meta (drgnx-agent-panel--meta e))
         (thoughts (drgnx-agent-panel--thoughts-of idx))
         (open-thinking (drgnx-agent-panel--thinking-open-p key))
         (open-detail (drgnx-agent-panel--detail-open-p key e)))
    (concat (format "  %s %s" (drgnx-agent-panel--dot status) title)
            (if (string-empty-p result) ""
              (propertize (concat "  · " result) 'face 'drgnx-agent-panel-subtle))
            (if meta (drgnx-agent-panel--align meta) "")
            "\n"
            (when thoughts
              (let ((text (mapconcat (lambda (th) (or (plist-get th :text) "")) thoughts "\n")))
                (if open-thinking
                    (concat (propertize "    ▾ thinking\n" 'face 'drgnx-agent-panel-subtle)
                            (drgnx-agent-panel--indented text 'drgnx-agent-panel-subtle))
                  (propertize (format "    ▸ thinking · %d lines\n" (length (split-string (string-trim-right text) "\n")))
                              'face 'drgnx-agent-panel-subtle))))
            (when (and open-detail (drgnx-agent-panel--text-of (plist-get e :content)))
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
                        (if (drgnx-agent-panel--thinking-open-p (list :e idx))
                            (drgnx-agent-panel--indented (plist-get e :text) 'drgnx-agent-panel-subtle) "")))
      ('stop (propertize "  — turn ended\n" 'face 'drgnx-agent-panel-subtle))
      ('error (propertize (format "  ✗ %s\n" (drgnx-agent-panel--one-line (or (plist-get e :text) (plist-get e :title) "error") 80))
                          'face 'drgnx-agent-panel-fail))
      ('compaction (propertize "  — context compacted\n" 'face 'drgnx-agent-panel-subtle))
      (_ (propertize (format "  %s\n" (drgnx-agent-panel--one-line (plist-get e :text) 80)) 'face 'drgnx-agent-panel-subtle)))))


(provide 'drgnx-agent-panel-steps)
;;; drgnx-agent-panel-steps.el ends here
