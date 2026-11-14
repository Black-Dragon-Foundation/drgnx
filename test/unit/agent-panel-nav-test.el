;;; agent-panel-nav-test.el --- batch tests: the agent panel's next/previous keys and fold answer from Sjá -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; Needs Sjá (a Nidhogg with `nidhogg-view--call'); skipped elsewhere.  No hub: the panel's buffer is the hub-fed view
;; `agent-panel/SESSION', given a model shaped like the hub's (view/panel.rs: a `list' scheme of the steps alone, each
;; its kind, entry and diff) and its rows; what the panel sends is recorded.  Each test names its pattern.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-hub-client)
(require 'drgnx-agents)
(require 'drgnx-agents-mirror)
(require 'drgnx-view-nav)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/agent-panel))

(declare-function drgnx-agent-panel-buffer "drgnx-agent-panel")

(defvar drgnx-agent-panel-nav-test--n 0 "Each run's panel gets a session (and so a view) of its own in Sjá.")
(defvar drgnx-agent-panel-nav-test--sent nil "What the panel sent the hub, newest first: (METHOD . PARAMS).")

(defconst drgnx-agent-panel-nav-test--steps
  '((0 "user") (1 "tool" hunk) (2 "agent") (3 "tool") (4 "user"))
  "The transcript: (INDEX KIND [hunk]), the hub's group heads.")

(defun drgnx-agent-panel-nav-test--model ()
  "The hub's model of the steps above: a node each, its kind, entry and diff."
  (json-serialize
   (list :ops
         (vector
          (list :reset
                (list :descriptor (list :scheme "list" :chain_kinds [] :match_fields [] :classes ["selected"]
                                        :flags [] :forms [] :start :null :lists [])
                      :nodes (vconcat (mapcar (lambda (s) (list :id (format "e:%d" (car s)) :kind (nth 1 s) :flags 0
                                                                :fields (vector (vector "entry" (car s))
                                                                                (vector "diff" (if (nth 2 s) 1 0)))))
                                              drgnx-agent-panel-nav-test--steps))
                      :edges []
                      :lists []))))))

(defun drgnx-agent-panel-nav-test--rows ()
  "The hub's rows of the steps: one each, its entry and its node id over the whole row."
  (mapcar (lambda (s)
            (let ((text (format "  step %d" (car s))) (id (format "e:%d" (car s))))
              (list :key id :text text
                    :props (list (list 0 (length text) "drgnx-agent-panel-entry" (car s))
                                 (list 0 (length text) "drgnx-work-id" id)))))
          drgnx-agent-panel-nav-test--steps))

(defmacro drgnx-agent-panel-nav-test--with (&rest body)
  "BODY in a fresh panel on the rows path holding the model and rows above, nothing selected, sends recorded."
  (declare (indent 0))
  `(progn
     (drgnx-test-require-nidhogg (fboundp 'nidhogg-view-push) "nidhogg-view-push")
     (let* ((drgnx-agent-panel-nav-test--sent nil)
            (drgnx-view-patch--buffers (make-hash-table :test #'equal))
            (drgnx-view-model--views (make-hash-table :test #'equal))
            (drgnx-view-patch-send-function (lambda (m p) (push (cons m p) drgnx-agent-panel-nav-test--sent)))
            (sid (format "nav-%d" (cl-incf drgnx-agent-panel-nav-test--n)))
            (view (concat "agent-panel/" sid)))
       (drgnx-test-with-modules '(tools/agent-panel)
         (cl-letf (((symbol-function 'drgnx-hub-call)
                    (lambda (method params _cb &rest _) (push (cons method params) drgnx-agent-panel-nav-test--sent) 1))
                   ((symbol-function 'drgnx-agent-panel--hub-up-p) (lambda () t)))
           (let ((buf (drgnx-agent-panel-buffer sid)))
             (unwind-protect
                 (with-current-buffer buf
                   (drgnx-view-model-event (list :view view :hub 7 :base 0 :version 1 :reset t
                                                 :model (drgnx-agent-panel-nav-test--model)))
                   (drgnx-view-apply-patch (list :view view :class (drgnx-view-patch-class drgnx-view-patch) :hub 7
                                                 :base 0 :version 1 :env_epoch 0 :model 1
                                                 :ops (list (list :reset (drgnx-agent-panel-nav-test--rows)))))
                   (drgnx-view-draw-now drgnx-view)
                   ,@body)
               (drgnx-timer-cancel (cons 'drgnx-view-nav-notice buf))
               (drgnx-timer-cancel (cons 'drgnx-view-model view))
               (let ((kill-buffer-query-functions nil)) (kill-buffer buf)))))))))

(defun drgnx-agent-panel-nav-test--goto (id)
  "Point to the row of node ID."
  (goto-char (point-min))
  (goto-char (prop-match-beginning (text-property-search-forward 'drgnx-work-id id #'equal))))

(defun drgnx-agent-panel-nav-test--at ()
  "The node at point."
  (get-text-property (point) 'drgnx-work-id))

(ert-deftest drgnx-agent-panel-nav/next-and-previous-of-a-kind-from-point ()
  "Pattern D: from the step at point, the next and previous tool call, change and message go through the model's
kinds in Sjá, wrapping, and point follows."
  (drgnx-agent-panel-nav-test--with
    (setq drgnx-agent-panel-nav-test--sent nil)
    (drgnx-agent-panel-nav-test--goto "e:2")
    (drgnx-agent-panel-next-tool)
    (should (equal (drgnx-view-nav-selection) "e:3"))
    (should (equal (drgnx-agent-panel-nav-test--at) "e:3"))
    (drgnx-agent-panel-next-tool)
    (should (equal (drgnx-agent-panel-nav-test--at) "e:1"))
    (drgnx-agent-panel-previous-tool)
    (should (equal (drgnx-agent-panel-nav-test--at) "e:3"))
    (drgnx-agent-panel-previous-change)
    (should (equal (drgnx-agent-panel-nav-test--at) "e:1"))
    (drgnx-agent-panel-next-prompt)
    (should (equal (drgnx-agent-panel-nav-test--at) "e:4"))
    (drgnx-agent-panel-next-prompt)
    (should (equal (drgnx-agent-panel-nav-test--at) "e:0"))
    ;; point moved by hand: the next move starts from there
    (drgnx-agent-panel-nav-test--goto "e:2")
    (drgnx-agent-panel-previous-prompt)
    (should (equal (drgnx-agent-panel-nav-test--at) "e:0"))
    ;; past the last tool call from a step that is none: the first
    (drgnx-agent-panel-nav-test--goto "e:4")
    (drgnx-agent-panel-next-tool)
    (should (equal (drgnx-agent-panel-nav-test--at) "e:1"))
    ;; no move asked the hub anything
    (should-not drgnx-agent-panel-nav-test--sent)))

(ert-deftest drgnx-agent-panel-nav/fold-is-user-state-sent-after ()
  "Pattern D: a fold changes the panel's own state at once and tells the hub after (`agents/panel/look'); off a step
it folds the selected one."
  (drgnx-agent-panel-nav-test--with
    (drgnx-agent-panel-nav-test--goto "e:2")
    (drgnx-agent-panel-next-tool)
    (setq drgnx-agent-panel-nav-test--sent nil)
    (goto-char (point-min))                ; the header: not a step
    (drgnx-agent-panel-toggle)
    (let ((look (cdr (assoc "agents/panel/look" drgnx-agent-panel-nav-test--sent))))
      (should look)
      (should (equal (plist-get look :view) (drgnx-view-patch-view drgnx-view-patch)))
      (should (seq-some (lambda (r) (eql (aref r 0) 3)) (plist-get look :rows))))))
