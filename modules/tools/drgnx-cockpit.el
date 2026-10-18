;;; drgnx-cockpit.el --- Module tools/cockpit: the Work cockpit — the Work graph's pane, its redraws, its commands -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The Work cockpit's home screen is the Work graph (pane kind `work-graph', home `left', view `work'): specs, plans,
;; tasks, agents, jobs and reviews from the cockpit's model (core/drgnx-cockpit-model.el), drawn
;; (drgnx-cockpit-graph.el) in a graphical window wide enough for it, else as an outline.  It follows the live store:
;; hub events, agent sessions and work-tracker scans schedule a redraw (`drgnx-cockpit-schedule'), at most one per
;; `drgnx-cockpit-redraw-delay', only while the graph is visible, and it draws only when what it would show changed.
;; A redraw reads the store and this Emacs's cached sessions; it never prompts and never touches a remote file.
;; Click or RET on a node opens its tab; f filters by milestone, agent and state.  See docs/guide/cockpit.md.

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

(declare-function drgnx-cockpit-graph-layout "drgnx-cockpit-graph")
(declare-function drgnx-cockpit-graph-outline "drgnx-cockpit-graph")
(declare-function drgnx-cockpit-graph-summary "drgnx-cockpit-graph")
(declare-function drgnx-cockpit-graph-bands "drgnx-cockpit-graph")
(declare-function drgnx-cockpit-graph--ascii-p "drgnx-cockpit-graph")
(declare-function drgnx-cockpit-graph--style "drgnx-cockpit-graph")
(declare-function drgnx-work-ui--metrics "drgnx-work-ui")
(declare-function drgnx-work-ui--colour "drgnx-work-ui")
(declare-function drgnx-agents-ui-transcript "drgnx-agents-ui")
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
(defvar drgnx-agents--sessions)
(defvar drgnx-cockpit-graph-svg)
(defvar drgnx-cockpit-graph--generation)

(defcustom drgnx-cockpit-redraw-delay 0.5
  "Seconds between the first change the Work graph hears of and its redraw: however many events come meanwhile,
it redraws once."
  :type 'number :group 'drgnx-cockpit)

(defcustom drgnx-cockpit-open-functions
  '((spec . drgnx-cockpit--open-file) (plan . drgnx-cockpit--open-file) (todo . drgnx-cockpit--open-file)
    (task . drgnx-cockpit--open-task) (agent . drgnx-cockpit--open-agent) (job . drgnx-cockpit--open-job)
    (review . drgnx-cockpit--open-job))
  "What opening a node of the Work graph does, by its kind: KIND → a function of the node.  A kind not listed opens
its file, when it has one."
  :type '(alist :key-type symbol :value-type function) :group 'drgnx-cockpit)

(defconst drgnx-cockpit-graph-buffer-name "*Work Graph*")

