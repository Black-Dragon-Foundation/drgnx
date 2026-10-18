;;; drgnx-monitors.el --- Move a window to another monitor: the commands and what the workbench knows -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Move to Monitor… (a picker), Move to Next Monitor and Move to Previous Monitor (they wrap round) ask the
;; window-manager adapter (`drgnx-platform') to move the selected window.  A command never blocks: it says
;; "Moving…" and reports the adapter's answer in the echo area, in plain words.  Where the window manager does
;; not let an app move its windows (GNOME) the command says why and names the key that does.  The picker is
;; the one prompt, and only in a command you ran; it waits (at most the adapter's deadline) for the monitor
;; list, because a prompt can never be opened from a timer or a callback.
;;
;; The mode keeps what the workbench knows about the monitors: the frame parameter `drgnx-monitor' (the
;; monitor a window is on, absent where the adapter knows none) and `drgnx-monitors--count'.  Both are
;; refreshed asynchronously after a move, and through one idle timer (1 s) when monitors are plugged or unplugged (once per burst, whatever
;; the last refresh) and when a window gains focus or is moved (at most once per window every 10 s; a refresh held back
;; by that limit is deferred, not dropped).  Replies of an older query never overwrite a newer one.  See docs/guide/workbench.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-platform)

(defvar drgnx-monitors--count nil
  "How many monitors the window manager lists, as of the last refresh (nil: not known yet).")

(defvar drgnx-monitors--pending nil "Frames waiting for the idle timer's refresh.")
(defvar drgnx-monitors--timer nil "The idle timer that refreshes `drgnx-monitors--pending', or nil.")
(defvar drgnx-monitors--force nil
  "Non-nil when the pending refresh ignores `drgnx-monitors--min-interval' (monitors were plugged or unplugged).")
(defvar drgnx-monitors--list-gen 0 "Generation of the latest monitor-list query; an older reply is ignored.")

