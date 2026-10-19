;;; clock-fixture-test.el --- batch tests: the virtual clock fixture (Emacs's own timer lists on a clock the test moves) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)

(defvar drgnx-clock-test--runs nil "Virtual or idle times at which a test's timer functions ran, newest first.")

(defun drgnx-clock-test--close (a b) (< (abs (- a b)) 1e-6))

(defun drgnx-clock-test--note (&rest _) (push (float-time) drgnx-clock-test--runs))

(defun drgnx-clock-test--pending-function () nil)
(defun drgnx-clock-test--pending-idle () nil)

(defun drgnx-clock-test--since (start)
  "The times in `drgnx-clock-test--runs', oldest first, as milliseconds-rounded seconds after START."
  (mapcar (lambda (x) (/ (round (* 1000 (- x start))) 1000.0)) (reverse drgnx-clock-test--runs)))

(defun drgnx-clock-test--rearm ()
  "The idle re-arm idiom: run again 0.2 s later in the same pause (persist, B2).  Notes the pause length."
  (push (list (float-time (current-idle-time)) (input-pending-p)) drgnx-clock-test--runs)
  (run-with-idle-timer (time-add (current-idle-time) 0.2) nil #'drgnx-clock-test--rearm))

(defmacro drgnx-clock-test--with (&rest body)
  "BODY on the clock with `drgnx-clock-test--runs' empty, a timer left over cancelled so the end check passes."
  `(let ((drgnx-clock-test--runs nil)) (drgnx-test-with-clock () ,@body (mapc #'cancel-timer (append timer-list timer-idle-list)))))

(ert-deftest drgnx-clock/float-time-reads-virtual ()
  (drgnx-test-with-clock ()
    (let ((t0 (drgnx-test-clock-now)) (compiled (byte-compile (lambda () (list (float-time) (current-time))))))
      (should (>= (- t0 (drgnx-test-real-time)) 999999))   ; H after the real clock
      (should (drgnx-clock-test--close (float-time) t0))
      (should (drgnx-clock-test--close (float-time (current-time)) t0))
      (drgnx-test-advance 5)
      (should (drgnx-clock-test--close (float-time) (+ t0 5)))
      (let ((from-compiled (funcall compiled)))
        (should (drgnx-clock-test--close (car from-compiled) (+ t0 5)))
        (should (drgnx-clock-test--close (float-time (cadr from-compiled)) (+ t0 5))))
      (should (= 1.0 (float-time '(0 1))))))               ; with an argument: the original
  (should (< (abs (- (float-time) (drgnx-test-real-time))) 1)))   ; and outside, the real clock

(ert-deftest drgnx-clock/delays-count-from-the-virtual-start ()
  (drgnx-clock-test--with
   (let ((t0 (drgnx-test-clock-now)) one-shot)
     (run-at-time 1 1 #'drgnx-clock-test--note)
     (drgnx-test-advance 2.5)
     (should (equal (drgnx-clock-test--since t0) '(1.0 2.0)))
     (setq one-shot (run-at-time 1 nil #'drgnx-clock-test--note))   ; made at virtual 2.5: due at 3.5
     (drgnx-test-advance 1)
     (should (equal (drgnx-clock-test--since t0) '(1.0 2.0 3.0 3.5)))
     (should-not (memq one-shot timer-list)))))

(ert-deftest drgnx-clock/a-real-wait-fires-nothing ()
  (drgnx-clock-test--with
   (run-at-time 0.1 nil #'drgnx-clock-test--note)
   (run-at-time 0.05 0.05 #'drgnx-clock-test--note)
   (sleep-for 0.3)
   (accept-process-output nil 0.2)
   (should-not drgnx-clock-test--runs)
   (drgnx-test-advance 0.1)
   (should (= 3 (length drgnx-clock-test--runs)))))        ; the one-shot and the repeater at 0.05 and 0.1

(ert-deftest drgnx-clock/one-idle-call-is-one-pause ()
  (drgnx-clock-test--with
   (let ((repeating (run-with-idle-timer 0.2 t #'drgnx-clock-test--note)))
     (drgnx-test-idle 2.5)
     (should (= 1 (length drgnx-clock-test--runs)))         ; a repeating idle timer: once per pause
     (should-not (current-idle-time))
     (drgnx-test-idle 2.5)
     (should (= 2 (length drgnx-clock-test--runs)))         ; the next pause: once more
     (cancel-timer repeating)
     (setq drgnx-clock-test--runs nil)
     (run-with-idle-timer 0.2 nil #'drgnx-clock-test--rearm)
     (drgnx-test-idle 2.5)                                  ; at 0.2, 0.4 ... 2.4
     (should (= 12 (length drgnx-clock-test--runs)))
     (should (drgnx-clock-test--close (car (car drgnx-clock-test--runs)) 2.4))
     (should (equal (delete-dups (mapcar #'cadr drgnx-clock-test--runs)) '(nil))))))

(ert-deftest drgnx-clock/input-ends-the-pause ()
  (drgnx-clock-test--with
   (run-with-idle-timer 0.2 nil #'drgnx-clock-test--rearm)
   (should-not (input-pending-p))
   (drgnx-test-idle 3 :input-at 0.5)                         ; 0.2 and 0.4 run; 0.6 comes after the key
   (should (= 2 (length drgnx-clock-test--runs)))
   (should-not (input-pending-p))                            ; back to no input once the call returns
   (should (= 1 (length timer-idle-list)))))                 ; the next re-arm waits for the next pause

(ert-deftest drgnx-clock/input-pending-and-idle-time-are-seen-inside-the-pause ()
  (drgnx-clock-test--with
   (let (seen)
     (run-with-idle-timer 1 nil (lambda () (setq seen (list (float-time (current-idle-time)) (input-pending-p)))))
     (drgnx-test-idle 2)
     (should (equal seen '(1.0 nil))))))

(ert-deftest drgnx-clock/wall-timers-due-in-the-pause-run-too ()
  (drgnx-clock-test--with
   (let ((t0 (drgnx-test-clock-now)))
     (run-at-time 0.3 nil #'drgnx-clock-test--note)
     (run-at-time 9 nil #'drgnx-clock-test--note)
     (run-with-idle-timer 0.2 nil #'drgnx-clock-test--note)
     (drgnx-test-idle 1 :input-at 0.9)
     (should (= 2 (length drgnx-clock-test--runs)))
     (should (drgnx-clock-test--close (float-time (current-time)) (+ t0 0.9)))   ; the pause ended at the key
     (should (drgnx-clock-test--close (- (car drgnx-clock-test--runs) t0) 0.3)))))

(ert-deftest drgnx-clock/advance-by-the-delay-always-fires ()
  ;; run-at-time D then advance D fires, for every D (0.3 is not a whole number of binary floats)
  (let (misses)
    (drgnx-test-with-clock ()
      (let ((d 0.001))
        (while (<= d 3.0)
          (let* ((fired nil) (idle-fired nil) (tm (run-at-time d nil (lambda () (setq fired t)))))
            (drgnx-test-advance d)
            (unless fired (push (list 'advance d) misses))
            (cancel-timer tm)
            (setq fired nil)
            (run-at-time d nil (lambda () (setq fired t)))        ; a wall timer inside a pause
            (run-with-idle-timer d nil (lambda () (setq idle-fired t)))
            (drgnx-test-idle d)
            (unless fired (push (list 'pause-wall d) misses))
            (unless idle-fired (push (list 'pause-idle d) misses))
            (mapc #'cancel-timer (append timer-list timer-idle-list)))
          (setq d (+ d (if (< d 1.5) 0.01 0.07))))
        (dolist (d '(0.3 0.6 0.7 2.3 0.98 1.13))
          (let ((fired nil) (input nil))
            (run-at-time d nil (lambda () (setq fired t)))
            (run-with-idle-timer d nil (lambda () (setq input t)))
            (drgnx-test-idle (+ d 1) :input-at d)               ; the key arrives as the timers fall due: nothing runs
            (when (or fired input) (push (list 'input-at d) misses))
            (mapc #'cancel-timer (append timer-list timer-idle-list))))))
    (should-not misses)))

(ert-deftest drgnx-clock/the-real-lists-are-untouched ()
  (let ((before timer-list) (idle-before timer-idle-list) (copy (copy-sequence timer-list)) (idle-copy (copy-sequence timer-idle-list)))
    (drgnx-test-with-clock ()
      (should-not timer-list)
      (should-not timer-idle-list)
      (let ((a (run-at-time 5 nil #'ignore)) (b (run-with-idle-timer 5 nil #'ignore)))
        (should (memq a timer-list))
        (should (memq b timer-idle-list))
        (cancel-timer a)
        (cancel-timer b)))
    (should (eq timer-list before))
    (should (eq timer-idle-list idle-before))
    (should (equal timer-list copy))
    (should (equal timer-idle-list idle-copy))
    (should-not (advice-member-p #'drgnx-test--float-time 'float-time))))

(ert-deftest drgnx-clock/a-pending-timer-fails-the-test ()
  (let ((err (should-error (drgnx-test-with-clock ()
                             (run-at-time 5 nil #'drgnx-clock-test--pending-function)
                             (run-with-idle-timer 5 nil #'drgnx-clock-test--pending-idle))
                           :type 'ert-test-failed)))
    (should (string-match-p "drgnx-clock-test--pending-function" (format "%S" err)))
    (should (string-match-p "drgnx-clock-test--pending-idle" (format "%S" err))))
  (should-not drgnx-test--active))

(ert-deftest drgnx-clock/the-end-check-names-layer-timers-and-resets ()
  (let (reset)
    (cl-letf (((symbol-function 'drgnx-timer-pending) (lambda () '((hub-tick some-module))))
              ((symbol-function 'drgnx-timer-reset) (lambda () (setq reset t))))
      (let ((err (should-error (drgnx-test-with-clock () (run-at-time 5 nil #'ignore)) :type 'ert-test-failed)))
        (should reset)
        (should (string-match-p "(hub-tick some-module)" (format "%S" err)))
        ;; layer timers come before the raw functions
        (should (< (string-match "hub-tick" (format "%S" err)) (string-match "ignore" (format "%S" err)))))
      (setq reset nil)
      (drgnx-test-with-clock (:allow-pending t) (run-at-time 5 nil #'ignore))
      (should reset))))

(ert-deftest drgnx-clock/the-timer-layers-seams-follow-the-clock ()
  (cl-letf (((symbol-function 'drgnx-timer--now) (lambda () 'real))
            ((symbol-function 'drgnx-timer--idle-time) (lambda () 'real))
            ((symbol-function 'drgnx-timer--input-pending-p) (lambda () 'real)))
    (drgnx-clock-test--with
     (let (seen)
       (should (drgnx-clock-test--close (drgnx-timer--now) (drgnx-test-clock-now)))
       (should-not (drgnx-timer--idle-time))
       (should-not (drgnx-timer--input-pending-p))
       (run-with-idle-timer 0.5 nil (lambda () (setq seen (list (float-time (drgnx-timer--idle-time))
                                                                (drgnx-timer--input-pending-p)))))
       (drgnx-test-idle 1)
       (should (equal seen '(0.5 nil)))))
    (should (eq 'real (drgnx-timer--now)))))

(ert-deftest drgnx-clock/allow-pending-lets-it-pass ()
  (drgnx-test-with-clock (:allow-pending t)
    (run-at-time 5 nil #'ignore)
    (run-with-idle-timer 5 nil #'ignore)))

(ert-deftest drgnx-clock/a-body-error-restores-everything ()
  (let ((before timer-list) (reset nil))
    (cl-letf (((symbol-function 'drgnx-timer-reset) (lambda () (setq reset t))))
      (should-error (drgnx-test-with-clock ()
                      (run-at-time 5 nil #'ignore)
                      (run-with-idle-timer 5 nil #'ignore)
                      (error "boom"))))
    (should reset)
    (should-not drgnx-test--active)
    (should (eq timer-list before))
    (should-not drgnx-test--idle)
    (dolist (a '(float-time current-time current-idle-time input-pending-p timer--activate))
      (should-not (advice--p (advice--symbol-function a))))
    (should (< (abs (- (float-time) (drgnx-test-real-time))) 1))
    (should-not (input-pending-p))
    ;; and the fixture works again
    (drgnx-test-with-clock () (should (>= (- (drgnx-test-clock-now) (drgnx-test-real-time)) 999999)))))

(ert-deftest drgnx-clock/a-cold-advice-trampoline-arms-nothing-in-the-virtual-lists ()
  "Emacs 31 native-compiles a primitive's advice trampoline when it is first advised, and logging that compile arms
`undo-auto--boundary-timer'; the fixture compiles them before it swaps the lists, so the body starts clean.
The trampolines compiled here replace the old ones for all native code, and `comp-installed-trampolines-h' is what
keeps a trampoline from being collected: they go into Emacs's own table at the end, or the next collection unloads
them and native code that calls `current-time' (ERT itself) jumps into unmapped memory."
  (skip-unless (and (fboundp 'native-comp-available-p) (native-comp-available-p)
                    (boundp 'comp-installed-trampolines-h)))
  (let ((fresh (make-hash-table :test #'eq)))
    (unwind-protect
        (let* ((dir (make-temp-file "drgnx-clock-eln" t))
               (native-comp-eln-load-path (list (file-name-as-directory dir)))   ; no trampoline cached on disk either
               (comp-installed-trampolines-h fresh)                             ; and none installed in this process
               (undo-auto-current-boundary-timer nil))
          (unwind-protect
              (drgnx-test-with-clock ()
                (should-not timer-list)
                (should-not timer-idle-list))
            (when (timerp undo-auto-current-boundary-timer) (cancel-timer undo-auto-current-boundary-timer))
            (delete-directory dir t)))
      (maphash (lambda (subr trampoline) (puthash subr trampoline comp-installed-trampolines-h)) fresh)))
  (garbage-collect))                    ; an unprotected trampoline is unloaded here and ERT's `current-time' crashes

(ert-deftest drgnx-clock/the-undo-boundary-timer-is-not-the-bodys ()
  (let ((undo-auto-current-boundary-timer nil))
    (drgnx-test-with-clock ()
      (setq undo-auto-current-boundary-timer (run-at-time 10 nil #'undo-auto--boundary-timer))
      (cancel-timer (run-at-time 5 nil #'ignore)))   ; the fixture drops Emacs's timer, so nothing is pending
    (should-not undo-auto-current-boundary-timer)))

(ert-deftest drgnx-clock/nesting-is-an-error ()
  (should-error (drgnx-test-with-clock () (drgnx-test-with-clock () nil)))
  (should-not drgnx-test--active)
  (should-error (drgnx-test-advance 1))
  (should-error (drgnx-test-idle 1)))

(provide 'clock-fixture-test)
;;; clock-fixture-test.el ends here
