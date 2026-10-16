;;; uitest-input-test.el --- batch tests: event construction -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-uitest)

(ert-deftest drgnx-uitest/key-events ()
  (should (equal (drgnx-uitest-key-events "C-x b") '(24 98)))
  (should (equal (drgnx-uitest-key-events "M-x") (list (aref (kbd "M-x") 0)))))

(ert-deftest drgnx-uitest/type-events ()
  (should (equal (drgnx-uitest-type-events "a\"✓") (list ?a ?\" ?✓))))

(ert-deftest drgnx-uitest/click-events ()
  ;; The release is resolved when it is delivered (a click, or a drag if the text moved).
  (should (equal (drgnx-uitest-click-events 'P) '((down-mouse-1 P) (drgnx-uitest-release 1 P))))
  (should (equal (drgnx-uitest-click-events 'P 3 1 0.3)
                 '((down-mouse-3 P) (drgnx-uitest-pause . 0.3) (drgnx-uitest-release 3 P))))
  (should (equal (drgnx-uitest-click-events 'P 1 2)
                 '((down-mouse-1 P) (drgnx-uitest-release 1 P) (double-down-mouse-1 P 2) (double-mouse-1 P 2)))))

(ert-deftest drgnx-uitest/window-ids-are-stable ()
  (let ((w (selected-window)))
    (should (string-match-p "\\`w[0-9]+\\'" (drgnx-uitest-window-id w)))
    (should (equal (drgnx-uitest-window-id w) (drgnx-uitest-window-id w)))
    (should (equal (drgnx-uitest-window-id (minibuffer-window)) "mini"))))

(ert-deftest drgnx-uitest/queue-delivers-one-event-per-tick ()
  (let ((drgnx-uitest--queue nil) (unread-command-events nil) (drgnx-uitest--timer 'dummy))
    (setq drgnx-uitest--queue (list ?a '(drgnx-uitest-pause . 0) ?b))
    (drgnx-uitest--tick)
    (should (equal unread-command-events '(?a)))
    (drgnx-uitest--tick)                        ; pause becomes a deadline
    (drgnx-uitest--tick)                        ; deadline passed: dropped
    (drgnx-uitest--tick)
    (should (equal unread-command-events '(?a ?b)))
    (should (null drgnx-uitest--queue))
    (setq unread-command-events nil)))

(ert-deftest drgnx-uitest/settled-waits-from-the-start-of-a-measurement ()
  ;; A measurement with no input must still give followers (timers) the quiet period.
  (let ((drgnx-uitest--queue nil) (unread-command-events nil)
        (drgnx-uitest--last-delivery 0.0)
        (drgnx-uitest-record--last-change 0.0)
        (drgnx-uitest-record--t0 (float-time)))
    (should-not (drgnx-uitest-settled-p 0.3))
    (let ((drgnx-uitest-record--t0 (- (float-time) 1)))
      (should (drgnx-uitest-settled-p 0.3)))))
