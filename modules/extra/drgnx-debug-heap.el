;;; drgnx-debug-heap.el --- the heap graph: a variable's objects as cards, its references as edges -*- lexical-binding: t -*-
;; Part of extra/debug (docs/develop/debugging.md, "The heap graph").  Show as Graph on a Variables row opens the
;; panel's Graph tab (on a local, the frame's locals, the frame its first card): the hub walks the objects from the
;; variable's expression and lays them out in cells
;; (`debug/heap'); this file writes each card's rows at its cells, rings the cards (`glitnir-blocks') and draws the
;; references (`glitnir-edges'), both Nidhogg's.  At each new stop the hub reads the graph again and pushes it
;; (`debug-heap', to the connection that opened it): changed rows take the warn tint, a new card is marked new, and a
;; card no longer reachable shows once more, faded, at its cells.  Closing the tab sends `debug/heap/close'.
;; the-look/debugging-extras.html, "Heap graph".

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-pixels)
(require 'drgnx-icons)
(require 'drgnx-type-faces)

(declare-function drgnx-hub--call-on "drgnx-hub-client" (conn method params callback &rest keys))
(declare-function drgnx-wb-area-show "drgnx-area" (area &optional tab buffer))
(declare-function drgnx-debug-view--value-node "drgnx-debug-view" ())
(declare-function drgnx-debug-view--field "drgnx-debug-view" (name id))
(declare-function drgnx-debug--session "drgnx-debug" (&optional state))
(declare-function drgnx-px "drgnx-pixels" (logical &optional frame scale))
(defvar drgnx-hub--events)

(defconst drgnx-debug-heap-buffer-name "*Debug Graph*")

;; the cards' text: titles and references in the UI font, names and values in the code font (debugging-extras.html)
(defface drgnx-debug-heap-card '((t :inherit drgnx-surface-raised)) "A card's fill." :group 'drgnx-debug)
(defface drgnx-debug-heap-title '((t :inherit (drgnx-ui-heading drgnx-debug-heap-card)))
  "A card's name: the variable or field path that reached it first." :group 'drgnx-debug)
(defface drgnx-debug-heap-type '((t :inherit (drgnx-ui-text drgnx-text-subtle drgnx-debug-heap-card)))
  "A card's type, after its name." :group 'drgnx-debug)
(defface drgnx-debug-heap-name '((t :inherit (drgnx-text-muted drgnx-debug-heap-card))) "A field's name."
  :group 'drgnx-debug)
(defface drgnx-debug-heap-value '((t :inherit (font-lock-constant-face drgnx-debug-heap-card))) "A field's value."
  :group 'drgnx-debug)
(defface drgnx-debug-heap-string '((t :inherit (font-lock-string-face drgnx-debug-heap-card))) "A string value."
  :group 'drgnx-debug)
(defface drgnx-debug-heap-reference '((t :inherit (drgnx-ui-caption drgnx-text-subtle drgnx-debug-heap-card)))
  "A reference field's target type (its edge leaves the row)." :group 'drgnx-debug)
(defface drgnx-debug-heap-cut '((t :inherit (drgnx-ui-caption drgnx-chip-quiet)))
  "A cut field's stub, \"+N not shown\", where its dashed edge ends." :group 'drgnx-debug)
(defface drgnx-debug-heap-changed '((t :inherit (drgnx-tint-warn))) "A row whose value changed at this stop."
  :group 'drgnx-debug)
(defface drgnx-debug-heap-gone '((t :inherit (drgnx-text-disabled drgnx-debug-heap-card)))
  "A card no longer reachable, shown once more." :group 'drgnx-debug)

(defvar drgnx-debug--sessions)
(defvar drgnx-debug-heap--frames nil
  "Each live session's stopped frame, (SESSION NAME EPOCH), from `debug-frame': the header's function and stop.")
(defvar-local drgnx-debug-heap--answer nil "The graph shown: the last `debug/heap' answer or `debug-heap' push.")
(defvar-local drgnx-debug-heap--before nil "The answer before it (its nodes and cards), for the rows that changed.")
(defvar-local drgnx-debug-heap--title nil "What the header names: the expression, or the local shown as a graph.")
(defvar-local drgnx-debug-heap--pick nil "The local whose card the first answer of a frame's locals selects.")
(defvar-local drgnx-debug-heap--selected nil "The selected card's id.")
(defvar-local drgnx-debug-heap--error nil "The last push's error, shown in the header until the next graph.")
(defvar-local drgnx-debug-heap--head "" "The header strip, the buffer's first line (a panel's header line is its tabs).")
(defvar-local drgnx-debug-heap--blocks nil "The cards' rings as last set (`glitnir-blocks').")
(defvar-local drgnx-debug-heap--edges nil "The references as last set (`glitnir-edges').")
(defvar-keymap drgnx-debug-heap-mode-map
  :doc "The Graph tab's keys; the profiles add theirs (`debug-heap-*' in keys/*.eld)."
  "<mouse-1>" #'drgnx-debug-heap-select)

(define-derived-mode drgnx-debug-heap-mode special-mode "Graph"
  "A variable's objects, or a frame's locals, as cards and their references as edges, read again at each stop."
  (setq-local truncate-lines t)
  (buffer-disable-undo)
  (add-hook 'kill-buffer-hook #'drgnx-debug-heap--closed nil t))

;;;; Asking

(defun drgnx-debug-heap--call (method params callback)
  "METHOD with PARAMS on the events connection, where the hub pushes `debug-heap': nil while it is down."
  (when (and (boundp 'drgnx-hub--events) (process-live-p drgnx-hub--events))
    (drgnx-hub--call-on drgnx-hub--events method params callback)
    t))

(defun drgnx-debug-heap-open (session expr &optional local)
  "Show EXPR's objects in SESSION (stopped) in the Graph tab, or with EXPR nil the stopped frame's locals, the card of
LOCAL (a local's name) selected; a graph already open there is closed first."
  (let ((b (get-buffer drgnx-debug-heap-buffer-name)))
    (when b (kill-buffer b))
    (setq b (get-buffer-create drgnx-debug-heap-buffer-name))
    (with-current-buffer b
      (drgnx-debug-heap-mode)
      (setq drgnx-debug-heap--title (or expr local "Locals") drgnx-debug-heap--pick local)
      (setq drgnx-debug-heap--head (drgnx-debug-heap--header))
      (let ((inhibit-read-only t)) (insert drgnx-debug-heap--head "\n")))
    (unless (drgnx-debug-heap--call "debug/heap" (if expr (list :session session :expr expr)
                                                   (list :session session :locals t))
                                    (lambda (result error)
                                      (when (buffer-live-p b)
                                        (with-current-buffer b
                                          (if error (drgnx-debug-heap--fail error) (drgnx-debug-heap--show result))))))
      (user-error "Not connected to the hub"))
    (drgnx-wb-area-show 'panel 'debug-graph b)
    b))

(defun drgnx-debug-show-as-graph ()
  "Show as Graph: the objects of the variable at point in the Run and Debug view, as cards with their references.  On
a local (a row of the Locals scope) the graph is the frame's locals, that local's card selected."
  (interactive)
  (let* ((id (drgnx-debug-view--value-node))
         (local (and (string-match "\\`v:[^:]+:Local[^/]*/\\([^/]+\\)\\'" id)
                     (or (drgnx-debug-view--field "label" id) (match-string 1 id))))
         (expr (or local (drgnx-debug-view--field "evaluate_name" id)
                   (user-error "The adapter gives no expression for this variable")))
         (session (if (string-match "\\`v:\\([^:]+\\):" id) (match-string 1 id)
                    (plist-get (or (drgnx-debug--session "stopped") (user-error "No stopped debug session")) :id))))
    (if local (drgnx-debug-heap-open session nil local) (drgnx-debug-heap-open session expr))))

(defun drgnx-debug-heap--closed ()
  "The Graph tab's buffer goes (`kill-buffer-hook'): the hub stops reading its graph, and no window keeps its lines."
  (when-let* ((g (plist-get drgnx-debug-heap--answer :graph)))
    (drgnx-debug-heap--call "debug/heap/close" (list :graph g) #'ignore))
  (drgnx-debug-heap--publish nil nil))

(defun drgnx-debug-heap-frame (data)
  "A `debug-frame' event (DATA): its session's function and stop, for the header (sessions that ended are dropped)."
  (let ((s (plist-get data :session)))
    (setq drgnx-debug-heap--frames
          (cons (list s (plist-get data :name) (plist-get data :epoch))
                (seq-filter (lambda (f) (and (not (equal (car f) s))
                                             (seq-find (lambda (x) (equal (plist-get x :id) (car f)))
                                                       (bound-and-true-p drgnx-debug--sessions))))
                            drgnx-debug-heap--frames)))))

(defun drgnx-debug-heap-event (data)
  "A `debug-heap' push: the open graph DATA names, read again at a new stop (or its error)."
  (when-let* ((b (get-buffer drgnx-debug-heap-buffer-name)))
    (with-current-buffer b
      (when (equal (plist-get data :graph) (plist-get drgnx-debug-heap--answer :graph))
        (if (plist-get data :error) (drgnx-debug-heap--fail (plist-get data :error)) (drgnx-debug-heap--show data))))))

(defun drgnx-debug-heap--fail (error)
  "ERROR in the header; the last cards stay."
  (setq drgnx-debug-heap--error (format "%s" error))
  (drgnx-debug-heap--draw))

(defun drgnx-debug-heap--show (answer)
  "Show ANSWER, the graph read again (or first): the one before it is kept for what changed.  The first answer of a
frame's locals selects the picked local's card."
  (setq drgnx-debug-heap--before drgnx-debug-heap--answer
        drgnx-debug-heap--answer answer
        drgnx-debug-heap--error nil)
  (when drgnx-debug-heap--pick
    (let ((f (drgnx-debug-heap--find-field drgnx-debug-heap--pick (drgnx-debug-heap--node (plist-get answer :node)))))
      (setq drgnx-debug-heap--selected (plist-get f :to) drgnx-debug-heap--pick nil)))
  (unless (drgnx-debug-heap--card drgnx-debug-heap--selected)
    (setq drgnx-debug-heap--selected (plist-get answer :node)))
  (drgnx-debug-heap--draw))

;;;; Drawing

(defun drgnx-debug-heap--find (id seq)
  (seq-find (lambda (x) (equal (plist-get x :id) id)) seq))

(defun drgnx-debug-heap--card (id &optional answer)
  "Card ID of ANSWER (default the one shown), or nil."
  (and id (drgnx-debug-heap--find id (plist-get (or answer drgnx-debug-heap--answer) :cards))))

(defun drgnx-debug-heap--node (id &optional answer)
  (drgnx-debug-heap--find id (plist-get (or answer drgnx-debug-heap--answer) :nodes)))

(defun drgnx-debug-heap--line (row)
  "The start of the grid's line ROW (the header strip is the buffer's first line)."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1+ row))
    (point)))

(defun drgnx-debug-heap--px (n)
  "N logical pixels as a stretch's pixels: a column on a text terminal."
  (if (display-graphic-p) (drgnx-px n) 1))

(defun drgnx-debug-heap--to (col &optional px face)
  "A stretch in FACE to column COL plus PX pixels (minus, a negative PX): cells are columns of the code font, so text
in another font (the UI font's titles) keeps the cards' edges where the hub put them."
  (propertize " " 'face face 'display
              `(space :align-to ,(cond ((or (null px) (zerop px)) col)
                                       ((> px 0) `(+ ,col (,px)))
                                       (t `(- ,col (,(- px))))))))

(defun drgnx-debug-heap--gap (px face)
  "A space PX pixels wide in FACE."
  (propertize " " 'face face 'display `(space :width (,px))))

(defun drgnx-debug-heap--width (s ui)
  "S's width in pixels: measured in the UI font (UI), else its columns of the code font."
  (if ui (string-pixel-width s) (* (string-width s) (frame-char-width))))

(defun drgnx-debug-heap--fit (s ui px)
  "S cut to PX pixels, UI as in `drgnx-debug-heap--width'."
  (cond ((<= (drgnx-debug-heap--width s ui) px) s)
        (ui (truncate-string-pixelwise s px nil "…"))
        (t (truncate-string-to-width s (max 0 (/ px (frame-char-width))) nil nil "…"))))

(defun drgnx-debug-heap--row (col width face left &optional right)
  "A card's row at COL, WIDTH columns wide, filled in FACE: LEFT after the left padding and RIGHT against the right one,
each (STRING . UI) (UI: in the UI font); RIGHT is kept whole where it fits, LEFT cut to what it leaves."
  (let* ((pad (drgnx-debug-heap--px 10)) (gap (drgnx-debug-heap--px 8))
         (room (- (* width (frame-char-width)) pad pad))
         (r (and right (drgnx-debug-heap--fit (car right) (cdr right) (max 0 (- room gap (drgnx-debug-heap--px 24))))))
         (rw (if r (drgnx-debug-heap--width r (cdr right)) 0))
         (l (drgnx-debug-heap--fit (car left) (cdr left) (max 0 (- room rw (if r gap 0))))))
    (concat (drgnx-debug-heap--to col pad face) l
            (and r (concat (drgnx-debug-heap--to (+ col width) (- (+ pad rw)) face) r))
            (drgnx-debug-heap--to (+ col width) 0 face))))

(defun drgnx-debug-heap--rows (node card state)
  "NODE's rows for CARD (its cells), as strings: its title (the name that reached it, then its type), then its fields.
STATE `gone' fades them, `new' marks the title; the fields whose value changed since the graph before take the warn
tint."
  (let* ((c (plist-get card :col)) (w (plist-get card :width)) (h (plist-get card :height))
         (face 'drgnx-debug-heap-card)
         (fields (append (plist-get node :fields) nil))
         (shown (max 0 (- h 1 (if (> (length fields) (1- h)) 1 0))))
         (was (and (not (memq state '(gone new)))
                   (drgnx-debug-heap--node (plist-get node :id) drgnx-debug-heap--before)))
         (path (plist-get node :path)) (type (plist-get node :type))
         (title (concat (propertize (if (string-empty-p path) type path) 'face 'drgnx-debug-heap-title)
                        (and (not (string-empty-p path)) (not (string-empty-p type))
                             (concat (drgnx-debug-heap--gap (drgnx-debug-heap--px 6) face)
                                     (propertize type 'face 'drgnx-debug-heap-type)))))
         (rows (list (drgnx-debug-heap--row c w face (cons title t)
                                            (and (eq state 'new)
                                                 (cons (propertize " new " 'face '(drgnx-ui-caption drgnx-chip-accent))
                                                       t))))))
    (dolist (f (seq-take fields shown))
      (let* ((to (plist-get f :to)) (v (plist-get f :value)) (ref (or to (plist-get f :cut)))
             (changed (and was (not (equal v (plist-get (drgnx-debug-heap--find-field (plist-get f :name) was)
                                                        :value)))))
             (row (drgnx-debug-heap--row
                   c w face (cons (propertize (plist-get f :name) 'face 'drgnx-debug-heap-name) nil)
                   (cons (propertize (if to (let ((tn (drgnx-debug-heap--node to))) (or (and tn (plist-get tn :type)) v)) v)
                                     'face (cond (ref 'drgnx-debug-heap-reference)
                                                 ((string-match-p "\\`['\"]" v) 'drgnx-debug-heap-string)
                                                 (t 'drgnx-debug-heap-value)))
                         ref))))
        (when changed (add-face-text-property 0 (length row) 'drgnx-debug-heap-changed nil row))
        (push row rows)))
    (when (> (length fields) shown)
      (push (drgnx-debug-heap--row c w face (cons (propertize (format "+%d more" (- (length fields) shown))
                                                              'face 'drgnx-debug-heap-name)
                                                  nil))
            rows))
    (setq rows (nreverse rows))
    (when (eq state 'gone)
      (dolist (r rows) (add-face-text-property 0 (length r) 'drgnx-debug-heap-gone nil r)))
    rows))

(defun drgnx-debug-heap--find-field (name node)
  (seq-find (lambda (f) (equal (plist-get f :name) name)) (plist-get node :fields)))

(defun drgnx-debug-heap--overlaps-p (a b)
  "Whether cards A and B share a cell."
  (and (< (plist-get a :col) (+ (plist-get b :col) (plist-get b :width)))
       (< (plist-get b :col) (+ (plist-get a :col) (plist-get a :width)))
       (< (plist-get a :row) (+ (plist-get b :row) (plist-get b :height)))
       (< (plist-get b :row) (+ (plist-get a :row) (plist-get a :height)))))

(defun drgnx-debug-heap--faded ()
  "The cards gone at this stop that are still drawn once, faded: (NODE . CARD) of the graph before, where they do
not overlap a card now."
  (let ((cards (append (plist-get drgnx-debug-heap--answer :cards) nil)))
    (delq nil (mapcar (lambda (id)
                        (let ((card (drgnx-debug-heap--card id drgnx-debug-heap--before))
                              (node (drgnx-debug-heap--node id drgnx-debug-heap--before)))
                          (and card node (not (seq-some (lambda (c) (drgnx-debug-heap--overlaps-p card c)) cards))
                               (cons node card))))
                      (append (plist-get drgnx-debug-heap--answer :gone) nil)))))

(defun drgnx-debug-heap--header ()
  "The header strip: the workflow icon, Graph and what it shows, the stopped frame's function, the stop and the
objects; against the right edge, chips for what changed at this stop and what the limit cut, or the error."
  (let* ((a drgnx-debug-heap--answer)
         ;; the objects: a frame's locals' first node is the frame
         (n (- (length (plist-get a :nodes)) (if (plist-get a :locals) 1 0)))
         (frame (assoc (plist-get a :session) drgnx-debug-heap--frames))
         (changed (length (plist-get a :changed))) (added (length (plist-get a :added))) (cut (or (plist-get a :cut) 0))
         (detail (if (not a) "reading…"
                   (string-join (delq nil (list (nth 1 frame) (and (nth 2 frame) (format "stop %d" (nth 2 frame)))
                                                (format "%d object%s" n (if (= n 1) "" "s"))))
                                " · ")))
         (chip (lambda (s face) (propertize s 'face (list 'drgnx-ui-caption face))))
         (chips (string-join
                 (delq nil (list (and (> changed 0) (funcall chip (format " %d changed " changed) 'drgnx-chip-quiet))
                                 (and (> added 0) (funcall chip (format " %d new " added) 'drgnx-chip-accent))
                                 (and (> cut 0) (funcall chip (format " +%d not shown " cut) 'drgnx-chip-quiet))
                                 (and drgnx-debug-heap--error (propertize drgnx-debug-heap--error 'face 'error))))
                 " ")))
    (concat " " (drgnx-look-icon 'workflow 'drgnx-text-muted 14) " "
            (propertize (format "Graph: %s" drgnx-debug-heap--title) 'face '(bold drgnx-ui-heading)) "  "
            (propertize detail 'face '(drgnx-ui-text drgnx-text-subtle))
            (unless (string-empty-p chips)
              (concat (propertize " " 'display `(space :align-to (- right (,(+ (string-pixel-width chips)
                                                                               (drgnx-debug-heap--px 12))))))
                      chips)))))

(defun drgnx-debug-heap--draw ()
  "Write the graph: the header strip, then a line per row of cells, each card's rows at its cells (stretches to their
columns); then its rings and edges."
  (let* ((a drgnx-debug-heap--answer)
         (faded (drgnx-debug-heap--faded))
         (height (apply #'max (or (plist-get a :height) 0)
                        (mapcar (lambda (f) (+ (plist-get (cdr f) :row) (plist-get (cdr f) :height))) faded)))
         (lines (make-vector height nil))
         (added (append (plist-get a :added) nil))
         (put (lambda (node card state)
                (let ((r (plist-get card :row)))
                  (dolist (s (drgnx-debug-heap--rows node card state))
                    (when (< r height)
                      (aset lines r (cons (list (plist-get card :col)
                                                (propertize s 'drgnx-debug-heap-card (plist-get card :id)))
                                          (aref lines r))))
                    (setq r (1+ r)))))))
    (seq-doseq (card (plist-get a :cards))
      (when-let* ((node (drgnx-debug-heap--node (plist-get card :id))))
        (funcall put node card (and (member (plist-get card :id) added) 'new))))
    (dolist (f faded) (funcall put (car f) (cdr f) 'gone))
    ;; the limit's stubs: one row each, "+N not shown" in a quiet chip at the cells the hub gave it
    (seq-doseq (cut (plist-get a :cuts))
      (let ((r (plist-get cut :row)) (pad (drgnx-debug-heap--gap (drgnx-debug-heap--px 6) 'drgnx-debug-heap-cut)))
        (when (< r height)
          (aset lines r (cons (list (plist-get cut :col)
                                    (propertize (concat pad (propertize (format "+%d not shown" (plist-get cut :count))
                                                                        'face 'drgnx-debug-heap-cut)
                                                        pad)
                                                'drgnx-debug-heap-stub t))
                              (aref lines r))))))
    ;; written whole at each stop (the hub lays the grid out again; a card keeps its cells, so point and each window's
    ;; start are put back where they were)
    (let ((inhibit-read-only t) (at (point))
          (starts (mapcar (lambda (w) (cons w (window-start w))) (get-buffer-window-list nil nil t))))
      (erase-buffer)
      (setq drgnx-debug-heap--head (drgnx-debug-heap--header))
      (insert drgnx-debug-heap--head "\n")
      (dotimes (r height)
        (dolist (piece (sort (aref lines r) (lambda (x y) (< (car x) (car y)))))
          (insert (drgnx-debug-heap--to (car piece)) (cadr piece)))
        (insert "\n"))
      (goto-char (min at (point-max)))
      (pcase-dolist (`(,w . ,start) starts) (set-window-start w (min start (point-max)) t)))
    (drgnx-debug-heap--decorate faded)))

(defun drgnx-debug-heap--decorate (&optional faded)
  "The cards' rings (the selected one in the focus colour, FADED ones in the subtle border) and the references'
edges (the selected card's in the accent), for the windows that show the graph.  A place is its row's start and
the cell's pixels across."
  (let* ((a drgnx-debug-heap--answer) (cw (frame-char-width)) (dy (/ (frame-char-height) 2))
         (sel drgnx-debug-heap--selected)
         (ring (lambda (card face)
                 (let ((r (plist-get card :row)) (c (plist-get card :col)))
                   `(ring ,(drgnx-debug-heap--line r) ,(drgnx-debug-heap--line (+ r (plist-get card :height)))
                          :x0 ,(* c cw) :x1 ,(* (+ c (plist-get card :width)) cw) :radius ,(drgnx-px 6) :ring ,face
                          :beneath default))))
         (place (lambda (p) (list (drgnx-debug-heap--line (aref p 1)) (* (aref p 0) cw) dy))))
    (drgnx-debug-heap--publish
     (append (mapcar (lambda (card) (funcall ring card (if (equal (plist-get card :id) sel) 'drgnx-focus-line 'drgnx-border)))
                     (plist-get a :cards))
             (mapcar (lambda (f) (funcall ring (cdr f) 'drgnx-border-subtle)) faded))
     (mapcar (lambda (e)
               (let ((points (append (plist-get e :points) nil)))
                 `(,(funcall place (car points)) ,(funcall place (car (last points)))
                   ,(if (or (equal (plist-get e :from) sel) (equal (plist-get e :to) sel)) 'drgnx-accent 'drgnx-text-subtle)
                   :points ,(mapcar place (butlast (cdr points)))
                   ;; a cut edge ends at its stub, dashed and without a head
                   ,@(if (plist-get e :cut) '(:dash t) '(:arrow t)))))
             (plist-get a :edges)))))

(defun drgnx-debug-heap--publish (blocks edges)
  "Keep BLOCKS and EDGES and give them to the windows that show this buffer."
  (setq drgnx-debug-heap--blocks blocks drgnx-debug-heap--edges edges)
  (dolist (w (get-buffer-window-list (current-buffer) nil t))
    (set-window-parameter w 'glitnir-blocks blocks)
    (set-window-parameter w 'glitnir-edges edges)))

(defun drgnx-debug-heap-select (&optional event)
  "Select the card at point (or at EVENT's click): it is ringed, and its edges take the accent."
  (interactive (list (and (mouse-event-p last-input-event) last-input-event)))
  (when event (posn-set-point (event-end event)))
  (when-let* ((id (get-text-property (point) 'drgnx-debug-heap-card)))
    (setq drgnx-debug-heap--selected id)
    (drgnx-debug-heap--decorate (drgnx-debug-heap--faded))))

(defun drgnx-debug-heap--teardown ()
  "The Graph tab goes with the module, and the frames it kept for the header."
  (setq drgnx-debug-heap--frames nil)
  (when-let* ((b (get-buffer drgnx-debug-heap-buffer-name))) (kill-buffer b)))

(provide 'drgnx-debug-heap)
;;; drgnx-debug-heap.el ends here
