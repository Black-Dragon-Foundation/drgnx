;;; drgnx-debug-heap.el --- the heap graph: a variable's objects as cards, its references as edges -*- lexical-binding: t -*-
;; Part of extra/debug (docs/develop/debugging.md, "The heap graph").  Show as Graph on a Variables row opens the
;; panel's Graph tab: the hub walks the objects from the variable's expression and lays them out in cells
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

(declare-function drgnx-hub--call-on "drgnx-hub-client" (conn method params callback &rest keys))
(declare-function drgnx-wb-area-show "drgnx-area" (area &optional tab buffer))
(declare-function drgnx-debug-view--value-node "drgnx-debug-view" ())
(declare-function drgnx-debug-view--field "drgnx-debug-view" (name id))
(declare-function drgnx-debug--session "drgnx-debug" (&optional state))
(declare-function drgnx-px "drgnx-pixels" (logical &optional frame scale))
(defvar drgnx-hub--events)

(defconst drgnx-debug-heap-buffer-name "*Debug Graph*")

(defface drgnx-debug-heap-card '((t :inherit drgnx-surface-raised)) "A card's fill." :group 'drgnx-debug)
(defface drgnx-debug-heap-type '((t :inherit (bold drgnx-debug-heap-card))) "A card's type row." :group 'drgnx-debug)
(defface drgnx-debug-heap-path '((t :inherit (drgnx-text-subtle drgnx-debug-heap-card)))
  "The expression that reached a card, after its type." :group 'drgnx-debug)
(defface drgnx-debug-heap-name '((t :inherit (drgnx-text-muted drgnx-debug-heap-card))) "A field's name."
  :group 'drgnx-debug)
(defface drgnx-debug-heap-value '((t :inherit (font-lock-constant-face drgnx-debug-heap-card))) "A field's value."
  :group 'drgnx-debug)
(defface drgnx-debug-heap-string '((t :inherit (font-lock-string-face drgnx-debug-heap-card))) "A string value."
  :group 'drgnx-debug)
(defface drgnx-debug-heap-reference '((t :inherit (drgnx-text-subtle drgnx-debug-heap-card)))
  "A reference field's target type (its edge leaves the row)." :group 'drgnx-debug)
(defface drgnx-debug-heap-cut '((t :inherit drgnx-chip-quiet))
  "A cut field's stub, \"+N not shown\", where its dashed edge ends." :group 'drgnx-debug)
(defface drgnx-debug-heap-changed '((t :inherit (drgnx-tint-warn))) "A row whose value changed at this stop."
  :group 'drgnx-debug)
(defface drgnx-debug-heap-gone '((t :inherit (drgnx-text-disabled drgnx-debug-heap-card)))
  "A card no longer reachable, shown once more." :group 'drgnx-debug)

(defvar-local drgnx-debug-heap--answer nil "The graph shown: the last `debug/heap' answer or `debug-heap' push.")
(defvar-local drgnx-debug-heap--before nil "The answer before it (its nodes and cards), for the rows that changed.")
(defvar-local drgnx-debug-heap--selected nil "The selected card's id.")
(defvar-local drgnx-debug-heap--error nil "The last push's error, shown in the header until the next graph.")
(defvar-local drgnx-debug-heap--blocks nil "The cards' rings as last set (`glitnir-blocks').")
(defvar-local drgnx-debug-heap--edges nil "The references as last set (`glitnir-edges').")
(defvar-keymap drgnx-debug-heap-mode-map
  :doc "The Graph tab's keys; the profiles add theirs (`debug-heap-*' in keys/*.eld)."
  "<mouse-1>" #'drgnx-debug-heap-select)

(define-derived-mode drgnx-debug-heap-mode special-mode "Graph"
  "A variable's objects as cards and its references as edges, read again at each stop."
  (setq-local truncate-lines t)
  (buffer-disable-undo)
  (add-hook 'kill-buffer-hook #'drgnx-debug-heap--closed nil t))

;;;; Asking

(defun drgnx-debug-heap--call (method params callback)
  "METHOD with PARAMS on the events connection, where the hub pushes `debug-heap': nil while it is down."
  (when (and (boundp 'drgnx-hub--events) (process-live-p drgnx-hub--events))
    (drgnx-hub--call-on drgnx-hub--events method params callback)
    t))

(defun drgnx-debug-heap-open (session expr)
  "Show EXPR's objects in SESSION (stopped) in the Graph tab; a graph already open there is closed first."
  (let ((b (get-buffer drgnx-debug-heap-buffer-name)))
    (when b (kill-buffer b))
    (setq b (get-buffer-create drgnx-debug-heap-buffer-name))
    (with-current-buffer b
      (drgnx-debug-heap-mode)
      (let ((inhibit-read-only t)) (insert (format " Graph: %s · reading…\n" expr))))
    (unless (drgnx-debug-heap--call "debug/heap" (list :session session :expr expr)
                                    (lambda (result error)
                                      (when (buffer-live-p b)
                                        (with-current-buffer b
                                          (if error (drgnx-debug-heap--fail error) (drgnx-debug-heap--show result))))))
      (user-error "Not connected to the hub"))
    (drgnx-wb-area-show 'panel 'debug-graph b)
    b))

(defun drgnx-debug-show-as-graph ()
  "Show as Graph: the objects of the variable at point in the Run and Debug view, as cards with their references."
  (interactive)
  (let* ((id (drgnx-debug-view--value-node))
         (expr (or (drgnx-debug-view--field "evaluate_name" id)
                   (user-error "The adapter gives no expression for this variable")))
         (session (if (string-match "\\`v:\\([^:]+\\):" id) (match-string 1 id)
                    (plist-get (or (drgnx-debug--session "stopped") (user-error "No stopped debug session")) :id))))
    (drgnx-debug-heap-open session expr)))

(defun drgnx-debug-heap--closed ()
  "The Graph tab's buffer goes (`kill-buffer-hook'): the hub stops reading its graph, and no window keeps its lines."
  (when-let* ((g (plist-get drgnx-debug-heap--answer :graph)))
    (drgnx-debug-heap--call "debug/heap/close" (list :graph g) #'ignore))
  (drgnx-debug-heap--publish nil nil))

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
  "Show ANSWER, the graph read again (or first): the one before it is kept for what changed."
  (setq drgnx-debug-heap--before drgnx-debug-heap--answer
        drgnx-debug-heap--answer answer
        drgnx-debug-heap--error nil)
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

(defun drgnx-debug-heap--cell (row col)
  "The position of the grid's cell ROW, COL (the header is the first line)."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1+ row))
    (move-to-column col)
    (point)))

(defun drgnx-debug-heap--fit (s width)
  "S cut to WIDTH columns."
  (truncate-string-to-width s width nil nil "…"))

(defun drgnx-debug-heap--row (left lface right rface width face)
  "A card's row WIDTH columns wide: LEFT in LFACE after a space, RIGHT in RFACE before one, the rest in FACE."
  (let* ((right (copy-sequence (drgnx-debug-heap--fit (or right "") (max 0 (- width 3)))))
         (left (copy-sequence (drgnx-debug-heap--fit left (max 0 (- width 3 (string-width right))))))
         (gap (- width 2 (string-width left) (string-width right))))
    ;; LFACE and RFACE under any face the text has (a type row's path)
    (add-face-text-property 0 (length left) lface t left)
    (add-face-text-property 0 (length right) rface t right)
    (concat (propertize " " 'face face) left (propertize (make-string (max 1 gap) ?\s) 'face face)
            right (propertize " " 'face face))))

(defun drgnx-debug-heap--rows (node card state)
  "NODE's rows for CARD (its width and height), as strings: STATE `gone' fades them, `new' marks the type row; the
fields whose value changed since the graph before take the warn tint."
  (let* ((w (plist-get card :width)) (h (plist-get card :height))
         (gone (eq state 'gone))
         (face (if gone 'drgnx-debug-heap-gone 'drgnx-debug-heap-card))
         (fields (append (plist-get node :fields) nil))
         (shown (max 0 (- h 1 (if (> (length fields) (1- h)) 1 0))))
         (was (and (not gone) (not (eq state 'new))
                   (drgnx-debug-heap--node (plist-get node :id) drgnx-debug-heap--before)))
         (rows (list (drgnx-debug-heap--row (concat (plist-get node :type)
                                                    (and (not (string-empty-p (plist-get node :path)))
                                                         (propertize (concat " " (plist-get node :path))
                                                                     'face (if gone face 'drgnx-debug-heap-path))))
                                            (if gone face 'drgnx-debug-heap-type)
                                            (and (eq state 'new) "new") 'drgnx-chip-accent w face))))
    (dolist (f (seq-take fields shown))
      (let* ((to (plist-get f :to)) (v (plist-get f :value))
             (changed (and was (not (equal v (plist-get (drgnx-debug-heap--find-field (plist-get f :name) was)
                                                        :value)))))
             (row (drgnx-debug-heap--row
                   (plist-get f :name) (if gone face 'drgnx-debug-heap-name)
                   (if to (let ((tn (drgnx-debug-heap--node to))) (or (and tn (plist-get tn :type)) v)) v)
                   (cond (gone face) ((or to (plist-get f :cut)) 'drgnx-debug-heap-reference)
                         ((string-match-p "\\`['\"]" v) 'drgnx-debug-heap-string) (t 'drgnx-debug-heap-value))
                   w face)))
        (when changed (add-face-text-property 0 (length row) 'drgnx-debug-heap-changed nil row))
        (push row rows)))
    (when (> (length fields) shown)
      (push (drgnx-debug-heap--row (format "+%d more" (- (length fields) shown)) (if gone face 'drgnx-debug-heap-name)
                                   nil face w face)
            rows))
    (nreverse rows)))

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
  "The first line: the graph's expression and size, what changed at this stop, what the limit cut, or the error."
  (let* ((a drgnx-debug-heap--answer)
         (n (length (plist-get a :nodes)))
         (changed (length (plist-get a :changed))) (added (length (plist-get a :added))) (cut (or (plist-get a :cut) 0)))
    (concat " " (propertize (format "Graph: %s" (plist-get a :expr)) 'face 'bold)
            (propertize (format "  %d object%s" n (if (= n 1) "" "s")) 'face 'drgnx-text-subtle)
            (and (> changed 0) (concat "  " (propertize (format " %d changed " changed) 'face 'drgnx-chip-quiet)))
            (and (> added 0) (concat "  " (propertize (format " %d new " added) 'face 'drgnx-chip-accent)))
            (and (> cut 0) (concat "  " (propertize (format " +%d not shown " cut) 'face 'drgnx-chip-quiet)))
            (and drgnx-debug-heap--error (concat "  " (propertize drgnx-debug-heap--error 'face 'error))))))

(defun drgnx-debug-heap--draw ()
  "Write the graph: the header, then a line per row of cells, each card's rows at its cells; then its rings and
edges."
  (let* ((a drgnx-debug-heap--answer)
         (faded (drgnx-debug-heap--faded))
         (width (apply #'max (or (plist-get a :width) 0)
                       (mapcar (lambda (f) (+ (plist-get (cdr f) :col) (plist-get (cdr f) :width))) faded)))
         (height (apply #'max (or (plist-get a :height) 0)
                        (mapcar (lambda (f) (+ (plist-get (cdr f) :row) (plist-get (cdr f) :height))) faded)))
         (lines (make-vector height nil))
         (added (append (plist-get a :added) nil))
         (put (lambda (node card state)
                (let ((r (plist-get card :row)) (c (plist-get card :col)))
                  (dolist (s (drgnx-debug-heap--rows node card state))
                    (when (< r height)
                      (aset lines r (cons (list c (propertize s 'drgnx-debug-heap-card (plist-get card :id))) (aref lines r))))
                    (setq r (1+ r)))))))
    (seq-doseq (card (plist-get a :cards))
      (when-let* ((node (drgnx-debug-heap--node (plist-get card :id))))
        (funcall put node card (and (member (plist-get card :id) added) 'new))))
    (dolist (f faded) (funcall put (car f) (cdr f) 'gone))
    ;; the limit's stubs: one row each, "+N not shown" in a quiet chip at the cells the hub gave it
    (seq-doseq (cut (plist-get a :cuts))
      (let ((r (plist-get cut :row)) (w (plist-get cut :width))
            (s (drgnx-debug-heap--fit (format " +%d not shown " (plist-get cut :count)) (plist-get cut :width))))
        (when (< r height)
          (aset lines r (cons (list (plist-get cut :col)
                                    (concat (propertize s 'face 'drgnx-debug-heap-cut)
                                            (make-string (max 0 (- w (string-width s))) ?\s)))
                              (aref lines r))))))
    ;; written whole at each stop (the hub lays the grid out again; a card keeps its cells, so point and each window's
    ;; start are put back where they were)
    (let ((inhibit-read-only t) (at (point))
          (starts (mapcar (lambda (w) (cons w (window-start w))) (get-buffer-window-list nil nil t))))
      (erase-buffer)
      (insert (drgnx-debug-heap--header) "\n")
      (dotimes (r height)
        (let ((col 0))
          (dolist (piece (sort (aref lines r) (lambda (x y) (< (car x) (car y)))))
            (insert (make-string (max 0 (- (car piece) col)) ?\s) (cadr piece))
            (setq col (+ (car piece) (string-width (cadr piece)))))
          (insert (make-string (max 0 (- width col)) ?\s) "\n")))
      (goto-char (min at (point-max)))
      (pcase-dolist (`(,w . ,start) starts) (set-window-start w (min start (point-max)) t)))
    (drgnx-debug-heap--decorate faded)))

(defun drgnx-debug-heap--decorate (&optional faded)
  "The cards' rings (the selected one in the focus colour, FADED ones in the subtle border) and the references'
edges (the selected card's in the accent), for the windows that show the graph."
  (let* ((a drgnx-debug-heap--answer) (cw (frame-char-width)) (dy (/ (frame-char-height) 2))
         (sel drgnx-debug-heap--selected)
         (ring (lambda (card face)
                 (let ((r (plist-get card :row)) (c (plist-get card :col)) (w (plist-get card :width)))
                   `(ring ,(drgnx-debug-heap--cell r c)
                          ,(drgnx-debug-heap--cell (+ r (plist-get card :height) -1) (+ c w))
                          :x0 ,(* c cw) :x1 ,(* (+ c w) cw) :radius ,(drgnx-px 6) :ring ,face :beneath default))))
         (place (lambda (p) (list (drgnx-debug-heap--cell (aref p 1) (aref p 0)) 0 dy))))
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
  "The Graph tab goes with the module."
  (when-let* ((b (get-buffer drgnx-debug-heap-buffer-name))) (kill-buffer b)))

(provide 'drgnx-debug-heap)
;;; drgnx-debug-heap.el ends here
