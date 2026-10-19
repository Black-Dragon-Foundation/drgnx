;;; drgnx-guard.el --- No prompts in automatic paths -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A prompt asked from a timer, a hook or while the daemon starts has nobody to answer it:
;; the daemon freezes.  `drgnx-guard-mode' makes such prompts signal
;; `drgnx-prompt-in-automatic-path' instead.  Timer context is known by wrapping
;; `timer-event-handler' (commands run by a nested command loop are not timer code);
;; other automatic code declares itself with `drgnx-automatic'.  Process filters and
;; sentinels are called from C and cannot be detected — wrap their bodies in
;; `drgnx-automatic'.  See docs/develop/core.md.

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
