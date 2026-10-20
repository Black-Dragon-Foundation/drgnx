;;; drgnx-agents-ui.el --- Module tools/agents: the Agents tab, transcripts, answers, edit review -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The right dock's Agents tab lists agent sessions and durable jobs (status, queued messages,
;; context %, what waits for you).  RET opens a session's transcript in the editor: turns, thinking,
;; tool calls with their subagents, plans, and what the agent asks — permissions to answer, edits to
;; review hunk by hunk.  Typing to a busy agent queues; only Stop cancels.  See docs/guide/agents.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'diff)
(require 'diff-mode)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-timer)
(require 'drgnx-state)
(require 'drgnx-view)
(require 'drgnx-trust)
(require 'drgnx-agents)
(require 'drgnx-jobs)

(declare-function drgnx-wb-area-show "drgnx-area")
(declare-function drgnx-wb-define-tab "drgnx-area")
(declare-function drgnx-wb-place "drgnx-rules")
(declare-function project-root "project")

(defface drgnx-agents-ui-dim '((t :inherit shadow)) "Thoughts and finished tool calls." :group 'drgnx)
(defface drgnx-agents-ui-user '((t :inherit bold)) "What you said." :group 'drgnx)
(defface drgnx-agents-ui-header '((t :inherit header-line)) "The Agents list's column titles (its first line)." :group 'drgnx)
(defface drgnx-agents-ui-ask '((t :inherit warning)) "What the agent waits for." :group 'drgnx)

(defvar-local drgnx-agents-ui--session nil "The session this transcript shows.")

;;;; The list (Agents tab)

(defvar drgnx-agents-ui--jobs-cache nil "(TIME . JOBS): the list redraws often; jobs are read every 5 s at most.")

(defvar drgnx-agents-ui--last (make-hash-table :test #'eq :weakness 'key)
  "Session → the time (`float-time') it last changed, as this UI heard it (the list's Last column).")

(defun drgnx-agents-ui-last-active (s)
  "The time session S last changed (status, transcript, queue, what waits), or nil."
  (gethash s drgnx-agents-ui--last))

(defun drgnx-agents-ui--ago (secs)
  "SECS as a short age: 30s, 5m, 2h, 3d."
  (let ((secs (max 0 (floor secs))))
    (cond ((< secs 60) (format "%ds" secs))
          ((< secs 3600) (format "%dm" (/ secs 60)))
          ((< secs 86400) (format "%dh" (/ secs 3600)))
          (t (format "%dd" (/ secs 86400))))))

(defvar drgnx-agents-list-mode-map
  (let ((m (make-sparse-keymap))) (set-keymap-parent m tabulated-list-mode-map) m)
  "Keys come from the key profiles (command `agents-open').")

(define-derived-mode drgnx-agents-list-mode tabulated-list-mode "Agents"
  "Agent sessions and durable jobs: RET opens one."
  (setq tabulated-list-format [("Name" 26 nil) ("Status" 9 nil) ("Last" 5 nil) ("Ctx" 5 nil) ("Via" 8 nil) ("Waiting" 0 nil)])
  ;; the dock's tab strip owns the header line: the column titles are the list's first line instead
  (setq-local tabulated-list-use-header-line nil)
  (add-hook 'tabulated-list-revert-hook (lambda () (setq drgnx-agents-ui--jobs-cache nil)) nil t)   ; g reads jobs now
  (tabulated-list-init-header))

(defun drgnx-agents-ui--waiting (s)
  (string-join (delq nil (list (and (drgnx-agent-session-queue s)
                                    (format "%d queued%s" (length (drgnx-agent-session-queue s))
                                            (if (drgnx-agent-session-paused s) " (paused)" "")))
                               (and (drgnx-agent-session-permissions s) (format "%d to answer" (length (drgnx-agent-session-permissions s))))
                               (and (drgnx-agent-session-reviews s) (format "%d edit to review" (length (drgnx-agent-session-reviews s))))))
               ", "))

(defun drgnx-agents-ui--jobs ()
  (unless (and drgnx-agents-ui--jobs-cache (< (- (float-time) (car drgnx-agents-ui--jobs-cache)) 5))
    (setq drgnx-agents-ui--jobs-cache (cons (float-time) (ignore-errors (drgnx-jobs-list)))))
  (cdr drgnx-agents-ui--jobs-cache))

(defun drgnx-agents-ui--entries ()
  (append
   (mapcar (lambda (s)
             (list s (vector (drgnx-agent-session-name s) (symbol-name (drgnx-agent-session-status s))
                             (if-let* ((at (drgnx-agents-ui-last-active s))) (drgnx-agents-ui--ago (- (float-time) at)) "")
                             (if-let* ((p (drgnx-agents-context-percent s))) (format "%d%%" p) "")
                             (pcase (drgnx-agent-session-via s) ('gateway "gateway") ('direct "direct") (_ ""))
                             (drgnx-agents-ui--waiting s))))
           (drgnx-agents-sessions))
   (mapcar (lambda (j)
             (list (plist-get j :id)
                   (vector (concat "job: " (plist-get j :name)) (symbol-name (plist-get j :status)) "" "" ""
                           (if (plist-get j :exit) (format "exit %s" (plist-get j :exit)) ""))))
           (drgnx-agents-ui--jobs))))

;; The list is a view with no rows (`agents-list'): the view gives it the timer, the visibility check and the stale
;; mark; its SYNC prints.  tabulated-list owns the text, so the view's START is moved to the end after each print.

(defun drgnx-agents-ui--id-at (pos)
  "The session or job id of the list line at POS (`tabulated-list-id'), or nil."
  (get-text-property pos 'tabulated-list-id))

(defun drgnx-agents-ui--pos-of (id)
  "The start of the line of ID in the current Agents list, or nil."
  (save-excursion
    (goto-char (point-min))
    (let (found)
      (while (and (not found) (not (eobp)))
        (if (equal (get-text-property (point) 'tabulated-list-id) id)
            (setq found (point))
          (goto-char (or (next-single-property-change (point) 'tabulated-list-id) (point-max)))))
      found)))

(defvar tabulated-list--header-overlay)
(defvar drgnx-large-file-open)          ; core/drgnx-large-file.el: a review's diff visits its copy whole

(defun drgnx-agents-ui--header-end ()
  "Make the column titles the list's first line (a fake header: the dock's tab strip has the header line) in the
theme's header face, and return where the lines start (`point-min' when the list uses a real header line)."
  (if tabulated-list-use-header-line
      (point-min)
    (let ((inhibit-read-only t))
      (unless (tabulated-list-header-overlay-p (point-min))
        (save-excursion (tabulated-list-print-fake-header)))
      (if (not (overlayp tabulated-list--header-overlay))
          (point-min)
        (unless (eq (overlay-get tabulated-list--header-overlay 'face) 'drgnx-agents-ui-header)
          (overlay-put tabulated-list--header-overlay 'face 'drgnx-agents-ui-header))
        (overlay-end tabulated-list--header-overlay)))))

(declare-function drgnx-surfaces-key-label "drgnx-surfaces")

(defun drgnx-agents-ui--new-key ()
  "The key that runs New Agent Session… in the active key profile (`drgnx-surfaces-key-label', without the keymap),
or nil (it is then in the palette only)."
  (and (fboundp 'drgnx-surfaces-key-label)
       (ignore-errors (drgnx-surfaces-key-label 'agents-new :short t))))

(defun drgnx-agents-ui--claude-needs ()
  "What the claude profile still needs when it is the default one and its adapter is missing or too old, as a
sentence, or nil when it is ready (or another profile is the default)."
  (when (equal (car (plist-get (cdr (ignore-errors (drgnx-agents-profile (drgnx-agents-default-profile)))) :command))
               drgnx-agents-claude-program)
    (let ((a (ignore-errors (drgnx-agents-claude-adapter))))
      (cond ((null a) (format "Claude needs its adapter, %s: run drgnx onboard --step agents (or Help → Welcome → Agents) to install it."
                              drgnx-agents-claude-program))
            ((ignore-errors (drgnx-agents-adapter-problem a))
             (format "Claude's adapter %s needs updating: drgnx doctor says how." drgnx-agents-claude-program))))))

(defun drgnx-agents-ui--empty-state ()
  "The text of an empty list: how to start a session (with its key when it has one), and what Claude needs when
the claude profile is not ready.  Wrapped to the list's window (at most 40 columns)."
  (let* ((key (drgnx-agents-ui--new-key))
         (width (min 40 (max 20 (if-let* ((w (drgnx-agents-ui--list-shown-p))) (window-body-width w) 40))))
         (paragraphs (delq nil (list (format "No agent sessions yet — New Agent Session… (%s) starts one"
                                             (if key (concat key ", or the palette") "palette"))
                                     (drgnx-agents-ui--claude-needs)))))
    (propertize
     (concat (mapconcat (lambda (p)
                          (with-temp-buffer
                            (insert p)
                            (let ((fill-column width) (sentence-end-double-space nil)) (fill-region (point-min) (point-max)))
                            (buffer-string)))
                        paragraphs "\n")
             "\n")
     'face 'drgnx-agents-ui-dim)))

(defun drgnx-agents-ui--update-lines ()
  "Make the current list's lines those of `tabulated-list-entries', in their order, touching only lines that differ:
a line whose id and columns are the same stays as it is (`tabulated-list-print' with UPDATE keeps a line of the same
id even when its columns changed, and without a sort key prints everything again).  Lines of ids no longer listed go;
a new id gets a line where its entry stands; a line out of order is deleted and printed again at its place.  The
column titles stay the first line; with no entries the empty state follows them."
  (let* ((entries (if (functionp tabulated-list-entries) (funcall tabulated-list-entries) tabulated-list-entries))
         (new (make-hash-table :test #'equal)) (present (make-hash-table :test #'equal))
         (inhibit-read-only t) (start (drgnx-agents-ui--header-end)))
    (dolist (e entries) (puthash (car e) t new))
    (goto-char start)
    (while (not (eobp))
      (puthash (get-text-property (point) 'tabulated-list-id) t present)
      (forward-line 1))
    (goto-char start)
    (unless entries
      (let ((text (drgnx-agents-ui--empty-state)))
        ;; the same text already there: keep it; else it goes in first and the old tail is dropped below
        (if (equal-including-properties text (buffer-substring (point) (point-max)))
            (goto-char (point-max))
          (insert text))))
    (dolist (e entries)
      (let ((id (car e)) (cols (cadr e)) done)
        (while (not done)
          (let ((here (and (not (eobp)) (get-text-property (point) 'tabulated-list-id))))
            (cond ((eobp) (funcall tabulated-list-printer id cols) (puthash id t present) (setq done t))
                  ((equal here id)
                   (if (equal cols (get-text-property (point) 'tabulated-list-entry))
                       (forward-line 1)
                     (delete-region (point) (progn (forward-line 1) (point)))
                     (funcall tabulated-list-printer id cols))
                   (setq done t))
                  ((or (not (gethash here new)) (gethash id present))
                   (remhash here present)    ; gone, or out of order: printed again at its entry
                   (delete-region (point) (progn (forward-line 1) (point))))
                  (t (funcall tabulated-list-printer id cols) (puthash id t present) (setq done t)))))))
    (delete-region (point) (point-max))))

(defun drgnx-agents-ui--leave-header ()
  "Windows of the current list whose point is in the column titles move to the first line below them."
  (let ((start (drgnx-agents-ui--header-end)))
    (when (< (point) start) (goto-char start))
    (dolist (w (get-buffer-window-list nil nil t))
      (when (< (window-point w) start) (set-window-point w start)))))

(defun drgnx-agents-ui--list-print (view)
  "SYNC of `agents-list': update the list's lines in place, each window keeping its point and start on their
session.  Then the view's START goes to the end: the view has no rows, and the text is tabulated-list's."
  (unwind-protect
      (drgnx-view-with-kept-windows (:key-at #'drgnx-agents-ui--id-at :pos-of #'drgnx-agents-ui--pos-of)
        (drgnx-agents-ui--update-lines))
    (drgnx-agents-ui--leave-header)
    ;; even when the update signalled: the self-check must not take the lines for foreign text and delete them
    (set-marker (drgnx-view--start view) (point-max))
    (set-buffer-modified-p nil)))

(defun drgnx-agents-ui--list-view ()
  "The view of the Agents list, or nil (no list, or it was made without the module)."
  (when-let* ((b (get-buffer "*drgnx Agents*")) (view (buffer-local-value 'drgnx-view b)))
    (and (drgnx-view-p view) view)))

(defun drgnx-agents-ui-list-buffer ()
  "The Agents list, up to date.  With the `agents-list' view type (the module is on) the view prints it."
  (let ((b (get-buffer-create "*drgnx Agents*")))
    (with-current-buffer b
      (unless (derived-mode-p 'drgnx-agents-list-mode) (drgnx-agents-list-mode))
      (setq tabulated-list-entries #'drgnx-agents-ui--entries)
      (if (not (alist-get 'agents-list drgnx-view--types))  ; the type is the module's: none while it is off
          (tabulated-list-print t t)
        (unless (drgnx-view-p drgnx-view) (drgnx-view-attach 'agents-list))
        (drgnx-view-touch drgnx-view)
        (drgnx-view-draw-now drgnx-view)))
    b))

(defun drgnx-agents-ui--list-shown-p ()
  "Non-nil if a window the workbench state records, on any frame, shows the Agents list: the first such window."
  (when-let* ((b (get-buffer "*drgnx Agents*")))
    (let (found)
      (dolist (f (drgnx-state-frames))
        (dolist (w (drgnx-state-windows f))
          (when (and (not found) (eq (window-buffer w) b)) (setq found w))))
      found)))

(defun drgnx-agents-ui--tick-update (&optional _data)
  "Start the list's 30 s tick (layer key `agents-ui-tick') while a window shows the list, cancel it when none does.
A store subscriber (idle lane): it reads the state's records and ignores the event's data.  A tick already running
keeps its phase."
  (if (drgnx-agents-ui--list-shown-p)
      (unless (drgnx-timer-active-p 'agents-ui-tick)
        (drgnx-timer-start 'agents-ui-tick 30 #'drgnx-agents-ui--tick :repeat 30 :owner 'tools/agents))
    (drgnx-timer-cancel 'agents-ui-tick)))

(defun drgnx-agents-ui--tick ()
  "The 30 s tick (layer key `agents-ui-tick'): mark the Agents list so its Last ages are printed again.  The view
prints only while the list is shown.  The tick itself runs only while the list shows (`drgnx-agents-ui--tick-update')."
  (when-let* ((view (drgnx-agents-ui--list-view))) (drgnx-view-touch view)))

(defun drgnx-agents-ui-view ()
  "Show the Agents tab in the right dock."
  (interactive)
  (let ((b (drgnx-agents-ui-list-buffer)))
    (if (fboundp 'drgnx-wb-area-show) (drgnx-wb-area-show 'right 'agents b) (display-buffer b))))

(defun drgnx-agents-ui-open-at-point ()
  "Open the session (its transcript) or job (its log) on this line."
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (cond ((drgnx-agent-session-p id) (drgnx-agents-ui-transcript id))
          ((stringp id) (drgnx-agents-ui-job-log id)))))

;;;; Transcripts: a view (wb/drgnx-view.el), one row per entry, patched in place

;; What streams in is appended to its row (GROW), a changed row is drawn again on its own, and nothing is drawn while
;; no window shows the transcript.  The agent's process filter only marks the view (`drgnx-agents-ui--changed').

(defvar drgnx-agents-transcript-mode-map
  (let ((m (make-sparse-keymap))) (set-keymap-parent m special-mode-map) m)
  "Keys come from the key profiles (command `agents-reply').")

(define-derived-mode drgnx-agents-transcript-mode special-mode "Agent"
  "A live agent transcript: RET sends (queued while the agent works); Stop cancels; g redraws.
Its rows are a view of type `agent-transcript' (read-only, no undo), drawn only while a window shows it."
  (setq-local truncate-lines nil
              revert-buffer-function (lambda (&rest _) (drgnx-agents-ui-refresh)))
  (when (drgnx-view-type-p 'agent-transcript)        ; the type is the module's: none while it is off
    (drgnx-view-attach 'agent-transcript)))

(defvar-local drgnx-agents-ui--synced nil
  "What this transcript's last full sync saw: [SESSION ENTRIES COUNT PERMISSIONS REVIEWS STATUS QUEUE-VECTOR
COMMANDS PAUSED EXIT STDERR LIVE PERMISSION-COUNT REVIEW-COUNT], LIVE being ((ENTRY . SIGNATURE)...) for its tool
and plan entries not done yet (they change in place).  When all of it is the same, a sync only looks at the growing
text (`drgnx-agents-ui--sync').")

(defun drgnx-agents-ui--tool-lines (e depth)
  "Tool entry E and its children (nested DEPTH deep) as a list of lines."
  (cons (concat (make-string (* 2 depth) ?\s)
                (propertize (format "⚙ %s [%s]" (or (plist-get e :title) "tool") (or (plist-get e :status) ""))
                            'face (if (equal (plist-get e :status) "completed") 'drgnx-agents-ui-dim 'default))
                "\n")
        (mapcan (lambda (c) (drgnx-agents-ui--tool-lines c (1+ depth))) (plist-get e :children))))

(defun drgnx-agents-ui--button (label action)
  "A copy of LABEL made a text button that calls ACTION."
  (make-text-button (copy-sequence label) nil 'action (lambda (_) (funcall action)) 'follow-link t))

(defun drgnx-agents-ui--blank-p (e)
  "Non-nil if entry E shows nothing (a turn's end that was not a Stop)."
  (pcase (plist-get e :type)
    ((or 'user 'agent 'thought 'tool 'plan 'error) nil)
    ('stop (not (equal (plist-get e :stop) "cancelled")))
    (_ t)))

(defun drgnx-agents-ui--keys (s)
  "Session S's rows, in order: `:commands' (when it has commands), each entry that shows something, each permission
and review to answer, `:status' (working or exited) and `:queue' (when messages wait)."
  (let (keys)
    (when (drgnx-agent-session-commands s) (push :commands keys))
    (dolist (e (drgnx-agent-session-entries s)) (unless (drgnx-agents-ui--blank-p e) (push e keys)))
    (dolist (p (drgnx-agent-session-permissions s)) (push p keys))
    (dolist (r (drgnx-agent-session-reviews s)) (push r keys))
    (when (memq (drgnx-agent-session-status s) '(busy exited)) (push :status keys))
    (when (drgnx-agent-session-queue s) (push :queue keys))
    (nreverse keys)))

(defun drgnx-agents-ui--entry-row (e)
  "Entry E's row: a string ending in a newline, or (BODY . SUFFIX) for the agent's text and thinking (they grow)."
  (pcase (plist-get e :type)
    ('user (concat (propertize (concat (if (plist-get e :steer) "↪ " "▸ ") (plist-get e :text)) 'face 'drgnx-agents-ui-user) "\n\n"))
    ('agent (cons (drgnx-agents-entry-text e) "\n\n"))
    ('thought (cons (propertize (concat "… " (drgnx-agents-entry-text e)) 'face 'drgnx-agents-ui-dim) "\n"))
    ('tool (apply #'concat (drgnx-agents-ui--tool-lines e 0)))
    ('plan (concat (mapconcat (lambda (p) (concat (pcase (plist-get p :status) ("completed" "☑ ") ("in_progress" "◐ ") (_ "☐ "))
                                                  (plist-get p :content) "\n"))
                              (plist-get e :entries))
                   "\n"))
    ('error (concat (propertize (concat "! " (plist-get e :text)) 'face 'error) "\n"))
    ('stop (propertize "■ stopped\n\n" 'face 'drgnx-agents-ui-dim))))

(defun drgnx-agents-ui--row (s key)
  "The text of session S's row KEY (`drgnx-agents-ui--keys').  Buttons are made here, their closures with them."
  (pcase key
    (:commands
     (concat (propertize (concat "Commands: " (mapconcat (lambda (c) (concat "/" (plist-get c :name))) (drgnx-agent-session-commands s) " "))
                         'face 'drgnx-agents-ui-dim)
             "\n\n"))
    (:status
     (if (eq (drgnx-agent-session-status s) 'busy)
         (concat (propertize "working…  " 'face 'drgnx-agents-ui-dim) (drgnx-agents-ui--button "[Stop]" (lambda () (drgnx-agents-stop s))) "\n")
       (concat (propertize (format "the agent exited%s\n%s" (if (drgnx-agent-session-exit s) (format " (%s)" (drgnx-agent-session-exit s)) "")
                                   (or (drgnx-agent-session-stderr s) ""))
                           'face 'error)
               "\n")))
    (:queue
     (let ((i -1))
       (concat (propertize (format "\n%d queued%s:" (length (drgnx-agent-session-queue s))
                                   (if (drgnx-agent-session-paused s) " (held by Stop)" ""))
                           'face 'drgnx-agents-ui-dim)
               (if (drgnx-agent-session-paused s)
                   (concat " " (drgnx-agents-ui--button "[Deliver]" (lambda () (drgnx-agents-deliver-queue s))))
                 "")
               (mapconcat (lambda (text)
                            (let ((n (setq i (1+ i))))
                              (concat "\n  " (propertize text 'face 'drgnx-agents-ui-dim) " "
                                      (drgnx-agents-ui--button (concat "[" (drgnx-face-glyph 'unqueue) "]")
                                                               (lambda () (drgnx-agents-unqueue s n))))))
                          (drgnx-agent-session-queue s))
               "\n")))
    ((guard (plist-get key :type)) (drgnx-agents-ui--entry-row key))
    ((guard (memq key (drgnx-agent-session-reviews s)))
     (concat (propertize (format "? the agent wants to change %s  " (plist-get key :path)) 'face 'drgnx-agents-ui-ask)
             (drgnx-agents-ui--button "[Review]" (lambda () (drgnx-agents-ui-review s key)))
             "\n"))
    (_                                  ; a permission
     (concat (propertize (format "? %s  " (plist-get key :title)) 'face 'drgnx-agents-ui-ask)
             (mapconcat (lambda (o) (concat (drgnx-agents-ui--button (format "[%s]" (plist-get o :name))
                                                                     (lambda () (drgnx-agents-answer-permission s key (plist-get o :optionId))))
                                            " "))
                        (plist-get key :options))
             "\n"))))

(defun drgnx-agents-ui-render (s)
  "Insert session S's transcript (and what waits for an answer) at point: its rows, as the transcript draws them."
  (dolist (key (drgnx-agents-ui--keys s))
    (let ((r (drgnx-agents-ui--row s key))) (if (consp r) (insert (car r) (cdr r)) (insert r)))))

(defun drgnx-agents-ui--render-row (key)
  "RENDER of the view type `agent-transcript': row KEY of this buffer's session."
  (drgnx-agents-ui--row drgnx-agents-ui--session key))

(defun drgnx-agents-ui--grow-row (key body)
  "GROW of `agent-transcript': for an agent's text or thinking, what came after the BODY characters drawn (the
thinking's with its 2-character prefix and dim face), read from the newest chunks only (`drgnx-agents-entry-tail');
nil (draw the row again) for anything else, or a text shorter than what was drawn."
  (let* ((type (and (consp key) (plist-get key :type))) (from (if (eq type 'thought) (- body 2) body))
         (new (and (memq type '(agent thought)) (>= from 0) (drgnx-agents-entry-tail key from))))
    (when (and new (eq type 'thought)) (put-text-property 0 (length new) 'face 'drgnx-agents-ui-dim new))
    new))

(defun drgnx-agents-ui--tool-fields (children)
  "The status, title and children of each of CHILDREN and their own, depth first, as a list."
  (mapcan (lambda (c) (nconc (list (plist-get c :status) (plist-get c :title) (plist-get c :children))
                             (drgnx-agents-ui--tool-fields (plist-get c :children))))
          children))

(defun drgnx-agents-ui--sig (key)
  "KEY's signature for `drgnx-view-sync-rows' (compared element by element with `eq'): for an entry its type,
status, title, children, plan entries and done (an agent's text or thinking: its type only, its text grows and
`:done' does not change what it shows), with a tool's subagent calls' status, title and children; a permission or
review is its own; the footer rows take the session's status, exit and each queued message (and what else they
show)."
  (let ((s drgnx-agents-ui--session))
    (pcase key
      (:commands (vector (drgnx-agent-session-commands s)))
      (:status (vector (drgnx-agent-session-status s) (drgnx-agent-session-exit s) (drgnx-agent-session-stderr s)))
      (:queue (apply #'vector (drgnx-agent-session-paused s) (drgnx-agent-session-queue s)))
      ((guard (memq (plist-get key :type) '(agent thought))) (vector (plist-get key :type)))
      ((guard (plist-get key :type))
       (apply #'vector (plist-get key :type) (plist-get key :status) (plist-get key :title) (plist-get key :children)
              (plist-get key :entries) (plist-get key :done) (drgnx-agents-ui--tool-fields (plist-get key :children))))
      (_ key))))

(defun drgnx-agents-ui--same-sig-p (a b)
  "Non-nil if the signature vectors A and B hold `eq' elements."
  (and (= (length a) (length b))
       (let ((i 0) (n (length a)))
         (while (and (< i n) (eq (aref a i) (aref b i))) (setq i (1+ i)))
         (= i n))))

(defun drgnx-agents-ui--sync (view)
  "SYNC of `agent-transcript': mark VIEW's rows that changed since the last sync.
Fast path: when the session's entries, permissions and reviews (the same lists, as long), status, queued messages
\(each one), commands, pause and exit are `eq' to the last sync's and no tool or plan entry still running changed,
nothing but the growing text can have changed.  Otherwise `drgnx-view-sync-rows' diffs every row.  Then an
agent's text or thinking not done yet that is longer than its drawn body is marked to grow."
  (let ((s drgnx-agents-ui--session))
    (when s
      (let ((old drgnx-agents-ui--synced) (entries (drgnx-agent-session-entries s)) (count 0) live texts)
        (dolist (e entries)
          (setq count (1+ count))
          (unless (plist-get e :done)
            (pcase (plist-get e :type)
              ((or 'agent 'thought) (push e texts))
              ((or 'tool 'plan) (push e live)))))
        (unless (and old (eq s (aref old 0)) (eq entries (aref old 1)) (= count (aref old 2))
                     ;; a `delq' keeps the head of a list whose first item stays: the lengths tell
                     (eq (drgnx-agent-session-permissions s) (aref old 3))
                     (= (length (drgnx-agent-session-permissions s)) (aref old 12))
                     (eq (drgnx-agent-session-reviews s) (aref old 4)) (= (length (drgnx-agent-session-reviews s)) (aref old 13))
                     (eq (drgnx-agent-session-status s) (aref old 5))
                     ;; a requeue replaces a message in place: each one is compared
                     (drgnx-agents-ui--same-items-p (drgnx-agent-session-queue s) (aref old 6))
                     (eq (drgnx-agent-session-commands s) (aref old 7)) (eq (drgnx-agent-session-paused s) (aref old 8))
                     (eq (drgnx-agent-session-exit s) (aref old 9)) (eq (drgnx-agent-session-stderr s) (aref old 10))
                     (= (length live) (length (aref old 11)))
                     (let ((ok t) (pairs (aref old 11)))
                       (while (and ok pairs)
                         (setq ok (and (memq (caar pairs) live)
                                       (drgnx-agents-ui--same-sig-p (cdar pairs) (drgnx-agents-ui--sig (caar pairs))))
                               pairs (cdr pairs)))
                       ok))
          (drgnx-view-sync-rows view (drgnx-agents-ui--keys s) #'drgnx-agents-ui--sig)
          (setq drgnx-agents-ui--synced
                (vector s entries count (drgnx-agent-session-permissions s) (drgnx-agent-session-reviews s)
                        (drgnx-agent-session-status s) (vconcat (drgnx-agent-session-queue s)) (drgnx-agent-session-commands s)
                        (drgnx-agent-session-paused s) (drgnx-agent-session-exit s) (drgnx-agent-session-stderr s)
                        (mapcar (lambda (e) (cons e (drgnx-agents-ui--sig e))) live)
                        (length (drgnx-agent-session-permissions s)) (length (drgnx-agent-session-reviews s)))))
        (dolist (e texts)
          (let ((body (drgnx-view-body-length view e)))
            (when (and body (/= body (+ (drgnx-agents-entry-length e) (if (eq (plist-get e :type) 'thought) 2 0))))
              (drgnx-view-grow view e))))))))

(defun drgnx-agents-ui--same-items-p (list vec)
  "Non-nil if LIST holds the elements of the vector VEC, in order, `eq'."
  (let ((i 0) (n (length vec)))
    (while (and list (< i n) (eq (car list) (aref vec i))) (setq list (cdr list) i (1+ i)))
    (and (null list) (= i n))))

(defun drgnx-agents-ui--buffer (s) (get-buffer-create (format "*agent: %s*" (drgnx-agent-session-name s))))

(defun drgnx-agents-ui-refresh (&optional s)
  "Redraw the transcript of S (default: this buffer's) now, even when no window shows it: its view syncs and draws
at once (`drgnx-view-draw-now')."
  (interactive)
  (let* ((s (or s drgnx-agents-ui--session)) (b (and s (get-buffer (format "*agent: %s*" (drgnx-agent-session-name s)))))
         (view (and (buffer-live-p b) (buffer-local-value 'drgnx-view b))))
    (when (drgnx-view-p view)
      (drgnx-view-touch view)
      (drgnx-view-draw-now view))))

(defun drgnx-agents-ui-transcript-buffer (s)
  "Session S's transcript buffer, drawn (not shown)."
  (let ((b (drgnx-agents-ui--buffer s)))
    (with-current-buffer b
      (unless (and (derived-mode-p 'drgnx-agents-transcript-mode) (drgnx-view-p drgnx-view))
        (drgnx-agents-transcript-mode))
      (setq drgnx-agents-ui--session s))
    (drgnx-agents-ui-refresh s)
    b))

(defun drgnx-agents-ui-transcript (s)
  "Show session S's transcript."
  (let ((b (drgnx-agents-ui-transcript-buffer s)))
    (pop-to-buffer b)
    b))

(defun drgnx-agents-ui--changed (s)
  "A session changed: note when (the list's Last column) and mark its transcript's view and the list's (each draws
from its own timer, at most every 0.1 s, only while shown).  Called from the agent's process filter: only marks."
  (puthash s (float-time) drgnx-agents-ui--last)
  (let* ((b (get-buffer (format "*agent: %s*" (drgnx-agent-session-name s))))
         (view (and b (buffer-local-value 'drgnx-view b))))
    (when (drgnx-view-p view) (drgnx-view-touch view)))
  (when-let* ((view (drgnx-agents-ui--list-view))) (drgnx-view-touch view)))

;;;; Commands

(defun drgnx-agents-ui--session (&optional prompt)
  (or drgnx-agents-ui--session
      (let ((live (drgnx-agents-sessions)))
        (cond ((null live) (user-error "No agent session (Agents: New Session)"))
              ((null (cdr live)) (car live))
              (t (let ((name (completing-read (or prompt "Session: ") (mapcar #'drgnx-agent-session-name live) nil t)))
                   (seq-find (lambda (s) (equal (drgnx-agent-session-name s) name)) live)))))))

(defun drgnx-agents-ui--cwd ()
  (or (when-let* ((p (and (fboundp 'project-current) (project-current)))) (project-root p)) default-directory))

(declare-function drgnx-agents-mirror-sync "drgnx-agents-mirror")
(declare-function drgnx-hub-socket "drgnx-hub-client")
(declare-function drgnx-hub-ensure "drgnx-hub-client")
(declare-function drgnx-hub-call-sync "drgnx-hub-client")

(defun drgnx-agents-ui--maybe-mirror ()
  "At idle: mirror the hub's agent sessions when a hub runs.  Never waits and never starts one: only a socket that
exists is connected to (asynchronously)."
  (require 'drgnx-hub-client)
  (when (and (file-exists-p (drgnx-hub-socket)) (not (process-live-p (bound-and-true-p drgnx-hub--events))))
    (require 'drgnx-agents-mirror)
    (with-demoted-errors "drgnx: the agent hub does not answer: %S" (drgnx-agents-mirror-sync))))

(defun drgnx-agents-ui-new-durable (profile)
  "Start an agent session of PROFILE in this project, held by the hub: it keeps working when Emacs closes."
  (interactive (list (completing-read "Durable agent profile: " (drgnx-agents-profile-names) nil t nil nil (drgnx-agents-default-profile))))
  (require 'drgnx-agents-mirror)
  (drgnx-hub-ensure)
  (drgnx-agents-mirror-sync)
  (let ((r (drgnx-hub-call-sync "agents/start" (list :profile profile :cwd (drgnx-agents-ui--cwd)))))
    (message "Agent %s started in the hub (it keeps working when Emacs closes)" (plist-get r :name))))

(defun drgnx-agents-ui-new (profile)
  "Start an agent session of PROFILE in this project."
  (interactive (list (completing-read "Agent profile: " (drgnx-agents-profile-names) nil t nil nil (drgnx-agents-default-profile))))
  (drgnx-agents-ui-transcript (drgnx-agents-start profile (drgnx-agents-ui--cwd))))

(defun drgnx-agents-ui-send (text)
  "Send TEXT to the agent — queued while it works; it never cancels the running turn."
  (interactive (list (read-string (format "To %s: " (drgnx-agent-session-name (drgnx-agents-ui--session))))))
  (drgnx-agents-send (drgnx-agents-ui--session) text))

(defun drgnx-agents-ui-stop ()
  "Stop the agent's running turn (the only thing that cancels)."
  (interactive)
  (drgnx-agents-stop (drgnx-agents-ui--session)))

(defun drgnx-agents-ui-deliver ()
  "Send the messages a Stop held back."
  (interactive)
  (drgnx-agents-deliver-queue (drgnx-agents-ui--session)))

(defun drgnx-agents-ui-take-over (profile session-id)
  "Resume the agent session SESSION-ID with PROFILE here."
  (interactive (list (completing-read "Agent profile: " (drgnx-agents-profile-names) nil t nil nil (drgnx-agents-default-profile)) (read-string "Session id: ")))
  (drgnx-agents-ui-transcript (drgnx-agents-take-over profile (drgnx-agents-ui--cwd) session-id)))

(defun drgnx-agents-ui-answer ()
  "Answer what the agent asks (permission to run a tool)."
  (interactive)
  (let* ((s (drgnx-agents-ui--session)) (p (or (car (drgnx-agent-session-permissions s)) (user-error "Nothing to answer")))
         (choice (completing-read (format "%s: " (plist-get p :title)) (mapcar (lambda (o) (plist-get o :name)) (plist-get p :options)) nil t)))
    (drgnx-agents-answer-permission s p (plist-get (seq-find (lambda (o) (equal (plist-get o :name) choice)) (plist-get p :options)) :optionId))))

(defun drgnx-agents-ui-job-log (id)
  "Show durable job ID's log."
  (interactive (list (completing-read "Job: " (mapcar (lambda (j) (plist-get j :id)) (drgnx-jobs-list)) nil t)))
  (with-current-buffer (get-buffer-create (format "*job: %s*" id))
    (let ((inhibit-read-only t)) (erase-buffer) (insert (drgnx-jobs-log id)))
    (special-mode)
    (pop-to-buffer (current-buffer))))

(defun drgnx-agents-ui-job-stop (id)
  "Stop durable job ID."
  (interactive (list (completing-read "Stop job: " (mapcar (lambda (j) (plist-get j :id))
                                                           (seq-filter (lambda (j) (eq (plist-get j :status) 'running)) (drgnx-jobs-list)))
                                      nil t)))
  (drgnx-jobs-stop id))

;;;; Edit review (the agent's fs/write_text_file)

(defvar-local drgnx-agents-ui--review nil "(SESSION ITEM COPY) this diff answers; COPY takes the hunks you apply.")

(defvar drgnx-agents-review-mode-map (make-sparse-keymap)
  "Keys come from the key profiles (commands `agents-review-done', `agents-review-reject').")

(define-minor-mode drgnx-agents-review-mode
  "An edit an agent proposes: C-c C-a applies a hunk (to a copy of the file), C-c C-c writes what you
applied to the file, C-c C-k rejects — nothing touches the file before Done."
  :lighter " Review")

(defun drgnx-agents-ui--local-p (s)
  "Whether session S works in a local folder: its agent's paths are then resolved with no file name handler."
  (not (file-remote-p (or (drgnx-agent-session-cwd s) "/"))))

(defun drgnx-agents-ui--path-ok-p (s path)
  "May the agent of session S have PATH reviewed?  A remote name only when the session's folder is remote
(`drgnx-trust-link-ok-p' with that folder as the source): what the agent says never makes Emacs connect (M2-6 c).
In a local session PATH must resolve, with no file name handler, to a local name (`drgnx-file-truename'): a link
on its way to a remote name, a quoted name (`/:…') and a link loop are refused too."
  (if (drgnx-agents-ui--local-p s)
      (and (drgnx-file-truename path) t)            ; also nil for a remote name as written
    (with-temp-buffer
      (setq default-directory (or (drgnx-agent-session-cwd s) "/"))
      (drgnx-trust-link-ok-p path (current-buffer)))))

(defun drgnx-agents-ui-review (s item)
  "Show the change ITEM proposes as a diff against a copy of its file: apply the hunks you want (to
the copy), then Done writes the copy to the file (Reject, or closing the diff, writes nothing).  A remote
name from a local session is rejected without a look at it, and so is a file Emacs keeps encrypted or compressed
\(`drgnx-file-sealed-p': the agent's plain text would land in it as it is)."
  (cond ((not (drgnx-agents-ui--path-ok-p s (plist-get item :path)))
         (message "Agent edit rejected: %s is a remote name from a local session" (plist-get item :path))
         (drgnx-agents-finish-review s item t)
         nil)
        ((drgnx-file-sealed-p (plist-get item :path))
         (message "Agent edit rejected: %s is kept encrypted or compressed: edit it yourself" (plist-get item :path))
         (drgnx-agents-finish-review s item t)
         nil)
        (t (drgnx-agents-ui--review-open s item))))

(defun drgnx-agents-ui--target (s path)
  "Where the edit of session S to PATH goes, and the file name handlers to use on it: (FILE . HANDLERS).  A local
session's PATH is used by its true name, resolved with no file name handler, and with none (`drgnx-file-truename':
the agent's name as written would be followed again, with handlers on); a remote session's as it is, with them."
  (if (drgnx-agents-ui--local-p s)
      (cons (or (drgnx-file-truename path) (user-error "%s leads to a remote name: refused" path)) nil)
    (cons path file-name-handler-alist)))

(defun drgnx-agents-ui--review-open (s item)
  (pcase-let* ((path (plist-get item :path))
               (`(,file . ,handlers) (drgnx-agents-ui--target s path))
               (shown (let ((file-name-handler-alist handlers)) (abbreviate-file-name file)))
               (copy (make-temp-file "drgnx-review-"))   ; a suffix of its own: the agent's `.gpg' reached EasyPG
               (new (make-temp-file "drgnx-proposed-"))
               (cwd (drgnx-agent-session-cwd s)))
    (let ((file-name-handler-alist handlers)) (when (file-exists-p file) (copy-file file copy t)))
    (with-temp-file new (insert (plist-get item :content)))
    (let ((b (diff-no-select copy new "-u" t (get-buffer-create (format "*review: %s*" shown)))))
      (delete-file new)                             ; hunks can apply to the copy alone
      (with-current-buffer b
        (drgnx-agents-review-mode 1)
        (setq drgnx-agents-ui--review (list s item copy))
        (setq-local drgnx-large-file-open 'whole)   ; diff-mode visits the copy from here (C-c C-a): whole, no question
        (setq header-line-format
              (concat (format " %s wants to change %s" (drgnx-agent-session-name s) shown)
                      (if (and cwd (not (if (drgnx-agents-ui--local-p s) (drgnx-file-inside-p file cwd) (file-in-directory-p path cwd))))
                          "  — OUTSIDE the session's project" "")
                      "  (C-c C-a apply a hunk · C-c C-c done · C-c C-k reject)"))
        (add-hook 'kill-buffer-hook #'drgnx-agents-ui--review-killed nil t))
      (pop-to-buffer b)
      b)))

(defun drgnx-agents-ui--review-cleanup (copy)
  (when-let* ((cb (find-buffer-visiting copy))) (with-current-buffer cb (set-buffer-modified-p nil)) (kill-buffer cb))
  (when (file-exists-p copy) (delete-file copy)))

(defun drgnx-agents-ui--review-killed ()
  "A review closed without Done or Reject: the agent hears it was rejected."
  (when drgnx-agents-ui--review
    (pcase-let ((`(,s ,item ,copy) drgnx-agents-ui--review))
      (setq drgnx-agents-ui--review nil)
      (drgnx-agents-ui--review-cleanup copy)
      (when (memq item (drgnx-agent-session-reviews s)) (drgnx-agents-finish-review s item t)))))

(defun drgnx-agents-ui-review-done ()
  "Write what you applied to the file; tell the agent."
  (interactive)
  (pcase-let ((`(,s ,item ,copy) (or drgnx-agents-ui--review (user-error "Not an agent's edit"))))
    ;; resolved again now, and written by that name (`drgnx-agents-ui--target': a local session's, with no handler)
    (pcase-let* ((path (plist-get item :path)) (`(,file . ,handlers) (drgnx-agents-ui--target s path))
                 (cb (find-buffer-visiting copy))
                 (visiting (let ((file-name-handler-alist handlers)) (find-buffer-visiting file))))
      (when (drgnx-file-sealed-p path)              ; it may lead to one now: never plain text into it
        (user-error "%s is kept encrypted or compressed: not written (reject the edit, and edit it yourself)" path))
      (when (and visiting (buffer-modified-p visiting))
        (user-error "%s has unsaved changes: save or revert them first"
                    (let ((file-name-handler-alist handlers)) (abbreviate-file-name file))))
      (let ((text (if cb (with-current-buffer cb (buffer-substring-no-properties (point-min) (point-max)))
                    (with-temp-buffer (insert-file-contents copy) (buffer-string))))
            (coding (and cb (with-current-buffer cb buffer-file-coding-system))))
        (let ((file-name-handler-alist handlers) (coding-system-for-write (or coding 'utf-8-unix)))
          (make-directory (file-name-directory file) t)
          (write-region text nil file nil 'silent))
        (when visiting (with-current-buffer visiting (revert-buffer t t t))))
      (setq drgnx-agents-ui--review nil)
      (drgnx-agents-ui--review-cleanup copy)
      (drgnx-agents-finish-review s item)
      (kill-buffer (current-buffer)))))

(defun drgnx-agents-ui-review-reject ()
  "Reject the agent's edit: the file stays as it is."
  (interactive)
  (pcase-let ((`(,s ,item ,copy) (or drgnx-agents-ui--review (user-error "Not an agent's edit"))))
    (setq drgnx-agents-ui--review nil)
    (drgnx-agents-ui--review-cleanup copy)
    (drgnx-agents-finish-review s item t)
    (kill-buffer (current-buffer))))

(defun drgnx-agents-ui-edit-queued ()
  "Change or remove (empty text) a queued message before it is sent."
  (interactive)
  (let* ((s (drgnx-agents-ui--session)) (q (or (drgnx-agent-session-queue s) (user-error "Nothing queued")))
         (pick (completing-read "Queued message: " q nil t))
         (n (seq-position q pick)))
    (drgnx-agents-requeue s n (read-string "Text (empty: remove): " pick))))

;;;; The module

(declare-function drgnx-agents-mirror-stop "drgnx-agents-mirror")
(declare-function drgnx-hub-disconnect "drgnx-hub-client")

(defun drgnx-agents-ui--teardown ()
  "Turned off: the hub's sessions are mirrored no more and the hub's event connection closes.  The layer timers (the
list's tick, the mirror's) end with the module's run; the hooks, the views, the tab, the rules and the commands go
with the cleanup stack."
  (when (featurep 'drgnx-agents-mirror) (drgnx-agents-mirror-stop))
  (when (featurep 'drgnx-hub-client) (drgnx-hub-disconnect)))

(drgnx-module-define 'tools/agents
                     :doc "Agents: sessions over ACP in the right dock's Agents tab, durable jobs, edit review."
                     :stage 'startup :requires '(core/workbench)
                     :teardown #'drgnx-agents-ui--teardown
                     :setup
                     (lambda ()
                       ;; transcripts: rows patched in place, drawn only while shown
                       (drgnx-view-define 'agent-transcript :render #'drgnx-agents-ui--render-row
                                          :grow #'drgnx-agents-ui--grow-row :sync #'drgnx-agents-ui--sync
                                          :delay drgnx-view-delay :slice drgnx-view-slice :follow-tail t :key-test 'eq)
                       (add-hook 'drgnx-agents-changed-functions #'drgnx-agents-ui--changed)
                       ;; the list: no rows, its SYNC prints it in place; drawn only while shown
                       (drgnx-view-define 'agents-list :render #'ignore :sync #'drgnx-agents-ui--list-print
                                          :delay drgnx-view-delay)
                       ;; the list's Last ages: marked every 30 s, a tick that runs only while a window shows the list
                       (dolist (event '(windows-changed pane-shown pane-hidden frame-removed))
                         (drgnx-state-subscribe event #'drgnx-agents-ui--tick-update))
                       (drgnx-agents-ui--tick-update)
                       ;; the hub's sessions (they outlive this Emacs), once Emacs is idle
                       (drgnx-timer-start 'agents-ui-mirror-first 3 #'drgnx-agents-ui--maybe-mirror :idle t)
                       ;; …and again later: a hub started (or restarted) since is picked up
                       (drgnx-timer-start 'agents-ui-mirror 30 #'drgnx-agents-ui--maybe-mirror :repeat t :idle t)
                       (when (fboundp 'drgnx-wb-define-tab)
                         (drgnx-wb-define-tab 'right 'agents :title "Agents" :placeholder #'drgnx-agents-ui-list-buffer))
                       (when (fboundp 'drgnx-wb-place)
                         (drgnx-wb-place 'drgnx-agents-list-mode 'right :tab 'agents)
                         (drgnx-wb-place '(drgnx-agents-transcript-mode) 'editor)
                         (drgnx-wb-place "\\`\\*\\(review\\|job\\): " 'editor))
                       (pcase-dolist (`(,id ,title ,fn ,doc)
                                      '((agents-view "Show Agents" drgnx-agents-ui-view "Agent sessions and durable jobs, in the right dock")
                                        (agents-new "New Agent Session…" drgnx-agents-ui-new "Start an agent (a profile) in this project")
                                        (agents-new-durable "New Durable Agent Session…" drgnx-agents-ui-new-durable
                                                            "An agent held by the hub: it keeps working when Emacs closes")
                                        (agents-send "Send to Agent…" drgnx-agents-ui-send "Queued while the agent works; never cancels")
                                        (agents-stop "Stop Agent" drgnx-agents-ui-stop "Cancel the running turn (the only thing that does)")
                                        (agents-deliver "Deliver Queued Messages" drgnx-agents-ui-deliver "Send what a Stop held back")
                                        (agents-edit-queued "Edit Queued Message…" drgnx-agents-ui-edit-queued "Change or remove a message before it is sent")
                                        (agents-take-over "Take Over Agent Session…" drgnx-agents-ui-take-over "Resume a session by its id")
                                        (agents-answer "Answer Agent…" drgnx-agents-ui-answer "Allow or reject what the agent asks")
                                        (jobs-log "Show Job Log…" drgnx-agents-ui-job-log "A durable job's output")
                                        (jobs-stop "Stop Job…" drgnx-agents-ui-job-stop "Stop a durable job")))
                         (drgnx-command-define id :category "Agents" :title title :command fn :doc doc))
                       (drgnx-command-define 'agents-open :category "Agents" :title "Open" :command #'drgnx-agents-ui-open-at-point
                                             :map 'drgnx-agents-list-mode-map :doc "The session's transcript, or the job's log")
                       (drgnx-command-define 'agents-reply :category "Agents" :title "Reply" :command #'drgnx-agents-ui-send
                                             :map 'drgnx-agents-transcript-mode-map :doc "Send to this agent (queued while it works)")
                       (drgnx-command-define 'agents-review-done :category "Agents" :title "Done Reviewing" :command #'drgnx-agents-ui-review-done
                                             :map 'drgnx-agents-review-mode-map :doc "Keep the hunks you applied; tell the agent")
                       (drgnx-command-define 'agents-review-reject :category "Agents" :title "Reject Edit" :command #'drgnx-agents-ui-review-reject
                                             :map 'drgnx-agents-review-mode-map :doc "Tell the agent the edit was rejected")))

(provide 'drgnx-agents-ui)
;;; drgnx-agents-ui.el ends here
