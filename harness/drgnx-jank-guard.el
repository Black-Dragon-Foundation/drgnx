;;; drgnx-jank-guard.el --- Record window-moving calls made from timers and window hooks -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Invariant I9 (docs/guide/workbench.md): nothing moves, selects, splits or deletes windows from
;; a timer or a window change hook.  The guard observes and records; it never blocks.  It knows it is in timer
;; context by wrapping `timer-event-handler'; commands run by a command loop nested
;; inside a timer (a minibuffer or a test's recursive edit) are not timer code, so
;; `command-execute' clears the flag.  Hooks run from C, so their members are wrapped: the guard
;; replaces each member of `drgnx-jank-guard-hooks' (and later `add-hook's, `remove-hook' still works)
;; with a closure that notes it is running.

;;; Code:
(defvar drgnx-jank-guard-log nil
  "Recorded violations, newest first: plists (:time :fn :window :timer).")

(defvar drgnx-jank-guard--timer-fn nil
  "Function of the timer running now (dynamically bound), or nil.")

(defconst drgnx-jank-guard-functions
  '(select-window set-window-start set-window-point recenter split-window delete-window)
  "Window-moving functions the guard watches.")

(defconst drgnx-jank-guard-hooks
  '(window-configuration-change-hook window-size-change-functions window-selection-change-functions
                                     window-buffer-change-functions window-state-change-functions)
  "Hooks whose (global) members the guard wraps.")

(defvar drgnx-jank-guard--hook-fn nil
  "(HOOK . FUNCTION) of the hook member running now (dynamically bound), or nil.")

(defvar drgnx-jank-guard--wrapped nil
  "Wrapped hook members: (((HOOK . FUNCTION) . WRAPPER) …).")

(defun drgnx-jank-guard--wrap (hook fn)
  "FN as a member of HOOK, noting that it runs; the same closure for the same member."
  (if (or (eq fn t) (not (or (symbolp fn) (functionp fn)))
          (rassq fn drgnx-jank-guard--wrapped))        ; already ours (a second enable)
      fn
    (or (cdr (assoc (cons hook fn) drgnx-jank-guard--wrapped))
        (let ((w (lambda (&rest args)
                   (let ((drgnx-jank-guard--hook-fn (cons hook fn))) (apply fn args)))))
          (push (cons (cons hook fn) w) drgnx-jank-guard--wrapped)
          w))))

(defun drgnx-jank-guard--unwrap (w)
  (if-let* ((cell (rassq w drgnx-jank-guard--wrapped))) (cdar cell) w))

(defun drgnx-jank-guard--map-hook (hook fn)
  "Replace the members of HOOK's global value by (FN member)."
  (when (boundp hook)
    (let ((v (default-value hook)))
      (set-default hook (if (and (consp v) (not (functionp v))) (mapcar fn v)
                          (if v (funcall fn v) v))))))

(defun drgnx-jank-guard--add-hook (args)
  (pcase-let ((`(,hook ,fn . ,rest) args))
    (if (and (memq hook drgnx-jank-guard-hooks) (not (nth 1 rest)))
        (cons hook (cons (drgnx-jank-guard--wrap hook fn) rest))
      args)))

(defun drgnx-jank-guard--remove-hook (args)
  (pcase-let ((`(,hook ,fn . ,rest) args))
    (if (and (memq hook drgnx-jank-guard-hooks) (not (nth 0 rest)))
        (cons hook (cons (or (cdr (assoc (cons hook fn) drgnx-jank-guard--wrapped)) fn) rest))
      args)))

(defun drgnx-jank-guard--describe (fn)
  (truncate-string-to-width (if (symbolp fn) (symbol-name fn) (format "%S" fn)) 80))

(declare-function drgnx-timer-describe "drgnx-timer")

(defun drgnx-jank-guard--timer (orig timer)
  (let ((drgnx-jank-guard--timer-fn
         (or (and (timerp timer)       ; a layer timer's function is named by its entry, not `drgnx-timer--fire'
                  (let ((layer (and (fboundp 'drgnx-timer-describe) (drgnx-timer-describe timer))))
                    (if layer (plist-get layer :fn) (timer--function timer))))
             'unknown-timer)))
    (funcall orig timer)))

(defun drgnx-jank-guard--command (orig &rest args)
  (let ((drgnx-jank-guard--timer-fn nil) (drgnx-jank-guard--hook-fn nil))
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
  (when (and (or drgnx-jank-guard--timer-fn drgnx-jank-guard--hook-fn)
             (not (and (eq fn 'select-window) (nth 1 args)))    ; NORECORD: temporary selection
             (not (drgnx-jank-guard--owned-p fn args)))
    (push (list :time (float-time) :fn fn
                :window (let ((w (car args))) (if (windowp w) (format "%s" w) "selected"))
                :timer (if drgnx-jank-guard--hook-fn
                           (drgnx-jank-guard--describe
                            (format "%s: %S" (car drgnx-jank-guard--hook-fn) (cdr drgnx-jank-guard--hook-fn)))
                         (drgnx-jank-guard--describe drgnx-jank-guard--timer-fn)))
          drgnx-jank-guard-log)))

(defun drgnx-jank-guard-enable ()
  "Start recording window-moving calls made from timers and window change hooks."
  (dolist (hook drgnx-jank-guard-hooks)
    (drgnx-jank-guard--map-hook hook (lambda (fn) (drgnx-jank-guard--wrap hook fn))))
  (advice-add 'add-hook :filter-args #'drgnx-jank-guard--add-hook '((name . drgnx-jank-guard)))
  (advice-add 'remove-hook :filter-args #'drgnx-jank-guard--remove-hook '((name . drgnx-jank-guard)))
  (advice-add 'timer-event-handler :around #'drgnx-jank-guard--timer '((name . drgnx-jank-guard)))
  (advice-add 'command-execute :around #'drgnx-jank-guard--command '((name . drgnx-jank-guard)))
  (dolist (fn drgnx-jank-guard-functions)
    (advice-add fn :before (lambda (&rest args) (drgnx-jank-guard--check fn args))
                '((name . drgnx-jank-guard)))))

(defun drgnx-jank-guard-disable ()
  "Stop recording."
  (dolist (fn (append '(timer-event-handler command-execute add-hook remove-hook) drgnx-jank-guard-functions))
    (advice-remove fn 'drgnx-jank-guard))
  (dolist (hook drgnx-jank-guard-hooks) (drgnx-jank-guard--map-hook hook #'drgnx-jank-guard--unwrap))
  (setq drgnx-jank-guard--wrapped nil))

(provide 'drgnx-jank-guard)
;;; drgnx-jank-guard.el ends here
