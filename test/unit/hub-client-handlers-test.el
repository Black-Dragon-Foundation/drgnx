;;; hub-client-handlers-test.el --- the hub's events go to a table of the handlers that take them -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: pure.  No hub; the events are run through the client's own `events' hook effect.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-hub-client)

(defvar drgnx-hub-handlers-test--seen nil "(HANDLER . EVENT) in the order they ran.")

(defun drgnx-hub-handlers-test--a (event _data) (push (cons 'a event) drgnx-hub-handlers-test--seen))
(defun drgnx-hub-handlers-test--b (event _data) (push (cons 'b event) drgnx-hub-handlers-test--seen))
(defun drgnx-hub-handlers-test--all (event _data) (push (cons 'all event) drgnx-hub-handlers-test--seen))
(put 'drgnx-hub-handlers-test--a 'hub-events-taken '("job" "card"))
(put 'drgnx-hub-handlers-test--b 'hub-events-taken '("term/*"))

(defmacro drgnx-hub-handlers-test--with (&rest body)
  "BODY with the event hook holding the test's three handlers (a: job and card, b: term/*, all: no declaration)."
  (declare (indent 0))
  `(let ((drgnx-hub-event-functions (list #'drgnx-hub-handlers-test--a #'drgnx-hub-handlers-test--b
                                          #'drgnx-hub-handlers-test--all))
         (drgnx-hub--handler-table nil) (drgnx-hub-handlers-test--seen nil))
     ,@body))

(defun drgnx-hub-handlers-test--run (event)
  (setq drgnx-hub-handlers-test--seen nil)
  (drgnx-hub--run-hook 'events nil event nil)
  (reverse drgnx-hub-handlers-test--seen))

(ert-deftest drgnx-hub-handlers/an-event-goes-to-the-handlers-that-take-it ()
  (drgnx-hub-handlers-test--with
    (should (equal '((a . "job") (all . "job")) (drgnx-hub-handlers-test--run "job")))
    (should (equal '((b . "term/exit") (all . "term/exit")) (drgnx-hub-handlers-test--run "term/exit")))
    (should (equal '((all . "agent")) (drgnx-hub-handlers-test--run "agent")))))

(ert-deftest drgnx-hub-handlers/the-table-is-looked-up-not-made-again ()
  (drgnx-hub-handlers-test--with
    (let ((first (drgnx-hub--event-handlers "job")))
      (should (eq first (drgnx-hub--event-handlers "job")))
      (should-not (eq first (drgnx-hub--event-handlers "card"))))))

(ert-deftest drgnx-hub-handlers/a-handler-added-or-removed-is-seen ()
  (drgnx-hub-handlers-test--with
    (should (equal 1 (length (drgnx-hub--event-handlers "agent-entries"))))
    (setq drgnx-hub-event-functions (cl-remove #'drgnx-hub-handlers-test--all drgnx-hub-event-functions))
    (should (equal nil (drgnx-hub--event-handlers "agent-entries")))
    (setq drgnx-hub-event-functions (cons #'drgnx-hub-handlers-test--all drgnx-hub-event-functions))
    (should (equal '((all . "agent")) (drgnx-hub-handlers-test--run "agent")))))

(ert-deftest drgnx-hub-handlers/a-failing-handler-does-not-stop-the-rest ()
  (drgnx-hub-handlers-test--with
    (cl-letf (((symbol-function 'drgnx-hub-handlers-test--a) (lambda (_e _d) (error "boom"))))
      (should (equal '((all . "job")) (drgnx-hub-handlers-test--run "job"))))))
