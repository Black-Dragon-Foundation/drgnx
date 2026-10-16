;;; drgnx-guard.el --- No prompts in automatic paths -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A prompt asked from a timer, a hook or while the daemon starts has nobody to answer it:
;; the daemon freezes.  `drgnx-guard-mode' makes such prompts signal
;; `drgnx-prompt-in-automatic-path' instead.  Timer context is known by wrapping
;; `timer-event-handler' (commands run by a nested command loop are not timer code);
;; other automatic code declares itself with `drgnx-automatic'.  Process filters and
;; sentinels are called from C and cannot be detected — wrap their bodies in
;; `drgnx-automatic'.  See docs/core.md.

;;; Code:
(define-error 'drgnx-prompt-in-automatic-path
  "drgnx: a prompt in an automatic path would freeze Emacs")

(defvar drgnx-guard-prompt-functions
  '(y-or-n-p yes-or-no-p read-string read-from-minibuffer completing-read read-passwd
    read-number read-file-name read-directory-name read-buffer)
  "Functions that wait for an answer from the user.")

(defvar drgnx-guard--timer-fn nil "Function of the timer running now (dynamically bound), or nil.")
(defvar drgnx-guard--automatic nil "Non-nil inside `drgnx-automatic'.")

(defmacro drgnx-automatic (&rest body)
  "Run BODY as automatic code: a prompt inside it signals instead of waiting."
  `(let ((drgnx-guard--automatic t)) ,@body))

(defun drgnx-guard--daemon-starting-p ()
  "Non-nil while a daemon initialises (no client could answer)."
  (and (daemonp) (not after-init-time)))

(defun drgnx-guard--context ()
  "Why the current context is automatic, or nil."
  (cond (drgnx-guard--timer-fn (format "a timer (%s)" drgnx-guard--timer-fn))
        (drgnx-guard--automatic "automatic code")
        ((drgnx-guard--daemon-starting-p) "daemon startup")))

(defun drgnx-guard--check (fn args)
  (when-let ((why (drgnx-guard--context)))
    (signal 'drgnx-prompt-in-automatic-path
            (list (format "%s %S asked from %s" fn (car args) why)))))

(defun drgnx-guard--timer (orig timer)
  (let ((drgnx-guard--timer-fn (or (and (timerp timer) (timer--function timer)) 'unknown-timer)))
    (funcall orig timer)))

(defun drgnx-guard--command (orig &rest args)
  (let ((drgnx-guard--timer-fn nil) (drgnx-guard--automatic nil))
    (apply orig args)))

(define-minor-mode drgnx-guard-mode
  "Signal instead of prompting in automatic paths (timers, `drgnx-automatic', daemon startup)."
  :global t :group 'drgnx
  (if drgnx-guard-mode
      (progn
        (advice-add 'timer-event-handler :around #'drgnx-guard--timer '((name . drgnx-guard)))
        (advice-add 'command-execute :around #'drgnx-guard--command '((name . drgnx-guard)))
        (dolist (fn drgnx-guard-prompt-functions)
          (advice-add fn :before (lambda (&rest args) (drgnx-guard--check fn args)) '((name . drgnx-guard)))))
    (dolist (fn (append '(timer-event-handler command-execute) drgnx-guard-prompt-functions))
      (advice-remove fn 'drgnx-guard))))

(provide 'drgnx-guard)
;;; drgnx-guard.el ends here
