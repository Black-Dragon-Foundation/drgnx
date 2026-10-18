;;; drgnx-cockpit.el --- Module tools/cockpit: the Work cockpit — the Work graph's pane, its redraws, its commands -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The Work cockpit's home screen is the Work graph (pane kind `work-graph', home `left', view `work'): specs, plans,
;; tasks, agents, jobs and reviews from the cockpit's model (core/drgnx-cockpit-model.el), drawn
;; (drgnx-cockpit-graph.el) in a graphical window wide enough for it, else as an outline.  It follows the live store:
;; hub events, agent sessions, work-tracker scans and theme changes schedule a redraw (`drgnx-cockpit-schedule'), and
;; a check every few seconds catches what other processes wrote.  At most one redraw runs per
;; `drgnx-cockpit-redraw-delay', only while the graph is visible; a cheap key (the store's data version and change
;; count, counters, the filter, the options, the font) says whether anything changed before the model is built, and
;; the graph draws only when what it would show changed.  It never prompts and never touches a remote file.  Click,
;; or TAB and RET, opens a node's tab; f filters by milestone, agent and state.  See docs/guide/cockpit.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'image)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-cockpit-model)
(require 'drgnx-panes)
;; the layout, the drawing and the outline sit beside this file
(unless (featurep 'drgnx-cockpit-graph)
  (load (expand-file-name "drgnx-cockpit-graph" (file-name-directory (or load-file-name buffer-file-name))) nil t))
(unless (featurep 'drgnx-cockpit-edits)                 ; each agent's edits, beside it too
  (load (expand-file-name "drgnx-cockpit-edits" (file-name-directory (or load-file-name buffer-file-name))) nil t))

(declare-function drgnx-cockpit-graph-layout "drgnx-cockpit-graph")
(declare-function drgnx-cockpit-graph-outline "drgnx-cockpit-graph")
(declare-function drgnx-cockpit-graph-summary "drgnx-cockpit-graph")
(declare-function drgnx-cockpit-graph-band-ranges "drgnx-cockpit-graph")
(declare-function drgnx-cockpit--question-text "drgnx-cockpit-model")
(declare-function drgnx-cockpit-graph-focus-element "drgnx-cockpit-graph")
(declare-function drgnx-cockpit-graph--elements "drgnx-cockpit-graph")
(declare-function drgnx-cockpit-graph--print "drgnx-cockpit-graph")
(declare-function drgnx-cockpit-graph--ascii-p "drgnx-cockpit-graph")
(declare-function drgnx-cockpit-edits--setup "drgnx-cockpit-edits")
(declare-function drgnx-cockpit-edits-pane-buffer "drgnx-cockpit-edits")
(declare-function drgnx-work-ui--metrics "drgnx-work-ui")
(declare-function drgnx-work-ui--colour "drgnx-work-ui")
(declare-function drgnx-work-nodes "drgnx-work-db")
(declare-function drgnx-agents-sessions "drgnx-agents")
(declare-function drgnx-job-ui-show "drgnx-job-ui")
(declare-function drgnx-agent-session-remote "drgnx-agents")
(declare-function drgnx-agent-session-id "drgnx-agents")
(declare-function drgnx-agent-session-name "drgnx-agents")
(declare-function drgnx-agent-session-cwd "drgnx-agents")
(declare-function drgnx-agent-session-task "drgnx-agents")
(declare-function drgnx-agent-session-job "drgnx-agents")
(declare-function drgnx-agent-session-status "drgnx-agents")
(declare-function drgnx-agent-session-permissions "drgnx-agents")
(declare-function evil-set-initial-state "evil-core")
(defvar drgnx-cockpit-graph-svg)
(defvar drgnx-cockpit-graph--generation)

(defcustom drgnx-cockpit-redraw-delay 0.5
  "Seconds between the first change the Work graph hears of and its redraw: however many events come meanwhile,
it redraws once."
  :type 'number :group 'drgnx-cockpit)

(defcustom drgnx-cockpit-check-interval 3
  "Seconds between two looks, while the Work graph shows, at whether another process wrote the store (an outside
agent's MCP server, another Emacs).  One cheap query each; the graph redraws only when it changed."
  :type 'number :group 'drgnx-cockpit)

(defcustom drgnx-cockpit-silent-interval 45
  "Seconds between two searches, while the Work graph shows, for worktrees nobody reports from (one git process per
repository the store knows); a work-tracker scan starts one too."
  :type 'number :group 'drgnx-cockpit)

(defcustom drgnx-cockpit-open-functions
  '((spec . drgnx-cockpit--open-file) (plan . drgnx-cockpit--open-file) (todo . drgnx-cockpit--open-file)
    (task . drgnx-cockpit-edits-open-task) (agent . drgnx-cockpit-edits-open-agent) (job . drgnx-cockpit--open-job)
    (review . drgnx-cockpit--open-job))
  "What opening a node of the Work graph does, by its kind: KIND → a function of the node.  A kind not listed opens
its file, when it has one."
  :type '(alist :key-type symbol :value-type function) :group 'drgnx-cockpit)

(defconst drgnx-cockpit-graph-buffer-name "*Work Graph*")

(defvar drgnx-cockpit-graph-current-filter nil
  "What the Work graph shows: (:milestone TEXT :agent ID :states (STATE…)), each optional (`drgnx-cockpit-filter'); nil
shows everything.  Set by `drgnx-cockpit-graph-filter'.")

(defvar drgnx-cockpit--timer nil "The redraw on its way: one at a time.")
(defvar drgnx-cockpit--check-timer nil "The repeating look at the store (`drgnx-cockpit--check'), while the graph lives.")
(defvar drgnx-cockpit--draws 0 "How many times the Work graph was drawn (tests and the perf lab read it).")
(defvar drgnx-cockpit--last-error nil "The last error a redraw said: the same one is said once.")
(defvar drgnx-cockpit--scan-n 0 "Counts finished work-tracker scans: part of the redraw key.")
(defvar drgnx-cockpit--silent nil "The worktrees nobody reports from, as `drgnx-cockpit-silent-worktrees' found them last.")
(defvar drgnx-cockpit--silent-n 0 "Counts changes of `drgnx-cockpit--silent': part of the redraw key.")
(defvar drgnx-cockpit--silent-at nil "When the last search for silent worktrees started (`float-time').")
(defvar drgnx-cockpit--silent-running nil "Non-nil while a search for silent worktrees runs.")

(defvar-local drgnx-cockpit--key nil "The cheap key of the last redraw (`drgnx-cockpit-graph-redraw'): equal, nothing to do.")
(defvar-local drgnx-cockpit--signature nil "What the graph shows now: a redraw that would show the same draws nothing.")
(defvar-local drgnx-cockpit--stale nil "Something changed while the graph was hidden: it redraws when it shows.")
(defvar-local drgnx-cockpit--model nil "The model the graph shows (filtered).")
(defvar-local drgnx-cockpit--built nil "The model last built, for `drgnx-cockpit--built-key'.")
(defvar-local drgnx-cockpit--built-key nil "(STORE FILTER GENERATION) the last model was built for.")
(defvar-local drgnx-cockpit--layout nil "The layout last measured (graphical windows only), for `drgnx-cockpit--layout-key'.")
(defvar-local drgnx-cockpit--layout-key nil "(MODEL METRICS GENERATION) the last layout was measured for.")
(defvar-local drgnx-cockpit--lines nil "The lines the outline shows, as they are in the buffer (patched in place).")
(defvar-local drgnx-cockpit--spots nil "While the drawing shows: alist hot-spot area → node id.")
(defvar-local drgnx-cockpit--svg nil "Non-nil while the drawing shows (nil: the outline).")
(defvar-local drgnx-cockpit--elements nil "While the drawing shows: its elements (`drgnx-cockpit-graph--elements').")
(defvar-local drgnx-cockpit--bands nil
  "While the drawing shows: its bands ((Y0 HEIGHT IMAGE START ROWS)…), START the buffer position of its first slice.
Their images are flushed when new ones replace them.")
(defvar-local drgnx-cockpit--frame nil
  "While the drawing shows: what its buffer text depends on — the head lines, the bands, the width and every box's
place (ID X Y W H).  The same again: a redraw changes only band images (`drgnx-cockpit--draw-svg').")
(defvar-local drgnx-cockpit--selected nil "The node selected with TAB (its id), or nil.")
(defvar-local drgnx-cockpit--questions nil "Hash node id → the first line of the open question about it.")

;;;; The buffer and its mode

(defvar drgnx-cockpit-graph-mode-map
  (let ((m (make-sparse-keymap))) (set-keymap-parent m special-mode-map) m)
  "The Work graph's keys (they come from the key profiles: f, RET, o, g, TAB, S-TAB).")

(defvar drgnx-cockpit--line-map
  (let ((m (make-sparse-keymap))) (define-key m [mouse-1] #'drgnx-cockpit-graph-click) m)
  "A click on a node's line of the outline opens it.")

(define-derived-mode drgnx-cockpit-graph-mode special-mode "Work Graph"
  "The Work graph: specs, plans, tasks, agents, jobs and reviews (docs/guide/cockpit.md)."
  (setq truncate-lines t buffer-read-only t)
  (buffer-disable-undo)
  (setq-local revert-buffer-function #'drgnx-cockpit--revert)
  (add-hook 'window-size-change-functions #'drgnx-cockpit--resized nil t)
  (add-hook 'window-buffer-change-functions #'drgnx-cockpit--resized nil t)
  (add-hook 'kill-buffer-hook #'drgnx-cockpit--unwatch nil t))

(with-eval-after-load 'evil                     ; its own letters, also in the Vim profile
  (when (fboundp 'evil-set-initial-state) (evil-set-initial-state 'drgnx-cockpit-graph-mode 'emacs)))

(defun drgnx-cockpit-graph-buffer ()
  "The Work graph's buffer, made the first time (it then follows the store while it lives).
It draws when it shows (`drgnx-cockpit--on-show')."
  (or (get-buffer drgnx-cockpit-graph-buffer-name)
      (with-current-buffer (get-buffer-create drgnx-cockpit-graph-buffer-name)
        (drgnx-cockpit-graph-mode)
        (setq drgnx-cockpit--stale t)
        (drgnx-cockpit--watch)
        (current-buffer))))

;;;; Following the store

(defun drgnx-cockpit--watch ()
  "Follow the store while the graph's buffer lives: hub events, agent sessions, work-tracker scans, theme changes,
and a look every `drgnx-cockpit-check-interval' s (idempotent)."
  (add-hook 'drgnx-hub-event-functions #'drgnx-cockpit--hub-event)
  (add-hook 'drgnx-agents-changed-functions #'drgnx-cockpit--agent-changed)
  (add-hook 'drgnx-work-ui-scanned-hook #'drgnx-cockpit--scanned)
  (add-hook 'enable-theme-functions #'drgnx-cockpit--theme-changed)
  (unless (timerp drgnx-cockpit--check-timer)
    (setq drgnx-cockpit--check-timer
          (run-with-timer drgnx-cockpit-check-interval drgnx-cockpit-check-interval #'drgnx-cockpit--check))))

(defun drgnx-cockpit--flush-bands ()
  "Release the drawing's band images (their pixels) and forget them."
  (dolist (b drgnx-cockpit--bands) (ignore-errors (image-flush (nth 2 b) t)))
  (setq drgnx-cockpit--bands nil))

(defun drgnx-cockpit--unwatch ()
  "The graph's buffer is killed: stop following the store (its `kill-buffer-hook'), release its images."
  (remove-hook 'drgnx-hub-event-functions #'drgnx-cockpit--hub-event)
  (remove-hook 'drgnx-agents-changed-functions #'drgnx-cockpit--agent-changed)
  (remove-hook 'drgnx-work-ui-scanned-hook #'drgnx-cockpit--scanned)
  (remove-hook 'enable-theme-functions #'drgnx-cockpit--theme-changed)
  (dolist (tm (list drgnx-cockpit--timer drgnx-cockpit--check-timer)) (when (timerp tm) (cancel-timer tm)))
  (setq drgnx-cockpit--timer nil drgnx-cockpit--check-timer nil)
  (drgnx-cockpit--flush-bands))

(defconst drgnx-cockpit--quiet-events '("agent-entries" "request" "budget")
  "Hub events that never change the graph: a transcript's chunks, the gateway's requests and spend.")

(defun drgnx-cockpit--hub-event (event _data)
  "`drgnx-hub-event-functions': a job, a card, an agent or a lease changed — the graph redraws soon."
  (unless (member event drgnx-cockpit--quiet-events) (drgnx-cockpit-schedule)))

(defun drgnx-cockpit--agent-changed (_session)
  "`drgnx-agents-changed-functions' (also every transcript chunk): a session's state may show in the graph.  The
redraw's key holds what the model reads of the sessions, so a chunk that changes none of it builds no model."
  (drgnx-cockpit-schedule))

(defun drgnx-cockpit--scanned ()
  "`drgnx-work-ui-scanned-hook': the tracker changed — redraw, and look for silent worktrees again."
  (cl-incf drgnx-cockpit--scan-n)
  (when-let* ((b (get-buffer drgnx-cockpit-graph-buffer-name)) ((drgnx-cockpit--visible-p b)))
    (drgnx-cockpit--call #'drgnx-cockpit--silent-scan t))
  (drgnx-cockpit-schedule))

(defun drgnx-cockpit--theme-changed (&rest _)
  "`enable-theme-functions': the drawing's colours come from faces — draw it again."
  (cl-incf drgnx-cockpit-graph--generation)
  (drgnx-cockpit-schedule))

(defun drgnx-cockpit--visible-p (buffer)
  "Whether BUFFER shows in a window of a visible frame."
  (and (get-buffer-window buffer 'visible) t))

(defun drgnx-cockpit-schedule (&optional delay)
  "Redraw the Work graph within DELAY seconds (`drgnx-cockpit-redraw-delay'): one redraw however many calls come
meanwhile, only while the graph is visible (hidden, it redraws when it shows), and it draws only when what it shows
changed.  Cheap: called from every event."
  (when-let* ((b (get-buffer drgnx-cockpit-graph-buffer-name)))
    (cond ((not (drgnx-cockpit--visible-p b)) (with-current-buffer b (setq drgnx-cockpit--stale t)))
          ((not (timerp drgnx-cockpit--timer))
           (setq drgnx-cockpit--timer (run-at-time (or delay drgnx-cockpit-redraw-delay) nil #'drgnx-cockpit--tick))))))

(defun drgnx-cockpit--error (err)
  "Say ERR, unless it is the one said last (a broken store would otherwise say it twice a second)."
  (let ((m (error-message-string err)))
    (unless (equal m drgnx-cockpit--last-error)
      (setq drgnx-cockpit--last-error m)
      (message "drgnx cockpit: %s" m))))

(defun drgnx-cockpit--call (fn &rest args)
  "FN with ARGS from a timer or a hook: an error is said once (`drgnx-cockpit--error'), never a prompt or a signal."
  (condition-case err (prog1 (apply fn args) (setq drgnx-cockpit--last-error nil))
    (error (drgnx-cockpit--error err) nil)))

(defun drgnx-cockpit--tick ()
  "The scheduled redraw (a timer).  A graph hidden since it was scheduled only notes it is stale."
  (setq drgnx-cockpit--timer nil)
  (when-let* ((b (get-buffer drgnx-cockpit-graph-buffer-name)))
    (if (drgnx-cockpit--visible-p b) (drgnx-cockpit--call #'drgnx-cockpit-graph-redraw)
      (with-current-buffer b (setq drgnx-cockpit--stale t)))))

(defun drgnx-cockpit--on-show (window)
  "The graph's pane shows in WINDOW: draw what changed while it was hidden (soon, never while showing it)."
  (when (buffer-local-value 'drgnx-cockpit--stale (window-buffer window)) (drgnx-cockpit-schedule 0)))

(defun drgnx-cockpit--resized (_window)
  "A window showing the graph changed size, or started showing it: the drawing may now fit, or no longer."
  (drgnx-cockpit-schedule))

(defun drgnx-cockpit--revert (&rest _) (drgnx-cockpit-graph-redraw t))

;;;; What other processes wrote; worktrees nobody reports from

(defun drgnx-cockpit--sessions-key ()
  "What the model reads of this Emacs's sessions: ((ID STATUS TASK JOB NAME CWD PERMISSIONS-P)…).  A transcript's
chunk changes none of it."
  (mapcar (lambda (s) (list (plist-get s :id) (plist-get s :status) (plist-get s :task) (plist-get s :job)
                            (plist-get s :name) (plist-get s :cwd) (and (plist-get s :permissions) t)))
          (drgnx-cockpit-sessions)))

(defun drgnx-cockpit--store-key ()
  "(DATA-VERSION TOTAL-CHANGES SESSIONS SCAN-N SILENT-N CLOSED): it changes when what the model reads does.  One
query: the data version moves when another connection commits, the change count when this Emacs writes; SESSIONS is
`drgnx-cockpit--sessions-key'; CLOSED is `drgnx-cockpit-include-closed-jobs'."
  (append (car (sqlite-select (drgnx-work-db) "select (select data_version from pragma_data_version()), total_changes()"))
          (list (drgnx-cockpit--sessions-key) drgnx-cockpit--scan-n drgnx-cockpit--silent-n drgnx-cockpit-include-closed-jobs)))

(defun drgnx-cockpit--check ()
  "Every `drgnx-cockpit-check-interval' s while the graph lives (a timer): when it shows, ask for a redraw if the
store changed since the last one (another process wrote it), and look for silent worktrees when that is due."
  (when-let* ((b (get-buffer drgnx-cockpit-graph-buffer-name)) ((drgnx-cockpit--visible-p b)))
    (drgnx-cockpit--call
     (lambda ()
       (unless (equal (drgnx-cockpit--store-key) (car (buffer-local-value 'drgnx-cockpit--key b))) (drgnx-cockpit-schedule))
       (drgnx-cockpit--silent-scan)))))

(defun drgnx-cockpit--roots ()
  "The folders the store knows in repositories — jobs' repos, the tracker's plans' repos, registered agents' working
folders and worktrees — that are local folders (git lists a repository's worktrees from any of them).  A remote name
is left out by its syntax (`file-remote-p') before any `file-directory-p' runs."
  (let ((dirs (append (mapcar #'car (sqlite-select (drgnx-work-db) "select distinct repo from job where repo is not null"))
                      (mapcar (lambda (p) (plist-get p :repo)) (drgnx-work-nodes 'plan))
                      (mapcan (lambda (r) (list (plist-get r :cwd) (plist-get r :worktree))) (drgnx-coord-agents)))))
    (seq-filter #'file-directory-p
                (delete-dups (mapcar (lambda (d) (file-name-as-directory (expand-file-name d)))
                                     (seq-remove #'file-remote-p (seq-filter #'stringp dirs)))))))

(defun drgnx-cockpit--silent-scan (&optional now)
  "Look for worktrees nobody reports from (`drgnx-cockpit-silent-worktrees', asynchronously), when the last look is
`drgnx-cockpit-silent-interval' s old (NOW: at once) and none runs.  What it finds goes to the model as :silent."
  (when (and (not drgnx-cockpit--silent-running)
             (or now (null drgnx-cockpit--silent-at) (>= (- (float-time) drgnx-cockpit--silent-at) drgnx-cockpit-silent-interval)))
    (setq drgnx-cockpit--silent-at (float-time))
    (when-let* ((roots (drgnx-cockpit--roots)))
      (setq drgnx-cockpit--silent-running t)
      (drgnx-cockpit-silent-worktrees roots #'drgnx-cockpit--silent-found (drgnx-cockpit-sessions)))))

(defun drgnx-cockpit--silent-found (agents)
  "The silent worktrees' AGENTS were found (a sentinel): keep them, and redraw when they changed."
  (setq drgnx-cockpit--silent-running nil)
  ;; two folders of one repository list the same worktrees: each once
  (let ((found (cl-remove-duplicates (seq-remove (lambda (a) (plist-get a :error)) agents)
                                     :key (lambda (a) (plist-get a :id)) :test #'equal :from-end t)))
    (unless (equal found drgnx-cockpit--silent)
      (setq drgnx-cockpit--silent found)
      (cl-incf drgnx-cockpit--silent-n)
      (drgnx-cockpit-schedule))))

;;;; Drawing

(defun drgnx-cockpit-sessions ()
  "The agent sessions this Emacs knows (its own and the hub's mirrors), as the model takes them: cached state only.
An exited session is left out (it no longer works on anything)."
  (when (fboundp 'drgnx-agents-sessions)
    (delq nil (mapcar (lambda (s)
                        (let ((id (or (drgnx-agent-session-remote s) (drgnx-agent-session-id s))))
                          (unless (or (null id) (eq (drgnx-agent-session-status s) 'exited))
                            (list :id id :name (drgnx-agent-session-name s) :cwd (drgnx-agent-session-cwd s)
                                  :task (drgnx-agent-session-task s) :job (drgnx-agent-session-job s)
                                  :status (drgnx-agent-session-status s) :permissions (drgnx-agent-session-permissions s)))))
                      (drgnx-agents-sessions)))))

(defun drgnx-cockpit--filtering-p ()
  (let ((f drgnx-cockpit-graph-current-filter))
    (or (plist-get f :milestone) (plist-get f :agent) (plist-get f :states))))

(defun drgnx-cockpit--current-model ()
  "The model the graph shows: the store's (with the silent worktrees found last), filtered by
`drgnx-cockpit-graph-current-filter'."
  (let ((m (drgnx-cockpit-model :sessions (drgnx-cockpit-sessions) :silent drgnx-cockpit--silent)))
    (if (drgnx-cockpit--filtering-p) (drgnx-cockpit-filter m drgnx-cockpit-graph-current-filter) m)))

(defun drgnx-cockpit--drawable-p (windows)
  "Whether the graph may be drawn (SVG) in WINDOWS: the option is on, this Emacs draws SVG, every window is graphical."
  (and drgnx-cockpit-graph-svg windows (image-type-available-p 'svg)
       (seq-every-p (lambda (w) (display-images-p (window-frame w))) windows)))

(defun drgnx-cockpit--filter-line ()
  "The line saying what the filter keeps, or nil."
  (when (drgnx-cockpit--filtering-p)
    (let ((f drgnx-cockpit-graph-current-filter))
      (propertize (concat "Filter: "
                          (string-join (delq nil (list (plist-get f :milestone)
                                                       (and (plist-get f :agent) (format "agent %s" (plist-get f :agent)))
                                                       (and (plist-get f :states) (string-join (plist-get f :states) ", "))))
                                       " · ")
                          "  (f changes it)")
                  'face 'drgnx-cockpit-edge))))

(defun drgnx-cockpit--question-lines (model)
  "Hash node id → the first line of the open question about it (MODEL's :questions), for hover texts."
  (let ((h (make-hash-table :test #'equal)))
    (dolist (q (plist-get model :questions))
      (when-let* ((node (plist-get q :node)) ((not (gethash node h))))
        (puthash node (truncate-string-to-width
                       (car (split-string (drgnx-cockpit--question-text (format "%s" (or (plist-get q :summary) ""))) "\n"))
                       120 nil nil "…")
                 h)))
    h))

(defun drgnx-cockpit-graph-redraw (&optional force)
  "Draw the Work graph again when what it shows changed (FORCE: read the store again and draw anyway); non-nil when
it drew.  The drawing in graphical windows wide enough for it (`drgnx-cockpit-graph-svg'), else the outline.
First a cheap key: the store's data version and change count, what the model reads of the sessions, the scan and
silent-worktree counters, the filter, `drgnx-cockpit-include-closed-jobs', the options' generation, the font's
metrics, the widest window, ASCII or not.  The same key: nothing to do.  Then the model is built only when the
store, sessions, filter or options changed, the layout only when the model, metrics or options did.  Reads the store
and the cached sessions only: never prompts."
  (when-let* ((b (get-buffer drgnx-cockpit-graph-buffer-name)))
    (with-current-buffer b
      (let* ((windows (get-buffer-window-list b nil t))
             (metrics (drgnx-work-ui--metrics))
             (drawable (drgnx-cockpit--drawable-p windows))
             (width (and drawable (apply #'max (mapcar (lambda (w) (window-body-width w t)) windows))))
             (ascii (drgnx-cockpit-graph--ascii-p))
             (filter drgnx-cockpit-graph-current-filter) (gen drgnx-cockpit-graph--generation)
             (store (drgnx-cockpit--store-key))
             (key (list store filter gen metrics width ascii)))
        (setq drgnx-cockpit--stale nil)
        (when (or force (not (equal key drgnx-cockpit--key)))
          (setq drgnx-cockpit--key key)
          (let* ((mkey (list store filter gen))
                 (model (if (and (not force) (equal mkey drgnx-cockpit--built-key)) drgnx-cockpit--built
                          (setq drgnx-cockpit--built-key mkey
                                drgnx-cockpit--built (drgnx-cockpit--current-model))))
                 (lkey (list model metrics gen))
                 (layout (and drawable
                              (if (equal lkey drgnx-cockpit--layout-key) drgnx-cockpit--layout
                                (setq drgnx-cockpit--layout-key lkey
                                      drgnx-cockpit--layout (drgnx-cockpit-graph-layout model metrics)))))
                 (svg (and layout (>= width (plist-get layout :w))))
                 (sig (list model filter (and svg metrics) ascii gen)))
            (when (or force (not (equal sig drgnx-cockpit--signature)))
              (setq drgnx-cockpit--signature sig drgnx-cockpit--model model
                    drgnx-cockpit--questions (drgnx-cockpit--question-lines model))
              (if svg (drgnx-cockpit--draw-svg model layout windows) (drgnx-cockpit--draw-outline model windows))
              (cl-incf drgnx-cockpit--draws)
              t)))))))

(defun drgnx-cockpit--line-of (id)
  "The line number of node ID's line in the outline, or nil."
  (save-excursion
    (goto-char (point-min))
    (when-let* ((m (text-property-search-forward 'drgnx-cockpit-node id t)))
      (line-number-at-pos (prop-match-beginning m)))))

(defun drgnx-cockpit--draw-outline (model windows)
  "Show MODEL as the outline, changing only the lines that changed: a window keeps its point (on its node when that
line changed) and its start."
  (let* ((new (mapcar (lambda (l)
                        (if-let* ((id (get-text-property 0 'drgnx-cockpit-node l)))
                            (propertize l 'keymap drgnx-cockpit--line-map 'mouse-face 'highlight
                                        'help-echo (gethash id drgnx-cockpit--questions))
                          l))
                      (delq nil (cons (drgnx-cockpit--filter-line) (drgnx-cockpit-graph-outline model)))))
         (old (if drgnx-cockpit--svg nil drgnx-cockpit--lines))
         (inhibit-read-only t)
         (pre 0) (o old) (n new))
    (when drgnx-cockpit--svg
      (erase-buffer)
      (kill-local-variable 'cursor-type)
      (drgnx-cockpit--flush-bands)
      (setq drgnx-cockpit--elements nil))
    (while (and o n (equal-including-properties (car o) (car n))) (setq o (cdr o) n (cdr n) pre (1+ pre)))
    (let* ((ro (reverse o)) (rn (reverse n)) (post 0))
      (while (and ro rn (equal-including-properties (car ro) (car rn))) (setq ro (cdr ro) rn (cdr rn) post (1+ post)))
      (let* ((gone (- (length old) pre post))
             ;; windows whose point is on a line about to change: back to the same node after
             (moved (delq nil (mapcar (lambda (w)
                                        (let ((line (line-number-at-pos (window-point w))))
                                          (when (and (> line pre) (<= line (+ pre gone)))
                                            (list w (get-text-property (save-excursion (goto-char (window-point w)) (line-beginning-position))
                                                                       'drgnx-cockpit-node)
                                                  line))))
                                      windows))))
        (save-excursion
          (goto-char (point-min))
          (forward-line pre)
          (delete-region (point) (progn (forward-line gone) (point)))
          (dolist (l (reverse rn)) (insert l "\n")))
        (drgnx-wb-with-owned-windows windows
          (pcase-dolist (`(,w ,id ,line) moved)
            (let ((to (or (and id (drgnx-cockpit--line-of id)) line)))
              (set-window-point w (save-excursion (goto-char (point-min)) (forward-line (1- to)) (point))))))))
    (set-buffer-modified-p nil)
    (setq drgnx-cockpit--lines new drgnx-cockpit--svg nil drgnx-cockpit--spots nil)))

(defun drgnx-cockpit--band-svg (layout y0 hb)
  "The SVG text of the band of LAYOUT from Y0, HB pixels tall, with the selected node's focus stroke."
  (let ((focus (and drgnx-cockpit--selected (drgnx-cockpit-graph-focus-element layout drgnx-cockpit--selected))))
    (drgnx-cockpit-graph--print layout (if focus (append drgnx-cockpit--elements (list focus)) drgnx-cockpit--elements) y0 hb)))

(defun drgnx-cockpit--draw-svg (model layout windows)
  "Show LAYOUT (of MODEL) as the drawing: a summary line, then the image in bands of slices (it scrolls like text),
every box a hot spot, the selected one stroked.
When the head lines, the boxes' places and the bands are what they were (`drgnx-cockpit--frame'), the buffer's text
stays: only the bands whose drawing changed get it, their old pixels flushed first.  Otherwise the buffer is drawn
anew; then the old bands' images are flushed, except one drawn the same again (its cached pixels serve the new one),
and windows keep their start and point where the buffer still reaches."
  (let* ((head (delq nil (list (drgnx-cockpit--filter-line) (drgnx-cockpit-graph-summary model))))
         (ranges (drgnx-cockpit-graph-band-ranges layout))
         (frame (list head ranges (plist-get layout :w)
                      (mapcar (lambda (b) (list (plist-get b :id) (plist-get b :x) (plist-get b :y) (plist-get b :w) (plist-get b :h)))
                              (plist-get layout :boxes))))
         (byid (make-hash-table :test #'equal)))
    (dolist (b (plist-get layout :boxes)) (puthash (plist-get b :id) b byid))
    (setq drgnx-cockpit--elements (drgnx-cockpit-graph--elements layout))
    (if (and drgnx-cockpit--svg (equal frame drgnx-cockpit--frame))
        (let ((fg (drgnx-work-ui--colour 'default :foreground)))   ; currentColor follows a theme change
          (cl-mapc (lambda (band m)
                     (pcase-let* ((`(,y0 ,hb ,img) band) (svg (drgnx-cockpit--band-svg layout y0 hb)))
                       (unless (and (equal svg (image-property img :data)) (equal m (image-property img :map))
                                    (equal fg (image-property img :foreground)))
                         (ignore-errors (image-flush img t))
                         (setf (image-property img :data) svg (image-property img :map) m (image-property img :foreground) fg))))
                   drgnx-cockpit--bands (drgnx-cockpit--band-maps byid ranges))
          (force-window-update (current-buffer)))
      (let* ((inhibit-read-only t) (map (make-sparse-keymap)) (spots nil) (i 0)
             (lh (cdr (plist-get layout :metrics)))
             (old drgnx-cockpit--bands) (bands nil)
             (keep (mapcar (lambda (w) (list w (window-start w) (window-point w))) windows)))
        (dolist (box (plist-get layout :boxes))
          (let ((area (intern (format "drgnx-cockpit-node-%d" (cl-incf i)))))
            (push (cons area (plist-get box :id)) spots)
            ;; a click comes as mouse-1 with the hot spot in its position, or prefixed by it: both open
            (define-key map (vector area 'mouse-1) #'drgnx-cockpit-graph-click)
            (define-key map (vector area 'double-mouse-1) #'ignore)))
        (define-key map [mouse-1] #'drgnx-cockpit-graph-click)
        (define-key map [down-mouse-1] #'ignore)        ; a press neither moves point nor selects
        (define-key map [double-mouse-1] #'ignore)
        (setq drgnx-cockpit--spots (nreverse spots))
        (erase-buffer)
        (dolist (l head) (insert l "\n"))
        (let ((start (point)) (maps (drgnx-cockpit--band-maps byid ranges)))
          (pcase-dolist (`(,y0 ,hb) ranges)
            (let ((img (create-image (drgnx-cockpit--band-svg layout y0 hb) 'svg t :scale 1.0
                                     :foreground (drgnx-work-ui--colour 'default :foreground)))
                  (rows (max 1 (/ hb (* 2 lh)))))
              ;; set after `create-image', which would measure the image for its hot spots
              (setf (image-property img :map) (pop maps))
              (push (list y0 hb img (point) rows) bands)
              ;; in slices of rows: it scrolls like text (it is drawn only where it fits across, so one column)
              (insert-sliced-image img nil nil rows 1)))
          (put-text-property start (point-max) 'keymap map))
        (drgnx-wb-with-owned-windows windows
          (pcase-dolist (`(,w ,s ,p) keep)
            (set-window-start w (min s (point-max)) t)
            (set-window-point w (min p (point-max)))))
        (set-buffer-modified-p nil)
        (setq-local cursor-type nil)                    ; no cursor box drawn round a slice of the image
        (setq drgnx-cockpit--svg t drgnx-cockpit--lines nil drgnx-cockpit--bands (nreverse bands) drgnx-cockpit--frame frame)
        ;; an old band drawn the same again keeps its pixels (the image cache finds the equal image); the others go
        (dolist (b old)
          (unless (seq-find (lambda (nb) (equal (nth 2 nb) (nth 2 b))) drgnx-cockpit--bands)
            (ignore-errors (image-flush (nth 2 b) t))))))))

(defun drgnx-cockpit--band-maps (byid ranges)
  "The hot spots of each band of RANGES ((Y0 HEIGHT)…, as `drgnx-cockpit-graph-band-ranges' gives them, all of one
height but the last), in its own pixels: the boxes it shows (BYID, id → box), cut to it, each with its node
described for hovering.  One pass over the boxes: each goes to the bands it reaches."
  (let* ((band (max 1 (cadr (car ranges)))) (n (length ranges)) (maps (make-vector n nil)) (ranges (vconcat ranges)))
    (pcase-dolist (`(,area . ,id) (reverse drgnx-cockpit--spots))
      (let* ((box (gethash id byid)) (y (plist-get box :y)) (bottom (+ y (plist-get box :h)))
             (x (plist-get box :x)) (right (+ x (plist-get box :w)))
             (props (list 'help-echo (drgnx-cockpit--describe (plist-get box :node) "\n") 'pointer 'hand)))
        (cl-loop for k from (max 0 (/ y band)) to (min (1- n) (/ (1- bottom) band))
                 do (let* ((y0 (car (aref ranges k))) (y1 (+ y0 (cadr (aref ranges k))))
                           (top (max y0 y)) (bot (min y1 bottom)))
                      (when (< top bot)
                        (push (list (cons 'rect (cons (cons x (- top y0)) (cons right (- bot y0)))) area props) (aref maps k)))))))
    (append maps nil)))

;;;; Selecting a node from the keyboard

(defun drgnx-cockpit--describe (node &optional sep)
  "NODE in one line (SEP between its parts, default \" · \"): kind, title, state, its open question, its file."
  (string-join (delq nil (list (format "%s: %s" (capitalize (symbol-name (plist-get node :kind))) (or (plist-get node :title) (plist-get node :id)))
                               (plist-get node :state)
                               (and drgnx-cockpit--questions (gethash (plist-get node :id) drgnx-cockpit--questions))
                               (plist-get node :path)))
               (or sep " · ")))

(defun drgnx-cockpit--box-band (layout id y0 hb)
  "Whether box ID of LAYOUT, with its focus stroke, reaches into the band from Y0, HB pixels tall."
  (when-let* ((e (and id (drgnx-cockpit-graph-focus-element layout id))))
    (and (<= (car e) (+ y0 hb)) (>= (cadr e) y0))))

(defun drgnx-cockpit--focus (id)
  "Select node ID in the drawing: only the bands the old and the new selection reach into are drawn again (their
images' pixels flushed first), and point goes to the row where its box starts."
  (let ((old drgnx-cockpit--selected) (layout drgnx-cockpit--layout))
    (setq drgnx-cockpit--selected id)
    (pcase-dolist (`(,y0 ,hb ,img ,start ,rows) drgnx-cockpit--bands)
      (when (or (drgnx-cockpit--box-band layout old y0 hb) (drgnx-cockpit--box-band layout id y0 hb))
        (ignore-errors (image-flush img t))
        (setf (image-property img :data) (drgnx-cockpit--band-svg layout y0 hb)))
      (when-let* ((box (seq-find (lambda (b) (equal (plist-get b :id) id)) (plist-get layout :boxes)))
                  (y (plist-get box :y)) ((and (>= y y0) (< y (+ y0 hb)))))
        (goto-char (+ start (* 2 (min (1- rows) (/ (* (- y y0) rows) hb)))))))
    (force-window-update (current-buffer))))

(defun drgnx-cockpit--outline-nodes ()
  "The outline's nodes in order: ((POS . ID)…), POS the start of each node's first line."
  (save-excursion
    (goto-char (point-min))
    (let ((out nil) (last nil))
      (while (not (eobp))
        (let ((id (get-text-property (point) 'drgnx-cockpit-node)))
          (when (and id (not (equal id last))) (push (cons (point) id) out))
          (setq last id))
        (forward-line 1))
      (nreverse out))))

(defun drgnx-cockpit-graph-select-next (&optional n)
  "Select the next node — in the drawing the next box in column order, in the outline the next node's line — and
say what it is; with N, N nodes on (back when negative).  RET opens it."
  (interactive "p")
  (unless (derived-mode-p 'drgnx-cockpit-graph-mode) (user-error "Not in the Work graph"))
  (let ((n (or n 1)))
    (if drgnx-cockpit--svg
        (let* ((boxes (sort (copy-sequence (plist-get drgnx-cockpit--layout :boxes))
                            (lambda (a b) (if (= (plist-get a :col) (plist-get b :col)) (< (plist-get a :y) (plist-get b :y))
                                            (< (plist-get a :col) (plist-get b :col))))))
               (ids (mapcar (lambda (b) (plist-get b :id)) boxes))
               (i (cl-position drgnx-cockpit--selected ids :test #'equal)))
          (when ids
            (drgnx-cockpit--focus (nth (mod (if i (+ i n) (if (> n 0) (1- n) n)) (length ids)) ids))))
      (let* ((nodes (drgnx-cockpit--outline-nodes))
             (i (cl-position-if (lambda (p) (<= (car p) (line-beginning-position))) nodes :from-end t)))
        (when nodes
          (let ((to (nth (mod (if i (+ i n) (if (> n 0) (1- n) n)) (length nodes)) nodes)))
            (goto-char (car to))
            (setq drgnx-cockpit--selected (cdr to))))))
    (when-let* ((node (and drgnx-cockpit--selected (drgnx-cockpit--shown-node drgnx-cockpit--selected))))
      (message "%s" (drgnx-cockpit--describe node)))))

(defun drgnx-cockpit-graph-select-previous (&optional n)
  "Select the previous node (`drgnx-cockpit-graph-select-next'); with N, N nodes back."
  (interactive "p")
  (drgnx-cockpit-graph-select-next (- (or n 1))))

;;;; Opening a node

(defun drgnx-cockpit--shown-node (id)
  "The node ID of the model the graph shows, or nil."
  (when-let* ((b (get-buffer drgnx-cockpit-graph-buffer-name)))
    (seq-find (lambda (n) (equal (plist-get n :id) id)) (plist-get (buffer-local-value 'drgnx-cockpit--model b) :nodes))))

(defun drgnx-cockpit--show-file (path line)
  "Open PATH at LINE in the editor area and select it; a file that is gone is said, never an error."
  (if (not (and path (file-exists-p path)))
      (progn (message "Work graph: %s is gone" (or path "the file")) nil)
    (let ((b (find-file-noselect path)))
      (if (fboundp 'drgnx-wb-show-in-editor) (drgnx-wb-show-in-editor b t) (pop-to-buffer b))
      (with-selected-window (or (get-buffer-window b) (selected-window))
        (goto-char (point-min))
        (forward-line (1- (or line 1))))
      b)))

(defun drgnx-cockpit--open-file (node)
  "Open NODE's file at its line (a spec, a plan, a TODO, a task's plan)."
  (drgnx-cockpit--show-file (plist-get node :path) (plist-get node :line)))

(defun drgnx-cockpit--open-task (node)
  "Open task NODE: its plan at its heading, else its job (a task an agent works on opens its edits first:
`drgnx-cockpit-edits-open-task').  A plan task no job runs is read-only here: it opens in its plan, and Start Job from
Plan is named, never run."
  (cond ((plist-get node :path)
         (prog1 (drgnx-cockpit--open-file node)
           (when (plist-get node :readonly)
             (message "%s is read-only here: no job runs it.  Start Job from Plan… (job-start) starts one"
                      (or (plist-get node :title) (plist-get node :id))))))
        (t (drgnx-cockpit--open-job node))))

(defun drgnx-cockpit--open-job (node)
  "Open NODE's job: its window (tasks, what needs you, decisions)."
  (if (and (plist-get node :job) (fboundp 'drgnx-job-ui-show)) (drgnx-job-ui-show (plist-get node :job))
    (message "%s has no job" (or (plist-get node :title) (plist-get node :id)))))

(defun drgnx-cockpit-graph-open-node (id)
  "Open the tab of node ID of the graph (`drgnx-cockpit-open-functions')."
  (let ((node (or (drgnx-cockpit--shown-node id) (user-error "The Work graph no longer shows %s" id))))
    (funcall (or (alist-get (plist-get node :kind) drgnx-cockpit-open-functions) #'drgnx-cockpit--open-file) node)))

(defun drgnx-cockpit--node-here (&optional prompt pred)
  "The node to act on: the node on this line of the outline, else the selected one (TAB) when PRED accepts it,
else one read with PROMPT among the nodes PRED accepts."
  (let ((pred (or pred #'identity)))
    (or (and (derived-mode-p 'drgnx-cockpit-graph-mode) (not drgnx-cockpit--svg)
             (get-text-property (line-beginning-position) 'drgnx-cockpit-node))
        (when-let* ((id (buffer-local-value 'drgnx-cockpit--selected (drgnx-cockpit-graph-buffer)))
                    (node (drgnx-cockpit--shown-node id)) ((funcall pred node)))
          id)
        (let* ((nodes (seq-filter pred (plist-get (buffer-local-value 'drgnx-cockpit--model (drgnx-cockpit-graph-buffer)) :nodes)))
               (choices (mapcar (lambda (n) (cons (format "%s: %s%s" (capitalize (symbol-name (plist-get n :kind))) (plist-get n :title)
                                                          (if (plist-get n :state) (format " (%s)" (plist-get n :state)) ""))
                                                  (plist-get n :id)))
                                nodes)))
          (unless choices (user-error "Nothing to open"))
          (cdr (assoc (completing-read (or prompt "Open: ") choices nil t) choices))))))

(defun drgnx-cockpit-graph-click (event)
  "Open the node under the click EVENT: a box of the drawing (its hot spot) or a line of the outline."
  (interactive "e")
  (let* ((start (event-start event)) (w (posn-window start)))
    (when (window-live-p w) (select-window w))         ; what opens goes beside the graph
    (let ((id (or (alist-get (posn-area start) (buffer-local-value 'drgnx-cockpit--spots (drgnx-cockpit-graph-buffer)))
                  (and (integer-or-marker-p (posn-point start)) (window-live-p w)
                       (get-text-property (posn-point start) 'drgnx-cockpit-node (window-buffer w))))))
      (if id (drgnx-cockpit-graph-open-node id) (message "Work graph: click a node to open it")))))

;;;; Commands

(defun drgnx-cockpit-graph-show ()
  "Show the Work graph in its pane and focus it; returns its window."
  (interactive)
  (let ((w (if (drgnx-pane-kind 'work-graph) (drgnx-pane-focus 'work-graph)
             (pop-to-buffer (drgnx-cockpit-graph-buffer))
             (selected-window))))
    (drgnx-cockpit-graph-redraw)
    w))

(defun drgnx-cockpit-graph-open (id)
  "Open the tab of node ID (the node on this line, else the selected one): a spec or plan at its line, a task in its
plan (read-only when no job runs it), an agent's transcript, a job's window."
  (interactive (list (drgnx-cockpit--node-here)))
  (drgnx-cockpit-graph-open-node id))

(defun drgnx-cockpit--plan-place (node)
  "(PATH . LINE) of NODE in its plan or spec: its own for a spec, plan, task or TODO; a job's plan; an agent's task's."
  (let ((model (buffer-local-value 'drgnx-cockpit--model (drgnx-cockpit-graph-buffer))))
    (pcase (plist-get node :kind)
      ((or 'spec 'plan 'task 'todo 'job) (and (plist-get node :path) (cons (plist-get node :path) (or (plist-get node :line) 1))))
      ('agent (seq-some (lambda (e) (and (eq (plist-get e :kind) 'assigned) (equal (plist-get e :to) (plist-get node :id))
                                         (drgnx-cockpit--plan-place (drgnx-cockpit--shown-node (plist-get e :from)))))
                        (plist-get model :edges))))))

(defun drgnx-cockpit-graph-open-in-plan (id)
  "Open node ID's plan at its line (a task's heading; an agent's task's)."
  (interactive (list (drgnx-cockpit--node-here "Open in plan: " #'drgnx-cockpit--plan-place)))
  (let* ((node (or (drgnx-cockpit--shown-node id) (user-error "The Work graph no longer shows %s" id)))
         (place (or (drgnx-cockpit--plan-place node) (user-error "%s is in no plan" (plist-get node :title)))))
    (drgnx-cockpit--show-file (car place) (cdr place))))

(defun drgnx-cockpit-graph-refresh ()
  "Read the store again and draw the Work graph now."
  (interactive)
  (drgnx-cockpit-graph-buffer)
  (drgnx-cockpit-graph-redraw t))

(defun drgnx-cockpit-graph-filter (milestone agent states)
  "Show only the nodes of MILESTONE (a text in their title or path, or an ancestor's), of AGENT, in STATES, with
their ancestors; each empty: any."
  (interactive
   (let* ((m (drgnx-cockpit-model :sessions (drgnx-cockpit-sessions) :silent drgnx-cockpit--silent))
          (f drgnx-cockpit-graph-current-filter)
          (titles (delete-dups (delq nil (mapcar (lambda (n) (and (memq (plist-get n :kind) '(spec plan)) (plist-get n :title)))
                                                 (plist-get m :nodes)))))
          (agents (mapcar (lambda (a) (cons (format "%s (%s)" (or (plist-get a :name) (plist-get a :id)) (plist-get a :id)) (plist-get a :id)))
                          (plist-get m :agents))))
     (list (completing-read "Milestone — a text in a title or path (empty: all): " titles nil nil nil nil (plist-get f :milestone))
           (cdr (assoc (completing-read "Agent (empty: all): " agents nil t) agents))
           (completing-read-multiple "States (comma between; empty: all): "
                                     (delete-dups (delq nil (mapcar (lambda (n) (plist-get n :state)) (plist-get m :nodes))))))))
  (setq drgnx-cockpit-graph-current-filter
        (list :milestone (and (stringp milestone) (not (string-empty-p milestone)) milestone)
              :agent (and (stringp agent) (not (string-empty-p agent)) agent)
              :states (seq-remove #'string-empty-p states)))
  (drgnx-cockpit-graph-refresh))

;;;; The module

(defun drgnx-cockpit--setup ()
  "tools/cockpit's setup: the Work graph's pane kind and its commands."
  (drgnx-pane-define-kind 'work-graph :title " WORK GRAPH" :home 'left :view 'work
                          :buffer #'drgnx-cockpit-graph-buffer :on-show #'drgnx-cockpit--on-show)
  (pcase-dolist (`(,id ,title ,fn ,doc)
                 '((cockpit-filter "Filter Graph…" drgnx-cockpit-graph-filter "Only a milestone's, an agent's or some states' nodes")
                   (cockpit-open "Open Node" drgnx-cockpit-graph-open "Its tab: a file at its line, a transcript, a job's window")
                   (cockpit-open-in-plan "Open in Plan" drgnx-cockpit-graph-open-in-plan "The plan at this task's heading")
                   (cockpit-refresh "Draw Graph Again" drgnx-cockpit-graph-refresh "Read the store again and draw the Work graph")
                   (cockpit-next "Select Next Node" drgnx-cockpit-graph-select-next "The next node, in column order; RET opens it")
                   (cockpit-previous "Select Previous Node" drgnx-cockpit-graph-select-previous "The previous node; RET opens it")))
    (drgnx-command-define id :category "Work" :title title :command fn :doc doc :map 'drgnx-cockpit-graph-mode-map))
  ;; an agent's edits (drgnx-cockpit-edits.el): a task or an agent of the graph opens them
  (drgnx-pane-define-kind 'agent-edits :title " EDITS" :home 'editor :buffer #'drgnx-cockpit-edits-pane-buffer)
  (drgnx-cockpit-edits--setup))

(drgnx-module-define 'tools/cockpit
                     :doc "The Work cockpit: the Work graph — specs, plans, tasks, agents, jobs and reviews; drawn in windows, an outline in terminals."
                     :stage 'startup :requires '(tools/work tools/jobs)
                     :setup #'drgnx-cockpit--setup)

(provide 'drgnx-cockpit)
;;; drgnx-cockpit.el ends here
