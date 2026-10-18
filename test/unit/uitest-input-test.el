;;; uitest-input-test.el --- batch tests: event construction -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-uitest)

(ert-deftest drgnx-uitest/key-events ()
  (should (equal (drgnx-uitest-key-events "C-x b") '(24 98)))
  (should (equal (drgnx-uitest-key-events "M-x") (list (aref (kbd "M-x") 0)))))

(ert-deftest drgnx-uitest/type-events ()
  (should (equal (drgnx-uitest-type-events "a\"✓") (list ?a ?\" ?✓)))
  (should (equal (drgnx-uitest-type-events "a\nb") (list ?a 'return ?b))))     ; a newline is the Return key, not C-j

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

(ert-deftest drgnx-uitest/settle-scale-follows-the-load-per-core ()
  ;; M4-13/M5-6: a loaded machine settles slower; the 5 s default stretches with it.
  (should (= (drgnx-uitest-settle-scale 0.5 4 "") 1.0))        ; idle
  (should (= (drgnx-uitest-settle-scale 3.9 4 "") 1.0))        ; a core to spare: never shorter
  (should (= (drgnx-uitest-settle-scale 8.0 4 "") 2.0))        ; two runnable tasks per core
  (should (= (drgnx-uitest-settle-scale 400.0 4 "") drgnx-uitest-settle-scale-max)) ; bounded
  (should (= (drgnx-uitest-settle-scale nil 4 "") (drgnx-uitest-settle-scale (car (load-average t)) 4 "")))
  (should (>= (drgnx-uitest-settle-scale) 1.0)))

(ert-deftest drgnx-uitest/settle-scale-env-overrides ()
  (should (= (drgnx-uitest-settle-scale 0.1 4 "3") 3.0))
  (should (= (drgnx-uitest-settle-scale 0.1 4 "1.5") 1.5))
  (should (= (drgnx-uitest-settle-scale 8.0 4 "0.5") 0.5))     ; a lower factor is allowed: the user asked
  (should (= (drgnx-uitest-settle-scale 8.0 4 "0") 2.0))       ; zero and junk are ignored
  (should (= (drgnx-uitest-settle-scale 8.0 4 "fast") 2.0))
  (let ((process-environment (cons "DRGNX_UITEST_SETTLE_SCALE=4" process-environment)))
    (should (= (drgnx-uitest-settle-scale 0.1 4) 4.0))))

(ert-deftest drgnx-uitest/run-deadline-uses-the-scaled-default ()
  (let (deadline)
    (cl-letf (((symbol-function 'drgnx-uitest-settle-scale) (lambda (&rest _) 3.0))
              ((symbol-function 'drgnx-uitest-measure-begin) #'ignore)
              ((symbol-function 'drgnx-uitest-enqueue) #'ignore)
              ((symbol-function 'recursive-edit) (lambda () (setq deadline drgnx-uitest--run-deadline)))
              ((symbol-function 'drgnx-uitest-measure-end) (lambda () nil)))
      (let ((t0 (float-time)))
        (drgnx-uitest-run nil)
        (should (< 14.9 (- deadline t0) 15.5))                 ; 5 s * 3
        (drgnx-uitest-run nil 2)
        (should (< 1.9 (- deadline t0) 2.5))))))                ; an explicit timeout is not scaled
