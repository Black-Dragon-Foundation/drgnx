;;; drgnx-work-trail.el --- The Work space's Timeline and research trail, and steering (library of tools/work-space) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The Timeline is the third view of the lens: a lane for each agent, its steps as segments on a shared time axis,
;; coloured by what the step was.  The trail is the Timeline zoomed into one agent: its steps in order, newest at the
;; bottom, with the agent's conclusions (decisions and findings) as cards among them.  Both are hub-fed views
;; (`work/trail/subscribe'): the hub builds their rows and their models, and their keys answer from the model in Sjá.
;; Enter opens a step's source.  The steering keys (`s' steer, `p' pause, `u' resume, `x' stop) work in every Work view
;; on the agent that is selected there; none of them cancels the agent's work except `x', after a confirmation.  Beside
;; a map without Sjá, a trail and the Timeline say the map needs it.
;; Loaded by tools/work-space (drgnx-work-space.el); defines no module.  See docs/develop/work-space.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-view)
(require 'drgnx-view-nav)
(require 'drgnx-work-client)
(unless (featurep 'drgnx-work-board)
  (load (expand-file-name "drgnx-work-board" (file-name-directory (or load-file-name buffer-file-name))) nil t))
(unless (featurep 'drgnx-work-code)
  (load (expand-file-name "drgnx-work-code" (file-name-directory (or load-file-name buffer-file-name))) nil t))
(declare-function drgnx-work-code-local-dir "drgnx-work-code")
(declare-function drgnx-work-code-local-file "drgnx-work-code")
(declare-function drgnx-work-hunk-mode "drgnx-work-code")

(declare-function drgnx-hub-call "drgnx-hub-client")
(declare-function nidhogg-view-get "nidhogg-views" (h what &optional arg arg2))
(declare-function nidhogg-view-set "nidhogg-views" (h what value))
(declare-function drgnx-view-env-register "drgnx-view-env")
(declare-function drgnx-work--open-agent "drgnx-work-map")
(declare-function drgnx-work-map-buffer "drgnx-work-map")
(declare-function drgnx-work-map--class-index "drgnx-work-map" (h name))
(declare-function drgnx-work-lens-string "drgnx-work-map")
(declare-function drgnx-work-lens-map-buffer "drgnx-work-board")
(declare-function drgnx-work-board--rows-p "drgnx-work-board")
(declare-function drgnx-surfaces-cheatsheet "drgnx-surfaces")
(declare-function drgnx-agent-session-remote "drgnx-agents")
(declare-function drgnx-agent-session-cwd "drgnx-agents")
(defvar drgnx-agents--sessions)
(defvar drgnx-work-lens--map)
(defvar drgnx-work-lens-nav)
(defvar drgnx-work-lens-map)
(defvar drgnx-work-map--lens)
(defvar drgnx-work-map-no-sja)
(defvar drgnx-chrome-own-tab-line)
(declare-function drgnx-work-lens-name "drgnx-work-map")
(defvar drgnx-work-map--selection)
(defvar drgnx-work-review--session)

(defcustom drgnx-work-resume-text "Continue."
  "The prompt `u' sends to resume a paused agent: a plain continue, labelled \"resumed by you\" in the trail."
  :type 'string :group 'drgnx-work-space)

;;;; What a step is

(defun drgnx-work-trail-kind (step)
  "The kind of STEP, a plist as the trail's model gives it: `read', `search', `web', `thought', `edit', `job',
`waiting' or `tool'.  Taken from the step's class and what the hub recorded it read or fetched, never from its prose."
  (pcase (plist-get step :class)
    ("think" 'thought)
    ((or "user-wait" "machine-queue" "paused" "stalled") 'waiting)
    ("job-wait" 'job)
    (_ (pcase (plist-get (plist-get step :detail) :kind)
         ("read" 'read) ("search" 'search) ("fetch" 'web) ("edit" 'edit) (_ 'tool)))))

;;;; The trail's buffer

(defvar-local drgnx-work-trail--session nil "The hub session whose steps this trail shows.")

(defvar drgnx-work-trail-mode-map
  (let ((m (make-sparse-keymap))) (set-keymap-parent m drgnx-work-lens-map) m)
  "Keys of a trail.  The key profiles bind them (`drgnx-command-define' with this map).")

(define-derived-mode drgnx-work-trail-mode special-mode "Work trail"
  "The Work space's research trail: one agent's steps in order, with its conclusions among them."
  (setq-local truncate-lines t cursor-type nil tab-line-format '("" drgnx-work-map--lens)
              drgnx-view-nav-list "steps"))  ; a key past the window pages the model's steps

(defun drgnx-work-trail-buffers ()
  (seq-filter (lambda (b) (and (eq (buffer-local-value 'major-mode b) 'drgnx-work-trail-mode) (not (drgnx-view-patch-twin-p b)))) (buffer-list)))

;;;; The hub's rows: the trail and the Timeline built in the hub (`work/trail/subscribe')

(defvar-local drgnx-work-trail--hub-params nil
  "What `work/trail/subscribe' takes besides the view: (:session SID) or (:lanes [...]).")

(declare-function drgnx-work-map-rows-p "drgnx-work-map")

(defun drgnx-work-trail--map-rows-p (map-buffer)
  "Whether MAP-BUFFER's map is on the hub's rows (its Timeline goes there too: its lanes are the map model's agents)."
  (and (buffer-live-p map-buffer) (buffer-local-value 'drgnx-view-patch map-buffer) t))

(defun drgnx-work-trail--hub-subscribe ()
  "Ask the hub for this buffer's trail or Timeline (again after a reconnect, as its env's RESUBSCRIBE)."
  (when drgnx-view-patch
    (drgnx-work-client--call "work/trail/subscribe"
                             (append (list :view (drgnx-view-patch-view drgnx-view-patch)) drgnx-work-trail--hub-params)
                             #'ignore)))

(defun drgnx-work-trail--hub-close ()
  "`kill-buffer-hook' of a trail or Timeline: the hub ends its view."
  (when drgnx-view-patch
    (ignore-errors (drgnx-work-client--call "work/trail/close" (list :view (drgnx-view-patch-view drgnx-view-patch)) #'ignore))))

(declare-function drgnx-view-env-twin "drgnx-view-env" (class prefixes &optional setup))

(defun drgnx-work-trail--twin (class)
  "The trail's or Timeline's buffer in display CLASS (`drgnx-view-patch-twin-function'): its state and its lens's,
read again before each command there; a Timeline's lit lanes on its own instance in Sjá."
  (drgnx-view-env-twin class '("drgnx-work-trail-" "drgnx-work-timeline-" "drgnx-work-lens-")
                       (lambda () (when (derived-mode-p 'drgnx-work-timeline-mode) (drgnx-work-timeline-rows-attached)))))

(defun drgnx-work-trail--rows-attach (view params)
  "Make the current buffer the hub-fed trail or Timeline VIEW and ask the hub for it with PARAMS."
  (drgnx-view-patch-attach view "unshown")
  (setq-local drgnx-view-patch-twin-function #'drgnx-work-trail--twin)
  (setq drgnx-work-trail--hub-params params)
  (require 'drgnx-view-env)
  (let ((buffer (current-buffer)))
    (drgnx-view-env-register view buffer (lambda (_view) (when (buffer-live-p buffer)
                                                           (with-current-buffer buffer (drgnx-work-trail--hub-subscribe))))))
  (add-hook 'kill-buffer-hook #'drgnx-work-trail--hub-close nil t)
  (drgnx-work-trail--hub-subscribe))

(defun drgnx-work-trail--no-rows ()
  "Say in this new buffer that its map needs Sjá."
  (let ((inhibit-read-only t)) (insert drgnx-work-map-no-sja "\n")))

;;;; Opening a trail

(defun drgnx-work-trail--sid (agent-id)
  "The hub session of the map item AGENT-ID (a subagent's is its parent's)."
  (car (split-string (substring agent-id (length "agent:")) "/")))

(defun drgnx-work-trail-open (map-buffer session)
  "The trail of hub SESSION, made when there is none: the hub builds its steps, conclusions and model.  MAP-BUFFER is
the map the trail is a view of.  Returns the buffer; it does not show itself."
  (let ((buffer (get-buffer-create (format "*drgnx work trail: %s*" session))))
    (with-current-buffer buffer
      (unless (and (derived-mode-p 'drgnx-work-trail-mode) (equal drgnx-work-trail--session session))
        (drgnx-work-trail-mode)
        (setq drgnx-work-trail--session session drgnx-work-lens-nav #'drgnx-work-trail--nav)
        (if (drgnx-work-map-rows-p)   ; a trail is the session's, with or without a map beside it
            (drgnx-work-trail--rows-attach (format "trail/%s" session) (list :session session))
          (drgnx-work-trail--no-rows)))
      (setq drgnx-work-lens--map map-buffer drgnx-work-map--lens (drgnx-work-lens-string 'timeline)))
    buffer))

(declare-function drgnx-face-glyph "drgnx-ui-kit")

(defun drgnx-work-trail-panel-string (label)
  "The tab line of the trail tile under the map (work-space-dark.html): the tab \"Trail · LABEL\" shown, \"Agent · LABEL\"
quiet, and \"following\" at its right (the tile follows the map's selection)."
  (concat (propertize (format " %s Trail · %s " (or (drgnx-face-glyph 'clock) "") label) 'face '(bold drgnx-pill-on))
          " "
          (propertize (format " Agent · %s " label) 'face 'drgnx-work-label)
          "   "
          (propertize " following ▾ " 'face 'drgnx-pill)))

(defvar drgnx-area-own-title)

(defun drgnx-work-trail-panel-title (label)
  "In the current trail buffer, shown as the tile under the map: its own title row, the tabs of
`drgnx-work-trail-panel-string' (the bottom dock's tabs stay off it)."
  (setq-local drgnx-area-own-title (drgnx-work-trail-panel-string label)))

;;;; Lighting the steps behind a conclusion: the model's chain class

(defun drgnx-work-trail--lit (kind)
  "The nodes of KIND (\"step\" or \"conclusion\") the selection lights (the model's class `chain'), in the rows' order:
a selected conclusion lights the steps it rests on, a selected step the conclusions that rest on it."
  (let* ((h (drgnx-view-patch-handle drgnx-view-patch)) (chain (drgnx-work-map--class-index h "chain"))
         (prop drgnx-view-patch-id-prop) (pos (point-min)) out)
    (while (< pos (point-max))
      (let ((id (get-text-property pos prop)))
        (when (and id chain (not (member id out)) (equal (nidhogg-view-get h 'kind id) kind)
                   (eql chain (nidhogg-view-get h 'class id)))
          (push id out)))
      (setq pos (next-single-property-change pos prop nil (point-max))))
    (nreverse out)))

(defun drgnx-work-trail--require-kind (kind what)
  "The selection of this trail when it is of KIND, else a user error that asks for WHAT."
  (unless (drgnx-work-trail--rows-p) (user-error "%s" drgnx-work-map-no-sja))
  (let ((id (drgnx-view-nav-selection)))
    (unless (and id (equal (nidhogg-view-get (drgnx-view-patch-handle drgnx-view-patch) 'kind id) kind))
      (user-error "Select %s first" what))
    id))

(defun drgnx-work-trail-show-steps ()
  "On a conclusion: go to the first step it rests on (lit by the selection); again, to the next."
  (interactive)
  (drgnx-work-trail--require-kind "conclusion" "a conclusion")
  (let* ((ids (drgnx-work-trail--lit "step"))
         (here (get-text-property (point) drgnx-view-patch-id-prop))
         (next (or (cadr (member here ids)) (car ids))))
    (if next
        (drgnx-view-nav--place-point drgnx-view next)
      (message "Work: this conclusion names no steps"))))

(defun drgnx-work-trail-show-conclusions ()
  "On a step: select the first conclusion that rests on it."
  (interactive)
  (drgnx-work-trail--require-kind "step" "a step")
  (if-let* ((c (car (drgnx-work-trail--lit "conclusion"))))
      (drgnx-view-nav 'select c)
    (message "Work: no conclusion rests on this step")))

;;;; Opening a step's source

(defun drgnx-work-trail--cwd (sid)
  "The folder of session SID, as this Emacs's mirror of it knows it, or nil; nil too when it is not a local folder
\(`drgnx-work-code-local-dir': the folder is the hub's word, and no file name handler runs on it)."
  (when-let* ((s (and (boundp 'drgnx-agents--sessions)
                      (seq-find (lambda (x) (equal (drgnx-agent-session-remote x) sid)) drgnx-agents--sessions))))
    (drgnx-work-code-local-dir (drgnx-agent-session-cwd s))))

(defun drgnx-work-trail--show (buffer beside)
  (if beside (display-buffer buffer) (pop-to-buffer buffer))
  buffer)

(defun drgnx-work-trail--text-buffer (name text &optional mode file-name)
  "A new read-only buffer NAME holding TEXT, in MODE (else the mode FILE-NAME would have); one of that name that was
there is killed first."
  (when-let* ((old (get-buffer name))) (kill-buffer old))
  (with-current-buffer (get-buffer-create name)
    (insert text)
    (goto-char (point-min))
    ;; FILE-NAME is the agent's: the mode is chosen from it with no file name handler running
    (if mode (funcall mode)
      (when file-name (let ((buffer-file-name file-name) (file-name-handler-alist nil)) (set-auto-mode))))
    (setq buffer-file-name nil buffer-read-only t)
    (current-buffer)))

(defun drgnx-work-trail-open-step (step &optional beside as-read)
  "Open the source of STEP: a read at its lines (AS-READ: the file as the agent read it, from `work/file-at', in a
read-only buffer `FILE@step-N'), a search run again now, a page in the browser, a thought in the transcript, an edit as
its diff.  BESIDE: without moving focus.  Returns the buffer when it is there at once."
  (let* ((sid (or (plist-get step :session) drgnx-work-trail--session)) (d (plist-get step :detail))
         (path (plist-get d :path)) (seq (plist-get step :seq)) result)
    (pcase (drgnx-work-trail-kind step)
      ('read
       (cond
        ((null path) (message "Work: this read recorded no file"))
        (as-read
         (drgnx-hub-call "work/file-at" (list :session sid :path path :seq seq)
                         (lambda (r err)
                           (if err
                               (message "Work: %s" err)
                             (setq result (drgnx-work-trail--show
                                           (drgnx-work-trail--text-buffer
                                            (format "%s@step-%d" (file-name-nondirectory path) seq)
                                            (decode-coding-string (base64-decode-string (plist-get r :bytes)) 'utf-8)
                                            nil path)
                                           beside))))))
        ;; the step's path is the agent's: only a plain local file inside its folder opens, by its true name
        (t (if-let* ((file (drgnx-work-code-local-file path (list (drgnx-work-trail--cwd sid)))))
               (let ((buf (find-file-noselect file)))
                 (with-current-buffer buf
                   (when-let* ((line (plist-get d :line_start)))
                     (goto-char (point-min)) (forward-line (1- line))))
                 (setq result (drgnx-work-trail--show buf beside)))
             (message "Work: %s is no plain local file in the agent's folder" path)))))
      ('search
       (let ((q (plist-get d :query)) (cwd (drgnx-work-trail--cwd sid)))
         (cond ((null q) (message "Work: this search recorded no query"))
               ((null cwd) (message "Work: the agent's folder is not a local one here"))
               (t (message "Work: run again now: %s" q)
                  (let ((default-directory cwd)) (project-find-regexp (regexp-quote q)))))))
      ('web (if-let* ((url (plist-get d :url))) (browse-url url) (message "Work: this step recorded no page")))
      ('thought (drgnx-work--open-agent sid))
      ('edit
       (if (null path)
           (message "Work: this edit recorded no file")
         (drgnx-hub-call "work/hunks" (list :session sid :path path)
                         (lambda (r err)
                           (if err
                               (message "Work: %s" err)
                             (setq result (drgnx-work-trail--show
                                           (drgnx-work-trail--text-buffer (format "*Work hunk: %s*" path)
                                                                          (or (plist-get r :diff) "") #'drgnx-work-hunk-mode)
                                           beside)))))))
      (_ (message "Work: nothing to open for this step")))
    result))

(defun drgnx-work-trail--open-conclusion (c beside)
  (let ((text (concat (format "%s %d  %s\n\nOrigin: %s\n" (plist-get c :kind) (plist-get c :n) (plist-get c :text)
                              (plist-get c :origin))
                      (if-let* ((ss (plist-get c :sources)))
                          (concat "\nSources:\n"
                                  (mapconcat (lambda (s) (concat "  " (or (plist-get s :path) (plist-get s :url))
                                                                 (if-let* ((l (plist-get s :lines))) (format ":%d–%d" (car l) (cadr l)) "")))
                                             ss "\n")
                                  "\n")
                        ""))))
    (drgnx-work-trail--show (drgnx-work-trail--text-buffer (format "*Work conclusion %d*" (plist-get c :n)) text) beside)))

;;;; The keys, through the native view model (Sjá)

(defun drgnx-work-trail--rows-p ()
  "Whether this trail or Timeline is a hub-fed view with Sjá's model."
  (and drgnx-view-patch (drgnx-view-patch-handle drgnx-view-patch) t))

(defun drgnx-work-trail--model-step (&optional id)
  "The step node ID (default: the selection) of the model as the step plist `drgnx-work-trail-open-step' takes, or nil
when ID is no step."
  (let ((id (or id (drgnx-view-nav-selection))) (h (drgnx-view-patch-handle drgnx-view-patch)))
    (when (and id (equal (nidhogg-view-get h 'kind id) "step"))
      (let ((f (lambda (name) (drgnx-view-nav-field name id))))
        (list :seq (funcall f "seq") :session (funcall f "session") :class (funcall f "class") :tool (funcall f "tool")
              :detail (list :kind (funcall f "detail-kind") :path (funcall f "path") :line_start (funcall f "line")
                            :query (funcall f "query") :url (funcall f "url")))))))

(defun drgnx-work-trail--rows-nav (dir)
  "DIR of the lens: a move follows the selection's link of that name (`next-agent' and `previous-agent' are `down' and
`up'); `open' and `open-beside' open the selected step or conclusion.  Nothing without the model."
  (when (drgnx-work-trail--rows-p)
    (pcase dir
      ((or 'left 'right 'up 'down) (drgnx-view-nav 'follow (symbol-name dir)))
      ('next-agent (drgnx-view-nav 'follow "down"))
      ('previous-agent (drgnx-view-nav 'follow "up"))
      ((or 'open 'open-beside)
       (let ((beside (eq dir 'open-beside)) (id (drgnx-view-nav-selection)))
         (cond
          ((drgnx-work-trail--model-step id)
           (drgnx-work-trail-open-step (drgnx-work-trail--model-step id) beside beside))
          ((and id (equal (nidhogg-view-get (drgnx-view-patch-handle drgnx-view-patch) 'kind id) "conclusion"))
           (drgnx-work-trail--open-conclusion (list :kind (drgnx-view-nav-field "conclusion-kind" id)
                                                    :n (drgnx-view-nav-field "n" id) :text (drgnx-view-nav-field "label" id))
                                              beside))
          (t (message "Work: no step is selected")))))))
  t)

(defun drgnx-work-timeline-rows-attached ()
  "The Timeline buffer is a hub-fed view: its lit lanes are the model's list `near' (the lanes the map's selection
reaches, which the hub keeps), in the chain's face."
  (setq-local drgnx-view-nav-faces '(("lit" . drgnx-work-chain)))
  (setf (drgnx-view-patch-class-faces drgnx-view-patch) nil)
  (nidhogg-view-set (drgnx-view-patch-handle drgnx-view-patch) 'lit "near"))

(defun drgnx-work-trail--nav (dir)
  "A key of the lens in a trail: DIR is `left' `up' (the earlier row), `right' `down' (the later), `open' or
`open-beside' (a step's source; S-RET: a read as the agent read it); the agent keys do nothing here."
  (unless (memq dir '(next-agent previous-agent)) (drgnx-work-trail--rows-nav dir))
  t)

;;;; Steering: the same keys in every Work view, on the agent selected there

(defun drgnx-work-trail--agent-sid ()
  "The hub session of the agent selected in the current Work view, or an error saying there is none."
  (or (cond ((derived-mode-p 'drgnx-work-trail-mode) drgnx-work-trail--session)
            ((derived-mode-p 'drgnx-work-review-mode) (bound-and-true-p drgnx-work-review--session))
            ((derived-mode-p 'drgnx-work-timeline-mode)
             (when (and (drgnx-work-trail--rows-p) (drgnx-view-nav-selection)) (drgnx-view-nav-field "session")))
            ((derived-mode-p 'drgnx-work-board-mode)       ; the selected card's agent, from the Board's model
             (when-let* ((agent (and (drgnx-work-board--rows-p) (drgnx-view-nav-selection) (drgnx-view-nav-field "agent"))))
               (drgnx-work-trail--sid agent)))
            ((derived-mode-p 'drgnx-work-map-mode)
             (when-let* ((sel drgnx-work-map--selection) ((memq (car sel) '(agent subagent))))
               (drgnx-work-trail--sid (cdr sel)))))
      (user-error "Select an agent first")))

(defun drgnx-work-trail-steer ()
  "Message the selected agent: queued or steering as its mode says, never a cancel."
  (interactive)
  (let* ((sid (drgnx-work-trail--agent-sid)) (text (read-string "Steer the agent: ")))
    (unless (string-empty-p text) (drgnx-hub-call "agents/send" (list :id sid :text text) #'ignore))))

(defun drgnx-work-trail-pause ()
  "Pause the selected agent after its current tool call; a notice says so and `u' resumes."
  (interactive)
  (let ((sid (drgnx-work-trail--agent-sid)))
    (drgnx-hub-call "agents/pause" (list :id sid) #'ignore)
    (message "Work: Pausing after the current tool call · u resume")))

(defun drgnx-work-trail-resume ()
  "Resume the selected agent with a plain continue prompt."
  (interactive)
  (let ((sid (drgnx-work-trail--agent-sid)))
    (drgnx-hub-call "agents/send" (list :id sid :text drgnx-work-resume-text) #'ignore)
    (message "Work: Resumed")))

(defun drgnx-work-trail-stop ()
  "Stop the selected agent, after a confirmation line."
  (interactive)
  (let ((sid (drgnx-work-trail--agent-sid)))
    (when (y-or-n-p (format "Stop the agent %s? " sid))
      (drgnx-hub-call "agents/stop" (list :id sid) #'ignore))))

(defun drgnx-work-trail-show ()
  "The research trail of the selected agent, in this window."
  (interactive)
  (pop-to-buffer-same-window (drgnx-work-trail-open (drgnx-work-lens-map-buffer) (drgnx-work-trail--agent-sid))))

(defun drgnx-work-keys-sheet ()
  "This mode's keys: the keyboard shortcuts sheet."
  (interactive)
  (drgnx-surfaces-cheatsheet))

;;;; The Timeline: a lane for each agent

;; the segments' faces, which the hub's rows name
(defface drgnx-work-seg-read '((t :inherit ansi-color-blue :inverse-video t)) "Reads, searches and pages in the Timeline."
  :group 'drgnx-work-space)
(defface drgnx-work-seg-edit '((t :inherit ansi-color-green :inverse-video t)) "Edits in the Timeline." :group 'drgnx-work-space)
(defface drgnx-work-seg-tool '((t :inherit ansi-color-cyan :inverse-video t)) "Other tool calls in the Timeline."
  :group 'drgnx-work-space)
(defface drgnx-work-seg-think '((t :inherit shadow :inverse-video t)) "Thinking in the Timeline." :group 'drgnx-work-space)
(defface drgnx-work-seg-job '((t :inherit ansi-color-magenta :inverse-video t)) "Waiting on a job in the Timeline."
  :group 'drgnx-work-space)
(defface drgnx-work-seg-wait '((t :inherit ansi-color-yellow :inverse-video t)) "Waiting for you or a machine in the Timeline."
  :group 'drgnx-work-space)

(defvar drgnx-work-timeline-mode-map
  (let ((m (make-sparse-keymap))) (set-keymap-parent m drgnx-work-lens-map) m)
  "Keys of the Timeline.  The key profiles bind them (`drgnx-command-define' with the lens map).")

(define-derived-mode drgnx-work-timeline-mode special-mode "Work timeline"
  "The Work space's Timeline: a lane for each agent, its steps as segments over time."
  (setq-local truncate-lines t cursor-type nil drgnx-chrome-own-tab-line t tab-line-format '("" drgnx-work-map--lens)))

(defun drgnx-work-timeline-buffers ()
  (seq-filter (lambda (b) (and (eq (buffer-local-value 'major-mode b) 'drgnx-work-timeline-mode) (not (drgnx-view-patch-twin-p b)))) (buffer-list)))

(defun drgnx-work-timeline-open (map-buffer)
  "The Timeline of MAP-BUFFER, made when there is none: the hub builds a lane per agent of the map's model, lit by the
map's selection there."
  (let ((buffer (get-buffer-create (format "*drgnx work timeline: %s*" (string-trim (buffer-name map-buffer) "\\*drgnx work: " "\\*")))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'drgnx-work-timeline-mode)
        (drgnx-work-timeline-mode)
        (setq drgnx-work-lens-nav #'drgnx-work-timeline--nav)
        (if (drgnx-work-trail--map-rows-p map-buffer)
            (progn
              (drgnx-work-trail--rows-attach (format "timeline/%s" (drgnx-view-patch-view (buffer-local-value 'drgnx-view-patch map-buffer)))
                                             (list :lanes (vconcat (drgnx-work-timeline--model-lanes map-buffer))))
              (drgnx-work-timeline-rows-attached))
          (drgnx-work-trail--no-rows)))
      (setq drgnx-work-lens--map map-buffer
            drgnx-work-map--lens (drgnx-work-lens-string 'timeline (drgnx-work-lens-name map-buffer))))
    buffer))

(defun drgnx-work-timeline--model-lanes (map-buffer)
  "The lanes of a Timeline of MAP-BUFFER's map: its model's agents (not their subagents), in team order, as
`work/trail/subscribe' takes them ({session, label})."
  (with-current-buffer map-buffer
    (when-let* ((h (and drgnx-view-patch (drgnx-view-patch-handle drgnx-view-patch))))
      (delq nil (mapcar (lambda (id)
                          (when (and (equal (nidhogg-view-get h 'kind id) "agent") (not (string-search "/" id)))
                            (list :session (drgnx-work-trail--sid id)
                                  :label (or (drgnx-view-nav-field "label" id) (drgnx-work-trail--sid id)))))
                        (append (nidhogg-view-get h 'list "team") nil))))))

(defun drgnx-work-timeline--nav (dir)
  "A key of the lens in the Timeline: DIR moves to the earlier or later step of the lane (`left' `right'), the lane
above or below (`up' `down', `previous-agent' `next-agent'), or opens the step (`open' `open-beside'); the model's
links say where (`drgnx-work-trail--rows-nav')."
  (drgnx-work-trail--rows-nav dir))

(provide 'drgnx-work-trail)
;;; drgnx-work-trail.el ends here
