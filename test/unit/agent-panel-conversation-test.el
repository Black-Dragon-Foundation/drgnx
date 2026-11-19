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

(defconst drgnx-agent-panel-conversation-test--request
  (list :id 7 :title "Read the gateway's log"
        :options (vector (list :kind "allow_once" :optionId "o-once") (list :kind "allow_always" :optionId "o-always")
                         (list :kind "reject_once" :optionId "o-no")))
  "A request the agent waits on, as the snapshot carries it.")

(ert-deftest drgnx-agent-panel-conversation/a-question-card-button-answers-the-request ()
  "The kit action `agent-panel-card' (a question card's button: VERB and the request id) answers the request with the
option of that verb: allow once, allow always, or reject."
  (drgnx-agent-panel-conversation-test--with
    (let ((def (gethash 'agent-panel-card drgnx-ui-kit--actions)) answered)
      (should def)
      (with-current-buffer buf
        (setq drgnx-agent-panel--snap (list :permissions (vector drgnx-agent-panel-conversation-test--request)))
        (cl-letf (((symbol-function 'drgnx-agent-panel--answer) (lambda (_r option) (push option answered))))
          (dolist (verb '("allow" "always" "deny")) (funcall (nth 0 def) (list verb "7")))))
      (should (equal '("o-once" "o-always" "o-no") (nreverse answered))))))

(ert-deftest drgnx-agent-panel-conversation/the-card-keys-are-y-a-n ()
  "On a question card's button, y allows, a allows always and n denies: each key calls the action with its verb."
  (drgnx-agent-panel-conversation-test--with
    (let ((def (gethash 'agent-panel-card drgnx-ui-kit--actions)))
      (should def)
      (dolist (row '(("y" "allow") ("a" "always") ("n" "deny")))
        (should (eq 'drgnx-ui-kit-activate (lookup-key (nth 2 def) (kbd (car row)))))
        (let ((transform (cdr (assoc (car row) (nth 1 def)))))
          (should (functionp transform))
          (should (equal (list (cadr row) "7") (funcall transform '("anything" "7")))))))))

(provide 'agent-panel-conversation-test)
;;; agent-panel-conversation-test.el ends here
