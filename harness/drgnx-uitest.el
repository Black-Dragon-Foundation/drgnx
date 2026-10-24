;;; drgnx-uitest.el --- Drive a drgnx harness session with paced synthetic input -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Loaded only inside harness sessions (docs/develop/harness.md).  Input is queued and delivered
;; one event per `drgnx-uitest-tick', so redisplay runs between events as it does for a
;; person; queued input would skip redisplay and hide jank.  Positions are root-frame
;; pixels, the same pixels as a screenshot.  APIs called through emacsclient run in
;; ` *server*', so they always act on the root frame's selected window.

;;; Code:
(require 'cl-lib)
(require 'drgnx-jank-guard)

(defvar drgnx-uitest-session-id nil
  "This session's id (DRGNX_UI_NAME, set by harness/init/prelude.el): `drgnx-uitest-api-as' runs only for it.")

(defvar drgnx-uitest-tick 0.04 "Seconds between two delivered input events.")
(defvar drgnx-uitest-quiet 0.3
  "Seconds without delivered input or visible change after which the session counts as settled.")

(defvar drgnx-uitest--queue nil "Input events waiting to be delivered, one per tick.")
(defvar drgnx-uitest--timer nil)
(defvar drgnx-uitest--last-delivery 0.0 "`float-time' of the last delivered event.")
(defvar drgnx-uitest--next-id 0)

;;;; Frames and windows

(defun drgnx-uitest-scale-ready-p (scale size factor geometry)
  "Non-nil when a root frame on a monitor of SIZE (\"WxH\", device pixels) at SCALE shows FACTOR (its
`frame-scale-factor') and GEOMETRY (the monitor's (X Y W H)).  GTK 3 knows only integer scales: a fractional
SCALE reaches Emacs as (ceiling SCALE), and the geometry is (W / SCALE) * (ceiling SCALE) (2880x1800 at 1.25:
4608x2880), within one logical pixel."
  (let ((c (ceiling scale)))
    (and (= factor c)
         (or (= scale c)
             (let ((px (mapcar #'string-to-number (split-string size "x"))))
               (and (<= (abs (- (nth 2 geometry) (* c (round (/ (float (nth 0 px)) scale))))) c)
                    (<= (abs (- (nth 3 geometry) (* c (round (/ (float (nth 1 px)) scale))))) c)))))))

(defun drgnx-uitest-root-frame ()
  "The session's root frame: the first visible graphical frame that is not a child frame.
Falls back to the selected frame (a daemon's terminal frame, or batch)."
  (or (cl-find-if (lambda (f) (and (null (frame-parent f)) (frame-visible-p f) (display-graphic-p f)))
                  (frame-list))
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

(defun drgnx-uitest--text-origin (window)
  "Frame pixel (X . Y) of the top-left corner of WINDOW's text area — the origin of
`posn-x-y' for text-area positions.  Computed from the window's outer edges plus its tab
line and header line: `window-body-pixel-edges' counts a tab line as body."
  (let ((edges (window-pixel-edges window)))
    (cons (nth 0 (window-body-pixel-edges window))
          (+ (nth 1 edges) (window-tab-line-height window) (window-header-line-height window)))))

(defun drgnx-uitest--text-box (window)
  "WINDOW's text area as frame pixels [LEFT TOP RIGHT BOTTOM]."
  (let ((origin (drgnx-uitest--text-origin window))
        (edges (window-pixel-edges window))
        (body (window-body-pixel-edges window)))
    (vector (car origin) (cdr origin) (nth 2 body)
            (- (nth 3 edges) (window-mode-line-height window) (window-scroll-bar-height window)))))

(defun drgnx-uitest-pos-xy (window pos)
  "Root-frame pixel (X . Y) in the middle of the character at POS in WINDOW, or nil if a
click there would not land on POS (invisible, scrolled away, cut off at the right edge)."
  (let* ((f (window-frame window))
         (origin (drgnx-uitest--text-origin window))
         (posn (and (not (with-current-buffer (window-buffer window) (invisible-p pos)))
                    (posn-at-point pos window)))
         (xy (and posn (posn-x-y posn)))
         (x (and xy (+ (car origin) (car xy) (/ (frame-char-width f) 2))))
         (y (and xy (+ (cdr origin) (cdr xy) (/ (frame-char-height f) 2))))
         (back (and xy (posn-at-x-y x y f))))
    (and back (eq (posn-window back) window) (eql (posn-point back) pos) (cons x y))))

(defun drgnx-uitest-target-xy (buffer text)
  "Root-frame pixel (X . Y) inside the first fully visible TEXT in the window showing BUFFER.
BUFFER is a buffer name or a major mode name.  An occurrence counts only if a click at its
pixel lands on it (`drgnx-uitest-pos-xy') — so text cut off at the right edge or hidden by
folding is never clicked.  Signals if there is no such occurrence."
  (let ((win (or (drgnx-uitest-find-window buffer)
                 (error "drgnx-uitest: no window shows %s" buffer))))
    (with-current-buffer (window-buffer win)
      (save-excursion
        (goto-char (window-start win))
        (let ((limit (window-end win t)) found)
          (while (and (not found) (search-forward text limit t))
            (setq found (drgnx-uitest-pos-xy win (match-beginning 0))))
          (or found (error "drgnx-uitest: %S is not visible in %s" text buffer)))))))

;;;; Events (pure)

(defun drgnx-uitest-key-events (keys)
  "Input events for KEYS in `kbd' syntax, e.g. \"C-x b\"."
  (listify-key-sequence (kbd keys)))

(defun drgnx-uitest-type-events (text)
  "Input events that type TEXT (a newline is the Return key, as typed — not C-j)."
  (mapcar (lambda (c) (if (eq c ?\n) 'return c)) text))

(defun drgnx-uitest--mouse-event-head (stem button)
  "The event symbol STEM-mouse-BUTTON (STEM \"down\", \"drag\", \"double\", \"double-down\") or,
with STEM nil, mouse-BUTTON.  Every mouse event the harness makes takes its symbol from here.
Emacs gives a click on a mode line, header line, tab line, divider, fringe or margin its area as
a key prefix (`[header-line down-mouse-1]') only for a symbol with the `event-kind' property
`mouse-click'.  Real input sets it the first time a symbol is made; a symbol interned here
never went through that, so a press on a header line would run the text area's binding —
for whichever events happened to be made first."
  (let ((head (intern (if stem (format "%s-mouse-%d" stem button) (format "mouse-%d" button)))))
    (put head 'event-kind 'mouse-click)
    head))

(defun drgnx-uitest-click-events (posn &optional button count hold)
  "Input events for clicking at POSN.
BUTTON is 1-3 (default 1), COUNT 1 or 2, HOLD seconds between press and release.  The
release is resolved when delivered (`drgnx-uitest--release-event'): a click, or a drag if
the text under the pointer changed meanwhile, as Emacs does for real input."
  (let* ((b (or button 1))
         (single (append (list (list (drgnx-uitest--mouse-event-head "down" b) posn))
                         (and hold (> hold 0) (list (cons 'drgnx-uitest-pause hold)))
                         (list (list 'drgnx-uitest-release b posn)))))
    (if (eql count 2)
        (append single (list (list (drgnx-uitest--mouse-event-head "double-down" b) posn 2)
                             (list (drgnx-uitest--mouse-event-head "double" b) posn 2)))
      single)))

(defun drgnx-uitest--posn-frame-xy (posn)
  "Frame pixel (X . Y) of POSN, whatever part of its window it is on.
`posn-x-y' is relative to the text area for the text and the fringes and margins (x: the body for
text, the window's left edge for the fringes), and to the window's top left for the header line,
tab line, mode line, dividers and scroll bars.  A posn on no window is already frame-relative."
  (let ((win (posn-window posn)) (xy (posn-x-y posn)) (area (posn-area posn)))
    (if (not (window-live-p win))
        xy
      (let ((edges (window-pixel-edges win))
            (origin (drgnx-uitest--text-origin win)))
        (cond ((null area) (cons (+ (car origin) (car xy)) (+ (cdr origin) (cdr xy))))
              ((memq area '(left-fringe right-fringe left-margin right-margin))
               (cons (+ (car edges) (car xy)) (+ (cdr origin) (cdr xy))))
              (t (cons (+ (car edges) (car xy)) (+ (nth 1 edges) (cdr xy)))))))))

(cl-defun drgnx-uitest-drag-events (from to &key button steps lazy)
  "Input events for dragging BUTTON (1-3, default 1) from posn FROM to posn TO.
`down-mouse-B' at FROM, STEPS (default 8) `mouse-movement' events on the straight line from FROM
to TO (the last at TO) — what a `track-mouse' loop reads —, then `drag-mouse-B' from FROM to TO.
When FROM and TO are the same pixel it is a click: `down-mouse-B', `mouse-B', no movements.
FROM may be on any part of a window — text, header line, tab line, mode line, fringe, divider —
and keeps its `posn-area', so a drag can start on a tab row or a window divider.  The movement
positions are what Emacs reports at the interpolated frame pixels, so they change window and
area as the pointer crosses them.

The posns are made now, against today's layout.  A drag that moves the layout under the pointer
(a divider, a tab reorder) needs them made as each event is delivered, the way Emacs reports a
real pointer: with LAZY the movements and the release are `(drgnx-uitest-move X Y)' and
`(drgnx-uitest-drag-end BUTTON FROM X Y)' queue entries that `drgnx-uitest--tick' resolves then."
  (let* ((b (or button 1))
         (n (or steps 8))
         (a (drgnx-uitest--posn-frame-xy from))
         (z (drgnx-uitest--posn-frame-xy to))
         (frame (if (windowp (posn-window from)) (window-frame (posn-window from)) (posn-window from)))
         (at (lambda (i)
               (let ((x (round (+ (car a) (* (- (car z) (car a)) (/ (float i) n)))))
                     (y (round (+ (cdr a) (* (- (cdr z) (cdr a)) (/ (float i) n))))))
                 (cond (lazy (list 'drgnx-uitest-move x y))
                       ((= i n) (list 'mouse-movement to))
                       (t (list 'mouse-movement (posn-at-x-y x y frame))))))))
    (append
     (list (list (drgnx-uitest--mouse-event-head "down" b) from))
     (unless (equal a z) (cl-loop for i from 1 to n collect (funcall at i)))
     (list (cond ((equal a z) (list (drgnx-uitest--mouse-event-head nil b) from))
                 (lazy (list 'drgnx-uitest-drag-end b from (car z) (cdr z)))
                 (t (list (drgnx-uitest--mouse-event-head "drag" b) from to)))))))

;;;; Paced delivery

(defun drgnx-uitest--release-event (button start)
  "The event for releasing BUTTON at the frame pixel where START was pressed.
Like Emacs for real input: if what lies under that pixel changed since the press — another
buffer position, or another window (the text or the layout moved under a held button) —
the release is a drag from START, else a click."
  (let* ((win (posn-window start))
         (end (if (and (windowp win) (window-live-p win) (null (posn-area start)) (posn-x-y start))
                  ;; Text area: back to the frame pixel, then resolve it as Emacs would now.
                  (let ((origin (drgnx-uitest--text-origin win)))
                    (posn-at-x-y (+ (car origin) (car (posn-x-y start)))
                                 (+ (cdr origin) (cdr (posn-x-y start)))
                                 (window-frame win)))
                start)))
    (drgnx-uitest--release-for button start end)))

(defun drgnx-uitest--release-for (button start end)
  "The release event of BUTTON pressed at posn START and released at posn END: a drag from START
if a text-area press now lies in another window or at another buffer position, else a click."
  (let ((win (posn-window start)))
    (if (and (windowp win) (null (posn-area start))
             (or (not (eq (posn-window end) win))
                 (not (eql (posn-point end) (posn-point start)))))
        (list (drgnx-uitest--mouse-event-head "drag" button) start end)
      (list (drgnx-uitest--mouse-event-head nil button) end))))

(defun drgnx-uitest--drag-end-event (button start end)
  "The release of a drag of BUTTON from posn START, resolved against posn END as it is now.
Like a click's release (`drgnx-uitest--release-for') for a press on text: if the pointer is back
on the pressed buffer position and window, it is a plain click.  A press on any other part of a
window (header line, tab line, mode line, divider, fringe) or on no window is always a drag —
the drag was asked for between two different pixels."
  (let ((win (posn-window start)))
    (if (and (windowp win) (null (posn-area start)))
        (drgnx-uitest--release-for button start end)
      (list (drgnx-uitest--mouse-event-head "drag" button) start end))))

(defvar drgnx-uitest--pointer nil
  "Frame pixel (X . Y) of the pointer as the queued mouse events put it, or nil when none is being delivered.")

(defun drgnx-uitest--pointer-advice (orig &rest args)
  "`mouse-absolute-pixel-position' while queued mouse events are delivered: their position, not the real pointer's.
`mouse-drag-line' (a divider, a mode line) measures a drag by the pointer's position, which a synthesized event does not move."
  (or drgnx-uitest--pointer (apply orig args)))

(advice-add 'mouse-absolute-pixel-position :around #'drgnx-uitest--pointer-advice)

(defun drgnx-uitest--note-pointer (ev)
  "Remember where the mouse event EV puts the pointer (`drgnx-uitest--pointer'); other events leave it."
  (when (and (consp ev) (symbolp (car ev)) (string-match-p "mouse" (symbol-name (car ev))))
    (let ((posn (if (string-prefix-p "drag-" (symbol-name (car ev))) (nth 2 ev) (nth 1 ev))))
      (when (and (consp posn) (ignore-errors (posn-window posn)))
        (setq drgnx-uitest--pointer (drgnx-uitest--posn-frame-xy posn))))))

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
      (setq drgnx-uitest--timer nil
            drgnx-uitest--pointer nil))
     ((eq (car-safe ev) 'drgnx-uitest-pause)
      (setcar drgnx-uitest--queue (cons 'drgnx-uitest-until (+ (float-time) (cdr ev)))))
     ((eq (car-safe ev) 'drgnx-uitest-until)
      (when (>= (float-time) (cdr ev)) (pop drgnx-uitest--queue)))
     (t
      (pop drgnx-uitest--queue)
      (pcase (car-safe ev)
        ('drgnx-uitest-release (setq ev (drgnx-uitest--release-event (nth 1 ev) (nth 2 ev))))
        ;; a drag's movements and release are placed against the layout as it is now
        ('drgnx-uitest-move (setq ev (list 'mouse-movement (drgnx-uitest-posn (nth 1 ev) (nth 2 ev)))))
        ('drgnx-uitest-drag-end
         (setq ev (drgnx-uitest--drag-end-event (nth 1 ev) (nth 2 ev)
                                                (drgnx-uitest-posn (nth 3 ev) (nth 4 ev))))))
      (drgnx-uitest--note-pointer ev)
      (setq unread-command-events (append unread-command-events (list ev))
            drgnx-uitest--last-delivery (float-time))))))

(defun drgnx-uitest-busy-p ()
  "Non-nil while input is queued or not yet read."
  (or drgnx-uitest--queue unread-command-events))

(defun drgnx-uitest-settled-p (&optional quiet)
  "Non-nil when no input is pending and nothing changed for QUIET seconds — counted from the
last input, the last change, and the start of the current measurement (so a measurement
without input still gives followers and timers their chance)."
  (and (not (drgnx-uitest-busy-p))
       (>= (- (float-time) (max drgnx-uitest--last-delivery drgnx-uitest-record--last-change
                                drgnx-uitest-record--t0))
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
(defvar drgnx-uitest-record--frame nil
  "The root frame when the measurement began.  The recorder stays on it: a frame made meanwhile comes
first in `frame-list' and would otherwise become the root frame.")
(defvar drgnx-uitest-record--size nil "The measured frame's pixel size (W . H) at the last snapshot.")

(defun drgnx-uitest-record--root ()
  "The frame the recorder watches: the measurement's (even once deleted), else the root frame."
  (or drgnx-uitest-record--frame (drgnx-uitest-root-frame)))

(defun drgnx-uitest-record--frame-size (frame)
  "FRAME's pixel size as (WIDTH . HEIGHT)."
  (cons (frame-pixel-width frame) (frame-pixel-height frame)))

(defun drgnx-uitest-record--signatures ()
  "Alist of (ID . SIGNATURE) for the measured frame's windows and its minibuffer."
  (let ((f (drgnx-uitest-record--root)))
    (cons (cons "mini" (list :height (window-pixel-height (minibuffer-window f))))
          (mapcar (lambda (w)
                    (cons (drgnx-uitest-window-id w)
                          (list :buffer (buffer-name (window-buffer w))
                                :start (window-start w) :point (window-point w)
                                :edges (window-pixel-edges w)
                                :header (window-header-line-height w)
                                :modeline (window-mode-line-height w)
                                :selected (eq w (frame-selected-window f)))))
                  (window-list f 'nomini)))))

(defun drgnx-uitest-record--change (id old new cause)
  (push (list (float-time) 'change id old new cause) drgnx-uitest-record--log)
  (setq drgnx-uitest-record--last-change (float-time)))

(defun drgnx-uitest-record--snapshot (cause)
  "Record every window whose signature changed since the last snapshot, as caused by CAUSE.
When CAUSE is `other' (no command or timer ran) and the frame's pixel size changed since the last
snapshot, the window manager resized it (a tiling WM halving it for a new window, say): `wm:resize'.
Once the measured frame is deleted nothing more is recorded: another frame's windows are not its windows,
and that frame's other size is no WM resize."
  (when-let* ((frame (drgnx-uitest-record--root))
              ((frame-live-p frame))
              (now (drgnx-uitest-record--signatures))
              (size (drgnx-uitest-record--frame-size frame)))
    (when (and (equal cause "other") drgnx-uitest-record--size (not (equal size drgnx-uitest-record--size)))
      (setq cause "wm:resize"))
    (setq drgnx-uitest-record--size size)
    (dolist (cell now)
      (let ((old (assoc (car cell) drgnx-uitest-record--sigs)))
        (unless (equal (cdr old) (cdr cell))
          (drgnx-uitest-record--change (car cell) (cdr old) (cdr cell) cause)
          (if old (setcdr old (cdr cell)) (push (copy-tree cell) drgnx-uitest-record--sigs)))))
    (dolist (old drgnx-uitest-record--sigs)
      (when (and (cdr old) (not (assoc (car old) now)))
        (drgnx-uitest-record--change (car old) (cdr old) nil cause)
        (setcdr old nil)))))

(defvar drgnx-uitest-record--command nil
  "Cause string of the innermost command or timer running now, or nil.")

(defun drgnx-uitest-record--ambient-cause ()
  "Who changed things since the last snapshot: the innermost running command or timer,
else `other' (process output, redisplay, …)."
  (or drgnx-uitest-record--command "other"))

(defun drgnx-uitest-record--poll ()
  "Tick poll: changes no timer claimed — the running command's, or `other'."
  (drgnx-uitest-record--snapshot (drgnx-uitest-record--ambient-cause)))

(defun drgnx-uitest-record--before-command ()
  (drgnx-uitest-record--snapshot "other")      ; whatever happened between commands
  (setq drgnx-uitest-record--command (format "command:%s" this-command)))

(defun drgnx-uitest-record--after-command ()
  (drgnx-uitest-record--snapshot (or drgnx-uitest-record--command (format "command:%s" this-command)))
  (drgnx-uitest--note-target (selected-window))      ; a window the input moved focus to is aimed at
  (setq drgnx-uitest-record--command nil))

(defconst drgnx-uitest-record--harness-timers
  '(drgnx-uitest--tick drgnx-uitest-record--poll drgnx-uitest--run-watch)
  "The harness's own timers: never a cause.")

(declare-function drgnx-timer-describe "drgnx-timer")

(defun drgnx-uitest-record--after-timer (orig timer)
  "Snapshot just before and right after each timer, so what it changed is attributed to it
— even a point moved with `goto-char' inside `with-selected-window', which calls no
window function — and what changed before it (the running command's work, process output)
is not."
  (let ((fn (and (timerp timer)         ; a layer timer's function is named by its entry, not `drgnx-timer--fire'
                 (let ((layer (and (fboundp 'drgnx-timer-describe) (drgnx-timer-describe timer))))
                   (if layer (plist-get layer :fn) (timer--function timer))))))
    (if (memq fn drgnx-uitest-record--harness-timers)
        (funcall orig timer)
      (drgnx-uitest-record--snapshot (drgnx-uitest-record--ambient-cause))
      (let ((cause (concat "timer:" (drgnx-jank-guard--describe fn))))
        ;; While it runs, this timer is the ambient cause — timers nested inside it (during its
        ;; sit-for) snapshot its changes under its name before running.
        (prog1 (let ((drgnx-uitest-record--command cause)) (funcall orig timer))
          (drgnx-uitest-record--snapshot cause))))))

(defvar drgnx-uitest-record--scroll-starts nil "Alist window id → last start seen by the scroll hook.")

(defun drgnx-uitest-record--on-scroll (window start)
  "Record a scroll — only if WINDOW's start really changed: redisplay also runs
`window-scroll-functions' with an unchanged start, which must not count as a change."
  (let* ((id (drgnx-uitest-window-id window))
         (seen (assoc id drgnx-uitest-record--scroll-starts)))
    (unless (and seen (eql (cdr seen) start))
      (if seen (setcdr seen start) (push (cons id start) drgnx-uitest-record--scroll-starts))
      (push (list (float-time) 'scroll id start) drgnx-uitest-record--log)
      (setq drgnx-uitest-record--last-change (float-time)))))

(defun drgnx-uitest-record--on-redisplay (_window)
  (cl-incf drgnx-uitest-record--redisplays))

(defun drgnx-uitest--plist-keys (plist)
  "PLIST's keys, each once (the first occurrence is the one `plist-get' sees)."
  (delete-dups (cl-loop for (k _v) on plist by #'cddr collect k)))

(defun drgnx-uitest-jank-report (log t0 initial targets last-input)
  "Summarise recorder LOG (oldest first) of a measurement started at T0.
INITIAL is the signature alist at T0, TARGETS the ids of windows the input was
aimed at (their changes are not collateral), LAST-INPUT the time of the last event.
Changes caused by `wm:resize' (the window manager resized the frame) count as layout, never as
collateral or a snap-back."
  (let ((last-change t0) (layout 0) (chrome 0) (echo 0) (scrolls 0) (osc 0) (collateral nil)
        (timer-moves 0) (wm-resizes 0) (causes nil) (trace nil)
        (history (mapcar (lambda (c) (list (car c) (cdr c))) initial)))
    (dolist (e log)
      (setq last-change (max last-change (car e)))
      (pcase e
        (`(,_ scroll . ,_) (cl-incf scrolls))
        (`(,time change ,id ,old ,new . ,rest)
         (let* ((cause (or (car rest) "other"))
                (wm (equal cause "wm:resize")))
           (if (assoc cause causes) (cl-incf (cdr (assoc cause causes))) (push (cons cause 1) causes))
           (when (and (string-prefix-p "timer:" cause) (not (equal id "mini"))) (cl-incf timer-moves))
           (when wm (cl-incf wm-resizes))
           (when (< (length trace) 50)
             (push (drgnx-uitest--trace-step (round (* 1000 (- time t0))) cause id old new) trace))
           (if (equal id "mini")
               (cl-incf echo)
             (when (or (null old) (null new)
                       (not (equal (plist-get old :edges) (plist-get new :edges))))
               (cl-incf layout))
             (when (and old new (not (and (equal (plist-get old :header) (plist-get new :header))
                                          (equal (plist-get old :modeline) (plist-get new :modeline)))))
               (cl-incf chrome))
             (unless (or wm (member id targets)) (cl-pushnew id collateral :test #'equal)))
           ;; Snap-backs are per field: point returning to where it was is one even if the
           ;; window's edges changed in between.  The WM's resizes are history, never a snap-back.
           (let ((h (assoc id history)) (snapped nil))
             (if (null h)
                 (push (list id new) history)
               (unless wm
                 (dolist (field (drgnx-uitest--plist-keys new))
                   (let ((now (plist-get new field))
                         (seen (mapcar (lambda (sig) (plist-get sig field)) (cdr h))))
                     (when (and (not (equal now (car seen))) (member now (cdr seen)))
                       (setq snapped t)))))
               (when snapped (cl-incf osc))
               (setcdr h (cons new (cdr h)))))))))
    (list :settle_ms (max 0 (round (* 1000 (- last-change (max t0 last-input)))))
          :layout_changes layout
          :collateral_moves (length collateral)
          :collateral (vconcat (reverse collateral))
          :oscillations osc :chrome_changes chrome :echo_changes echo :scrolls scrolls
          :timer_moves timer-moves
          :wm_resizes wm-resizes
          :causes (vconcat (mapcar (lambda (c) (list :cause (car c) :count (cdr c))) (reverse causes)))
          :trace (vconcat (reverse trace)))))

(defun drgnx-uitest--json-value (v)
  (cond ((null v) :false) ((consp v) (vconcat v)) (t v)))

(defun drgnx-uitest--trace-step (t-ms cause id old new)
  "One trace entry: when, why, which window, and the fields that changed (from → to)."
  (let ((step (list :t_ms t-ms :cause cause :window id)))
    (cond
     ((null old) (append step (list :fields ["created"])))
     ((null new) (append step (list :fields ["deleted"])))
     (t (let ((fields (seq-remove (lambda (k) (equal (plist-get old k) (plist-get new k)))
                                  (drgnx-uitest--plist-keys new))))
          (append step
                  (list :fields (vconcat (mapcar (lambda (k) (substring (symbol-name k) 1)) fields))
                        :from (cl-mapcan (lambda (k) (list k (drgnx-uitest--json-value (plist-get old k)))) fields)
                        :to (cl-mapcan (lambda (k) (list k (drgnx-uitest--json-value (plist-get new k)))) fields))))))))

(defun drgnx-uitest--note-target (window)
  "Count WINDOW as a target of the measured input."
  (when (windowp window)
    (cl-pushnew (drgnx-uitest-window-id window) drgnx-uitest--targets :test #'equal)))

(defun drgnx-uitest-measure-begin (&optional frame)
  "Start recording visible changes of FRAME (default: the root frame) for a jank report."
  (setq frame (or frame (drgnx-uitest-root-frame)))
  (setq drgnx-uitest--targets nil
        drgnx-uitest-record--log nil
        drgnx-uitest-record--scroll-starts      ; the starts now: a redraw that keeps them is no scroll
        (mapcar (lambda (w) (cons (drgnx-uitest-window-id w) (window-start w)))
                (seq-mapcat (lambda (f) (window-list f 'nomini)) (frame-list)))
        drgnx-uitest-record--t0 (float-time)
        drgnx-uitest-record--last-change 0.0
        drgnx-uitest-record--redisplays 0
        drgnx-uitest-record--gc0 (cons gcs-done gc-elapsed)
        drgnx-uitest-record--guard0 (length drgnx-jank-guard-log)
        drgnx-uitest-record--frame frame
        drgnx-uitest-record--size (drgnx-uitest-record--frame-size frame)
        drgnx-uitest-record--sigs (copy-tree (drgnx-uitest-record--signatures))
        drgnx-uitest-record--initial (copy-tree drgnx-uitest-record--sigs))
  (drgnx-uitest--note-target (frame-selected-window frame))
  (drgnx-uitest--note-target (selected-window))      ; the window with focus (a second frame's too)
  (add-hook 'window-scroll-functions #'drgnx-uitest-record--on-scroll)
  (add-hook 'pre-redisplay-functions #'drgnx-uitest-record--on-redisplay)
  (setq drgnx-uitest-record--command nil)
  (add-hook 'pre-command-hook #'drgnx-uitest-record--before-command -99)
  (add-hook 'post-command-hook #'drgnx-uitest-record--after-command 99)
  (advice-add 'timer-event-handler :around #'drgnx-uitest-record--after-timer)
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
  (remove-hook 'pre-command-hook #'drgnx-uitest-record--before-command)
  (remove-hook 'post-command-hook #'drgnx-uitest-record--after-command)
  (setq drgnx-uitest-record--command nil drgnx-uitest-record--frame nil drgnx-uitest-record--size nil)
  (advice-remove 'timer-event-handler #'drgnx-uitest-record--after-timer)
  ;; No target is added here: a window a timer focused after the input is collateral.  Targets are
  ;; the start's windows, the windows of mouse events and those focus moved to after a command.
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

;; Declared before use so the bindings in `drgnx-uitest-run' are dynamic.
(defvar drgnx-uitest--run-deadline 0.0)
(defvar drgnx-uitest--run-settled nil)
(defvar drgnx-guard--timer-fn)          ; drgnx's no-prompt guard, when loaded


(defconst drgnx-uitest-settle-timeout 5.0
  "Seconds `drgnx-uitest-run' waits for the session to settle on an idle machine.")

(defconst drgnx-uitest-settle-scale-max 8.0
  "Largest factor `drgnx-uitest-settle-scale' gives (a stuck session still ends).")

(defun drgnx-uitest-settle-scale (&optional load cpus env)
  "Factor to stretch the settle timeout by on a loaded machine.
`DRGNX_UITEST_SETTLE_SCALE' (or ENV, a string) overrides it with a positive number.  Otherwise it
is the 1-minute load average LOAD over the number of CPUS (defaults: this machine's), at least 1
and at most `drgnx-uitest-settle-scale-max': on a machine with a core to spare, 1."
  (let ((forced (let ((v (or env (getenv "DRGNX_UITEST_SETTLE_SCALE"))))
                  (and v (string-match-p "\\`[0-9]+\\(\\.[0-9]+\\)?\\'" v) (string-to-number v)))))
    (if (and forced (> forced 0))
        (float forced)
      (let ((load (or load (car (ignore-errors (load-average t)))))
            (cpus (max 1 (or cpus (num-processors)))))
        (if (numberp load)
            (min drgnx-uitest-settle-scale-max (max 1.0 (/ (float load) cpus)))
          1.0)))))

(defun drgnx-uitest-run (events &optional timeout)
  "Deliver EVENTS paced, wait until settled or TIMEOUT seconds, return the jank report.
TIMEOUT defaults to `drgnx-uitest-settle-timeout' times `drgnx-uitest-settle-scale' (a loaded
machine settles slower); an explicit TIMEOUT is used as given.
For ERT tests inside a session: a nested command loop runs the events as commands,
with redisplay between them, while the test waits.  The plist has :settled."
  (drgnx-uitest-measure-begin)
  (dolist (ev events)
    (when (mouse-event-p ev) (drgnx-uitest--note-target (posn-window (event-start ev)))))
  (drgnx-uitest-enqueue events)
  (setq drgnx-uitest--run-deadline (+ (float-time) (or timeout (* drgnx-uitest-settle-timeout (drgnx-uitest-settle-scale))))
        drgnx-uitest--run-settled nil)
  (let ((watch (run-with-timer drgnx-uitest-tick drgnx-uitest-tick #'drgnx-uitest--run-watch)))
    (unwind-protect
        ;; The test may run inside a timer; the commands it drives are not timer code.
        (let ((drgnx-jank-guard--timer-fn nil) (drgnx-guard--timer-fn nil)) (recursive-edit))
      (cancel-timer watch))
    (append (list :settled (if drgnx-uitest--run-settled t :false)) (drgnx-uitest-measure-end))))

(defun drgnx-uitest--run-watch ()
  "Leave `drgnx-uitest-run''s nested command loop once settled or past the deadline."
  (when (or (setq drgnx-uitest--run-settled (drgnx-uitest-settled-p))
            (> (float-time) drgnx-uitest--run-deadline))
    (exit-recursive-edit)))

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

;;;; Snapshots and pixel probes
;; A snapshot is (W H BYTES): BYTES holds W*H ARGB32 pixels, rows tightly packed, each pixel a 32-bit word in the
;; machine's byte order (little-endian: B G R A), the layout of `glitnir-snapshot' with FORMAT `raw'.

(defun drgnx-uitest-glitnir-p ()
  "Non-nil when Glitnir (the compositor) draws this session's frames, so its snapshot is the whole picture."
  (and (fboundp 'glitnir-active-p) (fboundp 'glitnir-snapshot) (glitnir-active-p)))

(defun drgnx-uitest--png-raw (png)
  "Decode PNG (a unibyte string: 8-bit RGB or RGBA, not interlaced, as cairo writes) into a snapshot."
  (unless (and (> (length png) 8) (string-prefix-p "\x89PNG" png)) (error "drgnx-uitest: not a PNG"))
  (unless (and (fboundp 'zlib-available-p) (zlib-available-p)) (error "drgnx-uitest: this Emacs has no zlib"))
  (let ((pos 8) w h ctype (idat nil))
    (while (< pos (length png))
      (let* ((len (+ (ash (aref png pos) 24) (ash (aref png (+ pos 1)) 16) (ash (aref png (+ pos 2)) 8) (aref png (+ pos 3))))
             (type (substring png (+ pos 4) (+ pos 8)))
             (data (+ pos 8)))
        (cond ((equal type "IHDR")
               (setq w (+ (ash (aref png data) 24) (ash (aref png (+ data 1)) 16) (ash (aref png (+ data 2)) 8) (aref png (+ data 3)))
                     h (+ (ash (aref png (+ data 4)) 24) (ash (aref png (+ data 5)) 16) (ash (aref png (+ data 6)) 8) (aref png (+ data 7)))
                     ctype (aref png (+ data 9)))
               (unless (and (= (aref png (+ data 8)) 8) (memq ctype '(2 6)) (= (aref png (+ data 12)) 0))
                 (error "drgnx-uitest: unsupported PNG (need 8-bit RGB/RGBA, not interlaced)")))
              ((equal type "IDAT") (push (substring png data (+ data len)) idat)))
        (setq pos (+ data len 4))))
    (let* ((bpp (if (= ctype 6) 4 3))
           (stride (* w bpp))
           (z (with-temp-buffer
                (set-buffer-multibyte nil)
                (apply #'insert (nreverse idat))
                (unless (zlib-decompress-region (point-min) (point-max)) (error "drgnx-uitest: bad PNG data"))
                (buffer-string)))
           (out (make-string (* w h 4) 0))  ; an ASCII fill makes a unibyte string; every byte is set below
           (le (eq (byteorder) ?l))
           (prev (make-string stride 0))
           (cur (make-string stride 0)))
      (dotimes (y h)
        (let ((base (* y (1+ stride))) (ft (aref z (* y (1+ stride)))))
          (dotimes (i stride)
            (let* ((x (aref z (+ base 1 i)))
                   (a (if (>= i bpp) (aref cur (- i bpp)) 0))
                   (b (aref prev i))
                   (c (if (>= i bpp) (aref prev (- i bpp)) 0)))
              (aset cur i
                    (logand 255
                            (+ x (pcase ft
                                   (0 0) (1 a) (2 b) (3 (ash (+ a b) -1))
                                   (4 (let* ((p (- (+ a b) c)) (pa (abs (- p a))) (pb (abs (- p b))) (pc (abs (- p c))))
                                        (cond ((and (<= pa pb) (<= pa pc)) a) ((<= pb pc) b) (t c))))
                                   (_ (error "drgnx-uitest: bad PNG filter"))))))))
          (dotimes (px w)
            (let ((s (* px bpp)) (d (* 4 (+ (* y w) px))))
              (if le
                  (progn (aset out d (aref cur (+ s 2))) (aset out (+ d 1) (aref cur (+ s 1)))
                         (aset out (+ d 2) (aref cur s)) (aset out (+ d 3) (if (= bpp 4) (aref cur (+ s 3)) 255)))
                (aset out d (if (= bpp 4) (aref cur (+ s 3)) 255)) (aset out (+ d 1) (aref cur s))
                (aset out (+ d 2) (aref cur (+ s 1))) (aset out (+ d 3) (aref cur (+ s 2)))))))
        (let ((tmp prev)) (setq prev cur cur tmp)))
      (list w h out))))

(defun drgnx-uitest-export (&optional frame)
  "FRAME's (default: the root frame's) `x-export-frames' composite as a snapshot.
It is the logical-pixel (1x) picture of FRAME and its child frames, whatever the display scale."
  (let ((f (or frame (drgnx-uitest-root-frame))))
    (redisplay t)
    (drgnx-uitest--png-raw (x-export-frames f 'png))))

(defun drgnx-uitest-snapshot (&optional frame)
  "FRAME's (default: the root frame's) picture as a snapshot (W H BYTES), in device pixels.
Glitnir's raw snapshot (the buffer GTK last committed) when `glitnir-snapshot' exists, else `drgnx-uitest-export'."
  (let ((f (or frame (drgnx-uitest-root-frame))))
    (if (fboundp 'glitnir-snapshot)
        (progn (redisplay t) (glitnir-snapshot f 'raw))
      (drgnx-uitest-export f))))

(defun drgnx-uitest-pixel (snap x y)
  "The pixel of SNAP at device pixel X, Y as (A R G B)."
  (pcase-let* ((`(,w ,h ,bytes) snap))
    (unless (and (<= 0 x) (< x w) (<= 0 y) (< y h)) (error "drgnx-uitest: pixel %d,%d outside %dx%d" x y w h))
    (let ((o (* 4 (+ (* y w) x))))
      (if (eq (byteorder) ?l)
          (list (aref bytes (+ o 3)) (aref bytes (+ o 2)) (aref bytes (+ o 1)) (aref bytes o))
        (list (aref bytes o) (aref bytes (+ o 1)) (aref bytes (+ o 2)) (aref bytes (+ o 3)))))))

(cl-defun drgnx-uitest-region-equal-p (a b rect &key (tolerance 0) ignore-alpha)
  "Non-nil when snapshots A and B agree on RECT (L T R B, device pixels, R and B exclusive).
Every channel may differ by TOLERANCE; IGNORE-ALPHA leaves the alpha channel out.  Differing sizes: nil."
  (pcase-let ((`(,l ,tp ,r ,bt) rect))
    (when (and (equal (seq-take a 2) (seq-take b 2)))
      (let ((w (nth 0 a)) (ba (nth 2 a)) (bb (nth 2 b)) (ok t)
            (alpha (if (eq (byteorder) ?l) 3 0)) (y tp))
        (while (and ok (< y bt))
          (let ((s (* 4 (+ (* y w) l))) (e (* 4 (+ (* y w) r))))
            (unless (and (= tolerance 0) (not ignore-alpha) (string= (substring ba s e) (substring bb s e)))
              (let ((i s))
                (while (and ok (< i e))
                  (unless (and ignore-alpha (= (% (- i s) 4) alpha))
                    (when (> (abs (- (aref ba i) (aref bb i))) tolerance) (setq ok nil)))
                  (setq i (1+ i))))))
          (setq y (1+ y)))
        ok))))

(defun drgnx-uitest-darker-p (a b x y)
  "Non-nil when snapshot A's pixel at X, Y has a lower luma than B's."
  (cl-flet ((luma (p) (+ (* 0.2126 (nth 1 p)) (* 0.7152 (nth 2 p)) (* 0.0722 (nth 3 p)))))
    (< (luma (drgnx-uitest-pixel a x y)) (luma (drgnx-uitest-pixel b x y)))))

(defun drgnx-uitest-bare-frame ()
  "Scroll bars, tool bar, menu bar and the blinking cursor off for the selected frame."
  (blink-cursor-mode -1)
  (modify-frame-parameters nil '((vertical-scroll-bars) (horizontal-scroll-bars) (tool-bar-lines . 0) (menu-bar-lines . 0)))
  (redisplay t)
  nil)

(defun drgnx-uitest-capture (dir)
  "Export the root frame and its visible child frames as PNGs into DIR.
`x-export-frames' cannot put several frames in one PNG, so each child comes with its
offset (parent-relative native edges) for compositing.  When Glitnir draws the frames
(`drgnx-uitest-glitnir-p') its snapshot already holds the children: root.png is that
snapshot (device pixels) and there are no children."
  (unless (display-graphic-p (drgnx-uitest-root-frame))
    (error "drgnx-uitest: no graphical frame to capture (a daemon session without a client frame? open one with ui_frame)"))
  (redisplay t)
  (make-directory dir t)
  (let* ((f (drgnx-uitest-root-frame))
         (root (expand-file-name "root.png" dir))
         (i -1))
    (if (drgnx-uitest-glitnir-p)
        (let ((coding-system-for-write 'binary))
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert (glitnir-snapshot f 'png))
            (write-region nil nil root nil 'silent)))
      (drgnx-uitest--export f root))
    (list :root root :width (frame-pixel-width f) :height (frame-pixel-height f)
          :children (vconcat (and (not (drgnx-uitest-glitnir-p))
                                  (mapcar (lambda (c)
                                            (let ((file (expand-file-name (format "child-%d.png" (cl-incf i)) dir))
                                                  (e (frame-edges c 'native-edges)))
                                              (drgnx-uitest--export c file)
                                              (list :path file :x (nth 0 e) :y (nth 1 e))))
                                          (drgnx-uitest-child-frames f)))))))

;;;; JSON API (for emacsclient; see harness/drgnx-ui.el)

(defun drgnx-uitest--json (plist)
  "PLIST as JSON text.  `json-serialize' returns unibyte UTF-8, which
prints as raw bytes; decode it so non-ASCII text survives emacsclient."
  (decode-coding-string (json-serialize plist) 'utf-8))

(defun drgnx-uitest--window-info (w)
  (with-current-buffer (window-buffer w)
    (list :id (drgnx-uitest-window-id w) :buffer (buffer-name) :mode (symbol-name major-mode)
          :edges (vconcat (window-pixel-edges w)) :body (drgnx-uitest--text-box w)
          :start (window-start w) :point (window-point w)
          :line (line-number-at-pos (window-point w))
          :header_h (window-header-line-height w) :mode_line_h (window-mode-line-height w)
          :selected (if (eq w (frame-selected-window (window-frame w))) t :false))))

(defun drgnx-uitest--windows ()
  (vconcat (mapcar #'drgnx-uitest--window-info (window-list (drgnx-uitest-root-frame) 'nomini))))

(defmacro drgnx-uitest-api-as (id &rest body)
  "Evaluate BODY when this session's id (`drgnx-uitest-session-id') is ID.  Otherwise return the JSON
{\"refused\": \"this session is S, not ID\"} (`drgnx-ui-parse-reply' makes it a refusal).  `drgnx-ui-call' wraps every
form in it, so no socket path reaches a session other than the one whose id the caller was given."
  (declare (indent 1))
  (let ((want (make-symbol "id")))
    `(let ((,want ,id))
       (if (equal ,want drgnx-uitest-session-id)
           (progn ,@body)
         (drgnx-uitest--json (list :refused (format "this session is %s, not %s" drgnx-uitest-session-id ,want)))))))

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

(defun drgnx-uitest-api-drag (from-x from-y to-x to-y &optional button steps)
  "Queue a drag from root-frame pixel FROM-X, FROM-Y to TO-X, TO-Y (`drgnx-uitest-drag-events')."
  (let* ((from (drgnx-uitest-posn from-x from-y))
         (to (drgnx-uitest-posn to-x to-y))
         (w (posn-window from)))
    (drgnx-uitest--note-target w)
    (drgnx-uitest-enqueue (drgnx-uitest-drag-events from to :button (or button 1) :steps steps :lazy t))
    (drgnx-uitest--json (list :from (list :x from-x :y from-y) :to (list :x to-x :y to-y)
                              :window (if (windowp w) (drgnx-uitest-window-id w) :null)
                              :area (if (posn-area from) (symbol-name (posn-area from)) :null)))))

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

(defun drgnx-uitest-api-gui-frames ()
  "Number of graphical root frames, and how many are visible, as JSON."
  (let ((gui (cl-remove-if-not (lambda (f) (and (display-graphic-p f) (null (frame-parent f)))) (frame-list))))
    (drgnx-uitest--json (list :count (length gui) :visible (cl-count-if #'frame-visible-p gui)))))

(defconst drgnx-uitest--frame-hooks
  '(before-make-frame-hook after-make-frame-functions server-after-make-frame-hook
                           window-setup-hook window-size-change-functions window-configuration-change-hook
                           after-setting-font-hook server-switch-hook)
  "Hooks timed by `drgnx-uitest-api-time-frame-hooks'.")

(defvar drgnx-uitest--frame-times nil "Alist (NAME . ms), newest first.")

(defun drgnx-uitest--timed (name)
  (lambda (orig &rest args)
    (let ((t0 (float-time)))
      (prog1 (apply orig args)
        (push (cons name (round (* 1000 (- (float-time) t0)))) drgnx-uitest--frame-times)))))

(defun drgnx-uitest--time-run-hooks (orig &rest args)
  "Time whole runs of the frame hooks (catches lambdas too)."
  (let ((hook (car args)) (t0 (float-time)))
    (prog1 (apply orig args)
      (when (memq hook drgnx-uitest--frame-hooks)
        (push (cons (format "total %s" hook) (round (* 1000 (- (float-time) t0)))) drgnx-uitest--frame-times)))))

(defun drgnx-uitest-api-time-frame-hooks ()
  "Start timing frame creation: each named function on the frame hooks, each hook run,
and `make-frame' itself.  Resets earlier times."
  (setq drgnx-uitest--frame-times nil)
  (dolist (hook drgnx-uitest--frame-hooks)
    (dolist (fn (and (boundp hook) (ensure-list (default-value hook))))
      (when (and (symbolp fn) (fboundp fn))
        (advice-add fn :around (drgnx-uitest--timed (symbol-name fn)) '((name . drgnx-uitest-frame-time))))))
  (advice-add 'make-frame :around (drgnx-uitest--timed "make-frame") '((name . drgnx-uitest-frame-time)))
  (dolist (runner '(run-hooks run-hook-with-args))
    (advice-add runner :around #'drgnx-uitest--time-run-hooks))
  (drgnx-uitest--json (list :ok t)))

(defun drgnx-uitest--untime-frame-hooks ()
  "Remove every timing advice `drgnx-uitest-api-time-frame-hooks' added."
  (dolist (hook drgnx-uitest--frame-hooks)
    (dolist (fn (and (boundp hook) (ensure-list (default-value hook))))
      (when (and (symbolp fn) (fboundp fn)) (advice-remove fn 'drgnx-uitest-frame-time))))
  (advice-remove 'make-frame 'drgnx-uitest-frame-time)
  (dolist (runner '(run-hooks run-hook-with-args))
    (advice-remove runner #'drgnx-uitest--time-run-hooks)))

(defun drgnx-uitest-api-frame-hook-times ()
  "The slowest timed items since `drgnx-uitest-api-time-frame-hooks' (≤ 10), as JSON.
Removes the timing advice: it must not stay and slow down what is measured later."
  (drgnx-uitest--untime-frame-hooks)
  (let ((top (seq-take (sort (copy-sequence drgnx-uitest--frame-times) (lambda (a b) (> (cdr a) (cdr b)))) 10)))
    (drgnx-uitest--json
     (list :hooks (vconcat (mapcar (lambda (c) (list :name (car c) :ms (cdr c))) top))))))

(defun drgnx-uitest-api-boot-status ()
  "While init runs: the active minibuffer prompt (a config asking something), or null."
  (drgnx-uitest--json
   (list :prompt (let ((w (active-minibuffer-window)))
                   (if w (with-current-buffer (window-buffer w) (or (minibuffer-prompt) "")) :null)))))

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

;;;; The child-frame packages (posframe, corfu, …): pinned, installed once, read-only in tests

(defvar drgnx-pkg-native-compile)
(defvar drgnx-pkg-shipped-lock)
(defvar drgnx-pkg-default-archives)
(declare-function drgnx-pkg-sync "drgnx-pkg")
(declare-function drgnx-pkg-write-lock "drgnx-pkg")
(declare-function drgnx-pkg--desc-entry "drgnx-pkg")
(declare-function drgnx-pkg--file "drgnx-pkg")
(defvar package-gnupghome-dir)
(declare-function drgnx-elpa-dir "drgnx-paths")

(defconst drgnx-uitest--childframe-pins-file
  (expand-file-name "../test/fixtures/childframe-packages.eld"
                    (file-name-directory (or load-file-name buffer-file-name default-directory)))
  "The pins: (NAME VERSION :archive ARCHIVE :sha256 HASH), the file's only form.")

(defun drgnx-uitest--childframe-pins ()
  "The pins; $DRGNX_CHILDFRAME_PINS names another file (the tests' own)."
  (with-temp-buffer
    (insert-file-contents (or (getenv "DRGNX_CHILDFRAME_PINS") drgnx-uitest--childframe-pins-file))
    (read (current-buffer))))

(defun drgnx-uitest--childframe-archives ()
  "The archives: $DRGNX_CHILDFRAME_ARCHIVES (\"NAME=URL-or-DIR,…\", the tests' local ones), else drgnx's."
  (if-let* ((env (getenv "DRGNX_CHILDFRAME_ARCHIVES")))
      (mapcar (lambda (s) (let ((i (string-search "=" s))) (cons (substring s 0 i) (file-name-as-directory (substring s (1+ i))))))
              (split-string env "," t))
    drgnx-pkg-default-archives))

(defun drgnx-uitest-childframe-install (dir)
  "Install the pinned packages (and what they need) into the new directory DIR, as `drgnx sync' does, in a private
data directory: the files' hashes are checked against the pins and the archives' signatures where they sign.  A hash
that differs, or any package that cannot be had, is an error and leaves DIR alone."
  (require 'drgnx-pkg)
  (let* ((pins (drgnx-uitest--childframe-pins))
         (root (file-name-as-directory (make-temp-file "drgnx-childframe" t)))
         (process-environment (append (mapcar (lambda (kv) (concat (car kv) "=" root (cdr kv)))
                                              '(("DRGNX_DATA_DIR" . "data") ("DRGNX_CONFIG_DIR" . "config")
                                                ("XDG_CACHE_HOME" . "cache") ("XDG_STATE_HOME" . "state")))
                                      process-environment))
         (drgnx-pkg-native-compile nil)
         (drgnx-pkg-shipped-lock (concat root "no-shipped.lock.eld")))
    (unwind-protect
        (progn
          (make-directory (concat root "config") t)
          (make-directory (concat root "mods") t)
          (with-temp-file (expand-file-name "packages.eld" (concat root "config"))
            (prin1 (list :packages (mapcar #'car pins)) (current-buffer)))
          ;; the lock: each pin as the archive describes it (kind, file, requirements, so what a package needs is
          ;; installed too) with the pin's hash, which the sync then enforces
          (let ((package-archives (drgnx-uitest--childframe-archives))
                (package-user-dir (concat root "refresh")) (package-alist nil) (package-archive-contents nil)
                (package--initialized t) (package-gnupghome-dir (concat root "data/gnupg"))
                (package-quickstart nil))
            (package-refresh-contents)
            (drgnx-pkg-write-lock
             (mapcar (lambda (p)
                       (pcase-let* ((`(,name ,version . ,plist) p)
                                    (desc (seq-find (lambda (d) (and (equal (package-desc-archive d) (plist-get plist :archive))
                                                                     (equal (package-version-join (package-desc-version d)) version)))
                                                    (alist-get name package-archive-contents))))
                         (unless desc (error "%s %s: archive %s does not serve it" name version (plist-get plist :archive)))
                         (drgnx-pkg--desc-entry desc (drgnx-pkg--file desc) (plist-get plist :sha256))))
                     pins)))
          (let ((r (drgnx-pkg-sync :archives (drgnx-uitest--childframe-archives) :modules-dir (concat root "mods"))))
            (unless (plist-get r :ok)
              (error "%s" (mapconcat (lambda (m) (format "%s: %s" (car m) (cdr m))) (plist-get r :missing) "; ")))
            (copy-directory (drgnx-elpa-dir) dir nil t t)))
      (delete-directory root t))))

(defun drgnx-uitest-childframe-cli ()
  "`drgnx childframe-elpa DIR': the arguments after --."
  (let ((args (cdr (member "--" command-line-args-left))))
    (setq command-line-args-left nil)
    (kill-emacs
     (condition-case err
         (progn
           (unless (and (= (length args) 1) (not (file-exists-p (car args))))
             (error "usage: drgnx childframe-elpa DIR   (DIR must not exist yet)"))
           (drgnx-uitest-childframe-install (expand-file-name (car args)))
           0)
       (error (message "drgnx: childframe-elpa: %s" (error-message-string err)) 1)))))

(defun drgnx-uitest-childframe-packages ()
  "Put the pinned child-frame packages from $DRGNX_CHILDFRAME_ELPA on `load-path'; their names, or nil when that is
unset or lacks one (tests then `skip-unless', as with $DRGNX_MODAL_ELPA).  The directory is only read."
  (when-let* ((dir (getenv "DRGNX_CHILDFRAME_ELPA")) ((file-directory-p dir)))
    (let ((dirs (mapcar (lambda (p) (expand-file-name (format "%s-%s" (car p) (cadr p)) dir))
                        (drgnx-uitest--childframe-pins))))
      (when (seq-every-p #'file-directory-p dirs)
        ;; the pins and what they need (company, dash, frame-local, vertico: the directories the install made)
        (dolist (d (append dirs (seq-filter (lambda (f) (and (file-directory-p f) (not (string-prefix-p "." (file-name-nondirectory f)))
                                                             (not (member (file-name-nondirectory f) '("archives" "gnupg")))))
                                            (directory-files dir t nil t))))
          (add-to-list 'load-path d))
        (mapcar #'car (drgnx-uitest--childframe-pins))))))

(provide 'drgnx-uitest)
;;; drgnx-uitest.el ends here
