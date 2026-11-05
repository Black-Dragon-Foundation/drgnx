;;; drgnx-work-trail.el --- The Work space's Timeline and research trail, and steering (library of tools/work-space) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The Timeline is the third view of the lens: a lane for each agent, its steps as segments on a shared time axis,
;; coloured by what the step was.  The trail is the Timeline zoomed into one agent: its steps in order, newest at the
;; bottom, following the tail while the agent works, with the agent's conclusions (decisions and findings) as cards among
;; them and a numbered pill on each step a conclusion rests on.  A trail opens with the last screenful (`timeline/get'
;; with a limit), pages back when the view scrolls near its top and takes new steps from the hub's `agent-step' events.
;; Enter opens a step's source.  The steering keys (`s' steer, `p' pause, `u' resume, `x' stop) work in every Work view
;; on the agent that is selected there; none of them cancels the agent's work except `x', after a confirmation.
;; Loaded by tools/work-space (drgnx-work-space.el); defines no module.  See docs/develop/work-space.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-view)
(require 'drgnx-work-client)
(unless (featurep 'drgnx-work-board)
  (load (expand-file-name "drgnx-work-board" (file-name-directory (or load-file-name buffer-file-name))) nil t))

(declare-function drgnx-hub-call "drgnx-hub-client")
(declare-function drgnx-work--open-agent "drgnx-work-map")
(declare-function drgnx-work-map--card-face "drgnx-work-map")
(declare-function drgnx-work-map--fit "drgnx-work-map")
(declare-function drgnx-work-map--state "drgnx-work-map")
(declare-function drgnx-work-map--field "drgnx-work-map")
(declare-function drgnx-work-map--outline-ids "drgnx-work-map")
(declare-function drgnx-work-map-buffer "drgnx-work-map")
(declare-function drgnx-work-lens-string "drgnx-work-map")
(declare-function drgnx-work-lens-map-buffer "drgnx-work-board")
(declare-function drgnx-work-board--agents-near "drgnx-work-board")
(declare-function drgnx-work-board-agent "drgnx-work-board")
(declare-function drgnx-work-nav-sel "drgnx-work-detail")
(declare-function drgnx-work-nav--team "drgnx-work-detail")
(declare-function drgnx-surfaces-cheatsheet "drgnx-surfaces")
(declare-function drgnx-agent-session-remote "drgnx-agents")
(declare-function drgnx-agent-session-cwd "drgnx-agents")
(defvar drgnx-agents--sessions)
(defvar drgnx-work-lens--map)
(defvar drgnx-work-lens-nav)
(defvar drgnx-work-lens-map)
(defvar drgnx-work-map--lens)
(defvar drgnx-work-map--selection)
(defvar drgnx-work-board--card)
(defvar drgnx-work-board--cards)
(defvar drgnx-work-timeline--sel)

(defcustom drgnx-work-trail-first-page 60
  "How many steps a trail opens with: the last screenful."
  :type 'integer :group 'drgnx-work-space)

(defcustom drgnx-work-trail-page 200
  "How many older steps a trail fetches when the view scrolls near its top."
  :type 'integer :group 'drgnx-work-space)

(defcustom drgnx-work-resume-text "Continue."
  "The prompt `u' sends to resume a paused agent: a plain continue, labelled \"resumed by you\" in the trail."
  :type 'string :group 'drgnx-work-space)

(defvar drgnx-work-trail-time-zone nil
  "The time zone the trail's times are shown in: nil, the local one (`format-time-string''s ZONE).  A test binds t.")

;;;; What a step is

(defconst drgnx-work-trail-icons
  '((read . "▤") (search . "⌕") (web . "◍") (thought . "…") (decision . "⚑") (finding . "✦") (edit . "✎")
    (job . "▦") (waiting . "◷") (tool . "›"))
  "The glyph of each kind of step, until the look's icons are built (read, search, page, thought, decision, finding,
edit, job, waiting).")

(defun drgnx-work-trail-kind (step)
  "The kind of STEP, a plist of the hub's `timeline/get': `read', `search', `web', `thought', `edit', `job', `waiting' or
`tool'.  Taken from the step's class and what the hub recorded it read or fetched, never from its prose."
  (pcase (plist-get step :class)
    ("think" 'thought)
    ((or "user-wait" "machine-queue" "paused" "stalled") 'waiting)
    ("job-wait" 'job)
    (_ (pcase (plist-get (plist-get step :detail) :kind)
         ("read" 'read) ("search" 'search) ("fetch" 'web) ("edit" 'edit) (_ 'tool)))))

(defun drgnx-work-trail-title (step)
  "STEP's title: `path:120–184' for a read, the query of a search, the host of a page with its title, `thinking' for a
thought, the path of an edit."
  (let* ((d (plist-get step :detail)) (path (plist-get d :path)))
    (pcase (drgnx-work-trail-kind step)
      ('read (cond ((null path) (or (plist-get step :tool) "read"))
                   ((and (plist-get d :line_start) (plist-get d :line_end))
                    (format "%s:%d–%d" path (plist-get d :line_start) (plist-get d :line_end)))
                   ((plist-get d :line_start) (format "%s:%d" path (plist-get d :line_start)))
                   (t path)))
      ('search (or (plist-get d :query) path (plist-get step :tool) "search"))
      ('web (let* ((url (plist-get d :url))
                   (host (and url (string-match "\\`[a-z]+://\\([^/?#]+\\)" url) (match-string 1 url))))
              (cond ((and host (plist-get d :title)) (format "%s · %s" host (plist-get d :title)))
                    (host host)
                    (t (or (plist-get d :query) (plist-get step :tool) "page")))))
      ('thought "thinking")
      ('edit (or path (plist-get step :tool) "edit"))
      ('job "waiting on a job")
      ('waiting (pcase (plist-get step :class)
                  ("user-wait" "waiting for you") ("machine-queue" "waiting for a machine")
                  ("paused" "paused") (_ "stalled")))
      (_ (or (plist-get step :tool) "tool")))))

(defun drgnx-work-trail--time (secs)
  (format-time-string "%H:%M:%S" secs drgnx-work-trail-time-zone))

(defun drgnx-work-trail--duration (step)
  "How long STEP took, `1.5s' or `2m05s'; nothing for a step that is still open."
  (when-let* ((end (plist-get step :end)) (start (plist-get step :start)))
    (let ((d (- end start))) (if (< d 60) (format "%.1fs" d) (format "%dm%02ds" (floor d 60) (mod (floor d) 60))))))

(defun drgnx-work-trail--rest-on (c)
  "The ids of the steps conclusion C rests on: those its named sources matched, then those since the last conclusion."
  (let ((links (plist-get c :links)))
    (delete-dups (append (plist-get links :named) (plist-get links :since_last)))))

;;;; Rows

(defun drgnx-work-trail-row-text (step conclusions &optional lit)
  "The row of STEP: its kind's icon, its title, the number of each of CONCLUSIONS resting on it, and at the right its
time and duration.  LIT: the ids of the steps lit (their pills fill and the row takes the chain's face)."
  (let* ((id (plist-get step :id)) (lit-p (memq id lit))
         (pills (mapconcat (lambda (c) (propertize (format " [%d]" (plist-get c :n))
                                                   'face (if lit-p 'drgnx-work-selected 'drgnx-work-chip)))
                           (seq-filter (lambda (c) (memq id (drgnx-work-trail--rest-on c))) conclusions) ""))
         (text (concat (propertize (cdr (assq (drgnx-work-trail-kind step) drgnx-work-trail-icons)) 'face 'drgnx-work-label)
                       " " (drgnx-work-trail-title step) pills
                       (propertize " " 'display '(space :align-to (- right 14)))
                       (drgnx-work-trail--time (plist-get step :start))
                       (if-let* ((d (drgnx-work-trail--duration step))) (concat " " d) "")
                       "\n")))
    (add-text-properties 0 (length text) (list 'drgnx-work-step id) text)
    (when lit-p (add-face-text-property 0 (length text) 'drgnx-work-chain t text))
    text))

(defun drgnx-work-trail-conclusion-text (c)
  "The card of conclusion C: its number and text, what it rests on, and its named sources no step matches."
  (let* ((n (length (drgnx-work-trail--rest-on c))) (kind (intern (plist-get c :kind)))
         (unmatched (plist-get (plist-get c :links) :unmatched))
         (l1 (format "%s %d  %s\n" (cdr (assq kind drgnx-work-trail-icons)) (plist-get c :n) (plist-get c :text)))
         (l2 (format "   based on %s%s\n" (if (zerop n) "no steps" (format "%d step%s" n (if (= n 1) "" "s")))
                     (if unmatched
                         (format " · named, not read in this session: %s"
                                 (mapconcat (lambda (s) (or (plist-get s :path) (plist-get s :url))) unmatched ", "))
                       ""))))
    (add-face-text-property 0 (length l1) (drgnx-work-map--card-face 2 0) t l1)
    (add-face-text-property 0 (length l2) (drgnx-work-map--card-face 2 1) t l2)
    (concat l1 l2)))

;;;; The trail's state

(defvar-local drgnx-work-trail--session nil "The hub session whose steps this trail shows.")
(defvar-local drgnx-work-trail--steps nil "The loaded steps, oldest first.")
(defvar-local drgnx-work-trail--by-id nil "Hash step id → step.")
(defvar-local drgnx-work-trail--conclusions nil "The session's conclusions (`work/conclusions').")
(defvar-local drgnx-work-trail--notes nil "Notes of what the user did, newest first: (KEY . TEXT).")
(defvar-local drgnx-work-trail--keys nil "The view's row keys in order.")
(defvar-local drgnx-work-trail--lit nil "The ids of the steps lit by `l' or `L'.")
(defvar-local drgnx-work-trail--more nil "Whether older steps may exist (the last page came back full).")
(defvar-local drgnx-work-trail--fetching nil "Whether an older page is on its way.")
(defvar-local drgnx-work-trail--loaded nil "Whether the first page has come.")

(defvar drgnx-work-trail-mode-map
  (let ((m (make-sparse-keymap))) (set-keymap-parent m drgnx-work-lens-map) m)
  "Keys of a trail.  The key profiles bind them (`drgnx-command-define' with this map).")

(define-derived-mode drgnx-work-trail-mode special-mode "Work trail"
  "The Work space's research trail: one agent's steps in order, with its conclusions among them."
  (setq-local truncate-lines t cursor-type nil tab-line-format '("" drgnx-work-map--lens))
  (add-hook 'post-command-hook #'drgnx-work-trail--maybe-page nil t))

(defun drgnx-work-trail-buffers ()
  (seq-filter (lambda (b) (eq (buffer-local-value 'major-mode b) 'drgnx-work-trail-mode)) (buffer-list)))

(defun drgnx-work-trail--step (id) (and drgnx-work-trail--by-id (gethash id drgnx-work-trail--by-id)))

(defun drgnx-work-trail--conclusion (n)
  (seq-find (lambda (c) (eql (plist-get c :n) n)) drgnx-work-trail--conclusions))

(defun drgnx-work-trail--render (key)
  (pcase (car key)
    (:step (if-let* ((s (drgnx-work-trail--step (cadr key))))
               (drgnx-work-trail-row-text s drgnx-work-trail--conclusions drgnx-work-trail--lit)
             "\n"))
    (:conc (if-let* ((c (drgnx-work-trail--conclusion (cadr key)))) (drgnx-work-trail-conclusion-text c) "\n"))
    (:note (concat (propertize (format "↺ %s" (cdr (assq (cadr key) drgnx-work-trail--notes))) 'face 'drgnx-work-label) "\n"))
    (_ "\n")))

(drgnx-view-define 'work-trail :render #'drgnx-work-trail--render :follow-tail t :slice drgnx-view-slice)

(defun drgnx-work-trail--conc-keys-after (step-id)
  "The row keys of the conclusions stamped on step STEP-ID."
  (mapcar (lambda (c) (list :conc (plist-get c :n)))
          (seq-filter (lambda (c) (eql (plist-get c :step) step-id)) drgnx-work-trail--conclusions)))

(defun drgnx-work-trail--build-keys ()
  "All the row keys: each step, the conclusions stamped on it, then the conclusions of no loaded step, then the notes."
  (append (apply #'append (mapcar (lambda (s) (cons (list :step (plist-get s :id))
                                                    (drgnx-work-trail--conc-keys-after (plist-get s :id))))
                                  drgnx-work-trail--steps))
          (mapcar (lambda (c) (list :conc (plist-get c :n)))
                  (seq-remove (lambda (c) (and (plist-get c :step) (drgnx-work-trail--step (plist-get c :step))))
                              drgnx-work-trail--conclusions))
          (mapcar (lambda (n) (list :note (car n))) (reverse drgnx-work-trail--notes))))

(defun drgnx-work-trail-install (buffer session steps conclusions)
  "Make BUFFER a trail of SESSION holding STEPS (oldest first) and CONCLUSIONS, drawn from scratch."
  (with-current-buffer buffer
    (unless (derived-mode-p 'drgnx-work-trail-mode)
      (drgnx-work-trail-mode)
      (drgnx-view-attach 'work-trail))
    (setq drgnx-work-trail--session session drgnx-work-trail--steps steps drgnx-work-trail--conclusions conclusions
          drgnx-work-trail--by-id (make-hash-table :test #'eql) drgnx-work-trail--lit nil
          drgnx-work-trail--loaded t drgnx-work-lens-nav #'drgnx-work-trail--nav)
    (dolist (s steps) (puthash (plist-get s :id) s drgnx-work-trail--by-id))
    (setq drgnx-work-trail--keys (drgnx-work-trail--build-keys))
    (drgnx-view-reset drgnx-view drgnx-work-trail--keys)))

;;;; Steps arriving: at the end live, at the top when paging back

(defun drgnx-work-trail--merge (steps)
  "Take STEPS (oldest first) not seen yet: newer than the last loaded ones go to the end, older than the first to the top."
  (let ((fresh (seq-remove (lambda (s) (drgnx-work-trail--step (plist-get s :id))) steps)))
    (when fresh
      (let* ((first (car drgnx-work-trail--steps))
             (older (seq-filter (lambda (s) (and first (< (plist-get s :seq) (plist-get first :seq)))) fresh))
             (newer (seq-remove (lambda (s) (memq s older)) fresh)))
        (dolist (s fresh) (puthash (plist-get s :id) s drgnx-work-trail--by-id))
        (when older
          (setq drgnx-work-trail--steps (append older drgnx-work-trail--steps))
          (let ((keys (apply #'append (mapcar (lambda (s) (cons (list :step (plist-get s :id))
                                                                (drgnx-work-trail--conc-keys-after (plist-get s :id))))
                                              older))))
            (setq drgnx-work-trail--keys (append keys drgnx-work-trail--keys))
            (drgnx-view-insert drgnx-view keys :after nil)))
        (when newer
          (setq drgnx-work-trail--steps (append drgnx-work-trail--steps newer))
          (let ((keys (apply #'append (mapcar (lambda (s) (cons (list :step (plist-get s :id))
                                                                (drgnx-work-trail--conc-keys-after (plist-get s :id))))
                                              newer))))
            (setq drgnx-work-trail--keys (append drgnx-work-trail--keys keys))
            (drgnx-view-append drgnx-view keys)))))))

(defun drgnx-work-trail--set-conclusions (conclusions)
  "Take CONCLUSIONS: each one not shown yet gets a card after the step it was stamped on, else at the end."
  (let ((known (mapcar (lambda (c) (plist-get c :n)) drgnx-work-trail--conclusions)))
    (setq drgnx-work-trail--conclusions conclusions)
    (dolist (c conclusions)
      (unless (memq (plist-get c :n) known)
        (let ((key (list :conc (plist-get c :n)))
              (at (and (plist-get c :step) (drgnx-work-trail--step (plist-get c :step)) (list :step (plist-get c :step)))))
          (if (and at (member at drgnx-work-trail--keys))
              (let ((cell (member at drgnx-work-trail--keys)))
                (setcdr cell (cons key (cdr cell)))
                (drgnx-view-insert drgnx-view (list key) :after at))
            (setq drgnx-work-trail--keys (append drgnx-work-trail--keys (list key)))
            (drgnx-view-append drgnx-view (list key))))))
    (drgnx-view-dirty drgnx-view (mapcar (lambda (s) (list :step (plist-get s :id))) drgnx-work-trail--steps))))

(defun drgnx-work-trail--request (buffer params fn)
  "Ask the hub for steps of BUFFER's session with PARAMS (`timeline/get' fields); FN gets the steps in BUFFER."
  (let ((sid (buffer-local-value 'drgnx-work-trail--session buffer)))
    (drgnx-hub-call "timeline/get" (append (list :scope "session" :id sid) params)
                    (lambda (result _err)
                      (when (buffer-live-p buffer)
                        (with-current-buffer buffer (funcall fn (plist-get result :steps))))))))

(defun drgnx-work-trail--fetch-conclusions (buffer)
  (when (buffer-live-p buffer)
    (drgnx-hub-call "work/conclusions" (list :session (buffer-local-value 'drgnx-work-trail--session buffer))
                    (lambda (result _err)
                      (when (buffer-live-p buffer)
                        (with-current-buffer buffer
                          (drgnx-work-trail--set-conclusions (plist-get result :conclusions))))))))

(defun drgnx-work-trail-page-back (&optional buffer)
  "Fetch the next page of older steps into BUFFER's trail (default: the current), unless there is none or one is on
its way."
  (with-current-buffer (or buffer (current-buffer))
    (when (and drgnx-work-trail--more (not drgnx-work-trail--fetching) drgnx-work-trail--steps)
      (setq drgnx-work-trail--fetching t)
      (drgnx-work-trail--request
       (current-buffer) (list :limit drgnx-work-trail-page :before (plist-get (car drgnx-work-trail--steps) :seq))
       (lambda (steps)
         (setq drgnx-work-trail--fetching nil drgnx-work-trail--more (>= (length steps) drgnx-work-trail-page))
         (drgnx-work-trail--merge steps))))))

(defun drgnx-work-trail--maybe-page ()
  "`post-command-hook' of a trail: older steps are fetched when point is within a screenful of the top."
  (when (and drgnx-work-trail--more (not drgnx-work-trail--fetching) (drgnx-view-p drgnx-view))
    (let ((edge (nth (min 30 (1- (length drgnx-work-trail--keys))) drgnx-work-trail--keys)))
      (when-let* ((start (and edge (drgnx-view-row-start drgnx-view edge))))
        (when (<= (point) start) (drgnx-work-trail-page-back))))))

(defun drgnx-work-trail--catch-up (buffer)
  "BUFFER's trail takes the steps the hub has after its last one."
  (with-current-buffer buffer
    (when drgnx-work-trail--loaded
      (drgnx-work-trail--request buffer (and drgnx-work-trail--steps
                                             (list :since (plist-get (car (last drgnx-work-trail--steps)) :seq)))
                                 #'drgnx-work-trail--merge)
      (drgnx-timer-soon (cons 'work-trail-conclusions (buffer-name)) 0.5 #'drgnx-work-trail--fetch-conclusions
                        :args (list buffer) :owner buffer))))

(defun drgnx-work-trail-event (event data)
  "A `drgnx-hub-event-functions' handler: an `agent-step' reaches the trails and the Timeline of its session."
  (when (equal event "agent-step")
    (let ((sid (plist-get (or (plist-get data :step) data) :session)))
      (dolist (b (drgnx-work-trail-buffers))
        (when (equal (buffer-local-value 'drgnx-work-trail--session b) sid) (drgnx-work-trail--catch-up b)))
      (drgnx-work-timeline--step-arrived sid))))

;;;; Opening a trail

(defun drgnx-work-trail--sid (agent-id)
  "The hub session of the map item AGENT-ID (a subagent's is its parent's)."
  (car (split-string (substring agent-id (length "agent:")) "/")))

(defun drgnx-work-trail-open (map-buffer session)
  "The trail of hub SESSION, made when there is none: the last screenful of its steps and its conclusions are asked for.
MAP-BUFFER is the map the trail is a view of.  Returns the buffer; it does not show itself."
  (let ((buffer (get-buffer-create (format "*drgnx work trail: %s*" session))))
    (with-current-buffer buffer
      (unless (and (derived-mode-p 'drgnx-work-trail-mode) (equal drgnx-work-trail--session session))
        (drgnx-work-trail-install buffer session nil nil)
        (setq drgnx-work-trail--loaded nil drgnx-work-trail--more t)
        (drgnx-work-trail--request
         buffer (list :limit drgnx-work-trail-first-page)
         (lambda (steps)
           (setq drgnx-work-trail--loaded t drgnx-work-trail--more (>= (length steps) drgnx-work-trail-first-page))
           (drgnx-work-trail--merge steps)))
        (drgnx-work-trail--fetch-conclusions buffer))
      (setq drgnx-work-lens--map map-buffer drgnx-work-map--lens (drgnx-work-lens-string 'timeline)))
    buffer))

;;;; Lighting the steps behind a conclusion

(defun drgnx-work-trail-conclusion-steps (n &optional named-only)
  "The ids of the steps conclusion N rests on: those its named sources matched and those since the previous conclusion,
or with NAMED-ONLY the named ones."
  (when-let* ((c (drgnx-work-trail--conclusion n)))
    (if named-only (plist-get (plist-get c :links) :named) (drgnx-work-trail--rest-on c))))

(defun drgnx-work-trail-step-conclusions (step-id)
  "The numbers of the conclusions that rest on step STEP-ID."
  (mapcar (lambda (c) (plist-get c :n))
          (seq-filter (lambda (c) (memq step-id (drgnx-work-trail--rest-on c))) drgnx-work-trail--conclusions)))

(defun drgnx-work-trail-lit-steps (n &optional named-only)
  "Light the steps conclusion N rests on (see `drgnx-work-trail-conclusion-steps'): their pills fill, their rows take the
chain's face.  Returns the ids."
  (let* ((old drgnx-work-trail--lit) (ids (drgnx-work-trail-conclusion-steps n named-only)))
    (setq drgnx-work-trail--lit ids)
    (when (drgnx-view-p drgnx-view)
      (drgnx-view-dirty drgnx-view (mapcar (lambda (id) (list :step id)) (delete-dups (append old ids)))))
    ids))

(defun drgnx-work-trail--key-here ()
  (and (drgnx-view-p drgnx-view) (drgnx-view-key-at)))

(defun drgnx-work-trail-show-steps ()
  "On a conclusion: light the steps it rests on and go to the first; again, to the next."
  (interactive)
  (let ((key (drgnx-work-trail--key-here)))
    (unless (eq (car key) :conc) (user-error "Point is not on a conclusion"))
    (let* ((ids (drgnx-work-trail-lit-steps (cadr key)))
           (here (get-text-property (point) 'drgnx-work-step))
           (next (or (cadr (memq here ids)) (car ids))))
      (if (null next)
          (message "Work: conclusion %d names no steps" (cadr key))
        (goto-char (or (drgnx-view-row-start drgnx-view (list :step next)) (point)))))))

(defun drgnx-work-trail-show-conclusions ()
  "On a step: go to the first conclusion that rests on it."
  (interactive)
  (let* ((key (drgnx-work-trail--key-here)) (ns (and (eq (car key) :step) (drgnx-work-trail-step-conclusions (cadr key)))))
    (if ns
        (goto-char (drgnx-view-row-start drgnx-view (list :conc (car ns))))
      (message "Work: no conclusion rests on this step"))))

;;;; Opening a step's source

(defun drgnx-work-trail--cwd (sid)
  "The folder of session SID, as this Emacs's mirror of it knows it, or nil."
  (when-let* ((s (and (boundp 'drgnx-agents--sessions)
                      (seq-find (lambda (x) (equal (drgnx-agent-session-remote x) sid)) drgnx-agents--sessions))))
    (drgnx-agent-session-cwd s)))

(defun drgnx-work-trail--file (sid path)
  "PATH (the step's, relative to its worktree) as a file name of this machine."
  (if (file-name-absolute-p path) path (expand-file-name path (or (drgnx-work-trail--cwd sid) default-directory))))

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
    (if mode (funcall mode) (when file-name (let ((buffer-file-name file-name)) (set-auto-mode))))
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
        (t (let ((buf (find-file-noselect (drgnx-work-trail--file sid path))))
             (with-current-buffer buf
               (when-let* ((line (plist-get d :line_start)))
                 (goto-char (point-min)) (forward-line (1- line))))
             (setq result (drgnx-work-trail--show buf beside))))))
      ('search
       (if-let* ((q (plist-get d :query)))
           (progn (message "Work: run again now: %s" q)
                  (let ((default-directory (or (drgnx-work-trail--cwd sid) default-directory)))
                    (project-find-regexp (regexp-quote q))))
         (message "Work: this search recorded no query")))
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
                                                                          (or (plist-get r :diff) "") #'diff-mode)
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
                        "")
                      (format "\nBased on %d steps\n" (length (drgnx-work-trail--rest-on c))))))
    (drgnx-work-trail--show (drgnx-work-trail--text-buffer (format "*Work conclusion %d*" (plist-get c :n)) text) beside)))

(defun drgnx-work-trail--nav (dir)
  "A key of the lens in a trail: DIR is `left' `up' (the earlier row), `right' `down' (the later), `open' or
`open-beside' (a step's source; S-RET: a read as the agent read it); the agent keys do nothing here."
  (pcase dir
    ((or 'left 'up) (forward-line -1))
    ((or 'right 'down) (forward-line 1))
    ((or 'open 'open-beside)
     (let ((key (drgnx-work-trail--key-here)))
       (pcase (car key)
         (:step (drgnx-work-trail-open-step (drgnx-work-trail--step (cadr key)) (eq dir 'open-beside) (eq dir 'open-beside)))
         (:conc (drgnx-work-trail--open-conclusion (drgnx-work-trail--conclusion (cadr key)) (eq dir 'open-beside)))
         (_ (message "Work: nothing to open here"))))))
  t)

;;;; Steering: the same keys in every Work view, on the agent selected there

(defun drgnx-work-trail--agent-sid ()
  "The hub session of the agent selected in the current Work view, or an error saying there is none."
  (or (cond ((derived-mode-p 'drgnx-work-trail-mode) drgnx-work-trail--session)
            ((derived-mode-p 'drgnx-work-timeline-mode)
             (when-let* ((lane (car (bound-and-true-p drgnx-work-timeline--sel)))) (drgnx-work-trail--sid lane)))
            ((derived-mode-p 'drgnx-work-board-mode)
             (when-let* ((state (drgnx-work-map--state drgnx-work-lens--map))
                         (card (seq-find (lambda (c) (equal (plist-get c :id) drgnx-work-board--card)) drgnx-work-board--cards))
                         (agent (drgnx-work-board-agent state card)))
               (drgnx-work-trail--sid agent)))
            ((derived-mode-p 'drgnx-work-map-mode)
             (when-let* ((sel drgnx-work-map--selection) ((memq (car sel) '(agent subagent))))
               (drgnx-work-trail--sid (cdr sel)))))
      (user-error "Select an agent first")))

(defun drgnx-work-trail--note (sid text)
  "Say in SID's trails that the user did TEXT, in the order it happened."
  (dolist (b (drgnx-work-trail-buffers))
    (with-current-buffer b
      (when (equal drgnx-work-trail--session sid)
        (let* ((n (1+ (length drgnx-work-trail--notes))) (key (list :note n)))
          (push (cons n (format "%s · %s" text (drgnx-work-trail--time (float-time)))) drgnx-work-trail--notes)
          (setq drgnx-work-trail--keys (append drgnx-work-trail--keys (list key)))
          (drgnx-view-append drgnx-view (list key)))))))

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
    (drgnx-work-trail--note sid "paused by you")
    (message "Work: Pausing after the current tool call · u resume")))

(defun drgnx-work-trail-resume ()
  "Resume the selected agent with a plain continue prompt, labelled in the trail."
  (interactive)
  (let ((sid (drgnx-work-trail--agent-sid)))
    (drgnx-hub-call "agents/send" (list :id sid :text drgnx-work-resume-text) #'ignore)
    (drgnx-work-trail--note sid "resumed by you")))

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

(defconst drgnx-work-timeline-lane-limit 200 "How many steps of each lane the Timeline asks for.")

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

(defconst drgnx-work-timeline-faces
  '((read . drgnx-work-seg-read) (search . drgnx-work-seg-read) (web . drgnx-work-seg-read) (edit . drgnx-work-seg-edit)
    (tool . drgnx-work-seg-tool) (thought . drgnx-work-seg-think) (job . drgnx-work-seg-job) (waiting . drgnx-work-seg-wait))
  "The face of each kind of step.")

(defun drgnx-work-timeline-spans (steps t0 t1 width)
  "STEPS (plists with :seq :start :end) as segments on a lane WIDTH pixels wide that shows the time from T0 to T1: a
list of (SEQ X W KIND), each at least 2 px wide.  A step that is still open runs to T1."
  (let ((k (/ (float width) (max 1.0 (- t1 t0)))))
    (mapcar (lambda (s)
              (list (plist-get s :seq) (round (* (- (plist-get s :start) t0) k))
                    (max 2 (round (* (- (or (plist-get s :end) t1) (plist-get s :start)) k)))
                    (drgnx-work-trail-kind s)))
            steps)))

(defvar-local drgnx-work-timeline--lanes nil "The agent item ids the Timeline has a lane for, in team order.")
(defvar-local drgnx-work-timeline--steps nil "Hash lane id → its steps, oldest first.")
(defvar-local drgnx-work-timeline--sel nil "The selection: (LANE . SEQ), the step in the lane (SEQ nil: none yet).")
(defvar-local drgnx-work-timeline--lit nil "The lanes of the agents the map's selection leads to or comes from.")
(defvar-local drgnx-work-timeline--lit-file nil "The path of the selected file: the steps that touch it are lit.")

(defvar drgnx-work-timeline-mode-map
  (let ((m (make-sparse-keymap))) (set-keymap-parent m drgnx-work-lens-map) m)
  "Keys of the Timeline.  The key profiles bind them (`drgnx-command-define' with the lens map).")

(define-derived-mode drgnx-work-timeline-mode special-mode "Work timeline"
  "The Work space's Timeline: a lane for each agent, its steps as segments over time."
  (setq-local truncate-lines t cursor-type nil tab-line-format '("" drgnx-work-map--lens)))

(defun drgnx-work-timeline-buffers ()
  (seq-filter (lambda (b) (eq (buffer-local-value 'major-mode b) 'drgnx-work-timeline-mode)) (buffer-list)))

(defun drgnx-work-timeline--range ()
  "The time the lanes cover: (T0 . T1), the earliest start and the latest end of any loaded step."
  (let (t0 t1)
    (maphash (lambda (_ steps)
               (dolist (s steps)
                 (setq t0 (min (or t0 (plist-get s :start)) (plist-get s :start))
                       t1 (max (or t1 0) (or (plist-get s :end) (plist-get s :start))))))
             drgnx-work-timeline--steps)
    (cons (or t0 0.0) (or t1 1.0))))

(defun drgnx-work-timeline--width ()
  (let ((win (car (get-buffer-window-list (current-buffer) nil t)))) (max 100 (- (if win (window-body-width win t) 1000) 160))))

(defun drgnx-work-timeline--lane-text (lane)
  (let* ((state (drgnx-work-map--state drgnx-work-lens--map)) (item (and state (drgnx-work-client-item state lane)))
         (range (drgnx-work-timeline--range))
         (label (drgnx-work-map--fit (or (plist-get item :label) lane) 130))
         (face (and (member lane drgnx-work-timeline--lit) 'drgnx-work-chain)))
    (concat (propertize label 'face (or face 'drgnx-work-label))
            (mapconcat
             (lambda (sp)
               (pcase-let ((`(,seq ,x ,w ,kind) sp))
                 (let ((f (cdr (assq kind drgnx-work-timeline-faces)))
                       (sel (equal drgnx-work-timeline--sel (cons lane seq))))
                   (concat (propertize " " 'display `(space :align-to (,(+ 140 x))))
                           (propertize " " 'display `(space :width (,w)) 'drgnx-work-step (cons lane seq)
                                       'face (if sel (list 'drgnx-work-selected f) f))))))
             (drgnx-work-timeline-spans (gethash lane drgnx-work-timeline--steps) (car range) (cdr range)
                                        (drgnx-work-timeline--width))
             "")
            "\n")))

(defun drgnx-work-timeline--render (key)
  (pcase (car key)
    (:axis (let ((r (drgnx-work-timeline--range)))
             (concat (propertize (format "%s%s%s" (make-string 20 ?\s) (drgnx-work-trail--time (car r))
                                         (if (> (cdr r) (car r)) (format " to %s" (drgnx-work-trail--time (cdr r))) ""))
                                 'face 'drgnx-work-label)
                     "\n")))
    (:lane (drgnx-work-timeline--lane-text (cadr key)))
    (:none "No agents yet.\n")
    (_ "\n")))

(defun drgnx-work-timeline--sync (_view)
  (drgnx-view-sync-rows drgnx-view (if drgnx-work-timeline--lanes
                                       (cons '(:axis) (mapcar (lambda (l) (list :lane l)) drgnx-work-timeline--lanes))
                                     '((:none)))
                        (lambda (key) (if (eq (car key) :lane)
                                          (vector (gethash (cadr key) drgnx-work-timeline--steps) drgnx-work-timeline--sel
                                                  (member (cadr key) drgnx-work-timeline--lit)
                                                  (drgnx-work-timeline--range))
                                        (drgnx-work-timeline--range)))))

(drgnx-view-define 'work-timeline :render #'drgnx-work-timeline--render :sync #'drgnx-work-timeline--sync
                   :slice drgnx-view-slice)

(defun drgnx-work-timeline--lane-ids (state)
  "The agents of STATE a lane is made for: the agents (not their subagents), in team order."
  (seq-filter (lambda (id) (equal (plist-get (drgnx-work-client-item state id) :kind) "agent")) (drgnx-work-nav--team state)))

(defun drgnx-work-timeline--fetch (buffer lane)
  (drgnx-hub-call "timeline/get" (list :scope "session" :id (drgnx-work-trail--sid lane) :limit drgnx-work-timeline-lane-limit)
                  (lambda (result _err)
                    (when (buffer-live-p buffer)
                      (with-current-buffer buffer
                        (puthash lane (plist-get result :steps) drgnx-work-timeline--steps)
                        (unless (car drgnx-work-timeline--sel) (setq drgnx-work-timeline--sel (cons lane nil)))
                        (when (equal (car drgnx-work-timeline--sel) lane)
                          (setq drgnx-work-timeline--sel
                                (cons lane (or (cdr drgnx-work-timeline--sel) (plist-get (car (last (plist-get result :steps))) :seq)))))
                        (drgnx-view-touch drgnx-view))))))

(defun drgnx-work-timeline--step-arrived (sid)
  "A step of session SID closed: every Timeline with its lane asks for the lane again."
  (dolist (b (drgnx-work-timeline-buffers))
    (with-current-buffer b
      (when-let* ((lane (seq-find (lambda (l) (equal (drgnx-work-trail--sid l) sid)) drgnx-work-timeline--lanes)))
        (drgnx-timer-soon (cons 'work-timeline lane) 0.3 #'drgnx-work-timeline--fetch :args (list b lane) :owner b)))))

(defun drgnx-work-timeline--lit-for (state sel)
  "The lanes and the file path the map selection SEL lights in the Timeline (design 8.2)."
  (let ((id (cdr sel)))
    (pcase (car sel)
      ('agent (list (list id) nil))
      ('subagent (list (list (or (plist-get (drgnx-work-client-item state id) :parent) id)) nil))
      ((or 'plan 'spec 'ask 'branch 'machine) (list (drgnx-work-board--agents-near state sel) nil))
      ('file (list (drgnx-work-board--agents-near state sel)
                   (mapconcat #'identity (cdr (split-string (substring id (length "file:")) "/")) "/")))
      (_ nil))))

(defun drgnx-work-timeline-open (map-buffer)
  "The Timeline of MAP-BUFFER, made when there is none: a lane for each agent, lit by the map's selection."
  (let ((buffer (get-buffer-create (format "*drgnx work timeline: %s*" (string-trim (buffer-name map-buffer) "\\*drgnx work: " "\\*")))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'drgnx-work-timeline-mode)
        (drgnx-work-timeline-mode)
        (setq drgnx-work-lens-nav #'drgnx-work-timeline--nav
              drgnx-work-timeline--steps (make-hash-table :test #'equal))
        (drgnx-view-attach 'work-timeline))
      (setq drgnx-work-lens--map map-buffer drgnx-work-map--lens (drgnx-work-lens-string 'timeline))
      (let* ((state (drgnx-work-map--state map-buffer)) (sel (buffer-local-value 'drgnx-work-map--selection map-buffer))
             (lit (and state sel (drgnx-work-timeline--lit-for state sel))))
        (setq drgnx-work-timeline--lanes (and state (drgnx-work-timeline--lane-ids state))
              drgnx-work-timeline--lit (car lit) drgnx-work-timeline--lit-file (cadr lit)
              drgnx-work-timeline--sel (cons (or (car (car lit)) (car drgnx-work-timeline--lanes)) nil)))
      (drgnx-view-touch drgnx-view)
      (dolist (lane drgnx-work-timeline--lanes) (drgnx-work-timeline--fetch buffer lane)))
    buffer))

(defun drgnx-work-timeline--nav (dir)
  "A key of the lens in the Timeline: DIR moves to the earlier or later step of the lane (`left' `right'), the lane
above or below (`up' `down', `previous-agent' `next-agent'), or opens the step (`open' `open-beside')."
  (let* ((lane (car drgnx-work-timeline--sel)) (steps (gethash lane drgnx-work-timeline--steps))
         (at (cl-position (cdr drgnx-work-timeline--sel) steps :key (lambda (s) (plist-get s :seq))))
         (lanes drgnx-work-timeline--lanes) (li (cl-position lane lanes :test #'equal)))
    (pcase dir
      ((or 'left 'right)
       (when steps
         (setq drgnx-work-timeline--sel
               (cons lane (plist-get (nth (max 0 (min (1- (length steps)) (+ (or at (1- (length steps))) (if (eq dir 'left) -1 1)))) steps)
                                     :seq)))))
      ((or 'up 'down 'next-agent 'previous-agent)
       (when (and li (cdr lanes))
         (let* ((to (nth (mod (+ li (if (memq dir '(up previous-agent)) -1 1)) (length lanes)) lanes))
                (now (and at (plist-get (nth at steps) :start)))
                (other (gethash to drgnx-work-timeline--steps))
                (near (and other (car (sort (copy-sequence other)
                                            (lambda (a b) (< (abs (- (plist-get a :start) (or now 0)))
                                                             (abs (- (plist-get b :start) (or now 0))))))))))
           (setq drgnx-work-timeline--sel (cons to (plist-get near :seq))))))
      ((or 'open 'open-beside)
       (if-let* ((step (seq-find (lambda (s) (eql (plist-get s :seq) (cdr drgnx-work-timeline--sel))) steps)))
           (drgnx-work-trail-open-step (if (plist-get step :session) step (plist-put (copy-sequence step) :session (drgnx-work-trail--sid lane)))
                                       (eq dir 'open-beside) (eq dir 'open-beside))
         (message "Work: no step is selected"))))
    (drgnx-view-touch drgnx-view)
    t))

(provide 'drgnx-work-trail)
;;; drgnx-work-trail.el ends here
