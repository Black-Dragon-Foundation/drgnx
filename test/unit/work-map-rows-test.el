;;; work-map-rows-test.el --- batch tests: the Work map inserts the rows the hub builds -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: orders
;; Needs Sjá (a Nidhogg with `nidhogg-view--call') for the rows path; skipped elsewhere, except the old path's test.
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
                                        :lists ["team" "needs-you" "outline"] :classes ["selected" "match" "chain" "dim"]
                                        :flags ["needs-you"] :forms (vector (list :name "graph")) :start "team")
                      :nodes (vector
                              (list :id "ask:1" :kind "ask" :nav (list :down "agent:a") :fields [["label" "Fix"]])
                              (list :id "agent:a" :kind "agent" :nav (list :up "ask:1" :right "agent:b")
                                    :fields [["label" "alpha"]])
                              (list :id "agent:b" :kind "agent" :nav (list :up "ask:1" :left "agent:a")
                                    :fields [["label" "beta"]]))
                      :edges [["ask:1" "agent:a" "came-from"] ["ask:1" "agent:b" "came-from"]]
                      :lists (vector (list :name "team" :ids ["agent:a" "agent:b"])
                                     (list :name "needs-you" :ids [])
                                     (list :name "outline" :ids ["agent:a" "agent:b"])))))))
  "A small map model: an ask over two agents.")

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
     (skip-unless (fboundp 'nidhogg-view--call))
     (let ((drgnx-view-patch--buffers (make-hash-table :test #'equal))
           (drgnx-view-model--views (make-hash-table :test #'equal))
           (drgnx-view-patch--hooked nil)
           (drgnx-view-old-path nil)
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
  ;; the client's half: a rows view subscribes again with `rows' when the hub is back
  (let ((drgnx-work-client--views (make-hash-table :test #'equal)) (asked nil))
    (cl-letf (((symbol-function 'drgnx-work-client--call) (lambda (method params _cb) (push (cons method params) asked) t)))
      (drgnx-work-client-open "w1" (list :id "w1" :roots '("/r/")) :rows t)
      (setq asked nil)
      (drgnx-work-client-connected)
      (should (equal "work/map/subscribe" (car (car asked))))
      (should (eq t (plist-get (cdr (car asked)) :rows)))
      ;; its answer is the hub's id, not a frame: the view is live and keeps none
      (drgnx-work-client--subscribed "w1" (drgnx-work-client--view-gen (drgnx-work-client--get "w1")) (list :hub 9 :version 1) nil)
      (should (equal "live" (drgnx-work-client-status "w1")))
      (should-not (drgnx-work-client-view-state "w1")))))

(ert-deftest drgnx-work-map-rows/selected-is-sent-without-waiting ()
  "Pattern D: a key moves the selection at once, with no answer from the hub; the trailing notice then tells the hub
the selection with `work/map/set'."
  (drgnx-work-map-rows-test--with
    (drgnx-work-map-right)
    (should (equal '(agent . "agent:a") drgnx-work-map--selection))
    (should-not (assoc "work/map/set" drgnx-work-map-rows-test--sent))
    (drgnx-view-nav--notice buf)
    (should (equal (list :view view :selected "agent:a") (cdr (assoc "work/map/set" drgnx-work-map-rows-test--sent))))))

(ert-deftest drgnx-work-map-rows/old-path-switch-still-draws-the-map ()
  "Pattern D: with `drgnx-view-old-path' the map draws its own frames (its view type) and subscribes without `rows';
off it, with Sjá, the map is hub-fed and subscribes with `rows'."
  (let ((asked nil))
    (drgnx-test-with-modules '(tools/work-space)
      (cl-letf (((symbol-function 'drgnx-work-client--call) (lambda (method params _cb) (push (cons method params) asked) t)))
        (let* ((drgnx-view-old-path t) (ws (list :id "old-ws" :roots (list temporary-file-directory)))
               (buf (drgnx-work-space--buffer ws)))
          (unwind-protect
              (with-current-buffer buf
                (should-not drgnx-view-patch)
                (should (eq 'work-map (drgnx-view-type-name (drgnx-view--type drgnx-view))))
                (should-not (plist-get (cdr (assoc "work/map/subscribe" asked)) :rows)))
            (kill-buffer buf)))
        (when (fboundp 'nidhogg-view--call)
          (setq asked nil)
          (let* ((drgnx-view-old-path nil) (ws (list :id "rows-ws" :roots (list temporary-file-directory)))
                 (buf (drgnx-work-space--buffer ws)))
            (unwind-protect
                (with-current-buffer buf
                  (should drgnx-view-patch)
                  (should (equal "rows-ws" (drgnx-view-patch-view drgnx-view-patch)))
                  (should (eq t (plist-get (cdr (assoc "work/map/subscribe" asked)) :rows))))
              (kill-buffer buf))))))))

;;; work-map-rows-test.el ends here
