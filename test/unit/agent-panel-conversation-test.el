;;; agent-panel-conversation-test.el --- the conversation's header chain chips and question cards (Flow Task 23) -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: pure.  The hub's rows are not drawn here: the panel is fed a snapshot by hand and the hub's answers are recorded.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-hub-client)
(require 'drgnx-ui-kit)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/agent-panel))

(declare-function drgnx-agent-panel-buffer "drgnx-agent-panel")
(declare-function drgnx-agent-panel-chip "drgnx-agent-panel-explain")
(declare-function drgnx-work-select "drgnx-work-map")
(defvar drgnx-agent-panel--snap)
(defvar drgnx-ui-kit--actions)

(defmacro drgnx-agent-panel-conversation-test--with (&rest body)
  "BODY with the module set up, the hub's calls swallowed, and panel \"s1\" as `buf'."
  (declare (indent 0))
  `(let (buf)
     (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (&rest _) 1)))
       (drgnx-test-with-modules '(tools/agent-panel)
         (unwind-protect (progn (setq buf (drgnx-agent-panel-buffer "s1")) ,@body)
           (when (buffer-live-p buf) (kill-buffer buf)))))))

(ert-deftest drgnx-agent-panel-conversation/a-chain-chip-selects-its-node-in-work ()
  "A click on a chain chip of the header (the hub marks it `select:KIND:ID') selects that node in Work, and asks the hub
for no explanation."
  (drgnx-agent-panel-conversation-test--with
    (let (picked asked)
      (cl-letf (((symbol-function 'drgnx-work-select) (lambda (kind id) (setq picked (list kind id))))
                ((symbol-function 'drgnx-agent-panel--ask) (lambda (&rest args) (setq asked args))))
        (with-current-buffer buf (drgnx-agent-panel-chip (intern "select:task:t7"))))
      (should (equal '("task" "t7") picked))
      (should-not asked))))

(provide 'agent-panel-conversation-test)
;;; agent-panel-conversation-test.el ends here
