;;; work-map-rows-test.el --- batch tests: the Work map inserts the rows the hub builds -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: orders
;; Needs Sjá (a Nidhogg with `nidhogg-view--call'); skipped elsewhere, except the test of a map without it.
;; No hub: the map buffer gets the hub's patches and model by hand, what it sends is recorded.  Each test names its
;; pattern (A: every order, orders-fixture.el; D: pure).
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-view)
(require 'drgnx-view-nav)
(require 'drgnx-work-client)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/orders-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-work-map" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/work-space))

(declare-function drgnx-work-space--buffer "drgnx-work-space")
(declare-function drgnx-view-nav--notice "drgnx-view-nav")
(defvar drgnx-work-space--view)

(defvar drgnx-work-map-rows-test--n 0 "Each run's view gets a name of its own in Sjá.")
(defvar drgnx-work-map-rows-test--sent nil "What the map sent the hub, newest first: (METHOD . PARAMS).")

(defconst drgnx-work-map-rows-test--model
  (json-serialize
   (list :ops
         (vector
          (list :reset
                (list :descriptor (list :scheme "links" :chain_kinds ["came-from"] :match_fields ["label"]
                                        :lists ["team" "needs-you" "outline" "plans"]
                                        :classes ["selected" "match" "chain" "dim"]
                                        :flags ["needs-you"]
                                        :forms (vector (list :name "graph") (list :name "outline" :list "outline"))
                                        :start "team")
                      :nodes (vector
                              (list :id "ask:1" :kind "ask" :nav (list :down "agent:a") :fields [["label" "Fix"]])
                              (list :id "agent:a" :kind "agent" :nav (list :up "ask:1" :right "agent:b")
                                    :fields [["label" "alpha"] ["done" 2] ["steps" 5] ["edit_files" 3] ["edit_plus" 10]
                                             ["edit_minus" 4] ["reads" 7] ["conclusion" "tests pass"] ["spend" "$0.40"]
                                             ["minutes" 12] ["overlaps" "agent:b"]])
                              (list :id "agent:b" :kind "agent" :nav (list :up "ask:1" :left "agent:a")
                                    :fields [["label" "beta"] ["overlaps" "agent:a"]])
                              (list :id "file:drgnx/src/x.rs" :kind "file" :nav (list :up "agent:a")
                                    :fields [["label" "x.rs"]])
                              (list :id "plan:p1" :kind "plan" :nav (list :up "ask:1") :fields [["label" "p1"]])
                              (list :id "plan:p2" :kind "plan" :fields [["label" "p2"]]))
                      :edges [["ask:1" "agent:a" "came-from"] ["ask:1" "agent:b" "came-from"]
                              ["agent:a" "file:drgnx/src/x.rs" "came-from"] ["ask:1" "plan:p1" "came-from"]]
                      :lists (vector (list :name "team" :ids ["agent:a" "agent:b"])
                                     (list :name "needs-you" :ids [])
                                     (list :name "outline" :ids ["agent:a" "agent:b"])
                                     (list :name "plans" :ids ["plan:p1" "plan:p2"])))))))
  "A small map model: an ask over two agents (the first with a file, the two overlapping) and a plan; a second plan
apart.")

(defun drgnx-work-map-rows-test--row (text)
  "One row of every card, TEXT \"QQ AA BB\" or another of that shape (each card two characters at 0, 3 and 6)."
  (list :key "r" :text text
        :props (list (list 0 2 "drgnx-work-id" "ask:1") (list 3 5 "drgnx-work-id" "agent:a")
                     (list 6 8 "drgnx-work-id" "agent:b"))))

(defun drgnx-work-map-rows-test--patch (view hub base version ops)
  (list :view view :class "c" :hub hub :base base :version version :env_epoch 1 :ops ops))

(defmacro drgnx-work-map-rows-test--with (&rest body)
  "BODY in a map buffer `buf' on the rows path (view `view') holding the model and one row, sending recorded."
  (declare (indent 0))
  `(progn
     (drgnx-test-require-nidhogg (fboundp 'nidhogg-view-push) "nidhogg-view-push")
     (let ((drgnx-view-patch--buffers (make-hash-table :test #'equal))
           (drgnx-view-model--views (make-hash-table :test #'equal))
           (drgnx-view-patch--hooked nil)
           (drgnx-work-map-rows-test--sent nil)
           (drgnx-view-patch-send-function (lambda (m p) (push (cons m p) drgnx-work-map-rows-test--sent)))
           (drgnx-work-map-select-functions nil)
           (view (format "wmr-test-%d" (cl-incf drgnx-work-map-rows-test--n))))
       (with-temp-buffer
         (drgnx-work-map-mode)
         (let ((buf (current-buffer)))
           (drgnx-view-patch-attach view "c" :epoch 1)
           (unwind-protect
               (progn
                 (drgnx-view-model-event (list :view view :hub 7 :base 0 :version 1 :reset t
                                               :model drgnx-work-map-rows-test--model))
                 (drgnx-view-apply-patch (append (drgnx-work-map-rows-test--patch
                                                  view 7 0 1 (list (list :reset (list (drgnx-work-map-rows-test--row "QQ AA BB")))))
                                                 (list :model 1)))
                 (drgnx-view-draw-now drgnx-view)
                 ,@body)
             (drgnx-view-patch-teardown)
             (drgnx-timer-cancel (cons 'drgnx-view buf))
             (drgnx-timer-cancel (cons 'drgnx-view-nav-notice buf))
             (drgnx-timer-cancel (cons 'drgnx-view-model view))))))))

(defun drgnx-work-map-rows-test--selected-at ()
  "The node id under point and whether the selected face is on it."
  (list (get-text-property (point) 'drgnx-work-id)
        (and (memq 'drgnx-view-selected (mapcar (lambda (o) (overlay-get o 'face)) (overlays-at (point)))) t)))

(ert-deftest drgnx-work-map-rows/selection-survives-every-order-of-patch-and-key ()
  "Pattern A: the hub's row patches (the row's text changing around the same cards) and the user's keys, in every
order: the selection is the model's, point is on its card and the selected face on its span."
  (drgnx-work-map-rows-test--with
    (let ((n 0))
      (drgnx-test-every-order
       :kinds '(patch key)
       :sources `(("hub" (patch "QQ AA BB.") (patch "QQ AA BB..")) ("user" (key right) (key right)))
       :init (lambda ()
               ;; the same buffer each order: a reset of the hub's row and no selection
               (cl-incf n)
               (drgnx-view-apply-patch (drgnx-work-map-rows-test--patch
                                        view 7 0 (+ 10 (* 10 n))
                                        (list (list :reset (list (drgnx-work-map-rows-test--row "QQ AA BB"))))))
               (drgnx-work-map--nav 'select "ask:1")
               (list :v (+ 10 (* 10 n))))
       :step (lambda (s ev)
               (pcase ev
                 (`(patch ,text)
                  (drgnx-view-apply-patch (drgnx-work-map-rows-test--patch
                                           view 7 (plist-get s :v) (1+ (plist-get s :v))
                                           (list (list :replace (list (drgnx-work-map-rows-test--row text))))))
                  (setq s (plist-put s :v (1+ (plist-get s :v)))))
                 (`(key ,_) (if (equal (cdr drgnx-work-map--selection) "ask:1") (drgnx-work-map-touches)
                              (drgnx-work-map-right))))
               (drgnx-view-draw-now drgnx-view)
               (cons s nil))
       :check (lambda (_s _order)
                (let ((at (progn (drgnx-view-draw-now drgnx-view) (drgnx-work-map-rows-test--selected-at))))
                  (cond ((not (equal (cdr drgnx-work-map--selection) "agent:b"))
                         (format "the selection is %S, not agent:b" drgnx-work-map--selection))
                        ((not (equal at '("agent:b" t))) (format "point's card and face: %S" at)))))))))

(ert-deftest drgnx-work-map-rows/reconnect-redraws-from-reset ()
  "Pattern A: the old hub's patch in flight, the link lost, the new hub's reset: in every order the map shows the new
hub's row, keeps the selection's face on it, and no old patch lands after the reset.  The view subscribes again with
`rows'."
  (drgnx-work-map-rows-test--with
    (let ((n 0))
      (drgnx-test-every-order
       :kinds '(patch disconnect)
       :sources `(("old hub" (patch 7 1 "QQ AA BB old"))
                  ("link" (disconnect))
                  ("new hub" (patch 8 0 "QN AN BN")))
       :edges '((("link" . 0) . ("new hub" . 0)))
       :init (lambda ()
               (cl-incf n)
               (drgnx-view-apply-patch (drgnx-work-map-rows-test--patch
                                        view 7 0 (* 100 n) (list (list :reset (list (drgnx-work-map-rows-test--row "QQ AA BB"))))))
               (drgnx-work-map--nav 'select "agent:a")
               (list :n n))
       :step (lambda (s ev)
               (pcase ev
                 (`(patch 7 ,_ ,text)
                  (drgnx-view-apply-patch (drgnx-work-map-rows-test--patch
                                           view 7 (* 100 (plist-get s :n)) (1+ (* 100 (plist-get s :n)))
                                           (list (list :replace (list (drgnx-work-map-rows-test--row text)))))))
                 (`(patch 8 ,_ ,text)
                  (drgnx-view-apply-patch (drgnx-work-map-rows-test--patch
                                           view (+ 8 (* 10 (plist-get s :n))) 0 1
                                           (list (list :reset (list (drgnx-work-map-rows-test--row text)))))))
                 ('(disconnect) (drgnx-view-patch--forget drgnx-view-patch)))
               (cons s nil))
       :check (lambda (_s _order)
                (drgnx-view-draw-now drgnx-view)
                (goto-char (point-min))
                (let ((text (buffer-substring-no-properties (point-min) (line-end-position))))
                  (search-forward "AN")
                  (backward-char 1)
                  (cond ((not (equal text "QN AN BN")) (format "the map shows %S, not the new hub's row" text))
                        ((not (equal (drgnx-work-map-rows-test--selected-at) '("agent:a" t)))
                         (format "the selection's face: %S" (drgnx-work-map-rows-test--selected-at)))))))))
  ;; the client's half: a view subscribes again when the hub is back
  (let ((drgnx-work-client--views (make-hash-table :test #'equal)) (asked nil))
    (cl-letf (((symbol-function 'drgnx-work-client--call) (lambda (method params _cb) (push (cons method params) asked) t)))
      (drgnx-work-client-open "w1" (list :id "w1" :roots '("/r/")))
      (setq asked nil)
      (drgnx-work-client-connected)
      (should (equal "work/map/subscribe" (car (car asked))))
      (should (equal "w1" (plist-get (cdr (car asked)) :view)))
      ;; its answer is the hub's id: the view is live
      (drgnx-work-client--subscribed "w1" (drgnx-work-client--view-gen (drgnx-work-client--get "w1")) (list :hub 9 :version 1) nil)
      (should (equal "live" (drgnx-work-client-status "w1"))))))

(ert-deftest drgnx-work-map-rows/selected-is-sent-without-waiting ()
  "Pattern D: a key moves the selection at once, with no answer from the hub; the trailing notice then tells the hub
the selection with `work/map/set'."
  (drgnx-work-map-rows-test--with
    (drgnx-work-map-right)
    (should (equal '(agent . "agent:a") drgnx-work-map--selection))
    (should-not (assoc "work/map/set" drgnx-work-map-rows-test--sent))
    (drgnx-view-nav--notice buf)
    (should (equal (list :view view :selected "agent:a") (cdr (assoc "work/map/set" drgnx-work-map-rows-test--sent))))))

(ert-deftest drgnx-work-map-rows/asked-layout-draws-at-the-answer ()
  "Pattern D: a layout the user asks for (the filters) is drawn at the next timer pass once the hub answers (its rows
came before the answer), not a throttle later; an answer with an error hurries nothing."
  (drgnx-work-map-rows-test--with
    (let ((drgnx-work-client--views (make-hash-table :test #'equal)) (callbacks nil) (hurried nil))
      (cl-letf (((symbol-function 'drgnx-work-client--call)
                 (lambda (method _params cb) (when (equal method "work/map/set") (push cb callbacks)) t))
                ((symbol-function 'drgnx-view-hurry) (lambda (v) (push v hurried))))
        (drgnx-work-client-open "wmr" (list :id "wmr" :roots '("/r/")))
        (setq-local drgnx-work-space--view "wmr")
        (drgnx-work-map-overlaps)
        (should (= 1 (length callbacks)))
        (drgnx-view-apply-patch (drgnx-work-map-rows-test--patch
                                 view 7 1 2 (list (list :replace (list (drgnx-work-map-rows-test--row "QQ AA"))))))
        (should-not hurried)
        (funcall (car callbacks) (list :version 2) nil)
        (should (equal (list drgnx-view) hurried))
        (setq hurried nil)
        (drgnx-work-map-overlaps)
        (funcall (car callbacks) nil "no view")
        (should-not hurried)))))

(declare-function drgnx-work-code-files-command "drgnx-work-code")
(declare-function drgnx-work-code-diffs-command "drgnx-work-code")
(declare-function drgnx-work-code--select-file "drgnx-work-code")
(declare-function drgnx-work-board-plans-for "drgnx-work-board")
(declare-function drgnx-work-review--summary "drgnx-work-review")
(declare-function drgnx-work-huddle-overlap "drgnx-work-detail")
(declare-function drgnx-work-detail-buffer "drgnx-work-detail")
(declare-function drgnx-work-board-open "drgnx-work-board")
(declare-function drgnx-work-flow-open "drgnx-work-flow")

(ert-deftest drgnx-work-map-rows/files-and-diffs-take-the-selection ()
  "Pattern D: on the rows path the files picker and the diffs ask the hub for the session the model's selection stands
for: a selected agent's own, a file's agent on its chain.  With nothing selected they say so."
  (drgnx-work-map-rows-test--with
    (let ((calls nil) (shown nil))
      (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (method params _cb &rest _) (push (cons method params) calls) 1))
                ((symbol-function 'display-buffer) (lambda (b &rest _) (push b shown) (selected-window)))
                ((symbol-function 'select-window) #'ignore))     ; the map stays the current buffer
        (unwind-protect
            (progn
              (should-error (drgnx-work-code-files-command) :type 'user-error)
              (drgnx-work-map--nav 'select "agent:a")
              (drgnx-work-code-files-command)
              (should (equal (list :session "a") (cdr (assoc "work/files" calls))))
              (setq calls nil)
              (drgnx-work-map--nav 'select "file:drgnx/src/x.rs")
              (drgnx-work-code-diffs-command)
              (should (equal (list :session "a") (cdr (assoc "work/files" calls)))))
          (mapc #'kill-buffer (seq-filter #'buffer-live-p shown)))))))

(ert-deftest drgnx-work-map-rows/who-is-here-selects-the-file ()
  "Pattern D: `who is here' selects the file on a map on the rows path when the model has it, and nothing when not."
  (drgnx-work-map-rows-test--with
    (cl-letf (((symbol-function 'drgnx-work-map-buffers) (lambda () (list buf)))
              ((symbol-function 'pop-to-buffer) #'ignore))
      (drgnx-work-code--select-file "drgnx" "src/x.rs")
      (should (equal '(file . "file:drgnx/src/x.rs") drgnx-work-map--selection))
      (drgnx-work-code--select-file "drgnx" "src/none.rs")
      (should (equal '(file . "file:drgnx/src/x.rs") drgnx-work-map--selection)))))

(ert-deftest drgnx-work-map-rows/the-outline-key-asks-the-hub-for-its-form ()
  "Pattern D: the outline key asks the hub to draw the outline (`work/map/set' :outline \"on\"), then the cards again
(\"off\")."
  (drgnx-work-map-rows-test--with
    (let ((asked nil) (drgnx-work-space--view "wsv"))
      (cl-letf (((symbol-function 'drgnx-work-client-set) (lambda (id &rest params) (push (cons id params) asked))))
        (drgnx-work-map-toggle-outline)
        (should (equal '("wsv" :outline "on") (car asked)))
        (drgnx-work-map-toggle-outline)
        (should (equal '("wsv" :outline "off") (car asked)))))))

(ert-deftest drgnx-work-map-rows/the-board-is-scoped-by-the-models-plans ()
  "Pattern D: the design's table 8.2, Map to Board, from the model: a plan scopes the Board to itself, an ask (or a
spec) to the plans on its chain; anything else, or nothing selected, to every task."
  (drgnx-work-map-rows-test--with
    (should-not (drgnx-work-board-plans-for buf))
    (drgnx-work-map--nav 'select "ask:1")
    (should (equal '("plan:p1") (drgnx-work-board-plans-for buf)))
    (drgnx-work-map--nav 'select "plan:p2")
    (should (equal '("plan:p2") (drgnx-work-board-plans-for buf)))
    (drgnx-work-map--nav 'select "agent:a")
    (should-not (drgnx-work-board-plans-for buf))))

(ert-deftest drgnx-work-map-rows/the-review-summary-reads-the-agents-card ()
  "Pattern D: the review panel's summary is the model's card of the agent: its plan steps, edits, reads, last
conclusion and spend; an agent the model has no card for says so."
  (drgnx-work-map-rows-test--with
    (should (equal (concat "plan:   2 of 5 steps done\n"
                           "did:    edits 3 files (+10 −4) · reads 7 · last: tests pass\n"
                           "spent:  $0.40 · 12 min\n")
                   (drgnx-work-review--summary buf "a")))
    (should (equal "plan:   no plan steps recorded\ndid:    \nspent:  \n" (drgnx-work-review--summary buf "b")))
    (should (equal "the map holds no card for this agent\n" (drgnx-work-review--summary buf "zz")))))

(ert-deftest drgnx-work-map-rows/h-huddles-the-agents-the-model-says-overlap ()
  "Pattern D: `work-huddle' on a selected agent starts a huddle with the agent its card overlaps (the model's
`overlaps' field); anything but an agent is refused."
  (drgnx-work-map-rows-test--with
    (let (calls)
      (cl-letf (((symbol-function 'drgnx-agents-editor-here-huddle) (lambda (a b) (push (list a b) calls))))
        (drgnx-work-map--nav 'select "agent:a")
        (drgnx-work-huddle-overlap)
        (should (equal '(("a" "b")) calls))
        (drgnx-work-map--nav 'select "ask:1")
        (should-error (drgnx-work-huddle-overlap) :type 'user-error)))))

(ert-deftest drgnx-work-map-rows/esc-clears-the-search-then-the-filters-then-closes ()
  "Pattern D: Esc clears the search first (the model's search too), then the filters and the collapsed layers (sent to
the hub), then closes the pane."
  (drgnx-work-map-rows-test--with
    (let ((closed 0) (set nil) (drgnx-work-space--view "wsv"))
      (cl-letf (((symbol-function 'drgnx-close-pane) (lambda () (cl-incf closed)))
                ((symbol-function 'drgnx-work-client-set-then) (lambda (_id _cb &rest params) (push params set))))
        (drgnx-work-map-overlaps)
        (drgnx-work-map-search "alpha")
        (should (equal '(agent . "agent:a") drgnx-work-map--selection))   ; the first match is selected
        (drgnx-work-map-escape)                                           ; the search first
        (should-not drgnx-work-map--search)
        (should (plist-get drgnx-work-map--filters :overlaps))
        (drgnx-work-map-escape)                                           ; then the filters
        (should-not drgnx-work-map--filters)
        (should (eq :false (plist-get (plist-get (car set) :filters) :overlaps)))
        (should (= 0 closed))
        (drgnx-work-map-escape)                                           ; then the pane
        (should (= 1 closed))))))

(ert-deftest drgnx-work-map-rows/the-map-is-hub-fed-with-its-lens ()
  "Pattern D: a map opened with Sjá is the hub-fed view of its workspace, subscribes with `rows' and has the lens on
its tab line, the map marked."
  (drgnx-test-require-nidhogg (fboundp 'nidhogg-view--call) "nidhogg-view--call")
  (let ((asked nil))
    (drgnx-test-with-modules '(tools/work-space)
      (cl-letf (((symbol-function 'drgnx-work-client--call) (lambda (method params _cb) (push (cons method params) asked) t)))
        (let* ((ws (list :id "rows-ws" :roots (list temporary-file-directory)))
               (buf (drgnx-work-space--buffer ws)))
          (unwind-protect
              (with-current-buffer buf
                (should drgnx-view-patch)
                (should (equal "rows-ws" (drgnx-view-patch-view drgnx-view-patch)))
                (should (equal "rows-ws" (plist-get (cdr (assoc "work/map/subscribe" asked)) :view)))
                (should (string-search "Map" (substring-no-properties drgnx-work-map--lens))))
            (kill-buffer buf)))))))

(ert-deftest drgnx-work-map-rows/without-sja-the-map-says-so ()
  "Pattern D: in an Emacs without Sjá the map, its side panel, its Board and its Flow say the map needs Sjá; the map
asks the hub nothing and its keys say the same."
  (let ((asked nil))
    (drgnx-test-with-modules '(tools/work-space)
      (cl-letf (((symbol-function 'drgnx-work-client--call) (lambda (method params _cb) (push (cons method params) asked) t))
                ((symbol-function 'drgnx-work-map-rows-p) #'ignore))
        (let* ((ws (list :id "no-sja-ws" :roots (list temporary-file-directory)))
               (buf (drgnx-work-space--buffer ws)) (others nil))
          (unwind-protect
              (progn
                (with-current-buffer buf
                  (should-not drgnx-view-patch)
                  (drgnx-view-draw-now drgnx-view)
                  (should (string-search "needs Sjá" (buffer-string)))
                  (should-error (drgnx-work-map-right) :type 'user-error)
                  (should-error (drgnx-work-map-needs-you-here-next) :type 'user-error))
                (setq others (list (drgnx-work-detail-buffer buf) (drgnx-work-board-open buf) (drgnx-work-flow-open buf)))
                (dolist (b others)
                  (should (string-search "needs Sjá" (with-current-buffer b (buffer-string)))))
                (should-not asked))
            (dolist (b (cons buf others)) (when (buffer-live-p b) (kill-buffer b)))))))))

;;; work-map-rows-test.el ends here
