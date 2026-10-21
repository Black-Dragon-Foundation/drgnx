;;; drgnx-guard.el --- No prompts in automatic paths -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A prompt asked from a timer, a hook or while the daemon starts has nobody to answer it:
;; the daemon freezes.  `drgnx-guard-mode' makes such prompts signal
;; `drgnx-prompt-in-automatic-path' instead.  Timer context is known by wrapping
;; `timer-event-handler' (commands run by a nested command loop are not timer code);
;; other automatic code declares itself with `drgnx-automatic'.  Process filters and
;; sentinels are called from C, so they are guarded where they are handed over:
;; `drgnx-guard-wrap' runs a callback as automatic code and turns what it raises into a
;; notice (a refused prompt is a `fail', any other error a `warn'), and
;; `drgnx-guard-run-hook' does the same for each function of a hook.  A lint
;; (test/unit/lint-guard-test.el) keeps every callback wrapped.  See docs/develop/core.md.

;;; Code:
(define-error 'drgnx-prompt-in-automatic-path
              "drgnx: a prompt in an automatic path would freeze Emacs")

(defvar drgnx-guard-prompt-functions
  '(y-or-n-p yes-or-no-p read-string read-from-minibuffer completing-read read-passwd
             read-number read-file-name read-directory-name read-buffer
             read-multiple-choice read-answer read-key read-char-choice)
  "Functions that wait for an answer from the user (not `read-event': `sit-for' uses it).")

(defvar drgnx-guard--timer-fn nil "Function of the timer running now (dynamically bound), or nil.")
(defvar drgnx-guard--automatic nil "Non-nil inside `drgnx-automatic'.")

(defmacro drgnx-automatic (&rest body)
  "Run BODY as automatic code: a prompt inside it signals instead of waiting."
  `(let ((drgnx-guard--automatic t)) ,@body))

(defvar drgnx-guard--started nil
  "Non-nil once Emacs finished starting: set by the last `window-setup-hook' function (after
`after-init-hook' and `emacs-startup-hook', which run when `after-init-time' is already set).")

(defun drgnx-guard--daemon-starting-p ()
  "Non-nil while a daemon initialises (no client could answer)."
  (and (daemonp) (not drgnx-guard--started)))

(defun drgnx-guard--mark-started () (setq drgnx-guard--started t))

(defun drgnx-guard--context ()
  "Why the current context is automatic, or nil."
  (cond (drgnx-guard--timer-fn (format "a timer (%s)" drgnx-guard--timer-fn))
        (drgnx-guard--automatic "automatic code")
        ((drgnx-guard--daemon-starting-p) "daemon startup")))

