;;; clock-fixture.el --- virtual time for tests: Emacs's own timer lists on a clock the test moves -*- lexical-binding: t -*-
;;
;; (drgnx-test-with-clock (&key allow-pending) BODY...)  BODY on fresh timer lists and a virtual clock
;; (drgnx-test-advance SECS)                            wall timers due within SECS run, in due order, repeats included
;; (drgnx-test-idle SECS &key input-at)                 one idle pause; wall timers due in it run too
;; (drgnx-test-clock-now) / (drgnx-test-real-time)      virtual seconds since the fixture began / real time, both floats
;;
;; Nothing in the code under test changes: `float-time', `current-time', `current-idle-time', `input-pending-p',
;; `sleep-for', `sit-for' and `accept-process-output' are advised while BODY runs, and `timer-list'/`timer-idle-list'
;; are bound to nil, so every timer BODY starts, whoever starts it, lands in lists of its own and runs only when the
;; test (or a wait that moves virtual time) says so.  Docs: docs/develop/core.md "Testing: time, waits and processes",
;; docs/develop/harness.md "Virtual time".
(require 'ert)
(require 'cl-lib)
(require 'timer)

(defvar drgnx-test-clock-horizon 1000000
  "H, seconds: a wall timer's time is its virtual due time plus H, so a real wait never finds one ripe.")

(defvar drgnx-test-clock-max-runs 10000
  "More timer runs than this in one `drgnx-test-advance' is an error (a timer that re-arms with no delay).")

(defvar drgnx-test--active nil "Non-nil while `drgnx-test-with-clock' runs its body.")
(defvar drgnx-test--start nil "T0: the real time at entry, a Lisp time (exact).")
(defvar drgnx-test--now nil "Virtual wall time, T0 plus the virtual seconds so far, a Lisp time (exact).")
(defvar drgnx-test--pause nil "Virtual time at which the idle pause now running began, nil outside a pause.")
(defvar drgnx-test--input-at nil "Virtual time from which simulated input is pending (inside a pause), or nil.")
(defvar drgnx-test--accept nil "The original `accept-process-output', for a real zero-length look at process output.")

(defun drgnx-test-real-time ()
  "The real time as a float: for waits and reports, which stay on the wall clock."
  (float-time (time-convert nil t)))

(defun drgnx-test-clock-now ()
  "Virtual seconds since `drgnx-test-with-clock' began, a float (0.0 at entry); an error outside it."
  (unless drgnx-test--active (error "No virtual clock: use drgnx-test-with-clock"))
  (float-time (time-subtract drgnx-test--now drgnx-test--start)))

(defun drgnx-test--secs (secs)
  "SECS as an exact Lisp time.
A number within a microsecond of a whole millisecond becomes that exact millisecond count, as a timer's delay does
(`drgnx-test-clock--shift'), so `run-at-time D' then `drgnx-test-advance D' always fires (0.3 is not exact in
binary).  Any other float is rounded to the microsecond, so repeated sums do not drift."
  (if (numberp secs)
      (let ((ms (round (* 1000 secs))))
        (cond ((< (abs (- secs (/ ms 1000.0))) 1e-6) (cons ms 1000))
              ((floatp secs) (cons (round (* secs 1000000)) 1000000))
              (t secs)))
    secs))

;;;; The clock reads

(defun drgnx-test--float-time (orig &rest args)
  "`float-time' with no argument is virtual time; with one it is Emacs's own."
  (if args (apply orig args) (funcall orig drgnx-test--now)))

(defun drgnx-test--current-time ()
  "`current-time': virtual time, in the form Emacs uses."
  (time-convert drgnx-test--now (if current-time-list 'list t)))

(defun drgnx-test--current-idle-time ()
  "`current-idle-time': nil outside a pause, the pause's virtual length inside one."
  (and drgnx-test--pause
       (time-convert (time-subtract drgnx-test--now drgnx-test--pause) (if current-time-list 'list t))))

(defun drgnx-test--input-pending-p (&rest _)
  "`input-pending-p': t from the pause's INPUT-AT on, nil otherwise."
  (and drgnx-test--input-at (not (time-less-p drgnx-test--now drgnx-test--input-at))))

(defun drgnx-test--seam-now (&rest _) (float-time drgnx-test--now))

(defun drgnx-test-clock--shift (timer &optional _triggered _cell idle)
  "A wall timer stamped from the real clock (by `run-at-time', whoever calls it) moves onto the virtual clock plus H.
Stamp minus real now is the delay, so a timer made at virtual v with delay d is due at v + d.  Emacs stamped it a
few microseconds before this advice runs, so a delay of 2 ms or more is rounded to the millisecond (1 s stays
exactly 1 s).  A timer already in the virtual era (its time is H away from the real one: a re-armed repeat) and
every idle timer stay as they are.  A time computed from the virtual clock (`float-time' plus a delay) reads as a
real stamp: give timers delays, not absolute times."
  (unless (or idle (not (timerp timer)))
    (let ((due (timer--time timer)) (real (time-convert nil t)))
      (when (and (consp due) (time-less-p due (time-add real (/ drgnx-test-clock-horizon 2))))
        (let ((delay (float-time (time-subtract due real))))
          (setf (timer--time timer)
                (time-add (time-add drgnx-test--now drgnx-test-clock-horizon)
                          (if (>= delay 0.002) (cons (round (* 1000 delay)) 1000) delay))))))))

(defun drgnx-test--due (timer)
  "The virtual time at which wall TIMER is due."
  (time-subtract (timer--time timer) drgnx-test-clock-horizon))

;;;; Waits move virtual time

(defun drgnx-test--sleep-for (seconds &optional millis)
  "`sleep-for': virtual time moves by SECONDS (and MILLIS), due timers run, process output is looked at."
  (drgnx-test-advance (+ seconds (/ (or millis 0) 1000.0)))
  (funcall drgnx-test--accept nil 0)
  nil)

(defun drgnx-test--sit-for (seconds &optional _nodisp)
  "`sit-for': like `sleep-for', but simulated input ends it early and it then returns nil (else t)."
  (let ((secs (drgnx-test--secs (if (numberp seconds) seconds 0))))
    (cond ((drgnx-test--input-pending-p) nil)
          ((and drgnx-test--input-at (time-less-p drgnx-test--input-at (time-add drgnx-test--now secs)))
           (drgnx-test-advance (time-subtract drgnx-test--input-at drgnx-test--now))
           nil)
          (t (drgnx-test-advance secs)
             (funcall drgnx-test--accept nil 0)
             t))))

(defun drgnx-test--accept-process-output (orig &rest args)
  "`accept-process-output': the real wait, then virtual time moves by the real time it took."
  (let* ((began (drgnx-test-real-time)) (result (apply orig args)))
    (drgnx-test-advance (- (drgnx-test-real-time) began))
    result))

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
            (sleep-for :override drgnx-test--sleep-for)
            (sit-for :override drgnx-test--sit-for)
            (accept-process-output :around drgnx-test--accept-process-output)
            (timer--activate :before drgnx-test-clock--shift))
          (cl-loop for (seam . fn) in drgnx-test--seams
                   when (fboundp seam) collect (list seam :override fn))))

;;;; Time moves

(defun drgnx-test--check-active ()
  (unless drgnx-test--active (error "No virtual clock: use drgnx-test-with-clock")))

(defun drgnx-test--move-to (time)
  "Virtual time becomes TIME if that is later than it is (a wait inside a timer function may have moved it on)."
  (when (time-less-p drgnx-test--now time) (setq drgnx-test--now time)))

(defun drgnx-test-advance (secs)
  "Move virtual time forward SECS seconds, running every wall timer that comes due, in order.
A timer runs by `timer-event-handler' while still on `timer-list' (popping it first makes the handler treat it as
cancelled), and a repeating one runs again each time it is due again within SECS.  More than
`drgnx-test-clock-max-runs' runs is an error."
  (drgnx-test--check-active)
  (let ((target (time-add drgnx-test--now (drgnx-test--secs secs))) (runs 0) timer)
    (while (and (setq timer (cl-find-if-not #'timer--triggered timer-list))
                (not (time-less-p target (drgnx-test--due timer))))
      (when (> (cl-incf runs) drgnx-test-clock-max-runs)
        (error "drgnx-test-advance: more than %d timer runs (a timer re-arms with no delay?)"
               drgnx-test-clock-max-runs))
      (drgnx-test--move-to (drgnx-test--due timer))
      (timer-event-handler timer))
    (drgnx-test--move-to target)
    nil))

(cl-defun drgnx-test-idle (secs &key input-at)
  "One idle pause of SECS seconds, as Emacs's command loop runs it, then back to non-idle.
Every idle timer is a candidate again (`timer_start_idle' clears their triggered flag); each one due and not yet
run in this pause runs in time order, the pause clock moving to its time, a repeating one once.  A one-shot a timer
arms at `(time-add (current-idle-time) D)' runs too when it is due within the pause.  Wall timers due in the pause
run in the same order, virtual time moving with it.  From INPUT-AT seconds into the pause nothing more runs and
`input-pending-p' is t until this returns."
  (drgnx-test--check-active)
  (when drgnx-test--pause (error "drgnx-test-idle: already in a pause"))
  (let* ((start drgnx-test--now) (secs (drgnx-test--secs secs)) (input-at (and input-at (drgnx-test--secs input-at)))
         (end (if (and input-at (time-less-p input-at secs)) input-at secs)) (runs 0) done)
    (dolist (timer timer-idle-list) (setf (timer--triggered timer) nil))
    (setq drgnx-test--pause start
          drgnx-test--input-at (and input-at (time-add start input-at)))
    (unwind-protect
        (while (not done)
          (let* ((idle (cl-find-if-not #'timer--triggered timer-idle-list))
                 (wall (cl-find-if-not #'timer--triggered timer-list))
                 (idle-at (and idle (drgnx-test--secs (float-time (timer--time idle)))))   ; stored truncated to a picosecond
                 (wall-at (and wall (time-subtract (drgnx-test--due wall) start)))
                 (next (cond ((and idle wall) (if (time-less-p wall-at idle-at) wall idle))
                             (t (or idle wall))))
                 (at (and next (if (eq next wall) wall-at idle-at))))
            (cond ((or (null next) (time-less-p secs at)
                       (and input-at (not (time-less-p at input-at))))
                   (setq done t))
                  (t (when (> (cl-incf runs) 1000)
                       (error "Idle timers re-arm themselves at once: a busy loop"))
                     (drgnx-test--move-to (time-add start at))
                     (timer-event-handler next)))))
      (drgnx-test--move-to (time-add start end))
      (setq drgnx-test--pause nil
            drgnx-test--input-at nil))
    nil))

;;;; The fixture

(declare-function drgnx-timer-pending "drgnx-timer" ())
(declare-function drgnx-timer-reset "drgnx-timer" ())

(defun drgnx-test--timer-name (timer)
  "TIMER's function as the failure message names it: the symbol, or `lambda' with its file when that is known."
  (let ((fn (timer--function timer)))
    (if (symbolp fn)
        fn
      (let ((file (ignore-errors (find-lisp-object-file-name fn nil))))
        (if (stringp file) (list 'lambda (file-name-nondirectory file)) 'lambda)))))

(defun drgnx-test--pending-names ()
  "What is still pending, for the failure message: the layer's timers as (KEY OWNER KIND), then raw functions."
  (append (and (fboundp 'drgnx-timer-pending) (ignore-errors (drgnx-timer-pending)))
          (mapcar #'drgnx-test--timer-name (append timer-list timer-idle-list))))

(defun drgnx-test--call-with-clock (body allow-pending)
  "Run BODY (a function) on the virtual clock; see `drgnx-test-with-clock'."
  (when drgnx-test--active (error "drgnx-test-with-clock: already inside one"))
  (let* ((timer-list nil) (timer-idle-list nil)
         (start (time-convert nil t))
         (drgnx-test--active t) (drgnx-test--start start) (drgnx-test--now start)
         (drgnx-test--pause nil) (drgnx-test--input-at nil)
         (drgnx-test--accept (symbol-function 'accept-process-output))
         (layer (fboundp 'drgnx-timer--now))
         (advice (drgnx-test--advice)) names)
    (unwind-protect
        (progn (dolist (a advice) (advice-add (nth 0 a) (nth 1 a) (nth 2 a)))
               (funcall body)
               (when (and (not layer) (fboundp 'drgnx-timer--now))
                 (error "drgnx-timer was loaded inside drgnx-test-with-clock: require it first"))
               (when (and (not allow-pending) (or timer-list timer-idle-list (fboundp 'drgnx-timer-pending)))
                 (setq names (drgnx-test--pending-names))))
      (dolist (a advice) (advice-remove (nth 0 a) (nth 2 a)))
      (mapc #'cancel-timer (append timer-list timer-idle-list))
      (when (fboundp 'drgnx-timer-reset) (ignore-errors (drgnx-timer-reset))))
    (when names
      (ert-fail (list "timers still pending at the end of drgnx-test-with-clock" names)))))

(cl-defmacro drgnx-test-with-clock ((&key allow-pending) &rest body)
  "Run BODY on a virtual clock.
BODY sees fresh `timer-list' and `timer-idle-list'.  `float-time' and `current-time' without an argument return
the real time at entry plus the virtual seconds so far, moved only by `drgnx-test-advance', `drgnx-test-idle',
`sleep-for', `sit-for' and a timed `accept-process-output' (by the real time it waited); due timers run right after.
`current-idle-time' and `input-pending-p' follow `drgnx-test-idle'.  Timers made by `run-at-time' are moved onto the
virtual clock plus `drgnx-test-clock-horizon' when activated, so a real wait never finds one ripe.  At the end a pending
timer fails the test (naming the layer's keys and owners, then raw functions) unless `:allow-pending' is t, and
`drgnx-timer-reset' runs.  Nesting is an error.  If `drgnx-timer--now' is defined at entry, the timer layer's three
seams follow the clock too; load the layer before entering, not inside.

Stays real: `time-since', `(time-subtract nil ...)' and `format-time-string' with no time read the real clock;
tests of code that uses them use real time.  Use: (drgnx-test-with-clock () ...) or
(drgnx-test-with-clock (:allow-pending t) ...)."
  (declare (indent 1))
  `(drgnx-test--call-with-clock (lambda () ,@body) ,allow-pending))

(provide 'clock-fixture)
(provide 'drgnx-clock-fixture)
;;; clock-fixture.el ends here
