;;; work-nav-test.el --- the map's selection, its chain, keyboard navigation and the side panel -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: pure functions of the cached frame and the selection; the edge recolour that waits one frame runs on the
;; virtual clock (`drgnx-test-with-clock').
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-work-client)
(load (expand-file-name "test/fixtures/work-space-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-work-map" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-work-detail" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/work-space))

(declare-function drgnx-work-nav-chain "drgnx-work-detail")
(declare-function drgnx-work-nav-move "drgnx-work-detail")
(declare-function drgnx-work-nav-agent "drgnx-work-detail")
(declare-function drgnx-work-nav-resolve "drgnx-work-detail")
(declare-function drgnx-work-detail-text "drgnx-work-detail")
(declare-function drgnx-work-map-select "drgnx-work-map")
(defvar drgnx-work-map-scale)
(defvar drgnx-work-map--edge-selection)
(defvar drgnx-work-map-edges-functions)

(defvar drgnx-work-nav-test--n 0
  "A counter: each test's map view has an id of its own, so one test's pending timer never stands in for another's.")

(defun drgnx-work-nav-test--state ()
  (drgnx-work-client-init (drgnx-work-fixture-frame)))

(defun drgnx-work-nav-test--sel (state id)
  (cons (intern (plist-get (drgnx-work-client-item state id) :kind)) id))

(ert-deftest drgnx-work-nav/arrows-follow-the-cores-chains ()
  (let* ((state (drgnx-work-nav-test--state)) (a1 '(agent . "agent:a1")))
    (should (equal '(plan . "plan:deferred") (drgnx-work-nav-move state a1 'up)))
    (should (equal '(spec . "spec:race-proof") (drgnx-work-nav-move state '(plan . "plan:deferred") 'up)))
    (should (equal '(branch . "branch:drgnx/rp-df-hub") (drgnx-work-nav-move state a1 'down)))
    (should (equal '(agent . "agent:a2") (drgnx-work-nav-move state a1 'right)))
    (should (equal a1 (drgnx-work-nav-move state '(agent . "agent:a2") 'left)))
    (should (equal a1 (drgnx-work-nav-move state a1 'left)))                     ; the end of the layer: it stays
    (pcase-let ((`(,up ,down ,edges) (drgnx-work-nav-chain state a1)))
      (should (equal '("ask:1" "plan:deferred" "spec:race-proof") (sort (copy-sequence up) #'string<)))
      (should (equal '("agent:a1/t1" "branch:drgnx/rp-df-hub" "file:drgnx/src/session.rs" "machine:desktop")
                     (sort (copy-sequence down) #'string<)))
      (should (= 7 (length edges)))                                              ; the overlap is not on the chain
      (should-not (seq-some (lambda (e) (equal (plist-get e :kind) "overlap")) edges)))))

(ert-deftest drgnx-work-nav/tab-walks-team-order ()
  (let ((state (drgnx-work-nav-test--state)))
    (should (equal '(subagent . "agent:a1/t1") (drgnx-work-nav-agent state '(agent . "agent:a1") t)))
    (should (equal '(agent . "agent:a2") (drgnx-work-nav-agent state '(subagent . "agent:a1/t1") t)))
    (should (equal '(agent . "agent:a1") (drgnx-work-nav-agent state '(agent . "agent:a2") t)))        ; wraps
    (should (equal '(agent . "agent:a2") (drgnx-work-nav-agent state '(agent . "agent:a1") nil)))      ; and back
    (should (equal '(agent . "agent:a1") (drgnx-work-nav-agent state '(plan . "plan:deferred") t)))))   ; from a non-agent

