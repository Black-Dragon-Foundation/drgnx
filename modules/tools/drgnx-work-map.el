;;; drgnx-work-map.el --- The Work map's buffer: mode, view type and rows (library of tools/work-space) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The map is one read-only buffer, `*drgnx work: NAME*', in `drgnx-work-map-mode': a `drgnx-view' whose rows are
;; the layout's sub-rows `(:row LAYER BLOCK-LINE SUB)' and the bands between them `(:band LAYER BLOCK-LINE SUB)', in
;; the order of their y.  A row's text is a function of the cached frame (core/drgnx-work-client.el) and the scale:
;; cards are buffer text, their lines placed by pixel `:align-to' from the layout's units, their boxes the decoration
;; faces' (modules/ui/drgnx-decor.el); the bands are blank lines of their height, which the edge tiles draw into.
;; The same frame is also drawn as an outline (one block per agent), in terminals, when the layout does not fit, and
;; on `O'.  The buffer's view id is `drgnx-work-space--view'.  Keys come from the key profiles (keys/*.eld), never
;; from this file.  Loaded by tools/work-space (drgnx-work-space.el); defines no module.
;; See docs/develop/work-space.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-view)
(require 'drgnx-work-client)
(unless (featurep 'drgnx-decor)
  (load (expand-file-name "../ui/drgnx-decor" (file-name-directory (or load-file-name buffer-file-name))) nil t))

(unless (featurep 'drgnx-work-edges)
  (load (expand-file-name "drgnx-work-edges" (file-name-directory (or load-file-name buffer-file-name))) nil t))

(unless (featurep 'drgnx-runners-view)
  (load (expand-file-name "drgnx-runners-view" (file-name-directory (or load-file-name buffer-file-name))) nil t))

(declare-function drgnx-runners-view-dot-face "drgnx-runners-view")
(declare-function drgnx-work-space--show-detail "drgnx-work-space")
(declare-function drgnx-face-glyph "drgnx-ui-kit")
(declare-function drgnx-work-edges-geometry "drgnx-work-edges")
(declare-function drgnx-work-edges-colours "drgnx-work-edges")
(declare-function drgnx-work-edges-key "drgnx-work-edges")
(declare-function drgnx-work-edges-band-text "drgnx-work-edges")
(declare-function drgnx-work-edges-band-tiles "drgnx-work-edges")
(declare-function drgnx-work-edges-lane-parts "drgnx-work-edges")
(declare-function drgnx-work-edges-flush "drgnx-work-edges")

(defvar-local drgnx-work-space--view nil
  "The id of the map view this buffer shows (`drgnx-work-client-open'), or nil for an empty map.")
(defvar-local drgnx-work-space--message nil
  "The text an empty map (no workspace) shows.")
(defvar-local drgnx-work-map--outline nil
  "nil: the outline form when the frame is a terminal's or does not fit; t: always; `off': never.")

(defvar-local drgnx-work-map--selection nil
  "The selected item, (KIND . ID), or nil.  The rows' faces are text properties taken from it when a row is drawn.")
(defvar-local drgnx-work-map--chain nil
  "The chain of the selection, cached: (SELECTION EDGES UP DOWN CHAIN-EDGES), EDGES the frame's edge list it came from.")
(defvar-local drgnx-work-map--edge-selection nil
  "The selection the edge tiles show: it follows `drgnx-work-map--selection' one frame later.")
(defvar-local drgnx-work-map--edge-chain-edges nil
  "The chain edges the band tiles and lanes are drawn with: the edges of `drgnx-work-map--edge-selection''s chain.")
(defvar-local drgnx-work-map--finished nil
  "The id of the item that finished while it was selected; the side panel says so until the selection moves.")
(defvar-local drgnx-work-map--search nil
  "The text `work-search' narrows the map to, or nil: items that do not match are dimmed.")

(defvar-local drgnx-work-map--strip ""
  "The needs-you strip, the buffer's header line: drawn when the frame's strip changes, so redisplay only reads it.")
(defvar-local drgnx-work-map--strip-source nil
  "The (NEEDS-YOU . CHIPS) lists of the frame the strip was made from: a draw makes the strip again when they differ.")
(defvar-local drgnx-work-map--lens ""
  "The lens (Map · Board · Timeline), the buffer's tab line.")
(defvar-local drgnx-work-map--filters nil
  "The filters sent to the hub: a plist (:focus ITEM-ID :overlaps BOOL :finished BOOL).")
(defvar-local drgnx-work-map--collapsed nil "The collapsed layers (1 to 6).")
(defvar-local drgnx-work-map--asked nil
  "Non-nil from a layout the user asked for (`drgnx-work-map--send-filters') until its frame comes: that frame is
drawn at the next timer pass, not a throttle later (live frames keep the view's throttle).")
(defvar-local drgnx-work-map--new nil "The ids with a new conclusion, marked until the highlight timer clears them.")
(defvar-local drgnx-work-map--needs-at 0 "The index of the strip entry `n' selected last.")

(defvar drgnx-work-map-select-functions nil
  "Called with the map buffer after its selection changed (the side panel draws again).")
(defvar drgnx-work-map-edges-functions nil
  "Called with (VIEW-ID SELECTION) one frame after the selection changed: the chain's edge tiles take their colours.")

(defvar drgnx-work-map-scale nil
  "The display scale the rows are drawn at; nil: the frame's.  A test binds it.")

(defvar drgnx-work-lens-map
  (let ((m (make-sparse-keymap))) (set-keymap-parent m special-mode-map) m)
  "Keys every Work view shares: the map, the Board, the Timeline and the trail (the lens, moving, opening).  The
key profiles bind them (`drgnx-command-define' with this map); each view's own keymap has it as its parent.")
(defvar-local drgnx-work-lens--map nil
  "In a Board, Timeline, trail or review buffer: the map buffer it is a view of (the selection lives there).")
(defvar-local drgnx-work-lens-nav nil
  "In a Work view that is not the map: a function of one direction (`left' `right' `up' `down' `next-agent'
`previous-agent' `open' `open-beside') that moves or opens in that view; the shared keys call it.")

(defvar drgnx-work-map-mode-map
  (let ((m (make-sparse-keymap))) (set-keymap-parent m drgnx-work-lens-map) m)
  "Keys of the map buffer.  The key profiles bind them (`drgnx-command-define' with this map).")

(defface drgnx-work-band '((t :height 0.1))
  "The blank lines of the bands between rows: small, so a band is as high as its tile and no higher."
  :group 'drgnx-work-space)

(define-derived-mode drgnx-work-map-mode special-mode "Work map"
  "The Work space's map: layers of asks, specs, plans, agents, branches and files, and the edges between them."
  (setq-local truncate-lines t cursor-type nil
              header-line-format '("" drgnx-work-map--strip) tab-line-format '("" drgnx-work-map--lens)))

(defconst drgnx-work-map--layer-names
  ["You asked" "Specs" "Plans" "Agents" "Branches" "Files"]
  "The six layers' labels, sentence case (the look); the last, \"Files and machines\", is short for the margin.")

(defconst drgnx-work-map--margin 84 "The width, in logical pixels, of the layer labels' margin.")

(defun drgnx-work-map-buffers ()
  "The live map buffers."
  (seq-filter (lambda (b) (eq (buffer-local-value 'major-mode b) 'drgnx-work-map-mode)) (buffer-list)))

(defun drgnx-work-map-buffer (view-id)
  "The map buffer showing view VIEW-ID, or nil."
  (seq-find (lambda (b) (equal (buffer-local-value 'drgnx-work-space--view b) view-id)) (drgnx-work-map-buffers)))

(defun drgnx-work-map--state (&optional buffer)
  "The client state of BUFFER's (default: the current) view, or nil."
  (when-let* ((id (buffer-local-value 'drgnx-work-space--view (or buffer (current-buffer)))))
    (drgnx-work-client-view-state id)))

;;;; Geometry

(defun drgnx-work-map--scale ()
  (or drgnx-work-map-scale (and (fboundp 'frame-scale-factor) (ignore-errors (frame-scale-factor))) 1))

(defun drgnx-work-map--px (units)
  "UNITS (4 logical pixels each) in device pixels."
  (round (* units 4 (drgnx-work-map--scale))))

(defun drgnx-work-map--margin-px () (round (* drgnx-work-map--margin (drgnx-work-map--scale))))

;;;; The rows of a layout

(defvar drgnx-work-map--index (make-hash-table :test #'eq :weakness 'key)
  "Layout (the plist of a state's frame) → (ITEMS . ROWS): ITEMS a hash row key → the ids in that row, left to
right; ROWS a hash row key → the layout's row plist.  Weak on the layout: a new frame has a new layout, and the old
index goes with it.")

(defun drgnx-work-map--row-key (r)
  (list :row (plist-get r :layer) (plist-get r :block_line) (plist-get r :sub)))

(defun drgnx-work-map--index-of (state)
  "STATE's row index (see `drgnx-work-map--index')."
  (let ((layout (drgnx-work-client-layout state)))
    (or (gethash layout drgnx-work-map--index)
        (let ((h (make-hash-table :test #'equal)) (rows (make-hash-table :test #'equal)))
          (dolist (r (plist-get layout :rows)) (puthash (drgnx-work-map--row-key r) r rows))
          (dolist (id (drgnx-work-client-ids state))
            (dolist (key (drgnx-work-client-rows-of state id)) (push id (gethash key h))))
          (maphash (lambda (key ids)
                     (puthash key (sort ids (lambda (a b) (< (plist-get (drgnx-work-client-rect state a) :x)
                                                             (plist-get (drgnx-work-client-rect state b) :x))))
                              h))
                   h)
          (puthash layout (cons h rows) drgnx-work-map--index)))))

(defun drgnx-work-map--layout-keys (state)
  "The row keys of STATE's layout in y order: each band above its row."
  (let* ((layout (drgnx-work-client-layout state))
         (original (plist-get layout :rows))
         (rows (sort (copy-sequence original) (lambda (a b) (< (plist-get a :y) (plist-get b :y)))))
         out)
    (dolist (r rows)
      (let ((i (cl-position r original :test #'eq)))
        (when (seq-find (lambda (b) (eql (plist-get b :row) i)) (plist-get layout :bands))
          (push (cons :band (cdr (drgnx-work-map--row-key r))) out)))
      (push (drgnx-work-map--row-key r) out))
    (nreverse out)))

(defun drgnx-work-map--outline-p (state)
  "Whether STATE is drawn as an outline: asked for, a terminal's, or a layout that does not fit."
  (and state
       (or (eq drgnx-work-map--outline t)
           (and (not (eq drgnx-work-map--outline 'off))
                (or (not (display-graphic-p)) (not (plist-get (drgnx-work-client-layout state) :fits)))))))

(defun drgnx-work-map--outline-ids (state)
  "The agents of STATE the outline shows, in block order (plan rank, then start order), a subagent after its parent."
  (let* ((agents (seq-filter (lambda (id) (equal (plist-get (drgnx-work-client-item state id) :kind) "agent"))
                             (drgnx-work-client-ids state)))
         (plan-rank (lambda (id) (let ((b (plist-get (drgnx-work-client-item state id) :block)))
                                   (if b (or (plist-get (drgnx-work-client-item state b) :order) 0) most-positive-fixnum))))
         (order (lambda (id) (or (plist-get (drgnx-work-client-item state id) :order) 0))))
    (sort agents (lambda (a b) (let ((ra (funcall plan-rank a)) (rb (funcall plan-rank b)))
                                 (if (= ra rb)
                                     (or (< (funcall order a) (funcall order b))
                                         (and (= (funcall order a) (funcall order b)) (string< a b)))
                                   (< ra rb)))))))

(defun drgnx-work-map--keys (state)
  "The keys of the rows STATE is drawn as: the layout's, or the outline's (a notice when it did not fit)."
  (if (drgnx-work-map--outline-p state)
      (append (and (not (plist-get (drgnx-work-client-layout state) :fits)) '((:notice)))
              (or (mapcar (lambda (id) (list :outline id)) (drgnx-work-map--outline-ids state)) '((:outline-none))))
    (drgnx-work-map--layout-keys state)))

;;;; The selection's look

(declare-function drgnx-work-nav-chain "drgnx-work-detail")
(declare-function drgnx-work-nav-move "drgnx-work-detail")
(declare-function drgnx-work-nav-agent "drgnx-work-detail")
(declare-function drgnx-work-nav-sel "drgnx-work-detail")
(declare-function drgnx-work-nav-resolve "drgnx-work-detail")
(declare-function drgnx-work-detail-update "drgnx-work-detail")

(defun drgnx-work-map--chain-of (state)
  "The cached chain (UP DOWN EDGES) of the selection in STATE, made again when the selection or the edges changed."
  (let ((edges (drgnx-work-client-edges state)))
    (unless (and drgnx-work-map--chain (equal (car drgnx-work-map--chain) drgnx-work-map--selection)
                 (eq (cadr drgnx-work-map--chain) edges))
      (setq drgnx-work-map--chain (cons drgnx-work-map--selection (cons edges (drgnx-work-nav-chain state drgnx-work-map--selection)))))
    (cddr drgnx-work-map--chain)))

(defun drgnx-work-map--matches-p (state id)
  "Whether item ID's label contains the search text."
  (string-match-p (regexp-quote drgnx-work-map--search)
                  (concat (or (plist-get (drgnx-work-client-item state id) :label) "") " "
                          (or (drgnx-work-map--field (drgnx-work-client-item state id) :task) ""))))

(defun drgnx-work-map--class (state id)
  "The face class of item ID: `drgnx-work-selected' for the selection, `drgnx-work-dim' for what the chain or the search
leaves out, nil for the rest.  Read from the cached selection when a row is drawn."
  (let ((sel drgnx-work-map--selection) (search (and drgnx-work-map--search (not (string-empty-p drgnx-work-map--search)))))
    (cond ((and sel (equal (cdr sel) id)) 'drgnx-work-selected)
          (search (unless (drgnx-work-map--matches-p state id) 'drgnx-work-dim))
          (sel (pcase-let ((`(,up ,down ,_) (drgnx-work-map--chain-of state)))
                 (unless (or (member id up) (member id down)) 'drgnx-work-dim))))))

(defun drgnx-work-map--classes (state)
  "Hash id → class of every item of STATE."
  (let ((h (make-hash-table :test #'equal)))
    (dolist (id (drgnx-work-client-ids state)) (puthash id (drgnx-work-map--class state id) h))
    h))

(defun drgnx-work-map--visible-keys (keys)
  "Of the row KEYS those a window shows (all of them when no window does)."
  (let ((windows (get-buffer-window-list (current-buffer) nil t)))
    (if (null windows)
        keys
      (seq-filter (lambda (k)
                    (when-let* ((p (drgnx-view-row-start drgnx-view k)))
                      (seq-some (lambda (w) (and (>= p (window-start w)) (<= p (window-end w t)))) windows)))
                  keys))))

(defun drgnx-work-map--restyle (state before)
  "Draw again the rows whose items changed class since BEFORE (a hash id → class): the visible ones in this command's
own redisplay, the rest by the view's own draw."
  (let ((keys nil))
    (dolist (id (drgnx-work-client-ids state))
      (unless (eq (gethash id before) (drgnx-work-map--class state id))
        (setq keys (append (drgnx-work-client-rows-of state id) keys))))
    (when (and keys (drgnx-view-p drgnx-view) (not (drgnx-work-map--outline-p state)))
      (setq keys (delete-dups keys))
      (drgnx-view-dirty drgnx-view keys)
      (drgnx-view-draw-now drgnx-view (drgnx-work-map--visible-keys keys)))))

(defun drgnx-work-map--edges-later (buffer)
  "The timer function one frame after a selection: the edge tiles take the chain's colours."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq drgnx-work-map--edge-selection drgnx-work-map--selection)
      (run-hook-with-args 'drgnx-work-map-edges-functions drgnx-work-space--view drgnx-work-map--selection))))

(defun drgnx-work-map--edge-keys-of (edges)
  (mapcar #'drgnx-work-edges-key edges))

(defun drgnx-work-map--rows-of-edges (state keys)
  "The row keys whose bands or lanes draw an edge named in KEYS (edge keys), and the layout's rows indexes of its bands:
((ROW-KEY …) . (BAND-INDEX …))."
  (let* ((layout (drgnx-work-client-layout state)) (rows (plist-get layout :rows)) out bands)
    (dolist (b (plist-get layout :bands))
      (when (seq-some (lambda (s) (member (drgnx-work-edges-key s) keys)) (plist-get b :segs))
        (push (cons :band (cdr (drgnx-work-map--row-key (nth (plist-get b :row) rows)))) out)
        (push (plist-get b :row) bands)))
    (dolist (l (plist-get layout :lanes))
      (when (member (drgnx-work-edges-key l) keys)
        (push (drgnx-work-map--row-key (nth (plist-get l :row) rows)) out)))
    (cons (delete-dups out) bands)))

(defun drgnx-work-map--edges-update (view-id selection)
  "`drgnx-work-map-edges-functions': the tiles and lanes of the edges that joined or left the chain of SELECTION take
their colours, and the rows that hold them are drawn again; the images they replace are flushed.  The tiles no edge
of which changed are the very images they were."
  (when-let* ((buffer (drgnx-work-map-buffer view-id)))
    (with-current-buffer buffer
      (let ((state (drgnx-work-map--state)))
        (when (and state (drgnx-view-p drgnx-view) (not (drgnx-work-map--outline-p state)))
          (let* ((old drgnx-work-map--edge-chain-edges)
                 (new (and selection (nth 2 (drgnx-work-nav-chain state selection))))
                 (old-keys (drgnx-work-map--edge-keys-of old)) (new-keys (drgnx-work-map--edge-keys-of new))
                 (changed (append (seq-remove (lambda (k) (member k new-keys)) old-keys)
                                  (seq-remove (lambda (k) (member k old-keys)) new-keys)))
                 (found (drgnx-work-map--rows-of-edges state changed))
                 (colours (drgnx-work-edges-colours))
                 (before (drgnx-work-map--edge-geometry state old)) (after (drgnx-work-map--edge-geometry state new)))
            (dolist (i (cdr found))
              (when-let* ((band (drgnx-work-map--band-of state i)))
                (cl-mapc #'drgnx-work-edges-flush
                         (drgnx-work-edges-band-tiles band before colours)
                         (drgnx-work-edges-band-tiles band after colours))))
            (setq drgnx-work-map--edge-chain-edges new)
            (when (car found)
              (drgnx-view-dirty drgnx-view (car found))
              (drgnx-view-draw-now drgnx-view (drgnx-work-map--visible-keys (car found))))))))))

(defun drgnx-work-map-theme-changed ()
  "Draw every map again: the edge tiles hold colours the faces had."
  (dolist (b (drgnx-work-map-buffers))
    (with-current-buffer b
      (when (and (drgnx-view-p drgnx-view) (drgnx-work-map--state)) (drgnx-view-touch drgnx-view)))))

(defun drgnx-work-map--place-point (sel)
  "Point, and the point of every window showing the buffer, on SEL's card (or its outline block)."
  (let ((pos (or (text-property-any (point-min) (point-max) 'drgnx-work-id (cdr sel))
                 (and (drgnx-view-p drgnx-view) (drgnx-view-row-start drgnx-view (list :outline (cdr sel)))))))
    (when pos
      (goto-char pos)
      (dolist (w (get-buffer-window-list (current-buffer) nil t)) (set-window-point w pos)))))

(defun drgnx-work-map-select (sel)
  "Select SEL, (KIND . ID), in the current map, or nothing with nil.  The rows whose items change class (selected,
on the chain, dimmed) are drawn again, the visible ones in this command's own redisplay; point goes to the card;
the side panel follows; the chain's edge tiles one frame later (the timer takes the last selection of a held key)."
  (let ((state (drgnx-work-map--state)))
    (when (and state (not (equal sel drgnx-work-map--selection)))
      (let ((before (drgnx-work-map--classes state)))
        (setq drgnx-work-map--selection sel drgnx-work-map--finished nil)
        (drgnx-work-map--restyle state before)
        (when sel (drgnx-work-map--place-point sel))
        (run-hook-with-args 'drgnx-work-map-select-functions (current-buffer))
        (when drgnx-work-space--view
          (drgnx-timer-soon (cons 'work-edges drgnx-work-space--view) 0.016 #'drgnx-work-map--edges-later
                            :args (list (current-buffer)) :owner (current-buffer)))))))

;;;; Moving the selection

(defun drgnx-work-map--require-state ()
  (or (drgnx-work-map--state) (user-error "This map has nothing to select")))

(defun drgnx-work-map--first ()
  "The first thing to select in a map with no selection: its first agent, else its first ask."
  (let ((state (drgnx-work-map--state)))
    (or (drgnx-work-nav-agent state nil t)
        (when-let* ((id (car (sort (copy-sequence (drgnx-work-client-ids state)) #'string<))))
          (drgnx-work-nav-sel state id)))))

(defun drgnx-work-map--move (dir)
  "Move the selection in DIR; in a Work view that is not the map, that view's own move."
  (if drgnx-work-lens-nav
      (funcall drgnx-work-lens-nav dir)
    (let ((state (drgnx-work-map--require-state)))
      (drgnx-work-map-select (if drgnx-work-map--selection
                                 (drgnx-work-nav-move state drgnx-work-map--selection dir)
                               (drgnx-work-map--first))))))

(defun drgnx-work-map-left () "Select the previous item of this layer." (interactive) (drgnx-work-map--move 'left))
(defun drgnx-work-map-right () "Select the next item of this layer." (interactive) (drgnx-work-map--move 'right))
(defun drgnx-work-map-why () "Select what the selection came from." (interactive) (drgnx-work-map--move 'up))
(defun drgnx-work-map-touches () "Select what the selection touches." (interactive) (drgnx-work-map--move 'down))

(defun drgnx-work-map-next-agent ()
  "Select the next agent, in team order."
  (interactive)
  (if drgnx-work-lens-nav
      (funcall drgnx-work-lens-nav 'next-agent)
    (let ((state (drgnx-work-map--require-state)))
      (drgnx-work-map-select (drgnx-work-nav-agent state drgnx-work-map--selection t)))))

(defun drgnx-work-map-previous-agent ()
  "Select the previous agent, in team order."
  (interactive)
  (if drgnx-work-lens-nav
      (funcall drgnx-work-lens-nav 'previous-agent)
    (let ((state (drgnx-work-map--require-state)))
      (drgnx-work-map-select (drgnx-work-nav-agent state drgnx-work-map--selection nil)))))

;;;; Opening the selection

(defvar drgnx-agents--sessions)
(declare-function drgnx-agents-ui-transcript "drgnx-agents-ui")
(declare-function drgnx-agent-session-remote "drgnx-agents")

(declare-function drgnx-work-code-open-file "drgnx-work-code")
(declare-function drgnx-work-code-local-file "drgnx-work-code")
(declare-function drgnx-work-code--roots "drgnx-work-code")

(defun drgnx-work--open-agent (sid)
  "Open the transcript of the hub session SID in today's Agents view (the agent panel replaces this later)."
  (if-let* ((s (and (boundp 'drgnx-agents--sessions)
                    (seq-find (lambda (x) (equal (drgnx-agent-session-remote x) sid)) drgnx-agents--sessions))))
      (progn (require 'drgnx-agents-ui) (drgnx-agents-ui-transcript s))
    (message "Work: no transcript of this agent here")))

(defun drgnx-work-map--root-named (name)
  "The workspace root whose directory is called NAME, or nil."
  (let ((roots (plist-get (drgnx-work-client--view-params (drgnx-work-client--get drgnx-work-space--view)) :workspace)))
    (seq-find (lambda (r) (equal (file-name-nondirectory (directory-file-name r)) name)) (plist-get roots :roots))))

(defun drgnx-work-map--open-item (state sel beside)
  "Open the item SEL of STATE as the design's table says; BESIDE: without moving focus."
  (let* ((id (cdr sel)) (key (cadr (split-string id ":")))
         (show (lambda (buffer) (if beside (display-buffer buffer) (pop-to-buffer buffer)))))
    (pcase (car sel)
      ('agent (drgnx-work--open-agent (substring id (length "agent:"))))
      ('subagent (drgnx-work--open-agent (car (split-string (substring id (length "agent:")) "/"))))
      ('branch (let* ((parts (split-string key "/")) (root (drgnx-work-map--root-named (car parts))))
                 (cond ((null root) (message "Work: %s is not in this workspace" (car parts)))
                       ((fboundp 'magit-status) (funcall #'magit-status root))
                       (t (funcall show (dired-noselect root))))))
      ('file (drgnx-work-code-open-file state sel :beside beside))
      ('machine (drgnx-work-space--show-detail (current-buffer))
                (message "Work: %s — its queue is in the side panel" (plist-get (drgnx-work-client-item state id) :label)))
      ;; a document's key is the hub's: only a plain local file inside a root of the workspace opens, by its true name
      (_ (let ((path (seq-some (lambda (root) (drgnx-work-code-local-file key (list root)))
                               (if-let* ((v (drgnx-work-client--get drgnx-work-space--view)))
                                   (plist-get (plist-get (drgnx-work-client--view-params v) :workspace) :roots)
                                 (drgnx-work-code--roots)))))
           (if path (funcall show (find-file-noselect path))
             (message "Work: no document is recorded for %s" (plist-get (drgnx-work-client-item state id) :label))))))))

(defun drgnx-work-map-open-selection (&optional beside)
  "Open the selected item: an agent's transcript, a branch's repository, a file, a document.  BESIDE (a prefix
argument): without moving focus."
  (interactive "P")
  (if drgnx-work-lens-nav
      (funcall drgnx-work-lens-nav (if beside 'open-beside 'open))
    (let ((state (drgnx-work-map--require-state)))
      (unless drgnx-work-map--selection (user-error "Nothing is selected"))
      (drgnx-work-map--open-item state drgnx-work-map--selection beside))))

(defun drgnx-work-map-open-beside ()
  "Open the selected item beside the map, without moving focus."
  (interactive)
  (if drgnx-work-lens-nav
      (funcall drgnx-work-lens-nav 'open-beside)
    (drgnx-work-map-open-selection t)))

;;;; Card text

(defun drgnx-work-map--field (item key) (plist-get (plist-get item :fields) key))

(defun drgnx-work-map--state-word (s)
  (pcase s ("needs-you" "needs you") ((pred stringp) s) (_ "")))

(defun drgnx-work-map--dot (item)
  "The state dot of ITEM, in the face of its state; a runner's follows its own state (`drgnx-runners-*' faces)."
  (if-let* ((r (drgnx-work-map--field item :runner)))
      (propertize (drgnx-face-glyph 'dot) 'face
                  (drgnx-runners-view-dot-face (or (plist-get r :state) "") (plist-get r :jobs)))
    (propertize "●" 'face (pcase (drgnx-work-map--field item :state)
                            ("running" 'drgnx-work-chain)
                            ("needs-you" 'drgnx-work-needs-you)
                            ((or "review" "stalled") 'drgnx-work-overlap)
                            (_ 'drgnx-work-dim)))))

(defun drgnx-work-map--job-chip (job &optional now)
  "The agent card's chip for its JOB (a plist as the hub sends it): \"job · NAME · M:SS/Nm\" at NOW (seconds since the
epoch; default the present), or \"job · NAME · waiting\" while it has no machine."
  (if (or (equal (plist-get job :state) "waiting") (not (numberp (plist-get job :started))))
      (format "job · %s · waiting" (plist-get job :name))
    (format "job · %s · %s" (or (plist-get job :runner) (plist-get job :name)) (drgnx-work-map--job-time job now))))

(defun drgnx-work-map--job-time (job &optional now)
  "JOB's elapsed time against its time box, \"M:SS/Nm\", at NOW (seconds since the epoch; default the present)."
  (let ((secs (max 0 (truncate (- (or now (float-time)) (plist-get job :started))))) (limit (plist-get job :limit_min)))
    (format "%d:%02d%s" (/ secs 60) (% secs 60) (if limit (format "/%dm" limit) ""))))

(defun drgnx-work-map--badge (item)
  "The agent badge: the model's initial in the agent's colour."
  (let ((model (or (drgnx-work-map--field item :model) "")))
    (propertize (if (string-empty-p model) "?" (upcase (substring model 0 1)))
                'face (intern (format "drgnx-work-agent-%d" (1+ (mod (1- (or (plist-get item :order) 1)) 6)))))))

(defun drgnx-work-map--partner (state id)
  "The item an overlap edge joins ID to, as \"model · name\", or nil."
  (when-let* ((e (seq-find (lambda (e) (and (equal (plist-get e :kind) "overlap")
                                            (or (equal (plist-get e :from) id) (equal (plist-get e :to) id))))
                           (drgnx-work-client-edges state)))
              (other (if (equal (plist-get e :from) id) (plist-get e :to) (plist-get e :from)))
              (it (drgnx-work-client-item state other)))
    (if-let* ((m (drgnx-work-map--field it :model))) (format "%s · %s" m (plist-get it :label)) (plist-get it :label))))

(defun drgnx-work-map--new-chip (id)
  "The `new' chip of an item with a new conclusion (see `drgnx-work-map--new'), else nothing."
  (if (member id drgnx-work-map--new) (propertize " new " 'face 'drgnx-work-new) ""))

(defun drgnx-work-map--rich-lines (state id)
  "The five lines of the rich agent card ID: who, its task, how it is going, its latest conclusion, the flag."
  (let* ((it (drgnx-work-client-item state id)) (f (lambda (k) (drgnx-work-map--field it k)))
         (model (funcall f :model)) (edits (funcall f :edits)) (progress (funcall f :progress))
         (ctx (funcall f :context)) (partner (drgnx-work-map--partner state id)))
    (list (concat (drgnx-work-map--dot it) " " (drgnx-work-map--badge it) "  "
                  (if model (concat model " · ") "") (plist-get it :label) (drgnx-work-map--new-chip id))
          (or (funcall f :task) "")
          (mapconcat #'identity
                     (delq nil (list (or (funcall f :activity) (drgnx-work-map--state-word (funcall f :state)))
                                     (and (funcall f :minutes) (format "%d min" (funcall f :minutes)))
                                     (funcall f :spend)
                                     (and progress (format "%d/%d" (car progress) (cadr progress)))
                                     (and ctx (> ctx 80) (format "ctx %d %%" ctx))
                                     (and (funcall f :job) (drgnx-work-map--job-chip (funcall f :job)))))
                     " · ")
          (if-let* ((c (funcall f :conclusion))) (concat "→ " c) "")
          (cond ((plist-get it :warn)
                 (propertize (if partner (format "⚠ shares files with %s" partner) "⚠ overlap")
                             'face 'drgnx-work-overlap))
                (t (mapconcat #'identity
                              (delq nil (list (and (funcall f :reads) (format "reads %d" (funcall f :reads)))
                                              (and edits (format "edits %d (+%d −%d)" (nth 0 edits) (nth 1 edits)
                                                                 (nth 2 edits)))))
                              " · "))))))

(defun drgnx-work-map--compact-lines (item)
  "The two lines of a compact agent card: who, and how it is going (with the overlap mark)."
  (let* ((f (lambda (k) (drgnx-work-map--field item k))) (model (funcall f :model)))
    (list (concat (drgnx-work-map--dot item) " " (drgnx-work-map--badge item) " "
                  (if (and model (equal (plist-get item :kind) "agent")) (concat model " · ") "") (plist-get item :label)
                  (drgnx-work-map--new-chip (plist-get item :id)))
          (concat (mapconcat #'identity
                             (delq nil (list (or (funcall f :activity) (drgnx-work-map--state-word (funcall f :state)))
                                             (and (funcall f :minutes) (format "%dm" (funcall f :minutes)))
                                             (and (funcall f :job) (drgnx-work-map--job-chip (funcall f :job)))))
                             " ")
                  (if (plist-get item :warn) (propertize " ⚠" 'face 'drgnx-work-overlap) "")))))

(defun drgnx-work-map--chip-line (item)
  "The one line of a chip item: ask, spec, plan, branch, file or machine."
  (let* ((kind (plist-get item :kind)) (label (plist-get item :label)) (f (lambda (k) (drgnx-work-map--field item k)))
         (runner (and (equal kind "machine") (funcall f :runner)))
         (glyph (if runner
                    (concat (drgnx-work-map--dot item) " "
                            (drgnx-face-glyph (intern (or (plist-get runner :icon) "server"))))
                  (pcase kind ("ask" "❝") ("spec" "◫") ("plan" "☰") ("branch" "⑂") ("file" "▭") ("machine" "▣") (_ "·"))))
         (extra (pcase kind
                  ("plan" (when-let* ((p (funcall f :progress))) (format "%d/%d" (car p) (cadr p))))
                  ("branch" (let ((bits (delq nil (list (when-let* ((e (funcall f :edits))) (format "edits %d" (car e)))
                                                        ;; only what the hub sent: the merge queue is its fact
                                                        (when-let* ((q (funcall f :queue))) (format "queue %d/%d" (car q) (cadr q)))
                                                        (when-let* ((c (funcall f :conflicts)))
                                                          (format "conflicts with %s" (string-join c ", ")))))))
                              (and bits (string-join bits " · "))))
                  ("file" (when-let* ((c (funcall f :change))) (format "+%d −%d" (car c) (cadr c))))
                  ("machine" (let ((bits (delq nil (list (when-let* ((s (funcall f :slots))) (format "%d/%d" (car s) (cadr s)))
                                                         (when-let* ((c (plist-get runner :cost))) (and (stringp c) c))))))
                               (and bits (string-join bits " · ")))))))
    (concat (if (plist-get item :needs_you) (propertize "⚑ " 'face 'drgnx-work-needs-you) "")
            glyph " " label (if extra (concat " · " extra) "")
            (if (plist-get item :warn) (propertize " ⚠" 'face 'drgnx-work-overlap) ""))))

(defun drgnx-work-map--card-lines (state id)
  "The text lines of item ID's card, by its form: five (rich agent), two (compact agent or subagent) or one (chip)."
  (let* ((item (drgnx-work-client-item state id)) (kind (plist-get item :kind)))
    (cond ((member kind '("agent" "subagent"))
           (if (and (equal kind "agent") (equal (drgnx-work-client-form state id) "rich"))
               (drgnx-work-map--rich-lines state id)
             (drgnx-work-map--compact-lines item)))
          (t (list (drgnx-work-map--chip-line item))))))

(defun drgnx-work-map--card-face (n i)
  "The decoration face of line I of a card of N lines."
  (cond ((= n 1) (if (facep 'drgnx-card-single) 'drgnx-card-single 'drgnx-work-chip))
        ((= i 0) 'drgnx-card-top) ((= i (1- n)) 'drgnx-card-bottom) (t 'drgnx-card-mid)))

;;;; Row text

(defun drgnx-work-map--row-lines (row)
  "How many text lines the layout row ROW holds: five for a rich agent row, two for a compact one, else one."
  (cond ((not (eql 4 (plist-get row :layer))) 1)
        ((>= (plist-get row :height_units) 20) 5)
        (t 2)))

(defun drgnx-work-map--layer-label (state key row)
  "The label for KEY's first line: the layer's name on its first row, a collapsed layer's with its count."
  (let* ((layer (nth 1 key)) (name (aref drgnx-work-map--layer-names (1- layer)))
         (first (equal key (seq-find (lambda (k) (and (eq (car k) :row) (eql (nth 1 k) layer)))
                                     (drgnx-work-map--layout-keys state)))))
    (cond ((plist-get row :collapsed)
           (format "%s · %d" name (cl-count-if (lambda (id) (eq (drgnx-work-client-kind-layer
                                                                 (plist-get (drgnx-work-client-item state id) :kind))
                                                                layer))
                                               (drgnx-work-client-ids state))))
          (first name)
          (t ""))))

(defun drgnx-work-map--segment (state id i)
  "Line I of item ID's card, placed at its x, or the empty string when its card has fewer lines."
  (let* ((rect (drgnx-work-client-rect state id)) (lines (drgnx-work-map--card-lines state id)) (n (length lines)))
    (if (or (null rect) (>= i n))
        ""
      (let* ((left (+ (drgnx-work-map--margin-px) (drgnx-work-map--px (plist-get rect :x))))
             (right (+ (drgnx-work-map--margin-px) (drgnx-work-map--px (+ (plist-get rect :x) (plist-get rect :w)))))
             (face (drgnx-work-map--card-face n i)) (class (drgnx-work-map--class state id))
             (text (copy-sequence (drgnx-view-fit (nth i lines) (- right left 10)))))
        ;; the box face under the text's own faces; the selection's class over both: text properties, not overlays,
        ;; so a row drawn again has them
        (add-face-text-property 0 (length text) face t text)
        (when class (add-face-text-property 0 (length text) class nil text))
        (add-text-properties 0 (length text) (list 'drgnx-work-id id) text)
        (concat (propertize " " 'display `(space :align-to (,left)))
                text
                (propertize " " 'display `(space :align-to (,right)) 'face (if class (list class face) face)
                            'drgnx-work-id id))))))

(defun drgnx-work-map--edge-geometry (state &optional chain-edges)
  "The geometry the edge tiles and lanes of STATE are made from, with the chain CHAIN-EDGES (default: the shown one)."
  (drgnx-work-edges-geometry state (or chain-edges drgnx-work-map--edge-chain-edges) (drgnx-work-map--scale)
                             (drgnx-work-map--margin-px)))

(defun drgnx-work-map--band-of (state row-index)
  "The band above the layout's row ROW-INDEX with the port chips that belong in it, or nil: a plist :row
:height_units :segs :ports."
  (let* ((layout (drgnx-work-client-layout state)) (rows (plist-get layout :rows))
         (band (seq-find (lambda (b) (eql (plist-get b :row) row-index)) (plist-get layout :bands)))
         (ports (delq nil
                      (mapcar (lambda (p)
                                (let ((rect (drgnx-work-client-rect state (plist-get p :target)))
                                      (rk (car (drgnx-work-client-rows-of state (plist-get p :target)))))
                                  (when (and rect rk (eql row-index (cl-position rk rows :test
                                                                                 (lambda (k r) (equal k (drgnx-work-map--row-key r))))))
                                    (cons (+ (plist-get rect :x) (/ (plist-get rect :w) 2)) (length (plist-get p :parents))))))
                              (plist-get layout :ports)))))
    (and band (append band (list :ports ports)))))

(defun drgnx-work-map-row-text (state key)
  "The text of row KEY of STATE's layout: a band (its edge tiles, else blank, as high as its tile), or the lines of a
row's cards with the lanes that pass through them."
  (let* ((index (drgnx-work-map--index-of state)) (row-key (cons :row (cdr key)))
         (row (gethash row-key (cdr index))) (layout (drgnx-work-client-layout state))
         (i (cl-position row (plist-get layout :rows) :test #'eq)))
    (if (eq (car key) :band)
        (let* ((band (drgnx-work-map--band-of state i))
               (px (drgnx-work-map--px (or (plist-get band :height_units) 1)))
               (tiles (and band (drgnx-work-edges-band-text band (drgnx-work-map--edge-geometry state)
                                                            (drgnx-work-edges-colours)))))
          (if tiles
              (concat tiles (propertize "\n" 'face 'drgnx-work-band 'line-height t))
            (concat (propertize " " 'face 'drgnx-work-band)
                    (propertize "\n" 'face 'drgnx-work-band 'line-height (list (max 0 (1- px)))))))
      (let* ((ids (gethash row-key (car index))) (n (drgnx-work-map--row-lines row))
             (px (/ (drgnx-work-map--px (plist-get row :height_units)) n))
             (label (drgnx-work-map--layer-label state key row)) lines
             (lanes (and i (seq-some (lambda (l) (eql (plist-get l :row) i)) (plist-get layout :lanes))
                         (drgnx-work-edges-lane-parts i (plist-get layout :lanes) (drgnx-work-map--edge-geometry state)
                                                      (drgnx-work-edges-colours)))))
        (dotimes (line n)
          (push (concat (if (and (= line 0) (not (string-empty-p label)))
                            (propertize (drgnx-view-fit label (- (drgnx-work-map--margin-px) 8)) 'face 'drgnx-work-label)
                          "")
                        (if lanes
                            ;; the cards and the lanes in order of their columns; a sort that copies: an in-place
                            ;; one rewrites the conses `append' shares with LANES, and the next line gets this
                            ;; line's cards with its lanes
                            (mapconcat #'cdr
                                       (sort (append (mapcar (lambda (id)
                                                               (cons (+ (drgnx-work-map--margin-px)
                                                                        (drgnx-work-map--px (plist-get (drgnx-work-client-rect state id) :x)))
                                                                     (drgnx-work-map--segment state id line)))
                                                             ids)
                                                     lanes)
                                             :key #'car)
                                       "")
                          (mapconcat (lambda (id) (drgnx-work-map--segment state id line)) ids ""))
                        (propertize "\n" 'line-height (list (max 0 (1- px)))))
                lines))
        (apply #'concat (nreverse lines))))))

;;;; The outline form

(defun drgnx-work-map--parent (state id)
  "The item ID came from (the first came-from edge into it, by id), or nil."
  (let ((from (delq nil (mapcar (lambda (e) (and (equal (plist-get e :kind) "came-from") (equal (plist-get e :to) id)
                                                 (plist-get e :from)))
                                (drgnx-work-client-edges state)))))
    (car (sort from #'string<))))

(defun drgnx-work-map--why (state id)
  "ID's why-chain as text: you: \"ask\" › spec › plan › task."
  (let ((chain nil) (cur (drgnx-work-map--parent state id)) (guard 0))
    (while (and cur (< (cl-incf guard) 8))
      (let ((it (drgnx-work-client-item state cur)))
        (push (if (equal (plist-get it :kind) "ask") (format "you: \"%s\"" (plist-get it :label)) (plist-get it :label))
              chain))
      (setq cur (drgnx-work-map--parent state cur)))
    (let ((task (drgnx-work-map--field (drgnx-work-client-item state id) :task)))
      (mapconcat #'identity (append chain (and task (list task))) " › "))))

(defun drgnx-work-map--touches (state id)
  "ID's touches as text: its branch, machine, edits and reads."
  (let* ((item (drgnx-work-client-item state id)) (out nil))
    (dolist (e (drgnx-work-client-edges state))
      (when (equal (plist-get e :from) id)
        (let ((to (drgnx-work-client-item state (plist-get e :to))))
          (pcase (plist-get e :kind)
            ("came-from" (when (equal (plist-get to :kind) "branch") (push (plist-get to :label) out)))
            ("runs-on" (push (format "%s slot" (plist-get to :label)) out))))))
    (when-let* ((edits (drgnx-work-map--field item :edits)))
      (push (format "edits %d (+%d −%d)" (nth 0 edits) (nth 1 edits) (nth 2 edits)) out))
    (when-let* ((r (drgnx-work-map--field item :reads))) (push (format "reads %d" r) out))
    (mapconcat #'identity (nreverse out) " · ")))

(defun drgnx-work-map--outline-block (state id columns)
  "The outline block of agent ID: its line, why, touches and conclusion, each at most COLUMNS wide, ending in a newline."
  (let* ((item (drgnx-work-client-item state id)) (f (lambda (k) (drgnx-work-map--field item k)))
         (model (funcall f :model)) (progress (funcall f :progress))
         (head (concat (drgnx-work-map--dot item) " " (if model (concat model " · ") "") (plist-get item :label) "  "
                       (mapconcat #'identity
                                  (delq nil (list (or (funcall f :activity) (drgnx-work-map--state-word (funcall f :state)))
                                                  (and (funcall f :minutes) (format "%dm" (funcall f :minutes)))
                                                  (funcall f :spend)
                                                  (and progress (format "%d/%d" (car progress) (cadr progress)))))
                                  " ")))
         (partner (and (plist-get item :warn) (drgnx-work-map--partner state id)))
         (flag (and (plist-get item :warn) (propertize (if partner (format "⚠ shares files with %s" partner) "⚠ overlap")
                                                       'face 'drgnx-work-overlap)))
         (first (if (and flag (<= (+ (string-width head) 2 (string-width flag)) columns))
                    (concat head (make-string (- columns (string-width head) (string-width flag)) ?\s) flag)
                  (truncate-string-to-width head columns nil nil "…")))
         (lines (list first
                      (format "   why:      %s" (drgnx-work-map--why state id))
                      (format "   touches:  %s" (drgnx-work-map--touches state id)))))
    (when-let* ((c (funcall f :conclusion))) (setq lines (append lines (list (concat "   → " c)))))
    (concat (mapconcat (lambda (l) (truncate-string-to-width l columns nil nil "…")) lines "\n") "\n")))

(defun drgnx-work-map-outline (state &optional columns)
  "STATE as an outline, at most COLUMNS (default 80) wide: one block per agent, in plan order, each with why, touches
and its latest conclusion.  The form of terminals, of a map that does not fit and of `O'."
  (let ((columns (or columns 80)) (ids (drgnx-work-map--outline-ids state)))
    (if (null ids)
        "No agents are working.\n"
      (mapconcat (lambda (id) (drgnx-work-map--outline-block state id columns)) ids "\n"))))

;;;; The view type

(defun drgnx-work-map--columns ()
  (if-let* ((w (car (get-buffer-window-list (current-buffer) nil t)))) (max 40 (window-body-width w)) 80))

(defun drgnx-work-map--render (key)
  "The text of row KEY in the current buffer's map."
  (let ((state (drgnx-work-map--state)))
    (cond
     ((equal key '(:empty)) (concat (or drgnx-work-space--message "") "\n"))
     ((null state) "\n")
     ((equal key '(:notice)) (concat "Too many to draw at this width · O back to the map, at a wider tile\n"))
     ((equal key '(:outline-none)) (drgnx-work-map-outline state))
     ((eq (car key) :outline) (drgnx-work-map--outline-block state (cadr key) (drgnx-work-map--columns)))
     (t (drgnx-work-map-row-text state key)))))

(defun drgnx-work-map--sig (key)
  "KEY's signature for `drgnx-view-sync-rows': the rows' items and rectangles themselves (`eq' tells a change)."
  (let ((state (drgnx-work-map--state)))
    (cond ((null state) key)
          ((eq (car key) :row)
           (vconcat (list (plist-get (drgnx-work-client-layout state) :rows))
                    (mapcar (lambda (id) (drgnx-work-client-item state id))
                            (gethash key (car (drgnx-work-map--index-of state))))))
          ((eq (car key) :outline) (vector (drgnx-work-client-items state) (drgnx-work-client-edges state)))
          (t key))))

(defun drgnx-work-map--sync (_view)
  "The view type's SYNC: the rows are the frame's."
  (let ((state (drgnx-work-map--state)))
    ;; a map attached to a frame it already holds has had no event to make its strip from
    (when (and state (not (and drgnx-work-map--strip-source
                               (eq (car drgnx-work-map--strip-source) (drgnx-work-client-needs-you state))
                               (eq (cdr drgnx-work-map--strip-source) (drgnx-work-client-chips state)))))
      (drgnx-work-map--refresh-strip))
    (drgnx-view-sync-rows drgnx-view (if state (drgnx-work-map--keys state) '((:empty))) #'drgnx-work-map--sig)))

(drgnx-view-define 'work-map :render #'drgnx-work-map--render :sync #'drgnx-work-map--sync
                   :slice drgnx-view-slice)

(defun drgnx-work-map-toggle-outline ()
  "Show the outline form instead of the map, or the map again (a terminal's frame always shows the outline)."
  (interactive)
  (setq drgnx-work-map--outline (if (eq drgnx-work-map--outline t) 'off t))
  (drgnx-view-touch drgnx-view))

;;;; The strip and the lens: header line and tab line, strings drawn when the frame changes

(defun drgnx-work-map--needs-you (state)
  "The strip's entries in STATE, ((TEXT . ITEM-IDS) …): the cards, then the agents that need you with no card."
  (let* ((cards (mapcar (lambda (c) (cons (plist-get c :text) (plist-get c :about))) (drgnx-work-client-needs-you state)))
         (covered (apply #'append (mapcar #'cdr cards)))
         (agents (seq-filter (lambda (id) (let ((it (drgnx-work-client-item state id)))
                                            (and (equal (plist-get it :kind) "agent")
                                                 (equal (drgnx-work-map--field it :state) "needs-you")
                                                 (not (member id covered)))))
                             (drgnx-work-client-ids state))))
    (append cards (mapcar (lambda (id) (cons (format "%s needs you" (plist-get (drgnx-work-client-item state id) :label))
                                             (list id)))
                          (sort agents #'string<)))))

(defun drgnx-work-map--strip-string (state)
  "The needs-you strip of STATE: a chip with its jump key for each of the first nine entries, +N for the rest, and the
mission chips (the machines' load) at the right."
  (let* ((entries (drgnx-work-map--needs-you state)) (i 0))
    (concat (mapconcat (lambda (e) (cl-incf i) (propertize (format " ⚑ %s  g%d " (car e) i) 'face 'drgnx-work-needs-you))
                       (seq-take entries 9) " ")
            (if (> (length entries) 9) (propertize (format " +%d " (- (length entries) 9)) 'face 'drgnx-work-needs-you) "")
            (propertize " " 'display '(space :align-to right))
            (mapconcat (lambda (c) (propertize (format " %s %d/%d%s " (plist-get c :label) (or (plist-get c :used) 0)
                                                       (or (plist-get c :total) 0)
                                                       (if (stringp (plist-get c :cost)) (format " · cloud %s" (plist-get c :cost)) ""))
                                               'face 'drgnx-work-chip))
                       (drgnx-work-client-chips state) " "))))

(defun drgnx-work-lens-string (&optional current)
  "The lens: Map · Board · Timeline, CURRENT (`map', `board' or `timeline'; default `map') in bold, the others in the
label face (`m' `b' `t' switch)."
  (let ((current (or current 'map)))
    (mapconcat (lambda (v)
                 (propertize (format " %s " (cdr v)) 'face (if (eq (car v) current) 'bold 'drgnx-work-label)))
               '((map . "Map") (board . "Board") (timeline . "Timeline")) "·")))

(defun drgnx-work-map--lens-string ()
  "The lens of the map: Map · Board · Timeline, the map in bold."
  (drgnx-work-lens-string 'map))

(defun drgnx-work-map--refresh-strip ()
  "Make the strip of the current buffer's frame; redisplay then only reads the variable."
  (let ((state (drgnx-work-map--state)))
    (setq drgnx-work-map--strip (if state (drgnx-work-map--strip-string state) "")
          drgnx-work-map--strip-source (and state (cons (drgnx-work-client-needs-you state) (drgnx-work-client-chips state)))
          drgnx-work-map--lens (drgnx-work-map--lens-string)))
  (force-mode-line-update))

(defun drgnx-work-map-needs-you (n)
  "Select the item the strip's Nth chip (g N) is about.  It selects; nothing is approved, pushed or answered."
  (let* ((state (drgnx-work-map--require-state)) (entry (nth (1- n) (drgnx-work-map--needs-you state)))
         (id (and entry (seq-find (lambda (i) (drgnx-work-client-item state i)) (cdr entry)))))
    (if id
        (progn (setq drgnx-work-map--needs-at (1- n)) (drgnx-work-map-select (drgnx-work-nav-sel state id)))
      (message "Work: nothing needs you at g%d" n))))

(defun drgnx-work-map-needs-you-here-next (&optional back)
  "Select the next (BACK: previous) thing that needs you, cycling."
  (interactive)
  (let* ((state (drgnx-work-map--require-state)) (n (length (drgnx-work-map--needs-you state))))
    (if (zerop n)
        (message "Work: nothing needs you")
      (setq drgnx-work-map--needs-at (mod (+ drgnx-work-map--needs-at (if back -1 1)) n))
      (drgnx-work-map-needs-you (1+ drgnx-work-map--needs-at)))))

(defun drgnx-work-map-needs-you-here-previous ()
  "Select the previous thing that needs you."
  (interactive)
  (drgnx-work-map-needs-you-here-next t))

;;;; Filters: the user's own layouts, which the hub makes at once

(defun drgnx-work-map--send-filters ()
  "Tell the hub the filters and collapsed layers: it answers with a full frame, laid out again.  A layout the user
asks for moves (`drgnx-work-map--motion-begin')."
  (drgnx-work-map--motion-begin)
  (when drgnx-work-space--view
    (setq drgnx-work-map--asked t)
    (drgnx-work-client-set drgnx-work-space--view
                           :filters (list :focus (plist-get drgnx-work-map--filters :focus)
                                          :overlaps (if (plist-get drgnx-work-map--filters :overlaps) t :false)
                                          :finished (if (plist-get drgnx-work-map--filters :finished) t :false))
                           :collapsed (vconcat drgnx-work-map--collapsed))))

(defun drgnx-work-map-focus ()
  "Hide what is not on the selection's chain; again, or with nothing selected, show everything.  While focused, the
arrow keys move inside the chain and send nothing."
  (interactive)
  (let ((sel drgnx-work-map--selection) (cur (plist-get drgnx-work-map--filters :focus)))
    (cond ((and cur (or (null sel) (equal cur (cdr sel)))) (setq drgnx-work-map--filters (plist-put drgnx-work-map--filters :focus nil)))
          (sel (setq drgnx-work-map--filters (plist-put drgnx-work-map--filters :focus (cdr sel))))
          (t (user-error "Select an item first")))
    (drgnx-work-map--send-filters)))

(defun drgnx-work-map-overlaps ()
  "Show only the agents and branches that overlap, and what they share; again for everything."
  (interactive)
  (setq drgnx-work-map--filters (plist-put drgnx-work-map--filters :overlaps (not (plist-get drgnx-work-map--filters :overlaps))))
  (drgnx-work-map--send-filters))

(defun drgnx-work-map-show-finished ()
  "Show finished items too; again to hide them."
  (interactive)
  (setq drgnx-work-map--filters (plist-put drgnx-work-map--filters :finished (not (plist-get drgnx-work-map--filters :finished))))
  (drgnx-work-map--send-filters))

(defun drgnx-work-map-collapse-layer (n)
  "Collapse layer N to one thin row, or expand it."
  (setq drgnx-work-map--collapsed (if (memq n drgnx-work-map--collapsed) (delq n (copy-sequence drgnx-work-map--collapsed))
                                    (cons n drgnx-work-map--collapsed)))
  (drgnx-work-map--send-filters))

(defun drgnx-work-map-expand-layers ()
  "Expand every layer."
  (interactive)
  (setq drgnx-work-map--collapsed nil)
  (drgnx-work-map--send-filters))

(defun drgnx-work-map--restyle-all (fn)
  "Call FN, then draw again the rows whose items changed class because of it (the search text, say)."
  (let* ((state (drgnx-work-map--state)) (before (and state (drgnx-work-map--classes state))))
    (funcall fn)
    (when state (drgnx-work-map--restyle state before))))

(defun drgnx-work-map--set-search (text)
  "Narrow the map to TEXT (nil or empty: no narrowing): items that do not match are dimmed."
  (drgnx-work-map--restyle-all
   (lambda () (setq drgnx-work-map--search (and text (not (string-empty-p text)) text)))))

(defun drgnx-work-map-search (text)
  "Narrow the map to the items matching TEXT, dim the rest, and select the first match."
  (interactive (list (read-string "Narrow the map to: " drgnx-work-map--search)))
  (drgnx-work-map--set-search text)
  (when-let* ((state (drgnx-work-map--state)) (text (and text (not (string-empty-p text)) text))
              (first (car (seq-filter (lambda (id) (drgnx-work-map--matches-p state id))
                                      (mapcar #'car (sort (mapcar (lambda (id) (cons id (drgnx-work-client-rect state id)))
                                                                  (seq-filter (lambda (i) (drgnx-work-client-rect state i))
                                                                              (drgnx-work-client-ids state)))
                                                          (lambda (a b) (< (plist-get (cdr a) :y) (plist-get (cdr b) :y)))))))))
    (drgnx-work-map-select (drgnx-work-nav-sel state first))))

(declare-function drgnx-close-pane "drgnx-close")

(defun drgnx-work-map-escape ()
  "Clear the search; with none, clear the filters and the collapsed layers; with none of those, close the pane."
  (interactive)
  (cond ((and drgnx-work-map--search (not (string-empty-p drgnx-work-map--search)))
         (drgnx-work-map--set-search nil))
        ((or (plist-get drgnx-work-map--filters :focus) (plist-get drgnx-work-map--filters :overlaps)
             (plist-get drgnx-work-map--filters :finished) drgnx-work-map--collapsed)
         (setq drgnx-work-map--filters nil drgnx-work-map--collapsed nil)
         (drgnx-work-map--send-filters))
        (t (drgnx-close-pane))))

;;;; A new conclusion shows for 4 s

(defun drgnx-work-map--clear-new (buffer)
  "The timer function of the highlight: BUFFER's new marks go and their cards are drawn again."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((state (drgnx-work-map--state)) (ids drgnx-work-map--new))
        (setq drgnx-work-map--new nil)
        (when (and state ids (drgnx-view-p drgnx-view) (not (drgnx-work-map--outline-p state)))
          (drgnx-view-dirty drgnx-view (delete-dups (apply #'append (mapcar (lambda (id) (drgnx-work-client-rows-of state id)) ids)))))))))

(defun drgnx-work-map--note-new (marks)
  "Items whose latest conclusion MARKS (with the frame before them in :old) changed get a `new' mark for 4 s: one timer
for the whole map."
  (let* ((state (drgnx-work-map--state)) (old (plist-get marks :old))
         (fresh (and state old
                     (seq-filter (lambda (id)
                                   (let ((n (drgnx-work-map--field (drgnx-work-client-item state id) :conclusion))
                                         (o (drgnx-work-map--field (drgnx-work-client-item old id) :conclusion)))
                                     (and n (not (equal n o)))))
                                 (plist-get marks :items)))))
    (when fresh
      (setq drgnx-work-map--new (delete-dups (append fresh drgnx-work-map--new)))
      (drgnx-timer-start (cons 'work-new drgnx-work-space--view) 4 #'drgnx-work-map--clear-new
                         :args (list (current-buffer)) :owner (current-buffer)))))

;;;; Motion: a layout the user asked for moves, in the compositor

;; Glitnir's layout leg (Nidhogg): the window parameter `glitnir-layout-capture' asks the presenter for a picture of
;; the window's text area, `glitnir-layout-captured-p' says it holds it, and `glitnir-layout-motion' says what moved
;; from it.  Without the leg (a terminal, a flat GUI, macOS for now, reduced motion) the map jumps, and says nothing.
(declare-function glitnir-active-p "glitnir")
(declare-function glitnir-layout-captured-p "glitnir")
(declare-function glitnir--reduced-motion-p "glitnir")
(defvar drgnx-look-motion)

(defvar drgnx-work-map-motion-duration 0.16
  "Seconds a layout the user asked for takes to move: the look's longest transition.  A test binds it.")

(defconst drgnx-work-map--motion-period (/ 1.0 60)
  "One frame period: how long the new layout waits for the compositor to hold the old picture.")

(defvar drgnx-work-map-motion-stats (list :legs 0 :skipped 0)
  "This Emacs's map motion: :legs the layouts that moved, :skipped those whose old picture the compositor did not
hold within one period (they jumped).")

(defvar-local drgnx-work-map--motion nil
  "The layout the user asked for, waiting for its frame: (OLD-STATE . WINDOWS), WINDOWS a list of (WINDOW OLD) for
each window that asked for a capture.  OLD: an alist id → (X Y W H), the cards the window showed, in pixels of its
text area.  Nil when nothing waits.")

(defvar-local drgnx-work-map--motion-windows nil
  "The windows this map set `glitnir-layout-capture' on: the leg's end and the teardown take their parameters off.")

(defun drgnx-work-map--motion-p ()
  "Whether a layout can move here: Glitnir draws the selected frame, it has the layout leg, and motion is not
reduced (the desktop's setting through Glitnir, or `drgnx-look-motion')."
  (and (display-graphic-p) (fboundp 'glitnir-layout-captured-p) (fboundp 'glitnir-active-p) (glitnir-active-p)
       (not (eq (bound-and-true-p drgnx-look-motion) 'reduced))
       (not (and (fboundp 'glitnir--reduced-motion-p) (glitnir--reduced-motion-p)))))

(defun drgnx-work-map--drawn-rows (state window)
  "Hash row key → (Y . H): where WINDOW draws STATE's rows, from the one it starts at down to its bottom, in pixels of
its text area.  The display engine lays them out (`window-text-pixel-size', which needs no redisplay), so a row whose
text is taller than the layout (an emoji, a larger fallback font) is where it is drawn.  Nil when WINDOW starts inside
a row or scrolls sideways."
  (let* ((start (window-start window)) (key (drgnx-view-key-at start)))
    (when (and key (zerop (window-hscroll window)) (eql start (drgnx-view-row-start drgnx-view key)))
      (let ((rest (member key (drgnx-work-map--layout-keys state))) (bottom (window-body-height window t))
            (rows (make-hash-table :test #'equal)) (y 0))
        (while (and rest (< y bottom))
          (let* ((from (drgnx-view-row-start drgnx-view (car rest)))
                 (to (or (and (cdr rest) (drgnx-view-row-start drgnx-view (cadr rest))) (point-max)))
                 (h (if from (cdr (window-text-pixel-size window from to)) 0)))
            (puthash (car rest) (cons y h) rows)
            (setq y (+ y h) rest (cdr rest))))
        rows))))

(defun drgnx-work-map--checked-rows (state window)
  "`drgnx-work-map--drawn-rows' of WINDOW, checked against `window-line-height' (WINDOW shows STATE now): (ROWS .
LIMIT), LIMIT the y of the first row whose drawn top differs (cards there and below are left out), or nil.  Nil when
WINDOW is not drawn yet or the rows cannot be told."
  (when-let* ((rows (drgnx-work-map--drawn-rows state window)) (top (nth 2 (window-line-height 0 window))))
    (let ((vpos 0) (prev nil) (limit nil) (done nil))
      (save-excursion
        (goto-char (window-start window))
        (while (not (or done limit (eobp)))
          (let ((line (window-line-height vpos window)) (key (drgnx-view-key-at (point))))
            (if (or (null line) (not (gethash key rows)))
                (setq done t)                   ; past the window's last line
              (when (and key (not (equal key prev)))
                (unless (eql (- (nth 2 line) top) (car (gethash key rows)))
                  (setq limit (car (gethash key rows))))
                (setq prev key))
              (setq vpos (1+ vpos))
              (forward-line 1)))))
      (cons rows limit))))

(defun drgnx-work-map--item-rects (state window rows limit)
  "Alist id → (X Y W H): the cards of STATE that WINDOW shows, at least in part, in pixels of its text area.  X and W
are the layout's; Y and H the drawn rows' (ROWS, `drgnx-work-map--drawn-rows').  Cards whose row's y is at or below
LIMIT (nil: none) are left out."
  (let ((height (window-body-height window t)) (margin (drgnx-work-map--margin-px))
        (layout-rows (cdr (drgnx-work-map--index-of state))) out)
    (dolist (id (drgnx-work-client-ids state))
      (when-let* ((rect (drgnx-work-client-rect state id)) (key (car (drgnx-work-client-rows-of state id)))
                  (drawn (gethash key rows)) ((or (null limit) (< (car drawn) limit))))
        (let* ((row (gethash key layout-rows)) (units (max 1 (or (plist-get row :height_units) 1)))
               (x (+ margin (drgnx-work-map--px (plist-get rect :x))))
               (w (- (+ margin (drgnx-work-map--px (+ (plist-get rect :x) (plist-get rect :w)))) x))
               ;; the card's share of its drawn row: the whole row, mostly
               (y (+ (car drawn) (round (* (cdr drawn) (- (plist-get rect :y) (plist-get row :y))) units)))
               (h (round (* (cdr drawn) (min (plist-get rect :h) units)) units)))
          (when (and (> (+ y h) 0) (< y height))
            (push (list id x y w h) out)))))
    out))

(defun drgnx-work-map--motion-begin ()
  "A layout the user asked for is on its way (its frame comes from the hub): each window showing the map asks the
compositor for the picture of the layout it shows now, and remembers where its cards are.  Nothing when the map
cannot move here (`drgnx-work-map--motion-p'): the new layout then jumps."
  (let ((state (drgnx-work-map--state)))
    (when (and state drgnx-work-space--view (drgnx-view-p drgnx-view) (not (drgnx-work-map--outline-p state))
               (drgnx-work-map--motion-p))
      (let ((windows nil))
        (dolist (w (get-buffer-window-list (current-buffer) nil t))
          (when-let* ((rows (drgnx-work-map--checked-rows state w)))
            ;; a new value, not `eq' to the last: the compositor takes a new picture
            (set-window-parameter w 'glitnir-layout-capture (list 'work-map))
            (cl-pushnew w drgnx-work-map--motion-windows)
            (push (list w (drgnx-work-map--item-rects state w (car rows) (cdr rows))) windows)))
        (when windows
          (drgnx-timer-cancel (cons 'work-motion-end drgnx-work-space--view))
          (setq drgnx-work-map--motion (cons state windows))
          ;; a frame that never comes (no hub, nothing changed) leaves no capture behind
          (drgnx-timer-start (cons 'work-motion-expire drgnx-work-space--view) 1 #'drgnx-work-map--motion-expire
                             :args (list (current-buffer)) :owner (current-buffer)))))))

(defun drgnx-work-map--motion-frame ()
  "The frame of the layout the user asked for came: it is drawn now when every window's old picture is held, else
one period later (`drgnx-work-map--motion-settle'), moving where it is held."
  (drgnx-timer-cancel (cons 'work-motion-expire drgnx-work-space--view))
  (unless (drgnx-work-map--motion-try (current-buffer))
    (drgnx-timer-poll (cons 'work-motion drgnx-work-space--view) drgnx-work-map--motion-period
                      #'drgnx-work-map--motion-try :deadline drgnx-work-map--motion-period
                      :on-timeout #'drgnx-work-map--motion-settle :args (list (current-buffer))
                      :owner (current-buffer))))

(defun drgnx-work-map--motion-try (buffer)
  "Draw BUFFER's new layout if every window's old picture is held; non-nil when it is drawn (or nothing waits)."
  (or (not (buffer-live-p buffer))
      (with-current-buffer buffer
        (or (null drgnx-work-map--motion)
            (when (seq-every-p (lambda (w) (or (not (window-live-p (car w))) (glitnir-layout-captured-p (car w))))
                               (cdr drgnx-work-map--motion))
              (drgnx-work-map--motion-draw)
              t)))))

(defun drgnx-work-map--motion-settle (buffer)
  "One period passed: BUFFER's new layout is drawn, moving in the windows whose old picture is held."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when drgnx-work-map--motion (drgnx-work-map--motion-draw)))))

(defun drgnx-work-map--motion-of (old-state state window old)
  "The `glitnir-layout-motion' of WINDOW from OLD-STATE, its cards at OLD (an alist as `drgnx-work-map--item-rects'),
to STATE, which the buffer holds now and WINDOW has not shown yet; nil when nothing it shows moved."
  (when-let* ((rows (drgnx-work-map--drawn-rows state window)))
    (let ((new (drgnx-work-map--item-rects state window rows nil)) moves enters exits)
      (dolist (n new)
        (let ((o (assoc (car n) old)))
          (cond ((and o (not (equal (cdr o) (cdr n)))) (push (list (car n) (cdr o) (cdr n)) moves))
                ((and (null o) (null (drgnx-work-client-item old-state (car n)))) (push (list (car n) (cdr n)) enters)))))
      (dolist (o old)
        (unless (drgnx-work-client-item state (car o)) (push (list (car o) (cdr o)) exits)))
      (when (or moves enters exits)
        (list :moves moves :enters enters :exits exits :background 'default
              :duration drgnx-work-map-motion-duration :curve 'ease-out)))))

(defun drgnx-work-map--motion-draw ()
  "Draw the new layout and, before the redisplay that shows it, tell the compositor what moved: a window whose old
picture is held gets `glitnir-layout-motion'; one whose picture is not held drops its capture and jumps (a skipped
leg, counted in `drgnx-work-map-motion-stats')."
  (let ((old-state (car drgnx-work-map--motion)) (windows (cdr drgnx-work-map--motion)) (moved nil))
    (setq drgnx-work-map--motion nil)
    (drgnx-timer-cancel (cons 'work-motion drgnx-work-space--view))
    (drgnx-view-touch drgnx-view)
    (drgnx-view-draw-now drgnx-view)
    (let* ((state (drgnx-work-map--state)) (layout (and state (not (drgnx-work-map--outline-p state)))))
      (pcase-dolist (`(,w ,old) windows)
        (when (window-live-p w)
          (let* ((held (glitnir-layout-captured-p w))
                 (motion (and held layout (eq (window-buffer w) (current-buffer))
                              (drgnx-work-map--motion-of old-state state w old))))
            (if motion
                (progn (set-window-parameter w 'glitnir-layout-motion motion)
                       (setq moved t)
                       (cl-incf (plist-get drgnx-work-map-motion-stats :legs)))
              (unless held (cl-incf (plist-get drgnx-work-map-motion-stats :skipped)))
              (set-window-parameter w 'glitnir-layout-capture nil)
              (set-window-parameter w 'glitnir-layout-motion nil))))))
    (when moved
      ;; the leg is over by then: its parameters go, so the window is an ordinary one again
      (drgnx-timer-start (cons 'work-motion-end drgnx-work-space--view) (+ drgnx-work-map-motion-duration 0.1)
                         #'drgnx-work-map--motion-end :args (list (current-buffer)) :owner (current-buffer)))))

(defun drgnx-work-map--motion-off ()
  "Take the capture and the motion off every window this map set them on (a jump for a leg still running)."
  (dolist (w drgnx-work-map--motion-windows)
    (when (window-live-p w)
      (set-window-parameter w 'glitnir-layout-capture nil)
      (set-window-parameter w 'glitnir-layout-motion nil)))
  (setq drgnx-work-map--motion-windows nil))

(defun drgnx-work-map--motion-end (buffer)
  "The timer function at a leg's end: BUFFER's windows lose their capture and motion, unless a new layout waits."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (unless drgnx-work-map--motion (drgnx-work-map--motion-off)))))

(defun drgnx-work-map--motion-expire (buffer)
  "The timer function a second after a layout was asked for and its frame did not come: the captures go."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq drgnx-work-map--motion nil)
      (drgnx-work-map--motion-off))))

(defun drgnx-work-map-motion-clear (&optional buffer)
  "Stop BUFFER's (default: the current) map motion: nothing waits, its timers stop and its windows lose the capture
and the motion.  The module's teardown and a map buffer's end call it."
  (with-current-buffer (or buffer (current-buffer))
    (when drgnx-work-space--view
      (dolist (k '(work-motion work-motion-expire work-motion-end))
        (drgnx-timer-cancel (cons k drgnx-work-space--view))))
    (setq drgnx-work-map--motion nil)
    (drgnx-work-map--motion-off)))

;;;; Marks from the client

(defun drgnx-work-map--changed (view-id marks)
  "`drgnx-work-client-change-functions': draw what MARKS name in the buffer of VIEW-ID."
  (when-let* ((buffer (drgnx-work-map-buffer view-id)))
    (with-current-buffer buffer
      (drgnx-work-map--note-new marks)
      (when (or (plist-get marks :strip) (eq (plist-get marks :rows) t)) (drgnx-work-map--refresh-strip))
      (when (drgnx-view-p drgnx-view)
        (if (or (eq (plist-get marks :rows) t) (plist-get marks :keys) (plist-get marks :layout)
                (drgnx-work-map--outline-p (drgnx-work-map--state)))
            ;; the layout the user asked for moves; any other change, live ones included, never does
            (if (and drgnx-work-map--motion (plist-get marks :layout))
                (progn (setq drgnx-work-map--asked nil) (drgnx-work-map--motion-frame))
              (drgnx-view-touch drgnx-view)
              ;; the frame of a layout the user asked for is drawn at the next pass; a live one waits the throttle
              (when (and drgnx-work-map--asked (plist-get marks :layout))
                (setq drgnx-work-map--asked nil)
                (drgnx-view-hurry drgnx-view)))
          (when (plist-get marks :rows) (drgnx-view-dirty drgnx-view (plist-get marks :rows)))))
      ;; the selected item went (its agent finished, its branch merged): the selection moves to what it came from,
      ;; the panel says it finished, and nothing signals
      (when-let* ((sel drgnx-work-map--selection) ((member (cdr sel) (plist-get marks :removed)))
                  (old (plist-get marks :old)) (state (drgnx-work-map--state)))
        (pcase-let ((`(,new . ,finished) (drgnx-work-nav-resolve old state sel)))
          (setq drgnx-work-map--selection nil)
          (drgnx-work-map-select new)
          (setq drgnx-work-map--finished finished)
          (run-hook-with-args 'drgnx-work-map-select-functions (current-buffer)))))))

(provide 'drgnx-work-map)
;;; drgnx-work-map.el ends here
