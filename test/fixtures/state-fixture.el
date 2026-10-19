;;; state-fixture.el --- for tests: a fresh workbench state store and bus, restored by value -*- lexical-binding: t -*-
(require 'drgnx-signal)                 ; the bus, and the store it reads

(defvar drgnx-state-test--variables
  '((drgnx-state--frames . (make-hash-table :test 'eq :weakness 'key))
    (drgnx-state--order . nil)
    (drgnx-state--roles . (copy-sequence drgnx-state--roles)) ; the roles defined so far (built-ins, loaded code)
    (drgnx-state--in-command . nil)
    (drgnx-state-mode . nil)
    (drgnx-state--now . nil)                                   ; Task 5: subscribers, idle calls, selection
    (drgnx-state--idle . nil)
    (drgnx-state--queue . nil)
    (drgnx-state--selected-frame . nil)
    (drgnx-state--watching . nil)
    (drgnx-signal--subscribers . nil)
    (drgnx-signal--state . nil)
    (drgnx-signal--posted . nil)
    (drgnx-signal--timer . nil)                                ; Task 10: the one idle flush, store and bus
    (drgnx-signal--editor . nil)
    (drgnx-signal--switched . nil)
    (drgnx-signal-errors . nil))
  "Alist VARIABLE → FORM: the store and bus state `drgnx-test-with-state' saves by value and sets to FORM's
value for its body (only the variables that are bound).  Each task that adds store or bus state adds it here.")

(defvar drgnx-state-test--timers '(drgnx-signal--timer)
  "Variables of `drgnx-state-test--variables' that hold a timer: cancelled on the way in and out, and nil
afterwards (a cancelled timer left in the variable would keep the bus from arming a new one).")

(defun drgnx-state-test--cancel-timers ()
  (dolist (v drgnx-state-test--timers)
    (when (and (boundp v) (timerp (symbol-value v))) (cancel-timer (symbol-value v)))))

(defun drgnx-state-test--call (fn)
  "Call FN with a fresh store and bus, the store's hooks off; restore everything by value (`set') after."
  (let ((on (bound-and-true-p drgnx-state-mode))
        (saved (let (acc)
                 (dolist (entry drgnx-state-test--variables (nreverse acc))
                   (when (boundp (car entry)) (push (cons (car entry) (symbol-value (car entry))) acc))))))
    (drgnx-state-test--cancel-timers)
    (unwind-protect
        (progn
          (drgnx-state--install nil)
          (dolist (entry drgnx-state-test--variables)
            (when (boundp (car entry)) (set (car entry) (eval (cdr entry) t))))
          (funcall fn))
      (drgnx-state-test--cancel-timers)
      (drgnx-state--install nil)        ; BODY may have turned the mode on
      (pcase-dolist (`(,var . ,value) saved)
        (set var (if (memq var drgnx-state-test--timers) nil value)))
      (when on (drgnx-state--install t)))))

(defmacro drgnx-test-with-state (&rest body)
  "Run BODY with a fresh workbench state store and bus, and the store's hooks off (call `drgnx-state-sync').
Every bound variable of `drgnx-state-test--variables' is saved by value and restored with `set' afterwards,
never `let' (a function BODY calls that sets one globally must not leak past the test)."
  (declare (indent 0) (debug t))
  `(drgnx-state-test--call (lambda () ,@body)))

(defun drgnx-test-use-editor (window)
  "Make WINDOW its frame's MRU editor for a test (`drgnx-state-use-editor'); return WINDOW."
  (drgnx-state-use-editor window)
  window)

(provide 'state-fixture)
;;; state-fixture.el ends here
