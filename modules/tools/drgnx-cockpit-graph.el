;;; drgnx-cockpit-graph.el --- The Work graph: specs, plans, tasks, agents, jobs and reviews, drawn or as an outline -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The Work cockpit's home screen, from the cockpit's model only (core/drgnx-cockpit-model.el):
;; `drgnx-cockpit-graph-layout' puts the nodes in columns (`drgnx-cockpit-graph-columns') with their edges,
;; `drgnx-cockpit-graph-svg' draws them (SVG text; every colour from a face), and `drgnx-cockpit-graph-outline' gives
;; the same nodes as a tree of text lines, for terminal frames and windows too narrow for the drawing.  These are
;; functions of the model: no file is read, nothing prompts.  The pane, the redraws and the commands are in
;; drgnx-cockpit.el.  See docs/guide/cockpit.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-cockpit-model)
;; the SVG helpers (theme colours, font metrics) are the Work tab's: its file sits beside this one
(unless (featurep 'drgnx-work-ui)
  (load (expand-file-name "drgnx-work-ui" (file-name-directory (or load-file-name buffer-file-name))) nil t))

(declare-function drgnx-work-ui--colour "drgnx-work-ui")
(declare-function drgnx-face-glyph "drgnx-face")

(defvar drgnx-cockpit-graph--generation 0
  "Counts changes to the graph's options: a redraw after one draws even when the model is the same.")

(declare-function drgnx-cockpit-schedule "drgnx-cockpit")

(defun drgnx-cockpit-graph--set (symbol value)
  "Set SYMBOL to VALUE and draw the Work graph again (an option's `:set')."
  (set-default symbol value)
  (cl-incf drgnx-cockpit-graph--generation)
  (when (fboundp 'drgnx-cockpit-schedule) (drgnx-cockpit-schedule 0)))

(defcustom drgnx-cockpit-graph-columns '((spec) (plan) (task todo) (agent job review))
  "The Work graph's columns, left to right: each is a list of node kinds.
A kind no column lists goes in the last one; adding a column is adding a list."
  :type '(repeat (repeat symbol)) :set #'drgnx-cockpit-graph--set :group 'drgnx-cockpit)

(defcustom drgnx-cockpit-graph-svg t
  "Non-nil: the Work graph is drawn (SVG) in a graphical window wide enough for it; nil: always its outline."
  :type 'boolean :set #'drgnx-cockpit-graph--set :group 'drgnx-cockpit)

(defcustom drgnx-cockpit-graph-box-chars 32
  "The most characters a line of a box in the drawing shows; a longer title is cut (all of it shows on hover)."
  :type 'natnum :set #'drgnx-cockpit-graph--set :group 'drgnx-cockpit)

(defcustom drgnx-cockpit-graph-band-height 400
  "The drawing is made of images this many pixels tall, one under the other (at least 100).  A change draws again
only the bands it reaches, so shorter bands cost less per change; Emacs refuses one image over `max-image-size'."
  :type 'natnum :set #'drgnx-cockpit-graph--set :group 'drgnx-cockpit)

(defcustom drgnx-cockpit-graph-states
  '(("done" drgnx-cockpit-done ok) ("merged" drgnx-cockpit-done ok) ("pass" drgnx-cockpit-done ok)
    ("dropped" drgnx-cockpit-done circle) ("stopped" drgnx-cockpit-done paused) ("exited" drgnx-cockpit-done circle)
    ("not running" drgnx-cockpit-done circle)
    ("running" drgnx-cockpit-running dot) ("claimed" drgnx-cockpit-running dot) ("in-review" drgnx-cockpit-running dot)
    ("busy" drgnx-cockpit-running dot) ("starting" drgnx-cockpit-running dot) ("reporting" drgnx-cockpit-running dot)
    ("pending" drgnx-cockpit-blocked circle) ("needs-input" drgnx-cockpit-blocked warning)
    ("failed" drgnx-cockpit-blocked warning) ("fail" drgnx-cockpit-blocked warning)
    ("paused" drgnx-cockpit-blocked paused) ("not reporting" drgnx-cockpit-blocked circle))
  "How a node's state looks: STATE → (FACE GLYPH).  GLYPH names a glyph (ok, dot, circle, warning, paused, …).
A state not listed has no face and the glyph `circle'; a node waiting on you always has `drgnx-cockpit-waiting' and
the glyph `waiting'."
  :type '(alist :key-type string :value-type (list face symbol)) :set #'drgnx-cockpit-graph--set :group 'drgnx-cockpit)

(defface drgnx-cockpit-waiting '((t :inherit error))
  "A node waiting on you: its mark in the graph (and the timeline)." :group 'drgnx-cockpit)
(defface drgnx-cockpit-done '((t :inherit shadow)) "Done work in the graph: its mark and title." :group 'drgnx-cockpit)
(defface drgnx-cockpit-running '((t :inherit success)) "Work going on in the graph: its mark." :group 'drgnx-cockpit)
(defface drgnx-cockpit-blocked '((t :inherit warning))
  "Work that waits on other work or failed, in the graph: its mark; the blocks lines." :group 'drgnx-cockpit)
(defface drgnx-cockpit-edge '((t :inherit shadow))
  "The graph's lines between nodes, column titles and the details after a title." :group 'drgnx-cockpit)
(defface drgnx-cockpit-focus '((t :inherit highlight))
  "The node selected with TAB in the graph: the stroke round its box (its background colour)." :group 'drgnx-cockpit)
(defface drgnx-cockpit-kind '((t :inherit bold)) "The kind of a node in the graph: Spec, Plan, Job, TODO, Review."
  :group 'drgnx-cockpit)

;;;; Glyphs (`drgnx-face-glyph' when the face module is loaded)

(defconst drgnx-cockpit-graph--glyphs
  '((waiting "◐" . "?") (ok "✓" . "+") (dot "●" . "*") (circle "○" . "o") (warning "⚠" . "!") (paused "⏸" . "||")
    (tee "├ " . "|-") (last "└ " . "`-") (bar "│ " . "| ") (sep " · " . " | ") (from "← " . "<- "))
  "The graph's glyphs, NAME → (UNICODE . ASCII): those `drgnx-face-glyph' has come from it; the tree's are these.")

(defun drgnx-cockpit-graph--ascii-p (&optional frame)
  "Non-nil when FRAME (the selected one) is a terminal frame whose terminal does not write UTF-8."
  (and (not (display-graphic-p frame))
       (let ((coding (terminal-coding-system (frame-terminal frame))))
         (not (and coding (string-prefix-p "utf-8" (symbol-name (coding-system-base coding))))))))

(defun drgnx-cockpit-graph--glyph-table (&optional unicode)
  "NAME → glyph for the selected frame (UNICODE non-nil: the drawing's, always Unicode)."
  (let ((ascii (and (not unicode) (drgnx-cockpit-graph--ascii-p))))
    (mapcar (lambda (g)
              (cons (car g) (or (and (not unicode) (not (memq (car g) '(tee last bar from))) (fboundp 'drgnx-face-glyph)
                                     (drgnx-face-glyph (car g)))
                                (if ascii (cddr g) (cadr g)))))
            drgnx-cockpit-graph--glyphs)))

;;;; What every view needs from the model

(defconst drgnx-cockpit-graph--tree '((derives . to) (implements . to) (assigned . from) (reviewed-by . from))
  "Edge kinds that make the tree: whether an edge's :to or its :from is the parent.")

(defun drgnx-cockpit-graph--index (model)
  "Hash tables of MODEL for drawing it: (:byid :order :kids :parent :agents :reviews :needs :blocks :assigned-to).
:kids, :agents and :reviews map a node to its children, its agents' and its reviews' ids, in model order."
  (let ((ix (list :byid (make-hash-table :test #'equal) :order (make-hash-table :test #'equal)
                  :kids (make-hash-table :test #'equal) :parent (make-hash-table :test #'equal)
                  :agents (make-hash-table :test #'equal) :reviews (make-hash-table :test #'equal)
                  :needs (make-hash-table :test #'equal) :blocks (make-hash-table :test #'equal)
                  :assigned-to (make-hash-table :test #'equal)))
        (i 0))
    (dolist (n (plist-get model :nodes))
      (puthash (plist-get n :id) n (plist-get ix :byid))
      (puthash (plist-get n :id) (cl-incf i) (plist-get ix :order)))
    (let ((byid (plist-get ix :byid)))
      (dolist (e (reverse (plist-get model :edges)))
        (let* ((kind (plist-get e :kind)) (from (plist-get e :from)) (to (plist-get e :to))
               (up (alist-get kind drgnx-cockpit-graph--tree))
               (parent (pcase up ('to to) ('from from))) (child (pcase up ('to from) ('from to)))
               (ckind (plist-get (gethash child byid) :kind)))
          (pcase kind
            ('needs (push to (gethash from (plist-get ix :needs))))
            ('blocks (push to (gethash from (plist-get ix :blocks)))))
          (when (eq kind 'assigned) (push from (gethash to (plist-get ix :assigned-to))))
          (when up
            (puthash child t (plist-get ix :parent))
            (push child (gethash parent (plist-get ix (pcase ckind ('agent :agents) ('review :reviews) (_ :kids)))))))))
    ix))

(defun drgnx-cockpit-graph--column (kind)
  "The index of the column KIND goes in (`drgnx-cockpit-graph-columns'): the last one when no column lists it."
  (or (cl-position-if (lambda (col) (memq kind col)) drgnx-cockpit-graph-columns)
      (max 0 (1- (length drgnx-cockpit-graph-columns)))))

(defun drgnx-cockpit-graph--sorted (ids ix)
  "IDS by their column, then in the model's order."
  (let ((byid (plist-get ix :byid)) (order (plist-get ix :order)))
    (sort (copy-sequence ids)
          (lambda (a b)
            (let ((ca (drgnx-cockpit-graph--column (plist-get (gethash a byid) :kind)))
                  (cb (drgnx-cockpit-graph--column (plist-get (gethash b byid) :kind))))
              (if (= ca cb) (< (gethash a order 0) (gethash b order 0)) (< ca cb)))))))

(defun drgnx-cockpit-graph--style (node)
  "(FACE . GLYPH-NAME) of NODE: waiting on you first, else its state's (`drgnx-cockpit-graph-states')."
  (if (plist-get node :waiting) '(drgnx-cockpit-waiting . waiting)
    (let ((s (assoc (plist-get node :state) drgnx-cockpit-graph-states)))
      (if s (cons (nth 1 s) (nth 2 s)) '(nil . circle)))))

(defun drgnx-cockpit-graph--short (node)
  "A task's short name T<N> (its id ends in #N), else nil."
  (let ((id (plist-get node :id)))
    (and (eq (plist-get node :kind) 'task) (stringp id) (string-match "#\\([0-9]+\\)\\'" id)
         (concat "T" (match-string 1 id)))))

(defun drgnx-cockpit-graph--name (node)
  "NODE as other lines name it: a task's T<N>, else its title."
  (or (drgnx-cockpit-graph--short node) (format "%s" (or (plist-get node :title) (plist-get node :id)))))

(defun drgnx-cockpit-graph--kind-word (node)
  "The word before a node's title (Spec, Plan, Job, TODO, Review), or nil (tasks and agents have a mark instead)."
  (pcase (plist-get node :kind)
    ('spec "Spec") ('plan "Plan") ('job "Job") ('todo "TODO") ('review "Review") ('agent nil) ('task nil)
    (k (and k (capitalize (symbol-name k))))))

(defun drgnx-cockpit-graph--marked-p (node)
  "Whether NODE's line starts with its state's mark (tasks, agents and anything waiting on you)."
  (or (plist-get node :waiting) (memq (plist-get node :kind) '(task agent))))

(defun drgnx-cockpit-graph--details (node ix g)
  "The details after NODE's title, as propertized strings: waiting on you (first: a cut line keeps it), who works on
it, its review, its state."
  (let* ((byid (plist-get ix :byid)) (id (plist-get node :id)) (kind (plist-get node :kind))
         (state (plist-get node :state)) (out nil))
    (when (plist-get node :waiting) (push (propertize "waits on you" 'face 'drgnx-cockpit-waiting) out))
    (pcase kind
      ('plan (let* ((tasks (seq-filter (lambda (k) (eq (plist-get (gethash k byid) :kind) 'task)) (gethash id (plist-get ix :kids))))
                    (done (seq-count (lambda (k) (member (plist-get (gethash k byid) :state) '("done" "merged"))) tasks)))
               (when tasks (push (format "%d/%d done" done (length tasks)) out))))
      ('agent (push (format "%s" (or (plist-get node :reporting) "agent")) out)
              (when-let* ((tasks (gethash id (plist-get ix :assigned-to))))
                (push (mapconcat (lambda (t1) (drgnx-cockpit-graph--name (gethash t1 byid))) tasks ", ") out))
              (when (plist-get node :label) (push (format "%s" (plist-get node :label)) out))))
    (when-let* ((agents (gethash id (plist-get ix :agents))))
      (push (concat (alist-get 'from g) (mapconcat (lambda (a) (drgnx-cockpit-graph--name (gethash a byid))) agents ", ")) out))
    (dolist (r (gethash id (plist-get ix :reviews)))
      (let ((rn (gethash r byid)))
        (push (propertize (format "review: %s" (or (plist-get rn :state) "")) 'face (car (drgnx-cockpit-graph--style rn))) out)))
    ;; the state, unless it says nothing (open, ready) or the mark says it already (✓ done)
    (when (and state (not (member state '("open" "ready"))) (not (eq kind 'plan))
               (not (and (drgnx-cockpit-graph--marked-p node) (member state '("done" "merged")))))
      (push (format "%s" state) out))
    (nreverse out)))

(defun drgnx-cockpit-graph-summary (model &optional g)
  "One line on MODEL: how many nodes wait on you (in `drgnx-cockpit-waiting'), agents and jobs.  G: the glyphs."
  (let* ((g (or g (drgnx-cockpit-graph--glyph-table)))
         (nodes (plist-get model :nodes))
         (waiting (seq-count (lambda (n) (plist-get n :waiting)) nodes))
         (agents (seq-count (lambda (n) (eq (plist-get n :kind) 'agent)) nodes))
         (jobs (seq-count (lambda (n) (eq (plist-get n :kind) 'job)) nodes)))
    (string-join
     (delq nil (list (and (> waiting 0)
                          (propertize (format "%s %d waiting on you" (alist-get 'waiting g) waiting) 'face 'drgnx-cockpit-waiting))
                     (format "%d agent%s" agents (if (= agents 1) "" "s"))
                     (format "%d job%s" jobs (if (= jobs 1) "" "s"))))
     (alist-get 'sep g))))

;;;; The outline (terminal frames, narrow windows)

(defun drgnx-cockpit-graph--label (node ix g)
  "NODE's line without its tree prefix: its mark, kind, T<N>, title, then its details."
  (pcase-let* ((`(,face . ,glyph) (drgnx-cockpit-graph--style node))
               (word (drgnx-cockpit-graph--kind-word node))
               (short (drgnx-cockpit-graph--short node))
               (title (format "%s" (or (plist-get node :title) (plist-get node :id))))
               (details (drgnx-cockpit-graph--details node ix g)))
    (concat (if (drgnx-cockpit-graph--marked-p node) (concat (propertize (alist-get glyph g) 'face face) " ") "")
            (if word (concat (propertize word 'face 'drgnx-cockpit-kind) " ") "")
            (if short (concat short " ") "")
            (if (eq face 'drgnx-cockpit-done) (propertize title 'face 'drgnx-cockpit-done) title)
            (if details
                (concat "  " (mapconcat (lambda (d) (if (get-text-property 0 'face d) d (propertize d 'face 'drgnx-cockpit-edge)))
                                        details (propertize (alist-get 'sep g) 'face 'drgnx-cockpit-edge)))
              ""))))

(defun drgnx-cockpit-graph--deps-lines (node ix g prefix)
  "NODE's needs and blocks lines, each starting with PREFIX and its tree glyph."
  (let* ((byid (plist-get ix :byid)) (id (plist-get node :id))
         (needs (drgnx-cockpit-graph--sorted (gethash id (plist-get ix :needs)) ix))
         (blocks (drgnx-cockpit-graph--sorted (gethash id (plist-get ix :blocks)) ix))
         (lines (delq nil
                      (list (and needs
                                 (concat (propertize "needs: " 'face 'drgnx-cockpit-edge)
                                         (mapconcat (lambda (d) (let ((dn (gethash d byid)))
                                                                  (concat (drgnx-cockpit-graph--name dn)
                                                                          (if (member (plist-get dn :state) '("done" "merged"))
                                                                              (concat " " (propertize (alist-get 'ok g) 'face 'drgnx-cockpit-done))
                                                                            ""))))
                                                    needs ", ")))
                            (and blocks
                                 (concat (propertize "blocks: " 'face 'drgnx-cockpit-blocked)
                                         (mapconcat (lambda (d) (drgnx-cockpit-graph--name (gethash d byid))) blocks ", ")))))))
    (cl-loop for l in lines for rest on lines
             collect (propertize (concat prefix (alist-get (if (cdr rest) 'tee 'last) g) l) 'drgnx-cockpit-node id))))

(defun drgnx-cockpit-graph-outline (model)
  "MODEL (`drgnx-cockpit-model', filtered or not) as the Work graph's text: a list of propertized lines.
A summary (what waits on you, agents, jobs), then the nodes as a tree — spec › plan › its tasks, TODOs and jobs, a
task's agents and review on its line, then its needs and blocks — then the agents.  Every node's line carries
`drgnx-cockpit-node' (its id).  The same information as the drawing, for terminal frames and narrow windows."
  (let* ((g (drgnx-cockpit-graph--glyph-table))
         (ix (drgnx-cockpit-graph--index model))
         (byid (plist-get ix :byid))
         (nodes (plist-get model :nodes))
         (seen (make-hash-table :test #'equal))
         (out nil))
    (cl-labels ((walk (id prefix child-prefix)
                  (unless (gethash id seen)
                    (puthash id t seen)
                    (let* ((n (gethash id byid))
                           (kids (drgnx-cockpit-graph--sorted (seq-remove (lambda (k) (gethash k seen)) (gethash id (plist-get ix :kids))) ix))
                           (deps (drgnx-cockpit-graph--deps-lines n ix g child-prefix)))
                      (push (propertize (concat prefix (drgnx-cockpit-graph--label n ix g)) 'drgnx-cockpit-node id) out)
                      ;; the dependency lines sit under their task, before any child
                      (dolist (d deps) (push (if kids (concat (substring d 0 (length child-prefix)) (alist-get 'bar g)
                                                              (substring d (length child-prefix)))
                                               d)
                                             out))
                      (cl-loop for k in kids for rest on kids
                               do (walk k (concat child-prefix (alist-get (if (cdr rest) 'tee 'last) g))
                                        (concat child-prefix (if (cdr rest) (alist-get 'bar g) "  "))))))))
      (if (null nodes)
          (list (propertize "Nothing to show yet: specs, plans and jobs appear here as the work tracker and agents report them."
                            'face 'drgnx-cockpit-edge))
        (push (drgnx-cockpit-graph-summary model g) out)
        (dolist (id (drgnx-cockpit-graph--sorted
                     (delq nil (mapcar (lambda (n) (let ((id (plist-get n :id)))
                                                     (and (not (gethash id (plist-get ix :parent))) (not (eq (plist-get n :kind) 'agent)) id)))
                                       nodes))
                     ix))
          (walk id "" ""))
        (let ((agents (seq-filter (lambda (n) (eq (plist-get n :kind) 'agent)) nodes)))
          (when agents
            (push "" out)
            (push (propertize "AGENTS" 'face 'drgnx-cockpit-edge) out)
            (dolist (a agents)
              (push (propertize (concat "  " (drgnx-cockpit-graph--label a ix g)) 'drgnx-cockpit-node (plist-get a :id)) out))))
        (nreverse out)))))

;;;; The drawing (graphical windows)

(defun drgnx-cockpit-graph--cut (s n)
  "S cut to N characters (a cut ends in …)."
  (if (> (string-width s) n) (truncate-string-to-width s n nil nil "…") s))

(defun drgnx-cockpit-graph--box-lines (node ix g)
  "NODE's two lines in a box: (MARK TITLE-LINE DETAILS-LINE), plain text cut to `drgnx-cockpit-graph-box-chars'.
MARK is nil where the outline has none (`drgnx-cockpit-graph--marked-p'); the details line starts with its kind.
G: the drawing's glyphs (`drgnx-cockpit-graph--glyph-table', once per layout)."
  (let* ((n drgnx-cockpit-graph-box-chars)
         (mark (and (drgnx-cockpit-graph--marked-p node) (alist-get (cdr (drgnx-cockpit-graph--style node)) g)))
         (short (drgnx-cockpit-graph--short node))
         (title (format "%s" (or (plist-get node :title) (plist-get node :id))))
         (details (mapcar #'substring-no-properties (drgnx-cockpit-graph--details node ix g))))
    (list mark
          (drgnx-cockpit-graph--cut (concat (if short (concat short " ") "") title) (max 4 (if mark (- n 2) n)))
          (drgnx-cockpit-graph--cut (string-join (delq nil (cons (drgnx-cockpit-graph--kind-word node) details)) (alist-get 'sep g))
                                    n))))

(defun drgnx-cockpit-graph-layout (model metrics)
  "MODEL's nodes as boxes in the columns of `drgnx-cockpit-graph-columns', with MODEL's edges between them.
METRICS: (CHAR-WIDTH . LINE-HEIGHT) in pixels (`drgnx-work-ui--metrics').  Returns (:boxes BOXES :edges EDGES :w W
:h H :titles ((X . TITLE)…) :metrics METRICS).  A box is (:id :node :col :lines (MARK TITLE DETAILS) :x :y :w :h);
an edge (:from ID :to ID :kind KIND).  A box sits level with the nodes it joins in the columns before it, then a
parent moves to the middle of what it joins after it; in a column boxes never overlap."
  (let* ((cw (car metrics)) (lh (cdr metrics)) (pad (/ lh 2)) (vgap (/ lh 2)) (hgap (* 5 cw))
         (ncol (max 1 (length drgnx-cockpit-graph-columns)))
         (top (* 2 lh)) (bh (+ (* 2 lh) (* 2 pad)))
         (ix (drgnx-cockpit-graph--index model))
         (g (drgnx-cockpit-graph--glyph-table t))
         (boxes (make-hash-table :test #'equal)) (cols (make-vector ncol nil))
         (near (make-hash-table :test #'equal)) (edges nil))
    (dolist (n (plist-get model :nodes))
      (let* ((col (drgnx-cockpit-graph--column (plist-get n :kind)))
             (b (list :id (plist-get n :id) :node n :col col :lines (drgnx-cockpit-graph--box-lines n ix g) :x 0 :y 0 :w 0 :h bh)))
        (puthash (plist-get n :id) b boxes)
        (push b (aref cols col))))
    (dotimes (c ncol) (aset cols c (nreverse (aref cols c))))
    (dolist (e (plist-get model :edges))
      (let ((a (gethash (plist-get e :from) boxes)) (b (gethash (plist-get e :to) boxes)))
        (when (and a b)
          (push (list :from (plist-get e :from) :to (plist-get e :to) :kind (plist-get e :kind)) edges)
          (unless (memq (plist-get e :kind) '(needs blocks))
            (push b (gethash (plist-get a :id) near))
            (push a (gethash (plist-get b :id) near))))))
    ;; widths, then x: an empty column takes no room
    (let ((x hgap) (titles nil))
      (dotimes (c ncol)
        (when-let* ((bs (aref cols c)))
          (let ((w (+ (* 2 pad) (* cw (+ 2 (apply #'max (mapcar (lambda (b) (apply #'max (mapcar #'string-width (cdr (plist-get b :lines)))))
                                                                bs)))))))
            (dolist (b bs) (plist-put b :x x) (plist-put b :w w))
            (push (cons x (upcase (mapconcat (lambda (k) (concat (symbol-name k) "s"))
                                             (seq-uniq (mapcar (lambda (b) (plist-get (plist-get b :node) :kind)) bs))
                                             " · ")))
                  titles)
            (setq x (+ x w hgap)))))
      (cl-flet* ((centre (b) (+ (plist-get b :y) (/ (plist-get b :h) 2)))
                 (want (b pred) (let ((ns (seq-filter pred (gethash (plist-get b :id) near))))
                                  (and ns (/ (apply #'+ (mapcar #'centre ns)) (length ns)))))
                 ;; PAIRS ((BOX . WANTED-CENTRE-OR-NIL)…), in order, one under the other: boxes that want the same
                 ;; centre (a parent's children) as a block around it, each as near its wish as the room above allows
                 (stack (pairs)
                   (let ((cursor top))
                     (while pairs
                       (let* ((w (cdar pairs)) (block (list (car (pop pairs)))))
                         (while (and w pairs (eql (cdar pairs) w)) (push (car (pop pairs)) block))
                         (let ((y (if w (max cursor (- w (/ (- (* (length block) (+ bh vgap)) vgap) 2))) cursor)))
                           (dolist (b (nreverse block)) (plist-put b :y y) (setq y (+ y bh vgap)))
                           (setq cursor y))))))
                 ;; left to right from column FROM: each level with what it joins in the columns before it
                 (forward (from)
                   (cl-loop for c from from below ncol
                            do (let* ((pairs (mapcar (lambda (b) (cons b (want b (lambda (o) (< (plist-get o :col) c))))) (aref cols c)))
                                      (joined (seq-filter #'cdr pairs)) (alone (seq-remove #'cdr pairs)))
                                 (stack (append (sort joined (lambda (p q) (< (cdr p) (cdr q)))) alone))))))
        (forward 0)
        ;; right to left: a parent to the middle of what it joins after it…
        (cl-loop for c from (- ncol 2) downto 0
                 do (let ((bs (sort (copy-sequence (aref cols c)) (lambda (p q) (< (plist-get p :y) (plist-get q :y))))))
                      (stack (mapcar (lambda (b) (cons b (or (want b (lambda (o) (> (plist-get o :col) c))) (centre b)))) bs))))
        ;; …then its children around it again, and what joins them
        (forward 1))
      (let ((h (+ vgap (apply #'max top (mapcar (lambda (c) (apply #'max 0 (mapcar (lambda (b) (+ (plist-get b :y) bh)) c))) cols)))))
        (list :boxes (apply #'append (append cols nil)) :edges (nreverse edges) :w x :h h :titles (nreverse titles)
              :metrics metrics)))))

(defun drgnx-cockpit-graph--colours ()
  "Alist FACE → its colour as SVG takes it (#rrggbb, or currentColor: the image's foreground), for every face the
drawing uses, plus `default' (its foreground) and `background' (the default background, or none)."
  (append (mapcar (lambda (f) (cons f (drgnx-work-ui--colour f :foreground)))
                  '(default drgnx-cockpit-waiting drgnx-cockpit-done drgnx-cockpit-running drgnx-cockpit-blocked drgnx-cockpit-edge))
          (list (cons 'background (let ((c (drgnx-work-ui--colour 'default :background))) (if (equal c "currentColor") "none" c))))))

(defvar drgnx-cockpit-graph--encoded (make-hash-table :test #'equal)
  "Text → its SVG form (`drgnx-cockpit-graph--encode'): the titles and details of one redraw are mostly the last
one's.  Bounded: emptied when it holds 4096 texts.")

(defun drgnx-cockpit-graph--encode (text)
  "TEXT as SVG text: &, < and > escaped, every character past ASCII as &#N; (what svg.el does, in one pass)."
  (if (not (string-match-p "[&<>[:nonascii:]]" text)) text
    (or (gethash text drgnx-cockpit-graph--encoded)
        (progn
          (when (>= (hash-table-count drgnx-cockpit-graph--encoded) 4096) (clrhash drgnx-cockpit-graph--encoded))
          (puthash text (replace-regexp-in-string "[&<>]\\|[^[:ascii:]]"
                                                  (lambda (m) (pcase m ("&" "&amp;") ("<" "&lt;") (">" "&gt;") (_ (format "&#%d;" (aref m 0)))))
                                                  text t t)
                   drgnx-cockpit-graph--encoded)))))

(defun drgnx-cockpit-graph--tag (tag attrs &optional text)
  "The SVG text of element TAG (a symbol) with ATTRS ((NAME . VALUE)…) and TEXT."
  (concat "<" (symbol-name tag)
          (mapconcat (lambda (a) (let ((v (cdr a))) (concat " " (symbol-name (car a)) "=\"" (if (numberp v) (number-to-string v) v) "\"")))
                     attrs "")
          (if text (concat ">" (drgnx-cockpit-graph--encode text) "</" (symbol-name tag) ">") "/>")))

(defun drgnx-cockpit-graph--elements (layout)
  "LAYOUT's SVG elements in drawing order — column titles, edges, then boxes over them — each (YMIN YMAX ELEMENT),
ELEMENT its SVG text, written once for every band it reaches into.  Every colour comes from a face
\(`drgnx-cockpit-graph--colours')."
  (let* ((cw (car (plist-get layout :metrics))) (lh (cdr (plist-get layout :metrics))) (pad (/ lh 2))
         (col (drgnx-cockpit-graph--colours))
         (c (lambda (face) (or (alist-get face col) (alist-get 'default col))))
         (byid (make-hash-table :test #'equal))
         (blocking (make-hash-table :test #'equal))
         ;; column → t when it has boxes
         (cols (let ((v (make-vector (1+ (apply #'max 0 (mapcar (lambda (b) (plist-get b :col)) (plist-get layout :boxes)))) nil)))
                 (dolist (b (plist-get layout :boxes)) (aset v (plist-get b :col) t))
                 v))
         (out nil))
    (cl-flet ((el (ymin ymax tag attrs &optional text)
                (push (list ymin ymax (drgnx-cockpit-graph--tag tag attrs text)) out)))
      (dolist (b (plist-get layout :boxes)) (puthash (plist-get b :id) b byid))
      (dolist (e (plist-get layout :edges))
        (when (eq (plist-get e :kind) 'blocks) (puthash (cons (plist-get e :to) (plist-get e :from)) t blocking)))
      (pcase-dolist (`(,x . ,title) (plist-get layout :titles))
        (el 0 (* 2 lh) 'text `((x . ,x) (y . ,lh) (fill . ,(funcall c 'drgnx-cockpit-edge)) (font-size . ,(round (* lh 0.65)))
                               (letter-spacing . 1))
            title))
      ;; edges first: the boxes are drawn over them
      (dolist (e (plist-get layout :edges))
        (let* ((a (gethash (plist-get e :from) byid)) (b (gethash (plist-get e :to) byid)))
          (unless (eq (plist-get e :kind) 'blocks)              ; drawn with its needs edge
            (let ((ya (+ (plist-get a :y) (/ (plist-get a :h) 2))) (yb (+ (plist-get b :y) (/ (plist-get b :h) 2))))
              (if (= (plist-get a :col) (plist-get b :col))
                  ;; in one column (a task needs another): a dashed arc on its right, in the blocked face while it blocks
                  (let* ((x (+ (plist-get a :x) (plist-get a :w))) (d (min (* 2 cw) (+ cw (/ (abs (- yb ya)) 8)))))
                    (el (min ya yb) (max ya yb) 'path
                        `((d . ,(format "M%d,%d C%d,%d %d,%d %d,%d" x ya (+ x d) ya (+ x d) yb x yb)) (fill . "none")
                          (stroke . ,(funcall c (if (gethash (cons (plist-get e :from) (plist-get e :to)) blocking)
                                                    'drgnx-cockpit-blocked 'drgnx-cockpit-edge)))
                          (stroke-width . 1.2) (stroke-dasharray . "3,3"))))
                (let* ((l (if (< (plist-get a :col) (plist-get b :col)) a b)) (r (if (eq l a) b a))
                       (x1 (+ (plist-get l :x) (plist-get l :w))) (y1 (if (eq l a) ya yb))
                       (x2 (plist-get r :x)) (y2 (if (eq l a) yb ya)) (mx (/ (+ x1 x2) 2))
                       (between (seq-filter (lambda (k) (and (aref cols k) (< (plist-get l :col) k (plist-get r :col))))
                                            (number-sequence 0 (1- (length cols))))))
                  ;; an edge past a column (a job to its plan) is not drawn: behind that column's boxes it would seem to
                  ;; come out of one of them, and the job's tasks join it to the plan already (an agent on a plan
                  ;; shows on the plan's box, ← NAME)
                  (unless between
                    (el (min y1 y2) (max y1 y2) 'path
                        `((d . ,(format "M%d,%d C%d,%d %d,%d %d,%d" x1 y1 mx y1 mx y2 x2 y2)) (fill . "none")
                          (stroke . ,(funcall c 'drgnx-cockpit-edge)) (stroke-width . 1.2))))))))))
      (dolist (b (plist-get layout :boxes))
        (pcase-let* ((n (plist-get b :node)) (`(,face . ,_) (drgnx-cockpit-graph--style n))
                     (`(,mark ,title ,details) (plist-get b :lines))
                     (x (plist-get b :x)) (y (plist-get b :y)) (w (plist-get b :w)) (h (plist-get b :h))
                     (base (+ y pad (round (* lh 0.8)))))
          (el y (+ y h) 'rect `((x . ,x) (y . ,y) (width . ,w) (height . ,h) (rx . ,(/ pad 2)) (fill . ,(alist-get 'background col))
                                (stroke . ,(funcall c (or face 'drgnx-cockpit-edge))) (stroke-width . ,(if (plist-get n :waiting) 2 1))
                                (stroke-dasharray . ,(if (and (plist-get n :readonly) (eq (plist-get n :kind) 'task)) "4,3" "none"))))
          (when mark (el y (+ y h) 'text `((x . ,(+ x pad)) (y . ,base) (fill . ,(funcall c (or face 'drgnx-cockpit-edge)))) mark))
          (el y (+ y h) 'text `((x . ,(+ x pad (if mark (* 2 cw) 0))) (y . ,base)
                                (fill . ,(funcall c (if (eq face 'drgnx-cockpit-done) face 'default)))
                                (font-weight . ,(if (memq (plist-get n :kind) '(spec plan)) "bold" "normal")))
              title)
          (el y (+ y h) 'text `((x . ,(+ x pad)) (y . ,(+ base lh)) (fill . ,(funcall c 'drgnx-cockpit-edge))) details)
          (when (plist-get n :waiting)          ; the red dot
            (el y (+ y h) 'circle `((cx . ,(- (+ x w) (/ lh 3))) (cy . ,(+ y (/ lh 3))) (r . ,(max 2 (/ lh 5)))
                                    (fill . ,(funcall c 'drgnx-cockpit-waiting))))))))
    (nreverse out)))

(defun drgnx-cockpit-graph--print (layout elements y0 h)
  "The SVG text of ELEMENTS (`drgnx-cockpit-graph--elements' of LAYOUT) seen through the band from Y0, H pixels
tall: only the elements that reach into it."
  (let* ((lh (cdr (plist-get layout :metrics))) (w (plist-get layout :w)) (y1 (+ y0 h))
         (fam (let ((f (face-attribute 'default :family nil t))) (if (and (stringp f) (not (string-prefix-p "unspecified" f))) f "monospace"))))
    (with-temp-buffer
      (insert (substring (drgnx-cockpit-graph--tag 'svg `((width . ,w) (height . ,h) (version . "1.1") (xmlns . "http://www.w3.org/2000/svg")
                                                          (viewBox . ,(format "0 %d %d %d" y0 w h)) (font-family . ,fam)
                                                          (font-size . ,(round (* lh 0.75)))))
                         0 -2)
              ">")
      (pcase-dolist (`(,ymin ,ymax ,e) elements) (when (and (<= ymin y1) (>= ymax y0)) (insert e)))
      (insert "</svg>")
      (buffer-string))))

(defun drgnx-cockpit-graph-svg (layout)
  "The SVG text of LAYOUT (`drgnx-cockpit-graph-layout'), in the theme's colours."
  (drgnx-cockpit-graph--print layout (drgnx-cockpit-graph--elements layout) 0 (plist-get layout :h)))

(defun drgnx-cockpit-graph-focus-element (layout id)
  "The focus stroke round box ID of LAYOUT, as an element of `drgnx-cockpit-graph--elements' (in the background
colour of `drgnx-cockpit-focus', else its foreground), or nil when LAYOUT has no such box."
  (when-let* ((b (seq-find (lambda (b) (equal (plist-get b :id) id)) (plist-get layout :boxes))))
    (let* ((y (- (plist-get b :y) 3)) (h (+ (plist-get b :h) 6))
           (bg (drgnx-work-ui--colour 'drgnx-cockpit-focus :background))
           (colour (if (equal bg "currentColor") (drgnx-work-ui--colour 'drgnx-cockpit-focus :foreground) bg)))
      (list y (+ y h) (drgnx-cockpit-graph--tag 'rect `((x . ,(- (plist-get b :x) 3)) (y . ,y) (width . ,(+ (plist-get b :w) 6))
                                                        (height . ,h) (rx . 5) (fill . "none") (stroke . ,colour)
                                                        (stroke-width . 3)))))))

(defun drgnx-cockpit-graph-band-ranges (layout)
  "The bands LAYOUT is drawn in: ((Y0 HEIGHT)…), none taller than `drgnx-cockpit-graph-band-height'."
  (let ((h (plist-get layout :h)) (band (max 100 drgnx-cockpit-graph-band-height)))
    (cl-loop for y0 from 0 below h by band collect (list y0 (min band (- h y0))))))

(defun drgnx-cockpit-graph-bands (layout &optional elements)
  "LAYOUT drawn as bands (`drgnx-cockpit-graph-band-ranges'): ((Y0 HEIGHT SVG-TEXT)…), each a window (viewBox) on the
same drawing with the ELEMENTS (default: `drgnx-cockpit-graph--elements' of LAYOUT) that reach into it, so lines
cross from one band into the next."
  (let ((elements (or elements (drgnx-cockpit-graph--elements layout))))
    (mapcar (lambda (r) (list (car r) (cadr r) (drgnx-cockpit-graph--print layout elements (car r) (cadr r))))
            (drgnx-cockpit-graph-band-ranges layout))))

(provide 'drgnx-cockpit-graph)
;;; drgnx-cockpit-graph.el ends here
