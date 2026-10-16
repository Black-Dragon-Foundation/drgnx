;;; guard-test.el --- GUI tests: guard sees real timers, not commands -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-uitest)

(ert-deftest drgnx-ui-guard/timer-recenter-is-a-violation ()
  (delete-other-windows)
  (switch-to-buffer (get-buffer-create "*drgnx-guard*"))
  (with-current-buffer "*drgnx-guard*" (erase-buffer) (dotimes (_ 100) (insert "x\n")))
  (run-with-timer 0.05 nil (lambda () (set-window-start (selected-window) 50)))
  (let ((r (drgnx-uitest-run (drgnx-uitest-key-events "C-n"))))
    (should (= (plist-get r :guard_violations) 1))))

(ert-deftest drgnx-ui-guard/commands-are-not-violations ()
  (let ((r (drgnx-uitest-run (drgnx-uitest-key-events "C-x 2 C-x o C-x 1"))))
    (should (= (plist-get r :guard_violations) 0))))
