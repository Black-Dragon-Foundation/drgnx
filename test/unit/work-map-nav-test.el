;;; work-map-nav-test.el --- batch tests: the Work map's keys on the rows path answer from the model in Sjá -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: orders
;; Needs Sjá (a Nidhogg with `nidhogg-view--call'); skipped elsewhere.  No hub: the map buffer is attached as a
;; hub-fed view, given a model shaped like the hub's map model (work::map::model) and one row of cards, and every key
;; is a command run in it.  Each test names its pattern.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-view)
(require 'drgnx-view-nav)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-work-map" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/work-space))

(defvar drgnx-work-map-nav-test--n 0 "Each run's view gets a name of its own in Sjá.")

(defconst drgnx-work-map-nav-test--model
  (json-serialize
   (list :ops
         (vector
          (list :reset
                (list :descriptor (list :scheme "links" :chain_kinds ["came-from"] :match_fields ["label" "task"]
                                        :lists ["team" "needs-you" "outline"]
                                        :classes ["selected" "match" "chain" "dim"]
                                        :flags ["needs-you" "warn" "live"]
                                        :forms (vector (list :name "graph") (list :name "outline" :list "outline"))
                                        :start "team")
                      :nodes (vector
                              (list :id "ask:1" :kind "ask" :nav (list :down "agent:a")
                                    :fields [["label" "Fix login"]])
                              (list :id "agent:a" :kind "agent" :flags 1 :nav (list :up "ask:1" :right "agent:b")
                                    :fields [["label" "alpha"] ["task" "login"] ["x" 0] ["y" 10] ["w" 20] ["h" 6]])
                              (list :id "agent:b" :kind "agent" :nav (list :up "ask:1" :left "agent:a" :down "file:r/x.el")
                                    :fields [["label" "beta"] ["task" "docs"]])
                              (list :id "file:r/x.el" :kind "file" :nav (list :up "agent:b")
                                    :fields [["label" "x.el"]]))
                      :edges [["ask:1" "agent:a" "came-from"] ["ask:1" "agent:b" "came-from"]
                              ["agent:b" "file:r/x.el" "came-from"]]
                      :lists (vector (list :name "team" :ids ["agent:a" "agent:b"])
                                     (list :name "needs-you" :ids ["agent:b" "ask:1"])
                                     (list :name "outline" :ids ["agent:a" "agent:b"])))))))
  "The hub's map model, small: an ask over two agents, b touching a file; b and the ask need you.")

(defun drgnx-work-map-nav-test--row ()
  "One row holding every card: \"QQ AA BB FF\"."
  (list :key "r" :text "QQ AA BB FF"
        :props (list (list 0 2 "drgnx-work-id" "ask:1") (list 3 5 "drgnx-work-id" "agent:a")
                     (list 6 8 "drgnx-work-id" "agent:b") (list 9 11 "drgnx-work-id" "file:r/x.el"))))

(defmacro drgnx-work-map-nav-test--with (&rest body)
  "BODY in a map buffer on the rows path holding the model, nothing selected, sending captured."
  (declare (indent 0))
  `(progn
     (drgnx-test-require-nidhogg (fboundp 'nidhogg-view-push) "nidhogg-view-push")
     (let ((drgnx-view-patch--buffers (make-hash-table :test #'equal))
           (drgnx-view-model--views (make-hash-table :test #'equal))
           (drgnx-view-patch--hooked nil)
           (drgnx-view-old-path nil)
           (drgnx-view-patch-send-function #'ignore)
           (drgnx-work-map-select-functions nil)
           (view (format "wmn-test-%d" (cl-incf drgnx-work-map-nav-test--n))))
       (with-temp-buffer
         (drgnx-work-map-mode)
         (let ((buf (current-buffer)))
           (drgnx-view-patch-attach view "c" :epoch 1)
           (unwind-protect
               (progn
                 (drgnx-view-model-event (list :view view :hub 7 :base 0 :version 1 :reset t
                                               :model drgnx-work-map-nav-test--model))
                 (drgnx-view-apply-patch (list :view view :class "c" :hub 7 :base 0 :version 1 :env_epoch 1 :model 1
                                               :ops (list (list :reset (list (drgnx-work-map-nav-test--row))))))
                 (drgnx-view-draw-now drgnx-view)
                 ,@body)
             (drgnx-view-patch-teardown)
             (drgnx-timer-cancel (cons 'drgnx-view buf))
             (drgnx-timer-cancel (cons 'drgnx-view-nav-notice buf))
             (drgnx-timer-cancel (cons 'drgnx-view-model view))))))))

(defun drgnx-work-map-nav-test--faces (pos)
  (delq nil (mapcar (lambda (o) (overlay-get o 'face)) (overlays-at (+ (point-min) pos)))))

(ert-deftest drgnx-work-map-nav/why-follows-up ()
  "Pattern D: from nothing the first key takes the team's first agent; `why' follows its up link to the ask, and
the selection is the map's (KIND . ID), point on the card."
  (drgnx-work-map-nav-test--with
    (drgnx-work-map-right)
    (should (equal '(agent . "agent:a") drgnx-work-map--selection))
    (drgnx-work-map-why)
    (should (equal '(ask . "ask:1") drgnx-work-map--selection))
    (should (= (point) (point-min)))
    (drgnx-work-map-touches)
    (should (equal '(agent . "agent:a") drgnx-work-map--selection))
    (should (equal '(drgnx-view-selected) (drgnx-work-map-nav-test--faces 3)))))

(ert-deftest drgnx-work-map-nav/back-and-forward-retrace-the-moves ()
  "Pattern D (SJA-HISTORY-1): back returns to where the selection was before the last move, a run of arrows counting
as one move; forward redoes it; each keeps the map's (KIND . ID)."
  (drgnx-work-map-nav-test--with
    (drgnx-work-map-right)
    (drgnx-work-map-why)
    (drgnx-work-map-touches)
    (should (equal '(agent . "agent:a") drgnx-work-map--selection))
    (drgnx-work-map-back)
    (should (equal '(agent . "agent:a") drgnx-work-map--selection))
    (drgnx-work-map-next-agent)
    (drgnx-work-map-back)
    (should (equal '(agent . "agent:a") drgnx-work-map--selection))
    (drgnx-work-map-forward)
    (should-not (equal '(agent . "agent:a") drgnx-work-map--selection))
    (drgnx-work-map-back)
    (should (equal '(agent . "agent:a") drgnx-work-map--selection))))

(ert-deftest drgnx-work-map-nav/next-agent-walks-team ()
  "Pattern A: next and previous agent walk the team list, wrapping, in every order of the two keys from a."
  (dolist (order '((next next) (next previous) (previous next) (previous previous)))
    (drgnx-work-map-nav-test--with
      (drgnx-work-map--nav 'select "agent:a")
      (dolist (k order) (if (eq k 'next) (drgnx-work-map-next-agent) (drgnx-work-map-previous-agent)))
      (should (equal '(agent . "agent:a") drgnx-work-map--selection))   ; two agents: any two steps come back
      (drgnx-work-map-next-agent)
      (should (equal '(agent . "agent:b") drgnx-work-map--selection)))))

(ert-deftest drgnx-work-map-nav/needs-you-n-walks-targets ()
  "Pattern D: g N takes the Nth entry of the model's needs-you list; n and p cycle it; a missing N selects nothing."
  (drgnx-work-map-nav-test--with
    (drgnx-work-map-needs-you 2)
    (should (equal '(ask . "ask:1") drgnx-work-map--selection))
    (drgnx-work-map-needs-you-here-next)
    (should (equal '(agent . "agent:b") drgnx-work-map--selection))
    (drgnx-work-map-needs-you-here-previous)
    (should (equal '(ask . "ask:1") drgnx-work-map--selection))
    (let ((inhibit-message t)) (drgnx-work-map-needs-you 5))
    (should (equal '(ask . "ask:1") drgnx-work-map--selection))))

(ert-deftest drgnx-work-map-nav/open-reads-fields-once ()
  "Pattern D: opening the selected agent asks Sjá once (its label) and opens that agent's transcript; the kind came
with the selection.  A file opens at the agents on its chain."
  (drgnx-work-map-nav-test--with
    (drgnx-work-map--nav 'select "agent:a")
    (let ((gets 0) (opened nil) (real (symbol-function 'nidhogg-view--call)))
      (cl-letf (((symbol-function 'nidhogg-view--call)
                 (lambda (op &rest args) (when (eql op 8) (cl-incf gets)) (apply real op args)))
                ((symbol-function 'drgnx-work--open-agent) (lambda (sid) (push sid opened))))
        (drgnx-work-map-open-selection))
      (should (equal '("a") opened))
      (should (= 1 gets)))
    (drgnx-work-map--nav 'select "file:r/x.el")
    (let ((agents :none))
      (cl-letf (((symbol-function 'drgnx-work-code-open-file)
                 (lambda (_state _sel &rest keys) (setq agents (plist-get keys :agents)))))
        (drgnx-work-map-open-selection))
      (should (equal '("b") agents)))))

(ert-deftest drgnx-work-map-nav/search-dims-non-matches ()
  "Pattern D: a search dims the cards that do not match (on their spans) and selects the first match; escape
clears it."
  (drgnx-work-map-nav-test--with
    (drgnx-work-map-search "doc")
    (should (equal '(agent . "agent:b") drgnx-work-map--selection))
    (should (equal '(shadow) (drgnx-work-map-nav-test--faces 3)))
    (should (equal '(shadow) (drgnx-work-map-nav-test--faces 0)))
    (should (equal '(drgnx-view-selected) (drgnx-work-map-nav-test--faces 6)))
    (should-not (drgnx-work-map-nav-test--faces 2))
    (drgnx-work-map-escape)
    (should-not drgnx-work-map--search)
    (should-not (memq 'drgnx-view-match (drgnx-work-map-nav-test--faces 3)))))

(ert-deftest drgnx-work-map-nav/motion-rects-come-from-the-model ()
  "Pattern D: on the rows path a card's rect for motion capture is the model's fields x y w h; a card without them
has none."
  (drgnx-work-map-nav-test--with
    (should (equal '(:x 0 :y 10 :w 20 :h 6) (drgnx-work-map--rect nil "agent:a")))
    (should-not (drgnx-work-map--rect nil "agent:b"))))

(ert-deftest drgnx-work-detail/rows-follow-the-selection ()
  "Pattern D: beside a map on the rows path the Detail panel is the hub's view VIEW/detail in the map's class: its
rows are what the hub sends there, and a selection move redraws nothing here (the hub follows the selection, which
the map sends as work/map/set)."
  (drgnx-work-map-nav-test--with
    (load (expand-file-name "modules/tools/drgnx-work-detail" drgnx-dir) nil t)
    (let* ((map-view (drgnx-view-patch-view drgnx-view-patch))
           (detail (drgnx-work-detail-buffer (current-buffer))))
      (unwind-protect
          (with-current-buffer detail
            (should (equal (concat map-view "/detail") (drgnx-view-patch-view drgnx-view-patch)))
            (should (equal "c" (drgnx-view-patch-class drgnx-view-patch)))
            (drgnx-view-apply-patch (list :view (concat map-view "/detail") :class "c" :hub 7 :base 0 :version 1
                                          :env_epoch 0
                                          :ops (list (list :reset (list (list :key "head/0" :text "beta · agent"))))))
            (drgnx-view-draw-now drgnx-view)
            (should (equal "beta · agent" (string-trim (buffer-string))))
            (let ((touched 0))
              (cl-letf (((symbol-function 'drgnx-view-touch) (lambda (&rest _) (cl-incf touched))))
                (drgnx-work-detail-update (buffer-local-value 'drgnx-work-detail--map detail)))
              (should (= 0 touched))))
        (kill-buffer detail)))))

;;; work-map-nav-test.el ends here
