;;; drgnx-agent-settings.el --- Module tools/agent-settings: one settings page per coding agent -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Agents: Settings opens a page for Claude Code, Codex, Gemini or Kimi Code (`*agent settings: TITLE*', in the editor
;; area): the routes to the models and their billing, then the agent's MCP servers, hooks and skills, each with where
;; it comes from, its status and its detail.  Add, edit, remove and turn on or off write the agent's own files
;; (core/drgnx-agent-config*.el); Test runs an MCP server or a hook in a separate process (core/drgnx-agent-check.el).
;;
;; Opening and Refresh only read files (`drgnx-agent-config-read' and the last Test results): nothing is started.  A
;; Test result arrives from a process and redraws the page; it never asks anything.  Environment and header values
;; are never drawn (`NAME=••••'); they are read with `read-passwd', and an empty answer keeps the current value.
;; See docs/guide/agent-settings.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'button)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-agent-config)
(require 'drgnx-agent-config-claude)
(require 'drgnx-agent-config-codex)
(require 'drgnx-agent-config-gemini)
(require 'drgnx-agent-config-kimi)
(require 'drgnx-agent-check)

(declare-function drgnx-wb-place "drgnx-rules")
(declare-function drgnx-agents-profile "drgnx-agents")
(declare-function drgnx-agent-session-p "drgnx-agents")
(declare-function drgnx-agent-session-profile "drgnx-agents")
(declare-function drgnx-agent-session-cwd "drgnx-agents")
(declare-function drgnx-ai-provider "drgnx-ai")
(declare-function drgnx-ai-agent-gateway-chain "drgnx-ai")
(declare-function drgnx-ai-store-key "drgnx-ai")
(declare-function tabulated-list-get-id "tabulated-list")
(declare-function project-root "project")

(defvar drgnx-wb--owned)                ; drgnx-wb.el: windows the running code may move from a timer
(defvar drgnx-agents-ui--session)       ; drgnx-agents-ui.el: the session of a transcript buffer

(defface drgnx-agent-settings-heading '((t :inherit bold)) "Headings of an agent settings page." :group 'drgnx)
(defface drgnx-agent-settings-dim '((t :inherit shadow)) "Details on an agent settings page." :group 'drgnx)
(defface drgnx-agent-settings-ok '((t :inherit success)) "A status that is fine." :group 'drgnx)
(defface drgnx-agent-settings-problem '((t :inherit error)) "A status or file that is wrong." :group 'drgnx)
(defface drgnx-agent-settings-warning '((t :inherit warning)) "A note to read: a setting overrides another." :group 'drgnx)

(defvar-local drgnx-agent-settings--kind nil "The agent this page shows.")
(defvar-local drgnx-agent-settings--root nil "The project this page shows (a directory name), or nil.")
(defvar-local drgnx-agent-settings--data nil "What `drgnx-agent-config-read' returned for this page.")

(defvar drgnx-agent-settings--running (make-hash-table :test #'equal)
  "Items whose Test runs now: ((KIND SECTION NAME FILE) . ORDINAL) → t.")

(defconst drgnx-agent-settings--sections '((mcp . "MCP Servers") (hook . "Hooks") (skill . "Skills"))
  "The sections of a page, top to bottom.")

(defvar drgnx-agent-settings--results nil
  "While the page is drawn: the last Test results, read once: ((KIND SECTION NAME FILE) . RESULT)….")

;;;; Small parts

(defun drgnx-agent-settings--events (kind)
  "The hook events of agent KIND, and whether only they may be given: (EVENTS . STRICT)."
  (pcase kind
    ('claude (cons drgnx-agent-config-claude-hook-events nil))
    ('codex (cons drgnx-agent-config-codex-hook-events nil))
    ('gemini (cons drgnx-agent-config-gemini--events t))
    ('kimi (cons drgnx-agent-config-kimi--hook-events t))))

(defun drgnx-agent-settings--key (item)
  "What identifies ITEM between reads (as the last Test results key it)."
  (list (plist-get item :kind) (plist-get item :section) (plist-get item :name) (plist-get item :file)))

(defun drgnx-agent-settings--ago (seconds)
  "SECONDS as a short age."
  (let ((s (max 0 (floor seconds))))
    (cond ((< s 60) "just now")
          ((< s 3600) (format "%dm ago" (/ s 60)))
          ((< s 86400) (format "%dh ago" (/ s 3600)))
          (t (format "%dd ago" (/ s 86400))))))

(defun drgnx-agent-settings--first-line (text &optional max)
  "The first line of TEXT, at most MAX (80) characters."
  (let ((line (car (split-string (or text "") "\n" t "[ \t\r]+")))
        (max (or max 80)))
    (cond ((null line) "")
          ((> (length line) max) (concat (substring line 0 (1- max)) "…"))
          (t line))))

(defun drgnx-agent-settings--secrets (item)
  "The secrets of ITEM, to mask its detail with."
  (ignore-errors (drgnx-agent-config-secrets (plist-get item :spec))))

(defun drgnx-agent-settings--mask (text item)
  "TEXT with ITEM's secrets masked."
  (drgnx-agent-config-mask-text (or text "") (drgnx-agent-settings--secrets item)))

(defun drgnx-agent-settings--names (pairs)
  "The names of PAIRS ((NAME . VALUE)…) as strings."
  (mapcar (lambda (p) (drgnx-agent-config-json-keystr (car p))) pairs))

(defun drgnx-agent-settings--button (label command &optional help)
  "Insert a button LABEL that runs COMMAND with point on the button's line."
  (insert-text-button label 'action (lambda (b) (goto-char (button-start b)) (call-interactively command))
                      'follow-link t 'help-echo help))

(defun drgnx-agent-settings--action-button (label action &optional help)
  "Insert a button LABEL that calls ACTION."
  (insert-text-button label 'action (lambda (_) (funcall action)) 'follow-link t 'help-echo help))

(defun drgnx-agent-settings--visit (file &optional line)
  "Show FILE (at LINE)."
  (pop-to-buffer (find-file-noselect file))
  (when line
    (goto-char (point-min))
    (forward-line (1- line))))

;;;; Status and detail of a row

(defun drgnx-agent-settings--cheap-status (item)
  "ITEM's status from its files (nothing is run; worked out when it was read), as text with a face."
  (pcase-let ((`(,status . ,detail) (plist-get item :cheap)))
    (pcase status
      ('ok (if (eq (plist-get item :section) 'mcp) (propertize "ok" 'face 'drgnx-agent-settings-ok) ""))
      ('missing-command (propertize "command not found" 'face 'drgnx-agent-settings-problem))
      ('no-url (propertize "no URL" 'face 'drgnx-agent-settings-problem))
      (_ (propertize (concat "unreadable: " (drgnx-agent-settings--first-line (drgnx-agent-settings--mask detail item) 60))
                     'face 'drgnx-agent-settings-problem)))))

(defun drgnx-agent-settings--test-status (item)
  "The last Test of ITEM with its age, or that it runs now; \"\" when it never ran."
  (if (gethash (drgnx-agent-settings--ref item) drgnx-agent-settings--running)
      (propertize "testing…" 'face 'drgnx-agent-settings-dim)
    (let* ((r (cdr (assoc (drgnx-agent-settings--key item) drgnx-agent-settings--results)))
           (age (and r (plist-get r :at) (concat "Test " (drgnx-agent-settings--ago (- (float-time) (plist-get r :at))) ": "))))
      (cond
       ((null r) "")
       ((eq (plist-get item :section) 'hook)
        (let ((exit (plist-get r :exit)))
          (concat (propertize (or age "Test: ") 'face 'drgnx-agent-settings-dim)
                  (cond ((plist-get r :timeout) (propertize "timed out" 'face 'drgnx-agent-settings-problem))
                        ((null exit) (propertize (drgnx-agent-settings--first-line (or (plist-get r :error) "did not run") 60)
                                                 'face 'drgnx-agent-settings-problem))
                        (t (propertize (format "exit %s" exit)
                                       'face (if (eql exit 0) 'drgnx-agent-settings-ok 'drgnx-agent-settings-problem)))))))
       (t
        (let ((status (plist-get r :status)) (tools (plist-get r :tools)))
          (concat (propertize (or age "Test: ") 'face 'drgnx-agent-settings-dim)
                  (pcase status
                    ('ok (propertize (format "ok, %d tool%s" (length tools) (if (= (length tools) 1) "" "s"))
                                     'face 'drgnx-agent-settings-ok))
                    ('needs-login (propertize "needs a login" 'face 'drgnx-agent-settings-warning))
                    ('timeout (propertize "no answer (timed out)" 'face 'drgnx-agent-settings-problem))
                    (_ (propertize (concat "failed: " (drgnx-agent-settings--first-line (plist-get r :error) 60))
                                   'face 'drgnx-agent-settings-problem))))))))))

(defun drgnx-agent-settings--status (item)
  "ITEM's status: off, read-only, inactive, its files' status, then its last Test."
  (string-join
   (seq-remove #'string-empty-p
               (list (if (plist-get item :enabled) "" (propertize "off" 'face 'drgnx-agent-settings-dim))
                     (if (plist-get item :readonly) (propertize "read-only" 'face 'drgnx-agent-settings-dim) "")
                     (if (plist-get item :inactive) (propertize "inactive" 'face 'drgnx-agent-settings-warning) "")
                     (drgnx-agent-settings--cheap-status item)
                     (drgnx-agent-settings--test-status item)))
   " · "))

(defun drgnx-agent-settings--detail (item)
  "The lines under ITEM's row: what it runs or where it is, its variables and headers by name only."
  (let* ((spec (plist-get item :spec)) (lines nil))
    (pcase (plist-get item :section)
      ('mcp
       (if (plist-get spec :command)
           (push (drgnx-agent-settings--mask
                  (combine-and-quote-strings (cons (plist-get spec :command) (append (plist-get spec :args) nil)))
                  item)
                 lines)
         (push (drgnx-agent-settings--mask (or (plist-get spec :url) "no URL") item) lines))
       (when-let* ((env (plist-get spec :env)))
         (push (concat "env: " (mapconcat (lambda (n) (concat n "=" drgnx-agent-config-mask))
                                          (drgnx-agent-settings--names env) " "))
               lines))
       (when-let* ((headers (plist-get spec :headers)))
         (push (concat "headers: " (mapconcat (lambda (n) (concat n ": " drgnx-agent-config-mask))
                                              (drgnx-agent-settings--names headers) ", "))
               lines))
       (when-let* ((names (plist-get spec :env-headers)))
         (push (concat "headers from the environment: "
                       (mapconcat #'identity (cl-mapcar (lambda (h v) (format "%s ($%s)" h v))
                                                        names (plist-get spec :env-header-vars))
                                  ", "))
               lines))
       (when-let* ((var (plist-get spec :bearer-env)))
         (push (format "token from $%s" var) lines)))
      ('hook
       (push (concat (if (plist-get spec :command)
                         (concat "runs: " (drgnx-agent-settings--mask (plist-get spec :command) item))
                       (format "a %s hook (shown, not run here)" (or (plist-get spec :hook-type) "non-command")))
                     (if (plist-get spec :timeout)
                         (format "  (timeout %s %s)" (plist-get spec :timeout)
                                 (if (eq (plist-get spec :timeout-unit) 'ms) "ms" "s"))
                       ""))
             lines))
      ('skill
       (let ((description (plist-get spec :description)))
         (push (if (string-empty-p (or description "")) (abbreviate-file-name (or (plist-get spec :dir) ""))
                 (drgnx-agent-settings--first-line description 100))
               lines))))
    (when-let* ((note (plist-get item :inactive))) (push note lines))
    (when-let* ((note (plist-get item :note))) (push note lines))
    (when-let* ((reason (plist-get item :reason))) (push reason lines))
    (nreverse lines)))

(defun drgnx-agent-settings--toggle-p (item)
  "Non-nil when ITEM can be turned on or off from the page."
  (pcase (plist-get item :section)
    ('skill (not (eq (plist-get item :kind) 'kimi)))
    ('mcp (and (memq (plist-get item :kind) '(codex kimi)) (not (plist-get item :readonly))))))

;;;; Drawing

(defun drgnx-agent-settings--insert-heading (title)
  (insert (propertize title 'face 'drgnx-agent-settings-heading)))

(defun drgnx-agent-settings--insert-agents ()
  "The row of agents (the shown one as a heading) and the rules files."
  (let ((kind drgnx-agent-settings--kind) (root drgnx-agent-settings--root) (first t))
    (dolist (k drgnx-agent-config-kinds)
      (unless first (insert (propertize " · " 'face 'drgnx-agent-settings-dim)))
      (setq first nil)
      (if (eq k kind)
          (drgnx-agent-settings--insert-heading (drgnx-agent-config-title k))
        (let ((k k))
          (drgnx-agent-settings--action-button (drgnx-agent-config-title k)
                                               (lambda () (drgnx-agent-settings-open k root))
                                               "Show this agent's settings"))))
    (insert "\n" (propertize "Rules: " 'face 'drgnx-agent-settings-dim))
    (if-let* ((rules (plist-get drgnx-agent-settings--data :rules)))
        (dolist (file rules)
          (let ((file file))
            (drgnx-agent-settings--action-button (abbreviate-file-name file)
                                                 (lambda () (drgnx-agent-settings--visit file))
                                                 "Open this rules file"))
          (insert "  "))
      (insert (propertize "none" 'face 'drgnx-agent-settings-dim)))
    (insert "\n" (if root
                     (concat (propertize "Project: " 'face 'drgnx-agent-settings-dim) (abbreviate-file-name root))
                   (propertize "No project: the user's settings only" 'face 'drgnx-agent-settings-dim))
            "\n")))

(defun drgnx-agent-settings--insert-problems ()
  "Files that do not parse, with the line."
  (when-let* ((problems (plist-get drgnx-agent-settings--data :problems)))
    (insert "\n")
    (drgnx-agent-settings--insert-heading "Problems")
    (insert "\n")
    (pcase-dolist (`(,file ,line ,message) problems)
      (let ((start (point)))
        (insert "  " (propertize (format "%s%s: %s (nothing is written to it)" (abbreviate-file-name file)
                                         (if line (format ", line %s" line) "") (or message "unreadable"))
                                 'face 'drgnx-agent-settings-problem)
                "  ")
        (let ((file file) (line line))
          (drgnx-agent-settings--action-button "[Open]" (lambda () (drgnx-agent-settings--visit file line))))
        (insert "\n")
        (put-text-property start (point) 'drgnx-agent-settings-file (cons file line))))))

(defun drgnx-agent-settings--billing (route)
  "How ROUTE is paid for, in words."
  (pcase (plist-get route :billing)
    ('subscription "flat: your subscription")
    ('openrouter "per token through OpenRouter, plus its fee")
    ('local "local: no cost")
    (_ (format "per token, billed by %s" (or (plist-get route :vendor) "the provider")))))

(defun drgnx-agent-settings--route-provider (route)
  "The drgnx provider id whose key ROUTE uses (a direct key drgnx can store), or nil."
  (when-let* ((kind (plist-get route :kind))
              ((not (eq (plist-get route :billing) 'local)))
              (first (car (ignore-errors (drgnx-ai-agent-gateway-chain kind))))
              (provider (ignore-errors (drgnx-ai-provider (car first)))))
    (and (plist-get provider :key-env) (car first))))

(defun drgnx-agent-settings--store-key (id)
  "Read the key of provider ID (hidden) and keep it in the system's secret store."
  (require 'drgnx-ai)
  (let ((key (read-passwd (format "Key for %s (kept in your %s): " (or (plist-get (drgnx-ai-provider id) :name) id)
                                  (if (eq system-type 'darwin) "Keychain" "keyring")))))
    (unwind-protect
        (if (string-empty-p key)
            (message "No key given; nothing was stored")
          (message "The key is in your %s" (drgnx-ai-store-key id key)))
      (clear-string key))))

(defun drgnx-agent-settings--insert-routes ()
  "One line per route: name, URL and model, where the key is, billing; notes about overrides."
  (insert "\n")
  (drgnx-agent-settings--insert-heading "Routes")
  (insert "\n")
  (let ((routes (plist-get drgnx-agent-settings--data :routes)))
    (unless routes (insert (propertize "  none\n" 'face 'drgnx-agent-settings-dim)))
    (dolist (route routes)
      (let ((where (string-join (delq nil (list (plist-get route :base-url) (plist-get route :model))) " · ")))
        (insert "  " (or (plist-get route :profile) "?")
                (if (string-empty-p where) "" (concat "  " where))
                "  " (drgnx-agent-settings--billing route))
        (when-let* ((id (drgnx-agent-settings--route-provider route)))
          (insert "  ")
          (drgnx-agent-settings--action-button "[Store key…]" (lambda () (drgnx-agent-settings--store-key id))
                                               "Keep this provider's key in your Keychain or keyring"))
        (insert "\n")
        (when-let* ((key (plist-get route :key-where)))
          (insert (propertize (concat "      key: " key) 'face 'drgnx-agent-settings-dim) "\n"))
        (when-let* ((launch (plist-get route :launch)))
          (insert (propertize (concat "      run: " launch) 'face 'drgnx-agent-settings-dim) "\n")))))
  (dolist (note (plist-get drgnx-agent-settings--data :notes))
    (insert "  " (propertize (concat "! " note) 'face 'drgnx-agent-settings-warning) "\n")))

(defun drgnx-agent-settings--insert-item (item width)
  "ITEM's row, its buttons and its detail lines; the name padded to WIDTH."
  (let ((start (point)) (section (plist-get item :section)))
    (insert "  " (string-pad (plist-get item :name) width) "  "
            (propertize (string-pad (symbol-name (plist-get item :from)) 9) 'face 'drgnx-agent-settings-dim) " ")
    (let ((status (drgnx-agent-settings--status item)))
      (unless (string-empty-p status) (insert status "  ")))
    (when (eq section 'mcp)
      (drgnx-agent-settings--button "[Test]" #'drgnx-agent-settings-test "Start the server and list its tools")
      (insert " "))
    (when (and (eq section 'hook) (plist-get (plist-get item :spec) :command))
      (drgnx-agent-settings--button "[Test (runs the command)]" #'drgnx-agent-settings-test
                                    "Run the hook's command for real, with a sample event")
      (insert " "))
    (unless (or (plist-get item :readonly) (eq section 'skill))
      (drgnx-agent-settings--button "[Edit…]" #'drgnx-agent-settings-edit)
      (insert " ")
      (drgnx-agent-settings--button "[Remove…]" #'drgnx-agent-settings-remove)
      (insert " "))
    (when (drgnx-agent-settings--toggle-p item)
      (drgnx-agent-settings--button (if (plist-get item :enabled) "[Turn off]" "[Turn on]") #'drgnx-agent-settings-toggle)
      (insert " "))
    (drgnx-agent-settings--button "[Open]" #'drgnx-agent-settings-open-file "Its file, at its line")
    (insert "\n")
    (dolist (line (drgnx-agent-settings--detail item))
      (insert (make-string (+ 4 width) ?\s) (propertize line 'face 'drgnx-agent-settings-dim) "\n"))
    ;; only the key: a copy of the text (kill-ring-save, yank) must never carry the item
    (put-text-property start (point) 'drgnx-agent-settings-item (drgnx-agent-settings--ref item))))

(defun drgnx-agent-settings--insert-section (section title)
  "The SECTION of the page under TITLE, with its buttons and rows."
  (let ((start (point))
        (items (seq-filter (lambda (i) (eq (plist-get i :section) section)) (plist-get drgnx-agent-settings--data :items))))
    (insert "\n")
    (drgnx-agent-settings--insert-heading title)
    (insert "  ")
    (if (eq section 'skill)
        (drgnx-agent-settings--button "[New Skill…]" #'drgnx-agent-settings-new-skill)
      (drgnx-agent-settings--button "[Add…]" #'drgnx-agent-settings-add))
    (when (eq section 'mcp)
      (insert " ")
      (drgnx-agent-settings--button "[Test All]" #'drgnx-agent-settings-test-all "Test the MCP servers the agent would start (the project's asked first)"))
    (insert "\n")
    (if (null items)
        (insert (propertize "  none\n" 'face 'drgnx-agent-settings-dim))
      (let ((width (min 32 (apply #'max (mapcar (lambda (i) (string-width (plist-get i :name))) items)))))
        (dolist (item items) (drgnx-agent-settings--insert-item item width))))
    (put-text-property start (point) 'drgnx-agent-settings-section section)))

(defun drgnx-agent-settings--render ()
  "Draw the page from what was read last; only the last Test results are read here (once)."
  (let ((inhibit-read-only t)
        (drgnx-agent-settings--results (ignore-errors (drgnx-agent-check-results))))
    (erase-buffer)
    (drgnx-agent-settings--insert-agents)
    (drgnx-agent-settings--insert-problems)
    (drgnx-agent-settings--insert-routes)
    (pcase-dolist (`(,section . ,title) drgnx-agent-settings--sections)
      (drgnx-agent-settings--insert-section section title))))

(defun drgnx-agent-settings--redraw ()
  "Draw the page again, each window's point and start on the same line."
  (let* ((windows (get-buffer-window-list (current-buffer) nil t))
         (line (line-number-at-pos)) (column (current-column))
         (places (mapcar (lambda (w) (list w (line-number-at-pos (window-point w)) (line-number-at-pos (window-start w))))
                         windows))
         (drgnx-wb--owned (append windows (and (boundp 'drgnx-wb--owned) drgnx-wb--owned))))
    (drgnx-agent-settings--render)
    (cl-flet ((at (n) (save-excursion (goto-char (point-min)) (forward-line (1- n)) (point))))
      (goto-char (at line))
      (move-to-column column)
      (pcase-dolist (`(,w ,pt ,start) places)
        (set-window-start w (at start) t)
        (set-window-point w (at pt))))))

(defun drgnx-agent-settings--sanitize (item)
  "ITEM as the page keeps it: environment and header values gone, the command, arguments, URL and problem masked,
and its status from the files (`:cheap', worked out from the whole ITEM).  Test and the edits read the item again."
  (let* ((spec (plist-get item :spec))
         (secrets (drgnx-agent-settings--secrets item))
         (mask (lambda (s) (if (stringp s) (drgnx-agent-config-mask-text s secrets) s)))
         (names (lambda (pairs) (mapcar (lambda (p) (list (drgnx-agent-config-json-keystr (car p)))) pairs)))
         (safe (copy-sequence spec))
         (out (copy-sequence item))
         (cheap (drgnx-agent-config-cheap-status item)))
    (dolist (key '(:env :headers))
      (when (plist-get safe key) (setq safe (plist-put safe key (funcall names (plist-get safe key))))))
    (dolist (key '(:command :url :description))
      (when (plist-get safe key) (setq safe (plist-put safe key (funcall mask (plist-get safe key))))))
    (when (plist-get safe :args)
      (setq safe (plist-put safe :args (mapcar mask (append (plist-get safe :args) nil)))))
    (when spec (setq out (plist-put out :spec safe)))
    (when (plist-get out :problem) (setq out (plist-put out :problem (funcall mask (plist-get out :problem)))))
    (plist-put out :cheap (cons (car cheap) (funcall mask (cdr cheap))))))

(defun drgnx-agent-settings--number (items)
  "ITEMS, each with `:ordinal': its rank among the items with the same key (two hooks of one event and matcher in
one file share a key)."
  (let ((seen (make-hash-table :test #'equal)))
    (mapcar (lambda (item)
              (let* ((key (drgnx-agent-settings--key item)) (n (gethash key seen 0)))
                (puthash key (1+ n) seen)
                (plist-put (copy-sequence item) :ordinal n)))
            items)))

(defun drgnx-agent-settings--ref (item)
  "What a row of the page points to: (KEY . ORDINAL)."
  (cons (drgnx-agent-settings--key item) (plist-get item :ordinal)))

(defun drgnx-agent-settings--read-config ()
  "Everything the agent has configured, as `drgnx-agent-config-read' gives it, the items numbered; an unexpected
error is signalled as `drgnx-agent-config-unreadable' with a fixed message (its own text may quote a file)."
  (let ((data (condition-case nil
                  (drgnx-agent-config-read drgnx-agent-settings--kind drgnx-agent-settings--root)
                (error (signal 'drgnx-agent-config-unreadable
                               (list (drgnx-agent-config-home drgnx-agent-settings--kind) nil "could not be read"))))))
    (plist-put (copy-sequence data) :items (drgnx-agent-settings--number (plist-get data :items)))))

(defun drgnx-agent-settings--read ()
  "Read the agent's settings for the page (files only); the page keeps them without secret values."
  (let ((data (condition-case err
                  (drgnx-agent-settings--read-config)
                (drgnx-agent-config-unreadable (list :problems (list (cdr err)))))))
    (setq drgnx-agent-settings--data
          (plist-put data :items (mapcar #'drgnx-agent-settings--sanitize (plist-get data :items))))))

(defun drgnx-agent-settings--fresh-items ()
  "The items as their files hold them now (with their values); a `user-error' when they cannot be read."
  (condition-case nil
      (plist-get (drgnx-agent-settings--read-config) :items)
    (drgnx-agent-config-unreadable
     (user-error "%s's settings could not be read: Refresh (g)" (drgnx-agent-config-title drgnx-agent-settings--kind)))))

(defun drgnx-agent-settings--match (item items)
  "The one of ITEMS (read just now) that the page's ITEM shows, when it is still as the page shows it, else nil."
  (when-let* ((found (seq-find (lambda (i) (equal (drgnx-agent-settings--ref i) (drgnx-agent-settings--ref item)))
                               items)))
    (let ((clean (drgnx-agent-settings--sanitize found)))
      (and (cl-every (lambda (p) (equal (plist-get clean p) (plist-get item p))) '(:spec :enabled :inactive :from))
           found))))

(defun drgnx-agent-settings--fresh (item)
  "ITEM as its file holds it now (with its values), for a Test or a write.  A `user-error' when it is gone or is
no longer what the page shows (what was confirmed must be what runs)."
  (or (drgnx-agent-settings--match item (drgnx-agent-settings--fresh-items))
      (user-error "%s changed on disk: Refresh (g)" (plist-get item :name))))

(defun drgnx-agent-settings--filter-substring (beg end &optional delete)
  "`filter-buffer-substring-function' of a page: copied text carries none of the page's own properties."
  (let ((text (buffer-substring--filter beg end delete)))
    (remove-list-of-text-properties
     0 (length text) '(drgnx-agent-settings-item drgnx-agent-settings-section drgnx-agent-settings-file action button
                                                 category follow-link help-echo)
     text)
    text))

;;;; The page

(defvar drgnx-agent-settings-mode-map
  (let ((m (make-sparse-keymap))) (set-keymap-parent m special-mode-map) m)
  "Keys come from the key profiles (the Agent Settings commands).")

(define-derived-mode drgnx-agent-settings-mode special-mode "Agent Settings"
  "An agent's routes, MCP servers, hooks and skills: add, edit, remove, turn on or off, Test."
  (setq-local truncate-lines t
              revert-buffer-function (lambda (&rest _) (drgnx-agent-settings-refresh))
              filter-buffer-substring-function #'drgnx-agent-settings--filter-substring))

(defun drgnx-agent-settings--buffer (kind)
  (get-buffer-create (format "*agent settings: %s*" (drgnx-agent-config-title kind))))

(defun drgnx-agent-settings--usable-root (dir)
  "DIR as a project for a page: a local directory name, or nil."
  (and dir (not (file-remote-p dir)) (file-name-as-directory (expand-file-name dir))))

(defun drgnx-agent-settings-open (kind &optional root)
  "Show the settings page of agent KIND for the project ROOT (nil: the user's settings only); the buffer."
  (let ((buffer (drgnx-agent-settings--buffer kind)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'drgnx-agent-settings-mode) (drgnx-agent-settings-mode))
      (setq drgnx-agent-settings--kind kind
            drgnx-agent-settings--root (drgnx-agent-settings--usable-root root))
      (drgnx-agent-settings--read)
      (drgnx-agent-settings--render)
      (goto-char (point-min)))
    (pop-to-buffer buffer)
    buffer))

(defun drgnx-agent-settings--page ()
  (unless (derived-mode-p 'drgnx-agent-settings-mode) (user-error "Not an agent settings page"))
  (current-buffer))

(defun drgnx-agent-settings--item-at-point (&optional what)
  "The item on this line, as the page keeps it (no secret values); a `user-error' naming WHAT when there is none."
  (drgnx-agent-settings--page)
  (let ((ref (or (get-text-property (point) 'drgnx-agent-settings-item)
                 (get-text-property (line-beginning-position) 'drgnx-agent-settings-item))))
    (or (and ref (seq-find (lambda (i) (equal (drgnx-agent-settings--ref i) ref))
                           (plist-get drgnx-agent-settings--data :items)))
        (user-error "No MCP server, hook or skill on this line%s" (if what (concat " to " what) "")))))

(defun drgnx-agent-settings--refresh-buffer (buffer)
  "Read BUFFER's agent settings again and redraw it (never asks)."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (drgnx-agent-settings--read)
      (drgnx-agent-settings--redraw))))

;;;; Which agent

(defun drgnx-agent-settings--kind-of-profile (name)
  "The agent kind the agent profile NAME runs, or nil."
  (let* ((plist (cdr (ignore-errors (drgnx-agents-profile name))))
         (program (file-name-nondirectory (or (car (plist-get plist :command)) ""))))
    (cond ((string-match-p "\\`claude" program) 'claude)
          ((string-match-p "codex" program) 'codex)
          ((string-match-p "gemini" program) 'gemini)
          ((string-match-p "kimi" program) 'kimi))))

(defun drgnx-agent-settings--session-at-point ()
  "The agent session of this transcript, or of this row of the Agents list, or nil."
  (cond ((and (derived-mode-p 'tabulated-list-mode) (fboundp 'drgnx-agent-session-p))
         (let ((id (tabulated-list-get-id))) (and (drgnx-agent-session-p id) id)))
        ((bound-and-true-p drgnx-agents-ui--session))))

(defun drgnx-agent-settings--of-session (session)
  "(KIND ROOT) for SESSION, or nil when its profile is not one of the four agents."
  (when-let* ((kind (drgnx-agent-settings--kind-of-profile (drgnx-agent-session-profile session))))
    (list kind (drgnx-agent-settings--usable-root (drgnx-agent-session-cwd session)))))

(defun drgnx-agent-settings--project ()
  "This buffer's project root (a local one), or nil."
  (unless (file-remote-p default-directory)
    (when-let* ((project (and (require 'project nil t) (project-current))))
      (drgnx-agent-settings--usable-root (project-root project)))))

(defun drgnx-agent-settings--ask-kind (prompt &optional except)
  "An agent kind read with PROMPT (EXCEPT left out); Claude Code by default."
  (let* ((kinds (remq except drgnx-agent-config-kinds))
         (titles (mapcar #'drgnx-agent-config-title kinds))
         (default (car (member "Claude Code" titles)))
         (title (completing-read (format-prompt prompt (or default (car titles))) titles nil t nil nil
                                 (or default (car titles)))))
    (or (cl-find title kinds :key #'drgnx-agent-config-title :test #'equal)
        (user-error "No such agent: %s" title))))

;;;; Commands

(defun drgnx-agent-settings (kind &optional root)
  "Show the settings of agent KIND for the project ROOT.
Interactively: the agent of the session at point (in the Agents list or a transcript), else asked."
  (interactive
   (or (when-let* ((session (drgnx-agent-settings--session-at-point))) (drgnx-agent-settings--of-session session))
       (list (drgnx-agent-settings--ask-kind "Agent settings for") (drgnx-agent-settings--project))))
  (drgnx-agent-settings-open kind root))

(defun drgnx-agent-settings-here ()
  "Show the settings of the agent of the session at point (its project)."
  (interactive)
  (let ((session (or (drgnx-agent-settings--session-at-point) (user-error "No agent session here"))))
    (apply #'drgnx-agent-settings-open
           (or (drgnx-agent-settings--of-session session)
               (user-error "Profile %s is not Claude Code, Codex, Gemini or Kimi Code"
                           (drgnx-agent-session-profile session))))))

(defun drgnx-agent-settings-refresh ()
  "Read the agent's files again and redraw the page (nothing is started)."
  (interactive)
  (drgnx-agent-settings--refresh-buffer (drgnx-agent-settings--page)))

(defun drgnx-agent-settings-other ()
  "Show another agent's settings, for the same project."
  (interactive)
  (drgnx-agent-settings--page)
  (drgnx-agent-settings-open (drgnx-agent-settings--ask-kind "Agent" drgnx-agent-settings--kind)
                             drgnx-agent-settings--root))

(defun drgnx-agent-settings-open-file ()
  "Open the file the item (or problem) on this line comes from, at its line."
  (interactive)
  (drgnx-agent-settings--page)
  (if-let* ((problem (get-text-property (line-beginning-position) 'drgnx-agent-settings-file)))
      (drgnx-agent-settings--visit (car problem) (cdr problem))
    (let ((item (drgnx-agent-settings--item-at-point "open")))
      (unless (plist-get item :file) (user-error "%s has no file" (plist-get item :name)))
      (drgnx-agent-settings--visit (plist-get item :file) (plist-get item :line)))))

;;;;; Test

(defun drgnx-agent-settings--start-test (item)
  "Test ITEM in its own process; the page shows the result when it comes."
  (let ((key (drgnx-agent-settings--ref item))
        (buffer (current-buffer))
        (root (or drgnx-agent-settings--root (expand-file-name "~/"))))
    (puthash key t drgnx-agent-settings--running)
    (condition-case err
        (funcall (if (eq (plist-get item :section) 'hook) #'drgnx-agent-check-hook #'drgnx-agent-check-mcp)
                 item root
                 (lambda (result)
                   ;; from a process: never asks, never fails out
                   (remhash key drgnx-agent-settings--running)
                   (with-demoted-errors "Agent settings: keeping the Test result failed: %S"
                     (drgnx-agent-check-remember item result))
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer (drgnx-agent-settings--redraw)))))
      (error (remhash key drgnx-agent-settings--running)
             (signal (car err) (cdr err))))
    (drgnx-agent-settings--redraw)))

(defun drgnx-agent-settings--runs (item)
  "What the MCP server ITEM (as the page keeps it: masked) starts or reaches."
  (let ((spec (plist-get item :spec)))
    (if (plist-get spec :command)
        (combine-and-quote-strings (cons (plist-get spec :command) (append (plist-get spec :args) nil)))
      (or (plist-get spec :url) "no URL"))))

(defun drgnx-agent-settings-test ()
  "Test the MCP server on this line (start it, list its tools), or run the hook on this line for real.
A server from the project's files, or an inactive one (that the agent ignores, such as an untrusted project's), is
started only after a confirmation that shows what it starts."
  (interactive)
  (let ((item (drgnx-agent-settings--item-at-point "test")))
    (pcase (plist-get item :section)
      ('mcp
       (when (or (not (or (plist-get item :inactive) (eq (plist-get item :from) 'project)))
                 (yes-or-no-p (format "%s is %s. Start %s? " (plist-get item :name)
                                      (string-join
                                       (delq nil (list (and (eq (plist-get item :from) 'project) "from the project's files")
                                                       (and (plist-get item :inactive)
                                                            (concat "inactive: " (plist-get item :inactive)))))
                                       " and ")
                                      (drgnx-agent-settings--runs item))))
         (drgnx-agent-settings--start-test (drgnx-agent-settings--fresh item))))
      ('hook
       (let ((command (plist-get (plist-get item :spec) :command)))
         (unless command (user-error "This hook runs no command"))
         (when (yes-or-no-p (format "Run %s for real? " command))
           (drgnx-agent-settings--start-test (drgnx-agent-settings--fresh item)))))
      (_ (user-error "A skill has nothing to test")))))

(defun drgnx-agent-settings-test-all ()
  "Test the MCP servers on the page that the agent would start: inactive and off ones are skipped, and the project's
own servers (from files in the project) start only after one confirmation.  Hooks are never run here: they run for
real, so each is tested on its own."
  (interactive)
  (drgnx-agent-settings--page)
  (let* ((all (seq-filter (lambda (i) (and (eq (plist-get i :section) 'mcp)
                                           (not (gethash (drgnx-agent-settings--ref i) drgnx-agent-settings--running))))
                          (plist-get drgnx-agent-settings--data :items)))
         (skip-p (lambda (i) (or (plist-get i :inactive) (not (plist-get i :enabled)))))
         (skipped (seq-filter skip-p all))
         (servers (seq-difference all skipped #'eq))
         (project (seq-filter (lambda (i) (eq (plist-get i :from) 'project)) servers))
         (declined nil)
         (changed 0)
         (started 0))
    (when (and project
               (not (yes-or-no-p (format "Start %s from the project's files: %s? "
                                         (if (cdr project) (format "%d servers" (length project)) "a server")
                                         (mapconcat (lambda (i) (format "%s (%s)" (plist-get i :name)
                                                                        (drgnx-agent-settings--runs i)))
                                                    project "; ")))))
      (setq servers (seq-difference servers project #'eq)
            declined (length project)))
    (when servers
      (let ((fresh (drgnx-agent-settings--fresh-items)))
        (dolist (i servers)
          ;; what runs is what the page showed and was confirmed: a server changed on disk is skipped, and the
          ;; file's own state is checked again
          (let ((item (drgnx-agent-settings--match i fresh)))
            (cond ((or (null item) (funcall skip-p item)
                       (and (eq (plist-get item :from) 'project) (not (memq i project))))
                   (cl-incf changed))
                  (t (cl-incf started) (drgnx-agent-settings--start-test item)))))))
    (message "%s%s%s%s"
             (if (> started 0) (format "Testing %d MCP server%s" started (if (= started 1) "" "s")) "No MCP server tested")
             (if skipped (format "; %d skipped (inactive or off)" (length skipped)) "")
             (if (> changed 0) (format "; %d skipped (changed on disk: Refresh)" changed) "")
             (if declined (format "; %d project server%s not started" declined (if (= declined 1) "" "s")) ""))))

;;;;; Writing

(defun drgnx-agent-settings--write (op item scope)
  "Do OP with ITEM in SCOPE through the agent's files; say how it went and read the page again."
  (let ((buffer (current-buffer)))
    (drgnx-agent-config-write drgnx-agent-settings--kind op item scope drgnx-agent-settings--root
                              (lambda (result)
                                ;; at once, or later from the agent's CLI: never asks
                                (message "%s" (or (plist-get result :error) (plist-get result :note) "Done"))
                                (drgnx-agent-settings--refresh-buffer buffer)))))

(defun drgnx-agent-settings--ask-scope (section)
  "Where a new item of SECTION goes: a scope of `drgnx-agent-config-scopes' (asked when there is a choice)."
  (let* ((scopes (drgnx-agent-config-scopes drgnx-agent-settings--kind section drgnx-agent-settings--root))
         (labels (mapcar (lambda (s) (format "%s — %s" (nth 1 s) (abbreviate-file-name (or (nth 2 s) "")))) scopes)))
    (cond ((null scopes) (user-error "No place to add this"))
          ((null (cdr scopes)) (car (car scopes)))
          (t (let ((choice (completing-read (format-prompt "Where" (car labels)) labels nil t nil nil (car labels))))
               (car (nth (or (cl-position choice labels :test #'equal) (user-error "No such place")) scopes)))))))

(defun drgnx-agent-settings--ask-pairs (what old)
  "Names and values of WHAT (\"Environment variables\" or \"Headers\"), OLD ((NAME . VALUE)…) being the current ones.
The names are edited as text; each value is read with `read-passwd', and an empty answer keeps the current value."
  (let* ((old (mapcar (lambda (p) (cons (drgnx-agent-config-json-keystr (car p)) (cdr p))) old))
         (names (split-string (read-string (format "%s, names separated by spaces (empty: none): " what)
                                           (string-join (mapcar #'car old) " "))
                              nil t))
         (out nil))
    (dolist (name names (nreverse out))
      (let* ((current (assoc name old))
             (value (read-passwd (if current (format "%s (empty: keep the current value): " name) (format "%s: " name)))))
        (cond ((not (string-empty-p value)) (push (cons name (prog1 (copy-sequence value) (clear-string value))) out))
              (current (push current out))
              (t (message "%s left out: it has no value" name)))))))

(defun drgnx-agent-settings--ask-text (prompt current item)
  "Read PROMPT; with CURRENT (ITEM's), an empty answer keeps it, and the prompt shows it masked.
The answer may hold a secret (a token in a command line or URL): it is kept out of the minibuffer history."
  (let ((answer (let ((history-add-new-input nil))
                  (read-string (if current
                                   (format "%s (empty: keep %s): " prompt (drgnx-agent-settings--mask current item))
                                 (format "%s: " prompt))))))
    (if (string-empty-p answer) current answer)))

(defun drgnx-agent-settings--ask-mcp (old)
  "A server's name and spec from the minibuffer: (NAME . SPEC).  OLD: the item edited, or nil."
  (let* ((spec (copy-sequence (plist-get old :spec)))
         (name (read-string (format-prompt "Name" (plist-get old :name)) nil nil (plist-get old :name)))
         (types (if (eq drgnx-agent-settings--kind 'codex) '("stdio" "http") '("stdio" "http" "sse")))
         (current (and old (symbol-name (or (plist-get spec :type) (if (plist-get spec :url) 'http 'stdio)))))
         (type (intern (completing-read (format-prompt "Transport" (or current "stdio")) types nil t nil nil
                                        (or current "stdio")))))
    (when (string-empty-p name) (user-error "A server needs a name"))
    (if (eq type 'stdio)
        (let* ((was (and (plist-get spec :command)
                         (combine-and-quote-strings (cons (plist-get spec :command) (append (plist-get spec :args) nil)))))
               (line (drgnx-agent-settings--ask-text "Command line" was old))
               (argv (and line (split-string-shell-command line))))
          (unless argv (user-error "A stdio server needs a command"))
          (unless (equal line was)
            (setq spec (plist-put spec :command (car argv))
                  spec (plist-put spec :args (cdr argv))))
          (setq spec (plist-put spec :env (drgnx-agent-settings--ask-pairs "Environment variables" (plist-get spec :env)))
                spec (plist-put spec :url nil)
                spec (plist-put spec :headers nil)))
      (let ((url (drgnx-agent-settings--ask-text "URL" (plist-get spec :url) old)))
        (unless url (user-error "An %s server needs a URL" type))
        (setq spec (plist-put spec :url url)
              spec (plist-put spec :headers (drgnx-agent-settings--ask-pairs "Headers" (plist-get spec :headers)))
              spec (plist-put spec :command nil)
              spec (plist-put spec :args nil)
              spec (plist-put spec :env nil))))
    (cons name (plist-put spec :type type))))

(defun drgnx-agent-settings--ask-hook (old)
  "A hook's name and spec from the minibuffer: (NAME . SPEC).  OLD: the item edited, or nil."
  (let* ((spec (copy-sequence (plist-get old :spec)))
         (events (drgnx-agent-settings--events drgnx-agent-settings--kind))
         (default (or (plist-get spec :event) (car (car events))))
         (event (completing-read (format-prompt "Event" default) (car events) nil (cdr events) nil nil default))
         (matcher (read-string "Matcher (empty: every tool or source): " (plist-get spec :matcher)))
         (command (drgnx-agent-settings--ask-text "Command" (plist-get spec :command) old))
         (unit (if (eq drgnx-agent-settings--kind 'gemini) "milliseconds" "seconds"))
         (timeout (string-trim
                   (read-string (if (plist-get spec :timeout)
                                    (format "Timeout in %s (empty: keep %s; none or 0: no timeout): " unit
                                            (plist-get spec :timeout))
                                  (format "Timeout in %s (empty, none or 0: no timeout): " unit))))))
    (unless command (user-error "A hook needs a command"))
    (setq spec (plist-put spec :event event)
          spec (plist-put spec :matcher (and (not (string-empty-p matcher)) matcher))
          spec (plist-put spec :command command))
    (cond ((string-empty-p timeout))
          ((member (downcase timeout) '("none" "0")) (setq spec (plist-put spec :timeout nil)))
          ((string-match-p "\\`[0-9]+\\'" timeout) (setq spec (plist-put spec :timeout (string-to-number timeout))))
          (t (user-error "A timeout is a whole number of %s, or none" unit)))
    (cons (if (plist-get spec :matcher) (format "%s %s" event (plist-get spec :matcher)) event) spec)))

(defun drgnx-agent-settings--section-here ()
  "The section on this line, or asked."
  (or (get-text-property (point) 'drgnx-agent-settings-section)
      (get-text-property (line-beginning-position) 'drgnx-agent-settings-section)
      (let* ((choices '(("MCP server" . mcp) ("Hook" . hook) ("Skill" . skill)))
             (choice (completing-read "Add: " choices nil t)))
        (or (cdr (assoc choice choices)) (user-error "Nothing to add")))))

(defun drgnx-agent-settings-add ()
  "Add an MCP server, a hook or a skill (the section on this line, else asked): first where, then what."
  (interactive)
  (drgnx-agent-settings--page)
  (let ((section (drgnx-agent-settings--section-here)))
    (if (eq section 'skill)
        (drgnx-agent-settings-new-skill)
      (let* ((scope (drgnx-agent-settings--ask-scope section))
             (answer (if (eq section 'mcp) (drgnx-agent-settings--ask-mcp nil) (drgnx-agent-settings--ask-hook nil))))
        (drgnx-agent-settings--write 'add (list :kind drgnx-agent-settings--kind :section section :name (car answer)
                                                :from scope :spec (cdr answer) :enabled t)
                                     scope)))))

(defun drgnx-agent-settings--refuse-read-only (item)
  (when (plist-get item :readonly)
    (user-error "%s is read-only here (from %s%s)" (plist-get item :name) (plist-get item :from)
                (if (plist-get item :reason) (concat ": " (plist-get item :reason)) ""))))

(defun drgnx-agent-settings-edit ()
  "Change the MCP server or hook on this line (a skill: open its SKILL.md), in the file it is in."
  (interactive)
  (let ((item (drgnx-agent-settings--item-at-point "edit")))
    (if (eq (plist-get item :section) 'skill)
        (drgnx-agent-settings--visit (plist-get item :file))
      (drgnx-agent-settings--refuse-read-only item)
      ;; the item with its values, as the file holds it now: an empty answer keeps them
      (let* ((item (drgnx-agent-settings--fresh item))
             (answer (if (eq (plist-get item :section) 'mcp)
                         (drgnx-agent-settings--ask-mcp item)
                       (drgnx-agent-settings--ask-hook item)))
             (new (copy-sequence item)))
        (setq new (plist-put new :name (car answer))
              new (plist-put new :spec (cdr answer))
              new (plist-put new :replaces item))
        (drgnx-agent-settings--write 'edit new (plist-get item :from))))))

(defun drgnx-agent-settings-remove ()
  "Remove the MCP server or hook on this line from its file, after a confirmation."
  (interactive)
  (let ((item (drgnx-agent-settings--item-at-point "remove")))
    (when (eq (plist-get item :section) 'skill)
      (user-error "A skill is removed by deleting its folder: %s"
                  (abbreviate-file-name (or (plist-get (plist-get item :spec) :dir) ""))))
    (drgnx-agent-settings--refuse-read-only item)
    (when (yes-or-no-p (format "Remove %s from %s? " (plist-get item :name)
                               (abbreviate-file-name (or (plist-get item :file) "its file"))))
      (drgnx-agent-settings--write 'remove (drgnx-agent-settings--fresh item) (plist-get item :from)))))

(defun drgnx-agent-settings-toggle ()
  "Turn the MCP server or skill on this line on or off."
  (interactive)
  (let ((item (drgnx-agent-settings--fresh (drgnx-agent-settings--item-at-point "turn on or off"))))
    (drgnx-agent-settings--write 'toggle item (and (eq (plist-get item :section) 'mcp) (plist-get item :from)))))

(defun drgnx-agent-settings-new-skill ()
  "Create a skill (a SKILL.md with its name and description): first where, then its name."
  (interactive)
  (drgnx-agent-settings--page)
  (let* ((scope (drgnx-agent-settings--ask-scope 'skill))
         (name (read-string "Skill name (lowercase letters, digits and hyphens): "))
         (description (read-string "Description (when the agent should use it): ")))
    (drgnx-agent-settings--write 'add (list :kind drgnx-agent-settings--kind :section 'skill :name name :from scope
                                            :spec (list :description description) :enabled t)
                                 scope)))

;;;; The module

(defun drgnx-agent-settings--on-page-p () (derived-mode-p 'drgnx-agent-settings-mode))

(defun drgnx-agent-settings--setup ()
  (when (fboundp 'drgnx-wb-place) (drgnx-wb-place 'drgnx-agent-settings-mode 'editor))
  (drgnx-command-define 'agent-settings :category "Agents" :title "Settings" :command #'drgnx-agent-settings
                        :doc "An agent's routes, MCP servers, hooks and skills: Claude Code, Codex, Gemini, Kimi Code")
  (drgnx-command-define 'agent-settings-here :category "Agents" :title "Settings of This Agent"
                        :command #'drgnx-agent-settings-here :map '(drgnx-agents-ui . drgnx-agents-list-mode-map)
                        :doc "The settings page of the session's agent, for its project"
                        :when #'drgnx-agent-settings--session-at-point)
  (pcase-dolist (`(,id ,title ,fn ,doc)
                 '((agent-settings-refresh "Refresh" drgnx-agent-settings-refresh "Read the agent's files again")
                   (agent-settings-test "Test" drgnx-agent-settings-test
                                        "Start the MCP server and list its tools, or run the hook for real (asked first)")
                   (agent-settings-test-all "Test All" drgnx-agent-settings-test-all
                                            "Test the page's MCP servers: inactive and off ones skipped, the project's asked first")
                   (agent-settings-add "Add…" drgnx-agent-settings-add "An MCP server, a hook or a skill: where, then what")
                   (agent-settings-edit "Edit…" drgnx-agent-settings-edit "Change this MCP server or hook in its file")
                   (agent-settings-remove "Remove…" drgnx-agent-settings-remove "Take this MCP server or hook out of its file")
                   (agent-settings-toggle "Turn On or Off" drgnx-agent-settings-toggle "This MCP server or skill")
                   (agent-settings-new-skill "New Skill…" drgnx-agent-settings-new-skill "A SKILL.md with its name and description")
                   (agent-settings-open-file "Open Its File" drgnx-agent-settings-open-file "The file this line comes from")
                   (agent-settings-other "Other Agent…" drgnx-agent-settings-other "Another agent's settings, same project")))
    (drgnx-command-define id :category "Agent Settings" :title title :command fn :doc doc
                          :map '(drgnx-agent-settings . drgnx-agent-settings-mode-map)
                          :when #'drgnx-agent-settings--on-page-p)))

(drgnx-module-define 'tools/agent-settings
                     :doc "Agents: Settings — routes, MCP servers, hooks and skills of Claude Code, Codex, Gemini and Kimi Code"
                     :stage 'idle
                     :setup #'drgnx-agent-settings--setup)

(provide 'drgnx-agent-settings)
;;; drgnx-agent-settings.el ends here
