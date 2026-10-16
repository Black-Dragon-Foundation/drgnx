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

;;;; Recorder

(defvar drgnx-uitest-record--last-change 0.0 "`float-time' of the last recorded visible change.")
(defvar drgnx-uitest-record--log nil "Recorded events, newest first.")
(defvar drgnx-uitest-record--sigs nil "Alist of window id to its last signature.")
(defvar drgnx-uitest-record--initial nil)
(defvar drgnx-uitest-record--t0 0.0)
(defvar drgnx-uitest-record--timer nil)
(defvar drgnx-uitest-record--redisplays 0)
(defvar drgnx-uitest-record--gc0 nil)
(defvar drgnx-uitest-record--guard0 0)
(defvar drgnx-uitest--targets nil "Ids of windows the measured input was aimed at.")

(defun drgnx-uitest-record--signatures ()
  "Alist of (ID . SIGNATURE) for the root frame's windows and its minibuffer."
  (let ((f (drgnx-uitest-root-frame)))
    (cons (cons "mini" (list :height (window-pixel-height (minibuffer-window f))))
          (mapcar (lambda (w)
                    (cons (drgnx-uitest-window-id w)
                          (list :buffer (buffer-name (window-buffer w))
                                :start (window-start w) :point (window-point w)
                                :edges (window-pixel-edges w)
                                :header (window-header-line-height w)
                                :modeline (window-mode-line-height w))))
                  (window-list f 'nomini)))))

(defun drgnx-uitest-record--change (id old new)
  (push (list (float-time) 'change id old new) drgnx-uitest-record--log)
  (setq drgnx-uitest-record--last-change (float-time)))

(defun drgnx-uitest-record--poll ()
  "Record every window whose signature changed since the last poll."
  (let ((now (drgnx-uitest-record--signatures)))
    (dolist (cell now)
      (let ((old (assoc (car cell) drgnx-uitest-record--sigs)))
        (unless (equal (cdr old) (cdr cell))
          (drgnx-uitest-record--change (car cell) (cdr old) (cdr cell))
          (if old (setcdr old (cdr cell)) (push (copy-tree cell) drgnx-uitest-record--sigs)))))
    (dolist (old drgnx-uitest-record--sigs)
      (when (and (cdr old) (not (assoc (car old) now)))
        (drgnx-uitest-record--change (car old) (cdr old) nil)
        (setcdr old nil)))))

(defun drgnx-uitest-record--on-scroll (window start)
  (push (list (float-time) 'scroll (drgnx-uitest-window-id window) start) drgnx-uitest-record--log)
  (setq drgnx-uitest-record--last-change (float-time)))

(defun drgnx-uitest-record--on-redisplay (_window)
  (cl-incf drgnx-uitest-record--redisplays))

(defun drgnx-uitest-jank-report (log t0 initial targets last-input)
  "Summarise recorder LOG (oldest first) of a measurement started at T0.
INITIAL is the signature alist at T0, TARGETS the ids of windows the input was
aimed at (their changes are not collateral), LAST-INPUT the time of the last event."
  (let ((last-change t0) (layout 0) (chrome 0) (echo 0) (scrolls 0) (osc 0) (collateral nil)
        (history (mapcar (lambda (c) (list (car c) (cdr c))) initial)))
    (dolist (e log)
      (setq last-change (max last-change (car e)))
      (pcase e
        (`(,_ scroll . ,_) (cl-incf scrolls))
        (`(,_ change ,id ,old ,new)
         (if (equal id "mini")
             (cl-incf echo)
           (when (or (null old) (null new)
                     (not (equal (plist-get old :edges) (plist-get new :edges))))
             (cl-incf layout))
           (when (and old new (not (and (equal (plist-get old :header) (plist-get new :header))
                                        (equal (plist-get old :modeline) (plist-get new :modeline)))))
             (cl-incf chrome))
           (unless (member id targets) (cl-pushnew id collateral :test #'equal)))
         (let ((h (assoc id history)))
           (if (null h)
               (push (list id new) history)
             (when (member new (cddr h)) (cl-incf osc))   ; back to an earlier value
             (setcdr h (cons new (cdr h))))))))
    (list :settle_ms (max 0 (round (* 1000 (- last-change (max t0 last-input)))))
          :layout_changes layout
          :collateral_moves (length collateral)
          :collateral (vconcat (reverse collateral))
          :oscillations osc :chrome_changes chrome :echo_changes echo :scrolls scrolls)))

(defun drgnx-uitest--note-target (window)
  "Count WINDOW as a target of the measured input."
  (when (windowp window)
    (cl-pushnew (drgnx-uitest-window-id window) drgnx-uitest--targets :test #'equal)))

(defun drgnx-uitest-measure-begin ()
  "Start recording visible changes for a jank report."
  (setq drgnx-uitest--targets nil
        drgnx-uitest-record--log nil
        drgnx-uitest-record--t0 (float-time)
        drgnx-uitest-record--last-change 0.0
        drgnx-uitest-record--redisplays 0
        drgnx-uitest-record--gc0 (cons gcs-done gc-elapsed)
        drgnx-uitest-record--guard0 (length drgnx-jank-guard-log)
        drgnx-uitest-record--sigs (copy-tree (drgnx-uitest-record--signatures))
        drgnx-uitest-record--initial (copy-tree drgnx-uitest-record--sigs))
  (drgnx-uitest--note-target (frame-selected-window (drgnx-uitest-root-frame)))
  (add-hook 'window-scroll-functions #'drgnx-uitest-record--on-scroll)
  (add-hook 'pre-redisplay-functions #'drgnx-uitest-record--on-redisplay)
  (when (timerp drgnx-uitest-record--timer) (cancel-timer drgnx-uitest-record--timer))
  (setq drgnx-uitest-record--timer
        (run-with-timer drgnx-uitest-tick drgnx-uitest-tick #'drgnx-uitest-record--poll)))

(defun drgnx-uitest-measure-end ()
  "Stop recording and return the jank report plist."
  (drgnx-uitest-record--poll)
  (when (timerp drgnx-uitest-record--timer) (cancel-timer drgnx-uitest-record--timer))
  (setq drgnx-uitest-record--timer nil)
  (remove-hook 'window-scroll-functions #'drgnx-uitest-record--on-scroll)
  (remove-hook 'pre-redisplay-functions #'drgnx-uitest-record--on-redisplay)
  (drgnx-uitest--note-target (frame-selected-window (drgnx-uitest-root-frame)))
  (let ((new (- (length drgnx-jank-guard-log) drgnx-uitest-record--guard0)))
    (append (drgnx-uitest-jank-report (reverse drgnx-uitest-record--log) drgnx-uitest-record--t0
                                      drgnx-uitest-record--initial drgnx-uitest--targets
                                      drgnx-uitest--last-delivery)
            (list :redisplays drgnx-uitest-record--redisplays
                  :gc_count (- gcs-done (car drgnx-uitest-record--gc0))
                  :gc_ms (round (* 1000 (- gc-elapsed (cdr drgnx-uitest-record--gc0))))
                  :guard_violations new
                  :guard (vconcat (seq-take drgnx-jank-guard-log new))))))

;;;; Running input from a test

(defun drgnx-uitest-run (events &optional timeout)
  "Deliver EVENTS paced, wait until settled or TIMEOUT seconds (default 5), return the jank report.
For ERT tests inside a session: a nested command loop runs the events as commands,
with redisplay between them, while the test waits.  The plist has :settled."
  (drgnx-uitest-measure-begin)
  (dolist (ev events)
    (when (mouse-event-p ev) (drgnx-uitest--note-target (posn-window (event-start ev)))))
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
    (append (list :settled (if settled t :false)) (drgnx-uitest-measure-end))))

;;;; Capture

(defun drgnx-uitest-child-frames (frame)
  "Visible child frames of FRAME (posframes, popups)."
  (cl-remove-if-not (lambda (c) (and (eq (frame-parent c) frame) (frame-visible-p c))) (frame-list)))

(defun drgnx-uitest--export (frame file)
  "Write FRAME as a PNG to FILE without touching the echo area."
  (let ((coding-system-for-write 'binary))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert (x-export-frames frame 'png))
      (write-region nil nil file nil 'silent))))

(defun drgnx-uitest-capture (dir)
  "Export the root frame and its visible child frames as PNGs into DIR.
`x-export-frames' cannot put several frames in one PNG, so each child comes with its
offset (parent-relative native edges) for compositing."
  (redisplay t)
  (make-directory dir t)
  (let* ((f (drgnx-uitest-root-frame))
         (root (expand-file-name "root.png" dir))
         (i -1))
    (drgnx-uitest--export f root)
    (list :root root :width (frame-pixel-width f) :height (frame-pixel-height f)
          :children (vconcat
                     (mapcar (lambda (c)
                               (let ((file (expand-file-name (format "child-%d.png" (cl-incf i)) dir))
                                     (e (frame-edges c 'native-edges)))
                                 (drgnx-uitest--export c file)
                                 (list :path file :x (nth 0 e) :y (nth 1 e))))
                             (drgnx-uitest-child-frames f))))))

;;;; JSON API (for emacsclient; see harness/drgnx_ui.py)

(defun drgnx-uitest--json (plist) (json-serialize plist))

(defun drgnx-uitest--window-info (w)
  (with-current-buffer (window-buffer w)
    (list :id (drgnx-uitest-window-id w) :buffer (buffer-name) :mode (symbol-name major-mode)
          :edges (vconcat (window-pixel-edges w)) :body (vconcat (window-body-pixel-edges w))
          :start (window-start w) :point (window-point w)
          :line (line-number-at-pos (window-point w))
          :header_h (window-header-line-height w) :mode_line_h (window-mode-line-height w)
          :selected (if (eq w (frame-selected-window (window-frame w))) t :false))))

(defun drgnx-uitest--windows ()
  (vconcat (mapcar #'drgnx-uitest--window-info (window-list (drgnx-uitest-root-frame) 'nomini))))

(defun drgnx-uitest-api-state ()
  "Frame, windows, minibuffer, child frames and busy flag, as JSON."
  (let ((f (drgnx-uitest-root-frame)))
    (drgnx-uitest--json
     (list :frame (list :width (frame-pixel-width f) :height (frame-pixel-height f))
           :windows (drgnx-uitest--windows)
           :minibuffer_h (window-pixel-height (minibuffer-window f))
           :children (vconcat (mapcar (lambda (c) (vconcat (frame-edges c 'native-edges)))
                                      (drgnx-uitest-child-frames f)))
           :busy (if (drgnx-uitest-busy-p) t :false)))))

(defun drgnx-uitest-api-screenshot (dir)
  "Capture into DIR; JSON with file paths, child offsets and the window map."
  (drgnx-uitest--json (append (drgnx-uitest-capture dir) (list :windows (drgnx-uitest--windows)))))

(defun drgnx-uitest-api-click (x y &optional button count hold-ms)
  "Queue a click at root-frame pixel X, Y."
  (let* ((posn (drgnx-uitest-posn x y))
         (w (posn-window posn)))
    (drgnx-uitest--note-target w)
    (drgnx-uitest-enqueue (drgnx-uitest-click-events posn (or button 1) (or count 1)
                                                     (and hold-ms (/ hold-ms 1000.0))))
    (drgnx-uitest--json (list :x x :y y :window (if (windowp w) (drgnx-uitest-window-id w) :null)))))

(defun drgnx-uitest-api-click-target (buffer text &optional button count hold-ms)
  "Queue a click on the first visible TEXT in the window showing BUFFER."
  (let ((xy (drgnx-uitest-target-xy buffer text)))
    (drgnx-uitest-api-click (car xy) (cdr xy) button count hold-ms)))

(defun drgnx-uitest-api-keys (keys)
  "Queue KEYS (`kbd' syntax)."
  (drgnx-uitest--json (list :queued (drgnx-uitest-enqueue (drgnx-uitest-key-events keys)))))

(defun drgnx-uitest-api-type (text)
  "Queue typing TEXT."
  (drgnx-uitest--json (list :queued (drgnx-uitest-enqueue (drgnx-uitest-type-events text)))))

(defun drgnx-uitest-api-status (&optional quiet-ms)
  "Busy and settled flags, as JSON."
  (drgnx-uitest--json
   (list :busy (if (drgnx-uitest-busy-p) t :false)
         :settled (if (drgnx-uitest-settled-p (and quiet-ms (/ quiet-ms 1000.0))) t :false))))

(defun drgnx-uitest-api-measure-begin ()
  "Start a measurement."
  (drgnx-uitest-measure-begin)
  (drgnx-uitest--json (list :ok t)))

(defun drgnx-uitest-api-measure-end ()
  "End the measurement; the jank report as JSON."
  (let ((r (drgnx-uitest-measure-end)))
    (drgnx-uitest--json
     (plist-put r :guard
                (vconcat (mapcar (lambda (g) (list :time (plist-get g :time)
                                                   :fn (symbol-name (plist-get g :fn))
                                                   :window (plist-get g :window)
                                                   :timer (plist-get g :timer)))
                                 (plist-get r :guard)))))))

(provide 'drgnx-uitest)
;;; drgnx-uitest.el ends here
