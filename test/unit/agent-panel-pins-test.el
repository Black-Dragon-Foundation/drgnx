;;; agent-panel-pins-test.el --- the agent panel: pinned cards, the to-do list, the edits ledger -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: pure.  No hub: the panel is fed snapshots and entries by hand, and the hub client's calls are recorded.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-hub-client)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/agent-panel))

(declare-function drgnx-agent-panel-buffer "drgnx-agent-panel")
(declare-function drgnx-agent-panel--take-entries "drgnx-agent-panel")
(declare-function drgnx-agent-panel-pin "drgnx-agent-panel-cards")
(declare-function drgnx-agent-panel-ledger "drgnx-agent-panel-cards")

(defmacro drgnx-agent-panel-pins-test--with (&rest body)
  "BODY with the module set up, the hub's calls swallowed, and panel \"s1\" as `buf'."
  (declare (indent 0))
  `(let (buf)
     (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (&rest _) 1)))
       (drgnx-test-with-modules '(tools/agent-panel)
         (unwind-protect (progn (setq buf (drgnx-agent-panel-buffer "s1")) ,@body)
           (when (buffer-live-p buf) (kill-buffer buf)))))))

(defun drgnx-agent-panel-pins-test--text (buf)
  (with-current-buffer buf
    (drgnx-view-draw-now drgnx-view)
    (buffer-substring-no-properties (point-min) (point-max))))

;;; hub rows: the pinned cards, the to-do list and the ledger are the hub's (view/panel_cards.rs).  What stays here is
;;; the state the editor keeps and sends: what is pinned, and whether the ledger is open.

(defvar drgnx-agent-panel--pins)
(defvar drgnx-agent-panel--ledger-open)
(declare-function drgnx-agent-panel--look-params "drgnx-agent-panel")

(ert-deftest drgnx-agent-panel/pin-a-card ()
  "A pin is the step's one line, sent to the hub with the look (`pins'); pinned again, or from its card (the hub's row
carries `drgnx-agent-panel-pin'), it goes; what is not a step or a card cannot be pinned."
  (drgnx-agent-panel-pins-test--with
    (with-current-buffer buf
      (drgnx-agent-panel--take-entries
       (list (list 0 (list :type "tool" :id "t1" :title "Read the spec" :kind "read" :status "completed"))
             (list 1 (list :type "tool" :id "t2" :title "Run the tests" :kind "execute" :status "completed"))))
      (drgnx-agent-panel-pins-test--text buf)
      (goto-char (drgnx-view-row-start drgnx-view '(:e 1)))
      (drgnx-agent-panel-pin)
      (should (equal '("Run the tests") (append (plist-get (drgnx-agent-panel--look-params) :pins) nil)))
      ;; pinned again from the step: gone; and pinned, then unpinned from the card
      (drgnx-agent-panel-pin)
      (should (= 0 (length (plist-get (drgnx-agent-panel--look-params) :pins))))
      (drgnx-agent-panel-pin)
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert (propertize "card" 'drgnx-agent-panel-pin 0))
        (goto-char (- (point-max) 2)))
      (drgnx-agent-panel-pin)
      (should-not drgnx-agent-panel--pins)
      ;; something that is not a card cannot be pinned
      (goto-char (drgnx-view-row-start drgnx-view '(:composer)))
      (should-error (drgnx-agent-panel-pin) :type 'user-error))))

(ert-deftest drgnx-agent-panel/the-ledger-open-flag-goes-to-the-hub ()
  (drgnx-agent-panel-pins-test--with
    (with-current-buffer buf
      (should (eq :false (plist-get (drgnx-agent-panel--look-params) :ledger_open)))
      (drgnx-agent-panel-ledger)
      (should (eq t (plist-get (drgnx-agent-panel--look-params) :ledger_open)))
      (drgnx-agent-panel-ledger)
      (should (eq :false (plist-get (drgnx-agent-panel--look-params) :ledger_open))))))

(provide 'agent-panel-pins-test)
;;; agent-panel-pins-test.el ends here
