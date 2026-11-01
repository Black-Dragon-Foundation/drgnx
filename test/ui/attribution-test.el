;;; attribution-test.el --- GUI tests: every change is attributed to its cause -*- lexical-binding: t -*-
;; test-class: cond
(require 'ert)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
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

(defvar drgnx-attr--other nil "The window `drgnx-attr--slow-command''s timer scrolls.")

(defun drgnx-attr--slow-command ()
  "Start a timer and stay in the command until it has run, so the timer runs during the command."
  (interactive)
  (let ((ran nil))
    (run-with-timer 0.05 nil (lambda () (set-window-start drgnx-attr--other 900) (setq ran t)))
    (drgnx-test-wait (lambda () ran) :secs 5 :what "the timer inside the command")))

(ert-deftest drgnx-ui-attribution/timer-during-a-command ()
  (let ((other (drgnx-attr--two-windows)))
    (setq drgnx-attr--other other)
    (keymap-global-set "C-c z" #'drgnx-attr--slow-command)
    (unwind-protect
        (progn
          (let* ((r (drgnx-uitest-run (drgnx-uitest-key-events "C-c z")))
                 (moved (seq-find (lambda (s) (equal (plist-get s :window) (drgnx-uitest-window-id other)))
                                  (append (plist-get r :trace) nil))))
            (should moved)
            (should (string-prefix-p "timer:" (plist-get moved :cause)))))
      (keymap-global-unset "C-c z"))))

(defun drgnx-attr--move-then-wait ()
  (interactive)
  (let ((seen (length drgnx-uitest-record--log)))
    (forward-line 3)
    (drgnx-test-wait (lambda () (> (length drgnx-uitest-record--log) seen)) :secs 5 :what "the recorder's poll")))

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

(ert-deftest drgnx-ui-attribution/nested-timers-keep-their-own-changes ()
  ;; A timer that waits (sit-for) lets other timers run inside it; each keeps its own changes.
  (let ((other (drgnx-attr--two-windows)) (sel (selected-window)) (ran nil))
    (defun drgnx-attr--inner-timer () (set-window-start other 900) (setq ran t))
    (defun drgnx-attr--outer-timer ()
      (with-selected-window sel (goto-char 400))
      (run-with-timer 0.05 nil #'drgnx-attr--inner-timer)
      (drgnx-test-wait (lambda () ran) :secs 5 :what "the timer inside the timer"))
    (run-with-timer 0.05 nil #'drgnx-attr--outer-timer)
    (let* ((r (drgnx-uitest-run nil))
           (cause-of (lambda (win) (plist-get (seq-find (lambda (s) (equal (plist-get s :window) (drgnx-uitest-window-id win)))
                                                        (append (plist-get r :trace) nil))
                                              :cause))))
      (should (equal (funcall cause-of sel) "timer:drgnx-attr--outer-timer"))
      (should (equal (funcall cause-of other) "timer:drgnx-attr--inner-timer")))))
