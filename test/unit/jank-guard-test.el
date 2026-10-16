;;; jank-guard-test.el --- batch tests: jank guard -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-jank-guard)

(defmacro drgnx-test--with-guard (&rest body)
  `(let ((drgnx-jank-guard-log nil))
     (drgnx-jank-guard-enable)
     (unwind-protect (progn ,@body) (drgnx-jank-guard-disable))))

(ert-deftest drgnx-jank-guard/records-window-moves-from-timers ()
  (drgnx-test--with-guard
   (let ((drgnx-jank-guard--timer-fn 'some-follower))
     (set-window-start (selected-window) 1))
   (should (= (length drgnx-jank-guard-log) 1))
   (should (eq (plist-get (car drgnx-jank-guard-log) :fn) 'set-window-start))
   (should (equal (plist-get (car drgnx-jank-guard-log) :timer) "some-follower"))))

(ert-deftest drgnx-jank-guard/ignores-commands-and-temporary-selection ()
  (drgnx-test--with-guard
   (set-window-start (selected-window) 1)                ; not in a timer
   (let ((drgnx-jank-guard--timer-fn 'some-timer))
     (select-window (selected-window) 'norecord))        ; with-selected-window style
   (should (null drgnx-jank-guard-log))))

(ert-deftest drgnx-jank-guard/disable-removes-advice ()
  (drgnx-jank-guard-enable)
  (drgnx-jank-guard-disable)
  (should-not (advice-member-p 'drgnx-jank-guard 'set-window-start)))
