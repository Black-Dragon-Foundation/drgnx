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

;;;; Seams: the layer reads time and input only through these (the clock fixture overrides them)

(defun drgnx-timer--now () "Now, in seconds (`float-time')." (float-time))
(defun drgnx-timer--idle-time () "How long Emacs has been idle (`current-idle-time'), or nil." (current-idle-time))
(defun drgnx-timer--input-pending-p () "Non-nil when input is waiting (`input-pending-p')." (input-pending-p))
(defun drgnx-timer-now () "Now, in seconds: the clock layer timers run on (a test's virtual clock in tests)." (drgnx-timer--now))

;;;; Entries, keys and owners

(cl-defstruct (drgnx-timer--entry (:constructor drgnx-timer--make) (:copier nil))
  "One live key: what it runs, for whom, and its Emacs timer."
  key kind          ; start | debounce | soon | poll | steps
  timer chain       ; the Emacs timer; idle steps' re-armed one-shot
  fn args owner token (failures 0)
  secs last         ; debounce: last call time; soon: last run start
  deadline on-timeout budget interruptible on-done
  repeat)           ; start: its REPEAT (nil: a one-shot)

(defvar drgnx-timer--table (make-hash-table :test #'equal)
  "KEY → entry.  KEY: a symbol, or (SYMBOL . OBJECT) for one timer per buffer, process, frame, window, session or root.")

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
        (when (and entry (eq (drgnx-timer--entry-owner entry) buffer)) (drgnx-timer--drop entry))))
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
process, frame or window; anything else signals `wrong-type-argument'.  See docs/develop/core.md, \"Timers\"."
  (drgnx-timer--check key fn)
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
        (when (bufferp (car cell)) (drgnx-timer--watch-buffer (car cell) key))
        key))))

(defun drgnx-timer-cancel (key)
  "Cancel KEY's timer; non-nil when there was one."
  (let ((entry (gethash key drgnx-timer--table)))
    (when entry (drgnx-timer--drop entry) t)))

(defun drgnx-timer-active-p (key)
  "Non-nil while KEY has a timer pending."
  (and (gethash key drgnx-timer--table) t))

(defun drgnx-timer-cancel-owner (owner)
  "Cancel every timer OWNER owns; return how many.  A module symbol matches every run of that module."
  (let ((found nil))
    (maphash (lambda (_key entry) (when (eq (drgnx-timer--entry-owner entry) owner) (push entry found)))
             drgnx-timer--table)
    (dolist (entry found) (drgnx-timer--drop entry))
    (length found)))

(defun drgnx-timer-describe (timer)
  "(:key KEY :owner OWNER :kind KIND :fn FN) for a layer TIMER (an Emacs timer whose function is
`drgnx-timer--fire'), else nil.  OWNER is the module symbol, buffer, process or `:core', without a run token."
  (when (and (timerp timer) (eq (timer--function timer) #'drgnx-timer--fire))
    (let ((entry (car (timer--args timer))))
      (when (drgnx-timer--entry-p entry)
        (list :key (drgnx-timer--entry-key entry) :owner (drgnx-timer--entry-owner entry)
              :kind (drgnx-timer--entry-kind entry) :fn (drgnx-timer--entry-fn entry))))))

(defun drgnx-timer-pending ()
  "The live keys, as (KEY OWNER KIND)."
  (let ((out nil))
    (maphash (lambda (key entry)
               (push (list key (drgnx-timer--entry-owner entry) (drgnx-timer--entry-kind entry)) out))
             drgnx-timer--table)
    (nreverse out)))

(defun drgnx-timer-reset ()
  "Cancel every layer timer and empty the table (tests and the census)."
  (let ((all nil))
    (maphash (lambda (_key entry) (push entry all)) drgnx-timer--table)
    (dolist (entry all) (drgnx-timer--drop entry))
    (clrhash drgnx-timer--table)))

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
        (let ((once (not (drgnx-timer--entry-repeat entry))))
          (when once (remhash key drgnx-timer--table))
          (drgnx-timer--call entry once))))))

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
the failure count; an error goes to `drgnx-timer--failed'.  The debugger opens only with `debug-on-error' and a
frame to show it in (`drgnx-timer--debugger-p'): never in batch or in a daemon with no client."
  (let ((fn (drgnx-timer--entry-fn entry)) (args (drgnx-timer--entry-args entry))
        (owner (drgnx-timer--entry-owner entry))
        (debug-on-error (and debug-on-error (drgnx-timer--debugger-p))))
    (condition-case-unless-debug err
        (progn
          (save-match-data
            (cond ((bufferp owner) (with-current-buffer owner (apply fn args)))
                  ((and record (symbolp owner) (not (eq owner :core)))
                   (drgnx-modules--record-call owner (lambda () (apply fn args))))
                  (t (apply fn args))))
          (setf (drgnx-timer--entry-failures entry) 0))
      (error (drgnx-timer--failed entry err)))))

(defun drgnx-timer--rerun-p (entry)
  "Non-nil if ENTRY would run again: a repeating timer, a poll or idle steps."
  (or (drgnx-timer--entry-repeat entry) (memq (drgnx-timer--entry-kind entry) '(poll steps))))

(defun drgnx-timer--failed (entry err)
  "Record ERR, raised by ENTRY's FN, in `drgnx-timer-errors' and say it once with `message'.
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
    (message "drgnx: timer %S failed: %s" key msg)
    (when stop
      (drgnx-timer--drop entry)
      (drgnx-timer--write-report))))

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
      (when (fboundp 'drgnx-state-dir)
        (let ((file (expand-file-name drgnx-timer-report-file (drgnx-state-dir)))
              (stopped nil) (inhibit-interaction t) (coding-system-for-write 'utf-8-unix))
          (dolist (e drgnx-timer-errors)
            (when (plist-get e :stopped) (push (drgnx-timer--printable e) stopped)))
          (make-directory (file-name-directory file) t)
          (with-temp-file file
            (let ((print-length nil) (print-level nil))
              (prin1 (list :stopped (nreverse stopped)) (current-buffer))
              (insert "\n")))))
    (error nil)))

(provide 'drgnx-timer)
;;; drgnx-timer.el ends here