(defvar drgnx-cockpit-graph-filter nil
  "What the Work graph shows: (:milestone TEXT :agent ID :states (STATE…)), each optional (`drgnx-cockpit-filter'); nil
shows everything.  Set by `drgnx-cockpit-graph-filter'.")

(defvar drgnx-cockpit--timer nil "The redraw on its way: one at a time.")
(defvar drgnx-cockpit--draws 0 "How many times the Work graph was drawn (tests and the perf lab read it).")
(defvar-local drgnx-cockpit--signature nil "What the graph shows now: a redraw that would show the same draws nothing.")
(defvar-local drgnx-cockpit--stale nil "Something changed while the graph was hidden: it redraws when it shows.")
(defvar-local drgnx-cockpit--model nil "The model the graph shows (filtered).")
(defvar-local drgnx-cockpit--layout nil "The layout of `drgnx-cockpit--model' (only measured on graphical frames).")
(defvar-local drgnx-cockpit--lines nil "The lines the outline shows, as they are in the buffer (patched in place).")
(defvar-local drgnx-cockpit--spots nil "While the drawing shows: alist hot-spot area → node id.")
(defvar-local drgnx-cockpit--svg nil "Non-nil while the drawing shows (nil: the outline).")

;;;; The buffer and its mode

(defvar drgnx-cockpit-graph-mode-map
  (let ((m (make-sparse-keymap))) (set-keymap-parent m special-mode-map) m)
  "The Work graph's keys (they come from the key profiles: f, RET, o, g).")

(defvar drgnx-cockpit--line-map
  (let ((m (make-sparse-keymap))) (define-key m [mouse-1] #'drgnx-cockpit-graph-click) m)
  "A click on a node's line of the outline opens it.")

(define-derived-mode drgnx-cockpit-graph-mode special-mode "Work Graph"
  "The Work graph: specs, plans, tasks, agents, jobs and reviews (docs/guide/cockpit.md)."
  (setq truncate-lines t buffer-read-only t)
  (buffer-disable-undo)
  (setq-local revert-buffer-function #'drgnx-cockpit--revert)
  (add-hook 'window-size-change-functions #'drgnx-cockpit--resized nil t)
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
  "Follow the store while the graph's buffer lives: hub events, agent sessions, work-tracker scans (idempotent)."
  (add-hook 'drgnx-hub-event-functions #'drgnx-cockpit--hub-event)
  (add-hook 'drgnx-agents-changed-functions #'drgnx-cockpit--agent-changed)
  (add-hook 'drgnx-work-ui-scanned-hook #'drgnx-cockpit-schedule))

(defun drgnx-cockpit--unwatch ()
  "The graph's buffer is killed: stop following the store (its `kill-buffer-hook')."
  (remove-hook 'drgnx-hub-event-functions #'drgnx-cockpit--hub-event)
  (remove-hook 'drgnx-agents-changed-functions #'drgnx-cockpit--agent-changed)
  (remove-hook 'drgnx-work-ui-scanned-hook #'drgnx-cockpit-schedule)
  (when (timerp drgnx-cockpit--timer) (cancel-timer drgnx-cockpit--timer))
  (setq drgnx-cockpit--timer nil))

(defconst drgnx-cockpit--quiet-events '("agent-entries" "request" "budget")
  "Hub events that never change the graph: a transcript's chunks, the gateway's requests and spend.")

(defun drgnx-cockpit--hub-event (event _data)
  "`drgnx-hub-event-functions': a job, a card, an agent or a lease changed — the graph redraws soon."
  (unless (member event drgnx-cockpit--quiet-events) (drgnx-cockpit-schedule)))

(defun drgnx-cockpit--agent-changed (_session)
  "`drgnx-agents-changed-functions': a session's state may show in the graph."
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

(defun drgnx-cockpit--tick ()
  "The scheduled redraw (a timer): an error is a message, never a prompt."
  (setq drgnx-cockpit--timer nil)
  (condition-case err (drgnx-cockpit-graph-redraw)
    (error (message "drgnx cockpit: %s" (error-message-string err)))))

(defun drgnx-cockpit--on-show (_window)
  "The graph's pane shows: draw what changed while it was hidden (soon, never while showing it)."
  (drgnx-cockpit-schedule 0))

(defun drgnx-cockpit--resized (_window)
  "A window showing the graph changed size: the drawing may now fit, or no longer."
  (drgnx-cockpit-schedule))

(defun drgnx-cockpit--revert (&rest _) (drgnx-cockpit-graph-redraw t))

;;;; Drawing

(defun drgnx-cockpit-sessions ()
  "The agent sessions this Emacs knows (its own and the hub's mirrors), as the model takes them: cached state only.
An exited session is left out (it no longer works on anything)."
  (when (boundp 'drgnx-agents--sessions)
    (delq nil (mapcar (lambda (s)
                        (let ((id (or (drgnx-agent-session-remote s) (drgnx-agent-session-id s))))
                          (unless (or (null id) (eq (drgnx-agent-session-status s) 'exited))
                            (list :id id :name (drgnx-agent-session-name s) :cwd (drgnx-agent-session-cwd s)
                                  :task (drgnx-agent-session-task s) :job (drgnx-agent-session-job s)
                                  :status (drgnx-agent-session-status s) :permissions (drgnx-agent-session-permissions s)))))
                      drgnx-agents--sessions))))

(defun drgnx-cockpit--filtering-p ()
  (let ((f drgnx-cockpit-graph-filter))
    (or (plist-get f :milestone) (plist-get f :agent) (plist-get f :states))))

(defun drgnx-cockpit--current-model ()
  "The model the graph shows: the store's, filtered by `drgnx-cockpit-graph-filter'."
  (let ((m (drgnx-cockpit-model :sessions (drgnx-cockpit-sessions))))
    (if (drgnx-cockpit--filtering-p) (drgnx-cockpit-filter m drgnx-cockpit-graph-filter) m)))

(defun drgnx-cockpit--drawable-p (windows)
  "Whether the graph may be drawn (SVG) in WINDOWS: the option is on, this Emacs draws SVG, every window is graphical."
  (and drgnx-cockpit-graph-svg windows (image-type-available-p 'svg)
       (seq-every-p (lambda (w) (display-images-p (window-frame w))) windows)))

(defun drgnx-cockpit--filter-line ()
  "The line saying what the filter keeps, or nil."
  (when (drgnx-cockpit--filtering-p)
    (let ((f drgnx-cockpit-graph-filter))
      (propertize (concat "Filter: "
                          (string-join (delq nil (list (plist-get f :milestone)
                                                       (and (plist-get f :agent) (format "agent %s" (plist-get f :agent)))
                                                       (and (plist-get f :states) (string-join (plist-get f :states) ", "))))
                                       " · ")
                          "  (f changes it)")
                  'face 'drgnx-cockpit-edge))))

(defun drgnx-cockpit-graph-redraw (&optional force)
  "Draw the Work graph again when what it shows changed (FORCE: anyway); non-nil when it drew.
The drawing in graphical windows wide enough for it (`drgnx-cockpit-graph-svg'), else the outline.  Reads the store
and the cached sessions only: never prompts."
  (when-let* ((b (get-buffer drgnx-cockpit-graph-buffer-name)))
    (with-current-buffer b
      (let* ((model (drgnx-cockpit--current-model))
             (windows (get-buffer-window-list b nil t))
             (layout (and (drgnx-cockpit--drawable-p windows)
                          (if (and drgnx-cockpit--layout (equal model drgnx-cockpit--model)) drgnx-cockpit--layout
                            (drgnx-cockpit-graph-layout model (drgnx-work-ui--metrics)))))
             (svg (and layout (>= (apply #'max (mapcar (lambda (w) (window-body-width w t)) windows)) (plist-get layout :w))))
             (sig (list model drgnx-cockpit-graph-filter (and svg (plist-get layout :metrics))
                        (drgnx-cockpit-graph--ascii-p) drgnx-cockpit-graph--generation)))
        (setq drgnx-cockpit--stale nil drgnx-cockpit--layout layout)
        (when (or force (not (equal sig drgnx-cockpit--signature)))
          (setq drgnx-cockpit--signature sig drgnx-cockpit--model model)
          (if svg (drgnx-cockpit--draw-svg model layout windows) (drgnx-cockpit--draw-outline model windows))
          (cl-incf drgnx-cockpit--draws)
          t)))))

(defun drgnx-cockpit--line-of (id)
  "The line number of node ID's line in the outline, or nil."
  (save-excursion
    (goto-char (point-min))
    (when-let* ((m (text-property-search-forward 'drgnx-cockpit-node id t)))
      (line-number-at-pos (prop-match-beginning m)))))

(defun drgnx-cockpit--draw-outline (model windows)
  "Show MODEL as the outline, changing only the lines that changed: a window keeps its point (on its node when that
line changed) and its start."
  (let* ((new (mapcar (lambda (l) (if (get-text-property 0 'drgnx-cockpit-node l)
                                      (propertize l 'keymap drgnx-cockpit--line-map 'mouse-face 'highlight)
                                    l))
                      (delq nil (cons (drgnx-cockpit--filter-line) (drgnx-cockpit-graph-outline model)))))
         (old (if drgnx-cockpit--svg nil drgnx-cockpit--lines))
         (inhibit-read-only t)
         (pre 0) (o old) (n new))
    (when drgnx-cockpit--svg (erase-buffer) (kill-local-variable 'cursor-type))
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

(defun drgnx-cockpit--draw-svg (model layout windows)
  "Show LAYOUT (of MODEL) as the drawing: a summary line, then the image in slices (it scrolls like text), every box a
hot spot.  Windows keep their start and point where the buffer still reaches."
  (let* ((inhibit-read-only t) (map (make-sparse-keymap)) (spots nil) (i 0)
         (lh (cdr (plist-get layout :metrics)))
         (keep (mapcar (lambda (w) (list w (window-start w) (window-point w))) windows)))
    (dolist (box (plist-get layout :boxes))
      (let ((area (intern (format "drgnx-cockpit-node-%d" (cl-incf i)))))
        (push (cons area (plist-get box :id)) spots)
        ;; a click comes as mouse-1 with the hot spot in its position, or prefixed by it: both open
        (define-key map (vector area 'mouse-1) #'drgnx-cockpit-graph-click)
        (define-key map (vector area 'double-mouse-1) #'ignore)))
    (define-key map [mouse-1] #'drgnx-cockpit-graph-click)
    (define-key map [down-mouse-1] #'ignore)            ; a press neither moves point nor selects
    (define-key map [double-mouse-1] #'ignore)
    (setq spots (nreverse spots))
    (erase-buffer)
    (dolist (l (delq nil (list (drgnx-cockpit--filter-line) (drgnx-cockpit-graph-summary model)))) (insert l "\n"))
    (let ((start (point)) (byid (make-hash-table :test #'equal)))
      (dolist (b (plist-get layout :boxes)) (puthash (plist-get b :id) b byid))
      (pcase-dolist (`(,y0 ,hb ,svg) (drgnx-cockpit-graph-bands layout))
        (let ((img (create-image svg 'svg t :scale 1.0 :foreground (drgnx-work-ui--colour 'default :foreground))))
          ;; each band's hot spots in its own pixels: the boxes it shows, cut to it (set after `create-image')
          (setf (image-property img :map)
                (delq nil (mapcar (lambda (s)
                                    (let* ((box (gethash (cdr s) byid)) (n (plist-get box :node))
                                           (top (max y0 (plist-get box :y)))
                                           (bot (min (+ y0 hb) (+ (plist-get box :y) (plist-get box :h)))))
                                      (when (< top bot)
                                        (list (cons 'rect (cons (cons (plist-get box :x) (- top y0))
                                                                (cons (+ (plist-get box :x) (plist-get box :w)) (- bot y0))))
                                              (car s)
                                              (list 'help-echo (format "%s\n%s%s" (plist-get n :title) (or (plist-get n :state) "")
                                                                       (if (plist-get n :path) (concat "\n" (plist-get n :path)) ""))
                                                    'pointer 'hand)))))
                                  spots)))
          ;; in slices of rows: it scrolls like text (it is drawn only where it fits across, so one column)
          (insert-sliced-image img nil nil (max 1 (/ hb (* 2 lh))) 1)))
      (put-text-property start (point-max) 'keymap map))
    (drgnx-wb-with-owned-windows windows
      (pcase-dolist (`(,w ,s ,p) keep)
        (set-window-start w (min s (point-max)) t)
        (set-window-point w (min p (point-max)))))
    (set-buffer-modified-p nil)
    (setq-local cursor-type nil)                        ; no cursor box drawn round a slice of the image
    (setq drgnx-cockpit--spots spots drgnx-cockpit--svg t drgnx-cockpit--lines nil)))

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
  "Open task NODE: its plan at its heading (its edits, once the cockpit shows them), else its job.  A plan task no
job runs is read-only here: it opens in its plan, and Start Job from Plan is named, never run."
  (cond ((plist-get node :path)
         (prog1 (drgnx-cockpit--open-file node)
           (when (plist-get node :readonly)
             (message "%s is read-only here: no job runs it.  Start Job from Plan… (job-start) starts one"
                      (or (plist-get node :title) (plist-get node :id))))))
        (t (drgnx-cockpit--open-job node))))

(defun drgnx-cockpit--open-agent (node)
  "Open agent NODE: its transcript when its session is in this Emacs, else say what it is doing."
  (let ((s (and (boundp 'drgnx-agents--sessions)
                (seq-find (lambda (s) (equal (or (drgnx-agent-session-remote s) (drgnx-agent-session-id s)) (plist-get node :agent)))
                          drgnx-agents--sessions))))
    (if (and s (fboundp 'drgnx-agents-ui-transcript)) (drgnx-agents-ui-transcript s)
      (message "%s: %s, %s — no transcript in this Emacs" (plist-get node :title) (or (plist-get node :reporting) "agent")
               (or (plist-get node :state) "")))))

(defun drgnx-cockpit--open-job (node)
  "Open NODE's job: its window (tasks, what needs you, decisions)."
  (if (and (plist-get node :job) (fboundp 'drgnx-job-ui-show)) (drgnx-job-ui-show (plist-get node :job))
    (message "%s has no job" (or (plist-get node :title) (plist-get node :id)))))

(defun drgnx-cockpit-graph-open-node (id)
  "Open the tab of node ID of the graph (`drgnx-cockpit-open-functions')."
  (let ((node (or (drgnx-cockpit--shown-node id) (user-error "The Work graph no longer shows %s" id))))
    (funcall (or (alist-get (plist-get node :kind) drgnx-cockpit-open-functions) #'drgnx-cockpit--open-file) node)))

(defun drgnx-cockpit--node-here (&optional prompt pred)
  "The id of the node on this line of the outline; else (the drawing, a line of no node) one read with PROMPT among
the nodes PRED accepts."
  (or (and (derived-mode-p 'drgnx-cockpit-graph-mode) (get-text-property (line-beginning-position) 'drgnx-cockpit-node))
      (let* ((nodes (seq-filter (or pred #'identity) (plist-get (buffer-local-value 'drgnx-cockpit--model (drgnx-cockpit-graph-buffer)) :nodes)))
             (choices (mapcar (lambda (n) (cons (format "%s: %s%s" (capitalize (symbol-name (plist-get n :kind))) (plist-get n :title)
                                                        (if (plist-get n :state) (format " (%s)" (plist-get n :state)) ""))
                                                (plist-get n :id)))
                              nodes)))
        (unless choices (user-error "Nothing to open"))
        (cdr (assoc (completing-read (or prompt "Open: ") choices nil t) choices)))))

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
  "Open the tab of node ID (the node on this line): a spec or plan at its line, a task in its plan (read-only when
no job runs it), an agent's transcript, a job's window."
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
   (let* ((m (drgnx-cockpit-model :sessions (drgnx-cockpit-sessions))) (f drgnx-cockpit-graph-filter)
          (agents (mapcar (lambda (a) (cons (format "%s (%s)" (or (plist-get a :name) (plist-get a :id)) (plist-get a :id)) (plist-get a :id)))
                          (plist-get m :agents))))
     (list (read-string "Milestone — a text in a title or path (empty: all): " (plist-get f :milestone))
           (cdr (assoc (completing-read "Agent (empty: all): " agents nil t) agents))
           (completing-read-multiple "States (comma between; empty: all): "
                                     (delete-dups (delq nil (mapcar (lambda (n) (plist-get n :state)) (plist-get m :nodes))))))))
  (setq drgnx-cockpit-graph-filter
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
                   (cockpit-refresh "Draw Graph Again" drgnx-cockpit-graph-refresh "Read the store again and draw the Work graph")))
    (drgnx-command-define id :category "Work" :title title :command fn :doc doc :map 'drgnx-cockpit-graph-mode-map)))

(drgnx-module-define 'tools/cockpit
                     :doc "The Work cockpit: the Work graph — specs, plans, tasks, agents, jobs and reviews; drawn in windows, an outline in terminals."
                     :stage 'startup :requires '(tools/work tools/jobs)
                     :setup #'drgnx-cockpit--setup)

(provide 'drgnx-cockpit)
;;; drgnx-cockpit.el ends here
