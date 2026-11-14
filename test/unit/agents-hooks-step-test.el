;;; agents-hooks-step-test.el --- a step's hook rows belong to the tool call the hub names -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: pure.  The hub's `agent-step' event names the tool call its step ran (`call'); the mirror keeps the hook
;; rows under that entry id and walks no entry to find it.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-agents)
(require 'drgnx-agents-mirror)
(require 'drgnx-agents-hooks)

(ert-deftest drgnx-agents-hooks/rows-sit-under-the-call-the-step-names ()
  (let* ((drgnx-agents-changed-functions nil) (drgnx-agents-mirror--paused nil)
         (m (drgnx-agents--make :remote "s-h" :id "s-h" :status 'busy
                                :entries (list (list :type 'tool :id "t9") (list :type 'tool :id "t10")))))
    (let ((drgnx-agents--sessions (list m)))
      (cl-letf (((symbol-function 'drgnx-agent-session-entries) (lambda (_s) (error "walked the entries"))))
        (drgnx-agents-mirror--event "agent-step"
                                    (list :session "s-h" :step (list :seq 7 :session "s-h" :call "t9"
                                                                     :hooks (list (list :point "after-edit"))))))
      (should (equal '((:point "after-edit")) (drgnx-agents-hooks-rows-for-tool m "t9")))
      (should-not (drgnx-agents-hooks-rows-for-tool m "t10")))))

(provide 'agents-hooks-step-test)
;;; agents-hooks-step-test.el ends here
