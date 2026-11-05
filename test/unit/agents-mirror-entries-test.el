;;; agents-mirror-entries-test.el --- batch tests: the hub sends a mirror its entries only while a transcript shows -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: gated
;; The hub runs as its own process (as it does for the user); this Emacs plays the editor, inside the delivery gate
;; (`drgnx-test-gated').  The agent is a real child, so what it did is a condition the test sees after each release of
;; the hub's lines (the helpers of agents-mirror-test.el), never a deadline.
(require 'ert)
(require 'drgnx-agents)
(require 'drgnx-agents-mirror)
(require 'drgnx-records)
(require 'drgnx-hub-client)
(load (expand-file-name "test/unit/agents-mirror-test" drgnx-dir) nil t)   ; its helpers and the hub fixtures

(defun drgnx-agents-mirror-entries-test--hub-text (id)
  "The text of session ID's transcript as the hub holds it."
  (mapconcat (lambda (e) (format "%s" (or (plist-get e :text) "")))
             (plist-get (drgnx-agents-mirror-test--ask "agents/get" (list :id id)) :entries) " "))

(defun drgnx-agents-mirror-entries-test--hub-has (id text)
  "Settle until the hub's transcript of ID holds TEXT, then let the hub's clock pass its update throttle once more
and release what it wrote: an entry it holds has been sent to whoever asked for it."
  (drgnx-agents-mirror-test--settle
   (lambda () (string-search text (drgnx-agents-mirror-entries-test--hub-text id))) (format "the hub's transcript holds %S" text))
  (drgnx-test-hub-advance 100)
  (drgnx-test-deliver-all))

(ert-deftest drgnx-agents-mirror/shown-transcript-gets-entries ()
  (drgnx-agents-mirror-test--with '()
    (drgnx-agents-mirror-sync)
    (let* ((m (drgnx-agents-mirror-test--start :profile "mock")) (id (drgnx-agent-session-remote m)))
      ;; not shown: the turn is in the hub's transcript and not in the mirror's
      (drgnx-agents-mirror-test--ask "agents/send" (list :id id :text "first"))
      (drgnx-agents-mirror-entries-test--hub-has id "You said: first")
      (should-not (string-search "You said: first" (drgnx-agents-mirror-test--text m)))
      ;; shown: the transcript is fetched, and what comes after arrives as entries
      (drgnx-agents-mirror-show id)
      (drgnx-agents-mirror-test--settle (lambda () (string-search "You said: first" (drgnx-agents-mirror-test--text m)))
                                        "the transcript fetched when it is shown")
      (drgnx-agents-mirror-test--ask "agents/send" (list :id id :text "second"))
      (drgnx-agents-mirror-test--settle (lambda () (string-search "You said: second" (drgnx-agents-mirror-test--text m)))
                                        "the entries of the shown session"))))

(ert-deftest drgnx-agents-mirror/hidden-transcript-unsubscribes ()
  (drgnx-agents-mirror-test--with '()
    (drgnx-agents-mirror-sync)
    (let* ((m (drgnx-agents-mirror-test--start :profile "mock")) (id (drgnx-agent-session-remote m)))
      (drgnx-agents-mirror-show id)
      (drgnx-agents-mirror-test--ask "agents/send" (list :id id :text "one"))
      (drgnx-agents-mirror-test--settle (lambda () (string-search "You said: one" (drgnx-agents-mirror-test--text m)))
                                        "the entries while it is shown")
      (drgnx-agents-mirror-hide id)
      (should-not (gethash id drgnx-agents-mirror--shown))
      ;; the answer to the unsubscribe has been released with the rest by the next ask
      (drgnx-agents-mirror-test--ask "agents/send" (list :id id :text "two"))
      (drgnx-agents-mirror-entries-test--hub-has id "You said: two")
      (should-not (string-search "You said: two" (drgnx-agents-mirror-test--text m))))))

(ert-deftest drgnx-agents-mirror/turn-end-from-the-snapshot-without-entries ()
  ;; a session nobody shows gets no entries: its turns start and end by the snapshots' status alone, once each
  (let (events)
    (drgnx-agents-mirror-test--hooks events
      (drgnx-agents-mirror--apply-snapshot (drgnx-agents-mirror-test--snap "idle" "T#1"))
      (drgnx-agents-mirror--apply-snapshot (drgnx-agents-mirror-test--snap "busy" "T#1"))
      (drgnx-agents-mirror--apply-snapshot (drgnx-agents-mirror-test--snap "busy" "T#1"))
      (drgnx-agents-mirror--apply-snapshot (drgnx-agents-mirror-test--snap "idle" "T#1"))
      (should (equal (reverse events) '((start . "h-t") (turn-start . "h-t") (turn-end . "h-t"))))
      (should-not (drgnx-agent-session-entries (drgnx-agents-mirror--find "h-t"))))))

(provide 'agents-mirror-entries-test)
;;; agents-mirror-entries-test.el ends here
