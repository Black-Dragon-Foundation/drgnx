;;; view-nav-test.el --- batch tests: keys through the native view model, classes on the cards (wb/drgnx-view-nav.el) -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: orders
;; Needs Sjá (a Nidhogg with `nidhogg-view--call'); skipped elsewhere.  Each test names its pattern.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-view)
(require 'drgnx-view-nav)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)

(defvar drgnx-view-nav-test--sent nil "What the view sent the hub, newest first: (METHOD . PARAMS).")
(defvar drgnx-view-nav-test--n 0 "Each run's view gets a name of its own in Sjá.")

(defmacro drgnx-view-nav-test--with (&rest body)
  "BODY in a fresh buffer attached as the hub-fed pair (`view' . \"c\"), holding the two-card model (`--start');
sending captured, the notice method \"t/set\".  `h' is the buffer's instance in Sjá."
  (declare (indent 0))
  `(progn
     (drgnx-test-require-nidhogg (fboundp 'nidhogg-view-push) "nidhogg-view-push")
     (let ((drgnx-view-patch--buffers (make-hash-table :test #'equal))
           (drgnx-view-model--views (make-hash-table :test #'equal))
           (drgnx-view-patch--hooked nil)
           (drgnx-view-nav-test--sent nil)
           (drgnx-view-selected-functions nil)
           (drgnx-view-patch-send-function (lambda (m p) (push (cons m p) drgnx-view-nav-test--sent)))
           (view (format "vn-test-%d" (cl-incf drgnx-view-nav-test--n))))
       (with-temp-buffer
         (let ((buf (current-buffer)))
           (drgnx-view-patch-attach view "c" :epoch 1)
           (setq-local drgnx-view-nav-notice-method "t/set")
           (let ((h (drgnx-view-patch-handle drgnx-view-patch)))
             (ignore h)
             (unwind-protect (progn (drgnx-view-nav-test--start view) ,@body)
               (drgnx-view-patch-teardown)
               (drgnx-timer-cancel (cons 'drgnx-view buf))
               (drgnx-timer-cancel (cons 'drgnx-view-nav-notice buf))
               (drgnx-timer-cancel (cons 'drgnx-view-model view)))))))))

(defconst drgnx-view-nav-test--model
  (concat "{\"ops\":[{\"reset\":{\"descriptor\":{\"scheme\":\"links\",\"chain_kinds\":[],\"match_fields\":[\"label\"],"
          "\"lists\":[\"team\"],\"classes\":[\"selected\",\"match\",\"dim\"],\"start\":\"team\"},"
          "\"nodes\":[{\"id\":\"a\",\"kind\":\"card\",\"nav\":{\"right\":\"b\"},\"fields\":[[\"label\",\"alpha\"]]},"
          "{\"id\":\"b\",\"kind\":\"card\",\"nav\":{\"left\":\"a\"},\"fields\":[[\"label\",\"beta\"]]}],\"edges\":[],"
          "\"lists\":[{\"name\":\"team\",\"ids\":[\"a\",\"b\"]}]}}]}")
  "Two cards on one line: a, then b to its right.")

(defun drgnx-view-nav-test--row (text)
  "The one row: \"AA  BB\" with a's span 0–2 and b's 4–6 (TEXT replaces the cards' letters)."
  (list :key "r" :text text :props (list (list 0 2 "drgnx-work-id" "a") (list 4 6 "drgnx-work-id" "b"))))

(defun drgnx-view-nav-test--start (view)
  (drgnx-view-model-event (list :view view :hub 7 :base 0 :version 1 :reset t :model drgnx-view-nav-test--model))
  (drgnx-view-apply-patch (list :view view :class "c" :hub 7 :base 0 :version 1 :env_epoch 1 :model 1
                                :ops (list (list :reset (list (drgnx-view-nav-test--row "AA  BB"))))))
  (drgnx-view-draw-now drgnx-view))

(defun drgnx-view-nav-test--face-at (pos)
  "The faces of the overlays at POS."
  (delq nil (mapcar (lambda (o) (overlay-get o 'face)) (overlays-at pos))))

(ert-deftest drgnx-view-nav/class-on-the-card-not-the-line ()
  "Pattern D: selecting a puts the selected face on a's span, b's on b's, and nothing between them."
  (drgnx-view-nav-test--with
    (should (equal "a" (drgnx-view-nav 'select "a")))
    (should (equal '(drgnx-view-selected) (drgnx-view-nav-test--face-at (+ (point-min) 0))))
    (should (equal '(drgnx-view-selected) (drgnx-view-nav-test--face-at (+ (point-min) 1))))
    (should-not (drgnx-view-nav-test--face-at (+ (point-min) 2)))
    (should-not (drgnx-view-nav-test--face-at (+ (point-min) 3)))
    (should (equal '(shadow) (drgnx-view-nav-test--face-at (+ (point-min) 4))))
    (should (= (point) (point-min)))
    (should (equal "b" (drgnx-view-nav 'follow "right")))
    (should (equal '(shadow) (drgnx-view-nav-test--face-at (point-min))))
    (should (equal '(drgnx-view-selected) (drgnx-view-nav-test--face-at (+ (point-min) 4))))
    (should (= (point) (+ (point-min) 4)))))

(defun drgnx-view-nav-test--drawn ()
  "What a redisplay of this buffer would show: its text ticks and its overlays with their properties."
  (list (buffer-modified-tick) (buffer-chars-modified-tick)
        (sort (mapcar (lambda (o) (list (overlay-start o) (overlay-end o) (overlay-properties o)))
                      (overlays-in (point-min) (point-max)))
              (lambda (x y) (< (car x) (car y))))))

(defun drgnx-view-nav-test--label (view version label)
  "VIEW's model VERSION: a's label is LABEL, a field the rows don't show (no row patch names it)."
  (drgnx-view-model-event
   (list :view view :hub 7 :base (1- version) :version version
         :model (json-serialize
                 (list :ops (vector (list :nodes (vector (list :id "a" :kind "card" :nav (list :right "b")
                                                               :fields (vector (vector "label" label)))))))))))

(ert-deftest drgnx-view-nav/a-model-that-moves-no-class-changes-nothing-drawn ()
  "Pattern B (SJA-MODEL-CADENCE-1): a model no row patch names whose apply moves no class changes neither the text nor
an overlay of the view's buffer when its timer applies it; one applied after a class moved puts that class on."
  (drgnx-view-nav-test--with
    (should (equal "a" (drgnx-view-nav 'select "a")))
    (let ((before (drgnx-view-nav-test--drawn)))
      (should (nth 2 before))
      (cl-loop for label in '("A2" "A3" "A4") for version from 2
               do (drgnx-view-nav-test--label view version label)
               (drgnx-view-model--due view)
               (should (equal label (nidhogg-view-get h 'field "label" "a")))
               (should (equal before (drgnx-view-nav-test--drawn))))
      (nidhogg-view-set h 'select "b")
      (drgnx-view-nav-test--label view 5 "A5")
      (drgnx-view-model--due view)
      (should (equal '(drgnx-view-selected) (drgnx-view-nav-test--face-at (+ (point-min) 4))))
      (should (equal (nth 1 before) (buffer-chars-modified-tick))))))

(ert-deftest drgnx-view-nav/replaced-row-keeps-its-class ()
  "Pattern A: the row holding the selected card is replaced (rows naming the same model); in every order of the
patch, the draw and the key, once all have run, a's span has the selected face and b's the dim one."
  (dolist (order '((patch draw key) (patch key draw) (key patch draw)))
    (drgnx-view-nav-test--with
      (dolist (step order)
        (pcase step
          ('key (drgnx-view-nav 'select "a"))
          ('patch (drgnx-view-apply-patch (list :view view :class "c" :hub 7 :base 1 :version 2 :env_epoch 1 :model 1
                                                :ops (list (list :replace (list (drgnx-view-nav-test--row "aa  bb")))))))
          ('draw (drgnx-view-draw-now drgnx-view))))
      (should (equal "aa  bb\n" (buffer-substring-no-properties (point-min) (point-max))))
      (should (equal '(drgnx-view-selected) (drgnx-view-nav-test--face-at (point-min))))
      (should (equal '(shadow) (drgnx-view-nav-test--face-at (+ (point-min) 4))))
      (should-not (drgnx-view-nav-test--face-at (+ (point-min) 2)))
      (should (= 2 (length (cl-remove-if-not (lambda (o) (overlay-get o 'face))
                                             (overlays-in (point-min) (point-max)))))))))

(ert-deftest drgnx-view-nav/held-key-sends-one-trailing-notice ()
  "Pattern B on the test clock: a key held (a move every 30 ms for 0.25 s) sends at most one notice per
`drgnx-view-delay', and the last one names where the selection came to rest."
  (drgnx-view-nav-test--with
    (drgnx-test-with-clock ()
      (nidhogg-view-set h 'select "a")
      (dotimes (i 9)
        (drgnx-view-nav 'follow (if (cl-evenp i) "right" "left"))
        (drgnx-test-advance 0.03))
      (should (equal "b" (drgnx-view-nav-selection)))     ; from a: b a b a b a b a b
      (drgnx-test-advance 0.5)
      (let ((notices (reverse (cl-remove-if-not (lambda (s) (equal (car s) "t/set")) drgnx-view-nav-test--sent))))
        (should (<= 1 (length notices) 3))
        (should (equal (list :view view :selected "b") (cdr (car (last notices)))))))))

(ert-deftest drgnx-view-nav/clear-sent-for-no-selection ()
  "Pattern D: a selection dropped sends the notice with `clear'."
  (drgnx-view-nav-test--with
    (drgnx-test-with-clock ()
      (drgnx-view-nav 'select "b")
      (drgnx-test-advance 0.5)
      (drgnx-view-nav 'select nil)
      (drgnx-test-advance 0.5)
      (should (equal (list "t/set" :view view :clear t) (car drgnx-view-nav-test--sent)))
      (should-not (drgnx-view-nav-test--face-at (point-min))))))

(ert-deftest drgnx-view-nav/selected-functions-run-on-a-move-only ()
  "Pattern D: `drgnx-view-selected-functions' run when the selection moved, not on a move that stays."
  (drgnx-view-nav-test--with
    (let ((seen nil))
      (add-hook 'drgnx-view-selected-functions (lambda (b id) (push (cons b id) seen)) nil t)
      (drgnx-view-nav 'select "a")
      (drgnx-view-nav 'follow "left")                      ; a has no left: it stays
      (should (equal (list (cons (current-buffer) "a")) seen)))))

(ert-deftest drgnx-view-nav/broken-view-says-so ()
  "Pattern D, test-hooks: two panics trip the view's breaker; a key then answers nil and says so once."
  (drgnx-view-nav-test--with
    (skip-unless (condition-case nil (progn (nidhogg-view--call 99 "vn-probe-hooks") t) (args-out-of-range nil)))
    (nidhogg-view--call 99 view)
    (nidhogg-view--call 99 view)
    (let ((messages nil))
      (cl-letf (((symbol-function 'drgnx-notify) (lambda (_source _severity text &rest _) (push text messages))))
        (should-not (drgnx-view-nav 'follow "right"))
        (should-not (drgnx-view-nav 'follow "right")))
      (should (= 1 (length messages)))
      (should (string-match-p "broke" (car messages))))))

(ert-deftest drgnx-view-nav/class-step-makes-nothing-per-node-drawn-elsewhere ()
  "Pattern D: a draw that replaced one row gives that row's nodes their classes again, found by the row → ids index;
the nodes drawn in other rows are never visited and cost it no object (a panel draws a node per step: a closure each
was 100 kB a draw, and a walk of them all 8.7 % of work-live's samples)."
  (drgnx-view-nav-test--with
    (let ((ids (drgnx-view-patch-ids drgnx-view-patch)) (keys (drgnx-view-patch-keys drgnx-view-patch)) visited)
      (puthash "r" '("in-r") keys)
      (puthash "in-r" '("r") ids)
      (cl-flet ((cells (n)
                  (dotimes (i n)
                    (puthash (format "x%d" i) (list (format "k%d" i)) ids)
                    (puthash (format "k%d" i) (list (format "x%d" i)) keys))
                  (setq visited nil)
                  (let ((v0 (nth 2 (memory-use-counts))))
                    (cl-letf (((symbol-function 'drgnx-view-nav--put-class) (lambda (_v id _c) (push id visited))))
                      (drgnx-view-nav-class-step view '("r")))
                    (- (nth 2 (memory-use-counts)) v0))))
        (let* ((few (cells 10)) (few-visited visited) (many (cells 1000)))
          (should (< (- many few) 100))
          (should (member "in-r" few-visited))
          (should (member "in-r" visited))
          (should-not (cl-some (lambda (id) (string-prefix-p "x" id)) visited)))))))

;; Windows

(defun drgnx-view-nav-test--tree-window (from)
  "A tree's model whose list `order' is entries FROM to FROM+3 of m0..m9, as a reset."
  (let ((ids (mapcar (lambda (i) (format "m%d" i)) (number-sequence from (+ from 3)))))
    (json-serialize
     (list :ops (vector (list :reset
                              (list :descriptor (list :scheme "tree" :lists ["order"] :classes ["selected"] :start "order")
                                    :nodes (vconcat (mapcar (lambda (id) (list :id id :kind "match"
                                                                               :fields (vector (vector "label" id))))
                                                            ids))
                                    :edges []
                                    :lists (vector (list :name "order" :ids (vconcat ids) :total 10 :from from)))))))))

(ert-deftest drgnx-view-nav/a-key-past-the-window-asks-once-and-runs-again ()
  "Pattern C: a tree holding entries 0-3 of 10.  `down' from the last asks the hub once for the window a step past it
\(half the window: `view/window' order from 2), keys meanwhile ask nothing more and the newest is kept (a walk-to entry 8); each model
that comes applies at once; one that does not reach entry 8 asks again (from 6), and the one that does selects it."
  (drgnx-view-nav-test--with
    (drgnx-test-require-nidhogg
     (progn (drgnx-view-model-event (list :view view :hub 7 :base 1 :version 2 :reset t
                                          :model (drgnx-view-nav-test--tree-window 0)))
            (drgnx-view-model--due view)
            (ignore-errors (nidhogg-view-get h 'window "order")))
     "Sjá window read (nidhogg-view-get 'window)")
    (let ((asks (lambda () (mapcar (lambda (s) (plist-get (cdr s) :from))
                                   (seq-filter (lambda (s) (equal (car s) "view/window")) drgnx-view-nav-test--sent)))))
      (drgnx-view-nav 'select "m3")
      (should (equal "m3" (drgnx-view-nav 'follow "down")))
      (should (equal '(2) (funcall asks)))
      (should (drgnx-view-nav-paging-p))
      (drgnx-view-nav 'follow "down")
      (should (equal "m3" (drgnx-view-nav 'walk-to "order" 8)))
      (should (equal '(2) (funcall asks)))
      (drgnx-view-model-event (list :view view :hub 7 :base 2 :version 3 :reset t
                                    :model (drgnx-view-nav-test--tree-window 4)))
      (should (equal '(6 2) (funcall asks)))   ; walk-to 8 ran on 4-7: past it again, centred
      (should (drgnx-view-nav-paging-p))
      (drgnx-view-model-event (list :view view :hub 7 :base 3 :version 4 :reset t
                                    :model (drgnx-view-nav-test--tree-window 6)))
      (should (equal "m8" (drgnx-view-nav-selection)))
      (should-not (drgnx-view-nav-paging-p))
      (should (equal '(6 2) (funcall asks))))))

;;; view-nav-test.el ends here
