;;; agents-editor-client-test.el --- the editor client's pure core: stale frames, gaps and the restart -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: orders
;; `drgnx-agents-editor--core-step' takes a state and one event and returns the next state with its effects.  No
;; process, timer or clock: the deliveries run in every order they can arrive in (`drgnx-test-every-order').
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(load (expand-file-name "modules/tools/drgnx-agents-editor" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/orders-fixture" drgnx-dir) nil t)

(defun drgnx-agents-editor-client-test--frame (version doc &optional agents)
  (list :version version :doc_version doc :agents agents :gutter nil))

(defun drgnx-agents-editor-client-test--adapter (state event)
  (let ((r (drgnx-agents-editor--core-step state event)))
    (cons (car r) nil)))

(ert-deftest drgnx-agents-editor-client/every-order-stale-doc-version-is-dropped ()
  ;; the buffer sent change 7; a frame made for document 5 comes before or after the change and the fresh frame for 7:
  ;; the stale one is never shown, wherever it lands once the change is known
  (let* ((stale (drgnx-agents-editor-client-test--frame 2 5 '((:ordinal 9))))
         (fresh (drgnx-agents-editor-client-test--frame 3 7 '((:ordinal 1))))
         (r (drgnx-test-every-order
             :kinds '(buffer-changed frame)
             :sources `((edit (buffer-changed 7)) (hub (frame ,stale) (frame ,fresh)))
             :edges '(((edit . 0) . (hub . 0)))
             :init (lambda () (car (drgnx-agents-editor--core-step nil '(watch))))
             :step #'drgnx-agents-editor-client-test--adapter
             :check (lambda (s _order)
                      (let ((f (drgnx-agents-editor--state-frame s)))
                        (cond ((not (eql 3 (plist-get f :version))) (format "version %S, not 3" (plist-get f :version)))
                              ((not (equal '((:ordinal 1)) (plist-get f :agents))) "the stale frame's agents are shown")))))))
    (should (eq 'exhaustive (plist-get r :mode)))))

(ert-deftest drgnx-agents-editor-client/a-stale-frame-has-no-effects ()
  (let* ((s (car (drgnx-agents-editor--core-step nil '(watch))))
         (s (car (drgnx-agents-editor--core-step s '(buffer-changed 7))))
         (r (drgnx-agents-editor--core-step s (list 'frame (drgnx-agents-editor-client-test--frame 1 5)))))
    (should-not (cdr r))
    (should-not (drgnx-agents-editor--state-frame (car r)))))

(ert-deftest drgnx-agents-editor-client/a-gap-asks-for-a-full-frame ()
  (let* ((s (car (drgnx-agents-editor--core-step nil '(watch))))
         (s (car (drgnx-agents-editor--core-step s (list 'frame (drgnx-agents-editor-client-test--frame 4 0)))))
         (gap (drgnx-agents-editor--core-step s (list 'delta '(:version 7 :base 6 :agents ((:ordinal 3))))))
         (next (drgnx-agents-editor--core-step s (list 'delta '(:version 5 :base 4 :agents ((:ordinal 3))))))
         (old (drgnx-agents-editor--core-step s (list 'delta '(:version 3 :base 2 :agents ((:ordinal 3)))))))
    (should (equal '((call-watch)) (cdr gap)))                       ; asked, and nothing applied
    (should (= 4 (drgnx-agents-editor--state-version (car gap))))
    (should (equal '((apply)) (cdr next)))                           ; in sequence: applied
    (should (equal '((:ordinal 3)) (plist-get (drgnx-agents-editor--state-frame (car next)) :agents)))
    (should-not (cdr old))))                                         ; older than what is held: dropped

(ert-deftest drgnx-agents-editor-client/restart-rewatches-visible-buffers ()
  (let* ((s (car (drgnx-agents-editor--core-step nil '(watch))))
         (s (car (drgnx-agents-editor--core-step s (list 'frame (drgnx-agents-editor-client-test--frame 4 0)))))
         (r (drgnx-agents-editor--core-step s '(restart)))
         (d (drgnx-agents-editor--core-step (car r) (list 'delta '(:version 5 :base 4)))))
    (should (equal '((call-watch)) (cdr r)))
    (should-not (drgnx-agents-editor--state-version (car r)))
    (should (equal '((call-watch)) (cdr d)))                         ; no base after a restart: a delta asks for a frame
    (should-not (cdr (drgnx-agents-editor--core-step nil '(restart))))   ; an unwatched buffer asks nothing
    (should-not (cdr (drgnx-agents-editor--core-step nil '(unwatch))))))

(provide 'agents-editor-client-test)
;;; agents-editor-client-test.el ends here
