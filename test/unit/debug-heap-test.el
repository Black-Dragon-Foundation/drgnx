;;; debug-heap-test.el --- batch tests: the heap graph's cards, rings and edges -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; The hub's `debug/heap' answers and `debug-heap' pushes are made here (the shape debug/heap_wire.rs sends, arrays as
;; vectors); what the Graph tab asks of the hub is recorded.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "modules/extra/drgnx-debug" drgnx-dir) nil t)

(defun debug-heap-test--node (id type path &rest fields)
  (list :id id :type type :path path
        :fields (vconcat (mapcar (lambda (f) (append (list :name (nth 0 f) :value (nth 1 f))
                                                     (and (nth 2 f) (list :to (nth 2 f)))))
                                 fields))))

(defun debug-heap-test--answer (&optional second)
  "A ring a → b → c → a, with `spare' to d; SECOND: the next stop's, b's qty changed, d gone and e new."
  (list :graph "g1" :session "s1" :expr "a" :node "a" :cut (if second 40 0)
        :nodes (vconcat
                (list (apply #'debug-heap-test--node "a" "Node" "a"
                             (append '(("sku" "'nut-m6'") ("qty" "20") ("next" "<Node>" "b"))
                                     (if second '(("spare" "<Node>" "e")) '(("spare" "<Node>" "d")))))
                      (debug-heap-test--node "b" "Node" "a.next" '("sku" "'bolt-m4'")
                                             (list "qty" (if second "3" "5")) '("next" "<Node>" "c"))
                      (debug-heap-test--node "c" "Node" "a.next.next" '("sku" "'washer-8'") '("qty" "0")
                                             '("next" "<Node>" "a"))
                      (if second (debug-heap-test--node "e" "Node" "a.spare" '("sku" "'pin-9'"))
                        (debug-heap-test--node "d" "Node" "a.spare" '("sku" "'pin-2'")))))
        :cards (vconcat (list (list :id "a" :col 3 :row 2 :width 16 :height 5)
                              (list :id "b" :col 25 :row 2 :width 16 :height 4)
                              (list :id "c" :col 47 :row 2 :width 16 :height 4)
                              (list :id (if second "e" "d") :col 25 :row (if second 12 8) :width 16 :height 2)))
        :edges (vconcat (list (list :from "a" :field 2 :to "b" :points [[19 5] [23 5] [23 2] [25 2]])
                              (list :from "b" :field 2 :to "c" :points [[41 5] [45 5] [45 2] [47 2]])
                              (list :from "c" :field 2 :to "a" :points [[63 5] [65 5] [65 0] [1 0] [1 2] [3 2]])
                              (list :from "a" :field 3 :to (if second "e" "d")
                                    :points (if second [[19 6] [23 6] [23 12] [25 12]] [[19 6] [23 6] [23 8] [25 8]]))))
        :width 68 :height (if second 15 11)
        :added (if second ["e"] []) :changed (if second ["b"] []) :gone (if second ["d"] [])))

(defmacro debug-heap-test--with (&rest body)
  "BODY with the hub's calls on the events connection recorded in CALLS (newest first) as (METHOD PARAMS CALLBACK),
a stopped session s1, and the Graph buffer killed after."
  (declare (indent 0))
  `(let ((calls nil) (drgnx-hub--events nil)
         (drgnx-debug--sessions (list (list :id "s1" :name "Python: app" :state "stopped"))))
     (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
               ((symbol-function 'drgnx-hub--call-on)
                (lambda (_conn method params cb &rest _) (push (list method params cb) calls) 1))
               ((symbol-function 'drgnx-wb-area-show) #'ignore))
       (unwind-protect (progn ,@body)
         (when (get-buffer drgnx-debug-heap-buffer-name)
           (kill-buffer drgnx-debug-heap-buffer-name))))))

(defmacro debug-heap-test--open ()
  "Open a's graph and answer it with the first stop's (CALLS: `debug-heap-test--with''s)."
  '(progn (drgnx-debug-heap-open "s1" "a")
          (funcall (nth 2 (car calls)) (debug-heap-test--answer) nil)))

(defun debug-heap-test--at (id k)
  "Where card ID's row K (0: its title) starts, or nil."
  (with-current-buffer drgnx-debug-heap-buffer-name
    (let ((card (drgnx-debug-heap--card id)) (found nil))
      (when card
        (save-excursion
          (goto-char (drgnx-debug-heap--line (+ (plist-get card :row) k)))
          (while (and (not found) (< (point) (line-end-position)))
            (if (equal (get-text-property (point) 'drgnx-debug-heap-card) id) (setq found (point)) (forward-char)))))
      found)))

(defun debug-heap-test--row (id k)
  "The text of card ID's row K (0: its title): its stretches read as spaces."
  (with-current-buffer drgnx-debug-heap-buffer-name
    (let ((at (debug-heap-test--at id k)))
      (and at (let ((eol (save-excursion (goto-char at) (line-end-position))))
                (buffer-substring-no-properties at (next-single-property-change at 'drgnx-debug-heap-card nil eol)))))))

(defun debug-heap-test--find (beg end prop value)
  "The first position from BEG to END whose PROP is `equal' to VALUE, or nil."
  (while (and (< beg end) (not (equal (get-text-property beg prop) value))) (setq beg (1+ beg)))
  (and (< beg end) beg))

(defun debug-heap-test--face-p (face pos)
  (memq face (ensure-list (get-text-property pos 'face))))

(defun debug-heap-test--head ()
  (with-current-buffer drgnx-debug-heap-buffer-name (substring-no-properties drgnx-debug-heap--head)))

(ert-deftest drgnx-debug-heap/opens-on-the-events-connection-and-closes-with-the-tab ()
  "Show as Graph asks `debug/heap' for the session's expression on the connection the hub pushes `debug-heap' to;
killing the Graph tab's buffer sends `debug/heap/close'."
  (debug-heap-test--with
    (debug-heap-test--open)
    (should (equal (nth 0 (car (last calls))) "debug/heap"))
    (should (equal (nth 1 (car (last calls))) (list :session "s1" :expr "a")))
    (kill-buffer drgnx-debug-heap-buffer-name)
    (should (equal (butlast (car calls)) (list "debug/heap/close" (list :graph "g1"))))))

(ert-deftest drgnx-debug-heap/a-card-is-its-name-and-type-then-its-fields-at-its-cells ()
  "Each card sits at its cells: its title (the name that reached it in the UI heading face, then its type, subtle),
then a row per field, the name left and the value right (a reference shows its target's type in the UI caption
face), each row's end aligned to the card's right edge."
  (debug-heap-test--with
    (debug-heap-test--open)
    (should (equal (debug-heap-test--row "a" 0) " a Node "))
    (should (equal (debug-heap-test--row "b" 0) " a.next Node "))
    (should (equal (debug-heap-test--row "a" 1) " sku 'nut-m6' "))
    (should (equal (debug-heap-test--row "a" 3) " next Node "))
    (should (equal (debug-heap-test--row "b" 2) " qty 5 "))
    (let ((title (debug-heap-test--at "a" 0)) (next (debug-heap-test--at "a" 3)))
      (with-current-buffer drgnx-debug-heap-buffer-name
        (should (debug-heap-test--face-p 'drgnx-debug-heap-title (1+ title)))
        (should (debug-heap-test--face-p 'drgnx-debug-heap-type (+ title 3)))
        (should (debug-heap-test--face-p 'drgnx-debug-heap-name (1+ next)))
        (should (debug-heap-test--face-p 'drgnx-debug-heap-reference (+ next 6)))
        ;; the card starts at its column and its rows end at its right edge (col 3, 16 wide)
        (should (equal (get-text-property (1- title) 'display) '(space :align-to 3)))
        (should (equal (get-text-property (+ next 10) 'display) '(space :align-to 19)))
        (should-not (get-text-property (1- title) 'drgnx-debug-heap-card))))))

(ert-deftest drgnx-debug-heap/more-than-eight-fields-end-in-a-more-row ()
  "A card shows 8 fields, then \"+N more\"."
  (debug-heap-test--with
    (drgnx-debug-heap-open "s1" "big")
    (funcall (nth 2 (car calls))
             (list :graph "g2" :session "s1" :expr "big" :node "x" :cut 0
                   :nodes (vector (apply #'debug-heap-test--node "x" "Big" "big"
                                         (mapcar (lambda (i) (list (format "f%d" i) (number-to-string i)))
                                                 (number-sequence 1 11))))
                   :cards (vector (list :id "x" :col 3 :row 0 :width 12 :height 10)) :edges []
                   :width 18 :height 11 :added [] :changed [] :gone [])
             nil)
    (should (equal (debug-heap-test--row "x" 8) " f8 8 "))
    (should (equal (debug-heap-test--row "x" 9) " +3 more "))))

(ert-deftest drgnx-debug-heap/each-card-is-a-ring-and-each-reference-an-edge ()
  "The cards are Glitnir rings over their cells (the border, radius 6) and the references Glitnir edges from the
field's row to the target's type row, through the hub's bends, with an arrowhead, in the subtle colour; the
selected card (the root at first) is ringed in the focus colour and its edges take the accent."
  (debug-heap-test--with
    (debug-heap-test--open)
    (with-current-buffer drgnx-debug-heap-buffer-name
      (let* ((cw (frame-char-width)) (blocks drgnx-debug-heap--blocks) (edges drgnx-debug-heap--edges)
             (ring (lambda (id) (seq-find (lambda (b) (= (plist-get (nthcdr 3 b) :x0)
                                                         (* cw (plist-get (drgnx-debug-heap--card id) :col))))
                                          drgnx-debug-heap--blocks))))
        (should (= (length blocks) 4))
        (should (eq (car (funcall ring "b")) 'ring))
        (should (= (plist-get (nthcdr 3 (funcall ring "b")) :x0) (* 25 cw)))
        (should (= (plist-get (nthcdr 3 (funcall ring "b")) :x1) (* 41 cw)))
        ;; its rows: 2 to 5 (END is the start of the line after)
        (should (= (nth 1 (funcall ring "b")) (drgnx-debug-heap--line 2)))
        (should (= (nth 2 (funcall ring "b")) (drgnx-debug-heap--line 6)))
        (should (eq (plist-get (nthcdr 3 (funcall ring "b")) :ring) 'drgnx-border))
        (should (eq (plist-get (nthcdr 3 (funcall ring "a")) :ring) 'drgnx-focus-line))
        (should (= (length edges) 4))
        (let ((b->c (nth 1 edges)) (dy (/ (frame-char-height) 2)))
          ;; a place is its line's start and the cell's pixels across
          (should (equal (nth 0 b->c) (list (drgnx-debug-heap--line 5) (* 41 cw) dy)))
          (should (equal (nth 1 b->c) (list (drgnx-debug-heap--line 2) (* 47 cw) dy)))
          (should (equal (plist-get (nthcdr 3 b->c) :points)
                         (list (list (drgnx-debug-heap--line 5) (* 45 cw) dy)
                               (list (drgnx-debug-heap--line 2) (* 45 cw) dy))))
          (should (plist-get (nthcdr 3 b->c) :arrow))
          (should (eq (nth 2 b->c) 'drgnx-text-subtle)))
        ;; a → b and c → a touch the selected a
        (should (eq (nth 2 (nth 0 edges)) 'drgnx-accent))
        (should (eq (nth 2 (nth 2 edges)) 'drgnx-accent))
        ;; RET on b selects it
        (goto-char (debug-heap-test--at "b" 1))
        (drgnx-debug-heap-select)
        (should (eq (plist-get (nthcdr 3 (funcall ring "b")) :ring) 'drgnx-focus-line))
        (should (eq (plist-get (nthcdr 3 (funcall ring "a")) :ring) 'drgnx-border))
        (should (eq (nth 2 (nth 1 drgnx-debug-heap--edges)) 'drgnx-accent))
        (should (eq (nth 2 (nth 2 drgnx-debug-heap--edges)) 'drgnx-text-subtle))))))

(ert-deftest drgnx-debug-heap/the-next-stop-tints-changes-marks-new-and-fades-the-gone-once ()
  "`debug-heap' at the next stop: b's changed row takes the warn tint, e is marked new, d (no longer reachable)
shows once more in the disabled colour at its cells, with no edge, and is gone at the stop after.  The header counts
them, and a cut says how many were not shown."
  (debug-heap-test--with
    (debug-heap-test--open)
    (drgnx-debug--event "debug-heap" (debug-heap-test--answer t))
    (with-current-buffer drgnx-debug-heap-buffer-name
      (let ((qty (debug-heap-test--at "b" 2)) (sku (debug-heap-test--at "b" 1)))
        (should (debug-heap-test--face-p 'drgnx-debug-heap-changed (1+ qty)))
        (should-not (debug-heap-test--face-p 'drgnx-debug-heap-changed (1+ sku))))
      (should (string-match-p "new" (debug-heap-test--row "e" 0)))
      ;; d is drawn once more from the graph before, faded, at its cells (row 8, col 25)
      (save-excursion
        (goto-char (drgnx-debug-heap--line 9))
        (let ((at (debug-heap-test--find (point) (line-end-position) 'drgnx-debug-heap-card "d")))
          (should at)
          (should (debug-heap-test--face-p 'drgnx-debug-heap-gone (1+ at)))))
      (should (= (length drgnx-debug-heap--edges) 4))
      (should (= (length drgnx-debug-heap--blocks) 5))
      (let ((head (debug-heap-test--head)))
        (should (string-match-p "Graph: a" head))
        (should (string-match-p "1 changed" head))
        (should (string-match-p "1 new" head))
        (should (string-match-p "\\+40 not shown" head))))
    (drgnx-debug--event "debug-heap" (plist-put (plist-put (plist-put (debug-heap-test--answer t) :changed [])
                                                           :added [])
                                                :gone []))
    (with-current-buffer drgnx-debug-heap-buffer-name
      (should-not (debug-heap-test--find (point-min) (point-max) 'drgnx-debug-heap-card "d"))
      (should (= (length drgnx-debug-heap--blocks) 4)))))

(ert-deftest drgnx-debug-heap/a-cut-field-ends-in-a-stub-by-a-dashed-edge ()
  "A field the limit cut (`cut' N, no target) shows its value as a reference; its stub \"+N not shown\" sits at the
cells the hub gave it, and its edge (`cut', to \"\") is dashed with no arrowhead, ending at the stub."
  (debug-heap-test--with
    (drgnx-debug-heap-open "s1" "b")
    (funcall (nth 2 (car calls))
             (list :graph "g3" :session "s1" :expr "b" :node "b" :cut 40
                   :nodes (vector (list :id "b" :type "Node" :path "b"
                                        :fields (vector (list :name "sku" :value "'bolt-m4'")
                                                        (list :name "tags" :value "list · 40" :cut 40))))
                   :cards (vector (list :id "b" :col 3 :row 0 :width 18 :height 3))
                   :cuts (vector (list :from "b" :field 1 :count 40 :col 25 :row 4 :width 15))
                   :edges (vector (list :from "b" :field 1 :to "" :cut t :points [[21 2] [23 2] [23 4] [25 4]]))
                   :width 40 :height 5 :added [] :changed [] :gone [])
             nil)
    (should (equal (debug-heap-test--row "b" 2) " tags list · 40 "))
    (with-current-buffer drgnx-debug-heap-buffer-name
      (should (debug-heap-test--face-p 'drgnx-debug-heap-reference (+ (debug-heap-test--at "b" 2) 7)))
      (let ((stub (text-property-any (drgnx-debug-heap--line 4) (drgnx-debug-heap--line 5) 'drgnx-debug-heap-stub t)))
        (should (equal (buffer-substring-no-properties
                        stub (next-single-property-change stub 'drgnx-debug-heap-stub nil (drgnx-debug-heap--line 5)))
                       " +40 not shown "))
        (should (equal (get-text-property (1- stub) 'display) '(space :align-to 25)))
        (should (debug-heap-test--face-p 'drgnx-debug-heap-cut (1+ stub)))
        (should-not (get-text-property (1+ stub) 'drgnx-debug-heap-card)))
      (should (= (length drgnx-debug-heap--blocks) 1))
      (let ((e (car drgnx-debug-heap--edges)) (dy (/ (frame-char-height) 2)))
        (should (equal (nth 1 e) (list (drgnx-debug-heap--line 4) (* 25 (frame-char-width)) dy)))
        (should (plist-get (nthcdr 3 e) :dash))
        (should-not (plist-get (nthcdr 3 e) :arrow))
        ;; it leaves the selected card b: the accent
        (should (eq (nth 2 e) 'drgnx-accent))))))

(ert-deftest drgnx-debug-heap/an-error-says-so-and-keeps-the-graph ()
  "A push with an error (the program ran on, the session ended) says so in the header and keeps the last cards."
  (debug-heap-test--with
    (debug-heap-test--open)
    (drgnx-debug--event "debug-heap" (list :graph "g1" :session "s1" :error "debug session s1 is not stopped"))
    (with-current-buffer drgnx-debug-heap-buffer-name
      (should (string-match-p "not stopped" (debug-heap-test--head))))
    (should (equal (debug-heap-test--row "a" 0) " a Node "))
    ;; another graph's push changes nothing here
    (drgnx-debug--event "debug-heap" (plist-put (debug-heap-test--answer t) :graph "g9"))
    (should (equal (debug-heap-test--row "b" 2) " qty 5 "))))

(ert-deftest drgnx-debug-heap/show-as-graph-reads-the-variable-at-point ()
  "Show as Graph on a Variables row: the row's session and expression."
  (debug-heap-test--with
    (cl-letf (((symbol-function 'drgnx-debug-view--value-node) (lambda () "v:s1:7"))
              ((symbol-function 'drgnx-debug-view--field)
               (lambda (name _id) (pcase name ("evaluate_name" "order.items") ("label" "items")))))
      (drgnx-debug-show-as-graph)
      (should (equal (nth 1 (car calls)) (list :session "s1" :expr "order.items"))))))

;; the shape of a frame's locals (heap_wire.rs, `locals: true'): the frame first, a and shared (a.next) its references
(defun debug-heap-test--locals ()
  (list :graph "g4" :session "s1" :expr "" :locals t :node "frame" :cut 0
        :nodes (vector (debug-heap-test--node "frame" "frame" "Locals" '("a" "<Node>" "1") '("shared" "<Node>" "2")
                                              '("threshold" "10"))
                       (debug-heap-test--node "1" "Node" "a" '("qty" "20") '("next" "<Node>" "2"))
                       (debug-heap-test--node "2" "Node" "shared" '("qty" "3")))
        :cards (vector (list :id "frame" :col 3 :row 2 :width 18 :height 4)
                       (list :id "1" :col 27 :row 2 :width 14 :height 3)
                       (list :id "2" :col 47 :row 2 :width 14 :height 2))
        :edges (vector (list :from "frame" :field 0 :to "1" :points [[21 3] [25 3] [25 2] [27 2]])
                       (list :from "frame" :field 1 :to "2" :points [[21 4] [23 4] [23 0] [45 0] [45 2] [47 2]])
                       (list :from "1" :field 1 :to "2" :points [[41 4] [45 4] [45 2] [47 2]]))
        :width 64 :height 7 :added [] :changed [] :gone []))

(ert-deftest drgnx-debug-heap/show-as-graph-on-a-local-opens-the-frames-locals-with-it-selected ()
  "Show as Graph on a row of the Locals scope asks for the frame's locals: the frame is the first card, titled
Locals, and the local's own card is the selected one; the header names the local."
  (debug-heap-test--with
    (cl-letf (((symbol-function 'drgnx-debug-view--value-node) (lambda () "v:s1:Locals/a"))
              ((symbol-function 'drgnx-debug-view--field)
               (lambda (name _id) (pcase name ("evaluate_name" "a") ("label" "a")))))
      (drgnx-debug-show-as-graph))
    (should (equal (nth 1 (car calls)) (list :session "s1" :locals t)))
    (funcall (nth 2 (car calls)) (debug-heap-test--locals) nil)
    (with-current-buffer drgnx-debug-heap-buffer-name
      (should (equal drgnx-debug-heap--selected "1")))
    (should (equal (debug-heap-test--row "frame" 0) " Locals frame "))
    (should (equal (debug-heap-test--row "frame" 2) " shared Node "))
    (should (string-match-p "Graph: a +2 objects" (debug-heap-test--head)))))

(ert-deftest drgnx-debug-heap/the-header-names-the-frame-and-the-stop ()
  "The header strip: Graph and the expression, then the stopped frame's function, the stop and the objects."
  (debug-heap-test--with
    (drgnx-debug-heap-frame (list :session "s1" :epoch 2 :name "reorder_quantities" :top t))
    (debug-heap-test--open)
    (should (string-match-p "Graph: a +reorder_quantities · stop 2 · 4 objects" (debug-heap-test--head)))))

;;; debug-heap-test.el ends here
