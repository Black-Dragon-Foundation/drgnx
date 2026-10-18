;;; clock-fixture.el --- virtual time for tests: Emacs's own timer lists on a clock the test moves -*- lexical-binding: t -*-
;;
;; (drgnx-test-with-clock (&key allow-pending) BODY...)  BODY on fresh timer lists and a virtual clock
;; (drgnx-test-advance SECS)                            wall timers due within SECS run, in due order, repeats included
;; (drgnx-test-idle SECS &key input-at)                 one idle pause; wall timers due in it run too
;; (drgnx-test-clock-now) / (drgnx-test-real-time)      virtual time / real time, both floats
;;
;; Nothing in the code under test changes: `float-time', `current-time', `current-idle-time' and `input-pending-p'
;; are advised while BODY runs, and `timer-list'/`timer-idle-list' are bound to nil, so every timer BODY starts,
;; whoever starts it, lands in lists of its own and runs only when the test says so.  Docs: docs/develop/harness.md
;; "Virtual time".
(require 'ert)
(require 'cl-lib)
(require 'timer)

(defconst drgnx-test--clock-shift 1000000
  "H: seconds the virtual clock starts after the real one, so a real wait never finds a virtual timer ripe.")

(defvar drgnx-test--active nil "Non-nil while `drgnx-test-with-clock' runs its body.")
(defvar drgnx-test--now nil "Virtual wall time, a Lisp time (exact).")
(defvar drgnx-test--idle nil "Idle time of the pause now running (a Lisp time), nil outside a pause.")
(defvar drgnx-test--input nil "Non-nil once simulated input has ended the pause, until `drgnx-test-idle' returns.")

(defun drgnx-test-real-time ()
  "The real time as a float: for waits and reports, which stay on the wall clock."
  (float-time (time-convert nil t)))

(defun drgnx-test-clock-now ()
  "Virtual time as a float; an error outside `drgnx-test-with-clock'."
  (unless drgnx-test--active (error "No virtual clock: use drgnx-test-with-clock"))
  (float-time drgnx-test--now))

;;;; The clock reads

(defun drgnx-test--float-time (orig &rest args)
  "`float-time' with no argument is virtual time; with one it is Emacs's own."
  (if args (apply orig args) (funcall orig drgnx-test--now)))

(defun drgnx-test--current-time ()
  "`current-time': virtual time, in the form Emacs uses."
  (time-convert drgnx-test--now (if current-time-list 'list t)))

(defun drgnx-test--current-idle-time ()
  "`current-idle-time': nil outside a pause, the pause's virtual length inside one."
  (and drgnx-test--idle (time-convert drgnx-test--idle (if current-time-list 'list t))))

(defun drgnx-test--input-pending-p (&rest _)
  "`input-pending-p': nil, or t once the pause was ended by simulated input."
  drgnx-test--input)

(defun drgnx-test--seam-now (&rest _) (float-time drgnx-test--now))

(defun drgnx-test--move-to-virtual (timer &optional _triggered _cell idle)
  "A wall timer stamped from the real clock (by `run-at-time', whoever calls it) moves onto the virtual clock.
The delay counts from the virtual now: a timer made at virtual v with delay d is due at v + d.  Emacs stamped it a
few microseconds before this advice runs, so a delay of 2 ms or more is rounded to the millisecond (1 s stays
exactly 1 s).  A timer already in the virtual era (its time is H away from the real one) and every idle timer stay
as they are."
  (unless (or idle (not (timerp timer)))
    (let ((due (timer--time timer)) (real (time-convert nil t)))
      (when (and (consp due) (time-less-p due (time-add real (/ drgnx-test--clock-shift 2))))
        (let ((delay (float-time (time-subtract due real))))
          (setf (timer--time timer)
                (time-add drgnx-test--now (if (>= delay 0.002) (cons (round (* 1000 delay)) 1000) delay))))))))

(defconst drgnx-test--seams
  '((drgnx-timer--now . drgnx-test--seam-now)
    (drgnx-timer--idle-time . drgnx-test--current-idle-time)
    (drgnx-timer--input-pending-p . drgnx-test--input-pending-p))
  "The timer layer's three seams, and the fixture function each follows (contract point 1).")

(defun drgnx-test--advice ()
  "The advice the fixture installs: (SYMBOL HOW FUNCTION), the layer's seams last and only when they exist."
  (append '((float-time :around drgnx-test--float-time)
            (current-time :override drgnx-test--current-time)
            (current-idle-time :override drgnx-test--current-idle-time)
            (input-pending-p :override drgnx-test--input-pending-p)
            (timer--activate :before drgnx-test--move-to-virtual))
          (cl-loop for (seam . fn) in drgnx-test--seams
                   when (fboundp seam) collect (list seam :override fn))))

;;;; Time moves

(defun drgnx-test--snap (secs)
  "SECS as a time: a number within a microsecond of a whole millisecond becomes that exact millisecond count.
A timer made by `run-at-time' D is due at an exact millisecond (`drgnx-test--move-to-virtual'), so the time a test
advances by (0.3 is 0.29999999999999998 in binary) is snapped the same way and `advance D' always reaches it."
  (if (numberp secs)
      (let ((ms (round (* 1000 secs))))
        (if (< (abs (- secs (/ ms 1000.0))) 1e-6) (cons ms 1000) secs))
    secs))

(defun drgnx-test--check-active ()
  (unless drgnx-test--active (error "No virtual clock: use drgnx-test-with-clock")))

(defun drgnx-test-advance (secs)
  "Move virtual time forward SECS seconds, running every wall timer that comes due, in order.
A timer runs by `timer-event-handler' while still on `timer-list' (popping it first makes the handler treat it as
cancelled), and a repeating one runs again each time it is due again within SECS."
  (drgnx-test--check-active)
  (let ((target (time-add drgnx-test--now (drgnx-test--snap secs))) (runs 0) timer)
    (while (and (setq timer (cl-find-if-not #'timer--triggered timer-list))
                (not (time-less-p target (timer--time timer))))
      (when (> (cl-incf runs) 10000) (error "Timers re-arm themselves at once: a busy loop"))
      (when (time-less-p drgnx-test--now (timer--time timer)) (setq drgnx-test--now (timer--time timer)))
      (timer-event-handler timer))
    (setq drgnx-test--now target)
    nil))

(cl-defun drgnx-test-idle (secs &key input-at)
  "One idle pause of SECS seconds, as Emacs's command loop runs it, then back to non-idle.
Every idle timer is a candidate again (`timer_start_idle' clears their triggered flag); each one due and not yet
run in this pause runs in time order, the pause clock moving to its time, a repeating one once.  A one-shot a timer
arms at `(time-add (current-idle-time) D)' runs too when it is due within the pause.  Wall timers due in the pause
run in the same order, virtual time moving with it.  From INPUT-AT seconds into the pause nothing more runs and
`input-pending-p' is t until this returns."
  (drgnx-test--check-active)
  (when drgnx-test--idle (error "drgnx-test-idle: already in a pause"))
  (setq secs (drgnx-test--snap secs) input-at (and input-at (drgnx-test--snap input-at)))
  (let ((start drgnx-test--now) (runs 0) (end (if (and input-at (time-less-p input-at secs)) input-at secs)) done)
    (dolist (timer timer-idle-list) (setf (timer--triggered timer) nil))
    (setq drgnx-test--idle 0)
    (unwind-protect
        (while (not done)
          (let* ((idle (cl-find-if-not #'timer--triggered timer-idle-list))
                 (wall (cl-find-if-not #'timer--triggered timer-list))
                 (idle-at (and idle (drgnx-test--snap (float-time (timer--time idle)))))   ; stored truncated to a picosecond
                 (wall-at (and wall (time-subtract (timer--time wall) start)))
                 (next (cond ((and idle wall) (if (time-less-p wall-at idle-at) wall idle))
                             (t (or idle wall))))
                 (at (and next (if (eq next wall) wall-at idle-at))))
            (cond ((or (null next) (time-less-p secs at)) (setq done t))
                  ((and input-at (not (time-less-p at input-at)))
                   (setq drgnx-test--input t done t))
                  (t (when (> (cl-incf runs) 1000)
                       (error "Idle timers re-arm themselves at once: a busy loop"))
                     (when (time-less-p drgnx-test--idle at) (setq drgnx-test--idle at))
                     (when (time-less-p drgnx-test--now (time-add start at))
                       (setq drgnx-test--now (time-add start at)))
                     (timer-event-handler next)))))
      (setq drgnx-test--now (let ((to (time-add start end)))
                              (if (time-less-p drgnx-test--now to) to drgnx-test--now))
            drgnx-test--idle nil
            drgnx-test--input nil))
    nil))

;;;; The fixture

(defvar undo-auto-current-boundary-timer)
(declare-function drgnx-timer-pending "drgnx-timer" ())
(declare-function drgnx-timer-reset "drgnx-timer" ())

(defun drgnx-test--pending-names ()
  "What is still pending, for the failure message: the layer's timers as (KEY OWNER), then raw functions."
  (append (and (fboundp 'drgnx-timer-pending) (ignore-errors (drgnx-timer-pending)))
          (mapcar (lambda (timer)
                    (let ((fn (timer--function timer))) (if (symbolp fn) fn 'anonymous-function)))
                  (append timer-list timer-idle-list))))

(defun drgnx-test--drop-emacs-timers ()
  "Cancel the housekeeping timer Emacs arms by itself (`undo-auto--boundary-timer'): it is not the code under test's."
  (dolist (timer (copy-sequence timer-list))
    (when (eq (timer--function timer) 'undo-auto--boundary-timer)
      (cancel-timer timer)
      (when (eq timer undo-auto-current-boundary-timer) (setq undo-auto-current-boundary-timer nil)))))

(defun drgnx-test--warm-trampolines ()
  "Advise and unadvise each primitive the fixture advises, on scratch timer lists.
Emacs 31 native-compiles a primitive's advice trampoline on the first `advice-add' of it, and logging that compile
arms `undo-auto--boundary-timer'; done here, the body's lists never see it and the real lists are left as they were."
  (let ((timer-list nil) (timer-idle-list nil))
    (dolist (a (drgnx-test--advice))
      (when (subrp (symbol-function (nth 0 a)))
        (advice-add (nth 0 a) :around #'ignore)
        (advice-remove (nth 0 a) #'ignore)))
    (drgnx-test--drop-emacs-timers)))

(defun drgnx-test--call-with-clock (body allow-pending)
  "Run BODY (a function) on the virtual clock; see `drgnx-test-with-clock'."
  (when drgnx-test--active (error "drgnx-test-with-clock cannot nest"))
  (drgnx-test--warm-trampolines)
  (let ((timer-list nil) (timer-idle-list nil)
        (drgnx-test--active t)
        (drgnx-test--now (time-add (time-convert (floor (float-time (time-convert nil t))) t)
                                   drgnx-test--clock-shift))
        (drgnx-test--idle nil) (drgnx-test--input nil)
        (advice (drgnx-test--advice)) names)
    (unwind-protect
        (progn (dolist (a advice) (advice-add (nth 0 a) (nth 1 a) (nth 2 a)))
               (funcall body)
               (drgnx-test--drop-emacs-timers)
               (when (and (not allow-pending) (or timer-list timer-idle-list))
                 (setq names (drgnx-test--pending-names))))
      (dolist (a advice) (advice-remove (nth 0 a) (nth 2 a)))
      (when (fboundp 'drgnx-timer-reset) (ignore-errors (drgnx-timer-reset))))
    (when names (ert-fail (list "Timers still pending at the end of the test (pass :allow-pending t to allow):" names)))))

(cl-defmacro drgnx-test-with-clock ((&key allow-pending) &rest body)
  "Run BODY on a virtual clock.
BODY sees fresh `timer-list' and `timer-idle-list'; `float-time' and `current-time' without an argument return
virtual time (it starts 10^6 s after the real one, so a real wait never finds a virtual timer ripe), moved only by
`drgnx-test-advance' and `drgnx-test-idle'; `current-idle-time' and `input-pending-p' follow `drgnx-test-idle'.
Timers made by `run-at-time' are moved onto the virtual clock when activated.  At the end a pending timer fails
the test (naming the layer's keys and owners, then raw functions) unless `:allow-pending' is t.  Nesting is an
error.  Use: (drgnx-test-with-clock () ...) or (drgnx-test-with-clock (:allow-pending t) ...)."
  (declare (indent 1))
  `(drgnx-test--call-with-clock (lambda () ,@body) ,allow-pending))

(provide 'clock-fixture)
;;; clock-fixture.el ends here