(defun drgnx-guard-automatic-p ()
  "Non-nil when the code running now is automatic (a timer, `drgnx-automatic', daemon startup): nobody can answer
a prompt, and with `drgnx-guard-mode' on one would signal."
  (and (drgnx-guard--context) t))

(defun drgnx-guard--check (fn args)
  (when-let* ((why (drgnx-guard--context)))
    (signal 'drgnx-prompt-in-automatic-path
            (list (format "%s %S asked from %s" fn (car args) why)))))

(declare-function drgnx-timer-describe "drgnx-timer")

(defun drgnx-guard--timer (orig timer)
  (let ((drgnx-guard--timer-fn
         (or (and (timerp timer)       ; a layer timer's function is named by its entry, not `drgnx-timer--fire'
                  (let ((layer (and (fboundp 'drgnx-timer-describe) (drgnx-timer-describe timer))))
                    (if layer (plist-get layer :fn) (timer--function timer))))
             'unknown-timer)))
    (funcall orig timer)))

(defun drgnx-guard--command (orig &rest args)
  (let ((drgnx-guard--timer-fn nil) (drgnx-guard--automatic nil))
    (apply orig args)))

;;;; Process callbacks and hooks

(declare-function drgnx-notify "drgnx-notice")
(declare-function drgnx-timer--debugger-p "drgnx-timer")

(defun drgnx-guard--label (label)
  "LABEL as text: a string, or (HOOK . FN) from `drgnx-guard-run-hook', made a string only when something failed."
  (if (consp label) (format "%s %s" (car label) (cdr label)) label))

(defvar drgnx-notice--table)

(defun drgnx-guard--record (label err)
  "Record ERR, caught around LABEL, as a notice of source `guard' (the model loads on the first catch, not before:
no require cycle).  A refused prompt is a `fail' event, any other error a `warn' event, said in the echo area
when LABEL has none yet (the first catch; repeats only count), as Emacs said a failed filter.  Never signals."
  (let ((label (drgnx-guard--label label)))
    (condition-case failed
        (progn
          (require 'drgnx-notice)
          (if (memq 'drgnx-prompt-in-automatic-path (get (car err) 'error-conditions))
              (drgnx-notify 'guard 'fail
                            (format "%s asked a question from a process callback; drgnx refused (it would freeze Emacs)"
                                    label)
                            :id label)
            (drgnx-notify 'guard 'warn (format "%s: %s" label (error-message-string err)) :id label
                          :echo (not (gethash (cons 'guard label) drgnx-notice--table)))))
      (error (message "drgnx: %s: %s (not recorded: %s)" label (error-message-string err)
                      (error-message-string failed))))))

(defun drgnx-guard--call (fn label args)
  "Apply FN to ARGS as automatic code; an error is recorded under LABEL (`drgnx-guard--record') and the value is nil.
The debugger opens only with `debug-on-error' and a frame to show it in (the timer layer's rule,
`drgnx-timer--debugger-p'): never in batch or in a daemon with no client."
  (let ((debug-on-error (and debug-on-error (fboundp 'drgnx-timer--debugger-p) (drgnx-timer--debugger-p))))
    (condition-case-unless-debug err
        (drgnx-automatic (apply fn args))
      (error (drgnx-guard--record label err) nil))))

(defun drgnx-guard-wrap (fn &optional label)
  "A function of any arguments that applies FN to them inside the guard: for a process filter or sentinel.
FN runs as automatic code (`drgnx-automatic'), so a prompt there signals instead of waiting.  What it raises is
not signalled again (Emacs would show it as \"error in process sentinel\"): a refused prompt becomes a `fail'
event of source `guard' with id LABEL, any other error a `warn' event; the wrapper then returns nil.  LABEL names
the callback in those notices: the process's purpose, such as \"hub events\"; default FN printed."
  (let ((label (or label (format "%s" fn))))
    (lambda (&rest args) (drgnx-guard--call fn label args))))

(defun drgnx-guard--run-one (fn hook args)
  (drgnx-guard--call fn (cons hook fn) args)
  nil)

(defun drgnx-guard-run-hook (hook &rest args)
  "Call each function of HOOK with ARGS, each as if wrapped by `drgnx-guard-wrap' with the label \"HOOK FN\": one
that fails or asks is recorded, and the next still runs.  Returns nil."
  (run-hook-wrapped hook #'drgnx-guard--run-one hook args)
  nil)

(define-minor-mode drgnx-guard-mode
  "Signal instead of prompting in automatic paths (timers, `drgnx-automatic', daemon startup)."
  :global t :group 'drgnx
  (if drgnx-guard-mode
      (progn
        ;; Turned on after startup (init done): nothing is starting any more.
        (if after-init-time (drgnx-guard--mark-started)
          (add-hook 'window-setup-hook #'drgnx-guard--mark-started 100))
        (advice-add 'timer-event-handler :around #'drgnx-guard--timer '((name . drgnx-guard)))
        (advice-add 'command-execute :around #'drgnx-guard--command '((name . drgnx-guard)))
        (dolist (fn drgnx-guard-prompt-functions)
          (advice-add fn :before (lambda (&rest args) (drgnx-guard--check fn args)) '((name . drgnx-guard)))))
    (dolist (fn (append '(timer-event-handler command-execute) drgnx-guard-prompt-functions))
      (advice-remove fn 'drgnx-guard))))

(provide 'drgnx-guard)
;;; drgnx-guard.el ends here
