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
  "Called with no arguments once after a batch of teardowns (keys and menus follow the registry).")

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
    (unwind-protect
        (let ((err (condition-case e
                       (let ((drgnx-modules--current module) (drgnx-modules--setup-load load-file-name))
                         (funcall setup)
                         nil)
                     (error (error-message-string e)))))
          (when err (setq problems (append problems (drgnx-modules--unwind module before))))
          (setq done t)
          (and (or err problems) (cons err problems)))
      (unless done (drgnx-modules--unwind module before)))))

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
     (t (let ((problems nil) (fn (plist-get (cdr spec) :teardown))
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
