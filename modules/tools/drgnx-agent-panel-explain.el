;;; drgnx-agent-panel-explain.el --- The agent panel's provenance lines and chip popups (library of tools/agent-panel) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Why a step was allowed, and what each chip means.  Under a step: the hooks' verdict lines (refused, changed,
;; failed, busy; RET on one shows its provenance) from the hook rows the step carries, and a line for a request you
;; answered Always.  A chip opens a popup of the hub's facts (`agents/explain') and the one action that helps: the
;; context breakdown with drop and pin where the agent advertises them and what /compact keeps, the cost per step with
;; the cache hits, the modes you may switch to, what the agent waits for, the MCP servers.  Nothing here is guessed: a
;; fact the hub does not know is not listed.  Loaded by tools/agent-panel (drgnx-agent-panel.el); defines no module.
;; See docs/guide/agent-panel.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-view)
(require 'drgnx-registry)
(require 'drgnx-agents-hooks)

(defvar drgnx-agent-panel--session)
(defvar drgnx-agent-panel--snap)
(defvar drgnx-agent-panel--steps)
(declare-function drgnx-agent-panel--ask "drgnx-agent-panel")
(declare-function drgnx-agent-panel--entry "drgnx-agent-panel")
(declare-function drgnx-agent-panel--stats-render "drgnx-agent-panel")
(declare-function drgnx-agents-hooks-show-provenance "drgnx-agents-hooks")
(declare-function drgnx-agents-hooks--preview-text "drgnx-agents-hooks")

(defconst drgnx-agent-panel-explain-items '(context cost mode model waiting mcp)
  "The chips `agents/explain' has facts for.")

(defvar-local drgnx-agent-panel--always nil
  "The requests answered Always in this panel, newest first: plists (:tool the tool call's id, :title).")

;;;; Under a step

(defun drgnx-agent-panel-explain--button (text action)
  (make-text-button (copy-sequence text) nil 'action (lambda (_) (funcall action)) 'follow-link t))

(defun drgnx-agent-panel-explain--always-of (e)
  "The Always records that allowed tool entry E."
  (seq-filter (lambda (a) (if (plist-get a :tool)
                              (equal (plist-get a :tool) (plist-get e :id))
                            (equal (plist-get a :title) (plist-get e :title))))
              drgnx-agent-panel--always))

(defun drgnx-agent-panel-explain-step-lines (e)
  "The lines under tool entry E: the hooks' verdicts on its step (a button each, its provenance) and the Always that
allowed it.  Empty when there is nothing to say."
  (let* ((step (and (plist-get e :step) (gethash (plist-get e :step) drgnx-agent-panel--steps)))
         (lines (drgnx-agents-hooks-lines (append (plist-get step :hooks) nil))))
    (concat
     (mapconcat (lambda (l)
                  (let ((row (plist-get l :row)) (rec (plist-get l :record)))
                    (concat "    "
                            (if rec
                                (drgnx-agent-panel-explain--button
                                 (plist-get l :text) (lambda () (drgnx-agents-hooks-show-provenance row rec)))
                              (plist-get l :text))
                            "\n")))
                lines "")
     (and (drgnx-agent-panel-explain--always-of e)
          (propertize "    allowed by your Always · V revokes\n" 'face 'drgnx-agent-panel-subtle)))))

(defun drgnx-agent-panel-explain-note-always (request)
  "REQUEST, a permission request, was answered Always: the step it belongs to says so."
  (let ((tool (plist-get request :tool)))
    (push (list :tool (and (consp tool) (or (plist-get tool :id) (plist-get tool :toolCallId)))
                :title (plist-get request :title))
          drgnx-agent-panel--always)))

(defun drgnx-agent-panel-revoke-always ()
  "Forget the Always that allowed the step at point.  The agent keeps its own rule until it starts again; the panel
stops saying the step was allowed by it."
  (interactive)
  (let* ((key (and (drgnx-view-p drgnx-view) (drgnx-view-key-at)))
         (e (and (eq (car-safe key) :e) (drgnx-agent-panel--entry (cadr key))))
         (mine (and e (drgnx-agent-panel-explain--always-of e))))
    (unless mine (user-error "This step was not allowed by an Always"))
    (setq drgnx-agent-panel--always (seq-remove (lambda (a) (memq a mine)) drgnx-agent-panel--always))
    (drgnx-view-dirty drgnx-view (list key))
    (message "Always forgotten here; the agent keeps its own rule until it restarts")))

;;;; Chip popups

(defun drgnx-agent-panel-explain--fresh (name)
  "An empty buffer called NAME (the one there was is killed, not erased)."
  (when-let* ((old (get-buffer name))) (kill-buffer old))
  (get-buffer-create name))

(defun drgnx-agent-panel-explain--facts-text (facts)
  (mapconcat (lambda (f) (format "%-34s %s\n" (plist-get f :name) (plist-get f :value))) (append facts nil) ""))

(defun drgnx-agent-panel-explain--feature-p (snap feature)
  (and (member feature (append (plist-get (plist-get snap :panel) :features) nil)) t))

(defun drgnx-agent-panel-explain--act (session method params)
  (drgnx-agent-panel--ask method (append (list :id session) params)
                          (lambda (_r err) (message "%s" (if err (format "%s: %s" method err) (format "%s: done" method))))))

(defun drgnx-agent-panel-explain--context-text (snap)
  "The context breakdown of SNAP: the bar, each part with its items (drop and pin buttons where the agent advertises
them) and what /compact frees (and a button for what it keeps, when the agent can say)."
  (let ((c (plist-get (plist-get snap :panel) :context)) (session drgnx-agent-panel--session))
    (when c
      (concat
       "\n" (drgnx-agents-hooks-bar c) "\n\n"
       (mapconcat
        (lambda (p)
          (concat (propertize "██ " 'face (drgnx-agents-hooks--kind-face (plist-get p :kind)))
                  (format "%-13s %7d tokens\n" (plist-get p :kind) (or (plist-get p :tokens) 0))
                  (mapconcat
                   (lambda (it)
                     (let ((item (plist-get it :id)))
                       (concat (format "    %-40s %7d  " (truncate-string-to-width (or (plist-get it :label) item) 40)
                                       (or (plist-get it :tokens) 0))
                               (and (drgnx-agent-panel-explain--feature-p snap "drop")
                                    (concat (drgnx-agent-panel-explain--button
                                             "[drop]" (lambda () (drgnx-agent-panel-explain--act
                                                                  session "agents/context-drop" (list :item item))))
                                            " "))
                               (and (drgnx-agent-panel-explain--feature-p snap "pin")
                                    (concat (drgnx-agent-panel-explain--button
                                             "[pin]" (lambda () (drgnx-agent-panel-explain--act
                                                                 session "agents/context-pin" (list :item item :pinned t))))
                                            " "
                                            (drgnx-agent-panel-explain--button
                                             "[unpin]" (lambda () (drgnx-agent-panel-explain--act
                                                                   session "agents/context-pin"
                                                                   (list :item item :pinned :false))))))
                               "\n")))
                   (append (plist-get p :items) nil) "")))
        (append (plist-get c :parts) nil) "")
       (and (plist-get c :compact_frees) (format "\n/compact would free %d tokens\n" (plist-get c :compact_frees)))
       (and (drgnx-agent-panel-explain--feature-p snap "compact-preview")
            (concat "\n" (drgnx-agent-panel-explain--button
                          "[What /compact keeps]" (lambda () (drgnx-agent-panel-explain--compact-preview session)))
                    "\n"))))))

(defun drgnx-agent-panel-explain--compact-preview (session)
  (drgnx-agent-panel--ask
   "agents/compact-preview" (list :id session)
   (lambda (r err)
     (if err (message "agents/compact-preview: %s" err)
       (with-current-buffer (drgnx-agent-panel-explain--fresh "*agent compact preview*")
         (let ((inhibit-read-only t)) (insert (drgnx-agents-hooks--preview-text r)))
         (special-mode)
         (pop-to-buffer (current-buffer)))))))

(defun drgnx-agent-panel-explain--cost-text ()
  "The steps that cost most, and how much of the input came from the cache, from the steps loaded in this panel."
  (let* ((steps (seq-filter (lambda (s) (numberp (plist-get s :cost))) (hash-table-values drgnx-agent-panel--steps)))
         (top (seq-take (sort (copy-sequence steps) (lambda (a b) (> (plist-get a :cost) (plist-get b :cost)))) 5))
         (in (apply #'+ (mapcar (lambda (s) (or (plist-get s :tokens_in) 0)) (hash-table-values drgnx-agent-panel--steps))))
         (read (apply #'+ (mapcar (lambda (s) (or (plist-get s :cache_read) 0)) (hash-table-values drgnx-agent-panel--steps)))))
    (concat (and top (concat "\nDearest steps\n"
                             (mapconcat (lambda (s) (format "  step %-6s $%.2f\n" (plist-get s :seq) (plist-get s :cost))) top "")))
            (and (> (+ in read) 0)
                 (format "\nCache hits  %d%% of the input (%d of %d tokens)\n" (round (* 100.0 (/ (float read) (+ in read))))
                         read (+ in read))))))

(defun drgnx-agent-panel-explain--waiting-text (snap)
  (cond ((plist-get snap :permissions) "\nAnswer: RET allow once · A always · D deny\n")
        ((plist-get snap :paused) "\nHeld by you: u resumes it\n")))

(defun drgnx-agent-panel-explain--popup-text (item facts snap)
  "The popup of chip ITEM (a symbol): the title, the hub's FACTS (a list or vector of (:name :value)), and the item's
own part drawn from SNAP and the steps loaded here."
  (concat (propertize (format "%s\n" (capitalize (symbol-name item))) 'face 'drgnx-agent-panel-title)
          "\n" (drgnx-agent-panel-explain--facts-text facts)
          (pcase item
            ('context (drgnx-agent-panel-explain--context-text snap))
            ('cost (drgnx-agent-panel-explain--cost-text))
            ('waiting (drgnx-agent-panel-explain--waiting-text snap))
            ('mode (drgnx-agent-panel-explain--mode-text snap))
            (_ nil))))

(defun drgnx-agent-panel-explain--mode-text (_snap)
  "The part of the mode popup beyond the hub's facts: none yet."
  nil)

(defun drgnx-agent-panel-explain--show (buffer item facts)
  "Show the popup of ITEM for the panel BUFFER."
  (when (buffer-live-p buffer)
    (let ((text (with-current-buffer buffer
                  (drgnx-agent-panel-explain--popup-text item facts drgnx-agent-panel--snap))))
      (with-current-buffer (drgnx-agent-panel-explain--fresh (format "*agent %s*" item))
        (let ((inhibit-read-only t)) (insert text))
        (special-mode)
        (goto-char (point-min))
        (pop-to-buffer (current-buffer))))))

(defun drgnx-agent-panel-chip (item)
  "Open the facts behind chip ITEM (context, cost, mode, model, waiting or mcp): the chip at point, else you choose."
  (interactive (list (or (get-text-property (point) 'drgnx-agent-panel-chip)
                         (intern (completing-read "Chip: " (mapcar #'symbol-name drgnx-agent-panel-explain-items) nil t)))))
  (let ((buffer (current-buffer)))
    (drgnx-agent-panel--ask "agents/explain" (list :id drgnx-agent-panel--session :item (symbol-name item))
                            (lambda (r err)
                              (if err (message "agents/explain: %s" err)
                                (drgnx-agent-panel-explain--show buffer item (plist-get r :facts)))))))

(defun drgnx-agent-panel-explain-setup ()
  (dolist (c '((agents-panel-chip "Explain a Chip" drgnx-agent-panel-chip
                                  "The facts behind the chip at point, and the one action that helps")
               (agents-panel-revoke-always "Forget an Always" drgnx-agent-panel-revoke-always
                                           "On a step an Always allowed: the panel stops saying so (the agent keeps its rule)")))
    (drgnx-command-define (nth 0 c) :category "Agents" :title (nth 1 c) :command (nth 2 c)
                          :map 'drgnx-agent-panel-mode-map :doc (nth 3 c))))

(provide 'drgnx-agent-panel-explain)
;;; drgnx-agent-panel-explain.el ends here
