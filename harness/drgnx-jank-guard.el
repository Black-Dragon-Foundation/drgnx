;;; drgnx-jank-guard.el --- Record window-moving calls made from timers -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Invariant I9 (docs/workbench.md): nothing moves, selects, splits or deletes windows from
;; a timer.  The guard observes and records; it never blocks.  It knows it is in timer
;; context by wrapping `timer-event-handler'; commands run by a command loop nested
;; inside a timer (a minibuffer or a test's recursive edit) are not timer code, so
;; `command-execute' clears the flag.  Hook context is covered in M3 (change bus).

;;; Code:
(defvar drgnx-jank-guard-log nil
  "Recorded violations, newest first: plists (:time :fn :window :timer).")

(defvar drgnx-jank-guard--timer-fn nil
  "Function of the timer running now (dynamically bound), or nil.")

(defconst drgnx-jank-guard-functions
  '(select-window set-window-start set-window-point recenter split-window delete-window)
  "Window-moving functions the guard watches.")

(defun drgnx-jank-guard--describe (fn)
  (truncate-string-to-width (if (symbolp fn) (symbol-name fn) (format "%S" fn)) 80))

(defun drgnx-jank-guard--timer (orig timer)
  (let ((drgnx-jank-guard--timer-fn
         (or (and (timerp timer) (timer--function timer)) 'unknown-timer)))
    (funcall orig timer)))

(defun drgnx-jank-guard--command (orig &rest args)
  (let ((drgnx-jank-guard--timer-fn nil))
    (apply orig args)))

(defvar drgnx-wb--owned)

(defun drgnx-jank-guard--owned-p (fn args)
  "Non-nil if the window FN moves is one the running code owns (`drgnx-wb-with-owned-windows')."
  (and (boundp 'drgnx-wb--owned) drgnx-wb--owned
       (let ((w (if (and (memq fn '(set-window-start set-window-point select-window delete-window split-window))
                         (windowp (car args)))
                    (car args)
                  (selected-window))))
         (memq w drgnx-wb--owned))))

(defun drgnx-jank-guard--check (fn args)
  (when (and drgnx-jank-guard--timer-fn
             (not (and (eq fn 'select-window) (nth 1 args)))    ; NORECORD: temporary selection
             (not (drgnx-jank-guard--owned-p fn args)))
    (push (list :time (float-time) :fn fn
                :window (let ((w (car args))) (if (windowp w) (format "%s" w) "selected"))
                :timer (drgnx-jank-guard--describe drgnx-jank-guard--timer-fn))
          drgnx-jank-guard-log)))

(defun drgnx-jank-guard-enable ()
  "Start recording window-moving calls made from timers."
  (advice-add 'timer-event-handler :around #'drgnx-jank-guard--timer '((name . drgnx-jank-guard)))
  (advice-add 'command-execute :around #'drgnx-jank-guard--command '((name . drgnx-jank-guard)))
  (dolist (fn drgnx-jank-guard-functions)
    (advice-add fn :before (lambda (&rest args) (drgnx-jank-guard--check fn args))
                '((name . drgnx-jank-guard)))))

(defun drgnx-jank-guard-disable ()
  "Stop recording."
  (dolist (fn (append '(timer-event-handler command-execute) drgnx-jank-guard-functions))
    (advice-remove fn 'drgnx-jank-guard)))

(provide 'drgnx-jank-guard)
;;; drgnx-jank-guard.el ends here
