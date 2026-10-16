;;; drgnx-uitest.el --- Drive a drgnx harness session with paced synthetic input -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Loaded only inside harness sessions (docs/harness.md).  Input is queued and delivered
;; one event per `drgnx-uitest-tick', so redisplay runs between events as it does for a
;; person; queued input would skip redisplay and hide jank.  Positions are root-frame
;; pixels, the same pixels as a screenshot.  APIs called through emacsclient run in
;; ` *server*', so they always act on the root frame's selected window.

;;; Code:
(require 'cl-lib)
(require 'drgnx-jank-guard)

(defvar drgnx-uitest-tick 0.04 "Seconds between two delivered input events.")
(defvar drgnx-uitest-quiet 0.3
  "Seconds without delivered input or visible change after which the session counts as settled.")

(defvar drgnx-uitest--queue nil "Input events waiting to be delivered, one per tick.")
(defvar drgnx-uitest--timer nil)
(defvar drgnx-uitest--last-delivery 0.0 "`float-time' of the last delivered event.")
(defvar drgnx-uitest-record--last-change 0.0 "`float-time' of the last recorded visible change.")
(defvar drgnx-uitest--next-id 0)

;;;; Frames and windows

(defun drgnx-uitest-root-frame ()
  "The session's root frame: the first visible frame that is not a child frame."
  (or (cl-find-if (lambda (f) (and (null (frame-parent f)) (frame-visible-p f))) (frame-list))
      (selected-frame)))

(defun drgnx-uitest-window-id (window)
  "Stable id of WINDOW for reports: \"mini\" for a minibuffer window, else \"wN\"."
  (if (window-minibuffer-p window)
      "mini"
    (or (window-parameter window 'drgnx-uitest-id)
        (set-window-parameter window 'drgnx-uitest-id
                              (format "w%d" (cl-incf drgnx-uitest--next-id))))))

(defun drgnx-uitest-find-window (buffer)
  "The root-frame window whose buffer name or major mode name is BUFFER."
  (cl-find-if (lambda (w)
                (with-current-buffer (window-buffer w)
                  (or (equal (buffer-name) buffer) (equal (symbol-name major-mode) buffer))))
              (window-list (drgnx-uitest-root-frame) 'nomini)))

(defun drgnx-uitest-posn (x y)
  "Position object for root-frame pixel X, Y."
  (posn-at-x-y x y (drgnx-uitest-root-frame)))

(defun drgnx-uitest-target-xy (buffer text)
  "Root-frame pixel (X . Y) inside the first visible TEXT in the window showing BUFFER.
BUFFER is a buffer name or a major mode name.  Signals if either is not on screen."
  (let* ((win (or (drgnx-uitest-find-window buffer)
                  (error "drgnx-uitest: no window shows %s" buffer)))
         (pos (with-current-buffer (window-buffer win)
                (save-excursion
                  (goto-char (window-start win))
                  (unless (search-forward text (window-end win t) t)
                    (error "drgnx-uitest: %S is not visible in %s" text buffer))
                  (match-beginning 0))))
         (xy (posn-x-y (posn-at-point pos win)))
         (body (window-body-pixel-edges win))
         (f (window-frame win)))
    (cons (+ (nth 0 body) (car xy) (/ (frame-char-width f) 2))
          (+ (nth 1 body) (cdr xy) (/ (frame-char-height f) 2)))))

;;;; Events (pure)

(defun drgnx-uitest-key-events (keys)
  "Input events for KEYS in `kbd' syntax, e.g. \"C-x b\"."
  (listify-key-sequence (kbd keys)))

(defun drgnx-uitest-type-events (text)
  "Input events that type TEXT."
  (append text nil))

(defun drgnx-uitest-click-events (posn &optional button count hold)
  "Input events for clicking at POSN.
BUTTON is 1-3 (default 1), COUNT 1 or 2, HOLD seconds between press and release."
  (let* ((b (or button 1))
         (single (append (list (list (intern (format "down-mouse-%d" b)) posn))
                         (and hold (> hold 0) (list (cons 'drgnx-uitest-pause hold)))
                         (list (list (intern (format "mouse-%d" b)) posn)))))
    (if (eql count 2)
        (append single (list (list (intern (format "double-down-mouse-%d" b)) posn 2)
                             (list (intern (format "double-mouse-%d" b)) posn 2)))
      single)))

;;;; Paced delivery

(defun drgnx-uitest-enqueue (events)
  "Queue EVENTS for paced delivery; return the queue length."
  (setq drgnx-uitest--queue (append drgnx-uitest--queue events))
  (unless drgnx-uitest--timer           ; tests bind a non-timer here to drive `--tick' by hand
    (setq drgnx-uitest--timer (run-with-timer 0 drgnx-uitest-tick #'drgnx-uitest--tick)))
  (length drgnx-uitest--queue))

(defun drgnx-uitest--tick ()
  "Deliver the next queued event, or wait out a pause; stop the timer when empty."
  (let ((ev (car drgnx-uitest--queue)))
    (cond
     ((null ev)
      (when (timerp drgnx-uitest--timer) (cancel-timer drgnx-uitest--timer))
      (setq drgnx-uitest--timer nil))
     ((eq (car-safe ev) 'drgnx-uitest-pause)
      (setcar drgnx-uitest--queue (cons 'drgnx-uitest-until (+ (float-time) (cdr ev)))))
     ((eq (car-safe ev) 'drgnx-uitest-until)
      (when (>= (float-time) (cdr ev)) (pop drgnx-uitest--queue)))
     (t
      (pop drgnx-uitest--queue)
      (setq unread-command-events (append unread-command-events (list ev))
            drgnx-uitest--last-delivery (float-time))))))

(defun drgnx-uitest-busy-p ()
  "Non-nil while input is queued or not yet read."
  (or drgnx-uitest--queue unread-command-events))

(defun drgnx-uitest-settled-p (&optional quiet)
  "Non-nil when no input is pending and nothing changed for QUIET seconds."
  (and (not (drgnx-uitest-busy-p))
       (>= (- (float-time) (max drgnx-uitest--last-delivery drgnx-uitest-record--last-change))
           (or quiet drgnx-uitest-quiet))))

;;;; Running input from a test

(defun drgnx-uitest-run (events &optional timeout)
  "Deliver EVENTS paced and return when settled or after TIMEOUT seconds (default 5).
For ERT tests inside a session: a nested command loop runs the events as commands,
with redisplay between them, while the test waits.  Returns a plist with :settled."
  (drgnx-uitest-enqueue events)
  (let* ((deadline (+ (float-time) (or timeout 5)))
         (settled nil)
         (watch (run-with-timer drgnx-uitest-tick drgnx-uitest-tick
                                (lambda ()
                                  (when (or (setq settled (drgnx-uitest-settled-p))
                                            (> (float-time) deadline))
                                    (exit-recursive-edit))))))
    (unwind-protect
        (let ((drgnx-jank-guard--timer-fn nil)) (recursive-edit))
      (cancel-timer watch))
    (list :settled (if settled t :false))))

(provide 'drgnx-uitest)
;;; drgnx-uitest.el ends here
