;;; drgnx-work-board.el --- The Work space's Board: tasks by the tracker's columns (library of tools/work-space) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The Board is the second view of the lens (Map · Board · Timeline): the tracker's tasks in part 1's six columns
;; (queued, running, waiting, needs you, review, done), one flat card each with a 4 px progress bar.  It is scoped to
;; the plan the map's selection stands in (or plans, for a spec or an ask), else it shows every task.  The hub builds
;; it (`work/board/subscribe'): its rows, and a model of its own (Sjá) whose selection is the Board's alone.  It is
;; drawn only from those rows: beside a map without Sjá it says so.
;; Loaded by tools/work-space (drgnx-work-space.el); defines no module.  See docs/develop/work-space.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-view)
(require 'drgnx-view-nav)
(require 'drgnx-work-client)
(unless (featurep 'drgnx-work-map)
  (load (expand-file-name "drgnx-work-map" (file-name-directory (or load-file-name buffer-file-name))) nil t))
(unless (featurep 'drgnx-work-detail)
  (load (expand-file-name "drgnx-work-detail" (file-name-directory (or load-file-name buffer-file-name))) nil t))

(declare-function drgnx-view-env-register "drgnx-view-env")
(declare-function nidhogg-view-set "nidhogg-views" (h what value))
(declare-function drgnx-work-timeline-open "drgnx-work-trail")
(declare-function drgnx-work-timeline-buffers "drgnx-work-trail")
(declare-function drgnx-work--open-agent "drgnx-work-map")
(declare-function drgnx-work-map-select "drgnx-work-map")
(declare-function drgnx-work-lens-string "drgnx-work-map")
(declare-function drgnx-work-map--sja "drgnx-work-map")
(declare-function drgnx-work-map--class-index "drgnx-work-map" (h name))
(declare-function nidhogg-view-get "nidhogg-views" (h what &optional arg arg2))
(defvar drgnx-work-lens--map)
(defvar drgnx-work-lens-nav)
(defvar drgnx-work-lens-map)
(defvar drgnx-work-map--lens)
(defvar drgnx-chrome-own-tab-line)
(declare-function drgnx-work-lens-name "drgnx-work-map")
(defvar drgnx-work-map--selection)
(defvar drgnx-work-map-no-sja)

;;;; What the map's selection scopes the Board to (design 8.2)

(defun drgnx-work-board-plans-for (map-buffer)
  "The plans the Board is scoped to for MAP-BUFFER's selection, from the map's model (Sjá): a plan itself, or the plans
on a spec's or an ask's chain (the model's list `plans', class `chain'); nil for anything else, or without Sjá (every
task)."
  (let ((sel (buffer-local-value 'drgnx-work-map--selection map-buffer))
        (h (with-current-buffer map-buffer (drgnx-work-map--sja))))
    (when h
      (pcase (car sel)
        ('plan (list (cdr sel)))
        ((or 'spec 'ask)
         (let ((chain (drgnx-work-map--class-index h "chain")))
           (seq-filter (lambda (id) (and chain (eql chain (nidhogg-view-get h 'class id))))
                       (nidhogg-view-get h 'list "plans"))))))))

;;;; The board buffer

(defvar-local drgnx-work-board--map nil "The map buffer this board is a view of.")
(defvar-local drgnx-work-board--plans nil "The plans the board is scoped to; nil: every task.")

(defface drgnx-work-bar '((t :inherit drgnx-selected)) "The done part of a card's progress bar." :group 'drgnx-work-space)
(defface drgnx-work-bar-rest '((t :inherit drgnx-selected-quiet)) "The rest of a card's progress bar."
  :group 'drgnx-work-space)

(defvar drgnx-work-board-mode-map
  (let ((m (make-sparse-keymap))) (set-keymap-parent m drgnx-work-lens-map) m)
  "Keys of the board.  The key profiles bind them (`drgnx-command-define' with the lens map).")

(define-derived-mode drgnx-work-board-mode special-mode "Work board"
  "The Work space's Board: the tracker's tasks by column, scoped to the selected plan."
  (setq-local truncate-lines t cursor-type nil drgnx-chrome-own-tab-line t
              tab-line-format '("" drgnx-work-map--lens)))

(declare-function drgnx-view-env-twin "drgnx-view-env" (class prefixes &optional setup))

(defun drgnx-work-board--twin (class)
  "The Board's buffer in display CLASS (`drgnx-view-patch-twin-function'): its state and its lens's, read again
before each command there."
  (drgnx-view-env-twin class '("drgnx-work-board-" "drgnx-work-lens-")))

(defun drgnx-work-board-buffers ()
  (seq-filter (lambda (b) (and (eq (buffer-local-value 'major-mode b) 'drgnx-work-board-mode) (not (drgnx-view-patch-twin-p b)))) (buffer-list)))

(defun drgnx-work-board-refresh (&optional buffer)
  "Ask the hub for BUFFER's Board (default: the current board) again (`drgnx-work-board--subscribe'); the hub reads
the tasks and sends the Board's model and rows.  Without Sjá nothing is asked."
  (with-current-buffer (or buffer (current-buffer))
    (when (drgnx-work-board--rows-p) (drgnx-work-board--subscribe))))

;;;; The hub's Board, with a model of its own (Sjá)

;; The Board's cards are the hub's rows and its keys answer from its own model (`work/board/subscribe'): a card node
;; per task with the `board' form's links, the lists `cards' and `team'.  Its selection is its own: it neither follows
;; the map's nor moves it (the map's model holds no tracker tasks).

(defun drgnx-work-board--rows-p ()
  "Whether this board is a hub-fed view with its model in Sjá."
  (and drgnx-view-patch (drgnx-view-patch-handle drgnx-view-patch) t))

(defun drgnx-work-board--rows-view (map-buffer)
  "The hub's Board view beside MAP-BUFFER's map view, (VIEW . CLASS), when the map is on the hub's rows, else nil."
  (with-current-buffer map-buffer
    (when drgnx-view-patch
      (cons (concat (drgnx-view-patch-view drgnx-view-patch) "/board") (drgnx-view-patch-class drgnx-view-patch)))))

(defun drgnx-work-board--subscribe ()
  "Ask the hub for this board's view: the tasks of its plans (else every task), with its map's agents on them.  On the
subscribed connection, as its map: the hub sends a view's rows to the connection that asked, and finds the map there."
  (when (buffer-live-p drgnx-work-board--map)
    (condition-case nil
        (drgnx-work-client--call "work/board/subscribe"
                                 (list :view (drgnx-view-patch-view drgnx-view-patch)
                                       :map (drgnx-view-patch-view (buffer-local-value 'drgnx-view-patch drgnx-work-board--map))
                                       :plans (vconcat drgnx-work-board--plans))
                                 #'ignore)
      (error nil))))

(defun drgnx-work-board-rows-attached ()
  "The board is a hub-fed view on the rows path: up, down, left and right take the `board' form's links."
  (nidhogg-view-set (drgnx-view-patch-handle drgnx-view-patch) 'form "board"))

(defun drgnx-work-board--nav (dir)
  "A key of the lens in the board: DIR is `left' `right' `up' `down' `next-agent' `previous-agent' `open' or
`open-beside', answered from the Board's model: a move follows the `board' form's link, the agent keys walk the list
`team', open opens the selected card's agent.  Without Sjá the keys move nothing."
  (when (drgnx-work-board--rows-p)
    (pcase dir
      ((or 'left 'right 'up 'down) (drgnx-view-nav 'follow (symbol-name dir)))
      ('next-agent (drgnx-view-nav 'walk "team" 1))
      ('previous-agent (drgnx-view-nav 'walk "team" -1))
      ((or 'open 'open-beside)
       (if-let* ((agent (and (drgnx-view-nav-selection) (drgnx-view-nav-field "agent"))))
           (drgnx-work--open-agent (substring agent (length "agent:")))
         (message "Work: no agent works on this task")))))
  t)

;;;; Opening a board

(defun drgnx-work-board--name (map-buffer)
  (format "*drgnx work board: %s*" (string-trim (buffer-name map-buffer) "\\*drgnx work: " "\\*")))

(defun drgnx-work-board--no-rows ()
  "Say in this board's new buffer that its map needs Sjá."
  (let ((inhibit-read-only t)) (insert drgnx-work-map-no-sja "\n")))

(defun drgnx-work-board-open (map-buffer)
  "The board of MAP-BUFFER, made when there is none, scoped to the plans the map's selection stands for (design 8.2).
Returns the buffer; it asks the hub for the Board and does not show itself.  Beside a map without Sjá the board says
so instead."
  (let ((buffer (get-buffer-create (drgnx-work-board--name map-buffer)))
        (rows (drgnx-work-board--rows-view map-buffer)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'drgnx-work-board-mode)
        (drgnx-work-board-mode)
        (setq drgnx-work-lens-nav #'drgnx-work-board--nav)
        (if rows
            (progn (drgnx-view-patch-attach (car rows) (cdr rows) :sja t)
                   (setq-local drgnx-view-patch-twin-function #'drgnx-work-board--twin)
                   (require 'drgnx-view-env)
                   (drgnx-view-env-register (car rows) buffer))
          (drgnx-work-board--no-rows)))
      (setq drgnx-work-board--map map-buffer drgnx-work-lens--map map-buffer)
      (setq drgnx-work-board--plans (drgnx-work-board-plans-for map-buffer))
      (setq drgnx-work-map--lens (drgnx-work-lens-string 'board (drgnx-work-lens-name map-buffer)))
      (when rows (drgnx-work-board-rows-attached))
      (drgnx-work-board-refresh buffer))
    buffer))

;;;; Switching between the lens's views, keeping the selection

(defun drgnx-work-lens-map-buffer ()
  "The map buffer of the current Work view."
  (cond ((derived-mode-p 'drgnx-work-map-mode) (current-buffer))
        ((buffer-live-p drgnx-work-lens--map) drgnx-work-lens--map)
        (t (user-error "This view has no map"))))

(defun drgnx-work-lens-switch (lens)
  "Show LENS (`map', `board' or `timeline') in this window, with the selection of the view that was shown.  The
agent of the Timeline's selected step becomes the map's selection; the Board's selection is its own
\(`drgnx-work-board--rows-p')."
  (let ((map (drgnx-work-lens-map-buffer)))
    (when-let* ((sid (and (derived-mode-p 'drgnx-work-timeline-mode) (drgnx-work-board--rows-p) (drgnx-view-nav-selection)
                          (drgnx-view-nav-field "session")))
                ((with-current-buffer map (drgnx-work-map--sja))))
      (with-current-buffer map (drgnx-work-map-select (cons 'agent (concat "agent:" sid)))))
    (pop-to-buffer-same-window
     (pcase lens
       ('map map)
       ('board (drgnx-work-board-open map))
       ('timeline (if (fboundp 'drgnx-work-timeline-open) (drgnx-work-timeline-open map)
                    (user-error "The Timeline is not loaded")))))
    ;; leaving the Flow: the map's side panel where its tile showed
    (when (fboundp 'drgnx-work-flow-detail-hide) (drgnx-work-flow-detail-hide map))))

(defun drgnx-work-lens-show-map () "Show the map, keeping the selection." (interactive) (drgnx-work-lens-switch 'map))
(defun drgnx-work-lens-show-board () "Show the Board, keeping the selection." (interactive) (drgnx-work-lens-switch 'board))
(defun drgnx-work-lens-show-timeline () "Show the Timeline, keeping the selection." (interactive) (drgnx-work-lens-switch 'timeline))

(provide 'drgnx-work-board)
;;; drgnx-work-board.el ends here
