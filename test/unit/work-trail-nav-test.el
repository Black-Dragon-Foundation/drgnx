;;; work-trail-nav-test.el --- batch tests: the Timeline's and the trail's keys on the rows path answer from Sjá -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; Needs Sjá (a Nidhogg with `nidhogg-view--call'); skipped elsewhere.  No hub: the buffer is attached as a hub-fed
;; view, given a model shaped like the hub's (work::trail::model) and its rows, and every key is a call of the lens's
;; nav in it.  Each test names its pattern.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-view)
(require 'drgnx-view-nav)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-work-map" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-work-trail" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/work-space))

(defvar drgnx-work-trail-nav-test--n 0 "Each run's view gets a name of its own in Sjá.")

(defun drgnx-work-trail-nav-test--node (id kind nav fields)
  (list :id id :kind kind :flags 0 :nav nav :fields (vconcat fields)))

(defun drgnx-work-trail-nav-test--descriptor (lists chain start)
  (list :scheme "links" :chain_kinds (vconcat chain) :match_fields ["label"] :lists (vconcat lists)
        :classes ["selected" "match" "chain" "lit" "dim"] :flags [] :forms (vector (list :name "rows")) :start start))

(defun drgnx-work-trail-nav-test--timeline (near)
  "The hub's Timeline model of two lanes, a (steps 1 and 2) and b (step 1), lane NEAR lit."
  (json-serialize
   (list :ops
         (vector
          (list :reset
                (list :descriptor (drgnx-work-trail-nav-test--descriptor '("lanes" "lasts" "near") nil "lasts")
                      :nodes (vector
                              (drgnx-work-trail-nav-test--node "lane:a" "lane" (list :down "lane:b" :up "lane:b" :right "step:a:2")
                                                               '(["label" "alpha"] ["session" "a"]))
                              (drgnx-work-trail-nav-test--node "lane:b" "lane" (list :down "lane:a" :up "lane:a" :right "step:b:1")
                                                               '(["label" "beta"] ["session" "b"]))
                              (drgnx-work-trail-nav-test--node "step:a:1" "step" (list :left "lane:a" :right "step:a:2" :down "step:b:1" :up "step:b:1")
                                                               '(["label" "Read f1"] ["seq" 1] ["class" "tool"] ["session" "a"]))
                              (drgnx-work-trail-nav-test--node "step:a:2" "step" (list :left "step:a:1" :down "step:b:1" :up "step:b:1")
                                                               '(["label" "Read f2"] ["seq" 2] ["class" "tool"] ["session" "a"]))
                              (drgnx-work-trail-nav-test--node "step:b:1" "step" (list :left "lane:b" :down "step:a:2" :up "step:a:2")
                                                               '(["label" "Read g"] ["seq" 1] ["class" "tool"] ["tool" "Read"]
                                                                 ["detail-kind" "read"] ["path" "src/g.rs"] ["line" 7]
                                                                 ["session" "b"])))
                      :edges []
                      :lists (vector (list :name "lanes" :ids ["lane:a" "lane:b"])
                                     (list :name "lasts" :ids ["step:a:2" "step:b:1"])
                                     (list :name "near" :ids (vector near)))))))))

(defun drgnx-work-trail-nav-test--timeline-rows ()
  "The Timeline's rows: a lane each, its label then a segment per step (\"alpha 12\", \"beta 1\")."
  (list (list :key "lane:a" :text "alpha 12"
              :props (list (list 0 5 "drgnx-work-id" "lane:a") (list 6 7 "drgnx-work-id" "step:a:1")
                           (list 7 8 "drgnx-work-id" "step:a:2")))
        (list :key "lane:b" :text "beta 1"
              :props (list (list 0 4 "drgnx-work-id" "lane:b") (list 5 6 "drgnx-work-id" "step:b:1")))))

(defun drgnx-work-trail-nav-test--trail ()
  "The hub's trail model: steps 1 and 2, then conclusion 1 resting on both."
  (json-serialize
   (list :ops
         (vector
          (list :reset
                (list :descriptor (drgnx-work-trail-nav-test--descriptor '("steps") '("rests-on") "steps")
                      :nodes (vector
                              (drgnx-work-trail-nav-test--node "step:1" "step" (list :down "step:2" :right "step:2")
                                                               '(["label" "Read a"] ["seq" 1] ["class" "tool"]))
                              (drgnx-work-trail-nav-test--node "step:2" "step" (list :up "step:1" :left "step:1"
                                                                                     :down "conc:1" :right "conc:1")
                                                               '(["label" "Read b"] ["seq" 2] ["class" "tool"]))
                              (drgnx-work-trail-nav-test--node "conc:1" "conclusion" (list :up "step:2" :left "step:2")
                                                               '(["label" "it holds"] ["n" 1] ["conclusion-kind" "finding"])))
                      :edges [["conc:1" "step:1" "rests-on"] ["conc:1" "step:2" "rests-on"]]
                      :lists (vector (list :name "steps" :ids ["step:1" "step:2"]))))))))

(defun drgnx-work-trail-nav-test--trail-rows ()
  (list (list :key "step:1" :text "Read a" :props (list (list 0 6 "drgnx-work-id" "step:1")))
        (list :key "step:2" :text "Read b" :props (list (list 0 6 "drgnx-work-id" "step:2")))
        (list :key "conc:1:0" :text "finding 1 it holds" :props (list (list 0 18 "drgnx-work-id" "conc:1")))))

(defmacro drgnx-work-trail-nav-test--with (mode model rows &rest body)
  "BODY in a MODE buffer on the rows path holding MODEL (a JSON string) and ROWS, nothing selected, sending dropped."
  (declare (indent 3))
  `(progn
     (drgnx-test-require-nidhogg (fboundp 'nidhogg-view-push) "nidhogg-view-push")
     (let ((drgnx-view-patch--buffers (make-hash-table :test #'equal))
           (drgnx-view-model--views (make-hash-table :test #'equal))
           (drgnx-view-patch--hooked nil)
           (drgnx-view-old-path nil)
           (drgnx-view-patch-send-function #'ignore)
           (view (format "wtn-test-%d" (cl-incf drgnx-work-trail-nav-test--n))))
       (with-temp-buffer
         (funcall ,mode)
         (let ((buf (current-buffer)))
           (drgnx-view-patch-attach view "c" :epoch 1)
           (unwind-protect
               (progn
                 (drgnx-view-model-event (list :view view :hub 7 :base 0 :version 1 :reset t :model ,model))
                 (drgnx-view-apply-patch (list :view view :class "c" :hub 7 :base 0 :version 1 :env_epoch 1 :model 1
                                               :ops (list (list :reset ,rows))))
                 (drgnx-view-draw-now drgnx-view)
                 ,@body)
             (drgnx-view-patch-teardown)
             (drgnx-timer-cancel (cons 'drgnx-view buf))
             (drgnx-timer-cancel (cons 'drgnx-view-nav-notice buf))
             (drgnx-timer-cancel (cons 'drgnx-view-model view))))))))

(defun drgnx-work-trail-nav-test--faces (pos)
  (delq nil (mapcar (lambda (o) (overlay-get o 'face)) (overlays-at (+ (point-min) pos)))))

(ert-deftest drgnx-work-trail-nav/lane-moves ()
  "Pattern D: the Timeline's keys follow the model's links: from nothing a key takes the first lane's last step; left
runs along the lane, down crosses to the nearest step below, next-agent back up; open opens the selected step as the
model says it (its session and source)."
  (drgnx-work-trail-nav-test--with #'drgnx-work-timeline-mode (drgnx-work-trail-nav-test--timeline "lane:a")
                                   (drgnx-work-trail-nav-test--timeline-rows)
    (drgnx-work-timeline--nav 'right)
    (should (equal "step:a:2" (drgnx-view-nav-selection)))
    (drgnx-work-timeline--nav 'left)
    (should (equal "step:a:1" (drgnx-view-nav-selection)))
    (drgnx-work-timeline--nav 'left)
    (should (equal "lane:a" (drgnx-view-nav-selection)))
    (drgnx-work-timeline--nav 'right)
    (drgnx-work-timeline--nav 'down)
    (should (equal "step:b:1" (drgnx-view-nav-selection)))
    (should (equal '(drgnx-view-selected) (drgnx-work-trail-nav-test--faces 14)))
    (let ((opened nil))
      (cl-letf (((symbol-function 'drgnx-work-trail-open-step) (lambda (step &rest _) (push step opened))))
        (drgnx-work-timeline--nav 'open))
      (should (equal "b" (plist-get (car opened) :session)))
      (should (eql 1 (plist-get (car opened) :seq)))
      (should (equal "src/g.rs" (plist-get (plist-get (car opened) :detail) :path)))
      (should (eql 7 (plist-get (plist-get (car opened) :detail) :line_start)))
      (should (eq 'read (drgnx-work-trail-kind (car opened)))))
    (should (equal "b" (drgnx-work-trail--agent-sid)))
    (drgnx-work-timeline--nav 'next-agent)
    (should (equal "step:a:2" (drgnx-view-nav-selection)))))

(ert-deftest drgnx-work-trail-nav/lit-follows-map-selection ()
  "Pattern D: the Timeline lights the lanes of the model's list `near' in the chain's face; when the hub sends a model
whose `near' names another lane (the map's selection moved) and no rows, its timer moves the light."
  (drgnx-work-trail-nav-test--with #'drgnx-work-timeline-mode (drgnx-work-trail-nav-test--timeline "lane:a")
                                   (drgnx-work-trail-nav-test--timeline-rows)
    (drgnx-work-timeline-rows-attached)
    (drgnx-view-nav-class-step drgnx-view)
    (should (equal '(drgnx-work-chain) (drgnx-work-trail-nav-test--faces 0)))
    (should-not (drgnx-work-trail-nav-test--faces 9))
    (let ((model (json-serialize (list :ops (vector (list :list (list :name "near" :ids ["lane:b"])))))))
      (drgnx-view-model-event (list :view (drgnx-view-patch-view drgnx-view-patch) :hub 7 :base 1 :version 2
                                    :model model)))
    (should (equal '(drgnx-work-chain) (drgnx-work-trail-nav-test--faces 0)))   ; queued, not applied yet
    (drgnx-view-model--due (drgnx-view-patch-view drgnx-view-patch))
    (should-not (drgnx-work-trail-nav-test--faces 0))
    (should (equal '(drgnx-work-chain) (drgnx-work-trail-nav-test--faces 9)))))

(ert-deftest drgnx-work-trail-nav/trail-walks-rows-and-lights-the-rests ()
  "Pattern D: in a trail, down walks the rows (steps, then the conclusion after its step); a selected conclusion puts
the steps it rests on in the chain class; open on it opens the conclusion with its number and text."
  (drgnx-work-trail-nav-test--with #'drgnx-work-trail-mode (drgnx-work-trail-nav-test--trail)
                                   (drgnx-work-trail-nav-test--trail-rows)
    (drgnx-work-trail--nav 'down)
    (should (equal "step:1" (drgnx-view-nav-selection)))
    (drgnx-work-trail--nav 'down)
    (drgnx-work-trail--nav 'down)
    (should (equal "conc:1" (drgnx-view-nav-selection)))
    (should (equal '(drgnx-view-chain) (drgnx-work-trail-nav-test--faces 0)))
    (should (equal '(drgnx-view-chain) (drgnx-work-trail-nav-test--faces 7)))
    (let ((opened nil))
      (cl-letf (((symbol-function 'drgnx-work-trail--open-conclusion) (lambda (c _beside) (push c opened))))
        (drgnx-work-trail--nav 'open))
      (should (eql 1 (plist-get (car opened) :n)))
      (should (equal "it holds" (plist-get (car opened) :text))))
    (drgnx-work-trail--nav 'up)
    (should (equal "step:2" (drgnx-view-nav-selection)))))

;;; work-trail-nav-test.el ends here
