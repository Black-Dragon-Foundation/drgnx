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

(defun debug-heap-test--cell (row col)
  "The text from ROW, COL of the grid to the end of that line."
  (with-current-buffer drgnx-debug-heap-buffer-name
    (save-excursion (goto-char (drgnx-debug-heap--cell row col))
                    (buffer-substring-no-properties (point) (line-end-position)))))

(ert-deftest drgnx-debug-heap/opens-on-the-events-connection-and-closes-with-the-tab ()
  "Show as Graph asks `debug/heap' for the session's expression on the connection the hub pushes `debug-heap' to;
killing the Graph tab's buffer sends `debug/heap/close'."
  (debug-heap-test--with
    (debug-heap-test--open)
    (should (equal (nth 0 (car (last calls))) "debug/heap"))
    (should (equal (nth 1 (car (last calls))) (list :session "s1" :expr "a")))
    (kill-buffer drgnx-debug-heap-buffer-name)
    (should (equal (butlast (car calls)) (list "debug/heap/close" (list :graph "g1"))))))

(ert-deftest drgnx-debug-heap/a-card-is-its-type-then-its-fields-at-its-cells ()
  "Each card sits at its cells: the type row, then a row per field, the name left and the value right (a reference
shows its target's type), all within the card's width."
  (debug-heap-test--with
    (debug-heap-test--open)
    (should (string-prefix-p " Node" (debug-heap-test--cell 2 3)))
    (should (string-match-p "\\` sku +'nut-m6' \\'" (substring (debug-heap-test--cell 3 3) 0 16)))
    (should (string-match-p "\\` next +Node \\'" (substring (debug-heap-test--cell 5 3) 0 16)))
    (should (string-prefix-p " Node" (debug-heap-test--cell 2 25)))
    (should (string-match-p "\\` qty +5 \\'" (substring (debug-heap-test--cell 4 25) 0 16)))
    (with-current-buffer drgnx-debug-heap-buffer-name
      (should (equal (get-text-property (drgnx-debug-heap--cell 4 25) 'drgnx-debug-heap-card) "b"))
      (should-not (get-text-property (drgnx-debug-heap--cell 4 24) 'drgnx-debug-heap-card)))))

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
    (should (string-match-p "\\` f8 +8 \\'" (substring (debug-heap-test--cell 8 3) 0 12)))
    (should (string-prefix-p " +3 more" (debug-heap-test--cell 9 3)))))

(ert-deftest drgnx-debug-heap/each-card-is-a-ring-and-each-reference-an-edge ()
  "The cards are Glitnir rings over their cells (the border, radius 6) and the references Glitnir edges from the
field's row to the target's type row, through the hub's bends, with an arrowhead, in the subtle colour; the
selected card (the root at first) is ringed in the focus colour and its edges take the accent."
  (debug-heap-test--with
    (debug-heap-test--open)
    (with-current-buffer drgnx-debug-heap-buffer-name
      (let* ((cw (frame-char-width)) (blocks drgnx-debug-heap--blocks) (edges drgnx-debug-heap--edges)
             (ring (lambda (id) (seq-find (lambda (b) (= (nth 1 b) (drgnx-debug-heap--cell
                                                                    (plist-get (drgnx-debug-heap--card id) :row)
                                                                    (plist-get (drgnx-debug-heap--card id) :col))))
                                          drgnx-debug-heap--blocks))))
        (should (= (length blocks) 4))
        (should (eq (car (funcall ring "b")) 'ring))
        (should (= (plist-get (nthcdr 3 (funcall ring "b")) :x0) (* 25 cw)))
        (should (= (plist-get (nthcdr 3 (funcall ring "b")) :x1) (* 41 cw)))
        (should (= (nth 2 (funcall ring "b")) (drgnx-debug-heap--cell 5 41)))
        (should (eq (plist-get (nthcdr 3 (funcall ring "b")) :ring) 'drgnx-border))
        (should (eq (plist-get (nthcdr 3 (funcall ring "a")) :ring) 'drgnx-focus-line))
        (should (= (length edges) 4))
        (let ((b->c (nth 1 edges)) (dy (/ (frame-char-height) 2)))
          (should (equal (nth 0 b->c) (list (drgnx-debug-heap--cell 5 41) 0 dy)))
          (should (equal (nth 1 b->c) (list (drgnx-debug-heap--cell 2 47) 0 dy)))
          (should (equal (plist-get (nthcdr 3 b->c) :points)
                         (list (list (drgnx-debug-heap--cell 5 45) 0 dy) (list (drgnx-debug-heap--cell 2 45) 0 dy))))
          (should (plist-get (nthcdr 3 b->c) :arrow))
          (should (eq (nth 2 b->c) 'drgnx-text-subtle)))
        ;; a → b and c → a touch the selected a
        (should (eq (nth 2 (nth 0 edges)) 'drgnx-accent))
        (should (eq (nth 2 (nth 2 edges)) 'drgnx-accent))
        ;; RET on b selects it
        (goto-char (drgnx-debug-heap--cell 3 27))
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
      (let ((qty (drgnx-debug-heap--cell 4 27)) (sku (drgnx-debug-heap--cell 3 27)))
        (should (memq 'drgnx-debug-heap-changed (ensure-list (get-text-property qty 'face))))
        (should-not (memq 'drgnx-debug-heap-changed (ensure-list (get-text-property sku 'face)))))
      (should (string-match-p "new" (debug-heap-test--cell 12 25)))
      (should (string-prefix-p " Node" (debug-heap-test--cell 8 25)))
      (should (memq 'drgnx-debug-heap-gone (ensure-list (get-text-property (drgnx-debug-heap--cell 9 27) 'face))))
      (should (= (length drgnx-debug-heap--edges) 4))
      (should (= (length drgnx-debug-heap--blocks) 5))
      (let ((head (buffer-substring-no-properties (point-min) (line-end-position 1))))
        (should (string-match-p "Graph: a" head))
        (should (string-match-p "1 changed" head))
        (should (string-match-p "1 new" head))
        (should (string-match-p "\\+40 not shown" head))))
    (drgnx-debug--event "debug-heap" (plist-put (plist-put (plist-put (debug-heap-test--answer t) :changed [])
                                                           :added [])
                                                :gone []))
    (with-current-buffer drgnx-debug-heap-buffer-name
      (should-not (string-prefix-p " Node" (debug-heap-test--cell 8 25)))
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
    (should (string-match-p "\\` tags +list · 40 \\'" (substring (debug-heap-test--cell 2 3) 0 18)))
    (with-current-buffer drgnx-debug-heap-buffer-name
      (should (eq (get-text-property (+ (drgnx-debug-heap--cell 2 3) 14) 'face) 'drgnx-debug-heap-reference)))
    (should (string-prefix-p " +40 not shown " (debug-heap-test--cell 4 25)))
    (with-current-buffer drgnx-debug-heap-buffer-name
      (should (eq (get-text-property (drgnx-debug-heap--cell 4 26) 'face) 'drgnx-debug-heap-cut))
      (should-not (get-text-property (drgnx-debug-heap--cell 4 26) 'drgnx-debug-heap-card))
      (should (= (length drgnx-debug-heap--blocks) 1))
      (let ((e (car drgnx-debug-heap--edges)) (dy (/ (frame-char-height) 2)))
        (should (equal (nth 1 e) (list (drgnx-debug-heap--cell 4 25) 0 dy)))
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
      (should (string-match-p "not stopped" (buffer-substring-no-properties (point-min) (line-end-position 1))))
      (should (string-prefix-p " Node" (debug-heap-test--cell 2 3))))
    ;; another graph's push changes nothing here
    (drgnx-debug--event "debug-heap" (plist-put (debug-heap-test--answer t) :graph "g9"))
    (should (string-match-p "\\` qty +5 \\'" (substring (debug-heap-test--cell 4 25) 0 16)))))

(ert-deftest drgnx-debug-heap/show-as-graph-reads-the-variable-at-point ()
  "Show as Graph on a Variables row: the row's session and expression."
  (debug-heap-test--with
    (cl-letf (((symbol-function 'drgnx-debug-view--value-node) (lambda () "v:s1:7"))
              ((symbol-function 'drgnx-debug-view--field)
               (lambda (name _id) (pcase name ("evaluate_name" "order.items") ("label" "items")))))
      (drgnx-debug-show-as-graph)
      (should (equal (nth 1 (car calls)) (list :session "s1" :expr "order.items"))))))

;;; debug-heap-test.el ends here