;; Per-frame state lives in weak tables, not in frame parameters: none of it can leak into a saved layout.
(defvar drgnx-monitors--stamps (make-hash-table :test #'eq :weakness 'key) "Frame -> time of its last refresh.")
(defvar drgnx-monitors--gens (make-hash-table :test #'eq :weakness 'key)
  "Frame -> generation of its latest monitor query; an older reply is ignored.")
(defvar drgnx-monitors--moving (make-hash-table :test #'eq :weakness 'key) "Frames with a move under way.")

(defconst drgnx-monitors--idle-delay 1 "Seconds of idle time before the pending frames are refreshed.")
(defconst drgnx-monitors--min-interval 10 "A frame is refreshed by the timer at most once in this many seconds.")

(defconst drgnx-monitors--only-one "Only one monitor: there is nowhere to move this window")

;;;; Which frames

(defun drgnx-monitors--eligible-p (frame)
  "FRAME is live, graphical and not a child frame (terminal frames are workbench frames too, but have no monitor)."
  (and (frame-live-p frame) (display-graphic-p frame) (not (frame-parent frame))))

(defun drgnx-monitors-available-p ()
  "The selected frame can be moved to a monitor: graphical, live, not a child frame."
  (drgnx-monitors--eligible-p (selected-frame)))

(defun drgnx-monitors--error-p (r) (and (consp r) (eq (car r) :error)))

(defun drgnx-monitors--later (fn) (run-at-time 0 nil fn))

;;;; Moving

(defun drgnx-monitors--reason (can)
  "CAN, a `drgnx-platform-can-move' refusal (REASON . FIX), as one sentence: \"REASON: FIX\"."
  (if (consp can)
      (if (cdr can) (format "%s: %s" (car can) (cdr can)) (car can))
    "drgnx cannot move this window"))

(defun drgnx-monitors--name (mon)
  "\"monitor N (NAME)\" for MON (a numbered monitor); without a name just \"monitor N\"."
  (let ((name (plist-get mon :name)))
    (if (and (stringp name) (not (string-empty-p name)))
        (format "monitor %d (%s)" (plist-get mon :number) name)
      (format "monitor %d" (plist-get mon :number)))))

(defun drgnx-monitors--target (target current monitors)
  "The monitor of MONITORS (numbered, sorted) TARGET names, or (:error MESSAGE).
TARGET is a number, `next' or `previous' (they wrap round from CURRENT, the monitor the window is on)."
  (let ((n (length monitors)))
    (cond ((integerp target)
           (or (seq-find (lambda (m) (eql (plist-get m :number) target)) monitors)
               (list :error (format "There is no monitor %d: there %s %d" target (if (= n 1) "is" "are") n))))
          ((not current) (list :error "Cannot tell which monitor this window is on"))
          (t (let ((i (1- (plist-get current :number))))
               (nth (mod (if (eq target 'next) (1+ i) (1- i)) n) monitors))))))

(defun drgnx-monitors--step (frame target monitors callback)
  "Second half of a move: MONITORS are known (two or more); find the current one, then move."
  (drgnx-platform-frame-monitor
   frame
   (lambda (seen)
     (let* ((current (and seen (drgnx-platform-match-monitor seen monitors)))
            (mon (drgnx-monitors--target target current monitors)))
       (cond ((drgnx-monitors--error-p mon) (funcall callback mon))
             ((and current (eql (plist-get current :number) (plist-get mon :number)))
              (funcall callback (list :ok (format "Already on %s" (drgnx-monitors--name mon)))))
             (t (drgnx-platform-move-frame
                 frame mon
                 (lambda (r)
                   (if (drgnx-monitors--error-p r)
                       (funcall callback r)
                     (when (frame-live-p frame)
                       (drgnx-monitors--set-monitor frame mon)
                       (drgnx-monitors-refresh frame))
                     (funcall callback (list :ok (format "Moved to %s" (drgnx-monitors--name mon)))))))))))))

(defun drgnx-monitors--move (frame target callback &optional monitors can)
  "Move FRAME to TARGET (a monitor number, `next' or `previous').  CALLBACK, later, gets (:ok MESSAGE) or
\(:error MESSAGE).  MONITORS, when given, is the numbered list the caller has fetched; CAN the answer of
`drgnx-platform-can-move' the caller already has (asked here when nil).  A move already under way for FRAME is
not joined: the new one is refused.  Never signals."
  (if (gethash frame drgnx-monitors--moving)
      (drgnx-monitors--later
       (lambda () (funcall callback (list :error "A move of this window is already under way"))))
    (puthash frame t drgnx-monitors--moving)
    (let ((cb (lambda (r)
                (remhash frame drgnx-monitors--moving)
                (condition-case err (funcall callback r)
                  (error (message "drgnx: monitors: %s" (error-message-string err)))))))
      (condition-case err
          (let ((can (or can (drgnx-platform-can-move frame))))
            (cond ((not (eq can t))
                   (drgnx-monitors--later (lambda () (funcall cb (list :error (drgnx-monitors--reason can))))))
                  (monitors
                   (drgnx-monitors--step frame target monitors cb))
                  (t (drgnx-platform-monitors
                      frame
                      (lambda (mons)
                        (cond ((drgnx-monitors--error-p mons) (funcall cb mons))
                              ((< (length mons) 2) (funcall cb (list :error drgnx-monitors--only-one)))
                              (t (drgnx-monitors--step frame target mons cb))))))))
        (error (drgnx-monitors--later
                (lambda () (funcall cb (list :error (format "Moving failed: %s" (error-message-string err)))))))))))

(defun drgnx-monitors-move (frame target &optional callback)
  "Move FRAME to TARGET: a monitor number, `next' or `previous' (they wrap round).
CALLBACK, called later, gets `ok' or (:error MESSAGE) (\"Moved to monitor 2 (DP-2)\" is the command's message).
Never signals and never blocks; FRAME's `drgnx-monitor' parameter is updated."
  (drgnx-monitors--move frame target
                        (lambda (r)
                          (when callback
                            (funcall callback (if (drgnx-monitors--error-p r) r 'ok))))))

;;;; Commands

(defun drgnx-monitors--show (r)
  "Say the result R of `drgnx-monitors--move' in the echo area."
  (message "%s" (cadr r)))

(defun drgnx-monitors--run (target)
  "The command body: move the selected window to TARGET, saying \"Moving…\" and then the result."
  (let* ((frame (selected-frame)) (can (drgnx-platform-can-move frame)))
    (if (not (eq can t))
        (message "%s" (drgnx-monitors--reason can))
      (message "Moving…")
      (drgnx-monitors--move frame target #'drgnx-monitors--show nil can))))

;;;###autoload
(defun drgnx-monitors-move-next ()
  "Move this window to the next monitor (from the last back to the first)."
  (interactive)
  (drgnx-monitors--run 'next))

;;;###autoload
(defun drgnx-monitors-move-previous ()
  "Move this window to the previous monitor (from the first to the last)."
  (interactive)
  (drgnx-monitors--run 'previous))

(defun drgnx-monitors--fetch-sync (frame)
  "FRAME's numbered monitors, or (:error MESSAGE).  Waits at most the adapter's deadline: only for the picker,
which is a prompt in a command the user ran (a prompt cannot be opened from a callback)."
  (let ((result nil)
        (deadline (+ (float-time) drgnx-platform-command-timeout drgnx-platform-watchdog-margin 0.5)))
    (drgnx-platform-monitors frame (lambda (r) (setq result (list r))))
    (while (and (not result) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (if result (car result) (list :error "The window manager did not answer"))))

(defun drgnx-monitors--table (labels)
  "A completion table over LABELS that keeps their order (monitor 1 first)."
  (lambda (string pred action)
    (if (eq action 'metadata)
        '(metadata (display-sort-function . identity) (cycle-sort-function . identity))
      (complete-with-action action labels string pred))))

;;;###autoload
(defun drgnx-monitors-move-to ()
  "Move this window to a monitor you pick."
  (interactive)
  (let* ((frame (selected-frame)) (can (drgnx-platform-can-move frame)))
    (if (not (eq can t))
        (message "%s" (drgnx-monitors--reason can))
      (let ((mons (drgnx-monitors--fetch-sync frame)))
        (cond ((drgnx-monitors--error-p mons) (message "%s" (cadr mons)))
              ((< (length mons) 2) (message "%s" drgnx-monitors--only-one))
              (t (condition-case nil
                     (let* ((labels (mapcar (lambda (m) (plist-get m :label)) mons))
                            (pick (completing-read "Move window to monitor: " (drgnx-monitors--table labels) nil t))
                            (mon (seq-find (lambda (m) (equal (plist-get m :label) pick)) mons)))
                       (when mon
                         (message "Moving…")
                         (drgnx-monitors--move frame (plist-get mon :number) #'drgnx-monitors--show mons can)))
                   (quit (message "Move cancelled")))))))))

;;;; What the workbench knows

(defun drgnx-monitors--emacs-count (frame)
  "How many monitors Emacs itself sees from FRAME (nil when it cannot say)."
  (ignore-errors (length (display-monitor-attributes-list frame))))

(defun drgnx-monitors--set-monitor (frame monitor)
  "Record MONITOR (a plist, or nil: none known) as the monitor FRAME is on; older queries still in flight lose.
nil rather than a removed parameter: Emacs cannot delete a frame parameter, and `frame-parameter' reads both as nil."
  (puthash frame (1+ (gethash frame drgnx-monitors--gens 0)) drgnx-monitors--gens)
  (set-frame-parameter frame 'drgnx-monitor monitor))

(defun drgnx-monitors--fetch-monitor (frame)
  "Ask the adapter which monitor FRAME is on; the answer is dropped when a newer query was started meanwhile."
  (let ((gen (1+ (gethash frame drgnx-monitors--gens 0))))
    (puthash frame gen drgnx-monitors--gens)
    (puthash frame (float-time) drgnx-monitors--stamps)
    (drgnx-platform-frame-monitor
     frame (lambda (mon)
             (when (and (frame-live-p frame) (eql gen (gethash frame drgnx-monitors--gens)))
               (set-frame-parameter frame 'drgnx-monitor mon))))))

(defun drgnx-monitors--fetch-count (frame)
  "Ask the adapter how many monitors there are (Emacs' own count where it cannot list them); the answer is
dropped when a newer query was started meanwhile."
  (let ((gen (cl-incf drgnx-monitors--list-gen)))
    (drgnx-platform-monitors
     frame (lambda (r)
             (when (= gen drgnx-monitors--list-gen)
               (setq drgnx-monitors--count
                     (if (drgnx-monitors--error-p r) (drgnx-monitors--emacs-count frame) (length r))))))))

(defun drgnx-monitors-refresh (frame)
  "Update FRAME's parameter `drgnx-monitor' and `drgnx-monitors--count' from the adapter, asynchronously.
Where the adapter knows no monitor for FRAME the parameter is nil; where it cannot list monitors the count is
Emacs' own.  A terminal or child frame is left alone."
  (when (drgnx-monitors--eligible-p frame)
    (condition-case err
        (progn (drgnx-monitors--fetch-monitor frame)
               (drgnx-monitors--fetch-count frame))
      (error (message "drgnx: monitors: %s" (error-message-string err))))))

(defun drgnx-monitors--arm (delay)
  "(Re)start the idle timer: one timer for all frames, restarted by every new request."
  (when (timerp drgnx-monitors--timer) (cancel-timer drgnx-monitors--timer))
  (setq drgnx-monitors--timer (run-with-idle-timer delay nil #'drgnx-monitors--run-pending)))

(defun drgnx-monitors--run-pending ()
  "The idle timer's job.  Each pending frame not refreshed in the last `drgnx-monitors--min-interval' s (all of
them after a hot-plug) is refreshed, the monitor list being fetched once for all of them; the others are kept
and the timer is armed again for the time they have left."
  (when (timerp drgnx-monitors--timer) (cancel-timer drgnx-monitors--timer))   ; harmless when it is the one running
  (setq drgnx-monitors--timer nil)
  (let ((frames (seq-filter #'drgnx-monitors--eligible-p drgnx-monitors--pending))
        (force drgnx-monitors--force) (now (float-time)) due deferred (soonest nil))
    (setq drgnx-monitors--pending nil drgnx-monitors--force nil)
    (dolist (f frames)
      (let ((left (- drgnx-monitors--min-interval (- now (gethash f drgnx-monitors--stamps 0)))))
        (if (or force (<= left 0))
            (push f due)
          (push f deferred)
          (setq soonest (if soonest (min soonest left) left)))))
    (condition-case err
        (when due
          (dolist (f due) (drgnx-monitors--fetch-monitor f))
          (drgnx-monitors--fetch-count (car due)))
      (error (message "drgnx: monitors: %s" (error-message-string err))))
    (when deferred
      (setq drgnx-monitors--pending deferred)
      (drgnx-monitors--arm (max drgnx-monitors--idle-delay soonest)))))

(defun drgnx-monitors--schedule-frames (frames &optional force)
  "Have FRAMES refreshed by the idle timer; FORCE: whatever their last refresh was."
  (dolist (f frames)
    (when (drgnx-monitors--eligible-p f) (cl-pushnew f drgnx-monitors--pending)))
  (when force (setq drgnx-monitors--force t))
  (when drgnx-monitors--pending (drgnx-monitors--arm drgnx-monitors--idle-delay)))

(defun drgnx-monitors--focus-changed (&rest _)
  "`after-focus-change-function': the frames that have focus may have changed monitor."
  (condition-case err
      (drgnx-monitors--schedule-frames
       (or (seq-filter (lambda (f) (and (drgnx-monitors--eligible-p f) (eq (frame-focus-state f) t))) (frame-list))
           (list (selected-frame))))
    (error (message "drgnx: monitors: %s" (error-message-string err)))))

(defun drgnx-monitors--frame-moved (frame)
  "`move-frame-functions': FRAME was moved, maybe to another monitor."
  (drgnx-monitors--schedule-frames (list frame)))

(defun drgnx-monitors--monitors-changed (&rest _)
  "`display-monitors-changed-functions': a monitor was plugged or unplugged.  Only refreshes, later and once per
burst of calls; moves nothing."
  (condition-case err
      (drgnx-monitors--schedule-frames (frame-list) t)
    (error (message "drgnx: monitors: %s" (error-message-string err)))))
;;;; Right-click menu

(defun drgnx-monitors--click-frame (click)
  (let ((w (and (mouse-event-p click) (ignore-errors (posn-window (event-start click))))))
    (cond ((windowp w) (window-frame w))
          ((framep w) w)
          (t (selected-frame)))))

(defun drgnx-monitors--context-p (click)
  "The `monitors' context: CLICK is in a graphical frame and more than one monitor is known."
  (let ((frame (drgnx-monitors--click-frame click)))
    (and (drgnx-monitors--eligible-p frame)
         (> (or drgnx-monitors--count (drgnx-monitors--emacs-count frame) 0) 1))))

;;;; The mode

(define-minor-mode drgnx-monitors-mode
  "Keep what the workbench knows about the monitors: each window's monitor and how many there are."
  :global t :group 'drgnx
  (if drgnx-monitors-mode
      (progn
        (add-hook 'display-monitors-changed-functions #'drgnx-monitors--monitors-changed)
        (add-hook 'move-frame-functions #'drgnx-monitors--frame-moved)
        (add-function :after after-focus-change-function #'drgnx-monitors--focus-changed)
        (drgnx-monitors--schedule-frames (list (selected-frame))))
    (remove-hook 'display-monitors-changed-functions #'drgnx-monitors--monitors-changed)
    (remove-hook 'move-frame-functions #'drgnx-monitors--frame-moved)
    (remove-function after-focus-change-function #'drgnx-monitors--focus-changed)
    (when (timerp drgnx-monitors--timer) (cancel-timer drgnx-monitors--timer))
    (setq drgnx-monitors--timer nil drgnx-monitors--pending nil drgnx-monitors--force nil)))

(provide 'drgnx-monitors)
;;; drgnx-monitors.el ends here
