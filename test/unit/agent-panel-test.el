;;; agent-panel-test.el --- the agent panel: rows, steps, patches, chips -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: pure.  No hub: the panel is fed snapshots and entries by hand, and the hub client's calls are recorded.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-hub-client)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/agent-panel))

(defvar drgnx-agent-panel--stats-render)
(declare-function drgnx-agent-panel-buffer "drgnx-agent-panel")
(declare-function drgnx-agent-panel--take-entries "drgnx-agent-panel")
(declare-function drgnx-agent-panel--take-snapshot "drgnx-agent-panel")
(declare-function drgnx-agent-panel--take-steps "drgnx-agent-panel")
(declare-function drgnx-agent-panel-toggle "drgnx-agent-panel")
(declare-function drgnx-agent-panel--ask "drgnx-agent-panel")

(defvar drgnx-agent-panel-test--calls nil)

(defmacro drgnx-agent-panel-test--with (&rest body)
  "BODY with the module set up, the hub's calls recorded in `drgnx-agent-panel-test--calls' (METHOD . PARAMS) and
unanswered, and panel \"s1\" as `buf'."
  (declare (indent 0))
  `(let ((drgnx-agent-panel-test--calls nil) buf)
     (cl-letf (((symbol-function 'drgnx-hub-call)
                (lambda (method params _cb &rest _) (push (cons method params) drgnx-agent-panel-test--calls) 1)))
       (drgnx-test-with-modules '(tools/agent-panel)
         (unwind-protect
             (progn (setq buf (drgnx-agent-panel-buffer "s1"))
                    ,@body)
           (when (buffer-live-p buf) (kill-buffer buf)))))))

(defun drgnx-agent-panel-test--text (buf)
  (with-current-buffer buf
    (drgnx-view-draw-now drgnx-view)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun drgnx-agent-panel-test--tool (id title status &rest more)
  (append (list :type "tool" :id id :title title :kind "read" :status status) more))

(ert-deftest drgnx-agent-panel/appends-and-patches-never-rerenders ()
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (drgnx-agent-panel--take-entries (list (list 0 (list :type "user" :text "go"))
                                             (list 1 (drgnx-agent-panel-test--tool "t1" "Read a.el" "pending"))))
      (drgnx-agent-panel-test--text buf)
      (let ((rendered nil))
        (cl-letf* ((orig (symbol-function 'drgnx-agent-panel--render))
                   ((symbol-function 'drgnx-agent-panel--render)
                    (lambda (key) (push key rendered) (funcall orig key))))
          ;; an entry appended: only its row is drawn
          (drgnx-agent-panel--take-entries (list (list 2 (drgnx-agent-panel-test--tool "t2" "Read b.el" "pending"))))
          (drgnx-agent-panel-test--text buf)
          (should (equal '((:e 2)) rendered))
          ;; an entry changed in place: only its row is drawn again
          (setq rendered nil)
          (drgnx-agent-panel--take-entries (list (list 1 (drgnx-agent-panel-test--tool "t1" "Read a.el" "completed"))))
          (drgnx-agent-panel-test--text buf)
          (should (equal '((:e 1)) rendered))
          ;; the same entry again changes nothing
          (setq rendered nil)
          (drgnx-agent-panel--take-entries (list (list 1 (drgnx-agent-panel-test--tool "t1" "Read a.el" "completed"))))
          (drgnx-agent-panel-test--text buf)
          (should-not rendered)))
      (should (string-match-p "Read a.el" (drgnx-agent-panel-test--text buf)))
      (should (string-match-p "Read b.el" (drgnx-agent-panel-test--text buf))))))

(ert-deftest drgnx-agent-panel/a-chip-without-a-feed-is-hidden ()
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (drgnx-agent-panel--take-snapshot (list :id "s1" :name "Claude" :status "idle" :profile "Claude" :mode "queue"))
      (let ((text (drgnx-agent-panel-test--text buf)))
        (should (string-match-p "queue" text))
        (should-not (string-match-p "MCP" text))
        (should-not (string-match-p "checkpoints" text))
        (should-not (string-match-p "\\$" text))
        (should-not (string-match-p "files" text)))
      (drgnx-agent-panel--take-snapshot (list :id "s1" :name "Claude" :status "idle" :profile "Claude" :mode "queue"
                                              :usage (list :used 50 :size 100 :cost 0.25) :files_edited 3 :mcp 2))
      (let ((text (drgnx-agent-panel-test--text buf)))
        (should (string-match-p "50%" text))
        (should (string-match-p "\\$0.25" text))
        (should (string-match-p "3 files" text))
        (should (string-match-p "MCP 2" text))))))

(ert-deftest drgnx-agent-panel/thinking-folds-under-its-step ()
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (drgnx-agent-panel--take-entries
       (list (list 0 (drgnx-agent-panel-test--tool "t1" "Grep foo" "completed"))
             (list 1 (list :type "thought" :text "first idea\nsecond idea"))))
      (let ((text (drgnx-agent-panel-test--text buf)))
        (should (string-match-p "▸ thinking · 2 lines" text))
        (should-not (string-match-p "first idea" text))
        ;; the thought is not a row of its own
        (should-not (drgnx-view-row-start drgnx-view '(:e 1))))
      (goto-char (drgnx-view-row-start drgnx-view '(:e 0)))
      (drgnx-agent-panel-toggle)
      (should (string-match-p "first idea" (drgnx-agent-panel-test--text buf)))
      ;; a thought that arrives later patches its step's row
      (drgnx-agent-panel--take-entries (list (list 2 (list :type "thought" :text "third"))))
      (should (string-match-p "third" (drgnx-agent-panel-test--text buf)))
      ;; a thought with no step before it is a row
      (drgnx-agent-panel--take-entries (list (list 3 (list :type "user" :text "x")) (list 4 (list :type "thought" :text "alone"))))
      (drgnx-agent-panel-test--text buf)
      (should (with-current-buffer buf (drgnx-view-row-start drgnx-view '(:e 4)))))))

(ert-deftest drgnx-agent-panel/time-and-cost-are-in-warn-when-slow-or-dear ()
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (drgnx-agent-panel--take-steps (list (list :seq 1 :start 0.0 :end 0.5 :cost 0.01)
                                           (list :seq 2 :start 0.0 :end 30.0 :cost 2.0)))
      (drgnx-agent-panel--take-entries
       (list (list 0 (drgnx-agent-panel-test--tool "t1" "Quick" "completed" :step 1))
             (list 1 (drgnx-agent-panel-test--tool "t2" "Slow" "completed" :step 2))))
      (let ((text (drgnx-agent-panel-test--text buf)))
        (should (string-match-p "500 ms" text))
        (should (string-match-p "\\$2.00" text)))
      (let* ((s (with-current-buffer buf (buffer-string)))
             (pos (string-search "30.0 s" s)))
        (should (memq 'drgnx-agent-panel-warn (ensure-list (get-text-property pos 'face s))))
        (should-not (memq 'drgnx-agent-panel-warn (ensure-list (get-text-property (string-search "500 ms" s) 'face s))))))))

(ert-deftest drgnx-agent-panel/off-leaves-no-panel-and-no-hooks ()
  (let ((before (list window-buffer-change-functions drgnx-hub-event-functions drgnx-hub-connected-functions)))
    (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (&rest _) 1)))
      (drgnx-test-with-modules '(tools/agent-panel)
        (drgnx-agent-panel-buffer "s9")
        (should (get-buffer "*drgnx agent: s9*"))))
    (should-not (get-buffer "*drgnx agent: s9*"))
    (should (equal before (list window-buffer-change-functions drgnx-hub-event-functions drgnx-hub-connected-functions)))))

(provide 'agent-panel-test)
;;; agent-panel-test.el ends here
