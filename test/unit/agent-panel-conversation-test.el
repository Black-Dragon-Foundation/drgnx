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

(defun drgnx-agent-panel-conversation-test--press (key verb)
  "Press KEY on the button of the card whose verb is VERB (`allow', `always' or `deny') for request 7: the commands the
action runs, in order.  The key's own transform rewrites the button's args, as `kit-activate' does."
  (let* ((def (gethash 'agent-panel-card drgnx-ui-kit--actions)) calls)
    (should def)
    (should (eq 'drgnx-ui-kit-activate (lookup-key (nth 2 def) (kbd key))))
    (let ((transform (cdr (assoc key (nth 1 def)))) (last-input-event (aref (kbd key) 0)))
      (should (functionp transform))
      (cl-letf (((symbol-function 'drgnx-agent-panel-allow) (lambda () (push 'allow calls)))
                ((symbol-function 'drgnx-agent-panel-always) (lambda () (push 'always calls)))
                ((symbol-function 'drgnx-agent-panel-reject) (lambda () (push 'deny calls))))
        (funcall (nth 0 def) (funcall transform (list (format "card:%s:7" verb))))))
    (nreverse calls)))

(ert-deftest drgnx-agent-panel-conversation/y-on-a-permission-card-button-allows-once ()
  "`y' on a button of a permission card allows the request once, whichever button point is on."
  (drgnx-agent-panel-conversation-test--with
    (should (equal '(allow) (drgnx-agent-panel-conversation-test--press "y" "deny")))))

(ert-deftest drgnx-agent-panel-conversation/a-on-a-permission-card-button-allows-always ()
  "`a' on a button of a permission card allows the request from now on."
  (drgnx-agent-panel-conversation-test--with
    (should (equal '(always) (drgnx-agent-panel-conversation-test--press "a" "allow")))))

(ert-deftest drgnx-agent-panel-conversation/n-on-a-permission-card-button-denies ()
  "`n' on a button of a permission card denies the request."
  (drgnx-agent-panel-conversation-test--with
    (should (equal '(deny) (drgnx-agent-panel-conversation-test--press "n" "allow")))))

(ert-deftest drgnx-agent-panel-conversation/ret-on-a-button-runs-that-buttons-verb ()
  "RET on a button of a permission card runs that button's own verb (a mouse click is the panel's dispatcher's)."
  (drgnx-agent-panel-conversation-test--with
    (let ((def (gethash 'agent-panel-card drgnx-ui-kit--actions)) calls (last-input-event ?\r))
      (should def)
      (cl-letf (((symbol-function 'drgnx-agent-panel-allow) (lambda () (push 'allow calls)))
                ((symbol-function 'drgnx-agent-panel-always) (lambda () (push 'always calls)))
                ((symbol-function 'drgnx-agent-panel-reject) (lambda () (push 'deny calls))))
        (dolist (verb '("allow" "always" "deny")) (funcall (nth 0 def) (list (format "card:%s:7" verb)))))
      (should (equal '(allow always deny) (nreverse calls))))))

(provide 'agent-panel-conversation-test)
;;; agent-panel-conversation-test.el ends here
