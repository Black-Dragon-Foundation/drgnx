;;; attribution-test.el --- GUI tests: every change is attributed to its cause -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-uitest)

(defun drgnx-attr--two-windows ()
  (delete-other-windows)
  (switch-to-buffer (get-buffer-create "*attr-a*"))
  (with-current-buffer "*attr-a*" (erase-buffer) (dotimes (i 200) (insert (format "a %03d\n" i))) (goto-char (point-min)))
  (let ((other (split-window-below)))
    (set-window-buffer other (get-buffer-create "*attr-b*"))
    (with-current-buffer "*attr-b*" (erase-buffer) (dotimes (i 200) (insert (format "b %03d\n" i))))
    (set-window-point other 1)
    (message nil)
    (redisplay t)
    other))

(defun drgnx-attr--causes (report)
  (mapcar (lambda (step) (plist-get step :cause)) (append (plist-get report :trace) nil)))

(ert-deftest drgnx-ui-attribution/command ()
  (drgnx-attr--two-windows)
  (let ((r (drgnx-uitest-run (drgnx-uitest-key-events "C-n"))))
    (should (member "command:next-line" (drgnx-attr--causes r)))))

(ert-deftest drgnx-ui-attribution/timer-scrolling-another-window ()
  (let ((other (drgnx-attr--two-windows)))
    (run-with-timer 0.1 nil (lambda () (set-window-start other 500)))
    (let ((r (drgnx-uitest-run (drgnx-uitest-key-events "C-n"))))
      (should (seq-some (lambda (c) (string-prefix-p "timer:" c)) (drgnx-attr--causes r)))
      (should (>= (plist-get r :timer_moves) 1)))))

(ert-deftest drgnx-ui-attribution/timer-moving-point-inside-with-selected-window ()
  ;; The gryphn follow's shape: goto-char in another window, no set-window-point call.
  (let ((other (drgnx-attr--two-windows)))
    (run-with-timer 0.1 nil (lambda () (with-selected-window other (goto-char 700))))
    (let* ((r (drgnx-uitest-run (drgnx-uitest-key-events "C-n")))
           (step (seq-find (lambda (s) (string-prefix-p "timer:" (plist-get s :cause)))
                           (append (plist-get r :trace) nil))))
      (should step)
      (should (equal (plist-get step :fields) ["point"])))))

(defun drgnx-attr--slow-command ()
  (interactive)
  (sit-for 0.4))

(ert-deftest drgnx-ui-attribution/timer-during-a-command ()
  (let ((other (drgnx-attr--two-windows)))
    (keymap-global-set "C-c z" #'drgnx-attr--slow-command)
    (unwind-protect
        (progn
          (run-with-timer 0.15 nil (lambda () (set-window-start other 900)))
          (let* ((r (drgnx-uitest-run (drgnx-uitest-key-events "C-c z")))
                 (moved (seq-find (lambda (s) (equal (plist-get s :window) (drgnx-uitest-window-id other)))
                                  (append (plist-get r :trace) nil))))
            (should moved)
            (should (string-prefix-p "timer:" (plist-get moved :cause)))))
      (keymap-global-unset "C-c z"))))

(defun drgnx-attr--move-then-wait ()
  (interactive)
  (forward-line 3)
  (sit-for 0.3))

(ert-deftest drgnx-ui-attribution/command-change-before-its-sit-for ()
  ;; The poll and other timers run inside the command's sit-for; the command's own change
  ;; must still be attributed to the command.
  (drgnx-attr--two-windows)
  (keymap-global-set "C-c y" #'drgnx-attr--move-then-wait)
  (unwind-protect
      (let* ((r (drgnx-uitest-run (drgnx-uitest-key-events "C-c y")))
             (mine (seq-find (lambda (s) (equal (plist-get s :window) (drgnx-uitest-window-id (selected-window))))
                             (append (plist-get r :trace) nil))))
        (should mine)
        (should (equal (plist-get mine :cause) "command:drgnx-attr--move-then-wait")))
    (keymap-global-unset "C-c y")))
