;;; report-test.el --- GUI tests: recorder and jank report -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-uitest)

(defun drgnx-test--two-windows ()
  (delete-other-windows)
  (switch-to-buffer (get-buffer-create "*drgnx-a*"))
  (with-current-buffer "*drgnx-a*" (erase-buffer) (dotimes (i 200) (insert (format "a %03d\n" i))))
  (let ((other (split-window-below)))
    (set-window-buffer other (get-buffer-create "*drgnx-b*"))
    (with-current-buffer "*drgnx-b*" (erase-buffer) (dotimes (i 200) (insert (format "b %03d\n" i))))
    (message nil)                                  ; start with a one-line, empty echo area
    (redisplay t)
    other))

(ert-deftest drgnx-ui-report/typing-is-paced-and-clean ()
  (drgnx-test--two-windows)
  (let ((r (drgnx-uitest-run (drgnx-uitest-type-events "hello"))))
    (should (eq (plist-get r :settled) t))
    (should (>= (plist-get r :redisplays) 5))        ; redisplay ran between the 5 events
    (should (= (plist-get r :collateral_moves) 0))
    (should (= (plist-get r :layout_changes) 0))))

(ert-deftest drgnx-ui-report/split-is-a-layout-change ()
  (drgnx-test--two-windows)
  (let ((r (drgnx-uitest-run (drgnx-uitest-key-events "C-x 2"))))
    (should (>= (plist-get r :layout_changes) 1))))

(ert-deftest drgnx-ui-report/background-scroll-is-collateral ()
  (let ((other (drgnx-test--two-windows)))
    (run-with-timer 0.1 nil (lambda () (set-window-start other 500)))
    (let ((r (drgnx-uitest-run (drgnx-uitest-key-events "C-n"))))
      (should (= (plist-get r :collateral_moves) 1))
      (should (>= (plist-get r :settle_ms) 50)))))
