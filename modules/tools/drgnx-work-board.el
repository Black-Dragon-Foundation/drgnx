;;; drgnx-work-board.el --- The Work space's Board: tasks by the tracker's columns (library of tools/work-space) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The Board is the second view of the lens (Map · Board · Timeline): the tracker's tasks in part 1's six columns
;; (queued, running, waiting, needs you, review, done), one flat card each with a 4 px progress bar.  It is scoped to
;; the plan the map's selection stands in (or plans, for a spec or an ask), else it shows every task.  Switching views
;; keeps the selection: each view shows the nearest thing it can represent (design 8.2), by pure functions of the
;; map's cached frame and the board's cards, so a switch never waits on the hub.  The tasks themselves are asked of
;; the hub (`tasks/find', `plans/get') and asked again when the map's frame changes.
;; Loaded by tools/work-space (drgnx-work-space.el); defines no module.  See docs/develop/work-space.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-view)
(require 'drgnx-work-client)
(unless (featurep 'drgnx-work-map)
  (load (expand-file-name "drgnx-work-map" (file-name-directory (or load-file-name buffer-file-name))) nil t))
(unless (featurep 'drgnx-work-detail)
  (load (expand-file-name "drgnx-work-detail" (file-name-directory (or load-file-name buffer-file-name))) nil t))

(declare-function drgnx-hub-call "drgnx-hub-client")
(declare-function drgnx-work-timeline-open "drgnx-work-trail")
(declare-function drgnx-work-timeline-buffers "drgnx-work-trail")
(declare-function drgnx-work--open-agent "drgnx-work-map")
(declare-function drgnx-work-map-select "drgnx-work-map")
(declare-function drgnx-work-map-buffer "drgnx-work-map")
(declare-function drgnx-work-lens-string "drgnx-work-map")
(declare-function drgnx-work-map--fit "drgnx-work-map")
(declare-function drgnx-work-map--card-face "drgnx-work-map")
(declare-function drgnx-work-map--state-word "drgnx-work-map")
(declare-function drgnx-work-map--state "drgnx-work-map")
(declare-function drgnx-work-map--field "drgnx-work-map")
(declare-function drgnx-work-nav-sel "drgnx-work-detail")
(declare-function drgnx-work-nav-chain "drgnx-work-detail")
(defvar drgnx-work-lens--map)
(defvar drgnx-work-lens-nav)
(defvar drgnx-work-lens-map)
(defvar drgnx-work-map--lens)
(defvar drgnx-work-map--selection)

;;;; The columns

(defconst drgnx-work-board-columns '(queued running waiting needs-you review done)
  "The Board's columns, left to right: part 1's `norn::tracker::Column'.")

(defconst drgnx-work-board-column-names ["Queued" "Running" "Waiting" "Needs you" "Review" "Done"]
  "The columns' headings.")

(defun drgnx-work-board-column (status)
  "The column of a tracker task with STATUS, as `norn::tracker::board_column' has it: `open', `blocked' and a status it
does not know are queued, `claimed' and `running' running, `waiting' waiting, `needs-input' needs you, `in-review'
review, `done' and `dropped' done."
  (pcase status
    ((or "claimed" "running") 'running)
    ("waiting" 'waiting)
    ("needs-input" 'needs-you)
    ("in-review" 'review)
    ((or "done" "dropped") 'done)
    (_ 'queued)))

(defun drgnx-work-board-columns-of (cards)
  "CARDS (plists :id :title :status ...) by column: an alist (COLUMN . CARDS) for each of the six, in the Board's order."
  (mapcar (lambda (col)
            (cons col (seq-filter (lambda (c) (eq col (drgnx-work-board-column (plist-get c :status)))) cards)))
          drgnx-work-board-columns))

;;;; Selection, both ways (design 8.2): pure

(defun drgnx-work-board--bare (id) (if (string-prefix-p "task:" id) (substring id (length "task:")) id))

(defun drgnx-work-board-agent (state card)
  "The agent of STATE (an item id) working on CARD's task, or nil."
  (let ((want (drgnx-work-board--bare (plist-get card :id))))
    (seq-find (lambda (id)
                (let* ((it (drgnx-work-client-item state id)) (task (drgnx-work-map--field it :task)))
                  (and (equal (plist-get it :kind) "agent") task (equal (drgnx-work-board--bare task) want))))
              (sort (copy-sequence (drgnx-work-client-ids state)) #'string<))))

(defun drgnx-work-board--card-of (state cards agent-id)
  "The id of the card of CARDS whose task AGENT-ID works on, or nil."
  (plist-get (seq-find (lambda (c) (equal (drgnx-work-board-agent state c) agent-id)) cards) :id))

(defun drgnx-work-board--agents-near (state sel)
  "The agents SEL leads to or comes from in STATE: those on its chain, in the chain's order."
  (let ((chain (drgnx-work-nav-chain state sel)))
    (seq-filter (lambda (id) (equal (plist-get (drgnx-work-client-item state id) :kind) "agent"))
                (append (nth 0 chain) (nth 1 chain)))))

(defun drgnx-work-board--plans-of (state sel)
  "The plans a plan, spec or ask SEL stands for: itself, or those below it."
  (if (eq (car sel) 'plan)
      (list (cdr sel))
    (seq-filter (lambda (id) (equal (plist-get (drgnx-work-client-item state id) :kind) "plan"))
                (nth 1 (drgnx-work-nav-chain state sel)))))

(defun drgnx-work-board-for-selection (state cards sel)
  "What the Board shows for the map selection SEL (KIND . ID) of STATE, given CARDS: (:card ID) for an agent (a
subagent: its parent's), (:lit IDS) for a file, branch or machine (the tasks whose agents touch it), (:plans IDS) for a
plan, spec or ask (the Board of those plans), or nil when there is nothing to show."
  (let* ((id (cdr sel)) (item (drgnx-work-client-item state id)))
    (pcase (car sel)
      ((or 'agent 'subagent)
       (let ((card (drgnx-work-board--card-of
                    state cards (if (eq (car sel) 'subagent) (or (plist-get item :parent) id) id))))
         (and card (list :card card))))
      ((or 'plan 'spec 'ask) (list :plans (drgnx-work-board--plans-of state sel)))
      ((or 'file 'branch 'machine)
       (list :lit (delq nil (delete-dups (mapcar (lambda (a) (drgnx-work-board--card-of state cards a))
                                                 (drgnx-work-board--agents-near state sel))))))
      (_ nil))))

(defun drgnx-work-board-to-selection (state cards task-id)
  "The map selection for the card TASK-ID of CARDS: its agent's card, else its plan (which then has no agent), else nil."
  (when-let* ((card (seq-find (lambda (c) (equal (plist-get c :id) task-id)) cards)))
    (if-let* ((agent (drgnx-work-board-agent state card)))
        (drgnx-work-nav-sel state agent)
      (when-let* ((plan (plist-get card :plan)) ((drgnx-work-client-item state plan)))
        (drgnx-work-nav-sel state plan)))))

(defun drgnx-work-board-move (cols id dir)
  "The card id after moving from card ID in COLS (`drgnx-work-board-columns-of') in DIR (`left' `right' `up' `down'):
sideways to the nearest column that has cards, at the same height or the last card; up and down within the column."
  (let* ((c (seq-position cols id (lambda (col want) (seq-find (lambda (card) (equal (plist-get card :id) want)) (cdr col)))))
         (col (and c (nth c cols)))
         (i (and col (seq-position (cdr col) id (lambda (card want) (equal (plist-get card :id) want))))))
    (if (null i)
        id
      (pcase dir
        ('up (plist-get (nth (max 0 (1- i)) (cdr col)) :id))
        ('down (plist-get (nth (min (1- (length (cdr col))) (1+ i)) (cdr col)) :id))
        (_ (let* ((step (if (eq dir 'left) -1 1)) (j (+ c step)))
             (while (and (>= j 0) (< j (length cols)) (null (cdr (nth j cols)))) (setq j (+ j step)))
             (if (and (>= j 0) (< j (length cols)))
                 (let ((cards (cdr (nth j cols)))) (plist-get (nth (min i (1- (length cards))) cards) :id))
               id)))))))

;;;; The board buffer

(defvar-local drgnx-work-board--map nil "The map buffer this board is a view of.")
(defvar-local drgnx-work-board--cards nil "The tasks the board shows: plists (:id :title :status :plan :progress).")
(defvar-local drgnx-work-board--card nil "The selected card's id.")
(defvar-local drgnx-work-board--lit nil "The ids of the cards lit because an item they relate to is selected.")
(defvar-local drgnx-work-board--plans nil "The plans the board is scoped to; nil: every task.")
(defvar-local drgnx-work-board--gen 0 "The refresh in flight; an answer to an older one is dropped.")

(defface drgnx-work-bar '((t :inherit highlight)) "The done part of a card's progress bar." :group 'drgnx-work-space)
(defface drgnx-work-bar-rest '((t :inherit secondary-selection)) "The rest of a card's progress bar."
  :group 'drgnx-work-space)

(defvar drgnx-work-board-mode-map
  (let ((m (make-sparse-keymap))) (set-keymap-parent m drgnx-work-lens-map) m)
  "Keys of the board.  The key profiles bind them (`drgnx-command-define' with the lens map).")

(define-derived-mode drgnx-work-board-mode special-mode "Work board"
  "The Work space's Board: the tracker's tasks by column, scoped to the selected plan."
  (setq-local truncate-lines t cursor-type nil
              tab-line-format '("" drgnx-work-map--lens)))

(defun drgnx-work-board-buffers ()
  (seq-filter (lambda (b) (eq (buffer-local-value 'major-mode b) 'drgnx-work-board-mode)) (buffer-list)))

(defun drgnx-work-board--state ()
  (when (buffer-live-p drgnx-work-board--map) (drgnx-work-map--state drgnx-work-board--map)))

;;;; Asking the hub for the tasks

(defun drgnx-work-board--step-progress (steps)
  "(DONE TOTAL) of a plan task's STEPS, or nil when it has none."
  (when steps
    (list (cl-count-if (lambda (s) (let ((d (plist-get s :done))) (and d (not (eq d :false))))) steps) (length steps))))

(defun drgnx-work-board--set-cards (buffer gen cards)
  "Show CARDS in BUFFER when GEN is still its latest refresh."
  (when (and (buffer-live-p buffer) (= gen (buffer-local-value 'drgnx-work-board--gen buffer)))
    (with-current-buffer buffer
      (setq drgnx-work-board--cards cards)
      (when (drgnx-view-p drgnx-view) (drgnx-view-touch drgnx-view)))))

(defun drgnx-work-board--fetch-plans (buffer gen plans acc)
  "Ask `plans/get' of each of PLANS in turn, ACC holding the cards so far."
  (if (null plans)
      (drgnx-work-board--set-cards buffer gen acc)
    (drgnx-hub-call "plans/get" (list :plan (car plans))
                    (lambda (result _err)
                      (drgnx-work-board--fetch-plans
                       buffer gen (cdr plans)
                       (append acc (mapcar (lambda (task)
                                             (list :id (plist-get task :id) :title (plist-get task :title)
                                                   :status (plist-get task :status) :plan (car plans)
                                                   :progress (drgnx-work-board--step-progress (plist-get task :steps))))
                                           (plist-get result :tasks))))))))

(defun drgnx-work-board--fetch-all (buffer gen cursor acc pages)
  "Ask `tasks/find' for a page of every task (CURSOR: the page after the one before), up to four pages."
  (drgnx-hub-call "tasks/find" (list :cursor cursor)
                  (lambda (result _err)
                    (let ((acc (append acc (mapcar (lambda (task)
                                                     (list :id (plist-get task :id) :title (plist-get task :title)
                                                           :status (plist-get task :status)))
                                                   (plist-get result :tasks))))
                          (next (plist-get result :cursor)))
                      (if (and next (< (1+ pages) 4))
                          (drgnx-work-board--fetch-all buffer gen next acc (1+ pages))
                        (drgnx-work-board--set-cards buffer gen acc))))))

(defun drgnx-work-board-refresh (&optional buffer)
  "Ask the hub for BUFFER's tasks (default: the current board) again; the board draws them when they come."
  (let ((buffer (or buffer (current-buffer))))
    (with-current-buffer buffer
      (let ((gen (cl-incf drgnx-work-board--gen)) (plans drgnx-work-board--plans))
        (condition-case nil
            (if plans
                (drgnx-work-board--fetch-plans buffer gen plans nil)
              (drgnx-work-board--fetch-all buffer gen nil nil 0))
          (error nil))))))

;;;; Rows

(defun drgnx-work-board--column-px ()
  "The width of one column in pixels: a sixth of the window's, at least 120."
  (let ((win (car (get-buffer-window-list (current-buffer) nil t))))
    (max 120 (/ (- (if win (window-body-width win t) 1200) 12) 6))))

(defun drgnx-work-board--class (id)
  (cond ((equal id drgnx-work-board--card) 'drgnx-work-selected)
        ((member id drgnx-work-board--lit) 'drgnx-work-chain)))

(defun drgnx-work-board--lines (card)
  "The text of CARD's first two lines: its title, and its state with the agent working on it."
  (let* ((state (drgnx-work-board--state)) (agent (and state (drgnx-work-board-agent state card)))
         (item (and agent (drgnx-work-client-item state agent))))
    (list (concat "● " (or (plist-get card :title) (plist-get card :id)))
          (mapconcat #'identity
                     (delq nil (list (drgnx-work-map--state-word (plist-get card :status))
                                     (and item (plist-get item :label))
                                     (and (plist-get card :progress)
                                          (format "%d/%d" (car (plist-get card :progress)) (cadr (plist-get card :progress))))))
                     " · "))))

(defun drgnx-work-board--segment (card col line)
  "Line LINE (0 to 2) of CARD in column COL: its title, its state, then its progress bar."
  (let* ((w (drgnx-work-board--column-px)) (left (* col w)) (right (+ left w -8))
         (face (drgnx-work-map--card-face 3 line)) (class (drgnx-work-board--class (plist-get card :id)))
         (closing (propertize " " 'display `(space :align-to (,right)) 'face (if class (list class face) face))))
    (if (< line 2)
        (let ((text (copy-sequence (drgnx-work-map--fit (nth line (drgnx-work-board--lines card)) (- right left 10)))))
          (add-face-text-property 0 (length text) face t text)
          (when class (add-face-text-property 0 (length text) class nil text))
          (add-text-properties 0 (length text) (list 'drgnx-work-id (plist-get card :id)) text)
          (concat (propertize " " 'display `(space :align-to (,left))) text closing))
      (let* ((p (plist-get card :progress)) (span (- right left 8))
             (fill (if (and p (> (cadr p) 0)) (round (* span (/ (float (car p)) (cadr p)))) 0)))
        (concat (propertize " " 'display `(space :align-to (,(+ left 4))))
                (propertize " " 'display `(space :width (,fill) :height (4)) 'face 'drgnx-work-bar)
                (propertize " " 'display `(space :width (,(- span fill)) :height (4)) 'face 'drgnx-work-bar-rest)
                closing)))))

(defun drgnx-work-board--keys ()
  (let ((n (apply #'max 0 (mapcar (lambda (c) (length (cdr c))) (drgnx-work-board-columns-of drgnx-work-board--cards)))))
    (cons '(:head) (if (zerop n) '((:none)) (cl-loop for i below n collect (list :cards i))))))

(defun drgnx-work-board--render (key)
  (let ((cols (drgnx-work-board-columns-of drgnx-work-board--cards)))
    (pcase (car key)
      (:none "No tasks.\n")
      (:head (concat (mapconcat (lambda (col)
                                  (let ((i (seq-position drgnx-work-board-columns (car col))))
                                    (concat (propertize " " 'display `(space :align-to (,(* i (drgnx-work-board--column-px)))))
                                            (propertize (format "%s · %d" (aref drgnx-work-board-column-names i) (length (cdr col)))
                                                        'face 'drgnx-work-label))))
                                cols "")
                     "\n"))
      (:cards (let ((i (cadr key)))
                (apply #'concat
                       (cl-loop for line below 3
                                collect (concat (mapconcat (lambda (col)
                                                             (if-let* ((card (nth i (cdr col))))
                                                                 (drgnx-work-board--segment
                                                                  card (seq-position drgnx-work-board-columns (car col)) line)
                                                               ""))
                                                           cols "")
                                                "\n"))))))))

(defun drgnx-work-board--sig (key)
  (let ((cols (drgnx-work-board-columns-of drgnx-work-board--cards)))
    (if (eq (car key) :cards)
        (vconcat (mapcar (lambda (col) (let ((c (nth (cadr key) (cdr col))))
                                         (cons c (and c (drgnx-work-board--class (plist-get c :id))))))
                         cols))
      (vconcat (mapcar (lambda (col) (length (cdr col))) cols)))))

(defun drgnx-work-board--sync (_view)
  (drgnx-view-sync-rows drgnx-view (drgnx-work-board--keys) #'drgnx-work-board--sig))

(drgnx-view-define 'work-board :render #'drgnx-work-board--render :sync #'drgnx-work-board--sync
                   :slice drgnx-view-slice)

;;;; Moving and opening

(defun drgnx-work-board--select (id)
  (setq drgnx-work-board--card id drgnx-work-board--lit nil)
  (when (drgnx-view-p drgnx-view) (drgnx-view-dirty drgnx-view t))
  (when-let* ((pos (text-property-any (point-min) (point-max) 'drgnx-work-id id)))
    (goto-char pos)
    (dolist (w (get-buffer-window-list (current-buffer) nil t)) (set-window-point w pos))))

(defun drgnx-work-board--team-cards ()
  "The cards that have an agent, in the order of the columns and, in a column, as they come."
  (let ((state (drgnx-work-board--state)))
    (and state (seq-filter (lambda (c) (drgnx-work-board-agent state c))
                           (apply #'append (mapcar #'cdr (drgnx-work-board-columns-of drgnx-work-board--cards)))))))

(defun drgnx-work-board--nav (dir)
  "A key of the lens in the board: DIR is `left' `right' `up' `down' `next-agent' `previous-agent' `open' or
`open-beside'."
  (let ((cols (drgnx-work-board-columns-of drgnx-work-board--cards)))
    (pcase dir
      ((or 'left 'right 'up 'down)
       (let ((first (plist-get (car (seq-mapcat #'cdr cols)) :id)))
         (when-let* ((id (if drgnx-work-board--card (drgnx-work-board-move cols drgnx-work-board--card dir) first)))
           (drgnx-work-board--select id))))
      ((or 'next-agent 'previous-agent)
       (let* ((ids (mapcar (lambda (c) (plist-get c :id)) (drgnx-work-board--team-cards)))
              (at (cl-position drgnx-work-board--card ids :test #'equal)) (n (length ids)))
         (when ids
           (drgnx-work-board--select
            (nth (cond ((null at) (if (eq dir 'next-agent) 0 (1- n))) ((eq dir 'next-agent) (mod (1+ at) n)) (t (mod (1- at) n)))
                 ids)))))
      ((or 'open 'open-beside)
       (let* ((state (drgnx-work-board--state)) (card (seq-find (lambda (c) (equal (plist-get c :id) drgnx-work-board--card))
                                                                drgnx-work-board--cards))
              (agent (and state card (drgnx-work-board-agent state card))))
         (if agent
             (drgnx-work--open-agent (substring agent (length "agent:")))
           (message "Work: no agent works on this task")))))
    t))

;;;; Opening a board

(defun drgnx-work-board--name (map-buffer)
  (format "*drgnx work board: %s*" (string-trim (buffer-name map-buffer) "\\*drgnx work: " "\\*")))

(defun drgnx-work-board-open (map-buffer)
  "The board of MAP-BUFFER, made when there is none: its card, lit cards and plans follow the map's selection (design 8.2).
Returns the buffer; it asks the hub for the tasks and does not show itself."
  (let ((buffer (get-buffer-create (drgnx-work-board--name map-buffer))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'drgnx-work-board-mode)
        (drgnx-work-board-mode)
        (setq drgnx-work-lens-nav #'drgnx-work-board--nav)
        (drgnx-view-attach 'work-board))
      (setq drgnx-work-board--map map-buffer drgnx-work-lens--map map-buffer)
      (let* ((state (drgnx-work-map--state map-buffer))
             (sel (buffer-local-value 'drgnx-work-map--selection map-buffer))
             (what (and state sel (drgnx-work-board-for-selection state drgnx-work-board--cards sel))))
        (setq drgnx-work-board--plans (plist-get what :plans)
              drgnx-work-board--card (plist-get what :card)
              drgnx-work-board--lit (plist-get what :lit)))
      (setq drgnx-work-map--lens (drgnx-work-lens-string 'board))
      (drgnx-view-touch drgnx-view)
      (drgnx-work-board-refresh buffer))
    buffer))

(defun drgnx-work-board--changed (view-id _marks)
  "`drgnx-work-client-change-functions': the map of VIEW-ID changed; its board asks for its tasks again, once a moment."
  (when-let* ((map (drgnx-work-map-buffer view-id)))
    (dolist (b (drgnx-work-board-buffers))
      (when (eq (buffer-local-value 'drgnx-work-board--map b) map)
        (drgnx-timer-soon (cons 'work-board view-id) 0.3 #'drgnx-work-board-refresh :args (list b) :owner b)))))

;;;; Switching between the lens's views, keeping the selection

(defun drgnx-work-lens-map-buffer ()
  "The map buffer of the current Work view."
  (cond ((derived-mode-p 'drgnx-work-map-mode) (current-buffer))
        ((buffer-live-p drgnx-work-lens--map) drgnx-work-lens--map)
        (t (user-error "This view has no map"))))

(defun drgnx-work-lens-switch (lens)
  "Show LENS (`map', `board' or `timeline') in this window, with the selection of the view that was shown.  A card
selected on the board becomes the map's selection (its agent, else its plan)."
  (let ((map (drgnx-work-lens-map-buffer)))
    (when (derived-mode-p 'drgnx-work-board-mode)
      (when-let* ((state (drgnx-work-board--state)) (id drgnx-work-board--card)
                  (sel (drgnx-work-board-to-selection state drgnx-work-board--cards id)))
        (with-current-buffer map (drgnx-work-map-select sel))))
    (pop-to-buffer-same-window
     (pcase lens
       ('map map)
       ('board (drgnx-work-board-open map))
       ('timeline (if (fboundp 'drgnx-work-timeline-open) (drgnx-work-timeline-open map)
                    (user-error "The Timeline is not loaded")))))))

(defun drgnx-work-lens-show-map () "Show the map, keeping the selection." (interactive) (drgnx-work-lens-switch 'map))
(defun drgnx-work-lens-show-board () "Show the Board, keeping the selection." (interactive) (drgnx-work-lens-switch 'board))
(defun drgnx-work-lens-show-timeline () "Show the Timeline, keeping the selection." (interactive) (drgnx-work-lens-switch 'timeline))

(provide 'drgnx-work-board)
;;; drgnx-work-board.el ends here
