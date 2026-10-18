;;; drgnx-modules-record.el --- A module's cleanup stack: each change pushes its own undo -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; While a module's setup runs, `drgnx-modules--current' names it.  A call that changes global
;; state pushes its own undo onto that module's stack with `drgnx-modules-push-undo' (the shape of
;; buttercup's cleanup stack: the code that knows what it changed knows how to change it back).
;; `drgnx-module-teardown' turns a module off now: its :teardown function, then its stack, last in
;; first out, each undo under its own error guard.  A setup that fails half-way is rolled back the
;; same way.  Teardown and rollback run in automatic paths: they never prompt.  `require' cannot be
;; undone — a library's top level is never recorded.  See docs/develop/core.md, "Modules".

;;; Code:
(defvar drgnx-modules--table)
(defvar drgnx-modules--report)
(declare-function drgnx-modules--record "drgnx-modules")

(defvar drgnx-modules--current nil
  "The module whose setup is running now (dynamically bound), else nil.")

(defvar drgnx-modules--stacks nil
  "Alist MODULE → list of (LABEL . UNDO), newest first: how to undo what its setup changed.")

(defvar drgnx-modules-after-teardown-functions nil
  "Called with no arguments once after a batch of teardowns (keys and menus follow the registry).")

(defun drgnx-modules-push-undo (label undo)
  "Record UNDO to run when the module whose setup is running is torn down; return nil.
UNDO: a function of no arguments that first checks the state is still what this module set, and
changes nothing otherwise.  LABEL: a short description for reports (\"hook find-file-hook f\").
Outside a setup, or while a library loads (its top level registers for itself and stays until
restart), nothing is recorded."
  (when (and drgnx-modules--current (not load-in-progress))
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

(defun drgnx-modules--run-setup (module setup)
  "Run SETUP as MODULE's: the undos it pushes go onto MODULE's stack.  Nil when it ran; when it
signals, what it changed so far is rolled back and the result is (ERROR-MESSAGE . UNDO-PROBLEMS)."
  (let ((before (alist-get module drgnx-modules--stacks)))
    (condition-case e
        (progn (let ((drgnx-modules--current module)) (funcall setup)) nil)
      (error (cons (error-message-string e) (drgnx-modules--unwind module before))))))

(defun drgnx-module-teardown (name)
  "Turn module NAME off now: its :teardown function, then its cleanup stack, last in first out.
Returns the problems (nil when clean): an undo that failed is named by its label, a failed
:teardown by \"teardown\"; nothing is raised and nothing prompts.  The status becomes `off'.
A module that is not running does nothing.  A module defined with `:teardown \\='restart' (or one
drgnx did not define, such as an external module) is left running and returns (\"restart\").
Callers run `drgnx-modules-after-teardown-functions' once after a batch of teardowns."
  (let ((spec (assq name drgnx-modules--table))
        (report (alist-get name drgnx-modules--report)))
    (cond
     ((not (eq (plist-get report :status) 'ok)) nil)
     ((or (not spec) (eq (plist-get (cdr spec) :teardown) 'restart)) (list "restart"))
     (t (let ((problems nil) (fn (plist-get (cdr spec) :teardown)))
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
