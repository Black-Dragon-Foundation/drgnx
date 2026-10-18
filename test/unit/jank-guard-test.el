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

(defun drgnx-jank-test--mover (&rest _) (set-window-start (selected-window) 1))
(defun drgnx-jank-test--quiet (&rest _) nil)

(ert-deftest drgnx-jank-guard/hook-window-move-recorded ()
  ;; DEFERRED M3c-8: a window move made inside a window change hook is recorded like one from a timer;
  ;; members added before and after the guard started are both seen, and removing one still works.
  (let ((window-configuration-change-hook (list #'drgnx-jank-test--quiet #'drgnx-jank-test--mover))
        (window-size-change-functions nil))
    (drgnx-test--with-guard
     (add-hook 'window-size-change-functions #'drgnx-jank-test--mover)      ; after the start
     (run-hooks 'window-configuration-change-hook)
     (should (= (length drgnx-jank-guard-log) 1))
     (should (eq (plist-get (car drgnx-jank-guard-log) :fn) 'set-window-start))
     (should (string-match-p "window-configuration-change-hook.*mover" (plist-get (car drgnx-jank-guard-log) :timer)))
     (run-hook-with-args 'window-size-change-functions (selected-frame))
     (should (= (length drgnx-jank-guard-log) 2))
     (should (string-match-p "window-size-change-functions" (plist-get (car drgnx-jank-guard-log) :timer)))
     ;; the same function called by a command, not by a hook: not recorded
     (drgnx-jank-test--mover)
     (should (= (length drgnx-jank-guard-log) 2))
     ;; remove-hook with the original function still removes the wrapped member
     (remove-hook 'window-size-change-functions #'drgnx-jank-test--mover)
     (run-hook-with-args 'window-size-change-functions (selected-frame))
     (should (= (length drgnx-jank-guard-log) 2)))
    ;; the guard off: the hooks hold the original functions again
    (should (equal window-configuration-change-hook (list #'drgnx-jank-test--quiet #'drgnx-jank-test--mover)))))
