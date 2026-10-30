;;; drgnx-timer.el --- Keyed, owned timers with a named function: one door for every timer -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A timer that outlives the current command goes through this layer.  It has a KEY: a second start replaces the
;; first, so a setup run twice keeps one timer.  It has an OWNER (a module run, a buffer, a process or `:core'):
;; its function is never called once the owner is gone.  Its function is named.  Every layer timer's Emacs function
;; is `drgnx-timer--fire', which checks the key and the owner, catches every error, and stops a timer that would
;; run again after `drgnx-timer-failure-limit' failures in a row (recorded in `drgnx-timer-errors' and written for
;; the doctor).  The layer reads time and input only through three seams, which the test clock fixture drives.
;; Nothing here prompts.  See docs/develop/core.md, "Timers".

;;; Code:
(eval-when-compile (require 'cl-lib))
(require 'timer)
(require 'drgnx-modules-record)

(declare-function drgnx-state-dir "drgnx-paths")
(declare-function drgnx-file-write "drgnx-file")

;;;; Seams: the layer reads time and input only through these (the clock fixture overrides them)

(defun drgnx-timer--now () "Now, in seconds (`float-time')." (float-time))
(defun drgnx-timer--idle-time () "How long Emacs has been idle (`current-idle-time'), or nil." (current-idle-time))
(defun drgnx-timer--input-pending-p () "Non-nil when input is waiting (`input-pending-p')." (input-pending-p))
(defun drgnx-timer-now () "Now, in seconds: the clock layer timers run on (a test's virtual clock in tests)." (drgnx-timer--now))

(defvar drgnx-timer-chain-yield 0.016
  "Seconds a zero-delay chain waits before its next link while input is pending (`drgnx-timer-chain-delay').")

(defun drgnx-timer-chain-delay ()
  "The delay of a zero-delay chain's next link: 0, or `drgnx-timer-chain-yield' while input is pending.
Emacs's wait for input runs ripe timers back to back and leaves them only for keyboard input, so a chain re-armed
at 0 starves input queued on `unread-command-events' (a re-read key, a harness's typing) until the chain ends.
Waiting one link lets that wait return: the command loop reads the input first.  See docs/develop/core.md, \"Timers\"."
  (if (drgnx-timer--input-pending-p) drgnx-timer-chain-yield 0))

;;;; Entries, keys and owners

(cl-defstruct (drgnx-timer--entry (:constructor drgnx-timer--make) (:copier nil))
  "One live key: what it runs, for whom, and its Emacs timer."
  key kind          ; start | debounce | soon | poll | steps
  timer chain       ; the Emacs timer; idle steps' re-armed one-shot
  fn args owner token (failures 0)
  secs last         ; debounce: its SECS and the last call's time (nil: an idle debounce); poll: its INTERVAL and start time
  min-interval      ; soon: its :min-interval, or nil
  deadline on-timeout budget interruptible on-done
  repeat)           ; start: its REPEAT (nil: a one-shot)

(defvar drgnx-timer--table (make-hash-table :test #'equal)
  "KEY → entry.  KEY: a symbol, or (SYMBOL . OBJECT) for one timer per buffer, process, frame, window, session or root.")

(defvar drgnx-timer--last-run (make-hash-table :test #'equal)
  "KEY → (TIME . OWNER): when KEY's last `drgnx-timer-soon' run with a :min-interval began.
Kept only for such keys, and removed by `drgnx-timer-cancel', `drgnx-timer-cancel-owner' (a module's run end calls
it; a process owner's sentinel must), `drgnx-timer-reset', and the killing of the buffer that owns the key or is
its OBJECT, `(SYMBOL . BUFFER)'.  A key whose OBJECT is another process, frame or window, under a `:core' or module
owner, keeps its entry until one of those.")

(defvar-local drgnx-timer--buffer-keys nil
  "Keys whose timers this buffer may own; `drgnx-timer--buffer-killed' cancels those it still owns.")
(put 'drgnx-timer--buffer-keys 'permanent-local t)

(defcustom drgnx-timer-failure-limit 3
  "A timer that would run again (repeating, a poll, idle steps) stops after this many failures in a row."
  :type 'natnum :group 'drgnx)

(defvar drgnx-timer-errors nil
  "Errors of layer timers, newest first, at most 50: plists (:key :owner :fn :error :failures :stopped :time).
:owner has no run token, :error is the message, :failures the count in a row, :stopped t when this failure stopped
the timer, :time `drgnx-timer-now'.")

(defvar drgnx-timer-report-file "timers-report.eld"
  "The file in `drgnx-state-dir' that the stopped timers are written to; the doctor's `timers' check reads it.")

(defun drgnx-timer--key-p (key)
  "Non-nil if KEY is a non-nil symbol, or (SYMBOL . OBJECT) with OBJECT a symbol, number, string, buffer, process,
frame or window.  Keys are compared with `equal': a struct or a list would hash by contents that change."
  (if (consp key)
      (let ((o (cdr key)))
        (and (car key) (symbolp (car key))
             (or (symbolp o) (numberp o) (stringp o) (bufferp o) (processp o) (framep o) (windowp o))))
    (and key (symbolp key))))

(defun drgnx-timer--check (key fn)
  "Signal `wrong-type-argument' unless FN is a named function (a non-nil symbol) and KEY a key (`drgnx-timer--key-p')."
  (unless (and fn (symbolp fn)) (signal 'wrong-type-argument (list 'symbolp fn)))
  (unless (drgnx-timer--key-p key) (signal 'wrong-type-argument (list 'drgnx-timer--key-p key))))

(defun drgnx-timer--owner (owner)
  "OWNER resolved to (OWNER . TOKEN), or `:gone' when it is gone already.
nil: the module whose setup (or `drgnx-modules-with-owner' code) runs now, with its run token, else `:core'.  A
module symbol: its current run token, `:gone' when it has no run.  A buffer or a process: itself while live.
`:core': lives as long as Emacs.  Anything else signals `wrong-type-argument'."
  (cond ((null owner) (or (drgnx-modules--owner) (list :core)))
        ((eq owner :core) (list :core))
        ((bufferp owner) (if (buffer-live-p owner) (list owner) :gone))
        ((processp owner) (if (process-live-p owner) (list owner) :gone))
        ((and (symbolp owner) (not (keywordp owner)))
         (let ((token (alist-get owner drgnx-modules--runs))) (if token (cons owner token) :gone)))
        (t (signal 'wrong-type-argument (list 'drgnx-timer--owner owner)))))

(defun drgnx-timer--live-p (entry)
  "Non-nil while ENTRY's owner is there: a live buffer or process, a module run whose token is still current, `:core'."
  (let ((owner (drgnx-timer--entry-owner entry)))
    (cond ((eq owner :core) t)
          ((bufferp owner) (buffer-live-p owner))
          ((processp owner) (process-live-p owner))
          (t (eq (drgnx-timer--entry-token entry) (alist-get owner drgnx-modules--runs))))))

(defun drgnx-timer--drop (entry)
  "Cancel ENTRY's timers and take it out of the table, if it is still its key's entry."
  (let ((timer (drgnx-timer--entry-timer entry)) (chain (drgnx-timer--entry-chain entry))
        (key (drgnx-timer--entry-key entry)))
    (when timer (cancel-timer timer))
    (when chain (cancel-timer chain))
    (when (eq (gethash key drgnx-timer--table) entry) (remhash key drgnx-timer--table))))

(defun drgnx-timer--buffer-killed ()
  "On a buffer's own `kill-buffer-hook': cancel the timers it still owns."
  (let ((buffer (current-buffer)))
    (dolist (key drgnx-timer--buffer-keys)
      (let ((entry (gethash key drgnx-timer--table)))
        (when (and entry (eq (drgnx-timer--entry-owner entry) buffer)) (drgnx-timer--drop entry)))
      (when (or (eq (cdr (gethash key drgnx-timer--last-run)) buffer) (eq (cdr-safe key) buffer))
        (remhash key drgnx-timer--last-run)))
    (setq drgnx-timer--buffer-keys nil)))
(put 'drgnx-timer--buffer-killed 'permanent-local-hook t)

(defun drgnx-timer--watch-buffer (buffer key)
  "Note KEY on BUFFER's key list; its first key adds `drgnx-timer--buffer-killed' to its own `kill-buffer-hook'."
  (with-current-buffer buffer
    (unless drgnx-timer--buffer-keys (add-hook 'kill-buffer-hook #'drgnx-timer--buffer-killed nil t))
    (unless (member key drgnx-timer--buffer-keys) (push key drgnx-timer--buffer-keys))))

;;;; The API

(cl-defun drgnx-timer-start (key secs fn &key repeat idle args owner)
  "Call FN with ARGS after SECS seconds, or after SECS seconds of idleness when IDLE; return KEY.
REPEAT: for a wall timer, run again every REPEAT seconds (as `run-at-time'); for an idle timer, non-nil runs it once
in every pause.  KEY's pending timer, whatever started it, is cancelled first: one timer per key.
OWNER: nil (the module whose setup or `drgnx-modules-with-owner' code runs now, else `:core'), a module symbol, a
buffer, a process or `:core'.  FN is never called once its owner is gone; when the owner is gone already nothing
starts and this returns nil.  A one-shot owned by a module runs as the module's code (what it changes is undone
when the module is turned off).
FN must be a non-nil symbol, and KEY a symbol or (SYMBOL . OBJECT) with OBJECT a symbol, number, string, buffer,
process, frame or window; anything else signals `wrong-type-argument', as does a wall timer's REPEAT that is not a
number (Emacs refuses it).  See docs/develop/core.md, \"Timers\"."
  (drgnx-timer--check key fn)
  (unless (or idle (null repeat) (numberp repeat)) (signal 'wrong-type-argument (list 'numberp repeat)))
  (let ((cell (drgnx-timer--owner owner)))
    (unless (eq cell :gone)
      (drgnx-timer-cancel key)
      (let ((entry (drgnx-timer--make :key key :kind 'start :fn fn :args args :owner (car cell) :token (cdr cell)
                                      :secs secs :repeat repeat)))
        (setf (drgnx-timer--entry-timer entry)
              (if idle
                  (run-with-idle-timer secs repeat #'drgnx-timer--fire entry)
                (run-at-time secs repeat #'drgnx-timer--fire entry)))
        (puthash key entry drgnx-timer--table)
        (drgnx-timer--restarted key)
        (when (bufferp (car cell)) (drgnx-timer--watch-buffer (car cell) key))
        key))))

(defun drgnx-timer-cancel (key)
  "Cancel KEY's timer, and forget when it last ran; non-nil when there was a timer."
  (remhash key drgnx-timer--last-run)
  (let ((entry (gethash key drgnx-timer--table)))
    (when entry (drgnx-timer--drop entry) t)))

(defun drgnx-timer-active-p (key)
  "Non-nil while KEY has a timer pending."
  (and (gethash key drgnx-timer--table) t))

(defun drgnx-timer-cancel-owner (owner)
  "Cancel every timer OWNER owns; return how many.  A module symbol matches every run of that module."
  (let ((found nil) (ran nil))
    (maphash (lambda (_key entry) (when (eq (drgnx-timer--entry-owner entry) owner) (push entry found)))
             drgnx-timer--table)
    (maphash (lambda (key last) (when (eq (cdr last) owner) (push key ran))) drgnx-timer--last-run)
    (dolist (entry found) (drgnx-timer--drop entry))
    (dolist (key ran) (remhash key drgnx-timer--last-run))
    (length found)))

(defun drgnx-timer-describe (timer)
  "(:key KEY :owner OWNER :kind KIND :fn FN) for a layer TIMER (an Emacs timer whose function is
`drgnx-timer--fire'), else nil.  OWNER is the module symbol, buffer, process or `:core', without a run token."
  (when (and (timerp timer) (eq (timer--function timer) #'drgnx-timer--fire))
    (let ((entry (car (timer--args timer))))
      (when (drgnx-timer--entry-p entry)
        (list :key (drgnx-timer--entry-key entry) :owner (drgnx-timer--entry-owner entry)
              :kind (drgnx-timer--entry-kind entry) :fn (drgnx-timer--entry-fn entry))))))

(defun drgnx-timer-fn (timer)
  "The function a layer TIMER runs (what `drgnx-timer-describe' gives as :fn), else nil.  Cheap: no plist."
  (when (and (timerp timer) (eq (timer--function timer) #'drgnx-timer--fire))
    (let ((entry (car (timer--args timer))))
      (when (drgnx-timer--entry-p entry) (drgnx-timer--entry-fn entry)))))

(defun drgnx-timer-pending ()
  "The live keys, as (KEY OWNER KIND)."
  (let ((out nil))
    (maphash (lambda (key entry)
               (push (list key (drgnx-timer--entry-owner entry) (drgnx-timer--entry-kind entry)) out))
             drgnx-timer--table)
    (nreverse out)))

(defun drgnx-timer-reset ()
  "Cancel every layer timer and empty the table (tests and the census).
An entry that cannot be cancelled (its timer is a test's stub, not a timer) never stops the rest."
  (let ((all nil))
    (maphash (lambda (_key entry) (push entry all)) drgnx-timer--table)
    (dolist (entry all) (ignore-errors (drgnx-timer--drop entry)))
    (clrhash drgnx-timer--table)
    (clrhash drgnx-timer--last-run)))

;;;; The fire wrapper

(defun drgnx-timer--fire (entry)
  "Run ENTRY: the function of every layer timer (so `list-timers' shows one function, and the key names it).
In order: a timer whose key holds another entry now (replaced, or cancelled while it was ripe) does nothing; an
owner that is gone drops the entry without calling FN; a one-shot leaves the table before FN runs, so FN may start
its key again; then FN runs (`drgnx-timer--call')."
  (let ((key (drgnx-timer--entry-key entry)))
    (when (eq (gethash key drgnx-timer--table) entry)
      (if (not (drgnx-timer--live-p entry))
          (drgnx-timer--drop entry)
        (let ((kind (drgnx-timer--entry-kind entry)))
          (cond ((eq kind 'debounce) (drgnx-timer--fire-debounce entry))
                ((eq kind 'soon) (drgnx-timer--fire-soon entry))
                ((eq kind 'poll) (drgnx-timer--fire-poll entry))
                ((eq kind 'steps) (drgnx-timer--fire-steps entry))
                (t (let ((once (not (drgnx-timer--entry-repeat entry))))
                     (when once (remhash key drgnx-timer--table))
                     (drgnx-timer--call entry once)))))))))

(defun drgnx-timer--debugger-p ()
  "Non-nil when the debugger could show itself: not batch, and some frame is on a real terminal (a daemon with no
client has only the initial one)."
  (and (not noninteractive)
       (let ((frames (frame-list)) (found nil))
         (while (and frames (not found))
           (unless (equal (terminal-name (frame-terminal (car frames))) "initial_terminal") (setq found t))
           (setq frames (cdr frames)))
         found)))

(defun drgnx-timer--call (entry record)
  "Call ENTRY's FN with its ARGS, in `save-match-data', a buffer owner current; catch every error.
RECORD non-nil and a module owner: FN runs as the module's code (`drgnx-modules--record-call').  A success resets
the failure count and returns FN's value; an error goes to `drgnx-timer--failed' (the entry's failure count is then
above 0) and the value is nil.  The debugger opens only with `debug-on-error' and a frame to show it in
\(`drgnx-timer--debugger-p'): never in batch or in a daemon with no client."
  (let ((fn (drgnx-timer--entry-fn entry)) (args (drgnx-timer--entry-args entry))
        (owner (drgnx-timer--entry-owner entry))
        (debug-on-error (and debug-on-error (drgnx-timer--debugger-p))))
    (condition-case-unless-debug err
        (prog1
            (save-match-data
              (cond ((bufferp owner) (with-current-buffer owner (apply fn args)))
                    ((and record (symbolp owner) (not (eq owner :core)))
                     (drgnx-modules--record-call owner (lambda () (apply fn args))))
                    (t (apply fn args))))
          (setf (drgnx-timer--entry-failures entry) 0))
      (error (drgnx-timer--failed entry err) nil))))

(defun drgnx-timer--rerun-p (entry)
  "Non-nil if ENTRY would run again: a repeating timer, a poll or idle steps."
  (or (drgnx-timer--entry-repeat entry) (memq (drgnx-timer--entry-kind entry) '(poll steps))))

(defun drgnx-timer--failed (entry err)
  "Record ERR, raised by ENTRY's FN, in `drgnx-timer-errors' and as a notice (`drgnx-timer--notify').
At its `drgnx-timer-failure-limit'-th failure in a row an ENTRY that would run again is cancelled, marked
`:stopped', and the report file rewritten (`drgnx-timer--write-report')."
  (let* ((n (1+ (drgnx-timer--entry-failures entry)))
         (stop (and (drgnx-timer--rerun-p entry) (>= n drgnx-timer-failure-limit) t))
         (key (drgnx-timer--entry-key entry))
         (msg (error-message-string err)))
    (setf (drgnx-timer--entry-failures entry) n)
    (push (list :key key :owner (drgnx-timer--entry-owner entry) :fn (drgnx-timer--entry-fn entry)
                :error msg :failures n :stopped stop :time (drgnx-timer--now))
          drgnx-timer-errors)
    (let ((tail (nthcdr 49 drgnx-timer-errors))) (when tail (setcdr tail nil)))
    (when stop
      (drgnx-timer--drop entry)
      (drgnx-timer--write-report))
    (drgnx-timer--notify entry n msg stop)))

(declare-function drgnx-notify "drgnx-notice" (source severity text &rest args))
(declare-function drgnx-notice-clear "drgnx-notice" (source &optional id))

(defun drgnx-timer--notify (entry n msg stop)
  "Post ENTRY's failure (MSG) to source `timers': a `warn' event with id (failed . KEY), so a timer that fails again
and again (a debounce after every pause in typing) only counts; when STOP, ENTRY stopped after N failures: a `warn'
condition with id KEY.  The model needs this layer, so it loads at the first failure.  Never signals."
  (let ((key (drgnx-timer--entry-key entry)) (fn (drgnx-timer--entry-fn entry)))
    (condition-case failed
        (progn
          (require 'drgnx-notice)
          (if stop
              (drgnx-notify 'timers 'warn (format "timer %S (%s) stopped after %d failures: %s" key fn n msg)
                            :id key :life 'condition
                            :fix "report the error; drgnx starts the timer again at the next start")
            (drgnx-notify 'timers 'warn (format "timer %S (%s) failed: %s" key fn msg) :id (cons 'failed key))))
      (error (message "drgnx: timer %S failed%s: %s (not recorded: %s)" key (if stop ", stopped" "") msg
                      (error-message-string failed))))))

(defun drgnx-timer--restarted (key)
  "KEY starts again: its \"stopped\" notice, if any, goes (nothing when the model is not loaded)."
  (when (featurep 'drgnx-notice) (drgnx-notice-clear 'timers key)))

;;;; The primitives: debounce, soon, poll, idle steps

(defcustom drgnx-timer-step-budget 0.008
  "Seconds one firing of `drgnx-timer-idle-steps' may spend on steps before it hands the rest to its chain."
  :type 'number :group 'drgnx)

(defconst drgnx-timer--slack 0.001
  "Seconds a clock comparison forgives: a timer fires on a millisecond-rounded time, and the clock is a float.")

(defun drgnx-timer--check-named (fn)
  "Signal `wrong-type-argument' unless FN is nil or a symbol (a hook function is named like a timer's)."
  (unless (symbolp fn) (signal 'wrong-type-argument (list 'symbolp fn))))

(defun drgnx-timer--install (entry cell)
  "Put ENTRY, whose owner resolved to CELL, in the table under its key; a buffer owner notes the key."
  (puthash (drgnx-timer--entry-key entry) entry drgnx-timer--table)
  (drgnx-timer--restarted (drgnx-timer--entry-key entry))
  (when (bufferp (car cell)) (drgnx-timer--watch-buffer (car cell) (drgnx-timer--entry-key entry))))

(defun drgnx-timer--call-final (entry fn)
  "Call FN (an ON-TIMEOUT or ON-DONE function, or nil) once with ENTRY's args, in ENTRY's
owner's buffer if it is one; not recorded as the module's code (the primitives' firings never install the net).
An error is recorded like any other (`drgnx-timer--failed'); it stops nothing."
  (when fn
    (drgnx-timer--call (drgnx-timer--make :key (drgnx-timer--entry-key entry) :kind 'start :fn fn
                                          :args (drgnx-timer--entry-args entry)
                                          :owner (drgnx-timer--entry-owner entry)
                                          :token (drgnx-timer--entry-token entry))
                       nil)))

;;;; Debounce

(cl-defun drgnx-timer-debounce (key secs fn &key args idle owner)
  "Call FN with the last call's ARGS once SECS pass with no further call of this; return KEY.
A call while KEY's debounce is pending only stores ARGS (and, for a wall debounce, the time): it makes no timer and
does not look at OWNER again.  A wall timer that fires before SECS have passed since the last call waits the
remainder.  IDLE: SECS of idleness instead, one idle timer armed once (input resets idleness, so calls only store
ARGS and nothing reads the clock).  A call on a key that holds another kind of timer replaces it; SECS and IDLE
are those of the call that armed the debounce.  OWNER, FN and KEY as in `drgnx-timer-start'; nil when OWNER is gone.
See docs/develop/core.md, \"Timers\"."
  (let ((entry (gethash key drgnx-timer--table)))
    (if (and entry (eq (drgnx-timer--entry-kind entry) 'debounce)
             (eq (null (drgnx-timer--entry-last entry)) (and idle t)))
        (progn (setf (drgnx-timer--entry-args entry) args)
               (unless idle (setf (drgnx-timer--entry-last entry) (drgnx-timer--now)))
               key)
      (drgnx-timer--check key fn)
      (let ((cell (drgnx-timer--owner owner)))
        (unless (eq cell :gone)
          (when entry (drgnx-timer--drop entry))
          (let ((new (drgnx-timer--make :key key :kind 'debounce :fn fn :args args :owner (car cell)
                                        :token (cdr cell) :secs secs :last (unless idle (drgnx-timer--now)))))
            (setf (drgnx-timer--entry-timer new)
                  (if idle
                      (run-with-idle-timer secs nil #'drgnx-timer--fire new)
                    (run-at-time secs nil #'drgnx-timer--fire new)))
            (drgnx-timer--install new cell)
            key))))))

(defun drgnx-timer--fire-debounce (entry)
  "ENTRY's timer is due: a wall debounce called since waits the remainder (a new timer, from a delay); else FN runs."
  (let* ((last (drgnx-timer--entry-last entry))
         (left (and last (min (drgnx-timer--entry-secs entry)       ; a clock that stepped back never stretches the wait
                              (- (drgnx-timer--entry-secs entry) (- (drgnx-timer--now) last))))))
    (if (and left (> left drgnx-timer--slack))
        (setf (drgnx-timer--entry-timer entry) (run-at-time left nil #'drgnx-timer--fire entry))
      (remhash (drgnx-timer--entry-key entry) drgnx-timer--table)
      (drgnx-timer--call entry nil))))

;;;; Soon

(cl-defun drgnx-timer-soon (key secs fn &key args idle min-interval owner)
  "Call FN with ARGS once, SECS after the first call of a burst; return KEY.
A call while KEY is pending does nothing (its ARGS are the first call's).  MIN-INTERVAL: the delay is
max(SECS, LAST + MIN-INTERVAL - now), LAST being when KEY's previous run began (a throttle).  IDLE: SECS of
idleness.  A call on a key that holds another kind of timer replaces it.  OWNER, FN and KEY as in
`drgnx-timer-start'; nil when OWNER is gone.  See docs/develop/core.md, \"Timers\"."
  (let ((entry (gethash key drgnx-timer--table)))
    (if (and entry (eq (drgnx-timer--entry-kind entry) 'soon))
        key
      (drgnx-timer--check key fn)
      (let ((cell (drgnx-timer--owner owner)))
        (unless (eq cell :gone)
          (when entry (drgnx-timer--drop entry))
          (let* ((delay (if min-interval (drgnx-timer--soon-delay key secs min-interval (car cell)) secs))
                 (new (drgnx-timer--make :key key :kind 'soon :fn fn :args args :owner (car cell)
                                         :token (cdr cell) :min-interval min-interval)))
            (setf (drgnx-timer--entry-timer new)
                  (if idle
                      (run-with-idle-timer delay nil #'drgnx-timer--fire new)
                    (run-at-time delay nil #'drgnx-timer--fire new)))
            (drgnx-timer--install new cell)
            (when (and min-interval (consp key) (bufferp (cdr key)) (buffer-live-p (cdr key)))
              (drgnx-timer--watch-buffer (cdr key) key))   ; the buffer's death prunes the key's last-run entry
            key))))))

(defun drgnx-timer--soon-delay (key secs min-interval owner)
  "SECS, or longer so that KEY runs MIN-INTERVAL after its last run, if OWNER ran it."
  (let ((last (gethash key drgnx-timer--last-run)))
    (if (and last (eq (cdr last) owner))
        (max secs (min min-interval (- (+ (car last) min-interval) (drgnx-timer--now))))   ; a clock step back: <= MIN
      secs)))

(defun drgnx-timer--fire-soon (entry)
  "ENTRY's timer is due: note when this run began (with a MIN-INTERVAL), leave the table, run FN."
  (let ((key (drgnx-timer--entry-key entry)))
    (remhash key drgnx-timer--table)
    (when (drgnx-timer--entry-min-interval entry)
      (let ((last (gethash key drgnx-timer--last-run)))
        (if last
            (setf (car last) (drgnx-timer--now) (cdr last) (drgnx-timer--entry-owner entry))
          (puthash key (cons (drgnx-timer--now) (drgnx-timer--entry-owner entry)) drgnx-timer--last-run))))
    (drgnx-timer--call entry nil)))

;;;; Poll

(cl-defun drgnx-timer-poll (key interval fn &key deadline on-timeout args owner)
  "Call FN with ARGS every INTERVAL seconds until it returns non-nil; return KEY.
DEADLINE, required, is a positive number of seconds from this call: at the first firing at or past it,
ON-TIMEOUT (a named function, or nil) is called with ARGS instead of FN and the poll ends.  A poll whose owner goes
ends with no ON-TIMEOUT; one stopped by `drgnx-timer-failure-limit' calls it once.  Without a DEADLINE this signals
\(wrong-type-argument numberp DEADLINE) at once.  OWNER, FN and KEY as in `drgnx-timer-start'; nil when OWNER is
gone.  See docs/develop/core.md, \"Timers\"."
  (unless (and (numberp deadline) (> deadline 0)) (signal 'wrong-type-argument (list 'numberp deadline)))
  (drgnx-timer--check key fn)
  (drgnx-timer--check-named on-timeout)
  (let ((cell (drgnx-timer--owner owner)))
    (unless (eq cell :gone)
      (let ((old (gethash key drgnx-timer--table)))
        (when old (drgnx-timer--drop old)))
      (let ((new (drgnx-timer--make :key key :kind 'poll :fn fn :args args :owner (car cell) :token (cdr cell)
                                    :secs interval :repeat interval :last (drgnx-timer--now)
                                    :deadline deadline :on-timeout on-timeout)))
        (setf (drgnx-timer--entry-timer new) (run-at-time interval interval #'drgnx-timer--fire new))
        (drgnx-timer--install new cell)
        key))))

(defun drgnx-timer--fire-poll (entry)
  "ENTRY's poll is due: past its deadline ON-TIMEOUT replaces FN and ends it; else FN runs, and non-nil ends it."
  (if (>= (+ (- (drgnx-timer--now) (drgnx-timer--entry-last entry)) drgnx-timer--slack)
          (drgnx-timer--entry-deadline entry))
      (progn (drgnx-timer--drop entry)
             (drgnx-timer--call-final entry (drgnx-timer--entry-on-timeout entry)))
    (let ((done (drgnx-timer--call entry nil))
          (failures (drgnx-timer--entry-failures entry)))
      (cond ((>= failures (max 1 drgnx-timer-failure-limit))     ; the failure limit stopped it just now
             (drgnx-timer--call-final entry (drgnx-timer--entry-on-timeout entry)))
            ((not (eq (gethash (drgnx-timer--entry-key entry) drgnx-timer--table) entry)))   ; FN cancelled it
            (done (drgnx-timer--drop entry))))))

;;;; Idle steps

(cl-defun drgnx-timer-idle-steps (key secs step &key args budget interruptible owner on-done)
  "Call STEP with ARGS in idle time until it returns nil, then ON-DONE (with ARGS); return KEY.
A repeating idle timer at SECS (the pause starter) calls STEP at least once per pause, and again while STEP returned
non-nil, no input is pending and BUDGET seconds (default `drgnx-timer-step-budget') are not spent.  A firing that
leaves work and saw no input arms a one-shot idle timer SECS further into the same pause (the chain), so the steps
finish within one pause.  Input pending ends the firing and cancels the chain; the starter resumes SECS into the
next pause.  INTERRUPTIBLE: each step runs in `while-no-input'; an aborted step counts as input and runs again in
the next pause.  A step that signals ends its firing (no chain); `drgnx-timer-failure-limit' of those in a row stop
it.  OWNER, STEP and KEY as in `drgnx-timer-start'; nil when OWNER is gone.  See docs/develop/core.md, \"Timers\"."
  (drgnx-timer--check key step)
  (drgnx-timer--check-named on-done)
  (let ((cell (drgnx-timer--owner owner)))
    (unless (eq cell :gone)
      (let ((old (gethash key drgnx-timer--table)))
        (when old (drgnx-timer--drop old)))
      (let ((new (drgnx-timer--make :key key :kind 'steps :fn step :args args :owner (car cell) :token (cdr cell)
                                    :secs secs :repeat t :budget budget :interruptible interruptible
                                    :on-done on-done)))
        (setf (drgnx-timer--entry-timer new) (run-with-idle-timer secs t #'drgnx-timer--fire new))
        (drgnx-timer--install new cell)
        key))))

(defun drgnx-timer--step (entry)
  "Run ENTRY's STEP once: (VALUE), or t when `while-no-input' aborted it (or input was pending)."
  (if (drgnx-timer--entry-interruptible entry)
      (while-no-input (list (drgnx-timer--call entry nil)))
    (list (drgnx-timer--call entry nil))))

(defun drgnx-timer--fire-steps (entry)
  "One firing of ENTRY's idle steps, from the starter or the chain.
A chain still pending is stale (input came before it ran): it is cancelled first.  The loop ends when STEP is
done (the entry is dropped, ON-DONE runs), when input is pending (no chain), or when the budget is spent with work
left (the chain is armed SECS after the idle time now)."
  (let ((chain (drgnx-timer--entry-chain entry)))
    (when chain
      (cancel-timer chain)
      (setf (drgnx-timer--entry-chain entry) nil)))
  (let ((start (drgnx-timer--now))
        (budget (or (drgnx-timer--entry-budget entry) drgnx-timer-step-budget))
        (key (drgnx-timer--entry-key entry))
        (state nil))
    (while (null state)
      (let ((result (drgnx-timer--step entry)))
        (cond ((eq result t) (setq state 'input))
              ((not (eq (gethash key drgnx-timer--table) entry)) (setq state 'gone))
              ((> (drgnx-timer--entry-failures entry) 0) (setq state 'failed))
              ((null (car result)) (setq state 'done))
              ((drgnx-timer--input-pending-p) (setq state 'input))
              ((>= (- (drgnx-timer--now) start) budget) (setq state 'more)))))
    (cond ((eq state 'done)
           (drgnx-timer--drop entry)
           (drgnx-timer--call-final entry (drgnx-timer--entry-on-done entry)))
          ((eq state 'more)
           (setf (drgnx-timer--entry-chain entry)
                 (run-with-idle-timer (time-add (or (drgnx-timer--idle-time) 0) (drgnx-timer--entry-secs entry))
                                      nil #'drgnx-timer--fire entry))))))

;;;; The report the doctor reads

(defun drgnx-timer--printable (x)
  "X with each buffer, process, frame or window in it replaced by its printed form, so that `read' takes it back."
  (cond ((consp x) (cons (drgnx-timer--printable (car x)) (drgnx-timer--printable (cdr x))))
        ((or (symbolp x) (numberp x) (stringp x)) x)
        (t (format "%S" x))))

(defun drgnx-timer--write-report ()
  "Write the stopped timers of `drgnx-timer-errors', (:stopped (PLIST…)) newest first, to `drgnx-timer-report-file'
in the state dir.  Never prompts and never raises: a write that fails is skipped."
  (condition-case nil
      (when (and (fboundp 'drgnx-state-dir) (require 'drgnx-file nil t))
        (let ((file (expand-file-name drgnx-timer-report-file (drgnx-state-dir)))
              (stopped nil) (inhibit-interaction t))
          (dolist (e drgnx-timer-errors)
            (when (plist-get e :stopped) (push (drgnx-timer--printable e) stopped)))
          (drgnx-file-write file (list :stopped (nreverse stopped)) :fsync nil)))
    (error nil)))

;;;; A run's end

(add-hook 'drgnx-modules-run-end-functions #'drgnx-timer-cancel-owner)   ; a module off: its timers go with its run

(provide 'drgnx-timer)
;;; drgnx-timer.el ends here
