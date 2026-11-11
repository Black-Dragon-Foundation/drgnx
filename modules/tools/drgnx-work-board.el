;;; drgnx-work-board.el --- The Work space's Board: tasks by the tracker's columns (library of tools/work-space) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The Board is the second view of the lens (Map · Board · Timeline): the tracker's tasks in part 1's six columns
;; (queued, running, waiting, needs you, review, done), one flat card each with a 4 px progress bar.  It is scoped to
;; the plan the map's selection stands in (or plans, for a spec or an ask), else it shows every task.  The hub builds
;; it (`work/board/subscribe'): its rows, and a model of its own (Sjá) whose selection is the Board's alone.  It is
;; drawn only from those rows: beside a map that is not on the rows path (no Sjá) it says so.
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
(declare-function drgnx-work-map-buffer "drgnx-work-map")
(declare-function drgnx-work-lens-string "drgnx-work-map")
(declare-function drgnx-work-map--state "drgnx-work-map")
(declare-function drgnx-work-nav-chain "drgnx-work-detail")
(defvar drgnx-work-lens--map)
(defvar drgnx-work-lens-nav)
(defvar drgnx-work-lens-map)
(defvar drgnx-work-map--lens)
(defvar drgnx-work-map--selection)
(defvar drgnx-work-timeline--sel)

;;;; What the map's selection scopes the Board to (design 8.2): pure

(defun drgnx-work-board--agents-near (state sel)
  "The agents SEL leads to or comes from in STATE: those on its chain, in the chain's order."
  (let ((chain (drgnx-work-nav-chain state sel)))
    (seq-filter (lambda (id) (equal (plist-get (drgnx-work-client-item state id) :kind) "agent"))
                (append (nth 0 chain) (nth 1 chain)))))

(defun drgnx-work-board-plans-for (state sel)
  "The plans the Board is scoped to for the map selection SEL (KIND . ID) of STATE: a plan itself, or the plans below a
spec or an ask; nil for anything else (every task)."
  (pcase (car sel)
    ('plan (list (cdr sel)))
    ((or 'spec 'ask)
     (seq-filter (lambda (id) (equal (plist-get (drgnx-work-client-item state id) :kind) "plan"))
                 (nth 1 (drgnx-work-nav-chain state sel))))))

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
  (setq-local truncate-lines t cursor-type nil
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
the tasks and sends the Board's model and rows.  Off the rows path nothing is asked."
  (with-current-buffer (or buffer (current-buffer))
    (when (drgnx-work-board--rows-p) (drgnx-work-board--subscribe))))

;;;; The hub's Board, with a model of its own (Sjá)

;; The Board's cards are the hub's rows and its keys answer from its own model (`work/board/subscribe'): a card node
;; per task with the `board' form's links, the lists `cards' and `team'.  Its selection is its own: it neither follows
;; the map's nor moves it (the map's model holds no tracker tasks).

(defun drgnx-work-board--rows-p ()
  "Whether this board is a hub-fed view with its model in Sjá (the rows path)."
  (and (not drgnx-view-old-path) drgnx-view-patch (drgnx-view-patch-handle drgnx-view-patch) t))

(defun drgnx-work-board--rows-view (map-buffer)
  "The hub's Board view beside MAP-BUFFER's map view, (VIEW . CLASS), when the map is on the rows path, else nil."
  (with-current-buffer map-buffer
    (when-let* ((state (and (not drgnx-view-old-path) drgnx-view-patch)))
      (cons (concat (drgnx-view-patch-view state) "/board") (drgnx-view-patch-class state)))))

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
`team', open opens the selected card's agent.  Off the rows path the keys move nothing."
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
  "Say in this board's new buffer that the Board is drawn only from the hub's rows, which this Emacs cannot show."
  (let ((inhibit-read-only t))
    (insert "The Board needs Sjá, Nidhogg's view model: it is drawn from the hub's rows, and this Emacs has no Sjá"
            " (or `drgnx-view-old-path' is set).\n")))

(defun drgnx-work-board-open (map-buffer)
  "The board of MAP-BUFFER, made when there is none, scoped to the plans the map's selection stands for (design 8.2).
Returns the buffer; it asks the hub for the Board and does not show itself.  Beside a map that is not on the rows path
the board says so instead."
  (let ((buffer (get-buffer-create (drgnx-work-board--name map-buffer)))
        (rows (drgnx-work-board--rows-view map-buffer)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'drgnx-work-board-mode)
        (drgnx-work-board-mode)
        (setq drgnx-work-lens-nav #'drgnx-work-board--nav)
        (if rows
            (progn (drgnx-view-patch-attach (car rows) (cdr rows))
                   (setq-local drgnx-view-patch-twin-function #'drgnx-work-board--twin)
                   (require 'drgnx-view-env)
                   (drgnx-view-env-register (car rows) buffer))
          (drgnx-work-board--no-rows)))
      (setq drgnx-work-board--map map-buffer drgnx-work-lens--map map-buffer)
      (let ((state (drgnx-work-map--state map-buffer))
            (sel (buffer-local-value 'drgnx-work-map--selection map-buffer)))
        (setq drgnx-work-board--plans (and state sel (drgnx-work-board-plans-for state sel))))
      (setq drgnx-work-map--lens (drgnx-work-lens-string 'board))
      (when rows (drgnx-work-board-rows-attached))
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
  "Show LENS (`map', `board' or `timeline') in this window, with the selection of the view that was shown.  The
Timeline's lane becomes the map's selection; the Board's selection is its own (`drgnx-work-board--rows-p')."
  (let ((map (drgnx-work-lens-map-buffer)))
    (when-let* ((sel (and (derived-mode-p 'drgnx-work-timeline-mode)
                          (when-let* ((lane (car drgnx-work-timeline--sel))) (cons 'agent lane)))))
      (with-current-buffer map (drgnx-work-map-select sel)))
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
