;;; drgnx-modules-record.el --- A module's cleanup stack: each change pushes its own undo -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; While a module's setup runs, `drgnx-modules--current' names it.  A call that changes global
;; state pushes its own undo onto that module's stack with `drgnx-modules-push-undo' (the shape of
;; buttercup's cleanup stack: the code that knows what it changed knows how to change it back).
;; `drgnx-module-teardown' turns a module off now: its :teardown function, then its stack, last in
;; first out, each undo under its own error guard.  A setup that does not finish (an error, a quit,
;; a throw) is rolled back the same way.  Teardown and rollback run in automatic paths: they never
;; prompt.  `require' cannot be undone — the top level of a library a setup loads is never
;; recorded.  See docs/develop/core.md, "Modules".

;;; Code:
(defvar drgnx-modules--table)
(defvar drgnx-modules--report)
(declare-function drgnx-modules--record "drgnx-modules")

(defvar drgnx-modules--current nil
  "The module whose setup is running now (dynamically bound), else nil.")

(defvar drgnx-modules--setup-load nil
  "`load-file-name' when the running setup began (dynamically bound with `drgnx-modules--current').
The startup stage itself runs inside a `load' (init.el calls `drgnx-init'), so \"a load is in
progress\" cannot tell a setup's own code from a library it loads; a nested `load' or `require'
binds `load-file-name' anew.")

(defvar drgnx-modules--stacks nil
  "Alist MODULE → list of (LABEL . UNDO), newest first: how to undo what its setup changed.")

(defvar drgnx-module--in-helper nil
  "Non-nil (dynamically bound) while a paired helper itself calls `add-hook' or `advice-add'.
The safety net that records raw `add-hook' and `advice-add' calls during a setup skips them: the
helper already made the claim, and a second, unconditional undo would break the either-order rule.")

(defvar drgnx-modules--tearing-down nil "Modules whose teardown is running (dynamically bound).")

(defvar drgnx-modules-after-teardown-functions nil
  "Called with no arguments once after a batch of teardowns and after a run-time turn on.
Keys and menus follow the registry.")

(defsubst drgnx-modules--recording-p ()
  "Non-nil when a module's setup is running and it is the setup's own code, not the top level of
a library it loads (that registers for itself and stays until restart)."
  (and drgnx-modules--current (eq load-file-name drgnx-modules--setup-load)))

(defun drgnx-modules-push-undo (label undo)
  "Record UNDO to run when the module whose setup is running is torn down; return nil.
UNDO: a function of no arguments that first checks the state is still what this module set, and
changes nothing otherwise.  LABEL: a short description for reports (\"hook find-file-hook f\").
Outside a setup, or from the top level of a library the setup loads, nothing is recorded
\(`drgnx-modules--recording-p')."
  (when (drgnx-modules--recording-p)
    (push (cons label undo) (alist-get drgnx-modules--current drgnx-modules--stacks)))
  nil)

;;;; The safety net: what a setup reaches through Emacs's own doors

(defsubst drgnx-modules--net-records-p ()
  "Non-nil if the safety net records the call being made: a setup's own code, not a drgnx helper."
  (and (not drgnx-module--in-helper) (drgnx-modules--recording-p)))

(defvar drgnx-modules--net-seen nil
  "While the safety net is on (non-nil only then): (TIMERS MODES FEATURES) already attributed — to a setup run
inside this one, or to nobody (another library's `eval-after-load' forms) — so that no other module gets them.")

(defvar drgnx-modules--runs nil
  "Alist MODULE → a token made fresh by each run of its setup and dropped when it is torn down or rolled back.
Deferred work (`drgnx-modules-with-owner') runs only while the run that scheduled it is on.")

(defvar drgnx-modules--features nil
  "Alist MODULE → the features its setups loaded first, newest first (for the report; never unloaded).")

(defun drgnx-modules-features-of (module)
  "The features MODULE's setup loaded first, newest first.  `require' cannot be undone: they stay loaded."
  (alist-get module drgnx-modules--features))

(defun drgnx-modules--name (fn) (if (symbolp fn) (symbol-name fn) "a lambda"))

(defun drgnx-modules--label (&rest args)
  "`format' ARGS, cut to 100 characters: a list element can be a keymap or a long alist entry."
  (let ((s (let ((print-length 4) (print-level 2)) (apply #'format args))))
    (if (> (length s) 100) (concat (substring s 0 99) "…") s)))

(defconst drgnx-modules--emacs-timer-variables '(jit-lock-context-timer jit-lock--antiblink-grace-timer)
  "Variables in which Emacs's own libraries keep a timer whose function is a lambda (see
`drgnx-modules--emacs-timer-p').")

(defun drgnx-modules--emacs-timer-p (timer)
  "Non-nil if TIMER is one of Emacs's own: its function is defined under `lisp-directory' (or preloaded), or a
library keeps it in one of `drgnx-modules--emacs-timer-variables'.  Emacs's libraries start such singleton timers
lazily from code a setup calls (an edit starts undo's boundary timer) and keep them in a variable: cancelled, they
would stay dead for the session.  The net leaves them alone."
  (let ((fn (timer--function timer)))
    (or (and (symbolp fn)
             (let ((file (symbol-file fn 'defun)))
               (and file (or (not (file-name-absolute-p file)) (string-prefix-p lisp-directory file)))))
        (let ((vars drgnx-modules--emacs-timer-variables))
          (while (and vars (not (and (boundp (car vars)) (eq (symbol-value (car vars)) timer))))
            (setq vars (cdr vars)))
          vars))))

(defun drgnx-modules--hook-has (hook function)
  "Non-nil if FUNCTION is on HOOK's global value (`add-hook''s test)."
  (let ((v (and (default-boundp hook) (default-value hook))))
    (member function (if (or (functionp v) (not (listp v))) (list v) v))))

(defun drgnx-modules--add-hook (orig hook function &optional depth local)
  "Around `add-hook' while a setup runs: a function newly on a hook's global value is recorded."
  (let ((new (and (not local) (drgnx-modules--net-records-p) (not (drgnx-modules--hook-has hook function)))))
    (prog1 (funcall orig hook function depth local)
      (when (and new (drgnx-modules--hook-has hook function))
        (drgnx-modules-push-undo (drgnx-modules--label "hook %s %s" hook (drgnx-modules--name function))
                                 (lambda () (when (drgnx-modules--hook-has hook function)
                                              (remove-hook hook function))))))))

(defun drgnx-modules--advice-add (orig symbol how function &optional props)
  "Around `advice-add' while a setup runs: an advice newly on SYMBOL is recorded."
  (let ((new (and (drgnx-modules--net-records-p) (not (advice-member-p function symbol)))))
    (prog1 (funcall orig symbol how function props)
      (when (and new (advice-member-p function symbol))
        (drgnx-modules-push-undo (drgnx-modules--label "advice %s %s" symbol (drgnx-modules--name function))
                                 (lambda () (when (advice-member-p function symbol)
                                              (advice-remove symbol function))))))))

(defun drgnx-modules--list-has (var element compare)
  "The tail of VAR's global value that starts with ELEMENT, as `add-to-list' with COMPARE finds it."
  (let ((l (and (default-boundp var) (default-value var))))
    (cond ((null compare) (member element l))
          ((eq compare #'eq) (memq element l))
          ((eq compare #'eql) (memql element l))
          (t (while (and l (not (funcall compare element (car l)))) (setq l (cdr l))) l))))   ; its argument order

(defun drgnx-modules--add-to-list (orig var element &optional append compare)
  "Around `add-to-list' while a setup runs: an element newly in a list's global value is recorded.
Not the minor mode lists (Emacs 31's `define-minor-mode' adds to them so): modes are compared after the setup."
  (let ((new (and (drgnx-modules--net-records-p) (symbolp var) (not (memq var '(global-minor-modes local-minor-modes)))
                  (not (drgnx-modules--list-has var element compare)))))
    (prog1 (funcall orig var element append compare)
      (when (and new (drgnx-modules--list-has var element compare))
        (drgnx-modules-push-undo (drgnx-modules--label "list %s %s" var element)
                                 (lambda ()
                                   (when-let* ((cell (drgnx-modules--list-has var element compare)))
                                     (let ((l (default-value var)))   ; a copy without that one element
                                       (set-default var (append (take (- (length l) (length cell)) l) (cdr cell)))))))))))

(defun drgnx-modules--snapshot ()
  "Timers, global minor modes and features now, to compare with later (`drgnx-modules--new')."
  ;; Copies: timers are inserted into their lists, and modes deleted from theirs, in place.
  (list (append timer-list timer-idle-list nil) (copy-sequence global-minor-modes) features))

(defun drgnx-modules--fresh (now old claimed)
  "The elements of NOW in neither OLD nor CLAIMED, in NOW's order."
  (let ((out nil))
    (dolist (x now) (unless (or (memq x old) (memq x claimed)) (push x out)))
    (nreverse out)))

(defun drgnx-modules--new (before)
  "(TIMERS MODES FEATURES) there now but not in BEFORE (a `drgnx-modules--snapshot') and claimed by nobody."
  (pcase-let ((`(,timers ,modes ,feats) before)
              (`(,ct ,cm ,cf) drgnx-modules--net-seen))
    (let* ((n (- (length features) (length feats)))
           (tail (and (>= n 0) (eq (nthcdr n features) feats))))   ; `provide' pushes: the old list is a tail
      (list (drgnx-modules--fresh (append timer-list timer-idle-list) timers ct)
            (drgnx-modules--fresh global-minor-modes modes cm)
            (drgnx-modules--fresh (if tail (take n features) features) (unless tail feats) cf)))))

(defun drgnx-modules--claim (new)
  "Mark NEW, a (TIMERS MODES FEATURES), as attributed, so no enclosing recorder takes it too."
  (let ((box drgnx-modules--net-seen))           ; one list, shared by the nested recorders: changed in place
    (when box
      (dolist (part new) (setcar box (append part (car box))) (setq box (cdr box))))))

(defun drgnx-modules--after-load (orig &rest args)
  "Around `do-after-load-evaluation' while a setup runs: `eval-after-load' forms belong to nobody.
They run once, when their library loads; were they recorded on the module whose setup loaded it, turning that
module off would undo them and turning it on again would not bring them back.  So nothing they do is recorded —
except deferred work that names its owner (`drgnx-modules-with-owner')."
  (let ((before (drgnx-modules--snapshot)))
    (unwind-protect (let ((drgnx-modules--current nil)) (apply orig args))
      (drgnx-modules--claim (drgnx-modules--new before)))))

(defconst drgnx-modules--net
  '((add-hook . drgnx-modules--add-hook) (add-to-list . drgnx-modules--add-to-list)
    (do-after-load-evaluation . drgnx-modules--after-load) (advice-add . drgnx-modules--advice-add))
  "The safety net: advice on Emacs's own doors, there only while a setup runs.  `advice-add' last, so
installing the others is not recorded.")

(defun drgnx-modules--record-new (module before)
  "Push MODULE's undos for the timers and global modes that appeared since BEFORE and that nobody claimed;
note its new features.  Modes are pushed last: they go off first, and their own off code goes first."
  (pcase-let ((`(,timers ,modes ,feats) (drgnx-modules--new before)))
    (dolist (timer timers)
      (unless (drgnx-modules--emacs-timer-p timer)
        (drgnx-modules-push-undo (drgnx-modules--label "timer %s" (drgnx-modules--name (timer--function timer)))
                                 (lambda () (when (or (memq timer timer-list) (memq timer timer-idle-list))
                                              (cancel-timer timer))))))
    (dolist (mode (reverse modes))               ; newest first in the list: the newest goes off first
      (drgnx-modules-push-undo (format "mode %s" mode)
                               (lambda () (when (memq mode global-minor-modes) (funcall mode -1)))))
    (when feats
      (setf (alist-get module drgnx-modules--features) (append feats (alist-get module drgnx-modules--features))))
    (drgnx-modules--claim (list timers modes feats))))

(defun drgnx-modules--record-call (module fn)
  "Call FN as MODULE's code, with the safety net; return its value.
While FN runs, `add-hook' (global), `advice-add' and `add-to-list' calls from MODULE's own code that change
something push their undo onto MODULE's stack; after it (also after an error, a quit or a throw), so do the timers
and global minor modes that appeared.  The advice is installed by the outermost call only and removed when it
ends: outside a setup it costs nothing."
  (let ((outer drgnx-modules--net-seen) (before (drgnx-modules--snapshot)))
    (unwind-protect
        (progn
          (unless outer (dolist (a drgnx-modules--net) (advice-add (car a) :around (cdr a))))
          (let ((drgnx-modules--net-seen (or outer (list nil nil nil)))
                (drgnx-modules--current module) (drgnx-modules--setup-load load-file-name))
            (unwind-protect (funcall fn)
              (drgnx-modules--record-new module before))))
      (unless outer
        (let ((inhibit-quit t))                 ; a second C-g must not leave the advice behind
          (dolist (a drgnx-modules--net) (advice-remove (car a) (cdr a))))))))

(defun drgnx-modules--quietly-call (fn)
  "Call FN as a claim-aware drgnx helper's own change, which pushes its own undo; return FN's value.
The safety net records nothing of it: not its `add-hook', `advice-add' or `add-to-list' calls
\(`drgnx-module--in-helper'), nor the timers and global modes it starts (seen, for nobody).  A second,
unconditional undo from the net would turn off a mode or remove a function another module still claims."
  (if (not drgnx-modules--net-seen)
      (let ((drgnx-module--in-helper t)) (funcall fn))
    (let ((before (drgnx-modules--snapshot)))
      (unwind-protect (let ((drgnx-module--in-helper t)) (funcall fn))
        (drgnx-modules--claim (drgnx-modules--new before))))))

(defmacro drgnx-modules--quietly (&rest body)
  "Run BODY as a claim-aware helper's own change: the safety net records none of it (`drgnx-modules--quietly-call')."
  (declare (indent 0) (debug t))
  `(drgnx-modules--quietly-call (lambda () ,@body)))

(defmacro drgnx-modules--with-recorder (module &rest body)
  "Run BODY as MODULE's setup code with the safety net (`drgnx-modules--record-call')."
  (declare (indent 1) (debug t))
  `(drgnx-modules--record-call ,module (lambda () ,@body)))

(defun drgnx-modules--owner ()
  "(MODULE . RUN-TOKEN) when a setup's own code runs, else nil."
  (and (drgnx-modules--recording-p)
       (cons drgnx-modules--current (alist-get drgnx-modules--current drgnx-modules--runs))))

(defun drgnx-modules--owned (owner fn)
  "A function that calls FN (with its arguments) as OWNER's code (`drgnx-modules--owner'), recorded; once
OWNER's run is over (turned off, rolled back, run again) it does nothing and returns nil.  No OWNER: FN."
  (if (not owner) fn
    (lambda (&rest args)
      (when (eq (cdr owner) (alist-get (car owner) drgnx-modules--runs))
        (drgnx-modules--record-call (car owner) (lambda () (apply fn args)))))))

(defmacro drgnx-modules-with-owner (&rest body)
  "A function (of any arguments, ignored) that runs BODY later as the module whose setup evaluates this form.
For deferred work: `(eval-after-load \\='x (drgnx-modules-with-owner …))', `(run-with-idle-timer 1 nil
\(drgnx-modules-with-owner …))'.  When it runs, what BODY changes is recorded onto that module, as in its setup;
once the module is turned off (or its setup rolled back, or run again) it does nothing and returns nil.
Evaluated outside a setup, it just runs BODY.  Each call installs the safety net for BODY's extent: for one-off
work, not for a hook that runs on every command."
  (declare (indent 0) (debug t))
  `(drgnx-modules--owned (drgnx-modules--owner) (lambda (&rest _) ,@body)))

(defun drgnx-modules--unwind (module &optional until)
  "Run MODULE's undos, newest first, down to UNTIL (a tail of its stack; nil: all of it).
Each runs under its own error guard and may not prompt.  Returns the problems, one string per
undo that failed, naming its label."
  (let ((problems nil) (inhibit-interaction t) (drgnx-modules--current nil))
    (while (let ((stack (alist-get module drgnx-modules--stacks)))
             (and stack (not (eq stack until))))
      (let ((entry (pop (alist-get module drgnx-modules--stacks))))   ; popped first: never runs twice
        (condition-case e (funcall (cdr entry))
          (error (push (format "%s: %s" (car entry) (error-message-string e)) problems)))))
    (unless (alist-get module drgnx-modules--stacks)
      (setq drgnx-modules--stacks (assq-delete-all module drgnx-modules--stacks)))
    (nreverse problems)))

(defun drgnx-modules--restart-p (module)
  "Non-nil if MODULE is not turned off while Emacs runs: `:teardown \\='restart', or not drgnx's own."
  (let ((spec (assq module drgnx-modules--table)))
    (or (not spec) (eq (plist-get (cdr spec) :teardown) 'restart))))

(defun drgnx-modules--run-setup (module setup)
  "Run SETUP as MODULE's: the undos it pushes go onto MODULE's stack.
A module that is on (and not `restart') is torn down first, so no undo is left behind.  When the
setup does not finish — an error, a quit, a throw — what it changed so far is rolled back; a quit
or a throw then goes on.  Returns nil when all went well, else (ERROR-MESSAGE-or-nil . PROBLEMS)."
  (let* ((problems (and (eq (plist-get (alist-get module drgnx-modules--report) :status) 'ok)
                        (not (drgnx-modules--restart-p module))
                        (drgnx-module-teardown module)))
         (before (alist-get module drgnx-modules--stacks))
         (done nil))
    (setf (alist-get module drgnx-modules--runs) (list module))   ; this run's token
    (unwind-protect
        (let ((err (condition-case e
                       (progn (drgnx-modules--with-recorder module (funcall setup)) nil)
                     (error (error-message-string e)))))
          (when err
            (setq drgnx-modules--runs (assq-delete-all module drgnx-modules--runs))
            (setq problems (append problems (drgnx-modules--unwind module before))))
          (setq done t)
          (and (or err problems) (cons err problems)))
      (unless done
        (setq drgnx-modules--runs (assq-delete-all module drgnx-modules--runs))
        (drgnx-modules--unwind module before)))))

(defun drgnx-module-teardown (name)
  "Turn module NAME off now: its :teardown function, then its cleanup stack, last in first out.
Returns the problems (nil when clean): an undo that failed is named by its label, a failed
:teardown by \"teardown\"; nothing is raised and nothing prompts.  The status becomes `off'.
A module that is not running does nothing, nor does a teardown of NAME from inside its own.  A
module defined with `:teardown \\='restart' (or one drgnx did not define, such as an external
module) is left running and returns (\"restart\").  Callers run
`drgnx-modules-after-teardown-functions' once after a batch of teardowns."
  (let ((spec (assq name drgnx-modules--table))
        (report (alist-get name drgnx-modules--report)))
    (cond
     ((or (not (eq (plist-get report :status) 'ok)) (memq name drgnx-modules--tearing-down)) nil)
     ((drgnx-modules--restart-p name) (list "restart"))
     (t (setq drgnx-modules--runs (assq-delete-all name drgnx-modules--runs))   ; its deferred work stops
        (let ((problems nil) (fn (plist-get (cdr spec) :teardown))
              (drgnx-modules--tearing-down (cons name drgnx-modules--tearing-down)))
          (unwind-protect
              (when (functionp fn)
                (let ((inhibit-interaction t) (drgnx-modules--current nil))
                  (condition-case e (funcall fn)
                    (error (push (format "teardown: %s" (error-message-string e)) problems)))))
            (setq problems (append problems (drgnx-modules--unwind name)))
            (drgnx-modules--record name (plist-get report :stage) nil 'off nil nil problems))
          problems)))))

(provide 'drgnx-modules-record)
;;; drgnx-modules-record.el ends here
