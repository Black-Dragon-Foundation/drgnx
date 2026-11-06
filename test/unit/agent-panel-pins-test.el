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

(defun drgnx-agent-panel-pins-test--edit (id)
  (list :type "tool" :id id :title (format "Edit %s" id) :kind "edit" :status "completed"))

(ert-deftest drgnx-agent-panel/pin-a-card ()
  (drgnx-agent-panel-pins-test--with
    (with-current-buffer buf
      (drgnx-agent-panel--take-entries
       (list (list 0 (list :type "tool" :id "t1" :title "Read the spec" :kind "read" :status "completed"))
             (list 1 (list :type "tool" :id "t2" :title "Run the tests" :kind "execute" :status "completed"))))
      (drgnx-agent-panel-pins-test--text buf)
      (goto-char (drgnx-view-row-start drgnx-view '(:e 1)))
      (drgnx-agent-panel-pin)
      (let ((text (drgnx-agent-panel-pins-test--text buf)))
        ;; the pinned card is above the transcript, under the chips
        (should (string-match-p "⚑ Run the tests" text))
        (should (< (string-search "⚑ Run the tests" text) (string-search "Read the spec" text))))
      ;; pinned again from the card: gone
      (goto-char (drgnx-view-row-start drgnx-view '(:pin 0)))
      (drgnx-agent-panel-pin)
      (should-not (string-match-p "⚑" (drgnx-agent-panel-pins-test--text buf)))
      ;; something that is not a card cannot be pinned
      (goto-char (drgnx-view-row-start drgnx-view '(:chips)))
      (should-error (drgnx-agent-panel-pin) :type 'user-error))))

(ert-deftest drgnx-agent-panel/todo-list-from-plan-entries ()
  (drgnx-agent-panel-pins-test--with
    (with-current-buffer buf
      (drgnx-agent-panel--take-entries
       (list (list 0 (list :type "plan" :entries (list (list :content "Read" :status "completed")
                                                       (list :content "Write" :status "in_progress")
                                                       (list :content "Test" :status "pending"))))))
      (let ((text (drgnx-agent-panel-pins-test--text buf)))
        (should (string-match-p "To do · 1 of 3 done" text))
        (should (string-match-p "☑ Read" text))
        (should (string-match-p "◐ Write" text))
        (should (string-match-p "☐ Test" text))
        ;; the plan entry is not a row of the transcript
        (should-not (drgnx-view-row-start drgnx-view '(:e 0))))
      ;; a plan is replaced, not repeated
      (drgnx-agent-panel--take-entries
       (list (list 1 (list :type "plan" :entries (list (list :content "Read" :status "completed")
                                                       (list :content "Write" :status "completed")
                                                       (list :content "Test" :status "in_progress"))))))
      (let ((text (drgnx-agent-panel-pins-test--text buf)))
        (should (string-match-p "To do · 2 of 3 done" text))
        (should (= 2 (length (split-string text "To do"))))))))

(ert-deftest drgnx-agent-panel/changes-since-you-looked-counts-from-the-mark ()
  (drgnx-agent-panel-pins-test--with
    (with-current-buffer buf
      (drgnx-agent-panel--take-entries (list (list 0 (drgnx-agent-panel-pins-test--edit "a"))
                                             (list 1 (drgnx-agent-panel-pins-test--edit "b"))))
      ;; never looked: both are new
      (should (string-match-p "2 new since you looked" (drgnx-agent-panel-pins-test--text buf)))
      ;; looking sets the mark at the newest entry
      (drgnx-agent-panel-ledger)
      (should-not (string-match-p "new since you looked" (drgnx-agent-panel-pins-test--text buf)))
      ;; two more edits and a read: the count is the edits after the mark
      (drgnx-agent-panel--take-entries (list (list 2 (drgnx-agent-panel-pins-test--edit "c"))
                                             (list 3 (list :type "tool" :id "r" :title "Read" :kind "read" :status "completed"))
                                             (list 4 (drgnx-agent-panel-pins-test--edit "d"))))
      (should (string-match-p "2 new since you looked" (drgnx-agent-panel-pins-test--text buf)))
      ;; folded and opened again: looking again moves the mark
      (drgnx-agent-panel-ledger)
      (drgnx-agent-panel-ledger)
      (should-not (string-match-p "new since you looked" (drgnx-agent-panel-pins-test--text buf))))))

(provide 'agent-panel-pins-test)
;;; agent-panel-pins-test.el ends here
