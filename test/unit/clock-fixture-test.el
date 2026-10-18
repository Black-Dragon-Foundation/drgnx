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

(ert-deftest drgnx-test-clock/float-time-and-current-time-read-virtual-time ()
  (drgnx-test-with-clock ()
    (let ((t0 (float-time)) (compiled (byte-compile (lambda () (list (float-time) (current-time))))))
      (should (< (abs (- t0 (drgnx-test-real-time))) 1))   ; T0 is the real time at entry: timestamps stay plausible
      (should (= 0.0 (drgnx-test-clock-now)))
      (should (drgnx-clock-test--close (float-time (current-time)) t0))
      (drgnx-test-advance 5)
      (should (drgnx-clock-test--close (float-time) (+ t0 5)))
      (should (drgnx-clock-test--close (drgnx-test-clock-now) 5))
      (let ((from-compiled (funcall compiled)))
        (should (drgnx-clock-test--close (car from-compiled) (+ t0 5)))
        (should (drgnx-clock-test--close (float-time (cadr from-compiled)) (+ t0 5))))))
  (should (< (abs (- (float-time) (drgnx-test-real-time))) 1)))   ; outside, the real clock

(ert-deftest drgnx-test-clock/an-argument-reads-the-original ()
  (drgnx-test-with-clock ()
    (drgnx-test-advance 100)
    (should (= 1.0 (float-time '(0 1))))
    (should (= 2.5 (float-time (cons 5 2))))))

(ert-deftest drgnx-test-clock/a-one-shot-and-a-repeat-run-at-their-virtual-times ()
  (drgnx-clock-test--with
   (let ((t0 (float-time)) (one-shot (run-at-time 5 nil #'drgnx-clock-test--note)))
     (run-at-time 1 1 #'drgnx-clock-test--note)
     (drgnx-test-advance 4.5)
     (should (equal (mapcar (lambda (x) (round (* 1000000 (- x t0)))) (reverse drgnx-clock-test--runs))
                    '(1000000 2000000 3000000 4000000)))
     (setq drgnx-clock-test--runs nil)
     (drgnx-test-advance 1.0)                                  ; 4.5 -> 5.5: the one-shot at 5, then the repeat at 5
     (should (= 2 (length drgnx-clock-test--runs)))
     (should-not (memq one-shot timer-list)))))

(ert-deftest drgnx-test-clock/contract-2-a-timer-made-after-an-advance-counts-from-then ()
  (drgnx-clock-test--with
   (let ((t0 (float-time)) one-shot)
     (run-at-time 1 1 #'drgnx-clock-test--note)
     (drgnx-test-advance 2.5)
     (should (equal (drgnx-clock-test--since t0) '(1.0 2.0)))
     (setq one-shot (run-at-time 1 nil #'drgnx-clock-test--note))   ; made at virtual 2.5: due at 3.5
     (drgnx-test-advance 1)
     (should (equal (drgnx-clock-test--since t0) '(1.0 2.0 3.0 3.5)))
     (should-not (memq one-shot timer-list)))))

(ert-deftest drgnx-test-clock/a-real-wait-fires-no-virtual-timer ()
  (drgnx-clock-test--with
   (run-at-time 0.1 nil #'drgnx-clock-test--note)
   (run-at-time 0.05 0.05 #'drgnx-clock-test--note)
   (funcall drgnx-test--accept nil 0.3)                      ; the original, a real 0.3 s wait
   (should-not drgnx-clock-test--runs)
   (should (= 0.0 (drgnx-test-clock-now)))
   (drgnx-test-advance 0.1)
   (should (= 3 (length drgnx-clock-test--runs)))))        ; the one-shot and the repeater at 0.05 and 0.1

(ert-deftest drgnx-test-clock/sleep-for-advances-by-its-argument ()
  (drgnx-clock-test--with
   (let ((t0 (float-time)) (began (drgnx-test-real-time)))
     (run-at-time 1 nil #'drgnx-clock-test--note)
     (run-at-time 4 nil #'drgnx-clock-test--note)
     (sleep-for 2.5)
     (should (drgnx-clock-test--close (drgnx-test-clock-now) 2.5))
     (should (equal (drgnx-clock-test--since t0) '(1.0)))
     (sleep-for 2 500)                                         ; the obsolete milliseconds argument
     (should (drgnx-clock-test--close (drgnx-test-clock-now) 5.0))
     (should (equal (drgnx-clock-test--since t0) '(1.0 4.0)))
     (should (< (- (drgnx-test-real-time) began) 1)))))

(ert-deftest drgnx-test-clock/sit-for-advances-and-sees-input ()
  (drgnx-clock-test--with
   (let (seen)
     (should (eq t (sit-for 1.5)))
     (should (drgnx-clock-test--close (drgnx-test-clock-now) 1.5))
     (run-with-idle-timer 0.2 nil (lambda () (setq seen (list (sit-for 1) (input-pending-p) (sit-for 1)))))
     (drgnx-test-idle 3 :input-at 0.5)                         ; the sit-for ends at the key, 0.3 s in
     (should (equal seen '(nil t nil)))
     (should (drgnx-clock-test--close (drgnx-test-clock-now) 2.0))
     (should-not (input-pending-p)))))

(ert-deftest drgnx-test-clock/a-timed-accept-advances-by-the-real-wait ()
  (drgnx-clock-test--with
   (let ((began (drgnx-test-real-time)))
     (run-at-time 0.1 nil #'drgnx-clock-test--note)
     (accept-process-output nil 0.2)
     (let ((waited (- (drgnx-test-real-time) began)))
       (should (>= waited 0.15))
       (should (< (abs (- (drgnx-test-clock-now) waited)) 0.05))
       (should (= 1 (length drgnx-clock-test--runs)))))))      ; the 0.1 s timer came due in it

(ert-deftest drgnx-test-clock/a-polling-loop-with-a-float-time-deadline-ends ()
  (drgnx-clock-test--with
   (let ((began (drgnx-test-real-time)) (deadline (+ (float-time) 30)) (steps 0))
     (while (< (float-time) deadline)
       (sleep-for 0.05)
       (cl-incf steps))
     (should (<= 599 steps 601))
     (should (< (- (drgnx-test-real-time) began) 1)))))

(ert-deftest drgnx-test-clock/advance-stops-a-runaway-repeat ()
  (should (= 10000 drgnx-test-clock-max-runs))
  (drgnx-test-with-clock (:allow-pending t)
    (let ((drgnx-test-clock-max-runs 200) (runs 0))
      (letrec ((again (lambda () (cl-incf runs) (run-at-time 0 nil again))))
        (run-at-time 0 nil again)
        (let ((err (should-error (drgnx-test-advance 1))))
          (should (equal (cadr err) "drgnx-test-advance: more than 200 timer runs (a timer re-arms with no delay?)"))
          (should (= 200 runs)))))))

(ert-deftest drgnx-test-clock/contract-3-one-idle-call-is-one-pause ()
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

(ert-deftest drgnx-test-clock/input-ends-the-pause ()
  (drgnx-clock-test--with
   (run-with-idle-timer 0.2 nil #'drgnx-clock-test--rearm)
   (should-not (input-pending-p))
   (drgnx-test-idle 3 :input-at 0.5)                         ; 0.2 and 0.4 run; 0.6 comes after the key
   (should (= 2 (length drgnx-clock-test--runs)))
   (should-not (input-pending-p))                            ; back to no input once the call returns
   (should (= 1 (length timer-idle-list)))))                 ; the next re-arm waits for the next pause

(ert-deftest drgnx-test-clock/input-pending-and-idle-time-are-seen-inside-the-pause ()
  (drgnx-clock-test--with
   (let (seen)
     (run-with-idle-timer 1 nil (lambda () (setq seen (list (float-time (current-idle-time)) (input-pending-p)))))
     (drgnx-test-idle 2)
     (should (equal seen '(1.0 nil))))))

(ert-deftest drgnx-test-clock/wall-timers-due-in-a-pause-run-too ()
  (drgnx-clock-test--with
   (let ((t0 (float-time)))
     (run-at-time 0.3 nil #'drgnx-clock-test--note)
     (run-at-time 9 nil #'drgnx-clock-test--note)
     (run-with-idle-timer 0.2 nil #'drgnx-clock-test--note)
     (drgnx-test-idle 1 :input-at 0.9)
     (should (= 2 (length drgnx-clock-test--runs)))
     (should (drgnx-clock-test--close (float-time (current-time)) (+ t0 0.9)))   ; the pause ended at the key
     (should (drgnx-clock-test--close (- (car drgnx-clock-test--runs) t0) 0.3)))))

(ert-deftest drgnx-test-clock/advance-by-the-delay-always-fires ()
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

(ert-deftest drgnx-test-clock/the-real-timer-lists-are-untouched ()
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

(ert-deftest drgnx-test-clock/a-pending-timer-fails-the-test-named-by-function ()
  (let ((err (should-error (drgnx-test-with-clock ()
                             (run-at-time 5 nil #'drgnx-clock-test--pending-function)
                             (run-at-time 6 nil (lambda () nil))
                             (run-with-idle-timer 5 nil #'drgnx-clock-test--pending-idle))
                           :type 'ert-test-failed)))
    (should (string-match-p "timers still pending at the end of drgnx-test-with-clock" (format "%S" err)))
    (should (string-match-p "drgnx-clock-test--pending-function" (format "%S" err)))
    (should (string-match-p "drgnx-clock-test--pending-idle" (format "%S" err)))
    (should (string-match-p "lambda" (format "%S" err))))
  (should-not drgnx-test--active))

(ert-deftest drgnx-test-clock/contract-4-pending-layer-timers-are-named-first-and-reset ()
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

(ert-deftest drgnx-test-clock/contract-1-the-seams-read-the-virtual-clock ()
  (cl-letf (((symbol-function 'drgnx-timer--now) (lambda () 'real))
            ((symbol-function 'drgnx-timer--idle-time) (lambda () 'real))
            ((symbol-function 'drgnx-timer--input-pending-p) (lambda () 'real)))
    (drgnx-clock-test--with
     (let (seen)
       (should (drgnx-clock-test--close (drgnx-timer--now) (float-time)))
       (should-not (drgnx-timer--idle-time))
       (should-not (drgnx-timer--input-pending-p))
       (run-with-idle-timer 0.5 nil (lambda () (setq seen (list (float-time (drgnx-timer--idle-time))
                                                                (drgnx-timer--input-pending-p)))))
       (drgnx-test-idle 1)
       (should (equal seen '(0.5 nil)))))
    (should (eq 'real (drgnx-timer--now)))))

(ert-deftest drgnx-test-clock/allow-pending-cancels-quietly ()
  (let (ran wall idle)
    (drgnx-test-with-clock (:allow-pending t)
      (setq wall (run-at-time 5 nil (lambda () (setq ran t)))
            idle (run-with-idle-timer 5 nil (lambda () (setq ran t)))))
    (timer-event-handler wall)                                 ; a cancelled timer is not run, even when called
    (timer-event-handler idle)
    (should-not ran)))

(ert-deftest drgnx-test-clock/a-body-error-restores-everything ()
  (let ((before timer-list) (reset nil))
    (cl-letf (((symbol-function 'drgnx-timer-reset) (lambda () (setq reset t))))
      (should-error (drgnx-test-with-clock ()
                      (run-at-time 5 nil #'ignore)
                      (run-with-idle-timer 5 nil #'ignore)
                      (error "boom"))))
    (should reset)
    (should-not drgnx-test--active)
    (should (eq timer-list before))
    (should-not drgnx-test--pause)
    (dolist (a '(float-time current-time current-idle-time input-pending-p sleep-for sit-for accept-process-output
                            timer--activate))
      (should-not (advice--p (advice--symbol-function a))))
    (should (< (abs (- (float-time) (drgnx-test-real-time))) 1))
    (should-not (input-pending-p))
    ;; and the fixture works again
    (drgnx-test-with-clock () (should (= 0.0 (drgnx-test-clock-now))))))

(ert-deftest drgnx-test-clock/nesting-is-an-error ()
  (let ((err (should-error (drgnx-test-with-clock () (drgnx-test-with-clock () nil)))))
    (should (equal (cadr err) "drgnx-test-with-clock: already inside one")))
  (should-not drgnx-test--active)
  (should-error (drgnx-test-advance 1))
  (should-error (drgnx-test-idle 1)))

(ert-deftest drgnx-test-clock/loading-the-layer-inside-is-an-error ()
  (cl-letf (((symbol-function 'drgnx-timer--now) nil))        ; not loaded at entry, even when the suite has it loaded
    (let ((err (should-error (drgnx-test-with-clock ()
                               (fset 'drgnx-timer--now (lambda () 0.0))))))
      (should (equal (cadr err) "drgnx-timer was loaded inside drgnx-test-with-clock: require it first")))
    (should-not drgnx-test--active)))

(ert-deftest drgnx-test-clock/trampolines-land-in-the-runs-eln-dir ()
  (skip-unless (and (fboundp 'native-comp-available-p) (native-comp-available-p) native-comp-eln-load-path))
  (let* ((names '(float-time current-time current-idle-time input-pending-p sleep-for sit-for accept-process-output))
         (primitives (cl-remove-if-not (lambda (f) (subr-primitive-p (symbol-function f))) names))
         (home (file-name-as-directory (expand-file-name "~"))))
    (should (>= (length primitives) 6))
    (drgnx-test-with-clock ())
    (dolist (f primitives)
      (let ((found (cl-loop for dir in native-comp-eln-load-path
                            append (file-expand-wildcards
                                    (expand-file-name (format "*/subr--trampoline-*_%s_*.eln" (subst-char-in-string ?- ?_ (symbol-name f)))
                                                      dir)))))
        (should found)
        (dolist (file found)                                  ; the run's directory or Emacs's own, never ~
          (should-not (string-prefix-p home file)))))))

(provide 'clock-fixture-test)
;;; clock-fixture-test.el ends here