(ert-deftest drgnx-work-nav/up-reaches-the-ask-in-at-most-6-keys ()
  (let ((state (drgnx-work-nav-test--state)))
    (dolist (id (drgnx-work-client-ids state))
      (unless (equal (plist-get (drgnx-work-client-item state id) :kind) "ask")
        (let ((sel (drgnx-work-nav-test--sel state id)) (keys 0))
          (while (and (not (eq (car sel) 'ask)) (< keys 7))
            (setq sel (drgnx-work-nav-move state sel 'up) keys (1+ keys)))
          (should (equal (list id 'ask t) (list id (car sel) (<= keys 6)))))))))

(defmacro drgnx-work-nav-test--with-map (&rest body)
  "BODY in a map buffer (a view of the fixture frame, the layout form) with `state' and `id' bound."
  (declare (indent 0))
  `(drgnx-test-with-modules '(tools/work-space)
     (let* ((drgnx-work-map-scale 1) (id (format "work-nav-test-%d" (cl-incf drgnx-work-nav-test--n)))
            (frame (drgnx-work-fixture-frame))
            (drgnx-work-client--views (make-hash-table :test #'equal)) (state (drgnx-work-client-init frame))
            (drgnx-work-client-change-functions '(drgnx-work-map--changed)))
       (puthash id (drgnx-work-client--make-view :id id :state state :status 'live) drgnx-work-client--views)
       (drgnx-work-fixture-with-buffer
         (drgnx-work-map-mode)
         (setq drgnx-work-space--view id drgnx-work-map--outline 'off)
         (drgnx-view-attach 'work-map)
         (drgnx-view-touch drgnx-view)
         (drgnx-view-draw-now drgnx-view)
         ,@body))))

(defun drgnx-work-nav-test--face-at (text)
  "The faces of the first TEXT in the buffer, as a list."
  (goto-char (point-min))
  (search-forward text)
  (ensure-list (get-text-property (match-beginning 0) 'face)))

(ert-deftest drgnx-work-nav/dimming-survives-a-row-reinsertion ()
  (drgnx-work-nav-test--with-map
    (drgnx-work-map-select '(agent . "agent:a1"))
    (drgnx-view-draw-now drgnx-view)
    (should (memq 'drgnx-work-selected (drgnx-work-nav-test--face-at "hub rows")))
    (should (memq 'drgnx-work-dim (drgnx-work-nav-test--face-at "fx-sess")))
    (should-not (memq 'drgnx-work-dim (drgnx-work-nav-test--face-at "deferred testing")))   ; the plan is on the chain
    ;; the row is deleted and inserted again: the same faces, from the cached selection, with no overlay
    (drgnx-view-dirty drgnx-view '((:row 4 0 0)))
    (drgnx-view-draw-now drgnx-view)
    (should (memq 'drgnx-work-selected (drgnx-work-nav-test--face-at "hub rows")))
    (should (memq 'drgnx-work-dim (drgnx-work-nav-test--face-at "fx-sess")))
    (should-not (overlays-in (point-min) (point-max)))))

(ert-deftest drgnx-work-nav/edges-follow-one-frame-later ()
  (drgnx-test-with-clock (:allow-pending t)
    (drgnx-work-nav-test--with-map
      (let* ((ran nil) (drgnx-work-map-edges-functions (list (lambda (_view sel) (push sel ran)))))
        (drgnx-work-map-select '(agent . "agent:a1"))
        (drgnx-work-map-select '(agent . "agent:a2"))                      ; a held arrow key
        (should-not drgnx-work-map--edge-selection)                         ; the cards are refaced; the tiles wait
        (should (drgnx-timer-active-p (cons 'work-edges id)))
        (drgnx-test-advance 1)
        (should (equal '(agent . "agent:a2") drgnx-work-map--edge-selection))
        (should (equal '((agent . "agent:a2")) ran))))))                    ; once, for the last selection

(ert-deftest drgnx-work-space/new-finding-shows-within-1s-and-clears-after-4s ()
  ;; a new conclusion marks its card `new' at once and a timer clears it 4 s later: one for the whole map
  (drgnx-test-with-clock (:allow-pending t)
    (drgnx-work-nav-test--with-map
      (drgnx-work-client-event
       "work-map" (plist-put (drgnx-work-fixture-delta
                              4 3 :changed (list (drgnx-work-fixture-changed frame "agent:a2" :conclusion "found the leak")))
                             :view id))
      (drgnx-view-draw-now drgnx-view)
      (should (string-search "found the leak" (buffer-string)))
      (should (string-search " new " (buffer-string)))
      (should (drgnx-timer-active-p (cons 'work-new id)))
      (drgnx-test-advance 3)
      (drgnx-view-draw-now drgnx-view)
      (should (string-search " new " (buffer-string)))                      ; still within the 4 s
      (drgnx-test-advance 2)
      (drgnx-view-draw-now drgnx-view)
      (should-not (string-search " new " (buffer-string)))
      (should (string-search "found the leak" (buffer-string))))))          ; the conclusion stays; the chip goes

(ert-deftest drgnx-work-nav/a-removed-selection-moves-to-its-parent ()
  (let* ((frame (drgnx-work-fixture-frame)) (state (drgnx-work-client-init frame))
         (gone (car (drgnx-work-client-step state (drgnx-work-fixture-delta 4 3 :removed '("agent:a1/t1"))))))
    ;; a subagent ends: the selection goes to the agent it came from, and the panel is told what finished
    (should (equal '((agent . "agent:a1") . "agent:a1/t1")
                   (drgnx-work-nav-resolve state gone '(subagent . "agent:a1/t1"))))
    ;; what still exists stays
    (should (equal '((agent . "agent:a1") . nil) (drgnx-work-nav-resolve state gone '(agent . "agent:a1"))))
    ;; an agent and its branch end: the nearest ancestor that is left
    (let ((both (car (drgnx-work-client-step
                      state (drgnx-work-fixture-delta
                             4 3 :removed '("agent:a1" "agent:a1/t1" "branch:drgnx/rp-df-hub"))))))
      (should (equal '((plan . "plan:deferred") . "branch:drgnx/rp-df-hub")
                     (drgnx-work-nav-resolve state both '(branch . "branch:drgnx/rp-df-hub")))))))

(ert-deftest drgnx-work-detail/every-edge-in-words ()
  ;; the side panel is the text alternative to the lines: each edge's two ends name each other in their panels
  (let* ((state (drgnx-work-nav-test--state))
         (label (lambda (id) (plist-get (drgnx-work-client-item state id) :label)))
         (words '(("came-from" . "came from") ("edits" . "edits") ("runs-on" . "runs on") ("overlap" . "overlaps with"))))
    (dolist (e (drgnx-work-client-edges state))
      (let ((from (plist-get e :from)) (to (plist-get e :to)))
        (should (string-search (funcall label to) (drgnx-work-detail-text state (drgnx-work-nav-test--sel state from))))
        (should (string-search (funcall label from) (drgnx-work-detail-text state (drgnx-work-nav-test--sel state to))))
        (should (string-search (cdr (assoc (plist-get e :kind) words))
                               (drgnx-work-detail-text state (drgnx-work-nav-test--sel state from))))))
    ;; the other parts of the panel
    (let ((text (drgnx-work-detail-text state '(agent . "agent:a1"))))
      (should (string-search "why" text))
      (should (string-search "you: \"fix deferred testing rows\"" text))
      (should (string-search "turn_core drops the started flag" text))
      (should (string-search "open" text)))))

(provide 'work-nav-test)
;;; work-nav-test.el ends here
