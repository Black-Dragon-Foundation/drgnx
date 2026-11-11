;;; drgnx-work-flow.el --- The Work space's Flow lens: a plan run's tasks by gate (library of tools/work-space) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The Flow is the fourth view of the lens (Map · Board · Timeline · Flow): a plan run as the hub's records, a row per
;; task and a column per gate (Brief, Red first, Build, Author check, Merge batch, Review), each cell a chip of the
;; gate's state; under them the merge batch and the rule pack.  The hub builds it (`work/flow/subscribe'): its rows,
;; and a model of its own (Sjá) whose selection is the Flow's alone, with the held tasks in its list `held'.  `e' shows
;; the selected task's evidence (`orch/evidence'), `R' the rule pack's rows.  Off the rows path it says so.
;; Loaded by tools/work-space (drgnx-work-space.el); defines no module.  See docs/develop/orchestration.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-view)
(require 'drgnx-view-nav)
(require 'drgnx-work-client)
(require 'drgnx-pixels)
(unless (featurep 'drgnx-work-map)
  (load (expand-file-name "drgnx-work-map" (file-name-directory (or load-file-name buffer-file-name))) nil t))

(declare-function drgnx-view-env-register "drgnx-view-env")
(declare-function drgnx-view-env-twin "drgnx-view-env" (class prefixes &optional setup))
(declare-function drgnx-hub-call "drgnx-hub-client")
(declare-function nidhogg-view-set "nidhogg-views" (h what value))
(declare-function drgnx-work-lens-string "drgnx-work-map")
(declare-function drgnx-work-lens-name "drgnx-work-map")
(defvar drgnx-work-lens--map)
(defvar drgnx-work-map--strip)
(defvar drgnx-chrome-own-tab-line)
(defvar drgnx-work-lens-nav)
(defvar drgnx-work-lens-map)
(defvar drgnx-work-map--lens)

;;;; The faces the hub's Flow rows name: the UI font, the theme's chips and text

(defface drgnx-work-flow-text '((t :inherit drgnx-ui-text)) "The Flow's text: a task's title, the tiles' lines."
  :group 'drgnx-work-space)
(defface drgnx-work-flow-label '((t :inherit (drgnx-ui-caption drgnx-text-muted)))
  "The Flow's labels: task ids, agents, column headings." :group 'drgnx-work-space)
(defface drgnx-work-flow-heading '((t :inherit drgnx-ui-heading)) "The Flow's headings: the run, the batch, a tile's."
  :group 'drgnx-work-space)
(defface drgnx-work-flow-chip-ok '((t :inherit (drgnx-ui-caption drgnx-chip-ok))) "A gate that passed."
  :group 'drgnx-work-space)
(defface drgnx-work-flow-chip-run '((t :inherit (drgnx-ui-caption drgnx-chip-accent))) "A gate that runs."
  :group 'drgnx-work-space)
(defface drgnx-work-flow-chip-held '((t :inherit (drgnx-ui-caption drgnx-chip-attention)))
  "A gate that holds the task: it needs you." :group 'drgnx-work-space)
(defface drgnx-work-flow-chip-err '((t :inherit (drgnx-ui-caption drgnx-chip-error))) "A gate that failed."
  :group 'drgnx-work-space)
(defface drgnx-work-flow-chip-wait '((t :inherit (drgnx-ui-caption drgnx-chip-quiet))) "A gate not reached yet."
  :group 'drgnx-work-space)

;;;; What the Flow asks and shows: pure

(defun drgnx-work-flow--ask (view map job)
  "Ask the hub for the Flow VIEW beside map view MAP: job JOB's, else (nil) the newest running job's."
  (drgnx-work-client--call "work/flow/subscribe"
                           (append (list :view view :map map) (and job (list :job job)))
                           #'ignore))

(defun drgnx-work-flow--evidence-line (e)
  "Record E (a plist as `orch/evidence' answers it) as one line: its kind, job, tree and command, then its failing
rows or its pass count; a waiver says its reason."
  (let* ((facts (plist-get e :facts))
         (tree (substring (or (plist-get facts :tree_key) "") 0 (min 7 (length (or (plist-get facts :tree_key) "")))))
         (kind (plist-get e :kind)))
    (if (equal kind "waiver")
        (format "%-7s  %s  by you: %s" kind tree (or (plist-get e :note) ""))
      (let* ((rows (append (plist-get e :rows) nil))
             (failed (seq-filter (lambda (r) (equal (plist-get r :verdict) "fail")) rows))
             (pass (seq-count (lambda (r) (equal (plist-get r :verdict) "pass")) rows))
             (command (or (cadr (split-string (or (plist-get facts :selector) "") "\n")) "")))
        (format "%-7s  job %s  %s  %s  %s" kind (plist-get e :job) tree command
                (if failed
                    (format "%d failed: %s" (length failed)
                            (mapconcat (lambda (r) (plist-get r :name)) failed ", "))
                  (format "%d pass" pass)))))))

(defun drgnx-work-flow--evidence-lines (evidence)
  "EVIDENCE (a vector of records, oldest first) as lines; a line saying so when there is none."
  (if (seq-empty-p evidence)
      (list "No evidence yet.")
    (mapcar #'drgnx-work-flow--evidence-line evidence)))

;;;; The Flow buffer

(defvar-local drgnx-work-flow--map nil "The map buffer this Flow is a view of.")
(defvar-local drgnx-work-flow--job nil "The job this Flow shows; nil: the newest running job.")

(defvar drgnx-work-flow-mode-map
  (let ((m (make-sparse-keymap))) (set-keymap-parent m drgnx-work-lens-map) m)
  "Keys of the Flow.  The key profiles bind them (`drgnx-command-define' with this map or the lens map).")

(define-derived-mode drgnx-work-flow-mode special-mode "Work flow"
  "The Work space's Flow lens: a plan run's tasks by gate, its merge batch and its rule pack."
  (setq-local truncate-lines t cursor-type nil drgnx-chrome-own-tab-line t
              tab-line-format '("" drgnx-work-map--lens)
              header-line-format '(:eval (drgnx-work-flow--strip))))

(defun drgnx-work-flow--strip ()
  "The Flow's header: its map's strip (what needs you with its jump keys, the machines' load), as the map last made
it; redisplay only reads it."
  (if (buffer-live-p drgnx-work-flow--map) (buffer-local-value 'drgnx-work-map--strip drgnx-work-flow--map) ""))

(defun drgnx-work-flow--twin (class)
  "The Flow's buffer in display CLASS (`drgnx-view-patch-twin-function')."
  (drgnx-view-env-twin class '("drgnx-work-flow-" "drgnx-work-lens-")))

(defun drgnx-work-flow-buffers ()
  "The live Flow buffers."
  (seq-filter (lambda (b) (and (eq (buffer-local-value 'major-mode b) 'drgnx-work-flow-mode)
                               (not (drgnx-view-patch-twin-p b))))
              (buffer-list)))

(defun drgnx-work-flow--rows-p ()
  "Whether this Flow is a hub-fed view with its model in Sjá (the rows path)."
  (and (not drgnx-view-old-path) drgnx-view-patch (drgnx-view-patch-handle drgnx-view-patch) t))

(defun drgnx-work-flow-refresh (&optional buffer)
  "Ask the hub for BUFFER's Flow (default: the current one) again; off the rows path nothing is asked."
  (with-current-buffer (or buffer (current-buffer))
    (when (and (drgnx-work-flow--rows-p) (buffer-live-p drgnx-work-flow--map))
      (ignore-errors
        (drgnx-work-flow--ask (drgnx-view-patch-view drgnx-view-patch)
                              (drgnx-view-patch-view (buffer-local-value 'drgnx-view-patch drgnx-work-flow--map))
                              drgnx-work-flow--job)))))

(defun drgnx-work-flow--nav (dir)
  "A key of the lens in the Flow: DIR `up' or `down' follows the `flow' form's link, `next-agent' and
`previous-agent' walk the held tasks; the others move nothing.  Off the rows path the keys move nothing."
  (when (drgnx-work-flow--rows-p)
    (pcase dir
      ((or 'up 'down) (drgnx-view-nav 'follow (symbol-name dir)))
      ('next-agent (drgnx-view-nav 'walk "held" 1))
      ('previous-agent (drgnx-view-nav 'walk "held" -1))))
  t)

;;;; The cards' rings and the rows' rules: Glitnir blocks (`glitnir-blocks', Nidhogg's `glitnir.el')
;; The hub marks them on its rows (`drgnx-work-flow-block': ["ring" ID X0 X1] on a card's span of each of its rows,
;; ["rule" KEY X0 X1] on a row with a hairline under it, device px); the rows give the cards' fill.  A box could not
;; draw them: a box is one row high, the chips have boxes of their own, and the two cards share their rows.  The
;; window parameter is set only when the blocks changed, never per redisplay; their colours are faces, which Glitnir
;; resolves again on a theme change.

(defface drgnx-work-flow-card '((t :inherit drgnx-surface-panel)) "A Flow card's fill: the batch, the line gate."
  :group 'drgnx-work-space)
;; a span of the rows has one face, so the text on a card names its twin, which carries the fill
(defface drgnx-work-flow-card-text '((t :inherit (drgnx-work-flow-text drgnx-work-flow-card)))
  "The Flow's text on a card." :group 'drgnx-work-space)
(defface drgnx-work-flow-card-label '((t :inherit (drgnx-work-flow-label drgnx-work-flow-card)))
  "The Flow's labels on a card." :group 'drgnx-work-space)
(defface drgnx-work-flow-card-heading '((t :inherit (drgnx-work-flow-heading drgnx-work-flow-card)))
  "A card's heading." :group 'drgnx-work-space)

(defvar-local drgnx-work-flow--blocks nil "The Flow's blocks as last set (`glitnir-blocks'), with markers.")
(defvar-local drgnx-work-flow--blocks-key nil
  "`drgnx-work-flow--blocks' with positions for its markers, as last computed: what a patch compares.")

(defun drgnx-work-flow--block-spec ()
  "The Flow's blocks from its rows' `drgnx-work-flow-block' marks: a `glitnir-blocks' value with positions, one block
per mark from the first row it is on to the end of the last (a ring: radius 8 px in `drgnx-border', its corners in
the colour of `default' beneath; a rule: a hairline in `drgnx-border-subtle')."
  (let ((pos (point-min)) (spans (make-hash-table :test 'equal)) order)
    (while (< pos (point-max))
      (let ((v (get-text-property pos 'drgnx-work-flow-block))
            (next (next-single-property-change pos 'drgnx-work-flow-block nil (point-max))))
        (when v
          (let ((span (gethash v spans)))
            (if span (setcdr span next) (puthash v (cons pos next) spans) (push v order))))
        (setq pos next)))
    (mapcar (lambda (v)
              (let ((span (gethash v spans)) (ring (equal (elt v 0) "ring")))
                `(,(if ring 'ring 'rule) ,(car span) ,(cdr span) :x0 ,(elt v 2) :x1 ,(elt v 3)
                  ,@(if ring `(:radius ,(drgnx-px 8) :ring drgnx-border :beneath default)
                      '(:ring drgnx-border-subtle)))))
            (nreverse order))))

(defun drgnx-work-flow--blocks ()
  "Give the windows showing this Flow its blocks, when they changed.  A patch that gives the same blocks only puts
their markers back: the window parameter stays the same object."
  (let ((key (drgnx-work-flow--block-spec)))
    (if (equal key drgnx-work-flow--blocks-key)
        (cl-loop for b in drgnx-work-flow--blocks for k in key
                 do (set-marker (nth 1 b) (nth 1 k)) (set-marker (nth 2 b) (nth 2 k)))
      (dolist (b drgnx-work-flow--blocks) (set-marker (nth 1 b) nil) (set-marker (nth 2 b) nil))
      (setq drgnx-work-flow--blocks-key key
            drgnx-work-flow--blocks
            (mapcar (lambda (k) (append (list (car k) (copy-marker (nth 1 k)) (copy-marker (nth 2 k))) (nthcdr 3 k)))
                    key)))
    (dolist (w (get-buffer-window-list (current-buffer) nil t))
      (unless (eq (window-parameter w 'glitnir-blocks) drgnx-work-flow--blocks)
        (set-window-parameter w 'glitnir-blocks drgnx-work-flow--blocks)))))

(defun drgnx-work-flow--patched (_view _keys)
  "`drgnx-view-patch-patched-functions' in a Flow: its blocks follow its rows."
  (drgnx-work-flow--blocks))

(defun drgnx-work-flow--unblock ()
  "The Flow goes (`kill-buffer-hook'): no window keeps its blocks."
  (let ((blocks drgnx-work-flow--blocks))
    (when blocks
      (walk-windows (lambda (w) (when (eq (window-parameter w 'glitnir-blocks) blocks)
                                  (set-window-parameter w 'glitnir-blocks nil)))
                    nil t))))

(defun drgnx-work-flow--name (map-buffer)
  (format "*drgnx work flow: %s*" (string-trim (buffer-name map-buffer) "\\*drgnx work: " "\\*")))

(defun drgnx-work-flow-open (map-buffer)
  "The Flow of MAP-BUFFER, made when there is none; it asks the hub for the Flow and does not show itself.  Beside a
map that is not on the rows path it says so instead."
  (let ((buffer (get-buffer-create (drgnx-work-flow--name map-buffer)))
        (rows (with-current-buffer map-buffer
                (when-let* ((state (and (not drgnx-view-old-path) drgnx-view-patch)))
                  (cons (concat (drgnx-view-patch-view state) "/flow") (drgnx-view-patch-class state))))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'drgnx-work-flow-mode)
        (drgnx-work-flow-mode)
        (setq drgnx-work-lens-nav #'drgnx-work-flow--nav)
        (if rows
            (progn (drgnx-view-patch-attach (car rows) (cdr rows))
                   (setq-local drgnx-view-patch-twin-function #'drgnx-work-flow--twin)
                   (require 'drgnx-view-env)
                   (drgnx-view-env-register (car rows) buffer)
                   (nidhogg-view-set (drgnx-view-patch-handle drgnx-view-patch) 'form "flow")
                   ;; the selection is the Flow's own: its tile follows it
                   (add-hook 'drgnx-view-selected-functions #'drgnx-work-flow--selected-moved nil t)
                   ;; the cards' rings and the rows' rules follow every patch
                   (add-hook 'drgnx-view-patch-patched-functions #'drgnx-work-flow--patched nil t)
                   (add-hook 'kill-buffer-hook #'drgnx-work-flow--unblock nil t))
          (let ((inhibit-read-only t))
            (insert "The Flow needs Sjá, Nidhogg's view model: it is drawn from the hub's rows, and this Emacs has"
                    " no Sjá (or `drgnx-view-old-path' is set).\n"))))
      (setq drgnx-work-flow--map map-buffer drgnx-work-lens--map map-buffer
            drgnx-work-map--lens (drgnx-work-lens-string 'flow (drgnx-work-lens-name map-buffer)
                                                         '(("evidence" . "e") ("rules" . "R"))))
      (drgnx-work-flow-refresh buffer))
    buffer))

;;;; The Flow's own keys

(defun drgnx-work-flow-evidence ()
  "Show the selected task's evidence: the hub's records of its runs, its gates' findings and waivers, oldest first."
  (interactive)
  (let ((task (and (drgnx-work-flow--rows-p) (drgnx-view-nav-selection))))
    (unless task (user-error "Work: select a task first"))
    (drgnx-hub-call "orch/evidence" (list :task task)
                    (lambda (result err)
                      (if err
                          (message "Work: no evidence for %s (%s)" task (or (plist-get err :message) err))
                        ;; a fresh buffer each time: the list is a one-off answer, never patched
                        (when-let* ((old (get-buffer "*drgnx evidence*"))) (kill-buffer old))
                        (with-current-buffer (get-buffer-create "*drgnx evidence*")
                          (let ((inhibit-read-only t))
                            (insert (propertize (format "Evidence · %s\n\n" task) 'face 'bold))
                            (dolist (l (drgnx-work-flow--evidence-lines (plist-get result :evidence)))
                              (insert l "\n")))
                          (special-mode)
                          (goto-char (point-min))
                          (display-buffer (current-buffer))))))))

;;;; The Rules tile: the run's rule pack in the bottom panel

(defvar-local drgnx-work-flow--rules nil "In a Flow: its Rules tile.  In a tile: the Flow it belongs to.")

(defun drgnx-work-flow--rules-params (view map job)
  "The params that make VIEW the Rules tile beside map view MAP, of job JOB (nil: the hub's newest)."
  (append (list :view view :map map :rules t) (and job (list :job job))))

(define-derived-mode drgnx-work-flow-rules-mode special-mode "Work rules"
  "The Flow's Rules tile: the hub's rows of the run's rule pack, each rule's kind and how the hub holds it."
  (setq-local truncate-lines t cursor-type nil))

(defun drgnx-work-flow--rules-twin (class)
  "The tile's buffer in display CLASS (`drgnx-view-patch-twin-function')."
  (drgnx-view-env-twin class '("drgnx-work-flow-")))

(defun drgnx-work-flow-rules-buffers ()
  "The live Rules tiles."
  (seq-filter (lambda (b) (and (eq (buffer-local-value 'major-mode b) 'drgnx-work-flow-rules-mode)
                               (not (drgnx-view-patch-twin-p b))))
              (buffer-list)))

(defun drgnx-work-flow-rules-buffer (flow)
  "FLOW's Rules tile, made and asked for when there is none: the hub's rows of the view VIEW/rules.  Nil off the rows
path."
  (with-current-buffer flow
    (when (and (drgnx-work-flow--rows-p) (buffer-live-p drgnx-work-flow--map))
      (unless (buffer-live-p drgnx-work-flow--rules)
        (let ((view (concat (drgnx-view-patch-view drgnx-view-patch) "/rules"))
              (class (drgnx-view-patch-class drgnx-view-patch))
              (map-view (drgnx-view-patch-view (buffer-local-value 'drgnx-view-patch drgnx-work-flow--map)))
              (buffer (get-buffer-create (format "*drgnx work rules: %s*"
                                                 (string-trim (buffer-name flow) "\\*drgnx work flow: " "\\*")))))
          (with-current-buffer buffer
            (drgnx-work-flow-rules-mode)
            (drgnx-view-patch-attach view class)
            (setq-local drgnx-view-patch-twin-function #'drgnx-work-flow--rules-twin)
            (require 'drgnx-view-env)
            (drgnx-view-env-register view buffer)
            (setq drgnx-work-flow--rules flow))
          (setq drgnx-work-flow--rules buffer)
          (drgnx-work-client--call "work/flow/subscribe"
                                   (drgnx-work-flow--rules-params view map-view drgnx-work-flow--job) #'ignore)))
      drgnx-work-flow--rules)))

(declare-function drgnx-pane-show "drgnx-panes")
(defvar drgnx-work-flow--detail)

(defun drgnx-work-flow-rules ()
  "Show the run's rule pack in the bottom panel: each rule, its kind and how the hub holds it."
  (interactive)
  (let* ((flow (if (derived-mode-p 'drgnx-work-flow-detail-mode) drgnx-work-flow--detail (current-buffer)))
         (tile (and (buffer-live-p flow) (drgnx-work-flow-rules-buffer flow)))
         (win (selected-window)))
    (unless tile (user-error "Work: the Rules tile needs the Flow on the hub's rows"))
    (drgnx-pane-show 'work-rules)
    (when (window-live-p win) (select-window win))))

;;;; The detail tile: the selected task's why, what clears it, its evidence and its actions

(defvar-local drgnx-work-flow--selected nil "The task the Flow's detail tile shows (the Flow's selection).")
(defvar-local drgnx-work-flow--detail nil "In a Flow: its detail tile.  In a tile: the Flow it details.")

(defun drgnx-work-flow--detail-params (view map job task)
  "The params that make VIEW the detail tile of TASK, beside map view MAP, of job JOB (nil: the hub's newest)."
  (append (list :view view :map map :detail task) (and job (list :job job))))

(defvar drgnx-work-flow-detail-mode-map
  (let ((m (make-sparse-keymap))) (set-keymap-parent m drgnx-work-flow-mode-map) m)
  "Keys of the detail tile: the Flow's, so its actions answer from either.")

(define-derived-mode drgnx-work-flow-detail-mode special-mode "Work flow detail"
  "The Flow's detail tile: the hub's rows for the Flow's selected task, its actions on the Flow's keys."
  (setq-local truncate-lines t cursor-type nil))

(defun drgnx-work-flow--detail-twin (class)
  "The tile's buffer in display CLASS (`drgnx-view-patch-twin-function')."
  (drgnx-view-env-twin class '("drgnx-work-flow-")))

(defun drgnx-work-flow-detail-buffers ()
  "The live detail tiles."
  (seq-filter (lambda (b) (and (eq (buffer-local-value 'major-mode b) 'drgnx-work-flow-detail-mode)
                               (not (drgnx-view-patch-twin-p b))))
              (buffer-list)))

(defun drgnx-work-flow-detail-buffer (flow)
  "FLOW's detail tile, made when there is none: the hub's rows of the view VIEW/detail beside the Flow's VIEW.  Nil
off the rows path."
  (with-current-buffer flow
    (when (drgnx-work-flow--rows-p)
      (unless (buffer-live-p drgnx-work-flow--detail)
        (let ((view (concat (drgnx-view-patch-view drgnx-view-patch) "/detail"))
              (class (drgnx-view-patch-class drgnx-view-patch))
              (buffer (get-buffer-create (format "*drgnx work flow detail: %s*"
                                                 (string-trim (buffer-name flow) "\\*drgnx work flow: " "\\*")))))
          (with-current-buffer buffer
            (drgnx-work-flow-detail-mode)
            (drgnx-view-patch-attach view class)
            (setq-local drgnx-view-patch-twin-function #'drgnx-work-flow--detail-twin)
            (require 'drgnx-view-env)
            (drgnx-view-env-register view buffer)
            (setq drgnx-work-flow--detail flow))
          (setq drgnx-work-flow--detail buffer)))
      drgnx-work-flow--detail)))

(defun drgnx-work-flow--ask-detail (flow)
  "Ask the hub for FLOW's detail tile of its selected task (nothing while none is selected)."
  (with-current-buffer flow
    (when-let* ((task drgnx-work-flow--selected) ((buffer-live-p drgnx-work-flow--map))
                (tile (drgnx-work-flow-detail-buffer flow)))
      (drgnx-work-client--call "work/flow/subscribe"
                               (drgnx-work-flow--detail-params
                                (drgnx-view-patch-view (buffer-local-value 'drgnx-view-patch tile))
                                (drgnx-view-patch-view (buffer-local-value 'drgnx-view-patch drgnx-work-flow--map))
                                drgnx-work-flow--job task)
                               #'ignore))))

(defun drgnx-work-flow--selected-moved (buffer id)
  "`drgnx-view-selected-functions' in a Flow: BUFFER's selection is ID now, and its tile shows that task."
  (when (and id (buffer-live-p buffer))
    (with-current-buffer buffer
      (when (derived-mode-p 'drgnx-work-flow-mode)
        (setq drgnx-work-flow--selected id)
        (drgnx-work-flow--ask-detail buffer)))))

(defun drgnx-work-flow--swap-window (from to)
  "The window of the selected frame that shows FROM shows TO instead (none: nothing changes)."
  (when-let* (((buffer-live-p to)) (w (and (buffer-live-p from) (get-buffer-window from))))
    (set-window-buffer w to)))

(defun drgnx-work-flow-detail-show (flow)
  "FLOW's tile where its map's side panel shows: the right dock follows the lens."
  (when-let* ((tile (drgnx-work-flow-detail-buffer flow))
              (map (buffer-local-value 'drgnx-work-flow--map flow)))
    (dolist (b (drgnx-work-detail-buffers))
      (when (eq (buffer-local-value 'drgnx-work-detail--map b) map)
        (drgnx-work-flow--swap-window b tile)))))

(defun drgnx-work-flow-detail-hide (map)
  "The lens left the Flow of MAP: its map's side panel where the tile showed."
  (dolist (tile (drgnx-work-flow-detail-buffers))
    (when-let* ((flow (buffer-local-value 'drgnx-work-flow--detail tile))
                ((buffer-live-p flow))
                ((eq (buffer-local-value 'drgnx-work-flow--map flow) map)))
      (drgnx-work-flow--swap-window tile (drgnx-work-detail-buffer map)))))

(defun drgnx-work-flow--card-of (task)
  "The `gate' card on TASK's row in this Flow (the hub puts it there while a gate holds the task), or nil."
  (let ((pos (point-min)) card)
    (while (and (not card) pos)
      (when (and (equal (get-text-property pos 'drgnx-work-id) task) (get-text-property pos 'drgnx-work-card))
        (setq card (get-text-property pos 'drgnx-work-card)))
      (setq pos (next-single-property-change pos 'drgnx-work-id)))
    card))

(defun drgnx-work-flow--held-card ()
  "The card of the task selected in this Flow (or in the Flow this tile details); an error when no gate holds it."
  (let ((flow (if (derived-mode-p 'drgnx-work-flow-detail-mode) drgnx-work-flow--detail (current-buffer))))
    (unless (and (buffer-live-p flow) (with-current-buffer flow (derived-mode-p 'drgnx-work-flow-mode)))
      (user-error "Work: not in a Flow"))
    (with-current-buffer flow
      (let ((task (or drgnx-work-flow--selected (user-error "Work: select a task first"))))
        (or (drgnx-work-flow--card-of task) (user-error "Work: no gate holds %s" task))))))

(defun drgnx-work-flow--act (card action &optional arg)
  "Answer CARD with ACTION (and ARG) as the user (`job/card'); say how it went."
  (drgnx-hub-call "job/card" (append (list :card card :action action) (and arg (list :arg arg)))
                  (lambda (_result err)
                    (message (if err (format "Work: %s: %s" action (or (plist-get err :message) err))
                               (format "Work: %s sent" action))))
                  :deadline 10))

(defun drgnx-work-flow-run-red ()
  "The held task's gates again: the hub runs what they miss (the red, the author check) and merges when they pass."
  (interactive)
  (drgnx-work-flow--act (drgnx-work-flow--held-card) "merge"))

(defun drgnx-work-flow-tell-agent ()
  "Send the held task back to its agent with the gate card's words."
  (interactive)
  (drgnx-work-flow--act (drgnx-work-flow--held-card) "retry"))

(defun drgnx-work-flow-waive (reason)
  "Waive the held task's gates once, for its tip only, with REASON: recorded on the task as your waiver.  Only you can
waive (the hub takes a waiver from the user's connection alone)."
  (interactive (list (read-string "Waive once, the reason: ")))
  (let ((card (drgnx-work-flow--held-card)))
    (when (string-blank-p reason) (user-error "Work: a waiver needs its reason"))
    (drgnx-work-flow--act card "waive" (string-trim reason))))

(declare-function drgnx-work-detail-buffers "drgnx-work-detail")
(declare-function drgnx-work-detail-buffer "drgnx-work-detail")
(defvar drgnx-work-detail--map)

(defun drgnx-work-lens-show-flow ()
  "Show the Flow lens of the map's newest running job, its detail tile where the map's side panel was."
  (interactive)
  (let ((flow (drgnx-work-flow-open (drgnx-work-lens-map-buffer))))
    (pop-to-buffer-same-window flow)
    ;; its blocks on the window it shows in now
    (with-current-buffer flow (when drgnx-work-flow--blocks (drgnx-work-flow--blocks)))
    (drgnx-work-flow-detail-show flow)))

(declare-function drgnx-work-lens-map-buffer "drgnx-work-board")

(provide 'drgnx-work-flow)
;;; drgnx-work-flow.el ends here
